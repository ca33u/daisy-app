// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  NotionMeetingNote.swift
//  Daisy
//
//  A meeting as a Notion meeting note (`POST /v1/meeting_notes`, Notion
//  changelog of 16.11.2026): the page type Notion's own AI notes use, in
//  the person's meeting notes database, which Notion makes if they have
//  none. The third kind of Notion destination, beside a child page and a
//  database row (`NotionExporter`).
//
//  What the endpoint allows, by its reference page:
//    • the token is a personal access token; an internal integration's
//      secret, which the other two kinds take, gets a 403;
//    • the text goes into the Notes tab, as Markdown, in the one call:
//      nothing can be added afterwards, and the Summary and Transcript
//      tabs are Notion's own;
//    • no page URL comes back, only the note's id.
//  A note isn't linked to a calendar event: that takes Notion Calendar's
//  ids, which the REST API has no way to look up.
//
//  Written against the documentation; not yet run against Notion.
//

import Foundation

nonisolated enum NotionMeetingNote {
    /// `daisy.notionParentKind` for this kind.
    static let kind = "meeting_notes"
    static let endpoint = URL(string: "https://api.notion.com/v1/meeting_notes")!
    /// The only version the endpoint lists.
    static let apiVersion = "2026-03-11"

    /// Notion refuses a request over 500 KB or over 1000 blocks; both are
    /// kept under with room to spare.
    static let maxBodyBytes = 450_000
    static let maxBlocks = 900
    static let maxTitleLength = 2000

    enum Failure: LocalizedError, Equatable {
        case needsPersonalToken, tokenRejected

        var errorDescription: String? {
            switch self {
            case .needsPersonalToken:
                String(localized: "Notion meeting notes need a personal access token, not an integration secret")
            case .tokenRejected:
                String(localized: "Notion doesn’t accept this token")
            }
        }

        /// Nil for what isn't about the token: a 403 also answers with
        /// other codes (a workspace out of credits), and those keep
        /// Notion's own words.
        init?(status: Int, body: Data) {
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            switch (status, json?["code"] as? String) {
            case (401, _): self = .tokenRejected
            case (403, "restricted_resource"): self = .needsPersonalToken
            default: return nil
            }
        }
    }

    // MARK: - Request

    /// The encoded body. A transcript that doesn't fit is cut at a whole
    /// block, and the note says so.
    static func body(
        for data: MeetingExportData,
        maxBytes: Int = maxBodyBytes, maxBlocks: Int = maxBlocks
    ) throws -> Data {
        let head = headBlocks(for: data)
        let transcript = data.transcriptChunks.map(transcriptBlock).filter { !$0.isEmpty }
        var kept = min(transcript.count, max(0, maxBlocks - head.count - 2))
        while true {
            var blocks = head
            if !transcript.isEmpty { blocks.append("## " + escaped(String(localized: "Transcript"))) }
            blocks += transcript.prefix(kept)
            if kept < transcript.count {
                blocks.append("*" + escaped(String(localized: "The transcript doesn’t fit into one Notion note, the rest is in Daisy")) + "*")
            }
            let encoded = try JSONSerialization.data(withJSONObject: [
                "title": String(data.title.prefix(maxTitleLength)),
                "markdown": blocks.joined(separator: "\n\n"),
                "markdown_version": "v2",
            ], options: [.withoutEscapingSlashes])
            if encoded.count <= maxBytes || kept == 0 { return encoded }
            // By the share it is over, a block at the least.
            kept = min(kept - 1, kept * maxBytes / encoded.count)
        }
    }

    /// The address of the note, from its id. The docs give no URL; taken
    /// that a full-page note opens by its id, as a page does (not checked).
    /// An answer without an id still means the note is there, and sending
    /// again would make a second one: Notion itself then.
    static func pageURL(fromResponse data: Data) -> URL {
        let home = URL(string: "https://www.notion.so/")!
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let note = json["meeting_note"] as? [String: Any],
              let raw = note["id"] as? String, let id = UUID(uuidString: raw) else { return home }
        return home.appendingPathComponent(id.uuidString.lowercased().replacingOccurrences(of: "-", with: ""))
    }

    // MARK: - Markdown

    private static func headBlocks(for data: MeetingExportData) -> [String] {
        var blocks: [String] = []
        if let started = data.startedAt {
            let stamp = DateFormatter.localizedString(from: started, dateStyle: .medium, timeStyle: .short)
            let duration = "\(data.durationSeconds / 60):\(String(format: "%02d", data.durationSeconds % 60))"
            blocks.append(escaped("📌  \(stamp)  ·  \(duration)  ·  \(data.locale)"))
        }
        guard let summary = data.summary else { return blocks }
        // The headers in the summary's language, as the page export does.
        var sample = summary.summary
        if sample.count < 60, let first = summary.sections.first?.bullets.first?.text { sample += " " + first }
        let labels = SummaryLabels.for(language: LanguageDetector.detect(sample))
        if !summary.summary.isEmpty {
            blocks.append("## " + escaped(labels.meeting))
            blocks += paragraphs(summary.summary)
        }
        // What the card shows: a template's sections when there is one.
        for section in summary.templated?.sections ?? summary.sections {
            blocks.append("## " + oneLine(section.title))
            let list = bulletLines(section.bullets, level: 0)
            if !list.isEmpty { blocks.append(list.joined(separator: "\n")) }
        }
        if !summary.actionItems.isEmpty {
            blocks.append("## " + escaped(labels.nextActions))
            blocks.append(summary.actionItems.map { "- [ ] " + oneLine($0) }.joined(separator: "\n"))
        }
        if !summary.clientFollowUp.isEmpty {
            blocks.append("## " + escaped(labels.followUp))
            blocks += paragraphs(summary.clientFollowUp)
        }
        return blocks
    }

    private static func bulletLines(_ bullets: [SummaryBullet], level: Int) -> [String] {
        bullets.flatMap { bullet in
            [String(repeating: "  ", count: level) + "- " + oneLine(bullet.text)]
                + bulletLines(bullet.children, level: level + 1)
        }
    }

    /// A chunk is several lines of the transcript; it stays one block. The
    /// stored transcript's own bold «[0:12 · Name]» stays bold, without the
    /// brackets.
    private static func transcriptBlock(_ chunk: String) -> String {
        lines(chunk).map { line in
            guard line.hasPrefix("**["), let end = line.range(of: "]**") else { return escaped(line) }
            let label = line[line.index(line.startIndex, offsetBy: 3)..<end.lowerBound]
            return "**" + escaped(String(label)) + "**" + escaped(String(line[end.upperBound...]))
        }.joined(separator: "\\\n")
    }

    /// Blank lines part paragraphs; a line inside one is a line.
    private static func paragraphs(_ text: String) -> [String] {
        var out: [[String]] = [[]]
        for line in text.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.isEmpty { out.append([]) } else { out[out.count - 1].append(escaped(line)) }
        }
        return out.filter { !$0.isEmpty }.map { $0.joined(separator: "\\\n") }
    }

    private static func oneLine(_ text: String) -> String {
        escaped(lines(text).joined(separator: " "))
    }

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Text as text: nothing a person said becomes formatting, a Notion
    /// tag or a mention. Notion's Markdown is CommonMark, where a backslash
    /// before ASCII punctuation is that punctuation. By scalars: a keycap
    /// emoji's «*» is one character with what follows it.
    ///
    /// Of the brackets only «]» is escaped: that ends a link, an image or a
    /// citation before it begins, and «\[…\]» is a display formula in
    /// the notation Notion's Markdown borrows from.
    static func escaped(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            let escapes = switch scalar {
            case "\\", "`", "*", "_", "]", "<", ">", "#", "~", "$", "|", "^", "&": true
            // A custom emoji, «:smile:» — and «1:02:45» has its shape.
            case ":": opensShortcode(scalars, after: index)
            default: false
            }
            if escapes { out.append("\\") }
            out.append(scalar)
        }
        let result = String(out)
        // At the start of a line: a list, a rule, a setext heading, «1.».
        // (A line of colons and dashes: a table's rule.)
        if let first = scalars.first, "-+=".unicodeScalars.contains(first)
            || (first == ":" && scalars.allSatisfy { $0 == ":" || $0 == "-" } && !result.hasPrefix("\\")) { return "\\" + result }
        let digits = result.prefix(while: { $0.isASCII && $0.isNumber })
        let rest = result.dropFirst(digits.count)
        if !digits.isEmpty, let mark = rest.first, mark == "." || mark == ")" { return digits + "\\" + rest }
        return result
    }

    private static func opensShortcode(_ scalars: [Unicode.Scalar], after colon: Int) -> Bool {
        var index = colon + 1
        while index < scalars.count, scalars[index].properties.isAlphabetic
                || scalars[index].properties.numericType != nil || "_-+".unicodeScalars.contains(scalars[index]) {
            index += 1
        }
        return index > colon + 1 && index < scalars.count && scalars[index] == ":"
    }
}
