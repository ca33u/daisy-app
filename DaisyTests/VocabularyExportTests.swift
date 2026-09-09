//
//  VocabularyExportTests.swift
//  DaisyTests
//
//  The export file is the bulk-import format; a round trip must keep
//  every entry, its kind and its order.
//

import Foundation
import Testing
@testable import Daisy

@Suite("Vocabulary export round-trips through bulk import")
struct VocabularyExportTests {
    @Test("Terms and corrections survive export → parseImport")
    func roundTrip() {
        let original = [
            DictationReplacement(kind: .term, from: "", to: "Kubernetes"),
            DictationReplacement(kind: .correction, from: "my sql", to: "MySQL"),
            DictationReplacement(kind: .term, from: "", to: "Дейзи"),
            DictationReplacement(kind: .correction, from: "клод", to: "Claude"),
        ]
        let text = DictationDictionary.exportText(original)
        #expect(text.hasPrefix("# Daisy vocabulary"))
        let back = DictationDictionary.parseImport(text)
        #expect(back.map(\.kind) == original.map(\.kind))
        #expect(back.map(\.from) == original.map(\.from))
        #expect(back.map(\.to) == original.map(\.to))
    }
}
