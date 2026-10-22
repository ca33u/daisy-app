//
//  TranscriptSpeakersTests.swift
//  DaisyCoreTests
//
//  Бэклог 15 П-3. A summary stops inventing the other side of a
//  conversation when it knows there is only one voice. That knowledge
//  comes from here, so it has to be right about the awkward cases.
//

import Foundation
import Testing
@testable import DaisyCore

@Suite("How many voices are in a transcript")
struct TranscriptSpeakersTests {
    private let meeting = """
    **[0:00 · Me]** Let's start.
    **[0:12 · Remote A]** Sure.
    **[0:30 · Me]** Agreed then.
    """

    private let monologue = """
    **[0:00 · Me]** Note to self: renew the domain.
    **[0:21 · Me]** And call the accountant.
    """

    @Test func aMeetingNamesEveryoneOnce() {
        #expect(TranscriptSpeakers.distinct(inBody: meeting) == ["Me", "Remote A"])
        #expect(!TranscriptSpeakers.isSingleVoice(inBody: meeting))
    }

    @Test func aMonologueIsOneVoice() {
        #expect(TranscriptSpeakers.distinct(inBody: monologue) == ["Me"])
        #expect(TranscriptSpeakers.isSingleVoice(inBody: monologue))
    }

    /// The case that decides whether this is safe to hang a prompt on:
    /// a transcript with no speaker labels tells us nothing. Calling it
    /// a monologue would apply the narrower instructions to a meeting
    /// whose labelling merely failed — inventing silence instead of
    /// inventing attendees, which is the same mistake mirrored.
    @Test func noLabelsIsNotOneVoice() {
        #expect(TranscriptSpeakers.distinct(inBody: "just some text\nand more").isEmpty)
        #expect(!TranscriptSpeakers.isSingleVoice(inBody: ""))
    }

    @Test func speakersComeBackInTheOrderTheyFirstSpeak() {
        let body = """
        **[0:00 · Remote B]** Hi.
        **[0:04 · Me]** Hello.
        **[0:09 · Remote B]** Ready when you are.
        """
        #expect(TranscriptSpeakers.distinct(inBody: body) == ["Remote B", "Me"])
    }

    /// Names carry spaces, dots and non-Latin letters — the separator
    /// is the "·", not whitespace.
    @Test func realNamesSurvive() {
        let body = "**[1:02 · Егор Сазанов]** Привет.\n**[1:20 · Anna T.]** Hi."
        #expect(TranscriptSpeakers.distinct(inBody: body) == ["Егор Сазанов", "Anna T."])
    }

    @Test func theSingleVoiceInstructionsOnlyAppearForOneVoice() {
        let one = SummaryPrompt.meetingSystemInstructions(localeHint: "en", singleVoice: true)
        let many = SummaryPrompt.meetingSystemInstructions(localeHint: "en", singleVoice: false)
        #expect(one.contains("ONE VOICE IN THIS RECORDING"))
        #expect(!many.contains("ONE VOICE IN THIS RECORDING"))
        // The language directive must stay first — it is the one rule
        // that governs the whole response.
        #expect(SummaryPrompt.meetingSystemInstructions(localeHint: "ru", singleVoice: true)
            .hasPrefix("━━━ OUTPUT LANGUAGE: RUSSIAN"))
    }

    /// Egor 22.10: a note to self came back as a meeting "about nothing".
    /// One voice keeps the thought and drops the meeting's quotas; many
    /// voices keep the meeting rules unchanged.
    @Test func oneVoiceDropsTheMeetingQuotasManyVoicesKeepThem() {
        let one = SummaryPrompt.meetingSystemInstructions(localeHint: "ru", singleVoice: true)
        let many = SummaryPrompt.meetingSystemInstructions(localeHint: "ru", singleVoice: false)
        #expect(one.contains("keep the speaker's thought"))
        #expect(one.contains("0-4 sections, as many as the thought has"))
        #expect(one.contains("clientFollowUp is always empty."))
        #expect(!one.contains("3-5 sections total"))
        #expect(!one.contains("when in doubt, draft one"))
        #expect(many.contains("  - 3-5 sections total, ordered by importance (most decision-\n    heavy first).\n"))
        #expect(many.contains("when in doubt, draft one"))
        #expect(!many.contains("keep the speaker's thought"))
    }
}

@Suite("Speaker labels only count where they mean something")
struct SpeakerLabelMeaningTests {
    /// The case found on a real phone, 2026-09-23. A phone transcript
    /// labels every segment `Me` and carries an empty speaker map —
    /// so "one distinct name" is true of a two-person meeting too.
    @Test func aPhoneTranscriptSaysNothingAboutHowManySpoke() {
        let phoneBody = """
        **[0:00 · Me]** Да надо просто вот мне секунд.
        **[0:05 · Me]** Да, хорошо.
        """
        #expect(TranscriptSpeakers.isSingleVoice(inBody: phoneBody))
        #expect(!TranscriptSpeakers.labelsAreMeaningful(speakerMap: [:], diarization: nil))
    }

    @Test func aDiarizedTranscriptDoesCount() {
        #expect(TranscriptSpeakers.labelsAreMeaningful(speakerMap: ["Remote A": "Anna"], diarization: nil))
        #expect(TranscriptSpeakers.labelsAreMeaningful(speakerMap: [:], diarization: "pyannote"))
    }

    /// An explicit "none" is a statement that nothing diarized it — it
    /// must not read as evidence that something did.
    @Test func anExplicitNoneIsNotDiarization() {
        #expect(!TranscriptSpeakers.labelsAreMeaningful(speakerMap: [:], diarization: "none"))
        #expect(!TranscriptSpeakers.labelsAreMeaningful(speakerMap: nil, diarization: ""))
    }
}
