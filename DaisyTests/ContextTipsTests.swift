//
//  ContextTipsTests.swift
//  DaisyTests
//
//  Onboarding 2.0, package E (Egor 23–24.10): the calendar and summary
//  tips come once, only under their condition, never under the test host
//  and never over a busy Daisy; the project offer names only a plausible
//  project, once, and «Создать» creates it and moves the note.
//

import Foundation
import Testing
@testable import Daisy

@MainActor
struct ContextTipsTests {
    /// A throwaway defaults domain — never the real prefs.
    private func withDefaults(_ body: (UserDefaults) async -> Void) async {
        let name = "contexttips-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        await body(defaults)
    }

    @MainActor final class Harness {
        var busy = false
        var capturing = false
        var widgetUp = true
        var calendarSettled = false
        var meetingRecorded: Bool? = false
        var summaryReady: Bool? = false
        var hasWidget = true
        var now = Date()
        var shown: [WidgetBubbleContent] = []
        var tips: ContextTips!
    }

    private func harness(_ defaults: UserDefaults, suppressed: Bool = false) -> Harness {
        let h = Harness()
        h.tips = ContextTips(
            defaults: defaults,
            isSuppressed: suppressed,
            isBusy: { [unowned h] in h.busy },
            isCapturing: { [unowned h] in h.capturing },
            showAsk: { [unowned h] content in
                guard h.widgetUp else { return false }
                h.shown.append(content)
                return true
            },
            calendarSettled: { [unowned h] in h.calendarSettled },
            meetingRecorded: { [unowned h] in h.meetingRecorded },
            summaryReady: { [unowned h] in h.summaryReady },
            hasWidget: { [unowned h] in h.hasWidget },
            now: { [unowned h] in h.now },
            // Far enough out that no retry fires inside a test.
            retryDelay: .seconds(3600)
        )
        return h
    }

    private let yesterday = Date().addingTimeInterval(-86_400)

    // MARK: - Calendar

    @Test func calendarTipFiresOnceAfterTheTour() async { await withDefaults { defaults in
        let h = harness(defaults)
        // No tour behind this install (an update): not asked.
        h.tips.meetingAppLaunched()
        #expect(h.shown.isEmpty)

        ContextTips.tourFinished(path: .full, at: Date(), defaults: defaults)
        h.tips.meetingAppLaunched()
        #expect(h.shown.count == 1)
        #expect(h.shown.first?.text == ContextTips.Copy.calendarAsk)
        #expect(h.shown.first?.tag == ContextTips.bubbleTag)
        #expect(h.shown.first?.action != nil)
        #expect(h.tips.hasShown(.calendar))

        // Again, and from a fresh instance on the same prefs: still once.
        h.tips.meetingAppLaunched()
        let later = harness(defaults)
        later.tips.meetingAppLaunched()
        later.tips.dayStarted()
        #expect(h.shown.count == 1)
        #expect(later.shown.isEmpty)
    } }

    @Test func calendarTipWaitsForTheDayAfterTheTour() async { await withDefaults { defaults in
        let h = harness(defaults)
        ContextTips.tourFinished(path: .full, at: Date(), defaults: defaults)
        h.tips.dayStarted()
        #expect(h.shown.isEmpty)

        ContextTips.tourFinished(path: .full, at: yesterday, defaults: defaults)
        h.tips.dayStarted()
        #expect(h.shown.count == 1)
    } }

    @Test func calendarTipNotWhenACalendarIsConnected() async { await withDefaults { defaults in
        let h = harness(defaults)
        ContextTips.tourFinished(path: .full, at: yesterday, defaults: defaults)
        h.calendarSettled = true
        h.tips.dayStarted()
        h.tips.meetingAppLaunched()
        #expect(h.shown.isEmpty)
        #expect(!h.tips.hasShown(.calendar))
        #expect(h.tips.pending.isEmpty)
    } }

    @Test func calendarTipNotOnTheDictationPathUntilAMeeting() async { await withDefaults { defaults in
        let h = harness(defaults)
        ContextTips.tourFinished(path: .dictationOnly, at: yesterday, defaults: defaults)
        #expect(h.tips.meetingsNotYet)
        h.tips.dayStarted()
        h.tips.meetingAppLaunched()
        #expect(h.shown.isEmpty)

        h.meetingRecorded = true
        #expect(!h.tips.meetingsNotYet)
        h.tips.meetingAppLaunched()
        #expect(h.shown.count == 1)
    } }

