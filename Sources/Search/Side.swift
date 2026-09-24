import SwiftUI

/// The tabs, down the left instead of across the top.
///
/// The same pieces as the strip — the grey that slides to the tab you picked,
/// the pinned squares, the cross that appears under the pointer — laid out the
/// other way. The traffic lights keep their corner; the column starts under
/// them and the page takes the whole height beside it.
struct SideBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    /// Out over the page, folded (see Fold.swift), rather than beside it.
    var floating = false

    @Namespace private var pill

    @State private var dragging: Tab.ID?
    @State private var travel: CGFloat = 0
    /// Where the line held was when it was picked up, in the rows' space.
    @State private var startY: CGFloat = 0
    /// A line held over the squares, to become one of them when let go.
    @State private var overGrid = false
    /// True for as long as a line, or a square, is being dragged. SwiftUI
    /// puts these back by itself when the drag ends and also when it is
    /// cancelled, which `onEnded` never hears of: the rows swapping to their
    /// scrolling copy under the hand, say. Without them, a cancelled drag
    /// left its line or square held for good, drawn over its neighbours.
    @GestureState private var holdingLine = false
    @GestureState private var holdingSquare = false
    /// Where the rows and the squares are on screen: the two blocks measure
    /// their drags in spaces of their own, and this joins them.
    @State private var places = Places()
    @State private var landing = false
    /// The width the column had when the edge was picked up.
    @State private var grabbed: CGFloat?
    @State private var onEdge = false
    /// How wide the extensions in the top corner are, kept clear of the
    /// strip that drags the window.
    @State private var corner: CGFloat = 0

    /// A pin, picked up out of the grid — a separate state from the loose
    /// rows above, since the two gestures never happen at once but move on
    /// two different axes.
    /// The neighbouring spaces' own grey, apart from this one's.
    @Namespace private var before
    @Namespace private var after

    @State private var pinDragging: Tab.ID?
    @State private var pinFrom = 0
    @State private var pinTravel: CGSize = .zero

    private static let gap: CGFloat = 2
    private static let pinGap: CGFloat = 4
    /// The heading over the tabs pinned as lines, and the line with Clear
    /// that parts them from the rest.
    static let heading: CGFloat = 26
    static let divider: CGFloat = 24
    /// The air under the address, the same the squares leave under them.
    static let addressGap: CGFloat = 10

    /// A line, and a pinned square at its tallest, at the size picked in
    /// Settings › Customization.
    private var row: CGFloat { prefs.tabSize.row }
    private var square: CGFloat { prefs.tabSize.square }
    private var step: CGFloat { row + SideBar.gap }

    var body: some View {
        ZStack(alignment: .top) {
            // Not under the card for a new space: it isn't made of views that
            // would take the click first.
            DragStrip(reserved: 0, below: browser.makingSpace ? .greatestFiniteMagnitude : rowsEnd)

            // The band the lights sit in is this mode's title bar: the window
            // is dragged by it and a double-click fills the screen with it,
            // everywhere but over the three doors, which take their own
            // clicks. The lights are the title bar's own and answer first.
            HStack(spacing: 0) {
                DragStrip()
                    .frame(width: 10 + Metrics.sideLights)
                Color.clear
                    .frame(width: Metrics.helm)
                    .allowsHitTesting(false)
                // Not under the puzzle and its pinned buttons at the far end.
                DragStrip(trailing: corner + 10)
            }
            .frame(height: Metrics.strip)

            VStack(alignment: .leading, spacing: 0) {
                // The traffic lights' corner, with back, forward and reload
                // sitting right of them — the same three doors as the top
                // bar, moved beside the lights since there's no far end of a
                // row to put them at in this mode.
                HStack(spacing: 0) {
                    Color.clear.frame(width: Metrics.sideLights)
                    Helm(browser: browser)
                    Spacer(minLength: 0)
                    // The extensions, in the corner across from the lights.
                    ExtensionSlot(always: true, room: extensionRoom)
                        .background {
                            GeometryReader { box in
                                Color.clear
                                    .onAppear { corner = box.size.width }
                                    .onChange(of: box.size.width) { _, width in corner = width }
                            }
                        }
                }
                .frame(height: Metrics.strip)

                // The page's address, and the field unfurling from it (see
                // SideAddress.swift). Over the spaces rather than in each:
                // it is the page's, whichever space the page is in.
                if prefs.sideAddress {
                    SideAddress(browser: browser)
                        .padding(.bottom, SideBar.addressGap)
                }

                // The spaces side by side, as pages: two fingers sideways move
                // the one on screen and the next one together, the next one
                // coming in as this one goes, with nothing between them.
                pages

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            // Clear of the foot, which sits over the column's bottom edge.
            .padding(.bottom, SideBar.footHeight)

            VStack {
                Spacer()
                foot
            }
        }
        .frame(width: prefs.sideWidth)
        .frame(maxHeight: .infinity)
        // Rows on their way to or from another space stay in the column.
        .clipped()
        .onAppear { SpaceSwipe.shared.start(for: browser) }
        .background { ground }
        // On a theme's glass, beside the page, the card's own edge is the
        // line between them.
        .overlay(alignment: .trailing) {
            if !prefs.theme.isGlass || floating {
                Rectangle().fill(Palette.hairline).frame(width: 1)
            }
        }
        .overlay(alignment: .trailing) { edge }
        .onDrop(of: [.url, .text], isTargeted: $landing) { providers in
            browser.take(providers)
        }
        .animation(Motion.quick, value: landing)
        .animation(Motion.glide, value: browser.activeID)
        .animation(Motion.glide, value: browser.editingTab)
        .animation(Motion.settle, value: browser.tabs.map(\.id))
        .animation(Motion.settle, value: browser.pinnedCount)
        .animation(Motion.settle, value: browser.keptCount)
        .animation(Motion.settle, value: prefs.pinnedFolded)
        .onChange(of: holdingLine) { _, holding in if !holding { letGoOfLine() } }
        .onChange(of: holdingSquare) { _, holding in if !holding { letGoOfSquare() } }
    }

    /// The ground, or a theme's glass: nothing of its own beside the page,
    /// where the window's glass is already behind it, and the same glass of
    /// its own when it comes out over the page.
    @ViewBuilder
    private var ground: some View {
        ZStack {
            if !prefs.theme.isGlass {
                Palette.ground
            } else if floating {
                Backdrop(theme: prefs.theme)
            }
            if landing { Palette.hover }
        }
    }

    /// The column's edge: pull it to make the column wider or narrower,
    /// double-click it to put it back. The hairline darkens under the pointer
    /// so the edge says it can be taken before it is.
    private var edge: some View {
        Rectangle()
            .fill(Palette.ink.opacity(onEdge || grabbed != nil ? 0.18 : 0))
            .frame(width: onEdge || grabbed != nil ? 2 : 1)
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { over in
                onEdge = over
                if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if grabbed == nil { grabbed = prefs.sideWidth }
                        let wanted = (grabbed ?? prefs.sideWidth) + value.translation.width
                        prefs.sideWidth = min(Metrics.sideMax, max(Metrics.sideMin, wanted))
                    }
                    .onEnded { _ in grabbed = nil }
            )
            .modifier(OneClick(double: true) {
                withAnimation(Motion.settle) { prefs.sideWidth = Metrics.side }
            })
            .animation(Motion.quick, value: onEdge)
    }

    // MARK: - the spaces, as pages

    /// Where the space on screen sits among them: one past the last while
    /// the card for a new one is up.
    private var spaceAt: Int {
        browser.makingSpace ? browser.spaces.count : (browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0)
    }

    private var pages: some View {
        let width = prefs.sideWidth
        let swipe = browser.spaceSwipe
        let at = spaceAt
        return ZStack(alignment: .topLeading) {
            page(at, pill: pill)
                .offset(x: swipe)
            // Only while the fingers are bringing one in: the one they are
            // bringing, a page's width away.
            if swipe > 0, at > 0 {
                page(at - 1, pill: before)
                    .offset(x: swipe - width)
            }
            if swipe < 0, at < browser.spaces.count {
                page(at + 1, pill: after)
                    .offset(x: swipe + width)
            }
        }
        // The pages are the column's whole width, each with its own margin.
        .padding(.horizontal, -10)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// One space's page: the rows on screen, another space's rows as they
    /// were left, or past the last the card for a new one.
    @ViewBuilder
    private func page(_ index: Int, pill: Namespace.ID) -> some View {
        Group {
            if index == browser.spaces.count {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    NewSpaceCard(browser: browser)
                    Spacer(minLength: 0)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            } else if browser.spaces[index].id == browser.spaceID {
                VStack(alignment: .leading, spacing: 0) {
                    if browser.pinnedCount > 0 {
                        pinned
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                                places.gridTop = frame.minY
                                places.gridBottom = frame.maxY
                            }
                            // A line held over the squares lights them: let go,
                            // it becomes one.
                            .background {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(Palette.hover.opacity(overGrid ? 1 : 0))
                                    .padding(-4)
                            }
                            .animation(Motion.quick, value: overGrid)
                            .padding(.bottom, 10)
                            // A square taken down among the lines is drawn over
                            // them, not under.
                            .zIndex(pinDragging == nil ? 0 : 1)
                    }
                    // A row too long for the window scrolls between the pins
                    // and the foot, rather than running under the lights at one
                    // end and the foot at the other. While it fits, the scroll
                    // view is the rows' own height and neither scrolls nor
                    // clips, and the space under it is still the window's to
                    // be dragged by. One view either way: a plain stack and a
                    // scrolling copy, swapped as the rows grew past the window,
                    // ended any drag that made them grow. Inside the page: the
                    // swipe between spaces moves the page, scroll and all.
                    ScrollViewReader { proxy in
                        ThinScroll { rows }
                            .frame(maxHeight: rowsHeight)
                            // The tab you go to is the tab you see — ⌘1–⌘9,
                            // ⇧⌘], a link opening beside the one on screen.
                            .onChange(of: browser.activeID) { _, id in
                                guard let id else { return }
                                withAnimation(Motion.glide) { proxy.scrollTo(id) }
                            }
                            .onAppear {
                                if let id = browser.activeID { proxy.scrollTo(id, anchor: .center) }
                            }
                    }
                }
            } else {
                preview(browser.parked[browser.spaces[index].id] ?? Parked(tabs: [], active: nil), pill: pill)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: prefs.sideWidth, alignment: .topLeading)
    }

    /// Another space's rows, drawn with the same pieces as this one's so the
    /// two read as one column while they pass — and nothing to press until
    /// it is the one on screen.
    private func preview(_ row: Parked, pill: Namespace.ID) -> some View {
        let pins = row.tabs.filter { $0.place == .essential }
        let open = row.tabs.contains { $0.place == .kept && !$0.asleep }
        let clears = row.tabs.contains { $0.place == .loose }
        let cols = SideBar.pinColumns(pins.count)
        let width = pinWidth(for: pins.count)
        let height = min(square, width)
        return VStack(alignment: .leading, spacing: 0) {
            if !pins.isEmpty {
                VStack(spacing: 0) {
                    PinGrid(columns: cols, width: width, height: height, spacing: SideBar.pinGap) {
                        ForEach(pins) { tab in
                            PinSquare(browser: browser, prefs: prefs, tab: tab, live: tab.id == row.active,
                                      pill: pill, width: width, height: height)
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            ForEach(SideBar.pieces(of: row.tabs, active: row.active, folded: prefs.pinnedFolded)) { piece in
                switch piece {
                case .heading:
                    PinnedHeading(prefs: prefs, open: open)
                case .tab(let tab):
                    SideRow(browser: browser, prefs: prefs, tab: tab, live: tab.id == row.active, pill: pill, close: {})
                        .padding(.bottom, SideBar.gap)
                case .divider:
                    ClearLine(clears: clears) {}
                }
            }
            if !prefs.newTabInFoot { newTab }
        }
        .allowsHitTesting(false)
    }

    /// Where the rows stop and the window's own drag area starts. Added up
    /// from what was drawn rather than measured: a measurement would arrive a
    /// frame late, and for one frame the whole column would drag the window.
    private var rowsEnd: CGFloat {
        let pins = browser.pinnedCount
        let cols = SideBar.pinColumns(pins)
        let pinRows = pins == 0 ? 0 : (pins + cols - 1) / cols
        let pinBlock = pinRows == 0 ? 0
            : CGFloat(pinRows) * pinHeight + CGFloat(pinRows - 1) * SideBar.pinGap + 10
        let address = prefs.sideAddress ? SideAddress.height + SideBar.addressGap : 0
        return Metrics.strip + address + pinBlock + rowsHeight + 8
    }

    /// What the rows take, top to bottom: the pinned lines, the line with
    /// Clear, the other tabs and the row that makes another. The same sum
    /// the drags work from, so the three can't disagree.
    private var rowsHeight: CGFloat {
        keptBlock + SideBar.divider + CGFloat(looseTabs.count) * step + (prefs.newTabInFoot ? 0 : row)
    }

    // MARK: - the pinned squares

    private var pinnedTabs: [Tab] { browser.tabs.filter { $0.place == .essential } }
    private var keptTabs: [Tab] { browser.tabs.filter { $0.place == .kept } }
    private var looseTabs: [Tab] { browser.tabs.filter { $0.place == .loose } }
    /// The pinned lines drawn: all of them, or folded, only the one on
    /// screen — the tab you are on is never out of sight.
    private var shownKept: [Tab] {
        keptTabs.filter { !prefs.pinnedFolded || $0.id == browser.activeID }
    }

    /// Three columns is the block's own shape — up to six pins, that's two
    /// full rows, and one or two is just those same three places with a
    /// couple of them empty rather than a lonely row of its own width. Only
    /// past six does the block widen, one column at a time, to stay at two
    /// rows for as long as that's a reasonable shape at all.
    private static func pinColumns(_ count: Int) -> Int {
        max(3, (count + 1) / 2)
    }

    /// However many columns the count calls for, they split the row's own
    /// width between them — the row is what fills edge to edge, not each
    /// cell on its own, so this grows past the square's height
    /// (TabSize.square) just as readily as it shrinks below it.
    private var pinWidth: CGFloat { pinWidth(for: browser.pinnedCount) }

    private func pinWidth(for count: Int) -> CGFloat {
        let cols = SideBar.pinColumns(count)
        guard cols > 0 else { return square }
        let available = prefs.sideWidth - 20 - CGFloat(cols - 1) * SideBar.pinGap
        return max(20, available / CGFloat(cols))
    }

    /// The one dimension that doesn't chase the sidebar's width: past three
    /// columns' worth of room a cell would otherwise turn into a big square
    /// rather than the wide, short button pinned tabs actually look like
    /// everywhere else in this app. It only shrinks below the square's height
    /// alongside the width, once a narrow column leaves no other choice.
    private var pinHeight: CGFloat {
        min(square, pinWidth)
    }

    /// The grid itself: fixed-size cells, left-aligned, so a half-empty last
    /// row holds its ground rather than stretching to fill it.
    private var pinned: some View {
        let tabs = pinnedTabs
        let cols = SideBar.pinColumns(tabs.count)
        let width = pinWidth
        let height = pinHeight
        // Measured in the grid's own space, not the square's: a square that
        // has just been moved to a new cell would otherwise report the drag
        // from where it now is, the target would jump back, and the square
        // would shuttle between two cells for as long as the finger stayed.
        return VStack(spacing: 0) { PinGrid(columns: cols, width: width, height: height, spacing: SideBar.pinGap) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                let held = pinDragging == tab.id
                PinSquare(
                    browser: browser,
                    prefs: prefs,
                    tab: tab,
                    live: tab.id == browser.activeID,
                    pill: pill,
                    width: width,
                    height: height
                )
                .offset(pinOffset(held: held, index: index, columns: cols))
                // Under the hand exactly, as a row is (see the rows below).
                .transaction { if held { $0.animation = nil } }
                .zIndex(held ? 1 : 0)
                .shadow(color: .black.opacity(held ? 0.16 : 0), radius: 10, y: 3)
                .gesture(pinReorder(tab: tab, index: index, columns: cols, width: width, height: height))
            }
        } }
        .coordinateSpace(name: "pins")
    }

    /// The one square actually held stays glued to the fingers; every other
    /// square is already exactly where it belongs, because `browser.move`
    /// put it there — this only cancels out the bit of that same movement
    /// the held square already got for free by changing index underneath
    /// its own drag.
    private func pinOffset(held: Bool, index: Int, columns: Int) -> CGSize {
        guard held else { return .zero }
        let stepX = pinWidth + SideBar.pinGap
        let stepY = pinHeight + SideBar.pinGap
        let from = (row: pinFrom / columns, col: pinFrom % columns)
        let now = (row: index / columns, col: index % columns)
        return CGSize(
            width: pinTravel.width - CGFloat(now.col - from.col) * stepX,
            height: pinTravel.height - CGFloat(now.row - from.row) * stepY
        )
    }

    /// How many cells the drag has moved, in the grid's own row-major order
    /// — a straight line through the array a column-major offset would get
    /// wrong the moment it crossed a row. Row and column travel each measure
    /// themselves against that axis's own step now that a cell's width and
    /// height aren't the same number.
    private func pinDelta(columns: Int, stepX: CGFloat, stepY: CGFloat) -> Int {
        let col = Int((pinTravel.width / stepX).rounded())
        let row = Int((pinTravel.height / stepY).rounded())
        return row * columns + col
    }

    private func pinTarget(from: Int, moved: Int) -> Int {
        min(max(0, from + moved), max(0, pinnedTabs.count - 1))
    }

    /// Pick a square up and the others make way — across a row, and down
    /// into the next, exactly as far as the fingers actually moved.
    private func pinReorder(tab: Tab, index: Int, columns: Int, width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("pins"))
            .updating($holdingSquare) { _, holding, _ in holding = true }
            .onChanged { value in
                if pinDragging != tab.id {
                    pinDragging = tab.id
                    pinFrom = index
                }
                pinTravel = value.translation
                // Taken down past the grid, it is on its way to the lines:
                // the squares stop making way for it.
                guard !below(value) else { return }
                let stepX = width + SideBar.pinGap
                let stepY = height + SideBar.pinGap
                let target = pinTarget(from: pinFrom, moved: pinDelta(columns: columns, stepX: stepX, stepY: stepY))
                if target != index {
                    withAnimation(Motion.settle) {
                        browser.move(tab, to: target)
                    }
                }
            }
            .onEnded { value in
                // Read from the gesture, not from state: whether this runs
                // before or after the reset above is SwiftUI's to say.
                if below(value) {
                    // Where among the lines it was let go, in their space.
                    let (place, slot) = aim(places.gridTop + value.location.y - places.rowsTop, holding: tab)
                    withAnimation(Motion.settle) { browser.put(tab, place, at: slot) }
                }
                letGoOfSquare()
            }
    }

    /// A square held past the grid's bottom edge.
    private func below(_ value: DragGesture.Value) -> Bool {
        places.gridTop + value.location.y > places.gridBottom + 6
    }

    private func letGoOfSquare() {
        guard pinDragging != nil || pinTravel != .zero else { return }
        withAnimation(Motion.settle) {
            pinDragging = nil
            pinTravel = .zero
        }
    }

    // MARK: - the rows

    /// What the pinned lines take of the rows: their heading, and the lines
    /// drawn under it. Nothing when there are none.
    private var keptBlock: CGFloat {
        guard browser.keptCount > 0 else { return 0 }
        return SideBar.heading + CGFloat(shownKept.count) * step
    }

    /// Where a line starts, in the rows' space. Added up from the same
    /// numbers the rows are drawn with, as `rowsEnd` is.
    private func top(of tab: Tab) -> CGFloat {
        if let index = shownKept.firstIndex(where: { $0.id == tab.id }) {
            return SideBar.heading + CGFloat(index) * step
        }
        let index = looseTabs.firstIndex { $0.id == tab.id } ?? 0
        return keptBlock + SideBar.divider + CGFloat(index) * step
    }

    /// The block, and the place in it, that a tab held at `y` in the rows'
    /// space would take: above the middle of the line with Clear, the pinned
    /// lines; under it, the rest. Folded, the lines out of sight can't be
    /// aimed between: one already pinned stays where it is, and another goes
    /// at their end — which opens them to show it (see `Browser.put`).
    private func aim(_ y: CGFloat, holding tab: Tab) -> (Browser.Place, Int) {
        let kept = keptTabs.filter { $0.id != tab.id }.count
        let loose = looseTabs.filter { $0.id != tab.id }.count
        if y < keptBlock + SideBar.divider / 2 {
            guard !prefs.pinnedFolded else { return (.kept, keptTabs.firstIndex { $0.id == tab.id } ?? kept) }
            return (.kept, min(max(0, Int(floor((y - SideBar.heading) / step))), kept))
        }
        return (.loose, min(max(0, Int(floor((y - keptBlock - SideBar.divider) / step))), loose))
    }

    /// One piece of the rows: the heading over the pinned lines, a tab's
    /// line, or the line with Clear.
    private enum Piece: Identifiable {
        case heading
        case tab(Tab)
        case divider

        var id: AnyHashable {
            switch self {
            case .heading: return "heading"
            case .tab(let tab): return tab.id
            case .divider: return "divider"
            }
        }
    }

    /// A row's pieces top to bottom, as one list. A line is the same view on
    /// either side of the divider: drawn by two lists, crossing from one to
    /// the other made it a new view, the drag it was under ended with the
    /// old one, and the line stayed held where it was left, over another.
    /// Folded, the pinned line on screen still shows (see `shownKept`).
    private static func pieces(of tabs: [Tab], active: Tab.ID?, folded: Bool) -> [Piece] {
        let kept = tabs.filter { $0.place == .kept }
        var pieces: [Piece] = []
        if !kept.isEmpty {
            pieces.append(.heading)
            pieces += kept.filter { !folded || $0.id == active }.map(Piece.tab)
        }
        pieces.append(.divider)
        pieces += tabs.filter { $0.place == .loose }.map(Piece.tab)
        return pieces
    }

    private func line(_ tab: Tab) -> some View {
        let held = dragging == tab.id
        return SideRow(
            browser: browser,
            prefs: prefs,
            tab: tab,
            live: tab.id == browser.activeID,
            pill: pill,
            close: { browser.close(tab) }
        )
        .padding(.bottom, SideBar.gap)
        .offset(y: held ? startY + travel - top(of: tab) : 0)
        // Under the hand exactly. Its place in the row springs when it
        // passes another tab, and the offset springs back the same way —
        // until the next move of the hand cuts the offset's spring short
        // and leaves the place's running: the tab jumped a whole slot and
        // drifted back each time it passed one. Only the others glide.
        .transaction { if held { $0.animation = nil } }
        .zIndex(held ? 1 : 0)
        .shadow(color: .black.opacity(held ? 0.14 : 0), radius: 12, y: 4)
        .opacity(held && overGrid ? 0.6 : 1)
        .gesture(reorder(tab: tab))
    }

    /// Pick a line up and the others make way as it passes them — across
    /// the line with Clear too, which pins it or unpins it, and up into the
    /// squares, which makes it one of them once it is let go there.
    private func reorder(tab: Tab) -> some Gesture {
        // See the grid: the drag is measured in the rows' space, not the
        // line's, so a line that has just moved keeps its bearings.
        DragGesture(minimumDistance: 5, coordinateSpace: .named("rows"))
            .updating($holdingLine) { _, holding, _ in holding = true }
            .onChanged { value in
                if dragging != tab.id {
                    startY = top(of: tab)
                    dragging = tab.id
                }
                travel = value.translation.height
                overGrid = over(value, holding: tab)
                guard !overGrid else { return }
                let (place, slot) = aim(startY + travel + row / 2, holding: tab)
                let now = tab.place
                let index = (now == .kept ? keptTabs : looseTabs).firstIndex { $0.id == tab.id } ?? 0
                guard place != now || slot != index else { return }
                withAnimation(Motion.settle) {
                    if place == now {
                        browser.move(tab, to: browser.block(place).lowerBound + slot)
                    } else {
                        browser.put(tab, place, at: slot)
                    }
                }
            }
            .onEnded { value in
                // Read from the gesture, not from state: whether this runs
                // before or after the reset above is SwiftUI's to say.
                if over(value, holding: tab) {
                    withAnimation(Motion.settle) { browser.pin(tab) }
                }
                letGoOfLine()
            }
    }

    /// The pointer up over the squares, holding a line that can be one.
    private func over(_ value: DragGesture.Value, holding tab: Tab) -> Bool {
        browser.pinnedCount > 0 && !tab.isBlank && places.rowsTop + value.location.y < places.gridBottom + 4
    }

    private func letGoOfLine() {
        guard dragging != nil || travel != 0 || overGrid else { return }
        withAnimation(Motion.settle) {
            dragging = nil
            travel = 0
            overGrid = false
        }
    }

    /// The pinned lines under their heading, the line with Clear, the other
    /// tabs and the row that makes another, which scroll as one — unless
    /// the way to another is down in the foot.
    private var rows: some View {
        let open = keptTabs.contains { !$0.asleep }
        let clears = !looseTabs.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(SideBar.pieces(of: browser.tabs, active: browser.activeID, folded: prefs.pinnedFolded)) { piece in
                switch piece {
                case .heading:
                    PinnedHeading(prefs: prefs, open: open)
                case .tab(let tab):
                    line(tab)
                case .divider:
                    ClearLine(clears: clears) {
                        withAnimation(Motion.settle) { browser.clearTabs() }
                    }
                }
            }
            if !prefs.newTabInFoot { newTab }
        }
        .coordinateSpace(name: "rows")
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { places.rowsTop = $0 }
    }

    /// The foot's door and its margin beneath.
    private static let footHeight: CGFloat = 26 + 10

    private var newTab: some View {
        // The line above it leaves the gap.
        Quiet(icon: "plus", title: "New tab", height: row, text: prefs.tabSize.text) { browser.newTab() }
    }

    /// The doors at the bottom: the spaces, the extensions and the
    /// bookmarks, and a new tab, when it was asked to live here, alone in
    /// the far corner where it never moves.
    /// The pinned extension buttons that fit between reload and the puzzle:
    /// the column less its padding, the lights, the three doors and the
    /// puzzle with a little air, at a door and its gap each.
    private var extensionRoom: Int {
        let free = prefs.sideWidth - 20 - Metrics.sideLights - (3 * 26 + 2 * 2) - 26 - 4
        return max(0, Int(free / 28))
    }

    private var foot: some View {
        HStack(spacing: 2) {
            if browser.prefs.usesSpaces { SpaceDot(browser: browser) }
            Door(icon: "bookmark", help: "Bookmarks") { browser.bookmarksOpen.toggle() }
                .popover(isPresented: $browser.bookmarksOpen, arrowEdge: .trailing) {
                    BookmarksDropdown(browser: browser, bookmarks: browser.bookmarks)
                }
            Spacer(minLength: 0)
            if prefs.newTabInFoot {
                Door(icon: "plus", help: "New tab   ⌘T") { browser.newTab() }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

}

/// Where the rows and the squares are on screen. Read by the drags alone, so
/// kept in a box rather than in state: the rows move on every frame of a
/// scroll, and state would redraw the whole column for each.
private final class Places {
    var rowsTop: CGFloat = 0
    var gridTop: CGFloat = 0
    var gridBottom: CGFloat = 0
}

/// The pinned squares' grid, every cell laid out at once. A lazy grid makes
/// its cells only once the column is on screen, where the column's slide
/// can't take them along: folded with ⌘S and brought back, the squares stood
/// in place while the column came in beneath them. A dozen squares need no
/// laziness.
private struct PinGrid: Layout {
    let columns: Int
    let width: CGFloat
    let height: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = (subviews.count + columns - 1) / columns
        return CGSize(
            width: CGFloat(columns) * width + CGFloat(max(0, columns - 1)) * spacing,
            height: CGFloat(rows) * height + CGFloat(max(0, rows - 1)) * spacing
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(index % columns) * (width + spacing),
                    y: bounds.minY + CGFloat(index / columns) * (height + spacing)
                ),
                proposal: ProposedViewSize(width: width, height: height)
            )
        }
    }
}

