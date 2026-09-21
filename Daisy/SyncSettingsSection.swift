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
            // Ф3-B: the audio side — the Mac listens on the local network.
            HStack(alignment: .firstTextBaseline) {
                Text(handoffLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("Transcripts, summaries, speakers and photos travel through your private iCloud database. Recordings never go through the cloud: the iPhone hands them to this Mac directly when both are on the same network, the Mac diarizes them, and the speaker names ride back as text.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @Bindable private var handoff = AudioHandoffServer.shared

    private var handoffLine: String {
        var parts: [String] = []
        switch handoff.state {
        case .off: parts.append(String(localized: "Recordings from the iPhone: off."))
        case .starting: parts.append(String(localized: "Recordings from the iPhone: starting…"))
        case .listening: parts.append(String(localized: "Recordings from the iPhone: this Mac (\(handoff.macName)) is listening on the local network."))
        case .failed(let message): parts.append(String(localized: "Recordings from the iPhone: failed — \(message)"))
        }
        if let at = handoff.lastTransferAt {
            parts.append(String(localized: "Last received \(at.formatted(.relative(presentation: .named))) from \(handoff.lastPhoneName ?? "the iPhone")."))
        }
        if let active = handoff.activeDiarization {
            parts.append(String(localized: "Diarizing \(active)…"))
        } else if !handoff.pendingDiarization.isEmpty {
            parts.append(String(localized: "\(handoff.pendingDiarization.count) waiting for diarization."))
        }
        return parts.joined(separator: " ")
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
