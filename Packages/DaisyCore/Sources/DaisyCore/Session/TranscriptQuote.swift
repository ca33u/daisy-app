//
//  TranscriptQuote.swift
//  DaisyCore
//
//  Backlog 24 М-11: a few lines of a meeting as a quote — «12.09, 14:20 —
//  Иван: …» — and, when asked, the same stretch of the recording as an
//  .m4a, at most a minute: a quote, not the recording. One builder for the
//  phone and the Mac; the Mac's microphone and system audio are mixed.
//

import AVFoundation
import Foundation

public nonisolated enum TranscriptQuote {
    public static let maxAudioSeconds: Double = 60

    /// «12.09, 14:20 — Иван: …», then one line per speaker turn.
    public static func text(_ segments: [TranscriptTimeline.Segment], started: Date, locale: Locale = .current) -> String {
        guard let first = segments.first else { return "" }
        let when = started.addingTimeInterval(first.startSec)
        let stamp = when.formatted(.dateTime.day().month(.twoDigits).locale(locale)) + ", "
            + when.formatted(.dateTime.hour().minute().locale(locale))
        return segments.enumerated().map { index, segment in
            let line = segment.speaker.isEmpty ? plain(segment.text) : "\(segment.speaker): \(plain(segment.text))"
            return index == 0 ? "\(stamp) — \(line)" : line
        }.joined(separator: "\n")
    }

    /// The markers of a highlight (`==…==`) are not part of what was said.
    public static func plain(_ text: String) -> String { text.replacingOccurrences(of: "==", with: "") }

    /// From a second before the first line to a second after the last one
    /// ends (where the next begins), at most a minute.
    public static func audioRange(_ segments: [TranscriptTimeline.Segment], next: TranscriptTimeline.Segment?) -> ClosedRange<Double>? {
        guard let first = segments.first, let last = segments.last else { return nil }
        let start = max(0, first.startSec - 1)
        let end = (next?.startSec ?? (last.startSec + 10)) + 1
        guard end > start else { return nil }
        return start...min(end, start + maxAudioSeconds)
    }

    /// The stretch as .m4a. Each element of `tracks` is one source (the
    /// microphone, the system audio) as its parts end to end; several
    /// sources are mixed.
    public static func exportAudio(tracks: [[URL]], range: ClosedRange<Double>, to url: URL) async throws {
        let composition = AVMutableComposition()
        var longest = CMTime.zero
        for parts in tracks where !parts.isEmpty {
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            var cursor = CMTime.zero
            for part in parts {
                let asset = AVURLAsset(url: part)
                guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                let length = try await asset.load(.duration)
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: cursor)
                cursor = cursor + length
            }
            if cursor > longest { longest = cursor }
        }
        guard longest > .zero,
              let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)
        else { throw CocoaError(.fileWriteUnknown) }
        export.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                                       end: CMTime(seconds: min(range.upperBound, longest.seconds), preferredTimescale: 600))
        try? FileManager.default.removeItem(at: url)
        try await export.export(to: url, as: .m4a)
    }

    /// The transcript's lines a selection touches, in order: a whole line
    /// by its stamp, a piece of one by its words.
    public static func segments(touchedBy selection: String, in lines: [TranscriptTimeline.Segment]) -> [TranscriptTimeline.Segment] {
        let pieces = selection.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: #"^\s*\[[^\]]*\]\s*"#, with: "", options: .regularExpression) }
            .map { $0.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 3 }
        var out: [TranscriptTimeline.Segment] = []
        var from = 0
        for piece in pieces {
            guard let index = lines[from...].firstIndex(where: { plain($0.text).contains(piece) || piece.contains(plain($0.text)) })
            else { continue }
            if !out.contains(lines[index]) { out.append(lines[index]) }
            from = index
        }
        return out
    }
}
