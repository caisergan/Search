import SwiftUI
import AppKit

// Lifted from Office Inspiration, with the ground turned white: there the work
// floats on an off-white canvas, here the page *is* the ground and everything
// the browser draws has to get out of its way.
//
// Every colour is a pair — one for a light window, one for a dark — and
// resolves itself against whatever appearance the window has. The window
// takes its appearance from the app, and the app from Settings ›
// Customization › Appearance: light, dark, or whatever the Mac is doing.
// Nothing else in the code knows which it is.
enum Palette {
    static let ground = Color(nsColor: NS.ground)
    static let ink = Color(nsColor: NS.ink)             // neutral-900 · neutral-100
    static let muted = Color(nsColor: NS.muted)         // neutral-500
    static let faint = Color(nsColor: NS.faint)         // neutral-300 · neutral-700
    static let hairline = Color(nsColor: NS.hairline)   // neutral-200 · neutral-800
    static let wash = Color(nsColor: NS.wash)           // the live tab
    static let hover = Color(nsColor: NS.hover)         // the one under the pointer
    /// The only two that aren't grey: a connection nobody can read on the
    /// way, and one anybody can (see SiteCard.swift).
    static let safe = Color(nsColor: NS.safe)           // green-700 · green-400
    static let unsafe = Color(nsColor: NS.unsafe)       // amber-700 · amber-400

    /// The same colours for the AppKit corners of the app — a text field's
    /// ink, a window's background — which want an NSColor and keep it.
    enum NS {
        static let ground = pair(1.0, 0.11)
        static let ink = pair(0.09, 0.93)
        /// Like the wash below, ink laid thinly rather than greys of their
        /// own: the same greys over the ground, and over a theme's colour a
        /// lighter or darker shade of it — a fixed grey there has nothing to
        /// stand out against and goes under.
        static let muted = veil(0.45, 0.53)
        static let faint = veil(0.17, 0.24)
        static let hairline = veil(0.09, 0.10)
        /// Ink laid thinly over whatever is behind, rather than a grey of
        /// their own: over the ground they come out exactly the greys they
        /// always were (0.937 and 0.965 light, 0.175 and 0.15 dark), and over
        /// a theme's glass they let its colour through instead of sitting on
        /// it as grey patches.
        static let wash = veil(0.063, 0.073)
        static let hover = veil(0.035, 0.045)
        /// The resting traffic lights, drawn by hand when the app is behind.
        static let resting = pair(0.80, 0.30)
        static let safe = tint(light: (0.08, 0.50, 0.24), dark: (0.29, 0.87, 0.50))
        static let unsafe = tint(light: (0.71, 0.33, 0.04), dark: (0.98, 0.75, 0.14))

        private static func tint(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
            NSColor(name: nil) { appearance in
                let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
            }
        }

        private static func pair(_ light: CGFloat, _ dark: CGFloat) -> NSColor {
            NSColor(name: nil) { appearance in
                let dim = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(white: dim ? dark : light, alpha: 1)
            }
        }

        /// Black over a light window, white over a dark one, this thick.
        private static func veil(_ light: CGFloat, _ dark: CGFloat) -> NSColor {
            NSColor(name: nil) { appearance in
                let dim = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(white: dim ? 1 : 0, alpha: dim ? dark : light)
            }
        }
    }
}

/// What the window is made of around the page. Plain is the white (or
/// black) it always was. The rest are glass: the desktop shows through the
/// tabs and the bar, blurred, coloured by the theme, and the page sits on it
/// as a card with rounded corners — the one opaque thing in the window.
///
/// The colour comes four ways: none, for plain glass; one hue laid evenly;
/// a gradient of two or three colours across the window; or glows, soft
/// spots of colour on a deeper ground, the richest of them. Each is stored
/// by its name, so a theme can be added anywhere in the list.
enum Theme: String, CaseIterable, Identifiable {
    case plain, glass
    // Hues
    case graphite, slate, sand, coral, rose, crimson, amber, lime, sage, teal, sky, indigo, violet, mauve
    // Gradients
    case dusk, sunset, sherbet, peach, citrus, tropic, mint, forest, glacier, lagoon, ocean, aurora, twilight, orchid, plum, berry, candy, cherry, ember, nebula, midnight
    // Glows
    case nova, borealis, reef, dream, prism, sunrise, velvet, lava, cosmos,
         bloom, halo, iris, mirage, opal, solstice, tidal, flare, jade, sorbet
    // Dark
    case eclipse, abyss, noir, obsidian, ink, smoulder, moss

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plain: return "Plain"
        case .glass: return "Glass"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    /// The kinds, in the order the picker shows them.
    enum Family: CaseIterable {
        case basic, hue, gradient, glow, dark

