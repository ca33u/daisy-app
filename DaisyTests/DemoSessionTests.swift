import DaisyCore
import Foundation
import Testing
@testable import Daisy

/// The tour's demo meeting (Onboarding 2.0, 24.10). Every test installs into
/// its own temporary Library — never the person's — and nothing here reads
/// or writes `UserDefaults.standard`.
@MainActor
@Suite("Demo meeting")
struct DemoSessionTests {
    private let base: URL
    private let sessions: URL
    private let now = Date(timeIntervalSince1970: 1_792_843_200) // 2026-10-24 12:00 UTC

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-session-\(UUID().uuidString)", isDirectory: true)
        sessions = SessionsFolder.sessionsDirectory(in: base)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }

    private func fixture(_ language: String) throws -> DemoSession.Fixture {
        try #require(DemoSession.loadFixture(language: language))
    }

    private func install(_ language: String = "ru", name: String = "Егор", audio: URL? = nil) throws -> StoredSession {
        let id = try DemoSession.install(try fixture(language), language: language, userName: name,
                                         in: sessions, audio: audio, now: now)
        return try #require(SessionStore.parseSession(at: sessions.appendingPathComponent(id)))
    }

    /// The same meeting without the flag — what a real recording looks like.
    private func realCopy(of demo: StoredSession) throws -> StoredSession {
        let copy = sessions.appendingPathComponent("2026-10-20T09-00-00Z", isDirectory: true)
        try FileManager.default.copyItem(at: demo.directoryURL, to: copy)
        let transcript = copy.appendingPathComponent("transcript.md")
        let text = try String(contentsOf: transcript, encoding: .utf8)
            .replacingOccurrences(of: "\(DemoSession.frontmatterKey): true\n", with: "")
        try text.write(to: transcript, atomically: true, encoding: .utf8)
        return try #require(SessionStore.parseSession(at: copy))
    }

    @Test func bothFixturesAreComplete() throws {
        for language in ["ru", "en"] {
            let f = try fixture(language)
            #expect(f.durationSec == 124)
            #expect((12...16).contains(f.lines.count))
            #expect(Set(f.lines.map(\.speaker)) == [.anna, .me])
            #expect(f.lines.map(\.at) == f.lines.map(\.at).sorted())
            #expect((f.lines.last?.at ?? .max) < f.durationSec)
            #expect(f.actionItems.count == 2)
            #expect(f.actionItems[0].hasPrefix("{anna}:") && f.actionItems[1].hasPrefix("{me}:"))
            #expect(!f.summary.isEmpty && !f.sections.isEmpty)
        }
        #expect(try fixture("ru").title == "Демо: макеты лендинга")
        #expect(try fixture("en").title == "Demo: landing mockups")
    }

    @Test func installWritesAFinishedMeetingTheLibraryReads() throws {
        let s = try install()
        #expect(s.isDemo)
        #expect(s.title == "Демо: макеты лендинга")
        #expect(s.kind == .recording)
        #expect(s.folderSlug == "inbox")
        #expect(s.durationSec == 124)
        #expect(s.locale == "ru")
        #expect(s.startedAt == now.addingTimeInterval(-124))
        #expect(s.id == "2026-10-24T11-57-56Z")
        #expect(s.contentState == .transcript)
        #expect(!s.hasMicAudio && !s.hasSystemAudio)
        #expect(s.transcriptText.contains("**[0:00 · Анна]**"))
        #expect(s.transcriptText.contains("**[0:11 · Егор]**"))
        let summary = try #require(s.summary)
        #expect(summary.actionItems == ["Анна: макет первого экрана к четвергу", "Егор: отправить тексты Маше до пятницы"])
        #expect(summary.clientFollowUp.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: s.directoryURL.appendingPathComponent(".recording").path))
    }

    @Test func noNameMeansTyOrYou() throws {
        let ru = try install("ru", name: "  ")
        #expect(ru.transcriptText.contains("**[0:11 · Ты]**"))
        #expect(ru.summary?.actionItems.last?.hasPrefix("Ты:") == true)
        try FileManager.default.removeItem(at: ru.directoryURL)
        let en = try install("en", name: "")
        #expect(en.title == "Demo: landing mockups")
        #expect(en.transcriptText.contains("**[0:11 · You]**"))
        #expect(en.summary?.actionItems == ["Anna: first-screen mockup by Thursday", "You: send the copy to Masha by Friday"])
    }

    @Test func aSecondInstallFindsTheFirst() throws {
        let first = try install("ru")
        let again = try DemoSession.install(try fixture("en"), language: "en", userName: "Egor",
                                            in: sessions, audio: nil, now: now.addingTimeInterval(600))
        #expect(again == first.id)
        // Staging folders included: none is left behind.
        let folders = try FileManager.default.contentsOfDirectory(atPath: sessions.path).filter { $0 != ".DS_Store" }
        #expect(folders == [first.id])
        #expect(DemoSession.existingID(in: sessions) == first.id)
    }

    @Test func neverWritesIntoAnExistingFolder() throws {
        let taken = sessions.appendingPathComponent("2026-10-24T11-57-56Z", isDirectory: true)
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
        let s = try install()
        #expect(s.id == "2026-10-24T11-57-55Z")
        #expect(try FileManager.default.contentsOfDirectory(atPath: taken.path).isEmpty)
    }

    @Test func theFlagSurvivesAReloadAndAnEdit() throws {
        let s = try install()
        #expect(SessionStore.parseSession(at: s.directoryURL)?.isDemo == true)
        // A rename rewrites one front-matter line, as SessionStore.setTitle does.
        let transcript = try #require(s.transcriptURL)
        let text = try String(contentsOf: transcript, encoding: .utf8)
        try SessionStore.upsertFrontmatter(in: text, key: "title", value: "\"Мой разбор\"")
            .write(to: transcript, atomically: true, encoding: .utf8)
        let renamed = try #require(SessionStore.parseSession(at: s.directoryURL))
        #expect(renamed.title == "Мой разбор")
        #expect(renamed.isDemo)
        #expect(try realCopy(of: s).isDemo == false)
    }

    @Test func theAudioSlotIsUsedWhenFilled() throws {
        let audio = base.appendingPathComponent("ru.m4a")
        try Data(repeating: 0, count: 16).write(to: audio)
        let s = try install(audio: audio)
        #expect(s.hasSystemAudio)
        #expect(FileManager.default.fileExists(atPath: s.directoryURL.appendingPathComponent("system_audio.m4a").path))
    }

    @Test func statsSkipTheDemo() throws {
        let demo = try install()
        let real = try realCopy(of: demo)

        // Anonymous counts: an action on the demo is not counted.
        let url = base.appendingPathComponent("improvement.json")
        let store = ImprovementStats.Store(url: url)
        ImprovementStats.add(.speakersNamed, count: 1, onDemo: true, mode: .on, to: store, now: now)
        #expect(store.days().isEmpty)
        ImprovementStats.add(.speakersNamed, count: 1, onDemo: false, mode: .on, to: store, now: now)
        #expect(store.days()[ImprovementStats.day(now)]?["speakers.named"] == 1)

        // Home analytics.
        func meetings(_ list: [StoredSession]) -> Int {
            MeetingAnalytics.snapshot(sessions: list, personalFolderSlugs: [], workFolderSlugs: [],
                                      workday: nil, summaryRange: .year, now: now).totalMeetings
        }
        #expect(meetings([demo]) == 0)
        #expect(meetings([demo, real]) == 1)

        // iPhone sync: the demo stays on the Mac.
        let engine = SessionSyncEngine(base: SessionsBase(base: base),
                                       stateURL: base.appendingPathComponent("sync-state.json"),
                                       transport: InMemorySyncTransport())
        #expect(try engine.snapshot(of: demo.id) == nil)
        #expect(try engine.snapshot(of: real.id) != nil)
    }
}
