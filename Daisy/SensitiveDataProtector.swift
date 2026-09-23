//
//  SensitiveDataProtector.swift
//  Daisy
//
//  Local, per-request privacy transform for cloud summary providers.
//  The engine — recognizers, reversible markers, tolerant restore —
//  moved to DaisyCore (`PseudonymSession`, 2026-09-23, backlog 19 А-2а)
//  so the phone runs the same code; what is left here is the Mac's own
//  vocabulary of tasks and requests. Context-bearing entities receive
//  reversible typed pseudonyms; secrets and payment-card numbers are
//  redacted irreversibly. The replacement dictionary never leaves the
//  session and is discarded after the provider reply is restored.
//

import DaisyCore
import Foundation

/// The only object allowed to carry the local token → original dictionary.
/// It is a value type, is never encoded, and is intended to live only across
/// one provider request.
nonisolated struct ProtectedSummaryRequest: Sendable {
    let transcript: String
    let title: String
    let task: SummaryTask
    let report: SensitiveDataProtectionReport

    fileprivate let session: PseudonymSession

    func restore(_ summary: MeetingSummary) -> MeetingSummary {
        MeetingSummary(
            summary: restore(summary.summary),
            sections: summary.sections.map { section in
                SummarySection(
                    title: restore(section.title),
                    bullets: section.bullets.map(restore)
                )
            },
            actionItems: summary.actionItems.map(restore),
            clientFollowUp: restore(summary.clientFollowUp)
        )
    }

    private func restore(_ bullet: SummaryBullet) -> SummaryBullet {
        SummaryBullet(
            text: restore(bullet.text),
            children: bullet.children.map(restore)
        )
    }

    private func restore(_ text: String) -> String {
        session.restore(text)
    }
}

/// Generic counterpart of `ProtectedSummaryRequest` for features that
/// don't speak `MeetingSummary` — currently the plan-analysis pipeline,
/// whose provider returns raw JSON. Same lifetime contract: value type,
/// never encoded, lives across exactly one provider request. The caller
/// runs `restore(_:)` over every model-produced string before it is
/// validated or persisted.
nonisolated struct ProtectedPlanAnalysisRequest: Sendable {
    let title: String
    /// Plan-item texts in the caller's original order, ids untouched.
    let planItemTexts: [String]
    let transcript: String
    let report: SensitiveDataProtectionReport

    fileprivate let session: PseudonymSession

    func restore(_ text: String) -> String {
        session.restore(text)
    }
}

nonisolated enum SensitiveDataProtector {
    static func shouldProtect(enabled: Bool, providerIsLocal: Bool) -> Bool {
        enabled && !providerIsLocal
    }

    /// Put the originals back — tolerant of mangled markers; see
    /// `PseudonymSession.restore(_:using:)`.
    nonisolated static func restore(_ text: String, using originals: [String: String]) -> String {
        PseudonymSession.restore(text, using: originals)
    }

    /// True when any pseudonym or redaction marker survived `restore`.
    /// Callers that put model output in front of a person — the polish
    /// passes — must refuse such a result rather than ship a placeholder
    /// into someone's transcript or text field.
    nonisolated static func containsUnrestoredMarker(_ text: String) -> Bool {
        PseudonymSession.containsUnrestoredMarker(text)
    }

    /// Plan-analysis boundary: pseudonymize the plan FIRST so canonical
    /// plan wording seeds the mapping, then the title, then the
    /// transcript — mentions of the same entity in all three share one
    /// token, which is what lets evidence quotes survive the round-trip
    /// (restored quote == raw-transcript text the validator checks).
    static func protectPlanAnalysis(
        title: String,
        planItemTexts: [String],
        transcript: String,
        detectNamedEntities: Bool = true
    ) -> ProtectedPlanAnalysisRequest {
        var session = PseudonymSession(detectNamedEntities: detectNamedEntities)
        let protectedPlan = planItemTexts.map { session.protect($0) }
        let protectedTitle = session.protect(title)
        let protectedTranscript = session.protect(transcript)
        return ProtectedPlanAnalysisRequest(
            title: protectedTitle,
            planItemTexts: protectedPlan,
            transcript: protectedTranscript,
            report: session.report,
            session: session
        )
    }

    static func protect(
        transcript: String,
        title: String,
        task: SummaryTask,
        detectNamedEntities: Bool = true
    ) -> ProtectedSummaryRequest {
        // The polish passes rewrite the person's OWN words and hand them
        // straight back — into transcript.md, or into whatever field
        // they're dictating into. An irreversible `[[REDACTED_SECRET]]`
        // has nowhere to be restored from, so it would simply replace
        // what was said (audit 2026-09-01). Everything is reversible on
        // those tasks instead: the same privacy on the wire — the
        // provider still never sees the real value — with the original
        // restored locally afterwards.
        let reversibleOnly: Bool
        switch task {
        case .dictationPolish, .transcriptPolish: reversibleOnly = true
        default:                                  reversibleOnly = false
        }
        var context = TaskContext(session: PseudonymSession(
            detectNamedEntities: detectNamedEntities, reversibleOnly: reversibleOnly))

        // Task context first: canonical attendee/company names from calendar
        // metadata become the stable mapping that shorter transcript mentions
        // can reuse.
        let protectedTask = context.protect(task: task)
        let protectedTitle = context.protect(title)
        let protectedTranscript = context.protect(transcript)

        return ProtectedSummaryRequest(
            transcript: protectedTranscript,
            title: protectedTitle,
            task: protectedTask,
            report: context.session.report,
            session: context.session
        )
    }

    /// The Mac's task vocabulary, walked through one session.
    private struct TaskContext {
        var session: PseudonymSession

        mutating func protect(_ text: String) -> String {
            session.protect(text)
        }

        mutating func protect(task: SummaryTask) -> SummaryTask {
            switch task {
            case .meeting:
                return task
            case .preMeetingBrief(let info):
                return .preMeetingBrief(
                    SummaryPrompt.BriefPromptInfo(
                        meetingTitle: protect(info.meetingTitle),
                        attendees: info.attendees.map { protect($0) },
                        lastMetPhrase: info.lastMetPhrase.map { protect($0) },
                        includesWebContext: info.includesWebContext
                    )
                )
            case .voiceProfile, .catchUp, .morningBrief:
                return task
            case .dictationPolish(let instruction):
                return .dictationPolish(instruction: protect(instruction))
            case .transcriptPolish(let context):
                return .transcriptPolish(
                    TranscriptPolisher.PromptContext(
                        attendees: context.attendees.map { protect($0) },
                        vocabulary: context.vocabulary.map { protect($0) },
                        meetingApp: context.meetingApp.map { protect($0) }
                    )
                )
            case .speakerNames(let context):
                return .speakerNames(
                    SpeakerNameSuggester.PromptContext(
                        attendees: context.attendees.map { protect($0) },
                        labels: context.labels
                    )
                )
            }
        }
    }
}
