//
//  DaisyWidgetPetalTests.swift
//  DaisyTests
//
//  The petals breathe symmetrically about the vertical axis (2026-10-09):
//  mirror-image petals share a spectrum band, so the flower doesn't look
//  as if it sways from side to side.
//

import Testing
@testable import Daisy

struct DaisyWidgetPetalTests {
    @Test func mirrorPetalsShareABand() {
        let bands = (0..<8).map { DaisyWidget.bandIndex(forPetal: $0, petalCount: 8) }
        #expect(bands == [0, 1, 2, 3, 4, 3, 2, 1])
        // Every band index is one the analyzer produces.
        #expect(bands.allSatisfy { $0 < SpectrumAnalyzer.bandCount })
    }
}
