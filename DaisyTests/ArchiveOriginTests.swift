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

    /// The archives' timeline (31.10, dictation during a recording): time
    /// since the origin less each stretch between the shared pause and
    /// resume moments — where the pads put a frame in every track.
    @Test func timelineLeavesOutThePausedStretches() {
        let base: UInt64 = 7_000_000_000
        func host(_ seconds: Double) -> UInt64 { base &+ AVAudioTime.hostTime(forSeconds: seconds) }
        func timeline(_ seconds: Double) -> Double { ArchiveOrigin.timelineSeconds(now: host(seconds)) ?? -1 }
        ArchiveOrigin.mark(now: base)
        #expect(abs(timeline(12.5) - 12.5) < 0.001)
        // Paused at 20: frozen there however long the pause lasts.
        ArchiveOrigin.markPause(now: host(20))
        #expect(abs(timeline(45) - 20) < 0.001)
        // Resumed at 50: the 30 s between the marks are not on it.
        ArchiveOrigin.markResume(now: host(50))
        #expect(abs(timeline(55) - 25) < 0.001)
        // A resume whose track failed to restart, marked again at 51: the
        // archives leave out 20…51 (the pads read the latest mark), and
        // so does the timeline.
        ArchiveOrigin.markResume(now: host(51))
        #expect(abs(timeline(55) - 24) < 0.001)
        // A second pause adds up.
        ArchiveOrigin.markPause(now: host(60))
        ArchiveOrigin.markResume(now: host(70))
        #expect(abs(timeline(80) - 39) < 0.001)
        // A new recording starts the timeline over.
        ArchiveOrigin.mark(now: host(100))
        #expect(abs(timeline(103) - 3) < 0.001)
        #expect(timeline(99) == 0)
    }
}
