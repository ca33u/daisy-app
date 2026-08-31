//
//  MainView.swift
//  Daisy
//
//  Single-window primary UI. NavigationSplitView with three sections in
//  the sidebar (Home / History / Settings) and the matching content in
//  the detail pane. Replaces the previous multi-window setup where
//  History and Settings each had their own Window scene.
//
//  Section selection is held in `AppNavigation.shared` so that other
//  surfaces (menu bar popover, floating widget) can route to a section
//  via:
//      AppNavigation.shared.section = .library
//      openWindow(id: "main")
//

import AppKit
import EventKit
import SwiftUI

// MARK: - Section enum

enum MainSection: String, Hashable, CaseIterable, Identifiable, Sendable {
    case home, library, notes, dictation, voice, connections, settings, about

    var id: String { rawValue }

    /// Destinations that hold the user's own material. These fill the
    /// sidebar from the top.
    static var primaryCases: [MainSection] {
        allCases.filter { !utilityCases.contains($0) }
    }

    /// Housekeeping destinations, pinned to the bottom of the sidebar
    /// (Egor, 2026-08-31). They're where you go to configure the app,
    /// not where you work — sitting them under Home/Library/Notes gave
    /// them the same weight as the content, and pushed the recording
    /// capsule further from the eye. Bottom-anchored is also where
    /// macOS users look for them (Mail, Music, Xcode all park account
    /// and settings affordances at the foot of the source list).
    static let utilityCases: [MainSection] = [.settings, .about]

    var title: String {
        switch self {
        case .home:        String(localized: "Home")
        case .library:     String(localized: "Library")
        case .notes:       String(localized: "Notes")
        case .dictation:   String(localized: "Dictation")
        case .voice:       String(localized: "Voice")
        case .connections: String(localized: "Connections")
        case .settings:    String(localized: "Settings")
        case .about:       String(localized: "About")
        }
    }

    var systemImage: String {
        switch self {
        case .home:        "house"
        // books.vertical reads as "your shelf of past meetings" —
        // matches Apple Books / Music's Library iconography. Was
        // `list.bullet.rectangle` while the section was called
        // History, which framed it as a chronological log; Library
        // reframes it as a curated collection, and the icon follows.
        case .library:     "books.vertical"
        // note.text reads as "a jotted note" — sits below Library as
        // the lighter, quick-capture counterpart (voice notes) to the
        // curated meeting shelf above it.
        case .notes:       "note.text"
        // character.cursor.ibeam reads as "type / insert text at the
        // caret" — the universal dictation/typing affordance (same
        // glyph the old Settings → Dictation tab used). Reframes this
        // section as "where your dictated words live" alongside the
        // Library of meetings.
        case .dictation:   "character.cursor.ibeam"
        // waveform reads as "your voice" — pairs with the Voice section
        // that profiles how you speak/write.
        case .voice:       "waveform"
        // arrow.triangle.branch reads as "things diverging from a
        // central point" — same shape Notion / Linear / Raycast use
        // for their Integrations / Connections nav entries. Closest
        // SF Symbol to that visual without falling back to the
        // generic link icon (which we already use elsewhere).
        case .connections: "arrow.triangle.branch"
        case .settings:    "gearshape"
        case .about:       "info.circle"
        }
    }
}

// MARK: - Shared navigation state

/// SwiftUI TabView in SettingsView has no public selection by
/// default. Exposing the tab enum here lets external surfaces
/// (FirstRun CTAs, Home-screen hints) deep-link to a specific
/// settings sub-tab, not just "Settings" in the sidebar.
///
/// `.integrations` and `.mcpServer` were moved out of Settings into
/// the top-level `Connections` sidebar destination (see
/// `ConnectionSection`). Settings now holds only the "how the
/// recorder works" tabs — Capture / Transcription / Summary.
enum SettingsTab: String, Hashable, Sendable {
    /// General is the catch-all tab — audio I/O devices, sounds,
    /// hotkey, calendar gating, screenshot toggles, the floating
    /// widget, storage location. Was named `.capture` while it sat
    /// alongside Notion / MCP / Integrations tabs, but those moved
    /// to the top-level Connections destination and what remained
    /// drifted toward "general app preferences" — hence the rename.
    case general
    /// Recording behavior — input device, hotkeys, meeting auto-record,
    /// and Daisy's on-screen presence (menu bar + floating widget).
    /// Split out of the overloaded General tab in 1.0.7.16.
    case recording
    case transcription
    case summary
    /// System privacy permissions Daisy interacts with — Microphone,
    /// Calendar, Accessibility, Screen Recording. Lives in Settings
    /// (not Connections) because it's about local OS-level access,
    /// not about external service integrations. macOS convention —
    /// Granola, Wispr Flow et al. put permission dashboards here too.
    case permissions
}

