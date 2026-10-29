// Draws the Orchard app icon and writes mac/icon/AppIcon.icns, docs/logo.png
// and web/icon.png. Run from the repo root:  swift mac/icon/make-icon.swift
//
// Design: a light grey squircle (Apple's 824/1024 icon grid) with a dark leaf on a
// short stem and a smaller sprouting leaf: "lots of small things grown locally".
import AppKit

func leafPath(length: CGFloat, width: CGFloat) -> NSBezierPath {
    // Pointed leaf along +y from the origin; width is the widest point.
    let p = NSBezierPath()
    p.move(to: .zero)
    p.curve(to: NSPoint(x: 0, y: length),
            controlPoint1: NSPoint(x: width * 0.98, y: length * 0.10),
            controlPoint2: NSPoint(x: width * 0.42, y: length * 0.80))
    p.curve(to: .zero,
            controlPoint1: NSPoint(x: -width * 0.42, y: length * 0.80),
            controlPoint2: NSPoint(x: -width * 0.98, y: length * 0.10))
    p.close()
    return p
}

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // Squircle body with soft drop shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    shadow.set()
    NSColor(calibratedWhite: 0.78, alpha: 1).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [
        NSColor(calibratedWhite: 0.96, alpha: 1),
        NSColor(calibratedWhite: 0.88, alpha: 1),
        NSColor(calibratedWhite: 0.78, alpha: 1),
    ])!.draw(in: body, angle: -70)
    // Subtle top highlight.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Same tones as the selection badge: a dark leaf on light grey.
    let ink = NSColor(calibratedWhite: 0.20, alpha: 1)
    let veinColor = NSColor(calibratedWhite: 0.42, alpha: 1)

    // Stem.
    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: 420, y: 205))
    stem.curve(to: NSPoint(x: 462, y: 372), controlPoint1: NSPoint(x: 428, y: 275), controlPoint2: NSPoint(x: 450, y: 335))
    stem.lineWidth = 34
    stem.lineCapStyle = .round
    ink.setStroke()
    stem.stroke()

    func leaf(at origin: NSPoint, angle: CGFloat, length: CGFloat, width: CGFloat, vein: Bool) {
        let t = NSAffineTransform()
        t.translateX(by: origin.x, yBy: origin.y)
        t.rotate(byDegrees: angle)
        let p = leafPath(length: length, width: width)
        p.transform(using: t as AffineTransform)
        NSGraphicsContext.saveGraphicsState()
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.12)
        s.shadowOffset = NSSize(width: 0, height: -6)
        s.shadowBlurRadius = 14
        s.set()
        ink.setFill()
        p.fill()
        NSGraphicsContext.restoreGraphicsState()
        guard vein else { return }
        let v = NSBezierPath()
        v.move(to: NSPoint(x: 0, y: length * 0.06))
        v.line(to: NSPoint(x: 0, y: length * 0.78))
        for (y, dir) in [(0.22, 1.0), (0.30, -1.0), (0.42, 1.0), (0.50, -1.0)] {
            v.move(to: NSPoint(x: 0, y: length * y))
            v.line(to: NSPoint(x: dir * width * 0.22, y: length * (y + 0.13)))
        }
        v.transform(using: t as AffineTransform)
        v.lineWidth = 13
        v.lineCapStyle = .round
        NSGraphicsContext.saveGraphicsState()
        p.addClip()
        veinColor.setStroke()
        v.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Big leaf leaning right, small sprout leaning left.
    leaf(at: NSPoint(x: 438, y: 292), angle: 52, length: 175, width: 120, vein: false)
    leaf(at: NSPoint(x: 462, y: 368), angle: -34, length: 450, width: 330, vein: true)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

func png(_ size: CGFloat) -> Data { draw(size: size).representation(using: .png, properties: [:])! }

for base in [16, 32, 128, 256, 512] {
    try png(CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let out = root.appendingPathComponent("mac/icon/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
precondition(p.terminationStatus == 0, "iconutil failed")

try fm.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
try png(512).write(to: root.appendingPathComponent("docs/logo.png"))
try png(256).write(to: root.appendingPathComponent("web/icon.png"))
print("Wrote mac/icon/AppIcon.icns, docs/logo.png, web/icon.png")
