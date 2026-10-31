import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("NetSpeed.iconset")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 512, y: CGFloat(pixels) / 512)
        let rect = NSRect(x: 28, y: 28, width: 456, height: 456)
        let background = NSBezierPath(roundedRect: rect, xRadius: 112, yRadius: 112)
        NSGradient(starting: NSColor(srgbRed: 0.11, green: 0.18, blue: 0.28, alpha: 1),
                   ending: NSColor(srgbRed: 0.04, green: 0.08, blue: 0.15, alpha: 1))!.draw(in: background, angle: -90)
        for (x, upward, color) in [(CGFloat(181), false, NSColor(srgbRed: 0.27, green: 0.87, blue: 0.75, alpha: 1)),
                                   (CGFloat(331), true, NSColor(srgbRed: 0.39, green: 0.66, blue: 1, alpha: 1))] {
            let arrow = NSBezierPath()
            arrow.lineWidth = 30
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            let tip: CGFloat = upward ? 354 : 158
            let tail: CGFloat = upward ? 158 : 354
            let shoulder: CGFloat = upward ? 296 : 216
            arrow.move(to: NSPoint(x: x, y: tail))
            arrow.line(to: NSPoint(x: x, y: tip))
            arrow.move(to: NSPoint(x: x - 51, y: shoulder))
            arrow.line(to: NSPoint(x: x, y: tip))
            arrow.line(to: NSPoint(x: x + 51, y: shoulder))
            color.setStroke()
            arrow.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(filename))
    }
}
