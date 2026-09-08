//
//  ServiceWiring.swift
//  Daisy
//
//  Single source of truth for wiring shared services (HotkeyManager,
//  MeetingDetector, CalendarService) to the current `RecordingSession`
//  and `AppSettings`. Called from two places:
//
//   1. `DaisyApp.init` — initial wiring at launch, so hotkeys + auto-
//      start work before the user opens the window.
//   2. `MainView` `.onChange` handlers — re-applied when the user flips
//      the relevant setting.
//
//  Centralising here prevents the two wiring sites from drifting apart
//  as services are added or their handler signatures change.
//

import EventKit
import Foundation

@MainActor
enum ServiceWiring {

    /// Backward-compat single-slot wiring of the meeting hotkey.
    /// Kept so legacy call sites compile; new code should call
    /// `applyAllHotkeys(settings:session:)` to wire all three slots.
    static func applyHotkey(choice: HotkeyChoice, session: RecordingSession) {
        HotkeyManager.shared.register(
            slot: .record,
            choice: choice,
            action: .toggle { [weak session] in
                Task { await session?.toggleByHotkey() }
            }
        )
    }

    /// Register meeting + voice-notes + dictation hotkeys from
    /// settings. Idempotent — calling again rewires all three
    /// slots from current settings.
    ///
    /// Modes:
    ///   - **Meeting** + **Voice notes** use `.toggle` (press
    ///     once to start, press again to stop). Zero permission
    ///     for Meeting (Carbon RegisterEventHotKey); Voice notes
    ///     needs Input Monitoring only if bound to Fn / globe.
    ///   - **Dictation** uses `.hold` (push-to-talk). Wispr Flow
    ///     parity: hold the key while speaking, release to drop
    ///     the transcript on the clipboard. Requires Input
    ///     Monitoring permission regardless of which key is bound.
    static func applyAllHotkeys(settings: AppSettings, session: RecordingSession) {
        HotkeyManager.shared.register(
            slot: .record,
            choice: settings.recordHotkey,
            action: .toggle { [weak session] in
                Task { await session?.toggleByHotkey() }
            }
        )
        HotkeyManager.shared.register(
            slot: .voiceNote,
            choice: settings.voiceNoteHotkey,
            action: .toggle { [weak session] in
                Task { await session?.toggleVoiceNoteByHotkey() }
            }
        )
        // Dictation registers only AFTER first-run completes. The hold
        // path needs Input Monitoring, and macOS prompts at monitor
        // registration — with the fresh-install Fn default that prompt
        // would otherwise fire at first launch, BEFORE onboarding has
        // shown the Hotkeys step that explains it. MainView re-applies
        // hotkeys when `hasShownFirstRun` flips.
        HotkeyManager.shared.register(
            slot: .dictation,
            choice: settings.hasShownFirstRun ? settings.dictationHotkey : .none,
            action: .hold(
                onPress: { [weak session] in
                    Task { await session?.startDictationHotkey() }
                },
                onRelease: { [weak session] in
                    Task { await session?.stopDictationHotkey() }
                }
            )
        )
        // Rewrite-selection-in-my-voice — one tap grabs the selection,
        // rewrites it via the Voice Profile, pastes it back.
        HotkeyManager.shared.register(
            slot: .rewrite,
            choice: settings.rewriteSelectionHotkey,
            action: .toggle {
                Task { await SelectionRewrite.shared.trigger() }
            }
        )
        // Fix-the-layout — one tap re-types the selection (or the word in
        // flight) in the layout it should have been typed with.
        HotkeyManager.shared.register(
            slot: .fixLayout,
            choice: settings.layoutFixHotkey,
            action: .toggle {
                Task { await LayoutFixService.shared.trigger(settings: settings) }
            }
        )
        // Mark-this-moment — one tap during a recording. `.toggle`
        // (single fire on press) rather than `.hold`: a marker is an
        // instant, and Carbon's toggle path needs no permission, which
        // matters for a key someone will press mid-meeting expecting
        // nothing to happen but a marker.
        HotkeyManager.shared.register(
            slot: .markMoment,
            choice: settings.markMomentHotkey,
            action: .toggle { [weak session] in
                Task { await session?.markMomentByHotkey() }
            }
        )
        // Re-paste last dictation — one tap re-inserts the most recent
        // dictation at the caret. Session-independent (it reads
        // DictationHistory, not the live session), so no `session`
        // capture.
        HotkeyManager.shared.register(
            slot: .repasteLast,
            choice: settings.repasteLastHotkey,
            action: .toggle {
                Task { @MainActor in DictationPaste.shared.repasteLast() }
            }
        )
    }

    /// Start or stop the as-you-type layout watcher from settings.
    /// Idempotent, and safe to call when nothing changed — the watcher
    /// itself no-ops on a redundant start.
    static func applyLayoutAutoFix(settings: AppSettings) {
        LayoutAutoFix.shared.apply(settings: settings)
    }

    /// Start or stop the screenshot→note watcher from settings.
    /// Idempotent — the watcher no-ops on a redundant start.
    static func applyScreenshotNotes(settings: AppSettings) {
        ScreenshotNoteCapture.shared.apply(settings: settings)
    }

