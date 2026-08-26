//
//  DaisyAppDelegate.swift
//  Daisy
//
//  Lifecycle override: closing the main window does NOT quit the app.
//  Daisy keeps living in the menu bar (and as the floating petal widget
//  during a recording). The user explicitly quits via menu-bar item or
//  the floating-widget right-click menu.
//
//  Clicking the Dock icon while no windows are visible re-opens the
//  main window (standard reopen handling).
//

import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class DaisyAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Daisy is always a regular app (Dock icon + app menus). The
        // "Compact menu bar" setting (Settings → General → Appearance) no
        // longer demotes to `.accessory` — it only swaps the menu-bar
        // icon's click from the transcription popover to a dropdown menu
        // (see DaisyApp's conditional MenuBarExtra). Dock icon + menus stay.
        NSApp.setActivationPolicy(.regular)

        // Apply the persisted System / Light / Dark preference globally.
        // `DaisyColors` supplies paired tokens, so SwiftUI content, AppKit
        // chrome, menu-bar popover, floating widget, and alerts move together.
        AppearanceController.apply(AppearancePreference.stored())

        // FluidAudio (diarization / Silero VAD / Parakeet) network policy:
        // hard-block every download surface outside explicit, logged
        // model-download windows — "nothing leaves your Mac" enforced in
        // code via ModelHub.offlineMode (FluidAudio 0.15.5+; called
        // DownloadUtils.enforceOffline before that), not
        // just promised. Loaders retry inside a download window when the
        // model cache is missing. See FluidAudioNetworkGuard.
        #if canImport(FluidAudio)
        FluidAudioNetworkGuard.engage()
        #endif

        // Silence-prompt notification category needs to be on file
        // before the first time `SilenceMonitor` decides to fire
        // one. We also take over as the UN delegate so action taps
        // (Stop & save / Not yet) route through us into the
        // Foundation NotificationCenter bus — which the active
        // SilenceMonitor subscribes to.
        UNUserNotificationCenter.current().delegate = self
        SilencePromptNotification.register()
        // 1.0.5: calendar-driven lifecycle banners.
        AutoStartNotification.register()
        AutoStopNotification.register()
        // 1.0.7.9: Prompt-mode "record this call?" ask.
        AutoStartPromptNotification.register()
        // Prompt-mode "meeting seems over — stop & save?" ask
        // (Settings → "Ask before auto-stopping").
        AutoStopPromptNotification.register()

        // Voice Memos import (Settings → Transcription). Reads the raw
        // UserDefaults bool — same rationale as `compactMenuBarOnly`
        // above: the @main App's State wiring isn't guaranteed visible
        // this early, and the persisted value is the source of truth.
        // No-op unless the user opted in; arms a daily scan + one
        // delayed pass.
        VoiceMemoScanner.shared.start(
            enabled: UserDefaults.standard.bool(forKey: "daisy.ingestVoiceMemos")
        )

        // Recover any recording interrupted by a crash / power loss: a
        // refresh detects "audio but no transcript" folders and hands them
        // to InterruptedRecordingRecovery. Delayed so it doesn't fight
        // first-paint; the scan is cheap.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            await SessionStore.shared.refresh()
        }

        // Pause/save the active recording around sleep and shutdown so the
        // archive stays consistent. (A *hard* power cut sends no warning —
        // that's what the crash-recovery scan above is for.)
        installPowerLifecycleObservers()

        DispatchQueue.main.async {
            for window in NSApp.windows where window.canBecomeMain {
                self.applyWarmChrome(to: window)
            }
        }

        // SwiftUI's scene delegate keeps resetting
        // `presentationOptions` AFTER we set them — at unpredictable
        // points during the fullscreen transition. Single-shot
        // asyncAfter(N) is racy. Solution: a repeating Timer that
        // re-forces `autoHideMenuBar + autoHideToolbar` every 0.5s
        // for the first 5 seconds after entering fullscreen. By the
        // 5-second mark SwiftUI has finished its transition dance
        // and our flags stick.
        // Note on fullscreen + menubar: macOS 26 doesn't let
        // third-party apps tint the system menubar (NSMainMenu is
        // system-managed). Earlier attempts to force `.hideMenuBar`
        // / `.autoHideMenuBar` were silently reverted by SwiftUI's
        // scene delegate. We accept the native behaviour — system
        // menubar appears at the top of fullscreen with its own
        // material backdrop. Our cream `containerBackground` still
        // tints everything below it.
    }

    // MARK: - Power / sleep lifecycle

    /// True while we auto-paused the active recording for system sleep, so
    /// we know to auto-resume on wake.
    private var pausedForSleep = false

    /// Pause the live recording when the Mac sleeps (flushes the archive),
    /// resume on wake, and save on a graceful shutdown / restart / logout.
    /// A hard power cut sends no notification — `InterruptedRecordingRecovery`
    /// is the safety net for that.
    private func installPowerLifecycleObservers() {
        let wc = NSWorkspace.shared.notificationCenter
        wc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.handleWillSleep() }
        }
        wc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.handleDidWake() }
        }
        wc.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.handleWillPowerOff() }
        }
    }

    private func handleWillSleep() async {
        guard let session = RecordingSession.current, session.status == .recording else { return }
        pausedForSleep = true
        await session.pause()
    }

    private func handleDidWake() async {
        guard pausedForSleep else { return }
        pausedForSleep = false
        guard let session = RecordingSession.current, session.status == .paused else { return }
        await session.resume()
        ToastCenter.shared.show(String(localized: "Resumed recording after your Mac woke up."), style: .info)
    }

    private func handleWillPowerOff() async {
        guard let session = RecordingSession.current,
              session.status == .recording || session.status == .paused else { return }
        // Graceful shutdown / restart / logout — we have time to finalize.
        await session.stop()
    }

    // MARK: - Chrome

    /// Minimum-viable chrome to make NSWindow wear our cream colour.
    /// Per macOS-dev agent audit, the previous extras
    /// (`titlebarSeparatorStyle = .none`, `toolbarStyle = .unified`,
    /// the recursive NSVisualEffectView walk) were no-ops in Tahoe
    /// — Liquid Glass uses a private `_NSGlassBackdropView`, not
    /// NSVisualEffectView, so traversal couldn't touch it.
    private func applyWarmChrome(to window: NSWindow) {
        // Keep titlebar chrome in the same appearance as the content. The
        // background colour itself is dynamic, so its parchment and espresso
        // variants remain aligned with `Color.daisyBgPrimary`.
        window.appearance = nil
        window.backgroundColor = Self.windowBackground
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
    }

    /// Dynamic AppKit counterpart to `Color.daisyBgPrimary`, including the
    /// transparent titlebar and the macOS 14 window-background fallback.
    private static let windowBackground = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0x0D / 255, green: 0x10 / 255, blue: 0x0E / 255, alpha: 1)
            : NSColor(srgbRed: 0xFF / 255, green: 0xFE / 255, blue: 0xFC / 255, alpha: 1)
    }

    // Keep the process alive after the last window closes — we still
    // have a menu-bar item and possibly the floating widget.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Guard Quit against an in-progress recording. If the user quits
    /// (⌘Q, menu, or the widget's "Quit Daisy") while capture is live,
    /// confirm first — and on confirm, finalize the session so the audio
    /// archive + transcript-so-far are saved before the process exits.
    /// Without this, `NSApp.terminate` kills the process immediately and
    /// the in-progress recording is lost.
    ///
    /// Note: this is the QUIT path only. Closing the main window does not
    /// reach here — Daisy keeps running in the menu bar / floating widget
    /// (see `applicationShouldTerminateAfterLastWindowClosed`).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session = RecordingSession.current,
              session.status == .recording || session.status == .paused else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Daisy is still recording")
        alert.informativeText =
            String(localized: "Quit and save this recording? Daisy will finalize the audio and transcript captured so far.")
        alert.addButton(withTitle: String(localized: "Save & Quit"))   // .alertFirstButtonReturn
        alert.addButton(withTitle: String(localized: "Cancel"))         // .alertSecondButtonReturn

        // Bring Daisy forward so the modal isn't lost behind other apps
        // (the user is likely in another window when they hit ⌘Q).
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        // Defer termination until the session has persisted the audio
        // archive + transcript.md. `stop()` writes those synchronously and
        // kicks the summary off detached; the summary won't finish before
        // we exit, but the recording is saved and re-summarizable from the
        // Library on next launch.
        Task { @MainActor in
            await session.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show the banner even when Daisy is the frontmost app — by
    /// default macOS suppresses banners for the active app, but the
    /// silence prompt is most useful exactly when the user is in
    /// some other window and hasn't noticed they're still recording.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Route the user's tap on Stop & save / Not yet into the
    /// Foundation NotificationCenter bus. SilenceMonitor on the
    /// active session listens there and runs the matching action.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        Task { @MainActor in
            switch actionID {
            case SilencePromptNotification.actionStop:
                NotificationCenter.default.post(
                    name: SilencePromptNotification.stopRequested, object: nil
                )
            case SilencePromptNotification.actionSnooze:
                NotificationCenter.default.post(
                    name: SilencePromptNotification.snoozeRequested, object: nil
                )
            case AutoStartNotification.actionStop:
                // User tapped "Stop & save" on the auto-start banner.
                // RecordingSession.subscribeToLifecycleNotifications
                // listens and routes to stop().
                NotificationCenter.default.post(
                    name: AutoStartNotification.stopRequested, object: nil
                )
            case AutoStartPromptNotification.actionRecord:
                // Prompt mode: user said yes — start the pending trigger.
                NotificationCenter.default.post(
                    name: AutoStartPromptNotification.recordRequested, object: nil
                )
            case AutoStartPromptNotification.actionIgnore:
                // Prompt mode: user said no — drop the pending trigger.
                NotificationCenter.default.post(
                    name: AutoStartPromptNotification.ignoreRequested, object: nil
                )
            case AutoStopPromptNotification.actionStop:
                // Auto-stop prompt: user confirmed — stop & save now.
                // RecordingSession's init-time observer routes to
                // performAutoStopFromPrompt().
                NotificationCenter.default.post(
                    name: AutoStopPromptNotification.stopRequested, object: nil
                )
            case AutoStopPromptNotification.actionSnooze10:
                NotificationCenter.default.post(
                    name: AutoStopPromptNotification.snooze10Requested, object: nil
                )
            case AutoStopPromptNotification.actionSnooze30:
                NotificationCenter.default.post(
                    name: AutoStopPromptNotification.snooze30Requested, object: nil
                )
            default:
                // Tap on the banner body of a silence-prompt category —
                // treat as "Not yet" so the silence clock resets.
                // For other categories (auto-start tapped body, auto-
                // stop tapped body, auto-stop PROMPT tapped body) we
                // just dismiss — macOS already activates the app on a
                // body tap, and for the auto-stop prompt that's the
                // whole contract: open Daisy, keep recording, decide
                // there. The broadcast only fires when an explicit
                // action button is hit.
                let cat = response.notification.request.content.categoryIdentifier
                if cat == SilencePromptNotification.categoryID {
                    NotificationCenter.default.post(
                        name: SilencePromptNotification.snoozeRequested, object: nil
                    )
                } else if cat == AutoStartPromptNotification.categoryID {
                    // Body tap on the "record this call?" banner with no
                    // explicit action — treat as Ignore so the pending
                    // trigger doesn't linger.
                    NotificationCenter.default.post(
                        name: AutoStartPromptNotification.ignoreRequested, object: nil
                    )
                }
            }
            completionHandler()
        }
    }

    // When the user clicks the Dock icon and no windows are visible,
    // bring the main window back. macOS calls this with
    // hasVisibleWindows == false in that case; returning `true` tells
    // AppKit to handle the default reopen (it'll restore the closed
    // Window scene).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Force activation policy back to .regular in case anything
            // demoted us, and ask AppKit to restore the main scene.
            NSApp.setActivationPolicy(.regular)

            // Fallback: surface any existing main-capable window if the
            // default reopen path didn't fire for some reason.
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                return false
            }
        }
        return true
    }
}
