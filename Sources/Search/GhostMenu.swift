import AppKit
import SwiftUI

/// The vertical three-dot menu for reopening recently closed tabs.
struct TabGhostMenu: View {
    @ObservedObject var browser: Browser
    @State private var hovering = false

    var body: some View {
        Menu {
            if browser.ghosts.isEmpty {
                Text("No recently closed tabs")
            } else {
                ForEach(browser.ghosts.reversed().prefix(12)) { ghost in
                    Button {
                        browser.reopen(ghost)
                    } label: {
                        Label {
                            Text(ghost.label)
                        } icon: {
                            if let host = ghost.url.host()?.lowercased(),
                               let icon = Favicons.shared.cached(host) {
                                Image(nsImage: TabGhostMenu.small(icon))
                            } else {
                                Image(systemName: "globe")
                            }
                        }
                    }
                }
                Divider()
                Button("Reopen Last Closed Tab") {
                    browser.reopen()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.muted)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Palette.hover : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26, height: 26)
        .onHover { hovering = $0 }
        .help("Recently closed tabs")
        .animation(Motion.quick, value: hovering)
    }

    /// The cached icon is sixty-four points across; a menu wants sixteen.
    private static func small(_ icon: NSImage) -> NSImage {
        let copy = icon.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}