        var title: String {
            switch self {
            case .basic: return "Basic"
            case .hue: return "Hues"
            case .gradient: return "Gradients"
            case .glow: return "Glows"
            case .dark: return "Dark"
            }
        }

        var themes: [Theme] { Theme.allCases.filter { $0.family == self } }
    }

    var family: Family {
        switch paint {
        case .none: return .basic
        case .hue: return .hue
        case .linear: return .gradient
        case .glow: return .glow
        case .dark: return .dark
        }
    }

    /// Everything but plain lets the desktop through.
    var isGlass: Bool { self != .plain }

    /// How a theme's colour is laid over the blur.
    enum Paint {
        case none
        case hue(Color)
        /// Colours evenly spaced from one point of the window to another.
        case linear([Color], from: UnitPoint, to: UnitPoint)
        /// A ground, and spots of colour on it, each fading out from its
        /// point.
        case glow(ground: Color, spots: [(Color, UnitPoint)])
        /// A ground nearly black, lit at its edges by glows that stop well
        /// short of the middle — the desktop all but gone behind it.
        case dark(ground: Color, spots: [(Color, UnitPoint)])
    }

    var paint: Paint {
        func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
        switch self {
        case .plain, .glass: return .none

        case .graphite: return .hue(rgb(0.30, 0.32, 0.36))
        case .rose: return .hue(rgb(0.93, 0.36, 0.50))
        case .amber: return .hue(rgb(0.96, 0.62, 0.18))
        case .lime: return .hue(rgb(0.52, 0.80, 0.26))
        case .teal: return .hue(rgb(0.12, 0.66, 0.64))
        case .sky: return .hue(rgb(0.30, 0.64, 0.96))
        case .indigo: return .hue(rgb(0.34, 0.36, 0.90))
        case .violet: return .hue(rgb(0.62, 0.38, 0.92))
        case .slate: return .hue(rgb(0.36, 0.44, 0.56))
        case .sand: return .hue(rgb(0.84, 0.72, 0.52))
        case .coral: return .hue(rgb(1.00, 0.50, 0.40))
        case .crimson: return .hue(rgb(0.82, 0.12, 0.24))
        case .sage: return .hue(rgb(0.54, 0.66, 0.52))
        case .mauve: return .hue(rgb(0.72, 0.52, 0.68))

        case .dusk: return .linear([rgb(0.95, 0.58, 0.30), rgb(0.80, 0.34, 0.40)], from: .topLeading, to: .bottomTrailing)
        case .sunset: return .linear([rgb(1.00, 0.66, 0.26), rgb(0.95, 0.33, 0.45), rgb(0.50, 0.24, 0.66)], from: .top, to: .bottom)
        case .peach: return .linear([rgb(1.00, 0.78, 0.60), rgb(0.98, 0.52, 0.52)], from: .topLeading, to: .bottomTrailing)
        case .citrus: return .linear([rgb(0.98, 0.86, 0.28), rgb(0.98, 0.54, 0.16)], from: .topLeading, to: .bottomTrailing)
        case .mint: return .linear([rgb(0.60, 0.94, 0.76), rgb(0.24, 0.72, 0.70)], from: .top, to: .bottom)
        case .forest: return .linear([rgb(0.36, 0.64, 0.42), rgb(0.16, 0.40, 0.32)], from: .topLeading, to: .bottomTrailing)
        case .lagoon: return .linear([rgb(0.20, 0.86, 0.86), rgb(0.12, 0.44, 0.84)], from: .topLeading, to: .bottomTrailing)
        case .ocean: return .linear([rgb(0.22, 0.60, 0.82), rgb(0.14, 0.30, 0.66)], from: .topLeading, to: .bottomTrailing)
        case .aurora: return .linear([rgb(0.30, 0.90, 0.60), rgb(0.16, 0.62, 0.78), rgb(0.52, 0.34, 0.90)], from: .topLeading, to: .bottomTrailing)
        case .orchid: return .linear([rgb(0.66, 0.46, 0.88), rgb(0.90, 0.46, 0.66)], from: .topLeading, to: .bottomTrailing)
        case .berry: return .linear([rgb(0.86, 0.22, 0.56), rgb(0.44, 0.18, 0.62)], from: .top, to: .bottom)
        case .candy: return .linear([rgb(0.98, 0.56, 0.78), rgb(0.56, 0.72, 0.98)], from: .topLeading, to: .bottomTrailing)
        case .ember: return .linear([rgb(0.96, 0.44, 0.16), rgb(0.62, 0.10, 0.14)], from: .top, to: .bottom)
        case .nebula: return .linear([rgb(0.60, 0.30, 0.86), rgb(0.26, 0.20, 0.64), rgb(0.08, 0.08, 0.22)], from: .topLeading, to: .bottomTrailing)
        case .midnight: return .linear([rgb(0.24, 0.26, 0.48), rgb(0.08, 0.09, 0.20)], from: .topLeading, to: .bottomTrailing)
        case .sherbet: return .linear([rgb(1.00, 0.70, 0.36), rgb(1.00, 0.50, 0.62), rgb(0.72, 0.60, 0.96)], from: .topLeading, to: .bottomTrailing)
        case .tropic: return .linear([rgb(0.98, 0.88, 0.30), rgb(0.40, 0.84, 0.44), rgb(0.10, 0.62, 0.66)], from: .top, to: .bottom)
        case .glacier: return .linear([rgb(0.86, 0.96, 1.00), rgb(0.50, 0.80, 0.92), rgb(0.26, 0.56, 0.72)], from: .top, to: .bottom)
        case .twilight: return .linear([rgb(0.10, 0.14, 0.40), rgb(0.46, 0.24, 0.62), rgb(0.96, 0.46, 0.60)], from: .top, to: .bottom)
        case .plum: return .linear([rgb(0.52, 0.22, 0.52), rgb(0.26, 0.10, 0.32)], from: .topLeading, to: .bottomTrailing)
        case .cherry: return .linear([rgb(1.00, 0.52, 0.66), rgb(0.80, 0.08, 0.22)], from: .topLeading, to: .bottomTrailing)

        case .nova: return .glow(ground: rgb(0.18, 0.08, 0.30), spots: [
            (rgb(1.00, 0.42, 0.62), .topLeading), (rgb(0.40, 0.46, 1.00), .bottomTrailing), (rgb(1.00, 0.70, 0.30), .bottomLeading),
        ])
        case .borealis: return .glow(ground: rgb(0.04, 0.14, 0.20), spots: [
            (rgb(0.24, 0.96, 0.62), .top), (rgb(0.30, 0.56, 1.00), .bottomLeading), (rgb(0.66, 0.36, 0.96), .trailing),
        ])
        case .reef: return .glow(ground: rgb(0.02, 0.24, 0.34), spots: [
            (rgb(1.00, 0.50, 0.42), .topTrailing), (rgb(0.16, 0.86, 0.80), .leading), (rgb(1.00, 0.84, 0.40), .bottom),
        ])
        case .dream: return .glow(ground: rgb(0.86, 0.80, 0.96), spots: [
            (rgb(0.98, 0.64, 0.82), .topLeading), (rgb(0.62, 0.78, 1.00), .trailing), (rgb(0.78, 0.66, 1.00), .bottom),
        ])
        case .lava: return .glow(ground: rgb(0.20, 0.03, 0.04), spots: [
            (rgb(1.00, 0.36, 0.10), .bottomLeading), (rgb(0.96, 0.12, 0.30), .topTrailing), (rgb(1.00, 0.72, 0.20), .center),
        ])
        case .cosmos: return .glow(ground: rgb(0.03, 0.03, 0.10), spots: [
            (rgb(0.38, 0.20, 0.90), .topLeading), (rgb(0.10, 0.60, 0.90), .bottomTrailing), (rgb(0.90, 0.24, 0.70), .trailing),
        ])
        case .prism: return .glow(ground: rgb(0.10, 0.10, 0.18), spots: [
            (rgb(1.00, 0.30, 0.40), .topLeading), (rgb(1.00, 0.86, 0.30), .topTrailing),
            (rgb(0.30, 0.90, 0.60), .bottomLeading), (rgb(0.36, 0.50, 1.00), .bottomTrailing),
        ])
        case .sunrise: return .glow(ground: rgb(0.36, 0.20, 0.36), spots: [
            (rgb(1.00, 0.80, 0.40), .bottom), (rgb(1.00, 0.46, 0.40), .bottomLeading), (rgb(0.54, 0.46, 0.90), .top),
        ])
        case .velvet: return .glow(ground: rgb(0.14, 0.02, 0.10), spots: [
            (rgb(0.80, 0.10, 0.36), .topTrailing), (rgb(0.44, 0.10, 0.60), .bottomLeading), (rgb(0.96, 0.40, 0.50), .leading),
        ])
        case .bloom: return .glow(ground: rgb(0.30, 0.10, 0.22), spots: [
            (rgb(1.00, 0.56, 0.72), .topLeading), (rgb(1.00, 0.76, 0.52), .bottomTrailing), (rgb(0.86, 0.34, 0.60), .bottomLeading),
        ])
        case .halo: return .glow(ground: rgb(0.08, 0.10, 0.20), spots: [
            (rgb(0.98, 0.90, 0.64), .center), (rgb(0.52, 0.64, 1.00), .topLeading), (rgb(0.62, 0.52, 0.96), .bottomTrailing),
        ])
        case .iris: return .glow(ground: rgb(0.12, 0.08, 0.28), spots: [
            (rgb(0.54, 0.40, 1.00), .topTrailing), (rgb(0.30, 0.70, 1.00), .bottomLeading), (rgb(0.92, 0.56, 1.00), .leading),
        ])
        case .mirage: return .glow(ground: rgb(0.30, 0.22, 0.14), spots: [
            (rgb(1.00, 0.72, 0.40), .top), (rgb(0.40, 0.80, 0.84), .bottomTrailing), (rgb(0.96, 0.52, 0.44), .bottomLeading),
        ])
        case .opal: return .glow(ground: rgb(0.78, 0.84, 0.88), spots: [
            (rgb(0.66, 0.92, 0.88), .topLeading), (rgb(0.98, 0.76, 0.84), .trailing), (rgb(0.76, 0.74, 1.00), .bottom), (rgb(1.00, 0.92, 0.70), .top),
        ])
        case .solstice: return .glow(ground: rgb(0.24, 0.06, 0.06), spots: [
            (rgb(1.00, 0.80, 0.24), .topLeading), (rgb(1.00, 0.40, 0.14), .center), (rgb(0.70, 0.16, 0.40), .bottomTrailing),
        ])
        case .tidal: return .glow(ground: rgb(0.02, 0.12, 0.22), spots: [
            (rgb(0.20, 0.86, 0.96), .bottomLeading), (rgb(0.10, 0.40, 0.90), .topTrailing), (rgb(0.40, 1.00, 0.80), .leading),
        ])
        case .flare: return .glow(ground: rgb(0.12, 0.04, 0.20), spots: [
            (rgb(1.00, 0.30, 0.20), .topTrailing), (rgb(1.00, 0.20, 0.70), .bottomLeading), (rgb(1.00, 0.66, 0.20), .trailing),
        ])
        case .jade: return .glow(ground: rgb(0.02, 0.16, 0.12), spots: [
            (rgb(0.30, 0.86, 0.56), .topLeading), (rgb(0.10, 0.60, 0.56), .bottomTrailing), (rgb(0.76, 0.92, 0.46), .trailing),
        ])
        case .sorbet: return .glow(ground: rgb(0.96, 0.84, 0.80), spots: [
            (rgb(1.00, 0.62, 0.50), .topLeading), (rgb(0.98, 0.84, 0.46), .bottom), (rgb(0.96, 0.60, 0.78), .trailing),
        ])

        // Night with a purple light in the top corner and a grey one at
        // the foot — the look this kind was made for.
        case .eclipse: return .dark(ground: rgb(0.035, 0.04, 0.07), spots: [
            (rgb(0.44, 0.22, 0.64), .topTrailing), (rgb(0.44, 0.46, 0.56), .bottomLeading),
        ])
        case .abyss: return .dark(ground: rgb(0.02, 0.04, 0.08), spots: [
            (rgb(0.08, 0.46, 0.56), .bottomTrailing), (rgb(0.14, 0.24, 0.56), .topLeading),
        ])
        case .noir: return .dark(ground: rgb(0.03, 0.03, 0.03), spots: [
            (rgb(0.46, 0.36, 0.26), .top), (rgb(0.24, 0.24, 0.26), .bottomTrailing),
        ])
        case .obsidian: return .dark(ground: rgb(0.03, 0.03, 0.05), spots: [
            (rgb(0.40, 0.22, 0.70), .topLeading), (rgb(0.12, 0.50, 0.40), .bottomTrailing),
        ])
        case .ink: return .dark(ground: rgb(0.03, 0.05, 0.12), spots: [
            (rgb(0.20, 0.30, 0.66), .top), (rgb(0.10, 0.16, 0.40), .bottom),
        ])
        case .smoulder: return .dark(ground: rgb(0.06, 0.03, 0.03), spots: [
            (rgb(0.70, 0.24, 0.10), .bottomLeading), (rgb(0.46, 0.10, 0.16), .topTrailing),
        ])
        case .moss: return .dark(ground: rgb(0.03, 0.05, 0.04), spots: [
            (rgb(0.24, 0.44, 0.26), .topLeading), (rgb(0.36, 0.40, 0.20), .bottomTrailing),
        ])
        }
    }

