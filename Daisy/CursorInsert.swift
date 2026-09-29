//
//  CursorInsert.swift
//  Daisy
//
//  Backlog 24 М-10: «Insert at cursor» — a next step or the follow-up goes
//  into the app the person was in before Daisy: a mail being written, a
//  chat. Daisy hands the focus back to that app and puts the text where
//  its caret is, by the dictation's own road (Accessibility first, typed
//  keys for web views, the clipboard with its restore only as the last
//  resort). The step's status says where it went: `sent: paste` with the
//  app's name, in `summary.json` beside the phone's statuses.
//

import AppKit
import DaisyCore
import os

/// The last app in front that was not Daisy — where «Insert at cursor»
/// goes. Watches activations from launch.
@MainActor
@Observable
final class PreviousAppTracker {
    static let shared = PreviousAppTracker()

    private(set) var previous: NSRunningApplication?
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// Its name, while it is still running.
    var name: String? {
        guard let previous, !previous.isTerminated else { return nil }
        return previous.localizedName
    }

    func start() {
        guard observer == nil else { return }
        if let front = NSWorkspace.shared.frontmostApplication, !Self.isDaisy(front) { previous = front }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let app, !Self.isDaisy(app) else { return }
                PreviousAppTracker.shared.previous = app
            }
        }
    }

    nonisolated static func isDaisy(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier == ProcessInfo.processInfo.processIdentifier
            || app.bundleIdentifier == Bundle.main.bundleIdentifier
    }
}

@MainActor
enum CursorInsert {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "CursorInsert")

    /// Hands the focus back and inserts. Returns the app's name when the
    /// text went to it, nil when there was nowhere to go.
    @discardableResult
    static func insert(_ text: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let app = PreviousAppTracker.shared.previous, !app.isTerminated else {
            ToastCenter.shared.show(
                String(localized: "Open a mail or a chat, then come back and insert."),
                style: .info
            )
            return nil
        }
        let name = app.localizedName ?? ""
        app.activate()
        // Wait for it to be in front, then a beat for its window to take
        // the key focus back — typing before that lands in Daisy.
        for _ in 0..<40 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            try? await Task.sleep(for: .milliseconds(25))
        }
        try? await Task.sleep(for: .milliseconds(200))
        log.info("Inserting a step (\(trimmed.count) chars) into \(name, privacy: .public)")
        DictationPaste.shared.insert(trimmed)
        return name
    }
}

/// The phone's status on a step, written by the Mac: one key of one item
/// in `summary.json`'s `actions`, everything else in the file untouched
/// (the JSON is patched, not re-encoded through this app's model, which
/// does not know `actions`). A file without `actions` gets them, read from
/// the strings the way every reader does (ActionItem.legacy).
enum ActionStatusWriter {
    /// М-10: sent, by paste, into which app.
    static func markPasted(step index: Int, into app: String, in directory: URL) {
        set(.init(state: .sent, destination: "paste", identifier: app), forStep: index, in: directory)
    }

    /// М-1: every step nothing else has claimed went to the participants.
    static func markRecapSent(steps count: Int, in directory: URL) {
        for index in 0..<count where !hasStatus(index, in: directory) {
            set(.init(state: .sent, destination: "participants"), forStep: index, in: directory)
        }
    }

    private static func hasStatus(_ index: Int, in directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("summary.json")),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let actions = root["actions"] as? [[String: Any]], actions.indices.contains(index) else { return false }
        return actions[index]["status"] != nil
    }

    static func set(_ status: ActionItem.Status, forStep index: Int, in directory: URL) {
        let url = directory.appendingPathComponent("summary.json")
        guard let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        var actions = root["actions"] as? [[String: Any]] ?? []
        if actions.isEmpty {
            let strings = root["actionItems"] as? [String] ?? []
            let encoder = JSONEncoder()
            actions = strings.enumerated().compactMap { i, text in
                (try? encoder.encode(ActionItem.legacy(text, index: i)))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            }
        }
        guard actions.indices.contains(index),
              let encoded = try? JSONEncoder().encode(status),
              let statusObject = try? JSONSerialization.jsonObject(with: encoded) else { return }
        actions[index]["status"] = statusObject
        root["actions"] = actions
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? out.write(to: url, options: .atomic)
    }
}
