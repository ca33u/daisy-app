//
//  Summarizer.swift
//  Daisy
//
//  Observable façade for the summarization pipeline. The UI talks to
//  exactly one Summarizer; it dispatches to the user-selected
//  SummaryProvider (Apple Intelligence / Anthropic / OpenAI) under the
//  hood. Keeps `lastSummary`, `isSummarizing`, `lastError`, and
//  `availability` reactive so the SwiftUI views update automatically.
//

import DaisyCore
import Foundation
import Observation
import os

/// Three-section meeting summary:
///  1. `summary` — what the meeting was about (the "встреча" section)
///  2. `actionItems` — block of next steps the participants will take
///  3. `clientFollowUp` — ready-to-send draft message a client or
///     partner could receive (separate from internal action items)
///
/// Older builds wrote `decisions` and `followUps` arrays into
/// `summary.json`; those keys are silently ignored by the current
/// decoder. The custom `init(from:)` also defaults `clientFollowUp`
/// to an empty string for legacy files that don't carry it yet —
/// the UI hides that section when empty.
///
/// Plain Codable struct on purpose — the FoundationModels-backed
/// AppleIntelligenceSummarizer wraps its OWN `@Generable` mirror
/// of these fields (which only compiles on macOS 26+) and converts
/// into this canonical type. Keeps the shared model
/// macOS-14-compatible.
nonisolated struct MeetingSummary: Codable, Sendable, Equatable {
    /// One-sentence elevator pitch — "what was this meeting about?".
    /// Rendered above the topical sections as the lede. For legacy
    /// summaries (written before sections shipped) this carries the
    /// full 2-4 sentence overview and `sections` is empty; UI falls
    /// back to rendering this as a plain paragraph.
    let summary: String

    /// Granola-style topical outline — 3-5 sections, each with a
    /// title and bulleted content (with optional sub-bullets, up to
    /// ~3 levels deep). Empty `[]` for legacy summaries written
    /// before this feature shipped; UI then falls back to rendering
    /// `summary` as a paragraph.
    let sections: [SummarySection]

    /// Imperative next steps with optional owner prefix
    /// (e.g. "Maria: send the contract by Thursday"). Kept as a
    /// flat array even after sections shipped — owners + dates are
    /// the actionable scan-target, sub-grouping under a section
    /// hides them.
    let actionItems: [String]

    /// Ready-to-send follow-up message a client / vendor / partner
    /// could receive. Empty string for purely internal team syncs.
    /// Kept as a Daisy-specific field on top of the Granola-style
    /// outline; useful for SMB workflows where the host hands the
    /// summary to a counterpart right after the call.
    let clientFollowUp: String

    /// A short name for the meeting, written by the model with the
    /// summary (03.10.2026). Replaces the session's title only while that
    /// title is still the app's own placeholder — see `MeetingTitle`.
    /// nil in files written before, and from providers that do not send it.
    var title: String? = nil

    // MARK: - Init

    init(
        summary: String,
        sections: [SummarySection] = [],
        actionItems: [String],
        clientFollowUp: String,
        title: String? = nil
    ) {
        self.summary = summary
        self.sections = sections
        self.actionItems = actionItems
        self.clientFollowUp = clientFollowUp
        self.title = title
    }

    /// Sentinel for a recording that captured no intelligible speech.
    /// Built WITHOUT calling the LLM (see `Summarizer.summarize`): empty
    /// outline / actions / follow-up, so the card shows one clean line and
    /// the follow-up plaque is suppressed — instead of the model
    /// fabricating an apologetic "the recording failed" summary plus a
    /// matching client follow-up (Egor, 2026-06-13).
    static let noSpeechCaptured = MeetingSummary(
        summary: String(localized: "No speech was captured in this recording — there's nothing to summarize."),
        sections: [],
        actionItems: [],
        clientFollowUp: ""
    )

    // MARK: - Codable

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.summary = try c.decode(String.self, forKey: .summary)
        // `sections` is new in 1.0.2 — older summary.json files on
        // disk don't carry it. Decode as optional, default to empty
        // array. UI's fallback path renders such legacy summaries as
        // a paragraph (the old behaviour) so users never see "no
        // content" on previously-saved sessions.
        self.sections = try c.decodeIfPresent([SummarySection].self, forKey: .sections) ?? []
        self.actionItems = try c.decodeIfPresent([String].self, forKey: .actionItems) ?? []
        self.clientFollowUp = try c.decodeIfPresent(String.self, forKey: .clientFollowUp) ?? ""
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(summary, forKey: .summary)
        try c.encode(sections, forKey: .sections)
        try c.encode(actionItems, forKey: .actionItems)
        try c.encode(clientFollowUp, forKey: .clientFollowUp)
        try c.encodeIfPresent(title, forKey: .title)
    }

    private enum CodingKeys: String, CodingKey {
        case summary, sections, actionItems, clientFollowUp, title
    }
}

