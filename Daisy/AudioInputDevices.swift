//
//  AudioInputDevices.swift
//  Daisy
//
//  CoreAudio facade for enumerating microphone-capable input devices
//  and resolving a user-saved selection back to an `AudioDeviceID`.
//
//  Why CoreAudio instead of AVFoundation:
//   • `AVCaptureDevice.devices(for: .audio)` exists but targets the
//     AVCaptureSession pipeline (camera/photo) and is awkward to wire
//     into AVAudioEngine.
//   • AVAudioEngine's `inputNode` is internally a HAL audio unit
//     (AUHAL) — to point it at a specific device we have to call
//     `AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, …)`
//     with an `AudioDeviceID` anyway, so CoreAudio is the natural
//     source of truth.
//
//  Stability of identifiers:
//   • `AudioDeviceID` is a session-local UInt32 that can change when
//     devices are unplugged / replugged or after a reboot.
//   • `kAudioDevicePropertyDeviceUID` returns a CFString that is
//     stable across reboots and reconnects (e.g. for built-in mic
//     it's "BuiltInMicrophoneDevice"; for AirPods Pro it's the
//     pairing UID).
//   • We persist UID in `AppSettings.selectedMicDeviceUID` and
//     resolve it back to a fresh `AudioDeviceID` at every recording
//     start. If the saved device is gone (unplugged), we fall back
//     to system default.
//

import CoreAudio
import Foundation
import IOKit
import os

/// One input-capable audio device visible to the system.
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    /// Stable across reboots and reconnects. Persist this, not `id`.
    let uid: String
    /// Human-readable device name (e.g. "MacBook Pro Microphone",
    /// "AirPods Pro", "Shure MV7"). Surfaced in the Settings picker.
    let name: String
    /// True if this is the device macOS would pick on its own — i.e.
    /// the same device a `nil` `selectedMicDeviceUID` would route to.
    let isSystemDefault: Bool
}

