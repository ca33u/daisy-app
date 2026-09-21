//
//  SessionEditing.swift
//  DaisyCore
//
//  backlog 8 G-2: a person edits the transcript and writes notes on the
//  phone. The contract's rules, applied literally:
//
//  §7.2 — never re-render the whole file to change one thing. The
//  frontmatter block is carried over byte for byte; a field changes by
//  replacing its line (`SessionDocument.upsertFrontmatter`), the body
//  changes by replacing exactly the section that was edited.
//
//  §7.3 — atomic writes only, and never a transcript for a session
//  that has none yet: while a recording still waits for its finishing
//  pass, a note is kept in a HIDDEN sidecar (`.pending-notes.md`, ignored
//  by every reader) and folded into `transcript.md` by
//  `SessionWriter.finish` — so an edit made during transcription is never
//  overwritten by the pass, it is what the pass writes.
//
//  `## Notes` is a section of its own, before `## Transcript`, never mixed
//  into the transcript's lines. A reader that doesn't know it shows it as
//  the Markdown it is.
//

import Foundation

public nonisolated enum SessionEditing {
    public static let notesHeading = "## Notes"
    public static let pendingNotesName = ".pending-notes.md"

    // MARK: - Frontmatter kept verbatim

    /// The raw frontmatter block (first `---` through the closing `---`,
    /// with its trailing newline) and the body after it. When there is
    /// no frontmatter the block is empty and the body is the whole text.
    public static func split(_ markdown: String) -> (frontmatter: String, body: String) {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return ("", markdown) }
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            let block = lines[0...i].joined(separator: "\n") + "\n"
            let body = lines[(i + 1)...].joined(separator: "\n")
            return (block, body)
        }
        return ("", markdown)
    }

    /// The same file with only the body replaced.
    public static func replacingBody(of markdown: String, with body: String) -> String {
        let (frontmatter, _) = split(markdown)
        return frontmatter + body
    }

    // MARK: - Sections of the body

    /// `## Heading` lines that start a section (`## Transcript`, `## Notes`,
    /// the Mac's localized ones). `#` (title) and `###` are not.
    static func isSectionHeading(_ line: String) -> Bool {
        line.hasPrefix("## ")
    }

    /// The lines of the section under `heading`, excluding the heading,
    /// up to the next `## ` or the end; nil when the heading is absent.
    public static func section(_ heading: String, in body: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0 == heading }) else { return nil }
        var end = lines.count
        for i in (start + 1)..<lines.count where isSectionHeading(lines[i]) { end = i; break }
        return lines[(start + 1)..<end].joined(separator: "\n")
    }

    /// The body with the section under `heading` replaced by `content`
    /// (heading kept). If the heading is absent: inserted before
    /// `## Transcript` when there is one, else appended. Empty content
    /// removes the section altogether.
    public static func setSection(_ heading: String, to content: String, in body: String) -> String {
        var lines = body.components(separatedBy: "\n")
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let block: [String] = trimmed.isEmpty ? [] : [heading, ""] + trimmed.components(separatedBy: "\n") + [""]
        if let start = lines.firstIndex(where: { $0 == heading }) {
            var end = lines.count
            for i in (start + 1)..<lines.count where isSectionHeading(lines[i]) { end = i; break }
            lines.replaceSubrange(start..<end, with: block)
        } else if !block.isEmpty {
            if let transcript = lines.firstIndex(where: { $0 == TranscriptDocument.transcriptHeading }) {
                lines.insert(contentsOf: block, at: transcript)
            } else {
                if lines.last?.isEmpty == false { lines.append("") }
                lines.append(contentsOf: block)
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func notes(in body: String) -> String? {
        section(notesHeading, in: body)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func transcriptText(in body: String) -> String? {
        section(TranscriptDocument.transcriptHeading, in: body)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Files

    /// Replace the transcript section and/or the notes in `transcript.md`,
    /// atomically, frontmatter untouched. Nil leaves that part alone.
    public static func save(transcript: String?, notes: String?, to transcriptURL: URL) throws {
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        var (frontmatter, body) = split(markdown)
        if let transcript {
            body = setSection(TranscriptDocument.transcriptHeading, to: transcript, in: body)
        }
        if let notes {
            body = setSection(notesHeading, to: notes, in: body)
        }
        try Data((frontmatter + body).utf8).write(to: transcriptURL, options: .atomic)
    }

    /// `title:` only — one line replaced by prefix (§7.2).
    public static func saveTitle(_ title: String, to transcriptURL: URL) throws {
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        let updated = SessionDocument.upsertFrontmatter(in: markdown, key: "title", value: SessionDocument.yamlQuote(title))
        try Data(updated.utf8).write(to: transcriptURL, options: .atomic)
    }

    /// A note for a session that has no transcript yet: kept hidden until
    /// the finishing pass folds it in. Empty text removes the sidecar.
    public static func savePendingNotes(_ notes: String, in sessionDirectory: URL) throws {
        let url = sessionDirectory.appendingPathComponent(pendingNotesName)
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try Data(trimmed.utf8).write(to: url, options: .atomic)
        }
    }

    public static func pendingNotes(in sessionDirectory: URL) -> String? {
        let url = sessionDirectory.appendingPathComponent(pendingNotesName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Called by `SessionWriter.finish`: the rendered transcript with the
    /// pending note folded in as `## Notes`, and the sidecar removed.
    public static func foldPendingNotes(into transcript: String, sessionDirectory: URL) -> String {
        guard let notes = pendingNotes(in: sessionDirectory) else { return transcript }
        let (frontmatter, body) = split(transcript)
        let folded = frontmatter + setSection(notesHeading, to: notes, in: body)
        try? FileManager.default.removeItem(at: sessionDirectory.appendingPathComponent(pendingNotesName))
        return folded
    }
}
