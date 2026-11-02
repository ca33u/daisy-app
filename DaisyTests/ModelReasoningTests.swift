//
//  ModelReasoningTests.swift
//  DaisyTests
//
//  A reasoning model's thinking never reaches a field (02.11.2026).
//  TypeWhisper pasted 2,964 characters of reasoning for eight seconds of
//  dictation (typewhisper-mac#1802). Here: thinking in front of the answer
//  is taken off before the answer is read — including a JSON draft written
//  while thinking, which the first-balanced-object scan would otherwise
//  pick — and what has no tag to strip is stopped by the length gates.
//  The local providers are run for real against a stubbed server.
//

import Foundation
import Testing
@testable import Daisy

struct ModelReasoningTests {
    private let envelope = #"{"summary":"","sections":[],"actionItems":[],"clientFollowUp":"Перенесём созвон на четверг."}"#

    @Test("Thinking in front of the answer is taken off, a JSON draft inside it included")
    func leadingThinkWithDraft() throws {
        let reply = """
        <think>
        The user wants it polished. Draft: {"summary":"","sections":[],"actionItems":[],"clientFollowUp":"DRAFT from the thinking"}
        Hmm, shorter is better.
        </think>

        \(envelope)
        """
        let summary = try CloudSummaryDTO.decode(from: reply).toMeetingSummary()
        #expect(summary.clientFollowUp == "Перенесём созвон на четверг.")
    }

