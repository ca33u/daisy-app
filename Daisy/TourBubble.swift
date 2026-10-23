//
//  TourBubble.swift
//  Daisy
//
//  The first-run tour's coach mark (Onboarding 2.0, Egor 23–24.10):
//  Daisy speaks in the first person from a dark card beside the floating
//  widget, with a small arrow pointing at her. Unlike `WidgetBubble`'s
//  one-line pill — a prompt that expires — this one wraps, carries a
//  step counter and up to two buttons, and stays until the tour moves on.
//
//  Plain AppKit for the same reason the widget pill is: SwiftUI content
//  inside a borderless panel never painted on macOS 27 beta (see
//  `FloatingPanelController.showBubble`). The look is the approved
//  prototype's `.bubble`: #1C1A17 card, 14 pt body, «4 из 9», pill
//  buttons, 14 pt radius, soft shadow — always dark, in either appearance.
//
//  FOLLOWING THE WIDGET. The card is a child window of the widget panel,
//  so AppKit carries it along while the widget is dragged; every move of
//  the widget also re-runs the placement, which flips the card to the
//  other side when the widget nears a screen edge.
//

import AppKit
import os

/// What the coach mark says on one step of the tour.
struct TourBubbleContent {
    struct Action {
        let title: String
        let run: @MainActor () -> Void
    }

    /// Daisy's line. One span may be wrapped in `**…**` — it's drawn in
    /// the brand amber (the prototype's `<em>`); the markers never show.
    var text: String
    var step: Int
    var total: Int
    /// The light pill — «Дальше».
    var primary: Action?
    /// The ghost button beside it — «Пропустить».
    var secondary: Action?
    /// While set, the card is waiting for the person to DO something
    /// («зажми fn»): a pulsing dot and this text replace the buttons.
    var waiting: String?

    init(
        text: String,
        step: Int,
        total: Int,
        primary: Action? = nil,
        secondary: Action? = nil,
        waiting: String? = nil
    ) {
        self.text = text
        self.step = step
        self.total = total
        self.primary = primary
        self.secondary = secondary
        self.waiting = waiting
    }

    /// The buttons actually drawn, primary first. Empty while waiting —
    /// a step that waits for a key hold has nothing to click.
    var visibleActions: [(action: Action, isPrimary: Bool)] {
        guard waiting == nil else { return [] }
        var actions: [(action: Action, isPrimary: Bool)] = []
        if let primary { actions.append((primary, true)) }
        if let secondary { actions.append((secondary, false)) }
        return actions
    }

    /// `text` without the `**` markers, and where the emphasised span
    /// sits in it (UTF-16, for `NSAttributedString`). An unpaired marker
    /// is left as typed rather than guessed at.
    static func parse(_ text: String) -> (plain: String, emphasis: NSRange?) {
        let marker = "**"
        guard let open = text.range(of: marker),
              let close = text.range(of: marker, range: open.upperBound..<text.endIndex)
        else { return (text, nil) }
        let before = String(text[..<open.lowerBound])
        let span = String(text[open.upperBound..<close.lowerBound])
        let after = String(text[close.upperBound...])
        let plain = before + span + after
        let range = NSRange(location: (before as NSString).length, length: (span as NSString).length)
        return (plain, range.length > 0 ? range : nil)
    }
}

