//
//  DaisyKey.swift
//  Daisy
//
//  The Daisy key (backlog 34 K-1, Egor 21.10.2026). One key for what
//  used to be the voice-note key, «rewrite in my voice» and — next —
//  voice commands. Two gestures, no menu:
//
//    • a TAP (< 0.35 s) is the old voice-note toggle: a long note that
//      runs until the next tap; during a meeting, the side note;
//    • a HOLD is «I talk while I hold»: let go and Daisy does it.
//
//  And one rule: save first, work out what was meant second. Whatever
//  was said in a hold goes to the Command History (text and audio, kept
//  as long as dictations) before anything is decided. A hold that isn't
//  understood becomes a note in the Library — a note is never lost.
//
//  K-1 understands without a model: «note / запиши / запомни …» is a
//  note, «… в проект X» files it; a silent hold over selected text
//  rewrites it in the person's voice; a silent hold with nothing
//  selected says so and creates nothing; anything else is kept as a
//  note («Сохранила как заметку»). Commands that need a model (edit the
//  selection, write a reply) are K-2.
//
//  A hold is a dictation underneath — same capture, same engines, same
//  side session while the previous recording finishes — whose last step
//  hands the text here instead of pasting it (`DictationPurpose`, which
//  carries the press's token so each hold meets its own context). The
//  capture starts on key-down, so the first words of a hold are never
//  lost; a tap discards that half-second and starts the long note.
//

import AppKit
import ApplicationServices
import Foundation
import Observation
import os

// MARK: - What the key saw when it went down

/// The focused field and the selection at the moment the key went down —
/// read through Accessibility, never by copying (⌘C).
nonisolated struct DaisyKeyContext: Sendable, Equatable {
    /// Selected text in the focused element; nil when there is none, it
    /// couldn't be read, or the field is a password field.
    var selection: String?
    /// The app answered the selection question (with text or with none).
    /// False for Electron and Chromium apps that don't expose it — the
    /// selection is then unknown, not absent.
    var selectionReadable = false
    /// The focused field takes edits.
    var isEditable = false
    /// The focused field is a password field: nothing is read from it
    /// and nothing will be written into it.
    var isSecureField = false
    /// Accessibility was granted when the key went down.
    var accessibilityTrusted = false
    /// The focused element itself, so a result is inserted only where the
    /// person was when the key went down (K-2).
    var element: AXElementBox?

    static let empty = DaisyKeyContext()

    var hasSelection: Bool {
        guard let selection else { return false }
        return !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether a silent hold should try the rewrite: there is a selection,
    /// or there may be one Daisy couldn't see (the rewrite then reads it
    /// the old way, after release, and says if nothing is selected).
    var mayHaveSelection: Bool {
        hasSelection || !accessibilityTrusted || !selectionReadable
    }

    /// Reads the focused element. AX calls can block on an app that
    /// doesn't answer, so this runs off the main actor with the same short
    /// messaging timeout `AXFocus` uses.
    static func read() -> DaisyKeyContext {
        var context = DaisyKeyContext()
        guard AXIsProcessTrusted() else { return context }
        context.accessibilityTrusted = true
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return context }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)
        context.element = AXElementBox(element)
        let role = string(element, kAXRoleAttribute) ?? ""
        let subrole = string(element, kAXSubroleAttribute) ?? ""
        if role == "AXSecureTextField" || subrole == kAXSecureTextFieldSubrole as String {
            context.isSecureField = true
            return context
        }
        var selectedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedRef) == .success {
            context.selectionReadable = true
            if let selected = selectedRef as? String, !selected.isEmpty { context.selection = selected }
        }
        context.isEditable = isSettable(element, kAXValueAttribute as CFString)
            || (role == "AXWebArea" && isSettable(element, kAXSelectedTextRangeAttribute as CFString))
        return context
    }

    /// The text selected in `box` right now, or nil when there is none or
    /// it can't be read.
    static func currentSelection(in box: AXElementBox) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(box.element, kAXSelectedTextAttribute as CFString, &raw) == .success,
              let text = raw as? String, !text.isEmpty else { return nil }
        return text
    }

    /// The element that has the keyboard focus now, or nil.
    static func focusedElement() -> AXElementBox? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        return AXElementBox(focusedRef as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute, &settable) == .success else { return false }
        return settable.boolValue
    }
}

/// An AX element carried across actors. AX elements are CF references
/// safe to pass between threads; equality is the element's identity.
nonisolated final class AXElementBox: @unchecked Sendable, Equatable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
    static func == (lhs: AXElementBox, rhs: AXElementBox) -> Bool { CFEqual(lhs.element, rhs.element) }
}

// MARK: - What a hold meant (no model)

/// What the words of a hold were understood as, by rules alone.
nonisolated enum DaisyKeyIntent: Equatable, Sendable {
    /// «note / запиши / запомни …» — the rest is the note, possibly
    /// opening with «в проект X».
    case note(String)
    /// Anything the rules don't know: kept as a note (K-2 will offer to
    /// run it as a command).
    case unclear(String)
}