    @Test("Every tag the reasoning models use, in any case, one block after another")
    func everyTag() throws {
        for (open, close) in [("<THINK>", "</THINK>"), ("<thinking>", "</thinking>"), ("<reasoning>", "</reasoning>"),
                              ("<thought>", "</thought>"), ("<seed:think>", "</seed:think>"), ("[THINK]", "[/THINK]"),
                              ("◁think▷", "◁/think▷")] {
            let reply = "\(open)plan {\"clientFollowUp\":\"draft\"}\(close)\n<think>again</think>\(envelope)"
            #expect(try CloudSummaryDTO.decode(from: reply).toMeetingSummary().clientFollowUp == "Перенесём созвон на четверг.",
                    "\(open)")
        }
    }

    @Test("A reply that starts mid-thought (the template sent the opener) loses everything up to the closer")
    func templateOpener() throws {
        let reply = "Okay, so I should write {\"clientFollowUp\":\"draft\"} first.\n</think>\n\n\(envelope)"
        #expect(try CloudSummaryDTO.decode(from: reply).toMeetingSummary().clientFollowUp == "Перенесём созвон на четверг.")
    }

    @Test("Thinking cut off before it closed is no answer at all")
    func unclosedThinking() {
        #expect(ModelReasoning.answer(from: "<think>Let me draft {\"clientFollowUp\":\"draft\"} and") == "")
        #expect(throws: SummaryProviderError.self) {
            try CloudSummaryDTO.decode(from: "<think>Let me draft {\"clientFollowUp\":\"draft\"} and")
        }
    }

    @Test("gpt-oss: the final channel is the answer, analysis alone is none")
    func harmony() throws {
        let reply = "<|channel|>analysis<|message|>Draft {\"clientFollowUp\":\"draft\"}<|end|><|start|>assistant<|channel|>final<|message|>\(envelope)<|return|>"
        #expect(try CloudSummaryDTO.decode(from: reply).toMeetingSummary().clientFollowUp == "Перенесём созвон на четверг.")
        #expect(ModelReasoning.answer(from: "<|channel|>analysis<|message|>Still thinking {\"a\":1}") == "")
    }

    @Test("Thinking inside the answer's own text comes off its front, unless the person's text starts that way")
    func thinkingInsideTheValue() {
        let dictation = "перенесём на четверг, если всем удобно"
        #expect(ModelReasoning.withoutLeadingThinking("<think>They want it short.</think>\nПеренесём на четверг.", unlessIn: dictation)
                == "Перенесём на четверг.")
        #expect(ModelReasoning.withoutLeadingThinking("<think>They want it short, so", unlessIn: dictation) == "")
        // A selected prompt template that opens with its own tag stays whole.
        let template = "<thinking>\nConsider the user\n</thinking>\nAnswer briefly."
        #expect(ModelReasoning.withoutLeadingThinking("<thinking>\nConsider the user\n</thinking>\nAnswer briefly, please.",
                                                       unlessIn: "исправь опечатки\n\(template)")
                == "<thinking>\nConsider the user\n</thinking>\nAnswer briefly, please.")
    }

    @Test("A tag that is part of the answer stays: the person's code mentions it")
    func tagInTheAnswerStays() throws {
        let code = #"let answer = reply.replacingOccurrences(of: \"</think>\", with: \"\") // drop <think>"#
        let json = #"{"summary":"","sections":[],"actionItems":[],"clientFollowUp":""# + code + #""}"#
        for reply in [json, "Here's the edit:\n\(json)", "Here's the edit:\n```json\n\(json)\n```"] {
            let decoded = try CloudSummaryDTO.decode(from: reply).toMeetingSummary().clientFollowUp
            #expect(decoded.contains("</think>"), "\(reply.prefix(20))")
            #expect(decoded.contains("// drop <think>"))
        }
        // gpt-oss tokens inside an answer are its text, not channels.
        let harmonyInValue = #"{"summary":"","sections":[],"actionItems":[],"clientFollowUp":"split on <|channel|>final<|message|> here"}"#
        #expect(try CloudSummaryDTO.decode(from: harmonyInValue).toMeetingSummary().clientFollowUp
                == "split on <|channel|>final<|message|> here")
        #expect(ModelReasoning.withoutLeadingThinking("Use <think> tags carefully.") == "Use <think> tags carefully.")
    }

    @Test("A line of preamble, then thinking with a draft, then the answer")
    func preambleThenThinking() throws {
        let reply = "Sure.\n<think>Draft: {\"clientFollowUp\":\"draft\"}</think>\n\(envelope)"
        #expect(try CloudSummaryDTO.decode(from: reply).toMeetingSummary().clientFollowUp == "Перенесём созвон на четверг.")
    }

    @Test("A reply without thinking is untouched")
    func plainReply() throws {
        #expect(ModelReasoning.answer(from: "  \(envelope)\n") == envelope)
        #expect(try CloudSummaryDTO.decode(from: "```json\n\(envelope)\n```").toMeetingSummary().clientFollowUp
                == "Перенесём созвон на четверг.")
    }

    // MARK: - What no tag marks: the length gates

    @Test("Polish: 2,964 characters of prose reasoning for 85 in, or «Understood.» for 140, are refused")
    func polishGate() {
        let dictation = String(repeating: "а", count: 85)
        #expect(!RecordingSession.acceptsPolish(of: dictation, result: String(repeating: "x", count: 2_964)))
        #expect(!RecordingSession.acceptsPolish(of: String(repeating: "а", count: 140), result: "Understood."))
        #expect(RecordingSession.acceptsPolish(of: dictation, result: String(repeating: "б", count: 90)))
    }

    @Test("Daisy key: what eight seconds of speech can't have asked for is not typed into the field")
    func insertionBudget() {
        let reasoning = String(repeating: "Wait, looking at the vocabulary again. ", count: 76)  // 2,964
        #expect(reasoning.count == 2_964)
        #expect(!DaisyKeyCommandParser.fitsInsertion(reasoning, kind: .write, selection: nil, spokenSeconds: 8))
        // A letter written from one sentence fits.
        #expect(DaisyKeyCommandParser.fitsInsertion(String(repeating: "x", count: 1_100), kind: .write, selection: nil, spokenSeconds: 5))
        // An edit may grow its selection, as a polish may…
        let selection = String(repeating: "y", count: 1_000)
        #expect(DaisyKeyCommandParser.fitsInsertion(String(repeating: "x", count: 2_400), kind: .edit, selection: selection, spokenSeconds: 3))
        // …and the selection doesn't widen a write's budget.
        #expect(!DaisyKeyCommandParser.fitsInsertion(String(repeating: "x", count: 2_400), kind: .write, selection: selection, spokenSeconds: 3))
        // A prompt or a letter to a template is long by design.
        #expect(DaisyKeyCommandParser.fitsInsertion(String(repeating: "x", count: 2_400), kind: .write, selection: nil,
                                                    spokenSeconds: 4, longForm: true))
        #expect(!DaisyKeyCommandParser.fitsInsertion(String(repeating: "x", count: 2_400), kind: .write, selection: nil,
                                                     spokenSeconds: 4))
    }
}

