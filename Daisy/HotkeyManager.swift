//
//  HotkeyManager.swift
//  Daisy
//
//  Global hotkey for start / stop recording. Uses Carbon's
//  `RegisterEventHotKey` — modern Swift has no first-party replacement,
//  and Carbon hotkeys work without requiring Accessibility / Input
//  Monitoring permissions (unlike `CGEventTap` / `NSEvent` global
//  monitors). The trade-off is a small amount of `@convention(c)`
//  glue to bridge the system callback back into Swift.
//
//  Usage:
//      HotkeyManager.shared.register(choice: .ctrlOptCmdR) {
//          Task { await session.toggleByHotkey() }
//      }
//
//  Call `unregister()` to disable. Calling `register` again replaces
//  any previous registration.
//

import AppKit
import Carbon.HIToolbox
import Foundation
import os

// MARK: - HotkeyChoice (struct, supports presets + custom)

/// A keyboard shortcut. Used to be a fixed enum of presets; now a
/// struct so users can record any combination via Settings →
/// HotkeyRecorder.
///
/// `keyCode == nil` means "disabled" (no global shortcut registered).
struct HotkeyChoice: Hashable, Codable, Sendable, Identifiable {
    /// Carbon virtual keycode (`kVK_*` from `HIToolbox.Events`).
    /// `nil` for `.none` (disabled).
    let keyCode: UInt32?
    /// Carbon modifier flags bitmask. `0` is legal (e.g. F-keys).
    let modifiers: UInt32?
    /// Human-readable string like "⌃⌥⌘R" — used as picker label and
    /// `id`. For custom combos this is computed from keyCode + mods.
    let label: String

    var id: String { label }

    // MARK: Presets

