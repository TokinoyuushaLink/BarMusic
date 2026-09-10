import SwiftUI
import AppKit

private extension NSColor {
    /// CALayer stores a concrete CGColor, so resolve semantic AppKit colors
    /// against the owning view's current appearance before assigning them.
    func cgColor(resolvedFor appearance: NSAppearance) -> CGColor {
        var result = NSColor.clear.cgColor
        appearance.performAsCurrentDrawingAppearance {
            result = self.cgColor
        }
        return result
    }
}

private extension NSView {
    /// Recycled table cells can be configured while detached, when their own
    /// effectiveAppearance still falls back to Aqua. Prefer inherited/window
    /// appearance so layer colors never flash back to their light-mode value.
    var layerColorAppearance: NSAppearance {
        window?.effectiveAppearance
            ?? superview?.effectiveAppearance
            ?? NSApp.effectiveAppearance
    }

    /// Fetch the semantic color *inside* the appearance scope. Fetching
    /// secondaryLabelColor before entering this scope can leave recycled
    /// chevrons with the color resolved for the previous appearance.
    func secondaryLabelCGColor(alpha: CGFloat) -> CGColor {
        var result = NSColor.clear.cgColor
        layerColorAppearance.performAsCurrentDrawingAppearance {
            result = NSColor.secondaryLabelColor
                .withAlphaComponent(alpha)
                .cgColor
        }
        return result
    }
}

// MARK: - PlaylistNSTableView
// NSTableView + NSHostingView cell 复用，替代 LazyVStack 解决滚动卡顿

struct PlaylistNSTableView: NSViewRepresentable {

    let items: [MusicBridge.FlatPlaylistItem]
    let currentPlaylistName: String
    let isPlaying: Bool
    let themeColor: Color
    let artworkCacheRevision: Int
    let scrollToName: String?
    let topContentInset: CGFloat
    var onPlay:         (String) -> Void
    var onDrill:        (String) -> Void
    var onToggleFolder: (String) -> Void

