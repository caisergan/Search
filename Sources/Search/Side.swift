import SwiftUI
import Combine

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
    /// Where the line held would go if let go now. The others make way for
    /// it by this alone; the row itself changes once, when it is let go.
    @State private var aimed: Aim?
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

    static let gap: CGFloat = 2
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
                    .frame(width: Metrics.helm + (prefs.showsGhostMenu ? Metrics.ghostDoor : 0))
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
                    HStack(spacing: 4) {
                        Helm(browser: browser)
                        if prefs.showsGhostMenu { GhostDoor(browser: browser) }
                    }
                    Spacer(minLength: 0)
                    // The downloads and the extensions, in the corner
                    // across from the lights, with or without the door.
                    DownloadsAndExtensions(always: true, room: extensionRoom)
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
        .animation(Motion.settle, value: browser.groups)
        .animation(Motion.settle, value: browser.closedGroups.map(\.id))
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
                withAnimation(Motion.settle) { prefs.sideWidth = Metrics.side(ghosts: prefs.showsGhostMenu) }
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
        let clears = row.tabs.contains { $0.place == .loose && $0.group == nil }
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
            ForEach(SideBar.pieces(of: row.tabs, active: row.active, folded: prefs.pinnedFolded, groups: row.groups)) { piece in
                switch piece {
                case .heading:
                    PinnedHeading(prefs: prefs, open: open)
                case .tab(let tab):
                    SideBar.nested(tab) {
                        SideRow(browser: browser, prefs: prefs, tab: tab, live: tab.id == row.active, pill: pill, close: {})
                    }
                case .divider:
                    ClearLine(clears: clears, groups: false, group: {}, clear: {})
                case .group(let group, let members):
                    GroupLine(browser: browser, prefs: prefs, group: group, members: members)
                case .closed(let closed):
                    ClosedLine(browser: browser, prefs: prefs, closed: closed)
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
    /// Clear, what is under it and the row that makes another. The same sum
    /// the drags work from, so the three can't disagree.
    private var rowsHeight: CGFloat {
        keptBlock + SideBar.divider + CGFloat(lines.count) * step + (prefs.newTabInFoot ? 0 : row)
    }

    /// What is drawn under the line with Clear, all of it a line's height.
    private var lines: [Piece] {
        SideBar.lines(of: browser.tabs, active: browser.activeID, groups: browser.groups, closed: browser.closedGroups)
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
                    let target = aim(places.gridTop + value.location.y - places.rowsTop, holding: tab)
                    withAnimation(Motion.settle) { land(tab, target) }
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
        let index = lines.firstIndex {
            if case .tab(let other) = $0 { return other.id == tab.id }
            return false
        } ?? 0
        return keptBlock + SideBar.divider + CGFloat(index) * step
    }

    /// Where a tab held in the rows would go.
    private enum Aim: Equatable {
        case kept(Int)
        /// Before this one of a group's tabs; with none, into a folded group.
        case group(TabGroup.ID, Int?)
        case free(Int)
    }

    /// Everything under the line but the tab in the hand.
    private func others(than held: Tab.ID) -> [Piece] {
        lines.filter {
            if case .tab(let other) = $0 { return other.id != held }
            return true
        }
    }

    /// Where a tab whose middle is held at `y` in the rows' space would go:
    /// among the pinned lines while it is nearer the last of them than the
    /// first thing under Clear, and under it, whatever it is over — so over a
    /// group's line it goes into the group. Measured against the others alone,
    /// which don't move as it does, so the aim can't swing back and forth
    /// under a hand held still.
    private func aim(_ y: CGFloat, holding tab: Tab) -> Aim {
        let kept = shownKept.filter { $0.id != tab.id }.count
        let head = browser.keptCount > 0 ? SideBar.heading : 0
        func nearest(from top: CGFloat) -> Int { Int(((y - top - row / 2) / step).rounded()) }
        // A tab with no address can't be pinned (see `Browser.put`).
        if !tab.isBlank, y < head + CGFloat(kept) * step + (SideBar.divider + row) / 2 {
            return .kept(min(max(0, nearest(from: head)), kept))
        }
        let free = looseTabs.filter { $0.group == nil && $0.id != tab.id }
        let at = max(0, nearest(from: head + CGFloat(kept) * step + SideBar.divider))
        for piece in others(than: tab.id).dropFirst(at) {
            switch piece {
            case .group(let group, _):
                return .group(group.id, group.folded ? nil : 0)
            case .tab(let other):
                if let id = other.group {
                    // Folded, the one tab showing is no place to aim between.
                    guard browser.groups.first(where: { $0.id == id })?.folded == false else { return .group(id, nil) }
                    let beside = looseTabs.filter { $0.group == id && $0.id != tab.id }
                    return .group(id, beside.firstIndex { $0.id == other.id })
                }
                return .free(free.firstIndex { $0.id == other.id } ?? free.count)
            default:
                continue
            }
        }
        return .free(free.count)
    }

    /// Whether the tab already has that place.
    private func holds(_ tab: Tab, _ aim: Aim) -> Bool {
        switch aim {
        case .kept(let slot):
            guard tab.place == .kept else { return false }
            return prefs.pinnedFolded || keptTabs.firstIndex { $0.id == tab.id } == slot
        case .group(let group, let slot):
            guard tab.group == group else { return false }
            guard let slot else { return true }
            return looseTabs.filter { $0.group == group }.firstIndex { $0.id == tab.id } == slot
        case .free(let slot):
            return tab.place == .loose && tab.group == nil
                && looseTabs.filter { $0.group == nil }.firstIndex { $0.id == tab.id } == slot
        }
    }

    /// Puts a tab where an aim says, in the row itself. Folded, the pinned
    /// lines out of sight can't be aimed between: one already pinned stays
    /// where it is, and another goes at their end — which opens them to show
    /// it (see `Browser.put`).
    private func land(_ tab: Tab, _ aim: Aim) {
        guard !holds(tab, aim) else { return }
        switch aim {
        case .kept(let slot):
            let slot = prefs.pinnedFolded ? keptTabs.count : slot
            if tab.place == .kept {
                browser.move(tab, to: browser.block(.kept).lowerBound + slot)
            } else {
                browser.put(tab, .kept, at: slot)
            }
        case .group(let group, let slot):
            browser.put(tab, into: group, at: slot)
        case .free(let slot):
            browser.put(tab, into: nil, at: slot)
        }
    }

    /// How far each of the other lines, and the line with Clear, stands off
    /// its place while a line is held: they close up behind it and open a gap
    /// where it is aimed, as if it were already there. A folded group opens
    /// none: what goes in goes out of sight.
    private func makingWay() -> (lines: [AnyHashable: CGFloat], divider: CGFloat) {
        guard let held = dragging, let aimed else { return ([:], 0) }
        let head = browser.keptCount > 0 ? SideBar.heading : 0
        let kept = shownKept.filter { $0.id != held }
        var keptGap: Int?
        if case .kept(let slot) = aimed { keptGap = slot }
        let dividerTop = head + CGFloat(kept.count + (keptGap == nil ? 0 : 1)) * step

        var way: [AnyHashable: CGFloat] = [:]
        for (index, tab) in kept.enumerated() {
            let room = keptGap.map { index >= $0 ? 1 : 0 } ?? 0
            way[tab.id] = head + CGFloat(index + room) * step - top(of: tab)
        }

        let drawn = lines
        let under = others(than: held)
        var gap: Int?
        switch aimed {
        case .kept, .group(_, nil):
            break
        case .group(let id, let slot?):
            let line = under.firstIndex {
                if case .group(let group, _) = $0 { return group.id == id }
                return false
            }
            gap = line.map { $0 + 1 + slot }
        case .free(let slot):
            let free = under.indices.filter {
                if case .tab(let tab) = under[$0] { return tab.group == nil }
                return false
            }
            gap = slot < free.count ? free[slot] : under.count
        }
        var now: [AnyHashable: Int] = [:]
        for (index, piece) in drawn.enumerated() { now[piece.id] = index }
        let top = dividerTop + SideBar.divider
        for (index, piece) in under.enumerated() {
            let room = gap.map { index >= $0 ? 1 : 0 } ?? 0
            let drawnAt = keptBlock + SideBar.divider + CGFloat(now[piece.id] ?? index) * step
            way[piece.id] = top + CGFloat(index + room) * step - drawnAt
        }
        return (way, dividerTop - keptBlock)
    }

    /// One piece of the rows: the heading over the pinned lines, a tab's
    /// line, the line with Clear, or a group's line, closed or not.
    private enum Piece: Identifiable {
        case heading
        case tab(Tab)
        case divider
        case group(TabGroup, [Tab])
        case closed(ClosedGroup)

        var id: AnyHashable {
            switch self {
            case .heading: return "heading"
            case .tab(let tab): return tab.id
            case .divider: return "divider"
            case .group(let group, _): return group.id
            case .closed(let closed): return closed.id
            }
        }
    }

    /// A row's pieces top to bottom, as one list. A line is the same view on
    /// either side of the divider: drawn by two lists, crossing from one to
    /// the other made it a new view, the drag it was under ended with the
    /// old one, and the line stayed held where it was left, over another.
    /// Folded, the pinned line on screen still shows (see `shownKept`).
    private static func pieces(
        of tabs: [Tab], active: Tab.ID?, folded: Bool,
        groups: [TabGroup] = [], closed: [ClosedGroup] = []
    ) -> [Piece] {
        let kept = tabs.filter { $0.place == .kept }
        var pieces: [Piece] = []
        if !kept.isEmpty {
            pieces.append(.heading)
            pieces += kept.filter { !folded || $0.id == active }.map(Piece.tab)
        }
        pieces.append(.divider)
        pieces += lines(of: tabs, active: active, groups: groups, closed: closed)
        return pieces
    }

    /// The pieces under the divider: the groups, each line followed by the
    /// tabs it shows, and then the tabs in no group. A folded group still
    /// shows the tab you are on, as the pinned lines do.
    private static func lines(of tabs: [Tab], active: Tab.ID?, groups: [TabGroup], closed: [ClosedGroup]) -> [Piece] {
        let loose = tabs.filter { $0.place == .loose }
        var waiting = closed.sorted { $0.at < $1.at }
        var lines: [Piece] = []
        for (index, group) in groups.enumerated() {
            while let next = waiting.first, next.at <= index { lines.append(.closed(waiting.removeFirst())) }
            let members = loose.filter { $0.group == group.id }
            guard !members.isEmpty else { continue }
            lines.append(.group(group, members))
            lines += members.filter { !group.folded || $0.id == active }.map(Piece.tab)
        }
        lines += waiting.map(Piece.closed)
        lines += loose.filter { $0.group == nil }.map(Piece.tab)
        return lines
    }

    /// A tab's line with the air under it, and in a group, set in from the
    /// group's chevron with a hairline running down from it. One view either
    /// way: a line going into a group under the hand stays the line it was.
    private static func nested<Content: View>(_ tab: Tab, @ViewBuilder content: () -> Content) -> some View {
        let inside = tab.group != nil
        return content()
            .padding(.leading, inside ? 20 : 0)
            .background(alignment: .leading) {
                Rectangle()
                    .fill(Palette.hairline)
                    .frame(width: 1)
                    .padding(.leading, 18)
                    .opacity(inside ? 1 : 0)
            }
    }

    private func line(_ tab: Tab, making way: CGFloat) -> some View {
        let held = dragging == tab.id
        return SideBar.nested(tab) {
            SideRow(
                browser: browser,
                prefs: prefs,
                tab: tab,
                live: tab.id == browser.activeID,
                pill: pill,
                close: { browser.close(tab, asking: true) }
            )
        }
        .offset(y: held ? startY + travel - top(of: tab) : way)
        // Under the hand exactly; only the others glide. Its place in the
        // row stays put until it is let go: moved as it passed each tab, the
        // place sprang there while the offset didn't, a transaction here
        // can't stop a place its stack gives it from springing, and the tab
        // jumped back a whole slot and drifted forward each time.
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
                    places.held = tab.id
                }
                travel = value.translation.height
                overGrid = over(value, holding: tab)
                // Over the squares, the lines go back to their places.
                let target = overGrid ? nil : aim(startY + travel + row / 2, holding: tab)
                if target != aimed {
                    withAnimation(Motion.settle) { aimed = target }
                }
            }
            .onEnded { value in
                // Read from the gesture, not from state: whether this runs
                // before or after the reset above is SwiftUI's to say. The
                // line springs from under the hand to its new place, and the
                // others from the gap they made to the same place in the row:
                // their offsets and their places spring together, and cancel.
                if places.held == tab.id {
                    withAnimation(Motion.settle) {
                        if over(value, holding: tab) {
                            browser.pin(tab)
                        } else {
                            land(tab, aim(startY + value.translation.height + row / 2, holding: tab))
                        }
                    }
                }
                places.held = nil
                letGoOfLine()
            }
    }

    /// The pointer up over the squares, holding a line that can be one.
    private func over(_ value: DragGesture.Value, holding tab: Tab) -> Bool {
        browser.pinnedCount > 0 && !tab.isBlank && places.rowsTop + value.location.y < places.gridBottom + 4
    }

    private func letGoOfLine() {
        guard dragging != nil || travel != 0 || overGrid || aimed != nil else { return }
        withAnimation(Motion.settle) {
            dragging = nil
            travel = 0
            overGrid = false
            aimed = nil
        }
    }

    /// The pinned lines under their heading, the line with Clear, the other
    /// tabs and the row that makes another, which scroll as one — unless
    /// the way to another is down in the foot.
    private var rows: some View {
        let open = keptTabs.contains { !$0.asleep }
        let clears = looseTabs.contains { $0.group == nil }
        let way = makingWay()
        var aimedGroup: TabGroup.ID?
        if case .group(let id, _) = aimed { aimedGroup = id }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(SideBar.pieces(
                of: browser.tabs, active: browser.activeID, folded: prefs.pinnedFolded,
                groups: browser.groups, closed: browser.closedGroups
            )) { piece in
                switch piece {
                case .heading:
                    PinnedHeading(prefs: prefs, open: open)
                case .tab(let tab):
                    line(tab, making: way.lines[tab.id] ?? 0)
                case .divider:
                    ClearLine(
                        clears: clears,
                        groups: prefs.tabGroups && browser.canGroup,
                        group: { withAnimation(Motion.settle) { browser.groupBySite() } },
                        clear: { withAnimation(Motion.settle) { browser.clearTabs() } }
                    )
                    .offset(y: way.divider)
                case .group(let group, let members):
                    GroupLine(browser: browser, prefs: prefs, group: group, members: members, aimedAt: aimedGroup == group.id)
                        .offset(y: way.lines[group.id] ?? 0)
                case .closed(let closed):
                    ClosedLine(browser: browser, prefs: prefs, closed: closed)
                        .offset(y: way.lines[closed.id] ?? 0)
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
    /// The pinned extension buttons that fit between reload (or the
    /// recently closed door after it) and the puzzle: the column less its
    /// padding, the lights, the doors and the puzzle with a little air, at a
    /// door and its gap each.
    private var extensionRoom: Int {
        let ghost = prefs.showsGhostMenu ? Metrics.ghostDoor : 0
        let free = prefs.sideWidth - 20 - Metrics.sideLights - (3 * 26 + 2 * 2) - ghost - 26 - 4
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
    /// The line a drag has picked up, which outlives the state saying so:
    /// that may be put back before the drag's end is heard.
    var held: Tab.ID?
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
        .overlay { MiddleClick { browser.close(tab, asking: true) } }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: { browser.close(tab, asking: true) }) }
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
    /// plays (or is muted) and so keep a place of their own at the end of the
    /// row. The cross is only there under the pointer, and takes none.
    private var status: Bool { !editing && (tab.loading || speaker) }
    /// The speaker, which can be pressed, and so steps in beside the cross
    /// under the pointer rather than hiding beneath it as the ring does.
    private var speaker: Bool { !tab.loading && (tab.noisy || tab.muted) }

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
                if tab.capture.any {
                    CaptureMark(tab: tab)
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
                        Speaker(tab: tab).transition(.opacity)
                    }
                }
                .frame(width: prefs.tabSize.cross, height: prefs.tabSize.cross)
                // The cross takes this place while the pointer is here; the
                // speaker moves one place in, clear of the cross's reach.
                .opacity(hovering && !speaker ? 0 : 1)
                .padding(.trailing, hovering && speaker ? prefs.tabSize.cross + 8 : 0)
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
        .animation(Motion.quick, value: speaker)
        .background { ground }
        .modifier(Shake(travel: shake))
        // The gap under the line is the line's to the pointer: left out, the
        // pointer fell between two lines for a pixel on its way down, and the
        // hover and the cursor flickered off and back.
        .padding(.bottom, SideBar.gap)
        .contentShape(Rectangle())
        .modifier(OneClick(double: false) {
            if live { browser.beginTabEdit(tab) } else { browser.select(tab) }
        })
        // A pinned line with no page has nothing to put down.
        .overlay { MiddleClick { if !(tab.kept && tab.asleep) { close() } } }
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(browser: browser, tab: tab, close: close) }
        // The browser doesn't hear a tab go somewhere, and where its tabs are
        // is what says whether Group has anything to do.
        .onChange(of: tab.address) { _, _ in
            if prefs.tabGroups, tab.group == nil { browser.objectWillChange.send() }
        }
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

