//
//  SettingsRows.swift
//  Daisy
//
//  The rows of Settings that have a name of their own: the one table
//  search reads, deep links land on, and the views anchor with
//  `.settingsRow(_:)` (Settings restructure S1, Egor 24.10.2026).
//
//  A row knows its tab and its title here, not in the view, so search
//  finds a row whichever tab is mounted, and a test can hold the table
//  against the views (`SettingsFrameTests`: every case is anchored by
//  exactly one `.settingsRow(.case)` in Daisy/).
//
//  Raw values are `<tab>.<row>` — deep links and any saved reference go
//  through them. Moving a row to another tab changes `tab` and the
//  prefix together; the test checks they agree. S2 moved «Summarize»
//  (ai.summaryTiming → meetings.summaryTiming).
//

import SwiftUI

enum SettingsRow: String, CaseIterable, Hashable, Sendable {
    // General
    case displayName = "general.displayName"
    case interfaceLanguage = "general.interfaceLanguage"
    case theme = "general.theme"
    case compactMenuBar = "general.compactMenuBar"
    case floatingWidget = "general.floatingWidget"
    case menuBarNextMeeting = "general.menuBarNextMeeting"
    case notifications = "general.notifications"

    // Shortcuts
    case recordHotkey = "shortcuts.record"
    case dictationHotkey = "shortcuts.dictation"
    case daisyKey = "shortcuts.daisyKey"
    case markMomentHotkey = "shortcuts.markMoment"
    case repasteHotkey = "shortcuts.repaste"
    case daisyKeyMeetingCommands = "shortcuts.meetingCommands"
    case sideNotesLeaveMeeting = "shortcuts.sideNotesLeaveMeeting"
    case daisyKeyCloudGrants = "shortcuts.cloudGrants"

    // Meetings
    case microphone = "meetings.microphone"
    case noiseReduction = "meetings.noiseReduction"
    case recordOtherSide = "meetings.recordOtherSide"
    case macOutput = "meetings.macOutput"
    case processingPlan = "meetings.processingPlan"
    case processLaterOnCharger = "meetings.processLaterOnCharger"
    case meetingModel = "meetings.meetingModel"
    case liveTranscript = "meetings.liveTranscript"
    case autoRecord = "meetings.autoRecord"
    case workingHours = "meetings.workingHours"
    case showSessionAfterStop = "meetings.showSessionAfterStop"
    case screenCapture = "meetings.screenCapture"
    case screenshotInterval = "meetings.screenshotInterval"
    case screenshotNotes = "meetings.screenshotNotes"
    case askToStop = "meetings.askToStop"
    case speakersInTranscript = "meetings.speakersInTranscript"
    case nameKnownPeople = "meetings.nameKnownPeople"
    case splitMicVoices = "meetings.splitMicVoices"
    case removeEcho = "meetings.removeEcho"
    case knownSpeakers = "meetings.knownSpeakers"
    case summaryTiming = "meetings.summaryTiming"

    // Dictation
    case dictationEngine = "dictation.engine"
    case fixProductNames = "dictation.fixProductNames"
    case pasteViaClipboard = "dictation.pasteViaClipboard"
    case livePreview = "dictation.livePreview"
    case transcriptionLanguage = "dictation.transcriptionLanguage"
    case layoutFixer = "dictation.layoutFixer"
    case layoutFixAsYouType = "dictation.layoutFixAsYouType"
    case layoutFixSwitchesSource = "dictation.layoutFixSwitchesSource"
    case layoutFixHotkey = "dictation.layoutFixHotkey"

    // AI
    case summaryProvider = "ai.summaryProvider"
    case summaryLanguage = "ai.summaryLanguage"
    case protectSensitiveData = "ai.protectSensitiveData"
    case secondPass = "ai.secondPass"
    case followUpsInMyVoice = "ai.followUpsInMyVoice"
    case morningBrief = "ai.morningBrief"
    case preMeetingBrief = "ai.preMeetingBrief"
    case researchAttendees = "ai.researchAttendees"
    case myStyle = "ai.myStyle"