/// A pinned tab as a cell in the block at the top of the column — as wide as
/// its row asks for, but never taller than the classic square, so a row with
/// room to spare turns into a wide, short button rather than a bigger icon.
private struct PinSquare: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let pill: Namespace.ID
    var width: CGFloat = 34
    var height: CGFloat = 34

    @State private var hovering = false

    /// Everything drawn inside scales off the shorter edge — the one that
    /// stays put — so the glyph sits at its usual size, centred, rather than
    /// stretching to chase the width.
    private var scale: CGFloat { min(width, height) }

    var body: some View {
        Group {
            if browser.editingPin == tab.id {
                PinField(browser: browser, tab: tab)
            } else if prefs.glyph == .icons, let icon = tab.icon {
                Mark(icon: icon, letter: tab.pin ?? "", size: scale * 16 / 34)
            } else {
                Text(tab.pin ?? "")
                    .font(.system(size: scale * 12 / 34, weight: .medium))
                    .foregroundStyle(live ? Palette.ink : Palette.muted)
            }
        }
        .frame(width: scale * 16 / 34, height: scale * 16 / 34)
        .frame(width: width, height: height)
        .background {
            if live {
                RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous)
                    .fill(Palette.wash)
                    .matchedGeometryEffect(id: "live", in: pill)
            } else {
                RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous)
                    .fill(hovering ? Palette.hover : Palette.wash.opacity(0.55))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: scale * 9 / 34, style: .continuous))
        .modifier(OneClick(double: live) {
            if live { browser.editLetter(tab) } else { browser.select(tab) }
        })
        // Put down, like ⌘W: close() is what knows a pin isn't removed.
        .overlay { MiddleClick { browser.close(tab) } }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: { browser.close(tab) }) }
        .help(tab.label)
        .animation(Motion.quick, value: hovering)
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// The rows, scrolling, with a thin bar drawn in place of the system's.
///
/// The system's bar lies over the rows' right edge, on top of the close
/// button of the tab under the pointer, so it was easy to hit one when
/// aiming for the other. This bar sits in the margin to the right of the
/// rows instead, and shows while the pointer is over them. It takes no
/// clicks, because that margin is also where the column is resized.
private struct ThinScroll<Content: View>: View {
    @ViewBuilder let content: Content