/// Sub-section inside the Connections page. Lets external CTAs
/// (FirstRun, Home destination prompts) deep-link to a specific
/// card on the page — MCP server / Auto-routing.
///
/// Calendar dropped in 1.0.4 — EventKit permission moved to
/// Settings → Permissions and behaviour toggles to Settings →
/// General. Notion briefly lived in Settings → General → Storage
/// (1.0.5) but came back to Connections in 1.0.7.16 — it's an
/// outbound send-to destination, so it renders as a "Notion" Section
/// at the top of the Auto-routing tab rather than getting its own
/// `ConnectionSection` case. Google Calendar OAuth UI is dormant
/// pre-verification; when it returns it'll come back as its own case
/// here.
enum ConnectionSection: String, Hashable, Sendable {
    case mcpServer
    case autoRouting
    // Google Calendar OAuth row moved to Settings → Permissions
    // → Calendar in build 42 (2026-05-28). Both calendar sources
    // (Apple via EventKit, Google via OAuth) now live side-by-side
    // in Permissions so users see "where Daisy reads calendar data
    // from" in one place. Connections is now strictly outbound
    // integrations (auto-routing + MCP server).
}

@Observable
@MainActor
final class AppNavigation {
    static let shared = AppNavigation()
    var section: MainSection = .home
    /// One-shot session selection request. HomeView (and any other
    /// surface that needs to deep-link into a transcript) sets this
    /// together with `section = .library`; LibraryView consumes and
    /// clears it on appear / when it observes the change. nil means
    /// "let the view pick its own default" — usually the first row.
    var pendingLibrarySelection: StoredSession.ID?
    /// One-shot Settings tab request. FirstRunView and any external
    /// CTA that wants to land the user on a specific sub-tab inside
    /// SettingsView (Summary for API key, Capture for Calendar,
    /// etc.) sets this together with `section = .settings`. The
    /// SettingsView reads + clears it on appear. nil means "use the
    /// default tab".
    var pendingSettingsTab: SettingsTab?
    /// One-shot Connections deep-link. Same pattern as
    /// `pendingSettingsTab` but for the new Connections sidebar
    /// destination. ConnectionsView reads + clears on appear; the
    /// section scrolls to the matching anchor.
    var pendingConnectionsSection: ConnectionSection?
    private init() {}

    /// Convenience for `Open this session in Library`. Sets both
    /// section and the pending selection so the Library view jumps
    /// straight to the correct row.
    func openInLibrary(_ id: StoredSession.ID) {
        pendingLibrarySelection = id
        section = .library
    }

    /// Convenience for `Open Settings → <tab>`. FirstRun + onboarding
    /// CTAs use this so the user lands exactly where the action they
    /// just read about is configured, not on the default General tab.
    func openInSettings(_ tab: SettingsTab) {
        pendingSettingsTab = tab
        section = .settings
    }

    /// Convenience for `Open Connections → <card>`. Used by FirstRun
    /// onboarding CTAs ("Connect Notion", "Set up MCP server") and
    /// the Home destination-discovery banner.
    func openInConnections(_ card: ConnectionSection) {
        pendingConnectionsSection = card
        section = .connections
    }
}

// MARK: - MainView

struct MainView: View {
    @Bindable var session: RecordingSession
    @Bindable var settings: AppSettings
    @Bindable var nav = AppNavigation.shared
    @Bindable private var updater = SparkleUpdater.shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarSelection: MainSection? = .home
    /// Shared Library selection state, hoisted out of the (now split)
    /// list + detail columns so both can read/write one selection. Owned
    /// here — ABOVE the shell-arity branch — so each tab's selection,
    /// query and filters survive the split's remount when the user
    /// navigates away and back. One model per scope keeps Library and
    /// Notes independent, mirroring the pre-refactor per-tab `@State`.
    @State private var libraryModel = LibraryModel(scope: .all)
    @State private var notesModel = LibraryModel(scope: .notes)

    var body: some View {
        // The shell arity branches per section (see `splitShell`).
        // Window / toolbar chrome that must attach to the
        // NavigationSplitView itself lives in `MainWindowChrome`, applied
        // inside each branch. The app-lifecycle modifiers below
        // (sidebar-selection sync, reactive service re-wiring) sit out
        // HERE on the stable body so they survive both the split
        // subtree's remount when the user enters / leaves Library or
        // Notes AND the one-time onboarding → shell swap: state owned by
        // MainView (`libraryModel`, `notesModel`, `sidebarSelection`)
        // lives above the branch, and the wiring `.onChange` handlers
        // stay registered while onboarding is on screen — which is what
        // makes the layout-fixer toggle on the onboarding's layout step
        // actually start the tap.
        Group {
            if settings.hasShownFirstRun {
                splitShell
            } else {
                // First run owns the WHOLE window — no sidebar: showing
                // navigation that can't be used yet is worse than showing
                // none. `FirstRunView.finish()` flips `hasShownFirstRun`
                // and this branch swaps to the ordinary shell in place.
                // MainWindowChrome (toolbar pill, 860pt floor) stays off
                // here on purpose: onboarding has no toolbar, suppresses
                // the window title itself, and allows a narrower window
                // (its single-column fallback kicks in below ~760pt).
                FirstRunView(settings: settings)
                    .navigationTitle("")
                    .frame(minWidth: 560, minHeight: 520)
                    .daisyWindowBackground(Color.daisyBgPrimary)
            }
        }
        .modifier(ToastOverlay())
        // Keep the local sidebar selection mirrored with the shared
        // AppNavigation state so external surfaces (menu bar / widget)
        // can switch sections by mutating `AppNavigation.shared`.
        .onAppear { sidebarSelection = nav.section }
        .onChange(of: sidebarSelection) { _, new in
            if let new, new != nav.section { nav.section = new }
        }
        .onChange(of: nav.section) { _, new in
            if sidebarSelection != new { sidebarSelection = new }
        }
        // Reactive service re-wiring, lifted out of `body` into
        // ViewModifiers. Inline, this was 14 chained `.onChange`
        // handlers stacked on the toolbar/sheet/styling chain, which
        // tripped the Swift type-checker's complexity limit ("unable
        // to type-check this expression in reasonable time") once the
        // auto-start policy added five more. Each modifier below is its
        // own type-check scope. Initial wiring still runs in
        // DaisyApp.init via the same ServiceWiring helpers.
        .modifier(HotkeyStopWiring(settings: settings, session: session))
        .modifier(AutoStartWiring(settings: settings, session: session))
        .modifier(CalendarServerWiring(settings: settings, session: session))
    }

