//
//  SessionFrontmatter.swift
//  DaisyCore
//
//  session-format.md §3.1 as a value type: every key, in the order the
//  Mac writes them (`MarkdownExporter.frontmatterLines`, 1.0.7.72), one
//  `render()` and one `parse(_:)` that goes through the Mac's own parser
//  (`SessionDocument.parseFrontmatter`) so a phone-written file and a
//  Mac-written file are read by the same code.
//
//  The phone profile (the contract's future §3.6) is `phoneRecording`:
//  `source: Daisy`, `daisy_origin: iphone`, `daisy_kind: recording`,
//  `daisy_speaker_map: {}`, `daisy_system_audio_status: off`,
//  `daisy_mic_audio_status: captured (N B)`. `duration_sec` is an
//  integer TRUNCATED, never rounded — `Int(duration)` — as §3.1 says and
//  §3.5 reminds.
//

import Foundation

/// Per-stream capture outcome (§3.1 `daisy_*_audio_status`). The four
/// shapes the Mac writes, verbatim (`archiveLabel`).
public nonisolated enum AudioArchiveStatus: Sendable, Equatable {
    case off
    case empty
    case captured(bytes: Int64)
    case truncated(bytes: Int64, framesWritten: Int64, writeErrors: Int)

    public var label: String {
        switch self {
        case .off: return "off"
        case .empty: return "empty"
        case .captured(let bytes):
            return "captured (\(bytes) B)"
        case .truncated(let bytes, let framesWritten, let writeErrors):
            return "truncated (\(bytes) B on disk, \(framesWritten) frames written, \(writeErrors) write errors)"
        }
    }

    /// Reverse of `label` — enough for round-trip tests and for a
    /// reader that only cares which of the four shapes it is.
    public static func parse(_ raw: String) -> AudioArchiveStatus? {
        if raw == "off" { return .off }
        if raw == "empty" { return .empty }
        if raw.hasPrefix("captured ("), let n = Int64(raw.dropFirst("captured (".count).prefix { $0.isNumber }) {
            return .captured(bytes: n)
        }
        if raw.hasPrefix("truncated (") {
            let numbers = raw.split(whereSeparator: { !$0.isNumber }).compactMap { Int64($0) }
            if numbers.count >= 3 {
                return .truncated(bytes: numbers[0], framesWritten: numbers[1], writeErrors: Int(numbers[2]))
            }
        }
        return nil
    }
}