/// Where the card goes relative to the widget. Pure, so the flip and the
/// clamps can be tested without a screen.
nonisolated enum TourBubbleLayout {
    /// Which side of the widget the card sits on.
    enum Side: Equatable { case left, right }

    struct Placement: Equatable {
        /// The panel's frame — card plus the arrow's protrusion.
        var frame: NSRect
        var side: Side
        /// Arrow centre, measured up from the panel's bottom edge.
        var arrowY: CGFloat
    }

    static let maxCardWidth: CGFloat = 340
    static let minCardWidth: CGFloat = 220
    static let cornerRadius: CGFloat = 14
    /// How far the arrow (a 16 pt square turned 45°) sticks out of the card.
    static let arrowProtrusion: CGFloat = 11
    /// Air between the arrow's side of the panel and the widget's frame.
    /// The widget panel already has ~9 pt of shadow room around the disc.
    static let widgetGap: CGFloat = 2
    /// The arrow sits this far above the card's bottom when nothing
    /// pushes it — the card rises from the widget (the prototype's
    /// `bottom: 22px` arrow, centred 30 up).
    static let arrowRestY: CGFloat = 30
    /// Closest the arrow's centre may come to the card's top or bottom,
    /// so it never sprouts from a rounded corner.
    static let arrowInset: CGFloat = 24
    static let screenInset: CGFloat = 8

    /// Prefer the widget's left — the card reads as Daisy speaking, and
    /// the widget's default home is the bottom-right corner. Flip right
    /// when the left doesn't fit; with no room either side, take the
    /// roomier one and clamp. Vertically the card rises from the widget
    /// and is clamped whole into the visible frame, the arrow sliding to
    /// keep pointing at the widget as far as the card's corners allow.
    static func place(cardSize: NSSize, widget: NSRect, visible: NSRect) -> Placement {
        let size = NSSize(width: cardSize.width + arrowProtrusion, height: cardSize.height)

        let leftX = widget.minX - widgetGap - size.width
        let rightX = widget.maxX + widgetGap
        let fitsLeft = leftX >= visible.minX + screenInset
        let fitsRight = rightX + size.width <= visible.maxX - screenInset
        let side: Side
        if fitsLeft {
            side = .left
        } else if fitsRight {
            side = .right
        } else {
            side = (widget.minX - visible.minX) >= (visible.maxX - widget.maxX) ? .left : .right
        }
        var x = side == .left ? leftX : rightX
        x = clamp(x, visible.minX + screenInset, visible.maxX - size.width - screenInset)

        var y = widget.midY - arrowRestY
        y = clamp(y, visible.minY + screenInset, visible.maxY - size.height - screenInset)

        let arrowY: CGFloat
        if size.height >= arrowInset * 2 {
            arrowY = clamp(widget.midY - y, arrowInset, size.height - arrowInset)
        } else {
            arrowY = size.height / 2
        }
        return Placement(frame: NSRect(origin: NSPoint(x: x, y: y), size: size), side: side, arrowY: arrowY)
    }

    /// `lo` wins when the range is inverted (a screen too small for the
    /// card) — the card's bottom-left stays on screen.
    private static func clamp(_ value: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        max(lo, min(value, hi))
    }
}

/// Shows the tour's coach mark beside the widget. The tour owns the
/// script; this owns the panel.
@MainActor
final class TourBubbleCenter {
    static let shared = TourBubbleCenter()
    private init() {}

    private var panel: NSPanel?
    private var bubbleView: TourBubbleView?
    /// The widget panel the card is attached to as a child, when it is.
    private weak var parentWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []

    var isShowing: Bool { panel != nil }

