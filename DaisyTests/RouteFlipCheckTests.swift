//
//  RouteFlipCheckTests.swift
//  DaisyTests
//
//  B-1 (19.10): a headset flipping to call mode and back is an event for
//  the process tap. Sound heard since the change settles it; silence
//  rebuilds the tap, twice in a row at most — never a move to
//  ScreenCaptureKit, whose switch restarts the archive as silence.
//
//  24.10 (user log, AirPods Pro, call mode 24 kHz → music mode 48 kHz an
//  hour into a call): four rebuilds in the same pinned configuration, all
//  silent, then nothing more — not when the output moved to the speakers,
//  not on resume. The second attempt is a fresh build hosted on the
//  default output (the headset itself), the first one a fresh build on the
//  built-in output when the route moved the output's clock, and another
//  output device opens a new ladder. A fresh tap delivers its own rate;
//  the archive converts.
//

import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import Daisy

struct RouteFlipCheckTests {
    private let changed = Date(timeIntervalSince1970: 1_800_000_000)
    private let airPodsCall = RouteFlipCheck.RouteShape(deviceID: 183, sampleRate: 24_000, bluetooth: true)
    private let airPodsMusic = RouteFlipCheck.RouteShape(deviceID: 183, sampleRate: 48_000, bluetooth: true)
    private let speakers = RouteFlipCheck.RouteShape(deviceID: 71, sampleRate: 48_000, bluetooth: false)
    private let wired = RouteFlipCheck.RouteShape(deviceID: 90, sampleRate: 48_000, bluetooth: false)

    @Test func soundAfterTheChangeKeepsTheTap() {
        for clock in [false, true] {
            #expect(RouteFlipCheck.decide(changedAt: changed, lastAudibleAt: changed.addingTimeInterval(4), rebuilds: 0, clockChanged: clock) == .keep)
            #expect(RouteFlipCheck.decide(changedAt: changed, lastAudibleAt: changed.addingTimeInterval(4), rebuilds: 2, clockChanged: clock) == .keep)
        }
    }

    @Test func soundOnlyBeforeTheChangeCountsAsSilence() {
        // User log B: the other side heard for 49 minutes, then the flip.
        #expect(RouteFlipCheck.decide(changedAt: changed, lastAudibleAt: changed.addingTimeInterval(-60), rebuilds: 0, clockChanged: false) == .rebuildTap)
        #expect(RouteFlipCheck.decide(changedAt: changed, lastAudibleAt: nil, rebuilds: 0, clockChanged: false) == .rebuildTap)
    }

    @Test func theSecondAttemptIsAFreshBuildOnTheDefaultOutputThenItLeavesIt() {
        // Review 24.10: a fresh build on the built-in output runs into the
        // same host as every in-place rebuild; the second goes to the
        // headset itself.
        #expect(RouteFlipCheck.decide(changedAt: changed, lastAudibleAt: nil, rebuilds: 1, clockChanged: false) == .freshBuild(.defaultOutput))
        #expect(RouteFlipCheck.decide(changedAt: changed, lastAudibleAt: nil, rebuilds: 1, clockChanged: true) == .freshBuild(.defaultOutput))
        #expect(RouteFlipCheck.decide(changedAt: changed, lastAudibleAt: nil, rebuilds: 2, clockChanged: false) == .giveUp)
        #expect(RouteFlipCheck.decide(changedAt: changed, lastAudibleAt: nil, rebuilds: 2, clockChanged: true) == .giveUp)
        #expect(RouteFlipCheck.maxRebuilds == 2)
    }

    @Test func aRouteThatMovedTheClockIsFreshFromTheFirstAttempt() {
        // 24.10: the tap was built on 24 kHz call mode; the check runs on
        // 48 kHz music mode — the in-place rebuild would pin 24 kHz again.
        let moved = RouteFlipCheck.clockChanged(from: airPodsCall, to: airPodsMusic)
        #expect(moved)
        #expect(RouteFlipCheck.decide(changedAt: changed, lastAudibleAt: changed.addingTimeInterval(-60), rebuilds: 0, clockChanged: moved) == .freshBuild(.preferred))
    }

    @Test func theDefaultOutputHostFallsBackToTheBuiltInOne() {
        // The AirPods at 48 kHz in the 24.10 log, then the speakers themselves.
        #expect(RouteFlipCheck.defaultOutputHostUID(defaultOutputUID: "AirPods-UID", builtInUID: "BuiltInSpeakerDevice") == "AirPods-UID")
        #expect(RouteFlipCheck.defaultOutputHostUID(defaultOutputUID: "BuiltInSpeakerDevice", builtInUID: "BuiltInSpeakerDevice") == "BuiltInSpeakerDevice")
        // The default gone: the built-in output; neither: the engine's own choice.
        #expect(RouteFlipCheck.defaultOutputHostUID(defaultOutputUID: nil, builtInUID: "BuiltInSpeakerDevice") == "BuiltInSpeakerDevice")
        #expect(RouteFlipCheck.defaultOutputHostUID(defaultOutputUID: "", builtInUID: "BuiltInSpeakerDevice") == "BuiltInSpeakerDevice")
        #expect(RouteFlipCheck.defaultOutputHostUID(defaultOutputUID: nil, builtInUID: nil) == nil)
    }

