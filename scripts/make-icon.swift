import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let background = NSColor(srgbRed: 0.045, green: 0.075, blue: 0.085, alpha: 1)
let accent = NSColor(srgbRed: 0.88, green: 0.98, blue: 0.54, alpha: 1)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        NSColor.clear.setFill(); bounds.fill()
        let unit = CGFloat(pixels) / 1024
        background.setFill()
        NSBezierPath(roundedRect: NSRect(x: 40 * unit, y: 40 * unit, width: 944 * unit, height: 944 * unit), xRadius: 212 * unit, yRadius: 212 * unit).fill()
        // An original flowing S, drawn from vector curves at every output size.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current!.cgContext.scaleBy(x: unit, y: unit)
        accent.setStroke()
        let mark = NSBezierPath()
        mark.lineWidth = 88; mark.lineCapStyle = .round; mark.lineJoinStyle = .round
        mark.move(to: NSPoint(x: 740, y: 704))
        mark.curve(to: NSPoint(x: 364, y: 682), controlPoint1: NSPoint(x: 638, y: 792), controlPoint2: NSPoint(x: 446, y: 778))
        mark.curve(to: NSPoint(x: 386, y: 522), controlPoint1: NSPoint(x: 266, y: 590), controlPoint2: NSPoint(x: 286, y: 540))
        mark.line(to: NSPoint(x: 606, y: 482))
        mark.curve(to: NSPoint(x: 626, y: 324), controlPoint1: NSPoint(x: 712, y: 462), controlPoint2: NSPoint(x: 734, y: 408))
        mark.curve(to: NSPoint(x: 264, y: 340), controlPoint1: NSPoint(x: 532, y: 250), controlPoint2: NSPoint(x: 366, y: 266))
        mark.stroke()
        NSGraphicsContext.restoreGraphicsState()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not render icon") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
