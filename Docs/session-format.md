# The Daisy session format

This document is the contract between every Daisy app. A recording made
by one must open in another, on another operating system, years later.

The macOS app is the reference implementation. Where an implementation
and this document disagree, the implementation is wrong — but where this
document and the macOS app's behaviour disagree, this document is wrong
and should be corrected, because what is already on people's disks is the
real format.

A guiding principle runs through all of it: **the files are the
database.** There is no index, no journal, no server. A user can open a
session folder in Finder or Explorer, read the transcript in any text
editor, and delete what they don't want. Anything that would make the
folder unreadable without our app is a bug, not an optimisation.

---

## 1. Where sessions live

Sessions are flat directories under `<base>/Daisy/Sessions/`. There is no
nesting: a session's project is metadata, never a path.

`<base>` is either the app's own storage or a folder the user picked. A
user-picked base is remembered with whatever the platform's durable
path-permission mechanism is (a security-scoped bookmark on macOS), and
previous bases stay readable so moving the library never hides old work.
Only the currently active base is ever created; an old one that has gone
away is not recreated.

The scan is non-recursive, ignores hidden entries, and considers only
directories. This matters: it is what lets staging directories (§8) live
safely alongside real sessions.

### 1.1 The directory name is the session ID

```
2026-05-17T12-37-36Z
```

An ISO-8601 UTC instant to the second, with every `:` replaced by `-`
because Windows forbids colons in path components and macOS displays them
as slashes. No fractional seconds. The trailing `Z` is part of the name.

Readers must also accept the legacy local-offset shape, which older
recordings still use:

```
2026-05-16T22-30-00+08-00
```

Restore the colons before parsing.

Because the ID is a second-resolution timestamp, two sessions starting in
the same second inside one base would collide. The import path already
handles this by appending `-2`, `-3`, … until the name is free. **New
implementations should apply that suffix scheme to recordings too**, not
just imports; the Mac app currently assumes the collision can't happen.

---

## 2. What a session folder contains

Everything except `transcript.md` is optional. A folder with nothing but
audio is a valid state (an import awaiting transcription); a folder with
nothing but a transcript is a valid state (audio deleted by the retention
sweep).

| File | Meaning |
|---|---|
| `transcript.md` | The document. UTF-8, YAML frontmatter + Markdown body. §3 |
| `summary.json` | AI summary. §4 |
| `microphone.caf` | The user's own voice |
| `microphone.part2.caf`, `.part3.caf`, … | Continuation files after a mid-recording format change |
| `system_audio.caf` | Everyone else. Never split |
| `system_audio.<ext>` | Imported audio, keeping its original container |
| `screenshots/001.jpg` … | Captured frames, `%03d` + extension |
| `screenshots/index.json` | `{"001.jpg": 12.0}` — filename → seconds into the recording |
| `screenshots/highlights.json` | `["001.jpg", …]` — frames OCR found visually distinct |
| `markers.json` | Moments the user marked by hotkey, written as they happen |
| `import.json` | Present iff this session came from a file the user imported. §5 |
| `speakers.json` | `{"centroids": {"A": [f32…]}}` — voice fingerprints |
| `speaker_suggestions.json` | Proposed names for diarized labels |
| `transcript.raw.md` | Pre-polish copy, when a second LLM pass rewrote the transcript |
| `meeting-preparation.json` | Written at **start**, before any transcript exists |
| `plan-analysis.json`, `plan-analysis-error.json` | Post-meeting plan comparison |
| `.recording` | Hidden. A recording is in progress, or died mid-flight. §6 |
| `.send_failures.json` | Hidden. Deliveries to Notion/Slack/etc. that failed |

Audio extensions a reader must recognise: `caf`, `m4a`, `mp3`, `wav`,
`aiff`, `aif`, `aac`, `flac`.

### 2.1 Which stream is which

The microphone stream **is the user, by definition.** Its segments are
labelled with the user's display name and are never diarized into
separate people. The system-audio stream is the other side, and that is
what gets diarized into `Remote A`, `Remote B`, and so on.

This is why imported audio is written as `system_audio.<ext>` and never
as `microphone`. An imported interview is other people talking; filing it
as the microphone stream would stamp the user's own name on every word of
it.

Microphone audio is recorded at the input device's real sample rate and
channel count, not a fixed format — which is why a mid-recording device
change rolls over to a `.partN` file rather than resampling. System audio
is captured at 48 kHz.

