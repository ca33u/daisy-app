// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  WhatsNew.swift
//  Daisy
//
//  «What's New in Daisy»: a window that opens once after an update. This
//  edition (Egor 28.11) says that the Daisy Subscription exists and can be
//  used instead of one's own API key, as a paywall in the form of the
//  iPhone's (DaisyLite, PaywallView.swift): the brand's field photograph
//  with the headline on it, what the subscription gives, two plans side by
//  side with the year chosen, one button. The first edition (22.10) walked
//  through the Daisy key in three animated scenes; they are gone with it,
//  and the keycaps they drew stay for the tour (OnboardingTourView).
//
//  Buying is never a yes to sending text: someone who hasn't signed in or
//  hasn't answered «Send text through Daisy's server?» is taken to the
//  subscription's block of Settings, with the plan they chose, and decides
//  that there first (`WhatsNewSubscribe`).
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - When it opens

enum WhatsNew {
    /// Bump with each new edition: the window opens once per edition for
    /// anyone who had Daisy before it. A fresh install sees the onboarding
    /// instead and is marked as having seen this one.
    // "daisy-key-2026-10", the first edition: the Daisy key in three scenes.
    // "-b": 1.0.8.37–38 marked the first edition seen as it opened, then
    // crashed drawing it (22.10) — everyone who updated gets it once more.
    // "-c": notes became a hold and the tap the layout fix (Egor 23.10).
    // "-d": the last scene says where the new tour is — someone who
    // updates never sees it otherwise (Onboarding 2.0, Egor 24.10).
    // "-e": and that Settings are eight tabs with search (S4, Egor 24.10).
    // "subscription-2026-11": the Daisy Subscription instead of one's own
    // key, as a paywall with the field photograph (Egor 28.11).
    nonisolated static let edition = "subscription-2026-11"
    nonisolated static let seenKey = "daisy.whatsNew.seenEdition"

    static func shouldOpen(hasShownFirstRun: Bool, defaults: UserDefaults = .standard) -> Bool {
        hasShownFirstRun && defaults.string(forKey: seenKey) != edition
    }

    static func markSeen(defaults: UserDefaults = .standard) {
        defaults.set(edition, forKey: seenKey)
    }

    /// What an update does with an edition not seen yet.
    nonisolated enum Arrival: Equatable {
        /// The window opens.
        case open
        /// It doesn't, and the edition counts as seen: the person has what
        /// it offers. It stays in Help, Settings and About.
        case seen
        /// Not now, and not seen either: asked again at the next launch.
        case later
    }

    /// This edition sells the subscription, so it doesn't open by itself
    /// for someone who has one. `subscriptionActive` is the server's answer
    /// for the signed-in account, nil when there was none: then nothing is
    /// known, and a subscriber must not get the window because the network
    /// was down for a moment — the next launch asks again. Signed out,
    /// this Mac has no subscription to use, whatever the person owns.
    nonisolated static func arrival(signedIn: Bool, subscriptionActive: Bool?) -> Arrival {
        guard signedIn else { return .open }
        switch subscriptionActive {
        case true?: return .seen
        case false?: return .open
        case nil: return .later
        }
    }

    /// The decision for an update, start to finish. Nil: nothing to decide
    /// — a fresh install (the tour marks the edition), or an edition seen
    /// already, by itself or by hand. A subscriber's edition is marked seen
    /// here. `.later` is asked again with the same call when the status
    /// arrives (`WhatsNewPresenter`), in the same launch or the next.
    static func arrive(hasShownFirstRun: Bool, signedIn: Bool, subscriptionActive: Bool?,
                       defaults: UserDefaults = .standard) -> Arrival? {
        guard shouldOpen(hasShownFirstRun: hasShownFirstRun, defaults: defaults) else { return nil }
        let arrival = arrival(signedIn: signedIn, subscriptionActive: subscriptionActive)
        if arrival == .seen { markSeen(defaults: defaults) }
        return arrival
    }

    /// This launch is through with the edition: it asked for the window,
    /// marked it seen, or put it off until the status is known.
    static var settledThisLaunch = false

    /// The window is on its way or on screen, so what else would come up
    /// by itself waits its turn: the Daisy key's one-time bubble
    /// (`DaisyKeyController.introduceIfNeeded`).
    nonisolated static func isAhead(due: Bool, settled: Bool, showing: Bool) -> Bool {
        showing || (due && !settled)
    }

