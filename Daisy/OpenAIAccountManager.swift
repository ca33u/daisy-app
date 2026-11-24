//
//  OpenAIAccountManager.swift
//  Daisy
//
//  Observable ChatGPT-account state for Settings. Credentials remain owned
//  by Codex; Daisy receives only display metadata and never reads auth files.
//

import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class OpenAIAccountManager: SummaryAccountManaging {
    static let shared = OpenAIAccountManager()

    private(set) var accountState: SummaryAccountState = .signedOut
    private(set) var availableModels: [SummaryAccountModel] = []
    private(set) var account: SummaryAccount?
    private(set) var rateLimit: CodexRateLimitInfo?

    @ObservationIgnored
    private let service: any CodexAppServerServing
    @ObservationIgnored
    private let executableAvailable: @Sendable (String) -> Bool

    init(
        service: any CodexAppServerServing = CodexAppServerService.shared,
        executableAvailable: @escaping @Sendable (String) -> Bool = {
            CodexAppServerService.resolveExecutable(override: $0) != nil
        }
    ) {
        self.service = service
        self.executableAvailable = executableAvailable
    }

    var defaultModelID: String? {
        availableModels.first(where: \.isDefault)?.id ?? availableModels.first?.id
    }

    var isConnected: Bool {
        if case .connected = accountState { return true }
        return false
    }

    func connect() async {
        guard executableAvailable(executableOverride) else {
            accountState = .notInstalled
            return
        }
        accountState = .connecting
        do {
            let attempt = try await service.beginLogin(executableOverride: executableOverride)
            guard NSWorkspace.shared.open(attempt.authorizationURL) else {
                throw CodexAppServerError.authorizationFailed
            }
            try await service.awaitLogin(attempt, executableOverride: executableOverride)
            await refreshStatus()
        } catch is CancellationError {
            accountState = .signedOut
        } catch {
            apply(error)
        }
    }

    func disconnect() async {
        do { try await service.logout(executableOverride: executableOverride) }
        catch {
            apply(error)
            return
        }
        account = nil
        rateLimit = nil
        availableModels = []
        accountState = .signedOut
    }

    func refreshStatus() async {
        guard executableAvailable(executableOverride) else {
            account = nil
            rateLimit = nil
            availableModels = []
            accountState = .notInstalled
            return
        }

        do {
            guard let info = try await service.account(executableOverride: executableOverride) else {
                account = nil
                rateLimit = nil
                availableModels = []
                accountState = .signedOut
                return
            }
            guard info.type == "chatgpt" else {
                account = nil
                rateLimit = nil
                availableModels = []
                accountState = .failed(message: String(localized: "Codex is using an API key. Sign out of Codex, then connect a ChatGPT account."))
                return
            }

            let summaryAccount = SummaryAccount(
                id: info.email,
                email: info.email,
                displayName: nil,
                plan: info.plan
            )
            account = summaryAccount

            async let modelsRequest = service.models(executableOverride: executableOverride)
            async let limitsRequest = service.rateLimits(executableOverride: executableOverride)
            let modelInfo = try await modelsRequest
            let limitInfo = try await limitsRequest
            availableModels = modelInfo.map {
                SummaryAccountModel(
                    id: $0.id,
                    displayName: $0.displayName,
                    isDefault: $0.isDefault
                )
            }
            rateLimit = limitInfo
            if let limitInfo, limitInfo.isReached {
                accountState = .limitReached(resetAt: limitInfo.resetsAt)
            } else {
                accountState = .connected(summaryAccount)
            }
        } catch {
            apply(error)
        }
    }

    private var executableOverride: String {
        UserDefaults.standard.string(forKey: "daisy.agentCLIPath") ?? ""
    }

    private func apply(_ error: Error) {
        if let codex = error as? CodexAppServerError {
            switch codex {
            case .notInstalled:
                accountState = .notInstalled
            case .authorizationFailed:
                accountState = .signedOut
            case .sessionExpired:
                accountState = .sessionExpired
            default:
                accountState = .failed(message: codex.localizedDescription)
            }
        } else {
            accountState = .failed(message: String(localized: "Couldn't refresh the ChatGPT account. Try again."))
        }
    }
}
