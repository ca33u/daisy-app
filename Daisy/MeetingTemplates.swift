//
//  MeetingTemplates.swift
//  Daisy
//
//  The person's own templates (backlog 35, Egor 21.10): what a follow-up
//  letter says and in what order, and what sections a meeting's notes
//  have. The Voice Profile is HOW they write; a template is WHAT, and in
//  what order — a salesperson's letter after a demo, a recruiter's notes
//  after an interview.
//
//  BOTH ARE SECOND PASSES. The summary is made exactly as before — it is
//  the fallback, and its decisions and next steps feed Actions and the
//  follow-up — and a template only lays the meeting out again:
//    • a follow-up template rides in `FollowUpVoice`'s pass, structure and
//      tone in one call, never a third;
//    • a summary template is one more call that puts the transcript under
//      the template's sections, each item with the timecode of the line it
//      came from; what can't be tied to a line is dropped, and a section
//      the meeting had nothing for says «Not discussed». Nobody else does
//      either, and it is the guard against invented notes.
//
//  WHICH TEMPLATE: one rule for both kinds — picked by hand in the card >
//  the meeting's folder > a word in its title > the default > none (as
//  before). The card says which and why.
//
//  PRIVACY: templates live on this Mac (`templates.json` beside the Voice
//  Profile). A cloud provider gets the template's STRUCTURE with the
//  transcript, never the example letters it was made from; those are read
//  once, with names taken out first, and only with a yes when the
//  provider is in the cloud.
//

import DaisyCore
import Foundation
import os

// MARK: - Model

nonisolated enum MeetingTemplateKind: String, Codable, Sendable {
    case followUp
    case summary
}

/// One section of a summary template: its title and a short hint of what
/// goes there («Pains — in their words, with a timecode»).
nonisolated struct MeetingTemplateSection: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var hint: String = ""
}

nonisolated struct MeetingTemplate: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var kind: MeetingTemplateKind
    var name: String
    /// A summary template's sections, in order.
    var sections: [MeetingTemplateSection] = []
    /// A follow-up template's structure, as the person approved it: parts
    /// and order, length, greeting and sign-off. No names, no placeholders.
    var structure: String = ""
    /// Folders whose meetings get this template.
    var folderSlugs: [String] = []
    /// Words in a meeting's title that pick this template («interview»,
    /// «стендап», «1:1»).
    var titleWords: [String] = []
    var isDefault = false
    /// The built-in it was made from, if any.
    var builtIn: String? = nil
    var createdAt = Date()
    var lastUsedAt: Date? = nil
    var useCount = 0
    var archived = false

    init(kind: MeetingTemplateKind, name: String, sections: [MeetingTemplateSection] = [], structure: String = "",
         folderSlugs: [String] = [], titleWords: [String] = [], builtIn: String? = nil) {
        self.kind = kind
        self.name = name
        self.sections = sections
        self.structure = structure
        self.folderSlugs = folderSlugs
        self.titleWords = titleWords
        self.builtIn = builtIn
    }

    // Lenient: a file from a later version, with keys this one doesn't
    // know or without ones it added, still opens.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(MeetingTemplateKind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        sections = try c.decodeIfPresent([MeetingTemplateSection].self, forKey: .sections) ?? []
        structure = try c.decodeIfPresent(String.self, forKey: .structure) ?? ""
        folderSlugs = try c.decodeIfPresent([String].self, forKey: .folderSlugs) ?? []
        titleWords = try c.decodeIfPresent([String].self, forKey: .titleWords) ?? []
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        builtIn = try c.decodeIfPresent(String.self, forKey: .builtIn)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        useCount = try c.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    }

    /// Unused this long, the list offers to archive it (against a pile of
    /// templates nobody uses — research 21.10).
    static let staleAfter: TimeInterval = 30 * 24 * 3600

    func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastUsedAt ?? createdAt) > Self.staleAfter
    }
}

/// `summary.json` → `templated` (session-format.md §4). The app's own copy,
/// as `MeetingSummary` is: it carries the app's `SummarySection`.
nonisolated struct TemplatedSummary: Codable, Sendable, Equatable {
    var template: String
    var templateID: String?
    var reason: String?
    var pickedByHand: Bool?
    var sections: [SummarySection]
}

/// `summary.json` → `followUpTemplate`.
nonisolated struct TemplateReference: Codable, Sendable, Equatable {
    var name: String
    var id: String?
    var pickedByHand: Bool?
}

// MARK: - Choosing

