//
//  LayoutFixUndo.swift
//  Daisy
//
//  Makes a wrong automatic layout fix cheap to reverse — the whole
//  reason Punto Switcher's users tolerated an aggressive corrector was
//  that a mistake cost one press of Break. Ours stays conservative
//  (see LayoutFix.judge), but a bad call should still cost one
//  keypress, not a manual retype. That's what this file is for.
//
//  What records something here: the two AUTOMATIC paths (LayoutAutoFix's
//  "before the boundary" and "after the fact"), and — since 31.10.2026 —
//  the fix key (any key, a lone ⌥ included) when it fixed the LAST WORD with nothing
//  selected. That word is gone from the buffer the moment it is fixed,
//  and the converted text can't be re-converted blindly (the key would
//  pick the dictionary's favourite, not necessarily what was there), so
//  pressing again right away puts back exactly what was typed — Punto's
//  second press. Only an automatic fix's undo teaches
//  `LayoutFixExceptions`: undoing your own press says nothing about the
//  word. A fixed SELECTION records nothing: the selection is gone after
//  the paste, and undoing it would fight PasteboardProxy over the
//  clipboard.
//

import Foundation
import Observation

/// The last automatic fix, kept just long enough for one keypress to
/// undo it.
@MainActor
final class LayoutFixUndo {
    static let shared = LayoutFixUndo()

    struct Record {
        /// The word as the person typed it, no boundary. This is what
        /// gets retyped, and the exceptions set's key.
        let originalWord: String
        /// What sits between the word and the caret and was put back
        /// as it was: the boundary that ended it (space, comma, Return,
        /// …) for the automatic paths, which only settle once one has
        /// fired; for the fix key the spaces after the last word, or
        /// nothing for a word still being typed.
        let trailing: String
        /// The fix's output, word only, no boundary.
        let replacementWord: String
        let bundleID: String
        /// The layout to make active again on undo — i.e. whatever was
        /// active before `settle` switched it, captured at that moment.
        /// `nil` when `settle` didn't switch anything, matching the
        /// "nothing to put back" case.
        let restoreLayoutID: String?
        /// `WordBuffer.generation` read right after `settle` discards
        /// the buffer — i.e. the value AFTER the fix's own discard has
        /// already bumped it, not a value cached before that call.
        /// This is what lets undo work in apps that won't answer
        /// Accessibility: the tap sees every keystroke on the machine,
        /// so if this counter hasn't moved (beyond the fix key's own
        /// chord — see `generationAllowsUndo`), nothing was TYPED
        /// since. That is not quite "the caret can't have moved" —
        /// see the caveat on `generationAllowsUndo` — but it is
        /// everything a keystroke-based signal can prove.
        ///
        /// Nil when the tap wasn't running at the fix — the fix key
        /// works without it, and a counter nobody advanced proves
        /// nothing about what was typed since.
        let generation: UInt64?
        /// The fix key (or the Daisy key's tap) made this fix, not the automatic
        /// watcher: its undo is a second press, not a lesson.
        var byKey = false
        let at: Date

        /// What's on screen right now: fix output + boundary. What
        /// undo deletes, and what it compares the caret against.
        var replacementText: String { replacementWord + trailing }
        /// What undo retypes.
        var originalText: String { originalWord + trailing }
    }

    /// How long an undo stays offered. Long enough to notice the
    /// mistake and reach for the key; short enough that pressing it
    /// after several more words have gone by does ordinary key work
    /// instead of surprising someone by rewriting a sentence they've
    /// moved past.
    private static let window: TimeInterval = 5

    private(set) var pending: Record?

    private init() {}

    func record(_ record: Record) {
        pending = record
    }

    /// The pending record, if it's still within the undo window and
    /// for the same app — `nil` otherwise, which the caller treats as
    /// "nothing to undo". Cross-app is refused outright: the fix and
    /// the undo key press have to happen in the same place, or this is
    /// somebody else's fix key press in a different window.
    func fresh(bundleID: String) -> Record? {
        guard let pending,
              Date().timeIntervalSince(pending.at) <= Self.window,
              pending.bundleID == bundleID
        else { return nil }
        return pending
    }

    /// Second press in a row after a successful undo is ordinary key
    /// work, not an undo of the undo — callers clear this the moment
    /// undo succeeds.
    func clear() {
        pending = nil
    }

