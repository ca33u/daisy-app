//
//  QuitFinalizeRecovery.swift
//  Daisy
//
//  Finishes the post-stop pipeline for sessions saved by Quit / shutdown
//  DURING recording. `stop()` flushes the live transcript synchronously,
//  but the detached `finalizePostStop` (full-archive Whisper pass +
//  summary) dies with the process — the folder classifies `.valid`, yet
//  the transcript is live-quality (holes on long recordings, see the
//  1.0.7.17 truncation class) and there's no summary. The still-present
//  `.recording` marker is the tell: finalize Stage 3b removes it on a
//  clean run, so `.valid` + marker ⇒ the final pass never happened.
//
//  Policy (2026-07-20):
//    • Fast quit stays fast; this recovery is the single mechanism — it
//      also covers shutdown (`willPowerOff` can't delay the process) and
//      crash-after-transcript-write.
//    • Never silent: the user gets an action toast, nothing runs on its
//      own (a full Whisper pass takes minutes and would otherwise stall
//      live transcription — the recovery-vs-live Whisper-slot contention
//      class).
//    • Only UNTOUCHED transcripts are rewritten. If transcript.md's
//      mtime is later than the audio's (user edited it in Obsidian /
//      an editor), we leave the file alone; the marker stays, which
//      also keeps the retention sweep from purging the audio, so a
//      future manual "re-process" UI still has the raw material.
//
//  Like InterruptedRecordingRecovery: best-effort, never deletes, any
//  failure leaves folder + marker in place so the next launch retries.
//

import Foundation
import os

