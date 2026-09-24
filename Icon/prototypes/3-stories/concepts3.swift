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


func P(_ p: NSRect, _ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: p.minX + x * p.width, y: p.minY + y * p.height) }
func poly(_ p: NSRect, _ pts: [(CGFloat, CGFloat)]) -> NSBezierPath {
    let b = NSBezierPath(); b.move(to: P(p, pts[0].0, pts[0].1)); for q in pts.dropFirst() { b.line(to: P(p, q.0, q.1)) }; b.close(); return b
}
func oval(_ p: NSRect, _ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat? = nil) -> NSBezierPath {
    let ry = ry ?? rx
    return NSBezierPath(ovalIn: NSRect(x: p.minX + (cx - rx) * p.width, y: p.minY + (cy - ry) * p.height, width: 2 * rx * p.width, height: 2 * ry * p.height))
}
func rect(_ p: NSRect, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat = 0) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: p.minX + x * p.width, y: p.minY + y * p.height, width: w * p.width, height: h * p.height), xRadius: r * p.width, yRadius: r * p.width)
}
func sky(_ shape: NSBezierPath, _ cs: [NSColor]) { NSGradient(colors: cs)!.draw(in: shape, angle: -90) }
func hills(_ p: NSRect, _ y: CGFloat, _ amp: CGFloat, _ phase: CGFloat, _ c: NSColor) {
    let b = NSBezierPath(); b.move(to: P(p, -0.1, -0.1)); b.line(to: P(p, -0.1, y))
    b.curve(to: P(p, 0.5, y + amp * 0.3), controlPoint1: P(p, 0.1 + phase, y + amp), controlPoint2: P(p, 0.3 + phase, y + amp))
    b.curve(to: P(p, 1.1, y), controlPoint1: P(p, 0.7 - phase, y - amp * 0.4), controlPoint2: P(p, 0.9, y + amp * 0.5))
    b.line(to: P(p, 1.1, -0.1)); b.close(); c.setFill(); b.fill()
}
func dots(_ p: NSRect, _ pts: [(CGFloat, CGFloat, CGFloat)], _ c: NSColor) { c.setFill(); for d in pts { oval(p, d.0, d.1, d.2).fill() } }
func cloud(_ p: NSRect, _ x: CGFloat, _ y: CGFloat, _ k: CGFloat, _ c: NSColor) {
    c.setFill()
    oval(p, x, y, 0.09 * k, 0.07 * k).fill(); oval(p, x + 0.09 * k, y - 0.01 * k, 0.07 * k, 0.055 * k).fill(); oval(p, x - 0.09 * k, y - 0.015 * k, 0.06 * k, 0.045 * k).fill()
    rect(p, x - 0.15 * k, y - 0.06 * k, 0.31 * k, 0.05 * k, r: 0.025 * k).fill()
}
func waves(_ p: NSRect, _ y: CGFloat, _ c: NSColor, _ n: Int = 4) {
    let b = NSBezierPath(); b.move(to: P(p, -0.05, -0.1)); b.line(to: P(p, -0.05, y))
    let w = 1.1 / CGFloat(n)
    for i in 0..<n {
        let x0 = -0.05 + CGFloat(i) * w
        b.curve(to: P(p, x0 + w, y), controlPoint1: P(p, x0 + w * 0.3, y + 0.035), controlPoint2: P(p, x0 + w * 0.7, y - 0.035))
    }
    b.line(to: P(p, 1.05, -0.1)); b.close(); c.setFill(); b.fill()
}
func glow(_ p: NSRect, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ c: NSColor) {
    NSGradient(starting: c, ending: c.withAlphaComponent(0))!.draw(in: oval(p, cx, cy, r), relativeCenterPosition: .zero)
}

