//
//  OnboardingTourTests.swift
//  DaisyTests
//
//  The first-run tour's state machine (Onboarding 2.0): the steps of each
//  path, the moves between them, which event finishes which step, the
//  resume snapshot, and that every line Daisy says exists in both
//  languages. The window, the widget and the bubble's panel need a real
//  run — see the hand-over notes.
//

import AppKit
import Foundation
import Testing
@testable import Daisy

@Suite("Onboarding tour — steps and moves")
struct OnboardingTourStepsTests {
    typealias Step = OnboardingTour.Step

    @Test("The full path has all nine steps in the prototype's order")
    func fullPath() {
        #expect(OnboardingTour.steps(for: .full) == [
            .hello, .you, .widget, .dictation, .style, .daisyKey, .meeting, .models, .done,
        ])
    }

    @Test("Just dictation skips the meeting and nothing else")
    func dictationPath() {
        #expect(OnboardingTour.steps(for: .dictationOnly) == [
            .hello, .you, .widget, .dictation, .style, .daisyKey, .models, .done,
        ])
    }

    @Test("Next walks the path to «Готово» and stays there")
    func nextWalksThePath() {
        for path in [OnboardingTour.Path.full, .dictationOnly] {
            var tour = OnboardingTour(path: path)
            var seen: [Step] = [tour.step]
            for _ in 0..<12 {
                tour.next()
                if seen.last != tour.step { seen.append(tour.step) }
            }
            #expect(seen == OnboardingTour.steps(for: path))
            #expect(tour.step == .done)
        }
    }

    @Test("Picking «Только диктовка» on «Ты» leaves the meeting out of the walk")
    func choosingThePath() {
        var tour = OnboardingTour()
        tour.next()
        #expect(tour.step == .you)
        tour.choosePath(.dictationOnly)
        #expect(tour.step == .widget)
        #expect(tour.path == .dictationOnly)
        tour.next(); tour.next(); tour.next()
        #expect(tour.step == .daisyKey)
        tour.next()
        #expect(tour.step == .models)
    }

    @Test("The path is picked on «Ты» only")
    func pathOnlyOnYou() {
        var tour = OnboardingTour(step: .dictation, path: .full)
        tour.choosePath(.dictationOnly)
        #expect(tour.path == .full)
        #expect(tour.step == .dictation)
    }

    @Test("«Пропустить тур» goes straight to «Готово» from anywhere")
    func skipTour() {
        for step in Step.allCases {
            var tour = OnboardingTour(step: step, path: .full)
            tour.skipTour()
            #expect(tour.step == .done)
            #expect(!tour.isStepDone)
        }
    }

    @Test("Counter: the place within the path")
    func numbering() {
        #expect(OnboardingTour(step: .widget, path: .full).number == 3)
        #expect(OnboardingTour(step: .done, path: .full).total == 9)
        #expect(OnboardingTour(step: .models, path: .dictationOnly).number == 7)
        #expect(OnboardingTour(step: .models, path: .dictationOnly).total == 8)
    }

    @Test("The keys go live from the dictation step on")
    func keysLive() {
        let live = Step.allCases.filter { OnboardingTour(step: $0).keysLive }
        #expect(live == [.dictation, .style, .daisyKey, .meeting, .models, .done])
    }
}

@Suite("Onboarding tour — completion events")
struct OnboardingTourEventTests {
    typealias Step = OnboardingTour.Step
    typealias Event = OnboardingTour.Event

    static let events: [Event] = [
        .widgetMoved, .widgetKept, .dictationLanded, .passageRead, .noteSaved, .meetingShown, .modelsReady,
    ]

    @Test("Each event finishes its own step and no other")
    func eventsFinishTheirStep() {
        for event in Self.events {
            for step in Step.allCases {
                var tour = OnboardingTour(step: step, path: .full)
                let finished = tour.handle(event)
                let expected = OnboardingTour.step(finishedBy: event) == step
                #expect(finished == expected, "\(event) on \(step)")
                #expect(tour.isStepDone == expected)
                // An event never moves the tour: «Дальше» does.
                #expect(tour.step == step)
            }
        }
    }

