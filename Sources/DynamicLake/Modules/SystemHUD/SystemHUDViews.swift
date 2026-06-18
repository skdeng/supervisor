import SwiftUI

/// The facet currently being presented in the compact HUD.
enum SystemHUDFacet: Equatable {
    case volume(muted: Bool)
    case brightness
    case keyboardBacklight

    /// SF Symbol for the facet, reflecting the current level so the glyph reads correctly.
    func symbol(level: Float) -> String {
        switch self {
        case .volume(let muted):
            if muted || level <= 0.001 { return "speaker.slash.fill" }
            if level < 0.34 { return "speaker.wave.1.fill" }
            if level < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .brightness:
            return "sun.max.fill"
        case .keyboardBacklight:
            return "keyboard.fill"
        }
    }
}

/// The transient level indicator shown trailing of the notch while a value is changing:
/// an icon plus a thin segmented level bar. Animates as the bound level changes.
struct SystemHUDCompactLevelBar: View {
    let facet: SystemHUDFacet
    let level: Float

    private let segmentCount = 16

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: facet.symbol(level: level))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchTheme.primaryForeground)
                .frame(width: 16)
                .contentTransition(.symbolEffect(.replace))

            GeometryReader { geo in
                let filled = Int((level * Float(segmentCount)).rounded())
                HStack(spacing: 1.5) {
                    ForEach(0..<segmentCount, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(
                                index < filled
                                    ? NotchTheme.primaryForeground
                                    : NotchTheme.primaryForeground.opacity(0.18)
                            )
                    }
                }
                .frame(height: geo.size.height)
            }
            .frame(width: 56, height: 6)
        }
        .padding(.horizontal, NotchTheme.compactSidePadding)
        .animation(.easeOut(duration: 0.18), value: level)
        .animation(.easeOut(duration: 0.18), value: facet)
    }
}

/// A single labeled slider row used in the expanded panel. The slider writes back to the
/// system through `onChange` as the user drags.
struct SystemHUDSliderRow: View {
    let symbol: String
    let title: String
    @Binding var value: Double
    let onChange: (Double) -> Void
    var trailingControl: AnyView? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotchTheme.primaryForeground)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NotchTheme.primaryForeground)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 11, weight: .regular).monospacedDigit())
                    .foregroundStyle(NotchTheme.secondaryForeground)
                if let trailingControl { trailingControl }
            }

            Slider(
                value: Binding(
                    get: { value },
                    set: { newValue in
                        value = newValue
                        onChange(newValue)
                    }
                ),
                in: 0...1
            )
            .controlSize(.small)
            .tint(NotchTheme.primaryForeground)
        }
    }
}