/// The line between the pinned tabs and the rest, with Group and Clear at its
/// end: Group gathers the tabs under it by site, Clear closes the ones in no
/// group. The pinned ones and the squares are neither's.
private struct ClearLine: View {
    let clears: Bool
    let groups: Bool
    let group: () -> Void
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            if groups {
                LineWord(title: "Group", help: "Gather the tabs that aren't pinned by site", act: group)
            }
            if clears {
                LineWord(title: "Clear", help: "Close every tab that isn't pinned or in a group", act: clear)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: SideBar.divider)
    }
}

private struct LineWord: View {
    let title: String
    let help: String
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.faint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .transition(.opacity)
        .animation(Motion.quick, value: hovering)
    }
}

/// A group's line: a click folds or opens it, a double-click renames it, and
/// under the pointer its end offers Ungroup and the cross.
private struct GroupLine: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    let group: TabGroup
    let members: [Tab]
    /// A tab in the hand would go into it if let go now.
    var aimedAt = false

    @State private var hovering = false

    /// What the end of the line keeps to itself under the pointer, out of
    /// reach of the press (a real view, asked before any other; see DragStrip).
    private static let endRoom: CGFloat = 112

    private var editing: Bool { browser.editingGroup == group.id }
    private var open: Bool { hovering && !editing }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.down")
                .font(.system(size: 8.5, weight: .semibold))
                .rotationEffect(.degrees(group.folded ? -90 : 0))
                .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.muted)
                .frame(width: prefs.tabSize.mark)
            if prefs.glyph == .icons {
                GroupMark(tabs: members, letter: String(group.name.prefix(1)).uppercased(), size: prefs.tabSize.mark)
            }
            if editing {
                GroupNameField(browser: browser, group: group, size: prefs.tabSize.text)
                    .frame(height: prefs.tabSize.field)
            } else {
                Text(group.name)
                    .font(.system(size: prefs.tabSize.text, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, open ? GroupLine.endRoom : 34)
        .frame(height: prefs.tabSize.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(aimedAt ? Palette.wash : hovering ? Palette.hover : .clear)
        }
        // The gap under it is its own to the pointer, as a tab's line's is.
        .padding(.bottom, SideBar.gap)
        .contentShape(Rectangle())
        .overlay {
            if !editing {
                GroupPress { clicks in
                    withAnimation(Motion.settle) {
                        // The first of two has folded or opened it already.
                        browser.toggleFold(group.id)
                        if clicks >= 2 { browser.beginGroupRename(group.id) }
                    }
                }
                .padding(.trailing, open ? GroupLine.endRoom : 0)
            }
        }
        .overlay(alignment: .trailing) { end.padding(.bottom, SideBar.gap) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename") { browser.beginGroupRename(group.id) }
            Button(group.folded ? "Expand" : "Collapse") {
                withAnimation(Motion.settle) { browser.toggleFold(group.id) }
            }
            Divider()
            Button("Ungroup") { withAnimation(Motion.settle) { browser.ungroup(group.id) } }
            Button(members.count == 1 ? "Close 1 Tab" : "Close \(members.count) Tabs") {
                withAnimation(Motion.settle) { browser.closeGroup(group.id) }
            }
        }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: aimedAt)
        .transition(.opacity)
    }

    private var end: some View {
        HStack(spacing: 6) {
            // Nothing of it to see until one of them plays. Each hears its
            // own tab: the browser doesn't hear a page start to.
            ZStack {
                ForEach(members) { GroupSound(tab: $0) }
            }
            if open {
                GroupWord(title: "Ungroup", help: "Keep the tabs, drop the group") {
                    withAnimation(Motion.settle) { browser.ungroup(group.id) }
                }
                Button {
                    withAnimation(Motion.settle) { browser.closeGroup(group.id) }
                } label: {
                    TabEnd(unpins: false, size: prefs.tabSize)
                }
                .buttonStyle(.plain)
                .help(members.count == 1 ? "Close 1 tab" : "Close \(members.count) tabs")
            } else {
                Text("\(members.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Palette.muted)
                    .allowsHitTesting(false)
                    .padding(.trailing, 3)
            }
        }
        .padding(.trailing, 7)
    }
}

