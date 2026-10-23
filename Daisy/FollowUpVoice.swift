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

    /// Return `summary` with its follow-up rewritten in the user's voice —
    /// and, with a follow-up template, in its structure, in the same call
    /// (backlog 35 Ш-1) — or unchanged, which is the answer whenever
    /// anything at all is missing: the setting (a template turns the pass
    /// on by itself), a profile or a template, a follow-up, or a usable
    /// reply. Never fails loudly: a follow-up in the model's voice is a
    /// small disappointment, an empty one is a bug.
    ///
    /// `voice: false` — the paths that leave the voice out on purpose (the
    /// evening pass, imports, MCP: nobody is waiting, every call costs) —
    /// apply only a template.
    ///
    /// `language`: the language to write the letter in («ru», «en»…) — a
    /// pick from the meeting card, or the meeting's own when the pick is
    /// taken back. The caller remembers it; this only writes.
    static func polished(_ summary: MeetingSummary, template: MeetingTemplate? = nil,
                         pickedByHand: Bool = false, voice: Bool = true, language: String? = nil,
                         marksUse: Bool = true) async -> MeetingSummary {
        let structure = template.map(\.structure).flatMap { $0.isEmpty ? nil : $0 }
        let wantsVoice = voice && AppSettings.followUpsInMyVoiceEnabled
        let languageName = SummaryPrompt.explicitLanguageName(for: language)
        guard wantsVoice || structure != nil || languageName != nil else { return summary }
        let draft = summary.clientFollowUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return summary }
        // The follow-up's language is the summary language when one is
        // pinned (that is exactly why the setting exists — record in one
        // language, write to the client in another), otherwise whatever
        // the draft turned out to be. No nudge toast from here: this runs
        // after a meeting, with nobody watching for it.
        let target = languageName != nil ? language
            : VoiceCorpusClassifier.normalized(AppSettings.currentSummaryLanguage) ?? LanguageDetector.detect(draft)
        // The voice only with the setting on: a template alone rewrites the
        // structure, not the person's tone.
        let style = wantsVoice
            ? VoiceProfileStore.shared.resolveStyle(forTextIn: target).flatMap { $0.instruction.isEmpty ? nil : $0 }
            : nil
        guard style != nil || structure != nil || languageName != nil else { return summary }

        guard let rewritten = await RecordingSession.polishWithDeadline(
            text: draft,
            instruction: instruction(for: style?.promptInstruction, structure: structure, languageName: languageName),
            seconds: deadlineSeconds,
            // A template can make a long draft a short letter; another
            // language can be far shorter (Chinese) or longer.
            minShare: structure == nil && languageName == nil ? 0.4 : 0.15,
            maxShare: languageName == nil ? 2.5 : 5
        )?.trimmingCharacters(in: .whitespacesAndNewlines), !rewritten.isEmpty else {
            log.info("Follow-up left as drafted — the second pass returned nothing usable")
            return summary
        }
        // Asked for another language: a reply still in the old one (the
        // borrowed polish prompt says to keep the user's language, and a
        // weak model obeys it) is not the translation it would be shown as.
        if languageName != nil, let language, let detected = LanguageDetector.detect(rewritten),
           !detected.hasPrefix(String(language.prefix(2))) {
            log.info("Follow-up left as it was — the rewrite didn't come back in the language asked for")
            return summary
        }

        log.info("Follow-up rewritten (voice: \(style != nil, privacy: .public), template: \(structure != nil, privacy: .public))")
        // A copy, not a rebuilt summary: the title and a template's notes
        // stay with it.
        var result = summary
        result.clientFollowUp = rewritten
        if let template, structure != nil {
            result.followUpTemplate = TemplateReference(name: template.name, id: template.id.uuidString,
                                                        pickedByHand: pickedByHand ? true : nil)
            // Not for the tour's demo meeting (`marksUse`): neither counted
            // nor moved up the template list.
            if marksUse { MeetingTemplateStore.shared.markUsed(template.id.uuidString) }
        } else {
            // Rewritten without a template: a name left from an earlier one
            // would describe a letter that isn't its any more.
            result.followUpTemplate = nil
        }
        return result
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
    private static func instruction(for style: String?, structure: String?, languageName: String?) -> String {
        var parts: [String] = []
        if let style { parts.append(style) }
        if let structure {
            // Research 21.10: a follow-up that doesn't read like a model's —
            // about THIS meeting from the first line, no transcript bullets,
            // nothing invented, unknowns marked for the person to fill.
            parts.append("""
            Lay the message out by this structure the user set for such letters — its parts, their order and its length:
            \(structure)
            Take every fact from the text you are given and nothing else: a part of the structure the text gives nothing for is left out, not filled. The first line is about this meeting specifically. Don't turn it into a list of everything that was said. Where the structure needs something the text doesn't say (a date, a name), write [?] in its place.
            """)
        }
        parts.append("""
        Two things about THIS text specifically:
          - It is a WRITTEN follow-up message, not dictation. There are no
            disfluencies or speech-to-text errors to repair. Rewrite it so
            it reads as if this person had written it themselves, and keep
            every fact, name, date, number and commitment exactly as it
            stands.
          - \(languageName.map { "Write the message in \($0), whatever language the text you are given is in; translate it faithfully, keeping every fact." }
                ?? "Write in the SAME language as the text you are given, even if the voice description or the structure above is written in another language.")
        """)
        return parts.joined(separator: "\n\n")
    }
}
