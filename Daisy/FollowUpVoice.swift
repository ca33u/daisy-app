//
//  FollowUpVoice.swift
//  Daisy
//
//  Rewriting the follow-up draft in the user's own voice.
//
//  The follow-up is the one thing Daisy produces that leaves the
//  building with the user's name on it. Everything else — notes,
//  action items, the transcript — is read by the person who recorded
//  it. The follow-up is read by their client. So of all the text in a
//  summary, this is the paragraph where sounding like a language model
//  costs something real, and the Voice Profile already knows how they
//  write.
//
//  A SECOND PASS, not a longer prompt. Folding the style instruction
//  into the summary prompt would be one call instead of two, and it was
//  the first thing tried on paper — but it puts a paragraph about tone
//  in the same breath as the JSON schema and the section rules, where it
//  bleeds into bullet phrasing and competes for a local model's context
//  (the exact pressure that broke summaries for a tester in July). This
//  way the summary is produced exactly as before, and only the follow-up
//  is rewritten, through the same path that already polishes dictation —
//  including its length gate, which rejects a "polish" that came back as
//  a summary or an invented letter.
//
//  OFF BY DEFAULT, because it is a second provider call on every meeting
//  that has a follow-up: real money on a cloud provider, and another
//  model round trip on a machine that just finished transcribing.
//

import Foundation
import os

@MainActor
enum FollowUpVoice {

    /// Bounded like the dictation polish: a follow-up is a few
    /// paragraphs, and if the provider hasn't answered by now the user is
    /// better served by the unpolished draft than by waiting.
    private static let deadlineSeconds: Double = 25

    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "FollowUpVoice")

    /// Return `summary` with its follow-up rewritten in the user's voice,
    /// or unchanged — which is the answer whenever anything at all is
    /// missing: the setting, a profile, a follow-up, or a usable reply.
    /// Never fails loudly: a follow-up in the model's voice is a small
    /// disappointment, an empty one is a bug.
    static func polished(_ summary: MeetingSummary) async -> MeetingSummary {
        guard AppSettings.followUpsInMyVoiceEnabled else { return summary }
        let draft = summary.clientFollowUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return summary }
        // The follow-up's language is the summary language when one is
        // pinned (that is exactly why the setting exists — record in one
        // language, write to the client in another), otherwise whatever
        // the draft turned out to be. No nudge toast from here: this runs
        // after a meeting, with nobody watching for it.
        let target = VoiceCorpusClassifier.normalized(AppSettings.currentSummaryLanguage)
            ?? LanguageDetector.detect(draft)
        guard let style = VoiceProfileStore.shared.resolveStyle(forTextIn: target),
              !style.instruction.isEmpty else { return summary }

        guard let rewritten = await RecordingSession.polishWithDeadline(
            text: draft,
            instruction: instruction(for: style.promptInstruction),
            seconds: deadlineSeconds
        )?.trimmingCharacters(in: .whitespacesAndNewlines), !rewritten.isEmpty else {
            log.info("Follow-up left as drafted — voice polish returned nothing usable")
            return summary
        }

        log.info("Follow-up rewritten in the user's voice")
        return MeetingSummary(
            summary: summary.summary,
            sections: summary.sections,
            actionItems: summary.actionItems,
            clientFollowUp: rewritten
        )
    }

    /// The style profile plus two corrections, because this borrows the
    /// DICTATION polish prompt rather than owning one.
    ///
    /// The borrowed prompt expects speech: it offers to remove
    /// disfluencies and false starts, and a weak local model handed a
    /// clean written email with those instructions can reasonably decide
    /// there is nothing to do and hand it back — a call paid for and
    /// nothing gained. So the framing is corrected here.
    ///
    /// The language line matters more. A profile generated from Russian
    /// dictation is itself written in Russian, and the borrowed prompt's
    /// only language rule is "keep the user's language" — so a user who
    /// sets Summary language to English for client mail can get an
    /// English draft rewritten back into Russian by their own style
    /// description. The length gate can't catch that: the character
    /// count barely moves.
    private static func instruction(for style: String) -> String {
        """
        \(style)

        Two things about THIS text specifically:
          - It is a WRITTEN follow-up message, not dictation. There are no
            disfluencies or speech-to-text errors to repair. Rewrite it so
            it reads as if this person had written it themselves, and keep
            every fact, name, date, number and commitment exactly as it
            stands.
          - Write in the SAME language as the text you are given, even if
            the voice description above is written in another language.
        """
    }
}
