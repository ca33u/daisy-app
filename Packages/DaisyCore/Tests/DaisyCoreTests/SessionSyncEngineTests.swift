//
//  SessionSyncEngineTests.swift
//  DaisyCoreTests
//
//  backlog 9 Ф3-A: a phone and a Mac, one shared transport. The DoD in
//  miniature: a session recorded on one side appears on the other; a
//  title edited on the phone and diarization added on the Mac at the
//  same time both survive; a body edited on both sides keeps the loser
//  beside the file; a speaker map is never emptied by the other side;
//  a remote deletion never deletes a local folder.
//

import Testing
import Foundation
@testable import DaisyCore

@MainActor
@Suite("SessionSyncEngine (two devices, one transport)")
struct SessionSyncEngineTests {
    struct Device {
        let base: SessionsBase
        let engine: SessionSyncEngine
        var sessions: URL { base.sessionsDirectory }
        func transcript(_ id: String) throws -> String {
            try String(contentsOf: sessions.appendingPathComponent("\(id)/transcript.md"), encoding: .utf8)
        }
    }

    private func makeDevice(_ name: String, transport: InMemorySyncTransport) throws -> Device {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(name)-\(UUID().uuidString)", isDirectory: true)
        let base = SessionsBase(base: root)
        try FileManager.default.createDirectory(at: base.sessionsDirectory, withIntermediateDirectories: true)
        let engine = SessionSyncEngine(base: base, stateURL: root.appendingPathComponent("sync-state.json"), transport: transport)
        return Device(base: base, engine: engine)
    }

    private func writeSession(_ device: Device, id: String, title: String, body: String = "# T\n\n## Transcript\n\n**[0:00 · Me]** hello\n", speakerMap: String = "{}") throws {
        let dir = device.sessions.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = "---\ntitle: \"\(title)\"\ndaisy_kind: recording\ndaisy_origin: iphone\ndaisy_speaker_map: \(speakerMap)\ntags: [meeting, transcript, daisy]\n---\n\n" + body
        try text.write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try Data(repeating: 1, count: 100).write(to: dir.appendingPathComponent("microphone.caf"))   // never travels
    }

    /// File mtimes are the local stamps: make sure a later write is later.
    private func tick() async { try? await Task.sleep(for: .milliseconds(1100)) }

    @Test func recordedOnThePhoneAppearsOnTheMacWithoutAudio() async throws {
        let cloud = InMemorySyncTransport()
        let phone = try makeDevice("phone", transport: cloud)
        let mac = try makeDevice("mac", transport: cloud)
        try writeSession(phone, id: "2026-09-21T10-00-00Z", title: "Field")
        try Data("{\"summary\":\"x\"}".utf8).write(to: phone.sessions.appendingPathComponent("2026-09-21T10-00-00Z/summary.json"))
        let up = try await phone.engine.syncOnce()
        #expect(up.pushed == 1)
        let down = try await mac.engine.syncOnce()
        #expect(down.pulled == 1)
        let text = try mac.transcript("2026-09-21T10-00-00Z")
        #expect(SessionDocument.parseFrontmatter(in: text).title == "Field")
        #expect(text.contains("**[0:00 · Me]** hello"))
        #expect(FileManager.default.fileExists(atPath: mac.sessions.appendingPathComponent("2026-09-21T10-00-00Z/summary.json").path))
        #expect(!FileManager.default.fileExists(atPath: mac.sessions.appendingPathComponent("2026-09-21T10-00-00Z/microphone.caf").path))
        // Nothing to do on a second round.
        let again = try await mac.engine.syncOnce()
        #expect(again == .init())
    }

