import Foundation
import Testing
import WhisperKit
@testable import Daisy

/// Sentry DAISY-MAC-2 (1.0.8.43, MacBookPro16,1): WhisperKit crashed in
/// `TextDecoder.prepareDecoderInputs` on an Intel Mac. ArgmaxCore's
/// `FloatType` is `Float` on macOS x86_64, and the float16 MLMultiArray
/// initializer fills a 2-byte-per-element IOSurface with 4-byte floats.
/// Until WhisperKit is fixed, the x86_64 slice neither loads nor decodes
/// Whisper, and a recording that needs it is refused in words.
@Suite("Whisper on Intel Macs")
struct IntelMacWhisperTests {
    typealias Preflight = RecordingSession.StartPreflight

    @Test("The slice decides: arm64 runs Whisper, x86_64 (Intel or Rosetta) doesn't")
    func sliceDecides() {
        #if arch(x86_64)
        #expect(WhisperEngine.runsOnThisMac == false)
        // The cause, pinned: halves are written as 4-byte floats here.
        #expect(MemoryLayout<FloatType>.size == 4)
        #else
        #expect(WhisperEngine.runsOnThisMac == true)
        #expect(MemoryLayout<FloatType>.size == 2)
        #endif
    }

    @Test("A recording that needs Whisper is refused up front where it can't run")
    func preflightRefuses() {
        #expect(Preflight.decide(hasShownFirstRun: true, whisperState: .ready, modelIsCached: true,
                                 isOnline: true, whisperRequired: true, whisperRunsHere: false) == .macUnsupported)
        #expect(Preflight.decide(hasShownFirstRun: true, whisperState: .notLoaded, modelIsCached: false,
                                 isOnline: false, whisperRequired: true, whisperRunsHere: false) == .macUnsupported)
    }

    @Test("A fast-engine dictation isn't refused for it, and onboarding still comes first")
    func preflightLetsOthersThrough() {
        #expect(Preflight.decide(hasShownFirstRun: true, whisperState: .notLoaded, modelIsCached: false,
                                 isOnline: true, whisperRequired: false, whisperRunsHere: false) == .proceed)
        #expect(Preflight.decide(hasShownFirstRun: false, whisperState: .notLoaded, modelIsCached: false,
                                 isOnline: true, whisperRequired: true, whisperRunsHere: false) == .onboardingIncomplete)
        #expect(Preflight.decide(hasShownFirstRun: true, whisperState: .ready, modelIsCached: true,
                                 isOnline: true, whisperRequired: true, whisperRunsHere: true) == .proceed)
    }

    @MainActor
    @Test("Loading on an Intel slice fails in words and downloads nothing",
          .enabled(if: !WhisperEngine.runsOnThisMac, "only an x86_64 run can show it"))
    func loadFailsInWords() async {
        #if arch(x86_64)
        await WhisperEngine.shared.ensureLoaded()
        #expect(WhisperEngine.shared.state == .failed(WhisperEngineError.unsupportedMac.localizedDescription))
        await #expect(throws: WhisperEngineError.self) {
            _ = try await WhisperEngine.shared.transcribe(samples: [Float](repeating: 0, count: 16_000), language: nil)
        }
        #endif
    }

    @MainActor
    @Test("On an Intel Mac a Parakeet dictation waits for Parakeet, whatever it's doing")
    func intelGateWaitsForParakeet() {
        typealias Gate = DictationModelGate
        func parakeet(downloading: Bool = false, complete: Bool = false, failed: Bool = false) -> Gate.Parakeet {
            .init(isReady: false, isDownloading: downloading, hasCompleteModel: complete, failedRecently: failed)
        }
        #expect(Gate.plan(engine: .parakeet, parakeet: parakeet(downloading: true), appleSpeechReady: false, whisperRunsHere: false) == .loadParakeet)
        #expect(Gate.plan(engine: .parakeet, parakeet: parakeet(failed: true), appleSpeechReady: false, whisperRunsHere: false) == .loadParakeet)
        #expect(Gate.plan(engine: .parakeet, parakeet: parakeet(), appleSpeechReady: false, whisperRunsHere: false) == .loadParakeet)
        // Apple's model missing and the Whisper engine still need Whisper — refused with the dictation message.
        #expect(Gate.plan(engine: .appleSpeech, parakeet: parakeet(), appleSpeechReady: false, whisperRunsHere: false) == .whisper)
        #expect(Gate.plan(engine: .whisper, parakeet: parakeet(), appleSpeechReady: true, whisperRunsHere: false) == .whisper)
        // Apple silicon keeps its rule: a downloading Parakeet hands the press to Whisper.
        #expect(Gate.plan(engine: .parakeet, parakeet: parakeet(downloading: true), appleSpeechReady: false) == .whisper)
    }

    @MainActor
    @Test("The wait caption shows Parakeet's download too")
    func parakeetCaption() {
        #expect(DictationModelGate.waitCaption(whisper: nil, loadProgress: 0, parakeet: .downloading(progress: 0.25))
                == "Downloading the speech model · 25% · let go to cancel")
        #expect(DictationModelGate.waitCaption(whisper: nil, loadProgress: 0, parakeet: .loading)
                == "Getting the speech model ready · let go to cancel")
    }

    @MainActor
    @Test("A refused dictation names the row that fixes it, in both languages")
    func dictationMessage() throws {
        #expect(RecordingSession.dictationNeedsFastEngineMessage
                == "Dictation can’t start: on an Intel Mac it needs Faster or Apple dictation ready. Check \(SettingsRow.dictationEngine.path).")
        let ru = try #require(Bundle.main.path(forResource: "ru", ofType: "lproj").flatMap(Bundle.init(path:)))
        let key = "Dictation can’t start: on an Intel Mac it needs Faster or Apple dictation ready. Check %@."
        let value = ru.localizedString(forKey: key, value: "∅", table: nil)
        #expect(value != "∅" && value != key && value.contains("Быстрее"))
    }

    @Test("The message says what's needed, in both languages")
    func message() throws {
        #expect(WhisperEngineError.unsupportedMac.localizedDescription
                == "This needs a Mac with Apple silicon (M1 or newer): the speech model doesn’t run on Intel Macs yet.")
        let ru = try #require(Bundle.main.path(forResource: "ru", ofType: "lproj").flatMap(Bundle.init(path:)))
        let key = "This needs a Mac with Apple silicon (M1 or newer): the speech model doesn’t run on Intel Macs yet."
        let value = ru.localizedString(forKey: key, value: "∅", table: nil)
        #expect(value != "∅" && value != key)
    }

    @Test("The log report's Mac line names the slice and flags an unsupported Whisper")
    func hardwareLine() {
        #expect(LogReporter.hardwareLine(model: "Mac16,7", binaryArch: "arm64", rosetta: false, whisperRuns: true)
                == "Mac16,7 binary=arm64 rosetta=no")
        #expect(LogReporter.hardwareLine(model: "MacBookPro16,1", binaryArch: "x86_64", rosetta: false, whisperRuns: false)
                == "MacBookPro16,1 binary=x86_64 rosetta=no whisper=UNSUPPORTED (WhisperKit can't decode on x86_64)")
        #expect(LogReporter.hardwareLine(model: nil, binaryArch: "x86_64", rosetta: nil, whisperRuns: false)
                .hasPrefix("? binary=x86_64 rosetta=?"))
    }
}
