import Foundation
import Testing
@testable import Daisy

/// "Help make Daisy better" (2026-10-18). Never touches the real counts
/// file or the person's choice: a test store lives in a temporary folder.
@Suite("Anonymous feature counts")
struct ImprovementStatsTests {
    private var everyEvent: [ImprovementStats.Event] {
        var events: [ImprovementStats.Event] = [
            .recordingStarted(fromCalendar: true), .recordingStarted(fromCalendar: false),
            .recordingSaved(seconds: 60), .recordingSaved(seconds: 30 * 60), .recordingSaved(seconds: 2 * 3600),
            .recordingFailed, .recordingMicOnly, .voiceNoteSaved, .transcriptionFailed,
            .dictation(engine: "whisper"), .dictation(engine: "parakeet"), .dictation(engine: "apple_speech"),
            .dictationRepaste, .importFile, .importArchive, .iPhoneAudioReceived, .syncPulled,
            .exportMarkdown, .exportArchive, .exportNotion, .exportClaude, .exportAudio,
            .mcpToolCall(failed: true), .screenshotNote, .momentMarked, .layoutFixed, .layoutUndo,
            .voiceProfileGenerated, .catchUpUsed, .speakersNamed, .speakersMatched,
        ]
        for kind in SummaryProviderKind.allCases {
            events += [.summary(kind, viaAccount: false), .summaryFailed(kind, viaAccount: false)]
        }
        events += [.summary(.openai, viaAccount: true), .summaryFailed(.openai, viaAccount: true)]
        return events
    }

    @Test func everyEventIsOnThePublishedList() {
        let used = Set(everyEvent.flatMap(\.names))
        #expect(used.subtracting(ImprovementStats.publishedNames).isEmpty)
        #expect(ImprovementStats.publishedNames.subtracting(used).isEmpty)
        // An engine Daisy does not know yet is counted, but never named.
        #expect(ImprovementStats.Event.dictation(engine: "something new").names == ["dictation.done"])
    }

    @Test func aReportCarriesCountsAndVersionsOnly() throws {
        let report = ImprovementStats.report(day: "2026-10-17", counts: ["recording.saved": 2])
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        #expect(Set(json.keys) == ["schema", "day", "app", "version", "build", "channel", "os", "language", "sync", "counts"])
        #expect(report.channel == "beta" || report.channel == "stable")
        #expect(report.language.count == 2)
    }

    @Test func daysAreUTCAndTheStoreAddsAndForgets() throws {
        #expect(ImprovementStats.day(Date(timeIntervalSince1970: 1_792_195_200)) == "2026-10-17")
        #expect(ImprovementStats.day(Date(timeIntervalSince1970: 1_792_195_199)) == "2026-10-16")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("improvement-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ImprovementStats.Store(url: url)
        store.add(["dictation.done", "dictation.engine.whisper"], count: 1, day: "2026-10-17")
        store.add(["dictation.done"], count: 2, day: "2026-10-17")
        #expect(ImprovementStats.Store(url: url).days() == ["2026-10-17": ["dictation.done": 3, "dictation.engine.whisper": 1]])
        store.remove(day: "2026-10-17")
        #expect(ImprovementStats.Store(url: url).days().isEmpty)
        store.add(["layout.fixed"], count: 1, day: "2026-10-18")
        store.clear()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
