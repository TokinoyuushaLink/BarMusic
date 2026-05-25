import Foundation

struct AlbumColorComponent: Codable, Sendable {
    let r: Float
    let g: Float
    let b: Float
    var luminance: Float { 0.299 * r + 0.587 * g + 0.114 * b }

    func clamped(min minLum: Float = 0.20, max maxLum: Float = 0.70) -> AlbumColorComponent {
        let lum = luminance
        if lum > maxLum && lum > 0 {
            let s = maxLum / lum
            return AlbumColorComponent(r: r * s, g: g * s, b: b * s)
        } else if lum < minLum {
            let t = lum < 1 ? (minLum - lum) / (1 - lum) : 0
            return AlbumColorComponent(r: r + (1 - r) * t, g: g + (1 - g) * t, b: b + (1 - b) * t)
        }
        return self
    }

    // Preserve hue; push luminance toward target for use as background fill.
    // dark target ~0.18 (scale down), light target ~0.90 (mix with white).
    func asBackground(forDark: Bool) -> AlbumColorComponent {
        let target: Float = forDark ? 0.18 : 0.90
        let lum = luminance
        if forDark {
            if lum <= 0 { return AlbumColorComponent(r: target, g: target, b: target) }
            let s = min(target / lum, 1.0)
            return AlbumColorComponent(r: r * s, g: g * s, b: b * s)
        } else {
            let t = lum < 1 ? max((target - lum) / (1 - lum), 0) : 0
            return AlbumColorComponent(r: r + (1 - r) * t, g: g + (1 - g) * t, b: b + (1 - b) * t)
        }
    }
}

struct AlbumColorEntry: Codable, Sendable {
    let dark:    AlbumColorComponent  // accent · dark mode  (s×√v×log)
    let light:   AlbumColorComponent  // accent · light mode (s×(1−lum)×log)
    let bgDark:  AlbumColorComponent  // background · dark mode  (largest cluster, darkened)
    let bgLight: AlbumColorComponent  // background · light mode (largest cluster, lightened)
}

struct AlbumColorAnalyzer {

    private static let fbDark    = AlbumColorComponent(r: 0.93, g: 0.42, b: 0.62)
    private static let fbLight   = AlbumColorComponent(r: 0.72, g: 0.10, b: 0.35)
    private static let fbBgDark  = AlbumColorComponent(r: 0.15, g: 0.15, b: 0.17)
    private static let fbBgLight = AlbumColorComponent(r: 0.94, g: 0.92, b: 0.93)
    static let fallback = AlbumColorEntry(dark: fbDark, light: fbLight, bgDark: fbBgDark, bgLight: fbBgLight)

    private struct Cluster {
        let r: Float, g: Float, b: Float
        let count: Int
        let s: Float, v: Float
        var luminance: Float { 0.299 * r + 0.587 * g + 0.114 * b }
    }

    static func analyze(bgraData: Data, size: Int = TrackArtworkCache.thumbSize) -> AlbumColorEntry {
        guard bgraData.count == size * size * 4 else { return fallback }

        // — 1. Quantize into 5-bit/channel buckets —
        var counts: [Int32: Int] = [:]
        var sumR:   [Int32: Int] = [:]
        var sumG:   [Int32: Int] = [:]
        var sumB:   [Int32: Int] = [:]
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
                sumR[key, default: 0]   += Int(r)
                sumG[key, default: 0]   += Int(g)
                sumB[key, default: 0]   += Int(b)
                totalOpaque += 1
            }
        }
        guard totalOpaque > 0, !counts.isEmpty else { return fallback }

        // — 2. Build Cluster array —
        var clusters: [Cluster] = []
        clusters.reserveCapacity(counts.count)
        for (key, count) in counts {
            let r = Float(sumR[key]!) / Float(count) / 255
            let g = Float(sumG[key]!) / Float(count) / 255
            let b = Float(sumB[key]!) / Float(count) / 255
            let (_, s, v) = rgbToHSV(r: r, g: g, b: b)
            clusters.append(Cluster(r: r, g: g, b: b, count: count, s: s, v: v))
        }

        // — 3. Background = largest cluster, adjusted per appearance mode —
        let bgCluster = clusters.max { $0.count < $1.count }!
        let bgBase    = AlbumColorComponent(r: bgCluster.r, g: bgCluster.g, b: bgCluster.b)
        let bgDark    = bgBase.asBackground(forDark: true)
        let bgLight   = bgBase.asBackground(forDark: false)

        // — 4. Detect predominantly achromatic covers (black/gray/white ≥ 85%) —
        // For these, saturation-based scoring is meaningless; use brightness inversion instead:
        // dark mode → brightest cluster (white text on black bg), light mode → darkest cluster.
        let achromaticPixels = clusters.filter { $0.s < 0.20 }.reduce(0) { $0 + $1.count }
        if Float(achromaticPixels) / Float(totalOpaque) >= 0.85 {
            let brightCluster = clusters.max { $0.luminance < $1.luminance }!
            let darkestCluster = clusters.min { $0.luminance < $1.luminance }!
            return AlbumColorEntry(
                dark:    AlbumColorComponent(r: brightCluster.r,  g: brightCluster.g,  b: brightCluster.b),
                light:   AlbumColorComponent(r: darkestCluster.r, g: darkestCluster.g, b: darkestCluster.b),
                bgDark:  bgDark,
                bgLight: bgLight
            )
        }

        // — 5. Accent = most vivid cluster (log-weighted to surface small vivid areas) —
        func darkScore(_ c: Cluster)  -> Float { c.s * sqrtf(c.v)       * log10f(Float(c.count) + 10) }
        func lightScore(_ c: Cluster) -> Float { c.s * (1 - c.luminance) * log10f(Float(c.count) + 10) }

        // Prefer chromatic candidates; fall back to all clusters for non-achromatic covers.
        let colored = clusters.filter { $0.s >= 0.20 && $0.v >= 0.12 && $0.v <= 0.97 }
        let pool    = colored.isEmpty ? clusters : colored

        let darkCluster  = pool.max { darkScore($0)  < darkScore($1)  }!
        let lightCluster = pool.max { lightScore($0) < lightScore($1) }!

        return AlbumColorEntry(
            dark:    AlbumColorComponent(r: darkCluster.r,  g: darkCluster.g,  b: darkCluster.b),
            light:   AlbumColorComponent(r: lightCluster.r, g: lightCluster.g, b: lightCluster.b),
            bgDark:  bgDark,
            bgLight: bgLight
        )
    }

    private static func rgbToHSV(r: Float, g: Float, b: Float) -> (Float, Float, Float) {
        let maxC  = max(r, g, b)
        let minC  = min(r, g, b)
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
