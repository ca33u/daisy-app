#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md

import sys
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

import score  # noqa: E402


class TextMetricTests(unittest.TestCase):
    def test_normalization_is_multilingual_and_punctuation_insensitive(self) -> None:
        self.assertEqual(score.normalize_text("Привет, DAISY!"), "привет daisy")

    def test_exact_word_error_rate(self) -> None:
        metric = score.error_rate("one two three", "one four three five")
        self.assertEqual(metric["errors"], 2)
        self.assertAlmostEqual(metric["rate"], 2 / 3)

    def test_exact_character_error_rate(self) -> None:
        metric = score.error_rate("кот", "кит", characters=True)
        self.assertEqual(metric["errors"], 1)
        self.assertAlmostEqual(metric["rate"], 1 / 3)


class DiarizationMetricTests(unittest.TestCase):
    def test_speaker_names_are_permutation_invariant(self) -> None:
        reference = [
            score.Segment(0, 2, "Alice"),
            score.Segment(2, 4, "Bob"),
        ]
        hypothesis = [
            score.Segment(0, 2, "B"),
            score.Segment(2, 4, "A"),
        ]
        metric = score.diarization_metrics(reference, hypothesis, duration=4, collar=0)
        self.assertIsNotNone(metric)
        self.assertEqual(metric["der"], 0)
        self.assertEqual(metric["jer"], 0)
        self.assertEqual(metric["mapping"], {"A": "Bob", "B": "Alice"})

    def test_missing_speech_is_counted(self) -> None:
        reference = [score.Segment(0, 4, "Alice")]
        hypothesis = [score.Segment(0, 2, "X")]
        metric = score.diarization_metrics(reference, hypothesis, duration=4, collar=0)
        self.assertAlmostEqual(metric["der"], 0.5)
        self.assertAlmostEqual(metric["miss_seconds"], 2.0)


class ManifestTests(unittest.TestCase):
    def test_fixture_scores_perfectly(self) -> None:
        report = score.score_manifest(ROOT / "fixtures" / "manifest.json", collar=0)
        result = report["results"][0]
        self.assertEqual(result["metrics"]["wer"]["rate"], 0)
        self.assertEqual(result["metrics"]["diarization"]["der"], 0)
        self.assertEqual(result["metrics"]["capture_completeness"], 1)
        self.assertEqual(result["metrics"]["real_time_factor"], 0.5)

    def test_diarization_only_case_does_not_require_transcript(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "reference.rttm").write_text(
                "SPEAKER case 1 0.0 2.0 <NA> <NA> speaker-a <NA> <NA>\n",
                encoding="utf-8",
            )
            (root / "hypothesis.json").write_text(
                json.dumps({
                    "product": "Daisy",
                    "audio_duration_seconds": 2,
                    "diarization_segments": [{"start": 0, "end": 2, "speaker": "A"}],
                    "segments": [],
                }),
                encoding="utf-8",
            )
            (root / "manifest.json").write_text(
                json.dumps({
                    "cases": [{
                        "id": "diarization-only",
                        "duration_seconds": 2,
                        "reference": {"rttm": "reference.rttm"},
                        "runs": [{"system": "Daisy", "hypothesis": "hypothesis.json"}],
                    }],
                }),
                encoding="utf-8",
            )

            report = score.score_manifest(root / "manifest.json", collar=0)
            result = report["results"][0]
            self.assertIsNone(result["metrics"]["wer"])
            self.assertIsNone(result["metrics"]["cer"])
            self.assertEqual(result["metrics"]["diarization"]["der"], 0)
            self.assertIn("| — | — | 0.00% |", score.render_markdown(report))


if __name__ == "__main__":
    unittest.main()
