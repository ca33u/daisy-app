//
//  FirstRunView.swift
//  Daisy
//
//  Multi-step welcome flow shown on first launch. Fills the whole main
//  window (no sidebar) — see MainView's first-run branch.
//
//  Layout: two columns when the window is wide enough — a step rail on
//  the left (done / current / upcoming, done steps clickable) and the
//  current step's content in a readable column on the right. Below
//  ~760pt the rail doesn't fit and we fall back to a single column with
//  progress dots on top.
//
//  Step order lives in `steps(for:installedLayoutCount:)` — a pure
//  function so the order is unit-tested. Purpose (doubles as welcome +
//  the setup-path pick), name, one permissions screen (mic /
//  accessibility / screen as rows — the set depends on the setup path,
//  and Screen Recording is deliberately last, see `permissionsStep`),
//  hotkeys, the layout-fixer step (only with 2+ installed keyboard layouts),
//  calendar, summaries, and model preparation. The final preparation
//  screen enables "Start using Daisy" once the selected models are
//  verified, and offers "Skip for now" until then — the models finish
//  in the background and the first recording waits for them. Either
//  calls `finish()` (see `isLastStep`); the one useful line that used
//  to live there (where recording actually starts) moved to Home's
//  empty state, where it's needed exactly when it's needed.
//
//  Permission state comes from SystemPermissions.shared — the same
//  tri-state façade Settings → Permissions uses — so each row can
//  honestly branch: not asked → Allow (fires the system prompt);
//  granted → checkmark; denied → Open Settings… (macOS asks once, a
//  second Allow would silently do nothing and read as a broken app;
//  when the system prompt itself is unreliable — a known macOS 14+
//  bug for Screen Recording, see ScreenRecordingPermission.swift —
//  Allow falls back to opening System Settings directly). The layout
//  step's auto-fix toggle gets the same honesty treatment from a
//  different signal, LayoutAutoFix.shared.isRunning: the setting can
//  be on while the tap never actually started.
//
//  There is no language step: macOS picks the interface language from
//  the user's preferred-languages list (plus the one-shot `be` → `ru`
//  fallback in AppSettings.applyBelarusianLanguageFallbackIfNeeded).
//  Settings → Language is where an explicit override lives.
//
//  Onboarding survives a relaunch: granting Screen Recording ends with
//  macOS offering "Quit & Reopen", which kills the process before
//  `hasShownFirstRun` flips. `Resume` snapshots step / setup path /
//  accessibility-asked / model-step-seeded to UserDefaults on every
//  change and the init restores them, so the user comes back to the
//  step they left rather than to the welcome screen. Reconciling a
//  saved step with the steps a launch actually shows is `resumeStep`,
//  pure and unit-tested alongside the step order.
//
//  Calendar offers Apple (EventKit, via SystemPermissions.calendar)
//  and Google (OAuth, via GoogleOAuthClient / GoogleAccountStore — the
//  same flow Settings → Permissions uses) side by side. Either, both,
//  or neither is fine — Daisy merges and dedupes events from whichever
//  sources are connected.
//

import SwiftUI
import AppKit
import FoundationModels

struct FirstRunView: View {
    @Bindable var settings: AppSettings

    /// Onboarding progress that has to survive the process dying
    /// mid-flow. Granting Screen Recording makes macOS offer
    /// "Quit & Reopen" — the user takes it, Daisy restarts with
    /// `hasShownFirstRun` still false, and MainView rebuilds this view
    /// from scratch. Without a resume snapshot that lands them back on
    /// step 1 having already answered everything.
    ///
    /// Written on every change rather than from some exit hook: the
    /// quit is the system's, not ours, and can land at any moment.
    /// UserDefaults directly (not AppSettings) because none of this is
    /// a user-facing setting — it's scratch state with a lifetime of
    /// exactly one onboarding, cleared by `finish()`.
    private enum Resume {
        private static let stepKey = "daisy.firstRun.resumeStep"
        private static let pathKey = "daisy.firstRun.resumePath"
        private static let axAskedKey = "daisy.firstRun.accessibilityAsked"
        private static let modelSeededKey = "daisy.firstRun.modelStepSeeded"

        static func save(
            step: Step,
            path: SetupPath,
            accessibilityAsked: Bool,
            modelStepSeeded: Bool
        ) {
            let defaults = UserDefaults.standard
            defaults.set(step.rawValue, forKey: stepKey)
            defaults.set(path.rawValue, forKey: pathKey)
            defaults.set(accessibilityAsked, forKey: axAskedKey)
            defaults.set(modelStepSeeded, forKey: modelSeededKey)
        }

        static func clear() {
            let defaults = UserDefaults.standard
            for key in [stepKey, pathKey, axAskedKey, modelSeededKey] {
                defaults.removeObject(forKey: key)
            }
        }

        static var path: SetupPath {
            SetupPath(rawValue: UserDefaults.standard.string(forKey: pathKey) ?? "")
                ?? .full
        }

        static var accessibilityAsked: Bool {
            UserDefaults.standard.bool(forKey: axAskedKey)
        }

        static var modelStepSeeded: Bool {
            UserDefaults.standard.bool(forKey: modelSeededKey)
        }

