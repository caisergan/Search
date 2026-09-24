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

// A · Sidebar — the app's own layout: a window, tabs down the left, the page.
func sidebar(_ size: CGFloat) -> NSImage {
    icon(size) { p, shape, s in
        gradient(shape, rgb(92, 140, 255), rgb(40, 70, 220))
        let win = p.insetBy(dx: 150 * s, dy: 170 * s)
        let r = 56 * s
        let w = NSBezierPath(roundedRect: win, xRadius: r, yRadius: r)
        shadowed(40 * s, 16 * s, 0.30) { NSColor.white.setFill(); w.fill() }
        NSGraphicsContext.saveGraphicsState(); w.addClip()
        let col = NSRect(x: win.minX, y: win.minY, width: win.width * 0.34, height: win.height)
        rgb(236, 239, 246).setFill(); NSBezierPath(rect: col).fill()
        // tabs: the live one washed, the rest as lines
        let lh = 30 * s, gap = 66 * s
        for i in 0..<4 {
            let y = win.maxY - 90 * s - CGFloat(i) * gap
            let bar = NSRect(x: col.minX + 40 * s, y: y, width: col.width - (i == 0 ? 70 : 100) * s, height: lh)
            (i == 0 ? rgb(40, 70, 220) : rgb(180, 188, 205)).setFill()
            NSBezierPath(roundedRect: bar, xRadius: lh / 2, yRadius: lh / 2).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

// B · Return — you type, you press Return, you are there.
func returnKey(_ size: CGFloat) -> NSImage {
    icon(size) { p, shape, s in
        gradient(shape, rgb(255, 250, 240), rgb(238, 228, 210))
        let path = NSBezierPath()
        let t = 92 * s
        let x1 = p.minX + 640 * s, yTop = p.minY + 640 * s, yBase = p.minY + 360 * s, x0 = p.minX + 260 * s
        path.move(to: NSPoint(x: x1, y: yTop))
        path.line(to: NSPoint(x: x1, y: yBase + 40 * s))
        path.curve(to: NSPoint(x: x1 - 40 * s, y: yBase), controlPoint1: NSPoint(x: x1, y: yBase + 18 * s), controlPoint2: NSPoint(x: x1 - 18 * s, y: yBase))
        path.line(to: NSPoint(x: x0 + 60 * s, y: yBase))
        path.lineWidth = t; path.lineCapStyle = .round; path.lineJoinStyle = .round
        let head = NSBezierPath()
        head.move(to: NSPoint(x: x0 + 170 * s, y: yBase + 120 * s))
        head.line(to: NSPoint(x: x0 + 50 * s, y: yBase))
        head.line(to: NSPoint(x: x0 + 170 * s, y: yBase - 120 * s))
        head.lineWidth = t; head.lineCapStyle = .round; head.lineJoinStyle = .round
        shadowed(20 * s, 10 * s, 0.18) {
            rgb(230, 80, 40).setStroke(); path.stroke(); head.stroke()
        }
    }
}

// C · Horizon — quiet: a low sun on a still line.
func horizon(_ size: CGFloat) -> NSImage {
    icon(size) { p, shape, s in
        NSGradient(colors: [rgb(255, 196, 150), rgb(250, 120, 110), rgb(120, 70, 160)])!.draw(in: shape, angle: -90)
        let horizonY = p.minY + p.height * 0.40
        let r = p.width * 0.24
        let sun = NSBezierPath(ovalIn: NSRect(x: p.midX - r, y: horizonY - r, width: 2 * r, height: 2 * r))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: p.minX, y: horizonY, width: p.width, height: p.height)).addClip()
        rgb(255, 248, 235).setFill(); sun.fill()
        NSGraphicsContext.restoreGraphicsState()
        rgb(60, 30, 90).setFill()
        NSBezierPath(rect: NSRect(x: p.minX, y: p.minY, width: p.width, height: horizonY - p.minY)).fill()
        // reflections
        rgb(255, 230, 210, 0.55).setFill()
        for (i, w) in [0.34, 0.22, 0.12].enumerated() {
            let ww = p.width * CGFloat(w), hh = 14 * s
            let y = horizonY - 50 * s - CGFloat(i) * 52 * s
            NSBezierPath(roundedRect: NSRect(x: p.midX - ww / 2, y: y, width: ww, height: hh), xRadius: hh / 2, yRadius: hh / 2).fill()
        }
    }
}

// D · Needle — a compass needle, pointing somewhere, nothing else.
func needle(_ size: CGFloat) -> NSImage {
    icon(size) { p, shape, s in
        gradient(shape, rgb(34, 38, 44), rgb(12, 14, 17))
        // ticks
        let c = NSPoint(x: p.midX, y: p.midY), R = p.width * 0.38
        for i in 0..<60 {
            let a = CGFloat(i) / 60 * 2 * .pi
            let long = i % 15 == 0
            let r0 = R - (long ? 44 : 22) * s
            let t = NSBezierPath()
            t.move(to: NSPoint(x: c.x + cos(a) * r0, y: c.y + sin(a) * r0))
            t.line(to: NSPoint(x: c.x + cos(a) * R, y: c.y + sin(a) * R))
            t.lineWidth = (long ? 10 : 5) * s; t.lineCapStyle = .round
            NSColor.white.withAlphaComponent(long ? 0.8 : 0.3).setStroke(); t.stroke()
        }
        let a = CGFloat.pi / 4, L = R * 0.82, W = 58 * s
        let dir = NSPoint(x: cos(a), y: sin(a)), n = NSPoint(x: -sin(a), y: cos(a))
        func pt(_ l: CGFloat, _ w: CGFloat) -> NSPoint { NSPoint(x: c.x + dir.x * l + n.x * w, y: c.y + dir.y * l + n.y * w) }
        shadowed(24 * s, 12 * s, 0.5) {
            let north = NSBezierPath(); north.move(to: pt(L, 0)); north.line(to: pt(0, W)); north.line(to: pt(0, -W)); north.close()
            rgb(255, 69, 58).setFill(); north.fill()
            let south = NSBezierPath(); south.move(to: pt(-L, 0)); south.line(to: pt(0, W)); south.line(to: pt(0, -W)); south.close()
            rgb(240, 240, 245).setFill(); south.fill()
        }
        NSColor(white: 0.1, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 16 * s, y: c.y - 16 * s, width: 32 * s, height: 32 * s)).fill()
    }
}

