//
//  SessionEditing.swift
//  DaisyCore
//
//  backlog 8 G-2: a person edits the transcript (or the title) on the
//  phone. The contract's rules, applied literally:
//
//  §7.2 — never re-render the whole file to change one thing. The
//  frontmatter block is carried over byte for byte; a field changes by
//  replacing its line (`SessionDocument.upsertFrontmatter`), the body
//  changes by replacing exactly the section that was edited — the text
//  under `## Transcript`, nothing else.
//
//  §7.3 — atomic writes only, and never a transcript for a session that
//  has none yet: there is nothing to edit until the finishing pass has
//  written the file. (Notes as a separate section were built and removed
//  the same day — Egor, 2026-09-21: not wanted.)
//

import Foundation

public nonisolated enum SessionEditing {
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

    public static func transcriptText(in body: String) -> String? {
        section(TranscriptDocument.transcriptHeading, in: body)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Files

    /// Replace the transcript section in `transcript.md`, atomically,
    /// frontmatter untouched.
    public static func save(transcript: String, to transcriptURL: URL) throws {
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        let (frontmatter, body) = split(markdown)
        let updated = setSection(TranscriptDocument.transcriptHeading, to: transcript, in: body)
        try Data((frontmatter + updated).utf8).write(to: transcriptURL, options: .atomic)
    }

    /// `title:` only — one line replaced by prefix (§7.2).
    public static func saveTitle(_ title: String, to transcriptURL: URL) throws {
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        // One line, always: a pasted line break would end the `title:`
        // line early and spill into the frontmatter.
        let oneLine = title.components(separatedBy: .newlines).joined(separator: " ")
        let updated = SessionDocument.upsertFrontmatter(in: markdown, key: "title", value: SessionDocument.yamlQuote(oneLine))
        try Data(updated.utf8).write(to: transcriptURL, options: .atomic)
    }
}
