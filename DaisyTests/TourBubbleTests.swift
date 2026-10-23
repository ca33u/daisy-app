//
//  TourBubbleTests.swift
//  DaisyTests
//
//  Onboarding 2.0, package A: where the tour's coach mark goes beside
//  the widget, what it draws for a waiting step, and the widget's
//  remembered position. The panels themselves (child windows, the ring,
//  drag tracking) are device-QA territory; the maths and the content
//  rules are pinned here.
//

import AppKit
import Foundation
import Testing
@testable import Daisy

@Suite("Tour bubble placement")
struct TourBubblePlacementTests {

    typealias Layout = TourBubbleLayout

    private let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
    private let card = NSSize(width: 340, height: 140)
    private let widgetSize = NSSize(width: 60, height: 60)

    private func widget(x: CGFloat, y: CGFloat) -> NSRect {
        NSRect(origin: NSPoint(x: x, y: y), size: widgetSize)
    }

    @Test("Sits left of a widget in its default bottom-right home")
    func defaultLeft() {
        let w = widget(x: 1300, y: 80)
        let p = Layout.place(cardSize: card, widget: w, visible: visible)
        #expect(p.side == .left)
        #expect(p.frame.maxX <= w.minX)
        #expect(p.frame.width == card.width + Layout.arrowProtrusion)
    }

    @Test("Flips to the right near the left edge")
    func flipsRight() {
        let w = widget(x: 20, y: 400)
        let p = Layout.place(cardSize: card, widget: w, visible: visible)
        #expect(p.side == .right)
        #expect(p.frame.minX >= w.maxX)
        #expect(p.frame.maxX <= visible.maxX)
    }

    @Test("Flips on a secondary display left of the main one")
    func flipsOnOffsetScreen() {
        let left = NSRect(x: -1920, y: 0, width: 1920, height: 1055)
        let w = NSRect(x: -1900, y: 500, width: 60, height: 60)
        let p = Layout.place(cardSize: card, widget: w, visible: left)
        #expect(p.side == .right)
        #expect(p.frame.minX >= w.maxX)
    }

    @Test("Stays on screen vertically at the bottom and the top")
    func verticalClamp() {
        for y in [CGFloat(-30), 0, 4, 400, 820, 900] {
            let p = Layout.place(cardSize: card, widget: widget(x: 1300, y: y), visible: visible)
            #expect(p.frame.minY >= visible.minY)
            #expect(p.frame.maxY <= visible.maxY)
        }
    }

    @Test("The arrow points at the widget's middle when nothing pushes the card")
    func arrowAtWidget() {
        let w = widget(x: 1300, y: 400)
        let p = Layout.place(cardSize: card, widget: w, visible: visible)
        #expect(abs(p.frame.minY + p.arrowY - w.midY) < 0.5)
    }

    @Test("A clamped card keeps the arrow off its rounded corners")
    func arrowInsideCard() {
        for y in [CGFloat(0), 840] {
            let p = Layout.place(cardSize: card, widget: widget(x: 1300, y: y), visible: visible)
            #expect(p.arrowY >= Layout.arrowInset)
            #expect(p.arrowY <= p.frame.height - Layout.arrowInset)
        }
    }

    @Test("No room either side: the roomier side, still on screen")
    func noRoom() {
        let narrow = NSRect(x: 0, y: 0, width: 400, height: 600)
        let p = Layout.place(cardSize: card, widget: widget(x: 300, y: 200), visible: narrow)
        #expect(p.side == .left)
        #expect(p.frame.minX >= narrow.minX)
        #expect(p.frame.maxX <= narrow.maxX)
    }
}

@Suite("Tour bubble content")
@MainActor
struct TourBubbleContentTests {

    private func content(waiting: String?) -> TourBubbleContent {
        TourBubbleContent(
            text: "Hold **fn** and say a few words.",
            step: 4, total: 9,
            primary: .init(title: "Next", run: {}),
            secondary: .init(title: "Skip", run: {}),
            waiting: waiting
        )
    }

    @Test("Waiting replaces both buttons")
    func waitingHidesButtons() {
        let waiting = content(waiting: "hold fn")
        #expect(waiting.visibleActions.isEmpty)
        let view = TourBubbleView(content: waiting)
        #expect(view.pillButtons.isEmpty)
        #expect(view.waitingView?.text == "hold fn")
    }