// 01 · Paper Plane — you throw a few words; they loop once and land where you meant.
func plane(_ size: CGFloat) -> NSImage { icon(size) { p, shape, s in
    sky(shape, [rgb(120, 190, 255), rgb(200, 230, 255)])
    cloud(p, 0.28, 0.25, 1.1, NSColor.white.withAlphaComponent(0.85))
    let t = NSBezierPath(); t.move(to: P(p, 0.08, 0.42))
    t.curve(to: P(p, 0.40, 0.46), controlPoint1: P(p, 0.22, 0.38), controlPoint2: P(p, 0.40, 0.30))
    t.curve(to: P(p, 0.56, 0.60), controlPoint1: P(p, 0.40, 0.62), controlPoint2: P(p, 0.52, 0.62))
    t.lineWidth = 16 * s; t.lineCapStyle = .round; t.setLineDash([2 * s, 40 * s], count: 2, phase: 0)
    NSColor.white.setStroke(); t.stroke()
    shadowed(24 * s, 14 * s, 0.25) {
        NSColor.white.setFill(); poly(p, [(0.90, 0.80), (0.52, 0.58), (0.66, 0.54)]).fill()
        rgb(220, 232, 245).setFill(); poly(p, [(0.90, 0.80), (0.66, 0.54), (0.70, 0.40)]).fill()
        rgb(180, 200, 225).setFill(); poly(p, [(0.90, 0.80), (0.66, 0.54), (0.64, 0.47)]).fill()
    }
} }

// 02 · Lighthouse — a dark sea of noise, one steady beam showing the way.
func lighthouse(_ size: CGFloat) -> NSImage { icon(size) { p, shape, s in
    sky(shape, [rgb(20, 30, 70), rgb(50, 60, 120)])
    dots(p, [(0.15, 0.85, 0.008), (0.3, 0.72, 0.006), (0.85, 0.9, 0.007), (0.75, 0.62, 0.005), (0.55, 0.88, 0.006)], NSColor.white.withAlphaComponent(0.8))
    NSGradient(starting: rgb(255, 235, 160, 0.75), ending: rgb(255, 235, 160, 0))!.draw(in: poly(p, [(0.42, 0.66), (1.1, 0.88), (1.1, 0.52)]), angle: 0)
    waves(p, 0.20, rgb(15, 22, 50), 3)
    hills(p, 0.26, 0.04, 0.05, rgb(10, 14, 32))
    let tower = poly(p, [(0.33, 0.24), (0.51, 0.24), (0.47, 0.60), (0.37, 0.60)])
    NSColor(white: 0.95, alpha: 1).setFill(); tower.fill()
    NSGraphicsContext.saveGraphicsState(); tower.addClip()
    rgb(230, 70, 60).setFill(); rect(p, 0.2, 0.34, 0.5, 0.07).fill(); rect(p, 0.2, 0.48, 0.5, 0.07).fill()
    NSGraphicsContext.restoreGraphicsState()
    rgb(30, 30, 40).setFill(); rect(p, 0.35, 0.60, 0.14, 0.02).fill(); poly(p, [(0.35, 0.72), (0.49, 0.72), (0.42, 0.79)]).fill()
    glow(p, 0.42, 0.66, 0.14, rgb(255, 230, 150, 0.9))
    rgb(255, 240, 180).setFill(); rect(p, 0.37, 0.62, 0.10, 0.10, r: 0.01).fill()
} }

// 03 · Open Door — a dark room, a door left open, the page is the light beyond it.
func door(_ size: CGFloat) -> NSImage { icon(size) { p, shape, s in
    gradient(shape, rgb(52, 44, 70), rgb(28, 22, 40))
    NSGradient(starting: rgb(255, 214, 140, 0.8), ending: rgb(255, 214, 140, 0))!.draw(in: poly(p, [(0.34, 0.24), (0.66, 0.24), (0.95, -0.05), (0.02, -0.05)]), angle: -90)
    rgb(255, 232, 180).setFill(); rect(p, 0.34, 0.24, 0.32, 0.54).fill()
    // the door, swung in
    rgb(120, 70, 50).setFill(); poly(p, [(0.34, 0.24), (0.34, 0.78), (0.20, 0.84), (0.20, 0.16)]).fill()
    rgb(230, 190, 90).setFill(); oval(p, 0.24, 0.50, 0.012).fill()
    // a figure in the doorway, small
    rgb(40, 30, 50).setFill(); oval(p, 0.53, 0.52, 0.035).fill(); rect(p, 0.505, 0.24, 0.05, 0.24, r: 0.02).fill()
} }

