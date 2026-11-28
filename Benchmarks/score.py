#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
"""Score a neutral Daisy benchmark manifest without third-party packages.

The scorer is deliberately product-agnostic: Daisy, Humla, OpenWhispr, or
another system can emit the same small hypothesis JSON shape. It calculates
WER/CER, DER/JER, speaker-count accuracy, capture completeness, and real-time
factor, then writes machine-readable JSON and a reviewable Markdown table.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Hashable, Iterable, Sequence


WORD_RE = re.compile(r"[^\W_]+(?:['’][^\W_]+)*", re.UNICODE)


def normalize_text(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).casefold()
    return " ".join(WORD_RE.findall(text))


def levenshtein_distance(a: Sequence[Hashable], b: Sequence[Hashable]) -> int:
    """Exact Levenshtein distance using Myers' bit-vector algorithm.

    Python integers provide the bit-vector, keeping long meeting transcripts
    practical without an O(words²) matrix in memory.
    """
    if not a:
        return len(b)
    if not b:
        return len(a)
    if len(a) > len(b):
        a, b = b, a

    masks: dict[Hashable, int] = {}
    for i, symbol in enumerate(a):
        masks[symbol] = masks.get(symbol, 0) | (1 << i)

    score = len(a)
    highest = 1 << (len(a) - 1)
    positive = ~0
    negative = 0
    for symbol in b:
        equal = masks.get(symbol, 0)
        vertical = equal | negative
        horizontal = (((equal & positive) + positive) ^ positive) | equal
        positive_horizontal = negative | ~(horizontal | positive)
        negative_horizontal = positive & horizontal
        if positive_horizontal & highest:
            score += 1
        elif negative_horizontal & highest:
            score -= 1
        positive_horizontal = (positive_horizontal << 1) | 1
        negative_horizontal <<= 1
        positive = negative_horizontal | ~(vertical | positive_horizontal)
        negative = positive_horizontal & vertical
    return score


def error_rate(reference: str, hypothesis: str, *, characters: bool = False) -> dict[str, Any]:
    ref_normalized = normalize_text(reference)
    hyp_normalized = normalize_text(hypothesis)
    if characters:
        ref_units = list(ref_normalized.replace(" ", ""))
        hyp_units = list(hyp_normalized.replace(" ", ""))
    else:
        ref_units = ref_normalized.split()
        hyp_units = hyp_normalized.split()
    edits = levenshtein_distance(ref_units, hyp_units)
    return {
        "errors": edits,
        "reference_units": len(ref_units),
        "rate": (edits / len(ref_units)) if ref_units else (0.0 if not hyp_units else 1.0),
    }


@dataclass(frozen=True)
class Segment:
    start: float
    end: float
    speaker: str
    text: str = ""


def parse_rttm(path: Path) -> list[Segment]:
    segments: list[Segment] = []
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 8 or parts[0].upper() != "SPEAKER":
            raise ValueError(f"{path}:{line_number}: expected an RTTM SPEAKER row")
        start = float(parts[3])
        duration = float(parts[4])
        if duration <= 0:
            continue
        segments.append(Segment(start, start + duration, parts[7]))
    return sorted(segments, key=lambda item: (item.start, item.end, item.speaker))


def _json_segments(path: Path, raw_segments: Iterable[dict[str, Any]], *, allow_text: bool) -> list[Segment]:
    segments: list[Segment] = []
    for index, raw in enumerate(raw_segments):
        try:
            start = float(raw["start"])
            end = float(raw["end"])
        except (KeyError, TypeError, ValueError) as error:
            raise ValueError(f"{path}: segment {index} has invalid start/end") from error
        if end <= start:
            continue
        speaker = str(raw.get("speaker") or "unknown")
        segments.append(Segment(start, end, speaker, str(raw.get("text") or "") if allow_text else ""))
    return sorted(segments, key=lambda item: (item.start, item.end, item.speaker))


def parse_hypothesis(path: Path) -> tuple[dict[str, Any], list[Segment], list[Segment]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    transcript = _json_segments(path, payload.get("segments", []), allow_text=True)
    diarization = _json_segments(path, payload.get("diarization_segments", []), allow_text=False)
    if not diarization:
        diarization = [item for item in transcript if item.speaker != "unknown"]
    return payload, transcript, diarization


def _best_mapping(weights: dict[tuple[str, str], float], hypotheses: list[str], references: list[str]) -> dict[str, str]:
    if not hypotheses or not references:
        return {}
    if len(references) > 16:
        # Pathological over-splitting should not make the scorer explode.
        available = set(references)
        mapping: dict[str, str] = {}
        for hyp in hypotheses:
            if not available:
                break
            ref = max(available, key=lambda candidate: weights.get((hyp, candidate), 0.0))
            mapping[hyp] = ref
            available.remove(ref)
        return mapping

    states: dict[int, tuple[float, dict[str, str]]] = {0: (0.0, {})}
    for hyp in hypotheses:
        next_states = dict(states)  # leaving an extra hypothesis unmapped is valid
        for mask, (score, mapping) in states.items():
            for index, ref in enumerate(references):
                bit = 1 << index
                if mask & bit:
                    continue
                candidate_score = score + weights.get((hyp, ref), 0.0)
                existing = next_states.get(mask | bit)
                if existing is None or candidate_score > existing[0]:
                    candidate = dict(mapping)
                    candidate[hyp] = ref
                    next_states[mask | bit] = (candidate_score, candidate)
        states = next_states
    return max(states.values(), key=lambda item: item[0])[1]


def diarization_metrics(
    reference: list[Segment],
    hypothesis: list[Segment],
    *,
    duration: float,
    collar: float,
) -> dict[str, Any] | None:
    if not reference:
        return None

    events: dict[float, dict[str, list[str] | int]] = {}

    def event(time: float) -> dict[str, list[str] | int]:
        time = min(duration, max(0.0, time))
        return events.setdefault(time, {"ref_add": [], "ref_remove": [], "hyp_add": [], "hyp_remove": [], "exclude": 0})

    for segment in reference:
        event(segment.start)["ref_add"].append(segment.speaker)  # type: ignore[union-attr]
        event(segment.end)["ref_remove"].append(segment.speaker)  # type: ignore[union-attr]
        if collar > 0:
            event(segment.start - collar)["exclude"] += 1  # type: ignore[operator]
            event(segment.start + collar)["exclude"] -= 1  # type: ignore[operator]
            event(segment.end - collar)["exclude"] += 1  # type: ignore[operator]
            event(segment.end + collar)["exclude"] -= 1  # type: ignore[operator]
    for segment in hypothesis:
        event(segment.start)["hyp_add"].append(segment.speaker)  # type: ignore[union-attr]
        event(segment.end)["hyp_remove"].append(segment.speaker)  # type: ignore[union-attr]
    event(0.0)
    event(duration)

    active_ref: dict[str, int] = {}
    active_hyp: dict[str, int] = {}
    excluded = 0
    atomic: list[tuple[float, set[str], set[str]]] = []
    weights: dict[tuple[str, str], float] = {}
    times = sorted(events)
    for index, time in enumerate(times[:-1]):
        payload = events[time]
        for speaker in payload["ref_remove"]:  # type: ignore[union-attr]
            active_ref[speaker] = max(0, active_ref.get(speaker, 0) - 1)
        for speaker in payload["hyp_remove"]:  # type: ignore[union-attr]
            active_hyp[speaker] = max(0, active_hyp.get(speaker, 0) - 1)
        for speaker in payload["ref_add"]:  # type: ignore[union-attr]
            active_ref[speaker] = active_ref.get(speaker, 0) + 1
        for speaker in payload["hyp_add"]:  # type: ignore[union-attr]
            active_hyp[speaker] = active_hyp.get(speaker, 0) + 1
        excluded += int(payload["exclude"])
        delta = times[index + 1] - time
        if delta <= 0 or excluded > 0:
            continue
        refs = {speaker for speaker, count in active_ref.items() if count > 0}
        hyps = {speaker for speaker, count in active_hyp.items() if count > 0}
        atomic.append((delta, refs, hyps))
        for hyp in hyps:
            for ref in refs:
                weights[(hyp, ref)] = weights.get((hyp, ref), 0.0) + delta

    ref_speakers = sorted({segment.speaker for segment in reference})
    hyp_speakers = sorted({segment.speaker for segment in hypothesis if segment.speaker != "unknown"})
    mapping = _best_mapping(weights, hyp_speakers, ref_speakers)

    miss = false_alarm = confusion = reference_time = 0.0
    intersection = {ref: 0.0 for ref in ref_speakers}
    union = {ref: 0.0 for ref in ref_speakers}
    reverse_mapping = {ref: hyp for hyp, ref in mapping.items()}
    for delta, refs, hyps in atomic:
        reference_time += len(refs) * delta
        correct = sum(1 for hyp in hyps if mapping.get(hyp) in refs)
        miss += max(0, len(refs) - len(hyps)) * delta
        false_alarm += max(0, len(hyps) - len(refs)) * delta
        confusion += (min(len(refs), len(hyps)) - correct) * delta
        for ref in ref_speakers:
            ref_active = ref in refs
            hyp_active = reverse_mapping.get(ref) in hyps
            if ref_active and hyp_active:
                intersection[ref] += delta
            if ref_active or hyp_active:
                union[ref] += delta

    der = (miss + false_alarm + confusion) / reference_time if reference_time else None
    per_speaker_jer = [1.0 - intersection[ref] / union[ref] for ref in ref_speakers if union[ref] > 0]
    return {
        "der": der,
        "jer": (sum(per_speaker_jer) / len(per_speaker_jer)) if per_speaker_jer else None,
        "miss_seconds": miss,
        "false_alarm_seconds": false_alarm,
        "confusion_seconds": confusion,
        "reference_speaker_seconds": reference_time,
        "reference_speakers": len(ref_speakers),
        "detected_speakers": len(hyp_speakers),
        "speaker_count_correct": len(ref_speakers) == len(hyp_speakers),
        "mapping": mapping,
        "collar_seconds": collar,
    }


def _resolve(base: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else base / path


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def score_manifest(path: Path, collar: float) -> dict[str, Any]:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    base = path.parent
    results: list[dict[str, Any]] = []
    for case in manifest.get("cases", []):
        reference_config = case["reference"]
        reference_text_path = _resolve(base, reference_config["text"]) if reference_config.get("text") else None
        reference_text = reference_text_path.read_text(encoding="utf-8") if reference_text_path else None
        rttm_path = _resolve(base, reference_config["rttm"]) if reference_config.get("rttm") else None
        reference_segments = parse_rttm(rttm_path) if rttm_path else []
        duration = float(case.get("duration_seconds") or max((item.end for item in reference_segments), default=0.0))

        for run in case.get("runs", []):
            hypothesis_path = _resolve(base, run["hypothesis"])
            payload, hypothesis_segments, hypothesis_diarization = parse_hypothesis(hypothesis_path)
            hypothesis_text = " ".join(item.text for item in hypothesis_segments)
            processing_seconds = run.get("processing_seconds", payload.get("processing_seconds"))
            captured_duration = run.get("capture", {}).get("captured_duration_seconds", payload.get("audio_duration_seconds"))
            metrics = {
                "wer": error_rate(reference_text, hypothesis_text) if reference_text is not None else None,
                "cer": error_rate(reference_text, hypothesis_text, characters=True) if reference_text is not None else None,
                "diarization": diarization_metrics(
                    reference_segments,
                    hypothesis_diarization,
                    duration=duration,
                    collar=collar,
                ) if rttm_path else None,
                "capture_completeness": (float(captured_duration) / duration) if captured_duration is not None and duration > 0 else None,
                "real_time_factor": (float(processing_seconds) / duration) if processing_seconds is not None and duration > 0 else None,
            }
            results.append({
                "case_id": case["id"],
                "language": case.get("language"),
                "duration_seconds": duration,
                "system": run.get("system", payload.get("product", "unknown")),
                "version": run.get("version", payload.get("version", "unknown")),
                "engine": run.get("engine", payload.get("engine")),
                "hypothesis": str(hypothesis_path.relative_to(base) if hypothesis_path.is_relative_to(base) else hypothesis_path),
                "hypothesis_sha256": _sha256(hypothesis_path),
                "metrics": metrics,
                "checks": {
                    "recoverability": run.get("recoverability", "not_tested"),
                    "export": run.get("export", "not_tested"),
                    "data_ownership": run.get("data_ownership", "not_tested"),
                    "mcp": run.get("mcp", "not_tested"),
                },
                "notes": run.get("notes"),
            })
    return {
        "schema_version": 1,
        "suite": manifest.get("suite", {}),
        "scoring": {
            "text_normalization": "Unicode NFKC, casefold, punctuation removed, whitespace collapsed",
            "diarization_collar_seconds": collar,
            "overlap_scored": True,
        },
        "results": results,
    }


def _percent(value: float | None) -> str:
    return "—" if value is None else f"{value * 100:.2f}%"


def render_markdown(report: dict[str, Any]) -> str:
    suite = report.get("suite", {})
    lines = [f"# {suite.get('name', 'Benchmark report')}", ""]
    if suite.get("date"):
        lines.append(f"Measured: {suite['date']}")
    if suite.get("environment"):
        environment = suite["environment"]
        lines.append(f"Environment: {environment.get('machine', 'unknown')} · {environment.get('os', 'unknown')}")
    lines += ["", "| Case | System | WER | CER | DER | JER | Speakers | Capture | RTF |", "|---|---|---:|---:|---:|---:|---:|---:|---:|"]
    for result in report["results"]:
        metrics = result["metrics"]
        diarization = metrics.get("diarization")
        speakers = "—"
        der = jer = None
        if diarization:
            speakers = f"{diarization['detected_speakers']}/{diarization['reference_speakers']}"
            der = diarization["der"]
            jer = diarization["jer"]
        rtf = metrics.get("real_time_factor")
        lines.append(
            f"| {result['case_id']} | {result['system']} {result['version']} | "
            f"{_percent(metrics['wer']['rate'] if metrics['wer'] else None)} | "
            f"{_percent(metrics['cer']['rate'] if metrics['cer'] else None)} | "
            f"{_percent(der)} | {_percent(jer)} | {speakers} | "
            f"{_percent(metrics.get('capture_completeness'))} | "
            f"{'—' if rtf is None else f'{rtf:.3f}×'} |"
        )
    lines += ["", f"DER uses a {report['scoring']['diarization_collar_seconds']:.2f}s collar and scores overlap.", ""]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--json", dest="json_output", type=Path)
    parser.add_argument("--markdown", dest="markdown_output", type=Path)
    parser.add_argument("--collar", type=float, default=0.25)
    args = parser.parse_args()
    if args.collar < 0:
        parser.error("--collar must be non-negative")
    try:
        report = score_manifest(args.manifest.resolve(), args.collar)
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"benchmark scoring failed: {error}", file=sys.stderr)
        return 2
    rendered = render_markdown(report)
    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if args.markdown_output:
        args.markdown_output.parent.mkdir(parents=True, exist_ok=True)
        args.markdown_output.write_text(rendered, encoding="utf-8")
    if not args.json_output and not args.markdown_output:
        print(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
