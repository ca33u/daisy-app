//
//  CrashReportsTests.swift
//  DaisyTests
//
//  A crash report carries the failure, versions and the Mac's model, and
//  nothing about the person (backlog 27 С-2, 2026-10-09).
//

import Foundation
import Sentry
import Testing
@testable import Daisy

struct CrashReportsTests {
    @Test func scrubKeepsTheFailureAndDropsThePerson() throws {
        let home = NSHomeDirectory()
        let event = Event(level: .fatal)
        event.user = User(userId: "someone")
        event.serverName = "Egor's MacBook Air"
        event.message = SentryMessage(formatted: "Meeting with Maria")
        event.context = [
            "device": ["name": "Egor's MacBook Air", "model": "Mac15,12", "locale": "ru_RU", "free_memory": 123],
            "app": ["app_version": "1.0.8.31", "device_app_hash": "abc", "app_start_time": "2026-10-09"],
            "culture": ["locale": "ru_RU"],
            "user info": ["NSFilePath": "\(home)/Desktop/Meets/Meeting with Maria.md"],
        ]
        let exception = Exception(value: "Fatal error at \(home)/Library/x", type: "EXC_BAD_ACCESS")
        let mechanism = Mechanism(type: "mach")
        mechanism.data = ["crash_info": ["message": "abort at \(home)/Develop/x.swift"]]
        exception.mechanism = mechanism
        let frame = Frame()
        frame.package = "\(home)/Applications/Daisy.app/Contents/MacOS/Daisy"
        exception.stacktrace = SentryStacktrace(frames: [frame], registers: [:])
        event.exceptions = [exception]

        let json = CrashReports.preview(event)
        #expect(!json.contains(home))
        #expect(!json.contains("Egor's MacBook Air"))
        #expect(!json.contains("someone"))
        #expect(!json.contains("Maria"))
        #expect(!json.contains("ru_RU"))
        #expect(!json.contains("device_app_hash"))
        #expect(!json.contains("free_memory"))
        #expect(!json.contains("app_start_time"))
        #expect(!json.contains("user info"))
        #expect(json.contains("~/Develop/x.swift"))
        #expect(json.contains("EXC_BAD_ACCESS"))
        #expect(json.contains("Mac15,12"))
        #expect(json.contains("~/Applications/Daisy.app"))
    }
}