// 04 · Telescope — a quiet hill at night, one star found.
func telescope(_ size: CGFloat) -> NSImage { icon(size) { p, shape, s in
    sky(shape, [rgb(10, 20, 50), rgb(40, 50, 110), rgb(90, 80, 150)])
    dots(p, [(0.12, 0.88, 0.006), (0.25, 0.70, 0.005), (0.45, 0.92, 0.005), (0.6, 0.75, 0.004), (0.9, 0.6, 0.005), (0.18, 0.55, 0.004)], NSColor.white.withAlphaComponent(0.7))
    glow(p, 0.80, 0.82, 0.12, rgb(255, 230, 150, 0.8))
    rgb(255, 240, 190).setFill()
    let st = NSBezierPath(); let c = P(p, 0.80, 0.82)
    for i in 0..<8 { let a = CGFloat(i) * .pi / 4 + .pi / 2; let r = (i % 2 == 0 ? 0.06 : 0.018) * p.width
        let q = NSPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r); i == 0 ? st.move(to: q) : st.line(to: q) }
    st.close(); st.fill()
    hills(p, 0.22, 0.10, 0.08, rgb(18, 22, 45))
    rgb(210, 200, 240).setStroke()
    for (a, b) in [((0.38, 0.30), (0.33, 0.20)), ((0.38, 0.30), (0.44, 0.20))] as [((CGFloat, CGFloat), (CGFloat, CGFloat))] {
        let l = NSBezierPath(); l.move(to: P(p, a.0, a.1)); l.line(to: P(p, b.0, b.1)); l.lineWidth = 12 * s; l.stroke() }
    let tube = NSBezierPath(); tube.move(to: P(p, 0.30, 0.28)); tube.line(to: P(p, 0.62, 0.52))
    tube.lineWidth = 50 * s; tube.lineCapStyle = .round; rgb(210, 200, 240).setStroke(); tube.stroke()
    let lens = NSBezierPath(); lens.move(to: P(p, 0.55, 0.47)); lens.line(to: P(p, 0.66, 0.555)); lens.lineWidth = 64 * s; lens.stroke()
} }

// 05 · Balloon — three megabytes: light enough to rise above the rest.
func balloon(_ size: CGFloat) -> NSImage { icon(size) { p, shape, s in
    sky(shape, [rgb(255, 214, 180), rgb(190, 225, 250)])
    cloud(p, 0.22, 0.18, 1.3, NSColor.white); cloud(p, 0.82, 0.30, 0.9, NSColor.white.withAlphaComponent(0.9))
    let env = NSBezierPath(); let top = P(p, 0.55, 0.88)
    env.move(to: P(p, 0.48, 0.42))
    env.curve(to: top, controlPoint1: P(p, 0.26, 0.58), controlPoint2: P(p, 0.28, 0.88))
    env.curve(to: P(p, 0.62, 0.42), controlPoint1: P(p, 0.82, 0.88), controlPoint2: P(p, 0.84, 0.58))
    env.close()
    shadowed(20 * s, 10 * s, 0.15) { rgb(240, 90, 70).setFill(); env.fill() }
    NSGraphicsContext.saveGraphicsState(); env.addClip()
    rgb(255, 240, 225).setFill(); rect(p, 0.475, 0.3, 0.05, 0.7).fill(); rect(p, 0.575, 0.3, 0.05, 0.7).fill()
    NSGraphicsContext.restoreGraphicsState()
    rgb(90, 60, 40).setStroke()
    for (a, b) in [((0.49, 0.42), (0.51, 0.34)), ((0.61, 0.42), (0.59, 0.34))] as [((CGFloat, CGFloat), (CGFloat, CGFloat))] {
        let l = NSBezierPath(); l.move(to: P(p, a.0, a.1)); l.line(to: P(p, b.0, b.1)); l.lineWidth = 6 * s; l.stroke() }
    rgb(140, 90, 50).setFill(); rect(p, 0.50, 0.28, 0.10, 0.07, r: 0.012).fill()
} }