    @Test func theTapIsReadFromTheEndOfTheInputList() {
        // The built-in speakers have no inputs: the tap is the only buffer.
        #expect(ProcessTapAudioCapture.tapBufferStart(bufferCount: 1, tapBuffers: 1) == 0)
        // A headset host: its microphone first (turned off), the tap last.
        #expect(ProcessTapAudioCapture.tapBufferStart(bufferCount: 2, tapBuffers: 1) == 1)
        #expect(ProcessTapAudioCapture.tapBufferStart(bufferCount: 3, tapBuffers: 2) == 1)
        #expect(ProcessTapAudioCapture.tapBufferStart(bufferCount: 0, tapBuffers: 1) == nil)
        #expect(ProcessTapAudioCapture.tapBufferStart(bufferCount: 1, tapBuffers: 0) == nil)
    }

    @Test func aHeadsetHostIsTrustedOnlyInTheTapsLayout() {
        let headsetMic = kAudioStreamTerminalTypeHeadsetMicrophone
        let tap: (sampleRate: Double, channels: UInt32) = (48_000, 1)
        func check(
            inputs: Int = 2, hostInputs: Int = 1, lastType: UInt32 = 0, hostTypes: [UInt32] = [headsetMic],
            last: (sampleRate: Double, channels: UInt32)? = (48_000, 1), hostRate: Double? = 48_000
        ) -> Bool {
            ProcessTapAudioCapture.tapIsLastInput(
                aggregateInputStreams: inputs, hostInputStreams: hostInputs, lastStreamTerminalType: lastType,
                hostInputTerminalTypes: hostTypes, lastStreamFormat: last, tapFormat: tap, hostSampleRate: hostRate)
        }
        // AirPods in music mode as the host: their microphone, then the tap.
        #expect(check())
        // The tap drift-compensated to the host's rate is still the tap.
        #expect(check(last: (24_000, 1), hostRate: 24_000))
        // The other order — the microphone last — would record the person
        // as the other side: refused by type, or by shape.
        #expect(!check(lastType: headsetMic))
        #expect(!check(lastType: kAudioStreamTerminalTypeMicrophone, hostTypes: [0]))
        #expect(!check(lastType: kAudioStreamTerminalTypeLine, hostTypes: [kAudioStreamTerminalTypeLine]))
        #expect(!check(hostTypes: [0], last: (16_000, 1)))   // an untyped headset mic in call mode
        #expect(!check(last: (48_000, 2)))
        // A count that isn't the host's inputs plus the tap, or a last
        // stream that can't be read.
        #expect(!check(inputs: 3))
        #expect(!check(inputs: 1))
        #expect(!check(last: nil))
    }

    @Test func theClockMovesWithTheRateOrTheTransportOnly() {
        #expect(RouteFlipCheck.clockChanged(from: airPodsMusic, to: speakers))   // Bluetooth off
        #expect(RouteFlipCheck.clockChanged(from: speakers, to: airPodsCall))    // on, and a new rate
        #expect(!RouteFlipCheck.clockChanged(from: speakers, to: wired))         // another device, same clock
        #expect(!RouteFlipCheck.clockChanged(from: airPodsMusic, to: airPodsMusic))
        #expect(!RouteFlipCheck.clockChanged(from: nil, to: airPodsMusic))
    }

    @Test func anotherRouteAfterGivingUpOpensANewLadder() {
        // 24.10: given up on the AirPods, then the output moved to the speakers.
        #expect(RouteFlipCheck.reopensLadder(gaveUpOn: airPodsMusic, now: speakers))
        #expect(RouteFlipCheck.reopensLadder(gaveUpOn: speakers, now: wired))
        // The same headset in another mode, or the same route again — a
        // headset flapping between call and music mode — does not.
        #expect(!RouteFlipCheck.reopensLadder(gaveUpOn: airPodsMusic, now: airPodsCall))
        #expect(!RouteFlipCheck.reopensLadder(gaveUpOn: airPodsMusic, now: airPodsMusic))
        // Nothing given up: nothing to reopen.
        #expect(!RouteFlipCheck.reopensLadder(gaveUpOn: nil, now: speakers))
    }

    @Test func theWindowOutlastsAFlipAndBack() {
        // The headset in log B came back 5 s after each flip; the check
        // must wait past that so it judges the route the call stays on.
        #expect(RouteFlipCheck.window > 5)
    }
}

/// A fresh tap delivers its own rate into an archive opened at the
/// session's first one: the archive converts and keeps one file.
@MainActor
struct SystemAudioArchiveFormatTests {
    private func tone(rate: Double, frames: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = buffer.floatChannelData![0]
        for i in 0..<frames { samples[i] = 0.2 * sinf(Float(i) * 2 * .pi * 440 / Float(rate)) }
        return buffer
    }

    @Test func aMidRecordingRateChangeIsConvertedIntoTheArchive() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RouteFlip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("system_audio.caf")

        // Half a second in call mode (24 kHz), then one second after the
        // flip (48 kHz), 10 ms buffers as the tap delivers them.
        let before = (0..<50).map { _ in tone(rate: 24_000, frames: 240) }
        let after = (0..<100).map { _ in tone(rate: 48_000, frames: 480) }
        let written = SystemAudioCapture().archiveForTesting(before + after, into: url)

        // 12 000 frames before, ~24 000 converted after; a resampler may
        // hold back a few frames at the seam.
        #expect(written > 35_500 && written <= 36_000)
        let file = try AVAudioFile(forReading: url)
        #expect(file.processingFormat.sampleRate == 24_000)
        #expect(file.processingFormat.channelCount == 1)
        #expect(UInt64(file.length) == written)
    }
}