    func makeCoordinator() -> PlaylistCoordinator { PlaylistCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = context.coordinator.tableView
        let col = NSTableColumn(identifier: .init("col"))
        col.isEditable = false
        tv.addTableColumn(col)
        tv.headerView = nil
        tv.backgroundColor = .clear
        tv.selectionHighlightStyle = .none
        tv.usesAlternatingRowBackgroundColors = false
        tv.intercellSpacing = .zero
        tv.style = .plain
        tv.usesAutomaticRowHeights = false
        tv.dataSource = context.coordinator
        tv.delegate   = context.coordinator

        let sv = NSScrollView()
        sv.documentView = tv
        sv.drawsBackground = false
        sv.hasVerticalScroller   = false
        sv.hasHorizontalScroller = false
        sv.contentView.automaticallyAdjustsContentInsets = false
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator

        let topPaddingChanged = abs(c.topContentInset - topContentInset) > 0.5
        let oldOriginY = sv.documentVisibleRect.minY
        let wasAtTop = abs(oldOriginY + c.topContentInset) <= 1 || abs(oldOriginY) <= 1
        let needsFullReload = c.items.count != items.count ||
            zip(c.items, items).contains { $0.id != $1.id }
        let artworkChanged = c.artworkCacheRevision != artworkCacheRevision
        let shouldRestoreTop = wasAtTop && scrollToName == nil &&
            (topPaddingChanged || needsFullReload)

        // 只有影响显示的状态变化才触发可见行刷新
        let needsVisibleReload = !needsFullReload && (
            c.currentPlaylistName != currentPlaylistName ||
            c.isPlaying != isPlaying ||
            c.themeColor != themeColor ||
            artworkChanged
        )

        c.items               = items
        c.currentPlaylistName = currentPlaylistName
        c.isPlaying           = isPlaying
        c.themeColor          = themeColor
        c.artworkCacheRevision = artworkCacheRevision
        c.topContentInset     = topContentInset
        c.onPlay              = onPlay
        c.onDrill             = onDrill
        c.onToggleFolder      = onToggleFolder

        if needsFullReload || artworkChanged {
            let keys = items.map { item -> String? in
                switch item {
                case .folderHeader(let group, _):
                    return group.representativeTrackKey
                case .playlist(_, let info):
                    return info.representativeTrackKey
                }
            }
            c.artworkImages = TrackArtworkCache.shared.cgImages(forKeys: keys)
        }

        // A nil value marks the previous centering request as consumed, so
        // opening the same playlist again can issue a fresh request later.
        if scrollToName == nil {
            c.lastScrolledTo = nil
        }

        if topPaddingChanged {
            sv.contentView.automaticallyAdjustsContentInsets = false
            sv.contentView.contentInsets = NSEdgeInsets(
                top: topContentInset, left: 0, bottom: 0, right: 0
            )
        }

        let tv = c.tableView
        if needsFullReload {
            tv.reloadData()
        } else if needsVisibleReload {
            let range = tv.rows(in: tv.visibleRect)
            let visible = IndexSet(integersIn: range.lowerBound..<(range.upperBound + 1))
            if !visible.isEmpty {
                tv.reloadData(forRowIndexes: visible, columnIndexes: IndexSet(integer: 0))
            }
        }

        // reloadData() can clamp the clip origin back to zero when an empty table
        // becomes taller than its viewport. Restore the negative top origin only
        // after AppKit has recalculated the document height.
        if shouldRestoreTop {
            DispatchQueue.main.async { [weak sv] in
                guard let sv else { return }
                sv.layoutSubtreeIfNeeded()
                sv.documentView?.layoutSubtreeIfNeeded()
                sv.contentView.scroll(to: NSPoint(x: 0, y: -topContentInset))
                sv.reflectScrolledClipView(sv.contentView)
            }
        }

        // 滚动到指定列表（仅当 scrollToName 变化时）
        if let name = scrollToName, name != c.lastScrolledTo,
           let idx = items.firstIndex(where: {
               if case .playlist(_, let pl) = $0 { return pl.name == name }
               return false
           }) {
            c.lastScrolledTo = name
            let tableRow = idx
            DispatchQueue.main.async { [weak sv, weak tv] in
                guard let sv, let tv, tableRow < tv.numberOfRows else { return }
                sv.layoutSubtreeIfNeeded()
                tv.layoutSubtreeIfNeeded()

                // Center the selected row in the unobscured region below the
                // floating header. NSClipView's own lower-bound constraint also
                // counts the top inset at the bottom, which permits an unwanted
                // blank area, so clamp against the real table content ourselves.
                let rowRect = tv.rect(ofRow: tableRow)
                let viewportHeight = sv.contentView.bounds.height
                let unobscuredCenterY = (topContentInset + viewportHeight) / 2
                let desiredY = rowRect.midY - unobscuredCenterY
                let minimumY = -topContentInset
                let contentBottom = tv.numberOfRows > 0
                    ? tv.rect(ofRow: tv.numberOfRows - 1).maxY
                    : 0
                let maximumY = max(minimumY, contentBottom - viewportHeight)
                let targetY = min(max(desiredY, minimumY), maximumY)
                sv.contentView.scroll(to: NSPoint(x: 0, y: targetY))
                sv.reflectScrolledClipView(sv.contentView)
            }
        }
    }
}

// MARK: - PlaylistCoordinator

final class PlaylistCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    let tableView = NSTableView()
    var items: [MusicBridge.FlatPlaylistItem] = []
    var currentPlaylistName: String = ""
    var isPlaying: Bool = false
    var themeColor: Color = .pink
    var artworkCacheRevision: Int = -1
    var artworkImages: [CGImage?] = []
    var topContentInset: CGFloat = 0
    var lastScrolledTo: String? = nil
    var onPlay:         (String) -> Void = { _ in }
    var onDrill:        (String) -> Void = { _ in }
    var onToggleFolder: (String) -> Void = { _ in }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch items[row] {
        case .folderHeader: return 27
        case .playlist:     return 39
        }
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        switch items[row] {

        case .folderHeader(let group, let collapsed):
            let id = NSUserInterfaceItemIdentifier("folder")
            let cell = tableView.makeView(withIdentifier: id, owner: nil)
                as? NativeFolderCellView
                ?? {
                    let view = NativeFolderCellView()
                    view.identifier = id
                    view.autoresizingMask = [.width, .height]
                    return view
                }()
            cell.configure(
                group: group,
                collapsed: collapsed,
                artwork: row < artworkImages.count ? artworkImages[row] : nil,
                onTap: { [weak self] in self?.onToggleFolder(group.folderName) }
            )
            return cell

        case .playlist(let group, let pl):
            let id = NSUserInterfaceItemIdentifier("playlist")
            let cell = tableView.makeView(withIdentifier: id, owner: nil)
                as? NativePlaylistCellView
                ?? {
                    let view = NativePlaylistCellView()
                    view.identifier = id
                    view.autoresizingMask = [.width, .height]
                    return view
                }()
            cell.configure(
                group: group, pl: pl,
                isActive:  pl.name == currentPlaylistName,
                isPlaying: isPlaying,
                themeColor: themeColor,
                artwork: row < artworkImages.count ? artworkImages[row] : nil,
                onPlay:  { [weak self] in self?.onPlay(pl.name) },
                onDrill: { [weak self] in self?.onDrill(pl.name) }
            )
            return cell
        }
    }
}

