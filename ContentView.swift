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
                        .fill(theme.theme.color.opacity(0.15))
                        .frame(width: 48, height: 48)
                    Image(systemName: music.isPlaying ? "music.note" : "music.note.list")
                        .font(.system(size: 20))
                        .foregroundColor(.pink)
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
            Circle()
                .fill(music.isPlaying ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 7, height: 7)
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
        HStack(alignment: .center) {
            Image(systemName: "music.note.list")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(L.playlists)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()

            ZStack(alignment: .trailing) {
                if music.isLoadingPlaylists {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.4)
                        .frame(width: 30, height: 14, alignment: .trailing)
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    // MARK: - Playlist Section

    var playlistSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(music.playlistGroups) { group in
                    if group.isFolder && !music.isGroupHidden(group) {
                        let baseIndent: CGFloat = 14 + CGFloat(max(0, group.indentLevel - 1)) * 12
                        let collapsed = music.isFolderCollapsed(group.folderName)

                        // Folder header row with collapse chevron
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                music.toggleFolderCollapse(group.folderName)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.secondary.opacity(0.7))
                                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                                    .animation(.easeInOut(duration: 0.18), value: collapsed)
                                    .frame(width: 12)
                                if let img = group.folderArtwork {
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
                            .padding(.leading, baseIndent)
                            .padding(.trailing, 14)
                            .padding(.top, 6)
                            .padding(.bottom, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(height: 26)  // fixed height prevents scroll jitter
                    }

                    // Playlist rows — hidden when folder is collapsed
                    if !music.isGroupHidden(group) && (!group.isFolder || !music.isFolderCollapsed(group.folderName)) {
                        ForEach(group.playlists) { pl in
                            Group {
                                let isActive = pl.name == music.currentPlaylistName
                                HStack(spacing: 0) {
                                    Button {
                                        music.playPlaylist(named: pl.name)
                                    } label: {
                                        HStack(spacing: 8) {
                                            if let img = pl.artworkImage {
                                                Image(nsImage: img)
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fill)
                                                    .frame(width: 28, height: 28)
                                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                            } else {
                                                ZStack {
                                                    RoundedRectangle(cornerRadius: 4)
                                                        .fill(isActive ? Color.white.opacity(0.25) : Color.pink.opacity(0.12))
                                                        .frame(width: 28, height: 28)
                                                    Image(systemName: pl.kind.icon)
                                                        .font(.system(size: 12))
                                                        .foregroundColor(isActive ? .white : .pink)
                                                }
                                            }
                                            Text(pl.name)
                                                .font(.system(size: 12))
                                                .foregroundColor(isActive ? .white : .primary)
                                                .lineLimit(1)
                                            Spacer()
                                            if isActive && music.isPlaying {
                                                Image(systemName: "speaker.wave.2.fill")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(.white.opacity(0.9))
                                            } else {
                                                Text("\(pl.trackCount)")
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundColor(isActive ? .white.opacity(0.8) : .secondary)
                                            }
                                        }
                                        .padding(.leading, group.isFolder ? 14 + CGFloat(max(0, group.indentLevel - 1)) * 12 + 20 : 14)
                                        .padding(.trailing, 4)
                                        .padding(.vertical, 5)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        music.openPlaylistDetail(named: pl.name)
                                    } label: {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(isActive ? .white.opacity(0.7) : .secondary.opacity(0.6))
                                            .frame(width: 20, height: 38)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                                .frame(width: 256, alignment: .leading)
                                .background(isActive ? theme.theme.color.opacity(0.85) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }

                            Divider().padding(.leading, group.isFolder ? 14 + CGFloat(max(0, group.indentLevel - 1)) * 12 + 56 : 50)
                        }
                    }
                }
            }
        }
        .frame(height: 410)
    }

    // MARK: - Drill-down Header

    func drillHeader(playlistName: String) -> some View {
        let artwork: NSImage? = music.playlistGroups
            .flatMap { $0.playlists }
            .first { $0.name == playlistName }?
            .artworkImage
        return HStack(spacing: 8) {
            Button {
                music.closePlaylistDetail()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.theme.color)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Artwork thumbnail
            if let img = artwork {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(theme.theme.color.opacity(0.12))
                        .frame(width: 28, height: 28)
                    Image(systemName: "music.note.list")
                        .font(.system(size: 12))
                        .foregroundColor(.pink)
                }
            }

            Text(playlistName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Spacer()

            ZStack(alignment: .trailing) {
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Drill-down Track List

    var drillSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
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
                    let tracks = music.sortedDrillTracks
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                        Button {
                            music.playFromDrill(index: idx)
                        } label: {
                            HStack(spacing: 8) {
                                // 轨道号
                                if music.sortByTrackOrder && track.trackNumber > 0 {
                                    Text(track.discNumber > 1
                                         ? "\(track.discNumber)-\(track.trackNumber)"
                                         : "\(track.trackNumber)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(isCurrentDrillTrack(track) ? .white.opacity(0.6) : .secondary)
                                        .frame(width: 26, alignment: .trailing)
                                } else {
                                    Text("\(idx + 1)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(isCurrentDrillTrack(track) ? .white.opacity(0.6) : .secondary.opacity(0.5))
                                        .frame(width: 26, alignment: .trailing)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(track.title)
                                            .font(.system(size: 12))
                                            .foregroundColor(
                                                isCurrentDrillTrack(track) ? .white : .primary
                                            )
                                            .lineLimit(1)
                                        if isCurrentDrillTrack(track) && music.isPlaying {
                                            Image(systemName: "speaker.wave.2.fill")
                                                .font(.system(size: 9))
                                                .foregroundColor(.white.opacity(0.9))
                                        }
                                    }
                                    Text(track.artist)
                                        .font(.system(size: 10))
                                        .foregroundColor(isCurrentDrillTrack(track) ? .white.opacity(0.75) : .secondary)
                                        .lineLimit(1)
                                }

                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .background(
                                isCurrentDrillTrack(track)
                                    ? theme.theme.color.opacity(0.85) : Color.clear
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider().padding(.leading, 48)
                    }
                }
            }
        }
        // Same fixed height as playlist section to keep popover stable
        .frame(height: 554)
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

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Slider(
                value: Binding(
                    get: { Double(music.volume) },
                    set: { music.setVolume(Float($0)) }
                ),
                in: 0...1
            )
            .controlSize(.small)
            .tint(theme.theme.color)
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
