import SwiftUI

// What the window shows of Downloads.swift: the page of every download
// (⇧⌘J).

struct DownloadsPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var downloads: Downloads

    var body: some View {
        Plate("Downloads", width: 560, close: { browser.hoarding = false }) {
            if downloads.items.isEmpty {
                Card { Nothing("Nothing downloaded yet.") }
            } else {
                ScrollView(showsIndicators: false) {
                    Card {
                        ForEach(Array(downloads.items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Rule() }
                            Row(item: item, downloads: downloads)
                        }
                    }
                    .padding(.bottom, 2)
                }
                .frame(maxHeight: 420)
            }
        } foot: {
            HStack {
                Text(downloads.items.isEmpty ? "Files land in \(browser.downloadsFolder.lastPathComponent)"
                     : "Clearing the list leaves the files where they are")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                Spacer()
                if !downloads.items.isEmpty {
                    Pill("Clear list") { downloads.clear() }
                }
            }
        }
    }

    private struct Row: View {
        @ObservedObject var item: Download
        let downloads: Downloads

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: item.there ? "doc" : "doc.badge.ellipsis")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(item.there ? Palette.muted : Palette.faint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.host.isEmpty ? When.said(item.started) : "\(item.host) · \(When.said(item.started))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if hovering {
                    if item.active { Quick("Pause") { downloads.pause(item) } }
                    if item.stopped { Quick("Resume") { downloads.resume(item) } }
                    if item.there { Quick("Show in Finder") { downloads.reveal(item) } }
                    Quick("Remove", tint: .red.opacity(0.75)) { downloads.remove(item) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
            .onTapGesture { if item.state == .done { downloads.open(item) } }
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}