    /// Put the card up with `content`; a card already showing just takes
    /// the new content (same as `update`).
    func show(_ content: TourBubbleContent) {
        guard !TestHost.isActive else { return }
        if panel != nil {
            update(content)
            return
        }
        let view = TourBubbleView(content: content)
        let panel = TourBubblePanel(
            contentRect: NSRect(origin: .zero, size: view.frame.size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // AppKit's shadow follows the card-plus-arrow silhouette.
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // The card is always dark; anything AppKit draws itself should be too.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = view
        panel.alphaValue = 0
        self.panel = panel
        self.bubbleView = view

        reposition()
        panel.orderFrontRegardless()
        attachToWidget()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }
        observeWidget()
    }

    /// New content in the same panel — no fade, no flicker. Does nothing
    /// when no card is showing: a late callback from a step the tour has
    /// already left must not resurrect the card.
    func update(_ content: TourBubbleContent) {
        guard let panel, let bubbleView else { return }
        panel.disableScreenUpdatesUntilFlush()
        bubbleView.apply(content)
        reposition()
    }

    /// The widget hid or came back (`FloatingPanelController.show/hide`).
    /// A child window would vanish with its parent — and a waiting step
    /// would wait on a card nobody sees — so on hide the card lets go and
    /// moves to the corner the widget lives in; on show it re-attaches.
    func widgetVisibilityChanged() {
        guard let panel else { return }
        if WidgetBubbleCenter.shared.host?.widgetWindow == nil, let parentWindow {
            parentWindow.removeChildWindow(panel)
            self.parentWindow = nil
        }
        reposition()
        attachToWidget()
        panel.orderFrontRegardless()
    }

    func hide() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let panel {
            parentWindow?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        parentWindow = nil
        panel = nil
        bubbleView = nil
    }

    // MARK: - Placement

    /// Re-run the placement against the widget's current frame — after
    /// every widget move, screen change and content change.
    private func reposition() {
        guard let panel, let bubbleView else { return }
        let (widget, screen) = anchor()
        guard let screen else {
            Logger(subsystem: "app.essazanov.Daisy", category: "TourBubble")
                .error("reposition: no screen to anchor to")
            return
        }
        let placement = TourBubbleLayout.place(
            cardSize: bubbleView.cardSize, widget: widget, visible: screen.visibleFrame
        )
        bubbleView.setArrow(side: placement.side, y: placement.arrowY)
        panel.setFrame(placement.frame, display: true)
        bubbleView.frame = NSRect(origin: .zero, size: placement.frame.size)
        bubbleView.layoutSubtreeIfNeeded()
        // Next turn: the new silhouette (arrow flipped, card resized)
        // reaches the backing store only at the next CA commit, and a
        // shadow taken now would trace the old one.
        DispatchQueue.main.async { [weak panel] in
            CATransaction.flush()
            panel?.invalidateShadow()
        }
    }

    /// The widget's frame and screen. While the widget is hidden (the
    /// tour is expected to keep it on), the card points at the corner
    /// the widget would occupy — same fallback as the prompt pill.
    private func anchor() -> (NSRect, NSScreen?) {
        if let frame = WidgetBubbleCenter.shared.host?.widgetFrame {
            let centre = NSPoint(x: frame.midX, y: frame.midY)
            let screen = NSScreen.screens.first { $0.frame.contains(centre) } ?? NSScreen.main
            return (frame, screen)
        }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero
        return (NSRect(x: visible.maxX - 80 - 60, y: visible.minY + 80, width: 60, height: 60), screen)
    }

    /// Child of the widget panel, so a drag carries the card along live;
    /// the move observer then re-places it (flip, clamp) as it goes.
    private func attachToWidget() {
        guard let panel,
              let widget = WidgetBubbleCenter.shared.host?.widgetWindow,
              widget.isVisible,
              widget !== parentWindow
        else { return }
        parentWindow?.removeChildWindow(panel)
        widget.addChildWindow(panel, ordered: .above)
        parentWindow = widget
    }

    private func observeWidget() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didMoveNotification, object: nil, queue: .main
        ) { [weak self] note in
            let moved = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let moved,
                      moved === WidgetBubbleCenter.shared.host?.widgetWindow else { return }
                self.reposition()
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.attachToWidget()
                self?.reposition()
            }
        })
    }
}

/// Never key, never main — the person's typing stays where it was
/// (the practice field, their own app).
private final class TourBubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Card view

/// The card: background silhouette, header («🌼 DAISY · 4 из 9»), Daisy's
/// line, and the button / waiting row. Frame-based layout — the card's
/// size is measured once per content and the panel is sized to it.
final class TourBubbleView: NSView {
    private enum Metrics {
        static let padTop: CGFloat = 14
        static let padBottom: CGFloat = 12
        static let padH: CGFloat = 16
        static let headerHeight: CGFloat = 14
        static let headerGap: CGFloat = 6
        static let rowGap: CGFloat = 10
        static let rowHeight: CGFloat = 27
        static let buttonSpacing: CGFloat = 8
    }

