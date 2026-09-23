//
//  ExportSummaryPrompts — backlog 19 А-2.
//
//  `swift run ExportSummaryPrompts <out.json>` writes every system prompt
//  the summary can take (each language hint × one voice or not), the
//  user-prompt template and the output schema — straight from
//  `SummaryPrompt`, so the server never holds a hand-copied prompt that
//  drifts from the apps. The server sends these texts and nothing the
//  client wrote: a subscription buys summaries, not an open model.
//

import DaisyCore
import Foundation

let hints: [String?] = [nil, "ru", "uk", "pl", "es", "fr", "de", "it", "pt", "ja", "ko", "zh", "en"]
var system: [String: String] = [:]
for hint in hints {
    for single in [false, true] {
        system["\(hint ?? "auto")|\(single ? "single" : "multi")"] =
            SummaryPrompt.meetingSystemInstructions(localeHint: hint, singleVoice: single)
    }
}
let payload: [String: Any] = [
    "generatedBy": "DaisyCore ExportSummaryPrompts",
    "system": system,
    // Placeholders, filled by the server after it neutralises any copy of
    // the transcript fences inside the transcript itself.
    "userTemplate": SummaryPrompt.meetingUserPrompt(title: "{{TITLE}}", transcript: "{{TRANSCRIPT}}"),
    "schema": MeetingSummaryJSONSchema.json,
]
let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "summary-prompts.json")
try data.write(to: out)
print("wrote \(system.count) system prompts to \(out.path)")