private enum NativePlaylistSymbols {
    static func image(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular) -> CGImage? {
        guard let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
        else { return nil }
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

private final class NativeFolderCellView: NSTableCellView {
    override var isFlipped: Bool { true }

    private static let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    private let artworkLayer = CALayer()
    private let placeholderTintLayer = CALayer()
    private let placeholderMaskLayer = CALayer()
    private let chevronTintLayer = CALayer()
    private let chevronMaskLayer = CALayer()
    private var name = ""
    private var indent: CGFloat = 14
    private var collapsed = false
    private var hasArtwork = false
    private var onTap: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        artworkLayer.cornerRadius = 3
        artworkLayer.masksToBounds = true
        artworkLayer.contentsGravity = .resizeAspectFill
        artworkLayer.minificationFilter = .linear
        placeholderMaskLayer.contents = NativePlaylistSymbols.image("folder.fill", pointSize: 10)
        placeholderMaskLayer.contentsGravity = .resizeAspect
        placeholderTintLayer.mask = placeholderMaskLayer
        artworkLayer.addSublayer(placeholderTintLayer)

        chevronMaskLayer.contents = NativePlaylistSymbols.image(
            "chevron.right", pointSize: 9, weight: .semibold
        )
        chevronMaskLayer.contentsGravity = .resizeAspect
        chevronTintLayer.mask = chevronMaskLayer

        layer?.addSublayer(chevronTintLayer)
        layer?.addSublayer(artworkLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTap = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artworkLayer.contents = nil
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
        updateColors()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevronTintLayer.frame = NSRect(x: indent, y: 8, width: 12, height: 12)
        chevronMaskLayer.frame = chevronTintLayer.bounds
        chevronTintLayer.setAffineTransform(
            collapsed ? .identity : CGAffineTransform(rotationAngle: .pi / 2)
        )
        artworkLayer.frame = NSRect(x: indent + 18, y: 7, width: 14, height: 14)
        placeholderTintLayer.frame = artworkLayer.bounds.insetBy(dx: 2, dy: 2)
        placeholderMaskLayer.frame = placeholderTintLayer.bounds
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        (name as NSString).draw(
            with: NSRect(x: indent + 38, y: 6, width: max(0, bounds.width - indent - 52), height: 16),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [
                .font: Self.font,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: Self.paragraph
            ]
        )
    }

    func configure(group: PlaylistGroup, collapsed: Bool, artwork: CGImage?, onTap: @escaping () -> Void) {
        name = group.folderName
        indent = 14 + CGFloat(max(0, group.indentLevel - 1)) * 12
        self.collapsed = collapsed
        hasArtwork = artwork != nil
        self.onTap = onTap
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artworkLayer.contents = artwork
        CATransaction.commit()
        updateColors()
        setAccessibilityLabel(group.folderName)
        needsLayout = true
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { onTap?() }
    }
    override func accessibilityPerformPress() -> Bool { onTap?(); return true }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for item in [artworkLayer, placeholderTintLayer, placeholderMaskLayer,
                     chevronTintLayer, chevronMaskLayer] { item.contentsScale = scale }
    }

    private func updateColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholderTintLayer.isHidden = hasArtwork
        placeholderTintLayer.backgroundColor = NSColor.secondaryLabelColor.cgColor(
            resolvedFor: layerColorAppearance
        )
        artworkLayer.backgroundColor = hasArtwork
            ? NSColor.clear.cgColor(resolvedFor: layerColorAppearance)
            : NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor(
                resolvedFor: layerColorAppearance
            )
        chevronTintLayer.backgroundColor = secondaryLabelCGColor(alpha: 0.7)
        CATransaction.commit()
    }
}

