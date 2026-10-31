//
//  SettingsWiring.swift
//  Daisy
//
//  The reactive half of `ServiceWiring`: a changed setting (a hotkey, the
//  MCP server, auto-start, the calendar, the evening summaries…) is
//  applied the moment it changes. Until 31.10.2026 this was a chain of
//  `.onChange` handlers on MainView, which lives only as long as the main
//  window — fine while Settings were a page of it. With Settings in their
//  own window the main one can be closed while they are changed, and the
//  change never took effect (review of the settings window, H1). Started
//  once at launch from DaisyApp.init, right after `ServiceWiring.applyAll`,
//  and alive until quit: each change is applied exactly once, whichever
//  windows are open.
//

import EventKit
import Foundation
import Observation

@MainActor
enum SettingsWiring {
    private static var watches: [ObservedValue] = []

    static func start(settings: AppSettings, session: RecordingSession) {
        guard watches.isEmpty else { return }
        let hotkeys = { ServiceWiring.applyAllHotkeys(settings: settings, session: session) }
        watches = [
            // Hotkeys.
            ObservedValue({ settings.recordHotkey }) { hotkeys() },
            ObservedValue({ settings.voiceNoteHotkey }) { hotkeys() },
            ObservedValue({ settings.dictationHotkey }) { hotkeys() },
            ObservedValue({ settings.layoutFixHotkey }) { hotkeys() },
            ObservedValue({ settings.markMomentHotkey }) { hotkeys() },
            ObservedValue({ settings.repasteLastHotkey }) { hotkeys() },
            // The Daisy key's hold needs Accessibility; granted later, the
            // key is registered again with its hold (backlog 34).
            ObservedValue({ SystemPermissions.shared.accessibility }) {
                hotkeys()
                DaisyKeyController.introduceIfNeeded(settings: settings)
            },
            // The as-you-type watcher is a keyboard tap, not a hotkey — it
            // starts and stops on its own toggle.
            ObservedValue({ settings.layoutFixAuto }) {
                ServiceWiring.applyLayoutAutoFix(settings: settings)
            },
            // The master switch gates both halves: the watcher and the
            // shortcut.
            ObservedValue({ settings.layoutFixEnabled }) {
                ServiceWiring.applyLayoutAutoFix(settings: settings)
                hotkeys()
            },
            ObservedValue({ settings.screenshotNotesEnabled }) {
                ServiceWiring.applyScreenshotNotes(settings: settings)
            },
            // Dictation registration is deferred until first-run completes
            // (Input Monitoring prompt timing — see ServiceWiring); re-apply
            // the moment onboarding closes so the fresh-install Fn default
            // goes live immediately.
            ObservedValue({ settings.hasShownFirstRun }) { hotkeys() },

            // Auto-start and the evening pass.
            ObservedValue({ settings.autoStartPolicy }) {
                ServiceWiring.applyMeetingAutoStart(settings: settings, session: session)
                ServiceWiring.applyCalendar(settings: settings, session: session)
            },
            ObservedValue({ settings.autoStartOnMeeting }) {
                ServiceWiring.applyMeetingAutoStart(settings: settings, session: session)
            },
            ObservedValue({ settings.autoStartPromptMode }) {
                ServiceWiring.applyMeetingAutoStart(settings: settings, session: session)
            },
            ObservedValue({ settings.autoStartFromCalendar }) {
                ServiceWiring.applyCalendar(settings: settings, session: session)
            },
            ObservedValue({ settings.summaryTiming }) {
                ServiceWiring.applyEndOfDaySummaries(settings: settings, session: session)
            },
            // Changing the hour re-arms the poll, so moving it EARLIER than
            // the current time fires tonight rather than tomorrow.
            ObservedValue({ settings.endOfDaySummaryHour }) {
                ServiceWiring.applyEndOfDaySummaries(settings: settings, session: session)
            },

            // Calendars and the MCP server.
            ObservedValue({ CalendarService.shared.authorizationStatus }) {
                let granted = CalendarService.shared.authorizationStatus == .fullAccess
                if settings.calendarAccessGranted != granted {
                    settings.calendarAccessGranted = granted
                }
                ServiceWiring.applyCalendar(settings: settings, session: session)
            },
            ObservedValue({ GoogleAccountStore.shared.isConnected }) {
                ServiceWiring.applyCalendar(settings: settings, session: session)
            },
            ObservedValue({ settings.mcpServerEnabled }) {
                ServiceWiring.applyMCPServer(settings: settings)
            },
            ObservedValue({ settings.mcpServerPort }) {
                if settings.mcpServerEnabled {
                    ServiceWiring.applyMCPServer(settings: settings)
                }
            },
            ObservedValue({ MCPServer.shared.state }) {
                if case .running(let port) = MCPServer.shared.state {
                    Task { await ServiceWiring.refreshMCPClients(port: port) }
                }
            },
        ]
        // The server can be up before the first change is seen.
        if case .running(let port) = MCPServer.shared.state {
            Task { await ServiceWiring.refreshMCPClients(port: port) }
        }
    }
}

/// Calls `onChange` once each time the observed value ends up different
/// from the last one seen — `.onChange(of:)` without a view. Observation
/// reports the coming change; the value is read again on the main actor
/// after it lands, and the tracking re-armed. Several writes before that
/// read collapse into one call; a write back to the old value is none.
@MainActor
final class ObservedValue {
    /// Reads the value now and says whether it moved since the last read
    /// (and remembers it).
    private let moved: @MainActor () -> Bool
    /// Reads the value only — for the tracking, which must not move `last`.
    private let peek: @MainActor () -> Void
    private let onChange: @MainActor () -> Void
    private(set) var isCancelled = false

    init<Value: Equatable>(_ read: @escaping @MainActor () -> Value,
                           onChange: @escaping @MainActor () -> Void) {
        var last = read()
        moved = {
            let now = read()
            guard now != last else { return false }
            last = now
            return true
        }
        peek = { _ = read() }
        self.onChange = onChange
        arm()
    }

    func cancel() { isCancelled = true }

    private func arm() {
        guard !isCancelled else { return }
        withObservationTracking {
            peek()
        } onChange: {
            // Held until the next change only: a cancelled watch is not
            // re-armed then, and is let go.
            Task { @MainActor in self.changed() }
        }
    }

    private func changed() {
        guard !isCancelled else { return }
        // Re-armed before acting, so a change the action itself makes is
        // seen too.
        arm()
        if moved() { onChange() }
    }
}
