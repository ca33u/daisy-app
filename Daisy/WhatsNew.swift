//
//  WhatsNew.swift
//  Daisy
//
//  «What's New in Daisy» (Egor 22.10): a window that opens once after an
//  update and walks through the Daisy key in three animated scenes — a
//  note filed into its project, a hold that says what to do, a silent
//  hold that rewrites the selection. Drawn here rather than played from
//  a video, so it speaks both languages, shows the person's own key and
//  follows the theme; the flower is the widget's own shape and timings.
//  The motion was agreed on a browser prototype first.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - When it opens

enum WhatsNew {
    /// Bump with each new edition: the window opens once per edition for
    /// anyone who had Daisy before it. A fresh install sees the onboarding
    /// instead and is marked as having seen this one.
    // "-b": 1.0.8.37–38 marked the first edition seen as it opened, then
    // crashed drawing it (22.10) — everyone who updated gets it once more.
    // "-c": notes became a hold and the tap the layout fix (Egor 23.10).
    // "-d": the last scene says where the new tour is — someone who
    // updates never sees it otherwise (Onboarding 2.0, Egor 24.10).
    nonisolated static let edition = "daisy-key-2026-10-d"
    nonisolated static let seenKey = "daisy.whatsNew.seenEdition"

    static func shouldOpen(hasShownFirstRun: Bool, defaults: UserDefaults = .standard) -> Bool {
        hasShownFirstRun && defaults.string(forKey: seenKey) != edition
    }

    static func markSeen(defaults: UserDefaults = .standard) {
        defaults.set(edition, forKey: seenKey)
    }
}

/// Opens the window after an update, once the process-tap question (a
/// sheet of its own) is out of the way, and whenever the Help menu asks.
struct WhatsNewPresenter: ViewModifier {
    let settings: AppSettings
    let tapPermissionShowing: Bool
    @Bindable private var nav = AppNavigation.shared

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $nav.showsWhatsNew) {
                WhatsNewSheet(settings: settings)
            }
            .task(id: settings.hasShownFirstRun) {
                // The process-tap question goes first: when it will be asked,
                // this opens once its sheet closes (below). Read live — the
                // modifier's own copy is from before MainView decided.
                guard !TestHost.isActive,
                      WhatsNew.shouldOpen(hasShownFirstRun: settings.hasShownFirstRun),
                      !ProcessTapPermission.shouldAsk else { return }
                // Let the window settle first.
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                nav.showsWhatsNew = true
            }
            .onChange(of: tapPermissionShowing) { _, showing in
                if !showing, !TestHost.isActive, WhatsNew.shouldOpen(hasShownFirstRun: settings.hasShownFirstRun) {
                    nav.showsWhatsNew = true
                }
            }
    }
}

// MARK: - The window

struct WhatsNewSheet: View {
    let settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scene = 0
    @State private var startedAt = Date()

