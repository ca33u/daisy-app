//
//  VoiceCorpus.swift
//  Daisy
//
//  The multilingual shape of the voice corpus: one bucket per language,
//  the rule that decides which bucket a sample lands in, and the on-disk
//  files both live in.
//
//  Why buckets instead of the two strings this replaced: a profile built
//  from 120 Russian + 100 English + 80 Ukrainian words is not a
//  multilingual profile, it is noise with three labels. Splitting happens
//  on the way IN — the language is decided the moment a sample is stored
//  and then lives as the bucket's label, so nothing has to classify a
//  16k blob after the fact.
//
//  The unit of classification is a WHOLE dictation (a meeting contributes
//  blocks of the user's own speech instead — see
//  `VoiceProfileStore.ownSpeechChunks`). Inside a unit the language is
//  never split: a Russian sentence carrying English product names is this
//  person's Russian, and cutting it apart would leave a sterile Russian
//  bucket and an English bucket made of two-word scraps.
//

import Foundation

// MARK: - Language identity

enum VoiceLanguage {
    /// Bucket for samples no step of the classifier could name. It
    /// accumulates, it is counted in the "not recognized" footnote, and it
    /// NEVER generates a profile — a profile built from text we can't name
    /// is a profile we can't reason about.
    ///
    /// `nonisolated` because the classifier (off-main by design) names it.
    nonisolated static let undetermined = "und"

    /// Native language name for a bucket, reusing the transcription
    /// catalogue so "Русский" / "English" / "Español" read the same here
    /// as in the locale picker. Unknown codes fall back to the system's
    /// own name for them, then to the raw code. MainActor by default —
    /// `Transcriber.availableLocales` is, and this is UI copy anyway.
    static func label(for code: String) -> String {
        if let known = Transcriber.availableLocales.first(where: { $0.id == code }) {
            return known.label
        }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}

// MARK: - Bucket

/// One language's corpus. The two sources stay separate inside it, for
/// the same reason they were separate before the split: the "count my
/// meeting speech" switch has to stay reversible, and a blended blob has
/// no provenance. Now that argument simply applies per language.
nonisolated struct VoiceCorpusBucket: Codable, Sendable, Equatable {
    /// ISO 639-1, or `VoiceLanguage.undetermined`.
    var language: String
    var dictation: String = ""
    var dictationWords: Int = 0
    var meetings: String = ""
    var meetingWords: Int = 0
    var lastAppendedAt: Date = .distantPast
    /// Samples that ever landed here — including text the tail-trim has
    /// since dropped. Feeds "not enough data yet" copy and, later, the
    /// stability gate on Phase-2 coaching.
    var sampleCount: Int = 0
    /// Samples whose runner-up language hypothesis was strong (≥0.25) —
    /// a cheap code-switching indicator, wanted by both the coaching card
    /// and the tone export.
    var codeSwitchSamples: Int = 0
    /// Phase 2: "suggest what to work on in this language", opt-in per
    /// language, default OFF. Stored now so Phase 2 doesn't have to
    /// migrate this file a second time; nothing reads it yet and no UI
    /// exposes it (Egor, 2026-08-26 — no native/non-native split, one
    /// per-language toggle instead).
    var coachingEnabled: Bool = false

    init(language: String) {
        self.language = language
    }

    /// Hand-written so a file written by an OLDER build (or a future one
    /// that adds fields) still decodes. A bucket that fails to decode
    /// takes the whole corpus file with it, which is exactly the kind of
    /// silent data loss this store must not have.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.decode(String.self, forKey: .language)
        dictation = try c.decodeIfPresent(String.self, forKey: .dictation) ?? ""
        dictationWords = try c.decodeIfPresent(Int.self, forKey: .dictationWords) ?? 0
        meetings = try c.decodeIfPresent(String.self, forKey: .meetings) ?? ""
        meetingWords = try c.decodeIfPresent(Int.self, forKey: .meetingWords) ?? 0
        lastAppendedAt = try c.decodeIfPresent(Date.self, forKey: .lastAppendedAt) ?? .distantPast
        sampleCount = try c.decodeIfPresent(Int.self, forKey: .sampleCount) ?? 0
        codeSwitchSamples = try c.decodeIfPresent(Int.self, forKey: .codeSwitchSamples) ?? 0
        coachingEnabled = try c.decodeIfPresent(Bool.self, forKey: .coachingEnabled) ?? false
    }

