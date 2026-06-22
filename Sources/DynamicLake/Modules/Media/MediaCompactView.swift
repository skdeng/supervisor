import SwiftUI

/// Compact LEADING contribution: the album-art thumbnail (left of the notch).
struct MediaArtworkCompactView: View {
    @ObservedObject var module: MediaModule

    private let artSize: CGFloat = 18

    var body: some View {
        if let nowPlaying = module.nowPlaying {
            artwork(for: nowPlaying)
                .transition(.opacity.combined(with: .scale))
        }
    }

    @ViewBuilder
    private func artwork(for nowPlaying: NowPlaying) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        if let image = nowPlaying.artworkImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: artSize, height: artSize)
                .clipShape(shape)
        } else {
            shape
                .fill(Color.white.opacity(0.18))
                .frame(width: artSize, height: artSize)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(NotchTheme.primaryForeground)
                )
        }
    }
}

/// Compact TRAILING contribution: the now-playing audio-bars equalizer (right of the notch).
/// The bars animate while playing and rest flat when paused.
struct MediaBarsCompactView: View {
    @ObservedObject var module: MediaModule

    var body: some View {
        if let nowPlaying = module.nowPlaying {
            AudioBarsView(isPlaying: nowPlaying.isPlaying)
                .frame(width: 14, height: 18)
                .transition(.opacity.combined(with: .scale))
        }
    }
}

/// A small three-bar equalizer that bounces while playing and rests flat when paused,
/// echoing the iOS now-playing indicator.
///
/// The bounce is driven by a `TimelineView` rather than a `repeatForever` animation: the
/// timeline ticks per frame while playing and is `paused` when stopped, and the paused branch
/// of `barScale` returns the flat resting height. This sidesteps `repeatForever`'s start/stop
/// fragility (a running repeat can't be cleanly interrupted, and re-arming it after a teardown
/// is unreliable) — pause/resume here is just a function of `isPlaying`.
struct AudioBarsView: View {
    let isPlaying: Bool

    private let barCount = 3
    private let barWidth: CGFloat = 2.5
    private let spacing: CGFloat = 2
    /// Flat resting height (as a fraction of the full bar) when paused/stopped.
    private let restScale: CGFloat = 0.35

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(NotchTheme.primaryForeground)
                        .frame(width: barWidth)
                        .frame(maxHeight: .infinity)
                        .scaleEffect(y: barScale(index, time: time), anchor: .center)
                }
            }
        }
    }

    /// Smooth oscillation in `[restScale, 1]` while playing; flat `restScale` when paused.
    /// Each bar has its own period and phase offset so they bounce lively and out of lockstep.
    private func barScale(_ index: Int, time: Double) -> CGFloat {
        guard isPlaying else { return restScale }
        let period = [0.62, 0.5, 0.72][index % 3]   // seconds per full up-down cycle
        let phase = [0.0, 0.66, 0.33][index % 3]    // fractional offset so the bars desync
        let unit = (sin((time / period + phase) * 2 * .pi) + 1) / 2  // 0...1
        return restScale + (1 - restScale) * unit
    }
}
