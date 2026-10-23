//
//  StyleProfileTip.swift
//  Daisy
//
//  The one-time «profile is ready» ask (Onboarding 2.0, package D,
//  Egor 23.10): when a language's dictations first reach
//  `VoiceProfileStore.unlockWords` and that language has no profile yet,
//  Daisy says so once at the widget — «Слов набралось. Собрать твой
//  профиль стиля?» — with «Собрать» and the pill's own ✕.
//
//  It only ASKS. A click anywhere on a pill with an action accepts it
//  (`FloatingPanelController.showBubble`), so a stray click is a yes —
//  and that is why «Собрать» builds right there only when the provider
//  is effectively local. On any other provider the pill's action is
//  «Открыть»: My style, where the Generate button and its page say what
//  the profile is built from. Either way generation is the My style
//  button's own path (`VoiceProfileStore.generate`) with today's
//  provider and privacy handling — no new egress, no new consent surface
//  (the second-pass privacy rule). A provider that can't run says so in
//  the result, in the same words the My style card would show.
//
//  Not asked of someone who has a universal profile (carried over from
//  before the language split, or pasted in from another app): it already
//  covers every language, and a built Russian profile would quietly take
//  over from it for Russian.
//
//  Never over a recording, a dictation, a Daisy-key command or another
//  pill: the crossing usually happens INSIDE a dictation's stop, so the
//  ask waits — persisted, so a quit doesn't lose it — and is retried on a
//  timer and on every later dictation.
//

import AppKit

@MainActor
final class StyleProfileTip {
    static let shared = StyleProfileTip()

    static let bubbleTag = "style-profile-tip"
    /// Bool per language: the ask was shown. Never cleared.
    static let shownKeyPrefix = "daisy.styleProfileTip.shown."
    /// [String]: languages that crossed while Daisy was busy.
    static let pendingKey = "daisy.styleProfileTip.pending"

    private let defaults: UserDefaults
    private let isSuppressed: Bool
    private let isBusy: @MainActor () -> Bool
    private let providerIsLocal: @MainActor () -> Bool
    /// The ask. False = nothing reached the screen, and the ask stays
    /// pending: there is no banner fallback, because a banner can carry
    /// no button and a silent one (notifications off) would spend the
    /// person's only ask on nothing.
    private let showAsk: @MainActor (WidgetBubbleContent) -> Bool
    /// The outcome of «Собрать» — a pill, or a banner without a widget.
    private let presentResult: @MainActor (WidgetBubbleContent) -> Void
    private let retryDelay: Duration
    /// The store whose corpus grew last — what «Собрать» builds from.
    private weak var store: VoiceProfileStore?
    private var retryTask: Task<Void, Never>?
    /// Ten minutes of retries; after that, the next dictation tries again.
    private static let maxRetries = 20

    init(
        defaults: UserDefaults = .standard,
        // Tests run inside Daisy.app on the real prefs: a pill that pops
        // by itself there would burn Egor's one-time ask.
        isSuppressed: Bool = TestHost.isActive,
        isBusy: @escaping @MainActor () -> Bool = StyleProfileTip.daisyIsBusy,
        providerIsLocal: @escaping @MainActor () -> Bool = { Summarizer.shared.providerIsEffectivelyLocal },
        showAsk: @escaping @MainActor (WidgetBubbleContent) -> Bool = { WidgetBubbleCenter.shared.show($0) },
        presentResult: @escaping @MainActor (WidgetBubbleContent) -> Void = {
            WidgetBubbleCenter.shared.present($0, notificationTitle: "Daisy")
        },
        retryDelay: Duration = .seconds(30)
    ) {
        self.defaults = defaults
        self.isSuppressed = isSuppressed
        self.isBusy = isBusy
        self.providerIsLocal = providerIsLocal
        self.showAsk = showAsk
        self.presentResult = presentResult
        self.retryDelay = retryDelay
    }

    /// A recording, a dictation (main or side), a finalize or summary in
    /// flight, a Daisy-key command being written, or another pill on
    /// screen — a pill of ours must not replace a prompt that needs an
    /// answer now.
    static func daisyIsBusy() -> Bool {
        RecordingSession.isCapturingOrTranscribing
            || DaisyKeyController.shared.isBusy
            || WidgetBubbleCenter.shared.host?.isBubbleShown == true
    }

