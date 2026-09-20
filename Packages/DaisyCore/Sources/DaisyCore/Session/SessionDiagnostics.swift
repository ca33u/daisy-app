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
    /// backlog 6 F-1: decode time over audio time (0.10 = ten minutes
    /// of audio in one minute), and the process's peak physical
    /// footprint after the pass, in MB — the two numbers the backlog
    /// wants from the real phone, per session, not from a one-off run.
    public var transcribeRTF: Double?
    public var peakMemoryMB: Int?

    public init() {}

    public enum Key {
        public static let batteryStart = "daisy_diag_battery_start"
        public static let batteryStop = "daisy_diag_battery_stop"
        public static let thermalStart = "daisy_diag_thermal_start"
        public static let thermalStop = "daisy_diag_thermal_stop"
        public static let background = "daisy_diag_background"
        public static let queueWaitSec = "daisy_diag_queue_wait_sec"
        public static let transcribeSec = "daisy_diag_transcribe_sec"
        public static let transcribeRTF = "daisy_diag_transcribe_rtf"
        public static let peakMemoryMB = "daisy_diag_peak_memory_mb"
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
        if let v = transcribeRTF { out.append(.init(key: Key.transcribeRTF, value: String(format: "%.3f", v))) }
        if let v = peakMemoryMB { out.append(.init(key: Key.peakMemoryMB, value: String(v))) }
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
        d.transcribeRTF = p[Key.transcribeRTF].flatMap(Double.init)
        d.peakMemoryMB = p[Key.peakMemoryMB].flatMap(Int.init)
        return d
    }

    /// The process's peak physical footprint so far, in MB (the number
    /// Xcode's memory gauge and Jetsam look at), or nil where the kernel
    /// won't say.
    public static func peakFootprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let peak = info.ledger_phys_footprint_peak > 0 ? info.ledger_phys_footprint_peak : Int64(info.phys_footprint)
        return Int(peak / 1_048_576)
    }

    public var isEmpty: Bool { fields().isEmpty }

    private static func format(_ battery: Double) -> String {
        String(format: "%.2f", battery)
    }
}