---

## 3. `transcript.md`

UTF-8. Line 1 is exactly `---`; the next line that is exactly `---`
closes the frontmatter; everything after it is the body.

### 3.1 Frontmatter

Parse rule: split each line at the **first** `:`, trim the value, then
strip surrounding double quotes if both are present. Ignore unknown keys
— they are how the format grows without breaking old readers.

Written in this order:

| Key | Form | Written |
|---|---|---|
| `title` | quoted string | always |
| `type` | literal `meeting-transcript` | always |
| `source` | literal `Daisy` | always |
| `locale` | the *setting*, often `auto` | always |
| `detected_locale` | 2-letter code | when detected |
| `started` | ISO-8601 | when known |
| `duration_sec` | integer, **truncated** not rounded | always |
| `daisy_folder` | lowercase slug, default `inbox` | always |
| `daisy_kind` | `recording` or `note` | always |
| `daisy_tag` | quoted string; absent means untagged | when non-empty |
| `daisy_event_*` | calendar binding: external id, local id, title, start, platform, attendees, emails | when calendar-bound |
| `daisy_speaker_map` | inline dict. §3.2 | **always, `{}` when empty** |
| `daisy_audio_parts` | `["microphone.caf", "microphone.part2.caf"]` | only when more than one part |
| `daisy_system_audio_status` | `off` / `empty` / `captured (N B)` / `truncated (…)` | always |
| `daisy_mic_audio_status` | same four shapes | always |
| `daisy_mic_only` | cause code | when mic-only and the cause is known |
| `tags` | literal `[meeting, transcript, daisy]` | always |

Other writers add: `daisy_recovered: true` (crash recovery);
`daisy_parent_session`, `daisy_imported`, `daisy_import_source`,
`daisy_import_mode`, `daisy_import_original_name`,
`daisy_transcription_model`, `daisy_transcription_language`,
`daisy_diarization`, `daisy_audio_files` (import and re-transcription).
`daisy_client` is a read-only legacy alias for `daisy_tag`.

To change one field, replace the first line whose prefix is `key:`, or
insert before the closing `---`. Never re-render the whole file to change
one value — see §7.2.

### 3.2 `daisy_speaker_map`

A one-line inline dict from diarization label to display name:

```yaml
daisy_speaker_map: {A: "Alex", B: "Maria"}
```

The body always keeps canonical `Remote A` labels. The map is applied at
render time, by replacing `\bRemote\s+([A-Z])\b`. This is deliberate: the
names are metadata the user can rename freely, and the transcript text
stays stable.

A value of the literal form `Remote X` is an **alias**, meaning "this
label is the same voice as label X" — how merging two speakers is stored
without inventing a new field. Resolve exactly one hop; do not follow
alias chains.

Two quoting cautions, both real:

- The Mac app has two writers for this line, and one of them emits
  **quoted** keys (`{"A": "Alex"}`) while the reader strips quotes from
  values only. A map written by that path parses back with a key that
  literally includes the quote characters. **Emit bare keys; on read,
  strip quotes from keys as well.**
- There is no escaping. A display name containing a comma will break
  parsing. Reject or replace commas in names.

Substitution must be a **single pass with a lookup**, not a sequence of
find-and-replace calls: replacing `Remote A` → `Alex` and then
`Remote B` → `Remote A` in dictionary order produces different results on
different runs. This was a real bug.

### 3.3 Body

```markdown
# <title>

> recorded <date> · <duration>

## Summary
### <meeting label>
<lede paragraph>
### <section title>
- bullet
  - nested bullet
### Next actions
- [ ] item
### Follow-up
<paragraph>

## Screenshots
![0:42](<path>)

## Marked moments
- **[0:42]** — ![0:42](<path>)

## Transcript

**[0:07 · Alex]** Text of the segment.

**[0:12 · Remote A]** Text of the next one.

## Shared on screen
<OCR text, appended after the fact>
```

Section headings are localized — except one. **`## Transcript` is never
translated**, in any language, because the audio-retention sweep finds it
by literal string to decide whether a transcript has real content before
deleting the only copy of the audio. Translating it would delete
recordings.

Timestamps are `m:ss`, or `h:mm:ss` past an hour. The separator between
timestamp and speaker is `·` (U+00B7) with a space on each side.

