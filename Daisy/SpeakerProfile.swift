// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  SpeakerProfile.swift
//  Daisy
//
//  One persistent voice profile — Daisy's record of "this 256-d
//  embedding vector belongs to a person the user has named". Saved
//  to disk in the app's container and matched against new sessions
//  so users name a speaker once and Daisy auto-labels them in every
//  future meeting.
//
//  Privacy: the embedding is a biometric derivative — irreversible
//  (you cannot reconstruct the voice from it) but uniquely
//  identifying. Lives in the sandboxed container, NEVER leaves the
//  Mac, can be wiped from Settings → Speakers → Forget all.
//

import Foundation

struct SpeakerProfile: Codable, Identifiable, Sendable, Hashable {
    /// Stable UUID — used as both filename and in-memory dictionary
    /// key. Survives renames.
    let id: UUID
    /// Display name the user typed (e.g. "Alex", "Mom", "Customer:
    /// Sarah Chen"). Free-text, no validation beyond non-empty trim.
    var name: String
    /// 256-dim L2-normalized vector from FluidAudio's wespeaker_v2
    /// model. Cosine similarity ≥ matchThreshold against a new
    /// session's cluster centroid → "this is the same person".
    var embedding: [Float]
    /// When the profile was first created (user typed the name).
    let createdAt: Date
    /// Last time this profile matched a session — bumped on
    /// successful auto-match. Used to age-out stale profiles in the
    /// management UI ("haven't heard from this person in 6 months").
    var lastSeenAt: Date
    /// How many times Daisy has matched this profile in sessions.
    /// Display-only — gives the user a sense of which profiles are
    /// load-bearing vs one-offs.
    var sessionCount: Int

    // ── CRM fields (1.0.7.10, Talat parity) ──────────────────────
    // All three are ADDITIVE and migration-safe: the custom
    // `init(from:)` below uses `decodeIfPresent`, so profiles saved
    // before this field set existed (which have none of these keys
    // in their JSON) still decode — they get the empty defaults.
    // No version-stamp / migration pass needed; absence == default.

    /// Email addresses associated with this person. Used to match
    /// calendar attendees → this speaker: when a session is bound to
    /// a calendar event, Daisy intersects the event's attendee emails
    /// (`DaisyMeeting.attendeeEmails`) with this list to identify and
    /// auto-label the speaker, IN ADDITION to the voice fingerprint.
    /// Lowercased + trimmed on write (see SpeakerProfileStore). One
    /// person can have several (work + personal). Empty by default.
    var emails: [String]

    /// Free-form context the user types about this person — role,
    /// company, "met at WWDC", "always joins late", whatever. Never
    /// fed to matching; purely a human note surfaced in the speaker
    /// detail UI and (future) optionally in summaries. Empty default.
    var notes: String

    init(
        id: UUID = UUID(),
        name: String,
        embedding: [Float],
        createdAt: Date = Date(),
        lastSeenAt: Date = Date(),
        sessionCount: Int = 1,
        emails: [String] = [],
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.sessionCount = sessionCount
        self.emails = emails
        self.notes = notes
    }

