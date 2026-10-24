//
//  PermissionsView.swift
//  Daisy
//
//  The Privacy tab of Settings: the macOS permissions Daisy uses, then
//  what leaves the Mac — the improvement counts and crash reports — and
//  the logs (Settings restructure S3, Egor 24.10.2026: those three came
//  from About; the calendar rows went to Connections). Granola / Wispr
//  Flow / MacWhisper put their permission panes in Settings too; this
//  matches macOS convention.
//
//  Each row encodes status as a coloured badge + caption + action
//  button (Request access for `.notDetermined`, Open System
//  Settings… for `.denied`/`.restricted`, Revoke… for `.granted`).
//  State is refreshed on app focus via `SystemPermissions.shared`,
//  so external changes in System Settings reflect immediately
//  when the user comes back to Daisy.
//

import SwiftUI

struct PermissionsView: View {
    /// Passed in from SettingsView so the "Don't remind me" toggle in the
    /// meeting-recording group can read/write the suppress flag.
    @Bindable var settings: AppSettings

    @Bindable private var permissions = SystemPermissions.shared

    /// System Audio Recording, as the last probe heard it (24.09). Not a
    /// TCC read — there is none — so it is refreshed on appear and after
    /// "Check again".
    @State private var systemAudio = ProcessTapPermission.state
    @State private var checkingSystemAudio = false
    @State private var showsTapSheet = false

    /// `CrashReports.mode` (UserDefaults), written back on change.
    @State private var crashReportsMode = CrashReports.mode
    /// "Help improve Daisy" — read from the stored mode, so a «Help» on
    /// Home shows here at once; set only by this switch (a «no» here is
    /// never asked again).
    @AppStorage(ImprovementStats.modeKey) private var improvementModeRaw = ImprovementStats.Mode.unasked.rawValue
    private var helpsImprove: Binding<Bool> {
        Binding(get: { improvementModeRaw == ImprovementStats.Mode.on.rawValue },
                set: { ImprovementStats.setFromAbout($0) })
    }

    var body: some View {
        Form {
            permissionsSection
            leavesTheMacSection
            logsSection
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.privacy, settings: settings)
        .onAppear {
            permissions.refresh()
            systemAudio = ProcessTapPermission.state
        }
    }

    // MARK: - Section

