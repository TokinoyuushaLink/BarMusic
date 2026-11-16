import Foundation
import AppKit
import Combine
import iTunesLibrary

// MARK: - Track entry for drill-down view

struct PlaylistTrackItem: Identifiable {
    let id: UUID = UUID()
    let title: String
    let artist: String
    let album: String
    let discNumber: Int
    let trackNumber: Int
    let url: URL?
}

// MARK: - Library mode

enum LibraryMode: String {
    case musicLibrary   // 系统音乐库
    case folder         // 用户指定的文件夹，递归读取
}

// MARK: - ITLibrary cache

final class LibraryCache {
    static let shared = LibraryCache()
    private init() {}
    private var library: ITLibrary? = nil
    private let lock = NSLock()

    func get() -> ITLibrary? {
        lock.lock()
        defer { lock.unlock() }
        if let lib = library { return lib }
        library = try? ITLibrary(apiVersion: "1.1")
        return library
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        library = nil
    }
}

// MARK: - Artwork cache

final class ArtworkCache {
    static let shared = ArtworkCache()
    private init() {}
    private var cache: [URL: Data] = [:]
    private let queue = DispatchQueue(label: "ArtworkCache", attributes: .concurrent)
    func artworkData(for url: URL) -> Data? { queue.sync { cache[url] } }
    func store(_ data: Data, for url: URL) {
        queue.async(flags: .barrier) { self.cache[url] = data }
    }
    func clear() { queue.async(flags: .barrier) { self.cache.removeAll() } }
}

// MARK: - Build progress tracker (thread-safe, used across two concurrent tasks)

private final class BuildProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var artDone = 0, artTotal = 1
    private var trkDone = 0, trkTotal = 1

    func setArt(done: Int, total: Int) -> Double {
        lock.lock(); defer { lock.unlock() }
        artDone = done; artTotal = max(1, total)
        return combined
    }

    func setTrk(done: Int, total: Int) -> Double {
        lock.lock(); defer { lock.unlock() }
        trkDone = done; trkTotal = max(1, total)
        return combined
    }

    private var combined: Double {
        Double(artDone) / Double(artTotal) * 0.5 +
        Double(trkDone) / Double(trkTotal) * 0.5
    }
}

// MARK: - WaveformStore (isolated ObservableObject so band updates don't invalidate ContentView)

final class WaveformStore: ObservableObject {
    @Published var bands: [Float] = [Float](repeating: 0, count: 6)
    private var pollTimer: Timer?

    func startPolling() {
        guard pollTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.bands = AudioPlayer.shared.latestBands
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        bands = [Float](repeating: 0, count: 6)
    }
}

// MARK: - MusicBridge

@MainActor
final class MusicBridge: ObservableObject {

    @Published var isPlaying: Bool = false
    @Published var currentTrack: TrackInfo = TrackInfo()
    @Published var currentArtwork: NSImage? = nil
    @Published var playlistGroups: [PlaylistGroup] = []
    @Published var isLoadingPlaylists: Bool = false
    @Published var buildProgress: Double = 0
    @Published var buildStatusText: String = ""
    /// Changes only when a complete artwork snapshot becomes available.
    @Published private(set) var artworkCacheRevision: Int = 0
    /// 当前播放列表的标识（音乐库模式是列表名，文件夹模式是目录相对路径）。
    @Published var currentPlaylistName: String = ""
    @Published var currentPlaylistTitle: String = ""
    @Published var currentTrackPath: String = ""

