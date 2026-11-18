import AppKit

// Finder uses point coordinates; render at 2× for Retina displays.
let width = 660, height = 420
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2,
    pixelsHigh: height * 2, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedWhite: 0.965, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
func label(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, shade: CGFloat) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    (text as NSString).draw(in: NSRect(x: 24, y: y, width: 612, height: 44), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(calibratedWhite: shade, alpha: 1),
        .paragraphStyle: paragraph
    ])
}
label("JSONic", y: 327, size: 30, weight: .semibold, shade: 0.13)
label("Перетащите JSONic в «Программы»", y: 292, size: 16, weight: .regular, shade: 0.42)
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 302, y: 209))
arrow.line(to: NSPoint(x: 358, y: 209))
arrow.move(to: NSPoint(x: 345, y: 222))
arrow.line(to: NSPoint(x: 358, y: 209))
arrow.line(to: NSPoint(x: 345, y: 196))
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(calibratedWhite: 0.58, alpha: 1).setStroke()
arrow.stroke()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