    // MARK: Shell arity

    /// Library and Notes render as a GENUINE three-column split so the
    /// window's Liquid Glass toolbar breaks into column-aligned sections
    /// (Daisy pill over the sidebar, Tags pill over the list, the detail
    /// action pills over the detail). Every other section keeps the
    /// original TWO-column split (a full-width page in the detail column,
    /// no dead middle band — `NavigationSplitViewVisibility` has no
    /// "hide the middle column only" state, which is exactly why a
    /// single always-3-column shell can't work for the full-width pages).
    ///
    /// The two branches use different `NavigationSplitView` initializers,
    /// so switching between them remounts the split subtree. That's
    /// acceptable: it only happens on a section navigation, and the state
    /// that must survive (sidebar selection + the two Library models) is
    /// owned by MainView, above the branch.
    @ViewBuilder
    private var splitShell: some View {
        if nav.section == .library || nav.section == .notes {
            threeColumnSplit
        } else {
            twoColumnSplit
        }
    }

    /// Full-width sections (Home / Dictation / Voice / Connections /
    /// Settings / About). Unchanged from the pre-refactor shell: a
    /// sidebar and a single detail column.
    private var twoColumnSplit: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detail
                // Keep the product accent inside the content pane. The split
                // view itself uses a neutral tint for native sidebar selection.
                .tint(Color.daisyAccent)
        }
        .modifier(MainWindowChrome())
    }

    /// Library / Notes: [sidebar] | [session list] | [session detail].
    /// The list is the CONTENT column so its toolbar items (Tags pill)
    /// land in the list region of the window toolbar; the detail column
    /// carries `SessionDetailView` and its trailing action pills in the
    /// detail region. `.id(nav.section)` gives Library and Notes distinct
    /// identities so switching between the two cleanly re-runs the list
    /// column's default-selection / deep-link `onAppear` — the shared
    /// models, owned above, still persist each tab's selection.
    private var threeColumnSplit: some View {
        let model = (nav.section == .notes) ? notesModel : libraryModel
        return NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } content: {
            LibraryListColumn(model: model)
                // Fixed width (single value) → the list/detail divider is
                // not draggable; the centre column stays put (Egor).
                .navigationSplitViewColumnWidth(320)
                .id(nav.section)
        } detail: {
            LibraryDetailColumn(model: model)
                // Sane minimum so the transcript pane isn't over-wide at
                // its floor; flexes to fill the remaining window width.
                .navigationSplitViewColumnWidth(min: 420, ideal: 640)
                .tint(Color.daisyAccent)
                .id(nav.section)
        }
        .modifier(MainWindowChrome())
    }

    // MARK: Sidebar

    private var sidebar: some View {
        // Let AppKit render sidebar selection. Keeping selection ownership in
        // `List(selection:)` gives the sidebar its standard macOS keyboard,
        // focus and accessibility behaviour, and prevents a second custom
        // highlight from fighting the system-selected row.
        List(selection: $sidebarSelection) {
            Section {
                // Settings / About are NOT here — they live in the
                // bottom inset below, under the update row.
                ForEach(MainSection.primaryCases) { section in
                    Label {
                        Text(section.title)
                            .foregroundStyle(Color.daisySidebarInk)
                    } icon: {
                        Image(systemName: section.systemImage)
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(Color.daisySidebarInk)
                    }
                        // Native sidebar label styles otherwise colour the
                        // symbol independently through the environment tint.
                        .tint(Color.daisySidebarInk)
                        .tag(section)
                }
            }

            // Recording capsule sits directly under nav items, no
            // section header — header label was visual noise.
            Section {
                RecordCapsule(session: session, settings: settings)
                    // 2026-05-25 — capsule was visibly narrower than
                    // the Home / Library / etc. selection chips above.
                    // `List(.sidebar)` adds ~8pt implicit horizontal
                    // inset that we can't override directly. Negative
                    // listRowInsets cancel that inset so the capsule's
                    // outer edges land at the same x-coordinates as
                    // the highlight chip on the row above. Combined
                    // with the capsule's own 10pt internal text
                    // padding the visual width now matches.
                    .listRowInsets(EdgeInsets(top: 14, leading: -8, bottom: 4, trailing: -8))
                    .listRowBackground(Color.clear)

                // Stop & save (and, below it, Stop & discard) live next
                // to the toggle capsule so a user mid-session can
                // finalise — or bin a mistake — without hunting in the
                // kebab menu. Only during recording / paused.
                if session.status == .recording || session.status == .paused {
                    Button {
                        Task { await session.stop() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                                .font(.callout.weight(.semibold))
                            Text("Stop & save")
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        // 2026-05-25 — padding tracks RecordCapsule's
                        // pad recipe exactly so the two capsules
                        // render as a matched pair (same width, same
                        // height, same internal rhythm — Pause toggle
                        // on top, Stop & save underneath). Egor's
                        // pass bumped horizontal 8 → 12 to give the
                        // stop glyph + label room from the capsule
                        // curve. If RecordCapsule's h-pad ever moves,
                        // bump this one in lockstep.
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .foregroundStyle(Color.daisyTextPrimary)
                        .background(
                            Capsule(style: .continuous).fill(Color.daisyBgElevated)
                        )
                        .overlay(
                            Capsule(style: .continuous).strokeBorder(Color.daisyDivider, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    // Same negative-inset compensation as RecordCapsule
                    // above so the Stop button lines up with the
                    // capsule edges (and therefore with the sidebar
                    // row chips above) instead of sitting indented.
                    .listRowInsets(EdgeInsets(top: 0, leading: -8, bottom: 4, trailing: -8))
                    .listRowBackground(Color.clear)

                    // Stop & discard — third and last, because it's the
                    // one that destroys. Same capsule recipe as Stop &
                    // save (matched trio) with destructive ink instead
                    // of a filled red button: a red slab directly under
                    // the two neutral capsules would pull the eye to the
                    // action we least want tapped. Never fires without
                    // the confirmation alert — the same one the widget's
                    // right-click menu raises.
                    Button {
                        DiscardRecordingPrompt.confirmAndDiscard(session)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .font(.callout.weight(.semibold))
                            Text("Stop & discard")
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        // Tracks RecordCapsule's pad recipe in lockstep
                        // with the Stop & save button above it.
                        .padding(.horizontal, 12)
                        .padding(.vertical, 14)
                        .foregroundStyle(Color.daisyError)
                        .background(
                            Capsule(style: .continuous).fill(Color.daisyBgElevated)
                        )
                        .overlay(
                            Capsule(style: .continuous).strokeBorder(Color.daisyDivider, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Stop recording and delete it — audio, transcript and screenshots. Asks first.")
                    .listRowInsets(EdgeInsets(top: 0, leading: -8, bottom: 4, trailing: -8))
                    .listRowBackground(Color.clear)
                }

                // System-audio status row — UNDER the Stop button.
                // Order: tap-target first, status second. The status
                // is informational ("here's what's being captured");
                // putting it above Stop made the eye land on a label
                // before the actionable button, which felt wrong.
                // Muted when the user opted out of meeting-permission
                // reminders (Settings → Permissions → "Don't remind me").
                if (session.status == .recording || session.status == .paused),
                   !settings.suppressMeetingPermissionReminders {
                    SystemAudioStatusPill(session: session)
                        // 2026-05-25 — top inset 0 → 12 per Egor's
                        // pass. The status pill belongs to a
                        // different visual family than the Pause /
                        // Stop & save / Stop & discard capsules above
                        // (capsules =
                        // primary actions; pill = informational
                        // status). Pre-bump the 4pt gap inherited
                        // from Pause→Stop made the three rows read
                        // as one undifferentiated stack. 12pt drops
                        // the pill far enough below the action pair
                        // to be parsed as "status note on the
                        // current recording" rather than "third
                        // button in a row".
                        .listRowInsets(EdgeInsets(top: 12, leading: -8, bottom: 8, trailing: -8))
                        .listRowBackground(Color.clear)
                }

                // One-time speech-model download progress. Unlike the
                // rows above this is NOT gated on recording state: the
                // big Whisper download (~626 MB) kicks off at first
                // launch, before the user ever hits Record, and used to
                // be visible only in the widget tooltip + Settings
                // badge. The pill renders nothing once engines are
                // ready, so in the common steady state this row simply
                // isn't there. Same negative-inset compensation as the
                // pills above; 12pt top gap = informational-row rhythm
                // (matches SystemAudioStatusPill's spacing rationale).
                ModelDownloadPill(settings: settings)
                    .listRowInsets(EdgeInsets(top: 12, leading: -8, bottom: 8, trailing: -8))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        // Keep the sidebar on the same paper surface as cards instead of
        // letting the system material darken it against the window.
        .scrollContentBackground(.hidden)
        .background(Color.daisyBgSidebar)
        // Foot of the sidebar: the update affordance (only when there IS
        // an update) sitting directly above the two housekeeping
        // destinations. Order matters — "Update" appears above Settings
        // rather than below it, so the row that comes and goes never
        // shifts the two rows the user reaches for by muscle memory.
        .safeAreaInset(edge: .bottom, spacing: 0) { sidebarFooter }
    }

    /// Update row + the pinned Settings / About rows.
    private var sidebarFooter: some View {
        VStack(spacing: 2) {
            updateFooter
            ForEach(MainSection.utilityCases) { section in
                utilityRow(section)
            }
        }
        .padding(.bottom, 8)
        .background(Color.daisyBgSidebar)
    }

    /// A bottom-pinned sidebar destination, hand-drawn because it lives
    /// outside `List(selection:)` and therefore gets no system chip.
    /// Mirrors the List row's geometry and colours so the two groups read
    /// as one sidebar: same ink, same selection fill, same 8pt outer
    /// inset. Selection still flows through `sidebarSelection`, so
    /// keyboard focus, the menu bar and the widget keep working.
    private func utilityRow(_ section: MainSection) -> some View {
        let isSelected = sidebarSelection == section
        return Button {
            sidebarSelection = section
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.systemImage)
                    .symbolRenderingMode(.monochrome)
                    .font(.callout)
                    .frame(width: 18)
                Text(section.title)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.daisySidebarInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.daisySidebarSelection : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Bottom-of-sidebar "Обновиться" row. Renders nothing in the steady
    /// state (up to date) so it costs zero space until there's an update.
    /// Orange per Egor's spec — see the `daisyUpdateAccent` note about the
    /// clash with the recording-reserved amber.
    @ViewBuilder
    private var updateFooter: some View {
        if let upd = updater.availableUpdate {
            Button {
                updater.checkForUpdates()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrowshape.down.circle.fill")
                        .font(.callout)
                    Text(String(localized: "sidebar.update", defaultValue: "Update"))
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.daisyUpdateAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Update available: \(upd.shortVersion)"))
            // Bottom padding and the sidebar ground now belong to
            // `sidebarFooter`, which stacks this row above Settings /
            // About; owning them here too double-padded the group.
            .padding(.horizontal, 8)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch nav.section {
        case .home:
            HomeView(session: session)
        case .library:
            LibraryView(scope: .all)
        case .notes:
            LibraryView(scope: .notes)
        case .dictation:
            DictationView()
        case .voice:
            VoiceView(settings: settings)
        case .connections:
            ConnectionsView(settings: settings)
        case .settings:
            SettingsView(settings: settings)
        case .about:
            AboutView(settings: settings)
        }
    }
}

// MARK: - Main window chrome

/// Window- and toolbar-level chrome shared by both shell branches
/// (`twoColumnSplit` / `threeColumnSplit`). Bundled into a ViewModifier
/// so it's declared once but applied DIRECTLY to each `NavigationSplitView`:
/// a `.toolbar` must attach to the split view itself to populate the
/// window toolbar, so this can't move above the shell-arity branch.
/// The shell's window floor. A named, internal constant (not inlined in
/// MainWindowChrome, which is private) because onboarding reads it too:
/// FirstRunView allows a narrower window (560pt, for its single-column
/// fallback) and pre-grows the window to THIS floor before handing over
/// to the shell — one source, so the two can't drift apart and
/// reintroduce the 300pt snap on finishing first run.
enum MainWindowShellFloor {
    static let width: CGFloat = 860
    static let height: CGFloat = 560
}

private struct MainWindowChrome: ViewModifier {

    func body(content: Content) -> some View {
        content
            // Brand pill goes into `.navigation` placement — the leading
            // zone of the window toolbar (over the sidebar). Empty
            // navigation title suppresses the system-rendered "Daisy"
            // text that would otherwise show alongside our pill.
            .navigationTitle("")
            // 2026-05-27 — remove SwiftUI's auto-generated sidebar toggle.
            // Apple macOS-26 UAF: the toggle's backing `NSSegmentedCell`
            // dereferences deallocated class metadata during layout /
            // mouseDown (same Swift-concurrency↔AppKit bridge UAF family
            // as the documented 26.0.1 Button crash), reproducing every
            // time a recording starts on 1.0.7.3 / 26.2. Hiding the
            // toggle means SwiftUI never materializes the buggy cell.
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                // Leading placement — native macOS apps put back/forward
                // here. With the AppKit title-bar transparency in
                // DaisyAppDelegate + the hidden toolbar background below,
                // leading-placement items don't push the sidebar down.
                ToolbarItem(placement: .navigation) {
                    // Wordmark only — the DaisyMark glyph was dropped here
                    // (Egor, 2026-07-21) so the brand pill is just the name.
                    Text("Daisy")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        // Inner padding sits inside the auto-fitted Liquid
                        // Glass brand pill so the wordmark has room from the
                        // pill's left and right edges instead of hugging them.
                        .padding(.horizontal, 12)
                }
            }
            // `.hidden` (NOT `.visible` — `.visible` paints a solid bar
            // that breaks sidebar-to-top). `.hidden` tells macOS 26 not to
            // composite its Liquid Glass material under the toolbar, which
            // was leaving white strips around toolbar items; the window's
            // own cream `backgroundColor` (DaisyAppDelegate) shows through.
            .daisyWindowToolbarHidden()
            .frame(minWidth: MainWindowShellFloor.width, minHeight: MainWindowShellFloor.height)
            // Warm ivory window background — matches mydaisy.io and defeats
            // macOS's default cool-gray windowBackgroundColor. Sidebar's
            // frosted material still composes on top of this warm base.
            .daisyWindowBackground(Color.daisyBgPrimary)
            // `List(.sidebar)` takes its native selection colour from the
            // NavigationSplitView owner, not from a tint on the inner List.
            // A pale neutral tint keeps that system highlight gray.
            .tint(Color.daisySidebarSelection)
    }
}

// MARK: - System audio status pill

/// Tiny status row under the Stop button during active recording.
/// Tells the user what's actually being captured right now, in
/// plain language — no "capture", "stream", "permission" jargon
/// that needs decoding mid-meeting.
///
///   • capturing → "Recording both sides" — green dot, sage tint
///   • denied    → "Only your voice — Screen Recording is off"
///                 (clickable: opens System Settings)
///   • failed    → "Only your voice — couldn't reach the other side"
///                 (full error in tooltip on hover)
///
/// `.disabled` and `.pending` render nothing — the user either
/// turned system audio off on purpose, or recording hasn't started.
struct SystemAudioStatusPill: View {
    @Bindable var session: RecordingSession

    var body: some View {
        switch session.systemAudioStatus {
        case .capturing:
            capturingPill
        case .denied:
            deniedPill
        case .failed(let message):
            failedPill(message)
        case .disabled, .pending:
            EmptyView()
        }
    }

    /// Sage-tinted capsule confirming both sides are being captured.
    /// Matches the visual weight of the warning states below so the
    /// status row stays consistent regardless of state — eye lands
    /// on the same shape, only the colour and copy change.
    ///
    /// 2026-05-25 — opacity recipe synced to the unified banner
    /// family (0.20 fill + 0.20 strokeBorder). Pre-sync this used
    /// 0.10 / 0.25 (the "subtle status pill" recipe) but the
    /// warning siblings below were on the same recipe with no
    /// affordance distinction — eye couldn't pick out that the
    /// warning was clickable. Now all three states share the
    /// banner-family 0.20/0.20 chip, vertical pad bumped 6 → 10 to
    /// give the text room when it wraps to two lines.
    private var capturingPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.daisySuccess)
                .frame(width: 6, height: 6)
            Text("Recording both sides")
                .font(.caption)
                .foregroundStyle(Color.daisyTextPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous).fill(Color.daisySuccess.opacity(0.20))
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(Color.daisySuccess.opacity(0.20), lineWidth: 0.5)
        )
    }

    /// Screen Recording permission denied — recording continues with
    /// mic only. The WHOLE pill is the tap target (opens System
    /// Settings → Privacy → Screen Recording); there is no separate
    /// "Fix" button. At the sidebar's ~200pt width the label plus a
    /// trailing CTA clipped to "Screen Recording is…", so the copy is
    /// now compact and the affordance is the pill itself (Egor,
    /// 2026-06-04). Cinnamon daisyAccent 0.20/0.20 chip; the warning
    /// reads from the glyph + the "click to fix" hint, full detail in
    /// the hover tooltip.
    private var deniedPill: some View {
        Button {
            ScreenRecordingPermission.openSystemSettings()
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.daisyAccent)
                Text("Only your voice — click to fix")
                    .font(.caption)
                    .foregroundStyle(Color.daisyTextPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous).fill(Color.daisyAccent.opacity(0.20))
            )
            .overlay(
                Capsule(style: .continuous).strokeBorder(Color.daisyAccent.opacity(0.20), lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Daisy needs Screen Recording permission to capture the other side of meetings. Click to open System Settings.")
    }

    /// System audio capture started but errored out mid-stream
    /// (display gone, ScreenCaptureKit threw, etc). The recording
    /// keeps going with mic only — full error in the help tooltip
    /// for the curious; the user-facing label stays simple.
    ///
    /// 2026-05-25 — same banner-family treatment as `deniedPill`.
    /// 2-line allowance + cinnamon 0.20/0.20 chip. No trailing CTA
    /// since there's nothing to click — the error is informational
    /// (the recording continues with mic only anyway).
    private func failedPill(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(Color.daisyAccent)
            Text("Only your voice — couldn't reach the other side")
                .font(.caption)
                .foregroundStyle(Color.daisyTextPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous).fill(Color.daisyAccent.opacity(0.20))
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(Color.daisyAccent.opacity(0.20), lineWidth: 0.5)
        )
        .help(message)
    }
}

// MARK: - Model download pill

/// The single most relevant speech-model load in flight, unified across
/// the three ASR engines (whose `LoadState` enums are distinct types).
/// `ModelDownloadPill` (main-window sidebar) and the popover's progress
/// bar in `ContentView` both resolve through this, so the two surfaces
/// always describe the same download.
///
/// Priority when several engines load at once: Whisper > Parakeet >
/// Nemotron. Whisper is the engine every recording blocks on
/// (`RecordingSession.start()` awaits it); the other two are optional
/// dictation extras, so they only count while their settings toggles
/// are on — a disabled engine sits in `.notLoaded` forever and would
/// otherwise be permanent noise. One activity, never a stack.
enum ModelLoadActivity: Equatable {
    /// Engine reports `.downloading` but no bytes have moved yet —
    /// resolving the HF repo / checking the on-disk cache. Showing
    /// "Downloading… 0%" here is misleading (a cached model never
    /// downloads anything); surfaces render this as "Checking
    /// models…" with an indeterminate bar.
    case checking
    case downloading(progress: Double, totalMB: Int?)
    /// CoreML does not publish unit progress. Whisper supplies a
    /// determinate estimate; optional engines without one pass nil.
    case loading(estimatedProgress: Double?)

    /// True while real bytes are moving — the only phase with a
    /// meaningful fraction. `totalMB` (when known) lets the label show
    /// "X / Y MB" instead of a bare percentage.
    private static func classify(_ progress: Double, totalMB: Int?) -> ModelLoadActivity {
        progress > 0.001 ? .downloading(progress: progress, totalMB: totalMB) : .checking
    }

    /// Highest-priority in-flight load, or `nil` when every relevant
    /// engine is `.notLoaded` / `.ready` / `.failed`. Failures stay
    /// out on purpose — they already surface via the Settings badge
    /// and the session status label, and a permanent red pill in the
    /// sidebar would shout forever with no action attached.
    ///
    /// Reading the engines' `@Observable` state inside a view body is
    /// what makes SwiftUI re-render as the download progresses — no
    /// timers, no polling.
    static func current(settings: AppSettings) -> ModelLoadActivity? {
        switch WhisperEngine.shared.state {
        case .downloading(let progress): return classify(progress, totalMB: WhisperEngine.shared.activeModelSizeMB)
        case .loading:
            return .loading(estimatedProgress: WhisperEngine.shared.loadProgress)
        case .notLoaded, .ready, .failed: break
        }
        if settings.dictationUseParakeet {
            switch ParakeetEngine.shared.state {
            case .downloading(let progress): return classify(progress, totalMB: nil)
            case .loading: return .loading(estimatedProgress: nil)
            case .notLoaded, .ready, .failed: break
            }
        }
        if settings.dictationUseNemotronLive {
            switch NemotronLiveEngine.shared.state {
            case .downloading(let progress): return classify(progress, totalMB: nil)
            case .loading: return .loading(estimatedProgress: nil)
            case .notLoaded, .ready, .failed: break
            }
        }
        return nil
    }
}

/// Sidebar progress row for the one-time speech-model download
/// (Whisper is ~626 MB on a fresh install; Parakeet / Nemotron when
/// those dictation engines are enabled). Until 1.0.7.19 the only
/// surfaces were the widget tooltip and the Settings → Transcription
/// badge — on a fresh install the main window gave no hint that a
/// large download was running (user feedback). Same banner-family
/// chip as `SystemAudioStatusPill` above (0.20 fill + 0.20
/// strokeBorder) with a thin linear bar inside.
///
///   • `.checking`    → "Checking models…" + indeterminate bar
///   • `.downloading` → "Downloading model… 67%" + determinate bar
///   • `.loading`     → approximate percentage + determinate bar when
///                      the engine can provide an estimate
///   • ready / failed / not loaded → renders nothing (steady state;
///     failures keep their existing Settings-badge + status-label paths)
struct ModelDownloadPill: View {
    /// Plain `let` is enough — Observation tracks the `settings.*`
    /// and `*Engine.shared.state` reads inside `body` (made via
    /// `ModelLoadActivity.current`) without `@Bindable`.
    let settings: AppSettings

    var body: some View {
        switch ModelLoadActivity.current(settings: settings) {
        case .checking?:
            // Eyes, not a download arrow — nothing is downloading yet,
            // Daisy is just looking around (cache check / repo resolve).
            pill(label: String(localized: "Checking models…"), icon: "eyes", progress: nil)
        case .downloading(let progress, let totalMB)?:
            pill(
                label: downloadLabel(progress: progress, totalMB: totalMB),
                icon: "arrow.down.circle",
                progress: min(max(progress, 0), 1)
            )
        case .loading(let estimatedProgress)?:
            pill(
                label: loadingLabel(progress: estimatedProgress),
                icon: "arrow.down.circle",
                progress: estimatedProgress
            )
        case nil:
            EmptyView()
        }
    }

    /// "Downloading model… 412 / 626 MB" when the model size is known,
    /// else a bare percentage. Bytes give the "it's actually moving"
    /// signal a lone percentage can't.
    private func downloadLabel(progress: Double, totalMB: Int?) -> String {
        if let totalMB {
            let done = Int((Double(totalMB) * min(max(progress, 0), 1)).rounded())
            let mb = "\(done) / \(totalMB) MB"
            return String(localized: "modelload.downloading.mb",
                          defaultValue: "Downloading model… \(mb)")
        }
        return String(localized: "Downloading model… \(Int(progress * 100))%")
    }

    /// CoreML does not expose exact specialization progress, so the
    /// percentage is marked approximate and reaches 100 only on success.
    private func loadingLabel(progress: Double?) -> String {
        if let progress {
            let percent = Int((min(max(progress, 0), 1) * 100).rounded())
            return String(localized: "Preparing model… about \(percent)%")
        }
        return String(localized: "Loading model…")
    }

    /// Banner-family chip — cinnamon accent (informational, not a
    /// warning, so no exclamation glyph), icon + caption on top, thin
    /// bar underneath. `progress == nil` renders the indeterminate
    /// linear bar for the brief CoreML-init phase, where no meaningful
    /// fraction exists.
    private func pill(label: String, icon: String, progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(Color.daisyAccent)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Color.daisyTextPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            // `progress == nil` MUST use ProgressView() (no value) for the
            // ANIMATED indeterminate bar. `ProgressView(value: nil, total:)`
            // renders a STATIC empty track on macOS — the reason the load
            // phase read as frozen/stuck (Egor 2026-07-23).
            Group {
                if let progress {
                    ProgressView(value: progress, total: 1.0)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .controlSize(.small)
            .tint(Color.daisyAccent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Rounded rectangle, NOT the banner capsule — with two stacked
        // lines + a progress bar inside, a capsule's fully-round ends
        // swallow the corners (user feedback on first build).
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.daisyAccent.opacity(0.20))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.daisyAccent.opacity(0.20), lineWidth: 0.5)
        )
        .help("One-time setup: Daisy transcribes on-device, so the model has to download first. Recording starts as soon as it's ready.")
    }
}


// MARK: - Service re-wiring modifiers
//
// The reactive ServiceWiring re-application that used to live as a long
// `.onChange` chain on `MainView.body`, split across three ViewModifiers
// purely to stay within the Swift type-checker's expression-complexity
// budget. Behaviour is identical to the former inline chain; only the
// grouping is new. Plain `let` (not @Bindable) is enough — Observation
// tracks the `settings.*` reads inside each `.onChange(of:)`.

private struct HotkeyStopWiring: ViewModifier {
    let settings: AppSettings
    let session: RecordingSession

    func body(content: Content) -> some View {
        content
            .onChange(of: settings.recordHotkey) { _, _ in
                ServiceWiring.applyAllHotkeys(settings: settings, session: session)
            }
            .onChange(of: settings.voiceNoteHotkey) { _, _ in
                ServiceWiring.applyAllHotkeys(settings: settings, session: session)
            }
            .onChange(of: settings.dictationHotkey) { _, _ in
                ServiceWiring.applyAllHotkeys(settings: settings, session: session)
            }
            .onChange(of: settings.rewriteSelectionHotkey) { _, _ in
                ServiceWiring.applyAllHotkeys(settings: settings, session: session)
            }
            .onChange(of: settings.layoutFixHotkey) { _, _ in
                ServiceWiring.applyAllHotkeys(settings: settings, session: session)
            }
            .onChange(of: settings.markMomentHotkey) { _, _ in
                ServiceWiring.applyAllHotkeys(settings: settings, session: session)
            }
            .onChange(of: settings.repasteLastHotkey) { _, _ in
                ServiceWiring.applyAllHotkeys(settings: settings, session: session)
            }
            // The as-you-type watcher is a keyboard tap, not a hotkey —
            // it starts and stops on its own toggle.
            .onChange(of: settings.layoutFixAuto) { _, _ in
                ServiceWiring.applyLayoutAutoFix(settings: settings)
            }
            .onChange(of: settings.screenshotNotesEnabled) { _, _ in
                ServiceWiring.applyScreenshotNotes(settings: settings)
            }
            // Dictation registration is deferred until first-run
            // completes (Input Monitoring prompt timing — see
            // ServiceWiring); re-apply the moment onboarding closes so
            // the fresh-install Fn default goes live immediately.
            .onChange(of: settings.hasShownFirstRun) { _, _ in
                ServiceWiring.applyAllHotkeys(settings: settings, session: session)
            }
            // Granola-style auto-open: jump to History on the freshly
            // finished session when the user opted in.
            .onChange(of: session.status) { _, new in
                if case .finished = new,
                   settings.showSessionAfterStop,
                   let id = session.sessionDirectory?.lastPathComponent {
                    AppNavigation.shared.openInLibrary(id)
                }
            }
    }
}

private struct AutoStartWiring: ViewModifier {
    let settings: AppSettings
    let session: RecordingSession

    func body(content: Content) -> some View {
        content
            .onChange(of: settings.autoStartPolicy) { _, _ in
                ServiceWiring.applyMeetingAutoStart(settings: settings, session: session)
                ServiceWiring.applyCalendar(settings: settings, session: session)
            }
            .onChange(of: settings.autoStartOnMeeting) { _, _ in
                ServiceWiring.applyMeetingAutoStart(settings: settings, session: session)
            }
            .onChange(of: settings.autoStartPromptMode) { _, _ in
                ServiceWiring.applyMeetingAutoStart(settings: settings, session: session)
            }
            .onChange(of: settings.autoStartFromCalendar) { _, _ in
                ServiceWiring.applyCalendar(settings: settings, session: session)
            }
            .onChange(of: settings.summaryTiming) { _, _ in
                ServiceWiring.applyEndOfDaySummaries(settings: settings, session: session)
            }
            // Changing the hour re-arms the poll, so moving it EARLIER
            // than the current time fires tonight rather than tomorrow.
            .onChange(of: settings.endOfDaySummaryHour) { _, _ in
                ServiceWiring.applyEndOfDaySummaries(settings: settings, session: session)
            }
    }
}

private struct CalendarServerWiring: ViewModifier {
    let settings: AppSettings
    let session: RecordingSession

    func body(content: Content) -> some View {
        content
            .onChange(of: CalendarService.shared.authorizationStatus) { _, status in
                let granted = (status == .fullAccess)
                if settings.calendarAccessGranted != granted {
                    settings.calendarAccessGranted = granted
                }
                ServiceWiring.applyCalendar(settings: settings, session: session)
            }
            .onChange(of: GoogleAccountStore.shared.isConnected) { _, _ in
                ServiceWiring.applyCalendar(settings: settings, session: session)
            }
            .onChange(of: settings.mcpServerEnabled) { _, _ in
                ServiceWiring.applyMCPServer(settings: settings)
            }
            .onChange(of: settings.mcpServerPort) { _, _ in
                if settings.mcpServerEnabled {
                    ServiceWiring.applyMCPServer(settings: settings)
                }
            }
    }
}