    static func isAhead(hasShownFirstRun: Bool) -> Bool {
        isAhead(due: shouldOpen(hasShownFirstRun: hasShownFirstRun), settled: settledThisLaunch,
                showing: AppNavigation.shared.showsWhatsNew)
    }
}

/// Opens the window after an update, once the process-tap question (a
/// sheet of its own) is out of the way, and whenever the Help menu asks.
struct WhatsNewPresenter: ViewModifier {
    let settings: AppSettings
    let tapPermissionShowing: Bool
    @Bindable private var nav = AppNavigation.shared
    /// `nav.showsWhatsNew`, once the window has no other sheet: asked for
    /// over Settings (whose sheet closes for it), it comes up after.
    @State private var presented = false
    @State private var waiting: Task<Void, Never>?
    /// The account's status wasn't known when the update was looked at
    /// (`WhatsNew.Arrival.later`): decided again when it arrives.
    @State private var awaitsStatus = false
    private var account: DaisyAccountStore { .shared }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { presented },
                set: { shown in
                    presented = shown
                    if !shown { nav.showsWhatsNew = false }
                }
            )) {
                WhatsNewSheet(maxHeight: WhatsNewSheet.heightLimit(under: AppNavigation.mainWindow))
                    // Here, not in the sheet: drawn in a test, the sheet
                    // must not write the person's own preferences.
                    .onAppear { WhatsNew.markSeen() }
            }
            .onChange(of: nav.showsWhatsNew, initial: true) { _, wanted in
                waiting?.cancel()
                guard wanted else {
                    presented = false
                    return
                }
                waiting = Task { @MainActor in
                    guard await SheetQueue.waitUntilClear(), nav.showsWhatsNew else { return }
                    presented = true
                }
            }
            .task(id: settings.hasShownFirstRun) {
                // The process-tap question goes first: when it will be asked,
                // this opens once its sheet closes (below). Read live — the
                // modifier's own copy is from before MainView decided.
                guard !TestHost.isActive,
                      WhatsNew.shouldOpen(hasShownFirstRun: settings.hasShownFirstRun),
                      !ProcessTapPermission.shouldAsk else { return }
                // Let the window settle first; a Settings link that brought
                // Daisy up goes first.
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                await openAfterUpdate()
            }
            .onChange(of: tapPermissionShowing) { _, showing in
                if !showing, !TestHost.isActive, WhatsNew.shouldOpen(hasShownFirstRun: settings.hasShownFirstRun) {
                    Task { @MainActor in await openAfterUpdate() }
                }
            }
            // The status that wasn't known at launch has arrived (Settings
            // were opened, a summary asked for it), or the account is gone.
            .onChange(of: account.subscription?.active) { _, _ in statusArrived() }
            .onChange(of: account.isSignedIn) { _, _ in statusArrived() }
    }

    /// The window by itself, unless the account signed in on this Mac has
    /// the subscription already (`WhatsNew.arrival`).
    private func openAfterUpdate() async {
        let active = account.isSignedIn ? await account.currentSubscription()?.active : nil
        await settle(subscriptionActive: active)
    }

    private func statusArrived() {
        guard awaitsStatus, !TestHost.isActive else { return }
        // Undecided again until `settle` ends: the Daisy-key bubble waits
        // on this, so the two don't come up together behind an open panel.
        WhatsNew.settledThisLaunch = false
        Task { @MainActor in await settle(subscriptionActive: account.subscription?.active) }
    }

    /// Decides with what is known now. Still once per edition and never for
    /// a subscriber (`WhatsNew.arrive`), still behind the other sheets.
    private func settle(subscriptionActive: Bool?) async {
        // Signed in read here, after the answer: a session the server
        // refused is signed out by now.
        let signedIn = account.isSignedIn
        let arrival = WhatsNew.arrive(hasShownFirstRun: settings.hasShownFirstRun, signedIn: signedIn,
                                      subscriptionActive: signedIn ? subscriptionActive : nil)
        awaitsStatus = arrival == .later
        if arrival == .open, !Task.isCancelled, await SheetQueue.waitForNoPanel(),
           // Opened from Help meanwhile: seen already.
           WhatsNew.shouldOpen(hasShownFirstRun: settings.hasShownFirstRun) {
            nav.showsWhatsNew = true
        }
        WhatsNew.settledThisLaunch = true
    }
}