/// Which template a meeting gets, and why — shown in the card.
nonisolated struct MeetingTemplateChoice: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        case pickedByHand
        case folder(String)
        case titleWord(String)
        case byDefault
    }

    let template: MeetingTemplate
    let reason: Reason

    var reasonText: String {
        switch reason {
        case .pickedByHand: String(localized: "picked by hand")
        case .folder(let name): String(localized: "folder “\(name)”")
        case .titleWord(let word): String(localized: "“\(word)” in the title")
        case .byDefault: String(localized: "the default")
        }
    }

    /// Picked by hand > folder > a word in the title > the default > none.
    static func choose(_ kind: MeetingTemplateKind, among templates: [MeetingTemplate], picked: String? = nil,
                       folderSlug: String?, folderName: String? = nil, title: String?) -> MeetingTemplateChoice? {
        let live = templates.filter { $0.kind == kind && !$0.archived }
        if let picked, let template = live.first(where: { $0.id.uuidString == picked }) {
            return MeetingTemplateChoice(template: template, reason: .pickedByHand)
        }
        if let folderSlug, let template = live.first(where: { $0.folderSlugs.contains(folderSlug) }) {
            return MeetingTemplateChoice(template: template, reason: .folder(folderName ?? folderSlug))
        }
        if let title {
            for template in live {
                if let word = template.titleWords.first(where: { titleMentions(title, $0) }) {
                    return MeetingTemplateChoice(template: template, reason: .titleWord(word))
                }
            }
        }
        if let template = live.first(where: \.isDefault) {
            return MeetingTemplateChoice(template: template, reason: .byDefault)
        }
        return nil
    }

    /// A word of the title starts with it («интервью» in «Интервью с
    /// Анной», «demo» in «Demo — Acme»), Russian endings forgiven by the
    /// prefix; a word with no letters in it («1:1») is looked for as is.
    static func titleMentions(_ title: String, _ word: String) -> Bool {
        let needle = word.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return false }
        let haystack = title.lowercased()
        guard needle.allSatisfy({ $0.isLetter }) else {
            // «1:1» as itself, not inside «21:10» or «11:15».
            var from = haystack.startIndex
            while let found = haystack.range(of: needle, range: from..<haystack.endIndex) {
                let before = found.lowerBound > haystack.startIndex ? haystack[haystack.index(before: found.lowerBound)] : " "
                let after = found.upperBound < haystack.endIndex ? haystack[found.upperBound] : " "
                if !before.isNumber, !after.isNumber, before != ":", after != ":" { return true }
                from = found.upperBound
            }
            return false
        }
        return haystack.split(whereSeparator: { !$0.isLetter }).contains { $0.hasPrefix(needle) }
    }
}

// MARK: - Store

/// `templates.json` beside the Voice Profile (Application Support/Daisy/
/// Voice). Not synced: the templates are this Mac's, until someone asks.
@Observable
@MainActor
final class MeetingTemplateStore {
    static let shared = MeetingTemplateStore()

    private(set) var templates: [MeetingTemplate] = []
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Templates")

    private init() {
        let appSupport = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        fileURL = appSupport.appendingPathComponent("Daisy/Voice/templates.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([MeetingTemplate].self, from: data) {
            templates = decoded
        }
    }

    func templates(_ kind: MeetingTemplateKind, includingArchived: Bool = false) -> [MeetingTemplate] {
        templates.filter { $0.kind == kind && (includingArchived || !$0.archived) }
    }

    func template(id: String?) -> MeetingTemplate? {
        guard let id else { return nil }
        return templates.first { $0.id.uuidString == id }
    }

    /// Adds or replaces. One default per kind.
    func save(_ template: MeetingTemplate) {
        let isNew = !templates.contains { $0.id == template.id }
        if template.isDefault {
            for index in templates.indices where templates[index].kind == template.kind { templates[index].isDefault = false }
        }
        if let index = templates.firstIndex(where: { $0.id == template.id }) {
            templates[index] = template
        } else {
            templates.append(template)
        }
        persist()
        if isNew {
            ImprovementStats.record(template.kind == .followUp ? .templateFollowUpCreated : .templateSummaryCreated)
        }
    }

    func delete(_ id: UUID) {
        templates.removeAll { $0.id == id }
        persist()
    }

