//
//  AXFocus.swift
//  Daisy
//
//  What has keyboard focus right now, asked through Accessibility.
//
//  This exists because of one question the layout fixer cannot answer
//  any other way: is it safe to send backspaces? Letters typed into a
//  MESSAGE LIST are type-select, not text — and the backspaces that
//  would fix a word there delete mail instead. Same shape in Finder, in
//  Gmail's keyboard shortcuts, in any app where a bare letter is a
//  command. A fixer that can't tell the difference is a text shredder
//  with good intentions.
//
//  Everything here is best-effort by design. Apps vary wildly in what
//  they expose (Electron and web views worst of all), and every failure
//  returns "don't know" — which callers must treat as "don't touch".
//
//  One class of "don't know" is recoverable: Chromium-based apps have no
//  accessibility tree at all until a client asks for one. See
//  `requestAccessibilityTree(forProcessID:)` — callers that get nothing
//  useful should ask, then move on and expect an answer next time.
//
//  AX calls block on the target app, so the messaging timeout is pinned
//  short: this runs between a keystroke and the character appearing, and
//  an unresponsive app must cost us milliseconds, not seconds.
//

import AppKit
import ApplicationServices

@MainActor
enum AXFocus {

    enum Kind {
        /// Not a text field, or we couldn't tell. Never edit.
        case unknown
        /// The system won't name a focused element at all. Also never
        /// edit — but distinct from `unknown` because it is the one
        /// failure with a possible remedy: an app with no accessibility
        /// tree looks exactly like this. See
        /// `requestAccessibilityTree(forProcessID:)`.
        case noElement
        /// A password field. Never edit, never inspect.
        case secure
        /// Editable text.
        case editable
    }

    private static let messagingTimeout: Float = 0.2

    static func kind() -> Kind {
        guard let element = focusedElement() else { return .noElement }
        let role = string(element, kAXRoleAttribute) ?? ""
        let subrole = string(element, kAXSubroleAttribute) ?? ""
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" { return .secure }
        if role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole {
            return .editable
        }
        // Browser and Electron editors commonly expose the focused
        // contenteditable area as AXWebArea rather than AXTextArea.  A
        // settable selection range is the evidence that this particular
        // web area is accepting text; a read-only page does not qualify.
        if role == "AXWebArea", isSettable(element, kAXSelectedTextRangeAttribute as CFString) {
            return .editable
        }
        // Web and Electron inputs often report something else entirely.
        // A settable value attribute is the next best evidence that this
        // is a place text can be edited.
        return isSettable(element, kAXValueAttribute as CFString) ? .editable : .unknown
    }

    /// What the focused element looks like, for the log report and for
    /// the one-line refusal notes. Roles and subroles are AX CLASS names
    /// ("AXTextField", "AXWebArea") — the shape of the UI, never its
    /// content, so this is safe to log where the text itself would not
    /// be.
    static func describeFocus() -> String {
        guard let element = focusedElement() else { return "no focused element" }
        let role = string(element, kAXRoleAttribute) ?? "?"
        let subrole = string(element, kAXSubroleAttribute) ?? "-"
        let settable = isSettable(element, kAXValueAttribute as CFString)
        return "role=\(role) subrole=\(subrole) valueSettable=\(settable)"
    }

    /// The `count` characters immediately before the caret, when the app
    /// will say. Used to CONFIRM that what we are about to delete is what
    /// we think it is — the difference between fixing a word and eating
    /// the sentence in front of it.
    ///
    /// Nil means "no answer", which is not the same as "doesn't match".
    /// A DEFINITE answer that can't match comes back as one, so callers
    /// treat it as the mismatch it is rather than as silence (review
    /// 31.10: an emptied field after Return read as "no answer", and
    /// the fix key then sent backspaces into it): fewer characters
    /// before the caret than asked for come back as they are, and a
    /// selection — the caret isn't sitting after any text — as "".
    static func textBeforeCaret(count: Int) -> String? {
        guard count > 0, let element = focusedElement() else { return nil }
        switch caret(element) {
        case nil:
            return nil
        case .selection:
            return ""
        case .at(let caret):
            guard caret > 0 else { return isEmpty(element) ? "" : nil }
            return text(of: element, before: caret, count: min(count, caret))
        }
    }

