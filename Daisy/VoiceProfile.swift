//
//  VoiceProfile.swift
//  Daisy
//
//  A local "voice profile" — a description of how the user writes/speaks,
//  built by analyzing a corpus of their own recent dictations through the
//  selected summary provider. Two jobs:
//    • display — a readable profile (tone, signature phrases, quirks) in
//      the Voice section, reusing the MeetingSummary outline shape;
//    • function — a compact `styleInstruction` that conditions the two
//      rewrites that apply it: a follow-up drafted as the user
//      (`FollowUpVoice`) and the rewrite-selection hotkey
//      (`SelectionRewrite`). It is NOT applied to dictation itself: the
//      profile is learned from dictations, so that would be a costly
//      identity (removed 2026-09-12, see `finishDictation`).
//
//  100% local when the provider is local. The corpus is the user's own
//  dictation history (never leaves the Mac unless a cloud provider is
//  chosen — same contract as summaries).
//
//  Multilingual since 1.0.7.64: the corpus is split into per-language
//  buckets on the way IN (`VoiceCorpus.swift`), the 300-word unlock is
//  counted per language, and a rewrite picks the profile for the language
//  of the TEXT BEING WRITTEN. Everything anyone had before that lands in
//  a universal (`language == nil`) profile that keeps working for every
//  language — nobody is asked to re-earn an unlock they already had.
//

import Foundation
import Observation
import os

/// `nonisolated` for the same reason `MeetingSummary` is: it is decoded
/// and encoded off the main actor (the corpus files), and a
/// MainActor-isolated `init(from:)` can't witness `Decodable`.
nonisolated struct VoiceProfile: Codable, Sendable, Equatable {
    let generatedAt: Date
    /// Word count of the corpus it was built from (shown as confidence).
    let sampleWords: Int
    /// Readable profile for the UI (summary + sections). Reuses
    /// MeetingSummary purely as a display container.
    let display: MeetingSummary
    /// Compact directive fed to the polish rewrite. Derived from the
    /// profile's `clientFollowUp`.
    let styleInstruction: String
    /// ISO 639-1 code this profile describes, or nil for a UNIVERSAL
    /// profile: the single pre-split profile carried over by migration,
    /// and any style prompt the user pasted in by hand (one carried over
    /// from another app has no language in any meaningful sense).
    let language: String?
    /// True when `language` was decided by the corpus rather than chosen
    /// by the user. Nothing branches on it yet; it exists so the UI can
    /// eventually say "this one predates the language split" without a
    /// second migration.
    let languageIsInferred: Bool

    init(
        generatedAt: Date,
        sampleWords: Int,
        display: MeetingSummary,
        styleInstruction: String,
        language: String?,
        languageIsInferred: Bool
    ) {
        self.generatedAt = generatedAt
        self.sampleWords = sampleWords
        self.display = display
        self.styleInstruction = styleInstruction
        self.language = language
        self.languageIsInferred = languageIsInferred
    }

    /// Hand-written so the pre-split JSON in `daisy.voiceProfile` — which
    /// has neither language field — still decodes during migration.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        sampleWords = try c.decodeIfPresent(Int.self, forKey: .sampleWords) ?? 0
        display = try c.decode(MeetingSummary.self, forKey: .display)
        styleInstruction = try c.decodeIfPresent(String.self, forKey: .styleInstruction) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language)
        languageIsInferred = try c.decodeIfPresent(Bool.self, forKey: .languageIsInferred) ?? false
    }
}

/// Provenance tag for a sample the first-run tour fed into the corpus
/// (`VoiceProfileStore.appendTourSample`). The words are in the bucket
/// like any dictation's — the tail-trim may since have dropped them, so a
/// view that highlights them checks the bucket text before pointing.
nonisolated struct VoiceTourSample: Codable, Sendable, Equatable {
    /// The bucket it landed in (ISO 639-1 or `VoiceLanguage.undetermined`).
    let language: String
    let text: String
    let words: Int
    let at: Date
}

/// A style instruction resolved for one piece of text, plus the two facts
/// the prompt needs about where it came from.
nonisolated struct ResolvedVoiceStyle: Sendable, Equatable {
    /// The profile's own directive, verbatim.
    let instruction: String
    /// Language of the profile that supplied it; nil = universal.
    let sourceLanguage: String?
    /// Language of the text about to be rewritten; nil = unknown.
    let targetLanguage: String?
    /// The profile describes a different language than the text.
    let isCrossLanguage: Bool

    /// What actually goes into `.dictationPolish`. Without the guard a
    /// Russian directive, honestly executed, drops Russian turns of
    /// phrase into English text — not "my voice" but "an AI-generated
    /// Russian accent", which is worse than no polish at all.
    var promptInstruction: String {
        guard isCrossLanguage else { return instruction }
        // English names, not ISO codes: the prompt around them is
        // English, and "in ru" is a worse instruction than "in Russian".
        func named(_ code: String?) -> String? {
            guard let code else { return nil }
            return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
        }
        let source = named(sourceLanguage).map { "in \($0)" } ?? "in another language"
        let target = named(targetLanguage).map { "in \($0)" } ?? "in a different language"
        return """
        \(instruction)

        The style description above was derived from this person's speech
        \(source), but the text you are rewriting is \(target).
        Transfer only what is language-independent: register and
        formality, typical sentence length and rhythm, punctuation habits,
        how direct or hedged they are, what they never do. Do NOT carry
        over vocabulary, idioms, signature phrases or sentence patterns
        from the other language — write natural, idiomatic text in the
        language you were given.
        """
    }
}

@MainActor
@Observable
final class VoiceProfileStore {
    static let shared = VoiceProfileStore()

    enum State: Equatable {
        case idle
        case generating
        case ready
        case failed(String)
    }

    /// Generation state per language. Keyed rather than singular so that
    /// starting a rebuild of English can't paint the Russian card as
    /// "generating" — or, worse, report English's failure on it.
    private(set) var states: [String: State] = [:]

    /// The corpus, one bucket per language. Written to
    /// `<App Support>/Daisy/Voice/corpus.json`.
    private(set) var buckets: [String: VoiceCorpusBucket] = [:]
    /// Generated profiles, keyed by language, plus the universal one.
    private(set) var profiles: [String: VoiceProfile] = [:]
    private(set) var legacyProfile: VoiceProfile?

    /// Anchor for the short-sample stickiness rule (see
    /// `VoiceCorpusClassifier`). Persisted with the corpus so a relaunch
    /// mid-conversation doesn't send the next "ok" to `und`.
    private var lastConfidentLanguage: String? = nil
    private var lastConfidentAt: Date? = nil
    /// See `VoiceCorpusFile.migrationDominantLanguage` / `migrationUnlocked`.
    private var migrationDominantLanguage: String? = nil
    private var migrationUnlocked = false

