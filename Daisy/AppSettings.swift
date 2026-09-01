//
//  AppSettings.swift
//  Daisy
//
//  User-facing preferences backed by UserDefaults (non-secret) and
//  Keychain (Notion token + parent id). Observable so the UI updates
//  when values change.
//

import AppKit
import Foundation
import Observation
import os

enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    static let defaultsKey = "daisy.appAppearance"

    static func stored(in defaults: UserDefaults = .standard) -> Self {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let preference = Self(rawValue: rawValue) else {
            return .system
        }
        return preference
    }
}

/// One AppKit appearance source for every Daisy surface: SwiftUI windows,
/// menu-bar popover, floating panel, sheets, and native alerts.
@MainActor
enum AppearanceController {
    static func apply(_ preference: AppearancePreference) {
        switch preference {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

@Observable
@MainActor
final class AppSettings {
    // Non-secret prefs.
    var captureSystemAudio: Bool {
        didSet { defaults.set(captureSystemAudio, forKey: Self.k_captureSystemAudio) }
    }

    /// Persistent UID of the user-picked microphone, or empty string
    /// to follow the macOS system default (the legacy v1.0 behaviour).
    /// We store UID rather than `AudioDeviceID` because UID is stable
    /// across reboots and reconnects; `AudioDeviceID` is not.
    /// `CoreAudioMicRecorder` resolves UID → live `AudioDeviceID` at
    /// every recording start, and silently falls back to system default
    /// if the saved device is gone (unplugged headset, removed USB
    /// interface, etc.).
    var selectedMicDeviceUID: String {
        didSet { defaults.set(selectedMicDeviceUID, forKey: Self.k_selectedMicDeviceUID) }
    }

    /// Optional conservative microphone noise gate. Processing stays
    /// entirely on-device and is applied before audio reaches the live
    /// transcriber or archive. Off by default: a gate can make very quiet
    /// speech less natural, so users should enable it only after listening
    /// to their own setup through Recording → Audio diagnostics.
    var microphoneNoiseSuppressionEnabled: Bool {
        didSet {
            defaults.set(
                microphoneNoiseSuppressionEnabled,
                forKey: Self.k_microphoneNoiseSuppressionEnabled
            )
        }
    }

    var screenshotsEnabled: Bool {
        didSet { defaults.set(screenshotsEnabled, forKey: Self.k_screenshotsEnabled) }
    }
    var screenshotIntervalSec: Int {
        didSet { defaults.set(screenshotIntervalSec, forKey: Self.k_screenshotInterval) }
    }
    /// Whether text read off the screen also goes to the SUMMARIZER.
    /// Independent of `screenshotsEnabled`: turning this off still writes
    /// the "Shared on screen" section into transcript.md and still makes
    /// it searchable — it only stops the text being appended to the
    /// summary prompt. On by default, which is the behaviour that
    /// shipped.
    ///
    /// Asked for by a tester who believed screen content was filling his
    /// local model's context window (Ken, 2026-07-28). It wasn't — the
    /// extract is capped at 5000 characters, roughly 1.7k tokens against
    /// 20-30k for an hour of speech — but the switch is cheap, and
    /// someone summarising a screen-share of unrelated work has a real
    /// reason to want it.
    var screenTextInSummary: Bool {
        didSet { defaults.set(screenTextInSummary, forKey: Self.k_screenTextInSummary) }
    }

    /// Opt-in local pseudonymization before content reaches a configured
    /// remote summary provider. Confirmed local providers bypass it. The
    /// first release is OFF by default while EN/RU detection quality is
    /// evaluated; the Settings copy explicitly avoids promising complete
    /// anonymity.
    var protectSensitiveDataBeforeCloudAI: Bool {
        didSet {
            defaults.set(
                protectSensitiveDataBeforeCloudAI,
                forKey: Self.k_protectSensitiveDataBeforeCloudAI
            )
        }
    }
    /// Opt-in: import Apple Voice Memos recordings as transcripts into a
    /// "Voice Memos" subfolder of the transcripts folder. Off by default.
    /// Reading the Voice Memos library needs Full Disk Access (the
    /// Settings → Transcription row guides the user). Drives `VoiceMemoScanner`.
    var ingestVoiceMemos: Bool {
        didSet { defaults.set(ingestVoiceMemos, forKey: Self.k_ingestVoiceMemos) }
    }
    /// WHEN the summarizer runs. Substrate for `summaryTiming` — kept
    /// as a stored Bool because two paths read it directly, including
    /// `QuitFinalizeRecovery`, which reads UserDefaults from a context
    /// with no `AppSettings` at all. Same shape as
    /// `autoStartPolicy` → `autoStartOnMeeting`.
    ///
    /// True == summarize inline in the post-stop pipeline. False covers
    /// BOTH "never" and "later tonight" — the scheduler is what tells
    /// them apart, and it must not run inline either way.
    var autoSummarize: Bool {
        didSet { defaults.set(autoSummarize, forKey: Self.k_autoSummarize) }
    }

    /// When summaries happen. Replaces a bare on/off switch, because
    /// the real question was never whether to summarize — it was
    /// whether to do it while the user is still holding the laptop.
    ///
    /// A local model summarizing right after Stop lands on a machine
    /// that has just finished a final Whisper pass, speaker matching and
    /// screen OCR; that pile-up is what "Daisy melts my Mac" actually
    /// is (Ken, 2026-07-29). Deferring the LLM to a quiet hour costs
    /// nothing but patience.
    var summaryTiming: SummaryTiming {
        didSet {
            guard summaryTiming != oldValue else { return }
            defaults.set(summaryTiming.rawValue, forKey: Self.k_summaryTiming)
            // Write through: `.afterEachMeeting` is the ONLY value that
            // may run inline.
            if autoSummarize != (summaryTiming == .afterEachMeeting) {
                autoSummarize = (summaryTiming == .afterEachMeeting)
            }
        }
    }

    /// Transient: true iff `summaryTiming` came from an explicit stored
    /// value rather than being derived from `autoSummarize`. Gates the
    /// end-of-init reconcile — deriving then writing back would be a
    /// no-op, and on the legacy path the Bool is the source of truth.
    @ObservationIgnored
    private var didLoadStoredSummaryTiming = false

    /// Hour of day (0-23, local) the end-of-day pass runs at. Only
    /// meaningful for `.endOfDay`.
    var endOfDaySummaryHour: Int {
        didSet { defaults.set(endOfDaySummaryHour, forKey: Self.k_endOfDaySummaryHour) }
    }

    /// Optional workday boundary used only by the local Home analytics.
    /// Off by default: Daisy must not guess that a 19:00 recording is
    /// "after hours" until the user has said what their hours are.
    var workingHoursEnabled: Bool {
        didSet { defaults.set(workingHoursEnabled, forKey: Self.k_workingHoursEnabled) }
    }

    /// Minutes from local midnight. Half-hour steps in Settings, stored as
    /// integers so the analytics can do calendar math without formatter
    /// round-trips. End may be 1440, meaning midnight at the end of the day.
    var workingDayStartMinutes: Int {
        didSet { defaults.set(workingDayStartMinutes, forKey: Self.k_workingDayStartMinutes) }
    }

    var workingDayEndMinutes: Int {
        didSet { defaults.set(workingDayEndMinutes, forKey: Self.k_workingDayEndMinutes) }
    }

    /// Pre-meeting brief: when ON, Home assembles a short brief for an
    /// upcoming calendar meeting from the user's OWN past sessions with
    /// the same people (matched by attendee email / linked event title).
    /// Default OFF — sending past-session excerpts to a CLOUD provider is
    /// new data egress, so it must be opt-in (a cloud provider additionally
    /// requires a per-meeting "Generate" tap; local providers auto-run).
    var preMeetingBriefEnabled: Bool {
        didSet { defaults.set(preMeetingBriefEnabled, forKey: Self.k_preMeetingBriefEnabled) }
    }

    /// Morning brief card on Home: today's meetings + open action items
    /// + (provider permitting) an LLM "what matters today" lede. Default
    /// ON — the card only appears when there's content, the LLM part is
    /// consent-gated on cloud providers, and everything else is local.
    var morningBriefEnabled: Bool {
        didSet { defaults.set(morningBriefEnabled, forKey: Self.k_morningBriefEnabled) }
    }

    /// Daily "your brief is ready" notification. Default OFF.
    var morningBriefNotifyEnabled: Bool {
        didSet { defaults.set(morningBriefNotifyEnabled, forKey: Self.k_morningBriefNotifyEnabled) }
    }

    /// Notification time as minutes from local midnight (default 09:00).
    var morningBriefNotifyMinutes: Int {
        didSet { defaults.set(morningBriefNotifyMinutes, forKey: Self.k_morningBriefNotifyMinutes) }
    }

    /// Opt-in online research for the brief. When ON *and* an Anthropic
    /// API key is present, the brief is augmented with a short web-search
    /// pass about the attendees / their company (Anthropic's web_search
    /// tool). Default OFF — keeps the brief fully local unless the user
    /// explicitly opts into the network. No-op (silently skipped) when
    /// there's no Anthropic key.
    var preMeetingBriefResearchOnline: Bool {
        didSet { defaults.set(preMeetingBriefResearchOnline, forKey: Self.k_preMeetingBriefResearchOnline) }
    }

    /// Second LLM pass over the finished transcript: fix names, brands,
    /// and terms that speech recognition got wrong, leaving the wording
    /// alone (`TranscriptPolisher`). Default ON — but the runtime gate
    /// in `RecordingSession.runTranscriptPolish` is the one that
    /// matters, and it is stricter than this flag: the pass only runs
    /// when the transcript was ALREADY going to the configured provider
    /// (local provider, or a cloud provider the user already opted into
    /// summarizing with). A cloud provider plus summaries off means the
    /// pass is skipped rather than becoming the first thing to send the
    /// transcript off the Mac.
    ///
    /// Not *no* new egress, though — say it plainly: on the cloud path
    /// the prompt also carries the invite's attendee names and up to
    /// `polishVocabularyLimit` of the user's vocabulary terms, neither
    /// of which the ordinary summary prompt sends. That's the feature
    /// working (the names ARE the context that fixes the names), it's
    /// spelled out in the Settings caption, and it's why the vocabulary
    /// is capped.
    ///
    /// One flag, two passes: this also gates
    /// `runSpeakerNameSuggestions`, which spends a SECOND request
    /// proposing which attendee each speaker is. They're one setting
    /// because they're one bargain from the user's side — "let a model
    /// read the finished transcript with my calendar as context" — and
    /// splitting them would be a settings screen describing an
    /// implementation detail. The caption states both. Users who'd
    /// rather not spend the requests, or not send that context, turn it
    /// off here.
    var transcriptSecondPass: Bool {
        didSet { defaults.set(transcriptSecondPass, forKey: Self.k_transcriptSecondPass) }
    }

    /// Language the summary itself is written in. Decoupled from
    /// the transcript locale because users often record meetings in
    /// one language but want the summary in another (e.g. record RU,
    /// summarise EN for a partner who'll read the notes).
    ///
    /// Stored as the value of `SummaryLanguage.id`. "auto" means
    /// "use the transcript's language" — the historical behaviour.
    var summaryLanguage: String {
        didSet { defaults.set(summaryLanguage, forKey: Self.k_summaryLanguage) }
    }

    /// Default transcription locale applied to every new session
    /// at creation time. Same string contract as
    /// `Transcriber.availableLocales` — "auto" means
    /// `NLLanguageRecognizer`-driven auto-detect on first
    /// transcript chunks; otherwise a two-letter ISO code locks
    /// Whisper to that language. Stored separately from the
    /// per-session `localeIdentifier` so users with stable
    /// recording habits (always RU, always EN) don't have to
    /// re-pick on every session.
    var defaultTranscriptionLocale: String {
        didSet { defaults.set(defaultTranscriptionLocale, forKey: Self.k_defaultTranscriptionLocale) }
    }

    /// Voice-note mode override for transcription locale. Empty
    /// string means "use `defaultTranscriptionLocale`" (the
    /// meeting default). Non-empty overrides per-mode — useful
    /// when the user records meetings in English but dictates
    /// personal notes in Russian (or vice versa).
    var voiceNoteLocale: String {
        didSet { defaults.set(voiceNoteLocale, forKey: Self.k_voiceNoteLocale) }
    }

    /// Folder that auto-started / calendar-bound MEETINGS file into when
    /// the session is still in the default Inbox (the user can always
    /// override per-session in the UI). Stored as a slug; resolved via
    /// `FolderStore.existingFolder(slug:)`, falling back to Inbox if the
    /// folder was deleted. Default "work" preserves the long-standing
    /// hardcoded behaviour. Voice notes keep their own fixed target
    /// (Notes) — this knob is meetings only. (Egor 2026-06-20)
    var defaultMeetingFolderSlug: String {
        didSet { defaults.set(defaultMeetingFolderSlug, forKey: Self.k_defaultMeetingFolderSlug) }
    }

    /// Dictation mode override for transcription locale. Same
    /// contract as `voiceNoteLocale` — empty falls back to the
    /// meeting default. Defaults to empty so behaviour is
    /// backwards-compatible for users who haven't picked yet.
    var dictationLocale: String {
        didSet { defaults.set(dictationLocale, forKey: Self.k_dictationLocale) }
    }

    /// Engine used for the DICTATION final pass (the text that gets
    /// pasted). Three choices, all on-device:
    ///   • `.whisper`  — WhisperKit, the default/fallback (diarization-
    ///     grade quality; carries the ~1 resident Whisper model).
    ///   • `.parakeet` — FluidAudio Parakeet, low-latency NE transducer,
    ///     multilingual incl. RU; one-time ~600 MB download.
    ///   • `.appleSpeech` — Apple SpeechAnalyzer / SpeechTranscriber
    ///     (macOS 26+). ~2× faster than Whisper turbo, model ships with
    ///     the OS (ZERO app-bundle weight). Needs a concrete language
    ///     (no "auto") and macOS 26; falls back to Whisper otherwise.
    /// Migrated once from the legacy `dictationUseParakeet` bool.
    var dictationEngine: DictationEngine {
        didSet { defaults.set(dictationEngine.rawValue, forKey: Self.k_dictationEngine) }
    }

    /// Back-compat convenience — several read sites (MainView status,
    /// LogReporter, dictation warm-up, Settings badge) still ask "is
    /// Parakeet the dictation engine?". Derived from `dictationEngine`.
    var dictationUseParakeet: Bool { dictationEngine == .parakeet }

    /// When ON, each finished dictation is rewritten in the user's own
    /// voice (via the local Voice Profile) before it's pasted. Adds one
    /// LLM pass to the paste path, so it's opt-in and default OFF. No-op
    /// until a voice profile has been generated (Voice section).
    var polishDictationInMyVoice: Bool {
        didSet { defaults.set(polishDictationInMyVoice, forKey: Self.k_polishDictationInMyVoice) }
    }

    /// Built-in dictation layer restoring transliterated product names
    /// to their Latin spelling («фигма» → "Figma") on every engine —
    /// Parakeet can't be vocabulary-biased, so this is the only way it
    /// gets brand names right in non-Latin speech. Curated table in
    /// BrandTransliterations.swift; the user's own Vocabulary rules
    /// always take precedence. Default ON. Key lives on
    /// `BrandCorrections.defaultsKey` because DictationPaste (no
    /// AppSettings reference) reads it straight from UserDefaults.
    var fixBrandNamesInDictation: Bool {
        didSet { defaults.set(fixBrandNamesInDictation, forKey: BrandCorrections.defaultsKey) }
    }

    /// EXPERIMENTAL: stream the DICTATION live preview through FluidAudio's
    /// Nemotron 3.5 multilingual streaming ASR (560 ms chunks, Neural
    /// Engine) instead of the Whisper rolling-window pass. Preview-only —
    /// the pasted text still comes from Whisper/Parakeet on release.
    /// Default off. UI: Settings → Transcription → "Live preview while
    /// dictating" (the badge doubles as the download indicator). First
    /// enable triggers a one-time model download (multilingual 560 ms
    /// variant). See NemotronLiveEngine.
    var dictationUseNemotronLive: Bool {
        didSet { defaults.set(dictationUseNemotronLive, forKey: Self.k_dictationUseNemotronLive) }
    }

    /// Global meeting-recorder hotkey (mode = .meeting). `.none`
    /// disables. Stored in UserDefaults as JSON (struct, not enum
    /// any more). This is the original Daisy hotkey from 1.0.x.
    var recordHotkey: HotkeyChoice {
        didSet {
            if let data = try? JSONEncoder().encode(recordHotkey) {
                defaults.set(data, forKey: Self.k_recordHotkey)
            }
        }
    }

    /// Voice-notes hotkey (mode = .voiceNote). Starts a quick
    /// personal recording with no LLM summary and routes the
    /// session into the Notes folder. Toggle on/off; same UX as
    /// `recordHotkey` but for the lighter "I want to capture this
    /// thought before I forget" flow. `.none` disables.
    var voiceNoteHotkey: HotkeyChoice {
        didSet {
            if let data = try? JSONEncoder().encode(voiceNoteHotkey) {
                defaults.set(data, forKey: Self.k_voiceNoteHotkey)
            }
        }
    }

    /// Dictation hotkey (mode = .dictation). Wispr-Flow-lite: hold
    /// to record, release to transcribe → put on the clipboard +
    /// fire a toast prompting Cmd+V. No session is saved, no LLM
    /// summary runs. `.none` disables. Same JSON storage as the
    /// other two hotkeys.
    var dictationHotkey: HotkeyChoice {
        didSet {
            if let data = try? JSONEncoder().encode(dictationHotkey) {
                defaults.set(data, forKey: Self.k_dictationHotkey)
            }
        }
    }

    /// Global hotkey for "rewrite selection in my voice" — grabs the
    /// selected text in ANY app, rewrites it through the Voice Profile
    /// on the selected summary provider, and pastes the result back over
    /// the selection. `.none` (default) disables — the feature needs a
    /// generated Voice Profile to do anything, so it's opt-in.
    var rewriteSelectionHotkey: HotkeyChoice {
        didSet {
            if let data = try? JSONEncoder().encode(rewriteSelectionHotkey) {
                defaults.set(data, forKey: Self.k_rewriteSelectionHotkey)
            }
        }
    }

    /// Rewrite the client follow-up in the user's own voice, using the
    /// Voice Profile, before it is saved or sent anywhere. OFF by default:
    /// it is a second provider call on every meeting that has a follow-up.
    /// See FollowUpVoice for why it is a second pass and not a longer
    /// summary prompt.
    var followUpsInMyVoice: Bool {
        didSet { defaults.set(followUpsInMyVoice, forKey: Self.k_followUpsInMyVoice) }
    }

    /// Global hotkey for "fix the keyboard layout" — «ghbdtn» becomes
    /// «привет». Fixes the selection, or the word being typed when the
    /// automatic watcher is running. `.none` (default) disables.
    var layoutFixHotkey: HotkeyChoice {
        didSet {
            if let data = try? JSONEncoder().encode(layoutFixHotkey) {
                defaults.set(data, forKey: Self.k_layoutFixHotkey)
            }
        }
    }

    /// Turn every screenshot into a note, with a few seconds afterwards
    /// during which dictation goes into that note instead of pasting.
    /// OFF by default: it watches a folder we were never watching, which
    /// raises a system prompt, and it files things the user didn't
    /// explicitly ask to file. See `ScreenshotNoteCapture`.
    var screenshotNotesEnabled: Bool {
        didSet { defaults.set(screenshotNotesEnabled, forKey: Self.k_screenshotNotesEnabled) }
    }

    /// Global hotkey for "paste my last dictation" — re-inserts the most
    /// recent dictation at the caret (Wispr's "paste last transcript").
    /// Recovers a dictation that landed nowhere because no field was
    /// focused. `.none` (default) disables.
    var repasteLastHotkey: HotkeyChoice {
        didSet {
            if let data = try? JSONEncoder().encode(repasteLastHotkey) {
                defaults.set(data, forKey: Self.k_repasteLastHotkey)
            }
        }
    }

    /// Global hotkey for "mark this moment" — the user's own judgement
    /// about which minute of a recording mattered, stated live. Only
    /// does anything while recording. `.none` (default) disables.
    /// See `MomentMarkers` for why the marker, not the frame, is the
    /// feature.
    var markMomentHotkey: HotkeyChoice {
        didSet {
            if let data = try? JSONEncoder().encode(markMomentHotkey) {
                defaults.set(data, forKey: Self.k_markMomentHotkey)
            }
        }
    }

    /// Fix the layout automatically, word by word, without a keypress.
    /// OFF by default and deliberately hard to turn on by accident: it
    /// needs Accessibility access, and it rewrites text nobody asked it to
    /// touch. See LayoutAutoFix for what it does and does not watch.
    var layoutFixAuto: Bool {
        didSet { defaults.set(layoutFixAuto, forKey: Self.k_layoutFixAuto) }
    }

    /// After a fix, switch the active input source to the layout the text
    /// belonged to. On by default — without it the fix is one word and
    /// the next word goes wrong the same way.
    var layoutFixSwitchesSource: Bool {
        didSet { defaults.set(layoutFixSwitchesSource, forKey: Self.k_layoutFixSwitchesSource) }
    }

    /// When ON, Daisy auto-starts a recording the moment one of the
    /// known meeting apps (Zoom / Teams / Telegram / etc.) launches.
    ///
    /// As of 1.0.7.9 this is no longer a directly user-facing toggle —
    /// it's a derived wiring flag written through by `autoStartPolicy`'s
    /// `didSet`. The Settings UI exposes the 4-mode policy instead; this
    /// bool (and `autoStartFromCalendar`) remain the substrate that
    /// `ServiceWiring.applyMeetingAutoStart` / `applyCalendar` and the
    /// MainView `.onChange` re-wiring read, so the existing detection
    /// plumbing keeps working untouched. Kept persisted so a downgrade
    /// to a pre-policy build still finds a sane value.
    var autoStartOnMeeting: Bool {
        didSet { defaults.set(autoStartOnMeeting, forKey: Self.k_autoStartOnMeeting) }
    }

    /// Granular auto-start policy (Talat-parity), the single user-facing
    /// control in Settings → Meetings. Supersedes the old pair of
    /// independent "Start when a meeting app opens" / "Start at the
    /// scheduled meeting time" toggles with one segmented control:
    ///
    ///   • **Always**    — auto-record every detected call (both the
    ///     NSWorkspace app-launch detector AND the calendar detector
    ///     fire, and each starts recording immediately).
    ///   • **Selective** — auto-record only calendar-synced meetings
    ///     (events that carry a Zoom/Meet/Teams/Webex link). The
    ///     app-launch detector is suppressed, so opening Zoom for a
    ///     personal call you didn't schedule won't be captured. This is
    ///     the simplest sensible "allowlist" that fits Daisy — the
    ///     calendar IS the allowlist. (A per-app allowlist was judged
    ///     too heavy for this surface; noted in the 1.0.7.9 work.)
    ///   • **Prompt**    — detect the call and ASK first via a macOS
    ///     banner with Record / Ignore actions, instead of starting
    ///     silently. Applies to BOTH detectors.
    ///   • **Manual**    — never auto-start; only the Record button /
    ///     hotkey starts a session.
    ///
    /// `didSet` writes through to the legacy `autoStartOnMeeting` /
    /// `autoStartFromCalendar` substrate flags + the `autoStartPromptMode`
    /// flag, so all existing wiring (`ServiceWiring`, the MainView
    /// `.onChange` handlers, `CalendarService.tick`) keeps functioning
    /// with no structural change. The mapping:
    ///   Always    → app-launch ON,  calendar ON,  prompt OFF
    ///   Selective → app-launch OFF, calendar ON,  prompt OFF
    ///   Prompt    → app-launch ON,  calendar ON,  prompt ON
    ///   Manual    → app-launch OFF, calendar OFF, prompt OFF
    var autoStartPolicy: AutoStartPolicy {
        didSet {
            defaults.set(autoStartPolicy.rawValue, forKey: Self.k_autoStartPolicy)
            applyAutoStartPolicyToSubstrate()
        }
    }

    /// Derived from `autoStartPolicy` (set ON only when policy is
    /// `.prompt`). When true, the detection paths — calendar
    /// (`RecordingSession.startFromMeeting`) and app-launch
    /// (`ServiceWiring.applyMeetingAutoStart`) — surface a Record /
    /// Ignore banner instead of starting the recording directly. Stored
    /// so a process restart preserves the choice without re-deriving
    /// (the policy `didSet` also keeps it in sync).
    var autoStartPromptMode: Bool {
        didSet { defaults.set(autoStartPromptMode, forKey: Self.k_autoStartPromptMode) }
    }

    /// Transient (not persisted): true iff `autoStartPolicy` was loaded
    /// from an explicit stored value at init, vs. derived from the
    /// legacy bools. Gates the one-shot end-of-init substrate reconcile
    /// so we only let the policy overwrite the bools when the user has
    /// actually adopted the new control — never on the legacy path,
    /// where flipping a bool would change behaviour (e.g. an app-launch-
    /// only legacy user must NOT get calendar auto-start turned on).
    @ObservationIgnored
    private var didLoadStoredAutoStartPolicy: Bool = false

    /// When ON, finishing a session (Stop) automatically opens the
    /// just-recorded session in History so the transcript is visible
    /// immediately, and the summary section pops in once the LLM
    /// returns. Default OFF — Daisy stays in the background by
    /// default; users who want the Granola-style "session window
    /// pops up after every meeting" flow flip this on.
    var showSessionAfterStop: Bool {
        didSet { defaults.set(showSessionAfterStop, forKey: Self.k_showSessionAfterStop) }
    }

    /// When ON, Daisy posts a "Are we done?" macOS banner after a
    /// long stretch of silence during recording (3 min) or a long
    /// pause (5 min). OFF disables the prompt entirely — the
    /// SilenceMonitor still tracks state internally (cheap), it
    /// just never surfaces a banner.
    var silencePromptsEnabled: Bool {
        didSet { defaults.set(silencePromptsEnabled, forKey: Self.k_silencePromptsEnabled) }
    }

    /// When ON (default), Daisy posts a macOS banner the moment the
    /// calendar-driven auto-start fires. Includes a "Stop & save"
    /// action so the user can bail out if Daisy picked up a meeting
    /// they didn't want recorded.
    var notifyOnAutoStart: Bool {
        didSet { defaults.set(notifyOnAutoStart, forKey: Self.k_notifyOnAutoStart) }
    }

    /// When ON (default), Daisy posts a confirmation banner when the
    /// calendar-driven auto-stop fires and the recording is saved.
    var notifyOnAutoStop: Bool {
        didSet { defaults.set(notifyOnAutoStop, forKey: Self.k_notifyOnAutoStop) }
    }

    /// When ON, the diarization pass also runs over the microphone
    /// stream — useful when remote-meeting participants are heard
    /// through the user's speakers (in-room playback) instead of
    /// being captured separately via system-audio loopback. Mic-side
    /// segments then get "Speaker A / B / C" labels instead of all
    /// collapsing into "Me". OFF by default — adds Pyannote inference
    /// over the full mic recording (CoreML, neural-engine, ~15-25%
    /// of Whisper runtime), so for the common one-user case it's
    /// wasted compute.
    var diarizeMicrophone: Bool {
        didSet { defaults.set(diarizeMicrophone, forKey: Self.k_diarizeMicrophone) }
    }

    /// When ON (default), Whisper transcribes audio in rolling 2-second
    /// passes WHILE the meeting is happening, so the user sees segments
    /// appear in the toolbar popover in near-real-time. When OFF,
    /// Whisper is silent during recording — only the audio archive
    /// gets written to disk; transcription runs as a single pass on
    /// Stop. Off-mode is dramatically lighter on the MainActor (no
    /// per-window commits + cache invalidations + SwiftUI cascades),
    /// which makes long sessions feel snappier and pause/resume
    /// react instantly even on 1.5h+ recordings. Trade-off: no live
    /// transcript view during the meeting. Build 43 added this as
    /// an opt-in perf escape hatch after Egor's hypothesis: "может
    /// можно сделать так что бы не сразу превращать в текст и так
    /// будет легче?" — yes, materially.
    ///
    /// Future direction: this may become default OFF for ≥macOS 26
    /// where MainActor saturation under the new SwiftUI Observable
    /// system is more pronounced. For now default ON keeps the
    /// behaviour everyone's used to.
    var liveTranscriptionTier: LiveTranscriptionTier {
        didSet { defaults.set(liveTranscriptionTier.rawValue, forKey: Self.k_liveTranscriptionTier) }
    }

    /// Speakers mode for the system-audio stream. When `true` (default,
    /// behaviour up to 1.0.6.x), pyannote diarizes the remote stream
    /// into Bobby / Wags / Faraday / etc — one label per detected
    /// voice cluster. When `false` ("Two sides" / Granola-style),
    /// the remote diarizer is disabled entirely and every system-audio
    /// segment gets a single "Remote" label. The latter is useful
    /// when:
    ///   • Meeting has rapid back-and-forth or similar-sounding voices
    ///     where the auto-detector over-splits clusters (4 actual
    ///     speakers → 5+ labels with gaps like A / B / D / F / G)
    ///   • User just wants the simpler "you vs them" output and
    ///     doesn't care which remote spoke
    ///   • Faster post-stop (skips pyannote on system stream)
    /// The mic stream is unaffected — it's still labeled with
    /// `userDisplayName` or "Me".
    var diarizeRemoteSpeakers: Bool {
        didSet { defaults.set(diarizeRemoteSpeakers, forKey: Self.k_diarizeRemoteSpeakers) }
    }

    /// EXPERIMENTAL (default OFF). When ON and a recording is bound to a
    /// calendar event, Daisy pins the remote diarizer to the attendee
    /// count (minus you) as a hard `numClusters` hint instead of auto-
    /// detect. Can sharpen diarization when the invite is accurate, but a
    /// wrong count (no-shows, uninvited joiners, one person on two devices)
    /// can make it worse — hence opt-in, pending on-device A/B. Surfaced
    /// in Settings → Recording → Speakers so that A/B can run on real
    /// meetings; stays default OFF until it wins one.
    var diarizeUseAttendeeCountHint: Bool {
        didSet { defaults.set(diarizeUseAttendeeCountHint, forKey: Self.k_diarizeUseAttendeeCountHint) }
    }

    /// Post-merge dedup pass for acoustic loopback. When ON (default),
    /// after both mic and system transcribers finish, the merge step
    /// walks every mic-side segment and drops it if a system-side
    /// segment within ±2s has matching text (normalized Levenshtein
    /// similarity >0.8, ±20% length). Targets the case where the user
    /// plays meeting audio through speakers instead of headphones:
    /// the mic picks up the same audio and Whisper transcribes it
    /// twice. Sequential matches (3+ consecutive) are treated as
    /// confirmed echo. Isolated single matches are kept on the
    /// assumption that the user might be quoting what the other
    /// person said. Set OFF only if you need every mic segment
    /// preserved (e.g., diagnostic / archival use cases) and accept
    /// the duplicate-attribution noise.
    var suppressAcousticEcho: Bool {
        didSet { defaults.set(suppressAcousticEcho, forKey: Self.k_suppressAcousticEcho) }
    }

    /// Post-stop global speaker re-clustering. When ON (default), once
    /// the post-stop pipeline writes transcript + summary, a final
    /// async pass loads the full concatenated audio off disk and
    /// re-runs pyannote diarization with global context (the live
    /// path only sees streaming 10-30s chunks, so the same voice
    /// can fragment into Remote A / Remote D / Remote G across
    /// chunks). The re-clustered labels are mapped back to the live
    /// transcript by IoU overlap so user-applied speaker names
    /// (Remote A → Алиса) survive. Adds 30-90s of background work
    /// for typical meetings; user-visible state stays in `.finished`
    /// throughout. Set OFF for the fastest possible Stop & save and
    /// accept that some speakers may fragment.
    var globalReclusterAfterStop: Bool {
        didSet { defaults.set(globalReclusterAfterStop, forKey: Self.k_globalReclusterAfterStop) }
    }

    /// Display name used for the user's own voice in transcripts.
    /// Empty (default) → falls back to the legacy "Me" label.
    /// When set, mic-source segments render as `[Egor]` instead of
    /// `[Me]` in the live transcript UI, the saved transcript.md
    /// frontmatter body, AND the LLM prompt — giving the summarizer
    /// concrete identity for sentences like "Maria asked Egor about
    /// pricing" instead of a generic first-person placeholder.
    var userDisplayName: String {
        didSet { defaults.set(userDisplayName, forKey: Self.k_userDisplayName) }
    }

    /// How cross-meeting speaker recognition behaves once Daisy has a
    /// known speaker (voice fingerprint and/or email) that matches a
    /// new session. Three modes (Talat-parity, 1.0.7.10):
    ///   • `.automatic` (DEFAULT) — apply the match silently, pre-
    ///     filling the transcript's speaker map. This is the behaviour
    ///     of every build before 1.0.7.10, kept as default so existing
    ///     users see NO change (Talat itself defaults to Suggest, but
    ///     we don't silently downgrade an experience people already
    ///     rely on).
    ///   • `.suggest` — compute the match but DON'T apply it; surface
    ///     it as a confirmable suggestion (post-stop notification +
    ///     a Confirm affordance in the session's Name-the-speakers
    ///     card) so the user approves before names land in the
    ///     transcript.
    ///   • `.off` — no cross-meeting auto-match at all; speakers stay
    ///     "Remote A/B/C" until the user names them by hand. The
    ///     voice fingerprint is still persisted on manual naming
    ///     (so turning this back on later works), just never auto-
    ///     applied. Per-session `speakers.json` is written regardless.
    /// Note: this gates the AUTO-LABEL step only. The underlying voice-
    /// match engine (`SpeakerProfileStore.findMatch`) is unchanged.
    var speakerMatchMode: SpeakerMatchMode {
        didSet { defaults.set(speakerMatchMode.rawValue, forKey: Self.k_speakerMatchMode) }
    }

    /// Days to keep raw audio (.caf) files for finished sessions.
    /// Tag conventions:
    ///   • `audioRetentionDeleteAfterTranscription` (-1) — fresh-
    ///     install default since 1.0.6.12. Audio purges per-session
    ///     immediately after `finalizePostStop` lands transcript +
    ///     summary on disk. No timer sweep involved. Matches the
    ///     "audio doesn't outlive the pipeline" privacy posture
    ///     Granola made the table-stakes in this category.
    ///   • `0` — keep forever. Default for users upgrading from
    ///     pre-1.0.6.12 builds who never opened Settings → Storage.
    ///   • positive N — keep N days, then sweep at app launch
    ///     (`AudioRetentionSweep.runIfNeeded`). Existing 1/7/30
    ///     picks preserve their semantic.
    /// In all modes, transcript.md / summary.json / speakers.json /
    /// screenshots stay intact — only raw `.caf` archives are
    /// purged.
    var audioRetentionDays: Int {
        didSet { defaults.set(audioRetentionDays, forKey: Self.k_audioRetentionDays) }
    }

    /// Sentinel value for `audioRetentionDays` meaning "delete the
    /// raw audio as soon as Daisy is done with it (post-transcript +
    /// summary)". Negative so it never collides with a real day
    /// count, both forward and backward. Constant exposed publicly
    /// so callers (RecordingSession, SettingsView, AudioRetentionSweep)
    /// don't magic-number the -1.
    static let audioRetentionDeleteAfterTranscription: Int = -1

    /// Sentinel value for `audioRetentionDays` meaning "don't write
    /// audio to disk at all" (build 44). The strongest privacy
    /// posture in the picker — Whisper still consumes from the live
    /// in-memory PCM stream (AsyncStream from the tap closure), so
    /// the transcript is unaffected; only the on-disk `.caf` archive
    /// is skipped. RecordingSession reads this constant and passes
    /// `archiveURL: nil` to `recorder.start()` and
    /// `systemAudio.start()`. Trade-off: no crash-recovery from
    /// disk (if Daisy crashes mid-meeting the transcript is lost),
    /// no re-transcription with a different Whisper model later.
    /// Matches the "transcription only" mode Fireflies / Read.ai /
    /// Wispr Flow ship as a compliance / privacy escape hatch.
    static let audioRetentionDoNotRecord: Int = -2

    /// When ON, Daisy plays a short macOS system sound on recording
    /// transitions (start / pause / resume / stop). Off for users
    /// who record in environments where the click would be picked
    /// up by their own mic or who just don't like audio chrome.
    /// Default ON because the cues are quiet (~0.4 volume) and
    /// the feedback materially helps remind a user the session is
    /// live when the floating widget isn't visible.
    var recordingSoundsEnabled: Bool {
        didSet { defaults.set(recordingSoundsEnabled, forKey: Self.k_recordingSoundsEnabled) }
    }

    /// When ON, Daisy's menu-bar item shows the next upcoming
    /// calendar event next to its icon ("14:30 · Q3 Review") so the
    /// user can glance at it without opening Daisy. Off by default —
    /// adds chrome to the menu bar that some users don't want.
    /// Suppressed while recording (recording state takes priority).
    var menuBarShowsNextMeeting: Bool {
        didSet { defaults.set(menuBarShowsNextMeeting, forKey: Self.k_menuBarShowsNextMeeting) }
    }

    /// App-wide colour appearance. System follows the Mac automatically;
    /// explicit light/dark choices update every Daisy window immediately.
    var appAppearance: AppearancePreference {
        didSet {
            defaults.set(appAppearance.rawValue, forKey: AppearancePreference.defaultsKey)
            AppearanceController.apply(appAppearance)
        }
    }

    /// When ON, Daisy behaves as a focused menu-bar app (à la Wispr
    /// Flow): the big main window does NOT auto-open at launch, and the
    /// app runs with `.accessory` activation policy (no Dock icon, no
    /// Cmd+Tab entry). Daisy lives entirely in the menu-bar popover +
    /// the floating petal widget. The popover's "More" menu still offers
    /// "Open Library…" / "Settings…" (which raise the main window) and
    /// "Quit Daisy", so the user is never stranded — and clicking a Dock
    /// re-add or any reopen flips the policy back to `.regular`.
    ///
    /// Default OFF — behaviour is then byte-for-byte the historical
    /// regular-app experience (Dock icon, main window opens on launch and
    /// on Dock click). The activation-policy swap is applied live on
    /// toggle (no relaunch needed) via the MainView wiring modifier; the
    /// launch-time decision lives in
    /// `DaisyAppDelegate.applicationDidFinishLaunching`.
    var compactMenuBarOnly: Bool {
        didSet { defaults.set(compactMenuBarOnly, forKey: Self.k_compactMenuBarOnly) }
    }

    /// When true, Daisy hides its in-app "the other side isn't being
    /// captured" warning (the system-audio status pill). The macOS
    /// permission prompt still fires when the user records a meeting —
    /// this only mutes Daisy's own reminder. Toggled in Settings →
    /// Permissions → "For meeting recording" → "Don't remind me".
    var suppressMeetingPermissionReminders: Bool {
        didSet { defaults.set(suppressMeetingPermissionReminders, forKey: Self.k_suppressMeetingPermissionReminders) }
    }

    /// Whether the first-run welcome sheet has been dismissed at
    /// least once. We show it on first launch (and on a clean
    /// install with no other Daisy data) to anchor the user on
    /// where the important Settings live — provider setup, Notion,
    /// activation triggers. Default false; flipped to true the
    /// moment the user closes the sheet.
    var hasShownFirstRun: Bool {
        didSet { defaults.set(hasShownFirstRun, forKey: Self.k_hasShownFirstRun) }
    }

    /// One-shot interface-language fallback for Belarusian systems.
    /// Called from DaisyApp.init, before the first localized string is
    /// resolved, so it takes effect in the same launch. Daisy has no
    /// `be` localization and macOS's fallback for a be-first preferred
    /// list is English — Russian is almost certainly the lesser evil
    /// there. This is the ONLY rule layered on top of the system
    /// choice: everyone else gets whatever macOS picks from their
    /// preferred languages. Region is deliberately not consulted —
    /// region ≠ language, and a user in RU running an English system
    /// wants English.
    ///
    /// Gated on the first-run flag (a rule for fresh installs, not a
    /// standing correction) and on the absence of an explicit override
    /// from Settings → Language, whose keys it shares — so once it has
    /// run, or once the user has chosen anything themselves, it never
    /// fires again.
    static func applyBelarusianLanguageFallbackIfNeeded(
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: k_hasShownFirstRun),
              defaults.object(forKey: "AppleLanguagesOverridden") == nil,
              let primary = Locale.preferredLanguages.first,
              Locale(identifier: primary).language.languageCode?.identifier == "be"
        else { return }
        defaults.set(["ru"], forKey: "AppleLanguages")
        defaults.set(true, forKey: "AppleLanguagesOverridden")
    }

    /// Set the first time a user opens a meeting session whose
    /// `daisy_system_audio_status` is `empty` and reads the
    /// acoustic-loopback explainer banner in SessionDetailView. After
    /// that, the banner stops appearing on subsequent empty-audio
    /// sessions — the user has been told once, no need to repeat the
    /// same paragraph every time they open one. Pre-1.0.6.12 the
    /// banner showed unconditionally on every affected session, which
    /// for a tester whose mac happens to trip the macOS 26 SCStream
    /// regression meant a wall of identical orange explainers across
    /// 50+ retroactive sessions after the 1.0.6.11 update.
    var hasSeenAcousticLoopbackExplainer: Bool {
        didSet {
            defaults.set(hasSeenAcousticLoopbackExplainer,
                         forKey: Self.k_hasSeenAcousticLoopbackExplainer)
        }
    }

    /// When ON, finishing a session (Stop & save → summary done)
    /// automatically pushes it to Notion using the credentials in
    /// the same tab. Default OFF — opt-in because the first time
    /// a user records they probably don't want a half-tested
    /// integration writing into their workspace. Honoured only if
    /// `hasNotionCredentials` is true at the moment the session
    /// completes — otherwise silently skipped.
    var autoSendNotion: Bool {
        didSet { defaults.set(autoSendNotion, forKey: Self.k_autoSendNotion) }
    }

    /// Timestamp of the last successful Notion Test connection
    /// probe. Drives the UI gate that lets the user flip
    /// `autoSendNotion` ON — without a passing test we can't be sure
    /// the credentials work, the parent type is right, and the
    /// title column is named "Name" (for databases). Auto-send
    /// without a confirmed test would silently fail every session.
    /// `nil` (or .distantPast) means never tested.
    var lastNotionTestPassedAt: Date? {
        didSet {
            if let date = lastNotionTestPassedAt {
                defaults.set(date.timeIntervalSince1970, forKey: Self.k_lastNotionTestPassedAt)
            } else {
                defaults.removeObject(forKey: Self.k_lastNotionTestPassedAt)
            }
        }
    }

    /// Identifier for the user's preferred "default" destination —
    /// the one that fires when they click `Send to` in History
    /// without expanding the dropdown.
    ///
    /// Wire format:
    ///   • `""` — no default; Send-to always opens the menu
    ///     (legacy behaviour for users who didn't set one).
    ///   • `"notion"` — first-party REST connector.
    ///   • Any other string — the `MCPIntegration.id.uuidString`
    ///     of a configured MCP integration.
    ///
    /// Resolution is lazy at click time; if the saved ID points
    /// at a deleted / disabled integration we silently fall back
    /// to opening the menu.
    var defaultDestinationID: String {
        didSet { defaults.set(defaultDestinationID, forKey: Self.k_defaultDestinationID) }
    }

    /// Whether the Notion parent ID points at a page (the default,
    /// historical behaviour — Daisy creates the session as a child
    /// page under it) or at a database (Daisy creates the session
    /// as a database row, with title property "Name"). Stored as a
    /// string for forward compatibility with possible future kinds.
    var notionParentKind: String {
        didSet {
            defaults.set(notionParentKind, forKey: Self.k_notionParentKind)
            if notionParentKind != oldValue { lastNotionTestPassedAt = nil }
        }
    }

    /// Folder slugs that Notion auto-send applies to. Empty = all
    /// folders (the simple case). Non-empty restricts auto-send to
    /// just those folders — useful when you record Notes-style
    /// sessions you don't want pushed to a Notion team page.
    /// Manual Send-to from the kebab ignores this filter.
    var autoSendNotionFolders: Set<String> {
        didSet {
            if let data = try? JSONEncoder().encode(autoSendNotionFolders) {
                defaults.set(data, forKey: Self.k_autoSendNotionFolders)
            }
        }
    }

    /// When ON, Daisy auto-starts at the moment a calendar event with
    /// a detected meeting URL begins. Covers browser-based meetings
    /// (Google Meet in Chrome) that the NSWorkspace-based detector
    /// can't see. Requires calendar permission.
    var autoStartFromCalendar: Bool {
        didSet { defaults.set(autoStartFromCalendar, forKey: Self.k_autoStartFromCalendar) }
    }

    /// User has approved calendar reading. We persist a hint so the
    /// UI can show "permission granted" without re-querying TCC.
    /// EventKit itself is the source of truth.
    var calendarAccessGranted: Bool {
        didSet { defaults.set(calendarAccessGranted, forKey: Self.k_calendarAccessGranted) }
    }

    /// Whether the floating Daisy widget (the petal mark) appears on
    /// top of other windows during recording / paused / summarizing.
    /// ON by default — the widget is the always-visible affordance
    /// for pause / resume / stop without having to find the menu bar
    /// or main window. Users who don't want it can flip it off in
    /// Settings → Capture.
    var floatingWidgetEnabled: Bool {
        didSet { defaults.set(floatingWidgetEnabled, forKey: Self.k_floatingWidgetEnabled) }
    }

    /// Deadline for a manual "Hide for…" suspension of the floating
    /// widget, set from the widget's right-click menu. Persisted (as
    /// epoch seconds; nil = no suspension) so the hide survives an app
    /// relaunch — it used to live only in FloatingPanelController's
    /// memory, so quitting Daisy forgot it and the widget reappeared
    /// well before the chosen window elapsed.
    var floatingWidgetSuspendedUntil: Date? {
        didSet {
            if let until = floatingWidgetSuspendedUntil {
                defaults.set(until.timeIntervalSince1970, forKey: Self.k_floatingWidgetSuspendedUntil)
            } else {
                defaults.removeObject(forKey: Self.k_floatingWidgetSuspendedUntil)
            }
        }
    }

    /// When ON and the current session is bound to a calendar event,
    /// Daisy schedules an auto-stop at `meeting.endDate + grace`.
    /// A cancellable warning toast lets the user keep the session
    /// going past the calendar end if the conversation runs over.
    var autoStopFromCalendar: Bool {
        didSet { defaults.set(autoStopFromCalendar, forKey: Self.k_autoStopFromCalendar) }
    }

    /// Auto-stop grace period, in seconds. Two roles, one number:
    ///
    ///   1. **Earliest-stop offset** — the silence-gated auto-stop
    ///      (`RecordingSession.evaluateAutoStop`) won't even consider
    ///      stopping until `meeting.endDate + autoStopGraceSec`, and
    ///      then only after a further quiet stretch. So this is the
    ///      "wrap up, say goodbye, hop off" tail past a calendar event.
    ///   2. **Rejoin / merge window** (Talat's "grace period") — if you
    ///      leave a call and rejoin within this window the conversation
    ///      keeps flowing, so the silence gate never trips and the two
    ///      back-to-back stretches are captured as ONE recording rather
    ///      than two. Because the gate is silence-driven (not a fixed
    ///      timer), a longer grace simply widens the rejoin tolerance;
    ///      it does not, by itself, force a stop.
    ///
    /// Default 300 = 5 min. Talat exposes values as low as 1s, but for
    /// Daisy that's unsafe: with a 1s grace a 2-second pause to switch
    /// speakers could clip the tail of a live meeting, and the #48
    /// premature-stop class of bug lives exactly here. 5 min is the
    /// conservative default that covers a normal hop-off without risking
    /// a mid-meeting cut; the picker still offers shorter values for
    /// users who want them.
    var autoStopGraceSec: Int {
        didSet { defaults.set(autoStopGraceSec, forKey: Self.k_autoStopGraceSec) }
    }

    /// Prompt-before-stopping variant of the calendar auto-stop. When
    /// ON (and `autoStopFromCalendar` is on), the silence-gated
    /// evaluator ASKS instead of stopping on its own: a macOS banner
    /// ("Meeting seems over") with Stop & save / 10 more minutes /
    /// 30 more minutes actions, plus a matching in-app action toast.
    /// OFF (default) keeps the original behaviour — a 30 s "Keep
    /// going" warning toast, then an automatic stop & save.
    var autoStopPromptMode: Bool {
        didSet { defaults.set(autoStopPromptMode, forKey: Self.k_autoStopPromptMode) }
    }

    // ─── MCP server (Phase 6a) ────────────────────────────────────────
    //
    // Daisy can expose its sessions to external AI clients (Claude
    // Desktop, Claude Code, Cowork, Cursor, …) via the Model Context
    // Protocol. Transport: HTTP + SSE on a loopback port — nothing
    // ever leaves the Mac. Opt-in.

    /// Whether the local MCP server is running.
    var mcpServerEnabled: Bool {
        didSet { defaults.set(mcpServerEnabled, forKey: Self.k_mcpServerEnabled) }
    }

    /// Loopback TCP port the MCP server binds to. Default 54321;
    /// user can change it if there's a conflict.
    var mcpServerPort: Int {
        didSet { defaults.set(mcpServerPort, forKey: Self.k_mcpServerPort) }
    }

    // ─── MCP summarizer (Phase 6b) ────────────────────────────────────
    //
    // Daisy can ALSO be an MCP client — used by the .mcp provider
    // to call a user-configured local LLM wrapper. Independent from
    // the server above; same protocol, opposite direction.

    /// Base URL of the MCP server that wraps the local LLM.
    /// Empty string means unconfigured.
    var mcpSummarizerURL: String {
        didSet { defaults.set(mcpSummarizerURL, forKey: Self.k_mcpSummarizerURL) }
    }

    /// Tool name to call on that server.
    var mcpSummarizerToolName: String {
        didSet { defaults.set(mcpSummarizerToolName, forKey: Self.k_mcpSummarizerToolName) }
    }

    /// JSON template for the tool's `arguments` field. Supports
    /// `{{system}}` / `{{transcript}}` / `{{title}}` placeholders
    /// which Daisy substitutes before sending.
    var mcpSummarizerArgumentsTemplate: String {
        didSet { defaults.set(mcpSummarizerArgumentsTemplate, forKey: Self.k_mcpSummarizerArgsTemplate) }
    }

    // Secret prefs — mirrored in Keychain, exposed read/write here for the
    // settings view. Read-through on access, write-through on assignment.
    //
    // Keychain failures are rare but real (locked keychain, sandbox
    // misconfig). Swallowing them silently meant a user could paste a
    // key, see no error, and discover later that it never persisted.
    // Now they get a toast.
    var notionToken: String {
        didSet {
            Self.persist(notionToken, account: SecretKey.notionToken, label: String(localized: "Notion token"))
            // New token → old test result no longer reflects this
            // configuration. Force a re-test before auto-send can
            // be re-enabled.
            if notionToken != oldValue { lastNotionTestPassedAt = nil }
        }
    }
    var notionParentID: String {
        didSet {
            Self.persist(notionParentID, account: SecretKey.notionParentID, label: String(localized: "Notion parent ID"))
            if notionParentID != oldValue { lastNotionTestPassedAt = nil }
        }
    }
    var anthropicAPIKey: String {
        didSet {
            Self.persist(anthropicAPIKey, account: SecretKey.anthropicAPIKey, label: String(localized: "Anthropic API key"))
            Task { @MainActor in await Summarizer.shared.refreshAvailability() }
        }
    }
    var openaiAPIKey: String {
        didSet {
            Self.persist(openaiAPIKey, account: SecretKey.openaiAPIKey, label: String(localized: "OpenAI API key"))
            Task { @MainActor in await Summarizer.shared.refreshAvailability() }
        }
    }
    var cursorAPIKey: String {
        didSet {
            Self.persist(cursorAPIKey, account: SecretKey.cursorAPIKey, label: String(localized: "Cursor API key"))
            Task { @MainActor in await Summarizer.shared.refreshAvailability() }
        }
    }
    var kimiAPIKey: String {
        didSet {
            Self.persist(kimiAPIKey, account: SecretKey.kimiAPIKey, label: String(localized: "Kimi API key"))
            Task { @MainActor in await Summarizer.shared.refreshAvailability() }
        }
    }

    @MainActor
    private static func persist(_ value: String, account: String, label: String) {
        do {
            try KeychainStore.set(value, account: account)
        } catch {
            Self.log.error("Keychain write failed for \(label, privacy: .public): \(error.localizedDescription, privacy: .public)")
            ToastCenter.shared.show(String(localized: "Couldn’t save \(label) — try again."), style: .error)
        }
    }

    /// Project `autoStartPolicy` onto the three substrate flags the
    /// detection plumbing actually reads. Kept as a single method so
    /// the init-time derivation and the runtime `didSet` can't drift.
    /// Assigning the bools fires THEIR `didSet` (persistence) and, at
    /// runtime, the MainView `.onChange(of:)` re-wiring — exactly the
    /// path the old two-toggle UI used, so no extra wiring is needed.
    private func applyAutoStartPolicyToSubstrate() {
        switch autoStartPolicy {
        case .always:
            if autoStartOnMeeting != true { autoStartOnMeeting = true }
            if autoStartFromCalendar != true { autoStartFromCalendar = true }
            if autoStartPromptMode != false { autoStartPromptMode = false }
        case .selective:
            // Calendar-synced meetings only — app-launch detector off.
            if autoStartOnMeeting != false { autoStartOnMeeting = false }
            if autoStartFromCalendar != true { autoStartFromCalendar = true }
            if autoStartPromptMode != false { autoStartPromptMode = false }
        case .prompt:
            // Both detectors armed, but they ask before recording.
            if autoStartOnMeeting != true { autoStartOnMeeting = true }
            if autoStartFromCalendar != true { autoStartFromCalendar = true }
            if autoStartPromptMode != true { autoStartPromptMode = true }
        case .manual:
            if autoStartOnMeeting != false { autoStartOnMeeting = false }
            if autoStartFromCalendar != false { autoStartFromCalendar = false }
            if autoStartPromptMode != false { autoStartPromptMode = false }
        }
    }

    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "AppSettings")

    private let defaults = UserDefaults.standard

    init() {
        // Default ON: a meeting capture app capturing only the mic
        // misses half the conversation. macOS permission prompt
        // fires lazily on first record, so the cost of `true` here
        // is zero until the user actually starts recording.
        self.captureSystemAudio = defaults.object(forKey: Self.k_captureSystemAudio) as? Bool ?? true
        self.selectedMicDeviceUID = defaults.string(forKey: Self.k_selectedMicDeviceUID) ?? ""
        self.microphoneNoiseSuppressionEnabled = defaults.bool(
            forKey: Self.k_microphoneNoiseSuppressionEnabled
        )
        self.screenshotsEnabled = defaults.bool(forKey: Self.k_screenshotsEnabled)
        let interval = defaults.integer(forKey: Self.k_screenshotInterval)
        self.screenshotIntervalSec = interval > 0 ? interval : 60
        // Default ON — matches what shipped before the switch existed.
        self.screenTextInSummary = defaults.object(forKey: Self.k_screenTextInSummary) as? Bool ?? true
        // Default OFF — named-entity detection can make mistakes, so this
        // remains an explicit user choice until its EN/RU evaluation is done.
        self.protectSensitiveDataBeforeCloudAI = defaults.bool(
            forKey: Self.k_protectSensitiveDataBeforeCloudAI
        )
        // Default OFF — opt-in, and reading Voice Memos needs Full Disk Access.
        self.ingestVoiceMemos = defaults.bool(forKey: Self.k_ingestVoiceMemos)
        // Default OFF — when the user hasn't picked a summarizer
        // provider yet (no Anthropic / OpenAI key, no MCP server,
        // Apple Intelligence not detected) auto-summarize would
        // either silently no-op or — worse — fire a request against
        // a half-configured cloud account. Off-by-default keeps the
        // first-time experience honest; the user flips it on once
        // they've set up a provider.
        // Resolved into a LOCAL first: `summaryTiming` below derives from
        // it, and reading `self.autoSummarize` back before every stored
        // property is initialized is illegal in an initializer.
        let resolvedAutoSummarize: Bool
        if let storedAutoSummarize = defaults.object(forKey: Self.k_autoSummarize) as? Bool {
            resolvedAutoSummarize = storedAutoSummarize
        } else if !defaults.bool(forKey: Self.k_hasShownFirstRun), #available(macOS 26.0, *) {
            // Fresh install on macOS 26: the default provider is Apple
            // Intelligence — local and key-free — so the first recording
            // should end in a summary, not a bare transcript. The
            // half-configured-cloud concern above doesn't apply.
            // Existing installs keep their opt-in.
            resolvedAutoSummarize = true
        } else {
            resolvedAutoSummarize = false
        }
        self.autoSummarize = resolvedAutoSummarize
        // ─── Why these defaults are WRITTEN, not just resolved ───────
        // A fresh-install default derived from `!hasShownFirstRun` is
        // only true for one launch: first-run completes, sets that flag,
        // and the next launch takes the "existing install" branch — so
        // whatever the person never touched by hand silently reverts.
        // And because these are stored properties assigned inside
        // `init`, `didSet` does NOT fire, so nothing reached disk on its
        // own. Audit 2026-09-01 found three settings decaying this way:
        // auto-summary, the dictation hotkey (Fn → none, i.e. dictation
        // stops working on day two) and audio retention. Writing the
        // resolved value the first time freezes the decision instead.
        if defaults.object(forKey: Self.k_autoSummarize) == nil {
            defaults.set(resolvedAutoSummarize, forKey: Self.k_autoSummarize)
        }
        // Derived from the substrate on first read: an existing install
        // that had summaries on means "after each meeting", off means
        // "manually". Nobody is moved onto the scheduler without asking.
        if let stored = defaults.string(forKey: Self.k_summaryTiming),
           let timing = SummaryTiming(rawValue: stored) {
            self.summaryTiming = timing
            self.didLoadStoredSummaryTiming = true
        } else {
            let resolvedTiming: SummaryTiming = resolvedAutoSummarize ? .afterEachMeeting : .manual
            self.summaryTiming = resolvedTiming
            defaults.set(resolvedTiming.rawValue, forKey: Self.k_summaryTiming)
        }
        let storedHour = defaults.object(forKey: Self.k_endOfDaySummaryHour) as? Int
        // 20:00: late enough that the day's meetings are done, early
        // enough that the Mac is plausibly still awake.
        self.endOfDaySummaryHour = (storedHour.map { (0...23).contains($0) ? $0 : 20 }) ?? 20
        // Work-hours analytics is opt-in. 09:00–18:00 is only the picker
        // seed; it is never used to label time as after-hours until the
        // toggle is explicitly enabled.
        self.workingHoursEnabled = defaults.bool(forKey: Self.k_workingHoursEnabled)
        let storedWorkStart = defaults.object(forKey: Self.k_workingDayStartMinutes) as? Int
        let storedWorkEnd = defaults.object(forKey: Self.k_workingDayEndMinutes) as? Int
        let resolvedWorkStart = min(max(storedWorkStart ?? 9 * 60, 0), 22 * 60 + 30)
        let candidateWorkEnd = min(max(storedWorkEnd ?? 18 * 60, 30), 24 * 60)
        let resolvedWorkEnd = candidateWorkEnd > resolvedWorkStart
            ? candidateWorkEnd
            : min(resolvedWorkStart + 8 * 60, 24 * 60)
        self.workingDayStartMinutes = resolvedWorkStart
        self.workingDayEndMinutes = resolvedWorkEnd
        // Default OFF — opt-in; a cloud provider also needs a per-meeting
        // consent tap (see PreMeetingBriefStore).
        self.preMeetingBriefEnabled = defaults.object(forKey: Self.k_preMeetingBriefEnabled) as? Bool ?? false
        // Default OFF — opt-in network use.
        self.preMeetingBriefResearchOnline = defaults.bool(forKey: Self.k_preMeetingBriefResearchOnline)
        // Transcript second pass: default ON. The runtime gate keeps it
        // to providers the transcript already goes to. See the property
        // doc for what it adds to the prompt on the cloud path.
        self.transcriptSecondPass = defaults.object(forKey: Self.k_transcriptSecondPass) as? Bool ?? true
        // Morning brief: card ON (content-gated), notification OFF, 09:00.
        self.morningBriefEnabled = defaults.object(forKey: Self.k_morningBriefEnabled) as? Bool ?? true
        self.morningBriefNotifyEnabled = defaults.bool(forKey: Self.k_morningBriefNotifyEnabled)
        let notifyMinutes = defaults.integer(forKey: Self.k_morningBriefNotifyMinutes)
        self.morningBriefNotifyMinutes = notifyMinutes > 0 ? notifyMinutes : 9 * 60
        self.summaryLanguage = defaults.string(forKey: Self.k_summaryLanguage) ?? SummaryLanguage.auto.id
        self.defaultTranscriptionLocale = defaults.string(forKey: Self.k_defaultTranscriptionLocale) ?? "auto"
        // Per-mode overrides — empty string means "inherit from
        // defaultTranscriptionLocale". Users opt into language-
        // pinned dictation/voice-note explicitly.
        self.voiceNoteLocale = defaults.string(forKey: Self.k_voiceNoteLocale) ?? ""
        self.defaultMeetingFolderSlug = defaults.string(forKey: Self.k_defaultMeetingFolderSlug) ?? SessionFolder.work.slug
        self.dictationLocale = defaults.string(forKey: Self.k_dictationLocale) ?? ""
        // Dictation engine: read the new enum key; if absent, migrate
        // once from the legacy `dictationUseParakeet` bool (true→Parakeet,
        // else Whisper). New installs default to Whisper.
        if let raw = defaults.string(forKey: Self.k_dictationEngine),
           let engine = DictationEngine(rawValue: raw) {
            self.dictationEngine = engine
        } else {
            self.dictationEngine = defaults.bool(forKey: Self.k_dictationUseParakeet) ? .parakeet : .whisper
        }
        // Defaults to false (Whisper live preview) when the key is absent.
        self.dictationUseNemotronLive = defaults.bool(forKey: Self.k_dictationUseNemotronLive)
        // Opt-in voice-polish of dictation. Default OFF.
        self.polishDictationInMyVoice = defaults.bool(forKey: Self.k_polishDictationInMyVoice)
        self.fixBrandNamesInDictation = defaults.object(forKey: BrandCorrections.defaultsKey) as? Bool ?? true
        // Decode HotkeyChoice from UserDefaults JSON. Fall back to
        // ⌃⌥⌘R default if missing/corrupt. (Old enum-based string
        // values from pre-v1.1 installs are now invalid and will
        // silently fall back.)
        if let data = defaults.data(forKey: Self.k_recordHotkey),
           let decoded = try? JSONDecoder().decode(HotkeyChoice.self, from: data) {
            self.recordHotkey = decoded
        } else {
            self.recordHotkey = .ctrlOptCmdR
        }
        // Voice-note + dictation hotkeys default to `.none` so users
        // who don't know they exist don't get unexpected behaviour.
        // Users opt in by picking a binding in Settings → Connections.
        if let data = defaults.data(forKey: Self.k_voiceNoteHotkey),
           let decoded = try? JSONDecoder().decode(HotkeyChoice.self, from: data) {
            self.voiceNoteHotkey = decoded
        } else {
            self.voiceNoteHotkey = .none
        }
        if let data = defaults.data(forKey: Self.k_dictationHotkey),
           let decoded = try? JSONDecoder().decode(HotkeyChoice.self, from: data) {
            self.dictationHotkey = decoded
        } else if !defaults.bool(forKey: Self.k_hasShownFirstRun) {
            // Fresh install: dictation alive out of the box — Fn/globe,
            // the key Wispr-switchers already hold to talk. Existing
            // installs keep .none: gaining a global hotkey in an update
            // would be a surprise. Registration is deferred until
            // first-run completes (see ServiceWiring) so the Input
            // Monitoring prompt lands after the Hotkeys step, not at
            // first launch.
            //
            // Written to disk immediately — see the note above
            // `k_autoSummarize`. Without it the Fn binding survives
            // exactly one launch: first-run sets `hasShownFirstRun`, and
            // the next launch falls into `.none` below, so dictation
            // stops responding on day two for anyone who never opened
            // the hotkey picker.
            self.dictationHotkey = .fn
            if let encoded = try? JSONEncoder().encode(HotkeyChoice.fn) {
                defaults.set(encoded, forKey: Self.k_dictationHotkey)
            }
        } else {
            self.dictationHotkey = .none
        }
        // Rewrite-selection hotkey — same opt-in default as the others.
        if let data = defaults.data(forKey: Self.k_rewriteSelectionHotkey),
           let decoded = try? JSONDecoder().decode(HotkeyChoice.self, from: data) {
            self.rewriteSelectionHotkey = decoded
        } else {
            self.rewriteSelectionHotkey = .none
        }
        self.followUpsInMyVoice = defaults.bool(forKey: Self.k_followUpsInMyVoice)
        // Layout fixer — same opt-in default as the other hotkeys, and
        // the automatic mode is opt-in on top of that.
        if let data = defaults.data(forKey: Self.k_layoutFixHotkey),
           let decoded = try? JSONDecoder().decode(HotkeyChoice.self, from: data) {
            self.layoutFixHotkey = decoded
        } else {
            self.layoutFixHotkey = .none
        }
        self.screenshotNotesEnabled = defaults.bool(forKey: Self.k_screenshotNotesEnabled)
        // Re-paste last dictation — opt-in like every other hotkey.
        if let data = defaults.data(forKey: Self.k_repasteLastHotkey),
           let decoded = try? JSONDecoder().decode(HotkeyChoice.self, from: data) {
            self.repasteLastHotkey = decoded
        } else {
            self.repasteLastHotkey = .none
        }
        // Mark-a-moment — opt-in like every other hotkey. No preset is
        // safe to claim by default on a machine we don't own.
        if let data = defaults.data(forKey: Self.k_markMomentHotkey),
           let decoded = try? JSONDecoder().decode(HotkeyChoice.self, from: data) {
            self.markMomentHotkey = decoded
        } else {
            self.markMomentHotkey = .none
        }
        self.layoutFixAuto = defaults.bool(forKey: Self.k_layoutFixAuto)
        self.layoutFixSwitchesSource = defaults.object(forKey: Self.k_layoutFixSwitchesSource) as? Bool ?? true
        // Default OFF — auto-starting a recording the moment Zoom
        // / Teams / Telegram opens is surprising on first install
        // ("Daisy started recording a personal call I made
        // immediately after installing it"). It's a powerful
        // feature but needs opt-in. Users who want the headline
        // "Daisy captures every meeting" workflow flip it on in
        // Settings → Capture → Activation.
        // Capture into a local too: the auto-start POLICY derivation
        // below needs this value, but it runs before `self` is fully
        // initialized (Swift phase 1), where reading `self.autoStart…`
        // is illegal. Derive from the local instead.
        let loadedAutoStartOnMeeting = defaults.object(forKey: Self.k_autoStartOnMeeting) as? Bool ?? false
        self.autoStartOnMeeting = loadedAutoStartOnMeeting
        self.showSessionAfterStop = defaults.object(forKey: Self.k_showSessionAfterStop) as? Bool ?? false
        // Default ON — the prompt is the only safeguard against a
        // session left running for hours by accident. Users who
        // find it noisy can flip it off here.
        self.silencePromptsEnabled = defaults.object(forKey: Self.k_silencePromptsEnabled) as? Bool ?? true
        self.notifyOnAutoStart = defaults.object(forKey: Self.k_notifyOnAutoStart) as? Bool ?? true
        self.notifyOnAutoStop = defaults.object(forKey: Self.k_notifyOnAutoStop) as? Bool ?? true
        self.diarizeMicrophone = defaults.object(forKey: Self.k_diarizeMicrophone) as? Bool ?? false
        // Default ON. `defaults.object(forKey:) as? Bool ?? true`
        // pattern so fresh installs get live transcription on (the
        // historical behaviour) but the user's explicit OFF survives
        // across launches.
        // Live transcription tier (Full/Lite/Off). Migrates the pre-tier
        // binary toggle: a saved tier wins; else the old on/off bool maps
        // on→Lite (the new lighter default) / off→Off; else fresh install
        // defaults to Lite. The final pass on Stop is full quality at any
        // tier, so Lite only affects the throwaway live preview.
        if let raw = defaults.string(forKey: Self.k_liveTranscriptionTier),
           let tier = LiveTranscriptionTier(rawValue: raw) {
            self.liveTranscriptionTier = tier
        } else if let oldBool = defaults.object(forKey: Self.k_liveTranscriptionEnabled) as? Bool {
            self.liveTranscriptionTier = oldBool ? .lite : .off
        } else {
            self.liveTranscriptionTier = .lite
        }
        // 2026-05-25 — three diarization-quality settings added in
        // 1.0.7. All default ON so existing users get the new behavior
        // automatically (the changes are quality improvements, not
        // semantic shifts — diarizeRemoteSpeakers default matches the
        // prior implicit behavior; the other two are post-processing
        // passes that only run when the conditions trigger).
        self.diarizeRemoteSpeakers = defaults.object(forKey: Self.k_diarizeRemoteSpeakers) as? Bool ?? true
        self.diarizeUseAttendeeCountHint = defaults.object(forKey: Self.k_diarizeUseAttendeeCountHint) as? Bool ?? false
        self.suppressAcousticEcho = defaults.object(forKey: Self.k_suppressAcousticEcho) as? Bool ?? true
        self.globalReclusterAfterStop = defaults.object(forKey: Self.k_globalReclusterAfterStop) as? Bool ?? true
        self.userDisplayName = (defaults.string(forKey: Self.k_userDisplayName) ?? "")
        // Speaker match mode — default `.automatic` so existing users
        // (no stored value) keep the silent auto-label behaviour Daisy
        // has always had. Only an explicit user choice moves it off
        // Automatic. See `speakerMatchMode` doc for the three modes.
        if let rawMode = defaults.string(forKey: Self.k_speakerMatchMode),
           let mode = SpeakerMatchMode(rawValue: rawMode) {
            self.speakerMatchMode = mode
        } else {
            self.speakerMatchMode = .automatic
        }
        // 24-hour retention is the new default for fresh installs
        // (1.0.6.9+). Raw audio dominates Daisy's disk footprint
        // (~50-150 MB / hour) and an unbounded default bit a
        // tester whose Mac was already close to full.
        //
        // CRITICAL: existing users who never opened Settings →
        // Storage and never changed the retention picker must NOT
        // suddenly lose yesterday's audio because we flipped the
        // default — they didn't opt in. So we gate the new default
        // on `hasShownFirstRun`: false means a fresh install (no
        // first-run sheet shown yet), true means an existing
        // install that's been launched before. Anyone with an
        // explicit value in UserDefaults keeps it regardless;
        // `defaults.object(...) as? Int` returns nil only for keys
        // that were never written.
        // 2026-05-25 — fresh-install default changed from `1` (24h
        // timer sweep) to `audioRetentionDeleteAfterTranscription`
        // (-1; per-session purge after the post-stop pipeline). New
        // installs get the strongest privacy posture without losing
        // the option to keep audio; existing users who never opened
        // Settings → Storage still default to `0` (keep forever) to
        // preserve backwards-compat — they didn't opt in to any
        // purge behaviour and the upgrade shouldn't surprise-delete
        // yesterday's recordings. Anyone with an explicit value in
        // UserDefaults keeps it (storedRetention non-nil path).
        let storedRetention = defaults.object(forKey: Self.k_audioRetentionDays) as? Int
        let isFreshInstall = !defaults.bool(forKey: Self.k_hasShownFirstRun)
        let resolvedRetention = storedRetention
            ?? (isFreshInstall ? Self.audioRetentionDeleteAfterTranscription : 0)
        self.audioRetentionDays = resolvedRetention
        // Written on first resolve — see the note above `k_autoSummarize`.
        // Retention decays the other way round (delete-after-transcription
        // → keep-forever), so the leak is privacy, not data: a fresh
        // install would quietly stop honouring the strongest setting it
        // was given.
        if storedRetention == nil {
            defaults.set(resolvedRetention, forKey: Self.k_audioRetentionDays)
        }
        self.recordingSoundsEnabled = defaults.object(forKey: Self.k_recordingSoundsEnabled) as? Bool ?? true
        self.menuBarShowsNextMeeting = defaults.object(forKey: Self.k_menuBarShowsNextMeeting) as? Bool ?? false
        self.appAppearance = AppearancePreference.stored(in: defaults)
        // Default OFF — `defaults.bool(forKey:)` returns false for unset
        // keys, so a fresh install gets the historical regular-app
        // behaviour (Dock icon + main window on launch). Only an explicit
        // user opt-in moves it to the menu-bar-only experience.
        self.compactMenuBarOnly = defaults.bool(forKey: Self.k_compactMenuBarOnly)
        self.suppressMeetingPermissionReminders = defaults.bool(forKey: Self.k_suppressMeetingPermissionReminders)
        self.hasShownFirstRun = defaults.bool(forKey: Self.k_hasShownFirstRun)
        self.hasSeenAcousticLoopbackExplainer =
            defaults.bool(forKey: Self.k_hasSeenAcousticLoopbackExplainer)
        self.autoSendNotion = defaults.object(forKey: Self.k_autoSendNotion) as? Bool ?? false
        let lastTs = defaults.double(forKey: Self.k_lastNotionTestPassedAt)
        self.lastNotionTestPassedAt = lastTs > 0 ? Date(timeIntervalSince1970: lastTs) : nil
        self.defaultDestinationID = defaults.string(forKey: Self.k_defaultDestinationID) ?? ""
        self.notionParentKind = defaults.string(forKey: Self.k_notionParentKind) ?? "page"
        if let data = defaults.data(forKey: Self.k_autoSendNotionFolders),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            self.autoSendNotionFolders = decoded
        } else {
            self.autoSendNotionFolders = []
        }
        // Local copy for the policy derivation below (same phase-1
        // reason as `loadedAutoStartOnMeeting`).
        let loadedAutoStartFromCalendar = defaults.object(forKey: Self.k_autoStartFromCalendar) as? Bool ?? false
        self.autoStartFromCalendar = loadedAutoStartFromCalendar
        self.calendarAccessGranted = defaults.bool(forKey: Self.k_calendarAccessGranted)
        // Auto-start policy (1.0.7.9). The two legacy bools above are
        // now derived outputs of this. Migration so existing users see
        // ZERO behavioural change:
        //   • A previously-saved policy wins (user already moved to the
        //     new control).
        //   • Otherwise derive from the legacy bools that were just
        //     loaded — whatever the old two-toggle UI left us:
        //        app-launch ON, calendar ON  → .always
        //        app-launch OFF, calendar ON → .selective
        //        app-launch ON, calendar OFF → .always (app-launch was
        //          the headline "capture every meeting" path; treat the
        //          presence of ANY auto-start as Always so we never
        //          silently DOWNGRADE a user who had a detector armed)
        //        both OFF                     → .manual (the fresh-install
        //          default, since both bools default OFF)
        // The fresh-install default is therefore .manual — identical to
        // today's clean install (both toggles off). `autoStartPromptMode`
        // had no equivalent before, so it can only come from an explicit
        // .prompt policy; default false.
        let hadStoredPolicy: Bool
        if let rawPolicy = defaults.string(forKey: Self.k_autoStartPolicy),
           let policy = AutoStartPolicy(rawValue: rawPolicy) {
            self.autoStartPolicy = policy
            hadStoredPolicy = true
        } else if loadedAutoStartOnMeeting || loadedAutoStartFromCalendar {
            // Legacy users with at least one detector armed. App-launch
            // alone (calendar off) still maps to Always rather than
            // inventing an "app-only" mode — Selective is explicitly
            // calendar-driven, so it would be the wrong label.
            // NB: read the just-loaded LOCALS, not self.* — this runs in
            // init phase 1 (not all stored properties assigned yet), so
            // reading instance properties through self is rejected.
            self.autoStartPolicy = (!loadedAutoStartOnMeeting && loadedAutoStartFromCalendar)
                ? .selective
                : .always
            hadStoredPolicy = false
        } else {
            self.autoStartPolicy = .manual
            hadStoredPolicy = false
        }
        self.didLoadStoredAutoStartPolicy = hadStoredPolicy
        self.autoStartPromptMode = defaults.object(forKey: Self.k_autoStartPromptMode) as? Bool ?? false
        // Default ON: `object(forKey:)` returns nil for unset keys, so
        // `as? Bool ?? true` picks up explicit user choices (true OR
        // false) and falls through to true only on a clean install.
        self.floatingWidgetEnabled = defaults.object(forKey: Self.k_floatingWidgetEnabled) as? Bool ?? true
        // Restore a still-pending "Hide for…" deadline. Stored as epoch
        // seconds; absent/≤0 means no active suspension. FloatingPanel-
        // Controller re-arms the expiry timer from this on launch so a
        // hide chosen before quitting still lifts at its original time.
        if let suspendTS = defaults.object(forKey: Self.k_floatingWidgetSuspendedUntil) as? Double, suspendTS > 0 {
            self.floatingWidgetSuspendedUntil = Date(timeIntervalSince1970: suspendTS)
        } else {
            self.floatingWidgetSuspendedUntil = nil
        }
        // Default ON. `defaults.bool(forKey:)` returns false for unset
        // keys, which meant a clean-install user never had calendar
        // auto-stop armed — combined with the "back-to-back meetings
        // bleed into one session" bug (fixed in RecordingSession.
        // startFromMeeting), that produced the failure mode where
        // M1 + M2 collapsed into a single 75-min recording with one
        // title. `object(forKey:) as? Bool ?? true` preserves an
        // explicit user-off choice while defaulting fresh installs
        // to the safer behaviour.
        self.autoStopFromCalendar = defaults.object(forKey: Self.k_autoStopFromCalendar) as? Bool ?? true
        let storedGrace = defaults.integer(forKey: Self.k_autoStopGraceSec)
        self.autoStopGraceSec = storedGrace > 0 ? storedGrace : 300
        // Default OFF — asking is the opt-in variant; the silent
        // auto-stop with its cancellable warning toast stays the
        // default. `bool(forKey:)` returns false for unset keys.
        self.autoStopPromptMode = defaults.bool(forKey: Self.k_autoStopPromptMode)
        self.mcpServerEnabled = defaults.bool(forKey: Self.k_mcpServerEnabled)
        let storedPort = defaults.integer(forKey: Self.k_mcpServerPort)
        self.mcpServerPort = storedPort > 0 ? storedPort : 54321
        self.mcpSummarizerURL = defaults.string(forKey: Self.k_mcpSummarizerURL)
            ?? MCPSummarizer.defaultBaseURLString
        self.mcpSummarizerToolName = defaults.string(forKey: Self.k_mcpSummarizerToolName)
            ?? MCPSummarizer.defaultToolName
        self.mcpSummarizerArgumentsTemplate = defaults.string(forKey: Self.k_mcpSummarizerArgsTemplate)
            ?? MCPSummarizer.defaultArgumentsTemplate
        self.notionToken = KeychainStore.get(account: SecretKey.notionToken) ?? ""
        self.notionParentID = KeychainStore.get(account: SecretKey.notionParentID) ?? ""
        self.anthropicAPIKey = KeychainStore.get(account: SecretKey.anthropicAPIKey) ?? ""
        self.openaiAPIKey = KeychainStore.get(account: SecretKey.openaiAPIKey) ?? ""
        self.cursorAPIKey = KeychainStore.get(account: SecretKey.cursorAPIKey) ?? ""
        self.kimiAPIKey = KeychainStore.get(account: SecretKey.kimiAPIKey) ?? ""