    /// Where the caret and the text Accessibility reports may not be the
    /// ones on screen: any Chromium-based app, Electron included (Slack,
    /// Notion, Discord, the browsers) — their trees report per block and
    /// lag behind the keystrokes — and a contenteditable editor anywhere,
    /// which exposes its root as the focused AXWebArea. The fix key trusts
    /// a reading there only when the tap's own record of the typing
    /// agrees. A WebKit text field or text area (Safari inputs, Mail) is
    /// trusted: one call, no walk up a DOM deeper than any cap (review
    /// 31.10 — a 12-hop walk was both too slow and too shallow).
    static func caretMayBeUnreliable() -> Bool {
        if let app = NSWorkspace.shared.frontmostApplication, isChromiumBased(app) { return true }
        guard let element = focusedElement() else { return true }
        return string(element, kAXRoleAttribute) == "AXWebArea"
    }

    /// Chromium names its framework «<Product> Framework.framework»
    /// (Google Chrome, Microsoft Edge, Brave Browser, Electron…);
    /// nothing else ships one spelled that way. Per bundle, once.
    private static func isChromiumBased(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        if let known = chromiumBundles[url] { return known }
        let frameworks = url.appendingPathComponent("Contents/Frameworks")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        let isChromium = names.contains { $0.hasSuffix(" Framework.framework") }
        chromiumBundles[url] = isChromium
        return isChromium
    }

    private static var chromiumBundles: [URL: Bool] = [:]

    /// The focused field reports a caret and no selection — the fix key
    /// can skip asking for one with ⌘C (which empties and refills the
    /// clipboard). Nil when it won't say.
    static func hasNoSelection() -> Bool? {
        guard let element = focusedElement(), let caret = caret(element) else { return nil }
        if case .at = caret { return true }
        return false
    }

    /// Up to `limit` UTF-16 units before the caret, and whether they reach
    /// the start of the field — the fix key's way to find the last word
    /// when nothing it typed is in memory. Nil means "no answer", as
    /// above; an empty string is a caret at the start of the field.
    static func textBeforeCaret(upTo limit: Int) -> (text: String, reachesStart: Bool)? {
        guard limit > 0, let element = focusedElement() else { return nil }
        guard case .at(let caret) = caret(element) else { return nil }
        let count = min(caret, limit)
        guard count > 0 else { return isEmpty(element) ? ("", true) : nil }
        // An answer of the wrong length is an app whose caret and text
        // disagree — no answer at all, for a caller about to count
        // backspaces from it.
        guard let text = text(of: element, before: caret, count: count), text.utf16.count == count else { return nil }
        return (text, count == caret)
    }