    /// The height of the area on screen.
    @State private var visible: CGFloat = 0
    /// The height of all the rows.
    @State private var total: CGFloat = 0
    /// How far the rows are scrolled down.
    @State private var scrolled: CGFloat = 0
    @State private var hovering = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content
                .background {
                    GeometryReader { box in
                        Color.clear
                            .onChange(of: box.frame(in: .named("scroll")), initial: true) { _, frame in
                                total = frame.height
                                scrolled = -frame.minY
                            }
                    }
                }
        }
        // Hidden is not enough: with a mouse plugged in, or "Show scroll
        // bars: Always", macOS brings its own bar back for a hidden one —
        // over the crosses again.
        .scrollIndicators(.never)
        .coordinateSpace(name: "scroll")
        .background {
            GeometryReader { box in
                Color.clear
                    .onChange(of: box.size.height, initial: true) { _, height in visible = height }
            }
        }
        .overlay(alignment: .topTrailing) { bar }
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        // Rows that fit neither scroll nor clip, as the plain stack they
        // stand in for: a line carried up to the squares stays in sight.
        .scrollDisabled(fits)
        .scrollClipDisabled(fits)
        .scrollBounceBehavior(.basedOnSize)
    }

    private var fits: Bool { total <= visible + 0.5 }

    @ViewBuilder
    private var bar: some View {
        if total > visible, visible > 0 {
            let length = max(24, visible * visible / total)
            let progress = min(max(scrolled / (total - visible), 0), 1)
            Capsule()
                .fill(Palette.ink.opacity(0.22))
                .frame(width: 3, height: length)
                .offset(x: 6, y: progress * (visible - length))
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(false)
        }
    }
}

