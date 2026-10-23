//
//  DemoSession.swift
//  Daisy
//
//  The demo meeting of Onboarding 2.0 (Egor, 23–24.10). The tour's
//  «Meeting» step offers «Покажи на демо»: a two-minute call lands in the
//  Library at once — transcript by speaker, summary, two action items — so
//  the person sees what Daisy makes of a meeting without recording one
//  (Granola's pattern). Nothing is recorded or sent: the meeting is a
//  bundled fixture, written into the Library like a finished recording.
//
//  Fixtures: `Resources/DemoMeeting/ru.json` and `en.json` (the synchronized
//  group copies them to the bundle root). Fields: `title`, `durationSec`,
//  `anna` and `me` (the speakers' names; `me` is the fallback when no name
//  is set in Settings), `lines` (`speaker` "anna" | "me", `at` seconds,
//  `text`), `summary`, `sections` (`title` + `bullets`), `actionItems`
//  (`{anna}` and `{me}` are replaced by the names).
//
//  Audio slot: Egor records the real demo later. Put `ru.m4a` / `en.m4a`
//  next to the JSON and the install copies it into the session as
//  `system_audio.m4a` (one mixed track, like an imported file); the line
//  times must then match the recording. Without the file the demo is
//  transcript-only and the detail view says so.
//
//  The session carries `daisy_demo: true` in its front matter. Everything
//  that acts on new sessions skips it — auto-send, the anonymous counts,
//  the Home usage widgets and analytics, open items, the morning and
//  end-of-day passes, briefs and project memory, the style profile, the
//  «send recordings somewhere» nudge, iPhone sync. It is still a session:
//  it can be opened, renamed, searched and deleted like any other.
//

import DaisyCore
import Foundation
import SwiftUI
import os

enum DemoSession {
    /// Front-matter key that marks the demo. `true` is the only value.
    nonisolated static let frontmatterKey = "daisy_demo"

