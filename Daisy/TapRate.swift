//
//  TapRate.swift
//  Daisy
//
//  What sample rate a process tap's buffers are really at.
//
//  The IOProc is driven by the aggregate's clock, its host device's, and
//  the buffers come at that device's rate. The formats the HAL reports say
//  otherwise: `kAudioTapPropertyFormat` gives a rate of its own, and the
//  aggregate's input stream repeats it. Measured 24.11 on macOS 27: both
//  say 48 kHz and 44 100 frames a second come, the host's nominal rate. A
//  person's log the same day (macOS 26.0.1): AirPods in a call, 24 kHz
//  said, 48 from the built-in speakers. Up to and including 1.0.8.56 what
//  was said was believed, so the other side was recorded at the wrong
//  speed: 9 % fast in the first case; at half speed in the second, where
//  Whisper wrote Portuguese for it.
//
//  So the host's nominal rate is taken, and the device's clock is watched
//  from then on.
//

import Foundation

/// Watches the device's clock against the HAL's time, and says when it
/// runs at another rate than buffers are labelled with: the host's was
/// changed, or the nominal one wasn't true. Confined to the tap's IO queue.
///
/// The clock rather than a count of frames: cycles the system loses under
/// load leave the clock right and the count short.
nonisolated struct TapRateCheck {
    /// The rate buffers are labelled with now.
    private(set) var rate: Double

    private var windowStart: (time: Double, sampleTime: Double)?
    private var last: (time: Double, sampleTime: Double)?
    /// Another rate, and how many windows running have measured it.
    private var suspect: (rate: Double, windows: Int)?
    /// A rate the caller couldn't move to; not proposed again.
    private var refused: Double?

    /// Seconds in a window: a millisecond of jitter is a tenth of a percent.
    static let window: Double = 1
    /// Windows running that have to agree. A wrong change is worse than a
    /// late one.
    static let windows = 3
    /// How far a clock may be from the rate it is called by. The nearest
    /// two rates in use, 44.1 and 48 kHz, are 8 % apart.
    static let tolerance = 0.015
    static let standard: [Double] = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000,
                                     44_100, 48_000, 88_200, 96_000, 176_400, 192_000]

    init(rate: Double) { self.rate = rate }

    /// The rate to label buffers with when IO starts.
    static func initial(host: Double?, aggregate: Double?, reported: Double) -> Double {
        [host, aggregate].compactMap { $0 }.first { $0 > 0 } ?? reported
    }

    /// One IO cycle: the HAL's time for its first frame and that frame's
    /// position on the device's clock; nil for either says nothing.
    /// Returns a rate to move to; `rate` stays until `moved`.
    mutating func note(hostSeconds: Double?, sampleTime: Double?) -> Double? {
        guard let hostSeconds, let sampleTime, hostSeconds.isFinite, sampleTime.isFinite else {
            startOver()
            return nil
        }
        let now = (time: hostSeconds, sampleTime: sampleTime)
        defer { last = now }
        // Time or the clock went back, or stood still for a window and
        // more: another run of the device.
        if let last, now.time <= last.time || now.sampleTime <= last.sampleTime
            || now.time - last.time > Self.window { startOver() }
        guard let start = windowStart else {
            windowStart = now
            return nil
        }
        let elapsed = now.time - start.time
        guard elapsed >= Self.window else { return nil }
        let measured = (now.sampleTime - start.sampleTime) / elapsed
        windowStart = now
        guard let other = Self.standard.min(by: { abs($0 - measured) < abs($1 - measured) }),
              abs(measured / other - 1) <= Self.tolerance,
              abs(other / rate - 1) > Self.tolerance, other != refused else {
            suspect = nil
            return nil
        }
        let windows = suspect?.rate == other ? (suspect?.windows ?? 0) + 1 : 1
        suspect = (other, windows)
        guard windows >= Self.windows else { return nil }
        suspect = nil
        return other
    }

    /// The answer to a rate `note` gave: buffers are labelled with it now,
    /// or that can't be done.
    mutating func moved(to rate: Double, done: Bool) {
        if done { self.rate = rate } else { refused = rate }
    }

    private mutating func startOver() {
        windowStart = nil
        suspect = nil
    }
}
