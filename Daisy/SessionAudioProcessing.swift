//
//  SessionAudioProcessing.swift
//  Daisy
//
//  Explicit operations over audio retained inside a finished session:
//  add the first transcript to an audio-only folder, create a new derived
//  session when a transcript already exists, or export all tracks as M4A.
//

import AVFoundation
import DaisyCore
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

/// The provider passes finalize runs after its final Whisper pass — the
/// polish of names and terms (Stage 2b) and names from the conversation
/// (Stage 2c) — for a meeting the queue finishes instead (07.10.2026).
/// The caller has already applied finalize's privacy gate: a pass that's
/// off here is off because the transcript isn't going to this provider.
nonisolated struct SessionFinishingPasses: Sendable {
    var title: String
    var localeHint: String?
    var polish: Bool
    var suggestNames: Bool
    /// The bound calendar event's attendees: the polish's names and the
    /// name pass's allow-list.
    var attendees: [String]
}

@Observable
@MainActor
final class SessionAudioProcessing {
    static let shared = SessionAudioProcessing()

    private(set) var isRunning = false
    private(set) var statusText = ""
    /// How far the running transcription is, 0…1; nil when nothing is
    /// being transcribed or the length is unknown.
    private(set) var progress: Double?
    /// Which stretch of the whole job the channel being decoded covers:
    /// the microphone first, then the system audio.
    @ObservationIgnored private var progressSpan: (from: Double, to: Double) = (0, 1)

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

