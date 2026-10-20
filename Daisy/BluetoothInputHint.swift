//
//  BluetoothInputHint.swift
//  Daisy
//
//  B-2 (backlog 32, 19.10). A Bluetooth headset set as the system's
//  default INPUT is what flips it into headset mode — HFP, 16 kHz mono —
//  the moment the call app takes its microphone: the other side drops to
//  phone quality for everyone, the route change knocks the process tap
//  (B-1), and the person hears it as «помехи». Daisy itself records from
//  the built-in microphone; the fix is in System Settings → Sound →
//  Input, and it is theirs to make. Said once per headset, at the start
//  of a meeting, with the button that opens the pane.
//

import AppKit
import Foundation

nonisolated enum BluetoothInputHint {
    /// UserDefaults: the headset UIDs the hint was shown for.
    static let shownKey = "daisy.bluetoothInputHintShownUIDs"

    /// Core Audio transport labels (`AudioInputDevices.transportLabel`)
    /// that mean a Bluetooth headset.
    static func isHeadset(transport: String) -> Bool {
        transport == "bluetooth" || transport == "bluetoothLE"
    }

    /// Once per headset: a device without a UID can't be remembered, so
    /// it is never nagged about either.
    static func shouldShow(transport: String, uid: String, shown: Set<String>) -> Bool {
        isHeadset(transport: transport) && !uid.isEmpty && !shown.contains(uid)
    }

    /// System Settings → Sound. The first form is the Ventura+ pane, the
    /// second the older one macOS still accepts.
    static let soundSettingsURLs = [
        "x-apple.systempreferences:com.apple.Sound-Settings.extension",
        "x-apple.systempreferences:com.apple.preference.sound",
    ]

    @MainActor
    static func openSoundSettings() {
        for string in soundSettingsURLs {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}