    private static let sceneCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            illustration
                .padding([.horizontal, .top], 20)
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "\(scene + 1) of \(Self.sceneCount)"))
                    .font(.caption.weight(.semibold))
                    // The petals' lavender, a step deeper on white to be read.
                    .foregroundStyle(Color(light: Color(hex: 0x6B4FD8), dark: Color.daisyMarkDaisyPetalTo))
                Text(title)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text(text)
                    .foregroundStyle(Color.daisyTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // One height for all three steps, so Next stays under the pointer.
            .frame(minHeight: 112, alignment: .topLeading)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            if let setup {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(Color.daisyWarning)
                    Text(setup)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open Settings") {
                        AppNavigation.shared.openInSettings(.shortcuts, row: .daisyKey)
                        dismiss()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
            }
            if scene == Self.sceneCount - 1 {
                // The tour came with this update, and only a fresh install
                // walks into it by itself.
                HStack(spacing: 10) {
                    Image(systemName: "figure.walk")
                        .foregroundStyle(.secondary)
                    Text(ContextTips.Copy.whatsNewTour)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open") {
                        dismiss()
                        OnboardingTourController.shared.restart(settings: settings)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
            }
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<Self.sceneCount, id: \.self) { i in
                        Circle()
                            .fill(i == scene ? Color.primary : Color.daisyDivider)
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityHidden(true)
                Spacer()
                // On the last step Done says the same.
                if scene < Self.sceneCount - 1 {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                if scene > 0 {
                    Button("Back") { go(scene - 1) }
                }
                Button(scene == Self.sceneCount - 1 ? String(localized: "Done") : String(localized: "Next")) {
                    if scene == Self.sceneCount - 1 { dismiss() } else { go(scene + 1) }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(24)
        }
        .frame(width: 640)
        .background(Color.daisyBgPrimary)
        .onAppear {
            WhatsNew.markSeen()
            // This window introduces the Daisy key; the one-time bubble
            // saying the same is no longer needed.
            UserDefaults.standard.set(true, forKey: DaisyKeyController.introducedKey)
            startedAt = Date()
        }
    }

    private func go(_ next: Int) {
        scene = next
        startedAt = Date()
    }

    private var key: HotkeyChoice {
        settings.voiceNoteHotkey.keyCode == nil ? .ctrlOpt : settings.voiceNoteHotkey
    }

    /// What stands between the person and the key shown: none assigned
    /// (an update keeps an unassigned key unassigned — the scenes then
    /// suggest ⌃⌥), or the hold without the permission it needs.
    private var setup: String? {
        if settings.voiceNoteHotkey.keyCode == nil {
            return String(localized: "You don’t have a Daisy key yet — pick one in Settings. ⌃⌥ is the simplest.")
        }
        if !DaisyKeyController.canHold {
            // Without it the key isn't registered at all — as Settings says.
            return String(localized: "The Daisy key needs Accessibility — until it’s granted, it does nothing")
        }
        return nil
    }

    private var title: String {
        switch scene {
        case 0: String(localized: "Hold and say “note” — it goes straight into its project")
        case 1: String(localized: "Hold and say what to do")
        default: String(localized: "Hold without a word to rewrite in your voice")
        }
    }

    private var text: String {
        let k = key.displayLabel
        switch scene {
        case 0: return String(localized: "Hold \(k) and say “note to project Landing: …” — let go, and the note is there. End with “and summarize” for a summary too. Without a project it lands in Notes.")
        case 1: return String(localized: "Hold \(k) and say “write a reply…”, “translate”, “make a prompt for…”. Let go, and Daisy does it right where you are. A tap fixes the keyboard layout.")
        default: return String(localized: "Select some text, hold \(k) and say nothing. Daisy rewrites the selection the way you write.")
        }
    }

    private var illustration: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { context in
            let script = WhatsNewScript.all[scene]
            // Under Reduce Motion the scene holds on its outcome.
            let t = reduceMotion
                ? script.still
                : context.date.timeIntervalSince(startedAt).truncatingRemainder(dividingBy: script.duration)
            WhatsNewStage(scene: scene, t: t, caps: WhatsNewKeycaps.caps(for: key))
        }
        .frame(width: 600, height: 330)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // The heading and text below say it; an animation read aloud says nothing more.
        .accessibilityHidden(true)
    }
}

// MARK: - The scripts

/// One scene's timeline, in seconds: when the key is down, when words
/// are said, and how long before it starts over. The same numbers as the
/// prototype Egor approved.
struct WhatsNewScript {
    let duration: TimeInterval
    /// The still shown under Reduce Motion.
    let still: TimeInterval
    let keyDown: [ClosedRange<TimeInterval>]
    let speech: ClosedRange<TimeInterval>?

    static let all = [
        WhatsNewScript(duration: 10, still: 9, keyDown: [0.6...7.5], speech: 1.2...6.8),
        WhatsNewScript(duration: 12, still: 10, keyDown: [0.6...4.6], speech: 1.15...4.3),
        WhatsNewScript(duration: 10, still: 8.5, keyDown: [1.8...3.4], speech: nil),
    ]

