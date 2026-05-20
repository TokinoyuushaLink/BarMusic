import AVFoundation
import Combine
import iTunesLibrary

// MARK: - 播放模式

enum PlayMode: CaseIterable {
    case sequential
    case shuffle
    case repeatOne

    var icon: String {
        switch self {
        case .sequential: return "arrow.right"
        case .shuffle:    return "shuffle"
        case .repeatOne:  return "repeat.1"
        }
    }

    var label: String {
        switch self {
        case .sequential: return L.modeSequential
        case .shuffle:    return L.modeShuffle
        case .repeatOne:  return L.modeRepeatOne
        }
    }
}

// MARK: - AudioPlayer
// Plain NSObject — no ObservableObject, no @Published.
// All UI updates go through MusicBridge which gates on popover visibility.

final class AudioPlayer: NSObject {

    static let shared = AudioPlayer()

    // Plain stored properties — no Combine overhead
    private(set) var isPlaying: Bool = false
    private(set) var currentIndex: Int = 0
    private(set) var queue: [PlayerItem] = []
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    var volume: Float = 1.0
    private(set) var playMode: PlayMode = .sequential

    // Callbacks — MusicBridge sets these; nil when popover is closed
    var onStateChanged: (() -> Void)?      // isPlaying, currentIndex, playMode
    var onTimeChanged: ((Double) -> Void)? // currentTime (only when popover open)

    private var player: AVPlayer?
    private weak var observerPlayer: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: AnyCancellable?
    private(set) var timeObserverPaused = false

    private var shuffleOrder: [Int] = []
    private var shufflePosition: Int = 0

    struct PlayerItem {
        let url: URL
        let title: String
        let artist: String
        let album: String
    }

    override private init() { super.init() }

    // MARK: - Load

    func load(items: [PlayerItem], startIndex: Int = 0) {
        stop()
        queue = items
        guard !items.isEmpty else { return }
        if playMode == .shuffle { buildShuffleOrder(startAt: startIndex) }
        play(at: startIndex)
    }

    // MARK: - Playback

    func play(at index: Int) {
        guard index >= 0, index < queue.count else { return }
        removeObservers()
        player?.pause()
        player = nil
        currentIndex = index
        let item = AVPlayerItem(url: queue[index].url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.volume = volume
        player = newPlayer
        setupObservers()
        player?.play()
        isPlaying = true
        onStateChanged?()
        Task {
            let dur = try? await item.asset.load(.duration)
            await MainActor.run { self.duration = dur?.seconds ?? 0 }
        }
    }

    func togglePlayPause() {
        // If we stopped at end of queue (player == nil but queue not empty), restart
        if player == nil && !queue.isEmpty {
            play(at: 0)
            return
        }
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
        onStateChanged?()
    }

    func next() {
        guard !queue.isEmpty else { return }
        switch playMode {
        case .repeatOne:
            player?.seek(to: .zero)
            player?.play()
            isPlaying = true
            onStateChanged?()
        case .shuffle:
            shufflePosition = (shufflePosition + 1) % shuffleOrder.count
            play(at: shuffleOrder[shufflePosition])
        case .sequential:
            let next = currentIndex + 1
            if next < queue.count {
                play(at: next)
            } else {
                currentIndex = 0
                removeObservers()
                player?.pause()
                player = nil
                isPlaying = false
                currentTime = 0
                onStateChanged?()
            }
        }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            player?.seek(to: .zero)
            currentTime = 0
            return
        }
        switch playMode {
        case .repeatOne:
            player?.seek(to: .zero)
        case .shuffle:
            shufflePosition = max(0, shufflePosition - 1)
            play(at: shuffleOrder[shufflePosition])
        case .sequential:
            play(at: max(0, currentIndex - 1))
        }
    }

    func stop() {
        removeObservers()
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        onStateChanged?()
    }

    func seek(to time: Double) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        currentTime = time
    }

    func setVolume(_ v: Float) {
        volume = v
        player?.volume = v
    }

    // MARK: - Shuffle

    private func buildShuffleOrder(startAt index: Int) {
        var order = Array(0..<queue.count)
        order.removeAll { $0 == index }
        order.shuffle()
        order.insert(index, at: 0)
        shuffleOrder = order
        shufflePosition = 0
    }

    func setPlayMode(_ mode: PlayMode) {
        playMode = mode
        if mode == .shuffle { buildShuffleOrder(startAt: currentIndex) }
    }

    func cyclePlayMode() {
        let all = PlayMode.allCases
        let idx = all.firstIndex(of: playMode)!
        playMode = all[(idx + 1) % all.count]
        if playMode == .shuffle { buildShuffleOrder(startAt: currentIndex) }
        onStateChanged?()
    }

    // MARK: - Track info

    var currentTrackInfo: (title: String, artist: String, album: String)? {
        guard !queue.isEmpty, currentIndex < queue.count else { return nil }
        let item = queue[currentIndex]
        return (item.title, item.artist, item.album)
    }

    var currentURL: URL? {
        guard !queue.isEmpty, currentIndex < queue.count else { return nil }
        return queue[currentIndex].url
    }

    // MARK: - Activity control

    func pauseTimeObserver() {
        guard !timeObserverPaused else { return }
        if let obs = timeObserver {
            observerPlayer?.removeTimeObserver(obs)
            timeObserver = nil
        }
        timeObserverPaused = true
    }

    func resumeTimeObserver() {
        guard timeObserverPaused else { return }
        timeObserverPaused = false
        if player != nil { setupObservers() }
    }

    // MARK: - Observers

    private func setupObservers() {
        removeObservers()
        observerPlayer = player

        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0, preferredTimescale: 600),
            queue: DispatchQueue.global(qos: .utility)
        ) { [weak self] time in
            guard let self, !self.timeObserverPaused else { return }
            let secs = time.seconds
            self.currentTime = secs
            DispatchQueue.main.async { self.onTimeChanged?(secs) }
        }

        endObserver = NotificationCenter.default
            .publisher(for: .AVPlayerItemDidPlayToEndTime, object: player?.currentItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.next() }
    }

    private func removeObservers() {
        if let obs = timeObserver {
            observerPlayer?.removeTimeObserver(obs)
            timeObserver = nil
        }
        observerPlayer = nil
        endObserver?.cancel()
        endObserver = nil
    }
}

// MARK: - PlayerItem builder (nonisolated, safe to call from Task.detached)

extension AudioPlayer.PlayerItem {
    static func build(from raw: [ITLibMediaItem], sortByTrack: Bool) -> [AudioPlayer.PlayerItem] {
        let sorted: [ITLibMediaItem] = sortByTrack
            ? raw.sorted {
                if $0.album.discNumber != $1.album.discNumber {
                    return $0.album.discNumber < $1.album.discNumber
                }
                return $0.trackNumber < $1.trackNumber
              }
            : raw
        return sorted.compactMap { track in
            guard let url = track.location else { return nil }
            return AudioPlayer.PlayerItem(
                url: url,
                title: track.title,
                artist: track.artist?.name ?? L.unknownArtist,
                album: track.album.title ?? L.unknownAlbum
            )
        }
    }
}
