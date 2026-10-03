//
//  SummaryConnectionAndRunnerTests.swift
//  DaisyTests
//

import Foundation
import Testing
@testable import Daisy

@Suite("Summary account connection model")
struct SummaryConnectionTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "DaisyTests.SummaryConnection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test("Existing OpenAI installs stay on API key")
    func openAIMissingPreferenceMigratesToAPIKey() {
        withDefaults { defaults in
            defaults.set("gpt-existing", forKey: "daisy.openaiModel")
            defaults.set("leave-this-alone", forKey: "test.openaiKeySentinel")

            let preferences = SummaryConnectionPreferences(defaults: defaults)

            #expect(preferences.method(for: .openAI) == .apiKey)
            #expect(defaults.string(forKey: "daisy.openaiModel") == "gpt-existing")
            #expect(defaults.string(forKey: "test.openaiKeySentinel") == "leave-this-alone")
        }
    }

    @Test("Cursor stays on API key when an old account preference exists")
    func cursorAccountPreferenceMigratesToAPIKey() {
        withDefaults { defaults in
            let preferences = SummaryConnectionPreferences(defaults: defaults)
            preferences.setMethod(.account, for: .openAI)

            #expect(preferences.method(for: .openAI) == .account)
            #expect(preferences.method(for: .cursor) == .apiKey)

            defaults.set(
                SummaryConnectionMethod.account.rawValue,
                forKey: SummaryConnectionPreferences.methodKey(for: .cursor)
            )
            preferences.setMethod(.account, for: .cursor)
            #expect(preferences.method(for: .openAI) == .account)
            #expect(preferences.method(for: .cursor) == .apiKey)
        }
    }

    @Test("Single-method providers reject unsupported switches")
    func singleMethodProvidersStayFixed() {
        withDefaults { defaults in
            let preferences = SummaryConnectionPreferences(defaults: defaults)
            preferences.setMethod(.account, for: .anthropic)
            preferences.setMethod(.apiKey, for: .githubCopilot)

            #expect(preferences.method(for: .anthropic) == .apiKey)
            #expect(preferences.method(for: .githubCopilot) == .account)
        }
    }

    @Test("API and account model selections do not overwrite each other")
    func modelsArePerMethod() {
        withDefaults { defaults in
            defaults.set("gpt-api", forKey: "daisy.openaiModel")
            let preferences = SummaryConnectionPreferences(defaults: defaults)
            preferences.setAccountModel("gpt-account", for: .openAI)

            #expect(defaults.string(forKey: "daisy.openaiModel") == "gpt-api")
            #expect(preferences.accountModel(for: .openAI) == "gpt-account")
        }
    }

    @Test("Account state covers all shared UI states")
    func accountStateSurface() {
        let account = SummaryAccount(
            id: "acct_1",
            email: "person@example.com",
            displayName: "Person",
            plan: "Plus"
        )
        let states: [SummaryAccountState] = [
            .notInstalled,
            .signedOut,
            .connecting,
            .connected(account),
            .sessionExpired,
            .limitReached(resetAt: nil),
            .failed(message: "offline"),
        ]
        #expect(states.count == 7)
        #expect(states[3] == .connected(account))
    }

    @Test("Cloud disclosure acknowledgement is stored per provider")
    func disclosureIsPerProvider() {
        withDefaults { defaults in
            let preferences = SummaryConnectionPreferences(defaults: defaults)

            #expect(!preferences.hasAcknowledgedCloudDisclosure(for: .openAI))
            #expect(!preferences.hasAcknowledgedCloudDisclosure(for: .cursor))

            preferences.acknowledgeCloudDisclosure(for: .openAI)

            #expect(preferences.hasAcknowledgedCloudDisclosure(for: .openAI))
            #expect(!preferences.hasAcknowledgedCloudDisclosure(for: .cursor))
        }
    }
}

