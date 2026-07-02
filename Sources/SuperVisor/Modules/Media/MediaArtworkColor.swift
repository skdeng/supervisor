import AppKit
import SwiftUI

/// Extracts a vibrant "dominant" color from album artwork, suitable for tinting UI on the black
/// notch. It downsamples the artwork to a small bitmap, bins pixels by quantized RGB weighted by
/// vibrancy (saturation² × brightness) — so near-black/near-white/gray backgrounds don't win —
/// picks the heaviest bin, then boosts the result so it reads clearly against black.
enum MediaArtworkColor {
    /// Used when there is no artwork or extraction fails, so bars stay their default white.
    static let fallback: Color = NotchTheme.primaryForeground

    static func dominant(of image: NSImage) -> Color? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let side = 40
        let bytesPerRow = side * 4
        guard let ctx = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let buffer = ctx.data else { return nil }

        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        let ptr = buffer.bindMemory(to: UInt8.self, capacity: side * side * 4)

        struct Bin { var weight = 0.0; var r = 0.0; var g = 0.0; var b = 0.0 }
        var bins: [Int: Bin] = [:]
        let levels = 5.0

        for i in 0..<(side * side) {
            let o = i * 4
            let a = Double(ptr[o + 3]) / 255.0
            if a < 0.5 { continue }
            // Un-premultiply so translucent edges don't skew toward black.
            let inv = a > 0 ? 1.0 / a : 0
            let r = min(1, Double(ptr[o]) / 255.0 * inv)
            let g = min(1, Double(ptr[o + 1]) / 255.0 * inv)
            let b = min(1, Double(ptr[o + 2]) / 255.0 * inv)

            let (_, s, v) = hsv(r, g, b)
            let weight = (s * s) * v          // prefer saturated + bright; suppress gray/dark
            if weight < 0.02 { continue }

            let key = Int(r * (levels - 1)) * 25 + Int(g * (levels - 1)) * 5 + Int(b * (levels - 1))
            var bin = bins[key] ?? Bin()
            bin.weight += weight
            bin.r += r * weight
            bin.g += g * weight
            bin.b += b * weight
            bins[key] = bin
        }

        guard let best = bins.values.max(by: { $0.weight < $1.weight }), best.weight > 0 else {
            return nil
        }

        // Average color within the winning bin, then push it to a punchy floor so it pops on black.
        var (h, s, v) = hsv(best.r / best.weight, best.g / best.weight, best.b / best.weight)
        s = max(s, 0.45)
        v = max(v, 0.6)
        let (r, g, b) = rgb(h, s, v)
        return Color(red: r, green: g, blue: b)
    }

    // MARK: HSV conversions

    private static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        let v = mx
        let s = mx == 0 ? 0 : d / mx
        var h = 0.0
        if d != 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, s, v)
    }

    private static func rgb(_ h: Double, _ s: Double, _ v: Double) -> (r: Double, g: Double, b: Double) {
        if s == 0 { return (v, v, v) }
        let scaled = h * 6
        let i = Int(scaled) % 6
        let f = scaled - Double(Int(scaled))
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}