enum AudioInputDevices {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "AudioInputDevices")

    /// Enumerate every connected input device with the system default
    /// flagged. Returns an empty array if any CoreAudio call fails —
    /// the caller treats that the same as "no selection possible",
    /// which silently falls back to the system default behaviour.
    static func list() -> [AudioInputDevice] {
        let ids = allDeviceIDs()
        guard !ids.isEmpty else { return [] }
        let defaultID = systemDefaultInputID()
        return ids.compactMap { id -> AudioInputDevice? in
            guard hasInputStreams(id) else { return nil }
            guard let uid = deviceUID(id), !uid.isEmpty else { return nil }
            let name = deviceName(id) ?? "Unknown input"
            return AudioInputDevice(
                id: id,
                uid: uid,
                name: name,
                isSystemDefault: id == defaultID
            )
        }
    }

    /// Look up the live `AudioDeviceID` for a previously-saved UID.
    /// Returns nil if the device has been disconnected, or if it's
    /// present but no longer reports input streams (e.g. user
    /// re-routed a multi-channel interface).
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        for id in allDeviceIDs() {
            if deviceUID(id) == uid, hasInputStreams(id) {
                return id
            }
        }
        return nil
    }

    /// Best NON-Bluetooth input device, or nil if every input is BT.
    /// A Bluetooth headset used for OUTPUT drags the default INPUT onto
    /// its SCO mic, which delivers pure silence while the headset is
    /// playing audio (A2DP↔SCO can't run simultaneously). When we're not
    /// pinned to a specific device we avoid that mic and prefer the
    /// built-in. Prefers the built-in mic; else the first wired/USB input.
    static func firstNonBluetoothInputID() -> AudioDeviceID? {
        let ids = allDeviceIDs().filter { hasInputStreams($0) && !isBluetooth($0) }
        guard !ids.isEmpty else { return nil }
        if let builtIn = ids.first(where: {
            (deviceUID($0) ?? "").contains("BuiltInMicrophone")
        }) {
            return builtIn
        }
        return ids.first
    }

    /// Stable UID for a live `AudioDeviceID`, or nil if CoreAudio can't
    /// resolve it. The inverse of `deviceID(forUID:)`. `AudioRecorder`
    /// uses this to remember — by stable identity, not the session-local
    /// `AudioDeviceID` — which device a recording is actually bound to,
    /// so a mid-session Bluetooth default-input flip can be told apart
    /// from the device the user/engine is on.
    static func uid(for id: AudioDeviceID) -> String? {
        return deviceUID(id)
    }

    /// True if `id` uses a Bluetooth transport (or, for an aggregate,
    /// any active sub-device does). Lets the route-change recovery gate
    /// its "keep the current mic" decision on transport: connecting
    /// AirPods for *output* drags the default *input* onto their SCO
    /// mic, which frequently delivers pure silence — we want to ignore
    /// that flip, but still follow an intentional wired/USB input
    /// change. Aggregate-aware (AirPods nested in a multi-output
    /// aggregate still read as Bluetooth). Mirrors the equivalent check
    /// on the system-audio (output) side in `SystemAudioCapture`.
    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        guard let transportType = transportType(id) else { return false }

        if transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE {
            return true
        }

        // Aggregate? Drill into the active sub-devices once (no deep
        // recursion — a direct transport check per sub covers the real
        // configs we care about, e.g. AirPods inside a multi-output).
        guard transportType == kAudioDeviceTransportTypeAggregate else {
            return false
        }
        var subDevicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var subDevicesSize: UInt32 = 0
        let szStatus = AudioObjectGetPropertyDataSize(
            id, &subDevicesAddress, 0, nil, &subDevicesSize
        )
        guard szStatus == noErr, subDevicesSize > 0 else { return false }

        let count = Int(subDevicesSize) / MemoryLayout<AudioObjectID>.size
        var subDevices = [AudioObjectID](repeating: 0, count: count)
        let listStatus = subDevices.withUnsafeMutableBufferPointer { buf -> OSStatus in
            var sz = subDevicesSize
            return AudioObjectGetPropertyData(
                id, &subDevicesAddress, 0, nil, &sz, buf.baseAddress!
            )
        }
        guard listStatus == noErr else { return false }

        for sub in subDevices where sub != kAudioObjectUnknown {
            var subTransport: UInt32 = 0
            var subSize = UInt32(MemoryLayout<UInt32>.size)
            var subAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let s = AudioObjectGetPropertyData(
                sub, &subAddress, 0, nil, &subSize, &subTransport
            )
            if s == noErr,
               subTransport == kAudioDeviceTransportTypeBluetooth
                || subTransport == kAudioDeviceTransportTypeBluetoothLE {
                return true
            }
        }
        return false
    }

    // MARK: - Transport & virtual drivers

    /// Raw CoreAudio transport type, or nil when the device won't say.
    /// One reader for the whole file: `isBluetooth`, `isBuiltIn`,
    /// `firstExternalWiredInputID` and the diagnostics below all used to
    /// carry their own copy of this eleven-line dance.
    private static func transportType(_ id: AudioDeviceID) -> UInt32? {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport) == noErr else {
            return nil
        }
        return transport
    }

    /// Short, greppable transport name for diagnostics. Unknown types
    /// come out as their four-char code rather than "unknown" — a code
    /// we can look up beats a word that ends the investigation.
    static func transportLabel(_ id: AudioDeviceID) -> String {
        guard let transport = transportType(id) else { return "?" }
        return transportLabel(transportType: transport)
    }

    private static func transportLabel(transportType transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:     return "builtin"
        case kAudioDeviceTransportTypeAggregate:   return "aggregate"
        case kAudioDeviceTransportTypeVirtual:     return "virtual"
        case kAudioDeviceTransportTypeUSB:         return "usb"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        case kAudioDeviceTransportTypePCI:         return "pci"
        case kAudioDeviceTransportTypeFireWire:    return "firewire"
        case kAudioDeviceTransportTypeBluetooth:   return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "bluetoothLE"
        case kAudioDeviceTransportTypeHDMI:        return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        case kAudioDeviceTransportTypeAirPlay:     return "airplay"
        case kAudioDeviceTransportTypeAVB:         return "avb"
        case continuityWiredTransport:             return "continuity-wired"
        case continuityWirelessTransport:          return "continuity"
        case kAudioDeviceTransportTypeUnknown:     return "unknown"
        default:                                   return fourCharCode(transport)
        }
    }

    /// Continuity Capture transports (iPhone used as camera/mic).
    /// Spelled as raw four-char codes rather than the SDK constants so
    /// this file keeps compiling whatever SDK it's built against; a
    /// wrong guess costs nothing but a `'ccwl'` in the log instead of a
    /// word. An asleep Continuity mic can hold the default-input slot
    /// and deliver silence, so naming the transport matters here.
    private static let continuityWiredTransport: UInt32 = 0x6363_7764     // 'ccwd'
    private static let continuityWirelessTransport: UInt32 = 0x6363_776C  // 'ccwl'

    /// A CoreAudio constant back as its four printable characters.
    private static func fourCharCode(_ value: UInt32) -> String {
        let bytes = [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ]
        let text = bytes.map { byte -> String in
            (0x20...0x7E).contains(byte)
                ? String(UnicodeScalar(byte))
                : "?"
        }.joined()
        return "'\(text)'"
    }

    /// One known third-party virtual audio driver. `needles` are
    /// lowercased fragments matched against BOTH the device name and its
    /// UID — vendors are consistent in one or the other, rarely both
    /// (BlackHole names its devices "BlackHole 2ch", Rogue Amoeba hides
    /// the brand in a reverse-DNS UID).
    struct VirtualAudioDriver: Sendable {
        let product: String
        let needles: [String]
        /// True when the driver hands on REAL microphone audio (noise
        /// suppressors, EQs, voice changers, streaming mixers). Binding
        /// a recording to one of these is a working, deliberate setup —
        /// they belong in the log inventory, and nowhere near a warning.
        /// False for capture sinks (loopback devices), where a mic
        /// recording plausibly comes out empty.
        var passesMicAudio: Bool = false
    }

    /// Drivers we can name on sight. The point is not completeness —
    /// `kAudioDeviceTransportTypeVirtual` already catches the general
    /// case — it's that "BlackHole 2ch" in a log line means nothing to a
    /// reader who hasn't met it, while "Krisp (virtual driver)" answers
    /// the whole question of why a meeting recorded silence.
    ///
    /// Needles are matched as substrings of name + UID, so they're kept
    /// deliberately specific: `zoom` alone would flag Zoom Corporation's
    /// very real H6 and UAC-232 interfaces, `wave link` matches the
    /// software's virtual devices without touching an Elgato Wave:3.
    ///
    /// Deliberately absent: Multi-Output and Aggregate devices. They ARE
    /// visible in the inventory (transport `aggregate`), but a hand-built
    /// aggregate is a normal pro-audio rig, not a symptom.
    static let knownVirtualDrivers: [VirtualAudioDriver] = [
        // Capture sinks — audio goes IN, no microphone comes out.
        VirtualAudioDriver(product: "BlackHole", needles: ["blackhole", "existential audio"]),
        VirtualAudioDriver(product: "Loopback", needles: ["loopback audio", "com.rogueamoeba.loopback"]),
        VirtualAudioDriver(product: "Audio Hijack / ACE", needles: ["audio hijack", "rogueamoeba", "rogue amoeba"]),
        VirtualAudioDriver(product: "VB-Cable", needles: ["vb-cable", "vb-audio", "vbaudio"]),
        VirtualAudioDriver(product: "Soundflower", needles: ["soundflower"]),
        VirtualAudioDriver(product: "iShowU Audio Capture", needles: ["ishowu"]),
        VirtualAudioDriver(product: "Background Music", needles: ["bgmdevice"]),
        VirtualAudioDriver(product: "Zoom", needles: ["zoomaudiodevice", "zoom audio device"]),
        VirtualAudioDriver(product: "Microsoft Teams", needles: ["microsoft teams audio"]),
        VirtualAudioDriver(product: "Descript", needles: ["descript loopback", "descriptaudio"]),
        VirtualAudioDriver(product: "Ecamm", needles: ["ecamm"]),
        VirtualAudioDriver(product: "NDI", needles: ["ndi audio", "newtek ndi"]),
        VirtualAudioDriver(product: "Sound Siphon", needles: ["sound siphon"]),
        VirtualAudioDriver(product: "Screenflick", needles: ["screenflick"]),
        // Mic pass-throughs — a normal setup, reported but never warned
        // about. Krisp in particular is one of the most common mic
        // configurations among the people this feature is for.
        VirtualAudioDriver(product: "Krisp", needles: ["krisp"], passesMicAudio: true),
        VirtualAudioDriver(product: "eqMac", needles: ["eqmac"], passesMicAudio: true),
        VirtualAudioDriver(product: "Elgato Wave Link", needles: ["wave link", "elgato virtual"], passesMicAudio: true),
        VirtualAudioDriver(product: "Voicemod", needles: ["voicemod"], passesMicAudio: true),
        VirtualAudioDriver(product: "Boom", needles: ["boom 3d", "boom2device"], passesMicAudio: true),
    ]

    /// Signature-table entry matching `id`, else nil.
    static func virtualDriver(for id: AudioDeviceID) -> VirtualAudioDriver? {
        virtualDriver(name: deviceName(id) ?? "", uid: deviceUID(id) ?? "")
    }

    /// Same match against already-read strings — the inventory reads
    /// name and UID once per device and passes them down rather than
    /// making every predicate go back to the HAL. A wedged third-party
    /// driver is precisely what this code exists to diagnose, and each
    /// extra `AudioObjectGetPropertyData` is another chance to hang the
    /// report on it.
    private static func virtualDriver(name: String, uid: String) -> VirtualAudioDriver? {
        let haystack = "\(name) \(uid)".lowercased()
        guard haystack.contains(where: { !$0.isWhitespace }) else { return nil }
        return knownVirtualDrivers.first { driver in
            driver.needles.contains { needle in haystack.contains(needle) }
        }
    }

    /// UID prefix of the private aggregate device the process-tap
    /// backend builds (`ProcessTapAudioCapture`). Ours shows up in our
    /// own device list — a private aggregate is visible to its creator —
    /// and must never be reported as somebody else's virtual driver.
    private static let ownDeviceUIDPrefix = "app.essazanov.Daisy."

    /// True when `id` is a device Daisy itself created.
    static func isOwnDevice(_ id: AudioDeviceID) -> Bool {
        (deviceUID(id) ?? "").hasPrefix(ownDeviceUIDPrefix)
    }

    /// True when a device is a virtual one belonging to some other app —
    /// a recognised driver, or anything the HAL itself calls `virtual`.
    /// NOT aggregates (see `knownVirtualDrivers`), and callers screen
    /// out Daisy's own tap aggregate before asking.
    ///
    /// This is an inventory label, not a verdict: it covers the mic
    /// pass-throughs too, because a report wants to see Krisp in the
    /// chain even though Krisp is working as intended.
    private static func isForeignVirtual(driver: VirtualAudioDriver?, transport: UInt32?) -> Bool {
        if driver != nil { return true }
        return transport == kAudioDeviceTransportTypeVirtual
    }

    /// True when recording a MICROPHONE from `id` plausibly yields
    /// nothing: a foreign virtual device that isn't one of the known mic
    /// pass-throughs. An unrecognised `virtual` transport counts — we
    /// can't vouch for a driver we've never met, and the cost of the
    /// warning is one dismissible line.
    ///
    /// The caller warns, it never blocks or re-routes: routing a meeting
    /// through BlackHole can be exactly what the user meant.
    static func virtualInputMayBeSilent(_ id: AudioDeviceID) -> Bool {
        guard id != 0, !isOwnDevice(id) else { return false }
        let driver = virtualDriver(for: id)
        guard isForeignVirtual(driver: driver, transport: transportType(id)) else { return false }
        return driver?.passesMicAudio != true
    }

    /// Public read of a device's display name — the string the user sees
    /// in the macOS sound menu, so it's the one to name in a warning.
    static func name(for id: AudioDeviceID) -> String? {
        deviceName(id)
    }

    /// Every input and output device, one per line, for the log report.
    ///
    /// Written after a class of field reports that could not be
    /// diagnosed at all: another app's virtual driver (a rival notetaker,
    /// Krisp, a Loopback rig) takes over the default input or output, the
    /// meeting records silence or half a conversation, and the report
    /// showed a single device name with no hint that seven others were
    /// competing for the route. `*` marks the system default; `ours`
    /// marks a device Daisy created.
    ///
    /// UIDs are printed for INPUTS only. On the input side the UID is
    /// what you match against the pinned `selectedMicDeviceUID` to see
    /// whether the pin resolved; on the output side name + transport
    /// answer everything the block was written for, and a Bluetooth UID
    /// is the headset's pairing address — a stable hardware identifier
    /// for a device that's merely connected. Cheapest privacy there is:
    /// don't print what you don't read.
    ///
    /// Capped PER DIRECTION: duplex devices (every USB interface, every
    /// aggregate, BlackHole) emit a line each way, so a single combined
    /// cap would quietly eat the entire output section — half the reason
    /// the block exists.
    static func deviceInventory(limit: Int = 12) -> String {
        let ids = allDeviceIDs()
        guard !ids.isEmpty else { return "  (no audio devices)" }
        let defaultIn = systemDefaultInputID()
        let defaultOut = systemDefaultOutputID()

        func line(_ id: AudioDeviceID, direction: String, isDefault: Bool) -> String {
            // Read each property ONCE per device — see `virtualDriver`.
            let name = deviceName(id) ?? "?"
            let uid = deviceUID(id) ?? "?"
            let transport = transportType(id)
            let transportName = transport.map { transportLabel(transportType: $0) } ?? "?"
            let driver = virtualDriver(name: name, uid: uid)
            var parts = [
                "  \(direction)\(isDefault ? " *" : "  ")",
                "'\(name)'",
                "[\(transportName)]",
            ]
            if direction == "IN" {
                parts.append("ch=\(inputChannelCount(id))")
            }
            if let driver {
                parts.append("driver=\(driver.product)")
            }
            if uid.hasPrefix(ownDeviceUIDPrefix) {
                parts.append("ours")
            } else if isForeignVirtual(driver: driver, transport: transport) {
                parts.append("FOREIGN-VIRTUAL")
            }
            if direction == "IN" {
                parts.append("uid=\(uid)")
            }
            return parts.joined(separator: " ")
        }

        func section(_ direction: String, matching: (AudioDeviceID) -> Bool, defaultID: AudioDeviceID) -> [String] {
            var lines = ids.filter(matching).map {
                line($0, direction: direction, isDefault: $0 == defaultID)
            }
            if lines.count > limit {
                let dropped = lines.count - limit
                lines = Array(lines.prefix(limit))
                lines.append("  (+\(dropped) more \(direction))")
            }
            return lines
        }

        let inputs = section("IN", matching: { hasInputStreams($0) }, defaultID: defaultIn)
        let outputs = section("OUT", matching: { hasOutputStreams($0) }, defaultID: defaultOut)
        return (inputs + outputs).joined(separator: "\n")
    }

    // MARK: - CoreAudio plumbing

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        )
        guard sizeStatus == noErr, size > 0 else {
            if sizeStatus != noErr {
                log.error("AudioObjectGetPropertyDataSize failed (status \(sizeStatus, privacy: .public))")
            }
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
        )
        guard status == noErr else {
            log.error("AudioObjectGetPropertyData(devices) failed (status \(status, privacy: .public))")
            return []
        }
        return ids
    }

    /// System default input device ID. Exposed (not private) so
    /// `AudioRecorder.applyPreferredInputDevice(uid:)` can fall through
    /// to it explicitly when the user picked "System default" — pinning
    /// the AUHAL to the *current* default rather than leaving it bound
    /// to a stale ID after a route change. Returns 0 if CoreAudio fails;
    /// callers treat that the same as "no pinning possible".
    static func systemDefaultInputID() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id
        )
        return status == noErr ? id : 0
    }

    /// The system default OUTPUT device id (0 if CoreAudio refuses).
    /// Only used for diagnostics: a Bluetooth OUTPUT is the tell-tale
    /// for the AirPods capture failure — the system-audio loopback goes
    /// silent and the SCO mic drops out, so a meeting records near-empty.
    static func systemDefaultOutputID() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id
        )
        return status == noErr ? id : 0
    }

    /// Human-readable output route used by ScreenCaptureKit diagnostics.
    /// Daisy follows the macOS output rather than selecting a second route
    /// inside the app, so the settings UI shows this value explicitly and
    /// links to Sound Settings when the user wants to change it.
    static func systemDefaultOutputName() -> String {
        let id = systemDefaultOutputID()
        guard id != 0 else { return String(localized: "No output device") }
        return deviceName(id) ?? String(localized: "Unknown output")
    }

    static func systemDefaultOutputIsBluetooth() -> Bool {
        let id = systemDefaultOutputID()
        return id != 0 && isBluetooth(id)
    }

    /// One-line audio-route snapshot for the log report: the pinned mic
    /// (or "system default"), the live default input, and the live
    /// default OUTPUT — each flagged `[BT]` when Bluetooth. Bluetooth
    /// output/input is the signature of the AirPods capture failure, so
    /// support reports need it to diagnose "recorded empty / garbage".
    static func routeDiagnostics(selectedMicUID: String) -> String {
        func describe(_ id: AudioDeviceID) -> String {
            guard id != 0 else { return "none" }
            let name = deviceName(id) ?? "?"
            return isBluetooth(id) ? "\(name) [BT]" : name
        }
        let pinned: String
        if selectedMicUID.isEmpty {
            pinned = "system default"
        } else if let pinnedID = deviceID(forUID: selectedMicUID) {
            pinned = describe(pinnedID)
        } else {
            pinned = "pinned-but-offline"
        }
        return "mic=\(pinned) defaultIn=\(describe(systemDefaultInputID())) defaultOut=\(describe(systemDefaultOutputID()))"
    }

    /// Read the *actual* hardware stream sample rate from CoreAudio.
    /// Used as a defensive cross-check against `AVAudioNode.outputFormat(forBus:)`
    /// inside the route-change recovery path — after pinning the AUHAL
    /// to a new device, AVAudioEngine has been observed (macOS 26.2,
    /// Apple DevForum 680785 / 683348) to return the *previous* device's
    /// cached format from `outputFormat(forBus:)`. Installing a tap with
    /// that stale format trips Apple's internal assertion
    /// `format.sampleRate == inputHWFormat.sampleRate` and crashes the
    /// app. This helper lets `AudioRecorder` cross-check and fall to
    /// paused on disagreement rather than ship the assertion to users.
    ///
    /// Returns nil if CoreAudio refuses or the device has no input scope.
    static func streamFormatSampleRate(for id: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &format)
        guard status == noErr, format.mSampleRate > 0 else {
            if status != noErr {
                log.error("StreamFormat read failed for device \(id, privacy: .public) (status \(status, privacy: .public))")
            }
            return nil
        }
        return format.mSampleRate
    }

    /// Diagnostic snapshot of a device's sample-rate reporting across
    /// scopes + nominal, logged at format-de-sync points (2026-06-01).
    /// Lets us tell a genuine AVAudioEngine-vs-CoreAudio staleness
    /// de-sync (input stream already == output/nominal, AVE just lags
    /// behind and catches up after the device settles) from a
    /// scope/asymmetry artifact (input stream ≠ output stream — a device
    /// whose mic really runs at a different rate than its speakers).
    /// Best-effort; unreadable values render as "?".
    static func streamRateDiagnostics(for id: AudioDeviceID) -> String {
        func streamRate(_ scope: AudioObjectPropertyScope) -> String {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamFormat,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            var fmt = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let st = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &fmt)
            return (st == noErr && fmt.mSampleRate > 0) ? String(format: "%.0f", fmt.mSampleRate) : "?"
        }
        var nominalAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nominal: Float64 = 0
        var nominalSize = UInt32(MemoryLayout<Float64>.size)
        let nominalStatus = AudioObjectGetPropertyData(id, &nominalAddr, 0, nil, &nominalSize, &nominal)
        let nominalStr = (nominalStatus == noErr && nominal > 0) ? String(format: "%.0f", nominal) : "?"
        let name = deviceName(id) ?? "?"
        return "device \(id) '\(name)': inputStream=\(streamRate(kAudioDevicePropertyScopeInput))Hz, outputStream=\(streamRate(kAudioDevicePropertyScopeOutput))Hz, nominal=\(nominalStr)Hz"
    }

    /// True when the Mac's lid is CLOSED (clamshell / desk-dock mode:
    /// external display + keyboard, laptop shut). Egor's field report
    /// 2026-07-26: in clamshell macOS keeps the built-in microphone in
    /// the device list, lets us open it, and then feeds bit-exact zeros
    /// forever — the hardware is physically muted with the lid. So this
    /// is a first-class capture precondition, not a curiosity.
    ///
    /// `AppleClamshellState` on IOPMrootDomain is the standard read and
    /// needs no entitlement. Any failure returns false — we never block
    /// recording on a diagnostic we couldn't take.
    static func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain")
        )
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        ) else { return false }
        return (property.takeRetainedValue() as? Bool) ?? false
    }

    /// True when `id` is the Mac's own built-in microphone — the device
    /// that goes silent in clamshell mode. Matches on transport first
    /// (authoritative) and falls back to the UID convention.
    static func isBuiltIn(_ id: AudioDeviceID) -> Bool {
        if let transportType = transportType(id) {
            return transportType == kAudioDeviceTransportTypeBuiltIn
        }
        return (deviceUID(id) ?? "").contains("BuiltInMicrophone")
    }

    /// First PHYSICAL external input — something that genuinely records
    /// with the lid shut (USB interface, webcam mic, Thunderbolt dock).
    ///
    /// Transport is a WHITELIST, not a blacklist: virtual drivers
    /// (BlackHole, Loopback, Krisp, ZoomAudioDevice), aggregates and an
    /// asleep Continuity mic all report real input streams and would
    /// otherwise qualify — and silently switching a user onto one of
    /// those is the exact digital-silence failure this whole layer
    /// exists to prevent. Also requires ≥1 real input channel.
    static func firstExternalWiredInputID() -> AudioDeviceID? {
        let physical: Set<UInt32> = [
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypePCI,
            kAudioDeviceTransportTypeFireWire,
            kAudioDeviceTransportTypeDisplayPort,
            kAudioDeviceTransportTypeHDMI,
        ]
        return allDeviceIDs().first { id in
            guard hasInputStreams(id), !isBuiltIn(id), inputChannelCount(id) > 0 else { return false }
            guard let transport = transportType(id) else { return false }
            return physical.contains(transport)
        }
    }

    /// Live input channel count on the input scope (0 for output-only,
    /// misconfigured or virtual devices that expose no real channels).
    static func inputChannelCount(_ id: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        )
        return list.reduce(0) { $0 + $1.mNumberChannels }
    }

    /// Everything we know about a device, in one log line. Emitted at
    /// every capture start (2026-07-26): a field report where the mic
    /// delivered bit-exact digital silence could not be diagnosed
    /// because the log recorded only the numeric AudioDeviceID — an
    /// aggregate, a virtual driver, an asleep Continuity mic and the
    /// built-in mic all looked identical.
    static func describe(_ id: AudioDeviceID) -> String {
        guard id != 0 else { return "device 0 (none)" }
        let name = deviceName(id) ?? "?"
        let uidStr = deviceUID(id) ?? "?"
        let isDefault = systemDefaultInputID() == id ? "yes" : "no"
        // Transport and driver added 2026-08-25: `bluetooth=false
        // builtIn=false` describes a USB interface and somebody else's
        // virtual driver identically, and those two have nothing in
        // common when a recording comes out empty.
        var line = "device \(id) '\(name)' uid=\(uidStr) transport=\(transportLabel(id)) inputStreams=\(hasInputStreams(id)) inputChannels=\(inputChannelCount(id)) bluetooth=\(isBluetooth(id)) builtIn=\(isBuiltIn(id)) lidClosed=\(isLidClosed()) isSystemDefault=\(isDefault)"
        if isOwnDevice(id) {
            line += " ours=yes"
        } else if let driver = virtualDriver(for: id) {
            line += " virtualDriver=\(driver.product) passesMicAudio=\(driver.passesMicAudio)"
        }
        return line
    }

    /// A device qualifies as an "input" if it has at least one
    /// stream on the input scope. Most output-only devices (HDMI
    /// displays, headphones) report zero here.
    static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
        guard status == noErr else { return false }
        return size > 0
    }

    static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
        guard status == noErr else { return false }
        return size > 0
    }

    /// Every connected OUTPUT device, system default flagged. Reuses the
    /// `AudioInputDevice` shape (id/uid/name/isSystemDefault) — the
    /// Settings output picker needs exactly the same fields.
    static func listOutputs() -> [AudioInputDevice] {
        let ids = allDeviceIDs()
        guard !ids.isEmpty else { return [] }
        let defaultID = systemDefaultOutputID()
        return ids.compactMap { id -> AudioInputDevice? in
            guard hasOutputStreams(id) else { return nil }
            guard let uid = deviceUID(id), !uid.isEmpty else { return nil }
            let name = deviceName(id) ?? "Unknown output"
            return AudioInputDevice(
                id: id,
                uid: uid,
                name: name,
                isSystemDefault: id == defaultID
            )
        }
    }

    /// Change the SYSTEM default output device (the same thing the Sound
    /// Settings picker or the menu-bar sound menu does — affects the whole
    /// Mac, not just Daisy). Daisy deliberately follows the macOS output
    /// rather than keeping a private route, so the Settings picker writes
    /// the system default directly. Returns false if CoreAudio refuses.
    @discardableResult
    static func setSystemDefaultOutput(deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id
        )
        if status != noErr {
            log.error("Couldn't set default output to \(deviceID, privacy: .public): OSStatus \(status, privacy: .public)")
        }
        return status == noErr
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        return stringProperty(id, selector: kAudioObjectPropertyName)
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String? {
        return stringProperty(id, selector: kAudioDevicePropertyDeviceUID)
    }

    /// Read a CFString property off an `AudioObjectID`. The
    /// `Unmanaged` dance is required because `AudioObjectGetPropertyData`
    /// returns a +1 reference and Swift won't bridge it implicitly
    /// for us.
    private static func stringProperty(
        _ id: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cfStr)
        guard status == noErr, let unmanaged = cfStr else { return nil }
        return unmanaged.takeRetainedValue() as String
    }
}
