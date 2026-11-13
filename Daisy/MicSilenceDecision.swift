import Foundation

/// What a recording does when its microphone has gone silent.
///
/// Support mail 14.11: a muted listener's meeting stopped being recorded.
/// The person sat in a multi-speaker call with the microphone muted for
/// long stretches. Ten seconds of a silent microphone made the recorder
/// pause itself, the session followed with its real `pause()`, and that
/// pauses the system-audio capture and both transcribers too — so the
/// other participants were no longer recorded either. A hardware mute on
/// a headset, a system-level input mute, a closed lid on the built-in
/// microphone and some Bluetooth routes all look like this.
///
/// A silent microphone is a reason to pause only when it is the only
/// thing being recorded. A meeting that has the other side's capture as
/// part of it goes on.
enum MicSilenceDecision: Equatable {
    /// Today's path: the recorder falls to paused, the session follows.
    case pause
    /// The recorder keeps running and keeps writing its track.
    case keepRecording

    /// `.keepRecording` for a meeting that has system-audio capture as
    /// part of it — whether or not the other side is delivering right
    /// now. Pausing protects nothing there, and it fights the capture's
    /// own recovery: a capture that gave up keeps retrying, and a pause
    /// would have it come back into a paused recording.
    ///
    /// `captureIsPartOfSession` — this recording armed the capture at
    /// its start (the setting on, Screen Recording not denied). It is
    /// there because the capture's state outlives a recording: `stop()`
    /// leaves `.stopped`, and a later microphone-only meeting, which
    /// never starts the capture, would read that leftover as its own.
    ///
    /// Of the states, during such a recording: `.starting` and
    /// `.capturing` are a capture at work; `.stopped` is one that gave
    /// up mid-recording and is being retried; `.idle` is a start that
    /// failed, so there is no capture in this recording after all;
    /// `.paused` is one that was not resumed.
    ///
    /// Everything else — a voice note, a dictation, a meeting without
    /// the capture — pauses exactly as before.
    static func decide(
        mode: RecordingSession.RecordingMode,
        captureIsPartOfSession: Bool,
        systemAudio: SystemAudioCapture.CaptureState
    ) -> MicSilenceDecision {
        guard case .meeting = mode, captureIsPartOfSession else { return .pause }
        switch systemAudio {
        case .starting, .capturing, .stopped:
            return .keepRecording
        case .idle, .paused:
            return .pause
        }
    }

    /// A microphone that stayed silent through (nearly) all of a kept
    /// recording wrote a full-length file of nothing. For the "did
    /// either channel capture anything" question at Stop that is not a
    /// captured channel, whatever the file's size says.
    static func micTrackIsEmpty(keptSilenceSec: TimeInterval, recordedSec: TimeInterval) -> Bool {
        recordedSec > 0 && keptSilenceSec >= recordedSec * 0.9
    }
}

/// What the recorder knows about a silence it is recording through.
struct MicSilenceFacts: Equatable {
    /// The microphone has been above the liveness floor at some point
    /// in this recording — across unit rebuilds and pauses. It works;
    /// what is silent now was most likely muted. Never above the floor
    /// is a microphone that has not worked in this recording at all: a
    /// stale permission, a Bluetooth route, a virtual input.
    var heardEarlier: Bool
    /// (Almost) every buffer was bit-exact zeros — macOS is handing over
    /// an empty signal, not a quiet room (`LivenessBox`).
    var digitalSilence: Bool
    /// The lid is closed and the recording is on the Mac's own
    /// microphone, which is disconnected with the lid.
    var lidClosedOnBuiltInMic: Bool
    /// How long this silence has lasted, from the last signal — not
    /// from a liveness clock a rebuilt unit restarted.
    var silentFor: TimeInterval

    /// Whether `allZero` of `total` liveness samples make a digital
    /// silence — or nil while there are too few to say. The counters
    /// restart with every rebuilt unit, and a tick that lands on a new
    /// unit's first few zero buffers would otherwise read «digital» and
    /// skip the patience a quiet input is owed
    /// (`MicSilenceNotice.quietInputPatienceSec`). The ratio is the
    /// recorder's own: nine samples in ten.
    static func digitalSilence(allZero: Int, total: Int, minimumTotal: Int) -> Bool? {
        guard total > 0, total >= minimumTotal else { return nil }
        return allZero * 10 >= total * 9
    }
}

