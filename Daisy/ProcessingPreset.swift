//
//  ProcessingPreset.swift
//  Daisy
//
//  Settings → Meetings → «Обработка встреч»: three plans that set the
//  handful of settings that decide how hard Daisy works during and after
//  a meeting (Egor, 07.10.2026). The plan is DERIVED from those settings,
//  never stored: change any of them by hand and the section says «Свой»
//  instead of holding a stale choice that no longer describes reality.
//
//  What is deliberately NOT in a plan (vault: business/projects/daisy/
//  2026-10-07-settings-presets.md):
//    • the final Whisper pass — it is the same full-quality pass in every
//      plan; a faster, worse one was rejected (quality first);
//    • the Whisper model — switching it means a 1.5 GB download;
//    • turning screenshots ON — whether to capture the screen is a
//      privacy choice. Since S2 (24.10.2026) screenshots count in the
//      match only as a rule a plan keeps: Economy has them off, Balanced
//      no more often than every 2 minutes; Maximum leaves them alone.
//
//  `Setting` is the one table of what a plan speaks for: the match, the
//  «по плану» badges on those rows and the Custom card's links all read
//  it (Settings restructure S2, Egor 24.10.2026).
//

import Foundation

enum ProcessingPreset: String, CaseIterable, Identifiable {
    case economy
    case balanced
    case maximum

    var id: String { rawValue }

    /// The settings a plan owns.
    struct Values: Equatable {
        var liveTranscript: LiveTranscriptionTier
        var diarizeRemoteSpeakers: Bool
        var diarizeMicrophone: Bool
        var transcriptSecondPass: Bool
    }

    var values: Values {
        switch self {
        case .economy:
            // The live transcript is cheap next to the final pass, but
            // it is the one load DURING the meeting, and Economy is for
            // a laptop on battery. The transcript comes after Stop.
            return Values(liveTranscript: .off, diarizeRemoteSpeakers: false,
                          diarizeMicrophone: false, transcriptSecondPass: false)
        case .balanced:
            // Today's fresh-install defaults.
            return Values(liveTranscript: .lite, diarizeRemoteSpeakers: true,
                          diarizeMicrophone: false, transcriptSecondPass: true)
        case .maximum:
            return Values(liveTranscript: .full, diarizeRemoteSpeakers: true,
                          diarizeMicrophone: true, transcriptSecondPass: true)
        }
    }

    /// The settings a plan speaks for, each with the row that shows it.
    /// A plan owns the first four outright; the two screenshot ones only
    /// where it keeps a rule about them (`owns`).
    enum Setting: CaseIterable, Sendable {
        case liveTranscript
        case speakersInTranscript
        case splitMicVoices
        case secondPass
        case screenCapture
        case screenshotInterval

        var row: SettingsRow {
            switch self {
            case .liveTranscript: .liveTranscript
            case .speakersInTranscript: .speakersInTranscript
            case .splitMicVoices: .splitMicVoices
            case .secondPass: .secondPass
            case .screenCapture: .screenCapture
            case .screenshotInterval: .screenshotInterval
            }
        }

        /// This setting's value in `state`, to tell which ones a change
        /// touched.
        func value(in state: State) -> AnyHashable {
            switch self {
            case .liveTranscript: state.liveTranscript
            case .speakersInTranscript: state.diarizeRemoteSpeakers
            case .splitMicVoices: state.diarizeMicrophone
            case .secondPass: state.transcriptSecondPass
            case .screenCapture: state.screenshotsEnabled
            case .screenshotInterval: state.screenshotIntervalSec
            }
        }
    }

    /// The values of every `Setting`, one field each — plain values so
    /// the match is pure and testable without the real prefs.
    struct State: Equatable, Sendable {
        var liveTranscript: LiveTranscriptionTier
        var diarizeRemoteSpeakers: Bool
        var diarizeMicrophone: Bool
        var transcriptSecondPass: Bool
        var screenshotsEnabled: Bool
        var screenshotIntervalSec: Int

        @MainActor
        init(_ settings: AppSettings) {
            liveTranscript = settings.liveTranscriptionTier
            diarizeRemoteSpeakers = settings.diarizeRemoteSpeakers
            diarizeMicrophone = settings.diarizeMicrophone
            transcriptSecondPass = settings.transcriptSecondPass
            screenshotsEnabled = settings.screenshotsEnabled
            screenshotIntervalSec = settings.screenshotIntervalSec
        }

        init(liveTranscript: LiveTranscriptionTier, diarizeRemoteSpeakers: Bool, diarizeMicrophone: Bool,
             transcriptSecondPass: Bool, screenshotsEnabled: Bool, screenshotIntervalSec: Int) {
            self.liveTranscript = liveTranscript
            self.diarizeRemoteSpeakers = diarizeRemoteSpeakers
            self.diarizeMicrophone = diarizeMicrophone
            self.transcriptSecondPass = transcriptSecondPass
            self.screenshotsEnabled = screenshotsEnabled
            self.screenshotIntervalSec = screenshotIntervalSec
        }

        @MainActor
        func write(to settings: AppSettings) {
            // Only what differs: each write is a defaults write and an
            // observation tick.
            if settings.liveTranscriptionTier != liveTranscript { settings.liveTranscriptionTier = liveTranscript }
            if settings.diarizeRemoteSpeakers != diarizeRemoteSpeakers { settings.diarizeRemoteSpeakers = diarizeRemoteSpeakers }
            if settings.diarizeMicrophone != diarizeMicrophone { settings.diarizeMicrophone = diarizeMicrophone }
            if settings.transcriptSecondPass != transcriptSecondPass { settings.transcriptSecondPass = transcriptSecondPass }
            if settings.screenshotsEnabled != screenshotsEnabled { settings.screenshotsEnabled = screenshotsEnabled }
            if settings.screenshotIntervalSec != screenshotIntervalSec { settings.screenshotIntervalSec = screenshotIntervalSec }
        }
    }

