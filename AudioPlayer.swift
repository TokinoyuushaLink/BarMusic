import AVFoundation
import Accelerate
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
// Uses AVAudioEngine + AVAudioPlayerNode instead of AVPlayer.
// AVPlayer ties its render pipeline to CVDisplayLink (display clock), causing
// CPU wakeups whenever the display activates (mouse over menu bar, Space switch).
// AVAudioEngine runs on the audio HAL clock — completely decoupled from the display.

final class AudioPlayer: NSObject {

    static let shared = AudioPlayer()

    private let engine     = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    private var currentFile: AVAudioFile?
    // Frame position of the start of the currently scheduled segment (for seek tracking)
    private var seekFrameOffset: AVAudioFramePosition = 0
    // Incremented on every play/seek/stop to invalidate stale completion callbacks
    private var playGeneration = 0

    private(set) var isPlaying:   Bool     = false
    private(set) var currentIndex: Int     = 0
    private(set) var queue:       [PlayerItem] = []
    private(set) var cachedDuration: Double = 0
    private(set) var playMode:    PlayMode = .sequential
    var volume: Float = 1.0

    var onStateChanged: (() -> Void)?

    // Waveform FFT (audio-thread only — never accessed from main thread)
    private var fftSetup: FFTSetup?
    private let fftN     = 1024
    private let fftHalfN = 512
    private let fftLog2n = vDSP_Length(10)
    private var smoothedBands = [Float](repeating: 0, count: 6)
    private var peakBands     = [Float](repeating: 1, count: 6)
    private var waveformTapActive = false
    // Ring buffer: accumulate 256-frame chunks so FFT always sees 1024 samples
    private var ringBuffer  = [Float](repeating: 0, count: 1024)
    private var ringWritePos = 0

    // Latest FFT result — written on audio thread, read on main thread via lock
    private let bandsLock = NSLock()
    private var _latestBands: [Float] = [Float](repeating: 0, count: 6)
    var latestBands: [Float] {
        bandsLock.lock(); defer { bandsLock.unlock() }
        return _latestBands
    }

    private var shuffleOrder:    [Int] = []
    private var shufflePosition: Int   = 0

    // MARK: - Current position

    var currentTime: Double {
        let sr = currentFile?.processingFormat.sampleRate ?? 44100
        guard let nodeTime   = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0
        else { return Double(seekFrameOffset) / sr }
        return Double(seekFrameOffset + max(0, playerTime.sampleTime)) / playerTime.sampleRate
    }

    var duration: Double { cachedDuration }

    // MARK: - PlayerItem

    struct PlayerItem {
        let url:    URL
        let title:  String
        let artist: String
        let album:  String
    }

    // MARK: - Init

    override private init() {
        fftSetup = vDSP_create_fftsetup(fftLog2n, FFTRadix(kFFTRadix2))
        super.init()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = volume
        try? engine.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    // MARK: - Waveform tap

    func startWaveformTap() {
        guard !waveformTapActive else { return }
        waveformTapActive = true
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 256, format: nil) { [weak self] buf, _ in
            guard let self else { return }
            // Fill ring buffer with new frames (wrapping)
            let frameCount = Int(buf.frameLength)
            guard let src = buf.floatChannelData?[0], frameCount > 0 else { return }
            for i in 0..<frameCount {
                self.ringBuffer[self.ringWritePos] = src[i]
                self.ringWritePos = (self.ringWritePos + 1) & (self.fftN - 1)
            }
            // Build contiguous 1024-sample window from ring buffer
            var window = [Float](repeating: 0, count: self.fftN)
            let tail = self.fftN - self.ringWritePos
            window.withUnsafeMutableBufferPointer { dst in
                self.ringBuffer.withUnsafeBufferPointer { src in
                    memcpy(dst.baseAddress!, src.baseAddress! + self.ringWritePos, tail * MemoryLayout<Float>.size)
                    memcpy(dst.baseAddress! + tail, src.baseAddress!, self.ringWritePos * MemoryLayout<Float>.size)
                }
            }
            let raw = self.analyzeBands(samples: window)
            // Asymmetric EMA: attack instant, decay smooth
            let decayα: Float = 0.5
            for i in 0..<self.smoothedBands.count {
                if raw[i] >= self.smoothedBands[i] {
                    self.smoothedBands[i] = raw[i]
                } else {
                    self.smoothedBands[i] = self.smoothedBands[i] * (1 - decayα) + raw[i] * decayα
                }
            }
            let bands = self.smoothedBands
            // Write only — no main-thread dispatch; WaveformStore polls at display rate
            self.bandsLock.lock()
            self._latestBands = bands
            self.bandsLock.unlock()
        }
    }

