import SwiftUI

/// The expanded Meeting Mode block shown while a meeting is in progress: the meeting rendered in
/// the agenda's row style (calendar-accent dot, green live timing) so it reads as the lead row of
/// the meeting list, above a global mic-mute toggle, a quick audio-output switcher, and a Join
/// button. Surfaces only when the ongoing event has a detected join link.
struct MeetingHUDView: View {
    let meeting: CalendarEvent
    @ObservedObject var mic: MicController
    @ObservedObject var audioOutput: AudioOutputController
    let onJoin: (URL) -> Void
    let onToggleMute: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            CallAudioControls(
                mic: mic,
                audioOutput: audioOutput,
                onToggleMute: onToggleMute
            ) {
                if let url = meeting.joinURL {
                    joinButton(url: url)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        // Anchor from the meeting's start (a stable instant) so the per-second cadence isn't
        // re-anchored each time the enclosing section's timeline rebuilds this view.
        TimelineView(.periodic(from: meeting.start, by: 1)) { context in
            HStack(spacing: NotchTheme.rowMarkerGap) {
                Circle()
                    .fill(meeting.accent)
                    .frame(width: 8, height: 8)
                    .frame(width: NotchTheme.rowMarkerWidth)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(NotchTheme.primaryForeground)
                    Text(timing(now: context.date))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.green)
                }
                Spacer(minLength: 6)
                if let provider = meeting.provider {
                    Text(provider.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(NotchTheme.secondaryForeground)
                }
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: NotchTheme.rowActionSize, height: NotchTheme.rowActionSize)
                        .foregroundStyle(NotchTheme.secondaryForeground)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .notchTooltip("Dismiss meeting")
                .help("Dismiss meeting")
            }
        }
    }

    private func joinButton(url: URL) -> some View {
        Button {
            onJoin(url)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "video.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("Join")
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(NotchTheme.brandGradient))
            .foregroundStyle(.white)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .notchTooltip("Join meeting")
        .help("Join meeting")
    }

    /// "12:34 · ends in 18m" while running; just the elapsed clock once it runs over.
    private func timing(now: Date) -> String {
        let elapsed = Self.clock(now.timeIntervalSince(meeting.start))
        let remaining = meeting.end.timeIntervalSince(now)
        if remaining > 0 {
            return "\(elapsed) · ends in \(max(1, Int((remaining / 60).rounded(.up))))m"
        }
        return elapsed
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// Meeting Mode for a call detected from camera or microphone use, with the same microphone and
/// output controls as a scheduled meeting and no event-specific actions.
struct AdHocCallHUDView: View {
    let startedAt: Date
    @ObservedObject var mic: MicController
    @ObservedObject var audioOutput: AudioOutputController
    let onToggleMute: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                HStack(spacing: NotchTheme.rowMarkerGap) {
                    // A detected call has no calendar, so green — the live semantic the agenda
                    // rows use for their timing line — stands in for the accent dot.
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .frame(width: NotchTheme.rowMarkerWidth)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("On a call")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .foregroundStyle(NotchTheme.primaryForeground)
                        Text(MeetingHUDView.clock(context.date.timeIntervalSince(startedAt)))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(Color.green)
                    }
                    Spacer(minLength: 6)
                }
            }

            CallAudioControls(
                mic: mic,
                audioOutput: audioOutput,
                onToggleMute: onToggleMute
            ) {
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shared microphone and output-route controls for scheduled and detected calls.
private struct CallAudioControls<Trailing: View>: View {
    @ObservedObject var mic: MicController
    @ObservedObject var audioOutput: AudioOutputController
    let onToggleMute: () -> Void
    let trailing: Trailing

    @State private var showOutputPicker = false

    init(
        mic: MicController,
        audioOutput: AudioOutputController,
        onToggleMute: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.mic = mic
        self.audioOutput = audioOutput
        self.onToggleMute = onToggleMute
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                muteButton
                OutputRouteButton(controller: audioOutput, active: showOutputPicker) {
                    showOutputPicker.toggle()
                }
                Spacer(minLength: 6)
                trailing
            }
            if showOutputPicker {
                AudioOutputDeviceList(controller: audioOutput) {
                    showOutputPicker = false
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showOutputPicker)
    }

    private var muteButton: some View {
        let tooltip = mic.isMuted ? "Unmute microphone" : "Mute microphone"
        return Button(action: onToggleMute) {
            HStack(spacing: 6) {
                Image(systemName: mic.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 12, weight: .bold))
                Text(mic.isMuted ? "Muted" : "Mic on")
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(
                    mic.isMuted ? Color.red.opacity(0.9) : Color.white.opacity(0.12)
                )
            )
            .foregroundStyle(mic.isMuted ? Color.white : NotchTheme.primaryForeground)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!mic.hasInput)
        .opacity(mic.hasInput ? 1 : 0.4)
        .notchTooltip(tooltip)
        .help(tooltip)
    }
}

/// The full calendar expanded section: the Meeting Mode HUD on top when a meeting is in
/// progress, followed by the agenda of remaining upcoming meetings. Observes the service so the
/// HUD appears/disappears and the agenda stays live as the clock advances.
struct CalendarSection: View {
    @ObservedObject var service: CalendarService
    @ObservedObject var dismissals: MeetingDismissalStore
    @ObservedObject var mic: MicController
    @ObservedObject var audioOutput: AudioOutputController
    @ObservedObject var callMonitor: CallActivityMonitor
    let onJoin: (URL) -> Void
    let onToggleMute: () -> Void
    let onDismiss: (CalendarEvent) -> Void
    let onRestore: (String) -> Void

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 5)) { context in
            let active = service.activeMeeting(asOf: context.date)
            let upcoming = service.events.filter { $0.id != active?.id }
            VStack(spacing: 10) {
                if let active {
                    MeetingHUDView(
                        meeting: active,
                        mic: mic,
                        audioOutput: audioOutput,
                        onJoin: onJoin,
                        onToggleMute: onToggleMute,
                        onDismiss: { onDismiss(active) }
                    )
                } else if callMonitor.isCallLikely,
                          let adHocCallStartedAt = callMonitor.callStartedAt {
                    AdHocCallHUDView(
                        startedAt: adHocCallStartedAt,
                        mic: mic,
                        audioOutput: audioOutput,
                        onToggleMute: onToggleMute
                    )
                } else if service.isDenied {
                    CalendarAccessPromptView()
                }
                if !upcoming.isEmpty || !dismissals.dismissed.isEmpty {
                    CalendarAgendaView(
                        events: upcoming,
                        dismissals: dismissals,
                        onJoin: onJoin,
                        onDismiss: onDismiss,
                        onRestore: onRestore
                    )
                }
            }
        }
    }
}
