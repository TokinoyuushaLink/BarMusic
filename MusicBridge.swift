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
    private(set) var library: ITLibrary? = nil
    func get() -> ITLibrary? {
        if let lib = library { return lib }
        library = try? ITLibrary(apiVersion: "1.1")
        return library
    }
    func invalidate() { library = nil }
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

// MARK: - MusicBridge

@MainActor
final class MusicBridge: ObservableObject {

    @Published var isPlaying: Bool = false
    @Published var currentTrack: TrackInfo = TrackInfo()
    @Published var currentArtwork: NSImage? = nil
    @Published var playlistGroups: [PlaylistGroup] = []
    @Published var isLoadingPlaylists: Bool = false
    @Published var currentPlaylistName: String = ""
    @Published var currentTime: Double = 0
    @Published var volume: Float = UserDefaults.standard.object(forKey: "volume") as? Float ?? 1.0

    // Drill-down
    @Published var drillPlaylistName: String? = nil
    @Published var drillTracks: [PlaylistTrackItem] = []
    @Published var isLoadingDrill: Bool = false

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
                self.isPlaying  = self.audioPlayer.isPlaying
                self.playMode   = self.audioPlayer.playMode
                self.volume     = self.audioPlayer.volume
                self.syncCurrentTrack()
            }
        }

        audioPlayer.onTimeChanged = { [weak self] secs in
            Task { @MainActor [weak self] in
                self?.currentTime = secs
            }
        }

        // Apply persisted volume to the player immediately
        audioPlayer.setVolume(volume)
    }

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
        audioPlayer.resumeTimeObserver()
        // Sync everything that may have changed while popover was closed
        isPlaying  = audioPlayer.isPlaying
        playMode   = audioPlayer.playMode
        volume     = audioPlayer.volume
        currentTime = audioPlayer.currentTime
        syncCurrentTrack()
    }

    func popoverDidClose() {
        isPopoverOpen = false
        audioPlayer.pauseTimeObserver()
    }

    // MARK: - Playlist loading

    func fetchPlaylists() {
        guard playlistGroups.isEmpty else { return }
        loadPlaylists()
    }

    func refreshPlaylists() {
        guard !isLoadingPlaylists else { return }
        LibraryCache.shared.invalidate()
        ArtworkCache.shared.clear()
        playlistGroups = []
        loadPlaylists()
    }

    private func loadPlaylists() {
        guard !isLoadingPlaylists else { return }
        isLoadingPlaylists = true
        Task.detached(priority: .userInitiated) {
            let groups = LibraryReader.fetchGroupedPlaylists()
            await MainActor.run { [weak self] in
                self?.playlistGroups = groups
                self?.isLoadingPlaylists = false
            }
        }
    }

    // MARK: - Drill-down

    func openPlaylistDetail(named name: String) {
        drillPlaylistName = name
        drillTracks = []
        isLoadingDrill = true
        Task.detached(priority: .userInitiated) {
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
        let tracks = sortedDrillTracks
        let sortByTrack = sortByTrackOrder   // capture on MainActor before detaching
        Task.detached(priority: .userInitiated) {
            guard let library = LibraryCache.shared.get(),
                  let playlist = library.allPlaylists.first(where: { $0.name == name })
            else { return }
            let items = AudioPlayer.PlayerItem.build(from: playlist.items, sortByTrack: sortByTrack)
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
        let sortByTrack = sortByTrackOrder   // capture on MainActor before detaching
        Task.detached(priority: .userInitiated) {
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
