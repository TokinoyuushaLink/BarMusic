import AppKit
import AVFoundation
import CryptoKit
import iTunesLibrary

// MARK: - 磁盘布局
//
//  ~/Library/Application Support/BarMusic/artwork/
//    artworkIndex.json          — { "trackKey": "a1b2c3d4" }   曲目 → 哈希前8位
//    a1b2c3d4.raw               — 40×40 BGRA raw，固定 6400 字节
//    e5f6a7b8.raw
//    ...
//
//  trackKey = "\(title)|\(artist)|\(album)"（轻量指纹，不用 persistentID 保持跨版本稳定）

// MARK: - TrackArtworkCache

final class TrackArtworkCache {

    static let shared = TrackArtworkCache()

    // 像素尺寸：56×56 在 @2x 屏上渲染为 28pt，1:1 映射无缩放损耗
    static let thumbSize = 56
    // 每张图固定字节数：56 × 56 × 4(BGRA) = 12544
    static let rawByteCount = thumbSize * thumbSize * 4

    // ── L1 内存池 ──────────────────────────────────────────
    // key = hash8（8位16进制），value = 已渲染的 NSImage（供非热路径使用）
    private var pool: [String: NSImage] = [:]
    // 热路径专用：直接存 CGImage，跳过 NSImage→CGImage 转换开销
    private var cgPool: [String: CGImage] = [:]
    // key = trackKey，value = hash8（用于从曲目快速查图）
    private var trackIndex: [String: String] = [:]
    private let lock = NSLock()

    // ── 磁盘路径 ───────────────────────────────────────────
    private let artworkDir: URL?
    private let indexURL: URL?

    private init() {
        if let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = appSupport
                .appendingPathComponent("BarMusic", isDirectory: true)
                .appendingPathComponent("artwork", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            artworkDir = dir
            indexURL = dir.appendingPathComponent("artworkIndex.json")
        } else {
            artworkDir = nil
            indexURL = nil
        }
    }

    private func rawURL(hash8: String) -> URL? {
        artworkDir?.appendingPathComponent("\(hash8).raw")
    }

    // MARK: - 启动：从磁盘 mmap 全量加载