    /// `replaceLiveTranscript`: the session's transcript is the live text
    /// of a recording whose final pass never ran (the next recording
    /// started). Write the final transcript INTO this session, replacing
    /// it, and clear the `.recording` marker — not a derived copy.
    /// `finishing`: also run finalize's provider passes (the queue's
    /// finish of such a recording).
    func retranscribe(
        _ session: StoredSession,
        options: SessionRetranscriptionOptions,
        replaceLiveTranscript: Bool = false,
        finishing: SessionFinishingPasses? = nil
    ) async throws -> StoredSession.ID {
        guard !isRunning else { throw ProcessingError.busy }
        guard !recordingOrFinalizeIsActive else { throw ProcessingError.recordingActive }
        let sourceFiles = SessionAudioFiles.discover(in: session.directoryURL)
        guard sourceFiles.hasAny else { throw ProcessingError.noAudio }
        let isFirstTranscript = session.transcriptURL == nil || replaceLiveTranscript

        isRunning = true
        statusText = isFirstTranscript
            ? String(localized: "Preparing the recording")
            : String(localized: "Preparing a new session")
        defer {
            WhisperEngine.shared.releaseAlternateModel(options.modelID)
            isRunning = false
            statusText = ""
            progress = nil
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
        // session-format.md §3.6: a phone session's microphone track is
        // the whole room, not the owner — diarized whole, owner found by
        // voice profile, everyone else `Remote`.
        let originalMarkdown = session.transcriptURL.flatMap {
            try? String(contentsOf: $0, encoding: .utf8)
        } ?? ""
        let isPhoneSession = SessionOrigin.isRoomMicrophone(Self.frontmatterValue("daisy_origin", in: originalMarkdown))

        let transcribeStarted = Date()
        let bothChannels = !processingFiles.microphone.isEmpty && !processingFiles.system.isEmpty
        progressSpan = (0, bothChannels ? 0.5 : 1)
        statusText = String(localized: "Transcribing microphone audio")
        var microphoneOutput = try await transcribeChannel(
            processingFiles.microphone,
            source: .microphone,
            language: language,
            totalSec: Double(session.durationSec),
            modelID: options.modelID,
            diarize: options.diarize && processingFiles.system.isEmpty,
            startedAt: session.startedAt,
            biasTerms: biasTerms
        )

        progressSpan = (bothChannels ? 0.5 : 0, 1)
        statusText = String(localized: "Transcribing system audio")
        let systemOutput = try await transcribeChannel(
            processingFiles.system,
            source: .systemAudio,
            language: language,
            totalSec: Double(session.durationSec),
            modelID: options.modelID,
            diarize: options.diarize,
            startedAt: session.startedAt,
            biasTerms: biasTerms
        )

        var carriedNames: [String: String] = [:]
        if isPhoneSession, options.diarize {
            let owner = SpeakerProfileStore.shared.ownerProfile?.embedding
            let assigned = PhoneSpeakerAssignment.apply(
                segments: microphoneOutput.segments,
                centroids: microphoneOutput.centroids,
                owner: owner
            )
            log.notice("Phone session: \(microphoneOutput.centroids.count, privacy: .public) cluster(s), owner \(assigned.ownerCluster ?? "not found", privacy: .public) (score \(String(format: "%.2f", assigned.ownerScore), privacy: .public), profile \(owner == nil ? "absent" : "present", privacy: .public))")
            microphoneOutput = ChannelOutput(segments: assigned.segments, centroids: assigned.centroids)
            // 25.09: the phone diarizes too, and names given there sit in
            // the parent's map under the phone's letters. They follow
            // their voice to this pass's letters, or the child would
            // open with every name gone.
            carriedNames = Self.namesFromParent(originalMarkdown: originalMarkdown, directory: session.directoryURL,
                                                to: assigned.centroids)
            if !carriedNames.isEmpty {
                log.notice("Phone session: \(carriedNames.count, privacy: .public) name(s) carried from the parent")
            }
        } else if !isPhoneSession, !processingFiles.microphone.isEmpty {
            // A Mac session: the mic IS the owner (§2.1) — the one place
            // the owner's voice can be learnt from without asking.
            let micFiles = processingFiles.microphone
            let displayName = RecordingSession.current?.settings.userDisplayName ?? ""
            Task.detached(priority: .utility) {
                if let embedding = await OwnerVoice.embedding(fromMicrophoneArchives: micFiles) {
                    await MainActor.run { _ = SpeakerProfileStore.shared.enrolOwner(embedding: embedding, displayName: displayName) }
                }
            }
        }

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
        // Echo dedup pairs the mic against the system stream; a phone
        // session has one track wearing both labels — nothing to dedup.
        if !isPhoneSession, RecordingSession.current?.settings.suppressAcousticEcho == true {
            segments = AcousticEchoDedup.filter(segments)
        }

        // A final pass that heard less than the live text did must not
        // replace it: «No speech detected.» over a meeting's live
        // transcript is the loss the ordinary finalize already refuses
        // (it keeps its live segments on a 0-segment pass). Here the
        // live text stays, the marker still goes — the recording is
        // finished, just with the text it had — and the summary is made
        // from the live text (review 24.09).
        if replaceLiveTranscript {
            let liveWords = Self.spokenWordCount(inTranscriptMarkdown: originalMarkdown)
            let finalWords = segments.reduce(0) { $0 + Self.spokenWordCount(in: $1.text) }
            if let reason = Self.reasonToKeepLiveTranscript(liveWords: liveWords, finalWords: finalWords) {
                log.error("Final pass for \(session.id, privacy: .public) kept the live transcript: \(reason, privacy: .public)")
                try? FileManager.default.removeItem(at: session.directoryURL.appendingPathComponent(".recording"))
                await SessionStore.shared.refresh()
                return session.id
            }
        }

        var rawMarkdown: String?
        if let finishing, finishing.polish {
            let before = segments
            segments = await polishSegments(
                segments, finishing: finishing,
                finalPassSeconds: Date().timeIntervalSince(transcribeStarted)
            )
            // Pre-empted by a recording mid-pass: nothing is committed
            // yet, so the job simply runs again later.
            try Task.checkCancellation()
            if segments.map(\.text) != before.map(\.text) {
                // finalize keeps what the recognizer heard next to the
                // corrected text; same file, same header, no frontmatter.
                let original = Self.renderDerivedTranscript(
                    originalMarkdown: originalMarkdown,
                    session: session,
                    options: options,
                    segments: before,
                    audioFiles: processingFiles.all.map(\.lastPathComponent),
                    isFirstTranscript: isFirstTranscript,
                    speakerMap: carriedNames
                )
                rawMarkdown = RecordingSession.rawTranscriptHeader + Self.bodyWithoutFrontmatter(original)
            }
        }

        statusText = String(localized: "Writing the new transcript")
        let markdown = Self.renderDerivedTranscript(
            originalMarkdown: originalMarkdown,
            session: session,
            options: options,
            segments: segments,
            audioFiles: processingFiles.all.map(\.lastPathComponent),
            isFirstTranscript: isFirstTranscript,
            speakerMap: carriedNames
        )
        try markdown.write(
            to: stagingDirectory.appendingPathComponent("transcript.md"),
            atomically: true,
            encoding: .utf8
        )
        if let rawMarkdown {
            try rawMarkdown.write(
                to: stagingDirectory.appendingPathComponent("transcript.raw.md"),
                atomically: true,
                encoding: .utf8
            )
        }

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
                to: session.directoryURL,
                replacing: replaceLiveTranscript
            )
            if replaceLiveTranscript {
                try? FileManager.default.removeItem(at: session.directoryURL.appendingPathComponent(".recording"))
            }
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
        if let finishing, finishing.suggestNames, isFirstTranscript {
            await suggestSpeakerNames(
                segments: segments, in: session.directoryURL,
                named: Set(carriedNames.keys), finishing: finishing
            )
        }
        return finalID
    }

