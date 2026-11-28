// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  TapRateTests.swift
//  DaisyTests
//
//  The other side's speed (24.11): buffers labelled with a rate they don't
//  come at, and everything that must not look like it.
//

import AVFoundation
import Foundation
import Testing
@testable import Daisy

@Suite("Process tap sample rate")
struct TapRateTests {
    /// Feeds `seconds` of cycles at `actual` Hz and moves to every rate
    /// the check gives; returns them.
    private func run(_ check: inout TapRateCheck, actual: Double, seconds: Double, frames: (Int) -> Int = { _ in 512 },
                     from start: Double = 0, jitter: (Int) -> Double = { _ in 0 },
                     skipping: (Int) -> Bool = { _ in false }, done: Bool = true) -> [Double] {
        var said: [Double] = []
        var position = 0
        var cycle = 0
        while Double(position) / actual < seconds {
            if !skipping(cycle),
               let rate = check.note(hostSeconds: start + Double(position) / actual + jitter(cycle), sampleTime: Double(position)) {
                said.append(rate)
                check.moved(to: rate, done: done)
            }
            position += frames(cycle)
            cycle += 1
        }
        return said
    }

    @Test("The rate to begin with is the host's, not the one reported")
    func initial() {
        // AirPods in a call, the built-in speakers as the host.
        #expect(TapRateCheck.initial(host: 48_000, aggregate: 48_000, reported: 24_000) == 48_000)
        // Measured: both formats say 48, 44.1 comes.
        #expect(TapRateCheck.initial(host: 44_100, aggregate: 44_100, reported: 48_000) == 44_100)
        #expect(TapRateCheck.initial(host: nil, aggregate: 44_100, reported: 48_000) == 44_100)
        #expect(TapRateCheck.initial(host: 0, aggregate: nil, reported: 48_000) == 48_000)
    }

    @Test("A wrong label is found, both ways", arguments: [(24_000, 48_000), (48_000, 44_100), (44_100, 48_000), (48_000, 16_000),
                                                           (16_000, 48_000), (48_000, 24_000), (96_000, 48_000)] as [(Double, Double)])
    func wrongLabel(labelled: Double, actual: Double) {
        var check = TapRateCheck(rate: labelled)
        #expect(run(&check, actual: actual, seconds: 6) == [actual])
        #expect(check.rate == actual)
    }

    @Test("A right label is left alone, with jitter and drift")
    func rightLabel() {
        var check = TapRateCheck(rate: 48_000)
        #expect(run(&check, actual: 48_000 * 1.0005, seconds: 60, jitter: { Double(($0 * 7) % 5) * 0.001 }).isEmpty)
    }

    /// Nothing is lost on the device's clock.
    @Test("Lost cycles aren't a slower rate", arguments: [2, 3, 8, 12])
    func lostCycles(every: Int) {
        var check = TapRateCheck(rate: 48_000)
        #expect(run(&check, actual: 48_000, seconds: 30, skipping: { $0 % every != 0 && every < 4 }).isEmpty)
        #expect(run(&check, actual: 48_000, seconds: 30, from: 100, skipping: { $0 % every == 1 }).isEmpty)
    }

    @Test("A wrong label is found through lost cycles and uneven ones")
    func wrongLabelWithLoss() {
        var lossy = TapRateCheck(rate: 24_000)
        #expect(run(&lossy, actual: 48_000, seconds: 10, skipping: { $0 % 90 == 40 }) == [48_000])
        var uneven = TapRateCheck(rate: 24_000)
        #expect(run(&uneven, actual: 48_000, seconds: 10, frames: { $0 % 2 == 0 ? 256 : 512 }) == [48_000])
        var long = TapRateCheck(rate: 48_000)
        #expect(run(&long, actual: 24_000, seconds: 10, frames: { _ in 4_096 }) == [24_000])
    }

    @Test("Without the HAL's time or the device's clock nothing is said")
    func noClock() {
        var check = TapRateCheck(rate: 24_000)
        for cycle in 0..<2_000 {
            #expect(check.note(hostSeconds: Double(cycle) / 93.75, sampleTime: nil) == nil)
            #expect(check.note(hostSeconds: nil, sampleTime: Double(cycle * 512)) == nil)
        }
    }

    @Test("A pause, and a clock that starts again")
    func restart() {
        var check = TapRateCheck(rate: 48_000)
        #expect(run(&check, actual: 48_000, seconds: 2.5).isEmpty)
        #expect(run(&check, actual: 48_000, seconds: 2.5, from: 2.5).isEmpty)
        #expect(run(&check, actual: 48_000, seconds: 10, from: 60).isEmpty)
    }

    @Test("The host changing its rate is followed")
    func rateChange() {
        var check = TapRateCheck(rate: 48_000)
        #expect(run(&check, actual: 48_000, seconds: 3).isEmpty)
        #expect(run(&check, actual: 44_100, seconds: 6, from: 3.05) == [44_100])
        #expect(run(&check, actual: 48_000, seconds: 6, from: 10) == [48_000])
    }

    @Test("Less than three windows, or no standard rate, changes nothing")
    func notEnough() {
        var brief = TapRateCheck(rate: 48_000)
        #expect(run(&brief, actual: 44_100, seconds: 2.5).isEmpty)
        var odd = TapRateCheck(rate: 48_000)
        #expect(run(&odd, actual: 39_000, seconds: 10).isEmpty)
    }

    @Test("A rate that can't be moved to is proposed once")
    func refused() {
        var check = TapRateCheck(rate: 24_000)
        #expect(run(&check, actual: 48_000, seconds: 30, done: false) == [48_000])
        #expect(check.rate == 24_000)
    }

    @Test("Moving: on to the new rate, or converted into the one a rebuild is held to")
    func delivery() throws {
        func format(_ rate: Double) throws -> AVAudioFormat {
            try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        }
        let free = TapDelivery(format: try format(24_000), converter: nil, outputFormat: try format(24_000), pinned: nil)
        #expect(free.move(to: 48_000))
        #expect(free.format.sampleRate == 48_000)
        #expect(free.outputFormat.sampleRate == 48_000)
        #expect(free.converter == nil)

        let held = TapDelivery(format: try format(24_000), converter: nil, outputFormat: try format(24_000), pinned: try format(24_000))
        #expect(held.move(to: 48_000))
        #expect(held.format.sampleRate == 48_000)
        #expect(held.outputFormat.sampleRate == 24_000)
        #expect(held.converter != nil)
        #expect(held.move(to: 24_000))
        #expect(held.converter == nil)
        #expect(held.format.sampleRate == 24_000)
    }
}
