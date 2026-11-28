// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
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
        Sync sends the TEXT of your sessions to your own iCloud — the private CloudKit database of your Apple ID, end-to-end encrypted when Advanced Data Protection is on. Nobody else, not Daisy's makers, can read it

        What leaves the Mac: each session's transcript and its version before the second pass, summary, markers, speakers with their voice fingerprints and suggested names, meeting preparation, plan review and screenshots, with its title, date and project. Your project list with each project's notes and tracker settings, and your dictation vocabulary. The keys and tokens saved in Daisy go to iCloud Keychain, if it is on for this Mac, so Daisy for iPhone finds them

        What never leaves this way: recordings. Audio moves only directly between your iPhone and this Mac on the local network, only when asked, never through the cloud. With sync on, this Mac listens on the local network for it

        Turning sync off later stops sending, but does not delete what is already in iCloud. With sync off, "Delete my data from iCloud" removes the sessions, the vocabulary and the keys. The project list stays: Daisy for iPhone keeps it nowhere else
        """)

    var body: some View {
        Section {
            Toggle("Sync with the iPhone through iCloud", isOn: Binding(
                get: { sync.isEnabled },
                set: { wanted in
                    if wanted { showExplanation = true } else { sync.isEnabled = false }
                }
            ))
            // A copy not signed for Daisy's iCloud container (a build of the
            // public repo) can't sync; say so instead of a privacy sheet
            // that ends in a failure.
            .disabled(!SyncCoordinator.cloudKitAvailable)
            .settingsRow(.iCloudSync)
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
            if !SyncCoordinator.cloudKitAvailable {
                Text(SyncCoordinator.unavailableMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    .disabled(erasing || !SyncCoordinator.cloudKitAvailable)
                    .confirmationDialog(sync.isEnabled ? Text("Delete every session Daisy synced to your iCloud?") : Text("Delete your sessions, vocabulary and keys from iCloud?"),
                                        isPresented: $confirmErase, titleVisibility: .visible) {
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
                        // With sync on the keys and the vocabulary are in
                        // use in iCloud and stay; off, they go with the
                        // sessions (16.11). The project list stays either
                        // way — `ICloudSwitch.eraseWhatIsNotSessions`.
                        if sync.isEnabled {
                            Text("Every session Daisy synced is removed from your iCloud. Sessions on this Mac and on the iPhone stay where they are; with sync on, they will be sent again. Your vocabulary and keys stay in iCloud while sync is on: turn sync off first to remove them too")
                        } else {
                            Text("Removed from your iCloud: every session Daisy synced, your vocabulary, and the keys and tokens Daisy keeps in iCloud Keychain. Everything on this Mac stays, and Daisy here keeps working. The project list stays in iCloud: Daisy for iPhone keeps it nowhere else. Daisy for iPhone loses the keys until you turn sync on again on a Mac that has them. Daisy on another Mac loses them too if it has sync on or is an older version: enter them there again. A device with sync still on sends its sessions and vocabulary again")
                        }
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
            Text("Off by default: Daisy puts nothing of yours in iCloud until you turn it on. With sync on, transcripts, summaries, speakers and photos travel through your private iCloud database; your project list, vocabulary and saved keys go to iCloud too. Recordings never go through the cloud: the iPhone hands them to this Mac directly when both are on the same network, the Mac diarizes them, and the speaker names ride back as text")
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