        // Reconcile substrate to the policy ONCE at launch — but ONLY
        // when the policy came from an explicit stored value. `didSet`
        // doesn't fire during init, so if a previously-saved policy
        // disagrees with the stored bools (user round-tripped through an
        // older build that flipped a bool directly), the policy is
        // authoritative and we re-derive the bools from it. On the LEGACY
        // path (no stored policy) we skip this: the policy was derived
        // FROM the bools, so they already agree, and reconciling could
        // change behaviour (an app-launch-only user → .always would
        // otherwise gain calendar auto-start). Safe to run before wiring:
        // ServiceWiring.applyAll runs later in DaisyApp.init off the
        // now-consistent values.
        if didLoadStoredAutoStartPolicy {
            applyAutoStartPolicyToSubstrate()
        }
        // Same reconcile for the summary substrate, and for the same
        // reason: `didSet` doesn't fire during init, so a stored
        // `summaryTiming` could sit next to a contradictory
        // `autoSummarize` — an older build's toggle writes the Bool and
        // knows nothing about the timing key. That combination would
        // summarize inline after every Stop AND again in the evening.
        if didLoadStoredSummaryTiming,
           autoSummarize != (summaryTiming == .afterEachMeeting) {
            autoSummarize = (summaryTiming == .afterEachMeeting)
        }
    }

    var hasNotionCredentials: Bool {
        !notionToken.isEmpty && !notionParentID.isEmpty
    }

    /// Static convenience for places (Toolbar actions in
    /// SessionDetailView) that don't have AppSettings injected and
    /// just need a yes/no on Notion configuration. Reads Keychain
    /// directly to avoid singleton wiring.
    nonisolated static var notionConfigured: Bool {
        let token = KeychainStore.get(account: SecretKey.notionToken) ?? ""
        let parent = KeychainStore.get(account: SecretKey.notionParentID) ?? ""
        return !token.isEmpty && !parent.isEmpty
    }

    /// Read-only static accessor for the summary-language preference,
    /// readable from `nonisolated` contexts (e.g. SessionDetailView's
    /// `reSummarize()` which needs to feed the canonical locale
    /// resolver in `RecordingSession.resolveSummaryLocaleHint`
    /// without holding a live `AppSettings` instance). Returns "auto"
    /// if never explicitly set, matching the init() default.
    nonisolated static var currentSummaryLanguage: String {
        UserDefaults.standard.string(forKey: k_summaryLanguage) ?? "auto"
    }

    /// The language DICTATION is pinned to right now, as a two-letter
    /// code, or nil when the user is on auto-detect. Dictation's own
    /// override wins, falling back to the meeting default — the same
    /// resolution `finishDictation` does for the fast engines.
    ///
    /// Read statically because the voice-corpus store has no
    /// `AppSettings` instance: it is a singleton fed from the paste path,
    /// and a pinned language is the cheapest, most reliable answer to
    /// "which language bucket does this dictation belong in".
    nonisolated static var currentDictationLanguage: String? {
        let defaults = UserDefaults.standard
        let dictation = defaults.string(forKey: k_dictationLocale) ?? ""
        let raw = dictation.isEmpty
            ? (defaults.string(forKey: k_defaultTranscriptionLocale) ?? "auto")
            : dictation
        return VoiceCorpusClassifier.normalized(raw)
    }

    /// Read where no `AppSettings` instance is in reach — the summarizer
    /// is handed a transcript, not the settings object. Same pattern as
    /// `currentSummaryLanguage` above.
    nonisolated static var followUpsInMyVoiceEnabled: Bool {
        UserDefaults.standard.bool(forKey: k_followUpsInMyVoice)
    }

    /// Summarizer has no live AppSettings reference; read the persisted
    /// privacy switch at the provider boundary, where every request passes.
    nonisolated static var protectSensitiveDataBeforeCloudAIEnabled: Bool {
        UserDefaults.standard.bool(forKey: k_protectSensitiveDataBeforeCloudAI)
    }

    private static let k_captureSystemAudio = "daisy.captureSystemAudio"
    private static let k_selectedMicDeviceUID = "daisy.selectedMicDeviceUID"
    private static let k_microphoneNoiseSuppressionEnabled =
        "daisy.microphoneNoiseSuppressionEnabled"
    private static let k_screenshotsEnabled = "daisy.screenshotsEnabled"
    private static let k_screenshotInterval = "daisy.screenshotIntervalSec"
    private static let k_screenTextInSummary = "daisy.screenTextInSummary"
    nonisolated private static let k_protectSensitiveDataBeforeCloudAI =
        "daisy.protectSensitiveDataBeforeCloudAI"
    private static let k_summaryTiming = "daisy.summaryTiming"
    private static let k_endOfDaySummaryHour = "daisy.endOfDaySummaryHour"
    private static let k_workingHoursEnabled = "daisy.workingHoursEnabled"
    private static let k_workingDayStartMinutes = "daisy.workingDayStartMinutes"
    private static let k_workingDayEndMinutes = "daisy.workingDayEndMinutes"
    private static let k_ingestVoiceMemos = "daisy.ingestVoiceMemos"
    private static let k_autoSummarize = "daisy.autoSummarize"
    private static let k_preMeetingBriefEnabled = "daisy.preMeetingBriefEnabled"
    private static let k_morningBriefEnabled = "daisy.morningBriefEnabled"
    private static let k_morningBriefNotifyEnabled = "daisy.morningBriefNotifyEnabled"
    private static let k_morningBriefNotifyMinutes = "daisy.morningBriefNotifyMinutes"
    private static let k_preMeetingBriefResearchOnline = "daisy.preMeetingBriefResearchOnline"
    private static let k_transcriptSecondPass = "daisy.transcriptSecondPass"
    private static let k_showSessionAfterStop = "daisy.showSessionAfterStop"
    /// `nonisolated` because `currentSummaryLanguage` (above) reads
    /// this key from a nonisolated context (SessionDetailView's
    /// reSummarize() path), and Swift 6's default MainActor isolation
    /// on AppSettings would otherwise propagate to the static and
    /// emit a "main-actor isolated static can't be referenced from
    /// nonisolated context" error. The string is a plain `let` with
    /// no shared mutation — safe to read from any actor.
    nonisolated private static let k_summaryLanguage = "daisy.summaryLanguage"
    // `nonisolated` — read by `currentDictationLanguage`, which the
    // voice-corpus store calls without an AppSettings instance.
    nonisolated private static let k_defaultTranscriptionLocale = "daisy.defaultTranscriptionLocale"
    private static let k_voiceNoteLocale = "daisy.voiceNoteLocale"
    private static let k_defaultMeetingFolderSlug = "daisy.defaultMeetingFolderSlug"
    nonisolated private static let k_dictationLocale = "daisy.dictationLocale"
    private static let k_dictationUseParakeet = "daisy.dictationUseParakeet"  // legacy — read once for migration into k_dictationEngine
    private static let k_dictationEngine = "daisy.dictationEngine"
    private static let k_polishDictationInMyVoice = "daisy.polishDictationInMyVoice"
    private static let k_dictationUseNemotronLive = "daisy.dictationUseNemotronLive"
    private static let k_recordHotkey = "daisy.recordHotkey"
    private static let k_voiceNoteHotkey = "daisy.voiceNoteHotkey"
    private static let k_dictationHotkey = "daisy.dictationHotkey"
    private static let k_rewriteSelectionHotkey = "daisy.rewriteSelectionHotkey"
    nonisolated private static let k_followUpsInMyVoice = "daisy.followUpsInMyVoice"
    private static let k_layoutFixHotkey = "daisy.layoutFixHotkey"
    private static let k_markMomentHotkey = "daisy.markMomentHotkey"
    private static let k_repasteLastHotkey = "daisy.repasteLastHotkey"
    private static let k_screenshotNotesEnabled = "daisy.screenshotNotesEnabled"
    private static let k_layoutFixAuto = "daisy.layoutFixAuto"
    private static let k_layoutFixSwitchesSource = "daisy.layoutFixSwitchesSource"
    private static let k_autoStartOnMeeting = "daisy.autoStartOnMeeting"
    private static let k_autoStartPolicy = "daisy.autoStartPolicy"
    private static let k_autoStartPromptMode = "daisy.autoStartPromptMode"
    private static let k_silencePromptsEnabled = "daisy.silencePromptsEnabled"
    private static let k_notifyOnAutoStart = "daisy.notifyOnAutoStart"
    private static let k_notifyOnAutoStop = "daisy.notifyOnAutoStop"
    private static let k_diarizeMicrophone = "daisy.diarizeMicrophone"
    private static let k_liveTranscriptionEnabled = "daisy.liveTranscriptionEnabled"
    private static let k_liveTranscriptionTier = "daisy.liveTranscriptionTier"
    private static let k_diarizeRemoteSpeakers = "daisy.diarizeRemoteSpeakers"
    private static let k_diarizeUseAttendeeCountHint = "daisy.diarizeUseAttendeeCountHint"
    private static let k_suppressAcousticEcho = "daisy.suppressAcousticEcho"
    private static let k_globalReclusterAfterStop = "daisy.globalReclusterAfterStop"
    private static let k_userDisplayName = "daisy.userDisplayName"
    private static let k_speakerMatchMode = "daisy.speakerMatchMode"
    private static let k_audioRetentionDays = "daisy.audioRetentionDays"
    private static let k_recordingSoundsEnabled = "daisy.recordingSoundsEnabled"
    private static let k_menuBarShowsNextMeeting = "daisy.menuBarShowsNextMeeting"
    private static let k_compactMenuBarOnly = "daisy.compactMenuBarOnly"
    private static let k_suppressMeetingPermissionReminders = "daisy.suppressMeetingPermissionReminders"
    private static let k_hasShownFirstRun = "daisy.hasShownFirstRun"
    private static let k_hasSeenAcousticLoopbackExplainer =
        "daisy.hasSeenAcousticLoopbackExplainer"
    private static let k_autoSendNotion = "daisy.autoSendNotion"
    private static let k_lastNotionTestPassedAt = "daisy.lastNotionTestPassedAt"
    private static let k_defaultDestinationID = "daisy.defaultDestinationID"
    private static let k_notionParentKind = "daisy.notionParentKind"
    private static let k_autoSendNotionFolders = "daisy.autoSendNotionFolders"
    private static let k_autoStartFromCalendar = "daisy.autoStartFromCalendar"
    private static let k_calendarAccessGranted = "daisy.calendarAccessGranted"
    private static let k_floatingWidgetEnabled = "daisy.floatingWidgetEnabled"
    private static let k_floatingWidgetSuspendedUntil = "daisy.floatingWidgetSuspendedUntil"
    private static let k_autoStopFromCalendar = "daisy.autoStopFromCalendar"
    private static let k_autoStopGraceSec = "daisy.autoStopGraceSec"
    private static let k_autoStopPromptMode = "daisy.autoStopPromptMode"
    private static let k_mcpServerEnabled = "daisy.mcpServerEnabled"
    private static let k_mcpServerPort = "daisy.mcpServerPort"
    private static let k_mcpSummarizerURL = "daisy.mcpSummarizer.url"
    private static let k_mcpSummarizerToolName = "daisy.mcpSummarizer.toolName"
    private static let k_mcpSummarizerArgsTemplate = "daisy.mcpSummarizer.argsTemplate"
}

