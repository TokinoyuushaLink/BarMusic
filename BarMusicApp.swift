import SwiftUI
import AppKit

// MARK: - Theme

enum AppTheme: String, CaseIterable {
    case pink   = "pink"
    case red    = "red"
    case orange = "orange"
    case purple = "purple"
    case blue   = "blue"
    case teal   = "teal"
    case green  = "green"
    case custom = "custom"

    var color: Color {
        switch self {
        case .pink:   return .pink
        case .red:    return Color(red: 0.92, green: 0.2, blue: 0.2)
        case .orange: return .orange
        case .purple: return .purple
        case .blue:   return .blue
        case .teal:   return .teal
        case .green:  return Color(red: 0.2, green: 0.75, blue: 0.4)
        case .custom: return .pink  // ThemeManager supplies the saved custom color.
        }
    }

    var label: String {
        switch self {
        case .pink:   return L.themePink
        case .red:    return L.themeRed
        case .orange: return L.themeOrange
        case .purple: return L.themePurple
        case .blue:   return L.themeBlue
        case .teal:   return L.themeTeal
        case .green:  return L.themeGreen
        case .custom: return L.themeCustom
        }
    }
}

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    private init() {}

    @Published private(set) var customColor: NSColor = {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "customThemeRed") != nil else { return .systemPink }
        return NSColor(
            srgbRed: defaults.double(forKey: "customThemeRed"),
            green: defaults.double(forKey: "customThemeGreen"),
            blue: defaults.double(forKey: "customThemeBlue"),
            alpha: 1
        )
    }()

    @Published var theme: AppTheme = {
        let raw = UserDefaults.standard.string(forKey: "appTheme") ?? ""
        return AppTheme(rawValue: raw) ?? .pink
    }()

    var color: Color {
        theme == .custom ? Color(nsColor: customColor) : theme.color
    }

    func set(_ t: AppTheme) {
        theme = t
        UserDefaults.standard.set(t.rawValue, forKey: "appTheme")
    }

    func setCustomColor(_ color: NSColor) {
        let converted = color.usingColorSpace(.sRGB) ?? .systemPink
        customColor = converted
        let defaults = UserDefaults.standard
        defaults.set(Double(converted.redComponent), forKey: "customThemeRed")
        defaults.set(Double(converted.greenComponent), forKey: "customThemeGreen")
        defaults.set(Double(converted.blueComponent), forKey: "customThemeBlue")
        set(.custom)
    }
}

// MARK: - Playback interval menu control

final class PlaybackIntervalMenuView: NSView {
    let valueLabel = NSTextField(labelWithString: "")
    let slider: NSSlider

    init(value: Double, target: AnyObject, action: Selector) {
        slider = NSSlider(value: value, minValue: 0, maxValue: 4, target: target, action: action)
        super.init(frame: NSRect(x: 0, y: 0, width: 170, height: 58))

        let titleLabel = NSTextField(labelWithString: L.playbackInterval)
        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.frame = NSRect(x: 14, y: 34, width: 78, height: 17)
        addSubview(titleLabel)

        valueLabel.alignment = .right
        valueLabel.font = .menuFont(ofSize: 0)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.frame = NSRect(x: 91, y: 34, width: 65, height: 17)
        addSubview(valueLabel)

        slider.isContinuous = true
        slider.controlSize = .small
        slider.frame = NSRect(x: 12, y: 7, width: 146, height: 24)
        slider.setAccessibilityLabel(L.playbackInterval)
        addSubview(slider)

        updateValueLabel(value)
    }

    required init?(coder: NSCoder) { nil }

    func updateValueLabel(_ value: Double) {
        valueLabel.stringValue = L.playbackIntervalValue(value)
    }
}

