#!/usr/bin/env python3
"""Writes Daisy/Acknowledgements.txt — the licenses and notices of what
Daisy for Mac links and the models it downloads, shipped inside Daisy.app
(Egor 22.10; the iPhone build has had one since 1.0).

The libraries' texts come verbatim from the Swift package checkouts at the
revisions Package.resolved pins; the speaker models' NOTICE and LICENSE
from Daisy's mirror, checked against ModelsManifest.json's SHA-256. Run it
again whenever a package or a model changes — DaisyTests/
AcknowledgementsTests fails while the file names an older revision.

    scripts/acknowledgements.py [path/to/SourcePackages/checkouts]
"""
import hashlib
import json
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHECKOUTS = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "build/TestDD.noindex/SourcePackages/checkouts"
OUT = ROOT / "Daisy/Acknowledgements.txt"
RESOLVED = ROOT / "Daisy.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
MANIFEST = ROOT / "Daisy/ModelsManifest.json"
MIRROR = "https://models.mydaisy.io"

RULE = "=" * 72

pins = {p["identity"]: p["state"] for p in json.loads(RESOLVED.read_text())["pins"]}


def pinned(identity):
    state = pins[identity]
    return state.get("version") or state["revision"]


# Package identity → checkout folder; each must sit at its pinned revision,
# or the file would carry old texts under a new label.
FOLDERS = {"argmax-oss-swift": "argmax-oss-swift", "fluidaudio": "FluidAudio", "sparkle": "Sparkle", "sentry-cocoa": "sentry-cocoa"}
for identity, folder in FOLDERS.items():
    path = CHECKOUTS / folder
    head = subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    if head != pins[identity]["revision"]:
        sys.exit(f"error: {path} is at {head or 'nothing'}, Package.resolved pins {pins[identity]['revision']} — resolve packages first")


def read(*parts):
    # Leading newlines only: some texts open with indented lines.
    return (CHECKOUTS.joinpath(*parts)).read_text(encoding="utf-8").strip("\n").rstrip()


def mirror_file(repo, path):
    """A file from Daisy's mirror, only if it is the one the manifest pins."""
    entry = next((f for f in json.loads(MANIFEST.read_text())["files"] if f["repo"] == repo and f["path"] == path), None)
    if entry is None:
        sys.exit(f"error: {repo}/{path} isn't in ModelsManifest.json")
    return fetch(f"{MIRROR}/{repo}/resolve/main/{path}", entry["sha256"]), entry["revision"]


def fetch(url, sha256=None):
    # Cloudflare turns away urllib's default User-Agent.
    request = urllib.request.Request(url, headers={"User-Agent": "Daisy-acknowledgements/1"})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
    if sha256 and hashlib.sha256(data).hexdigest() != sha256:
        sys.exit(f"error: {url} doesn't match ModelsManifest.json")
    return data.decode("utf-8").strip("\n").rstrip()


def section(title, body):
    return f"\n\n\n{title}\n{RULE}\n\n{body}\n"


MIT_OPENAI = """MIT License

Copyright (c) 2022 OpenAI

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE."""

MIT_SILERO = MIT_OPENAI.replace("Copyright (c) 2022 OpenAI", "Copyright (c) 2020-present Silero Team")

INTRO = """Daisy for Mac — Acknowledgements

Daisy for Mac uses the open-source libraries and models below. Their authors
keep their rights; this credit doesn't mean they endorse Daisy. The same list,
with links, is at https://mydaisy.io/licenses.

The models are not part of the installer. Daisy downloads pinned copies from
its own mirror (models.mydaisy.io), unchanged, with Hugging Face at the same
pinned revision as the fallback, and checks each file's SHA-256 before use; if
both fail, the speech libraries' own Hugging Face download is the last resort:

- Whisper large-v3 — OpenAI, MIT. Core ML conversion by Argmax (WhisperKit), MIT.
  The tokenizer and configuration files (openai/whisper-large-v3) are
  redistributed under the Apache License, Version 2.0, as their repository
  declares; its full text is in the FluidAudio section below.
- Parakeet TDT 0.6B v3 — NVIDIA, CC BY 4.0
  (https://creativecommons.org/licenses/by/4.0/). Modified: Fluid Inference
  converted it to Core ML with palettized encoder weights
  (FluidInference/parakeet-tdt-0.6b-v3-coreml).
- pyannote segmentation-3.0 — CNRS, MIT. Converted to Core ML with fixed input
  shapes by Fluid Inference.
- WeSpeaker / pyannote wespeaker-voxceleb-resnet34-LM — CC BY 4.0. Modified by
  Fluid Inference (wespeaker_v2): fixed input shapes, a fused filter-bank front
  end and 8-bit palettized weights. Both speaker models:
  FluidInference/speaker-diarization-coreml; its NOTICE and LICENSE are below.
- Silero VAD — Silero Team, MIT. Core ML conversion by Fluid Inference.
- Nemotron 3.5 ASR Streaming Multilingual 0.6B — NVIDIA, OpenMDW 1.1
  (https://openmdw.ai/license/1-1/). Core ML conversion by Fluid Inference.
  Downloaded straight from Hugging Face, and only when the live dictation
  preview is on; Daisy doesn't redistribute it.

Each license's warranty disclaimer applies as written in it."""

parts = [INTRO]
parts.append(section(f"WhisperKit / Argmax OSS — MIT (revision {pinned('argmax-oss-swift')})", read("argmax-oss-swift", "LICENSE")))
parts.append(section("Argmax third-party notices, including Hugging Face swift-transformers", read("argmax-oss-swift", "NOTICES")))
parts.append(section(f"FluidAudio — Apache 2.0 (revision {pinned('fluidaudio')})", read("FluidAudio", "LICENSE")))
for notice in sorted((CHECKOUTS / "FluidAudio/ThirdPartyLicenses").glob("*.md")):
    parts.append(section(f"FluidAudio third-party license: {notice.stem.replace('-LICENSE', '')}", notice.read_text(encoding="utf-8").strip("\n").rstrip()))
# FluidAudio's NemoTextProcessing statically links Rust crates; all are
# MIT OR Apache-2.0 (Apache's text is above) except nom, MIT only.
parts.append(section("nom 7.1.3 (Rust, linked through FluidAudio's NemoTextProcessing) — MIT",
                     fetch("https://raw.githubusercontent.com/rust-bakery/nom/7.1.3/LICENSE")))
parts.append(section(f"Sparkle {pinned('sparkle')} — MIT and the licenses it includes", read("Sparkle", "LICENSE")))
parts.append(section(f"Sentry for Apple platforms (sentry-cocoa {pinned('sentry-cocoa')}) — MIT", read("sentry-cocoa", "LICENSE.md")))
parts.append(section("Sentry third-party notices", read("sentry-cocoa", "THIRD_PARTY_NOTICES.md")))
notice, revision = mirror_file("FluidInference/speaker-diarization-coreml", "NOTICE.md")
parts.append(section(f"Fluid Inference speaker models — NOTICE (revision {revision})", notice))
license_text, _ = mirror_file("FluidInference/speaker-diarization-coreml", "LICENSE")
parts.append(section(f"Fluid Inference speaker models — LICENSE (revision {revision})", license_text))
parts.append(section("OpenAI Whisper — MIT", MIT_OPENAI))
parts.append(section("Silero VAD — MIT", MIT_SILERO))

OUT.write_text("".join(parts).rstrip() + "\n", encoding="utf-8")
print(f"wrote {OUT.relative_to(ROOT)} ({OUT.stat().st_size} bytes)")