    // Library
    case recordingsFolder = "library.recordingsFolder"
    case spaceUsed = "library.spaceUsed"
    case deleteAudioFiles = "library.deleteAudioFiles"
    case deleteRecordings = "library.deleteRecordings"
    case audioStorage = "library.audioStorage"
    case defaultMeetingProject = "library.defaultMeetingProject"
    case defaultNoteProject = "library.defaultNoteProject"
    case iCloudSync = "library.iCloudSync"
    case speechModels = "library.speechModels"
    case downloadModels = "library.downloadModels"

    // Connections
    case notion = "connections.notion"
    case mcpServer = "connections.mcpServer"

    // Privacy
    case microphoneAccess = "privacy.microphone"
    case accessibility = "privacy.accessibility"
    case screenRecording = "privacy.screenRecording"
    case calendarApple = "privacy.calendarApple"
    case calendarGoogle = "privacy.calendarGoogle"
    case notificationPermission = "privacy.notifications"

    var tab: SettingsTab {
        switch self {
        case .displayName, .interfaceLanguage, .theme, .compactMenuBar, .floatingWidget,
             .menuBarNextMeeting, .notifications:
            .general
        case .recordHotkey, .dictationHotkey, .daisyKey, .markMomentHotkey, .repasteHotkey,
             .daisyKeyMeetingCommands, .sideNotesLeaveMeeting, .daisyKeyCloudGrants:
            .shortcuts
        case .microphone, .noiseReduction, .recordOtherSide, .macOutput, .processingPlan,
             .processLaterOnCharger, .meetingModel, .liveTranscript, .autoRecord, .workingHours,
             .showSessionAfterStop, .screenCapture, .screenshotInterval, .screenshotNotes, .askToStop,
             .speakersInTranscript, .nameKnownPeople, .splitMicVoices, .removeEcho, .knownSpeakers,
             .summaryTiming:
            .meetings
        case .dictationEngine, .fixProductNames, .pasteViaClipboard, .livePreview,
             .transcriptionLanguage, .layoutFixer, .layoutFixAsYouType, .layoutFixSwitchesSource,
             .layoutFixHotkey:
            .dictation
        case .summaryProvider, .summaryLanguage, .protectSensitiveData, .secondPass,
             .followUpsInMyVoice, .morningBrief, .preMeetingBrief, .researchAttendees, .myStyle:
            .ai
        case .recordingsFolder, .spaceUsed, .deleteAudioFiles, .deleteRecordings, .audioStorage,
             .defaultMeetingProject, .defaultNoteProject, .iCloudSync, .speechModels, .downloadModels:
            .library
        case .notion, .mcpServer:
            .connections
        case .microphoneAccess, .accessibility, .screenRecording, .calendarApple, .calendarGoogle,
             .notificationPermission:
            .privacy
        }
    }