    /// How thickly the colour is laid over the blur: a glow nearly hides
    /// the desktop, a hue only tints it.
    var strength: Double {
        switch family {
        case .basic: return 0
        case .hue: return 0.42
        case .gradient: return 0.50
        case .glow: return 0.72
        case .dark: return 0.94
        }
    }

    /// How far in from the window's edges the page sits, and how round its
    /// corners are, when it is a card.
    static let inset: CGFloat = 8
    static let corner: CGFloat = 12
}

/// A theme's colour, drawn to fill whatever it is given — the window, or a
/// swatch in Settings.
struct ThemePaint: View {
    let theme: Theme

    var body: some View {
        switch theme.paint {
        case .none:
            Color.clear
        case .hue(let colour):
            colour
        case .linear(let colours, let from, let to):
            LinearGradient(colors: colours, startPoint: from, endPoint: to)
        case .glow(let ground, let spots):
            Glows(ground: ground, spots: spots, reach: 0.75)
        case .dark(let ground, let spots):
            Glows(ground: ground, spots: spots, reach: 0.5)
        }
    }

    /// Spots of colour on a ground, each fading to nothing this far out, as
    /// a share of the longer side.
    private struct Glows: View {
        let ground: Color
        let spots: [(Color, UnitPoint)]
        let reach: CGFloat

