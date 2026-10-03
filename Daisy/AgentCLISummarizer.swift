//
//  AgentCLISummarizer.swift
//  Daisy
//
//  Summaries through the Codex CLI the user already has signed in. No
//  API key: Codex authenticates with the user's own ChatGPT
//  subscription, and the request counts against that plan's limits.
//
//  WHY THERE IS NO CLAUDE CODE OPTION HERE, AND WHY IT MUST NOT BE
//  ADDED BACK. The first version of this file drove `claude -p` too.
//  That is not permitted. Anthropic's Claude Code legal page is
//  explicit: OAuth authentication "is intended exclusively ... to
//  support ordinary use of Claude Code and other native Anthropic
//  applications", and "Anthropic does not permit third-party developers
//  to offer Claude.ai login or to route requests through Free, Pro, or
//  Max plan credentials on behalf of their users" — adding that
//  "Anthropic reserves the right to take measures to enforce these
//  restrictions and may do so without prior notice."
//  (https://code.claude.com/docs/en/legal-and-compliance)
//
//  Daisy is a third-party product, publicly distributed. Shelling out to
//  a CLI the user installed themselves does not change what the request
//  IS: Daisy routing a summary through that user's Pro/Max credentials.
//  For Claude the supported routes are an API key (which Daisy already
//  offers as its own provider), a local model, or a written agreement
//  with Anthropic. If someone wants Claude-without-a-key later, the
//  honest shape is "open this transcript in Claude" — prepare the
//  prompt, hand it over, let the user paste the answer back — not an
//  automated round trip on subscription credentials.
//
//  WHY A SUBPROCESS AND NOT MCP. The elegant version of this is MCP
//  sampling: Daisy's MCP server asks the connected client (Claude
//  Desktop) to run the completion on the user's subscription. The
//  protocol has `sampling/createMessage` for exactly this — but Claude
//  Desktop has never implemented sampling, so the call has nobody to
//  answer it (and for Claude it would be barred anyway, per above).
//  Codex ships a documented non-interactive mode. So: a subprocess. (Daisy is not sandboxed — see Daisy.entitlements —
//  so it can spawn one; `MCPSummarizer` stayed HTTP-only for that
//  reason. No extra entitlement is needed to exec a separate binary.)
//
//  FIVE THINGS THIS FILE IS CAREFUL ABOUT.
//
//  1. BILLING IS NOT GUARANTEED TO BE FREE, and Daisy must never imply
//     it is. Headless agent runs have open reports of billing as
//     metered API usage when the account also has API access — one user
//     reported four figures in two days. The settings copy says to check
//     usage after the first run. We do not promise "free", and we record
//     nothing to TokenLedger because the agent reports no usage we can
//     price.
//
//  2. THIS IS AN AGENT, NOT A MODEL. Left alone, Codex can read files
//     and run commands, so every run happens in an empty temporary
//     directory with read-only sandboxing. If the installed version cannot
//     prove that capability, Daisy refuses to run it. Containment is not
//     total either way:
//     HOME is inherited, because that's where the CLI keeps the
//     credentials this whole feature depends on, so user-scope config
//     still loads.
//
//  3. THE TRANSCRIPT LEAVES THE MAC. It goes to OpenAI under the user's
//     own account. No worse than the API-key
//     providers, but not local — `privacyTag` says so plainly. The
//     request being relayed by an app on the user's own machine must not
//     read as "stays on my Mac".
//
//  4. A GUI APP'S ENVIRONMENT IS NOT A TERMINAL'S. Launched from Finder,
//     Daisy inherits `PATH=/usr/bin:/bin:/usr/sbin:/sbin` — no Homebrew,
//     no `~/.local/bin`. A CLI installed through a package manager can be
//     a shim that execs its own runtime, so finding the shim isn't
//     enough: the CHILD needs a PATH that can find that runtime, or it
//     dies with exit 127. That is the single likeliest way this feature
//     would "work in Terminal, do nothing in Daisy".
//
//  5. WE ASK THE BINARY WHAT IT SUPPORTS INSTEAD OF GUESSING. Flag names
//     here are not hardcoded from documentation — the first run reads the
//     installed CLI's `--help` and every optional flag is used only if it
//     appears there. This is not neatness: an unsupported flag makes the
//     CLI exit with a usage error, so guessing turns a version mismatch
//     into a 100%-failure feature. Two of the flags in the first draft of
//     this file WERE wrong, taken from docs that didn't match the shipped
//     binaries. The probe is cached per binary path for the process
//     lifetime, and a failed probe blocks the run with an update message.
//

