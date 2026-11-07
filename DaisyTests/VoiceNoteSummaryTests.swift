//
//  VoiceNoteSummaryTests.swift
//  DaisyTests
//
//  Mac voice notes (Egor 07.11.2026): the `daisy_voice_note` key Flow reads,
//  the gate that decides whether a voice note is summarized without being
//  asked, and the one-voice prompt its summary is written with (DaisyCore's
//  words — `OneVoiceSummaryRules`; `Daisy.` names the app's own types where
//  DaisyCore has one of the same name). Nothing here writes
//  `UserDefaults.standard` — the switch and the declines are tried on
//  `ScratchDefaults`; the recovery render only reads the default meeting
//  project from it. Files go to temporary folders.
//

import CryptoKit
import DaisyCore
import Foundation
import Testing
@testable import Daisy

@MainActor
@Suite("Voice notes: the key and the recognition")
struct VoiceNoteMarkerTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-note-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func session(_ markdown: String, id: String = "2026-11-07T10-00-00Z") throws -> StoredSession {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try markdown.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        return try #require(SessionStore.parseSession(at: dir))
    }

    private static func voiceNote(kind: String = "note", marker: String? = "true", extra: String = "",
                                  duration: Int = 42, body: String = "## Transcript\n\n**[0:01 · Me]** Sell templates separately.\n") -> String {
        var lines = ["---", "title: \"Voice note 2026-11-07 10:00\"", "started: 2026-11-07T10:00:00Z",
                     "duration_sec: \(duration)", "daisy_folder: inbox", "daisy_kind: \(kind)"]
        if let marker { lines.append("daisy_voice_note: \(marker)") }
        if !extra.isEmpty { lines.append(extra) }
        lines += ["daisy_speaker_map: {}", "daisy_system_audio_status: off", "---", "", "# Voice note", "", body]
        return lines.joined(separator: "\n")
    }

    @Test func theKeyFollowsTheKindOfAVoiceNoteOnly() {
        #expect(MarkdownExporter.kindLines(kind: .note, isVoiceNote: true) == ["daisy_kind: note", "daisy_voice_note: true"])
        #expect(MarkdownExporter.kindLines(kind: .recording, isVoiceNote: false) == ["daisy_kind: recording"])
        #expect(MarkdownExporter.kindLines(kind: .note, isVoiceNote: false) == ["daisy_kind: note"])
        // Never beside another kind, whatever the caller says.
        #expect(MarkdownExporter.kindLines(kind: .recording, isVoiceNote: true) == ["daisy_kind: recording"])
    }

    @Test func aVoiceNoteIsOneRecordedAsOneAndStillANote() {
        #expect(RecordingSession.isVoiceNote(mode: .voiceNote, kind: .note))
        // Moved to the Library while it finished: a recording now.
        #expect(!RecordingSession.isVoiceNote(mode: .voiceNote, kind: .recording))
        #expect(!RecordingSession.isVoiceNote(mode: .meeting, kind: .recording))
        #expect(!RecordingSession.isVoiceNote(mode: .meeting, kind: .note))
        #expect(!RecordingSession.isVoiceNote(mode: .dictation, kind: .recording))
    }

    @Test func aMarkedVoiceNoteReadsAsOne() throws {
        let note = try session(Self.voiceNote())
        #expect(note.kind == .note)
        #expect(note.voiceNote == .marked)
        #expect(note.isVoiceNote)
    }

    @Test func theKindWinsOverTheKey() throws {
        #expect(try session(Self.voiceNote(kind: "recording")).voiceNote == .none)
        #expect(try session(Self.voiceNote(marker: "false")).voiceNote == .none)
    }

    @Test func anOlderVoiceNoteIsKnownByItsShape() throws {
        #expect(try session(Self.voiceNote(marker: nil)).voiceNote == .byShape)
        // From before `daisy_kind`: a session in Notes is a note.
        let legacy = Self.voiceNote(marker: nil).replacingOccurrences(of: "daisy_kind: note\n", with: "")
            .replacingOccurrences(of: "daisy_folder: inbox", with: "daisy_folder: notes")
        #expect(try session(legacy).voiceNote == .byShape)
        // No length, no transcript heading, another note's marker, a meeting
        // it came from: not a voice note.
        #expect(try session(Self.voiceNote(marker: nil, duration: 0)).voiceNote == .none)
        #expect(try session(Self.voiceNote(marker: nil, body: "Call Boris tomorrow.")).voiceNote == .none)
        #expect(try session(Self.voiceNote(marker: nil, extra: "daisy_text_note: true")).voiceNote == .none)
        #expect(try session(Self.voiceNote(marker: nil, extra: "daisy_source_meeting: 2026-11-07T09-00-00Z")).voiceNote == .none)
        #expect(try session(Self.voiceNote(kind: "recording", marker: nil)).voiceNote == .none)
        // A meeting filed as a note captured, or tried to capture, the other side.
        let filedMeeting = Self.voiceNote(marker: nil)
            .replacingOccurrences(of: "daisy_system_audio_status: off", with: "daisy_system_audio_status: captured (10 B)")
        #expect(try session(filedMeeting, id: "filed-meeting").voiceNote == .none)
    }

    @Test func aDaisyKeyNoteAndASideNoteAreNotVoiceNotes() throws {
        let held = DaisyKeyNote.markdown(body: "Call Boris about the contract tomorrow, and check the price.",
                                         created: Date(timeIntervalSince1970: 1_794_000_000), durationSec: 6,
                                         folderSlug: "inbox")
        #expect(!held.contains(VoiceNoteProfile.frontmatterKey))
        #expect(try session(held, id: "held").voiceNote == .none)

        let side = RecordingSession.renderSideNoteMarkdown(
            body: "## Transcript\n\n**[0:01 · Me]** Remember the pricing slide.",
            start: Date(timeIntervalSince1970: 1_794_000_000), end: Date(timeIntervalSince1970: 1_794_000_030),
            meetingID: "2026-11-07T09-00-00Z", hasAudio: true)
        #expect(!side.contains(VoiceNoteProfile.frontmatterKey))
        #expect(try session(side, id: "side").voiceNote == .none)
    }

    @Test func editsKeepTheKey() throws {
        var text = Self.voiceNote()
        text = SessionStore.upsertFrontmatter(in: text, key: "title", value: "\"Templates sold separately\"")
        text = SessionStore.upsertFrontmatter(in: text, key: "daisy_folder", value: "work")
        text = SessionStore.upsertFrontmatter(in: text, key: "daisy_tag", value: "\"Ideas\"")
        text = SessionStore.upsertFrontmatter(in: text, key: "daisy_speaker_map", value: "{\"Me\": \"Egor\"}")
        #expect(text.contains("daisy_voice_note: true"))
        let edited = try session(text)
        #expect(edited.voiceNote == .marked)
        #expect(edited.folderSlug == "work")
        // What the final re-render adopts from disk keeps it a note.
        let url = edited.directoryURL.appendingPathComponent("transcript.md")
        #expect(RecordingSession.persistedUserFields(at: url).kind == "note")
    }

    private func stored(kind: Daisy.SessionKind) -> StoredSession {
        StoredSession(
            id: "2026-11-07T10-00-00Z", directoryURL: root, title: "Voice note 2026-11-07 10:00",
            startedAt: Date(timeIntervalSince1970: 1_794_045_600), durationSec: 42, locale: "auto",
            transcriptPreview: "", transcriptText: "", hasMicAudio: true, hasSystemAudio: false,
            screenshotURLs: [], screenshotOffsets: [:], screenshotHighlights: [], summary: nil,
            transcriptURL: nil, folderSlug: "inbox", kind: kind, tag: "", meetingAttendees: [],
            meetingAttendeeEmails: [], linkedEventTitle: nil, meetingPreparation: nil, planAnalysis: nil,
            planAnalysisError: nil, speakerMap: [:], speakerCentroidIDs: [], systemAudioStatus: "off", kindKnown: true)
    }

    private func retranscribed(_ session: StoredSession, original: String, firstTranscript: Bool = false) -> String {
        let segment = Daisy.TranscriptSegment(id: UUID(), startedAt: session.startedAt, text: "Sell templates separately.",
                                        isFinal: true, source: .microphone, speakerId: nil, endSec: 3, startSec: 1)
        return SessionAudioProcessing.renderDerivedTranscript(
            originalMarkdown: original, session: session,
            options: SessionRetranscriptionOptions(modelID: "large-v3-v20240930_626MB", language: "en", diarize: false),
            segments: [segment], audioFiles: ["microphone.caf"], isFirstTranscript: firstTranscript)
    }

    @Test func reTranscribingAVoiceNoteKeepsItAVoiceNote() throws {
        // The copy «Re-transcribe» makes, and the in-place finish of an
        // interrupted final pass: both keep the note's kind and its key.
        for first in [false, true] {
            let markdown = retranscribed(stored(kind: .note), original: Self.voiceNote(), firstTranscript: first)
            #expect(markdown.contains("daisy_kind: note"))
            #expect(!markdown.contains("daisy_kind: recording"))
            #expect(markdown.contains("daisy_voice_note: true"))
            #expect(try session(markdown, id: "rt-\(first)").voiceNote == .marked)
        }
        // A meeting stays a recording, as before.
        let meeting = retranscribed(stored(kind: .recording), original: "---\ndaisy_kind: recording\n---\n")
        #expect(meeting.contains("daisy_kind: recording"))
        #expect(!meeting.contains("daisy_voice_note"))
    }

    @Test func reTranscribingNeverRewritesAKindItDoesNotKnow() {
        // The phone's take reads as a recording here; its kind stays (§3.1).
        let take = retranscribed(stored(kind: .recording), original: "---\ndaisy_kind: rehearsal\ndaisy_origin: iphone\n---\n")
        #expect(take.contains("daisy_kind: rehearsal"))
        #expect(!take.contains("daisy_kind: recording"))
        // No kind on disk — a first import, a note from before the key:
        // the kind it reads as.
        let imported = retranscribed(stored(kind: .recording), original: "", firstTranscript: true)
        #expect(imported.contains("daisy_kind: recording"))
        let legacyNote = retranscribed(stored(kind: .note), original: "---\ndaisy_folder: notes\n---\n")
        #expect(legacyNote.contains("daisy_kind: note"))
    }

    @Test func aRoomRecordingFiledAsANoteIsNotAVoiceNote() throws {
        for origin in ["iphone", "watch", "import", "something-new"] {
            #expect(try session(Self.voiceNote(marker: nil, extra: "daisy_origin: \(origin)"), id: "o-\(origin)").voiceNote == .none)
            #expect(try session(Self.voiceNote(extra: "daisy_origin: \(origin)"), id: "om-\(origin)").voiceNote == .none)
        }
        #expect(try session(Self.voiceNote(marker: nil, extra: "daisy_origin: mac"), id: "o-mac").voiceNote == .byShape)
    }

    @Test func theMarkerSaysAVoiceNoteAndAMeetingsIsUnchanged() {
        let start = Date(timeIntervalSince1970: 1_794_045_600)
        let iso = ISO8601DateFormatter().string(from: start)
        #expect(RecordingMarker.contents(startedAt: start, isVoiceNote: false) == iso)
        let note = RecordingMarker.contents(startedAt: start, isVoiceNote: true)
        #expect(RecordingMarker.parse(note) == .init(startedAt: start, isVoiceNote: true))
        // Written before 07.11, and a meeting's now: a meeting.
        #expect(RecordingMarker.parse(iso) == .init(startedAt: start, isVoiceNote: false))
        #expect(RecordingMarker.parse(iso + "\n") == .init(startedAt: start, isVoiceNote: false))
        #expect(RecordingMarker.parse("garbage") == .init(startedAt: nil, isVoiceNote: false))
    }

    @Test func aRecoveredVoiceNoteComesBackAsOne() throws {
        let start = Date(timeIntervalSince1970: 1_794_045_600)
        let note = Daisy.InterruptedRecordingRecovery.renderMarkdown(startDate: start, durationSec: 30, isVoiceNote: true,
                                                               noteFolderSlug: "ideas",
                                                               mic: "Sell templates separately, not in the subscription.",
                                                               system: nil)
        #expect(note.contains("daisy_recovered: true"))
        #expect(!note.contains("daisy_kind: recording"))
        let recovered = try session(note, id: "recovered-note")
        #expect(recovered.kind == .note)
        #expect(recovered.voiceNote == .marked)
        #expect(recovered.folderSlug == "ideas")
        // A notes project that no longer exists: Inbox, the key absent.
        let inInbox = Daisy.InterruptedRecordingRecovery.renderMarkdown(startDate: start, durationSec: 30, isVoiceNote: true,
                                                                  noteFolderSlug: nil, mic: "Words.", system: nil)
        #expect(!inInbox.contains("daisy_folder:"))
        let meeting = Daisy.InterruptedRecordingRecovery.renderMarkdown(startDate: start, durationSec: 30, mic: "Hello there.", system: "Hi.")
        #expect(meeting.contains("daisy_kind: recording"))
        #expect(!meeting.contains(VoiceNoteProfile.frontmatterKey))
        #expect(try session(meeting, id: "recovered-meeting").voiceNote == .none)
    }
}