    /// Words the profile for this language would be built from right now.
    func effectiveWords(includingMeetings: Bool) -> Int {
        dictationWords + (includingMeetings ? meetingWords : 0)
    }

    var isEmpty: Bool { dictation.isEmpty && meetings.isEmpty }
}

// MARK: - On-disk files

nonisolated struct VoiceCorpusFile: Codable, Sendable {
    var version: Int = 2
    var buckets: [String: VoiceCorpusBucket] = [:]
    /// Last sample whose language the classifier was sure about, and
    /// when — the anchor for the short-sample stickiness rule.
    var lastConfidentLanguage: String?
    var lastConfidentAt: Date?
    /// The language the pre-split corpus was mostly in, decided once at
    /// migration. Two jobs: it is the implied source language of the
    /// universal profile (so a pre-split Russian user polishing Russian
    /// is NOT told their profile is in another language), and it is the
    /// bucket that inherits the pre-split unlock. Recorded rather than
    /// recomputed so it can't drift as the corpus grows.
    var migrationDominantLanguage: String?
    /// Whether the pre-split corpus was already over the 300-word
    /// threshold. Someone who could generate a profile before the split
    /// must still be able to after it — splitting a corpus is not
    /// allowed to take back an unlock.
    var migrationUnlocked: Bool = false

    init(version: Int = 2,
         buckets: [String: VoiceCorpusBucket] = [:],
         lastConfidentLanguage: String? = nil,
         lastConfidentAt: Date? = nil,
         migrationDominantLanguage: String? = nil,
         migrationUnlocked: Bool = false) {
        self.version = version
        self.buckets = buckets
        self.lastConfidentLanguage = lastConfidentLanguage
        self.lastConfidentAt = lastConfidentAt
        self.migrationDominantLanguage = migrationDominantLanguage
        self.migrationUnlocked = migrationUnlocked
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 2
        // Bucket by bucket, and a bucket we cannot read is an ERROR, not
        // an empty bucket. Skipping it silently would decode "fine" with
        // a smaller corpus, and the next append would write that smaller
        // corpus back over the file — the whole point of failing here is
        // that the caller then quarantines the file instead.
        var decoded: [String: VoiceCorpusBucket] = [:]
        let container = try c.nestedContainer(keyedBy: VoiceDynamicKey.self, forKey: .buckets)
        for key in container.allKeys {
            decoded[key.stringValue] = try container.decode(VoiceCorpusBucket.self, forKey: key)
        }
        buckets = decoded
        lastConfidentLanguage = try c.decodeIfPresent(String.self, forKey: .lastConfidentLanguage)
        lastConfidentAt = try c.decodeIfPresent(Date.self, forKey: .lastConfidentAt)
        migrationDominantLanguage = try c.decodeIfPresent(String.self, forKey: .migrationDominantLanguage)
        migrationUnlocked = try c.decodeIfPresent(Bool.self, forKey: .migrationUnlocked) ?? false
    }
}

nonisolated struct VoiceProfilesFile: Codable, Sendable {
    var version: Int = 2
    /// Keyed by ISO 639-1 code.
    var profiles: [String: VoiceProfile] = [:]
    /// The single pre-split profile, kept as the universal fallback for
    /// any language that has none of its own. Also where a hand-pasted
    /// style prompt lives — one carried over from another app has no
    /// language in any meaningful sense.
    var legacy: VoiceProfile?

    init(version: Int = 2,
         profiles: [String: VoiceProfile] = [:],
         legacy: VoiceProfile? = nil) {
        self.version = version
        self.profiles = profiles
        self.legacy = legacy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 2
        // Entry by entry, and a profile we cannot read fails the whole
        // decode on purpose: a profile is text the user may have written
        // themselves, and quietly dropping one would let the next write
        // erase it for good. The caller quarantines the file and
        // recovers the pre-split profile from UserDefaults instead.
        var decodedProfiles: [String: VoiceProfile] = [:]
        let container = try c.nestedContainer(keyedBy: VoiceDynamicKey.self, forKey: .profiles)
        for key in container.allKeys {
            decodedProfiles[key.stringValue] = try container.decode(VoiceProfile.self, forKey: key)
        }
        profiles = decodedProfiles
        legacy = try c.decodeIfPresent(VoiceProfile.self, forKey: .legacy)
    }
}

/// Coding key for the language → value maps, so they can be decoded one
/// entry at a time.
nonisolated struct VoiceDynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

// MARK: - Classification

