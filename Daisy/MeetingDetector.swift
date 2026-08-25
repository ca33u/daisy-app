//
//  MeetingDetector.swift
//  Daisy
//
//  Watches NSWorkspace for known meeting apps launching and fires a
//  callback so RecordingSession can auto-start. v0.1 limitation:
//  browser-based meetings (Google Meet in Chrome / Safari) aren't
//  detectable this way — bundle id stays "com.google.Chrome"
//  regardless of the tab. EventKit / Calendar integration (Phase 7)
//  will cover that case by reacting to scheduled meeting events
//  rather than process launches.
//
//  Only NEW launches during Daisy's lifetime trigger auto-start: if
//  Zoom is already running when Daisy starts we DON'T auto-start (the
//  user is treated as already in a meeting they didn't ask to record).
//  NSWorkspace's didLaunchApplicationNotification gives us that for
//  free — it only fires for launches after the observer is installed.
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class MeetingDetector {
    static let shared = MeetingDetector()

    /// One entry in the "offer to record when this launches" list.
    ///
    /// A single app can ship several bundle ids (Teams modern/legacy,
    /// two Webex builds, Telegram macOS/Desktop). They are grouped so
    /// the user toggles "Telegram" once rather than hunting two opaque
    /// reverse-DNS strings that have to be flipped in lockstep.
    nonisolated struct MeetingApp: Identifiable, Hashable, Sendable {
        let name: String
        let bundleIDs: [String]
        let isBuiltIn: Bool
        /// Stable across launches (unlike a Set's iteration order), which
        /// is what `ForEach` needs to avoid re-shuffling the rows.
        nonisolated var id: String { bundleIDs.joined(separator: "|") }
    }

    /// Apps we consider "a meeting is happening" when they launch, in
    /// display order. Conservative list — better to miss a niche app
    /// than to auto-record someone's FaceTime to grandma. FaceTime is
    /// absent on purpose; a user who wants it adds it themselves.
    ///
    /// Single source of truth for both `builtInMeetingBundleIDs` and
    /// `displayName(for:)`: with two lists an app added to one and
    /// forgotten in the other is detectable but nameless (or named but
    /// dead), and nothing catches it at compile time.
    ///
    /// Every entry ships switched ON. Telegram in particular fires on
    /// plain messenger launches, not just calls — which is a prompt
    /// twenty times a day for someone who chats there — so the answer
    /// is the switch below, not removing it from the list: the user who
    /// takes Telegram calls still wants it detected.
    nonisolated static let builtInMeetingApps: [MeetingApp] = [
        MeetingApp(name: "Zoom", bundleIDs: ["us.zoom.xos"], isBuiltIn: true),
        // Modern + legacy Teams.
        MeetingApp(name: "Microsoft Teams",
                   bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"],
                   isBuiltIn: true),
        MeetingApp(name: "Webex",
                   bundleIDs: ["com.webex.meetingmanager", "com.cisco.webexmeetingsapp"],
                   isBuiltIn: true),
        MeetingApp(name: "GoToMeeting", bundleIDs: ["com.logmein.GoToMeeting"], isBuiltIn: true),
        MeetingApp(name: "BlueJeans", bundleIDs: ["com.bluejeansnet.BlueJeans"], isBuiltIn: true),
        MeetingApp(name: "Skype", bundleIDs: ["com.skype.skype"], isBuiltIn: true),
        // Telegram macOS + Telegram Desktop's alternate id.
        MeetingApp(name: "Telegram",
                   bundleIDs: ["ru.keepcoder.Telegram", "org.telegram.desktop"],
                   isBuiltIn: true),
        MeetingApp(name: "Discord", bundleIDs: ["com.hnc.Discord"], isBuiltIn: true),
    ]

    /// Flat id set of what Daisy ships with.
    ///
    /// Read `meetingBundleIDs()` rather than this, unless you genuinely
    /// mean "the ones Daisy ships with, switched off ones included": the
    /// user's own additions are just as much a meeting app as Zoom is,
    /// and an app they switched off is not one at all.
    nonisolated static let builtInMeetingBundleIDs: Set<String> =
        Set(builtInMeetingApps.flatMap(\.bundleIDs))

    // MARK: - User-added apps

    /// An app the user added to the detection list themselves.
    ///
    /// The name is captured at add time from the bundle on disk, so the
    /// list stays readable even for an app that is later moved or
    /// uninstalled — showing a bare `com.example.thing` for something
    /// the user picked by clicking its icon would be a poor trade for
    /// saving a string.
    nonisolated struct CustomApp: Codable, Hashable, Identifiable, Sendable {
        let bundleID: String
        let name: String
        nonisolated var id: String { bundleID }
    }

    nonisolated static let customAppsKey = "daisy.customMeetingApps"

    /// Apps the user added. Persisted as JSON; mutations write through.
    var customApps: [CustomApp] = [] {
        didSet {
            guard customApps != oldValue else { return }
            // Bail rather than store `Data()`: an unreadable value would
            // leave the Settings list showing apps that detection no
            // longer knows about, and drop them entirely on next launch.
            // Keeping the last good value is the better failure.
            guard let data = try? JSONEncoder().encode(customApps) else { return }
            UserDefaults.standard.set(data, forKey: Self.customAppsKey)
        }
    }

    /// The user's list, read straight from UserDefaults.
    ///
    /// `nonisolated` because the NSWorkspace observer closure is not
    /// isolated, and because a cached snapshot would need invalidating
    /// from every mutation site. Reading it fresh each time is also what
    /// makes an added app take effect immediately: the observer resolves
    /// the id set at notification time, not when `start()` ran.
    /// UserDefaults is thread-safe, and no caller is hot — the busiest
    /// is one screenshot tick.
    nonisolated static func storedCustomApps() -> [CustomApp] {
        guard let data = UserDefaults.standard.data(forKey: customAppsKey),
              let apps = try? JSONDecoder().decode([CustomApp].self, from: data) else {
            return []
        }
        return apps
    }

    // MARK: - Switched-off apps

    nonisolated static let disabledAppsKey = "daisy.disabledMeetingApps"

    /// Bundle ids the user switched OFF in Settings.
    ///
    /// Stored as an opt-OUT list rather than an "enabled" list on
    /// purpose: a built-in added in a future release then arrives
    /// switched on for everyone, instead of being invisibly absent from
    /// every existing install's stored enabled-set. Custom apps the user
    /// switched off keep their entry in `customApps` so the row (and the
    /// switch) survives — being off is not the same as being deleted.
    var disabledBundleIDs: Set<String> = [] {
        didSet {
            guard disabledBundleIDs != oldValue else { return }
            // Sorted so the plist diff is stable between writes.
            UserDefaults.standard.set(disabledBundleIDs.sorted(), forKey: Self.disabledAppsKey)
        }
    }

    /// The opt-out list, read straight from UserDefaults — `nonisolated`
    /// for the same reason `storedCustomApps()` is: the NSWorkspace
    /// observer resolves the id set at notification time, so a switch
    /// flipped in Settings takes effect on the very next launch.
    nonisolated static func storedDisabledBundleIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: disabledAppsKey) ?? [])
    }

    /// Every bundle id whose LAUNCH offers to start a recording: what
    /// Daisy ships with, plus what the user added, minus what they
    /// switched off. Hoist this out of loops — it decodes JSON.
    nonisolated static func meetingBundleIDs() -> Set<String> {
        allKnownMeetingBundleIDs().subtracting(storedDisabledBundleIDs())
    }

    /// Every app Daisy recognises as a call app, switch or no switch.
    ///
    /// Distinct from `meetingBundleIDs()` on purpose. The switch answers
    /// "should launching this ask me to record?" — it is not a claim
    /// that the app stopped hosting calls. Heuristics that merely
    /// RECOGNISE a call window (`ScreenshotCapture.pickDisplay` picking
    /// the monitor the call is on) must keep working for an app the user
    /// switched off and then recorded by hand.
    nonisolated static func allKnownMeetingBundleIDs() -> Set<String> {
        builtInMeetingBundleIDs.union(storedCustomApps().map(\.bundleID))
    }

    // MARK: - The list the user manages

    /// Built-ins (ship order) followed by the user's own additions.
    ///
    /// An instance property, not a static one, precisely so reading it
    /// from a SwiftUI body registers observation on `customApps` — the
    /// Settings list re-renders when an app is added or removed.
    var meetingApps: [MeetingApp] {
        Self.builtInMeetingApps + customApps.map {
            MeetingApp(name: $0.name, bundleIDs: [$0.bundleID], isBuiltIn: false)
        }
    }

    /// Whether launching this app still offers to record. "At least one
    /// live id" rather than "no dead ids": a half-disabled group would
    /// genuinely still fire, and a switch that reads OFF while detection
    /// runs is the worse lie. Toggling it repairs the group either way.
    func isEnabled(_ app: MeetingApp) -> Bool {
        app.bundleIDs.contains { !disabledBundleIDs.contains($0) }
    }

    /// Flip one app on/off, moving every id in the group together.
    func setEnabled(_ enabled: Bool, for app: MeetingApp) {
        if enabled {
            disabledBundleIDs.subtract(app.bundleIDs)
        } else {
            disabledBundleIDs.formUnion(app.bundleIDs)
        }
    }

    /// Drop a user-added app entirely. Built-ins can only be switched
    /// off — there is nothing to delete, they come back on next launch.
    func removeCustomApp(_ app: MeetingApp) {
        guard !app.isBuiltIn else { return }
        customApps.removeAll { app.bundleIDs.contains($0.bundleID) }
        // Don't leave the opt-out behind: re-adding the same app later
        // has to come back switched ON, not silently dead.
        disabledBundleIDs.subtract(app.bundleIDs)
    }

    /// Last detected bundle id, for UI display ("Auto-started: Zoom").
    var lastDetected: String? = nil

    private var observer: NSObjectProtocol?
    private var onMeetingStart: ((String) -> Void)?

    private init() {
        customApps = Self.storedCustomApps()
        disabledBundleIDs = Self.storedDisabledBundleIDs()
    }

    /// Begin watching for meeting-app launches. Replaces any existing
    /// observer. Fires the callback immediately when a known meeting app
    /// launches — no debounce (the old user-tunable "detection delay" was
    /// removed in 1.0.7.16; a rare false start is undone via the
    /// "Recording started · Stop & save" banner). Only NEW launches during
    /// Daisy's lifetime trigger it — `didLaunchApplicationNotification`
    /// never fires for apps already running when the observer is installed.
    func start(onMeetingStart: @escaping (String) -> Void) {
        stop()
        self.onMeetingStart = onMeetingStart
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let info = note.userInfo,
                let app = info[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let bundleID = app.bundleIdentifier,
                Self.meetingBundleIDs().contains(bundleID)
            else { return }
            // Hop onto the main actor — observer fires on the main
            // queue but the closure capture context isn't isolated.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastDetected = bundleID
                self.onMeetingStart?(bundleID)
            }
        }
    }

    /// Stop observing. Safe to call multiple times.
    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        onMeetingStart = nil
    }

    /// Pretty name for a bundle id, for UI display. Curated names win;
    /// then the name captured when the user added the app; then the raw
    /// id, which is at least searchable. Note the built-in scan runs
    /// first so the (JSON-decoding) custom lookup is only paid for ids
    /// Daisy doesn't ship with.
    nonisolated static func displayName(for bundleID: String) -> String {
        if let app = builtInMeetingApps.first(where: { $0.bundleIDs.contains(bundleID) }) {
            return app.name
        }
        return storedCustomApps().first { $0.bundleID == bundleID }?.name ?? bundleID
    }
}
