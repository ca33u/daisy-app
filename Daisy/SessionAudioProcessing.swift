//
//  SessionAudioProcessing.swift
//  Daisy
//
//  Explicit operations over audio retained inside a finished session:
//  add the first transcript to an audio-only folder, create a new derived
//  session when a transcript already exists, or export all tracks as M4A.
//

import AVFoundation
import Foundation
import Observation
import os

nonisolated struct SessionAudioFiles: Sendable, Equatable {
    let microphone: [URL]
    let system: [URL]

    var all: [URL] { microphone + system }
    var hasAny: Bool { !all.isEmpty }

    static func discover(in directory: URL) -> SessionAudioFiles {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return SessionAudioFiles(
            microphone: parts(in: entries, prefix: "microphone"),
            system: parts(in: entries, prefix: "system_audio")
        )
    }

    /// Container formats a session folder may hold under the
    /// `microphone` / `system_audio` name. Daisy itself only ever
    /// writes `.caf`; the rest arrive through `AudioImporter` (as
    /// `system_audio.<ext>`), which keeps the original container (no
    /// lossy re-encode) and relies on
    /// `AVAudioFile` reading all of these natively. Extend here AND in
    /// `AudioImporter.supportedExtensions` together.
    nonisolated static let audioExtensions: Set<String> = [
        "caf", "m4a", "mp3", "wav", "aiff", "aif", "aac", "flac",
    ]

    private static func parts(in entries: [URL], prefix: String) -> [URL] {
        entries
            .filter { url in
                let ext = url.pathExtension.lowercased()
                guard audioExtensions.contains(ext) else { return false }
                let stem = url.deletingPathExtension().lastPathComponent
                if stem == prefix { return true }
                let marker = "\(prefix).part"
                guard stem.hasPrefix(marker) else { return false }
                return Int(stem.dropFirst(marker.count)) != nil
            }
            .sorted { partNumber($0, prefix: prefix) < partNumber($1, prefix: prefix) }
    }

    private static func partNumber(_ url: URL, prefix: String) -> Int {
        let name = url.deletingPathExtension().lastPathComponent
        if name == prefix { return 1 }
        let marker = "\(prefix).part"
        guard name.hasPrefix(marker), let value = Int(name.dropFirst(marker.count)) else {
            return Int.max
        }
        return value
    }
}

nonisolated struct SessionRetranscriptionOptions: Sendable, Equatable {
    var modelID: String
    var language: String
    var diarize: Bool
}

@Observable
@MainActor
final class SessionAudioProcessing {
    static let shared = SessionAudioProcessing()

