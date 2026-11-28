// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  AccessibilityPromptTests.swift
//  DaisyTests
//
//  The test host must never put up the system Accessibility window
//  (18.11.2026: test runs left a screen of them to close by hand). The
//  window can't be observed from here, so the tests hold the two things
//  that keep it away: `AccessibilityPrompt.show` asks nothing in the test
//  host, and no other source file calls `AXIsProcessTrustedWithOptions`
//  itself. Other system calls that can ask for input access
//  (`CGRequestPostEventAccess`, `CGRequestListenEventAccess`) are not
//  used anywhere and are not scanned for.
//

import Foundation
import Testing
@testable import Daisy

@MainActor
struct AccessibilityPromptTests {
    @Test func theTestHostAsksNothing() {
        var asked = 0
        AccessibilityPrompt.show(ask: { asked += 1 })
        #expect(TestHost.isActive)
        #expect(asked == 0)
    }

    @Test func outsideTheTestHostItAsksOnce() {
        var asked = 0
        AccessibilityPrompt.show(isTestHost: false, ask: { asked += 1 })
        #expect(asked == 1)
    }

    @Test func onlyOneFileMakesTheSystemCall() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DaisyTests
            .deletingLastPathComponent()   // repository root
        let home = "Daisy/AccessibilityPrompt.swift"
        var scanned = 0
        var offenders: [String] = []
        for folder in ["Daisy", "DaisyLLM", "Packages/DaisyCore/Sources", "Packages/DaisyLLM/Sources"] {
            let base = root.appendingPathComponent(folder)
            var inFolder = 0
            let files = try #require(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil), "no folder \(folder)")
            for case let file as URL in files where file.pathExtension == "swift" {
                let path = String(file.path.dropFirst(root.path.count + 1))
                scanned += 1
                inFolder += 1
                guard path != home else { continue }
                let source = try String(contentsOf: file, encoding: .utf8)
                // The call and both spellings of its prompt option.
                if source.contains("AXIsProcessTrustedWithOptions") || source.contains("AXTrustedCheckOptionPrompt") {
                    offenders.append(path)
                }
            }
            // A folder that moved must fail here, not pass unread.
            #expect(inFolder > 0, "no Swift sources under \(folder)")
        }
        #expect(scanned > 100, "no sources found under \(root.path)")
        #expect(offenders.isEmpty, "ask through AccessibilityPrompt.show(): \(offenders)")
    }
}
