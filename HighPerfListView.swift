import SwiftUI
import AppKit

// MARK: - PlaylistNSTableView
// NSTableView + NSHostingView cell 复用，替代 LazyVStack 解决滚动卡顿

struct PlaylistNSTableView: NSViewRepresentable {

    let items: [MusicBridge.FlatPlaylistItem]
    let currentPlaylistName: String
    let isPlaying: Bool
    let themeColor: Color
    let scrollToName: String?
    var onPlay:         (String) -> Void
    var onDrill:        (String) -> Void
    var onToggleFolder: (String) -> Void

    func makeCoordinator() -> PlaylistCoordinator { PlaylistCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = context.coordinator.tableView
        let col = NSTableColumn(identifier: .init("col"))
        col.isEditable = false
        tv.addTableColumn(col)
        tv.headerView = nil
        tv.backgroundColor = .clear
        tv.selectionHighlightStyle = .none
        tv.usesAlternatingRowBackgroundColors = false
        tv.intercellSpacing = .zero
        tv.style = .plain
        tv.dataSource = context.coordinator
        tv.delegate   = context.coordinator

        let sv = NSScrollView()
        sv.documentView = tv
        sv.drawsBackground = false
        sv.hasVerticalScroller   = false
        sv.hasHorizontalScroller = false
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator

        let needsFullReload = c.items.count != items.count ||
            zip(c.items, items).contains { $0.id != $1.id }

        // 只有影响显示的状态变化才触发可见行刷新
        let needsVisibleReload = !needsFullReload && (
            c.currentPlaylistName != currentPlaylistName ||
            c.isPlaying != isPlaying ||
            c.themeColor != themeColor
        )

        c.items               = items
        c.currentPlaylistName = currentPlaylistName
        c.isPlaying           = isPlaying
        c.themeColor          = themeColor
        c.onPlay              = onPlay
        c.onDrill             = onDrill
        c.onToggleFolder      = onToggleFolder

        let tv = c.tableView
        if needsFullReload {
            tv.reloadData()
        } else if needsVisibleReload {
            let range = tv.rows(in: tv.visibleRect)
            let visible = IndexSet(integersIn: range.lowerBound..<(range.upperBound + 1))
            if !visible.isEmpty {
                tv.reloadData(forRowIndexes: visible, columnIndexes: IndexSet(integer: 0))
            }
        }

        // 滚动到指定列表（仅当 scrollToName 变化时）
        if let name = scrollToName, name != c.lastScrolledTo,
           let idx = items.firstIndex(where: {
               if case .playlist(_, let pl) = $0 { return pl.name == name }
               return false
           }) {
            c.lastScrolledTo = name
            tv.scrollRowToVisible(idx)
        }
    }
}

// MARK: - PlaylistCoordinator

final class PlaylistCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    let tableView = NSTableView()
    var items: [MusicBridge.FlatPlaylistItem] = []
    var currentPlaylistName: String = ""
    var isPlaying: Bool = false
    var themeColor: Color = .pink
    var lastScrolledTo: String? = nil
    var onPlay:         (String) -> Void = { _ in }
    var onDrill:        (String) -> Void = { _ in }
    var onToggleFolder: (String) -> Void = { _ in }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch items[row] {
        case .folderHeader: return 27
        case .playlist:     return 39
        }
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        switch items[row] {

        case .folderHeader(let group, let collapsed):
            let id = NSUserInterfaceItemIdentifier("folder")
            let cell = tableView.makeView(withIdentifier: id, owner: nil)
                as? NSHostingView<FolderHeaderRowView>
                ?? makeHostingCell(id: id, root: FolderHeaderRowView(
                    group: group, collapsed: collapsed,
                    themeColor: themeColor, onTap: {}))
            cell.rootView = FolderHeaderRowView(
                group: group, collapsed: collapsed, themeColor: themeColor,
                onTap: { [weak self] in self?.onToggleFolder(group.folderName) }
            )
            return cell

        case .playlist(let group, let pl):
            let id = NSUserInterfaceItemIdentifier("playlist")
            let cell = tableView.makeView(withIdentifier: id, owner: nil)
                as? NSHostingView<PlaylistItemRowView>
                ?? makeHostingCell(id: id, root: PlaylistItemRowView(
                    group: group, pl: pl, isActive: false, isPlaying: false,
                    themeColor: themeColor, onPlay: {}, onDrill: {}))
            cell.rootView = PlaylistItemRowView(
                group: group, pl: pl,
                isActive:  pl.name == currentPlaylistName,
                isPlaying: isPlaying,
                themeColor: themeColor,
                onPlay:  { [weak self] in self?.onPlay(pl.name) },
                onDrill: { [weak self] in self?.onDrill(pl.name) }
            )
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = NSTableRowView()
        v.isEmphasized = false
        return v
    }

    private func makeHostingCell<V: View>(id: NSUserInterfaceItemIdentifier, root: V) -> NSHostingView<V> {
        let h = NSHostingView(rootView: root)
        h.identifier = id
        h.autoresizingMask = [.width, .height]
        return h
    }
}