    // MARK: - Migration-safe decoding
    //
    // Hand-rolled `init(from:)` so that profiles written by any prior
    // build decode cleanly. The original schema had only id / name /
    // embedding / createdAt / lastSeenAt / sessionCount; a JSON file
    // from that era has NO `emails` or `notes` key. With the
    // synthesised Decodable, a missing key for a non-optional stored
    // property is a hard decode error — every old profile would throw
    // and the store's `try? decoder.decode(...)` would silently drop
    // it ("Skipped malformed profile"), wiping the user's enrolled
    // speaker DB on first launch after update. `decodeIfPresent` with
    // a default makes the new keys optional ON THE WIRE while keeping
    // them non-optional in memory. The legacy six keys stay `decode`
    // (required) — any file that lacks THOSE was already unreadable
    // before this change, so behaviour there is unchanged.
    //
    // Encoding stays synthesised: new writes always include all keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.embedding = try c.decode([Float].self, forKey: .embedding)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.lastSeenAt = try c.decode(Date.self, forKey: .lastSeenAt)
        self.sessionCount = try c.decode(Int.self, forKey: .sessionCount)
        // New, optional-on-disk fields — absent in pre-1.0.7.10 files.
        self.emails = try c.decodeIfPresent([String].self, forKey: .emails) ?? []
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

/// Sidecar file persisted alongside each session's audio archive.
/// Stores the per-cluster centroid embeddings keyed by the in-
/// transcript label ("A", "B", "C"). When the user later renames
/// "Remote A" → "Alex" in SessionDetailView we load this file,
/// look up centroid for "A", and hand it to
/// `SpeakerProfileStore.upsert(name:embedding:)` so the new
/// profile encodes who Alex's voice sounds like.
///
/// File layout: `<session-dir>/speakers.json`.
///
/// `nonisolated` so the Codable conformance can be used from a
/// nonisolated context (specifically `RecordingSession.makeStoredSession`,
/// which decodes this file off the main actor). Under the project's
/// Swift 6 default-actor-isolation = MainActor, an unannotated type
/// gets @MainActor and so does its synthesised Decodable conformance,
/// which the nonisolated callsite can't reach. Type is a pure data
/// container with no shared mutable state, so opting out is safe.
nonisolated struct SpeakerCentroidsFile: Codable, Sendable {
    let centroids: [String: [Float]]
}

/// Holds the speaker labels Daisy has a name for but did NOT
/// auto-apply — the user confirms them in the session's
/// Name-the-speakers card before the names enter the transcript.
///
/// Written in both `Suggest` and `Automatic` mode, for different
/// reasons:
///
///   • In `Suggest`, EVERY match lands here, including the strong ones
///     (voice fingerprint, calendar-attendee email) — that's what the
///     mode means. In `Automatic` those same strong matches go straight
///     into the transcript's `daisy_speaker_map` instead.
///   • The two WEAK signals are suggestion-only in every mode and so
///     land here even under `Automatic`: a name matched off the invite
///     by display name (`invite`) and a name inferred from how someone
///     is addressed in the conversation (`mentioned`,
///     `SpeakerNameSuggester`). Neither is an identity key, and a wrong
///     speaker name is worse than "Remote B" — it's a quotation
///     attributed to someone who didn't say it, in a document the user
///     may forward.
///
/// In `Off` mode nothing is written: the user turned cross-meeting
/// recognition off, and every source above is a form of it.
///
/// File layout: `<session-dir>/speaker_suggestions.json`. Deleted by
/// the detail view once every suggestion has been confirmed or
/// dismissed, so a session with no pending suggestions has no sidecar.
///
/// `byLabel` maps transcript speaker label ("A", "B", …) → the
/// suggested display name. `source` is a parallel map label → why we
/// matched ("voice" / "email" / "voice+email" / "invite" /
/// "mentioned"), surfaced as a subtle caption so the user knows how
/// confident the match is.
///
/// `nonisolated` for the same reason as `SpeakerCentroidsFile` — pure
/// data container decoded off the main actor.
nonisolated struct SpeakerSuggestionsFile: Codable, Sendable {
    var byLabel: [String: String]
    var source: [String: String]
}

/// Cosine similarity between two L2-normalized vectors. Since both
/// are unit-length, this reduces to a dot product. Range −1…+1;
/// FluidAudio's wespeaker_v2 produces embeddings where same-speaker
/// pairs typically score 0.7+ and different-speaker pairs sit below
/// 0.5.
///
/// Public so the matching logic + future ML test helpers can call
/// it; we don't depend on FluidAudio's internal `SpeakerOperations`
/// to keep this module independently testable.
nonisolated func speakerCosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0
    for i in 0..<a.count {
        dot += a[i] * b[i]
    }
    // Vectors are already L2-normalized by the embedding model;
    // dot product == cosine. No division by magnitudes needed.
    return dot
}
