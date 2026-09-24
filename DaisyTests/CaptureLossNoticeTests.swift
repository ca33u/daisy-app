//
//  CaptureLossNoticeTests.swift
//  DaisyTests
//
//  Incident 23.09, the tail of 24.09 — third user, 1.0.8.2. A call began
//  in AirPods: Daisy announced it couldn’t hear the other side (pill,
//  banner, a day-long toast). They switched output to the speakers, the
//  capture came back, a 2.6-second toast said «capture continues» — and
//  the warning stayed until the end of the meeting. Two messages said
//  opposite things; they deleted the recording and started again.
//
//  The notice must come down on the first audible frame after it, and a
//  later loss must be announced again.
//
//  The toast center is one per process and other suites run beside this
//  one, so the toast is checked by ITS id — was ours taken down — never
//  by whatever happens to be on screen.
//

import Foundation
import Testing
@testable import Daisy

@MainActor
private final class RecordingBubbleHost: WidgetBubbleHosting {
    var isWidgetVisible = true
    private(set) var shown: [String?] = []
    private(set) var hidden = 0
    func showBubble(_ content: WidgetBubbleContent) { shown.append(content.tag) }
    func hideBubble() { hidden += 1 }
    func pauseBubbleCountdown() {}
    func restartBubbleCountdown() {}
    func updateLiveCaption(_ text: String) {}
    func hideLiveCaption() {}
}

@MainActor
@Suite("An announced loss comes down when the other side is heard", .serialized)
struct CaptureLossNoticeTests {

    /// `post` and `cancel` hop through a MainActor task.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    @Test func bluetoothSilenceThenSpeakersThenSound() async {
        let host = RecordingBubbleHost()
        WidgetBubbleCenter.shared.host = host
        defer { WidgetBubbleCenter.shared.host = nil; ToastCenter.shared.dismiss() }
        let capture = SystemAudioCapture()

        // Call started in AirPods: 35 s of nothing, the notice goes out.
        capture.announceBluetoothSilence()
        await settle()
        #expect(capture.lossNoticeShownForTesting)
        #expect(host.shown == [CaptureProblemNotification.bubbleTag])
        let warning = capture.lossToastIDForTesting
        #expect(warning != nil, "The day-long warning must be tracked to be taken down")

        // Output switched to the speakers; the first audible frame.
        capture.noteAudibleAudio()
        await settle()
        #expect(!capture.lossNoticeShownForTesting)
        #expect(host.hidden == 1, "The pill must come down")
        #expect(capture.lossToastIDForTesting == nil)
        #expect(ToastCenter.shared.current?.id != warning, "The day-long warning must be gone")

        // More sound says nothing more.
        capture.noteAudibleAudio()
        await settle()
        #expect(host.hidden == 1)

        // Back to AirPods later in the same meeting: announced again.
        capture.announceBluetoothSilence()
        await settle()
        #expect(capture.lossNoticeShownForTesting)
        #expect(host.shown.count == 2)
    }

    /// Audible sound with no loss announced is just sound.
    @Test func soundWithoutALossChangesNothingOnScreen() async {
        let host = RecordingBubbleHost()
        WidgetBubbleCenter.shared.host = host
        defer { WidgetBubbleCenter.shared.host = nil; ToastCenter.shared.dismiss() }
        ToastCenter.shared.dismiss()
        let capture = SystemAudioCapture()
        capture.noteAudibleAudio()
        await settle()
        #expect(host.hidden == 0)
        #expect(ToastCenter.shared.current == nil)
        #expect(capture.receivedAudibleAudio)
    }
}