    enum Palette {
        static let card = NSColor(red: 28 / 255, green: 26 / 255, blue: 23 / 255, alpha: 1)       // #1C1A17
        static let ink = NSColor(red: 245 / 255, green: 243 / 255, blue: 239 / 255, alpha: 1)      // #F5F3EF
        static let brand = NSColor(red: 245 / 255, green: 161 / 255, blue: 75 / 255, alpha: 1)     // #F5A14B
        static let secondary = NSColor(red: 189 / 255, green: 182 / 255, blue: 171 / 255, alpha: 1) // #BDB6AB
        static let pill = NSColor(red: 243 / 255, green: 239 / 255, blue: 232 / 255, alpha: 1)     // #F3EFE8
    }

    private(set) var content: TourBubbleContent
    /// The card's own size, arrow excluded — what `TourBubbleLayout` places.
    private(set) var cardSize: NSSize = .zero
    private var side: TourBubbleLayout.Side = .left
    private var arrowY: CGFloat = TourBubbleLayout.arrowRestY

    private let shape = TourBubbleShapeView()
    private let header = NSView()
    private let headerIcon = NSImageView()
    private let headerName = NSTextField(labelWithString: "")
    private let counter = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let row = NSView()
    /// The pills currently drawn, primary first. Internal for tests.
    private(set) var pillButtons: [TourPillButton] = []
    /// The pulsing-dot row, when the content is waiting. Internal for tests.
    private(set) var waitingView: TourWaitingView?
    /// A pill fired and its action hasn't run yet — further clicks are
    /// dropped so a double-click can't skip two steps.
    private var isFiring = false

    init(content: TourBubbleContent) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true

        addSubview(shape)