nonisolated struct VoiceLanguageVerdict: Sendable, Equatable {
    /// Bucket to store the sample in.
    var language: String
    /// Whether this verdict is solid enough to anchor the stickiness rule
    /// for the short samples that follow it.
    var isConfident: Bool
    /// The detector had a strong second hypothesis — a cheap
    /// code-switching signal.
    var mixed: Bool
}

/// Decides which bucket a sample belongs to. Pure and `nonisolated`:
/// callers include the meeting finalize path.
nonisolated enum VoiceCorpusClassifier {
    /// Under this length the detector is silent by construction
    /// (`LanguageDetector` needs 16 characters and real confidence), and
    /// "ок", "да, отправляй", "send it" are a real share of dictations.
    /// Rather than dump them all in `und`, a short sample sticks to the
    /// language of the last confidently classified one.
    ///
    /// These two are a convenience heuristic, not a measurement: the cost
    /// of getting one wrong is a single short phrase in the wrong bucket,
    /// which the tail-trim washes out.
    static let stickyMinChars = 40
    static let stickyWindow: TimeInterval = 10 * 60

    /// Steps, cheapest first:
    ///  1. the user pinned a language — they said it themselves, and it
    ///     covers everyone who isn't on auto-detect;
    ///  2. the detector, on this very sample;
    ///  3. a hint from the transcriber (its session-wide snapped
    ///     language), used only where the detector stayed silent — it is
    ///     a fallback rather than a priority because a meeting's own
    ///     blocks may legitimately differ from the session-wide lock;
    ///  4. stickiness, for samples too short for step 2;
    ///  5. `und`.
    static func classify(
        _ text: String,
        pinned: String?,
        transcriberHint: String?,
        sticky: (language: String, at: Date)?,
        now: Date = Date()
    ) -> VoiceLanguageVerdict {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pinned, let code = normalized(pinned) {
            return VoiceLanguageVerdict(language: code, isConfident: true, mixed: false)
        }
        if let detected = LanguageDetector.detectDetailed(trimmed) {
            return VoiceLanguageVerdict(
                language: detected.code,
                isConfident: true,
                mixed: detected.runnerUpConfidence >= 0.25
            )
        }
        if let transcriberHint, let code = normalized(transcriberHint) {
            // Not "confident" for stickiness purposes: it describes the
            // session, not this sample.
            return VoiceLanguageVerdict(language: code, isConfident: false, mixed: false)
        }
        if trimmed.count < stickyMinChars,
           let sticky,
           now.timeIntervalSince(sticky.at) <= stickyWindow {
            return VoiceLanguageVerdict(language: sticky.language, isConfident: false, mixed: false)
        }
        return VoiceLanguageVerdict(
            language: VoiceLanguage.undetermined,
            isConfident: false,
            mixed: false
        )
    }

    /// "auto" / "" / "en-US" → nil / nil / "en". Keeps every caller from
    /// re-deriving the same two-letter prefix.
    static func normalized(_ raw: String) -> String? {
        let code = raw
            .split(separator: "-")
            .first
            .map(String.init)?
            .lowercased() ?? ""
        guard !code.isEmpty, code != "auto", code != VoiceLanguage.undetermined else { return nil }
        return code
    }
}

// MARK: - Block grouping (meeting speech)

nonisolated enum VoiceSpeechBlocks {
    /// A meeting's own speech CAN honestly change language halfway
    /// through (a call that starts in Russian and continues in English),
    /// so unlike a dictation it is not one sample. Lines are grouped, in
    /// transcript order, into blocks of at least `minChars`; a trailing
    /// block shorter than `mergeTailUnder` is folded into the previous
    /// one rather than classified on its own.
    static let minChars = 300
    static let mergeTailUnder = 120

    /// Rough sentence split, for text that arrives as ONE joined string
    /// (a legacy meeting blob) and so has no line structure left to
    /// group on. Deliberately crude — it only has to produce units small
    /// enough for `group` to re-assemble into blocks.
    static func sentences(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" || character == "\u{2026}" {
                let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { out.append(piece) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    static func group(_ lines: [String]) -> [String] {
        var blocks: [String] = []
        var current = ""
        for line in lines {
            let piece = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            current = current.isEmpty ? piece : current + " " + piece
            if current.count >= minChars {
                blocks.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            if current.count < mergeTailUnder, let last = blocks.popLast() {
                blocks.append(last + " " + current)
            } else {
                blocks.append(current)
            }
        }
        return blocks
    }
}
