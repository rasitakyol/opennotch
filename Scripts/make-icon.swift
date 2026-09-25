// Renders the app icon (a notch above three usage bars) and packs it into an .icns file.
// Usage: swift Scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Draws in a 1024×1024 coordinate space (origin bottom-left), following the macOS icon grid.
func drawIcon() {
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    color(0x111114).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: color(0x2C2C31), ending: color(0x0A0A0C))!.draw(in: squircle, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()

    // The notch hanging from the top edge, with the hardware's outward top flares.
    let notchWidth: CGFloat = 330, notchHeight: CGFloat = 96, flare: CGFloat = 22, radius: CGFloat = 44
    let left = body.midX - notchWidth / 2, right = body.midX + notchWidth / 2, top = body.maxY
    let notch = NSBezierPath()
    notch.move(to: NSPoint(x: left - flare, y: top))
    notch.curve(to: NSPoint(x: left, y: top - flare), controlPoint1: NSPoint(x: left, y: top), controlPoint2: NSPoint(x: left, y: top))
    notch.line(to: NSPoint(x: left, y: top - notchHeight + radius))
    notch.curve(to: NSPoint(x: left + radius, y: top - notchHeight), controlPoint1: NSPoint(x: left, y: top - notchHeight), controlPoint2: NSPoint(x: left, y: top - notchHeight))
    notch.line(to: NSPoint(x: right - radius, y: top - notchHeight))
    notch.curve(to: NSPoint(x: right, y: top - notchHeight + radius), controlPoint1: NSPoint(x: right, y: top - notchHeight), controlPoint2: NSPoint(x: right, y: top - notchHeight))
    notch.line(to: NSPoint(x: right, y: top - flare))
    notch.curve(to: NSPoint(x: right + flare, y: top), controlPoint1: NSPoint(x: right, y: top), controlPoint2: NSPoint(x: right, y: top))
    notch.close()
    NSColor.black.setFill()
    notch.fill()

    // Camera dot.
    color(0x1B1F2A).setFill()
    NSBezierPath(ovalIn: NSRect(x: body.midX - 13, y: top - notchHeight / 2 - 13, width: 26, height: 26)).fill()

    // Three usage bars: calm, busy, nearly out.
    let bars: [(CGFloat, UInt32)] = [(0.36, 0x33D66A), (0.64, 0xFFD21A), (0.9, 0xFF4D42)]
    let barWidth: CGFloat = 560, barHeight: CGFloat = 60, gap: CGFloat = 50
    let startY: CGFloat = 548
    for (index, bar) in bars.enumerated() {
        let y = startY - CGFloat(index) * (barHeight + gap)
        let track = NSRect(x: body.midX - barWidth / 2, y: y, width: barWidth, height: barHeight)
        color(0xFFFFFF, 0.1).setFill()
        NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
        let fill = NSRect(x: track.minX, y: y, width: barWidth * bar.0, height: barHeight)
        let fillPath = NSBezierPath(roundedRect: fill, xRadius: barHeight / 2, yRadius: barHeight / 2)
        NSGradient(starting: color(bar.1).blended(withFraction: 0.18, of: .white)!, ending: color(bar.1))!.draw(in: fillPath, angle: -90)
    }
    NSGraphicsContext.restoreGraphicsState()

    // Hairline edge highlight.
    color(0xFFFFFF, 0.1).setStroke()
    let edge = NSBezierPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184)
    edge.lineWidth = 3
    edge.stroke()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let scale = CGFloat(size) / 1024
    NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("OpenNotch.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try png(size: 1024).write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("png"))
print("✓ \(output)")
