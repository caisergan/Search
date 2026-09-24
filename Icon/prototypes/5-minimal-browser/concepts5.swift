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


// The same rules as set 4. What's new: every mark borrows one sign people
// already read as "the web" — a globe, a tab, the address bar, the window's
// three buttons, back and forward, a link, a pointer.
extension Grid {
    func ring(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> NSBezierPath { let b = circle(x, y, r - 0.5); b.lineWidth = u; return b }
    func ellipse(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> NSBezierPath {
        let b = NSBezierPath(ovalIn: NSRect(x: p.midX + (x - rx) * u, y: p.midY + (y - ry) * u, width: 2 * rx * u, height: 2 * ry * u)); b.lineWidth = u; return b
    }
    func line(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat), round: Bool = false) -> NSBezierPath {
        let l = NSBezierPath(); l.move(to: pt(a.0, a.1)); l.line(to: pt(b.0, b.1)); l.lineWidth = u
        l.lineCapStyle = round ? .round : .butt; l.lineJoinStyle = round ? .round : .miter; return l
    }
    func polyline(_ pts: [(CGFloat, CGFloat)]) -> NSBezierPath {
        let l = NSBezierPath(); l.move(to: pt(pts[0].0, pts[0].1)); for q in pts.dropFirst() { l.line(to: pt(q.0, q.1)) }
        l.lineWidth = u; l.lineCapStyle = .round; l.lineJoinStyle = .round; return l
    }
    /// The S as two arcs of radius r, stacked, centred on (x, y).
    func sCurve(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> NSBezierPath {
        let b = NSBezierPath()
        b.appendArc(withCenter: pt(x, y + r), radius: r * u, startAngle: 20, endAngle: 270, clockwise: false)
        b.appendArc(withCenter: pt(x, y - r), radius: r * u, startAngle: 90, endAngle: -160, clockwise: true)
        b.lineWidth = u; b.lineCapStyle = .butt; return b
    }
    /// A globe: the outline, one meridian, the equator.
    func globe(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: NSColor) {
        c.setStroke(); ring(x, y, r).stroke(); ellipse(x, y, r * 0.42, r - 0.5).stroke(); line((x - r + 0.5, y), (x + r - 0.5, y)).stroke()
    }
}

// 01 · Meridian — a globe whose meridian is an S: the web, and our name in it.
func meridian(_ size: CGFloat) -> NSImage { flat(size, INK) { g, _ in
    PAPER.setStroke(); g.ring(0, 0, 4).stroke()
    RED.setStroke(); g.sCurve(0, 0, 1.25).stroke()
} }

// 02 · Horizon Globe — the half-sun from set 4, now the lit half of a globe.
func horizonGlobe(_ size: CGFloat) -> NSImage { flat(size, PAPER) { g, _ in
    NSGraphicsContext.saveGraphicsState(); g.rect(-6, 0, 12, 6).addClip(); RED.setFill(); g.circle(0, 0, 4).fill(); NSGraphicsContext.restoreGraphicsState()
    INK.setStroke(); g.ring(0, 0, 4).stroke(); g.ellipse(0, 0, 1.7, 3.5).stroke(); g.line((-4, 0), (4, 0)).stroke()
} }

// 03 · Address — the full stop from set 4 inside the one field: type, Return.
func address(_ size: CGFloat) -> NSImage { flat(size, INK) { g, _ in
    PAPER.setStroke(); let pill = g.rect(-4.5, -1.75, 9, 3.5, r: 1.75); pill.lineWidth = g.u; pill.stroke()
    PAPER.setFill(); g.rect(-2.75, -0.5, 3.5, 1, r: 0.5).fill()
    RED.setFill(); g.circle(2.25, 0, 0.75).fill()
} }

// 04 · Tab — the shape every browser shares: a tab that flares into the page below it.
func tab(_ size: CGFloat) -> NSImage { flat(size, RED) { g, _ in
    PAPER.setFill()
    g.rect(-4.5, -4, 9, 3, r: 0.75).fill()                 // the page's top edge
    g.rect(-3, -1.5, 4.5, 3.5, r: 0.75).fill()             // the live tab
    g.rect(-3.75, -1.25, 6, 0.5).fill()                    // its foot, then the two flares
    RED.setFill(); g.circle(-3.75, -0.5, 0.75).fill(); g.circle(2.25, -0.5, 0.75).fill()
    INK.setFill(); g.rect(-2, 0.25, 2.5, 0.5, r: 0.25).fill()
} }

// 05 · Window — the Mac window, reduced: three buttons, a column of tabs, the page.
func window(_ size: CGFloat) -> NSImage { flat(size, PAPER) { g, _ in
    INK.setStroke(); let w = g.rect(-4.5, -3.5, 9, 7, r: 1); w.lineWidth = g.u; w.stroke()
    INK.setFill(); g.rect(-0.75, -3.5, 1, 7).fill()
    for (i, c) in [RED, INK, INK].enumerated() { c.setFill(); g.circle(-3.1 + CGFloat(i) * 0.9, 2.1, 0.35).fill() }
} }

// 06 · Pointer — the arrow you move all day, resting on the world.
func pointer(_ size: CGFloat) -> NSImage { flat(size, INK) { g, _ in
    g.globe(-0.75, 0.75, 3.5, PAPER)
    let arrow = g.poly([(0.5, -0.25), (0.5, -4.25), (1.5, -3.25), (2.25, -4.75), (3.0, -4.35), (2.25, -2.85), (3.75, -2.75)])
    INK.setStroke(); arrow.lineWidth = g.u * 0.9; arrow.lineJoinStyle = .round; arrow.stroke()
    RED.setFill(); arrow.fill()
} }

// 07 · Back · Forward — the two buttons that mean "browser" to everyone.
func backForward(_ size: CGFloat) -> NSImage { flat(size, PAPER) { g, _ in
    INK.setStroke(); g.polyline([(-0.75, 2.5), (-3.25, 0), (-0.75, -2.5)]).stroke()
    RED.setStroke(); g.polyline([(0.75, 2.5), (3.25, 0), (0.75, -2.5)]).stroke()
} }

// 08 · Link — two rings holding on to each other: the thing the web is made of.
func link(_ size: CGFloat) -> NSImage { flat(size, INK) { g, _ in
    let a = g.rect(-4, -1.5, 5, 3, r: 1.5), b = g.rect(-1, -1.5, 5, 3, r: 1.5)
    a.lineWidth = g.u; b.lineWidth = g.u
    var t = AffineTransform(translationByX: -g.p.midX, byY: -g.p.midY); t.append(AffineTransform(rotationByDegrees: 45)); t.append(AffineTransform(translationByX: g.p.midX, byY: g.p.midY))
    a.transform(using: t); b.transform(using: t)
    PAPER.setStroke(); a.stroke(); RED.setStroke(); b.stroke()
    // re-draw a's crossing so the rings interlock
    NSGraphicsContext.saveGraphicsState(); g.rect(-6, -6, 6, 6).addClip(); PAPER.setStroke(); a.stroke(); NSGraphicsContext.restoreGraphicsState()
} }

// 09 · Private Globe — the keyhole from set 4 cut into the world: the web, but yours.
func privateGlobe(_ size: CGFloat) -> NSImage { flat(size, RED) { g, _ in
    PAPER.setFill(); g.circle(0, 0, 4).fill()
    RED.setFill(); g.circle(0, 0.9, 1.3).fill(); g.poly([(-0.65, 0.2), (0.65, 0.2), (1.1, -2.4), (-1.1, -2.4)]).fill()
} }

// 10 · Lens — a magnifier whose glass is a globe: search, the web.
func lens(_ size: CGFloat) -> NSImage { flat(size, PAPER) { g, _ in
    g.globe(-0.75, 0.75, 3.25, INK)
    RED.setStroke(); g.line((1.5, -1.5), (3.75, -3.75), round: true).stroke()
} }

let concepts: [(String, String, (CGFloat) -> NSImage)] = [
    ("01 · Meridian", "a globe whose meridian is an S", meridian),
    ("02 · Horizon Globe", "the half-sun, now the lit half of a globe", horizonGlobe),
    ("03 · Address", "the one field: type, Return", address),
    ("04 · Tab", "one tab and the page it opens", tab),
    ("05 · Window", "three buttons, a column of tabs, the page", window),
    ("06 · Pointer", "your arrow, resting on the world", pointer),
    ("07 · Back · Forward", "the two buttons that mean browser", backForward),
    ("08 · Link", "two rings holding on: what the web is", link),
    ("09 · Private Globe", "the world, with a keyhole in it", privateGlobe),
    ("10 · Lens", "a magnifier whose glass is a globe", lens),
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
