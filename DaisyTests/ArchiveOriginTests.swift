//
//  ArchiveOriginTests.swift
//  DaisyTests
//
//  Each archive of a recording starts at its real place on one clock
//  (2026-10-09): the lead is the time from the recording's origin to the
//  track's first frame, and it is written once per recording.
//

import AVFoundation
import Foundation
import Testing
@testable import Daisy

// Serialized: the origin is one shared value, and parallel tests would
// overwrite each other's mark.
@Suite("Archive origin", .serialized)
struct ArchiveOriginTests {

    @Test func leadIsTimeAfterOrigin() {
        let origin: UInt64 = 1_000_000_000
        ArchiveOrigin.mark(now: origin)
        let later = origin &+ AVAudioTime.hostTime(forSeconds: 0.3)
        #expect(abs(ArchiveOrigin.leadSeconds(to: later) - 0.3) < 0.001)
    }

    @Test func noLeadBeforeOrigin() {
        let origin: UInt64 = 2_000_000_000
        ArchiveOrigin.mark(now: origin)
        #expect(ArchiveOrigin.leadSeconds(to: origin - 1) == 0)
        #expect(ArchiveOrigin.leadSeconds(to: origin) == 0)
    }

    @Test func leadTakenOncePerRecording() {
        let clock = ArchiveClockBox()
        clock.beginRecording()
        let origin = mach_absolute_time()
        ArchiveOrigin.mark(now: origin)
        let time = AVAudioTime(hostTime: origin &+ AVAudioTime.hostTime(forSeconds: 0.25))
        #expect(abs(clock.takeLead(to: time) - 0.25) < 0.001)
        #expect(clock.takeLead(to: time) == 0)
        clock.beginRecording()
        #expect(abs(clock.takeLead(to: time) - 0.25) < 0.001)
    }

    @Test func resumePadEqualisesThePauseCut() {
        let base: UInt64 = 5_000_000_000
        func host(_ seconds: Double) -> UInt64 { base &+ AVAudioTime.hostTime(forSeconds: seconds) }
        ArchiveOrigin.mark(now: base)
        // Track stopped 0.08 s before the shared pause moment, and its
        // first frame after resume came 0.03 s after the resume moment.
        ArchiveOrigin.markPause(now: host(10))
        ArchiveOrigin.markResume(now: host(20))
        let pad = ArchiveOrigin.resumePad(lastFrameEnd: host(9.92), firstFrame: host(20.03))
        #expect(abs(pad - 0.11) < 0.001)
        // Nothing written before the pause: no "before" part.
        #expect(abs(ArchiveOrigin.resumePad(lastFrameEnd: 0, firstFrame: host(20.03)) - 0.03) < 0.001)
        // A new recording clears the marks.
        ArchiveOrigin.mark(now: host(30))
        #expect(ArchiveOrigin.resumePad(lastFrameEnd: host(29), firstFrame: host(31)) == 0)
    }
}