    @Test func titleOnThePhoneAndDiarizationOnTheMacBothSurvive() async throws {
        let cloud = InMemorySyncTransport()
        let phone = try makeDevice("phone", transport: cloud)
        let mac = try makeDevice("mac", transport: cloud)
        let id = "2026-09-21T11-00-00Z"
        try writeSession(phone, id: id, title: "Draft")
        _ = try await phone.engine.syncOnce()
        _ = try await mac.engine.syncOnce()
        await tick()
        // Phone renames; Mac names a speaker — at the same time.
        try SessionEditing.saveTitle("Meeting with Roman", to: phone.sessions.appendingPathComponent("\(id)/transcript.md"))
        let macURL = mac.sessions.appendingPathComponent("\(id)/transcript.md")
        let macText = SessionDocument.upsertFrontmatter(in: try String(contentsOf: macURL, encoding: .utf8), key: "daisy_speaker_map", value: "{A: \"Roman\"}")
        try macText.write(to: macURL, atomically: true, encoding: .utf8)
        _ = try await mac.engine.syncOnce()
        _ = try await phone.engine.syncOnce()   // pulls the map, pushes the title
        _ = try await mac.engine.syncOnce()     // pulls the title
        let p = SessionDocument.parseFrontmatter(in: try phone.transcript(id))
        let m = SessionDocument.parseFrontmatter(in: try mac.transcript(id))
        #expect(p.title == "Meeting with Roman" && m.title == "Meeting with Roman")
        #expect(p.speakerMap == ["A": "Roman"] && m.speakerMap == ["A": "Roman"])
    }

    @Test func bodyEditedOnBothSidesKeepsTheLoserBesideTheFile() async throws {
        let cloud = InMemorySyncTransport()
        let phone = try makeDevice("phone", transport: cloud)
        let mac = try makeDevice("mac", transport: cloud)
        let id = "2026-09-21T12-00-00Z"
        try writeSession(phone, id: id, title: "T")
        _ = try await phone.engine.syncOnce()
        _ = try await mac.engine.syncOnce()
        await tick()
        try SessionEditing.save(transcript: "**[0:00 · Me]** hello from the phone", to: phone.sessions.appendingPathComponent("\(id)/transcript.md"))
        await tick()
        try SessionEditing.save(transcript: "**[0:00 · Me]** hello from the Mac", to: mac.sessions.appendingPathComponent("\(id)/transcript.md"))
        _ = try await phone.engine.syncOnce()
        let macRound = try await mac.engine.syncOnce()
        #expect(macRound.conflicts == 1)
        // The Mac's edit was later: it wins, the phone's text is kept beside.
        #expect(try mac.transcript(id).contains("hello from the Mac"))
        let conflicts = try FileManager.default.contentsOfDirectory(atPath: mac.sessions.appendingPathComponent(id).path).filter { $0.hasPrefix("transcript.conflict-") }
        #expect(conflicts.count == 1)
        #expect(try String(contentsOf: mac.sessions.appendingPathComponent("\(id)/\(conflicts[0])"), encoding: .utf8).contains("hello from the phone"))
        _ = try await phone.engine.syncOnce()
        #expect(try phone.transcript(id).contains("hello from the Mac"))
    }

    @Test func speakerMapIsNeverEmptiedByTheOtherSide() async throws {
        let cloud = InMemorySyncTransport()
        let phone = try makeDevice("phone", transport: cloud)
        let mac = try makeDevice("mac", transport: cloud)
        let id = "2026-09-21T13-00-00Z"
        try writeSession(phone, id: id, title: "T")
        _ = try await phone.engine.syncOnce()
        _ = try await mac.engine.syncOnce()
        await tick()
        // Mac diarizes and names; phone re-renders with `{}` a second later.
        let macURL = mac.sessions.appendingPathComponent("\(id)/transcript.md")
        try SessionDocument.upsertFrontmatter(in: try String(contentsOf: macURL, encoding: .utf8), key: "daisy_speaker_map", value: "{A: \"Roman\"}")
            .write(to: macURL, atomically: true, encoding: .utf8)
        await tick()
        let phoneURL = phone.sessions.appendingPathComponent("\(id)/transcript.md")
        var phoneText = try String(contentsOf: phoneURL, encoding: .utf8)
        phoneText = SessionDocument.upsertFrontmatter(in: phoneText, key: "daisy_speaker_map", value: "{}")
        phoneText = SessionDocument.upsertFrontmatter(in: phoneText, key: "daisy_tag", value: "\"Expo\"")
        try phoneText.write(to: phoneURL, atomically: true, encoding: .utf8)
        _ = try await mac.engine.syncOnce()
        _ = try await phone.engine.syncOnce()
        _ = try await mac.engine.syncOnce()
        #expect(SessionDocument.parseFrontmatter(in: try phone.transcript(id)).speakerMap == ["A": "Roman"])
        #expect(SessionDocument.parseFrontmatter(in: try mac.transcript(id)).tag == "Expo")
    }