/// The site's mark on a group's line: the icon of the first of its tabs that
/// has one, and the name's letter until one does. Each tab is listened to, as
/// a sleeping tab's icon may arrive long after the line is drawn.
private struct GroupMark: View {
    let tabs: [Tab]
    let letter: String
    let size: CGFloat

    @State private var heard = 0

    var body: some View {
        let _ = heard
        Mark(icon: tabs.lazy.compactMap(\.icon).first, letter: letter, size: size)
            .onReceive(Publishers.MergeMany(tabs.map(\.$icon))) { _ in
                // Said as it is about to change: read once it has.
                DispatchQueue.main.async { heard &+= 1 }
            }
    }
}

/// The speaker of a tab playing out of sight in a group: press it to quiet the
/// tab, which then has no more to say here.
private struct GroupSound: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if tab.noisy, !tab.muted { Speaker(tab: tab) }
    }
}

private struct GroupWord: View {
    let title: String
    let help: String
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.muted)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Palette.ink.opacity(hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(Motion.quick, value: hovering)
    }
}

/// A press on a group's line, and how many clicks it was. The press has to be
/// done with at once for a fold to feel like one, which rules out SwiftUI's
/// pair of tap gestures: with both, the single waits to be sure it is one. So
/// a real view, there for the left button and nothing else (see MiddleClick).
struct GroupPress: NSViewRepresentable {
    let act: (Int) -> Void

