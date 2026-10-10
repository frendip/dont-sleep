import Foundation
import Darwin

public enum TrustRole: String, Codable, Sendable { case app, controller, watchdog }
public struct TrustedCode: Codable, Sendable {
    public let identifier: String
    public let cdhash: String
    public init(identifier: String, cdhash: String) { self.identifier = identifier; self.cdhash = cdhash }
}
public struct TrustManifest: Codable, Sendable {
    public let version: Int
    public let authorizedUID: UInt32
    public let app: TrustedCode
    public let controller: TrustedCode
    public let watchdog: TrustedCode
    public init(version: Int, authorizedUID: UInt32, app: TrustedCode, controller: TrustedCode, watchdog: TrustedCode) {
        self.version = version; self.authorizedUID = authorizedUID; self.app = app; self.controller = controller; self.watchdog = watchdog
    }
}
public final class TrustPolicy {
    public let manifest: TrustManifest
    public init(manifest: TrustManifest) throws {
        guard manifest.version == 1, manifest.authorizedUID >= 500,
              Set([manifest.app.identifier, manifest.controller.identifier, manifest.watchdog.identifier]).count == 3 else { throw PlatformError.invalidTrust }
        for code in [manifest.app, manifest.controller, manifest.watchdog] {
            guard !code.identifier.isEmpty, code.identifier.count < 200,
                  code.identifier.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }),
                  code.cdhash.count == 40, code.cdhash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw PlatformError.invalidTrust }
        }
        self.manifest = manifest
    }
    public static func load(from url: URL = URL(fileURLWithPath: "/Library/Application Support/DontSleep/trust.json")) throws -> TrustPolicy {
        let directory = try SecureDirectory(url: url.deletingLastPathComponent(), owner: 0, privateDirectory: false)
        guard let data = try directory.readFile(url.lastPathComponent, privateFile: false),
              let manifest = try? JSONDecoder().decode(TrustManifest.self, from: data) else { throw PlatformError.invalidTrust }
        return try TrustPolicy(manifest: manifest)
    }
    public func requirement(for role: TrustRole) -> String {
        let code: TrustedCode
        switch role { case .app: code = manifest.app; case .controller: code = manifest.controller; case .watchdog: code = manifest.watchdog }
        return "identifier \"\(code.identifier)\" and cdhash H\"\(code.cdhash)\""
    }
    public func configure(listener: NSXPCListener, allowedPeer role: TrustRole) {
        listener.setConnectionCodeSigningRequirement(requirement(for: role))
    }
    public func configure(connection: NSXPCConnection, peer role: TrustRole) {
        connection.setCodeSigningRequirement(requirement(for: role))
    }
    public func validateUID(_ connection: NSXPCConnection, role: TrustRole) -> Bool { validateUID(connection.effectiveUserIdentifier, role: role) }
    public func validateUID(_ uid: UInt32, role: TrustRole) -> Bool { uid == (role == .app ? manifest.authorizedUID : 0) }
}
