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
struct AudioBarsView: View {
    let isPlaying: Bool

    private let barCount = 3
    private let barWidth: CGFloat = 2.5
    private let spacing: CGFloat = 2

    /// Per-bar animation phase so each bar bounces out of sync.
    @State private var animate = false

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(NotchTheme.primaryForeground)
                    .frame(width: barWidth)
                    .frame(maxHeight: .infinity)
                    .scaleEffect(y: barScale(index), anchor: .center)
                    .animation(
                        isPlaying
                            ? .easeInOut(duration: duration(index))
                                .repeatForever(autoreverses: true)
                            : .easeOut(duration: 0.2),
                        value: animate
                    )
            }
        }
        .onAppear { animate = isPlaying }
        .onChange(of: isPlaying) { _, playing in
            animate = playing
        }
    }

    /// Tall when animating (alternating per-bar so they don't move in lockstep),
    /// short and uniform when paused.
    private func barScale(_ index: Int) -> CGFloat {
        guard isPlaying else { return 0.35 }
        // When `animate` toggles, even/odd bars are at opposite extremes.
        let high: CGFloat = 1.0
        let low: CGFloat = 0.35
        let isEven = index % 2 == 0
        if animate {
            return isEven ? high : low
        } else {
            return isEven ? low : high
        }
    }

    private func duration(_ index: Int) -> Double {
        // Slightly different periods per bar for a livelier, less mechanical motion.
        [0.5, 0.42, 0.58][index % 3]
    }
}