    func isDown(_ t: TimeInterval) -> Bool { keyDown.contains { $0.contains(t) } }
    func speaking(_ t: TimeInterval) -> Bool { speech?.contains(t) ?? false }
}

private func progress(_ t: TimeInterval, _ from: TimeInterval, _ to: TimeInterval) -> Double {
    min(1, max(0, (t - from) / (to - from)))
}

private func firstWords(_ text: String, _ p: Double) -> String {
    let words = text.split(separator: " ")
    return words.prefix(Int((Double(words.count) * p).rounded())).joined(separator: " ")
}

private func firstChars(_ text: String, _ p: Double) -> String {
    String(text.prefix(Int((Double(text.count) * p).rounded())))
}

/// The widget's «done» flash: 0.08 s up, then back.
private func flash(_ t: TimeInterval, at: TimeInterval) -> Double {
    let d = t - at
    guard d >= 0, d <= 0.7 else { return 0 }
    return d < 0.08 ? d / 0.08 : exp(-(d - 0.08) / 0.22)
}

/// Understanding turns the flower once per 4.8 s, as the widget does.
private func spin(_ t: TimeInterval, from: TimeInterval) -> Double { max(0, t - from) * 360 / 4.8 }

// MARK: - A scene at one moment

struct WhatsNewStage: View {
    let scene: Int
    let t: TimeInterval
    let caps: [WhatsNewKeycaps.Cap]

    var body: some View {
        let script = WhatsNewScript.all[scene]
        ZStack {
            LinearGradient(colors: [Color.daisyBgSidebar, Color.daisyDivider], startPoint: .topLeading, endPoint: .bottomTrailing)
            content
                .frame(width: 410, height: 236)
                .position(x: 36 + 205, y: 26 + 118)
            if let words = said {
                speechBubble(words)
                    .position(x: 300, y: 330 - 112)
            }
            // The pill beside the flower, laid out rather than measured:
            // measuring the timer with NSString crashed 1.0.8.37–38 (a nil
            // value in CoreText's attribute copy, 22.10).
            HStack(spacing: 8) {
                if let pill {
                    WhatsNewPill(text: pill.text, detail: pill.detail)
                        .offset(y: 1)
                }
                WhatsNewFlower(look: look, size: 58)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 30)
            .padding(.bottom, 26)
            WhatsNewKeycaps(caps: caps, down: script.isDown(t))
                .position(x: 300, y: 330 - 44)
        }
        .frame(width: 600, height: 330)
    }

    // What the person is heard saying, word by word, then fading.
    private var said: String? {
        let script = WhatsNewScript.all[scene]
        guard let speech = script.speech, t >= speech.lowerBound - 0.15, t <= speech.upperBound + 0.9 else { return nil }
        let words = firstWords(spoken, progress(t, speech.lowerBound, speech.upperBound))
        return words.isEmpty ? "…" : words
    }

    private var spoken: String {
        switch scene {
        case 0: String(localized: "Note to project Landing: show Daisy writing an email on the first screen. Check with Masha by Friday.")
        default: String(localized: "Write a reply: let’s do Thursday at three, I’ll send the link.")
        }
    }

