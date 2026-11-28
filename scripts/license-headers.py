#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
"""Puts the license header on Daisy's own source files — the two lines
NOTICE.md promises («Source files carry an SPDX line»):

    SPDX-License-Identifier: AGPL-3.0-only
    Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md

Swift and C-family files get them as `//` lines at the very top, Python and
shell as `#` lines. A line that has to stay first stays first: a shebang,
a Python coding line (PEP 263), `// swift-tools-version` in a Package.swift.
The rest of the file is left as it was, and a file that already has the
header is not written at all. When the header's text changes here (a new
year in the copyright line), an older header of ours is replaced in place.

The files are the ones git knows in this checkout: tracked, and new ones
not yet added (ignored ones are not). Data and assets are out by their
extension; build output, package checkouts, vendored code and hidden
folders by their path (SKIPPED_FOLDERS: third-party source goes into one
of those). As a net under that, a file whose opening comment names someone
else's copyright, or that names another license, is not touched and is
listed. A file with our SPDX line somewhere below the top is an error to
fix by hand, not a place for a second header.

    scripts/license-headers.py           add the header where it is missing,
                                         replace an older one of ours
    scripts/license-headers.py --check   change nothing; list the files
                                         without the current header, exit 1

DaisyTests/AboutLegalTests (everySourceFileCarriesTheLicenseHeader) holds
every Swift file outside SKIPPED_FOLDERS and hidden folders to it; it reads
that list from this file.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

HEADER = ("SPDX-License-Identifier: AGPL-3.0-only",
          "Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md")
SPDX_ID = "AGPL-3.0-only"
OURS = ("Egor Sazanov", "addicted")

SLASH = {".swift", ".h", ".m", ".mm", ".c", ".cpp", ".metal"}
HASH = {".py", ".sh"}
# An extensionless file is a script only if its shebang names one of these.
INTERPRETERS = {"sh", "bash", "zsh", "python", "python3"}

# Build output, package checkouts and vendored code, wherever they sit.
# Hidden folders (.build, .swiftpm, .claude, .github) are out as well.
# AboutLegalTests reads the names between the braces: keep them plain
# double-quoted strings.
SKIPPED_FOLDERS = {"build", "DerivedData", "SourcePackages", "checkouts", "Pods", "Carthage",
                   "node_modules", "vendor", "Vendor", "ThirdParty", "third_party", "__pycache__"}

SHEBANG = re.compile(rb"#!\s*(\S+)(?:\s+(\S+))?")
# PEP 263, as Python itself reads it: on line 1, or on line 2 under a line
# that is a comment or blank.
CODING = re.compile(rb"[ \t\f]*#.*?coding[:=][ \t]*[-_.a-zA-Z0-9]+")
COMMENT_OR_BLANK = re.compile(rb"[ \t\f]*(#.*)?$")
TOOLS_VERSION = re.compile(rb"//\s*swift-tools-version", re.IGNORECASE)
COPYRIGHT = re.compile(r"copyright\s*(\(c\)|©|\d{4})", re.IGNORECASE)
SPDX = re.compile(r"SPDX-License-Identifier:\s*([A-Za-z0-9.+-]+(?:\s+(?:OR|AND|WITH)\s+[A-Za-z0-9.+-]+)*)")
# An SPDX line this far down is still a header; further down it is a string.
SPDX_REACH = 30


def candidates():
    """Paths git knows here, relative to the repository root."""
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                         capture_output=True, check=True).stdout
    return sorted(set(p.decode("utf-8") for p in out.split(b"\0") if p))


def interpreter(first_line):
    """`python3` for `#!/usr/bin/env python3`, `zsh` for `#!/bin/zsh`."""
    match = SHEBANG.match(first_line)
    if not match:
        return None
    program = match.group(1).rsplit(b"/", 1)[-1]
    if program == b"env" and match.group(2):
        program = match.group(2)
    return program.decode("ascii", "replace")


def language(path, data):
    """(comment mark, is it Python); the mark is None for a file that is
    not source."""
    suffix = Path(path).suffix
    if suffix in SLASH:
        return "//", False
    if suffix in HASH:
        return "#", suffix == ".py"
    program = interpreter(data.split(b"\n", 1)[0]) if suffix == "" else None
    if program in INTERPRETERS:
        return "#", program.startswith("python")
    return None, False


def pinned_lines(lines, mark, python):
    """How many leading lines must stay above the header."""
    if not lines:
        return 0
    if mark == "//":
        return 1 if TOOLS_VERSION.match(lines[0]) else 0
    if python:
        if len(lines) > 1 and CODING.match(lines[1]) and COMMENT_OR_BLANK.match(lines[0].rstrip(b"\r\n")):
            return 2
        if CODING.match(lines[0]):
            return 1
    return 1 if lines[0].startswith(b"#!") else 0


def older_header(pair, mark):
    """Is this pair of lines a header of ours with another text: an SPDX
    line, then a `Copyright ©` line that names us."""
    if len(pair) < 2:
        return False
    first, second = (line.decode("utf-8", "replace").rstrip("\r\n") for line in pair)
    return (first.startswith(f"{mark} SPDX-License-Identifier: ")
            and second.startswith(f"{mark} Copyright © ")
            and any(name in second for name in OURS))


def opening_comment(lines, mark):
    """The comment the file opens with, as text lines: where a header of
    someone else's would be. Strings further down (a license text a script
    writes out) are not it."""
    block, inside = [], False
    for raw in lines[:80]:
        line = raw.decode("utf-8", "replace").strip()
        if inside:
            block.append(line)
            inside = "*/" not in line
        elif not line or line.startswith(mark):
            block.append(line)
        elif mark == "//" and line.startswith("/*"):
            block.append(line)
            inside = "*/" not in line
        else:
            break
    return block


def examine(path):
    """(state, detail, new bytes). The state is one of: `skip` (not source),
    `ok`, `missing`, `outdated`, `foreign`, `misplaced`."""
    file = ROOT / path
    if file.is_symlink() or not file.is_file():
        return "skip", None, None
    data = file.read_bytes()
    mark, python = language(path, data)
    if mark is None:
        return "skip", None, None
    bom = b"\xef\xbb\xbf" if data.startswith(b"\xef\xbb\xbf") else b""
    lines = data[len(bom):].splitlines(keepends=True)
    newline = b"\r\n" if lines and lines[0].endswith(b"\r\n") else b"\n"
    header = [f"{mark} {text}".encode("utf-8") for text in HEADER]
    at = pinned_lines(lines, mark, python)
    if [line.rstrip(b"\r\n") for line in lines[at:at + 2]] == header:
        return "ok", None, None
    if older_header(lines[at:at + 2], mark):
        lines[at:at + 2] = [line + newline for line in header]
        return "outdated", None, bom + b"".join(lines)

    for line in opening_comment(lines[at:], mark):
        if COPYRIGHT.search(line) and not any(name in line for name in OURS):
            return "foreign", f"carries someone else's copyright ({line.lstrip('/#* ').strip()})", None
    for number, raw in enumerate(lines[at:at + SPDX_REACH], start=at + 1):
        spdx = SPDX.search(raw.decode("utf-8", "replace"))
        if spdx and spdx.group(1) != SPDX_ID:
            return "foreign", f"is under {spdx.group(1)}", None
        if spdx:
            return "misplaced", f"has an SPDX line at line {number}, not at the top: move the header up by hand", None

    if at and not lines[at - 1].endswith((b"\n", b"\r")):
        lines[at - 1] += newline
    lines[at:at] = [line + newline for line in header]
    return "missing", None, bom + b"".join(lines)


def main():
    arguments = sys.argv[1:]
    if arguments in (["--help"], ["-h"]):
        print(__doc__)
        return
    if arguments not in ([], ["--check"]):
        sys.exit("usage: scripts/license-headers.py [--check]")
    check = arguments == ["--check"]

    marked, missing, outdated, foreign_files, misplaced = {}, [], [], [], []
    for path in candidates():
        parts = Path(path).parts
        if any(part.startswith(".") or part in SKIPPED_FOLDERS for part in parts[:-1]):
            continue
        state, detail, new = examine(path)
        if state == "missing":
            missing.append(path)
            if not check:
                (ROOT / path).write_bytes(new)
                kind = Path(path).suffix or "script"
                marked[kind] = marked.get(kind, 0) + 1
        elif state == "outdated":
            outdated.append(path)
            if not check:
                (ROOT / path).write_bytes(new)
        elif state == "foreign":
            foreign_files.append((path, detail))
        elif state == "misplaced":
            misplaced.append((path, detail))

    for path, detail in foreign_files:
        print(f"left alone: {path} {detail}")
    for path, detail in misplaced:
        print(f"error: {path} {detail}", file=sys.stderr)
    if check:
        for path in missing:
            print(f"no license header: {path}", file=sys.stderr)
        for path in outdated:
            print(f"older license header: {path}", file=sys.stderr)
        if missing or outdated:
            print(f"files without the current license header: {len(missing) + len(outdated)}"
                  " — run scripts/license-headers.py", file=sys.stderr)
    else:
        if marked:
            by_kind = ", ".join(f"{count} {kind}" for kind, count in sorted(marked.items()))
            print(f"header added to {sum(marked.values())} files ({by_kind})")
        if outdated:
            print(f"header replaced in {len(outdated)} files")
        if not marked and not outdated:
            print("every source file already has the header")
    sys.exit(1 if misplaced or (check and (missing or outdated)) else 0)


if __name__ == "__main__":
    main()