import Foundation

/// Which agent CLI to drive. A single case today (see the header for why
/// Claude Code isn't one of them) but kept as an enum: the settings key
/// already persists it, and the next permitted agent should be an added
/// case rather than a rewrite.
nonisolated enum AgentCLIKind: String, Codable, CaseIterable, Sendable {
    case codex

    var displayName: String {
        switch self {
        case .codex: return String(localized: "Codex")
        }
    }

    /// Executable name as found on `PATH`.
    var executableName: String {
        switch self {
        case .codex: return "codex"
        }
    }

    /// Where first-party apps and common installers put the binary.
    /// Resolution is intentionally path-only: executing a login shell just
    /// to find a client would violate the runner's no-shell boundary.
    var likelyPaths: [String] {
        let home = NSHomeDirectory()
        switch self {
        case .codex:
            return [
                // The ChatGPT app moved its helper into `codex-cli/CodexCLI.app`
                // (seen 03.10.2026): Daisy said «Codex не найден» on a Mac
                // that had it. Newest layout first, the old one kept; the real binary, not the `bin/codex` shell wrapper beside it — the runner starts no shell.
                "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                "\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                "\(home)/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                "/Applications/Codex.app/Contents/Resources/codex",
                "\(home)/Applications/ChatGPT.app/Contents/Resources/codex",
                "\(home)/Applications/Codex.app/Contents/Resources/codex",
                "\(home)/.local/bin/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
            ]
        }
    }

    /// The subcommand that runs one non-interactive completion, if the
    /// CLI has one.
    var subcommand: String? {
        switch self {
        case .codex: return "exec"
        }
    }

    /// Arguments built from what the INSTALLED binary says it supports,
    /// rather than from flag names hardcoded here.
    ///
    /// Every optional flag is gated on `help.has(...)`. The point is not
    /// tidiness — it's that this file integrates with someone else's CLI
    /// across versions we can't see, and a flag that doesn't exist makes
    /// the whole run exit with a usage error. Guessing gets the feature a
    /// 100%-failure mode; asking gets it a graceful one. (Two flags were
    /// already wrong when they were guessed from documentation.)
    ///
    /// What each optional flag buys, in the order we care:
    ///  • tool restriction — this is a summarizer, not a file-read
    ///    primitive. If the flag is missing we still run, and say so in
    ///    the log rather than pretending the agent is contained.
    ///  • `--skip-git-repo-check` — Codex refuses to start outside a Git
    ///    repo, and our scratch dir is a bare temp folder.
    ///  • `-o/--output-last-message` — writes just the final answer to a
    ///    file, keeping us off a progress log.
    ///  • sandbox / output format — nice to have, not load-bearing.
    func arguments(help: AgentCLIHelp) -> [AgentProcessRunner.Argument] {
        var args: [AgentProcessRunner.Argument] = []
        if let subcommand { args.append(.literal(subcommand)) }

        switch self {
        case .codex:
            if help.has("--skip-git-repo-check") {
                args.append(.literal("--skip-git-repo-check"))
            }
            if help.has("--sandbox") {
                args += [.literal("--sandbox"), .literal("read-only")]
            }
            if help.has("--output-last-message") {
                args += [.literal("--output-last-message"), .temporaryFile("answer.txt")]
            }
            // Positional `-` = read the prompt from stdin.
            args.append(.literal("-"))
        }
        return args
    }

    /// Whether the answer will be in `lastMessageFile` — only when the
    /// installed binary actually accepted the flag that writes it.
    func readsAnswerFromFile(help: AgentCLIHelp) -> Bool {
        help.has("--output-last-message")
    }

}

/// What the installed binary's `--help` says it accepts.
///
/// Deliberately dumb: a substring match over the help text. Parsing
/// option grammars properly would be a project, and the question we ask
/// is narrow — "does the literal string `--skip-git-repo-check` appear
/// in this binary's help?" — where a substring is exactly right.
nonisolated struct AgentCLIHelp: Sendable {
    private let text: String

    init(text: String) { self.text = text }

    /// Empty help (the probe failed) reports every flag as absent. The
    /// caller refuses to run because safe containment cannot be proven.
    static let unknown = AgentCLIHelp(text: "")

    func has(_ flag: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.contains(flag)
    }

    var isEmpty: Bool { text.isEmpty }
}