// MARK: - SummaryTiming

/// When Daisy runs the summarizer.
nonisolated enum SummaryTiming: String, CaseIterable, Identifiable, Sendable {
    /// Inline in the post-stop pipeline, as it always did.
    case afterEachMeeting
    /// Queued and run in one batch at a set hour — see
    /// `EndOfDaySummaries`.
    case endOfDay
    /// Only when the user asks, from a session's own Re-summarize.
    case manual

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .afterEachMeeting: return String(localized: "After each meeting")
        case .endOfDay:         return String(localized: "At the end of the day")
        case .manual:           return String(localized: "Only when I ask")
        }
    }
}

// MARK: - AutoStartPolicy

/// How aggressively Daisy auto-records detected calls. Modelled on
/// Talat's Settings → Recordings auto-start control. `rawValue` is the
/// stable string persisted in `AppSettings.autoStartPolicy`.
///
/// Detection itself (NSWorkspace app-launch + calendar-event) is
/// unchanged — the policy only decides what to DO when a call is
/// detected. See `AppSettings.autoStartPolicy` for the full mapping
/// onto the substrate flags.
enum AutoStartPolicy: String, CaseIterable, Identifiable, Sendable {
    /// Auto-record every detected call (app-launch + calendar), starting
    /// immediately and silently.
    case always
    /// Auto-record only calendar-synced meetings (events with a
    /// Zoom/Meet/Teams/Webex link). App-launch detection is suppressed.
    case selective
    /// Detect the call but ASK first (Record / Ignore banner) before
    /// recording. Applies to both detectors.
    case prompt
    /// Never auto-start — only the Record button / hotkey.
    case manual

