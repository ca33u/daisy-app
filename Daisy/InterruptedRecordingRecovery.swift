//
//  InterruptedRecordingRecovery.swift
//  Daisy
//
//  Recovers a meeting recording interrupted by a crash, power loss, or
//  force-quit: the `.caf` audio is on disk but `transcript.md` was never
//  written (it's produced only at Stop). `SessionStore` keeps the folder
//  visible, classifies it as `.interrupted`, and hands it here for a
//  best-effort transcript.
//
//  Best-effort BY DESIGN. The hard safety guarantee lives in SessionStore
//  (never delete a recoverable folder); this layer only adds the nice-to-
//  have of auto-transcribing it. So on ANY failure we leave the folder and
//  its `.recording` marker untouched — the audio is preserved on disk and
//  recovery is retried on the next scan. We never delete anything here.
//
//  Output is a basic transcript (mic + system as two sections, no speaker
//  diarization or LLM summary — the live finalize state is gone). Reuses
//  the proven decode + transcribe path the Voice Memos importer used
//  (removed 24.09 — Voice Memos come in through Daisy for iPhone now).
//

import Foundation
import os

@MainActor
final class InterruptedRecordingRecovery {
    static let shared = InterruptedRecordingRecovery()

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Recovery")
    /// Folders already picked up this launch — keeps repeated `refresh()`
    /// calls from double-processing while a recovery is in flight.
    private var seen: Set<String> = []

    private init() {}

    /// Kick off best-effort recovery for each interrupted folder. Idempotent.
    func recover(_ folders: [URL]) {
        for folder in folders {
            let key = folder.path
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            Task { @MainActor in await self.recoverOne(folder) }
        }
    }

    private func recoverOne(_ folder: URL) async {
        // Hold the sessions-folder security scope for the whole pass.
        // The tickets `SessionStore.performRefresh` acquired are released
        // by the time this detached recovery runs, so for sessions in a
        // user-picked folder (Obsidian vault) every read of the .caf and
        // the transcript.md write below would fail without our own scope
        // — recovery then silently no-ops and re-toasts every launch.
        guard let ticket = SessionsFolder.acquireBase() else {
            log.error("Recovery: could not acquire sessions folder access — will retry next scan")
            seen.remove(folder.path)
            return
        }
        defer { ticket.release() }

        let started = Date()
        let micCafs = Self.cafParts(in: folder, prefix: "microphone")
        let systemCafs = Self.cafParts(in: folder, prefix: "system_audio")
        guard !micCafs.isEmpty || !systemCafs.isEmpty else {
            log.warning("Recovery: no .caf in \(folder.lastPathComponent, privacy: .public) — skipping")
            return
        }

        ToastCenter.shared.show(String(localized: "Recovering an unfinished recording…"), style: .info)

        let language = WhisperLocale.language(
            from: UserDefaults.standard.string(forKey: "daisy.defaultTranscriptionLocale") ?? "auto"
        )

        // Dictations held during the recording stay out of its mic text
        // (`DictationHolds`); the other side is never cut.
        let mic = await transcribeChannel(micCafs, language: language,
                                          cutting: DictationHoldStore.load(from: folder))
        let system = await transcribeChannel(systemCafs, language: language)

        // Decode/transcribe failed for both → leave everything in place
        // (audio preserved); a later launch retries.
        guard mic != nil || system != nil else {
            log.error("Recovery: decode/transcribe failed for \(folder.lastPathComponent, privacy: .public) — left intact")
            ToastCenter.shared.show(
                String(localized: "Couldn't auto-transcribe a recovered recording — the audio is kept; open the folder to re-process it."),
                style: .warning
            )
            return
        }

        let marker = Self.marker(in: folder)
        let startDate = marker.startedAt ?? Self.folderDate(folder)
        let durationSec = max(mic?.durationSec ?? 0, system?.durationSec ?? 0)
        let markdown = Self.renderMarkdown(
            startDate: startDate,
            durationSec: durationSec,
            isVoiceNote: marker.isVoiceNote,
            // As the live path files a voice note: the default notes
            // project, when it still exists (`RecordingSession.start`).
            noteFolderSlug: marker.isVoiceNote
                ? FolderStore.shared.existingFolder(slug: FolderStore.shared.defaultNoteFolderSlug)?.slug
                : nil,
            mic: mic?.text,
            system: system?.text,
            markers: MomentMarkerStore.markdownSection(
                for: folder,
                heading: String(localized: "Marked moments")
            )
        )

        do {
            try await Task.detached(priority: .utility) {
                try Data(markdown.utf8).write(
                    to: folder.appendingPathComponent("transcript.md"),
                    options: .atomic
                )
            }.value
            // transcript.md exists now → drop the marker; folder is .valid.
            try? FileManager.default.removeItem(
                at: folder.appendingPathComponent(SessionStore.recordingMarkerName)
            )
            log.info("Recovered \(folder.lastPathComponent, privacy: .public) in \(Date().timeIntervalSince(started), privacy: .public)s")
            ToastCenter.shared.show(String(localized: "Recovered your unfinished recording."), style: .success)
            await SessionStore.shared.refresh()
        } catch {
            // Write failed → leave the audio + marker so the next scan retries.
            log.error("Recovery: writing transcript.md failed for \(folder.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public) — audio preserved")
        }
    }