/// One topical chunk of the Granola-style outline — a header plus a
/// list of bullets. Bullets can themselves carry sub-bullets, so the
/// section renders as an indented tree like the user's xAID.ai
/// reference. Section count + bullet count per section are not
/// enforced in the type — the prompt tells the model "3-5 sections,
/// 2-6 bullets each" and that's where the constraint lives.
nonisolated struct SummarySection: Codable, Sendable, Equatable {
    let title: String
    let bullets: [SummaryBullet]
}

/// Localised header strings for the summary UI (the Settings →
/// Test summary preview and the SessionDetailView outline). The
/// section CONTENT is localised by the LLM via the language
/// directive in the system prompt; the UI's own structural
/// headers ("Meeting" / "Next actions" / "Follow-up for client /
/// partner") need to match — otherwise a Russian summary lands
/// inside English structural labels, which reads inconsistently.
///
/// `for(language:)` accepts an ISO 639-1 two-letter code OR the
/// "auto" sentinel; unknown codes fall through to English (same
/// default that drives the prompt fallback). Add a case here
/// when adding a new `SummaryLanguage` enum case.
nonisolated struct SummaryLabels: Sendable {
    let meeting: String
    let nextActions: String
    let followUp: String

    static func `for`(language: String?) -> SummaryLabels {
        switch (language ?? "").lowercased() {
        case "ru":
            return SummaryLabels(
                meeting: "Встреча",
                nextActions: "Следующие шаги",
                followUp: "Ответ клиенту / партнёру"
            )
        case "uk":
            return SummaryLabels(
                meeting: "Зустріч",
                nextActions: "Наступні кроки",
                followUp: "Відповідь клієнту / партнеру"
            )
        case "pl":
            return SummaryLabels(
                meeting: "Spotkanie",
                nextActions: "Następne kroki",
                followUp: "Wiadomość do klienta / partnera"
            )
        case "es":
            return SummaryLabels(
                meeting: "Reunión",
                nextActions: "Próximas acciones",
                followUp: "Mensaje al cliente / socio"
            )
        case "fr":
            return SummaryLabels(
                meeting: "Réunion",
                nextActions: "Prochaines actions",
                followUp: "Message au client / partenaire"
            )
        case "de":
            return SummaryLabels(
                meeting: "Meeting",
                nextActions: "Nächste Schritte",
                followUp: "Nachricht an Kunden / Partner"
            )
        case "it":
            return SummaryLabels(
                meeting: "Riunione",
                nextActions: "Prossimi passi",
                followUp: "Messaggio al cliente / partner"
            )
        case "pt":
            return SummaryLabels(
                meeting: "Reunião",
                nextActions: "Próximas ações",
                followUp: "Mensagem para o cliente / parceiro"
            )
        case "ja":
            return SummaryLabels(
                meeting: "ミーティング",
                nextActions: "次のアクション",
                followUp: "クライアント／パートナー向けフォローアップ"
            )
        case "ko":
            return SummaryLabels(
                meeting: "회의",
                nextActions: "다음 단계",
                followUp: "클라이언트 / 파트너 후속 메시지"
            )
        case "zh":
            return SummaryLabels(
                meeting: "会议",
                nextActions: "后续行动",
                followUp: "给客户／合作伙伴的跟进"
            )
        default:
            return SummaryLabels(
                meeting: "Meeting",
                nextActions: "Next actions",
                followUp: "Follow-up for client / partner"
            )
        }
    }
}

/// Single bullet in the outline. Recursive: `children` are deeper
/// sub-bullets. Empty `[]` is the leaf case. Codable is automatic
/// via the synthesised init/encode; recursion works because Swift
/// supports indirect Codable for value types.
nonisolated struct SummaryBullet: Codable, Sendable, Equatable {
    let text: String
    let children: [SummaryBullet]

    init(text: String, children: [SummaryBullet] = []) {
        self.text = text
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try c.decode(String.self, forKey: .text)
        self.children = try c.decodeIfPresent([SummaryBullet].self, forKey: .children) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(children, forKey: .children)
    }

    private enum CodingKeys: String, CodingKey {
        case text, children
    }
}

