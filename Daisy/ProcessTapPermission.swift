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
//  Review 24.09-2: the tone plays on the BUILT-IN output, never the
//  default one. A Bluetooth headset in a call runs at 16–24 kHz, where
//  18 kHz is above Nyquist and resampling removes it — the probe would
//  hear zeros, call it a refusal and switch the tap off for exactly the
//  people it exists for. The tap is per-process and hears the tone
//  wherever it plays. And should the pin fail, the tone is kept below
//  the Nyquist of whatever the output turns out to be.
//

import AppKit
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

    enum State: Equatable { case notAsked, granted, denied }

    static var isAvailable: Bool {
        guard #available(macOS 14.4, *) else { return false }
        return ProcessTapDebugFlag.isEnabled
    }

    static var state: State {
        !asked ? .notAsked : (denied ? .denied : .granted)
    }

    /// Privacy & Security → System Audio Recording Only; the pane's own
    /// anchor, falling back to Privacy & Security if macOS doesn't know it.
    static func openSettings() {
        let urls = ["x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
                    "x-apple.systempreferences:com.apple.preference.security"]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
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

    /// 18 kHz where the output can carry it (48 kHz: inaudible); below
    /// Nyquist with margin anywhere slower — a 16 kHz headset gets 6 kHz
    /// at −50 dBFS, faint but detected rather than cut away.
    nonisolated static func toneFrequency(forOutputRate rate: Double) -> Double {
        min(toneHz, rate * 0.375)
    }

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
        if let builtIn = ProcessTapAudioCapture.builtInOutputDevice(), let unit = tone.outputNode.audioUnit {
            var device = builtIn.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                log.warning("Probe could not pin its tone to \(builtIn.name, privacy: .public) (\(status, privacy: .public)) — playing on the default output")
            }
        } else {
            log.warning("No built-in output — the probe tone plays on the default output")
        }
        let outputRate = tone.outputNode.outputFormat(forBus: 0).sampleRate
        let frequency = toneFrequency(forOutputRate: outputRate > 0 ? outputRate : 48_000)
        log.notice("Probe tone: \(Int(frequency), privacy: .public) Hz on an output at \(Int(outputRate), privacy: .public) Hz")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let phase = PhaseBox()
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let step = 2 * Double.pi * frequency / 48_000
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
