# Feature counts ("Help make Daisy better")

Daisy for Mac can send the developer a day's count of which features ran and
where they failed. It does so only if you agree: Daisy asks once, a couple of
minutes after a launch past first run, and the switch is in
**Settings → About → Help improve Daisy**. Until you answer, nothing is
counted. Turning it off deletes whatever was counted and not yet sent.

## What a report looks like

Once a day Daisy sends one report for the previous UTC day to
`https://api.mydaisy.io/api/usage`:

```json
{
  "app" : "mac",
  "build" : 150,
  "channel" : "beta",
  "counts" : {
    "dictation.done" : 14,
    "dictation.engine.whisper" : 14,
    "recording.length.15to60m" : 2,
    "recording.saved" : 2,
    "summary.anthropic" : 2
  },
  "day" : "2026-10-17",
  "language" : "en",
  "os" : "26",
  "schema" : 1,
  "sync" : false,
  "version" : "1.0.8.33"
}
```

**What What's sent shows.** In Settings → About, What's sent shows the report
being gathered today, exactly as it will go out.

**What a report never contains:**
- meeting text, titles, names, file paths or device names;
- an identifier of any kind.

So two reports from one Mac look the same as two reports from two Macs.

**What the server does with a report.** The server (`daisy-api`,
`src/usage.ts`):
- accepts only the names listed below;
- adds the numbers into daily totals;
- keeps no report;
- does not record the address a report came from.

Vercel, which hosts the server, keeps its standard short-lived request logs,
as for any web request.

## Every counter

The list is the same in the app (`Daisy/ImprovementStats.swift`) and on the
server (`daisy-api/src/usage.ts`); a test keeps the app to it, and the server
refuses anything else.

| Counter | Counted when |
|---|---|
| `recording.started` | a meeting recording starts |
| `recording.started.calendar` | …and it was started from the calendar (auto-start or its prompt) |
| `recording.saved` | a meeting recording is saved |
| `recording.length.under15m` / `15to60m` / `over60m` | the saved recording's length, in one of three buckets |
| `recording.failed` | a recording could not start |
| `recording.mic_only` | a meeting recorded the microphone only (system audio failed or was denied) |
| `voice_note.saved` | a voice note is saved |
| `transcription.failed` | the final transcription pass failed |
| `summary.<provider>` | a meeting summary was made |
| `summary.failed.<provider>` | a meeting summary failed |
| `dictation.done` | a dictation produced text |
| `dictation.engine.whisper` / `parakeet` / `apple_speech` | which engine produced it |
| `dictation.repaste` | "Paste last dictation" was used |
| `import.file` | an audio or video file was imported |
| `import.archive` | a `.daisy` session archive was imported |
| `iphone.audio_received` | a recording's audio arrived from Daisy for iPhone |
| `sync.pulled` | sessions arrived through iCloud sync (the count) |
| `export.markdown` / `archive` / `notion` / `claude` / `audio` | a session was exported that way |
| `mcp.tool_call` / `mcp.tool_error` | a tool of Daisy's MCP server was called / returned an error |
| `screenshot.note` | a screenshot note was created |
| `moment.marked` | a moment was marked during a recording |
| `layout.fixed` / `layout.undo` | the keyboard layout fixer converted a word / a fix was undone |
| `voice_profile.generated` | the writing-style profile was built |
| `catch_up.used` | "What did I miss?" made a recap |
| `speakers.named` / `speakers.matched` | speakers were named by hand / matched automatically (the count) |
| `rewrite.done` / `rewrite.failed` | "Rewrite in my voice" pasted a rewrite / the summary provider gave no usable rewrite in time (an error, a timeout, or a result too short, too long or with a privacy placeholder left in) |
| `ask.done` | "Ask Daisy" answered and pasted the answer |
| `ask.with_selection` | …with text selected |
| `ask.local` / `ask.cloud` | …by a provider on this Mac / in the cloud |
| `ask.undone` | an answer from "Ask Daisy" was undone |

"Ask Daisy" is not in the app yet. Its counters are listed ahead, so the server
already accepts them when it arrives; until then Daisy never sends them.

`<provider>` is the kind of summary provider, never the model, key or
account:
- `apple`, `anthropic`, `openai`, `openai_account` (a ChatGPT account), `gemini`, `cursor`, `kimi`;
- `ollama`, `lmstudio`, `mcp`, `agent_cli`.

**What travels with the counts:**
- the app version and build;
- `channel`: `beta` or `stable`;
- the macOS major version;
- the interface language (two letters);
- `sync`: whether iCloud sync is on.

Daisy for iPhone does not send these counts.