    @Test func calendarTipWaitsWhileBusyAndDropsWhenMoot() async { await withDefaults { defaults in
        let h = harness(defaults)
        ContextTips.tourFinished(path: .full, at: yesterday, defaults: defaults)
        h.busy = true
        h.tips.meetingAppLaunched()
        #expect(h.shown.isEmpty)
        #expect(h.tips.pending == [.calendar])

        h.busy = false
        h.tips.showPendingIfCalm()
        #expect(h.shown.count == 1)
        #expect(h.tips.pending.isEmpty)
        #expect(h.tips.hasShown(.calendar))

        // Waiting, then connected in the meantime: dropped, not shown.
        let other = "contexttips-\(UUID().uuidString)"
        let otherDefaults = UserDefaults(suiteName: other)!
        defer { otherDefaults.removePersistentDomain(forName: other) }
        let g = harness(otherDefaults)
        ContextTips.tourFinished(path: .full, at: yesterday, defaults: otherDefaults)
        g.widgetUp = false
        g.tips.meetingAppLaunched()
        #expect(g.tips.pending == [.calendar])
        g.widgetUp = true
        g.calendarSettled = true
        g.tips.showPendingIfCalm()
        #expect(g.shown.isEmpty)
        #expect(g.tips.pending.isEmpty)
        #expect(!g.tips.hasShown(.calendar))
    } }

    // MARK: - Summary provider

    @Test func summaryTipFiresOnceWhenNoProviderCanWrite() async { await withDefaults { defaults in
        let h = harness(defaults)
        h.summaryReady = true
        h.tips.summaryProviderMissing()
        #expect(h.shown.isEmpty)

        h.summaryReady = false
        h.tips.summaryProviderMissing()
        #expect(h.shown.count == 1)
        #expect(h.shown.first?.text == ContextTips.Copy.summaryAsk)
        #expect(h.shown.first?.actionTitle == ContextTips.Copy.summaryAction)
        #expect(h.tips.hasShown(.summaryProvider))

        h.tips.summaryProviderMissing()
        harness(defaults).tips.summaryProviderMissing()
        #expect(h.shown.count == 1)
    } }

    @Test func unknownConditionsKeepATipWaiting() async { await withDefaults { defaults in
        // Right after launch: the provider isn't checked yet.
        let h = harness(defaults)
        h.summaryReady = nil
        h.tips.summaryProviderMissing()
        #expect(h.shown.isEmpty)
        #expect(h.tips.pending == [.summaryProvider])
        h.tips.showPendingIfCalm()
        #expect(h.tips.pending == [.summaryProvider])
        h.summaryReady = false
        h.tips.showPendingIfCalm()
        #expect(h.shown.count == 1)

        // The Library not loaded yet on the dictation path: neither shown
        // nor dropped; loaded with a meeting in it, it shows.
        ContextTips.tourFinished(path: .dictationOnly, at: yesterday, defaults: defaults)
        h.meetingRecorded = nil
        h.tips.dayStarted()
        #expect(h.shown.count == 1)
        #expect(h.tips.pending == [.calendar])
        h.meetingRecorded = true
        h.tips.showPendingIfCalm()
        #expect(h.shown.count == 2)
        #expect(h.tips.hasShown(.calendar))
    } }

    @Test func summaryTipWaitsWhileBusy() async { await withDefaults { defaults in
        let h = harness(defaults)
        h.busy = true
        h.tips.summaryProviderMissing()
        #expect(h.shown.isEmpty)
        #expect(h.tips.pending == [.summaryProvider])
        // A quit in between: the next launch shows it.
        let next = harness(defaults)
        next.tips.showPendingIfCalm()
        #expect(next.shown.count == 1)
        #expect(next.tips.pending.isEmpty)
    } }

