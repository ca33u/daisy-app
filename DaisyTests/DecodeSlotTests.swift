//
//  DecodeSlotTests.swift
//  DaisyTests
//
//  A dictation behind a meeting's final pass decodes between the pass's
//  spans, not after the whole pass.
//

import Foundation
import Testing
@testable import Daisy

@MainActor
@Suite("Decoder line: dictation goes first")
struct DecodeSlotTests {
    @Test func aDictationGetsInBetweenTheSpansOfALongPass() async {
        let slot = DecodeSlot()
        var log: [String] = []

        _ = await slot.acquire()                  // the meeting's final pass
        let other = Task { @MainActor in           // a live window, ordinary line
            if await slot.acquire() { log.append("live"); slot.release() }
        }
        let dictation = Task { @MainActor in
            if await slot.acquire(priority: true) { log.append("dictation"); slot.release() }
        }
        while !slot.hasPriorityWaiter { await Task.yield() }

        log.append("span 1")
        await slot.yieldToPriority()
        log.append("span 2")
        slot.release()
        await dictation.value
        await other.value

        #expect(log == ["span 1", "dictation", "span 2", "live"])
        #expect(!slot.isBusy)
    }

    @Test func yieldingWithNobodyWaitingIsFree() async {
        let slot = DecodeSlot()
        _ = await slot.acquire()
        await slot.yieldToPriority()
        #expect(slot.isBusy)
        slot.release()
        #expect(!slot.isBusy)
    }

    @Test func aCancelledWaiterLeavesTheLineAtOnce() async {
        // Stopping a dictation cancels its live window and waits for it;
        // behind a meeting's pass that wait used to last the whole pass.
        let slot = DecodeSlot()
        _ = await slot.acquire()                  // the meeting's pass, still going
        let window = Task { @MainActor in await slot.acquire() }
        while slot.waitingCount == 0 { await Task.yield() }
        window.cancel()
        #expect(await window.value == false)
        #expect(slot.waitingCount == 0)
        #expect(slot.isBusy)                      // the pass still holds it
        slot.release()
        #expect(!slot.isBusy)
    }
}
