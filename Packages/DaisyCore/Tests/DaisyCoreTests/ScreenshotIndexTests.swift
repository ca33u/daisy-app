//
//  ScreenshotIndexTests.swift
//  DaisyCoreTests
//
//  backlog 6 F-2: the phone's photos land exactly where the Mac reads
//  them — `screenshots/001.jpg` + `index.json` `{"001.jpg": 12.0}`.
//

import Testing
import Foundation
@testable import DaisyCore

@Suite("ScreenshotIndex")
struct ScreenshotIndexTests {
    @Test func namesNumbersAndOrderMatchTheMac() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID().uuidString)", isDirectory: true)
        let dir = ScreenshotIndex.directory(in: tmp)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(dir.lastPathComponent == "screenshots")
        #expect(ScreenshotIndex.nextNumber(in: dir) == 1)
        #expect(ScreenshotIndex.name(number: 1) == "001.jpg")
        #expect(ScreenshotIndex.name(number: 1000) == "1000.jpg")
        for n in [2, 10, 1] {
            try Data([0xFF]).write(to: dir.appendingPathComponent(ScreenshotIndex.name(number: n)))
        }
        try Data([0xFF]).write(to: dir.appendingPathComponent("001 copy.jpg"))
        try Data([0xFF]).write(to: dir.appendingPathComponent("._002.jpg"))
        #expect(ScreenshotIndex.frames(in: dir).map(\.lastPathComponent) == ["001.jpg", "002.jpg", "010.jpg"])
        #expect(ScreenshotIndex.nextNumber(in: dir) == 11)

        try ScreenshotIndex.write(["001.jpg": 12.0, "002.jpg": 340.5], to: dir)
        let raw = try String(contentsOf: ScreenshotIndex.url(in: dir), encoding: .utf8)
        #expect(raw.contains("\"001.jpg\":12") && raw.contains("\"002.jpg\":340.5"))
        #expect(ScreenshotIndex.load(from: dir) == ["001.jpg": 12.0, "002.jpg": 340.5])
        #expect(ScreenshotIndex.load(from: tmp).isEmpty)
    }
}

extension ScreenshotIndexTests {
    @Test func appendNumbersAndStampsAndAddedLaterIsPastTheEnd() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("shots2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let first = try ScreenshotIndex.append(jpeg: Data([0xFF, 0xD8]), to: tmp, offsetSeconds: 14.12)
        let second = try ScreenshotIndex.append(jpeg: Data([0xFF, 0xD8]), to: tmp, offsetSeconds: 604_800)
        #expect(first.lastPathComponent == "001.jpg" && second.lastPathComponent == "002.jpg")
        let offsets = ScreenshotIndex.load(from: ScreenshotIndex.directory(in: tmp))
        #expect(offsets == ["001.jpg": 14.1, "002.jpg": 604_800])
        #expect(!ScreenshotIndex.isAddedLater(offset: 14.1, durationSec: 134))
        #expect(ScreenshotIndex.isAddedLater(offset: 604_800, durationSec: 134))
        let started = Date(timeIntervalSince1970: 1_000)
        #expect(ScreenshotIndex.offsetForAddingNow(started: started, now: Date(timeIntervalSince1970: 1_500)) == 500)
    }
}