@MainActor
@Suite("Voice notes: the summary")
struct VoiceNoteSummaryTests {
    @Test func theGate() {
        let since = Date(timeIntervalSince1970: 1_794_000_000)
        let before = since.addingTimeInterval(-60), after = since.addingTimeInterval(60)
        // On this Mac: always, whenever it was recorded.
        let local = VoiceNoteProfile.Gate(providerIsEffectivelyLocal: true, summarizeInCloud: false, cloudAllowedSince: nil)
        #expect(local.allows(recordedAt: before))
        #expect(local.allows(recordedAt: nil))
        // A cloud provider: only a note recorded since the switch went on.
        let cloud = VoiceNoteProfile.Gate(providerIsEffectivelyLocal: false, summarizeInCloud: true, cloudAllowedSince: since)
        #expect(cloud.allows(recordedAt: after))
        #expect(cloud.allows(recordedAt: since))
        #expect(!cloud.allows(recordedAt: before))
        #expect(!cloud.allows(recordedAt: nil))
        // Off, or on without a moment: nothing.
        #expect(!VoiceNoteProfile.Gate(providerIsEffectivelyLocal: false, summarizeInCloud: false, cloudAllowedSince: since)
            .allows(recordedAt: after))
        #expect(!VoiceNoteProfile.Gate(providerIsEffectivelyLocal: false, summarizeInCloud: true, cloudAllowedSince: nil)
            .allows(recordedAt: after))
        // A note from before the key never goes on its own.
        #expect(!VoiceNoteProfile.summarizesOnItsOwn(.byShape, recordedAt: after, gate: local))
        #expect(VoiceNoteProfile.summarizesOnItsOwn(.marked, recordedAt: after, gate: cloud))
    }

    @Test func theCloudSwitchIsOffUntilTurnedOnAndRemembersWhenAndForWhom() {
        let scratch = ScratchDefaults("voice-note-summaries")
        let defaults = scratch.make()
        let anthropic = Daisy.SummaryProviderKind.anthropic.rawValue, openai = Daisy.SummaryProviderKind.openai.rawValue
        #expect(AppSettings.k_summarizeVoiceNotesInCloud == "daisy.summarizeVoiceNotesInCloud")
        #expect(AppSettings.voiceNoteCloudGrant(in: defaults) == nil)
        #expect(AppSettings.summarizeVoiceNotesInCloudSince(for: anthropic, in: defaults) == nil)

        let on = Date(timeIntervalSince1970: 1_794_000_000.75)
        AppSettings.recordSummarizeVoiceNotesInCloud(true, provider: anthropic, in: defaults, now: on)
        // Down to the second, the precision of a note's `started:`.
        #expect(AppSettings.voiceNoteCloudGrant(in: defaults)
                == VoiceNoteCloudGrant(provider: anthropic, since: Date(timeIntervalSince1970: 1_794_000_000)))
        #expect(AppSettings.summarizeVoiceNotesInCloudSince(for: anthropic, in: defaults) == Date(timeIntervalSince1970: 1_794_000_000))
        // A yes to one provider is no yes to another.
        #expect(AppSettings.summarizeVoiceNotesInCloudSince(for: openai, in: defaults) == nil)

        // Turned on for another: from then, and only for it.
        AppSettings.recordSummarizeVoiceNotesInCloud(true, provider: openai, in: defaults, now: on.addingTimeInterval(50))
        #expect(AppSettings.summarizeVoiceNotesInCloudSince(for: openai, in: defaults) == Date(timeIntervalSince1970: 1_794_000_050))
        #expect(AppSettings.summarizeVoiceNotesInCloudSince(for: anthropic, in: defaults) == nil)

        AppSettings.recordSummarizeVoiceNotesInCloud(false, provider: openai, in: defaults, now: on.addingTimeInterval(60))
        #expect(AppSettings.voiceNoteCloudGrant(in: defaults) == nil)
        #expect(defaults.object(forKey: AppSettings.k_summarizeVoiceNotesInCloudSince) == nil)
        #expect(defaults.object(forKey: AppSettings.k_summarizeVoiceNotesInCloudProvider) == nil)

        // On again: from then, not from the first time.
        AppSettings.recordSummarizeVoiceNotesInCloud(true, provider: anthropic, in: defaults, now: on.addingTimeInterval(100))
        #expect(AppSettings.summarizeVoiceNotesInCloudSince(for: anthropic, in: defaults) == Date(timeIntervalSince1970: 1_794_000_100))

        // On by hand, or without a provider: lets no note through.
        let bare = scratch.make()
        bare.set(true, forKey: AppSettings.k_summarizeVoiceNotesInCloud)
        #expect(AppSettings.voiceNoteCloudGrant(in: bare) == nil)
        bare.set(Date(), forKey: AppSettings.k_summarizeVoiceNotesInCloudSince)
        #expect(AppSettings.voiceNoteCloudGrant(in: bare) == nil)
        #expect(AppSettings.summarizeVoiceNotesInCloudSince(for: anthropic, in: bare) == nil)
    }

    @Test func aProviderLimitIsNotAFault() {
        #expect(Summarizer.isProviderLimit(AppleIntelligenceContextExceeded(message: "too long")))
        #expect(Summarizer.isProviderLimit(Daisy.SummaryProviderError.unsupportedLanguage(provider: "Apple Intelligence", languageCode: "ru")))
        #expect(!Summarizer.isProviderLimit(Daisy.SummaryProviderError.missingAPIKey(provider: "Anthropic")))
        #expect(!Summarizer.isProviderLimit(CancellationError()))
        // The person still reads what they always read.
        #expect(AppleIntelligenceContextExceeded(message: "too long").localizedDescription == "too long")
    }

    @Test func aVoiceNotesPromptIsDaisyCoresOneVoice() {
        for hint in [nil, "ru", "en"] as [String?] {
            let prompt = Daisy.SummaryPrompt.systemInstructions(localeHint: hint, task: .summary(oneVoice: true))
            #expect(prompt.contains(OneVoiceSummaryRules.directive))
            #expect(prompt.contains(OneVoiceSummaryRules.followUpGate))
            #expect(prompt.contains("  - " + OneVoiceSummaryRules.sectionCount))
            #expect(prompt.contains("  - " + OneVoiceSummaryRules.followUpConstraint))
            #expect(!prompt.contains("3-5 sections total"))
            #expect(!prompt.contains("when in doubt, draft one"))
        }
        // Nobody to write to, even when a follow-up is asked for.
        let forced = Daisy.SummaryPrompt.systemInstructions(localeHint: nil, task: .meeting(forceFollowUp: true, oneVoice: true))
        #expect(forced.contains(OneVoiceSummaryRules.followUpGate))
        #expect(!forced.contains("MUST write a non-empty clientFollowUp"))
        #expect(SummaryTask.summary(oneVoice: true).isOneVoice)
        #expect(SummaryTask.summary(oneVoice: true).asksForTitle)
        #expect(!SummaryTask.standard.isOneVoice)
        #expect(!SummaryTask.meeting(forceFollowUp: true).isOneVoice)
    }

    /// SHA-256 of the meeting prompt as it was before voice notes had a
    /// summary (HEAD 7ad5a66's `meetingSystemInstructions`). Change these
    /// only when the meeting prompt is meant to change.
    @Test func theMeetingPromptIsByteForByteAsBefore() {
        func sha(_ text: String) -> String {
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        #expect(sha(Daisy.SummaryPrompt.systemInstructions(localeHint: nil, task: .standard))
                == "f14625d46b66fc71a9acb39e52a0abbe5d771945bba640e14ff1a7e49d3c3f7c")
        #expect(sha(Daisy.SummaryPrompt.systemInstructions(localeHint: "ru", task: .summary(oneVoice: false)))
                == "c2a1e59d3dbf51aab1f51889078f39ed1ce5e57567fb04ace8cd8dd8df1c6841")
        #expect(sha(Daisy.SummaryPrompt.systemInstructions(localeHint: "en", task: .meeting(forceFollowUp: true)))
                == "b1301a8f0a401d2996feef745748928247894808de8efc6abc47ab409f2a83cd")
        #expect(!Daisy.SummaryPrompt.systemInstructions(localeHint: nil, task: .standard).contains(OneVoiceSummaryRules.directive))
    }

    @Test func theEveningPassNamesVoiceNotes() {
        #expect(EndOfDaySummaries.startText(meetings: 1, voiceNotes: 0) == String(localized: "Summarizing 1 meeting…"))
        #expect(EndOfDaySummaries.startText(meetings: 3, voiceNotes: 0) == String(localized: "Summarizing \(3) meetings…"))
        // Voice notes alone start quietly: each may yet be left alone.
        #expect(EndOfDaySummaries.startText(meetings: 0, voiceNotes: 2) == nil)
        #expect(EndOfDaySummaries.startText(meetings: 1, voiceNotes: 2) == String(localized: "Summarizing meetings and voice notes: \(3)…"))
        #expect(EndOfDaySummaries.doneText(succeeded: 1, withVoiceNotes: false) == String(localized: "1 meeting summarized."))
        #expect(EndOfDaySummaries.doneText(succeeded: 3, withVoiceNotes: true) == String(localized: "Summaries done: \(3)."))
        #expect(EndOfDaySummaries.failureText(meetingsFailed: true).hasPrefix("Couldn't summarize tonight's meetings"))
        #expect(EndOfDaySummaries.failureText(meetingsFailed: false).hasPrefix("Couldn't summarize tonight's voice notes"))
    }
}