    /// Whether this plan keeps a rule about `setting` — the rows that
    /// wear its badge. Maximum says nothing about screenshots; Economy
    /// nothing about the interval of captures it has turned off.
    func owns(_ setting: Setting) -> Bool {
        switch setting {
        case .liveTranscript, .speakersInTranscript, .splitMicVoices, .secondPass: true
        case .screenCapture: self == .economy
        case .screenshotInterval: self == .balanced
        }
    }

    /// Whether `state` keeps this plan's rule for `setting`; true for a
    /// setting the plan doesn't own.
    func holds(_ setting: Setting, in state: State) -> Bool {
        let v = values
        switch setting {
        case .liveTranscript: return state.liveTranscript == v.liveTranscript
        case .speakersInTranscript: return state.diarizeRemoteSpeakers == v.diarizeRemoteSpeakers
        case .splitMicVoices: return state.diarizeMicrophone == v.diarizeMicrophone
        case .secondPass: return state.transcriptSecondPass == v.transcriptSecondPass
        case .screenCapture: return !owns(.screenCapture) || !state.screenshotsEnabled
        case .screenshotInterval:
            return !owns(.screenshotInterval) || !state.screenshotsEnabled
                || state.screenshotIntervalSec >= Self.balancedScreenshotIntervalSec
        }
    }

    /// The plan `state` keeps every rule of, or nil for «Свой».
    static func matching(_ state: State) -> ProcessingPreset? {
        allCases.first { preset in Setting.allCases.allSatisfy { preset.holds($0, in: state) } }
    }

    @MainActor
    static func matching(_ settings: AppSettings) -> ProcessingPreset? {
        matching(State(settings))
    }

    /// `state` with this plan's rules applied — the smallest change that
    /// makes `matching` say this plan (Egor, 07.10.2026): Economy turns
    /// screen captures off; Balanced keeps them if they're on but no
    /// more often than every 2 minutes; Maximum leaves both alone.
    func applied(to state: State) -> State {
        let v = values
        var next = state
        next.liveTranscript = v.liveTranscript
        next.diarizeRemoteSpeakers = v.diarizeRemoteSpeakers
        next.diarizeMicrophone = v.diarizeMicrophone
        next.transcriptSecondPass = v.transcriptSecondPass
        if owns(.screenCapture) { next.screenshotsEnabled = false }
        if owns(.screenshotInterval), next.screenshotsEnabled,
           next.screenshotIntervalSec < Self.balancedScreenshotIntervalSec {
            next.screenshotIntervalSec = Self.balancedScreenshotIntervalSec
        }
        return next
    }

    /// Captures just switched on (`state` has them on): under Balanced,
    /// no faster than its 2 minutes — turning on what the plan allows
    /// shouldn't read as breaking it (Settings S2, 24.10.2026).
    static func capturesTurnedOn(_ state: State) -> State {
        var before = state
        before.screenshotsEnabled = false
        guard state.screenshotsEnabled, matching(before) == .balanced else { return state }
        return balanced.applied(to: state)
    }

    /// The live tier and the Speakers flags are read when a recording
    /// starts; the second pass when one finishes.
    @MainActor
    func apply(to settings: AppSettings) {
        applied(to: State(settings)).write(to: settings)
        // A side effect outside the plan's match: Economy also defers
        // processing to a charger, and nothing but its own switch turns
        // that off again.
        if self == .economy { settings.deferProcessingOnBattery = true }
    }

    /// Balanced's floor for the screenshot interval — one of the
    /// «Capture every» row's own options (15 s, 30 s, 1 min, 2 min).
    static let balancedScreenshotIntervalSec = 120

    var title: String {
        switch self {
        case .economy: return String(localized: "Economy")
        case .balanced: return String(localized: "Balanced")
        case .maximum: return String(localized: "Maximum")
        }
    }

    // The words for each setting's value, shared by the Settings cards
    // and the onboarding step. Keyed where a plain key is already taken
    // with another form — "Full" is «Полный» and "Off" is «Выкл» elsewhere.

    static func liveLabel(_ tier: LiveTranscriptionTier) -> String {
        switch tier {
        case .off: String(localized: "After the meeting")
        case .lite: String(localized: "Optimal")
        case .full: String(localized: "preset.live.full", defaultValue: "Full")
        }
    }

    static func participantsLabel(_ on: Bool) -> String {
        on ? String(localized: "Each separately") : String(localized: "You and the other side")
    }

    static func roomLabel(_ on: Bool) -> String {
        on ? String(localized: "Separate participants") : String(localized: "Don't separate participants")
    }

    static func refineLabel(_ on: Bool) -> String {
        on ? String(localized: "Names, terms, who spoke") : String(localized: "preset.refine.off", defaultValue: "Off")
    }

    var tagline: String {
        switch self {
        case .economy:
            return String(localized: "Least load and battery. The transcript appears after the meeting.")
        case .balanced:
            return String(localized: "Recommended. A light live transcript, the other side’s speakers told apart.")
        case .maximum:
            return String(localized: "Everything on. The most load — best on a charger.")
        }
    }
}