    func makeNSView(context: Context) -> NSView { GroupPresser() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? GroupPresser)?.act = act
    }
}

final class GroupPresser: NSView {
    var act: (Int) -> Void = { _ in }
    private var pressed = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseUp
        else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        act(event.clickCount)
    }
}

/// A group's name being typed: Return or a press anywhere else keeps it, and
/// esc leaves it as it was. As a tab's own field (TabAddressField).
private struct GroupNameField: NSViewRepresentable {
    @ObservedObject var browser: Browser
    let group: TabGroup
    let size: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser, id: group.id) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: size, weight: .medium)
        field.textColor = Palette.NS.ink
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.stringValue = group.name
        context.coordinator.watch(field)
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.11)),
                .foregroundColor: Palette.NS.ink,
            ]
            editor.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {}

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.unwatch()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let browser: Browser
        let id: TabGroup.ID
        private var watcher: Any?

        init(browser: Browser, id: TabGroup.ID) {
            self.browser = browser
            self.id = id
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                browser.finishGroupRename(id, name: control.stringValue)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                browser.finishGroupRename(id, name: "")
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            browser.finishGroupRename(id, name: field.stringValue)
        }

        /// A press on what takes no focus leaves the field focused, so presses
        /// are watched for while it is there (see TabAddressField).
        @MainActor func watch(_ field: NSTextField) {
            watcher = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak field] event in
                guard let self, let field, event.window === field.window,
                      !field.bounds.contains(field.convert(event.locationInWindow, from: nil))
                else { return event }
                let (browser, id, name) = (self.browser, self.id, field.stringValue)
                DispatchQueue.main.async { browser.finishGroupRename(id, name: name) }
                return event
            }
        }

        @MainActor func unwatch() {
            if let watcher { NSEvent.removeMonitor(watcher) }
            watcher = nil
        }
    }
}

