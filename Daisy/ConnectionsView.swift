//
//  ConnectionsView.swift
//  Daisy
//
//  First-class sidebar destination for everything that touches the
//  outside world: calendar sources, Notion, MCP server, auto-routing
//  to other integrations. Previously these lived inside Settings as
//  separate tabs (Integrations / MCP server), with calendar
//  connection rows scattered into the General (formerly Capture) tab.
//
//  Why a top-level destination instead of a Settings tab:
//   • The Settings TabView was at 5 tabs and growing (Apple HIG: ≤5).
//   • Calendar connections live in the same mental category as Notion
//     and the MCP socket — "where Daisy talks to other systems" —
//     not "how the recorder works". Splitting them by tab obscured
//     that.
//   • Users come back here regularly: to check whether Notion's still
//     authed, what port the MCP server is on, whether Google Calendar
//     re-needs consent. Settings-tab depth was wrong for that flow.
//
//  Layout: TabView with two tabs — MCP server (incoming) and
//  Auto-routing (outgoing destinations: Notion + MCP integrations).
//  External CTAs can deep-link via
//  `AppNavigation.shared.openInConnections(.autoRouting)` /
//  `.mcpServer`. The Notion destination moved here from Settings in
//  1.0.7.16 — it's an outbound send-to destination, same class as the
//  MCP integrations. Calendar SOURCES live in Settings → Permissions.
//

import SwiftUI

struct ConnectionsView: View {
    @Bindable var settings: AppSettings
    @Bindable var mcpServer = MCPServer.shared
    @Bindable var integrationStore = MCPIntegrationStore.shared
    @Bindable var nav = AppNavigation.shared

    // MARK: - View state

    /// Currently-selected Connections tab. Persisted across navigations
    /// to / from the Connections sidebar entry within the same launch;
    /// deep-links (AppNavigation.openInConnections(_:)) write through
    /// to this value on .onChange.
    ///
    /// 1.0.4: Calendar tab left — EventKit grant in Settings →
    /// Permissions, behaviour toggles in Settings → General.
    /// 1.0.5: Notion tab folded into Settings → General → Storage.
    /// 1.0.7.16: Notion came back here — it's an outbound send-to
    /// destination, the same class as the MCP integrations, so it now
    /// renders as a "Notion" Section at the top of the Auto-routing
    /// tab. Google Calendar OAuth UI stays dormant pre-verification;
    /// when Google approves it comes back here.
    @State private var selectedSection: ConnectionSection = .autoRouting
    @State private var editingIntegration: MCPIntegration?
    @State private var mcpPortText: String = ""
    /// Disables the one-click button while the JSON merge runs. The
    /// write is fast (a direct, non-sandboxed file write — see
    /// `ClaudeDesktopConfig`), but guarding against a double-tap that
    /// fires two overlapping writes keeps the toasts sane.
    @State private var claudeInstallInProgress: Bool = false
    /// Where Daisy's entry currently stands in Claude Desktop's
    /// config — drives the button copy ("Add" vs "Update port" vs
    /// "Reinstall"), the Remove affordance, and the not-installed /
    /// malformed hints. Recomputed on appear, after every write, and
    /// whenever the live server port changes.
    @State private var claudeEntryState: ClaudeDesktopConfig.EntryState = .notInstalled
    @State private var codexInstallInProgress: Bool = false
    @State private var codexEntryState: CodexMCPConfig.EntryState = .notInstalled
    @State private var cursorInstallInProgress: Bool = false
    @State private var cursorEntryState: CursorMCPConfig.EntryState = .notInstalled
    /// MCP access-control toggles — mirrors of `MCPAccessToken`'s
    /// UserDefaults-backed flags (kept as @State because they live
    /// outside AppSettings; onChange writes them through).
    @State private var mcpRequireToken = MCPAccessToken.isRequired
    @State private var mcpAllowActions = MCPAccessToken.allowExternalActions

    // Notion destination state — moved here from SettingsView in
    // 1.0.7.16 along with the row + sheet. `notionTestResult` drives
    // the inline StatusBadge next to Test connection; the shared
    // `TestResult` enum is file-scoped in SettingsView.swift so both
    // surfaces can name it. `showingNotionSettings` toggles the
    // credentials / parent / Test-connection sheet.
    @State private var notionTestResult: TestResult = .idle
    @State private var showingNotionSettings = false

    // Google account UI moved to Settings → Permissions → Calendar
    // (build 42, 2026-05-28) — Apple Calendar and Google Calendar are
    // both calendar sources, they belong side-by-side under
    // Permissions. `GoogleAccountStore` is read directly by
    // PermissionsView now.

    // MARK: - Body