// E · Focus — a lens reduced to two circles: the ring, and what's in it.
func focus(_ size: CGFloat) -> NSImage {
    icon(size) { p, shape, s in
        NSGradient(colors: [rgb(20, 190, 160), rgb(10, 110, 120)])!.draw(in: shape, angle: -60)
        let c = NSPoint(x: p.midX - 30 * s, y: p.midY + 30 * s), R = p.width * 0.27
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
        ring.lineWidth = 78 * s
        let handle = NSBezierPath()
        let a = -CGFloat.pi / 4
        handle.move(to: NSPoint(x: c.x + cos(a) * (R + 30 * s), y: c.y + sin(a) * (R + 30 * s)))
        handle.line(to: NSPoint(x: c.x + cos(a) * (R + 190 * s), y: c.y + sin(a) * (R + 190 * s)))
        handle.lineWidth = 96 * s; handle.lineCapStyle = .round
        shadowed(30 * s, 14 * s, 0.25) {
            NSColor.white.setStroke(); ring.stroke(); handle.stroke()
        }
        let d = R * 0.42
        rgb(255, 214, 90).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - d, y: c.y - d, width: 2 * d, height: 2 * d)).fill()
    }
}

let concepts: [(String, (CGFloat) -> NSImage)] = [("A · Sidebar", sidebar), ("B · Return", returnKey), ("C · Horizon", horizon), ("D · Needle", needle), ("E · Focus", focus)]
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
for (i, (_, f)) in concepts.enumerated() { png(f(1024), 1024, 1024, dir.appendingPathComponent("new\(i).png")) }
print("ok")