private final class NativePlaylistCellView: NSTableCellView {
    override var isFlipped: Bool { true }

    private static let titleFont = NSFont.systemFont(ofSize: 12)
    private static let countFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private static let titleParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()
    private static let countParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        return style
    }()

    private let artworkLayer = CALayer()
    private let placeholderTintLayer = CALayer()
    private let placeholderMaskLayer = CALayer()
    private let playingTintLayer = CALayer()
    private let playingMaskLayer = CALayer()
    private let chevronTintLayer = CALayer()
    private let chevronMaskLayer = CALayer()
    private var title = ""
    private var count = ""
    private var leadingPad: CGFloat = 14
    private var dividerPad: CGFloat = 50
    private var isActive = false
    private var isPlaying = false
    private var hasArtwork = false
    private var themeColor = NSColor.systemPink
    private var iconName = ""
    private var isArrowPressed = false
    private var beganPressingArrow = false
    private var onPlay: (() -> Void)?
    private var onDrill: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        artworkLayer.cornerRadius = 4
        artworkLayer.masksToBounds = true
        artworkLayer.contentsGravity = .resizeAspectFill
        artworkLayer.minificationFilter = .linear
        placeholderMaskLayer.contentsGravity = .resizeAspect
        placeholderTintLayer.mask = placeholderMaskLayer
        artworkLayer.addSublayer(placeholderTintLayer)

        playingMaskLayer.contents = NativePlaylistSymbols.image("speaker.wave.2.fill", pointSize: 10)
        playingMaskLayer.contentsGravity = .resizeAspect
        playingTintLayer.mask = playingMaskLayer
        chevronMaskLayer.contents = NativePlaylistSymbols.image(
            "chevron.right", pointSize: 9, weight: .medium
        )
        chevronMaskLayer.contentsGravity = .resizeAspect
        chevronTintLayer.mask = chevronMaskLayer

        layer?.addSublayer(artworkLayer)
        layer?.addSublayer(playingTintLayer)
        layer?.addSublayer(chevronTintLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        onPlay = nil
        onDrill = nil
        isArrowPressed = false
        beganPressingArrow = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artworkLayer.contents = nil
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
        updateColors()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let accessorySlotX = max(leadingPad + 36, bounds.width - 60)
        artworkLayer.frame = NSRect(x: leadingPad, y: 5, width: 28, height: 28)
        placeholderTintLayer.frame = artworkLayer.bounds.insetBy(dx: 7, dy: 7)
        placeholderMaskLayer.frame = placeholderTintLayer.bounds
        // The playing glyph occupies exactly the same slot as the track count,
        // so it visually replaces the number instead of appearing beside it.
        playingTintLayer.frame = NSRect(
            x: accessorySlotX + 17,
            y: 14,
            width: 11,
            height: 11
        )
        playingMaskLayer.frame = playingTintLayer.bounds
        chevronTintLayer.frame = NSRect(
            x: max(0, bounds.width - 24),
            y: 14.5,
            width: 7,
            height: 10
        )
        chevronMaskLayer.frame = chevronTintLayer.bounds
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let titleColor: NSColor
        let secondaryColor: NSColor
        if isActive {
            themeColor.withAlphaComponent(0.85).setFill()
            bounds.fill()
            titleColor = .white
            secondaryColor = NSColor.white.withAlphaComponent(0.8)
        } else {
            titleColor = .labelColor
            secondaryColor = .secondaryLabelColor
        }

        let titleX = leadingPad + 36
        let accessoryX = max(titleX, bounds.width - 60)
        (title as NSString).draw(
            with: NSRect(x: titleX, y: 11, width: max(0, accessoryX - titleX - 5), height: 17),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [
                .font: Self.titleFont,
                .foregroundColor: titleColor,
                .paragraphStyle: Self.titleParagraph
            ]
        )
        if !(isActive && isPlaying) {
            (count as NSString).draw(
                with: NSRect(x: accessoryX, y: 12, width: 28, height: 16),
                options: [.usesLineFragmentOrigin],
                attributes: [
                    .font: Self.countFont,
                    .foregroundColor: secondaryColor,
                    .paragraphStyle: Self.countParagraph
                ]
            )
        }
        NSColor.secondaryLabelColor.withAlphaComponent(0.18).setFill()
        NSRect(x: dividerPad, y: max(0, bounds.height - 1), width: max(0, bounds.width - dividerPad), height: 1).fill()
    }

    func configure(
        group: PlaylistGroup,
        pl: PlaylistInfo,
        isActive: Bool,
        isPlaying: Bool,
        themeColor: Color,
        artwork: CGImage?,
        onPlay: @escaping () -> Void,
        onDrill: @escaping () -> Void
    ) {
        title = pl.name
        count = "\(pl.trackCount)"
        leadingPad = group.isFolder
            ? 14 + CGFloat(max(0, group.indentLevel - 1)) * 12 + 20
            : 14
        dividerPad = group.isFolder
            ? 14 + CGFloat(max(0, group.indentLevel - 1)) * 12 + 56
            : 50
        self.isActive = isActive
        self.isPlaying = isPlaying
        self.themeColor = NSColor(themeColor)
        hasArtwork = artwork != nil
        isArrowPressed = false
        beganPressingArrow = false
        self.onPlay = onPlay
        self.onDrill = onDrill

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artworkLayer.contents = artwork
        if iconName != pl.kind.icon {
            iconName = pl.kind.icon
            placeholderMaskLayer.contents = NativePlaylistSymbols.image(iconName, pointSize: 12)
        }
        playingTintLayer.isHidden = !(isActive && isPlaying)
        CATransaction.commit()
        updateColors()
        setAccessibilityLabel("\(pl.name), \(pl.trackCount)")
        needsLayout = true
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        beganPressingArrow = bounds.contains(point) && point.x >= bounds.width - 34
        isArrowPressed = beganPressingArrow
        updateColors()
    }

    override func mouseDragged(with event: NSEvent) {
        guard beganPressingArrow else { return }
        let point = convert(event.locationInWindow, from: nil)
        let pressed = bounds.contains(point) && point.x >= bounds.width - 34
        guard pressed != isArrowPressed else { return }
        isArrowPressed = pressed
        updateColors()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let startedOnArrow = beganPressingArrow
        let endedOnArrow = bounds.contains(point) && point.x >= bounds.width - 34
        beganPressingArrow = false
        isArrowPressed = false
        updateColors()
        if startedOnArrow {
            if endedOnArrow { onDrill?() }
        } else if bounds.contains(point) {
            onPlay?()
        }
    }
    override func accessibilityPerformPress() -> Bool { onPlay?(); return true }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for item in [artworkLayer, placeholderTintLayer, placeholderMaskLayer,
                     playingTintLayer, playingMaskLayer, chevronTintLayer, chevronMaskLayer] {
            item.contentsScale = scale
        }
    }

    private func updateColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholderTintLayer.isHidden = hasArtwork
        placeholderTintLayer.backgroundColor = (
            isActive ? NSColor.white : NSColor.secondaryLabelColor
        ).cgColor(resolvedFor: layerColorAppearance)
        artworkLayer.backgroundColor = hasArtwork
            ? NSColor.clear.cgColor(resolvedFor: layerColorAppearance)
            : (isActive
                ? NSColor.white.withAlphaComponent(0.25).cgColor(resolvedFor: layerColorAppearance)
                : NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor(
                    resolvedFor: layerColorAppearance
                ))
        artworkLayer.opacity = isActive ? 0.88 : 1
        playingTintLayer.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor(
            resolvedFor: layerColorAppearance
        )
        let arrowAlpha: CGFloat = isArrowPressed ? 0.28 : 0.55
        chevronTintLayer.backgroundColor = isActive
            ? NSColor.white.withAlphaComponent(arrowAlpha).cgColor
            : secondaryLabelCGColor(alpha: arrowAlpha)
        CATransaction.commit()
    }
}

