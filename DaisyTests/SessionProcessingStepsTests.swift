//
//  SessionProcessingStepsTests.swift
//  DaisyTests
//
//  The card's step list, the no-speech summary guard and the
//  re-transcribe message (31.10): a 79-minute meeting recorded with live
//  transcription off ran its final pass under a card that offered
//  Summarize, got summarized from 80 screenshot links, renamed after
//  that summary, and its Re-transcribe said to finish a recording that
//  wasn't running.
//

import Foundation
import Testing
@testable import Daisy

@Suite("Processing steps")
@MainActor
struct SessionProcessingStepsTests {
    private let everything = ProcessingPlan(voices: true, namesAndTerms: true, screenText: true, summary: true)

    @Test("steps run in the pipeline's order; a long meeting's names and terms follow its summary")
    func order() {
        #expect(everything.steps == [.transcription, .voices, .namesAndTerms, .screenText, .summary])
        var long = everything
        long.namesAfterSummary = true
        #expect(long.steps == [.transcription, .voices, .screenText, .summary, .namesAndTerms])
    }

    @Test("a step that won't run isn't listed")
    func absentSteps() {
        let plan = ProcessingPlan(voices: false, namesAndTerms: false, screenText: false, summary: false)
        #expect(plan.steps == [.transcription])
        let noScreens = ProcessingPlan(voices: true, namesAndTerms: false, screenText: false, summary: true)
        #expect(noScreens.steps == [.transcription, .voices, .summary])
    }

    @Test("transcribing: its percent, everything else waits")
    func transcribing() {
        let rows = everything.rows(at: .transcribing(42))
        #expect(rows.map(\.state) == [.running(42), .waiting, .waiting, .waiting, .waiting])
        // Nothing reported yet (a queue job loading its model).
        #expect(everything.rows(at: nil).first?.state == .running(nil))
        #expect(everything.rows(at: .transcribing(nil)).first?.state == .running(nil))
    }

    @Test("past the final pass the voices are done with it; the running step has a spinner")
    func polishing() {
        let rows = everything.rows(at: .polishing)
        #expect(rows.map(\.state) == [.done, .done, .running(nil), .waiting, .waiting])
    }

    @Test("a long meeting summarizing: the screens are done, names and terms still wait")
    func longMeetingSummary() {
        var long = everything
        long.namesAfterSummary = true
        let rows = long.rows(at: .summarizing)
        #expect(rows.map(\.step) == [.transcription, .voices, .screenText, .summary, .namesAndTerms])
        #expect(rows.map(\.state) == [.done, .done, .done, .running(nil), .waiting])
        #expect(long.rows(at: .polishing).map(\.state) == [.done, .done, .done, .done, .running(nil)])
    }

    @Test("a stage the plan left out still moves the others by its place")
    func stageOutsidePlan() {
        let plan = ProcessingPlan(voices: true, namesAndTerms: false, screenText: true, summary: true)
        #expect(plan.rows(at: .polishing).map(\.state) == [.done, .done, .waiting, .waiting])
    }

    @Test("notes: Low Power and the draft while transcribing, and the draft only when there is one")
    func notes() {
        #expect(ProcessingPlan.notes(stage: .transcribing(10), lowPowerMode: true, hasDraft: true) == [.lowPower, .draftBelow])
        #expect(ProcessingPlan.notes(stage: .transcribing(10), lowPowerMode: false, hasDraft: false).isEmpty)
        #expect(ProcessingPlan.notes(stage: .summarizing, lowPowerMode: true, hasDraft: true).isEmpty)
    }

    @Test("stages land only on a session being processed, and go with it")
    func storeGate() {
        let store = SessionStore.shared
        let id = "test-processing-\(UUID().uuidString)"
        store.setFinalizeStage(.polishing, for: id)
        #expect(store.finalizeStages[id] == nil)
        store.beginProcessing(id, plan: everything)
        defer { store.endProcessing(id) }
        #expect(store.isProcessing(id))
        store.setFinalizeStage(.readingScreens, for: id)
        #expect(store.finalizeStages[id] == .readingScreens)
        store.endProcessing(id)
        #expect(!store.isProcessing(id))
        #expect(store.finalizeStages[id] == nil)
    }
}

@Suite("Transcript speech")
struct TranscriptSpeechTests {
    /// Egor's meeting at Stop with live transcription off.
    private let linksOnly = """
    # Meeting 31 Oct

    > recorded 31 Oct 2026 · 79 min

    ## Screenshots

    ![0:42](/Users/x/Desktop/Meets/Daisy/Sessions/s/screenshots/0001.jpg)

    ![1:12](/Users/x/Desktop/Meets/Daisy/Sessions/s/screenshots/0002.jpg)

    ## Marked moments
    - **[0:42]** — ![0:42](/Users/x/screenshots/0001.jpg)

    ## Transcript

    """