    var body: some View {
        // Two tabs since build 42: Auto-routing + MCP server. Calendar
        // tab moved to Settings → Permissions → Calendar (both Apple
        // EventKit and Google OAuth sources live there together so
        // the user has ONE place that shows "where Daisy reads
        // calendar data from"). Connections is now strictly outbound
        // integrations: where Daisy SENDS data, not where it reads
        // from.
        Group {
            switch selectedSection {
            case .autoRouting: autoRoutingTab
            case .mcpServer:   mcpServerTab
            }
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(Color.daisyBgPrimary)
        // Text-only glass tab strip at toolbar level, replacing the
        // native TabView chrome (system-locked per-cell padding). Order
        // matches the old tab order: Auto-routing, then MCP server.
        .toolbar {
            ToolbarItem(placement: .principal) {
                GlassSegmentedControl(
                    selection: $selectedSection,
                    segments: [
                        .init(value: .autoRouting, title: String(localized: "Auto-routing")),
                        .init(value: .mcpServer, title: String(localized: "MCP server")),
                    ]
                )
            }
        }
        .onAppear {
            mcpPortText = String(settings.mcpServerPort)
            refreshMCPClientEntryStates()
            consumePendingSection()
        }
        .onChange(of: nav.pendingConnectionsSection) { _, _ in
            consumePendingSection()
        }
        .onChange(of: settings.mcpServerPort) { _, new in
            mcpPortText = String(new)
            // If the user has already wired Daisy into Claude Desktop,
            // silently rewrite the config so the URL keeps pointing at
            // the right port. Only fires when an entry already exists,
            // so changing the port never creates a config the user
            // didn't ask for.
            ClaudeDesktopConfig.refreshIfInstalled(port: liveServerPort)
            CursorMCPConfig.refreshIfInstalled(port: liveServerPort)
            refreshMCPClientEntryStates()
            // Codex's refresh is async (it shells out to the CLI), so
            // its entry state has to be re-read AFTER it finishes —
            // reading it now would show the pre-refresh port and offer
            // a "reconnect" button for work already in progress.
            Task {
                await CodexMCPConfig.refreshIfInstalled(port: liveServerPort)
                refreshMCPClientEntryStates()
            }
        }
        // The button copy + status hints key off whether the server is
        // running and on what port; recompute when the listener state
        // flips (start / stop / restart on a new port).
        .onChange(of: mcpServer.state) { _, _ in
            refreshMCPClientEntryStates()
        }
        .sheet(item: $editingIntegration) { integration in
            IntegrationEditor(
                initial: integration,
                onSave: { updated in
                    if integrationStore.integrations.contains(where: { $0.id == updated.id }) {
                        integrationStore.update(updated)
                    } else {
                        integrationStore.add(updated)
                    }
                    editingIntegration = nil
                },
                onCancel: { editingIntegration = nil }
            )
            .frame(minWidth: 580, minHeight: 520)
        }
    }

    /// One-shot deep-link consumer. AppNavigation writes a pending
    /// section before flipping `section = .connections`; we read it
    /// here on appear / on change and flip the selected tab.
    private func consumePendingSection() {
        guard let pending = nav.pendingConnectionsSection else { return }
        selectedSection = pending
        nav.pendingConnectionsSection = nil
    }

    // MARK: - Tab wrappers
    //
    // Each tab is a single-Section Form so it inherits the same
    // grouped-card chrome the rest of Daisy's preference surfaces use.
    // The actual section content (mcpServerSection / autoRoutingSection)
    // is unchanged from when it lived in the stacked scroll layout.

    private var mcpServerTab: some View {
        Form { mcpServerSection }
            .formStyle(.grouped)
    }

    private var autoRoutingTab: some View {
        Form {
            // Notion destination — moved here from Settings → General
            // → Storage in 1.0.7.16. It's an outbound send-to
            // destination, the same logical class as the MCP
            // integrations in autoRoutingSection below, so it belongs
            // on the Connections page rather than next to the local
            // recordings folder.
            Section {
                notionDestinationRow
            } header: {
                Text("Notion")
            }
            autoRoutingSection
        }
        .formStyle(.grouped)
    }

    // Calendar UI moved out of Connections entirely in build 42
    // (2026-05-28). Both Apple Calendar (EventKit) and Google Calendar
    // (OAuth) now live in Settings → Permissions → Calendar — see
    // PermissionsView for the unified UI. Connections is now strictly
    // about outbound integrations (Auto-routing + MCP server).
    // Backend (`GoogleOAuthClient` / `GoogleAccountStore` /
    // `GoogleCalendarService`) is unchanged; only the UI surface moved.

    // MARK: - Notion destination
    //
    // Moved here from SettingsView (Settings → General → Storage) in
    // 1.0.7.16 — Notion is an outbound send-to destination, the same
    // class as the MCP integrations in the Auto-routing section, so it
    // lives on the Connections page now. The row + auto-send toggle +
    // optional folder filter render in the Auto-routing tab's "Notion"
    // Section (see autoRoutingTab); the credentials / parent / Test-
    // connection sheet opens from the gear button. Persisted fields are
    // on the shared `AppSettings`; `NotionExporter.shared` does the
    // probe.

    @ViewBuilder
    private var notionDestinationRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Notion")
                        .font(.callout.weight(.medium))
                    notionStatusBadge
                }
                Text(notionRowCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            // Gear opens the modal with secret / parent-id / parent-
            // type / Test connection. Pre-1.0.5.4 those lived in an
            // inline DisclosureGroup, which pushed Storage section
            // down and left a visible empty row when collapsed.
            Button {
                showingNotionSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Notion settings")
            Toggle("", isOn: $settings.autoSendNotion)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!settings.hasNotionCredentials || settings.lastNotionTestPassedAt == nil)
                .help(notionToggleHelp)
        }
        .sheet(isPresented: $showingNotionSettings) {
            notionSettingsSheet
                .frame(minWidth: 520, minHeight: 460)
        }

