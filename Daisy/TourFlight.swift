//
//  TourFlight.swift
//  Daisy
//
//  Step 3 of the first-run tour: the flower leaves the window and lands
//  where the widget lives (the prototype's `.widget.fly`, 0.9 s). Plain
//  AppKit in a borderless panel, like the bubble — SwiftUI content there
//  never painted on macOS 27 beta (see `TourBubble`). Under Reduce Motion
//  it doesn't fly.
//
//  THE PANEL STANDS STILL (17.11, Sentry DAISY-MAC-5). The flight used to
//  be a 56 pt panel whose FRAME was animated through `animator()`, and
//  1.0.8.51 closed on macOS 26.6.2 inside AppKit while such an animation
//  was being applied: main thread, a display-link tick, +[NSAnimationManager
//  performAnimations:] → -[CABasicAnimation applyForTime:…] → -[NSWindow
//  _setFrameCommon:display:fromServer:] → -[NSWindow
//  _adjustNeedsDisplayRegionForNewFrame:], EXC_BREAKPOINT two frames
//  further down, symbols stripped. That stack is what an `animator()`
//  frame animation looks like and what `setFrame(_:display:animate:)`
//  does not (sampled both), and the flight was the app's only one. What
//  AppKit trapped on is not known and it did not reproduce on macOS 27,
//  alone or overlapped with the main window's animated resize. So the
//  flight no longer takes that path at all: a panel is placed once over
//  the route (one per screen the route crosses) and a layer moves inside
//  it. No window frame changes while it flies.
//

import AppKit
import QuartzCore

// MARK: - Where it flies

/// The route of the flight and the panels it is drawn in. Pure: no
/// windows, no screens of its own.
nonisolated struct TourFlightPlan: Equatable, Sendable {
    /// One panel. On one screen there is one; a route that crosses
    /// screens gets one per screen, because with «Displays have separate
    /// Spaces» a window shows on a single display only.
    struct Stage: Equatable, Sendable {
        /// The panel's frame in screen coordinates. Set once.
        let frame: NSRect
        /// The disc's centre at the start and on landing, in the panel's
        /// own coordinates (origin at its bottom-left corner).
        let from: CGPoint
        let to: CGPoint
    }

    /// The disc's side when it leaves the window.
    let side: CGFloat
    /// The landed disc's side over `side`.
    let scale: CGFloat
    let stages: [Stage]

    /// The widget panel keeps ~9 pt of shadow room around its disc.
    static let widgetShadowRoom: CGFloat = 9
    /// Room around the route for the disc's own shadow.
    static let margin: CGFloat = 24

    /// Nil when there is nothing sane to fly: a start or a widget frame
    /// with no size or with a coordinate that isn't a number, or no
    /// screen under the route. The caller then skips the flight.
    init?(from start: NSRect, to widgetFrame: NSRect, screens: [NSRect]) {
        guard Self.isUsable(start), Self.isUsable(widgetFrame) else { return nil }
        // `insetBy` answers the null rect, with infinite origin, for a
        // frame too small to inset.
        let target = widgetFrame.insetBy(dx: Self.widgetShadowRoom, dy: Self.widgetShadowRoom)
        guard Self.isUsable(target) else { return nil }

        let route = start.union(target).insetBy(dx: -Self.margin, dy: -Self.margin).integral
        var stages: [Stage] = []
        for screen in screens where Self.isUsable(screen) {
            let frame = route.intersection(screen)
            // Mirrored displays share one frame: one panel for them.
            guard Self.isUsable(frame), !stages.contains(where: { $0.frame == frame }) else { continue }
            stages.append(Stage(
                frame: frame,
                from: CGPoint(x: start.midX - frame.minX, y: start.midY - frame.minY),
                to: CGPoint(x: target.midX - frame.minX, y: target.midY - frame.minY)))
        }
        guard !stages.isEmpty else { return nil }

        self.side = min(start.width, start.height)
        self.scale = min(target.width, target.height) / min(start.width, start.height)
        self.stages = stages
    }

    private static func isUsable(_ rect: NSRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }
}

// MARK: - The flight

