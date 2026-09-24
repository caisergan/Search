// The app's icon, drawn rather than exported: the mark is Drice's
// Subtract.svg, read from its own path data rather than loaded as an image,
// so it stays a crisp vector at every size instead of a raster scaled up.
// The icon puts it on a plate — a Dock icon has to be an opaque square
// whether the logo itself wants a background or not.

import AppKit




/// Drice's Subtract.svg (22 September 2026): a pill with an S cut out of it,
/// on its own 608 × 276 canvas. The same path is in Design.swift's
/// `Logomark` and in the website's mark — one shape, three places.
let canvas = (width: 608.0, height: 276.0)
let markData = "M469.443 0C545.471 0.00013198 607.103 61.6325 607.104 137.66C607.104 213.688 545.471 275.321 469.443 275.321H137.66C61.6323 275.321 0 213.688 0 137.66C0.00016085 61.6325 61.6325 0.000140192 137.66 0H469.443ZM138.104 51.5977C127.234 51.5977 117.512 53.5115 108.938 57.3389C100.518 61.0132 93.8581 66.2188 88.959 72.9551C84.2132 79.5381 81.8398 87.3464 81.8398 96.3789C81.8399 105.258 83.6773 112.607 87.3516 118.425C91.0258 124.089 95.9251 128.682 102.049 132.203C108.173 135.571 114.833 138.327 122.028 140.471L151.652 149.197C158.389 151.188 163.9 154.249 168.187 158.383C172.473 162.516 174.617 168.028 174.617 174.917C174.617 182.572 171.402 188.849 164.972 193.748C158.695 198.494 150.122 200.867 139.252 200.867C132.21 200.867 125.702 199.413 119.731 196.504C113.914 193.442 109.091 189.308 105.264 184.103C101.436 178.744 99.2169 172.697 98.6045 165.961H97.6855L75.4102 171.013C76.3287 180.658 79.697 189.308 85.5146 196.963C91.3322 204.618 98.9103 210.665 108.249 215.104C117.741 219.544 128.076 221.765 139.252 221.765C151.193 221.765 161.68 219.774 170.713 215.794C179.746 211.813 186.711 206.225 191.61 199.029C196.662 191.834 199.188 183.414 199.188 173.769C199.188 164.124 197.352 156.239 193.678 150.115C190.003 143.838 185.104 138.863 178.98 135.188C172.857 131.514 166.044 128.605 158.542 126.462L128.229 117.735C121.799 115.898 116.516 113.219 112.383 109.698C108.402 106.177 106.412 101.354 106.412 95.2305C106.412 88.188 109.168 82.6758 114.68 78.6953C120.344 74.5619 128.152 72.4951 138.104 72.4951C147.901 72.4952 155.939 74.9448 162.216 79.8438C168.493 84.7428 172.397 91.1729 173.928 99.1338H174.847L196.663 93.8525C195.745 85.5853 192.605 78.3131 187.247 72.0361C181.889 65.6061 174.923 60.6306 166.35 57.1094C157.929 53.4351 148.514 51.5977 138.104 51.5977Z"

/// A tiny reader for the one path the mark is: absolute M, L, H, V, C, Z —
/// what Figma writes for a flattened shape, and nothing else.
func svgCommands(_ d: String) -> [(Character, [CGFloat])] {
    var out: [(Character, [CGFloat])] = []
    var current: Character?
    var numbers: [CGFloat] = []
    var token = ""
    func flushNumber() {
        if !token.isEmpty, let v = Double(token) { numbers.append(CGFloat(v)) }
        token = ""
    }
    for ch in d {
        if "MLHVCZmlhvcz".contains(ch) {
            flushNumber()
            if let current { out.append((current, numbers)) }
            current = ch
            numbers = []
        } else if ch == " " || ch == "," {
            flushNumber()
        } else if ch == "-" && !token.isEmpty && !token.hasSuffix("e") {
            flushNumber()
            token = "-"
        } else {
            token.append(ch)
        }
    }
    flushNumber()
    if let current { out.append((current, numbers)) }
    return out
}

/// The mark, fit to `fraction` of `plate`'s width and centred on it. SVG's y
/// grows downward and AppKit's upward, so every y is flipped on the way in;
/// the S is a hole, so the path is filled even-odd.
func markPath(in plate: NSRect, fraction: CGFloat) -> NSBezierPath {
    let scale = plate.width * fraction / canvas.width
    let ox = plate.midX - canvas.width * scale / 2
    let oy = plate.midY - canvas.height * scale / 2
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: ox + x * scale, y: oy + (canvas.height - y) * scale)
    }
    let path = NSBezierPath()
    path.windingRule = .evenOdd
    var last = NSPoint.zero
    var start = NSPoint.zero
    for (c, n) in svgCommands(markData) {
        switch c {
        case "M": last = NSPoint(x: n[0], y: n[1]); start = last; path.move(to: pt(n[0], n[1]))
        case "L": last = NSPoint(x: n[0], y: n[1]); path.line(to: pt(n[0], n[1]))
        case "H": last.x = n[0]; path.line(to: pt(last.x, last.y))
        case "V": last.y = n[0]; path.line(to: pt(last.x, last.y))
        case "C":
            var k = 0
            while k + 5 < n.count {
                path.curve(to: pt(n[k + 4], n[k + 5]), controlPoint1: pt(n[k], n[k + 1]), controlPoint2: pt(n[k + 2], n[k + 3]))
                last = NSPoint(x: n[k + 4], y: n[k + 5])
                k += 6
            }
        case "Z": path.close(); last = start
        default: break
        }
    }
    return path
}


