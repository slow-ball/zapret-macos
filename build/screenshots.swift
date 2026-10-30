// The screenshots of the README from the app's snapshots (dark theme):
//   ZAPRET_SNAPSHOT=<folder> ZAPRET_SCRIPT="$PWD/src/zapret.sh" ZAPRET_DEMO=1 ZAPRET_SNAPSHOT_DARK=1 zapret.app/Contents/MacOS/zapret
//   xcrun swift build/screenshots.swift <snapshot folder> .github/screenshots
// Every screen is a window with rounded corners and a shadow; hero.jpg is the home page and the menu bar
// panel on a background.

import AppKit

let args = CommandLine.arguments
guard args.count == 3 else { print("screenshots.swift <снимки> <выход>"); exit(1) }
let src = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])

func load(_ name: String) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(data: try! Data(contentsOf: src.appendingPathComponent(name))) else { fatalError(name) }
    return rep
}

/// the part of a snapshot: the title bar strip of a page snapshot cut off, at most `height` pixels tall
func cut(_ rep: NSBitmapImageRep, top: Int, height: Int? = nil) -> CGImage {
    let h = min(rep.pixelsHigh - top, height ?? .max)
    return rep.cgImage!.cropping(to: CGRect(x: 0, y: top, width: rep.pixelsWide, height: h))!
}

/// a window: rounded, with a hairline border and a soft shadow
func drawWindow(_ img: CGImage, in r: CGRect, radius: CGFloat, _ ctx: CGContext) {
    let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -r.width * 0.012), blur: r.width * 0.05, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.draw(img, in: r)
    ctx.restoreGState()
    ctx.addPath(path); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor); ctx.setLineWidth(2); ctx.strokePath()
}

func canvas(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    draw(g.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ name: String, jpeg: Bool = false) {
    let data = jpeg ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])!
                    : rep.representation(using: .png, properties: [:])!
    try! data.write(to: out.appendingPathComponent(name))
}

/// one screen as a window on a transparent background, `width` pixels wide
func screen(_ img: CGImage, width: Int, radius: CGFloat = 26) -> NSBitmapImageRep {
    let margin = 30
    let w = width - 2 * margin
    let h = Int(CGFloat(img.height) * CGFloat(w) / CGFloat(img.width))
    return canvas(width, h + 2 * margin + 10) { ctx in
        ctx.interpolationQuality = .high
        drawWindow(img, in: CGRect(x: margin, y: margin + 10, width: w, height: h), radius: radius, ctx)
    }
}

let strip = 64
save(screen(cut(load("strategies-dark.png"), top: strip, height: 1460), width: 820), "strategies.png")
save(screen(cut(load("sites-dark.png"), top: strip), width: 820), "sites.png")
save(screen(cut(load("settings-dark.png"), top: strip), width: 820), "settings.png")
save(screen(cut(load("welcome-dark.png"), top: 0), width: 820), "welcome.png")
save(screen(cut(load("menu-dark.png"), top: strip), width: 404, radius: 22), "menu.png")

// hero: the window and the menu bar panel over a dark gradient
let home = cut(load("home-dark.png"), top: strip)
let menu = cut(load("menu-dark.png"), top: strip)
let hero = canvas(1800, 1260) { ctx in
    ctx.interpolationQuality = .high
    let colors = [NSColor(red: 0.07, green: 0.16, blue: 0.20, alpha: 1).cgColor, NSColor(red: 0.08, green: 0.07, blue: 0.13, alpha: 1).cgColor,
                  NSColor(red: 0.22, green: 0.12, blue: 0.36, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 1260), end: CGPoint(x: 1800, y: 0), options: [])
    let hw: CGFloat = 1060
    let hh = CGFloat(home.height) * hw / CGFloat(home.width)
    drawWindow(home, in: CGRect(x: 120, y: (1260 - hh) / 2, width: hw, height: hh), radius: 30, ctx)
    let mw: CGFloat = 520
    let mh = CGFloat(menu.height) * mw / CGFloat(menu.width)
    drawWindow(menu, in: CGRect(x: 1160, y: (1260 - mh) / 2 - 20, width: mw, height: mh), radius: 26, ctx)
}
save(hero, "hero.jpg", jpeg: true)
print("готово:", out.path)