// 06 · Paper Boat — small, folded by hand, out on a big calm sea at night.
func boat(_ size: CGFloat) -> NSImage { icon(size) { p, shape, s in
    sky(shape, [rgb(12, 40, 70), rgb(30, 80, 120)])
    glow(p, 0.74, 0.76, 0.16, rgb(255, 250, 220, 0.5)); rgb(255, 250, 225).setFill(); oval(p, 0.74, 0.76, 0.075).fill()
    rgb(12, 40, 70).setFill(); oval(p, 0.77, 0.79, 0.07).fill()
    shadowed(12 * s, 6 * s, 0.3) {
        NSColor.white.setFill(); poly(p, [(0.22, 0.44), (0.78, 0.44), (0.66, 0.30), (0.34, 0.30)]).fill()
        rgb(225, 232, 240).setFill(); poly(p, [(0.50, 0.70), (0.34, 0.44), (0.66, 0.44)]).fill()
        rgb(200, 210, 225).setFill(); poly(p, [(0.50, 0.70), (0.50, 0.44), (0.66, 0.44)]).fill()
    }
    waves(p, 0.32, rgb(20, 70, 110, 0.95), 3)
    waves(p, 0.20, rgb(10, 45, 80), 4)
} }

// 07 · Winding Road — a path through the hills to the one place you were going.
func road(_ size: CGFloat) -> NSImage { icon(size) { p, shape, s in
    sky(shape, [rgb(255, 200, 120), rgb(255, 230, 190)])
    rgb(255, 250, 235).setFill(); oval(p, 0.5, 0.66, 0.10).fill()
    hills(p, 0.56, 0.06, 0.1, rgb(140, 190, 120))
    hills(p, 0.40, 0.10, -0.05, rgb(90, 160, 100))
    hills(p, 0.22, 0.08, 0.06, rgb(50, 120, 80))
    let r = NSBezierPath()
    r.move(to: P(p, 0.30, -0.05))
    r.curve(to: P(p, 0.62, 0.34), controlPoint1: P(p, 0.40, 0.15), controlPoint2: P(p, 0.85, 0.22))
    r.curve(to: P(p, 0.50, 0.56), controlPoint1: P(p, 0.40, 0.44), controlPoint2: P(p, 0.40, 0.50))
    r.lineWidth = 60 * s; r.lineCapStyle = .round; rgb(250, 235, 200).setStroke(); r.stroke()
    let c = r.copy() as! NSBezierPath; c.lineWidth = 8 * s; c.setLineDash([28 * s, 30 * s], count: 2, phase: 0); rgb(230, 170, 90).setStroke(); c.stroke()
} }

// 08 · Curtains — drawn back: nothing left in the way of the page.
func curtains(_ size: CGFloat) -> NSImage { icon(size) { p, shape, s in
    gradient(shape, rgb(150, 30, 50), rgb(90, 15, 30))
    shadowed(30 * s, 0, 0.5) { NSColor.white.setFill(); rect(p, 0.22, 0.18, 0.56, 0.62, r: 0.03).fill() }
    rgb(210, 215, 225).setFill(); rect(p, 0.30, 0.66, 0.30, 0.04, r: 0.02).fill()
    for (i, w) in [0.40, 0.36, 0.40, 0.28].enumerated() { rgb(225, 228, 235).setFill(); rect(p, 0.30, 0.54 - CGFloat(i) * 0.07, CGFloat(w), 0.025, r: 0.012).fill() }
    for left in [true, false] {
        let c = NSBezierPath(); let x0: CGFloat = left ? 0.0 : 1.0, xi: CGFloat = left ? 0.26 : 0.74, xt: CGFloat = left ? 0.12 : 0.88
        c.move(to: P(p, x0, 1.0)); c.line(to: P(p, xi, 1.0))
        c.curve(to: P(p, xt, 0.40), controlPoint1: P(p, xi, 0.70), controlPoint2: P(p, xt + (left ? 0.08 : -0.08), 0.50))
        c.curve(to: P(p, x0 + (left ? 0.16 : -0.16), 0.0), controlPoint1: P(p, xt - (left ? 0.02 : -0.02), 0.25), controlPoint2: P(p, x0 + (left ? 0.2 : -0.2), 0.10))
        c.line(to: P(p, x0, 0)); c.close()
        shadowed(24 * s, 0, 0.45) { rgb(200, 40, 60).setFill(); c.fill() }
        rgb(230, 180, 80).setFill(); rect(p, xt - 0.06, 0.39, 0.12, 0.03, r: 0.015).fill()
    }
    rgb(230, 180, 80).setFill(); rect(p, 0, 0.92, 1, 0.03).fill()
} }