    /// The row's name as its label reads — the same catalog key the view
    /// uses, so search shows what the eye then finds. Where the label
    /// alone is ambiguous across tabs («Language» was three different
    /// things) the title says which.
    var titleResource: LocalizedStringResource {
        switch self {
        case .displayName: "Your name"
        case .interfaceLanguage: "Interface language"
        case .theme: "Theme"
        case .compactMenuBar: "Compact menu bar"
        case .floatingWidget: "Floating widget"
        case .menuBarNextMeeting: "Show next meeting in the menu bar"
        case .notifications: "Notifications"
        case .recordHotkey: "Record a meeting"
        case .dictationHotkey: "Dictation"
        case .daisyKey: "Daisy key"
        case .markMomentHotkey: "Mark this moment"
        case .repasteHotkey: "Paste my last dictation"
        case .daisyKeyMeetingCommands: "Commands during a meeting"
        case .sideNotesLeaveMeeting: "Side notes leave the meeting"
        case .daisyKeyCloudGrants: "Allowed to send to the cloud"
        case .microphone: "Microphone"
        case .noiseReduction: "Reduce background noise"
        case .recordOtherSide: "Record the other side"
        case .macOutput: "Mac output"
        case .processingPlan: "Meeting processing"
        case .processLaterOnCharger: "Process meetings later, on a charger"
        case .meetingModel: "Meeting model"
        case .liveTranscript: "Live transcript"
        case .autoRecord: "Auto-record"
        case .workingHours: "Track working hours"
        case .showSessionAfterStop: "Open the session window when recording stops"
        case .screenCapture: "Capture what's shared on screen"
        case .screenshotInterval: "Capture every"
        case .screenshotNotes: "Turn my screenshots into notes"
        case .askToStop: "Ask to stop when the meeting ends"
        case .speakersInTranscript: "Speakers in transcript"
        case .nameKnownPeople: "Name known people"
        case .splitMicVoices: "Split voices in my mic"
        case .removeEcho: "Remove echo from my mic"
        case .knownSpeakers: "Known speakers"
        case .dictationEngine: "Dictation engine"
        case .fixProductNames: "Fix product names"
        case .pasteViaClipboard: "Paste through the clipboard"
        case .livePreview: "Live preview while dictating"
        case .transcriptionLanguage: "Transcription language"
        case .layoutFixer: "Layout fixer"
        case .layoutFixAsYouType: "Fix the layout as I type"
        case .layoutFixSwitchesSource: "Switch the input source after a fix"
        case .layoutFixHotkey: "Fix the keyboard layout"
        case .summaryProvider: "Summary provider"
        case .summaryLanguage: "Summary language"
        case .summaryTiming: "Summarize"
        case .protectSensitiveData: "Protect sensitive data before cloud AI"
        case .secondPass: "Second pass over the transcript"
        case .followUpsInMyVoice: "Write follow-ups in my voice"
        case .morningBrief: "Morning brief"
        case .preMeetingBrief: "Pre-meeting brief"
        case .researchAttendees: "Research attendees online"
        case .myStyle: "My style"
        case .recordingsFolder: "Recordings folder"
        case .spaceUsed: "Space used"
        case .deleteAudioFiles: "Delete audio files"
        case .deleteRecordings: "Delete recordings"
        case .audioStorage: "Audio storage"
        case .defaultMeetingProject: "Default project for meetings"
        case .defaultNoteProject: "Default project for notes"
        case .iCloudSync: "Sync with the iPhone through iCloud"
        case .speechModels: "Models"
        case .downloadModels: "Download models now"
        case .notion: "Notion"
        case .mcpServer: "MCP server"
        case .microphoneAccess: "Microphone"
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .calendarApple: "Calendar (Apple)"
        case .calendarGoogle: "Calendar (Google)"
        case .notificationPermission: "Notifications"
        }
    }

    var title: String { String(localized: titleResource) }

    /// The row that stands in for this one while it is hidden — the
    /// layout fixer's rows only exist with the fixer on, so a link to
    /// them lands on its switch instead of on nothing.
    var standIn: SettingsRow? {
        switch self {
        case .layoutFixAsYouType, .layoutFixSwitchesSource, .layoutFixHotkey: .layoutFixer
        case .screenshotInterval: .screenCapture
        // The grants list is there only once a command was allowed.
        case .daisyKeyCloudGrants: .daisyKeyMeetingCommands
        default: nil
        }
    }

    /// The switches that hide rows. Plain values rather than
    /// `AppSettings`, which reads the real prefs.
    struct Switches: Equatable, Sendable {
        var layoutFixEnabled = true
        var screenshotsEnabled = true
        var hasCloudGrants = true

        @MainActor
        static func current(_ settings: AppSettings) -> Switches {
            Switches(layoutFixEnabled: settings.layoutFixEnabled,
                     screenshotsEnabled: settings.screenshotsEnabled,
                     hasCloudGrants: !DaisyKeyController.cloudAllowedProviders.isEmpty)
        }
    }

    /// Whether the row is on screen given the switches that hide rows.
    func isShown(_ switches: Switches) -> Bool {
        switch self {
        case .layoutFixAsYouType, .layoutFixSwitchesSource, .layoutFixHotkey: switches.layoutFixEnabled
        case .screenshotInterval: switches.screenshotsEnabled
        case .daisyKeyCloudGrants: switches.hasCloudGrants
        default: true
        }
    }

    /// Where a link lands: the row itself, or its stand-in while hidden.
    func target(_ switches: Switches) -> SettingsRow {
        isShown(switches) ? self : (standIn ?? self)
    }