/// One tab, as a line in the column.
private struct SideRow: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let pill: Namespace.ID
    let close: () -> Void

    @State private var hovering = false
    @State private var shake: CGFloat = 0

    /// A pinned line's button unpins it; any other line's closes it.
    private var unpins: Bool { tab.kept }

    private var editing: Bool { browser.editingTab == tab.id }

    /// The ring or the speaker, which stay for as long as the page loads or
    /// plays and so keep a place of their own at the end of the row. The
    /// cross is only there under the pointer, and takes none.
    private var status: Bool { !editing && (tab.loading || tab.noisy) }

    var body: some View {
        HStack(spacing: 8) {
            if editing {
                TabAddressField(browser: browser)
                    .frame(height: prefs.tabSize.field)
            } else {
                if prefs.glyph == .icons, !tab.isBlank {
                    Mark(icon: tab.icon, letter: tab.monogram, size: prefs.tabSize.mark)
                }
                if tab.bench {
                    // A script's tab, not yours.
                    Image(systemName: "flask")
                        .font(.system(size: 9))
                        .foregroundStyle(colour.opacity(0.7))
                }
                if tab.shy {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(colour.opacity(0.7))
                }
                Text(tab.label)
                    .font(.system(size: prefs.tabSize.text))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(colour)
            }

            if status {
                Spacer(minLength: 2)

                ZStack {
                    if tab.loading {
                        Ring(size: prefs.tabSize.ring).transition(.opacity)
                    } else {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: prefs.tabSize.glyph))
                            .foregroundStyle(Palette.muted)
                            .transition(.opacity)
                    }
                }
                .frame(width: prefs.tabSize.cross, height: prefs.tabSize.cross)
                // The cross takes this place while the pointer is here.
                .opacity(hovering ? 0 : 1)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, status ? 7 : 10)
        .frame(height: prefs.tabSize.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The title keeps its length under the pointer and fades out
        // beneath the cross, rather than being cut shorter, so its end
        // doesn't jump on each row the pointer passes.
        .mask {
            ZStack {
                Rectangle().opacity(hovering && !editing && !status ? 0 : 1)
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 16)
                    Color.clear.frame(width: prefs.tabSize.cross + 11)
                }
            }
        }
        .overlay(alignment: .trailing) {
            if !editing {
                ZStack {
                    if hovering {
                        TabEnd(unpins: unpins, size: prefs.tabSize)
                            .transition(.opacity)
                    }
                }
                .frame(width: prefs.tabSize.cross, height: prefs.tabSize.cross)
                .overlay {
                    Color.clear
                        .frame(width: 30, height: prefs.tabSize.row)
                        .contentShape(Rectangle())
                        .onTapGesture { if hovering { endPressed() } }
                        .help(unpins ? "Unpin" : "")
                }
                .padding(.trailing, 7)
            }
        }
        .animation(Motion.quick, value: tab.loading)
        .animation(Motion.quick, value: tab.noisy)
        .background { ground }
        .modifier(Shake(travel: shake))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .modifier(OneClick(double: false) {
            if live { browser.beginTabEdit(tab) } else { browser.select(tab) }
        })
        // A pinned line with no page has nothing to put down.
        .overlay { MiddleClick { if !(tab.kept && tab.asleep) { close() } } }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: close) }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.glide, value: editing)
        .onChange(of: browser.refusals) { _, _ in
            guard editing else { return }
            shake = 0
            withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
        }
        .transition(.scale(scale: 0.94, anchor: .leading).combined(with: .opacity))
    }

    private func endPressed() {
        if unpins {
            withAnimation(Motion.settle) { browser.unkeep(tab) }
        } else {
            close()
        }
    }

    @ViewBuilder
    private var ground: some View {
        if live {
            ZStack(alignment: .leading) {
                Rectangle().fill(Palette.wash)
                if prefs.showsReading {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Palette.ink.opacity(0.055))
                            .frame(width: geo.size.width * tab.reading)
                            .animation(.easeOut(duration: 0.15), value: tab.reading)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            // On glass, an edge of light round it, as a pane of it would have.
            .overlay {
                if prefs.theme.isGlass {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Palette.ink.opacity(0.08), lineWidth: 1)
                }
            }
            .matchedGeometryEffect(id: "live", in: pill)
        } else if hovering {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.hover)
        }
    }

    private var colour: Color {
        if live { return Palette.ink }
        return hovering ? Palette.ink.opacity(0.7) : Palette.muted
    }
}

