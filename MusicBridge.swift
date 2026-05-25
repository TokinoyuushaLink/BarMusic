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
    @Published var currentPlaylistName: String = ""
    @Published var volume: Float = UserDefaults.standard.object(forKey: "volume") as? Float ?? 1.0
    /// 主列表滚动位置锚点（playlist name），session 内持久，popover 关闭时销毁
    @Published var playlistScrollID: String? = nil

    // Drill-down
    @Published var drillPlaylistName: String? = nil
    @Published var drillTracks: [PlaylistTrackItem] = []
    @Published var isLoadingDrill: Bool = false

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
        guard playlistGroups.isEmpty else { return }

        // 先尝试从磁盘加载（同步，极快）
        if let cached = PlaylistDiskCache.shared.load() {
            playlistGroups = cached
            // 缓存命中：并行预热（Track/Artwork 不依赖 ITLibrary，无需等待）
            Task.detached(priority: .userInitiated) {
                PlaylistDiskCache.shared.prewarmTrackCaches()
            }
            Task.detached(priority: .utility) {
                TrackArtworkCache.shared.loadFromDisk {}
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
                        TrackArtworkCache.shared.buildCache(for: allPlaylists) { done, total in
                            let p = prog.setArt(done: done, total: total)
                            DispatchQueue.main.async { [weak self] in self?.buildProgress = p }
                        }
                        print("[MusicBridge] ✅ 封面缓存构建完成")
                    }

                    // 任务 2：预构建所有播放列表的曲目缓存（贡献进度 50–100%）
                    group.addTask {
                        print("[MusicBridge] 📋 曲目缓存构建中...")
                        PlaylistDiskCache.shared.prebuildAllTracksCaches(from: allPlaylists) { done, total in
                            let p = prog.setTrk(done: done, total: total)
                            DispatchQueue.main.async { [weak self] in self?.buildProgress = p }
                        }
                        print("[MusicBridge] ✅ 曲目缓存构建完成")
                    }

                    await group.waitForAll()
                }

                print("[MusicBridge] 🎉 全部缓存构建完成！")
            }

            await MainActor.run { [weak self] in
                self?.playlistGroups = groups
                self?.isLoadingPlaylists = false
                self?.buildProgress = 1.0
                self?.buildStatusText = ""
            }
        }
    }

    // MARK: - Drill-down

    func openPlaylistDetail(named name: String) {
        drillPlaylistName = name
        drillTracks = []
        isLoadingDrill = true
        Task.detached(priority: .userInitiated) {
            // 1. 优先从活跃列表读取
            if let active = PlaylistDiskCache.shared.getActivePlaylistTracks(),
               active.name == name {
                await MainActor.run { [weak self] in
                    self?.drillTracks = active.tracks
                    self?.isLoadingDrill = false
                }
                return
            }
            
            // 2. 从磁盘/内存缓存读取（应该已经预构建好了）
            if let cached = PlaylistDiskCache.shared.loadTracks(for: name) {
                await MainActor.run { [weak self] in
                    self?.drillTracks = cached
                    self?.isLoadingDrill = false
                }
                return
            }

            // 3. 缓存未命中（极少发生）→ 从 iTunesLibrary 读取
            print("[MusicBridge] ⚠️ 曲目缓存未命中：\(name)，从 iTunes 库读取")
            guard let library = LibraryCache.shared.get(),
                  let playlist = library.allPlaylists.first(where: { $0.name == name })
            else {
                await MainActor.run { [weak self] in self?.isLoadingDrill = false }
                return
            }
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
            // 写入活跃列表缓存
            PlaylistDiskCache.shared.setActivePlaylist(name: name, tracks: tracks)
            await MainActor.run { [weak self] in
                self?.drillTracks = tracks
                self?.isLoadingDrill = false
            }
        }
    }

    func closePlaylistDetail() {
        drillPlaylistName = nil
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
                self?.audioPlayer.load(items: items, startIndex: startIndex)
            }
        }
    }

    var sortedDrillTracks: [PlaylistTrackItem] {
        guard sortByTrackOrder else { return drillTracks }
        return drillTracks.sorted {
            if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
            return $0.trackNumber < $1.trackNumber
        }
    }

    func playPlaylist(named name: String) {
        let sortByTrack = sortByTrackOrder
        Task.detached(priority: .userInitiated) {
            // 优先从缓存读取（L1/L2/L3），无需 ITLibrary → 零延迟
            if let cached = PlaylistDiskCache.shared.loadTracks(for: name) {
                let items = AudioPlayer.PlayerItem.build(from: cached, sortByTrack: sortByTrack)
                if !items.isEmpty {
                    await MainActor.run { [weak self] in
                        self?.currentPlaylistName = name
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

        var id: String {
            switch self {
            case .folderHeader(let g, _): return "folder:\(g.folderName)"
            case .playlist(_, let p):    return p.id.uuidString
            }
        }
    }

    var flatPlaylistItems: [FlatPlaylistItem] {
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
