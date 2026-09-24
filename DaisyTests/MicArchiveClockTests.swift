//
//  MicArchiveClockTests.swift
//  DaisyTests
//
//  24.09: a mic rebuilt mid-recording took 5.2 s to deliver again, the
//  archive went on as if no time had passed, and every later mic line
//  sat five seconds early against the other side.
//

import AVFoundation
import Foundation
import Testing
@testable import Daisy

@Suite("Mic archive keeps the wall clock")
struct MicArchiveClockTests {
    private let rate = 48_000.0

    private func time(_ seconds: Double) -> AVAudioTime {
        AVAudioTime(hostTime: 1_000_000_000 + AVAudioTime.hostTime(forSeconds: seconds), sampleTime: 0, atRate: rate)
    }

    @Test func steadyBuffersNeedNoPadding() {
        let clock = ArchiveClockBox()
        var t = 0.0
        for _ in 0..<100 {
            #expect(clock.advance(to: time(t), frames: 512) == 0)
            t += 512 / rate
        }
    }

    @Test func anOutageIsFilled() {
        let clock = ArchiveClockBox()
        _ = clock.advance(to: time(0), frames: 4800)          // 0.1 s
        let gap = clock.advance(to: time(5.3), frames: 4800)
        #expect(abs(gap - 5.2) < 0.01)
        #expect(clock.advance(to: time(5.4), frames: 4800) == 0)
    }

    @Test func aPauseIsNotAnOutage() {
        let clock = ArchiveClockBox()
        _ = clock.advance(to: time(0), frames: 4800)
        clock.reset()
        #expect(clock.advance(to: time(60), frames: 4800) == 0)
    }
}
