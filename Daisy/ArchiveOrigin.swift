//
//  ArchiveOrigin.swift
//  Daisy
//
//  One clock for every archive of a recording (2026-10-09). The microphone
//  and the system audio each start their archive at their own first frame,
//  and the system audio starts a fraction of a second later (one session:
//  0.27–0.31 s). Mixed or played together, the two then drift apart.
//
//  The recording marks its start here, before the first track starts. Each
//  track, when its archive gets its first frame, pads leading silence for
//  the time between the origin and that frame. Files written this way line
//  up on the wall clock, so the export, the final transcription pass and
//  the quotes all read the same timeline.
//

import AVFoundation
import Foundation
import os

nonisolated enum ArchiveOrigin {
    private static let origin = OSAllocatedUnfairLock<UInt64?>(initialState: nil)

    /// Call once, just before the first track is started.
    static func mark(now: UInt64 = mach_absolute_time()) {
        origin.withLock { $0 = now }
        pauseResume.withLock { $0 = nil }
        pausedTotal.withLock { $0 = 0 }
    }

    /// Every stretch between a pause moment and its resume moment so far:
    /// what the archives' timeline leaves out (`timelineSeconds`).
    private static let pausedTotal = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

    /// Where a frame captured at `now` sits on every archive of the
    /// recording: seconds since the origin, less each paused stretch
    /// between the shared pause and resume moments — the lead and the
    /// resume pads put each track's frames exactly there. Frozen at the
    /// pause moment while paused. The clock the final pass, a
    /// retranscribe and crash recovery date their lines on (31.10: what a
    /// dictation held during the recording is cut on). `nil` before any
    /// recording marked an origin.
    static func timelineSeconds(now: UInt64 = mach_absolute_time()) -> TimeInterval? {
        guard let start = origin.withLock({ $0 }) else { return nil }
        var end = now
        if let marks = pauseResume.withLock({ $0 }), marks.resume == 0 { end = marks.pause }
        guard end > start else { return 0 }
        return max(0, AVAudioTime.seconds(forHostTime: end - start) - pausedTotal.withLock { $0 })
    }

    /// The pause and resume moments shared by every track (2026-10-09).
    /// Each track stops and restarts with its own latency, so a pause cut
    /// a slightly different stretch out of each archive: measured +50 ms
    /// of drift between the tracks per pause. With one pause moment (both
    /// tracks already stopped) and one resume moment (neither restarted
    /// yet), each track pads its own difference and the cut is the same.
    private static let pauseResume = OSAllocatedUnfairLock<(pause: UInt64, resume: UInt64)?>(initialState: nil)

    /// Call after every track has paused.
    static func markPause(now: UInt64 = mach_absolute_time()) {
        pauseResume.withLock { $0 = (now, 0) }
    }

    /// Call before any track resumes.
    static func markResume(now: UInt64 = mach_absolute_time()) {
        let paused = pauseResume.withLock { state -> TimeInterval in
            guard let marks = state else { return 0 }
            state = (marks.pause, now)
            // The archives leave out pause → the LATEST resume (the pads
            // read these marks): a resume whose track failed to restart,
            // marked again later, moves that end, and the timeline with it.
            let from = marks.resume == 0 ? marks.pause : marks.resume
            guard now > from else { return 0 }
            return AVAudioTime.seconds(forHostTime: now - from)
        }
        pausedTotal.withLock { $0 += paused }
    }

    /// Silence a track writes at its first frame after a resume: from its
    /// last frame to the pause moment, plus from the resume moment to this
    /// frame. Each part is normally a stop/start latency; each is filled
    /// only up to 5 s, so a track that was silent for longer (a failed
    /// resume, a device fault) doesn't gain minutes of padding.
    static func resumePad(lastFrameEnd: UInt64, firstFrame: UInt64) -> TimeInterval {
        guard let marks = pauseResume.withLock({ $0 }), marks.resume > 0 else { return 0 }
        let cap: TimeInterval = 5
        var pad: TimeInterval = 0
        if lastFrameEnd > 0, marks.pause > lastFrameEnd {
            pad += min(cap, AVAudioTime.seconds(forHostTime: marks.pause - lastFrameEnd))
        }
        if firstFrame > marks.resume {
            pad += min(cap, AVAudioTime.seconds(forHostTime: firstFrame - marks.resume))
        }
        return pad
    }

    /// Seconds from the origin to `hostTime`, or 0 when there is no origin
    /// or the frame is not later than it. Never negative: a track can't
    /// start before the recording did.
    static func leadSeconds(to hostTime: UInt64) -> TimeInterval {
        guard let start = origin.withLock({ $0 }), hostTime > start else { return 0 }
        return AVAudioTime.seconds(forHostTime: hostTime - start)
    }
}
