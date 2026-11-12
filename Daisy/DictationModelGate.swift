import Foundation

/// What a dictation start has to wait for before the microphone opens,
/// and what the widget says while it waits.
///
/// Field report 27.10: a person on Parakeet («Быстрее», ready) pressed the
/// dictation key while the meeting model couldn't load. Every dictation
/// waited for Whisper first — whatever engine it was going to use — so
/// the widget spun for up to a minute, the key could neither stop nor
/// cancel it, and the dictation ended refused. Whisper is the engine of
/// meetings and the FALLBACK of a fast dictation, not its prerequisite.
enum DictationModelGate {
    enum Plan: Equatable {
        /// The selected fast engine is ready: open the microphone now.
        case none
        /// Parakeet is complete on disk but not in memory — a load of a
        /// few seconds. Whisper only if that load fails.
        case loadParakeet
        /// Whisper engine selected, or the fast engine can't run this
        /// time (downloading, failed a minute ago, no model, Apple's
        /// model not installed): Whisper takes this dictation.
        case whisper
    }

    struct Parakeet: Equatable {
        var isReady: Bool
        var isDownloading: Bool
        var hasCompleteModel: Bool
        /// Failed within `ParakeetEngine.failureBackoff` — not worth a
        /// full failed CoreML load again on this press.
        var failedRecently: Bool
    }

    /// `whisperRunsHere`: false on an Intel Mac (`WhisperEngine.runsOnThisMac`).
    /// There Whisper is no fallback, so a Parakeet that isn't ready is
    /// waited for whatever it's doing — downloading, or failed a minute
    /// ago — rather than refused; the wait shows its progress and letting
    /// go cancels it.
    static func plan(engine: DictationEngine, parakeet: Parakeet, appleSpeechReady: Bool,
                     whisperRunsHere: Bool = true) -> Plan {
        switch engine {
        case .whisper:
            return .whisper
        case .parakeet:
            if parakeet.isReady { return .none }
            if !whisperRunsHere { return .loadParakeet }
            // A first-ever ~600 MB download isn't worth holding the key
            // for; Whisper takes this one and Parakeet is there next time.
            if parakeet.isDownloading || parakeet.failedRecently { return .whisper }
            return parakeet.hasCompleteModel ? .loadParakeet : .whisper
        case .appleSpeech:
            return appleSpeechReady ? .none : .whisper
        }
    }

    /// Whether app launch puts Parakeet in memory (Egor 03.11: the first
    /// dictation after an update waited 15 s for a model that had been on
    /// disk all along — likely an uncached Neural Engine compile). Only
    /// the chosen engine, and only a model complete on disk: a launch
    /// never starts the first ~600 MB download, which stays with Settings,
    /// onboarding and the first press. A model FluidAudio finds broken is
    /// repaired from the mirror, as the first press would do. The disk
    /// check runs only for a Parakeet user.
    static func preloadsParakeetAtLaunch(engine: DictationEngine,
                                         hasCompleteModel: @autoclosure () -> Bool) -> Bool {
        engine == .parakeet && hasCompleteModel()
    }

    // MARK: - Launch preload

    enum LaunchPreloadStep: Equatable, Sendable {
        case parakeet, whisper
    }

    /// What launch loads, in order: Parakeet when it is the dictation
    /// engine and complete on disk (`preloadsParakeetAtLaunch`), then
    /// Whisper. One after the other since 12.11 (Sentry DAISY-MAC-4):
    /// 1.0.8.49 started both at once, and the two reports from that build
    /// show Whisper's load aborting while it read a compiled package from
    /// the app's Core ML cache, with another thread in a FluidAudio model
    /// load, inside Core ML's compilation, at the same moment.
    ///
    /// `skip`: the last run ended inside a model load
    /// (`ModelLoadGuard.skipsLaunchPreload`) — nothing is loaded ahead of
    /// need this launch. A held engine isn't preloaded either. The disk
    /// check runs only for a Parakeet that would be loaded.
    static func launchPreload(engine: DictationEngine, hasCompleteParakeet: @autoclosure () -> Bool,
                              skip: Bool, held: Set<ModelLoadEngine>) -> [LaunchPreloadStep] {
        guard !skip else { return [] }
        var steps: [LaunchPreloadStep] = []
        if !held.contains(.parakeet),
           preloadsParakeetAtLaunch(engine: engine, hasCompleteModel: hasCompleteParakeet()) {
            steps.append(.parakeet)
        }
        if !held.contains(.whisper) { steps.append(.whisper) }
        return steps
    }

