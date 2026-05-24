import Foundation
import AppKit
import iTunesLibrary

// MARK: - Codable 镜像结构
// artwork 全部剔除，playlists.cache 只存纯文本元数据

private struct CodablePlaylistInfo: Codable {
    let id: String
    let libraryID: Int64
    let name: String
    let trackCount: Int
    let kindRaw: String
    let isFolder: Bool
    let representativeTrackKey: String?
}

private struct CodablePlaylistGroup: Codable {
    let id: String
    let folderName: String
    let isFolder: Bool
    let indentLevel: Int
    let ancestorFolderNames: [String]
    let playlists: [CodablePlaylistInfo]
    let representativeTrackKey: String?
}

private struct CacheEnvelope: Codable {
    let version: Int
    let builtAt: Date
    let groups: [CodablePlaylistGroup]
}

private struct CodableTrackItem: Codable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let discNumber: Int
    let trackNumber: Int
    let urlString: String?
}

// 每个播放列表独立一个小文件
private struct SingleTrackCache: Codable {
    let version: Int
    let name: String   // 播放列表名，预热时用于还原 memory cache key
    let tracks: [CodableTrackItem]
}

// MARK: - PlaylistDiskCache

final class PlaylistDiskCache {

    static let shared = PlaylistDiskCache()
    private init() {}

    private let cacheVersion = 5  // v5: SingleTrackCache 加入 name 字段

    // L1：活跃播放列表（常驻内存，单列表）
    private var activePlaylistTracks: (name: String, tracks: [PlaylistTrackItem])? = nil

    // L2：已访问列表的内存缓存（懒加载，按需填充）
    private var trackMemoryCache: [String: [PlaylistTrackItem]] = [:]
    private let memoryCacheLock = NSLock()

    // MARK: - 路径

