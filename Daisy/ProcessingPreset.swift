//
//  ProcessingPreset.swift
//  Daisy
//
//  Settings → General → «Обработка встреч»: three plans that set the
//  handful of settings that decide how hard Daisy works during and after
//  a meeting (Egor, 07.10.2026). The plan is DERIVED from those settings,
//  never stored: change any of them by hand and the section says «Свои»
//  instead of holding a stale choice that no longer describes reality.
//
//  What is deliberately NOT in a plan (vault: business/projects/daisy/
//  2026-10-07-settings-presets.md):
//    • the final Whisper pass — it is the same full-quality pass in every
//      plan; a faster, worse one was rejected (quality first);
//    • the Whisper model — switching it means a 1.5 GB download;
//    • screenshots — a privacy choice, not a load one.
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

    /// The plan the current settings match, or nil for «Свои».
    @MainActor
    static func matching(_ settings: AppSettings) -> ProcessingPreset? {
        let current = Values(
            liveTranscript: settings.liveTranscriptionTier,
            diarizeRemoteSpeakers: settings.diarizeRemoteSpeakers,
            diarizeMicrophone: settings.diarizeMicrophone,
            transcriptSecondPass: settings.transcriptSecondPass
        )
        return allCases.first { $0.values == current }
    }

    /// The live tier and the Speakers flags are read when a recording
    /// starts; the second pass when one finishes.
    @MainActor
    func apply(to settings: AppSettings) {
        let v = values
        settings.liveTranscriptionTier = v.liveTranscript
        settings.diarizeRemoteSpeakers = v.diarizeRemoteSpeakers
        settings.diarizeMicrophone = v.diarizeMicrophone
        settings.transcriptSecondPass = v.transcriptSecondPass
    }

    var title: String {
        switch self {
        case .economy: return String(localized: "Economy")
        case .balanced: return String(localized: "Balanced")
        case .maximum: return String(localized: "Maximum")
        }
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