        /// Saved step resolved against the step list actually in play.
        /// The reconciling itself lives in `FirstRunView.resumeStep` so
        /// it can be unit-tested without a UserDefaults round-trip.
        static func step(in steps: [Step]) -> Step {
            FirstRunView.resumeStep(
                savedRaw: UserDefaults.standard.string(forKey: stepKey),
                in: steps
            )
        }
    }

    /// Where a resumed onboarding should land, given the raw value
    /// `Resume` stored and the steps this launch actually shows.
    ///
    /// The saved value can name a step the current path never shows (the
    /// user re-picked the track) or one that has since disappeared (the
    /// layout step, if a keyboard layout was uninstalled between
    /// launches), and an old build may have left an `Int` raw value
    /// behind. Rather than restart the whole flow — the exact thing the
    /// snapshot exists to prevent — fall back to the nearest EARLIER
    /// step that does exist, so at worst the user re-answers one screen.
    /// `Step.allCases` is declaration order, which is flow order, so
    /// "earlier" is a prefix search. Pure and non-private so
    /// FirstRunStepsTests can pin the behaviour, exactly like
    /// `steps(for:installedLayoutCount:)`.
    static func resumeStep(savedRaw: String?, in steps: [Step]) -> Step {
        guard let savedRaw, let saved = Step(rawValue: savedRaw) else { return .purpose }
        if steps.contains(saved) { return saved }
        let all = Step.allCases
        guard let savedIndex = all.firstIndex(of: saved) else { return .purpose }
        return all[..<savedIndex].last(where: steps.contains) ?? .purpose
    }

    init(settings: AppSettings) {
        _settings = Bindable(settings)
        let path = Resume.path
        let steps = Self.steps(
            for: path,
            installedLayoutCount: KeyboardLayouts.shared.installed.count
        )
        _setupPath = State(initialValue: path)
        _step = State(initialValue: Resume.step(in: steps))
        _accessibilityAsked = State(initialValue: Resume.accessibilityAsked)
        _modelStepSeeded = State(initialValue: Resume.modelStepSeeded)
    }

    /// Steps the user walks through, in order.
    ///
    /// Raw values are spelled out rather than left positional: `Resume`
    /// persists one across launches, and an update that inserts or
    /// reorders a case would otherwise silently resume an abandoned
    /// onboarding onto a DIFFERENT step — still a valid member of the
    /// list, so nothing could detect it. Names also make the stored
    /// value legible in `defaults read`.
    enum Step: String, CaseIterable {
        case purpose
        case name
        /// One screen for the whole permission set — which rows it
        /// shows depends on `SetupPath` (see `permissionsStep`).
        case permissions
        case hotkeys
        /// The wrong-layout fixer — asked only of people with 2+
        /// installed keyboard layouts (see `steps(for:installedLayoutCount:)`).
        case layout
        // Soft, optional setup steps. Each is skippable via its
        // "Continue" footer — no action is forced.
        case calendar
        case model
        case preparation

        /// Short name shown in the step rail / used by both columns.
        var railTitle: String {
            switch self {
            case .purpose:         String(localized: "Purpose")
            case .name:            String(localized: "Your name")
            case .permissions:     String(localized: "Permissions")
            case .hotkeys:         String(localized: "Hotkeys")
            case .layout:          String(localized: "Keyboard layout")
            case .calendar:        String(localized: "Calendar")
            case .model:           String(localized: "Summaries")
            case .preparation:     String(localized: "Prepare Daisy")
            }
        }
    }

    /// Which setup track the user picked on the `purpose` step. Tailors
    /// what onboarding asks — the full track sets up meetings, dictation-
    /// only skips to the dictation essentials. NOT an app mode: the app
    /// stays whole; the user can enable the rest later (lazily).
    /// Raw-valued so `Resume` can persist the pick across a relaunch.
    enum SetupPath: String { case full, dictationOnly }
    @State private var setupPath: SetupPath

    /// Steps shown, branched by `setupPath`. Full asks the recording
    /// permission set (mic + accessibility + screen — full users dictate
    /// too) and all three hotkeys; dictation-only asks mic + accessibility
    /// and just the dictation hotkey. After the permission/hotkey block
    /// come the optional "soft" steps: full gets calendar + summary
    /// model; dictation-only skips them (both are meeting-oriented).
    private var orderedSteps: [Step] {
        Self.steps(for: setupPath,
                   installedLayoutCount: KeyboardLayouts.shared.installed.count)
    }

    /// Pure step-order builder, extracted so the order is unit-testable
    /// (see FirstRunStepsTests). The layout-fixer step exists only for
    /// people with 2+ installed keyboard layouts — with one layout there
    /// is nothing to switch between and the question is noise.
    static func steps(for path: SetupPath, installedLayoutCount: Int) -> [Step] {
        let layoutFixer: [Step] = installedLayoutCount > 1 ? [.layout] : []
        switch path {
        case .full:
            return [.purpose, .name, .permissions,
                    .hotkeys] + layoutFixer + [.calendar, .model, .preparation]
        case .dictationOnly:
            return [.purpose, .permissions, .hotkeys]
                    + layoutFixer + [.preparation]
        }
    }

