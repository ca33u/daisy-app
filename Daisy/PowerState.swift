//
//  PowerState.swift
//  Daisy
//
//  Is the Mac on battery or in Low Power Mode? Drives «Process later,
//  on a charger» (Egor, 07.10.2026): a 32-minute meeting took its whole
//  final pass on battery under Low Power Mode, minutes of Whisper the
//  person paid for in charge and waited for on screen.
//
//  Battery vs AC comes from IOKit's power-source snapshot and its change
//  notification; Low Power Mode from ProcessInfo and its notification.
//  A desktop Mac has no battery and always reads as on AC.
//

import Foundation
import IOKit.ps
import Observation
import os

@Observable
@MainActor
final class PowerState {
    static let shared = PowerState()

    private(set) var onBattery = false
    private(set) var lowPowerMode = false

    /// Heavy work should wait: on battery, or Low Power Mode is on.
    var isConstrained: Bool { onBattery || lowPowerMode }

    /// Called on every change, after the values are updated.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var lowPowerObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let log = Logger(subsystem: "app.essazanov.Daisy", category: "PowerState")

    private init() {
        refresh()
    }

    /// Start listening. Idempotent.
    func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let state = Unmanaged<PowerState>.fromOpaque(context).takeUnretainedValue()
            // IOKit calls back on the run loop the source was added to —
            // the main one.
            MainActor.assumeIsolated { state.refresh() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        let battery = Self.readOnBattery()
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard battery != onBattery || lowPower != lowPowerMode else { return }
        onBattery = battery
        lowPowerMode = lowPower
        log.info("Power: \(battery ? "battery" : "AC", privacy: .public), Low Power Mode \(lowPower ? "on" : "off", privacy: .public)")
        onChange?()
    }

    nonisolated private static func readOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? else {
            return false
        }
        return type == kIOPSBatteryPowerValue
    }
}
