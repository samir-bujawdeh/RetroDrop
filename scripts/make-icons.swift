// Draws RetroDrop's icons. Run from the repo root:  swift scripts/make-icons.swift
//
//   Resources/AppIcon.icns                     app icon (all sizes)
//   Resources/MenuBarStopped.png (+ @2x)       menu bar, server stopped: outlined phone
//   Resources/MenuBarRunning.png (+ @2x)       menu bar, server running: solid phone with radiating rings
//   assets/*.png                               previews for the README
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(_ px: Int, _ draw: (CGFloat) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

/// RetroDrop's "sending" signal: a centre dot inside concentric rings that open at the bottom,
/// like waves radiating from the phone. Stroke the rings and fill the dot.
func radialSignal(center c: NSPoint, dot: CGFloat, radii: [CGFloat], lineWidth: CGFloat,
                  gap: CGFloat = 70) -> (rings: NSBezierPath, dot: NSBezierPath) {
    let rings = NSBezierPath()
    for r in radii {
        // Angles run counter-clockwise from 3 o'clock; the gap is centred on 6 o'clock (270°).
        rings.move(to: NSPoint(x: c.x + r * cos((270 + gap / 2) * .pi / 180),
                               y: c.y + r * sin((270 + gap / 2) * .pi / 180)))
        rings.appendArc(withCenter: c, radius: r, startAngle: 270 + gap / 2, endAngle: 270 - gap / 2 + 360)
    }
    rings.lineWidth = lineWidth
    rings.lineCapStyle = .round
    let dotPath = NSBezierPath(ovalIn: NSRect(x: c.x - dot, y: c.y - dot, width: dot * 2, height: dot * 2))
    return (rings, dotPath)
}

// MARK: App icon (1024 master)

func appIcon(_ s: CGFloat) {
    let k = s / 1024
    // macOS icon grid: 824pt rounded square centred in 1024, with a soft shadow.
    let tile = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * k, yRadius: 185 * k)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.30)
    shadow.shadowBlurRadius = 18 * k
    shadow.shadowOffset = NSSize(width: 0, height: -8 * k)
    shadow.set()
    color(0x2A1A3A).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    // 70s sunset sky
    NSGradient(colors: [color(0x2B1C46), color(0x6B2D5C), color(0xD9573B), color(0xF4A340)],
               atLocations: [0, 0.38, 0.75, 1], colorSpace: .sRGB)!
        .draw(in: tile, angle: -90)
    // retro sun behind the phone
    let sun = NSRect(x: 512 * k - 250 * k, y: 470 * k, width: 500 * k, height: 500 * k)
    NSGradient(starting: color(0xFFD27A), ending: color(0xF7894A))!
        .draw(in: NSBezierPath(ovalIn: sun), angle: -90)
    // stripes across the bottom
    let stripes: [(UInt32, CGFloat, CGFloat)] = [(0xF6C445, 300, 58), (0xEE8A3A, 220, 58), (0xD9483B, 140, 58), (0x8E2F55, 60, 80)]
    for (hex, y, h) in stripes {
        color(hex).setFill()
        NSRect(x: tile.minX, y: y * k, width: tile.width, height: h * k).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // the phone: original-iPhone proportions, chunky home button
    let phone = NSRect(x: 512 * k - 175 * k, y: 175 * k, width: 350 * k, height: 640 * k)
    NSGraphicsContext.saveGraphicsState()
    let ps = NSShadow()
    ps.shadowColor = color(0x000000, 0.45)
    ps.shadowBlurRadius = 30 * k
    ps.shadowOffset = NSSize(width: 0, height: -14 * k)
    ps.set()
    color(0x1C1C21).setFill()
    NSBezierPath(roundedRect: phone, xRadius: 62 * k, yRadius: 62 * k).fill()
    NSGraphicsContext.restoreGraphicsState()
    // chrome bezel
    let bezel = NSBezierPath(roundedRect: phone.insetBy(dx: 4 * k, dy: 4 * k), xRadius: 58 * k, yRadius: 58 * k)
    bezel.lineWidth = 8 * k
    color(0xD8D8DE).setStroke()
    bezel.stroke()

    // screen
    let screen = NSRect(x: phone.minX + 34 * k, y: phone.minY + 128 * k, width: phone.width - 68 * k, height: 410 * k)
    NSGradient(starting: color(0x2F8F9D), ending: color(0x16485E))!
        .draw(in: NSBezierPath(rect: screen), angle: -90)
    // radiating signal on screen
    let signal = radialSignal(center: NSPoint(x: screen.midX, y: screen.midY - 6 * k), dot: 24 * k,
                              radii: [58 * k, 90 * k, 122 * k], lineWidth: 16 * k)
    color(0xFFF4E0).setFill()
    color(0xFFF4E0).setStroke()
    signal.dot.fill()
    signal.rings.stroke()

    // earpiece
    color(0x4A4A52).setFill()
    let ear = NSRect(x: phone.midX - 45 * k, y: phone.maxY - 66 * k, width: 90 * k, height: 14 * k)
    NSBezierPath(roundedRect: ear, xRadius: 7 * k, yRadius: 7 * k).fill()
    // home button
    let home = NSRect(x: phone.midX - 40 * k, y: phone.minY + 40 * k, width: 80 * k, height: 80 * k)
    color(0x2C2C33).setFill()
    NSBezierPath(ovalIn: home).fill()
    let ring = NSBezierPath(ovalIn: home.insetBy(dx: 3 * k, dy: 3 * k))
    ring.lineWidth = 5 * k
    color(0x55555E).setStroke()
    ring.stroke()
    let square = NSBezierPath(roundedRect: home.insetBy(dx: 27 * k, dy: 27 * k), xRadius: 6 * k, yRadius: 6 * k)
    square.lineWidth = 4 * k
    color(0x8A8A94).setStroke()
    square.stroke()
}

