//
//  ProcessTapPermission.swift
//  Daisy
//
//  Incident 23.09, review 24.09: the process tap is the default backend on
//  macOS 14.4+, and it needs a permission ScreenCaptureKit did not —
//  "System Audio Recording Only". macOS asks for it the first time a tap
//  starts (`AudioDeviceStart`), which, left alone, is the first meeting
//  after the update: a system dialog in the middle of a call. So Daisy
//  asks once, on its own sheet, before any call.
//
//  The permission cannot be read. A denied tap raises no error — every
//  call returns noErr and the tap hands over zeros — so the answer is
//  learned by listening: Daisy plays a tone nobody hears (18 kHz at
//  −50 dBFS) and taps ITS OWN process. The tone arrives: allowed. Zeros:
//  denied, and recordings stay on ScreenCaptureKit from the first
//  second, with no silent stretch to wait out.
//

import AVFoundation
import Foundation
import os

@MainActor
enum ProcessTapPermission {
    enum Outcome: Equatable { case granted, denied, unavailable }

    static let askedKey = "daisy.processTapPermissionAsked"
    static let deniedKey = "daisy.processTapPermissionDenied"

    /// The sheet has done its job: the question was put to macOS.
    static var asked: Bool {
        get { UserDefaults.standard.bool(forKey: askedKey) }
        set { UserDefaults.standard.set(newValue, forKey: askedKey) }
    }

    /// The last probe heard nothing of its own tone.
    static var denied: Bool {
        get { UserDefaults.standard.bool(forKey: deniedKey) }
        set { UserDefaults.standard.set(newValue, forKey: deniedKey) }
    }

    /// Show the sheet: the tap would be used, and nobody asked yet.
    static var shouldAsk: Bool {
        guard #available(macOS 14.4, *) else { return false }
        return ProcessTapDebugFlag.isEnabled && !asked
    }

    /// Anything above this in the tapped signal is the tone: −50 dBFS is
    /// 0.0032; the floor sits ~10 dB under it and far above exact zeros.
    nonisolated static let heardThreshold: Float = 0.001
    nonisolated static let toneAmplitude: Float = 0.00316
    nonisolated static let toneHz: Double = 18_000

    nonisolated static func outcome(peak: Float) -> Outcome {
        peak > heardThreshold ? .granted : .denied
    }

    /// Record what a probe found. `asked` becomes true either way.
    static func record(_ outcome: Outcome) {
        switch outcome {
        case .granted: denied = false; asked = true
        case .denied: denied = true; asked = true
        case .unavailable: break
        }
    }

    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "TapPermission")

    /// Play the tone, tap our own process, and listen until the tone
    /// arrives, `stop()` returns true, or `timeout` runs out.
    /// The first probe on a Mac is what shows the macOS dialog.
    static func probe(timeout: Duration, stop: @escaping @MainActor () -> Bool = { false }) async -> Outcome {
        guard #available(macOS 14.4, *) else { return .unavailable }

        let tone = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let phase = PhaseBox()
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let step = 2 * Double.pi * ProcessTapPermission.toneHz / 48_000
            for frame in 0..<Int(frameCount) {
                let value = Float(sin(phase.value)) * ProcessTapPermission.toneAmplitude
                phase.value += step
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value
                }
            }
            return noErr
        }
        tone.attach(source)
        tone.connect(source, to: tone.mainMixerNode, format: format)
        do {
            try tone.start()
        } catch {
            log.error("Tone did not start: \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }
        defer { tone.stop() }
        // Our process becomes a Core Audio process object once it plays.
        try? await Task.sleep(for: .milliseconds(250))

        let peak = PeakBox()
        let queue = DispatchQueue(label: "app.essazanov.Daisy.tapProbe")
        let tap = ProcessTapAudioCapture(
            scope: .onlyProcesses(pids: [getpid()]),
            requestedHostUID: nil,
            pinnedFormat: nil,
            deliveryQueue: queue,
            onBuffer: { chunk in
                guard let data = chunk.pcm.floatChannelData else { return }
                var local: Float = 0
                for channel in 0..<Int(chunk.pcm.format.channelCount) {
                    for i in 0..<Int(chunk.pcm.frameLength) { local = max(local, abs(data[channel][i])) }
                }
                peak.raise(to: local)
            },
            onDeath: { _, _ in }
        )
        do {
            try await Task.detached { try tap.start() }.value
        } catch {
            log.error("Probe tap did not start: \(error.localizedDescription, privacy: .public)")
            return .unavailable
        }
        defer { Task.detached { tap.stop() } }

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline, !stop() {
            if outcome(peak: peak.value) == .granted { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let result = outcome(peak: peak.value)
        log.notice("Tap permission probe: \(result == .granted ? "tone heard — allowed" : "zeros — denied or not answered", privacy: .public) (peak \(peak.value, privacy: .public))")
        return result
    }

    /// At launch, when the last answer was no: a short, silent re-check,
    /// so allowing it later in System Settings brings the tap back.
    static func recheckIfDenied() {
        guard asked, denied else { return }
        Task { @MainActor in
            let result = await probe(timeout: .seconds(1.5))
            if result == .granted { record(.granted) }
        }
    }
}

private nonisolated final class PhaseBox: @unchecked Sendable {
    var value: Double = 0
}

private nonisolated final class PeakBox: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    var value: Float { lock.withLock { peak } }
    func raise(to candidate: Float) { lock.withLock { peak = max(peak, candidate) } }
}