    nonisolated var id: String { rawValue }

    /// Short label for the auto-start selector (the pop-up menu in
    /// Settings → Auto-start). Plain-language names — what Daisy records,
    /// not the internal policy word.
    nonisolated var displayName: String {
        switch self {
        case .always:    return String(localized: "All meetings")
        case .selective: return String(localized: "Meetings with a link")
        case .prompt:    return String(localized: "Ask me first")
        case .manual:    return String(localized: "Off")
        }
    }
}

// MARK: - SpeakerMatchMode

/// How aggressively Daisy applies a recognized speaker (by voice
/// fingerprint and/or calendar-attendee email) to a new recording.
/// Modelled on Talat's Settings → Speakers match control. `rawValue`
/// is the stable string persisted in `AppSettings.speakerMatchMode`.
///
/// The recognition itself (cosine match in `SpeakerProfileStore` +
/// email intersection) is unchanged across modes — the mode only
/// decides what to DO with a hit: apply it, suggest it, or ignore it.
/// See `AppSettings.speakerMatchMode` for the per-mode behaviour.
enum SpeakerMatchMode: String, CaseIterable, Identifiable, Sendable {
    /// No cross-meeting auto-match. Speakers stay Remote A/B/C until
    /// named by hand. Voice fingerprints are still persisted on manual
    /// naming so re-enabling later works.
    case off
    /// Recognize, but surface as a confirmable suggestion rather than
    /// applying it. The user approves before names enter the transcript.
    case suggest
    /// Apply the match silently (pre-fills the transcript speaker map).
    /// Daisy's behaviour in every build before 1.0.7.10 — the default.
    case automatic

