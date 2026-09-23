//
//  CaptureRestartBudgetTests.swift
//  DaisyTests
//
//  Инцидент 23.09, P0. macOS stops a ScreenCaptureKit stream every few
//  minutes on some machines; every restart worked, and after the third
//  Daisy stopped trying for the rest of the meeting. One user lost the
//  other side of eighteen meetings.
//
//  The budget is now counted over a window. These are the two shapes
//  that must come out differently.
//

import Foundation
import Testing
@testable import Daisy

@Suite("The restart budget counts a window, not a meeting")
struct CaptureRestartBudgetTests {

    /// Reproduces the incident: a stream that dies every few minutes
    /// and comes back every time. Under the old per-recording budget
    /// the fourth death ended capture for good.
    @Test func aStreamThatKeepsComingBackKeepsBeingRestarted() {
        let window = SystemAudioCapture.restartWindowForTesting
        let limit = SystemAudioCapture.maxRestartsInWindowForTesting
        var deaths: [Date] = []
        let start = Date()
        // Seven deaths, each a few minutes apart — the user's 14:00
        // meeting had them at +7, +8, +15 minutes.
        // The user's own two meetings, to the second:
        //   14:00 meeting — deaths at 14:07:06, 14:08:22, 14:15:07, 14:15:19
        //   17:00 meeting — 17:01:48, 17:03:02, 17:10:11, 17:10:22
        // Under the old budget the fourth ended capture for the rest of
        // the meeting; the user lost 15 and 11 minutes in.
        for minute in [7.10, 8.37, 15.12, 15.32, 22, 30, 37, 45] {
            let now = start.addingTimeInterval(minute * 60)
            deaths.removeAll { now.timeIntervalSince($0) > window }
            #expect(deaths.count < limit,
                    "Gave up at minute \(minute) on a stream that recovers every time")
            deaths.append(now)
        }
    }

    /// The shape the budget was written for: a stream that dies again
    /// immediately. It must still stop thrashing.
    @Test func aStreamDyingInABurstStopsBeingHammered() {
        let window = SystemAudioCapture.restartWindowForTesting
        let limit = SystemAudioCapture.maxRestartsInWindowForTesting
        var deaths: [Date] = []
        let start = Date()
        var exhausted = false
        for second in stride(from: 0, to: 60, by: 5) {
            let now = start.addingTimeInterval(Double(second))
            deaths.removeAll { now.timeIntervalSince($0) > window }
            if deaths.count >= limit { exhausted = true; break }
            deaths.append(now)
        }
        #expect(exhausted, "A stream failing every 5 s should exhaust the window")
    }

    /// The window has to be long enough that "died at +7 and +8
    /// minutes" does not read as a burst, and short enough that a
    /// genuine burst fills it.
    @Test func theWindowIsMinutesNotHours() {
        #expect(SystemAudioCapture.restartWindowForTesting >= 60)
        #expect(SystemAudioCapture.restartWindowForTesting <= 600)
    }
}
