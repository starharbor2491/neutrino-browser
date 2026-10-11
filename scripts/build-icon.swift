// SPDX-License-Identifier: MPL-2.0
import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create icon bitmap") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        NSColor(calibratedRed: 0.35, green: 0.25, blue: 0.64, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: CGFloat(pixels) * 0.045, dy: CGFloat(pixels) * 0.045), xRadius: CGFloat(pixels) * 0.21, yRadius: CGFloat(pixels) * 0.21).fill()
        let star = NSBezierPath()
        let c = CGFloat(pixels) * 0.5, reach = CGFloat(pixels) * 0.30, inner = CGFloat(pixels) * 0.075
        star.move(to: NSPoint(x: c, y: c + reach))
        star.curve(to: NSPoint(x: c + reach, y: c), controlPoint1: NSPoint(x: c + inner, y: c + inner), controlPoint2: NSPoint(x: c + inner, y: c + inner))
        star.curve(to: NSPoint(x: c, y: c - reach), controlPoint1: NSPoint(x: c + inner, y: c - inner), controlPoint2: NSPoint(x: c + inner, y: c - inner))
        star.curve(to: NSPoint(x: c - reach, y: c), controlPoint1: NSPoint(x: c - inner, y: c - inner), controlPoint2: NSPoint(x: c - inner, y: c - inner))
        star.curve(to: NSPoint(x: c, y: c + reach), controlPoint1: NSPoint(x: c - inner, y: c + inner), controlPoint2: NSPoint(x: c - inner, y: c + inner))
        star.close(); NSColor.white.setFill(); star.fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot render icon") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
