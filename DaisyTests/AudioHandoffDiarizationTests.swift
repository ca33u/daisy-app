//
//  AudioHandoffDiarizationTests.swift
//  DaisyTests
//
//  26.09: a phone session whose voices the phone told apart is not
//  diarized again when its audio reaches the Mac.
//

import Foundation
import Testing
@testable import Daisy

@Suite("Audio handoff: the phone's diarization stands")
struct AudioHandoffDiarizationTests {
    @Test func aPhoneDiarizedSessionIsLeftAlone() {
        let md = "---\ndaisy_origin: iphone\ndaisy_speaker_map: {}\ndaisy_diarization: true\n---\n\n## Transcript\n"
        #expect(AudioHandoffServer.phoneDiarized(markdown: md))
    }

    @Test func aSessionWithoutItIsDiarizedAsBefore() {
        #expect(!AudioHandoffServer.phoneDiarized(markdown: "---\ndaisy_origin: iphone\ndaisy_speaker_map: {}\n---\n"))
        #expect(!AudioHandoffServer.phoneDiarized(markdown: "---\ndaisy_origin: iphone\ndaisy_diarization: false\n---\n"))
        #expect(!AudioHandoffServer.phoneDiarized(markdown: "no frontmatter at all"))
    }
}
