// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
import Testing
@testable import Daisy

@Suite("Whisper model load progress")
struct WhisperLoadProgressTests {
    @Test("Estimate is determinate, monotonic, and capped until ready")
    func estimateIsMonotonicAndCapped() {
        let samples = [0.0, 1, 10, 60, 360, 3_600].map {
            WhisperEngine.estimatedLoadProgress(
                elapsed: $0,
                expectedDuration: 360
            )
        }

        #expect(samples.first == 0.02)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(samples.allSatisfy { $0 >= 0.02 && $0 <= 0.98 })
        #expect(samples.last == 0.98)
    }
}