    @State private var preparation = ModelPreparation()
    @State private var step: Step
    /// Permission state lives in `SystemPermissions.shared` (@Observable,
    /// same façade Settings → Permissions reads), refreshed on step
    /// change + on app foreground-activation — the system can flip
    /// grants out-of-band (user toggles in System Settings while
    /// onboarding is open), and a cached value would otherwise lie.
    /// One refresh updates every row of the permissions step at once.
    private var perms: SystemPermissions { SystemPermissions.shared }
    /// Whether THIS onboarding session already fired the Accessibility
    /// prompt. macOS asks once — after that `AXIsProcessTrustedWithOptions`
    /// silently does nothing — and unlike mic there is no API that
    /// distinguishes "never asked" from "denied". Local tracking is
    /// enough here: on a fresh install nobody has been asked yet.
    /// Persisted by `Resume` for the same reason the step is: a relaunch
    /// mid-onboarding would otherwise re-offer Allow for a prompt macOS
    /// will never show a second time.
    @State private var accessibilityAsked: Bool
    /// Google account state for the calendar step — same observable
    /// store Settings → Permissions reads, so a connection made in
    /// either place shows up in both.
    @Bindable private var googleAccount = GoogleAccountStore.shared
    /// True while the OAuth loopback flow is in flight, so the row can
    /// show a spinner and Connect can't be double-tapped into two
    /// browser windows.
    @State private var googleConnecting: Bool = false
    /// Most recent OAuth error, surfaced inline on the Google row.
    @State private var googleConnectError: String?

    // ─── Soft-step state ──────────────────────────────────────────────
    /// Summary provider is @Observable but lives outside `settings`, so
    /// it needs its own @Bindable to drive the provider Picker.
    @Bindable private var summarizer = Summarizer.shared
    /// One-shot guard for seeding Apple Intelligence as the SELECTED
    /// provider on the model step. Seeded once so a user who picks a
    /// cloud provider, goes back and returns isn't overridden.
    /// Persisted by `Resume`: the provider pick writes straight through
    /// to UserDefaults, so a per-process flag would let a relaunch onto
    /// the model step re-seed over a choice the user already made.
    @State private var modelStepSeeded: Bool
    /// Re-render tick for the layout-fix card. `LayoutAutoFix.shared.isRunning`
    /// is not @Observable, so `layoutFixCaption` can't notice the tap
    /// starting on its own; bumping this after the toggle flips forces
    /// the card to re-read the real running state.
    @State private var layoutFixRecheck = 0

