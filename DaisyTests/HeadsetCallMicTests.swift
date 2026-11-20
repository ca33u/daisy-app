//
//  HeadsetCallMicTests.swift
//  DaisyTests
//
//  The microphone choice during a call on a Bluetooth headset
//  (`HeadsetCallMic`, field log 19.11): which headset counts, and when a
//  running recording moves onto it or is offered back to the usual
//  choice. Device ids are plain numbers here; nothing touches CoreAudio.
//

import CoreAudio
import Testing
@testable import Daisy

struct HeadsetCallMicTests {
    private let builtIn: AudioDeviceID = 78
    private let airPods: AudioDeviceID = 112
    private let otherHeadset: AudioDeviceID = 140

    // MARK: - Call mode

    @Test func callModeRatesAndMusicModeRates() {
        #expect(HeadsetCallMic.isCallModeRate(8_000))
        #expect(HeadsetCallMic.isCallModeRate(16_000))
        #expect(HeadsetCallMic.isCallModeRate(24_000))
        #expect(HeadsetCallMic.isCallModeRate(32_000))
        #expect(!HeadsetCallMic.isCallModeRate(44_100))
        #expect(!HeadsetCallMic.isCallModeRate(48_000))
        #expect(!HeadsetCallMic.isCallModeRate(0))
    }

    // MARK: - Which headsets other processes record from

    @Test func aProcessRecordingOnlyTheHeadsetCounts() {
        #expect(HeadsetCallMic.recordedHeadsets(inputLists: [[airPods]], headsets: [airPods]) == [airPods])
    }

    /// A voice-processing call on the built-in mic with sound in the
    /// AirPods lists both: it can't say which one it records from.
    @Test func aProcessListingTwoInputCapableDevicesDoesNotCount() {
        #expect(HeadsetCallMic.recordedHeadsets(inputLists: [[builtIn, airPods]], headsets: [airPods]).isEmpty)
    }

    @Test func aDeviceListedTwiceCountsOnce() {
        #expect(HeadsetCallMic.recordedHeadsets(inputLists: [[airPods, airPods]], headsets: [airPods]) == [airPods])
        #expect(HeadsetCallMic.recordedHeadsets(inputLists: [[airPods], [airPods]], headsets: [airPods]) == [airPods])
    }