    // Library mode
    @Published private(set) var libraryMode: LibraryMode = {
        LibraryMode(rawValue: UserDefaults.standard.string(forKey: "libraryMode") ?? "") ?? .musicLibrary
    }()
    @Published private(set) var folderRootURL: URL? = {
        guard let path = UserDefaults.standard.string(forKey: "folderModeRoot"), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()
    @Published private(set) var folderTree: FolderNode? = nil
    private var folderNodes: [String: FolderNode] = [:]
    /// 切换数据源时递增，用来丢弃过期的后台结果。
    private var loadGeneration: UInt = 0
    @Published var volume: Float = UserDefaults.standard.object(forKey: "volume") as? Float ?? 1.0
    /// 主列表滚动位置锚点（playlist name），session 内持久，popover 关闭时销毁
    @Published var playlistScrollID: String? = nil

    // Drill-down
    @Published var drillPlaylistName: String? = nil
    @Published var drillTracks: [PlaylistTrackItem] = [] {
        didSet {
            cachedTrackOrder = drillTracks.sorted {
                if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                return $0.trackNumber < $1.trackNumber
            }
        }
    }
    @Published var isLoadingDrill: Bool = false
    private var cachedTrackOrder: [PlaylistTrackItem] = []
    private var drillLoadGeneration: UInt = 0

    let waveformStore = WaveformStore()

    private static func defaultShowWaveform() -> Bool {
        let ud = UserDefaults.standard
        return ud.object(forKey: "showWaveform") != nil ? ud.bool(forKey: "showWaveform") : true
    }
    @Published var showWaveform: Bool = MusicBridge.defaultShowWaveform() {
        didSet {
            UserDefaults.standard.set(showWaveform, forKey: "showWaveform")
            if showWaveform && isPopoverOpen {
                audioPlayer.startWaveformTap(); waveformStore.startPolling()
            } else {
                audioPlayer.stopWaveformTap(); waveformStore.stopPolling()
            }
        }
    }

    @Published var sortByTrackOrder: Bool = UserDefaults.standard.object(forKey: "sortByTrackOrder") as? Bool ?? true
    @Published var playMode: PlayMode = .sequential

    // Folder collapse state
    @Published var collapsedFolders: Set<String> = {
        let saved = UserDefaults.standard.stringArray(forKey: "collapsedFolders") ?? []
        return Set(saved)
    }()

    let audioPlayer = AudioPlayer.shared
    private var isPopoverOpen = false

    init() {
        // Wire AudioPlayer callbacks — these fire only on actual events, no Combine overhead
        audioPlayer.onStateChanged = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isPopoverOpen else {
                    // Popover 关闭：只在内存里记录曲目信息，不碰任何 @Published
                    // 等 popoverDidOpen 时统一同步，避免触发 SwiftUI diff
                    return
                }
                self.isPlaying  = self.audioPlayer.isPlaying
                self.playMode   = self.audioPlayer.playMode
                self.volume     = self.audioPlayer.volume
                self.syncCurrentTrack()
            }
        }


        // Apply persisted volume to the player immediately
        audioPlayer.setVolume(volume)

