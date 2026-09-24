//
//  UnfinishedFinalPassTests.swift
//  DaisyTests
//
//  24.09: a recording cut short by the next one was queued for its final
//  pass — and the queue dropped the job because the session already had
//  its live transcript, which a rotated recording always has. The job now
//  carries that it REPLACES the live transcript; older queue files, from
//  before the flag, must still load.
//

import Foundation
import Testing
@testable import Daisy

@Suite("A recording cut short by the next one gets its final pass")
struct UnfinishedFinalPassTests {
    @Test func aQueueFileFromBeforeTheFlagStillLoads() throws {
        let old = """
        [{"id":"9D2BD2C4-8320-47B9-8C25-80FB84136F77","sessionID":"2026-09-24T05-36-30Z",
          "directoryPath":"/tmp/x","title":"Meeting","modelID":"m","language":"auto","diarize":true,
          "createdAt":780000000,"attempts":0}]
        """
        let jobs = try JSONDecoder().decode([ImportTranscriptionJob].self, from: Data(old.utf8))
        #expect(jobs.count == 1)
        #expect(jobs[0].finishesLiveTranscript == nil, "An import job, as before")
    }

    @Test func theFlagSurvivesTheQueueFile() throws {
        let job = ImportTranscriptionJob(
            id: UUID(), sessionID: "s", directoryPath: "/tmp/s", title: "t", modelID: "m",
            language: "auto", diarize: true, notBefore: nil, createdAt: Date(), attempts: 0,
            lastError: nil, finishesLiveTranscript: true)
        let back = try JSONDecoder().decode(ImportTranscriptionJob.self, from: JSONEncoder().encode(job))
        #expect(back.finishesLiveTranscript == true)
    }
}
