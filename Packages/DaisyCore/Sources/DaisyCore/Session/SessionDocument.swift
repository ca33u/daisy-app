//
//  SessionDocument.swift
//  DaisyCore
//
//  The frontmatter half of the session contract (session-format.md §3.1,
//  §3.2, §7.2) as code. Everything here is copied from daisy-app —
//  `SessionStore.parseFrontmatter` / `upsertFrontmatter` /
//  `parseYAMLDict` (SessionStore.swift ≈ lines 752 and 1554, macOS Daisy
//  1.0.7.72) and `MarkdownExporter.yamlQuote` / `yamlInlineDict` — so
//  that a file written by the phone reads back on the Mac with the SAME
//  parser, and vice versa. The Mac copy is the reference; fix there
//  first, then re-copy.
//
//  One deliberate deviation, mandated by the contract (§3.2): on read,
//  quotes are stripped from dictionary KEYS as well as values. The Mac
//  has a writer that emits `{"A": "Alex"}` and a reader that only
//  unquotes values.
//

import Foundation

/// `daisy_kind` — recording vs note. Mac `SessionKind`.
public nonisolated enum SessionKind: String, Sendable, Codable {
    case recording
    case note
}

/// Everything the Mac reader pulls out of `transcript.md`'s frontmatter.
/// Field set mirrors the Mac `ParsedFrontmatter` exactly, plus the
/// raw key→value map so unknown keys (§3.1 "ignore unknown keys") are
/// still reachable — `daisy_origin`, `daisy_recovered`, …
public nonisolated struct ParsedFrontmatter: Sendable, Equatable {
    public var title: String?
    public var locale: String?
    public var started: String?
    public var durationSec: Int?
    public var folder: String?
    public var kind: String?
    public var tag: String?
    public var attendees: [String] = []
    public var attendeeEmails: [String] = []
    public var linkedEventTitle: String?
    public var speakerMap: [String: String] = [:]
    public var systemAudioStatus: String?
    public var micOnlyCause: String?
    public var micAudioStatus: String?
    /// Every `key: value` line in frontmatter order, values with
    /// surrounding quotes stripped (§3.1 parse rule). First occurrence
    /// wins for duplicate keys, matching `upsertFrontmatter`.
    public var raw: [(key: String, value: String)] = []
    /// Keys in the order they appear — for the ordering test.
    public var keyOrder: [String] { raw.map(\.key) }
    /// Markdown body after the closing `---`. Whole text if no frontmatter.
    public var body: String

    public init(body: String) { self.body = body }

    public subscript(key: String) -> String? {
        raw.first { $0.key == key }?.value
    }

    public static func == (lhs: ParsedFrontmatter, rhs: ParsedFrontmatter) -> Bool {
        lhs.title == rhs.title && lhs.locale == rhs.locale && lhs.started == rhs.started
            && lhs.durationSec == rhs.durationSec && lhs.folder == rhs.folder
            && lhs.kind == rhs.kind && lhs.tag == rhs.tag
            && lhs.speakerMap == rhs.speakerMap
            && lhs.systemAudioStatus == rhs.systemAudioStatus
            && lhs.micAudioStatus == rhs.micAudioStatus
            && lhs.body == rhs.body
    }
}

