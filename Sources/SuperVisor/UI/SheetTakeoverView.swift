import SwiftUI

/// The chrome around a sheet takeover: a back button and title above the presenter's content.
struct SheetTakeoverView: View {
    let takeover: SheetTakeoverCenter.Takeover
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(NotchTheme.primaryForeground)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .notchTooltip("Back")
                .help("Back")

                Text(takeover.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NotchTheme.primaryForeground)
                Spacer(minLength: 0)
            }
            // Align the chevron's glyph, not its tap target, with the content's leading edge.
            .padding(.leading, -8)

            takeover.content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
