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
    }

    /// Seconds from the origin to `hostTime`, or 0 when there is no origin
    /// or the frame is not later than it. Never negative: a track can't
    /// start before the recording did.
    static func leadSeconds(to hostTime: UInt64) -> TimeInterval {
        guard let start = origin.withLock({ $0 }), hostTime > start else { return 0 }
        return AVAudioTime.seconds(forHostTime: hostTime - start)
    }
}