    /// How long one launch step may keep the next one waiting.
    static let launchPreloadStepCap: TimeInterval = 90

    /// Whether the launch stops waiting for the step in front and starts
    /// the next. A step that turned into a download — Parakeet's files
    /// found broken and fetched again, Whisper's model not on disk — is
    /// minutes of network, not a load; and nothing in-process can cancel a
    /// Core ML load that hangs, so past the cap the next step goes anyway.
    static func preloadMovesOn(isDownloading: Bool, elapsed: TimeInterval) -> Bool {
        isDownloading || elapsed > launchPreloadStepCap
    }

    /// Runs the launch steps one after the other. Each step runs in its own
    /// task (`StartStepGate`), so one that stops being waited for
    /// (`preloadMovesOn`) goes on to its end.
    ///
    /// Only the launch is ordered. There is deliberately no lane that makes
    /// every model load in the app wait its turn: a dictation press must
    /// not sit behind a cold Whisper compile of a minute or more. So two
    /// loads can still run at once: one asked for elsewhere next to a
    /// launch step (a dictation press in the first seconds, the recovery
    /// of an interrupted recording three seconds in, Settings → Dictation
    /// appearing), and the launch's own two when the first stops being
    /// waited for — a Parakeet whose files are being fetched again lets
    /// Whisper start, and then compiles beside it.
    static func runLaunchPreload(
        _ steps: [LaunchPreloadStep],
        pollEvery: Duration = .milliseconds(250),
        isDownloading: @escaping @MainActor (LaunchPreloadStep) -> Bool,
        load: @escaping @MainActor (LaunchPreloadStep) async -> Void
    ) async {
        for step in steps {
            let started = Date()
            var watch: Task<Void, Never>?
            await StartStepGate.wait(for: { await load(step) }) { moveOn in
                watch = Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: pollEvery)
                        if Task.isCancelled { return }
                        if preloadMovesOn(isDownloading: isDownloading(step),
                                          elapsed: Date().timeIntervalSince(started)) {
                            moveOn()
                            return
                        }
                    }
                }
            }
            watch?.cancel()
        }
    }

    /// The caption over the widget while a dictation waits for a model.
    /// A dictation is started from another app, so the hover tooltip
    /// never shows; this pill is where the wait is visible. It also says
    /// what ends it: the key is held, and letting go cancels.
    static func waitCaption(whisper state: WhisperEngine.LoadState?, loadProgress: Double,
                            parakeet: ParakeetEngine.LoadState? = nil) -> String {
        if case .downloading(let progress) = parakeet {
            let percent = Int((min(max(progress, 0), 1) * 100).rounded())
            return String(localized: "Downloading the speech model · \(percent)% · let go to cancel")
        }
        switch state {
        case .downloading(let progress):
            let percent = Int((min(max(progress, 0), 1) * 100).rounded())
            return String(localized: "Downloading the speech model · \(percent)% · let go to cancel")
        case .loading:
            let percent = Int((min(max(loadProgress, 0), 1) * 100).rounded())
            return String(localized: "Getting the speech model ready · about \(percent)% · let go to cancel")
        case .notLoaded, .ready, .failed, .none:
            return String(localized: "Getting the speech model ready · let go to cancel")
        }
    }
}