/// Where a group was, just after its cross: the line says how many went, and
/// for a moment they can come back.
private struct ClosedLine: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    let closed: ClosedGroup

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(closed.pages.count == 1 ? "1 tab closed" : "\(closed.pages.count) tabs closed")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 0)
            Button {
                withAnimation(Motion.settle) { browser.reopenGroup(closed) }
            } label: {
                Text("Undo")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Palette.ink.opacity(hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .frame(height: prefs.tabSize.row)
        .padding(.bottom, SideBar.gap)
        .animation(Motion.quick, value: hovering)
        .transition(.opacity)
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

/// The speaker at the end of a tab that plays sound, or that was muted and
/// so says it is: a press mutes the tab or lets it be heard again. Drawn as
/// it was before it could be pressed, with the cross's faint disc behind
/// it only while the pointer is on it.
struct Speaker: View {
    @ObservedObject var tab: Tab

    @State private var hovering = false

    var body: some View {
        Button(action: tab.toggleMute) {
            Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 8))
                .foregroundStyle(Palette.muted)
                .frame(width: 15, height: 15)
                .background(Palette.ink.opacity(hovering ? 0.07 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tab.muted ? "Unmute Tab" : "Mute Tab")
        .animation(Motion.quick, value: hovering)
    }
}

/// A tab using the camera, the microphone or the screen says so, in red,
/// before its name — whichever tab it is, on screen or not. A press holds
/// them all quiet, and another brings them back (see Tab.toggleCapturePause).
struct CaptureMark: View {
    @ObservedObject var tab: Tab

    @State private var hovering = false

    var body: some View {
        Button(action: tab.toggleCapturePause) {
            Image(systemName: tab.capture.symbol)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(tab.capture.live ? Color(nsColor: .systemRed) : Palette.muted)
                .frame(width: 15, height: 15)
                .background(Palette.ink.opacity(hovering ? 0.07 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tab.capture.help)
        .animation(Motion.quick, value: hovering)
    }
}

/// A small square holding one symbol. Lit when what it opens is open.
struct Door: View {
    let icon: String
    var on = false
    /// The symbol stood on end, about its middle: the three dots of a menu,
    /// which SF Symbols only draws lying down.
    var turned = false
    var help = ""
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .rotationEffect(.degrees(turned ? 90 : 0))
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