        headerIcon.image = NSImage(named: "DaisyMark")
        headerIcon.imageScaling = .scaleProportionallyUpOrDown
        headerIcon.contentTintColor = Palette.secondary
        header.addSubview(headerIcon)
        // «DAISY» set like the prototype's `.who`: 11 pt, uppercase,
        // tracked out — the small-caps feel without a small-caps font.
        headerName.attributedStringValue = NSAttributedString(string: "DAISY", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: Palette.secondary,
            .kern: 0.9
        ])
        header.addSubview(headerName)
        counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        counter.textColor = Palette.secondary
        counter.alignment = .right
        header.addSubview(counter)
        addSubview(header)

        body.isSelectable = false
        body.drawsBackground = false
        body.isBordered = false
        addSubview(body)
        addSubview(row)

        apply(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Swap in new content and re-measure. The caller re-places the panel.
    func apply(_ content: TourBubbleContent) {
        self.content = content
        isFiring = false

        counter.stringValue = String(localized: "\(content.step) of \(content.total)")
        body.attributedStringValue = Self.bodyString(content.text)

        row.subviews.forEach { $0.removeFromSuperview() }
        pillButtons = []
        waitingView = nil
        if let waiting = content.waiting {
            let view = TourWaitingView(text: waiting)
            row.addSubview(view)
            waitingView = view
        } else {
            for (action, isPrimary) in content.visibleActions {
                let button = TourPillButton(title: action.title, isPrimary: isPrimary)
                button.onPress = { [weak self] in self?.fire(action) }
                row.addSubview(button)
                pillButtons.append(button)
            }
        }
        cardSize = measure()
        frame.size = NSSize(width: cardSize.width + TourBubbleLayout.arrowProtrusion, height: cardSize.height)
        needsLayout = true
    }

    func setArrow(side: TourBubbleLayout.Side, y: CGFloat) {
        self.side = side
        self.arrowY = y
        needsLayout = true
    }

    private var hasRow: Bool { waitingView != nil || !pillButtons.isEmpty }

    private var rowContentWidth: CGFloat {
        if let waitingView { return waitingView.fittingWidth }
        guard !pillButtons.isEmpty else { return 0 }
        return pillButtons.reduce(0) { $0 + $1.fittingWidth }
            + Metrics.buttonSpacing * CGFloat(pillButtons.count - 1)
    }

    /// Narrow for a short line («Слушаю…»), up to 340 for a paragraph.
    private func measure() -> NSSize {
        let maxInner = TourBubbleLayout.maxCardWidth - Metrics.padH * 2
        let minInner = TourBubbleLayout.minCardWidth - Metrics.padH * 2
        let cell = body.cell ?? NSTextFieldCell()
        let natural = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 10_000)).width
        let inner = min(maxInner, max(minInner, ceil(natural), rowContentWidth))
        let bodyHeight = ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 10_000)).height)
        var height = Metrics.padTop + Metrics.headerHeight + Metrics.headerGap + bodyHeight + Metrics.padBottom
        if hasRow { height += Metrics.rowGap + Metrics.rowHeight }
        return NSSize(width: inner + Metrics.padH * 2, height: height)
    }

    override func layout() {
        super.layout()
        let protrusion = TourBubbleLayout.arrowProtrusion
        let card = NSRect(
            x: side == .left ? 0 : protrusion, y: 0,
            width: cardSize.width, height: cardSize.height
        )
        shape.frame = bounds
        shape.update(card: card, arrowAt: NSPoint(x: side == .left ? card.maxX : card.minX, y: arrowY))

        let inner = card.insetBy(dx: Metrics.padH, dy: 0)
        var top = card.maxY - Metrics.padTop

        header.frame = NSRect(x: inner.minX, y: top - Metrics.headerHeight, width: inner.width, height: Metrics.headerHeight)
        headerIcon.frame = NSRect(x: 0, y: 1, width: 12, height: 12)
        let nameSize = headerName.fittingSize
        headerName.frame = NSRect(x: 20, y: (Metrics.headerHeight - nameSize.height) / 2, width: nameSize.width, height: nameSize.height)
        let counterSize = counter.fittingSize
        counter.frame = NSRect(
            x: inner.width - counterSize.width, y: (Metrics.headerHeight - counterSize.height) / 2,
            width: counterSize.width, height: counterSize.height
        )
        top -= Metrics.headerHeight + Metrics.headerGap

        let bodyHeight = ceil((body.cell ?? NSTextFieldCell())
            .cellSize(forBounds: NSRect(x: 0, y: 0, width: inner.width, height: 10_000)).height)
        body.preferredMaxLayoutWidth = inner.width
        body.frame = NSRect(x: inner.minX, y: top - bodyHeight, width: inner.width, height: bodyHeight)
        top -= bodyHeight

        row.isHidden = !hasRow
        if hasRow {
            top -= Metrics.rowGap
            row.frame = NSRect(x: inner.minX, y: top - Metrics.rowHeight, width: inner.width, height: Metrics.rowHeight)
            if let waitingView {
                waitingView.frame = NSRect(x: 0, y: 0, width: waitingView.fittingWidth, height: Metrics.rowHeight)
            }
            var x: CGFloat = 0
            for button in pillButtons {
                button.frame = NSRect(x: x, y: 0, width: button.fittingWidth, height: Metrics.rowHeight)
                x += button.fittingWidth + Metrics.buttonSpacing
            }
        }
    }

    /// Run the action on the next turn of the run loop: it will usually
    /// `update` or `hide` this very card, which must not happen while the
    /// pill that was clicked is still inside its own `mouseUp`.
    private func fire(_ action: TourBubbleContent.Action) {
        guard !isFiring else { return }
        isFiring = true
        Task { @MainActor [weak self] in
            action.run()
            self?.isFiring = false
        }
    }

    private static func bodyString(_ text: String) -> NSAttributedString {
        let (plain, emphasis) = TourBubbleContent.parse(text)
        let paragraph = NSMutableParagraphStyle()
        // 14 pt at the prototype's 1.45 line height.
        paragraph.lineSpacing = 3.5
        paragraph.lineBreakMode = .byWordWrapping
        let string = NSMutableAttributedString(string: plain, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: Palette.ink,
            .paragraphStyle: paragraph
        ])
        if let emphasis {
            string.addAttribute(.foregroundColor, value: Palette.brand, range: emphasis)
        }
        return string
    }
}

