// Renders the Vacuum app icon: swift Tools/make_icon.swift <output.png>
import AppKit

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
func gradient(_ stops: [NSColor]) -> NSGradient { NSGradient(colors: stops)! }

// Tile: 824pt rounded square centered in the 1024 canvas, as macOS expects.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.shadowBlurRadius = 28
shadow.set()
color(20, 60, 120).setFill()
tilePath.fill()
ctx.restoreGState()

ctx.saveGState()
tilePath.addClip()
gradient([color(72, 190, 255), color(30, 110, 230), color(24, 60, 170)]).draw(in: tile, angle: -60)

// Cleaning trail: soft lighter swaths sweeping behind the robot.
ctx.setLineCap(.round)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
ctx.setLineWidth(70)
for (i, y) in [250.0, 395.0, 540.0].enumerated() {
    let p = CGMutablePath()
    let x0: CGFloat = 170, x1: CGFloat = 560
    p.move(to: CGPoint(x: i % 2 == 0 ? x0 : x1, y: y))
    p.addLine(to: CGPoint(x: i % 2 == 0 ? x1 : x0, y: y))
    ctx.addPath(p); ctx.strokePath()
}
ctx.restoreGState()

// Robot body, top-down, tilted slightly.
ctx.saveGState()
ctx.translateBy(x: 600, y: 470)
ctx.rotate(by: .pi / 14)
let R: CGFloat = 270

// Drop shadow
let sh = NSShadow()
sh.shadowColor = NSColor.black.withAlphaComponent(0.4)
sh.shadowOffset = NSSize(width: 0, height: -22)
sh.shadowBlurRadius = 38
ctx.saveGState(); sh.set()
color(255, 255, 255).setFill()
NSBezierPath(ovalIn: NSRect(x: -R, y: -R, width: 2 * R, height: 2 * R)).fill()
ctx.restoreGState()

// Shell
let body = NSBezierPath(ovalIn: NSRect(x: -R, y: -R, width: 2 * R, height: 2 * R))
gradient([color(255, 255, 255), color(214, 226, 244)]).draw(in: body, angle: -90)

// Front bumper: dark arc along the top.
let bumper = NSBezierPath()
bumper.appendArc(withCenter: .zero, radius: R, startAngle: 35, endAngle: 145)
bumper.appendArc(withCenter: .zero, radius: R - 42, startAngle: 145, endAngle: 35, clockwise: true)
bumper.close()
color(28, 40, 74).setFill()
bumper.fill()

// Top plate
let plateR: CGFloat = R - 70
let plate = NSBezierPath(ovalIn: NSRect(x: -plateR, y: -plateR - 10, width: 2 * plateR, height: 2 * plateR))
gradient([color(240, 246, 255), color(196, 212, 238)]).draw(in: plate, angle: -90)
color(170, 190, 224).setStroke()
plate.lineWidth = 4
plate.stroke()

// LiDAR turret
let tR: CGFloat = 78
let turret = NSBezierPath(ovalIn: NSRect(x: -tR, y: -tR + 20, width: 2 * tR, height: 2 * tR))
gradient([color(58, 72, 110), color(24, 34, 62)]).draw(in: turret, angle: -90)
let cap = NSBezierPath(ovalIn: NSRect(x: -tR + 22, y: -tR + 42, width: 2 * (tR - 22), height: 2 * (tR - 22)))
gradient([color(96, 112, 156), color(40, 52, 88)]).draw(in: cap, angle: -90)

// Status light (green = docked/ok)
let led = NSBezierPath(ovalIn: NSRect(x: -20, y: -150, width: 40, height: 40))
color(70, 220, 120).setFill(); led.fill()
let ledGlow = NSBezierPath(ovalIn: NSRect(x: -36, y: -166, width: 72, height: 72))
color(70, 220, 120, 0.25).setFill(); ledGlow.fill()
ctx.restoreGState()

// Gloss across the top of the tile.
ctx.saveGState()
tilePath.addClip()
gradient([NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])
    .draw(in: NSRect(x: 100, y: 520, width: 824, height: 404), angle: -90)
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