    private static func text(of element: AXUIElement, before caret: Int, count: Int) -> String? {
        var range = CFRange(location: caret - count, length: count)
        // Ask for just the tail if the app supports it — the whole value
        // of a long document is expensive and often refused.
        if let rangeValue = AXValueCreate(.cfRange, &range) {
            var result: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                rangeValue,
                &result
            ) == .success, let text = result as? String {
                return text
            }
        }
        // Fall back to the whole value.
        guard let whole = string(element, kAXValueAttribute) else { return nil }
        let units = Array(whole.utf16)
        guard caret <= units.count, caret - count >= 0 else { return nil }
        return String(decoding: units[(caret - count)..<caret], as: UTF16.self)
    }

    // MARK: - Waking up apps that have no tree yet

    /// Ask an app to build its accessibility tree, for the apps that
    /// don't have one until someone asks.
    ///
    /// Chromium — and therefore every Electron app: Claude, Slack,
    /// Discord, Notion — keeps its AX tree switched OFF and builds it
    /// only when a client sets `AXManualAccessibility` on the
    /// application element. Until then the system-wide focused-element
    /// query returns nothing at all, which is precisely the "no focused
    /// element" the layout fixer logs when it stands down. Native AppKit
    /// apps always have a tree, which is why the same word gets fixed in
    /// Notes and Telegram and ignored one window over.
    ///
    /// Deliberately narrow. Switching the tree on is not free — the
    /// target app builds and then maintains it from here on — so we ask
    /// once per process, only for the app the user is actively typing
    /// into, and only after a real refusal. Never speculatively, never
    /// across everything running. We also never switch it back off: the
    /// flag is global to the target process and another assistive client
    /// may be leaning on it.
    ///
    /// Chromium builds the tree asynchronously, so the keystroke that
    /// triggered this still gets no answer. The next word is the one
    /// that gets fixed.
    ///
    /// Returns the app's answer, or nil when nothing was sent — this pid
    /// was already asked, or there is no running app behind it. Callers
    /// log on a non-nil answer, so the log gets one line per app rather
    /// than one per keystroke.
    ///
    /// Note this fires at a NATIVE app too, on the rare occasions
    /// nothing at all has focus (an empty desktop). That costs one call
    /// and one line, and `.attributeUnsupported` comes back and settles
    /// it permanently.
    @discardableResult
    static func requestAccessibilityTree(forProcessID pid: pid_t) -> AXError? {
        guard pid > 0, let running = NSRunningApplication(processIdentifier: pid) else { return nil }
        let now = Date()
        if let previous = manualAccessibilityAsked[pid],
           previous.launchDate == running.launchDate,
           !previous.isWorthRetrying(now: now) {
            return nil
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        let result = AXUIElementSetAttributeValue(
            app,
            manualAccessibilityAttribute as CFString,
            kCFBooleanTrue as CFTypeRef
        )
        manualAccessibilityAsked[pid] = Ask(
            launchDate: running.launchDate,
            result: result,
            at: now
        )
        forgetDeadProcesses()
        return result
    }

    /// Not a public constant in any SDK header — Chromium's own
    /// convention, which Electron inherits.
    private static let manualAccessibilityAttribute = "AXManualAccessibility"

    /// One app's answer, remembered so it is asked once and not once per
    /// keystroke — a cross-process call with a 200 ms ceiling has no
    /// business in the typing path of every app that simply has no tree
    /// to give.
    private struct Ask {
        /// What makes this entry about a PROCESS and not about a number.
        /// PIDs are recycled, and matching on the number alone would
        /// leave a brand-new app permanently unasked because something
        /// that quit an hour ago happened to have the same one. Optional
        /// because AppKit doesn't always know; when it's nil on both
        /// sides this degrades to matching the number, which costs at
        /// worst the one missed ask it always used to cost.
        let launchDate: Date?
        let result: AXError
        let at: Date

        /// Whether the answer leaves anything to come back for. A
        /// refusal is final: either Chromium took the flag, or the app
        /// is native and has no such attribute to set. Only "couldn't
        /// complete" is worth another go — an app busy launching says
        /// that — and not soon, because the ask isn't free.
        func isWorthRetrying(now: Date) -> Bool {
            result == .cannotComplete && now.timeIntervalSince(at) > retryAfter
        }

        private var retryAfter: TimeInterval { 60 }
    }

    private static var manualAccessibilityAsked: [pid_t: Ask] = [:]

    /// Purely a memory bound — correctness against recycled PIDs comes
    /// from `Ask.launchDate`, not from pruning in time.
    private static func forgetDeadProcesses() {
        guard manualAccessibilityAsked.count > 16 else { return }
        manualAccessibilityAsked = manualAccessibilityAsked.filter {
            NSRunningApplication(processIdentifier: $0.key) != nil
        }
    }

    // MARK: - Plumbing

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success,
        let value = focused,
        CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    private enum Caret {
        /// No selection; the caret at this UTF-16 offset.
        case at(Int)
        /// Text is selected.
        case selection
    }

    /// Where the caret is, or nil when the app doesn't report a selection.
    private static func caret(_ element: AXUIElement) -> Caret? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &raw
        ) == .success,
        let value = raw,
        CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        // A non-empty selection means the caret isn't sitting after a
        // word we typed.
        guard range.length == 0 else { return .selection }
        guard range.location >= 0 else { return nil }
        return .at(range.location)
    }

    /// The field holds no text. A caret at 0 is believed only then: some
    /// web editors report {0, 0} wherever the caret really is, and that
    /// must stay "no answer", not "nothing there" (review 31.10).
    private static func isEmpty(_ element: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &raw) == .success,
           let count = raw as? Int {
            return count == 0
        }
        return string(element, kAXValueAttribute)?.isEmpty ?? false
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute, &settable) == .success else { return false }
        return settable.boolValue
    }
}
