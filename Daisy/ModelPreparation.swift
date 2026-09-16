import Foundation
import Observation
import SwiftUI

/// Pure validation and sizing. File presence is only a preflight: Core ML
/// loading AND an inference must succeed before Whisper reports ready.
nonisolated enum ModelPreparationPolicy {
    static func requiredFreeBytes(downloadMB: Int) -> Int64 {
        guard downloadMB > 0 else { return 0 }
        return max(2 * 1_073_741_824, Int64(downloadMB) * 2_000_000 + 1_073_741_824)
    }

    static func diskMessage(required: Int64, available: Int64) -> String {
        String(format: String(localized: "Not enough disk space — need %.1f GB free, only %.2f GB available. Free some space and try again."),
               Double(required) / 1_073_741_824, Double(available) / 1_073_741_824)
    }

    static func isCompleteWhisperFolder(_ folder: URL) -> Bool {
        for bundle in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            for file in ["coremldata.bin", "model.mil", "weights/weight.bin"] {
                let url = folder.appendingPathComponent("\(bundle).mlmodelc/\(file)")
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true, (values.fileSize ?? 0) > 0,
                      let handle = try? FileHandle(forReadingFrom: url) else { return false }
                let prefix = try? handle.read(upToCount: 128)
                try? handle.close()
                guard let prefix,
                      !String(decoding: prefix, as: UTF8.self).hasPrefix("version https://git-lfs.github.com/spec/v1") else { return false }
            }
        }
        return true
    }
}

@MainActor @Observable
final class ModelPreparation {
    static var activePreparations = 0
    private(set) var isRunning = false
    private(set) var stage = ""
    private(set) var error: String?
    private var preparedKey: String?

    private func key(settings: AppSettings, includeSpeakers: Bool) -> String {
        "\(WhisperEngine.shared.modelID)|\(settings.dictationEngine.rawValue)|\(settings.dictationLocale)|\(settings.defaultTranscriptionLocale)|\(includeSpeakers)|\(settings.diarizeRemoteSpeakers)|\(settings.diarizeMicrophone)|\(settings.dictationUseNemotronLive)"
    }

    func canFinish(settings: AppSettings, includeSpeakers: Bool) -> Bool {
        !isRunning && preparedKey == key(settings: settings, includeSpeakers: includeSpeakers)
            && WhisperEngine.shared.isReady
            && (!settings.dictationUseNemotronLive || NemotronLiveEngine.shared.isReady)
            && (settings.dictationEngine != .parakeet || ParakeetEngine.shared.isReady)
            && (!includeSpeakers || (!settings.diarizeRemoteSpeakers && !settings.diarizeMicrophone)
                || DiarizationEngine.shared.isAvailable)
    }

    func prepare(settings: AppSettings, includeSpeakers: Bool, downloadAgain: Bool = false) async {
        guard !isRunning, Self.activePreparations == 0 else { return }
        guard !RecordingSession.isCapturingOrTranscribing, !SessionAudioProcessing.shared.isRunning else {
            error = String(localized: "Wait for recording and transcription to finish before preparing models.")
            return
        }
        isRunning = true
        Self.activePreparations += 1
        error = nil
        preparedKey = nil
        let requestedKey = key(settings: settings, includeSpeakers: includeSpeakers)
        defer { isRunning = false; stage = ""; Self.activePreparations -= 1 }
        if !settings.hasShownFirstRun { UserDefaults.standard.set(true, forKey: "daisy.preparation.started") }
        let whisper = WhisperEngine.shared
        stage = String(localized: "Preparing speech recognition…")
        if downloadAgain { await whisper.downloadAgain() }
        else { await whisper.ensureLoaded() }
        guard whisper.isReady else {
            if case .failed(let reason) = whisper.state { error = reason }
            else { error = String(localized: "The speech model is not ready. Try again.") }
            return
        }
        stage = String(localized: "Preparing speech detection…")
        guard await whisper.prepareSpeechDetection() else {
            error = String(localized: "Couldn’t prepare speech detection. Check your connection and try again.")
            return
        }
        if settings.dictationEngine == .parakeet {
            stage = String(localized: "Preparing fast dictation…")
            await ParakeetEngine.shared.ensureLoaded()
            guard ParakeetEngine.shared.isReady else {
                if case .failed(let reason) = ParakeetEngine.shared.state { error = reason }
                else { error = String(localized: "Couldn’t prepare fast dictation. Try again.") }
                return
            }
        }
        if settings.dictationEngine == .appleSpeech, #available(macOS 26, *) {
            let locale = settings.dictationLocale.isEmpty ? settings.defaultTranscriptionLocale : settings.dictationLocale
            if !locale.isEmpty, locale != "auto" {
                stage = String(localized: "Preparing Apple dictation…")
                guard await AppleSpeechEngine.ensureModelReady(locale: Locale(identifier: locale)) else {
                    error = String(localized: "Apple dictation is unavailable for this language. Choose Standard in Settings → Transcription and try again.")
                    return
                }
            }
        }
        if settings.dictationUseNemotronLive {
            stage = String(localized: "Preparing live dictation…")
            await NemotronLiveEngine.shared.ensureLoaded()
            guard NemotronLiveEngine.shared.isReady else {
                error = String(localized: "Couldn’t prepare live dictation. Turn off live preview in Settings → Transcription or try again.")
                return
            }
        }
        if includeSpeakers && (settings.diarizeRemoteSpeakers || settings.diarizeMicrophone) {
            stage = String(localized: "Preparing speaker separation…")
            await DiarizationEngine.shared.ensureLoaded()
            guard DiarizationEngine.shared.isAvailable else {
                error = DiarizationEngine.shared.lastLoadError ?? String(localized: "Couldn’t prepare speaker separation. Try again.")
                return
            }
        }
        guard !Task.isCancelled, requestedKey == key(settings: settings, includeSpeakers: includeSpeakers) else { return }
        preparedKey = requestedKey
    }
}

