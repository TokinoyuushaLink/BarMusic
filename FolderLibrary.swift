import Foundation
import AVFoundation

// MARK: - 文件夹模式
//
// 缓存放在用户所选文件夹里：
//   <根目录>/.bmcache/index.json     目录树 + 曲目元数据（路径都相对根目录，文件夹挪走也有效）
//   <根目录>/.bmcache/artwork/       封面缩略图（沿用 TrackArtworkCache 的格式）
// 手动刷新时整体重建。

struct FolderTrackData: Codable {
    var file: String            // 文件名（位于所属目录下）
    var title: String
    var artist: String
    var album: String
    var disc: Int
    var track: Int
}

struct FolderNodeData: Codable {
    var name: String
    var rep: String?            // 第一首有封面的曲目 key，给行/文件夹头显示封面用
    var tracks: [FolderTrackData]
    var children: [FolderNodeData]
}

private struct FolderCacheFile: Codable {
    var version: Int
    var root: FolderNodeData
}

/// 运行时的目录节点。key 是相对根目录的路径（根为 "."），同时用作列表标识。
final class FolderNode {
    let key: String
    let name: String
    let url: URL
    let repKey: String?
    let tracks: [PlaylistTrackItem]
    let children: [FolderNode]
    let id = UUID()
    let totalTracks: Int

    init(data: FolderNodeData, url: URL, key: String) {
        self.key = key
        self.name = data.name
        self.url = url
        self.repKey = data.rep
        self.tracks = data.tracks.map {
            PlaylistTrackItem(title: $0.title, artist: $0.artist, album: $0.album,
                              discNumber: $0.disc, trackNumber: $0.track,
                              url: url.appendingPathComponent($0.file))
        }
        self.children = data.children.map {
            FolderNode(data: $0,
                       url: url.appendingPathComponent($0.name, isDirectory: true),
                       key: key == "." ? $0.name : key + "/" + $0.name)
        }
        self.totalTracks = tracks.count + children.reduce(0) { $0 + $1.totalTracks }
    }

    var isLeaf: Bool { children.isEmpty }

    func index(into dict: inout [String: FolderNode]) {
        dict[key] = self
        for child in children { child.index(into: &dict) }
    }
}

// MARK: - 扫描与缓存

enum FolderLibrary {

