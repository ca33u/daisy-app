// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  SessionAudioTimelineTests.swift
//  DaisyTests
//

import Testing
@testable import Daisy

@Suite("Stored audio playback timeline")
struct SessionAudioTimelineTests {
    @Test("Maps a continuous time to rotated audio parts")
    func mapsAcrossParts() {
        let timeline = SessionAudioTimeline(durations: [10, 20, 5])

        #expect(timeline.totalDuration == 35)
        #expect(timeline.location(for: 0) == .init(partIndex: 0, localTime: 0))
        #expect(timeline.location(for: 9) == .init(partIndex: 0, localTime: 9))
        #expect(timeline.location(for: 10) == .init(partIndex: 1, localTime: 0))
        #expect(timeline.location(for: 29) == .init(partIndex: 1, localTime: 19))
        #expect(timeline.location(for: 30) == .init(partIndex: 2, localTime: 0))
        #expect(timeline.location(for: 99) == .init(partIndex: 2, localTime: 5))
    }

    @Test("Clamps negative seek time")
    func clampsNegativeTime() {
        let timeline = SessionAudioTimeline(durations: [4])
        #expect(timeline.location(for: -5) == .init(partIndex: 0, localTime: 0))
    }
}