// MARK: - TrackNSTableView

struct TrackNSTableView: NSViewRepresentable {

    let tracks: [PlaylistTrackItem]
    let currentTrackTitle:  String
    let currentTrackArtist: String
    let isPlaying:       Bool
    let showTrackNumber: Bool
    let themeColor: Color
    let artworkCacheRevision: Int
    let topContentInset: CGFloat
    var onTap:      (Int) -> Void
    var onSwipeBack: (() -> Void)?

    func makeCoordinator() -> TrackCoordinator { TrackCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = context.coordinator.tableView
        let col = NSTableColumn(identifier: .init("col"))
        col.isEditable = false
        tv.addTableColumn(col)
        tv.headerView = nil
        tv.backgroundColor = .clear
        tv.selectionHighlightStyle = .none
        tv.usesAlternatingRowBackgroundColors = false
        tv.intercellSpacing = .zero
        tv.style = .plain
        tv.usesAutomaticRowHeights = false
        tv.rowHeight = 40
        tv.dataSource = context.coordinator
        tv.delegate   = context.coordinator

        // Keep the stock scroll view so AppKit can use concurrent VBL scrolling.
        // Overriding scrollWheel switches it to the single-threaded behavior.
        let sv = NSScrollView()
        sv.documentView = tv
        sv.drawsBackground = false
        sv.hasVerticalScroller   = false
        sv.hasHorizontalScroller = false
        sv.contentView.automaticallyAdjustsContentInsets = false
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator

        let topPaddingChanged = abs(c.topContentInset - topContentInset) > 0.5
        let oldOriginY = sv.documentVisibleRect.minY
        let wasAtTop = abs(oldOriginY + c.topContentInset) <= 1 || abs(oldOriginY) <= 1
        let needsFullReload = c.tracks.count != tracks.count ||
            zip(c.tracks, tracks).contains { $0.id != $1.id }
        let artworkChanged = c.artworkCacheRevision != artworkCacheRevision
        let shouldRestoreTop = wasAtTop && (topPaddingChanged || needsFullReload)

        let needsVisibleReload = !needsFullReload && (
            c.currentTrackTitle  != currentTrackTitle  ||
            c.currentTrackArtist != currentTrackArtist ||
            c.isPlaying          != isPlaying          ||
            c.showTrackNumber    != showTrackNumber    ||
            c.themeColor         != themeColor
        )

        c.tracks              = tracks
        c.currentTrackTitle   = currentTrackTitle
        c.currentTrackArtist  = currentTrackArtist
        c.isPlaying           = isPlaying
        c.showTrackNumber     = showTrackNumber
        c.themeColor          = themeColor
        c.artworkCacheRevision = artworkCacheRevision
        c.topContentInset     = topContentInset
        c.onTap               = onTap
        c.onSwipeBack         = onSwipeBack

        if needsFullReload || artworkChanged {
            // Resolve every row once. Scrolling now performs only an array
            // lookup and never enters TrackArtworkCache's lock.
            c.artworkImages = TrackArtworkCache.shared.cgImages(for: tracks)
        }

        if topPaddingChanged {
            sv.contentView.automaticallyAdjustsContentInsets = false
            sv.contentView.contentInsets = NSEdgeInsets(
                top: topContentInset, left: 0, bottom: 0, right: 0
            )
        }

        let tv = c.tableView
        if needsFullReload {
            tv.reloadData()
        } else if needsVisibleReload || artworkChanged {
            let range = tv.rows(in: tv.visibleRect)
            let visible = IndexSet(integersIn: range.lowerBound..<(range.upperBound + 1))
            if !visible.isEmpty {
                tv.reloadData(forRowIndexes: visible, columnIndexes: IndexSet(integer: 0))
            }
        }


        if shouldRestoreTop {
            DispatchQueue.main.async { [weak sv] in
                guard let sv else { return }
                sv.layoutSubtreeIfNeeded()
                sv.documentView?.layoutSubtreeIfNeeded()
                sv.contentView.scroll(to: NSPoint(x: 0, y: -topContentInset))
                sv.reflectScrolledClipView(sv.contentView)
            }
        }
    }
}

