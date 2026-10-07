#!/usr/bin/env python3
"""How long does a cloud model stay silent while it streams a long summary?

Daisy streams cloud summaries with an IDLE timeout (Anthropic 120 s; OpenAI,
Kimi and Gemini 300 s): the request fails only if no byte arrives for that
long. Reasoning models on chat completions stream nothing while they think,
so the question for a two-hour meeting is the longest silent stretch. This
sends a synthetic two-hour transcript the way Daisy does and prints the time
to first byte, the longest gap between chunks, the total time and the usage.

It costs one real summary request on YOUR key (roughly $0.05–0.30).

    python3 Benchmarks/stream_gaps.py          # the key Daisy saved, from the keychain
    OPENAI_API_KEY=sk-... python3 Benchmarks/stream_gaps.py
    OPENAI_API_KEY=sk-... python3 Benchmarks/stream_gaps.py --model gpt-5.6-sol --effort medium

Only the standard library; nothing is written to disk.
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request


def synthetic_transcript(minutes: int) -> str:
    speakers = ["Me", "Remote A", "Remote B"]
    lines = []
    for i in range(minutes * 10):  # a line every ~6 s
        m, s = divmod(i * 6, 60)
        lines.append(
            f"**[{m}:{s:02d} · {speakers[i % 3]}]** We went through the launch plan, "
            f"the budget and who owns the next step for item {i}."
        )
    return "\n\n".join(lines)


def keychain_key():
    """The key Daisy saved. Daisy keeps a copy in the login keychain too;
    macOS may ask once to allow `security` to read it."""
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", "app.essazanov.Daisy", "-a", "openai.api_key", "-w"],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return out.stdout.strip() or None


SYSTEM = (
    "You summarize meetings. Reply with JSON only: "
    '{"summary": str, "sections": [{"title": str, "bullets": [{"text": str, "children": []}]}], '
    '"actionItems": [str], "clientFollowUp": str}'
)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="gpt-5.6-terra")
    ap.add_argument("--effort", default="low", help="reasoning_effort (Daisy sends low)")
    ap.add_argument("--minutes", type=int, default=120)
    args = ap.parse_args()

    key = os.environ.get("OPENAI_API_KEY") or keychain_key()
    if not key or key == "sk-...":
        print("No OpenAI key: put yours in Daisy (Settings, Summary) or pass OPENAI_API_KEY=<your key>.", file=sys.stderr)
        return 2

    body = {
        "model": args.model,
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": "Title: Launch\n\n" + synthetic_transcript(args.minutes)},
        ],
        "response_format": {"type": "json_object"},
        "max_completion_tokens": 32000,
        "reasoning_effort": args.effort,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    request = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )

    start = time.monotonic()
    last = start
    first = None
    longest = 0.0
    usage = None
    finish = None
    chars = 0
    try:
        response = urllib.request.urlopen(request, timeout=600)
    except urllib.error.HTTPError as error:
        print(f"OpenAI answered HTTP {error.code}: {error.read().decode(errors='replace')[:500]}", file=sys.stderr)
        return 2
    with response:
        for raw in response:
            now = time.monotonic()
            longest = max(longest, now - last)
            last = now
            line = raw.decode().strip()
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                break
            chunk = json.loads(payload)
            if first is None:
                first = now - start
            usage = chunk.get("usage") or usage
            for choice in chunk.get("choices") or []:
                chars += len((choice.get("delta") or {}).get("content") or "")
                finish = choice.get("finish_reason") or finish

    total = time.monotonic() - start
    print(f"model {args.model}, reasoning_effort {args.effort}, {args.minutes}-minute transcript")
    print(f"first byte after   {first or 0:6.1f} s")
    print(f"longest silence    {longest:6.1f} s   (Daisy gives up after 300 s)")
    print(f"total              {total:6.1f} s, {chars} characters, finish_reason={finish}")
    print(f"usage              {json.dumps(usage)}")
    return 0 if longest < 300 else 1


if __name__ == "__main__":
    sys.exit(main())