nonisolated struct AgentCLISummarizer: SummaryProvider {
    let kind: SummaryProviderKind = .agentCLI

    let agent: AgentCLIKind
    /// User-supplied absolute path, when auto-detection can't find the
    /// binary (a version manager, an unusual prefix). Empty = auto.
    let executableOverride: String

    /// Generous: the agent boots a runtime, authenticates, and may
    /// retry — and a long meeting is a big prompt. Still bounded, so a
    /// hung agent can't wedge the finalize pipeline.
    private static let timeout: TimeInterval = 180
    private static let helpProbeTimeout: TimeInterval = 3

    init(agent: AgentCLIKind, executableOverride: String = "") {
        self.agent = agent
        self.executableOverride = executableOverride
    }

    // MARK: - Locating the binary

    /// Resolve the executable from a known path, or `nil` when it isn't
    /// installed where Daisy can safely see it. No shell is invoked.
    func resolvedExecutable() -> String? {
        let fm = FileManager.default
        let override = executableOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            let url = URL(fileURLWithPath: override).standardizedFileURL
            return url.lastPathComponent == agent.executableName
                && fm.isExecutableFile(atPath: url.path) ? url.path : nil
        }
        for path in agent.likelyPaths where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// `Task.detached` because the lookup blocks and, under this
    /// target's approachable-concurrency setting, a `nonisolated async`
    /// func would otherwise inherit the CALLER's isolation — and the
    /// caller (`Summarizer.refreshAvailability`) is `@MainActor`. That
    /// keeps filesystem checks off the main thread at launch.
    func isReady() async -> Bool {
        let probe = self
        guard let executable = await Task.detached(priority: .utility, operation: {
            probe.resolvedExecutable()
        }).value else { return false }
        let help = await Self.probeHelp(executable: executable, subcommand: agent.subcommand)
        return help.has("--sandbox") && help.has("--skip-git-repo-check")
    }

    // MARK: - Capability probe

    /// `--help` output per (binary path + subcommand), cached for the
    /// process lifetime. The probe is a subprocess; running it before
    /// every summary would add a spawn to each one for an answer that
    /// only changes when the user upgrades the CLI.
    private static let helpCache = HelpCache()

    /// Ask the installed binary what it supports. Bounded and
    /// failure-tolerant: on any error we return `.unknown`; the caller then
    /// refuses to start because it cannot prove the required containment.
    private static func probeHelp(executable: String, subcommand: String?) async -> AgentCLIHelp {
        let key = "\(executable)|\(subcommand ?? "")"
        if let cached = helpCache.value(for: key) { return cached }

        let help: AgentCLIHelp = await Task.detached(priority: .utility) {
            let runner: AgentProcessRunner
            do {
                runner = try AgentProcessRunner(
                    executable: .codex(URL(fileURLWithPath: executable))
                )
            } catch {
                return .unknown
            }

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = childPath(for: executable)
            let args = (subcommand.map { [AgentProcessRunner.Argument.literal($0)] } ?? [])
                + [.literal("--help")]
            let request = AgentProcessRunner.Request(
                arguments: args,
                stdin: Data(),
                environment: env,
                timeout: helpProbeTimeout,
                stdoutLimit: 64 * 1_024,
                stderrLimit: 64 * 1_024
            )
            guard let result = try? await runner.run(request) else {
                return .unknown
            }
            // Some clients print help to stderr.
            let text = result.stdoutText + "\n" + result.stderrText
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .unknown
            }
            return AgentCLIHelp(text: text)
        }.value

        if !help.isEmpty { helpCache.store(help, for: key) }
        return help
    }

    /// Tiny lock-guarded cache. A `final class` because the summarizer is
    /// a struct recreated per call — the cache has to outlive it.
    private final class HelpCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: AgentCLIHelp] = [:]

        func value(for key: String) -> AgentCLIHelp? {
            lock.lock(); defer { lock.unlock() }
            return entries[key]
        }

        func store(_ help: AgentCLIHelp, for key: String) {
            lock.lock(); entries[key] = help; lock.unlock()
        }
    }

    /// PATH for the CHILD. The resolved binary's own directory first (a
    /// version manager's shim lives next to its runtime), then the usual
    /// install prefixes, then the system default.
    private static func childPath(for executable: String) -> String {
        var parts = [URL(fileURLWithPath: executable).deletingLastPathComponent().path]
        let home = NSHomeDirectory()
        parts += [
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        if let inherited = ProcessInfo.processInfo.environment["PATH"], !inherited.isEmpty {
            parts.append(inherited)
        }
        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    // MARK: - Summarize

    func summarize(
        transcript: String,
        title: String,
        localeHint: String?,
        task: SummaryTask
    ) async throws -> MeetingSummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 40 else {
            throw SummaryProviderError.transcriptTooShort
        }
        let executable = await Task.detached(priority: .userInitiated) { [self] in
            resolvedExecutable()
        }.value
        guard let executable else {
            throw SummaryProviderError.modelUnavailable(
                provider: agent.displayName,
                reason: String(localized: "Not installed, or Daisy can’t see it. Install the CLI and sign in, or set its path in Settings → Summary.")
            )
        }

        // Same prompt every other provider gets — the agent is just a
        // different pipe to a model, so the summary shape stays
        // identical across providers.
        let system = SummaryPrompt.systemInstructions(localeHint: localeHint, task: task)
        let user = SummaryPrompt.userPrompt(title: title, transcript: trimmed, task: task)
        let prompt = system + "\n\n" + user

        // Ask the installed binary what it accepts before building the
        // command line. Running without both containment flags is refused:
        // an account-backed summarizer must never silently become a general
        // filesystem agent because an older client happens to be installed.
        let help = await Self.probeHelp(executable: executable, subcommand: agent.subcommand)
        guard help.has("--sandbox"), help.has("--skip-git-repo-check") else {
            throw SummaryProviderError.modelUnavailable(
                provider: agent.displayName,
                reason: String(localized: "This installed client can’t prove a safe read-only mode. Update it before using account summaries.")
            )
        }

        let output = try await run(executable: executable, prompt: prompt, help: help)
        return try parse(output)
    }

    /// Spawn the known client through the shared constrained runner. The
    /// runner owns stdin piping, the empty 0700 scratch directory, output
    /// bounds, timeout, cancellation, and cleanup.
    private func run(executable: String, prompt: String, help: AgentCLIHelp) async throws -> String {
        let runner: AgentProcessRunner
        do {
            runner = try AgentProcessRunner(
                executable: .codex(URL(fileURLWithPath: executable))
            )
        } catch {
            throw SummaryProviderError.modelUnavailable(
                provider: agent.displayName,
                reason: error.localizedDescription
            )
        }

        // Inherit the environment (HOME is where the CLI keeps its
        // credentials) but fix PATH, and strip API keys: with one
        // present, the agents prefer metered API billing over the
        // subscription the user picked this provider to use.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.childPath(for: executable)
        // `CODEX_API_KEY` is honoured specifically by `codex exec`, and
        // `OPENAI_API_KEY` flips Codex to metered API billing — both
        // defeat the one thing this provider is for.
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY"] {
            env.removeValue(forKey: key)
        }

        let request = AgentProcessRunner.Request(
            arguments: agent.arguments(help: help),
            stdin: Data(prompt.utf8),
            environment: env,
            removingEnvironmentVariables: ["OPENAI_API_KEY", "CODEX_API_KEY"],
            timeout: Self.timeout,
            outputFiles: agent.readsAnswerFromFile(help: help) ? ["answer.txt"] : []
        )

        do {
            let result = try await runner.run(request)
            if agent.readsAnswerFromFile(help: help),
               let data = result.outputFiles["answer.txt"] {
                let answer = String(decoding: data, as: UTF8.self)
                if !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return answer
                }
            }
            return result.stdoutText
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Do not log the child output: clients can echo a prompt, and a
            // transcript must never enter Daisy's logs.
            throw SummaryProviderError.modelUnavailable(
                provider: agent.displayName,
                reason: error.localizedDescription
            )
        }
    }

    // MARK: - Response parsing

    /// The agents wrap the answer in whatever prose they feel like, so
    /// `CloudSummaryDTO.decode` (which already tolerates fenced blocks
    /// and surrounding text — every cloud provider needs that) does the
    /// work.
    private func parse(_ text: String) throws -> MeetingSummary {
        do {
            return try CloudSummaryDTO.decode(from: text).toMeetingSummary()
        } catch {
            throw SummaryProviderError.parseFailed(
                provider: agent.displayName,
                message: error.localizedDescription
            )
        }
    }
}
