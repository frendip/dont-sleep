import Foundation
import CryptoKit

enum InstallerProgram {
    static let pinnedSHA256 = "3c69528560b579fb7f7598a71eb6862a6f2900a0911a2d693848f5d58e46e240"
    static func command(program: Data, digest: String, appPath: String, uid: UInt32, liveHash: String) throws -> String {
        let actual = SHA256.hash(data: program).map { String(format: "%02x", $0) }.joined()
        guard actual == digest, let source = String(data: program, encoding: .utf8), uid >= 501,
              !liveHash.isEmpty, liveHash.allSatisfy({ $0.isHexDigit }) else { throw ProgramError.invalid }
        // The authorization agent receives captured immutable bytes, never a mutable script path.
        return "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash --noprofile --norc -c " + quote(source) + " -- " + quote(appPath) + " --uid " + String(uid) + " --expected-app-hash " + quote(liveHash)
    }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    enum ProgramError: LocalizedError {
        case invalid
        var errorDescription: String? { "Служебный компонент изменён. Соберите или установите согласованную версию приложения заново." }
    }
}