    func setArchived(_ archived: Bool, _ id: UUID) {
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return }
        templates[index].archived = archived
        if archived { templates[index].isDefault = false }
        persist()
    }

    /// A template was applied to a meeting.
    func markUsed(_ id: String?) {
        guard let index = templates.firstIndex(where: { $0.id.uuidString == id }) else { return }
        templates[index].useCount += 1
        templates[index].lastUsedAt = Date()
        persist()
        ImprovementStats.record(templates[index].kind == .followUp ? .templateFollowUpApplied : .templateSummaryApplied)
    }

    func choose(_ kind: MeetingTemplateKind, picked: String? = nil, folderSlug: String?, title: String?) -> MeetingTemplateChoice? {
        MeetingTemplateChoice.choose(kind, among: templates, picked: picked, folderSlug: folderSlug,
                                     folderName: folderSlug.flatMap { FolderStore.shared.existingFolder(slug: $0)?.name },
                                     title: title)
    }

    /// The follow-up template a Daisy-key request names: «…по шаблону
    /// продажи», «…using the sales template» — a word of the template's
    /// name, after «шаблон» / «template».
    func followUpTemplate(mentionedIn request: String) -> MeetingTemplate? {
        Self.template(mentionedIn: request, among: templates(.followUp))
    }

    nonisolated static func template(mentionedIn request: String, among candidates: [MeetingTemplate]) -> MeetingTemplate? {
        let lowered = request.lowercased()
        guard let marker = ["шаблон", "template"].compactMap({ lowered.range(of: $0) }).first else { return nil }
        let after = lowered[marker.upperBound...].split(whereSeparator: { !$0.isLetter }).map(String.init)
        let before = lowered[..<marker.lowerBound].split(whereSeparator: { !$0.isLetter }).suffix(2).map(String.init)
        let said = Set((after.prefix(3) + before).filter { $0.count >= 4 }.map { String($0.prefix(5)) })
        func stems(_ template: MeetingTemplate) -> Set<String> {
            Set(template.name.lowercased().split(whereSeparator: { !$0.isLetter })
                .filter { $0.count >= 4 }.map { String($0.prefix(5)) })
        }
        // A word several templates share («после» in «Клиенту после
        // продажи» and «Кандидату после интервью») tells them apart from
        // nothing: only words that name one template count, and one has to
        // win outright.
        var owners: [String: Int] = [:]
        for template in candidates { for stem in stems(template) { owners[stem, default: 0] += 1 } }
        let scored = candidates.map { template in
            (template, stems(template).filter { said.contains($0) && owners[$0] == 1 }.count)
        }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        guard let best = scored.first, scored.dropFirst().first?.1 != best.1 else { return nil }
        return best.0
    }

    /// One write after another, in order: an older snapshot landing last
    /// would bring back a deleted template (review 21.10).
    @ObservationIgnored private var lastWrite: Task<Void, Never>?

    private func persist() {
        let snapshot = templates
        let url = fileURL
        let log = log
        let previous = lastWrite
        lastWrite = Task.detached(priority: .utility) {
            await previous?.value
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(snapshot).write(to: url, options: .atomic)
            } catch {
                log.error("templates.json not written: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Built-in summary templates

nonisolated enum BuiltInSummaryTemplates {
    /// Six starting points, in English and Russian (research 21.10).
    static func all(russian: Bool) -> [MeetingTemplate] {
        func t(_ id: String, _ name: String, _ words: [String], _ sections: [(String, String)]) -> MeetingTemplate {
            MeetingTemplate(kind: .summary, name: name,
                            sections: sections.map { MeetingTemplateSection(title: $0.0, hint: $0.1) },
                            titleWords: words, builtIn: id)
        }
        if russian {
            return [
                t("discovery", "Знакомство / продажа", ["discovery", "demo", "демо", "продаж", "знакомств"], [
                    ("Ситуация клиента", "чем занимаются, что у них сейчас"),
                    ("Боли", "своими словами клиента"),
                    ("Бюджет и сроки", "цифры и даты, как прозвучали"),
                    ("Кто решает", "люди и роли в решении"),
                    ("Возражения", "сомнения и как на них ответили"),
                    ("Следующий шаг", "что, кто и когда"),
                ]),
                t("one-on-one", "Встреча 1:1", ["1:1", "1-1", "one-on-one", "один на один"], [
                    ("Как дела", "успехи и настроение"),
                    ("Что мешает", "блокеры и риски"),
                    ("Обратная связь", "в обе стороны"),
                    ("Рост", "цели и развитие"),
                    ("Договорились", "что, кто и к какому сроку"),
                ]),
                t("interview", "Интервью кандидата", ["интервью", "собеседован", "interview"], [
                    ("Опыт", "кем и где работал, ключевые проекты"),
                    ("Сильные стороны", "с примерами из разговора"),
                    ("Сомнения", "что насторожило"),
                    ("Мотивация и ожидания", "почему ищет, деньги, сроки"),
                    ("Вопросы кандидата", "о чём спрашивал"),
                    ("Итог и следующий шаг", "решение и что дальше"),
                ]),
                t("standup", "Планёрка / стендап", ["планёрк", "планерк", "стендап", "дейли", "standup", "daily"], [
                    ("Сделано", "по людям"),
                    ("В работе сегодня", "по людям"),
                    ("Блокеры", "что мешает и кто поможет"),
                ]),
                t("retro", "Ретро", ["ретро", "retro"], [
                    ("Что получилось", ""),
                    ("Что не получилось", ""),
                    ("Идеи", ""),
                    ("Действия", "что меняем, кто отвечает"),
                ]),
                t("consultation", "Консультация клиента", ["консультац", "consultation"], [
                    ("Запрос", "с чем пришёл клиент"),
                    ("Контекст", "важные обстоятельства"),
                    ("Что посоветовали", "рекомендации"),
                    ("Открытые вопросы", "что осталось неясным"),
                    ("Следующие шаги", "что, кто и когда"),
                ]),
            ]
        }
        return [
            t("discovery", "Discovery / sales call", ["discovery", "demo", "sales", "intro"], [
                ("Client's situation", "what they do, what they have now"),
                ("Pains", "in the client's own words"),
                ("Budget and timeline", "numbers and dates as said"),
                ("Who decides", "people and their part in the decision"),
                ("Objections", "doubts and how they were answered"),
                ("Next step", "what, who and when"),
            ]),
            t("one-on-one", "1:1", ["1:1", "1-1", "one-on-one"], [
                ("How it's going", "wins and mood"),
                ("Blockers", "what's in the way, risks"),
                ("Feedback", "both ways"),
                ("Growth", "goals and development"),
                ("Agreed", "what, who, by when"),
            ]),
            t("interview", "Candidate interview", ["interview", "screening"], [
                ("Background", "roles, companies, key projects"),
                ("Strengths", "with examples from the conversation"),
                ("Concerns", "what gave pause"),
                ("Motivation and expectations", "why they're looking, money, timing"),
                ("Candidate's questions", "what they asked"),
                ("Verdict and next step", "the call and what happens next"),
            ]),
            t("standup", "Standup", ["standup", "stand-up", "daily", "scrum"], [
                ("Done", "by person"),
                ("Today", "by person"),
                ("Blockers", "what's in the way and who helps"),
            ]),
            t("retro", "Retro", ["retro", "retrospective"], [
                ("What went well", ""),
                ("What didn't", ""),
                ("Ideas", ""),
                ("Actions", "what changes, who owns it"),
            ]),
            t("consultation", "Client consultation", ["consultation", "advisory"], [
                ("Request", "what the client came with"),
                ("Context", "what matters about their situation"),
                ("Advice given", "the recommendations"),
                ("Open questions", "what's still unclear"),
                ("Next steps", "what, who and when"),
            ]),
        ]
    }
}

// MARK: - The summary pass

/// What a summary template's pass needs in its prompt.
nonisolated struct TemplatedSummaryContext: Sendable {
    var sections: [MeetingTemplateSection]
    /// «Not discussed» in the meeting's language.
    var notDiscussed: String
}

/// What a structure-reading pass reads examples for.
nonisolated enum TemplateStructureTarget: Sendable {
    case followUp
    case summary
}

nonisolated enum MeetingTemplatePass {
    /// «Not discussed» in the meeting's language: Russian for Russian,
    /// English otherwise (the model writes other languages itself).
    static func notDiscussed(language: String?) -> String {
        language?.hasPrefix("ru") == true ? "Не обсуждалось" : "Not discussed"
    }

    /// transcript.md's `## Transcript` as the pass reads it: one line per
    /// utterance, `[mm:ss] Speaker: text`. The timecodes are the ones the
    /// file shows, so a bullet's timecode points into the file.
    static func transcriptLines(fromMarkdown markdown: String) -> String {
        guard let start = markdown.range(of: "\n## Transcript\n") else { return "" }
        let body = markdown[start.upperBound...]
        var lines: [String] = []
        for raw in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("## ") { break }
            // **[12:34 · Anna]** text
            guard line.hasPrefix("**["), let close = line.range(of: "]**") else { continue }
            let head = line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound]
            let parts = head.components(separatedBy: " · ")
            guard let time = parts.first, !time.isEmpty else { continue }
            let speaker = parts.dropFirst().joined(separator: " · ")
            let text = line[close.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            lines.append(speaker.isEmpty ? "[\(time)] \(text)" : "[\(time)] \(speaker): \(text)")
        }
        return lines.joined(separator: "\n")
    }

    /// Seconds of a `[h:mm:ss]` / `[mm:ss]` at the start of a bullet.
    static func leadingTimecode(_ text: String) -> Double? {
        guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else { return nil }
        let parts = text[text.index(after: text.startIndex)..<close].split(separator: ":").map { Int($0) }
        guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        let n = parts.compactMap { $0 }
        return n.count == 3 ? Double(n[0] * 3600 + n[1] * 60 + n[2]) : Double(n[0] * 60 + n[1])
    }

    /// The model's Markdown, checked: sections in the template's order and
    /// with its count; a bullet stays only if it starts with a timecode
    /// inside the meeting (and the timecode is one the transcript has);
    /// a section left empty says «Not discussed».
    ///
    /// Headings are matched to the template by their number («## 2.
    /// Budget» — the prompt asks for it), then by title; a heading that
    /// matches neither is ignored rather than shifting every section after
    /// it (review 21.10). Only when no heading matches at all is the order
    /// trusted. Timecodes compare by their seconds, so «[05:12]» is the
    /// file's «[5:12]».
    static func parse(_ markdown: String, template: [MeetingTemplateSection], notDiscussed: String,
                      knownTimecodes: Set<Double>, durationSec: Int) -> [SummarySection] {
        var parsed: [(heading: String, bullets: [String])] = []
        for raw in markdown.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                parsed.append((line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces), []))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• "), !parsed.isEmpty {
                parsed[parsed.count - 1].bullets.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            }
        }
        func normalized(_ s: String) -> String {
            s.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        }
        /// «2. Budget» → (1, "Budget"); «Budget» → (nil, "Budget").
        func split(_ heading: String) -> (number: Int?, title: String) {
            let digits = heading.prefix { $0.isNumber }
            guard !digits.isEmpty, let n = Int(digits) else { return (nil, heading) }
            let rest = heading.dropFirst(digits.count).drop { ".):".contains($0) || $0 == " " }
            return (n - 1, String(rest))
        }
        var slots: [Int: (title: String, bullets: [String])] = [:]
        var unmatched: [(position: Int, title: String, bullets: [String])] = []
        for (position, entry) in parsed.enumerated() {
            let (number, title) = split(entry.heading)
            let index = number.flatMap { template.indices.contains($0) ? $0 : nil }
                ?? template.firstIndex { normalized($0.title) == normalized(title) }
            guard let index else {
                unmatched.append((position, title, entry.bullets))
                continue
            }
            let existing = slots[index]
            slots[index] = (existing?.title ?? title, (existing?.bullets ?? []) + entry.bullets)
        }
        // A heading that matched nothing (a title the model translated)
        // takes the section at its own position, if that one is still
        // empty — never one already filled, so a stray extra heading can't
        // push the rest down.
        if !slots.isEmpty {
            for entry in unmatched where template.indices.contains(entry.position) && slots[entry.position] == nil {
                slots[entry.position] = (entry.title, entry.bullets)
            }
        }
        if slots.isEmpty {
            for (index, entry) in parsed.prefix(template.count).enumerated() {
                slots[index] = (split(entry.heading).title, entry.bullets)
            }
        }
        let nd = normalized(notDiscussed)
        func isNotDiscussed(_ text: String) -> Bool {
            let plain = normalized(text)
            return plain == nd || plain == "not discussed" || plain == "не обсуждалось"
        }
        return template.indices.map { index in
            let fromModel = slots[index]
            // The model's title (translated into the meeting's language),
            // unless it came back empty or with a marker in it.
            let title = fromModel.map(\.title)
                .flatMap { $0.isEmpty || SensitiveDataProtector.containsUnrestoredMarker($0) ? nil : $0 }
                ?? template[index].title
            let kept = (fromModel?.bullets ?? []).filter { bullet in
                guard !isNotDiscussed(bullet), let seconds = leadingTimecode(bullet),
                      seconds <= Double(durationSec) + 30,
                      // A marker that didn't come back as a name takes this
                      // point with it, not the whole pass.
                      !SensitiveDataProtector.containsUnrestoredMarker(bullet) else { return false }
                return knownTimecodes.isEmpty || knownTimecodes.contains(seconds)
            }
            let bullets = kept.isEmpty ? [SummaryBullet(text: notDiscussed)] : kept.map { SummaryBullet(text: $0) }
            return SummarySection(title: title, bullets: bullets)
        }
    }

    /// The seconds of the timecodes the transcript lines start with.
    static func timecodes(in lines: String) -> Set<Double> {
        Set(lines.split(separator: "\n").compactMap { leadingTimecode(String($0)) })
    }

    /// How long the pass may take before the standard summary is the answer.
    static let deadlineSeconds: Double = 120

    /// Lays the meeting out under `template`. nil when there's no
    /// transcript, the provider fails, or nothing usable comes back — the
    /// standard summary is what the person then sees.
    static func run(_ template: MeetingTemplate, transcriptMarkdown: String, title: String, localeHint: String?,
                    durationSec: Int, reason: String?, pickedByHand: Bool) async -> TemplatedSummary? {
        let lines = transcriptLines(fromMarkdown: transcriptMarkdown)
        guard !lines.isEmpty, !template.sections.isEmpty else { return nil }
        let language = localeHint.flatMap { $0 == "auto" ? nil : $0 } ?? LanguageDetector.detect(lines)
        let nd = notDiscussed(language: language)
        let context = TemplatedSummaryContext(sections: template.sections, notDiscussed: nd)
        let task = SummaryTask.templatedSummary(context)
        // Bounded: finalize waits for this, and on a local model a long
        // meeting must not hold the session in «summarizing» for minutes
        // (review 21.10). Past it, the standard summary is the answer.
        let text: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                (try? await Summarizer.shared.runProbe(transcript: lines, title: title, localeHint: localeHint,
                                                       task: task))?.clientFollowUp
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(deadlineSeconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let text, !text.isEmpty else { return nil }
        let sections = parse(text, template: template.sections, notDiscussed: nd,
                             knownTimecodes: timecodes(in: lines), durationSec: durationSec)
        // Every section «not discussed» means the pass found nothing it
        // could tie to the meeting: not a result worth showing over the
        // standard summary.
        guard sections.contains(where: { $0.bullets.first?.text != nd }) else { return nil }
        return TemplatedSummary(template: template.name, templateID: template.id.uuidString, reason: reason,
                                pickedByHand: pickedByHand ? true : nil, sections: sections)
    }

    // MARK: Reading examples

    /// What a structure read gives back: the structure (or the sections,
    /// for a summary template) and the names taken out of the examples
    /// before they were read, to show the person.
    struct Reading: Sendable {
        var structure: String
        var sections: [MeetingTemplateSection]
        var removed: [String]
    }

    /// Reads 1–3 example letters (or a good meeting note) for their
    /// structure. Names, companies, contacts are taken out on this Mac
    /// first and never put back: the template must not carry the client
    /// from the example into a letter to someone else.
    static func read(examples: String, target: TemplateStructureTarget) async -> Reading? {
        var scrubber = PseudonymSession(detectNamedEntities: true)
        // Plain labels, not the scrubber's markers: a cloud request is
        // pseudonymised again on its way out, numbering from 001 too, and
        // its restore would put a name it caught where the model echoed one
        // of ours (review 21.10). «[person]» means nothing to anyone.
        let scrubbed = genericLabels(scrubber.protect(examples))
        let removed = scrubber.replacedOriginals
        guard let reply = try? await Summarizer.shared.runProbe(
            transcript: scrubbed, title: "Template", localeHint: nil, task: .templateStructure(target)) else { return nil }
        let text = withoutNames(withoutMarkers(reply.clientFollowUp), removed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !SensitiveDataProtector.containsUnrestoredMarker(text) else { return nil }
        switch target {
        case .followUp:
            return Reading(structure: text, sections: [], removed: removed)
        case .summary:
            let sections = sectionLines(text)
            guard !sections.isEmpty else { return nil }
            return Reading(structure: "", sections: sections, removed: removed)
        }
    }

    /// `Title — hint` lines (or `## Title`) into sections.
    static func sectionLines(_ text: String) -> [MeetingTemplateSection] {
        text.split(separator: "\n").compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "#-*•0123456789.) ".contains(first) { line.removeFirst() }
            guard !line.isEmpty else { return nil }
            for dash in [" — ", " – ", " - ", ": "] {
                if let range = line.range(of: dash) {
                    let title = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                    let hint = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    guard !title.isEmpty else { return nil }
                    return MeetingTemplateSection(title: title, hint: hint)
                }
            }
            return MeetingTemplateSection(title: line)
        }
    }

    /// A pseudonym marker that came back is a name from an example: it
    /// goes, it is not put back.
    static func withoutMarkers(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[\s*\[\s*(DAISY|REDACTED)_[A-Z_]*?(_\s*\d+)?\s*\]\s*\]"#, with: "…",
                                  options: [.regularExpression, .caseInsensitive])
    }

    /// The scrubber's markers as plain labels: «[[DAISY_PERSON_001]]» →
    /// «[person]», «[[REDACTED_SECRET]]» → «[secret]».
    static func genericLabels(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[\[(?:DAISY|REDACTED)_([A-Z]+(?:_[A-Z]+)*?)(?:_\d+)?\]\]"#) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: text), let kind = Range(match.range(at: 1), in: text) else { continue }
            let label = text[kind].lowercased().replacingOccurrences(of: "_", with: " ")
            result.replaceSubrange(whole, with: "[\(label)]")
        }
        return result
    }

    /// Belt and braces: a name the scrubber took out that the model wrote
    /// back anyway (it can't have, but a template must never carry one).
    static func withoutNames(_ text: String, _ names: [String]) -> String {
        // Whole words only: a removed «Ann» leaves «annual» alone.
        names.filter { $0.count >= 3 }.reduce(text) { result, name in
            result.replacingOccurrences(
                of: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}])",
                with: "…", options: [.regularExpression, .caseInsensitive])
        }
    }

    /// Whether example letters may go to the summary provider to be read:
    /// always on this Mac; in the cloud, after one yes.
    static let cloudReadingKey = "daisy.templates.cloudReadingAllowed"
}