    nonisolated var id: String { rawValue }

    /// Label for the segmented control.
    nonisolated var displayName: String {
        switch self {
        case .off:       return String(localized: "Off")
        case .suggest:   return String(localized: "Suggest")
        case .automatic: return String(localized: "Automatic")
        }
    }
}

// MARK: - SummaryLanguage

/// Languages the user can pin the AI summary to. Decoupled from
/// transcription locale — the transcript stays in its captured
/// language, only the summary text is shifted.
///
/// `id` is the 2-letter ISO code stored in `AppSettings.summaryLanguage`,
/// or the literal `"auto"` for "use the transcript's language".
/// Live-transcription cost tier, surfaced in Settings → Transcription.
/// `full` is the original behaviour (turbo model, 2 s cadence, full
/// decode); `lite` trims cadence + decode for a much lighter live
/// preview; `off` shows no live transcript and runs a single full pass
/// on Stop (the build-43 "deferred" path). The final transcript on Stop
/// is always full quality regardless of tier.
enum LiveTranscriptionTier: String, CaseIterable, Identifiable, Sendable {
    case full
    case lite
    case off

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .full: return String(localized: "Full")
        case .lite: return String(localized: "Lite")
        case .off:  return String(localized: "Off")
        }
    }
}

/// Engine used for the dictation final pass. See `AppSettings.dictationEngine`.
/// `.appleSpeech` is only offered on macOS 26+ (the UI hides it below that);
/// if somehow selected on an older OS or with an "auto" locale, the dictation
/// path falls back to Whisper.
enum DictationEngine: String, CaseIterable, Identifiable, Sendable {
    case whisper
    case parakeet
    case appleSpeech

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .whisper:     return String(localized: "Standard")
        case .parakeet:    return String(localized: "Faster · 600 MB")
        case .appleSpeech: return String(localized: "Apple · built-in")
        }
    }
}

