import AppKit
import SwiftUI

/// The window of the menu bar panel with the corners of our cards instead of the system's small ones.
/// SwiftUI has no say over that window, so this reaches it through AppKit once it is shown
struct RoundedPanel: NSViewRepresentable {
    var radius: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { round(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { round(view.window) }
    }

    private func round(_ window: NSWindow?) {
        // once per window: SwiftUI updates the panel on every status poll
        guard let window, let frame = window.contentView?.superview, frame.layer?.cornerRadius != radius else { return }
        // the material behind the content is an effect view: its mask makes the shape, shadow included
        for case let effect as NSVisualEffectView in [frame] + frame.subviews where effect.maskImage?.capInsets.top != radius {
            effect.maskImage = Self.mask(radius)
        }
        frame.wantsLayer = true
        frame.layer?.cornerRadius = radius
        frame.layer?.cornerCurve = .continuous
        frame.layer?.masksToBounds = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.invalidateShadow()
    }

    /// a stretchable rounded rectangle: the corners stay, the middle stretches
    private static func mask(_ r: CGFloat) -> NSImage {
        let side = r * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }
}
