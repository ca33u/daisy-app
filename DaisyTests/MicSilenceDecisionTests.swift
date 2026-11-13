//
//  MicSilenceDecisionTests.swift
//  DaisyTests
//
//  Support mail 14.11: a muted listener's meeting stopped being recorded.
//  Ten seconds of a silent microphone paused the recorder, the session
//  followed with its real pause, and the other participants were no
//  longer recorded either.
//
//  A silent microphone now pauses only a recording that has nothing else
//  in it. These lock the decision table (mode × whether the capture is
//  part of the recording × its state), the watchdog's episodes (asked
//  once per silence, carried through a rebuilt unit, a stalled unit
//  paused without asking), the one notice per recording — calm for a
//  muted listener, loud for a microphone nobody can hear — its
//  withdrawal, and the strings.
//
//  No microphone is opened here: the watchdog's memory is a value type
//  driven with dates. The shared `WidgetBubbleCenter` is not touched —
//  CaptureLossNoticeTests owns it while it runs.
//

import Foundation
import Testing
@testable import Daisy

@MainActor
@Suite("A silent microphone pauses only a recording with nothing else in it")
struct MicSilenceDecisionTests {
    typealias Mode = RecordingSession.RecordingMode
    typealias State = SystemAudioCapture.CaptureState

    private static let states: [State] = [.idle, .starting, .capturing, .paused, .stopped]

    // MARK: - The decision

    @Test("A meeting with the capture as part of it keeps recording — delivering or not")
    func aMeetingWithTheCaptureKeepsRecording() {
        #expect(MicSilenceDecision.decide(mode: .meeting, captureIsPartOfSession: true, systemAudio: .capturing) == .keepRecording)
        #expect(MicSilenceDecision.decide(mode: .meeting, captureIsPartOfSession: true, systemAudio: .starting) == .keepRecording)
        // Gave up mid-recording and is being retried: a pause here would
        // have the capture come back into a paused recording.
        #expect(MicSilenceDecision.decide(mode: .meeting, captureIsPartOfSession: true, systemAudio: .stopped) == .keepRecording)
    }

    @Test("A meeting without the capture pauses, as before")
    func aMeetingWithoutTheCapturePauses() {
        // The start failed, so there is no capture after all.
        #expect(MicSilenceDecision.decide(mode: .meeting, captureIsPartOfSession: true, systemAudio: .idle) == .pause)
        #expect(MicSilenceDecision.decide(mode: .meeting, captureIsPartOfSession: true, systemAudio: .paused) == .pause)
        // Never armed — the setting off, Screen Recording denied —
        // whatever state an earlier recording left behind. `stop()`
        // leaves `.stopped`, and that must not read as «gave up».
        for state in Self.states {
            #expect(MicSilenceDecision.decide(mode: .meeting, captureIsPartOfSession: false, systemAudio: state) == .pause,
                    "\(state)")
        }
    }

    @Test("The whole table: mode × capture part of the recording × its state")
    func theWholeTable() {
        for mode in [Mode.meeting, .voiceNote, .dictation] {
            for armed in [true, false] {
                for state in Self.states {
                    let keeps = mode == .meeting && armed
                        && (state == .starting || state == .capturing || state == .stopped)
                    #expect(MicSilenceDecision.decide(mode: mode, captureIsPartOfSession: armed, systemAudio: state)
                                == (keeps ? .keepRecording : .pause),
                            "\(mode) armed=\(armed) \(state)")
                }
            }
        }
    }

    @Test("A voice note and a dictation always pause",
          arguments: [Mode.voiceNote, .dictation], [true, false])
    func microphoneOnlyModesPause(mode: Mode, armed: Bool) {
        for state in Self.states {
            #expect(MicSilenceDecision.decide(mode: mode, captureIsPartOfSession: armed, systemAudio: state) == .pause)
        }
    }

    // MARK: - The empty track

    @Test("A microphone silent through nine tenths of a recording is not a captured channel")
    func aSilentTrackIsEmpty() {
        #expect(MicSilenceDecision.micTrackIsEmpty(keptSilenceSec: 3600, recordedSec: 3600))
        // The boundary: exactly nine tenths is empty, a second less is not.
        #expect(MicSilenceDecision.micTrackIsEmpty(keptSilenceSec: 3240, recordedSec: 3600))
        #expect(!MicSilenceDecision.micTrackIsEmpty(keptSilenceSec: 3239, recordedSec: 3600))
        #expect(!MicSilenceDecision.micTrackIsEmpty(keptSilenceSec: 0, recordedSec: 3600))
        // Nothing recorded says nothing about the microphone.
        #expect(!MicSilenceDecision.micTrackIsEmpty(keptSilenceSec: 0, recordedSec: 0))
        #expect(!MicSilenceDecision.micTrackIsEmpty(keptSilenceSec: 5, recordedSec: 0))
    }
}

