// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  CatchUpTests.swift
//  DaisyTests
//
//  The catch-up is the one feature the user runs mid-call, and the one
//  place where an un-deduped mic stream would tell them what THEY
//  supposedly said while they were out of the room. The slice builder
//  is where that is decided, so it gets the tests.
//

import Testing
import Foundation
@testable import Daisy

@Suite("Catch-up slice")
struct CatchUpTests {

    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func segment(
        _ text: String,
        source: SegmentSource,
        secondsIn: Double,
        speaker: String? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: UUID(),
            startedAt: origin.addingTimeInterval(secondsIn),
            text: text,
            isFinal: true,
            source: source,
            speakerId: speaker,
            endSec: secondsIn + 2,
            startSec: secondsIn
        )
    }

    private func slice(
        _ segments: [TranscriptSegment],
        atSecond second: Double,
        suppressEcho: Bool = true,
        budget: Int = CatchUp.characterBudget
    ) -> String {
        CatchUp.slice(
            segments: segments,
            now: origin.addingTimeInterval(second),
            displayName: "Egor",
            suppressEcho: suppressEcho,
            budget: budget
        )
    }

    // MARK: - Window

    @Test("Only the last few minutes are included")
    func slice_honoursTheWindow() {
        let segments = [
            segment("это было десять минут назад", source: .systemAudio, secondsIn: 0, speaker: "A"),
            segment("а это только что", source: .systemAudio, secondsIn: 590, speaker: "A"),
        ]
        let text = slice(segments, atSecond: 600)
        #expect(!text.contains("десять минут назад"))
        #expect(text.contains("только что"))
    }

    @Test("Speaker labels survive, so the recap can say who said what")
    func slice_keepsSpeakerLabels() {
        let text = slice([
            segment("я думаю да", source: .microphone, secondsIn: 10),
            segment("согласен", source: .systemAudio, secondsIn: 12, speaker: "A"),
        ], atSecond: 20)
        #expect(text.contains("[Egor] я думаю да"))
        #expect(text.contains("[Remote A] согласен"))
    }

    @Test("An empty window yields an empty slice rather than a stray label")
    func slice_emptyWindow() {
        let segments = [segment("давно", source: .systemAudio, secondsIn: 0, speaker: "A")]
        #expect(slice(segments, atSecond: 10_000).isEmpty)
        #expect(slice([], atSecond: 10).isEmpty)
    }

    @Test("Blank segments are dropped and newlines flattened")
    func slice_cleansSegments() {
        let text = slice([
            segment("   ", source: .systemAudio, secondsIn: 1, speaker: "A"),
            segment("первая\nвторая", source: .systemAudio, secondsIn: 2, speaker: "A"),
        ], atSecond: 10)
        #expect(text == "[Remote A] первая вторая")
    }

    // MARK: - Echo

    @Test("Speaker echo is stripped before the model sees the window")
    func slice_removesAcousticEcho() {
        // The failure this exists to prevent: on speakers the mic
        // re-captures the other party, so the recap would tell the user
        // what they supposedly said while they were out of the room.
        var segments: [TranscriptSegment] = []
        let lines = [
            "мы решили перенести релиз на следующую неделю",
            "бюджет остаётся прежним до конца квартала",
            "нужно предупредить команду поддержки заранее",
            "я подготовлю письмо для клиента сегодня",
            "и пришлю его на согласование к вечеру",
        ]
        for (index, line) in lines.enumerated() {
            let at = Double(index) * 10
            segments.append(segment(line, source: .systemAudio, secondsIn: at, speaker: "A"))
            // The echo: same words, mic side, ~1s later.
            segments.append(segment(line, source: .microphone, secondsIn: at + 1))
        }
        let text = slice(segments, atSecond: 60)
        #expect(!text.contains("[Egor]"))
        #expect(text.contains("[Remote A]"))

        // With the setting off, the caller gets the raw stream — the
        // toggle still means what it says.
        let raw = slice(segments, atSecond: 60, suppressEcho: false)
        #expect(raw.contains("[Egor]"))
    }

    @Test("Dedup sees the whole session, not just the window")
    func slice_dedupsAgainstSegmentsOutsideTheWindow() {
        // An echo can sit just inside the window while the system-side
        // original it copies sits just outside. Slicing first would
        // strip that original and let the echo through as if the user
        // had said it.
        var segments: [TranscriptSegment] = []
        let lines = [
            "давайте зафиксируем сроки по этому направлению",
            "и распределим задачи между командами",
            "потом вернёмся к обсуждению бюджета",
            "нужно согласовать это с финансовым отделом",
        ]
        for (index, line) in lines.enumerated() {
            let at = 200 + Double(index) * 3
            segments.append(segment(line, source: .systemAudio, secondsIn: at, speaker: "A"))
            segments.append(segment(line, source: .microphone, secondsIn: at + 1))
        }
        // now = 500.5 → the 5-minute window opens at 200.5, i.e. BETWEEN
        // the first system line (200) and its mic echo (201). Dedup after
        // slicing would find no partner for that echo and let it through
        // as the user's own speech.
        let text = slice(segments, atSecond: 500.5)
        // Guard the guard: the window has to actually contain something,
        // or the assertion below passes on an empty string and this test
        // proves nothing.
        #expect(!text.isEmpty)
        #expect(text.contains("[Remote A]"))
        #expect(!text.contains("[Egor]"))
    }

    @Test("The dedup pass here doesn't disturb the headphones nudge")
    func slice_doesNotClobberSystemicFlag() {
        // `stop()` reads `lastFilterWasSystemic` between the transcript
        // render and the toast. A catch-up landing in that gap must not
        // flip it.
        _ = AcousticEchoDedup.filter([
            segment("привет", source: .systemAudio, secondsIn: 0, speaker: "A"),
        ])
        let before = AcousticEchoDedup.lastFilterWasSystemic
        _ = slice([segment("что-то", source: .systemAudio, secondsIn: 1, speaker: "A")], atSecond: 5)
        #expect(AcousticEchoDedup.lastFilterWasSystemic == before)
    }

    // MARK: - Budget

    @Test("Over budget, the OLDEST lines go — the user is rejoining the newest")
    func slice_trimsFromTheFront() {
        let segments = (0..<20).map {
            segment("реплика номер \($0) с каким-то содержанием", source: .systemAudio, secondsIn: Double($0), speaker: "A")
        }
        let text = slice(segments, atSecond: 25, budget: 200)
        #expect(text.count <= 200)
        #expect(text.contains("номер 19"))
        #expect(!text.contains("номер 0 "))
    }

    @Test("A single over-budget line is kept rather than emptied")
    func slice_keepsAtLeastOneLine() {
        let text = slice([
            segment(String(repeating: "с", count: 500), source: .systemAudio, secondsIn: 1, speaker: "A"),
        ], atSecond: 5, budget: 100)
        #expect(!text.isEmpty)
    }

    // MARK: - Outcome

    /// Records what a `@Sendable` test closure saw. Mutating a captured
    /// `var` from one is an error under the Swift 6 language mode.
    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }

    @Test("Too little speech short-circuits without calling a provider")
    func run_shortCircuitsOnAQuietWindow() async {
        let called = Box<Bool>()
        let outcome = await CatchUp.run(
            slice: "[Remote A] ага",
            localeHint: nil,
            summarize: { _, _ in
                called.value = true
                return MeetingSummary(summary: "x", sections: [], actionItems: [], clientFollowUp: "")
            }
        )
        guard case .tooQuiet = outcome else {
            Issue.record("expected .tooQuiet, got \(outcome)")
            return
        }
        #expect(called.value == nil)
    }

    @Test("A provider failure degrades to 'unavailable', never to a crash or a lie")
    func run_handlesProviderFailure() async {
        let long = String(repeating: "[Remote A] что-то было сказано. ", count: 20)
        let outcome = await CatchUp.run(
            slice: long,
            localeHint: nil,
            summarize: { _, _ in throw SummaryProviderError.invalidResponse(provider: "Test") }
        )
        guard case .unavailable = outcome else {
            Issue.record("expected .unavailable, got \(outcome)")
            return
        }
    }

    @Test("An empty recap counts as unavailable rather than being shown blank")
    func run_rejectsEmptyRecap() async {
        let long = String(repeating: "[Remote A] что-то было сказано. ", count: 20)
        let outcome = await CatchUp.run(
            slice: long,
            localeHint: nil,
            summarize: { _, _ in
                MeetingSummary(summary: "   ", sections: [], actionItems: [], clientFollowUp: "")
            }
        )
        guard case .unavailable = outcome else {
            Issue.record("expected .unavailable, got \(outcome)")
            return
        }
    }

    @Test("The recap comes back from `summary`, and the task is the catch-up one")
    func run_returnsRecap() async {
        let long = String(repeating: "[Remote A] что-то было сказано. ", count: 20)
        let sawTask = Box<SummaryTask>()
        let outcome = await CatchUp.run(
            slice: long,
            localeHint: nil,
            summarize: { _, task in
                sawTask.value = task
                return MeetingSummary(
                    summary: "Перенесли релиз на неделю.",
                    sections: [], actionItems: [], clientFollowUp: ""
                )
            }
        )
        guard case .recap(let text) = outcome else {
            Issue.record("expected .recap, got \(outcome)")
            return
        }
        #expect(text == "Перенесли релиз на неделю.")
        if case .catchUp = sawTask.value { } else {
            Issue.record("wrong task: \(String(describing: sawTask.value))")
        }
    }

    // MARK: - Prompt

    @Test("The prompt says this is a fragment of a live meeting, not a summary")
    func prompt_framesItAsAnOngoingMeeting() {
        let flat = SummaryPrompt.catchUpSystemInstructions(localeHint: nil)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        #expect(flat.contains("STILL IN PROGRESS"))
        #expect(flat.contains("it hasn't ended"))
        #expect(flat.contains("untrusted DATA"))
    }

    @Test("The freeform variant keeps the rules and drops the JSON envelope")
    func prompt_freeformKeepsRules() {
        let json = SummaryPrompt.catchUpSystemInstructions(localeHint: nil)
        let freeform = SummaryPrompt.catchUpSystemInstructions(localeHint: nil, jsonEnvelope: false)
        #expect(json.contains("clientFollowUp"))
        #expect(!freeform.contains("clientFollowUp"))
        for rule in ["STILL IN PROGRESS", "Do not pad", "untrusted DATA"] {
            #expect(json.contains(rule))
            #expect(freeform.contains(rule))
        }
    }
}