/// The card's silhouette: a 14 pt rounded rect plus the arrow, a 16 pt
/// square (3 pt corners) turned 45° and centred on the card's edge — one
/// filled path, so the window shadow traces both as a single shape.
private final class TourBubbleShapeView: NSView {
    private let shapeLayer = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        shapeLayer.fillColor = TourBubbleView.Palette.card.cgColor
        layer?.addSublayer(shapeLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// A hand-added layer doesn't follow the window to Retina by itself.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        shapeLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    func update(card: NSRect, arrowAt centre: NSPoint) {
        let path = CGMutablePath()
        let radius = TourBubbleLayout.cornerRadius
        path.addRoundedRect(in: card, cornerWidth: radius, cornerHeight: radius)
        let arrow = CGRect(x: -8, y: -8, width: 16, height: 16)
        let turn = CGAffineTransform(translationX: centre.x, y: centre.y).rotated(by: .pi / 4)
        path.addRoundedRect(in: arrow, cornerWidth: 3, cornerHeight: 3, transform: turn)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer.frame = bounds
        shapeLayer.path = path
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A pill: light on dark for the primary, text-only for the ghost.
/// Fires on mouse-up inside, like a real button; reachable by VoiceOver.
final class TourPillButton: NSView {
    let title: String
    let isPrimary: Bool
    var onPress: (() -> Void)?
    private let label: NSTextField
    private static let padH: CGFloat = 12

    init(title: String, isPrimary: Bool) {
        self.title = title
        self.isPrimary = isPrimary
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 12.5, weight: isPrimary ? .semibold : .medium)
        label.textColor = isPrimary ? TourBubbleView.Palette.card : TourBubbleView.Palette.secondary
        label.setAccessibilityElement(false)
        addSubview(label)
        if isPrimary {
            layer?.backgroundColor = TourBubbleView.Palette.pill.cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var fittingWidth: CGFloat { ceil(label.fittingSize.width) + Self.padH * 2 }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let size = label.fittingSize
        label.frame = NSRect(
            x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) != nil ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        alphaValue = 0.7
    }

    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { onPress?() }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// «● зажми fn» — the brand-amber dot blinks while the tour waits for
/// the person to act. Steady under Reduce Motion.
final class TourWaitingView: NSView {
    let text: String
    private let dot = NSView()
    private let label: NSTextField

    init(text: String) {
        self.text = text
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        dot.wantsLayer = true
        dot.layer?.backgroundColor = TourBubbleView.Palette.brand.cgColor
        dot.layer?.cornerRadius = 3
        addSubview(dot)
        label.font = .systemFont(ofSize: 12)
        label.textColor = TourBubbleView.Palette.secondary
        addSubview(label)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let blink = CABasicAnimation(keyPath: "opacity")
            blink.fromValue = 1
            blink.toValue = 0.15
            blink.duration = 0.6
            blink.autoreverses = true
            blink.repeatCount = .infinity
            blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.layer?.add(blink, forKey: "blink")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var fittingWidth: CGFloat { 6 + 6 + ceil(label.fittingSize.width) }

    override func layout() {
        super.layout()
        dot.frame = NSRect(x: 0, y: (bounds.height - 6) / 2, width: 6, height: 6)
        let size = label.fittingSize
        label.frame = NSRect(x: 12, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
}

#Preview("Tour bubble — buttons") {
    TourBubbleView(content: TourBubbleContent(
        text: "Это я, **Daisy**. Я живу в углу экрана и всегда под рукой. Перетащи меня туда, где мне будет удобно.",
        step: 3, total: 9,
        primary: .init(title: "Дальше", run: {}),
        secondary: .init(title: "Пропустить", run: {})
    ))
}

#Preview("Tour bubble — waiting") {
    TourBubbleView(content: TourBubbleContent(
        text: "Зажми fn и скажи пару слов — я напечатаю их в поле.",
        step: 4, total: 9,
        waiting: "зажми fn"
    ))
}