    @Test("Which step each event belongs to")
    func eventMap() {
        #expect(OnboardingTour.step(finishedBy: .widgetMoved) == .widget)
        #expect(OnboardingTour.step(finishedBy: .widgetKept) == .widget)
        #expect(OnboardingTour.step(finishedBy: .dictationLanded) == .dictation)
        #expect(OnboardingTour.step(finishedBy: .passageRead) == .style)
        #expect(OnboardingTour.step(finishedBy: .noteSaved) == .daisyKey)
        #expect(OnboardingTour.step(finishedBy: .meetingShown) == .meeting)
        #expect(OnboardingTour.step(finishedBy: .modelsReady) == .models)
    }

    @Test("A step finishes once; moving on resets it")
    func finishOnce() {
        var tour = OnboardingTour(step: .widget, path: .full)
        let moved = tour.handle(.widgetMoved)
        let keptAfter = tour.handle(.widgetKept)
        #expect(moved)
        #expect(!keptAfter)
        tour.next()
        #expect(tour.step == .dictation)
        #expect(!tour.isStepDone)
        // A late drag of the widget doesn't finish the dictation.
        let lateDrag = tour.handle(.widgetMoved)
        #expect(!lateDrag)
        #expect(!tour.isStepDone)
    }
}

@Suite("Onboarding tour — resume")
struct OnboardingTourResumeTests {
    typealias Step = OnboardingTour.Step

    private func defaults() -> UserDefaults {
        let name = "OnboardingTourTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Saved and loaded: the same step and path")
    func roundTrip() {
        for path in [OnboardingTour.Path.full, .dictationOnly] {
            for step in OnboardingTour.steps(for: path) {
                let d = defaults()
                OnboardingTour(step: step, path: path).save(to: d)
                let loaded = OnboardingTour.load(from: d)
                #expect(loaded.step == step)
                #expect(loaded.path == path)
                #expect(!loaded.isStepDone)
            }
        }
    }

    @Test("Skip, next and a quit in between: the tour comes back where it was")
    func skipNextResume() {
        let d = defaults()
        var tour = OnboardingTour()
        tour.next()                    // you
        tour.choosePath(.full)         // widget
        tour.handle(.widgetKept)
        tour.next()                    // dictation
        tour.next()                    // skipped → style
        tour.save(to: d)
        var resumed = OnboardingTour.load(from: d)
        #expect(resumed.step == .style)
        resumed.next()
        #expect(resumed.step == .daisyKey)
        resumed.skipTour()
        resumed.save(to: d)
        #expect(OnboardingTour.load(from: d).step == .done)
    }

    @Test("Nothing saved, or garbage: from the start")
    func nothingSaved() {
        let d = defaults()
        #expect(OnboardingTour.load(from: d) == OnboardingTour())
        d.set("calendar", forKey: AppSettings.k_tourStep)
        d.set("??", forKey: AppSettings.k_tourPath)
        let loaded = OnboardingTour.load(from: d)
        #expect(loaded.step == .hello)
        #expect(loaded.path == .full)
    }

    @Test("A meeting step saved on the dictation path resumes one step earlier")
    func stepNotInPath() {
        #expect(OnboardingTour.resumeStep(savedRaw: "meeting", path: .dictationOnly) == .daisyKey)
        #expect(OnboardingTour.resumeStep(savedRaw: "meeting", path: .full) == .meeting)
    }

    @Test("Clearing removes the snapshot")
    func clear() {
        let d = defaults()
        OnboardingTour(step: .models, path: .dictationOnly).save(to: d)
        d.set(true, forKey: AppSettings.k_tourAccessibilityAsked)
        OnboardingTour.clear(d)
        #expect(d.string(forKey: AppSettings.k_tourStep) == nil)
        #expect(d.string(forKey: AppSettings.k_tourPath) == nil)
        #expect(!d.bool(forKey: AppSettings.k_tourAccessibilityAsked))
    }
}

