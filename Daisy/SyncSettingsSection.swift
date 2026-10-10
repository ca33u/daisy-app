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
    @State private var showExplanation = false
    @State private var confirmErase = false
    @State private var eraseResult: String?
    @State private var erasing = false

    /// J-0: what leaves the Mac, what never does, where it goes, and
    /// that switching off deletes nothing — in front of the person
    /// BEFORE the switch flips. The toggle itself never turns sync on;
    /// only "Turn on" in the sheet does.
    static let explanation = String(localized: """
        Sync sends the TEXT of your sessions to your own iCloud — the private CloudKit database of your Apple ID, end-to-end encrypted when Advanced Data Protection is on. Nobody else, not Daisy's makers, can read it.

        What leaves the Mac: transcript.md, summary.json, session metadata (title, date, folder, speaker names) and the screenshots of a session.

        What never leaves this way: recordings. Audio moves only directly between your iPhone and this Mac on the local network, only when asked, never through the cloud.

        Turning sync off later stops sending, but does not delete what is already in iCloud — use "Delete my data from iCloud" for that.
        """)

    var body: some View {
        Section {
            Toggle("Sync with the iPhone through iCloud", isOn: Binding(
                get: { sync.isEnabled },
                set: { wanted in
                    if wanted { showExplanation = true } else { sync.isEnabled = false }
                }
            ))
            .sheet(isPresented: $showExplanation) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Before sync goes on").font(.title3.weight(.semibold))
                    Text(Self.explanation).font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Not now") { showExplanation = false }
                            .keyboardShortcut(.cancelAction)
                        Button("Turn on") { sync.isEnabled = true; showExplanation = false }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(24)
                .frame(width: 520)
            }
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
            HStack {
                Button("Delete my data from iCloud…") { confirmErase = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.daisyTextPrimary)
                    .disabled(erasing)
                    .confirmationDialog("Delete everything Daisy put in your iCloud?", isPresented: $confirmErase, titleVisibility: .visible) {
                        Button("Delete from iCloud", role: .destructive) {
                            erasing = true
                            Task {
                                do { try await sync.eraseCloudData(); eraseResult = String(localized: "Deleted. Nothing on this Mac was touched.") }
                                catch { eraseResult = error.localizedDescription }
                                erasing = false
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Every session Daisy synced is removed from your iCloud. Sessions on this Mac and on the iPhone stay where they are; with sync on, they will be sent again.")
                    }
                if let eraseResult {
                    Text(eraseResult).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
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
            Text("Off by default: nothing leaves this Mac until you turn it on. With sync on, transcripts, summaries, speakers and photos travel through your private iCloud database. Recordings never go through the cloud: the iPhone hands them to this Mac directly when both are on the same network, the Mac diarizes them, and the speaker names ride back as text.")
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
            parts.append(String(localized: "Last received \(at.formatted(.relative(presentation: .named))) from \(handoff.lastPhoneName ?? String(localized: "the iPhone"))."))
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
