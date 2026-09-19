//
//  PermissionsView.swift
//  Daisy
//
//  Dashboard for the four system privacy permissions Daisy uses.
//  Lives as a tab inside Settings (`SettingsTab.permissions`) because
//  it's about local OS-level access — not external service
//  integrations. Granola / Wispr Flow / MacWhisper put their
//  permission panes in Settings too; this matches macOS convention.
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

    /// Observable Google account state — moved here from
    /// `ConnectionsView` in build 42 (2026-05-28). Drives the
    /// Connect / Disconnect button labels and the connected-as email
    /// row in the Google Calendar permission row.
    @Bindable private var googleAccount = GoogleAccountStore.shared
    /// True while the OAuth flow is in flight (Safari hands off to
    /// our loopback listener and back). Disables Connect to stop
    /// double-clicks from spawning two browser windows.
    @State private var googleConnecting: Bool = false
    /// Most-recent OAuth error message, surfaced inline below the
    /// Google Calendar row so the user can see exactly what Google
    /// returned.
    @State private var googleConnectError: String?

    /// Whether Daisy can read the Voice Memos library — drives the Full
    /// Disk Access row below, which appears only while Voice Memos import
    /// is enabled (the grant request moved here from the Voice Memos
    /// section on 2026-06-24).
    @State private var voiceMemoAccess: VoiceMemoLibrary.AccessStatus = .ok

    var body: some View {
        Form {
            permissionsSection
        }
        .formStyle(.grouped)
        .onAppear {
            permissions.refresh()
            voiceMemoAccess = VoiceMemoLibrary.accessStatus()
        }
    }

    // MARK: - Section

    @ViewBuilder
    private var permissionsSection: some View {
        // ── For dictation: the minimum to dictate ─────────────
        Section {
            permissionRow(
                title: String(localized: "Microphone"),
                caption: String(localized: "Captures your voice"),
                iconName: "mic.fill",
                isRequired: true,
                status: permissions.microphone,
                requestAction: { Task { await permissions.requestMicrophone() } },
                openSettings: permissions.openMicrophoneSettings
            )

            permissionRow(
                title: String(localized: "Accessibility"),
                caption: String(localized: "Lets dictation paste into any app"),
                iconName: "keyboard",
                isRequired: true,
                status: permissions.accessibility,
                requestAction: { permissions.requestAccessibility() },
                openSettings: permissions.openAccessibilitySettings
            )
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
            permissionRow(
                title: String(localized: "Screen Recording"),
                caption: String(localized: "Captures the other side of meetings"),
                iconName: "rectangle.on.rectangle",
                isRequired: false,
                status: permissions.screenRecording,
                requestAction: { permissions.requestScreenRecording() },
                openSettings: permissions.openScreenRecordingSettings
            )

            permissionRow(
                title: String(localized: "Calendar (Apple)"),
                caption: String(localized: "Auto-starts recording at meeting times"),
                iconName: "calendar",
                isRequired: false,
                status: permissions.calendar,
                requestAction: { Task { await permissions.requestCalendar() } },
                openSettings: permissions.openCalendarSettings
            )

            // Google Calendar — OAuth row, same "calendar source"
            // mental model as Apple Calendar, sat side-by-side.
            googleCalendarRow

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
            permissionRow(
                title: String(localized: "Notifications"),
                caption: String(localized: "Banner when Daisy auto-starts or saves"),
                iconName: "bell",
                isRequired: false,
                status: permissions.notifications,
                requestAction: { permissions.requestNotifications() },
                openSettings: permissions.openNotificationSettings
            )
        } header: {
            Text("Notifications")
        }

        // ── Full Disk Access — only for Voice Memos import ────
        // Shown only while Voice Memos import is on, so people who don't
        // use it aren't nagged for a permission they don't need. Moved
        // here from the Voice Memos section (Settings → Transcription).
        if settings.ingestVoiceMemos {
            Section {
                voiceMemosFullDiskAccessRow
            } header: {
                Text("For Voice Memos import")
            }
        }
    }

    // MARK: - Row

    // MARK: - Google Calendar row (OAuth, custom shape)

    /// Google Calendar permission row — OAuth flow instead of the
    /// EventKit Request/Settings rhythm. Mimics the visual structure
    /// of `permissionRow` (SF Symbol + title + caption on the left,
    /// action on the right) so it reads as "another permission row",
    /// but the action button toggles between Connect (PKCE-loopback
    /// OAuth) and Disconnect (revoke token), and there's a
    /// connected-as email surfaced when connected.
    @ViewBuilder
    private var googleCalendarRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: googleAccount.isConnected ? "checkmark.seal.fill" : "calendar.badge.plus")
                .font(.callout)
                .foregroundStyle(googleAccount.isConnected ? Color.daisySuccess : .secondary)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Calendar (Google)")
                        .font(.callout.weight(.medium))
                    Text("Optional")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Color.secondary.opacity(0.18))
                        )
                        .foregroundStyle(.secondary)
                }
                if googleAccount.isConnected, let email = googleAccount.email {
                    Text("Connected as \(email)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Read-only access to your calendar events")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let err = googleConnectError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(Color.daisyError)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            if googleAccount.isConnected {
                Button(role: .destructive) {
                    Task {
                        await googleAccount.disconnect()
                        googleConnectError = nil
                    }
                } label: {
                    Text("Disconnect")
                }
                .controlSize(.small)
            } else {
                Button {
                    Task { await runOAuthConnect() }
                } label: {
                    if googleConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Connect")
                    }
                }
                .controlSize(.small)
                .disabled(googleConnecting)
            }
        }
    }

    /// Run the PKCE-loopback OAuth flow + persist the result via
    /// `GoogleAccountStore`. Surfaces any thrown error inline so the
    /// user can see exactly what Google returned (was useful during
    /// the verification recording attempt; still useful for
    /// debugging "I clicked Connect and nothing happened" reports).
    private func runOAuthConnect() async {
        googleConnecting = true
        googleConnectError = nil
        defer { googleConnecting = false }
        do {
            let result = try await GoogleOAuthClient.connect()
            googleAccount.save(connect: result)
        } catch {
            googleConnectError = error.localizedDescription
        }
    }

    // MARK: - Voice Memos Full Disk Access row

    /// Full Disk Access row — custom because FDA has no request API (you
    /// can only deep-link to System Settings) and its state is inferred
    /// from whether we can read the Voice Memos library, not from
    /// `SystemPermissions`. The section header ("For Voice Memos import")
    /// carries the context; the badge just reads "Optional" like the others.
    @ViewBuilder
    private var voiceMemosFullDiskAccessRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.callout)
                .foregroundStyle(voiceMemoFDAColor)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Full Disk Access")
                        .font(.callout.weight(.medium))
                    Text("Optional")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.gray.opacity(0.15), in: Capsule())
                }
                Text(voiceMemoFDACaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if voiceMemoAccess != .noLibrary {
                Button(voiceMemoAccess == .ok ? "Open Settings…" : "Open Full Disk Access") {
                    SystemPermissions.shared.openFullDiskAccessSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(voiceMemoAccess == .ok ? .secondary : Color.daisyTextPrimary)
            }
        }
        .font(.callout)
        .padding(.vertical, 4)
    }

    private var voiceMemoFDAColor: Color {
        switch voiceMemoAccess {
        case .ok:                  return Color.daisySuccess
        case .needsFullDiskAccess: return Color.daisyWarning
        case .noLibrary, .error:   return .secondary
        }
    }

    private var voiceMemoFDACaption: String {
        switch voiceMemoAccess {
        case .ok:                  return String(localized: "Granted — Daisy can read your Voice Memos library.")
        case .needsFullDiskAccess: return String(localized: "Grant Full Disk Access, then reopen this tab.")
        case .noLibrary:           return String(localized: "No Voice Memos library found on this Mac.")
        case .error(let msg):      return msg
        }
    }

    // MARK: - Generic permission row

    /// One row in the permissions dashboard. SF Symbol + title +
    /// caption on the left, then the action button. The status itself
    /// is communicated by two existing signals — icon colour (green
    /// = granted, red/orange = needs attention, secondary = idle)
    /// and the action button's text (Request / Open Settings… /
    /// Revoke…) — so the explicit "Granted / Not requested" pill
    /// in between was redundant visual noise. Removed in 1.0.5.
    @ViewBuilder
    private func permissionRow(
        title: String,
        caption: String,
        iconName: String,
        isRequired: Bool,
        status: SystemPermissions.Status,
        requestAction: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.callout)
                .foregroundStyle(iconColor(status: status, isRequired: isRequired))
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    if !isRequired {
                        Text("Optional")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.gray.opacity(0.15), in: Capsule())
                    }
                }
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            actionButton(
                status: status,
                requestAction: requestAction,
                openSettings: openSettings
            )
        }
        .font(.callout)
        .padding(.vertical, 4)
    }

    // MARK: - Cell pieces

    private func iconColor(
        status: SystemPermissions.Status,
        isRequired: Bool
    ) -> Color {
        switch status {
        case .granted:                       return Color.daisySuccess
        case .denied, .restricted:           return isRequired ? Color.daisyError : Color.daisyWarning
        case .insufficient:                  return Color.daisyWarning
        case .notDetermined:                 return .secondary
        }
    }

    // statusBadge(...) removed in 1.0.5 — row state is communicated
    // by `iconColor(status:isRequired:)` on the leading SF Symbol +
    // the action button's text (Request / Open Settings… / Revoke…).
    // Section header still surfaces "Required permission missing"
    // when needsAttention, which is the overall warning a user
    // glancing at Settings actually needs.

    @ViewBuilder
    private func actionButton(
        status: SystemPermissions.Status,
        requestAction: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
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
            // on a row that already accents in cinnamon (icon +
            // "Optional" pill + title).
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
