//
//  OnboardingTour.swift
//  Daisy
//
//  Onboarding 2.0 (Egor 23–24.10): the first run is a short tour in which
//  Daisy introduces herself and teaches by doing — nine steps, the order
//  and the words of the approved prototype (v3). The window shows the
//  scene (OnboardingTourView), Daisy speaks from the coach bubble beside
//  the widget (TourBubble), and every line comes from OnboardingCopy.
//
//  Three layers here:
//   • `OnboardingTour` — the pure state machine: which steps a path has,
//     what moves between them, which event finishes which step, and the
//     resume snapshot. Unit-tested without a screen.
//   • `TourHooks` — the three calls into the demo meeting and the style
//     samples (packages C and D), swappable for the tests.
//   • `OnboardingTourController` — the one live tour: side effects per
//     step (widget, permissions, hotkeys, the practice field, the models),
//     the bubble's script, and `finish()`, which keeps what FirstRunView's
//     did: `hasShownFirstRun`, «What's New» marked seen, the window grown
//     to the shell's floor.
//
//  Calendar, the processing plan, the summary provider and templates are
//  no longer asked here — they move to contextual tips (package E).
//

import AppKit
import Foundation
import os

// MARK: - State machine

nonisolated struct OnboardingTour: Equatable, Sendable {
    /// Flow order. Raw values are persisted (resume) — spelled out so a
    /// reorder never resumes onto a different step.
    enum Step: String, CaseIterable, Sendable {
        case hello
        case you
        case widget
        case dictation
        case style
        case daisyKey
        /// Full path only.
        case meeting
        case models
        case done
    }

    /// The pick on «Ты»: what Daisy is for. Not an app mode — it only
    /// decides whether the tour shows the meeting step.
    enum Path: String, Sendable {
        case full
        case dictationOnly
    }

    /// What the person did. Each finishes exactly one step, and only
    /// while that step is the current one.
    enum Event: Equatable, Sendable {
        /// The widget was dragged (`FloatingPanelController.widgetMoved`).
        case widgetMoved
        /// «Оставить здесь».
        case widgetKept
        /// A dictation landed in the practice field.
        case dictationLanded
        /// The passage was read into the practice field.
        case passageRead
        /// A Daisy-key note was saved.
        case noteSaved
        /// The demo or the person's own recording is on screen.
        case meetingShown
        /// The standard model is downloaded and checked.
        case modelsReady
    }

    private(set) var step: Step
    private(set) var path: Path
    /// The current step's task is done: Daisy says her «done» line and
    /// «Дальше» appears. Reset on every move.
    private(set) var isStepDone = false

    init(step: Step = .hello, path: Path = .full) {
        self.step = step
        self.path = path
    }

    static func steps(for path: Path) -> [Step] {
        switch path {
        case .full: Step.allCases
        case .dictationOnly: Step.allCases.filter { $0 != .meeting }
        }
    }

    var steps: [Step] { Self.steps(for: path) }

    /// «4 из 9» — the place within this path.
    var number: Int { (steps.firstIndex(of: step) ?? 0) + 1 }
    var total: Int { steps.count }

    /// The step a given event finishes.
    static func step(finishedBy event: Event) -> Step {
        switch event {
        case .widgetMoved, .widgetKept: .widget
        case .dictationLanded: .dictation
        case .passageRead: .style
        case .noteSaved: .daisyKey
        case .meetingShown: .meeting
        case .modelsReady: .models
        }
    }

    /// The dictation and Daisy keys work from the dictation step on —
    /// before it nothing has explained them, and registering the fn
    /// monitor is what makes macOS ask for Input Monitoring.
    var keysLive: Bool {
        let all = Step.allCases
        return all.firstIndex(of: step)! >= all.firstIndex(of: .dictation)!
    }

    /// «Дальше», and «Пропустить» on a step — the same move: the next
    /// step of the path. Stays on `.done`, which only `finish` leaves.
    mutating func next() {
        let all = Step.allCases
        let position = all.firstIndex(of: step)!
        if let following = all[(position + 1)...].first(where: steps.contains) {
            step = following
        }
        isStepDone = false
    }

    /// A card on «Ты»: the path is set and the tour moves on.
    mutating func choosePath(_ path: Path) {
        guard step == .you else { return }
        self.path = path
        next()
    }

    /// «Пропустить тур» — straight to «Готово» (the prototype's goTo(N)).
    mutating func skipTour() {
        step = .done
        isStepDone = false
    }

    /// True when the event finished the current step (it wasn't already
    /// done, and it belongs to this step). Anything else is ignored: a
    /// late drag of the widget doesn't finish the dictation step.
    @discardableResult
    mutating func handle(_ event: Event) -> Bool {
        guard !isStepDone, Self.step(finishedBy: event) == step else { return false }
        isStepDone = true
        return true
    }

    // MARK: Resume

    /// Where a resumed tour lands: the saved step if this path has it,
    /// else the nearest earlier one, else the start.
    static func resumeStep(savedRaw: String?, path: Path) -> Step {
        guard let savedRaw, let saved = Step(rawValue: savedRaw) else { return .hello }
        let steps = steps(for: path)
        if steps.contains(saved) { return saved }
        let all = Step.allCases
        let index = all.firstIndex(of: saved)!
        return all[..<index].last(where: steps.contains) ?? .hello
    }

    static func load(from defaults: UserDefaults) -> OnboardingTour {
        let path = Path(rawValue: defaults.string(forKey: AppSettings.k_tourPath) ?? "") ?? .full
        let step = resumeStep(savedRaw: defaults.string(forKey: AppSettings.k_tourStep), path: path)
        return OnboardingTour(step: step, path: path)
    }

    func save(to defaults: UserDefaults) {
        defaults.set(step.rawValue, forKey: AppSettings.k_tourStep)
        defaults.set(path.rawValue, forKey: AppSettings.k_tourPath)
    }

    static func clear(_ defaults: UserDefaults) {
        for key in [AppSettings.k_tourStep, AppSettings.k_tourPath, AppSettings.k_tourAccessibilityAsked] {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - Hooks into the demo meeting and the style profile

/// The tour's three calls into work built alongside it (packages C and
/// D, merged 24.10): the demo meeting and the style samples. Swappable so
/// the tests can run the tour without a Library or a corpus.
@MainActor
enum TourHooks {
    /// Installs the bundled demo meeting in the given language ("ru", "en")
    /// and returns its session id (`StoredSession.ID`), or nil when it
    /// could not be written (`DemoSession.install` logs why).
    static var installDemoMeeting: @MainActor (String) async -> String? = { locale in
        let id = await DemoSession.install(locale: locale)
        return id.isEmpty ? nil : id
    }

    /// The dictation step's text, in the person's own words, and the
    /// dictation locale ("ru-RU", "en", "auto"). `appendTourSample` finds
    /// the same words `DictationPaste` already put in the corpus and only
    /// tags them — nothing is counted twice.
    static var styleSample: @MainActor (String, String) -> Void = { text, locale in
        VoiceProfileStore.shared.appendTourSample(text, locale: locale)
    }

    /// The counter on the style step: words so far toward a style profile
    /// for that locale, and the threshold. Read in a view body, so it
    /// updates live through the store's observation.
    static var styleProgress: @MainActor (String) -> (words: Int, threshold: Int) = { locale in
        VoiceProfileStore.shared.progress(locale: locale)
    }
}

// MARK: - The live tour

@MainActor @Observable
final class OnboardingTourController {
    static let shared = OnboardingTourController()

    /// The meeting step's own little flow.
    enum MeetingPhase: Equatable {
        case choosing
        /// «Запишу сам»: recording since this moment (nil while starting).
        case recording(since: Date?)
        /// Stopping, or installing the demo.
        case finishing
        /// The meeting to show in the window, when there is one.
        case showing(String?)
    }

    private(set) var tour = OnboardingTour()
    /// The tour owns the main window: first run, or a replay from Help /
    /// About. MainView branches on it with `hasShownFirstRun`.
    private(set) var isActive = false
    /// What the practice field holds on the dictation and style steps.
    var practiceText = ""
    /// A key is held and Daisy is listening — the bubble says «Слушаю…».
    private(set) var isListening = false
    private(set) var meeting: MeetingPhase = .choosing
    private(set) var isAskingMeetingAccess = false
    /// The tour already fired the one-shot Accessibility prompt (macOS asks
    /// once; after that only System Settings helps). Persisted.
    private(set) var accessibilityAsked = false
    /// The ONE standard model (Egor 24.10 «одна стандартная на всё»):
    /// started as soon as the path is known, so dictation on step 4 has
    /// it; the models step shows where it is.
    let preparation = ModelPreparation()

    @ObservationIgnored private weak var settings: AppSettings?
    @ObservationIgnored private weak var session: RecordingSession?
    @ObservationIgnored private var defaults: UserDefaults = .standard
    /// The step whose side effects have run — `enter` is idempotent.
    @ObservationIgnored private var enteredStep: OnboardingTour.Step?
    @ObservationIgnored private var keysApplied = false
    /// The widget switch before a replay turned it on — put back by
    /// `finish`: a tour shown again mustn't undo «hide the widget».
    @ObservationIgnored private var widgetEnabledBeforeReplay: Bool?
    /// The flower is flying to the widget; the bubble waits for it.
    @ObservationIgnored private var isFlying = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// A step's background work (the Accessibility watch, the meeting
    /// timer) — cancelled when the step is left.
    @ObservationIgnored private var stepTask: Task<Void, Never>?

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "OnboardingTour")

    private init() {}

    /// The keys are registered for the tour (ServiceWiring reads this
    /// beside `hasShownFirstRun`).
    var keysLive: Bool { isActive && tour.keysLive }

    /// Show the tour instead of the app's shell.
    static func showsTour(hasShownFirstRun: Bool, isActive: Bool) -> Bool {
        !hasShownFirstRun || isActive
    }

    // MARK: Start, restart, finish

    /// The tour's window appeared. On a first run this is the start (or
    /// the resume); on a replay `restart` already started it.
    func attach(settings: AppSettings, session: RecordingSession) {
        // The test host runs the app on real prefs: nothing starts by itself.
        guard !TestHost.isActive else { return }
        self.settings = settings
        self.session = session
        if !isActive {
            guard !settings.hasShownFirstRun else { return }
            tour = OnboardingTour.load(from: defaults)
            accessibilityAsked = defaults.bool(forKey: AppSettings.k_tourAccessibilityAsked)
            isActive = true
            // Resumed past «Ты»: the model was on its way before the quit.
            if tour.step != .hello && tour.step != .you { startPreparation() }
        }
        installObservers()
        enter()
    }

    /// «Пройти тур заново» (Help, About, the last screen): step 1 again.
    func restart(settings: AppSettings? = nil) {
        guard !TestHost.isActive else { return }
        if let settings { self.settings = settings }
        if let entered = enteredStep { leave(entered) }
        enteredStep = nil
        if !isActive, let settings = self.settings, settings.hasShownFirstRun {
            widgetEnabledBeforeReplay = settings.floatingWidgetEnabled
        }
        tour = OnboardingTour()
        practiceText = ""
        meeting = .choosing
        isListening = false
        isActive = true
        // The window shows the tour once MainView sees `isActive`; if the
        // tour is already on screen (the «Готово» screen), enter here.
        if self.settings != nil { enter() }
    }

    /// «Открыть Daisy». Today's effects of finishing onboarding, plus the
    /// tour's own clean-up.
    func finish() {
        guard isActive, !TestHost.isActive else { return }
        if let entered = enteredStep { leave(entered) }
        enteredStep = nil
        TourBubbleCenter.shared.hide()
        FloatingPanelController.shared?.setAttentionRing(false)
        showWidget()
        if let wasEnabled = widgetEnabledBeforeReplay {
            widgetEnabledBeforeReplay = nil
            settings?.floatingWidgetEnabled = wasEnabled
            FloatingPanelController.shared?.reevaluateVisibility()
        }
        if let settings, !settings.hasShownFirstRun,
           !preparation.isRunning,
           !preparation.canFinish(settings: settings, includeSpeakers: false) {
            // Skipped or not ready yet: the model finishes in the
            // background, and the first recording waits for it.
            ModelPreparation.completeInBackground(settings: settings, includeSpeakers: false)
        }
        growWindowToShellFloor()
        OnboardingTour.clear(defaults)
        // FirstRunView's snapshot, from a build before the tour.
        for key in ["daisy.firstRun.resumeStep", "daisy.firstRun.resumePath",
                    "daisy.firstRun.accessibilityAsked", "daisy.firstRun.modelStepSeeded",
                    "daisy.preparation.started"] {
            defaults.removeObject(forKey: key)
        }
        // A fresh install learned all of it here; «What's New» is for an update.
        WhatsNew.markSeen()
        isActive = false
        practiceText = ""
        settings?.hasShownFirstRun = true
    }

    // MARK: Moves

    func next() {
        tour.next()
        enter()
    }

    func skipTour() {
        tour.skipTour()
        enter()
    }

    func choosePath(_ path: OnboardingTour.Path) {
        // The card's 350 ms can lose to «Пропустить тур».
        guard isActive, tour.step == .you else { return }
        tour.choosePath(path)
        startPreparation()
        enter()
    }

    func handle(_ event: OnboardingTour.Event) {
        guard isActive, tour.handle(event) else { return }
        if tour.step == .widget {
            FloatingPanelController.shared?.setAttentionRing(false)
        }
        refreshBubble()
    }

    /// The session started or stopped listening (a dictation or Daisy-key
    /// hold) — fed by the tour view.
    func setListening(_ on: Bool) {
        guard isListening != on else { return }
        isListening = on
        refreshBubble()
    }

    // MARK: Steps

    private func enter() {
        guard isActive, enteredStep != tour.step, !TestHost.isActive, let settings else { return }
        if let previous = enteredStep { leave(previous) }
        enteredStep = tour.step
        if !settings.hasShownFirstRun { tour.save(to: defaults) }
        if tour.keysLive != keysApplied {
            keysApplied = tour.keysLive
            applyHotkeys()
        }
        switch tour.step {
        case .hello, .you:
            // The widget arrives on step 3, flying out of the window.
            FloatingPanelController.shared?.hide()
        case .widget:
            flyToWidget()
        case .dictation, .style:
            showWidget()
            practiceText = ""
            DictationPaste.shared.practiceSink = { [weak self] text in
                self?.practiceLanded(text) ?? false
            }
            // Someone else's words read aloud aren't the person's style
            // («стиль соберу из твоих настоящих диктовок»).
            DictationPaste.shared.practiceKeepsOutOfCorpus = tour.step == .style
        case .daisyKey:
            showWidget()
            askAccessibility()
        case .meeting:
            showWidget()
            meeting = .choosing
        case .models:
            showWidget()
            startPreparation()
        case .done:
            showWidget()
        }
        refreshBubble()
    }

    private func leave(_ step: OnboardingTour.Step) {
        stepTask?.cancel()
        stepTask = nil
        switch step {
        case .widget:
            isFlying = false
            FloatingPanelController.shared?.setAttentionRing(false)
            FloatingPanelController.shared?.widgetWindow?.alphaValue = 1
        case .dictation, .style:
            DictationPaste.shared.practiceSink = nil
            DictationPaste.shared.practiceKeepsOutOfCorpus = false
        case .meeting:
            // Left mid-recording («Пропустить тур»): the take is the
            // person's, saved like any other.
            if case .recording = meeting, let session, Self.isCapturing(session) {
                Task { await session.stop() }
            }
        default:
            break
        }
        isListening = false
    }

    /// A dictation arrived while the practice field is on screen.
    private func practiceLanded(_ text: String) -> Bool {
        guard isActive, tour.step == .dictation || tour.step == .style else { return false }
        practiceText = practiceText.isEmpty ? text : practiceText + " " + text
        if tour.step == .dictation {
            TourHooks.styleSample(text, styleLocale)
            handle(.dictationLanded)
        } else {
            handle(.passageRead)
        }
        return true
    }

    // MARK: Widget

    private func showWidget() {
        settings?.floatingWidgetEnabled = true
        FloatingPanelController.shared?.reevaluateVisibility()
        FloatingPanelController.shared?.widgetWindow?.alphaValue = 1
    }

    /// Step 3: the flower flies from the window to the widget's place,
    /// the widget fades in, the ring starts, Daisy speaks.
    private func flyToWidget() {
        showWidget()
        let ringAndBubble = { [weak self] in
            guard let self, self.tour.step == .widget else { return }
            self.isFlying = false
            if !self.tour.isStepDone { FloatingPanelController.shared?.setAttentionRing(true) }
            self.refreshBubble()
        }
        guard let widget = FloatingPanelController.shared?.widgetWindow,
              let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })
        else {
            ringAndBubble()
            return
        }
        isFlying = true
        widget.alphaValue = 0
        let from = NSRect(x: window.frame.midX - 28, y: window.frame.midY - 28, width: 56, height: 56)
        TourFlight.fly(from: from, to: widget.frame) { [weak self] in
            guard let self, self.tour.step == .widget else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                widget.animator().alphaValue = 1
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                ringAndBubble()
            }
        }
    }

    // MARK: Permissions

    /// Step 6: the Daisy key needs key-up events — Accessibility. Asked
    /// once on entering (the system prompt), then watched: once granted,
    /// the key is registered at once.
    private func askAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        if !accessibilityAsked {
            accessibilityAsked = true
            defaults.set(true, forKey: AppSettings.k_tourAccessibilityAsked)
            SystemPermissions.shared.requestAccessibility()
        }
        stepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard AXIsProcessTrusted() else { continue }
                SystemPermissions.shared.refresh()
                self?.applyHotkeys()
                return
            }
        }
    }

    /// The Accessibility row's Allow / Open Settings.
    func requestAccessibilityAgain() {
        if accessibilityAsked {
            SystemPermissions.shared.openAccessibilitySettings()
        } else {
            askAccessibility()
        }
    }

    /// The meeting step's access: System Audio (the process tap, asked by
    /// listening for Daisy's own tone, as its sheet does) and Screen
    /// Recording — last, because its grant ends with «Quit & Reopen».
    var needsMeetingAccess: Bool {
        ProcessTapPermission.shouldAsk || SystemPermissions.shared.screenRecording != .granted
    }

    func askMeetingAccess() {
        guard !isAskingMeetingAccess else { return }
        isAskingMeetingAccess = true
        Task { [weak self] in
            if ProcessTapPermission.shouldAsk {
                let outcome = await ProcessTapPermission.probe(timeout: .seconds(90)) {
                    self?.tour.step != .meeting
                }
                ProcessTapPermission.record(outcome)
            }
            guard let self else { return }
            self.isAskingMeetingAccess = false
            // Left the step during the 90 s probe: no prompt on «Готово».
            guard self.isActive, self.tour.step == .meeting else { return }
            if SystemPermissions.shared.screenRecording != .granted {
                SystemPermissions.shared.requestScreenRecording()
            }
        }
    }

    // MARK: Meeting

    /// «Покажи на демо».
    func showDemo() {
        guard meeting == .choosing else { return }
        meeting = .finishing
        refreshBubble()
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        Task { [weak self] in
            let id = await TourHooks.installDemoMeeting(language)
            await SessionStore.shared.refresh()
            self?.meetingReady(id)
        }
    }

    /// «Запишу сам»: an ordinary meeting recording, stopped by a tap on
    /// the widget (which pauses it) or after 20 seconds.
    func recordMeeting() {
        guard meeting == .choosing, let session, Self.isIdle(session) else { return }
        meeting = .recording(since: nil)
        refreshBubble()
        stepTask = Task { [weak self] in
            await session.start()
            guard let self, !Task.isCancelled else {
                // The step was left while the recording was starting
                // («Пропустить тур»): `leave` couldn't stop what hadn't
                // started yet, so stop it here — saved like any take. A
                // start still in `.preparing` is waited out (up to 5 s),
                // in a task of its own: this one is cancelled, and its
                // sleeps would return at once.
                Task { @MainActor in
                    for _ in 0..<50 where session.status == .preparing {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    if session.status == .recording || session.status == .paused { await session.stop() }
                }
                return
            }
            guard Self.isCapturing(session) else {
                // Refused (a toast said why): back to the two cards.
                self.meeting = .choosing
                self.refreshBubble()
                return
            }
            let since = Date()
            self.meeting = .recording(since: since)
            self.refreshBubble()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self.refreshBubble()
                if Date().timeIntervalSince(since) >= Self.selfRecordingSeconds
                    || session.status == .paused
                    || !Self.isCapturing(session) { break }
            }
            guard !Task.isCancelled else { return }
            let id = session.sessionDirectory?.lastPathComponent
            self.meeting = .finishing
            self.refreshBubble()
            if Self.isCapturing(session) { await session.stop() }
            await SessionStore.shared.refresh()
            self.meetingReady(id)
        }
    }

    static let selfRecordingSeconds: TimeInterval = 20

    private func meetingReady(_ id: String?) {
        guard isActive, tour.step == .meeting else { return }
        meeting = .showing(id)
        handle(.meetingShown)
    }

    private static func isIdle(_ session: RecordingSession) -> Bool {
        switch session.status {
        case .idle, .finished, .failed: true
        default: false
        }
    }

    private static func isCapturing(_ session: RecordingSession) -> Bool {
        switch session.status {
        case .preparing, .recording, .paused: true
        default: false
        }
    }

    // MARK: Models

    /// The standard model for meetings and dictation, nothing else: speaker
    /// separation and the faster engine come later, when asked for.
    private func startPreparation() {
        guard !TestHost.isActive, let settings else { return }
        if !settings.hasShownFirstRun {
            // One standard model on everything (Egor 24.10): dictation on
            // the engine that shares the meeting model.
            WhisperEngine.shared.modelID = WhisperEngine.defaultModelID
            settings.dictationEngine = .whisper
            settings.dictationUseNemotronLive = false
        }
        guard !preparation.isRunning, ModelPreparation.activePreparations == 0,
              !preparation.canFinish(settings: settings, includeSpeakers: false) else {
            checkModelsReady()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.preparation.prepare(settings: settings, includeSpeakers: false)
            self.checkModelsReady()
        }
    }

    /// The models step's «Скачать и проверить» after a failure.
    func retryPreparation() { startPreparation() }

    var modelsReady: Bool {
        guard let settings else { return false }
        return preparation.canFinish(settings: settings, includeSpeakers: false)
    }

    private func checkModelsReady() {
        if modelsReady { handle(.modelsReady) }
    }

    // MARK: Keys and locale

    /// The dictation key the copy names; fn when none is set.
    var dictationKey: HotkeyChoice {
        guard let key = settings?.dictationHotkey, key.keyCode != nil else { return .fn }
        return key
    }

    /// The Daisy key; ⌃⌥ when none is set (as «What's New» does).
    var daisyKey: HotkeyChoice {
        guard let key = settings?.voiceNoteHotkey, key.keyCode != nil else { return .ctrlOpt }
        return key
    }

    var styleLocale: String {
        guard let settings else { return "auto" }
        return settings.dictationLocale.isEmpty ? settings.defaultTranscriptionLocale : settings.dictationLocale
    }

    private func applyHotkeys() {
        guard let settings, let session else { return }
        ServiceWiring.applyAllHotkeys(settings: settings, session: session)
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: FloatingPanelController.widgetMoved, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(.widgetMoved) }
        })
        observers.append(center.addObserver(
            forName: DaisyKeyController.noteSaved, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(.noteSaved) }
        })
    }

    // MARK: The bubble

    func refreshBubble() {
        guard isActive, !TestHost.isActive, !isFlying else { return }
        if let content = bubbleContent() {
            TourBubbleCenter.shared.show(content)
        } else {
            TourBubbleCenter.shared.hide()
        }
    }

    /// What Daisy says beside the widget right now; nil on the steps that
    /// live in the window alone (1, 2, 8, 9).
    func bubbleContent() -> TourBubbleContent? {
        typealias Action = TourBubbleContent.Action
        let next = Action(title: OnboardingCopy.text(.next)) { [weak self] in self?.next() }
        let skip = Action(title: OnboardingCopy.text(.skipStep)) { [weak self] in self?.next() }
        func say(_ text: String, primary: Action? = nil, secondary: Action? = nil,
                 waiting: String? = nil, skip: Action? = nil) -> TourBubbleContent {
            TourBubbleContent(text: text, step: tour.number, total: tour.total,
                              primary: primary, secondary: secondary, waiting: waiting, skip: skip)
        }
        let done = tour.isStepDone
        switch tour.step {
        case .widget:
            if done { return say(OnboardingCopy.text(.widgetDone), primary: next) }
            let stay = Action(title: OnboardingCopy.text(.widgetStay)) { [weak self] in self?.handle(.widgetKept) }
            return say(OnboardingCopy.text(.widgetBubble), secondary: stay, skip: skip)
        case .dictation:
            if done { return say(OnboardingCopy.text(.dictationDone), primary: next) }
            if isListening { return say(OnboardingCopy.text(.listening)) }
            return say(OnboardingCopy.dictationBubble(dictationKey),
                       waiting: OnboardingCopy.holdKey(dictationKey), skip: skip)
        case .style:
            if done { return say(OnboardingCopy.text(.styleDone), primary: next) }
            if isListening { return say(OnboardingCopy.text(.listening)) }
            return say(OnboardingCopy.styleBubble(dictationKey),
                       waiting: OnboardingCopy.holdKey(dictationKey), skip: skip)
        case .daisyKey:
            if done { return say(OnboardingCopy.text(.daisyKeyDone), primary: next) }
            if isListening { return say(OnboardingCopy.text(.listening)) }
            return say(OnboardingCopy.daisyKeyBubble(daisyKey),
                       waiting: OnboardingCopy.holdKey(daisyKey), skip: skip)
        case .meeting:
            switch meeting {
            case .choosing:
                return say(OnboardingCopy.text(.meetingLine), skip: skip)
            case .recording(let since):
                let seconds = since.map { Int(Date().timeIntervalSince($0)) } ?? 0
                return say(OnboardingCopy.text(.meetingRecording),
                           waiting: String(format: "%d:%02d", seconds / 60, seconds % 60))
            case .finishing:
                return say(OnboardingCopy.text(.meetingRecording), waiting: "…")
            case .showing:
                // «Дальше» is in the window, under the meeting.
                return say(OnboardingCopy.text(.meetingDone))
            }
        case .hello, .you, .models, .done:
            return nil
        }
    }

    // MARK: Window

    /// The tour allows a narrower window than the shell (560 pt); grow it
    /// to the shell's floor before handing over, so AppKit doesn't snap
    /// it 300 pt in one frame (as FirstRunView did).
    private func growWindowToShellFloor() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        var frame = window.frame
        guard frame.width < MainWindowShellFloor.width || frame.height < MainWindowShellFloor.height else { return }
        // Keep the top edge (windows are y-up): grow right and down.
        let newWidth = max(frame.width, MainWindowShellFloor.width)
        let newHeight = max(frame.height, MainWindowShellFloor.height)
        frame.origin.y -= (newHeight - frame.height)
        frame.size = NSSize(width: newWidth, height: newHeight)
        if let screen = window.screen?.visibleFrame {
            frame.origin.x = max(min(frame.origin.x, screen.maxX - frame.width), screen.minX)
            frame.origin.y = max(min(frame.origin.y, screen.maxY - frame.height), screen.minY)
        }
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: Tests

    /// A tour on its own defaults, for tests: no window, no side effects.
    static func forTesting(defaults: UserDefaults) -> OnboardingTourController {
        let controller = OnboardingTourController()
        controller.defaults = defaults
        return controller
    }

    /// Tests drive the state without the window (`attach` needs one).
    func startForTesting(_ tour: OnboardingTour = OnboardingTour()) {
        self.tour = tour
        isActive = true
    }
}