    func stopWaveformTap() {
        guard waveformTapActive else { return }
        waveformTapActive = false
        engine.mainMixerNode.removeTap(onBus: 0)
        smoothedBands = [Float](repeating: 0, count: 6)
        peakBands     = [Float](repeating: 1, count: 6)
        ringBuffer    = [Float](repeating: 0, count: fftN)
        ringWritePos  = 0
        bandsLock.lock()
        _latestBands = [Float](repeating: 0, count: 6)
        bandsLock.unlock()
    }

    // Runs on audio render thread — Accelerate FFT → 6 log-frequency bands
    // samples: contiguous 1024-point window (already linearised from ring buffer)
    private func analyzeBands(samples inputSamples: [Float]) -> [Float] {
        guard let setup = fftSetup else { return [Float](repeating: 0, count: 6) }

        let n = fftN, halfN = fftHalfN

        // Apply Hann window
        var samples = inputSamples
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(n))

        // Real FFT via split-complex
        let rPtr = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        let iPtr = UnsafeMutablePointer<Float>.allocate(capacity: halfN)
        defer { rPtr.deallocate(); iPtr.deallocate() }
        rPtr.initialize(repeating: 0, count: halfN)
        iPtr.initialize(repeating: 0, count: halfN)
        var split = DSPSplitComplex(realp: rPtr, imagp: iPtr)

        // Pack N real floats as N/2 complex (stride 1 = consecutive DSPComplex)
        samples.withUnsafeBytes { bytes in
            vDSP_ctoz(bytes.baseAddress!.assumingMemoryBound(to: DSPComplex.self),
                      1, &split, 1, vDSP_Length(halfN))
        }
        vDSP_fft_zrip(setup, &split, 1, fftLog2n, FFTDirection(FFT_FORWARD))

        // Amplitude spectrum
        var amps = [Float](repeating: 0, count: halfN)
        vDSP_zvabs(&split, 1, &amps, 1, vDSP_Length(halfN))

        // 6 log-spaced bands (44100 Hz, N=1024 → 43.07 Hz/bin)
        // [1–5] ~43–215 Hz  [6–23] ~258–989 Hz  [24–58] ~1–2.5 kHz
        // [59–93] ~2.5–4 kHz  [94–186] ~4–8 kHz  [187–511] ~8–22 kHz
        let bounds = [1, 6, 24, 59, 94, 187, halfN]
        var raw = [Float](repeating: 0, count: 6)
        for i in 0..<6 {
            let lo = bounds[i], hi = min(bounds[i + 1], halfN)
            guard lo < hi else { continue }
            var rms: Float = 0
            amps.withUnsafeBufferPointer {
                vDSP_rmsqv($0.baseAddress! + lo, 1, &rms, vDSP_Length(hi - lo))
            }
            raw[i] = rms
        }

