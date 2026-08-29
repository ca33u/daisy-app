//
//  FloatingPanelController.swift
//  Daisy
//
//  Manages the borderless NSPanel that hosts the Daisy widget. The panel
//  floats above all apps, doesn't steal focus, is draggable, and is
//  shown automatically while the session is busy (recording, preparing,
//  summarizing) and tucked away otherwise.
//

import AppKit
import SwiftUI
import Observation
import os

@MainActor
final class FloatingPanelController {
    private let session: RecordingSession
    private let settings: AppSettings
    private var panel: NSPanel?
    private var hasPositionedOnce = false
    /// The callout anchored to the widget (see `WidgetBubble`). A second
    /// borderless panel, sized to its content, tracked to the widget's
    /// frame on show. Nil when nothing is being prompted.
    private var bubblePanel: NSPanel?
    private var bubbleDismissTimer: Timer?
    /// The live pill's ✕ ring — kept to pause/restart the countdown
    /// while a dictation hold is feeding a screenshot note.
    private weak var bubbleCloseButton: CountdownCloseButton?
    /// The live pill's configured lifetime, for `restartBubbleCountdown`.
    private var bubbleAutoDismiss: TimeInterval = 12
    /// Objc target for the bubble's action button — see
    /// `BubbleActionTarget`. Lives exactly as long as the bubble.
    private var bubbleActionTarget: AnyObject?
    /// Same, for the bubble's destructive (trash) button. A second slot
    /// rather than a reused one: a pill can carry both, and one `AnyObject`
    /// holding two targets means whichever was assigned second is the only
    /// button that still fires.
    private var bubbleDestructiveTarget: AnyObject?
    /// The live dictation caption — a THIRD panel, one pill-slot above
    /// the prompt bubble's, that updates in place as the person speaks.
    /// Deliberately its own panel (not a reuse of `bubblePanel`): a
    /// stream must never evict a prompt mid-countdown, and a prompt
    /// ("Daisy is already recording") must be able to appear WHILE the
    /// caption is running. Nil when no dictation is streaming.
    private var captionPanel: NSPanel?
    private weak var captionLabel: NSTextField?
    /// When set, the panel stays hidden until this date — regardless of
    /// session status. Set by the right-click "Hide for…" menu. Backed by
    /// AppSettings so the suspension is persisted and survives an app
    /// relaunch — it used to be in-memory only, so quitting Daisy dropped
    /// the hide and the widget reappeared well before the chosen window.
    private var suspendedUntil: Date? {
        get { settings.floatingWidgetSuspendedUntil }
        set { settings.floatingWidgetSuspendedUntil = newValue }
    }