    static let none = HotkeyChoice(keyCode: nil, modifiers: nil, label: "Disabled")
    static let ctrlOptCmdR = HotkeyChoice(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: UInt32(controlKey | optionKey | cmdKey),
        label: "⌃⌥⌘R"
    )
    static let ctrlOptCmdD = HotkeyChoice(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(controlKey | optionKey | cmdKey),
        label: "⌃⌥⌘D"
    )
    static let ctrlOptSpace = HotkeyChoice(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey | optionKey),
        label: "⌃⌥Space"
    )
    static let shiftCmdR = HotkeyChoice(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: UInt32(shiftKey | cmdKey),
        label: "⇧⌘R"
    )
    // V-presets for the paste-flavoured action (re-paste last
    // dictation). V is the paste mnemonic users already know from
    // ⌘V / Wispr Flow; R and D read as "record"/"dictate" and are
    // wrong hints for this row. ⇧⌘V is deliberately absent — many
    // apps bind it to "Paste and Match Style".
    static let ctrlOptCmdV = HotkeyChoice(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(controlKey | optionKey | cmdKey),
        label: "⌃⌥⌘V"
    )
    static let ctrlOptV = HotkeyChoice(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(controlKey | optionKey),
        label: "⌃⌥V"
    )
    static let f5 = HotkeyChoice(
        keyCode: UInt32(kVK_F5),
        modifiers: 0,
        label: "F5"
    )
    /// Fn / globe key. Bare, no modifiers. Carbon
    /// RegisterEventHotKey can't bind this — Fn is a modifier flag,
    /// not a regular key event — so `HotkeyManager` routes it
    /// through `NSEvent.addGlobalMonitorForEvents(.flagsChanged)`
    /// instead, which requires Input Monitoring permission. macOS
    /// will prompt the first time the user binds Fn.
    ///
    /// Label is plain "Fn" — UI layers render the SF Symbol
    /// `globe` icon next to it (see `isFnOnly` consumers in
    /// SettingsView + HotkeyRecorder).
    static let fn = HotkeyChoice(
        keyCode: UInt32(kVK_Function),
        modifiers: 0,
        label: "Fn"
    )

    /// Preset list shown in Settings picker. Custom recorder lives
    /// alongside — see `HotkeyRecorder` view.
    static let allPresets: [HotkeyChoice] = [.none, .ctrlOptCmdR, .ctrlOptCmdD, .ctrlOptSpace, .shiftCmdR, .f5, .fn]

    /// Paste-flavoured preset list — used by the "Paste my last
    /// dictation" row instead of `allPresets`.
    static let pastePresets: [HotkeyChoice] = [.none, .ctrlOptCmdV, .ctrlOptV, .fn]

    /// True when this choice is the bare Fn / globe key — handled
    /// by the NSEvent global-monitor path, not Carbon. Read by
    /// `HotkeyManager.register` to pick the right registration
    /// strategy.
    var isFnOnly: Bool {
        keyCode == UInt32(kVK_Function) && (modifiers ?? 0) == 0
    }

    /// Whether this choice is one of the canonical presets above.
    /// UI uses this to mark presets in the menu (vs custom recordings).
    var isPreset: Bool {
        Self.allPresets.contains(self) || Self.pastePresets.contains(self)
    }

    // MARK: Custom recording

    /// Build a HotkeyChoice from an NSEvent.keyDown event. Used by
    /// HotkeyRecorder to convert captured keys into a choice. Returns
    /// nil if the event has no modifiers (a bare letter as a global
    /// hotkey would hijack typing).
    static func fromNSEvent(_ event: NSEvent) -> HotkeyChoice? {
        fromKeyCode(event.keyCode, modifierFlags: event.modifierFlags)
    }

    /// Same shape as `fromNSEvent` but takes raw keyCode + flags so
    /// callers can override the modifier source. Used by
    /// HotkeyRecorder which tracks modifiers via `.flagsChanged`
    /// separately — on some macOS / keyboard combos the keyDown
    /// event's `modifierFlags` arrive empty even when the user is
    /// holding ⌘/⌃/⌥.
    ///
    /// Accepted:
    ///   • any key + at least one of ⌃ / ⌥ (⌘ may ride along, e.g.
    ///     ⌃⌥⌘R, but never on its own — see below)
    ///   • function keys (F1–F20) on their own (rarely typed,
    ///     no risk of hijacking ordinary input)
    ///
    /// ⌘ alone (with or without ⇧) is NOT accepted as a global hotkey:
    /// a bare ⌘+letter is indistinguishable from a system or app
    /// shortcut, and Carbon's `RegisterEventHotKey` is happy to
    /// register one anyway — it shadows Copy/Paste/Cut/Select
    /// All/Undo/Save/Close/Quit/New/... everywhere on the Mac for as
    /// long as Daisy runs. One did get recorded as "rewrite in my
    /// voice" during testing: ⌘C, which ate Copy system-wide.
    static func fromKeyCode(_ keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> HotkeyChoice? {
        let carbonKey = UInt32(keyCode)
        let carbonMods = nsToCarbonModifiers(modifierFlags)
        let strongMods: UInt32 = UInt32(controlKey | optionKey)
        let hasStrongModifier = (carbonMods & strongMods) != 0
        let isBareFunctionKey = Self.functionKeyCodes.contains(carbonKey) && carbonMods == 0
        guard hasStrongModifier || isBareFunctionKey else { return nil }
        let label = humanLabel(keyCode: carbonKey, modifiers: carbonMods)
        return HotkeyChoice(keyCode: carbonKey, modifiers: carbonMods, label: label)
    }

    /// kVK_F1 … kVK_F20 — virtual keycodes for the function row.
    /// Allowed as bare hotkeys because nobody types them as
    /// ordinary characters, so binding e.g. F5 as Daisy's toggle
    /// won't hijack normal typing the way bare "K" would.
    private static let functionKeyCodes: Set<UInt32> = [
        UInt32(kVK_F1),  UInt32(kVK_F2),  UInt32(kVK_F3),  UInt32(kVK_F4),
        UInt32(kVK_F5),  UInt32(kVK_F6),  UInt32(kVK_F7),  UInt32(kVK_F8),
        UInt32(kVK_F9),  UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
        UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
        UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20),
    ]

    /// NSEvent.ModifierFlags → Carbon modifier bitmask.
    private static func nsToCarbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command)  { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift)    { carbon |= UInt32(shiftKey) }
        if flags.contains(.option)   { carbon |= UInt32(optionKey) }
        if flags.contains(.control)  { carbon |= UInt32(controlKey) }
        return carbon
    }

    /// Compose a "⌃⌥⌘R"-style display label from key + modifiers.
    /// Internal because HotkeyManager's NSEvent hold-monitor path
    /// uses it to compose the permission-prompt toast label.
    static func humanLabel(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += keyName(for: keyCode)
        return s
    }

    /// Map a Carbon keyCode to its on-screen glyph. Falls back to
    /// `<keyCode>` for keys we haven't mapped.
    private static func keyName(for code: UInt32) -> String {
        // Punctuation + named keys
        switch Int(code) {
        case kVK_Space:     return "Space"
        case kVK_Return:    return "⏎"
        case kVK_Tab:       return "⇥"
        case kVK_Escape:    return "⎋"
        case kVK_Delete:    return "⌫"
        case kVK_F1:        return "F1"
        case kVK_F2:        return "F2"
        case kVK_F3:        return "F3"
        case kVK_F4:        return "F4"
        case kVK_F5:        return "F5"
        case kVK_F6:        return "F6"
        case kVK_F7:        return "F7"
        case kVK_F8:        return "F8"
        case kVK_F9:        return "F9"
        case kVK_F10:       return "F10"
        case kVK_F11:       return "F11"
        case kVK_F12:       return "F12"
        case kVK_Function:  return "Fn"
        case kVK_LeftArrow:  return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow:    return "↑"
        case kVK_DownArrow:  return "↓"
        default: break
        }
        // ANSI letters/digits
        let ansiMap: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
            kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Backslash: "\\", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
            kVK_ANSI_Grave: "`",
        ]
        return ansiMap[Int(code)] ?? "<\(code)>"
    }
}