let ink = NSColor(red: 0.09, green: 0.09, blue: 0.09, alpha: 1)

func plateRect(_ size: CGFloat) -> (NSRect, NSBezierPath, CGFloat) {
    let s = size / 1024
    let plate = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let r = 824 * 0.2237 * s
    return (plate, NSBezierPath(roundedRect: plate, xRadius: r, yRadius: r), s)
}

func dockShadow(_ shape: NSBezierPath, _ s: CGFloat, fill: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor.black.withAlphaComponent(0.22)
    sh.shadowBlurRadius = 24 * s
    sh.shadowOffset = NSSize(width: 0, height: -10 * s)
    sh.set()
    NSColor.black.setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState(); shape.addClip(); fill(); NSGraphicsContext.restoreGraphicsState()
}

func gradient(_ shape: NSBezierPath, _ top: NSColor, _ bottom: NSColor) {
    NSGradient(starting: bottom, ending: top)!.draw(in: shape, angle: 90)
}

/// A mark whose pill is `fraction` of the plate wide, shifted by dx (in plate widths).
func mark(_ plate: NSRect, _ fraction: CGFloat, dx: CGFloat = 0) -> NSBezierPath {
    let p = markPath(in: plate, fraction: fraction)
    p.transform(using: AffineTransform(translationByX: dx * plate.width, byY: 0))
    return p
}

// The S's own bounds inside the mark: x 75…199, y 51…222 on the 608×276 canvas.
func sRightEdge(_ plate: NSRect, _ fraction: CGFloat, dx: CGFloat = 0) -> (x: CGFloat, y0: CGFloat, y1: CGFloat) {
    let scale = plate.width * fraction / canvas.width
    let ox = plate.midX - canvas.width * scale / 2 + dx * plate.width
    let oy = plate.midY - canvas.height * scale / 2
    return (ox + 232 * scale, oy + (276 - 214) * scale, oy + (276 - 62) * scale)
}

// 1 · Ink — the plate goes dark, the mark goes white and bigger.
func ink1(_ size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let (plate, shape, s) = plateRect(size)
        dockShadow(shape, s) {
            gradient(shape, NSColor(white: 0.20, alpha: 1), NSColor(white: 0.07, alpha: 1))
            NSColor.white.withAlphaComponent(0.10).setStroke()
            let rim = NSBezierPath(roundedRect: plate.insetBy(dx: 1.5 * s, dy: 1.5 * s), xRadius: 824 * 0.2237 * s, yRadius: 824 * 0.2237 * s)
            rim.lineWidth = 3 * s; rim.stroke()
            NSColor(white: 0.97, alpha: 1).setFill()
            mark(plate, 0.80).fill()
        }
        return true
    }
}

// 2 · Bleed — the pill is too big for the plate and runs off the right;
// what's left is a huge S at the start of a field.
func bleed(_ size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let (plate, shape, s) = plateRect(size)
        dockShadow(shape, s) {
            gradient(shape, .white, NSColor(white: 0.93, alpha: 1))
            ink.setFill()
            mark(plate, 1.45, dx: 0.40).fill()
        }
        return true
    }
}

// 3 · Field — a white field on graphite, the S in it and a caret waiting.
func field(_ size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let (plate, shape, s) = plateRect(size)
        dockShadow(shape, s) {
            gradient(shape, NSColor(white: 0.30, alpha: 1), NSColor(white: 0.12, alpha: 1))
            let f: CGFloat = 0.84
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.35)
            sh.shadowBlurRadius = 30 * s; sh.shadowOffset = NSSize(width: 0, height: -12 * s); sh.set()
            NSColor.white.setFill(); mark(plate, f).fill()
            NSGraphicsContext.restoreGraphicsState()
            // the caret
            let e = sRightEdge(plate, f)
            let w = max(26 * s, 1.5)
            let caret = NSBezierPath(roundedRect: NSRect(x: e.x + 18 * s, y: e.y0, width: w, height: e.y1 - e.y0), xRadius: w / 2, yRadius: w / 2)
            NSColor(red: 0.16, green: 0.45, blue: 1.0, alpha: 1).setFill(); caret.fill()
        }
        return true
    }
}

