import SwiftUI
import AppKit

/// The approved open-eye silhouette is shared by the menu mark and app icon.
struct EyeOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
        path.move(to: CGPoint(x: x, y: y + h * 0.5))
        path.addCurve(to: CGPoint(x: x + w, y: y + h * 0.5), control1: CGPoint(x: x + w * 0.27, y: y - h * 0.17), control2: CGPoint(x: x + w * 0.73, y: y - h * 0.17))
        path.addCurve(to: CGPoint(x: x, y: y + h * 0.5), control1: CGPoint(x: x + w * 0.73, y: y + h * 1.17), control2: CGPoint(x: x + w * 0.27, y: y + h * 1.17))
        path.closeSubpath()
        return path
    }
}

struct EyeBolt: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let points: [CGPoint] = [.init(x: 0.57, y: 0.04), .init(x: 0.29, y: 0.55), .init(x: 0.49, y: 0.55), .init(x: 0.41, y: 0.96), .init(x: 0.73, y: 0.40), .init(x: 0.53, y: 0.40)]
        for (i, point) in points.enumerated() {
            let q = CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        p.closeSubpath(); return p
    }
}

struct EyeMark: View {
    let bolt: Bool
    var badge: StatusBadge = .none
    var compact = false
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: EyeArtwork.templateImage(bolt: bolt, compact: compact))
                .renderingMode(.template).resizable().scaledToFit()
                .frame(width: 27, height: 19)
            if badge != .none {
                Image(systemName: badge == .warning ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, badge == .warning ? Color.orange : Color.red)
                    .font(.system(size: 10, weight: .bold))
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(1))
                    .offset(x: 4, y: 3)
            }
        }.frame(width: badge == .none ? 27 : 31, height: 23)
    }
}

enum EyeArtwork {
    // Stable image identity prevents MenuBarExtra replacing its icon on every clock/status update.
    @MainActor private static let templates = [
        makeTemplate(bolt: false, compact: false), makeTemplate(bolt: true, compact: false),
        makeTemplate(bolt: false, compact: true), makeTemplate(bolt: true, compact: true)
    ]
    @MainActor static func templateImage(bolt: Bool, compact: Bool = false) -> NSImage {
        templates[(compact ? 2 : 0) + (bolt ? 1 : 0)]
    }
    @MainActor private static func makeTemplate(bolt: Bool, compact: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 28, height: 20), flipped: true) { rect in
            NSColor.black.setStroke()
            let eye = NSBezierPath()
            eye.move(to: NSPoint(x: 1, y: 10))
            eye.curve(to: NSPoint(x: 27, y: 10), controlPoint1: NSPoint(x: 8, y: -0.5), controlPoint2: NSPoint(x: 20, y: -0.5))
            eye.curve(to: NSPoint(x: 1, y: 10), controlPoint1: NSPoint(x: 20, y: 20.5), controlPoint2: NSPoint(x: 8, y: 20.5))
            eye.lineWidth = 1.8; eye.lineJoinStyle = .round; eye.stroke()
            if bolt {
                NSColor.black.setFill()
                let b = NSBezierPath()
                b.move(to: NSPoint(x: 16, y: 3)); b.line(to: NSPoint(x: 10, y: 11)); b.line(to: NSPoint(x: 14, y: 11))
                b.line(to: NSPoint(x: 12, y: 17)); b.line(to: NSPoint(x: 19, y: 8)); b.line(to: NSPoint(x: 15, y: 8)); b.close(); b.fill()
            }
            return true
        }
        // MenuBarExtra uses the NSImage dimensions, not the surrounding SwiftUI frame.
        if compact { image.size = NSSize(width: 20, height: 14) }
        image.isTemplate = true
        return image
    }
}
