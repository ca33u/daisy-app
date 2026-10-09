//
//  CrashReports.swift
//  Daisy
//
//  Crash reports only when the person sends one (backlog 27 С-2, decided by
//  Egor 2026-10-09). Daisy's promise is that nothing leaves the Mac without
//  an explicit action, so a crash is never reported on its own: Sentry
//  catches it, and on the next launch Daisy asks — showing exactly what the
//  report holds — before anything goes out.
//
//  What a report may carry: where in the code Daisy failed (the stack), the
//  app version, macOS and the Mac's model. Never meeting text, titles,
//  names, file paths (the home folder is cut), device names, logs or IP.
//  Everything else Sentry can collect is off: sessions, breadcrumbs,
//  network and hang tracking, tracing, swizzling.
//
//  Settings → About: "Crash reports: Ask every time / Never send". "Never"
//  doesn't start Sentry at all — no crash handler, no connection — from the
//  next launch. Uncaught NSExceptions are caught too: that needs method
//  swizzling, which is on for that alone (see `configure`).
//

import AppKit
import Foundation
import Sentry
import os

nonisolated enum CrashReports {
    /// Project daisy-mac, org daisy-30, region EU. A DSN only says where to
    /// send; it ships inside the app either way.
    static let dsn = "https://ec9125c256266d3451dfea250812bc20@o4512219671625728.ingest.de.sentry.io/4512225920221264"

    enum Mode: String, CaseIterable, Sendable {
        case ask
        case never
    }

    static let modeKey = "daisy.crashReportsMode"

    static var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "CrashReports")

    /// The crash event held for the person's answer, and the id of the one
    /// they agreed to send — by id, so no other event can take the approval.
    private final class Hold: @unchecked Sendable {
        let lock = OSAllocatedUnfairLock<(pending: Event?, approved: SentryId?)>(uncheckedState: (nil, nil))
    }
    private static let hold = Hold()

    /// Call once at launch, before the first window.
    static func start() {
        guard mode == .ask else { return }
        SentrySDK.start { options in configure(options) }
    }

    /// Every option, in one place so a test can start the SDK exactly as
    /// the app does.
    static func configure(_ options: Options) {
        options.dsn = dsn
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        options.releaseName = "daisy-macos@\(version)+\(build)"
        #if DEBUG
        options.environment = "debug"
        #endif
        options.sendDefaultPii = false
        options.enableAutoSessionTracking = false
        options.maxBreadcrumbs = 0
        // Uncaught NSExceptions (Egor, 2026-10-09: yes). sentry-cocoa hooks
        // them only through method swizzling, so swizzling is on — for
        // that alone. Everything else swizzling could feed is off, and no
        // request is ever traced: `tracePropagationTargets` is empty, so
        // no `sentry-trace` / `baggage` header reaches Anthropic, OpenAI,
        // Notion, Google or Sparkle (test). Side effect, accepted: an
        // exception AppKit used to swallow now ends Daisy — and is caught.
        options.enableSwizzling = true
        options.enableUncaughtNSExceptionReporting = true
        options.enableNetworkTracking = false
        options.enableNetworkBreadcrumbs = false
        options.enableAutoBreadcrumbTracking = false
        options.enableAutoPerformanceTracing = false
        options.enableCaptureFailedRequests = false
        options.enableAppHangTracking = false
        options.tracePropagationTargets = []
        options.tracesSampleRate = 0
        // Discarded-event counts would ride along on the one report the
        // person approved, unseen in the preview.
        options.sendClientReports = false
        options.beforeSend = { event in
            let send = hold.lock.withLock { state -> Bool in
                if let approved = state.approved, approved == event.eventId {
                    state.approved = nil
                    return true
                }
                state.pending = event
                return false
            }
            if send { return scrub(event) }
            DispatchQueue.main.async { askToSend() }
            return nil
        }
    }

    /// What survives: the failure (exceptions, threads, binary images), the
    /// release and level, and an allowlist of the device, OS and app
    /// contexts. Everything else — user, request, breadcrumbs, tags, extra,
    /// the exception's userInfo, the locale, the Mac's name, the memory and
    /// boot figures the SDK adds when the report is sent — goes, so what is
    /// sent is what the preview showed. The home folder is cut from every
    /// string that remains.
    static func scrub(_ event: Event) -> Event {
        event.user = nil
        event.request = nil
        event.breadcrumbs = nil
        event.extra = nil
        event.tags = nil
        event.serverName = nil
        event.message = nil
        let allowed: [String: Set<String>] = [
            "device": ["model", "model_id", "arch", "family", "simulator"],
            "os": ["name", "version", "build"],
            "app": ["app_version", "app_build", "app_identifier", "build_type"],
        ]
        var kept: [String: [String: Any]] = [:]
        for (name, fields) in allowed {
            if let section = event.context?[name] {
                kept[name] = section.filter { fields.contains($0.key) }
            }
        }
        event.context = kept.isEmpty ? nil : kept

        let home = NSHomeDirectory()
        func clean(_ text: String?) -> String? { text?.replacingOccurrences(of: home, with: "~") }
        func cleanAny(_ value: Any) -> Any {
            switch value {
            case let text as String: return clean(text) ?? text
            case let dict as [String: Any]: return dict.mapValues(cleanAny)
            case let list as [Any]: return list.map(cleanAny)
            default: return value
            }
        }
        for exception in event.exceptions ?? [] {
            exception.value = clean(exception.value) ?? ""
            if let mechanism = exception.mechanism {
                mechanism.data = mechanism.data.map { $0.mapValues(cleanAny) }
                mechanism.desc = clean(mechanism.desc)
            }
            for frame in exception.stacktrace?.frames ?? [] {
                frame.package = clean(frame.package)
            }
        }
        for thread in event.threads ?? [] {
            thread.name = clean(thread.name)
            for frame in thread.stacktrace?.frames ?? [] {
                frame.package = clean(frame.package)
            }
        }
        for image in event.debugMeta ?? [] {
            image.codeFile = clean(image.codeFile)
        }
        return event
    }

    /// The text "What will be sent" shows: the report as it would leave.
    static func preview(_ event: Event) -> String {
        let scrubbed = scrub(event).serialize()
        guard let data = try? JSONSerialization.data(withJSONObject: scrubbed, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    @MainActor
    private static func askToSend() {
        guard let event = hold.lock.withLock({ $0.pending }) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Daisy closed unexpectedly")
        alert.informativeText = String(localized: "Send a crash report to the developer? It says where in the code Daisy failed, the app and macOS versions and the Mac model — never your meetings, names, files or devices. The whole report is below.")
        alert.addButton(withTitle: String(localized: "Send Report"))
        alert.addButton(withTitle: String(localized: "Don't Send"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don't ask again")

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 220))
        text.string = preview(event)
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 220))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll

        // A launch at login leaves Daisy behind other windows; bring the
        // question forward instead of holding a modal nobody sees.
        NSApp.activate()
        let answer = alert.runModal()
        hold.lock.withLock { $0.pending = nil }
        if alert.suppressionButton?.state == .on {
            mode = .never
        }
        guard answer == .alertFirstButtonReturn else {
            log.info("Crash report not sent")
            return
        }
        hold.lock.withLock { $0.approved = event.eventId }
        SentrySDK.capture(event: event)
        log.info("Crash report sent")
    }
}
