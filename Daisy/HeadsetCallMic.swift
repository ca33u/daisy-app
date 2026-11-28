// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  HeadsetCallMic.swift
//  Daisy
//
//  Which microphone to record when the person is in a call on a
//  Bluetooth headset.
//
//  An unpinned recording stays off a Bluetooth headset's microphone
//  (`CoreAudioMicRecorder.resolveInputDeviceID`): a headset that is only
//  playing would be pulled into call mode by Daisy opening its mic — the
//  other side drops to phone quality, the system-audio tap is knocked
//  (`BluetoothInputHint`), and the field logs had that mic deliver silence.
//  A headset a call app has already put into call mode is a different
//  case: its microphone is what the other side hears and what the person
//  speaks into, while the built-in mic, the one Daisy took, hears them
//  faintly. Field log 19.11 (1.0.8.51, AirPods Pro at 24 kHz, the system
//  input left on the MacBook Air microphone): in a 46-minute meeting the
//  other side was transcribed, and the microphone track gave one segment.
//
//  A headset counts when both hold:
//    • another process runs input with the headset as the only
//      input-capable device in its list
//      (`AudioInputDevices.bluetoothInputsInUseElsewhere` says why «only»:
//      a voice-processing capture lists its output device too);
//    • the headset is in call mode: a nominal rate of 32 kHz or less.
//  The second is a guard against a listing that misleads in some way not
//  yet seen; the one the recording is already on needs only the first,
//  since Daisy then holds it in call mode itself.
//
//  A device the rule chose that then gave no buffers is left: back to the
//  device before, or to the usual choice, and out of the rule for the rest
//  of the recording (`CoreAudioMicRecorder.devicesGivingNoAudio`).
//
//  Nothing here has been run with a Bluetooth headset yet.
//

import CoreAudio
import Foundation

nonisolated enum HeadsetCallMic {
    /// Highest nominal rate taken for call mode. Classic HFP runs at 8 or
    /// 16 kHz, AirPods at 24 kHz (the field log), super-wideband HFP at
    /// 32 kHz; music mode at 44.1 or 48 kHz. A headset whose calls run at
    /// 44.1 kHz or more (LE Audio can) is not caught.
    static let callModeMaxRate: Double = 32_000

    /// The headsets other processes record from, given each process's
    /// input-capable devices (its input-scope device list, kept to devices
    /// with input streams). A process counts only when a headset is the one
    /// such device it lists — two can't say which one it records from
    /// (`AudioInputDevices.bluetoothInputsInUseElsewhere`). A device listed
    /// twice counts once.
    static func recordedHeadsets(inputLists: [[AudioDeviceID]], headsets: [AudioDeviceID]) -> [AudioDeviceID] {
        var found: [AudioDeviceID] = []
        for list in inputLists {
            let distinct = Set(list)
            guard distinct.count == 1, let device = distinct.first,
                  headsets.contains(device), !found.contains(device) else { continue }
            found.append(device)
        }
        return found
    }

    static func isCallModeRate(_ rate: Double) -> Bool {
        rate > 0 && rate <= callModeMaxRate
    }

    /// The headset to record from, or nil.
    /// - Parameters:
    ///   - inUse: Bluetooth microphones other processes record from, less
    ///     the devices that gave no audio in this recording.
    ///   - systemDefault: preferred when it is a candidate.
    ///   - bound: the device the recording is on; it needs no call-mode
    ///     proof (Daisy holds it in call mode itself).
    ///   - inCallMode: whether a headset is in call mode.
    static func pick(
        inUse: [AudioDeviceID], systemDefault: AudioDeviceID, bound: AudioDeviceID?,
        inCallMode: (AudioDeviceID) -> Bool
    ) -> AudioDeviceID? {
        let candidates = inUse.filter { $0 == bound || inCallMode($0) }
        if systemDefault != 0, candidates.contains(systemDefault) { return systemDefault }
        return candidates.first
    }
}

/// The running recording's half of the rule, read on the recorder's
/// 2-second silence-monitor tick. A call that puts a headset into call
/// mode after the recording started moves the recording onto it; once no
/// other process records from the headset the usual choice is asked
/// again, so that Daisy alone does not keep the headset in call mode.
///
/// Both moves wait for the same reading many ticks in a row. Each move
/// rebuilds the audio unit and may start a new part of the archive, and
/// the readings have short-lived causes: a dictation or Siri opens a
/// headset's mic for a few seconds (≈ 10 s of waiting before following),
/// and a call app may stop its input while muted (≈ 30 s before leaving).
nonisolated struct HeadsetCallWatch: Equatable {
    /// Ticks in a row a headset must be a candidate before the recording
    /// follows it: 8–10 s at a 2 s tick.
    static let ticksToFollow = 5
    /// Ticks in a row a Bluetooth mic the recording is on must be recorded
    /// by no other process before the usual choice is asked again: 28–30 s.
    static let ticksToReconsider = 15

    enum Step: Equatable {
        case stay
        /// Move the recording onto this headset.
        case follow(AudioDeviceID)
        /// Ask the usual device choice again; move if it picks another device.
        case reconsider
    }

    private var candidate: AudioDeviceID?
    private var seen = 0
    private var unused = 0

    /// - Parameters:
    ///   - bound: the device the recording is on.
    ///   - boundIsBluetooth: whether that device is a Bluetooth one.
    ///   - headset: the headset to be on (`HeadsetCallMic.pick`), or nil.
    mutating func observe(bound: AudioDeviceID?, boundIsBluetooth: Bool, headset: AudioDeviceID?) -> Step {
        if let headset, headset != bound {
            unused = 0
            if candidate == headset {
                seen += 1
            } else {
                candidate = headset
                seen = 1
            }
            guard seen >= Self.ticksToFollow else { return .stay }
            reset()
            return .follow(headset)
        }
        candidate = nil
        seen = 0
        guard boundIsBluetooth, headset == nil else {
            unused = 0
            return .stay
        }
        unused += 1
        guard unused >= Self.ticksToReconsider else { return .stay }
        unused = 0
        return .reconsider
    }

    /// Forget the counting (a resume, a route change, a move).
    mutating func reset() {
        candidate = nil
        seen = 0
        unused = 0
    }
}
