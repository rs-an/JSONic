import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
func drawIcon(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    ctx.cgContext.scaleBy(x: CGFloat(size)/1024, y: CGFloat(size)/1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 205, yRadius: 205)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = color(0.12, 0.05, 0.23, 0.35); shadow.shadowBlurRadius = 25; shadow.shadowOffset = NSSize(width: 0, height: -10); shadow.set()
    color(0.29, 0.15, 0.49).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0.31,0.16,0.55), ending: color(0.66,0.40,0.85))!.draw(in: tile, angle: 65)
    color(1,1,1,0.22).setStroke(); tile.lineWidth = 3; tile.stroke()
    // Two generous braces frame three log lines. No overlapping pictograms.
    let brace = NSBezierPath()
    brace.move(to: NSPoint(x: 337, y: 758))
    brace.curve(to: NSPoint(x: 270, y: 680), controlPoint1: NSPoint(x: 280, y: 758), controlPoint2: NSPoint(x: 270, y: 734))
    brace.line(to: NSPoint(x: 270, y: 601))
    brace.curve(to: NSPoint(x: 219, y: 512), controlPoint1: NSPoint(x: 270, y: 544), controlPoint2: NSPoint(x: 255, y: 522))
    brace.curve(to: NSPoint(x: 270, y: 423), controlPoint1: NSPoint(x: 255, y: 502), controlPoint2: NSPoint(x: 270, y: 480))
    brace.line(to: NSPoint(x: 270, y: 344))
    brace.curve(to: NSPoint(x: 337, y: 266), controlPoint1: NSPoint(x: 270, y: 290), controlPoint2: NSPoint(x: 280, y: 266))
    brace.lineWidth = 57; brace.lineCapStyle = .round; brace.lineJoinStyle = .round
    color(0.98,0.96,1).setStroke(); brace.stroke()
    var mirror = AffineTransform(); mirror.translate(x: 1024, y: 0); mirror.scale(x: -1, y: 1)
    brace.transform(using: mirror); brace.stroke()
    for (y, width) in [(646.0, 204.0), (512.0, 270.0), (378.0, 154.0)] {
        let line = NSBezierPath(roundedRect: NSRect(x: 377, y: y - 27, width: width, height: 54), xRadius: 27, yRadius: 27)
        (y == 512 ? color(0.44, 0.94, 0.87) : color(0.94, 0.86, 1, 0.80)).setFill()
        line.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for base in [16,32,128,256,512] {
    for scale in [1,2] {
        let name = "icon_\(base)x\(base)" + (scale == 2 ? "@2x" : "") + ".png"
        try drawIcon(size: base*scale).write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(size: 1024).write(to: root.appendingPathComponent("Assets/AppIcon.png"))

// ICNS container with PNG representations, including Retina variants.
func bigEndian(_ value: Int) -> Data {
    var v = UInt32(value).bigEndian
    return withUnsafeBytes(of: &v) { Data($0) }
}
var chunks = Data()
for (tag, size) in [("icp4",16),("icp5",32),("icp6",64),("ic07",128),("ic08",256),("ic09",512),("ic10",1024),("ic11",32),("ic12",64),("ic13",256),("ic14",512)] {
    let png = drawIcon(size: size)
    chunks.append(Data(tag.utf8)); chunks.append(bigEndian(png.count + 8)); chunks.append(png)
}
var icns = Data("icns".utf8); icns.append(bigEndian(chunks.count + 8)); icns.append(chunks)
try icns.write(to: root.appendingPathComponent("Assets/AppIcon.icns"))
