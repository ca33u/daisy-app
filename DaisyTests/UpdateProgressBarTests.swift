//
//  UpdateProgressBarTests.swift
//  DaisyTests
//
//  The orange bar over Sparkle's update window (Egor 22.10): laid over
//  once, following the window's progress, and nothing for other windows.
//

import AppKit
import Testing
@testable import Daisy

/// Stands in for Sparkle's SUStatusController: found by the class name's
/// ending, with the same two KVO properties.
@objc(DaisyTestSUStatusController)
final class DaisyTestSUStatusController: NSWindowController {
    @objc dynamic var progressValue: Double = 0
    @objc dynamic var maxProgressValue: Double = 0
}

@MainActor
struct UpdateProgressBarTests {
    private func statusWindow() -> (NSWindow, DaisyTestSUStatusController, NSProgressIndicator) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120), styleMask: [.titled], backing: .buffered, defer: true)
        let bar = NSProgressIndicator(frame: NSRect(x: 100, y: 60, width: 280, height: 20))
        bar.style = .bar
        window.contentView?.addSubview(bar)
        let controller = DaisyTestSUStatusController(window: window)
        return (window, controller, bar)
    }

    private func overlays(_ window: NSWindow) -> [NSView] {
        window.contentView?.subviews.filter { $0.identifier?.rawValue == "daisy.updateProgressBar" } ?? []
    }

    @Test func laysAnOrangeBarOverSparklesOnce() {
        let (window, controller, bar) = statusWindow()
        // Sparkle's bindings observe the controller before the window shows,
        // which renames its class (NSKVONotifying_…).
        let binding = NSObject()
        controller.addObserver(binding, forKeyPath: "progressValue", context: nil)
        defer { controller.removeObserver(binding, forKeyPath: "progressValue") }
        UpdateProgressBar.attach(to: window)
        UpdateProgressBar.attach(to: window)
        #expect(overlays(window).count == 1)
        #expect(bar.alphaValue == 0)
        _ = controller
    }

    @Test func followsTheWindowsProgress() {
        let (_, controller, _) = statusWindow()
        let progress = SparkleProgress(controller: controller)
        #expect(progress.fraction == nil)          // checking: indeterminate
        controller.maxProgressValue = 34_433_844
        controller.progressValue = 17_216_922
        #expect(progress.fraction == 0.5)
        controller.progressValue = 40_000_000
        #expect(progress.fraction == 1)
    }

    @Test func otherWindowsAreLeftAlone() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let bar = NSProgressIndicator(frame: NSRect(x: 10, y: 10, width: 200, height: 20))
        bar.style = .bar
        window.contentView?.addSubview(bar)
        let controller = NSWindowController(window: window)
        UpdateProgressBar.attach(to: window)
        #expect(overlays(window).isEmpty)
        #expect(bar.alphaValue == 1)
        _ = controller
    }
}
