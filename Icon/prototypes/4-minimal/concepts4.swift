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


func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(red: r/255, green: g/255, blue: b/255, alpha: a) }
func shadowed(_ blur: CGFloat, _ dy: CGFloat, _ alpha: CGFloat, _ f: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(alpha)
    sh.shadowBlurRadius = blur; sh.shadowOffset = NSSize(width: 0, height: -dy); sh.set()
    f(); NSGraphicsContext.restoreGraphicsState()
}
func icon(_ size: CGFloat, _ f: @escaping (NSRect, NSBezierPath, CGFloat) -> Void) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let (plate, shape, s) = plateRect(size)
        dockShadow(shape, s) { f(plate, shape, s) }
        return true
    }
}


// ─── The rules every mark below follows ──────────────────────────────────
// 1. One grid: the plate is 12 units across; marks live inside the central
//    8 × 8 keyline square (circles inside its inscribed circle).
// 2. One weight: every stroke and bar is exactly 1 unit.
// 3. Three colours and no more than two per icon (plus the plate):
//    ink, paper, and one vermilion accent. No gradients, no glows, no shadows
//    on the mark — only the plate keeps the Dock's shadow.
// 4. Built from circles, squares and straight lines only; curves are arcs.
// 5. It must still be itself as a 16 px silhouette.
let INK = rgb(22, 22, 22), PAPER = rgb(244, 240, 232), RED = rgb(232, 69, 44)

struct Grid {
    let p: NSRect
    var u: CGFloat { p.width / 12 }
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: p.midX + x * u, y: p.midY + y * u) }
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat = 0) -> NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: p.midX + x * u, y: p.midY + y * u, width: w * u, height: h * u), xRadius: r * u, yRadius: r * u)
    }
    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: p.midX + (x - r) * u, y: p.midY + (y - r) * u, width: 2 * r * u, height: 2 * r * u))
    }
    func poly(_ pts: [(CGFloat, CGFloat)]) -> NSBezierPath {
        let b = NSBezierPath(); b.move(to: pt(pts[0].0, pts[0].1)); for q in pts.dropFirst() { b.line(to: pt(q.0, q.1)) }; b.close(); return b
    }
    func arc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ a0: CGFloat, _ a1: CGFloat, clockwise: Bool = false) -> NSBezierPath {
        let b = NSBezierPath(); b.appendArc(withCenter: pt(x, y), radius: r * u, startAngle: a0, endAngle: a1, clockwise: clockwise)
        b.lineWidth = u; return b
    }
}
func flat(_ size: CGFloat, _ plate: NSColor, _ f: @escaping (Grid, NSBezierPath) -> Void) -> NSImage {
    icon(size) { p, shape, _ in plate.setFill(); shape.fill(); f(Grid(p: p), shape) }
}

// 01 · Horizon — a circle and a line. Half the sun is up; the rest is the page.
func horizon(_ size: CGFloat) -> NSImage { flat(size, PAPER) { g, shape in
    NSGraphicsContext.saveGraphicsState(); g.rect(-6, -0.5, 12, 7).addClip()
    RED.setFill(); g.circle(0, -0.5, 3.5).fill()
    NSGraphicsContext.restoreGraphicsState()
    INK.setFill(); g.rect(-4, -1.5, 8, 1).fill()
} }

// 02 · Portal — an arched doorway full of light, the door swung half open into it.
func portal(_ size: CGFloat) -> NSImage { flat(size, INK) { g, _ in
    let door = g.rect(-2.5, -4, 5, 5.5); door.append(g.circle(0, 1.5, 2.5)); PAPER.setFill(); door.fill()
    RED.setFill(); g.poly([(-2.5, -4), (-2.5, 1.5), (-0.5, 2.5), (-0.5, -5)]).fill()
} }

// 03 · Beam — a lighthouse with everything taken away but the lamp and its light.
func beam(_ size: CGFloat) -> NSImage { flat(size, INK) { g, _ in
    PAPER.setFill(); g.poly([(-2.5, 0), (4.5, 2.5), (4.5, -2.5)]).fill()
    RED.setFill(); g.circle(-2.5, 0, 1.5).fill()
} }

// 04 · Fold — one sheet, folded once, going somewhere.
func fold(_ size: CGFloat) -> NSImage { flat(size, RED) { g, _ in
    PAPER.setFill(); g.poly([(-4, 0), (4, 3), (0, -1)]).fill()
    INK.setFill(); g.poly([(0, -1), (4, 3), (1, -4)]).fill()
} }

// 05 · Two Arcs — an S drawn with a compass: two half-circles, one weight.
func twoArcs(_ size: CGFloat) -> NSImage { flat(size, INK) { g, _ in
    PAPER.setStroke()
    let top = g.arc(0, 1.5, 1.5, -90, 180, clockwise: false); top.lineCapStyle = .butt
    let bottom = g.arc(0, -1.5, 1.5, 90, 360, clockwise: true)
    let s = NSBezierPath(); s.append(g.arc(0, 1.5, 1.5, 0, 270, clockwise: false)); s.lineWidth = g.u
    let s2 = g.arc(0, -1.5, 1.5, 90, -180, clockwise: true)
    _ = top; _ = bottom
    s.stroke(); s2.stroke()
    RED.setFill(); g.circle(3.5, -3.0, 0.5).fill()
} }

