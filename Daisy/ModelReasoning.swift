//
//  ModelReasoning.swift
//  Daisy
//
//  A reasoning model's thinking, taken off the front of its answer before
//  anything reads it (02.11.2026). TypeWhisper pasted 2,964 characters of a
//  model's reasoning for eight seconds of dictation (typewhisper-mac#1802);
//  here the answer is a JSON envelope, and `CloudSummaryDTO.decode` takes
//  the FIRST balanced object — so a model that drafts the JSON while it
//  thinks would hand over the draft from inside its thinking, and that
//  draft is what a Daisy-key command types into the person's field.
//
//  Thinking that comes in a field of its own (Ollama's `message.thinking`,
//  LM Studio's `reasoning_content`, Anthropic's `thinking` blocks) is never
//  read: every provider reads only the answer's text. This is for thinking
//  that arrives INSIDE the text — a chat template that doesn't honour
//  `think: false`, LM Studio with reasoning not separated, a CLI agent, a
//  gpt-oss reply whose channels weren't parsed.
//
//  Only thinking IN FRONT of the answer is taken: every format puts it
//  there, and a tag further on may be the person's own text (a selection
//  of code that mentions `<think>`). Thinking written as plain prose has
//  no marker to find; the length gates of each pass catch that one
//  (`RecordingSession.acceptsPolish`, `DaisyKeyCommandParser.fitsInsertion`).
//

import Foundation

nonisolated enum ModelReasoning {
    /// The tag pairs reasoning models wrap their thinking in: DeepSeek-R1,
    /// Qwen3, QwQ and most local models `<think>`; some fine-tunes
    /// `<thinking>` / `<reasoning>` / `<thought>`; Seed-OSS `<seed:think>`;
    /// Magistral `[THINK]`; Kimi `◁think▷`.
    static let tagPairs: [(open: String, close: String)] = [
        ("<think>", "</think>"),
        ("<thinking>", "</thinking>"),
        ("<reasoning>", "</reasoning>"),
        ("<thought>", "</thought>"),
        ("<seed:think>", "</seed:think>"),
        ("[THINK]", "[/THINK]"),
        ("◁think▷", "◁/think▷"),
    ]

    /// gpt-oss (harmony): the answer is the `final` channel; `analysis` is
    /// the thinking. Only a reply that STARTS with these tokens is read as
    /// channels — the same tokens inside an answer are its own text.
    static let harmonyFinal = "<|channel|>final<|message|>"
    static let harmonyStarts = ["<|channel|>", "<|start|>"]
    static let harmonyEnds = ["<|end|>", "<|return|>", "<|call|>"]

    /// The reply without the thinking in front of it, for a reply whose
    /// answer is the JSON envelope. Empty when there is nothing but
    /// thinking — cut off before it closed, or an `analysis` channel with
    /// no `final` — so the caller fails instead of using it.
    static func answer(from reply: String) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)

        // gpt-oss: the last final channel, up to its end token.
        if harmonyStarts.contains(where: { text.hasPrefix($0) }) {
            guard let final = text.range(of: harmonyFinal, options: .backwards) else { return "" }
            text = String(text[final.upperBound...])
            if let end = harmonyEnds.compactMap({ text.range(of: $0)?.lowerBound }).min() {
                text = String(text[..<end])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        text = withoutLeadingThinking(text)
        guard !opensAsAnswer(text) else { return text }

        // Thinking with no opener in front of it: the chat template put the
        // opener into the prompt (DeepSeek-R1, Qwen3 in thinking mode) and
        // the reply starts mid-thought, or a line of preamble came first.
        // It ends at a closer the answer follows directly — the envelope's
        // `{` or a fence. A closer followed by anything else is text, maybe
        // inside the answer's own string (code that mentions `</think>`).
        var cut: String.Index?
        for pair in tagPairs {
            var from = text.startIndex
            while let close = text.range(of: pair.close, options: .caseInsensitive, range: from..<text.endIndex) {
                if opensAsAnswer(text[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) {
                    if cut.map({ close.upperBound < $0 }) ?? true { cut = close.upperBound }
                    break
                }
                from = close.upperBound
            }
        }
        guard let cut else { return text }
        return String(text[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The answer's own text without thinking blocks in front of it — for
    /// the envelope's `clientFollowUp`, read by a pass that knows what it
    /// gave the model. A block whose opener is also in that `source` (the
    /// person's selection or dictation has a tag of its own) is the
    /// person's text and stays.
    static func withoutLeadingThinking(_ text: String, unlessIn source: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let (pair, opener) = leadingOpener(of: text) {
            if source.range(of: pair.open, options: .caseInsensitive) != nil { return text }
            guard let close = text.range(of: pair.close, options: .caseInsensitive,
                                         range: opener.upperBound..<text.endIndex) else {
                return ""
            }
            text = String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Blocks in front, one after another. One that never closes is all
    /// thinking — the generation stopped before the answer — and leaves
    /// nothing.
    static func withoutLeadingThinking(_ text: String) -> String {
        withoutLeadingThinking(text, unlessIn: "")
    }

    private static func opensAsAnswer(_ text: String) -> Bool {
        text.hasPrefix("{") || text.hasPrefix("```")
    }

    private static func leadingOpener(of text: String) -> ((open: String, close: String), Range<String.Index>)? {
        for pair in tagPairs {
            if let opener = text.range(of: pair.open, options: [.anchored, .caseInsensitive]) {
                return (pair, opener)
            }
        }
        return nil
    }
}