nonisolated enum DaisyKeyIntentParser {
    /// Words that, said first, make the rest a note. Longer openings
    /// («запиши заметку», «make a note») are tried before shorter ones.
    static let noteOpenings: [[String]] = [
        ["запиши", "заметку"], ["сделай", "заметку"], ["make", "a", "note"], ["take", "a", "note"], ["note", "down"], ["write", "down"],
        ["заметка"], ["заметку"], ["запиши"], ["запомни"], ["записать"], ["note"], ["remember"],
    ]
    /// A name said before the command («Daisy, запиши …») is not part of it.
    static let addressWords: Set<String> = ["daisy", "дейзи", "дэйзи", "дейси", "дези"]

    /// nil when nothing was said (silence, a cough, punctuation only).
    static func parse(_ transcript: String) -> DaisyKeyIntent? {
        var words = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        if let first = words.first, addressWords.contains(normalized(first)) { words.removeFirst() }
        let text = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        for opening in noteOpenings where words.count >= opening.count {
            if zip(words, opening).allSatisfy({ normalized($0) == $1 }) {
                let rest = words.dropFirst(opening.count).joined(separator: " ")
                return .note(trimmedLead(rest))
            }
        }
        return .unclear(text)
    }

    /// Lowercased, without the punctuation speech engines put around
    /// words («Запиши,» → «запиши»).
    static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespaces))
    }

    /// Without the comma, colon or dash that follows an opening word.
    static func trimmedLead(_ text: String) -> String {
        var t = Substring(text)
        while let c = t.first, c.isPunctuation || c.isWhitespace || c == "—" || c == "-" { t = t.dropFirst() }
        return String(t)
    }
}

// MARK: - Commands that need a model (K-2)

/// What a command asks for, and so where its result may go.
nonisolated enum DaisyKeyCommandKind: Equatable, Sendable {
    /// Change the selected text in place (an edit verb over an editable
    /// selection): the result replaces the selection.
    case edit
    /// Write new text («напиши», «ответь» with nothing selected): the
    /// result goes in at the caret.
    case write
    /// Answer from the selection as a source — a reply to a selected
    /// email, a translation for the person, «о чём тут»: the selection is
    /// never replaced, the result goes to the clipboard.
    case answer
}

