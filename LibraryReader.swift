import Foundation
import AppKit
import AVFoundation
import iTunesLibrary

// MARK: - 数据模型

struct TrackInfo: Equatable {
    var name: String     = L.notPlaying
    var artist: String   = "—"
    var album: String    = "—"
    var duration: Double = 0
}

struct PlaylistInfo: Identifiable, Equatable {
    let id: UUID
    let libraryID: NSNumber
    var name: String
    var trackCount: Int
    var kind: PlaylistKind
    var artworkImage: NSImage?          // 运行时由 TrackArtworkCache 填充，不持久化
    var isFolder: Bool
    var representativeTrackKey: String? // 第一首有封面的曲目 key，持久化到 playlists.cache

    static func == (lhs: PlaylistInfo, rhs: PlaylistInfo) -> Bool { lhs.id == rhs.id }

    enum PlaylistKind {
        case user, smart, library, folder
        var icon: String {
            switch self {
            case .user:    return "music.note.list"
            case .smart:   return "gearshape.fill"
            case .library: return "music.quarternote.3"
            case .folder:  return "folder.fill"
            }
        }
    }
}

struct PlaylistGroup: Identifiable {
    let id: UUID = UUID()
    var folderName: String
    var folderArtwork: NSImage?         // 运行时由 TrackArtworkCache 填充，不持久化
    var isFolder: Bool
    var indentLevel: Int
    var ancestorFolderNames: [String]
    var playlists: [PlaylistInfo]
    var representativeTrackKey: String? // 文件夹的代表曲目 key
}

// MARK: - LibraryReader

final class LibraryReader {

    static func fetchGroupedPlaylists() -> [PlaylistGroup] {
        guard let library = LibraryCache.shared.get() else {
            print("[iTunesLibrary] 无法初始化音乐库")
            return []
        }

        let all = library.allPlaylists
        var byID: [NSNumber: ITLibPlaylist] = [:]
        for pl in all { byID[pl.persistentID] = pl }

        let isFolder: (ITLibPlaylist) -> Bool = { $0.kind.rawValue == 3 }

        let visiblePlaylists = all.filter { pl in
            if pl.isMaster { return false }
            if isFolder(pl) { return false }
            if pl.distinguishedKind != .kindNone { return false }
            return true
        }

        func indentDepth(_ pl: ITLibPlaylist) -> Int {
            var depth = 0
            var current = pl
            while let pid = current.parentID, let parent = byID[pid] {
                depth += 1
                current = parent
            }
            return depth
        }

        var groups: [PlaylistGroup] = []

        func appendFolder(_ folder: ITLibPlaylist, depth: Int, ancestors: [String]) {
            let folderName = folder.name

            let children: [PlaylistInfo] = visiblePlaylists
                .filter { $0.parentID == folder.persistentID }
                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
                .map { makeInfo($0) }

            let subFolders = all
                .filter { isFolder($0) && $0.parentID == folder.persistentID }
                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

            guard !children.isEmpty || !subFolders.isEmpty else { return }

            // 文件夹的代表 key = 第一个有 representativeTrackKey 的子列表的 key
            let folderRepKey = children.compactMap { $0.representativeTrackKey }.first

            groups.append(PlaylistGroup(
                folderName: folderName,
                folderArtwork: nil,         // 不在构建阶段读封面，由 TrackArtworkCache 提供
                isFolder: true,
                indentLevel: depth,
                ancestorFolderNames: ancestors,
                playlists: children,
                representativeTrackKey: folderRepKey
            ))

            for sub in subFolders {
                appendFolder(sub, depth: depth + 1, ancestors: ancestors + [folderName])
            }
        }

        let topFolders = all
            .filter { isFolder($0) && ($0.parentID == nil || byID[$0.parentID!].map { !isFolder($0) } ?? true) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

        for folder in topFolders {
            appendFolder(folder, depth: 1, ancestors: [])
        }

        let topLevel: [PlaylistInfo] = visiblePlaylists
            .filter { $0.parentID == nil }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            .map { makeInfo($0) }

        if !topLevel.isEmpty {
            groups.append(PlaylistGroup(
                folderName: "",
                folderArtwork: nil,
                isFolder: false,
                indentLevel: 0,
                ancestorFolderNames: [],
                playlists: topLevel,
                representativeTrackKey: topLevel.compactMap { $0.representativeTrackKey }.first
            ))
        }

        return groups
    }

    // MARK: - makeInfo（不读封面，只记录代表曲目 key）

    private static func makeInfo(_ playlist: ITLibPlaylist) -> PlaylistInfo {
        let kind: PlaylistInfo.PlaylistKind
        switch playlist.kind.rawValue {
        case 2, 5: kind = .smart
        case 1:    kind = playlist.distinguishedKind == .kindNone ? .user : .library
        default:   kind = .user
        }

        // 找第一首有文件路径的曲目作为代表（构建时不读 artwork，由 TrackArtworkCache 负责）
        let repKey: String? = playlist.items.prefix(10).compactMap { item -> String? in
            guard item.location != nil else { return nil }
            return TrackArtworkCache.shared.trackKey(item)
        }.first

        return PlaylistInfo(
            id: UUID(),
            libraryID: playlist.persistentID,
            name: playlist.name,
            trackCount: playlist.items.count,
            kind: kind,
            artworkImage: nil,
            isFolder: false,
            representativeTrackKey: repKey
        )
    }

    // MARK: - 封面工具（供 TrackArtworkCache 构建阶段使用）

    static func artworkDataFromFile(url: URL) -> Data? {
        let asset = AVURLAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        Task {
            if let metadata = try? await asset.load(.commonMetadata) {
                for item in metadata {
                    if item.commonKey == .commonKeyArtwork,
                       let data = try? await item.load(.dataValue) {
                        result = data
                        break
                    }
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    static func artworkFromFile(url: URL) -> NSImage? {
        guard let data = artworkDataFromFile(url: url) else { return nil }
        return NSImage(data: data)
    }
}
