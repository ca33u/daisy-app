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
