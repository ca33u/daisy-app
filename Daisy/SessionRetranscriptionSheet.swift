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
                        Text(processor.statusText)
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
                Button("Cancel") { dismiss() }
                    .disabled(processor.isRunning)
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
        .interactiveDismissDisabled(processor.isRunning)
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
        Task {
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
                errorMessage = String(localized: "Re-transcription was cancelled.")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
