//
//  VoiceNoteProfile.swift
//  Daisy
//
//  A Mac voice note in the session format, and the rule its summary
//  follows (Egor 07.11.2026).
//
//  Flow reads the library as files and wants a voice note in its inbox as
//  a note (a task when an action was named), so a voice note says what it
//  is: `daisy_voice_note: true`, right after `daisy_kind: note`, written by
//  `MarkdownExporter` at Stop and at the final pass (session-format.md
//  §3.4 «Voice notes (Mac)»). A Daisy-key note and a side note are notes
//  of their own shapes, not voice notes, and never carry it. Voice notes
//  written before the key are recognised by their shape and get no key
//  written into them — no sweep through the library.
//
//  The summary: a voice note is one person thinking aloud, so it is
//  summarized in that person's voice (`SummaryTask.summary(oneVoice:)`,
//  DaisyCore's one-voice rules). It is summarized on its own, at the time
//  meetings are, when the provider keeps it on this Mac; a cloud provider
//  gets it only with «Summarize voice notes with …» on — off by default,
//  so updating Daisy never starts sending notes anywhere — and only a note
//  recorded while it was on (`Gate`).
//

import DaisyCore
import Foundation

nonisolated enum VoiceNoteProfile {
    /// The rule is DaisyCore's (`VoiceNoteRecognition`): the phone reads
    /// the same one to keep a Mac voice note out of its own requests.
    typealias Recognition = VoiceNoteRecognition

    /// The marker key. Written only as `true`, and only beside
    /// `daisy_kind: note`.
    static var frontmatterKey: String { VoiceNoteRecognition.frontmatterKey }
    static var otherNoteMarkers: Set<String> { VoiceNoteRecognition.otherNoteMarkers }
    static var sourceMeetingKey: String { VoiceNoteRecognition.sourceMeetingKey }

    /// What a `transcript.md` says about itself, in the Mac's terms —
    /// `kind` as `SessionStore` resolved it (`daisy_kind:`, or the Notes
    /// folder for files from before it).
    static func recognise(kind: SessionKind, marker: String?, otherNoteProfile: Bool,
                          origin: String? = nil, systemAudioStatus: String?,
                          durationSec: Int, body: String) -> Recognition {
        VoiceNoteRecognition.recognise(isNote: kind == .note, marker: marker, otherNoteProfile: otherNoteProfile,
                                       origin: origin, systemAudioStatus: systemAudioStatus,
                                       durationSec: durationSec, body: body)
    }

    static func isTrue(_ raw: String) -> Bool { VoiceNoteRecognition.isTrue(raw) }

    // MARK: - The summary gate

    /// Whether a voice note may be summarized without being asked (Egor
    /// 07.11). Read again right before anything is sent — a pass planned
    /// at Stop or at the start of the evening may reach the provider
    /// minutes later, after the switch or the provider changed.
    struct Gate: Sendable, Equatable {
        /// `Summarizer.providerIsEffectivelyLocal` — never
        /// `providerKind.isLocal`, which says yes for an Ollama pointed at
        /// another host.
        var providerIsEffectivelyLocal: Bool
        /// «Summarize voice notes with …».
        var summarizeInCloud: Bool
        /// When the switch was last turned on; nil while it is off.
        var cloudAllowedSince: Date?

        /// On this Mac: always — nothing leaves it. A cloud provider: only
        /// a note recorded while the switch was on (its start at or after
        /// the moment it was turned on), and only while it still is, so
        /// turning it on never sends the notes recorded before. A note
        /// with no known start, or a switch on with no moment, fails
        /// closed.
        func allows(recordedAt: Date?) -> Bool {
            if providerIsEffectivelyLocal { return true }
            guard summarizeInCloud, let since = cloudAllowedSince, let recordedAt else { return false }
            return recordedAt >= since
        }

        /// The gate as the settings and the provider stand now.
        @MainActor
        static var current: Gate {
            current(providerIsEffectivelyLocal: Summarizer.shared.providerIsEffectivelyLocal,
                    provider: Summarizer.shared.voiceNoteDestination, switch: VoiceNoteCloudSwitch())
        }

        /// The switch counts only for the provider it was turned on for.
        static func current(providerIsEffectivelyLocal: Bool, provider: String,
                            switch cloudSwitch: VoiceNoteCloudSwitch) -> Gate {
            let since = cloudSwitch.since(for: provider)
            return Gate(providerIsEffectivelyLocal: providerIsEffectivelyLocal,
                        summarizeInCloud: since != nil, cloudAllowedSince: since)
        }
    }

    /// A stored session's voice note, summarized on its own: one recorded
    /// with its key — never one from before the update — that the gate
    /// lets through. When it runs is the meetings' «Summarize».
    static func summarizesOnItsOwn(_ voiceNote: Recognition, recordedAt: Date?, gate: Gate) -> Bool {
        voiceNote == .marked && gate.allows(recordedAt: recordedAt)
    }

    /// Whether an earlier session's words — its summary, its action
    /// items, its transcript — may ride along in a request about something
    /// else (a project's memory, the morning brief, a pre-meeting dossier)
    /// to the provider `gate` describes. A voice note, with its key or from
    /// before it, only as its own summary could go: the gate is the same,
    /// so a note kept on this Mac isn't carried out by a later meeting's
    /// request. Everything else, as before.
    ///
    /// `kindKnown` false — the transcript evicted to iCloud, unreadable or
    /// missing, so the session can't be told from a voice note — fails closed: such
    /// a session's words go to a provider on this Mac, never to a cloud
    /// one, until its transcript is back. That leaves an evicted meeting
    /// out of a cloud request too, which costs a little context; the other
    /// way would carry an evicted voice note out.
    static func mayFeed(isVoiceNote: Bool, kindKnown: Bool, recordedAt: Date?, gate: Gate) -> Bool {
        guard kindKnown else { return gate.providerIsEffectivelyLocal }
        return !isVoiceNote || gate.allows(recordedAt: recordedAt)
    }

    // MARK: - Notes a provider declined

    /// Voice notes the summary provider couldn't do — too long for an
    /// on-device model, a language it doesn't write — left quietly and
    /// remembered here, outside the session folder, so the evening pass
    /// doesn't try them every night: not tried again by that provider (for
    /// 30 days) — another provider may, and the person can always ask.
    struct Declines {
        static let defaultsKey = "daisy.voiceNoteSummaryDeclines"
        /// Older entries go: the evening pass looks back a week.
        static let keepDays: Double = 30
        let defaults: UserDefaults

        init(defaults: UserDefaults = .standard) { self.defaults = defaults }

        private var all: [String: [String: Any]] {
            defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String: Any]] ?? [:]
        }

        /// `provider`: `SummaryProviderKind.rawValue` of the one that declined.
        func record(_ sessionID: String, provider: String, now: Date = Date()) {
            let horizon = now.addingTimeInterval(-Self.keepDays * 86_400)
            var kept = all.filter { (($0.value["at"] as? Date) ?? .distantPast) >= horizon }
            kept[sessionID] = ["provider": provider, "at": now]
            defaults.set(kept, forKey: Self.defaultsKey)
        }

        /// Declined by `provider` within the last `keepDays`.
        func declined(_ sessionID: String, by provider: String, now: Date = Date()) -> Bool {
            guard let entry = all[sessionID], (entry["provider"] as? String) == provider,
                  let at = entry["at"] as? Date else { return false }
            return at >= now.addingTimeInterval(-Self.keepDays * 86_400)
        }
    }
}