/// "Pinned", over the tabs pinned as lines. A click folds them under it and
/// brings them back; folded, a dot says one of them has its page open.
private struct PinnedHeading: View {
    @ObservedObject var prefs: Preferences
    /// One of the pinned lines has its page open.
    let open: Bool

    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(Motion.settle) { prefs.pinnedFolded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text("Pinned")
                    .font(.system(size: 11, weight: .medium))
                if prefs.pinnedFolded, open {
                    Circle().fill(Palette.muted).frame(width: 4, height: 4)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(prefs.pinnedFolded ? -90 : 0))
                    .opacity(hovering ? 1 : 0)
            }
            .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.muted)
            .padding(.horizontal, 10)
            .frame(height: SideBar.heading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.settle, value: prefs.pinnedFolded)
    }
}

/// The line between the pinned tabs and the rest, with Clear at its end:
/// every tab under it goes, the pinned ones and the squares stay.
private struct ClearLine: View {
    let clears: Bool
    let clear: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            if clears {
                Button(action: clear) {
                    Text("Clear")
                        .font(.system(size: 11))
                        .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.faint)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("Close every tab that isn't pinned")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: SideBar.divider)
        .animation(Motion.quick, value: hovering)
    }
}

/// A row that is an action rather than a page. Quiet until the pointer is on it.
struct Quiet: View {
    let icon: String
    let title: String
    var height: CGFloat = 28
    /// The title's size, kept with the tabs' it sits under.
    var text: CGFloat = 12.5
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 15)
                Text(title)
                    .font(.system(size: text))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.faint)
            .padding(.leading, 10)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering ? Palette.hover : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// A small square holding one symbol. Lit when what it opens is open.
struct Door: View {
    let icon: String
    var on = false
    var help = ""
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(on ? Palette.ink : (hovering ? Palette.ink.opacity(0.7) : Palette.muted))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? Palette.wash : (hovering ? Palette.hover : .clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: on)
    }
}