/// `displayName` is what the picker shows. The order roughly mirrors
/// `Transcriber.availableLocales` so the two pickers feel related.
enum SummaryLanguage: String, CaseIterable, Identifiable, Sendable {
    case auto
    case en
    case ru
    case uk
    case pl
    case es
    case fr
    case de
    case it
    case pt
    case ja
    case ko
    case zh

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .auto: return String(localized: "Auto · same as transcript")
        case .en:   return "English"
        case .ru:   return "Русский"
        case .uk:   return "Українська"
        case .pl:   return "Polski"
        case .es:   return "Español"
        case .fr:   return "Français"
        case .de:   return "Deutsch"
        case .it:   return "Italiano"
        case .pt:   return "Português"
        case .ja:   return "日本語"
        case .ko:   return "한국어"
        case .zh:   return "中文"
        }
    }

    /// Whether Apple's on-device model can WRITE in this language.
    /// Apple Intelligence supports a fixed set (en/es/fr/de/it/pt/ja/ko/zh
    /// as of macOS 26); asking for e.g. Russian silently yields English.
    /// The Settings picker filters on this when the provider is
    /// `.appleIntelligence`, and warns if the stored choice is unsupported.
    /// `.auto` stays offered — the transcript's language may be supported.
    nonisolated var supportedByAppleIntelligence: Bool {
        switch self {
        case .auto, .en, .es, .fr, .de, .it, .pt, .ja, .ko, .zh: return true
        case .ru, .uk, .pl: return false
        }
    }
}
