//
//  DaisyApp.swift
//  Daisy
//
//  Regular Mac app (Dock icon + Cmd+Tab) that also lives in the menu
//  bar. Single primary scene with a NavigationSplitView (Home / History
//  / Settings sections in a sidebar).
//
//  Surfaces:
//   • MainView (Window id "main") — primary window. Opens on launch
//     and on Dock-icon click. Closing it does NOT quit (see
//     DaisyAppDelegate). `Window` (singular) ensures menu-bar / widget
//     entry points focus the existing window instead of duplicating it.
//   • MenuBarExtra — full recording UI in the menu bar.
//   • FloatingPanelController — borderless petal widget over the
//     desktop while recording / summarizing.
//

import SwiftUI
import os

@main
struct DaisyApp: App {
    @NSApplicationDelegateAdaptor(DaisyAppDelegate.self) private var appDelegate

    @State private var settings: AppSettings
    @State private var session: RecordingSession
    @State private var floatingPanel: FloatingPanelController

    init() {
        // One-shot migration of legacy `hola.*` preference keys to
        // `daisy.*`. Must run BEFORE AppSettings is constructed so the
        // migrated values are read in this same launch.
        UserDefaultsMigration.runIfNeeded()

        // Catches a crash so the next launch can ASK whether to send it;
        // nothing leaves without that answer (CrashReports).
        CrashReports.start()

        // NOT here: the eager keychain migration. It walks all eight
        // secrets, and reading an item of the OLD login keychain can
        // raise the system's "… wants to use your confidential
        // information" dialog whenever the item's ACL does not list
        // this binary — a profile moved between Macs, restored from
        // Time Machine, or simply an earlier build. On the main thread,
        // before the first window, that is the app standing still with
        // an unexplained dialog on screen (Egor, 2026-09-22: 2 m 41 s).
        //
        // The lazy migration in `KeychainStore.get` stays: a secret the
        // person actually uses moves forward on first read, inside a
        // running app. The eager pass exists only so a key they never
        // touch here still reaches the iPhone — which matters only when
        // sync is on, and sync is off by default. `SyncCoordinator`
        // runs it off the main thread when sync is turned on.

        // Belarusian systems fall back to Russian, once, on a fresh
        // install — must run before anything resolves a localized
        // string, or the choice only lands on the NEXT launch. There
        // is no language step in onboarding; Settings → Language is
        // the only explicit switch.
        AppSettings.applyBelarusianLanguageFallbackIfNeeded()

        let s = AppSettings()
        let sess = RecordingSession(settings: s)
        // Weak handle for the Quit-during-recording save path
        // (DaisyAppDelegate.applicationShouldTerminate).
        RecordingSession.current = sess
        _settings = State(wrappedValue: s)
        _session = State(wrappedValue: sess)
        _floatingPanel = State(wrappedValue: FloatingPanelController(session: sess, settings: s))

        // Initial wiring of hotkey + meeting auto-start + calendar.
        // Re-applied reactively in MainView's .onChange handlers when
        // the user flips the relevant setting. Centralised in
        // `ServiceWiring` so both call sites can't drift apart.
        ServiceWiring.applyAll(settings: s, session: sess)

        // Note the build we just launched into, so a later bug report can
        // say what this Mac updated FROM and when (see VersionInfo).
        VersionInfo.recordLaunch()

        // Touch the voice corpus here, at launch, and not by accident on
        // the first dictation: its first access reads (and on an update,
        // migrates) the corpus, and migration runs a language detector
        // over every paragraph. That work is fine at launch and is not
        // fine in the Stop→paste window, which is where the first access
        // would otherwise land (`DictationPaste.prepare`).
        _ = VoiceProfileStore.shared

        // Start Sparkle's normal background cycle immediately after launch.
        // This honours the Automatic update setting, does not interrupt the
        // user with a manual-check sheet, and ensures a newly published
        // release is discovered without waiting for the next hourly cadence.
        SparkleUpdater.shared.checkForUpdatesAfterLaunch()

        // Benchmarks/kill_recovery.sh: `open -a Daisy --args --benchmark-record`
        // starts a microphone recording as soon as the app is up, so the
        // harness can kill -9 the process mid-meeting and measure what
        // survives on relaunch. Nothing else reads this flag; a person
        // never passes it by accident.
        if CommandLine.arguments.contains("--benchmark-record") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                await sess.start()
            }
        }
    }

    var body: some Scene {
        // Primary window — opens on launch and on Dock click. `Window`
        // (singular) guarantees one main window: `openWindow(id:"main")`
        // from the menu bar / widget will focus the existing window
        // instead of spawning duplicates. With macOS 14+ SwiftUI infers
        // `.regular` activation policy from having any standard
        // foreground scene, so Dock icon + Cmd+Tab still appear.
        Window("Daisy", id: "main") {
            MainView(session: session, settings: settings)
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
        .defaultSize(width: 980, height: 640)
        // No `.windowToolbarStyle(.unified)` — that flag stretches the
        // toolbar bar across the entire window, painting OVER the
        // sidebar's top edge. Default NavigationSplitView behaviour
        // on macOS already lets the sidebar's frosted material
        // extend up to the title bar (Mail / Notes / Finder pattern),
        // and toolbar items live in the detail-pane portion only.
        .commands {
            // Re-target the system "Daisy Help" menu item at our
            // hosted support page instead of the default (which
            // would look for a bundled .help file we don't ship).
            CommandGroup(replacing: .help) {
                Button("Daisy Help") {
                    if let url = URL(string: "https://mydaisy.io/support") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut("?", modifiers: [.command])
                Divider()
                // Tester feedback channel: collects the last 24 h of
                // Daisy's own logs + an environment header and opens
                // a pre-addressed Mail compose — the user reviews and
                // presses Send themselves (LogReporter.swift).
                Button("Send Log Report…") {
                    LogReporter.sendReport(settings: settings)
                }
                // The dumb path: writes the log file and nothing else.
                // For anyone whose mail is in a browser, or who just
                // wants the log to hand over.
                Button("Export Logs…") {
                    LogReporter.exportLogs(settings: settings)
                }
            }
            // Replace the default About panel with one that names the
            // studio and links to contact + website. The system's
            // default shows just the bundle version, which reads as
            // "we forgot to fill this in".
            CommandGroup(replacing: .appInfo) {
                Button("About Daisy") {
                    AboutPanel.show()
                }
                // "Check for Updates…" sits in the App menu directly
                // under About — that's the macOS convention (Slack,
                // Bear, Tot, MailMate all put it there). The button is
                // disabled while an in-flight check is running so a
                // double-click can't fire two probes; the wrapper also
                // disables it entirely when Sparkle isn't linked yet,
                // which is the state on the first build before the
                // SPM dep is added in Xcode.
                Button(SparkleUpdater.shared.checkOrInstallTitle) {
                    SparkleUpdater.shared.checkOrInstall()
                }
                .disabled(!SparkleUpdater.shared.canCheckOrInstall)
            }
            // ⌘R — refresh "Your Day" on demand: calendar meetings AND
            // the day-card brief (Egor 2026-07-25; was calendar-only).
            // A meeting added in Calendar right before hitting Record
            // shouldn't wait for the next EventKit tick, and the lede/
            // agenda/tasks should follow in the same gesture. Sits in
            // the View menu per macOS convention (Mail/Finder ⌘R-ish
            // refresh affordances). Safe while recording — neither
            // refresh touches the live session.
            CommandGroup(after: .sidebar) {
                Divider()
                Button("Refresh Your Day") {
                    // Home-only by product decision (Egor 2026-07-25) —
                    // the guard doubles the .disabled below in case the
                    // menu's enable-state ever lags an @Observable nav
                    // change.
                    guard AppNavigation.shared.section == .home else { return }
                    CalendarService.shared.refresh()
                    Task { await MorningBriefStore.shared.regenerate(settings: settings) }
                }
                .keyboardShortcut("r", modifiers: [.command])
                // Reading the @Observable nav section here makes the
                // menu item re-evaluate on section changes: ⌘R is
                // greyed out everywhere except Home.
                .disabled(AppNavigation.shared.section != .home)
            }
        }

        // Menu-bar icon — two MenuBarExtra scenes, one inserted at a time
        // by "Compact menu bar":
        //  • Default    → `.window` popover with the full ContentView (live
        //    record + transcription).
        //  • Compact ON → `.menu`: a native dropdown with the quick actions
        //    (CompactMenuItems), so the transcription window never shows.
        // `SceneBuilder` rejects if/else; `isInserted` flips live with the
        // toggle. Dock icon + app menus stay untouched.
        //
        // 30.09: before, the compact choice was a menu-looking view inside
        // the `.window` popover, and it opened far from the icon (a user on
        // macOS 26.6: the window kept the full view's 420×580 frame and the
        // short list sat in its middle, ~290 pt below the bar, with the
        // frame's outline around it).
        MenuBarExtra(isInserted: Binding(get: { !settings.compactMenuBarOnly }, set: { _ in })) {
            ContentView(session: session, settings: settings)
                .frame(width: 420, height: 580)
        } label: {
            MenuBarLabel(session: session, settings: settings)
        }
        .menuBarExtraStyle(.window)

        MenuBarExtra(isInserted: Binding(get: { settings.compactMenuBarOnly }, set: { _ in })) {
            CompactMenuItems(session: session, settings: settings)
        } label: {
            MenuBarLabel(session: session, settings: settings)
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - Menu bar label
//
// Pulls the dynamic label content out of DaisyApp's scene builder
// so we can `@Bindable` the session + calendar service and update
// the label whenever either changes. Three states:
//
//   • Recording  → icon only (the existing menu-bar art already
//                  communicates "active"; adding text would crowd
//                  the system bar at the worst time)
//   • Setting on AND has upcoming event within 8h
//                → icon + "Q3 Review in 3h 5m" (a countdown; «now» for
//                  the first five minutes of a meeting)
//   • Default    → icon only
//

private struct MenuBarLabel: View {
    @Bindable var session: RecordingSession
    @Bindable var settings: AppSettings
    @Bindable private var calendar = CalendarService.shared

    var body: some View {
        // The countdown («Q3 Review in 3h 5m») changes every minute: the
        // label reads `MinuteClock`, which ticks on the minute. Not a
        // TimelineView — inside a MenuBarExtra label it re-rendered without
        // end at launch (29.09: the main thread spun in
        // MenuBarExtraHost.requestUpdate, the app never finished launching).
        let next = nextMeetingLabel(now: MinuteClock.shared.now)
        Group {
            if let next {
                HStack(spacing: 4) {
                    Image(nsImage: DaisyMark.menuBarImage)
                    Text(next)
                }
            } else {
                Image(nsImage: DaisyMark.menuBarImage)
            }
        }
        .modifier(MenuBarLabelTrace(text: next))
    }

    /// Returns the menu-bar label text when ALL conditions hold:
    ///   • User opted in (`menuBarShowsNextMeeting == true`)
    ///   • Session is NOT actively recording (recording state owns
    ///     the menu bar — surfacing "Next meeting" mid-recording is
    ///     a distraction)
    ///   • Calendar service has an upcoming event within 8 hours
    /// nil → fall back to icon-only. The text is a countdown, not a clock
    /// time (Egor, 29.09).
    private func nextMeetingLabel(now: Date) -> String? {
        guard settings.menuBarShowsNextMeeting else { return nil }
        switch session.status {
        case .recording, .paused, .preparing, .stopping, .summarizing:
            return nil
        case .idle, .finished, .failed:
            return calendar.nextMeetingCountdownLabel(now: now)
        }
    }
}

/// The menu-bar countdown's clock: `now`, moved on at each minute's start
/// so «in 5m» becomes «in 4m» when the clock in the menu bar changes.
/// A wake from sleep moves it at once; a repeating timer keeps its phase.
@MainActor
@Observable
final class MinuteClock {
    static let shared = MinuteClock()
    private(set) var now = Date()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wake: NSObjectProtocol?

    private init() {
        let timer = Timer(fire: Self.nextMinute(after: Date()), interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.now = Date()
                // After a sleep the timer's next fire may be minutes late;
                // put it back on the minute.
                self?.timer?.fireDate = Self.nextMinute(after: Date())
            }
        }
    }

    /// The start of the next minute (the reference date is minute-aligned).
    nonisolated static func nextMinute(after date: Date) -> Date {
        let t = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / 60).rounded(.down) * 60 + 60)
    }
}

/// DEBUG only: each change of the menu-bar text, with the second it
/// happened — how the countdown's minute tick, «now» and the hiding while
/// recording are checked on a live calendar (`log show … MenuBarLabel`).
private struct MenuBarLabelTrace: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        #if DEBUG
        content.onChange(of: text, initial: true) { _, new in
            Logger(subsystem: "app.essazanov.Daisy", category: "MenuBarLabel")
                .notice("menu bar label: \(new ?? "(icon only)", privacy: .public)")
        }
        #else
        content
        #endif
    }
}

