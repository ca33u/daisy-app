# Dictation cleanup: the measurement corpus

`corpus.jsonl` is what «Fix dictation by context» is timed on. The phrases were written for the
measurement: they are synthetic, in Russian and English, and none of them is anyone's real dictation.

## Line format

One JSON object per line:

```
{"id": "ru-short-1", "lang": "ru", "raw": "…", "want": "…"}
```

- `id`: the phrase's name in the output
- `lang`: its language (`ru`, `en`)
- `raw`: the text as a speech recognizer would hand it over: no punctuation, a misheard word, a false start
- `want`: the text a good cleanup returns. For the eye only: the bench prints the answer beside `raw` and scores nothing

## Running the bench

Against a built app, with the provider chosen in its Settings → AI:

```
/Applications/Daisy.app/Contents/MacOS/Daisy --daisy-dictation-cleanup-bench scripts/dictation-cleanup/corpus.jsonl --runs 3 --allow-cloud
```

Run it from the repository root, or give the corpus by its full path. For a build of one's own, put that
build's `Daisy.app` in place of `/Applications/Daisy.app`.

Each phrase goes the way a dictation goes in the app: the vocabulary and the product-name fixes, the
length rules, the language told from the text, the request held to the deadline, the answer checked,
the spellings put back. So the numbers are the product's. The switch in Settings and the yes stored
for dictation are neither read nor written, and nothing goes into the dictation history, the voice
profile or the fixes count.

- `--runs n`: go through the corpus n times (1 without it)
- `--allow-cloud`: needed when the provider isn't on this Mac. The corpus is sent to it; without the flag the bench refuses and exits with 77
- terms: a real dictation sends up to 40 entries of the vocabulary with its text. By default the bench sends 40 made-up ones in their place (product and company names such as Figma and Kubernetes), so the prompt is as long as the product's and nothing personal goes with a measurement
- `--with-terms`: send up to 40 entries of YOUR vocabulary (Dictation → Vocabulary in the app) instead, exactly as a dictation does
- `--no-terms`: send none. The prompt is then shorter than what the product sends
- `--no-deadline`: let a slow answer finish instead of cutting it at 2.5 s, so its time is measured

The first line it prints says which terms went (`synthetic`, `your vocabulary` or `none`) and how many.
The vocabulary is applied to the phrases on this Mac in every case.

Per phrase it prints the id, the milliseconds, the outcome, `raw` and the cleaned text; then the median
and the nearest-rank p90 of the milliseconds, and how many phrases ended each way (`applied`,
`unchanged`, `timeout`, `rejected: …`, `failed`, `skipped: …`).

The provider's key or session comes from the Keychain, as in the app. A properly signed build run from
Terminal can read it; an ad-hoc build can't, and for that one a key or a session can be passed in the
environment, `DAISY_BENCH_ANTHROPIC_KEY` for one's own Anthropic key or `DAISY_BENCH_SESSION` for the
Daisy Subscription. A session passed this way that the server refuses does not sign the app's own
account out.

```
DAISY_BENCH_ANTHROPIC_KEY=YOUR_KEY /Applications/Daisy.app/Contents/MacOS/Daisy --daisy-dictation-cleanup-bench scripts/dictation-cleanup/corpus.jsonl --allow-cloud
```

Exit codes: 0 done, 64 usage, 66 the corpus can't be read, 77 a cloud provider without `--allow-cloud`,
78 the provider can't be used (the reason is printed).

The code is `Daisy/DictationCleanupBench.swift`; what it measures is `Daisy/DictationCleanup.swift`
and the cleanup steps in `Daisy/DictationPaste.swift`.