        var body: some View {
            GeometryReader { geo in
                let radius = max(geo.size.width, geo.size.height) * reach
                ZStack {
                    ground
                    ForEach(spots.indices, id: \.self) { index in
                        RadialGradient(
                            colors: [spots[index].0, spots[index].0.opacity(0)],
                            center: spots[index].1,
                            startRadius: 0,
                            endRadius: radius
                        )
                    }
                }
            }
        }
    }
}

/// A theme's glass: the desktop, blurred until only its colours are left,
/// a thin shade over it so the tabs can be read, and the theme's colour.
///
/// Always the desktop, wherever it is drawn — beside the page, and over it
/// when the column or the strip comes out folded. Blurring the page there
/// instead turned the column into a smear of whatever the page had under
/// it: grey over a black page, and nothing like the column it stands in for.
struct Backdrop: View {
    let theme: Theme

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            Blur()
            ThemePaint(theme: theme)
                .opacity(theme.strength)
            // Black under white ink, white under black, over the colour
            // rather than under it: the colour can be as rich as it likes
            // and the titles still read, never so much it all goes grey.
            (dark ? Color.black : Color.white)
                .opacity(dark ? 0.30 : 0.34)
        }
        .allowsHitTesting(false)
    }

    private struct Blur: NSViewRepresentable {
        func makeNSView(context: Context) -> ClearGlass {
            let view = ClearGlass()
            // Blurred whether or not the window is the one in front: a theme
            // that went grey every time another app was clicked would be two
            // themes.
            view.state = .active
            view.material = .sidebar
            view.blendingMode = .behindWindow
            return view
        }

        func updateNSView(_ view: ClearGlass, context: Context) {
            view.strip()
        }
    }
}