// 06 · Margin — the app itself: a narrow column for tabs, a wide field for the page.
func margin(_ size: CGFloat) -> NSImage { flat(size, PAPER) { g, _ in
    INK.setFill(); g.rect(-4, -4, 2, 8).fill()
    RED.setFill(); g.rect(-1, 3, 5, 1).fill()
    INK.setFill(); g.rect(-1, 0.5, 5, 1).fill(); g.rect(-1, -2, 3.5, 1).fill()
} }

// 07 · Keyhole — cut straight through the plate: what's yours stays behind it.
func keyhole(_ size: CGFloat) -> NSImage { flat(size, RED) { g, _ in
    PAPER.setFill(); g.circle(0, 1.25, 2).fill(); g.poly([(-1, 0), (1, 0), (1.75, -4), (-1.75, -4)]).fill()
} }

// 08 · Full Stop — one line you type on, one dot where you press Return. Done.
func fullStop(_ size: CGFloat) -> NSImage { flat(size, PAPER) { g, _ in
    INK.setFill(); g.rect(-4, -0.5, 6, 1, r: 0.5).fill()
    RED.setFill(); g.circle(3.5, 0, 1).fill()
} }

// 09 · Crescent — two circles, one laid over the other: quiet, and mostly night.
func crescent(_ size: CGFloat) -> NSImage { flat(size, INK) { g, _ in
    PAPER.setFill(); g.circle(-0.5, -0.5, 3.5).fill()
    INK.setFill(); g.circle(1.25, 0.75, 3).fill()
    RED.setFill(); g.circle(3.25, -3.0, 0.5).fill()
} }

// 10 · Stack — tabs down the side, one of them is where you are.
func stack(_ size: CGFloat) -> NSImage { flat(size, INK) { g, _ in
    PAPER.setFill()
    for y in [2.0, -0.5, -3.0] as [CGFloat] { g.rect(-4, y, y == 2 ? 8 : 5, 1, r: 0.5).fill() }
    RED.setFill(); g.rect(-4, 2, 8, 1, r: 0.5).fill()
    PAPER.setFill(); g.rect(-4, -0.5, 5, 1, r: 0.5).fill(); g.rect(-4, -3, 3, 1, r: 0.5).fill()
} }

let concepts: [(String, String, (CGFloat) -> NSImage)] = [
    ("01 · Horizon", "a circle, a line: half the sun is up", horizon),
    ("02 · Portal", "a door half open, the light behind", portal),
    ("03 · Beam", "the lighthouse, minus the lighthouse", beam),
    ("04 · Fold", "one sheet, folded once, going", fold),
    ("05 · Two Arcs", "an S drawn with a compass", twoArcs),
    ("06 · Margin", "a column for tabs, a field for the page", margin),
    ("07 · Keyhole", "cut through: yours stays behind it", keyhole),
    ("08 · Full Stop", "a line you type, a dot for Return", fullStop),
    ("09 · Crescent", "two circles: quiet, mostly night", crescent),
    ("10 · Stack", "tabs down the side, you are here", stack),
]
func png(_ img: NSImage, _ w: Int, _ h: Int, _ url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}


let cw: CGFloat = 360, rh: CGFloat = 470, W = cw * 5, H = rh * 2
let sheet = NSImage(size: NSSize(width: W, height: H), flipped: false) { _ in
    for (i, (name, line, f)) in concepts.enumerated() {
        let x = CGFloat(i % 5) * cw, y0 = H - CGFloat(i / 5 + 1) * rh
        NSColor(white: 0.95, alpha: 1).setFill(); NSRect(x: x, y: y0 + 130, width: cw, height: rh - 130).fill()
        NSColor(white: 0.16, alpha: 1).setFill(); NSRect(x: x, y: y0, width: cw, height: 130).fill()
        f(1024).draw(in: NSRect(x: x + 30, y: y0 + 125, width: 300, height: 300))
        (name as NSString).draw(at: NSPoint(x: x + 24, y: y0 + rh - 34), withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor(white: 0.15, alpha: 1)])
        (line as NSString).draw(at: NSPoint(x: x + 24, y: y0 + rh - 56), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(white: 0.45, alpha: 1)])
        var cx = x + 24
        for px in [96, 64, 32, 16] as [CGFloat] { f(px).draw(in: NSRect(x: cx, y: y0 + 60 - px / 2, width: px, height: px)); cx += px + 14 }
    }
    return true
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
png(sheet, Int(W), Int(H), dir.appendingPathComponent("sheet.png"))
for (i, (name, _, f)) in concepts.enumerated() {
    let slug = name.lowercased().replacingOccurrences(of: " · ", with: "-").replacingOccurrences(of: " ", with: "-")
    png(f(1024), 1024, 1024, dir.appendingPathComponent("\(slug).png")); _ = i
}
print("ok")
