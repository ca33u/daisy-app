//
//  MeetingTemplatesView.swift
//  Daisy
//
//  «My style» → «Follow-ups» and «Meeting notes» (backlog 35): the
//  person's templates, made from examples or section by section, with the
//  rule that picks them and a preview on a real meeting before saving.
//  See `MeetingTemplates` for what a template does and where it goes.
//

import SwiftUI
import UniformTypeIdentifiers

/// The tabs of «My style».
enum MyStyleTab: String, CaseIterable, Identifiable, Sendable {
    case voice, followUps, meetingNotes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .voice: String(localized: "Voice")
        case .followUps: String(localized: "Follow-ups")
        case .meetingNotes: String(localized: "Meeting notes")
        }
    }
}

// MARK: - A tab's list

struct MeetingTemplatesPane: View {
    let kind: MeetingTemplateKind

    @State private var editing: MeetingTemplate?
    @State private var showsArchived = false
    private var store: MeetingTemplateStore { .shared }

    private var russian: Bool { Bundle.main.preferredLocalizations.first?.hasPrefix("ru") == true }

    var body: some View {
        let live = store.templates(kind)
        let archived = store.templates(kind, includingArchived: true).filter(\.archived)
        VStack(alignment: .leading, spacing: 14) {
            Text(kind == .followUp
                 ? String(localized: "What your follow-up letters say and in what order — your voice is how they sound. A meeting gets a template by its folder, a word in its title, or the default.")
                 : String(localized: "The sections of your meeting notes — a sales call, an interview, a standup. The standard summary stays; the card shows the template’s view beside it, every point with its timecode."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            addButtons

            if live.isEmpty {
                Text(kind == .followUp ? String(localized: "No follow-up templates yet.") : String(localized: "No notes templates yet."))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            }
            ForEach(live) { template in
                TemplateRow(template: template, onEdit: { editing = template })
            }

            if !archived.isEmpty {
                DisclosureGroup(isExpanded: $showsArchived) {
                    ForEach(archived) { template in
                        HStack {
                            Text(template.name)
                            Spacer()
                            Button("Restore") { store.setArchived(false, template.id) }
                                .buttonStyle(.borderless)
                            Button(role: .destructive) { store.delete(template.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                        .font(.callout)
                        .padding(.vertical, 2)
                    }
                } label: {
                    Text("Archived (\(archived.count))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            // What leaves the Mac (backlog 35 «Приватность»).
            Text("Templates stay on this Mac. With a cloud summary provider, a template’s structure is sent with the transcript — never the example letters it was made from.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(item: $editing) { template in
            MeetingTemplateEditor(template: template, isNew: !store.templates.contains { $0.id == template.id })
        }
    }

    @ViewBuilder
    private var addButtons: some View {
        HStack(spacing: 10) {
            if kind == .followUp {
                Button {
                    editing = MeetingTemplate(kind: .followUp, name: "")
                } label: {
                    Label("New follow-up template", systemImage: "plus")
                }
            } else {
                Menu {
                    ForEach(BuiltInSummaryTemplates.all(russian: russian)) { builtIn in
                        Button(builtIn.name) {
                            var copy = builtIn
                            copy.id = UUID()
                            editing = copy
                        }
                    }
                } label: {
                    Label("From the built-ins", systemImage: "square.grid.2x2")
                }
                .fixedSize()
                Button {
                    editing = MeetingTemplate(kind: .summary, name: "",
                                              sections: [MeetingTemplateSection(title: "")])
                } label: {
                    Label("New template", systemImage: "plus")
                }
            }
        }
        .controlSize(.regular)
    }
}

private struct TemplateRow: View {
    let template: MeetingTemplate
    let onEdit: () -> Void
    private var store: MeetingTemplateStore { .shared }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(template.name).font(.headline)
                    if template.isDefault {
                        Text("Default")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
                Text(ruleLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(usageLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                // Not used for a month: offer the archive, never do it
                // unasked (research 21.10).
                if template.isStale(), !template.isDefault {
                    HStack(spacing: 6) {
                        Text("Not used for 30 days.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Archive") { store.setArchived(true, template.id) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
            Spacer(minLength: 8)
            Button("Edit", action: onEdit)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Menu {
                Button(template.isDefault ? String(localized: "Not the default") : String(localized: "Use by default")) {
                    var copy = template
                    copy.isDefault.toggle()
                    store.save(copy)
                }
                Button("Archive") { store.setArchived(true, template.id) }
                Button("Delete", role: .destructive) { store.delete(template.id) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.daisyBgSidebar))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.daisyDivider, lineWidth: 0.5))
    }

    private var ruleLine: String {
        var parts: [String] = []
        let folders = template.folderSlugs.compactMap { FolderStore.shared.existingFolder(slug: $0)?.name }
        if !folders.isEmpty { parts.append(String(localized: "Folders: \(folders.joined(separator: ", "))")) }
        if !template.titleWords.isEmpty { parts.append(String(localized: "Title words: \(template.titleWords.joined(separator: ", "))")) }
        if parts.isEmpty {
            return template.isDefault ? String(localized: "Every meeting without another template")
                : String(localized: "Only when picked in a meeting’s card")
        }
        return parts.joined(separator: " · ")
    }

    private var usageLine: String {
        guard template.useCount > 0, let last = template.lastUsedAt else { return String(localized: "Not used yet") }
        return String(localized: "Used \(template.useCount) times · last \(last.formatted(date: .abbreviated, time: .omitted))")
    }
}

// MARK: - Editor

struct MeetingTemplateEditor: View {
    @State var template: MeetingTemplate
    let isNew: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var examples = ""
    @State private var removedNames: [String] = []
    @State private var isReading = false
    @State private var readingFailed = false
    @State private var asksCloudReading = false
    @State private var titleWordsText = ""
    @State private var showsFromNote = false
    @State private var preview: TemplatePreview?
    @State private var choosingFiles = false
    @State private var dropTargeted = false
    @State private var isPreviewing = false

    private var store: MeetingTemplateStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(isNew ? (template.kind == .followUp ? String(localized: "New follow-up template") : String(localized: "New notes template"))
                               : String(localized: "Edit template"))
                        .font(.title2.weight(.semibold))
                    TextField(template.kind == .followUp ? String(localized: "Name — “Client after a sale”") : String(localized: "Name — “Candidate interview”"),
                              text: $template.name)
                        .textFieldStyle(.roundedBorder)
                    if template.kind == .followUp { followUpBody } else { summaryBody }
                    rulesBody
                }
                .padding(20)
            }
            Divider()
            HStack {
                if template.kind == .summary {
                    Button {
                        Task { await runPreview() }
                    } label: {
                        Label("Preview on a recent meeting", systemImage: "eye")
                    }
                    .disabled(!canSave || isPreviewing)
                    if isPreviewing { ProgressView().controlSize(.small) }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(14)
        }
        .frame(width: 600, height: 640)
        .onAppear { titleWordsText = template.titleWords.joined(separator: ", ") }
        .alert(String(localized: "Read the examples with \(Summarizer.shared.providerKind.shortName)?"),
               isPresented: $asksCloudReading) {
            Button("Allow") {
                UserDefaults.standard.set(true, forKey: MeetingTemplatePass.cloudReadingKey)
                Task { await read() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Names, companies and contacts are taken out on this Mac first. The examples go to the provider once, to read their structure; templates themselves stay here.")
        }
        .sheet(item: $preview) { preview in
            TemplatePreviewSheet(preview: preview)
        }
    }

    private var canSave: Bool {
        let named = !template.name.trimmingCharacters(in: .whitespaces).isEmpty
        switch template.kind {
        case .followUp: return named && !template.structure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .summary: return named && template.sections.contains { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    // MARK: Follow-up

    @ViewBuilder
    private var followUpBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Examples — one to three of your best letters")
                .font(.headline)
            Text("Paste them or drop files (.txt, .md, .eml, .docx). Daisy reads their structure once; the letters themselves aren’t kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $examples)
                .font(.callout)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.daisyDivider))
            fileRow
            HStack {
                Button {
                    Task { await startReading() }
                } label: {
                    Label("Read the structure", systemImage: "text.magnifyingglass")
                }
                .disabled(examples.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isReading)
                if isReading { ProgressView().controlSize(.small) }
                if readingFailed {
                    Text("Couldn’t read a structure — write it below yourself.")
                        .font(.caption)
                        .foregroundStyle(Color.daisyWarning)
                }
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Structure")
                .font(.headline)
            Text("Parts and their order, length, greeting and sign-off. Edit it freely — this is what letters follow.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $template.structure)
                .font(.callout)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.daisyDivider))
            if !removedNames.isEmpty {
                Text("Left out of the template: \(removedNames.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Summary

    @ViewBuilder
    private var summaryBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sections").font(.headline)
                Spacer()
                Button(showsFromNote ? String(localized: "Hide") : String(localized: "From a note you like…")) {
                    showsFromNote.toggle()
                }
                .buttonStyle(.link)
            }
            if showsFromNote {
                Text("Paste a meeting note you like; Daisy lists its sections for you to edit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $examples)
                    .font(.callout)
                    .frame(minHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.daisyDivider))
                fileRow
                HStack {
                    Button {
                        Task { await startReading() }
                    } label: {
                        Label("Read the sections", systemImage: "text.magnifyingglass")
                    }
                    .disabled(examples.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isReading)
                    if isReading { ProgressView().controlSize(.small) }
                    if readingFailed {
                        Text("Couldn’t read the sections — add them below.")
                            .font(.caption)
                            .foregroundStyle(Color.daisyWarning)
                    }
                }
            }
            ForEach($template.sections) { $section in
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 4) {
                        TextField("Section — “Budget and timeline”", text: $section.title)
                            .textFieldStyle(.roundedBorder)
                        TextField("What goes there (optional) — “numbers and dates as said”", text: $section.hint)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                    }
                    VStack(spacing: 2) {
                        Button { move(section.id, by: -1) } label: { Image(systemName: "chevron.up") }
                        Button { move(section.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    }
                    .buttonStyle(.borderless)
                    Button(role: .destructive) {
                        template.sections.removeAll { $0.id == section.id }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button {
                template.sections.append(MeetingTemplateSection(title: ""))
            } label: {
                Label("Add a section", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            Text("A section the meeting didn’t touch says “Not discussed” — nothing is made up to fill it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// «Choose files…» and a box to drop them on. Not a drop on the text
    /// editor: the text view under it takes a dropped file as its path.
    private var fileRow: some View {
        HStack(spacing: 10) {
            Button {
                choosingFiles = true
            } label: {
                Label("Choose files…", systemImage: "doc.badge.plus")
            }
            Text("or drop them here")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(dropTargeted ? Color.accentColor : Color.daisyDivider,
                                  style: StrokeStyle(lineWidth: 1, dash: [4])))
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    loadFiles(providers)
                    return true
                }
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: Self.exampleTypes,
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls.prefix(3) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let text = try? TemplateExampleFile.text(of: url), !text.isEmpty { append(text) }
            }
        }
    }

    private static let exampleTypes: [UTType] = TemplateExampleFile.extensions.compactMap { UTType(filenameExtension: $0) }

    private func append(_ text: String) {
        examples += (examples.isEmpty ? "" : "\n\n———\n\n") + text
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = template.sections.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard template.sections.indices.contains(target) else { return }
        template.sections.swapAt(index, target)
    }

    // MARK: Rules

    @ViewBuilder
    private var rulesBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("When a meeting gets it").font(.headline)
            Text("Picked in the meeting’s card wins; then its folder, then a word in its title, then the default.")
                .font(.caption)
                .foregroundStyle(.secondary)
            let folders = FolderStore.shared.allFolders
            if !folders.isEmpty {
                Text("Folders").font(.subheadline)
                FlowToggles(items: folders.map { ($0.slug, $0.name) }, selection: $template.folderSlugs)
            }
            Text("Words in the title").font(.subheadline)
            TextField("interview, demo, standup, 1:1", text: $titleWordsText)
                .textFieldStyle(.roundedBorder)
                .onChange(of: titleWordsText) { _, text in
                    template.titleWords = text.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
            Toggle("Use by default", isOn: $template.isDefault)
            Text(matchesLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// «On which of the last 20 meetings it would have applied» (research
    /// 21.10) — the rule checked against real titles before saving.
    private var matchesLine: String {
        let recent = SessionStore.shared.sessions
            .filter { $0.kind == .recording }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(20)
        guard !recent.isEmpty else { return "" }
        let others = store.templates(template.kind).filter { $0.id != template.id }
        let hits = recent.filter { session in
            let choice = MeetingTemplateChoice.choose(template.kind, among: others + [template], folderSlug: session.folderSlug,
                                                      title: session.linkedEventTitle ?? session.title)
            guard let choice, choice.template.id == template.id else { return false }
            if case .byDefault = choice.reason { return false }
            return true
        }
        if hits.isEmpty { return String(localized: "By folder or title it would apply to none of your recent meetings (\(recent.count) checked).") }
        let names = hits.prefix(3).map { "“\($0.linkedEventTitle ?? $0.title)”" }.joined(separator: ", ")
        return String(localized: "Recent meetings it would apply to: \(hits.count) of \(recent.count) — \(names)")
    }

    // MARK: Actions

    private func loadFiles(_ providers: [NSItemProvider]) {
        for provider in providers.prefix(3) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, TemplateExampleFile.extensions.contains(url.pathExtension.lowercased()),
                      let text = try? TemplateExampleFile.text(of: url), !text.isEmpty else { return }
                Task { @MainActor in append(text) }
            }
        }
    }

    private func startReading() async {
        if !Summarizer.shared.providerIsEffectivelyLocal,
           !UserDefaults.standard.bool(forKey: MeetingTemplatePass.cloudReadingKey) {
            asksCloudReading = true
            return
        }
        await read()
    }

    private func read() async {
        isReading = true
        readingFailed = false
        defer { isReading = false }
        let target: TemplateStructureTarget = template.kind == .followUp ? .followUp : .summary
        guard let reading = await MeetingTemplatePass.read(examples: examples, target: target) else {
            readingFailed = true
            return
        }
        removedNames = reading.removed
        switch template.kind {
        case .followUp: template.structure = reading.structure
        case .summary: template.sections = reading.sections
        }
    }

    private func save() {
        template.name = template.name.trimmingCharacters(in: .whitespaces)
        template.sections = template.sections.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        store.save(template)
        dismiss()
    }

    /// The template on the latest meeting with a summary, beside its
    /// standard summary — before saving (research 21.10).
    private func runPreview() async {
        guard let session = SessionStore.shared.sessions
            .filter({ $0.kind == .recording && $0.summary != nil && $0.transcriptURL != nil })
            .max(by: { $0.startedAt < $1.startedAt }),
              let url = session.transcriptURL,
              let markdown = try? String(contentsOf: url, encoding: .utf8) else {
            ToastCenter.shared.show(String(localized: "No recent meeting with a summary to preview on"), style: .info)
            return
        }
        isPreviewing = true
        defer { isPreviewing = false }
        var draft = template
        draft.sections = draft.sections.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let templated = await MeetingTemplatePass.run(
            draft, transcriptMarkdown: markdown, title: session.title,
            localeHint: StoredSessionTemplates.localeHint(for: session), durationSec: session.durationSec,
            reason: nil, pickedByHand: false) else {
            ToastCenter.shared.show(String(localized: "Couldn’t lay that meeting out by this template"), style: .warning)
            return
        }
        preview = TemplatePreview(meetingTitle: session.title, standard: session.summary?.sections ?? [],
                                  templated: templated.sections)
    }
}

/// Folder toggles in a wrapping row.
private struct FlowToggles: View {
    let items: [(id: String, name: String)]
    @Binding var selection: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.id) { item in
                Toggle(item.name, isOn: Binding(
                    get: { selection.contains(item.id) },
                    set: { on in
                        if on { selection.append(item.id) } else { selection.removeAll { $0 == item.id } }
                    }))
                    .toggleStyle(.checkbox)
            }
        }
    }
}

// MARK: - Preview

struct TemplatePreview: Identifiable {
    let id = UUID()
    let meetingTitle: String
    let standard: [SummarySection]
    let templated: [SummarySection]
}

private struct TemplatePreviewSheet: View {
    let preview: TemplatePreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview — “\(preview.meetingTitle)”")
                .font(.title3.weight(.semibold))
            HStack(alignment: .top, spacing: 16) {
                column(String(localized: "Standard"), preview.standard)
                Divider()
                column(String(localized: "By this template"), preview.templated)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 820, height: 560)
    }

    private func column(_ title: String, _ sections: [SummarySection]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.title).font(.subheadline.weight(.semibold))
                            ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, bullet in
                                Text("• \(bullet.text)").font(.callout).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