Speaker labels: the microphone stream uses the user's configured display
name, or `Me` when unset; the system stream uses `Remote A`, `Remote B`,
…, or bare `Remote` when diarization produced nothing.

### 3.4 The minimal profile: screenshot notes

Not every session is a meeting. A screenshot note is created by a
keystroke, holds one picture and possibly a line of dictated context, and
has no audio, no speakers and no summary. It is the **same kind of
session** — one directory, one `transcript.md` — written with a much
smaller set of fields.

It is marked by one key:

```yaml
daisy_screenshot_note: true
```

When that key is present and true, the following are **legitimately
absent**, and a reader must not treat their absence as corruption:

- `type`, `source`, `locale`, `tags` — the fixed literals §3.1 calls
  "always"
- `daisy_speaker_map` — nothing was diarized, so there is nothing to map
- `daisy_system_audio_status`, `daisy_mic_audio_status` — nothing was
  captured
- the `## Transcript` heading, and every other body section

What such a note does carry, in this order: `title`, `started`,
`duration_sec: 0`, `daisy_kind: note`, `daisy_folder`, and the marker
key.

The body is a heading, an optional paragraph of dictated context, and a
relative image link:

```markdown
# Screenshot — 2026-09-12 09:14

The pricing table they showed on the call.

![2026-09-12 09:14](screenshots/001.png)
```

Two details a second implementation must match. The image goes in
`screenshots/001.<ext>`, never as a loose file in the session root —
that folder and the numeric name are what make the picture visible in
the Library at all. And the link is **relative**, unlike the absolute
paths the meeting renderer writes for its screenshot section.

This shape is by far the most common thing in a real library: in the
author's own, 75 of 90 sessions are screenshot notes. Any tool that
walks a sessions directory and expects §3.1's "always" fields will be
wrong about most of what it sees.

The general rule this is an instance of: **`daisy_kind: note` sessions
have no audio-derived fields.** A voice note is a note with audio and a
transcript; a screenshot note is a note with neither. Both are notes,
and neither owes the meeting shape anything.

---

## 4. `summary.json`

```jsonc
{
  "summary":        "string",      // required
  "sections":       [ { "title": "string",
                        "bullets": [ { "text": "string",
                                       "children": [ /* bullets */ ] } ] } ],
  "actionItems":    [ "string" ],
  "clientFollowUp": "string"
}
```

All four keys are always written, including empty arrays and strings.
Unknown keys are ignored on read — older files carry `decisions` and
`followUps`, which no longer mean anything.

**Writes must be atomic.** A torn write leaves truncated JSON, and
because reads are best-effort, the user simply sees no summary and never
learns why. Write to a temporary file in the same directory and rename
over the target.

There is no version or backfill flag inside the file. Recovery paths must
never overwrite an existing `summary.json` — its absence is the only
signal that a summary is still owed.

---

## 5. `import.json`

Present exactly when the session came from a file the user imported.

| Field | Meaning |
|---|---|
| `title` | Display title until a transcript exists; derived from the filename |
| `startedAt` | The date **of the file** — track metadata, else creation, else modification. Never the moment of import |
| `durationSec` | Probed duration |
| `folderSlug` | Project chosen at import |
| `sourcePath` | Absolute path of the original |
| `originalName` | Original filename with extension |
| `mode` | `copy` or `move` |
| `importedAt` | Wall clock of the import |

ISO-8601 dates, pretty-printed, sorted keys, written atomically.

This file carries a second job beyond metadata: **its presence is what
keeps an audio-only folder out of crash recovery.** A folder with audio
and no transcript looks exactly like a recording that died, and without
this marker the app will try to "recover" it — quietly starting a full
transcription the user never asked for. Write it before the audio is
visible in the sessions directory, not after.

`move` must trash the original, never hard-delete it, and only after the
new copy is safely in place. It is downgraded to `copy` for video sources
and for anything already inside the sessions tree.

---

## 6. Classification: is this session finished, interrupted, or junk?

Every folder resolves to exactly one of three states.

**Unreadable** — the folder cannot be parsed at all. Skip it and **do not
modify it**. An unparseable folder is more likely to be someone else's
data than ours.

**Interrupted** — a recording died mid-flight and its audio is worth
recovering. All of the following must hold:

- audio exists (microphone or system), **and**
- there is no finished transcript, **and**
- there is no `import.json`, **and**
- neither the transcript nor the audio is cloud-evicted, **and**
- either the `.recording` marker is present, or the largest single audio
  file is at least **256 KB**.

