// Generates build/AppIcon.icns: deep-sea gradient rounded rect + sailboat.
// Run:  swift Scripts/generate_icon.swift && iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
import AppKit

let iconsetPath = "build/AppIcon.iconset"
try FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func render(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let size = CGFloat(pixels)
    // macOS icon grid: content inset ~10%, corner radius ~18.5% of full size
    let inset = size * 0.10
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.185, yRadius: size * 0.185)
    NSGradient(
        starting: NSColor(calibratedRed: 0.10, green: 0.22, blue: 0.42, alpha: 1),
        ending: NSColor(calibratedRed: 0.02, green: 0.06, blue: 0.16, alpha: 1)
    )!.draw(in: path, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: size * 0.40, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "sailboat.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size, flipped: false) { drawRect in
            symbol.draw(in: drawRect)
            NSColor.white.set()
            drawRect.fill(using: .sourceAtop)
            return true
        }
        let symbolSize = tinted.size
        let origin = NSPoint(x: (size - symbolSize.width) / 2, y: (size - symbolSize.height) / 2)
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for (suffix, scale) in [("", 1), ("@2x", 2)] {
        let rep = render(pixels: base * scale)
        let png = rep.representation(using: .png, properties: [:])!
        try png.write(to: URL(fileURLWithPath: "\(iconsetPath)/icon_\(base)x\(base)\(suffix).png"))
    }
}
print("Wrote \(iconsetPath)")
