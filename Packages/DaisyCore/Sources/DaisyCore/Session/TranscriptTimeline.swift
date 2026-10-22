//
//  TranscriptTimeline.swift
//  DaisyCore
//
//  backlog 13 М-2: a photo taken during a meeting belongs where it was
//  taken — between the words that were said around it — not in a strip
//  at the bottom of the screen.
//
//  The data for this has existed since backlog 6: `ScreenshotIndex`
//  stamps every frame with its second into `index.json`, §7.6 describes
//  it and the Mac reads it. What was missing was the reading order. So
//  this is a VIEW over what is already on disk: segments and frames
//  merged onto one clock. **Nothing in the format changes** — not the
//  numbering, not `index.json`, not the order of anything.
//
//  §7.6 / §3.3: a frame whose stamp is greater than `duration_sec` was
//  attached after the recording (a card photographed a week later). It
//  is not a position in the conversation and must never be drawn as
//  one: those go last, marked "added later".
//

import Foundation

public nonisolated enum TranscriptTimeline {
    public enum Item: Sendable, Equatable, Identifiable {
        case segment(Segment)
        /// A line under `## Transcript` without a stamp (§3.3): shown, never hidden.
        case paragraph(Paragraph)
        case photo(Photo)

        public var id: String {
            switch self {
            case .segment(let s): "s-\(s.startSec)-\(s.text.hashValue)"
            case .paragraph(let p): "t-\(p.afterSec)-\(p.rawLine.hashValue)"
            case .photo(let p): "p-\(p.file)"
            }
        }

        public var startSec: Double {
            switch self {
            case .segment(let s): s.startSec
            case .paragraph(let p): p.afterSec
            case .photo(let p): p.offsetSec
            }
        }
    }

    public struct Segment: Sendable, Equatable {
        public var startSec: Double
        public var speaker: String
        public var text: String
        /// The line exactly as it stands in the file, for an editor that
        /// must put back what it did not change (§7.2).
        public var rawLine: String

        public init(startSec: Double, speaker: String, text: String, rawLine: String) {
            self.startSec = startSec; self.speaker = speaker; self.text = text; self.rawLine = rawLine
        }
    }

    public struct Paragraph: Sendable, Equatable {
        /// The second of the stamped line above it (0 before the first):
        /// it has no clock of its own and reads after that line.
        public var afterSec: Double
        public var text: String
        /// The line exactly as it stands in the file (§7.2).
        public var rawLine: String

        public init(afterSec: Double, text: String, rawLine: String) {
            self.afterSec = afterSec; self.text = text; self.rawLine = rawLine
        }
    }

    public struct Photo: Sendable, Equatable {
        public var file: String
        public var offsetSec: Double
        /// §7.6: stamped past the end of the recording.
        public var isAddedLater: Bool
    }

    /// The transcript body and the frames, in reading order.
    ///
    /// - Parameters:
    ///   - body: everything under `## Transcript`.
    ///   - frames: `index.json` as filename → seconds.
    ///   - durationSec: `duration_sec` from the frontmatter; a frame
    ///     stamped past it was added after the recording.
    public static func items(body: String, frames: [String: Double], durationSec: Int) -> [Item] {
        let duration = Double(durationSec)
        // Text in the order of the file; a paragraph takes the clock of the
        // stamped line above it, and `order` keeps it right after that line.
        var text: [(item: Item, order: Int)] = []
        var lastSec = 0.0
        for (order, line) in body.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let segment = segment(from: line) {
                lastSec = segment.startSec
                text.append((.segment(segment), order))
            } else {
                text.append((.paragraph(Paragraph(afterSec: lastSec, text: trimmed, rawLine: line)), order))
            }
        }
        var during: [(item: Item, order: Int)] = []
        var later: [Item] = []
        for (file, offset) in frames {
            let photo = Photo(file: file, offsetSec: offset, isAddedLater: duration > 0 && offset > duration)
            if photo.isAddedLater { later.append(.photo(photo)) } else { during.append((.photo(photo), Int.max)) }
        }
        var merged = text + during
        // Sort by the clock; a photo taken at the same second as a line was
        // taken while it was being said, so it comes after it (and after
        // the paragraphs that follow it). Ties never depend on the sort.
        merged.sort { lhs, rhs in
            if lhs.item.startSec != rhs.item.startSec { return lhs.item.startSec < rhs.item.startSec }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            if case .photo(let a) = lhs.item, case .photo(let b) = rhs.item { return a.file < b.file }
            return false
        }
        later.sort { $0.startSec < $1.startSec }
        return merged.map(\.item) + later
    }

    /// Segment lines of a body: `**[m:ss · Name]** text` (§3.3).
    /// Anything else (a heading, a stray paragraph) is skipped — this
    /// reads, it does not rewrite.
    public static func parseSegments(_ body: String) -> [Segment] {
        body.components(separatedBy: "\n").compactMap(segment(from:))
    }

    static func segment(from line: String) -> Segment? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("**["), let close = trimmed.range(of: "]**") else { return nil }
        let head = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<close.lowerBound])
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let text = String(trimmed[close.upperBound...]).trimmingCharacters(in: .whitespaces)
        // `m:ss · Name` — the separator is the contract's middle dot.
        let parts = head.components(separatedBy: " · ")
        guard parts.count >= 2, let seconds = seconds(from: parts[0]) else { return nil }
        return Segment(
            startSec: seconds,
            speaker: parts.dropFirst().joined(separator: " · "),
            text: text,
            rawLine: line
        )
    }

    /// `m:ss` or `h:mm:ss` → seconds.
    public static func seconds(from timecode: String) -> Double? {
        let parts = timecode.split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return parts.reduce(0.0) { $0 * 60 + Double(Int($1)!) }
    }
}