/// The recorder's report on a silence it records through. `began` once
/// per episode, `continues` on every later watchdog tick while it lasts
/// (the owner may not have been able to say anything yet), `over` when
/// signal is back.
enum MicSilenceEvent: Equatable {
    case began(MicSilenceFacts)
    case continues(MicSilenceFacts)
    case over
}

/// The silence watchdog's memory between its ticks (14.11).
///
/// The watchdog used to be a single `if`: silent for ten seconds, pause.
/// Now a silence can be recorded through, which makes it an episode with
/// a beginning and an end.
struct MicSilenceWatch {
    enum Step: Equatable {
        /// Signal within the window, no episode open.
        case none
        /// The microphone has been silent for the window and the
        /// recording goes on. Returned once per episode.
        case keptEpisodeBegan
        /// A later tick of the same episode.
        case keptEpisodeContinues
        /// Signal is back after a kept episode.
        case keptEpisodeEnded
        /// Fall to paused, as the watchdog always did: the owner was
        /// asked and said so.
        case pause
        /// Fall to paused without asking: the device has delivered no
        /// buffer for `stallAfter`.
        case pauseStalled
    }

    /// When the silence of the open kept episode began.
    private(set) var keptSince: Date?
    /// Silence recorded through in episodes that have ended.
    private var closedSilenceSec: TimeInterval = 0

    /// One tick.
    ///
    /// `lastSignalAt` — the liveness clock: the last time the microphone
    /// was above the floor, or the moment the clock was restarted (a
    /// unit rebuilt on a route change gets a fresh grace window).
    /// `signalWasHeard` tells the two apart: false while nothing has
    /// been above the floor since the restart. A restarted clock does
    /// not end an episode — the microphone is as silent as it was.
    /// `lastBufferAt` — the last time the device delivered a buffer.
    ///
    /// `decide` is asked when the watchdog would fire with no episode
    /// open — once per silence. An episode it allowed lasts until signal
    /// is back, or the recorder pauses or stops; the answer does not
    /// depend on how the other side is doing, so there is nothing to
    /// ask again.
    ///
    /// It is NOT asked when the device has stopped delivering buffers,
    /// and such a device ends an open episode too: that is a stalled
    /// unit, not a silent microphone, and it pauses exactly as it did
    /// before 14.11. Keeping the other side recording through a stalled
    /// or lost microphone unit — this, and the recorder's `.noBuffers`,
    /// `.noInputDevice` and `.rebuildFailed` pauses — is a separate
    /// change that is not in this one.
    mutating func tick(
        now: Date,
        lastSignalAt: Date,
        signalWasHeard: Bool,
        lastBufferAt: Date?,
        window: TimeInterval,
        stallAfter: TimeInterval,
        decide: () -> MicSilenceDecision
    ) -> Step {
        guard now.timeIntervalSince(lastSignalAt) >= window else {
            guard let since = keptSince else { return .none }
            guard signalWasHeard else { return .keptEpisodeContinues }
            closedSilenceSec += max(0, lastSignalAt.timeIntervalSince(since))
            keptSince = nil
            return .keptEpisodeEnded
        }
        let delivering = lastBufferAt.map { now.timeIntervalSince($0) < stallAfter } ?? false
        guard delivering else {
            close(at: now)
            return .pauseStalled
        }
        guard keptSince == nil else { return .keptEpisodeContinues }
        guard decide() == .keepRecording else { return .pause }
        keptSince = lastSignalAt
        return .keptEpisodeBegan
    }

    /// The recorder paused or stopped: an open episode ends here.
    mutating func close(at now: Date) {
        guard let since = keptSince else { return }
        closedSilenceSec += max(0, now.timeIntervalSince(since))
        keptSince = nil
    }

    /// How long the open episode's silence has lasted; 0 with none open.
    func openSilenceSec(now: Date) -> TimeInterval {
        keptSince.map { max(0, now.timeIntervalSince($0)) } ?? 0
    }

    /// Silence recorded through so far, the open episode included.
    func keptSilenceSec(now: Date) -> TimeInterval {
        closedSilenceSec + openSilenceSec(now: now)
    }
}

/// The one notice a recording gives about a silent microphone it keeps
/// recording through (14.11). Once per recording, not per episode:
/// someone who toggles a headset's mute twenty times in a meeting must
/// not get twenty pills. Calm or loud, whichever comes first.
struct MicSilenceNotice {
    enum Text: Equatable {
        /// Calm: «Mic is silent, still recording the other side». The
        /// microphone worked earlier, so it was muted, and the other
        /// side is there to be recorded.
        case micSilent
        /// Calm, the closed lid's own wording, with the same promise.
        case lidClosedStillRecording
        /// Calm, the closed lid's plain wording: nothing audible has
        /// come from the other side, so nothing is promised about it.
        case lidClosed
        /// Loud: «Daisy can’t hear you», and the microphone is
        /// delivering bit-exact zeros — permission, or a muted input.
        /// With the way to Microphone settings.
        case micNotHeardDigital
        /// Loud: below the floor but not zeros — a Bluetooth route, a
        /// dead device.
        case micNotHeardQuiet

