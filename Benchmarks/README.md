# Daisy reproducible benchmark

This directory is the executable source of truth for product comparisons. It
keeps measurements separate from marketing copy and accepts the same neutral
hypothesis format from Daisy, Humla, OpenWhispr, or another app.

No competitor or Daisy accuracy number should be published until its input
audio, reference, app/model version, environment, raw hypothesis, and scorer
output can be reproduced from a manifest here.

## What is measured

- WER and CER after one shared Unicode normalization policy.
- DER and JER from RTTM, with speaker-label permutation, overlap scoring, and a
  declared boundary collar (0.25 seconds by default).
- Detected speaker count versus reference count.
- Capture completeness and processing real-time factor.
- Manual pass/fail checks for recovery, export/data ownership, and MCP.

WER and DER remain separate. A transcript can contain the right words and the
wrong speaker labels, or vice versa.

## Dataset contract

The full comparison suite is intentionally not committed because meeting audio
may be licensed or private. Put local material under `Benchmarks/datasets/` and
generated hypotheses under `Benchmarks/runs/`; both are ignored by git.

Each case must have:

1. an audio file and SHA-256;
2. a manually verified UTF-8 reference transcript for WER/CER cases (it may
   be omitted for an explicitly diarization-only public case);
3. RTTM speaker turns for diarization cases;
4. language, duration, speaker count, overlap/noise/capture tags;
5. consent or a public-data licence recorded in the private dataset manifest.

The target matrix is 15/60/180 minutes, EN/RU/RU↔EN, 2/4/6 speakers,
clean/noisy/overlap, and microphone plus system-audio capture. Public AMI or
another redistributable corpus can provide the reproducible layer; private real
meetings may be scored and published only as aggregates.

## Produce a Daisy hypothesis

The benchmark runner is isolated in `DaisyTests` so no benchmark-only surface
ships in the app. It invokes the same `AudioArchiveDecoder`, final Whisper
profile, and FluidAudio diarizer as the product:

```sh
cd daisy-app
./Benchmarks/run_daisy.sh \
  Benchmarks/datasets/case-001.wav \
  Benchmarks/runs/case-001/daisy-1.0.7.59.json \
  en 2
```

Omit the final speaker count to test Daisy's automatic count. Record both runs
when evaluating the attendee-count hint; do not mix them into one result.

By default the runner goes through the **production offline pipeline**
(`SessionAudioProcessing.transcribeChannel`: 900-second blocks, Whisper per
block, block diarization, merge by speaker) — the same code path behind
"Transcribe audio", crash recovery and the post-Stop final pass. The output
carries `"pipeline": "block"`. Set `DAISY_BENCHMARK_PATH=full` for the
whole-file shortcut (single Whisper call + `diarizeFull`, honours the speaker
count hint); it is labelled `"pipeline": "full"` and must not be published as
the product's number. Numbers from before 2026-09-09 were produced by the
`full` path.

Humla and OpenWhispr hypotheses must be exported into the same JSON shape:

```json
{
  "schema_version": 1,
  "product": "Example",
  "version": "1.2.3",
  "engine": "model and relevant settings",
  "audio_duration_seconds": 60.0,
  "processing_seconds": 12.4,
  "diarization_segments": [
    {"start": 0.0, "end": 2.4, "speaker": "A"}
  ],
  "segments": [
    {"start": 0.0, "end": 2.4, "speaker": "A", "text": "Hello"}
  ]
}
```

`diarization_segments` must contain the complete raw diarizer output, including
clusters that did not overlap an ASR segment. Otherwise an over-split can vanish
from the displayed transcript and make speaker-count/DER look better than the
engine actually was. The scorer falls back to transcript speaker spans only for
older adapters that cannot expose raw diarization.

Never hand-correct a hypothesis. Corrections belong in a separately named
"after manual cleanup" run.

## Score a suite

Copy `fixtures/manifest.json`, point its cases at the real references and raw
hypotheses, then run:

```sh
python3 Benchmarks/score.py Benchmarks/datasets/manifest.json \
  --json Benchmarks/reports/2026-08-17.json \
  --markdown Benchmarks/reports/2026-08-17.md
```

Validate the scorer itself with:

```sh
python3 -m unittest Benchmarks/test_score.py
python3 Benchmarks/score.py Benchmarks/fixtures/manifest.json
```

## Publication gate

Publish a comparison row only when all of these are present:

- raw app output and its SHA-256;
- exact app build, engine/model, settings, Mac, and OS;
- three warm measured runs for timing metrics;
- reference provenance and scoring configuration;
- failures and unavailable features shown as such, not removed from the mean.

Synthetic/TTS cases are harness smoke tests, never product accuracy evidence.

## Crash recovery, end to end

`Benchmarks/kill_recovery.sh [SECONDS] [OUTPUT_JSON]` launches the built app
with `--benchmark-record` (the app starts a microphone recording on its own),
waits, sends `kill -9`, relaunches, and waits for
`InterruptedRecordingRecovery` to write `transcript.md`. The report gives the
seconds recorded, the seconds of archive that survived on disk, the recovered
transcript's `duration_sec`, and the coverage ratio. The 40-minute run is the
published one; `120` is a smoke run. Play audio into the microphone while it
runs — the scenario measures survival, not accuracy.