// 09 · Kite — held by one string: it flies on its own but stays yours.
func kite(_ size: CGFloat) -> NSImage { icon(size) { p, shape, s in
    sky(shape, [rgb(80, 180, 240), rgb(170, 225, 250)])
    cloud(p, 0.25, 0.72, 0.9, NSColor.white.withAlphaComponent(0.9)); cloud(p, 0.78, 0.22, 1.1, NSColor.white.withAlphaComponent(0.8))
    let str = NSBezierPath(); str.move(to: P(p, 0.58, 0.46))
    str.curve(to: P(p, 0.10, -0.05), controlPoint1: P(p, 0.50, 0.25), controlPoint2: P(p, 0.20, 0.25))
    str.lineWidth = 5 * s; NSColor.white.setStroke(); str.stroke()
    let tail = NSBezierPath(); tail.move(to: P(p, 0.58, 0.46))
    tail.curve(to: P(p, 0.74, 0.14), controlPoint1: P(p, 0.72, 0.38), controlPoint2: P(p, 0.56, 0.24))
    tail.lineWidth = 5 * s; rgb(40, 40, 60).setStroke(); tail.stroke()
    for (x, y) in [(0.66, 0.35), (0.63, 0.25), (0.70, 0.17)] as [(CGFloat, CGFloat)] { rgb(255, 200, 60).setFill(); poly(p, [(x - 0.03, y + 0.02), (x + 0.03, y - 0.02), (x + 0.03, y + 0.02), (x - 0.03, y - 0.02)]).fill() }
    shadowed(20 * s, 10 * s, 0.2) {
        rgb(250, 80, 90).setFill(); poly(p, [(0.62, 0.88), (0.44, 0.66), (0.62, 0.66)]).fill(); poly(p, [(0.62, 0.66), (0.80, 0.66), (0.58, 0.46)]).fill()
        rgb(255, 200, 60).setFill(); poly(p, [(0.62, 0.88), (0.80, 0.66), (0.62, 0.66)]).fill(); poly(p, [(0.44, 0.66), (0.62, 0.66), (0.58, 0.46)]).fill()
    }
} }

// 10 · Keyhole — the room is yours: light comes in, nothing looks out.
func keyhole(_ size: CGFloat) -> NSImage { icon(size) { p, shape, s in
    gradient(shape, rgb(70, 60, 55), rgb(40, 34, 30))
    shadowed(0, 0, 0) {
        rgb(200, 160, 90).setFill(); rect(p, 0.30, 0.16, 0.40, 0.68, r: 0.20).fill()
        rgb(170, 130, 70).setFill(); rect(p, 0.33, 0.19, 0.34, 0.62, r: 0.17).fill()
    }
    let hole = oval(p, 0.5, 0.58, 0.085); hole.append(poly(p, [(0.46, 0.56), (0.54, 0.56), (0.575, 0.30), (0.425, 0.30)]))
    hole.windingRule = .nonZero
    NSGraphicsContext.saveGraphicsState(); hole.addClip()
    NSGradient(colors: [rgb(255, 200, 120), rgb(140, 200, 255)])!.draw(in: hole.bounds, angle: 90)
    rgb(255, 250, 230).setFill(); oval(p, 0.53, 0.64, 0.03).fill()
    NSGraphicsContext.restoreGraphicsState()
} }

let concepts: [(String, String, (CGFloat) -> NSImage)] = [
    ("01 · Paper Plane", "a few words, thrown; they land", plane),
    ("02 · Lighthouse", "one steady beam over the noise", lighthouse),
    ("03 · Open Door", "the page is the light beyond", door),
    ("04 · Telescope", "a quiet hill, one star found", telescope),
    ("05 · Balloon", "light enough to rise", balloon),
    ("06 · Paper Boat", "small, handmade, calm sea", boat),
    ("07 · Winding Road", "the path to where you meant", road),
    ("08 · Curtains", "drawn back: nothing in the way", curtains),
    ("09 · Kite", "flies free, stays yours", kite),
    ("10 · Keyhole", "light comes in, no one looks out", keyhole),
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
