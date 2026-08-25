//
//  SettingsView.swift
//  Daisy
//
//  Four-tab settings window:
//   • Capture        — mic toggle (always on), system audio, screenshots
//   • Transcription  — Whisper model picker (size vs accuracy)
//   • Summary        — provider picker (Apple / Anthropic / OpenAI)
//                      + API keys + model per provider + auto-summarize toggle
//   • Notion         — token + parent ID
//

import AppKit
import EventKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var whisper = WhisperEngine.shared
    @Bindable var parakeet = ParakeetEngine.shared
    @Bindable var nemotron = NemotronLiveEngine.shared
    @Bindable var summarizer = Summarizer.shared
    @Bindable private var openAIAccount = OpenAIAccountManager.shared
    @Bindable private var subscriptionUsage = SubscriptionUsageLedger.shared
    // Calendar source state — needed by the General-tab Calendar
    // section (autoStart / autoStop / menu-bar next-meeting toggles).
    // Bound to the SAME observable the Permissions tab reads
    // (SystemPermissions.shared) so the two surfaces can't disagree
    // about "is calendar granted". SystemPermissions auto-refreshes
    // on `NSApplication.didBecomeActiveNotification`, so toggling the
    // grant in System Settings → Privacy & Security and tabbing back
    // to Daisy updates this view without manual refresh.
    @Bindable private var systemPermissions = SystemPermissions.shared
    @Bindable private var googleAccount = GoogleAccountStore.shared
    @Bindable private var layoutFixExceptions = LayoutFixExceptions.shared

    @State private var summaryTestResult: TestResult = .idle
    @State private var pendingAccountDisclosure: SummaryConnectionProvider?
    // Notion destination config (token / parent / auto-send / Test
    // connection) moved to the top-level Connections page →
    // Auto-routing tab in 1.0.7.16 — it's an external send-to
    // destination, the same class as the MCP integrations that
    // already live there, not local recorder behaviour. Its @State
    // (notionTestResult / showingNotionSettings), views, and helpers
    // now live in ConnectionsView. The shared `TestResult` enum was
    // hoisted to file scope (bottom of this file) so both this view's
    // Summary test and Connections' Notion test can reference it.

    /// Last summary produced by Test summary — drives the preview
    /// block that shows up after a successful run. Cleared on each
    /// new test so the preview always matches the latest probe.
    @State private var summaryTestPreview: MeetingSummary?

    /// Bumped after the user picks / clears the sessions folder so
    /// the displayed path refreshes. `SessionsFolder` is plain
    /// UserDefaults under the hood — not @Observable — so SwiftUI
    /// needs a state nudge to re-read the path.
    @State private var storageRefreshTick: Int = 0
    /// Folder change is a two-stage decision: pick the destination, then
    /// explicitly decide what should happen to directories in the previous
    /// active root. The destructive branch gets a second confirmation.
    @State private var pendingStorageChange: SessionsFolderChangeRequest?
    @State private var showingStorageChangeChoices = false
    @State private var showingStorageDeleteConfirmation = false
    @State private var storageChangeInProgress = false
    /// On-disk Whisper cache stats — populated by an off-thread
    /// scan in `transcriptionTab.task`. `cacheRefreshTick` is the
    /// nudge the task watches; we bump it after Remove unused so
    /// the UI re-reads the freshly-shrunk cache.
    @State private var cachedModelsCount: Int = 0
    @State private var cachedModelsBytes: Int64 = 0
    /// True when "Remove unused" has something to free: >1 Whisper variant,
    /// or a Parakeet model on disk that dictation isn't currently using.
    @State private var hasUnusedModels = false
    @State private var cacheRefreshTick: Int = 0

    /// UI-language override state. Snapshot at view init so the "restart
    /// needed" hint appears only when the pick differs from what THIS
    /// launch is running with. `appLanguageTick` forces a re-render after
    /// a change (UserDefaults isn't observable by SwiftUI).
    @State private var appLanguageAtLaunch: String = Self.currentAppLanguage()
    @State private var appLanguageTick = 0
    /// Offer-to-restart alert shown right after the user picks a
    /// different interface language.
    @State private var showLanguageRestartAlert = false

    /// Current `AppleLanguages` override: "system" when none is set,
    /// else the two-letter code of the first entry.
    private static func currentAppLanguage() -> String {
        guard let langs = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
              let first = langs.first,
              UserDefaults.standard.object(forKey: "AppleLanguagesOverridden") != nil else {
            return "system"
        }
        return String(first.prefix(2))
    }

    /// Read/write binding for the language picker. "system" removes the
    /// override (follow macOS); "en"/"ru" pin the app language. Both keys
    /// take effect on next launch — standard AppKit behaviour.
    private var appLanguageBinding: Binding<String> {
        Binding(
            get: {
                _ = appLanguageTick  // establish dependency
                return Self.currentAppLanguage()
            },
            set: { newValue in
                let d = UserDefaults.standard
                if newValue == "system" {
                    d.removeObject(forKey: "AppleLanguages")
                    d.removeObject(forKey: "AppleLanguagesOverridden")
                } else {
                    d.set([newValue], forKey: "AppleLanguages")
                    // Marker so `currentAppLanguage` can tell OUR override
                    // apart from the system-seeded AppleLanguages array
                    // (macOS pre-populates that key with the system list).
                    d.set(true, forKey: "AppleLanguagesOverridden")
                }
                appLanguageTick &+= 1
                // Offer a restart when the pick differs from the language
                // this launch is running with. Picking the current one
                // back (changed their mind) needs no restart → no alert.
                if newValue != appLanguageAtLaunch {
                    showLanguageRestartAlert = true
                }
            }
        )
    }

    /// Relaunch the app so the new `AppleLanguages` override applies:
    /// spawn a second instance, then terminate this one. The tiny delay
    /// lets the new instance clear the launch gate before we exit.
    private func relaunchDaisy() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }

    /// On-disk size of all known `.caf` audio archives across
    /// every session. Drives the "Clear audio cache" row caption
    /// in Storage. Populated by an off-thread scan, bumped by
    /// `audioCacheRefreshTick` after the manual purge so the
    /// freshly-zeroed size shows up immediately.
    @State private var audioCacheFiles: Int = 0
    @State private var audioCacheBytes: Int64 = 0
    @State private var audioCacheRefreshTick: Int = 0
    /// Drives the destructive-confirm alert before `runNow()`.
    @State private var showingClearAudioConfirm = false
    /// Set while the sweep is running so the button shows
    /// progress + can't be double-clicked.
    @State private var clearingAudioCache = false

    /// Cached `ByteCountFormatter` for the cache-size row. Building
    /// one per body recompute is wasteful; this one stays alive for
    /// the view lifetime.
    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    /// Active sub-tab inside Settings. Bound to TabView's selection
    /// so external surfaces (FirstRunView, Home CTAs) can deep-link
    /// to a specific tab via `AppNavigation.shared.openInSettings(_:)`.
    /// Without an explicit binding TabView always lands on the first
    /// child — that's why early onboarding clicks felt broken
    /// (user wanted Summary, got Capture).
    @State private var settingsTab: SettingsTab = .general
    /// Live `/api/tags` model list for the Ollama picker (empty until
    /// fetched / when the server is unreachable → static catalog).
    @State private var ollamaInstalledModels: [String] = []
    /// Owns the user-added meeting-app list; @Observable, so the rows
    /// below refresh as it changes.
    @Bindable private var detector = MeetingDetector.shared
    /// Read for its progress while a batch runs — the pass is
    /// unattended by design, so the one place it's configured is where
    /// it should be visible.
    @Bindable private var endOfDay = EndOfDaySummaries.shared
    @State private var lmStudioLoadedModels: [String] = []
    /// Where the selected agent CLI was found, or nil when it isn't
    /// installed. Filled by a `.task` (the lookup can spawn a login
    /// shell, so it must not run during render).
    @State private var resolvedAgentPath: String?
    @Bindable private var nav = AppNavigation.shared

    var body: some View {
        // Custom text-only Liquid-Glass tab strip in the window toolbar
        // (ToolbarItem .principal below), replacing the native TabView.
        // The strip lives OFF the SwiftUI `glassEffect()`/DesignLibrary
        // path this app disabled — it uses AppKit's NSGlassEffectView
        // (see GlassSegmentedControl.swift). Content is a plain switch so
        // we control per-cell padding, which `.tabItem` locks.
        //
        // History (kept for context): 2026-05-22 / 2026-05-28 there were
        // two aborted attempts to swap the TabView for a custom HStack of
        // tab buttons on macOS 26, both reverted when the crash then in
        // view turned out to correlate with low disk / a partly-downloaded
        // model / recording start-stop cycles rather than the segmented
        // control itself. This control is different: it carries no
        // SwiftUI glass and no NSSegmentedControl, so it's off both of
        // those crash pathways.
        Group {
            switch settingsTab {
            case .general:       generalTab
            case .recording:     recordingTab
            case .transcription: transcriptionTab
            case .summary:       summaryTab
            case .permissions:   PermissionsView(settings: settings)
            }
        }
        .scrollContentBackground(.hidden)
        .toolbar {
            ToolbarItem(placement: .principal) {
                GlassSegmentedControl(
                    selection: $settingsTab,
                    segments: [
                        .init(value: .general, title: String(localized: "General")),
                        .init(value: .recording, title: String(localized: "Recording")),
                        .init(value: .transcription, title: String(localized: "Transcription")),
                        .init(value: .summary, title: String(localized: "Summary")),
                        .init(value: .permissions, title: String(localized: "Permissions")),
                    ]
                )
            }
        }
        // Consume any one-shot deep-link from AppNavigation. Set on
        // appear (initial entry into Settings) AND on change (user
        // jumps from FirstRun while Settings sheet is already
        // mounted — rare but possible).
        .onAppear { consumePendingSettingsTab() }
        .onChange(of: nav.pendingSettingsTab) { _, _ in
            consumePendingSettingsTab()
        }
        // macOS Settings convention: ~700pt fixed-width per tab. Without
        // a minimum the form collapses and Hotkey rows cramp horizontally.
        .frame(minWidth: 640, idealWidth: 720, minHeight: 540, maxHeight: .infinity)
        .padding()
        .background(Color.daisyBgPrimary)
        .task { await summarizer.refreshAvailability() }
        .alert(
            "Send transcripts to a cloud provider?",
            isPresented: Binding(
                get: { pendingAccountDisclosure != nil },
                set: { if !$0 { pendingAccountDisclosure = nil } }
            ),
            presenting: pendingAccountDisclosure
        ) { provider in
            Button("Cancel", role: .cancel) {
                pendingAccountDisclosure = nil
            }
            Button("Continue") {
                confirmAccountDisclosure(for: provider)
            }
        } message: { provider in
            Text(accountDisclosureMessage(for: provider))
        }
    }

    /// Pull any one-shot Settings-tab request from AppNavigation,
    /// apply it to local TabView selection, and clear the field so
    /// it doesn't fire again on subsequent appears. This is the
    /// hand-off that makes FirstRun CTAs land on the right tab
    /// instead of the default Capture.
    private func consumePendingSettingsTab() {
        guard let pending = nav.pendingSettingsTab else { return }
        settingsTab = pending
        nav.pendingSettingsTab = nil
    }

    /// Label shown on the preset Menu's trigger. Always reflects
    /// the currently-active shortcut — whether it's a canonical
    /// preset or a custom combo the user recorded via Press keys.
    /// "Custom · ⌥⌘X" makes the state legible at a glance; if
    /// nothing is configured (`.none`), fall back to a hint.
    private var presetMenuLabel: String {
        let current = settings.recordHotkey
        if current.keyCode == nil {
            return String(localized: "Choose preset")
        }
        if current.isPreset {
            return current.label
        }
        return String(localized: "Custom — \(current.label)")
    }

    /// Combined recorder + preset-menu editor for ANY hotkey
    /// binding. Recorder handles regular keys + Fn rising edge;
    /// the preset menu is the bullet-proof way to pick Fn, bare
    /// F-keys, or canonical combos without arguing with macOS
    /// event delivery. Pre-1.0.3 only the meeting hotkey had the
    /// preset menu — voice-note and dictation rows offered only
    /// the recorder, which was a dead end for Fn (Fn never fires
    /// .keyDown so the recorder silently ignored it).
    /// One row in the Shortcuts section: title + per-row caption +
    /// the hotkey editor on the trailing side. Per-row caption beats
    /// the prior one-paragraph footer because each shortcut has
    /// different semantics — having "Voice note saves to Notes,
    /// dictation auto-pastes" jammed into a single wall of text
    /// made all three modes feel interchangeable.
    /// The seven hotkey slots, in row order. Each knows its display
    /// name (for the conflict toast) and how to read its current value
    /// off AppSettings — which is what lets `conflictGuarded` compare a
    /// new combo against every OTHER slot without comparing bindings.
    private enum HotkeySlot: CaseIterable {
        case record, voiceNote, dictation, rewrite, layoutFix, markMoment, repaste

        var displayName: String {
            switch self {
            case .record: return String(localized: "Record a meeting")
            case .voiceNote: return String(localized: "Voice note")
            case .dictation: return String(localized: "Dictation")
            case .rewrite: return String(localized: "Rewrite in my voice")
            case .layoutFix: return String(localized: "Fix the keyboard layout")
            case .markMoment: return String(localized: "Mark this moment")
            case .repaste: return String(localized: "Paste my last dictation")
            }
        }

        func value(in settings: AppSettings) -> HotkeyChoice {
            switch self {
            case .record: return settings.recordHotkey
            case .voiceNote: return settings.voiceNoteHotkey
            case .dictation: return settings.dictationHotkey
            case .rewrite: return settings.rewriteSelectionHotkey
            case .layoutFix: return settings.layoutFixHotkey
            case .markMoment: return settings.markMomentHotkey
            case .repaste: return settings.repasteLastHotkey
            }
        }
    }

    /// Wrap a hotkey binding so an assignment that collides with another
    /// slot is REFUSED (toast naming the owner) instead of silently
    /// creating two actions on one combo — the field case was Fn bound
    /// to both Dictation and Paste-last, where only one ever fired.
    /// Comparison is keyCode + modifiers, not label, so a preset and an
    /// identical custom recording still collide. `.none` never conflicts.
    private func conflictGuarded(
        _ binding: Binding<HotkeyChoice>,
        slot: HotkeySlot
    ) -> Binding<HotkeyChoice> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                if let keyCode = newValue.keyCode {
                    let owner = HotkeySlot.allCases.first { other in
                        guard other != slot else { return false }
                        let existing = other.value(in: settings)
                        return existing.keyCode == keyCode
                            && (existing.modifiers ?? 0) == (newValue.modifiers ?? 0)
                    }
                    if let owner {
                        ToastCenter.shared.show(
                            String(localized: "\(newValue.label) is already assigned to “\(owner.displayName)”. Free it up there first."),
                            style: .warning
                        )
                        return
                    }
                }
                binding.wrappedValue = newValue
            }
        )
    }

    @ViewBuilder
    private func shortcutRow(
        title: LocalizedStringKey,
        caption: LocalizedStringKey,
        binding: Binding<HotkeyChoice>,
        slot: HotkeySlot,
        presets: [HotkeyChoice] = HotkeyChoice.allPresets
    ) -> some View {
        LabeledContent {
            hotkeyEditor(binding: conflictGuarded(binding, slot: slot), presets: presets)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func hotkeyEditor(
        binding: Binding<HotkeyChoice>,
        presets: [HotkeyChoice] = HotkeyChoice.allPresets
    ) -> some View {
        HStack(spacing: 8) {
            HotkeyRecorder(value: binding)
            Menu {
                ForEach(presets) { preset in
                    Button {
                        binding.wrappedValue = preset
                    } label: {
                        if preset.keyCode == nil {
                            if preset == binding.wrappedValue {
                                Label("Disabled", systemImage: "checkmark")
                            } else {
                                Text("Disabled")
                            }
                        // Fn preset gets the SF Symbol globe icon
                        // — matches the modern Mac keyboard glyph
                        // for the same key (kVK_Function).
                        } else if preset.isFnOnly {
                            Label(preset.label, systemImage: preset == binding.wrappedValue ? "checkmark" : "globe")
                        } else if preset == binding.wrappedValue {
                            Label(preset.label, systemImage: "checkmark")
                        } else {
                            Text(preset.label)
                        }
                    }
                }
            } label: {
                // Chevron-down reads as "this is a dropdown picker"
                // — the prior `list.bullet` icon was easy to misread
                // as a hamburger menu (i.e. "more actions") and
                // testers tried right-clicking it. Chevron matches
                // the rest of the macOS dropdown idiom.
                // Match the menu Pickers elsewhere in Settings (e.g.
                // Auto-record) — the up/down chevron is macOS's menu-
                // picker indicator, so the preset menu reads as the same
                // kind of control (Egor, 2026-06-13).
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Pick from presets")
        }
    }

    // MARK: - MCP summarizer wrapper presets

    /// Known local-LLM MCP wrappers. Each defines a sensible
    /// `(baseURL, toolName, argumentsTemplate)` triple so the user
    /// can pick from a Menu instead of hand-writing JSON.
    private enum MCPSummarizerPreset {
        case ollama
        case lmStudio
        case llamaCpp

        var baseURL: String {
            switch self {
            case .ollama:   return "http://127.0.0.1:11435"
            case .lmStudio: return "http://127.0.0.1:1234"
            case .llamaCpp: return "http://127.0.0.1:8080"
            }
        }
        var toolName: String {
            switch self {
            case .ollama, .lmStudio: return "chat"
            case .llamaCpp:          return "complete"
            }
        }
        var template: String {
            switch self {
            case .ollama:
                return """
                {
                  "model": "qwen3.5:4b",
                  "messages": [
                    {"role": "system", "content": "{{system}}"},
                    {"role": "user", "content": "{{transcript}}"}
                  ],
                  "format": "json"
                }
                """
            case .lmStudio:
                // No `response_format`: newer LM Studio rejects
                // `{"type":"json_object"}` with HTTP 400 (GitHub #5).
                // The prompt drives JSON; the decoder tolerates prose.
                return """
                {
                  "model": "qwen/qwen3.5-4b",
                  "messages": [
                    {"role": "system", "content": "{{system}}"},
                    {"role": "user", "content": "{{transcript}}"}
                  ]
                }
                """
            case .llamaCpp:
                return """
                {
                  "prompt": "{{system}}\\n\\n{{transcript}}",
                  "n_predict": 1024,
                  "temperature": 0.2
                }
                """
            }
        }
    }

    private func applyMCPSummarizerPreset(_ preset: MCPSummarizerPreset) {
        settings.mcpSummarizerURL = preset.baseURL
        settings.mcpSummarizerToolName = preset.toolName
        settings.mcpSummarizerArgumentsTemplate = preset.template
    }

    // MARK: - Storage (sessions folder)

    /// Row showing the currently-configured sessions folder + buttons
    /// to change or reset it. `storageRefreshTick` is bound to the
    /// HStack via `.id(...)` — that both reads the @State (so
    /// SwiftUI tracks it) and forces a fresh view identity each time
    /// the tick changes, which is exactly what we need since
    /// SessionsFolder reads UserDefaults directly (not @Observable).
    @ViewBuilder
    private var storageRow: some View {
        // 2026-05-25 — leading icons removed from all four Storage rows
        // (folder / clock.arrow.circlepath / trash / doc.text). Egor's
        // call: with row titles already strong ("Sessions folder",
        // "Delete audio after", "Clear all audio now", "Notion") the
        // icons were decoration, not navigation, and they pushed the
        // titles' x-position 28pt to the right vs the header text on
        // the same Form. Cleaner without them.
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recordings folder")
                    .font(.callout.weight(.medium))
                Text(storageDisplayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Button("Choose folder…") {
                    chooseRecordingsFolder()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.daisyTextPrimary)
                .disabled(storageChangeInProgress)
                if SessionsFolder.hasUserFolder {
                    // Was .borderless + tertiary grey — read as plain
                    // text, not as an actionable control. Promoted to
                    // .bordered with primary tint so it sits visually
                    // adjacent to Choose folder… as a peer secondary
                    // action.
                    Button("Reset to default") {
                        resetRecordingsFolder()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.daisyTextPrimary)
                    .disabled(storageChangeInProgress)
                }
            }
        }
        .id(storageRefreshTick)
        .confirmationDialog(
            "What should Daisy do with the existing recordings?",
            isPresented: $showingStorageChangeChoices,
            titleVisibility: .visible,
            presenting: pendingStorageChange
        ) { request in
            Button("Move them to the new folder") {
                runStorageChange(.move, request: request)
            }
            Button("Leave them where they are") {
                runStorageChange(.keep, request: request)
            }
            Button("Delete the existing recordings", role: .destructive) {
                DispatchQueue.main.async {
                    pendingStorageChange = request
                    showingStorageDeleteConfirmation = true
                }
            }
            Button("Cancel", role: .cancel) {
                pendingStorageChange = nil
            }
        } message: { request in
            if SessionsFolder.isCloudSynced(request.destinationBaseURL) {
                Text("Daisy found \(request.existingFolderCount) recording folders in the current location. Old folders left in place will remain visible in the Library, while new recordings will use the new location.\n\nNote: the new folder is synced with iCloud. With “Optimize Mac Storage” enabled, macOS can move recordings to the cloud when disk space runs low — they will show as “Stored in iCloud” until downloaded again. A folder outside iCloud is safer for recordings.")
            } else {
                Text("Daisy found \(request.existingFolderCount) recording folders in the current location. Old folders left in place will remain visible in the Library, while new recordings will use the new location.")
            }
        }
        .alert(
            "Move the existing recordings to the Trash?",
            isPresented: $showingStorageDeleteConfirmation,
            presenting: pendingStorageChange
        ) { request in
            Button("Cancel", role: .cancel) {
                pendingStorageChange = nil
            }
            Button("Move to Trash", role: .destructive) {
                runStorageChange(.delete, request: request)
            }
        } message: { request in
            Text("Daisy will move \(request.existingFolderCount) recording folders from the current location to the Trash. This does not affect files already stored elsewhere.")
        }
    }

    private var storageDisplayPath: String {
        SessionsFolder.userFolderDisplayPath()
            ?? SessionsFolder.defaultContainerLabel
    }

    private func chooseRecordingsFolder() {
        guard let destination = SessionsFolder.chooseFolder(),
              let request = SessionsFolderChange.prepare(destination: destination) else { return }
        beginStorageChange(request)
    }

    private func resetRecordingsFolder() {
        guard let destination = SessionsFolder.defaultBase(),
              let request = SessionsFolderChange.prepare(
                destination: destination,
                destinationIsDefault: true
              ) else { return }
        beginStorageChange(request)
    }

    private func beginStorageChange(_ request: SessionsFolderChangeRequest) {
        if !SessionsFolderChange.requiresUserDecision(request) {
            storageChangeInProgress = true
            Task {
                defer { storageChangeInProgress = false }
                do {
                    try await SessionsFolderChange.reauthorize(request)
                    storageRefreshTick &+= 1
                    ToastCenter.shared.show(
                        String(localized: "Recordings folder access restored."),
                        style: .success
                    )
                } catch {
                    ToastCenter.shared.show(error.localizedDescription, style: .error)
                }
            }
        } else {
            // Always ask on a real destination change. A zero count can mean
            // either an intentionally empty recordings folder or that the
            // previous location was temporarily unavailable while counting;
            // neither case is permission to choose a migration policy for
            // the user. Defer one run-loop turn so AppKit has fully dismissed
            // the folder picker before SwiftUI presents this dialog.
            DispatchQueue.main.async {
                pendingStorageChange = request
                showingStorageChangeChoices = true
            }
        }
    }

    private func runStorageChange(
        _ action: SessionsFolderExistingFilesAction,
        request: SessionsFolderChangeRequest
    ) {
        pendingStorageChange = nil
        storageChangeInProgress = true
        Task {
            defer { storageChangeInProgress = false }
            do {
                let report = try await SessionsFolderChange.apply(action, request: request)
                storageRefreshTick &+= 1
                audioCacheRefreshTick &+= 1
                if !report.isComplete, action != .keep {
                    let format = String(localized: "%lld recording folders could not be processed. They remain in the previous location and are still visible in the Library.")
                    ToastCenter.shared.show(
                        String.localizedStringWithFormat(format, Int64(report.remainingCount)),
                        style: .warning,
                        duration: .seconds(8)
                    )
                } else {
                    let message: String
                    switch action {
                    case .move:
                        message = String(localized: "Recordings moved to the new folder.")
                    case .delete:
                        message = String(localized: "Existing recordings moved to the Trash.")
                    case .keep:
                        message = String(localized: "Existing recordings will stay where they are and remain visible in the Library.")
                    }
                    ToastCenter.shared.show(message, style: .success)
                }
            } catch {
                storageRefreshTick &+= 1
                ToastCenter.shared.show(error.localizedDescription, style: .error, duration: .seconds(8))
            }
        }
    }

    // MARK: - Notion destination (under Storage)

    /// Notion destination row + auto-send toggle + DisclosureGroup
    /// containing the credentials, parent picker, and Test connection
    /// affordances. Lives next to `storageRow` because Notion is the
    /// same logical category — "where Daisy sends a finished meeting"
    /// — as the local sessions folder. Pre-1.0.5 this was a separate
    /// tab inside the Connections sidebar destination; testers found
    /// it hard to discover because they'd think of "where sessions
    /// go" as a single concept and end up looking in Settings first.
    /// "Clear audio cache" affordance — manual flush of all `.caf`
    /// audio archives across every session, regardless of the
    /// retention picker setting. Lives below the retention row so
    /// the user gets both the auto-trim and the one-shot
    /// "everything off the disk now" controls in the same place.
    /// Existing users who installed before audio retention shipped
    /// might have multi-GB caches; the row caption shows the
    /// current size so they can decide before clicking. Confirm
    /// alert prevents accidental purges — transcripts and
    /// summaries are NOT touched, but raw audio is unrecoverable
    /// once removed.
    @ViewBuilder
    private var clearAudioCacheRow: some View {
        let mb = Double(audioCacheBytes) / 1_048_576.0
        // 2026-05-25 UX-copy pass:
        //   - "across N file(s)" with parenthesised plural-s reads
        //     sloppy at N=1 ("1 file(s)") and was the most visible
        //     copy nit in any screenshot of this row. Switched to a
        //     proper singular/plural switch + middle dot (matches
        //     menu-bar formatting elsewhere in the app).
        //   - "Nothing to clear" stays as-is — fine.
        //   - "file" → "recording" — the user thinks of these as
        //     meeting recordings, not files. Same reason "cache" got
        //     dropped from the row title (dev word).
        let sizeText: String = {
            if audioCacheFiles == 0 { return String(localized: "No audio to delete") }
            let size: String
            if mb < 1024 { size = String(format: String(localized: "%.0f MB"), mb) }
            else { size = String(format: String(localized: "%.2f GB"), mb / 1024.0) }
            // No recording count here — it read as a contradiction next to
            // the "Delete recordings" row's count ("1 recording" vs "26
            // recordings"). The reassurance "keeps transcripts" is what
            // actually distinguishes this row from deleting whole recordings.
            return String(localized: "\(size) · keeps transcripts")
        }()
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                // Title weight bumped to .callout.medium for parity
                // with the other row titles in this Section
                // (Sessions folder / Notion). Without it the row
                // visually deemphasised itself, like an info row
                // instead of an actionable one.
                Text(String(localized: "Delete audio files"))
                    .font(.callout.weight(.medium))
                Text(sizeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // 2026-05-25 — dropped `role: .destructive` on the row
            // trigger. The role forces a system tint that renders
            // muddy peach in `.disabled` state on the cream / ivory
            // surface, and `role` overrides any explicit `.tint`
            // we set. Pre-fix the disabled button visually clashed
            // with the rest of the Section (toggles + secondary
            // buttons). Now: explicit red tint only when the action
            // is actually available; secondary grey when disabled.
            // The destructive intent still gets surfaced — inside
            // the confirm alert, where it belongs. This matches the
            // pattern in Linear / Things / Reeder where destructive
            // red lives in the confirm sheet, not the row trigger.
            // Also: "Clear…" → "Clear" — ellipsis = "more input
            // needed" per macOS HIG (file picker, text entry, etc).
            // A y/n confirm alert isn't more input, so the trailing
            // dot was just noise.
            Button {
                showingClearAudioConfirm = true
            } label: {
                if clearingAudioCache {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Delete")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(audioCacheFiles == 0 ? Color.secondary : Color.daisyError)
            .disabled(clearingAudioCache || audioCacheFiles == 0)
        }
        .task(id: audioCacheRefreshTick) {
            let result = await AudioRetentionSweep.currentCacheSize()
            audioCacheFiles = result.files
            audioCacheBytes = result.bytes
        }
        // 2026-05-25 alert copy rewrite:
        //   - "archives" → "recordings" (archive reads cold and
        //     mirrors the same backend-y term we got rid of in the
        //     row title).
        //   - alert message dropped `microphone.caf` /
        //     `system_audio.caf` filenames entirely — pure
        //     engineering leak, users don't know those names.
        //   - confirm button "Clear" → "Delete" to match the new
        //     alert title verb (consistency: title says delete,
        //     button says delete).
        //   - "Cleared X of audio" toast → "Freed X" — shorter,
        //     reads as a user benefit (space back) rather than
        //     restating the action.
        //   - "Audio cache was already empty" → "Nothing to clear —
        //     audio is already gone" mirrors the row caption when
        //     idle so the language is consistent before/after.
        .alert("Delete all audio files?", isPresented: $showingClearAudioConfirm) {
            Button("Delete", role: .destructive) {
                clearingAudioCache = true
                AudioRetentionSweep.runNow { _, freedBytes in
                    let mb = Double(freedBytes) / 1_048_576.0
                    let freedText: String = {
                        if mb < 1024 { return String(format: String(localized: "%.0f MB"), mb) }
                        return String(format: String(localized: "%.2f GB"), mb / 1024.0)
                    }()
                    ToastCenter.shared.show(
                        freedBytes > 0
                            ? String(localized: "Freed \(freedText)")
                            : String(localized: "Nothing to clear — audio is already gone"),
                        style: .success
                    )
                    clearingAudioCache = false
                    audioCacheRefreshTick += 1
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Daisy deletes the audio from every session right now. Transcripts, summaries and screenshots stay. This can't be undone.")
        }
    }

    // Notion destination (row + auto-send toggle + folder filter +
    // the credentials/parent/Test-connection sheet) moved to the
    // top-level Connections page → Auto-routing tab in 1.0.7.16 —
    // it's an external send-to destination, the same class as the MCP
    // integrations already there, not local recorder behaviour. The
    // views (notionDestinationRow / notionSettingsSheet /
    // notionStatusBadge / notionTestStatusView), copy (notionRowCaption
    // / notionToggleHelp), the testNotion() probe, and the
    // folder-filter + labelWithCaption helpers that only Notion used
    // now live in ConnectionsView. Calendar behaviour toggles came
    // back to Settings → General in 1.0.4, sitting next to the
    // auto-start trigger they conceptually neighbour; the EventKit
    // grant + status badge are in Settings → Permissions.

    // MARK: - General

    private var generalTab: some View {
        generalTabForm
    }

    private var generalTabForm: some View {
        Form {
            // ── Group 0: Profile ──────────────────────────────
            // Identity used to label the mic-side of transcripts.
            // Empty by default → falls back to the generic "Me".
            // First section in General because it answers the
            // narrative question "who am I in this app" before
            // "what mic, where files, etc.". Section was originally
            // "You" — renamed to "Profile" to match the macOS
            // Settings convention (System Settings → Privacy & Security
            // → "Profiles", Mail → "Profiles"), which reads as a
            // labelled identity container rather than a pronoun.
            Section {
                // 2026-05-25 — caption ("Replaces \"Me\" in transcripts
                // and lets the summarizer address you by name") removed.
                // The label "Your name" + the placeholder "e.g. Egor"
                // already carry intent for anyone scanning Settings;
                // the longer rationale moved to a tooltip on a
                // post-PH polish if it turns out we need it. Dropping
                // the caption also kills Form's auto-inserted row
                // separator since the Section now has a single row —
                // no more half-divider underneath the field.
                LabeledContent("Your name") {
                    TextField("", text: $settings.userDisplayName, prompt: Text("e.g. Egor"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity)
                }
            } header: {
                Text("Profile")
            }

            // ── Appearance ────────────────────────────────────
            // Single home for every on-screen display setting Daisy
            // exposes (1.0.7.19). Consolidated from three scattered
            // homes: the menu-bar / widget toggles were in Recording's
            // "Menu bar & widget" section, the live-preview + live-
            // transcript controls were in Transcription. Grouped here
            // because they all answer one question — "how does Daisy
            // show up on screen" — independent of audio I/O or how the
            // recorder processes a session.
            Section {
                // Interface language override. Default = follow macOS
                // (per-app language can also be set in System Settings →
                // Language & Region). Uses the standard `AppleLanguages`
                // override, which only applies on the next launch.
                Picker("Language", selection: appLanguageBinding) {
                    Text("System").tag("system")
                    Text("English").tag("en")
                    Text("Русский").tag("ru")
                }
                .pickerStyle(.menu)
                .alert("Restart Daisy?", isPresented: $showLanguageRestartAlert) {
                    Button("Restart Now") { relaunchDaisy() }
                    Button("Later", role: .cancel) {}
                } message: {
                    Text("The interface language changes after Daisy restarts.")
                }

                Picker("Theme", selection: $settings.appAppearance) {
                    Text("Automatic").tag(AppearancePreference.system)
                    Text("Light").tag(AppearancePreference.light)
                    Text("Dark").tag(AppearancePreference.dark)
                }
                .pickerStyle(.segmented)

                Toggle(isOn: $settings.compactMenuBarOnly) {
                    Text("Compact menu bar")
                    Text("Clicking the menu-bar icon opens a quick dropdown menu instead of the live transcription window. The Dock icon and app menus stay.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Floating widget", isOn: $settings.floatingWidgetEnabled)
                Toggle("Show next meeting in the menu bar", isOn: $settings.menuBarShowsNextMeeting)
                    .disabled(!hasAnyCalendarSource)

                // ("Live preview while dictating" moved BACK to
                // Transcription in 1.0.7.31 — it is an engine/performance
                // control, not an on-screen-appearance one; the 2026-07
                // audit flagged the mislocation.)

                // ("Live transcript" tier moved BACK to Transcription in
                // 1.0.7.31 — same reasoning as the live-preview toggle.)
            } header: {
                Text("Appearance")
            } footer: {
                if !hasAnyCalendarSource {
                    Text("Showing the next meeting needs calendar access in Settings → Permissions.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // (Audio/mic, Shortcuts, Meetings moved to the "Recording"
            // tab in 1.0.7.16. The menu-bar / widget toggles + the live-
            // preview / live-transcript controls were pulled into the
            // "Appearance" section above in 1.0.7.19. General is now
            // app-level prefs: Profile, Appearance, Storage, Privacy,
            // Notifications.)

            // ── Group 2: Storage / Privacy ────────────────────
            // Split (1.0.7.16) from one "Storage" section that conflated
            // three things: where files live, the retention/privacy
            // choice, and the optional Notion export.
            Section {
                storageRow
                clearAudioCacheRow
                BulkDeleteRecordingsView()
            } header: {
                Text("Storage")
            }

            Section {
                // Retention / privacy posture. "Don't record audio" is the
                // strongest stance; the rest are a time-to-live. Per-session
                // purge fires from RecordingSession.finalizePostStop; the
                // time options are swept by AudioRetentionSweep.
                HStack(alignment: .center, spacing: 10) {
                    Text("Delete audio after")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Picker("", selection: $settings.audioRetentionDays) {
                        Text("Don't record audio")
                            .tag(AppSettings.audioRetentionDoNotRecord)
                        Text("After transcription")
                            .tag(AppSettings.audioRetentionDeleteAfterTranscription)
                        Text("24 hours").tag(1)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("Keep forever").tag(0)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: settings.audioRetentionDays) { _, new in
                        AudioRetentionSweep.runIfNeeded(retentionDays: new)
                        // Warn that the no-audio mode forfeits crash recovery:
                        // with no .caf on disk, an interrupted session can't be
                        // rebuilt — only finished sessions keep their transcript.
                        if new == AppSettings.audioRetentionDoNotRecord {
                            ToastCenter.shared.show(
                                String(localized: "Audio won't be saved to disk. If a recording is interrupted — a crash or power loss — it can't be recovered; only sessions you finish keep their transcript."),
                                style: .warning,
                                duration: .seconds(8)
                            )
                        }
                    }
                }
            } header: {
                Text("Privacy")
            }

            // (Notion "Send to" moved to the Connections page in 1.0.7.16
            // — it's an external destination, not local storage. Shortcuts
            // and Meetings moved to the new "Recording" tab.)

            // ── Notifications ─────────────────────────────────
            // One picker instead of four per-class toggles (2026-07
            // audit: four separate decisions where one preset covers
            // everyone). The four underlying settings stay the source
            // of truth — the picker just writes presets into them, so
            // every consumer (SoundEffects, auto-start/stop banners,
            // SilenceMonitor) is untouched and a user who set a custom
            // mix via an older build sees an honest "Custom" row.
            Section {
                Picker(selection: notificationLevelBinding) {
                    Text("All").tag(NotificationLevel.all)
                    Text("Important only").tag(NotificationLevel.important)
                    Text("Off").tag(NotificationLevel.off)
                    if notificationLevelBinding.wrappedValue == .custom {
                        Text("Custom").tag(NotificationLevel.custom)
                    }
                } label: {
                    Text("Notifications")
                    Text(notificationLevelCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .pickerStyle(.menu)
            } header: {
                Text("Notifications")
            }

            // ── Library folders ───────────────────────────────
            // Create / rename / delete custom Library folders. The store
            // + sidebar already support custom folders; this is the
            // management UI that was missing (1.0.7.24).
            FolderManagementSection(settings: settings)

            // Auto-summary lives in the Summary tab — it sits next
            // to the provider config it depends on.

        }
        .formStyle(.grouped)
    }

    // MARK: - Recording tab (split out of General, 1.0.7.16)

    private var recordingTab: some View {
        recordingTabForm
    }

    private var recordingTabForm: some View {
        Form {
            RecordingAudioSettingsSection(settings: settings)

            // ── Shortcuts ─────────────────────────────────────
            // One hotkey per recording mode. Each row offers the
            // recorder ("Press keys…") AND a preset Menu — the preset is
            // the only reliable way to bind Fn / 🌐 / F-keys on macOS.
            Section {
                shortcutRow(
                    title: "Record a meeting",
                    caption: "Tap once to start, tap again to pause / resume",
                    binding: $settings.recordHotkey,
                    slot: .record
                )
                shortcutRow(
                    title: "Voice note",
                    caption: "Tap once to start, tap again to stop",
                    binding: $settings.voiceNoteHotkey,
                    slot: .voiceNote
                )
                shortcutRow(
                    title: "Dictation",
                    caption: "Hold to talk, release to paste",
                    binding: $settings.dictationHotkey,
                    slot: .dictation
                )
                shortcutRow(
                    title: "Rewrite in my voice",
                    caption: "Select text anywhere, tap to rewrite it in your tone (needs a Voice Profile)",
                    binding: $settings.rewriteSelectionHotkey,
                    slot: .rewrite
                )
                shortcutRow(
                    title: "Fix the keyboard layout",
                    caption: "«ghbdtn» becomes «привет» — the selection, or the word you're typing",
                    binding: $settings.layoutFixHotkey,
                    slot: .layoutFix
                )
                shortcutRow(
                    title: "Mark this moment",
                    caption: "While recording, flag the minute you’re in — it lands in the transcript and leads the summary",
                    binding: $settings.markMomentHotkey,
                    slot: .markMoment
                )
                shortcutRow(
                    title: "Paste my last dictation",
                    caption: "Re-inserts your most recent dictation at the cursor — for when it landed in the wrong window or nowhere at all",
                    binding: $settings.repasteLastHotkey,
                    slot: .repaste,
                    // V-presets: paste mnemonic (⌘V muscle memory),
                    // not the record/dictate letters the other rows use.
                    presets: HotkeyChoice.pastePresets
                )
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shortcuts")
                    Text("Combos must include ⌘ / ⌃ / ⌥, a bare function key (F1–F20), or the globe Fn key.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textCase(nil)
                }
            }

            // ── Meetings ──────────────────────────────────────
            Section {
                Picker("Auto-record", selection: $settings.autoStartPolicy) {
                    ForEach(AutoStartPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .pickerStyle(.menu)

                // Only where app detection actually runs. Under
                // "Meetings with a link" and "Off" the app-launch
                // detector is switched off entirely, and a list of apps
                // sitting there would promise something that can't
                // happen. See AutoStartPolicy's substrate mapping.
                if settings.autoStartPolicy == .always || settings.autoStartPolicy == .prompt {
                    meetingAppsRow
                }

                Toggle(isOn: $settings.workingHoursEnabled) {
                    Text("Track working hours")
                    Text("Used only for the local Home dashboard: daily meeting load and time outside your workday.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if settings.workingHoursEnabled {
                    LabeledContent("Working day") {
                        HStack(spacing: 8) {
                            Picker("From", selection: $settings.workingDayStartMinutes) {
                                ForEach(Array(stride(from: 0, through: 22 * 60 + 30, by: 30)), id: \.self) { minutes in
                                    Text(workingTimeLabel(minutes)).tag(minutes)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 92)

                            Text("to")
                                .foregroundStyle(.secondary)

                            Picker("To", selection: $settings.workingDayEndMinutes) {
                                ForEach(Array(stride(from: settings.workingDayStartMinutes + 30, through: 24 * 60, by: 30)), id: \.self) { minutes in
                                    Text(workingTimeLabel(minutes)).tag(minutes)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 92)
                        }
                    }
                    .onChange(of: settings.workingDayStartMinutes) { _, start in
                        if settings.workingDayEndMinutes <= start {
                            settings.workingDayEndMinutes = min(start + 8 * 60, 24 * 60)
                        }
                    }
                }

                // Applies to every recording (not just meetings) → ungated,
                // above the calendar-only row.
                Toggle("Open the session window when recording stops", isOn: $settings.showSessionAfterStop)

                // Screen-content capture + on-device OCR. Off by default;
                // needs Screen Recording permission. Reinstated with a
                // clearer pitch after being parked (UI-only) in 1.0.7.16.
                Toggle(isOn: $settings.screenshotsEnabled) {
                    Text("Capture what's shared on screen")
                    Text("Periodically captures your screen while recording, reads the text on-device (slides, dashboards, docs), and folds it into the transcript and summary — searchable even if never said aloud. Needs Screen Recording permission; stays on your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if settings.screenshotsEnabled {
                    Picker("Capture every", selection: $settings.screenshotIntervalSec) {
                        Text("15 seconds").tag(15)
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("2 minutes").tag(120)
                    }
                    .pickerStyle(.menu)
                    Toggle(isOn: $settings.screenTextInSummary) {
                        Text("Use screen text in summaries")
                        Text("Off keeps it in the transcript and in search, but out of the summary — useful when what's on screen is unrelated to the conversation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Independent of the capture toggle above: that one is
                // about meetings, this one is about the screenshots the
                // user takes themselves, at any time.
                Toggle(isOn: $settings.screenshotNotesEnabled) {
                    Text("Turn my screenshots into notes")
                    Text("Every screenshot you take becomes a note with the image in it. Right after, hold your dictation key to say what it was about — that goes into the same note instead of being pasted. Daisy copies the picture and never touches your original.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Calendar-only. Merged on/off + grace: -1 → off, 0 → ask
                // at the scheduled end, 300 → 5 min after (the grace also
                // doubles as the rejoin window). Since 2026-08-21 Daisy
                // never stops on its own — the timing gates raise the
                // «Stop & save?» widget bubble, so the copy says "ask",
                // and the old "Ask before auto-stopping" toggle is gone
                // (asking IS the only behaviour now; the persisted
                // autoStopPromptMode flag stays, unread).
                Picker("Ask to stop when the meeting ends", selection: autoStopSelection) {
                    Text("Off").tag(-1)
                    Text("At the scheduled end").tag(0)
                    Text("5 minutes after").tag(300)
                }
                .pickerStyle(.menu)
                .disabled(!hasAnyCalendarSource)
            } header: {
                Text("Meetings")
            } footer: {
                if !hasAnyCalendarSource {
                    Text("Calendar-based options need access in Settings → Permissions. Daisy reads via macOS Calendar — iCloud, Exchange, and any Google accounts you've added to Calendar.app.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // (The "Menu bar & widget" section — compact / floating
            // widget / show-next-meeting toggles — moved to General →
            // "Appearance" in 1.0.7.19, consolidating every on-screen
            // display setting in one place.)
        }
        .formStyle(.grouped)
    }

    /// At least one calendar source is connected — Apple EventKit
    /// (`.fullAccess` granted) OR Google via direct OAuth. Gates the
    /// behaviour toggles in the Calendar section of generalTab; the
    /// underlying grant/connect affordances live elsewhere
    /// (EventKit in Settings → Permissions, Google in Connections
    /// once verification clears).
    ///
    /// Reads the LIVE `CalendarService.authorizationStatus`, not the
    /// persisted `settings.calendarAccessGranted` cache. Pre-1.0.4 the
    /// gate used the cached bool, which could lag behind the real
    /// EventKit state — a tester with Apple Calendar granted in
    /// System Settings → Privacy & Security but a stale UserDefaults
    /// bool saw every toggle in this section disabled even though
    /// Permissions tab correctly said "Granted". Same observable
    /// (`@Bindable var calendarService = CalendarService.shared`) the
    /// Permissions tab reads, so the two surfaces can't diverge.
    private var hasAnyCalendarSource: Bool {
        systemPermissions.calendar == .granted || googleAccount.isConnected
    }

    /// One selector standing in for the old auto-stop toggle + grace
    /// picker. -1 = off; otherwise on, with the value as the grace (also
    /// the rejoin window). A stored grace that isn't one of the offered
    /// options shows as "5 minutes after" until the user re-picks.
    private var autoStopSelection: Binding<Int> {
        Binding(
            get: {
                guard settings.autoStopFromCalendar else { return -1 }
                return settings.autoStopGraceSec == 0 ? 0 : 300
            },
            set: { newValue in
                if newValue < 0 {
                    settings.autoStopFromCalendar = false
                } else {
                    settings.autoStopFromCalendar = true
                    settings.autoStopGraceSec = newValue
                }
            }
        )
    }

    /// Locale-aware half-hour labels for the workday pickers. 1440 is a
    /// useful end-of-day sentinel but Date wraps it to tomorrow's 00:00,
    /// which is exactly the label we want.
    private func workingTimeLabel(_ minutes: Int) -> String {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let day = calendar.startOfDay(for: Date())
        let date = calendar.date(byAdding: .minute, value: minutes, to: day) ?? day
        return date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Transcription (Whisper)

    private var transcriptionTab: some View {
        Form {
            // One "Transcription" block, two rows. Friendly names (no model
            // IDs / engine vendor names), no helper captions, no separate
            // status rows or buttons — each row's status (and model download
            // progress) rides as a badge next to its label. Meetings (+
            // voice notes) always use the Whisper model on row 1; dictation
            // picks its engine on row 2 (Default = Whisper, reusing that
            // model; Faster = on-device Parakeet, ~600 MB once).
            Section {
                Picker(selection: $whisper.modelID) {
                    ForEach(WhisperEngine.availableModels, id: \.id) { model in
                        let size = model.sizeMB >= 1000
                            ? String(format: String(localized: "%.1f GB"), Double(model.sizeMB) / 1000.0)
                            : String(localized: "\(model.sizeMB) MB")
                        let name = model.id == WhisperEngine.defaultModelID
                            ? "Standard" : String(localized: "Most accurate")
                        Text("\(name) · \(size)").tag(model.id)
                    }
                } label: {
                    transcriptionRowLabel(
                        "Meeting model",
                        state: whisperBadgeState,
                        message: whisperShortStatus
                    )
                }
                .pickerStyle(.menu)

                Picker(selection: $settings.dictationEngine) {
                    Text(DictationEngine.whisper.displayName).tag(DictationEngine.whisper)
                    Text(DictationEngine.parakeet.displayName).tag(DictationEngine.parakeet)
                    // Apple SpeechAnalyzer only exists on macOS 26 — hide
                    // the option below that so users can't pick a dead end.
                    if #available(macOS 26, *) {
                        Text(DictationEngine.appleSpeech.displayName).tag(DictationEngine.appleSpeech)
                    }
                } label: {
                    transcriptionRowLabel(
                        "Dictation engine",
                        state: dictationBadgeState,
                        message: dictationShortStatus
                    )
                }
                .pickerStyle(.menu)
                // Selecting "Faster" (or reopening Settings while it's
                // already chosen) kicks the Parakeet download so its badge
                // shows progress — no separate button; the badge IS the
                // download indicator. Apple needs no download here (the
                // model ships with the OS; first use pulls it in the
                // background from the dictation path).
                .onChange(of: settings.dictationEngine) { _, engine in
                    if engine == .parakeet { Task { await ParakeetEngine.shared.ensureLoaded() } }
                    // Re-scan models on disk now so the "Models" row and
                    // "Remove unused" reflect the new engine immediately.
                    cacheRefreshTick &+= 1
                }
                .onChange(of: parakeet.isReady) { _, _ in
                    // Parakeet finished downloading/loading → refresh the
                    // models size + count without waiting for a reopen.
                    cacheRefreshTick &+= 1
                }
                .onAppear {
                    if settings.dictationEngine == .parakeet, !parakeet.isReady {
                        Task { await ParakeetEngine.shared.ensureLoaded() }
                    }
                }
                if settings.dictationEngine == .appleSpeech {
                    Text("Uses the speech model built into macOS 26 — no download, ~2× faster than Whisper, nothing added to Daisy’s size. Needs a specific language below (not Auto); otherwise dictation falls back to Whisper.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Built-in brand layer (Egor 2026-07-25) — the only way
                // the Faster engine (no vocabulary biasing) gets product
                // names in Latin when you dictate in Russian & co.
                Toggle(isOn: $settings.fixBrandNamesInDictation) {
                    Text("Fix product names")
                }
                .help("Restores product names spoken in another script to their Latin spelling — «фигма» becomes Figma, «гитхаб» becomes GitHub. Applies to dictation and to recorded meetings, on every engine; your own Vocabulary rules always win.")

                // Streaming live preview for dictation (Nemotron 3.5,
                // on-device). The badge doubles as the model-download
                // indicator — same pattern as the Faster engine in
                // Transcription. Preview-only: the pasted text still comes
                // from the dictation engine picked in Transcription.
                Toggle(isOn: $settings.dictationUseNemotronLive) {
                    transcriptionRowLabel(
                        "Live preview while dictating",
                        state: nemotronBadgeState,
                        message: nemotronShortStatus
                    )
                }
                .help("Shows your words about half a second behind your speech while you hold the dictation key. The pasted text still comes from the dictation engine above. Turning this on downloads an on-device model once.")
                .onChange(of: settings.dictationUseNemotronLive) { _, useNemotron in
                    if useNemotron { Task { await NemotronLiveEngine.shared.ensureLoaded() } }
                }
                .onAppear {
                    if settings.dictationUseNemotronLive, !nemotron.isReady {
                        Task { await NemotronLiveEngine.shared.ensureLoaded() }
                    }
                }

                // One transcription language for everything (meetings,
                // voice notes, dictation). Per-mode overrides were removed
                // 2026-06-05 — nobody set them separately, and the recorder
                // header still offers a per-session override. Pinning a
                // language kills auto-detect drift (e.g. a Russian opener
                // mis-decoded as French). Voice-note / dictation locale
                // fields stay in the model defaulting to "inherit", so this
                // single pick drives all three modes.
                Picker("Language", selection: $settings.defaultTranscriptionLocale) {
                    ForEach(Transcriber.availableLocales, id: \.id) { locale in
                        Text(locale.label).tag(locale.id)
                    }
                }
                .pickerStyle(.menu)

                // Live-transcript tier — how the toolbar transcript updates
                // during a meeting. Plain names: Default (was "Lite") is the
                // sensible default; Full is heavier; Off transcribes once on
                // Stop. The final saved transcript is always full quality,
                // and dictation always runs live regardless of this.
                Picker("Live transcript", selection: $settings.liveTranscriptionTier) {
                    Text("Off").tag(LiveTranscriptionTier.off)
                    Text("Standard").tag(LiveTranscriptionTier.lite)
                    Text("Full · uses more memory").tag(LiveTranscriptionTier.full)
                }
                .pickerStyle(.menu)
            } header: {
                Text("Transcription")
            }

            // ── Keyboard layout ───────────────────────────────
            // Typed-text sibling of "Fix product names" above: same job
            // (put the characters the user meant on screen), different
            // input. The shortcut itself is bound in Recording →
            // Shortcuts with the others.
            Section {
                Toggle(isOn: $settings.layoutFixAuto) {
                    Text("Fix the layout as I type")
                }
                .help("Corrects words that are gibberish in one layout and a real word in another, as you finish them — including the word you press Return on. Needs Accessibility access.")

                Toggle(isOn: $settings.layoutFixSwitchesSource) {
                    Text("Switch the input source after a fix")
                }
                .help("Otherwise the fix lands on one word and the next one goes wrong the same way.")

                // Undo (one press of the fix shortcut, right after a fix)
                // teaches the exceptions list — this row is where that
                // memory becomes visible and, if it's ever wrong, undoable
                // itself.
                HStack {
                    Text("Words Daisy doesn't touch: \(layoutFixExceptions.count)")
                        .font(.callout)
                    Spacer()
                    Button("Clear") {
                        layoutFixExceptions.clear()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(layoutFixExceptions.count == 0)
                }
                .help("Undoing a fix (press the shortcut right after) adds the word here so Daisy leaves it alone from then on.")
            } header: {
                Text("Keyboard layout")
            } footer: {
                Text("The shortcut fixes selected text in compatible apps. Automatic fixing decides while you're still typing the word, using the spell-check dictionaries already on your Mac, so a word you finish with Return is corrected before it's sent. Nothing is stored or sent anywhere, and it stands down in password fields, terminals, IDEs, password managers and remote desktops. Needs Accessibility access.")
            }

            // Diarization above Language in 1.0.6: it's a structural
            // "how is the audio interpreted" choice, same family as
            // Model — Language is downstream content-level. Sized
            // down the description too; the long version moved to
            // the footer.
            Section {
                // 2026-05-25 — primary "Speakers mode" picker added in
                // 1.0.7. Two modes:
                //  • Split (true, default) = current behavior;
                //    pyannote diarizes the system stream into separate
                //    Remote A / Remote B / Remote C clusters.
                //  • Two sides (false) = Granola-style. System stream
                //    gets a single "Remote" label regardless of how
                //    many voices. Mic stream is still "you".
                // 2026-05-26 — renamed "All speakers" → "Split" to
                // match the verb form of the action ("split each
                // voice into its own row") and pair-cadence-wise
                // with "Two sides" (1-2 syllables each).
                // Strings consolidated to EN in 1.0.7 — the picker
                // shipped briefly with RU radio labels + EN section
                // chrome, which broke the language rhythm of the rest
                // of the Whisper form. Whole form is EN, so are these.
                // Caption under the picker and the section footer
                // were both removed shortly after: both quoted the
                // "Two sides" label literally, which read like a live
                // status of which mode was active and contradicted
                // the actual selection (e.g. radio on "All speakers"
                // with caption "Pick 'Two sides' if…" feels like a
                // bug to the user even when the copy is descriptive).
                // The option names alone are self-explanatory; no
                // example-name parenthesis either — they overloaded
                // the row with internal-jargon proper nouns.
                // pickerStyle(.menu): dropdowns (NSPopUpButton), matching
                // every other picker in this form (1.0.7.16 — was
                // .radioGroup). DO NOT switch these to .inline / .segmented:
                // that routes through NSSegmentedControl, which hits a macOS
                // 26.2 use-after-free in the Swift-concurrency↔AppKit bridge
                // and crashes when the picker re-lays-out mid-cycle (repro'd
                // build 36: start → silent recording → restart). Both .menu
                // (popup) and .radioGroup (real NSButtons) are off that UAF
                // stack; we use .menu for form consistency.
                //
                // Labels renamed 2026-05-28 from "Split"/"Two sides" to
                // "Per speaker"/"Me vs. others" because the original
                // labels collided with the sidebar's "Recording both
                // sides" status pill — a user reported the conflict in
                // the same crash thread. New labels describe what shows
                // up in the transcript (per-speaker rows vs. just me
                // and everyone-else) without borrowing "sides" vocab.
                Picker(selection: $settings.diarizeRemoteSpeakers) {
                    Text("Per speaker")
                        .tag(true)
                    Text("Me and others")
                        .tag(false)
                } label: {
                    Text("Speakers in transcript")
                }
                .pickerStyle(.menu)

                // Moved in from the old "Speaker matching" section (merged
                // 1.0.7.16). Same .menu style as the rest of the form.
                Picker(selection: $settings.speakerMatchMode) {
                    ForEach(SpeakerMatchMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                } label: {
                    Text("Name known people")
                }
                .pickerStyle(.menu)
                Text(speakerMatchModeHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $settings.diarizeMicrophone) {
                    Text("Split voices in my mic")
                    Text("When other people are heard through your speakers, label them separately instead of all as “Me.”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: $settings.suppressAcousticEcho) {
                    Text("Remove echo from my mic")
                    Text("Drops lines your mic catches as an echo when a meeting plays through your speakers instead of headphones.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Previously defaults-only, with the doc comment saying
                // "flip via defaults for testing". It's surfaced now so
                // the A/B can happen on real meetings; still default OFF
                // and still honestly described as a gamble, because the
                // attendee count is a hard constraint on the diarizer
                // and the invite is a noisy proxy for who actually
                // showed up.
                Toggle(isOn: $settings.diarizeUseAttendeeCountHint) {
                    Text("Use the invite’s headcount")
                    Text("For calendar meetings, tells the speaker-splitter exactly how many people to expect. Sharpens it when the invite is accurate — and makes it worse when it isn’t (no-shows, someone who wasn’t invited, one person on two devices). Experimental.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Speakers")
            }

            // "Match known speakers" moved into the merged "Speakers"
            // section above (1.0.7.16) as "Name known people".
            // "Models" cache section moved BELOW "Known speakers"
            // (1.0.7.16) — it's disk maintenance, was splitting the two
            // speaker sections.

            // Known speakers — persistent voice profiles store. Lets
            // the user inspect what biometric derivatives Daisy has
            // saved, edit a person's emails/notes, forget individual
            // profiles, or wipe the whole store. This is a privacy-
            // required surface — without it
            // there's no way to delete enrollment data short of
            // resetting the app container.
            Section {
                speakerProfilesRow
            } header: {
                Text("Known speakers")
            } footer: {
                Text("After you name a speaker in a transcript (e.g. \"Alex\"), Daisy stores a short voice fingerprint locally and auto-labels them in future recordings. Open a speaker to add their email (so calendar invites match them too) or notes. Fingerprints never leave your Mac. Forget anytime.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // On-disk model cache (maintenance) — kept last on the tab,
            // after the speaker content it used to interrupt.
            Section {
                if isDownloadingModel { modelDownloadCancelRow }
                modelsCacheRow
                downloadModelsNowRow
            } header: {
                Text("Models")
            } footer: {
                Text("Models update only when Daisy updates. Pull any missing ones ahead of time so a download never interrupts a recording.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // ── Voice Memos import (moved to bottom of Transcription,
            // 2026-06-24) ─────────────────────────────────────────
            VoiceMemoImportSection(settings: settings)
        }
        .formStyle(.grouped)
        .task(id: cacheRefreshTick) {
            // Refresh on tab open + after any cleanup. Detached so a slow
            // FileManager scan never blocks the form's first paint. Counts
            // BOTH the Whisper models and the dictation engine (Parakeet)
            // model on disk.
            let w = await Task.detached {
                (WhisperEngine.cachedModels().count, WhisperEngine.totalCacheSizeBytes())
            }.value
            let p = await Task.detached {
                (ParakeetEngine.cachedModelCount(), ParakeetEngine.cachedModelBytes())
            }.value
            cachedModelsCount = w.0 + p.0
            cachedModelsBytes = w.1 + p.1
            hasUnusedModels = (w.0 > 1) || (p.0 > 0 && !settings.dictationUseParakeet)
        }
    }

    /// True while either the meeting (Whisper) or dictation (Parakeet)
    /// model is actively downloading — drives the Stop-download row.
    private var isDownloadingModel: Bool {
        if case .downloading = whisper.state { return true }
        if case .downloading = parakeet.state { return true }
        return false
    }

    /// Progress + Stop button shown while a model download is running, so
    /// the user can abort a slow/stuck download instead of waiting it out.
    @ViewBuilder
    private var modelDownloadCancelRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(modelDownloadLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Stop") {
                whisper.cancelDownload()
                parakeet.cancelDownload()
                cacheRefreshTick &+= 1
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Color.daisyTextPrimary)
        }
    }

    private var modelDownloadLabel: String {
        if case .downloading(let p) = whisper.state {
            return String(localized: "Downloading meeting model… \(Int(p * 100))%")
        }
        if case .downloading(let p) = parakeet.state {
            return String(localized: "Downloading dictation model… \(Int(p * 100))%")
        }
        return String(localized: "Downloading model…")
    }

    /// Manually pull any missing models (meeting = Whisper, the selected
    /// dictation engine, and the diarizer) so the app is fully offline-
    /// ready. There's no model auto-update: model versions ride along with
    /// Daisy app updates, so this only downloads what's missing.
    @ViewBuilder
    private var downloadModelsNowRow: some View {
        Button {
            Task { await downloadAllModels() }
        } label: {
            Text(isDownloadingModel
                 ? String(localized: "Downloading…")
                 : String(localized: "Download models now"))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(Color.daisyTextPrimary)
        .disabled(isDownloadingModel)
    }

    private func downloadAllModels() async {
        await whisper.ensureLoaded()
        switch settings.dictationEngine {
        case .whisper:
            break  // covered by the Whisper load above
        case .parakeet:
            await ParakeetEngine.shared.ensureLoaded()
        case .appleSpeech:
            if #available(macOS 26, *) {
                let localeID = settings.dictationLocale.isEmpty
                    ? settings.defaultTranscriptionLocale
                    : settings.dictationLocale
                if localeID != "auto", !localeID.isEmpty {
                    _ = await AppleSpeechEngine.ensureModelReady(locale: Locale(identifier: localeID))
                }
            }
        }
        await DiarizationEngine.shared.ensureLoaded()
        cacheRefreshTick &+= 1
        let ok = whisper.isReady
        ToastCenter.shared.show(
            ok ? String(localized: "Models ready.")
               : String(localized: "Couldn’t download some models — check your connection and try again."),
            style: ok ? .success : .error
        )
    }

    /// Models-on-disk summary row + Remove-unused action. Disabled
    /// when there's only one cached variant (current one), so the
    /// button never appears actionable when there's nothing it
    /// could do.
    @ViewBuilder
    private var modelsCacheRow: some View {
        HStack(spacing: 8) {
            Text("\(cachedModelsCount) models · \(formattedCacheSize)")
                .monospacedDigit()
            Spacer()
            Button("Remove unused") {
                Task {
                    var freed = await whisper.removeUnusedModels()
                    // The Parakeet model is "unused" when dictation isn't
                    // set to it — free it too.
                    if !settings.dictationUseParakeet {
                        freed += ParakeetEngine.removeCachedModel()
                    }
                    cacheRefreshTick &+= 1
                    if freed > 0 {
                        ToastCenter.shared.show(
                            String(localized: "Freed \(byteFormatter.string(fromByteCount: freed)) of model cache."),
                            style: .success
                        )
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Color.daisyTextPrimary)
            .disabled(!hasUnusedModels || isWhisperLoading)
        }
    }

    private var formattedCacheSize: String {
        byteFormatter.string(fromByteCount: cachedModelsBytes)
    }

    /// Bind directly to the singleton so the row re-renders when the
    /// store mutates (forget, upsert, etc.). Lifecycle-attached to
    /// the view; no need to retain elsewhere.
    @Bindable private var speakerStore = SpeakerProfileStore.shared

    /// Profile the user tapped to inspect / edit. Drives the speaker
    /// detail sheet (emails, notes, "appears in"). nil = no sheet.
    /// We key off the UUID rather than holding the value type so the
    /// sheet always reads the freshest profile from the store after
    /// an edit, and so a Forget from inside the sheet can dismiss
    /// cleanly without a dangling stale copy. Wrapped in a tiny
    /// Identifiable box because UUID isn't Identifiable on its own and
    /// `.sheet(item:)` needs Identifiable (we avoid an app-wide
    /// `extension UUID: Identifiable`, which would risk a conflict).
    @State private var editingSpeaker: EditingSpeaker?

    /// Identifiable wrapper for the speaker-detail sheet's `item:`
    /// binding. `id` IS the profile UUID.
    private struct EditingSpeaker: Identifiable {
        let id: UUID
    }

    /// Per-mode explainer under the speaker-match picker — one sentence
    /// per mode in Daisy's plain voice. DEFAULT is Automatic — preserve
    /// the long-standing behaviour, so its copy reads as "the normal thing".
    private var speakerMatchModeHelp: String {
        switch settings.speakerMatchMode {
        case .automatic:
            return String(localized: "Daisy labels a recognized person automatically as soon as a recording finishes — by their voice, or by their email if the meeting came from your calendar. This is the default.")
        case .suggest:
            return String(localized: "Daisy recognizes the person but waits — it shows the name as a suggestion in the recording's “Name the speakers” card, and you confirm before it's applied.")
        case .off:
            return String(localized: "Daisy never auto-labels across meetings. Speakers stay “Remote A / B” until you name them by hand. Voice fingerprints are still saved when you name someone, so you can switch this back on later.")
        }
    }

    /// Lists every known speaker profile in most-recently-seen order
    /// with per-row "Forget" + a global "Forget all" button. Hides
    /// gracefully when no profiles exist so first-time users don't
    /// see an empty placeholder card.
    @ViewBuilder
    private var speakerProfilesRow: some View {
        let profiles = speakerStore.profilesByRecent
        if profiles.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "person.2")
                    .foregroundStyle(.secondary)
                Text("No voice profiles yet.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.callout)
            .onAppear { speakerStore.ensureLoaded() }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(profiles) { profile in
                    // Whole row is a button into the detail sheet
                    // (emails / notes / appears-in). Forget stays a
                    // distinct trailing button so a mis-tap can't
                    // delete a profile — it's the only destructive
                    // action and it keeps its own hit target.
                    HStack(spacing: 10) {
                        Button {
                            editingSpeaker = EditingSpeaker(id: profile.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "person.fill")
                                    .foregroundStyle(Color.daisyAccent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name)
                                        .font(.callout.weight(.medium))
                                    Text(speakerProfileSummary(profile))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button("Forget") {
                            speakerStore.forget(profile.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Color.daisyTextPrimary)
                    }
                }
                HStack {
                    Spacer()
                    Button("Forget all") {
                        speakerStore.forgetAll()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.daisyError)
                }
            }
            .sheet(item: $editingSpeaker) { item in
                SpeakerDetailSheet(profileID: item.id)
            }
        }
    }

    private func speakerProfileSummary(_ profile: SpeakerProfile) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let seen = formatter.localizedString(for: profile.lastSeenAt, relativeTo: Date())
        let count = profile.sessionCount
        let meetings = String(localized: "\(count) meetings")
        return String(localized: "\(meetings) · last \(seen)")
    }

    private var whisperBadgeState: StatusBadge.State {
        switch whisper.state {
        case .ready:                 return .ok
        case .downloading, .loading: return .busy
        case .failed:                return .err
        case .notLoaded:             return .idle
        }
    }

    /// Compact per-row status — a short word/percent for the badge that
    /// sits next to the "Meeting model" label (also the download indicator).
    /// `nil` when ready or not-yet-loaded → the badge shows just its icon.
    private var whisperShortStatus: String? {
        switch whisper.state {
        case .downloading(let p): return "\(Int(p * 100))%"
        case .loading: return String(localized: "Loading")
        case .failed: return String(localized: "Failed")
        case .ready, .notLoaded: return nil
        }
    }

    /// Row label = title + a status badge (which doubles as the model-
    /// download indicator). Shared by both Transcription rows.
    @ViewBuilder
    private func transcriptionRowLabel(_ title: String, state: StatusBadge.State, message: String?) -> some View {
        HStack(spacing: 8) {
            Text(title)
            StatusBadge(state: state, message: message)
        }
    }

    private var isWhisperLoading: Bool {
        switch whisper.state {
        case .loading, .downloading: return true
        default: return false
        }
    }

    // MARK: - Dictation engine (Parakeet)

    private var parakeetBadgeState: StatusBadge.State {
        switch parakeet.state {
        case .ready:                 return .ok
        case .downloading, .loading: return .busy
        case .failed:                return .err
        case .notLoaded:             return .idle
        }
    }

    private var parakeetShortStatus: String? {
        switch parakeet.state {
        case .downloading(let p): return "\(Int(p * 100))%"
        case .loading: return "Loading"
        case .failed: return "Failed"
        case .ready, .notLoaded: return nil
        }
    }

    /// The dictation row's badge follows whichever engine is selected:
    /// Whisper → the Whisper model's state; Parakeet → Parakeet's; Apple
    /// → always ok (ships with the OS, nothing to load in-app).
    private var dictationBadgeState: StatusBadge.State {
        switch settings.dictationEngine {
        case .parakeet:    return parakeetBadgeState
        case .whisper:     return whisperBadgeState
        case .appleSpeech: return .ok
        }
    }

    private var dictationShortStatus: String? {
        switch settings.dictationEngine {
        case .parakeet:    return parakeetShortStatus
        case .whisper:     return whisperShortStatus
        case .appleSpeech: return nil
        }
    }

    /// Streaming dictation preview (Nemotron). Badge mirrors the engine's
    /// load state; the download percentage doubles as the progress UI.
    // MARK: - Notification level (derived preset over 4 stored settings)

    /// Preset the Notifications picker exposes. NOT persisted itself —
    /// derived from (and written into) the four underlying settings so
    /// consumers and old installs need no migration. `.custom` appears
    /// only when an older build's per-toggle mix doesn't match a preset.
    enum NotificationLevel: Hashable {
        case all, important, off, custom
    }

    private var notificationLevelBinding: Binding<NotificationLevel> {
        Binding(
            get: {
                let s = settings
                switch (s.recordingSoundsEnabled, s.notifyOnAutoStart, s.notifyOnAutoStop, s.silencePromptsEnabled) {
                case (true, true, true, true):     return .all
                case (false, true, true, false):   return .important
                case (false, false, false, false): return .off
                default:                           return .custom
                }
            },
            set: { level in
                switch level {
                case .all:
                    settings.recordingSoundsEnabled = true
                    settings.notifyOnAutoStart = true
                    settings.notifyOnAutoStop = true
                    settings.silencePromptsEnabled = true
                case .important:
                    // Auto-start/stop banners carry actions and confirm
                    // state changes the user didn't trigger by hand —
                    // that's the "important" half. Sound cues and the
                    // long-silence nag are the ambient half.
                    settings.recordingSoundsEnabled = false
                    settings.notifyOnAutoStart = true
                    settings.notifyOnAutoStop = true
                    settings.silencePromptsEnabled = false
                case .off:
                    settings.recordingSoundsEnabled = false
                    settings.notifyOnAutoStart = false
                    settings.notifyOnAutoStop = false
                    settings.silencePromptsEnabled = false
                case .custom:
                    break   // display-only state, never written
                }
            }
        )
    }

    private var notificationLevelCaption: String {
        switch notificationLevelBinding.wrappedValue {
        case .all:
            return String(localized: "Sounds, the start-of-recording prompts, and the long-silence check.")
        case .important:
            return String(localized: "Only the start-of-recording prompts — no sounds, no long-silence check.")
        case .off:
            return String(localized: "No sounds or prompts. The end-of-meeting ask keeps its own setting above.")
        case .custom:
            return String(localized: "A custom per-notification mix from an earlier version. Picking a preset replaces it.")
        }
    }

    private var nemotronBadgeState: StatusBadge.State {
        switch nemotron.state {
        case .ready:                 return .ok
        case .downloading, .loading: return .busy
        case .failed:                return .err
        case .notLoaded:             return .idle
        }
    }

    private var nemotronShortStatus: String? {
        switch nemotron.state {
        case .downloading(let p): return "\(Int(p * 100))%"
        case .loading: return "Loading"
        case .failed: return "Failed"
        case .ready, .notLoaded: return nil
        }
    }

    // MARK: - Summary Provider

    private var summaryTab: some View {
        Form {
            // ONE-block summary section: Provider → credentials →
            // Model → Status → Test. Eliminates the stack of 4–5
            // small sections with redundant headers ("Summary
            // provider", "Anthropic API key", "Model", "Provider
            // status") that fragmented what is conceptually a
            // single setup flow. Caption rolls into one footer
            // explaining where transcripts go for the selected
            // provider.
            Section {
                Picker("Provider", selection: $summarizer.providerKind) {
                    ForEach(availableSummaryProviders, id: \.self) { kind in
                        // Model-aware for Ollama: a `:cloud` model is not
                        // local, so the row reads "Ollama (cloud model)".
                        Text(kind.displayName(ollamaModel: kind == .ollama ? summarizer.ollamaModel : nil)).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .onAppear {
                    // If a user upgraded TO macOS 26 with an old
                    // setting OR is downgrading from 26 with
                    // .appleIntelligence stuck in UserDefaults,
                    // bounce them onto a valid provider so the
                    // picker doesn't render an unreachable selection.
                    if !availableSummaryProviders.contains(summarizer.providerKind),
                       let firstAvailable = availableSummaryProviders.first {
                        summarizer.providerKind = firstAvailable
                    }
                }

                providerInlineRows

                // Test row — final action in the block. Apple
                // Intelligence has nothing to validate remotely so
                // we skip it for that provider.
                if summarizer.providerKind != .appleIntelligence {
                    HStack {
                        Button("Test summary") {
                            Task { await testSummaryProvider() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.daisyAccent)
                        .disabled(testSummaryButtonDisabled)
                        Spacer()
                        summaryTestStatusView
                    }
                }
            } header: {
                // Status (and its Refresh) ride at the header level, right-
                // aligned — same idea as the Transcription badges.
                HStack(spacing: 8) {
                    Text("Summary provider")
                    Spacer()
                    StatusBadge(state: summarizerBadgeState, message: summarizerStatusText)
                    Button("Refresh") {
                        Task {
                            if summarizer.providerKind == .openai,
                               summarizer.openAIConnectionMethod == .account {
                                await openAIAccount.refreshStatus()
                                adoptDefaultOpenAIAccountModelIfNeeded()
                            }
                            await summarizer.refreshAvailability()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.daisyTextPrimary)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summarySectionFooter)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    // When the provider can't run, surface the specific,
                    // actionable reason here (warning tint) instead of
                    // leaving the user with only the "Unavailable" badge.
                    if case .unavailable(let reason) = summarizer.availability {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(Color.daisyWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // MCP-only extras stay separate — preset menu + raw
            // JSON template are an engineering escape hatch most
            // users never open.
            if summarizer.providerKind == .mcp {
                mcpPresetSection
                mcpAdvancedJSONSection
            }

            // Preview MD-document after a successful Test summary.
            summaryTestPreviewSection

            Section {
                // With Apple Intelligence the list shrinks to languages the
                // on-device model can actually WRITE (asking for e.g.
                // Russian silently yields English). The stored choice stays
                // listed even if unsupported — so the picker never shows a
                // blank value — with an explicit warning underneath.
                let aiProvider = summarizer.providerKind == .appleIntelligence
                Picker("Summary language", selection: $settings.summaryLanguage) {
                    ForEach(SummaryLanguage.allCases.filter {
                        !aiProvider
                            || $0.supportedByAppleIntelligence
                            || $0.id == settings.summaryLanguage
                    }) { lang in
                        Text(lang.displayName).tag(lang.id)
                    }
                }
                .pickerStyle(.menu)
                if aiProvider,
                   let lang = SummaryLanguage(rawValue: settings.summaryLanguage),
                   !lang.supportedByAppleIntelligence {
                    Text("Apple Intelligence can't write summaries in \(lang.displayName) — they'll come out in English. Pick a supported language or switch to a cloud provider.")
                        .font(.caption)
                        .foregroundStyle(Color.daisyWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("Summarize", selection: $settings.summaryTiming) {
                    ForEach(SummaryTiming.allCases) { timing in
                        Text(timing.displayName).tag(timing)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!summarizerAvailable)
                if settings.summaryTiming == .endOfDay {
                    // Not the bare "At" the morning-brief row uses: that
                    // key is still untranslated in the catalog, and this
                    // row reads better with a verb anyway.
                    Picker("Run at", selection: $settings.endOfDaySummaryHour) {
                        ForEach(Array(16...23), id: \.self) { hour in
                            Text(verbatim: String(format: "%02d:00", hour)).tag(hour)
                        }
                    }
                    .pickerStyle(.menu)
                    if case .running(let current, let total) = endOfDay.state {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Summarizing \(current) of \(total)…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    // Names the week explicitly: on any normal evening
                    // this is just today's meetings, but the FIRST pass
                    // after switching over from "Only when I ask" reaches
                    // back through everything that never got one — which
                    // is the one time a user needs warning.
                    Text("Daisy summarizes the day's meetings in one pass, plus anything from the last week that still has no summary. It waits if you're recording, and picks up whatever it missed next time — including meetings recorded after the hour, and evenings when the Mac was asleep or Daisy was closed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !summarizerAvailable {
                    Text("Provider isn’t ready yet — set it up above first.")
                        .font(.caption)
                        .foregroundStyle(Color.daisyWarning)
                }

                Toggle(isOn: $settings.protectSensitiveDataBeforeCloudAI) {
                    Text("Protect sensitive data before cloud AI")
                    Text("When enabled, Daisy locally replaces detected people, companies, contacts, and links before a remote request, then restores them in the result. Passwords, API keys, and payment-card numbers stay redacted. Local providers are unchanged. This reduces disclosure risk but cannot guarantee anonymity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Transcript-quality pass, listed before the summary
                // knobs because it runs before them and everything below
                // reads its output. The caption states the privacy gate
                // outright — "one extra request" is the cost users will
                // ask about, and "only when it was going there anyway"
                // is the answer to the question the word "cloud" raises.
                Toggle(isOn: $settings.transcriptSecondPass) {
                    Text("Second pass over the transcript")
                    Text("After a meeting, Daisy re-reads the transcript and fixes names, brands, and terms that transcription got wrong — using the calendar invite and your vocabulary. Wording is never changed, and the original is kept alongside it. Daisy also proposes who each speaker is, for you to confirm. Costs a couple of extra requests per meeting, and sends the invite’s attendee names along with the transcript; on a cloud provider it runs only when that meeting is being summarized there anyway.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // The follow-up is the one part of a summary that leaves
                // the building with the user's name on it, so it is the
                // one part worth spending a second pass on. Needs a Voice
                // Profile to have anything to imitate — shown either way,
                // with the reason, rather than hidden (a toggle that
                // appears out of nowhere later is worse than one that
                // explains itself now).
                Toggle(isOn: $settings.followUpsInMyVoice) {
                    Text("Write follow-ups in my voice")
                    Text(voiceProfileExists
                         ? "Rewrites just the follow-up draft using your Voice Profile, after the summary is written. One extra request per meeting that has one."
                         : "Needs a Voice Profile first — open Voice in the sidebar. Rewrites just the follow-up draft, at the cost of one extra request per meeting that has one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: $settings.morningBriefEnabled) {
                    Text("Morning brief")
                    Text("A card on Home each day: your meetings, open action items from recent sessions, and what to focus on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .onChange(of: settings.morningBriefEnabled) { _, _ in
                    MorningBriefStore.rescheduleNotification(settings: settings)
                }
                if settings.morningBriefEnabled {
                    Toggle(isOn: $settings.morningBriefNotifyEnabled) {
                        Text("Daily notification")
                    }
                    .onChange(of: settings.morningBriefNotifyEnabled) { _, _ in
                        MorningBriefStore.rescheduleNotification(settings: settings)
                    }
                    if settings.morningBriefNotifyEnabled {
                        Picker("At", selection: $settings.morningBriefNotifyMinutes) {
                            ForEach([7 * 60, 8 * 60, 9 * 60, 10 * 60], id: \.self) { minutes in
                                Text(String(format: "%02d:%02d", minutes / 60, minutes % 60)).tag(minutes)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: settings.morningBriefNotifyMinutes) { _, _ in
                            MorningBriefStore.rescheduleNotification(settings: settings)
                        }
                    }
                }

                Toggle(isOn: $settings.preMeetingBriefEnabled) {
                    Text("Pre-meeting brief")
                }
                Text("Before a calendar meeting, Home shows a short brief built from your past recordings with the same people. Runs on your chosen summary provider — fully local when that provider is local.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $settings.preMeetingBriefResearchOnline) {
                    Text("Research attendees online")
                }
                .disabled(!settings.preMeetingBriefEnabled || settings.anthropicAPIKey.isEmpty)
                if settings.anthropicAPIKey.isEmpty {
                    Text("Needs an Anthropic API key — the brief uses Claude’s web search. Without a key the brief stays fully local.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Adds a short web-search pass about the attendees and their company. Leaves your Mac only when this is on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Summary output")
            }
        }
        .formStyle(.grouped)
    }

    /// Inline credential / model rows for the selected provider.
    /// Lives inside the unified Summary section so picker → keys →
    /// model render as one visual block. Apple Intelligence has no
    /// inline rows (nothing to configure).
    @ViewBuilder
    private var providerInlineRows: some View {
        switch summarizer.providerKind {
        case .appleIntelligence:
            EmptyView()

        case .anthropic:
            LabeledContent("API key") {
                SecureField("", text: $settings.anthropicAPIKey, prompt: Text("sk-ant-…"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }
            Picker("Model", selection: $summarizer.anthropicModel) {
                ForEach(AnthropicAPISummarizer.availableModels, id: \.id) { item in
                    Text(item.label).tag(item.id)
                }
                // A selection with no matching tag draws an EMPTY menu
                // button — which is what someone parked on a model we
                // have since dropped from the list would see. Keep the
                // id visible instead.
                if !AnthropicAPISummarizer.availableModels.contains(where: { $0.id == summarizer.anthropicModel }) {
                    Text(String(localized: "Custom: \(summarizer.anthropicModel)")).tag(summarizer.anthropicModel)
                }
            }
            .pickerStyle(.menu)

        case .kimi:
            LabeledContent("API key") {
                SecureField("", text: $settings.kimiAPIKey, prompt: Text("sk-…"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }
            Picker("Model", selection: $summarizer.kimiModel) {
                ForEach(KimiAPISummarizer.availableModels, id: \.id) { item in
                    Text(item.label).tag(item.id)
                }
                if !KimiAPISummarizer.availableModels.contains(where: { $0.id == summarizer.kimiModel }) {
                    Text(String(localized: "Custom: \(summarizer.kimiModel)")).tag(summarizer.kimiModel)
                }
            }
            .pickerStyle(.menu)

        case .openai:
            SummaryConnectionMethodPicker(
                method: openAIConnectionMethodBinding,
                accountTitle: String(localized: "ChatGPT account")
            )

            if summarizer.openAIConnectionMethod == .apiKey {
                // Existing API block: intentionally unchanged. Account
                // mode owns separate state and a separate model choice.
                LabeledContent("API key") {
                    SecureField("", text: $settings.openaiAPIKey, prompt: Text("sk-proj-…"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                }
                Picker("Model", selection: $summarizer.openaiModel) {
                    ForEach(OpenAIAPISummarizer.availableModels, id: \.id) { item in
                        Text(item.label).tag(item.id)
                    }
                    if !OpenAIAPISummarizer.availableModels.contains(where: { $0.id == summarizer.openaiModel }) {
                        Text(String(localized: "Custom: \(summarizer.openaiModel)")).tag(summarizer.openaiModel)
                    }
                }
                .pickerStyle(.menu)
            } else {
                SummaryAccountConnectionRows(
                    accountLabel: String(localized: "ChatGPT account"),
                    providerName: String(localized: "ChatGPT"),
                    state: openAIAccount.accountState,
                    availableModels: openAIAccount.availableModels,
                    selectedModel: $summarizer.openAIAccountModel,
                    installMessage: String(localized: "ChatGPT or Codex isn't installed"),
                    installButtonTitle: String(localized: "Get ChatGPT"),
                    installURL: URL(string: "https://openai.com/chatgpt/desktop/"),
                    currentAccount: openAIAccount.account,
                    planUsagePercent: openAIAccount.rateLimit?.usedPercent,
                    usage: subscriptionUsage.recentUsage(provider: .openai),
                    connect: {
                        await openAIAccount.connect()
                        adoptDefaultOpenAIAccountModelIfNeeded()
                        await summarizer.refreshAvailability()
                    },
                    disconnect: {
                        await openAIAccount.disconnect()
                        await summarizer.refreshAvailability()
                    },
                    refresh: {
                        await openAIAccount.refreshStatus()
                        adoptDefaultOpenAIAccountModelIfNeeded()
                        await summarizer.refreshAvailability()
                    }
                )
                    .task(id: "\(summarizer.openAIConnectionMethod.rawValue)|\(summarizer.agentCLIPath)") {
                        await openAIAccount.refreshStatus()
                        adoptDefaultOpenAIAccountModelIfNeeded()
                        await summarizer.refreshAvailability()
                    }
            }

        case .cursor:
            LabeledContent("API key") {
                SecureField("", text: $settings.cursorAPIKey, prompt: Text("key_…"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }

            LabeledContent("Model") {
                TextField("", text: $summarizer.cursorModel, prompt: Text(CursorAgentService.defaultModelID))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
            }

            if let found = CursorAgentService.resolveExecutable(override: summarizer.cursorAgentPath) {
                Label("Cursor Agent found at \(found.path)", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.daisySuccess)
            } else {
                Label {
                    HStack(spacing: 8) {
                        Text("Cursor Agent CLI isn't installed. The Cursor editor command is not a substitute.")
                        Button("Install guide") {
                            if let url = URL(string: "https://cursor.com/docs/cli/installation") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.daisyWarning)
                }
                .font(.caption)
            }

            LabeledContent("Path (optional)") {
                TextField("", text: $summarizer.cursorAgentPath, prompt: Text("/Users/you/.local/bin/cursor-agent"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
            }

        case .ollama:
            LabeledContent("Server URL") {
                TextField("", text: $summarizer.ollamaBaseURL, prompt: Text(OllamaAPISummarizer.defaultBaseURLString))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
            }
            Picker("Model", selection: $summarizer.ollamaModel) {
                ForEach(ollamaModelChoices, id: \.id) { item in
                    Text(item.label).tag(item.id)
                }
                // Free-form fallback — the current value may not be in
                // the live list yet (just typed, or the server is down
                // and we're on the static catalog).
                if !ollamaModelChoices.contains(where: { $0.id == summarizer.ollamaModel }) {
                    Text(String(localized: "Custom: \(summarizer.ollamaModel)")).tag(summarizer.ollamaModel)
                }
            }
            .pickerStyle(.menu)
            // Pull the real installed-model list from /api/tags on first
            // appearance and whenever the server URL changes. An empty
            // result (server unreachable) leaves ollamaModelChoices on
            // the static catalog.
            .task(id: summarizer.ollamaBaseURL) {
                ollamaInstalledModels = await OllamaAPISummarizer.fetchInstalledModels(
                    baseURL: URL(string: summarizer.ollamaBaseURL)
                        ?? URL(string: OllamaAPISummarizer.defaultBaseURLString)!
                )
            }
            LabeledContent("Model tag") {
                TextField("", text: $summarizer.ollamaModel, prompt: Text(OllamaAPISummarizer.defaultModelID))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
            }

        case .lmStudio:
            LabeledContent("Server URL") {
                TextField("", text: $summarizer.lmStudioBaseURL, prompt: Text(LMStudioAPISummarizer.defaultBaseURLString))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
            }
            Picker("Model", selection: $summarizer.lmStudioModel) {
                ForEach(lmStudioModelChoices, id: \.id) { item in
                    Text(item.label).tag(item.id)
                }
                if !lmStudioModelChoices.contains(where: { $0.id == summarizer.lmStudioModel }) {
                    Text("Custom: \(summarizer.lmStudioModel)").tag(summarizer.lmStudioModel)
                }
            }
            .pickerStyle(.menu)
            // Read the running server's loaded models on first
            // appearance and whenever the URL changes. LM Studio ids
            // change format between versions and depend entirely on what
            // the user downloaded, so a hardcoded list is the worst of
            // the three sources — it stays only as an offline fallback.
            .task(id: summarizer.lmStudioBaseURL) {
                lmStudioLoadedModels = await LMStudioAPISummarizer.fetchLoadedModels(
                    baseURL: URL(string: summarizer.lmStudioBaseURL)
                        ?? URL(string: LMStudioAPISummarizer.defaultBaseURLString)!
                )
            }
            LabeledContent("API identifier") {
                TextField("", text: $summarizer.lmStudioModel, prompt: Text(LMStudioAPISummarizer.defaultModelID))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
            }

        case .agentCLI:
            // Only worth a control when there's a choice to make. One
            // agent today (Claude Code is barred — see the footer), so
            // the picker stays out of the way until a second one is
            // permitted.
            if AgentCLIKind.allCases.count > 1 {
                Picker("Agent", selection: $summarizer.agentCLIKind) {
                    ForEach(AgentCLIKind.allCases, id: \.self) { agent in
                        Text(agent.displayName).tag(agent)
                    }
                }
                .pickerStyle(.menu)
            }
            // Found-or-not is the whole configuration story here, and a
            // GUI app's PATH excludes ~/.local/bin and Homebrew — the
            // single likeliest reason this reads as broken for someone
            // whose CLI works fine in Terminal. So say which it is.
            if let found = resolvedAgentPath {
                Label {
                    Text("Found at \(found)")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.daisySuccess)
                }
                .font(.caption)
            } else {
                Label {
                    Text("Daisy can't find this command. Install it and sign in (run it once in Terminal), or paste its full path below — `which \(summarizer.agentCLIKind.executableName)` in Terminal prints it.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.daisyWarning)
                }
                .font(.caption)
            }
            // Always present, never conditional on the status above: a
            // field that vanishes the moment the path resolves can't be
            // corrected or cleared, and would yank focus mid-typing as
            // soon as what you typed started working.
            LabeledContent("Path (optional)") {
                TextField("", text: $summarizer.agentCLIPath, prompt: Text("/Users/you/.local/bin/\(summarizer.agentCLIKind.executableName)"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
            }
            // The probe hangs off THIS row, not the picker above it: the
            // picker is conditional (one agent today) and a `.task` on a
            // view that isn't rendered never runs — the status line would
            // have said "can't find this command" forever. Resolving is
            // off the render path because the last-resort lookup spawns a
            // login shell.
            .task(id: "\(summarizer.agentCLIKind.rawValue)|\(summarizer.agentCLIPath)") {
                let probe = AgentCLISummarizer(
                    agent: summarizer.agentCLIKind,
                    executableOverride: summarizer.agentCLIPath
                )
                resolvedAgentPath = nil
                let found = await Task.detached { probe.resolvedExecutable() }.value
                // `.task(id:)` cancels this task when the agent or path
                // changes, but a detached child keeps running — without
                // this guard a slow probe could land after a newer one.
                guard !Task.isCancelled else { return }
                resolvedAgentPath = found
            }

        case .mcp:
            // `prompt:` (placeholder) + `labelsHidden()` so Form
            // doesn't promote the title to a trailing accessory and
            // draw it twice. Same fix we apply in the Notion section.
            LabeledContent("Server URL") {
                TextField("", text: $settings.mcpSummarizerURL, prompt: Text("http://127.0.0.1:11435"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
            }
            // Egress honesty: "MCP" reads as a local option, but the URL
            // can point anywhere. Say out loud when transcripts would
            // leave the Mac; auto-run features (briefs) also key off
            // this via `providerIsEffectivelyLocal`.
            if !settings.mcpSummarizerURL.isEmpty,
               !Summarizer.isLoopbackURL(URL(string: settings.mcpSummarizerURL)) {
                Label {
                    Text("This server is not on this Mac — full transcripts will be sent to it over the network. Briefs won't auto-generate with a remote endpoint.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.daisyWarning)
                }
            }
            LabeledContent("Tool name") {
                TextField("", text: $settings.mcpSummarizerToolName, prompt: Text("chat"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func adoptDefaultOpenAIAccountModelIfNeeded() {
        guard summarizer.openAIAccountModel.isEmpty,
              let model = openAIAccount.defaultModelID
        else { return }
        summarizer.openAIAccountModel = model
    }

    private var openAIConnectionMethodBinding: Binding<SummaryConnectionMethod> {
        Binding(
            get: { summarizer.openAIConnectionMethod },
            set: { requestConnectionMethod($0, for: .openAI) }
        )
    }

    private func requestConnectionMethod(
        _ method: SummaryConnectionMethod,
        for provider: SummaryConnectionProvider
    ) {
        let preferences = SummaryConnectionPreferences()
        if method == .account,
           !preferences.hasAcknowledgedCloudDisclosure(for: provider) {
            pendingAccountDisclosure = provider
            return
        }
        setConnectionMethod(method, for: provider)
    }

    private func confirmAccountDisclosure(for provider: SummaryConnectionProvider) {
        SummaryConnectionPreferences().acknowledgeCloudDisclosure(for: provider)
        setConnectionMethod(.account, for: provider)
        pendingAccountDisclosure = nil
    }

    private func setConnectionMethod(
        _ method: SummaryConnectionMethod,
        for provider: SummaryConnectionProvider
    ) {
        switch provider {
        case .openAI:
            summarizer.openAIConnectionMethod = method
        case .anthropic, .kimi, .cursor, .githubCopilot:
            break
        }
    }

    private func accountDisclosureMessage(for provider: SummaryConnectionProvider) -> String {
        switch provider {
        case .openAI:
            return String(localized: "Daisy will send complete meeting transcripts to OpenAI through your ChatGPT account. Requests use your plan's limits; Daisy does not calculate a per-request price.")
        case .anthropic, .kimi, .cursor, .githubCopilot:
            return String(localized: "Daisy will send complete meeting transcripts to the selected cloud provider.")
        }
    }

    /// SummaryProviderKind cases visible to the user on the current
    /// macOS version. Apple Intelligence is hidden on macOS 14/15
    /// because its underlying framework (FoundationModels) only
    /// exists from Tahoe onward — surfacing it on Sonoma would
    /// show a control that has no working code path behind it.
    private var availableSummaryProviders: [SummaryProviderKind] {
        if #available(macOS 26.0, *) {
            return SummaryProviderKind.allCases
        }
        return SummaryProviderKind.allCases.filter { $0 != .appleIntelligence }
    }

    /// Single Test-button enable rule across all providers — saves
    /// duplicating the same `||`-chain in each switch case.
    private var testSummaryButtonDisabled: Bool {
        if summaryTestResult == .testing { return true }
        switch summarizer.providerKind {
        case .appleIntelligence: return true
        case .anthropic: return settings.anthropicAPIKey.isEmpty
        case .openai:
            if summarizer.openAIConnectionMethod == .account {
                return !openAIAccount.isConnected || summarizer.openAIAccountModel.isEmpty
            }
            return settings.openaiAPIKey.isEmpty
        case .cursor:
            guard CursorAgentService.resolveExecutable(override: summarizer.cursorAgentPath) != nil,
                  !summarizer.cursorModel.isEmpty else { return true }
            return settings.cursorAPIKey.isEmpty
        case .kimi: return settings.kimiAPIKey.isEmpty
        case .ollama: return summarizer.ollamaBaseURL.isEmpty || summarizer.ollamaModel.isEmpty
        case .lmStudio: return summarizer.lmStudioBaseURL.isEmpty || summarizer.lmStudioModel.isEmpty
        case .mcp:
            return settings.mcpSummarizerURL.isEmpty
                || settings.mcpSummarizerToolName.isEmpty
        case .agentCLI:
            // Nothing to fill in when the CLI is where we can find it —
            // the whole point is that there's no key to paste. Reads the
            // cached probe, never re-runs it: the lookup can spawn a
            // login shell and this is called during render.
            return resolvedAgentPath == nil
        }
    }

    /// Per-provider footer copy for the unified Summary section.
    /// Rolls "where transcripts go" + "where to get keys" + "cost"
    /// into one paragraph so the user doesn't read four scattered
    /// captions.
    private var summarySectionFooter: String {
        switch summarizer.providerKind {
        case .appleIntelligence:
            return String(localized: "Runs entirely on-device. Nothing about the transcript leaves your Mac. Apple's local model doesn't support every language (e.g. Russian) — for those, switch to a cloud provider.")
        case .anthropic:
            return String(localized: "Transcripts are sent to Anthropic over HTTPS using your own API key. Create one at console.anthropic.com/settings/keys — it's stored in your macOS Keychain. Each summary costs roughly $0.01–0.05.")
        case .openai:
            if summarizer.openAIConnectionMethod == .account {
                return String(localized: "Transcripts are sent to OpenAI through the Codex App Server signed into your ChatGPT account. Requests use your plan's limits and are included in the subscription when the provider allows it; Daisy doesn't estimate a per-request cost. Summary threads are ephemeral, run in an empty temporary folder, and cannot request approvals or change files.")
            }
            return String(localized: "Transcripts are sent to OpenAI over HTTPS using your own API key. Create one at platform.openai.com/api-keys — it's stored in your macOS Keychain. Each summary costs roughly $0.01–0.05.")
        case .cursor:
            return String(localized: "Transcripts are sent to Cursor through its Agent CLI using your API key, stored in macOS Keychain and passed only through `CURSOR_API_KEY`. Every run uses an empty temporary folder, never passes `--force`, and installs deny rules for shell, file reads/writes, and MCP.")
        case .kimi:
            return String(localized: "Transcripts are sent to Moonshot over HTTPS using your own API key — and Moonshot's documentation states that requests to its international endpoint are processed in China. Create a key at platform.kimi.ai — it's stored in your macOS Keychain. Cheapest of the cloud providers here: roughly $0.005–0.02 per summary on K2.6.")
        case .ollama:
            if OllamaAPISummarizer.isCloudModel(summarizer.ollamaModel) {
                return String(localized: "“\(summarizer.ollamaModel)” is an Ollama cloud model: your local Ollama daemon proxies the request to ollama.com, so the transcript LEAVES your Mac (Ollama bills the usage). For fully on-device summaries pick a model without a `:cloud`/`-cloud` tag.")
            }
            return String(localized: "Daisy calls your local Ollama server (`ollama serve`) over its native `/api/chat` REST. No API key, no network egress — everything stays on your Mac. Pull the model first: `ollama pull \(OllamaAPISummarizer.defaultModelID)`. Free.")
        case .lmStudio:
            return String(localized: "Daisy calls your local LM Studio server over its OpenAI-compatible `/v1/chat/completions` REST. No API key, no network egress — everything stays on your Mac. Load a model in the LM Studio app and click Developer → Start. The API identifier in this picker must match the one LM Studio shows under the loaded model. Free.")
        case .mcp:
            return String(localized: "Advanced — for users running a custom MCP server (Python shim, `mcp-ollama` wrapper, etc.). Daisy connects over HTTP+SSE and calls one tool per summary. For stock Ollama or LM Studio use their dedicated providers above instead — those work without an MCP shim.")
        case .agentCLI:
            return String(localized: "Uses the Codex command you already have signed in — no API key. The transcript is sent to OpenAI by that CLI, under your own account, and counts against your ChatGPT plan's limits. Note: if your account also has API access, some setups have been reported to bill these runs as metered API usage — check your usage after the first summary. Daisy runs it with tools disabled, in an empty temporary folder. (Claude Code isn't offered: Anthropic doesn't permit third-party apps to route requests through Claude subscription credentials — use the Anthropic API key provider instead.)")
        }
    }

    /// Model picker choices for Ollama. Prefers the live `/api/tags`
    /// listing (what the user has actually pulled, including spooled
    /// `:cloud` stubs); falls back to the static catalog when the
    /// server is unreachable. Known ids reuse the catalog's friendly
    /// label; unknown ids show the raw tag, and cloud models are marked
    /// so the egress is visible before selection.
    private var ollamaModelChoices: [(id: String, label: String)] {
        guard !ollamaInstalledModels.isEmpty else {
            return OllamaAPISummarizer.availableModels
        }
        let catalog = Dictionary(
            OllamaAPISummarizer.availableModels.map { ($0.id, $0.label) },
            uniquingKeysWith: { first, _ in first }
        )
        return ollamaInstalledModels.map { name in
            if let known = catalog[name] { return (id: name, label: known) }
            let suffix = OllamaAPISummarizer.isCloudModel(name) ? String(localized: " — cloud (ollama.com)") : ""
            return (id: name, label: name + suffix)
        }
    }

    // MARK: - Meeting apps

    /// The apps whose launch starts a recording: what Daisy ships with,
    /// plus whatever the user adds.
    ///
    /// A hardcoded list is a support queue with extra steps — Roam this
    /// week (Ken, 2026-07-28), Around and Whereby the next, and every
    /// one of them a release for a two-line change. Letting the user
    /// point at the app closes the whole class, and it answers its own
    /// question: no one has to look up a bundle identifier.
    @ViewBuilder
    private var meetingAppsRow: some View {
        LabeledContent {
            Button("Add App…") { addMeetingApp() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.daisyTextPrimary)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Apps that offer to record")
                Text(meetingAppsSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // ONE list, built-ins and user additions together: from the
        // user's side "Telegram asks me to record twenty times a day"
        // and "Roam isn't detected" are the same question about the same
        // list, and a screen that can only ever grow answers half of it.
        // Built-ins can be switched off but not deleted — they're part
        // of the app, and a delete that silently comes back on the next
        // release would be the worse affordance.
        ForEach(detector.meetingApps) { app in
            HStack(spacing: 8) {
                Text(app.name)
                if !app.isBuiltIn, let bundleID = app.bundleIDs.first {
                    // Only for user additions: it's the one identifier
                    // they may need to verify (two Slack builds, an app
                    // that moved). Built-in names aren't ambiguous, and
                    // printing "us.zoom.xos" next to Zoom is noise.
                    Text(bundleID)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if !app.isBuiltIn {
                    Button {
                        detector.removeCustomApp(app)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "Remove \(app.name)"))
                }
                Toggle(isOn: Binding(
                    get: { detector.isEnabled(app) },
                    set: { detector.setEnabled($0, for: app) }
                )) {
                    // Hidden visually, kept for VoiceOver — the row's
                    // own name text is not the switch's label.
                    Text(app.name)
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(String(localized: "Offer to record when \(app.name) launches"))
            }
        }
    }

    private var meetingAppsSummary: String {
        // Distinct APPS, not bundle ids: Teams, Webex and Telegram each
        // ship two ids, and counting raw entries would advertise 11 for
        // 8 apps — overstating coverage to someone deciding whether they
        // need to add theirs. Switched-off apps aren't counted either:
        // the number has to match what actually happens.
        let active = detector.meetingApps.filter { detector.isEnabled($0) }.count
        guard active > 0 else {
            return String(localized: "No app launch offers to record right now — every app below is switched off. Daisy still records when you press Record, and calendar auto-start is unaffected.")
        }
        // "Offer", not "start": since 2026-08-21 an app launch never
        // records silently — it raises the widget-bubble ask, under
        // every policy. The copy must not promise a hot mic.
        return String(localized: "When one of \(active) known call apps launches, Daisy offers to start recording. Add your own if it isn't detected — only a NEW launch counts, so quit and reopen the app to test.")
    }

    /// Standard open panel over /Applications. The bundle id comes from
    /// the chosen app itself, which is the point: the user knows what
    /// they clicked, not what its reverse-DNS identifier is.
    private func addMeetingApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.title = String(localized: "Add a Meeting App")
        panel.message = String(localized: "Pick an app whose launch should start a recording.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            ToastCenter.shared.show(
                String(localized: "That doesn't look like an app Daisy can identify."),
                style: .error
            )
            return
        }
        // Not `FileManager.displayName(atPath:)` — that honours the
        // user's "Show all filename extensions" setting, which would
        // bake "Slack.app" into the stored name permanently.
        let name = (Bundle(url: url)?.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        // Already on the list (built-in or previously added)? Say so —
        // closing the panel with no explanation reads as a failure. But
        // if it's on the list and switched OFF, "already detected" is a
        // lie and the user is stuck in a loop, so honour what they just
        // asked for and switch it back on.
        if let existing = detector.meetingApps.first(where: { $0.bundleIDs.contains(bundleID) }) {
            if detector.isEnabled(existing) {
                ToastCenter.shared.show(
                    String(localized: "\(existing.name) is already detected — no need to add it."),
                    style: .info
                )
            } else {
                detector.setEnabled(true, for: existing)
                ToastCenter.shared.show(
                    String(localized: "\(existing.name) was switched off — turned it back on."),
                    style: .info
                )
            }
            return
        }
        detector.customApps.append(
            MeetingDetector.CustomApp(bundleID: bundleID, name: name)
        )
    }

    /// Model picker choices for LM Studio. Prefers the live
    /// `/v1/models` listing (what the server has actually loaded);
    /// falls back to the static catalog when LM Studio isn't running.
    /// Known ids reuse the catalog's friendly label.
    private var lmStudioModelChoices: [(id: String, label: String)] {
        guard !lmStudioLoadedModels.isEmpty else {
            return LMStudioAPISummarizer.availableModels
        }
        let catalog = Dictionary(
            LMStudioAPISummarizer.availableModels.map { ($0.id, $0.label) },
            uniquingKeysWith: { first, _ in first }
        )
        return lmStudioLoadedModels.map { id in
            (id: id, label: catalog[id] ?? id)
        }
    }

    /// Quick-setup preset menu — MCP only, kept as its own section
    /// because it's an escape hatch most users skip.
    private var mcpPresetSection: some View {
        Section {
            HStack(spacing: 8) {
                Text("Use template for")
                Spacer()
                Menu("Pick wrapper") {
                    Button("llama.cpp (complete tool)") {
                        applyMCPSummarizerPreset(.llamaCpp)
                    }
                    // Ollama + LM Studio presets removed in build 40:
                    // those products don't speak MCP+SSE natively, so
                    // the preset's URL/tool/template would silently
                    // fail at first summary. Stock Ollama and LM Studio
                    // each have their own dedicated provider above
                    // (Settings → Summary → Provider) that hits their
                    // real REST endpoint directly. MCP preset list now
                    // shows only wrappers that genuinely DO expose an
                    // MCP-over-SSE surface.
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Text("Fills the URL, tool name, and arguments template with sensible defaults for that wrapper. For stock Ollama or LM Studio, switch the provider above instead — those have dedicated adapters that work without an MCP shim.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Quick setup")
        }
    }

    /// Raw JSON template editor — engineering escape hatch.
    private var mcpAdvancedJSONSection: some View {
        Section {
            DisclosureGroup("Advanced — raw JSON template") {
                TextEditor(text: $settings.mcpSummarizerArgumentsTemplate)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 160)
                    .padding(6)
                    .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
                    )
                HStack {
                    Button("Reset to default") {
                        settings.mcpSummarizerArgumentsTemplate = MCPSummarizer.defaultArgumentsTemplate
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.daisyTextPrimary)
                    Spacer()
                }
                Text("JSON template for the tool's `arguments`. Three placeholders get substituted before sending: `{{system}}` (Daisy's system prompt), `{{transcript}}` (meeting title + body), `{{title}}` (meeting title alone). Edit the `model` field to match a model your wrapper has pulled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var summarizerBadgeState: StatusBadge.State {
        switch summarizer.availability {
        case .available: return .ok
        case .unavailable: return .warn
        case .unknown: return .busy
        }
    }

    private var summarizerStatusText: String {
        switch summarizer.availability {
        case .available: return String(localized: "Available")
        case .unavailable: return String(localized: "Unavailable")
        case .unknown: return String(localized: "Checking…")
        }
    }

    private var summarizerStatusBody: String {
        switch summarizer.availability {
        case .available: return String(localized: "\(summarizer.providerKind.shortName) is ready for summaries.")
        case .unavailable(let reason): return reason
        case .unknown: return ""
        }
    }

    private var summarizerAvailable: Bool {
        if case .available = summarizer.availability { return true }
        return false
    }

    /// Whether there is a Voice Profile to imitate. Read straight from the
    /// store rather than observed: this gates one toggle's copy, and the
    /// profile is generated on another screen — a stale read here costs a
    /// reopen of Settings, not correctness.
    private var voiceProfileExists: Bool {
        VoiceProfileStore.shared.profile?.styleInstruction.isEmpty == false
    }

    private var summaryTestStatusView: some View {
        switch summaryTestResult {
        case .idle:        StatusBadge(state: .idle)
        case .testing:     StatusBadge(state: .busy)
        case .success(let msg): StatusBadge(state: .ok, message: msg)
        case .failure(let msg): StatusBadge(state: .err, message: msg)
        }
    }

    /// Inline preview that shows what the rendered summary looks
    /// like after a successful Test summary. Mirrors the typography
    /// SessionDetailView uses for real sessions — same MD-document
    /// grammar (H3 heading + hairline + body) so the test result
    /// reads as a faithful demo of "this is what you'll see after
    /// a real meeting".
    @ViewBuilder
    private var summaryTestPreviewSection: some View {
        if let preview = summaryTestPreview {
            // Headers in the user's chosen summary language — so a
            // Russian summary preview shows "Встреча / Следующие
            // шаги / Ответ клиенту" instead of English structural
            // labels stamped on top of Russian content. The picker
            // value goes through SummaryLanguage.id which matches
            // SummaryLabels.for's expected codes; "auto" → English.
            let labels = SummaryLabels.for(language: settings.summaryLanguage)
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    DisclosureGroup {
                        Text(Self.fixtureTranscript)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 6)
                    } label: {
                        Text(String(localized: "Test transcript (\(Self.fixtureTitle))"))
                            .font(.caption.weight(.medium))
                    }

                    Divider()

                    previewMDSection(title: labels.meeting) {
                        Text(preview.summary)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Granola-style topical outline — 3-5 sections,
                    // each with a flat (or shallow-nested) bullet
                    // list. Mirrors the real session detail layout
                    // so the preview faithfully demos what a session
                    // looks like after a real meeting. Pre-1.0.2 the
                    // preview only rendered Meeting + Next actions +
                    // Follow-up, so a Granola-style summary looked
                    // like a single paragraph here even when the
                    // model returned sections.
                    ForEach(Array(preview.sections.enumerated()), id: \.offset) { _, section in
                        previewMDSection(title: section.title) {
                            previewBulletTree(section.bullets, level: 0)
                        }
                    }

                    if !preview.actionItems.isEmpty {
                        previewMDSection(title: labels.nextActions) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(preview.actionItems.enumerated()), id: \.offset) { _, item in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Image(systemName: "square")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                        Text(item)
                                            .font(.callout)
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }

                    if !preview.clientFollowUp.isEmpty {
                        previewMDSection(title: labels.followUp) {
                            Text(preview.clientFollowUp)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } header: {
                Text("Preview · what a real session looks like")
            }
        }
    }

    /// Recursive bullet renderer for the Settings → Test summary
    /// preview. Mirrors `SessionDetailView.bulletTree` typography so
    /// the preview reads as a faithful demo of a real session. Uses
    /// `AnyView` rather than `some View` to break the same recursive-
    /// opaque-return-type compiler error that bit us in
    /// ContentView/SessionDetailView during the Xcode 16 / Swift 6
    /// upgrade — see [[fix-recursive-viewbuilder-bulletTree]].
    private func previewBulletTree(_ bullets: [SummaryBullet], level: Int) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(width: 8, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bullet.text)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if !bullet.children.isEmpty {
                                previewBulletTree(bullet.children, level: level + 1)
                            }
                        }
                    }
                    .padding(.leading, CGFloat(level) * 14)
                }
            }
        )
    }

    @ViewBuilder
    private func previewMDSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.daisyTextPrimary)
            Rectangle()
                .fill(Color.daisyDivider)
                .frame(height: 0.5)
            content()
        }
    }

    private func testSummaryProvider() async {
        summaryTestResult = .testing
        summaryTestPreview = nil
        // Use the isolated `runProbe` path — calling the regular
        // `summarize` would write into the shared singleton's
        // `lastSummary` / `lastError`, which the active recording
        // session reads back as if it were the real summary for
        // that meeting. Bug reproduced when the user pressed Test
        // summary mid-recording and the fixture transcript ended
        // up attached to the live session.
        //
        // Honour the user's Summary-language picker: if they chose
        // a specific language, force the probe to output in that
        // language so they see what their real summaries will look
        // like. "Auto" passes nil so the model picks based on the
        // (English) fixture content — fine for the smoke test
        // semantics ("can my provider produce a summary at all").
        // Pre-fix this hard-coded `localeHint: "en"` made the test
        // always read English even when the picker said "Русский",
        // which looked like a localization bug to QA.
        let chosenHint: String? = (settings.summaryLanguage == SummaryLanguage.auto.id)
            ? nil
            : settings.summaryLanguage
        do {
            let summary = try await summarizer.runProbe(
                transcript: Self.fixtureTranscript,
                title: Self.fixtureTitle,
                localeHint: chosenHint
            )
            summaryTestResult = .success(String(localized: "Summary came through."))
            summaryTestPreview = summary
        } catch {
            // Wrap the raw error — system messages from URLSession /
            // CoreData / decoder show up here looking like "The
            // request timed out." with no context. Prefixing keeps
            // the diagnostic info but anchors it to a recognisable
            // verb ("Test failed"), so the user knows where to
            // look without parsing system-level English.
            summaryTestResult = .failure(String(localized: "Test failed — \(error.localizedDescription)"))
        }
    }

    // MARK: - Test fixture
    //
    // Realistic two-person client call so the model has actual
    // material to summarise — a couple of concrete next actions,
    // one decision, and an obvious follow-up to send to the
    // client. Renders into a populated MeetingSummary the preview
    // can show as a "this is what a finished session looks like"
    // demo right inside Settings.

    private static let fixtureTitle = String(localized: "Brand site · homepage direction review")

    private static let fixtureTranscript = """
    [you] Thanks for jumping on. I pulled together two directions for the homepage hero based on what you mentioned last week. Want to walk through them?
    [client] Yeah, let's do it. I want to know which one we're locking in before I show the team on Friday.
    [you] OK. Direction one leans into the product photography — big image, very little copy. Direction two is more editorial: copy-first, the product appears lower down the fold.
    [client] I like the editorial one. We get more room for the value prop. But honestly, the product photo on direction one is much stronger than what we have today.
    [you] Right. What if we keep the editorial structure but commission a couple of fresh product shots for it? Say two scenes — one lifestyle, one studio.
    [client] That works for me. Can you scope what a new shoot would cost and send a number by Thursday? I'd rather not be guessing on budget when I'm in front of the team.
    [you] Will do — I'll have a quote in your inbox Thursday morning. Quick check: what about the testimonials section? You mentioned wanting to feature the new enterprise quote.
    [client] Yes, please include it. I'll send you the approved version tonight.
    [you] Perfect. So to recap: we go with the editorial direction, you send the testimonial tonight, I send a shoot budget Thursday, and we lock the homepage layout on the call next Tuesday.
    [client] Great. Let's also book 30 minutes Friday to look at the mobile breakpoints — I have a couple of concerns there I want to flag before they freeze.
    [you] Done. I'll send the invite right after this call.
    """

    // MARK: - About

    // About content lives in `AboutView.swift` — promoted out of
    // Settings tabs into a top-level sidebar section.
}

/// Shared API/account selector used by every provider that supports both
/// routes. Keeping one component prevents a provider-specific label or layout
/// from silently changing the established API-key block beneath it.
private struct SummaryConnectionMethodPicker: View {
    @Binding var method: SummaryConnectionMethod
    let accountTitle: String

    var body: some View {
        Picker("Connection", selection: $method) {
            Text("API key").tag(SummaryConnectionMethod.apiKey)
            Text(accountTitle).tag(SummaryConnectionMethod.account)
        }
        .pickerStyle(.segmented)
    }
}

/// Provider-neutral rendering of `SummaryAccountState`, model selection,
/// installation guidance, usage, and account actions. Provider managers keep
/// ownership of OAuth and process details; this view owns no credentials.
private struct SummaryAccountConnectionRows: View {
    let accountLabel: String
    let providerName: String
    let state: SummaryAccountState
    let availableModels: [SummaryAccountModel]
    @Binding var selectedModel: String
    let installMessage: String
    let installButtonTitle: String?
    let installURL: URL?
    let currentAccount: SummaryAccount?
    let planUsagePercent: Int?
    let usage: SubscriptionUsageSummary?
    let connect: @MainActor () async -> Void
    let disconnect: @MainActor () async -> Void
    let refresh: @MainActor () async -> Void

    var body: some View {
        accountStateRows

        if !availableModels.isEmpty {
            Picker("Model", selection: $selectedModel) {
                ForEach(availableModels) { model in
                    Text(model.displayName).tag(model.id)
                }
                if !selectedModel.isEmpty,
                   !availableModels.contains(where: { $0.id == selectedModel }) {
                    Text(String(localized: "Unavailable: \(selectedModel)"))
                        .tag(selectedModel)
                }
            }
            .pickerStyle(.menu)
        }

        if let used = planUsagePercent, used < 100 {
            LabeledContent("Plan usage") {
                Text(String(localized: "\(used)% used"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        LabeledContent("Billing") {
            Text("Included in subscription · uses provider limit")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let usage, usage.requestCount > 0 {
            LabeledContent("Daisy usage · 28 days") {
                Text(usageDescription(usage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var accountStateRows: some View {
        switch state {
        case .notInstalled:
            LabeledContent(accountLabel) {
                HStack(spacing: 8) {
                    Text(installMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let installButtonTitle, let installURL {
                        Button(installButtonTitle) {
                            NSWorkspace.shared.open(installURL)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

        case .signedOut:
            LabeledContent(accountLabel) {
                Button("Connect account") {
                    Task { await connect() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.daisyAccent)
            }

        case .connecting:
            LabeledContent(accountLabel) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for sign-in in your browser…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .connected(let account):
            accountIdentityRow(account)

        case .sessionExpired:
            LabeledContent(accountLabel) {
                HStack(spacing: 8) {
                    Text("Session expired")
                        .font(.caption)
                        .foregroundStyle(Color.daisyWarning)
                    Button("Connect again") {
                        Task { await connect() }
                    }
                    .buttonStyle(.bordered)
                }
            }

        case .limitReached(let resetAt):
            if let currentAccount {
                accountIdentityRow(currentAccount)
            }
            LabeledContent(String(localized: "\(providerName) limit")) {
                Text(limitDescription(resetAt))
                    .font(.caption)
                    .foregroundStyle(Color.daisyWarning)
            }

        case .failed(let message):
            LabeledContent(accountLabel) {
                HStack(spacing: 8) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Color.daisyWarning)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") {
                        Task { await refresh() }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func accountIdentityRow(_ account: SummaryAccount) -> some View {
        LabeledContent(accountLabel) {
            HStack(spacing: 10) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(account.email ?? account.displayName ?? String(localized: "Connected"))
                    if let plan = account.plan {
                        Text(plan.capitalized)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Disconnect") {
                    Task { await disconnect() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func limitDescription(_ resetAt: Date?) -> String {
        guard let resetAt else { return String(localized: "Reached") }
        return String(localized: "Reached · resets \(resetAt.formatted(date: .abbreviated, time: .shortened))")
    }

    private func usageDescription(_ usage: SubscriptionUsageSummary) -> String {
        let average = usage.averageDurationSeconds.formatted(.number.precision(.fractionLength(1)))
        if usage.failedRequests > 0 {
            return String(localized: "\(usage.requestCount) requests · \(usage.failedRequests) failed · \(average)s average")
        }
        return String(localized: "\(usage.requestCount) requests · \(average)s average")
    }
}

/// Result of a "Test connection / Test summary" probe — drives the
/// inline StatusBadge next to the Test button. Hoisted to file scope
/// (1.0.7.16) from a nested `SettingsView.TestResult` when the Notion
/// destination config moved to ConnectionsView: SettingsView's Summary
/// test (`summaryTestResult`) and ConnectionsView's Notion test
/// (`notionTestResult`) both reference it now, and a private nested
/// enum wouldn't be visible across the two files. Single definition —
/// do not duplicate.
enum TestResult: Equatable {
    case idle
    case testing
    case success(String)
    case failure(String)
}

#Preview {
    SettingsView(settings: AppSettings())
}