// MARK: Menu bar icons (template: black on transparent, 18pt)

func menuBarPhone(_ s: CGFloat, running: Bool) {
    let k = s / 18
    let body = NSRect(x: 4.5 * k, y: 1.25 * k, width: 9 * k, height: 15.5 * k)
    let radius = 2.2 * k
    NSColor.black.setFill()
    NSColor.black.setStroke()
    let ctx = NSGraphicsContext.current!.cgContext

    if running {
        NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius).fill()
        // knock out the signal and home button
        ctx.setBlendMode(.clear)
        // Only one ring fits legibly in a 9pt-wide phone at menu bar size.
        let signal = radialSignal(center: NSPoint(x: 9 * k, y: 10.6 * k), dot: 1.3 * k,
                                  radii: [3.05 * k], lineWidth: 1.25 * k, gap: 80)
        signal.dot.fill()
        signal.rings.stroke()
        NSBezierPath(ovalIn: NSRect(x: 8.1 * k, y: 2.4 * k, width: 1.8 * k, height: 1.8 * k)).fill()
        ctx.setBlendMode(.normal)
    } else {
        let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.75 * k, dy: 0.75 * k),
                                   xRadius: radius - 0.5 * k, yRadius: radius - 0.5 * k)
        outline.lineWidth = 1.5 * k
        outline.stroke()
        NSBezierPath(ovalIn: NSRect(x: 8.1 * k, y: 3.5 * k, width: 1.8 * k, height: 1.8 * k)).fill()
    }
}

// MARK: Output

let fm = FileManager.default
let iconset = "build/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    write(render(base, appIcon), "\(iconset)/icon_\(base)x\(base).png")
    write(render(base * 2, appIcon), "\(iconset)/icon_\(base)x\(base)@2x.png")
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()

for (name, running) in [("MenuBarStopped", false), ("MenuBarRunning", true)] {
    write(render(18) { menuBarPhone($0, running: running) }, "Resources/\(name).png")
    write(render(36) { menuBarPhone($0, running: running) }, "Resources/\(name)@2x.png")
}

// README previews
try? fm.createDirectory(atPath: "assets", withIntermediateDirectories: true)
write(render(512, appIcon), "assets/icon.png")
for (name, running) in [("menubar-stopped", false), ("menubar-running", true)] {
    write(render(144) { menuBarPhone($0, running: running) }, "assets/\(name).png")
    // White version for GitHub's dark theme (the README picks one with <picture>).
    write(render(144) { s in
        menuBarPhone(s, running: running)
        NSColor.white.set()
        NSRect(x: 0, y: 0, width: s, height: s).fill(using: .sourceAtop)
    }, "assets/\(name)-dark.png")
}
print("Icons written to Resources/ and assets/")