        if libraryMode == .folder, folderRootURL == nil { libraryMode = .musicLibrary }
        applyArtworkCacheForCurrentMode()
    }

    func toggleWaveform() { showWaveform.toggle() }

    // MARK: - Playback controls

    func togglePlayPause() { audioPlayer.togglePlayPause() }
    func nextTrack()        { audioPlayer.next() }
    func previousTrack()    { audioPlayer.previous() }

    func cyclePlayMode() {
        audioPlayer.cyclePlayMode()
        playMode = audioPlayer.playMode
    }

    func toggleSortOrder() {
        sortByTrackOrder.toggle()
        UserDefaults.standard.set(sortByTrackOrder, forKey: "sortByTrackOrder")
    }

    func setVolume(_ v: Float) {
        audioPlayer.setVolume(v)
        volume = v
        UserDefaults.standard.set(v, forKey: "volume")
    }

    func setInterTrackDelay(_ delay: TimeInterval) {
        audioPlayer.setInterTrackDelay(delay)
    }

    // MARK: - Popover lifecycle

    func popoverDidOpen() {
        isPopoverOpen = true
        isPlaying = audioPlayer.isPlaying
        playMode  = audioPlayer.playMode
        volume    = audioPlayer.volume
        syncCurrentTrack()
        if showWaveform { audioPlayer.startWaveformTap(); waveformStore.startPolling() }
    }

    func popoverDidClose() {
        isPopoverOpen = false
        _playlistScrollID = .init(wrappedValue: nil)
        audioPlayer.stopWaveformTap()
        waveformStore.stopPolling()
    }
    // MARK: - Playlist loading

    /// 启动时调用：优先读磁盘缓存，缓存不存在才从 iTunes 框架重新构建。
    func fetchPlaylists() {
        if libraryMode == .folder { loadFolderLibrary(rescan: false); return }
        guard playlistGroups.isEmpty else { return }

        // 先尝试从磁盘加载（同步，极快）
        if let cached = PlaylistDiskCache.shared.load() {
            playlistGroups = cached
            // 缓存命中：并行预热（Track/Artwork 不依赖 ITLibrary，无需等待）
            Task.detached(priority: .userInitiated) {
                PlaylistDiskCache.shared.prewarmTrackCaches()
            }
            Task.detached(priority: .utility) {
                TrackArtworkCache.shared.loadFromDisk { [weak self] in
                    self?.artworkCacheRevision &+= 1
                }
            }
            Task.detached(priority: .background) {
                _ = LibraryCache.shared.get()  // 后台静默预热，不阻塞前两个任务
            }
            return
        }

        // 无缓存 → 首次构建（同时构建曲目封面缓存）
        buildAndCachePlaylists()
    }

    /// 手动刷新：强制从 iTunes 框架重新读取并覆盖缓存。
    func refreshPlaylists() {
        guard !isLoadingPlaylists else { return }
        if libraryMode == .folder { loadFolderLibrary(rescan: true); return }
        LibraryCache.shared.invalidate()
        ArtworkCache.shared.clear()
        PlaylistDiskCache.shared.deleteAllCacheFiles()
        TrackArtworkCache.shared.invalidate()
        playlistGroups = []
        buildAndCachePlaylists()
    }

    /// 从 iTunesLibrary 框架构建列表，完成后写入磁盘缓存。
    private func buildAndCachePlaylists() {
        guard !isLoadingPlaylists else { return }
        isLoadingPlaylists = true
        buildProgress = 0
        buildStatusText = L.buildingCache
        // 构建期间用户可能切到文件夹模式：抓住本次的封面缓存与代号，过期就不碰界面状态。
        loadGeneration &+= 1
        let generation = loadGeneration
        let artworkCache = TrackArtworkCache.shared
        Task.detached(priority: .userInitiated) {
            let groups = LibraryReader.fetchGroupedPlaylists()
            // 在后台线程写缓存，不阻塞主线程
            PlaylistDiskCache.shared.save(groups)

            // 并行构建：封面缓存 + 全部播放列表曲目缓存
            if let library = LibraryCache.shared.get() {
                let allPlaylists = library.allPlaylists
                print("[MusicBridge] 🚀 开始并行构建：封面缓存 + 曲目缓存（共 \(allPlaylists.count) 个列表）")
                let prog = BuildProgress()

                await withTaskGroup(of: Void.self) { group in
                    // 任务 1：构建封面缓存（贡献进度 0–50%）
                    group.addTask {
                        print("[MusicBridge] 📸 封面缓存构建中...")
                        artworkCache.buildCache(for: allPlaylists) { done, total in
                            let p = prog.setArt(done: done, total: total)
                            Task { @MainActor in self.buildProgress = p }
                        }
                        print("[MusicBridge] ✅ 封面缓存构建完成")
                    }

                    // 任务 2：预构建所有播放列表的曲目缓存（贡献进度 50–100%）
                    group.addTask {
                        print("[MusicBridge] 📋 曲目缓存构建中...")
                        PlaylistDiskCache.shared.prebuildAllTracksCaches(from: allPlaylists) { done, total in
                            let p = prog.setTrk(done: done, total: total)
                            Task { @MainActor in self.buildProgress = p }
                        }
                        print("[MusicBridge] ✅ 曲目缓存构建完成")
                    }

                    await group.waitForAll()
                }

                print("[MusicBridge] 🎉 全部缓存构建完成！")
            }

            await MainActor.run { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.playlistGroups = groups
                self.isLoadingPlaylists = false
                self.buildProgress = 1.0
                self.buildStatusText = ""
                self.artworkCacheRevision &+= 1
            }
        }
    }

    // MARK: - Folder mode

    /// 读 <根目录>/.bmcache；没有缓存（或手动刷新）时递归扫描并重建缓存。
    private func loadFolderLibrary(rescan: Bool) {
        guard let root = folderRootURL, !isLoadingPlaylists else { return }
        if !rescan, folderTree != nil { return }
        if rescan {
            // 根目录读不到（比如移动硬盘没插）时保留现有内容
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue
            else { return }
            TrackArtworkCache.shared.invalidate()
        }
        isLoadingPlaylists = true
        buildProgress = 0
        buildStatusText = L.scanningFolder
        loadGeneration &+= 1
        let generation = loadGeneration
        let artworkCache = TrackArtworkCache.shared

        Task.detached(priority: .userInitiated) { [weak self] in
            var tree = rescan ? nil : FolderLibrary.loadCache(root: root)
            if tree != nil {
                artworkCache.loadFromDisk { [weak self] in self?.artworkCacheRevision &+= 1 }
            } else {
                tree = FolderLibrary.scan(root: root, artworkCache: artworkCache) { value in
                    Task { @MainActor [weak self] in
                        guard let self, self.loadGeneration == generation else { return }
                        self.buildProgress = value
                    }
                }
                if let tree { FolderLibrary.saveCache(tree, root: root) }
            }
            let node = tree.map { FolderNode(data: $0, url: root, key: ".") }
            await MainActor.run { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                if let node {
                    var index: [String: FolderNode] = [:]
                    node.index(into: &index)
                    self.folderNodes = index
                    self.folderTree = node
                }
                self.isLoadingPlaylists = false
                self.buildProgress = 1.0
                self.buildStatusText = ""
                self.artworkCacheRevision &+= 1
            }
        }
    }

    private func applyArtworkCacheForCurrentMode() {
        if libraryMode == .folder, let root = folderRootURL {
            TrackArtworkCache.activate(.folder(at: root))
        } else {
            TrackArtworkCache.activate(.library)
        }
    }

    private func reloadForSourceChange() {
        loadGeneration &+= 1                 // 让在途的后台结果失效
        isLoadingPlaylists = false
        buildProgress = 0
        buildStatusText = ""
        drillLoadGeneration &+= 1
        isLoadingDrill = false
        drillPlaylistName = nil
        drillTracks = []
        playlistScrollID = nil
        playlistGroups = []
        folderTree = nil
        folderNodes = [:]
        applyArtworkCacheForCurrentMode()
        artworkCacheRevision &+= 1
        fetchPlaylists()
    }

    func setLibraryMode(_ mode: LibraryMode) {
        guard mode != libraryMode else { return }
        if mode == .folder, folderRootURL == nil { return }     // 需要先指定文件夹
        libraryMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "libraryMode")
        reloadForSourceChange()
    }

    /// 指定（或更换）文件夹，并切换到文件夹模式。
    func setFolderRoot(_ url: URL) {
        let root = url.standardizedFileURL
        let changed = folderRootURL?.path != root.path
        folderRootURL = root
        UserDefaults.standard.set(root.path, forKey: "folderModeRoot")
        if libraryMode == .folder && !changed { return }
        libraryMode = .folder
        UserDefaults.standard.set(LibraryMode.folder.rawValue, forKey: "libraryMode")
        reloadForSourceChange()
    }

    /// 界面上显示的列表名：文件夹模式下标识是相对路径，显示的是目录名。
    func playlistTitle(for key: String) -> String {
        libraryMode == .folder ? (folderNodes[key]?.name ?? key) : key
    }

    func representativeKey(forPlaylist key: String) -> String? {
        if libraryMode == .folder { return folderNodes[key]?.repKey }
        return playlistGroups.flatMap { $0.playlists }.first { $0.name == key }?.representativeTrackKey
    }

    /// 列表头部右侧的数字：音乐库是列表数，文件夹模式是曲目总数。
    var listTotalCount: Int {
        libraryMode == .folder
            ? (folderTree?.totalTracks ?? 0)
            : playlistGroups.reduce(0) { $0 + $1.playlists.count }
    }

    private func orderedTracks(of node: FolderNode) -> [PlaylistTrackItem] {
        guard sortByTrackOrder else { return node.tracks }
        return node.tracks.sorted {
            if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
            return $0.trackNumber < $1.trackNumber
        }
    }

    /// 播放某个目录下直接包含的曲目；tappedURL 指定从哪一首开始。
    private func playFolderNode(_ node: FolderNode, startingAt tappedURL: URL? = nil) {
        let items = AudioPlayer.PlayerItem.build(from: node.tracks, sortByTrack: sortByTrackOrder)
        guard !items.isEmpty else { return }
        let start = tappedURL.flatMap { url in items.firstIndex { $0.url == url } } ?? 0
        currentPlaylistName = node.key
        currentPlaylistTitle = node.name
        audioPlayer.load(items: items, startIndex: start)
    }

    /// 主列表里点击散落的音频文件：以所在目录为队列，从这一首开始。
    func playFolderTrack(dirKey: String, index: Int) {
        guard let node = folderNodes[dirKey] else { return }
        let ordered = orderedTracks(of: node)
        guard index < ordered.count else { return }
        playFolderNode(node, startingAt: ordered[index].url)
    }

    // MARK: - Drill-down

    func openPlaylistDetail(named name: String) {
        // Do not begin the panel transition until the destination table has its
        // data. Otherwise a slow/cold playlist replaces the loading view midway
        // through the Core Animation movement and appears to skip the animation.
        drillLoadGeneration &+= 1
        let generation = drillLoadGeneration
        if libraryMode == .folder {
            guard let node = folderNodes[name] else { return }
            drillTracks = node.tracks
            isLoadingDrill = false
            drillPlaylistName = name
            return
        }
        drillTracks = []
        isLoadingDrill = true
        Task.detached(priority: .userInitiated) {
            let tracks: [PlaylistTrackItem]?

            // 1. 优先从活跃列表读取
            if let active = PlaylistDiskCache.shared.getActivePlaylistTracks(),
               active.name == name {
                tracks = active.tracks
            } else if let cached = PlaylistDiskCache.shared.loadTracks(for: name) {
                // 2. 从磁盘/内存缓存读取（通常已经预构建）
                tracks = cached
            } else {
                // 3. 缓存未命中（极少发生）→ 从 iTunesLibrary 读取
                print("[MusicBridge] ⚠️ 曲目缓存未命中：\(name)，从 iTunes 库读取")
                if let library = LibraryCache.shared.get(),
                   let playlist = library.allPlaylists.first(where: { $0.name == name }) {
                    tracks = playlist.items.map { track in
                        PlaylistTrackItem(
                            title: track.title,
                            artist: track.artist?.name ?? L.unknownArtist,
                            album: track.album.title ?? L.unknownAlbum,
                            discNumber: track.album.discNumber,
                            trackNumber: track.trackNumber,
                            url: track.location
                        )
                    }
                } else {
                    tracks = nil
                }
            }

            await MainActor.run { [weak self] in
                guard let self, self.drillLoadGeneration == generation else { return }
                guard let tracks else {
                    self.isLoadingDrill = false
                    return
                }

                PlaylistDiskCache.shared.setActivePlaylist(name: name, tracks: tracks)
                // Publish the destination content first. drillPlaylistName is
                // deliberately last because it is the transition trigger.
                self.drillTracks = tracks
                self.isLoadingDrill = false
                self.drillPlaylistName = name
            }
        }
    }

    func closePlaylistDetail() {
        drillLoadGeneration &+= 1
        drillPlaylistName = nil
        // drillTracks 由 ContentView 在退出动画结束后延迟清理
    }

    func clearDrillData() {
        drillTracks = []
    }

    func playFromDrill(index: Int) {
        guard let name = drillPlaylistName else { return }
        // drillTracks 已在内存中，包含文件 URL，无需再访问 ITLibrary
        let tracks = sortedDrillTracks
        let sortByTrack = sortByTrackOrder
        Task.detached(priority: .userInitiated) {
            let items = AudioPlayer.PlayerItem.build(from: tracks, sortByTrack: sortByTrack)
            guard !items.isEmpty else { return }
            let tapped = tracks[index]
            let startIndex = items.firstIndex(where: {
                $0.title == tapped.title && $0.artist == tapped.artist
            }) ?? 0
            await MainActor.run { [weak self] in
                self?.currentPlaylistName = name
                self?.currentPlaylistTitle = self?.playlistTitle(for: name) ?? name
                self?.audioPlayer.load(items: items, startIndex: startIndex)
            }
        }
    }

    var sortedDrillTracks: [PlaylistTrackItem] {
        sortByTrackOrder ? cachedTrackOrder : drillTracks
    }

    func playPlaylist(named name: String) {
        if libraryMode == .folder {
            if let node = folderNodes[name] { playFolderNode(node) }
            return
        }
        let sortByTrack = sortByTrackOrder
        Task.detached(priority: .userInitiated) {
            // 优先从缓存读取（L1/L2/L3），无需 ITLibrary → 零延迟
            if let cached = PlaylistDiskCache.shared.loadTracks(for: name) {
                let items = AudioPlayer.PlayerItem.build(from: cached, sortByTrack: sortByTrack)
                if !items.isEmpty {
                    await MainActor.run { [weak self] in
                        self?.currentPlaylistName = name
                        self?.currentPlaylistTitle = name
                        self?.audioPlayer.load(items: items, startIndex: 0)
                    }
                    return
                }
            }
            // 缓存未命中（极少）→ 回退到 ITLibrary
            guard let library = LibraryCache.shared.get(),
                  let playlist = library.allPlaylists.first(where: { $0.name == name })
            else { return }
            let items = AudioPlayer.PlayerItem.build(from: playlist.items, sortByTrack: sortByTrack)
            guard !items.isEmpty else { return }
            await MainActor.run { [weak self] in
                self?.currentPlaylistName = name
                self?.currentPlaylistTitle = name
                self?.audioPlayer.load(items: items, startIndex: 0)
            }
        }
    }



    // MARK: - Folder collapse

    func toggleFolderCollapse(_ folderName: String) {
        if collapsedFolders.contains(folderName) {
            collapsedFolders.remove(folderName)
        } else {
            collapsedFolders.insert(folderName)
        }
        UserDefaults.standard.set(Array(collapsedFolders), forKey: "collapsedFolders")
    }

    func isFolderCollapsed(_ folderName: String) -> Bool {
        collapsedFolders.contains(folderName)
    }

    func isGroupHidden(_ group: PlaylistGroup) -> Bool {
        group.ancestorFolderNames.contains(where: { collapsedFolders.contains($0) })
    }

    // MARK: - Flat list for LazyVStack (eliminates nested ForEach traversal during scroll)

    enum FlatPlaylistItem: Identifiable {
        case folderHeader(group: PlaylistGroup, collapsed: Bool)
        case playlist(group: PlaylistGroup, info: PlaylistInfo)
        /// 文件夹模式：直接显示在主列表里的音频文件。
        case track(group: PlaylistGroup, track: PlaylistTrackItem, dirKey: String, index: Int)

        var id: String {
            switch self {
            case .folderHeader(let g, _): return "folder:\(g.folderName)"
            case .playlist(_, let p):    return p.id.uuidString
            case .track(_, let t, _, _): return "track:\(t.url?.path ?? t.id.uuidString)"
            }
        }
    }

    /// 文件夹模式的主列表：
    ///  · 只含音乐的文件夹 → 一行，可进入
    ///  · 含子文件夹的文件夹 → 带箭头的折叠头，里面是它的子文件夹和直接包含的音频
    ///  · 根目录直接包含的音频 → 直接平铺
    private var folderFlatItems: [FlatPlaylistItem] {
        guard let root = folderTree else { return [] }
        var result: [FlatPlaylistItem] = []

        func emit(_ node: FolderNode, level: Int) {
            // level 0 = 根（不缩进）；其余与音乐库模式的文件夹缩进规则一致
            let group = PlaylistGroup(
                folderName: level == 0 ? "" : node.url.path, folderArtwork: nil,
                isFolder: level > 0, indentLevel: level, ancestorFolderNames: [],
                playlists: [], representativeTrackKey: node.repKey)

            for child in node.children {
                if child.isLeaf {
                    result.append(.playlist(group: group, info: PlaylistInfo(
                        id: child.id, libraryID: NSNumber(value: 0), name: child.key,
                        trackCount: child.tracks.count, kind: .folder, artworkImage: nil,
                        isFolder: false, representativeTrackKey: child.repKey, title: child.name)))
                } else {
                    let header = PlaylistGroup(
                        folderName: child.url.path, folderArtwork: nil, isFolder: true,
                        indentLevel: level + 1, ancestorFolderNames: [], playlists: [],
                        representativeTrackKey: child.repKey, title: child.name)
                    let collapsed = isFolderCollapsed(header.folderName)
                    result.append(.folderHeader(group: header, collapsed: collapsed))
                    if !collapsed { emit(child, level: level + 1) }
                }
            }
            for (i, track) in orderedTracks(of: node).enumerated() {
                result.append(.track(group: group, track: track, dirKey: node.key, index: i))
            }
        }
        emit(root, level: 0)
        return result
    }

    var flatPlaylistItems: [FlatPlaylistItem] {
        if libraryMode == .folder { return folderFlatItems }
        var result: [FlatPlaylistItem] = []
        for group in playlistGroups {
            guard !isGroupHidden(group) else { continue }
            if group.isFolder {
                let collapsed = isFolderCollapsed(group.folderName)
                result.append(.folderHeader(group: group, collapsed: collapsed))
                if collapsed { continue }
            }
            for pl in group.playlists {
                result.append(.playlist(group: group, info: pl))
            }
        }
        return result
    }

    func refreshStatus() { syncCurrentTrack() }

    // MARK: - Track sync

    private func syncCurrentTrack() {
        let path = audioPlayer.currentURL?.path ?? ""
        if currentTrackPath != path { currentTrackPath = path }
        guard let info = audioPlayer.currentTrackInfo else {
            currentTrack = TrackInfo()
            currentArtwork = nil
            return
        }
        currentTrack = TrackInfo(name: info.title, artist: info.artist, album: info.album)
        guard isPopoverOpen else { return }
        let url = audioPlayer.currentURL
        Task.detached(priority: .utility) {
            let imgData: Data?
            if let url {
                if let cached = ArtworkCache.shared.artworkData(for: url) {
                    imgData = cached
                } else {
                    let data = LibraryReader.artworkDataFromFile(url: url)
                    if let data { ArtworkCache.shared.store(data, for: url) }
                    imgData = data
                }
            } else {
                imgData = nil
            }
            // Construct NSImage on MainActor to avoid Sendable warning
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let data = imgData, let img = NSImage(data: data) {
                    self.currentArtwork = img
                } else {
                    self.currentArtwork = nil
                }
            }
        }
    }
}
