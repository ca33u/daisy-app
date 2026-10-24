//
//  WhisperDecoderThreadTests.swift
//  DaisyTests
//
//  The Whisper decode runs off the main thread. WhisperKit runs on its
//  caller's actor, and the engine is @MainActor: until `WhisperDecoder`
//  the decoder's work between CoreML predictions ran on the UI thread
//  (field log 24.10) — about half a second of main-thread CPU per pass,
//  which contributes to UI jank during a meeting.
//

import Foundation
import os
import Testing
import WhisperKit
@testable import Daisy

@MainActor
@Suite("Whisper decode: off the main thread")
struct WhisperDecoderThreadTests {
    @Test func theDecodeRunsOffTheMainThreadAndTheCallerResumesOnIt() async throws {
        let ranOnMain = Probe<Bool?>(nil)
        let decoder = WhisperDecoder { _, _ in
            ranOnMain.set(isMainThread())
            return []
        }
        #expect(isMainThread())

        _ = try await decoder.transcribe([0], options: DecodingOptions())

        #expect(ranOnMain.value == false)
        #expect(isMainThread())       // results land back on the main actor
    }

    /// A decode holds its thread the way CoreML's predict does — it
    /// blocks, it doesn't await. The main actor has to keep running
    /// meanwhile: here it is the one that lets the decode finish. The
    /// deadline is generous because the whole suite shares the main
    /// thread; it only runs out when the decode sits on main itself.
    @Test func theMainActorKeepsRunningWhileADecodeBlocks() async throws {
        let started = Probe(false)
        let released = Probe(false)
        let decoder = WhisperDecoder { _, _ in
            started.set(true)
            let deadline = Date().addingTimeInterval(30)
            while !released.value, Date() < deadline { usleep(1_000) }
            // An empty result says the main actor never answered.
            return released.value ? [TranscriptionResult(text: "", segments: [], language: "en",
                                                         timings: TranscriptionTimings())] : []
        }

        let pass = Task { @MainActor in try await decoder.transcribe([0], options: DecodingOptions()) }
        while !started.value { try? await Task.sleep(for: .milliseconds(5)) }
        released.set(true)              // main-actor work during the decode
        let results = try await pass.value

        #expect(results.count == 1)
    }

    @Test func cancellingThePassReachesTheDecode() async {
        let started = Probe(false)
        let sawCancel = Probe(false)
        let decoder = WhisperDecoder { _, _ in
            started.set(true)
            let deadline = Date().addingTimeInterval(30)
            while !Task.isCancelled, Date() < deadline { usleep(1_000) }
            sawCancel.set(Task.isCancelled)
            throw CancellationError()
        }

        let pass = Task { @MainActor in try await decoder.transcribe([0], options: DecodingOptions()) }
        while !started.value { try? await Task.sleep(for: .milliseconds(5)) }
        pass.cancel()
        _ = await pass.result

        #expect(sawCancel.value)
    }
}

private nonisolated func isMainThread() -> Bool { pthread_main_np() != 0 }

private nonisolated final class Probe<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>
    init(_ value: Value) { lock = OSAllocatedUnfairLock(initialState: value) }
    var value: Value { lock.withLock { $0 } }
    func set(_ value: Value) { lock.withLock { $0 = value } }
}
