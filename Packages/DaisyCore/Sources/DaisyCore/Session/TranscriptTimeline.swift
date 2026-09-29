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
        case photo(Photo)

        public var id: String {
            switch self {
            case .segment(let s): "s-\(s.startSec)-\(s.text.hashValue)"
            case .photo(let p): "p-\(p.file)"
            }
        }

        public var startSec: Double {
            switch self {
            case .segment(let s): s.startSec
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
        let segments = parseSegments(body)
        let duration = Double(durationSec)
        var during: [Item] = []
        var later: [Item] = []
        for (file, offset) in frames {
            let photo = Photo(file: file, offsetSec: offset, isAddedLater: duration > 0 && offset > duration)
            if photo.isAddedLater { later.append(.photo(photo)) } else { during.append(.photo(photo)) }
        }
        var merged = segments.map(Item.segment) + during
        // Sort by the clock; a photo taken at the same second as a line
        // was taken while it was being said, so it comes after it.
        merged.sort { lhs, rhs in
            if lhs.startSec != rhs.startSec { return lhs.startSec < rhs.startSec }
            if case .segment = lhs, case .photo = rhs { return true }
            return false
        }
        later.sort { $0.startSec < $1.startSec }
        return merged + later
    }

    /// Segment lines of a body: `**[m:ss · Name]** text` (§3.3).
    /// Anything else (a heading, a stray paragraph) is skipped — this
    /// reads, it does not rewrite.
    public static func parseSegments(_ body: String) -> [Segment] {
        var out: [Segment] = []
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("**["), let close = trimmed.range(of: "]**") else { continue }
            let head = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<close.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let text = String(trimmed[close.upperBound...]).trimmingCharacters(in: .whitespaces)
            // `m:ss · Name` — the separator is the contract's middle dot.
            let parts = head.components(separatedBy: " · ")
            guard parts.count >= 2, let seconds = seconds(from: parts[0]) else { continue }
            out.append(Segment(
                startSec: seconds,
                speaker: parts.dropFirst().joined(separator: " · "),
                text: text,
                rawLine: line
            ))
        }
        return out
    }

    /// `m:ss` or `h:mm:ss` → seconds.
    public static func seconds(from timecode: String) -> Double? {
        let parts = timecode.split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return parts.reduce(0.0) { $0 * 60 + Double(Int($1)!) }
    }
}
