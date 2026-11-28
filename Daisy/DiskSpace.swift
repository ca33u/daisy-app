// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  DiskSpace.swift
//  Daisy
//
//  Single source of truth for "how much room is left, and does Daisy
//  still record audio?". Three surfaces need the same answer and used
//  to each carry their own copy of the arithmetic:
//
//    • RecordingSession — decides at start() whether this session goes
//      transcript-only, and re-checks mid-recording.
//    • HomeView — the low-disk row on the onboarding card.
//    • LogReporter — the `Disk:` line in a support report.
//
//  They MUST agree. A warning on Home that says "audio is fine" while
//  the recorder has already dropped to transcript-only is worse than no
//  warning at all, and that's exactly what three separate thresholds
//  drift into.
//
//  Everything here measures "important usage" capacity, which counts
//  purgeable space — so we don't cry low-disk over space macOS would
//  free on demand.
//

import Foundation

enum DiskSpace {
    // MARK: - Thresholds

    /// Below this much free space when a recording starts → record
    /// TRANSCRIPT-ONLY, no `.caf` archives. Audio is the heavy part
    /// (~0.7 GB/hr) and would fill the disk.
    nonisolated static let recordingFloorBytes: Int64 = 3 * 1_073_741_824      // 3 GB

    /// Below this much free space MID-recording → stop both archives and
    /// keep transcribing. Lower than the start floor on purpose: once a
    /// meeting is underway, cutting audio is the last resort.
    nonisolated static let criticalFloorBytes: Int64 = 1_536 * 1_048_576      // 1.5 GB

    // MARK: - Measurement

    /// Free bytes on the volume backing `url`. nil when unqueryable —
    /// callers treat nil as "plenty" rather than blocking on a number we
    /// couldn't read.
    nonisolated static func freeBytes(at url: URL?) -> Int64? {
        guard let url else { return nil }
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// Free bytes on the volume Daisy actually writes recordings to.
    ///
    /// Not the same as the home volume: a user who pointed the sessions
    /// folder at an external disk records THERE, so measuring the boot
    /// drive would warn about the wrong volume — or stay quiet while the
    /// real target fills up. Goes through `acquireBase()` for the same
    /// reason the recorder does: the user folder is security-scoped, and
    /// reading its volume attributes needs the scope held.
    @MainActor
    static func recordingsVolumeFreeBytes() -> Int64? {
        if let ticket = SessionsFolder.acquireBase() {
            defer { ticket.release() }
            if let free = freeBytes(at: ticket.url) { return free }
        }
        // Reached when the user folder RESOLVED but its volume wouldn't
        // answer — an unmounted or misbehaving external disk. Measuring
        // the container is the useful answer there, since that's where a
        // recording would land. (`acquireBase()` handles the other
        // failure, a scope it can't acquire, by returning the container
        // itself.)
        return freeBytes(at: SessionsFolder.defaultBase())
    }
}
