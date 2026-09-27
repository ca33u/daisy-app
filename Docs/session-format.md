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
| `microphone.caf` | The user's own voice — on the Mac. On a phone session (§3.6) it is the whole room |
| `microphone.part2.caf`, `.part3.caf`, … | Continuation files after a mid-recording format change |
| `system_audio.caf` | Everyone else. Never split |
| `system_audio.<ext>` | Imported audio, keeping its original container |
| `screenshots/001.jpg` … | Captured frames, `%03d` + extension |
| `screenshots/index.json` | `{"001.jpg": 12.0}` — filename → seconds into the recording; a value past `duration_sec` means the frame was added after the recording ended (§3.3) |
| `screenshots/highlights.json` | `["001.jpg", …]` — frames OCR found visually distinct |
| `markers.json` | Moments the user marked by hotkey, written as they happen |
| `import.json` | Present iff this session came from a file the user imported. §5 |
| `script.md` | A rehearsal take's text, as it was when the take was recorded. §3.7 |
| `words.json` | Word timings: `[{"w": "Привет", "s": 0.32, "e": 0.61}, …]`, seconds into the recording. Written by readers that need them (rehearsal analysis, subtitles); any session may carry it |
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

The microphone stream **is the user, by definition** — on the Mac. Its
segments are labelled with the user's display name and are never diarized
into separate people. The system-audio stream is the other side, and that
is what gets diarized into `Remote A`, `Remote B`, and so on.

**This rule does not apply to a session whose microphone is the room**
(any `daisy_origin`, §3.6). A phone, a watch or an imported file records
a meeting with one microphone, and everyone present is in it. Reading
the Mac rule against such a file would stamp the owner's name on every
word the other person said — see §3.6 for what a reader does instead.

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
| `daisy_kind` | `recording`, `note` or `rehearsal` (§3.7) | always |
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
`daisy_diarization`, `daisy_audio_files` (import and re-transcription);
`daisy_origin` and `daisy_diag_*` (§3.6); `daisy_script_id`,
`daisy_target_sec`, `daisy_best_take` (§3.7).

**An unknown `daisy_kind` is kept, never rewritten.** A reader that does not
know the value shows the session as a recording; a writer that stamps
`daisy_kind` (moving a session between folders) writes it only where the
key is absent. Overwriting a value it does not know turns a rehearsal take
into a plain recording for good.
`daisy_client` is a read-only legacy alias for `daisy_tag`.

**Quoting.** A quoted value is `"` + the text with `\` written as `\\`
and `"` written as `\"` + `"`. A reader that strips the surrounding
quotes should also undo those two escapes, in that order reversed — the
Mac app's reader today strips the quotes and nothing else, so a title
containing `"` comes back with its backslashes (a listed gap, not a
licence: a second implementation unescapes). Only
`title`, `daisy_tag`, `daisy_transcription_model`, the `daisy_import_*`
strings, `daisy_parent_session` and the `daisy_event_*` strings are
quoted; every other value is bare.

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

**Highlights.** A reader may mark words inside a segment the way one
marks a line in a book: `==marked words==` — Obsidian's highlight
syntax, chosen because a Daisy library usually lives in an Obsidian
vault. Rules, all narrow on purpose:

- a highlight lives **inside one segment line**; it never spans lines;
- highlights never nest, and `====` (empty) marks nothing;
- a writer that does not understand them must **leave them alone** —
  the words between the markers are ordinary text, and stripping the
  markers is allowed (search, summarising, the `daisy_speaker_map`
  substitution) but must not remove the words;
- there is exactly **one** kind of mark and no colour. A colour would
  need a legend, and the second person to open the file would have to
  guess what it meant.

Section headings are localized — except one. **`## Transcript` is never
translated**, in any language, because the audio-retention sweep finds it
by literal string to decide whether a transcript has real content before
deleting the only copy of the audio. Translating it would delete
recordings.

Timestamps are `m:ss`, or `h:mm:ss` past an hour. The separator between
timestamp and speaker is `·` (U+00B7) with a space on each side.

Speaker labels: the microphone stream uses the user's configured display
name, or `Me` when unset; the system stream uses `Remote A`, `Remote B`,
…, or bare `Remote` when diarization produced nothing. On a phone session
(§3.6) the microphone stream carries everyone, so after diarization its
labels follow the system-stream rule — `Remote A`, `Remote B`, … — except
the cluster recognised as the owner's voice, which takes the display
name. Without diarization (`daisy_diarization` absent) the phone writes
every segment as `Me` (or the display name): honest for a voice note,
provisional for a meeting.

Screenshot timecodes in `## Screenshots` and `## Marked moments` come
from `screenshots/index.json`. A frame whose value is **greater than
`duration_sec`** was added after the recording ended (a card photographed
a week later, a note attached from the library): the value is the seconds
between the session's `started` and the moment of adding, so it stays a
number on the same clock, sorts to the end, and is never a fake position
inside the conversation. Render it as *added later*, not as a timecode.
The field is never used for anything else.

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

