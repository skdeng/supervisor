import SwiftUI

/// Compact trailing contribution: a small progress ring while one or more conversions run.
/// Shows determinate progress when total durations are known, falling back to an
/// indeterminate spinner otherwise. A small badge appears when more than one job is active.
struct ConversionCompactView: View {
    @ObservedObject var module: ConversionModule

    private let ringSize: CGFloat = 16
    private let lineWidth: CGFloat = 2.4

    var body: some View {
        HStack(spacing: 5) {
            ring
            if activeCount > 1 {
                Text("\(activeCount)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(NotchTheme.primaryForeground)
                    .monospacedDigit()
            }
        }
        .help(helpText)
    }

    private var activeCount: Int { module.activeTasks.count }

    @ViewBuilder
    private var ring: some View {
        if let fraction = module.aggregateProgress {
            ZStack {
                Circle()
                    .stroke(NotchTheme.separator, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(
                        NotchTheme.primaryForeground,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.25), value: fraction)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(NotchTheme.primaryForeground)
            }
            .frame(width: ringSize, height: ringSize)
        } else {
            IndeterminateRing(size: ringSize, lineWidth: lineWidth)
        }
    }

    private var helpText: String {
        if activeCount == 1, let only = module.activeTasks.first {
            return "Converting \(only.job.sourceName)"
        }
        return "Converting \(activeCount) files"
    }
}

/// A continuously rotating partial ring used for indeterminate conversion progress.
private struct IndeterminateRing: View {
    let size: CGFloat
    let lineWidth: CGFloat
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(NotchTheme.separator, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(
                    NotchTheme.primaryForeground,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(
                    .linear(duration: 0.9).repeatForever(autoreverses: false),
                    value: spinning
                )
        }
        .frame(width: size, height: size)
        .onAppear { spinning = true }
    }
}
