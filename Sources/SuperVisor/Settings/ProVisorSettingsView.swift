import AppKit
import SwiftUI

/// ProVisor's options: how often it looks, a way to make it look now, how the last pass went,
/// a door into the folder holding its brief and its tool access, the sites it may read signed
/// in, and whether it reads texts.
///
/// The last pass's summary is the agent's own account of where it looked and what got in its
/// way, so this is also where a misconfiguration shows up — a connector it expected and did
/// not have, a Claude Code too old for the flags that confine it.
struct ProVisorSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var center: ProVisorCenter
    @ObservedObject var sites: SiteAccessCenter

    @State private var removing: SiteRecord?
    /// Sites whose last removal failed.
    @State private var removalFailures: Set<String> = []

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

            if let report = center.lastScout {
                Text(report.text)
                    .font(.caption)
                    .foregroundStyle(report.failed ? Color.red : Color.secondary)
            }

            standingApprovals

            Text("Runs Claude Code in the background on this Mac to read your mail and calendar through the connectors you added in Claude, and lists what it thinks you would want done. While looking it can only read. Nothing changes until you approve a proposal, and by default an approved action can organize mail and write drafts but cannot send. When it sees a pattern in what you approve (always for one person, always on a certain day), a proposal offers a rule with that condition; choose Always and later ones under it are done without asking, limited to steps that can be undone, and shown to you afterwards. Its brief (CHARTER.md) and the connector tools it may use (access.json) are in its folder and are yours to edit. Uses your Claude plan, and needs a recent Claude Code signed in with your Claude account.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        siteList

        Toggle(
            "Read my texts",
            isOn: Binding(get: { sites.textsEnabled }, set: { sites.setTextsEnabled($0) })
        )
        Text("ProVisor can read your recent texts; sign-in codes in them are hidden from it. SuperVisor also uses texted codes to sign in to sites that send them. Needs Full Disk Access.")
            .font(.caption)
            .foregroundStyle(.secondary)

        if sites.textsStatus == .accessDenied {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Full Disk Access is off, so texts can't be read.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button("Open System Settings") { SiteAccessCenter.openFullDiskAccessSettings() }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
            }
        }
    }

    /// The granted sites, each with what it needs and a way to remove it, and the way to add one.
    private var siteList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sites")
                .font(.caption.weight(.medium))

            Text("ProVisor can read pages on these sites signed in, and only read. A site kept signed in holds no password and asks you to sign in again when it signs you out; for a site SuperVisor signs in to, the password stays in your Keychain and SuperVisor fills it in itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(sites.sites) { site in
                siteRow(site)
            }

            Button("Add Site…") { ProVisorSiteWindow.shared.showAdding(center: sites) }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))

            if !sites.sites.isEmpty || sites.textsEnabled,
               let pause = Self.pauseNotice(for: center.siteToolsUnavailable) {
                Text(pause)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { refresh() }
        // Full Disk Access is granted in System Settings, so the texts status is read again on
        // coming back to Settings.
        .onWindowBecomesKey { refresh() }
        .onChange(of: sites.sites) { center.refreshSiteTools() }
        .onChange(of: sites.textsEnabled) { center.refreshSiteTools() }
        .confirmationDialog(
            removing.map { "Remove \($0.name)?" } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { site in
            Button("Remove", role: .destructive) {
                Task {
                    do {
                        try await sites.remove(site.id)
                        removalFailures.remove(site.id)
                    } catch {
                        removalFailures.insert(site.id)
                    }
                }
            }
        } message: { _ in
            Text("Its saved sign-in and the site's cookies are deleted.")
        }
    }

    /// Reads the sites and texts again, then why a pass would run without the tools for them.
    private func refresh() {
        sites.refresh()
        center.refreshSiteTools()
    }

    /// The line that says why ProVisor is not reading the granted sites and texts, or nil when
    /// it is, or when there is nothing granted for it to read.
    static func pauseNotice(for reason: ProVisorBridge.Unavailable?) -> String? {
        switch reason {
        case nil, .nothingGranted?:
            nil
        case .accessNotSealed?:
            "Site and text reading is paused: access.json lets the scout call a tool SuperVisor doesn't know to be read-only."
        case .cliNotTrusted?:
            "Site and text reading is paused: the installed agent CLI isn't the signed build."
        case .disclaimUnavailable?:
            "Site and text reading is paused: this macOS can't start the agent without SuperVisor's own permissions."
        case .serverFailed?:
            "Site and text reading is paused: SuperVisor couldn't open its tool channel."
        }
    }

    private func siteRow(_ site: SiteRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            siteSummary(site)
            if removalFailures.contains(site.id) {
                Text("Couldn't remove \(site.name). Try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func siteSummary(_ site: SiteRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(site.name)
                    .font(.caption)
                HStack(spacing: 4) {
                    Text(site.id)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.secondary)
                    siteStatus(site)
                }
                .font(.caption)
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button("Sign In Again") {
                ProVisorSiteWindow.shared.showSignInAgain(site, center: sites)
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            Button("Remove") { removing = site }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
        }
    }

    @ViewBuilder
    private func siteStatus(_ site: SiteRecord) -> some View {
        switch SiteAccessCenter.SiteStatus(site, awaiting: sites.awaitingSignIn) {
        case .needsYou:
            Text("Needs you")
                .foregroundStyle(.orange)
        case let .signedIn(date):
            Text("Signed in \(date.formatted(.relative(presentation: .named)))")
                .foregroundStyle(.secondary)
        case let .signedInKeepingSession(date):
            Text("Signed in \(date.formatted(.relative(presentation: .named))) · asks you when it signs you out")
                .foregroundStyle(.secondary)
        case .notSignedInYet:
            Text("Not signed in yet")
                .foregroundStyle(.secondary)
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
        if center.lastScout?.failed == true { return "Last pass failed" }
        guard let last = center.lastScoutDate else { return "Has not looked yet" }
        return "Last looked \(last.formatted(.relative(presentation: .named)))"
    }

    private var statusSymbol: String {
        if center.isScouting || center.isFollowingUp { return "sparkles" }
        if center.lastScout?.failed == true { return "exclamationmark.triangle.fill" }
        return center.lastScoutDate == nil ? "circle.dashed" : "checkmark.circle.fill"
    }

    private var statusTint: Color {
        if center.isScouting || center.isFollowingUp { return .secondary }
        if center.lastScout?.failed == true { return .orange }
        return center.lastScoutDate == nil ? .secondary : .green
    }

    private func openFolder() {
        try? ProVisorHome.prepare()
        NSWorkspace.shared.open(ProVisorHome.rootURL)
    }
}