nonisolated enum DaisyKeyCommandParser {
    /// Verbs that change the selected text («короче», «исправь»).
    static let editVerbs: Set<String> = [
        "перепиши", "переписать", "сократи", "сократить", "короче", "покороче", "исправь", "поправь",
        "вежливее", "официальнее", "проще", "улучши", "переформулируй", "отредактируй", "причеши",
        "rewrite", "shorten", "shorter", "fix", "polish", "improve", "simplify", "rephrase", "edit", "proofread", "correct",
    ]
    /// Verbs that write new text («напиши», «ответь»).
    static let writeVerbs: Set<String> = [
        "напиши", "ответь", "составь", "подготовь", "сформулируй", "набросай", "сочини",
        "write", "reply", "draft", "compose", "answer", "prepare",
    ]
    static let translateVerbs: Set<String> = ["переведи", "translate"]
    /// «сделай короче», «make it shorter», «сделай промпт».
    static let makeVerbs: Set<String> = ["сделай", "make"]
    /// What «сделай / make it» has to be followed by to be an edit:
    /// «сделай из этого задачу» is not one (review 21.10).
    static let editAfterMake: Set<String> = [
        "короче", "покороче", "вежливее", "официальнее", "проще", "понятнее", "мягче", "лучше", "яснее", "живее",
        "shorter", "simpler", "clearer", "nicer", "politer", "friendlier", "better", "more", "less",
    ]
    /// Openings that ask about the selection.
    static let answerOpenings: [[String]] = [
        ["о", "чём"], ["о", "чем"], ["что", "тут"], ["что", "здесь"], ["объясни"], ["перескажи"],
        ["summarize"], ["explain"], ["what", "is", "this"], ["what's", "this"], ["what’s", "this"],
    ]
    /// After «переведи»: the translation is for the person, not the field.
    static let forMe: Set<String> = ["мне", "me"]

    /// nil when the words aren't a command by these rules — they are
    /// then kept as a note, with a button to run them anyway.
    static func kind(of text: String, hasSelection: Bool, selectionEditable: Bool) -> DaisyKeyCommandKind? {
        var words = text.split(whereSeparator: \.isWhitespace).map { DaisyKeyIntentParser.normalized(String($0)) }
        if let first = words.first, DaisyKeyIntentParser.addressWords.contains(first) { words.removeFirst() }
        guard let first = words.first else { return nil }
        if answerOpenings.contains(where: { opening in words.count >= opening.count && zip(words, opening).allSatisfy { $0 == $1 } }) {
            return hasSelection ? .answer : nil
        }
        if translateVerbs.contains(first) {
            guard hasSelection else { return .write }
            // «переведи мне», «translate for me»
            let forThem = words.dropFirst().prefix(2).contains(where: forMe.contains)
            return selectionEditable && !forThem ? .edit : .answer
        }
        if makeVerbs.contains(first), words.count > 1 {
            let next = words[1] == "it" && words.count > 2 ? words[2] : words[1]
            if next.hasPrefix("промпт") || next == "prompt" || next == "a" { return hasSelection ? .answer : .write }
            if editAfterMake.contains(next) { return hasSelection ? (selectionEditable ? .edit : .answer) : nil }
            return hasSelection ? .answer : nil
        }
        if editVerbs.contains(first) {
            return hasSelection ? (selectionEditable ? .edit : .answer) : nil
        }
        if writeVerbs.contains(first) {
            return hasSelection ? .answer : .write
        }
        return nil
    }

    /// Where the text goes, for its shape, from the app in front.
    static func field(bundleID: String?) -> VoiceCommandContext.Field {
        guard let id = bundleID?.lowercased() else { return .plain }
        let mail = ["com.apple.mail", "com.microsoft.outlook", "com.readdle.smartemail-mac", "com.superhuman.electron", "com.mimestream.mimestream"]
        let chat = ["com.tinyspeck.slackmacgap", "ru.keepcoder.telegram", "com.tdesktop.telegram", "com.apple.mobilesms",
                    "net.whatsapp.whatsapp", "com.hnc.discord", "desktop.whatsapp", "com.microsoft.teams2", "com.microsoft.teams"]
        let terminal = ["com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty"]
        let code = ["com.microsoft.vscode", "com.apple.dt.xcode", "dev.zed.zed", "com.todesktop.230313mzl4w4u92", "com.sublimetext.4"]
        if mail.contains(id) { return .mail }
        if chat.contains(id) { return .messenger }
        if terminal.contains(id) { return .terminal }
        if code.contains(id) || id.hasPrefix("com.jetbrains.") { return .code }
        return .plain
    }

    /// The model's text, as it may be inserted: trimmed, without quotes or
    /// a code fence wrapped round it, one line for a terminal. nil when
    /// nothing usable came back.
    static func cleaned(_ raw: String, field: VoiceCommandContext.Field) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6 {
            text = String(text.dropFirst(3).dropLast(3))
            if let newline = text.firstIndex(of: "\n"), !text[..<newline].contains(" ") { text = String(text[text.index(after: newline)...]) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (open, close) in [("\"", "\""), ("«", "»"), ("“", "”")] where text.hasPrefix(open) && text.hasSuffix(close) && text.count > 2 {
            let inner = String(text.dropFirst().dropLast())
            if !inner.contains(open) && !inner.contains(close) { text = inner }
        }
        // Any line break — a \r included — would press Return in a terminal.
        if field == .terminal { text = text.split(whereSeparator: \.isNewline).joined(separator: " ") }
        return text.isEmpty ? nil : text
    }
}

// MARK: - Which folder a note named

/// «… в проект Альфа, купить …» → the folder Альфа. Matching forgives
/// Russian endings («в папку Работы» finds «Работа») but not guessing:
/// no match or two equally good ones and the note goes to the default
/// notes folder, whole, with the words kept.
nonisolated enum DaisyKeyFolderRoute {
    struct Folder: Equatable, Sendable {
        let slug: String
        /// The folder's name, and any other name it answers to when
        /// spoken (Inbox is «Входящие» in Russian speech).
        let names: [String]
    }

    struct Result: Equatable, Sendable {
        /// The folder named, or nil: no folder phrase, or no single match.
        var folderSlug: String?
        /// A folder phrase was said but matched nothing.
        var unmatched = false
        /// A folder phrase matched more than one folder equally well.
        var ambiguous = false
        /// The note's text: without the folder phrase when it matched,
        /// everything when it didn't — no word is dropped on a guess.
        var body: String
    }

    static let prepositions: Set<String> = ["в", "во", "to", "in", "into"]
    static let folderWords: Set<String> = ["проект", "проекта", "проекте", "папку", "папка", "папке", "project", "folder"]

    static func route(_ text: String, folders: [Folder]) -> Result {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var nameStart = 0
        if words.count >= 2, prepositions.contains(DaisyKeyIntentParser.normalized(words[0])) {
            var i = 1
            if DaisyKeyIntentParser.normalized(words[i]) == "the", words.count >= 3 { i += 1 }
            if folderWords.contains(DaisyKeyIntentParser.normalized(words[i])) { nameStart = i + 1 }
        }
        guard nameStart > 0, nameStart < words.count else {
            return Result(folderSlug: nil, body: text)
        }
        let spoken = words[nameStart...].map(DaisyKeyIntentParser.normalized)
        var best: (slug: String, length: Int)?
        var tie = false
        for folder in folders {
            for name in folder.names {
                let nameWords = name.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
                guard !nameWords.isEmpty, nameWords.count <= spoken.count,
                      zip(spoken, nameWords).allSatisfy({ wordsMatch($0, $1) }) else { continue }
                if let current = best {
                    if nameWords.count > current.length { best = (folder.slug, nameWords.count); tie = false }
                    else if nameWords.count == current.length, current.slug != folder.slug { tie = true }
                } else {
                    best = (folder.slug, nameWords.count)
                }
            }
        }
        guard let best else { return Result(folderSlug: nil, unmatched: true, body: text) }
        guard !tie else { return Result(folderSlug: nil, ambiguous: true, body: text) }
        let rest = DaisyKeyIntentParser.trimmedLead(words[(nameStart + best.length)...].joined(separator: " "))
        return Result(folderSlug: best.slug, body: rest.isEmpty ? text : rest)
    }

    /// Same word, or the same stem with a different ending: a shared
    /// start of all but the last letter of the shorter word, at least
    /// three letters, lengths at most two apart.
    static func wordsMatch(_ spoken: String, _ name: String) -> Bool {
        if spoken == name { return true }
        let a = Array(spoken), b = Array(name)
        guard min(a.count, b.count) >= 4, abs(a.count - b.count) <= 2 else { return false }
        let shared = zip(a, b).prefix { $0 == $1 }.count
        return shared >= max(3, min(a.count, b.count) - 1)
    }
}

// MARK: - Command history

/// One hold, as it was said: its text (vocabulary applied), what Daisy
/// made of it, and — when there was audio — the recording.
nonisolated struct DaisyCommandEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var text: String
    var date: Date
    /// What came of it, for the list: "note", "inbox", "unclear",
    /// "rewrite", "silent", "failed".
    var outcome: String
    /// The app that was in front when the key went down.
    var appName: String?
    /// File name of the audio in the history's folder, if it was saved.
    var audioFile: String?
}

/// The Command History: on this Mac only, kept as long as dictations
/// (`DictationHistory.retention`), never synced or sent. Every file
/// operation goes through one ordered chain, so a newer list is never
/// overwritten by an older one and audio is never written after its
/// entry was removed.
@MainActor
@Observable
final class DaisyCommandHistory {
    static let shared = DaisyCommandHistory()

    nonisolated static let fileName = "command-history.json"
    nonisolated static let audioFolderName = "CommandHistory"
    nonisolated static let maxEntries = 500

    private(set) var entries: [DaisyCommandEntry] = []

    @ObservationIgnored private let log = Logger(subsystem: "app.essazanov.Daisy", category: "DaisyKey")
    @ObservationIgnored private let folder: URL?
    @ObservationIgnored private var lastIO: Task<Void, Never>?