    /// app 启动时调用一次，后续读取全走内存池。
    /// 在后台线程调用，完成后回调主线程。
    func loadFromDisk(completion: @escaping () -> Void) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            self.doLoadFromDisk()
            await MainActor.run { completion() }
        }
    }

    private func doLoadFromDisk() {
        guard let indexURL,
              let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            print("[TrackArtworkCache] 无磁盘索引，等待首次构建")
            return
        }

        var loaded = 0
        var newPool: [String: NSImage] = [:]
        var newCGPool: [String: CGImage] = [:]
        var newIndex: [String: String] = [:]

        for (trackKey, hash8) in index {
            newIndex[trackKey] = hash8
            // 已加载过相同 hash8 的图就复用，不重复 mmap
            if newPool[hash8] != nil { continue }
            guard let url = rawURL(hash8: hash8),
                  let (img, cgImg) = imageFromRawFile(url: url)
            else { continue }
            newPool[hash8] = img
            newCGPool[hash8] = cgImg
            loaded += 1
        }

        lock.lock()
        pool = newPool
        cgPool = newCGPool
        trackIndex = newIndex
        lock.unlock()

        print("[TrackArtworkCache] ✅ 启动加载：\(loaded) 张唯一封面，\(index.count) 条曲目映射")
    }

    // MARK: - 构建：遍历播放列表曲目，哈希去重写 .raw

    /// 在后台线程调用。增量构建：已有哈希的文件不重复写。
    func buildCache(for playlists: [ITLibPlaylist],
                    progress: ((Int, Int) -> Void)? = nil) {
        guard let dir = artworkDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 读现有索引（增量用）
        var existingIndex: [String: String] = [:]
        if let url = indexURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            existingIndex = decoded
        }

        // 收集所有需要处理的唯一曲目（用 trackKey 去重）
        var allItems: [ITLibMediaItem] = []
        var seen = Set<String>()
        for pl in playlists {
            for item in pl.items {
                let key = trackKey(item)
                if seen.insert(key).inserted { allItems.append(item) }
            }
        }

        let total = allItems.count
        var done = 0
        var newIndex = existingIndex

        // 已存在哈希的 .raw 文件集合，避免重复写盘
        var existingHashes = Set(existingIndex.values)

        for item in allItems {
            defer {
                done += 1
                if done % 50 == 0 { progress?(done, total) }
            }

            let key = trackKey(item)

            // 如果已有映射且对应 .raw 文件存在，跳过
            if let h = existingIndex[key],
               FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(h).raw").path) {
                continue
            }

            // 提取封面原始 Data
            guard let url = item.location,
                  let artData = artworkData(from: url)
            else { continue }

            // 计算哈希（对原始 Data，不对缩略图）
            let hash8 = sha256prefix8(artData)

            // 相同封面只写一次磁盘
            if !existingHashes.contains(hash8) {
                guard let rawData = makeThumbnailRaw(from: artData) else { continue }
                let rawURL = dir.appendingPathComponent("\(hash8).raw")
                do {
                    try rawData.write(to: rawURL, options: .atomic)
                    existingHashes.insert(hash8)
                } catch {
                    print("[TrackArtworkCache] 写入失败 \(hash8): \(error)")
                    continue
                }
            }

            newIndex[key] = hash8
        }

        // 写索引
        if let url = indexURL,
           let data = try? JSONEncoder().encode(newIndex) {
            try? data.write(to: url, options: .atomic)
        }

        // 更新内存池（只加载新增的 hash）
        lock.lock()
        trackIndex = newIndex
        for (_, hash8) in newIndex where pool[hash8] == nil {
            if let rawURL = rawURL(hash8: hash8),
               let (img, cgImg) = imageFromRawFile(url: rawURL) {
                pool[hash8] = img
                cgPool[hash8] = cgImg
            }
        }
        lock.unlock()

        progress?(total, total)
        print("[TrackArtworkCache] ✅ 构建完成：\(existingHashes.count) 张唯一封面，\(newIndex.count) 条映射")
    }

    // MARK: - 读取（同步，给 SwiftUI 行渲染用）

    func image(for item: PlaylistTrackItem) -> NSImage? {
        let key = trackKey(title: item.title, artist: item.artist, album: item.album)
        lock.lock()
        let hash8 = trackIndex[key]
        let img = hash8.flatMap { pool[$0] }
        lock.unlock()
        return img
    }

    func image(forKey key: String) -> NSImage? {
        lock.lock()
        let img = trackIndex[key].flatMap { pool[$0] }
        lock.unlock()
        return img
    }

    // 热路径专用：直接返回 CGImage，避免 NSImage→CGImage 转换
    // 配合 Image(decorative: cg, scale: 2.0) 使用，56px@2x = 28pt，零缩放
    func cgImage(for item: PlaylistTrackItem) -> CGImage? {
        let key = trackKey(title: item.title, artist: item.artist, album: item.album)
        lock.lock()
        let img = trackIndex[key].flatMap { cgPool[$0] }
        lock.unlock()
        return img
    }

    func cgImage(forKey key: String) -> CGImage? {
        lock.lock()
        let img = trackIndex[key].flatMap { cgPool[$0] }
        lock.unlock()
        return img
    }

    // MARK: - 清空（手动刷新时）

    func invalidate() {
        lock.lock()
        pool.removeAll()
        cgPool.removeAll()
        trackIndex.removeAll()
        lock.unlock()
        if let dir = artworkDir {
            try? FileManager.default.removeItem(at: dir)
        }
        print("[TrackArtworkCache] 🗑️ 已清空")
    }

    // MARK: - 私有工具

    /// 曲目唯一键（不依赖 persistentID，跨版本稳定）
    func trackKey(_ item: ITLibMediaItem) -> String {
        trackKey(title: item.title,
                 artist: item.artist?.name ?? "",
                 album: item.album.title ?? "")
    }

    func trackKey(title: String, artist: String, album: String) -> String {
        "\(title)|\(artist)|\(album)"
    }

    /// SHA-256 前 8 位作为文件名（碰撞概率极低，节省路径长度）
    private func sha256prefix8(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// 从音频文件提取封面原始 Data（同步，在后台线程调用）
    private func artworkData(from url: URL) -> Data? {
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

    /// 把封面 Data 缩放到 thumbSize×thumbSize，返回 BGRA raw Data（固定 rawByteCount 字节）
    private func makeThumbnailRaw(from data: Data) -> Data? {
        guard let src = NSImage(data: data) else { return nil }
        let size = Self.thumbSize
        let bytesPerRow = size * 4

        guard let ctx = CGContext(
            data: nil,
            width: size, height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .medium
        if let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        }

        guard let ptr = ctx.data else { return nil }
        return Data(bytes: ptr, count: bytesPerRow * size)
    }

    /// 从 .raw 文件 mmap 读取，返回 (NSImage, CGImage)（零拷贝，无 PNG 解码）
    private func imageFromRawFile(url: URL) -> (NSImage, CGImage)? {
        let size = Self.thumbSize
        let byteCount = Self.rawByteCount

        guard let mapped = try? Data(contentsOf: url, options: .mappedIfSafe),
              mapped.count == byteCount
        else { return nil }

        let provider = CGDataProvider(data: mapped as CFData)!
        guard let cgImg = CGImage(
            width: size, height: size,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedFirst.rawValue |
                CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }

        let img = NSImage(cgImage: cgImg, size: NSSize(width: size, height: size))
        return (img, cgImg)
    }
}