@Suite("Onboarding tour — the controller's script")
@MainActor
struct OnboardingTourControllerTests {
    private func controller(at step: OnboardingTour.Step) -> OnboardingTourController {
        let name = "OnboardingTourTests.\(UUID().uuidString)"
        let controller = OnboardingTourController.forTesting(defaults: UserDefaults(suiteName: name)!)
        controller.startForTesting(OnboardingTour(step: step, path: .full))
        return controller
    }

    @Test("The tour shows on first run, and on a replay")
    func showsTour() {
        #expect(OnboardingTourController.showsTour(hasShownFirstRun: false, isActive: false))
        #expect(OnboardingTourController.showsTour(hasShownFirstRun: true, isActive: true))
        #expect(!OnboardingTourController.showsTour(hasShownFirstRun: true, isActive: false))
    }

    @Test("A waiting step keeps «Пропустить»; done brings «Дальше»")
    func dictationBubble() {
        let tour = controller(at: .dictation)
        let waiting = tour.bubbleContent()
        #expect(waiting?.waiting != nil)
        #expect(waiting?.skip != nil)
        #expect(waiting?.primary == nil)
        #expect(waiting?.step == 4)
        #expect(waiting?.total == 9)
        tour.handle(.dictationLanded)
        let done = tour.bubbleContent()
        #expect(done?.text == OnboardingCopy.text(.dictationDone))
        #expect(done?.primary != nil)
        #expect(done?.waiting == nil)
        #expect(done?.skip == nil)
    }

    @Test("Completion events move only the step they belong to")
    func controllerEvents() {
        let tour = controller(at: .style)
        tour.handle(.noteSaved)
        tour.handle(.widgetMoved)
        #expect(!tour.tour.isStepDone)
        tour.handle(.passageRead)
        #expect(tour.tour.isStepDone)
        #expect(tour.tour.step == .style)
    }

    @Test("While a key is held the bubble only listens")
    func listening() {
        let tour = controller(at: .daisyKey)
        tour.setListening(true)
        let content = tour.bubbleContent()
        #expect(content?.text == OnboardingCopy.text(.listening))
        #expect(content?.rowActions.isEmpty == true)
        #expect(content?.waiting == nil)
    }

    @Test("The widget step offers «Оставить здесь» beside «Пропустить»")
    func widgetBubble() {
        let tour = controller(at: .widget)
        let content = tour.bubbleContent()
        #expect(content?.text == OnboardingCopy.text(.widgetBubble))
        #expect(content?.rowActions.map(\.action.title) == [
            OnboardingCopy.text(.widgetStay), OnboardingCopy.text(.skipStep),
        ])
    }

    @Test("The window-only steps have no bubble")
    func windowOnlySteps() {
        for step in [OnboardingTour.Step.hello, .you, .models, .done] {
            #expect(controller(at: step).bubbleContent() == nil)
        }
    }

    @Test("A late path pick after «Пропустить тур» changes nothing")
    func latePathPick() {
        let tour = controller(at: .done)
        tour.choosePath(.dictationOnly)
        #expect(tour.tour.step == .done)
        #expect(tour.tour.path == .full)
    }

    @Test("The keys are live only while the tour runs past dictation")
    func keysLive() {
        #expect(!controller(at: .widget).keysLive)
        #expect(controller(at: .dictation).keysLive)
    }
}

