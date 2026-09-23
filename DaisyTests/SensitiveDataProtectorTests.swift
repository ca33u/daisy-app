import struct DaisyCore.SensitiveDataProtectionReport
import Foundation
import Testing
@testable import Daisy

@Suite("Sensitive data protection")
struct SensitiveDataProtectorTests {
    @Test("The user switch and provider locality both gate protection")
    func gate() {
        #expect(!SensitiveDataProtector.shouldProtect(enabled: false, providerIsLocal: false))
        #expect(!SensitiveDataProtector.shouldProtect(enabled: true, providerIsLocal: true))
        #expect(SensitiveDataProtector.shouldProtect(enabled: true, providerIsLocal: false))
    }

    @Test("Contact data is reversible while secrets and cards stay redacted")
    func reversibleAndIrreversibleClasses() {
        let input = """
        Email jane@example.com or call +1 (415) 555-2671.
        Open https://example.com/private and use api_key=supersecretvalue.
        The card is 4111 1111 1111 1111.
        Email jane@example.com again.
        """
        let protected = SensitiveDataProtector.protect(
            transcript: input,
            title: "Customer follow-up",
            task: .standard,
            detectNamedEntities: false
        )

        #expect(!protected.transcript.contains("jane@example.com"))
        #expect(!protected.transcript.contains("415"))
        #expect(!protected.transcript.contains("https://example.com/private"))
        #expect(!protected.transcript.contains("supersecretvalue"))
        #expect(!protected.transcript.contains("4111 1111 1111 1111"))
        #expect(protected.transcript.contains("[[DAISY_EMAIL_001]]"))
        #expect(protected.transcript.components(separatedBy: "[[DAISY_EMAIL_001]]").count == 3)
        #expect(protected.transcript.contains("[[REDACTED_SECRET]]"))
        #expect(protected.transcript.contains("[[REDACTED_PAYMENT_CARD]]"))

        let remote = MeetingSummary(
            summary: protected.transcript,
            sections: [
                SummarySection(
                    title: "Contacts",
                    bullets: [SummaryBullet(text: "Write [[DAISY_EMAIL_001]]")]
                )
            ],
            actionItems: ["Call [[DAISY_PHONE_001]]"],
            clientFollowUp: "See [[DAISY_URL_001]]"
        )
        let restored = protected.restore(remote)

        #expect(restored.summary.contains("jane@example.com"))
        #expect(restored.sections[0].bullets[0].text.contains("jane@example.com"))
        #expect(restored.actionItems[0].contains("+1 (415) 555-2671"))
        #expect(restored.clientFollowUp.contains("https://example.com/private"))
        #expect(!restored.summary.contains("supersecretvalue"))
        #expect(!restored.summary.contains("4111 1111 1111 1111"))
    }

    @Test("Task metadata is transformed with the same request context")
    func taskMetadataIsProtected() {
        let task = SummaryTask.preMeetingBrief(
            SummaryPrompt.BriefPromptInfo(
                meetingTitle: "Planning with Jane Doe",
                attendees: ["Jane Doe", "john@example.com"],
                lastMetPhrase: "yesterday",
                includesWebContext: false
            )
        )
        let protected = SensitiveDataProtector.protect(
            transcript: "Jane Doe wrote to john@example.com.",
            title: "Planning with Jane Doe",
            task: task
        )

        guard case .preMeetingBrief(let info) = protected.task else {
            Issue.record("Expected a protected pre-meeting brief task")
            return
        }
        #expect(!info.attendees.joined().contains("john@example.com"))
        #expect(!protected.transcript.contains("john@example.com"))
        #expect(info.attendees[1] == "[[DAISY_EMAIL_001]]")
        #expect(protected.transcript.contains("[[DAISY_EMAIL_001]]"))
    }

    @Test("A URL carrying a secret is redacted rather than restored")
    func secretURLIsNeverRestored() {
        let url = "https://example.com/callback?access_token=topsecret123456"
        let protected = SensitiveDataProtector.protect(
            transcript: "Open \(url)",
            title: "Link",
            task: .standard,
            detectNamedEntities: false
        )
        #expect(!protected.transcript.contains(url))
        #expect(protected.transcript.contains("[[REDACTED_SECRET]]"))

        let restored = protected.restore(
            MeetingSummary(summary: protected.transcript, actionItems: [], clientFollowUp: "")
        )
        #expect(!restored.summary.contains(url))
        #expect(restored.summary.contains("[[REDACTED_SECRET]]"))
    }
}