    /// Enable or disable foreground-app meeting auto-detection
    /// (NSWorkspace-based — fires when Zoom / Teams / Meet etc. is
    /// launched). `enabled` is the derived `settings.autoStartOnMeeting`
    /// substrate flag (ON for Always / Prompt, OFF for Selective /
    /// Manual). The detector fires immediately on a known app's launch;
    /// when `autoStartPromptMode` is on it asks before recording instead
    /// of starting directly.
    ///
    /// We deliberately do NOT call `session.start()` when a session
    /// is already recording or paused. Previously the call slipped
    /// through to `start()` and silently returned via its guard,
    /// leaving the user confused why a brand-new meeting app launch
    /// did nothing visible. Now we surface a toast so the user can
    /// stop the previous session intentionally if they want a fresh
    /// recording for the newly-launched app.
    ///
    /// Unlike the calendar path (`startFromMeeting`) we cannot auto-
    /// rotate here — NSWorkspace's notification gives us the app
    /// bundle ID, not a `DaisyMeeting`, so we have no idea if it's
    /// a "different" meeting from what's already being recorded.
    /// Surfacing rather than acting is the right move.
    static func applyMeetingAutoStart(settings: AppSettings, session: RecordingSession) {
        guard settings.autoStartOnMeeting else {
            MeetingDetector.shared.stop()
            return
        }
        MeetingDetector.shared.start { [weak session] bundleID in
            Task { @MainActor in
                guard let session else { return }
                let appName = MeetingDetector.displayName(for: bundleID)
                // App launches ALWAYS ask before recording, regardless of
                // the auto-start policy (2026-08-21). Launching Discord/
                // Telegram to send a text used to silently start a
                // session in Always mode — a weak trigger deserves a
                // confirmation tap, not a hot mic. The ask surfaces as a
                // widget bubble (or a notification when the widget is
                // hidden); the already-recording case toasts inside.
                session.promptToStartFromAppLaunch(appName: appName)
            }
        }
    }

    /// Configure CalendarService for the current permission +
    /// auto-start preference. Called both on app launch and whenever
    /// `autoStartFromCalendar` or `calendarAccessGranted` flips.
    ///
    /// Behaviour:
    ///   • No permission → stop the service.
    ///   • Permission granted → start (idempotent), passing the
    ///     auto-start preference and a meeting-start handler.
    ///   • Both branches above keep `upcomingMeetings` cache warm
    ///     for the Home view even when auto-start is off — the user
    ///     still wants to see what's coming.
    static func applyCalendar(settings: AppSettings, session: RecordingSession) {
        // CalendarService now multiplexes EventKit + Google OAuth.
        // Start the service if EITHER source is available — a
        // user might only have Google connected (no Internet
        // Accounts integration) and still want auto-start.
        // Read the LIVE EventKit status, NOT the persisted
        // `settings.calendarAccessGranted` cache. That cache is only
        // written when the grant happens THROUGH Daisy's own request
        // flow (CalendarService.requestAccess -> authorizationStatus
        // change -> CalendarServerWiring). When the OS already has
        // Daisy granted at launch — a fresh UserDefaults after a
        // reinstall / defaults migration, or a grant made directly in
        // System Settings — the cache stays `false` and the reconciling
        // onChange never fires (its trigger value is already
        // .fullAccess and never changes), so the whole calendar goes
        // dark on a stale `false`. SettingsView's calendar gate was
        // moved to the live status for exactly this reason (see
        // `hasAnyCalendarSource`); this fetch gate had been missed.
        let liveStatus = EKEventStore.authorizationStatus(for: .event)
        let hasEventKit = (liveStatus == .fullAccess)
        // Keep the persisted cache reconciled so every other reader —
        // and the MainView sync path — sees the true state.
        if settings.calendarAccessGranted != hasEventKit {
            settings.calendarAccessGranted = hasEventKit
        }
        let hasGoogle = GoogleAccountStore.shared.isConnected
        guard hasEventKit || hasGoogle else {
            CalendarService.shared.stop()
            return
        }
        CalendarService.shared.start(
            // 48h so Home can roll over to "Tomorrow" once today's
            // meetings are done and still show a full next day.
            lookaheadHours: 48,
            autoStartOnMeeting: settings.autoStartFromCalendar
        ) { [weak session] meeting in
            Task { await session?.startFromMeeting(meeting) }
        }
    }

    /// Start or stop the local MCP server based on the user's
    /// preference. Loopback-only; opt-in. Idempotent.
    static func applyMCPServer(settings: AppSettings) {
        if settings.mcpServerEnabled {
            MCPServer.shared.start(port: settings.mcpServerPort)
        } else {
            MCPServer.shared.stop()
        }
    }

    /// Start or stop the end-of-day summary poll. Idempotent; the
    /// scheduler itself no-ops for any timing other than `.endOfDay`.
    static func applyEndOfDaySummaries(settings: AppSettings, session: RecordingSession) {
        EndOfDaySummaries.shared.apply(settings: settings, session: session)
    }

    /// Convenience for full initial wiring at launch.
    static func applyAll(settings: AppSettings, session: RecordingSession) {
        applyAllHotkeys(settings: settings, session: session)
        applyMeetingAutoStart(settings: settings, session: session)
        applyCalendar(settings: settings, session: session)
        applyMCPServer(settings: settings)
        applyEndOfDaySummaries(settings: settings, session: session)
        ImportTranscriptionQueue.shared.start()
        applyLayoutAutoFix(settings: settings)
        applyScreenshotNotes(settings: settings)
    }
}