        // Folder filter — appears when auto-send is on, so a power
        // user can scope auto-push to e.g. "Work" folder and keep
        // personal voice notes off Notion.
        if settings.autoSendNotion {
            folderFilterPicker(
                title: String(localized: "Only from projects"),
                selection: Binding(
                    get: { settings.autoSendNotionFolders },
                    set: { settings.autoSendNotionFolders = $0 }
                )
            )
        }
    }

    /// Modal sheet with the full Notion configuration — secret,
    /// parent id, parent type, Test connection. Replaced the prior
    /// inline DisclosureGroup in 1.0.5.4. Keeps the Storage section
    /// tight and pushes the field wall out of the main settings
    /// scroll, which matches what users expect from a macOS sheet.
    @ViewBuilder
    private var notionSettingsSheet: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Notion")
                                .font(.headline)
                            Text("Send finished recordings into a Notion page or database.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        notionStatusBadge
                    }

                    LabeledContent {
                        SecureField("", text: $settings.notionToken, prompt: Text("secret_…"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity)
                    } label: {
                        labelWithCaption(String(localized: "Integration secret"),
                                         caption: String(localized: "Paste your Notion integration secret."))
                    }

                    LabeledContent {
                        TextField("", text: $settings.notionParentID, prompt: Text("a1b2c3d4…"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity)
                    } label: {
                        labelWithCaption(String(localized: "Parent ID"),
                                         caption: String(localized: "The 32-character ID at the end of the page or database URL — with or without dashes."))
                    }

                    LabeledContent {
                        // pickerStyle(.menu) instead of .segmented:
                        // macOS 26.2 ships an Apple-side UAF in the Swift
                        // concurrency ↔ AppKit bridge that crashes any
                        // SwiftUI Picker(.segmented) on layout (it routes
                        // through SystemSegmentedControl, an NSSegmentedControl
                        // wrapper — same UAF family as the NavigationSplitView
                        // sidebar toggle we removed in build 33). 2 options
                        // fit the menu naturally in this LabeledContent
                        // trailing slot. Restore .segmented post-26.x once
                        // Apple ships the fix.
                        Picker("", selection: $settings.notionParentKind) {
                            Text("Page").tag("page")
                            Text("Database").tag("database")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    } label: {
                        labelWithCaption(String(localized: "Parent type"),
                                         caption: String(localized: "Page — Daisy adds the recording as a child page underneath. Database — adds a row (title column must be named \"Name\")."))
                    }

                    HStack {
                        notionTestStatusView
                        Spacer()
                        Button("Test connection") {
                            Task { await testNotion() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.daisyAccent)
                        .disabled(notionTestResult == .testing || !settings.hasNotionCredentials)
                    }

                    Text("Make an internal integration at notion.so/profile/integrations, then share the parent page or database with it. Test creates a probe page you can delete.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") {
                    showingNotionSettings = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .background(Color.daisyBgPrimary)
    }

    /// Right-of-title badge — same vocabulary as the old section
    /// header in Connections so returning users recognise the state.
    @ViewBuilder
    private var notionStatusBadge: some View {
        if settings.hasNotionCredentials && settings.lastNotionTestPassedAt != nil {
            Text("Connected")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.daisySuccess)
        } else if settings.hasNotionCredentials {
            Text("Needs test")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.daisyWarning)
        }
    }

    /// Caption text under the Notion title — flips depending on
    /// config state. Three meaningful states: unconfigured (call to
    /// action), configured-but-untested (warning to test first),
    /// configured-and-tested (passive confirmation).
    private var notionRowCaption: String {
        // The "gear" referenced here is the gearshape button on this
        // row that opens `notionSettingsSheet` — the deep config
        // (secret / parent / Test connection) lives in that sheet, not
        // inline, so the copy points at the gear rather than "below".
        if !settings.hasNotionCredentials {
            return String(localized: "Send finished recordings to Notion as a child page or a database row. Set it up in the gear.")
        }
        if settings.lastNotionTestPassedAt == nil {
            return String(localized: "Run Test connection in the gear first — auto-send only turns on once it passes.")
        }
        return String(localized: "Sends each recording to Notion the moment you stop.")
    }

    private var notionToggleHelp: String {
        if !settings.hasNotionCredentials {
            return String(localized: "Open Notion settings in the gear first.")
        }
        if settings.lastNotionTestPassedAt == nil {
            return String(localized: "Run Test connection before enabling auto-send.")
        }
        return String(localized: "Auto-send finished recordings to Notion.")
    }

    @ViewBuilder
    private var notionTestStatusView: some View {
        switch notionTestResult {
        case .idle:             StatusBadge(state: .idle)
        case .testing:          StatusBadge(state: .busy)
        case .success(let m):   StatusBadge(state: .ok, message: m)
        case .failure(let m):   StatusBadge(state: .err, message: m)
        }
    }

    private func testNotion() async {
        notionTestResult = .testing
        let probe = MeetingExportData(
            title: "Daisy — Connection test",
            summary: nil,
            transcriptChunks: ["This page was created by Daisy as a connection test. You can safely delete it."],
            durationSeconds: 0,
            locale: "en",
            startedAt: Date()
        )
        do {
            let url = try await NotionExporter.shared.createMeetingPage(probe)
            notionTestResult = .success("Test page created in Notion.")
            // Mark proven-working — the auto-send toggle's enabled
            // gate flips only after this timestamp exists.
            settings.lastNotionTestPassedAt = Date()
            NSWorkspace.shared.open(url)
        } catch {
            notionTestResult = .failure("Couldn't reach Notion — \(error.localizedDescription)")
        }
    }

    /// Folder-filter picker for "Only from folders" — visible only
    /// when auto-send is ON. Multi-select via Menu so the row stays
    /// compact regardless of how many folders the user has.
    @ViewBuilder
    private func folderFilterPicker(
        title: String,
        selection: Binding<Set<String>>
    ) -> some View {
        let folders = FolderStore.shared.allFolders
        Menu {
            Button {
                selection.wrappedValue = []
            } label: {
                if selection.wrappedValue.isEmpty {
                    Label("All folders", systemImage: "checkmark")
                } else {
                    Text("All projects")
                }
            }
            Divider()
            ForEach(folders) { folder in
                Button {
                    var current = selection.wrappedValue
                    if current.contains(folder.slug) {
                        current.remove(folder.slug)
                    } else {
                        current.insert(folder.slug)
                    }
                    selection.wrappedValue = current
                } label: {
                    if selection.wrappedValue.contains(folder.slug) {
                        Label(folder.name, systemImage: "checkmark")
                    } else {
                        Text(folder.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(folderFilterSummary(selection.wrappedValue, allFolders: folders))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func folderFilterSummary(_ slugs: Set<String>, allFolders: [SessionFolder]) -> String {
        if slugs.isEmpty { return "All folders" }
        let names = allFolders.filter { slugs.contains($0.slug) }.map(\.name)
        if names.count == 1 { return names[0] }
        if names.count <= 3 { return names.joined(separator: ", ") }
        return String(localized: "\(names.count) projects")
    }

    /// Label + caption stacked vertically in the LEADING column of
    /// a `LabeledContent` row. Keeps the input alone in the
    /// trailing column — which (1) lets every trailing field share
    /// the same width regardless of caption length, and (2) lets a
    /// segmented Picker stay on the same row as its label instead
    /// of falling into Form's two-line fallback.
    @ViewBuilder
    private func labelWithCaption(_ title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - MCP server section

    @ViewBuilder
    private var mcpServerSection: some View {
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MCP server")
                        .font(.callout.weight(.semibold))
                    Text(mcpServerSubtitle)
                        .font(.caption)
                        .foregroundStyle(mcpServerSubtitleColor)
                        .lineLimit(1)
                }
                Spacer()
                Toggle("MCP server", isOn: $settings.mcpServerEnabled)
                    .labelsHidden()
            }
            claudeDesktopRow
            codexRow
            cursorRow

            DisclosureGroup("Claude Code") {
                claudeCodeRow
                    .padding(.top, 6)
            }

            rawSnippetDisclosure

            DisclosureGroup("Privacy") {
                mcpPrivacySettings
                    .padding(.top, 6)
            }

            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Change the port only if it is occupied.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("", text: $mcpPortText, prompt: Text("54321"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .onSubmit { commitMCPPort() }
                    }
                }
                .padding(.top, 6)
            }
        } header: {
            Text("MCP server")
        } footer: {
            Text("Only apps on this Mac can connect.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Privacy & permissions

    @ViewBuilder
    private var mcpPrivacySettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $mcpRequireToken) {
                Text("Require access token")
                Text("A code for other apps on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: mcpRequireToken) { _, new in
                MCPAccessToken.isRequired = new
                ClaudeDesktopConfig.refreshIfInstalled(port: liveServerPort)
                CursorMCPConfig.refreshIfInstalled(port: liveServerPort)
                refreshMCPClientEntryStates()
                Task {
                    await CodexMCPConfig.refreshIfInstalled(port: liveServerPort)
                    refreshMCPClientEntryStates()
                }
            }

            if mcpRequireToken {
                HStack {
                    Text("Access token")
                    Spacer()
                    Button("Copy") {
                        copyToPasteboard(MCPAccessToken.ensure(), toast: "Access token copied.")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Label("Any app on this Mac can read your recordings while this is on.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.daisyWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $mcpAllowActions) {
                Text("Allow actions from MCP clients")
                Text("Lets apps re-summarize and send recordings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: mcpAllowActions) { _, new in
                MCPAccessToken.allowExternalActions = new
            }
        }
    }

    // MARK: Claude Desktop one-click

    @ViewBuilder
    private var claudeDesktopRow: some View {
        HStack(spacing: 10) {
            mcpClientTitle("Claude Desktop", status: claudeDesktopHint)
            Spacer(minLength: 8)
            if claudeEntryIsPresent {
                Button(role: .destructive) { removeFromClaudeDesktop() } label: {
                    Label("Disconnect", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(claudeInstallInProgress)
            }
            if !claudeEntryIsPresent || claudeConnectionNeedsRepair {
                Button { Task { await installToClaudeDesktop() } } label: {
                    Label(claudeDesktopButtonTitle, systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color.daisyAccent)
                .disabled(claudeInstallInProgress || !isServerRunning || claudeEntryState == .malformed)
            }
        }
    }

    // MARK: Codex and Cursor one-click setup

    @ViewBuilder
    private var codexRow: some View {
        HStack(spacing: 10) {
            mcpClientTitle("Codex", status: codexHint)
            Spacer(minLength: 8)
            if codexEntryIsPresent {
                Button(role: .destructive) { Task { await removeFromCodex() } } label: {
                    Label("Disconnect", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(codexInstallInProgress)
            }
            if !codexEntryIsPresent || codexEntryState == .installedDifferentPort {
                Button { Task { await installToCodex() } } label: {
                    Label(codexButtonTitle, systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color.daisyAccent)
                .disabled(codexInstallInProgress || !isServerRunning || codexEntryState == .codexNotInstalled)
            }
        }
    }

    @ViewBuilder
    private var cursorRow: some View {
        HStack(spacing: 10) {
            mcpClientTitle("Cursor", status: cursorHint)
            Spacer(minLength: 8)
            if cursorEntryIsPresent {
                Button(role: .destructive) { removeFromCursor() } label: {
                    Label("Disconnect", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(cursorInstallInProgress)
            }
            if !cursorEntryIsPresent || cursorEntryState == .installedDifferentPort {
                Button { Task { await installToCursor() } } label: {
                    Label(cursorButtonTitle, systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color.daisyAccent)
                .disabled(cursorInstallInProgress || !isServerRunning || cursorEntryState == .malformed)
            }
        }
    }

    @ViewBuilder
    private func mcpClientTitle(_ name: String, status: String) -> some View {
        Text(name)
            .font(.callout.weight(.semibold))
        Text(status)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    // MARK: Claude Code command

    @ViewBuilder
    private var claudeCodeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open Terminal, paste this command once, then restart Claude Code.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(claudeCodeCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
                    )

                Button {
                    copyToPasteboard(claudeCodeCommand, toast: "Claude Code command copied")
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.daisyTextPrimary)
                .help("Copy the claude mcp add command")
                .accessibilityLabel("Copy Claude Code command")
            }
        }
    }

    // MARK: Raw snippet (Cursor / Cline / Continue / manual)

    @ViewBuilder
    private var rawSnippetDisclosure: some View {
        DisclosureGroup("Other compatible apps") {
            VStack(alignment: .leading, spacing: 10) {
                Text("For Cursor, Cline, Continue, or another app that asks for an MCP configuration. Copy and paste this whole block.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(mcpConfigSnippet)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
                    )
                HStack {
                    Spacer()
                    Button {
                        copyToPasteboard(mcpConfigSnippet, toast: "MCP config copied")
                    } label: {
                        Label("Copy snippet", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.daisyTextPrimary)
                }
            }
            .padding(.top, 6)
        }
        .font(.callout)
    }

    // MARK: - Live port + derived UI state

    /// The port the config / command should point at. Prefer the port
    /// the listener is ACTUALLY bound to (`.running`/`.starting`) over
    /// the value in the text field — if the user typed a new port but
    /// hasn't applied it (server still on the old one), mcp-remote and
    /// `claude mcp add` must target where the socket really is, not
    /// where it's about to be. Falls back to the saved setting when
    /// the server is stopped (so the snippet still shows something
    /// sensible to copy ahead of turning it on).
    private var liveServerPort: Int {
        switch mcpServer.state {
        case .running(let port), .starting(let port):
            return port
        case .stopped, .failed:
            return settings.mcpServerPort
        }
    }

    private var isServerRunning: Bool {
        if case .running = mcpServer.state { return true }
        return false
    }

    private var mcpServerSubtitle: String {
        switch mcpServer.state {
        case .running:
            return String(localized: "Running locally")
        case .starting:
            return String(localized: "Starting…")
        case .stopped:
            return String(localized: "Off")
        case .failed(let error):
            if error.localizedCaseInsensitiveContains("address already in use") {
                return String(localized: "Port is already in use. Close the other copy of Daisy or change the port.")
            }
            return String(localized: "Couldn't start")
        }
    }

    private var mcpServerSubtitleColor: Color {
        if case .failed = mcpServer.state { return Color.daisyWarning }
        return .secondary
    }

    /// True when a `daisy` entry exists in the config at all (any
    /// port). Gates the Remove button.
    private var claudeEntryIsPresent: Bool {
        switch claudeEntryState {
        case .installed, .installedDifferentPort:
            return true
        default:
            return false
        }
    }

    private var claudeConnectionNeedsRepair: Bool {
        if case .installedDifferentPort = claudeEntryState { return true }
        return false
    }

    private var claudeDesktopButtonTitle: String {
        switch claudeEntryState {
        case .installed:
            return String(localized: "Set up again")
        case .installedDifferentPort:
            return String(localized: "Repair connection")
        case .notInstalled, .claudeNotInstalled, .malformed:
            return String(localized: "Connect")
        }
    }

    private var claudeDesktopHint: String {
        switch claudeEntryState {
        case .claudeNotInstalled:
            return String(localized: "Claude Desktop not found")
        case .notInstalled:
            return String(localized: "Not connected")
        case .installed:
            return String(localized: "Connected — restart Claude Desktop.")
        case .installedDifferentPort:
            return String(localized: "Connection needs an update.")
        case .malformed:
            return String(localized: "Configuration needs fixing.")
        }
    }

    private var codexEntryIsPresent: Bool {
        switch codexEntryState {
        case .installed, .installedDifferentPort:
            return true
        case .notInstalled, .codexNotInstalled:
            return false
        }
    }

    private var codexButtonTitle: String {
        switch codexEntryState {
        case .installed:
            return String(localized: "Set up again")
        case .installedDifferentPort:
            return String(localized: "Repair connection")
        case .notInstalled:
            return String(localized: "Connect")
        case .codexNotInstalled:
            return String(localized: "Codex not installed")
        }
    }

    private var codexHint: String {
        switch codexEntryState {
        case .installed:
            return String(localized: "Connected — start a new Codex task.")
        case .installedDifferentPort:
            return String(localized: "Connection needs an update.")
        case .notInstalled:
            return String(localized: "Not connected")
        case .codexNotInstalled:
            return String(localized: "Codex not found")
        }
    }

    private var cursorEntryIsPresent: Bool {
        switch cursorEntryState {
        case .installed, .installedDifferentPort:
            return true
        case .notInstalled, .malformed:
            return false
        }
    }

    private var cursorButtonTitle: String {
        switch cursorEntryState {
        case .installed:
            return String(localized: "Set up again")
        case .installedDifferentPort:
            return String(localized: "Repair connection")
        case .notInstalled, .malformed:
            return String(localized: "Connect")
        }
    }

    private var cursorHint: String {
        switch cursorEntryState {
        case .installed:
            return String(localized: "Connected — restart Cursor.")
        case .installedDifferentPort:
            return String(localized: "Connection needs an update.")
        case .notInstalled:
            return String(localized: "Not connected")
        case .malformed:
            return String(localized: "Configuration needs fixing.")
        }
    }

    private var mcpConfigSnippet: String {
        let port = liveServerPort
        // Claude Desktop config schema requires stdio transport
        // (`command` + `args`), not raw URL. `npx -y mcp-remote`
        // proxies a remote SSE/HTTP MCP into the stdio shape
        // Claude expects. The two extra flags after the URL pin
        // mcp-remote to the SSE transport Daisy speaks
        // (`--transport sse-only`) and allow plain HTTP on loopback
        // (`--allow-http`, otherwise mcp-remote refuses 127.0.0.1
        // since it isn't TLS). Same args work in Cursor / Cline /
        // Continue — they all accept stdio-style entries.
        // Version pinned for supply-chain hygiene (matches
        // ClaudeDesktopConfig); the header line appears only when the
        // access token is required.
        let headerLines = MCPAccessToken.isRequired
            ? """
            ,
                "--header",
                "Authorization: Bearer \(MCPAccessToken.ensure())"
            """
            : ""
        return """
        {
          "mcpServers": {
            "daisy": {
              "command": "npx",
              "args": [
                "-y",
                "mcp-remote@0.1.38",
                "http://127.0.0.1:\(port)/sse",
                "--transport",
                "sse-only",
                "--allow-http"\(headerLines)
              ]
            }
          }
        }
        """
    }

    /// Claude Code command. Claude Code speaks HTTP transports
    /// natively, so we register the loopback endpoint directly — no
    /// `mcp-remote` bridge, no extra flags. `--transport http` rather
    /// than `--transport sse`: Anthropic's own docs mark the SSE
    /// transport deprecated, and Daisy now serves POST /mcp. Entries
    /// added with the older command keep working — /sse is still
    /// served. The port is the LIVE one (see `liveServerPort`).
    private var claudeCodeCommand: String {
        let auth = MCPAccessToken.isRequired
            ? " --header \"Authorization: Bearer \(MCPAccessToken.ensure())\""
            : ""
        return "claude mcp add --transport http daisy http://127.0.0.1:\(liveServerPort)/mcp\(auth)"
    }

    private func copyToPasteboard(_ string: String, toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        ToastCenter.shared.show(toast, style: .success)
    }

    private func refreshMCPClientEntryStates() {
        claudeEntryState = ClaudeDesktopConfig.entryState(port: liveServerPort)
        codexEntryState = CodexMCPConfig.entryState(port: liveServerPort)
        cursorEntryState = CursorMCPConfig.entryState(port: liveServerPort)
    }

    private func commitMCPPort() {
        let trimmed = mcpPortText.trimmingCharacters(in: .whitespaces)
        if let p = Int(trimmed), p > 0, p <= 65535 {
            settings.mcpServerPort = p
        } else {
            mcpPortText = String(settings.mcpServerPort)
            ToastCenter.shared.show(String(localized: "Port must be 1–65535"), style: .warning)
        }
    }

    private func installToClaudeDesktop() async {
        claudeInstallInProgress = true
        // Write the LIVE port — matches the snippet / command the user
        // sees right above the button.
        let result = ClaudeDesktopConfig.install(port: liveServerPort)
        claudeInstallInProgress = false
        refreshMCPClientEntryStates()
        switch result {
        case .installed:
            ToastCenter.shared.show(
                String(localized: "Added to Claude Desktop — restart Claude to load Daisy."),
                style: .success
            )
        case .failed(let message):
            ToastCenter.shared.show(
                String(localized: "Couldn't update Claude config: \(message)"),
                style: .warning
            )
        }
    }

    private func removeFromClaudeDesktop() {
        claudeInstallInProgress = true
        let result = ClaudeDesktopConfig.remove()
        claudeInstallInProgress = false
        refreshMCPClientEntryStates()
        switch result {
        case .removed:
            ToastCenter.shared.show(
                String(localized: "Removed from Claude Desktop — restart Claude to drop Daisy."),
                style: .success
            )
        case .notPresent:
            ToastCenter.shared.show(String(localized: "No Daisy entry to remove."), style: .info)
        case .failed(let message):
            ToastCenter.shared.show(
                String(localized: "Couldn't update Claude config: \(message)"),
                style: .warning
            )
        }
    }

    private func installToCodex() async {
        codexInstallInProgress = true
        let result = await CodexMCPConfig.install(port: liveServerPort)
        codexInstallInProgress = false
        refreshMCPClientEntryStates()
        switch result {
        case .installed:
            ToastCenter.shared.show(
                String(localized: "Connected to Codex — start a new task to use Daisy."),
                style: .success
            )
        case .failed(let message):
            ToastCenter.shared.show(
                String(localized: "Couldn't update Codex: \(message)"),
                style: .warning
            )
        }
    }

    private func removeFromCodex() async {
        codexInstallInProgress = true
        let result = await CodexMCPConfig.remove()
        codexInstallInProgress = false
        refreshMCPClientEntryStates()
        switch result {
        case .removed:
            ToastCenter.shared.show(String(localized: "Disconnected from Codex."), style: .success)
        case .notPresent:
            ToastCenter.shared.show(String(localized: "No Daisy connection to remove."), style: .info)
        case .failed(let message):
            ToastCenter.shared.show(String(localized: "Couldn't update Codex: \(message)"), style: .warning)
        }
    }

    private func installToCursor() async {
        cursorInstallInProgress = true
        let result = CursorMCPConfig.install(port: liveServerPort)
        cursorInstallInProgress = false
        refreshMCPClientEntryStates()
        switch result {
        case .installed:
            ToastCenter.shared.show(
                String(localized: "Connected to Cursor — restart it to use Daisy."),
                style: .success
            )
        case .failed(let message):
            ToastCenter.shared.show(
                String(localized: "Couldn't update Cursor: \(message)"),
                style: .warning
            )
        }
    }

    private func removeFromCursor() {
        cursorInstallInProgress = true
        let result = CursorMCPConfig.remove()
        cursorInstallInProgress = false
        refreshMCPClientEntryStates()
        switch result {
        case .removed:
            ToastCenter.shared.show(String(localized: "Disconnected from Cursor."), style: .success)
        case .notPresent:
            ToastCenter.shared.show(String(localized: "No Daisy connection to remove."), style: .info)
        case .failed(let message):
            ToastCenter.shared.show(String(localized: "Couldn't update Cursor: \(message)"), style: .warning)
        }
    }

    // MARK: - Auto-routing section (MCP integrations + default destination)

    @ViewBuilder
    private var autoRoutingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                if integrationStore.integrations.isEmpty {
                    Text("No MCP integrations yet. Add one to push finished recordings into Linear, a custom Notion database, or any other MCP-compatible service.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(integrationStore.integrations) { integration in
                        integrationRow(integration)
                    }
                }

                HStack {
                    // Templates dropped in 1.0.5.4 — until we verify
                    // each one works end-to-end against the real
                    // upstream service, surfacing them was promising
                    // more than the code delivers. Blank integration
                    // is the only safe path; collapsed the menu into
                    // a direct button.
                    Button {
                        editingIntegration = MCPIntegration(
                            name: String(localized: "New integration"),
                            baseURL: "http://127.0.0.1:11436",
                            toolName: "",
                            argumentsTemplate: "{}",
                            enabled: true
                        )
                    } label: {
                        Label("Add integration", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.daisyTextPrimary)
                    Spacer()
                }
            }

            // Default destination — what Send-to fires when the user
            // clicks the toolbar button without expanding the dropdown.
            LabeledContent {
                HStack {
                    Spacer()
                    Picker("", selection: $settings.defaultDestinationID) {
                        Text("None (always show menu)").tag("")
                        if settings.hasNotionCredentials {
                            Text("Notion").tag("notion")
                        }
                        if !integrationStore.enabledIntegrations.isEmpty {
                            Divider()
                            ForEach(integrationStore.enabledIntegrations) { integration in
                                Text(integration.name).tag(integration.id.uuidString)
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            } label: {
                Text("Default Send-to destination")
            }
        } header: {
            HStack(spacing: 6) {
                Text("Auto-routing")
                Spacer()
                if !integrationStore.enabledIntegrations.isEmpty {
                    Text("\(integrationStore.enabledIntegrations.count) active")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Each integration is a destination Daisy can push a finished session to over MCP — Linear ticket, custom Notion DB, webhook, anything that speaks the protocol. Clicking Send-to in a session's toolbar fires the default destination immediately; the chevron next to it still opens the full list.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func integrationRow(_ integration: MCPIntegration) -> some View {
        HStack(spacing: 10) {
            Toggle(
                integration.name,
                isOn: Binding(
                    get: { integration.enabled },
                    set: { newValue in
                        var copy = integration
                        copy.enabled = newValue
                        integrationStore.update(copy)
                    }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(integration.name)
                    .font(.callout.weight(.medium))
                Text("\(integration.toolName) · \(integration.baseURL)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                editingIntegration = integration
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")
            .accessibilityLabel(String(localized: "Edit \(integration.name)"))
            Button(role: .destructive) {
                integrationStore.remove(id: integration.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
            .accessibilityLabel(String(localized: "Delete \(integration.name)"))
        }
    }

    // The Notion helpers (labelWithCaption, folderFilterPicker,
    // folderFilterSummary) came back here with the Notion section in
    // 1.0.7.16 — they're used only by the Notion destination config,
    // which now lives on this page (see the Notion destination MARK
    // above). ConnectionsView owns the canonical copies again.
}
