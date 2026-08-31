# Contributing to Daisy

Thanks for thinking about contributing. Daisy is open source under the Apache 2.0 licence, but direction is set by a single maintainer — please read this before spending your time on a pull request.

## Direction is set by the maintainer

Daisy is shaped by one person (Egor, Addicted Studio) and a small handful of advisors. That means:

- The roadmap is opinionated. Some features are deliberately out of scope (cloud sync, account system, multi-user collaboration) and won't be merged regardless of code quality.
- **Substantial changes should be discussed first.** Please open a [Discussion in Ideas](https://github.com/ca33u/daisy-app/discussions/categories/ideas) before writing the PR. I'll tell you upfront whether the direction fits, and we can iterate on the approach before you spend hours coding.
- I will sometimes close PRs that I won't merge. That's not a comment on the work — it's a "this doesn't fit where Daisy is going". I'll explain why.

## What's likely to be welcomed

- **Bug fixes** with a clear repro. Open an Issue first if there isn't one, but PRs that close existing Issues are great.
- **Performance improvements** that don't change the user-facing behaviour. CPU, memory, startup time, build time, render-thread allocation.
- **Polishing existing features** — better error messages, accessibility, keyboard navigation, dark-mode visuals.
- **Docs improvements** to the README, code comments, or [mydaisy.io](https://mydaisy.io) (which lives in [daisy-web](https://github.com/ca33u/daisy-web)).
- **New tests.** The `DaisyTests` smoke suite is small on purpose; high-value pure-function tests are welcome.

## What's likely to be declined

- New cloud integrations (we ship local-first; if you want cloud, write a separate tool that talks to Daisy via MCP).
- Account systems, user logins, anything that requires a server we maintain.
- Telemetry, analytics, "anonymous" usage stats — Daisy doesn't ship those by policy.
- Major UI overhauls without prior design discussion.
- Refactors that don't have a clear payoff (cleanliness alone isn't usually worth the merge cost).

## Practical bits

### Setup

```bash
git clone https://github.com/ca33u/daisy-app.git
cd daisy-app
open Daisy.xcodeproj
```

You need Xcode 16+ with the macOS 26 SDK. Apple Silicon Mac only — Daisy doesn't support Intel.

### Branch naming

- `fix/short-description` for bug fixes
- `feat/short-description` for new behaviour
- `chore/short-description` for tooling, deps, formatting

### Commit messages

One-line summary in the present tense. Body if needed. Example:

```
Tag picker: open on field tap, not chevron click

The chevron was redundant — clicking the field already had to open the
popover. Removing it cleaned up the visual hierarchy and matches the
Notion-style affordance used elsewhere.
```

### Code style

- Swift's standard formatting (Xcode's default).
- Comments where logic isn't obvious. Daisy's codebase leans heavily on **why-comments** — explain the reason behind a choice, not what the code does.
- No new third-party deps without prior discussion. Every new dep is a future audit problem.

### Tests

Run `DaisyTests` (the regression suite, not the UI tests target which was removed). Pure-function tests are preferred — integration tests against `AudioRecorder` or `SystemAudioCapture` need a Mac runner and are hard to keep stable.

### Licence

Daisy is [Apache 2.0](LICENSE). Contributions are accepted under that same licence. By opening a PR, you confirm you have the right to contribute under Apache 2.0 — that's all the paperwork.

## Questions

Ask on [Discord](https://discord.gg/JYCZRZXy6j), open a [Discussion in Q&A](https://github.com/ca33u/daisy-app/discussions/categories/q-a), or email **my@addicted.design**.
