import SwiftUI

struct FlowCompactView: View {
    @ObservedObject var tracker: FlowTracker

    var body: some View {
        Group {
            switch tracker.compactPresentation {
            case let .finalStretch(progress, elapsed):
                finalStretch(progress: progress, elapsed: elapsed)
            case let .breakCountdown(start, until):
                compactCountdown(start: start, until: until)
            case .recharged:
                rechargedAcknowledgement
            case nil:
                EmptyView()
            }
        }
        .fixedSize()
    }

    private func finalStretch(
        progress: Double,
        elapsed: TimeInterval
    ) -> some View {
        HStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: min(1, max(0, progress)))
                    .stroke(
                        NotchTheme.brandGradient,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 17, height: 17)

            Text(Self.compactDuration(elapsed))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private func compactCountdown(start: Date, until: Date) -> some View {
        HStack(spacing: 5) {
            Circle()
                .stroke(NotchTheme.brandGradient, lineWidth: 2.5)
                .frame(width: 17, height: 17)
                .overlay {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(NotchTheme.brandGradient)
                }
            Text(
                timerInterval: start...until,
                pauseTime: nil,
                countsDown: true,
                showsHours: false
            )
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
        }
    }

    private var rechargedAcknowledgement: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(NotchTheme.brandGradient)
            .shadow(color: NotchTheme.brandColor.opacity(0.9), radius: 6)
            .accessibilityLabel("Recharged")
    }

    private static func compactDuration(_ duration: TimeInterval) -> String {
        let minutes = max(0, Int(duration / 60))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h\(remainder)m"
    }
}

struct FlowPeekBannerView: View {
    @ObservedObject var tracker: FlowTracker

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NotchTheme.brandGradient)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.08)))

            Text(tracker.nudgeMessage ?? "")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(NotchTheme.primaryForeground)
                .lineLimit(1)

            FlowCapsuleButton(
                title: "Take \(tracker.breakLengthMinutes)",
                tooltip: "Start a \(tracker.breakLengthMinutes)-minute break",
                action: tracker.takeBreak
            )
        }
        .padding(.horizontal, 14)
    }
}

struct FlowExpandedView: View {
    @ObservedObject var tracker: FlowTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let window = tracker.breakWindow {
                breakContent(window)
            } else if tracker.isAcknowledgingWithoutSession {
                rechargedContent
            } else if tracker.showsBreakActions {
                breakActions
            }

            let timeline = tracker.timelineSegments
            if !timeline.isEmpty {
                FlowRhythmStrip(segments: timeline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var breakActions: some View {
        HStack(spacing: 8) {
            FlowCapsuleButton(
                title: "Take \(tracker.breakLengthMinutes)",
                tooltip: "Start a \(tracker.breakLengthMinutes)-minute break",
                action: tracker.takeBreak
            )
            FlowCapsuleButton(
                title: "Snooze 10",
                tooltip: "Delay the next break nudge by 10 minutes",
                action: tracker.snooze
            )
            FlowCapsuleButton(
                title: "Skip",
                tooltip: "Suppress break nudges for 60 minutes",
                action: tracker.skip
            )
        }
    }

    private func breakContent(_ window: FlowBreakWindow) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.16), lineWidth: 4)
                Circle()
                    .stroke(NotchTheme.brandGradient, lineWidth: 4)
                Text(
                    timerInterval: window.start...window.until,
                    pauseTime: nil,
                    countsDown: true,
                    showsHours: false
                )
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(NotchTheme.primaryForeground)
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 7) {
                Text("Break in progress")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NotchTheme.primaryForeground)
                FlowCapsuleButton(
                    title: "End break",
                    tooltip: "End the break without a recharge acknowledgement",
                    action: tracker.endBreakEarly
                )
            }
            Spacer()
        }
    }

    private var rechargedContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(NotchTheme.brandGradient)
                .shadow(color: NotchTheme.brandColor.opacity(0.8), radius: 7)
            Text("Recharged")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(NotchTheme.primaryForeground)
            Spacer()
        }
    }

}

private struct FlowCapsuleButton: View {
    let title: String
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.10)))
                .foregroundStyle(NotchTheme.primaryForeground)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .notchTooltip(tooltip)
        .help(tooltip)
    }
}

private struct FlowRhythmStrip: View {
    let segments: [FlowSegment]

    /// Locale-aware hour:minute (e.g. "9:07 AM" or "09:07"), so ticks within one hour stay distinct.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }()

    /// The axis spans the day's first activity to now, so it widens through the day rather than
    /// collapsing onto the recorded segments.
    private var range: ClosedRange<Date> {
        let now = Date()
        let start = segments.map(\.start).min() ?? now
        let end = max(now, segments.map(\.end).max() ?? start)
        return start...max(end, start.addingTimeInterval(60))
    }

    /// Left / optional middle / right ticks, dropping any that render identically to a neighbor —
    /// a short span collapses to a single label instead of repeating the same time three times.
    private func tickLabels(in bounds: ClosedRange<Date>) -> [String] {
        let mid = bounds.lowerBound.addingTimeInterval(
            bounds.upperBound.timeIntervalSince(bounds.lowerBound) / 2
        )
        let left = Self.timeFormatter.string(from: bounds.lowerBound)
        let middle = Self.timeFormatter.string(from: mid)
        let right = Self.timeFormatter.string(from: bounds.upperBound)
        if left == right { return [left] }
        if middle == left || middle == right { return [left, right] }
        return [left, middle, right]
    }

    /// Top-of-hour instants strictly inside the axis, drawn as faint gridlines so the strip reads
    /// as a time-of-day timeline rather than a progress bar.
    private func hourTicks(in bounds: ClosedRange<Date>) -> [Date] {
        let calendar = Calendar.current
        guard let first = calendar.nextDate(
            after: bounds.lowerBound,
            matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) else { return [] }
        var ticks: [Date] = []
        var tick = first
        while tick < bounds.upperBound {
            ticks.append(tick)
            guard let next = calendar.date(byAdding: .hour, value: 1, to: tick) else { break }
            tick = next
        }
        return ticks
    }

    var body: some View {
        let bounds = range
        let duration = max(1, bounds.upperBound.timeIntervalSince(bounds.lowerBound))
        let workBlocks = segments.filter { $0.kind == .work }
        let ticks = hourTicks(in: bounds)
        VStack(spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                    // Work blocks are coloured; breaks are the exposed track between them.
                    ForEach(workBlocks) { segment in
                        let startFraction = segment.start.timeIntervalSince(bounds.lowerBound) / duration
                        let widthFraction = segment.end.timeIntervalSince(segment.start) / duration
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(NotchTheme.brandGradient)
                            .frame(width: max(2, proxy.size.width * widthFraction))
                            .offset(x: proxy.size.width * startFraction)
                    }
                    ForEach(ticks, id: \.self) { tick in
                        let fraction = tick.timeIntervalSince(bounds.lowerBound) / duration
                        Rectangle()
                            .fill(Color.white.opacity(0.22))
                            .frame(width: 1)
                            .offset(x: proxy.size.width * fraction)
                    }
                }
            }
            .frame(height: 7)

            let labels = tickLabels(in: bounds)
            if labels.count == 1 {
                Text(labels[0])
                    .font(.caption2)
                    .foregroundStyle(NotchTheme.secondaryForeground)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                        if index > 0 { Spacer(minLength: 0) }
                        Text(label)
                    }
                }
                .font(.caption2)
                .foregroundStyle(NotchTheme.secondaryForeground)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today's work and break rhythm")
    }
}
