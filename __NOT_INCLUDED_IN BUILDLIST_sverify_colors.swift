#!/usr/bin/env swift
//
//  verify_colors.swift
//  独立验证 AlbumColorAnalyzer 的判定结果，无需 Xcode、无需建 package。
//
//  用法：
//    swift verify_colors.swift
//        读默认目录 ~/Library/Application Support/BarMusic/artwork/ 下所有 .raw
//
//    swift verify_colors.swift /path/to/artwork
//        指定 artwork 目录
//
//    swift verify_colors.swift /path/to/artwork --no-color
//        关闭 ANSI 色块（输出到文件 / 不支持 ANSI 的终端时用）
//
//  输出每张 .raw 的：hash、判定路径(A/B)、彩色占比、选出的四个颜色（带终端色块预览）。
//

import Foundation

// ───────────────────────────────────────────────────────────
// MARK: - 常量（与 TrackArtworkCache 保持一致）
// ───────────────────────────────────────────────────────────

let thumbSize = 56
let rawByteCount = thumbSize * thumbSize * 4   // 12544

// ───────────────────────────────────────────────────────────
// MARK: - AlbumColorAnalyzer（从主工程内联，逻辑完全一致）
// ───────────────────────────────────────────────────────────

struct AlbumColorComponent {
    let r: Float
    let g: Float
    let b: Float
    var luminance: Float { 0.299 * r + 0.587 * g + 0.114 * b }

    func adjustedLuminance(to target: Float) -> AlbumColorComponent {
        let lum = luminance
        if lum <= 0 { return AlbumColorComponent(r: target, g: target, b: target) }
        if target < lum {
            let s = target / lum
            return AlbumColorComponent(r: r * s, g: g * s, b: b * s)
        } else {
            let t = (target - lum) / (1 - lum)
            return AlbumColorComponent(r: r + (1 - r) * t,
                                       g: g + (1 - g) * t,
                                       b: b + (1 - b) * t)
        }
    }
}

struct AlbumColorEntry {
    let dark:    AlbumColorComponent
    let light:   AlbumColorComponent
    let bgDark:  AlbumColorComponent
    let bgLight: AlbumColorComponent
}

// 判定结果附带诊断信息，方便打印
struct AnalyzeResult {
    let entry: AlbumColorEntry
    let path: String          // "A" 有彩色 / "B" 无彩色 / "fallback"
    let coloredRatio: Float
    let bucketCount: Int
}

struct AlbumColorAnalyzer {

    static let fallback = AlbumColorEntry(
        dark:    AlbumColorComponent(r: 0.93, g: 0.42, b: 0.62),
        light:   AlbumColorComponent(r: 0.72, g: 0.10, b: 0.35),
        bgDark:  AlbumColorComponent(r: 0.15, g: 0.15, b: 0.17),
        bgLight: AlbumColorComponent(r: 0.94, g: 0.92, b: 0.93)
    )

    static let bgTargetDark:  Float = 0.18
    static let bgTargetLight: Float = 0.90
    static let satFloor: Float = 0.15
    static let coloredRatioFloor: Float = 0.03

    struct Cluster {
        let r: Float, g: Float, b: Float
        let count: Int
        let s: Float, v: Float
        var luminance: Float { 0.299 * r + 0.587 * g + 0.114 * b }
    }