// MARK: - TrackCoordinator

private final class NativeTrackCellView: NSTableCellView {
    override var isFlipped: Bool { true }

    private static let titleFont = NSFont.systemFont(ofSize: 12)
    private static let artistFont = NSFont.systemFont(ofSize: 10)
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    private static let titleParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    private static let numberParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byClipping
        return style
    }()

    private static func symbolImage(_ name: String, pointSize: CGFloat) -> CGImage? {
        guard let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        else { return nil }
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private let artworkLayer = CALayer()
    private let placeholderTintLayer = CALayer()
    private let placeholderMaskLayer = CALayer()
    private let playingTintLayer = CALayer()
    private let playingMaskLayer = CALayer()

    private var title = ""
    private var artist = ""
    private var number = ""
    private var isCurrent = false
    private var isPlaying = false
    private var hasArtwork = false
    private var themeColor = NSColor.systemPink
    private var onTap: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.masksToBounds = true

        artworkLayer.cornerRadius = 4
        artworkLayer.masksToBounds = true
        artworkLayer.contentsGravity = .resizeAspectFill
        artworkLayer.minificationFilter = .linear

        placeholderMaskLayer.contents = Self.symbolImage("music.note", pointSize: 11)
        placeholderMaskLayer.contentsGravity = .resizeAspect
        placeholderTintLayer.mask = placeholderMaskLayer
        artworkLayer.addSublayer(placeholderTintLayer)

        playingMaskLayer.contents = Self.symbolImage("speaker.wave.2.fill", pointSize: 9)
        playingMaskLayer.contentsGravity = .resizeAspect
        playingTintLayer.mask = playingMaskLayer

        layer?.addSublayer(artworkLayer)
        layer?.addSublayer(playingTintLayer)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTap = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artworkLayer.contents = nil
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
        updateLayerColors()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateLayerColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
        needsDisplay = true
    }

    override func layout() {
        super.layout()

        // These are backing-layer geometry updates, not UI transitions. Without
        // disabling actions, the playing symbol's first frame can interpolate
        // from its previous/default frame when playback state changes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let artworkSize: CGFloat = 28
        let textX: CGFloat = 50
        let numberWidth: CGFloat = 28
        let trailingPadding: CGFloat = 14
        let numberX = max(textX, bounds.width - trailingPadding - numberWidth)
        let textRight = numberX - 8

        artworkLayer.frame = NSRect(x: 14, y: 5, width: artworkSize, height: artworkSize)
        placeholderTintLayer.frame = artworkLayer.bounds.insetBy(dx: 7, dy: 7)
        placeholderMaskLayer.frame = placeholderTintLayer.bounds
        if isCurrent && isPlaying {
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.titleFont]
            let availableWidth = max(0, textRight - textX - 15)
            let naturalWidth = min(
                availableWidth,
                ceil((title as NSString).size(withAttributes: attributes).width)
            )
            playingTintLayer.frame = NSRect(
                x: textX + naturalWidth + 4,
                y: 6,
                width: 11,
                height: 11
            )
            playingMaskLayer.frame = playingTintLayer.bounds
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let titleColor: NSColor
        let secondaryColor: NSColor
        let numberColor: NSColor
        if isCurrent {
            themeColor.withAlphaComponent(0.85).setFill()
            bounds.fill()
            titleColor = .white
            secondaryColor = NSColor.white.withAlphaComponent(0.75)
            numberColor = NSColor.white.withAlphaComponent(0.6)
        } else {
            titleColor = .labelColor
            secondaryColor = .secondaryLabelColor
            numberColor = NSColor.secondaryLabelColor.withAlphaComponent(0.5)
        }

        let textX: CGFloat = 50
        let numberWidth: CGFloat = 28
        let numberX = max(textX, bounds.width - 14 - numberWidth)
        let textRight = numberX - 8
        let showsPlaying = isCurrent && isPlaying
        let titleWidth: CGFloat
        if showsPlaying {
            let measured = ceil((title as NSString).size(withAttributes: [.font: Self.titleFont]).width)
            titleWidth = min(max(0, textRight - textX - 15), measured)
        } else {
            titleWidth = max(0, textRight - textX)
        }

        (title as NSString).draw(
            with: NSRect(x: textX, y: 3, width: titleWidth, height: 17),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [
                .font: Self.titleFont,
                .foregroundColor: titleColor,
                .paragraphStyle: Self.titleParagraph
            ]
        )
        (artist as NSString).draw(
            with: NSRect(x: textX, y: 20, width: max(0, textRight - textX), height: 14),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [
                .font: Self.artistFont,
                .foregroundColor: secondaryColor,
                .paragraphStyle: Self.titleParagraph
            ]
        )
        (number as NSString).draw(
            with: NSRect(x: numberX, y: 12, width: numberWidth, height: 16),
            options: [.usesLineFragmentOrigin],
            attributes: [
                .font: Self.numberFont,
                .foregroundColor: numberColor,
                .paragraphStyle: Self.numberParagraph
            ]
        )

        NSColor.secondaryLabelColor.withAlphaComponent(0.18).setFill()
        NSRect(x: 56, y: max(0, bounds.height - 1), width: max(0, bounds.width - 56), height: 1).fill()
    }

    func configure(
        track: PlaylistTrackItem,
        index: Int,
        isCurrent: Bool,
        isPlaying: Bool,
        showTrackNumber: Bool,
        themeColor: Color,
        artwork: CGImage?,
        onTap: @escaping () -> Void
    ) {
        self.onTap = onTap
        title = track.title
        artist = track.artist
        number = showTrackNumber && track.trackNumber > 0
            ? (track.discNumber > 1
                ? "\(track.discNumber)-\(track.trackNumber)"
                : "\(track.trackNumber)")
            : "\(index + 1)"
        self.isCurrent = isCurrent
        self.isPlaying = isPlaying
        self.hasArtwork = artwork != nil
        self.themeColor = NSColor(themeColor)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artworkLayer.contents = artwork
        playingTintLayer.isHidden = !(isCurrent && isPlaying)
        CATransaction.commit()
        updateLayerColors()
        setAccessibilityLabel("\(track.title) — \(track.artist)")
        needsLayout = true
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        // Deliberately empty: activate on mouse-up like NSButton, while keeping
        // the row free of NSControl tracking areas.
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { onTap?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onTap?()
        return true
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for item in [artworkLayer, placeholderTintLayer, placeholderMaskLayer,
                     playingTintLayer, playingMaskLayer] {
            item.contentsScale = scale
        }
    }

    private func updateLayerColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholderTintLayer.isHidden = hasArtwork
        placeholderTintLayer.backgroundColor = (
            isCurrent
                ? NSColor.white.withAlphaComponent(0.6)
                : NSColor.secondaryLabelColor
        ).cgColor(resolvedFor: layerColorAppearance)
        artworkLayer.backgroundColor = hasArtwork
            ? NSColor.clear.cgColor(resolvedFor: layerColorAppearance)
            : (isCurrent
                ? NSColor.white.withAlphaComponent(0.15).cgColor(resolvedFor: layerColorAppearance)
                : NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor(
                    resolvedFor: layerColorAppearance
                ))
        artworkLayer.opacity = isCurrent ? 0.88 : 1
        playingTintLayer.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor(
            resolvedFor: layerColorAppearance
        )
        CATransaction.commit()
    }
}