// MARK: - The local providers, end to end

/// Serves one canned body to every request. Its own class, so it shares no
/// state with the other stubs in the target.
final class ReasoningReplyStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = ""

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct LocalReasoningProviderTests {
    private let draftThinking = #"The user said: перенесём на четверг. Draft: {"summary":"","sections":[],"actionItems":[],"clientFollowUp":"DRAFT"}"#
    private let answer = #"{"summary":"","sections":[],"actionItems":[],"clientFollowUp":"Перенесём на четверг."}"#

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReasoningReplyStub.self]
        return URLSession(configuration: config)
    }

    private func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    @Test("Ollama: thinking in the content or in its own field never reaches the polished text")
    func ollama() async throws {
        let launcher = OllamaLauncher(appURL: { nil }, open: { _ in }, pollEvery: .milliseconds(10))
        let summarizer = OllamaAPISummarizer(baseURL: URL(string: "http://127.0.0.1:11434")!, model: "deepseek-r1:8b",
                                             urlSession: session(), launcher: launcher)
        // A template that ignores `think: false` and inlines the thinking…
        ReasoningReplyStub.body = json(["message": ["role": "assistant", "content": "<think>\(draftThinking)</think>\n\(answer)"]])
        let dictation = "ну давай тогда перенесём созвон на четверг, если всем удобно"
        var summary = try await summarizer.summarize(transcript: dictation, title: "Dictation", localeHint: nil,
                                                     task: .dictationPolish(instruction: "Polish"))
        #expect(summary.clientFollowUp == "Перенесём на четверг.")
        // …and one that separates it.
        ReasoningReplyStub.body = json(["message": ["role": "assistant", "content": answer, "thinking": draftThinking]])
        summary = try await summarizer.summarize(transcript: dictation, title: "Dictation", localeHint: nil,
                                                 task: .dictationPolish(instruction: "Polish"))
        #expect(summary.clientFollowUp == "Перенесём на четверг.")
    }

    @Test("LM Studio: thinking inlined, opened by the template, or in reasoning_content never reaches a command's text")
    func lmStudio() async throws {
        let summarizer = LMStudioAPISummarizer(baseURL: URL(string: "http://127.0.0.1:1234")!, model: "qwen3-8b",
                                               urlSession: session())
        let context = VoiceCommandContext(role: .none, field: .messenger)
        // What the Daisy key sends: the request inside its payload.
        let payload = SummaryPrompt.voiceCommandPayload(request: "напиши, что перенесём на четверг", source: nil)
        for content in ["<think>\(draftThinking)</think>\n\(answer)", "\(draftThinking)\n</think>\n\n\(answer)"] {
            ReasoningReplyStub.body = json(["choices": [["message": ["role": "assistant", "content": content]]]])
            let summary = try await summarizer.summarize(transcript: payload, title: "Daisy",
                                                         localeHint: nil, task: .voiceCommand(context))
            #expect(DaisyKeyCommandParser.cleaned(summary.clientFollowUp, field: .messenger) == "Перенесём на четверг.")
        }
        ReasoningReplyStub.body = json(["choices": [["message": ["role": "assistant", "content": answer,
                                                                  "reasoning_content": draftThinking]]]])
        let summary = try await summarizer.summarize(transcript: payload, title: "Daisy",
                                                     localeHint: nil, task: .voiceCommand(context))
        #expect(summary.clientFollowUp == "Перенесём на четверг.")
    }
}