    /// Below this window width the rail + readable column don't both
    /// fit; fall back to a single column with progress dots on top.
    private static let twoColumnThreshold: CGFloat = 760
    private static let railWidth: CGFloat = 240
    /// Cap on the content column so a wide monitor doesn't stretch
    /// every line of copy across the whole window.
    private static let contentMaxWidth: CGFloat = 560

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= Self.twoColumnThreshold {
                twoColumnLayout
            } else {
                singleColumnLayout
            }
        }
        .background(Color.daisyBgPrimary)
        .onAppear {
            refreshPermissionStates()
        }
        .onChange(of: step) { _, _ in
            refreshPermissionStates()
            persistResume()
        }
        // These move without the step moving — the purpose step rewrites
        // the path in place, the Accessibility row fires its one-shot
        // prompt without advancing, and the model step seeds itself on
        // appear.
        .onChange(of: setupPath) { _, _ in persistResume() }
        .onChange(of: accessibilityAsked) { _, _ in persistResume() }
        .onChange(of: modelStepSeeded) { _, _ in persistResume() }
        // Permissions can flip out-of-band while onboarding is open —
        // the user opens System Settings, grants Screen Recording,
        // returns to Daisy. Without a focus observer the onboarding
        // step is frozen on "Allow Screen Recording" until they
        // click Next, which feels like the app missed the grant.
        // Refresh on every foreground-activation keeps the UI honest.
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            refreshPermissionStates()
        }
    }

    // MARK: - Column layouts

    /// Wide window: step rail on the left, the current step's content in
    /// a readable centered column on the right, Back/Next pinned to the
    /// bottom of the right column.
    private var twoColumnLayout: some View {
        HStack(spacing: 0) {
            stepRail
                .frame(width: Self.railWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.daisyBgSidebar)
            Divider()
                .overlay(Color.daisyDivider)
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
                    .frame(maxWidth: Self.contentMaxWidth)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// Narrow window (below `twoColumnThreshold`): the pre-rail layout —
    /// progress dots on top, content, footer. The user can shrink the
    /// window mid-onboarding, so this is a live fallback, not a relic.
    private var singleColumnLayout: some View {
        VStack(spacing: 0) {
            progressDots
                .padding(.top, 24)
                .padding(.bottom, 8)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
    }

    // MARK: - Step rail

    /// Left rail listing every step of the current path top to bottom.
    /// Three states — done (clickable, returns to that step), current,
    /// upcoming (inert: no jumping ahead past a permission ask).
    private var stepRail: some View {
        let steps = orderedSteps
        let current = steps.firstIndex(of: step) ?? 0
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, s in
                railRow(
                    s,
                    state: index < current ? .done
                         : index == current ? .current : .upcoming
                ) {
                    if !preparation.isRunning { step = s }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        // The window keeps `.fullSizeContentView` + a transparent
        // titlebar (DaisyAppDelegate), so the rail extends under the
        // traffic lights — leave them headroom.
        .padding(.top, 52)
        .padding(.bottom, 16)
    }

    private enum RailStepState { case done, current, upcoming }

    private func railRow(
        _ s: Step,
        state: RailStepState,
        activate: @escaping () -> Void
    ) -> some View {
        Button(action: activate) {
            HStack(spacing: 8) {
                Group {
                    switch state {
                    case .done:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.daisyAccent)
                    case .current:
                        Image(systemName: "circle.inset.filled")
                            .foregroundStyle(Color.daisyAccent)
                    case .upcoming:
                        Image(systemName: "circle")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .frame(width: 16)
                Text(s.railTitle)
                    .font(.callout.weight(state == .current ? .semibold : .regular))
                    .foregroundStyle(
                        state == .upcoming ? AnyShapeStyle(.tertiary)
                                           : AnyShapeStyle(Color.daisyTextPrimary)
                    )
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                state == .current ? AnyShapeStyle(Color.daisySidebarSelection)
                                  : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        // Only already-visited steps are navigable; the current row and
        // future rows don't react.
        .disabled(state != .done)
    }

    // MARK: - Progress dots (single-column fallback)
    //
    // Small dots that fill as the user advances. Visual anchor
    // ("am I almost done?") without taking real estate from the
    // step content. In the wide layout the rail replaces these.

    private var progressDots: some View {
        let steps = orderedSteps
        let current = steps.firstIndex(of: step) ?? 0
        return HStack(spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { idx, _ in
                Circle()
                    .fill(idx <= current ? Color.daisyAccent : Color.daisyDivider)
                    .frame(width: 6, height: 6)
            }
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var content: some View {
        Group {
            switch step {
            case .purpose: purposeStep
            case .name: nameStep
            case .permissions: permissionsStep
            case .hotkeys: hotkeysStep
            case .layout: layoutStep
            case .calendar: calendarStep
            case .model: modelStep
            case .preparation:
                ModelPreparationView(settings: settings, preparation: preparation,
                                     includeSpeakers: setupPath == .full)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
    }

    /// First screen: welcome + the setup-path choice merged into one.
    /// A short pitch (what Daisy does, one sentence) instead of the old
    /// full paragraph — the two option cards below carry the actual
    /// meaning now, so the pitch just needs to orient, not sell.
    private var purposeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What do you need Daisy for?")
                .font(.title2.weight(.semibold))
            Text("Daisy records meetings and dictates into any app — all on your Mac.")
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("We'll set up only what you need — you can enable the rest anytime.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            purposeOption(
                title: String(localized: "Meetings + dictation"),
                detail: String(localized: "Record and transcribe meetings, and dictate into any app."),
                path: .full
            )
            purposeOption(
                title: String(localized: "Just dictation"),
                detail: String(localized: "Talk, and Daisy types it into whatever app you're in."),
                path: .dictationOnly
            )
            Spacer()
        }
    }

    /// One selectable card on the purpose step — picking it sets the track
    /// and advances immediately (no separate Continue).
    private func purposeOption(title: String, detail: String, path: SetupPath) -> some View {
        Button {
            setupPath = path
            advance()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.daisyTextPrimary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color.daisyBgSidebar, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What should we call you?")
                .font(.title2.weight(.semibold))
            Text("Used to greet you and to label your voice in transcripts. Optional — leave it blank to skip.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(String(localized: "Your name"), text: $settings.userDisplayName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Spacer()
        }
    }

    /// One screen for the whole permission set. Title, one sentence
    /// about asking exactly this much, then a row per permission —
    /// icon, name, one line of "why", and a control that matches the
    /// REAL state: Allow fires the system prompt only while the system
    /// would actually show one; once denied, the row offers Open
    /// Settings… instead, because a second Allow silently does nothing
    /// and reads as a broken app. Dictation-only setups skip the
    /// Screen Recording row — nothing meeting-shaped is asked of them.
    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions")
                .font(.title2.weight(.semibold))
            Text("Daisy asks for exactly what its features need — nothing more.")
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                // Microphone is the one permission Daisy cannot work
                // without; the other two rows are optional. That
                // distinction used to live in a separate warning banner
                // — now it's just the honest "why" on each row, no
                // color or icon doing the talking instead of the words.
                permissionRow(
                    icon: "mic.fill",
                    title: String(localized: "Microphone"),
                    why: String(localized: "Needed for any recording."),
                    status: perms.microphone,
                    allow: { Task { await SystemPermissions.shared.requestMicrophone() } },
                    openSettings: { SystemPermissions.shared.openMicrophoneSettings() }
                )
                permissionRow(
                    icon: "keyboard",
                    title: String(localized: "Accessibility"),
                    why: String(localized: "Pastes dictated text into the app you're in."),
                    status: accessibilityRowStatus,
                    allow: {
                        accessibilityAsked = true
                        SystemPermissions.shared.requestAccessibility()
                    },
                    openSettings: { SystemPermissions.shared.openAccessibilitySettings() }
                )
                // Screen Recording sits LAST on purpose: it is the only
                // row whose grant macOS won't apply to a running process,
                // so it ends with the system offering "Quit & Reopen".
                // Anything below it would be asked either side of a
                // relaunch. Mic and Accessibility take effect in place,
                // so by the time this one fires the rest of the screen
                // is already answered. (`Resume` still puts the user
                // back on this step afterwards — the ordering removes
                // the interruption, it doesn't replace the safety net.)
                if setupPath == .full {
                    permissionRow(
                        icon: "rectangle.dashed.badge.record",
                        title: String(localized: "Screen Recording"),
                        why: String(localized: "Needed for system audio — the other side of a meeting."),
                        status: perms.screenRecording,
                        // Falls back to opening System Settings itself
                        // when the macOS 14+ prompt doesn't fire — see
                        // SystemPermissions.requestScreenRecording.
                        allow: { SystemPermissions.shared.requestScreenRecording() },
                        openSettings: { SystemPermissions.shared.openScreenRecordingSettings() }
                    )
                }
            }
            Spacer()
        }
    }

    /// Accessibility's row status. `AXIsProcessTrusted` is a Bool, so
    /// SystemPermissions can never report `.denied` for it — the local
    /// `accessibilityAsked` flag supplies the third state: once this
    /// onboarding has fired the one-shot prompt and the grant still isn't
    /// there, the only honest control is Open Settings….
    private var accessibilityRowStatus: SystemPermissions.Status {
        if perms.accessibility == .granted { return .granted }
        return accessibilityAsked ? .denied : .notDetermined
    }

    /// Single permission row: icon + name + one-line why on the left,
    /// the state-matched control on the right. Same card shell as
    /// `hotkeyRow` so the whole flow reads as one family.
    private func permissionRow(
        icon: String,
        title: String,
        why: String,
        status: SystemPermissions.Status,
        allow: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(status == .granted ? Color.daisySuccess : Color.daisyAccent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch status {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.daisySuccess)
            case .notDetermined:
                Button("Allow") { allow() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Color.daisyAccent)
                    .foregroundStyle(Color.daisyTextOnAccent)
            case .denied, .restricted, .insufficient:
                Button("Open Settings…") { openSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.daisyTextPrimary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.daisyBgSidebar, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
        )
    }

    private var hotkeysStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Hotkeys")
                .font(.title2.weight(.semibold))
            Text(setupPath == .full
                 ? String(localized: "Pick a global shortcut for each recording mode. You can change them later in Settings → Recording → Shortcuts.")
                 : String(localized: "Pick a global shortcut for dictation. You can change it later in Settings → Recording → Shortcuts."))
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                if setupPath == .full {
                    hotkeyRow(
                        title: String(localized: "Meeting"),
                        description: String(localized: "Captures mic + system audio together."),
                        color: .daisyRecording,
                        binding: $settings.recordHotkey
                    )
                    hotkeyRow(
                        title: String(localized: "Voice notes"),
                        description: String(localized: "Quick one-off thought, mic only."),
                        color: .daisyVoiceNote,
                        binding: $settings.voiceNoteHotkey
                    )
                }
                hotkeyRow(
                    title: String(localized: "Dictation"),
                    description: String(localized: "Hold to talk, release to paste at cursor."),
                    color: .daisyDictation,
                    binding: $settings.dictationHotkey
                )
            }
            Spacer()
        }
    }

    /// Single row in the hotkeys step — colour dot matching the
    /// widget centre for that mode + name + description + the shared
    /// `HotkeyRecorder` button (so the recording UX is identical to
    /// Settings → Hotkeys; users learn it once).
    @ViewBuilder
    private func hotkeyRow(
        title: String,
        description: String,
        color: Color,
        binding: Binding<HotkeyChoice>
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HotkeyRecorder(value: binding)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.daisyBgSidebar, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
        )
    }

    // MARK: - Soft steps

    /// The wrong-layout fixer — shown only when 2+ keyboard layouts are
    /// installed. One phrase about what it does, the as-you-type toggle
    /// and the fix key, in the same card-row shell as `hotkeyRow` so the
    /// key-recording UX is learned once. No separate "Allow Accessibility"
    /// button — the toggle fires that prompt itself via `LayoutAutoFix.start`
    /// when access is missing; `layoutFixCaption` below is what keeps the
    /// row honest if the user declines it. Flipping the toggle really
    /// starts the tap: MainView's `HotkeyStopWiring` observes
    /// `settings.layoutFixAuto` from OUTSIDE the first-run branch, so
    /// the re-wiring fires during onboarding too.
    private var layoutStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard layout")
                .font(.title2.weight(.semibold))
            Text("Daisy notices a word typed in the wrong keyboard layout and fixes it — before you send the message.")
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 12) {
                        Text("Fix the layout as I type")
                            .font(.callout.weight(.medium))
                        Spacer()
                        // The toggle itself fires the system Accessibility
                        // prompt when access is missing (LayoutAutoFix.start),
                        // so there's no separate "Allow Accessibility" button
                        // here — just the caption below telling the truth
                        // about whether it's actually running.
                        Toggle("", isOn: $settings.layoutFixAuto)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                    if let caption = layoutFixCaption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.daisyBgSidebar, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
                )
                // `isRunning` isn't observable and this render races the
                // wiring's own onChange (MainView starts/stops the tap a
                // beat after the toggle flips) — so wait for it, then tick
                // to make the caption re-read the real state.
                .id(layoutFixRecheck)
                .onChange(of: settings.layoutFixAuto) { _, _ in
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        layoutFixRecheck &+= 1
                    }
                }
                hotkeyRow(
                    title: String(localized: "Fix the keyboard layout"),
                    description: String(localized: "«ghbdtn» becomes «привет» — the selection, or the word you're typing"),
                    color: .daisyAccent,
                    binding: $settings.layoutFixHotkey
                )
            }
            Spacer()
        }
    }

    /// The toggle's stated intent (`settings.layoutFixAuto`) and what's
    /// actually running are two different things — flipping it on when
    /// Accessibility isn't granted leaves it looking enabled while the
    /// tap never started (exactly the `auto=true running=false` state a
    /// prior bug report traced a full day to). `LayoutAutoFix.shared.isRunning`
    /// is the real signal; reading `perms.accessibility` alongside it is
    /// what keeps this caption live on the same step-change / focus-
    /// activation refresh the rest of onboarding already relies on.
    private var layoutFixCaption: String? {
        guard settings.layoutFixAuto, !LayoutAutoFix.shared.isRunning else { return nil }
        // A rival switcher outranks the permission hint: with Caramba or
        // Punto running, Accessibility can be granted and this would
        // still say "not running yet" — true, useless, and the exact
        // shape of caption that cost a day of triage once already.
        if let rival = LayoutAutoFix.shared.conflictingSwitcherName {
            return String(
                format: String(localized: "Off while %@ is running — two layout fixers would garble the same word."),
                rival
            )
        }
        return perms.accessibility != .granted
            ? String(localized: "On, but Accessibility access is needed to actually run it.")
            : String(localized: "On, but not running yet.")
    }

    /// Calendar — Apple and Google are both offered, side by side, not a
    /// single either/or choice: Daisy already merges events from
    /// whichever sources are connected and dedupes them, so there's no
    /// reason to make the user pick one. Apple reuses `permissionRow` +
    /// `SystemPermissions.calendar` exactly as the earlier permissions
    /// step does; Google reuses Settings → Permissions' own OAuth flow
    /// (`GoogleOAuthClient.connect()` / `GoogleAccountStore`) restyled
    /// into this step's row shell, not a second implementation of it.
    private var calendarStep: some View {
        let appleConnected = perms.calendar == .granted
        let anyConnected = appleConnected || googleAccount.isConnected
        return VStack(alignment: .leading, spacing: 16) {
            Text("Calendar")
                .font(.title2.weight(.semibold))
            Text("Connect your calendar so Daisy can start recording automatically when a meeting begins. You can change this anytime in Settings.")
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Connect one or both — Daisy merges events from both and removes duplicates.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                permissionRow(
                    icon: "calendar",
                    title: String(localized: "Calendar (Apple)"),
                    why: String(localized: "Auto-starts recording at meeting times"),
                    status: perms.calendar,
                    allow: { Task { await SystemPermissions.shared.requestCalendar() } },
                    openSettings: { SystemPermissions.shared.openCalendarSettings() }
                )
                googleCalendarRow
            }

            if anyConnected {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Auto-record")
                        .font(.callout.weight(.medium))
                    Picker("", selection: $settings.autoStartPolicy) {
                        ForEach(AutoStartPolicy.allCases) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.daisyBgSidebar, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
                )
            }
            Spacer()
        }
    }

    /// Google Calendar row — same shell as `permissionRow` so it reads
    /// as "another calendar source," but the action is OAuth (Connect /
    /// in-flight spinner) rather than a system permission prompt.
    /// `GoogleOAuthClient.connect()` awaits its own local loopback
    /// callback before returning, so `googleAccount.isConnected` flips
    /// the moment the browser round-trip finishes — no extra focus
    /// observer needed here the way Accessibility needs one.
    @ViewBuilder
    private var googleCalendarRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: googleAccount.isConnected ? "checkmark.seal.fill" : "calendar.badge.plus")
                .font(.callout)
                .foregroundStyle(googleAccount.isConnected ? Color.daisySuccess : Color.daisyAccent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Calendar (Google)")
                    .font(.callout.weight(.medium))
                if googleAccount.isConnected, let email = googleAccount.email {
                    Text("Connected as \(email)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let err = googleConnectError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(Color.daisyError)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Read-only access to your calendar events")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if googleAccount.isConnected {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.daisySuccess)
            } else {
                Button {
                    Task { await connectGoogleCalendar() }
                } label: {
                    if googleConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Connect")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color.daisyAccent)
                .foregroundStyle(Color.daisyTextOnAccent)
                .disabled(googleConnecting)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.daisyBgSidebar, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
        )
    }

    /// Run the same PKCE-loopback OAuth flow Settings → Permissions
    /// uses, persisting the result via `GoogleAccountStore`.
    private func connectGoogleCalendar() async {
        googleConnecting = true
        googleConnectError = nil
        defer { googleConnecting = false }
        do {
            let result = try await GoogleOAuthClient.connect()
            googleAccount.save(connect: result)
        } catch GoogleOAuthClient.OAuthError.missingCode(.some("access_denied")) {
            // User cancelled on Google's consent screen — not a failure.
            return
        } catch {
            googleConnectError = error.localizedDescription
        }
    }

    /// Summaries — provider Picker + inline key. Offers only a small
    /// onboarding subset (Apple Intelligence when available + the two
    /// key-based cloud providers); local/self-hosted options are set up
    /// later in Settings.
    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Summaries")
                .font(.title2.weight(.semibold))
            Text("Choose the AI that writes your meeting summaries. You can change it or add other providers later in Settings.")
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $summarizer.providerKind) {
                    ForEach(onboardingProviders, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 280, alignment: .leading)

                switch summarizer.providerKind {
                case .anthropic:
                    SecureField(String(localized: "Anthropic API key"),
                                text: $settings.anthropicAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                case .openai:
                    SecureField(String(localized: "OpenAI API key"),
                                text: $settings.openaiAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                case .kimi:
                    SecureField(String(localized: "Kimi API key"),
                                text: $settings.kimiAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                case .appleIntelligence:
                    Text("Runs on-device — no API key needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                default:
                    EmptyView()
                }

                // Continue works without a key — say so, so an empty
                // field doesn't read as a wall. Whoever wants to look
                // around first pastes the key later.
                if summarizer.providerKind.requiresAPIKey {
                    Text("No key yet? Continue — you can add it later in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.daisyBgSidebar, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
            )
            Spacer()
        }
        // Apple Intelligence must be SELECTED when it can run, not
        // merely listed first. One-shot: coming back to this step after
        // picking a cloud provider doesn't override the choice.
        .onAppear {
            guard !modelStepSeeded else { return }
            modelStepSeeded = true
            if appleIntelligenceAvailable {
                summarizer.providerKind = .appleIntelligence
            }
        }
    }

    /// Whether Apple Intelligence's on-device model is actually usable —
    /// the same availability gate `AppleIntelligenceSummarizer.isReady()`
    /// applies, so onboarding never offers a provider that can't run.
    private var appleIntelligenceAvailable: Bool {
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return true
            default: return false
            }
        }
        return false
    }

    /// Providers offered during onboarding — a deliberately small subset.
    /// Order: Apple Intelligence (when it can run), Anthropic, OpenAI,
    /// Kimi. The current selection is always included so the menu Picker
    /// never renders a blank tag if the persisted provider is one we
    /// don't list.
    private var onboardingProviders: [SummaryProviderKind] {
        var list: [SummaryProviderKind] = []
        if appleIntelligenceAvailable { list.append(.appleIntelligence) }
        list.append(.anthropic)
        list.append(.openai)
        list.append(.kimi)
        if !list.contains(summarizer.providerKind) {
            list.append(summarizer.providerKind)
        }
        return list
    }

    // MARK: - Footer

    /// Whether `step` is the last one in the CURRENT path — varies by
    /// `setupPath` and whether the layout-fixer step is present, so this
    /// has to be computed, not hardcoded per case. The last step's
    /// primary button reads "Start using Daisy" and closes onboarding;
    /// there's no separate "You're set" screen to land on first.
    private var isLastStep: Bool {
        orderedSteps.last == step
    }

    private var footer: some View {
        HStack {
            // Back button — visible anywhere but the first step of the
            // CURRENT path, so the user can revisit a permission they
            // tapped Skip on without restarting the whole flow. Position
            // in `orderedSteps`, not `Step`'s own order: the path skips
            // cases, so a raw-value comparison would offer Back on a
            // screen with nothing behind it.
            if let index = orderedSteps.firstIndex(of: step), index > 0 {
                Button("Back") {
                    let steps = orderedSteps
                    if let i = steps.firstIndex(of: step), i > 0 {
                        step = steps[i - 1]
                    }
                }
                .buttonStyle(DaisyStepButtonStyle(filled: false))
                .disabled(preparation.isRunning)
            }
            Spacer()
            // Step-specific footer right side:
            //   • Purpose → the two option cards advance on tap, no button
            //   • Everything else → "Continue", or "Start using Daisy" on
            //     the path's last step — inline row controls (permissions,
            //     hotkeys, the layout toggle) do their own thing; nothing
            //     here is ever forced. `advance()` already calls `finish()`
            //     when there's no next step, so the action is the same
            //     either way — only the label changes.
            switch step {
            case .purpose:
                EmptyView()
            case .name, .permissions, .hotkeys, .layout, .calendar, .model, .preparation:
                // Preparation is the one step that can genuinely be
                // impossible to complete right now — no network, not
                // enough free disk — and a new user must never be
                // parked there. "Skip for now" hands them the app;
                // preparation carries on in the background and
                // `start()` waits for the model on the first recording.
                // Hidden once the models are verified: at that point
                // the primary button is the shorter path.
                if step == .preparation,
                   !preparation.canFinish(settings: settings, includeSpeakers: setupPath == .full) {
                    Button("Skip for now") {
                        finish(skippingPreparation: true)
                    }
                    .buttonStyle(DaisyStepButtonStyle(filled: false))
                    .help("Start using Daisy now. The speech models finish downloading in the background, and the first recording waits for them if they aren’t ready yet.")
                }
                Button(isLastStep ? String(localized: "Start using Daisy") : String(localized: "Continue")) {
                    advance()
                }
                .buttonStyle(DaisyStepButtonStyle(filled: true))
                .keyboardShortcut(.defaultAction)
                .disabled(step == .preparation && !preparation.canFinish(settings: settings, includeSpeakers: setupPath == .full))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    /// Onboarding's Back/Continue actions, sharing RecordCapsule's
    /// geometry (see `DaisyCapsuleMetrics`) so the "next" action carries
    /// the same visual weight as the app's other primary action. No new
    /// colors — `filled` picks between the existing accent capsule
    /// (Continue) and the same shape with no fill (Back), both already
    /// used elsewhere in the app.
    private struct DaisyStepButtonStyle: ButtonStyle {
        var filled: Bool

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(DaisyCapsuleMetrics.font)
                .padding(.horizontal, DaisyCapsuleMetrics.horizontalPadding)
                .padding(.vertical, DaisyCapsuleMetrics.verticalPadding)
                // Ink-on-accent: the system's white label fails WCAG on
                // the amber fill (≈2:1 in dark).
                .foregroundStyle(filled ? Color.daisyTextOnAccent : Color.daisyTextPrimary)
                .background(
                    Capsule(style: .continuous)
                        .fill(filled ? Color.daisyAccent : Color.clear)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            filled ? Color.white.opacity(0.12) : Color.daisyDivider,
                            lineWidth: 0.5
                        )
                )
                .opacity(configuration.isPressed ? 0.85 : 1)
        }
    }

    // MARK: - Permission refresh

    /// All request paths live in `SystemPermissions` (shared with
    /// Settings → Permissions); this is just the re-poll, wired to
    /// step changes + app foreground-activation by the observers on
    /// `body`. One call updates every permission row at once.
    private func refreshPermissionStates() {
        SystemPermissions.shared.refresh()
    }

    // MARK: - Flow

    private func advance() {
        let steps = orderedSteps
        guard let i = steps.firstIndex(of: step) else {
            // The current step vanished from the list mid-flow: the only
            // optional step is `.layout`, and `orderedSteps` recomputes
            // live from the installed keyboard layouts, so removing one
            // in System Settings while standing on that step drops it.
            // Falling through to `finish()` would end onboarding early
            // and skip everything after it — walk forward to the next
            // step that does exist instead, and only finish if there
            // genuinely isn't one.
            if let position = Step.allCases.firstIndex(of: step),
               let next = Step.allCases[(position + 1)...].first(where: steps.contains) {
                step = next
            } else {
                finish()
            }
            return
        }
        if i + 1 < steps.count {
            step = steps[i + 1]
        } else {
            finish()
        }
    }

    /// End of the flow. Setting `hasShownFirstRun` is the whole
    /// contract: MainView branches on it (the AppSettings `didSet`
    /// persists it to UserDefaults), so the window swaps back to the
    /// ordinary split shell the moment it flips.
    ///
    /// Before flipping, the window is grown to the shell's own floor
    /// (`MainWindowShellFloor`) if the user shrank it during onboarding
    /// — onboarding allows 560pt for its single-column fallback, the
    /// shell demands 860. Without this, AppKit enforces the shell's
    /// minimum in a single frame the moment the branch swaps: a 300pt
    /// snap. An animated setFrame first means the swap lands in a
    /// window that already fits. Growing leftward/downward is clamped
    /// to the visible screen so the larger frame never ends up
    /// half off-screen.
    private func finish(skippingPreparation: Bool = false) {
        // Onboarding ends on the preparation step, verified or
        // explicitly skipped. Any other way of getting here (a stale
        // Resume snapshot, a step vanishing mid-flow) lands on that
        // step instead of past it.
        guard step == .preparation else {
            step = .preparation
            return
        }
        if skippingPreparation {
            // Whatever is in flight keeps going: both ways a preparation
            // starts (the button, the `.task` resume) spawn an
            // unstructured Task that holds `preparation` alive past this
            // view. If nothing is running, start the rest in the
            // background so a user with network gets the models before
            // their first recording rather than during it.
            if !preparation.isRunning {
                ModelPreparation.completeInBackground(settings: settings, includeSpeakers: setupPath == .full)
            }
        } else {
            guard preparation.canFinish(settings: settings, includeSpeakers: setupPath == .full) else {
                return
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            var frame = window.frame
            if frame.width < MainWindowShellFloor.width
                || frame.height < MainWindowShellFloor.height {
                // NSWindow grows down-right from the top-left corner if
                // origin is kept; keep the TOP edge fixed (macOS windows
                // are y-up), extend rightward and downward.
                let newWidth = max(frame.width, MainWindowShellFloor.width)
                let newHeight = max(frame.height, MainWindowShellFloor.height)
                frame.origin.y -= (newHeight - frame.height)
                frame.size = NSSize(width: newWidth, height: newHeight)
                if let screen = window.screen?.visibleFrame {
                    frame.origin.x = max(min(frame.origin.x, screen.maxX - frame.width), screen.minX)
                    frame.origin.y = max(min(frame.origin.y, screen.maxY - frame.height), screen.minY)
                }
                window.setFrame(frame, display: true, animate: true)
            }
        }
        // Snapshot has served its purpose — a completed onboarding must
        // not leave a step behind for a future "show onboarding again"
        // to resume into.
        Resume.clear()
        UserDefaults.standard.removeObject(forKey: "daisy.preparation.started")
        settings.hasShownFirstRun = true
    }

    /// Snapshot the current position so a relaunch resumes here.
    private func persistResume() {
        Resume.save(
            step: step,
            path: setupPath,
            accessibilityAsked: accessibilityAsked,
            modelStepSeeded: modelStepSeeded
        )
    }
}

#Preview {
    FirstRunView(settings: AppSettings())
}