@Suite("Subscription request accounting")
@MainActor
struct SubscriptionUsageLedgerTests {
    @Test("Persists request facts without inventing token or price data")
    func persistenceAndAggregation() throws {
        let suite = "DaisyTests.SubscriptionUsage.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixedDate = Date(timeIntervalSince1970: 1_900_000_000)
        let key = "test.subscriptionUsage"

        let ledger = SubscriptionUsageLedger(
            defaults: defaults,
            defaultsKey: key,
            now: { fixedDate }
        )
        ledger.record(provider: .openai, model: "model-a", durationMilliseconds: 1_200, successful: true)
        ledger.record(provider: .openai, model: "model-a", durationMilliseconds: 800, successful: false)
        ledger.record(provider: .openai, model: "model-b", durationMilliseconds: 1_000, successful: true)
        ledger.record(provider: .anthropic, model: "ignored", durationMilliseconds: 9_999, successful: true)

        let restored = SubscriptionUsageLedger(
            defaults: defaults,
            defaultsKey: key,
            now: { fixedDate }
        )
        let usage = try #require(restored.recentUsage(provider: .openai, endingAt: fixedDate))

        #expect(usage.requestCount == 3)
        #expect(usage.successfulRequests == 2)
        #expect(usage.failedRequests == 1)
        #expect(usage.totalDurationMilliseconds == 3_000)
        #expect(usage.averageDurationSeconds == 1)
        #expect(usage.models == ["model-a", "model-b"])
        #expect(restored.recentUsage(provider: .anthropic, endingAt: fixedDate) == nil)
    }
}

@Suite("Meeting summary wire schema")
struct MeetingSummarySchemaTests {
    @Test("Canonical JSON Schema is valid and requires every wire field")
    func schemaIsValid() throws {
        let object = try JSONSerialization.jsonObject(with: MeetingSummaryJSONSchema.data)
        let schema = try #require(object as? [String: Any])
        let required = try #require(schema["required"] as? [String])

        #expect(schema["type"] as? String == "object")
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(Set(required) == ["title", "summary", "sections", "actionItems", "clientFollowUp"])
    }

    @Test("Malformed JSON is rejected by the shared parser")
    func malformedJSONIsRejected() {
        #expect(throws: (any Error).self) {
            _ = try CloudSummaryDTO.decode(
                from: #"{"summary":"cut off","sections":[}"#
            )
        }
    }

    @Test("Incomplete JSON keeps legacy tolerant defaults")
    func incompleteJSONUsesExistingDefaults() throws {
        let dto = try CloudSummaryDTO.decode(from: #"{"summary":"Only the lede"}"#)
        let summary = dto.toMeetingSummary()

        #expect(summary.summary == "Only the lede")
        #expect(summary.sections.isEmpty)
        #expect(summary.actionItems.isEmpty)
        #expect(summary.clientFollowUp.isEmpty)
    }
}

@Suite("Agent process runner")
struct AgentProcessRunnerTests {
    @Test("Transcript travels through stdin and scratch folder is deleted")
    func stdinAndCleanup() async throws {
        let runner = try AgentProcessRunner(executable: .testCat)
        let transcript = "private transcript payload"
        let result = try await runner.run(.init(
            arguments: [],
            stdin: Data(transcript.utf8),
            timeout: 2
        ))

        #expect(result.stdoutText == transcript)
        #expect(!FileManager.default.fileExists(atPath: result.temporaryDirectory.path))
    }

    @Test("Stdout is bounded without blocking the child")
    func stdoutLimit() async throws {
        let runner = try AgentProcessRunner(executable: .testSeq)
        let result = try await runner.run(.init(
            arguments: [.literal("1"), .literal("10000")],
            stdin: Data(),
            timeout: 2,
            stdoutLimit: 128,
            stderrLimit: 128
        ))

        #expect(result.stdoutWasTruncated)
        #expect(result.stdout.count == 128)
        #expect(result.stderr.count <= 128)
    }

