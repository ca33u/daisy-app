// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  TourFlightPlanTests.swift
//  DaisyTests
//
//  The tour's flight to the widget (17.11, Sentry DAISY-MAC-5): the route
//  and the panels it is drawn in. The panels stand still while the disc
//  flies, so everything about where it goes is arithmetic and is pinned
//  here; how it looks is device-QA territory.
//

import AppKit
import Foundation
import Testing
@testable import Daisy

@Suite("Tour flight plan")
struct TourFlightPlanTests {

    typealias Plan = TourFlightPlan

    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    /// The flower in the middle of the tour's window.
    private let start = NSRect(x: 472, y: 422, width: 56, height: 56)
    /// The widget panel at its bottom-right home.
    private let widget = NSRect(x: 1340, y: 60, width: 59.84, height: 59.84)

    @Test("One screen: one panel that holds the whole route")
    func oneScreen() throws {
        let plan = try #require(Plan(from: start, to: widget, screens: [screen]))
        #expect(plan.stages.count == 1)
        let stage = plan.stages[0]
        let target = widget.insetBy(dx: Plan.widgetShadowRoom, dy: Plan.widgetShadowRoom)
        #expect(stage.frame.contains(start))
        #expect(stage.frame.contains(target))
        // Room for the shadow on the sides that don't meet a screen edge.
        #expect(stage.frame.minX <= start.minX - Plan.margin)
        #expect(stage.frame.maxY >= start.maxY + Plan.margin)
        // Centres, in the panel's own coordinates.
        #expect(stage.from == CGPoint(x: start.midX - stage.frame.minX, y: start.midY - stage.frame.minY))
        #expect(stage.to == CGPoint(x: target.midX - stage.frame.minX, y: target.midY - stage.frame.minY))
    }

    @Test("The disc lands at the widget's own size: the panel less its shadow room")
    func scale() throws {
        let plan = try #require(Plan(from: start, to: widget, screens: [screen]))
        #expect(plan.side == 56)
        #expect(abs(plan.scale - (59.84 - 18) / 56) < 0.0001)
    }

    @Test("A panel never reaches past its screen")
    func clippedToScreen() throws {
        let nearEdge = NSRect(x: 1375, y: 5, width: 59.84, height: 59.84)
        let plan = try #require(Plan(from: start, to: nearEdge, screens: [screen]))
        #expect(screen.contains(plan.stages[0].frame))
    }

    @Test("A route across two screens gets a panel on each, in the same global place")
    func twoScreens() throws {
        let second = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
        let far = NSRect(x: 3200, y: 60, width: 59.84, height: 59.84)
        let plan = try #require(Plan(from: start, to: far, screens: [screen, second]))
        #expect(plan.stages.count == 2)
        #expect(screen.contains(plan.stages[0].frame))
        #expect(second.contains(plan.stages[1].frame))
        // Each panel puts the disc at the same point of the desktop.
        for stage in plan.stages {
            #expect(stage.from.x + stage.frame.minX == start.midX)
            #expect(stage.from.y + stage.frame.minY == start.midY)
        }
    }

    @Test("A screen the route doesn't cross gets no panel")
    func untouchedScreen() throws {
        let elsewhere = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let plan = try #require(Plan(from: start, to: widget, screens: [elsewhere, screen]))
        #expect(plan.stages.count == 1)
        #expect(screen.contains(plan.stages[0].frame))
    }

    @Test("Mirrored displays share one panel")
    func mirrored() throws {
        let plan = try #require(Plan(from: start, to: widget, screens: [screen, screen]))
        #expect(plan.stages.count == 1)
    }

    @Test("Nothing to fly: a widget frame too small to inset, an empty start, no screen")
    func nothingToFly() {
        // insetBy answers the null rect here, with an infinite origin.
        #expect(Plan(from: start, to: NSRect(x: 100, y: 100, width: 10, height: 10), screens: [screen]) == nil)
        #expect(Plan(from: start, to: .zero, screens: [screen]) == nil)
        #expect(Plan(from: .zero, to: widget, screens: [screen]) == nil)
        #expect(Plan(from: start, to: widget, screens: []) == nil)
        #expect(Plan(from: start, to: widget, screens: [NSRect(x: 5000, y: 5000, width: 800, height: 600)]) == nil)
    }

    @Test("Nothing to fly: a coordinate that isn't a number")
    func notANumber() {
        let broken = NSRect(x: CGFloat.nan, y: 60, width: 59.84, height: 59.84)
        let endless = NSRect(x: CGFloat.infinity, y: 60, width: 59.84, height: 59.84)
        #expect(Plan(from: start, to: broken, screens: [screen]) == nil)
        #expect(Plan(from: start, to: endless, screens: [screen]) == nil)
        #expect(Plan(from: broken, to: widget, screens: [screen]) == nil)
    }
}
