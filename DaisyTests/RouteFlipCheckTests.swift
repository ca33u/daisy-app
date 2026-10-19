//
//  RouteFlipCheckTests.swift
//  DaisyTests
//
//  B-1 (19.10): a headset flipping to call mode and back is an event for
//  the process tap. Sound heard since the change settles it; silence
//  rebuilds the tap in place, twice in a row at most — never a move to
//  ScreenCaptureKit, whose switch restarts the archive as silence.
//

import Foundation
import Testing
@testable import Daisy

struct RouteFlipCheckTests {
    private let changed = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func soundAfterTheChangeKeepsTheTap() {
        #expect(RouteFlipCheck.decide(changedAt: changed, lastAudibleAt: changed.addingTimeInterval(4), rebuilds: 0) == .keep)
        #expect(RouteFlipCheck.decide(changedAt: changed, lastAudibleAt: changed.addingTimeInterval(4), rebuilds: 2) == .keep)
    }

    @Test func soundOnlyBeforeTheChangeCountsAsSilence() {
        // User log B: the other side heard for 49 minutes, then the flip.
        #expect(RouteFlipCheck.decide(changedAt: changed, lastAudibleAt: changed.addingTimeInterval(-60), rebuilds: 0) == .rebuildTap)
        #expect(RouteFlipCheck.decide(changedAt: changed, lastAudibleAt: nil, rebuilds: 0) == .rebuildTap)
    }

    @Test func rebuildsTwiceInARowThenLeavesIt() {
        #expect(RouteFlipCheck.decide(changedAt: changed, lastAudibleAt: nil, rebuilds: 1) == .rebuildTap)
        #expect(RouteFlipCheck.decide(changedAt: changed, lastAudibleAt: nil, rebuilds: 2) == .giveUp)
        #expect(RouteFlipCheck.maxRebuilds == 2)
    }

    @Test func theWindowOutlastsAFlipAndBack() {
        // The headset in log B came back 5 s after each flip; the check
        // must wait past that so it judges the route the call stays on.
        #expect(RouteFlipCheck.window > 5)
    }
}
