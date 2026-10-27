import Foundation
import Testing
@testable import Daisy

/// Field report 27.10: every dictation waited for the meeting model
/// (Whisper) before opening the microphone, whatever engine it used, and
/// the wait couldn't be cancelled — with Whisper unable to load, a
/// dictation on a ready Parakeet spun for a minute and was refused.
@MainActor
@Suite("Dictation model gate")
struct DictationModelGateTests {
    typealias Gate = DictationModelGate

    private func parakeet(ready: Bool = false, downloading: Bool = false,
                          complete: Bool = false, failedRecently: Bool = false) -> Gate.Parakeet {
        .init(isReady: ready, isDownloading: downloading, hasCompleteModel: complete, failedRecently: failedRecently)
    }

    @Test("A ready fast engine opens the microphone without Whisper")
    func readyFastEngineSkipsWhisper() {
        #expect(Gate.plan(engine: .parakeet, parakeet: parakeet(ready: true), appleSpeechReady: false) == .none)
        #expect(Gate.plan(engine: .appleSpeech, parakeet: parakeet(), appleSpeechReady: true) == .none)
    }

    @Test("Parakeet on disk but not loaded is loaded, not replaced by Whisper")
    func completeParakeetLoads() {
        #expect(Gate.plan(engine: .parakeet, parakeet: parakeet(complete: true), appleSpeechReady: false) == .loadParakeet)
    }

    @Test("Whisper takes the dictation when the fast engine can't run this time")
    func whisperIsTheFallback() {
        #expect(Gate.plan(engine: .parakeet, parakeet: parakeet(downloading: true, complete: true), appleSpeechReady: false) == .whisper)
        #expect(Gate.plan(engine: .parakeet, parakeet: parakeet(complete: true, failedRecently: true), appleSpeechReady: false) == .whisper)
        #expect(Gate.plan(engine: .parakeet, parakeet: parakeet(), appleSpeechReady: false) == .whisper)
        #expect(Gate.plan(engine: .appleSpeech, parakeet: parakeet(ready: true), appleSpeechReady: false) == .whisper)
    }

    @Test("The Whisper engine always waits for Whisper")
    func whisperEngineWaits() {
        #expect(Gate.plan(engine: .whisper, parakeet: parakeet(ready: true), appleSpeechReady: true) == .whisper)
    }

    @Test("The wait caption says what's happening, how far, and how to cancel")
    func waitCaption() {
        #expect(Gate.waitCaption(whisper: .downloading(progress: 0.42), loadProgress: 0)
                == "Downloading the speech model · 42% · let go to cancel")
        #expect(Gate.waitCaption(whisper: .loading(status: ""), loadProgress: 0.7)
                == "Getting the speech model ready · about 70% · let go to cancel")
        #expect(Gate.waitCaption(whisper: nil, loadProgress: 0.9)
                == "Getting the speech model ready · let go to cancel")
        #expect(Gate.waitCaption(whisper: .downloading(progress: 1.7), loadProgress: 0)
                == "Downloading the speech model · 100% · let go to cancel")
    }

    @Test("Every new line has a Russian translation")
    func russianStrings() throws {
        let ru = try #require(Bundle(for: RecordingSession.self).path(forResource: "ru", ofType: "lproj")
            .flatMap(Bundle.init(path:)))
        for key in ["Downloading the speech model · %lld%% · let go to cancel",
                    "Getting the speech model ready · about %lld%% · let go to cancel",
                    "Getting the speech model ready · let go to cancel",
                    "I’ve cancelled it — the speech model is still getting ready. Dictation will work once it’s done."] {
            let value = ru.localizedString(forKey: key, value: "∅", table: nil)
            #expect(value != "∅" && value != key, "no RU for \(key)")
            #expect(!value.contains("ьте"), "RU uses «ты»: \(value)")
        }
    }

    @Test("A fast-engine dictation isn't refused up front for a Whisper it may not need")
    func preflightLetsFastDictationThrough() {
        typealias Preflight = RecordingSession.StartPreflight
        #expect(Preflight.decide(hasShownFirstRun: true, whisperState: .notLoaded, modelIsCached: false,
                                 isOnline: false, whisperRequired: false) == .proceed)
        #expect(Preflight.decide(hasShownFirstRun: true, whisperState: .notLoaded, modelIsCached: false,
                                 isOnline: false, whisperRequired: true) == .modelCannotLoad)
        #expect(Preflight.decide(hasShownFirstRun: false, whisperState: .ready, modelIsCached: true,
                                 isOnline: true, whisperRequired: false) == .onboardingIncomplete)
    }
}

/// The wait `start()` suspends in for a model: a cancel ends it at once,
/// and the step keeps running for the next press.
@MainActor
@Suite("Start step gate")
struct StartStepGateTests {
    @Test("A cancel ends the wait without waiting for the step")
    func cancelEndsTheWait() async {
        final class Flag { var done = false }
        let stepDone = Flag()
        // Ordering, not wall time: parallel suites share the main actor,
        // so a timing bound would be flaky. The step is far longer than
        // any contention; the wait must come back before it.
        await StartStepGate.wait(for: {
            try? await Task.sleep(for: .seconds(60))
            stepDone.done = true
        }) { cancel in
            Task { @MainActor in cancel() }
        }
        #expect(!stepDone.done)
    }

    @Test("Without a cancel the wait ends when the step does")
    func stepEndsTheWait() async {
        final class Flag { var done = false }
        let stepDone = Flag()
        await StartStepGate.wait(for: {
            try? await Task.sleep(for: .milliseconds(50))
            stepDone.done = true
        }) { _ in }
        #expect(stepDone.done)
    }

    @Test("A cancel after the step finished is harmless")
    func lateCancelIsHarmless() async {
        var saved: (@MainActor () -> Void)?
        await StartStepGate.wait(for: {}) { cancel in saved = cancel }
        saved?()
        saved?()
    }
}
