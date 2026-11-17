import AppKit
import SwiftUI

/// ProVisor's options: how often it looks, a way to make it look now, how the last pass ended,
/// a door into the folder holding its brief and its tool access, a door into the window where
/// its sites are managed, and what else it may read.
///
/// **Nothing here is the agent's account of a pass.** What the agent says is drawn from mail
/// anyone can send, so a failed pass is described by `ProVisorCenter.failureSentence` in the
/// app's words. The one agent wording on this pane is a standing rule, which the user read in
/// full and accepted with Always.
struct ProVisorSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var center: ProVisorCenter
    @ObservedObject var sites: SiteAccessCenter

    var body: some View {
        Picker("Look for ideas", selection: $settings.provisorScoutHours) {
            Text("Only when asked").tag(0)
            Text("Every hour").tag(1)
            Text("Every 3 hours").tag(3)
            Text("Every 6 hours").tag(6)
            Text("Once a day").tag(24)
        }

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(statusText, systemImage: statusSymbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusTint)

                Spacer()

                Button("Open Folder", action: openFolder)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))

                Button("Look Now") { center.scoutNow() }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .disabled(!center.isActive || center.isScouting || center.isFollowingUp)
            }

            if let failure = center.lastScoutFailure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            standingApprovals

            Text("Runs Claude Code in the background on this Mac to read your mail and calendar through the connectors you added in Claude, and lists what it thinks you would want done. While looking it can only read. Nothing changes until you approve a proposal, and by default an approved action can organize mail and write drafts but cannot send. When it sees a pattern in what you approve (always for one person, always on a certain day), a proposal offers a rule with that condition; choose Always and later ones under it are done without asking, limited to steps that can be undone, and shown to you afterwards. Its brief (CHARTER.md) and the connector tools it may use (access.json) are in its folder and are yours to edit; its own notes on each pass, including anything that got in its way, are there under memory. Uses your Claude plan, and needs a recent Claude Code signed in with your Claude account.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        siteList

        Toggle("Offer to keep passwords", isOn: $settings.provisorOffersPasswords)
        Text("After you sign in to a site yourself, SuperVisor can offer to keep the password you typed, in the Keychain, so it can sign in again by itself. It reads what you type into a site's user name and password fields while its sign-in window is open.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Toggle(
            "Read my texts",
            isOn: Binding(get: { sites.textsEnabled }, set: { sites.setTextsEnabled($0) })
        )
        Text("ProVisor can read your recent texts; sign-in codes in them are hidden from it. SuperVisor also uses texted codes to sign in to sites that send them. Needs Full Disk Access.")
            .font(.caption)
            .foregroundStyle(.secondary)

        if sites.textsStatus == .accessDenied {
            accessRow("Full Disk Access is off, so texts can't be read.", button: "Open System Settings") {
                SiteAccessCenter.openFullDiskAccessSettings()
            }
        }

        Toggle(
            "Read where my photos were taken",
            isOn: Binding(get: { sites.photoPlacesEnabled }, set: { sites.setPhotoPlacesEnabled($0) })
        )
        Text("ProVisor can read the date and exact coordinates of each photo in your Photos library, which shows where you have been. It never sees a photo. Needs access to Photos.")
            .font(.caption)
            .foregroundStyle(.secondary)

        switch sites.photoPlacesStatus {
        case .off, .on:
            EmptyView()
        case .accessNotAsked:
            accessRow("SuperVisor hasn't been allowed to read Photos yet.", button: "Allow…") {
                sites.requestPhotoAccess()
            }
        case .accessDenied:
            accessRow("Photos access is off, so photo locations can't be read.", button: "Open System Settings") {
                SiteAccessCenter.openPhotosAccessSettings()
            }
        }
    }

    /// A warning that a source is switched on and cannot be read, with the way to fix it.
    private func accessRow(
        _ message: String,
        button: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button(button, action: action)
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
        }
    }

    /// How many sites are granted, with the way into the window that manages them.
    private var siteList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Sites")
                Spacer(minLength: 8)
                Text(Self.sitesSummary(sites.sites, awaiting: sites.awaitingSignIn))
                    .foregroundStyle(.secondary)
                Button("Manage Sites…") { ProVisorSitesWindow.shared.show(center: sites) }
            }

            Text("ProVisor can read pages on the sites you sign in to for it, and only read.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !sites.sites.isEmpty || sites.textsEnabled || sites.photoPlacesEnabled,
               let pause = Self.pauseNotice(for: center.siteToolsUnavailable) {
                Text(pause)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { refresh() }
        // Full Disk Access and access to Photos are granted in System Settings, so both
        // statuses are read again on coming back to Settings.
        .onWindowBecomesKey { refresh() }
        .onChange(of: sites.sites) { center.refreshSiteTools() }
        .onChange(of: sites.textsEnabled) { center.refreshSiteTools() }
        .onChange(of: sites.photoPlacesEnabled) { center.refreshSiteTools() }
    }

    /// The count beside the Sites row: how many sites are granted, and how many of them are
    /// waiting for the person to sign in.
    static func sitesSummary(_ sites: [SiteRecord], awaiting: Set<String>) -> String {
        guard !sites.isEmpty else { return "None yet" }
        let count = sites.count == 1 ? "1 site" : "\(sites.count) sites"
        let waiting = sites.filter { SiteAccessCenter.SiteStatus($0, awaiting: awaiting) == .needsYou }.count
        switch waiting {
        case 0: return count
        case 1: return "\(count), 1 needs you"
        default: return "\(count), \(waiting) need you"
        }
    }

    /// Reads the sites, texts, and photo places again, then why a pass would run without the
    /// tools for them.
    private func refresh() {
        sites.refresh()
        center.refreshSiteTools()
    }

    /// The line that says why ProVisor is not reading the granted sites, texts, and photo
    /// places, or nil when it is, or when there is nothing granted for it to read.
    static func pauseNotice(for reason: ProVisorBridge.Unavailable?) -> String? {
        switch reason {
        case nil, .nothingGranted?:
            nil
        case .accessNotSealed?:
            "Reading sites, texts, and photo places is paused: access.json lets the scout call a tool SuperVisor doesn't know to be read-only."
        case .cliNotTrusted?:
            "Reading sites, texts, and photo places is paused: the installed agent CLI isn't the signed build."
        case .disclaimUnavailable?:
            "Reading sites, texts, and photo places is paused: this macOS can't start the agent without SuperVisor's own permissions."
        case .serverFailed?:
            "Reading sites, texts, and photo places is paused: SuperVisor couldn't open its tool channel."
        }
    }

    /// The rules in force, each removable here. They are also revocable from any row done under
    /// one; this is the place to see them all at once.
    @ViewBuilder
    private var standingApprovals: some View {
        let inForce = center.standingRules.filter(\.isActive)
        if !inForce.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Done without asking")
                    .font(.caption.weight(.medium))

                ForEach(inForce) { rule in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.condition)
                                .font(.caption)
                            Text(rule.action)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 8)

                        Button("Remove") { center.revokeStanding(rule.id) }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                    }
                }
            }
        }
    }

    private var statusText: String {
        if center.isScouting { return "Looking now…" }
        if center.isFollowingUp { return "Checking on earlier decisions…" }
        if center.lastScoutFailure != nil { return "Last pass failed" }
        guard let last = center.lastScoutDate else { return "Has not looked yet" }
        return "Last looked \(last.formatted(.relative(presentation: .named)))"
    }

    private var statusSymbol: String {
        if center.isScouting || center.isFollowingUp { return "sparkles" }
        if center.lastScoutFailure != nil { return "exclamationmark.triangle.fill" }
        return center.lastScoutDate == nil ? "circle.dashed" : "checkmark.circle.fill"
    }

    private var statusTint: Color {
        if center.isScouting || center.isFollowingUp { return .secondary }
        if center.lastScoutFailure != nil { return .orange }
        return center.lastScoutDate == nil ? .secondary : .green
    }

    private func openFolder() {
        try? ProVisorHome.prepare()
        NSWorkspace.shared.open(ProVisorHome.rootURL)
    }
}
