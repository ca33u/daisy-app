//
//  SessionDiagnostics.swift
//  DaisyCore
//
//  backlog 4 B-4: per-session field-day numbers, written into the
//  transcript frontmatter as `daisy_diag_*` keys (§3.1: unknown keys are
//  ignored by every reader, so the Mac is unaffected) and read back by
//  the phone's Diagnostics screen. Battery is 0…1 as iOS reports it;
//  thermal is `ProcessInfo.ThermalState` by name; the two durations
//  are what the queue measured, in whole seconds.
//

import Foundation

public nonisolated struct SessionDiagnostics: Codable, Sendable, Equatable {
    public var batteryStart: Double?
    public var batteryStop: Double?
    public var thermalStart: String?
    public var thermalStop: String?
    /// The recording was started while the app was NOT in the foreground
    /// (a widget / Control Center / Action button tap).
    public var startedInBackground: Bool?
    /// Seconds between Stop and the transcription actually starting.
    public var queueWaitSec: Int?
    /// Seconds the transcription itself took.
    public var transcribeSec: Int?

    public init() {}

    public enum Key {
        public static let batteryStart = "daisy_diag_battery_start"
        public static let batteryStop = "daisy_diag_battery_stop"
        public static let thermalStart = "daisy_diag_thermal_start"
        public static let thermalStop = "daisy_diag_thermal_stop"
        public static let background = "daisy_diag_background"
        public static let queueWaitSec = "daisy_diag_queue_wait_sec"
        public static let transcribeSec = "daisy_diag_transcribe_sec"
    }

    /// Frontmatter lines, in a fixed order, only for the values known.
    public func fields() -> [FrontmatterField] {
        var out: [FrontmatterField] = []
        if let v = batteryStart { out.append(.init(key: Key.batteryStart, value: Self.format(v))) }
        if let v = batteryStop { out.append(.init(key: Key.batteryStop, value: Self.format(v))) }
        if let v = thermalStart { out.append(.init(key: Key.thermalStart, value: v)) }
        if let v = thermalStop { out.append(.init(key: Key.thermalStop, value: v)) }
        if let v = startedInBackground { out.append(.init(key: Key.background, value: v ? "true" : "false")) }
        if let v = queueWaitSec { out.append(.init(key: Key.queueWaitSec, value: String(v))) }
        if let v = transcribeSec { out.append(.init(key: Key.transcribeSec, value: String(v))) }
        return out
    }

    public static func parse(_ p: ParsedFrontmatter) -> SessionDiagnostics {
        var d = SessionDiagnostics()
        d.batteryStart = p[Key.batteryStart].flatMap(Double.init)
        d.batteryStop = p[Key.batteryStop].flatMap(Double.init)
        d.thermalStart = p[Key.thermalStart]
        d.thermalStop = p[Key.thermalStop]
        d.startedInBackground = p[Key.background].map { $0 == "true" }
        d.queueWaitSec = p[Key.queueWaitSec].flatMap(Int.init)
        d.transcribeSec = p[Key.transcribeSec].flatMap(Int.init)
        return d
    }

    public var isEmpty: Bool { fields().isEmpty }

    private static func format(_ battery: Double) -> String {
        String(format: "%.2f", battery)
    }
}
