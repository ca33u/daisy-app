# Daisy

A local-first meeting recorder, push-to-talk dictation tool, and AI-notes app for macOS — with a local MCP server so Claude Desktop and Cursor can query your transcripts without anything leaving the Mac.

[![Support Daisy on Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/G3W723TUZD)

Daisy captures meeting audio (microphone + system-audio loopback via ScreenCaptureKit), transcribes it on-device with Whisper on the Neural Engine, and produces a structured outline with action items and a draft follow-up. Audio and transcripts never leave the Mac unless you explicitly enable a remote summary provider. Remote summaries can use your own API key or an explicitly connected ChatGPT account; an optional on-device privacy filter pseudonymizes detected sensitive data before supported cloud requests.

End-user installation, FAQ, and the privacy story live at **<https://mydaisy.io>**. This README is for people building Daisy from source.

## What it does

Three capture modes, one app:

- **Meetings** — records both sides of a call (your mic + the other side via system-audio loopback), no bot joining the meeting. On-device transcription + diarization (`Remote A` / `Remote B`, with optional mic-side attribution), a summary, action items, and a draft follow-up. Optional extras include periodic screenshots with on-device OCR, a preparation brief built from the agenda and past sessions, evidence-backed progress against the meeting plan, local meeting analytics, and custom meeting apps beyond the built-in list.
- **Push-to-talk dictation** — hold a hotkey, speak, and the text is pasted at your cursor in any app. Three on-device engines: Whisper (default), Parakeet (FluidAudio) for lower latency, and Apple SpeechAnalyzer on macOS 26 (zero download). A custom-vocabulary dictionary fixes names/jargon, an optional voice profile learns your phrasing, and a rolling 24-hour history lets you re-copy.
- **Voice notes** — quick one-off thoughts saved to your Library. Optional: import existing **Apple Voice Memos** as flat transcripts (on-device, opt-in, needs Full Disk Access).

Around the edges: morning and end-of-day summaries on Home, an opt-in keyboard-layout auto-fixer (retypes text entered in the wrong layout, with undo and per-app exceptions), and provider-returned ChatGPT plan-window usage plus local token accounting for API providers. The UI is localized in English and Russian.

The differentiator: Daisy ships a **local MCP server** bound to `127.0.0.1` that exposes your sessions as a queryable, actionable data source to any MCP client (Claude Desktop, Cursor, Codex). Because the transcript is already local, Daisy can be a local-only MCP source — something cloud meeting tools structurally can't offer.

## Status

- Latest release: see [`scripts/release-notes/`](./scripts/release-notes/) and <https://mydaisy.io/appcast.xml>. Beta ships from `main`; stable is promoted from a soaked beta (see [`RELEASING.md`](./RELEASING.md)).
- Deployment target: macOS 14 Sonoma. The Apple Intelligence summarizer and the Apple SpeechAnalyzer dictation engine require macOS 26 Tahoe; everything else runs on 14+.
- Apple Silicon (M1+). Signed with Developer ID, notarized, stapled, Sparkle EdDSA-signed for in-app updates.
- License: **Apache 2.0** (see [`LICENSE`](./LICENSE)). Full public source — build it and verify there's no telemetry.

## Build from source

Requirements:

- Xcode 26+ (ships the macOS 26 SDK the project builds against)
- An active Apple Developer account if you want a signed local build (unsigned builds are fine for development inside Xcode)

Clone and open:

```bash
git clone https://github.com/ca33u/daisy-app.git
cd daisy-app
open Daisy.xcodeproj
```

The Swift Package Manager dependencies (Sparkle, WhisperKit via [`argmax-oss-swift`](https://github.com/argmaxinc/argmax-oss-swift), FluidAudio) resolve on first project load. Hit Run; the app launches.

## Project layout

```
Daisy/                  → SwiftUI app sources (PBXFileSystemSynchronizedRootGroup)
DaisyTests/             → unit tests
Benchmarks/             → reproducible WER/DER/JER scorer, product runner, and public evidence
Daisy.xcodeproj/        → Xcode project
scripts/
  release.sh            → end-to-end release: archive → notarize → DMG → sign → Sparkle appcast
  release-notes/        → per-version markdown bullets consumed by release.sh
  dmgbuild_settings.py  → dmgbuild config (Python) for the installer DMG
  assets/               → DMG background, app icons
build/                  → archive output (gitignored)
RELEASING.md            → branch/channel model and the release/promote/hotfix flows
```

Key services that drive the app:

- `CoreAudioMicRecorder` — CoreAudio mic capture with route-change recovery and the archive `.caf` writer (replaced the old AVAudioEngine tap to fix route-change/Bluetooth dropouts)
- `SystemAudioCapture` — `SCStream` loopback for the remote side of a meeting, Bluetooth-output detection, silent-capture warnings
- `Transcriber` / `WhisperEngine` — WhisperKit on-device transcription with a Silero VAD pre-pass
- `ParakeetEngine` / `AppleSpeechEngine` — the two alternative dictation engines: FluidAudio Parakeet-TDT (low latency) and Apple SpeechAnalyzer (macOS 26, no model download); Whisper is the default
- Diarization + speaker memory — FluidAudio (Pyannote) labels remote voices; named speakers are remembered locally by a short voice fingerprint
- `DictationPaste` — pastes dictated text at the cursor via the Accessibility API, restoring your prior clipboard
- `RecordingSession` — orchestrates a session, owns calendar binding and auto-stop scheduling
- `Summarizer` — multi-provider LLM dispatch: Apple Intelligence (on-device), ChatGPT account, Anthropic, OpenAI, Kimi (Moonshot), Cursor API key, Ollama, LM Studio (local), or an MCP summarizer
- `SensitiveDataProtector` — optional on-device pseudonymization/redaction boundary for supported remote summaries
- `MeetingPreparation` / `MeetingPlanAnalysis` / `MeetingAnalytics` — pre-meeting context, evidence-backed agenda progress, and local call metrics
- `ScreenshotCapture` — opt-in periodic screenshots of the meeting window with Vision OCR; screen text flows into the transcript and summary
- `PreMeetingBrief` / `MorningBrief` / `EndOfDaySummaries` — local briefs assembled from your calendar and past sessions, plus an evening digest
- `VoiceProfile` — opt-in personalization learned from your dictations (and, optionally, your mic side of meetings)
- `LayoutAutoFix` — opt-in keyboard-layout auto-correction via a CGEvent tap, with undo and per-app exceptions
- `TokenLedger` — local token-usage accounting per cloud provider, shown on Home
- `MCPServer` — the local MCP server on `127.0.0.1`; exposes nine tools (five read, four act) to Claude Desktop / Cursor / Codex
- `VoiceMemoScanner` / `VoiceMemoIngestor` — opt-in, on-device import of Apple Voice Memos to Markdown transcripts
- Sparkle 2 — in-app auto-updates against `https://mydaisy.io/appcast.xml`

## MCP server

Daisy's MCP server turns your recordings into a live data source for AI clients, entirely on-device. Enable it in **Connections → MCP server** and use the one-click setup for Claude Desktop, Cursor, or Codex — the config is written for you. Nine tools, scoped to safe, reversible operations (no deleting, no editing transcript bodies):

- **Read** — `list_sessions`, `get_session`, `search_sessions`, `list_folders`, `list_destinations`
- **Act** — `resummarize_session`, `set_session_title`, `rename_speaker`, `route_session_to_destination` (Notion / Linear / Slack / webhook)

Docs: <https://mydaisy.io/docs/mcp>.

## Reproducible benchmarks

[`Benchmarks/`](./Benchmarks/) contains the product-pipeline runner, a neutral
standard-library scorer for WER/CER/DER/JER, fixtures, and published raw
evidence. The first public baseline is AMI `ES2004a`: Daisy 1.0.7.59 detected
4/4 speakers with 15.68% DER and 20.28% JER at a median 0.122× real time
across three warm runs on an M4 MacBook Air. It is one reproducible
diarization case, not a general accuracy
claim; Humla and OpenWhispr remain unscored until their raw output exists for
the exact same audio. See the [methodology and publication gate](./Benchmarks/README.md)
and the [public evidence](./Benchmarks/reports/public/).

## Release flow

```bash
DAISY_AUTO_PUSH=1 ./scripts/release.sh <shortVersion> <buildNumber> [stable|beta]
```

Beta is the default channel from `main`; stable is promoted from a soaked beta with `./scripts/release.sh promote <version>` (no rebuild). Six steps: archive → export → notarize → DMG → publish to the [daisy-web](https://github.com/ca33u/daisy-web) repo → inject an `<item>` into `appcast.xml` and commit. Vercel auto-deploys the site within a couple of minutes. Full branch/channel model and the hotfix flow are in [`RELEASING.md`](./RELEASING.md).

Release notes for each version go in `scripts/release-notes/<shortVersion>.md` as a flat markdown bullet list (`- one line per change`). The script extracts those bullets and embeds them in the appcast `<description>` so Sparkle shows them in its update sheet.

## Support and contact

- Chat with the community → [Discord](https://discord.gg/JYCZRZXy6j)
- Questions, ideas, show-and-tell → [GitHub Discussions](https://github.com/ca33u/daisy-app/discussions)
- Product issues, feature requests → file an issue on this repo or email **support@mydaisy.io**
- Security disclosures → see [`SECURITY.md`](./SECURITY.md)
- Procurement / security review / tailored deployment → email **hello@mydaisy.io**
- End-user docs → <https://mydaisy.io/docs> · Privacy → <https://mydaisy.io/privacy>

## Credits

- [Sparkle](https://sparkle-project.org) — in-app auto-updates
- [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) by Argmax — Apple Silicon Whisper inference (part of the Argmax OSS SDK)
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — Parakeet ASR + speaker diarization
- [FoundationModels](https://developer.apple.com/documentation/foundationmodels) — on-device summarization via Apple Intelligence (macOS 26+)

## License

[Apache 2.0](./LICENSE).