    @Test func nothingUnderTheTestHost() async { await withDefaults { defaults in
        let h = harness(defaults, suppressed: true)
        ContextTips.tourFinished(path: .full, at: yesterday, defaults: defaults)
        h.tips.start()
        h.tips.meetingAppLaunched()
        h.tips.dayStarted()
        h.tips.summaryProviderMissing()
        let route = DaisyKeyFolderRoute.Result(folderSlug: nil, unmatched: true, body: "в проект Альфа, купить молоко")
        #expect(h.tips.projectOffer(for: route.body, route: route) == nil)
        #expect(h.shown.isEmpty)
        #expect(h.tips.pending.isEmpty)
        for tip in ContextTips.Tip.allCases { #expect(!h.tips.hasShown(tip)) }
    } }

    // MARK: - Project

    @Test func projectNameOnlyWhenPlausible() {
        #expect(ContextTips.proposedProjectName(in: "в проект Альфа, купить молоко") == "Альфа")
        #expect(ContextTips.proposedProjectName(in: "в проект альфа. Купить молоко") == "Альфа")
        #expect(ContextTips.proposedProjectName(in: "в проект «Новый сайт»: созвон в пятницу") == "Новый сайт")
        #expect(ContextTips.proposedProjectName(in: "to the project Blue Moon Labs — call Anna") == "Blue Moon Labs")
        #expect(ContextTips.proposedProjectName(in: "в проект Лендинг") == "Лендинг")
        #expect(ContextTips.proposedProjectName(in: "в проект Альфа - купить молоко") == "Альфа")
        #expect(ContextTips.proposedProjectName(in: "в проект «Новый сайт»") == "Новый сайт")
        #expect(ContextTips.proposedProjectName(in: "в проект iOS, выложить сборку") == "iOS")
        #expect(ContextTips.proposedProjectName(in: "в проект Альфа — купить") == "Альфа")
        // No boundary: the name could be any of the words.
        #expect(ContextTips.proposedProjectName(in: "в проект Альфа купить молоко завтра") == nil)
        #expect(ContextTips.proposedProjectName(in: "в проект Альфа купить молоко") == nil)
        #expect(ContextTips.proposedProjectName(in: "в проект Новый сайт") == nil)
        // Four words before the comma is a sentence, not a name.
        #expect(ContextTips.proposedProjectName(in: "в проект Большой новый красивый сайт, купить") == nil)
        #expect(ContextTips.proposedProjectName(in: "в проект который мы обсуждали, купить") == nil)
        // Not a folder phrase at all.
        #expect(ContextTips.proposedProjectName(in: "купить молоко") == nil)
    }

    @Test func projectOfferOnceAndOnlyForAMissingProject() async { await withDefaults { defaults in
        let h = harness(defaults)
        let text = "в проект Альфа, купить молоко"
        let matched = DaisyKeyFolderRoute.Result(folderSlug: "alpha", body: "купить молоко")
        let ambiguous = DaisyKeyFolderRoute.Result(folderSlug: nil, ambiguous: true, body: text)
        let missing = DaisyKeyFolderRoute.Result(folderSlug: nil, unmatched: true, body: text)
        #expect(h.tips.projectOffer(for: text, route: matched) == nil)
        #expect(h.tips.projectOffer(for: text, route: ambiguous) == nil)
        h.capturing = true
        #expect(h.tips.projectOffer(for: text, route: missing) == nil)
        #expect(!h.tips.hasShown(.project))
        h.capturing = false
        // No widget panel: the offer would land on a banner without a button.
        h.hasWidget = false
        #expect(h.tips.projectOffer(for: text, route: missing) == nil)
        h.hasWidget = true
        #expect(h.tips.projectOffer(for: "в проект Альфа купить молоко", route: missing) == nil)
        #expect(!h.tips.hasShown(.project))

        #expect(h.tips.projectOffer(for: text, route: missing) == "Альфа")
        #expect(h.tips.hasShown(.project))
        #expect(h.tips.projectOffer(for: text, route: missing) == nil)
        #expect(harness(defaults).tips.projectOffer(for: text, route: missing) == nil)
        // Rides on the note's message — never a pill of its own.
        #expect(h.shown.isEmpty)
        #expect(ContextTips.content(for: .project) == nil)
    } }

    @Test func createProjectCreatesAndMoves() async {
        var created: [String] = []
        var moved: [(String, String)] = []
        let folder = await ContextTips.createProject(
            named: "Альфа",
            moving: "2026-10-24_note",
            addFolder: { name in created.append(name); return SessionFolder(name: name) },
            move: { id, folder in moved.append((id, folder.slug)); return true }
        )
        #expect(created == ["Альфа"])
        #expect(folder?.name == "Альфа")
        #expect(moved.count == 1)
        #expect(moved.first?.0 == "2026-10-24_note")
        #expect(moved.first?.1 == folder?.slug)

        // The move didn't happen: no folder reported, so the message says so.
        let failed = await ContextTips.createProject(
            named: "Бета", moving: "x",
            addFolder: { SessionFolder(name: $0) },
            move: { _, _ in false }
        )
        #expect(failed == nil)
    }

    // MARK: - Copy

    @Test func everyLineHasBothLanguages() throws {
        let missing = "\u{0}missing"
        let ru = try #require(Bundle.main.path(forResource: "ru", ofType: "lproj").flatMap(Bundle.init(path:)))
        let en = try #require(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        for key in ["tip.calendar.ask", "tip.calendar.action", "tip.summary.ask", "tip.summary.action",
                    "tip.project.ask", "tip.project.create", "tip.project.created", "tip.project.notMoved",
                    "tip.home.summary.caption", "tip.whatsNew.tour"] {
            #expect(ru.localizedString(forKey: key, value: missing, table: nil) != missing, "ru \(key)")
            #expect(en.localizedString(forKey: key, value: missing, table: nil) != missing, "en \(key)")
        }
        #expect(ContextTips.Copy.projectAsk(name: "Alpha", savedTo: "Inbox").contains("Alpha"))
        #expect(ContextTips.Copy.projectAsk(name: "Alpha", savedTo: "Inbox").contains("Inbox"))
    }
}