### 3.5 The other minimal profile: recovered recordings

Crash recovery writes an even smaller file than a screenshot note. It
runs after a crash or a power loss, from audio and nothing else: there
was no clean stop, so there is no summary, no diarization and no capture
statistics to record. Its marker is:

```yaml
daisy_recovered: true
```

It writes exactly `title`, `started`, `daisy_recovered`, `daisy_kind:
recording`, `duration_sec`, and — **only when the user has configured a
default meeting project** — `daisy_folder`. Everything else §3.1 calls
"always" is absent, and legitimately so. A reader must not treat a
missing `daisy_folder` here as data loss: absent means `inbox`, which is
what it would have meant anyway.

The body carries a heading, an explanatory quote, any moment markers
that survived in `markers.json`, and then one section per stream:

```markdown
## Your side

…what the microphone caught…

## Other side

…what the system audio caught…
```

When neither stream produced speech, the body says so in one italic
line instead.

Three things a second implementation must get right here.

**Those two headings are localized.** A Russian recovery writes «Ваша
сторона» and «Другая сторона». Never key on them. This is the exact
opposite of `## Transcript` (§3.3), which is never translated in any
language because the retention sweep finds real content by that literal
— and a recovered transcript deliberately has no such heading, which is
why the sweep leaves its audio alone. That is the design working, not a
gap: the raw audio is the only good copy of a recording nobody finished
processing.

**`duration_sec` here is rounded, not truncated**, which contradicts
§3.1. That is a bug in the Mac app, not a licence: a second
implementation truncates. A checker may tolerate the rounding on
recovered sessions until the Mac app is fixed, and should stop
tolerating it afterwards. The difference is under a second and harms
nobody — it is listed because an undocumented inconsistency is how two
implementations start drifting.

**The profile is a claim, not an inference.** It applies because the
marker says so, never because fields happen to be missing. A file with
`daisy_recovered: false`, or without the key, is judged as a full
recording no matter how little it carries. Same rule for §3.4. When a
file somehow carries both markers, the screenshot-note profile wins,
because it is the one that describes a shape the app still writes today.

### 3.6 Sessions whose microphone is the room

A Mac session's microphone is the owner (§2.1). Everything else records
a room: one microphone, everyone in it. Those sessions write into the
same folders with the same `transcript.md`, so the Mac Library reads
them like any other, and they are marked by:

```yaml
daisy_origin: iphone
```

written right after `daisy_kind`. A session without the key is a Mac
session; `daisy_origin: mac` is not written and must not be required.

**The values.** Each recorder gets its own, and the list grows:

| `daisy_origin` | Written by | The audio |
|---|---|---|
| *(key absent)* | Daisy for Mac | §2.1 applies: microphone = owner, system audio = the other side |
| `iphone` | Daisy for iPhone | the room, 16 kHz mono int16 |
| `watch` | Daisy for Apple Watch, recording on its own because the phone was out of reach | the room, 16 kHz mono int16, from a worse microphone |
| `import` | any Daisy, from a file the user brought in (§7.5) | whatever the file had; the recorder is unknown |

**A reader that does not recognise a value treats the session as a room
recording, not as a Mac one.** The rule is written this way round on
purpose: a new recorder appearing in a future version must not make an
old reader stamp the owner's name on a stranger's words. Adding a
recorder means adding a value here — never an exception somewhere else.
The `import` value is what a reader gets today; before it existed, the
phone wrote `iphone` on imported files too, which was a lie that
happened to produce the right behaviour.

What an `iphone` session carries when it arrives:

| Key / file | Value on arrival |
|---|---|
| `daisy_kind` | `recording` |
| `daisy_origin` | `iphone` |
| `microphone.caf` (+ `.partN`) | the **whole room**: owner and everyone present, **16 kHz mono int16** (since 2026-09-21; sessions recorded before that are at the phone's native rate, 48 kHz float32). Readers must not assume either — resample as for any `.caf`. May be **absent**: the phone applies the same retention policy as the Mac (`-1` delete after transcript + summary is the default), and `daisy_mic_audio_status` keeps the value written at the time of recording |
| `system_audio.*` | never present; `daisy_system_audio_status: off` |
| `daisy_mic_audio_status` | `captured (N B)` / `truncated (…)` / `empty`, as §3.1 |
| `daisy_speaker_map` | `{}` — the phone labels voices but never names anyone but the owner |
| `daisy_diarization` | `true` when the phone separated voices (below); absent otherwise |
| `speakers.json` | the other voices' centroids, under their final labels, when `daisy_diarization: true` |
| `daisy_transcription_model`, `daisy_transcription_language`, `detected_locale` | the phone transcribes with the Mac's default Whisper model and writes the same three keys the Mac writes on re-transcription |
| `daisy_event_*` | when the recording was started from a calendar meeting |
| `daisy_diag_*` | battery, thermal state, background start, queue wait, decode time, real-time factor, peak memory — the phone's own field-day telemetry; ignored by every other reader |
| `screenshots/` | photos taken from the record screen (§2), indexed by media second |
| body | without `daisy_diarization`: `**[m:ss · Me]**` (or the display name) on every segment; with it: the rules below |

**The rule of §2.1 does not apply** to any session in the table above.
Its microphone track is not the owner; it is the meeting. A reader that diarizes such a
session diarizes the microphone track **whole**, and then:

1. finds the owner's voice by comparing each cluster's centroid with the
   owner's stored `SpeakerProfile` (the 256-dimensional embedding the Mac
   already keeps for named speakers; the owner's is enrolled from Mac
   recordings, where the microphone *is* the owner). The best cluster above
   the match threshold takes the display name;
