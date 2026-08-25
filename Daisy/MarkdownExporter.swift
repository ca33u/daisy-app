//
//  MarkdownExporter.swift
//  Daisy
//
//  Renders a RecordingSession to Obsidian-friendly markdown and writes it
//  to a user-chosen location. Remembers the last-used folder via a
//  security-scoped bookmark so the save panel opens there next time.
//

import Foundation
import AppKit
import UniformTypeIdentifiers
import os

enum MarkdownExporter {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "Exporter")
    private static let lastFolderBookmarkKey = "daisy.lastExportFolderBookmark"

    // MARK: - Render

    static func renderMarkdown(session: RecordingSession, includeFrontmatter: Bool = true) -> String {
        var lines: [String] = []
        if includeFrontmatter {
            lines.append(contentsOf: frontmatterLines(session: session))
            lines.append("")
        }
        renderBody(session: session, into: &lines)
        return lines.joined(separator: "\n")
    }

    /// YAML frontmatter block (`---` … `---`). Split out of
    /// `renderMarkdown` in 1.0.7.19 so clipboard copies can skip it:
    /// pasted into Slack / Gmail / Claude the vault metadata is pure
    /// noise, and the rich-HTML clipboard flavor (MarkdownClipboard)
    /// would render it as paragraph soup. The on-disk transcript.md
    /// and the Save-panel export keep `includeFrontmatter: true`.
    private static func frontmatterLines(session: RecordingSession) -> [String] {
        var lines: [String] = []
        lines.append("---")
        lines.append("title: \(yamlQuote(session.title))")
        lines.append("type: meeting-transcript")
        lines.append("source: Daisy")
        lines.append("locale: \(session.localeIdentifier)")
        if let started = session.startedAt {
            lines.append("started: \(iso(started))")
        }
        lines.append("duration_sec: \(Int(session.elapsed))")
        lines.append("daisy_folder: \(session.folder.slug)")
        // Note vs recording — decoupled from the folder so both kinds can
        // live in any project. Read back by SessionStore.parseSession to
        // route the session into the Library (recording) or Notes (note)
        // tab. See RecordingSession.sessionKind / SessionKind.
        lines.append("daisy_kind: \(session.sessionKind.rawValue)")
        // Free-form tag — empty when untagged. History sidebar
        // selector groups by this value. Renamed from `daisy_client`
        // in 1.0.5.2; parser still reads the legacy key for older
        // sessions and replaces with the new key on next edit.
        if !session.tag.isEmpty {
            lines.append("daisy_tag: \(yamlQuote(session.tag))")
        }
        if let meeting = session.boundMeeting {
            // Bind transcript ↔ calendar event so future search can
            // resolve "show me the transcript of that Q3 review".
            // Both ids are persisted: external survives provider re-
            // sync, local is the runtime-resolvable handle.
            if let ext = meeting.externalID {
                lines.append("daisy_event_external_id: \(yamlQuote(ext))")
            }
            lines.append("daisy_event_local_id: \(yamlQuote(meeting.localID))")
            lines.append("daisy_event_title: \(yamlQuote(meeting.title))")
            lines.append("daisy_event_start: \(iso(meeting.startDate))")
            if let platform = meeting.meetingPlatform {
                lines.append("daisy_event_platform: \(platform)")
            }
            // Attendees from the EKEvent — powers the
            // "Speaker A → Alex" mapping UI in SessionDetailView.
            if !meeting.attendees.isEmpty {
                let quoted = meeting.attendees.map(yamlQuote).joined(separator: ", ")
                lines.append("daisy_event_attendees: [\(quoted)]")
            }
            // Attendee emails (1.0.7.10) — persisted so the post-stop
            // speaker-match pass and the SessionDetailView rename flow
            // can intersect them against SpeakerProfile.emails to
            // identify a speaker by their calendar invite, in addition
            // to the voice fingerprint. Separate key from the display
            // names because they're a different cardinality + identity
            // (an email is a stable key, a display name is fuzzy).
            // Already lowercased/deduped by CalendarService.
            if !meeting.attendeeEmails.isEmpty {
                let quoted = meeting.attendeeEmails.map(yamlQuote).joined(separator: ", ")
                lines.append("daisy_event_emails: [\(quoted)]")
            }
        }
        // daisy_speaker_map — always written when there's diarization
        // available (regardless of calendar binding). Pre-populated
        // with auto-matched profile names ("Alex" / "Mom") when the
        // SpeakerProfileStore recognized this session's clusters
        // from prior recordings; empty {} otherwise so the
        // SessionDetailView edit path still has somewhere to write.
        if !session.initialSpeakerMap.isEmpty {
            lines.append("daisy_speaker_map: \(yamlInlineDict(session.initialSpeakerMap))")
        } else {
            lines.append("daisy_speaker_map: {}")
        }
        // When a mic route change mid-session forced a format
        // rollover (see AudioRecorder.handleConfigurationChange),
        // the archive is split across `microphone.caf` plus
        // `microphone.part2.caf` (etc) instead of one continuous
        // file. Surface the part list here so the user (and any
        // downstream tooling reading the frontmatter) knows where
        // to find the full audio. Only emit the key when there's
        // actually more than one part — the common case is one
        // file and the frontmatter stays clean.
        let archivedParts = session.archivedAudioParts
        if archivedParts.count > 1 {
            let parts = archivedParts
                .map { yamlQuote($0.lastPathComponent) }
                .joined(separator: ", ")
            lines.append("daisy_audio_parts: [\(parts)]")
        }

        // Persistent audit of per-stream capture outcome. Four states
        // surface support-side debugging (1.0.7.1):
        //   off       — toggle disabled (or stream not applicable to mode)
        //   captured  — frames arrived AND landed on disk above floor
        //   empty     — armed but zero frames ever arrived (BT output,
        //               denied Screen Recording, SCKit Tahoe regression)
        //   truncated — frames arrived but disk write died silently
        //               (the 2026-05-25 Billions failure mode); user
        //               also got a loud toast at stop time. Frontmatter
        //               line includes byte/frame counts in parens so
        //               support can spot patterns without opening logs.
        // Pre-1.0.7.1 only the first three existed and `captured` was
        // derived from `hasCapturedSystemAudio` (== hasReceivedAudio in
        // memory). That flag flips true on the first SCK callback
        // regardless of whether AVAudioFile.write succeeded — so
        // sessions where every frame's write threw still stamped
        // `captured`. Now both streams use ArchiveStatus, which
        // cross-checks frames-written + on-disk byte count.
        // Mic line is new in 1.0.7.1 too — the Billions test caught
        // mic.caf truncated to 5% of session length with no signal
        // anywhere; symmetric audit prevents that class of silent loss.
        func archiveLabel(_ status: RecordingSession.ArchiveStatus) -> String {
            switch status {
            case .off: return "off"
            case .empty: return "empty"
            case .captured(let bytes):
                return "captured (\(bytes) B)"
            case .truncated(let bytes, let framesWritten, let writeErrors):
                return "truncated (\(bytes) B on disk, \(framesWritten) frames written, \(writeErrors) write errors)"
            }
        }
        lines.append("daisy_system_audio_status: \(archiveLabel(session.systemAudioArchiveStatus))")
        lines.append("daisy_mic_audio_status: \(archiveLabel(session.micAudioArchiveStatus))")
        // WHY the other side is missing, when we know — permission was
        // off, or the stream refused to start / resume. The archive
        // statuses above record the SYMPTOM (`empty`), which reads the
        // same for a Bluetooth output route, DRM-protected playback, and
        // a revoked Screen Recording grant; only this line separates the
        // one the user can fix from the ones they can't. Absent for a
        // healthy meeting and for every dictation / voice note.
        if let micOnly = session.micOnlyCause {
            lines.append("daisy_mic_only: \(micOnly.rawValue)")
        }
        lines.append("tags: [meeting, transcript, daisy]")
        lines.append("---")
        return lines
    }

    /// Document body — `# title`, recorded-quote, summary, screenshots,
    /// transcript. Shared tail of both flavors (with / without
    /// frontmatter).
    private static func renderBody(session: RecordingSession, into lines: inout [String]) {
        lines.append("# \(session.title)")
        lines.append("")

        if let started = session.startedAt {
            lines.append("> recorded \(humanDate(started)) · \(formatDuration(session.elapsed))")
            lines.append("")
        }

        // AI summary, if available. Lede + Granola-style topical
        // outline + flat next-actions checklist + optional follow-up
        // draft for the client / partner. Legacy summaries (pre-
        // 1.0.2) have `sections == []`, in which case the lede
        // carries the full paragraph and the outline block is
        // skipped — preserves the old layout exactly for sessions
        // saved on the previous schema.
        if let summary = session.summarizer.lastSummary {
            // Detect summary language from its content for the
            // structural H3 headers, so a Russian summary saved as
            // transcript.md uses "## Сводка / ### Встреча / ###
            // Следующие шаги" rather than English headers stamped
            // on top of Russian content. The "## Summary" wrapper
            // also follows.
            var sample = summary.summary
            if sample.count < 60, let firstBullet = summary.sections.first?.bullets.first?.text {
                sample += " " + firstBullet
            }
            let labels = SummaryLabels.for(language: LanguageDetector.detect(sample))
            let summaryHeader: String = {
                switch (LanguageDetector.detect(sample) ?? "").lowercased() {
                case "ru": return "Сводка"
                case "uk": return "Зведення"
                case "pl": return "Podsumowanie"
                case "es": return "Resumen"
                case "fr": return "Résumé"
                case "de": return "Zusammenfassung"
                case "it": return "Riepilogo"
                case "pt": return "Resumo"
                case "ja": return "サマリー"
                case "ko": return "요약"
                case "zh": return "摘要"
                default:   return "Summary"
                }
            }()
            lines.append("## \(summaryHeader)")
            lines.append("")
            if !summary.summary.isEmpty {
                lines.append("### \(labels.meeting)")
                lines.append("")
                lines.append(summary.summary)
                lines.append("")
            }
            for section in summary.sections {
                lines.append("### \(section.title)")
                lines.append("")
                appendBullets(section.bullets, level: 0, into: &lines)
                lines.append("")
            }
            if !summary.actionItems.isEmpty {
                lines.append("### \(labels.nextActions)")
                lines.append("")
                for item in summary.actionItems {
                    lines.append("- [ ] \(item)")
                }
                lines.append("")
            }
            if !summary.clientFollowUp.isEmpty {
                lines.append("### \(labels.followUp)")
                lines.append("")
                lines.append(summary.clientFollowUp)
                lines.append("")
            }
        }

        // Screenshots gallery, if any.
        let shots = session.screenshots.screenshotURLs
        if !shots.isEmpty {
            lines.append("## Screenshots")
            lines.append("")
            // Alt text carries the timecode so the gallery is navigable
            // against the transcript below it — the two share an origin.
            // Falls back to the filename for sessions with no index.
            let shotOffsets = shots.first.map {
                ScreenshotIndex.load(from: $0.deletingLastPathComponent())
            } ?? [:]
            for url in shots {
                let caption = ScreenshotIndex.timecode(for: url, offsets: shotOffsets)
                    ?? url.lastPathComponent
                lines.append("![\(caption)](\(url.path))")
                lines.append("")
            }
        }

        // Moments the user marked while recording. Above the transcript
        // and below the summary on purpose: this is the one section
        // nobody inferred — the person who was in the room said these
        // minutes mattered. Timecodes match the transcript's, so the
        // list reads as an index into it.
        let markers = session.momentMarkers
        if !markers.isEmpty {
            lines.append("## Marked moments")
            lines.append("")
            let shotsDir = session.sessionDirectory?
                .appendingPathComponent("screenshots", isDirectory: true)
            for marker in markers {
                if let frame = marker.screenshot,
                   let url = shotsDir?.appendingPathComponent(frame) {
                    lines.append("- **[\(marker.timecode)]** — ![\(marker.timecode)](\(url.path))")
                } else {
                    lines.append("- **[\(marker.timecode)]**")
                }
            }
            lines.append("")
        }

        lines.append("## Transcript")
        lines.append("")

        let origin = session.startedAt ?? Date()
        let myName = session.settings.userDisplayName
        // 2026-05-25 — apply acoustic-echo dedup before iterating
        // segments when the user has the suppression toggle on. Drops
        // mic-side segments that look like echoes of nearby system-
        // audio segments (user playing meeting through speakers
        // instead of headphones; mic re-captures + Whisper re-
        // transcribes the same audio, producing duplicate lines
        // attributed to the user). See `AcousticEchoDedup.swift`.
        // Side notes are COPIES of a meeting excerpt (2026-07-21 "excerpt"
        // model) — the meeting keeps every segment; nothing is cut here.
        let segments = session.settings.suppressAcousticEcho
            ? AcousticEchoDedup.filter(session.segments)
            : session.segments
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let offset = max(0, segment.startedAt.timeIntervalSince(origin))
            let label = segment.speakerLabel(displayName: myName)
            let prefix = "**[\(formatDuration(offset)) · \(label)]**"
            lines.append("\(prefix) \(text)")
            lines.append("")
        }
    }

    // MARK: - Save flow

    @MainActor
    static func saveWithPanel(session: RecordingSession) -> URL? {
        let panel = NSSavePanel()
        if let mdType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [mdType]
        }
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFilename(for: session)
        panel.title = "Save Transcript"
        panel.message = "Choose where to save the meeting transcript (e.g. your Obsidian vault)."

        if let lastFolder = restoreLastFolder() {
            panel.directoryURL = lastFolder
        }

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }

        rememberFolder(url.deletingLastPathComponent())

        let markdown = renderMarkdown(session: session)
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            log.info("Saved transcript to \(url.path, privacy: .private)")
            return url
        } catch {
            log.error("Failed to write transcript: \(error.localizedDescription, privacy: .public)")
            NSAlert.daisyError("Couldn't save transcript", error.localizedDescription)
            return nil
        }
    }

    /// Copy the rendered markdown to the system pasteboard — used by the
    /// popover footer Copy button and the widget's "Copy last transcript".
    /// Two-flavor write via RichClipboard (1.0.7.19): semantic HTML for
    /// rich targets (Slack / Notion / Gmail / Apple Notes), raw markdown
    /// for plain ones (Obsidian / Claude / editors). Frontmatter is
    /// omitted — it's vault metadata, noise everywhere a clipboard paste
    /// lands; the on-disk transcript.md keeps it (see saveWithPanel).
    @MainActor
    static func copyToClipboard(session: RecordingSession) {
        RichClipboard.copy(markdown: renderMarkdown(session: session, includeFrontmatter: false))
    }

    // MARK: - Folder bookmark (security-scoped)

    private static func rememberFolder(_ folder: URL) {
        do {
            let data = try folder.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: lastFolderBookmarkKey)
        } catch {
            log.error("Bookmark save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func restoreLastFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: lastFolderBookmarkKey) else {
            return nil
        }
        var stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    // MARK: - Formatting helpers

    private static func suggestedFilename(for session: RecordingSession) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let stamp = f.string(from: session.startedAt ?? Date())
        let safeTitle = session.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(stamp)-\(safeTitle).md"
    }

    nonisolated private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// Append a Granola-style hierarchical bullet list to the
    /// markdown output. Indentation uses two spaces per level — the
    /// standard CommonMark contract for nested lists, which
    /// Obsidian, Notion, GitHub, and most other renderers respect.
    /// Recursion depth is whatever the prompt produces; in practice
    /// it caps at ~3 levels.
    nonisolated private static func appendBullets(
        _ bullets: [SummaryBullet],
        level: Int,
        into lines: inout [String]
    ) {
        let indent = String(repeating: "  ", count: level)
        for bullet in bullets {
            lines.append("\(indent)- \(bullet.text)")
            if !bullet.children.isEmpty {
                appendBullets(bullet.children, level: level + 1, into: &lines)
            }
        }
    }

    nonisolated private static func humanDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    nonisolated private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    nonisolated private static func yamlQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Render a `[String: String]` as a YAML inline map:
    /// `{"A": "Alex", "B": "Bob"}`. Keys sorted alphabetically so
    /// diffs across runs stay stable (otherwise Codable / dict
    /// iteration order drifts). Format matches what
    /// `SessionStore.parseYAMLDict` already parses on the read
    /// side, so writes round-trip cleanly.
    nonisolated private static func yamlInlineDict(_ dict: [String: String]) -> String {
        if dict.isEmpty { return "{}" }
        let pairs = dict.keys.sorted().map { key in
            "\(yamlQuote(key)): \(yamlQuote(dict[key] ?? ""))"
        }
        return "{\(pairs.joined(separator: ", "))}"
    }
}

extension NSAlert {
    @MainActor
    static func daisyError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
