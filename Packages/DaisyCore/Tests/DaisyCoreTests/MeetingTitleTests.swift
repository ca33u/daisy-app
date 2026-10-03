//
//  MeetingTitleTests.swift
//  DaisyCoreTests
//
//  A meeting is named after its summary only while its title is the
//  app's own placeholder (03.10.2026).
//

import Foundation
import Testing
@testable import DaisyCore

@Suite("A meeting named after its summary")
struct MeetingTitleTests {
    @Test func onlyTheAppsOwnPlaceholdersAreAutomatic() {
        #expect(MeetingTitle.isAutomatic("Meeting 2026-10-03 14:20"))
        #expect(MeetingTitle.isAutomatic("Recording — 2026-10-03 14:20"))
        #expect(!MeetingTitle.isAutomatic("Voice note 2026-10-03 14:20"))
        #expect(!MeetingTitle.isAutomatic("Screenshot — 2026-10-03 14:20"))
        #expect(!MeetingTitle.isAutomatic("Weekly sync with Acme"))
        #expect(!MeetingTitle.isAutomatic("Meeting 2026-10-03 14:20 — pricing"))
    }

    @Test func aTitleSomeoneGaveIsNeverReplaced() {
        #expect(MeetingTitle.replacement(for: "🇯🇵 Японский", modelTitle: "Урок японского", summary: "Урок.") == nil)
        #expect(MeetingTitle.replacement(for: "Meeting 2026-10-03 14:20", modelTitle: "Pricing review with Acme", summary: "x") == "Pricing review with Acme")
    }

    @Test func theModelsTitleIsMadeFitForALine() {
        #expect(MeetingTitle.cleaned("«План запуска iPhone-версии».") == "План запуска iPhone-версии")
        #expect(MeetingTitle.cleaned("  one\ntwo  ") == "one two")
        #expect(MeetingTitle.cleaned("") == nil)
        #expect(MeetingTitle.cleaned("Meeting 2026-10-03 14:20") == nil)
        #expect((MeetingTitle.cleaned(String(repeating: "word ", count: 40)) ?? "").count <= 81)
    }

    @Test func withoutATitleTheFirstSentenceStandsIn() {
        let summary = "Обсудили план запуска iPhone-версии и сроки подачи в App Store. Решили подавать в ноябре."
        let title = MeetingTitle.replacement(for: "Recording — 2026-10-03 14:20", modelTitle: nil, summary: summary)
        #expect(title?.hasPrefix("Обсудили план запуска iPhone-версии") == true)
        #expect((title ?? "").count <= 61)
        #expect(MeetingTitle.replacement(for: "Meeting 2026-10-03 14:20", modelTitle: "  ", summary: "") == nil)
    }
}

@Suite("Project memory")
struct ProjectMemoryTests {
    private func meeting(_ id: String, day: Int, folder: String, tag: String = "", summary: String = "About things.") -> ProjectMemory.Earlier {
        ProjectMemory.Earlier(id: id, title: "T\(id)", startedAt: Date(timeIntervalSince1970: Double(day) * 86_400),
                              folderSlug: folder, tag: tag, summary: summary, steps: ["Anna: send the draft"])
    }
    private let now = Date(timeIntervalSince1970: 100 * 86_400)

    @Test func theNewestOfTheProjectThenOfTheTag() {
        let all = (1...6).map { meeting("p\($0)", day: $0, folder: "acme") }
            + [meeting("t1", day: 7, folder: "other", tag: "Pricing"), meeting("t2", day: 8, folder: "acme", tag: "pricing"),
               meeting("later", day: 200, folder: "acme"), meeting("empty", day: 9, folder: "acme", summary: " ")]
        let related = ProjectMemory.related(toID: "now", startedAt: now, folderSlug: "Acme", tag: "pricing", among: all)
        #expect(related.project.map(\.id) == ["t2", "p6", "p5", "p4"])
        #expect(related.tagged.map(\.id) == ["t1"])
    }

    @Test func inboxIsNotAProjectAndTheSwitchIsHonoured() {
        let all = [meeting("a", day: 1, folder: "inbox"), meeting("b", day: 2, folder: "acme", tag: "x")]
        #expect(ProjectMemory.related(toID: "n", startedAt: now, folderSlug: "inbox", tag: "", among: all).project.isEmpty)
        let off = ProjectMemory.related(toID: "n", startedAt: now, folderSlug: "acme", tag: "x", useProject: false, among: all)
        #expect(off.project.isEmpty)
        #expect(off.tagged.map(\.id) == ["b"])
    }

    @Test func theBlockIsFencedBoundedAndOldestFirst() throws {
        let block = try #require(ProjectMemory.block(
            projectName: "Acme", notes: "Boris is the CFO.", tag: nil,
            project: [meeting("p2", day: 2, folder: "acme"), meeting("p1", day: 1, folder: "acme")], tagged: []
        ))
        #expect(block.hasPrefix(ProjectMemory.opening))
        #expect(block.hasSuffix(ProjectMemory.closing))
        #expect(block.contains("Boris is the CFO."))
        #expect(block.range(of: "Tp1")!.lowerBound < block.range(of: "Tp2")!.lowerBound)
        #expect(block.contains("Next steps agreed then: Anna: send the draft"))
        let huge = try #require(ProjectMemory.block(projectName: nil, notes: String(repeating: "x", count: 50_000), tag: nil, project: [], tagged: []))
        #expect(huge.count < ProjectMemory.characterLimit + 200)
        #expect(ProjectMemory.block(projectName: "Acme", notes: " ", tag: nil, project: [], tagged: []) == nil)
        #expect(ProjectMemory.prepending(nil, to: "t") == "t")
    }

    @Test func aProjectWithOnlyNotesIsNotEmpty() {
        #expect(ProjectContext().isEmpty)
        #expect(!ProjectContext(notes: "who is who").isEmpty)
        #expect(!ProjectContext(memory: false).isEmpty)
        #expect(ProjectContext(memory: false).usesMemory == false)
    }
}