// MARK: - TrackNSTableView

struct TrackNSTableView: NSViewRepresentable {

    let tracks: [PlaylistTrackItem]
    let currentTrackTitle:  String
    let currentTrackArtist: String
    let isPlaying:       Bool
    let showTrackNumber: Bool
    let themeColor: Color
    var onTap: (Int) -> Void

    func makeCoordinator() -> TrackCoordinator { TrackCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = context.coordinator.tableView
        let col = NSTableColumn(identifier: .init("col"))
        col.isEditable = false
        tv.addTableColumn(col)
        tv.headerView = nil
        tv.backgroundColor = .clear
        tv.selectionHighlightStyle = .none
        tv.usesAlternatingRowBackgroundColors = false
        tv.intercellSpacing = .zero
        tv.style = .plain
        tv.dataSource = context.coordinator
        tv.delegate   = context.coordinator

        let sv = NSScrollView()
        sv.documentView = tv
        sv.drawsBackground = false
        sv.hasVerticalScroller   = false
        sv.hasHorizontalScroller = false
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        let needsFullReload = c.tracks.count != tracks.count

        let needsVisibleReload = !needsFullReload && (
            c.currentTrackTitle  != currentTrackTitle  ||
            c.currentTrackArtist != currentTrackArtist ||
            c.isPlaying          != isPlaying          ||
            c.showTrackNumber    != showTrackNumber    ||
            c.themeColor         != themeColor
        )

        c.tracks              = tracks
        c.currentTrackTitle   = currentTrackTitle
        c.currentTrackArtist  = currentTrackArtist
        c.isPlaying           = isPlaying
        c.showTrackNumber     = showTrackNumber
        c.themeColor          = themeColor
        c.onTap               = onTap

        let tv = c.tableView
        if needsFullReload {
            tv.reloadData()
        } else if needsVisibleReload {
            let range = tv.rows(in: tv.visibleRect)
            let visible = IndexSet(integersIn: range.lowerBound..<(range.upperBound + 1))
            if !visible.isEmpty {
                tv.reloadData(forRowIndexes: visible, columnIndexes: IndexSet(integer: 0))
            }
        }
    }
}

// MARK: - TrackCoordinator

final class TrackCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    let tableView = NSTableView()
    var tracks: [PlaylistTrackItem] = []
    var currentTrackTitle:  String = ""
    var currentTrackArtist: String = ""
    var isPlaying:       Bool = false
    var showTrackNumber: Bool = true
    var themeColor: Color = .pink
    var onTap: (Int) -> Void = { _ in }

    func numberOfRows(in tableView: NSTableView) -> Int { tracks.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 40 }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id  = NSUserInterfaceItemIdentifier("track")
        let track = tracks[row]
        let isCurrent = currentTrackTitle == track.title && currentTrackArtist == track.artist

        let cell = tableView.makeView(withIdentifier: id, owner: nil)
            as? NSHostingView<TrackRowView>
            ?? {
                let h = NSHostingView(rootView: TrackRowView(
                    track: track, index: row, isCurrent: false, isPlaying: false,
                    showTrackNumber: showTrackNumber, themeColor: themeColor, onTap: {}))
                h.identifier = id
                h.autoresizingMask = [.width, .height]
                return h
            }()

        let capturedRow = row
        cell.rootView = TrackRowView(
            track: track, index: row,
            isCurrent: isCurrent, isPlaying: isPlaying,
            showTrackNumber: showTrackNumber, themeColor: themeColor,
            onTap: { [weak self] in self?.onTap(capturedRow) }
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = NSTableRowView()
        v.isEmphasized = false
        return v
    }
}