    init(session: RecordingSession, settings: AppSettings) {
        self.session = session
        self.settings = settings
        WidgetBubbleCenter.shared.host = self
        startObserving()
        startObservingSettings()
        // Silence-prompt UI used to live here as a custom NSPanel
        // anchored above the daisy widget. Retired 2026-05-18 in
        // favour of a native `UNUserNotification` banner — see
        // `SilencePromptNotification` and `SilenceMonitor`. AppKit
        // handles all positioning / dismissal for free.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.ensureOnScreen()
            }
        }
        // Re-arm a "Hide for…" suspension that was still pending when
        // Daisy last quit. The deadline was restored into AppSettings,
        // so show()'s guard already keeps the widget hidden; here we
        // just schedule the expiry so it reappears at the original time.
        if let until = suspendedUntil {
            if until > Date() {
                rearmSuspensionTimer(until: until)
            } else {
                suspendedUntil = nil
            }
        }
    }

    // MARK: - Lifecycle

    func show() {
        // Honour a user-set suspension — if we're still inside the
        // hide window, don't show even if the session goes busy.
        if let until = suspendedUntil, until > Date() {
            return
        } else if suspendedUntil != nil {
            suspendedUntil = nil  // expired, clear it
        }
        if panel == nil { buildPanel() }
        positionIfNeeded()
        panel?.orderFrontRegardless()
    }

    func hide() {
        // A callout anchored to a widget that's leaving has nothing to
        // point at — take it with the widget.
        hideBubble()
        panel?.orderOut(nil)
    }

    /// Hide the widget for `duration` seconds. Called from the widget's
    /// right-click menu. After the timer fires, visibility is re-derived
    /// from the current session status.
    func hideFor(_ duration: TimeInterval) {
        let until = Date().addingTimeInterval(duration)
        suspendedUntil = until
        hide()
        rearmSuspensionTimer(until: until)
    }

    /// Schedule the wake-up that lifts a "Hide for…" suspension when it
    /// expires. Shared by `hideFor` and by launch-time restoration, so a
    /// hide chosen in a previous run still ends at its original deadline
    /// rather than the moment Daisy was relaunched.
    private func rearmSuspensionTimer(until: Date) {
        Task { @MainActor [weak self] in
            let remaining = until.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard let self else { return }
            // The user may have changed their mind via "Show now"
            // elsewhere, or set a new, later suspension; only lift the
            // one whose deadline has actually passed.
            if let until = self.suspendedUntil, until <= Date() {
                self.suspendedUntil = nil
                self.applyVisibility(for: self.session.status)
            }
        }
    }

    // MARK: - Status observation

    /// Registers a one-shot observation callback that re-fires whenever
    /// `session.status` changes, so visibility tracks the model without
    /// polling.
    private func startObserving() {
        applyVisibility(for: session.status)
        withObservationTracking {
            _ = session.status
        } onChange: { [weak self] in
            // Weak at the OUTER closure — that's the reference the
            // observation registration actually retains. Unwrap here:
            // a weak capture is a mutable box, and Swift 6 forbids the
            // nested Task from capturing a captured `var` — so hand
            // the Task an immutable strong `self` instead (retains
            // the controller only for the duration of the hop).
            guard let self else { return }
            Task { @MainActor in
                self.applyVisibility(for: self.session.status)
                self.startObserving()
            }
        }
    }

    /// Parallel observation hook for `settings.floatingWidgetEnabled`.
    /// Re-applies visibility immediately so toggling the master
    /// switch in Settings shows/hides the panel without needing a
    /// session-status change to retrigger.
    private func startObservingSettings() {
        withObservationTracking {
            _ = settings.floatingWidgetEnabled
        } onChange: { [weak self] in
            // Weak at the outer closure, unwrapped before the Task —
            // see startObserving() for the rationale.
            guard let self else { return }
            Task { @MainActor in
                self.applyVisibility(for: self.session.status)
                self.startObservingSettings()
            }
        }
    }

    private func applyVisibility(for status: RecordingSession.Status) {
        // Master switch: the floating widget is opt-in (Settings →
        // Capture → "Show floating widget"). When OFF, the panel
        // never appears regardless of session state.
        //
        // When ON, the widget is visible across ALL session states
        // including `.idle`. Pre-1.0.3 the panel hid itself at
        // idle, which meant a freshly-launched Daisy with no
        // active recording showed nothing — users couldn't see
        // Daisy was running until they hit the hotkey blind.
        // Always-visible-when-enabled is the right default; users
        // who want it gone can flip the master switch off or
        // pick "Hide for N minutes" from the right-click menu.
        guard settings.floatingWidgetEnabled else {
            hide()
            return
        }
        show()
    }

    /// Re-evaluate visibility against the current session state.
    /// Called by MainView when `settings.floatingWidgetEnabled`
    /// flips, so the widget appears/disappears the moment the
    /// toggle changes without needing a status change to retrigger.
    func reevaluateVisibility() {
        applyVisibility(for: session.status)
    }

    // MARK: - Panel construction

    /// Borderless panel that moves with an explicit drag. The widget
    /// used to rely solely on `isMovableByWindowBackground`, but the
    /// SwiftUI hosting view claims ever more of the mouse pipeline with
    /// each macOS release (the daisy has tap + context-menu gestures),
    /// and on macOS 27 beta background-drag stopped working entirely
    /// (field report 2026-08-21). `mouseDragged` reaching the window
    /// means no view claimed the drag — hand it to `performDrag`, which
    /// moves the panel with correct screen clamping. Clicks still hit
    /// SwiftUI first, so tap-to-record and right-click are unaffected.
    private final class WidgetPanel: NSPanel {
        override func mouseDragged(with event: NSEvent) {
            performDrag(with: event)
        }
    }

    private func buildPanel() {
        let widget = DaisyWidget(
            session: session,
            onHideRequest: { [weak self] duration in
                self?.hideFor(duration)
            }
        )
        // Container is bigger than the daisy itself so the SwiftUI
        // drop-shadow has room to breathe — otherwise the panel's
        // content rect clips it into a hard rectangle.
        // Sized 59.84×59.84 (was 70.4; −15% 2026-06-05) to match the
        // active daisy geometry (canvasSize 49.5 → 42.075 in DaisyWidget,
        // same ×0.85). The shadow keeps proportional padding around the
        // active state, more for passive (the daisy still shrinks in
        // idle/finished).
        let container = ZStack {
            widget
        }
        .frame(width: 59.84, height: 59.84)
        let hosting = NSHostingController(rootView: container)
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = CGColor.clear

        let panel = WidgetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 59.84, height: 59.84),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Don't let AppKit draw its own rectangular window shadow — it
        // produces a visible rectangular halo around the round widget.
        // SwiftUI draws a tighter shadow that hugs the circle.
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentViewController = hosting
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = CGColor.clear

        self.panel = panel
    }

    /// Auto-position only on the very first show. After that, the user's
    /// manual drag wins — we never override their placement (except when
    /// the panel has fallen off all displays; see `ensureOnScreen`).
    private func positionIfNeeded() {
        guard let panel = panel, let screen = bestScreen() else { return }
        guard !hasPositionedOnce else {
            ensureOnScreen()
            return
        }
        hasPositionedOnce = true
        anchorBottomRight(panel: panel, on: screen)
    }

    private func ensureOnScreen() {
        guard let panel = panel else { return }
        let frame = panel.frame
        // If any visible screen still contains the centre of the panel,
        // we're fine. Otherwise recover to the bottom-right of the best
        // available screen.
        let centre = NSPoint(x: frame.midX, y: frame.midY)
        let onAnyScreen = NSScreen.screens.contains { $0.frame.contains(centre) }
        if !onAnyScreen, let screen = bestScreen() {
            anchorBottomRight(panel: panel, on: screen)
        }
    }

    /// Prefer the screen the cursor is on (matches user attention), then
    /// fall back to the system's `main` screen, then to whatever's first
    /// in the connected-displays list. Important on multi-display
    /// setups where `NSScreen.main` for a borderless non-key panel can
    /// silently return a different display than the user is using.
    private func bestScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let underCursor = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return underCursor
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Anchor at the bottom-right of the screen's visible frame —
    /// roughly Dock level. 80-pt margin sits comfortably in the
    /// corner without crowding the Dock or hugging the screen edge.
    /// Defensive clamp keeps it inside `visibleFrame` regardless of
    /// display scaling or notch.
    private func anchorBottomRight(panel: NSPanel, on screen: NSScreen) {
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let margin: CGFloat = 80

        let rawX = frame.maxX - size.width - margin
        let minX = frame.minX + margin
        let maxX = frame.maxX - size.width - 4   // tiny inner gutter
        let x = min(max(minX, rawX), maxX)

        let rawY = frame.minY + margin
        let maxY = frame.maxY - size.height - 4
        let y = min(max(frame.minY, rawY), maxY)

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Widget bubble

extension FloatingPanelController: WidgetBubbleHosting {

    /// The widget is on screen when the master switch is on, it isn't
    /// inside a "Hide for…" suspension, and the panel actually exists and
    /// is ordered in. This is the gate `WidgetBubbleCenter` reads to
    /// decide bubble-vs-notification.
    var isWidgetVisible: Bool {
        guard settings.floatingWidgetEnabled else { return false }
        if let until = suspendedUntil, until > Date() { return false }
        return panel?.isVisible == true
    }

    func showBubble(_ content: WidgetBubbleContent) {
        guard let screen = panel?.screen ?? bestScreen() else {
            Logger(subsystem: "app.essazanov.Daisy", category: "WidgetBubble")
                .error("showBubble: no screen to anchor to — bubble dropped")
            return
        }
        // Anchor to the live widget when it's on screen; otherwise to a
        // synthetic point in the bottom-right corner — where the widget
        // would live. The bubble must not silently vanish just because
        // the widget is hidden (field case 2026-08-21: auto-start ask
        // never appeared), so the widget is an anchor preference, not a
        // requirement.
        let anchorFrame: NSRect
        if let widget = panel, widget.isVisible {
            anchorFrame = widget.frame
        } else {
            let visible = screen.visibleFrame
            anchorFrame = NSRect(x: visible.maxX - 24, y: visible.minY + 24, width: 1, height: 1)
        }
        // Fresh panel each time — the content (and its captured action)
        // changes per prompt, and a 12 s-lived panel isn't worth pooling.
        hideBubble()

        // Plain AppKit content, deliberately. This surface went through
        // three invisible incarnations inside an NSHostingController
        // (300×1 sliver, then a correctly-sized panel whose SwiftUI
        // content still never painted on macOS 27 beta — field logs
        // 2026-08-21, `visible=true` with nothing on screen). Label +
        // button + layer card have no render pipeline to go wrong.
        let card = BubbleCardView()
        // The whole pill is the affordance: when the content carries an
        // action, a click anywhere accepts it (Egor, 2026-08-21 — aiming
        // at a 15 pt glyph to start recording is fiddly). Dismissal
        // stays on the ✕, which swallows its own mouseDown as an
        // NSButton subview. Action-less pills keep tap-to-dismiss.
        //
        // Hide BEFORE running the action, here and in both buttons below.
        // An action is allowed to put up a pill of its own (the
        // screenshot-note trash does, when the delete fails), and hiding
        // afterwards would tear that replacement straight back down.
        card.onTap = { [weak self] in
            self?.hideBubble()
            content.action?()
        }

        // Single-line pill, matched to the PASSIVE (mini) daisy: same
        // dark warm surface, same visual height (canvas 42 × 0.80 ≈ 34),
        // full end-cap rounding, the widget's white for text.
        // One line, never wrapped, never "…" — the pill grows to fit the
        // text (Egor, 2026-08-21). The near-required compression
        // resistance keeps the label whole; only the screen-width cap
        // below outranks it, and then the text clips rather than
        // ellipsizes.
        let label = NSTextField(labelWithString: content.text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = NSColor.white.withAlphaComponent(0.92)
        label.lineBreakMode = .byClipping
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.init(999), for: .horizontal)
        card.addSubview(label)

        var actionControl: NSView?
        if content.actionSymbol != nil || content.actionTitle != nil {
            let target = BubbleActionTarget { [weak self] in
                self?.hideBubble()
                content.action?()
            }
            bubbleActionTarget = target
            let button: NSButton
            if let symbol = content.actionSymbol {
                let image = NSImage(systemSymbolName: symbol, accessibilityDescription: content.actionTitle)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
                button = NSButton(image: image ?? NSImage(), target: target, action: #selector(BubbleActionTarget.fire))
                button.toolTip = content.actionTitle
            } else {
                button = NSButton(title: content.actionTitle ?? "", target: target, action: #selector(BubbleActionTarget.fire))
                button.font = .systemFont(ofSize: 12, weight: .semibold)
            }
            button.isBordered = false
            button.contentTintColor = NSColor(Color.daisyAccent)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            card.addSubview(button)
            actionControl = button
        }

        // Throw-it-away affordance, for a pill announcing something Daisy
        // just created. Deliberately NOT another glyph in the ✕'s clothing:
        // the ✕ leaves the artifact alone, this deletes it, and the two
        // must not be a coin flip. Trash glyph, error colour, its own
        // target, and it sits inboard of the ✕ so the muscle-memory
        // "dismiss is the far-right thing" stays true.
        var destructiveControl: NSView?
        if let destructiveAction = content.destructiveAction {
            let target = BubbleActionTarget { [weak self] in
                self?.hideBubble()
                destructiveAction()
            }
            bubbleDestructiveTarget = target
            let image = NSImage(systemSymbolName: "trash", accessibilityDescription: content.destructiveTitle)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
            let button = NSButton(
                image: image ?? NSImage(),
                target: target,
                action: #selector(BubbleActionTarget.fire)
            )
            button.toolTip = content.destructiveTitle
            button.isBordered = false
            button.contentTintColor = NSColor(Color.daisyError)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            card.addSubview(button)
            destructiveControl = button
        }

        // Close affordance: an ✕ inside a countdown ring that unwinds
        // over the bubble's lifetime — "act now or this goes away".
        let closeButton = CountdownCloseButton(diameter: 22)
        closeButton.onTap = { [weak self] in self?.hideBubble() }
        card.addSubview(closeButton)

        let pillHeight: CGFloat = 34
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: pillHeight),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            // Only cap: the physical screen. Normal texts size the pill
            // freely; a pathological one clips against this, no "…".
            card.widthAnchor.constraint(
                lessThanOrEqualToConstant: screen.visibleFrame.width - 80
            )
        ])
        // Right-to-left chain: ✕, then the trash if there is one, then
        // whatever comes before it. Written as a moving anchor so adding
        // a control never means re-deriving the other two constraints.
        var trailingNeighbour = closeButton.leadingAnchor
        if let destructiveControl {
            NSLayoutConstraint.activate([
                // 12, not the 8 the action button gets. The two glyphs
                // either side of this gap have wildly asymmetric costs:
                // slipping off the trash onto the ✕ costs nothing,
                // slipping off the ✕ onto the trash destroys the note.
                destructiveControl.trailingAnchor.constraint(equalTo: trailingNeighbour, constant: -12),
                destructiveControl.centerYAnchor.constraint(equalTo: card.centerYAnchor)
            ])
            trailingNeighbour = destructiveControl.leadingAnchor
        }
        if let actionControl {
            NSLayoutConstraint.activate([
                actionControl.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
                actionControl.trailingAnchor.constraint(equalTo: trailingNeighbour, constant: -8),
                actionControl.centerYAnchor.constraint(equalTo: card.centerYAnchor)
            ])
        } else {
            label.trailingAnchor.constraint(equalTo: trailingNeighbour, constant: -8).isActive = true
        }

        card.layoutSubtreeIfNeeded()
        var fitting = card.fittingSize
        if fitting.width < 40 || fitting.height < 20 {
            fitting = NSSize(width: 300, height: pillHeight)
        }
        card.translatesAutoresizingMaskIntoConstraints = true
        card.frame = NSRect(origin: .zero, size: fitting)
        card.autoresizingMask = [.width, .height]

        let bubble = NSPanel(
            contentRect: NSRect(origin: .zero, size: fitting),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        bubble.isOpaque = false
        bubble.backgroundColor = .clear
        // AppKit's own shadow follows the rounded layer well enough —
        // the SwiftUI drop shadow left with the hosting view.
        bubble.hasShadow = true
        bubble.level = .floating
        bubble.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        bubble.isReleasedWhenClosed = false
        bubble.hidesOnDeactivate = false
        bubble.ignoresMouseEvents = false
        bubble.contentView = card
        bubble.setContentSize(fitting)

        positionBubble(bubble, over: anchorFrame, on: screen)
        bubble.orderFrontRegardless()
        closeButton.startCountdown(content.autoDismiss)
        bubblePanel = bubble
        bubbleCloseButton = closeButton
        bubbleAutoDismiss = content.autoDismiss
        Logger(subsystem: "app.essazanov.Daisy", category: "WidgetBubble").info(
            "showBubble: frame=\(String(describing: bubble.frame), privacy: .public) fitting=\(String(describing: fitting), privacy: .public) anchor=\(String(describing: anchorFrame), privacy: .public) visible=\(bubble.isVisible, privacy: .public) screen=\(String(describing: screen.visibleFrame), privacy: .public)"
        )

        bubbleDismissTimer = Timer.scheduledTimer(
            withTimeInterval: content.autoDismiss, repeats: false
        ) { [weak self] _ in
            // The inner `[weak self]` re-capture is REQUIRED under Swift 6:
            // referencing the outer closure's captured `self` from inside
            // the concurrent `Task` is an error otherwise.
            Task { @MainActor [weak self] in self?.hideBubble() }
        }
    }

    func hideBubble() {
        bubbleDismissTimer?.invalidate()
        bubbleDismissTimer = nil
        bubblePanel?.orderOut(nil)
        bubblePanel = nil
        bubbleActionTarget = nil
        bubbleDestructiveTarget = nil
        bubbleCloseButton = nil
    }

    /// Freeze the bubble's lifetime — ring stops unwinding, the dismiss
    /// timer dies. Used while a dictation hold is feeding the screenshot
    /// note: the prompt must not expire under the person mid-sentence
    /// (Egor, 2026-08-21).
    func pauseBubbleCountdown() {
        bubbleDismissTimer?.invalidate()
        bubbleDismissTimer = nil
        bubbleCloseButton?.pauseCountdown()
    }

    /// Un-freeze: restart the ring and the dismiss timer from the FULL
    /// original duration. Deliberately not "resume from where it was" —
    /// after a failed dictation the person needs the whole window again,
    /// and a ring that jumps back to full reads as "you have time", which
    /// is the truth.
    func restartBubbleCountdown() {
        guard bubblePanel != nil else { return }
        bubbleCloseButton?.startCountdown(bubbleAutoDismiss)
        bubbleDismissTimer?.invalidate()
        bubbleDismissTimer = Timer.scheduledTimer(
            withTimeInterval: bubbleAutoDismiss, repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hideBubble() }
        }
    }

    // MARK: - Live dictation caption

    /// Update (creating on first call) the caption pill with the running
    /// dictation text. Same visual language as the prompt pill (dark warm
    /// card, 34 pt, white text) but strictly passive: it ignores mouse
    /// events entirely — mid-dictation the person's next click belongs to
    /// the app they're dictating INTO, and a pill that swallows it would
    /// be worse than no pill. Head-truncated so the freshest words win
    /// when the line outgrows the width cap.
    func updateLiveCaption(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let screen = panel?.screen ?? bestScreen() else { return }

        let pillHeight: CGFloat = 34
        let hPad: CGFloat = 14
        // Width cap: readable, not a marquee across the display.
        let widthCap = min(screen.visibleFrame.width - 80, 560)

        if captionPanel == nil {
            let card = BubbleCardView()
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12)
            label.textColor = NSColor.white.withAlphaComponent(0.92)
            label.lineBreakMode = .byTruncatingHead
            label.maximumNumberOfLines = 1
            label.isSelectable = false
            card.addSubview(label)

            let caption = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: pillHeight),
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            caption.isOpaque = false
            caption.backgroundColor = .clear
            caption.hasShadow = true
            caption.level = .floating
            caption.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            caption.isReleasedWhenClosed = false
            caption.hidesOnDeactivate = false
            caption.ignoresMouseEvents = true
            caption.contentView = card
            captionPanel = caption
            captionLabel = label
        }
        guard let caption = captionPanel, let label = captionLabel else { return }

        label.stringValue = trimmed
        let textSize = label.attributedStringValue.size()
        let width = min(ceil(textSize.width) + hPad * 2, widthCap)
        let size = NSSize(width: max(width, 60), height: pillHeight)
        caption.contentView?.frame = NSRect(origin: .zero, size: size)
        // Center the single line vertically ourselves — an NSTextField
        // cell given the pill's full height top-aligns its text.
        let labelHeight = ceil(textSize.height)
        label.frame = NSRect(
            x: hPad,
            y: (pillHeight - labelHeight) / 2,
            width: size.width - hPad * 2,
            height: labelHeight
        )
        caption.setContentSize(size)

        // One pill-slot above where a prompt bubble would sit, so the
        // two surfaces can coexist (e.g. "Daisy is already recording"
        // during a dictation). Same dumb math as `positionBubble`,
        // nudged up by a pill height + gap.
        let anchorFrame: NSRect
        if let widget = panel, widget.isVisible {
            anchorFrame = widget.frame
        } else {
            let visible = screen.visibleFrame
            anchorFrame = NSRect(x: visible.maxX - 24, y: visible.minY + 24, width: 1, height: 1)
        }
        positionBubble(caption, over: anchorFrame, on: screen)
        var origin = caption.frame.origin
        origin.y = min(
            origin.y + pillHeight + 7,
            screen.visibleFrame.maxY - pillHeight - 4
        )
        caption.setFrameOrigin(origin)
        if !caption.isVisible { caption.orderFrontRegardless() }
    }

    func hideLiveCaption() {
        captionPanel?.orderOut(nil)
        captionPanel = nil
        captionLabel = nil
    }

    /// The bubble's card: a full-end-cap pill in the daisy widget's own
    /// dark warm circle color (same in both appearances — the widget's
    /// circle doesn't theme either). Tap anywhere that isn't the button
    /// dismisses.
    private final class BubbleCardView: NSView {
        var onTap: (() -> Void)?

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerCurve = .continuous
            // The widget's circle fill — see DaisyWidget's passive body.
            layer?.backgroundColor = NSColor(
                red: 28.0 / 255, green: 26.0 / 255, blue: 23.0 / 255, alpha: 1
            ).cgColor
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            // Pill: end caps fully rounded whatever the height ends up.
            layer?.cornerRadius = bounds.height / 2
        }

        override func mouseDown(with event: NSEvent) {
            onTap?()
        }
    }

    /// Objc trampoline for the bubble's action button —
    /// `FloatingPanelController` isn't an NSObject, so it can't be a
    /// target itself. Retained in `bubbleActionTarget` for the bubble's
    /// lifetime.
    private final class BubbleActionTarget: NSObject {
        private let onFire: () -> Void
        init(onFire: @escaping () -> Void) { self.onFire = onFire }
        /// The closure ends in `hideBubble()`, which nils the controller's
        /// only strong reference to THIS object (`NSControl.target` is
        /// weak) while the closure is still on the stack. Copy it out
        /// first so its captured context outlives the target that held it.
        @objc func fire() {
            let run = onFire
            run()
        }
    }

    /// ✕ inside a countdown ring. The ring starts full and unwinds
    /// clockwise over the bubble's lifetime — a visible "answer now or
    /// this closes itself". Tap = dismiss. Pure CALayer, no SwiftUI.
    private final class CountdownCloseButton: NSView {
        var onTap: (() -> Void)?
        private let ringLayer = CAShapeLayer()

        init(diameter: CGFloat) {
            super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
            wantsLayer = true
            translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: diameter),
                heightAnchor.constraint(equalToConstant: diameter)
            ])

            let inset: CGFloat = 1.5
            let center = CGPoint(x: diameter / 2, y: diameter / 2)
            let radius = diameter / 2 - inset

            // Faint full track under the countdown arc.
            let track = CAShapeLayer()
            track.path = CGPath(
                ellipseIn: CGRect(x: inset, y: inset, width: radius * 2, height: radius * 2),
                transform: nil
            )
            track.fillColor = NSColor.clear.cgColor
            track.strokeColor = NSColor.white.withAlphaComponent(0.16).cgColor
            track.lineWidth = 1.5
            layer?.addSublayer(track)

            // Countdown arc — starts at 12 o'clock, unwinds visually
            // clockwise (negative angular direction in y-up coords).
            let path = CGMutablePath()
            path.addArc(
                center: center,
                radius: radius,
                startAngle: .pi / 2,
                endAngle: .pi / 2 - 2 * .pi,
                clockwise: true
            )
            ringLayer.path = path
            ringLayer.fillColor = NSColor.clear.cgColor
            ringLayer.strokeColor = NSColor.white.withAlphaComponent(0.72).cgColor
            ringLayer.lineWidth = 1.5
            ringLayer.lineCap = .round
            layer?.addSublayer(ringLayer)

            let xImage = NSImageView()
            xImage.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold))
            xImage.contentTintColor = NSColor.white.withAlphaComponent(0.72)
            xImage.frame = bounds
            xImage.autoresizingMask = [.width, .height]
            addSubview(xImage)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        func startCountdown(_ seconds: TimeInterval) {
            // Reset any paused clock (see pauseCountdown) before a fresh run.
            ringLayer.speed = 1
            ringLayer.timeOffset = 0
            ringLayer.beginTime = 0
            ringLayer.removeAnimation(forKey: "countdown")
            ringLayer.strokeEnd = 0
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = 1
            animation.toValue = 0
            animation.duration = seconds
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            ringLayer.add(animation, forKey: "countdown")
        }

        /// Freeze the ring mid-unwind (standard CA pause: zero the layer
        /// clock at the current media time). `startCountdown` resets it.
        func pauseCountdown() {
            let paused = ringLayer.convertTime(CACurrentMediaTime(), from: nil)
            ringLayer.speed = 0
            ringLayer.timeOffset = paused
        }

        override func mouseDown(with event: NSEvent) {
            onTap?()
        }

        /// The ✕ must NEVER be click-dead: the NSImageView child could
        /// otherwise win hit-testing and swallow the mouseDown, and
        /// with a whole-pill tap meaning ACCEPT, a dead ✕ would leave
        /// no way to decline the ask. Claim every hit in our bounds
        /// for the button itself.
        override func hitTest(_ point: NSPoint) -> NSView? {
            super.hitTest(point) != nil ? self : nil
        }
    }

    /// Place the pill to the LEFT of the widget, vertically centered on
    /// it — it reads as the daisy speaking. If there's no room on the
    /// left (widget dragged to the left edge), flip to the right. Then
    /// clamp whole into the visible frame; the clamp stays the entire
    /// safety net, no tail, no further side-awareness.
    private func positionBubble(_ bubble: NSPanel, over widgetFrame: NSRect, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = bubble.frame.size
        let gap: CGFloat = 7

        var x = widgetFrame.minX - gap - size.width
        if x < visible.minX + 4 {
            x = widgetFrame.maxX + gap
        }
        var y = widgetFrame.midY - size.height / 2

        // Clamp into the visible frame on both axes.
        x = min(max(visible.minX + 4, x), visible.maxX - size.width - 4)
        y = min(max(visible.minY + 4, y), visible.maxY - size.height - 4)

        bubble.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
