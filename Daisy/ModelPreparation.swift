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
    /// Something optional didn't come down — speech detection or
    /// speaker separation. Daisy works without either (Whisper decodes
    /// the whole buffer; transcripts ship without speaker labels), so
    /// this is shown, not blocking, and the engines retry on their own
    /// the next time they're needed.
    private(set) var notice: String?
    private var preparedKey: String?

    /// Finish preparing after the user chose "Skip for now" in
    /// onboarding. Runs on a fresh instance held alive by its own task,
    /// so it outlives the onboarding view that asked for it. Best
    /// effort by design: if a recording starts first, `prepare` steps
    /// aside and `start()` loads what it needs itself; if there's no
    /// network, Whisper's own reconnect hook picks the download up
    /// later. Nothing here is a user-visible failure — the user already
    /// said "later".
    static func completeInBackground(settings: AppSettings, includeSpeakers: Bool) {
        Task { @MainActor in
            let preparation = ModelPreparation()
            await preparation.prepare(settings: settings, includeSpeakers: includeSpeakers)
        }
    }

    private func key(settings: AppSettings, includeSpeakers: Bool) -> String {
        "\(WhisperEngine.shared.modelID)|\(settings.dictationEngine.rawValue)|\(settings.dictationLocale)|\(settings.defaultTranscriptionLocale)|\(includeSpeakers)|\(settings.diarizeRemoteSpeakers)|\(settings.diarizeMicrophone)|\(settings.dictationUseNemotronLive)"
    }

    /// Ready to leave onboarding: the engines the user's choices REQUIRE
    /// are loaded and verified. Speech detection and speaker separation
    /// are deliberately absent from this list — both are optional at
    /// runtime (`WhisperEngine` decodes without VAD, `DiarizationEngine`
    /// reports `isAvailable == false` and transcripts ship unlabelled),
    /// and requiring them here turned a new user without 2 GB free, or
    /// without network for the diarizer bundle, into one who could not
    /// finish onboarding at all.
    func canFinish(settings: AppSettings, includeSpeakers: Bool) -> Bool {
        !isRunning && preparedKey == key(settings: settings, includeSpeakers: includeSpeakers)
            && WhisperEngine.shared.isReady
            && (!settings.dictationUseNemotronLive || NemotronLiveEngine.shared.isReady)
            && (settings.dictationEngine != .parakeet || ParakeetEngine.shared.isReady)
    }

    /// True once a recording or transcription began while a background
    /// preparation was mid-way. The remaining steps are skipped — a 600 MB
    /// download and a CoreML load next to a live recording is memory
    /// pressure exactly when it hurts most — and `start()` loads what it
    /// needs itself; the rest comes down the next time it's asked for.
    private var steppedAside: Bool {
        RecordingSession.isCapturingOrTranscribing || SessionAudioProcessing.shared.isRunning
    }

    private func noteSteppedAside() {
        notice = String(localized: "A recording started — the rest downloads after it ends.")
    }

    func prepare(settings: AppSettings, includeSpeakers: Bool, downloadAgain: Bool = false) async {
        guard !isRunning else { return }
        guard Self.activePreparations == 0 else {
            // A background completion (after "Skip for now") is still
            // running; a silent return here read as a dead button.
            error = String(localized: "Daisy is already preparing models in the background — give it a minute.")
            return
        }
        guard !RecordingSession.isCapturingOrTranscribing, !SessionAudioProcessing.shared.isRunning else {
            error = String(localized: "Wait for recording and transcription to finish before preparing models.")
            return
        }
        isRunning = true
        Self.activePreparations += 1
        error = nil
        notice = nil
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
        // Optional from here on: a miss is a notice, not a failure.
        if steppedAside { noteSteppedAside(); return }
        stage = String(localized: "Preparing speech detection…")
        let speechDetectionReady = await whisper.prepareSpeechDetection()
        if !speechDetectionReady {
            notice = String(localized: "Speech detection isn’t downloaded yet — Daisy works without it and will fetch it when the network is back.")
        }
        if steppedAside { noteSteppedAside(); return }
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
        if steppedAside { noteSteppedAside(); return }
        if settings.dictationUseNemotronLive {
            stage = String(localized: "Preparing live dictation…")
            await NemotronLiveEngine.shared.ensureLoaded()
            guard NemotronLiveEngine.shared.isReady else {
                error = String(localized: "Couldn’t prepare live dictation. Turn off live preview in Settings → Transcription or try again.")
                return
            }
        }
        if steppedAside { noteSteppedAside(); return }
        if includeSpeakers && (settings.diarizeRemoteSpeakers || settings.diarizeMicrophone) {
            stage = String(localized: "Preparing speaker separation…")
            await DiarizationEngine.shared.ensureLoaded()
            if !DiarizationEngine.shared.isAvailable {
                let line = String(localized: "Speaker separation isn’t downloaded yet — meetings will record without speaker labels until it is.")
                // Both optional pieces can be missing at once; say so.
                notice = notice.map { "\($0)\n\(line)" } ?? line
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
            Text("Download the speech models, then let Daisy check that they work. If you’d rather not wait, skip for now — they finish in the background, and your first recording waits for them.")
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
            if let notice = preparation.notice, preparation.error == nil {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = preparation.error {
                Text("Preparation failed. You can retry, choose another model, or download the speech model again.")
                    .foregroundStyle(Color.daisyWarningText)
                Text(error).font(.caption).textSelection(.enabled)
            } else if case .failed(let error) = whisper.state {
                Text(error).font(.caption).foregroundStyle(Color.daisyWarningText).textSelection(.enabled)
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
            // Unstructured on purpose: `.task` is cancelled when this
            // view leaves the hierarchy, and "Skip for now" does exactly
            // that mid-preparation. The engines don't stop on
            // cancellation anyway, but the Apple-dictation step would,
            // and a resumed preparation should finish like one the
            // button started.
            if !settings.hasShownFirstRun, UserDefaults.standard.bool(forKey: "daisy.preparation.started") {
                Task { @MainActor in
                    await preparation.prepare(settings: settings, includeSpeakers: includeSpeakers)
                }
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
