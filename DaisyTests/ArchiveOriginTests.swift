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
}
