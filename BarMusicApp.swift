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

    var color: Color {
        switch self {
        case .pink:   return .pink
        case .red:    return Color(red: 0.92, green: 0.2, blue: 0.2)
        case .orange: return .orange
        case .purple: return .purple
        case .blue:   return .blue
        case .teal:   return .teal
        case .green:  return Color(red: 0.2, green: 0.75, blue: 0.4)
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
        }
    }
}

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    private init() {}

    @Published var theme: AppTheme = {
        let raw = UserDefaults.standard.string(forKey: "appTheme") ?? ""
        return AppTheme(rawValue: raw) ?? .pink
    }()

    func set(_ t: AppTheme) {
        theme = t
        UserDefaults.standard.set(t.rawValue, forKey: "appTheme")
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
        popover.contentSize    = NSSize(width: 270, height: 600)
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
            popover.contentViewController = NSHostingController(
                rootView: ContentView()
                    .environmentObject(music)
                    .environmentObject(theme)
            )
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func showSettingsMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()

        // Theme submenu
        let themeItem = NSMenuItem(title: L.themeColor, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for t in AppTheme.allCases {
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
        popover.contentViewController = nil
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
