// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  SilencePromptNotification.swift
//  Daisy
//
//  Native `UNUserNotification` replacement for the old custom
//  `SilenceBubble` callout. Posts a banner ("Are we done?") with two
//  inline action buttons — Stop & save / Not yet — and routes the
//  user's choice back to the active `SilenceMonitor` via a
//  Foundation `NotificationCenter` broadcast so the recording
//  session can react.
//
//  Why this exists instead of a SwiftUI bubble:
//   • Apple positions the banner — no custom shadow-padding maths
//     or visible-frame clamping required.
//   • Works even when the floating widget is hidden or off-screen.
//   • Respects Focus Mode / Do Not Disturb naturally.
//   • Action buttons are Apple-styled, accessible, and translated.
//
//  Lifecycle: `register()` is called once at app launch from
//  `DaisyAppDelegate.applicationDidFinishLaunching` — sets the
//  category and asks for `.alert + .sound` authorization. `post()`
//  is called from `SilenceMonitor.tick` when the silence/pause
//  thresholds hit. `cancel()` retracts any in-flight banner when
//  the session resumes or stops.
//

import Foundation
// `@preconcurrency` silences Sendable-related warnings against
// UserNotifications types (`UNUserNotificationCenter`,
// `UNNotificationSettings`) that Apple hasn't yet audited. Without
// it, the system-callback closures inside `getNotificationSettings`
// and `requestAuthorization` flag every captured `center` reference.
@preconcurrency import UserNotifications

@MainActor
enum SilencePromptNotification {

    // MARK: - Identifiers

    /// Single shared identifier — only one silence prompt is ever
    /// in flight (any new post replaces an in-flight one).
    static let requestID = "app.essazanov.Daisy.silencePrompt"

    /// Category that bundles our two action buttons. Must be
    /// registered before the first `post()` so AppKit knows what
    /// buttons to draw on the banner.
    static let categoryID = "app.essazanov.Daisy.silencePrompt.category"

    /// Action identifier — user tapped "Stop & save".
    static let actionStop = "STOP_AND_SAVE"
    /// Action identifier — user tapped "Not yet".
    static let actionSnooze = "NOT_YET"

    // MARK: - NotificationCenter (Foundation) broadcasts

    /// Posted on the main bus when the user picks Stop & save from
    /// the banner. `SilenceMonitor.start` subscribes and forwards
    /// to `session.stop()`.
    static let stopRequested = Notification.Name("Daisy.silencePrompt.stopRequested")

    /// Posted when the user picks Not yet. SilenceMonitor's `snooze`
    /// re-arms the silence clock.
    static let snoozeRequested = Notification.Name("Daisy.silencePrompt.snoozeRequested")

    // MARK: - Setup

    /// Register the action category and request authorization. Call
    /// once at app launch — idempotent on subsequent calls.
    static func register() {
        let center = UNUserNotificationCenter.current()
        let stop = UNNotificationAction(
            identifier: actionStop,
            title: "Stop & save",
            options: [.foreground]
        )
        // "Keep recording" is clearer than the earlier "Not yet" —
        // explicit about what choosing it does (the session keeps
        // running) instead of just deferring a question.
        let snooze = UNNotificationAction(
            identifier: actionSnooze,
            title: String(localized: "Keep recording"),
            options: []
        )
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [stop, snooze],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        // Authorization is requested lazily — many users never hit a
        // silence prompt at all (short meetings), and asking up
        // front feels presumptuous. We re-check / request inside
        // `post()` the first time we need to actually surface a
        // banner.
    }

    // MARK: - Post

    /// Bubble tag for the silence ask — lets `cancel()` withdraw only
    /// its own pill when speech resumes.
    static let bubbleTag = "silence-ask"

    /// Surface the silence ask. Widget bubble first (2026-08-21 —
    /// system banners are being retired): «Stop & save?», tap the pill
    /// to stop, ✕/countdown to keep going (the "Not yet" snooze is the
    /// monitor's own re-prompt cadence either way). Falls back to the
    /// actionable banner only when no bubble host exists.
    static func post() {
        Task { @MainActor in
            let shown = WidgetBubbleCenter.shared.show(WidgetBubbleContent(
                text: String(localized: "Stop & save?"),
                actionTitle: String(localized: "Stop & save"),
                actionSymbol: "stop.circle",
                tag: bubbleTag,
                action: {
                    // Same bus the banner action rides — SilenceMonitor
                    // listens and runs the stop on the live session.
                    NotificationCenter.default.post(name: stopRequested, object: nil)
                }
            ))
            if !shown { postBanner() }
        }
    }

    /// The pre-bubble banner path. If notification permission
    /// hasn't been requested yet, ask first; if the user declines,
    /// fall through silently (the recording itself isn't affected,
    /// the user just doesn't get the nudge).
    private static func postBanner() {
        // Fetch a fresh center reference inside each closure rather
        // than capturing one — `UNUserNotificationCenter` is not
        // Sendable, and Swift 6 strict concurrency rejects the
        // capture in `@Sendable` callbacks even under
        // `@preconcurrency import`.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        Task { @MainActor in addRequest() }
                    }
                }
            case .authorized, .provisional:
                Task { @MainActor in addRequest() }
            case .denied, .ephemeral:
                // User said no — respect that, don't pester.
                break
            @unknown default:
                break
            }
        }
    }

    /// Pull any pending or delivered silence-prompt banner so a
    /// resumed / stopped session doesn't leave an orphan in
    /// Notification Center.
    static func cancel() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
        center.removeDeliveredNotifications(withIdentifiers: [requestID])
        Task { @MainActor in
            WidgetBubbleCenter.shared.dismiss(tag: bubbleTag)
        }
    }

    // MARK: - Internals

    private static func addRequest() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Are we done?")
        content.body = String(localized: "It's been quiet for a while.")
        content.sound = .default
        content.categoryIdentifier = categoryID
        // Reuse the same identifier so a new prompt replaces any
        // still-visible older one — no stacking.
        let request = UNNotificationRequest(
            identifier: requestID,
            content: content,
            // trigger: nil → "fire immediately".
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
