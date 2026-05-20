import Foundation

// MARK: - Locale detection

/// true = use Chinese, false = use English
/// DEBUG: flip this to force a language for screenshot
let debugForceLanguage: Bool? = true  // DEBUG LINE — set nil to use system, true = Chinese, false = English

var isChinese: Bool {
    if let forced = debugForceLanguage { return forced }
    let lang = Locale.current.language.languageCode?.identifier ?? ""
    return lang == "zh"
}

// MARK: - Strings

enum L {
    // Now Playing
    static var notPlaying:      String { isChinese ? "未在播放"   : "Not Playing" }
    static var unknownArtist:   String { isChinese ? "未知艺术家" : "Unknown Artist" }
    static var unknownAlbum:    String { isChinese ? "未知专辑"   : "Unknown Album" }
    static var unknownTrack:    String { isChinese ? "未知曲目"   : "Unknown Track" }
    static var unnamed:         String { isChinese ? "未命名"     : "Untitled" }

    // Playlist section
    static var playlists:       String { isChinese ? "播放列表"   : "Playlists" }
    static var quit:            String { isChinese ? "退出 BarMusic" : "Quit BarMusic" }

    // Sort button tooltip
    static var sortOnTooltip:   String { isChinese ? "按碟号/音轨号排序（已开启）" : "Sort by disc/track number (on)" }
    static var sortOffTooltip:  String { isChinese ? "按碟号/音轨号排序（已关闭）" : "Sort by disc/track number (off)" }

    // PlayMode labels
    static var modeSequential:  String { isChinese ? "顺序" : "Order" }
    static var modeShuffle:     String { isChinese ? "乱序" : "Shuffle" }
    static var modeRepeatOne:   String { isChinese ? "单曲" : "Repeat" }

    // Bottom bar
    static var refreshPlaylists: String { isChinese ? "刷新列表" : "Refresh Playlists" }

    // Settings menu
    static var settings:         String { isChinese ? "设置"     : "Settings" }
    static var themeColor:       String { isChinese ? "主题色"   : "Theme Color" }
    static var themeRed:         String { isChinese ? "红色"     : "Red" }
    static var themeOrange:      String { isChinese ? "橙色"     : "Orange" }
    static var themePink:        String { isChinese ? "粉色"     : "Pink" }
    static var themePurple:      String { isChinese ? "紫色"     : "Purple" }
    static var themeBlue:        String { isChinese ? "蓝色"     : "Blue" }
    static var themeTeal:        String { isChinese ? "青色"     : "Teal" }
    static var themeGreen:       String { isChinese ? "绿色"     : "Green" }
}
