//
//  SessionDetailView.swift
//  Daisy
//
//  Detail pane in the History window. Shows summary (if any), full
//  transcript text, screenshots gallery, and actions: re-summarize via
//  the current provider, export markdown, send to Notion / Claude,
//  reveal in Finder, or delete.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SessionDetailView: View {
    /// Initial snapshot — passed in by the caller (the History list).
    /// We don't render from this directly: instead we look the
    /// current value up in SessionStore by ID so the view reacts
    /// when the post-Stop detached task writes summary.json and
    /// SessionStore.reloadSession() replaces the row in-place.
    let initialSession: StoredSession

    /// Always-current session row. Falls back to the initial
    /// snapshot if the store hasn't loaded yet (cold launch into
    /// History view) or the session was deleted out from under us.
    private var session: StoredSession {
        SessionStore.shared.sessions
            .first(where: { $0.id == initialSession.id }) ?? initialSession
    }

    /// True while the post-Stop detached task is still running for
    /// this session — drives the skeleton placeholder in the
    /// summary slot until summary.json lands and SessionStore swaps
    /// in a fresh `StoredSession` with `summary != nil`.
    private var isSummaryGenerating: Bool {
        SessionStore.shared.sessionsGenerating.contains(initialSession.id)
    }

    /// True while the summary is being (re)generated — the post-Stop
    /// auto-summary OR a manual Re-summarize. Drives the inline progress
    /// banner + dims the stale summary. Excludes the follow-up draft (that
    /// keeps the summary visible and shows its own spinner instead).
    private var isResummarizing: Bool {
        isSummaryGenerating || (isRunningAction && !isDraftingFollowUp)
    }

    @State private var isRunningAction = false
    /// Set only while `draftFollowUp()` runs, so the Follow-up section can
    /// show a "Drafting follow-up…" spinner without firing the summary-
    /// level re-summarize banner.
    @State private var isDraftingFollowUp = false
    @State private var confirmDelete = false
    @State private var confirmDeleteAudio = false
    @State private var showRetranscriptionSheet = false
    /// Bumped whenever a Suggest-mode suggestion is confirmed or
    /// dismissed so the Name-the-speakers card re-reads the
    /// `speaker_suggestions.json` sidecar from disk (it's not in the
    /// observable SessionStore — it's a per-session file). Cheap: the
    /// sidecar is a handful of bytes and only re-read on the tick.
    @State private var suggestionRefreshTick = 0
    /// Frame shown by the screen-preview sheet — set by tapping a
    /// `[mm:ss]` stamp in the transcript.
    @State private var previewedScreenshot: PreviewedFrame?
    /// Pending "scroll the transcript to this moment" ask. Carries an id
    /// so asking twice for the same second still moves the pane.
    @State private var transcriptScroll: ScrollableTextView.ScrollRequest?
    /// Position in `session.distinctScreenshots` for the header stepper.
    /// -1 = not started, so the first tap lands on frame 1.
    @State private var screenStep = -1
    /// Frame the strip should scroll to. Set by the stepper and by a
    /// timecode tap, so both keep the two panes pointing at the same
    /// moment.
    @State private var stripTarget: URL?
    /// Local draft for the tag field in the header. Mirrors
    /// `session.tag` and commits to disk on blur / Enter — same
    /// save-on-blur idiom the title editor below uses.
    @State private var tagDraft: String = ""
    @FocusState private var tagFieldFocused: Bool
    /// Presents the tag editor popover anchored to the toolbar tag capsule.
    @State private var showTagPopover = false
    /// Inline-editable session title — mirrors the tag field's draft/commit
    /// pattern so you can rename a recording from the Library header (Egor
    /// 2026-06-16).
    @State private var titleDraft: String = ""
    @FocusState private var titleFieldFocused: Bool
    /// One-shot global flag — once the user has seen + dismissed the
    /// acoustic-loopback explainer for any meeting session, never
    /// show it again on subsequent empty-audio sessions. AppStorage
    /// binds directly to UserDefaults so the change persists across
    /// app launches and SwiftUI re-renders the view automatically
    /// when the flag flips, without us needing to route through
    /// AppSettings (which isn't already plumbed into this view).
    /// The matching definition in AppSettings.swift uses the same
    /// key string so both surfaces read / write the same value.
    @AppStorage("daisy.hasSeenAcousticLoopbackExplainer")
    private var hasSeenAcousticLoopbackExplainer: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                // 2026-05-25 — actionBanner removed in favour of
                // ToastCenter (self-dismissing, global). Egor caught a
                // bug where the banner survived NavigationSplitView's
                // session switch because @State actionStatus belongs
                // to the SwiftUI view (which gets reused across
                // selection changes), not to the session model. Move
                // / re-summarize / copy-markdown outcomes now fire as
                // toasts via the same channel as the inline copy
                // buttons inside CollapsibleBlock — consistent UX and
                // no "ghost banner from previous session" class of bug.
                // Acoustic-loopback banner — gated on three things:
                //   1. system audio for this session was empty (the
                //      frontmatter writes "empty" only on meeting-mode
                //      sessions over 60s, see RecordingSession line
                //      ~1084 — so the meeting-mode filter is already
                //      implicit, but keep it explicit here to be
                //      future-proof against frontmatter writes for
                //      voice notes / dictation in some later release);
                //   2. the user hasn't seen the explainer yet (one-
                //      shot global flag in AppSettings — pre-1.0.6.12
                //      we showed this on every affected session, which
                //      buried users with a wall of identical orange
                //      paragraphs after the 1.0.6.11 update);
                //   3. the user hasn't dismissed it for THIS session
                //      (transient @State — covers the case where they
                //      open the same session twice in one app run).
                //
                // 2026-08-25 — and when we KNOW the reason, we say the
                // reason instead. The banner below is a list of three
                // guesses; `micOnlyNote` names the one cause Daisy
                // actually recorded at capture time, doesn't expire, and
                // doesn't offer a "Got it" that would hide a fact about
                // this specific recording forever.
                if let cause = knownMicOnlyCause {
                    micOnlyNote(cause)
                } else if shouldShowLoopbackBanner {
                    acousticLoopbackBanner
                }

                // 2026-05-25 — two-block collapsible layout per Egor's
                // UX pass on 1.0.7. Pre-fix every mdSection card sat
                // independently in the scroll view, which (a) made the
                // scroll view dense and hard to skim and (b) gave no
                // primary "copy the whole summary" / "copy the whole
                // transcript" affordance — users had to walk every card
                // with manual selection, which itself was broken for
                // long transcripts (see SelectableTextView header).
                // Now: outer CollapsibleBlock groups the LLM-derived
                // content (Meeting / sections / Next actions / Follow-up
                // / screenshots) under "Summary"; raw verbatim audio
                // transcript stays in its own "Transcript" block. Each
                // block remembers its expanded state in @AppStorage so
                // a user who lives in transcripts and rarely reads the
                // summary (or vice versa) doesn't have to re-collapse
                // every session open.
                let hasSummary = session.summary != nil || isSummaryGenerating
                if hasSummary || session.hasScreenshots {
                    CollapsibleBlock(
                        title: summaryBlockTitle,
                        storageKey: "daisy.session.detail.summaryExpanded",
                        copyLabel: String(localized: "Copy summary"),
                        copyText: summaryCopyText,
                        showsCopy: session.summary != nil
                    ) {
                        VStack(alignment: .leading, spacing: 18) {
                            // 2026-05-26 — three cases:
                            //  (a) Fresh-generate (no prior summary):
                            //      isSummaryGenerating == true,
                            //      session.summary == nil → render
                            //      skeleton, that's it.
                            //  (b) Re-summarize over existing: both
                            //      true → render the inline progress
                            //      bar AND the existing (now stale)
                            //      summary at reduced opacity. Old
                            //      summary stays visible so the user
                            //      has a reference, and the bar is
                            //      the "yes, we got your click,
                            //      something is happening" signal.
                            //      Pre-fix the existing summary just
                            //      sat there with no indication —
                            //      Egor reported it as "не видно
                            //      прогресса что что-то запустилось".
                            //  (c) Stable: !isSummaryGenerating,
                            //      summary != nil → plain summary.
                            if isResummarizing && session.summary != nil {
                                resummarizingBanner
                            }
                            if let summary = session.summary {
                                summarySection(summary)
                                    .opacity(isResummarizing ? 0.45 : 1.0)
                                    .animation(.easeInOut(duration: 0.2), value: isResummarizing)
                            } else if isResummarizing {
                                summarySkeletonSection
                            }
                            if session.hasScreenshots { screenshotsSection }
                        }
                    }
                }
                // Follow-up — its OWN accordion with its own copy button
                // (Egor 2026-06-16), just like Transcript. Shown once there's
                // a summary with real content; empty → plaque + Draft CTA,
                // drafting → spinner.
                if let summary = session.summary, showFollowUpBlock(summary) {
                    CollapsibleBlock(
                        title: String(localized: "Follow-up"),
                        storageKey: "daisy.session.detail.followUpExpanded",
                        copyLabel: String(localized: "Copy follow-up"),
                        copyText: { session.summary?.clientFollowUp ?? "" },
                        showsCopy: !(session.summary?.clientFollowUp.isEmpty ?? true)
                    ) {
                        followUpSection(summary)
                    }
                }
                if !(session.meetingPreparation?.planItems.isEmpty ?? true) {
                    MeetingPlanAnalysisView(session: session)
                }
                if session.transcriptURL != nil, session.contentState != .inCloud {
                    CollapsibleBlock(
                        title: "Transcript",
                        storageKey: "daisy.session.detail.transcriptExpanded",
                        copyLabel: "Copy transcript",
                        copyText: { mappedTranscriptText },
                        accessory: { screenStepper }
                    ) {
                        transcriptSection
                    }
                } else {
                    folderContentStateCard
                }

                // Audio lives at the very bottom (Egor 2026-08-21) —
                // playback is a secondary affordance next to the summary
                // and transcript above.
                if retainedAudioFiles.hasAny || session.transcriptURL != nil {
                    audioPlaybackBlock
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Action buttons live in the window toolbar's trailing zone,
        // at the same vertical level as the Daisy brand pill on the
        // leading side. macOS 26 Liquid Glass wraps each ToolbarItem
        // in its own pill automatically — visual grammar matches the
        // Daisy mark + title pill on the left.
        .toolbar { detailToolbar }
        .alert("Delete this session?",
               isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await deleteSession() }
            }
        } message: {
            Text("Audio, transcript, summary and screenshots will be removed from disk. This can't be undone.")
        }
        .alert("Delete audio files for this recording?",
               isPresented: $confirmDeleteAudio) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                deleteRetainedAudio()
            }
        } message: {
            Text("The audio tracks move to the Trash. The transcript, summary and screenshots stay.")
        }
        // A sheet rather than a popover: the strip's 160pt thumbnails are
        // too small to read a slide off, and a popover anchored to a
        // click inside an NSTextView has nothing stable to attach to.
        .sheet(item: $previewedScreenshot) { frame in
            screenPreview(frame.url)
        }
        .sheet(isPresented: $showRetranscriptionSheet) {
            SessionRetranscriptionSheet(session: session)
        }
    }

    // MARK: - Screen stepper

    /// Walks the meeting by what was SHOWN: each tap moves to the next
    /// new screen and takes the transcript with it.
    ///
    /// Deliberately steps `distinctScreenshots` rather than every frame.
    /// An hour of capture is ~60 shots of which maybe eight are actually
    /// a new screen; stepping sixty near-identical slides is a slideshow,
    /// stepping eight is browsing. (When OCR found nothing legible —
    /// a video, a grid of faces — `distinctScreenshots` falls back to
    /// every frame, so the control still works, just less sharply.)
    ///
    /// Its presence is itself the signal that this session has pictures.
    /// No frames, or no timeline index, and there's no button at all
    /// rather than a dead one.
    @ViewBuilder
    private var screenStepper: some View {
        let frames = session.hasScreenTimeline ? session.distinctScreenshots : []
        if !frames.isEmpty {
            Button {
                advanceScreenStep(frames)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "photo")
                        .font(.caption)
                    // Position, the way a pinned-message bar shows it —
                    // without it there's no way to tell where you are or
                    // that the list has wrapped.
                    // `verbatim`: a bare counter isn't translatable text,
                    // and letting it extract as "%lld/%lld" invites a
                    // translation that reorders the two numbers.
                    Text(verbatim: "\(max(screenStep, 0) + 1)/\(frames.count)")
                        .font(.caption.monospacedDigit())
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(String(localized: "Jump to the next screen shown"))
        }
    }

    private func advanceScreenStep(_ frames: [URL]) {
        guard !frames.isEmpty else { return }
        let next = (screenStep + 1) % frames.count
        screenStep = next
        let frame = frames[next]
        stripTarget = frame
        guard let seconds = session.offset(of: frame) else { return }
        // A fresh id every time, so tapping through frames that share a
        // transcript line still counts as a new request.
        transcriptScroll = ScrollableTextView.ScrollRequest(
            id: (transcriptScroll?.id ?? 0) + 1,
            seconds: seconds
        )
    }

    // MARK: - Screen preview

    @ViewBuilder
    private func screenPreview(_ url: URL) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                if let timecode = ScreenshotIndex.timecode(
                    for: url, offsets: session.screenshotOffsets
                ) {
                    Text("On screen at \(timecode)")
                        .font(.headline)
                }
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.daisyTextPrimary)
                Button("Done") { previewedScreenshot = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)

            Divider()

            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                ProgressView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(14)
        }
        .frame(minWidth: 720, idealWidth: 1_000, minHeight: 480, idealHeight: 700)
    }

    // MARK: - Toolbar items (top-right corner of window)

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        // macOS 26 Liquid Glass sizing rule (load-bearing — read before
        // touching either pill): a toolbar control gets its OWN auto-fitted
        // glass capsule ONLY when it draws its own background, i.e. the
        // DEFAULT button/menu style. That capsule wraps the control's whole
        // label *including internal padding*, so padding on the label widens
        // the PILL. A `.borderless`/`.borderlessButton` style suppresses that
        // background; the control then borrows the enclosing container's
        // glass and its label padding is absorbed as layout margin OUTSIDE
        // the pill — which only widens the GAP, never the capsule. (That was
        // the long-standing ⋯ bug: borderlessButton + ToolbarItemGroup +
        // .fixedSize() made `.padding(.horizontal,24)` read as a gap, not
        // width.) Both items below therefore use their OWN ToolbarItem with
        // the DEFAULT style and pad the LABEL.
        //
        // Summarize is the primary action — its own capsule with a WORD
        // label (Egor, 2026-06-13), not a bare sparkle peer of copy/more.
        // Plain-text `Button` title (no `systemImage`) keeps the WORD visible
        // rather than collapsing to icon-only — that collapse is why the old
        // `Label` showed only the sparkle. So: text title + default style =
        // proper text pill.
        // Pin the three detail-section controls to the TRAILING edge of the
        // detail column's toolbar section (window right edge), where they lived
        // in the old 2-column layout. In the genuine 3-column
        // NavigationSplitView each column owns its own toolbar section; inside
        // the detail section the `.primaryAction` items resolve to the section's
        // LEADING edge (just right of the list/detail divider, next to the Tags
        // pill) because nothing in the detail section reserves leading space for
        // them to push against — there's no principal/title content here, and
        // the pre-26 implicit flexible spacer that used to trail-align
        // primaryAction no longer spans an individual column section.
        //
        // macOS 26 replaces that implicit spacer with an explicit one:
        // `ToolbarSpacer(.flexible)` is greedy space that consumes the
        // section's free width. Declared FIRST in the primaryAction region, it
        // pushes the whole group to the section's trailing edge. `.flexible`
        // draws NO glass and is NOT an item, so it doesn't disturb each
        // control's own default-style capsule (all three pills survive) and it
        // doesn't touch the list/sidebar sections. Declaration order after the
        // spacer is preserved, so the visual order stays tag → Summarize → ⋯.
        // macOS 26 only — pre-26 the implicit primary-action spacer already
        // trailing-pins these, and `ToolbarSpacer` doesn't exist there.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }
        // Tag capsule — leftmost of the primary-action cluster, so it
        // sits to the LEFT of Summarize (declaration order = left→right).
        ToolbarItem(placement: .primaryAction) {
            tagToolbarButton
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                attemptReSummarize()
            } label: {
                // While a summary is being (re)generated the button shows a
                // spinner + "Summarizing…" — the main "loader when creating a
                // summary" affordance, visible even if the Summary block is
                // collapsed (Egor 2026-06-16). Horizontal inset gives the
                // label room from the pill's edges.
                if isResummarizing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Summarizing…")
                    }
                    .padding(.horizontal, 10)
                } else {
                    Text("Summarize")
                        .padding(.horizontal, 10)
                }
            }
            .disabled(isRunningAction || session.transcriptURL == nil)
            .help("Re-summarize via current provider")
        }
        // ⋯ overflow menu — its OWN ToolbarItem (NOT a ToolbarItemGroup) so,
        // exactly like Summarize, the default-styled control draws its own
        // Liquid Glass capsule that auto-fits around the padded label. The
        // standalone Copy button was removed (Egor 2026-06-16 — its
        // both-flavours behaviour read as ambiguous next to Summarize);
        // single-flavour copies live in this ⋯ menu.
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Menu {
                    ForEach(FolderStore.shared.allFolders) { f in
                        Button {
                            Task { await moveTo(folder: f) }
                        } label: {
                            if f.slug == session.folderSlug {
                                Label(f.name, systemImage: "checkmark")
                            } else {
                                Text(f.name)
                            }
                        }
                    }
                } label: {
                    Label("Move to folder…", systemImage: "folder")
                }
                Divider()
                Button {
                    showRetranscriptionSheet = true
                } label: {
                    Label(
                        session.transcriptURL == nil
                            ? String(localized: "Transcribe audio")
                            : String(localized: "Re-transcribe"),
                        systemImage: "waveform.badge.magnifyingglass"
                    )
                }
                .disabled(!retainedAudioFiles.hasAny || SessionAudioProcessing.shared.isRunning)
                Button {
                    exportRetainedAudio()
                } label: {
                    Label("Export audio", systemImage: "square.and.arrow.up")
                }
                .disabled(!retainedAudioFiles.hasAny || SessionAudioProcessing.shared.isRunning)
                Divider()
                // Per-section copies (Egor 2026-06-17). Each copies that
                // section as plain markdown — the SAME text the matching
                // accordion's copy button produces (summaryCopyText is
                // body-only; follow-up + transcript reuse the accordion
                // closures). "Copy all" is the whole session. The old two
                // single-flavor items (Copy as Markdown / Copy for
                // Obsidian) were dropped: the only difference was a YAML
                // frontmatter block, too subtle to warrant two entries —
                // Daisy's routing handles vault filing.
                Button {
                    copySection(summaryCopyText(), label: "Summary")
                } label: {
                    Label("Copy Summary", systemImage: "doc.on.doc")
                }
                .disabled(session.summary == nil)
                Button {
                    copySection(session.summary?.clientFollowUp ?? "", label: "Follow-up")
                } label: {
                    Label("Copy Follow-up", systemImage: "arrowshape.turn.up.right")
                }
                .disabled(session.summary?.clientFollowUp.isEmpty ?? true)
                Button {
                    copySection(mappedTranscriptText, label: "Transcript")
                } label: {
                    Label("Copy Transcript", systemImage: "text.alignleft")
                }
                .disabled(session.transcriptText.isEmpty)
                Divider()
                Button {
                    copyPlainMarkdown(includeFrontmatter: false)
                } label: {
                    Label("Copy all", systemImage: "doc.plaintext")
                }
                .disabled(session.transcriptText.isEmpty)
                Divider()
                Button {
                    Task { await sendToNotion() }
                } label: {
                    Label("Send to Notion", systemImage: "doc.text")
                }
                Button {
                    sendToClaude()
                } label: {
                    Label("Send to Claude", systemImage: "sparkles")
                }
                mcpIntegrationsMenuItems
                Divider()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([session.directoryURL])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                Divider()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                toolbarIcon("ellipsis")
            }
            // DEFAULT menu style (do NOT set `.borderlessButton`): only the
            // default style draws the control's own Liquid Glass background,
            // and that capsule wraps the label INCLUDING toolbarIcon's
            // horizontal padding — which is what actually widens the pill.
            // `.borderlessButton` suppressed that background, so the old
            // padding leaked into the inter-item gap instead of the capsule.
            // `.menuIndicator(.hidden)` hides the default style's disclosure
            // chevron so the pill holds just the centred ⋯ glyph. No
            // `.fixedSize()` — its only job was collapsing the borderless
            // chevron's phantom width; with the indicator hidden and this as
            // its own item, it's unneeded and would re-pin the label to its
            // intrinsic size, defeating the padding.
            .menuIndicator(.hidden)
            // Menu in a macOS 26 toolbar inherits `.tint` for its label
            // glyph — bypasses Image.foregroundStyle. Pin the tint locally so
            // the ellipsis matches the other toolbar text instead of going
            // orange via the inherited accent.
            .tint(Color.daisyTextPrimary)
        }
    }

    // MARK: - Action attempts (with toast feedback)

    /// Wraps reSummarize with pre-condition checks. When click
    /// can't proceed (no transcript / no provider), shows a toast
    /// so the user sees explicit feedback instead of a dead-button
    /// no-op.
    private func attemptReSummarize() {
        if isRunningAction {
            ToastCenter.shared.show(String(localized: "Already running — wait a moment"), style: .info)
            return
        }
        if session.transcriptText.isEmpty {
            ToastCenter.shared.show(String(localized: "No transcript to summarize yet"), style: .warning)
            return
        }
        Task { await reSummarize() }
    }

    /// Lighter sibling of `attemptReSummarize` — runs the LLM call
    /// but only merges the new `clientFollowUp` back into the
    /// existing summary. Used by the Follow-up empty-state plaque
    /// when the LLM judged the conversation as internal on the
    /// first pass and the user wants Daisy to take another shot
    /// at drafting just the follow-up. Preserves sections,
    /// actionItems, lede, and any manual edits the user made to
    /// those — Egor pushed back on the original "Re-summarize"
    /// CTA because it re-rolled everything, which felt heavy-
    /// handed for one missing field.
    private func attemptDraftFollowUp() {
        if isRunningAction {
            ToastCenter.shared.show(String(localized: "Already running — wait a moment"), style: .info)
            return
        }
        if session.transcriptText.isEmpty {
            ToastCenter.shared.show(String(localized: "No transcript to draft from yet"), style: .warning)
            return
        }
        Task { await draftFollowUp() }
    }

    /// Uniform toolbar icon. `Color.daisyTextPrimary` is an explicit
    /// black/cream-warm depending on appearance — bypasses macOS 26's
    /// Liquid Glass tint inheritance that was washing the icons into
    /// inconsistent grays. `.symbolRenderingMode(.monochrome)` kills
    /// SF Symbols' default multicolor on `sparkles`. Horizontal
    /// padding gives the auto-fitted Liquid Glass pill breathing
    /// room around the glyph instead of hugging the edge.
    /// User-configured MCP integrations — one menu item per enabled
    /// integration. Empty when the user hasn't set anything up;
    /// nothing renders in that case (no spacer Divider).
    @ViewBuilder
    private var mcpIntegrationsMenuItems: some View {
        let store = MCPIntegrationStore.shared
        let enabled = store.enabledIntegrations
        if !enabled.isEmpty {
            Divider()
            ForEach(enabled) { integration in
                Button {
                    Task { await MCPDispatcher.send(integration, for: session) }
                } label: {
                    Label(String(localized: "Send to \(integration.name)"), systemImage: "paperplane")
                }
            }
        }
    }

    /// One toolbar glyph, wrapped in symmetric horizontal padding. The ⋯
    /// Menu that uses this is a DEFAULT-styled control (see `detailToolbar`),
    /// so its own Liquid Glass capsule auto-fits around this padded label —
    /// the padding here is the capsule's interior breathing room, the same
    /// way `.padding(.horizontal, 10)` widens the Summarize pill. The kebab
    /// is the only caller now that Copy was removed, so this only affects ⋯.
    private func toolbarIcon(_ name: String) -> some View {
        Image(systemName: name)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(Color.daisyTextPrimary)
            .font(.body.weight(.medium))
            // Symmetric interior padding so the centred ⋯ glyph sits in a
            // proper capsule instead of a tight rounded square. Now that the
            // menu draws its own default-style glass background (not a
            // borderless control inside a group), this padding genuinely
            // widens the PILL rather than leaking into the inter-item gap.
            .padding(.horizontal, 16)
    }

    // MARK: - Header (title + metadata; actions live in toolbar)

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Untitled", text: $titleDraft)
                .font(.title2.weight(.semibold))
                .textFieldStyle(.plain)
                .focused($titleFieldFocused)
                .lineLimit(1)
                .onSubmit {
                    commitTitle()
                    titleFieldFocused = false
                }
                .onChange(of: titleFieldFocused) { _, isFocused in
                    // Commit on blur so clicking away persists the rename.
                    if !isFocused { commitTitle() }
                }
                .help("Click to rename this recording")
                // Renaming works without a transcript too: SessionStore
                // falls back to renaming the folder itself (2026-08-21,
                // Finder-created/empty folders were stuck with their
                // directory name). Only the LIVE recording is off-limits.
                .disabled(session.id == SessionStore.shared.activeRecordingDirName)
            HStack(spacing: 8) {
                Text(formattedDate)
                Text("·")
                Text(formattedDuration)
                // Header used to surface two more chips here:
                //   • transcription locale ("AUTO" / "EN" / "RU"),
                //     already controlled in Settings → Transcription
                //     and doesn't change anything the user sees in
                //     the transcript itself;
                //   • a `speaker.wave.2` icon flagging that system
                //     audio was captured — read as cryptic visual
                //     debt, since the user already knows they
                //     recorded a meeting (the title literally says
                //     "Meeting 2026-…").
                // Removed in 1.0.6.4 — header now stays date · duration.
                // Tag moved to a toolbar capsule (left of Summarize) on
                // 2026-06-20 (Egor) — see `tagToolbarButton`.
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onAppear {
            tagDraft = session.tag
            titleDraft = session.title
        }
        .onChange(of: session.id) { _, _ in
            tagDraft = session.tag
            titleDraft = session.title
            // The detail pane is presented without an `.id`, so switching
            // sessions in the Library REUSES this view and every @State
            // survives. Screen-navigation state must not: every session
            // numbers its frames from `001`, so a preview left open would look
            // up its filename in the NEW session's index and print a
            // timecode from a different recording — confidently wrong,
            // which is the failure mode this whole feature exists to avoid.
            screenStep = -1
            stripTarget = nil
            previewedScreenshot = nil
            transcriptScroll = nil
        }
        .onChange(of: session.tag) { _, newValue in
            // External edit (e.g., from another window or a future
            // bulk tagging path) — reflect in the field unless the
            // user is actively editing it.
            if !tagFieldFocused { tagDraft = newValue }
        }
        .onChange(of: session.title) { _, newValue in
            // External title change (MCP set_session_title, or the
            // post-stop auto-title) — reflect unless the user is editing.
            if !titleFieldFocused { titleDraft = newValue }
        }
    }

    /// The cause Daisy actually recorded for this session, when it knows
    /// one. Unknown / future raw values read as nil, so an older build
    /// opening a newer transcript falls back to the generic banner
    /// instead of showing nothing.
    private var knownMicOnlyCause: MicOnlyCause? {
        session.micOnlyCause.flatMap(MicOnlyCause.init(rawValue:))
    }

    /// "Microphone only" marker for a meeting where Daisy KNOWS why the
    /// other side is missing.
    ///
    /// Not dismissible, unlike `acousticLoopbackBanner`, and that is the
    /// whole point of it. The banner teaches a general macOS behaviour
    /// once per device and is then correctly gone forever; this is a
    /// per-session fact about THIS recording, and a user who dismissed
    /// the explainer months ago still needs to know that the call they
    /// are reading is half a conversation. Every other place it was
    /// said — the start-time toast, the widget pill — expired the day it
    /// was recorded.
    ///
    /// One line, no icon column, no button: it has to survive being seen
    /// on every visit for the rest of the session's life, so it is
    /// sized as a caption, not as an alert.
    private func micOnlyNote(_ cause: MicOnlyCause) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "speaker.slash")
                .foregroundStyle(Color.daisyAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Microphone only")
                    .foregroundStyle(.secondary)
                Text(micOnlyExplanation(cause))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.daisyAccent.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func micOnlyExplanation(_ cause: MicOnlyCause) -> String {
        let text: String = switch cause {
        case .screenRecordingDenied:
            String(localized: "Screen Recording permission was off while this was recorded, so the other side of the call wasn’t captured.")
        case .systemAudioFailed:
            String(localized: "Daisy couldn’t capture the other side of this call, so only your microphone was recorded.")
        }
        return text
    }

    @ViewBuilder
    private var folderContentStateCard: some View {
        let state = session.contentState
        let headline: String = switch state {
        case .audioOnly: String(localized: "Audio without transcript")
        case .inCloud: String(localized: "Stored in iCloud")
        default: String(localized: "Empty recording folder")
        }
        let explanation: String = switch state {
        case .audioOnly:
            String(localized: "The audio is still on disk. You can create a transcript from it or reveal the folder in Finder.")
        case .inCloud:
            String(localized: "macOS moved this recording's files to iCloud to free up disk space. Download them to view the recording — this needs enough free disk space and may take a while.")
        default:
            String(localized: "Daisy found this folder in your recordings storage, but it does not contain audio or a transcript. It remains visible until you delete it.")
        }
        // Text-only card — no leading icon column (Egor 2026-08-21:
        // consistency with the other blocks' empty states).
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                Text(headline)
                    .font(.headline)
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if state == .audioOnly {
                        Button("Transcribe audio") {
                            showRetranscriptionSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(SessionAudioProcessing.shared.isRunning)
                    }
                    if state == .inCloud {
                        Button("Download from iCloud") {
                            Self.downloadEvictedFiles(in: session.directoryURL)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([session.directoryURL])
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Ask the system to materialize every evicted file in the session
    /// folder. Fire-and-forget: downloads proceed in the FileProvider
    /// daemon; the Library's storage monitor picks up the change and the
    /// row flips back to a normal session once files are local.
    nonisolated private static func downloadEvictedFiles(in directory: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return }
        for case let url as URL in enumerator {
            guard SessionStore.isCloudEvicted(url) else { continue }
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
    }

    /// Toolbar capsule (left of Summarize) that opens the tag editor in a
    /// popover. Shows the current tag, or "Add tag…" when untagged. Uses
    /// the DEFAULT button style so it draws its own Liquid Glass capsule
    /// like the Summarize pill (a borderless style would suppress the
    /// pill — see the toolbar notes). Moved out of the header row
    /// 2026-06-20 (Egor).
    @ViewBuilder
    private var tagToolbarButton: some View {
        Button {
            tagDraft = session.tag
            showTagPopover = true
        } label: {
            Text(session.tag.isEmpty ? String(localized: "Add tag") : session.tag)
                .lineLimit(1)
                .padding(.horizontal, 10)
        }
        .help("Tag this recording")
        .popover(isPresented: $showTagPopover, arrowEdge: .bottom) {
            tagPopoverContent
        }
    }

    /// Tag editor in the toolbar capsule's popover: a free-text field
    /// (type + Enter creates a new tag) plus the list of tags already in
    /// use across the store, and a Remove option when tagged.
    ///
    /// Commit model (avoids the 2026-05-26 focus-popover race): the field
    /// commits only on Enter; a suggestion / Remove commits explicitly and
    /// closes; `.onDisappear` commits the typed draft for the click-away
    /// case. `commitTag()` no-ops when the value is unchanged, so the
    /// overlapping calls are harmless.
    @ViewBuilder
    private var tagPopoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Tag…", text: $tagDraft)
                .textFieldStyle(.roundedBorder)
                .focused($tagFieldFocused)
                .frame(width: 200)
                .onSubmit {
                    commitTag()
                    showTagPopover = false
                }

            let allTags = SessionStore.shared.distinctTagsByFrequency
            if !allTags.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(allTags, id: \.self) { name in
                            Button {
                                tagDraft = name
                                commitTag()
                                showTagPopover = false
                            } label: {
                                HStack {
                                    Text(name)
                                    Spacer()
                                    if name == session.tag {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            if !session.tag.isEmpty {
                Divider()
                Button(role: .destructive) {
                    tagDraft = ""
                    commitTag()
                    showTagPopover = false
                } label: {
                    Text("Remove tag")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 220)
        .onAppear { tagFieldFocused = true }
        .onDisappear { commitTag() }
    }

    private func commitTag() {
        let trimmed = tagDraft.trimmingCharacters(in: .whitespaces)
        guard trimmed != session.tag else { return }
        Task { await SessionStore.shared.setTag(trimmed, for: session) }
    }

    private func commitTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty title would make the session unreadable in lists — revert.
        guard !trimmed.isEmpty else {
            titleDraft = session.title
            return
        }
        guard trimmed != session.title else { return }
        Task { await SessionStore.shared.setTitle(trimmed, for: session) }
    }


    // MARK: - Summary

    /// Placeholder shown above the transcript while the post-Stop
    /// detached summarize task is still running. Replaced in-place
    /// by `summarySection(...)` once `summary.json` lands and
    /// `SessionStore.reloadSession(id:)` flips the row to carry a
    /// non-nil `MeetingSummary`. Three rows mirror the real
    /// document layout (Meeting / Next actions / Follow-up) so the
    /// transition reads as "content arriving" rather than "layout
    /// shift".
    /// Inline progress bar shown ABOVE an existing summary while
    /// a re-summarize is in flight. Reused for the re-summarize
    /// case where session.summary is non-nil but generation is
    /// happening again; the existing summary stays visible at
    /// reduced opacity so the user has a reference, and this
    /// banner is the "yes, your click registered, something is
    /// cooking" affordance. Without it the existing summary just
    /// sat there with no feedback for the 5–20s of generation.
    @ViewBuilder
    private var resummarizingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Re-summarizing…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.daisyBgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder
    private var summarySkeletonSection: some View {
        mdSection(title: "Meeting") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Generating summary… transcript is ready below.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        mdSection(title: "Next actions") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<2, id: \.self) { _ in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "square")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.daisyDivider)
                            .frame(height: 12)
                            .frame(maxWidth: .infinity)
                            .opacity(0.6)
                    }
                }
            }
        }
    }

    // Summary rendered as a plain MD-style document — no coloured AI
    // card, no sparkles header, no border. The user reads this like a
    // normal write-up: headers, body text, bullets.
    //
    // 2026-06-12 — the whole textual body (Meeting lede + Granola-style
    // sections + Next actions + Follow-up draft, headers included) is
    // now ONE attributed string inside ONE NSTextView. Before, every
    // block was its own SwiftUI `Text` with `.textSelection(.enabled)`,
    // and macOS selection can't cross view boundaries — drag-select /
    // ⌘A in the summary topped out at a single line (Egor, release
    // blocker). Same fix the transcript got on 2026-05-25; see
    // summaryAttributedString(_:compact:) in SelectableTextView.swift
    // for the exact content/typography mirror (including the legacy
    // `sections == []` paragraph fallback).
    //
    // Only the follow-up's INTERACTIVE chrome stays as SwiftUI views
    // below the text — an NSTextView can't host controls inline:
    //   • drafting: the draft leaves the text body, spinner section
    //     shows in its place (same swap the old card did);
    //   • present: copy-draft button as a trailing footer row (was a
    //     corner overlay on the old standalone follow-up Text);
    //   • empty: the "model judged this internal" plaque under its
    //     localised header, exactly as before.
    @ViewBuilder
    private func summarySection(_ summary: MeetingSummary) -> some View {
        // Body only — lede + topical sections + next actions. The follow-up
        // draft is its OWN accordion now (Egor 2026-06-16), so strip it here.
        let bodySummary = MeetingSummary(
            summary: summary.summary,
            sections: summary.sections,
            actionItems: summary.actionItems,
            clientFollowUp: ""
        )
        // ScrollableTextView (not SelectableTextView) 2026-06-25: the bare
        // intrinsic-height NSTextView mis-measured tall multi-section summaries
        // on macOS 26 (usedRect under-report > the 1-line slack), so the bottom
        // of a long summary was clipped under the card with no way to scroll to
        // it (Egor). The scrollable variant lays the document out to full
        // height internally and caps the visible pane — short summaries sit
        // flush, long ones scroll inside the card. Same approach as Transcript.
        ScrollableTextView(
            attributed: summaryAttributedString(bodySummary, compact: false),
            maxHeight: 720
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Whether the Follow-up accordion shows: there's a draft, one is being
    /// drafted, or the summary has real content (→ empty-state plaque + CTA).
    /// Hidden for a no-content summary (e.g. the "no speech captured"
    /// sentinel) where there's nothing to follow up on.
    private func showFollowUpBlock(_ summary: MeetingSummary) -> Bool {
        let hasContent = !summary.sections.isEmpty || !summary.actionItems.isEmpty
        return !summary.clientFollowUp.isEmpty || isDraftingFollowUp || hasContent
    }

    /// Content of the Follow-up accordion: the draft message, a drafting
    /// spinner, or the empty-state plaque. Copy is served by the block's own
    /// header button now (no inline copy button here anymore).
    @ViewBuilder
    private func followUpSection(_ summary: MeetingSummary) -> some View {
        if !summary.clientFollowUp.isEmpty && !isDraftingFollowUp {
            // ScrollableTextView (2026-06-25): same macOS-26 mis-measure that
            // clipped the summary clipped long follow-ups under the card. The
            // scrollable variant sizes to content up to a cap, then scrolls
            // internally — short follow-ups sit flush, long ones stay reachable.
            ScrollableTextView(summary.clientFollowUp, maxHeight: 600)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if isDraftingFollowUp {
            // Drafting in flight — visible spinner so the user sees the click
            // registered (previously only a toast fired).
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Drafting follow-up…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Empty follow-up but real content: the model judged the
            // conversation internal — surface that + a one-click re-roll.
            followUpEmptyStatePlaque
        }
    }

    /// Renders inside the Follow-up mdSection when the LLM returned
    /// an empty `clientFollowUp` — typically because the model judged
    /// the conversation as a purely internal team sync with no
    /// external party that warrants a follow-up message. The plaque
    /// surfaces the decision (instead of silently dropping the
    /// section) and offers a Re-summarize CTA so the user can re-roll
    /// if they think the model misread the context.
    @ViewBuilder
    private var followUpEmptyStatePlaque: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.body)
                .foregroundStyle(.tertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 8) {
                Text("No follow-up was drafted — the model treated this conversation as internal (no external party identified).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // 2026-05-26 — button used to call attemptReSummarize()
                // (a full summary regenerate), which Egor flagged as
                // too heavy for one missing field — would also blow
                // away any manual edits the user made to the rest of
                // the summary. attemptDraftFollowUp() runs the same
                // LLM call but only merges the new `clientFollowUp`
                // into the existing summary; the lede, sections, and
                // actionItems stay untouched. Toast feedback
                // explicitly tells the user when the model still
                // judged the conversation as internal on the second
                // pass, so the empty result reads as a deliberate
                // model decision rather than a silent no-op.
                Button("Draft follow-up") {
                    attemptDraftFollowUp()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Color.daisyTextPrimary)
                .disabled(isSummaryGenerating)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.daisyBgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
        )
    }

    /// Detect the summary's output language from its own content so
    /// our structural headers ("Meeting" / "Next actions" / "Follow-
    /// up") match. We sample `summary.summary + first 200 chars of
    /// first section bullet` rather than picking up from a frontmatter
    /// field because pre-1.0.2 sessions don't carry the language
    /// anywhere. LanguageDetector returns nil on too-short / low-
    /// confidence input → falls through to English defaults, which
    /// is the same behaviour as a legacy English session.
    private func summaryLabels(for summary: MeetingSummary) -> SummaryLabels {
        var sample = summary.summary
        if sample.count < 60, let firstBullet = summary.sections.first?.bullets.first?.text {
            sample += " " + firstBullet
        }
        return SummaryLabels.for(language: LanguageDetector.detect(sample))
    }

    /// Document-style section: H2-weight heading, hairline rule under
    /// it, body content. Used for Meeting / Next actions / Follow-up /
    /// Transcript so the whole detail view reads as a single MD doc.
    @ViewBuilder
    private func mdSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.daisyTextPrimary)
                Rectangle()
                    .fill(Color.daisyDivider)
                    .frame(height: 0.5)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Screenshots

    private var screenshotsSection: some View {
        mdSection(title: String(localized: "Screenshots (\(session.screenshotURLs.count))")) {
            screenshotStrip
        }
    }

    private var screenshotStrip: some View {
        ScrollViewReader { proxy in
            screenshotRow
                // Keeps the picture and the words pointing at the same
                // moment: the stepper moves both panes, so the frame is
                // on screen by the time the transcript lands on its line.
                .onChange(of: stripTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
        }
    }

    private var screenshotRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(session.screenshotURLs, id: \.self) { url in
                    VStack(alignment: .leading, spacing: 4) {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.gray.opacity(0.2)
                        }
                        .frame(width: 160, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        // Where the frame sits on the recording's
                        // timeline, on the same clock as the transcript's
                        // [mm:ss] markers — which is the whole point:
                        // read a moment in the transcript, find the
                        // picture. Absent for sessions recorded before
                        // the index existed.
                        if let timecode = ScreenshotIndex.timecode(
                            for: url, offsets: session.screenshotOffsets
                        ) {
                            Text(timecode)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .id(url)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                stripTarget == url ? Color.daisyHomeAccent : .clear,
                                lineWidth: 2
                            )
                    )
                    // Double first: SwiftUI resolves the higher count
                    // before falling back to the single tap. Belt and
                    // braces below — if arbitration ever swallows the
                    // double-tap, opening the frame is still reachable.
                    .contextMenu {
                        Button("Open Screenshot") { NSWorkspace.shared.open(url) }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .onTapGesture(count: 2) {
                        NSWorkspace.shared.open(url)
                    }
                    // The reverse trip — saw the slide, want the words.
                    .onTapGesture {
                        stripTarget = url
                        guard let seconds = session.offset(of: url) else { return }
                        transcriptScroll = ScrollableTextView.ScrollRequest(
                            id: (transcriptScroll?.id ?? 0) + 1,
                            seconds: seconds
                        )
                    }
                }
            }
        }
    }

    // MARK: - Transcript

    private var transcriptSection: some View {
        // 2026-05-25 — mdSection title wrapper removed; the outer
        // CollapsibleBlock now owns the "Transcript" header + copy
        // button. We keep the speaker-mapping card and empty-state
        // text identical to pre-fix.
        //
        // Transcript body switched from SwiftUI `Text(...).textSelection`
        // to SelectableTextView (NSTextView wrapper) to fix the bug
        // Egor reported the same day: drag-select only covered the
        // current viewport on long transcripts, ⌘A inside Text was
        // similarly clipped. SelectableTextView puts the full string
        // into the AppKit text system, which has correct full-content
        // selection + ⌘F search. See SelectableTextView header for
        // the why.
        VStack(alignment: .leading, spacing: 12) {
            speakerMappingSection

            // Gate on the DISPLAYED body, not the raw file: an empty
            // recording still has a `# title` / `> recorded …` / `## Transcript`
            // doc header on disk, so `session.transcriptText` is non-empty
            // while the sliced-out transcript body is "" — which used to
            // render a blank 600pt pane (Egor 2026-07-22). Show an explicit
            // empty-recording note instead.
            if mappedTranscriptText.isEmpty {
                Text("Empty recording — nothing was transcribed")
                    .font(.body)
                    .foregroundStyle(.tertiary)
            } else {
                // A 50-min transcript in one intrinsic-height NSTextView hits
                // AppKit's max view height and clips the bottom unscrollably
                // (Egor 2026-06-16). ScrollableTextView scrolls internally,
                // so give it a bounded pane height. (600pt is a tunable
                // default — can be made window-relative later.)
                ScrollableTextView(
                    mappedTranscriptText,
                    // nil ⇒ no links rendered at all. A session with no
                    // frames, or one recorded before the timeline index
                    // existed, gets a plain transcript rather than
                    // stamps that look clickable and aren't.
                    onTimecodeTap: session.hasScreenTimeline
                        ? { seconds in
                            let frame = session.screenshot(at: seconds)
                            stripTarget = frame
                            previewedScreenshot = frame.map(PreviewedFrame.init)
                        }
                        : nil,
                    scrollRequest: transcriptScroll
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 600)
                    .clipped()
            }
        }
    }

    /// Show "Name speakers" card whenever the transcript has
    /// detected speakers ("Remote A", "Remote B", ...). Previously
    /// gated on `meetingAttendees.isEmpty` — that made the feature
    /// invisible for manual recordings (no calendar event). Now
    /// every diarized session can be renamed; calendar attendees,
    /// when present, become quick-pick suggestions next to the
    /// free-text field.
    @ViewBuilder
    private var speakerMappingSection: some View {
        if !detectedSpeakerInfo.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill")
                        .foregroundStyle(Color.daisyAccent)
                    Text("Name the speakers")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !session.speakerMap.isEmpty {
                        Button("Clear") {
                            Task { await SessionStore.shared.updateSpeakerMap([:], for: session) }
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.daisyTextSecondary)
                    }
                }
                Text("Replace the auto-generated labels with real names. Names propagate to the transcript, the summary's follow-up, and any sent destination.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(detectedSpeakerInfo, id: \.id) { info in
                    SpeakerNameRow(
                        speakerID: info.id,
                        currentName: session.speakerMap[info.id] ?? "",
                        attendeeSuggestions: session.meetingAttendees,
                        attendeeSourceEventTitle: session.linkedEventTitle,
                        segmentCount: info.count,
                        hasCentroid: info.hasCentroid,
                        // Suggest-mode candidate for this label, if Daisy
                        // recognized it but (per the match mode) left it
                        // for the user to confirm. nil in Automatic/Off
                        // or when this label wasn't recognized.
                        suggestion: speakerSuggestions[info.id],
                        suggestionSource: speakerSuggestionSources[info.id],
                        onCommit: { name in
                            Task { await applyMapping(speakerID: info.id, name: name) }
                        },
                        onDismissSuggestion: {
                            Task { await dismissSuggestion(speakerID: info.id) }
                        }
                    )
                }
            }
            // 2026-05-25 — promoted to section-card spec (radius 10,
            // daisyBgSidebar fill, daisyDivider border) per the shape
            // audit. Pre-fix this used the radius-8 banner family with
            // a cinnamon-tinted fill — visual conflation with the
            // acoustic-loopback banner above. This is a containing
            // card holding speaker rows, not an info chip; matching
            // AboutView's three section cards.
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.daisyBgSidebar)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
            )
        }
    }

    /// Speaker IDs ("A", "B", "C") that appear in the transcript body,
    /// annotated with how many segments each one owns and whether
    /// `speakers.json` has a saved voice fingerprint (centroid) for it.
    /// Extracted from `[Remote A]` / `[Remote B]` markers — same
    /// format `MarkdownExporter` writes via `TranscriptSegment.speakerLabel`.
    ///
    /// Sorted by `count` descending so the dominant voice in the
    /// meeting is the first row the user sees — pre-1.0.7.1 this was
    /// alphabetical, which meant a 380-segment "Remote B" sat below a
    /// 17-segment "Remote A" in the UI. New ordering matches the
    /// rename mental model: name the loud one first.
    ///
    /// `hasCentroid` is the new signal in 1.0.7.1 — true when
    /// FluidAudio persisted a voice embedding for this cluster.
    /// Centroidless IDs come from short fragments that didn't form
    /// a clean cluster (the 2026-05-25 tester Sync session saw
    /// Remote D with 17 segments but no centroid — the rename works
    /// for THIS session but can't auto-match future sessions because
    /// there's no fingerprint to compare against). SpeakerNameRow
    /// surfaces this as a "session only" caption so the user knows
    /// the rename isn't building a reusable profile.
    private var detectedSpeakerInfo: [(id: String, count: Int, hasCentroid: Bool)] {
        let pattern = #/\bRemote\s+([A-Z])\b/#
        var counts: [String: Int] = [:]
        for match in session.transcriptText.matches(of: pattern) {
            counts[String(match.1), default: 0] += 1
        }
        return counts
            .map { (id: $0.key, count: $0.value, hasCentroid: session.speakerCentroidIDs.contains($0.key)) }
            .sorted {
                // Primary: occurrence count desc. Secondary: ID asc so
                // ties (rare) get a stable order.
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.id < $1.id
            }
    }

    /// The transcript SECTION only, for the accordion. `transcriptText`
    /// (and the on-disk transcript.md, written by MarkdownExporter) is the
    /// FULL document — `# title`, a `> recorded … · duration` line, the
    /// summary, screenshots, then the transcript under a `## Transcript`
    /// heading. Rendering all of that here duplicated the session header
    /// above (title + date + duration) and the Summary accordion, so slice
    /// out just the transcript (Egor 2026-06-20). Falls back to stripping
    /// the leading title/recorded header when the marker is absent
    /// (MarkdownExporter always writes it today — defensive for legacy /
    /// hand-edited files). `transcriptText` itself is untouched, so search
    /// and the on-disk file keep the full document.
    private var transcriptBodyForDisplay: String {
        let full = session.transcriptText
        // The transcript heading always sits on its own line, after the
        // title/recorded/summary/screenshots. Match `\n## Transcript` so we
        // don't catch a mid-line occurrence and so an empty transcript
        // (heading with nothing after) still resolves to "".
        if let r = full.range(of: "\n## Transcript") {
            return String(full[r.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Self.strippingDocHeader(full)
    }

    /// Drop a leading `# title` heading and a following `> recorded …`
    /// quote (and the blank lines around them) — the part that duplicates
    /// the session header. Fallback only, when no `## Transcript` marker
    /// is present.
    private static func strippingDocHeader(_ body: String) -> String {
        var lines = body.components(separatedBy: "\n")
        if lines.first?.hasPrefix("# ") == true { lines.removeFirst() }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        if lines.first?.hasPrefix("> recorded") == true { lines.removeFirst() }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    /// Substitute "Remote A" → mapped name inline. The on-disk .md
    /// stays in canonical "Remote A" form so the mapping is fully
    /// re-pluggable (just edit `daisy_speaker_map:` in frontmatter).
    private var mappedTranscriptText: String {
        let base = transcriptBodyForDisplay
        guard !session.speakerMap.isEmpty else { return base }
        var text = base
        for (speakerID, name) in session.speakerMap {
            text = text.replacingOccurrences(
                of: "Remote \(speakerID)",
                with: name
            )
        }
        return text
    }

    private func applyMapping(speakerID: String, name: String?) async {
        var updated = session.speakerMap
        if let name {
            updated[speakerID] = name
        } else {
            updated.removeValue(forKey: speakerID)
        }
        await SessionStore.shared.updateSpeakerMap(updated, for: session)

        // Voice fingerprint persistence — when the user assigns a
        // real name to a speaker, look up that speaker's centroid
        // embedding from the session's `speakers.json` sidecar and
        // either create a new SpeakerProfile or update an existing
        // one. Next time the same person joins a recording, Daisy
        // will auto-label them ("Alex" instead of "Remote A").
        //
        // Skipped on "unmap" (name == nil) — we don't delete
        // profiles on clear, only on the explicit "Forget" action
        // in Settings → Speakers.
        guard let name, !name.isEmpty else {
            // A clear also resolves any pending suggestion for this row.
            pruneSuggestion(for: speakerID)
            return
        }
        guard let centroids = loadSpeakerCentroids() else {
            pruneSuggestion(for: speakerID)
            return
        }
        guard let embedding = centroids[speakerID], !embedding.isEmpty else {
            pruneSuggestion(for: speakerID)
            return
        }
        let profile = SpeakerProfileStore.shared.upsert(name: name, embedding: embedding)

        // Calendar-attendee email attach — when this session is bound
        // to an event with EXACTLY ONE attendee email (the 1:1-meeting
        // case, which is where "match this attendee to this voice" is
        // unambiguous), attach that email to the profile the user just
        // named. Future calendar meetings with the same invitee then
        // auto-match this speaker by email even if the voice timbre
        // drifts. We deliberately DON'T guess on multi-attendee events
        // — index alignment between the deduped names + emails arrays
        // isn't reliable; the speaker detail editor in Settings is the
        // explicit path for those.
        if session.meetingAttendeeEmails.count == 1 {
            SpeakerProfileStore.shared.addEmail(session.meetingAttendeeEmails[0], to: profile.id)
        }

        // Naming a speaker resolves its Suggest-mode suggestion.
        pruneSuggestion(for: speakerID)
    }

    // MARK: - Speaker suggestions

    /// Parsed `speaker_suggestions.json` for this session. Re-read
    /// whenever `suggestionRefreshTick` changes. Present in Suggest mode
    /// (where every match is a suggestion) and in Automatic mode when
    /// Daisy has a WEAK candidate it won't auto-apply — a name matched
    /// off the invite, or one inferred from how someone was addressed.
    /// Absent in Off mode. Filtered to labels the user hasn't already
    /// named, so a confirmed row's chip disappears even before the
    /// sidecar prune lands.
    private var speakerSuggestions: [String: String] {
        _ = suggestionRefreshTick  // re-evaluate on tick
        guard let file = loadSpeakerSuggestions() else { return [:] }
        return file.byLabel.filter { session.speakerMap[$0.key] == nil }
    }

    /// Parallel "how was this matched" map (label → "voice"/"email"/…)
    /// for the suggestion chips' caption.
    private var speakerSuggestionSources: [String: String] {
        _ = suggestionRefreshTick
        guard let file = loadSpeakerSuggestions() else { return [:] }
        return file.source
    }

    private func loadSpeakerSuggestions() -> SpeakerSuggestionsFile? {
        let url = session.directoryURL.appendingPathComponent("speaker_suggestions.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SpeakerSuggestionsFile.self, from: data)
    }

    /// User dismissed a suggestion without naming the speaker. Drop it
    /// from the sidecar so it doesn't reappear; leave the label
    /// unnamed (Remote X).
    private func dismissSuggestion(speakerID: String) async {
        pruneSuggestion(for: speakerID)
    }

    /// Remove one label's entry from the suggestions sidecar (on
    /// confirm or dismiss). Deletes the file once empty so a session
    /// with no pending suggestions carries no sidecar. Bumps the tick
    /// so the UI re-reads.
    private func pruneSuggestion(for speakerID: String) {
        let url = session.directoryURL.appendingPathComponent("speaker_suggestions.json")
        defer { suggestionRefreshTick &+= 1 }
        guard var file = loadSpeakerSuggestions() else { return }
        file.byLabel.removeValue(forKey: speakerID)
        file.source.removeValue(forKey: speakerID)
        if file.byLabel.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if let data = try? {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try enc.encode(file)
        }() {
            try? data.write(to: url, options: [.atomic])
        }
    }

    /// Read `speakers.json` from the session's directory. Returns
    /// nil if the sidecar is missing (older sessions recorded before
    /// the voice-fingerprint flow landed) or unreadable. Caller
    /// degrades gracefully — manual rename still works, it just
    /// won't seed a new profile.
    private func loadSpeakerCentroids() -> [String: [Float]]? {
        let url = session.directoryURL.appendingPathComponent("speakers.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let parsed = try? JSONDecoder().decode(SpeakerCentroidsFile.self, from: data) else {
            return nil
        }
        return parsed.centroids
    }

    // MARK: - Status feedback
    //
    // 2026-05-25 — the inline `actionBanner` view that used to live
    // here was removed. It was an inline pill above the session body
    // that surfaced "Markdown copied to clipboard" / "Moved to X" /
    // "Summary updated" messages. Two problems Egor caught in 1.0.7:
    //   1. State lived in `@State actionStatus` belonging to the
    //      SwiftUI view. NavigationSplitView reuses SessionDetailView
    //      across selection changes — so the banner survived session
    //      switches and appeared on sessions where the action never
    //      ran.
    //   2. No auto-dismiss. Required a manual ⨯ click; users left
    //      banners stuck for the entire app session.
    // Replaced by ToastCenter.shared.show(...) at every callsite —
    // self-dismissing, globally rendered above all windows, same
    // channel used by the CollapsibleBlock copy buttons added the
    // same day. Single source of truth for transient feedback.

    /// Gate for the acoustic-loopback banner. True when (a) the
    /// session's frontmatter says system audio capture stayed empty
    /// AND (b) the user hasn't yet dismissed the global explainer.
    /// The frontmatter writer in RecordingSession already gates on
    /// `currentMode == .meeting`, so dictation / voice-note sessions
    /// never get `daisy_system_audio_status: empty` written and
    /// never trigger this banner — meeting-only enforcement is
    /// implicit. Once the user clicks "Got it" the AppStorage flag
    /// flips and SwiftUI re-renders this whole view, hiding the
    /// banner immediately and forever on this device.
    private var shouldShowLoopbackBanner: Bool {
        session.systemAudioStatus == "empty" &&
            !hasSeenAcousticLoopbackExplainer
    }

    /// One-liner explainer for the acoustic-loopback case, shown once
    /// per device on the first empty-system-audio meeting the user
    /// opens. Pre-1.0.6.12 this was a three-paragraph wall of text on
    /// EVERY affected session — a tester whose mac trips the macOS 26
    /// SCStream regression got 50+ identical orange paragraphs across
    /// her library after the 1.0.6.11 update. New shape: a single line
    /// of plain English plus a "Got it" dismiss that sets the global
    /// `hasSeenAcousticLoopbackExplainer` flag. Deeper detail (which
    /// hotkey, how to fix for next time, Tahoe regression context)
    /// stays as the toast that fires once at the end of the session
    /// itself — that's the right moment to give it, not retroactively
    /// every time the user opens an old transcript.
    private var acousticLoopbackBanner: some View {
        // 2026-05-25 — pulled into the same chip family as the three
        // Home banners (permissions / connectCalendar / deniedCalendar).
        // Pre-fix this used raw `.orange` for icon + Got-it pill + chip
        // background + border, with mismatched opacities (0.06 / 0.2)
        // and a stroke (not strokeBorder). End result was a fourth
        // banner shape entirely. Now: cinnamon chip 0.20 fill + 0.20
        // strokeBorder, cinnamon icon, Got it as `.borderedProminent`
        // with the same `frame(minWidth: 88)` as Fix / Connect on the
        // Home banners. Single design family across the app.
        // 2026-05-26 — added secondary "why" caption underneath the
        // headline. Pre-fix the banner only said WHAT ("mic only")
        // without WHY, so the user assumed it was a Daisy bug
        // instead of a known macOS-side acoustic-loopback gap.
        // The three causes listed cover ~95% of empty-system-audio
        // sessions on the tester base — headphone routing bypasses
        // SCStream's loopback path, "no audio actually played"
        // hits standalone monologue/voice-note-style use, and
        // Screen Recording revocation is the silent permission-
        // pulled case Egor saw on his own Mac after a security
        // update flipped it off without a re-prompt.
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "speaker.slash.fill")
                .font(.title3)
                .foregroundStyle(Color.daisyAccent)
                // Align the icon optical baseline with the first
                // line of text now that there are two text rows
                // — without this it floats up against the chip's
                // top padding and reads as detached from the copy.
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Other side wasn't captured this session — mic only")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Common causes: headphones (audio bypasses the loopback path), no app played sound during the meeting, or Screen Recording access was revoked mid-session.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // minWidth on the label, not the Button — see comment on
            // `permissionsAttentionBanner.Fix` in HomeView.swift.
            Button {
                hasSeenAcousticLoopbackExplainer = true
            } label: {
                Text("Got it").frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(Color.daisyAccent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.daisyAccent.opacity(0.20),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.daisyAccent.opacity(0.20), lineWidth: 0.5)
        )
    }

    // MARK: - Actions

    private var retainedAudioFiles: SessionAudioFiles {
        SessionAudioFiles.discover(in: session.directoryURL)
    }

    @ViewBuilder
    private var audioPlaybackBlock: some View {
        let audio = retainedAudioFiles
        CollapsibleBlock(
            title: String(localized: "Audio"),
            storageKey: "daisy.session.detail.audioExpanded",
            copyLabel: "",
            copyText: { "" },
            showsCopy: false,
            accessory: {
                // Same visual grammar as the header copy buttons on the
                // other blocks: borderless, secondary, .callout icons.
                if audio.hasAny {
                    HStack(spacing: 10) {
                        Button {
                            showRetranscriptionSheet = true
                        } label: {
                            Image(systemName: "text.redaction")
                                .font(.callout)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .disabled(SessionAudioProcessing.shared.isRunning)
                        .help("Create a new transcript from this audio")

                        Button {
                            confirmDeleteAudio = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.callout)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Delete audio files")
                    }
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if audio.hasAny {
                    if !audio.microphone.isEmpty {
                        SessionAudioPlayerView(
                            title: String(localized: "Your microphone"),
                            files: audio.microphone
                        )
                    }
                    if !audio.system.isEmpty {
                        if !audio.microphone.isEmpty {
                            Divider()
                        }
                        SessionAudioPlayerView(
                            title: String(localized: "Other side"),
                            files: audio.system
                        )
                    }
                } else {
                    // Text-only, matching the other blocks' empty states
                    // (Egor 2026-08-21: the waveform.slash icon read as
                    // noise; the follow-up plaque set the pattern).
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Audio is no longer stored for this recording.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("To play future recordings here, choose 24 hours, 7 days, 30 days, or Keep forever in Settings → Privacy → Delete audio after.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Move this session's retained audio (all rotated parts, both
    /// tracks) to the Trash. Transcript/summary/screenshots stay; the
    /// block flips to its "audio no longer stored" explainer after the
    /// store refresh. Trash rather than unlink so a misclick is
    /// recoverable — unlike the Settings-wide "Delete audio files"
    /// purge, this sits one click from the player.
    private func deleteRetainedAudio() {
        let audio = retainedAudioFiles
        guard audio.hasAny else { return }
        let ticket = SessionsFolder.acquireAccess(to: session.directoryURL)
        defer { ticket?.release() }
        var failed = false
        for url in audio.all {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                // Container paths can't always reach the Trash — fall
                // back to a plain delete rather than leaving a mix.
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    failed = true
                }
            }
        }
        if failed {
            ToastCenter.shared.show(
                String(localized: "Some audio files couldn't be deleted."),
                style: .error
            )
        } else {
            ToastCenter.shared.show(String(localized: "Audio moved to the Trash."), style: .success)
        }
        Task { await SessionStore.shared.refresh() }
    }

    private func exportRetainedAudio() {
        guard retainedAudioFiles.hasAny else {
            ToastCenter.shared.show(
                String(localized: "This session does not contain retained audio."),
                style: .warning
            )
            return
        }

        let panel = NSSavePanel()
        panel.title = String(localized: "Export audio")
        panel.prompt = String(localized: "Export")
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = safeAudioFilename(for: session.title) + ".m4a"
        if let m4a = UTType(filenameExtension: "m4a") {
            panel.allowedContentTypes = [m4a]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        ToastCenter.shared.show(String(localized: "Exporting audio"), style: .info)
        Task {
            do {
                try await SessionAudioProcessing.shared.exportAudio(session, to: destination)
                ToastCenter.shared.show(String(localized: "Audio exported"), style: .success)
            } catch is CancellationError {
                ToastCenter.shared.show(String(localized: "Audio export was cancelled."), style: .info)
            } catch {
                ToastCenter.shared.show(error.localizedDescription, style: .error)
            }
        }
    }

    private func safeAudioFilename(for title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = title.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? String(localized: "Daisy meeting") : cleaned
    }

    private func moveTo(folder: SessionFolder) async {
        isRunningAction = true
        await SessionStore.shared.moveSession(session, to: folder)
        ToastCenter.shared.show(String(localized: "Moved to \(folder.name)"), style: .success)
        isRunningAction = false
    }

    private func reSummarize() async {
        guard !session.transcriptText.isEmpty else { return }
        isRunningAction = true
        ToastCenter.shared.show(
            String(localized: "Summarizing via \(Summarizer.shared.providerKind.shortName)…"),
            style: .info
        )

        // Use the canonical locale resolver — same code path as the
        // post-Stop auto-summary, so re-summarize can never produce a
        // different language than the original run on the same
        // transcript. The resolver puts content-driven detection
        // first, so a Russian transcript whose frontmatter is
        // "auto" still gets a Russian re-summary.
        let localeHint = RecordingSession.resolveSummaryLocaleHint(
            transcript: session.transcriptText,
            transcriptLocale: session.locale,
            summaryLanguageOverride: AppSettings.currentSummaryLanguage
        )

        let result = await Summarizer.shared.summarize(
            transcript: session.transcriptText,
            title: session.title,
            localeHint: localeHint
        )

        if let summary = result {
            // Explicit user action with a spinner up: the extra pass over
            // the follow-up is honest latency here, unlike in the
            // scheduled evening pass or an MCP call where nobody is
            // watching and both are deliberately left out.
            let voiced = await FollowUpVoice.polished(summary)
            Summarizer.shared.adopt(voiced)
            let saved = await SessionStore.shared.updateSummary(voiced, for: session)
            if saved {
                if let preparation = session.meetingPreparation, !preparation.planItems.isEmpty {
                    MeetingPlanAnalysisStore.shared.analyzeIfNeeded(
                        sessionID: session.id,
                        directory: session.directoryURL,
                        title: session.title,
                        localeHint: localeHint,
                        preparation: preparation,
                        durationSeconds: Double(session.durationSec),
                        force: true
                    )
                }
                ToastCenter.shared.show(String(localized: "Summary updated"), style: .success)
            } else {
                ToastCenter.shared.show(
                    SessionStore.shared.lastError ?? String(localized: "Couldn’t save summary"),
                    style: .error
                )
            }
        } else if let err = Summarizer.shared.lastError {
            ToastCenter.shared.show(err, style: .error)
        } else {
            ToastCenter.shared.show(String(localized: "No summary returned"), style: .error)
        }
        isRunningAction = false
    }

    /// Same LLM call as `reSummarize` (we have to send the whole
    /// transcript anyway — providers don't expose a follow-up-only
    /// endpoint), but the result is MERGED rather than REPLACED:
    /// only `clientFollowUp` from the new pass overwrites the
    /// existing summary. Everything else (lede, sections, action
    /// items, any user edits) is preserved.
    ///
    /// If the new pass ALSO returns an empty follow-up, we surface
    /// a clear "model still judged this internal" toast instead of
    /// silently re-writing nothing — that's the honest UX: user
    /// pressed the button, model made the same call, here's why
    /// nothing visibly changed.
    private func draftFollowUp() async {
        guard !session.transcriptText.isEmpty else { return }
        guard let existing = session.summary else {
            // No summary yet — fall back to a regular re-summarize so
            // the user still gets something. The plaque only renders
            // when summary != nil so this branch is defensive.
            await reSummarize()
            return
        }
        isRunningAction = true
        isDraftingFollowUp = true
        ToastCenter.shared.show(
            String(localized: "Drafting follow-up via \(Summarizer.shared.providerKind.shortName)…"),
            style: .info
        )

        let localeHint = RecordingSession.resolveSummaryLocaleHint(
            transcript: session.transcriptText,
            transcriptLocale: session.locale,
            summaryLanguageOverride: AppSettings.currentSummaryLanguage
        )

        // Force the model to draft a follow-up even if it judges the
        // meeting internal — clicking this button IS the explicit request.
        let result = await Summarizer.shared.summarize(
            transcript: session.transcriptText,
            title: session.title,
            localeHint: localeHint,
            task: .meeting(forceFollowUp: true)
        )

        if let fresh = result {
            let trimmedFollowUp = fresh.clientFollowUp
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedFollowUp.isEmpty {
                // Forced and still empty — the model ignored the directive
                // (rare). Keep the existing follow-up; tell the user.
                ToastCenter.shared.show(
                    String(localized: "Couldn't draft a follow-up for this one — try Re-summarize."),
                    style: .warning
                )
            } else {
                let merged = await FollowUpVoice.polished(
                    MeetingSummary(
                        summary: existing.summary,
                        sections: existing.sections,
                        actionItems: existing.actionItems,
                        clientFollowUp: trimmedFollowUp
                    )
                )
                Summarizer.shared.adopt(merged)
                await SessionStore.shared.updateSummary(merged, for: session)
                ToastCenter.shared.show(String(localized: "Follow-up drafted"), style: .success)
            }
        } else if let err = Summarizer.shared.lastError {
            ToastCenter.shared.show(err, style: .error)
        } else {
            ToastCenter.shared.show(String(localized: "No response from the model"), style: .error)
        }
        isDraftingFollowUp = false
        isRunningAction = false
    }

    /// Kebab-menu copy variants (1.0.7.19) — explicit single-flavor
    /// writes for when the user wants the RAW markdown as plain text
    /// (the toolbar Copy writes html + markdown; targets that prefer
    /// HTML would paste the rich flavor even when the user wanted
    /// source). `includeFrontmatter` is the Obsidian-vault variant.
    private func copyPlainMarkdown(includeFrontmatter: Bool) {
        guard !session.transcriptText.isEmpty else {
            ToastCenter.shared.show(String(localized: "No transcript yet"), style: .warning)
            return
        }
        RichClipboard.copyPlain(markdown: markdownDocument(includeFrontmatter: includeFrontmatter))
        ToastCenter.shared.show(
            includeFrontmatter
                ? String(localized: "Markdown with frontmatter copied")
                : String(localized: "Markdown copied to clipboard"),
            style: .success
        )
    }

    /// Copy one section as plain markdown with a toast. Empty content
    /// shows a warning instead of writing an empty pasteboard — mirrors
    /// `copyPlainMarkdown`'s guard. Backs the ⋯ menu's per-section
    /// copies (Summary / Follow-up / Transcript); the text comes from
    /// the same closures the accordion copy buttons use.
    private func copySection(_ text: String, label: String) {
        guard !text.isEmpty else {
            ToastCenter.shared.show(String(localized: "Nothing to copy yet"), style: .warning)
            return
        }
        RichClipboard.copyPlain(markdown: text)
        ToastCenter.shared.show(String(localized: "\(label) copied"), style: .success)
    }

    /// Full markdown document for the copy actions. The body is always
    /// re-assembled from in-memory state (see `copyMarkdown`'s lag
    /// note); `includeFrontmatter` prepends the verbatim YAML block
    /// from the on-disk transcript.md — frontmatter never lags memory
    /// the way the summary does, because every frontmatter mutation
    /// (folder / tag / speaker map) goes through SessionStore's
    /// synchronous upsert-and-rewrite path.
    private func markdownDocument(includeFrontmatter: Bool) -> String {
        let body = assembledMarkdown()
        guard includeFrontmatter, let fm = onDiskFrontmatter() else { return body }
        return fm + "\n\n" + body
    }

    /// The verbatim `---`-fenced frontmatter block from this session's
    /// transcript.md, or nil when the file is missing / carries none.
    private func onDiskFrontmatter() -> String? {
        guard let url = session.transcriptURL,
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            return lines[0...i].joined(separator: "\n")
        }
        return nil
    }

    /// Build a full markdown document for clipboard / share: title
    /// + summary (if present) + Granola-style sections + next actions
    /// + follow-up + transcript body. Mirrors `MarkdownExporter` but
    /// works against `StoredSession` (which `MarkdownExporter` doesn't
    /// take — it consumes the live `RecordingSession`).
    private func assembledMarkdown() -> String {
        var lines: [String] = []
        lines.append("# \(session.title)")
        lines.append("")

        if let s = session.summary {
            let labels = summaryLabels(for: s)
            if !s.summary.isEmpty {
                lines.append("## \(labels.meeting)")
                lines.append("")
                lines.append(s.summary)
                lines.append("")
            }
            for section in s.sections {
                lines.append("### \(section.title)")
                lines.append("")
                appendBullets(section.bullets, level: 0, into: &lines)
                lines.append("")
            }
            if !s.actionItems.isEmpty {
                lines.append("## \(labels.nextActions)")
                lines.append("")
                for item in s.actionItems {
                    lines.append("- [ ] \(item)")
                }
                lines.append("")
            }
            if !s.clientFollowUp.isEmpty {
                lines.append("## \(labels.followUp)")
                lines.append("")
                // The follow-up is already paragraph-formatted by the
                // model (2-4 paragraphs separated by blank lines).
                // Pasting it verbatim preserves that paragraphing.
                lines.append(s.clientFollowUp)
                lines.append("")
            }
        }

        lines.append("## Transcript")
        lines.append("")
        lines.append(session.transcriptText)

        return lines.joined(separator: "\n")
    }

    /// Recursive bullet writer for `assembledMarkdown`. Two-space
    /// indent per level, matching CommonMark / Obsidian / Notion.
    private func appendBullets(_ bullets: [SummaryBullet], level: Int, into lines: inout [String]) {
        let indent = String(repeating: "  ", count: level)
        for b in bullets {
            lines.append("\(indent)- \(b.text)")
            if !b.children.isEmpty {
                appendBullets(b.children, level: level + 1, into: &lines)
            }
        }
    }

    private func sendToNotion() async {
        if session.transcriptText.isEmpty {
            ToastCenter.shared.show(String(localized: "No transcript to send"), style: .warning)
            return
        }
        if !AppSettings.notionConfigured {
            ToastCenter.shared.show(String(localized: "Set Notion token in Settings first"), style: .warning)
            return
        }
        isRunningAction = true
        ToastCenter.shared.show(String(localized: "Sending to Notion…"), style: .info)
        let data = exportData()
        do {
            let url = try await NotionExporter.shared.createMeetingPage(data)
            ToastCenter.shared.show(String(localized: "Notion page created"), style: .success)
            NSWorkspace.shared.open(url)
        } catch {
            ToastCenter.shared.show(String(localized: "Notion: \(error.localizedDescription)"), style: .error)
        }
        isRunningAction = false
    }

    private func sendToClaude() {
        if session.transcriptText.isEmpty {
            ToastCenter.shared.show(String(localized: "No transcript to send"), style: .warning)
            return
        }
        let opened = ClaudeExporter.sendToClaude(data: exportData())
        if opened {
            ToastCenter.shared.show(String(localized: "Prompt copied — switch to Claude and ⌘V"), style: .success)
        } else {
            ToastCenter.shared.show(String(localized: "Prompt copied — claude.ai opened"), style: .success)
        }
    }

    private func deleteSession() async {
        await SessionStore.shared.delete(session)
        // SwiftUI will pop us back to the empty state when the session
        // disappears from the store.
    }

    /// Build a MeetingExportData snapshot from this stored session so we
    /// can reuse the existing Notion + Claude exporters.
    private func exportData() -> MeetingExportData {
        let chunks = Self.chunkTranscript(session.transcriptText)
        return MeetingExportData(
            title: session.title,
            summary: session.summary,
            transcriptChunks: chunks,
            durationSeconds: session.durationSec,
            locale: session.locale,
            startedAt: session.startedAt
        )
    }

    private static func chunkTranscript(_ text: String) -> [String] {
        let limit = 1500
        var chunks: [String] = []
        var current = ""
        for paragraph in text.split(separator: "\n\n", omittingEmptySubsequences: true) {
            let line = String(paragraph)
            if current.count + line.count + 2 > limit {
                if !current.isEmpty { chunks.append(current) }
                current = line
            } else {
                current = current.isEmpty ? line : "\(current)\n\n\(line)"
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Formatting

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: session.startedAt)
    }

    private var formattedDuration: String {
        let total = max(0, session.durationSec)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Collapsible-block helpers (1.0.7.1)

    /// Title for the outer Summary collapsible. Held as a separate
    /// property so we can keep it consistent with the rest of the
    /// EN-only UI surface (per the brand-voice memory: Daisy product
    /// UI is English only — RU bits creep in only via summary CONTENT
    /// when the user dictated in RU, never via chrome).
    private var summaryBlockTitle: String { String(localized: "Summary") }

    /// Markdown body of everything the Summary collapsible renders —
    /// lede paragraph, `##` topical sections with nested bullets,
    /// `- [ ]` next actions, follow-up draft. Built by
    /// `summaryMarkdown(_:labels:)` (MarkdownClipboard.swift), whose
    /// order mirrors `summaryAttributedString` 1:1. CollapsibleBlock
    /// writes it through `RichClipboard.copy`, so rich targets
    /// (Slack / Notion / Gmail / Apple Notes) paste real headings +
    /// indented bullets while plain targets (Obsidian / Claude /
    /// editors) get clean markdown. Replaces the 1.0.7.1 ALL-CAPS
    /// plain-text dump — that lowest-common-denominator format is
    /// exactly what the two-flavor pasteboard makes unnecessary.
    ///
    /// Returns "" when no summary is loaded (CollapsibleBlock won't
    /// fire copy in that state, but harmless to return an empty
    /// pasteboard string defensively).
    private var summaryCopyText: () -> String {
        return {
            guard let s = session.summary else { return "" }
            // Body only — the Follow-up accordion copies the draft itself.
            let body = MeetingSummary(
                summary: s.summary,
                sections: s.sections,
                actionItems: s.actionItems,
                clientFollowUp: ""
            )
            return summaryMarkdown(body, labels: summaryLabels(for: s))
        }
    }
}

// MARK: - Collapsible block (Summary / Transcript)
//
// Outer container for the two-block layout SessionDetailView ships
// in 1.0.7.1. Header is a row with chevron + title (whole row is
// the tap target for collapse) and a copy-to-clipboard button on
// the trailing edge. Body is rendered only when expanded — this is
// what makes long transcripts cheap to keep collapsed by default
// on next open.
//
// Expanded state persists via @AppStorage with a caller-supplied
// key, so the user's "I always keep Transcript collapsed" or
// "I always start with Summary closed" preference survives across
// sessions and app restarts. Keys live under daisy.session.detail.*
// in UserDefaults.
//
// Copy: caller passes a `() -> String` closure (lazy — we don't pay
// for the full summary/transcript flatten unless the user actually
// presses the button). Toast feedback fires after the clipboard write.
//
// Visual style mirrors `mdSection` (rounded rect, daisyBgSidebar fill,
// daisyDivider stroke, 10 pt radius) so the new outer container
// matches the existing inner cards visually — the user reads the
// nesting as "this card holds N cards" rather than "two different
// component families coexisting".

/// Wrapper so a frame URL can drive `.sheet(item:)`. A retroactive
/// `URL: Identifiable` would be visible to the whole module for the sake
/// of one sheet.
private struct PreviewedFrame: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct CollapsibleBlock<Accessory: View, Content: View>: View {
    let title: String
    let storageKey: String
    let copyLabel: String
    let copyText: () -> String
    /// When false the header copy button is hidden — used by the Summary
    /// block, whose copy is served by the toolbar + the follow-up button,
    /// so the block doesn't show a second redundant copy control (Egor).
    let showsCopy: Bool
    /// Extra control in the header, left of the copy button. Empty for
    /// every block but the transcript, which puts the screen-stepper
    /// there.
    let accessory: () -> Accessory
    let content: () -> Content

    @AppStorage private var isExpanded: Bool

    init(
        title: String,
        storageKey: String,
        copyLabel: String,
        copyText: @escaping () -> String,
        showsCopy: Bool = true,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.storageKey = storageKey
        self.copyLabel = copyLabel
        self.copyText = copyText
        self.showsCopy = showsCopy
        self.accessory = accessory
        self.content = content
        // @AppStorage with a dynamic key: have to use the underlying
        // wrapper init directly. Default to expanded — first-run users
        // want to see content, not have to hunt for the chevron.
        self._isExpanded = AppStorage(wrappedValue: true, storageKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                content()
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.daisyBgSidebar)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.daisyDivider, lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        // Fixed width so the title doesn't shift when
                        // the chevron rotates between states.
                        .frame(width: 12, alignment: .center)
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? String(localized: "Collapse") : String(localized: "Expand"))

            Spacer()

            accessory()

            if showsCopy {
                Button {
                    let text = copyText()
                    guard !text.isEmpty else {
                        ToastCenter.shared.show(String(localized: "Nothing to copy yet"), style: .warning)
                        return
                    }
                    // Two-flavor write (MarkdownClipboard.swift) — the
                    // closures hand us markdown; rich paste targets read
                    // the semantic-HTML render, plain ones the markdown.
                    RichClipboard.copy(markdown: text)
                    ToastCenter.shared.show(String(localized: "\(title) copied"), style: .success)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(copyLabel)
            }
        }
    }
}

extension CollapsibleBlock where Accessory == EmptyView {
    /// The common case: no extra header control.
    init(
        title: String,
        storageKey: String,
        copyLabel: String,
        copyText: @escaping () -> String,
        showsCopy: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title,
            storageKey: storageKey,
            copyLabel: copyLabel,
            copyText: copyText,
            showsCopy: showsCopy,
            accessory: { EmptyView() },
            content: content
        )
    }
}

// MARK: - Speaker name row
//
// One row inside the "Name the speakers" card. Shows the
// auto-detected "Remote A / B / C" label as the row anchor,
// a free-text TextField for the human name, and an optional
// suggestions Menu when calendar attendees are present.
//
// Save-on-blur semantics: typing → local @State; commits to the
// store on `.onSubmit` (Return) and on focus loss. No explicit
// Save button keeps the UX inline + intent-driven.

private struct SpeakerNameRow: View {
    let speakerID: String
    let currentName: String
    let attendeeSuggestions: [String]
    /// Title of the calendar event the attendees came from. nil
    /// for manual recordings with no calendar binding. Used as a
    /// disabled header at the top of the picker menu so the user
    /// can visually confirm "these are attendees from THIS event"
    /// — a tester saw what looked like emails from a different
    /// meeting and assumed the picker was broken (2026-05-26); the
    /// underlying cause was the wrong calendar event being bound
    /// at session-start time, which is now visible.
    let attendeeSourceEventTitle: String?
    /// How many transcript segments are attributed to this speaker
    /// cluster. Surfaced as a small "N segments" caption so the user
    /// can prioritise renaming the dominant voice over a stray
    /// 5-segment fragment.
    let segmentCount: Int
    /// True when speakers.json has a saved voice embedding for this
    /// cluster. False means FluidAudio assigned this label to
    /// fragments but didn't form a clean centroid — rename works for
    /// THIS session's display, but no fingerprint will auto-match
    /// future sessions. UX: subtle "session only" caption.
    let hasCentroid: Bool
    /// Suggest-mode candidate name Daisy recognized for this label but
    /// didn't auto-apply (match mode = Suggest). nil in Automatic/Off
    /// or when this label wasn't recognized. When non-nil AND the row
    /// is still unnamed, a "Suggested: <name>" affordance with a
    /// Confirm checkmark renders inline.
    let suggestion: String?
    /// Why Daisy matched ("voice" / "email" / "voice+email") — shown
    /// as a subtle caption on the suggestion chip so the user gauges
    /// confidence. nil hides the qualifier.
    let suggestionSource: String?
    let onCommit: (String?) -> Void
    /// User dismissed the suggestion without naming the speaker.
    let onDismissSuggestion: () -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(
        speakerID: String,
        currentName: String,
        attendeeSuggestions: [String],
        attendeeSourceEventTitle: String?,
        segmentCount: Int,
        hasCentroid: Bool,
        suggestion: String? = nil,
        suggestionSource: String? = nil,
        onCommit: @escaping (String?) -> Void,
        onDismissSuggestion: @escaping () -> Void = {}
    ) {
        self.speakerID = speakerID
        self.currentName = currentName
        self.attendeeSuggestions = attendeeSuggestions
        self.attendeeSourceEventTitle = attendeeSourceEventTitle
        self.segmentCount = segmentCount
        self.hasCentroid = hasCentroid
        self.suggestion = suggestion
        self.suggestionSource = suggestionSource
        self.onCommit = onCommit
        self.onDismissSuggestion = onDismissSuggestion
        self._draft = State(initialValue: currentName)
    }

    var body: some View {
        // 2026-05-26 — collapsed from the previous two-line layout
        // (leading "Remote X" chip + bordered TextField + caption row
        // underneath with segment count) into a single composite
        // field. The "Remote X" anchor now lives as the TextField
        // placeholder, so empty rows still read as "Remote A" greyed
        // out; once the user types a name, the placeholder yields.
        // Talk-time count and the "session only" pill move INTO the
        // trailing edge of the same field, replacing the captionLine
        // entirely. Net result: tighter one-line rows, no left
        // gutter wasted on a label that just echoed the speakerID.
        //
        // 2026-06-03 — wrapped in a VStack so a Suggest-mode chip can
        // render UNDER the field when Daisy recognized this voice but
        // (match mode = Suggest) left it for the user to confirm. The
        // chip only appears while the row is still unnamed; confirming
        // or naming the row by hand resolves it.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                speakerField
                // Suggestions menu — present only when the session has
                // calendar attendees. Quick-fill from the bound event,
                // still allows free-text in the field next to it.
                // 2026-05-26 — top of menu shows the source event title
                // (disabled header item) so the user can visually verify
                // "these are attendees from THIS event". Tester saw what
                // looked like emails from a different meeting; root
                // cause was the wrong event bound at session-start with
                // no on-screen indicator.
                if !attendeeSuggestions.isEmpty {
                    Menu {
                        if let eventTitle = attendeeSourceEventTitle,
                           !eventTitle.isEmpty {
                            Section("From: \(eventTitle)") {
                                ForEach(attendeeSuggestions, id: \.self) { name in
                                    Button(name) {
                                        draft = name
                                        commit()
                                    }
                                }
                            }
                        } else {
                            ForEach(attendeeSuggestions, id: \.self) { name in
                                Button(name) {
                                    draft = name
                                    commit()
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(
                        attendeeSourceEventTitle
                            .map { String(localized: "Pick from attendees of \"\($0)\"") }
                            ?? String(localized: "Pick from event attendees")
                    )
                }
            }
            suggestionChip
        }
    }

    /// Suggest-mode confirm affordance. Renders only when Daisy
    /// recognized a name for this label (`suggestion != nil`) AND the
    /// row is still unnamed — once the user confirms or types their
    /// own name, `currentName` is non-empty and the chip drops away.
    /// Confirm fills the field with the suggested name and commits
    /// (which persists the mapping AND prunes the sidecar via the
    /// parent's `onCommit` → `applyMapping`); Dismiss drops the
    /// suggestion without naming the row.
    @ViewBuilder
    private var suggestionChip: some View {
        if let suggestion, !suggestion.isEmpty, currentName.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(Color.daisyAccent)
                (
                    Text("Suggested: ").foregroundStyle(.secondary)
                    + Text(suggestion).foregroundStyle(Color.daisyTextPrimary).fontWeight(.medium)
                )
                .font(.caption)
                if let qualifier = suggestionSourceLabel {
                    Text(qualifier)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                Button {
                    draft = suggestion
                    commit()
                } label: {
                    Label("Confirm", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .tint(Color.daisyAccent)
                Button {
                    onDismissSuggestion()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .foregroundStyle(.secondary)
                .help("Dismiss this suggestion — the speaker stays unnamed.")
            }
            .padding(.leading, 2)
            .transition(.opacity)
        }
    }

    /// Human label for the match source caption on the suggestion
    /// chip ("heard" / "calendar" / "heard + calendar"). nil hides
    /// the qualifier. Keeps internal source keys ("voice"/"email")
    /// out of the UI copy.
    private var suggestionSourceLabel: String? {
        switch suggestionSource {
        case "voice":       return String(localized: "· heard")
        // "email" and "invite" are the two ways the calendar pass
        // resolves an attendee to a known profile; the distinction is
        // internal bookkeeping, and "calendar" is the honest word for
        // both from where the user sits.
        case "email":       return String(localized: "· calendar")
        case "invite":      return String(localized: "· calendar")
        case "voice+email": return String(localized: "· heard + calendar")
        // Inferred from how the person was addressed in the
        // conversation. Weaker evidence than a voice fingerprint, and
        // the caption says so — this is the one the user should read
        // before confirming.
        case "mentioned":   return String(localized: "· named in the call")
        default:            return nil
        }
    }

    /// Composite "field" — a custom rounded container that hosts the
    /// plain TextField on the leading edge and the meta strip
    /// (segment count + optional "session only" pill) pinned to the
    /// trailing edge. `.textFieldStyle(.roundedBorder)` doesn't let
    /// us put sibling content inside its chrome, so we build our own
    /// frame with the same proportions and add a focus-aware border.
    /// Layout priority on the meta elements keeps them right-anchored
    /// even when the user types a long name — the TextField scrolls
    /// its content within the remaining width rather than pushing
    /// the meta off-screen.
    @ViewBuilder
    private var speakerField: some View {
        HStack(spacing: 8) {
            TextField("Remote \(speakerID)", text: $draft)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, isFocused in
                    // Commit on blur so users who click away (rather
                    // than press Return) still persist their edit.
                    if !isFocused { commit() }
                }
                // 2026-05-27 — sync `draft` with `currentName` when
                // the parent flips it (e.g. the "Clear" button in
                // speakerMappingSection sets the whole map to empty,
                // which the parent feeds as `currentName: ""`).
                // Without this, `@State draft` keeps the previously-
                // typed name forever (SwiftUI ignores re-init of
                // @State on subsequent view updates), so the field
                // still reads "Спикер А" after Clear AND the next
                // focus blur commits it right back into speakerMap.
                // Egor caught: "не работает кнопка Clear".
                .onChange(of: currentName) { _, newName in
                    if !focused, draft != newName {
                        draft = newName
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(segmentCountText)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .layoutPriority(1)
            if !hasCentroid {
                Text("session only")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.daisyTextSecondary.opacity(0.12))
                    )
                    .layoutPriority(1)
                    .help("No voice fingerprint was saved for this cluster — the name applies to this session only and won't auto-match future recordings.")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    focused ? Color.daisyAccent.opacity(0.7) : Color.daisyDivider,
                    lineWidth: focused ? 1.5 : 0.5
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // Click anywhere inside the field — including on the
            // meta strip — focuses the TextField. Mirrors the
            // affordance the OS gives a bordered TextField for free.
            focused = true
        }
        .animation(.easeInOut(duration: 0.12), value: focused)
    }

    private var segmentCountText: String {
        segmentCount == 1 ? String(localized: "1 segment") : String(localized: "\(segmentCount) segments")
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        // Empty input clears the mapping — same as pre-fix `Unmapped`
        // button. Caller distinguishes nil vs string.
        if trimmed.isEmpty {
            // Only call onCommit if there was previously a value
            // (avoids spamming writes on focus loss of an unset row).
            if !currentName.isEmpty {
                onCommit(nil)
            }
        } else if trimmed != currentName {
            onCommit(trimmed)
        }
    }
}
