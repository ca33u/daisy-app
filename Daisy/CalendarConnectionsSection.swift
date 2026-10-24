//
//  CalendarConnectionsSection.swift
//  Daisy
//
//  Where Daisy reads meetings from — Apple Calendar (EventKit) and
//  Google Calendar (OAuth), side by side: the Calendar segment of
//  Settings → Connections. They sat under Privacy's meeting
//  permissions from build 42 (2026-05-28) until the Settings
//  restructure (S3, Egor 24.10.2026) made them connections; the
//  «Don't remind me» meeting-permission switch stayed in Privacy.
//

import SwiftUI

struct CalendarConnectionsSection: View {
    @Bindable private var permissions = SystemPermissions.shared

    /// Drives the Connect / Disconnect button labels and the
    /// connected-as email in the Google Calendar row.
    @Bindable private var googleAccount = GoogleAccountStore.shared
    /// True while the OAuth flow is in flight (Safari hands off to
    /// our loopback listener and back). Disables Connect to stop
    /// double-clicks from spawning two browser windows.
    @State private var googleConnecting = false
    /// Most-recent OAuth error message, surfaced inline below the
    /// Google Calendar row so the user can see exactly what Google
    /// returned.
    @State private var googleConnectError: String?

    var body: some View {
        Section {
            PermissionStatusRow(
                title: String(localized: "Calendar (Apple)"),
                caption: String(localized: "Auto-starts recording at meeting times"),
                iconName: "calendar",
                isRequired: false,
                status: permissions.calendar,
                requestAction: { Task { await permissions.requestCalendar() } },
                openSettings: permissions.openCalendarSettings
            )
            .settingsRow(.calendarApple)

            googleCalendarRow
                .settingsRow(.calendarGoogle)
        } header: {
            Text("Calendar")
        }
        .onAppear { permissions.refresh() }
    }

    // MARK: - Google Calendar row (OAuth, custom shape)

    /// Google Calendar row — OAuth flow instead of the EventKit
    /// Request/Settings rhythm. Mimics the visual structure of
    /// `PermissionStatusRow` (SF Symbol + title + caption on the left,
    /// action on the right) so it reads as the Apple row's sibling, but
    /// the action button toggles between Connect (PKCE-loopback OAuth)
    /// and Disconnect (revoke token), and there's a connected-as email
    /// surfaced when connected.
    @ViewBuilder
    private var googleCalendarRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: googleAccount.isConnected ? "checkmark.seal.fill" : "calendar.badge.plus")
                .font(.callout)
                .foregroundStyle(googleAccount.isConnected ? Color.daisySuccess : .secondary)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text("Calendar (Google)")
                    .font(.callout.weight(.medium))
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
}