// MARK: - Example files

nonisolated enum TemplateExampleFile {
    static let extensions = ["txt", "md", "markdown", "eml", "docx"]

    /// The text of a dropped example: plain text, Markdown, a Word file,
    /// or a saved email (.eml — its body, without the headers).
    static func text(of url: URL) throws -> String {
        if url.pathExtension.lowercased() == "eml" {
            // Byte for byte (Latin-1 maps every byte to one character), so
            // each part is decoded with its own charset — an 8bit koi8-r
            // body included.
            let data = try Data(contentsOf: url)
            return emailBody(String(data: data, encoding: .isoLatin1) ?? "", bytePreserved: true)
        }
        return try MeetingPlanFileExtractor.extract(from: url).text
    }

    /// An .eml's readable body: the first text/plain part, however deep
    /// the multipart nesting (a mail with attachments wraps the
    /// alternative part in a mixed one), decoded by its transfer encoding
    /// and charset (koi8-r and windows-1251 Russian mail too); the quoted
    /// thread below «>» lines left out.
    /// `bytePreserved`: `raw` holds the file's bytes one per character
    /// (Latin-1), not text.
    static func emailBody(_ raw: String, bytePreserved: Bool = false) -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let body = plainPart(normalized, bytePreserved: bytePreserved) ?? ""
        return body.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix(">") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text of the first text/plain part of an entity (headers, blank
    /// line, body), or nil when it has none.
    private static func plainPart(_ entity: String, bytePreserved: Bool, depth: Int = 0) -> String? {
        guard depth < 6 else { return nil }
        let headers: String
        let body: String
        if let split = entity.range(of: "\n\n") {
            headers = String(entity[..<split.lowerBound])
            body = String(entity[split.upperBound...])
        } else {
            headers = entity
            body = ""
        }
        let type = header("Content-Type", in: headers)?.lowercased() ?? "text/plain"
        if type.hasPrefix("multipart"), let boundary = parameter("boundary", in: header("Content-Type", in: headers) ?? "") {
            for part in body.components(separatedBy: "--\(boundary)").dropFirst() {
                let trimmed = part.hasPrefix("\n") ? String(part.dropFirst()) : part
                if trimmed.hasPrefix("--") { break }
                if let text = plainPart(trimmed, bytePreserved: bytePreserved, depth: depth + 1) { return text }
            }
            return nil
        }
        guard type.hasPrefix("text/plain") else { return nil }
        let encoding = header("Content-Transfer-Encoding", in: headers)?.lowercased() ?? ""
        let charset = parameter("charset", in: header("Content-Type", in: headers) ?? "")
        let bytes: [UInt8]
        if encoding.contains("quoted-printable") {
            bytes = quotedPrintableBytes(body, bytePreserved: bytePreserved)
        } else if encoding.contains("base64"),
                  let data = Data(base64Encoded: body.components(separatedBy: .whitespacesAndNewlines).joined()) {
            bytes = Array(data)
        } else if bytePreserved {
            // 7bit / 8bit: the bytes as they are, in the part's charset.
            bytes = body.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
        } else {
            return body
        }
        return decode(bytes, charset: charset)
    }

    private static func decode(_ bytes: [UInt8], charset: String?) -> String {
        if let charset {
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let text = String(bytes: bytes, encoding: encoding) { return text }
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func header(_ name: String, in headers: String) -> String? {
        let unfolded = headers.replacingOccurrences(of: "\n ", with: " ").replacingOccurrences(of: "\n\t", with: " ")
        for line in unfolded.split(separator: "\n") where line.lowercased().hasPrefix(name.lowercased() + ":") {
            return line.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func parameter(_ name: String, in value: String) -> String? {
        guard let range = value.range(of: name + "=", options: .caseInsensitive) else { return nil }
        var rest = value[range.upperBound...]
        if rest.hasPrefix("\"") {
            rest = rest.dropFirst()
            return rest.prefix { $0 != "\"" }.description
        }
        return rest.prefix { $0 != ";" && $0 != " " }.description
    }

    static func quotedPrintable(_ text: String) -> String {
        String(decoding: quotedPrintableBytes(text, bytePreserved: false), as: UTF8.self)
    }

    static func quotedPrintableBytes(_ text: String, bytePreserved: Bool) -> [UInt8] {
        var bytes: [UInt8] = []
        let joined = text.replacingOccurrences(of: "=\n", with: "")
        let source = bytePreserved ? joined.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) } : Array(joined.utf8)
        var index = 0
        while index < source.count {
            if source[index] == UInt8(ascii: "="), index + 2 < source.count,
               let byte = UInt8(String(bytes: source[(index + 1)...(index + 2)], encoding: .ascii) ?? "", radix: 16) {
                bytes.append(byte)
                index += 3
            } else {
                bytes.append(source[index])
                index += 1
            }
        }
        return bytes
    }
}

// MARK: - A stored meeting

/// Templates over a stored meeting's new summary (Re-summarize, Draft
/// follow-up, a template picked in the card). A template picked by hand
/// for this meeting stays its template; otherwise the rule chooses again.
@MainActor
enum StoredSessionTemplates {
    static func title(of session: StoredSession) -> String {
        session.linkedEventTitle ?? session.title
    }

    static func localeHint(for session: StoredSession) -> String? {
        RecordingSession.resolveSummaryLocaleHint(
            transcript: session.transcriptText,
            transcriptLocale: session.locale,
            summaryLanguageOverride: AppSettings.currentSummaryLanguage
        )
    }

    /// The follow-up through `FollowUpVoice`, with the meeting's template.
    static func followUp(_ summary: MeetingSummary, previous: MeetingSummary?, session: StoredSession,
                         template forced: MeetingTemplate? = nil, voice: Bool = true) async -> MeetingSummary {
        let previousPick = previous?.followUpTemplate?.pickedByHand == true ? previous?.followUpTemplate?.id : nil
        let choice = forced.map { MeetingTemplateChoice(template: $0, reason: .pickedByHand) }
            ?? MeetingTemplateStore.shared.choose(.followUp, picked: previousPick, folderSlug: session.folderSlug,
                                                  title: title(of: session))
        return await FollowUpVoice.polished(summary, template: choice?.template,
                                            pickedByHand: choice?.reason == .pickedByHand, voice: voice)
    }

    /// Both templates over a summary made where the voice pass is left out
    /// on purpose (imports, the evening pass, MCP): the meeting still gets
    /// its templates, and a hand-picked one isn't lost.
    static func applyWithoutVoice(_ summary: MeetingSummary, previous: MeetingSummary?,
                                  session: StoredSession) async -> MeetingSummary {
        let withFollowUp = await followUp(summary, previous: previous, session: session, voice: false)
        return await laidOut(withFollowUp, previous: previous, session: session)
    }

    /// The meeting laid out by its summary template, when it has one and
    /// the pass gives something; otherwise `summary` as it is.
    static func laidOut(_ summary: MeetingSummary, previous: MeetingSummary?, session: StoredSession,
                        template forced: MeetingTemplate? = nil) async -> MeetingSummary {
        let previousPick = previous?.templated?.pickedByHand == true ? previous?.templated?.templateID : nil
        guard let choice = forced.map({ MeetingTemplateChoice(template: $0, reason: .pickedByHand) })
                ?? MeetingTemplateStore.shared.choose(.summary, picked: previousPick, folderSlug: session.folderSlug,
                                                      title: title(of: session)),
              let url = session.transcriptURL,
              let markdown = try? String(contentsOf: url, encoding: .utf8),
              let templated = await MeetingTemplatePass.run(
                  choice.template, transcriptMarkdown: markdown, title: session.title,
                  localeHint: localeHint(for: session), durationSec: session.durationSec,
                  reason: choice.reasonText, pickedByHand: choice.reason == .pickedByHand) else { return summary }
        MeetingTemplateStore.shared.markUsed(choice.template.id.uuidString)
        var result = summary
        result.templated = templated
        return result
    }
}