/// The system's glass with only the blur left in it.
///
/// A material is a blur with a grey laid over it — a "fill" at 80% and a
/// "tone" lightening that — which is why the window came out a flat, dull
/// sheet and not the desktop's colours. Those two, and the desktop tint, are
/// hidden, and the blur is made wider and less loud, so what is left reads
/// as smooth light rather than as a picture out of focus. The layers are the
/// system's to name (read on macOS 26); where they are called something
/// else, the material is simply left whole, as it would have been.
final class ClearGlass: NSVisualEffectView {
    static let radius: CGFloat = 60
    static let saturation: CGFloat = 1.7

    override func layout() {
        super.layout()
        strip()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The system puts its layers back for the new appearance.
        DispatchQueue.main.async { self.strip() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { self.strip() }
    }

    func strip() {
        guard let root = layer else { return }
        var found: [CALayer] = []
        func walk(_ layer: CALayer) {
            found.append(layer)
            layer.sublayers?.forEach(walk)
        }
        walk(root)
        guard found.contains(where: { $0.name == "backdrop" }) else { return }
        for layer in found {
            switch layer.name {
            case "fill", "tone", "desktop tint":
                if !layer.isHidden { layer.isHidden = true }
            case "backdrop":
                let filters = "filters.gaussianBlur.inputRadius"
                if (layer.value(forKeyPath: filters) as? CGFloat) != ClearGlass.radius {
                    layer.setValue(ClearGlass.radius, forKeyPath: filters)
                    layer.setValue(ClearGlass.saturation, forKeyPath: "filters.colorSaturate.inputAmount")
                }
            default:
                break
            }
        }
    }
}

/// Light, dark, or the Mac's own — the one choice that colours everything.
enum Look: String, CaseIterable, Identifiable {
    case light, dark, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }

    /// What the app is told to be. Nothing, for "system": the app then
    /// follows the Mac, and changes with it.
    var appearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }

    /// Set on the app rather than on the window, so every panel, alert and
    /// sheet — and every page, which follows the window it is in — agrees.
    ///
    /// Never from inside whatever is happening when it is asked for: the
    /// switch in Settings changes it from within an animation, over a panel
    /// in transition, and re-skinning every window in the middle of that is
    /// how a window ends up with a layer that takes clicks and shows
    /// nothing. The next turn of the run loop is soon enough.
    func apply() {
        let wanted = appearance
        DispatchQueue.main.async {
            guard NSApp.appearance !== wanted, NSApp.appearance?.name != wanted?.name else { return }
            NSApp.appearance = wanted
        }
    }
}

enum Metrics {
    /// The tab strip. The window's title bar is grown to match it so the
    /// traffic lights come down with the tabs — otherwise giving the row room
    /// to breathe just leaves it sitting below three buttons it used to line
    /// up with.
    static let strip: CGFloat = 52
    /// Where the first tab starts. The traffic lights run from 19 to 79 —
    /// measured, not guessed — so this leaves them the same air on their right
    /// that the window gives them on their left.
    static let lights: CGFloat = 100
    /// Back, forward and reload, at the far end of the row beside the
    /// bookmarks: three doors and the air before the next one.
    static let helm: CGFloat = 3 * 26 + 2 * 2 + 8
    /// The same three doors again, in the sidebar, where they sit right of
    /// the lights instead. The column already has 10 of horizontal padding
    /// of its own before this even starts, so this is the lights' own edge
    /// (79) less that padding, plus a sliver of air — not the full breathing
    /// room a tab row gets, because the sidebar's minimum width doesn't have
    /// it to give.
    static let sideLights: CGFloat = 72
    /// The band left at the top when there is no strip: just enough for the
    /// traffic lights to sit in, and nothing else.
    static let bare: CGFloat = 34
    /// Tabs are a fixed width rather than the width of their titles, so the
    /// cross always lands in the same place and the row never rearranges
    /// itself while you read it. They give way when there are too many:
    /// narrower than tabTitled they show their site's mark alone, and they
    /// stop at tabMinWidth, the mark and its air. Past that the row scrolls,
    /// inside its own edges.
    static let tabWidth: CGFloat = 186
    static let tabTitled: CGFloat = 80
    static let tabMinWidth: CGFloat = 36
    static let tabGap: CGFloat = 2
    /// A pinned tab is a square the height of the row, holding one letter.
    static let pinWidth: CGFloat = 30
    /// The square at the end of the row that opens a new page.
    static let plusWidth: CGFloat = 30
    /// The address field, in both the places it shows up.
    static let fieldWidth: CGFloat = 560
    /// The column of titles down the left, in the way that has one.
    static let side: CGFloat = 232
    static let sideMin: CGFloat = 176
    static let sideMax: CGFloat = 440
}

