//
//  OnboardingCopy.swift
//  Daisy
//
//  Every line Daisy says in the first-run tour (Onboarding 2.0, Egor
//  23–24.10), in one file so the voice stays one. The words are the
//  approved prototype's (`T.ru` / `T.en`, v3) — ported, not rewritten;
//  the tone is daisy-tone-of-voice.md: first person, one thought per
//  bubble, «ты» in Russian.
//
//  Keyed strings (`tour.*`), both languages in Localizable.xcstrings as
//  manual entries. A key per case, so the tests can walk every step's
//  lines in both lprojs without a second list to keep in sync.
//

import Foundation

enum OnboardingCopy {
    /// One line of the tour. The raw value is the catalog key.
    enum Key: String, CaseIterable {
        // Shared
        case next = "tour.next"
        case skipStep = "tour.skipStep"
        case skipTour = "tour.skipTour"
        case again = "tour.again"
        /// «зажми %@» — the bubble's waiting line.
        case holdKey = "tour.holdKey"
        case listening = "tour.listening"
        case allow = "tour.allow"

        // 1 Hello
        case helloTitle = "tour.hello.title"
        case helloLine = "tour.hello.line"
        case go = "tour.hello.go"

        // 2 You
        case youTitle = "tour.you.title"
        case youPlaceholder = "tour.you.placeholder"
        case youPurpose = "tour.you.purpose"
        case youFullTitle = "tour.you.full.title"
        case youFullDetail = "tour.you.full.detail"
        case youDictationTitle = "tour.you.dictation.title"
        case youDictationDetail = "tour.you.dictation.detail"

        // 3 Widget
        case widgetTitle = "tour.widget.title"
        case widgetLine = "tour.widget.line"
        case widgetBubble = "tour.widget.bubble"
        case widgetStay = "tour.widget.stay"
        case widgetDone = "tour.widget.done"

        // 4 Dictation
        case dictationTitle = "tour.dictation.title"
        case dictationPlaceholder = "tour.dictation.placeholder"
        /// «Зажми %@ и скажи…» — %@ is the dictation key.
        case dictationBubble = "tour.dictation.bubble"
        case dictationDone = "tour.dictation.done"
        case dictationKeyLabel = "tour.dictation.keyLabel"
        case keyRightCommand = "tour.dictation.rightCommand"
        case keyRightOption = "tour.dictation.rightOption"

        // 5 Style
        case styleTitle = "tour.style.title"
        /// %@ is the dictation key.
        case stylePlaceholder = "tour.style.placeholder"
        case stylePassage = "tour.style.passage"
        /// %@ is the dictation key.
        case styleBubble = "tour.style.bubble"
        case styleDone = "tour.style.done"
        /// «%1$lld / %2$lld слов до профиля стиля»
        case styleCounter = "tour.style.counter"

        // 6 Daisy key
        case daisyKeyTitle = "tour.daisyKey.title"
        case daisyKeyLine = "tour.daisyKey.line"
        /// %@ is the Daisy key.
        case daisyKeyBubble = "tour.daisyKey.bubble"
        case daisyKeyDone = "tour.daisyKey.done"
        /// Why Accessibility, one line, beside the system's prompt.
        case daisyKeyAccessWhy = "tour.daisyKey.accessWhy"

        // 7 Meeting
        case meetingTitle = "tour.meeting.title"
        case meetingLine = "tour.meeting.line"
        case meetingAccessWhy = "tour.meeting.accessWhy"
        case meetingDemoTitle = "tour.meeting.demo.title"
        case meetingDemoDetail = "tour.meeting.demo.detail"
        case meetingSelfTitle = "tour.meeting.self.title"
        case meetingSelfDetail = "tour.meeting.self.detail"
        case meetingRecording = "tour.meeting.recording"
        case meetingDone = "tour.meeting.done"

        // 8 Models
        case modelsTitle = "tour.models.title"
        case modelsLine = "tour.models.line"
        case modelsStandard = "tour.models.standard"

        // 9 Done
        case doneTitle = "tour.done.title"
        /// %@ is the Daisy key.
        case doneLine = "tour.done.line"
        case doneOpen = "tour.done.open"

        /// The step this line belongs to; nil for the lines every step shares.
        var step: OnboardingTour.Step? {
            let parts = rawValue.split(separator: ".")
            guard parts.count >= 3 else { return nil }
            return OnboardingTour.Step(rawValue: String(parts[1]))
        }

        /// Takes arguments (`%@`, `%lld`).
        var isFormat: Bool {
            switch self {
            case .holdKey, .dictationBubble, .stylePlaceholder, .styleBubble,
                 .styleCounter, .daisyKeyBubble, .doneLine: true
            default: false
            }
        }
    }

    /// The line in the app's language.
    static func text(_ key: Key) -> String {
        String(localized: String.LocalizationValue(stringLiteral: key.rawValue))
    }

    private static func format(_ key: Key, _ args: any CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: args)
    }

    static func keys(for step: OnboardingTour.Step) -> [Key] {
        Key.allCases.filter { $0.step == step }
    }

    // MARK: - Lines with something filled in

    /// The key as the copy writes it: «fn» lower-case as on the keycap,
    /// the rest as Settings shows them.
    static func keyName(_ choice: HotkeyChoice) -> String {
        if choice.isFnOnly { return "fn" }
        if choice.isRightCommand { return text(.keyRightCommand) }
        if choice.isRightOption { return text(.keyRightOption) }
        return choice.displayLabel
    }

    static func holdKey(_ choice: HotkeyChoice) -> String { format(.holdKey, keyName(choice)) }
    static func dictationBubble(_ choice: HotkeyChoice) -> String { format(.dictationBubble, keyName(choice)) }
    static func stylePlaceholder(_ choice: HotkeyChoice) -> String { format(.stylePlaceholder, keyName(choice)) }
    static func styleBubble(_ choice: HotkeyChoice) -> String { format(.styleBubble, keyName(choice)) }
    static func daisyKeyBubble(_ choice: HotkeyChoice) -> String { format(.daisyKeyBubble, keyName(choice)) }
    static func doneLine(_ choice: HotkeyChoice) -> String { format(.doneLine, keyName(choice)) }

    static func styleCounter(words: Int, threshold: Int) -> String {
        format(.styleCounter, Int64(min(words, threshold)), Int64(threshold))
    }

    /// The keys the dictation step offers (Egor 23.10: fn, the right ⌘,
    /// the right ⌥, ⌃Space), each under the name the copy uses.
    static var dictationKeys: [(choice: HotkeyChoice, name: String)] {
        HotkeyChoice.dictationPresets.map { ($0, keyName($0)) }
    }
}