    nonisolated private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "DemoSession")

    // MARK: - Install

    /// Puts the demo meeting into the Library, or finds the one already
    /// there (any language), and returns its session id — the folder name,
    /// what `AppNavigation.openInLibrary(_:)` takes. Empty when it could
    /// not be written (logged); opening an empty id selects nothing.
    ///
    /// `locale` is "ru" or "en"; anything else gets English. `userName`
    /// nil reads the name from Settings; an empty name becomes «Ты» / "You".
    @discardableResult
    static func install(locale: String, userName: String? = nil) async -> String {
        // A second tap while the first install runs gets the same demo.
        if let running = installing { return await running.value }
        let task = Task { await performInstall(locale: locale, userName: userName) }
        installing = task
        defer { installing = nil }
        return await task.value
    }

    private static var installing: Task<String, Never>?

    private static func performInstall(locale: String, userName: String?) async -> String {
        let store = SessionStore.shared
        await store.refresh()
        if let existing = store.sessions.first(where: \.isDemo) { return existing.id }

        let language = locale.lowercased().hasPrefix("ru") ? "ru" : "en"
        guard let fixture = loadFixture(language: language) else {
            log.error("Demo fixture \(language, privacy: .public).json is missing from the bundle")
            return ""
        }
        guard let ticket = SessionsFolder.acquireBase() else {
            log.error("No writable sessions folder for the demo")
            return ""
        }
        defer { ticket.release() }
        let name = userName ?? UserDefaults.standard.string(forKey: AppSettings.k_userDisplayName) ?? ""
        let directory = SessionsFolder.sessionsDirectory(in: ticket.url)
        let audio = audioURL(language: language)
        let id: String
        do {
            id = try await Task.detached(priority: .userInitiated) {
                try install(fixture, language: language, userName: name, in: directory, audio: audio, now: Date())
            }.value
        } catch {
            log.error("Demo install failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
        // `refresh()` joins a scan already under way, which may have
        // listed the folder before the demo landed; the tour opens the id
        // in the Library right away, so it has to be there.
        for _ in 0..<3 where !store.sessions.contains(where: { $0.id == id }) {
            await store.refresh()
        }
        return id
    }

    /// The writing half, off the main actor and free of app state so tests
    /// can point it at a temporary folder. Returns the id of a demo already
    /// in `sessionsDirectory` instead of writing a second one.
    nonisolated static func install(
        _ fixture: Fixture,
        language: String,
        userName: String,
        in sessionsDirectory: URL,
        audio: URL?,
        now: Date
    ) throws -> String {
        if let existing = existingID(in: sessionsDirectory) { return existing }
        let fm = FileManager.default
        try fm.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

        // A real session's folder is named by its start time, and the
        // meeting has just ended. A taken name moves a second back: never
        // write into someone's recording.
        var startedAt = now.addingTimeInterval(-Double(fixture.durationSec))
        var target = sessionsDirectory.appendingPathComponent(SessionID.make(for: startedAt), isDirectory: true)
        while fm.fileExists(atPath: target.path) {
            startedAt.addTimeInterval(-1)
            target = sessionsDirectory.appendingPathComponent(SessionID.make(for: startedAt), isDirectory: true)
        }
        // Written in a hidden staging folder and moved in whole, as imports
        // are (`AudioImporter`): a Library scan in between would otherwise
        // list a half-written folder — once audio is bundled, as an
        // interrupted recording. `StagingSweep` clears a leftover.
        let directory = sessionsDirectory.appendingPathComponent(".daisy-demo-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)

        let me = userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? fixture.me
            : userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = fixture.summary(me: me)
        var hasAudio = false
        do {
            if let audio {
                try fm.copyItem(at: audio, to: directory.appendingPathComponent("system_audio.m4a"))
                hasAudio = true
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(summary).write(to: directory.appendingPathComponent("summary.json"), options: .atomic)
            // Last: transcript.md is what makes the folder a finished session.
            let markdown = transcript(fixture, language: language, me: me, summary: summary,
                                      startedAt: startedAt, hasAudio: hasAudio)
            try markdown.write(to: directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
            try fm.moveItem(at: directory, to: target)
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
        return target.lastPathComponent
    }

    /// The id of a demo session in `sessionsDirectory`, if one is there.
    nonisolated static func existingID(in sessionsDirectory: URL) -> String? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { entry in
                // Never download an evicted transcript just to look (see
                // `SessionStore.isCloudEvicted`).
                let transcript = entry.appendingPathComponent("transcript.md")
                return !SessionStore.isCloudEvicted(transcript) && isDemo(transcriptAt: transcript)
            }
            .map(\.lastPathComponent)
            .sorted()
            .first
    }

    /// True when the transcript's front matter says `daisy_demo: true`.
    nonisolated static func isDemo(transcriptAt url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let raw = SessionDocument.parseFrontmatter(in: text).raw
        return isDemo(frontmatterValue: raw.first(where: { $0.key == frontmatterKey })?.value)
    }

    nonisolated static func isDemo(frontmatterValue: String?) -> Bool {
        frontmatterValue?.trimmingCharacters(in: .whitespaces).lowercased() == "true"
    }

    // MARK: - Fixture

    nonisolated struct Fixture: Decodable, Sendable {
        enum Speaker: String, Decodable, Sendable { case anna, me }
        struct Line: Decodable, Sendable {
            let speaker: Speaker
            let at: Int
            let text: String
        }
        struct Section: Decodable, Sendable {
            let title: String
            let bullets: [String]
        }
        let title: String
        let durationSec: Int
        let anna: String
        let me: String
        let lines: [Line]
        let summary: String
        let sections: [Section]
        let actionItems: [String]

        func summary(me: String) -> MeetingSummary {
            MeetingSummary(
                summary: summary,
                sections: sections.map { section in
                    SummarySection(title: section.title, bullets: section.bullets.map { SummaryBullet(text: $0) })
                },
                actionItems: actionItems.map {
                    $0.replacingOccurrences(of: "{anna}", with: anna).replacingOccurrences(of: "{me}", with: me)
                },
                clientFollowUp: "",
                title: title
            )
        }
    }

    nonisolated static func loadFixture(language: String, bundle: Bundle = .main) -> Fixture? {
        guard let url = resource(language, "json", in: bundle),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Fixture.self, from: data)
    }

    /// The recording for the demo, when one has been bundled.
    nonisolated static func audioURL(language: String, bundle: Bundle = .main) -> URL? {
        resource(language, "m4a", in: bundle)
    }

    /// The synchronized group copies resources to the bundle root; a
    /// folder reference would keep `DemoMeeting/`. Either works.
    nonisolated private static func resource(_ name: String, _ ext: String, in bundle: Bundle) -> URL? {
        bundle.url(forResource: name, withExtension: ext, subdirectory: "DemoMeeting")
            ?? bundle.url(forResource: name, withExtension: ext)
    }

    // MARK: - Markdown

    /// transcript.md as `MarkdownExporter` writes a finished meeting.
    nonisolated static func transcript(
        _ fixture: Fixture,
        language: String,
        me: String,
        summary: MeetingSummary,
        startedAt: Date,
        hasAudio: Bool
    ) -> String {
        let labels = SummaryLabels.for(language: language)
        var lines: [String] = [
            "---",
            "title: \(yamlQuote(fixture.title))",
            "type: meeting-transcript",
            "source: Daisy",
            "locale: \(language)",
            "started: \(iso(startedAt))",
            "duration_sec: \(fixture.durationSec)",
            "daisy_folder: \(SessionFolder.inbox.slug)",
            "daisy_kind: \(SessionKind.recording.rawValue)",
            "daisy_speaker_map: {}",
        ]
        if hasAudio { lines.append("daisy_system_audio_status: captured") }
        lines += [
            "\(frontmatterKey): true",
            "tags: [meeting, transcript, daisy]",
            "---",
            "",
            "# \(fixture.title)",
            "",
            "> recorded \(humanDate(startedAt)) · \(timecode(fixture.durationSec))",
            "",
            "## \(language == "ru" ? "Сводка" : "Summary")",
            "",
            "### \(labels.meeting)",
            "",
            summary.summary,
            "",
        ]
        for section in summary.sections {
            lines += ["### \(section.title)", ""]
            lines += section.bullets.map { "- \($0.text)" }
            lines.append("")
        }
        lines += ["### \(labels.nextActions)", ""]
        lines += summary.actionItems.map { "- [ ] \($0)" }
        lines += ["", "## Transcript", ""]
        for line in fixture.lines {
            let speaker = line.speaker == .anna ? fixture.anna : me
            lines += ["**[\(timecode(line.at)) · \(speaker)]** \(line.text)", ""]
        }
        return lines.joined(separator: "\n")
    }

    nonisolated private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    nonisolated private static func humanDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    nonisolated private static func timecode(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    nonisolated private static func yamlQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - Badge

/// The small «демо» chip by the demo's title — Library row, Home's recent
/// list, the session header. Same capsule as the Library's tag chip.
struct DemoBadge: View {
    var body: some View {
        Text("demo")
            .font(.caption2.weight(.medium))
            .foregroundStyle(Color.daisyTextSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.daisySelectionBackground, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.daisySelectionBorder, lineWidth: 0.5))
            .help("A sample meeting from the tour. Delete it whenever you like.")
            .fixedSize()
    }
}