    /// finalize Stage 2b over the queue's segments: the polish's
    /// corrections applied by segment id, or the segments unchanged.
    /// Best-effort, like finalize's — every failure keeps the recognizer's
    /// text.
    private func polishSegments(
        _ segments: [TranscriptSegment],
        finishing: SessionFinishingPasses,
        finalPassSeconds: Double
    ) async -> [TranscriptSegment] {
        let bodyLength = segments.reduce(0) { $0 + $1.text.count }
        guard segments.count >= 2, bodyLength >= 200,
              !Summarizer.isEffectivelySilent(segments.map(\.text).joined(separator: "\n")) else { return segments }
        statusText = String(localized: "Correcting names and terms")
        progress = nil
        let title = finishing.title
        let localeHint = finishing.localeHint
        let outcome = await TranscriptPolisher.polish(
            segments: segments,
            context: TranscriptPolisher.PromptContext(
                attendees: finishing.attendees,
                vocabulary: Array(DictationDictionary.shared.biasTerms().prefix(RecordingSession.polishVocabularyLimit)),
                meetingApp: nil
            ),
            localeHint: localeHint,
            // finalize's budget: a fifth of what the final pass took.
            deadlineSeconds: finalPassSeconds * 0.2,
            summarize: { payload, task in
                try await Summarizer.shared.runProbe(
                    transcript: payload, title: title, localeHint: localeHint, task: task)
            }
        )
        log.info("Queued finish: transcript polish \(outcome.chunksApplied, privacy: .public)/\(outcome.chunksTotal, privacy: .public) chunks, \(outcome.replacements.count, privacy: .public) segment(s) changed\(outcome.timedOut ? " (deadline cut the pass short)" : "", privacy: .public)")
        guard !outcome.replacements.isEmpty else { return segments }
        return segments.map { segment in
            guard let corrected = outcome.replacements[segment.id] else { return segment }
            var copy = segment
            copy.text = corrected
            return copy
        }
    }

    /// finalize Stage 2c for a committed session: a name for each
    /// unnamed remote speaker from how the attendees are addressed,
    /// merged into `speaker_suggestions.json` without displacing stronger
    /// evidence. Never names anyone by itself.
    private func suggestSpeakerNames(
        segments: [TranscriptSegment],
        in directory: URL,
        named: Set<String>,
        finishing: SessionFinishingPasses
    ) async {
        let attendees = finishing.attendees
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !attendees.isEmpty, !Task.isCancelled else { return }
        let persisted = RecordingSession.persistedSpeakerMap(at: directory.appendingPathComponent("transcript.md"))
        let existing = RecordingSession.loadSuggestions(in: directory)
        let labels = Set(segments.compactMap { $0.source == .systemAudio ? $0.speakerId : nil })
            .filter { !named.contains($0) && persisted[$0] == nil && existing?.byLabel[$0] == nil }
            .sorted()
        guard !labels.isEmpty else { return }
        let turns = SpeakerNameSuggester.turns(segments)
        let transcript = SpeakerNameSuggester.sampleTranscript(turns: turns)
        guard !transcript.isEmpty else { return }

        statusText = String(localized: "Looking for speaker names")
        let title = finishing.title
        let localeHint = finishing.localeHint
        let proposed = await SpeakerNameSuggester.suggest(
            transcript: transcript,
            context: .init(attendees: attendees, labels: labels),
            turns: turns,
            summarize: { payload, task in
                try await Summarizer.shared.runProbe(
                    transcript: payload, title: title, localeHint: localeHint, task: task)
            }
        )
        log.info("Queued finish: \(proposed.count, privacy: .public) name suggestion(s) for \(labels.count, privacy: .public) unnamed label(s)")
        guard !proposed.isEmpty, !Task.isCancelled else { return }
        let added = RecordingSession.mergeSuggestions(proposed, source: "mentioned", into: directory, alsoNamed: named)
        guard added > 0 else { return }
        ToastCenter.shared.show(
            String(localized: "Daisy has a name for \(added) speakers · review in Library"),
            style: .info
        )
    }

