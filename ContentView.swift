import SwiftUI

struct ContentView: View {
    @EnvironmentObject var music: MusicBridge
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        VStack(spacing: 0) {
            if let playlistName = music.drillPlaylistName {
                // MARK: Drill-down view
                drillHeader(playlistName: playlistName)
                Divider()
                drillSection
            } else {
                // MARK: Main view
                nowPlayingSection
                Divider()
                controlsSection
                volumeSection
                Divider()
                playlistHeader
                Divider()
                playlistSection
            }
        }
        .frame(width: 270)
        .onAppear {
            music.refreshStatus()
            music.fetchPlaylists()
        }
    }

    // MARK: - Now Playing

    var nowPlayingSection: some View {
        HStack(spacing: 10) {
            if let img = music.currentArtwork {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Image(systemName: "music.note")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(music.currentTrack.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(music.currentTrack.artist)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if !music.currentPlaylistName.isEmpty {
                    Text(music.currentPlaylistName)
                        .font(.system(size: 10))
                        .foregroundColor(theme.theme.color.opacity(0.8))
                        .lineLimit(1)
                } else {
                    Text(music.currentTrack.album)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if music.showWaveform {
                WaveformBarsView(store: music.waveformStore, isPlaying: music.isPlaying)
            } else {
                Circle()
                    .fill(music.isPlaying ? Color.green : Color.gray.opacity(0.4))
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Controls（三组：播放控制 | 播放模式 | 排序方式）

    var controlsSection: some View {
        HStack(spacing: 0) {
            // 组1：播放控制
            Spacer()
            HStack(spacing: 8) {
                controlButton(icon: "backward.fill", size: 17) { music.previousTrack() }
                controlButton(
                    icon: music.isPlaying ? "pause.circle.fill" : "play.circle.fill",
                    size: 38, color: theme.theme.color
                ) { music.togglePlayPause() }
                controlButton(icon: "forward.fill", size: 17) { music.nextTrack() }
            }
            Spacer()

            // 组2：播放模式（顺序/乱序/单曲循环）
            Button { music.cyclePlayMode() } label: {
                Image(systemName: music.playMode.icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(music.playMode == .sequential ? .secondary : theme.theme.color)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(music.playMode == .sequential
                                  ? Color.clear
                                  : theme.theme.color.opacity(0.12))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()

            // 组3：排序方式
            // list.number = 按轨道号排序（默认，无高亮）
            // list.dash   = 关闭轨道号排序（特殊状态，高亮提示）
            Button { music.toggleSortOrder() } label: {
                Image(systemName: music.sortByTrackOrder ? "list.number" : "list.dash")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(music.sortByTrackOrder ? .secondary : theme.theme.color)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(music.sortByTrackOrder
                                  ? Color.clear
                                  : theme.theme.color.opacity(0.12))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(music.sortByTrackOrder ? L.sortOnTooltip : L.sortOffTooltip)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
    }

    // MARK: - Volume

    var volumeSection: some View {
        // ObservedObject directly on AudioPlayer so volume text re-renders on drag
        VolumeView()
    }

    // MARK: - Playlist Header

    var playlistHeader: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(L.playlists)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)

                Spacer()

                if music.isLoadingPlaylists {
                    Text(music.buildProgress > 0 ? "\(Int(music.buildProgress * 100))%" : "···")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(height: 14)
                        .animation(nil, value: music.buildProgress)
                } else {
                    let total = music.playlistGroups.reduce(0) { $0 + $1.playlists.count }
                    if total > 0 {
                        Text("\(total)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(height: 14)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 7)
            .padding(.bottom, music.isLoadingPlaylists ? 4 : 7)

            if music.isLoadingPlaylists {
                VStack(alignment: .leading, spacing: 2) {
                    if !music.buildStatusText.isEmpty {
                        Text(music.buildStatusText)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    ProgressView(value: music.buildProgress, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(theme.theme.color)
                        .scaleEffect(x: 1, y: 0.8, anchor: .center)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: - Playlist Section

    var playlistSection: some View {
        PlaylistNSTableView(
            items: music.flatPlaylistItems,
            currentPlaylistName: music.currentPlaylistName,
            isPlaying: music.isPlaying,
            themeColor: theme.theme.color,
            scrollToName: music.playlistScrollID,
            onPlay: { music.playPlaylist(named: $0) },
            onDrill: {
                music.playlistScrollID = $0
                music.openPlaylistDetail(named: $0)
            },
            onToggleFolder: { folderName in
                withAnimation(.easeInOut(duration: 0.18)) {
                    music.toggleFolderCollapse(folderName)
                }
            }
        )
        .frame(height: 410)
    }

    // MARK: - Drill-down Header

    func drillHeader(playlistName: String) -> some View {
        let repKey = music.playlistGroups
            .flatMap { $0.playlists }
            .first { $0.name == playlistName }?
            .representativeTrackKey ?? ""
        let backButton = Button {
            music.closePlaylistDetail()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.theme.color)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        let artworkView = Group {
            if let img = TrackArtworkCache.shared.image(forKey: repKey) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: 28, height: 28)
                    Image(systemName: "music.note.list")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
        }

        let countView = ZStack(alignment: .trailing) {
            if music.isLoadingDrill {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.4)
                    .frame(width: 30, height: 14, alignment: .trailing)
            } else {
                Text("\(music.drillTracks.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(height: 14)
            }
        }

        return ZStack {
            HStack(spacing: 6) {
                artworkView
                Text(playlistName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            HStack {
                backButton
                    .offset(x: -6)
                Spacer()
                countView
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Drill-down Track List

    var drillSection: some View {
        drillContent.frame(height: 558)
    }

    @ViewBuilder
    private var drillContent: some View {
        if music.isLoadingDrill {
            HStack {
                Spacer()
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.7)
                    .padding(.vertical, 40)
                Spacer()
            }
        } else {
            TrackNSTableView(
                tracks: music.sortedDrillTracks,
                currentTrackTitle:  music.currentTrack.name,
                currentTrackArtist: music.currentTrack.artist,
                isPlaying:       music.isPlaying,
                showTrackNumber: music.sortByTrackOrder,
                themeColor:      theme.theme.color,
                onTap: { music.playFromDrill(index: $0) }
            )
        }
    }

    // MARK: - Helpers

    private func isCurrentDrillTrack(_ track: PlaylistTrackItem) -> Bool {
        music.currentTrack.name == track.title && music.currentTrack.artist == track.artist
    }



    // MARK: - Control Button Helper

    @ViewBuilder
    func controlButton(icon: String, size: CGFloat, color: Color = .primary,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size))
                .foregroundColor(color)
                .frame(width: size + 16, height: size + 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - VolumeView
// Reads volume from MusicBridge (an @EnvironmentObject on the parent view).
// No longer observes AudioPlayer directly — eliminates a Combine subscription
// that was active even when the popover was closed.

struct VolumeView: View {
    @EnvironmentObject var music: MusicBridge
    @EnvironmentObject var theme: ThemeManager
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            VolumeSliderControl(
                value: Binding(
                    get: { Double(music.volume) },
                    set: { music.setVolume(Float($0)) }
                ),
                fillColor: NSColor(theme.theme.color),
                isDark: colorScheme == .dark
            )
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text("\(Int(music.volume * 100))%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }
}
// MARK: - FolderHeaderRowView

struct FolderHeaderRowView: View {
    let group: PlaylistGroup
    let collapsed: Bool
    let themeColor: Color
    let onTap: () -> Void

    var body: some View {
        let indent: CGFloat = 14 + CGFloat(max(0, group.indentLevel - 1)) * 12
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.7))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .animation(.easeInOut(duration: 0.18), value: collapsed)
                    .frame(width: 12)
                if let img = TrackArtworkCache.shared.image(forKey: group.representativeTrackKey ?? "") {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 14, height: 14)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Text(group.folderName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.leading, indent)
            .padding(.trailing, 14)
            .padding(.top, 6)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: 26)
    }
}

// MARK: - PlaylistItemRowView

struct PlaylistItemRowView: View {
    let group: PlaylistGroup
    let pl: PlaylistInfo
    let isActive: Bool
    let isPlaying: Bool
    let themeColor: Color
    let onPlay:  () -> Void
    let onDrill: () -> Void

    var body: some View {
        let leadingPad: CGFloat = group.isFolder
            ? 14 + CGFloat(max(0, group.indentLevel - 1)) * 12 + 20
            : 14
        let dividerPad: CGFloat = group.isFolder
            ? 14 + CGFloat(max(0, group.indentLevel - 1)) * 12 + 56
            : 50

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: onPlay) {
                    HStack(spacing: 8) {
                        if let cg = TrackArtworkCache.shared.cgImage(forKey: pl.representativeTrackKey ?? "") {
                            Image(decorative: cg, scale: 2.0)
                                .frame(width: 28, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(isActive ? Color.white.opacity(0.25) : Color.secondary.opacity(0.12))
                                    .frame(width: 28, height: 28)
                                Image(systemName: pl.kind.icon)
                                    .font(.system(size: 12))
                                    .foregroundColor(isActive ? .white : .secondary)
                            }
                        }
                        Text(pl.name)
                            .font(.system(size: 12))
                            .foregroundColor(isActive ? .white : .primary)
                            .lineLimit(1)
                        Spacer()
                        if isActive && isPlaying {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.9))
                        } else {
                            Text("\(pl.trackCount)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(isActive ? .white.opacity(0.8) : .secondary)
                        }
                    }
                    .padding(.leading, leadingPad)
                    .padding(.trailing, 4)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onDrill) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isActive ? .white.opacity(0.7) : .secondary.opacity(0.6))
                        .frame(width: 24, height: 38)
                        .padding(.trailing, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? themeColor.opacity(0.85) : Color.clear)

            Divider().padding(.leading, dividerPad)
        }
        .id(pl.name)
    }
}

// MARK: - TrackRowView
// 独立 struct：props 不变时 SwiftUI 跳过 body 重算，LazyVStack 下只有可见行参与渲染

struct TrackRowView: View {
    let track: PlaylistTrackItem
    let index: Int
    let isCurrent: Bool
    let isPlaying: Bool
    let showTrackNumber: Bool
    let themeColor: Color
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 8) {

                    // 封面（56px@scale:2 = 28pt，零缩放，CGImage 直通 GPU 无 NSImage 转换开销）
                    if let cg = TrackArtworkCache.shared.cgImage(for: track) {
                        Image(decorative: cg, scale: 2.0)
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .opacity(isCurrent ? 0.88 : 1.0)
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isCurrent ? Color.white.opacity(0.15) : Color.secondary.opacity(0.12))
                                .frame(width: 28, height: 28)
                            Image(systemName: "music.note")
                                .font(.system(size: 11))
                                .foregroundColor(isCurrent ? .white.opacity(0.6) : .secondary)
                        }
                    }

                    // 标题 + 艺术家
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(track.title)
                                .font(.system(size: 12))
                                .foregroundColor(isCurrent ? .white : .primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if isCurrent && isPlaying {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.white.opacity(0.9))
                                    .fixedSize()
                            }
                        }
                        Text(track.artist)
                            .font(.system(size: 10))
                            .foregroundColor(isCurrent ? .white.opacity(0.75) : .secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // 编号右对齐
                    if showTrackNumber && track.trackNumber > 0 {
                        Text(track.discNumber > 1
                             ? "\(track.discNumber)-\(track.trackNumber)"
                             : "\(track.trackNumber)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(isCurrent ? .white.opacity(0.6) : .secondary)
                            .frame(width: 28, alignment: .trailing)
                    } else {
                        Text("\(index + 1)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(isCurrent ? .white.opacity(0.6) : .secondary.opacity(0.5))
                            .frame(width: 28, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(isCurrent ? themeColor.opacity(0.85) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(height: 38)

            Divider().padding(.leading, 56)
        }
    }
}

// MARK: - WaveformBarsView

struct WaveformBarsView: View {
    @ObservedObject var store: WaveformStore
    let isPlaying: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var liveIsPlaying: Bool = false

    private let barW: CGFloat = 2
    private let gap:  CGFloat = 2
    private let maxH: CGFloat = 14
    private let minH: CGFloat = 3

    private var barColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.55) : Color.primary.opacity(0.45)
    }

    var body: some View {
        HStack(spacing: gap) {
            ForEach(0..<6, id: \.self) { i in
                let val = i < store.bands.count ? CGFloat(store.bands[i]) : 0
                let h   = liveIsPlaying ? minH + val * (maxH - minH) : minH
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor)
                    .frame(width: barW, height: h)
            }
        }
        .frame(width: 6 * barW + 5 * gap, height: maxH, alignment: .center)
        .onAppear { liveIsPlaying = isPlaying }
        .onChange(of: isPlaying) { newVal in
            if newVal {
                withAnimation(.easeOut(duration: 0.2)) {
                    liveIsPlaying = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.8)) {
                    liveIsPlaying = false
                }
            }
        }
    }
}

// MARK: - VolumeSliderControl
// NSViewRepresentable wrapping NSSlider with a custom NSSliderCell so we can
// control the track background color separately in light and dark mode.

private final class CustomSliderCell: NSSliderCell {
    var fillColor: NSColor = .systemBlue
    var isDark: Bool = false

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let trackH: CGFloat = 3
        let r = NSRect(x: rect.minX,
                       y: rect.midY - trackH / 2,
                       width: rect.width,
                       height: trackH)
        let radius = trackH / 2

        // Track background — slightly darker in light mode, slightly lighter in dark mode
        let bgColor: NSColor = isDark
            ? .white.withAlphaComponent(0.22)
            : .black.withAlphaComponent(0.14)
        bgColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()

        // Filled portion
        let ratio = CGFloat((doubleValue - minValue) / (maxValue - minValue))
        let filledW = r.width * ratio
        guard filledW > 0 else { return }
        let filledRect = NSRect(x: r.minX, y: r.minY, width: filledW, height: r.height)
        fillColor.setFill()
        NSBezierPath(roundedRect: filledRect, xRadius: radius, yRadius: radius).fill()
    }
}

struct VolumeSliderControl: NSViewRepresentable {
    @Binding var value: Double
    var fillColor: NSColor
    var isDark: Bool

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider()
        slider.cell = CustomSliderCell()
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = value
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.valueChanged(_:))
        applyCell(slider)
        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        if nsView.doubleValue != value { nsView.doubleValue = value }
        applyCell(nsView)
        nsView.needsDisplay = true
    }

    private func applyCell(_ slider: NSSlider) {
        guard let cell = slider.cell as? CustomSliderCell else { return }
        cell.fillColor = fillColor
        cell.isDark    = isDark
    }

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }
        @objc func valueChanged(_ sender: NSSlider) { value.wrappedValue = sender.doubleValue }
    }
}
