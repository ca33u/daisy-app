//
//  RecordingYieldTests.swift
//  DaisyTests
//
//  A recording that starts while stored audio is being transcribed
//  stops that job instead of being refused (19.10, user log A). The
//  toast names the job the way its owner will bring it back; the
//  sheet's own job gets no toast from the recording — the sheet speaks.
//

import Foundation
import Testing
@testable import Daisy

@MainActor
struct RecordingYieldTests {
    @Test func noticeNamesTheJobAndHowItComesBack() {
        #expect(SessionAudioProcessing.interruptionNotice(for: YieldedJob(title: "Weekly sync", kind: .finishing))
                == "Finishing “Weekly sync” is paused — it continues after the recording.")
        #expect(SessionAudioProcessing.interruptionNotice(for: YieldedJob(title: "Interview 3", kind: .transcribing))
                == "Transcribing “Interview 3” is paused — it continues after the recording.")
        #expect(SessionAudioProcessing.interruptionNotice(for: YieldedJob(title: "Lecture", kind: .interactive)) == nil)
    }

    @Test func nothingToYieldWhenIdle() {
        let processing = SessionAudioProcessing.shared
        #expect(processing.activeJob == nil)
        #expect(processing.yieldToRecording() == nil)
        // No job, no hold: the queue must not see a phantom recording.
        #expect(!processing.yieldingToRecording)
        processing.yieldToRecordingEnded()
        #expect(!processing.yieldingToRecording)
    }
}
