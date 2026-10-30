import SwiftUI

/// The mark: three waves, traffic flowing freely. Same curves as app/icon.swift
/// (there in a 1024 canvas, y up; here the box 210…814 of it fills the rect)
struct Waves: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x - 210) / 604 * rect.width, y: rect.minY + (814 - y) / 604 * rect.height)
        }
        var path = Path()
        for (y, phase) in [(CGFloat(632), CGFloat(0)), (512, 0.5), (392, 1.0)] {
            for x in stride(from: CGFloat(230), through: 794, by: 8) {
                let pt = p(x, y + 46 * sin((x - 230) / 564 * 2 * .pi * 1.25 + phase))
                if x == 230 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
        }
        return path
    }

    /// stroke width for a given size, in the icon's proportion
    static func width(_ size: CGFloat) -> CGFloat { 46 / 604 * size }
}

struct LogoMark: View {
    var size: CGFloat = 22

    var body: some View {
        Waves()
            .stroke(Theme.ribbon, style: StrokeStyle(lineWidth: Waves.width(size) * 1.3, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .shadow(color: Theme.glow.opacity(0.5), radius: size * 0.15)
    }
}

enum MenuBarIcon {
    /// template image for the menu bar: full when zapret works, faded when stopped
    static func image(running: Bool) -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let path = NSBezierPath(cgPath: Waves().path(in: rect.insetBy(dx: 0.5, dy: 0.5)).cgPath)
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.withAlphaComponent(running ? 1 : 0.45).setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
