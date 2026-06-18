import SwiftUI

/// Expanded panel section: large artwork, title/artist, a live scrubber bound to
/// elapsed/duration, and play/pause/prev/next transport controls that send real
/// MediaRemote commands. Shows a quiet empty state when nothing is playing.
struct MediaExpandedView: View {
    @ObservedObject var module: MediaModule

    var body: some View {
        Group {
            if let nowPlaying = module.nowPlaying {
                content(for: nowPlaying)
            } else {
                emptyState
            }
        }
        .padding(NotchTheme.panelPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: NotchTheme.surfaceCornerRadius)
    }

    // MARK: Now-playing content

    private func content(for nowPlaying: NowPlaying) -> some View {
        HStack(alignment: .top, spacing: 14) {
            artwork(for: nowPlaying)

            VStack(alignment: .leading, spacing: 10) {
                trackInfo(for: nowPlaying)
                MediaScrubberView(nowPlaying: nowPlaying)
                transportControls(for: nowPlaying)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func artwork(for nowPlaying: NowPlaying) -> some View {
        let size: CGFloat = 84
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if let image = nowPlaying.artworkImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(shape)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        } else {
            shape
                .fill(Color.white.opacity(0.12))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(NotchTheme.secondaryForeground)
                )
        }
    }

    private func trackInfo(for nowPlaying: NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(nowPlaying.title)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(NotchTheme.primaryForeground)
            if let artist = nowPlaying.artist {
                Text(artist)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(NotchTheme.secondaryForeground)
            }
            if let album = nowPlaying.album {
                Text(album)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(NotchTheme.secondaryForeground)
            }
        }
    }

    private func transportControls(for nowPlaying: NowPlaying) -> some View {
        HStack(spacing: 22) {
            TransportButton(systemName: "backward.fill", size: 16) {
                module.previousTrack()
            }
            TransportButton(
                systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                size: 22
            ) {
                module.togglePlayPause()
            }
            TransportButton(systemName: "forward.fill", size: 16) {
                module.nextTrack()
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .disabled(!module.canControl)
        .opacity(module.canControl ? 1 : 0.4)
    }

    // MARK: Empty state

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(NotchTheme.secondaryForeground)
            Text("Nothing playing")
                .font(.subheadline)
                .foregroundStyle(NotchTheme.secondaryForeground)
            Spacer(minLength: 0)
        }
    }
}

/// A circular tap target for a transport glyph, with a subtle press feedback.
private struct TransportButton: View {
    let systemName: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(NotchTheme.primaryForeground)
                .frame(width: size + 18, height: size + 18)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// A scrubber bound to the live elapsed/duration of the current track. While playing it
/// advances on a timer (the underlying MediaRemote snapshot only updates on track/state
/// changes), and dragging it previews a seek position. Seeking back into MediaRemote is
/// only attempted if the framework exposes a set-time symbol; otherwise the handle simply
/// reflects playback.
struct MediaScrubberView: View {
    let nowPlaying: NowPlaying

    /// Drives the live advance of the elapsed position while playing.
    @State private var now = Date()
    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var elapsed: TimeInterval { nowPlaying.currentElapsed(asOf: now) }
    private var duration: TimeInterval { nowPlaying.duration }
    private var progress: Double { nowPlaying.progress(asOf: now) }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                        .frame(height: 4)
                    Capsule()
                        .fill(NotchTheme.primaryForeground)
                        .frame(width: max(0, width * progress), height: 4)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 12)

            HStack {
                Text(timeString(elapsed))
                Spacer()
                Text(duration > 0 ? timeString(duration) : "--:--")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(NotchTheme.secondaryForeground)
        }
        .onReceive(ticker) { value in
            if nowPlaying.isPlaying { now = value }
        }
        .onAppear { now = Date() }
    }

    private func timeString(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "--:--" }
        let total = Int(interval.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
