import SwiftUI

// MARK: - Compact ring

/// Compact trailing contribution: a circular countdown ring with the remaining time of the
/// soonest active timer. Re-renders live via the observed store (`tickToken` drives the
/// once-per-second readout; the ring fill is recomputed from the wall clock each tick).
struct TimerCompactRing: View {
    @ObservedObject var store: TimersStore

    var body: some View {
        // Reading `tickToken` here ties this subtree to the per-second refresh.
        let _ = store.tickToken
        if let alertLabel = store.completionAlertLabel {
            HStack(spacing: 5) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.orange)
                Text("Time's up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NotchTheme.primaryForeground)
                    .lineLimit(1)
                if !alertLabel.isEmpty {
                    Text("• \(alertLabel)")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(NotchTheme.secondaryForeground)
                        .lineLimit(1)
                }
            }
            .fixedSize()
        } else if let timer = store.soonestRunning {
            let now = Date()
            let remaining = timer.remaining(at: now)
            let progress = timer.progress(at: now)

            HStack(spacing: 5) {
                ZStack {
                    Circle()
                        .stroke(NotchTheme.separator, lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: max(0.001, 1 - progress))
                        .stroke(
                            Color.orange,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "hourglass")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(NotchTheme.secondaryForeground)
                }
                .frame(width: 16, height: 16)

                Text(CountdownTimer.formatRemaining(remaining))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(NotchTheme.primaryForeground)
            }
            .fixedSize()
        }
    }
}

// MARK: - Expanded section

/// Expanded panel contribution: the active/paused/completed timer list plus the add control.
struct TimerExpandedSection: View {
    @ObservedObject var store: TimersStore

    var body: some View {
        let _ = store.tickToken
        VStack(alignment: .leading, spacing: 10) {
            header

            if store.timers.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    ForEach(store.sortedForDisplay) { timer in
                        TimerRow(timer: timer, store: store)
                    }
                }
            }

            TimerAddControl(store: store)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: NotchTheme.surfaceCornerRadius)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.system(size: 13, weight: .semibold))
            Text("Timers")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if !store.runningTimers.isEmpty {
                Text("\(store.runningTimers.count) running")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NotchTheme.secondaryForeground)
            }
        }
    }

    private var emptyState: some View {
        Text("No timers yet")
            .font(.system(size: 12))
            .foregroundStyle(NotchTheme.secondaryForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }
}

// MARK: - Single timer row

private struct TimerRow: View {
    let timer: CountdownTimer
    @ObservedObject var store: TimersStore

    var body: some View {
        let now = Date()
        let remaining = timer.remaining(at: now)
        let progress = timer.progress(at: now)

        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(NotchTheme.separator, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.001, 1 - progress))
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(timer.displayLabel)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(subtitle(remaining: remaining))
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(NotchTheme.secondaryForeground)
            }

            Spacer(minLength: 8)

            controls
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private var ringColor: Color {
        switch timer.state {
        case .running: return .orange
        case .paused: return .yellow.opacity(0.7)
        case .completed: return .green
        }
    }

    private func subtitle(remaining: TimeInterval) -> String {
        switch timer.state {
        case .running:
            return CountdownTimer.formatRemaining(remaining)
        case .paused:
            return "Paused • " + CountdownTimer.formatRemaining(remaining)
        case .completed:
            return "Done"
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 6) {
            switch timer.state {
            case .running:
                iconButton("pause.fill", help: "Pause") { store.pause(timer.id) }
                iconButton("xmark", help: "Cancel") { store.cancel(timer.id) }
            case .paused:
                iconButton("play.fill", help: "Resume") { store.resume(timer.id) }
                iconButton("xmark", help: "Cancel") { store.cancel(timer.id) }
            case .completed:
                iconButton("arrow.clockwise", help: "Restart") { store.restart(timer.id) }
                iconButton("xmark", help: "Dismiss") { store.dismissCompleted(timer.id) }
            }
        }
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(NotchTheme.primaryForeground)
        .help(help)
    }
}

// MARK: - Add control

/// Quick presets plus a custom minute/second entry to create a new timer.
private struct TimerAddControl: View {
    @ObservedObject var store: TimersStore

    @State private var showingCustom = false
    @State private var customMinutes = ""
    @State private var customSeconds = ""
    @FocusState private var minutesFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(TimersStore.presetsMinutes, id: \.self) { minutes in
                    presetButton(minutes)
                }
                customToggleButton
            }

            if showingCustom {
                customEntry
            }
        }
    }

    private func presetButton(_ minutes: Int) -> some View {
        Button {
            store.addTimer(duration: TimeInterval(minutes * 60))
        } label: {
            Text("\(minutes)m")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(NotchTheme.primaryForeground)
    }

    private var customToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                showingCustom.toggle()
            }
            if showingCustom {
                DispatchQueue.main.async { minutesFocused = true }
            }
        } label: {
            Image(systemName: showingCustom ? "chevron.up" : "plus")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 32, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.orange.opacity(0.85))
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.black)
        .help("Custom timer")
    }

    private var customEntry: some View {
        HStack(spacing: 6) {
            numberField("min", text: $customMinutes)
                .focused($minutesFocused)
            Text(":")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(NotchTheme.secondaryForeground)
            numberField("sec", text: $customSeconds)

            Button(action: startCustom) {
                Text("Start")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(height: 28)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(customDuration > 0 ? Color.orange.opacity(0.85) : Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(customDuration > 0 ? .black : NotchTheme.secondaryForeground)
            .disabled(customDuration <= 0)
        }
    }

    private func numberField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .monospacedDigit()
            .frame(width: 46, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .onChange(of: text.wrappedValue) { _, newValue in
                text.wrappedValue = String(newValue.filter(\.isNumber).prefix(3))
            }
            .onSubmit(startCustom)
    }

    private var customDuration: TimeInterval {
        let m = Int(customMinutes) ?? 0
        let s = Int(customSeconds) ?? 0
        return TimeInterval(m * 60 + s)
    }

    private func startCustom() {
        let duration = customDuration
        guard duration > 0 else { return }
        store.addTimer(duration: duration)
        customMinutes = ""
        customSeconds = ""
        withAnimation(.easeInOut(duration: 0.15)) {
            showingCustom = false
        }
    }
}
