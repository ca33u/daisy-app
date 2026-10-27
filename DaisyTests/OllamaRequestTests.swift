import Foundation
import Testing
@testable import Daisy

/// Field report 27.10: «Couldn't reach Ollama … (request timed out)» while
/// Ollama answered every probe. qwen3.5:4b on an M4 Air read the prompt at
/// ~130 tokens/s, wrote at ~13, and thought ~1,400 tokens before the JSON;
/// the request gave up at a flat 180 s and the error blamed `ollama serve`.
@MainActor
@Suite("Ollama summary request")
struct OllamaRequestTests {
    @Test("The summary asks for JSON with thinking off")
    func thinkingOff() throws {
        let body = OllamaAPISummarizer.chatBody(model: "qwen3.5:4b", system: "s", user: "u", numCtx: 16_384, thinkingOff: true)
        #expect(body["think"] as? Bool == false)
        #expect(body["format"] as? String == "json")
        #expect(body["stream"] as? Bool == false)
        let options = try #require(body["options"] as? [String: Any])
        #expect(options["num_ctx"] as? Int == 16_384)
        #expect(options["num_predict"] as? Int == 4_096)
    }

    @Test("thinkingOff: false leaves the field out")
    func fieldOptional() {
        let body = OllamaAPISummarizer.chatBody(model: "llama3.2", system: "s", user: "u", numCtx: 16_384, thinkingOff: false)
        #expect(body["think"] == nil)
    }

    @Test("The wait grows with the meeting, from 5 to at most 30 minutes")
    func timeoutScales() {
        #expect(OllamaAPISummarizer.timeout(promptChars: 0) == 300)
        // ~20k tokens, a half-hour Russian meeting: well past the old 180 s.
        let halfHour = OllamaAPISummarizer.timeout(promptChars: 60_000)
        #expect(halfHour > 700 && halfHour < 900)
        #expect(OllamaAPISummarizer.timeout(promptChars: 2_000_000) == 1_800)
    }

    @Test("A timeout says the model is too slow, not that Ollama isn't running")
    func timeoutWording() {
        let url = URL(string: "http://127.0.0.1:11434")!
        let slow = OllamaAPISummarizer.transportError(URLError(.timedOut), baseURL: url, timeout: 600, serverAnswers: true)
        #expect(slow.localizedDescription.contains("didn’t finish the summary in 10 min"))
        #expect(!slow.localizedDescription.contains("ollama serve"))
        let down = OllamaAPISummarizer.transportError(URLError(.cannotConnectToHost), baseURL: url, timeout: 600, serverAnswers: false)
        #expect(down.localizedDescription.contains("Couldn’t reach Ollama at http://127.0.0.1:11434"))
        // Timed out and the server no longer answers the probe: not «too slow».
        let gone = OllamaAPISummarizer.transportError(URLError(.timedOut), baseURL: url, timeout: 600, serverAnswers: false)
        #expect(gone.localizedDescription.contains("Couldn’t reach Ollama"))
    }

    @Test("Both messages have Russian")
    func russian() throws {
        let ru = try #require(Bundle.main.path(forResource: "ru", ofType: "lproj").flatMap(Bundle.init(path:)))
        for key in ["Ollama didn’t finish the summary in %lld min — this model is too slow for a meeting this long. Choose a smaller model, or a cloud provider, in %@.",
                    "Couldn’t reach Ollama at %@. Open Ollama (or run `ollama serve`) and try again. (%@)"] {
            let value = ru.localizedString(forKey: key, value: "∅", table: nil)
            #expect(value != "∅" && value != key)
        }
    }
}
