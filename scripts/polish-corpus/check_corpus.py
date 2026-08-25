#!/usr/bin/env python3
"""Tuning harness for TranscriptPolisher's validation guards.

`DaisyTests/TranscriptPolisherCorpusTests.swift` is AUTHORITATIVE — it runs
`TranscriptPolisher.validate` itself against this same `corpus.json`. This
script is a faithful re-implementation of that function, and it exists for one
reason: threshold work needs a fast loop, and an Xcode build is not always
available (nor is it available from an agent sandbox at all).

So: use it to see where a proposed guard change lands, then land the change in
Swift and let the test suite be the gate. If the two ever disagree, the Swift
one is right and this file is stale.

    python3 scripts/polish-corpus/check_corpus.py            # calibrated rules
    python3 scripts/polish-corpus/check_corpus.py --raw      # pre-2026-08-25 rules
    python3 scripts/polish-corpus/check_corpus.py --verbose  # per-case reasons

The brand table is PARSED OUT of Daisy/BrandTransliterations.swift rather than
copied, so the harness can never drift from the list the app actually ships.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CORPUS = Path(__file__).resolve().parent / "corpus.json"
BRANDS_SWIFT = REPO / "Daisy" / "BrandTransliterations.swift"

# ── Guard constants — keep in step with TranscriptPolisher.swift ──────────
MAX_CHANGED_TOKEN_RATIO = 0.15
MAX_CHANGED_TOKEN_RATIO_PER_LINE = 0.5
PER_LINE_RATIO_MINIMUM_TOKENS = 4
MIN_TOKEN_LENGTH_FOR_TRANSLITERATION = 4
SANCTIONED_CREDIT_DIVISOR = 3
MAX_CREDIT_DISTANCE = 4


# ── Brand table ──────────────────────────────────────────────────────────

ENTRY_RE = re.compile(
    r'Entry\(latin:\s*"([^"]+)",\s*stems:\s*\[([^\]]*)\]\)', re.S
)
ENDINGS_RE = re.compile(
    r"caseEndings\s*=\s*\[(.*?)\]", re.S
)


def strip_non_alnum(s: str) -> str:
    return "".join(c for c in s if c.isalnum())


def load_case_endings(text: str) -> list[str]:
    """Parsed, not copied — see the module docstring."""
    match = ENDINGS_RE.search(text)
    if not match:
        raise SystemExit("BrandCorrections.caseEndings not found — harness is stale")
    return [""] + re.findall(r'"([^"]+)"', match.group(1))


def load_brand_folds() -> dict[str, str]:
    """token (lowercased) -> canonical fold key. Mirrors
    BrandCorrections.canonicalFolds, stems first, canonicals last."""
    text = BRANDS_SWIFT.read_text(encoding="utf-8")
    endings = load_case_endings(text)
    entries = [
        (latin, re.findall(r'"([^"]+)"', stems_raw))
        for latin, stems_raw in ENTRY_RE.findall(text)
    ]

    def key_for(latin: str):
        if " " in latin:
            return None
        stripped = strip_non_alnum(latin.lower())
        return stripped or None

    folds: dict[str, str] = {}
    for latin, stems in entries:
        canonical = key_for(latin)
        if canonical is None:
            continue
        for stem in stems:
            if not stem.isalnum():
                continue
            folds[stem] = canonical
            for ending in endings:
                folds[stem + ending] = canonical
    for latin, _ in entries:
        canonical = key_for(latin)
        if canonical is not None:
            folds[canonical] = canonical
    return folds


BRAND_FOLDS = load_brand_folds()


# ── Tokenizer (mirrors TranscriptPolisher.tokenize) ──────────────────────

UNSPACED_RANGES = [
    (0x0E00, 0x0EFF), (0x1000, 0x109F), (0x1780, 0x17FF),
    (0x3040, 0x30FF), (0x3400, 0x4DBF), (0x4E00, 0x9FFF),
    (0xF900, 0xFAFF),
]


def is_unspaced(ch: str) -> bool:
    cp = ord(ch)
    return any(lo <= cp <= hi for lo, hi in UNSPACED_RANGES)


def split_run(run: str) -> list[str]:
    if not any(is_unspaced(c) for c in run):
        return [run]
    tokens: list[str] = []
    word = ""
    for ch in run:
        if is_unspaced(ch):
            if word:
                tokens.append(word)
                word = ""
            tokens.append(ch)
        else:
            word += ch
    if word:
        tokens.append(word)
    return tokens


def tokenize(text: str) -> list[str]:
    runs = re.split(r"[^\w]|_", text.lower(), flags=re.UNICODE)
    out: list[str] = []
    for run in runs:
        if run:
            out.extend(split_run(run))
    return out


# ── Folding (the calibration) ────────────────────────────────────────────

TRANSLIT = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e",
    "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
    "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
    "ф": "f", "х": "h", "ц": "c", "ч": "ch", "ш": "sh", "щ": "sch",
    "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
}


def is_cyrillic(token: str) -> bool:
    letters = [c for c in token if c.isalpha()]
    if not letters:
        return False
    return all("CYRILLIC" in unicodedata.name(c, "") for c in letters)


def transliterate(token: str) -> str:
    return "".join(TRANSLIT.get(c, c) for c in token)


def fold(token: str) -> str:
    brand = BRAND_FOLDS.get(token)
    if brand:
        return brand
    if len(token) >= MIN_TOKEN_LENGTH_FOR_TRANSLITERATION and is_cyrillic(token):
        return transliterate(token)
    return token


def sanctioned_folds(context: dict) -> set[str]:
    terms = set(BRAND_FOLDS.values())
    for phrase in list(context.get("attendees", [])) + list(context.get("vocabulary", [])):
        for token in tokenize(phrase):
            terms.add(fold(token))
    return terms


# ── Plausibility of one substitution ─────────────────────────────────────

MAX_MERGE_WINDOW = 3
MIN_PLAUSIBLE_LENGTH = 3


def levenshtein(a: str, b: str) -> int:
    if a == b:
        return 0
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1,
                               previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def plausible(source: str, target: str) -> bool:
    """Could `source` be what an ASR engine heard instead of `target`?

    Transliterates unconditionally and per character: `source` can be a RUN
    of tokens joined together, and a run is routinely half-Latin already.
    """
    a, b = transliterate(source), transliterate(target)
    if not a or not b:
        return False
    if a == b:
        return True
    if min(len(a), len(b)) < MIN_PLAUSIBLE_LENGTH:
        return False
    tolerance = max(1, 2 * max(len(a), len(b)) // 5)
    if abs(len(a) - len(b)) > tolerance:
        return False
    return levenshtein(a, b) <= tolerance


# ── Polarity ─────────────────────────────────────────────────────────────

NEGATIONS = {
    "не", "нет", "ни", "никогда", "нельзя", "никак", "без",
    "not", "no", "never", "none", "nor", "without", "cannot",
}

# A bare "t" is what the tokenizer leaves of don't / can't / won't, but it
# also falls out of "T-Bank" and "T-shirt" — so it counts only after one of
# these.
CONTRACTION_STEMS = {
    "don", "doesn", "didn", "won", "can", "couldn", "shouldn", "wouldn",
    "isn", "aren", "wasn", "weren", "hasn", "haven", "hadn", "ain",
    "mustn", "needn", "shan",
}


def negation_count(tokens: list[str]) -> int:
    count = 0
    for i, t in enumerate(tokens):
        if t in NEGATIONS:
            count += 1
        elif t == "t" and i > 0 and tokens[i - 1] in CONTRACTION_STEMS:
            count += 1
    return count


# ── Diff ─────────────────────────────────────────────────────────────────

def unmatched_positions(tokens: list[str], pool: list[str]) -> list[int]:
    available: dict[str, int] = {}
    for t in pool:
        available[t] = available.get(t, 0) + 1
    missing: list[int] = []
    for i, t in enumerate(tokens):
        if available.get(t, 0) > 0:
            available[t] -= 1
        else:
            missing.append(i)
    return missing


def changed_token_count(before: list[str], after: list[str]) -> int:
    """The raw, unforgiving multiset diff. Unchanged since 1.0.7.56."""
    return max(len(unmatched_positions(before, after)),
               len(unmatched_positions(after, before)))


def correction_cost(before: list[str], after: list[str], sanctioned: set[str]) -> int:
    return correction_diff(before, after, sanctioned)[0]


def correction_diff(before: list[str], after: list[str], sanctioned: set[str]):
    """(cost, dropped_sanctioned_term) — see the Swift CorrectionDiff."""
    folded_before = [fold(t) for t in before]
    folded_after = [fold(t) for t in after]
    lost = unmatched_positions(folded_before, folded_after)
    gained = unmatched_positions(folded_after, folded_before)

    raw = max(len(lost), len(gained))
    cap = max(1, len(before) // SANCTIONED_CREDIT_DIVISOR)
    if (len(before) >= PER_LINE_RATIO_MINIMUM_TOKENS
            and (raw - cap) > MAX_CHANGED_TOKEN_RATIO_PER_LINE * len(before)):
        return raw, False

    credits = 0
    for gained_index in gained:
        if credits >= cap:
            break
        term = folded_after[gained_index]
        if term not in sanctioned:
            continue
        window = find_window(lost, gained_index, term, before, folded_before, sanctioned)
        if window is None:
            continue
        start, length = window
        del lost[start:start + length]
        credits += 1

    dropped_known = any(folded_before[i] in sanctioned for i in lost)
    return max(len(lost), len(gained) - credits), dropped_known


def contains_cyrillic(text: str) -> bool:
    return any(0x0400 <= ord(c) <= 0x04FF for c in text)


def is_run(positions: list[int]) -> bool:
    return all(b == a + 1 for a, b in zip(positions, positions[1:]))


def find_window(lost, gained_index, term, originals, folded, sanctioned):
    """Range of lost tokens that plausibly WAS `term`. See the Swift
    `mergeWindow` for why each condition is here."""
    if not lost:
        return None
    term_key = transliterate(term)
    for length in range(min(MAX_MERGE_WINDOW, len(lost)), 0, -1):
        for start in range(0, len(lost) - length + 1):
            positions = lost[start:start + length]
            if not is_run(positions):
                continue
            if abs(positions[0] - gained_index) > MAX_CREDIT_DISTANCE:
                continue
            original_run = "".join(originals[i] for i in positions)
            folded_run = "".join(folded[i] for i in positions)
            if folded_run in sanctioned and folded_run != term:
                continue
            cross_script = contains_cyrillic(original_run)
            exact_merge = length > 1 and transliterate(folded_run) == term_key
            if not (cross_script or exact_merge):
                continue
            if plausible(folded_run, term):
                return start, length
    return None


# ── validate() ───────────────────────────────────────────────────────────

def split_leading_number(line: str):
    digits = ""
    i = 0
    while i < len(line) and line[i].isdigit() and len(digits) < 6:
        digits += line[i]
        i += 1
    if not digits or i >= len(line) or line[i] not in ".)":
        return None
    return int(digits), line[i + 1:].strip()


def parse_numbered_lines(reply: str):
    result: dict[int, str] = {}
    current = None
    pending: list[str] = []
    for raw in reply.split("\n"):
        line = raw.strip()
        split = split_leading_number(line)
        if split:
            number, rest = split
            if current is not None and pending:
                parts = [result.get(current, "")] + pending
                result[current] = " ".join(p for p in parts if p)
                pending = []
            if number in result:
                return None
            result[number] = rest
            current = number
        elif current is not None and line:
            pending.append(line)
    if pending:
        return None
    return result or None


def validate(reply: str, lines: list[str], sanctioned: set[str], raw_rules: bool):
    """Returns (accepted_indices, reason). accepted_indices is None on a drop."""
    if not lines:
        return None, "empty chunk"
    parsed = parse_numbered_lines(reply)
    if parsed is None:
        return None, "unparseable reply"
    if len(parsed) != len(lines) or set(parsed.keys()) != set(range(1, len(lines) + 1)):
        return None, f"line count/numbering ({len(parsed)} for {len(lines)})"

    changed_tokens = 0
    total_tokens = 0
    accepted: list[int] = []

    for number in sorted(parsed):
        original = lines[number - 1]
        trimmed = parsed[number].strip()
        if not trimmed:
            return None, f"line {number} emptied"

        in_count, out_count = len(original), len(trimmed)
        if not (out_count * 2 + 20 >= in_count):
            return None, f"line {number} too short ({in_count}->{out_count})"
        if not (out_count <= in_count * 5 // 4 + 12):
            return None, f"line {number} too long ({in_count}->{out_count})"

        before, after = tokenize(original), tokenize(trimmed)
        if not before and after:
            return None, f"line {number} put words in a wordless line"

        if raw_rules:
            line_changed = changed_token_count(before, after)
        else:
            if negation_count(before) != negation_count(after):
                return None, f"line {number} changed polarity"
            line_changed, dropped_known = correction_diff(before, after, sanctioned)
            if dropped_known:
                return None, f"line {number} dropped a known name or product"

        if len(before) >= PER_LINE_RATIO_MINIMUM_TOKENS:
            if line_changed > MAX_CHANGED_TOKEN_RATIO_PER_LINE * len(before):
                return None, f"line {number} rewritten ({line_changed}/{len(before)} tokens)"

        total_tokens += len(before)
        changed_tokens += line_changed
        if trimmed != original:
            accepted.append(number)

    if total_tokens > 0:
        ratio = changed_tokens / total_tokens
        if ratio > MAX_CHANGED_TOKEN_RATIO:
            return None, f"chunk changed {ratio:.0%} of tokens (limit {MAX_CHANGED_TOKEN_RATIO:.0%})"
    return accepted, "accepted"


# ── Runner ───────────────────────────────────────────────────────────────

def render_reply(case: dict) -> str:
    if case.get("reply"):
        return case["reply"]
    return "\n".join(f"{i + 1}. {line}" for i, line in enumerate(case["polished"]))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", action="store_true",
                    help="score with the pre-calibration token diff")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args()

    corpus = json.loads(CORPUS.read_text(encoding="utf-8"))
    cases = corpus["cases"]

    by_lang: dict[str, list[bool]] = {}
    failures: list[tuple[dict, str]] = []
    leaks: list[tuple[dict, str]] = []

    for case in cases:
        sanctioned = sanctioned_folds(case.get("context", {}))
        accepted, reason = validate(
            render_reply(case), case["raw"], sanctioned, args.raw
        )
        got_accept = accepted is not None
        want_accept = case["expect"] == "accept"
        ok = got_accept == want_accept
        if want_accept:
            by_lang.setdefault(case["lang"], []).append(got_accept)
        if not ok:
            (failures if want_accept else leaks).append((case, reason))
        if args.verbose:
            mark = "ok  " if ok else "FAIL"
            print(f"{mark} {case['id']:<40} {reason}")

    valid = [c for c in cases if c["expect"] == "accept"]
    traps = [c for c in cases if c["expect"] == "drop"]
    passed_valid = len(valid) - len(failures)
    caught_traps = len(traps) - len(leaks)

    mode = "RAW (pre-calibration)" if args.raw else "CALIBRATED"
    print(f"\n── {mode} ──")
    print(f"valid chunks accepted : {passed_valid}/{len(valid)}"
          f" ({passed_valid / len(valid):.0%})")
    for lang in sorted(by_lang):
        results = by_lang[lang]
        print(f"    {lang:<6} {sum(results)}/{len(results)}"
              f" ({sum(results) / len(results):.0%})")
    print(f"traps caught          : {caught_traps}/{len(traps)}"
          f" ({caught_traps / len(traps):.0%})")

    if failures:
        print("\nvalid chunks REJECTED:")
        for case, reason in failures:
            print(f"  - {case['id']}: {reason}")
    if leaks:
        print("\nTRAPS THAT GOT THROUGH:")
        for case, reason in leaks:
            print(f"  - {case['id']}")

    ru = by_lang.get("ru", [])
    ru_rate = sum(ru) / len(ru) if ru else 0.0
    ok = ru_rate >= 0.8 and not leaks
    print(f"\nDoD: ru >= 80% and zero trap leaks -> {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
