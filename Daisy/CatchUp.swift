//
//  CatchUp.swift
//  Daisy
//
//  "What did I miss?" — a summary of the last few minutes of a meeting
//  that is still being recorded. You step out for coffee, come back,
//  and get the thread instead of scrolling a live transcript.
//
//  Deliberately ephemeral. Nothing is written to the session: not to
//  transcript.md, not to summary.json, not to the sidecars. It is a
//  glance at the last five minutes, not a second summary competing
//  with the real one — and a user who asks three times in a meeting
//  should not find three artifacts in their folder afterwards.
//
//  The echo pass is not optional here. On speakers the mic re-captures
//  the other party, so the last five minutes contain every remote line
//  twice — once as them, once as the user. A catch-up built on that
//  tells the user what THEY supposedly said while they were out of the
//  room, which is worse than no catch-up at all.
//

import Foundation
import os

enum CatchUp {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "CatchUp")

    /// How far back the recap reaches. Five minutes is a coffee, a
    /// doorbell, or one tangent you tuned out of.
    static let windowMinutes: Double = 5

    /// Ceiling on the slice handed to the model. Five minutes of dense
    /// two-way speech is comfortably under this; the cap only bites on
    /// a very fast talker, and it trims the OLDEST lines so the most
    /// recent thread — the part the user is about to rejoin — survives.
    static let characterBudget = 6_000

    /// The user is waiting and watching. A recap that takes longer than
    /// this is no longer a recap; they'd have read the transcript.
    static let deadlineSeconds: Double = 30

    /// Below this there is nothing to summarize and a model asked to
    /// try will pad.
    static let minimumCharacters = 200

    // MARK: - Slice

    /// The last `windowMinutes` of speech, echo-filtered and rendered
    /// with speaker labels.
    ///
    /// Filtering runs over the WHOLE session, not just the window: the
    /// echo detector matches a mic segment against system segments
    /// within ±2s, and slicing first would strip the system-side
    /// original of any echo sitting near the window's leading edge,
    /// letting it through as if it were the user talking.
    static func slice(
        segments: [TranscriptSegment],
        now: Date,
        displayName: String,
        suppressEcho: Bool,
        windowMinutes: Double = windowMinutes,
        budget: Int = characterBudget
    ) -> String {
        let deduped = suppressEcho ? AcousticEchoDedup.filteredQuietly(segments) : segments
        let cutoff = now.addingTimeInterval(-windowMinutes * 60)
        let recent = deduped.filter {
            $0.startedAt >= cutoff
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !recent.isEmpty else { return "" }

        var lines = recent.map { segment -> String in
            let flat = segment.text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return "[\(segment.speakerLabel(displayName: displayName))] \(flat)"
        }

        // Drop from the FRONT while over budget — the tail is what the
        // user is about to walk back into.
        var total = lines.reduce(0) { $0 + $1.count + 1 }
        while total > budget, lines.count > 1 {
            total -= lines.removeFirst().count + 1
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Run

    enum Outcome: Sendable {
        case recap(String)
        /// Not enough speech in the window to recap.
        case tooQuiet
        /// Provider unavailable, refused, or too slow.
        case unavailable
        /// A cloud provider is selected and this meeting isn't being
        /// summarized there anyway, so running would make a mid-meeting
        /// glance the first thing to send the transcript off-device.
        /// Carries the provider's short name for the explanation.
        case wouldLeaveThisMac(provider: String)
    }

    /// Summarize the slice. Never throws; the caller renders whichever
    /// outcome comes back.
    static func run(
        slice: String,
        localeHint: String?,
        summarize: @escaping @Sendable (String, SummaryTask) async throws -> MeetingSummary
    ) async -> Outcome {
        guard slice.count >= minimumCharacters else { return .tooQuiet }

        let started = Date()
        guard let text = await TranscriptPolisher.withDeadline(
            seconds: deadlineSeconds,
            operation: { try await summarize(slice, .catchUp).summary }
        ) else {
            log.info("Catch-up: no answer within \(Int(deadlineSeconds), privacy: .public)s")
            return .unavailable
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unavailable }
        log.info("Catch-up: \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)ms, \(trimmed.count, privacy: .public) chars from \(slice.count, privacy: .public)")
        ImprovementStats.record(.catchUpUsed)
        return .recap(trimmed)
    }
}

extension RecordingSession {
    /// Recap the last few minutes of THIS session. Writes nothing —
    /// the caller owns the result and throws it away when the popover
    /// closes.
    ///
    /// Uses `runProbe` rather than `summarize` so the recap can't land
    /// in `lastSummary`, which the session UI and the auto-send stage
    /// both read: a mid-meeting glance must not be mistaken for the
    /// meeting's summary.
    ///
    /// Same privacy rule as the post-stop passes: this runs only when
    /// the transcript is already going to the configured provider —
    /// either it never leaves the Mac, or the meeting is set to be
    /// summarized there when it ends. Without that check, tapping
    /// "What did I miss?" on a cloud provider with auto-summary off
    /// would be the FIRST thing to send this meeting off-device, from a
    /// button whose help text is about persistence. Ephemeral is not the
    /// same as local, and the gate is what makes the two agree.
    func catchUpRecap() async -> CatchUp.Outcome {
        guard summarizer.providerIsEffectivelyLocal || settings.autoSummarize else {
            return .wouldLeaveThisMac(provider: summarizer.providerKind.shortName)
        }
        let slice = CatchUp.slice(
            segments: segments,
            now: Date(),
            displayName: settings.userDisplayName,
            suppressEcho: settings.suppressAcousticEcho
        )
        let title = self.title
        let localeHint = Self.resolveSummaryLocaleHint(
            transcript: slice,
            transcriptLocale: localeIdentifier,
            summaryLanguageOverride: settings.summaryLanguage
        )
        return await CatchUp.run(
            slice: slice,
            localeHint: localeHint,
            summarize: { payload, task in
                try await Summarizer.shared.runProbe(
                    transcript: payload,
                    title: title,
                    localeHint: localeHint,
                    task: task
                )
            }
        )
    }
}
