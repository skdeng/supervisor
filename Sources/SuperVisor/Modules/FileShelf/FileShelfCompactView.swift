import SwiftUI

/// Compact trailing contribution for staged files and active shelf operations.
struct FileShelfCompactView: View {
    @ObservedObject var store: FileShelfStore

    var body: some View {
        Group {
            if let item = store.arrivalItem {
                ScreenshotArrivalView(item: item)
                    .id(item.id)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            } else if store.count > 0 || store.hasActiveOperations {
                persistentBadge
            }
        }
        .animation(.snappy(duration: 0.18), value: store.arrivalItem?.id)
    }

    private var persistentBadge: some View {
        HStack(spacing: 4) {
            if store.count > 0 {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(store.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            if store.hasActiveOperations {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.45)
                    .frame(width: 8, height: 8)
                Text("\(store.activeOperationCount)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(NotchTheme.primaryForeground)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(
                    store.didJustReceive
                        ? AnyShapeStyle(NotchTheme.brandGradient.opacity(0.9))
                        : AnyShapeStyle(Color.white.opacity(0.16))
                )
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .scaleEffect(store.didJustReceive ? 1.18 : 1.0)
        .shadow(
            color: store.didJustReceive ? NotchTheme.brandPink.opacity(0.7) : .clear,
            radius: store.didJustReceive ? 6 : 0
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: store.didJustReceive)
        .animation(.snappy, value: store.count)
        .animation(.snappy, value: store.activeOperationCount)
    }
}

private struct ScreenshotArrivalView: View {
    @ObservedObject var item: StagedFile
    @State private var arrived = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(0.12))

            if let thumbnail = item.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NotchTheme.primaryForeground)
            }
        }
        .frame(width: 28, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.white.opacity(arrived ? 0 : 0.8), lineWidth: 1.5)
                .scaleEffect(arrived ? 1.45 : 0.85)
                .opacity(arrived ? 0 : 1)
        }
        .scaleEffect(arrived ? 1 : 1.55)
        .offset(y: arrived ? 0 : 26)
        .rotationEffect(.degrees(arrived ? 0 : -7))
        .opacity(arrived ? 1 : 0.25)
        .onAppear {
            withAnimation(.spring(response: 0.48, dampingFraction: 0.7)) {
                arrived = true
            }
        }
        .help("New screenshot — click the notch to open FileShelf")
    }
}