// MARK: - Manager

/// One of the three recording modes Daisy supports a hotkey for.
/// The rawValue doubles as the Carbon `EventHotKeyID.id` so the C
/// callback can disambiguate which slot fired without a lookup
/// table. Keep raw values stable — they're the wire format between
/// the kernel-side event tap and our action map.
nonisolated enum HotkeySlot: UInt32, CaseIterable, Sendable {
    case record    = 1   // mode = .meeting
    case voiceNote = 2   // mode = .voiceNote
    case dictation = 3   // mode = .dictation
    case rewrite   = 4   // rewrite selection in the user's voice
    case fixLayout = 5   // re-type text in the keyboard layout it belonged to
    case markMoment = 6  // "this bit matters" during a recording
    case repasteLast = 7 // paste the most recent dictation at the caret
}

/// How the slot's hotkey reacts to a key press:
///
///   - `.toggle` — single fire on press. Carbon `RegisterEventHotKey`
///     handles this and requires NO permission. Meeting recorder uses
///     this — recording a 60-minute call by holding a key down would
///     be cruel.
///
///   - `.hold` — fires `onPress` on key-down edge and `onRelease`
///     on key-up edge. Push-to-talk semantics, the natural fit for
///     dictation and quick voice notes. Carbon doesn't deliver
///     key-up events, so we use `NSEvent.addGlobalMonitorForEvents`
///     instead — which requires Input Monitoring permission. macOS
///     prompts on first use.
///
/// The mode is chosen by the call site (`ServiceWiring`), not by
/// the user's choice of key — meeting can be Fn (toggle), voice
/// note can be ⌃⌥V (hold). They're orthogonal.
nonisolated enum HotkeyAction: Sendable {
    case toggle(@MainActor @Sendable () -> Void)
    case hold(
        onPress: @MainActor @Sendable () -> Void,
        onRelease: @MainActor @Sendable () -> Void
    )
}

/// Thread-safe per-slot storage of the currently-registered action.
/// The Carbon `@convention(c)` callback and the NSEvent global
/// monitors all read from this map outside MainActor. Actions
/// inside the action enum are pre-typed `@MainActor` so the only
/// legal invocation site is a hop back to the main actor.
nonisolated private final class HotkeyActionMap: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[HotkeySlot: HotkeyAction]>(initialState: [:])

    func set(slot: HotkeySlot, action: HotkeyAction?) {
        lock.withLock { state in
            if let action {
                state[slot] = action
            } else {
                state.removeValue(forKey: slot)
            }
        }
    }

    func get(slot: HotkeySlot) -> HotkeyAction? {
        lock.withLock { $0[slot] }
    }
}

