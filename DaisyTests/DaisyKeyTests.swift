//
//  DaisyKeyTests.swift
//  DaisyTests
//
//  Backlog 34 K-1: what a Daisy-key hold means without a model, and
//  which folder a spoken note goes to. Nothing said is not a note; a
//  folder that isn't there drops no word.
//

import Foundation
import Testing
@testable import Daisy

struct DaisyKeyTests {
    @Test func silenceIsNotAnIntent() {
        #expect(DaisyKeyIntentParser.parse("") == nil)
        #expect(DaisyKeyIntentParser.parse("   ") == nil)
        #expect(DaisyKeyIntentParser.parse("…") == nil)
        #expect(DaisyKeyIntentParser.parse("Дейзи,") == nil)
    }

    @Test func noteOpeningsInBothLanguages() {
        #expect(DaisyKeyIntentParser.parse("Запиши, купить молоко") == .note("купить молоко"))
        #expect(DaisyKeyIntentParser.parse("заметка: позвонить Ане") == .note("позвонить Ане"))
        #expect(DaisyKeyIntentParser.parse("Запомни — пароль от вайфая на холодильнике") == .note("пароль от вайфая на холодильнике"))
        #expect(DaisyKeyIntentParser.parse("запиши заметку в проект Альфа бюджет") == .note("в проект Альфа бюджет"))
        #expect(DaisyKeyIntentParser.parse("Note: call the bank") == .note("call the bank"))
        #expect(DaisyKeyIntentParser.parse("Remember to send the deck") == .note("to send the deck"))
        #expect(DaisyKeyIntentParser.parse("Make a note, buy milk") == .note("buy milk"))
        #expect(DaisyKeyIntentParser.parse("Daisy, note buy milk") == .note("buy milk"))
    }

    @Test func anythingElseIsUnclearAndKeptWhole() {
        #expect(DaisyKeyIntentParser.parse("переведи на английский") == .unclear("переведи на английский"))
        #expect(DaisyKeyIntentParser.parse("Дейзи, что мы решили вчера") == .unclear("что мы решили вчера"))
        // A note word later in the sentence is not an opening.
        #expect(DaisyKeyIntentParser.parse("напомни записать") == .unclear("напомни записать"))
    }

    private let folders = [
        DaisyKeyFolderRoute.Folder(slug: "inbox", names: ["Inbox", "Входящие"]),
        DaisyKeyFolderRoute.Folder(slug: "альфа", names: ["Альфа"]),
        DaisyKeyFolderRoute.Folder(slug: "альфы", names: ["Альфы"]),
        DaisyKeyFolderRoute.Folder(slug: "работа", names: ["Работа"]),
        DaisyKeyFolderRoute.Folder(slug: "client a", names: ["Client A"]),
        DaisyKeyFolderRoute.Folder(slug: "client b", names: ["Client B"]),
    ]

    @Test func aNamedProjectIsFoundEvenWithAnEnding() {
        let work0 = DaisyKeyFolderRoute.route("во входящие купить хлеб", folders: folders)
        #expect(work0.folderSlug == nil)   // «во входящие» has no «проект/папку»: not a folder phrase
        let inbox = DaisyKeyFolderRoute.route("в папку Входящие купить хлеб", folders: folders)
        #expect(inbox == .init(folderSlug: "inbox", body: "купить хлеб"))
        let alpha = DaisyKeyFolderRoute.route("в проект Альфа, бюджет на ноябрь", folders: [folders[1], folders[3]])
        #expect(alpha == .init(folderSlug: "альфа", body: "бюджет на ноябрь"))
        let work = DaisyKeyFolderRoute.route("в папку Работы созвон в пятницу", folders: folders)
        #expect(work.folderSlug == "работа")
        #expect(work.body == "созвон в пятницу")
        let client = DaisyKeyFolderRoute.route("to project Client A send the contract", folders: folders)
        #expect(client == .init(folderSlug: "client a", body: "send the contract"))
    }

    @Test func noSuchProjectKeepsEveryWord() {
        let text = "в проект Бета позвонить юристу"
        #expect(DaisyKeyFolderRoute.route(text, folders: folders) == .init(folderSlug: nil, unmatched: true, body: text))
        // «Альфу» fits «Альфа» and «Альфы» equally: not a guess either.
        let tied = "в проект Альфу бюджет"
        #expect(DaisyKeyFolderRoute.route(tied, folders: folders) == .init(folderSlug: nil, ambiguous: true, body: tied))
    }

    @Test func noFolderPhraseIsJustTheNote() {
        #expect(DaisyKeyFolderRoute.route("купить молоко", folders: folders) == .init(folderSlug: nil, body: "купить молоко"))
        #expect(DaisyKeyFolderRoute.route("в магазин за хлебом", folders: folders).unmatched == false)
    }

    @Test func wordsMatchForgivesEndingsNotDifferentWords() {
        #expect(DaisyKeyFolderRoute.wordsMatch("альфу", "альфа"))
        #expect(DaisyKeyFolderRoute.wordsMatch("работы", "работа"))
        #expect(!DaisyKeyFolderRoute.wordsMatch("бета", "альфа"))
        #expect(!DaisyKeyFolderRoute.wordsMatch("ab", "abc"))
    }

    @Test func theNoteFileIsALibraryNote() {
        let md = DaisyKeyNote.markdown(body: "купить молоко", created: Date(timeIntervalSince1970: 1_800_000_000),
                                       durationSec: 4, folderSlug: "inbox")
        #expect(md.contains("daisy_kind: note"))
        #expect(md.contains("daisy_folder: inbox"))
        // No origin: a Daisy-key note is a Mac session, not the phone's room mic.
        #expect(!md.contains("daisy_origin"))
        #expect(md.contains("title: \"купить молоко\""))
        #expect(md.hasSuffix("купить молоко\n"))
        let long = String(repeating: "слово ", count: 30)
        #expect(DaisyKeyNote.title(for: long).count <= 61)
        #expect(DaisyKeyNote.title(for: "say \"hi\"") == "say \"hi\"")
        #expect(DaisyKeyNote.markdown(body: "say \"hi\"", created: Date(), durationSec: 0, folderSlug: "inbox")
            .contains("title: \"say \\\"hi\\\"\""))
    }

    @Test func tapIsShorterThanAThirdOfASecond() {
        #expect(DaisyKeyController.tapThreshold == 0.35)
        #expect(DaisyKeyController.maxHold == 300)
    }
}
