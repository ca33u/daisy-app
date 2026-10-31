//
//  DaisyKey.swift
//  Daisy
//
//  The Daisy key (backlog 34 K-1, Egor 21.10.2026). One key for what
//  used to be the voice-note key, «rewrite in my voice» and — next —
//  voice commands. Two gestures, no menu:
//
//    • a TAP (< 0.35 s) fixes the keyboard layout (Egor 23.10 — it was
//      the long note until then); during a meeting, the side note;
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
//  lost; a tap discards that half-second and fixes the layout.
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
        // Text selected in a page that isn't a field — a message open in
        // Mail, an article in Safari — isn't in AXSelectedText; WebKit
        // gives it through text markers. Without this «напиши ответ» over
        // a selected email had nothing to answer (Egor 22.10).
        if context.selection == nil, let marked = markedSelection(from: element) {
            context.selection = marked
            context.selectionReadable = true
        }
        context.isEditable = isSettable(element, kAXValueAttribute as CFString)
            || (role == "AXWebArea" && isSettable(element, kAXSelectedTextRangeAttribute as CFString))
        return context
    }

    /// The text selected in `box` right now, or nil when there is none or
    /// it can't be read.
    static func currentSelection(in box: AXElementBox) -> String? {
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(box.element, kAXSelectedTextAttribute as CFString, &raw) == .success,
           let text = raw as? String, !text.isEmpty { return text }
        // Read the way `read()` read it, or an edit made over a page's
        // selection would never count as over the same one.
        return markedSelection(from: box.element)
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

    /// The selection as WebKit's text markers give it, from the focused
    /// element or the page it sits in (a few parents up, no further than
    /// the AXWebArea).
    static func markedSelection(from element: AXUIElement) -> String? {
        var current = element
        for _ in 0..<8 {
            var range: CFTypeRef?
            let asked = AXUIElementCopyAttributeValue(current, "AXSelectedTextMarkerRange" as CFString, &range)
            // An app that doesn't answer won't answer its parents either.
            if asked == .cannotComplete { return nil }
            if asked == .success, let range {
                var text: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(current, "AXStringForTextMarkerRange" as CFString, range, &text) == .success,
                   let marked = text as? String, !marked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return marked
                }
            }
            if string(current, kAXRoleAttribute) == "AXWebArea" { return nil }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = parent as! AXUIElement
            AXUIElementSetMessagingTimeout(current, 0.2)
        }
        return nil
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
        // «Создай заметку в проект Work…» wasn't a note (Egor 23.10).
        ["создай", "заметку"], ["добавь", "заметку"], ["сохрани", "заметку"], ["новая", "заметка"],
        ["create", "a", "note"], ["add", "a", "note"], ["save", "a", "note"], ["new", "note"],
        ["запиши", "заметку"], ["сделай", "заметку"], ["make", "a", "note"], ["take", "a", "note"], ["note", "down"], ["write", "down"],
        ["заметка"], ["заметку"], ["запиши"], ["запомни"], ["записать"], ["note"], ["remember"],
    ]
    /// «добавь заметку» / "add a note" are a note only before a project
    /// («…в проект Work: …»): over a selection, "add a note at the end
    /// that…" is an edit (review 23.10).
    static let projectOnlyOpenings: Set<[String]> = [["добавь", "заметку"], ["add", "a", "note"]]
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
                if projectOnlyOpenings.contains(opening), !DaisyKeyFolderRoute.opensWithFolderPhrase(rest) { continue }
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

    /// The request is for a prompt for another tool («сделай промпт для
    /// картинки…», «write a prompt for Midjourney…»).
    /// English "prompt" only as the thing asked for — last, or before
    /// "for / to / about…": "a prompt reply" is an adjective. «Переведи /
    /// объясни этот промпт» works on a prompt, it doesn't write one
    /// (review 23.10).
    static func asksForPrompt(_ text: String) -> Bool {
        var words = text.split(whereSeparator: \.isWhitespace).map { DaisyKeyIntentParser.normalized(String($0)) }
        if let first = words.first, DaisyKeyIntentParser.addressWords.contains(first) { words.removeFirst() }
        if let first = words.first, translateVerbs.contains(first) { return false }
        if answerOpenings.contains(where: { opening in words.count >= opening.count && zip(words, opening).allSatisfy { $0 == $1 } }) {
            return false
        }
        return words.indices.contains { i in
            let w = words[i]
            if w.hasPrefix("промпт") || w.hasPrefix("промт") { return true }
            guard w == "prompt" || w == "prompts" else { return false }
            return i == words.count - 1 || promptFollowers.contains(words[i + 1])
        }
    }
    static let promptFollowers: Set<String> = ["for", "to", "about", "that", "which", "of", "in", "on", "with", "describing"]

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

// MARK: - What a note asks for, and which folder it named

