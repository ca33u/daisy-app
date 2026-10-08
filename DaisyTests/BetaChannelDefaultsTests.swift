import Foundation
import Sparkle
import Testing
@testable import Daisy

@Suite("A downloaded beta keeps receiving beta updates")
struct BetaChannelDefaultsTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "DaisyTests.beta.\(UUID().uuidString)")!
    }
    private let beta = BetaChannelDefaults.Item(build: "142", channel: "beta")

    @Test func untouchedBetaAndEarlierBetaInstallsOptIn() {
        let store = defaults()
        #expect(store.object(forKey: BetaChannelDefaults.key) == nil)
        #expect(BetaChannelDefaults.adoptInstalledBeta(build: "142", items: [beta, .init(build: "143", channel: "beta")], defaults: store))
        #expect(store.object(forKey: BetaChannelDefaults.key) as? Bool == true)
        #expect(BetaChannelDefaults.allowedChannels(defaults: store) == ["beta"])
        #expect(!BetaChannelDefaults.adoptInstalledBeta(build: "142", items: [beta], defaults: store))
    }

    @Test func stableMissingAndUnknownBuildsLeaveTheKeyAbsent() {
        for items in [[BetaChannelDefaults.Item(build: "142", channel: nil)], [], [beta], [.init(build: "142", channel: "preview")]] {
            let store = defaults()
            let build = items.first?.channel == "beta" ? "141" : "142"
            #expect(!BetaChannelDefaults.adoptInstalledBeta(build: build, items: items, defaults: store))
            #expect(store.object(forKey: BetaChannelDefaults.key) == nil)
        }
    }

    @Test func explicitChoiceSurvivesAReopenedDefaultsStore() {
        for choice in [false, true] {
            let suite = "DaisyTests.beta.\(UUID().uuidString)"
            let first = UserDefaults(suiteName: suite)!
            BetaChannelDefaults.setChoice(choice, defaults: first)
            let reopened = UserDefaults(suiteName: suite)!
            #expect(!BetaChannelDefaults.adoptInstalledBeta(build: "142", items: [beta], defaults: reopened))
            #expect(reopened.object(forKey: BetaChannelDefaults.key) as? Bool == choice)
            first.removePersistentDomain(forName: suite)
        }
    }

    @Test func promotedDuplicateWinsRegardlessOfFeedOrder() {
        let stable = BetaChannelDefaults.Item(build: "142", channel: nil)
        for items in [[beta, stable], [stable, beta]] {
            let store = defaults()
            #expect(!BetaChannelDefaults.adoptInstalledBeta(build: "142", items: items, defaults: store))
            #expect(store.object(forKey: BetaChannelDefaults.key) == nil)
        }
    }

    @Test func anotherPlatformAndMissingBundleVersionAreNotEvidence() {
        let store = defaults()
        #expect(!BetaChannelDefaults.adoptInstalledBeta(build: "142", items: [.init(build: "142", channel: "beta", isMacOS: false)], defaults: store))
        #expect(!BetaChannelDefaults.adoptInstalledBeta(build: nil, items: [beta], defaults: store))
        #expect(store.object(forKey: BetaChannelDefaults.key) == nil)
    }

    @Test func offlineDoesNotInferAChannel() {
        // Only the successful appcast callback invokes adoption. With no
        // response, the same untouched defaults continue to select stable.
        let store = defaults()
        #expect(BetaChannelDefaults.allowedChannels(defaults: store).isEmpty)
        #expect(store.object(forKey: BetaChannelDefaults.key) == nil)
    }
}