// MARK: - Compact menu-bar popover
//
// "Compact menu bar": a native dropdown menu — the quick actions from
// ContentView's "⋯ More" menu, without the live transcription UI. Its own
// `.menu` MenuBarExtra scene (see DaisyApp), so macOS draws and places it
// like any menu bar menu.

private struct CompactMenuItems: View {
    @Bindable var session: RecordingSession
    @Bindable var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            Task { await session.runSummary() }
        } label: { Label("Summarize now", systemImage: "sparkles") }
            .disabled(session.segments.isEmpty || session.summarizer.isSummarizing)
        Button {
            AppNavigation.shared.section = .library
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        } label: { Label("Open Library…", systemImage: "books.vertical") }
        Button {
            AppNavigation.shared.section = .settings
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        } label: { Label("Settings…", systemImage: "gear") }

        Divider()

        Button { session.reset() } label: { Label("New recording", systemImage: "plus.circle") }
            .disabled(session.status == .recording)
        Button { SparkleUpdater.shared.checkOrInstall() } label: {
            Label(SparkleUpdater.shared.checkOrInstallTitle, systemImage: "arrow.down.circle")
        }
        .disabled(!SparkleUpdater.shared.canCheckOrInstall)

        Divider()

        Button { NSApp.terminate(nil) } label: { Label("Quit Daisy", systemImage: "power") }
            .keyboardShortcut("q")
    }
}