    @Test("Without waiting: primary first, then the ghost")
    func buttonsInOrder() {
        let view = TourBubbleView(content: content(waiting: nil))
        #expect(view.pillButtons.map(\.title) == ["Next", "Skip"])
        #expect(view.pillButtons.map(\.isPrimary) == [true, false])
        #expect(view.waitingView == nil)
    }

    @Test("Updating to a waiting step drops the old buttons")
    func updateToWaiting() {
        let view = TourBubbleView(content: content(waiting: nil))
        view.apply(content(waiting: "hold fn"))
        #expect(view.pillButtons.isEmpty)
        #expect(view.waitingView != nil)
    }

    @Test("The card never grows past 340 pt, however long the line")
    func maxWidth() {
        let long = TourBubbleContent(text: String(repeating: "word ", count: 120), step: 1, total: 9)
        let view = TourBubbleView(content: long)
        #expect(view.cardSize.width <= TourBubbleLayout.maxCardWidth)
        #expect(view.cardSize.height > 100)
    }

    @Test("Emphasis markers are stripped and their span remembered")
    func parseEmphasis() {
        let (plain, range) = TourBubbleContent.parse("Hold **fn** and talk")
        #expect(plain == "Hold fn and talk")
        #expect(range == NSRange(location: 5, length: 2))
    }

    @Test("Text without a closed marker is left as typed")
    func parseUnpaired() {
        #expect(TourBubbleContent.parse("a ** b").plain == "a ** b")
        #expect(TourBubbleContent.parse("plain").emphasis == nil)
    }
}

@Suite("Widget remembered position")
struct WidgetOriginTests {

    private let size = NSSize(width: 59.84, height: 59.84)
    private let laptop = NSRect(x: 0, y: 0, width: 1512, height: 944)

    @Test("Round trip on the same screen lands on the same spot")
    func roundTrip() {
        let origin = NSPoint(x: 812, y: 133)
        let saved = WidgetOrigin(origin: origin, size: size, displayID: 1, visible: laptop)
        let back = saved.origin(size: size, visible: laptop)
        #expect(abs(back.x - origin.x) < 0.01)
        #expect(abs(back.y - origin.y) < 0.01)
    }

    @Test("An origin off the screen comes back clamped inside it")
    func clampsOffScreen() {
        let saved = WidgetOrigin(origin: NSPoint(x: 3000, y: -400), size: size, displayID: 1, visible: laptop)
        let back = saved.origin(size: size, visible: laptop)
        #expect(back.x + size.width <= laptop.maxX)
        #expect(back.y >= laptop.minY)
    }

    @Test("Bottom-right on a big external display stays bottom-right on the laptop")
    func mapsAcrossScreens() {
        let external = NSRect(x: 1512, y: 0, width: 2560, height: 1415)
        let origin = NSPoint(x: external.maxX - size.width - WidgetOrigin.gutter, y: external.minY + WidgetOrigin.gutter)
        let saved = WidgetOrigin(origin: origin, size: size, displayID: 2, visible: external)
        let back = saved.origin(size: size, visible: laptop)
        #expect(abs(back.x - (laptop.maxX - size.width - WidgetOrigin.gutter)) < 0.01)
        #expect(abs(back.y - (laptop.minY + WidgetOrigin.gutter)) < 0.01)
    }

    @Test("Corrupt fractions in the store are clamped, not trusted")
    func clampsStoredFractions() {
        let wild = WidgetOrigin(displayID: 1, fx: 7, fy: -3)
        let back = wild.origin(size: size, visible: laptop)
        #expect(laptop.contains(NSRect(origin: back, size: size)))
    }

    @Test("Saves to and loads from its defaults key")
    func defaultsRoundTrip() throws {
        let suite = "TourBubbleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(WidgetOrigin.load(from: defaults) == nil)
        let saved = WidgetOrigin(displayID: 69_733_382, fx: 0.25, fy: 0.75)
        saved.save(to: defaults)
        #expect(defaults.dictionary(forKey: "daisy.widget.origin") != nil)
        #expect(WidgetOrigin.load(from: defaults) == saved)
    }
}