    /// Whether a press of the fix key is the undo of `record`, given what
    /// Accessibility says sits before the caret. AX has THREE possible
    /// answers here, not two, and they are not interchangeable:
    ///
    ///  - Matches → confirmed, undo.
    ///  - A DIFFERENT string → confirmed WRONG. This is positive proof
    ///    the caret or the text moved (a focus change with no keystroke:
    ///    a timer-driven UI update, JS moving focus in a web view,
    ///    another automation tool's own AX call), and it must veto
    ///    outright — falling back to the generation counter here would
    ///    let a definite "no" be overruled by a heuristic that only
    ///    proves "no keystroke", not "the caret didn't move".
    ///  - No answer (nil) → AX can't help either way, which is Telegram,
    ///    Slack, Electron and most web editors, exactly where this
    ///    feature earns its keep. THIS is the one case the generation
    ///    counter is for: the tap sees every keystroke on the machine
    ///    regardless of which app is in front, so it can stand in for AX
    ///    being silent — never for AX being wrong. And only a counter the
    ///    tap has been advancing all along: with the watcher off at the
    ///    fix (`generation == nil`) or now, nobody counted what was typed.
    ///
    /// The caller still checks the focus is editable text first — that
    /// answers "can backspaces go here at all", not "does the text match".
    static func confirms(
        _ record: Record,
        textBeforeCaret: String?,
        tapRunning: Bool,
        currentGeneration: UInt64,
        triggerKeystrokes: UInt64
    ) -> Bool {
        switch textBeforeCaret {
        case .some(record.replacementText):
            return true
        case .some:
            return false
        case nil:
            guard tapRunning, let recorded = record.generation else { return false }
            return generationAllowsUndo(recorded: recorded, current: currentGeneration, triggerKeystrokes: triggerKeystrokes)
        }
    }

    /// Whether the generation counter alone proves nothing was typed
    /// since the fix — independent of Accessibility, which stays
    /// silent in exactly the apps (Telegram, Slack, Electron, most web
    /// editors) where this feature matters most.
    ///
    /// The tolerance is the trigger's own keystrokes and nothing more:
    /// a fix key with a letter (⇧⌘R) reaches the tap as a chord — a
    /// keyDown with ⌃/⌥/⌘ set — and `LayoutAutoFix.handle` routes any
    /// chord through `buffer.clear()`, which bumps the generation once.
    /// A modifier on its own (a tap of ⌥, the Daisy key's ⌃⌥) or Fn
    /// arrives as `.flagsChanged`, which the tap's mask (keyDown + the
    /// three mouse-down types) never sees: no bump, so none forgiven —
    /// forgiving one there would let undo erase a letter typed after the
    /// fix (review 31.10). Our own synthetic replacement/undo keystrokes
    /// are marked and skipped by the tap entirely.
    ///
    /// Pure — no AX, no running app — so it's checkable on its own.
    ///
    /// Known gap, accepted rather than papered over: this proves no
    /// KEYSTROKE happened, not that the caret is still where the fix
    /// left it. A focus or selection change with no keyDown at all —
    /// a timer-driven UI update, JS moving focus in a web view, a
    /// third-party AX/automation call, scroll-synced caret movement —
    /// would pass this check untouched. Two things narrow it in
    /// practice rather than closing it: the caller in
    /// `LayoutFixService` only reaches this branch when AX stayed
    /// SILENT (a definite AX mismatch vetoes outright, no fallback
    /// here — see `confirms`), and it requires the coincidence to
    /// land inside the same 5-second window in the same app. Closing
    /// it fully would need an AX focus-change observer
    /// (`AXObserverCreate` + `kAXFocusedUIElementChangedNotification`),
    /// which is a materially bigger feature than "one keypress undoes
    /// a fix" — noted here rather than built speculatively.
    nonisolated static func generationAllowsUndo(recorded: UInt64, current: UInt64, triggerKeystrokes: UInt64 = 1) -> Bool {
        current >= recorded && current &- recorded <= triggerKeystrokes
    }
}

/// Words the automatic fixer has been told, via undo, never to touch
/// again. A single wrong call is now one keypress AND one lesson
/// learned, so the same slang word or product name doesn't keep
/// getting "corrected" every time it's typed.
@MainActor
@Observable
final class LayoutFixExceptions {
    static let shared = LayoutFixExceptions()

    /// Past this many words the oldest exceptions age out. Not a
    /// permanent blocklist — the point is "stop re-annoying me about
    /// the word I just undid", and a cap keeps years of one-off typos
    /// from silently growing a plist forever.
    static let cap = 2_000

    private static let defaultsKey = "daisy.layoutFixExceptions"

    private let defaults: UserDefaults

    /// Oldest first — insertion order, needed for eviction. `contains`
    /// runs on the hottest path `judge` has (every automatically-typed
    /// word), so a parallel `Set` gives it O(1) instead of a linear
    /// scan through up to 2,000 strings.
    private(set) var words: [String]
    private var lookup: Set<String>

    var count: Int { words.count }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        words = stored
        lookup = Set(stored)
    }

    /// Case-insensitive: the word buffer holds exactly what was typed,
    /// and "Ghbdtn" at the start of a sentence has to match the
    /// "ghbdtn" undone moments earlier mid-sentence.
    func contains(_ word: String) -> Bool {
        lookup.contains(word.lowercased())
    }

    func add(_ word: String) {
        let key = word.lowercased()
        guard !lookup.contains(key) else { return }
        words.append(key)
        lookup.insert(key)
        if words.count > Self.cap {
            let overflow = words.count - Self.cap
            for evicted in words.prefix(overflow) { lookup.remove(evicted) }
            words.removeFirst(overflow)
        }
        persist()
    }

    func clear() {
        words.removeAll()
        lookup.removeAll()
        persist()
    }

    private func persist() {
        defaults.set(words, forKey: Self.defaultsKey)
    }
}