    private func speechBubble(_ words: String) -> some View {
        let script = WhatsNewScript.all[scene]
        let end = script.speech?.upperBound ?? 0
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "mic")
                .foregroundStyle(Color.daisyMarkDaisyPetalTo)
            Text(String(localized: "“\(words)”"))
                .italic()
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Color(white: 0.96))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 330, alignment: .leading)
        .background(Color(red: 28 / 255, green: 26 / 255, blue: 23 / 255).opacity(0.88), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .opacity(t > end + 0.5 ? 1 - progress(t, end + 0.5, end + 0.9) : 1)
    }

    // MARK: The flower's look for this moment

    private var look: WhatsNewFlower.Look {
        let script = WhatsNewScript.all[scene]
        switch scene {
        case 0:
            if t >= 0.8 && t < 7.6 { return .init(petals: .voice(loud: script.speaking(t) ? 1 : 0, t: t), center: .daisyMarkVoiceNote, daisy: false) }
            if t >= 7.6 && t < 8.4 { return .init(petals: .full, center: .daisyMarkVoiceNote, daisy: false, rotation: spin(t, from: 7.6)) }
            if t >= 8.4 { return .init(petals: .full, center: .daisyMarkVoiceNote, daisy: true, flash: flash(t, at: 8.4)) }
            return .idle
        case 1:
            if t >= 0.6 && t < 4.6 { return .init(petals: .voice(loud: script.speaking(t) ? 0.95 : 0.05, t: t)) }
            if t >= 4.6 && t < 5.95 { return .init(petals: .full, rotation: spin(t, from: 4.75)) }
            if t >= 5.95 && t < 8.8 { return .init(petals: .writing(since: t - 5.95), rotation: spin(5.95, from: 4.75)) }
            if t >= 8.8 { return .init(petals: .full, flash: flash(t, at: 8.8)) }
            return .idle
        default:
            if t >= 1.8 && t < 3.4 { return .init(petals: .voice(loud: 0, t: t)) }
            if t >= 3.4 && t < 4.55 { return .init(petals: .full, rotation: spin(t, from: 3.55)) }
            if t >= 4.55 && t < 7.1 { return .init(petals: .writing(since: t - 4.55), rotation: spin(4.55, from: 3.55)) }
            if t >= 7.1 { return .init(petals: .full, flash: flash(t, at: 7.1)) }
            return .idle
        }
    }

    /// The widget's pill: what it says, and an optional timer.
    private var pill: (text: String, detail: String?)? {
        let text: String?
        var detail: String?
        switch scene {
        case 0:
            if t >= 0.8 && t < 7.6 {
                text = String(localized: "Note")
                detail = String(format: "0:%02d", Int(max(0, t - 0.8)))
            } else if t >= 7.6 && t < 8.4 { text = String(localized: "Saving…") }
            else if t >= 8.4 { text = String(localized: "In “Landing”") }
            else { text = nil }
        case 1:
            if t >= 0.95 && t < 4.6 { text = String(localized: "Listening") }
            else if t >= 4.6 && t < 5.95 { text = String(localized: "Understanding…") }
            else if t >= 5.95 && t < 8.8 { text = String(localized: "Writing the reply…") }
            else if t >= 8.8 && t < 11.2 { text = String(localized: "Done") }
            else { text = nil }
        default:
            if t >= 2.15 && t < 3.4 { text = String(localized: "Listening · silent") }
            else if t >= 3.4 && t < 4.55 { text = String(localized: "Understanding…") }
            else if t >= 4.55 && t < 7.1 { text = String(localized: "Rewriting…") }
            else if t >= 7.1 && t < 9.4 { text = String(localized: "Done") }
            else { text = nil }
        }
        guard let text else { return nil }
        return (text, detail)
    }

    // MARK: The app window in the scene

    @ViewBuilder private var content: some View {
        switch scene {
        case 0: notesWindow
        case 1: mailWindow
        default: editorWindow
        }
    }

    private var caret: Text {
        Int(t * 2.2) % 2 == 0 ? Text(verbatim: "|").foregroundStyle(Color.daisyMarkDaisyPetalTo) : Text(verbatim: "")
    }

    private var notesWindow: some View {
        let recording = t >= 0.8 && t < 7.6
        let saved = t >= 8.4
        let speech = WhatsNewScript.all[0].speech!
        let live = firstWords(spoken, progress(t, speech.lowerBound + 0.25, speech.upperBound + 0.35))
        return WhatsNewMockWindow(title: String(localized: "Notes")) {
            HStack {
                Text(saved ? String(localized: "Landing first screen") : String(localized: "New note"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if t >= 0.8 {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(saved ? Color.daisyMarkDaisyCenter : Color.daisyMarkVoiceNote)
                            .frame(width: 6, height: 6)
                            .opacity(recording && Int(t * 1.6) % 2 == 1 ? 0.35 : 1)
                        Text(saved ? String(localized: "Landing") : String(format: "0:%02d", Int(max(0, min(t, 7.6) - 0.8))))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.daisyTextSecondary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.daisyBgSidebar, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.daisyDivider))
                }
            }
            (Text(t < 0.8 ? "" : live) + (recording ? caret : Text(verbatim: "")))
                .font(.system(size: 13))
                .foregroundStyle(saved ? Color.primary : Color.daisyTextSecondary)
                .lineSpacing(3)
        }
    }

    private var mailWindow: some View {
        let typed = firstChars(String(localized: "Hi Anna! Thursday at 3 pm works — I’ll send the call link the day before."), progress(t, 6.1, 8.7))
        return WhatsNewMockWindow(title: String(localized: "Mail")) {
            HStack(spacing: 8) {
                Text(String(localized: "AK"))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(red: 0.29, green: 0.12, blue: 0.08))
                    .frame(width: 22, height: 22)
                    .background(Color.daisyMarkMeeting.opacity(0.55), in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(String(localized: "Anna Kovaleva")).font(.system(size: 12, weight: .semibold))
                    Text(String(localized: "Mockups · 10:42")).font(.system(size: 10)).foregroundStyle(Color.daisyTextTertiary)
                }
            }
            Text(String(localized: "Hi! Can we get on a call about the mockups this week?"))
                .font(.system(size: 12))
            Divider()
            Group {
                if t < 6.1 {
                    Text(String(localized: "Reply…")).foregroundStyle(Color.daisyTextTertiary)
                } else {
                    Text(typed) + (t < 8.8 ? caret : Text(verbatim: ""))
                }
            }
            .font(.system(size: 12))
            .lineSpacing(2)
        }
    }

    private var editorWindow: some View {
        let rough = String(localized: "so we looked at the metrics and its all fine but conversion dropped on mobile gotta check whats up with the form")
        let clean = String(localized: "We looked at the metrics: overall it’s fine, but mobile conversion dropped. We need to check the form.")
        var body = AttributedString()
        if t < 4.7 {
            let n = Int((Double(rough.count) * progress(t, 0.3, 1.4)).rounded())
            var selected = AttributedString(String(rough.prefix(n)))
            selected.backgroundColor = Color.daisyMarkDaisyPetalTo.opacity(0.32)
            body = selected + AttributedString(String(rough.dropFirst(n)))
        } else {
            var typed = AttributedString(firstChars(clean, progress(t, 4.75, 7.0)))
            if t < 7.1 { typed.backgroundColor = Color.daisyMarkDaisyPetalTo.opacity(0.32) }
            body = typed
        }
        return WhatsNewMockWindow(title: String(localized: "Notes")) {
            Text(String(localized: "Week in review"))
                .font(.system(size: 14, weight: .semibold))
            (Text(body) + (t >= 4.7 && t < 7.1 ? caret : Text(verbatim: "")))
                .font(.system(size: 13))
                .lineSpacing(4)
                .opacity(t > 4.55 && t < 4.7 ? 1 - progress(t, 4.55, 4.7) : 1)
        }
    }
}