        // Peak-tracking normalization: fast attack, slow decay → output always 0–1
        for i in 0..<6 {
            peakBands[i] = raw[i] > peakBands[i]
                ? peakBands[i] * 0.7 + raw[i] * 0.3
                : max(1, peakBands[i] * 0.997)
        }
        return zip(raw, peakBands).map { min(1, $0 / $1) }
    }

    @objc private func handleEngineConfigChange(_ notification: Notification) {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = volume
        do {
            try engine.start()
            if isPlaying { playerNode.play() }
        } catch {
            print("[AudioPlayer] 引擎重启失败: \(error)")
            isPlaying = false
            onStateChanged?()
        }
    }

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
        playerNode.stop()
        currentIndex    = index
        seekFrameOffset = 0
        playGeneration += 1
        let gen = playGeneration

        guard let file = try? AVAudioFile(forReading: queue[index].url) else {
            onStateChanged?()
            return
        }
        currentFile    = file
        cachedDuration = Double(file.length) / file.processingFormat.sampleRate

        scheduleRemaining(from: 0, generation: gen)
        startEngineIfNeeded()
        playerNode.play()
        isPlaying = true
        onStateChanged?()
    }

    private func scheduleRemaining(from frame: AVAudioFramePosition, generation gen: Int) {
        guard let file = currentFile else { return }
        let count = AVAudioFrameCount(max(0, file.length - frame))
        guard count > 0 else { return }
        file.framePosition = frame
        playerNode.scheduleSegment(
            file, startingFrame: frame, frameCount: count, at: nil
        ) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.playGeneration == gen else { return }
                self.handleTrackEnd()
            }
        }
    }

    private func handleTrackEnd() {
        guard isPlaying else { return }
        next()
    }

    func togglePlayPause() {
        if currentFile == nil, !queue.isEmpty { play(at: 0); return }
        if isPlaying {
            playerNode.pause()
        } else {
            startEngineIfNeeded()
            playerNode.play()
        }
        isPlaying.toggle()
        onStateChanged?()
    }

    func next() {
        guard !queue.isEmpty else { return }
        switch playMode {
        case .repeatOne:
            seek(to: 0)
        case .shuffle:
            shufflePosition = (shufflePosition + 1) % shuffleOrder.count
            play(at: shuffleOrder[shufflePosition])
        case .sequential:
            let next = currentIndex + 1
            if next < queue.count {
                play(at: next)
            } else {
                playGeneration += 1
                playerNode.stop()
                currentFile     = nil
                currentIndex    = 0
                seekFrameOffset = 0
                cachedDuration  = 0
                isPlaying       = false
                onStateChanged?()
            }
        }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 { seek(to: 0); return }
        switch playMode {
        case .repeatOne:
            seek(to: 0)
        case .shuffle:
            shufflePosition = max(0, shufflePosition - 1)
            play(at: shuffleOrder[shufflePosition])
        case .sequential:
            play(at: max(0, currentIndex - 1))
        }
    }

    func stop() {
        playGeneration += 1
        playerNode.stop()
        currentFile     = nil
        seekFrameOffset = 0
        cachedDuration  = 0
        isPlaying       = false
        onStateChanged?()
    }

    func seek(to time: Double) {
        guard let file = currentFile else { return }
        let sr    = file.processingFormat.sampleRate
        let frame = min(AVAudioFramePosition(max(0, time) * sr), file.length - 1)
        playGeneration += 1
        let gen = playGeneration
        seekFrameOffset = frame
        playerNode.stop()
        scheduleRemaining(from: frame, generation: gen)
        if isPlaying {
            startEngineIfNeeded()
            playerNode.play()
        }
    }

    func setVolume(_ v: Float) {
        volume = v
        engine.mainMixerNode.outputVolume = v
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

    // MARK: - Shuffle

    private func buildShuffleOrder(startAt index: Int) {
        var order = Array(0..<queue.count)
        order.removeAll { $0 == index }
        order.shuffle()
        order.insert(index, at: 0)
        shuffleOrder    = order
        shufflePosition = 0
    }

    func cyclePlayMode() {
        let all = PlayMode.allCases
        let idx = all.firstIndex(of: playMode)!
        playMode = all[(idx + 1) % all.count]
        if playMode == .shuffle { buildShuffleOrder(startAt: currentIndex) }
        onStateChanged?()
    }

    // MARK: - Helpers

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        try? engine.start()
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
                url:    url,
                title:  track.title,
                artist: track.artist?.name ?? L.unknownArtist,
                album:  track.album.title  ?? L.unknownAlbum
            )
        }
    }

    // 从磁盘/内存缓存的 PlaylistTrackItem 构建（不需要 ITLibrary）
    static func build(from cached: [PlaylistTrackItem], sortByTrack: Bool) -> [AudioPlayer.PlayerItem] {
        let sorted: [PlaylistTrackItem] = sortByTrack
            ? cached.sorted {
                if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                return $0.trackNumber < $1.trackNumber
              }
            : cached
        return sorted.compactMap { track in
            guard let url = track.url else { return nil }
            return AudioPlayer.PlayerItem(url: url, title: track.title, artist: track.artist, album: track.album)
        }
    }
}
