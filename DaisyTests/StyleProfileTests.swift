//
//  StyleProfileTests.swift
//  DaisyTests
//
//  Onboarding 2.0, package D (Egor 23.10): what the tour dictates counts
//  toward the style profile like any dictation, the tour's counter reads
//  the per-language progress, and the «profile is ready» ask comes once,
//  only past the line, and never over a busy Daisy.
//

import Foundation
import Testing
@testable import Daisy

@MainActor
struct StyleProfileTests {
    /// A store on a throwaway folder and defaults domain — never the real
    /// corpus or the real prefs. Both removed when the test is done.
    private func withStore(_ body: (VoiceProfileStore, UserDefaults, URL) -> Void) {
        let name = "styleprofile-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: dir)
        }
        body(VoiceProfileStore(storeDirectory: dir, defaults: defaults), defaults, dir)
    }

    private func words(_ n: Int, _ word: String) -> String {
        Array(repeating: word, count: n).joined(separator: " ")
    }

    // MARK: - Tour samples

    @Test func tourSamplesCountPerLanguage() { withStore { store, _, _ in
        store.appendTourSample(words(150, "слово"), locale: "ru-RU")
        store.appendTourSample(words(120, "word"), locale: "en")
        #expect(store.progress(locale: "ru").words == 150)
        #expect(store.progress(locale: "ru-RU").words == 150)
        #expect(store.progress(locale: "en-US").words == 120)
        #expect(store.progress(locale: "de").words == 0)
        #expect(store.progress(locale: "ru").threshold == VoiceProfileStore.unlockWords)
        #expect(!store.canGenerate(for: "ru"))

        // Tour words and ordinary dictations fill the same bucket.
        store.appendDictation(words(150, "текст"), language: "ru")
        #expect(store.progress(locale: "ru").words == 300)
        #expect(store.canGenerate(for: "ru"))
        #expect(!store.canGenerate(for: "en"))

        #expect(store.tourSamples.map(\.language) == ["ru", "en"])
        #expect(store.tourSamples.map(\.words) == [150, 120])
    } }

    @Test func autoLocaleReportsTheNearestLanguage() { withStore { store, _, _ in
        #expect(store.progress(locale: "auto").words == 0)
        store.appendTourSample(words(80, "word"), locale: "en")
        store.appendTourSample(words(200, "слово"), locale: "ru")
        #expect(store.progress(locale: "auto").words == 200)
    } }

    @Test func tourTextAlreadyPastedIsTaggedNotCountedTwice() { withStore { store, _, _ in
        let text = words(60, "слово")
        // The practice field takes dictation like any field, so the paste
        // path has already fed it in…
        store.appendDictation(text, language: "ru")
        // …and the tour then hands the same text over.
        store.appendTourSample(text, locale: "ru")
        #expect(store.progress(locale: "ru").words == 60)
        #expect(store.tourSamples.count == 1)
        // Different text is a new sample.
        store.appendTourSample(words(10, "ещё"), locale: "ru")
        #expect(store.progress(locale: "ru").words == 70)
        #expect(store.tourSamples.count == 2)
    } }

    @Test func twoPastesIntoOneFieldAreTaggedNotCountedTwice() { withStore { store, _, _ in
        store.appendDictation(words(20, "первое"), language: "ru")
        store.appendDictation(words(30, "второе"), language: "ru")
        // The field joined the two pastes with a line break.
        store.appendTourSample(words(20, "первое") + "\n" + words(30, "второе"), locale: "ru")
        #expect(store.progress(locale: "ru").words == 50)
        #expect(store.tourSamples.map(\.words) == [50])
    } }

    @Test func tourSamplesSurviveARelaunch() { withStore { store, defaults, dir in
        store.appendTourSample(words(40, "word"), locale: "en")
        store.flushPendingWrites()
        let again = VoiceProfileStore(storeDirectory: dir, defaults: defaults)
        #expect(again.progress(locale: "en").words == 40)
        #expect(again.tourSamples.count == 1)
        #expect(again.tourSamples.first?.language == "en")
    } }

    // MARK: - Crossing the line

    @Test func crossingIsReportedOnceAndOnlyWithoutAProfile() { withStore { store, _, _ in
        var reports: [[String]] = []
        store.thresholdObserver = { reports.append($0) }
        store.appendDictation(words(299, "слово"), language: "ru")
        store.appendTourSample(words(2, "ещё"), locale: "ru")
        store.appendDictation(words(50, "слово"), language: "ru")
        #expect(reports == [[], ["ru"], []])

        // A language that already has a profile is not offered one.
        store.setCustomInstruction("Short and direct.", language: "en")
        store.appendDictation(words(300, "word"), language: "en")
        #expect(reports.last == [])

        // Nor is anyone with a universal profile: it covers every language.
        store.setCustomInstruction("Коротко и по делу.")
        store.appendDictation(words(300, "palabra"), language: "es")
        #expect(reports.last == [])
    } }

    // MARK: - The tip

    /// A tip wired to `store` the way the shared one is, with a pill
    /// recorder and a switchable "busy" in place of the widget.
    private final class Harness {
        var busy = false
        var local = true
        var widgetUp = true
        var shown: [WidgetBubbleContent] = []
        var tip: StyleProfileTip!
    }

    private func harness(
        _ store: VoiceProfileStore,
        _ defaults: UserDefaults,
        suppressed: Bool = false
    ) -> Harness {
        let h = Harness()
        h.tip = StyleProfileTip(
            defaults: defaults,
            isSuppressed: suppressed,
            isBusy: { [unowned h] in h.busy },
            providerIsLocal: { [unowned h] in h.local },
            showAsk: { [unowned h] content in
                guard h.widgetUp else { return false }
                h.shown.append(content)
                return true
            },
            presentResult: { [unowned h] in h.shown.append($0) },
            // Far enough out that no retry fires inside a test.
            retryDelay: .seconds(3600)
        )
        store.thresholdObserver = { [unowned h, unowned store] in
            h.tip.corpusGrew(crossed: $0, in: store)
        }
        return h
    }

    @Test func tipFiresOnceAndOnlyPastTheLine() { withStore { store, defaults, _ in
        let h = harness(store, defaults)
        store.appendTourSample(words(200, "слово"), locale: "ru")
        #expect(h.shown.isEmpty)

        store.appendDictation(words(120, "слово"), language: "ru")
        #expect(h.shown.count == 1)
        #expect(h.shown.first?.tag == StyleProfileTip.bubbleTag)
        #expect(h.shown.first?.actionTitle == String(localized: "Build"))
        #expect(h.shown.first?.action != nil)
        #expect(h.tip.hasShown("ru"))

        // More words, and a fresh tip on the same prefs: still once.
        store.appendDictation(words(400, "слово"), language: "ru")
        let later = harness(store, defaults)
        store.appendDictation(words(10, "слово"), language: "ru")
        #expect(h.shown.count == 1)
        #expect(later.shown.isEmpty)

        // Another language gets its own one ask.
        store.appendDictation(words(310, "word"), language: "en")
        #expect(later.shown.count == 1)
        #expect(later.tip.hasShown("en"))
    } }

    @Test func tipWaitsWhileDaisyIsBusy() { withStore { store, defaults, _ in
        let h = harness(store, defaults)
        h.busy = true
        store.appendDictation(words(310, "слово"), language: "ru")
        #expect(h.shown.isEmpty)
        #expect(h.tip.pendingLanguages == ["ru"])
        #expect(!h.tip.hasShown("ru"))

        h.busy = false
        h.tip.showPendingIfCalm()
        #expect(h.shown.count == 1)
        #expect(h.tip.pendingLanguages.isEmpty)
        #expect(h.tip.hasShown("ru"))
    } }

    @Test func pendingTipDropsOnceAProfileExists() { withStore { store, defaults, _ in
        let h = harness(store, defaults)
        h.busy = true
        store.appendDictation(words(310, "слово"), language: "ru")
        #expect(h.tip.pendingLanguages == ["ru"])
        // Built from My style while the ask was waiting.
        store.setCustomInstruction("Коротко и по делу.", language: "ru")
        h.busy = false
        h.tip.showPendingIfCalm()
        #expect(h.shown.isEmpty)
        #expect(h.tip.pendingLanguages.isEmpty)
    } }

    @Test func onACloudProviderTheAskOpensMyStyleInstead() { withStore { store, defaults, _ in
        // A click anywhere on the pill accepts it; that must not be what
        // sends the corpus to a cloud provider.
        let h = harness(store, defaults)
        h.local = false
        store.appendDictation(words(310, "слово"), language: "ru")
        #expect(h.shown.count == 1)
        #expect(h.shown.first?.actionTitle == String(localized: "Open"))
    } }

    @Test func anAskThatReachedNoScreenStaysPending() { withStore { store, defaults, _ in
        let h = harness(store, defaults)
        h.widgetUp = false
        store.appendDictation(words(310, "слово"), language: "ru")
        #expect(h.shown.isEmpty)
        #expect(!h.tip.hasShown("ru"))
        #expect(h.tip.pendingLanguages == ["ru"])
        h.widgetUp = true
        h.tip.showPendingIfCalm()
        #expect(h.shown.count == 1)
        #expect(h.tip.hasShown("ru"))
    } }

    @Test func suppressedTipNeverShows() { withStore { store, defaults, _ in
        let h = harness(store, defaults, suppressed: true)
        store.appendDictation(words(310, "слово"), language: "ru")
        #expect(h.shown.isEmpty)
        #expect(h.tip.pendingLanguages.isEmpty)
        #expect(!h.tip.hasShown("ru"))
    } }
}