// MARK: - Parts

private struct WhatsNewMockWindow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.daisyDivider).frame(width: 8, height: 8) }
                Spacer()
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.daisyTextSecondary)
                Spacer()
                Color.clear.frame(width: 34, height: 1)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Color.daisyBgSidebar)
            Divider()
            VStack(alignment: .leading, spacing: 8) { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        // The shadow on the window's shape only: on the whole stack it
        // shadowed every line of text too.
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.daisyBgPrimary)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        )
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.daisyDivider))
    }
}

private struct WhatsNewPill: View {
    let text: String
    let detail: String?

    var body: some View {
        HStack(spacing: 7) {
            Text(text).font(.system(size: 12, weight: .medium))
            if let detail {
                // Tabular digits, not the monospaced design: its font is what
                // crashed 1.0.8.37–38 (Sentry DAISY-MAC-1).
                Text(detail).font(.system(size: 11).monospacedDigit()).foregroundStyle(Color(white: 0.75))
            }
        }
        .foregroundStyle(Color(white: 0.96))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(
            Capsule()
                .fill(Color(red: 28 / 255, green: 26 / 255, blue: 23 / 255))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        )
        // Seen against a dark backdrop too.
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .fixedSize()
    }
}

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
        if choice.isRightCommand { return [Cap(glyph: "⌘", name: String(localized: "right command"))] }
        if choice.isRightOption { return [Cap(glyph: "⌥", name: String(localized: "right option"))] }
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