// 4 · Paper — Tahoe-ish: a soft light plate, the mark in ink with a little depth.
func paper(_ size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let (plate, shape, s) = plateRect(size)
        dockShadow(shape, s) {
            gradient(shape, NSColor(white: 0.99, alpha: 1), NSColor(white: 0.86, alpha: 1))
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.30)
            sh.shadowBlurRadius = 18 * s; sh.shadowOffset = NSSize(width: 0, height: -8 * s); sh.set()
            let m = mark(plate, 0.84)
            ink.setFill(); m.fill()
            NSGraphicsContext.restoreGraphicsState()
            // top-lit sheen on the pill
            NSGraphicsContext.saveGraphicsState(); m.addClip()
            NSGradient(starting: NSColor.white.withAlphaComponent(0.0), ending: NSColor.white.withAlphaComponent(0.16))!.draw(in: m.bounds, angle: 90)
            NSGraphicsContext.restoreGraphicsState()
        }
        return true
    }
}


// 5 · Caret — no pill at all: the plate is the field, a big S and the caret after it.
func sOnly(_ plate: NSRect, height: CGFloat, centerX: CGFloat) -> NSBezierPath {
    let d = markData[markData.range(of: "ZM")!.upperBound...]
    let saved = markData
    _ = saved
    // build from the S subpath alone, using markPath's reader on a 608×276 canvas
    let full = markPath(in: plate, fraction: 1)
    _ = full
    let path = NSBezierPath()
    var last = NSPoint.zero
    for (c, n) in svgCommands("M" + d) {
        switch c {
        case "M": last = NSPoint(x: n[0], y: -n[1]); path.move(to: last)
        case "H": last.x = n[0]; path.line(to: last)
        case "V": last.y = -n[0]; path.line(to: last)
        case "L": last = NSPoint(x: n[0], y: -n[1]); path.line(to: last)
        case "C":
            var k = 0
            while k + 5 < n.count {
                path.curve(to: NSPoint(x: n[k+4], y: -n[k+5]), controlPoint1: NSPoint(x: n[k], y: -n[k+1]), controlPoint2: NSPoint(x: n[k+2], y: -n[k+3]))
                last = NSPoint(x: n[k+4], y: -n[k+5]); k += 6
            }
        case "Z": path.close()
        default: break
        }
    }
    let b = path.bounds
    let k = height / b.height
    var t = AffineTransform(translationByX: -b.midX, byY: -b.midY)
    t.append(AffineTransform(scaleByX: k, byY: k))
    t.append(AffineTransform(translationByX: centerX, byY: plate.midY))
    path.transform(using: t)
    return path
}

func caret(_ size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let (plate, shape, s) = plateRect(size)
        dockShadow(shape, s) {
            gradient(shape, NSColor(white: 0.20, alpha: 1), NSColor(white: 0.07, alpha: 1))
            let h = plate.height * 0.56
            let S = sOnly(plate, height: h, centerX: plate.midX - plate.width * 0.08)
            NSColor(white: 0.97, alpha: 1).setFill(); S.fill()
            let w = 40 * s
            NSColor(red: 0.16, green: 0.45, blue: 1.0, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: S.bounds.maxX + 44 * s, y: plate.midY - h * 0.56, width: w, height: h * 1.12), xRadius: w / 2, yRadius: w / 2).fill()
        }
        return true
    }
}

func current(_ size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let (plate, shape, s) = plateRect(size)
        dockShadow(shape, s) { NSColor.white.setFill(); shape.fill(); ink.setFill(); mark(plate, 0.754).fill() }
        return true
    }
}

let concepts: [(String, (CGFloat) -> NSImage)] = [("Today", current), ("1 · Ink", ink1), ("2 · Bleed", bleed), ("3 · Field", field), ("4 · Paper", paper), ("5 · Caret", caret)]

func png(_ img: NSImage, _ w: Int, _ h: Int, _ url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// A sheet: one column per concept — big, then Dock sizes on dark and light.
let col: CGFloat = 360, W = col * CGFloat(concepts.count), H: CGFloat = 640
let sheet = NSImage(size: NSSize(width: W, height: H), flipped: false) { _ in
    NSColor(white: 0.16, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: 300).fill()
    NSColor(white: 0.95, alpha: 1).setFill(); NSRect(x: 0, y: 300, width: W, height: H - 300).fill()
    for (i, (name, f)) in concepts.enumerated() {
        let x = CGFloat(i) * col
        f(1024).draw(in: NSRect(x: x + 20, y: 300, width: 320, height: 320))
        (name as NSString).draw(at: NSPoint(x: x + 24, y: 604), withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor(white: 0.2, alpha: 1)])
        // Dock sizes on dark: 128, 64, 32, 16 — each drawn at its real pixel size
        var cx = x + 20
        for px in [128, 64, 32, 16] as [CGFloat] {
            f(px).draw(in: NSRect(x: cx, y: 150 - px / 2, width: px, height: px))
            cx += px + 12
        }
        // and small on light
        cx = x + 20
        for px in [64, 32, 16] as [CGFloat] {
            f(px).draw(in: NSRect(x: cx, y: 250 - px / 2 + 10, width: px, height: px))
            cx += px + 12
        }
    }
    return true
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
png(sheet, Int(W), Int(H), dir.appendingPathComponent("sheet.png"))
for (i, (_, f)) in concepts.enumerated() { png(f(1024), 1024, 1024, dir.appendingPathComponent("concept\(i).png")) }
print("ok")
