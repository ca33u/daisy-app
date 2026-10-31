//
//  DictationDuringRecordingTests.swift
//  DaisyTests
//
//  The dictation key during a recording (Egor, 31.10): the press goes to
//  the side session instead of being refused, and the words dictated are
//  cut from the recording's own microphone lines — the majority rule, a
//  0.3 s margin, the other side untouched — from a span kept beside the
//  recording in `dictation-holds.json`.
//

import Foundation
import Testing
@testable import Daisy

struct DictationHoldCutTests {
    private let origin = Date(timeIntervalSince1970: 2_000_000)

    private func line(_ text: String, at start: Double, to end: Double, source: SegmentSource = .microphone) -> TranscriptSegment {
        TranscriptSegment(id: UUID(), startedAt: origin.addingTimeInterval(start), text: text, isFinal: true,
                          source: source, endSec: end, startSec: start)
    }

    private let hold = DictationHold(startSec: 100, endSec: 106)

    @Test func theDictatedLinesAreCut() {
        #expect(DictationHoldCut.isCut(line("отправить Пете договор", at: 100.5, to: 105), by: [hold]))
        // Begun a beat before the key went down, finished a beat after it
        // came up: inside the margin.
        #expect(DictationHoldCut.isCut(line("и приложить счёт", at: 99.8, to: 106.2), by: [hold]))
    }

    @Test func theMajorityDecides() {
        // 4 s of a 6 s line inside the widened span (99.7…106.3): cut.
        #expect(DictationHoldCut.isCut(line("большая часть внутри", at: 102.3, to: 108.3), by: [hold]))
        // 2 s of an 8 s line inside: the meeting's sentence that brushed
        // the hold stays.
        #expect(!DictationHoldCut.isCut(line("как я и говорил", at: 93.7, to: 101.7), by: [hold]))
        // Exactly half is not more than half.
        #expect(!DictationHoldCut.isCut(line("ровно половина", at: 103.3, to: 109.3), by: [hold]))
        #expect(!DictationHoldCut.isCut(line("потом", at: 107, to: 110), by: [hold]))
    }

    @Test func theMarginIsThreeTenths() {
        #expect(DictationHoldCut.margin == 0.3)
        // A short line just past the release: within 0.3 s it's cut…
        #expect(DictationHoldCut.isCut(line("да", at: 106.0, to: 106.25), by: [hold]))
        // …well past it, it's the meeting's.
        #expect(!DictationHoldCut.isCut(line("да", at: 106.4, to: 106.8), by: [hold]))
        #expect(!DictationHoldCut.isCut(line("да", at: 106.0, to: 106.25), by: [hold], margin: 0))
    }

    @Test func theOtherSideIsNeverCut() {
        let remote = line("а что с бюджетом?", at: 101, to: 104, source: .systemAudio)
        #expect(!DictationHoldCut.isCut(remote, by: [hold]))
        let kept = DictationHoldCut.removing([remote, line("мой текст", at: 101, to: 104)], holds: [hold])
        #expect(kept.map(\.text) == ["а что с бюджетом?"])
    }

    @Test func aLineWithNoLengthGoesByItsStart() {
        #expect(DictationHoldCut.isCut(line("…", at: 103, to: 103), by: [hold]))
        #expect(!DictationHoldCut.isCut(line("…", at: 110, to: 110), by: [hold]))
    }

    @Test func severalHoldsAddUpOverOneLine() {
        // Each hold alone covers about a third of this line; together,
        // most of it.
        let holds = [DictationHold(startSec: 100, endSec: 103), DictationHold(startSec: 106, endSec: 109)]
        let across = line("через обе", at: 100, to: 110)
        #expect(DictationHoldCut.isCut(across, by: holds))
        #expect(!DictationHoldCut.isCut(across, by: [holds[0]]))
        #expect(!DictationHoldCut.isCut(across, by: [holds[1]]))
    }

    @Test func overlappingHoldsCountOnce() {
        let holds = [DictationHold(startSec: 100, endSec: 101), DictationHold(startSec: 100.5, endSec: 101.5)]
        let union = DictationHoldCut.merged(holds, margin: 0.3)
        #expect(union.count == 1)
        #expect(abs((union.first?.startSec ?? 0) - 99.7) < 1e-9)
        #expect(abs((union.first?.endSec ?? 0) - 101.8) < 1e-9)
        // 2.1 s of a 4.3 s line is inside the union — not most of it,
        // though the two widened holds summed would claim 3.2 s.
        #expect(!DictationHoldCut.isCut(line("длинная фраза встречи", at: 99.7, to: 104), by: holds))
    }

    @Test func anOpenHoldCutsOnUntilItsRelease() {
        let open = DictationHold(startSec: 100, endSec: .greatestFiniteMagnitude)
        #expect(DictationHoldCut.isCut(line("ещё диктую", at: 140, to: 143), by: [open]))
        #expect(!DictationHoldCut.isCut(line("до нажатия", at: 90, to: 95), by: [open]))
    }

    @Test func nothingHeldCutsNothing() {
        let lines = [line("раз", at: 1, to: 2), line("два", at: 3, to: 4, source: .systemAudio)]
        #expect(DictationHoldCut.removing(lines, holds: []) == lines)
        #expect(!DictationHoldCut.isCut(lines[0], by: []))
    }