// MARK: - AppDelegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var music: MusicBridge!
    let theme  = ThemeManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        music = MusicBridge()

        // Status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "music.note",
                                accessibilityDescription: "BarMusic")
            btn.target  = self
            btn.action  = #selector(handleClick(_:))
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // 关闭 hover 高亮：鼠标划过时不触发背景重绘
            (btn.cell as? NSButtonCell)?.showsBorderOnlyWhileMouseInside = false
        }

        // Main popover
        popover = NSPopover()
        popover.behavior       = .transient
        popover.animates       = true
        popover.delegate       = self
    }

    @objc func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!

        if event.type == .rightMouseUp ||
           event.modifierFlags.contains(.control) {
            showSettingsMenu(sender)
        } else {
            togglePopover(sender)
        }
    }

    func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Keep one hosting tree for the lifetime of the app. Recreating it
            // after every close loses the AppKit panels' model-layer positions,
            // so a drill-to-list return after reopening has no outgoing state to
            // animate from.
            if popover.contentViewController == nil {
                let hc = NSHostingController(
                    rootView: ContentView()
                        .environmentObject(music)
                        .environmentObject(theme)
                )
                hc.sizingOptions = .preferredContentSize
                popover.contentViewController = hc
            }
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func showSettingsMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()

        // Theme submenu
        let themeItem = NSMenuItem(title: L.themeColor, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for t in AppTheme.allCases where t != .custom {
            let item = NSMenuItem(
                title: t.label,
                action: #selector(selectTheme(_:)),
                keyEquivalent: ""
            )
            item.target         = self
            item.representedObject = t
            item.state          = (theme.theme == t) ? .on : .off
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let customThemeItem = NSMenuItem(
            title: L.themeCustom,
            action: #selector(showCustomColorPanel),
            keyEquivalent: ""
        )
        customThemeItem.target = self
        customThemeItem.state = (theme.theme == .custom) ? .on : .off
        sub.addItem(customThemeItem)
        themeItem.submenu = sub
        menu.addItem(themeItem)

        menu.addItem(.separator())

        // Waveform toggle
        let waveItem = NSMenuItem(title: L.waveformBars,
                                  action: #selector(toggleWaveform),
                                  keyEquivalent: "")
        waveItem.target = self
        waveItem.state  = music.showWaveform ? .on : .off
        menu.addItem(waveItem)

        // Inter-track delay slider (0.0–4.0 seconds)
        let delayItem = NSMenuItem()
        delayItem.view = PlaybackIntervalMenuView(
            value: music.audioPlayer.interTrackDelay,
            target: self,
            action: #selector(changeInterTrackDelay(_:))
        )
        menu.addItem(delayItem)

        menu.addItem(.separator())

        // Refresh
        let refresh = NSMenuItem(title: L.refreshPlaylists,
                                 action: #selector(refreshPlaylists),
                                 keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        // Quit
        let quit = NSMenuItem(title: L.quit,
                              action: #selector(quitApp),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Clear menu after use so left-click works normally next time
        DispatchQueue.main.async { self.statusItem.menu = nil }
    }

    @objc func toggleWaveform() {
        music.toggleWaveform()
    }

    @objc func selectTheme(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? AppTheme else { return }
        theme.set(t)
    }

    @objc func showCustomColorPanel() {
        let panel = NSColorPanel.shared
        panel.color = theme.customColor
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.setTarget(self)
        panel.setAction(#selector(changeCustomThemeColor(_:)))
        panel.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func changeCustomThemeColor(_ sender: NSColorPanel) {
        theme.setCustomColor(sender.color)
    }

    @objc func changeInterTrackDelay(_ sender: NSSlider) {
        // One decimal place gives useful precision without making the control fiddly.
        let delay = (sender.doubleValue * 10).rounded() / 10
        sender.doubleValue = delay
        music.setInterTrackDelay(delay)
        (sender.superview as? PlaybackIntervalMenuView)?.updateValueLabel(delay)
    }

    @objc func refreshPlaylists() {
        music.refreshPlaylists()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - NSPopoverDelegate

    func popoverWillShow(_ notification: Notification) {
        music.popoverDidOpen()
    }

    func popoverDidClose(_ notification: Notification) {
        music.popoverDidClose()
    }
}

// MARK: - App entry point

@main
struct BarMusicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // No windows needed; everything is in the popover
        Settings { EmptyView() }
    }
}
