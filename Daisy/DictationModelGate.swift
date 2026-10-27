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
