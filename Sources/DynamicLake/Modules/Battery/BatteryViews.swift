import SwiftUI

/// A compact circular battery ring used in the collapsed pill. Shows the charge fraction as a
/// stroked arc with a tint that reflects state (green charging, red critical, amber low) and a
/// small bolt glyph while charging.
struct BatteryRingView: View {
    let fraction: Double
    let isCharging: Bool
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, min(1.0, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: fraction)

            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// The expanded status card: battery summary plus a list of connected Bluetooth devices and
/// their battery levels, rendered on an inner Liquid Glass surface.
struct BatteryStatusCard: View {
    let battery: BatteryState
    let devices: [BluetoothDeviceInfo]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if battery.isPresent {
                batteryRow
            }

            if !devices.isEmpty {
                Divider().overlay(NotchTheme.separator)
                ForEach(devices) { device in
                    deviceRow(device)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: NotchTheme.surfaceCornerRadius)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "battery.100")
                .font(.system(size: 14, weight: .semibold))
            Text("Power")
                .font(.headline)
            Spacer()
        }
        .foregroundStyle(NotchTheme.primaryForeground)
    }

    private var batteryRow: some View {
        HStack(spacing: 12) {
            BatteryRingView(
                fraction: battery.fraction ?? 0,
                isCharging: battery.isCharging,
                tint: tint
            )
            .scaleEffect(26.0 / 16.0)
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(percentText)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(NotchTheme.primaryForeground)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(NotchTheme.secondaryForeground)
            }
            Spacer()
        }
    }

    private func deviceRow(_ device: BluetoothDeviceInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: glyph(for: device.name))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(NotchTheme.secondaryForeground)
                .frame(width: 18)
            Text(device.name)
                .font(.subheadline)
                .foregroundStyle(NotchTheme.primaryForeground)
                .lineLimit(1)
            Spacer()
            if let percent = device.batteryPercent {
                Text("\(percent)%")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(NotchTheme.secondaryForeground)
            }
        }
    }

    private var percentText: String {
        if let percent = battery.percent { return "\(percent)%" }
        return "—"
    }

    private var statusText: String {
        if battery.isCharged && battery.isPluggedIn {
            return "Charged"
        }
        if battery.isCharging {
            if let s = battery.secondsRemaining {
                return "Charging · \(Self.timeString(s)) to full"
            }
            return "Charging"
        }
        if battery.isPluggedIn {
            return "Plugged in"
        }
        if let s = battery.secondsRemaining {
            return "\(Self.timeString(s)) remaining"
        }
        return "On battery"
    }

    /// Pick a representative SF Symbol for a device based on its name.
    private func glyph(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpod") || lower.contains("headphone") || lower.contains("buds") {
            return "airpodspro"
        }
        if lower.contains("mouse") { return "magicmouse" }
        if lower.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if lower.contains("keyboard") { return "keyboard" }
        return "dot.radiowaves.left.and.right"
    }

    /// Format a seconds estimate as "Xh Ym" / "Ym".
    static func timeString(_ seconds: Int) -> String {
        let minutes = max(0, seconds / 60)
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