// MARK: - What «Subscribe» does

/// One decision for the window's button, apart from the window.
nonisolated enum WhatsNewSubscribe: Equatable {
    /// The payment page for the chosen plan, as «Subscribe» in Settings
    /// opens it; then Settings at the subscription's block, where the wait
    /// for the payment shows.
    case checkout
    /// Settings at the subscription's block with the chosen plan picked
    /// there: the person signs in and answers the question about sending
    /// text first. Buying is not that answer.
    case settings
    /// Nothing to buy: the subscription is active, or a payment page is
    /// open and waited for. Settings at the block, which says which.
    case status

    /// `active`: the account's status as the server last gave it; nil when
    /// it isn't known (signed out, not read yet, the server not reached).
    /// Unknown buys nothing, as in Settings, whose «Plan» row comes only
    /// with a status that says «not subscribed»: the block shows the
    /// status being read, or why it couldn't be.
    static func action(signedIn: Bool, consented: Bool, active: Bool?, awaitingPayment: Bool) -> WhatsNewSubscribe {
        if active == true || awaitingPayment { return .status }
        return signedIn && consented && active == false ? .checkout : .settings
    }

    /// Does it. `openSettings` closes the window and opens Settings → AI at
    /// the subscription's block. Returns the words of a checkout that
    /// failed: the window then stays and shows them, as the row in Settings
    /// shows its own, and nothing else happens.
    ///
    /// Settings open only once the page is: `DaisyAccountStore.onPaid`
    /// turns the subscription's switch on for a payment seen while the
    /// wait still shows, and the row that shows it, with its Cancel, is the
    /// one in Settings.
    @MainActor
    static func run(plan: DaisyAccountStore.Plan, store: DaisyAccountStore,
                    openSettings: @MainActor () -> Void) async -> String? {
        let decided = action(signedIn: store.isSignedIn, consented: store.hasAcknowledgedCloudDisclosure,
                             active: store.isSignedIn ? store.subscription?.active : nil,
                             awaitingPayment: store.awaitingPayment)
        switch decided {
        case .checkout:
            // The row in Settings shows the same plan if the wait is called off.
            store.chosenPlan = plan
            do {
                try await store.checkout(plan)
            } catch is CancellationError {
                // The window was closed while the page was being made.
                return nil
            } catch {
                return error.localizedDescription
            }
        case .settings:
            store.chosenPlan = plan
        case .status:
            break
        }
        openSettings()
        return nil
    }
}

/// The button's state, apart from the view: one purchase at a time.
@MainActor
@Observable
final class WhatsNewPurchase {
    /// A click is on its way to its payment page (or to Settings).
    private(set) var isWorking = false
    /// The words of a checkout that failed.
    private(set) var error: String?
    @ObservationIgnored private var work: Task<Void, Never>?

    /// One click's worth of `WhatsNewSubscribe.run`. A second click, or
    /// Return held down, while the first is on its way does nothing:
    /// `.disabled` is redrawn too late to stop it, `checkout` takes every
    /// call, and two calls are two payment pages. Nil: nothing was started.
    @discardableResult
    func subscribe(plan: DaisyAccountStore.Plan, store: DaisyAccountStore,
                   openSettings: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        guard !isWorking else { return nil }
        isWorking = true
        error = nil
        let task = Task {
            error = await WhatsNewSubscribe.run(plan: plan, store: store, openSettings: openSettings)
            isWorking = false
        }
        work = task
        return task
    }

    /// The window is gone: a page still being made is not opened.
    func cancel() { work?.cancel() }
}

// MARK: - The window

struct WhatsNewSheet: View {
    @Bindable private var store: DaisyAccountStore
    private let openSettings: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss
    /// The year unless the person picks the month, as on the iPhone.
    @State private var plan: DaisyAccountStore.Plan = .year
    @State private var purchase = WhatsNewPurchase()
    /// The tallest the window may be (`heightLimit`); shorter than its
    /// content, the feature rows scroll, then the photograph gives way.
    private let maxHeight: CGFloat