@MainActor
@Suite("The silence watchdog records through a silence the owner keeps")
struct MicSilenceWatchTests {
    private let window: TimeInterval = 10
    private let stallAfter: TimeInterval = 5
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    /// What the owner answers, and how many times it was asked.
    private final class Owner {
        var answer: MicSilenceDecision
        private(set) var asked = 0
        init(_ answer: MicSilenceDecision) { self.answer = answer }
        func decide() -> MicSilenceDecision {
            asked += 1
            return answer
        }
    }

    /// Whether the device is delivering buffers at the tick.
    private enum Buffers {
        case arriving
        case last(TimeInterval)
        case never
    }

    /// One watchdog tick at `now`. The liveness clock reads `signal`:
    /// the last time the microphone was above the floor, or — with
    /// `heard: false` — the moment a rebuilt unit restarted the clock.
    private func tick(_ watch: inout MicSilenceWatch, now: TimeInterval, signal: TimeInterval,
                      heard: Bool = true, buffers: Buffers = .arriving, owner: Owner) -> MicSilenceWatch.Step {
        let lastBufferAt: Date? = switch buffers {
        case .arriving: at(now)
        case .last(let seconds): at(seconds)
        case .never: nil
        }
        return watch.tick(now: at(now), lastSignalAt: at(signal), signalWasHeard: heard, lastBufferAt: lastBufferAt,
                          window: window, stallAfter: stallAfter, decide: owner.decide)
    }

    @Test("Signal within the window: nothing happens and nobody is asked")
    func aLiveMicrophoneAsksNobody() {
        var watch = MicSilenceWatch()
        let owner = Owner(.keepRecording)
        for now in stride(from: 2.0, through: 60.0, by: 2.0) {
            #expect(tick(&watch, now: now, signal: now - 1, owner: owner) == .none)
        }
        #expect(owner.asked == 0)
        #expect(watch.keptSilenceSec(now: at(60)) == 0)
    }

    @Test("An owner that says pause gets the watchdog as it always was")
    func pauseAtTheWindow() {
        var watch = MicSilenceWatch()
        let owner = Owner(.pause)
        // The boundary: a hair under the window is not yet silence.
        #expect(tick(&watch, now: 9.99, signal: 0, owner: owner) == .none)
        #expect(owner.asked == 0, "Not asked before the watchdog would fire")
        #expect(tick(&watch, now: 10, signal: 0, owner: owner) == .pause)
        #expect(owner.asked == 1)
        #expect(watch.keptSince == nil)
        #expect(watch.keptSilenceSec(now: at(10)) == 0, "A pause is not silence recorded through")
    }

    @Test("A kept silence begins once, and the owner is asked once")
    func aKeptEpisodeBeginsOnce() {
        var watch = MicSilenceWatch()
        let owner = Owner(.keepRecording)
        #expect(tick(&watch, now: 10, signal: 0, owner: owner) == .keptEpisodeBegan)
        for now in stride(from: 12.0, through: 600.0, by: 2.0) {
            #expect(tick(&watch, now: now, signal: 0, owner: owner) == .keptEpisodeContinues)
        }
        #expect(owner.asked == 1)
        // Counted from when the silence began, not from when it was noticed.
        #expect(watch.keptSince == at(0))
        #expect(watch.openSilenceSec(now: at(600)) == 600)
        #expect(watch.keptSilenceSec(now: at(600)) == 600)
    }