/// One extra `key: value` frontmatter line (§3.1 "other writers add").
public nonisolated struct FrontmatterField: Sendable, Equatable {
    public let key: String
    public let value: String
    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public nonisolated struct SessionFrontmatter: Sendable, Equatable {
    // §3.1, in write order.
    public var title: String
    public var type: String = "meeting-transcript"
    public var source: String = "Daisy"
    public var locale: String = "auto"
    public var detectedLocale: String?
    public var started: Date?
    /// Seconds. Rendered truncated (`Int(duration)`).
    public var duration: TimeInterval
    public var folder: String = SessionFolder.inbox.slug
    public var kind: SessionKind = .recording
    /// Where this session was made — `iphone` for us. Rendered right
    /// after `daisy_kind`, before `daisy_speaker_map`; absent on Mac
    /// files (§3.1 "other writers add"), so nil renders nothing.
    public var origin: String? = "iphone"
    public var tag: String?
    /// backlog 5 E-4: the calendar event this recording was started from
    /// (`daisy_event_*`, rendered after `daisy_tag`, before the speaker map).
    public var event: MeetingBinding?
    public var speakerMap: [String: String] = [:]
    public var audioParts: [String] = []
    public var systemAudioStatus: AudioArchiveStatus = .off
    public var micAudioStatus: AudioArchiveStatus = .off
    public var micOnlyCause: String?
    /// Writer-specific keys (today: `daisy_diag_*`, backlog 4 B-4),
    /// rendered after the contract's own keys and before `tags`.
    public var extras: [FrontmatterField] = []
    public var tags: [String] = ["meeting", "transcript", "daisy"]

    public init(title: String, started: Date?, duration: TimeInterval) {
        self.title = title
        self.started = started
        self.duration = duration
    }

    /// The phone profile: one microphone stream, nobody diarized.
    public static func phoneRecording(
        title: String,
        started: Date,
        duration: TimeInterval,
        micBytes: Int64,
        folder: String = SessionFolder.inbox.slug
    ) -> SessionFrontmatter {
        var fm = SessionFrontmatter(title: title, started: started, duration: duration)
        fm.folder = folder
        fm.kind = .recording
        fm.origin = "iphone"
        fm.systemAudioStatus = .off
        fm.micAudioStatus = micBytes > 0 ? .captured(bytes: micBytes) : .empty
        return fm
    }

    /// `duration_sec` as written: truncated, never rounded.
    public var durationSec: Int { Int(duration) }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// The frontmatter block, `---` to `---`, keys in §3.1 order.
    public func renderLines() -> [String] {
        var lines: [String] = []
        lines.append("---")
        lines.append("title: \(SessionDocument.yamlQuote(title))")
        lines.append("type: \(type)")
        lines.append("source: \(source)")
        lines.append("locale: \(locale)")
        if let detectedLocale {
            lines.append("detected_locale: \(detectedLocale)")
        }
        if let started {
            lines.append("started: \(Self.iso.string(from: started))")
        }
        lines.append("duration_sec: \(durationSec)")
        lines.append("daisy_folder: \(folder)")
        lines.append("daisy_kind: \(kind.rawValue)")
        if let origin {
            lines.append("daisy_origin: \(origin)")
        }
        if let tag, !tag.isEmpty {
            lines.append("daisy_tag: \(SessionDocument.yamlQuote(tag))")
        }
        if let event {
            lines.append(contentsOf: event.frontmatterLines())
        }
        lines.append("daisy_speaker_map: \(SessionDocument.yamlInlineDict(speakerMap))")
        if audioParts.count > 1 {
            let parts = audioParts.map { SessionDocument.yamlQuote($0) }.joined(separator: ", ")
            lines.append("daisy_audio_parts: [\(parts)]")
        }
        lines.append("daisy_system_audio_status: \(systemAudioStatus.label)")
        lines.append("daisy_mic_audio_status: \(micAudioStatus.label)")
        if let micOnlyCause {
            lines.append("daisy_mic_only: \(micOnlyCause)")
        }
        for field in extras {
            lines.append("\(field.key): \(field.value)")
        }
        lines.append("tags: [\(tags.joined(separator: ", "))]")
        lines.append("---")
        return lines
    }

    public func render() -> String {
        renderLines().joined(separator: "\n")
    }

    /// Read back through the Mac parser. Returns nil when the text has
    /// no `title` — the one field every profile carries.
    public static func parse(_ markdown: String) -> SessionFrontmatter? {
        let p = SessionDocument.parseFrontmatter(in: markdown)
        guard let title = p.title else { return nil }
        let started = p.started.flatMap { iso.date(from: $0) }
        var fm = SessionFrontmatter(
            title: title,
            started: started,
            duration: TimeInterval(p.durationSec ?? 0)
        )
        if let v = p["type"] { fm.type = v }
        if let v = p["source"] { fm.source = v }
        if let v = p.locale { fm.locale = v }
        fm.detectedLocale = p["detected_locale"]
        if let v = p.folder { fm.folder = v }
        if let v = p.kind, let k = SessionKind(rawValue: v) { fm.kind = k }
        fm.origin = p["daisy_origin"]
        fm.tag = p.tag
        fm.event = MeetingBinding.parse(p)
        fm.speakerMap = p.speakerMap
        fm.audioParts = p["daisy_audio_parts"].map(SessionDocument.parseYAMLArray) ?? []
        fm.systemAudioStatus = p.systemAudioStatus.flatMap(AudioArchiveStatus.parse) ?? .off
        fm.micAudioStatus = p.micAudioStatus.flatMap(AudioArchiveStatus.parse) ?? .off
        fm.micOnlyCause = p.micOnlyCause
        fm.extras = p.raw
            .filter { $0.key.hasPrefix("daisy_diag_") }
            .map { FrontmatterField(key: $0.key, value: $0.value) }
        if let v = p["tags"] { fm.tags = SessionDocument.parseYAMLArray(v) }
        return fm
    }
}