struct ModelPreparationView: View {
    @Bindable var settings: AppSettings
    @Bindable var preparation: ModelPreparation
    var includeSpeakers: Bool
    @Bindable private var whisper = WhisperEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Prepare Daisy").font(.title2.weight(.semibold))
            Text("Download the speech models, then let Daisy check that they work. Keep this window open until preparation is complete.")
                .foregroundStyle(.secondary)
            if !settings.hasShownFirstRun {
                Picker("Speech model", selection: $whisper.modelID) {
                    ForEach(WhisperEngine.availableModels, id: \.id) { model in
                        Text("\(model.label) · \(model.sizeMB) MB").tag(model.id)
                    }
                }
                .disabled(preparation.isRunning)
                Picker("Dictation engine", selection: $settings.dictationEngine) {
                    Text(DictationEngine.whisper.displayName).tag(DictationEngine.whisper)
                    Text(DictationEngine.parakeet.displayName).tag(DictationEngine.parakeet)
                    if #available(macOS 26, *), settings.dictationEngine == .appleSpeech {
                        Text(DictationEngine.appleSpeech.displayName).tag(DictationEngine.appleSpeech)
                    }
                }
                .disabled(preparation.isRunning)
                if includeSpeakers {
                    Toggle("Separate speakers", isOn: $settings.diarizeRemoteSpeakers)
                        .disabled(preparation.isRunning)
                }
            }
            if preparation.isRunning {
                Text(preparation.stage)
                if case .downloading(let progress) = whisper.state {
                    ProgressView(value: progress)
                    Text("\(Int(progress * Double(whisper.activeModelSizeMB))) / \(whisper.activeModelSizeMB) MB")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading and checking models…").font(.caption)
                    }
                }
            } else if preparation.canFinish(settings: settings, includeSpeakers: includeSpeakers) {
                Label("Daisy is ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.daisyAccent)
            }
            if let error = preparation.error {
                Text("Preparation failed. You can retry, choose another model, or download the speech model again.")
                    .foregroundStyle(Color.daisyWarning)
                Text(error).font(.caption).textSelection(.enabled)
            } else if case .failed(let error) = whisper.state {
                Text(error).font(.caption).foregroundStyle(Color.daisyWarning).textSelection(.enabled)
            }
            HStack {
                Button("Download and check") {
                    Task { await preparation.prepare(settings: settings, includeSpeakers: includeSpeakers) }
                }
                .disabled(preparation.isRunning)
                if preparation.error != nil || whisperFailed {
                    Button("Download speech model again") {
                        Task { await preparation.prepare(settings: settings, includeSpeakers: includeSpeakers, downloadAgain: true) }
                    }
                    .disabled(preparation.isRunning)
                }
            }
            if preparation.error != nil || whisperFailed {
                Text("Downloading again keeps the previous model files for diagnostics and needs additional free space.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Export Logs…") { LogReporter.exportLogs(settings: settings) }
            }
        }
        .task {
            if !settings.hasShownFirstRun, UserDefaults.standard.bool(forKey: "daisy.preparation.started") {
                await preparation.prepare(settings: settings, includeSpeakers: includeSpeakers)
            }
        }
    }

    private var whisperFailed: Bool {
        if case .failed = whisper.state { return true }
        return false
    }
}

nonisolated struct ModelDownloadDiskError: LocalizedError {
    let required: Int64
    let available: Int64
    var errorDescription: String? { ModelPreparationPolicy.diskMessage(required: required, available: available) }
}
