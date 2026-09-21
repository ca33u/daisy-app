//
//  SyncSettingsSection.swift
//  Daisy
//
//  backlog 9 Ф3-A: one toggle, one status line, one button — the same
//  three things the phone shows. The status is honest: "no iCloud
//  account" is a state, not an error.
//

import SwiftUI

struct SyncSettingsSection: View {
    @Bindable private var sync = SyncCoordinator.shared

    var body: some View {
        Section {
            Toggle("Sync with the iPhone through iCloud", isOn: $sync.isEnabled)
            HStack(alignment: .firstTextBaseline) {
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sync now") {
                    Task { await sync.syncNow() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.daisyTextPrimary)
                .disabled(!sync.isEnabled || sync.status == .syncing)
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("Transcripts, summaries, speakers and photos travel through your private iCloud database; recordings stay on the device that made them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusLine: String {
        switch sync.status {
        case .off: return String(localized: "Off")
        case .syncing: return String(localized: "Syncing…")
        case .noAccount: return String(localized: "No iCloud account on this Mac — sign in to iCloud in System Settings.")
        case .failed(let message): return String(localized: "Failed: \(message)")
        case .idle:
            if let at = sync.lastSyncAt {
                return String(localized: "Last synced \(at.formatted(.relative(presentation: .named)))")
            }
            return String(localized: "Not synced yet")
        }
    }
}
