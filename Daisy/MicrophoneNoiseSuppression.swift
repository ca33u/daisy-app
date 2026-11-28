// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  MicrophoneNoiseSuppression.swift
//  Daisy
//
//  A deliberately conservative, dependency-free microphone noise gate.
//  It attenuates low, steady room noise while leaving normal speech at
//  unity gain. The setting is opt-in because any gate can soften very
//  quiet speech. Processing happens on CoreAudioMicRecorder's serial
//  worker queue, never on the real-time render thread.
//

import AVFoundation
import Foundation

enum MicrophoneNoiseSuppression {
    /// Below this RMS level the input is treated as steady background.
    nonisolated static let closedThresholdDB: Float = -58
    /// At and above this level audio passes through unchanged.
    nonisolated static let openThresholdDB: Float = -42
    /// Keep a little ambience instead of hard-muting the channel. This
    /// avoids clipped word beginnings and makes the result sound less gated.
    nonisolated static let minimumGain: Float = 0.18

    /// Smooth gain curve used by both the processor and deterministic tests.
    /// `smoothstep` avoids a discontinuity as speech crosses the threshold.
    nonisolated static func gain(forRMSDB db: Float) -> Float {
        guard db.isFinite else { return minimumGain }
        if db <= closedThresholdDB { return minimumGain }
        if db >= openThresholdDB { return 1 }

        let linear = (db - closedThresholdDB) / (openThresholdDB - closedThresholdDB)
        let smooth = linear * linear * (3 - 2 * linear)
        return minimumGain + (1 - minimumGain) * smooth
    }

    /// Apply the gate in-place to Float32 PCM. AUHAL is configured to
    /// produce Float32 non-interleaved buffers, but the guards make this a
    /// safe no-op if that contract changes later.
    nonisolated static func apply(to buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        var sumSquares: Float = 0
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frameCount {
                let sample = samples[frame]
                sumSquares += sample * sample
            }
        }

        let meanSquare = sumSquares / Float(frameCount * channelCount)
        let rmsDB: Float = meanSquare > 0 ? 10 * log10(meanSquare) : -160
        let gain = gain(forRMSDB: rmsDB)
        guard gain < 0.999 else { return }

        for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frameCount {
                samples[frame] *= gain
            }
        }
    }
}
