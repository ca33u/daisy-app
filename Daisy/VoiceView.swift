//
//  VoiceView.swift
//  Daisy
//
//  The "Voice" sidebar section. Generates a local voice profile from the
//  user's own dictations and lets them turn on "polish dictation in my
//  voice" (a per-dictation rewrite conditioned on the profile).
//
//  One screen, one language at a time: a strip of language chips picks
//  which bucket is on show, and the card underneath is the same state
//  machine it always was — just parameterised by language. The unlock is
//  counted per language (300 words each), so the progress bar lives
//  INSIDE the language card rather than instead of the whole screen: a
//  user who was unlocked before the split stays unlocked, their old
//  profile keeps working for every language, and the bars only describe
//  what each individual language still needs.
//

import SwiftUI

struct VoiceView: View {
    @Bindable var settings: AppSettings
    @Bindable private var store = VoiceProfileStore.shared
    @State private var showingImport = false
    @State private var showingEdit = false
    /// nil = "whatever the store thinks is primary" — so the screen
    /// follows the corpus until the user picks a chip themselves.
    @State private var selectedLanguage: String?

    /// The language on show. Falls back to the store's primary, and to
    /// nil for someone whose only profile is a pasted style prompt.
    private var language: String? {
        if let picked = selectedLanguage, store.languages.contains(picked) {
            return picked
        }
        return store.primaryLanguage
    }

    private var shownProfile: VoiceProfile? {
        store.profile(for: language)
    }

