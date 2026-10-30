// Draws the app's icon: three waves, traffic that flows freely.
// build/app.sh makes AppIcon.icns from it. Run: swift app/icon.swift <file.png> (1024×1024)
import AppKit

let space = CGColorSpaceCreateDeviceRGB()
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
}
let aurora = gradient([color(0.18, 0.86, 0.78), color(0.24, 0.52, 1.0), color(0.58, 0.36, 0.98), color(0.98, 0.36, 0.62)])

// the same waves as Waves in app/Sources/Logo.swift: 1.25 periods between x 230 and 794
func wave(_ y: CGFloat, phase: CGFloat) -> CGPath {
    let p = CGMutablePath()
    for x in stride(from: CGFloat(230), through: 794, by: 4) {
        let pt = CGPoint(x: x, y: y + 46 * sin((x - 230) / 564 * 2 * .pi * 1.25 + phase))
        if x == 230 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    return p
}
let waves = [wave(632, phase: 0), wave(512, phase: 0.5), wave(392, phase: 1.0)]
let width: CGFloat = 46

// macOS icon grid: the shape is 824 of 1024 with a soft shadow around it
let shape = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 186, cornerHeight: 186, transform: nil)

let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
ctx.addPath(shape)
ctx.setFillColor(color(0, 0, 0))
ctx.fillPath()
ctx.restoreGState()

// deep night background with a faint blue light in the middle
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
ctx.drawLinearGradient(gradient([color(0.10, 0.09, 0.16), color(0.03, 0.03, 0.06)]),
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.drawRadialGradient(gradient([color(0.30, 0.35, 0.9, 0.18), color(0.30, 0.35, 0.9, 0)]),
                       startCenter: CGPoint(x: 512, y: 512), startRadius: 0, endCenter: CGPoint(x: 512, y: 512), endRadius: 420, options: [])

for w in waves {
    // glow
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 50, color: color(0.35, 0.45, 1, 0.7))
    ctx.addPath(w)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(color(0.35, 0.45, 1, 0.5))
    ctx.strokePath()
    ctx.restoreGState()
    // the wave in the aurora gradient
    ctx.saveGState()
    ctx.addPath(w)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(aurora, start: CGPoint(x: 230, y: 512), end: CGPoint(x: 794, y: 512),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
ctx.restoreGState()

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
