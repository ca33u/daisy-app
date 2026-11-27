//
//  SummaryProviderBlocksTests.swift
//  DaisyTests
//
//  Settings → AI in two blocks (Egor 27.11): the Daisy Subscription with
//  its switch, and one's own provider. The rules behind the switch, held
//  as pure functions and as `SummaryProviderChoice` because `Summarizer`
//  reads the person's defaults.
//

import Foundation
import Testing
@testable import Daisy

@Suite("Settings → AI: the subscription's block and the own provider's")
struct SummaryProviderBlocksTests {
    @Test("the own provider is the one selected; the kept one only while the subscription writes")
    func ownProviderAtLaunch() {
        #expect(Summarizer.ownProvider(stored: .openai, selected: .daisySubscription, default: .anthropic) == .openai)
        // A kept value gone stale (the selection written by another build, or by hand) doesn't win.
        #expect(Summarizer.ownProvider(stored: .openai, selected: .ollama, default: .anthropic) == .ollama)
        #expect(Summarizer.ownProvider(stored: .openai, selected: .daisyLocal, default: .anthropic) == .daisyLocal)
        #expect(Summarizer.ownProvider(stored: nil, selected: .ollama, default: .anthropic) == .ollama)
    }

    @Test("the subscription is never the own provider: a subscriber from 1.0.8.58 gets the default")
    func subscriptionIsNeverTheOwnProvider() {
        #expect(Summarizer.ownProvider(stored: nil, selected: .daisySubscription, default: .anthropic) == .anthropic)
        #expect(Summarizer.ownProvider(stored: .daisySubscription, selected: .daisySubscription, default: .appleIntelligence) == .appleIntelligence)
        #expect(Summarizer.ownProvider(stored: .daisySubscription, selected: .openai, default: .anthropic) == .openai)
    }

    @Test("the picker offers one's own providers, never the subscription")
    func pickerOffersOwnProviders() {
        for selected in SummaryProviderKind.allCases {
            for appleIntelligence in [true, false] {
                let offered = Summarizer.offeredProviders(selected: selected, appleIntelligence: appleIntelligence)
                #expect(!offered.contains(.daisySubscription))
                #expect(offered.contains(.appleIntelligence) == appleIntelligence)
                #expect(offered.contains(.daisyLocal) == (selected == .daisyLocal))
                #expect(offered.contains(.anthropic) && offered.contains(.openai))
            }
        }
    }

    @Test("switching the subscription off onto the local model doesn't leave Daisy key commands on Daisy's server")
    func subscriptionIsNeverTheInteractiveFallback() {
        #expect(!Summarizer.keepsAsInteractiveFallback(old: .daisySubscription, new: .daisyLocal))
        #expect(Summarizer.keepsAsInteractiveFallback(old: .openai, new: .daisyLocal))
        #expect(!Summarizer.keepsAsInteractiveFallback(old: .daisyLocal, new: .daisyLocal))
        #expect(!Summarizer.keepsAsInteractiveFallback(old: .openai, new: .anthropic))
    }

    @Test("links about the provider land on the block that writes")
    @MainActor
    func linksLandOnTheBlockInUse() {
        #expect(SettingsRow.summaryProvider(for: .daisySubscription) == .daisySubscription)
        for kind in SummaryProviderKind.allCases where kind != .daisySubscription {
            #expect(SettingsRow.summaryProvider(for: kind) == .summaryProvider)
        }
        #expect(SettingsRow.daisySubscription.path == "Settings → AI → Daisy Subscription")
        #expect(EndOfDaySummaries.failureText(meetingsFailed: true, row: .daisySubscription).hasSuffix("check Settings → AI → Daisy Subscription."))
    }

    // MARK: Across launches (`SummaryProviderChoiceStore`, on defaults of the test's own)

    private let scratch = ScratchDefaults("SummaryProviderBlocks")

