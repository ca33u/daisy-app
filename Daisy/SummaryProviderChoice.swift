//
//  SummaryProviderChoice.swift
//  Daisy
//
//  The summary provider as kept between launches: the one selected, the
//  person's own one (what the second block of Settings → AI shows, and what
//  summaries go back to when the Daisy Subscription is switched off), and
//  the one kept for the interactive route while the local model is chosen.
//
//  Apart from `Summarizer`, which reads the person's own defaults: a launch,
//  a switch and the next launch are tested here on defaults of a test's own.
//

import Foundation

nonisolated struct SummaryProviderChoice: Equatable, Sendable {
    /// The provider that writes summaries.
    var selected: SummaryProviderKind
    /// One's own provider (a key, an account, a local model). Never the
    /// Daisy Subscription.
    var own: SummaryProviderKind
    /// What the interactive route uses while the local model is selected.
    /// Never the local model, never the Daisy Subscription.
    var interactiveFallback: SummaryProviderKind?

    /// The choice once `new` is selected. An own provider becomes the own
    /// one; the subscription leaves the own one as it was, to come back to.
    func selecting(_ new: SummaryProviderKind) -> SummaryProviderChoice {
        guard new != selected else { return self }
        var next = self
        next.selected = new
        if new != .daisySubscription { next.own = new }
        if Summarizer.keepsAsInteractiveFallback(old: selected, new: new) { next.interactiveFallback = selected }
        return next
    }

    /// The switch of the subscription's block: on — the subscription
    /// writes; off — the own provider does again.
    func usingDaisySubscription(_ on: Bool) -> SummaryProviderChoice {
        selecting(on ? .daisySubscription : own)
    }
}

nonisolated struct SummaryProviderChoiceStore: @unchecked Sendable {
    static let selectedKey = "daisy.summaryProvider"
    static let ownKey = "daisy.summaryProvider.own"
    static let interactiveKey = "daisy.summaryProvider.interactive"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The choice at launch. The own provider is written back whenever it
    /// isn't the one kept: it has to be in the defaults before the
    /// subscription is selected, because from then on the selection no
    /// longer says what it was. (Review 27.11: kept only in memory, it was
    /// gone after «switch on, quit» for everyone coming from a build that
    /// didn't keep it, and the second block named the default provider.)
    func load(default fallback: SummaryProviderKind) -> SummaryProviderChoice {
        let selected = kind(Self.selectedKey) ?? fallback
        let kept = kind(Self.ownKey)
        let own = Summarizer.ownProvider(stored: kept, selected: selected, default: fallback)
        if own != kept { defaults.set(own.rawValue, forKey: Self.ownKey) }
        let interactive = kind(Self.interactiveKey)
        return SummaryProviderChoice(
            selected: selected, own: own,
            interactiveFallback: interactive == .daisyLocal || interactive == .daisySubscription ? nil : interactive)
    }

    func save(_ choice: SummaryProviderChoice) {
        defaults.set(choice.selected.rawValue, forKey: Self.selectedKey)
        defaults.set(choice.own.rawValue, forKey: Self.ownKey)
        defaults.set(choice.interactiveFallback?.rawValue, forKey: Self.interactiveKey)
    }

    private func kind(_ key: String) -> SummaryProviderKind? {
        defaults.string(forKey: key).flatMap(SummaryProviderKind.init(rawValue:))
    }
}
