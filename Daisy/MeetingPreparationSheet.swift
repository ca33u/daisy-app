// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  MeetingPreparationSheet.swift
//  Daisy
//
//  Native preparation surface opened from a Home agenda row.
//

import SwiftUI
import UniformTypeIdentifiers

struct MeetingPreparationSheet: View {
    let meeting: DaisyMeeting
    @Bindable var session: RecordingSession
    let settings: AppSettings

    @Environment(\.dismiss) private var dismiss
    @Bindable private var preparations = MeetingPreparationStore.shared
    @Bindable private var folders = FolderStore.shared
    @Bindable private var sessions = SessionStore.shared
    @Bindable private var actionItems = ActionItemStore.shared
    @Bindable private var briefs = PreMeetingBriefStore.shared

    @State private var draft: MeetingPreparation
    @State private var isNewPreparation: Bool
    @State private var isChoosingPlanFile = false
    @State private var importingPlanFile = false
    @State private var fileImportWillReplace = false
    @State private var pendingPlanImport: ExtractedMeetingPlanFile?
    @State private var showPlanReplacementConfirmation = false
    @State private var planImportError: String?
    @State private var isPlanDropTargeted = false
    @State private var showProjectPopover = false
    @State private var showTagPopover = false
    @State private var tagDraft = ""
    @FocusState private var tagFieldFocused: Bool
    @FocusState private var planTextFocused: Bool