    static func analyze(bgraData: Data, size: Int = thumbSize) -> AnalyzeResult {
        guard bgraData.count == size * size * 4 else {
            return AnalyzeResult(entry: fallback, path: "fallback(size)", coloredRatio: 0, bucketCount: 0)
        }

        var counts: [Int32: Int] = [:]
        var sumR: [Int32: Int] = [:]
        var sumG: [Int32: Int] = [:]
        var sumB: [Int32: Int] = [:]
        var totalOpaque = 0

        bgraData.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0 ..< size * size {
                let off = i &* 4
                guard base[off + 3] > 128 else { continue }
                let b = Int32(base[off])
                let g = Int32(base[off + 1])
                let r = Int32(base[off + 2])
                let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                counts[key, default: 0] += 1
                sumR[key, default: 0] += Int(r)
                sumG[key, default: 0] += Int(g)
                sumB[key, default: 0] += Int(b)
                totalOpaque += 1
            }
        }
        guard totalOpaque > 0, !counts.isEmpty else {
            return AnalyzeResult(entry: fallback, path: "fallback(empty)", coloredRatio: 0, bucketCount: 0)
        }

        var clusters: [Cluster] = []
        clusters.reserveCapacity(counts.count)
        for (key, count) in counts {
            let r = Float(sumR[key]!) / Float(count) / 255
            let g = Float(sumG[key]!) / Float(count) / 255
            let b = Float(sumB[key]!) / Float(count) / 255
            let (_, s, v) = rgbToHSV(r: r, g: g, b: b)
            clusters.append(Cluster(r: r, g: g, b: b, count: count, s: s, v: v))
        }

        let colored = clusters.filter { $0.s >= satFloor && $0.v >= 0.12 && $0.v <= 0.97 }
        let coloredPixels = colored.reduce(0) { $0 + $1.count }
        let coloredRatio = Float(coloredPixels) / Float(totalOpaque)

        if !colored.isEmpty && coloredRatio >= coloredRatioFloor {
            func vividScore(_ c: Cluster) -> Float {
                let brightFit = 1 - abs(c.v - 0.6) * 1.1
                return c.s * max(brightFit, 0.2) * log10f(Float(c.count) + 10)
            }
            let best = colored.max { vividScore($0) < vividScore($1) }!
            let base = AlbumColorComponent(r: best.r, g: best.g, b: best.b)

            let themeDark  = base.luminance < 0.45 ? base.adjustedLuminance(to: 0.55) : base
            let themeLight = base.luminance > 0.45 ? base.adjustedLuminance(to: 0.38) : base
            let bgDark  = base.adjustedLuminance(to: bgTargetDark)
            let bgLight = base.adjustedLuminance(to: bgTargetLight)

            let entry = AlbumColorEntry(dark: themeDark, light: themeLight, bgDark: bgDark, bgLight: bgLight)
            return AnalyzeResult(entry: entry, path: "A", coloredRatio: coloredRatio, bucketCount: clusters.count)

        } else {
            let brightest = clusters.max { $0.v < $1.v }!
            let darkest   = clusters.min { $0.v < $1.v }!
            let themeDark  = AlbumColorComponent(r: brightest.r, g: brightest.g, b: brightest.b)
            let themeLight = AlbumColorComponent(r: darkest.r,   g: darkest.g,   b: darkest.b)

            let bgCluster = clusters.max { $0.count < $1.count }!
            let bgBase = AlbumColorComponent(r: bgCluster.r, g: bgCluster.g, b: bgCluster.b)
            let entry = AlbumColorEntry(
                dark:    themeDark,
                light:   themeLight,
                bgDark:  bgBase.adjustedLuminance(to: bgTargetDark),
                bgLight: bgBase.adjustedLuminance(to: bgTargetLight)
            )
            return AnalyzeResult(entry: entry, path: "B", coloredRatio: coloredRatio, bucketCount: clusters.count)
        }
    }

    static func rgbToHSV(r: Float, g: Float, b: Float) -> (Float, Float, Float) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        let s = maxC > 0 ? delta / maxC : 0
        var h: Float = 0
        if delta > 0 {
            if      maxC == r { h = (g - b) / delta }
            else if maxC == g { h = 2 + (b - r) / delta }
            else              { h = 4 + (r - g) / delta }
            h *= 60
            if h < 0 { h += 360 }
        }
        return (h, s, maxC)
    }
}

