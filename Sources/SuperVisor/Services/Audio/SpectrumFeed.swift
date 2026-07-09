import Foundation
import SwiftUI

/// High-rate hand-off between the audio tap's IO thread and the per-frame spectrum views.
///
/// The tap publishes a fresh analysis (~45×/s) and views pull the latest snapshot on each
/// `TimelineView` frame. A lock-protected value box is used instead of `@Published` so audio-rate
/// updates never touch the main-actor observation machinery — views that aren't on screen cost
/// nothing, and views that are read exactly one snapshot per rendered frame.
final class SpectrumFeed: @unchecked Sendable {
    static let shared = SpectrumFeed()

    /// One analysis frame: equalizer band levels in `[0, 1]` and the beat-aura envelope.
    struct Snapshot: Sendable {
        var bars: [Float]
        var aura: Float

        static let silent = Snapshot(
            bars: [Float](repeating: 0, count: SpectrumAnalyzer.bandCount),
            aura: 0
        )
    }

    private let lock = NSLock()
    private var current: Snapshot = .silent

    /// Store a fresh analysis frame. Called from the tap's IO queue.
    func publish(bars: [Float], aura: Float) {
        lock.lock()
        current = Snapshot(bars: bars, aura: aura)
        lock.unlock()
    }

    /// Reset to silence (tap stopped or torn down for a rebuild).
    func clear() {
        lock.lock()
        current = .silent
        lock.unlock()
    }

    /// The latest analysis frame. Called from the main actor, once per rendered frame.
    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}

/// Low-rate, main-actor observable spectrum state: whether the system-audio tap is live and the
/// accent color the spectrum surfaces should tint with. `MediaModule` drives it; the compact
/// equalizer and the notch's beat-aura layer observe it (the aura lives in core UI, which never
/// references modules — this shared service is the decoupling point).
@MainActor
final class SpectrumCenter: ObservableObject {
    static let shared = SpectrumCenter()

    /// True while the system-audio tap is delivering samples, i.e. the live spectrum (and the
    /// aura) have real data behind them.
    @Published private(set) var isCapturing = false

    /// The current artwork's dominant color — the tint for the spectrum bars and aura glow.
    @Published private(set) var accent: Color = MediaArtworkColor.fallback

    func setCapturing(_ capturing: Bool) {
        if isCapturing != capturing { isCapturing = capturing }
    }

    func setAccent(_ color: Color) {
        if accent != color { accent = color }
    }
}
