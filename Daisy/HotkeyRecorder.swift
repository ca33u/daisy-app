//
//  HotkeyRecorder.swift
//  Daisy
//
//  SwiftUI control that lets the user record an arbitrary keyboard
//  shortcut by pressing it. Uses `NSEvent.addLocalMonitorForEvents`
//  to grab the next keystroke without any focus / first-responder
//  dance.
//
//  The recorder logic lives on a class coordinator (`KeyCaptureBox`)
//  rather than directly inside the View struct. That sidesteps two
//  traps with `addLocalMonitorForEvents` callbacks:
//   1. Swift 6 strict-concurrency on captured `self` of a struct
//      view — mutations to `@Binding` / `@State` via the captured
//      copy can be elided.
//   2. `Task { @MainActor in … }` queues the state update async,
//      so by the time it runs the monitor has already returned and
//      a fast follow-up key event can race the binding update.
//
//  The box uses `DispatchQueue.main.async` for the state hop — it
//  fires on the next runloop tick, reliably, without going through
//  Swift Concurrency scheduling.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HotkeyRecorder: View {
    @Binding var value: HotkeyChoice
    @State private var isListening = false
    @State private var box = KeyCaptureBox()

    var body: some View {
        Button {
            if isListening {
                box.stop()
                isListening = false
            } else {
                box.start(
                    onCapture: { choice in
                        value = choice
                        isListening = false
                    },
                    onCancel: {
                        isListening = false
                    }
                )
                isListening = true
            }
        } label: {
            HStack(spacing: 6) {
                // Keyboard icon shows ONLY while listening — in
                // idle state a leading icon would visually clash
                // with the shortcut label (e.g. "⌘ ⌃⌥⌘R" reads
                // as ⌘⌃⌥⌘R). The capsule itself is the affordance.
                if isListening {
                    Image(systemName: "keyboard")
                        .font(.caption.weight(.medium))
                } else if value.isFnOnly {
                    // Render SF Symbol globe alongside "Fn" text so
                    // users recognise the modern Mac globe key. Plain
                    // string "Fn" would be ambiguous (some users
                    // think Fn means a generic function key).
                    Image(systemName: "globe")
                        .font(.callout.weight(.medium))
                }
                Text(displayLabel)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                if !isListening && value.keyCode != nil {
                    Button {
                        value = .none
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear shortcut")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minWidth: 120)
            .background(
                Capsule(style: .continuous)
                    .fill(isListening
                          ? Color.daisyAccent.opacity(0.18)
                          : Color.daisyBgSidebar)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(isListening
                                  ? Color.daisyAccent
                                  : Color.daisyDivider, lineWidth: 0.7)
            )
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .help(isListening ? String(localized: "Press the shortcut combination…") : String(localized: "Click to change shortcut"))
        .onDisappear { box.stop() }
    }

    private var displayLabel: String {
        if isListening { return String(localized: "Press keys…") }
        if value.keyCode == nil { return String(localized: "Disabled") }
        return value.displayLabel
    }
}

// MARK: - Capture coordinator

/// Class coordinator owning the NSEvent monitor + the user-supplied
/// callbacks. Reference-typed so its identity is stable across view
/// re-renders, and so the monitor closure can capture `self`
/// (a class) without struct-value-capture surprises.
final class KeyCaptureBox {
    /// The box that is currently listening, app-wide. Settings shows
    /// three recorders (Record / Voice note / Dictation), each with
    /// its own box — without this guard two boxes can listen at the
    /// same time (clicking a second "Press keys…" button is a mouse
    /// event, so it never stops the first box). Both then install
    /// NSEvent monitors and the earlier-registered one consumes the
    /// keystroke, writing the combo into ITS binding — user report:
    /// focus visually on Dictation, shortcut landed on Voice note.
    /// `start()` force-cancels the previous listener instead.
    /// MainActor-confined (file compiles with default MainActor
    /// isolation; monitors fire on the main thread).
    private static weak var activeListener: KeyCaptureBox?

    /// A recorder is waiting for a combination: the global shortcuts hold
    /// still, so pressing one to record it doesn't also start it.
    static var isListening: Bool { activeListener != nil }

    private var keyToken: Any?
    private var flagsToken: Any?
    private var onCapture: ((HotkeyChoice) -> Void)?
    private var onCancel: (() -> Void)?

    /// Modifier state tracked via `.flagsChanged` events. macOS 26
    /// observed at user site: keyDown events come through with
    /// modifierFlags == 0x100 (no public modifier set) even when
    /// the user is holding ⌘/⌃/⌥. We track state separately and
    /// merge into the synthetic NSEvent we pass to fromNSEvent.
    private var trackedModifiers: NSEvent.ModifierFlags = []
    /// Every modifier held since they were last all up, device bits
    /// included — what a modifier-only shortcut is recorded from when
    /// they are let go with no key in between.
    private var heldModifiers: NSEvent.ModifierFlags = []
    private var keyDuringModifiers = false
    /// When the first of them went down (system uptime).
    private var modifiersDownSince: TimeInterval?

    deinit {
        if let keyToken { NSEvent.removeMonitor(keyToken) }
        if let flagsToken { NSEvent.removeMonitor(flagsToken) }
    }

    func start(
        onCapture: @escaping (HotkeyChoice) -> Void,
        onCancel: @escaping () -> Void
    ) {
        // Only one recorder may listen at a time — force-cancel the
        // previous one (its view flips back to idle via onCancel).
        if let other = Self.activeListener, other !== self {
            other.forceCancel()
        }

        stop()
        // NB: claim the slot only AFTER stop() — stop() clears the
        // slot when it belongs to self, so the other order would
        // immediately null out the claim.
        Self.activeListener = self
        self.onCapture = onCapture
        self.onCancel = onCancel
        trackedModifiers = []
        heldModifiers = []
        keyDuringModifiers = false
        modifiersDownSince = nil
        // Daisy's own Carbon shortcuts would eat their key before this
        // recorder saw it — and leave only their modifiers to record.
        // Off while listening, so pressing one records it (and moves it).
        HotkeyManager.shared.setCarbonPaused(true)

        // 1. Track modifier press/release via flagsChanged.
        //    Also: capture bare Fn / 🌐 press as a binding. Fn
        //    never emits .keyDown, so the only way to record it
        //    is to detect the rising edge of .function inside the
        //    flagsChanged stream.
        flagsToken = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            let newMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let previouslyHadFn = self.trackedModifiers.contains(.function)
            let nowHasFn = newMods.contains(.function)

            self.trackedModifiers = newMods

            // Modifiers alone (Egor 31.10): pressed and let go with no
            // key — one key is that key on its side («Left ⌥»), several
            // are the chord («⌃⌥»).
            let modifierKeys: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
            if newMods.intersection(modifierKeys).isEmpty {
                let held = self.heldModifiers
                // A key this monitor never saw — one the system or another
                // app took for its own shortcut (⌘Space, ⇧⌘4, Raycast's
                // ⌥Space) — still counts: the system's own «last key»
                // time knows it. Without this ⌘Space recorded «Left ⌘».
                let swallowed = self.modifiersDownSince.map { since in
                    CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
                        < ProcessInfo.processInfo.systemUptime - since
                } ?? false
                let typed = self.keyDuringModifiers || swallowed
                self.heldModifiers = []
                self.keyDuringModifiers = false
                self.modifiersDownSince = nil
                if !typed, !held.contains(.function), let choice = HotkeyChoice.fromModifiers(held) {
                    self.finish(with: choice)
                    // Passed on: the shortcuts' own monitors want to see
                    // the modifiers go up.
                    return event
                }
            } else {
                if self.heldModifiers.isEmpty { self.modifiersDownSince = event.timestamp }
                self.heldModifiers.formUnion(event.modifierFlags)
            }

            // Fn rising edge (up → down) and NO other strong modifier
            // present means "user pressed Fn alone to record it as
            // the hotkey". Strong modifier = ⌘ / ⌃ / ⌥ — those would
            // mean the user is recording a combo (e.g. ⌥Fn), which
            // we don't support since Carbon can't register such a
            // combo either; only bare Fn is a valid hotkey choice.
            if nowHasFn && !previouslyHadFn {
                let otherStrong: NSEvent.ModifierFlags = [.command, .control, .option]
                if newMods.intersection(otherStrong).isEmpty {
                    self.finish(with: .fn)
                    return nil
                }
            }
            return event
        }

        // 2. Catch the actual letter/key press.
        keyToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event: event)
        }
    }

    /// A combination is in: stop listening (until now the box went on
    /// listening after a capture, and the next key pressed in Settings
    /// re-bound the row behind its back) and hand it over.
    private func finish(with choice: HotkeyChoice) {
        let capture = onCapture
        stop()
        DispatchQueue.main.async { capture?(choice) }
    }

    /// Stop listening AND notify the owning recorder so its
    /// `isListening` state flips back to idle. Used when another
    /// recorder starts listening and takes over.
    private func forceCancel() {
        let cancel = onCancel
        stop()
        DispatchQueue.main.async { cancel?() }
    }

    func stop() {
        if let keyToken {
            NSEvent.removeMonitor(keyToken)
            self.keyToken = nil
        }
        if let flagsToken {
            NSEvent.removeMonitor(flagsToken)
            self.flagsToken = nil
        }
        onCapture = nil
        onCancel = nil
        trackedModifiers = []
        heldModifiers = []
        keyDuringModifiers = false
        modifiersDownSince = nil
        if Self.activeListener === self {
            Self.activeListener = nil
            HotkeyManager.shared.setCarbonPaused(false)
        }
    }

    /// Returns `nil` to consume the event (so it doesn't propagate
    /// to menu key-equivalents or the focused control), or the
    /// event itself to pass it through unchanged.
    private func handle(event: NSEvent) -> NSEvent? {
        // Merge event-reported modifiers with our flagsChanged-
        // tracked state — on some setups (observed macOS 26 +
        // certain keyboards) keyDown events arrive with no public
        // modifier bits even though the user is holding ⌘/⌃/⌥.
        let eventMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let effectiveMods = eventMods.union(trackedModifiers)

        keyDuringModifiers = true

        if event.keyCode == UInt16(kVK_Escape), effectiveMods.intersection([.control, .option, .shift, .command]).isEmpty {
            let cancel = onCancel
            stop()
            DispatchQueue.main.async { cancel?() }
            return nil
        }

        // Any key, any modifiers (Egor 31.10) — a bare letter or ⌘C
        // included. Settings warns under the recorder what that means
        // (`HotkeyWarnings`) instead of refusing it.
        finish(with: HotkeyChoice.fromKeyCode(UInt16(event.keyCode), modifierFlags: effectiveMods))
        return nil
    }
}
