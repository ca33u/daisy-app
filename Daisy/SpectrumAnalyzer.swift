// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  SpectrumAnalyzer.swift
//  Daisy
//
//  Reduces a rolling window of mono PCM samples into 6 normalized
//  spectrum bands using a Hann-windowed 2048-point FFT (vDSP).
//
//  Tuned for the daisy widget — not scientific analysis:
//    • Voice-friendly Hz band edges (80, 160, 320, 640, 1280, 2560, 5120)
//    • RMS within each band (smoother than peak-pick)
//    • dB clamp (-55…-20) so conversation volume maps to 0…1 instead of
//      flat-lining near zero with linear scaling
//    • Asymmetric attack/decay smoothing for "petals bloom and settle"
//    • Per-band hysteresis noise gate (no chatter on speech tails)
//    • Pre-allocated working buffers (no allocations per call)
//    • Lock around mutable state — `reset()` is safe to call from any
//      thread while `bands(…)` is mid-flight on the audio render thread
//

import Foundation
import Accelerate
import os.lock

final class SpectrumAnalyzer: @unchecked Sendable {
    static let bandCount = 6
    private static let log2n = 11
    private static let fftN = 1 << log2n  // 2048 — ~23 Hz/bin at 48 kHz

    /// Hz edges separating the 6 bands. Concentrated on the vocal range
    /// (fundamental ~80-300 Hz, formants ~500-3500 Hz). Treble band ends
    /// at 5.12 kHz — anything higher is sibilance / noise.
    private static let bandEdgesHz: [Float] = [80, 160, 320, 640, 1280, 2560, 5120]

    /// `nil` when vDSP FFT setup fails (allocation failure). `bands(from:)`
    /// then degrades gracefully — no crash, the spectrum just stops
    /// updating and the smoothed values stay where they are.
    private let fft: vDSP.FFT<DSPSplitComplex>?
    private let window: [Float]

    // Pre-allocated working buffers — no per-call heap allocation.
    /// Rolling history of the most-recent `fftN` mono samples. PERSISTS
    /// across calls — it's the FFT window itself, not per-call scratch.
    /// See `bands(from:)` step 1 for why a single callback buffer isn't
    /// enough under CoreAudio's small IO slices.
    private var history:    [Float]
    private var windowed:   [Float]
    private var realIn:     [Float]
    private var imagIn:     [Float]
    private var realOut:    [Float]
    private var imagOut:    [Float]
    private var magnitudes: [Float]

    /// Smoothed band values (carry over between calls). Asymmetric
    /// attack/decay so petals snap up but glide down.
    private var smoothed: [Float] = Array(repeating: 0, count: bandCount)
    private let attack: Float = 0.55
    private let decay:  Float = 0.32

    /// dB envelope — values below floorDB read as silent (0), values at
    /// or above ceilDB read as full (1). Tuned for typical mic input
    /// where conversational speech peaks around -25 to -20 dBFS.
    private let floorDB: Float = -55
    private let ceilDB:  Float = -20

    /// Per-band hysteresis noise gate. Open above `gateOpen`, close
    /// below `gateClose`. Prevents chatter when a single band wobbles
    /// across one threshold.
    private let gateOpen:  Float = 0.18
    private let gateClose: Float = 0.08
    private var gateIsOpen: Bool = false

    /// Locks all mutable state for safe cross-thread `reset()`.
    private let lock = OSAllocatedUnfairLock()