    @Test("Timeout stops a hung child with a friendly runner error")
    func timeout() async throws {
        let runner = try AgentProcessRunner(executable: .testSleep)
        do {
            _ = try await runner.run(.init(
                arguments: [.literal("5")],
                stdin: Data(),
                timeout: 0.1
            ))
            Issue.record("Expected timeout")
        } catch let error as AgentProcessRunnerError {
            guard case .timedOut = error else {
                Issue.record("Unexpected runner error: \(error)")
                return
            }
            #expect(error.localizedDescription.contains("stopped"))
        }
    }

    @Test("Cancellation terminates the child")
    func cancellation() async throws {
        let runner = try AgentProcessRunner(executable: .testSleep)
        let task = Task {
            try await runner.run(.init(
                arguments: [.literal("5")],
                stdin: Data(),
                timeout: 10
            ))
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    @Test("Temporary output arguments cannot escape the scratch folder")
    func rejectsTraversal() async throws {
        let runner = try AgentProcessRunner(executable: .testCat)
        do {
            _ = try await runner.run(.init(
                arguments: [.temporaryFile("../answer.txt")],
                stdin: Data(),
                timeout: 1
            ))
            Issue.record("Expected unsafe path rejection")
        } catch let error as AgentProcessRunnerError {
            #expect(error == .invalidTemporaryFilename)
        }
    }

    @Test("Trusted input files are created inside scratch and traversal is rejected")
    func inputFilesAreScoped() async throws {
        let runner = try AgentProcessRunner(executable: .testCat)
        let result = try await runner.run(.init(
            arguments: [.literal(".cursor/cli.json")],
            stdin: Data(),
            timeout: 1,
            inputFiles: [".cursor/cli.json": Data("deny-policy".utf8)]
        ))
        #expect(result.stdoutText == "deny-policy")
        #expect(!FileManager.default.fileExists(atPath: result.temporaryDirectory.path))

        do {
            _ = try await runner.run(.init(
                arguments: [],
                stdin: Data(),
                timeout: 1,
                inputFiles: ["../cli.json": Data()]
            ))
            Issue.record("Expected unsafe input path rejection")
        } catch let error as AgentProcessRunnerError {
            #expect(error == .invalidTemporaryFilename)
        }
    }

    @Test("Removed tokens never reach the child environment")
    func stripsSensitiveEnvironment() async throws {
        let runner = try AgentProcessRunner(executable: .testEnv)
        let result = try await runner.run(.init(
            arguments: [],
            stdin: Data(),
            environment: ["OPENAI_API_KEY": "SECRET_TOKEN"],
            removingEnvironmentVariables: ["OPENAI_API_KEY"],
            timeout: 1
        ))

        #expect(!result.stdoutText.contains("SECRET_TOKEN"))
        #expect(!result.stdoutText.contains("OPENAI_API_KEY"))
    }

    @Test("Raw child diagnostics never escape through localized errors")
    func childOutputIsNotExposed() async throws {
        let runner = try AgentProcessRunner(executable: .testGrep)
        let sentinel = "PRIVATE_TRANSCRIPT_SENTINEL"
        do {
            _ = try await runner.run(.init(
                arguments: [.literal("needle"), .literal(sentinel)],
                stdin: Data(),
                timeout: 1
            ))
            Issue.record("Expected grep to fail for a missing file")
        } catch let error as AgentProcessRunnerError {
            #expect(!error.localizedDescription.contains(sentinel))
            #expect(error.localizedDescription.contains("status"))
        }
    }

    @Test("Concurrent requests use isolated scratch folders and stdin")
    func concurrentRequestsAreIsolated() async throws {
        let runner = try AgentProcessRunner(executable: .testCat)
        let outputs = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<12 {
                group.addTask {
                    let payload = "private-payload-\(index)"
                    let result = try await runner.run(.init(
                        arguments: [],
                        stdin: Data(payload.utf8),
                        timeout: 2
                    ))
                    #expect(!FileManager.default.fileExists(atPath: result.temporaryDirectory.path))
                    return result.stdoutText
                }
            }

            var values: [String] = []
            for try await value in group { values.append(value) }
            return values
        }

        #expect(Set(outputs) == Set((0..<12).map { "private-payload-\($0)" }))
    }
}