    @Test func aMissingFolderIsNotADeletion() async throws {
        // The August rule: moved by hand, evicted, detached disk — the
        // server hears nothing, the other device keeps everything.
        let cloud = InMemorySyncTransport()
        let phone = try makeDevice("phone", transport: cloud)
        let mac = try makeDevice("mac", transport: cloud)
        let id = "2026-09-21T14-00-00Z"
        try writeSession(phone, id: id, title: "T")
        _ = try await phone.engine.syncOnce()
        _ = try await mac.engine.syncOnce()
        try FileManager.default.removeItem(at: phone.sessions.appendingPathComponent(id))
        _ = try await phone.engine.syncOnce()
        let round = try await mac.engine.syncOnce()
        #expect(round.deletedRemotely == 0)
        #expect(FileManager.default.fileExists(atPath: mac.sessions.appendingPathComponent("\(id)/transcript.md").path))
        // The phone's memory still holds the id: nothing was told.
        #expect(phone.engine.state.sessions[id] != nil)
    }

    @Test func anExplicitDeleteTravelsAsATombstoneAndTheOtherCopyGoesToTrash() async throws {
        let cloud = InMemorySyncTransport()
        let phone = try makeDevice("phone", transport: cloud)
        let mac = try makeDevice("mac", transport: cloud)
        let id = "2026-09-21T14-00-00Z"
        try writeSession(phone, id: id, title: "T")
        _ = try await phone.engine.syncOnce()
        _ = try await mac.engine.syncOnce()
        // The person taps Delete on the phone.
        try FileManager.default.removeItem(at: phone.sessions.appendingPathComponent(id))
        phone.engine.markDeleted(id)
        _ = try await phone.engine.syncOnce()
        let round = try await mac.engine.syncOnce()
        #expect(round.deletedRemotely == 1)
        let trashed = mac.sessions.appendingPathComponent("\(SessionSyncEngine.trashDirectoryName)/\(id)/transcript.md")
        #expect(!FileManager.default.fileExists(atPath: mac.sessions.appendingPathComponent("\(id)/transcript.md").path))
        #expect(FileManager.default.fileExists(atPath: trashed.path))
        // Nothing comes back on either side afterwards.
        let again = try await mac.engine.syncOnce()
        #expect(again.pushed == 0)
        let phoneAgain = try await phone.engine.syncOnce()
        #expect(phoneAgain.pulled == 0)
        #expect(!FileManager.default.fileExists(atPath: phone.sessions.appendingPathComponent(id).path))
    }

    @Test func aCopyRestoredFromTrashStaysLocalUntilEdited() async throws {
        let cloud = InMemorySyncTransport()
        let phone = try makeDevice("phone", transport: cloud)
        let mac = try makeDevice("mac", transport: cloud)
        let id = "2026-09-21T14-00-00Z"
        try writeSession(phone, id: id, title: "T")
        _ = try await phone.engine.syncOnce()
        _ = try await mac.engine.syncOnce()
        try FileManager.default.removeItem(at: phone.sessions.appendingPathComponent(id))
        phone.engine.markDeleted(id)
        _ = try await phone.engine.syncOnce()
        _ = try await mac.engine.syncOnce()
        // Restored by hand from the trash: stays here, silently.
        let trashed = mac.sessions.appendingPathComponent("\(SessionSyncEngine.trashDirectoryName)/\(id)")
        try FileManager.default.moveItem(at: trashed, to: mac.sessions.appendingPathComponent(id))
        #expect(try await mac.engine.syncOnce().pushed == 0)
        // Edited after the tombstone: a revival, it travels again.
        try await Task.sleep(for: .milliseconds(1100))
        try writeSession(mac, id: id, title: "T revived")
        #expect(try await mac.engine.syncOnce().pushed == 1)
        #expect(try await phone.engine.syncOnce().pulled == 1)
        #expect(FileManager.default.fileExists(atPath: phone.sessions.appendingPathComponent("\(id)/transcript.md").path))
    }

    @Test func aRecordingInProgressNeverTravels() async throws {
        let cloud = InMemorySyncTransport()
        let phone = try makeDevice("phone", transport: cloud)
        let id = "2026-09-21T15-00-00Z"
        try writeSession(phone, id: id, title: "Live")
        try Data("x".utf8).write(to: phone.sessions.appendingPathComponent("\(id)/.recording"))
        let round = try await phone.engine.syncOnce()
        #expect(round.pushed == 0)
    }
}
