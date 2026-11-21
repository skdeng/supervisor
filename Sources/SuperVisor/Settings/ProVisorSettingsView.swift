import AppKit
import SwiftUI

/// ProVisor's options: how often it looks, a way to make it look now, how the last pass ended,
/// a door into the folder holding its brief and its tool access, and a group that folds away
/// what it may read: the door into the window where its sites are managed, and the other sources.
///
/// **Nothing here is the agent's account of a pass.** What the agent says is drawn from mail
/// anyone can send, so a failed pass is described by `ProVisorCenter.failureSentence` in the
/// app's words. The one agent wording on this pane is a standing rule, which the user read in
/// full and accepted with Always.
struct ProVisorSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var center: ProVisorCenter
    @ObservedObject var sites: SiteAccessCenter
    @ObservedObject var messages: DirectMessageCenter

    @State private var showsAccess = false

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

            sourceFolderRow

            Text("Runs Claude Code in the background on this Mac to read your mail and calendar through the connectors you added in Claude, and lists what it thinks you would want done. While looking it can only read. Nothing changes until you approve a proposal, and by default an approved action can organize mail and write drafts but cannot send. When it sees a pattern in what you approve (always for one person, always on a certain day), a proposal offers a rule with that condition; choose Always and later ones under it are done without asking, limited to steps that can be undone, and shown to you afterwards. Its brief (CHARTER.md) and the connector tools it may use (access.json) are in its folder and are yours to edit; its own notes on each pass, including anything that got in its way, are there under memory. When something keeps getting in its way, or a change to the app would let it do more, it raises that as an item too; nothing carries such an item out, and you continue it in a Claude session where you decide what changes. Uses your Claude plan, and needs a recent Claude Code signed in with your Claude account.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        DisclosureGroup(isExpanded: $showsAccess) {
            // A disclosure group lays its content out as one form row, so the settings under
            // it carry their own spacing.
            VStack(alignment: .leading, spacing: 12) {
                siteList

                accessSetting("After you sign in to a site yourself, SuperVisor can offer to keep the password you typed, in the Keychain, so it can sign in again by itself. It reads what you type into a site's user name and password fields while its sign-in window is open.") {
                    Toggle("Offer to keep passwords", isOn: $settings.provisorOffersPasswords)
                }

                accessSetting("ProVisor can read your recent texts; sign-in codes in them are hidden from it. SuperVisor also uses texted codes to sign in to sites that send them. Needs Full Disk Access.") {
                    Toggle(
                        "Read my texts",
                        isOn: Binding(get: { sites.textsEnabled }, set: { sites.setTextsEnabled($0) })
                    )
                } warning: {
                    if sites.textsStatus == .accessDenied {
                        accessRow("Full Disk Access is off, so texts can't be read.", button: "Open System Settings") {
                            SiteAccessCenter.openFullDiskAccessSettings()
                        }
                    }
                }

                accessSetting("ProVisor can read the date and exact coordinates of each photo in your Photos library, which shows where you have been. It never sees a photo. Needs access to Photos.") {
                    Toggle(
                        "Read where my photos were taken",
                        isOn: Binding(get: { sites.photoPlacesEnabled }, set: { sites.setPhotoPlacesEnabled($0) })
                    )
                } warning: {
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

                accessSetting(Self.directMessagesExplanation(sourceName: messages.source.name)) {
                    Toggle(
                        "Read my \(messages.source.name) messages",
                        isOn: Binding(get: { messages.isEnabled }, set: { messages.setEnabled($0) })
                    )
                } warning: {
                    directMessagesStatus
                }
            }
            .padding(.top, 8)
        } label: {
            accessLabel
        }
    }

    /// The row that opens the access settings. It carries what is granted, or a warning when
    /// something under it needs the person, so a closed group hides neither.
    ///
    /// The refreshes hang here because this row is mounted whether the group is open or
    /// closed; on a row inside the group they would stop while it is closed and the warning
    /// would go stale.
    private var accessLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Access")
            Spacer(minLength: 8)
            if accessNeedsAttention {
                Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Text(Self.accessSummary(
                    siteCount: sites.sites.count,
                    texts: sites.textsEnabled,
                    photoPlaces: sites.photoPlacesEnabled,
                    directMessages: messages.isEnabled ? messages.source.name : nil
                ))
                .foregroundStyle(.secondary)
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

    private var accessNeedsAttention: Bool {
        Self.accessNeedsAttention(
            sites: sites.sites,
            awaiting: sites.awaitingSignIn,
            texts: sites.textsStatus,
            photoPlaces: sites.photoPlacesStatus,
            directMessages: messages.status,
            paused: pauseNotice != nil
        )
    }

    /// What the access row says is granted: the number of sites, then each other source that
    /// is switched on. `directMessages` is the name of the direct-message source when it is on.
    static func accessSummary(
        siteCount: Int,
        texts: Bool,
        photoPlaces: Bool,
        directMessages: String? = nil
    ) -> String {
        var parts: [String] = []
        if siteCount > 0 { parts.append(siteCount == 1 ? "1 site" : "\(siteCount) sites") }
        if texts { parts.append("texts") }
        if photoPlaces { parts.append("photo places") }
        if let directMessages { parts.append("\(directMessages) messages") }
        return parts.isEmpty ? "Nothing yet" : parts.joined(separator: ", ")
    }

    /// Whether a row under the access group is asking for the person: a site or a
    /// direct-message source waiting for a sign-in, a source switched on that macOS will not
    /// let the app read, or reading paused.
    static func accessNeedsAttention(
        sites: [SiteRecord],
        awaiting: Set<String>,
        texts: SiteAccessCenter.TextsStatus,
        photoPlaces: SiteAccessCenter.PhotoPlacesStatus,
        directMessages: DirectMessageCenter.Status = .off,
        paused: Bool
    ) -> Bool {
        paused
            || texts == .accessDenied
            || photoPlaces == .accessNotAsked
            || photoPlaces == .accessDenied
            || directMessages == .notSignedIn
            || directMessages == .needsYou
            || sites.contains { SiteAccessCenter.SiteStatus($0, awaiting: awaiting) == .needsYou }
    }

    /// Why reading is paused, when something is granted for a pass to read.
    private var pauseNotice: String? {
        guard !sites.sites.isEmpty || sites.textsEnabled || sites.photoPlacesEnabled else { return nil }
        return Self.pauseNotice(for: center.siteToolsUnavailable)
    }

    /// One setting under the access group: its control, what it lets the app read, and a
    /// warning while that cannot be read.
    private func accessSetting(
        _ explanation: String,
        @ViewBuilder control: () -> some View,
        @ViewBuilder warning: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            control()
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            warning()
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

    static func directMessagesExplanation(sourceName: String) -> String {
        "SuperVisor keeps a copy of your \(DirectMessageSnapshot.maximumThreads) most recent \(sourceName) chats, "
            + "with the latest messages in each, for ProVisor; message requests are left out. You sign in on "
            + "\(sourceName)'s own page and SuperVisor keeps that session, never your password. It then loads "
            + "your inbox in the background and copies what the page receives, without opening a chat. "
            + "\(sourceName) can tell this from a person browsing and may ask you to confirm your account. "
            + "Turning this off deletes the copy and the session on this Mac; \(sourceName) still lists "
            + "the login until you remove it there."
    }

    /// Where the direct-message source stands: the sign-in it waits for, or when it was last
    /// copied, with the way to copy it now.
    @ViewBuilder
    private var directMessagesStatus: some View {
        let name = messages.source.name
        switch messages.status {
        case .off:
            EmptyView()
        case .notSignedIn:
            accessRow("Not signed in to \(name) yet.", button: "Sign In…") {
                DirectMessageSignInWindow.shared.show(center: messages)
            }
        case .needsYou:
            accessRow("\(name) signed you out.", button: "Sign In…") {
                DirectMessageSignInWindow.shared.show(center: messages)
            }
        case let .signedIn(lastSync, chats):
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.directMessagesSyncText(isSyncing: messages.isSyncing, lastSync: lastSync, chats: chats))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    Button("Sync Now") {
                        Task { await messages.sync() }
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .disabled(messages.isSyncing || messages.isSigningIn)
                }

                if let problem = messages.problem {
                    Label(problem.sentence(sourceName: name), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func directMessagesSyncText(isSyncing: Bool, lastSync: Date?, chats: Int) -> String {
        if isSyncing { return "Copying your chats…" }
        guard let lastSync else { return "Signed in, not copied yet" }
        let count = chats == 1 ? "1 chat" : "\(chats) chats"
        return "\(count), copied \(lastSync.formatted(.relative(presentation: .named)))"
    }

    /// How many sites are granted, with the way into the window that manages them.
    private var siteList: some View {
        VStack(alignment: .leading, spacing: 4) {
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

            if let pauseNotice {
                Text(pauseNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
        messages.refresh()
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
        case .appReplaced?:
            "Reading sites, texts, and photo places is paused: SuperVisor was rebuilt or updated while it was running. Quit and reopen it."
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

    /// Where a session about ProVisor itself opens: SuperVisor's source, once the person has
    /// named the folder it is in. The path is the person's own choice, read from the panel.
    private var sourceFolderRow: some View {
        let path = settings.provisorSourceFolder
        return HStack(spacing: 8) {
            Text(Self.sourceFolderText(path: path, holdsSource: ProVisorHome.sourceFolder(at: path) != nil))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            Spacer()

            if !path.isEmpty {
                Button("Clear") { settings.provisorSourceFolder = "" }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
            }

            Button("Choose Source…", action: chooseSourceFolder)
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
        }
    }

    /// What the source-folder row says for the stored `path`.
    static func sourceFolderText(path: String, holdsSource: Bool) -> String {
        guard !path.isEmpty else {
            return "When ProVisor raises something about itself, the session you continue it in opens "
                + "in a folder of its own. Choose SuperVisor's source folder to have it open there."
        }
        let shown = (path as NSString).abbreviatingWithTildeInPath
        return holdsSource
            ? "Items about ProVisor itself open a session in \(shown)."
            : "\(shown) does not hold SuperVisor's source, so it is not used."
    }

    private func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder that holds SuperVisor's source (its Package.swift)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.provisorSourceFolder = url.path
    }
}
