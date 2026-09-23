//
//  CaretPosition.swift
//  DaisyCore
//
//  backlog 13 М-1: "insert here" needs to know what "here" is in the
//  transcript's own terms. A photo is not written into the body (§3.3
//  keeps frames in their own section), so the position is expressed as
//  a SECOND: the second of the segment line the caret is standing in.
//  The frame is stamped with it, and М-2's reading view then draws the
//  photo exactly where the person put it.
//

import Foundation

public nonisolated enum CaretPosition {
    /// The second of the segment the character offset falls inside.
    /// `nil` when the caret is above the first segment line — a note
    /// typed before anything was said has no second to claim.
    public static func second(inBody body: String, at offset: Int) -> Double? {
        let nsBody = body as NSString
        let clamped = max(0, min(offset, nsBody.length))
        var searched = 0
        var current: Double?
        for line in body.components(separatedBy: "\n") {
            let lineLength = (line as NSString).length
            if let segment = TranscriptTimeline.parseSegments(line).first {
                // A caret exactly at the start of a NEW segment belongs
                // to that segment, not to the one above it.
                if clamped >= searched { current = segment.startSec } else { break }
            }
            searched += lineLength + 1   // the newline
            if searched > clamped { break }
        }
        return current
    }

    /// Insert `text` at `offset`, on its own line, without disturbing
    /// what is around it — the editor writes the whole body back, so
    /// what was not touched must come back identical (§7.2).
    public static func insert(_ text: String, into body: String, at offset: Int) -> (body: String, caret: Int) {
        let nsBody = body as NSString
        let clamped = max(0, min(offset, nsBody.length))
        // Move to the end of the line the caret is in: a segment line is
        // one unit, and splitting it in half would break §3.3's shape.
        var insertion = clamped
        while insertion < nsBody.length, nsBody.character(at: insertion) != 10 { insertion += 1 }
        let prefix = nsBody.substring(to: insertion)
        let suffix = nsBody.substring(from: insertion)
        let block = "\n\n" + text
        let joined = prefix + block + (suffix.hasPrefix("\n") ? suffix : (suffix.isEmpty ? "\n" : "\n" + suffix))
        return (joined, (prefix as NSString).length + (block as NSString).length)
    }

    /// A spoken note as a segment line, so it reads like the rest of the
    /// transcript and the timeline can place it (§3.3).
    public static func segmentLine(second: Double, speaker: String, text: String) -> String {
        "**[\(TranscriptDocument.formatDuration(max(0, second))) · \(speaker)]** \(text)"
    }
}
