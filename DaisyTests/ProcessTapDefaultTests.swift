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
    private let keys = [ProcessTapDebugFlag.key, "daisy.processTapHeardNothingAt"]

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

    @Test func onUnlessSomeoneSaidNo() async {
        await withCleanDefaults {
            #expect(ProcessTapDebugFlag.isEnabled)
            if #available(macOS 14.4, *) { #expect(SystemAudioCapture.usesProcessTapBackend) }
            ProcessTapDebugFlag.isEnabled = false
            #expect(!SystemAudioCapture.usesProcessTapBackend)
        }
    }

    @Test func aTapThatHeardNothingSendsAWeekToScreenCaptureKit() async {
        await withCleanDefaults {
            guard #available(macOS 14.4, *) else { return }
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