/// The widget's flower on its own: eight petals of the widget's shape,
/// white → lavender while the Daisy key works, the voice note's blue
/// centre for a note.
struct WhatsNewFlower: View {
    enum Petals: Equatable {
        case full
        case voice(loud: Double, t: TimeInterval)
        case writing(since: TimeInterval)
    }

    struct Look: Equatable {
        var petals: Petals = .full
        var center: Color = .daisyMarkDaisyCenter
        var daisy = true
        var rotation: Double = 0
        var flash: Double = 0

        static let idle = Look(petals: .full, center: .white, daisy: false)
    }

    let look: Look
    let size: CGFloat

    private static let count = 8

    var body: some View {
        // The widget's proportions (DaisyWidget: a 42-unit canvas).
        let unit = size / 42.075
        let maxLength = size * 0.278
        let width = size * DaisyPetalShape.boxWidth / 100
        let center = size * 0.21
        let gap = size * 0.037
        ZStack {
            Circle().fill(Color(red: 28 / 255, green: 26 / 255, blue: 23 / 255))
            ZStack {
                ForEach(0..<Self.count, id: \.self) { i in
                    let scale = scale(i)
                    DaisyPetalShape()
                        .fill(look.daisy
                              ? AnyShapeStyle(LinearGradient(colors: [.daisyMarkDaisyPetalFrom, .daisyMarkDaisyPetalTo], startPoint: .bottom, endPoint: .top))
                              : AnyShapeStyle(Color.daisyMarkPetal))
                        .frame(width: width * scale.width, height: maxLength * scale.length)
                        .offset(y: -(center / 2 + maxLength * scale.length / 2 + gap))
                        .rotationEffect(.degrees(Double(i) * 360 / Double(Self.count)))
                }
            }
            .brightness(look.flash * 0.35)
            .rotationEffect(.degrees(look.rotation))
            .scaleEffect(0.85)
            Circle()
                .fill(look.center)
                .frame(width: center, height: center)
                .shadow(color: look.center.opacity(0.55), radius: 2.5 * unit)
                .scaleEffect(0.85)
        }
        .frame(width: size, height: size)
    }

    /// Length and width against a full petal. A voice moves each petal
    /// between half and full, symmetric as the widget's bands are.
    private func scale(_ i: Int) -> (length: CGFloat, width: CGFloat) {
        switch look.petals {
        case .full:
            return (1, 1)
        case .writing(let since):
            let g = DaisyWidget.writingGrowth(petal: i, count: Self.count, elapsed: since)
            return (g, g)
        case .voice(let loud, let t):
            let band = Double(min(i, Self.count - i))
            let s = 0.5 + 0.5 * sin(t * 8.3 + band * 1.7) * sin(t * 3.1 + band * 0.9 + 1.3)
            let syllable = 0.55 + 0.45 * abs(sin(t * 5.2 + band * 0.4))
            let amp = min(1, max(0, 0.12 + loud * (0.25 + 0.75 * s * syllable)))
            return (0.5 + 0.5 * CGFloat(amp), 1)
        }
    }
}