    private var cacheDir: URL? {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = appSupport.appendingPathComponent("BarMusic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var cacheURL: URL? {
        cacheDir?.appendingPathComponent("playlists.cache")
    }

    // 每个播放列表的曲目存在独立子目录下
    private var tracksCacheDir: URL? {
        guard let dir = cacheDir else { return nil }
        let tracksDir = dir.appendingPathComponent("tracks", isDirectory: true)
        try? FileManager.default.createDirectory(at: tracksDir, withIntermediateDirectories: true)
        return tracksDir
    }

    // 用 djb2 hash 作为文件名，避免文件系统不安全字符和路径长度问题
    private func trackFileURL(for playlistName: String) -> URL? {
        guard let dir = tracksCacheDir else { return nil }
        let hash = playlistName.utf8.reduce(5381 as UInt64) { ($0 &<< 5) &+ $0 &+ UInt64($1) }
        return dir.appendingPathComponent("\(hash).cache")
    }

    // MARK: - 播放列表元数据读取

    func load() -> [PlaylistGroup]? {
        guard let url = cacheURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(CacheEnvelope.self, from: data),
              envelope.version == cacheVersion
        else {
            if let url = cacheURL, FileManager.default.fileExists(atPath: url.path) {
                print("[PlaylistDiskCache] 版本不匹配，清空旧缓存")
                deleteAllCacheFiles()
            }
            return nil
        }

        let groups = envelope.groups.map { decode(group: $0) }
        print("[PlaylistDiskCache] ✅ 从磁盘加载 \(groups.count) 个分组（构建于 \(envelope.builtAt)）")
        return groups
    }

    // MARK: - 播放列表元数据写入

    func save(_ groups: [PlaylistGroup]) {
        let codable = CacheEnvelope(
            version: cacheVersion,
            builtAt: Date(),
            groups: groups.map { encode(group: $0) }
        )
        guard let url = cacheURL else { return }
        do {
            let data = try JSONEncoder().encode(codable)
            try data.write(to: url, options: .atomic)
            print("[PlaylistDiskCache] ✅ 写入完成（\(groups.count) 个分组，\(data.count / 1024) KB）")
        } catch {
            print("[PlaylistDiskCache] ❌ 写入失败: \(error)")
        }
    }

    // MARK: - 活跃列表（L1 内存常驻）

    func setActivePlaylist(name: String, tracks: [PlaylistTrackItem]) {
        if let old = activePlaylistTracks, old.name != name {
            // 旧活跃列表写入 L2 内存缓存，并异步落盘
            memoryCacheLock.lock()
            trackMemoryCache[old.name] = old.tracks
            memoryCacheLock.unlock()
            let oldTracks = old.tracks
            let oldName = old.name
            Task.detached(priority: .utility) { [weak self] in
                self?.saveTracksToDisk(oldTracks, for: oldName)
            }
        }
        activePlaylistTracks = (name, tracks)
        print("[PlaylistDiskCache] ✅ 活跃列表 → \"\(name)\"（\(tracks.count) 首）")
    }

    func getActivePlaylistTracks() -> (name: String, tracks: [PlaylistTrackItem])? {
        activePlaylistTracks
    }

    func saveActivePlaylists() {
        guard let active = activePlaylistTracks else { return }
        let tracks = active.tracks
        let name = active.name
        Task.detached(priority: .utility) { [weak self] in
            self?.saveTracksToDisk(tracks, for: name)
        }
    }

    // MARK: - 曲目缓存读取（三级缓存）

    func loadTracks(for playlistName: String) -> [PlaylistTrackItem]? {
        // L1: 活跃列表
        if let active = activePlaylistTracks, active.name == playlistName {
            return active.tracks
        }
        // L2: 内存缓存
        memoryCacheLock.lock()
        let cached = trackMemoryCache[playlistName]
        memoryCacheLock.unlock()
        if let cached { return cached }

        // L3: 单列表小文件（冷启动时只读一个小文件，不加载全部）
        if let tracks = loadTracksFromDisk(for: playlistName) {
            memoryCacheLock.lock()
            trackMemoryCache[playlistName] = tracks
            memoryCacheLock.unlock()
            return tracks
        }
        return nil
    }

    private func loadTracksFromDisk(for name: String) -> [PlaylistTrackItem]? {
        guard let url = trackFileURL(for: name),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(SingleTrackCache.self, from: data),
              cache.version == cacheVersion
        else { return nil }
        return cache.tracks.map { decode(track: $0) }
    }

    // MARK: - 曲目缓存写入（单列表）

    private func saveTracksToDisk(_ tracks: [PlaylistTrackItem], for name: String) {
        guard let url = trackFileURL(for: name) else { return }
        let cache = SingleTrackCache(version: cacheVersion, name: name, tracks: tracks.map { encode(track: $0) })
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
        print("[PlaylistDiskCache] 💾 \"\(name)\" 已落盘（\(data.count / 1024) KB）")
    }

    // MARK: - 预构建所有播放列表曲目缓存

    func prebuildAllTracksCaches(from playlists: [ITLibPlaylist],
                                 progress: ((Int, Int) -> Void)? = nil) {
        let visiblePlaylists = playlists.filter { !$0.isMaster && $0.distinguishedKind == .kindNone }
        let total = visiblePlaylists.count

        for (index, playlist) in visiblePlaylists.enumerated() {
            let tracks: [PlaylistTrackItem] = playlist.items.map { track in
                PlaylistTrackItem(
                    title: track.title,
                    artist: track.artist?.name ?? L.unknownArtist,
                    album: track.album.title ?? L.unknownAlbum,
                    discNumber: track.album.discNumber,
                    trackNumber: track.trackNumber,
                    url: track.location
                )
            }

            // 写独立文件
            saveTracksToDisk(tracks, for: playlist.name)

            // 同时写入 L2 内存缓存，构建完毕后点击立即可用
            memoryCacheLock.lock()
            trackMemoryCache[playlist.name] = tracks
            memoryCacheLock.unlock()

            let done = index + 1
            if done % 50 == 0 || done == total {
                print("[PlaylistDiskCache] 曲目缓存构建进度: \(done)/\(total)")
                progress?(done, total)
            }
        }

        print("[PlaylistDiskCache] ✅ 预构建完成：\(visiblePlaylists.count) 个播放列表")
    }

    // MARK: - 预热：启动时把所有小文件读入内存，消除首次点击的磁盘延迟

    func prewarmTrackCaches() {
        guard let dir = tracksCacheDir else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }

        var count = 0
        for file in files where file.pathExtension == "cache" {
            guard let data = try? Data(contentsOf: file),
                  let cache = try? JSONDecoder().decode(SingleTrackCache.self, from: data),
                  cache.version == cacheVersion
            else { continue }

            let tracks = cache.tracks.map { decode(track: $0) }
            memoryCacheLock.lock()
            if trackMemoryCache[cache.name] == nil {
                trackMemoryCache[cache.name] = tracks
                count += 1
            }
            memoryCacheLock.unlock()
        }
        print("[PlaylistDiskCache] 🔥 预热完成：\(count) 个播放列表已加载到内存")
    }