/// Which voice notes reach a provider without being asked — every path
/// that picks one, and the second look right before the send. Each case
/// here was let through before the gate knew when a note was recorded.
@MainActor
@Suite("Voice notes: what goes out on its own")
struct VoiceNoteSelectionTests {
    private let since = Date(timeIntervalSince1970: 1_794_000_000)
    private var cloudOn: VoiceNoteProfile.Gate {
        .init(providerIsEffectivelyLocal: false, summarizeInCloud: true, cloudAllowedSince: since)
    }
    private let cloudOff = VoiceNoteProfile.Gate(providerIsEffectivelyLocal: false, summarizeInCloud: false, cloudAllowedSince: nil)
    private let local = VoiceNoteProfile.Gate(providerIsEffectivelyLocal: true, summarizeInCloud: false, cloudAllowedSince: nil)

    private func stored(_ id: String, kind: Daisy.SessionKind, voiceNote: VoiceNoteProfile.Recognition = .none,
                        startedAt: Date, isDemo: Bool = false, summary: Daisy.MeetingSummary? = nil,
                        kindKnown: Bool = true) -> StoredSession {
        StoredSession(
            id: id, directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(id), title: id,
            startedAt: startedAt, durationSec: 42, locale: "en", transcriptPreview: "",
            transcriptText: "## Transcript\n\n**[0:01 · Me]** Sell templates separately, not in the subscription.",
            hasMicAudio: true, hasSystemAudio: false, screenshotURLs: [], screenshotOffsets: [:],
            screenshotHighlights: [], summary: summary, transcriptURL: nil, folderSlug: "inbox", kind: kind, tag: "",
            meetingAttendees: [], meetingAttendeeEmails: [], linkedEventTitle: nil, meetingPreparation: nil,
            planAnalysis: nil, planAnalysisError: nil, speakerMap: [:], speakerCentroidIDs: [],
            systemAudioStatus: "off", isDemo: isDemo, voiceNote: voiceNote, kindKnown: kindKnown)
    }

