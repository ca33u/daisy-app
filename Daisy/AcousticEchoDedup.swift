//
//  AcousticEchoDedup.swift
//  Daisy
//
//  Post-merge text-similarity pass that drops mic-side transcript
//  segments which look like acoustic echoes of nearby system-audio
//  segments. Targets the failure mode where a user plays meeting
//  audio through the laptop speakers (instead of headphones): the
//  microphone re-captures that same audio and Whisper transcribes
//  it on the mic side. Result without this pass: every line in the
//  transcript appears twice — once correctly labeled "Remote", once
//  wrongly labeled with the user's name.
//
//  Algorithm (called from `MarkdownExporter.renderMarkdown` when
//  `AppSettings.suppressAcousticEcho` is on):
//
//    1. Walk `segments` (already sorted by `startedAt`).
//    2. For each MIC-side segment, search ±2 seconds around its
//       start time for any SYSTEM-side segment with matching text,
//       by EITHER:
//         • near-equal length (±20%) + Levenshtein similarity > 0.8, OR
//         • containment — the shorter normalized text (≥12 chars) is a
//           substring of the longer one. Handles the common case where
//           one stream emits a whole sentence as a single segment while
//           the other splits it into 2-3 chunks (the ±20% length gate
//           alone rejected those, so echoes leaked through — observed on
//           the 2026-05-31 Billions-through-speakers test).
//    3. Mark the mic segment as an echo candidate.
//    4. After the full pass, decide at SESSION level first: if the
//       recording shows a systemic echo pattern (≥5 substantial
//       verbatim matches making up ≥10% of mic segments, or ≥20
//       absolute), the mic channel is clearly re-capturing speaker
//       output — drop EVERY candidate, including isolated ones.
//       Real conversations produce echo "пунктиром": one duplicate
//       per remote utterance with the user's own interjections in
//       between, so consecutive-run heuristics never fire (field
//       report: Ken Yesh 2026-07-24 — every Remote line doubled as
//       a mic line 1-2s later, zero runs of ≥3).
//    5. Otherwise (healthy session, a few coincidental matches):
//       fall back to the conservative rule — drop only runs of ≥3
//       consecutive echo candidates, keep isolated matches on the
//       assumption they're legitimate quoting ("ты сказал X").
//
//  Why not Apple-AEC at the audio-graph level: would require
//  rebuilding the AVAudioEngine + ScreenCaptureKit capture chain
//  with `kAudioUnitSubType_VoiceProcessingIO`, which isn't drop-in
//  for ScreenCaptureKit's audio output. Headphones still solve at
//  the source — this is the 90% software mitigation for users who
//  haven't put them on.
//

import Foundation
import os

