//
//  SpeakerProfileStore.swift
//  Daisy
//
//  Disk-backed registry of `SpeakerProfile`s. One JSON file per
//  profile under
//  `<container>/Application Support/Daisy/SpeakerProfiles/<uuid>.json`.
//  Loaded into memory on first access and kept hot for the life of
//  the app — there's typically only a handful of profiles, the
//  whole set is well under 100 KB.
//
//  Matching contract: given a new cluster centroid (256-d L2-
//  normalized), `findMatch(for:)` returns the highest-similarity
//  stored profile IF its cosine similarity exceeds `matchThreshold`.
//  Threshold tuned conservative (0.65) — false-positive ("auto-
//  named wrong person") is worse UX than false-negative ("user has
//  to rename manually again").
//
//  Privacy: profiles never leave the Mac. `forgetAll()` wipes the
//  directory; `forget(_:)` removes one. Both are exposed in
//  Settings for explicit user control.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class SpeakerProfileStore {
    static let shared = SpeakerProfileStore()

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "SpeakerProfiles")

    /// Cosine similarity threshold for "same speaker" matching.
    /// wespeaker_v2 same-speaker pairs typically score 0.7+, distinct
    /// pairs <0.5; 0.65 leaves a 0.05 safety margin against false
    /// positives. Tunable per-user in a future Settings row if we
    /// see real-world drift.
    static let matchThreshold: Float = 0.65

    /// All known profiles, keyed by UUID. Observable so any UI that
    /// renders the profile list (Settings, SessionDetailView's
    /// "Name the speakers" card) re-renders on add/rename/delete.
    private(set) var profiles: [UUID: SpeakerProfile] = [:]

    private let dirURL: URL
    private var loaded = false

    private init() {
        // Container's Application Support — sandboxed, encrypted at
        // rest by macOS FileVault, survives app re-installs (unless
        // user explicitly resets the container).
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        self.dirURL = appSupport
            .appendingPathComponent("Daisy", isDirectory: true)
            .appendingPathComponent("SpeakerProfiles", isDirectory: true)
    }

    // MARK: - Lifecycle

    /// Lazy load on first access. Idempotent. Safe to call from
    /// view body / init paths.
    func ensureLoaded() {
        guard !loaded else { return }
        do {
            try FileManager.default.createDirectory(
                at: dirURL,
                withIntermediateDirectories: true
            )
        } catch {
            // Don't latch `loaded` on a failure to even make the
            // directory — that left the store empty and mute for the
            // whole run, and the next `upsert` would happily start a
            // fresh set of profiles beside the ones on disk.
            // Latch the "picture is incomplete" flag too: without it
            // `upsert` would sail past its guard, create a profile in
            // memory and then fail its own write (which doesn't create
            // the directory either) — inventing a person that never
            // reaches disk (review find, 2026-09-02).
            hasUnreadableProfiles = true
            log.error("Couldn't create profile dir: \(error.localizedDescription, privacy: .public)")
            return
        }
        loaded = true
        let urls = (try? FileManager.default.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        var loaded: [UUID: SpeakerProfile] = [:]
        var failures = 0
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else {
                // "Didn't read" is not "doesn't exist" — the lesson
                // `VoiceProfileStore` already learned. Left unmarked,
                // an unreadable profile means `upsert` creates a SECOND
                // profile for the same person, and "Forget all people"
                // walks the loaded dictionary and so leaves that file
                // behind — on a store of voice biometrics, with a
                // button that promises to erase them (audit 2026-09-01).
                failures += 1
                log.error("Couldn't read profile at \(url.lastPathComponent, privacy: .public)")
                continue
            }
            guard let profile = try? decoder.decode(SpeakerProfile.self, from: data) else {
                failures += 1
                log.warning("Skipped malformed profile at \(url.lastPathComponent, privacy: .public)")
                continue
            }
            loaded[profile.id] = profile
        }
        profiles = loaded
        hasUnreadableProfiles = failures > 0
        log.info("Loaded \(loaded.count, privacy: .public) speaker profile(s), \(failures, privacy: .public) unreadable")
    }

    /// True when at least one profile file on disk couldn't be read or
    /// decoded during the last load. While set, the store won't invent
    /// new profiles (the unreadable one may BE this person), and
    /// "forget all" deletes by directory rather than by what loaded.
    private(set) var hasUnreadableProfiles = false

    // MARK: - Match

    /// Returns the best-matching profile for a cluster centroid, OR
    /// nil if no stored profile scores above the threshold. Caller
    /// (RecordingSession) uses this to pre-fill `daisy_speaker_map`
    /// on save so the user opens the transcript and sees "Alex" /
    /// "Mom" instead of "Remote A".
    func findMatch(for embedding: [Float]) -> SpeakerProfile? {
        ensureLoaded()
        guard !embedding.isEmpty else { return nil }
        var best: (profile: SpeakerProfile, score: Float)?
        for profile in profiles.values {
            let score = speakerCosineSimilarity(embedding, profile.embedding)
            if score > Self.matchThreshold, best == nil || score > best!.score {
                best = (profile, score)
            }
        }
        return best?.profile
    }

    /// Bump a matched profile's `lastSeenAt` + `sessionCount`. Called
    /// by RecordingSession after a successful auto-match so the
    /// management UI shows accurate "last heard" timestamps.
    func recordMatch(profileID: UUID) {
        ensureLoaded()
        guard var profile = profiles[profileID] else { return }
        profile.lastSeenAt = Date()
        profile.sessionCount += 1
        profiles[profileID] = profile
        write(profile)
    }

    // MARK: - Email matching (calendar attendees)

    /// Normalize an email for storage + comparison: lowercased,
    /// whitespace-trimmed. Mirrors `CalendarService.projectAttendeeEmails`
    /// so the two sides compare apples-to-apples. Returns nil for
    /// anything that doesn't look like an address (no `@`, empty).
    nonisolated static func normalizeEmail(_ raw: String) -> String? {
        let n = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard n.contains("@"), !n.isEmpty else { return nil }
        return n
    }

    /// Find the profile owning a given email address, if any. Used by
    /// the calendar-attendee match path: a session bound to an event
    /// hands us the attendee emails, and we resolve each to a known
    /// speaker. Exact (normalized) match — we don't fuzzy-match
    /// addresses. First hit wins; emails are expected unique across
    /// profiles (the upsert path dedupes on assignment, but a manual
    /// edit could in theory duplicate — deterministic order via the
    /// sorted-by-recent view keeps the winner stable).
    func findByEmail(_ rawEmail: String) -> SpeakerProfile? {
        ensureLoaded()
        guard let needle = Self.normalizeEmail(rawEmail) else { return nil }
        return profilesByRecent.first { $0.emails.contains(needle) }
    }

    /// Find the profile matching a display name. The name-side
    /// companion to `findByEmail`, for the common case where a calendar
    /// invite carries a person's name but not an address Daisy has ever
    /// seen (Google invites frequently give a display name only, and a
    /// profile only gains an email once the user maps a speaker to an
    /// attendee that HAS one).
    ///
    /// Matching goes through `SpeakerNameMatching`, so "Priya" resolves
    /// to a stored "Priya Raman" and "PriyaRaman" to "Priya Raman" —
    /// but two stored profiles that both match means neither does. That
    /// ambiguity check is why this resolves against the WHOLE name list
    /// rather than returning the first hit by recency: unlike an email,
    /// a display name is not an identity key, and picking the
    /// most-recent of two people called Alex would be inventing a fact.
    ///
    /// Note this is looser than the exact match it replaced — an invite
    /// whose display name fell back to "alex" now finds a stored "Alex
    /// Petrov". That's deliberate and it's why the only caller routes
    /// the result into suggestions rather than applying it.
    func findByName(_ rawName: String) -> SpeakerProfile? {
        ensureLoaded()
        let byRecent = profilesByRecent
        guard let canonical = SpeakerNameMatching.resolve(rawName, in: byRecent.map(\.name)) else {
            return nil
        }
        return byRecent.first { $0.name == canonical }
    }

    /// Add one email to a profile (idempotent, normalized). Called when
    /// the user maps a speaker to a calendar attendee whose email is
    /// known — we attach that email so the SAME person auto-matches by
    /// email on their next calendar meeting even if the voice timbre
    /// shifts (different mic, cold, speakerphone). No-op if the email
    /// is already on the profile or is malformed.
    func addEmail(_ rawEmail: String, to id: UUID) {
        ensureLoaded()
        guard var profile = profiles[id],
              let email = Self.normalizeEmail(rawEmail),
              !profile.emails.contains(email) else { return }
        profile.emails.append(email)
        profiles[id] = profile
        write(profile)
        // Email is PII — keep .private. Profile ID stays .public.
        log.info("Attached email to profile \(id, privacy: .public)")
    }

    // MARK: - Create / update

    /// Save or update a profile. Called by SessionDetailView when
    /// the user manually types a name into the "Name the speakers"
    /// card — the matching centroid embedding (from the session's
    /// `speakers.json` sidecar) is paired with the user-typed name
    /// to either reinforce an existing match or create a new
    /// profile.
    ///
    /// Heuristic: if `embedding` matches an existing profile under
    /// a DIFFERENT name, prefer renaming the existing profile over
    /// creating a duplicate — same person under two names is a
    /// data integrity bug we want to avoid.
    @discardableResult
    func upsert(name: String, embedding: [Float]) -> SpeakerProfile? {
        ensureLoaded()
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // 1. If embedding matches an existing profile → rename
        //    that profile (don't duplicate).
        if let match = findMatch(for: embedding) {
            var updated = match
            if updated.name != trimmed {
                updated.name = trimmed
            }
            updated.lastSeenAt = Date()
            profiles[updated.id] = updated
            write(updated)
            // Speaker name is PII the user typed — keep .private so
            // real names ("John", "Maria") don't end up in the
            // unified system log. Profile ID stays public — it's an
            // opaque UUID with no inherent identity.
            log.info("Renamed existing profile \(updated.id, privacy: .public) → \(trimmed, privacy: .private)")
            return updated
        }
        // 2. If a profile already has this name → update its
        //    embedding (re-enroll). Lets users explicitly re-enroll
        //    by typing the same name on a new speaker — e.g.
        //    they're on a different mic that changed timbre.
        if let existing = profiles.values.first(where: {
            $0.name.lowercased() == trimmed.lowercased()
        }) {
            var updated = existing
            updated.embedding = embedding
            updated.lastSeenAt = Date()
            updated.sessionCount += 1
            profiles[updated.id] = updated
            write(updated)
            log.info("Re-enrolled profile for \(trimmed, privacy: .private)")
            return updated
        }
        // 3. Fresh profile — unless we know the picture is incomplete.
        //    A profile we failed to READ might be this very person, and
        //    creating a second one for them corrupts the CRM quietly:
        //    two "Alex"es with different embeddings, and auto-matching
        //    picking between them at random.
        guard !hasUnreadableProfiles else {
            log.error("Not creating a profile for \(trimmed, privacy: .private) — some profiles on disk are unreadable and one of them may be this person")
            return nil
        }
        let new = SpeakerProfile(name: trimmed, embedding: embedding)
        profiles[new.id] = new
        write(new)
        log.info("Created profile for \(trimmed, privacy: .private)")
        return new
    }

    // MARK: - Metadata edit (detail UI)

    /// Replace a profile's editable CRM metadata — display name,
    /// email list, free-form notes — from the speaker detail/edit
    /// surface in Settings. Leaves the voice `embedding`, `createdAt`,
    /// `lastSeenAt`, and `sessionCount` untouched (those are owned by
    /// the matching engine, not user-editable). Emails are normalized
    /// + de-duplicated here so the store stays the single point of
    /// truth for email hygiene; blank entries (from an empty editor
    /// row) are dropped. No-op for an unknown id.
    func updateMetadata(id: UUID, name: String, emails: [String], notes: String) {
        ensureLoaded()
        guard var profile = profiles[id] else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty { profile.name = trimmedName }
        // Normalize + dedupe while preserving the user's input order.
        var seen = Set<String>()
        var cleaned: [String] = []
        for raw in emails {
            guard let e = Self.normalizeEmail(raw) else { continue }
            if seen.insert(e).inserted { cleaned.append(e) }
        }
        profile.emails = cleaned
        profile.notes = notes
        profiles[id] = profile
        write(profile)
        log.info("Updated metadata for profile \(id, privacy: .public)")
    }

    // MARK: - Forget

    /// Remove one profile from disk + memory.
    func forget(_ id: UUID) {
        ensureLoaded()
        profiles.removeValue(forKey: id)
        let url = dirURL.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }

    /// Nuclear option — wipe every profile. Exposed in Settings.
    func forgetAll() {
        ensureLoaded()
        // Delete by DIRECTORY, not by what happened to load. A profile
        // file that failed to decode this run is still a stored voice
        // fingerprint, and it used to survive a button that says it
        // erases all of them (audit 2026-09-01).
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dirURL, includingPropertiesForKeys: nil
        )) ?? []
        var removed = 0
        for url in urls where url.pathExtension == "json" {
            do {
                try FileManager.default.removeItem(at: url)
                removed += 1
            } catch {
                log.error("Couldn't delete profile \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        profiles.removeAll()
        // Only claim a clean slate if every file actually went. This
        // button promises to erase voice biometrics; a survivor means
        // the promise wasn't kept, and the store must keep behaving
        // as though something unknown is on disk.
        hasUnreadableProfiles = removed != urls.filter { $0.pathExtension == "json" }.count
        log.info("Forgot all speaker profiles — \(removed, privacy: .public) file(s) deleted")
    }

    // MARK: - Sorted view for UI

    /// Profiles ordered by most-recently-seen, descending. Settings
    /// list renders in this order so active speakers float to the
    /// top, dormant ones sink.
    var profilesByRecent: [SpeakerProfile] {
        ensureLoaded()
        return profiles.values.sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    // MARK: - Disk write

    private func write(_ profile: SpeakerProfile) {
        let url = dirURL.appendingPathComponent("\(profile.id.uuidString).json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(profile)
            try data.write(to: url, options: [.atomic])
        } catch {
            log.error("Couldn't persist profile \(profile.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