2. labels every other cluster `Remote A`, `Remote B`, … in order of first
   appearance, exactly as system-stream clusters on the Mac, and writes
   their centroids to `speakers.json` so they can be named, merged and
   enrolled the usual way;
3. when no cluster matches the owner — no profile yet, or the owner did
   not speak — labels **all** clusters `Remote …` and says nothing about
   who is who. An unlabelled owner is recoverable by renaming; an
   owner's name on someone else's words is not.

**The phone diarizes too (since 2026-09-25).** After transcribing, it
applies the three rules above to its own transcript and writes
`daisy_diarization: true` and `speakers.json`. Where it differs from the
Mac:

- the owner's profile is the phone's own, learnt from rehearsal takes
  (§3.7 — the speaker of a take is the owner). The Mac's profiles do not
  travel, so a phone with no takes yet labels every voice `Remote …`
  (rule 3);
- a voice heard in a single stretch shorter than 4 s joins the voice
  nearest in time, so one person is not split in two;
- when it finds one voice, it changes nothing: the lines stay `Me` and
  `daisy_diarization` is not written. One voice cannot tell a voice note
  from a lecture.

A transcript without `daisy_diarization` (every segment `Me`) is a first
pass, not a claim about who spoke: when its audio reaches the Mac, the
Mac diarizes it in a child session (`daisy_parent_session`), as any
re-transcription does. A transcript with `daisy_diarization: true` stands
— the Mac does not diarize it again on its own (since 2026-09-26). The
two devices keep separate owner profiles, each learnt where it listens,
and the Mac's, from a close microphone, would likely not know the owner
in a room recording. A re-transcription the user asks for still runs.

---

### 3.7 Rehearsal takes

A person rehearsing a talk, or voicing a reel from a script, records
**takes**. Each take is its own session — so sync, the library, deletion
and audio retention work unchanged — marked by:

```yaml
daisy_kind: rehearsal
daisy_origin: iphone
daisy_script_id: 5E1D2C9A-…
daisy_target_sec: 60
```

| Key / file | Meaning |
|---|---|
| `daisy_script_id` | UUID shared by every take of one text. The takes of a script are the sessions with the same id |
| `daisy_target_sec` | the duration the person is aiming for, integer seconds; absent when there is none |
| `daisy_best_take: true` | on the one take the person picked; absent on the others |
| `script.md` | the text **as it was for this take**, Markdown, paragraphs separated by a blank line. Edited text between takes means each take is compared with its own copy |
| `words.json` | word timings of what was said (§2); the analysis and the subtitles are computed from it and `script.md`, and are not stored |
| audio | `microphone.m4a` (AAC, 48 kHz) or `microphone.caf` (lossless, 48 kHz): a take may be published, so it is **not** reduced to 16 kHz like a meeting. Readers resample as for any audio |
| `video.mov` | optional: the front camera, **video only** (HEVC). The take's sound is the audio above, never the camera's |
| `video.json` | beside `video.mov`: `{"offsetSec": 0.42}` — where the first video frame falls in the audio, to lay the two together |

The script is **never** given to the transcriber as a prompt: a model told
what should be said hears it, and the differences the take exists to
show disappear.

A reader that does not know `rehearsal` shows the take as a recording;
`script.md` and `words.json` are extra files and are ignored (§3.1). §3.6
applies as for any phone session.

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

Edits made by a person — a corrected word, a renamed speaker, a title —
**survive "Transcribe again"**: it never overwrites the edited file, it
writes a child session (`daisy_parent_session`) and leaves the parent as
edited. When two copies of the same session meet during synchronisation
(a phone and a Mac editing the same folder), the copy with the later
modification time wins and the losing copy is kept beside it, never
deleted — the merge is a person's decision, not the sync's.

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

A frame added after the recording takes the next free number and an
`index.json` value past `duration_sec` (§3.3). Numbering therefore keeps
capture order, and "after the recording" frames are at the end both by
number and by value; a reader sorting by either gets the same result.

### 7.7 `duration_sec`

Truncated to a whole second — `Int(duration)`, never rounded — on every
profile. §3.5 records the one Mac writer that rounds; the phone
truncates. Two implementations that disagree here drift by a second on
half of all sessions, and a checker that compares durations across copies
will never settle.

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
