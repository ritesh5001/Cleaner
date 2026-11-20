// Renders Resources/AppIcon.icns: a Liquid-Glass-style sparkle on an indigo→teal squircle.
// Usage: swift scripts/make-icon.swift <output-dir>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824/1024 body, continuous-corner squircle.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    // Drop shadow
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Background gradient
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor(calibratedRed: 0.35, green: 0.30, blue: 0.95, alpha: 1),
                        NSColor(calibratedRed: 0.55, green: 0.25, blue: 0.85, alpha: 1),
                        NSColor(calibratedRed: 0.10, green: 0.75, blue: 0.80, alpha: 1)])!
        .draw(in: body, angle: -60)
    // Glass highlight on the top half
    let gloss = NSBezierPath(ovalIn: NSRect(x: body.minX - body.width * 0.2, y: body.midY,
                                            width: body.width * 1.4, height: body.height * 0.9))
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0.0)])!
        .draw(in: gloss, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Inner rim light
    NSColor.white.withAlphaComponent(0.25).setStroke()
    path.lineWidth = max(1, s * 0.006)
    path.stroke()

    // Sparkles symbol
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let sz = symbol.size
        let r = NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2 - s * 0.01, width: sz.width, height: sz.height)
        let glow = NSShadow()
        glow.shadowColor = NSColor.white.withAlphaComponent(0.6)
        glow.shadowBlurRadius = s * 0.04
        NSGraphicsContext.saveGraphicsState()
        glow.set()
        symbol.draw(in: r)
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
print(iconset.path)
