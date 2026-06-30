import SwiftUI

/// Expanded media section, styled after the system Now-Playing card: artwork beside the
/// title/artist with a now-playing waveform, a full-width scrubber, and a transport row
/// (favorite · previous · play-pause · next · output device). Rendered directly on the sheet's
/// black surface — no card of its own.
struct MediaExpandedView: View {
    @ObservedObject var module: MediaModule
    /// Whether the inline audio-output device list is shown (toggled by the transport-row icon).
    @State private var showOutputPicker = false

    var body: some View {
        Group {
            if let nowPlaying = module.nowPlaying {
                content(for: nowPlaying)
            } else {
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Now-playing content

    private func content(for nowPlaying: NowPlaying) -> some View {
        VStack(spacing: 16) {
            // Header: artwork, title/artist, now-playing waveform.
            HStack(alignment: .top, spacing: 12) {
                artworkView

                VStack(alignment: .leading, spacing: 3) {
                    Text(nowPlaying.title)
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(1)
                        .foregroundStyle(NotchTheme.primaryForeground)
                    if let artist = nowPlaying.artist {
                        Text(artist)
                            .font(.system(size: 15, weight: .regular))
                            .lineLimit(1)
                            .foregroundStyle(NotchTheme.secondaryForeground)
                    }
                }
                .padding(.top, 3)

                Spacer(minLength: 8)

                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(NotchTheme.secondaryForeground)
                    .padding(.top, 5)
            }

            MediaScrubberView(nowPlaying: nowPlaying)

            transportRow(for: nowPlaying)

            if showOutputPicker {
                AudioOutputDeviceList(controller: module.audioOutput) {
                    showOutputPicker = false
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showOutputPicker)
    }

    @ViewBuilder
    private var artworkView: some View {
        let size: CGFloat = 80
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if let image = module.artworkImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(shape)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
        } else {
            shape
                .fill(Color.white.opacity(0.12))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(NotchTheme.secondaryForeground)
                )
        }
    }

    // MARK: Transport

    private func transportRow(for nowPlaying: NowPlaying) -> some View {
        // The play/prev/next triad stays centered; the output-route icon sits at the trailing
        // edge as a separate layer so it isn't dimmed/disabled by the `canControl` gate.
        ZStack {
            HStack(spacing: 44) {
                TransportButton(systemName: "backward.fill", size: 22) { module.previousTrack() }
                TransportButton(
                    systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                    size: 28
                ) { module.togglePlayPause() }
                TransportButton(systemName: "forward.fill", size: 22) { module.nextTrack() }
            }
            .disabled(!module.canControl)
            .opacity(module.canControl ? 1 : 0.4)

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                OutputRouteButton(controller: module.audioOutput, active: showOutputPicker) {
                    showOutputPicker.toggle()
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A circular tap target for a transport glyph.
private struct TransportButton: View {
    let systemName: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(NotchTheme.primaryForeground)
                .frame(width: size + 14, height: size + 14)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// A full-width scrubber row: elapsed time, a progress bar, and total duration on one line.
/// While playing, the elapsed position advances on a timer (the underlying MediaRemote
/// snapshot only refreshes on track/state changes).
struct MediaScrubberView: View {
    let nowPlaying: NowPlaying

    @State private var now = Date()
    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var elapsed: TimeInterval { nowPlaying.currentElapsed(asOf: now) }
    private var duration: TimeInterval { nowPlaying.duration }
    private var progress: Double { nowPlaying.progress(asOf: now) }

    var body: some View {
        HStack(spacing: 10) {
            Text(timeString(elapsed))
                .frame(minWidth: 34, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(height: 5)
                    Capsule()
                        .fill(NotchTheme.primaryForeground.opacity(0.9))
                        .frame(width: max(0, geo.size.width * progress), height: 5)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 8)
            Text(duration > 0 ? timeString(duration) : "--:--")
                .frame(minWidth: 34, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(NotchTheme.secondaryForeground)
        .onReceive(ticker) { value in
            if nowPlaying.isPlaying { now = value }
        }
        .onAppear { now = Date() }
    }

    private func timeString(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "--:--" }
        let total = Int(interval.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