/// Mutable bool for press-state tracking inside event-monitor
/// closures. Closures capture `var` immutably, so we hide the
/// flip-flop state inside a thread-safe reference instead.
nonisolated private final class HoldPressState: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// Set `next` and return the *previous* value — used to detect
    /// rising / falling edges without an extra check.
    func swap(_ next: Bool) -> Bool {
        lock.withLock { prev in
            let was = prev
            prev = next
            return was
        }
    }
}

@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    /// EventHotKeyRef per slot — kept so we can `UnregisterEventHotKey`
    /// individually when a single hotkey is re-bound without tearing
    /// the other two down.
    private var refs: [HotkeySlot: EventHotKeyRef] = [:]

    /// NSEvent global monitors per slot — used when the bound choice
    /// is `.fn` (or any other case `.isFnOnly` matches). Stored
    /// alongside refs/actionMap so unregister can tear the right
    /// path down.
    private var fnMonitors: [HotkeySlot: Any] = [:]

    /// One shared event handler for all 3 slots — installed lazily
    /// on first `register(...)`, reused thereafter, torn down only
    /// when all 3 slots are unregistered.
    private var eventHandler: EventHandlerRef?

    /// `nonisolated` so the C callback can reach it via the manager
    /// pointer without crossing MainActor isolation. The map itself
    /// is thread-safe; actions are `@MainActor`-typed so they can
    /// only run after a MainActor hop.
    nonisolated fileprivate let actionMap = HotkeyActionMap()

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Hotkey")

    private init() {}

    /// Register or replace the hotkey for `slot`. Passing a `.none`
    /// choice unregisters the slot. Other slots keep their existing
    /// bindings.
    ///
    /// `action` picks the registration strategy:
    ///   - `.toggle` + non-Fn → Carbon RegisterEventHotKey, zero
    ///     permission, single-fire-on-press.
    ///   - `.toggle` + Fn → NSEvent .flagsChanged monitor (Fn alone
    ///     isn't a Carbon-bindable key), Input Monitoring required.
    ///   - `.hold` + anything → NSEvent global monitor (.keyDown +
    ///     .keyUp for regular keys, .flagsChanged for Fn). Input
    ///     Monitoring required, push-to-talk semantics.
    func register(slot: HotkeySlot, choice: HotkeyChoice, action: HotkeyAction) {
        unregister(slot: slot)
        guard let keyCode = choice.keyCode, let mods = choice.modifiers else { return }
        actionMap.set(slot: slot, action: action)

        switch action {
        case .toggle:
            if choice.isFnOnly {
                installFnFlagsMonitor(slot: slot, isHold: false)
            } else {
                installCarbonToggle(slot: slot, keyCode: keyCode, mods: mods)
            }
        case .hold:
            if choice.isFnOnly {
                installFnFlagsMonitor(slot: slot, isHold: true)
            } else {
                installKeyHoldMonitor(slot: slot, keyCode: keyCode, mods: mods)
            }
        }
    }

    /// Backward-compatible single-slot API. Treats the action as
    /// `.toggle` (the original Daisy hotkey contract). Kept so
    /// pre-multi-slot call sites in tests / experiments keep working.
    func register(choice: HotkeyChoice, action: @escaping @MainActor @Sendable () -> Void) {
        register(slot: .record, choice: choice, action: .toggle(action))
    }

    /// Combinations we've already complained about this launch — see the
    /// failure path in `installCarbonToggle`.
    private static var reportedRegistrationFailures: Set<String> = []

    /// Carbon path — single fire on press, no permission required.
    /// Used by `.toggle` mode for any non-Fn key.
    private func installCarbonToggle(slot: HotkeySlot, keyCode: UInt32, mods: UInt32) {
        ensureEventHandlerInstalled()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(
            signature: fourCharCode("DAIS"),
            id: slot.rawValue
        )
        let status = RegisterEventHotKey(
            keyCode,
            mods,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if let ref, status == noErr {
            refs[slot] = ref
            return
        }
        // The status used to be discarded, so a combination already held
        // by another app (Raycast, Alfred, Keyboard Maestro, a system
        // shortcut) failed with `eventHotKeyExistsErr` and NOTHING said
        // so: Settings kept showing the shortcut as assigned, the key
        // did nothing, and no line reached the log either. The hold path
        // right below has always handled its own permission failure
        // properly; this was the one silent one (audit 2026-09-01).
        let label = HotkeyChoice.humanLabel(keyCode: keyCode, modifiers: mods)
        log.warning("RegisterEventHotKey failed for \(label, privacy: .public) (slot \(slot.rawValue, privacy: .public)) — OSStatus \(status, privacy: .public)")
        // Only `eventHotKeyExistsErr` means "taken"; anything else is
        // our own bug and shouldn't accuse another app of it.
        let message = status == OSStatus(eventHotKeyExistsErr)
            ? String(localized: "Another app is already using \(label) — Daisy can't use it as a shortcut. Pick a different one.")
            : String(localized: "Daisy couldn't register \(label) as a shortcut. Try a different combination.")
        // One toast per combination per launch. `applyAllHotkeys`
        // re-registers all seven slots on every settings change, so a
        // standing conflict would otherwise fire on each keystroke in
        // the shortcut recorder and evict every other toast — the
        // ToastCenter has one slot too.
        guard Self.reportedRegistrationFailures.insert(label).inserted else { return }
        ToastCenter.shared.showAction(
            message,
            actionLabel: String(localized: "Open Settings"),
            style: .warning,
            duration: .seconds(15)
        ) {
            // Land on the tab that holds the shortcut rows, and bring
            // the window forward — the toast can be triggered from a
            // background launch where no window is open.
            AppNavigation.shared.pendingSettingsTab = .recording
            AppNavigation.shared.section = .settings
            WidgetBubbleCenter.shared.openMainWindow?()
        }
    }

    /// NSEvent .flagsChanged monitor for Fn / 🌐 globe key.
    /// `isHold` switches between toggle (fire on rising edge only)
    /// and push-to-talk (fire onPress on rising edge, onRelease on
    /// falling edge).
    private func installFnFlagsMonitor(slot: HotkeySlot, isHold: Bool) {
        let state = HoldPressState()
        let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: .flagsChanged
        ) { [weak self, state] event in
            guard let self else { return }
            // .function covers both legacy Fn and modern 🌐 globe.
            let isDown = event.modifierFlags.contains(.function)
            let wasDown = state.swap(isDown)
            if isDown && !wasDown {
                self.fireOnPress(slot: slot)
            } else if !isDown && wasDown && isHold {
                self.fireOnRelease(slot: slot)
            }
        }
        guard let monitor else {
            promptForInputMonitoring(label: "Fn / 🌐 key")
            return
        }
        fnMonitors[slot] = monitor
    }

    /// NSEvent .keyDown + .keyUp monitor for hold-to-talk bindings
    /// on regular (non-Fn) keys. Filters autorepeat key-downs so
    /// the press action fires exactly once per physical press.
    private func installKeyHoldMonitor(slot: HotkeySlot, keyCode: UInt32, mods: UInt32) {
        let state = HoldPressState()
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp]
        let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: mask
        ) { [weak self, state] event in
            guard let self else { return }
            // Match keyCode + Carbon-equivalent modifier bits. The
            // NSEvent modifierFlags can carry extra OS-level bits
            // (capsLock, deviceIndependentFlagsMask) we don't care
            // about — mask down before comparison.
            guard UInt32(event.keyCode) == keyCode else { return }
            guard matchesCarbonMods(event.modifierFlags, carbonMods: mods) else { return }

            switch event.type {
            case .keyDown:
                if event.isARepeat { return }
                if state.swap(true) { return }  // already-down race
                self.fireOnPress(slot: slot)
            case .keyUp:
                if !state.swap(false) { return }  // already-up race
                self.fireOnRelease(slot: slot)
            default:
                break
            }
        }
        guard let monitor else {
            promptForInputMonitoring(label: HotkeyChoice.humanLabel(keyCode: keyCode, modifiers: mods))
            return
        }
        fnMonitors[slot] = monitor
    }

    /// Dispatch the press half of the slot's current action.
    /// Crosses MainActor for the actual closure invocation.
    nonisolated private func fireOnPress(slot: HotkeySlot) {
        guard let action = actionMap.get(slot: slot) else { return }
        switch action {
        case .toggle(let f):
            Task { @MainActor in f() }
        case .hold(let onPress, _):
            Task { @MainActor in onPress() }
        }
    }

    /// Dispatch the release half — only relevant for `.hold`
    /// actions. `.toggle` slots ignore release edges.
    nonisolated private func fireOnRelease(slot: HotkeySlot) {
        guard case .hold(_, let onRelease) = actionMap.get(slot: slot) else { return }
        Task { @MainActor in onRelease() }
    }

    /// Show a once-per-failure toast nudging the user to Privacy &
    /// Security → Input Monitoring. The actual Settings deeplink
    /// jumps straight to the right pane.
    @MainActor
    private func promptForInputMonitoring(label: String) {
        log.warning("NSEvent.addGlobalMonitorForEvents returned nil — Input Monitoring denied for \(label, privacy: .public)")
        ToastCenter.shared.showAction(
            String(localized: "Daisy needs Input Monitoring to use the \(label) hotkey."),
            actionLabel: String(localized: "Open Settings"),
            style: .warning,
            perform: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                    NSWorkspace.shared.open(url)
                }
            }
        )
    }

    /// Unregister a single slot. Idempotent. Removes the shared
    /// event handler only when no slot remains registered.
    func unregister(slot: HotkeySlot) {
        if let ref = refs[slot] {
            UnregisterEventHotKey(ref)
            refs.removeValue(forKey: slot)
        }
        if let monitor = fnMonitors[slot] {
            NSEvent.removeMonitor(monitor)
            fnMonitors.removeValue(forKey: slot)
        }
        actionMap.set(slot: slot, action: nil)
        if refs.isEmpty, let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    /// Unregister every slot. Used at app shutdown / `applyAll` rewiring.
    func unregister() {
        for slot in HotkeySlot.allCases {
            unregister(slot: slot)
        }
    }

    /// Install the Carbon event handler that dispatches by
    /// `EventHotKeyID.id`. Lazy — runs once, persists until the
    /// last slot unregisters.
    private func ensureEventHandlerInstalled() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let userData, let eventRef else { return noErr }
                // Extract the EventHotKeyID so we know which slot
                // fired. Without this the manager couldn't tell
                // record vs voiceNote vs dictation apart.
                var hkID = EventHotKeyID()
                let size = MemoryLayout<EventHotKeyID>.size
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    size,
                    nil,
                    &hkID
                )
                guard status == noErr else { return noErr }
                guard let slot = HotkeySlot(rawValue: hkID.id) else { return noErr }
                let manager = Unmanaged<HotkeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                // Carbon path only fires for `.toggle` registrations;
                // `.hold` lives in NSEvent monitor land. Defensively
                // accept either, but Carbon never sees a hold action.
                manager.fireOnPress(slot: slot)
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandler
        )
    }
}

// MARK: - FourCharCode helper

private func fourCharCode(_ string: String) -> OSType {
    var code: OSType = 0
    for char in string.unicodeScalars.prefix(4) {
        code = (code << 8) | (OSType(char.value) & 0xFF)
    }
    return code
}

/// Compare an NSEvent's `modifierFlags` against a Carbon modifier
/// bitmask. NSEvent includes a number of OS-level flag bits we
/// don't care about (capsLock state, deviceIndependentFlagsMask
/// internals); mask the comparison down to the four we register
/// hotkeys against — ⌘ / ⌃ / ⌥ / ⇧.
private func matchesCarbonMods(_ ns: NSEvent.ModifierFlags, carbonMods: UInt32) -> Bool {
    var fromNS: UInt32 = 0
    if ns.contains(.command)  { fromNS |= UInt32(cmdKey) }
    if ns.contains(.control)  { fromNS |= UInt32(controlKey) }
    if ns.contains(.option)   { fromNS |= UInt32(optionKey) }
    if ns.contains(.shift)    { fromNS |= UInt32(shiftKey) }
    return fromNS == carbonMods
}