@MainActor
enum TourFlight {
    static let duration: TimeInterval = 0.9
    private static let fadeOut: TimeInterval = 0.2

    /// The flight in the air, if any: its panels and the task that waits
    /// for it to land.
    private static var panels: [NSPanel] = []
    private static var landing: Task<Void, Never>?

    /// Flies the disc from `start` to the widget and calls `completion`
    /// when it lands; calls it at once when there is no flight (Reduce
    /// Motion, nothing sane to fly). A flight that is cancelled never
    /// calls it.
    static func fly(from start: NSRect, to widgetFrame: NSRect, completion: @escaping @MainActor () -> Void) {
        cancel()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let plan = TourFlightPlan(from: start, to: widgetFrame, screens: NSScreen.screens.map(\.frame))
        else {
            completion()
            return
        }

        var discs: [CALayer] = []
        for stage in plan.stages {
            let panel = makePanel(frame: stage.frame)
            let disc = makeDisc(side: plan.side, contentsScale: panel.backingScaleFactor)
            // The model values are the landing; the animation plays the
            // way there and leaves the layer where it already is.
            disc.position = stage.to
            disc.transform = CATransform3DMakeScale(plan.scale, plan.scale, 1)
            // The panel comes up empty, and the disc joins it together
            // with its animation: no frame can show it already landed.
            panel.orderFrontRegardless()
            panel.contentView?.layer?.addSublayer(disc)
            disc.add(flightAnimation(stage: stage, scale: plan.scale), forKey: "flight")
            panels.append(panel)
            discs.append(disc)
        }

        // A plain wait rather than the animation's own completion: it
        // ends on time whatever Core Animation does with a layer nobody
        // can see, and the tour is waiting for it.
        landing = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            completion()
            for disc in discs {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                fade.duration = fadeOut
                // Without the layer's own implicit fade beside this one.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                disc.opacity = 0
                CATransaction.commit()
                disc.add(fade, forKey: "fade")
            }
            try? await Task.sleep(for: .seconds(fadeOut))
            guard !Task.isCancelled else { return }
            close()
        }
    }

    /// Takes a flight out of the air without landing it: the tour left
    /// the step, or ended.
    static func cancel() {
        landing?.cancel()
        close()
    }

    private static func close() {
        landing = nil
        for panel in panels { panel.orderOut(nil) }
        panels = []
    }

    private static func makePanel(frame: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The disc draws its own shadow; AppKit's would outline the panel.
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        // A panel hides with its app by default; the flight shows either way,
        // like the tour's card and the widget.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        panel.contentView = view
        return panel
    }

    /// The widget's look in miniature: the dark disc, the white mark and
    /// the widget's own shadow.
    private static func makeDisc(side: CGFloat, contentsScale: CGFloat) -> CALayer {
        let disc = CALayer()
        disc.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        disc.cornerRadius = side / 2
        disc.backgroundColor = NSColor(red: 28 / 255, green: 26 / 255, blue: 23 / 255, alpha: 1).cgColor
        disc.shadowColor = NSColor.black.cgColor
        disc.shadowOpacity = 0.35
        disc.shadowRadius = 6
        // Down: a view's layer has its origin at the bottom.
        disc.shadowOffset = CGSize(width: 0, height: -3)
        disc.shadowPath = CGPath(ellipseIn: disc.bounds, transform: nil)

        if let image = NSImage(named: "DaisyMark") {
            // White, cut to the mark's outline.
            let mark = CALayer()
            mark.frame = disc.bounds.insetBy(dx: side * 0.2, dy: side * 0.2)
            mark.backgroundColor = NSColor.white.cgColor
            let outline = CALayer()
            outline.frame = mark.bounds
            outline.contentsGravity = .resizeAspect
            outline.contentsScale = contentsScale
            outline.contents = image.layerContents(forContentsScale: contentsScale)
            mark.mask = outline
            disc.addSublayer(mark)
        }
        return disc
    }

    private static func flightAnimation(stage: TourFlightPlan.Stage, scale: CGFloat) -> CAAnimation {
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: stage.from)
        move.toValue = NSValue(point: stage.to)
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = scale
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [move, shrink, appear]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        return group
    }
}