@Observable
@MainActor
final class Summarizer {
    enum AvailabilityState: Equatable {
        case unknown
        case available
        case unavailable(String)
    }

    /// Shared instance — Summarizer holds the user's provider preference,
    /// API model selections, and the most recent result. Both Settings UI
    /// and RecordingSession bind to the same object.
    static let shared = Summarizer()

    // MARK: - Observable

    private(set) var availability: AvailabilityState = .unknown
    private(set) var isSummarizing = false
    private(set) var lastSummary: MeetingSummary?
    private(set) var lastError: String?

    /// Which provider is currently selected. Persisted to UserDefaults.
    /// Changing it triggers an availability re-check.
    var providerKind: SummaryProviderKind {
        didSet {
            guard oldValue != providerKind else { return }
            UserDefaults.standard.set(providerKind.rawValue, forKey: Self.kProvider)
            Task { await refreshAvailability() }
        }
    }

    /// Model ID selected per cloud provider (Anthropic / OpenAI).
    /// Apple Intelligence has no choice. Persisted independently so the
    /// user's pick survives switching providers back and forth.
    var anthropicModel: String {
        didSet { UserDefaults.standard.set(anthropicModel, forKey: Self.kAnthropicModel) }
    }
    var kimiModel: String {
        didSet { UserDefaults.standard.set(kimiModel, forKey: Self.kKimiModel) }
    }
    var geminiModel: String {
        didSet { UserDefaults.standard.set(geminiModel, forKey: Self.kGeminiModel) }
    }
    var openaiModel: String {
        didSet { UserDefaults.standard.set(openaiModel, forKey: Self.kOpenAIModel) }
    }
    /// OpenAI's API and account routes persist independently. The factory
    /// below intentionally keeps using the API route until the account
    /// client lands; adding this model must not alter existing behaviour.
    var openAIConnectionMethod: SummaryConnectionMethod {
        didSet {
            SummaryConnectionPreferences().setMethod(
                openAIConnectionMethod,
                for: .openAI
            )
            Task {
                if openAIConnectionMethod == .account {
                    await OpenAIAccountManager.shared.refreshStatus()
                }
                await refreshAvailability()
            }
        }
    }
    var openAIAccountModel: String {
        didSet {
            SummaryConnectionPreferences().setAccountModel(
                openAIAccountModel.isEmpty ? nil : openAIAccountModel,
                for: .openAI
            )
        }
    }
    var cursorModel: String {
        didSet {
            SummaryConnectionPreferences().setAccountModel(
                cursorModel.isEmpty ? nil : cursorModel,
                for: .cursor
            )
        }
    }
    var cursorAgentPath: String {
        didSet { UserDefaults.standard.set(cursorAgentPath, forKey: Self.kCursorAgentPath) }
    }
    /// Ollama model + base URL (build 40). Model is the tag the user
    /// has actually pulled (`ollama pull <name>`); base URL is the
    /// Ollama daemon endpoint (default 127.0.0.1:11434, overridable
    /// for users running Ollama on a non-default port).
    var ollamaModel: String {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: Self.kOllamaModel) }
    }
    var ollamaBaseURL: String {
        didSet { UserDefaults.standard.set(ollamaBaseURL, forKey: Self.kOllamaBaseURL) }
    }
    /// LM Studio model + base URL (build 40). Model id must match
    /// what's loaded in the LM Studio UI; base URL is the local-server
    /// endpoint (default 127.0.0.1:1234).
    var lmStudioModel: String {
        didSet { UserDefaults.standard.set(lmStudioModel, forKey: Self.kLMStudioModel) }
    }
    var lmStudioBaseURL: String {
        didSet { UserDefaults.standard.set(lmStudioBaseURL, forKey: Self.kLMStudioBaseURL) }
    }
    /// Which agent CLI drives the `.agentCLI` provider, and an optional
    /// absolute path for installs auto-detection can't find (a version
    /// manager, an unusual prefix). Empty path = auto-detect.
    var agentCLIKind: AgentCLIKind {
        didSet { UserDefaults.standard.set(agentCLIKind.rawValue, forKey: Self.kAgentCLIKind) }
    }
    var agentCLIPath: String {
        didSet { UserDefaults.standard.set(agentCLIPath, forKey: Self.kAgentCLIPath) }
    }

    // MARK: - Private

    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "Summarizer")

    private static let kProvider = "daisy.summaryProvider"
    private static let kAnthropicModel = "daisy.anthropicModel"
    private static let kOpenAIModel = "daisy.openaiModel"
    private static let kKimiModel = "daisy.kimiModel"
    private static let kGeminiModel = "daisy.geminiModel"
    private static let kOllamaModel = "daisy.ollamaModel"
    private static let kOllamaBaseURL = "daisy.ollamaBaseURL"
    private static let kAgentCLIKind = "daisy.agentCLIKind"
    private static let kAgentCLIPath = "daisy.agentCLIPath"
    private static let kCursorAgentPath = "daisy.cursorAgentPath"
    private static let kLMStudioModel = "daisy.lmStudioModel"
    private static let kLMStudioBaseURL = "daisy.lmStudioBaseURL"

    private init() {
        // Default to Apple Intelligence on macOS 26+ (where
        // FoundationModels is available). On macOS 14/15 fall back
        // to Anthropic as the default — it's the lowest-friction
        // path that doesn't require the user to discover the
        // unavailable Apple Intelligence option first.
        let defaultKind: SummaryProviderKind = {
            if #available(macOS 26.0, *) { return .appleIntelligence }
            return .anthropic
        }()
        let storedProvider = UserDefaults.standard.string(forKey: Self.kProvider)
            ?? defaultKind.rawValue
        self.providerKind = SummaryProviderKind(rawValue: storedProvider) ?? defaultKind

        self.anthropicModel = UserDefaults.standard.string(forKey: Self.kAnthropicModel)
            ?? AnthropicAPISummarizer.defaultModelID
        self.openaiModel = UserDefaults.standard.string(forKey: Self.kOpenAIModel)
            ?? OpenAIAPISummarizer.defaultModelID
        let connectionPreferences = SummaryConnectionPreferences()
        self.openAIConnectionMethod = connectionPreferences.method(for: .openAI)
        self.openAIAccountModel = connectionPreferences.accountModel(for: .openAI) ?? ""
        self.cursorModel = connectionPreferences.accountModel(for: .cursor)
            ?? CursorAgentService.defaultModelID
        self.cursorAgentPath = UserDefaults.standard.string(forKey: Self.kCursorAgentPath) ?? ""
        self.kimiModel = UserDefaults.standard.string(forKey: Self.kKimiModel)
            ?? KimiAPISummarizer.defaultModelID
        self.geminiModel = UserDefaults.standard.string(forKey: Self.kGeminiModel)
            ?? GeminiAPISummarizer.defaultModelID
        self.ollamaModel = UserDefaults.standard.string(forKey: Self.kOllamaModel)
            ?? OllamaAPISummarizer.defaultModelID
        self.ollamaBaseURL = UserDefaults.standard.string(forKey: Self.kOllamaBaseURL)
            ?? OllamaAPISummarizer.defaultBaseURLString
        self.lmStudioModel = UserDefaults.standard.string(forKey: Self.kLMStudioModel)
            ?? LMStudioAPISummarizer.defaultModelID
        self.lmStudioBaseURL = UserDefaults.standard.string(forKey: Self.kLMStudioBaseURL)
            ?? LMStudioAPISummarizer.defaultBaseURLString
        self.agentCLIKind = UserDefaults.standard.string(forKey: Self.kAgentCLIKind)
            .flatMap(AgentCLIKind.init(rawValue:)) ?? .codex
        self.agentCLIPath = UserDefaults.standard.string(forKey: Self.kAgentCLIPath) ?? ""

        Task { await refreshAvailability() }
    }

    // MARK: - Availability

    func refreshAvailability() async {
        let provider = makeProvider()
        let ready = await provider.isReady()
        if ready {
            availability = .available
        } else {
            availability = .unavailable(reasonForCurrent())
        }
    }

    private func reasonForCurrent() -> String {
        switch providerKind {
        case .appleIntelligence:
            // Prefer the SPECIFIC FoundationModels reason (not eligible /
            // not enabled / still downloading / same-language mismatch) so
            // the user sees exactly what to fix, not a generic catch-all.
            if #available(macOS 26.0, *),
               let reason = AppleIntelligenceSummarizer.currentUnavailabilityReason() {
                return reason
            }
            return "Apple Intelligence needs macOS 26 or later. Pick a cloud provider (Anthropic / OpenAI) in Settings → Summary instead."
        case .anthropic:
            return "Anthropic API key is missing. Add it in Settings → Summary Provider."
        case .openai:
            if openAIConnectionMethod == .account {
                return String(localized: "Connect your ChatGPT account in Settings → Summary.")
            }
            return "OpenAI API key is missing. Add it in Settings → Summary Provider."
        case .cursor:
            if CursorAgentService.resolveExecutable(override: cursorAgentPath) == nil {
                return String(localized: "Cursor Agent CLI isn't installed. Install `cursor-agent`, then return to Settings → Summary.")
            }
            return String(localized: "Cursor API key is missing. Add it in Settings → Summary Provider.")
        case .kimi:
            return "Kimi API key is missing. Add it in Settings → Summary Provider."
        case .gemini:
            return String(localized: "Gemini API key is missing. Add it in Settings → Summary Provider.")
        case .ollama:
            return "Couldn't reach Ollama at \(ollamaBaseURL). Open Terminal and run `ollama serve`, then pull a model with `ollama pull \(OllamaAPISummarizer.defaultModelID)`."
        case .lmStudio:
            return "Couldn't reach LM Studio at \(lmStudioBaseURL). Open the LM Studio app, load a model, then start the local server (Developer tab → Start)."
        case .mcp:
            return "MCP summarizer isn't configured. Open Settings → Summary → MCP and set the server URL, tool name, and arguments template."
        case .agentCLI:
            return "Daisy can't find the \(agentCLIKind.displayName) command. Install it and sign in (run it once in Terminal), or set its full path in Settings → Summary."
        }
    }

    // MARK: - Summarize

    /// Returns the produced summary on success, `nil` on failure.
    /// Side-effects (writing `lastSummary` / flipping `isSummarizing`) are
    /// preserved for legacy callers that observe the shared singleton —
    /// new code paths (e.g. RecordingSession's detached post-Stop task)
    /// prefer the return value to avoid a race when a second recording
    /// starts before the first summary lands.
    /// Replace the cached summary after a caller rewrote part of it — the
    /// voice pass over the follow-up is the only user today. Without this,
    /// `lastSummary` (which the UI and the auto-send stage read) would
    /// disagree with what was written to summary.json.
    func adopt(_ summary: MeetingSummary) {
        lastSummary = summary
    }

    @discardableResult
    func summarize(
        transcript: String,
        title: String,
        localeHint: String?,
        task: SummaryTask = .standard,
        /// `ProjectMemory`'s block for this meeting — the project's notes
        /// and what its earlier meetings came to. Goes in front of the
        /// transcript; the silence check below still judges the
        /// transcript alone.
        projectContext: String? = nil
    ) async -> MeetingSummary? {
        guard !transcript.isEmpty else { return nil }
        // No intelligible speech → don't hand a near-empty transcript to
        // the LLM (it fabricates an apologetic "recording failed" summary
        // and a client follow-up to match). Short-circuit to a clean
        // empty-state instead (Egor, 2026-06-13).
        if Self.isEffectivelySilent(transcript) {
            lastSummary = .noSpeechCaptured
            lastError = nil
            isSummarizing = false
            log.info("Skipped summary — transcript carried essentially no speech")
            return .noSpeechCaptured
        }
        isSummarizing = true
        lastError = nil

        let provider = makeProvider()
        do {
            let summary = try await summarizeWithPrivacy(
                provider: provider,
                transcript: ProjectMemory.prepending(projectContext, to: transcript),
                title: title,
                localeHint: localeHint,
                task: task
            )
            lastSummary = summary
            log.info("Summarized via \(self.providerKind.shortName, privacy: .public)")
            isSummarizing = false
            return summary
        } catch is CancellationError {
            // Benign: the caller withdrew (a new session started, a
            // deadline elapsed). Surfacing it would put "The operation
            // couldn't be completed. (Swift.CancellationError error 1.)"
            // in front of the user as if summarizing had failed.
            log.info("Summarize cancelled")
            lastError = nil
            isSummarizing = false
            return nil
        } catch {
            log.error("Summarize failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            isSummarizing = false
            return nil
        }
    }

    /// True when a transcript carries essentially no speech — a failed or
    /// silent capture. Counts word-like tokens (runs of 2+ letters); a
    /// real meeting, even ~20 seconds, has dozens, so the low threshold
    /// won't swallow short-but-real sessions. Bump it if silent captures
    /// still slip through with more garbled tokens.
    static func isEffectivelySilent(_ transcript: String) -> Bool {
        let words = transcript.split { !$0.isLetter }.filter { $0.count >= 2 }
        return words.count < 8
    }

    func clear() {
        lastSummary = nil
        lastError = nil
    }

    /// Isolated "dry run" — used by Settings → Test summary so the
    /// probe doesn't bleed into shared state. Does NOT touch
    /// `lastSummary`, `lastError`, or `isSummarizing`, so an
    /// in-flight real summary on the active session keeps its own
    /// state.
    ///
    /// Returns either the produced summary or a thrown error, so the
    /// caller can render its own one-shot preview without polluting
    /// the singleton.
    func runProbe(
        transcript: String,
        title: String,
        localeHint: String?,
        task: SummaryTask = .standard
    ) async throws -> MeetingSummary {
        let provider = makeProvider()
        return try await summarizeWithPrivacy(
            provider: provider,
            transcript: transcript,
            title: title,
            localeHint: localeHint,
            task: task
        )
    }

    /// One privacy boundary shared by normal summaries, Settings probes and
    /// every task routed through `SummaryProvider`. Detection runs off the
    /// MainActor; only aggregate counts are logged, never values or spans.
    private func summarizeWithPrivacy(
        provider: any SummaryProvider,
        transcript: String,
        title: String,
        localeHint: String?,
        task: SummaryTask
    ) async throws -> MeetingSummary {
        let enabled = AppSettings.protectSensitiveDataBeforeCloudAIEnabled
        let shouldProtect = SensitiveDataProtector.shouldProtect(
            enabled: enabled,
            providerIsLocal: providerIsEffectivelyLocal
        )
        guard shouldProtect else {
            return try await provider.summarize(
                transcript: transcript,
                title: title,
                localeHint: localeHint,
                task: task
            )
        }

        let protected = await Task.detached(priority: .userInitiated) {
            SensitiveDataProtector.protect(
                transcript: transcript,
                title: title,
                task: task
            )
        }.value
        log.info(
            "Cloud privacy filter prepared \(protected.report.distinctReplacements, privacy: .public) pseudonyms and \(protected.report.redactedOccurrences, privacy: .public) irreversible redactions"
        )
        let remoteSummary = try await provider.summarize(
            transcript: protected.transcript,
            title: protected.title,
            localeHint: localeHint,
            task: protected.task
        )
        return protected.restore(remoteSummary)
    }

    // MARK: - Factory

    /// Build a provider instance for the currently selected kind.
    /// Cheap to make — providers are structs/lightweight classes that
    /// hold no expensive state beyond URLSession references.
    ///
    /// MCP provider reads its config from UserDefaults directly so
    /// Summarizer stays AppSettings-agnostic. If the URL is missing
    /// or malformed we fall back to an UnavailableProvider that
    /// always fails — surfaces as a friendly error in the UI rather
    /// than a crash.
    /// True when the currently CONFIGURED provider endpoint keeps data on
    /// this Mac. `SummaryProviderKind.isLocal` alone LIES for
    /// .mcp/.ollama/.lmStudio — the user can point any of them at a
    /// remote host, and callers that auto-run generation "because the
    /// provider is local" (pre-meeting brief, morning brief, day card)
    /// would then ship past-session excerpts to an external server
    /// without the per-meeting consent tap. Always prefer this over
    /// `providerKind.isLocal` for privacy-gating decisions.
    var providerIsEffectivelyLocal: Bool {
        switch providerKind {
        case .appleIntelligence: return true
        case .anthropic, .openai, .cursor, .kimi, .gemini: return false
        case .ollama:
            return Self.isLoopbackURL(URL(string: ollamaBaseURL))
                && !OllamaAPISummarizer.isCloudModel(ollamaModel)
        case .lmStudio: return Self.isLoopbackURL(URL(string: lmStudioBaseURL))
        case .mcp:
            let s = UserDefaults.standard.string(forKey: "daisy.mcpSummarizer.url")
                ?? MCPSummarizer.defaultBaseURLString
            return Self.isLoopbackURL(URL(string: s))
        case .agentCLI:
            // The CLI runs locally; the model does not. Never local.
            return false
        }
    }

    /// Loopback check for provider endpoints. Conservative: an
    /// unparseable URL or missing host counts as NOT local.
    nonisolated static func isLoopbackURL(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    private func makeProvider() -> SummaryProvider {
        switch providerKind {
        case .appleIntelligence:
            // FoundationModels (Apple Intelligence's local LLM) is
            // macOS 26+ only. On Sonoma / Sequoia we surface a stub
            // that always reports unready, with a friendly error
            // message — same surface contract as the other
            // unavailable-config providers, so the UI doesn't need
            // version-conditional rendering paths.
            if #available(macOS 26.0, *) {
                return AppleIntelligenceSummarizer()
            }
            return UnavailableAppleIntelligenceProvider()
        case .anthropic:
            return AnthropicAPISummarizer(model: anthropicModel)
        case .openai:
            // Keep the established API adapter exactly as-is. Only the
            // explicit account selection routes through App Server.
            if openAIConnectionMethod == .account {
                return CodexAppServerSummarizer(
                    model: openAIAccountModel,
                    executableOverride: agentCLIPath
                )
            }
            return OpenAIAPISummarizer(model: openaiModel)
        case .cursor:
            return CursorAgentSummarizer(
                model: cursorModel,
                apiKey: KeychainStore.get(account: SecretKey.cursorAPIKey) ?? "",
                executableOverride: cursorAgentPath
            )
        case .kimi:
            return KimiAPISummarizer(model: kimiModel)
        case .gemini:
            return GeminiAPISummarizer(model: geminiModel)
        case .ollama:
            // Parse base URL with fallback to default if user typed
            // something malformed. Both adapters tolerate a missing
            // trailing slash — they `appendingPathComponent` rather
            // than string-concat.
            let url = URL(string: ollamaBaseURL)
                ?? URL(string: OllamaAPISummarizer.defaultBaseURLString)!
            return OllamaAPISummarizer(baseURL: url, model: ollamaModel)
        case .lmStudio:
            let url = URL(string: lmStudioBaseURL)
                ?? URL(string: LMStudioAPISummarizer.defaultBaseURLString)!
            return LMStudioAPISummarizer(baseURL: url, model: lmStudioModel)
        case .mcp:
            let defaults = UserDefaults.standard
            let urlString = defaults.string(forKey: "daisy.mcpSummarizer.url")
                ?? MCPSummarizer.defaultBaseURLString
            let toolName = defaults.string(forKey: "daisy.mcpSummarizer.toolName")
                ?? MCPSummarizer.defaultToolName
            let template = defaults.string(forKey: "daisy.mcpSummarizer.argsTemplate")
                ?? MCPSummarizer.defaultArgumentsTemplate
            guard let url = URL(string: urlString), url.scheme != nil else {
                return UnavailableMCPProvider(reason: "MCP server URL is empty or malformed: \"\(urlString)\"")
            }
            return MCPSummarizer(
                baseURL: url,
                toolName: toolName,
                argumentsTemplate: template
            )
        case .agentCLI:
            return AgentCLISummarizer(
                agent: agentCLIKind,
                executableOverride: agentCLIPath
            )
        }
    }
}

