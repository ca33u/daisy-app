// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
import AVFoundation
import Testing
@testable import Daisy

@Suite("Microphone noise suppression")
struct MicrophoneNoiseSuppressionTests {
    @Test("Low background is attenuated without being hard-muted")
    func lowBackgroundGain() {
        #expect(
            abs(
                MicrophoneNoiseSuppression.gain(forRMSDB: -80)
                    - MicrophoneNoiseSuppression.minimumGain
            ) < 0.0001
        )
    }

    @Test("Normal speech stays at unity gain")
    func speechGain() {
        #expect(MicrophoneNoiseSuppression.gain(forRMSDB: -30) == 1)
    }

    @Test("Transition between noise and speech is smooth")
    func transitionGain() {
        let gain = MicrophoneNoiseSuppression.gain(forRMSDB: -50)
        #expect(gain > MicrophoneNoiseSuppression.minimumGain)
        #expect(gain < 1)
    }

    @Test("Processing preserves buffer shape and attenuates quiet PCM")
    func bufferProcessing() throws {
        let format = try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        buffer.frameLength = 128
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<128 { samples[index] = 0.0005 }

        MicrophoneNoiseSuppression.apply(to: buffer)

        #expect(buffer.frameLength == 128)
        #expect(abs(samples[0] - 0.0005 * MicrophoneNoiseSuppression.minimumGain) < 0.00001)
    }
}
