import Foundation
import Testing
@testable import DaisyCore

@Suite("Pseudonyms: what leaves the phone for a provider")
struct PseudonymSessionTests {
    @Test func contactsAreReversibleSecretsAndCardsAreGone() {
        var session = PseudonymSession(detectNamedEntities: false)
        let sent = session.protect("""
        Email jane@example.com or call +1 (415) 555-2671.
        Open https://example.com/private and use api_key=supersecretvalue.
        The card is 4111 1111 1111 1111.
        Email jane@example.com again.
        """)
        #expect(!sent.contains("jane@example.com"))
        #expect(!sent.contains("415"))
        #expect(!sent.contains("supersecretvalue"))
        #expect(!sent.contains("4111 1111 1111 1111"))
        #expect(sent.components(separatedBy: "[[DAISY_EMAIL_001]]").count == 3)
        #expect(sent.contains("[[REDACTED_SECRET]]"))
        #expect(sent.contains("[[REDACTED_PAYMENT_CARD]]"))

        let back = session.restore(MeetingSummary(
            summary: "Write [[DAISY_EMAIL_001]]",
            sections: [SummarySection(title: "Contacts", bullets: [SummaryBullet(text: "Call [[DAISY_PHONE_001]]")])],
            actionItems: ["See [[DAISY_URL_001]]"],
            clientFollowUp: ""))
        #expect(back.summary == "Write jane@example.com")
        #expect(back.sections[0].bullets[0].text == "Call +1 (415) 555-2671")
        #expect(back.actionItems[0] == "See https://example.com/private")

        let report = session.report
        #expect(report.redactedOccurrences == 2)
        #expect(report.replacementsByKind[.email] == 1)
        #expect(report.replacementsByKind[.phone] == 1)
    }

    /// The first user's meeting, 23.09 — Russian, where `NLTagger` sees
    /// almost no names. The people Daisy already knows go by dictionary,
    /// in every case form.
    @Test func knownRussianNamesGoInEveryCase() {
        var session = PseudonymSession(detectNamedEntities: false,
                                       knownPeople: ["Влад", "Мария Иванова", "Кирилл", "Алина"])
        let sent = session.protect("""
        Привет, Влад! Я решила тебе отдать этих ребят. Кирилл, добрый день!
        Передай Владу, что с Владом всё согласовали. У Марии есть вопрос к Алине.
        Мария Иванова пришлёт договор Кириллу.
        """)
        for name in ["Влад", "Владу", "Владом", "Кирилл", "Кириллу", "Марии", "Алине", "Мария Иванова"] {
            #expect(!sent.contains(name), "\(name) left the phone")
        }
        // «Владимир» is not «Влад»: a stem is matched with its endings only.
        var other = PseudonymSession(detectNamedEntities: false, knownPeople: ["Влад"])
        #expect(other.protect("Владимир Петрович").contains("Владимир"))

        let back = session.restore("Договорились: [[DAISY_PERSON_001]] и [[daisy_person_002]] созвонятся.")
        #expect(back == "Договорились: Влад и Мария Иванова созвонятся.")
        #expect(!PseudonymSession.containsUnrestoredMarker(back))
    }

    @Test func oneNameSharedByTwoPeopleIsLeftToTheFullForms() {
        var session = PseudonymSession(detectNamedEntities: false, knownPeople: ["Анна Смирнова", "Анна Козлова"])
        let sent = session.protect("Анна Смирнова и Анна Козлова. Анна опоздала.")
        #expect(!sent.contains("Смирнова") && !sent.contains("Козлова"))
        #expect(sent.contains("Анна опоздала"))
    }

    @Test func aSecretURLIsNeverRestored() {
        let url = "https://example.com/callback?access_token=topsecret123456"
        var session = PseudonymSession(detectNamedEntities: false)
        let sent = session.protect("Open \(url)")
        #expect(!sent.contains(url))
        #expect(!session.restore(sent).contains(url))
        #expect(PseudonymSession.containsUnrestoredMarker(session.restore(sent)))
    }

    @Test func markersComeBackEvenWhenTheModelMangledThem() {
        var session = PseudonymSession(detectNamedEntities: false, knownPeople: ["Влад"])
        _ = session.protect("Влад")
        #expect(session.restore("[[ daisy_PERSON_001 ]] сказал") == "Влад сказал")
    }
}