    /// AVAudioFile 能直接解码的格式。
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "aif", "aiff", "aifc", "caf", "flac", "alac"
    ]

    private static let cacheVersion = 1
    private static let maxDepth = 32      // 符号链接环按真实路径检测，这只是兜底

    private static func cacheURL(_ root: URL) -> URL {
        root.appendingPathComponent(".bmcache/index.json")
    }

    static func loadCache(root: URL) -> FolderNodeData? {
        guard let data = try? Data(contentsOf: cacheURL(root)),
              let file = try? JSONDecoder().decode(FolderCacheFile.self, from: data),
              file.version == cacheVersion
        else { return nil }
        return file.root
    }

    static func saveCache(_ tree: FolderNodeData, root: URL) {
        let url = cacheURL(root)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(FolderCacheFile(version: cacheVersion, root: tree))
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: 目录遍历

    private final class Dir {
        let url: URL
        var files: [URL] = []
        var subdirs: [Dir] = []
        init(_ url: URL) { self.url = url }
    }

    private static func naturalOrder(_ a: URL, _ b: URL) -> Bool {
        a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
    }

    /// 用基于路径的 API：contentsOfDirectory(at:) 在 URL 本身是符号链接时会失败。
    /// 返回的 URL 保留“经过符号链接的路径”，所以同一目标出现在两处时标识仍然不同。
    private static func listEntries(_ dir: URL) -> [URL]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        return names.filter { !$0.hasPrefix(".") }       // 隐藏文件、.bmcache、macOS 的 ._ 文件
            .map { dir.appendingPathComponent($0) }
            .sorted(by: naturalOrder)
    }

    private static func walk(_ url: URL, ancestors: Set<String>, depth: Int) -> Dir? {
        guard depth <= maxDepth else { return nil }
        let real = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard !ancestors.contains(real), let entries = listEntries(url) else { return nil }

        let dir = Dir(url)
        let chain = ancestors.union([real])
        for entry in entries {
            var isDir: ObjCBool = false
            // fileExists 会跟随符号链接；失效的链接返回 false，直接跳过。
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let sub = walk(entry, ancestors: chain, depth: depth + 1),
                   !sub.files.isEmpty || !sub.subdirs.isEmpty {     // 只保留含音频的目录
                    dir.subdirs.append(sub)
                }
            } else if audioExtensions.contains(entry.pathExtension.lowercased()) {
                dir.files.append(entry)
            }
        }
        return dir
    }

    // MARK: 扫描

    /// 遍历 → 读元数据 → 建封面缓存。根目录不可读时返回 nil。
    static func scan(root: URL, artworkCache: TrackArtworkCache,
                     progress: @escaping (Double) -> Void) -> FolderNodeData? {
        guard let tree = walk(root, ancestors: [], depth: 0) else { return nil }

        var files: [URL] = []
        func collect(_ d: Dir) { files += d.files; d.subdirs.forEach(collect) }   // 与 convert 同序
        collect(tree)

        // 并发读元数据（0–50%）
        let count = files.count
        var results = [FolderTrackData?](repeating: nil, count: count)
        let lock = NSLock()
        var finished = 0
        let workers = max(1, min(6, ProcessInfo.processInfo.activeProcessorCount))
        results.withUnsafeMutableBufferPointer { buffer in
            let out = buffer
            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                var i = worker
                while i < count {
                    out[i] = readTrack(files[i])
                    lock.lock(); finished += 1; let done = finished; lock.unlock()
                    if done % 25 == 0 { progress(Double(done) / Double(count) * 0.5) }
                    i += workers
                }
            }
        }
        let tracks = results.map { $0! }

        // 封面（50–100%）：同一个 key 只处理一次
        var entries: [(key: String, url: URL)] = []
        var seen = Set<String>()
        for (i, t) in tracks.enumerated() {
            let key = artworkCache.trackKey(title: t.title, artist: t.artist, album: t.album)
            if seen.insert(key).inserted { entries.append((key, files[i])) }
        }
        artworkCache.buildCache(entries: entries) { done, total in
            progress(0.5 + Double(done) / Double(max(1, total)) * 0.5)
        }

        var cursor = 0
        func convert(_ d: Dir, name: String) -> FolderNodeData {
            let own = Array(tracks[cursor ..< cursor + d.files.count])
            cursor += d.files.count
            let children = d.subdirs.map { convert($0, name: $0.url.lastPathComponent) }
            let ownRep = own.map { artworkCache.trackKey(title: $0.title, artist: $0.artist, album: $0.album) }
                .first { artworkCache.cgImage(forKey: $0) != nil }
            return FolderNodeData(name: name, rep: ownRep ?? children.compactMap { $0.rep }.first,
                                  tracks: own, children: children)
        }
        return convert(tree, name: root.lastPathComponent)
    }

    // MARK: 元数据

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func leadingInt(_ s: String) -> Int? {       // "3/12" → 3
        Int(s.trimmingCharacters(in: .whitespaces).prefix(while: { $0.isNumber }))
    }

    /// iTunes 的 trkn / disk 是二进制：2 字节填充 + 2 字节序号 + 2 字节总数。
    private static func itunesCounter(_ item: AVMetadataItem) -> Int? {
        if let d = item.dataValue, d.count >= 4 {
            let v = Int(d[d.startIndex + 2]) << 8 | Int(d[d.startIndex + 3])
            return v > 0 ? v : nil
        }
        return item.numberValue?.intValue ?? item.stringValue.flatMap(leadingInt)
    }

    private static func textCounter(_ item: AVMetadataItem) -> Int? {
        item.stringValue.flatMap(leadingInt) ?? item.numberValue?.intValue
    }

    /// 缺失的字段都有兜底：标题用文件名；专辑用所在目录名，
    /// 这样不同目录里的无标签文件不会共用一个封面 key。
    private static func readTrack(_ url: URL) -> FolderTrackData {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

        var title: String?, artist: String?, album: String?
        for item in asset.commonMetadata {
            switch item.commonKey {
            case .commonKeyTitle?:     title  = title  ?? clean(item.stringValue)
            case .commonKeyArtist?:    artist = artist ?? clean(item.stringValue)
            case .commonKeyAlbumName?: album  = album  ?? clean(item.stringValue)
            default: break
            }
        }

        var disc = 0, track = 0
        for format in asset.availableMetadataFormats {
            for item in asset.metadata(forFormat: format) {
                let id = item.identifier
                let key = (item.key as? String)?.uppercased() ?? ""
                if id == .iTunesMetadataTrackNumber {
                    track = track > 0 ? track : (itunesCounter(item) ?? 0)
                } else if id == .iTunesMetadataDiscNumber {
                    disc = disc > 0 ? disc : (itunesCounter(item) ?? 0)
                } else if id == .id3MetadataTrackNumber || ["TRCK", "TRACKNUMBER"].contains(key) {
                    track = track > 0 ? track : (textCounter(item) ?? 0)
                } else if id == .id3MetadataPartOfASet || ["TPOS", "DISCNUMBER"].contains(key) {
                    disc = disc > 0 ? disc : (textCounter(item) ?? 0)
                }
            }
        }

        return FolderTrackData(
            file: url.lastPathComponent,
            title: title ?? url.deletingPathExtension().lastPathComponent,
            artist: artist ?? L.unknownArtist,
            album: album ?? url.deletingLastPathComponent().lastPathComponent,
            disc: disc, track: track)
    }
}