    // MARK: - Per-channel decode + transcribe (heavy decode off the main actor)

    private struct ChannelResult { let text: String; let durationSec: Double }

    private func transcribeChannel(_ urls: [URL], language: String?, cutting holds: [DictationHold] = []) async -> ChannelResult? {
        guard !urls.isEmpty else { return nil }
        let samples = await Task.detached(priority: .utility) {
            AudioArchiveDecoder.decodeToMono16k(urls: urls)
        }.value
        guard let samples, !samples.isEmpty else { return nil }
        do {
            let segments = try await WhisperEngine.shared.transcribe(
                samples: samples, language: language, profile: .full
            )
            // One decode of the whole archive: its seconds are the
            // recording's media clock, the one the holds are on.
            let spans = DictationHoldCut.merged(holds, margin: DictationHoldCut.margin)
            let text = segments
                .filter { spans.isEmpty || !DictationHoldCut.isCut(start: $0.start, end: $0.end, by: spans) }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return ChannelResult(text: text, durationSec: Double(samples.count) / 16_000.0)
        } catch {
            log.error("Recovery: Whisper failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Pure helpers

    /// Ordered `.caf` parts for a channel (`microphone`, `system_audio`).
    /// Base sorts before `.part2.caf` etc. alphabetically.
    nonisolated private static func cafParts(in folder: URL, prefix: String) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .filter { $0.pathExtension == "caf" && $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// What the `.recording` marker says (`RecordingMarker`): the start,
    /// and whether it was a voice note. Unreadable reads as a meeting with
    /// no start.
    nonisolated private static func marker(in folder: URL) -> RecordingMarker.Contents {
        let url = folder.appendingPathComponent(SessionStore.recordingMarkerName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return RecordingMarker.Contents(startedAt: nil, isVoiceNote: false)
        }
        return RecordingMarker.parse(text)
    }

    /// The folder's creation/modification date, when the marker has no start.
    nonisolated private static func folderDate(_ folder: URL) -> Date {
        let vals = try? folder.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return vals?.creationDate ?? vals?.contentModificationDate ?? Date()
    }

    /// Obsidian-shaped transcript.md with the minimum frontmatter
    /// (`title` + `started`) that makes SessionStore classify it `.valid`.
    /// A voice note (its marker said so, 07.11) comes back as one — a note
    /// with its key, in the default notes project — so its summary waits
    /// behind the voice-note gate like any voice note's, rather than going
    /// out as a meeting's to whatever provider is chosen.
    nonisolated static func renderMarkdown(
        startDate: Date,
        durationSec: Double,
        isVoiceNote: Bool = false,
        noteFolderSlug: String? = nil,
        mic: String?,
        system: String?,
        markers: String = ""
    ) -> String {
        let iso = ISO8601DateFormatter()
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let titleDate = df.string(from: startDate)

        let heading = isVoiceNote ? "Recovered voice note — \(titleDate)" : "Recovered recording — \(titleDate)"
        var lines: [String] = []
        lines.append("---")
        lines.append("title: \"\(heading)\"")
        lines.append("started: \(iso.string(from: startDate))")
        lines.append("daisy_recovered: true")
        // A recovered meeting is a full recording — stamped so it lands in
        // the Library tab (matches the legacy inference: recoveries never
        // used the Notes folder). A recovered voice note is a note with
        // its key (session-format.md §3.4, §3.5).
        if isVoiceNote {
            lines.append(contentsOf: MarkdownExporter.kindLines(kind: .note, isVoiceNote: true))
        } else {
            lines.append("daisy_kind: \(SessionKind.recording.rawValue)")
        }
        lines.append("duration_sec: \(Int(durationSec.rounded()))")
        let folderSlug = isVoiceNote
            ? noteFolderSlug ?? ""
            : UserDefaults.standard.string(forKey: "daisy.defaultMeetingFolderSlug") ?? ""
        if !folderSlug.isEmpty, !(isVoiceNote && folderSlug == SessionFolder.inbox.slug) {
            lines.append("daisy_folder: \(folderSlug)")
        }
        lines.append("---")
        lines.append("")
        lines.append("# \(heading)")
        lines.append("")
        lines.append("> " + String(localized: "Recovered after an interrupted session (crash or power loss). Basic transcript — no speaker labels or summary. The audio is in this folder if you want to re-process it."))
        lines.append("")
        // The markers survived the crash in `markers.json`; nothing else
        // here could reconstruct them, and they are the only part of
        // this recording that carries the user's own judgement.
        if !markers.isEmpty {
            lines.append(markers)
        }

        let micText = mic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sysText = system?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !micText.isEmpty {
            lines.append("## " + String(localized: "Your side"))
            lines.append("")
            lines.append(micText)
            lines.append("")
        }
        if !sysText.isEmpty {
            lines.append("## " + String(localized: "Other side"))
            lines.append("")
            lines.append(sysText)
            lines.append("")
        }
        if micText.isEmpty, sysText.isEmpty {
            lines.append("_" + String(localized: "No speech detected in the recovered audio.") + "_")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

/// The transcription locale setting as the two-letter code Whisper takes;
/// nil for "auto". (Was `VoiceMemoScanner.whisperLanguage`, kept when the
/// Voice Memos importer went, 24.09.)
nonisolated enum WhisperLocale {
    static func language(from locale: String) -> String? {
        let l = locale.lowercased()
        if l.isEmpty || l == "auto" { return nil }
        let two = l.prefix(2)
        return two.isEmpty ? nil : String(two)
    }
}

/// The `.recording` marker's contents (session-format.md §6.1). Line one
/// is the ISO-8601 start instant, as it always was; a voice note adds
/// `mode: voiceNote` on a line of its own (07.11), so crash recovery can
/// write it back as a voice note. A meeting's marker is unchanged, byte
/// for byte, and a marker written before is read as a meeting.
nonisolated enum RecordingMarker {
    struct Contents: Equatable, Sendable {
        var startedAt: Date?
        var isVoiceNote: Bool
    }

    static let voiceNoteLine = "mode: voiceNote"

    static func contents(startedAt: Date, isVoiceNote: Bool) -> String {
        let start = ISO8601DateFormatter().string(from: startedAt)
        return isVoiceNote ? start + "\n" + voiceNoteLine + "\n" : start
    }

    static func parse(_ text: String) -> Contents {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let start = lines.first.flatMap { ISO8601DateFormatter().date(from: $0) }
        return Contents(startedAt: start, isVoiceNote: lines.dropFirst().contains(voiceNoteLine))
    }
}
