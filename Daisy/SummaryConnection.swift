// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
//
//  SummaryConnection.swift
//  Daisy
//
//  Shared connection model for summary providers. API-key settings and
//  account settings deliberately use separate keys so switching routes
//  never deletes credentials or silently changes the API model.
//

import Foundation

nonisolated enum SummaryConnectionMethod: String, Codable, CaseIterable, Sendable {
    case apiKey
    case account
}

/// Stable provider identifiers for connection preferences. This is kept
/// separate from `SummaryProviderKind`: Copilot can have account settings
/// before its summary adapter becomes a selectable provider.
nonisolated enum SummaryConnectionProvider: String, Codable, CaseIterable, Sendable {
    case openAI = "openai"
    case anthropic
    case kimi
    case cursor
    case githubCopilot

    nonisolated var supportedMethods: [SummaryConnectionMethod] {
        switch self {
        case .openAI:
            return [.apiKey, .account]
        case .githubCopilot:
            return [.account]
        case .anthropic, .kimi, .cursor:
            return [.apiKey]
        }
    }

    nonisolated var defaultMethod: SummaryConnectionMethod {
        supportedMethods.first ?? .apiKey
    }
}

/// UserDefaults-backed storage with injectable defaults for migration tests.
/// A missing OpenAI value intentionally resolves to `.apiKey`, preserving the
/// behaviour of every install that predates account connections.
nonisolated struct SummaryConnectionPreferences: @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func method(for provider: SummaryConnectionProvider) -> SummaryConnectionMethod {
        guard provider.supportedMethods.count > 1,
              let raw = defaults.string(forKey: Self.methodKey(for: provider)),
              let stored = SummaryConnectionMethod(rawValue: raw),
              provider.supportedMethods.contains(stored)
        else {
            return provider.defaultMethod
        }
        return stored
    }

    func setMethod(_ method: SummaryConnectionMethod, for provider: SummaryConnectionProvider) {
        guard provider.supportedMethods.contains(method) else { return }
        defaults.set(method.rawValue, forKey: Self.methodKey(for: provider))
    }

    func accountModel(for provider: SummaryConnectionProvider) -> String? {
        defaults.string(forKey: Self.accountModelKey(for: provider))
    }

    func setAccountModel(_ model: String?, for provider: SummaryConnectionProvider) {
        let key = Self.accountModelKey(for: provider)
        if let model, !model.isEmpty {
            defaults.set(model, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func hasAcknowledgedCloudDisclosure(for provider: SummaryConnectionProvider) -> Bool {
        defaults.bool(forKey: Self.cloudDisclosureKey(for: provider))
    }

    func acknowledgeCloudDisclosure(for provider: SummaryConnectionProvider) {
        defaults.set(true, forKey: Self.cloudDisclosureKey(for: provider))
    }

    static func methodKey(for provider: SummaryConnectionProvider) -> String {
        "daisy.summaryConnection.\(provider.rawValue).method"
    }

    static func accountModelKey(for provider: SummaryConnectionProvider) -> String {
        "daisy.summaryConnection.\(provider.rawValue).accountModel"
    }

    static func cloudDisclosureKey(for provider: SummaryConnectionProvider) -> String {
        "daisy.summaryConnection.\(provider.rawValue).accountCloudDisclosureAcknowledged"
    }
}

nonisolated struct SummaryAccount: Equatable, Sendable {
    let id: String?
    let email: String?
    let displayName: String?
    let plan: String?
}

nonisolated struct SummaryAccountModel: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let isDefault: Bool

    init(id: String, displayName: String, isDefault: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.isDefault = isDefault
    }
}

/// Provider-neutral state shown by the reusable account connection UI.
nonisolated enum SummaryAccountState: Equatable, Sendable {
    case notInstalled
    case signedOut
    case connecting
    case connected(SummaryAccount)
    case sessionExpired
    case limitReached(resetAt: Date?)
    case failed(message: String)
}

/// Common account authorization surface. Implementations own provider-
/// specific OAuth and process protocols; UI and summary routing only depend
/// on this contract.
@MainActor
protocol SummaryAccountManaging: AnyObject {
    var accountState: SummaryAccountState { get }
    var availableModels: [SummaryAccountModel] { get }

    func connect() async
    func disconnect() async
    func refreshStatus() async
}
