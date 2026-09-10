import SwiftUI
import AppKit
import QuartzCore

struct ContentView: View {
    @EnvironmentObject var music: MusicBridge
    @EnvironmentObject var theme: ThemeManager

    // Decoupled from MusicBridge so the AppKit header motion and SwiftUI list
    // motion can be committed in the same animation transaction.
    @State private var showsDrillTopPanel = false
    @State private var hasAppeared = false
    @State private var horizontalMotionBeginTime: CFTimeInterval = 0
    // SwiftUI interpolates this value with the macOS 14 smooth spring; the
    // resulting height is applied to the AppKit material panel each frame.
    @State private var topPanelHeight: CGFloat = 193
    // 保存最后一次展示的 drill 名称，退出动画期间继续渲染 drillView
    @State private var visibleDrillName: String? = nil
    private let mainHeaderHeight: CGFloat = 193
    private let drillHeaderHeight: CGFloat = 45
    private let panelHeight: CGFloat = 603
    private var displayedDrillName: String? {
        visibleDrillName ?? music.drillPlaylistName
    }

    var body: some View {
        let w: CGFloat = 270
        ZStack(alignment: .top) {
            Color.clear.background(.thinMaterial).ignoresSafeArea()

            animatedContentPanels
                .frame(width: w, height: panelHeight)

            animatedTopPanel
                // Animate the representable's real layout frame. AppKit then
                // follows these interpolated bounds on every SwiftUI frame.
                .frame(width: w, height: topPanelHeight, alignment: .top)
                .zIndex(2)
        }
        .frame(width: w)
        .clipped()
        .onAppear {
            // Restore drill state if this is the first presentation while a
            // playlist is already retained by MusicBridge.
            if let name = music.drillPlaylistName {
                visibleDrillName = name
                topPanelHeight = drillHeaderHeight
                showsDrillTopPanel = true
            }
            hasAppeared = true
            music.refreshStatus()
            music.fetchPlaylists()
        }
        .onChange(of: music.drillPlaylistName) { _, name in
            if let name {
                // Stage the destination root first. AnimatedContentPanels calls
                // back after AppKit has laid out and displayed it offscreen.
                visibleDrillName = name
            } else {
                // 退出：先动画，动画结束后清除内容和数据
                horizontalMotionBeginTime = CACurrentMediaTime() + 0.05
                showsDrillTopPanel = false
                withAnimation(.smooth(duration: 0.44).delay(0.025)) {
                    topPanelHeight = mainHeaderHeight
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                    // A new playlist may have been opened during the return
                    // animation. Never let the previous transition clear it.
                    guard music.drillPlaylistName == nil else { return }
                    visibleDrillName = nil
                    music.clearDrillData()
                    // Consume the one-shot centering request. This also lets the
                    // same playlist request centering again on its next opening.
                    music.playlistScrollID = nil
                }
            }
        }
    }

    // MARK: - Main view