enum AcousticEchoDedup {

    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "EchoDedup")

    /// Window around a mic segment's start time within which a
    /// system-audio segment can match as an echo source. Wide enough
    /// to cover speaker→mic latency (50-200ms) plus Whisper segment-
    /// start drift (~1-2s between mic and system streams hearing the
    /// same waveform).
    private static let matchWindowSec: Double = 2.0

    /// Length-ratio bound: |mic_len - sys_len| / max(...) must be
    /// ≤ this fraction for a candidate match. Catches cases where
    /// Whisper segmented the same audio into slightly different
    /// chunks on each stream. 0.20 → 0.30 (2026-07-25): the Ken Yesh
    /// echo pair "Oh, there we go." vs "There we go." sat at 0.21 and
    /// leaked; the Levenshtein 0.8 gate behind it still rejects
    /// genuinely different text.
    private static let lengthRatioTolerance: Double = 0.30

    /// Normalized similarity threshold (0..1, where 1 = identical).
    /// 0.8 was chosen on the 2026-05-25 Billions test: SRT lines vs
    /// Daisy mic-echo lines averaged 0.85-0.95 similarity; legitimate
    /// quoting ("ты сказал X") rarely exceeds 0.6 because the user's
    /// surrounding words break the match.
    private static let similarityThreshold: Double = 0.80

    /// Minimum length (normalized chars) of the shorter segment for the
    /// containment path to fire. Below this, short fillers ("да", "нет",
    /// "хорошо") would be a substring of almost any longer line. ~12
    /// chars ≈ 2-3 Russian words. The run/systemic rules still
    /// backstop a false single match. 12 → 10 (2026-07-25): "there we
    /// go" normalizes to 11 chars and leaked at 12.
    private static let minContainmentLen: Int = 10

    /// A match only counts toward the SYSTEMIC-echo session gate when
    /// the normalized mic text is at least this long. Short fillers
    /// ("yeah", "да", "okay") match nearby system lines by coincidence
    /// all the time (simultaneous back-channel agreement) and must not
    /// be able to trip the session-level gate on their own.
    private static let minStrongLen: Int = 8

    /// Systemic-echo gate: at least this many strong matches AND at
    /// least `systemicMinStrongFraction` of non-empty mic segments…
    private static let systemicMinStrongCount: Int = 4

    /// …must be strong matches (guards long healthy meetings where a
    /// handful of coincidences accumulate)…
    private static let systemicMinStrongFraction: Double = 0.15

    /// …OR this many strong matches outright — 20 verbatim repeats
    /// within ±2s each cannot be coincidence at any session length.
    private static let systemicAbsoluteStrongCount: Int = 20

    /// Minimum length of a "confirmed echo" run. Runs of N or more
    /// consecutive mic segments matching nearby system segments are
    /// dropped wholesale; shorter runs are treated as ambiguous
    /// (possibly legitimate quoting) and kept.
    private static let confirmedEchoRunLength: Int = 3

    /// Apply the dedup filter to a merged segment list. Returns the
    /// segments to write to disk / show in transcript markdown. The
    /// input is expected to be the union of mic + system segments
    /// sorted by `startedAt`, exactly as `RecordingSession.segments`
    /// produces it.
    ///
    /// Returned list preserves order and identity for kept segments;
    /// dropped echoes are simply absent from the output.
    /// True when the most recent `filter` run tripped SYSTEMIC mode —
    /// the whole meeting echoed through speakers. Read by
    /// `RecordingSession` right after the finalize render to surface
    /// the headphones recommendation once. Same implicit isolation as
    /// the rest of this enum (project compiles main-actor-by-default).
    private(set) static var lastFilterWasSystemic = false

    /// The canonical entry point: filters AND records whether this
    /// session looked systemic, for the headphones nudge that
    /// `RecordingSession.stop()` shows once right after the render.
    static func filter(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let result = apply(segments)
        lastFilterWasSystemic = result.systemic
        return result.kept
    }

    /// Same filtering, without touching `lastFilterWasSystemic`.
    ///
    /// Every consumer that isn't "this is THE transcript" uses this —
    /// the summary text, the live catch-up, the voice-corpus harvest.
    /// They all need deduped segments, but none of them is the event
    /// the headphones nudge is reporting on, and a stray write between
    /// `renderMarkdown` setting the flag and `stop()` reading it would
    /// silently turn that nudge on or off.
    static func filteredQuietly(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        apply(segments).kept
    }

    private static func apply(
        _ input: [TranscriptSegment]
    ) -> (kept: [TranscriptSegment], systemic: Bool) {
        guard !input.isEmpty else { return (input, false) }
        let segments = trimEmbeddedEchoes(input)

        // Index system segments by start time for O(log n) window
        // lookups. We pre-normalize the system text once per
        // segment — Levenshtein on normalized text is cheaper than
        // on raw, and we'll potentially compare it against many mic
        // segments. The window scan during pass 1 walks
        // a small slice so the overall cost stays linear in
        // segment count, not quadratic.
        let systemSegments = segments
            .filter { $0.source == .systemAudio }
            .sorted { $0.startSec < $1.startSec }
        let systemNorm: [String] = systemSegments.map { normalize($0.text) }

        // Pass 1: mark every mic segment as echo / not-echo.
        // We build a parallel `isEcho` array because mic segments
        // are intermixed with system segments in the input order;
        // walking them once + storing the verdict lets pass 2 see
        // the sequential pattern without re-scanning.
        var verdict: [Bool] = Array(repeating: false, count: segments.count)
        var micNormLen: [Int] = Array(repeating: 0, count: segments.count)
        var strongCount = 0
        var micWithText = 0
        for (idx, seg) in segments.enumerated() {
            guard seg.source == .microphone else { continue }
            let micText = normalize(seg.text)
            guard !micText.isEmpty else { continue }
            micWithText += 1
            micNormLen[idx] = micText.count
            verdict[idx] = matchesAnyNearby(
                micText: micText,
                micStart: seg.startSec,
                systemSegments: systemSegments,
                systemNorm: systemNorm
            )
            if verdict[idx], micText.count >= minStrongLen {
                strongCount += 1
            }
        }

        // Session-level decision: does this recording show SYSTEMIC
        // echo (speakers instead of headphones — the mic re-captures
        // essentially every remote line)? If yes, every candidate is
        // an echo; the conservative run rule below would keep most of
        // them because real interjections break the runs.
        let strongFraction = micWithText > 0
            ? Double(strongCount) / Double(micWithText)
            : 0
        let systemicEcho =
            (strongCount >= systemicMinStrongCount && strongFraction >= systemicMinStrongFraction)
            || strongCount >= systemicAbsoluteStrongCount

        if systemicEcho {
            let kept = zip(segments, verdict)
                .compactMap { $1 && $0.source == .microphone ? nil : $0 }
            log.info("Acoustic echo dedup: SYSTEMIC mode — dropped \(segments.count - kept.count) of \(micWithText) mic segments (strong matches: \(strongCount), fraction \(String(format: "%.2f", strongFraction)))")
            return (kept, true)
        }

        // Pass 2 (healthy session): collapse the verdict array into
        // kept / dropped decisions. Echo runs of length ≥
        // `confirmedEchoRunLength` are dropped wholesale (high
        // confidence). Shorter runs are kept (ambiguous — could be
        // the user quoting the other side once, which is a
        // legitimate transcript artifact). System segments and
        // non-echo mic segments are always kept.
        var keep: [Bool] = Array(repeating: true, count: segments.count)
        var i = 0
        while i < segments.count {
            // Find next echo-run boundary.
            guard segments[i].source == .microphone, verdict[i] else {
                i += 1
                continue
            }
            // We're at the start of a candidate echo run. Walk
            // forward through consecutive mic segments and count
            // how many are flagged as echoes. Non-mic segments
            // (system audio interleaved) don't break the run —
            // they're orthogonal sources.
            let runStart = i
            var runEnd = i
            var micRunLen = 1
            var j = i + 1
            while j < segments.count {
                let s = segments[j]
                if s.source == .microphone {
                    if verdict[j] {
                        runEnd = j
                        micRunLen += 1
                        j += 1
                    } else if micNormLen[j] < minStrongLen {
                        // Short mic interjection ("yeah", "ага") between
                        // echoes — the user back-channeling over the
                        // speaker output. Doesn't count toward the run
                        // but doesn't break it either; requiring echoes
                        // to be strictly consecutive made the run rule
                        // blind to real conversational echo (Ken Yesh
                        // report, 2026-07-24).
                        j += 1
                    } else {
                        break  // substantial mic-side non-echo breaks the run
                    }
                } else {
                    // System-audio interleaved — skip past, doesn't
                    // count toward run length but doesn't break it.
                    j += 1
                }
            }
            if micRunLen >= confirmedEchoRunLength {
                // Confirmed echo block — drop all flagged mic
                // segments inside [runStart, runEnd]. Non-mic
                // segments in that range are preserved.
                for k in runStart...runEnd where verdict[k] && segments[k].source == .microphone {
                    keep[k] = false
                }
            }
            i = j
        }

        let kept = zip(segments, keep)
            .compactMap { $1 ? $0 : nil }
        if kept.count != segments.count {
            log.info("Acoustic echo dedup: run mode — dropped \(segments.count - kept.count) mic segments (strong matches: \(strongCount), fraction \(String(format: "%.2f", strongFraction)))")
        }
        return (kept, false)
    }

    // MARK: - Echo inside a line of your own

    /// Whole-segment matching misses the echo that lands in the SAME
    /// mic segment as the person's own words — Whisper joins what they
    /// said and what the speakers played the next second into one line
    /// (24.09, Egor on the laptop speakers: «Ну-ка давай, уровень
    /// собеседника…» and then the video's twenty words, as one line of
    /// his). Such a line is neither similar to the remote line nor
    /// contained in it, and dropping it would drop his words too.
    ///
    /// So word by word: a run of `minEchoRun` or more words that the
    /// system stream says at the same time is cut out of the mic line.
    /// What remains around it goes too if most of its words are the
    /// remote's (the ragged edge of the same echo); a line that is
    /// nothing but echo is dropped. Same time is the guard — a person
    /// quoting the other side does it after them, not over them.
    static let minEchoRun = 5
    /// Seconds a system line may start after, or end before, the mic
    /// line and still count as said at the same time.
    private static let overlapSlackSec: Double = 1.5

    static func trimEmbeddedEchoes(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let system = segments.filter { $0.source == .systemAudio }
        guard !system.isEmpty else { return segments }
        var trimmed = 0
        var dropped = 0
        var result: [TranscriptSegment] = []
        result.reserveCapacity(segments.count)
        for segment in segments {
            guard segment.source == .microphone else { result.append(segment); continue }
            let micEnd = max(segment.endSec, segment.startSec + 1)
            let window = system
                .filter { sys in
                    let sysEnd = max(sys.endSec, sys.startSec + 1)
                    return sys.startSec <= micEnd + overlapSlackSec && sysEnd >= segment.startSec - overlapSlackSec
                }
                .sorted { $0.startSec < $1.startSec }
            guard !window.isEmpty else { result.append(segment); continue }
            let remote = window.flatMap { words(in: $0.text).map(\.norm) }
            switch cutEcho(from: segment.text, remote: remote) {
            case .none:
                result.append(segment)
            case .some(let rest) where rest.isEmpty:
                dropped += 1
            case .some(let rest):
                var copy = segment
                copy.text = rest
                result.append(copy)
                trimmed += 1
            }
        }
        if trimmed + dropped > 0 {
            log.info("Acoustic echo dedup: cut the speakers' words out of \(trimmed) mic line(s), dropped \(dropped) that were only echo")
        }
        return result
    }

    /// The mic text with the echo cut out; `""` when nothing of the
    /// person's own is left; `nil` when there is no echo in it.
    static func cutEcho(from text: String, remote: [String]) -> String? {
        let tokens = words(in: text)
        let mic = tokens.map(\.norm)
        guard !mic.isEmpty, !remote.isEmpty else { return nil }
        let remoteSet = Set(remote)

        var echo = [Bool](repeating: false, count: mic.count)
        var foundRun = false
        // Longest common runs, longest first, until none is long enough.
        while let run = longestCommonRun(mic, remote, excluding: echo), run.length >= minEchoRun {
            for k in run.start..<(run.start + run.length) { echo[k] = true }
            foundRun = true
        }

        // The ragged edges and short lines: a stretch of the mic line
        // whose content words are mostly the remote's, holding a run of
        // at least three words said at the same time.
        var i = 0
        while i < mic.count {
            guard !echo[i] else { i += 1; continue }
            var j = i
            while j < mic.count, !echo[j] { j += 1 }
            let stretch = Array(mic[i..<j])
            let content = stretch.filter { $0.count >= 3 }
            let shared = content.filter { remoteSet.contains($0) }.count
            let touchesEcho = (i > 0 && echo[i - 1]) || (j < mic.count && echo[j])
            let mostlyRemote = !content.isEmpty && Double(shared) / Double(content.count) >= 0.5
            let hasRun = (longestCommonRun(stretch, remote, excluding: [Bool](repeating: false, count: stretch.count))?.length ?? 0) >= 3
            let debris = content.isEmpty && stretch.count <= 2
            if (touchesEcho && (mostlyRemote || debris)) || (mostlyRemote && hasRun && Double(shared) / Double(content.count) >= 0.6) {
                for k in i..<j { echo[k] = true }
                foundRun = true
            }
            i = j
        }
        guard foundRun else { return nil }

        let kept = tokens.indices.filter { !echo[$0] }.map { tokens[$0].raw }
        let joined = kept.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters).subtracting(CharacterSet(charactersIn: ".?!…")))
        guard joined.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    /// Words of a line: the raw token and its normalized form. Tokens
    /// that are only punctuation ride along with the word before them.
    private static func words(in text: String) -> [(raw: String, norm: String)] {
        var out: [(raw: String, norm: String)] = []
        for token in text.split(whereSeparator: \.isWhitespace) {
            let norm = normalize(String(token)).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "ё", with: "е")
            if norm.isEmpty {
                if !out.isEmpty { out[out.count - 1].raw += " " + token }
                continue
            }
            out.append((String(token), norm))
        }
        return out
    }

    /// The longest run of words `a` shares with `b` in the same order,
    /// not touching positions of `a` already taken.
    private static func longestCommonRun(_ a: [String], _ b: [String], excluding taken: [Bool]) -> (start: Int, length: Int)? {
        guard !a.isEmpty, !b.isEmpty else { return nil }
        var best: (start: Int, length: Int)? = nil
        var previous = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            var current = [Int](repeating: 0, count: b.count + 1)
            for j in 1...b.count where !taken[i - 1] && a[i - 1] == b[j - 1] {
                current[j] = previous[j - 1] + 1
                if current[j] > (best?.length ?? 0) {
                    best = (i - current[j], current[j])
                }
            }
            previous = current
        }
        return best
    }

    // MARK: - Internals

    /// Walks the sorted `systemSegments` and returns true if any
    /// system segment within ±matchWindowSec of `micStart` has text
    /// matching `micText` per the similarity + length-ratio rules.
    /// Linear in the size of the window slice (typically ≤5 segments)
    /// rather than total system segment count.
    private static func matchesAnyNearby(
        micText: String,
        micStart: Double,
        systemSegments: [TranscriptSegment],
        systemNorm: [String]
    ) -> Bool {
        // Binary search for the first system segment whose start is
        // within the window. lowerBound = micStart - window.
        let lowerBound = micStart - matchWindowSec
        let upperBound = micStart + matchWindowSec
        guard let startIdx = firstIndex(systemSegments, atOrAfter: lowerBound) else {
            return false
        }
        var idx = startIdx
        while idx < systemSegments.count, systemSegments[idx].startSec <= upperBound {
            let sysText = systemNorm[idx]
            if isEchoMatch(micText: micText, sysText: sysText) {
                return true
            }
            idx += 1
        }
        return false
    }

    /// First index in `segments` whose `startSec` is ≥ `target`.
    /// Standard binary-search lower-bound; returns nil if all
    /// segments precede the target.
    private static func firstIndex(
        _ segments: [TranscriptSegment],
        atOrAfter target: Double
    ) -> Int? {
        var lo = 0
        var hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].startSec < target {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo < segments.count ? lo : nil
    }

    /// Both texts already normalized via `normalize(_:)`. Checks
    /// the length-ratio gate first (cheap O(1) reject) before
    /// running Levenshtein (O(n*m)).
    private static func isEchoMatch(micText: String, sysText: String) -> Bool {
        guard !sysText.isEmpty, !micText.isEmpty else { return false }
        let micLen = Double(micText.count)
        let sysLen = Double(sysText.count)

        // Path 1 — near-equal length + high similarity. Catches the same
        // utterance transcribed slightly differently on each stream
        // ("Нова Медиа" vs "Ново-Медиа") when both streams chunked it
        // the same way.
        let ratio = abs(micLen - sysLen) / max(micLen, sysLen)
        if ratio <= lengthRatioTolerance {
            let dist = Double(levenshtein(micText, sysText))
            let similarity = 1.0 - (dist / max(micLen, sysLen))
            if similarity >= similarityThreshold { return true }
        }

        // Path 2 — containment. The common real case: one stream emits
        // the whole sentence as one segment while the other splits it
        // into chunks, so each chunk is a substring of the long segment
        // but the ±20% length gate (Path 1) rejects it. If the shorter
        // normalized text is substantial (≥ minContainmentLen) and is a
        // substring of the longer, treat as echo. The ≥3-consecutive run
        // rule in `filter` still protects an isolated legitimate quote.
        let (shorter, longer) = micLen <= sysLen
            ? (micText, sysText)
            : (sysText, micText)
        if shorter.count >= minContainmentLen, longer.contains(shorter) {
            return true
        }
        return false
    }

    /// Normalize for similarity comparison: lowercase, drop
    /// non-letter/digit punctuation, collapse whitespace. Whisper
    /// emits slightly different punctuation across passes ("Хорошо."
    /// on mic vs "Хорошо" on system, "ё" vs "е" inconsistencies)
    /// and we don't want those to break the match.
    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        var scalars: [Character] = []
        var lastWasSpace = false
        for c in lowered {
            if c.isLetter || c.isNumber {
                scalars.append(c)
                lastWasSpace = false
            } else if c.isWhitespace {
                if !lastWasSpace, !scalars.isEmpty {
                    scalars.append(" ")
                    lastWasSpace = true
                }
            }
            // Punctuation/symbols dropped entirely.
        }
        // Trim trailing space if any.
        while scalars.last == " " { scalars.removeLast() }
        return String(scalars)
    }

    /// Standard iterative Levenshtein distance with O(min(m,n)) extra
    /// memory. Called on short normalized strings (typical Whisper
    /// segment 5-30 words = 30-200 chars), so the O(n*m) cost is
    /// negligible against the ±2s window scan.
    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }

        var previous = Array(0...bChars.count)
        var current = Array(repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            current[0] = i
            for j in 1...bChars.count {
                let cost = (aChars[i - 1] == bChars[j - 1]) ? 0 : 1
                current[j] = min(
                    previous[j] + 1,        // deletion
                    current[j - 1] + 1,     // insertion
                    previous[j - 1] + cost  // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[bChars.count]
    }
}
