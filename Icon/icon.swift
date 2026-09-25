// The app's icon, drawn rather than exported: three concentric rings on a
// whiteish plate, in light blue. They are drawn as circles, so they stay a
// crisp vector at every size instead of a raster scaled up.

import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// The mark: three rings, centred on a 1024 canvas, each an outer and an
/// inner radius.
let rings: [(outer: CGFloat, inner: CGFloat)] = [
    (300, 246.154),
    (200, 161.538),
    (115.385, 92.308),
]

/// The rings as one path. Six concentric circles filled even-odd are three
/// rings: the band inside each outer radius and outside its inner one.
func ringsPath(_ s: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.windingRule = .evenOdd
    for ring in rings {
        for r in [ring.outer, ring.inner] {
            path.appendOval(in: NSRect(x: (512 - r) * s, y: (512 - r) * s, width: 2 * r * s, height: 2 * r * s))
        }
    }
    return path
}

func rgb(_ hex: Int) -> NSColor {
    NSColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func draw(_ size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    // Apple's grid: the shape takes 824 of 1024, and its corners are 22.37%.
    let s = size / 1024
    let plate = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let radius = 824 * 0.2237 * s
    let shape = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    // A soft shadow under the plate, the way every icon on the Dock has one.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = rgb(0x0B1D33).withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // The plate fades from white at the top to a breath of blue at the
    // bottom; the rings run from light sky at the top to a deeper azure.
    // An angle of 90 draws a gradient from the bottom up.
    NSGradient(starting: rgb(0xEAF2FB), ending: .white)!.draw(in: shape, angle: 90)
    NSGradient(starting: rgb(0x3B8BE8), ending: rgb(0x86C6FF))!.draw(in: ringsPath(s), angle: 90)
    return image
}

func write(_ image: NSImage, to url: URL, pixels: Int) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff)
    else { return }
    // The bitmap is asked for at the pixel size, whatever the screen thinks.
    let sized = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    sized.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sized)
    NSGraphicsContext.current?.imageInterpolation = .high
    rep.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = sized.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let image = draw(CGFloat(pixels))
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        write(image, to: out.appendingPathComponent(name), pixels: pixels)
    }
}
print("drew: \(out.path)")