    static let width: CGFloat = 640
    nonisolated static let heroHeight: CGFloat = 236
    /// The photograph at its shortest: the pill, the headline and the line
    /// under it, with a breath of field below them.
    nonisolated static let heroMinimum: CGFloat = 188
    /// The least of the feature rows left on screen to scroll: a row and
    /// the start of the next, so it reads as a list that goes on.
    nonisolated static let featuresMinimum: CGFloat = 76
    /// Ink for words ON the photograph, which is bright in both themes.
    private static let photoInk = Color(hex: 0x1F1D19)

    /// `store`: a test's account; nil is the app's own. `openSettings`
    /// closes the window and opens Settings → AI at the subscription's block.
    init(store: DaisyAccountStore? = nil, maxHeight: CGFloat = .infinity,
         openSettings: (@MainActor () -> Void)? = nil) {
        self.store = store ?? .shared
        self.maxHeight = maxHeight
        self.openSettings = openSettings ?? { AppNavigation.shared.openInSettings(.ai, row: .daisySubscription) }
    }

    private var isActive: Bool { store.subscription?.active == true }

    var body: some View {
        // On a display too short for the whole window, what gives way, in
        // this order: the feature rows scroll, down to a strip; then the
        // photograph gets shorter, down to its words. The plans (or the
        // subscription's state) never leave the button they belong to: a
        // person must see what «Subscribe» buys.
        VStack(spacing: 0) {
            hero
                .layoutPriority(1)
            featureRows
            fixedPart
                .layoutPriority(2)
        }
        .frame(width: Self.width)
        .frame(maxHeight: maxHeight.isFinite ? maxHeight : nil)
        // Its own height, the limit at most: the sheet is as tall as this says.
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.daisyBgPrimary)
        // The status as it is now, for a window opened by hand.
        .task { if store.isSignedIn { _ = await store.currentSubscription() } }
        .onDisappear { purchase.cancel() }
    }

    /// A sheet hangs under its window's title bar and may be taller than
    /// the window (this one is, at the main window's default 640 pt): macOS
    /// slides the window up for it. What it can't outgrow is the display.
    /// So the limit is the display's usable height less the title bar and a
    /// margin, not the window's height, which limits Settings and About
    /// (`PanelSize`): on a 13-inch display at its default scaling nothing
    /// scrolls, at «Larger Text» or with a tall Dock the feature rows do.
    static func heightLimit(under window: NSWindow?) -> CGFloat {
        guard let window, let screen = window.screen ?? NSScreen.main else { return .infinity }
        return heightLimit(displayHeight: screen.visibleFrame.height,
                           titleBar: window.frame.height - window.contentLayoutRect.height)
    }

    nonisolated static func heightLimit(displayHeight: CGFloat, titleBar: CGFloat) -> CGFloat {
        max(minimumHeight, displayHeight - max(0, titleBar) - PanelSize.margin)
    }

    /// The photograph at its shortest, a strip of feature rows, and the
    /// plans with the button and its small print whole: never less
    /// (WhatsNewTests holds the three to it).
    nonisolated static let minimumHeight: CGFloat = 540

    /// What the subscription gives: whole when there is room, a scrolling
    /// list when there isn't. The cut is marked the way the app marks a
    /// list over a fixed footer, a divider, with the window's own fade
    /// above it (as under the photograph), and the scroller shows.
    private var featureRows: some View {
        ViewThatFits(in: .vertical) {
            features
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            ScrollView {
                features
                    .padding(.horizontal, 24)
                    .padding(.bottom, 22)
            }
            .scrollIndicators(.visible)
            .scrollIndicatorsFlash(onAppear: true)
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    LinearGradient(colors: [Color.daisyBgPrimary.opacity(0), Color.daisyBgPrimary],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 18)
                    Divider()
                }
                .allowsHitTesting(false)
            }
            // Clear of the year's badge, which stands above its card.
            .padding(.bottom, 12)
        }
        .frame(minHeight: Self.featuresMinimum)
    }

    /// The choice, the button that acts on it and what the button's small
    /// print says: one block, always whole.
    private var fixedPart: some View {
        VStack(spacing: 0) {
            Group {
                if isActive { activeCard } else { plans }
            }
            .padding(.bottom, 12)
            if isActive { doneButton } else { offer }
            footerLinks
                .padding(.top, 8)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    // MARK: The photograph, and the words on it

    private var hero: some View {
        GeometryReader { space in
            ZStack(alignment: .topLeading) {
                WhatsNewFieldPhoto(height: space.size.height)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Daisy Subscription")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.7)))
                    Text("Summaries without an API key")
                        .font(.system(size: 30, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Daisy writes them for you, with no key of your own")
                        .font(.system(size: 14))
                        .opacity(0.82)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Self.photoInk)
                // The left of the photograph is the open field; the daisy has the right.
                .frame(width: 330, alignment: .leading)
                .padding(.leading, 26)
                // Above the fade: under it, in the dark theme, dark ink would sink.
                .padding(.top, 24)
            }
        }
        // Its own height wherever the display allows; shorter only once the
        // feature rows are down to their strip.
        .frame(width: Self.width)
        .frame(minHeight: Self.heroMinimum, idealHeight: Self.heroHeight, maxHeight: Self.heroHeight)
    }

    // MARK: What it gives

    private var features: some View {
        VStack(alignment: .leading, spacing: 12) {
            feature("sparkles",
                    String(localized: "Not only summaries"),
                    String(localized: "Follow-ups, briefs, Daisy key commands, rewrites of the selection and the transcript's second pass run on it too"))
            if !isActive {
                feature("gift", freeTitle, freeDetail)
            }
            feature("lock",
                    String(localized: "Only text is sent, never audio"),
                    String(localized: "It goes through Daisy's server to Anthropic, and only while the subscription's switch is on. Your own provider and its key stay in Settings; you can switch back any time"))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.daisyBgElevated))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.daisyDivider, lineWidth: 0.5))
    }

    /// Where the free three stand for the account on this Mac.
    nonisolated enum FreeSummaries: Equatable {
        /// Signed out, or the status not read: what they are and how to get them.
        case offered
        case left(Int)
        case used

        static func state(signedIn: Bool, remaining: Int?) -> FreeSummaries {
            guard signedIn, let remaining else { return .offered }
            return remaining > 0 ? .left(remaining) : .used
        }
    }

    private var freeSummaries: FreeSummaries {
        .state(signedIn: store.isSignedIn, remaining: store.subscription?.trialRemaining)
    }

    /// Never «three are free» over «they are used».
    private var freeTitle: String {
        freeSummaries == .used
            ? String(localized: "The free summaries are used")
            : String(localized: "Three summaries are free")
    }

    /// Signing in alone writes nothing: the subscription's switch does, so
    /// the line names it by its own label. Once the account is known, the
    /// count as the row in Settings gives it.
    private var freeDetail: String {
        let rest = String(localized: "Everything else needs the subscription")
        switch freeSummaries {
        case .offered:
            let toggle = String(localized: "Write summaries on the Daisy Subscription")
            return "\(String(localized: "For a meeting or a voice note: sign in and turn on “\(toggle)”")). \(rest)"
        case .left(let count):
            return "\(String(localized: "Free summaries left: \(count) of 3")). \(rest)"
        case .used:
            return String(localized: "Summaries and everything else now need the subscription")
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.daisyAccent)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.daisyAccentSoft))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.daisyTextPrimary)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(Color.daisyTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: The plans and the button

    private var plans: some View {
        HStack(alignment: .top, spacing: 12) {
            planCard(.year)
            planCard(.month)
        }
        // One height for both: the year has a line more.
        .fixedSize(horizontal: false, vertical: true)
        // The year's badge sits on its card's top edge.
        .padding(.top, 6)
    }

    private var offer: some View {
        VStack(spacing: 0) {
            Button(action: subscribe) {
                HStack(spacing: 8) {
                    if purchase.isWorking { ProgressView().controlSize(.small) }
                    Text(String(localized: "daisySubscription.subscribe", defaultValue: "Subscribe"))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
            }
            .buttonStyle(.daisyPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(purchase.isWorking)
            .accessibilityHint(Text("The payment page opens in your browser"))
            if let error = purchase.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.daisyWarning)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            // Two sentences, a line each: run together they broke mid-path.
            VStack(spacing: 2) {
                Text("The payment page opens in your browser")
                Text(verbatim: renewal)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(Color.daisyTextSecondary)
            .multilineTextAlignment(.center)
            .padding(.top, 10)
            .padding(.bottom, 4)
            // Never disabled: the window can be left while the page is being made.
            Button("Not now") { dismiss() }
                .buttonStyle(.daisyQuiet)
                .keyboardShortcut(.cancelAction)
        }
    }

    /// Where it is cancelled is where Settings manage it: the block's own
    /// «Manage subscription», named by its words.
    private var renewal: String {
        String(localized: "The subscription renews until you cancel it in \(SettingsRow.daisySubscription.path), “\(String(localized: "Manage subscription"))”")
    }

    private func planCard(_ card: DaisyAccountStore.Plan) -> some View {
        let selected = plan == card
        let isYear = card == .year
        let name = isYear
            ? String(localized: "whatsNew.plan.year", defaultValue: "Yearly")
            : String(localized: "whatsNew.plan.month", defaultValue: "Monthly")
        let price = DaisyAccountStore.Plan.priceText(card.price)
        let period = isYear
            ? String(localized: "whatsNew.plan.perYear", defaultValue: "per year")
            : String(localized: "whatsNew.plan.perMonth", defaultValue: "per month")
        // Both figures from the two prices, never written out.
        let month = DaisyAccountStore.Plan.month.price
        let perMonth = isYear
            ? String(localized: "\(DaisyAccountStore.Plan.priceText(DaisyPlanMath.perMonth(yearly: card.price))) a month")
            : nil
        let savings = isYear ? DaisyPlanMath.savingsPercent(monthly: month, yearly: card.price) : nil
        let saves = savings.map { String(localized: "Save \($0)%") }
        return Button { plan = card } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(selected ? Color.daisyTextPrimary : Color.daisyTextTertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(price)
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    Text(period)
                        .font(.callout)
                        .foregroundStyle(Color.daisyTextSecondary)
                }
                if let perMonth {
                    Text(perMonth)
                        .font(.caption)
                        .foregroundStyle(Color.daisyTextSecondary)
                }
            }
            .foregroundStyle(Color.daisyTextPrimary)
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.daisyBgElevated))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.daisyTextPrimary : Color.daisyDivider, lineWidth: selected ? 2 : 1))
            .overlay(alignment: .top) {
                if let savings {
                    Text(verbatim: "−\(savings)%")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.daisyTextOnAccent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.daisyAccent))
                        .offset(y: -10)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(purchase.isWorking)
        // The price with its period, in one breath. One element of its own
        // words, so the press is named too.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [name, "\(price) \(period)", perMonth, saves].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { plan = card }
    }

    private func subscribe() {
        purchase.subscribe(plan: plan, store: store, openSettings: openSettings)
    }

    // MARK: Subscribed already

    /// Opened by hand by a subscriber: nothing to sell, only what is so.
    private var activeCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.daisySuccess)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your subscription is active")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.daisyTextPrimary)
                if let detail = store.subscription?.primary.flatMap(activeDetail) {
                    Text(verbatim: detail)
                        .font(.callout)
                        .foregroundStyle(Color.daisyTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button("Open Settings") { openSettings() }
                .buttonStyle(.daisySecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.daisyBgElevated))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.daisyDivider, lineWidth: 0.5))
    }

    private var doneButton: some View {
        Button { dismiss() } label: {
            Text("Done")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
        }
        .buttonStyle(.daisyPrimary)
        .keyboardShortcut(.defaultAction)
        // Escape closes this state too; it has one button to show.
        .background {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    /// What the row of Settings says after «Active» (`activeLine`): until
    /// when, and where it is managed when it was bought on the iPhone.
    private func activeDetail(_ source: DaisySubscriptionStatus.Source) -> String? {
        var parts: [String] = []
        if let date = source.renewsAt?.formatted(date: .long, time: .omitted) {
            parts.append(source.willRenew == false
                ? String(localized: "Until \(date), won't renew")
                : String(localized: "Renews \(date)"))
        }
        if source.kind == .appStore {
            parts.append(String(localized: "Bought on iPhone, managed in the App Store"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    // MARK: The links

    private var footerLinks: some View {
        HStack(spacing: 6) {
            Link(String(localized: "whatsNew.link.terms", defaultValue: "Terms"), destination: Self.terms)
            Text(verbatim: "·").accessibilityHidden(true)
            Link(String(localized: "Privacy"), destination: Self.privacy)
            Text(verbatim: "·").accessibilityHidden(true)
            Link(String(localized: "whatsNew.link.refunds", defaultValue: "Refunds"), destination: Self.refunds)
        }
        .font(.caption)
        .foregroundStyle(Color.daisyTextSecondary)
        .tint(Color.daisyTextSecondary)
    }

    #if DEBUG
    /// The block that never scrolls, for measuring it outside the window.
    var fixedPartForInspection: some View { fixedPart.frame(width: Self.width) }
    #endif

    static let terms = URL(string: "https://mydaisy.io/terms")!
    static let privacy = URL(string: "https://mydaisy.io/privacy")!
    static let refunds = URL(string: "https://mydaisy.io/refunds")!
}

/// The brand's field photograph across the top of the window: the daisy
/// kept in view at the right, the bottom edge fading into the window so
/// what is below grows out of it. Decoration: nothing for VoiceOver.
private struct WhatsNewFieldPhoto: View {
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drifted = false

    var body: some View {
        Image("WhatsNewField")
            .resizable()
            .scaledToFill()
            // A very slow drift towards the daisy; still under Reduce
            // Motion. One repeating animation of this picture's scale, begun
            // once: no timeline, nothing else in the window is drawn again.
            .scaleEffect(drifted ? 1.06 : 1, anchor: .bottomTrailing)
            .frame(width: WhatsNewSheet.width, height: height, alignment: .bottomTrailing)
            .clipped()
            .overlay(alignment: .bottom) {
                // Shorter with the photograph, so it never reaches the words.
                LinearGradient(colors: [Color.daisyBgPrimary.opacity(0), Color.daisyBgPrimary],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: min(60, max(14, height - (WhatsNewSheet.heroMinimum - 14))))
            }
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 26).repeatForever(autoreverses: true)) { drifted = true }
            }
    }
}

// MARK: - Parts the tour draws with

/// The key as keycaps: ⌃ ⌥ for the default, the right ⌘, or the chord
/// the person recorded.
struct WhatsNewKeycaps: View {
    struct Cap: Equatable {
        let glyph: String
        let name: String
    }

    let caps: [Cap]
    let down: Bool

    static func caps(for choice: HotkeyChoice) -> [Cap] {
        if let key = choice.loneModifier { return [Cap(glyph: key.glyph, name: key.capName)] }
        let mods = choice.modifiers ?? 0
        var caps: [Cap] = []
        if mods & UInt32(controlKey) != 0 { caps.append(Cap(glyph: "⌃", name: "control")) }
        if mods & UInt32(optionKey) != 0 { caps.append(Cap(glyph: "⌥", name: "option")) }
        if mods & UInt32(shiftKey) != 0 { caps.append(Cap(glyph: "⇧", name: "shift")) }
        if mods & UInt32(cmdKey) != 0 { caps.append(Cap(glyph: "⌘", name: "command")) }
        if choice.keyCode != HotkeyChoice.modifiersOnlyKeyCode, choice.keyCode != UInt32(kVK_Function) {
            let letter = choice.label.drop { "⌃⌥⇧⌘".contains($0) }
            if !letter.isEmpty { caps.append(Cap(glyph: String(letter), name: "")) }
        } else if choice.isFnOnly {
            caps.append(Cap(glyph: "fn", name: ""))
        }
        return caps
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 7) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                VStack(spacing: 3) {
                    Text(cap.glyph).font(.system(size: 16))
                    if !cap.name.isEmpty {
                        Text(cap.name).font(.system(size: 8.5)).foregroundStyle(Color.daisyTextTertiary)
                    }
                }
                .frame(minWidth: 46, minHeight: 42)
                .padding(.horizontal, cap.name.count > 8 ? 8 : 0)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.daisyBgPrimary)
                        // The key's edge, gone while it's pressed.
                        .shadow(color: .black.opacity(down ? 0 : 0.22), radius: 0, y: down ? 0 : 3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(down ? Color.daisyMarkDaisyPetalTo : Color.daisyDivider, lineWidth: down ? 2 : 1)
                )
                .offset(y: down ? 3 : 0)
            }
        }
    }
}