    init() {
        let n = Self.fftN
        let half = n / 2
        fft = vDSP.FFT(
            log2n: vDSP_Length(Self.log2n),
            radix: .radix2,
            ofType: DSPSplitComplex.self
        )
        window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: n,
            isHalfWindow: false
        )
        history    = Array(repeating: 0, count: n)
        windowed   = Array(repeating: 0, count: n)
        realIn     = Array(repeating: 0, count: half)
        imagIn     = Array(repeating: 0, count: half)
        realOut    = Array(repeating: 0, count: half)
        imagOut    = Array(repeating: 0, count: half)
        magnitudes = Array(repeating: 0, count: half)
    }

    /// Compute spectrum bands from the trailing window of mono samples.
    /// Returns `bandCount` floats in 0…1.
    ///
    /// **Takes `UnsafeBufferPointer<Float>` directly** so the audio
    /// render thread doesn't allocate an intermediate Swift Array on
    /// every tap callback (pre-1.0.3 the caller did
    /// `Array(UnsafeBufferPointer(start: ch, count: frames))` and
    /// re-sliced; that ~16 KB alloc per buffer at 100 Hz had a real
    /// chance of priority-inverting against the render thread's
    /// internal locks during malloc slow paths). The buffer's
    /// backing memory is borrowed for the duration of this call
    /// only — we copy what we need into our pre-allocated rolling
    /// `history` window immediately.
    func bands(from samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        // FFT setup failed at init — degrade gracefully: return the
        // current smoothed values instead of crashing. The widget
        // petals simply don't animate.
        guard let fft else { return smoothed }

        let n = Self.fftN
        let half = n / 2

        // 1. Append the incoming samples into the rolling history window
        //    so the FFT runs on the most-recent `n` samples, NOT just this
        //    one callback's buffer. CoreAudio (AUHAL) hands us small IO
        //    slices — typically 512 frames — whereas the old AVAudioEngine
        //    tap delivered ~n-sized buffers, so zero-padding a single
        //    buffer USED to be fine. A lone 512-sample slice zero-padded to
        //    2048 lands under the RISING edge of the Hann window (near-zero
        //    weights) → magnitudes collapse below the dB floor → every band
        //    reads 0 → the gate never opens → the widget petals sit frozen
        //    at baseline. A rolling window fixes this for ANY IO buffer
        //    size; a buffer ≥ n still just takes the trailing n, so the
        //    legacy large-buffer path is unchanged.
        let total = samples.count
        if total >= n {
            let srcStart = total - n
            for i in 0..<n { history[i] = samples[srcStart + i] }
        } else if total > 0 {
            // Slide the window left by `total` (drop the oldest), then
            // append the new samples at the tail. Forward copy is safe:
            // each read index (i + total) is always ahead of its write (i).
            let keep = n - total
            for i in 0..<keep { history[i] = history[i + total] }
            for i in 0..<total { history[keep + i] = samples[i] }
        }
        // total == 0 (shouldn't happen) leaves the window untouched.

        // 2. Hann window over the rolling history.
        vDSP.multiply(history, window, result: &windowed)

        // 3. Pack windowed reals into split-complex form.
        windowed.withUnsafeBufferPointer { winPtr in
            // baseAddress is non-nil for these fixed-size, non-empty
            // buffers; guard instead of force-unwrapping so an
            // impossible nil skips the FFT pass rather than crashing.
            guard let winBase = winPtr.baseAddress else { return }
            winBase.withMemoryRebound(to: DSPComplex.self, capacity: half) { cplxPtr in
                realIn.withUnsafeMutableBufferPointer { rp in
                    imagIn.withUnsafeMutableBufferPointer { ip in
                        guard let realBase = rp.baseAddress,
                              let imagBase = ip.baseAddress else { return }
                        var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                        vDSP_ctoz(cplxPtr, 2, &split, 1, vDSP_Length(half))
                    }
                }
            }
        }

        // 4. Forward FFT.
        realIn.withUnsafeMutableBufferPointer { realInPtr in
            imagIn.withUnsafeMutableBufferPointer { imagInPtr in
                realOut.withUnsafeMutableBufferPointer { realOutPtr in
                    imagOut.withUnsafeMutableBufferPointer { imagOutPtr in
                        guard let realInBase  = realInPtr.baseAddress,
                              let imagInBase  = imagInPtr.baseAddress,
                              let realOutBase = realOutPtr.baseAddress,
                              let imagOutBase = imagOutPtr.baseAddress else { return }
                        let inSplit = DSPSplitComplex(
                            realp: realInBase,
                            imagp: imagInBase
                        )
                        var outSplit = DSPSplitComplex(
                            realp: realOutBase,
                            imagp: imagOutBase
                        )
                        fft.forward(input: inSplit, output: &outSplit)
                    }
                }
            }
        }

        // 5. Magnitudes. In Apple's real-FFT packing, realOut[0] = DC
        //    and imagOut[0] = Nyquist (the imaginary slot of bin 0 is
        //    reused for the highest real bin). Handle DC specially; we
        //    don't use Nyquist for any voice band.
        let scale = 2.0 / Float(n)
        magnitudes[0] = abs(realOut[0]) * scale
        for i in 1..<half {
            let r = realOut[i]
            let im = imagOut[i]
            magnitudes[i] = sqrt(r * r + im * im) * scale
        }

        // 6. RMS within each voice-tuned Hz band.
        let binHz = Float(sampleRate) / Float(n)
        var raw = [Float](repeating: 0, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            let loHz = Self.bandEdgesHz[b]
            let hiHz = Self.bandEdgesHz[b + 1]
            let loBin = max(1, Int(loHz / binHz))
            let hiBin = min(half - 1, Int(hiHz / binHz))
            guard hiBin >= loBin else { continue }
            var sumSq: Float = 0
            var count = 0
            for i in loBin...hiBin {
                let v = magnitudes[i]
                sumSq += v * v
                count += 1
            }
            raw[b] = count > 0 ? sqrt(sumSq / Float(count)) : 0
        }

        // 7. Convert to dB and clamp to 0…1.
        let eps: Float = 1e-7
        for i in 0..<Self.bandCount {
            let db = 20.0 * log10(raw[i] + eps)
            let norm = (db - floorDB) / (ceilDB - floorDB)
            raw[i] = max(0, min(1, norm))
        }

        // 8. Per-band hysteresis gate. Open when any band crosses the
        //    open threshold; close only when every band falls below
        //    the close threshold. Once closed, force all bands to 0
        //    so the decay envelope pulls petals back to rest.
        let peak = raw.max() ?? 0
        if gateIsOpen {
            if peak < gateClose { gateIsOpen = false }
        } else {
            if peak > gateOpen { gateIsOpen = true }
        }
        if !gateIsOpen {
            for i in 0..<Self.bandCount { raw[i] = 0 }
        }

        // 9. Asymmetric smoothing.
        for i in 0..<Self.bandCount {
            let prev = smoothed[i]
            let next = raw[i]
            let coef = next > prev ? attack : decay
            smoothed[i] = prev + (next - prev) * coef
        }
        return smoothed
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        // Clear the rolling window too so a new recording doesn't FFT the
        // tail of the previous one for the first few frames.
        for i in 0..<Self.fftN { history[i] = 0 }
        for i in 0..<Self.bandCount {
            smoothed[i] = 0
        }
        gateIsOpen = false
    }
}