final class TrackCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    let tableView = NSTableView()
    var tracks: [PlaylistTrackItem] = []
    var currentTrackTitle:  String = ""
    var currentTrackArtist: String = ""
    var isPlaying:       Bool = false
    var showTrackNumber: Bool = true
    var themeColor: Color = .pink
    var artworkCacheRevision: Int = -1
    var artworkImages: [CGImage?] = []
    var topContentInset: CGFloat = 0
    var onTap:       (Int) -> Void = { _ in }
    var onSwipeBack: (() -> Void)?

    func numberOfRows(in tableView: NSTableView) -> Int { tracks.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 40 }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let trackIndex = row
        let id  = NSUserInterfaceItemIdentifier("track")
        let track = tracks[trackIndex]
        let isCurrent = currentTrackTitle == track.title && currentTrackArtist == track.artist

        let cell = tableView.makeView(withIdentifier: id, owner: nil)
            as? NativeTrackCellView
            ?? {
                let view = NativeTrackCellView()
                view.identifier = id
                view.autoresizingMask = [.width, .height]
                return view
            }()

        let capturedRow = trackIndex
        cell.configure(
            track: track,
            index: trackIndex,
            isCurrent: isCurrent,
            isPlaying: isPlaying,
            showTrackNumber: showTrackNumber,
            themeColor: themeColor,
            artwork: trackIndex < artworkImages.count ? artworkImages[trackIndex] : nil,
            onTap: { [weak self] in self?.onTap(capturedRow) }
        )
        return cell
    }

}
