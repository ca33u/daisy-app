//
//  DiskSpace.swift
//  DaisyCore
//
//  Copied from daisy-app/Daisy/DiskSpace.swift (macOS Daisy 1.0.7.72,
//  2026-09-19). Thresholds and the measurement are verbatim; the Mac-only
//  `recordingsVolumeFreeBytes()` (security-scoped `SessionsFolder`) is
//  dropped — on iPhone the sessions base is always the app container, so
//  callers measure `freeBytes(at: base)` directly.
//
//  Single source of truth for "how much room is left, and does Daisy
//  still record audio?". Everything here measures "important usage"
//  capacity, which counts purgeable space — so we don't cry low-disk
//  over space the OS would free on demand.
//

import Foundation

public enum DiskSpace {
    // MARK: - Thresholds

    /// Below this much free space when a recording starts → record
    /// TRANSCRIPT-ONLY, no `.caf` archives. Audio is the heavy part
    /// (~0.7 GB/hr) and would fill the disk.
    public nonisolated static let recordingFloorBytes: Int64 = 3 * 1_073_741_824      // 3 GB

    /// Below this much free space MID-recording → stop both archives and
    /// keep transcribing. Lower than the start floor on purpose: once a
    /// meeting is underway, cutting audio is the last resort.
    public nonisolated static let criticalFloorBytes: Int64 = 1_536 * 1_048_576      // 1.5 GB

    // MARK: - Measurement

    /// Free bytes on the volume backing `url`. nil when unqueryable —
    /// callers treat nil as "plenty" rather than blocking on a number we
    /// couldn't read.
    public nonisolated static func freeBytes(at url: URL?) -> Int64? {
        guard let url else { return nil }
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}
