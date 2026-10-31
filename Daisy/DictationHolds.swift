//
//  DictationHolds.swift
//  Daisy
//
//  Dictation during a recording (Egor, 31.10). The dictation key held
//  while a meeting or a voice note records starts a dictation on a side
//  session of its own (`RecordingSession.sideDictation`) and pastes as
//  always. The recording's own microphone hears those words too, and they
//  were said to a text field, not to the meeting — so each hold's span is
//  kept on the recording and the recording's own-mic lines inside it are
//  cut from its transcript, and with it from the summary.
//
//  THE CLOCKS. A span is in seconds of the recording, pauses excluded —
//  the clock a `TranscriptSegment`'s `startSec` / `endSec` are on. There
//  are two such clocks, a fraction of a second apart per pause:
//    • the archives' timeline (`ArchiveOrigin.timelineSeconds`), which the
//      final pass, the queue, a retranscribe and crash recovery read their
//      lines on: each track's archive is padded to the shared origin and
//      to the shared pause/resume moments. This is the span persisted;
//    • the live clock (`CoreAudioMicRecorder.currentElapsed`, captured
//      time), which the live lines are on until the final pass replaces
//      them. Kept in memory only, for the live view and the transcript
//      written at Stop.
//  A hold that falls entirely inside a pause has no length and cuts
//  nothing; nothing was recorded then.
//
//  THE RULE. Only microphone lines: the other side (system audio) is
//  untouched, and so is the audio archive — the cut is a transcript
//  filter, re-applied by every pass that rebuilds the transcript (live,
//  the post-Stop final pass, the queue's finish, a later retranscribe,
//  crash recovery). Each span is widened by `margin` on both sides (key
//  travel, a word begun a beat early or finished a beat late); a mic line
//  is cut when MORE THAN HALF of its duration lies inside the widened
//  spans. A meeting sentence that merely brushes a hold stays; a line
//  with no duration is cut when its start is inside.
//
//  Persisted as `dictation-holds.json` in the session folder, rewritten on
//  every hold — the same pattern as `markers.json`, so a crash or a later
//  pass still knows which words to leave out.
//

import Foundation

/// One dictation held over a recording, on its media clock.
nonisolated struct DictationHold: Codable, Sendable, Hashable {
    var startSec: Double
    var endSec: Double
}

/// Where a dictation's key went down or came up, on both of a
/// recording's clocks (see THE CLOCKS above).
nonisolated struct DictationHoldMark: Sendable, Hashable {
    /// The archives' timeline: what the final pass's lines are on.
    var timeline: Double
    /// Captured time: what the live lines are on.
    var live: Double
}

nonisolated enum DictationHoldCut {
    /// Slack on both sides of a hold.
    static let margin: TimeInterval = 0.3

    /// The span a hold leaves on the recording's media clock, or `nil`
    /// when it has none (held wholly inside a pause — nothing recorded).
    static func span(from start: Double, to end: Double) -> DictationHold? {
        end > start ? DictationHold(startSec: max(0, start), endSec: end) : nil
    }

    /// Whether a line belongs to a dictation rather than the recording.
    static func isCut(_ segment: TranscriptSegment, by holds: [DictationHold], margin: TimeInterval = margin) -> Bool {
        guard segment.source == .microphone, !holds.isEmpty else { return false }
        return isCut(start: segment.startSec, end: segment.endSec, by: merged(holds, margin: margin))
    }

    /// The recording's lines without those a dictation owns.
    static func removing(_ segments: [TranscriptSegment], holds: [DictationHold], margin: TimeInterval = margin) -> [TranscriptSegment] {
        guard !holds.isEmpty else { return segments }
        let spans = merged(holds, margin: margin)
        return segments.filter { segment in
            segment.source != .microphone || !isCut(start: segment.startSec, end: segment.endSec, by: spans)
        }
    }

    /// The majority rule over already-widened, merged spans.
    static func isCut(start: Double, end: Double, by spans: [DictationHold]) -> Bool {
        let length = end - start
        guard length > 0 else {
            return spans.contains { start >= $0.startSec && start <= $0.endSec }
        }
        var inside = 0.0
        for span in spans {
            inside += max(0, min(end, span.endSec) - max(start, span.startSec))
        }
        return inside > length / 2
    }

    /// Widened by `margin`, sorted and merged, so a line spanning two
    /// close holds counts its overlap once.
    static func merged(_ holds: [DictationHold], margin: TimeInterval) -> [DictationHold] {
        let widened = holds
            .filter { $0.endSec >= $0.startSec }
            .map { DictationHold(startSec: $0.startSec - margin, endSec: $0.endSec + margin) }
            .sorted { $0.startSec < $1.startSec }
        var result: [DictationHold] = []
        for hold in widened {
            if let last = result.last, hold.startSec <= last.endSec {
                result[result.count - 1].endSec = max(last.endSec, hold.endSec)
            } else {
                result.append(hold)
            }
        }
        return result
    }
}

/// `dictation-holds.json` in the session folder.
nonisolated enum DictationHoldStore {
    static let filename = "dictation-holds.json"

    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(filename)
    }

    static func load(from directory: URL) -> [DictationHold] {
        guard let data = try? Data(contentsOf: url(in: directory)),
              let decoded = try? JSONDecoder().decode([DictationHold].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.startSec < $1.startSec }
    }

    static func write(_ holds: [DictationHold], to directory: URL) {
        guard let data = try? JSONEncoder().encode(holds.sorted { $0.startSec < $1.startSec }) else { return }
        try? data.write(to: url(in: directory), options: .atomic)
    }
}
