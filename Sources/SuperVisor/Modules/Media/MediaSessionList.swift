import SwiftUI

/// Every app's now-playing session, presented as a sheet takeover. Each row carries its own
/// play/pause; tapping a row makes that session the one the notch presents and hands the sheet
/// back.
struct MediaSessionList: View {
    @ObservedObject var module: MediaModule

    var body: some View {
        VStack(spacing: 0) {
            ForEach(module.sessions, id: \.sessionID) { session in
                row(for: session)
                if session.sessionID != module.sessions.last?.sessionID {
                    Divider().overlay(NotchTheme.separator)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .onChange(of: module.sessions.isEmpty) { _, isEmpty in
            // The last session ended while the list was open: nothing left to list.
            if isEmpty { dismiss() }
        }
    }

    private func dismiss() {
        SheetTakeoverCenter.shared.dismiss(id: MediaModule.sessionsTakeoverID)
    }

    private func row(for session: NowPlaying) -> some View {
        let isPresented = session.sessionID == module.nowPlaying?.sessionID
        return HStack(spacing: 10) {
            Button {
                module.select(sessionID: session.sessionID)
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    artwork(for: session)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title)
                            .font(.system(size: 13, weight: isPresented ? .semibold : .regular))
                            .lineLimit(1)
                            .foregroundStyle(NotchTheme.primaryForeground)
                        if let detail = Self.detail(for: session) {
                            Text(detail)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .foregroundStyle(NotchTheme.secondaryForeground)
                        }
                    }

                    Spacer(minLength: 6)

                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(NotchTheme.brandGradient)
                        .opacity(isPresented ? 1 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            let canToggle = module.canToggle(session)
            Button {
                module.togglePlayPause(sessionID: session.sessionID)
            } label: {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NotchTheme.primaryForeground)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canToggle)
            .opacity(canToggle ? 1 : 0.4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func artwork(for session: NowPlaying) -> some View {
        let size: CGFloat = 38
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        if let image = module.sessionArtwork[session.sessionID] {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(shape)
        } else {
            shape
                .fill(Color.white.opacity(0.12))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(NotchTheme.secondaryForeground)
                )
        }
    }

    /// "Artist · App", or whichever of the two the session carries.
    nonisolated static func detail(for session: NowPlaying) -> String? {
        let parts = [session.artist, session.appName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