    @Test("screenshot links, headings and an empty Transcript are no speech")
    func linksAreNotSpeech() {
        #expect(!TranscriptSpeech.hasSpeech(linksOnly))
        #expect(TranscriptSpeech.spokenText(linksOnly).isEmpty)
        #expect(!TranscriptSpeech.hasSpeech(""))
        #expect(!TranscriptSpeech.hasSpeech(linksOnly + "_No speech detected._\n"))
    }

    @Test("a stamped line is speech, stamp removed")
    func stampedLine() {
        let text = linksOnly + "**[0:07 · Alex]** Let's go through the roadmap.\n"
        #expect(TranscriptSpeech.hasSpeech(text))
        #expect(TranscriptSpeech.spokenText(text) == "Let's go through the roadmap.")
    }

    @Test("finalize's in-memory lines, and the screen text and moments appended for the summary")
    func summaryInput() {
        #expect(TranscriptSpeech.hasSpeech("[Me] Hello there\n\n[Remote A] Hi"))
        #expect(TranscriptSpeech.spokenText("[Me] Hello there") == "Hello there")
        let noSpeech = "\n\n[Content shared on screen during the meeting — text extracted from slides/documents shown, not spoken:]\nQ3 revenue up 12%\n\n[The participant flagged these timecodes as worth remembering while the meeting was happening: 0:42]"
        #expect(!TranscriptSpeech.hasSpeech(noSpeech))
        #expect(!TranscriptSpeech.hasSpeech(linksOnly + noSpeech))
        // Whisper's own bracketed tag at the end of a spoken line.
        #expect(TranscriptSpeech.spokenText("[Remote A] Yes I agree [laughs]") == "Yes I agree [laughs]")
    }

    @Test("a CRLF file reads the same as an LF one")
    func crlf() {
        let lf = linksOnly + "**[0:07 · Alex]** Let's go through the roadmap.\n"
        #expect(TranscriptSpeech.hasSpeech(lf.replacingOccurrences(of: "\n", with: "\r\n")))
        #expect(!TranscriptSpeech.hasSpeech(linksOnly.replacingOccurrences(of: "\n", with: "\r\n")))
    }

    @Test("the screen text section after the transcript isn't speech; a text note's own heading is")
    func sections() {
        let screens = linksOnly + "\n## Shared on screen\n\nQ3 revenue up 12%\n"
        #expect(!TranscriptSpeech.hasSpeech(screens))
        let note = "# Ideas\n\n## Transcript\n\n## Why\nPeople decline when they have nothing recorded yet.\n"
        #expect(TranscriptSpeech.hasSpeech(note))
    }
}

@Suite("No-speech summary guard")
@MainActor
struct NoSpeechSummaryGuardTests {
    @Test("a transcript of links gets no summary and a reason, without the provider")
    func refuses() async {
        let summarizer = Summarizer.shared
        let result = await summarizer.summarize(
            transcript: "## Screenshots\n\n![0:42](/tmp/s/screenshots/0001.jpg)\n\n## Transcript\n\n",
            title: "Meeting", localeHint: "en")
        #expect(result == nil)
        #expect(summarizer.lastError == Summarizer.noSpeechReason)
        #expect(summarizer.lastFailureCause == nil)
        #expect(!summarizer.isSummarizing)
    }

    @Test("a few spoken words are still the silent-capture notice, judged on speech alone")
    func silentNotice() async {
        // Links used to outvote the silence: three words each.
        let links = (1...20).map { "![0:\($0)](/tmp/s/screenshots/\($0).jpg)" }.joined(separator: "\n\n")
        let transcript = "## Screenshots\n\n\(links)\n\n## Transcript\n\n**[0:05 · Me]** Hello.\n"
        let result = await Summarizer.shared.summarize(transcript: transcript, title: "Meeting", localeHint: "en")
        #expect(result == .noSpeechCaptured)
    }
}

@Suite("Re-transcribe gate")
struct RetranscribeGateTests {
    @Test("this meeting still processing says so, whatever else is running")
    func thisSession() {
        #expect(SessionAudioProcessing.blockReason(processingThisSession: true, busy: true, recordingOrFinalizeActive: true) == .stillProcessing)
        #expect(SessionAudioProcessing.blockReason(processingThisSession: true, busy: false, recordingOrFinalizeActive: false) == .stillProcessing)
    }

    @Test("another recording or job keeps its own message; nothing running, nothing to say")
    func otherWork() {
        #expect(SessionAudioProcessing.blockReason(processingThisSession: false, busy: false, recordingOrFinalizeActive: true) == .recordingActive)
        #expect(SessionAudioProcessing.blockReason(processingThisSession: false, busy: true, recordingOrFinalizeActive: true) == .busy)
        #expect(SessionAudioProcessing.blockReason(processingThisSession: false, busy: false, recordingOrFinalizeActive: false) == nil)
    }

    @Test("the message names the meeting, not a recording")
    func message() {
        #expect(ProcessingError.stillProcessing.errorDescription == "Daisy is still processing this meeting — wait until it finishes.")
        #expect(ProcessingError.recordingActive.errorDescription != ProcessingError.stillProcessing.errorDescription)
    }
}