    @Test("An episode the owner kept is not ended by a later change of mind")
    func aKeptEpisodeIsNotAskedAgain() {
        // What the other side does is no reason to pause: the answer is
        // taken once per silence.
        var watch = MicSilenceWatch()
        let owner = Owner(.keepRecording)
        #expect(tick(&watch, now: 10, signal: 0, owner: owner) == .keptEpisodeBegan)
        owner.answer = .pause
        for now in stride(from: 12.0, through: 120.0, by: 2.0) {
            #expect(tick(&watch, now: now, signal: 0, owner: owner) == .keptEpisodeContinues)
        }
        #expect(owner.asked == 1)
        // The next silence asks anew.
        #expect(tick(&watch, now: 132, signal: 131, owner: owner) == .keptEpisodeEnded)
        #expect(tick(&watch, now: 142, signal: 131, owner: owner) == .pause)
        #expect(owner.asked == 2)
        #expect(watch.keptSilenceSec(now: at(500)) == 131)
    }

    @Test("Signal returns: the episode ends, and the next silence is a new one")
    func signalEndsTheEpisode() {
        var watch = MicSilenceWatch()
        let owner = Owner(.keepRecording)
        #expect(tick(&watch, now: 10, signal: 0, owner: owner) == .keptEpisodeBegan)
        #expect(tick(&watch, now: 30, signal: 0, owner: owner) == .keptEpisodeContinues)
        // Unmuted at 31 s.
        #expect(tick(&watch, now: 32, signal: 31, owner: owner) == .keptEpisodeEnded)
        #expect(watch.keptSince == nil)
        #expect(watch.keptSilenceSec(now: at(32)) == 31)
        #expect(tick(&watch, now: 34, signal: 33, owner: owner) == .none)
        // Muted again at 40 s: noticed at 50, a second episode.
        #expect(tick(&watch, now: 48, signal: 40, owner: owner) == .none)
        #expect(tick(&watch, now: 50, signal: 40, owner: owner) == .keptEpisodeBegan)
        #expect(tick(&watch, now: 60, signal: 40, owner: owner) == .keptEpisodeContinues)
        #expect(watch.keptSilenceSec(now: at(60)) == 31 + 20)
    }

    @Test("A unit rebuilt mid-episode restarts the clock, not the episode")
    func aRebuildDoesNotEndTheEpisode() {
        var watch = MicSilenceWatch()
        let owner = Owner(.keepRecording)
        #expect(tick(&watch, now: 10, signal: 0, owner: owner) == .keptEpisodeBegan)
        // Route change at 20 s: the liveness clock restarts there, and
        // nothing has been above the floor since.
        #expect(tick(&watch, now: 22, signal: 20, heard: false, owner: owner) == .keptEpisodeContinues)
        #expect(tick(&watch, now: 28, signal: 20, heard: false, owner: owner) == .keptEpisodeContinues)
        // Still silent when the grace window is over: the same episode,
        // on its own clock.
        #expect(tick(&watch, now: 30, signal: 20, heard: false, owner: owner) == .keptEpisodeContinues)
        #expect(owner.asked == 1)
        #expect(watch.keptSince == at(0))
        #expect(watch.openSilenceSec(now: at(30)) == 30)
        #expect(watch.keptSilenceSec(now: at(30)) == 30)
        // Real signal ends it.
        #expect(tick(&watch, now: 42, signal: 41, heard: true, owner: owner) == .keptEpisodeEnded)
        #expect(watch.keptSilenceSec(now: at(42)) == 41)
        // A restarted clock with no episode open is nothing at all.
        var idle = MicSilenceWatch()
        #expect(tick(&idle, now: 22, signal: 20, heard: false, owner: owner) == .none)
    }

    @Test("A unit that stopped delivering buffers pauses without asking")
    func aStalledUnitPauses() {
        // A stalled unit is not a silent microphone; it pauses as it
        // did before, and the owner is not consulted.
        var watch = MicSilenceWatch()
        let owner = Owner(.keepRecording)
        #expect(tick(&watch, now: 10, signal: 0, buffers: .last(1), owner: owner) == .pauseStalled)
        #expect(owner.asked == 0)

        // Never delivered a buffer at all.
        var never = MicSilenceWatch()
        #expect(tick(&never, now: 10, signal: 0, buffers: .never, owner: owner) == .pauseStalled)
        #expect(owner.asked == 0)

        // Stalls in the middle of a kept episode: the last buffer came at 20 s.
        var mid = MicSilenceWatch()
        #expect(tick(&mid, now: 10, signal: 0, owner: owner) == .keptEpisodeBegan)
        #expect(tick(&mid, now: 22, signal: 0, buffers: .last(20), owner: owner) == .keptEpisodeContinues)
        #expect(tick(&mid, now: 26, signal: 0, buffers: .last(20), owner: owner) == .pauseStalled)
        #expect(mid.keptSince == nil)
        #expect(mid.keptSilenceSec(now: at(100)) == 26)
    }