    @ViewBuilder
    private var permissionsSection: some View {
        // ── For dictation: the minimum to dictate ─────────────
        Section {
            PermissionStatusRow(
                title: String(localized: "Microphone"),
                caption: String(localized: "Captures your voice"),
                iconName: "mic.fill",
                isRequired: true,
                status: permissions.microphone,
                requestAction: { Task { await permissions.requestMicrophone() } },
                openSettings: permissions.openMicrophoneSettings
            )
                .settingsRow(.microphoneAccess)

            PermissionStatusRow(
                title: String(localized: "Accessibility"),
                caption: String(localized: "Lets dictation paste into any app"),
                iconName: "keyboard",
                isRequired: true,
                status: permissions.accessibility,
                requestAction: { permissions.requestAccessibility() },
                openSettings: permissions.openAccessibilitySettings
            )
                .settingsRow(.accessibility)
        } header: {
            // Header names the group ("enough to dictate") and carries the
            // overall permission status badge. The on-device privacy
            // explainer that used to sit here was dropped (Egor, 2026-06-13)
            // — it was a wall of text above the first prompt.
            HStack {
                Text("Enough for dictation")
                Spacer()
                if permissions.needsAttention {
                    Label("Required permission missing", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.daisyWarning)
                } else if permissions.hasAllRequiredGranted && permissions.hasAllOptionalGranted {
                    Label("All granted", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(Color.daisySuccess)
                }
            }
        }

        // ── For meeting recording: asked lazily on first use ──
        Section {
            if ProcessTapPermission.isAvailable {
                systemAudioRow
            }
            PermissionStatusRow(
                title: String(localized: "Screen Recording"),
                caption: ProcessTapPermission.isAvailable
                    ? String(localized: "Captures the other side when System Audio Recording isn’t allowed")
                    : String(localized: "Captures the other side of meetings"),
                iconName: "rectangle.on.rectangle",
                isRequired: false,
                status: permissions.screenRecording,
                requestAction: { permissions.requestScreenRecording() },
                openSettings: permissions.openScreenRecordingSettings
            )
                .settingsRow(.screenRecording)

            // The calendars are on Connections → Calendar since S3.

            // "Don't remind me" — mutes Daisy's in-app warning when a
            // recording isn't capturing the other side. The macOS
            // permission prompt still appears when you record a meeting,
            // so this only hides the nag, not the actual ask.
            Toggle(isOn: $settings.suppressMeetingPermissionReminders) {
                Text("Don't remind me")
                Text("Hide the in-app warning when the other side isn't being captured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("For meeting recording")
        }

        // ── Notifications ─────────────────────────────────────
        Section {
            PermissionStatusRow(
                title: String(localized: "Notifications"),
                caption: String(localized: "Banner when Daisy auto-starts or saves"),
                iconName: "bell",
                isRequired: false,
                status: permissions.notifications,
                requestAction: { permissions.requestNotifications() },
                openSettings: permissions.openNotificationSettings
            )
                .settingsRow(.notificationPermission)
        } header: {
            Text("Notifications")
        }
    }

    // MARK: - What leaves the Mac (from About, S3)

    @ViewBuilder
    private var leavesTheMacSection: some View {
        Section {
            // Anonymous feature counts, only with a yes (ImprovementStats).
            Toggle(isOn: helpsImprove) {
                Text("Help improve Daisy")
                Text("Once a day — anonymous counts of features and errors. No content, no identifier.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .settingsRow(.improveDaisy)
            Button("What's sent") { ImprovementStats.showPreview() }
                .buttonStyle(.link)

            // Crash reports only when the person sends one (backlog 27
            // С-2): after a crash Daisy asks, showing the whole report.
            // "Never" doesn't start the crash reporter at all; takes
            // effect on the next launch.
            Picker(selection: $crashReportsMode) {
                Text("Ask every time").tag(CrashReports.Mode.ask)
                Text("Never send").tag(CrashReports.Mode.never)
            } label: {
                Text("Crash reports")
                Text("After a crash, Daisy asks before sending anything and shows the whole report: where in the code it failed, the app and macOS versions and the Mac model. Never your meetings, names, files or devices. “Never send” applies from the next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: crashReportsMode) { _, mode in CrashReports.mode = mode }
            .settingsRow(.crashReports)
        } header: {
            Text("What leaves your Mac")
        }
    }

    // MARK: - Logs (from About's «Feedback», S3)

    /// Same tester feedback channel as Help → "Send Log Report…":
    /// collects the last 24 h of Daisy's own logs + an environment header
    /// and opens a pre-addressed Mail compose (LogReporter).
    @ViewBuilder
    private var logsSection: some View {
        Section {
            LabeledContent {
                Button {
                    LogReporter.sendReport(settings: settings)
                } label: {
                    HStack(spacing: 4) {
                        Text("Send Log Report…")
                        Image(systemName: "envelope")
                            .font(.caption)
                    }
                    .foregroundStyle(Color.daisyAccent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Report a bug: send a log report")
            } label: {
                Text("Report a bug")
            }
            .settingsRow(.logReport)
            // Second, EQUALLY visible path, and deliberately the dumb
            // one: it produces the log file and nothing else.
            // `canPerform` only proves Mail.app is installed, so the
            // button above can drop a user into a compose window they
            // can't send from (Ken, 2026-07-28 — mail lives in his
            // browser). Named for what it hands you, because the
            // previous "Save Log Report…" wording plus a clipboard
            // side effect read as "copies a form" (Egor, 2026-07-28).
            LabeledContent {
                Button {
                    LogReporter.exportLogs(settings: settings)
                } label: {
                    HStack(spacing: 4) {
                        Text("Export Logs…")
                        Image(systemName: "arrow.down.doc")
                            .font(.caption)
                    }
                    .foregroundStyle(Color.daisyAccent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Export the last 24 hours of logs to a file")
            } label: {
                Text("Just the log file")
            }
        } header: {
            Text("Logs")
        } footer: {
            Text("Both cover the last 24 hours of Daisy's logs — diagnostics only, no transcript text. Nothing is sent automatically; review it first.")
        }
    }

    // MARK: - System Audio Recording row (process tap, 24.09)

    /// How Daisy hears the other side on macOS 14.4+. Its status comes
    /// from the probe (Daisy's own inaudible tone, tapped), because macOS
    /// has no way to read this permission.
    @ViewBuilder
    private var systemAudioRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "waveform")
                .font(.callout)
                .foregroundStyle(systemAudio == .granted ? Color.daisySuccess
                                 : systemAudio == .denied ? Color.daisyWarning : .secondary)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("System Audio Recording")
                    .font(.callout.weight(.medium))
                Text(systemAudioCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            switch systemAudio {
            case .notAsked:
                Button("Allow…") { showsTapSheet = true }
                    .buttonStyle(.bordered).controlSize(.small).tint(Color.daisyTextPrimary)
            case .denied:
                HStack(spacing: 6) {
                    Button("Check again") { Task { await recheckSystemAudio() } }
                        .disabled(checkingSystemAudio)
                    Button("Open Settings…") { ProcessTapPermission.openSettings() }
                }
                .buttonStyle(.bordered).controlSize(.small)
            case .granted:
                Button("Open Settings…") { ProcessTapPermission.openSettings() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .font(.callout)
        .padding(.vertical, 4)
        .sheet(isPresented: $showsTapSheet, onDismiss: { systemAudio = ProcessTapPermission.state }) {
            TapPermissionSheet()
        }
    }

    private var systemAudioCaption: String {
        switch systemAudio {
        case .granted: String(localized: "Allowed — Daisy hears the other side through sound alone, Bluetooth headphones included.")
        case .denied: String(localized: "Not allowed — Daisy uses Screen Recording instead. Allow it in System Settings, then check again.")
        case .notAsked: String(localized: "Records the other side of meetings — sound only, without the screen.")
        }
    }

    private func recheckSystemAudio() async {
        checkingSystemAudio = true
        defer { checkingSystemAudio = false }
        let result = await ProcessTapPermission.probe(timeout: .seconds(2))
        ProcessTapPermission.record(result)
        systemAudio = ProcessTapPermission.state
    }
}

// MARK: - Permission row

/// One row in the permissions dashboard — here, and Apple Calendar on
/// Connections. SF Symbol + title + caption on the left, then the action
/// button. The status itself is communicated by two existing signals —
/// icon colour (green = granted, red/orange = needs attention, secondary
/// = idle) and the action button's text (Request / Open Settings… /
/// Revoke…) — so the explicit "Granted / Not requested" pill in between
/// was redundant visual noise. Removed in 1.0.5.
struct PermissionStatusRow: View {
    let title: String
    let caption: String
    let iconName: String
    let isRequired: Bool
    let status: SystemPermissions.Status
    let requestAction: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.callout)
                .foregroundStyle(iconColor)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            actionButton
        }
        .font(.callout)
        .padding(.vertical, 4)
    }

    private var iconColor: Color {
        switch status {
        case .granted:                       return Color.daisySuccess
        case .denied, .restricted:           return isRequired ? Color.daisyError : Color.daisyWarning
        case .insufficient:                  return Color.daisyWarning
        case .notDetermined:                 return .secondary
        }
    }

    // The section header still surfaces "Required permission missing"
    // when needsAttention, which is the overall warning a user glancing
    // at Settings actually needs.

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .notDetermined:
            Button("Request") { requestAction() }
                .buttonStyle(.daisyPrimary)
                .controlSize(.small)
        case .denied, .insufficient, .restricted:
            // .restricted = managed device, the user can't toggle but
            // surfacing the deeplink anyway in case an admin can act.
            // 2026-05-26 — explicit `.tint(Color.daisyTextPrimary)`
            // because the default `.bordered` tint on Daisy's cream
            // surface collapses into the background (washed-out
            // orange-on-cream — Egor flagged the row as unactionable-
            // looking). Inking the button gives it readable text +
            // a dark outline without piling another orange element
            // on a row that already accents in cinnamon (icon + title).
            Button("Open Settings…") { openSettings() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.daisyTextPrimary)
        case .granted:
            Button("Revoke…") { openSettings() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.secondary)
        }
    }
}