    // MARK: - 清空

    func deleteAllCacheFiles() {
        if let url = cacheURL { try? FileManager.default.removeItem(at: url) }
        // 删除新格式目录
        if let dir = cacheDir {
            let tracksDir = dir.appendingPathComponent("tracks")
            try? FileManager.default.removeItem(at: tracksDir)
            // 同时清理旧版 tracks.cache 单文件（版本迁移）
            let oldFile = dir.appendingPathComponent("tracks.cache")
            try? FileManager.default.removeItem(at: oldFile)
        }
        activePlaylistTracks = nil
        memoryCacheLock.lock()
        trackMemoryCache.removeAll()
        memoryCacheLock.unlock()
        print("[PlaylistDiskCache] 🗑️ 全部缓存已清空")
    }

    func deleteCacheFile() { deleteAllCacheFiles() }

    // MARK: - 编解码

    private func encode(group: PlaylistGroup) -> CodablePlaylistGroup {
        let repKey = group.playlists.first?.representativeTrackKey
        return CodablePlaylistGroup(
            id: group.id.uuidString,
            folderName: group.folderName,
            isFolder: group.isFolder,
            indentLevel: group.indentLevel,
            ancestorFolderNames: group.ancestorFolderNames,
            playlists: group.playlists.map { encode(info: $0) },
            representativeTrackKey: repKey
        )
    }

    private func encode(info: PlaylistInfo) -> CodablePlaylistInfo {
        CodablePlaylistInfo(
            id: info.id.uuidString,
            libraryID: info.libraryID.int64Value,
            name: info.name,
            trackCount: info.trackCount,
            kindRaw: kindString(info.kind),
            isFolder: info.isFolder,
            representativeTrackKey: info.representativeTrackKey
        )
    }

    private func decode(group g: CodablePlaylistGroup) -> PlaylistGroup {
        PlaylistGroup(
            folderName: g.folderName,
            folderArtwork: nil,
            isFolder: g.isFolder,
            indentLevel: g.indentLevel,
            ancestorFolderNames: g.ancestorFolderNames,
            playlists: g.playlists.map { decode(info: $0) },
            representativeTrackKey: g.representativeTrackKey
        )
    }

    private func decode(info i: CodablePlaylistInfo) -> PlaylistInfo {
        PlaylistInfo(
            id: UUID(uuidString: i.id) ?? UUID(),
            libraryID: NSNumber(value: i.libraryID),
            name: i.name,
            trackCount: i.trackCount,
            kind: kindFromString(i.kindRaw),
            artworkImage: nil,
            isFolder: i.isFolder,
            representativeTrackKey: i.representativeTrackKey
        )
    }

    private func encode(track: PlaylistTrackItem) -> CodableTrackItem {
        CodableTrackItem(
            id: track.id.uuidString,
            title: track.title,
            artist: track.artist,
            album: track.album,
            discNumber: track.discNumber,
            trackNumber: track.trackNumber,
            urlString: track.url?.absoluteString
        )
    }

    private func decode(track t: CodableTrackItem) -> PlaylistTrackItem {
        PlaylistTrackItem(
            title: t.title,
            artist: t.artist,
            album: t.album,
            discNumber: t.discNumber,
            trackNumber: t.trackNumber,
            url: t.urlString.flatMap { URL(string: $0) }
        )
    }

    private func kindString(_ kind: PlaylistInfo.PlaylistKind) -> String {
        switch kind {
        case .user:    return "user"
        case .smart:   return "smart"
        case .library: return "library"
        case .folder:  return "folder"
        }
    }

    private func kindFromString(_ s: String) -> PlaylistInfo.PlaylistKind {
        switch s {
        case "smart":   return .smart
        case "library": return .library
        case "folder":  return .folder
        default:        return .user
        }
    }
}