    /// Spans are on the media clock, pauses excluded — the clock the lines
    /// are on. A meeting recorded 0…100 s, paused for a minute of wall
    /// time, then resumed: its next line is at 100 s again, and a
    /// dictation held at media 130…135 cuts only what was said then.
    @Test func pausesAreNotOnTheClock() {
        let held = DictationHold(startSec: 130, endSec: 135)
        let lines = [
            line("до паузы", at: 97, to: 100),
            line("после паузы", at: 100, to: 104),
            line("диктовка", at: 130.2, to: 134.6),
            line("снова встреча", at: 136, to: 140),
        ]
        #expect(DictationHoldCut.removing(lines, holds: [held]).map(\.text) == ["до паузы", "после паузы", "снова встреча"])
    }

    @Test func aHoldWhollyInAPauseLeavesNoSpan() {
        // The media clock stood still from the press to the release.
        #expect(DictationHoldCut.span(from: 100, to: 100) == nil)
        #expect(DictationHoldCut.span(from: 100, to: 99) == nil)
        #expect(DictationHoldCut.span(from: 100, to: 104.5) == DictationHold(startSec: 100, endSec: 104.5))
    }

    @Test func theHoldsRoundTripBesideTheRecording() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("holds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(DictationHoldStore.load(from: dir).isEmpty)
        let holds = [DictationHold(startSec: 412.5, endSec: 418.25), DictationHold(startSec: 12, endSec: 15.5)]
        DictationHoldStore.write(holds, to: dir)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("dictation-holds.json").path))
        // Read back in time order.
        #expect(DictationHoldStore.load(from: dir) == holds.sorted { $0.startSec < $1.startSec })

        // The shape the session format documents.
        let json = #"[{"startSec": 312.4, "endSec": 318.9}]"#
        try Data(json.utf8).write(to: DictationHoldStore.url(in: dir))
        #expect(DictationHoldStore.load(from: dir) == [DictationHold(startSec: 312.4, endSec: 318.9)])

        // A damaged file cuts nothing rather than failing the pass.
        try Data("not json".utf8).write(to: DictationHoldStore.url(in: dir))
        #expect(DictationHoldStore.load(from: dir).isEmpty)
    }

    @Test func theCutStaysCheapOnALongMeeting() {
        let lines = (0..<3_000).map { i in
            line("строка \(i)", at: Double(i) * 2.4, to: Double(i) * 2.4 + 2, source: i % 2 == 0 ? .microphone : .systemAudio)
        }
        let holds = (0..<30).map { i in DictationHold(startSec: Double(i) * 240, endSec: Double(i) * 240 + 6) }
        let clock = ContinuousClock()
        var kept = 0
        let took = clock.measure { kept = DictationHoldCut.removing(lines, holds: holds).count }
        #expect(kept < lines.count)
        #expect(took < .milliseconds(50))
    }
}

@MainActor
struct DictationRoutingTests {
    private func route(_ status: RecordingSession.Status, _ mode: RecordingSession.RecordingMode = .meeting,
                       purpose: DictationPurpose = .paste, isSidecar: Bool = false,
                       finishing: Bool = false) -> RecordingSession.DictationRoute {
        RecordingSession.dictationRoute(status: status, mode: mode, purpose: purpose,
                                        isSidecar: isSidecar, previousStillFinishing: finishing)
    }

    @Test func aMeetingRecordingSendsTheDictationToTheSide() {
        #expect(route(.recording, .meeting) == .sideOverRecording)
        #expect(route(.paused, .meeting) == .sideOverRecording)
    }

    @Test func aVoiceNoteRecordingDoesToo() {
        #expect(route(.recording, .voiceNote) == .sideOverRecording)
        #expect(route(.paused, .voiceNote) == .sideOverRecording)
    }

    @Test func aDictationOnThisSessionIsStillAKeyAlreadyHeld() {
        #expect(route(.recording, .dictation) == .alreadyRecording)
    }

    @Test func onlyTheDictationKeyGoesToTheSide() {
        let token = UUID()
        #expect(route(.recording, purpose: .daisyKeyHold(token)) == .alreadyRecording)
        #expect(route(.recording, purpose: .daisyKeyTap(token)) == .alreadyRecording)
    }

    @Test func theSideSessionNeverSpawnsAnother() {
        #expect(route(.recording, .dictation, isSidecar: true) == .alreadyRecording)
        #expect(route(.idle, .dictation, isSidecar: true, finishing: true) == .here)
    }

    @Test func idleAndFinishingAreAsBefore() {
        #expect(route(.idle) == .here)
        #expect(route(.finished) == .here)
        #expect(route(.failed("x")) == .here)
        #expect(route(.finished, finishing: true) == .sideWhileFinishing)
        #expect(route(.summarizing, finishing: true) == .sideWhileFinishing)
        #expect(route(.summarizing) == .ignore)
        #expect(route(.preparing) == .ignore)
        #expect(route(.stopping) == .ignore)
        // A recording with a previous one still finishing: beside the
        // recording, not refused.
        #expect(route(.recording, finishing: true) == .sideOverRecording)
    }
}