    /// What "Edit" opens: the selected language's profile, or the
    /// universal one that is doing the polishing in its absence.
    private var editTarget: VoiceProfile? {
        shownProfile ?? store.profile(for: nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                // Above the profile, not under it (Egor, 2026-07-30): the
                // profile text is the long block on this page — anything
                // parked below it is below the fold, and this switch is
                // the answer to "why does this say 0 of 300 when I have 76
                // recordings", which is a question you have BEFORE you
                // read the profile.
                includeMeetingsCard
                if !store.languages.isEmpty {
                    languageStrip
                }
                stateCard
                if store.undeterminedWords > 0 {
                    // A footnote, never a chip: text we couldn't place is
                    // real and worth admitting to, but it will never
                    // produce a profile.
                    Text("Plus \(store.undeterminedWords) words in a language Daisy couldn’t place.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(24)
        }
        .task {
            // Covers the switch being flipped on in an earlier launch
            // before the Library had loaded. No-op once seeded.
            if store.includesMeetings, !store.hasAnyMeetingSpeech {
                await seedFromLibrary()
            }
        }
        .sheet(isPresented: $showingImport) {
            VoiceImportView(initialLanguage: language)
        }
        // Update + the polish toggle live as toolbar pills (CTA style, like
        // the other sections) — only once a profile exists.
        .toolbar {
            if store.hasProfile {
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $settings.polishDictationInMyVoice) {
                        Text("Polish in my voice")
                            .padding(.horizontal, 10)
                    }
                    .toggleStyle(.button)
                    .help("Rewrite each dictation in your voice before it's pasted")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingEdit = true
                    } label: {
                        Text("Edit")
                            .padding(.horizontal, 10)
                    }
                    .help("Edit your profile text, or paste one carried over from another app (Granola, Wispr Flow…)")
                }
                if let language = language, store.canGenerate(for: language) {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await store.generate(language: language) }
                        } label: {
                            Text("Update")
                                .padding(.horizontal, 10)
                        }
                        .help("Rebuild this language’s profile from your latest dictations")
                    }
                }
            }
        }
        // Edit / replace the current profile text (pre-filled with the
        // active style instruction), in the Style-prompt editor.
        .sheet(isPresented: $showingEdit) {
            // Falls back to the universal profile: standing on a
            // language card that has no profile of its own, "Edit" must
            // still open the text that is actually doing the polishing,
            // not an empty box that silently orphans it.
            VoiceImportView(
                initialText: editTarget?.styleInstruction ?? "",
                startInStylePrompt: true,
                // `.map` rather than `?? language`: a profile whose
                // language is legitimately nil is the UNIVERSAL one, and
                // saving it back under the selected language would
                // orphan it.
                initialLanguage: editTarget.map(\.language) ?? language
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your Voice")
                // Serif display title, matching the Home greeting.
                .font(.system(.largeTitle, design: .serif).weight(.medium))
                .foregroundStyle(.primary)
            Text("A profile of how you write, built from your dictations")
                .font(.callout)
                .foregroundStyle(.secondary)
            // "Built from N words · date" moved up here, under the title.
            if let profile = shownProfile {
                Text("Built from \(profile.sampleWords.formatted(.number)) words · \(profile.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Languages

    /// Chips for every language with enough words to be worth naming
    /// (40 — one stray Spanish sentence shouldn't put Spanish in the
    /// interface). Native names, reused from the transcription picker.
    /// A language without its own profile yet is drawn dimmed.
    private var languageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.languages, id: \.self) { code in
                    languageChip(code)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func languageChip(_ code: String) -> some View {
        let isSelected = language == code
        let hasProfile = store.profile(for: code) != nil
        return Button {
            selectedLanguage = code
        } label: {
            HStack(spacing: 6) {
                Text(VoiceLanguage.label(for: code))
                    .font(.callout)
                Text(store.effectiveWords(for: code).formatted(.number))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Color.gray.opacity(isSelected ? 0.16 : 0.06),
                in: Capsule()
            )
            .foregroundStyle(hasProfile ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - State

    @ViewBuilder
    private var stateCard: some View {
        if let language = language {
            languageCard(language)
        } else if let universal = store.legacyProfile {
            // No language has enough words yet, but a universal profile
            // exists — a pasted style prompt, or one carried across the
            // split. Only `legacyProfile` here: `profile(for: nil)`
            // would also hand back a language-tagged profile, which the
            // caption below would then mislabel.
            card {
                VStack(alignment: .leading, spacing: 10) {
                    universalNote
                    profileBody(universal)
                }
            }
        } else if let tagged = store.primaryProfile {
            // A profile tagged with a language that has no corpus behind
            // it (imported style prompt) — show it rather than the
            // "still learning" card, which would be a lie.
            card { profileBody(tagged) }
        } else {
            progressCard(for: nil)
        }
    }

    @ViewBuilder
    private func languageCard(_ code: String) -> some View {
        switch store.state(for: code) {
        case .generating:
            card {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Analyzing your dictations…")
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let reason):
            // A failed rebuild must not hide a profile that still
            // works: the old one is what is polishing dictations right
            // now, so it stays on screen with the error above it.
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    generateButton(title: "Try again", language: code)
                    if let profile = store.profile(for: code) {
                        Divider()
                        profileBody(profile)
                    }
                }
            }
        case .ready, .idle:
            if let profile = store.profile(for: code) {
                card { profileBody(profile) }
            } else if store.canGenerate(for: code) {
                VStack(alignment: .leading, spacing: 20) {
                    emptyCard(language: code)
                    universalCard
                }
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    progressCard(for: code)
                    universalCard
                }
            }
        }
    }

    /// Pre-unlock for ONE language: Daisy is still collecting enough of
    /// it to profile from. Says what happens MEANWHILE, not only what is
    /// missing — with another profile in place, dictation in this
    /// language is already being polished, and silence about that reads
    /// as a bug.
    @ViewBuilder
    private func progressCard(for code: String?) -> some View {
        let words = code.map { store.effectiveWords(for: $0) } ?? store.effectiveWords
        let progress = code.map { store.unlockProgress(for: $0) } ?? store.unlockProgress
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Daisy is learning your voice")
                    .font(.headline)
                if let code {
                    Text(VoiceLanguage.label(for: code))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("Keep dictating — your Voice Profile unlocks automatically once Daisy has heard enough of you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Color.daisyAccent)
                Text("\(words) of \(VoiceProfileStore.unlockWords) words")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                if code != nil, store.hasProfile {
                    Text("Until this language has its own profile, Daisy polishes it with the one you already have — your manner carries over, your words don’t.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Cold-start shortcut: seed from existing writing or a
                // ready-made style prompt instead of waiting.
                Button("Already have your style? Import it…") {
                    showingImport = true
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    /// The universal profile, rendered under a language card that has no
    /// profile of its own. Without this the migration's central promise
    /// — "your old profile keeps working" — is invisible the moment any
    /// language passes 40 words and takes over the screen.
    @ViewBuilder
    private var universalCard: some View {
        if let universal = store.legacyProfile {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    universalNote
                    profileBody(universal)
                }
            }
        }
    }

    /// Shown on a profile that has no language of its own — the one
    /// carried over from before the split, or a pasted style prompt.
    private var universalNote: some View {
        Text("This profile isn’t tied to a language — it’s used wherever Daisy hasn’t built one yet.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Opt-in switch for counting the user's own speech from meetings.
    ///
    /// Sits above the state card in EVERY state, not inside the
    /// pre-unlock card: it's the answer to "why does this say 0 of 300
    /// when I have 76 recordings" (2026-07-27 report), and it has to stay
    /// reachable after the profile exists so it can be turned back off —
    /// a switch that disappears once you're unlocked is a switch you
    /// can't undo.
    ///
    /// Off by default, and drawn as a Settings row rather than as a
    /// caption-sized control with a paragraph under it (Egor,
    /// 2026-07-30): body-weight label, full-size switch on the trailing
    /// edge, trade-off in the tooltip. Settings does the same wherever
    /// the explanation is a nicety rather than a warning (e.g. "Fix
    /// product names") — the label already says what the switch does, and
    /// two lines of tertiary text under one row made this card look like
    /// the page's main content instead of a single preference.
    ///
    /// `LabeledContent` for the trailing-edge layout, and the switch
    /// needs `.toggleStyle(.switch)` explicitly: nested in
    /// LabeledContent it has no Form row context and falls back to a
    /// checkbox (same note as the toggles in AboutView).
    private var includeMeetingsCard: some View {
        card {
            LabeledContent {
                Toggle("", isOn: Binding(
                    get: { store.includesMeetings },
                    set: { isOn in
                        store.setIncludesMeetings(isOn)
                        guard isOn else { return }
                        Task { await seedFromLibrary() }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            } label: {
                Text("Count my speech from meetings too")
            }
            .help("Only your microphone is used — never the other side. Meeting speech is conversational, so expect a profile that writes closer to how you talk.")
        }
    }

    /// Fill the meeting corpus from transcripts already on disk.
    ///
    /// Refreshes SessionStore first: a user who opens Voice without
    /// passing through Home or Library has an empty session list, and
    /// seeding off that would silently add nothing — with the switch
    /// already flipped, `onChange` would never fire again to retry.
    /// `backfillFromMeetings` no-ops once any meeting speech is stored,
    /// so running this more than once is free.
    private func seedFromLibrary() async {
        await SessionStore.shared.refresh()
        store.backfillFromMeetings(
            sessions: SessionStore.shared.sessions,
            displayName: settings.userDisplayName
        )
    }

    private func emptyCard(language code: String? = nil) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your Voice Profile is ready!")
                    .font(.headline)
                if let code {
                    Text(VoiceLanguage.label(for: code))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("Daisy has heard enough of your dictation to learn your tone, phrasing, and quirks — so it can polish future dictations to sound like you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    generateButton(title: "Generate profile", language: code)
                    Button("Import instead…") {
                        showingImport = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
        }
    }

    @ViewBuilder
    private func profileBody(_ profile: VoiceProfile) -> some View {
        // One continuous NSTextView-backed text body — same fix the
        // transcript and summary cards got (2026-07-25, Egor's
        // report): a stack of SwiftUI `Text`s with
        // .textSelection(.enabled) can't drag-select across view
        // boundaries, so selection stopped at every paragraph/bullet.
        // `includeStructural: false` = lede + sections/bullets only
        // (no "Meeting"/"Next actions"/follow-up frames — and an
        // imported profile duplicates its text into clientFollowUp,
        // which would render twice).
        //
        // ScrollableTextView, not SelectableTextView (2026-07-30,
        // Egor: "что-то поехало"). Two bugs, one cause — the bare
        // intrinsic-height NSTextView. Its text container is
        // zero-width until `sizeThatFits` pins it, so any layout pass
        // that asked for an ideal size instead of proposing a width
        // got AppKit's fitting size: the narrowest layout the text
        // admits, one hyphenated word per line in a ~55pt ribbon down
        // the left of a full-width card. And a 400-word profile
        // measured taller than the card it was given, so the tail was
        // clipped with no way to reach it. The scrollable variant
        // wraps to its own frame instead. Same move the Summary and
        // Transcript blocks already made.
        //
        // The cap is a backstop, not a reading height: this page
        // already scrolls, so a cap a real profile could reach would
        // put a second scroller inside the first one and swallow the
        // wheel over the card. It sits above any plausible profile and
        // below AppKit's ~16k-pt view-height ceiling, so a pathological
        // imported profile scrolls inside the card rather than being
        // clipped with no way to reach the end.
        ScrollableTextView(
            attributed: summaryAttributedString(
                profile.display,
                compact: true,
                includeStructural: false
            ),
            maxHeight: 4000
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Generation is always for ONE language. With none selected (no
    /// bucket is big enough to name yet) there is nothing to build, so
    /// the button simply isn't offered.
    @ViewBuilder
    private func generateButton(title: LocalizedStringKey, language code: String?) -> some View {
        if let code {
            Button {
                Task { await store.generate(language: code) }
            } label: {
                Text(title)
                    .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.daisyAccent)
            .controlSize(.regular)
        }
    }
}

// VoiceBulletRow removed 2026-07-25 — the profile card now renders
// through summaryAttributedString + SelectableTextView (one continuous
// selectable text body), same as the meeting summary cards.
