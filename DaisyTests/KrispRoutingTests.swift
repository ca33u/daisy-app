import Foundation
import Testing
@testable import Daisy

@MainActor
@Suite("Krisp route classification, not a live driver compatibility test")
struct KrispRoutingTests {
    @Test func krispMicIsAPassThroughNotACaptureSink() throws {
        for (name, uid) in [("Krisp Microphone", "virtual-mic"), ("Virtual Microphone", "com.krisp.audio.input"), ("KRISP microphone", "") ] {
            let driver = try #require(AudioInputDevices.virtualDriver(name: name, uid: uid))
            #expect(driver.product == "Krisp")
            #expect(driver.passesMicAudio)
        }
        let sink = try #require(AudioInputDevices.virtualDriver(name: "BlackHole 2ch", uid: ""))
        #expect(!sink.passesMicAudio)
        #expect(AudioInputDevices.virtualDriver(name: "MacBook Air Microphone", uid: "BuiltInMicrophoneDevice") == nil)
    }

    @Test func virtualSpeakerDoesNotProveTheDownstreamDeviceIsWired() {
        let route = SystemAudioCapture.OutputRoute(deviceID: 42, name: "Krisp Speaker", sampleRate: 16_000,
                                                   outputChannels: 1, bluetooth: false, virtualDriver: "Krisp")
        #expect(!route.bluetooth)
        #expect(route.description.contains("virtual=Krisp downstream=unknown"))
        var faster = route
        faster.sampleRate = 48_000
        #expect(faster != route, "A profile change behind the same endpoint still triggers route recovery")
    }

    @Test func separateOwnAndRemoteWordsSurviveDedup() {
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        let own = TranscriptSegment(id: UUID(), startedAt: origin, text: "I will send the proposal tomorrow.", isFinal: true,
                                    source: .microphone, endSec: 4, startSec: 0)
        let remote = TranscriptSegment(id: UUID(), startedAt: origin, text: "Please include the implementation schedule.", isFinal: true,
                                       source: .systemAudio, endSec: 4, startSec: 0)
        #expect(AcousticEchoDedup.filteredQuietly([own, remote]) == [own, remote])
    }
}