    private var library: [StoredSession] {
        [stored("meeting", kind: .recording, startedAt: since.addingTimeInterval(-3_600)),
         stored("noteAfter", kind: .note, voiceNote: .marked, startedAt: since.addingTimeInterval(600)),
         stored("noteBefore", kind: .note, voiceNote: .marked, startedAt: since.addingTimeInterval(-600)),
         stored("oldNote", kind: .note, voiceNote: .byShape, startedAt: since.addingTimeInterval(1_200)),
         stored("heldNote", kind: .note, startedAt: since.addingTimeInterval(1_800)),
         stored("demo", kind: .recording, startedAt: since.addingTimeInterval(2_400), isDemo: true)]
    }

    private func pending(_ gate: VoiceNoteProfile.Gate) -> [String] {
        EndOfDaySummaries.pending(in: library, now: since.addingTimeInterval(86_400), gate: gate,
                                  isProcessing: { _ in false }, declined: { _ in false }).map(\.id)
    }

    @Test func theEveningPassTakesOnlyNotesRecordedWhileTheSwitchWasOn() {
        // Turned on today: the note from before it stays on this Mac.
        #expect(pending(cloudOn) == ["noteAfter", "meeting"])
        #expect(pending(cloudOff) == ["meeting"])
        // On this Mac every voice note with its key — never an older one.
        #expect(pending(local) == ["noteAfter", "noteBefore", "meeting"])
    }