    init(meeting: DaisyMeeting, session: RecordingSession, settings: AppSettings) {
        self.meeting = meeting
        self.session = session
        self.settings = settings

        let key = PreMeetingBriefStore.key(for: meeting)
        let store = MeetingPreparationStore.shared
        let wasSaved = store.preparations[key] != nil
        let configuredFolder = FolderStore.shared.existingFolder(
            slug: settings.defaultMeetingFolderSlug
        ) ?? .inbox
        let suggestedTag = TagSuggestion.suggest(from: meeting.attendeeEmails) ?? ""
        let initialDraft = store.preparation(
            for: meeting,
            defaultProjectSlug: configuredFolder.slug,
            suggestedTag: suggestedTag
        )
        _draft = State(initialValue: initialDraft)
        _tagDraft = State(initialValue: initialDraft.tag)
        _isNewPreparation = State(initialValue: !wasSaved)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    meetingHeader
                    assignmentSection
                    planSection
                    briefSection
                    tasksSection
                }
                .padding(24)
            }

            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(PreparationCapsuleButtonStyle(tone: .neutral))
                    .keyboardShortcut(.cancelAction)
                Button {
                    startRecording()
                } label: {
                    Label("Start recording", systemImage: "record.circle")
                }
                .buttonStyle(PreparationCapsuleButtonStyle(tone: .primary))
                .keyboardShortcut(.defaultAction)
                // Keep active/paused enabled: the recording layer supports
                // the valid back-to-back flow by saving the previous meeting
                // before starting this one. Only transitional states cannot
                // accept another start request.
                .disabled(startUnavailable)
            }
            .padding(16)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 620, idealHeight: 720)
        .background(Color.daisyBgPrimary)
        .onAppear {
            // On first open, task matches are genuine existing relations,
            // so preserve them in the preparation without an extra click.
            // Once saved, an intentionally cleared selection stays cleared.
            if isNewPreparation {
                draft.linkedTaskIDs = relatedTasks.map(\.id)
                isNewPreparation = false
                persistDraft()
            }
        }
        .onChange(of: draft) { _, _ in persistDraft() }
        .fileImporter(
            isPresented: $isChoosingPlanFile,
            allowedContentTypes: MeetingPlanFileExtractor.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handlePlanFileSelection(result)
        }
        .alert("Replace current plan?", isPresented: $showPlanReplacementConfirmation) {
            Button("Cancel", role: .cancel) { pendingPlanImport = nil }
            Button("Replace", role: .destructive) {
                if let pendingPlanImport { applyPlanImport(pendingPlanImport) }
                pendingPlanImport = nil
            }
        } message: {
            Text("Importing this file will replace the plan text you entered manually.")
        }
        .alert(
            "Couldn’t import file",
            isPresented: Binding(
                get: { planImportError != nil },
                set: { if !$0 { planImportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { planImportError = nil }
        } message: {
            Text(planImportError ?? "")
        }
    }

    private var meetingHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.daisyTextPrimary)
                    Text(meetingTime)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let url = meeting.meetingURL {
                    Link(destination: url) {
                        Label("Join call", systemImage: "video")
                    }
                    .buttonStyle(.bordered)
                }
            }

            if !meeting.attendees.isEmpty {
                infoRow(
                    icon: "person.2",
                    title: String(localized: "Participants"),
                    value: meeting.attendees.joined(separator: ", ")
                )
            }
            if let location = meeting.location, !location.isEmpty {
                infoRow(
                    icon: "mappin.and.ellipse",
                    title: String(localized: "Location"),
                    value: location
                )
            }
        }
    }

    private var assignmentSection: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Project")
                    .font(.callout)
                    .foregroundStyle(Color.daisyTextPrimary)
                projectSelector
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 7) {
                Text("Tag")
                    .font(.callout)
                    .foregroundStyle(Color.daisyTextPrimary)
                tagSelector
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Meeting plan")
                .font(.callout)
                .foregroundStyle(Color.daisyTextPrimary)
            Text("Add the agenda, talking points, or a sales script. Daisy will keep this version with the recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let source = draft.planSource {
                importedFileCard(source)
            }
            planDropZone
            planTextArea
        }
    }

    private var tagSelector: some View {
        Button {
            tagDraft = draft.tag
            showTagPopover = true
        } label: {
            selectionFieldLabel(
                draft.tag.isEmpty ? String(localized: "Add tag") : draft.tag
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .popover(isPresented: $showTagPopover, arrowEdge: .bottom) {
            tagPopoverContent
        }
    }

    private var projectSelector: some View {
        Button {
            showProjectPopover = true
        } label: {
            selectionFieldLabel(projectName)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .popover(isPresented: $showProjectPopover, arrowEdge: .bottom) {
            projectPopoverContent
        }
    }

    private var projectPopoverContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(folders.allFolders) { folder in
                    Button {
                        draft.projectSlug = folder.slug
                        showProjectPopover = false
                    } label: {
                        HStack {
                            Text(folder.name)
                                .lineLimit(1)
                            Spacer()
                            if folder.slug == draft.projectSlug {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 5)
                }
            }
        }
        .frame(width: 240, height: min(CGFloat(folders.allFolders.count) * 30, 210))
        .padding(12)
    }

    private var projectName: String {
        folders.allFolders.first(where: { $0.slug == draft.projectSlug })?.name
            ?? draft.projectSlug
    }

    private func selectionFieldLabel(_ value: String) -> some View {
        HStack(spacing: 8) {
            Text(value)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(Color.daisyTextPrimary)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.daisySelectionBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.daisySelectionBorder, lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var tagPopoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Tag…", text: $tagDraft)
                .textFieldStyle(.roundedBorder)
                .focused($tagFieldFocused)
                .onSubmit {
                    commitTag()
                    showTagPopover = false
                }

            if !sessions.distinctTagsByFrequency.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sessions.distinctTagsByFrequency, id: \.self) { tag in
                            Button {
                                tagDraft = tag
                                commitTag()
                                showTagPopover = false
                            } label: {
                                HStack {
                                    Text(tag)
                                    Spacer()
                                    if tag == draft.tag {
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

            if !draft.tag.isEmpty {
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

    private var planDropZone: some View {
        VStack(spacing: 8) {
            if importingPlanFile {
                ProgressView()
                    .controlSize(.small)
                Text("Importing file…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: isPlanDropTargeted ? "arrow.down.doc.fill" : "arrow.down.doc")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(draft.planSource == nil
                     ? "Drop a TXT, Markdown, PDF, or DOCX file here"
                     : "Drop another file here to replace it")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Choose") {
                    fileImportWillReplace = draft.planSource != nil
                    isChoosingPlanFile = true
                }
                .buttonStyle(.bordered)
                .tint(Color.daisyTextPrimary)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .background(
            isPlanDropTargeted ? Color.daisySelectionBackground : Color.daisyBgElevated,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isPlanDropTargeted ? Color.daisyTextSecondary : Color.daisyDivider,
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            fileImportWillReplace = draft.planSource != nil
            importPlanFile(from: url)
            return true
        } isTargeted: { targeted in
            isPlanDropTargeted = targeted
        }
    }

    private var planTextArea: some View {
        TextField("Enter a plan or script…", text: $draft.planText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(8...14)
            .focused($planTextFocused)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .background(
                Color.daisySelectionBackground.opacity(0.45),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    planTextFocused ? Color.daisyTextSecondary : Color.daisySelectionBorder,
                    lineWidth: planTextFocused ? 1.25 : 0.75
                )
        )
    }

    private func importedFileCard(_ source: MeetingPlanSource) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(Color.daisyHomeAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.fileName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("Imported text · \(source.extractedCharacterCount.formatted()) characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove file") {
                // The editable text is already local Daisy data. Removing
                // the source association must not destroy manual edits.
                draft.planSource = nil
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Remove the file label and keep the editable plan text")
        }
        .padding(10)
        .background(Color.daisyBgElevated, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.daisyDivider, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var briefSection: some View {
        switch briefs.state(for: meeting) {
        case .noHistory:
            EmptyView()
        default:
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Brief")
                PreMeetingBriefCard(meeting: meeting, settings: settings)
            }
        }
    }

    @ViewBuilder
    private var tasksSection: some View {
        if !relatedTasks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Related tasks")
                ForEach(relatedTasks) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Button {
                            toggleTaskLink(item.id)
                        } label: {
                            Image(systemName: draft.linkedTaskIDs.contains(item.id)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(draft.linkedTaskIDs.contains(item.id)
                                                 ? Color.daisyHomeAccent : .secondary)
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.text)
                                .font(.callout)
                                .strikethrough(item.isDone)
                            Text(item.sessionTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var relatedTasks: [TrackedActionItem] {
        let matchingSessionIDs = Set(PreMeetingBriefStore.matchingSessions(
            for: meeting,
            in: sessions.sessions,
            now: Date(),
            limit: 10,
            requireStrong: false
        ).map(\.id))
        return actionItems.items.filter {
            matchingSessionIDs.contains($0.sessionID) || draft.linkedTaskIDs.contains($0.id)
        }
    }

    private var briefSourceSessionIDs: [String] {
        guard case .ready(let brief) = briefs.state(for: meeting) else { return [] }
        return brief.sourceSessionIDs
    }

    private var meetingTime: String {
        let date = meeting.startDate.formatted(date: .abbreviated, time: .omitted)
        let start = meeting.startDate.formatted(date: .omitted, time: .shortened)
        let end = meeting.endDate.formatted(date: .omitted, time: .shortened)
        return "\(date) · \(start)–\(end)"
    }

    private var startUnavailable: Bool {
        session.status == .preparing || session.status == .stopping
    }

    private func infoRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(title + ":")
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func toggleTaskLink(_ id: String) {
        if let index = draft.linkedTaskIDs.firstIndex(of: id) {
            draft.linkedTaskIDs.remove(at: index)
        } else {
            draft.linkedTaskIDs.append(id)
        }
    }

    private func persistDraft() {
        preparations.save(draft)
    }

    private func handlePlanFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            fileImportWillReplace = false
            // Cancellation is represented as a Cocoa user-cancelled error;
            // closing the picker should stay quiet.
            if (error as NSError).code != NSUserCancelledError {
                planImportError = error.localizedDescription
            }
        case .success(let urls):
            guard let url = urls.first else { return }
            importPlanFile(from: url)
        }
    }

    private func importPlanFile(from url: URL) {
        guard !importingPlanFile else { return }
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        importingPlanFile = true
        Task {
            defer {
                if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
                importingPlanFile = false
            }
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    try MeetingPlanFileExtractor.extract(from: url)
                }.value
                receivePlanImport(imported)
            } catch {
                fileImportWillReplace = false
                planImportError = error.localizedDescription
            }
        }
    }

    private func receivePlanImport(_ imported: ExtractedMeetingPlanFile) {
        let hasManualText = !draft.planText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasManualText && !fileImportWillReplace {
            pendingPlanImport = imported
            showPlanReplacementConfirmation = true
        } else {
            applyPlanImport(imported)
        }
        fileImportWillReplace = false
    }

    private func applyPlanImport(_ imported: ExtractedMeetingPlanFile) {
        draft.planText = imported.text
        draft.planSource = imported.source
    }

    private func commitTag() {
        let trimmed = tagDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != draft.tag else { return }
        draft.tag = trimmed
    }

    private func startRecording() {
        persistDraft()
        let snapshot = MeetingPreparationSnapshot(
            preparation: draft,
            briefSourceSessionIDs: briefSourceSessionIDs
        )
        dismiss()
        Task {
            await session.startFromMeeting(
                meeting,
                preparation: snapshot,
                userInitiated: true
            )
        }
    }
}

private struct PreparationCapsuleButtonStyle: ButtonStyle {
    enum Tone: Equatable {
        case primary
        case neutral
    }

    let tone: Tone

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DaisyCapsuleMetrics.font)
            .padding(.horizontal, DaisyCapsuleMetrics.horizontalPadding)
            .padding(.vertical, DaisyCapsuleMetrics.verticalPadding)
            .foregroundStyle(tone == .primary ? Color.white : Color.daisyTextPrimary)
            .background(
                Capsule(style: .continuous)
                    .fill(tone == .primary ? Color.daisyRecordIdle : Color.daisySelectionBackground)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        tone == .primary ? Color.white.opacity(0.12) : Color.daisySelectionBorder,
                        lineWidth: 0.5
                    )
            )
            .daisyGlass(in: Capsule(style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}
