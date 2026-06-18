import AppKit
import SwiftUI

// MARK: - Compact

/// Leading compact contribution: an imminent-event countdown chip when one exists, otherwise
/// the current temperature with a condition glyph. Observes the module so it re-renders on
/// `clockTick` and on service updates.
struct GlanceCompactView: View {
    @ObservedObject var module: GlanceModule

    var body: some View {
        Group {
            if let event = module.calendar.imminentEvent {
                eventChip(event)
            } else if let snapshot = module.weather.snapshot {
                weatherChip(snapshot)
            } else {
                EmptyView()
            }
        }
        // `clockTick` is observed so the countdown re-evaluates on each tick.
        .id(module.clockTick)
    }

    private func eventChip(_ event: GlanceEvent) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NotchTheme.secondaryForeground)
            Text(GlanceFormatting.compactTitle(event.title))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Text(GlanceFormatting.compactCountdown(to: event.startDate))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tint)
        }
        .tint(.green)
        .fixedSize()
    }

    private func weatherChip(_ snapshot: WeatherSnapshot) -> some View {
        HStack(spacing: 4) {
            Image(systemName: snapshot.symbolName)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 11, weight: .medium))
            Text(snapshot.temperatureText)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .fixedSize()
    }
}

// MARK: - Expanded

/// The module's expanded-panel section: a weather card and a short list of upcoming events,
/// with inline permission prompts when access is missing.
struct GlanceExpandedView: View {
    @ObservedObject var module: GlanceModule

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            WeatherCard(weather: module.weather)
                .id(module.clockTick)

            EventList(calendar: module.calendar, tick: module.clockTick)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchTheme.secondaryForeground)
            Text("Glance")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if module.weather.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}

// MARK: Weather card

private struct WeatherCard: View {
    @ObservedObject var weather: WeatherService

    var body: some View {
        Group {
            switch weather.authState {
            case .authorized:
                if let snapshot = weather.snapshot {
                    content(snapshot)
                } else {
                    loadingOrError
                }
            case .notDetermined:
                PermissionPrompt(
                    symbol: "location.fill",
                    message: "Allow location to show local weather.",
                    actionTitle: "Allow",
                    action: { weather.requestAuthorization() }
                )
            case .denied:
                PermissionPrompt(
                    symbol: "location.slash.fill",
                    message: "Location access is off. Enable it for weather.",
                    actionTitle: "Open Settings",
                    action: { SystemSettings.openLocationServices() }
                )
            case .unavailable:
                PermissionPrompt(
                    symbol: "exclamationmark.triangle.fill",
                    message: "Weather is unavailable on this Mac.",
                    actionTitle: nil,
                    action: {}
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: NotchTheme.surfaceCornerRadius)
    }

    private func content(_ snapshot: WeatherSnapshot) -> some View {
        HStack(spacing: 14) {
            Image(systemName: snapshot.symbolName)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 34, weight: .medium))
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(snapshot.temperatureText)
                        .font(.system(size: 26, weight: .semibold).monospacedDigit())
                    Text(snapshot.conditionDescription)
                        .font(.system(size: 12))
                        .foregroundStyle(NotchTheme.secondaryForeground)
                }
                HStack(spacing: 10) {
                    Label(snapshot.highText, systemImage: "arrow.up")
                    Label(snapshot.lowText, systemImage: "arrow.down")
                    if let place = snapshot.placeName {
                        Text(place)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(NotchTheme.secondaryForeground)
                .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var loadingOrError: some View {
        if let error = weather.lastErrorMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(NotchTheme.secondaryForeground)
                    .lineLimit(2)
                Spacer()
                Button("Retry") { Task { await weather.refresh() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Fetching weather…")
                    .font(.system(size: 12))
                    .foregroundStyle(NotchTheme.secondaryForeground)
                Spacer()
            }
        }
    }
}

// MARK: Event list

private struct EventList: View {
    @ObservedObject var calendar: CalendarService
    /// Module clock tick; binding it forces relative descriptions to refresh.
    let tick: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                Text("Upcoming")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(NotchTheme.secondaryForeground)

            switch calendar.authState {
            case .authorized:
                if calendar.upcoming.isEmpty {
                    emptyRow
                } else {
                    ForEach(calendar.upcoming.prefix(4)) { event in
                        EventRow(event: event)
                            .id("\(event.id)-\(tick)")
                    }
                }
            case .notDetermined:
                PermissionPrompt(
                    symbol: "calendar.badge.clock",
                    message: "Allow calendar access to see your next events.",
                    actionTitle: "Allow",
                    action: { calendar.requestAccessIfNeeded() }
                )
            case .denied:
                PermissionPrompt(
                    symbol: "calendar.badge.exclamationmark",
                    message: "Calendar access is off. Enable it to see events.",
                    actionTitle: "Open Settings",
                    action: { SystemSettings.openCalendarPrivacy() }
                )
            case .unavailable:
                PermissionPrompt(
                    symbol: "exclamationmark.triangle.fill",
                    message: "Calendar is unavailable on this Mac.",
                    actionTitle: nil,
                    action: {}
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: NotchTheme.surfaceCornerRadius)
    }

    private var emptyRow: some View {
        Text("Nothing scheduled")
            .font(.system(size: 12))
            .foregroundStyle(NotchTheme.secondaryForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }
}

private struct EventRow: View {
    let event: GlanceEvent

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(GlanceFormatting.relativeDescription(for: event))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(NotchTheme.secondaryForeground)
            }
            Spacer(minLength: 0)
            if !event.isAllDay {
                Text(GlanceFormatting.timeString(event.startDate))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(NotchTheme.secondaryForeground)
            }
        }
        .padding(.vertical, 3)
    }

    private var dotColor: Color {
        if let cg = event.calendarColor { return Color(cgColor: cg) }
        return .accentColor
    }
}

// MARK: Permission prompt

/// An inline row prompting the user to grant access or open System Settings.
private struct PermissionPrompt: View {
    let symbol: String
    let message: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(.yellow)
                .frame(width: 22)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.primaryForeground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - System Settings deep links

/// Opens the relevant System Settings privacy panes so the user can grant access.
enum SystemSettings {
    static func openLocationServices() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
    }

    static func openCalendarPrivacy() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
