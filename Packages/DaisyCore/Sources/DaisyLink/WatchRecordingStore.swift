//
//  WatchRecordingStore.swift
//  DaisyLink
//
//  Бэклог 14 Н-2: «правило Ф3-B переносится как есть». It was solved
//  once for the phone (`AudioRetention`), and solving it a second time
//  differently is how two devices end up disagreeing about whether a
//  recording is safe to delete.
//
//  The rule, in one sentence: a recording lives on the watch until the
//  phone has taken it AND said so, or until the ceiling, after which
//  storage wins. Everything below is that sentence, plus the number the
//  person sees.
//

import Foundation

/// One recording sitting on the watch, waiting for the phone.
public struct PendingRecording: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var seconds: Int
    public var bytes: Int64
    /// When `transferFile` handed it to the system. NOT a delivery:
    /// the system queues transfers for hours, and a queued file is
    /// still the only copy.
    public var handedToSystemAt: Date?
    /// When the PHONE said it has the file. This is the only thing
    /// that makes deletion safe.
    public var confirmedByPhoneAt: Date?

    public init(id: UUID = UUID(), startedAt: Date, seconds: Int, bytes: Int64,
                handedToSystemAt: Date? = nil, confirmedByPhoneAt: Date? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.seconds = seconds
        self.bytes = bytes
        self.handedToSystemAt = handedToSystemAt
        self.confirmedByPhoneAt = confirmedByPhoneAt
    }

    public var isConfirmed: Bool { confirmedByPhoneAt != nil }
}

public enum WatchRecordingStore {
    /// Same default as the phone's `AudioRetention`, and for the same
    /// reason: a week is long enough to get home to a Mac, short
    /// enough that a forgotten watch does not fill up.
    public static let defaultCeilingDays = 7

    /// What happens to each recording right now.
    public struct Sweep: Sendable, Equatable {
        /// Safe to delete: the phone has it.
        public var confirmed: [PendingRecording] = []
        /// Past the ceiling and still not confirmed. Deleting these
        /// loses audio that exists nowhere else — which is why they
        /// are returned separately and never mixed with `confirmed`.
        public var expired: [PendingRecording] = []
        /// Still waiting, still the only copy.
        public var waiting: [PendingRecording] = []
    }

    public static func sweep(_ pending: [PendingRecording], now: Date = Date(),
                             ceilingDays: Int = defaultCeilingDays) -> Sweep {
        let ceiling = now.addingTimeInterval(-Double(ceilingDays) * 86_400)
        var result = Sweep()
        for item in pending {
            if item.isConfirmed {
                result.confirmed.append(item)
            } else if item.startedAt < ceiling {
                result.expired.append(item)
            } else {
                result.waiting.append(item)
            }
        }
        return result
    }

    /// The line on the watch: how many are still the only copy, and how
    /// much room they take. Nil when nothing waits — a counter showing
    /// zero is noise on a screen this small.
    public static func waitingLine(_ pending: [PendingRecording], now: Date = Date(),
                                   ceilingDays: Int = defaultCeilingDays) -> String? {
        let sweep = sweep(pending, now: now, ceilingDays: ceilingDays)
        let stillHere = sweep.waiting + sweep.expired
        guard !stillHere.isEmpty else { return nil }
        let bytes = stillHere.reduce(Int64(0)) { $0 + $1.bytes }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return stillHere.count == 1
            ? "1 recording waiting for your phone · \(size)"
            : "\(stillHere.count) recordings waiting for your phone · \(size)"
    }

    /// 16 kHz mono int16 — the phone's format (§3.6), so nothing is
    /// converted on the way over. About 115 MB an hour.
    public static func expectedBytes(seconds: Int) -> Int64 {
        Int64(seconds) * 16_000 * 2
    }
}