    @Test func theEveningPassLooksAgainBeforeEachSend() {
        let note = stored("n", kind: .note, voiceNote: .marked, startedAt: since.addingTimeInterval(600))
        #expect(EndOfDaySummaries.mayStillSummarize(note, gate: cloudOn))
        // Switched off while the meetings before it were being summarized.
        #expect(!EndOfDaySummaries.mayStillSummarize(note, gate: cloudOff))
        #expect(EndOfDaySummaries.mayStillSummarize(stored("m", kind: .recording, startedAt: since), gate: cloudOff))
    }

    @Test func aQueuedFinishSummarizesAsFinalizeWould() {
        let after = stored("a", kind: .note, voiceNote: .marked, startedAt: since.addingTimeInterval(600))
        let before = stored("b", kind: .note, voiceNote: .marked, startedAt: since.addingTimeInterval(-600))
        #expect(ImportTranscriptionQueue.summarizesOnFinish(isMeeting: true, session: nil, gate: cloudOff))
        #expect(ImportTranscriptionQueue.summarizesOnFinish(isMeeting: false, session: after, gate: cloudOn))
        // A note recorded before the switch, finished on a charger after it.
        #expect(!ImportTranscriptionQueue.summarizesOnFinish(isMeeting: false, session: before, gate: cloudOn))
        #expect(!ImportTranscriptionQueue.summarizesOnFinish(isMeeting: false, session: after, gate: cloudOff))
        #expect(ImportTranscriptionQueue.summarizesOnFinish(isMeeting: false, session: before, gate: local))
        #expect(!ImportTranscriptionQueue.summarizesOnFinish(
            isMeeting: false, session: stored("o", kind: .note, voiceNote: .byShape, startedAt: since.addingTimeInterval(600)), gate: local))
        #expect(!ImportTranscriptionQueue.summarizesOnFinish(isMeeting: false, session: nil, gate: local))
    }

    @Test func theQueuedPassesLookAgainBeforeTheySend() {
        var passes = SessionFinishingPasses(title: "t", localeHint: nil, polish: true, suggestNames: true, attendees: [],
                                            voiceNote: .marked, recordedAt: since.addingTimeInterval(600))
        #expect(passes.mayStillSend(gate: cloudOn))
        #expect(!passes.mayStillSend(gate: cloudOff))
        #expect(passes.mayStillSend(gate: local))
        passes.voiceNote = .none
        #expect(passes.mayStillSend(gate: cloudOff))
    }

    @Test func aQuitRecoverySummarizesOnlyWhatFinalizeWould() {
        #expect(QuitFinalizeRecovery.summarizesRecovered(stored("m", kind: .recording, startedAt: since), gate: cloudOff))
        let before = stored("b", kind: .note, voiceNote: .marked, startedAt: since.addingTimeInterval(-600))
        #expect(!QuitFinalizeRecovery.summarizesRecovered(before, gate: cloudOn))
        #expect(!QuitFinalizeRecovery.summarizesRecovered(before, gate: cloudOff))
        #expect(QuitFinalizeRecovery.summarizesRecovered(before, gate: local))
        #expect(!QuitFinalizeRecovery.summarizesRecovered(stored("h", kind: .note, startedAt: since), gate: local))
    }

    @Test func stopDecidesByTheGateAtTheNotesStart() {
        #expect(RecordingSession.summarizesAtStop(mode: .meeting, kind: .recording, startedAt: nil, gate: cloudOff))
        #expect(RecordingSession.summarizesAtStop(mode: .voiceNote, kind: .note, startedAt: since.addingTimeInterval(1), gate: cloudOn))
        // Started before the switch went on, stopped after.
        #expect(!RecordingSession.summarizesAtStop(mode: .voiceNote, kind: .note, startedAt: since.addingTimeInterval(-1), gate: cloudOn))
        #expect(!RecordingSession.summarizesAtStop(mode: .voiceNote, kind: .note, startedAt: since, gate: cloudOff))
        #expect(RecordingSession.summarizesAtStop(mode: .voiceNote, kind: .note, startedAt: since, gate: local))
        #expect(!RecordingSession.summarizesAtStop(mode: .dictation, kind: .recording, startedAt: since, gate: local))
    }

    @Test func finalizeLooksAgainRightBeforeTheSend() {
        let start = since.addingTimeInterval(600)
        #expect(RecordingSession.summaryStillAllowed(willSummarize: true, isVoiceNote: true, startedAt: start, gate: cloudOn))
        // Switched off, or another provider chosen, during the final pass.
        #expect(!RecordingSession.summaryStillAllowed(willSummarize: true, isVoiceNote: true, startedAt: start, gate: cloudOff))
        #expect(!RecordingSession.summaryStillAllowed(willSummarize: false, isVoiceNote: true, startedAt: start, gate: local))
        // A meeting's answer was Stop's.
        #expect(RecordingSession.summaryStillAllowed(willSummarize: true, isVoiceNote: false, startedAt: nil, gate: cloudOff))
    }

    @Test func aNoteTheProviderDeclinedIsNotTriedEveryEvening() {
        let scratch = ScratchDefaults("voice-note-declines")
        let declines = VoiceNoteProfile.Declines(defaults: scratch.make())
        declines.record("noteAfter", provider: "appleIntelligence", now: since)
        #expect(declines.declined("noteAfter", by: "appleIntelligence", now: since))
        // Another provider may manage it.
        #expect(!declines.declined("noteAfter", by: "daisyLocal", now: since))
        let picked = EndOfDaySummaries.pending(in: library, now: since.addingTimeInterval(86_400), gate: local,
                                               isProcessing: { _ in false },
                                               declined: { declines.declined($0, by: "appleIntelligence", now: since) }).map(\.id)
        #expect(picked == ["noteBefore", "meeting"])
        // A meeting is never skipped this way.
        declines.record("meeting", provider: "appleIntelligence", now: since)
        #expect(EndOfDaySummaries.pending(in: library, now: since.addingTimeInterval(86_400), gate: local,
                                          isProcessing: { _ in false },
                                          declined: { declines.declined($0, by: "appleIntelligence", now: since) }).map(\.id).contains("meeting"))
        // Tried again by the same provider after 30 days.
        #expect(!declines.declined("noteAfter", by: "appleIntelligence", now: since.addingTimeInterval(31 * 86_400)))
        // Old entries go when a new one is written.
        declines.record("later", provider: "appleIntelligence", now: since.addingTimeInterval(40 * 86_400))
        #expect(!declines.declined("noteAfter", by: "appleIntelligence", now: since))
    }

    // MARK: - A voice note's words in requests about something else

    private func summary(_ text: String, steps: [String]) -> Daisy.MeetingSummary {
        Daisy.MeetingSummary(summary: text, sections: [], actionItems: steps, clientFollowUp: "")
    }

    private var summarized: [StoredSession] {
        [stored("meeting", kind: .recording, startedAt: since.addingTimeInterval(-3_600),
                summary: summary("Pricing with Acme", steps: ["Send the contract"])),
         stored("noteBefore", kind: .note, voiceNote: .marked, startedAt: since.addingTimeInterval(-600),
                summary: summary("My private idea", steps: ["Call Boris"])),
         stored("oldNote", kind: .note, voiceNote: .byShape, startedAt: since.addingTimeInterval(-1_200),
                summary: summary("An older thought", steps: ["Check the price"])),
         stored("noteAfter", kind: .note, voiceNote: .marked, startedAt: since.addingTimeInterval(600),
                summary: summary("Allowed idea", steps: ["Book the room"]))]
    }

    @Test func projectMemoryCarriesAVoiceNoteOnlyWhereTheNoteCouldGo() {
        let cloud = ProjectMemoryBridge.earlier(from: summarized, gate: cloudOn).map(\.id)
        #expect(cloud.contains("meeting"))
        #expect(cloud.contains("noteAfter"))
        // Summarized on this Mac before the switch: never in a cloud request.
        #expect(!cloud.contains("noteBefore"))
        #expect(!cloud.contains("oldNote"))
        #expect(ProjectMemoryBridge.earlier(from: summarized, gate: cloudOff).map(\.id) == ["meeting"])
        #expect(Set(ProjectMemoryBridge.earlier(from: summarized, gate: local).map(\.id))
                == ["meeting", "noteBefore", "oldNote", "noteAfter"])
    }

    @Test func theMorningBriefCarriesAVoiceNotesStepsOnlyWhereTheNoteCouldGo() {
        let items = [
            TrackedActionItem(id: "m#0", text: "Send the contract", sessionID: "meeting", sessionTitle: "m",
                              sessionDate: since.addingTimeInterval(-3_600), doneAt: nil, kindKnown: true),
            TrackedActionItem(id: "b#0", text: "Call Boris", sessionID: "noteBefore", sessionTitle: "b",
                              sessionDate: since.addingTimeInterval(-600), doneAt: nil, fromVoiceNote: true, kindKnown: true),
            TrackedActionItem(id: "a#0", text: "Book the room", sessionID: "noteAfter", sessionTitle: "a",
                              sessionDate: since.addingTimeInterval(600), doneAt: nil, fromVoiceNote: true, kindKnown: true),
        ]
        #expect(MorningBriefStore.itemsForProvider(items, gate: cloudOn).map(\.id) == ["m#0", "a#0"])
        #expect(MorningBriefStore.itemsForProvider(items, gate: cloudOff).map(\.id) == ["m#0"])
        #expect(MorningBriefStore.itemsForProvider(items, gate: local).count == 3)
    }

    @Test func aPreMeetingDossierLeavesOutAVoiceNoteKeptOnThisMac() {
        #expect(PreMeetingBriefStore.sessionsForProvider(summarized, gate: cloudOn).map(\.id) == ["meeting", "noteAfter"])
        #expect(PreMeetingBriefStore.sessionsForProvider(summarized, gate: cloudOff).map(\.id) == ["meeting"])
        #expect(PreMeetingBriefStore.sessionsForProvider(summarized, gate: local).count == 4)
    }

    @Test func aSessionWhoseKindCantBeReadStaysOffACloudRequest() {
        // transcript.md evicted to iCloud: read as a recording by default,
        // its summary.json still on disk — it may be a voice note.
        let evicted = stored("evicted", kind: .recording, startedAt: since.addingTimeInterval(600),
                             summary: summary("Maybe a private idea", steps: ["Call Boris"]), kindKnown: false)
        let library = summarized + [evicted]
        #expect(!ProjectMemoryBridge.earlier(from: library, gate: cloudOn).map(\.id).contains("evicted"))
        #expect(ProjectMemoryBridge.earlier(from: library, gate: local).map(\.id).contains("evicted"))
        #expect(!PreMeetingBriefStore.sessionsForProvider(library, gate: cloudOn).map(\.id).contains("evicted"))
        let item = TrackedActionItem(id: "e#0", text: "Call Boris", sessionID: "evicted", sessionTitle: "e",
                                     sessionDate: since.addingTimeInterval(600), doneAt: nil, kindKnown: false)
        #expect(MorningBriefStore.itemsForProvider([item], gate: cloudOn).isEmpty)
        #expect(MorningBriefStore.itemsForProvider([item], gate: local).count == 1)
    }

    @Test func aYesGoesWithTheProviderItWasFor() {
        let scratch = ScratchDefaults("voice-note-switch")
        let cloudSwitch = VoiceNoteCloudSwitch(defaults: scratch.make())
        let anthropic = Daisy.SummaryProviderKind.anthropic.rawValue
        let openai = Daisy.SummaryProviderKind.openai.rawValue
        let apple = Daisy.SummaryProviderKind.appleIntelligence.rawValue
        let note = since.addingTimeInterval(600)

        cloudSwitch.set(true, provider: anthropic, now: since)
        #expect(cloudSwitch.isOn(for: anthropic))
        #expect(!cloudSwitch.isOn(for: openai))
        // The gate as `Gate.current` builds it, for each provider.
        #expect(VoiceNoteProfile.Gate.current(providerIsEffectivelyLocal: false, provider: anthropic, switch: cloudSwitch)
            .allows(recordedAt: note))
        #expect(!VoiceNoteProfile.Gate.current(providerIsEffectivelyLocal: false, provider: openai, switch: cloudSwitch)
            .allows(recordedAt: note))

        // To a local provider and back: the yes is gone.
        cloudSwitch.providerChanged(from: anthropic, to: apple)
        #expect(cloudSwitch.grant == nil)
        #expect(!cloudSwitch.isOn(for: anthropic))
        #expect(!VoiceNoteProfile.Gate.current(providerIsEffectivelyLocal: false, provider: anthropic, switch: cloudSwitch)
            .allows(recordedAt: note))
        // Local needs no yes.
        #expect(VoiceNoteProfile.Gate.current(providerIsEffectivelyLocal: true, provider: apple, switch: cloudSwitch)
            .allows(recordedAt: note))

        // To another cloud provider: gone as well; the same one: kept.
        cloudSwitch.set(true, provider: anthropic, now: since)
        cloudSwitch.providerChanged(from: anthropic, to: anthropic)
        #expect(cloudSwitch.isOn(for: anthropic))
        cloudSwitch.providerChanged(from: anthropic, to: openai)
        #expect(!cloudSwitch.isOn(for: anthropic))
        #expect(!cloudSwitch.isOn(for: openai))
    }

    @Test func aYesIsToWhereTheTextGoes() {
        func destination(_ kind: Daisy.SummaryProviderKind, ollama: String = "http://127.0.0.1:11434",
                         model: String = "llama3.2", lmStudio: String = "http://127.0.0.1:1234",
                         mcp: String = "http://127.0.0.1:11435") -> String {
            Summarizer.destination(kind: kind, ollamaBaseURL: ollama, ollamaModel: model, lmStudioBaseURL: lmStudio, mcpURL: mcp)
        }
        // A fixed destination: the provider's name; the other settings don't count.
        #expect(destination(.anthropic) == "anthropic")
        #expect(destination(.anthropic, ollama: "http://gpu.example:11434") == "anthropic")
        // Configurable ones: the host, and Ollama's cloud models.
        #expect(destination(.ollama) != destination(.ollama, ollama: "http://gpu.example:11434"))
        #expect(destination(.ollama) == destination(.ollama, model: "qwen3:8b"))
        #expect(destination(.ollama) != destination(.ollama, model: "gpt-oss:120b-cloud"))
        #expect(destination(.ollama, ollama: "HTTP://GPU.example:11434/") == destination(.ollama, ollama: "http://gpu.example:11434"))
        #expect(destination(.lmStudio) != destination(.lmStudio, lmStudio: "http://10.0.0.5:1234"))
        #expect(destination(.mcp) != destination(.mcp, mcp: "https://llm.example.com"))
        // Two IPv6 hosts don't read as one once `host` drops the brackets.
        #expect(destination(.ollama, ollama: "http://[::1:1143]") != destination(.ollama, ollama: "http://[::1]:1143"))

        // The switch, as `Summarizer` drives it on such a change.
        let scratch = ScratchDefaults("voice-note-destination")
        let cloudSwitch = VoiceNoteCloudSwitch(defaults: scratch.make())
        let hostA = destination(.ollama, ollama: "http://gpu-a.example:11434")
        let hostB = destination(.ollama, ollama: "http://gpu-b.example:11434")
        cloudSwitch.set(true, provider: hostA, now: since)
        // A set to the same value (or launch, which sets nothing): kept.
        cloudSwitch.providerChanged(from: hostA, to: hostA)
        #expect(cloudSwitch.isOn(for: hostA))
        // Another host: gone, and coming back starts off.
        cloudSwitch.providerChanged(from: hostA, to: hostB)
        #expect(!cloudSwitch.isOn(for: hostB))
        #expect(!cloudSwitch.isOn(for: hostA))
        #expect(!VoiceNoteProfile.Gate.current(providerIsEffectivelyLocal: false, provider: hostA, switch: cloudSwitch)
            .allows(recordedAt: since.addingTimeInterval(600)))
        // A cloud model on the same host is another destination too.
        cloudSwitch.set(true, provider: hostA, now: since)
        cloudSwitch.providerChanged(from: hostA, to: destination(.ollama, ollama: "http://gpu-a.example:11434", model: "x:cloud"))
        #expect(cloudSwitch.grant == nil)
    }
}