public nonisolated enum SessionDocument {
    /// Parse `transcript.md` text. Verbatim Mac logic: line 1 must be
    /// exactly `---`; the next line that is exactly `---` closes the
    /// block; each line splits at the FIRST `:`; values lose surrounding
    /// double quotes when both are present.
    public static func parseFrontmatter(in markdown: String) -> ParsedFrontmatter {
        var parsed = ParsedFrontmatter(body: markdown)
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return parsed
        }
        var closeIdx: Int?
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closeIdx = i
                break
            }
        }
        guard let endIdx = closeIdx else { return parsed }

        for i in 1..<endIdx {
            let line = String(lines[i])
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = line[..<colonIdx].trimmingCharacters(in: .whitespaces)
            var valueRaw = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
            if valueRaw.hasPrefix("\"") && valueRaw.hasSuffix("\"") && valueRaw.count >= 2 {
                valueRaw = String(valueRaw.dropFirst().dropLast())
            }
            if !parsed.raw.contains(where: { $0.key == key }) {
                parsed.raw.append((key: key, value: valueRaw))
            }
            switch key {
            case "title":         parsed.title = valueRaw
            case "locale":        parsed.locale = valueRaw
            case "started":       parsed.started = valueRaw
            case "duration_sec":  parsed.durationSec = Int(valueRaw)
            case "daisy_folder":  parsed.folder = valueRaw.lowercased()
            case "daisy_kind":    parsed.kind = valueRaw.lowercased()
            case "daisy_tag":     parsed.tag = valueRaw
            // Legacy alias — read but never written.
            case "daisy_client":
                if parsed.tag == nil { parsed.tag = valueRaw }
            case "daisy_event_attendees":
                parsed.attendees = parseYAMLArray(valueRaw)
            case "daisy_event_emails":
                parsed.attendeeEmails = parseYAMLArray(valueRaw)
            case "daisy_event_title":
                parsed.linkedEventTitle = yamlUnquote(valueRaw)
            case "daisy_speaker_map":
                parsed.speakerMap = parseYAMLDict(valueRaw)
            case "daisy_system_audio_status":
                parsed.systemAudioStatus = valueRaw
            case "daisy_mic_only":
                parsed.micOnlyCause = valueRaw
            case "daisy_mic_audio_status":
                parsed.micAudioStatus = valueRaw
            default:              break
            }
        }
        parsed.body = lines[(endIdx + 1)...].joined(separator: "\n")
        return parsed
    }

    /// Mutate (or insert) one `key: value` line inside the YAML
    /// frontmatter at the top of `text` (§3.1 "to change one field").
    /// If there's no frontmatter at all, a fresh `---` block is prepended.
    /// Verbatim `SessionStore.upsertFrontmatter`.
    public static func upsertFrontmatter(in text: String, key: String, value: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first?.trimmingCharacters(in: .whitespaces) != "---" {
            return "---\n\(key): \(value)\n---\n\n\(text)"
        }
        var closeIdx: Int?
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closeIdx = i
                break
            }
        }
        guard let endIdx = closeIdx else {
            return "---\n\(key): \(value)\n---\n\n\(text)"
        }
        var copy = lines
        let newLine = "\(key): \(value)"
        if let existing = (1..<endIdx).first(where: { copy[$0].hasPrefix("\(key):") }) {
            copy[existing] = newLine
        } else {
            copy.insert(newLine, at: endIdx)
        }
        return copy.joined(separator: "\n")
    }

    // MARK: - YAML scalars (Mac `MarkdownExporter`)

    /// `"…"` with `\` and `"` escaped — what the Mac writes for `title`,
    /// `daisy_tag` and event fields.
    public static func yamlQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Strip surrounding double quotes and undo `yamlQuote`'s escaping.
    public static func yamlUnquote(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// `daisy_speaker_map` writer. §3.2: **bare keys**, quoted values,
    /// keys sorted so the line is stable across rewrites. Commas in a
    /// name would break the reader (no escaping exists) — replaced.
    public static func yamlInlineDict(_ dict: [String: String]) -> String {
        if dict.isEmpty { return "{}" }
        let pairs = dict.keys.sorted().map { key in
            let safeValue = (dict[key] ?? "").replacingOccurrences(of: ",", with: " ")
            return "\(key): \(yamlQuote(safeValue))"
        }
        return "{\(pairs.joined(separator: ", "))}"
    }

    /// Parse a YAML-style inline array — `["Alex", "Maria"]`.
    public static func parseYAMLArray(_ raw: String) -> [String] {
        var trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        return trimmed
            .split(separator: ",")
            .map { item in
                var s = item.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 {
                    s = String(s.dropFirst().dropLast())
                }
                return s
            }
            .filter { !$0.isEmpty }
    }

    /// Parse a YAML-style inline dict — `{A: "Alex", B: "Maria"}`.
    /// Quotes are stripped from keys too (§3.2, contract over Mac).
    public static func parseYAMLDict(_ raw: String) -> [String: String] {
        var trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        var out: [String: String] = [:]
        for pair in trimmed.split(separator: ",") {
            guard let colon = pair.firstIndex(of: ":") else { continue }
            var key = String(pair[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(pair[pair.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("\""), key.hasSuffix("\""), key.count >= 2 {
                key = String(key.dropFirst().dropLast())
            }
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty, !value.isEmpty {
                out[key] = value
            }
        }
        return out
    }
}