    /// The Connections page keeps two forms behind its own switch; a row
    /// there names the one it lives on so a link can switch to it first.
    var connectionSection: ConnectionSection? {
        switch self {
        case .notion: .autoRouting
        case .mcpServer: .mcpServer
        default: nil
        }
    }
}

// MARK: - Search

/// Filtering the row table by title. Pure, so the tests drive it with
/// their own entries; Settings builds `entries` from `SettingsRow`.
enum SettingsSearch {
    struct Entry: Equatable, Sendable {
        let row: SettingsRow
        /// Every name the row answers to — the title in the interface
        /// language and the English one, so «микрофон» and "microphone"
        /// both find it whichever language Daisy is in.
        let titles: [String]
    }

    static var entries: [Entry] {
        SettingsRow.allCases.map { row in
            let english = row.titleResource.key
            let local = row.title
            return Entry(row: row, titles: local == english ? [local] : [local, english])
        }
    }

    /// Case, diacritics (ё → е) and runs of spaces don't count.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Rows whose title contains the query: titles that start with it
    /// first, then titles with a word that does, then the rest; table
    /// order within each. An empty query finds nothing — the tab list is
    /// what shows then.
    static func results(for query: String, in entries: [Entry]) -> [SettingsRow] {
        let needle = normalize(query)
        guard !needle.isEmpty else { return [] }
        var ranked: [(rank: Int, index: Int, row: SettingsRow)] = []
        for (index, entry) in entries.enumerated() {
            let ranks = entry.titles.compactMap { rank(of: needle, in: normalize($0)) }
            if let best = ranks.min() { ranked.append((best, index, entry.row)) }
        }
        return ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.row)
    }

    private static func rank(of needle: String, in title: String) -> Int? {
        if title.hasPrefix(needle) { return 0 }
        guard title.contains(needle) else { return nil }
        let wordStarts = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return wordStarts.contains { $0.hasPrefix(needle) } ? 1 : 2
    }
}

// MARK: - Anchors and the highlight

extension View {
    /// Names a Settings row: an anchor a deep link scrolls to, and the
    /// soft accent wash that marks it for a couple of seconds after.
    func settingsRow(_ row: SettingsRow) -> some View {
        modifier(SettingsRowAnchor(row: row))
    }

    /// The scroll view of one Settings form, which takes a pending row
    /// meant for it (`accepts`) and brings it into view. Defaults to the
    /// rows of `tab`.
    func settingsScrollTarget(
        _ tab: SettingsTab,
        settings: AppSettings,
        accepts: @escaping (SettingsRow) -> Bool = { _ in true }
    ) -> some View {
        modifier(SettingsScrollTarget(tab: tab, settings: settings, accepts: accepts))
    }
}

private struct SettingsRowAnchor: ViewModifier {
    let row: SettingsRow
    private var nav: AppNavigation { AppNavigation.shared }

    func body(content: Content) -> some View {
        let lit = nav.highlightedSettingsRow == row
        content
            .id(row)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.daisyAccent.opacity(lit ? 0.16 : 0))
                    .padding(.horizontal, -6)
                    .padding(.vertical, -4)
                    .allowsHitTesting(false)
            }
            // Quick in, slow out: the wash is there when the scroll stops
            // and fades rather than blinks off.
            .animation(.easeOut(duration: lit ? 0.2 : 0.9), value: lit)
    }
}

private struct SettingsScrollTarget: ViewModifier {
    let tab: SettingsTab
    let settings: AppSettings
    let accepts: (SettingsRow) -> Bool
    private var nav: AppNavigation { AppNavigation.shared }

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .onAppear { take(proxy) }
                .onChange(of: nav.pendingSettingsRow) { _, _ in take(proxy) }
        }
    }

    private func take(_ proxy: ScrollViewProxy) {
        guard let pending = nav.pendingSettingsRow,
              pending.tab == tab, accepts(pending) else { return }
        nav.pendingSettingsRow = nil
        let row = pending.target(.current(settings))
        Task { @MainActor in
            // The form lays out its rows a beat after it appears; a
            // scroll before that lands short.
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(row, anchor: .center)
            }
            nav.highlight(row)
        }
    }
}