    @Test func onlyHeadsetsCount() {
        #expect(HeadsetCallMic.recordedHeadsets(inputLists: [[builtIn], []], headsets: [airPods]).isEmpty)
        #expect(HeadsetCallMic.recordedHeadsets(inputLists: [[builtIn], [otherHeadset], [airPods]], headsets: [airPods, otherHeadset])
                == [otherHeadset, airPods])
    }

    // MARK: - Which headset

    @Test func noHeadsetListedMeansNoPick() {
        #expect(HeadsetCallMic.pick(inUse: [], systemDefault: airPods, bound: nil, inCallMode: { _ in true }) == nil)
    }

    /// A headset that reads as recorded but is in music mode: following
    /// it would pull it into call mode.
    @Test func aListedHeadsetInMusicModeIsNotPicked() {
        #expect(HeadsetCallMic.pick(inUse: [airPods], systemDefault: builtIn, bound: builtIn, inCallMode: { _ in false }) == nil)
    }

    @Test func aListedHeadsetInCallModeIsPicked() {
        #expect(HeadsetCallMic.pick(inUse: [airPods], systemDefault: builtIn, bound: nil, inCallMode: { $0 == airPods }) == airPods)
    }

    /// Daisy on the headset holds it in call mode itself, so the headset
    /// the recording is on needs only the listing.
    @Test func theBoundHeadsetNeedsNoCallModeProof() {
        #expect(HeadsetCallMic.pick(inUse: [airPods], systemDefault: builtIn, bound: airPods, inCallMode: { _ in false }) == airPods)
    }

    @Test func theSystemDefaultWinsAmongCandidates() {
        #expect(HeadsetCallMic.pick(inUse: [otherHeadset, airPods], systemDefault: airPods, bound: nil, inCallMode: { _ in true }) == airPods)
        #expect(HeadsetCallMic.pick(inUse: [otherHeadset, airPods], systemDefault: builtIn, bound: nil, inCallMode: { _ in true }) == otherHeadset)
        // Not when the default is listed but not in call mode.
        #expect(HeadsetCallMic.pick(inUse: [otherHeadset, airPods], systemDefault: airPods, bound: nil, inCallMode: { $0 == otherHeadset }) == otherHeadset)
    }

    // MARK: - Following a call that starts during the recording

    private func follow(_ watch: inout HeadsetCallWatch, from bound: AudioDeviceID, boundIsBluetooth: Bool = false,
                        to headset: AudioDeviceID) -> [HeadsetCallWatch.Step] {
        (0..<HeadsetCallWatch.ticksToFollow).map { _ in
            watch.observe(bound: bound, boundIsBluetooth: boundIsBluetooth, headset: headset)
        }
    }

    @Test func aHeadsetIsFollowedAfterTicksToFollowInARow() {
        var watch = HeadsetCallWatch()
        let steps = follow(&watch, from: builtIn, to: airPods)
        #expect(steps.dropLast().allSatisfy { $0 == .stay })
        #expect(steps.last == .follow(airPods))
        // The count starts over after a move.
        #expect(watch.observe(bound: builtIn, boundIsBluetooth: false, headset: airPods) == .stay)
    }

    /// Siri or a dictation opens the headset's mic for a few seconds.
    @Test func aShortSightingIsNotFollowed() {
        var watch = HeadsetCallWatch()
        for _ in 0..<(HeadsetCallWatch.ticksToFollow - 1) {
            #expect(watch.observe(bound: builtIn, boundIsBluetooth: false, headset: airPods) == .stay)
        }
        #expect(watch.observe(bound: builtIn, boundIsBluetooth: false, headset: nil) == .stay)
        for _ in 0..<(HeadsetCallWatch.ticksToFollow - 1) {
            #expect(watch.observe(bound: builtIn, boundIsBluetooth: false, headset: airPods) == .stay)
        }
    }

    @Test func anotherHeadsetStartsTheCountOver() {
        var watch = HeadsetCallWatch()
        #expect(watch.observe(bound: builtIn, boundIsBluetooth: false, headset: airPods) == .stay)
        let steps = follow(&watch, from: builtIn, to: otherHeadset)
        #expect(steps.last == .follow(otherHeadset))
    }

    /// On one headset, a call moves to another.
    @Test func fromOneHeadsetToAnother() {
        var watch = HeadsetCallWatch()
        let steps = follow(&watch, from: airPods, boundIsBluetooth: true, to: otherHeadset)
        #expect(steps.last == .follow(otherHeadset))
    }

    @Test func nothingHappensOnTheHeadsetTheRecordingIsAlreadyOn() {
        var watch = HeadsetCallWatch()
        for _ in 0..<40 {
            #expect(watch.observe(bound: airPods, boundIsBluetooth: true, headset: airPods) == .stay)
        }
    }

    // MARK: - After the call

    private func unusedTicks(_ watch: inout HeadsetCallWatch, _ n: Int) -> [HeadsetCallWatch.Step] {
        (0..<n).map { _ in watch.observe(bound: airPods, boundIsBluetooth: true, headset: nil) }
    }

    @Test func aHeadsetNoOtherAppUsesIsReconsidered() {
        var watch = HeadsetCallWatch()
        let steps = unusedTicks(&watch, HeadsetCallWatch.ticksToReconsider)
        #expect(steps.dropLast().allSatisfy { $0 == .stay })
        #expect(steps.last == .reconsider)
        // And again as long if the usual choice kept it there.
        #expect(unusedTicks(&watch, HeadsetCallWatch.ticksToReconsider).last == .reconsider)
    }

    /// A call app that stops its input for a short mute.
    @Test func aCallThatComesBackResetsTheWait() {
        var watch = HeadsetCallWatch()
        _ = unusedTicks(&watch, HeadsetCallWatch.ticksToReconsider - 1)
        #expect(watch.observe(bound: airPods, boundIsBluetooth: true, headset: airPods) == .stay)
        let steps = unusedTicks(&watch, HeadsetCallWatch.ticksToReconsider)
        #expect(steps.dropLast().allSatisfy { $0 == .stay })
        #expect(steps.last == .reconsider)
    }

    @Test func anotherHeadsetInterruptsTheWaitAndIsFollowed() {
        var watch = HeadsetCallWatch()
        _ = unusedTicks(&watch, HeadsetCallWatch.ticksToReconsider - 1)
        let steps = follow(&watch, from: airPods, boundIsBluetooth: true, to: otherHeadset)
        #expect(steps.last == .follow(otherHeadset))
        #expect(watch.observe(bound: airPods, boundIsBluetooth: true, headset: nil) == .stay)
    }

    @Test func aMicThatIsNotBluetoothIsNeverReconsidered() {
        var watch = HeadsetCallWatch()
        for _ in 0..<(HeadsetCallWatch.ticksToReconsider * 2) {
            #expect(watch.observe(bound: builtIn, boundIsBluetooth: false, headset: nil) == .stay)
        }
    }

    @Test func aResetForgetsHalfCountedTicks() {
        var watch = HeadsetCallWatch()
        for _ in 0..<(HeadsetCallWatch.ticksToFollow - 1) {
            _ = watch.observe(bound: builtIn, boundIsBluetooth: false, headset: airPods)
        }
        watch.reset()
        #expect(follow(&watch, from: builtIn, to: airPods).last == .follow(airPods))
    }
}