    @Test("The stall boundary: a buffer `stallAfter` old is a stall, one a moment younger is not")
    func theStallBoundary() {
        let owner = Owner(.keepRecording)
        var justAlive = MicSilenceWatch()
        #expect(tick(&justAlive, now: 20, signal: 0, buffers: .last(15.01), owner: owner) == .keptEpisodeBegan)
        #expect(owner.asked == 1)
        var stalled = MicSilenceWatch()
        #expect(tick(&stalled, now: 20, signal: 0, buffers: .last(15), owner: owner) == .pauseStalled)
        #expect(owner.asked == 1)
        // A live microphone is never called stalled: the window comes first.
        var live = MicSilenceWatch()
        #expect(tick(&live, now: 20, signal: 19, buffers: .last(1), owner: owner) == .none)
    }

    @Test("A pause or a stop from outside ends the open episode")
    func closingEndsTheEpisode() {
        var watch = MicSilenceWatch()
        let owner = Owner(.keepRecording)
        #expect(tick(&watch, now: 10, signal: 0, owner: owner) == .keptEpisodeBegan)
        watch.close(at: at(25))
        #expect(watch.keptSince == nil)
        #expect(watch.openSilenceSec(now: at(900)) == 0)
        #expect(watch.keptSilenceSec(now: at(900)) == 25)
        // Closing twice, or with nothing open, changes nothing.
        watch.close(at: at(40))
        #expect(watch.keptSilenceSec(now: at(900)) == 25)
        // After a resume the liveness clock starts over; a silence that
        // goes on is a new episode.
        #expect(tick(&watch, now: 110, signal: 100, heard: false, owner: owner) == .keptEpisodeBegan)
    }
}

@MainActor
@Suite("A silent microphone is mentioned once per recording: calmly for a muted listener, loudly otherwise")
struct MicSilenceNoticeTests {
    typealias Text = MicSilenceNotice.Text

    private func facts(heardEarlier: Bool = true, digital: Bool = false, lid: Bool = false,
                       silentFor: TimeInterval = 10) -> MicSilenceFacts {
        MicSilenceFacts(heardEarlier: heardEarlier, digitalSilence: digital, lidClosedOnBuiltInMic: lid, silentFor: silentFor)
    }

    private func around(audible: Bool = true, capturing: Bool = true, lidAnnounced: Bool = false,
                        pillFree: Bool = true) -> MicSilenceNotice.Surroundings {
        .init(otherSideWasAudible: audible, otherSideIsCapturing: capturing,
              lidAlreadyAnnounced: lidAnnounced, pillIsFree: pillFree)
    }

    // MARK: - Calm or loud, and when

    @Test("The whole choice: heard earlier × digital × lid × other side audible × capturing × how long")
    func theWholeChoice() {
        for heardEarlier in [true, false] {
            for digital in [true, false] {
                for lid in [true, false] {
                    for audible in [true, false] {
                        for capturing in [true, false] {
                            for silentFor in [10.0, 59.9, 60.0, 300.0] {
                                var notice = MicSilenceNotice()
                                let said = notice.text(
                                    for: facts(heardEarlier: heardEarlier, digital: digital, lid: lid, silentFor: silentFor),
                                    surroundings: around(audible: audible, capturing: capturing))
                                let otherSideIsThere = audible && capturing
                                let expected: Text?
                                if lid {
                                    // Its own wording; the promise only with an other side.
                                    expected = otherSideIsThere ? .lidClosedStillRecording : .lidClosed
                                } else if heardEarlier && otherSideIsThere {
                                    // A muted listener.
                                    expected = .micSilent
                                } else if digital {
                                    // Zeros: loud at once.
                                    expected = .micNotHeardDigital
                                } else {
                                    // A quiet input: loud only after a minute.
                                    expected = silentFor >= 60 ? .micNotHeardQuiet : nil
                                }
                                let label = "heardEarlier=\(heardEarlier) digital=\(digital) lid=\(lid) audible=\(audible) capturing=\(capturing) silentFor=\(silentFor)"
                                #expect(said == expected, "\(label)")
                                #expect(notice.given == (expected != nil), "Only a notice that was shown is spent: \(label)")
                                #expect(notice.up == expected, "\(label)")
                            }
                        }
                    }
                }
            }
        }
    }