    var mainView: some View {
        ZStack(alignment: .top) {
            // Preserve the original panel height while allowing the table to fill
            // the area underneath the floating controls.
            Color.clear
                .frame(height: panelHeight)

            playlistSection(topContentInset: mainHeaderHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var mainFixedHeader: some View {
        VStack(spacing: 0) {
            nowPlayingSection
            Divider()
            controlsSection
            volumeSection
            Divider()
            playlistHeader
        }
    }

    // MARK: - Drill view

    func drillView(playlistName: String) -> some View {
        ZStack(alignment: .top) {
            Color.clear
                .frame(height: panelHeight)

            drillSection(topContentInset: drillHeaderHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var animatedTopPanel: some View {
        AnimatedTopPanel(
            // Before onAppear, use the retained model state so reopening an
            // already-drilled popup starts at the correct header immediately.
            showsDrillHeader: hasAppeared
                ? showsDrillTopPanel
                : music.drillPlaylistName != nil,
            horizontalBeginTime: horizontalMotionBeginTime,
            drillContentID: displayedDrillName ?? "",
            expandedHeight: mainHeaderHeight,
            collapsedHeight: drillHeaderHeight,
            mainContent: AnyView(
                HostedContentObserver(music: music, theme: theme) {
                    AnyView(
                        mainFixedHeader
                            .environmentObject(music)
                            .environmentObject(theme)
                    )
                }
            ),
            drillContent: AnyView(
                Group {
                    if let name = displayedDrillName {
                        HostedContentObserver(music: music, theme: theme) {
                            AnyView(
                                VStack(spacing: 0) {
                                    drillHeader(playlistName: name)
                                }
                                .environmentObject(music)
                                .environmentObject(theme)
                            )
                        }
                    }
                }
            )
        )
    }

    private var animatedContentPanels: some View {
        AnimatedContentPanels(
            showsDrill: hasAppeared
                ? showsDrillTopPanel
                : music.drillPlaylistName != nil,
            horizontalBeginTime: horizontalMotionBeginTime,
            drillContentID: displayedDrillName ?? "",
            onDrillPrepared: { name in
                guard music.drillPlaylistName == name,
                      visibleDrillName == name,
                      !showsDrillTopPanel
                else { return }
                horizontalMotionBeginTime = CACurrentMediaTime() + 0.05
                showsDrillTopPanel = true
                withAnimation(.smooth(duration: 0.44).delay(0.025)) {
                    topPanelHeight = drillHeaderHeight
                }
            },
            mainContent: AnyView(
                HostedContentObserver(music: music, theme: theme) {
                    AnyView(
                        mainView
                            .environmentObject(music)
                            .environmentObject(theme)
                    )
                }
            ),
            drillContent: AnyView(
                Group {
                    if let name = displayedDrillName {
                        HostedContentObserver(music: music, theme: theme) {
                            AnyView(
                                drillView(playlistName: name)
                                    .environmentObject(music)
                                    .environmentObject(theme)
                            )
                        }
                    }
                }
            )
        )
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
                        .foregroundColor(theme.color.opacity(0.8))
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
                    size: 38, color: theme.color
                ) { music.togglePlayPause() }
                controlButton(icon: "forward.fill", size: 17) { music.nextTrack() }
            }
            Spacer()

            // 组2：播放模式（顺序/乱序/单曲循环）
            Button { music.cyclePlayMode() } label: {
                Image(systemName: music.playMode.icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(music.playMode == .sequential ? .secondary : theme.color)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(music.playMode == .sequential
                                  ? Color.clear
                                  : theme.color.opacity(0.12))
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
                    .foregroundColor(music.sortByTrackOrder ? .secondary : theme.color)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(music.sortByTrackOrder
                                  ? Color.clear
                                  : theme.color.opacity(0.12))
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
        ZStack {
            playlistHeaderIdleContent
                .opacity(music.isLoadingPlaylists ? 0 : 1)

            playlistHeaderLoadingContent
                .opacity(music.isLoadingPlaylists ? 1 : 0)
        }
        // Both states occupy the original single-row height. Progress is an
        // overlay inside this frame and can never expand the fixed top panel.
        .frame(height: 28)
        .clipped()
    }

    private var playlistHeaderIdleContent: some View {
        HStack(alignment: .center) {
            Image(systemName: "music.note.list")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(L.playlists)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)

            Spacer()

            let total = music.playlistGroups.reduce(0) { $0 + $1.playlists.count }
            if total > 0 {
                Text("\(total)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(height: 14)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
    }

    private var playlistHeaderLoadingContent: some View {
        HStack(alignment: .center, spacing: 7) {
            Image(systemName: "music.note.list")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(music.buildStatusText.isEmpty ? L.buildingCache : music.buildStatusText)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            ProgressView(value: music.buildProgress, total: 1.0)
                .progressViewStyle(.linear)
                .tint(theme.color)
                .scaleEffect(x: 1, y: 0.65, anchor: .center)
                .frame(maxWidth: .infinity)
                .animation(nil, value: music.buildProgress)

            Text(music.buildProgress > 0 ? "\(Int(music.buildProgress * 100))%" : "···")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 30, height: 14, alignment: .trailing)
                .animation(nil, value: music.buildProgress)
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
    }

    // MARK: - Playlist Section

    func playlistSection(topContentInset: CGFloat) -> some View {
        PlaylistNSTableView(
            items: music.flatPlaylistItems,
            currentPlaylistName: music.currentPlaylistName,
            isPlaying: music.isPlaying,
            themeColor: theme.color,
            artworkCacheRevision: music.artworkCacheRevision,
            scrollToName: music.playlistScrollID,
            topContentInset: topContentInset,
            onPlay: { music.playPlaylist(named: $0) },
            onDrill: {
                music.playlistScrollID = $0
                music.openPlaylistDetail(named: $0)
            },
            onToggleFolder: { folderName in
                music.toggleFolderCollapse(folderName)
            }
        )
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
                .foregroundColor(theme.color)
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

    @ViewBuilder
    private func drillSection(topContentInset: CGFloat) -> some View {
        if music.isLoadingDrill {
            HStack {
                Spacer()
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.7)
                    .padding(.vertical, 40)
                Spacer()
            }
            .padding(.top, topContentInset)
        } else {
            TrackNSTableView(
                tracks: music.sortedDrillTracks,
                currentTrackTitle:  music.currentTrack.name,
                currentTrackArtist: music.currentTrack.artist,
                isPlaying:       music.isPlaying,
                showTrackNumber: music.sortByTrackOrder,
                themeColor:      theme.color,
                artworkCacheRevision: music.artworkCacheRevision,
                topContentInset: topContentInset,
                onTap:       { music.playFromDrill(index: $0) },
                onSwipeBack: { music.closePlaylistDetail() }
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

// MARK: - Persistent hosting roots

/// NSHostingView keeps this root for the lifetime of a panel. The closure is
/// deliberately rebuilt when either observable object changes, so value-type
/// SwiftUI content never becomes a stale snapshot while the AppKit host and its
/// Core Animation layer remain stable.
private struct HostedContentObserver: View {
    @ObservedObject var music: MusicBridge
    @ObservedObject var theme: ThemeManager
    let build: () -> AnyView

    var body: some View {
        // Reading one value from each object makes the dependency explicit in
        // addition to @ObservedObject's normal objectWillChange subscription.
        let _ = music.isPlaying
        let _ = theme.theme
        build()
    }
}

// MARK: - AppKit animated top panel

private enum HorizontalPanelMotion {
    static let topDuration: TimeInterval = 0.26
    static let contentSpring = Spring(response: 0.26, dampingRatio: 1.1)
    static let contentDuration: TimeInterval = contentSpring.settlingDuration

    static let topSamples = samples(
        spring: .smooth(duration: topDuration),
        duration: topDuration
    )
    static let contentSamples = samples(
        spring: contentSpring,
        duration: contentDuration
    )

    private static func samples(spring: Spring, duration: TimeInterval) -> [NSNumber] {
        let sampleCount = max(2, Int(ceil(duration * 120)))
        return (0...sampleCount).map { index in
            if index == sampleCount { return NSNumber(value: 1.0) }
            let time = duration * Double(index) / Double(sampleCount)
            let value: Double = spring.value(
                target: 1.0,
                initialVelocity: 0.0,
                time: time
            )
            return NSNumber(value: value)
        }
    }

    static func set(_ host: NSView, x: CGFloat, key: String) {
        guard let layer = host.layer else { return }
        layer.removeAnimation(forKey: key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(x, forKeyPath: "transform.translation.x")
        CATransaction.commit()
    }

    static func animate(
        _ host: NSView,
        to target: CGFloat,
        samples: [NSNumber],
        duration: TimeInterval,
        beginTime: CFTimeInterval,
        key: String
    ) {
        guard let layer = host.layer else { return }
        let visibleLayer = layer.presentation() ?? layer
        let from = (visibleLayer.value(forKeyPath: "transform.translation.x") as? NSNumber)?
            .doubleValue ?? 0

        layer.removeAnimation(forKey: key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(target, forKeyPath: "transform.translation.x")
        CATransaction.commit()

        let distance = Double(target) - from
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = samples.map {
            NSNumber(value: from + $0.doubleValue * distance)
        }
        animation.duration = duration
        animation.calculationMode = .linear
        if beginTime > 0 {
            animation.beginTime = layer.convertTime(beginTime, from: nil)
            animation.fillMode = .backwards
        }
        layer.add(animation, forKey: key)
    }
}

private final class AnimatedContentPanelsView: NSView {
    override var isFlipped: Bool { true }

    let mainHost = NSHostingView(rootView: AnyView(EmptyView()))
    let drillHost = NSHostingView(rootView: AnyView(EmptyView()))
    var drillContentID = ""

    private var showsDrill = false
    private var hasConfiguredState = false
    private var transitionGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        for host in [mainHost, drillHost] {
            host.wantsLayer = true
            host.sizingOptions = []
            host.safeAreaRegions = []
            addSubview(host)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        mainHost.frame = bounds
        drillHost.frame = bounds
    }

    func prepareDrillContentOffscreen() {
        layoutSubtreeIfNeeded()
        let distance = bounds.width > 0 ? bounds.width : 270
        HorizontalPanelMotion.set(
            drillHost,
            x: distance,
            key: "contentHorizontalMotion"
        )
        let wasHidden = drillHost.isHidden
        drillHost.isHidden = false
        drillHost.layoutSubtreeIfNeeded()
        drillHost.displayIfNeeded()
        drillHost.isHidden = wasHidden
    }

    /// A hosted NSTableView can receive model updates while its panel is
    /// hidden. Its coordinator then contains the new state, but no cells were
    /// visible to reconfigure. Refresh only the rows that are about to become
    /// visible so selection/highlight state is current without rebuilding the
    /// table or disturbing its scroll position.
    private func refreshVisibleTableRows(in view: NSView) {
        if let tableView = view as? NSTableView {
            let range = tableView.rows(in: tableView.visibleRect)
            guard range.location != NSNotFound, range.length > 0 else { return }
            tableView.reloadData(
                forRowIndexes: IndexSet(integersIn: range.location..<(range.location + range.length)),
                columnIndexes: IndexSet(integer: 0)
            )
            return
        }
        for subview in view.subviews {
            refreshVisibleTableRows(in: subview)
        }
    }

    func configure(
        showsDrill: Bool,
        horizontalBeginTime: CFTimeInterval,
        animated: Bool
    ) {
        layoutSubtreeIfNeeded()
        let distance = bounds.width > 0 ? bounds.width : 270

        if !hasConfiguredState {
            hasConfiguredState = true
            self.showsDrill = showsDrill
            mainHost.isHidden = showsDrill
            drillHost.isHidden = !showsDrill
            HorizontalPanelMotion.set(
                mainHost,
                x: showsDrill ? -distance : 0,
                key: "contentHorizontalMotion"
            )
            HorizontalPanelMotion.set(
                drillHost,
                x: showsDrill ? 0 : distance,
                key: "contentHorizontalMotion"
            )
            return
        }

        guard self.showsDrill != showsDrill else { return }
        self.showsDrill = showsDrill
        transitionGeneration += 1
        let generation = transitionGeneration
        let outgoing = showsDrill ? mainHost : drillHost
        let incoming = showsDrill ? drillHost : mainHost

        outgoing.isHidden = false
        incoming.isHidden = false
        incoming.removeFromSuperview()
        addSubview(incoming, positioned: .above, relativeTo: outgoing)
        // Commit the destination SwiftUI/AppKit table before its layer starts
        // moving. In particular, this creates the first visible NSTableView rows
        // while the host is still outside the clipped viewport.
        incoming.layoutSubtreeIfNeeded()
        refreshVisibleTableRows(in: incoming)
        incoming.displayIfNeeded()

        let outgoingTarget = showsDrill ? -distance : distance
        guard animated else {
            HorizontalPanelMotion.set(
                outgoing,
                x: outgoingTarget,
                key: "contentHorizontalMotion"
            )
            HorizontalPanelMotion.set(
                incoming,
                x: 0,
                key: "contentHorizontalMotion"
            )
            outgoing.isHidden = true
            return
        }

        HorizontalPanelMotion.animate(
            outgoing,
            to: outgoingTarget,
            samples: HorizontalPanelMotion.contentSamples,
            duration: HorizontalPanelMotion.contentDuration,
            beginTime: horizontalBeginTime,
            key: "contentHorizontalMotion"
        )
        HorizontalPanelMotion.animate(
            incoming,
            to: 0,
            samples: HorizontalPanelMotion.contentSamples,
            duration: HorizontalPanelMotion.contentDuration,
            beginTime: horizontalBeginTime,
            key: "contentHorizontalMotion"
        )

        let wait = max(0, horizontalBeginTime - CACurrentMediaTime())
            + HorizontalPanelMotion.contentDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak outgoing] in
            guard let self,
                  self.transitionGeneration == generation,
                  let outgoing
            else { return }
            outgoing.isHidden = true
        }
    }
}

private struct AnimatedContentPanels: NSViewRepresentable {
    let showsDrill: Bool
    let horizontalBeginTime: CFTimeInterval
    let drillContentID: String
    let onDrillPrepared: (String) -> Void
    let mainContent: AnyView
    let drillContent: AnyView

    func makeNSView(context: Context) -> AnimatedContentPanelsView {
        let view = AnimatedContentPanelsView()
        view.mainHost.rootView = mainContent
        view.drillHost.rootView = drillContent
        view.drillContentID = drillContentID
        view.configure(
            showsDrill: showsDrill,
            horizontalBeginTime: horizontalBeginTime,
            animated: false
        )
        return view
    }

    func updateNSView(_ view: AnimatedContentPanelsView, context: Context) {
        // The main root observes MusicBridge and ThemeManager directly. Replace
        // only the drill root when its playlist identity changes, avoiding a
        // full hosted-tree reset during the height animation.
        var preparedID: String?
        if view.drillContentID != drillContentID {
            view.drillContentID = drillContentID
            view.drillHost.rootView = drillContent
            if !drillContentID.isEmpty, !showsDrill {
                preparedID = drillContentID
            }
        }
        view.configure(
            showsDrill: showsDrill,
            horizontalBeginTime: horizontalBeginTime,
            // A non-zero begin time is emitted only by an actual navigation
            // action. `view.window` is transiently nil while NSPopover rebuilds
            // its controller and must not decide whether that action animates.
            animated: horizontalBeginTime > 0
        )
        if let preparedID {
            view.prepareDrillContentOffscreen()
            // State changes during updateNSView are invalid. Dispatch only the
            // ready signal; the destination itself is already fully committed.
            DispatchQueue.main.async {
                onDrillPrepared(preparedID)
            }
        }
    }
}

private final class TopPanelEffectView: NSVisualEffectView {
    override var isFlipped: Bool { true }

    let bottomSeparator: NSBox = {
        let separator = NSBox()
        separator.boxType = .separator
        separator.autoresizingMask = [.width, .minYMargin]
        return separator
    }()

    override func layout() {
        super.layout()
        bottomSeparator.frame = NSRect(
            x: 0,
            y: max(0, bounds.height - 1),
            width: bounds.width,
            height: 1
        )
    }
}

private final class AnimatedTopPanelView: NSView {
    override var isFlipped: Bool { true }

    let effectView = TopPanelEffectView()
    let mainHost = NSHostingView(rootView: AnyView(EmptyView()))
    let drillHost = NSHostingView(rootView: AnyView(EmptyView()))
    var drillContentID = ""

    private var expandedHeight: CGFloat = 193
    private var collapsedHeight: CGFloat = 45
    private var showsDrillHeader = false
    private var hasConfiguredState = false
    private var transitionGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        effectView.blendingMode = .withinWindow
        effectView.material = .popover
        effectView.state = .active
        effectView.isEmphasized = true
        effectView.wantsLayer = true
        effectView.layer?.masksToBounds = true
        mainHost.wantsLayer = true
        drillHost.wantsLayer = true

        mainHost.alphaValue = 1
        drillHost.alphaValue = 0
        effectView.addSubview(mainHost)
        effectView.addSubview(drillHost)
        // Keep the border independent from both fading content layers.
        effectView.addSubview(effectView.bottomSeparator, positioned: .above, relativeTo: nil)
        addSubview(effectView)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let clicks outside the currently visible material reach the track list.
        guard effectView.frame.contains(point) else { return nil }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        // SwiftUI animates this representable's bounds with `.smooth`; keep the
        // AppKit material view locked to those live bounds.
        effectView.frame = bounds
        mainHost.frame = NSRect(x: 0, y: 0, width: bounds.width, height: expandedHeight)
        drillHost.frame = NSRect(x: 0, y: 0, width: bounds.width, height: collapsedHeight)
    }

    func configure(
        expandedHeight: CGFloat,
        collapsedHeight: CGFloat,
        showsDrillHeader: Bool,
        horizontalBeginTime: CFTimeInterval,
        animated: Bool
    ) {
        self.expandedHeight = expandedHeight
        self.collapsedHeight = collapsedHeight
        layoutSubtreeIfNeeded()

        if !hasConfiguredState {
            hasConfiguredState = true
            self.showsDrillHeader = showsDrillHeader
            mainHost.alphaValue = showsDrillHeader ? 0 : 1
            mainHost.isHidden = showsDrillHeader
            drillHost.alphaValue = showsDrillHeader ? 1 : 0
            drillHost.isHidden = !showsDrillHeader
            let distance = bounds.width > 0 ? bounds.width : 270
            HorizontalPanelMotion.set(
                mainHost,
                x: showsDrillHeader ? -distance : 0,
                key: "topPanelHorizontalMotion"
            )
            HorizontalPanelMotion.set(
                drillHost,
                x: showsDrillHeader ? 0 : distance,
                key: "topPanelHorizontalMotion"
            )
            needsLayout = true
            return
        }

        guard self.showsDrillHeader != showsDrillHeader else { return }

        self.showsDrillHeader = showsDrillHeader
        transitionGeneration += 1
        let generation = transitionGeneration
        let outgoing = showsDrillHeader ? mainHost : drillHost
        let incoming = showsDrillHeader ? drillHost : mainHost

        outgoing.isHidden = false
        incoming.isHidden = false
        // Put the incoming content above the outgoing content for reliable hit
        // testing while both layers overlap during the crossfade.
        incoming.removeFromSuperview()
        effectView.addSubview(
            incoming,
            positioned: .below,
            relativeTo: effectView.bottomSeparator
        )
        incoming.layoutSubtreeIfNeeded()
        incoming.displayIfNeeded()
        incoming.alphaValue = 0
        guard animated else {
            outgoing.alphaValue = 0
            outgoing.isHidden = true
            incoming.alphaValue = 1
            let distance = bounds.width > 0 ? bounds.width : 270
            HorizontalPanelMotion.set(
                outgoing,
                x: showsDrillHeader ? -distance : distance,
                key: "topPanelHorizontalMotion"
            )
            HorizontalPanelMotion.set(
                incoming,
                x: 0,
                key: "topPanelHorizontalMotion"
            )
            return
        }

        // Run the macOS 14 `smooth` curve entirely on the hosting layers. The
        // sampled keyframes are composited without publishing per-frame SwiftUI
        // state or recomputing either header's body.
        let distance = bounds.width > 0 ? bounds.width : 270
        HorizontalPanelMotion.animate(
            outgoing,
            to: showsDrillHeader ? -distance : distance,
            samples: HorizontalPanelMotion.topSamples,
            duration: HorizontalPanelMotion.topDuration,
            beginTime: horizontalBeginTime,
            key: "topPanelHorizontalMotion"
        )
        HorizontalPanelMotion.animate(
            incoming,
            to: 0,
            samples: HorizontalPanelMotion.topSamples,
            duration: HorizontalPanelMotion.topDuration,
            beginTime: horizontalBeginTime,
            key: "topPanelHorizontalMotion"
        )

        // Fade the old content from the instant the transition starts.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.48
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            outgoing.animator().alphaValue = 0
        } completionHandler: { [weak self, weak outgoing] in
            guard let self,
                  self.transitionGeneration == generation,
                  let outgoing
            else { return }
            outgoing.isHidden = true
        }

        // Start revealing the new content 0.30 seconds before the old content
        // finishes. It deliberately completes after the geometry transitions.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self, weak incoming] in
            guard let self,
                  self.transitionGeneration == generation,
                  let incoming
            else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.48
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                incoming.animator().alphaValue = 1
            }
        }
    }
}

private struct AnimatedTopPanel: NSViewRepresentable {
    let showsDrillHeader: Bool
    let horizontalBeginTime: CFTimeInterval
    let drillContentID: String
    let expandedHeight: CGFloat
    let collapsedHeight: CGFloat
    let mainContent: AnyView
    let drillContent: AnyView

    func makeNSView(context: Context) -> AnimatedTopPanelView {
        let view = AnimatedTopPanelView()
        view.mainHost.rootView = mainContent
        view.drillHost.rootView = drillContent
        view.drillContentID = drillContentID
        view.configure(
            expandedHeight: expandedHeight,
            collapsedHeight: collapsedHeight,
            showsDrillHeader: showsDrillHeader,
            horizontalBeginTime: horizontalBeginTime,
            animated: false
        )
        return view
    }

    func updateNSView(_ view: AnimatedTopPanelView, context: Context) {
        // Both roots observe the shared environment objects. Keep them alive
        // during the height animation, and replace only playlist-specific
        // header content when its identity actually changes.
        if view.drillContentID != drillContentID {
            view.drillContentID = drillContentID
            view.drillHost.rootView = drillContent
        }
        view.configure(
            expandedHeight: expandedHeight,
            collapsedHeight: collapsedHeight,
            showsDrillHeader: showsDrillHeader,
            horizontalBeginTime: horizontalBeginTime,
            animated: horizontalBeginTime > 0
        )
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
                fillColor: NSColor(theme.color),
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
                    .animation(nil, value: store.bands)
            }
        }
        .frame(width: 6 * barW + 5 * gap, height: maxH, alignment: .center)
        .onAppear { liveIsPlaying = isPlaying }
        .onChange(of: isPlaying) { _, newVal in
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