// MARK: - Fallback

/// Stub provider used when the .mcp config can't be parsed. Always
/// reports unready and throws a useful error on summarize — keeps
/// the surface area uniform so callers don't need switch coverage
/// for config errors.
private nonisolated struct UnavailableMCPProvider: SummaryProvider {
    let kind: SummaryProviderKind = .mcp
    let reason: String

    func isReady() async -> Bool { false }

    func summarize(transcript: String, title: String, localeHint: String?, task: SummaryTask) async throws -> MeetingSummary {
        throw SummaryProviderError.modelUnavailable(provider: "MCP", reason: reason)
    }
}

/// Stub provider used when the user has Apple Intelligence selected
/// but they're running macOS 14/15 (FoundationModels framework
/// doesn't exist). Tells them what to do next — pick another
/// provider — without crashing or pretending it works.
private nonisolated struct UnavailableAppleIntelligenceProvider: SummaryProvider {
    let kind: SummaryProviderKind = .appleIntelligence

    func isReady() async -> Bool { false }

    func summarize(transcript: String, title: String, localeHint: String?, task: SummaryTask) async throws -> MeetingSummary {
        throw SummaryProviderError.modelUnavailable(
            provider: "Apple Intelligence",
            reason: "Apple Intelligence summaries require macOS 26 (Tahoe) or newer. Open Settings → Summary and pick Anthropic, OpenAI, or your local MCP server instead."
        )
    }
}
