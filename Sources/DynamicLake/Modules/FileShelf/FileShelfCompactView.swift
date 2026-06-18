import SwiftUI

/// Compact trailing contribution: a small badge showing the staged file count. Pulses
/// (scale + glow) briefly when a new file is dropped so the user sees the shelf react even
/// without expanding. Renders nothing when the shelf is empty (the module returns nil then,
/// but the guard here keeps the view self-consistent).
struct FileShelfCompactView: View {
    @ObservedObject var store: FileShelfStore

    var body: some View {
        if store.count > 0 {
            HStack(spacing: 4) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(store.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(NotchTheme.primaryForeground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(store.didJustReceive ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.16))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .scaleEffect(store.didJustReceive ? 1.18 : 1.0)
            .shadow(
                color: store.didJustReceive ? Color.accentColor.opacity(0.7) : .clear,
                radius: store.didJustReceive ? 6 : 0
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: store.didJustReceive)
            .animation(.snappy, value: store.count)
        }
    }
}