/// A held note that asks for its summary at the end — «…и сделай саммари
/// на это», «…самаризируй», «…and summarize it» (Egor 23.10). The ask is
/// taken off the note; only at the end, so «резюме кандидата» stays a note.
nonisolated enum DaisyKeyNoteSummary {
    /// Asks on their own: «…, самаризируй», "… and summarize".
    static let summaryVerbs: Set<String> = [
        "самаризируй", "саммаризируй", "суммаризируй", "самаризуй", "резюмируй",
        "summarize", "summarise",
    ]
    /// Only with a verb or «с» before them: «…отправить Пете саммари»,
    /// "the quarterly summary" and «резюме» (a CV) are what the note says.
    static let summaryNouns: Set<String> = ["саммари", "самари", "саммери", "резюме", "выжимку", "итоги", "summary"]
    static let leadIns: Set<String> = [
        "и", "а", "также", "ещё", "еще", "потом", "сделай", "добавь", "напиши", "пожалуйста",
        "краткое", "короткое", "небольшое",
        "and", "also", "then", "make", "add", "a", "please", "short", "brief", "quick",
    ]
    /// Imperatives only: «с резюме», "to write a summary", «подготовь
    /// итоги» are what the note says (review 23.10).
    static let nounOpeners: Set<String> = ["сделай", "добавь", "напиши", "make", "add"]
    /// Before the ask, these make it part of a sentence: "remind Pete to
    /// make a summary", «нужно сделать саммари».
    static let notAnAsk: Set<String> = ["to", "чтобы", "надо", "нужно", "должен", "должна", "попроси", "попросить", "ask"]
    static let tail: Set<String> = [
        "на", "это", "этого", "этому", "эту", "по", "к", "нему", "ней", "неё", "нее", "заметку", "заметке", "заметки",
        "it", "this", "the", "of", "for", "to", "too", "note",
    ]

    static func ask(in body: String) -> (body: String, wantsSummary: Bool) {
        let tokens = body.split(whereSeparator: \.isWhitespace).map(String.init)
        let words = tokens.map(DaisyKeyIntentParser.normalized)
        guard let at = words.indices.reversed().first(where: { summaryVerbs.contains(words[$0]) || summaryNouns.contains(words[$0]) }),
              at >= words.count - 8,
              words[(at + 1)...].allSatisfy({ tail.contains($0) || $0.isEmpty }) else { return (body, false) }
        var start = at
        while start > 0, leadIns.contains(words[start - 1]) { start -= 1 }
        if summaryNouns.contains(words[at]), !words[start..<at].contains(where: nounOpeners.contains) { return (body, false) }
        if start > 0, notAnAsk.contains(words[start - 1]) { return (body, false) }
        var kept = tokens[..<start].joined(separator: " ")
        while let last = kept.last, last == "," || last == ";" || last == "—" || last == "-" || last.isWhitespace { kept.removeLast() }
        guard kept.contains(where: \.isLetter) else { return (body, false) }
        return (kept, true)
    }
}

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

    /// Where the folder's name starts after «в проект / to the folder»,
    /// or 0 when the text doesn't open with such a phrase.
    static func nameStart(_ words: [String]) -> Int {
        guard words.count >= 2, prepositions.contains(DaisyKeyIntentParser.normalized(words[0])) else { return 0 }
        var i = 1
        if DaisyKeyIntentParser.normalized(words[i]) == "the", words.count >= 3 { i += 1 }
        return folderWords.contains(DaisyKeyIntentParser.normalized(words[i])) ? i + 1 : 0
    }

    static func opensWithFolderPhrase(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let start = nameStart(words)
        return start > 0 && start < words.count
    }

    static func route(_ text: String, folders: [Folder]) -> Result {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let nameStart = Self.nameStart(words)
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

    /// A long note's first words naming its project (Egor 22.10): «в
    /// проект Лендинг …», or «заметка в проект Лендинг …» — the way a held
    /// note is filed. nil when it doesn't open that way. Only the forms
    /// that send somewhere: «в проекте Альфа сроки поехали» is a story
    /// about the project, not where the note goes. The words themselves
    /// stay in the note.
    static let directions: Set<String> = ["в", "во", "to", "into"]
    static let destinations: Set<String> = ["проект", "папку", "project", "folder"]

    static func opening(_ text: String, folders: [Folder]) -> Result? {
        let lead = text.split(whereSeparator: \.isWhitespace).prefix(12).joined(separator: " ")
        let rest: String
        switch DaisyKeyIntentParser.parse(lead) {
        case .note(let said), .unclear(let said): rest = said
        case nil: return nil
        }
        let words = rest.split(whereSeparator: \.isWhitespace).map { DaisyKeyIntentParser.normalized(String($0)) }
        guard words.count >= 3, directions.contains(words[0]) else { return nil }
        let noun = words[1] == "the" ? words[2] : words[1]
        guard destinations.contains(noun) else { return nil }
        let result = route(rest, folders: folders)
        // «в проект» with no name after it names nothing.
        return result.folderSlug == nil && !result.unmatched && !result.ambiguous ? nil : result
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

    /// Better words for what was said: a command run during a meeting,
    /// read again from the meeting's final pass.
    func setText(_ text: String, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].text != text else { return }
        entries[index].text = text
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
    /// layout is fixed.
    case daisyKeyTap(UUID)
}

/// What the Daisy key is doing after its key-up, for the widget (the
/// widget's state language, Egor 21.10): lavender centre and white →
/// lavender petals while Daisy works, the stage told by motion — a slow
/// turn while it understands, petals growing one by one while it writes,
/// one flash when it's done. The hold itself (Listening) is read off the
/// session; this carries what comes after. Every stage ends on its own,
/// so an outcome that sets none can't leave the flower stuck.
@Observable
@MainActor
final class DaisyKeyIndicator {
    static let shared = DaisyKeyIndicator()

    enum Stage: Equatable {
        case none
        case understanding
        case writing
        case done
        case savedAsNote
        case failed
    }

    private(set) var stage: Stage = .none
    /// When the stage began: the writing petals' clock.
    private(set) var since = Date()
    /// A command is being written. A brief stage shown meanwhile (another
    /// hold kept as a note) falls back to writing, not to rest.
    var isWriting = false {
        didSet { if !isWriting, stage == .writing { show(.none) } }
    }
    @ObservationIgnored private var expiry: Task<Void, Never>?

    private init() {}

    func show(_ stage: Stage) {
        expiry?.cancel()
        self.stage = stage
        since = Date()
        guard let lasts = Self.lasts(stage) else { return }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(lasts))
            guard !Task.isCancelled, let self, self.stage == stage else { return }
            self.show(self.isWriting && stage != .writing ? .writing : .none)
        }
    }

    /// Ends a working stage nothing else ended (an outcome with no stage
    /// of its own: a silent hold, a stop) — back to writing if a command
    /// still is.
    func settle() {
        if stage == .understanding || (stage == .writing && !isWriting) {
            show(isWriting ? .writing : .none)
        }
    }

    /// A note was kept — unless the command it is kept from just failed:
    /// that stays red, as «Не вышло» (spec 21.10); the note is the safety
    /// net, the pill says so.
    func showSavedAsNote() {
        guard stage != .failed else { return }
        show(.savedAsNote)
    }

    /// How long each stage stays at most: the brief ones are the spec's
    /// («через 1 с — обычный вид»); the working ones outlast the command's
    /// own 30-second stop.
    nonisolated static func lasts(_ stage: Stage) -> TimeInterval? {
        switch stage {
        case .none: nil
        case .understanding: 60
        case .writing: 40
        case .done: 1
        case .savedAsNote: 1.2
        case .failed: 1.5
        }
    }
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
    /// The longest comment a meeting hold gives a moment.
    nonisolated static let maxComment: TimeInterval = 2 * 60
    /// A held-modifier press (⌃⌥, the right ⌘) that another key joins
    /// this soon was some other shortcut's start, and is thrown away;
    /// later, the person was talking, and it ends as a release does.
    nonisolated static let chordCancelWindow: TimeInterval = 1.5

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
        /// Set when the key went down during a meeting (K-3).
        var meeting: MeetingPress? = nil
    }

    /// What a hold during a meeting needs at its release: where in the
    /// recording it began, whether anything was said, and — when
    /// commands run during meetings — what was in front.
    private final class MeetingPress {
        let offset: Double
        let appName: String?
        let bundleID: String?
        let context: Task<DaisyKeyContext, Never>?
        /// The moment's frame, taken once the press is a hold — the screen
        /// as it was at the press, not after the comment (review 21.10).
        /// A tap cancels it before the capture; a silent hold or a command
        /// leaves it as one more ordinary screenshot.
        let frame: Task<String?, Never>
        /// Tenths of a second the microphone was above the speech floor.
        private(set) var audible = 0
        private var sampler: Task<Void, Never>?

        init(session: RecordingSession, readsContext: Bool) {
            offset = max(0, session.elapsed)
            let front = NSWorkspace.shared.frontmostApplication
            appName = front?.localizedName
            bundleID = front?.bundleIdentifier
            context = readsContext ? Task.detached(priority: .userInitiated) { DaisyKeyContext.read() } : nil
            frame = Task { [weak session] in
                try? await Task.sleep(for: .seconds(DaisyKeyController.tapThreshold))
                guard !Task.isCancelled, let session else { return nil }
                return await session.captureMomentFrame()
            }
            sampler = Task { [weak self, weak session] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, let session else { return }
                    if session.recorder.lastMicRMSDB > RecordingSession.sideNoteSpeechFloorDB { self.audible += 1 }
                }
            }
        }

        /// Three tenths of speech, as the side note's measure hears it.
        var heardSpeech: Bool { audible >= 3 }

        func finish(isTap: Bool) {
            sampler?.cancel()
            if isTap { frame.cancel() }
        }
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
    var isBusy: Bool { isWorking }
    /// Ends the command being written: Esc, the deadline, or its result.
    private var stopWriting: (() -> Void)?
    private var current: Press?
    private var holds: [UUID: Hold] = [:]
    /// Captures a cancel threw away: their finish starts no long note.
    private var cancelled: [UUID: Date] = [:]
    /// Holds a late cancel ended: their words count, their silence isn't
    /// a rewrite — it was the other shortcut.
    private var endedByChord: [UUID: Date] = [:]
    /// Presses whose capture was refused at key-down because nothing can
    /// transcribe it on this Mac (Intel, `WhisperEngine.runsOnThisMac`).
    /// Tap or hold isn't known yet then; the release decides: a tap still
    /// fixes the layout (no speech model needed), a hold says why.
    private var refusedStarts: Set<UUID> = []
    private var holdCap: Task<Void, Never>?

    private init() {}

    /// Whether key-up events can be had: the global key monitor needs
    /// Accessibility or Input Monitoring. Without either the key is
    /// registered tap-only (see `ServiceWiring`).
    static var canHold: Bool {
        AXIsProcessTrusted() || CGPreflightListenEventAccess()
    }

    nonisolated static let introducedKey = "daisy.daisyKey.introduced"
    /// Posted when a hold saved a note — the first-run tour's Daisy-key
    /// step finishes on it.
    nonisolated static let noteSaved = Notification.Name("daisy.daisyKey.noteSaved")

    /// Once, to someone who had a voice-note key before the Daisy key:
    /// notes and commands are a hold, the tap fixes the layout. On the
    /// widget's pill, or as a notification — a launch usually has no
    /// window in front. Not on a fresh install: onboarding says it.
    static func introduceIfNeeded(settings: AppSettings) {
        let defaults = UserDefaults.standard
        // Not from the test host: it shares the real app's defaults.
        guard settings.hasShownFirstRun, !TestHost.isActive, !defaults.bool(forKey: introducedKey) else { return }
        // «What's New» is about to say it, with the key in front of them.
        if WhatsNew.shouldOpen(hasShownFirstRun: settings.hasShownFirstRun) { return }
        guard settings.voiceNoteHotkey != .none else {
            defaults.set(true, forKey: introducedKey)
            return
        }
        guard canHold else { return }
        defaults.set(true, forKey: introducedKey)
        let key = settings.voiceNoteHotkey.displayLabel
        let text = String(localized: "Your voice-note key \(key) is now the Daisy key: hold and say “note …” or what to do, hold without a word over selected text to rewrite it. A tap fixes the keyboard layout")
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
        // A tap or hold over a recording doesn't need the command slot
        // (a side note, a moment), so only a capture waits for it.
        var mode = Self.mode(for: session)
        if isWorking, mode == .capturing {
            mode = .ignored
            tell(String(localized: "Still working on the last command"))
        }
        current = Press(token: token, at: Date(), mode: mode)
        if mode == .noCapture, session.currentMode == .meeting {
            current?.meeting = MeetingPress(session: session, readsContext: session.settings.daisyKeyMeetingCommands)
        }
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
        cancelled = cancelled.filter { Date().timeIntervalSince($0.value) < Self.maxHold * 2 }
        endedByChord = endedByChord.filter { Date().timeIntervalSince($0.value) < Self.maxHold * 2 }
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
            press.meeting?.finish(isTap: isTap)
            if isTap {
                press.meeting?.context?.cancel()
                await session.toggleVoiceNoteByHotkey()
            } else if session.currentMode == .meeting {
                if let meeting = press.meeting {
                    await meetingHoldFinished(meeting, session: session)
                } else {
                    tell(String(localized: "For a quiet marker, use the Mark this moment key"))
                }
            } else {
                tell(String(localized: "Stop the note first"))
            }
        case .capturing:
            if refusedStarts.remove(press.token) != nil {
                if isTap {
                    tapCaptureFinished(token: press.token, on: session)
                } else {
                    holdAbandoned(token: press.token)
                    tell(RecordingSession.dictationNeedsFastEngineMessage, style: .warning,
                         action: (String(localized: "Open Settings"), { AppNavigation.shared.openInSettings(.dictation, row: .dictationEngine) }),
                         opensWindow: false)
                }
                return
            }
            if isTap {
                session.markDaisyKeyTap(press.token)
            } else if !isWorking, Self.captures(press.token, on: session) || session.sideDictation.map({ Self.captures(press.token, on: $0) }) == true {
                // Only a hold whose capture really runs (or is starting) is
                // understood — a refused start never reaches the finish that
                // settles it — and not over a command still being written.
                DaisyKeyIndicator.shared.show(.understanding)
            }
            await session.stopDictationHotkey(daisyKeyToken: press.token)
            // A stop that really ran has finished (and settled) by now; one
            // still starting will settle at its finish.
            if !isTap, !Self.captures(press.token, on: session), session.sideDictation.map({ Self.captures(press.token, on: $0) }) != true {
                DaisyKeyIndicator.shared.settle()
            }
        }
    }

    /// Another key or modifier joined a held-modifier press (see
    /// `HotkeyAction.hold`'s `onCancel`): within `chordCancelWindow` the
    /// press was another shortcut's start — its capture is dropped as a
    /// tap's is, and no long note starts; after it, an ordinary release.
    func cancel(session: RecordingSession) async {
        guard let press = current else { return }
        if Date().timeIntervalSince(press.at) >= Self.chordCancelWindow {
            switch press.mode {
            case .capturing:
                endedByChord[press.token] = Date()
                await release(session: session)
                return
            case .noCapture:
                // A meeting comment that was said is kept; a quiet one
                // was the other shortcut's.
                if press.meeting?.heardSpeech == true {
                    await release(session: session)
                    return
                }
            case .ignored:
                break
            }
        }
        lastCancel = Date()
        current = nil
        holdCap?.cancel()
        holdCap = nil
        log.info("Daisy key: another key joined the hold — press dropped")
        switch press.mode {
        case .ignored:
            return
        case .noCapture:
            press.meeting?.finish(isTap: true)
            press.meeting?.context?.cancel()
        case .capturing:
            cancelled[press.token] = Date()
            session.markDaisyKeyTap(press.token)
            await session.stopDictationHotkey(daisyKeyToken: press.token)
        }
    }

    /// When a press was last dropped by a cancel — the meeting key that
    /// ran through ⌃⌥ waits for its capture to let go (`toggleByHotkey`).
    private(set) var lastCancel: Date?

    /// This press's capture is running or on its way on that session.
    private static func captures(_ token: UUID, on session: RecordingSession) -> Bool {
        (session.isDictating || session.pendingMode == .dictation || session.startingMode == .dictation)
            && session.ownsDictationCapture(token)
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

    /// A hold that came to nothing: its dictation start was dropped before
    /// the microphone opened (the key let go while a speech model was
    /// loading), or its words couldn't be transcribed. Nothing is
    /// understood — its bookkeeping goes and the flower settles.
    /// See `refusedStarts`.
    func startRefused(token: UUID) {
        refusedStarts.insert(token)
    }

    func holdAbandoned(token: UUID) {
        holds.removeValue(forKey: token)?.context.cancel()
        endedByChord.removeValue(forKey: token)
        cancelled.removeValue(forKey: token)
        DaisyKeyIndicator.shared.settle()
    }

    /// The tap's half-second is gone. A tap outside a recording fixes the keyboard layout — of the
    /// selection, or the word just typed — as the layout-fix shortcut
    /// does (Egor 23.10: notes are a hold now, the tap no longer starts
    /// one).
    func tapCaptureFinished(token: UUID, on session: RecordingSession) {
        holds.removeValue(forKey: token)?.context.cancel()
        if cancelled.removeValue(forKey: token) != nil { return }
        let settings = session.settings
        guard settings.layoutFixEnabled else {
            tell(String(localized: "A tap fixes the keyboard layout — turn it on in \(SettingsRow.layoutFixer.path)"),
                 action: (String(localized: "Open Settings"), { AppNavigation.shared.openInSettings(.dictation, row: .layoutFixer) }),
                 opensWindow: false)
            return
        }
        Task { @MainActor in await LayoutFixService.shared.trigger(settings: settings) }
    }

    /// A hold ended with its words recognized (possibly none). Saved
    /// first, then acted on.
    func holdFinished(token: UUID, transcript raw: String, samples: [Float], durationSec: Int) async {
        defer { DaisyKeyIndicator.shared.settle() }
        let hold = holds.removeValue(forKey: token)
        let chordEnded = endedByChord.removeValue(forKey: token) != nil
        let text = Self.corrected(raw)
        guard let intent = DaisyKeyIntentParser.parse(text) else {
            // A second or more with nothing recognized may still be
            // speech the engine missed: the audio is kept.
            let entryID: UUID? = durationSec >= 1 && !samples.isEmpty
                ? DaisyCommandHistory.shared.record(text: "", samples: samples, appName: hold?.appName, outcome: "silent")
                : nil
            let context = await hold?.context.value ?? .empty
            // With the card open a silent hold means nothing: its text is
            // not a selection to rewrite.
            if DaisyResultCard.shared.isOpen { return }
            // Ended by another shortcut, or in another app than it began
            // (⌘Tab under the hold): the selection isn't what was meant.
            if chordEnded || NSWorkspace.shared.frontmostApplication?.bundleIdentifier != hold?.bundleID {
                log.info("Daisy key: silent hold ended by another shortcut or app — no rewrite")
                return
            }
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
            // «…и сделай саммари» at the end asks for the note's summary
            // too (Egor 23.10); the words of the ask aren't the note.
            let ask = DaisyKeyNoteSummary.ask(in: route.body)
            guard let saved = await DaisyKeyNote.write(body: ask.body, samples: samples, durationSec: durationSec, folderSlug: slug) else {
                return noteNotSaved(text, entryID: entryID)
            }
            await SessionStore.shared.refresh()
            let folderName = FolderStore.shared.existingFolder(slug: slug)?.name ?? slug
            DaisyKeyIndicator.shared.showSavedAsNote()
            NotificationCenter.default.post(name: Self.noteSaved, object: nil)
            let misfiled = route.unmatched || route.ambiguous
            if misfiled {
                DaisyCommandHistory.shared.setOutcome("inbox", for: entryID)
                // The first «в проект X» with no X (Onboarding 2.0 tip):
                // offer to make X and put the note there, once.
                if let name = ContextTips.shared.projectOffer(for: rest.isEmpty ? text : rest, route: route) {
                    tell(ContextTips.Copy.projectAsk(name: name, savedTo: folderName),
                         action: (ContextTips.Copy.projectCreate(name), { [weak self] in
                             Task { @MainActor in await self?.createProject(name, moving: saved, savedTo: folderName) }
                         }),
                         opensWindow: false)
                } else {
                    tell(route.ambiguous
                         ? String(localized: "Several projects match — saved to \(folderName)")
                         : String(localized: "No such project — saved to \(folderName)"),
                         action: (String(localized: "Move"), { AppNavigation.shared.openInLibrary(saved) }))
                }
            } else {
                DaisyCommandHistory.shared.setOutcome("note", for: entryID)
                if !ask.wantsSummary {
                    tell(String(localized: "Note saved to \(folderName)"), style: .success,
                         action: (String(localized: "Open"), { AppNavigation.shared.openInLibrary(saved) }))
                }
            }
            // A misfiled note keeps its «Move» message: its summary is
            // written quietly, only a problem with it speaks up.
            if ask.wantsSummary { await summarizeNote(id: saved, slug: slug, body: ask.body, quiet: misfiled) }
            log.info("Daisy key note saved (\(ask.body.count, privacy: .public) chars, summary asked: \(ask.wantsSummary, privacy: .public))")
        case .unclear(let words):
            let context = await hold?.context.value ?? .empty
            // The card is open: what is said works on its text. Within five
            // minutes of closing it, an edit said with nothing selected
            // does too (spec 21.10).
            let card = DaisyResultCard.shared
            let saysAnEdit = DaisyKeyCommandParser.kind(of: words, hasSelection: true, selectionEditable: true) == .edit
            // A new selection is a new subject: the card doesn't take it.
            let freshSelection = context.hasSelection && context.selection != card.current
            // Open: anything without a fresh selection. Closed (five
            // minutes): only an edit said with nothing selected — selecting
            // the inserted text is an edit of the field, not of the card.
            let takesCard = card.isOpen ? !freshSelection : (!context.hasSelection && saysAnEdit && card.canRefineLast)
            if !context.isSecureField, takesCard {
                ImprovementStats.record(.daisyKeyIntent(saysAnEdit ? .edit : .write))
                await refineCard(words, entryID: entryID)
                return
            }
            // A password field is never read from or written to: what was
            // said there is a note, whatever it sounds like.
            if !context.isSecureField,
               let kind = DaisyKeyCommandParser.kind(of: words, hasSelection: context.hasSelection, selectionEditable: context.isEditable) {
                ImprovementStats.record(.daisyKeyIntent(kind == .edit ? .edit : .write))
                await runCommand(kind, request: words, context: context, bundleID: hold?.bundleID, appName: hold?.appName,
                                 entryID: entryID, samples: samples, durationSec: durationSec, atPress: true)
                return
            }
            ImprovementStats.record(.daisyKeyIntent(.unclear))
            await keepAsNote(words, samples: samples, durationSec: durationSec, entryID: entryID,
                             outcome: "unclear", message: String(localized: "Saved as a note"), offerToRun: true,
                             context: context.isSecureField ? .empty : context)
        }
    }

    // MARK: During a meeting (K-3)

    /// A hold during a meeting is a moment with a comment: the marker at
    /// the press, a frame when screenshots are on, and what was said —
    /// cut from the meeting's transcript and read back at finalize. With
    /// «Команды во время встречи» on, words that make a command run it
    /// instead. A silent hold marks nothing: there's a key for that.
    private func meetingHoldFinished(_ hold: MeetingPress, session: RecordingSession) async {
        // On the recording's clock, which the transcript's lines are on.
        // At most two minutes of it: a key-up that never came is let go at
        // five, and five minutes of the person's voice don't belong in
        // one comment — past the cap the words stay in the meeting.
        let start = session.mediaDate(hold.offset)
        let end = min(session.mediaNow, start.addingTimeInterval(Self.maxComment))
        guard hold.heardSpeech else {
            hold.context?.cancel()
            tell(String(localized: "For a quiet marker, use the Mark this moment key"))
            return
        }
        // Commands need the live words; with live transcription off there
        // are none to wait for.
        if let contextTask = hold.context, session.settings.liveTranscriptionTier != .off {
            let words = await Self.liveWords(of: session, from: start, to: end)
            let context = await contextTask.value
            if !words.isEmpty, !context.isSecureField,
               DaisyKeyIntentParser.parse(words).map({ if case .unclear = $0 { return true }; return false }) == true,
               let kind = DaisyKeyCommandParser.kind(of: words, hasSelection: context.hasSelection,
                                                     selectionEditable: context.isEditable) {
                // Said to Daisy, not to the meeting: cut like a comment, and
                // the history entry gets the final pass's words later.
                let entryID = DaisyCommandHistory.shared.record(text: words, samples: [], appName: hold.appName)
                session.cutFromMeeting(from: start, to: end, entryID: entryID)
                ImprovementStats.record(.daisyKeyHold)
                ImprovementStats.record(.daisyKeyMeetingCommand)
                ImprovementStats.record(.daisyKeyIntent(kind == .edit ? .edit : .write))
                await runCommand(kind, request: words, context: context, bundleID: hold.bundleID, appName: hold.appName,
                                 entryID: entryID, samples: [], durationSec: 0, atPress: true)
                return
            }
        }
        let frame = await hold.frame.value
        guard let marker = session.markMomentWithComment(offset: hold.offset, frame: frame, from: start, to: end) else {
            // The meeting stopped meanwhile: nothing was cut, the words
            // are in its transcript.
            tell(String(localized: "The recording ended before the moment was marked — what you said is in its transcript"))
            return
        }
        ImprovementStats.record(.daisyKeyMoment)
        tell(String(localized: "Moment marked at \(marker.timecode), with what you said"), style: .success)
    }

    /// What the meeting's live transcript heard over a hold. The live pass
    /// runs every 2–3.5 s, so this waits for the words to appear and for
    /// one more pass to settle their tail; ten seconds at most. Empty when
    /// live transcription heard nothing (or is off): the hold is a moment.
    private static func liveWords(of session: RecordingSession, from start: Date, to end: Date) async -> String {
        let deadline = Date().addingTimeInterval(10)
        var firstHeard: Date?
        var words = ""
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            words = session.uncutSegments
                .filter { MomentMarker.isComment($0, from: start, to: end) }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !words.isEmpty else { continue }
            if firstHeard == nil { firstHeard = Date() }
            if let firstHeard, Date().timeIntervalSince(firstHeard) >= 3 { break }
        }
        return corrected(words)
    }

    // MARK: Commands (K-2)

    /// Writes, changes or answers with the summary provider, then puts the
    /// result where it belongs. `atPress`: the field the key went down in
    /// is still the place to insert into (false when run later from a
    /// note's button — the result then goes to the clipboard). Anything
    /// that doesn't work out keeps the words as a note.
    private func runCommand(_ kind: DaisyKeyCommandKind, request: String, context: DaisyKeyContext, bundleID: String?,
                            appName: String? = nil, entryID: UUID, samples: [Float], durationSec: Int, atPress: Bool,
                            noteKept: Bool = false) async {
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
        guard await summarizer.isReady(for: .interactive) else {
            return await fallBack(String(localized: "No summary provider is available — saved as a note"))
        }
        // Commands take the interactive route: with the local model chosen
        // that is the provider chosen before it, and its consent is asked.
        let local = summarizer.interactiveProviderIsEffectivelyLocal
        let commandProvider = summarizer.interactiveProviderKind
        if !local, !Self.cloudAllowed(commandProvider) {
            // One yes per provider (spec 21.10): until then the words stay
            // a note, and the button is the yes.
            if !noteKept {
                await keepAsNote(request, samples: samples, durationSec: durationSec, entryID: entryID,
                                 outcome: "unclear", message: nil, offerToRun: false)
            }
            let provider = commandProvider.shortName
            tell(String(localized: "Commands send what you said and selected to \(provider). Saved as a note for now"),
                 action: (String(localized: "Allow and run"), { [weak self] in
                     Self.allowCloud(commandProvider)
                     Task { await self?.runCommand(kind, request: request, context: context, bundleID: bundleID, appName: appName,
                                                   entryID: entryID, samples: [], durationSec: 0, atPress: false, noteKept: true) }
                 }))
            return
        }
        let role: VoiceCommandContext.Role = kind == .edit ? .edit : (context.hasSelection ? .source : .none)
        let field = DaisyKeyCommandParser.field(bundleID: bundleID)
        // The voice is the language of what's being written: the selection's
        // for an edit, what was said for the rest.
        let voice = VoiceProfileStore.shared.resolveStyle(
            forTextIn: LanguageDetector.detect(kind == .edit ? (context.selection ?? request) : request))?.promptInstruction
        // «…по шаблону продажи»: a follow-up template the request names
        // gives the letter its structure (backlog 35 Ш-1).
        let named = kind == .write ? MeetingTemplateStore.shared.followUpTemplate(mentionedIn: request) : nil
        let commandContext = VoiceCommandContext(role: role, field: field, voice: voice, structure: named?.structure,
                                                 // «переведи этот промпт» edits a prompt, it doesn't write one.
                                                 prompt: kind != .edit && DaisyKeyCommandParser.asksForPrompt(request))

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
        // Written from nothing — «напиши ответ» with no message to answer —
        // it comes back as a skeleton of [?] (Egor 22.10): not a card.
        if role == .none, Self.isHollow(result) {
            DaisyCommandHistory.shared.setOutcome("hollow", for: entryID)
            tell(String(localized: "Nothing to answer — select the message text and say it again"))
            log.info("Daisy key command came back as placeholders only — nothing shown")
            return
        }
        ImprovementStats.record(.daisyKeyGenerated(local: local))
        if let named { MeetingTemplateStore.shared.markUsed(named.id.uuidString) }
        let insertable = atPress && (kind == .edit || (kind == .write && role == .none))
            && context.isEditable && !context.isSecureField
        // An edit goes in only over the same selection: a click elsewhere in
        // the same field during the wait would put it beside the original.
        let selectionStill = kind != .edit || context.element.flatMap(DaisyKeyContext.currentSelection(in:)) == context.selection
        let used = Self.usedLine(selection: role != .none, appName: appName)
        if insertable, selectionStill, let element = context.element, DaisyKeyContext.focusedElement() == element {
            DictationPaste.shared.insert(result)
            DaisyCommandHistory.shared.setOutcome("inserted", for: entryID)
            // An edit is a proposal: the card keeps the original, with
            // «Вернуть» and «Показать изменения» (research 21.10).
            if kind == .edit {
                DaisyResultCard.shared.show(result, used: used, original: context.selection, insertedInto: element,
                                            field: field, voice: voice)
            }
            log.info("Daisy key command inserted (\(result.count, privacy: .public) chars, \(local ? "local" : "cloud", privacy: .public))")
            return
        }
        if insertable {
            ImprovementStats.record(.daisyKeyFocusChanged)
            tell(String(localized: "Ready — you moved to another field, so it’s on the clipboard: ⌘V"), style: .success)
        }
        // Nowhere to put it (or the field moved): the card at the cursor,
        // and the clipboard.
        DaisyResultCard.shared.show(result, used: used, original: kind == .edit ? context.selection : nil,
                                    field: field, voice: voice)
        DaisyCommandHistory.shared.setOutcome("clipboard", for: entryID)
        log.info("Daisy key command to the card (\(result.count, privacy: .public) chars, kind \(String(describing: kind), privacy: .public))")
    }

    /// A text that is mostly «[?]»: placeholders where the body would go,
    /// a greeting and a sign-off around them. A short line with one
    /// unknown («Приду в [?].») is a real answer.
    nonisolated static func isHollow(_ text: String) -> Bool {
        let placeholders = text.components(separatedBy: "[?]").count - 1
        let bodyIsPlaceholder = text.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == "[?]" }
        guard placeholders >= 2 || bodyIsPlaceholder else { return false }
        return text.replacingOccurrences(of: "[?]", with: "").filter(\.isLetter).count < 25
    }

    /// «Использовано: выделение · Mail».
    static func usedLine(selection: Bool, appName: String?) -> String {
        var parts: [String] = []
        if selection { parts.append(String(localized: "selection")) }
        if let appName, !appName.isEmpty { parts.append(appName) }
        guard !parts.isEmpty else { return "Daisy" }
        return String(localized: "Used: \(parts.joined(separator: " · "))")
    }

    /// What was said works on the card's text: a new version on top.
    private func refineCard(_ request: String, entryID: UUID) async {
        let card = DaisyResultCard.shared
        let history = DaisyCommandHistory.shared
        guard !isWorking else {
            history.setOutcome("cardUnchanged", for: entryID)
            return tell(String(localized: "Still working on the last command"))
        }
        isWorking = true
        defer { isWorking = false }
        let summarizer = Summarizer.shared
        guard await summarizer.isReady(for: .interactive) else {
            history.setOutcome("cardUnchanged", for: entryID)
            return tell(String(localized: "No summary provider is available"), style: .warning)
        }
        let local = summarizer.interactiveProviderIsEffectivelyLocal
        guard local || Self.cloudAllowed(summarizer.interactiveProviderKind) else {
            // The provider changed since the card's text was written: the
            // new one needs its own yes.
            history.setOutcome("cardUnchanged", for: entryID)
            let kind = summarizer.interactiveProviderKind
            return tell(String(localized: "Commands send what you said and the card’s text to \(kind.shortName)"),
                        action: (String(localized: "Allow and run"), { [weak self] in
                            Self.allowCloud(kind)
                            Task { await self?.refineCard(request, entryID: entryID) }
                        }))
        }
        let base = card.current
        let payload = SummaryPrompt.voiceCommandPayload(request: request, source: base)
        switch await write(payload: payload, context: VoiceCommandContext(role: .edit, field: card.field, voice: card.voice)) {
        case .text(let result):
            ImprovementStats.record(.daisyKeyGenerated(local: local))
            card.addVersion(result)
            history.setOutcome("refined", for: entryID)
        case .stopped:
            history.setOutcome("stopped", for: entryID)
            tell(String(localized: "Stopped — what you said is in the command history"))
        case .failed:
            history.setOutcome("cardUnchanged", for: entryID)
            tell(String(localized: "Couldn’t change it — the card keeps the last version"), style: .warning)
        }
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
        // The flower writes with it, and says how it ended: one flash for a
        // result, red for none, back to rest for a stop.
        let indicator = DaisyKeyIndicator.shared
        indicator.isWriting = true
        indicator.show(.writing)
        var ended: DaisyKeyIndicator.Stage = .failed
        defer {
            indicator.isWriting = false
            indicator.show(ended)
        }
        _ = WidgetBubbleCenter.shared.show(WidgetBubbleContent(text: String(localized: "Writing…"), autoDismiss: 40, tag: Self.progressTag))
        defer { WidgetBubbleCenter.shared.dismiss(tag: Self.progressTag) }
        let work = Task<String?, Never> {
            guard let summary = try? await Summarizer.shared.runProbe(
                transcript: payload, title: "Daisy", localeHint: nil, task: .voiceCommand(context),
                route: .interactive) else { return nil }
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
            ended = .none
            return .stopped
        }
        if finished != nil { ended = .done }
        return finished.map(Written.text) ?? .failed
    }

    nonisolated static let stillWritingAfter: TimeInterval = 15
    nonisolated static let giveUpAfter: TimeInterval = 30
    nonisolated static let progressTag = "daisy-key-progress"

    /// Whether commands may go to this cloud provider (one yes each).
    static func cloudAllowed(_ kind: SummaryProviderKind, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "daisy.daisyKey.cloudAllowed.\(kind.rawValue)")
    }

    static func allowCloud(_ kind: SummaryProviderKind) {
        UserDefaults.standard.set(true, forKey: "daisy.daisyKey.cloudAllowed.\(kind.rawValue)")
    }

    /// Takes a yes back (Settings → Shortcuts → Daisy key): the next command for this
    /// provider asks again.
    static func revokeCloud(_ kind: SummaryProviderKind) {
        UserDefaults.standard.removeObject(forKey: "daisy.daisyKey.cloudAllowed.\(kind.rawValue)")
    }

    /// The cloud providers commands have a yes for.
    static var cloudAllowedProviders: [SummaryProviderKind] {
        SummaryProviderKind.allCases.filter { cloudAllowed($0) }
    }

    /// The summary a held note asked for: the summary provider, with the
    /// Daisy key's one-yes-per-cloud rule. Through `runProbe`, so a
    /// meeting finishing meanwhile keeps its own summary state — its card
    /// and auto-send read `Summarizer.lastSummary` (review 23.10).
    /// `quiet`: a misfiled note's «Move» message stays up — only asking
    /// for consent or a failure speaks over it.
    private func summarizeNote(id: String, slug: String, body: String, quiet: Bool = false) async {
        let folderName = FolderStore.shared.existingFolder(slug: slug)?.name ?? slug
        let open: (label: String, run: @MainActor () -> Void) = (String(localized: "Open"), { AppNavigation.shared.openInLibrary(id) })
        let summarizer = Summarizer.shared
        if summarizer.availability != .available { await summarizer.refreshAvailability() }
        guard summarizer.availability == .available else {
            if !quiet { tell(String(localized: "Note saved to \(folderName) — no summary provider is available for its summary"), action: open) }
            return
        }
        guard summarizer.providerIsEffectivelyLocal || Self.cloudAllowed(summarizer.providerKind) else {
            let kind = summarizer.providerKind
            tell(String(localized: "Note saved to \(folderName). Its summary would send it to \(kind.shortName)"),
                 action: (String(localized: "Allow and summarize"), { [weak self] in
                     Self.allowCloud(kind)
                     Task { await self?.summarizeNote(id: id, slug: slug, body: body, quiet: quiet) }
                 }))
            return
        }
        // Under eight words there's nothing to sum up — a model would pad
        // it. The note's own words: its transcript also carries the title.
        guard !Summarizer.isEffectivelySilent(body) else {
            if !quiet { tell(String(localized: "Note saved to \(folderName) — it’s too short for a summary"), action: open) }
            return
        }
        guard let session = SessionStore.shared.sessions.first(where: { $0.id == id }), !session.transcriptText.isEmpty else {
            if !quiet { tell(String(localized: "Note saved to \(folderName)"), style: .success, action: open) }
            return
        }
        let hint = RecordingSession.resolveSummaryLocaleHint(
            transcript: session.transcriptText, transcriptLocale: session.locale,
            summaryLanguageOverride: AppSettings.currentSummaryLanguage)
        if !quiet { tell(String(localized: "Note saved to \(folderName) — writing its summary…")) }
        guard let summary = try? await summarizer.runProbe(transcript: session.transcriptText, title: session.title, localeHint: hint) else {
            tell(String(localized: "Note saved to \(folderName), but its summary didn’t work out"), action: open)
            return
        }
        _ = await SessionStore.shared.updateSummary(summary, for: session)
        if !quiet { tell(String(localized: "Note saved to \(folderName) with a summary"), style: .success, action: open) }
    }

    /// The words as a note in the default notes folder — the end of every
    /// path that doesn't work out. `offerToRun`: the note's message carries
    /// «Это команда — выполнить».
    /// Returns whether the note was written.
    @discardableResult
    private func keepAsNote(_ words: String, samples: [Float], durationSec: Int, entryID: UUID,
                            outcome: String, message: String?, offerToRun: Bool, context: DaisyKeyContext = .empty) async -> Bool {
        let slug = FolderStore.shared.defaultNoteFolderSlug
        guard let saved = await DaisyKeyNote.write(body: words, samples: samples, durationSec: durationSec, folderSlug: slug) else {
            noteNotSaved(words, entryID: entryID)
            return false
        }
        await SessionStore.shared.refresh()
        DaisyCommandHistory.shared.setOutcome(outcome, for: entryID)
        DaisyKeyIndicator.shared.showSavedAsNote()
        guard let message else { return true }
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
        return true
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
    static func folders() -> [DaisyKeyFolderRoute.Folder] {
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
        DaisyKeyIndicator.shared.show(.failed)
        DaisyCommandHistory.shared.setOutcome("failed", for: entryID)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        tell(String(localized: "Couldn’t save the note — the text is on the clipboard and in the command history"), style: .warning)
    }

    /// «Создать «X»» on a misfiled note: the project, the note moved into
    /// it, and what came of it.
    private func createProject(_ name: String, moving note: StoredSession.ID, savedTo folderName: String) async {
        if let folder = await ContextTips.createProject(named: name, moving: note) {
            tell(ContextTips.Copy.projectCreated(folder.name), style: .success,
                 action: (String(localized: "Open"), { AppNavigation.shared.openInLibrary(note) }))
        } else {
            tell(ContextTips.Copy.projectNotMoved(folderName), style: .warning,
                 action: (String(localized: "Move"), { AppNavigation.shared.openInLibrary(note) }))
        }
    }

    /// Said where the person is: the key is pressed from other apps, and
    /// the toast lives in Daisy's window — so the widget's pill too, or a
    /// notification when there is no pill. `opensWindow`: the pill's action
    /// also brings Daisy's window up — off for an action that is done in
    /// place and says its outcome itself.
    func tell(_ text: String, style: Toast.Style = .info,
                      action: (label: String, run: @MainActor () -> Void)? = nil,
                      opensWindow: Bool = true) {
        if let action {
            ToastCenter.shared.showAction(text, actionLabel: action.label, style: style, duration: .seconds(8), perform: action.run)
        } else {
            ToastCenter.shared.show(text, style: style)
        }
        // From the pill the action has to bring the window up too: the
        // Library behind a closed window shows nothing.
        let fromPill: (@MainActor () -> Void)? = action.map { action in
            { action.run(); if opensWindow { WidgetBubbleCenter.shared.openMainWindow?() } }
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
final class EscapeWatch {
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