    private init() {
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        folder = support?.appendingPathComponent("Daisy", isDirectory: true)
        if let url = folder?.appendingPathComponent(Self.fileName),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([DaisyCommandEntry].self, from: data) {
            entries = decoded
        }
        sweepExpired()
    }

    private var audioFolder: URL? { folder?.appendingPathComponent(Self.audioFolderName, isDirectory: true) }

    /// Saves a hold before anything is done with it. The text is in the
    /// list at once; the audio follows in order.
    @discardableResult
    func record(text: String, samples: [Float], appName: String?, outcome: String = "unclear") -> UUID {
        var entry = DaisyCommandEntry(text: text, date: Date(), outcome: outcome, appName: appName)
        if !samples.isEmpty, let audioFolder {
            let name = "\(entry.id.uuidString).caf"
            entry.audioFile = name
            let url = audioFolder.appendingPathComponent(name)
            let log = self.log
            enqueue {
                try? FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
                if !AudioArchiveDecoder.writeMono16kCAF(samples: samples, to: url) {
                    log.error("Command history audio not saved")
                }
            }
        }
        entries.insert(entry, at: 0)
        trimAndPersist()
        return entry.id
    }

    func setOutcome(_ outcome: String, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].outcome = outcome
        persist()
    }

    func audioURL(for entry: DaisyCommandEntry) -> URL? {
        guard let name = entry.audioFile else { return nil }
        return audioFolder?.appendingPathComponent(name)
    }

    func clear() {
        let gone = entries
        entries = []
        removeAudio(of: gone)
        persist()
    }

    /// Applies the dictation history's window: the list and its audio.
    func sweepExpired(now: Date = Date()) {
        guard let interval = DictationHistory.shared.retention.interval else { return trimAndPersist() }
        let gone = entries.filter { now.timeIntervalSince($0.date) > interval }
        guard !gone.isEmpty else { return }
        entries.removeAll { now.timeIntervalSince($0.date) > interval }
        removeAudio(of: gone)
        persist()
    }

    private func trimAndPersist() {
        if entries.count > Self.maxEntries {
            let gone = Array(entries[Self.maxEntries...])
            entries.removeLast(entries.count - Self.maxEntries)
            removeAudio(of: gone)
        }
        persist()
    }

    private func removeAudio(of gone: [DaisyCommandEntry]) {
        let urls = gone.compactMap { audioURL(for: $0) }
        guard !urls.isEmpty else { return }
        enqueue { for url in urls { try? FileManager.default.removeItem(at: url) } }
    }

    private func persist() {
        guard let folder else { return }
        let snapshot = entries
        let log = self.log
        enqueue {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
            } catch {
                log.error("Command history not saved: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// One after another, off the main actor, in the order asked.
    private func enqueue(_ work: @escaping @Sendable () -> Void) {
        let previous = lastIO
        lastIO = Task.detached(priority: .utility) {
            await previous?.value
            work()
        }
    }
}

// MARK: - Writing the note

nonisolated enum DaisyKeyNote {
    /// The note's title: its first words, at most about 60 characters.
    static func title(for body: String) -> String {
        let flat = body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > 60 else { return flat }
        let cut = flat.prefix(60)
        if let space = cut.lastIndex(of: " ") { return String(cut[..<space]) + "…" }
        return String(cut) + "…"
    }

    /// The same minimum every note carries (`title`, `started`,
    /// `daisy_kind: note`, `daisy_folder`) so the Library lists it. No
    /// `daisy_origin`: without one a session is a Mac session, and any
    /// other value reads as the phone's room microphone when its audio is
    /// transcribed again.
    static func markdown(body: String, created: Date, durationSec: Int, folderSlug: String) -> String {
        let iso = ISO8601DateFormatter()
        let title = title(for: body)
        let quoted = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return [
            "---",
            "title: \"\(quoted)\"",
            "started: \(iso.string(from: created))",
            "duration_sec: \(max(0, durationSec))",
            "daisy_kind: \(SessionKind.note.rawValue)",
            "daisy_folder: \(folderSlug)",
            "---",
            "",
            "# \(title)",
            "",
            body,
            "",
        ].joined(separator: "\n")
    }

    /// Writes the note under the Sessions folder the Library reads, with
    /// the hold's audio as `microphone.caf`, off the main actor. Returns
    /// the session id, or nil when it couldn't be written (the caller
    /// keeps the words).
    @MainActor
    static func write(body: String, samples: [Float], durationSec: Int, folderSlug: String) async -> String? {
        guard let ticket = SessionsFolder.acquireBase() else {
            Logger(subsystem: "app.essazanov.Daisy", category: "DaisyKey").error("Daisy key note: no sessions folder")
            return nil
        }
        defer { ticket.release() }
        let base = ticket.url.appendingPathComponent("Daisy/Sessions", isDirectory: true)
        return await Task.detached(priority: .userInitiated) {
            writeFiles(base: base, body: body, samples: samples, durationSec: durationSec, folderSlug: folderSlug)
        }.value
    }

    static func writeFiles(base: URL, body: String, samples: [Float], durationSec: Int, folderSlug: String) -> String? {
        let log = Logger(subsystem: "app.essazanov.Daisy", category: "DaisyKey")
        let now = Date()
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        let safeStamp = stamp.string(from: now).replacingOccurrences(of: ":", with: "-")
        let fm = FileManager.default
        var dir = base.appendingPathComponent(safeStamp, isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: dir.path), suffix < 20 {
            dir = base.appendingPathComponent("\(safeStamp)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        guard !fm.fileExists(atPath: dir.path) else { return nil }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if !samples.isEmpty, !AudioArchiveDecoder.writeMono16kCAF(samples: samples, to: dir.appendingPathComponent("microphone.caf")) {
                throw CocoaError(.fileWriteUnknown)
            }
            let markdown = markdown(body: body, created: now, durationSec: durationSec, folderSlug: folderSlug)
            try Data(markdown.utf8).write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
        } catch {
            log.error("Daisy key note not written: \(error.localizedDescription, privacy: .public)")
            // Never half a note: the audio without its text would read
            // as a broken recording.
            try? fm.removeItem(at: dir)
            return nil
        }
        return dir.lastPathComponent
    }
}

// MARK: - The key

/// Why a dictation capture runs, carried on the session from key-down to
/// `finishDictation`. The Daisy-key cases carry their press's token.
nonisolated enum DictationPurpose: Sendable, Equatable {
    /// An ordinary dictation: paste at the caret.
    case paste
    /// A Daisy-key hold: hand the text to `DaisyKeyController`.
    case daisyKeyHold(UUID)
    /// A Daisy-key tap: the half-second captured is thrown away and the
    /// long note starts.
    case daisyKeyTap(UUID)
}

@MainActor
final class DaisyKeyController {
    static let shared = DaisyKeyController()

    /// Shorter than this is a tap (spec 21.10).
    nonisolated static let tapThreshold: TimeInterval = 0.35
    /// A key held this long is let go for the person (spec: «авто-стоп
    /// как у диктовки, сохранить»); also what frees the key if its
    /// key-up never arrives.
    nonisolated static let maxHold: TimeInterval = 5 * 60

    private enum PressMode {
        /// The key went down while nothing was recording: a capture runs.
        case capturing
        /// A note or a meeting is recording: no capture, the release decides.
        case noCapture
        /// Busy (a dictation held or starting, a session stopping): ignored.
        case ignored
    }

    private struct Press {
        let token: UUID
        let at: Date
        let mode: PressMode
    }

    /// What a capturing press saw, kept until its hold is finished.
    private struct Hold {
        let appName: String?
        let bundleID: String?
        let context: Task<DaisyKeyContext, Never>
        let at: Date
    }

    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "DaisyKey")
    /// A command is being written right now.
    private var isWorking = false
    /// Ends the command being written: Esc, the deadline, or its result.
    private var stopWriting: (() -> Void)?
    private var current: Press?
    private var holds: [UUID: Hold] = [:]
    private var holdCap: Task<Void, Never>?

    private init() {}

    /// Whether key-up events can be had: the global key monitor needs
    /// Accessibility or Input Monitoring. Without either the key is
    /// registered tap-only (see `ServiceWiring`).
    static var canHold: Bool {
        AXIsProcessTrusted() || CGPreflightListenEventAccess()
    }

    nonisolated static let introducedKey = "daisy.daisyKey.introduced"

    /// Once, to someone who had a voice-note key before the Daisy key:
    /// the tap is the note it always was, and the hold is new. On the
    /// widget's pill, or as a notification — a launch usually has no
    /// window in front. Not on a fresh install: onboarding says it.
    static func introduceIfNeeded(settings: AppSettings) {
        let defaults = UserDefaults.standard
        guard settings.hasShownFirstRun, !defaults.bool(forKey: introducedKey) else { return }
        guard settings.voiceNoteHotkey != .none else {
            defaults.set(true, forKey: introducedKey)
            return
        }
        guard canHold else { return }
        defaults.set(true, forKey: introducedKey)
        let key = settings.voiceNoteHotkey.label
        let text = settings.rewriteSelectionHotkey != .none
            ? String(localized: "Your voice-note key \(key) is now the Daisy key: tap for a note as before, hold to say what to do. Rewriting is on it too — hold without a word over selected text")
            : String(localized: "Your voice-note key \(key) is now the Daisy key: tap for a note as before, hold to say what to do")
        WidgetBubbleCenter.shared.present(
            WidgetBubbleContent(text: text, autoDismiss: 15, tag: "daisy-key-intro"),
            notificationTitle: String(localized: "The Daisy key")
        )
    }

    // MARK: Gestures

    func press(session: RecordingSession) async {
        guard current == nil else { return }
        let token = UUID()
        // A command still being written owns the key: say so rather than
        // ignore the press (research 21.10).
        let mode = isWorking ? .ignored : Self.mode(for: session)
        if isWorking { tell(String(localized: "Still working on the last command")) }
        current = Press(token: token, at: Date(), mode: mode)
        holdCap?.cancel()
        holdCap = Task { [weak self, weak session] in
            try? await Task.sleep(for: .seconds(Self.maxHold))
            guard let self, let session, !Task.isCancelled, self.current?.token == token else { return }
            self.log.notice("Daisy key held for \(Int(Self.maxHold), privacy: .public) s — letting go for the person")
            await self.release(session: session)
        }
        guard mode == .capturing else { return }
        // A hold whose finish never came (a start that was refused) is
        // not kept forever.
        holds = holds.filter { Date().timeIntervalSince($0.value.at) < Self.maxHold * 2 }
        let front = NSWorkspace.shared.frontmostApplication
        holds[token] = Hold(
            appName: front?.localizedName,
            bundleID: front?.bundleIdentifier,
            context: Task.detached(priority: .userInitiated) { DaisyKeyContext.read() },
            at: Date()
        )
        await session.startDictationHotkey(purpose: .daisyKeyHold(token))
    }

    func release(session: RecordingSession) async {
        guard let press = current else { return }
        current = nil
        holdCap?.cancel()
        holdCap = nil
        let isTap = Date().timeIntervalSince(press.at) < Self.tapThreshold
        switch press.mode {
        case .ignored:
            return
        case .noCapture:
            if isTap {
                await session.toggleVoiceNoteByHotkey()
            } else if session.currentMode == .meeting {
                // K-3 makes this a moment with a comment.
                tell(String(localized: "For a quiet marker, use the Mark this moment key"))
            } else {
                tell(String(localized: "Stop the note first"))
            }
        case .capturing:
            if isTap { session.markDaisyKeyTap(press.token) }
            await session.stopDictationHotkey(daisyKeyToken: press.token)
        }
    }

    private static func mode(for session: RecordingSession) -> PressMode {
        func busy(_ s: RecordingSession) -> Bool {
            s.isDictating || s.isStarting || s.startingMode != nil || s.pendingMode == .dictation
        }
        if busy(session) || session.sideDictation.map(busy) == true { return .ignored }
        switch session.status {
        case .recording, .paused: return .noCapture
        case .preparing, .stopping: return .ignored
        case .idle, .finished, .failed, .summarizing: return .capturing
        }
    }

    // MARK: From finishDictation

    /// The tap's half-second is gone; start (or, if one is running by
    /// now, stop) the long note — what the voice-note key did.
    func tapCaptureFinished(token: UUID, on session: RecordingSession) {
        holds.removeValue(forKey: token)?.context.cancel()
        let main = RecordingSession.current ?? session
        Task { @MainActor in
            await main.toggleVoiceNoteByHotkey()
            if main.currentMode == .voiceNote, main.status == .recording || main.status == .preparing {
                ImprovementStats.record(.daisyKeyTapNote)
            }
        }
    }

    /// A hold ended with its words recognized (possibly none). Saved
    /// first, then acted on.
    func holdFinished(token: UUID, transcript raw: String, samples: [Float], durationSec: Int) async {
        let hold = holds.removeValue(forKey: token)
        let text = Self.corrected(raw)
        guard let intent = DaisyKeyIntentParser.parse(text) else {
            // A second or more with nothing recognized may still be
            // speech the engine missed: the audio is kept.
            let entryID: UUID? = durationSec >= 1 && !samples.isEmpty
                ? DaisyCommandHistory.shared.record(text: "", samples: samples, appName: hold?.appName, outcome: "silent")
                : nil
            let context = await hold?.context.value ?? .empty
            if silentHold(context: context), let entryID {
                DaisyCommandHistory.shared.setOutcome("rewrite", for: entryID)
            }
            return
        }
        ImprovementStats.record(.daisyKeyHold)
        let entryID = DaisyCommandHistory.shared.record(text: text, samples: samples, appName: hold?.appName)
        switch intent {
        case .note(let rest):
            ImprovementStats.record(.daisyKeyIntent(.note))
            let route = DaisyKeyFolderRoute.route(rest.isEmpty ? text : rest, folders: Self.folders())
            let slug = route.folderSlug ?? FolderStore.shared.defaultNoteFolderSlug
            guard let saved = await DaisyKeyNote.write(body: route.body, samples: samples, durationSec: durationSec, folderSlug: slug) else {
                return noteNotSaved(text, entryID: entryID)
            }
            await SessionStore.shared.refresh()
            let folderName = FolderStore.shared.existingFolder(slug: slug)?.name ?? slug
            if route.unmatched || route.ambiguous {
                DaisyCommandHistory.shared.setOutcome("inbox", for: entryID)
                tell(route.ambiguous
                     ? String(localized: "Several projects match — saved to \(folderName)")
                     : String(localized: "No such project — saved to \(folderName)"),
                     action: (String(localized: "Move"), { AppNavigation.shared.openInLibrary(saved) }))
            } else {
                DaisyCommandHistory.shared.setOutcome("note", for: entryID)
                tell(String(localized: "Note saved to \(folderName)"), style: .success,
                     action: (String(localized: "Open"), { AppNavigation.shared.openInLibrary(saved) }))
            }
            log.info("Daisy key note saved (\(route.body.count, privacy: .public) chars)")
        case .unclear(let words):
            let context = await hold?.context.value ?? .empty
            // A password field is never read from or written to: what was
            // said there is a note, whatever it sounds like.
            if !context.isSecureField,
               let kind = DaisyKeyCommandParser.kind(of: words, hasSelection: context.hasSelection, selectionEditable: context.isEditable) {
                ImprovementStats.record(.daisyKeyIntent(kind == .edit ? .edit : .write))
                await runCommand(kind, request: words, context: context, bundleID: hold?.bundleID,
                                 entryID: entryID, samples: samples, durationSec: durationSec, atPress: true)
                return
            }
            ImprovementStats.record(.daisyKeyIntent(.unclear))
            await keepAsNote(words, samples: samples, durationSec: durationSec, entryID: entryID,
                             outcome: "unclear", message: String(localized: "Saved as a note"), offerToRun: true,
                             context: context.isSecureField ? .empty : context)
        }
    }

    // MARK: Commands (K-2)

    /// Writes, changes or answers with the summary provider, then puts the
    /// result where it belongs. `atPress`: the field the key went down in
    /// is still the place to insert into (false when run later from a
    /// note's button — the result then goes to the clipboard). Anything
    /// that doesn't work out keeps the words as a note.
    private func runCommand(_ kind: DaisyKeyCommandKind, request: String, context: DaisyKeyContext, bundleID: String?,
                            entryID: UUID, samples: [Float], durationSec: Int, atPress: Bool, noteKept: Bool = false) async {
        let summarizer = Summarizer.shared
        func fallBack(_ message: String) async {
            if noteKept {
                tell(message, style: .warning)
            } else {
                await keepAsNote(request, samples: samples, durationSec: durationSec, entryID: entryID,
                                 outcome: "unclear", message: message, offerToRun: true,
                                 context: context.isSecureField ? .empty : context)
            }
        }
        // One command at a time: the pill, Esc and «Ещё работаю» are one
        // slot each (review 21.10). A second one keeps its words as a note.
        guard !isWorking else {
            return await fallBack(String(localized: "Still working on the last command — saved this one as a note"))
        }
        isWorking = true
        defer { isWorking = false }
        if summarizer.availability != .available { await summarizer.refreshAvailability() }
        guard summarizer.availability == .available else {
            return await fallBack(String(localized: "No summary provider is available — saved as a note"))
        }
        let local = summarizer.providerIsEffectivelyLocal
        if !local, !Self.cloudAllowed(summarizer.providerKind) {
            // One yes per provider (spec 21.10): until then the words stay
            // a note, and the button is the yes.
            if !noteKept {
                await keepAsNote(request, samples: samples, durationSec: durationSec, entryID: entryID,
                                 outcome: "unclear", message: nil, offerToRun: false)
            }
            let provider = summarizer.providerKind.shortName
            tell(String(localized: "Commands send what you said and selected to \(provider). Saved as a note for now"),
                 action: (String(localized: "Allow and run"), { [weak self] in
                     Self.allowCloud(summarizer.providerKind)
                     Task { await self?.runCommand(kind, request: request, context: context, bundleID: bundleID, entryID: entryID,
                                                   samples: [], durationSec: 0, atPress: false, noteKept: true) }
                 }))
            return
        }
        let role: VoiceCommandContext.Role = kind == .edit ? .edit : (context.hasSelection ? .source : .none)
        let field = DaisyKeyCommandParser.field(bundleID: bundleID)
        // The voice is the language of what's being written: the selection's
        // for an edit, what was said for the rest.
        let voice = VoiceProfileStore.shared.resolveStyle(
            forTextIn: LanguageDetector.detect(kind == .edit ? (context.selection ?? request) : request))?.promptInstruction
        let commandContext = VoiceCommandContext(role: role, field: field, voice: voice)
        let payload = SummaryPrompt.voiceCommandPayload(request: request, source: role == .none ? nil : context.selection)
        let written = await write(payload: payload, context: commandContext)
        if case .stopped = written {
            // Esc or the deadline: stopped on purpose, the words are in the
            // command history (spec 21.10) — no note made of them.
            DaisyCommandHistory.shared.setOutcome("stopped", for: entryID)
            tell(String(localized: "Stopped — what you said is in the command history"))
            return
        }
        guard case .text(let result) = written else {
            return await fallBack(String(localized: "Couldn’t do that — saved as a note"))
        }
        ImprovementStats.record(.daisyKeyGenerated(local: local))
        let insertable = atPress && (kind == .edit || (kind == .write && role == .none))
            && context.isEditable && !context.isSecureField
        // An edit goes in only over the same selection: a click elsewhere in
        // the same field during the wait would put it beside the original.
        let selectionStill = kind != .edit || context.element.flatMap(DaisyKeyContext.currentSelection(in:)) == context.selection
        if insertable, selectionStill, let element = context.element, DaisyKeyContext.focusedElement() == element {
            DictationPaste.shared.insert(result)
            DaisyCommandHistory.shared.setOutcome("inserted", for: entryID)
            log.info("Daisy key command inserted (\(result.count, privacy: .public) chars, \(local ? "local" : "cloud", privacy: .public))")
            return
        }
        if insertable { ImprovementStats.record(.daisyKeyFocusChanged) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
        DaisyCommandHistory.shared.setOutcome("clipboard", for: entryID)
        tell(insertable
             ? String(localized: "Ready — you moved to another field, so it’s on the clipboard: ⌘V")
             : String(localized: "Ready — it’s on the clipboard: ⌘V"),
             style: .success)
        log.info("Daisy key command to the clipboard (\(result.count, privacy: .public) chars, kind \(String(describing: kind), privacy: .public))")
    }

    /// The provider's text, or nil: cancelled with Esc, past 30 s, or
    /// nothing usable. «Ещё пишу…» at 15 s. The press that comes in the
    /// meantime is told the key is busy.
    private enum Written {
        case text(String)
        /// Esc or the 30-second limit.
        case stopped
        /// The provider failed or gave nothing usable.
        case failed
    }

    private func write(payload: String, context: VoiceCommandContext) async -> Written {
        defer { stopWriting = nil }
        _ = WidgetBubbleCenter.shared.show(WidgetBubbleContent(text: String(localized: "Writing…"), autoDismiss: 40, tag: Self.progressTag))
        defer { WidgetBubbleCenter.shared.dismiss(tag: Self.progressTag) }
        let work = Task<String?, Never> {
            guard let summary = try? await Summarizer.shared.runProbe(
                transcript: payload, title: "Daisy", localeHint: nil, task: .voiceCommand(context)) else { return nil }
            let text = summary.clientFollowUp
            guard !SensitiveDataProtector.containsUnrestoredMarker(text) else { return nil }
            return DaisyKeyCommandParser.cleaned(text, field: context.field)
        }
        let still = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.stillWritingAfter))
            guard !Task.isCancelled else { return }
            _ = WidgetBubbleCenter.shared.show(WidgetBubbleContent(text: String(localized: "Still writing…"), autoDismiss: 20, tag: Self.progressTag))
        }
        defer { still.cancel() }
        let escape = EscapeWatch { [weak self] in self?.stopWriting?() }
        defer { escape.stop() }
        var deadline: Task<Void, Never>?
        let outcome: String?? = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            stopWriting = { once.resume(.none); work.cancel() }
            Task { once.resume(.some(await work.value)) }
            deadline = Task {
                try? await Task.sleep(for: .seconds(Self.giveUpAfter))
                guard !Task.isCancelled else { return }
                once.resume(.none)
                work.cancel()
            }
        }
        deadline?.cancel()
        guard let finished = outcome else {
            log.info("Daisy key command stopped (Esc or \(Int(Self.giveUpAfter), privacy: .public) s) — the words are in the command history")
            return .stopped
        }
        return finished.map(Written.text) ?? .failed
    }

    nonisolated static let stillWritingAfter: TimeInterval = 15
    nonisolated static let giveUpAfter: TimeInterval = 30
    nonisolated static let progressTag = "daisy-key-progress"

    /// Whether commands may go to this cloud provider (one yes each).
    static func cloudAllowed(_ kind: SummaryProviderKind) -> Bool {
        UserDefaults.standard.bool(forKey: "daisy.daisyKey.cloudAllowed.\(kind.rawValue)")
    }

    static func allowCloud(_ kind: SummaryProviderKind) {
        UserDefaults.standard.set(true, forKey: "daisy.daisyKey.cloudAllowed.\(kind.rawValue)")
    }

    /// The words as a note in the default notes folder — the end of every
    /// path that doesn't work out. `offerToRun`: the note's message carries
    /// «Это команда — выполнить».
    private func keepAsNote(_ words: String, samples: [Float], durationSec: Int, entryID: UUID,
                            outcome: String, message: String?, offerToRun: Bool, context: DaisyKeyContext = .empty) async {
        let slug = FolderStore.shared.defaultNoteFolderSlug
        guard let saved = await DaisyKeyNote.write(body: words, samples: samples, durationSec: durationSec, folderSlug: slug) else {
            return noteNotSaved(words, entryID: entryID)
        }
        await SessionStore.shared.refresh()
        DaisyCommandHistory.shared.setOutcome(outcome, for: entryID)
        guard let message else { return }
        if offerToRun {
            tell(message, action: (String(localized: "It’s a command — run it"), { [weak self] in
                Task {
                    // The selection seen at the press still counts as the
                    // source; nothing is inserted this late, only copied.
                    let kind = DaisyKeyCommandParser.kind(of: words, hasSelection: context.hasSelection, selectionEditable: false) ?? .write
                    await self?.runCommand(kind, request: words, context: context, bundleID: nil, entryID: entryID,
                                           samples: [], durationSec: 0, atPress: false, noteKept: true)
                }
            }))
        } else {
            tell(message, action: (String(localized: "Open"), { AppNavigation.shared.openInLibrary(saved) }))
        }
    }

    // MARK: Pieces

    /// Nothing was said. Over a selection: rewrite it in my voice, as the
    /// old rewrite key did. With nothing selected: say so, keep nothing.
    /// Returns whether the rewrite was asked for.
    @discardableResult
    private func silentHold(context: DaisyKeyContext) -> Bool {
        if context.isSecureField {
            log.info("Daisy key: silent hold in a password field — nothing done")
            return false
        }
        if context.mayHaveSelection {
            ImprovementStats.record(.daisyKeyRewriteSilent)
            Task { await SelectionRewrite.shared.trigger() }
            return true
        }
        tell(String(localized: "Didn’t hear anything"))
        return false
    }

    /// The user's folders, with the names system folders answer to in
    /// speech in either language.
    private static func folders() -> [DaisyKeyFolderRoute.Folder] {
        FolderStore.shared.allFolders.map { folder in
            var names = [folder.name]
            if folder.slug == SessionFolder.inbox.slug { names += ["Входящие", "Inbox"] }
            if folder.slug == SessionFolder.notes.slug { names += ["Заметки", "Notes"] }
            return DaisyKeyFolderRoute.Folder(slug: folder.slug, names: names)
        }
    }

    /// The note couldn't be written: the words are in the Command History
    /// already, and go on the clipboard too, so nothing is lost.
    private func noteNotSaved(_ text: String, entryID: UUID) {
        DaisyCommandHistory.shared.setOutcome("failed", for: entryID)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        tell(String(localized: "Couldn’t save the note — the text is on the clipboard and in the command history"), style: .warning)
    }

    /// Said where the person is: the key is pressed from other apps, and
    /// the toast lives in Daisy's window — so the widget's pill too, or a
    /// notification when there is no pill.
    private func tell(_ text: String, style: Toast.Style = .info,
                      action: (label: String, run: @MainActor () -> Void)? = nil) {
        if let action {
            ToastCenter.shared.showAction(text, actionLabel: action.label, style: style, duration: .seconds(8), perform: action.run)
        } else {
            ToastCenter.shared.show(text, style: style)
        }
        // From the pill the action has to bring the window up too: the
        // Library behind a closed window shows nothing.
        let fromPill: (@MainActor () -> Void)? = action.map { action in
            { action.run(); WidgetBubbleCenter.shared.openMainWindow?() }
        }
        WidgetBubbleCenter.shared.present(
            WidgetBubbleContent(text: text, actionTitle: action?.label, autoDismiss: 8, tag: "daisy-key", action: fromPill),
            notificationTitle: "Daisy"
        )
    }

    /// The person's vocabulary and the brand table, as a dictation gets —
    /// without the dictation history or the voice-profile corpus: a
    /// command is not a sample of how they write.
    static func corrected(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        var text = DictationDictionary.shared.applyCounting(to: trimmed).0
        if UserDefaults.standard.object(forKey: BrandCorrections.defaultsKey) as? Bool ?? true {
            let triggers = Set(DictationDictionary.shared.replacements.map { $0.from.lowercased() })
            text = BrandCorrections.apply(to: text, userTriggers: triggers).text
        }
        return text
    }
}

/// Resumes a continuation once, whoever comes first.
nonisolated private final class Once<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
    func resume(_ value: Value) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

/// Esc, anywhere, while a command is being written: in another app (the
/// global monitor) or in Daisy's own window (the local one).
@MainActor
private final class EscapeWatch {
    private var monitors: [Any] = []

    init(_ onEscape: @escaping @MainActor () -> Void) {
        let handle: (NSEvent) -> Void = { event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in onEscape() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handle) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handle($0); return $0 }) { monitors.append(local) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}