// One spring for anything that moves between two places, one for anything that
// arrives or leaves. Using the same two everywhere is most of why a thing feels
// like a single piece of software rather than a pile of views.
enum Motion {
    static let glide = Animation.spring(response: 0.34, dampingFraction: 0.82)
    static let settle = Animation.spring(response: 0.30, dampingFraction: 0.86)
    static let quick = Animation.easeOut(duration: 0.14)
}

/// Search's mark — Drice's Subtract.svg, a pill with an S cut out of it,
/// read from its own path data rather than loaded from a file, so it stays a
/// crisp vector at any size. No plate, no square behind it: the mark draws exactly
/// what the source file has and nothing it doesn't, the way every other icon
/// in this app is a bare shape rather than a shape on a background. The one
/// exception is the macOS app icon (`Icon/icon.swift`), which needs an
/// opaque square whether the mark wants one or not — that's the Dock's
/// requirement, not the logo's.
struct Logomark: Shape {
    /// The source's own canvas: Subtract.svg, 608 × 276, nothing outside it.
    static let canvas = CGSize(width: 608, height: 276)

    /// A pill with an S cut out of it. The same path as Icon/icon.swift and
    /// the website's mark.
    private static let data = "M469.443 0C545.471 0.00013198 607.103 61.6325 607.104 137.66C607.104 213.688 545.471 275.321 469.443 275.321H137.66C61.6323 275.321 0 213.688 0 137.66C0.00016085 61.6325 61.6325 0.000140192 137.66 0H469.443ZM138.104 51.5977C127.234 51.5977 117.512 53.5115 108.938 57.3389C100.518 61.0132 93.8581 66.2188 88.959 72.9551C84.2132 79.5381 81.8398 87.3464 81.8398 96.3789C81.8399 105.258 83.6773 112.607 87.3516 118.425C91.0258 124.089 95.9251 128.682 102.049 132.203C108.173 135.571 114.833 138.327 122.028 140.471L151.652 149.197C158.389 151.188 163.9 154.249 168.187 158.383C172.473 162.516 174.617 168.028 174.617 174.917C174.617 182.572 171.402 188.849 164.972 193.748C158.695 198.494 150.122 200.867 139.252 200.867C132.21 200.867 125.702 199.413 119.731 196.504C113.914 193.442 109.091 189.308 105.264 184.103C101.436 178.744 99.2169 172.697 98.6045 165.961H97.6855L75.4102 171.013C76.3287 180.658 79.697 189.308 85.5146 196.963C91.3322 204.618 98.9103 210.665 108.249 215.104C117.741 219.544 128.076 221.765 139.252 221.765C151.193 221.765 161.68 219.774 170.713 215.794C179.746 211.813 186.711 206.225 191.61 199.029C196.662 191.834 199.188 183.414 199.188 173.769C199.188 164.124 197.352 156.239 193.678 150.115C190.003 143.838 185.104 138.863 178.98 135.188C172.857 131.514 166.044 128.605 158.542 126.462L128.229 117.735C121.799 115.898 116.516 113.219 112.383 109.698C108.402 106.177 106.412 101.354 106.412 95.2305C106.412 88.188 109.168 82.6758 114.68 78.6953C120.344 74.5619 128.152 72.4951 138.104 72.4951C147.901 72.4952 155.939 74.9448 162.216 79.8438C168.493 84.7428 172.397 91.1729 173.928 99.1338H174.847L196.663 93.8525C195.745 85.5853 192.605 78.3131 187.247 72.0361C181.889 65.6061 174.923 60.6306 166.35 57.1094C157.929 53.4351 148.514 51.5977 138.104 51.5977Z"

