import SwiftUI

/// The live spectrum equalizer: six thin bars, each driven by a real FFT band of the actual
/// system audio (via `SpectrumFeed`), tinted with the artwork's dominant color.
///
/// Rendering is pull-based: a `TimelineView` redraws per frame and reads the latest analysis
/// snapshot — no observation churn at audio rate. Shown in place of the animated sine bars
/// whenever the system-audio tap is capturing (see `MediaBarsCompactView`).
struct SpectrumBarsView: View {
    /// Bar color — the artwork's dominant color, or white when there's no artwork.
    var tint: Color

    static let barCount = SpectrumAnalyzer.bandCount
    static let barWidth: CGFloat = 1.8
    static let spacing: CGFloat = 1.6
    /// Total natural width of the bar row, used by the compact container's frame.
    static var naturalWidth: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
    }

    /// Minimum visible bar height (as a fraction) so silent bands read as resting dots.
    private let floorScale: CGFloat = 0.12

    var body: some View {
        TimelineView(.animation) { _ in
            let bars = SpectrumFeed.shared.snapshot().bars
            HStack(alignment: .center, spacing: Self.spacing) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(tint)
                        .frame(width: Self.barWidth)
                        .frame(maxHeight: .infinity)
                        .scaleEffect(y: barScale(bars, index), anchor: .center)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: tint)
        }
    }

    private func barScale(_ bars: [Float], _ index: Int) -> CGFloat {
        guard index < bars.count else { return floorScale }
        return max(floorScale, CGFloat(bars[index]))
    }
}