    func hasShown(_ language: String) -> Bool {
        defaults.bool(forKey: Self.shownKeyPrefix + language)
    }

    var pendingLanguages: [String] {
        defaults.stringArray(forKey: Self.pendingKey) ?? []
    }

    /// `VoiceProfileStore.thresholdObserver`. `crossed` may be empty: any
    /// growth is a chance to show one still waiting.
    func corpusGrew(crossed: [String], in store: VoiceProfileStore) {
        guard !isSuppressed else { return }
        self.store = store
        let fresh = crossed.filter { !hasShown($0) && !pendingLanguages.contains($0) }
        if !fresh.isEmpty {
            defaults.set(pendingLanguages + fresh, forKey: Self.pendingKey)
        }
        showPendingIfCalm()
    }

    /// Show the first language still waiting, if Daisy is idle; else try
    /// again later. One pill at a time — another waiting language gets its
    /// turn at the next growth.
    func showPendingIfCalm(attempt: Int = 0) {
        guard !isSuppressed, let store else { return }
        // Drop what no longer needs asking: shown already, a profile got
        // built in the meantime (My style, the tip on another language),
        // a universal profile appeared, or the words fell back under the
        // line (meetings switched off).
        let waiting = pendingLanguages.filter {
            !hasShown($0)
                && store.profile(for: $0) == nil
                && store.legacyProfile == nil
                && store.canGenerate(for: $0)
        }
        if waiting != pendingLanguages {
            defaults.set(waiting, forKey: Self.pendingKey)
        }
        guard let language = waiting.first else {
            retryTask?.cancel()
            retryTask = nil
            return
        }
        guard !isBusy() else {
            scheduleRetry(attempt: attempt + 1)
            return
        }
        let buildsHere = providerIsLocal()
        let ask = WidgetBubbleContent(
            text: String(localized: "Enough words now. Build your style profile?"),
            actionTitle: buildsHere ? String(localized: "Build") : String(localized: "Open"),
            autoDismiss: 20,
            tag: Self.bubbleTag,
            action: buildsHere
                ? { [weak self] in self?.build(language) }
                : { Self.openMyStyle() }
        )
        guard showAsk(ask) else {
            scheduleRetry(attempt: attempt + 1)
            return
        }
        retryTask?.cancel()
        retryTask = nil
        defaults.set(true, forKey: Self.shownKeyPrefix + language)
        defaults.set(Array(waiting.dropFirst()), forKey: Self.pendingKey)
    }

    private func scheduleRetry(attempt: Int) {
        guard attempt <= Self.maxRetries, retryTask == nil else { return }
        retryTask = Task { [weak self, retryDelay] in
            try? await Task.sleep(for: retryDelay)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.showPendingIfCalm(attempt: attempt)
        }
    }

    /// «Собрать»: the My style button's own path, then the outcome at
    /// the widget — the person tapped there, not in the window.
    func build(_ language: String) {
        guard let store else { return }
        Task { @MainActor [weak self] in
            await store.generate(language: language)
            let text: String
            switch store.state(for: language) {
            case .ready:
                text = String(localized: "Your style profile is ready.")
            case .failed(let reason):
                // The same words the My style card shows for this failure
                // (no provider, a provider that didn't answer…).
                text = reason
            case .idle, .generating:
                // Another tap is already building it; that one reports.
                return
            }
            guard let self else { return }
            // Generation can take half a minute; whatever started since
            // keeps the widget, and the outcome goes to a toast instead.
            guard !self.isBusy() else {
                ToastCenter.shared.show(text, style: .info, duration: .seconds(6))
                return
            }
            self.presentResult(
                WidgetBubbleContent(
                    text: text,
                    actionTitle: String(localized: "Open"),
                    tag: Self.bubbleTag,
                    action: { Self.openMyStyle() }
                )
            )
        }
    }

    /// Daisy's window on My style → Voice. Same window dance as the
    /// morning-brief pill: SwiftUI's `openWindow` when the widget layer
    /// registered it (the only way to recreate a closed scene), else
    /// surface whatever window exists.
    static func openMyStyle() {
        AppNavigation.shared.section = .voice
        AppNavigation.shared.pendingStyleTab = .voice
        if let open = WidgetBubbleCenter.shared.openMainWindow {
            open()
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
    }
}