        var isLoud: Bool {
            switch self {
            case .micSilent, .lidClosedStillRecording, .lidClosed: return false
            case .micNotHeardDigital, .micNotHeardQuiet: return true
            }
        }
    }

    /// What is on screen and what has been said, at the moment of asking.
    struct Surroundings: Equatable {
        /// Something audible has come from the other side in this
        /// recording (`SystemAudioCapture.receivedAudibleAudio`).
        var otherSideWasAudible: Bool
        /// The other side's status is «capturing» right now
        /// (`RecordingSession.systemAudioStatus`): running, and not
        /// known to be delivering nothing.
        var otherSideIsCapturing: Bool
        /// `start()` warned about the closed lid seconds ago
        /// (`clamshellWarned`).
        var lidAlreadyAnnounced: Bool
        /// No other pill is on screen. Neither notice takes a pill's
        /// place — that pill may be a question with a button on it, or
        /// the only way to get the other side back.
        var pillIsFree: Bool
    }

    /// A sub-floor input that is NOT bit-exact zeros is called a
    /// microphone Daisy can't hear only after this much continuous
    /// silence. The recorder's own notes put a working microphone's
    /// room tone at −70…−90 dBFS against a −80 floor: a quiet working
    /// microphone in a quiet room sits under the floor until someone
    /// speaks, and must not get «Daisy can’t hear you» ten seconds in.
    /// Zeros need no such patience — no microphone produces them.
    static let quietInputPatienceSec: TimeInterval = 60

    /// The recording's one notice has been shown.
    private(set) var given = false
    /// The notice that is on screen now, as far as this recording
    /// knows: shown, and not yet taken down by `withdraw()`.
    private(set) var up: Text?

    /// What to show now, or nil for nothing. Returning a text spends
    /// the recording's one notice and marks it as up; returning nil
    /// spends nothing (one case excepted, below) — the recorder reports
    /// again on its next tick while the silence lasts, and the notice
    /// is shown when it can be, and is true.
    ///
    /// - A closed lid keeps its own wording, calm. One that `start()`
    ///   already announced is not said twice, and counts as the notice.
    /// - The microphone worked earlier in this recording, and the other
    ///   side has been audible in it and is being captured now: a muted
    ///   listener. The calm line.
    /// - Anything else is loud, without pausing: a microphone that
    ///   never worked, or one that worked and went silent with no other
    ///   side to record — an in-person meeting loses its only voice.
    ///   Zeros at once; a merely quiet input after
    ///   `quietInputPatienceSec`.
    mutating func text(for facts: MicSilenceFacts, surroundings: Surroundings) -> Text? {
        guard !given else { return nil }
        let otherSideIsThere = surroundings.otherSideWasAudible && surroundings.otherSideIsCapturing
        let candidate: Text
        if facts.lidClosedOnBuiltInMic {
            if surroundings.lidAlreadyAnnounced {
                given = true
                return nil
            }
            candidate = otherSideIsThere ? .lidClosedStillRecording : .lidClosed
        } else if facts.heardEarlier, otherSideIsThere {
            candidate = .micSilent
        } else if facts.digitalSilence {
            candidate = .micNotHeardDigital
        } else {
            guard facts.silentFor >= Self.quietInputPatienceSec else { return nil }
            candidate = .micNotHeardQuiet
        }
        guard surroundings.pillIsFree else { return nil }
        given = true
        up = candidate
        return candidate
    }

    /// Whether the notice's toast may be shown. `ToastCenter` holds one
    /// toast, and one that carries an action is somebody's way out —
    /// the day-long «Restart capture» is the last button on screen once
    /// the capture-loss pill has expired. The notice's toast repeats
    /// what its pill and banner say; it never takes such a toast's
    /// place.
    static func mayShowToast(currentToastHasAction: Bool) -> Bool {
        !currentToastHasAction
    }

    /// The silence is over, or the recording paused or stopped: the
    /// notice that is up, to be taken down — once. Nil when none is.
    mutating func withdraw() -> Text? {
        defer { up = nil }
        return up
    }
}
