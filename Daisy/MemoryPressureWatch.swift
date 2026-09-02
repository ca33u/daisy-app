//
//  MemoryPressureWatch.swift
//  Daisy
//
//  Listens for the system's memory-pressure signal and hands the ML
//  engines back their memory when the machine is short.
//
//  Why this exists: Daisy loads Whisper (626 MB by default, 1.5 GB for
//  the largest variant) and the FluidAudio diarizer at app start and,
//  before this, never unloaded either one. A Mac that opened Daisy in
//  the morning and recorded nothing carried that all day; a
//  re-transcription with a different variant could hold two graphs at
//  once. On the 8 GB machines most of our users have, that is the
//  difference between "Daisy is open" and the system swapping — with
//  Daisy's own summarizer being one of the things that then gets
//  starved (audit 2026-09-01).
//
//  Deliberately conservative:
//    • `.critical` only. macOS raises `.warning` during ordinary memory
//      compaction, which is common enough on 16 GB that reacting to it
//      would trade a real, felt cost — the next dictation hotkey pays a
//      full model reload before it can paste — against memory nobody
//      was short of (review find, 2026-09-02);
//    • never unloads while a decode, a recording, a finalize or a
//      re-transcribe is in flight — losing a pass is worse than the
//      memory;
//    • unloading costs a reload from the on-disk cache (seconds), not
//      a download.
//
//  If a `stop()` is ever added: cancel the source AND clear its handler
//  (`setEventHandler(handler: nil)`), or the handler's capture of the
//  source keeps both alive.
//

import Foundation
import os

@MainActor
enum MemoryPressureWatch {
    private static let log = Logger(
        subsystem: "app.essazanov.Daisy", category: "MemoryPressure"
    )
    private static var source: DispatchSourceMemoryPressure?

    /// Idempotent — a second call is a no-op, so wiring can call it
    /// freely on settings changes.
    static func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: .critical,
            queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated {
                let event = source.data
                log.warning("System memory pressure: \(event.rawValue, privacy: .public) — asking the ML engines to release")
                WhisperEngine.shared.releaseModelsUnderMemoryPressure()
                DiarizationEngine.shared.releaseUnderMemoryPressure()
            }
        }
        source.resume()
        Self.source = source
    }
}