    /// The corpus file exists but could not be READ this launch (IO
    /// error, a busy or evicted volume). Distinct from "damaged", and it
    /// makes every write a no-op: an empty in-memory corpus written over
    /// a file that was merely unreadable is how a whole corpus
    /// disappears. Same lesson as the iCloud-eviction audit — "couldn't
    /// read" is never "empty".
    private var corpusUnreadable = false
    /// Same, for `profiles.json` — a profile is text the user may have
    /// written by hand, and overwriting it with an empty file after a
    /// failed read is unrecoverable.
    private var profilesUnreadable = false
    @ObservationIgnored
    private var corpusWritePending = false

    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "VoiceProfile")

    // Legacy UserDefaults keys. Deliberately still READ and never
    // written or removed: they are the rollback path for one release. A
    // build that predates the split finds its strings exactly where it
    // left them, and if the language classification turns out wrong in
    // the field we can re-run migration from the original text. Deleting
    // them is a separate one-line change in a later beta.
    private static let legacyProfileKey = "daisy.voiceProfile"
    private static let legacyCorpusKey = "daisy.voiceCorpus"
    private static let legacyMeetingCorpusKey = "daisy.voiceCorpus.meetings"
    private static let migratedKey = "daisy.voiceCorpus.migratedV2"

    private static let includeMeetingsKey = "daisy.voiceProfileIncludeMeetings"
    /// One-shot per language: "your profile is in another language".
    private static let crossLanguageNudgeKeyPrefix = "daisy.voiceProfile.crossLangNudge."

    /// Stored cap, per language and per source — what the pre-split store
    /// applied to the whole corpus.
    private static let maxCorpusStoredChars = 16_000
    /// Hard cap on what is SENT to the provider for ONE language. Bounds
    /// token cost and what leaves the Mac on a cloud provider; keeps the
    /// most RECENT text.
    private static let maxCorpusChars = 8_000

    /// Wispr-style unlock: the profile isn't offered until enough real
    /// dictation has accumulated to say something meaningful. PER
    /// LANGUAGE — 300 words spread over three languages say nothing
    /// about any of them.
    static let unlockWords = 300

    /// Below this a language isn't shown at all: one stray Spanish
    /// sentence should not put Spanish in the interface.
    static let visibilityMinWords = 40

    private let storeDirectory: URL
    @ObservationIgnored
    private let defaults: UserDefaults

    /// Told, after a dictation, a tour sample or a meeting's own speech
    /// lands, which languages that sample carried over `unlockWords` for
    /// the first time and still have no profile — possibly none, which
    /// is the tip's cue to retry one still waiting. The shared store
    /// routes it to `StyleProfileTip`; a test store leaves it to the test.
    @ObservationIgnored
    var thresholdObserver: (@MainActor (_ crossed: [String]) -> Void)?

    /// Samples the first-run tour fed in, tagged so a later "what's in my
    /// corpus" view can tell them from ordinary dictations. The text
    /// itself lives in the bucket like any dictation's; this is
    /// provenance, persisted to `tour-samples.json`.
    private(set) var tourSamples: [VoiceTourSample] = []
    @ObservationIgnored
    private var tourSamplesUnreadable = false

    /// The last few ordinary dictations, held so a tour sample that ALSO
    /// went through the paste path (the tour's practice field takes
    /// dictation like any field) is tagged rather than counted twice.
    @ObservationIgnored
    private var recentDictations: [(text: String, language: String, at: Date)] = []

    private convenience init() {
        // Container's Application Support, exactly like
        // `SpeakerProfileStore`. NOT UserDefaults (six languages × two
        // sources × 16k would be ~200 KB in a plist macOS reads whole at
        // every launch and rewrites at every `set`), and NOT the
        // recordings folder — the corpus is app state, and anything that
        // lands in a synced folder is one day evicted and read back as an
        // error (see the iCloud-eviction audit, 2026-08-20).
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        self.init(
            storeDirectory: appSupport
                .appendingPathComponent("Daisy", isDirectory: true)
                .appendingPathComponent("Voice", isDirectory: true),
            defaults: .standard
        )
        // Read at call time, never here: `shared` is still being built.
        thresholdObserver = { crossed in
            StyleProfileTip.shared.corpusGrew(crossed: crossed, in: VoiceProfileStore.shared)
        }
    }

    /// A store on its own folder and defaults — what tests use, so they
    /// never touch the real corpus or the real preferences.
    init(storeDirectory: URL, defaults: UserDefaults) {
        self.storeDirectory = storeDirectory
        self.defaults = defaults

        // Absent key → false. Opt-in by design.
        includesMeetings = defaults.bool(forKey: Self.includeMeetingsKey)

        // Tags first: `loadOrMigrate` may prune a stale bucket, and that
        // drops the bucket's tags too — loaded later, the tags of an
        // evicted bucket would survive the prune.
        loadTourSamples()
        loadOrMigrate()
        // The `DictationHistory` used to seed an empty
        // corpus here. It no longer does, and that is the point: history
        // holds the text as PASTED, and at the time an opt-in LLM pass
        // could rewrite the paste in the model's taste — feeding that
        // back was exactly the feedback loop this version exists to
        // close. That pass is gone (2026-09-12); the rule stays, because
        // it is what keeps the corpus the person's own. Upgraders are
        // covered by the migration above; a brand-new user is 300 words
        // away either way.
    }

    // MARK: - Load / migrate

    private var corpusURL: URL { storeDirectory.appendingPathComponent("corpus.json") }
    private var profilesURL: URL { storeDirectory.appendingPathComponent("profiles.json") }

    private func loadOrMigrate() {
        try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

        var loadedCorpus = false
        if FileManager.default.fileExists(atPath: corpusURL.path) {
            // "Couldn't read it" and "read it, it's nonsense" are two
            // different situations and only one of them is recoverable
            // by starting over. A read error is transient (busy volume,
            // an evicted file, a bad moment) and the correct response is
            // to touch nothing at all this launch.
            do {
                let data = try Data(contentsOf: corpusURL)
                if let file = try? JSONDecoder().decode(VoiceCorpusFile.self, from: data) {
                    buckets = file.buckets
                    lastConfidentLanguage = file.lastConfidentLanguage
                    lastConfidentAt = file.lastConfidentAt
                    migrationDominantLanguage = file.migrationDominantLanguage
                    migrationUnlocked = file.migrationUnlocked
                    loadedCorpus = true
                } else {
                    // Damaged: move it aside instead of overwriting it,
                    // then fall through to migration — the pre-split
                    // UserDefaults strings are still there for one
                    // release, so this recovers rather than starts from
                    // zero.
                    moveAside(corpusURL, suffix: "corpus-damaged.json")
                    defaults.removeObject(forKey: Self.migratedKey)
                    log.error("Voice corpus file unreadable as JSON — moved aside, re-migrating from the legacy keys")
                }
            } catch {
                corpusUnreadable = true
                log.error("Voice corpus could not be read (\(error.localizedDescription, privacy: .public)) — leaving it untouched this launch")
            }
        }

        if FileManager.default.fileExists(atPath: profilesURL.path) {
            do {
                let data = try Data(contentsOf: profilesURL)
                if let file = try? JSONDecoder().decode(VoiceProfilesFile.self, from: data) {
                    profiles = file.profiles
                    legacyProfile = file.legacy
                } else {
                    moveAside(profilesURL, suffix: "profiles-damaged.json")
                    // The pre-split profile is still in UserDefaults for
                    // one release; re-running migration recovers it.
                    defaults.removeObject(forKey: Self.migratedKey)
                    log.error("Voice profiles file unreadable as JSON — moved aside, re-migrating from the legacy key")
                }
            } catch {
                // Same rule as the corpus: an unreadable profiles file
                // must never be replaced by an empty one.
                profilesUnreadable = true
                log.error("Voice profiles could not be read (\(error.localizedDescription, privacy: .public)) — leaving them untouched this launch")
            }
        }

        // A missing corpus file is itself a reason to migrate again: the
        // flag lives in the preferences plist and the data lives in
        // Application Support, and those two can be restored (or wiped)
        // independently. `corpusAlreadyPopulated` is what actually
        // prevents a double absorb.
        let migrated = defaults.bool(forKey: Self.migratedKey)
        if !corpusUnreadable, !profilesUnreadable, !migrated || !loadedCorpus {
            migrateFromLegacyDefaults(corpusAlreadyPopulated: loadedCorpus)
        }
        pruneStaleBuckets()
    }

    /// Quarantine a file we could parse nothing out of. Stamped with the
    /// time so a second incident doesn't destroy the evidence from the
    /// first one.
    private func moveAside(_ url: URL, suffix: String) {
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = storeDirectory.appendingPathComponent("\(stamp)-\(suffix)")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        log.error("Quarantined \(url.lastPathComponent, privacy: .public) as \(aside.lastPathComponent, privacy: .public)")
    }

    /// One-time pass over the pre-split UserDefaults corpus.
    ///
    /// The old corpus is dictations joined by "\n\n", so paragraphs are
    /// the original samples and can be classified the same way new ones
    /// are. Two deliberate differences from the live path:
    ///
    ///  • the detector runs FIRST and the pinned locale is only a
    ///    fallback. The pinned locale describes today; a corpus is a
    ///    year of yesterdays. Trusting it first would sweep a genuinely
    ///    mixed corpus into whichever language happens to be selected
    ///    right now, and that is the one migration error we cannot undo
    ///    from the UI.
    ///  • stickiness is by POSITION rather than by clock — the
    ///    paragraphs have no timestamps.
    ///
    /// Nothing is deleted: the legacy keys stay, and the single old
    /// profile becomes the UNIVERSAL profile rather than being assigned
    /// to a language. That is what keeps an already-unlocked user
    /// unlocked — they never see "your profile was reset, now dictate
    /// 300 English words".
    private func migrateFromLegacyDefaults(corpusAlreadyPopulated: Bool) {
        let oldCorpus = defaults.string(forKey: Self.legacyCorpusKey) ?? ""
        let oldMeetings = defaults.string(forKey: Self.legacyMeetingCorpusKey) ?? ""
        let fallback = AppSettings.currentDictationLanguage

        var migratedSamples = 0
        if !corpusAlreadyPopulated {
            if !oldCorpus.isEmpty {
                migratedSamples += absorbLegacy(oldCorpus, fallback: fallback, isMeeting: false)
            }
            if !oldMeetings.isEmpty {
                migratedSamples += absorbLegacy(oldMeetings, fallback: fallback, isMeeting: true)
            }
            // What the pre-split corpus was mostly in. This is the
            // universal profile's implied language: it was built from
            // this text, so polishing THIS language with it is not a
            // cross-language rewrite and must not get the guard.
            //
            // Counted the way the old `effectiveWords` counted — meetings
            // only when the switch is on — so the answer matches what
            // that user's progress bar used to say, and the same measure
            // decides both the dominant bucket and the unlock.
            migrationDominantLanguage = buckets.values
                .filter { $0.language != VoiceLanguage.undetermined }
                .max {
                    $0.effectiveWords(includingMeetings: includesMeetings)
                        < $1.effectiveWords(includingMeetings: includesMeetings)
                }?
                .language
            // Whoever was unlocked before the split stays unlocked. The
            // old threshold was 300 words across ONE undivided corpus,
            // so 200 Russian + 150 English used to be a profile you
            // could generate; splitting the corpus must not take that
            // away.
            let legacyWords = UsageStats.wordCount(oldCorpus)
                + (includesMeetings ? UsageStats.wordCount(oldMeetings) : 0)
            migrationUnlocked = legacyWords >= Self.unlockWords
        }

        if legacyProfile == nil, profiles.isEmpty,
           let data = defaults.data(forKey: Self.legacyProfileKey),
           let decoded = try? JSONDecoder().decode(VoiceProfile.self, from: data) {
            legacyProfile = VoiceProfile(
                generatedAt: decoded.generatedAt,
                sampleWords: decoded.sampleWords,
                display: decoded.display,
                styleInstruction: decoded.styleInstruction,
                language: nil,
                languageIsInferred: false
            )
        }

        // The flag is set only once BOTH files are safely written. A
        // failed write leaves it clear, so the next launch tries again
        // off the untouched legacy keys rather than losing the corpus.
        let corpusOK = writeCorpus()
        let profilesOK = writeProfiles()
        if corpusOK, profilesOK {
            defaults.set(true, forKey: Self.migratedKey)
            let summary = buckets.values
                .map { "\($0.language):\($0.effectiveWords(includingMeetings: true))" }
                .sorted()
                .joined(separator: " ")
            log.info("Voice corpus migrated to language buckets — \(migratedSamples, privacy: .public) sample(s) → \(summary, privacy: .public)")
        } else {
            log.error("Voice corpus migration could not be written — will retry on next launch")
        }
    }

    /// Split one legacy blob into its original samples and file them.
    /// Returns the number of samples absorbed.
    @discardableResult
    private func absorbLegacy(_ blob: String, fallback: String?, isMeeting: Bool) -> Int {
        let paragraphs = blob
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // A legacy MEETING paragraph is one whole meeting's own speech
        // joined with spaces, so it gets the same block treatment the
        // live path now gives a meeting: a call that changed language
        // halfway through must not be filed as one language.
        // A legacy meeting paragraph is one meeting's own speech joined
        // with spaces, so it has to be cut into sentences before there
        // is anything for `group` to group.
        let samples = isMeeting
            ? paragraphs.flatMap { VoiceSpeechBlocks.group(VoiceSpeechBlocks.sentences(in: $0)) }
            : paragraphs
        var previous: String?
        var absorbed = 0
        for paragraph in samples {
            var verdict = VoiceCorpusClassifier.classify(
                paragraph,
                pinned: nil,                       // detector first — see the note above
                transcriberHint: nil,
                sticky: previous.map { (language: $0, at: Date()) },
                now: Date()
            )
            if verdict.language == VoiceLanguage.undetermined,
               let fallback, let code = VoiceCorpusClassifier.normalized(fallback) {
                verdict = VoiceLanguageVerdict(language: code, isConfident: false, mixed: verdict.mixed)
            }
            if verdict.isConfident { previous = verdict.language }
            store(sample: paragraph, in: verdict, isMeeting: isMeeting, touchStickiness: false)
            absorbed += 1
        }
        return absorbed
    }

    /// Evict a bucket that is (a) not unlocked, (b) untouched for 90 days
    /// and (c) not in the top 6 by size. Text only — the counters are
    /// tiny and stay, and a PROFILE is never touched: the user may have
    /// written it themselves.
    private func pruneStaleBuckets() {
        // Keyed by the DICTIONARY key, not by `bucket.language`: this is
        // a deletion path, and the two are separately sourced (the key
        // from the verdict, the field from the decoded file). They agree
        // today; a deletion path should not depend on that.
        let keep = Set(
            buckets
                .sorted { $0.value.effectiveWords(includingMeetings: true) > $1.value.effectiveWords(includingMeetings: true) }
                .prefix(6)
                .map { $0.key }
        )
        let cutoff = Date().addingTimeInterval(-90 * 24 * 3600)
        var evicted: [String] = []
        for (code, bucket) in buckets {
            guard !keep.contains(code),
                  !bucket.isEmpty,
                  bucket.effectiveWords(includingMeetings: true) < Self.unlockWords,
                  bucket.lastAppendedAt < cutoff else { continue }
            var pruned = bucket
            pruned.dictation = ""
            pruned.dictationWords = 0
            pruned.meetings = ""
            pruned.meetingWords = 0
            buckets[code] = pruned
            evicted.append(code)
        }
        guard !evicted.isEmpty else { return }
        _ = writeCorpus()
        // Their text is gone from the bucket, so the tags would point at
        // nothing. (The tags load BEFORE this runs at launch — see init.)
        let before = tourSamples.count
        tourSamples.removeAll { evicted.contains($0.language) }
        if tourSamples.count != before { writeTourSamples() }
        log.info("Voice corpus: evicted stale bucket(s) \(evicted.joined(separator: ","), privacy: .public)")
    }

    // MARK: - Disk

    /// Synchronous and atomic, on the main actor. The file tops out
    /// around 200 KB, which is the same order as the plist write this
    /// replaced; handing it to a detached task would buy microseconds and
    /// cost write ordering.
    @discardableResult
    private func writeCorpus() -> Bool {
        // Never write over a file we failed to READ — see
        // `corpusUnreadable`.
        guard !corpusUnreadable else { return false }
        let file = VoiceCorpusFile(
            buckets: buckets,
            lastConfidentLanguage: lastConfidentLanguage,
            lastConfidentAt: lastConfidentAt,
            migrationDominantLanguage: migrationDominantLanguage,
            migrationUnlocked: migrationUnlocked
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(file).write(to: corpusURL, options: [.atomic])
            return true
        } catch {
            log.error("Couldn't persist voice corpus: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func writeProfiles() -> Bool {
        guard !profilesUnreadable else { return false }
        let file = VoiceProfilesFile(profiles: profiles, legacy: legacyProfile)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(file).write(to: profilesURL, options: [.atomic])
            return true
        } catch {
            log.error("Couldn't persist voice profiles: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private var tourSamplesURL: URL { storeDirectory.appendingPathComponent("tour-samples.json") }

    /// Same read rules as the corpus: a file we couldn't read is left
    /// alone this launch; one we read and couldn't parse is moved aside
    /// and the list starts over.
    private func loadTourSamples() {
        guard FileManager.default.fileExists(atPath: tourSamplesURL.path) else { return }
        do {
            let data = try Data(contentsOf: tourSamplesURL)
            if let decoded = try? JSONDecoder().decode([VoiceTourSample].self, from: data) {
                tourSamples = decoded
            } else {
                moveAside(tourSamplesURL, suffix: "tour-samples-damaged.json")
            }
        } catch {
            tourSamplesUnreadable = true
            log.error("Tour samples could not be read (\(error.localizedDescription, privacy: .public)) — leaving them untouched this launch")
        }
    }

    private func writeTourSamples() {
        guard !tourSamplesUnreadable else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(tourSamples).write(to: tourSamplesURL, options: [.atomic])
        } catch {
            log.error("Couldn't persist tour samples: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Meetings switch

    /// Whether meeting speech is currently counted, and the single source
    /// of truth for it.
    ///
    /// Owned here rather than in AppSettings so it sits INSIDE this
    /// store's `@Observable` graph: `effectiveWords`, `unlockProgress`
    /// and `isUnlocked` all depend on it, and had the flag lived
    /// elsewhere those would only refresh by luck — whenever some view
    /// happened to also read the settings object in the same body.
    private(set) var includesMeetings: Bool

    /// Flip the meetings switch. Persisted immediately; the caller is
    /// responsible for seeding from the existing library when turning it
    /// on (`VoiceView.seedFromLibrary`).
    func setIncludesMeetings(_ on: Bool) {
        guard includesMeetings != on else { return }
        includesMeetings = on
        defaults.set(on, forKey: Self.includeMeetingsKey)
    }

    // MARK: - Reading the corpus

    /// Languages worth showing, largest first. `und` is never among them
    /// — it gets a footnote, not a chip.
    var languages: [String] {
        buckets.values
            .filter {
                $0.language != VoiceLanguage.undetermined
                && $0.effectiveWords(includingMeetings: includesMeetings) >= Self.visibilityMinWords
            }
            .sorted {
                $0.effectiveWords(includingMeetings: includesMeetings)
                    > $1.effectiveWords(includingMeetings: includesMeetings)
            }
            .map(\.language)
    }

    /// The language the Voice screen opens on: the biggest one that has a
    /// profile, else simply the biggest.
    var primaryLanguage: String? {
        languages.first { profiles[$0] != nil } ?? languages.first
    }

    /// Words in the bucket for text whose language nothing could name.
    var undeterminedWords: Int {
        buckets[VoiceLanguage.undetermined]?
            .effectiveWords(includingMeetings: includesMeetings) ?? 0
    }

    func effectiveWords(for language: String) -> Int {
        buckets[language]?.effectiveWords(includingMeetings: includesMeetings) ?? 0
    }

    func isUnlocked(for language: String) -> Bool {
        profiles[language] != nil || canGenerate(for: language)
    }

    /// Whether "Generate" / "Update" can actually produce something for
    /// this language. Deliberately NOT the same question as
    /// `isUnlocked(for:)`: having a profile makes a language unlocked,
    /// but it does not make 50 words enough to build a new one from —
    /// and offering "Update" there would replace an imported profile
    /// with a worse generated one.
    func canGenerate(for language: String) -> Bool {
        let words = effectiveWords(for: language)
        guard words > 0 else { return false }
        // Grandfathered at migration: this user could already generate a
        // profile before the corpus was split, and the split is not
        // allowed to take that back.
        return words >= Self.unlockWords
            || (migrationUnlocked && language == migrationDominantLanguage)
    }

    func unlockProgress(for language: String) -> Double {
        min(1, Double(effectiveWords(for: language)) / Double(Self.unlockWords))
    }

    /// The tour's «27 / 300 слов до профиля стиля». `locale` is whatever
    /// the dictation runs in ("ru-RU", "en", "auto"); a locale that names
    /// no language ("auto") reports the language closest to its unlock,
    /// like the pre-unlock card in My style. `words` is NOT clamped — a
    /// counter shows `min(words, threshold)`.
    ///
    /// Reads `buckets`, so a SwiftUI view that calls it in `body` is
    /// redrawn by `@Observable` the moment a dictation or a tour sample
    /// lands — no extra publisher needed.
    func progress(locale: String) -> (words: Int, threshold: Int) {
        guard let code = VoiceCorpusClassifier.normalized(locale) else {
            return (effectiveWords, Self.unlockWords)
        }
        return (effectiveWords(for: code), Self.unlockWords)
    }

    /// Any meeting speech at all, in any language — the gate the
    /// library backfill uses.
    var hasAnyMeetingSpeech: Bool {
        buckets.values.contains { !$0.meetings.isEmpty }
    }

    /// Words of the language closest to its unlock. What the pre-unlock
    /// progress card counts: before any language reaches 300 there is no
    /// "the" language yet, and the honest number is the nearest one.
    var effectiveWords: Int {
        buckets.values
            .filter { $0.language != VoiceLanguage.undetermined }
            .map { $0.effectiveWords(includingMeetings: includesMeetings) }
            .max() ?? 0
    }

    var unlockProgress: Double {
        min(1, Double(effectiveWords) / Double(Self.unlockWords))
    }

    /// True once ANY language is unlocked, or any profile exists. It
    /// never goes back to false after migration: an already-unlocked
    /// user keeps their universal profile and their unlock (the
    /// per-language bars live inside the language cards, not instead of
    /// the whole screen).
    var isUnlocked: Bool {
        hasProfile || languages.contains { isUnlocked(for: $0) }
    }

    var hasProfile: Bool { primaryProfile != nil }

    /// The profile to show when no language is selected yet: the biggest
    /// language's, else the universal one.
    var primaryProfile: VoiceProfile? {
        if let lang = languages.first(where: { profiles[$0] != nil }), let p = profiles[lang] {
            return p
        }
        return legacyProfile ?? profiles.values.max { $0.sampleWords < $1.sampleWords }
    }

    /// Back-compat surface for the handful of call sites that just want
    /// "is there a profile at all" (SettingsView's toggle copy).
    var profile: VoiceProfile? { primaryProfile }

    func profile(for language: String?) -> VoiceProfile? {
        guard let code = language.flatMap(VoiceCorpusClassifier.normalized) else {
            return legacyProfile ?? primaryProfile
        }
        return profiles[code]
    }

    func state(for language: String) -> State {
        if let known = states[language] { return known }
        return profiles[language] != nil ? .ready : .idle
    }

    // MARK: - Feeding the corpus

    /// Feed a finished dictation into the corpus.
    ///
    /// `language` is for callers that already know (a pinned dictation
    /// locale, an import the user labelled); nil means "work it out" —
    /// pinned setting, then the detector, then stickiness, then `und`.
    ///
    /// The text MUST be the person's own words — spelling corrections
    /// applied, no LLM rewrite. Feeding rewritten text back in is a
    /// feedback loop: the profile then learns from what a model already
    /// rewrote to its own taste, and the style drifts toward the provider
    /// rather than toward the person. Today nothing on the dictation path
    /// rewrites before this call (the opt-in polish was removed
    /// 2026-09-12); if a rewrite ever returns there, it must not be what
    /// lands here.
    func appendDictation(_ text: String, language: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // The dictation locale is only a default HERE: it describes what
        // the user dictates, and a meeting or an imported email is not
        // that.
        let verdict = classify(
            trimmed,
            pinned: language ?? AppSettings.currentDictationLanguage,
            transcriberHint: nil
        )
        let before = wordsByLanguage()
        store(sample: trimmed, in: verdict, isMeeting: false, touchStickiness: true)
        let now = Date()
        recentDictations.removeAll { now.timeIntervalSince($0.at) >= Self.tourSampleDedupWindow }
        recentDictations.append((trimmed, verdict.language, now))
        if recentDictations.count > 8 { recentDictations.removeFirst() }
        scheduleCorpusWrite()
        reportCrossings(since: before)
    }

    /// Feed what the person dictated during the first-run tour. Exactly a
    /// dictation — same classification, caps and bucket — plus a
    /// `VoiceTourSample` tag. `locale` is the tour's dictation locale
    /// ("ru-RU", "en", "auto"); one that names no language leaves the
    /// choice to the detector, as for any dictation.
    ///
    /// Safe to call for text that ALSO went through the paste path (the
    /// tour's practice field takes dictation like any field, and
    /// `DictationPaste` feeds every dictation here): text equal to one
    /// recent dictation, or to the last few joined in order (two
    /// dictations into one field), is tagged where it already landed
    /// instead of being counted twice. Pass it as the field got it — text
    /// the person then edited by hand no longer matches and is counted as
    /// a sample of its own.
    ///
    /// Same contract as `appendDictation`: the person's own words, never
    /// a rewrite.
    func appendTourSample(_ text: String, locale: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let language: String
        if let pasted = takeRecentDictations(matching: trimmed) {
            language = pasted
        } else {
            let verdict = classify(trimmed, pinned: locale, transcriberHint: nil)
            let before = wordsByLanguage()
            store(sample: trimmed, in: verdict, isMeeting: false, touchStickiness: true)
            scheduleCorpusWrite()
            language = verdict.language
            reportCrossings(since: before)
        }
        tourSamples.append(VoiceTourSample(
            language: language,
            text: trimmed,
            words: UsageStats.wordCount(trimmed),
            at: Date()
        ))
        writeTourSamples()
    }

    /// How long after a pasted dictation the same text from the tour is
    /// taken to be that dictation. Generous: the tour hands the text over
    /// when the step completes, not at the paste.
    private static let tourSampleDedupWindow: TimeInterval = 10 * 60

    /// The language of the recent dictation(s) `text` is made of, consumed
    /// so the same dictation can't be claimed twice; nil = not pasted.
    /// Compared with whitespace collapsed: two pastes into one field are
    /// joined by whatever separator the field put between them.
    private func takeRecentDictations(matching text: String) -> String? {
        let now = Date()
        recentDictations.removeAll { now.timeIntervalSince($0.at) >= Self.tourSampleDedupWindow }
        func collapsed(_ s: String) -> String {
            s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let target = collapsed(text)
        // Newest first: a single match, then the last two joined, …
        for start in recentDictations.indices.reversed() {
            let run = recentDictations[start...]
            guard collapsed(run.map(\.text).joined(separator: " ")) == target else { continue }
            let language = run.last!.language
            recentDictations.removeSubrange(start...)
            return language
        }
        for index in recentDictations.indices.reversed()
        where collapsed(recentDictations[index].text) == target {
            let language = recentDictations[index].language
            recentDictations.remove(at: index)
            return language
        }
        return nil
    }

    /// Counted words per bucket — the "before" half of `reportCrossings`.
    private func wordsByLanguage() -> [String: Int] {
        buckets.mapValues { $0.effectiveWords(includingMeetings: includesMeetings) }
    }

    /// Tell `thresholdObserver` which languages just went over the unlock
    /// with no profile of their own — and none at all when a universal
    /// profile exists, which already covers every language (see
    /// `StyleProfileTip`). Called from the passive feeds only —
    /// a dictation, a tour sample, a meeting's own speech. Import, the
    /// meetings switch and the library backfill happen IN My style, with
    /// the Generate button in front of the person; asking again from the
    /// widget would be noise.
    private func reportCrossings(since before: [String: Int]) {
        guard let thresholdObserver else { return }
        let crossed = buckets.keys.filter { code in
            legacyProfile == nil
                && code != VoiceLanguage.undetermined
                && (before[code] ?? 0) < Self.unlockWords
                && effectiveWords(for: code) >= Self.unlockWords
                && profiles[code] == nil
        }
        thresholdObserver(crossed.sorted())
    }

    /// The dictation path runs INSIDE the Stop→paste window, and the
    /// person is waiting for their words to appear in a field. Encoding
    /// and atomically writing up to ~200 KB there would put file IO in
    /// front of the paste, which the UserDefaults write this replaced
    /// never did (it buffers). So the write hops to the next main-actor
    /// turn — after the paste — and coalesces: several dictations in a
    /// row cost one write.
    private func scheduleCorpusWrite() {
        guard !corpusWritePending else { return }
        corpusWritePending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.corpusWritePending = false
            _ = self.writeCorpus()
        }
    }

    /// Write a deferred corpus NOW. Called on the way out of the app:
    /// the last dictation before a Quit would otherwise never reach
    /// disk, because its write was waiting for a main-actor turn that
    /// never comes.
    func flushPendingWrites() {
        guard corpusWritePending else { return }
        corpusWritePending = false
        _ = writeCorpus()
    }

    /// Feed the user's own MEETING speech into the corpus.
    ///
    /// Callers MUST pass microphone-stream text only. Two of them exist:
    /// the post-stop hook in `RecordingSession.finalize`, which filters
    /// `segments` by `source == .microphone`, and
    /// `ownSpeechChunks(inTranscript:displayName:)` for transcripts
    /// already on disk. Nothing here re-checks — the filtering is the
    /// caller's job.
    ///
    /// One call = one classified unit, so callers hand over BLOCKS (see
    /// `VoiceSpeechBlocks`) rather than a whole meeting: a call that
    /// starts in Russian and continues in English is two units, and
    /// judging it as one would file half of it wrong.
    func appendMeetingSpeech(_ blocks: [String], language: String? = nil, transcriberHint: String? = nil) {
        var stored = 0
        let before = wordsByLanguage()
        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let verdict = classify(trimmed, pinned: language, transcriberHint: transcriberHint)
            store(sample: trimmed, in: verdict, isMeeting: true, touchStickiness: true)
            stored += 1
        }
        // One write for the whole meeting, not one per block.
        if stored > 0 {
            _ = writeCorpus()
            reportCrossings(since: before)
        }
    }

    private func classify(
        _ text: String,
        pinned: String?,
        transcriberHint: String?
    ) -> VoiceLanguageVerdict {
        let sticky: (language: String, at: Date)?
        if let code = lastConfidentLanguage, let at = lastConfidentAt {
            sticky = (language: code, at: at)
        } else {
            sticky = nil
        }
        return VoiceCorpusClassifier.classify(
            text,
            pinned: pinned,
            transcriberHint: transcriberHint,
            sticky: sticky
        )
    }

    private func store(
        sample: String,
        in verdict: VoiceLanguageVerdict,
        isMeeting: Bool,
        touchStickiness: Bool
    ) {
        var bucket = buckets[verdict.language] ?? VoiceCorpusBucket(language: verdict.language)
        if isMeeting {
            bucket.meetings = Self.appending(sample, to: bucket.meetings)
            bucket.meetingWords = UsageStats.wordCount(bucket.meetings)
        } else {
            bucket.dictation = Self.appending(sample, to: bucket.dictation)
            bucket.dictationWords = UsageStats.wordCount(bucket.dictation)
        }
        bucket.lastAppendedAt = Date()
        bucket.sampleCount += 1
        if verdict.mixed { bucket.codeSwitchSamples += 1 }
        buckets[verdict.language] = bucket
        if touchStickiness, verdict.isConfident {
            lastConfidentLanguage = verdict.language
            lastConfidentAt = Date()
        }
    }

    private static func appending(_ sample: String, to existing: String) -> String {
        var updated = existing.isEmpty ? sample : existing + "\n\n" + sample
        if updated.count > maxCorpusStoredChars {
            updated = String(updated.suffix(maxCorpusStoredChars))
        }
        return updated
    }

    /// The text a profile for `language` is actually built from.
    ///
    /// Each source gets its own half of the budget instead of being
    /// concatenated and tail-trimmed as one blob. Concatenating looks
    /// fine and silently isn't: the dictation corpus alone can reach
    /// 16k characters, so an 8k tail would be 100% dictation and the
    /// meeting text would be counted in the progress bar while never
    /// reaching the model. Halves also keep the ratio honest. Each half
    /// keeps its most RECENT text.
    private func corpusForGeneration(language: String) -> String {
        guard let bucket = buckets[language] else { return "" }
        guard includesMeetings, !bucket.meetings.isEmpty else {
            return String(bucket.dictation.suffix(Self.maxCorpusChars))
        }
        guard !bucket.dictation.isEmpty else {
            return String(bucket.meetings.suffix(Self.maxCorpusChars))
        }
        let half = Self.maxCorpusChars / 2
        return String(bucket.meetings.suffix(half)) + "\n\n" + String(bucket.dictation.suffix(half))
    }

    // MARK: - Generation

    /// Build (or rebuild) the profile for ONE language. Never "all
    /// languages at once": on a cloud provider that would be N requests
    /// behind one tap, and the person only ever reads one card.
    func generate(language: String) async {
        guard language != VoiceLanguage.undetermined else { return }
        // A second tap while the first probe is in flight is a second
        // paid provider request for the same answer.
        guard states[language] != .generating else { return }
        let sample = corpusForGeneration(language: language)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = UsageStats.wordCount(sample)
        guard canGenerate(for: language), words > 0 else {
            states[language] = .failed(String(localized: "Keep dictating — your profile unlocks once Daisy has heard enough of your voice."))
            return
        }

        states[language] = .generating
        do {
            let summary = try await Summarizer.shared.runProbe(
                transcript: sample,
                title: "Voice profile",
                // The profile itself must be written in the language it
                // describes; without the hint a mostly-Russian corpus can
                // still come back described in English.
                localeHint: language,
                task: .voiceProfile
            )
            let built = VoiceProfile(
                generatedAt: Date(),
                sampleWords: words,
                display: summary,
                styleInstruction: summary.clientFollowUp,
                language: language,
                languageIsInferred: true
            )
            profiles[language] = built
            _ = writeProfiles()
            states[language] = .ready
            log.info("Voice profile for \(language, privacy: .public) generated from \(words, privacy: .public) words")
            ImprovementStats.record(.voiceProfileGenerated)
        } catch {
            states[language] = .failed(error.localizedDescription)
            log.error("Voice profile for \(language, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Resolving a style for a piece of text

    /// Pick the profile to rewrite `language` text with.
    ///
    /// The rule is the language of the TARGET TEXT — not the interface,
    /// not a "main language" setting. Rewriting an English email uses the
    /// English profile.
    ///
    /// Cascade when that language has no profile:
    ///   1. its own profile;
    ///   2. the universal (pre-split / hand-pasted) profile;
    ///   3. the profile of the biggest corpus;
    ///   4. nothing — and then nothing happens. Exactly today's behaviour
    ///      with no profile: never block the paste, never show an error;
    ///      the person is waiting for their text, not for a dialog.
    ///
    /// Steps 2 and 3 come back flagged `isCrossLanguage`, which puts the
    /// guard into the prompt.
    func resolveStyle(forTextIn language: String?) -> ResolvedVoiceStyle? {
        func make(_ profile: VoiceProfile?, source: String?, cross: Bool) -> ResolvedVoiceStyle? {
            guard let profile, !profile.styleInstruction.isEmpty else { return nil }
            return ResolvedVoiceStyle(
                instruction: profile.styleInstruction,
                sourceLanguage: source,
                targetLanguage: language,
                isCrossLanguage: cross
            )
        }
        if let language, let own = make(profiles[language], source: language, cross: false) {
            return own
        }
        // A target language we couldn't name is not a KNOWN mismatch, so
        // no guard: the guard tells the model to drop the source
        // language's vocabulary, and doing that on a hunch degrades the
        // common case where the text is in the profile's language after
        // all.
        let crossKnown = language != nil
        // The universal profile DOES have an implied language when it
        // came across the split: the one its corpus was mostly in. Using
        // it means the common case — a pre-split Russian user dictating
        // Russian — is not treated as a cross-language rewrite, which
        // would strip the profile of the vocabulary that makes it worth
        // having. A pasted style prompt has no implied language, and
        // then no mismatch is known and no guard is added.
        if let universal = make(
            legacyProfile,
            source: migrationDominantLanguage,
            cross: crossKnown
                && migrationDominantLanguage != nil
                && migrationDominantLanguage != language
        ) {
            return universal
        }
        // Searched over the PROFILES, not over the visible languages: a
        // profile can exist with no corpus behind it at all (a style
        // prompt pasted in and tagged "Russian"), and a cascade that
        // only walks `languages` would report "no profile" to a person
        // who is looking at one.
        if let biggest = biggestProfileLanguage,
           let fallback = make(
               profiles[biggest],
               source: biggest,
               cross: crossKnown && biggest != language
           ) {
            return fallback
        }
        return nil
    }

    /// Language whose profile is backed by the most words. Prefers a
    /// language with an actual corpus, then falls back to sample count,
    /// so a corpus-less imported profile is still reachable.
    private var biggestProfileLanguage: String? {
        if let withCorpus = languages.first(where: { profiles[$0] != nil }) { return withCorpus }
        return profiles.max { $0.value.sampleWords < $1.value.sampleWords }?.key
    }

    /// Tell the user ONCE per language that their text is being polished
    /// by another language's profile. A toast, not a bubble: bubbles are
    /// for things that need a decision here and now (see the widget
    /// bubble notes), and this needs none — the language card in Voice
    /// says the same thing permanently.
    func noteCrossLanguagePolish(target: String?) {
        guard let target else { return }
        let key = Self.crossLanguageNudgeKeyPrefix + target
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        ToastCenter.shared.show(
            String(localized: "No profile for this language yet — Daisy is carrying your manner over, not your words. Keep dictating and it will build one."),
            style: .info,
            duration: .seconds(6)
        )
    }

    // MARK: - Meetings already in the Library

    /// One-time fill of the meeting corpus from transcripts already on
    /// disk, run when the toggle is switched on. Without it the setting
    /// would do nothing until the NEXT meeting — useless to the person who
    /// turns it on precisely because they already have dozens recorded
    /// (the 2026-07-27 report: 76 meetings, profile stuck at 0 of 300).
    ///
    /// Newest first, stopping at the stored cap, so a long library
    /// contributes its most recent speech rather than its oldest.
    /// No-op once ANY meeting speech is stored, so flipping the toggle
    /// off and on doesn't re-scan.
    @discardableResult
    func backfillFromMeetings(sessions: [StoredSession], displayName: String) -> Int {
        guard !hasAnyMeetingSpeech else { return 0 }
        let before = buckets.values.reduce(0) { $0 + $1.meetingWords }
        var collected: [String] = []
        var chars = 0
        outer: for session in sessions.sorted(by: { $0.startedAt > $1.startedAt }) {
            // Meetings only — `.note` is a voice note. The switch says
            // "meetings", and the post-stop hook is gated the same way,
            // so a voice note is treated identically whether it was
            // recorded before or after the switch was flipped.
            // Nor the tour's demo: those lines were written for the person.
            guard session.kind == .recording, !session.isDemo else { continue }
            for block in Self.ownSpeechChunks(inTranscript: session.transcriptText, displayName: displayName) {
                collected.append(block)
                chars += block.count
                if chars >= Self.maxCorpusStoredChars { break outer }
            }
        }
        guard !collected.isEmpty else { return 0 }
        // Reverse so the text reads oldest → newest, matching how the
        // corpus grows; the tail-trim then keeps recent speech. Stored
        // directly rather than through `appendMeetingSpeech` so a hundred
        // blocks cost ONE file write instead of a hundred.
        for block in collected.reversed() {
            let verdict = classify(block, pinned: nil, transcriberHint: nil)
            store(sample: block, in: verdict, isMeeting: true, touchStickiness: false)
        }
        _ = writeCorpus()
        let added = max(0, buckets.values.reduce(0) { $0 + $1.meetingWords } - before)
        log.info("Voice corpus: seeded \(added, privacy: .public) words of own meeting speech across \(collected.count, privacy: .public) block(s)")
        return added
    }

    /// Pull ONLY the user's own lines out of an exported transcript.
    ///
    /// MarkdownExporter writes every line as `**[mm:ss · Label]** text`,
    /// and the label tells us the stream: the microphone side is the
    /// user's display name, `Me`, or `Speaker <id>` (mic-side diarization
    /// with no name set), while the remote side is always `Remote…`
    /// (`TranscriptSegment.speakerLabel`).
    ///
    /// This matches the mic labels by ALLOW-LIST rather than excluding
    /// `Remote…`, and that asymmetry is deliberate: a remote speaker
    /// renamed through the speaker map would slip past an exclusion rule
    /// and quietly train the profile on someone else's voice. Missing some
    /// of the user's own older lines — e.g. recorded under a display name
    /// they've since changed — is the cheaper error by far.
    nonisolated static func ownSpeechLines(inTranscript transcript: String, displayName: String) -> [String] {
        let myName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out: [String] = []
        for rawLine in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard line.hasPrefix("**["), let close = line.range(of: "]**") else { continue }
            let inside = line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound]
            // `[mm:ss · Label]` — the label is everything after the
            // separator. No separator means an unexpected shape; skip it
            // rather than guess.
            guard let sep = inside.range(of: " · ") else { continue }
            let label = inside[sep.upperBound...].trimmingCharacters(in: .whitespaces)
            let lower = label.lowercased()
            let isMine = lower == "me"
                || (!myName.isEmpty && lower == myName)
                || label.hasPrefix("Speaker ")
            guard isMine else { continue }
            let text = line[close.upperBound...].trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { out.append(text) }
        }
        return out
    }

    /// The user's own speech from a transcript, grouped into blocks that
    /// are each big enough to classify a language from. Lines the
    /// allow-list drops simply close up — a gap moves a block boundary,
    /// it doesn't change what language the block is in.
    nonisolated static func ownSpeechChunks(inTranscript transcript: String, displayName: String) -> [String] {
        VoiceSpeechBlocks.group(ownSpeechLines(inTranscript: transcript, displayName: displayName))
    }

    // MARK: - Seeding without waiting for dictation

    /// Import the user's OWN writing (pasted text / .txt / .md — emails,
    /// posts, an export from another dictation app) into the corpus.
    /// Same pipeline as dictated words: fills the unlock bar and may
    /// unlock immediately. `language` nil = classify it like any other
    /// sample. Returns the words added, the bucket they landed in, and
    /// whether the corpus actually reached disk — a sheet that says
    /// "added 4 200 words" after a failed write is lying to the user.
    @discardableResult
    func importSamples(
        _ text: String,
        language: String? = nil
    ) -> (words: Int, language: String, persisted: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (0, VoiceLanguage.undetermined, true) }
        let verdict = classify(trimmed, pinned: language, transcriberHint: nil)
        let before = buckets[verdict.language]?.dictationWords ?? 0
        store(sample: trimmed, in: verdict, isMeeting: false, touchStickiness: true)
        let persisted = writeCorpus()
        let after = buckets[verdict.language]?.dictationWords ?? 0
        return (max(0, after - before), verdict.language, persisted)
    }

    /// Power-user path: the user already HAS a style instruction (e.g.
    /// carried over from another app). Installs it as the profile
    /// directly — no corpus, no LLM call. The instruction doubles as the
    /// display summary so the Voice card shows what's driving the polish.
    ///
    /// `language` nil installs it as the UNIVERSAL profile, which is the
    /// right default: an instruction brought in from elsewhere describes
    /// a person, not a language, and as the universal profile it covers
    /// every language that has none of its own.
    @discardableResult
    func setCustomInstruction(_ instruction: String, language: String? = nil) -> Bool {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Normalized so the key always matches what every reader looks
        // up (two-letter codes from `VoiceCorpusClassifier`); an "en-US"
        // sneaking in here would file a profile nothing could find.
        let code = language.flatMap(VoiceCorpusClassifier.normalized)
        let built = VoiceProfile(
            generatedAt: Date(),
            sampleWords: UsageStats.wordCount(trimmed),
            display: MeetingSummary(
                summary: trimmed,
                sections: [],
                actionItems: [],
                clientFollowUp: trimmed
            ),
            styleInstruction: trimmed,
            language: code,
            languageIsInferred: false
        )
        if let code {
            profiles[code] = built
            states[code] = .ready
        } else {
            legacyProfile = built
        }
        let persisted = writeProfiles()
        log.info("Voice profile set from a custom style instruction (language: \(code ?? "universal", privacy: .public))")
        return persisted
    }

}