    func path(in rect: CGRect) -> Path {
        // Fit the canvas into whatever frame this is given, centred, at the
        // larger scale that still keeps it inside — an SVG viewBox's "meet".
        let scale = min(rect.width / Logomark.canvas.width, rect.height / Logomark.canvas.height)
        let ox = rect.midX - Logomark.canvas.width * scale / 2
        let oy = rect.midY - Logomark.canvas.height * scale / 2
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * scale, y: oy + y * scale) }
        var path = Path()
        var last = CGPoint.zero
        var start = CGPoint.zero
        for (c, n) in Logomark.commands {
            switch c {
            case "M": last = CGPoint(x: n[0], y: n[1]); start = last; path.move(to: pt(n[0], n[1]))
            case "L": last = CGPoint(x: n[0], y: n[1]); path.addLine(to: pt(n[0], n[1]))
            case "H": last.x = n[0]; path.addLine(to: pt(last.x, last.y))
            case "V": last.y = n[0]; path.addLine(to: pt(last.x, last.y))
            case "C":
                var k = 0
                while k + 5 < n.count {
                    path.addCurve(to: pt(n[k + 4], n[k + 5]), control1: pt(n[k], n[k + 1]), control2: pt(n[k + 2], n[k + 3]))
                    last = CGPoint(x: n[k + 4], y: n[k + 5])
                    k += 6
                }
            case "Z": path.closeSubpath(); last = start
            default: break
            }
        }
        return path
    }

    /// Read once. Absolute M, L, H, V, C, Z — what Figma writes for a
    /// flattened shape, and nothing else is needed.
    private static let commands: [(Character, [CGFloat])] = {
        var out: [(Character, [CGFloat])] = []
        var current: Character?
        var numbers: [CGFloat] = []
        var token = ""
        func flush() {
            if !token.isEmpty, let v = Double(token) { numbers.append(CGFloat(v)) }
            token = ""
        }
        for ch in data {
            if "MLHVCZ".contains(ch) {
                flush()
                if let current { out.append((current, numbers)) }
                current = ch
                numbers = []
            } else if ch == " " || ch == "," {
                flush()
            } else if ch == "-" && !token.isEmpty {
                flush()
                token = "-"
            } else {
                token.append(ch)
            }
        }
        flush()
        if let current { out.append((current, numbers)) }
        return out
    }()
}

/// Wrong address, said without a dialog: the field shivers and stops.
struct Shake: GeometryEffect {
    var travel: CGFloat

    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        // Three there-and-backs, tapering to nothing, so it settles rather than
        // stopping mid-swing.
        let decay = 1 - travel
        return ProjectionTransform(
            CGAffineTransform(translationX: sin(travel * .pi * 6) * 7 * decay, y: 0)
        )
    }
}