    /// A transcript without its YAML frontmatter.
    nonisolated static func bodyWithoutFrontmatter(_ markdown: String) -> String {
        guard markdown.hasPrefix("---\n"),
              let end = markdown.dropFirst(4).range(of: "\n---\n") else { return markdown }
        return String(markdown[end.upperBound...])
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
            progress = nil
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

    struct ChannelOutput {
        var segments: [TranscriptSegment]
        var centroids: [String: [Float]]
    }

    /// The production offline path for one channel: 900 s blocks via
    /// `ArchiveBlockReader`, Whisper `.full` per block, block diarization
    /// alongside, merge by speaker at the end. Internal (not private) so
    /// the benchmark runner in DaisyTests measures THIS, not a
    /// whole-file shortcut that never ships.
    func transcribeChannel(
        _ urls: [URL],
        source: SegmentSource,
        language: String?,
        totalSec: Double? = nil,
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
            // Progress for the sheet: a two-hour lecture behind a bare
            // spinner reads as hung (Egor, 2026-09-18). Minutes reached
            // of minutes total; the block reader knows only offsets, so
            // the total comes from the session's own duration.
            if let totalSec, totalSec > 0 {
                let base = source == .microphone
                    ? String(localized: "Transcribing microphone audio")
                    : String(localized: "Transcribing system audio")
                // Reached = end of the block being decoded, capped at the total.
                let reachedSec = min(block.startSec + Double(block.samples.count) / Double(ArchiveBlockReader.sampleRate), totalSec)
                statusText = String(
                    format: String(localized: "%@ — %d of %d min"),
                    base, Int((reachedSec / 60).rounded(.up)), Int((totalSec / 60).rounded(.up))
                )
            }
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
                biasTerms: biasTerms,
                onProgress: { [weak self] inBlock in
                    guard let self, let totalSec, totalSec > 0 else { return }
                    let blockSec = Double(block.samples.count) / Double(ArchiveBlockReader.sampleRate)
                    let inChannel = min(1, (block.startSec + inBlock * blockSec) / totalSec)
                    let overall = self.progressSpan.from + (self.progressSpan.to - self.progressSpan.from) * inChannel
                    // Never backwards: a rounding step at a block seam
                    // must not make the bar flicker.
                    self.progress = max(self.progress ?? 0, overall)
                }
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

    /// One frontmatter value by the contract's parse rule (§3.1): first
    /// `:`, trimmed, surrounding quotes stripped. Enough for a marker key.
    nonisolated static func frontmatterValue(_ key: String, in markdown: String) -> String? {
        var inside = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "---" {
                if inside { return nil }
                inside = true
                continue
            }
            guard inside, let colon = line.firstIndex(of: ":") else { continue }
            guard line[..<colon] == key[...] else { continue }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            return value
        }
        return nil
    }

    nonisolated static func derivedSessionID(parentID: String, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "\(parentID)-retranscribed-\(formatter.string(from: now))"
    }

    /// Why a final pass must not replace a live transcript, or nil when
    /// it may: it found no words where the live text had some, or kept
    /// less than half of a live text long enough for the ratio to mean
    /// something. The final pass legitimately shrinks a live text —
    /// echo and loops go — but not by half.
    nonisolated static func reasonToKeepLiveTranscript(liveWords: Int, finalWords: Int) -> String? {
        if finalWords == 0, liveWords > 0 {
            return "the final pass found no speech; the live text has \(liveWords) words"
        }
        if liveWords >= 20, finalWords * 2 < liveWords {
            return "the final pass kept \(finalWords) words of the live text's \(liveWords)"
        }
        return nil
    }

    /// Words said in a transcript.md: the lines under `## Transcript`,
    /// without the `**[m:ss · Name]**` stamps and without italic notes
    /// such as «No speech detected.».
    nonisolated static func spokenWordCount(inTranscriptMarkdown markdown: String) -> Int {
        var inTranscript = false
        var count = 0
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                inTranscript = line == "## Transcript"
                continue
            }
            guard inTranscript, !line.isEmpty, !line.hasPrefix("_") else { continue }
            var text = line
            while let open = text.range(of: "**["), let close = text.range(of: "]**", range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            }
            count += spokenWordCount(in: text)
        }
        return count
    }

    nonisolated static func spokenWordCount(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace)
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
            .count
    }

    static func renderDerivedTranscript(
        originalMarkdown: String,
        session: StoredSession,
        options: SessionRetranscriptionOptions,
        segments: [TranscriptSegment],
        audioFiles: [String],
        isFirstTranscript: Bool = false,
        speakerMap: [String: String] = [:]
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
        markdown = SessionStore.upsertFrontmatter(in: markdown, key: "daisy_speaker_map", value: SessionStore.encodeYAMLDict(speakerMap))
        let encodedAudio = audioFiles.map(yamlQuote).joined(separator: ", ")
        markdown = SessionStore.upsertFrontmatter(in: markdown, key: "daisy_audio_files", value: "[\(encodedAudio)]")
        return markdown
    }

    /// The parent's names (its map, its `speakers.json`) moved onto
    /// `centroids` — this pass's clusters under their final labels.
    nonisolated static func namesFromParent(originalMarkdown: String, directory: URL,
                                            to centroids: [String: [Float]]) -> [String: String] {
        guard let raw = frontmatterValue("daisy_speaker_map", in: originalMarkdown) else { return [:] }
        let names = parseYAMLDict(raw)
        guard !names.isEmpty,
              let data = try? Data(contentsOf: directory.appendingPathComponent("speakers.json")),
              let parent = try? JSONDecoder().decode(SpeakerCentroidsFile.self, from: data) else { return [:] }
        return SpeakerAttribution.carryNames(names, from: parent.centroids, to: centroids)
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
        to sessionDirectory: URL,
        replacing: Bool = false
    ) throws {
        let fm = FileManager.default
        let stagedTranscript = stagingDirectory.appendingPathComponent("transcript.md")
        let transcript = sessionDirectory.appendingPathComponent("transcript.md")
        if replacing, fm.fileExists(atPath: transcript.path) {
            _ = try fm.replaceItemAt(transcript, withItemAt: stagedTranscript)
        } else {
            guard !fm.fileExists(atPath: transcript.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try fm.moveItem(at: stagedTranscript, to: transcript)
        }

        let stagedSpeakers = stagingDirectory.appendingPathComponent("speakers.json")
        if fm.fileExists(atPath: stagedSpeakers.path) {
            let speakers = sessionDirectory.appendingPathComponent("speakers.json")
            if fm.fileExists(atPath: speakers.path) {
                _ = try? fm.replaceItemAt(speakers, withItemAt: stagedSpeakers)
            } else {
                try? fm.moveItem(at: stagedSpeakers, to: speakers)
            }
        }

        let stagedRaw = stagingDirectory.appendingPathComponent("transcript.raw.md")
        if fm.fileExists(atPath: stagedRaw.path) {
            let raw = sessionDirectory.appendingPathComponent("transcript.raw.md")
            if fm.fileExists(atPath: raw.path) {
                _ = try? fm.replaceItemAt(raw, withItemAt: stagedRaw)
            } else {
                try? fm.moveItem(at: stagedRaw, to: raw)
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
