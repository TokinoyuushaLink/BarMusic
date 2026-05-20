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
    var artworkImage: NSImage?
    var isFolder: Bool

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

// 支持多层文件夹嵌套
struct PlaylistGroup: Identifiable {
    let id: UUID = UUID()
    var folderName: String          // "" = 顶层无文件夹
    var folderArtwork: NSImage?
    var isFolder: Bool
    var indentLevel: Int            // 0 = 顶层, 1 = 一级文件夹, 2 = 二级文件夹
    var ancestorFolderNames: [String]  // 从根到直接父级的文件夹名列表
    var playlists: [PlaylistInfo]
}

// MARK: - 读取器

final class LibraryReader {

    static func fetchGroupedPlaylists() -> [PlaylistGroup] {
        guard let library = LibraryCache.shared.get() else {
            print("[iTunesLibrary] 无法初始化音乐库")
            return []
        }

        let all = library.allPlaylists

        // persistentID → playlist，方便查父级
        var byID: [NSNumber: ITLibPlaylist] = [:]
        for pl in all { byID[pl.persistentID] = pl }

        // kind==3 是文件夹，kind==0/1/2/5 是普通/智能列表
        let isFolder: (ITLibPlaylist) -> Bool = { $0.kind.rawValue == 3 }

        // 过滤出用户可见的非文件夹列表
        let visiblePlaylists = all.filter { pl in
            if pl.isMaster { return false }
            if isFolder(pl) { return false }
            let dk = pl.distinguishedKind
            if dk != .kindNone { return false }   // 只保留普通用户列表，排除音乐资料库等系统列表
            return true
        }

        // 计算一个 playlist 相对于根的缩进深度
        func indentDepth(_ pl: ITLibPlaylist) -> Int {
            var depth = 0
            var current = pl
            while let pid = current.parentID, let parent = byID[pid] {
                depth += 1
                current = parent
            }
            return depth
        }

        // 找到某个 playlist 最顶层的文件夹祖先
        func topAncestorFolder(_ pl: ITLibPlaylist) -> ITLibPlaylist? {
            var result: ITLibPlaylist? = nil
            var current = pl
            while let pid = current.parentID, let parent = byID[pid] {
                if isFolder(parent) { result = parent }
                current = parent
            }
            return result
        }

        // 找直接父文件夹
        func directParentFolder(_ pl: ITLibPlaylist) -> ITLibPlaylist? {
            guard let pid = pl.parentID, let parent = byID[pid], isFolder(parent) else { return nil }
            return parent
        }

        // 收集所有文件夹，按层级排序（深度优先，保持 Music.app 原始顺序）
        // 策略：按 DFS 顺序遍历文件夹树，每个文件夹后面跟着它直属的子列表
        var groups: [PlaylistGroup] = []

        // ancestors: names of all folders from root down to (not including) current folder
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

            let folderArtwork = children.compactMap { $0.artworkImage }.first
            groups.append(PlaylistGroup(
                folderName: folderName,
                folderArtwork: folderArtwork,
                isFolder: true,
                indentLevel: depth,
                ancestorFolderNames: ancestors,
                playlists: children
            ))

            // Sub-folders get current folder appended to their ancestors
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
                playlists: topLevel
            ))
        }

        return groups
    }

    private static func makeInfo(_ playlist: ITLibPlaylist) -> PlaylistInfo {
        let kind: PlaylistInfo.PlaylistKind
        switch playlist.kind.rawValue {
        case 2, 5: kind = .smart
        case 1:    kind = playlist.distinguishedKind == .kindNone ? .user : .library
        default:   kind = .user
        }
        let artwork = artworkFromTracks(playlist.items)
        return PlaylistInfo(
            id: UUID(),
            libraryID: playlist.persistentID,
            name: playlist.name,
            trackCount: playlist.items.count,
            kind: kind,
            artworkImage: artwork,
            isFolder: false
        )
    }

    // MARK: - 封面

    static func artworkFromTracks(_ tracks: [ITLibMediaItem]) -> NSImage? {
        for track in tracks.prefix(5) {
            guard let url = track.location else { continue }
            if let img = artworkFromFile(url: url) { return img }
        }
        return nil
    }

    static func artworkFromFile(url: URL) -> NSImage? {
        // Use AVURLAsset with synchronous metadata loading to avoid deprecated API
        let asset = AVURLAsset(url: url)
        var result: NSImage? = nil
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            if let items = try? await asset.load(.commonMetadata) {
                for item in items where item.commonKey == .commonKeyArtwork {
                    if let data = try? await item.load(.value) as? Data,
                       let img = NSImage(data: data) {
                        result = img
                        break
                    }
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }
}