    private(set) var isRunning = false
    private(set) var statusText = ""

    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "AudioProcessing")

    private init() {}

    var recordingOrFinalizeIsActive: Bool {
        guard let recording = RecordingSession.current else { return false }
        if recording.summaryTask != nil { return true }
        switch recording.status {
        case .preparing, .recording, .paused, .stopping, .summarizing:
            return true
        case .idle, .finished, .failed:
            return false
        }
    }

    func retranscribe(
        _ session: StoredSession,
        options: SessionRetranscriptionOptions
    ) async throws -> StoredSession.ID {
        guard !isRunning else { throw ProcessingError.busy }
        guard !recordingOrFinalizeIsActive else { throw ProcessingError.recordingActive }
        let sourceFiles = SessionAudioFiles.discover(in: session.directoryURL)
        guard sourceFiles.hasAny else { throw ProcessingError.noAudio }
        let isFirstTranscript = session.transcriptURL == nil

        isRunning = true
        statusText = isFirstTranscript
            ? String(localized: "Preparing the recording")
            : String(localized: "Preparing a new session")
        defer {
            WhisperEngine.shared.releaseAlternateModel(options.modelID)
            isRunning = false
            statusText = ""
        }

        // The source may live in a previous custom root rather than the
        // current write destination. Acquire that exact root so an
        // audio-only folder left behind after a storage change remains
        // transcribable.
        let sourceBase = session.directoryURL
            .deletingLastPathComponent() // Sessions
            .deletingLastPathComponent() // Daisy
            .deletingLastPathComponent() // chosen base
        guard let ticket = SessionsFolder.acquireAccess(
            to: sourceBase,
            requireWrite: true
        ) else {
            throw ProcessingError.sourceUnavailable
        }
        defer { ticket.release() }

        let finalID = isFirstTranscript
            ? session.id
            : Self.derivedSessionID(parentID: session.id)
        let parent = session.directoryURL.deletingLastPathComponent()
        let finalDirectory = parent.appendingPathComponent(finalID, isDirectory: true)
        let stagingDirectory = parent.appendingPathComponent(
            ".daisy-retranscribe-\(UUID().uuidString)",
            isDirectory: true
        )
        var committed = false
        defer {
            if !committed {
                try? FileManager.default.removeItem(at: stagingDirectory)
            }
        }

        let processingFiles: SessionAudioFiles
        if isFirstTranscript {
            // Keep multi-gigabyte archives in place. Only the new metadata
            // is staged and atomically committed at the end.
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
            processingFiles = sourceFiles
        } else {
            statusText = String(localized: "Copying retained audio")
            processingFiles = try await Task.detached(priority: .utility) {
                try Self.copyAudio(
                    source: sourceFiles,
                    from: session.directoryURL,
                    to: stagingDirectory
                )
            }.value
        }

        statusText = String(localized: "Loading the selected model")
        let language = Self.whisperLanguage(options.language)
        let biasTerms = DictationDictionary.shared.biasTerms()

        statusText = String(localized: "Transcribing microphone audio")
        let microphoneOutput = try await transcribeChannel(
            processingFiles.microphone,
            source: .microphone,
            language: language,
            modelID: options.modelID,
            diarize: options.diarize && processingFiles.system.isEmpty,
            startedAt: session.startedAt,
            biasTerms: biasTerms
        )

        statusText = String(localized: "Transcribing system audio")
        let systemOutput = try await transcribeChannel(
            processingFiles.system,
            source: .systemAudio,
            language: language,
            modelID: options.modelID,
            diarize: options.diarize,
            startedAt: session.startedAt,
            biasTerms: biasTerms
        )

        var segments = (microphoneOutput.segments + systemOutput.segments)
            .sorted { $0.startSec < $1.startSec }
        let corrections = MeetingVocabulary.corrections(
            for: segments,
            rules: DictationDictionary.shared.replacements,
            applyBrandTable: RecordingSession.current?.settings.fixBrandNamesInDictation ?? true
        )
        if !corrections.isEmpty {
            segments = segments.map { segment in
                guard let corrected = corrections.replacements[segment.id] else { return segment }
                var copy = segment
                copy.text = corrected
                return copy
            }
        }
        if RecordingSession.current?.settings.suppressAcousticEcho == true {
            segments = AcousticEchoDedup.filter(segments)
        }

        statusText = String(localized: "Writing the new transcript")
        let originalMarkdown = session.transcriptURL.flatMap {
            try? String(contentsOf: $0, encoding: .utf8)
        } ?? ""
        let markdown = Self.renderDerivedTranscript(
            originalMarkdown: originalMarkdown,
            session: session,
            options: options,
            segments: segments,
            audioFiles: processingFiles.all.map(\.lastPathComponent),
            isFirstTranscript: isFirstTranscript
        )
        try markdown.write(
            to: stagingDirectory.appendingPathComponent("transcript.md"),
            atomically: true,
            encoding: .utf8
        )

        let centroids = systemOutput.centroids.isEmpty
            ? microphoneOutput.centroids
            : systemOutput.centroids
        if !centroids.isEmpty {
            let data = try JSONEncoder().encode(SpeakerCentroidsFile(centroids: centroids))
            try data.write(
                to: stagingDirectory.appendingPathComponent("speakers.json"),
                options: .atomic
            )
        }
        if isFirstTranscript {
            try Self.commitFirstTranscript(
                from: stagingDirectory,
                to: session.directoryURL
            )
        } else {
            try Self.copyOptionalSidecar(
                named: "markers.json",
                from: session.directoryURL,
                to: stagingDirectory
            )
            try FileManager.default.moveItem(at: stagingDirectory, to: finalDirectory)
        }
        committed = true
        if isFirstTranscript {
            log.info("Created first transcript in session \(session.id, privacy: .private)")
        } else {
            log.info("Created derived session \(finalID, privacy: .private) from \(session.id, privacy: .private)")
        }
        await SessionStore.shared.refresh()
        return finalID
    }

    func exportAudio(_ session: StoredSession, to destination: URL) async throws {
        guard !isRunning else { throw ProcessingError.busy }
        guard !recordingOrFinalizeIsActive else { throw ProcessingError.recordingActive }
        let files = SessionAudioFiles.discover(in: session.directoryURL)
        guard files.hasAny else { throw ProcessingError.noAudio }

        isRunning = true
        statusText = String(localized: "Creating M4A audio")
        defer {
            isRunning = false
            statusText = ""
        }
        let ticket = SessionsFolder.acquireBase()
        defer { ticket?.release() }

        let staging = destination.deletingLastPathComponent().appendingPathComponent(
            ".daisy-audio-\(UUID().uuidString).m4a"
        )
        var committed = false
        defer {
            if !committed { try? FileManager.default.removeItem(at: staging) }
        }
        try await Task.detached(priority: .userInitiated) {
            try SessionM4AExporter.export(files: files, to: staging)
        }.value
        try Task.checkCancellation()
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
        committed = true
    }

    private struct ChannelOutput {
        var segments: [TranscriptSegment]
        var centroids: [String: [Float]]
    }

    private func transcribeChannel(
        _ urls: [URL],
        source: SegmentSource,
        language: String?,
        modelID: String,
        diarize: Bool,
        startedAt: Date,
        biasTerms: [String]
    ) async throws -> ChannelOutput {
        guard !urls.isEmpty else { return ChannelOutput(segments: [], centroids: [:]) }
        let reader = ArchiveBlockReader(urls: urls)
        let diarizationPass = diarize ? await DiarizationEngine.shared.makeBlockPass() : nil
        var segments: [TranscriptSegment] = []

        while let block = await Task.detached(
            priority: .userInitiated,
            operation: { reader.nextBlock() }
        ).value {
            try Task.checkCancellation()
            async let diarization: Void = { [diarizationPass] in
                guard let diarizationPass else { return }
                await Task.detached(priority: .userInitiated) {
                    diarizationPass.process(samples: block.samples, atSec: block.startSec)
                }.value
            }()
            let whisper = try await WhisperEngine.shared.transcribe(
                samples: block.samples,
                language: language,
                modelID: modelID,
                profile: .full,
                biasTerms: biasTerms
            )
            await diarization
            for item in whisper {
                let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = block.startSec + item.start
                let end = block.startSec + item.end
                segments.append(TranscriptSegment(
                    id: UUID(),
                    startedAt: startedAt.addingTimeInterval(start),
                    text: text,
                    isFinal: true,
                    source: source,
                    speakerId: nil,
                    endSec: end,
                    startSec: start
                ))
            }
        }

        let diarization = diarizationPass?.finish()
            ?? DiarizationOutput(spans: [], centroids: [:])
        let merged = DiarizationEngine.mergeBySpeaker(
            segments: segments,
            diarization: diarization.spans
        )
        return ChannelOutput(segments: merged, centroids: diarization.centroids)
    }

    nonisolated static func derivedSessionID(parentID: String, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "\(parentID)-retranscribed-\(formatter.string(from: now))"
    }

    static func renderDerivedTranscript(
        originalMarkdown: String,
        session: StoredSession,
        options: SessionRetranscriptionOptions,
        segments: [TranscriptSegment],
        audioFiles: [String],
        isFirstTranscript: Bool = false
    ) -> String {
        let derivedTitle = isFirstTranscript
            ? session.title
            : String(
                format: String(localized: "%@ — re-transcribed"),
                session.title
            )
        var markdown = preservedFrontmatter(from: originalMarkdown)
        if markdown.isEmpty { markdown = "---\n---" }
        markdown += "\n\n# \(derivedTitle)\n\n## Transcript\n\n"

        let displayName = RecordingSession.current?.settings.userDisplayName
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let label = segment.speakerLabel(displayName: displayName)
            markdown += "**[\(formatDuration(segment.startSec)) · \(label)]** \(text)\n\n"
        }
        if segments.isEmpty {
            markdown += "_\(String(localized: "No speech detected."))_\n"
        }

        markdown = SessionStore.upsertFrontmatter(
            in: markdown,
            key: "title",
            value: yamlQuote(derivedTitle)
        )
        markdown = SessionStore.upsertFrontmatter(in: markdown, key: "type", value: "meeting-transcript")
        markdown = SessionStore.upsertFrontmatter(
            in: markdown,
            key: "source",
            value: yamlQuote(isFirstTranscript ? "Daisy audio transcription" : "Daisy re-transcription")
        )
        markdown = SessionStore.upsertFrontmatter(in: markdown, key: "locale", value: options.language)
        markdown = SessionStore.upsertFrontmatter(
            in: markdown,
            key: "started",
            value: ISO8601DateFormatter().string(from: session.startedAt)
        )
        let detectedDuration = Int(ceil(segments.map(\.endSec).max() ?? 0))
        markdown = SessionStore.upsertFrontmatter(
            in: markdown,
            key: "duration_sec",
            value: String(max(session.durationSec, detectedDuration))
        )
        markdown = SessionStore.upsertFrontmatter(in: markdown, key: "daisy_folder", value: session.folderSlug)
        markdown = SessionStore.upsertFrontmatter(in: markdown, key: "daisy_kind", value: SessionKind.recording.rawValue)
        if !isFirstTranscript {
            markdown = SessionStore.upsertFrontmatter(
                in: markdown,
                key: "daisy_parent_session",
                value: yamlQuote(session.id)
            )
        } else if let marker = ImportMarker.load(from: session.directoryURL) {
            // Provenance of an imported file moves from the sidecar
            // into the transcript, where every other session field
            // lives (see AudioImporter / design 2026-08-31 §1).
            markdown = SessionStore.upsertFrontmatter(in: markdown, key: "daisy_imported", value: "true")
            markdown = SessionStore.upsertFrontmatter(in: markdown, key: "daisy_import_source", value: yamlQuote(marker.sourcePath))
            markdown = SessionStore.upsertFrontmatter(in: markdown, key: "daisy_import_mode", value: marker.mode.rawValue)
            markdown = SessionStore.upsertFrontmatter(in: markdown, key: "daisy_import_original_name", value: yamlQuote(marker.originalName))
        }
        markdown = SessionStore.upsertFrontmatter(in: markdown, key: "daisy_transcription_model", value: yamlQuote(options.modelID))
        markdown = SessionStore.upsertFrontmatter(in: markdown, key: "daisy_transcription_language", value: options.language)
        markdown = SessionStore.upsertFrontmatter(in: markdown, key: "daisy_diarization", value: options.diarize ? "true" : "false")
        markdown = SessionStore.upsertFrontmatter(in: markdown, key: "daisy_speaker_map", value: "{}")
        let encodedAudio = audioFiles.map(yamlQuote).joined(separator: ", ")
        markdown = SessionStore.upsertFrontmatter(in: markdown, key: "daisy_audio_files", value: "[\(encodedAudio)]")
        return markdown
    }

    nonisolated private static func preservedFrontmatter(from markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return "" }
        for index in 1..<lines.count where lines[index].trimmingCharacters(in: .whitespaces) == "---" {
            return lines[0...index].joined(separator: "\n")
        }
        return ""
    }

    nonisolated private static func copyAudio(
        source: SessionAudioFiles,
        from sourceDirectory: URL,
        to destinationDirectory: URL
    ) throws -> SessionAudioFiles {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        for url in source.all {
            try Task.checkCancellation()
            try fm.copyItem(
                at: sourceDirectory.appendingPathComponent(url.lastPathComponent),
                to: destinationDirectory.appendingPathComponent(url.lastPathComponent)
            )
        }
        return SessionAudioFiles.discover(in: destinationDirectory)
    }

    nonisolated private static func copyOptionalSidecar(
        named name: String,
        from sourceDirectory: URL,
        to destinationDirectory: URL
    ) throws {
        let source = sourceDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try FileManager.default.copyItem(
            at: source,
            to: destinationDirectory.appendingPathComponent(name)
        )
    }

    /// Atomically publish only generated metadata into an existing
    /// audio-only folder. Audio never moves and an existing transcript is
    /// never overwritten if another process created one while we worked.
    nonisolated private static func commitFirstTranscript(
        from stagingDirectory: URL,
        to sessionDirectory: URL
    ) throws {
        let fm = FileManager.default
        let stagedTranscript = stagingDirectory.appendingPathComponent("transcript.md")
        let transcript = sessionDirectory.appendingPathComponent("transcript.md")
        guard !fm.fileExists(atPath: transcript.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fm.moveItem(at: stagedTranscript, to: transcript)

        let stagedSpeakers = stagingDirectory.appendingPathComponent("speakers.json")
        if fm.fileExists(atPath: stagedSpeakers.path) {
            let speakers = sessionDirectory.appendingPathComponent("speakers.json")
            if fm.fileExists(atPath: speakers.path) {
                _ = try? fm.replaceItemAt(speakers, withItemAt: stagedSpeakers)
            } else {
                try? fm.moveItem(at: stagedSpeakers, to: speakers)
            }
        }
        try? fm.removeItem(at: stagingDirectory)
    }

    nonisolated private static func whisperLanguage(_ locale: String) -> String? {
        let normalized = locale.lowercased()
        guard !normalized.isEmpty, normalized != "auto" else { return nil }
        return normalized.split(separator: "-").first.map(String.init)
    }

    nonisolated private static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    nonisolated private static func yamlQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

nonisolated enum ProcessingError: LocalizedError {
    case busy
    case recordingActive
    case noAudio
    case sourceUnavailable

    var errorDescription: String? {
        switch self {
        case .busy:
            return String(localized: "Another audio operation is already running.")
        case .recordingActive:
            return String(localized: "Finish the active recording and its transcription before processing stored audio.")
        case .noAudio:
            return String(localized: "This session does not contain retained audio.")
        case .sourceUnavailable:
            return String(localized: "Daisy couldn't write to this recording folder. Choose its storage folder again in Settings.")
        }
    }
}

nonisolated enum SessionM4AExporter {
    static func export(files: SessionAudioFiles, to destination: URL) throws {
        guard files.hasAny else { throw ProcessingError.noAudio }
        let sampleRate = 16_000.0
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            // 32 kbps is in CoreAudio's supported AAC range for mono
            // 16 kHz speech. 64 kbps fails at encoder setup on some Macs.
            AVEncoderBitRateKey: 32_000,
        ]
        let output = try AVAudioFile(
            forWriting: destination,
            settings: outputSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let microphoneReader = files.microphone.isEmpty
            ? nil
            : ArchiveBlockReader(urls: files.microphone, blockSeconds: 10, cutSearchSeconds: 0)
        let systemReader = files.system.isEmpty
            ? nil
            : ArchiveBlockReader(urls: files.system, blockSeconds: 10, cutSearchSeconds: 0)
        var microphone = microphoneReader?.nextBlock()
        var system = systemReader?.nextBlock()
        var wroteFrames = false

        while microphone != nil || system != nil {
            try Task.checkCancellation()
            let microphoneSamples = microphone?.samples ?? []
            let systemSamples = system?.samples ?? []
            let count = max(microphoneSamples.count, systemSamples.count)
            guard count > 0,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: pcmFormat,
                    frameCapacity: AVAudioFrameCount(count)
                  ),
                  let samples = buffer.floatChannelData?[0] else { break }
            buffer.frameLength = AVAudioFrameCount(count)

            for index in 0..<count {
                let mic = index < microphoneSamples.count ? microphoneSamples[index] : 0
                let remote = index < systemSamples.count ? systemSamples[index] : 0
                let mixed: Float
                if !microphoneSamples.isEmpty, !systemSamples.isEmpty {
                    mixed = (mic + remote) * 0.7
                } else {
                    mixed = mic + remote
                }
                samples[index] = max(-1, min(1, mixed))
            }
            try output.write(from: buffer)
            wroteFrames = true
            microphone = microphoneReader?.nextBlock()
            system = systemReader?.nextBlock()
        }
        if !wroteFrames { throw ProcessingError.noAudio }
    }
}