    @Test("A muted listener gets the calm line at ten seconds")
    func aMutedListener() {
        var notice = MicSilenceNotice()
        #expect(notice.text(for: facts(heardEarlier: true, digital: true, silentFor: 10), surroundings: around()) == .micSilent)
        #expect(!Text.micSilent.isLoud)
    }

    @Test("A microphone that worked and went silent with no other side audible is loud")
    func anInPersonMeetingIsNotLeftWithoutANotice() {
        // Meeting mode, nobody on the other side: the only voice in the
        // recording is being lost.
        var zeros = MicSilenceNotice()
        #expect(zeros.text(for: facts(heardEarlier: true, digital: true, silentFor: 10),
                           surroundings: around(audible: false)) == .micNotHeardDigital)
        var quiet = MicSilenceNotice()
        #expect(quiet.text(for: facts(heardEarlier: true, digital: false, silentFor: 10),
                           surroundings: around(audible: false)) == nil)
        #expect(quiet.text(for: facts(heardEarlier: true, digital: false, silentFor: 60),
                           surroundings: around(audible: false)) == .micNotHeardQuiet)
    }

    @Test("A quiet input is not called unheard ten seconds in — only after a minute")
    func aQuietWorkingMicIsGivenAMinute() {
        #expect(MicSilenceNotice.quietInputPatienceSec == 60)
        var notice = MicSilenceNotice()
        let quiet = { (seconds: TimeInterval) in self.facts(heardEarlier: false, digital: false, silentFor: seconds) }
        for seconds in stride(from: 10.0, to: 60.0, by: 2.0) {
            #expect(notice.text(for: quiet(seconds), surroundings: around()) == nil)
        }
        #expect(!notice.given)
        #expect(notice.text(for: quiet(60), surroundings: around()) == .micNotHeardQuiet)
        // Zeros need no patience.
        var zeros = MicSilenceNotice()
        #expect(zeros.text(for: facts(heardEarlier: false, digital: true, silentFor: 10), surroundings: around()) == .micNotHeardDigital)
    }

    @Test("An other side that was audible but is not being captured now promises nothing")
    func audibleOnceIsNotEnough() {
        var notice = MicSilenceNotice()
        #expect(notice.text(for: facts(digital: true), surroundings: around(audible: true, capturing: false)) == .micNotHeardDigital)
        var lid = MicSilenceNotice()
        #expect(lid.text(for: facts(lid: true), surroundings: around(audible: true, capturing: false)) == .lidClosed)
    }

    @Test("Which notices are loud")
    func loudness() {
        #expect(!Text.micSilent.isLoud)
        #expect(!Text.lidClosedStillRecording.isLoud)
        #expect(!Text.lidClosed.isLoud)
        #expect(Text.micNotHeardDigital.isLoud)
        #expect(Text.micNotHeardQuiet.isLoud)
    }

    // MARK: - Both yield

    @Test("Neither notice takes another pill's place, and neither is spent while it waits",
          arguments: [true, false])
    func bothYield(loud: Bool) {
        var notice = MicSilenceNotice()
        let silence = loud ? facts(heardEarlier: false, digital: true) : facts()
        for _ in 0..<5 {
            #expect(notice.text(for: silence, surroundings: around(pillFree: false)) == nil)
        }
        #expect(!notice.given, "Not spent: it is shown on a later tick, when the pill is free")
        #expect(notice.up == nil)
        #expect(notice.text(for: silence, surroundings: around(pillFree: true)) == (loud ? .micNotHeardDigital : .micSilent))
        #expect(notice.given)
    }

    @Test("The lid's lines yield too")
    func theLidYields() {
        var notice = MicSilenceNotice()
        #expect(notice.text(for: facts(lid: true), surroundings: around(pillFree: false)) == nil)
        #expect(notice.text(for: facts(lid: true), surroundings: around(audible: false, pillFree: false)) == nil)
        #expect(!notice.given)
        #expect(notice.text(for: facts(lid: true), surroundings: around()) == .lidClosedStillRecording)
    }

    // MARK: - Enough samples to say «digital»

    @Test("A rebuilt unit's first few zero buffers are not yet a digital silence")
    func digitalSilenceNeedsEnoughSamples() {
        // Thirty: a second of liveness samples, as the recorder takes them.
        #expect(MicSilenceFacts.digitalSilence(allZero: 0, total: 0, minimumTotal: 30) == nil)
        #expect(MicSilenceFacts.digitalSilence(allZero: 3, total: 3, minimumTotal: 30) == nil)
        #expect(MicSilenceFacts.digitalSilence(allZero: 29, total: 29, minimumTotal: 30) == nil)
        #expect(MicSilenceFacts.digitalSilence(allZero: 30, total: 30, minimumTotal: 30) == true)
        // The recorder's own ratio, nine in ten, once there are enough.
        #expect(MicSilenceFacts.digitalSilence(allZero: 27, total: 30, minimumTotal: 30) == true)
        #expect(MicSilenceFacts.digitalSilence(allZero: 26, total: 30, minimumTotal: 30) == false)
        #expect(MicSilenceFacts.digitalSilence(allZero: 0, total: 300, minimumTotal: 30) == false)
        // No samples is never an answer, whatever the minimum.
        #expect(MicSilenceFacts.digitalSilence(allZero: 0, total: 0, minimumTotal: 0) == nil)
    }

    // MARK: - The toast

    @Test("The notice's toast never takes the place of a toast with a button on it")
    func theToastYieldsToAnActionToast() {
        #expect(!MicSilenceNotice.mayShowToast(currentToastHasAction: true))
        #expect(MicSilenceNotice.mayShowToast(currentToastHasAction: false))
    }

    // MARK: - Withdrawal

    @Test("A notice that is up is withdrawn once; nothing up, nothing to withdraw")
    func withdrawal() {
        var notice = MicSilenceNotice()
        #expect(notice.withdraw() == nil)
        #expect(notice.text(for: facts(heardEarlier: false, digital: true), surroundings: around()) == .micNotHeardDigital)
        #expect(notice.up == .micNotHeardDigital)
        #expect(notice.withdraw() == .micNotHeardDigital)
        #expect(notice.up == nil, "The «loud notice is up» fact is cleared with it")
        #expect(notice.withdraw() == nil, "Pause, then stop: the second finds nothing of ours to take down")
        #expect(notice.given, "Withdrawn is still said: no second notice in this recording")
        #expect(notice.text(for: facts(), surroundings: around()) == nil)
    }

    @Test("A notice that waited for the pill was never up, so there is nothing to withdraw")
    func nothingToWithdrawWhileWaiting() {
        var notice = MicSilenceNotice()
        #expect(notice.text(for: facts(), surroundings: around(pillFree: false)) == nil)
        #expect(notice.withdraw() == nil)
    }

    @Test("The loud notice has a slot of its own: taking it down cannot take down another capture problem")
    func theLoudSlotIsItsOwn() {
        let own = CaptureProblemNotification.micSilenceSlot
        let shared = CaptureProblemNotification.sharedSlot
        #expect(own.bubbleTag != shared.bubbleTag)
        #expect(own.requestID != shared.requestID)
        #expect(shared.bubbleTag == CaptureProblemNotification.bubbleTag)
        #expect(shared.requestID == CaptureProblemNotification.requestID)
    }

    // MARK: - Once

    @Test("Twenty mutes in one meeting, one notice")
    func oncePerRecording() {
        var notice = MicSilenceNotice()
        #expect(notice.text(for: facts(), surroundings: around()) == .micSilent)
        for _ in 0..<19 {
            #expect(notice.text(for: facts(), surroundings: around()) == nil)
        }
        // Not for a different cause later in the same recording either.
        #expect(notice.text(for: facts(lid: true), surroundings: around()) == nil)
        #expect(notice.text(for: facts(heardEarlier: false, digital: true), surroundings: around()) == nil)
    }

    @Test("Loud first: no calm line after it in the same recording")
    func loudThenNothing() {
        var notice = MicSilenceNotice()
        #expect(notice.text(for: facts(heardEarlier: false, digital: true), surroundings: around(audible: false)) == .micNotHeardDigital)
        // The route was fixed, the person spoke, the others were heard,
        // then the person muted.
        #expect(notice.text(for: facts(heardEarlier: true), surroundings: around()) == nil)
    }

    @Test("The next recording speaks again")
    func aNewRecordingStartsFresh() {
        var first = MicSilenceNotice()
        _ = first.text(for: facts(), surroundings: around())
        var second = MicSilenceNotice()
        #expect(second.text(for: facts(), surroundings: around()) == .micSilent)
    }

    // MARK: - The lid

    @Test("A closed lid keeps its own wording, and promises the other side only when there is one")
    func theLidHasItsOwnText() {
        for heardEarlier in [true, false] {
            var withOtherSide = MicSilenceNotice()
            #expect(withOtherSide.text(for: facts(heardEarlier: heardEarlier, digital: true, lid: true),
                                       surroundings: around()) == .lidClosedStillRecording)
            var alone = MicSilenceNotice()
            #expect(alone.text(for: facts(heardEarlier: heardEarlier, digital: true, lid: true),
                               surroundings: around(audible: false)) == .lidClosed)
        }
    }

    @Test("A lid the start already announced is not announced again, and counts as the notice")
    func theLidIsNotSaidTwice() {
        var notice = MicSilenceNotice()
        #expect(notice.text(for: facts(lid: true), surroundings: around(lidAnnounced: true)) == nil)
        #expect(notice.given)
        #expect(notice.up == nil)
        #expect(notice.text(for: facts(), surroundings: around(lidAnnounced: true)) == nil)
    }

    @Test("A start-time lid warning does not swallow a different cause")
    func anotherCauseIsStillSaid() {
        var notice = MicSilenceNotice()
        #expect(notice.text(for: facts(), surroundings: around(lidAnnounced: true)) == .micSilent)
    }

    // MARK: - The words

    private static var catalog: [String: [String: Any]] {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // DaisyTests
                .deletingLastPathComponent()   // repository root
                .appendingPathComponent("Daisy/Localizable.xcstrings")
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            return try #require(json?["strings"] as? [String: [String: Any]])
        }
    }

    @Test("Every notice is in the catalog in Russian, and none says the recording stopped",
          arguments: [
            "Mic is silent, still recording the other side",
            "The lid is closed, the Mac’s mic is off. Still recording the other side",
            "No sound is reaching Daisy from the microphone. The recording continues",
            "macOS is sending Daisy an empty microphone signal. The recording continues. Check Privacy & Security → Microphone, and that the input isn’t muted in Sound settings",
            "Mic is silent — the recording continues. Check your mic (Bluetooth mics often record silence)",
          ])
    func theWords(key: String) throws {
        let entry = try #require(try Self.catalog[key], "\(key) is not in Localizable.xcstrings")
        let localizations = entry["localizations"] as? [String: Any]
        let unit = (localizations?["ru"] as? [String: Any])?["stringUnit"] as? [String: Any]
        let russian = try #require(unit?["value"] as? String)
        #expect(unit?["state"] as? String == "translated")
        for text in [key, russian] {
            #expect(!text.hasSuffix("."), "No full stop at the end: \(text)")
            for stopped in ["paused", "пауз", "nothing is being recorded", "не идёт", "Resume", "Продолжить"] {
                #expect(!text.localizedCaseInsensitiveContains(stopped), "\(text) says \(stopped)")
            }
        }
        // Each says, in Russian, that the recording goes on.
        #expect(russian.localizedCaseInsensitiveContains("записываю")
                || russian.localizedCaseInsensitiveContains("запись продолжается"))
    }

    @Test("The loud body says «не поступает», as the paused case's string does")
    func theLoudBodyMatchesThePausedCase() throws {
        func russian(_ key: String) throws -> String {
            let entry = try #require(try Self.catalog[key])
            let unit = ((entry["localizations"] as? [String: Any])?["ru"] as? [String: Any])?["stringUnit"] as? [String: Any]
            return try #require(unit?["value"] as? String)
        }
        let continues = try russian("No sound is reaching Daisy from the microphone. The recording continues")
        let paused = try russian("No sound is reaching Daisy from the microphone. Nothing is being recorded.")
        #expect(continues == "С микрофона в Daisy не поступает звук. Запись продолжается")
        #expect(paused.hasPrefix("С микрофона в Daisy не поступает звук."))
        // The plain lid line the notice falls back to is the existing one.
        let lid = try russian("The lid is closed, the Mac’s mic is off")
        #expect(lid == "Крышка закрыта, микрофон Mac выключен")
    }
}
