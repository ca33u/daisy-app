//
//  SoundEffectsTests.swift
//  DaisyTests
//
//  Daisy's own dictation cues ship inside the app (31.10, «Капля»).
//

import Foundation
import Testing
@testable import Daisy

struct SoundEffectsTests {
    @Test("The dictation drops are in the app bundle", arguments: ["DaisyDropStart", "DaisyDropDone"])
    func bundled(name: String) {
        let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: name, withExtension: "wav")
        #expect(url != nil)
    }
}
