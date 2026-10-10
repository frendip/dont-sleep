import AppKit
import SwiftUI
import DontSleepCore

/// Explicit fixture-only entry points. Neither creates a ServiceClient nor changes power settings.
@MainActor enum NativePreviews {
    static func render(to directory: URL) throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, presentation) in fixtures {
            for dark in [false, true] {
                let view = MenuPanel(presentation: presentation)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.controlActiveState, .key)
                try snapshot(view, dark: dark, to: directory.appendingPathComponent(name + (dark ? "-dark.png" : "-light.png")))
            }
        }
        print("Rendered \(fixtures.count * 2) native panel previews to \(directory.path)")
    }
    private static func snapshot<V: View>(_ view: V, dark: Bool, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = host.appearance; window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        window.setContentSize(size); host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw RenderError.bitmap }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw RenderError.bitmap }
        try png.write(to: url)
        window.contentView = nil; window.close()
    }
    static var fixtures: [(String, MenuPresentation)] {
        let identity = SessionIdentity(sessionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, generation: 1)
        let power = PowerSnapshot(source: .battery, percent: 78, sampledAt: 100)
        let timer = Session(identity: identity, mode: .fifteenMinutes, deadline: 972, leaseDeadline: 130)
        let permanent = Session(identity: identity, mode: .permanent, deadline: nil, leaseDeadline: 130)
        func p(_ snapshot: SessionSnapshot) -> MenuPresentation { .init(snapshot: snapshot, serviceTime: 100) }
        var setup = MenuPresentation(snapshot: nil, serviceTime: 100, connected: false)
        setup.setupRequired = true; setup.canQuitWithoutService = true
        var unknown = MenuPresentation(snapshot: nil, serviceTime: 100, connected: false)
        unknown.setupActionAvailable = true
        return [
            ("active-timer", p(.init(state: .active, selectedMode: .fifteenMinutes, session: timer, power: power))),
            ("off", p(.init(state: .off, power: power))),
            ("low-battery", p(.init(state: .off, power: .init(source: .battery, percent: 18, sampledAt: 100), issue: .lowBattery))),
            ("restore-error", p(.init(state: .failed, session: permanent, power: power, issue: .restoreFailed))),
            ("permanent", p(.init(state: .active, session: permanent, power: power))),
            ("enabling", p(.init(state: .enabling, session: timer, power: power))),
            ("restoring", p(.init(state: .restoring, session: permanent, power: power))),
            ("setup", setup),
            ("unknown", unknown),
            ("eight-hours-ac", p(.init(state: .active, selectedMode: .eightHours, session: .init(identity: identity, mode: .eightHours, deadline: 28_900, leaseDeadline: 130), power: .init(source: .ac, percent: 100, sampledAt: 100))))
        ]
    }
    static func exportIcon(to directory: URL) throws {
        _ = NSApplication.shared
        let iconset = directory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(base)x\(base)" + (scale == 2 ? "@2x" : "") + ".png"
                try iconPNG(size: base * scale).write(to: iconset.appendingPathComponent(name))
            }
        }
        try iconPNG(size: 1024).write(to: directory.appendingPathComponent("AppIcon.png"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconset.path, "-o", directory.appendingPathComponent("AppIcon.icns").path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RenderError.bitmap }
        print("Exported vector-drawn AppIcon.icns and iconset to \(directory.path)")
    }
    private static func iconPNG(size: Int) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw RenderError.bitmap }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        let scale = CGFloat(size) / 1024
        context.cgContext.scaleBy(x: scale, y: scale)
        NSColor(calibratedWhite: 0.035, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 208, yRadius: 208).fill()
        NSColor.white.setStroke()
        let eye = NSBezierPath(); eye.move(to: NSPoint(x: 190, y: 512))
        eye.curve(to: NSPoint(x: 834, y: 512), controlPoint1: NSPoint(x: 358, y: 744), controlPoint2: NSPoint(x: 666, y: 744))
        eye.curve(to: NSPoint(x: 190, y: 512), controlPoint1: NSPoint(x: 666, y: 280), controlPoint2: NSPoint(x: 358, y: 280))
        eye.close(); eye.lineWidth = 45; eye.lineJoinStyle = .round; eye.stroke()
        NSColor.white.setFill()
        let bolt = NSBezierPath(); bolt.move(to: NSPoint(x: 556, y: 646))
        for point in [NSPoint(x: 444, y: 494), .init(x: 510, y: 494), .init(x: 475, y: 372), .init(x: 595, y: 543), .init(x: 525, y: 543)] { bolt.line(to: point) }
        bolt.close(); bolt.fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw RenderError.bitmap }
        return png
    }
    enum RenderError: Error { case bitmap }
}
