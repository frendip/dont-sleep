// Build-time AppKit drawing only. No Finder scripting or app/service launch.
import AppKit

let manager = FileManager.default
let canvas = NSSize(width: 720, height: 460)
let paper = NSColor(srgbRed: 0.95, green: 0.955, blue: 0.965, alpha: 1)
let ink = NSColor(srgbRed: 0.03, green: 0.035, blue: 0.04, alpha: 1)
let secondary = NSColor(srgbRed: 0.43, green: 0.46, blue: 0.51, alpha: 1)

func render(size: NSSize, scale: Int, draw: () -> Void) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
        pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    context.cgContext.translateBy(x: 0, y: size.height)
    context.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

func text(_ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular,
          color: NSColor = ink, center: CGFloat = 360) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                             .foregroundColor: color]
    let string = value as NSString
    let width = string.size(withAttributes: attrs).width
    string.draw(at: NSPoint(x: center - width / 2, y: y), withAttributes: attrs)
}

func background() {
    paper.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: canvas)).fill()
    text("Don’t Sleep", y: 29, size: 38, weight: .bold)
    text("Перетащите приложение в «Программы»", y: 80, size: 16, color: secondary)
    let panel = NSBezierPath(roundedRect: NSRect(x: 76, y: 115, width: 568, height: 174),
                             xRadius: 22, yRadius: 22)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
    shadow.shadowBlurRadius = 10
    shadow.shadowOffset = NSSize(width: 0, height: -5)
    shadow.set()
    paper.setFill()
    panel.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(srgbRed: 0.78, green: 0.80, blue: 0.82, alpha: 1).setStroke()
    panel.lineWidth = 1
    panel.stroke()
    NSColor.black.setStroke()
    for x: CGFloat in [350, 375] {
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: x, y: 175))
        chevron.line(to: NSPoint(x: x - 15, y: 190))
        chevron.line(to: NSPoint(x: x, y: 205))
        chevron.lineWidth = 3.5
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        chevron.stroke()
    }
    text("Инструкция по установке и первому запуску", y: 432, size: 12, color: secondary)
}

func drawImage(_ image: NSImage, rect: NSRect) {
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
               respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
}

func readme() {
    // Transparent padding keeps this file visually secondary in Finder's global icon size.
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 32, y: 18))
    path.line(to: NSPoint(x: 65, y: 18))
    path.line(to: NSPoint(x: 83, y: 36))
    path.line(to: NSPoint(x: 83, y: 90))
    path.line(to: NSPoint(x: 32, y: 90))
    path.close()
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
    shadow.shadowBlurRadius = 3
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: 0.79, alpha: 1).setStroke()
    path.lineWidth = 0.7
    path.stroke()
    let fold = NSBezierPath()
    fold.move(to: NSPoint(x: 65, y: 18))
    fold.line(to: NSPoint(x: 65, y: 36))
    fold.line(to: NSPoint(x: 83, y: 36))
    fold.stroke()
    NSColor(white: 0.87, alpha: 1).setStroke()
    for y in stride(from: 46, through: 66, by: 7) {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 40, y: y))
        line.line(to: NSPoint(x: 75, y: y))
        line.lineWidth = 1.5
        line.stroke()
    }
    text("TXT", y: 75, size: 10, weight: .medium, color: secondary, center: 57.5)
}

func savePNG(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

func iconset(name: String, output: URL, source: NSImage? = nil) throws {
    let directory = output.appendingPathComponent(name + ".iconset")
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let size = NSSize(width: points, height: points)
            let bitmap = render(size: size, scale: scale) {
                if let source {
                    drawImage(source, rect: NSRect(origin: .zero, size: size))
                } else {
                    NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(points) / 112, y: CGFloat(points) / 112)
                    readme()
                }
            }
            let suffix = scale == 2 ? "@2x" : ""
            try savePNG(bitmap, to: directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
        }
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", directory.path, "-o", output.appendingPathComponent(name + ".icns").path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "iconutil", code: Int(process.terminationStatus)) }
}

func main() throws {
    let args = CommandLine.arguments
    if args.count == 4 && args[1] == "--set-icon" {
        guard let image = NSImage(contentsOfFile: args[2]),
              NSWorkspace.shared.setIcon(image, forFile: args[3], options: []) else {
            throw NSError(domain: "Set file icon", code: 1)
        }
        return
    }
    guard args.count == 3 else {
        throw NSError(domain: "Usage: render-dmg <repo-root> <output-directory>", code: 1)
    }
    let root = URL(fileURLWithPath: args[1])
    let output = URL(fileURLWithPath: args[2])
    try manager.createDirectory(at: output, withIntermediateDirectories: true)
    for scale in [1, 2] {
        try savePNG(render(size: canvas, scale: scale, draw: background),
                    to: output.appendingPathComponent(scale == 1 ? "background.png" : "background@2x.png"))
    }
    let source = root.appendingPathComponent("Resources/DMG/VolumeIcon.png")
    guard let volume = NSImage(contentsOf: source),
          let app = NSImage(contentsOf: root.appendingPathComponent("Resources/Assets/AppIcon.png")) else {
        throw NSError(domain: "Missing icon source", code: 1)
    }
    try iconset(name: "VolumeIcon", output: output, source: volume)
    try iconset(name: "Readme", output: output)
    let preview = render(size: canvas, scale: 2) {
        background()
        let folder = NSWorkspace.shared.icon(forFile: "/Applications")
        drawImage(folder, rect: NSRect(x: 164, y: 134, width: 112, height: 112))
        drawImage(app, rect: NSRect(x: 444, y: 134, width: 112, height: 112))
        text("Applications", y: 254, size: 14, center: 220)
        text("Don’t Sleep", y: 254, size: 14, center: 500)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current!.cgContext.translateBy(x: 304, y: 294)
        readme()
        NSGraphicsContext.restoreGraphicsState()
        text("Установка.txt", y: 414, size: 14)
    }
    try savePNG(preview, to: output.appendingPathComponent("layout-preview.png"))
}

do { try main() } catch {
    fputs("DMG artwork failed: \(error)\n", stderr)
    exit(1)
}