    @Test("coming from a build that didn't keep the own provider: switch on, quit, and it is still there")
    func ownProviderOutlivesARelaunch() {
        let defaults = scratch.make()
        defaults.set(SummaryProviderKind.openai.rawValue, forKey: SummaryProviderChoiceStore.selectedKey)
        let store = SummaryProviderChoiceStore(defaults: defaults)

        // First launch of this build: nothing kept yet.
        let launched = store.load(default: .anthropic)
        #expect(launched == SummaryProviderChoice(selected: .openai, own: .openai, interactiveFallback: nil))
        // The switch on (by hand, or by a payment).
        let onSubscription = launched.usingDaisySubscription(true)
        store.save(onSubscription)
        #expect(onSubscription.selected == .daisySubscription && onSubscription.own == .openai)

        // The next launch.
        let relaunched = SummaryProviderChoiceStore(defaults: defaults).load(default: .anthropic)
        #expect(relaunched == onSubscription)
        // The switch off: back on the provider from before.
        #expect(relaunched.usingDaisySubscription(false).selected == .openai)
    }

    @Test("the own provider is in the defaults from the first launch, before any switch")
    func ownProviderIsWrittenAtLaunch() {
        let defaults = scratch.make()
        defaults.set(SummaryProviderKind.ollama.rawValue, forKey: SummaryProviderChoiceStore.selectedKey)
        _ = SummaryProviderChoiceStore(defaults: defaults).load(default: .anthropic)
        #expect(defaults.string(forKey: SummaryProviderChoiceStore.ownKey) == SummaryProviderKind.ollama.rawValue)

        // Nothing chosen at all: the default, and it is kept too.
        let empty = scratch.make()
        #expect(SummaryProviderChoiceStore(defaults: empty).load(default: .anthropic).own == .anthropic)
        #expect(empty.string(forKey: SummaryProviderChoiceStore.ownKey) == SummaryProviderKind.anthropic.rawValue)
        // The selection itself isn't written by a launch: the default can change with the system.
        #expect(empty.string(forKey: SummaryProviderChoiceStore.selectedKey) == nil)
    }

    @Test("a kept own provider gone stale is put right on disk, not only in memory")
    func staleOwnProviderIsRewritten() {
        let defaults = scratch.make()
        // The selection changed by another build after the own one was kept.
        defaults.set(SummaryProviderKind.gemini.rawValue, forKey: SummaryProviderChoiceStore.selectedKey)
        defaults.set(SummaryProviderKind.openai.rawValue, forKey: SummaryProviderChoiceStore.ownKey)
        let store = SummaryProviderChoiceStore(defaults: defaults)
        let launched = store.load(default: .anthropic)
        #expect(launched.own == .gemini)
        #expect(defaults.string(forKey: SummaryProviderChoiceStore.ownKey) == SummaryProviderKind.gemini.rawValue)

        store.save(launched.usingDaisySubscription(true))
        let relaunched = SummaryProviderChoiceStore(defaults: defaults).load(default: .anthropic)
        #expect(relaunched.own == .gemini)
        #expect(relaunched.usingDaisySubscription(false).selected == .gemini)
    }

    @Test("a round trip of the switch changes nothing else; choosing a provider while off moves the own one")
    func switchRoundTrip() {
        let start = SummaryProviderChoice(selected: .daisyLocal, own: .daisyLocal, interactiveFallback: .anthropic)
        let on = start.usingDaisySubscription(true)
        #expect(on == SummaryProviderChoice(selected: .daisySubscription, own: .daisyLocal, interactiveFallback: .anthropic))
        // Back onto the local model: the subscription isn't kept for Daisy key commands.
        #expect(on.usingDaisySubscription(false) == start)
        // On twice, off twice: the same.
        #expect(on.usingDaisySubscription(true) == on)
        #expect(start.usingDaisySubscription(false) == start)

        let moved = start.selecting(.openai)
        #expect(moved == SummaryProviderChoice(selected: .openai, own: .openai, interactiveFallback: .anthropic))
        // The local model after a cloud provider keeps that provider for the interactive route.
        #expect(moved.selecting(.daisyLocal).interactiveFallback == .openai)
    }

    @Test("a kept interactive provider that can't be one is dropped at launch")
    func interactiveFallbackAtLaunch() {
        for (kept, expected) in [(SummaryProviderKind.daisySubscription, SummaryProviderKind?.none), (.daisyLocal, nil), (.openai, .openai)] {
            let defaults = scratch.make()
            defaults.set(SummaryProviderKind.daisyLocal.rawValue, forKey: SummaryProviderChoiceStore.selectedKey)
            defaults.set(kept.rawValue, forKey: SummaryProviderChoiceStore.interactiveKey)
            #expect(SummaryProviderChoiceStore(defaults: defaults).load(default: .anthropic).interactiveFallback == expected)
        }
    }
}