// ───────────────────────────────────────────────────────────
// MARK: - 终端输出工具
// ───────────────────────────────────────────────────────────

var useColor = true

func hex(_ c: AlbumColorComponent) -> String {
    let r = Int((c.r * 255).rounded()).clamped(0, 255)
    let g = Int((c.g * 255).rounded()).clamped(0, 255)
    let b = Int((c.b * 255).rounded()).clamped(0, 255)
    return String(format: "#%02X%02X%02X", r, g, b)
}

// 在终端用真彩色背景画两个空格当色块
func swatch(_ c: AlbumColorComponent) -> String {
    guard useColor else { return "  " }
    let r = Int((c.r * 255).rounded()).clamped(0, 255)
    let g = Int((c.g * 255).rounded()).clamped(0, 255)
    let b = Int((c.b * 255).rounded()).clamped(0, 255)
    return "\u{001B}[48;2;\(r);\(g);\(b)m  \u{001B}[0m"
}

extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.max(lo, Swift.min(hi, self)) }
}

func pad(_ s: String, _ width: Int) -> String {
    if s.count >= width { return s }
    return s + String(repeating: " ", count: width - s.count)
}

// ───────────────────────────────────────────────────────────
// MARK: - 主流程
// ───────────────────────────────────────────────────────────

var args = Array(CommandLine.arguments.dropFirst())
if let i = args.firstIndex(of: "--no-color") {
    useColor = false
    args.remove(at: i)
}

let defaultDir = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    .appendingPathComponent("BarMusic/artwork", isDirectory: true)

let artworkDir = args.first.map { URL(fileURLWithPath: $0) } ?? defaultDir

print("📂 扫描目录：\(artworkDir.path)\n")

guard let files = try? FileManager.default.contentsOfDirectory(
    at: artworkDir, includingPropertiesForKeys: nil
) else {
    print("❌ 无法读取目录，确认路径是否存在。")
    exit(1)
}

let rawFiles = files.filter { $0.pathExtension == "raw" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !rawFiles.isEmpty else {
    print("⚠️ 目录里没有 .raw 文件。先在 app 里构建一次缓存。")
    exit(0)
}

// 表头
print(pad("hash", 12) + pad("路径", 6) + pad("彩色%", 8) + pad("桶数", 6)
      + " theme-dark  theme-light  bg-dark  bg-light")
print(String(repeating: "─", count: 78))

var pathACount = 0
var pathBCount = 0

for file in rawFiles {
    let hash = file.deletingPathExtension().lastPathComponent
    guard let data = try? Data(contentsOf: file), data.count == rawByteCount else {
        print(pad(hash, 12) + "字节数不符（\(((try? Data(contentsOf: file))?.count) ?? 0)）")
        continue
    }

    let r = AlbumColorAnalyzer.analyze(bgraData: data)
    if r.path == "A" { pathACount += 1 }
    if r.path == "B" { pathBCount += 1 }

    let ratioStr = String(format: "%.1f%%", r.coloredRatio * 100)
    let e = r.entry

    var line = pad(hash, 12)
    line += pad(r.path, 6)
    line += pad(ratioStr, 8)
    line += pad("\(r.bucketCount)", 6)
    line += " "
    line += swatch(e.dark)   + " " + pad(hex(e.dark), 8)  + "  "
    line += swatch(e.light)  + " " + pad(hex(e.light), 8) + " "
    line += swatch(e.bgDark) + " "
    line += swatch(e.bgLight)
    print(line)
}

print(String(repeating: "─", count: 78))
print("\n共 \(rawFiles.count) 张：路径 A(有彩色) \(pathACount) 张，路径 B(无彩色) \(pathBCount) 张")
print("阈值：satFloor=\(AlbumColorAnalyzer.satFloor)  coloredRatioFloor=\(AlbumColorAnalyzer.coloredRatioFloor)")
print("\n色块顺序：theme-dark · theme-light · bg-dark · bg-light")
