import SwiftUI

/// The output-route trigger: an icon reflecting the current output device kind. Tapping it hands
/// the whole sheet to the device list (`SheetTakeoverCenter`), which hands it back once a device
/// is chosen. Lives in its own view so it observes the controller directly and updates its glyph
/// when the route changes.
struct OutputRouteButton: View {
    @ObservedObject var controller: AudioOutputController

    private static let takeoverID = "audio-output"

    var body: some View {
        let tooltip = "Audio output: \(controller.currentName.isEmpty ? "Unknown" : controller.currentName)"
        Button {
            SheetTakeoverCenter.shared.present(
                id: Self.takeoverID,
                title: "Audio Output",
                content: AnyView(AudioOutputDeviceList(controller: controller) {
                    SheetTakeoverCenter.shared.dismiss(id: Self.takeoverID)
                })
            )
        } label: {
            Image(systemName: AudioOutputDeviceList.icon(for: controller.currentName))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(NotchTheme.primaryForeground)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .notchTooltip(tooltip)
        .help(tooltip)
    }
}

/// The list of available audio output devices, presented as a sheet takeover. A list in the
/// sheet (rather than an `NSMenu`) is used deliberately: the notch panel is a non-activating
/// window that never becomes key, so a popup menu can't reliably take focus.
struct AudioOutputDeviceList: View {
    @ObservedObject var controller: AudioOutputController
    /// Called after a device is chosen, so the presenter can dismiss the list.
    var onSelect: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            ForEach(controller.devices) { device in
                deviceRow(device)
                if device.id != controller.devices.last?.id {
                    Divider().overlay(NotchTheme.separator)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func deviceRow(_ device: AudioOutputController.Device) -> some View {
        let isCurrent = device.id == controller.currentDeviceID
        return Button {
            controller.select(device.id)
            onSelect()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: Self.icon(for: device.name))
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 22)
                    .foregroundStyle(
                        isCurrent
                            ? AnyShapeStyle(NotchTheme.brandGradient)
                            : AnyShapeStyle(NotchTheme.secondaryForeground)
                    )
                Text(device.name)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(NotchTheme.primaryForeground)
                Spacer(minLength: 6)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(NotchTheme.brandGradient)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Pick an SF Symbol that roughly matches the device kind from its name.
    static func icon(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpod") { return "airpodspro" }
        if n.contains("headphone") || n.contains("beats") { return "headphones" }
        if n.contains("homepod") { return "homepod.fill" }
        if n.contains("apple tv") || n.hasSuffix(" tv") { return "appletv.fill" }
        if n.contains("display") || n.contains("monitor") || n.contains("studio") { return "speaker.wave.2.fill" }
        if n.contains("macbook") || n.contains("built-in") || n.contains("internal") { return "laptopcomputer" }
        return "hifispeaker.fill"
    }
}