@MainActor
final class QuitFinalizeRecovery {
    static let shared = QuitFinalizeRecovery()

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "QuitFinalize")
    /// Folders already offered/processed this launch — repeated
    /// `refresh()` calls must not stack toasts or double-process.
    private var seen: Set<String> = []
    private var running = false

    private init() {}

    /// Editing-detection slack. Quit-save writes transcript.md within
    /// moments of the last audio write; a user edit happens minutes-to-
    /// days later. 3 minutes absorbs a slow flush without misreading a
    /// real edit as "untouched".
    nonisolated private static let untouchedSlack: TimeInterval = 180

    /// Called from `SessionStore.performRefresh` with `.valid` folders
    /// that still carry the `.recording` marker (live session excluded
    /// by the caller). Idempotent per launch.
    func offer(_ folders: [URL]) {
        for folder in folders {
            let key = folder.path
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            guard Self.transcriptUntouched(in: folder) else {
                log.info("Quit-finalize: transcript in \(folder.lastPathComponent, privacy: .public) was edited after save — leaving as-is (marker kept, audio preserved)")
                continue
            }
            ToastCenter.shared.showAction(
                String(localized: "A recording was saved without its final processing pass."),
                actionLabel: String(localized: "Process now"),
                style: .info,
                duration: .seconds(12)
            ) { [weak self] in
                guard let self else { return }
                Task { @MainActor in await self.reprocess(folder) }
            }
        }
    }

    // MARK: - Re-process one folder

    private func reprocess(_ folder: URL) async {
        // Never fight the live pipeline for the Whisper slot — a full
        // pass over a long archive would stall live windows and the
        // dictation paste for minutes.
        guard SessionStore.shared.liveRecordingDirNames.isEmpty else {
            seen.remove(folder.path)   // re-offer on a later refresh
            ToastCenter.shared.show(
                String(localized: "Finish the current recording first — I'll offer again after."),
                style: .warning
            )
            return
        }
        guard !running else { return }
        running = true
        defer { running = false }

        // Hold the security scope for the whole pass — the session may
        // live in a user-picked folder (Obsidian vault), where reads and
        // writes fail without it.
        guard let ticket = SessionsFolder.acquireBase() else {
            log.error("Quit-finalize: could not acquire sessions folder access")
            return
        }
        defer { ticket.release() }

        let started = Date()
        let micCafs = Self.cafParts(in: folder, prefix: "microphone")
        let systemCafs = Self.cafParts(in: folder, prefix: "system_audio")
        guard !micCafs.isEmpty || !systemCafs.isEmpty else {
            // No audio to improve on — the live transcript is the best
            // we'll ever have. Drop the marker so we stop offering.
            try? FileManager.default.removeItem(
                at: folder.appendingPathComponent(SessionStore.recordingMarkerName)
            )
            return
        }

        ToastCenter.shared.show(
            String(localized: "Re-processing the recording — this can take a few minutes…"),
            style: .info
        )

        let language = WhisperLocale.language(
            from: UserDefaults.standard.string(forKey: "daisy.defaultTranscriptionLocale") ?? "auto"
        )
        let mic = await transcribeChannel(micCafs, language: language)
        let system = await transcribeChannel(systemCafs, language: language)
        guard mic != nil || system != nil else {
            log.error("Quit-finalize: decode/transcribe failed for \(folder.lastPathComponent, privacy: .public) — left intact")
            ToastCenter.shared.show(
                String(localized: "Couldn't re-process that recording — the audio is kept for another try."),
                style: .warning
            )
            return
        }

        // Re-check the edit guard — the pass takes minutes and the user
        // may have opened the file meanwhile. Never clobber an edit.
        guard Self.transcriptUntouched(in: folder) else {
            log.info("Quit-finalize: transcript edited during re-process — keeping the user's version")
            return
        }

        let transcriptURL = folder.appendingPathComponent("transcript.md")
        let original = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
        let updated = Self.replaceBody(
            in: original,
            with: Self.renderBody(
                mic: mic?.text,
                system: system?.text,
                markers: MomentMarkerStore.markdownSection(
                    for: folder,
                    heading: String(localized: "Marked moments")
                )
            )
        )
        do {
            try await Task.detached(priority: .utility) {
                try Data(updated.utf8).write(to: transcriptURL, options: .atomic)
            }.value
        } catch {
            log.error("Quit-finalize: writing transcript.md failed: \(error.localizedDescription, privacy: .public) — audio preserved")
            return
        }

        // Final pass done → drop the marker (mirrors finalize Stage 3b).
        try? FileManager.default.removeItem(
            at: folder.appendingPathComponent(SessionStore.recordingMarkerName)
        )
        await SessionStore.shared.refresh()
        log.info("Quit-finalize: re-processed \(folder.lastPathComponent, privacy: .public) in \(Int(Date().timeIntervalSince(started)), privacy: .public)s")

        // Summary — only if the user has auto-summarize on, the session
        // doesn't already have one, and a provider is configured (a
        // throw here is non-fatal; the transcript work above stands).
        let autoSummarize = UserDefaults.standard.object(forKey: "daisy.autoSummarize") as? Bool ?? false
        let hasSummary = FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("summary.json").path
        )
        if autoSummarize, !hasSummary,
           let session = SessionStore.shared.sessions.first(where: {
               $0.directoryURL.lastPathComponent == folder.lastPathComponent
           }) {
            let text = [mic?.text, system?.text].compactMap { $0 }.joined(separator: "\n\n")
            if let summary = try? await Summarizer.shared.runProbe(
                transcript: text, title: session.title, localeHint: nil
            ) {
                await SessionStore.shared.updateSummary(summary, for: session)
            }
        }
        ToastCenter.shared.show(
            String(localized: "Recording re-processed — transcript is now complete."),
            style: .success
        )
    }

    // MARK: - Per-channel decode + transcribe (heavy work off the main actor)

    private struct ChannelResult { let text: String; let durationSec: Double }

    private func transcribeChannel(_ urls: [URL], language: String?) async -> ChannelResult? {
        guard !urls.isEmpty else { return nil }
        let samples = await Task.detached(priority: .utility) {
            AudioArchiveDecoder.decodeToMono16k(urls: urls)
        }.value
        guard let samples, !samples.isEmpty else { return nil }
        do {
            let segments = try await WhisperEngine.shared.transcribe(
                samples: samples, language: language, profile: .full
            )
            let text = segments
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return ChannelResult(text: text, durationSec: Double(samples.count) / 16_000.0)
        } catch {
            log.error("Quit-finalize: Whisper failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Pure helpers

    /// True when transcript.md doesn't look hand-edited: its mtime is
    /// within `untouchedSlack` of the newest audio file's mtime.
    nonisolated static func transcriptUntouched(in folder: URL) -> Bool {
        let fm = FileManager.default
        let transcriptURL = folder.appendingPathComponent("transcript.md")
        guard let tMtime = (try? fm.attributesOfItem(atPath: transcriptURL.path))?[.modificationDate] as? Date else {
            return false
        }
        let audioMtimes = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "caf" }
            .compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
            ?? []
        guard let newestAudio = audioMtimes.max() else {
            // No audio mtime to compare against — be conservative.
            return false
        }
        return tMtime.timeIntervalSince(newestAudio) <= untouchedSlack
    }

    /// Ordered `.caf` parts for a channel (`microphone`, `system_audio`).
    nonisolated private static func cafParts(in folder: URL, prefix: String) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .filter { $0.pathExtension == "caf" && $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Keep the frontmatter block and the `# Title` heading verbatim;
    /// swap everything after them for the re-transcribed content. The
    /// frontmatter carries identity (title / started / folder slug) the
    /// store parses — it must survive byte-for-byte.
    nonisolated static func replaceBody(in original: String, with body: String) -> String {
        guard original.hasPrefix("---"),
              let close = original.range(of: "\n---\n") else {
            return body
        }
        let head = String(original[..<close.upperBound])
        let rest = String(original[close.upperBound...])
        var headingLine = ""
        for line in rest.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("# ") { headingLine = String(line) + "\n\n"; break }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { break }
        }
        return head + "\n" + headingLine + body
    }

    /// Body markdown: complete re-transcription, mic and system as two
    /// sections. No speaker labels — the live diarization state died
    /// with the process; a labeled version would need the offline
    /// diarizer, which is future work.
    nonisolated private static func renderBody(mic: String?, system: String?, markers: String = "") -> String {
        var lines: [String] = []
        lines.append("> " + String(localized: "Re-processed from the full audio archive after the app quit mid-recording. Complete transcript — no speaker labels."))
        lines.append("")
        // Re-rendering the body would otherwise drop the moments the
        // user marked before the quit — the one part of this file that
        // wasn't recoverable from the audio.
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
            lines.append("_" + String(localized: "No speech detected in the archived audio.") + "_")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
