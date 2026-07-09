import SwiftUI

/// Compact LEADING contribution: the album-art thumbnail (left of the notch).
struct MediaArtworkCompactView: View {
    @ObservedObject var module: MediaModule

    private let artSize: CGFloat = 18

    var body: some View {
        if module.nowPlaying != nil {
            artworkView
                .transition(.opacity.combined(with: .scale))
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        if let image = module.artworkImage {
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

/// Compact TRAILING contribution: the now-playing equalizer (right of the notch).
///
/// While the system-audio tap is capturing, the bars are a real FFT spectrum of what's playing
/// (`SpectrumBarsView`); when the tap is off, denied, or rebuilding, they fall back to the
/// animated sine bars. Both variants share the same six-thin-bar footprint so the swap never
/// changes the pill's layout.
struct MediaBarsCompactView: View {
    @ObservedObject var module: MediaModule
    @ObservedObject private var spectrum = SpectrumCenter.shared

    var body: some View {
        if let nowPlaying = module.nowPlaying {
            Group {
                if spectrum.isCapturing {
                    SpectrumBarsView(tint: module.artworkAccent)
                } else {
                    AudioBarsView(isPlaying: nowPlaying.isPlaying, tint: module.artworkAccent)
                }
            }
            .frame(width: SpectrumBarsView.naturalWidth, height: 18)
            .transition(.opacity.combined(with: .scale))
        }
    }
}

/// A small six-bar equalizer that bounces while playing and rests flat when paused,
/// echoing the iOS now-playing indicator. This is the no-capture fallback: the bounce is
/// synthesized, not audio-driven.
///
/// The bounce is driven by a `TimelineView` rather than a `repeatForever` animation: the
/// timeline ticks per frame while playing and is `paused` when stopped, and the paused branch
/// of `barScale` returns the flat resting height. This sidesteps `repeatForever`'s start/stop
/// fragility (a running repeat can't be cleanly interrupted, and re-arming it after a teardown
/// is unreliable) — pause/resume here is just a function of `isPlaying`.
struct AudioBarsView: View {
    let isPlaying: Bool
    /// Bar color — the artwork's dominant color, or white when there's no artwork.
    var tint: Color = NotchTheme.primaryForeground

    private let barCount = SpectrumBarsView.barCount
    private let barWidth: CGFloat = SpectrumBarsView.barWidth
    private let spacing: CGFloat = SpectrumBarsView.spacing
    /// Flat resting height (as a fraction of the full bar) when paused/stopped.
    private let restScale: CGFloat = 0.35

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(tint)
                        .frame(width: barWidth)
                        .frame(maxHeight: .infinity)
                        .scaleEffect(y: barScale(index, time: time), anchor: .center)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: tint)
        }
    }

    /// Smooth oscillation in `[restScale, 1]` while playing; flat `restScale` when paused.
    /// Each bar has its own period and phase offset so they bounce lively and out of lockstep.
    private func barScale(_ index: Int, time: Double) -> CGFloat {
        guard isPlaying else { return restScale }
        let period = [0.62, 0.5, 0.72, 0.56, 0.66, 0.46][index % 6]  // seconds per up-down cycle
        let phase = [0.0, 0.66, 0.33, 0.15, 0.82, 0.48][index % 6]   // offsets so the bars desync
        let unit = (sin((time / period + phase) * 2 * .pi) + 1) / 2  // 0...1
        return restScale + (1 - restScale) * unit
    }
}
