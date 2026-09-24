//
//  ProcessTapDefaultTests.swift
//  DaisyTests
//
//  Incident 23.09, Bluetooth part (24.09): the Core Audio process tap is
//  the default backend on 14.4+, ScreenCaptureKit the fallback. These pin
//  the switch and its one safety net — a tap that heard nothing (what a
//  denied System Audio Recording permission looks like) sends the next
//  week of recordings through ScreenCaptureKit.
//

import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import Daisy

@MainActor
@Suite("The process tap is the default, with a way back", .serialized)
struct ProcessTapDefaultTests {
    private let keys = [ProcessTapDebugFlag.key, "daisy.processTapHeardNothingAt",
                        ProcessTapPermission.askedKey, ProcessTapPermission.deniedKey]

    private func withCleanDefaults(_ body: () async throws -> Void) async rethrows {
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        try await body()
    }

    /// Review 24.09: until Daisy's own sheet has asked, the tap is not
    /// used — its first start is what shows the macOS dialog, and that
    /// must never be the middle of a call.
    @Test func notBeforeThePermissionWasAskedOnDaisysSheet() async {
        await withCleanDefaults {
            guard #available(macOS 14.4, *) else { return }
            #expect(ProcessTapDebugFlag.isEnabled)
            #expect(ProcessTapPermission.shouldAsk)
            #expect(!SystemAudioCapture.usesProcessTapBackend)
        }
    }

    @Test func allowedMeansTheTapAndNoMeansScreenCaptureKitFromTheFirstSecond() async {
        await withCleanDefaults {
            guard #available(macOS 14.4, *) else { return }
            ProcessTapPermission.record(.granted)
            #expect(!ProcessTapPermission.shouldAsk)
            #expect(SystemAudioCapture.usesProcessTapBackend)

            // Refused: the next recording starts on ScreenCaptureKit —
            // no silent tap to wait out for 120 seconds.
            ProcessTapPermission.record(.denied)
            #expect(!ProcessTapPermission.shouldAsk, "Asked once is asked")
            #expect(!SystemAudioCapture.usesProcessTapBackend)

            // Allowed later in System Settings, found by the launch re-check.
            ProcessTapPermission.record(.granted)
            #expect(SystemAudioCapture.usesProcessTapBackend)

            ProcessTapDebugFlag.isEnabled = false
            #expect(!SystemAudioCapture.usesProcessTapBackend, "An explicit no to the tap still holds")
        }
    }

    /// The probe listens for its own tone: 18 kHz at −50 dBFS.
    @Test func theProbeTellsItsToneFromZerosAndFromHiss() {
        #expect(ProcessTapPermission.outcome(peak: ProcessTapPermission.toneAmplitude) == .granted)
        #expect(ProcessTapPermission.outcome(peak: 0) == .denied, "A refused tap hands over exact zeros")
        #expect(ProcessTapPermission.outcome(peak: 0.00002) == .denied, "Dither is not the tone")
    }

    /// Review 24.09-2. A headset in a call runs at 16 kHz. The probe's
    /// tone, carried through the same resampling such an output imposes,
    /// must still arrive — 18 kHz would not, and "not heard" means the
    /// tap is switched off for the very people it is for.
    @Test func aSixteenKilohertzOutputStillCarriesTheTone() throws {
        func throughSixteenKilohertz(_ hz: Double) throws -> Float {
            let source = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let frames = AVAudioFrameCount(48_000)
            let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames)!
            input.frameLength = frames
            for i in 0..<Int(frames) {
                input.floatChannelData![0][i] = Float(sin(2 * Double.pi * hz * Double(i) / 48_000)) * ProcessTapPermission.toneAmplitude
            }
            let converter = try #require(AVAudioConverter(from: source, to: target))
            let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_000 + 64)!
            nonisolated(unsafe) var pending: AVAudioPCMBuffer? = input
            var error: NSError?
            _ = converter.convert(to: output, error: &error) { _, status in
                if let b = pending { pending = nil; status.pointee = .haveData; return b }
                status.pointee = .endOfStream
                return nil
            }
            // Skip the converter's settling at the start.
            var peak: Float = 0
            for i in 1_000..<Int(output.frameLength) { peak = max(peak, abs(output.floatChannelData![0][i])) }
            return peak
        }
        let chosen = ProcessTapPermission.toneFrequency(forOutputRate: 16_000)
        #expect(chosen < 8_000)
        #expect(ProcessTapPermission.outcome(peak: try throughSixteenKilohertz(chosen)) == .granted)
        // The bug the pin exists for: 18 kHz does not survive 16 kHz.
        #expect(ProcessTapPermission.outcome(peak: try throughSixteenKilohertz(18_000)) == .denied)
        // And at 48 kHz the inaudible 18 kHz is kept.
        #expect(ProcessTapPermission.toneFrequency(forOutputRate: 48_000) == 18_000)
    }

    /// The probe plays on the built-in output: it exists on this Mac and
    /// runs fast enough for 18 kHz.
    @Test func theProbePlaysOnTheBuiltInOutput() throws {
        let builtIn = try #require(ProcessTapAudioCapture.builtInOutputDevice(), "This Mac has built-in output")
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        #expect(AudioObjectGetPropertyData(builtIn.id, &address, 0, nil, &size, &rate) == noErr)
        #expect(ProcessTapPermission.toneFrequency(forOutputRate: rate) == 18_000)
    }

    @Test func aTapThatHeardNothingSendsAWeekToScreenCaptureKit() async {
        await withCleanDefaults {
            guard #available(macOS 14.4, *) else { return }
            ProcessTapPermission.record(.granted)
            ProcessTapDebugFlag.heardNothingAt = Date()
            #expect(!SystemAudioCapture.usesProcessTapBackend)
            ProcessTapDebugFlag.heardNothingAt = Date().addingTimeInterval(-8 * 86_400)
            #expect(SystemAudioCapture.usesProcessTapBackend, "After a week the tap gets another chance")
        }
    }

    @Test func routeSnapshotsCompare() {
        let a = SystemAudioCapture.OutputRoute(deviceID: 42, name: "AirPods", sampleRate: 48_000, outputChannels: 2, bluetooth: true)
        var hfp = a
        hfp.sampleRate = 24_000
        hfp.outputChannels = 1
        #expect(a != hfp, "A2DP → HFP on the same device is a route change")
        #expect(a.description.contains("BT"))
        let live = SystemAudioCapture.outputRoute()
        #expect(live == SystemAudioCapture.outputRoute(), "Two reads with nothing changing agree")
    }
}