**Valid** — everything else.

"Finished transcript" means `transcript.md` exists and either its body is
non-empty *or* it carries a `title` or `started` in frontmatter. The
second half matters: crash recovery writes exactly that minimum so a
recovered session with no speech in it doesn't get recovered forever.

### 6.1 The `.recording` marker

Written at start, containing the ISO-8601 start instant. Removed when the
final transcript is safely on disk — **never earlier**. Remove it too
soon and a crash becomes silent data loss; leave it and the session looks
interrupted forever.

It is written **only when audio is actually being archived**. A
transcript-only session (the user chose not to keep audio, or the disk was
too full) must not carry it, or it will look recoverable with nothing to
recover.

A folder that classifies as **valid but still carries the marker** means
the app was quit during a recording and the final pass never ran. It gets
a finishing pass, not a recovery pass.

The audio-retention sweep must refuse to touch any folder carrying this
marker.

### 6.2 Cloud-evicted files

A file that has been evicted to cloud storage must be treated as
**present but unreadable**, never as absent. Reading it triggers a
download that may fail or take minutes; treating it as missing has
already, once, caused the app to delete the only copy of a user's
recordings. Check eviction status before opening anything during a scan.

---

## 7. Rules that are easy to get wrong

### 7.1 Ordering

1. `meeting-preparation.json` is written at start, before any transcript.
2. `markers.json` is rewritten on every mark, mid-session.
3. `transcript.md` is written **twice**: a live-quality version at Stop,
   then a full-quality overwrite when offline processing finishes.
4. `summary.json` must land before any follow-up LLM call.
5. `.recording` is removed last.

### 7.2 The user edits while the pipeline runs

Between the two transcript writes, the user can rename the session,
change its project, add a tag, or name a speaker. Before the final
overwrite, **re-read the file from disk and adopt** `title`,
`daisy_folder`, `daisy_tag`, `daisy_kind` and `daisy_speaker_map` from
it. The user's value wins. Rendering from memory destroys their edits,
and they will not know why.

### 7.3 Never publish a half-written folder

Build imports and re-transcriptions inside a **hidden** staging directory
(`.daisy-import-<uuid>/`), then move the finished folder into place. The
scanner ignores hidden entries, so a partially written session can never
be mistaken for a crashed recording.

Publishing a first transcript must fail loudly if `transcript.md` already
exists, rather than overwriting.

### 7.4 Before deleting audio, read the transcript

The retention sweep must verify from **the file on disk** that a real
transcript exists — at least one non-empty line after the literal
`## Transcript` heading. Not a flag, not a cached value. If the file is
missing, unreadable, or cloud-evicted, the answer is no.

### 7.5 Deleting

A bulk delete must always exclude the folder currently being recorded.

A session shorter than 10 seconds with no audio frames and no transcript
segments is the only case where the app removes a folder on its own, and
even then it tells the user. At 10 seconds or more, an empty session is
kept.

### 7.6 Screenshots

Frame files are a zero-padded number plus a readable image extension, and
nothing else — `001 copy.jpg` and `._001.jpg` are not frames. Order them
**numerically**, not lexically: the padding stops at 1000, so `999.jpg`
sorts after `1000.jpg` as text.

---

## 8. Things that live beside sessions, not inside them

In the sessions directory, all hidden, all transient:

- `.daisy-import-<uuid>/` — an import being assembled
- `.daisy-retranscribe-<uuid>/` — a re-transcription being assembled
- `.daisy-audio-<uuid>.m4a` — a working copy

A crash can leave these behind. Sweeping them at launch is safe and
should be done; they are never user data.

## 9. Things that are not in the session folder at all

The **project list** is application settings, not session data. A session
stores only its project's slug (lowercased name); the list of projects,
their display names and their single level of nesting live in the
platform's preferences store. A session referring to an unknown slug must
cause the project to be recreated, never to be dropped — losing the
reference would silently move the user's recording to Inbox.

The two system projects, `inbox` and `notes`, always exist and cannot be
deleted.

`daisy_kind` is independent of the project. A note can live in any
project and a recording can live in Notes. Legacy sessions with no
`daisy_kind` are inferred from the project, which is why every move must
stamp the field explicitly — otherwise the inference flips the kind the
next time the file is read.