@Suite("Onboarding tour — copy")
@MainActor
struct OnboardingCopyTests {
    private static func table(_ language: String) -> Bundle? {
        Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    private static let missing = "\u{0}missing"

    @Test("Every step has its lines")
    func everyStepHasLines() {
        for step in OnboardingTour.Step.allCases {
            #expect(!OnboardingCopy.keys(for: step).isEmpty, "\(step)")
        }
    }

    @Test("Every line exists in English and in Russian, and they differ", arguments: OnboardingCopy.Key.allCases)
    func bothLanguages(_ key: OnboardingCopy.Key) throws {
        let en = try #require(Self.table("en"))
        let ru = try #require(Self.table("ru"))
        let english = en.localizedString(forKey: key.rawValue, value: Self.missing, table: nil)
        let russian = ru.localizedString(forKey: key.rawValue, value: Self.missing, table: nil)
        #expect(english != Self.missing && !english.isEmpty, "\(key.rawValue) has no English")
        #expect(russian != Self.missing && !russian.isEmpty, "\(key.rawValue) has no Russian")
        #expect(english != russian, "\(key.rawValue) is not translated")
    }

    @Test("A line with arguments takes them in both languages", arguments: OnboardingCopy.Key.allCases)
    func formatArguments(_ key: OnboardingCopy.Key) throws {
        let en = try #require(Self.table("en"))
        let ru = try #require(Self.table("ru"))
        func specifiers(_ s: String) -> [String] {
            let regex = try! NSRegularExpression(pattern: "%(\\d+\\$)?(@|lld)")
            return regex.matches(in: s, range: NSRange(s.startIndex..., in: s))
                .map { (s as NSString).substring(with: $0.range).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression) }
                .sorted()
        }
        let english = specifiers(en.localizedString(forKey: key.rawValue, value: nil, table: nil))
        let russian = specifiers(ru.localizedString(forKey: key.rawValue, value: nil, table: nil))
        #expect(english == russian, "\(key.rawValue)")
        #expect(english.isEmpty == !key.isFormat, "\(key.rawValue)")
    }

    @Test("The dictation keys: fn, right ⌘, right ⌥, ⌃Space")
    func dictationKeys() {
        #expect(HotkeyChoice.dictationPresets == [.fn, .rightCommand, .rightOption, .ctrlSpace])
        #expect(OnboardingCopy.keyName(.fn) == "fn")
        #expect(HotkeyChoice.rightOption.isModifierHold)
        #expect(HotkeyChoice.rightOption.isPreset)
    }

    @Test("The right ⌥ alone is the chord; with the left one it isn't")
    func rightOptionReading() {
        let right = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | ModifierChordReading.rightOptionBit)
        let both = NSEvent.ModifierFlags(rawValue: right.rawValue | ModifierChordReading.leftOptionBit)
        let left = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | ModifierChordReading.leftOptionBit)
        #expect(ModifierChordReading.read(right, for: .rightOption) == .exact)
        #expect(ModifierChordReading.read(both, for: .rightOption) == .extra)
        #expect(ModifierChordReading.read(left, for: .rightOption) == .extra)
        #expect(ModifierChordReading.read([.option, .command], for: .rightOption) == .extra)
    }
}

@Suite("Tour bubble — skip beside a waiting line")
@MainActor
struct TourBubbleSkipTests {
    @Test("A waiting step still draws «Пропустить», after the waiting line")
    func skipWhileWaiting() {
        let content = TourBubbleContent(
            text: "Hold fn.", step: 4, total: 9,
            primary: .init(title: "Next", run: {}),
            waiting: "hold fn",
            skip: .init(title: "Skip", run: {})
        )
        let view = TourBubbleView(content: content)
        #expect(view.waitingView != nil)
        #expect(view.pillButtons.map(\.title) == ["Skip"])
        #expect(view.pillButtons.map(\.isPrimary) == [false])
    }

    @Test("Without waiting, «Пропустить» comes last")
    func skipLast() {
        let content = TourBubbleContent(
            text: "Drag me.", step: 3, total: 9,
            secondary: .init(title: "Keep it here", run: {}),
            skip: .init(title: "Skip", run: {})
        )
        let view = TourBubbleView(content: content)
        #expect(view.pillButtons.map(\.title) == ["Keep it here", "Skip"])
    }
}
