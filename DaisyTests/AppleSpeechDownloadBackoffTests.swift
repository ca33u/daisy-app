//
//  AppleSpeechDownloadBackoffTests.swift
//  DaisyTests
//
//  B-4 (19.10): a failed Apple speech model download is not retried on
//  every recording — once a day per locale, cleared by a success.
//

import Foundation
import Testing
@testable import Daisy

struct AppleSpeechDownloadBackoffTests {
    private let failed = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aFreshLocaleIsTried() {
        #expect(AppleSpeechDownloadBackoff.shouldAttempt(lastFailureAt: nil, now: failed))
    }

    @Test func aFailureHoldsForADay() {
        #expect(!AppleSpeechDownloadBackoff.shouldAttempt(lastFailureAt: failed, now: failed.addingTimeInterval(60)))
        #expect(!AppleSpeechDownloadBackoff.shouldAttempt(lastFailureAt: failed, now: failed.addingTimeInterval(23 * 3600)))
        #expect(AppleSpeechDownloadBackoff.shouldAttempt(lastFailureAt: failed, now: failed.addingTimeInterval(24 * 3600)))
    }

    @Test func theKeyIsPerLocale() {
        #expect(AppleSpeechDownloadBackoff.key("ru-RU") != AppleSpeechDownloadBackoff.key("en-US"))
        #expect(AppleSpeechDownloadBackoff.key("ru-RU").hasSuffix("ru-RU"))
    }
}
