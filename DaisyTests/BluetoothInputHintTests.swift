//
//  BluetoothInputHintTests.swift
//  DaisyTests
//
//  B-2 (19.10): the "pick the built-in microphone" hint is for a
//  Bluetooth headset as the system input, once per headset.
//

import Foundation
import Testing
@testable import Daisy

struct BluetoothInputHintTests {
    @Test func onlyABluetoothInputGetsTheHint() {
        #expect(BluetoothInputHint.shouldShow(transport: "bluetooth", uid: "AC-80:input", shown: []))
        #expect(BluetoothInputHint.shouldShow(transport: "bluetoothLE", uid: "AC-80:input", shown: []))
        for transport in ["builtin", "usb", "virtual", "aggregate", "?"] {
            #expect(!BluetoothInputHint.shouldShow(transport: transport, uid: "x", shown: []))
        }
    }

    @Test func oncePerHeadset() {
        #expect(!BluetoothInputHint.shouldShow(transport: "bluetooth", uid: "AC-80:input", shown: ["AC-80:input"]))
        #expect(BluetoothInputHint.shouldShow(transport: "bluetooth", uid: "other:input", shown: ["AC-80:input"]))
    }

    @Test func aHeadsetWithoutAUIDIsNeverNagged() {
        #expect(!BluetoothInputHint.shouldShow(transport: "bluetooth", uid: "", shown: []))
    }
}
