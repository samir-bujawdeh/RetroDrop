// Draws the disk image window background. Run from the repo root:
//   swift scripts/make-dmg-background.swift
// Writes Resources/dmg-background.tiff (600x400 window, with a Retina 2x copy inside).
// Icon positions in scripts/dmg-settings.py must match: app at (150, 200), Applications at (450, 200).
import AppKit

let size = NSSize(width: 600, height: 400)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func draw() {
    // Warm cream paper
    NSGradient(starting: color(0xFBF3E6), ending: color(0xF3E3CC))!
        .draw(in: NSRect(origin: .zero, size: size), angle: -90)

    // Retro sunset stripes along the bottom (same colours as the app icon)
    let stripes: [(UInt32, CGFloat)] = [(0xF6C445, 34), (0xEE8A3A, 24), (0xD9483B, 14), (0x8E2F55, 0)]
    for (hex, y) in stripes {
        color(hex).setFill()
        NSRect(x: 0, y: y, width: size.width, height: y == 0 ? 14 : 10).fill()
    }

    // Title
    let title = NSAttributedString(string: "Drag RetroDrop to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 22, weight: .bold),
        .foregroundColor: color(0x3A2340),
    ])
    title.draw(at: NSPoint(x: (size.width - title.size().width) / 2, y: size.height - 62))

    let sub = NSAttributedString(string: "Then open it from Applications. It lives in your menu bar.", attributes: [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: color(0x6B4A5E),
    ])
    sub.draw(at: NSPoint(x: (size.width - sub.size().width) / 2, y: size.height - 86))

    // Curved arrow between the two icons (icon centres at y=200 from the top -> 200 from the bottom)
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 240, y: 214))
    arrow.curve(to: NSPoint(x: 352, y: 214), controlPoint1: NSPoint(x: 272, y: 244), controlPoint2: NSPoint(x: 320, y: 244))
    arrow.lineWidth = 6
    arrow.lineCapStyle = .round
    color(0xE0703A).setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 336, y: 232))
    head.line(to: NSPoint(x: 356, y: 210))
    head.line(to: NSPoint(x: 328, y: 206))
    head.lineWidth = 6
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                               pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size  // points, so the 2x copy is treated as Retina
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try! FileManager.default.createDirectory(atPath: "build", withIntermediateDirectories: true)
for (scale, name) in [(1.0, "build/dmg-bg.png"), (2.0, "build/dmg-bg@2x.png")] {
    try! render(scale: scale).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: name))
}
// Combine into one multi-resolution TIFF, which Finder picks the right size from.
let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck", "build/dmg-bg.png", "build/dmg-bg@2x.png", "-out", "Resources/dmg-background.tiff"]
try! tiffutil.run()
tiffutil.waitUntilExit()
print("Wrote Resources/dmg-background.tiff")
