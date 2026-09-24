//
//  DecodeSlot.swift
//  Daisy
//
//  The one Whisper decoder, one caller at a time — WhisperKit isn't safe
//  for simultaneous transcribes. Callers wait in line; a dictation waits
//  in a line of its own that goes first.
//
//  24.09: a dictation held right after a meeting used to cancel that
//  meeting's final pass. It no longer does — which puts the dictation
//  behind a pass that holds the decoder for minutes on a long meeting.
//  So a long pass steps aside between its spans (`yieldToPriority`):
//  the dictation decodes its few seconds, and the pass carries on first
//  in line.
//

import Foundation

@MainActor
final class DecodeSlot {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private(set) var isBusy = false
    private var waiters: [Waiter] = []
    private var priorityWaiters: [Waiter] = []

    var hasPriorityWaiter: Bool { !priorityWaiters.isEmpty }
    var waitingCount: Int { waiters.count + priorityWaiters.count }

    /// Wait for the slot. `false`: the waiting task was cancelled and
    /// left the line without the slot — it must not `release()`.
    ///
    /// A cancelled waiter leaves at once. Stopping a dictation cancels
    /// its live window and then waits for it to end; queued behind a
    /// meeting's final pass, that window used to end only when the
    /// whole pass did.
    func acquire(priority: Bool = false) async -> Bool {
        if !isBusy {
            isBusy = true
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    cont.resume(returning: false)
                    return
                }
                let waiter = Waiter(id: id, continuation: cont)
                if priority { priorityWaiters.append(waiter) } else { waiters.append(waiter) }
            }
        } onCancel: {
            Task { @MainActor in self.leave(id) }
        }
    }

    func release() {
        if !priorityWaiters.isEmpty {
            priorityWaiters.removeFirst().continuation.resume(returning: true)
        } else if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume(returning: true)
        } else {
            isBusy = false
        }
    }

    /// Called by the holder between units of work: hand the slot to a
    /// priority waiter, if there is one, and take it back as the first
    /// in the ordinary line.
    func yieldToPriority() async {
        guard isBusy, !priorityWaiters.isEmpty else { return }
        _ = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            waiters.insert(Waiter(id: UUID(), continuation: cont), at: 0)
            priorityWaiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func leave(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: index).continuation.resume(returning: false)
        } else if let index = priorityWaiters.firstIndex(where: { $0.id == id }) {
            priorityWaiters.remove(at: index).continuation.resume(returning: false)
        }
    }
}
