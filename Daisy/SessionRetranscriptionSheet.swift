//
//  SessionRetranscriptionSheet.swift
//  Daisy
//
//  Settings for creating a transcript from retained audio. Audio-only
//  folders receive their first transcript in place; sessions that already
//  have one produce a separate derived session.
//

import SwiftUI

struct SessionRetranscriptionSheet: View {
    let session: StoredSession

    @Environment(\.dismiss) private var dismiss
    @State private var modelID = WhisperEngine.defaultModelID
    @State private var language = "auto"
    @State private var diarize = true
    @State private var didLoadDefaults = false
    @State private var errorMessage: String?
    /// The running job, so Cancel can actually cancel it. The processor
    /// already checks for cancellation between blocks and throws away its
    /// staging directory on the way out; the only thing missing was
    /// someone calling `cancel()` (a two-hour lecture behind a disabled
    /// Cancel button — Egor, 2026-09-18).
    @State private var job: Task<Void, Never>?
    /// Cancellation lands between 15-minute blocks, so up to a few minutes
    /// can pass before the job actually stops. Say so, or Stop looks dead.
    @State private var isStopping = false

    private var processor: SessionAudioProcessing { .shared }
    private var audioFiles: SessionAudioFiles {
        SessionAudioFiles.discover(in: session.directoryURL)
    }
    private var isFirstTranscript: Bool { session.transcriptURL == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    isFirstTranscript
                        ? String(localized: "Transcribe audio")
                        : String(localized: "Re-transcribe audio")
                )
                    .font(.title2.weight(.semibold))
                Text(
                    isFirstTranscript
                        ? String(localized: "Daisy will add a transcript to this folder. The retained audio stays in place.")
                        : String(localized: "Daisy will create a new session. The current transcript and folder stay unchanged.")
                )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)

            Divider()

            Form {
                Picker("Model", selection: $modelID) {
                    ForEach(WhisperEngine.availableModels, id: \.id) { model in
                        VStack(alignment: .leading) {
                            Text(model.label)
                            Text(ByteCountFormatter.string(
                                fromByteCount: Int64(model.sizeMB) * 1_000_000,
                                countStyle: .file
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .tag(model.id)
                    }
                }

                Picker("Language", selection: $language) {
                    ForEach(Transcriber.availableLocales, id: \.id) { locale in
                        Text(locale.label).tag(locale.id)
                    }
                }

                Toggle("Detect speakers", isOn: $diarize)

                LabeledContent("Saved audio") {
                    Text(audioDescription)
                        .foregroundStyle(audioFiles.hasAny ? Color.secondary : Color.red)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(minHeight: 250)

            if processor.isRunning || errorMessage != nil {
                Divider()
                HStack(spacing: 10) {
                    if processor.isRunning {
                        ProgressView()
                            .controlSize(.small)
                        Text(isStopping
                             ? String(localized: "Stopping after the current block…")
                             : processor.statusText)
                            .foregroundStyle(.secondary)
                    } else if let errorMessage {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(errorMessage)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }

            Divider()

            HStack {
                Spacer()
                // "Stop" only for OUR job: the shared processor also runs
                // the import queue, and a sheet opened over that must not
                // pretend it can stop it.
                Button(job != nil ? String(localized: "Stop") : String(localized: "Cancel")) {
                    if let job {
                        isStopping = true
                        job.cancel()
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isStopping)
                Button(
                    isFirstTranscript
                        ? String(localized: "Create transcript")
                        : String(localized: "Create new transcript")
                ) {
                    startRetranscription()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.daisyAccent)
                .keyboardShortcut(.defaultAction)
                .disabled(processor.isRunning || !audioFiles.hasAny)
            }
            .padding(20)
        }
        .frame(width: 560)
        // Still modal while running — closing the sheet must not orphan a
        // job nobody can see any more — but the Stop button above is live.
        .interactiveDismissDisabled(job != nil)
        .onAppear(perform: loadDefaults)
    }

    private var audioDescription: String {
        let microphone = audioFiles.microphone.isEmpty ? nil : String(localized: "microphone")
        let system = audioFiles.system.isEmpty ? nil : String(localized: "system audio")
        let tracks = [microphone, system].compactMap { $0 }
        return tracks.isEmpty
            ? String(localized: "No audio found")
            : tracks.joined(separator: String(localized: " and "))
    }

    private func loadDefaults() {
        guard !didLoadDefaults else { return }
        didLoadDefaults = true
        modelID = WhisperEngine.shared.modelID
        let storedLocale = session.locale.lowercased()
        language = Transcriber.availableLocales.contains(where: { $0.id == storedLocale })
            ? storedLocale
            : "auto"
    }

    private func startRetranscription() {
        errorMessage = nil
        let options = SessionRetranscriptionOptions(
            modelID: modelID,
            language: language,
            diarize: diarize
        )
        isStopping = false
        job = Task {
            defer { job = nil; isStopping = false }
            do {
                let id = try await processor.retranscribe(session, options: options)
                // A queued import job for this session is now moot.
                ImportTranscriptionQueue.shared.cancel(sessionID: session.id)
                ToastCenter.shared.show(
                    isFirstTranscript
                        ? String(localized: "Transcript created")
                        : String(localized: "New transcript created"),
                    style: .success
                )
                AppNavigation.shared.openInLibrary(id)
                dismiss()
            } catch is CancellationError {
                // The person asked for this; a stale copy of the session
                // is already gone (staging is discarded on any exit).
                errorMessage = String(localized: "Stopped — nothing was changed.")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
