//
//  UserDefaultsMigration.swift
//  Daisy
//
//  One-shot UserDefaults migrations, run once each at launch:
//
//    1. `hola.*` preference keys renamed to `daisy.*`.
//    2. Retired cloud summary-model ids remapped to their successors.
//
//  Background: a handful of preference keys carried `hola.*` prefixes
//  from a previous internal codename. Renaming them in source without
//  migrating would silently reset every existing install (the new key
//  doesn't exist yet, so AppSettings falls back to defaults).
//
//  Strategy: copy the old value to the new key on first launch after
//  the rename, then remove the old key. Guarded by a sentinel so we
//  only run once — re-running would overwrite any change the user
//  made via Settings after the rename.
//

import Foundation
import os

enum UserDefaultsMigration {
    private static let log = Logger(subsystem: "app.essazanov.Daisy", category: "Migration")
    private static let sentinelKey = "daisy.migration.holaPrefixDone_v1"

    private static let keyMapping: [(old: String, new: String)] = [
        ("hola.captureSystemAudio",       "daisy.captureSystemAudio"),
        ("hola.screenshotsEnabled",       "daisy.screenshotsEnabled"),
        ("hola.screenshotIntervalSec",    "daisy.screenshotIntervalSec"),
        ("hola.autoSummarize",            "daisy.autoSummarize"),
        ("hola.whisperModelID",           "daisy.whisperModelID"),
        ("hola.lastExportFolderBookmark", "daisy.lastExportFolderBookmark"),
    ]

    /// Run whichever migrations haven't run yet. Idempotent — each one
    /// has its own sentinel, so repeat calls are no-ops. Safe to call at
    /// any point during launch; call BEFORE constructing AppSettings and
    /// before anything touches `Summarizer.shared`, so the new keys are
    /// populated by the time they're read.
    static func runIfNeeded() {
        let defaults = UserDefaults.standard

        // Each migration carries its OWN sentinel, so this must run
        // before — not after — the hola.* guard below. Behind it, it
        // would only ever execute on a machine that had never launched
        // Daisy, i.e. one with nothing to migrate: dead code that looks
        // like a feature.
        migrateSummaryModels(defaults: defaults)

        guard !defaults.bool(forKey: sentinelKey) else { return }

        var migratedCount = 0
        for (old, new) in keyMapping {
            // Only copy if the new key isn't already set — protects any
            // value the user might have set via a build that already
            // wrote the new key.
            if defaults.object(forKey: new) == nil,
               let value = defaults.object(forKey: old) {
                defaults.set(value, forKey: new)
                migratedCount += 1
            }
            // Always remove the legacy key, whether we copied or not,
            // so it stops cluttering the prefs plist.
            defaults.removeObject(forKey: old)
        }

        defaults.set(true, forKey: sentinelKey)

        if migratedCount > 0 {
            log.info("Migrated \(migratedCount, privacy: .public) hola.* preference key(s) to daisy.*")
        }
    }

    // MARK: - Cloud summary models (2026-07)

    /// `_v2`: `_v1` shipped behind the hola.* guard and could only ever
    /// mark itself done without doing anything. Anyone who ran that
    /// build carries a true `_v1` flag and would be skipped forever.
    private static let modelSentinelKey = "daisy.migration.summaryModels2026_07_v2"

    /// Model ids Daisy used to offer, and what each becomes.
    ///
    /// Cloud providers ONLY. A local model id is not interchangeable the
    /// way a hosted one is: `qwen3.5:4b` is a 3.4 GB download the user
    /// may not have, and rewriting `llama3.2:latest` to it would turn a
    /// working setup into a 404 at the worst possible moment — the first
    /// summary after an update. Ollama and LM Studio picks are left
    /// alone; their pickers read the live server listing anyway, so the
    /// newer catalog shows up there without touching anyone's choice.
    ///
    /// Only ids that are actually going away, or whose successor costs
    /// the same or less. `gpt-4o` and `gpt-4o-mini` are NOT on OpenAI's
    /// shutdown list — they just fell out of the current price sheet —
    /// so anyone on them keeps working, and we leave them alone. That
    /// matters most for `gpt-4o-mini` at $0.15/$0.60: the cheapest thing
    /// in the 5.6 generation was Luna at $1/$6 (2026-07-28 prices), so "migrating" someone
    /// who deliberately picked the cheap model would multiply their bill
    /// by ~10 without asking. They still see the refreshed list in
    /// Settings; their own pick just isn't overwritten (Egor, 2026-07-28).
    ///
    /// `gpt-4-turbo` IS being shut down (2026-10-23), and the mapping
    /// follows OpenAI's own stated replacement. The Claude ones are
    /// same-tier successors, and Sonnet 5 is CHEAPER than the 4.6 it
    /// replaces ($2/$10 vs $3/$15; the planned September rise to $3/$15
    /// was cancelled).
    private static let modelMapping: [(key: String, from: String, to: String)] = [
        ("daisy.anthropicModel", "claude-sonnet-4-6", "claude-sonnet-5"),
        ("daisy.anthropicModel", "claude-opus-4-6",   "claude-opus-5"),
        ("daisy.openaiModel",    "gpt-4-turbo",       "gpt-5.6-sol"),
    ]

    /// Move anyone still pointed at a model we no longer list onto its
    /// successor. Exact-match only: a hand-typed id we don't recognise
    /// is the user's deliberate choice and stays untouched.
    /// Every model mapping, oldest first so they chain (4.6 → 5 → 5.5
    /// in one launch). Internal for the tests.
    static func migrateSummaryModels(defaults: UserDefaults) {
        migrateSummaryModels(modelMapping, sentinel: modelSentinelKey, defaults: defaults)
        migrateSummaryModels(modelMapping2026_10, sentinel: modelSentinelKey2026_10, defaults: defaults)
    }

    // MARK: - Cloud summary models (2026-10)

    private static let modelSentinelKey2026_10 = "daisy.migration.summaryModels2026_10"

    /// The Claude 5.5 / 5.1 generation (2026-10-08): each successor costs
    /// the same (Sonnet 5.5, Fable 5.1) or less (Opus 5.5, $4/$20 against
    /// $5/$25). Haiku 4.5 is left alone — Haiku 5.5 is far cheaper but a
    /// different model (it can refuse, with no fallback), and someone on
    /// it picked it. The older ids stay in the picker either way.
    private static let modelMapping2026_10: [(key: String, from: String, to: String)] = [
        ("daisy.anthropicModel", "claude-sonnet-5", "claude-sonnet-5-5"),
        ("daisy.anthropicModel", "claude-opus-5",   "claude-opus-5-5"),
        ("daisy.anthropicModel", "claude-fable-5",  "claude-fable-5-1"),
    ]

    /// One pass over a mapping, once per sentinel. Exact-match only: a
    /// hand-typed id we don't recognise stays untouched.
    private static func migrateSummaryModels(
        _ mapping: [(key: String, from: String, to: String)],
        sentinel: String,
        defaults: UserDefaults
    ) {
        guard !defaults.bool(forKey: sentinel) else { return }
        for (key, from, to) in mapping where defaults.string(forKey: key) == from {
            defaults.set(to, forKey: key)
            log.info("Summary model \(from, privacy: .public) → \(to, privacy: .public)")
        }
        defaults.set(true, forKey: sentinel)
    }
}
