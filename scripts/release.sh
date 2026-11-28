#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
#
# release.sh — build, notarise, sign for Sparkle, and deploy a new
# Daisy release to mydaisy.io.
#
# This is the post-launch release flow. Before running it once, do
# the bootstrap steps (documented in the private vault:
# business/projects/daisy/playbook-release-bootstrap.md):
#   • Sparkle SPM dependency added in Xcode
#   • EdDSA key pair generated (private in Keychain, public in
#     Info.plist as SUPublicEDKey)
#   • SUFeedURL set to https://mydaisy.io/appcast.xml
#   • Notary credentials stored as a keychain profile named
#     "daisy-notary" via xcrun notarytool store-credentials
#   • Developer ID Application certificate present in the login
#     keychain
#   • daisy-web available as the parent checkout, a sibling checkout,
#     or through DAISY_WEB_REPO
#
# Usage:
#   ./scripts/release.sh 1.0.1 3
#                        ^^^^^ ^
#                        |     |
#                        |     CFBundleVersion (build number, monotonic)
#                        CFBundleShortVersionString (marketing version)
#
#   ./scripts/release.sh promote 1.0.1         (beta → stable, + GitHub Release)
#   ./scripts/release.sh github-release 1.0.1  (GitHub Release only)
#   ./scripts/release.sh upload-dmg build/Daisy-1.0.1.dmg 3  (R2 upload only)
#
# The publish step uploads the DMG to R2, injects the appcast item, updates
# the channel pointer, and commits daisy-web. It also commits the pbxproj
# bump here and tags it v<version>: the source of the build, which the
# appcast and the site link to. DAISY_AUTO_PUSH=1 pushes that tag and then,
# once the tag is on GitHub, daisy-web.
#
# Exit status: 0 published (or, without DAISY_AUTO_PUSH, ready with the
# commands printed); 1 stopped before anything was published or uploaded;
# 2 NOT published although the DMG is uploaded: the site push was held or
# refused, and the commands that finish the release are printed.
#

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration — adjust if your local paths differ.
# -----------------------------------------------------------------------------

DAISY_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Prefer an explicit override. The current workspace nests daisy-app inside the
# daisy-web checkout; standalone clones commonly use a lowercase sibling.
if [[ -n "${DAISY_WEB_REPO:-}" ]]; then
    DAISY_WEB_REPO="$(cd "${DAISY_WEB_REPO}" && pwd)"
elif [[ -f "${DAISY_REPO}/../public/appcast.xml" && -f "${DAISY_REPO}/../package.json" ]]; then
    DAISY_WEB_REPO="$(cd "${DAISY_REPO}/.." && pwd)"
elif [[ -f "${DAISY_REPO}/../daisy-web/public/appcast.xml" ]]; then
    DAISY_WEB_REPO="$(cd "${DAISY_REPO}/../daisy-web" && pwd)"
else
    echo "Could not locate daisy-web. Set DAISY_WEB_REPO to its checkout." >&2
    exit 1
fi
SCHEME="Daisy"
CONFIGURATION="Release"
TEAM_ID="${DAISY_TEAM_ID:-LW64FQXZCU}"  # Apple Developer team ID; override via DAISY_TEAM_ID env var
SIGNING_IDENTITY="${DAISY_SIGNING_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="daisy-notary"
APPCAST_URL="https://mydaisy.io/appcast.xml"
# The public address of every DMG: the appcast, the site's buttons and old
# links all use it. Since 2026-11-04 the files are not in daisy-web's git
# (2.6 GB had Vercel's clone take 13 min): they live in Cloudflare R2, the
# models bucket under downloads/, and mydaisy.io/downloads/* redirects there
# (daisy-web next.config.mjs). Moving storage again is that one redirect.
DOWNLOAD_URL_BASE="https://mydaisy.io/downloads"
R2_DOWNLOADS_URL="https://models.mydaisy.io/downloads"

# -----------------------------------------------------------------------------
# notarise_with_retry <path> <human-label>
#
# `xcrun notarytool submit --wait` can fail mid-flight on Apple's
# gateway (5xx / transient connection drops) without any way for the
# caller to know whether the submission ever reached the server.
# Pre-1.0.3 this aborted the whole release run after 3-5 minutes of
# archive + sign work. Now: 3 attempts with 60s / 180s / 360s backoff.
# On final failure, surface the underlying notarytool exit code and
# log so the user can diagnose.
# -----------------------------------------------------------------------------
notarise_with_retry() {
    local artifact="$1"
    local label="$2"
    local attempt
    local delay
    for attempt in 1 2 3; do
        if xcrun notarytool submit "${artifact}" \
            --keychain-profile "${NOTARY_PROFILE}" \
            --wait; then
            return 0
        fi
        if [[ ${attempt} -lt 3 ]]; then
            case ${attempt} in
                1) delay=60 ;;
                2) delay=180 ;;
                *) delay=360 ;;
            esac
            echo "  ⚠ notarytool failed for ${label} (attempt ${attempt}/3). Retrying in ${delay}s…" >&2
            sleep "${delay}"
        fi
    done
    echo "  ✗ notarytool failed for ${label} after 3 attempts. Aborting." >&2
    return 1
}

# -----------------------------------------------------------------------------
# upload_dmg <dmg> <build>
#
# Puts Daisy-<version>.dmg into R2 at downloads/<build>/<name> — the address
# the appcast item and the site's buttons use — and, for the first build of
# a version, at downloads/<name> too (older links). Objects are never
# overwritten: a re-released version gets a new build path while the live
# appcast still points at the previous one, so Sparkle can't get one
# build's bytes under another build's EdDSA signature, and no cache can
# hold stale bytes. Fails unless the public copy has the same size and
# SHA-256, so the release stops here, before the appcast is touched.
#
# Same bucket, Keychain record and pinned packages as scripts/models_sync.py
# (models_sync.py.lock); the secret goes from the Keychain into boto3 only,
# never into an argument or this script's output.
# -----------------------------------------------------------------------------
upload_dmg() {
    UV_CACHE_DIR="${DAISY_REPO}/build/uv-cache" \
    R2_DOWNLOADS_URL="${R2_DOWNLOADS_URL}" \
    uv run --quiet --no-project \
        --with boto3==1.43.112 --with botocore==1.43.112 --with s3transfer==0.19.2 \
        --with jmespath==1.1.0 --with python-dateutil==2.9.0.post0 --with six==1.17.0 \
        --with urllib3==2.8.0 \
        python3 - "$@" <<'PY'
import hashlib, json, os, re, subprocess, sys, time
from pathlib import Path
from urllib.request import Request, urlopen

import boto3
from botocore.config import Config

BUCKET = "daisy-models"
PUBLIC = os.environ["R2_DOWNLOADS_URL"]


def client():
    result = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "io.mydaisy.models.r2",
                             "-a", "daisy-models", "-w"], capture_output=True, timeout=120)
    if result.returncode:
        sys.exit("  ✗ R2 credentials unavailable in the Keychain (io.mydaisy.models.r2) — unlock or allow access")
    credentials = json.loads(result.stdout)
    if (credentials["bucket"] != BUCKET or
            not re.fullmatch(r"https://[0-9a-f]{32}\.eu\.r2\.cloudflarestorage\.com", credentials["endpoint"])):
        sys.exit("  ✗ Keychain R2 bucket or EU endpoint invalid")
    return boto3.client("s3", endpoint_url=credentials["endpoint"], region_name="auto",
                        aws_access_key_id=credentials["accessKeyID"],
                        aws_secret_access_key=credentials["secretAccessKey"],
                        config=Config(signature_version="s3v4", s3={"addressing_style": "path"},
                                      connect_timeout=10, read_timeout=60,
                                      request_checksum_calculation="when_required",
                                      response_checksum_validation="when_required",
                                      retries={"max_attempts": 3, "mode": "standard"}))


def digest(chunks):
    sha256, size = hashlib.sha256(), 0
    for chunk in chunks:
        sha256.update(chunk)
        size += len(chunk)
    return sha256.hexdigest(), size


def stored(r2, key):
    try:
        return r2.head_object(Bucket=BUCKET, Key=key)
    except Exception as error:
        if getattr(error, "response", {}).get("Error", {}).get("Code", "") in ("404", "NoSuchKey", "NotFound"):
            return None
        raise


def same(head, sha, size):
    return bool(head) and head.get("ContentLength") == size and head.get("Metadata", {}).get("sha256") == sha


def public(path, sha):
    # A query of its own: Cloudflare caches .dmg keyed with it, so this reads
    # what R2 holds, never an edge copy.
    request = Request(f"{PUBLIC}/{path}?sha256={sha}", headers={"User-Agent": "Daisy-release/1"})
    with urlopen(request, timeout=60) as response:
        return digest(iter(lambda: response.read(1024 * 1024), b""))


path, build = Path(sys.argv[1]), sys.argv[2]
name = path.name
if not re.fullmatch(r"Daisy-[0-9]+(\.[0-9]+)+\.dmg", name) or not path.is_file():
    sys.exit(f"  ✗ not a Daisy-<version>.dmg file: {path}")
if not re.fullmatch(r"[0-9]+", build):
    sys.exit(f"  ✗ not a build number: {build}")
with path.open("rb") as f:
    sha, size = digest(iter(lambda: f.read(1024 * 1024), b""))
headers = {
    "ContentType": "application/x-apple-diskimage",
    "ContentDisposition": f'attachment; filename="{name}"',
    "CacheControl": "public, max-age=31536000, immutable",
    "Metadata": {"sha256": sha},
}

r2 = client()
key, flat = f"downloads/{build}/{name}", f"downloads/{name}"
head = stored(r2, key)
if head and not same(head, sha, size):
    sys.exit(f"  ✗ R2 {key} already holds other bytes — build {build} was published; never overwritten")
if head:
    print(f"  ⊘ R2 already has {key}")
else:
    if same(stored(r2, flat), sha, size):
        # The same bytes are there under the old flat name: copy in R2.
        r2.copy_object(Bucket=BUCKET, Key=key, CopySource={"Bucket": BUCKET, "Key": flat},
                       MetadataDirective="REPLACE", **headers)
    else:
        r2.upload_file(str(path), BUCKET, key, ExtraArgs=headers)
    if not same(stored(r2, key), sha, size):
        sys.exit(f"  ✗ R2 {key} doesn't match {path} after upload")
    print(f"  → R2 {key} ({size} bytes)")
checks = [f"{build}/{name}"]
if stored(r2, flat) is None:
    r2.copy_object(Bucket=BUCKET, Key=flat, CopySource={"Bucket": BUCKET, "Key": key},
                   MetadataDirective="REPLACE", **headers)
    checks.append(name)
    print(f"  → R2 {flat} (first build of this version)")

for check in checks:
    for attempt in range(3):
        try:
            if public(check, sha) == (sha, size):
                break
        except OSError as error:  # HTTPError and URLError included
            print(f"  ⚠ {PUBLIC}/{check}: {error}", file=sys.stderr)
        time.sleep(10)
    else:
        sys.exit(f"  ✗ {PUBLIC}/{check} doesn't serve the uploaded bytes (sha256 {sha})")
    print(f"  ✓ {PUBLIC}/{check} serves sha256 {sha}")
PY
}

# -----------------------------------------------------------------------------
# github_release <marketing-version>
#
# Every stable release is also a GitHub Release with the SAME DMG the site
# serves (2026-10-07): mydaisy.io says so, and that has to stay true. Runs
# after `promote` and after a stable release; `release.sh github-release
# <version>` runs it alone.
#
# The DMG is downloaded from R2 at the appcast item's build — the published
# bytes, never a rebuild.
# The release hangs on the tag v<version>, which must
# already be on GitHub. tag_release_source pushes it before the site goes
# out; when it could not (see there), this prints the command to run once
# the tag is pushed. Publishing is
# gated behind DAISY_AUTO_PUSH=1, like the daisy-web push. Never fails
# the release — the site is already published by the time this runs.
# -----------------------------------------------------------------------------
GITHUB_REPO="${DAISY_GITHUB_REPO:-addicted-studio/daisy-app}"

github_release() {
    local version="$1"
    local tag="v${version}"
    local notes="${DAISY_REPO}/scripts/release-notes/${version}.md"
    local retry="./scripts/release.sh github-release ${version}"

    echo "▸ GitHub Release ${tag} on ${GITHUB_REPO}…"
    if [[ "${DAISY_AUTO_PUSH:-0}" != "1" ]]; then
        echo "    Not published (DAISY_AUTO_PUSH is off). After pushing: ${retry}"
        return 0
    fi
    if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
        echo "  ⚠ gh missing or not signed in — no GitHub Release. Then: ${retry}" >&2
        return 0
    fi
    if ! gh api "repos/${GITHUB_REPO}/git/ref/tags/${tag}" >/dev/null 2>&1; then
        echo "    Tag ${tag} is not on GitHub yet. Push it (RELEASING.md), then: ${retry}"
        return 0
    fi
    if gh release view "${tag}" -R "${GITHUB_REPO}" >/dev/null 2>&1; then
        echo "  ⊘ GitHub Release ${tag} already exists — left as is"
        return 0
    fi

    local item build length url work dmg sha body latest_flag="--latest=false" site_latest=""
    # The appcast item names the published build — its R2 path — and the
    # signed DMG's length.
    if ! item=$(VERSION="${version}" APPCAST_FILE="${DAISY_WEB_REPO}/public/appcast.xml" python3 - <<'PY'
import os, re, pathlib, sys
content = pathlib.Path(os.environ["APPCAST_FILE"]).read_text(encoding="utf-8")
m = re.search(r"<item>\s*<title>Daisy " + re.escape(os.environ["VERSION"]) + r"</title>(.*?)</item>", content, re.DOTALL)
build = m and re.search(r"<sparkle:version>(\d+)</sparkle:version>", m.group(1))
length = m and re.search(r'length="(\d+)"', m.group(1))
if not (build and length):
    sys.exit(1)
print(build.group(1), length.group(1))
PY
    ); then
        echo "  ⚠ no appcast item with a build and length for Daisy ${version} — no GitHub Release. Retry: ${retry}" >&2
        return 0
    fi
    read -r build length <<< "${item}"
    url="${R2_DOWNLOADS_URL}/${build}/Daisy-${version}.dmg"
    if ! work=$(mktemp -d); then
        echo "  ⚠ mktemp failed. Retry: ${retry}" >&2
        return 0
    fi
    # The asset takes the file's name, so it keeps Daisy-<version>.dmg.
    dmg="${work}/Daisy-${version}.dmg"
    body="${work}/notes.md"
    if ! curl -fsSL --retry 3 -o "${dmg}" "${url}"; then
        echo "  ⚠ couldn't download ${url} — no GitHub Release. Retry: ${retry}" >&2
        rm -rf "${work}"
        return 0
    fi
    if [[ "$(stat -f%z "${dmg}")" != "${length}" ]]; then
        echo "  ⚠ ${url} isn't the ${length} bytes the appcast signed — no GitHub Release. Retry: ${retry}" >&2
        rm -rf "${work}"
        return 0
    fi
    if ! sha=$(shasum -a 256 "${dmg}" | awk '{print $1}') || [[ -z "${sha}" ]]; then
        echo "  ⚠ couldn't hash ${dmg}. Retry: ${retry}" >&2
        rm -rf "${work}"
        return 0
    fi
    # "Latest" on GitHub only for the version the site's Download button
    # serves — README links releases/latest, and a backfilled older
    # version must not take the badge from it.
    if [[ -f "${DAISY_WEB_REPO}/lib/latestVersion.ts" ]]; then
        site_latest=$(sed -n 's/^export const LATEST_VERSION = "\(.*\)";$/\1/p' "${DAISY_WEB_REPO}/lib/latestVersion.ts")
    fi
    [[ "${site_latest}" == "${version}" ]] && latest_flag="--latest"
    {
        echo "Signed with Developer ID and notarized by Apple. The same DMG as on [mydaisy.io](https://mydaisy.io). Apple Silicon, macOS 14 Sonoma or later."
        echo
        echo "**SHA-256** \`${sha}\`"
        echo
        echo "Already installed? Daisy updates itself through Sparkle."
        echo
        echo "Source for this version: $(source_url "${version}")"
        if [[ -f "${notes}" ]]; then
            echo
            echo "## What's new in ${version}"
            echo
            grep -E '^[-*] ' "${notes}" || true
        fi
    } > "${body}"

    if gh release create "${tag}" "${dmg}" -R "${GITHUB_REPO}" --verify-tag \
        --title "Daisy ${version}" --notes-file "${body}" "${latest_flag}" >/dev/null; then
        echo "  ✓ https://github.com/${GITHUB_REPO}/releases/tag/${tag} (sha256 ${sha})"
    else
        echo "  ⚠ gh release create failed. Retry: ${retry}" >&2
    fi
    rm -rf "${work}"
    return 0
}

# -----------------------------------------------------------------------------
# source_url <marketing-version>
#
# Where the source of one released version is: the tag v<version> on GitHub.
# Daisy is under the AGPL from 1.0.8.60, and its section 6(d) wants a build
# offered for download to come with its source, offered the same way. So
# everything this script publishes for a version says this address: both
# appcast descriptions (the update window, the site's changelog) and the
# GitHub Release. The site shows the same address beside its Download
# buttons (daisy-web lib/versionSource.ts). Made from the version here,
# never typed into a notes file.
# -----------------------------------------------------------------------------
source_url() {
    echo "https://github.com/${GITHUB_REPO}/tree/v$1"
}

# -----------------------------------------------------------------------------
# github_git <git arguments…>
#
# git against GitHub's public https address the way a reader of the source
# link reaches it: no credential helper, no password prompt, no askpass
# window. The app repository is public, so reading it needs none of them,
# and the SSH `origin` is not involved.
# -----------------------------------------------------------------------------
github_git() {
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false \
        git -c credential.helper= "$@"
}

# -----------------------------------------------------------------------------
# github_tag_commit <marketing-version>
#
# Prints the commit v<version> names on GitHub, or nothing when the tag is
# not there. An annotated tag lists its commit on the ^{} line, a lightweight
# one only on the plain line. Fails when GitHub gave no answer.
# -----------------------------------------------------------------------------
github_tag_commit() {
    local tag="v$1" refs
    refs=$(github_git ls-remote --tags "https://github.com/${GITHUB_REPO}.git" \
        "refs/tags/${tag}" "refs/tags/${tag}^{}" 2>/dev/null) || return 1
    echo "${refs}" | awk -v t="refs/tags/${tag}" '
        $2 == t "^{}" { peeled = $1 }
        $2 == t       { plain = $1 }
        END { if (peeled != "") print peeled; else if (plain != "") print plain }'
}

# True when v<version> is on GitHub. No answer counts as no.
source_tag_on_github() {
    [[ -n "$(github_tag_commit "$1" || true)" ]]
}

# -----------------------------------------------------------------------------
# github_tag_matches <marketing-version> <commit>
#
# Compares what v<version> names on GitHub with <commit>, the code being
# released. 0: the same code. 1: other code, or it can't be compared (the
# tagged commit is left in SOURCE_TAG_REMOTE). 2: no such tag on GitHub.
# The pbxproj is left out: it differs by the version numbers alone.
# -----------------------------------------------------------------------------
PBXPROJ_IN_REPO="Daisy.xcodeproj/project.pbxproj"
SOURCE_TAG_REMOTE=""

github_tag_matches() {
    local tag="v$1" commit="$2"
    SOURCE_TAG_REMOTE=$(github_tag_commit "$1" || true)
    [[ -n "${SOURCE_TAG_REMOTE}" ]] || return 2
    if ! git -C "${DAISY_REPO}" cat-file -e "${SOURCE_TAG_REMOTE}^{commit}" 2>/dev/null; then
        # Not in this checkout yet: read it from GitHub. No local tag is made.
        github_git -C "${DAISY_REPO}" fetch -q --no-tags \
            "https://github.com/${GITHUB_REPO}.git" "refs/tags/${tag}" 2>/dev/null || true
    fi
    git -C "${DAISY_REPO}" diff --quiet "${SOURCE_TAG_REMOTE}" "${commit}" \
        -- . ":(exclude)${PBXPROJ_IN_REPO}" 2>/dev/null || return 1
}

# -----------------------------------------------------------------------------
# uncommitted_source
#
# What is in the working tree and not in HEAD, as `git status` lines. Two
# things don't count: the pbxproj this script writes back (the tagged commit
# carries it) and dot-folders (agent and editor state, never built).
# Untracked files do count: the project's folders are synchronized groups,
# so Xcode builds a file git has never seen.
# -----------------------------------------------------------------------------
uncommitted_source() {
    git -C "${DAISY_REPO}" status --porcelain 2>/dev/null \
        | grep -vE '^.. "?(Daisy\.xcodeproj/project\.pbxproj"?$|\.)' || true
}

# -----------------------------------------------------------------------------
# tag_release_source <marketing-version> <build>
#
# Puts the source of the build just made on GitHub as the tag v<version>,
# BEFORE daisy-web is pushed. The appcast and the site link to that tag
# (source_url); until 2026-11-28 it was pushed by hand after this script,
# so the link went live dead and stayed dead if the tag was forgotten.
#
# The tag is the commit RELEASING.md always tagged: the pbxproj bump
# "<version> (b<build>)" on top of the commit that was archived. It is made
# only when that commit is exactly what was built: nothing uncommitted when
# the run started (BUILT_CHANGES) or now, and HEAD still the commit the run
# started from (BUILT_COMMIT). A tag that exists is never moved. Only the
# tag is pushed, and only with DAISY_AUTO_PUSH=1; branches stay for the
# person to push.
#
# Never fails the release. It leaves what happened in SOURCE_TAG_STATE:
#   on-github    the tag is on GitHub and names this build's code
#   mismatch     the tag is on GitHub and names other code (SOURCE_TAG_REMOTE)
#   local        tagged here, not on GitHub yet (not pushed, or the push failed)
#   unseen       pushed to origin, yet GitHub's public address doesn't show it
#   dirty        not tagged: the build held changes that are in no commit
#   moved        not tagged: HEAD moved during the build
#   changed      not tagged: the tree changed during the build
#   local-other  not tagged: a local v<version> names other code
#   uncommitted  not tagged: the pbxproj bump couldn't be committed
#   untagged     the bump is committed, the tag couldn't be made
#   no-git       not a git checkout
# push_daisy_web reads it: the site goes out only with the tag on GitHub,
# and finish_tag_commands prints what is left to do for each state.
# -----------------------------------------------------------------------------
SOURCE_TAG_STATE=""

tag_release_source() {
    local version="$1" build="$2"
    local tag="v${version}"
    local tagged="" matches=0

    echo "▸ source tag ${tag}…"
    if [[ -z "${BUILT_COMMIT:-}" ]]; then
        SOURCE_TAG_STATE="no-git"
        echo "  ⚠ ${DAISY_REPO} is not a git checkout — no tag." >&2
        return 0
    fi

    # A version released again with a new build: the tag is the first
    # build's. The same code may go out under it; other code may not.
    github_tag_matches "${version}" "${BUILT_COMMIT}" || matches=$?
    if [[ "${matches}" == "0" ]]; then
        SOURCE_TAG_STATE="on-github"
        echo "  ⊘ ${tag} is already on GitHub and names this build's code — left as is"
        return 0
    elif [[ "${matches}" == "1" ]]; then
        SOURCE_TAG_STATE="mismatch"
        echo "  ✗ ${tag} on GitHub (${SOURCE_TAG_REMOTE:0:7}) is not the code of this build (${BUILT_COMMIT:0:7})." >&2
        return 0
    fi

    if [[ -n "${BUILT_CHANGES:-}" ]]; then
        SOURCE_TAG_STATE="dirty"
        echo "  ⚠ Not tagged: the build was made with changes that are in no commit:" >&2
        echo "${BUILT_CHANGES}" | sed 's/^/      /' >&2
        return 0
    fi
    if [[ "$(git -C "${DAISY_REPO}" rev-parse HEAD 2>/dev/null || true)" != "${BUILT_COMMIT}" ]]; then
        SOURCE_TAG_STATE="moved"
        echo "  ⚠ Not tagged: HEAD moved during the build (it started from ${BUILT_COMMIT:0:7})." >&2
        return 0
    fi

    tagged=$(git -C "${DAISY_REPO}" rev-parse -q --verify "refs/tags/${tag}^{commit}" 2>/dev/null || true)
    if [[ -n "${tagged}" ]]; then
        # A local tag an earlier run or a person left. Usable only if it
        # names the code that was built.
        if ! git -C "${DAISY_REPO}" diff --quiet "${tagged}" "${BUILT_COMMIT}" -- . ":(exclude)${PBXPROJ_IN_REPO}" 2>/dev/null; then
            SOURCE_TAG_STATE="local-other"
            echo "  ⚠ Not pushed: a local ${tag} (${tagged:0:7}) names other code than this build's (${BUILT_COMMIT:0:7})." >&2
            return 0
        fi
    else
        if [[ -n "$(uncommitted_source)" ]]; then
            SOURCE_TAG_STATE="changed"
            echo "  ⚠ Not tagged: the tree changed during the build:" >&2
            uncommitted_source | sed 's/^/      /' >&2
            return 0
        fi
        if ! git -C "${DAISY_REPO}" diff --quiet -- "${PBXPROJ_IN_REPO}" 2>/dev/null; then
            if ! git -C "${DAISY_REPO}" commit -q -m "${version} (b${build})" -- "${PBXPROJ_IN_REPO}"; then
                SOURCE_TAG_STATE="uncommitted"
                echo "  ⚠ Not tagged: couldn't commit ${PBXPROJ_IN_REPO}." >&2
                return 0
            fi
            echo "  ✓ committed: ${version} (b${build})"
        fi
        if ! git -C "${DAISY_REPO}" tag "${tag}"; then
            SOURCE_TAG_STATE="untagged"
            echo "  ⚠ Couldn't create ${tag}." >&2
            return 0
        fi
        echo "  ✓ tagged ${tag} ($(git -C "${DAISY_REPO}" rev-parse --short "${tag}^{commit}" 2>/dev/null || true))"
    fi

    SOURCE_TAG_STATE="local"
    if [[ "${DAISY_AUTO_PUSH:-0}" != "1" ]]; then
        echo "    Not pushed (DAISY_AUTO_PUSH is off)."
        return 0
    fi
    if ! git -C "${DAISY_REPO}" push origin "refs/tags/${tag}"; then
        echo "  ⚠ Couldn't push ${tag}." >&2
        return 0
    fi
    if source_tag_on_github "${version}"; then
        SOURCE_TAG_STATE="on-github"
        echo "  ✓ $(source_url "${version}")"
    else
        SOURCE_TAG_STATE="unseen"
        echo "  ⚠ Pushed ${tag} to origin, but https://github.com/${GITHUB_REPO} doesn't show it." >&2
    fi
    return 0
}

# -----------------------------------------------------------------------------
# finish_tag_commands <marketing-version> [<build>]
#
# Prints the commands that put v<version> on GitHub from the state
# tag_release_source left, one per line, ready to paste. Prints nothing when
# the tag is there. Fails when no command does it (other code under the
# tag, no git).
# -----------------------------------------------------------------------------
finish_tag_commands() {
    local version="$1" build="${2:-}"
    local tag="v${version}" paths=""

    case "${SOURCE_TAG_STATE:-}" in
        on-github)
            ;;
        local)
            echo "      cd ${DAISY_REPO}"
            echo "      git push origin ${tag}"
            ;;
        unseen)
            echo "    origin took ${tag}, but it is not at https://github.com/${GITHUB_REPO}."
            echo "    Check where origin points (git remote get-url origin), then:"
            echo "      cd ${DAISY_REPO}"
            echo "      git push origin ${tag}"
            ;;
        moved|changed)
            echo "    The archive was made from ${BUILT_COMMIT:0:7}. Tag that commit. (Its pbxproj has the"
            echo "    previous version numbers; this build got its own on the command line.)"
            if [[ "${SOURCE_TAG_STATE}" == "changed" ]]; then
                echo "    Only if the changes listed above came after the archive step; if they were"
                echo "    built, no commit is this build's source: release again from a clean tree."
            fi
            echo "      cd ${DAISY_REPO}"
            echo "      git tag ${tag} ${BUILT_COMMIT}"
            echo "      git push origin ${tag}"
            ;;
        dirty)
            # `XY path`, and `XY old -> new` for a rename.
            paths=$(echo "${BUILT_CHANGES:-}" | sed -e 's/^...//' -e 's/^.* -> //' | tr '\n' ' ')
            echo "    Commit what was built, then tag that commit. Only if these files are still"
            echo "    as they were when the archive was made; otherwise release again from a clean tree."
            echo "      cd ${DAISY_REPO}"
            echo "      git add -- ${paths}${PBXPROJ_IN_REPO}"
            echo "      git commit -m \"${version} (b${build})\" -- ${paths}${PBXPROJ_IN_REPO}"
            echo "      git tag ${tag}"
            echo "      git push origin ${tag}"
            ;;
        local-other)
            echo "    The local ${tag} is not this build. If it is a leftover, replace it:"
            echo "      cd ${DAISY_REPO}"
            echo "      git tag -d ${tag}"
            echo "      git tag ${tag} ${BUILT_COMMIT}"
            echo "      git push origin ${tag}"
            ;;
        uncommitted)
            echo "      cd ${DAISY_REPO}"
            echo "      git commit -m \"${version} (b${build})\" -- ${PBXPROJ_IN_REPO}"
            echo "      git tag ${tag}"
            echo "      git push origin ${tag}"
            ;;
        untagged)
            echo "      cd ${DAISY_REPO}"
            echo "      git tag ${tag}"
            echo "      git push origin ${tag}"
            ;;
        "")
            # promote: the tag is the beta's, made when it was cut.
            if source_tag_on_github "${version}"; then
                :
            elif git -C "${DAISY_REPO}" rev-parse -q --verify "refs/tags/${tag}^{commit}" >/dev/null 2>&1; then
                echo "      cd ${DAISY_REPO}"
                echo "      git push origin ${tag}"
            else
                echo "    There is no ${tag} here either. Tag the commit Daisy ${version} was built from"
                echo "    (the «${version} (b…)» commit) and push it:"
                echo "      cd ${DAISY_REPO}"
                echo "      git tag ${tag} <that commit>"
                echo "      git push origin ${tag}"
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# web_checkout_ready
#
# daisy-web's checkout is shared with other sessions, and a push to its main
# is a deploy. Before anything is built or changed: the checkout must be on
# main and level with origin/main, so that the release adds one commit, its
# own, and pushes that alone. Uncommitted files of other sessions are fine
# and are never touched (commit_daisy_web names its paths).
# -----------------------------------------------------------------------------
web_checkout_ready() {
    local branch ahead behind

    if ! git -C "${DAISY_WEB_REPO}" fetch -q origin main; then
        echo "  ✗ Couldn't fetch origin/main in ${DAISY_WEB_REPO}." >&2
        return 1
    fi
    branch=$(git -C "${DAISY_WEB_REPO}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    if [[ "${branch}" != "main" ]]; then
        echo "  ✗ ${DAISY_WEB_REPO} is on «${branch}», not main: the release commit goes to main." >&2
        return 1
    fi
    ahead=$(git -C "${DAISY_WEB_REPO}" rev-list --count origin/main..HEAD)
    behind=$(git -C "${DAISY_WEB_REPO}" rev-list --count HEAD..origin/main)
    if [[ "${ahead}" != "0" ]]; then
        echo "  ✗ ${DAISY_WEB_REPO} has ${ahead} commit(s) that are not on origin/main:" >&2
        git -C "${DAISY_WEB_REPO}" log --oneline origin/main..HEAD | cut -c1-110 | sed 's/^/      /' >&2
        echo "    The release pushes one commit, its own. Push these first, or move them off main." >&2
        return 1
    fi
    if [[ "${behind}" != "0" ]]; then
        echo "  ✗ ${DAISY_WEB_REPO} is ${behind} commit(s) behind origin/main. Bring it up to date first:" >&2
        echo "      cd ${DAISY_WEB_REPO}" >&2
        echo "      git pull --rebase --autostash" >&2
        return 1
    fi
}

# -----------------------------------------------------------------------------
# commit_daisy_web <message>
#
# Commits the release's own files in daisy-web, by name: the appcast and the
# version pointers, those that exist and changed. Never the whole index —
# another session may have staged work in this checkout. 0: committed
# (WEB_RELEASE_COMMIT). 1: nothing changed. 2: git refused.
# -----------------------------------------------------------------------------
WEB_RELEASE_COMMIT=""

commit_daisy_web() {
    local message="$1" path changed=""

    for path in public/appcast.xml lib/latestVersion.ts lib/betaVersion.ts; do
        [[ -e "${DAISY_WEB_REPO}/${path}" ]] || continue
        [[ -n "$(git -C "${DAISY_WEB_REPO}" status --porcelain -- "${path}" 2>/dev/null)" ]] || continue
        git -C "${DAISY_WEB_REPO}" add -- "${path}" || return 2
        changed="${changed} ${path}"
    done
    [[ -n "${changed}" ]] || return 1
    # Unquoted on purpose: three fixed paths, no spaces in them.
    # shellcheck disable=SC2086
    git -C "${DAISY_WEB_REPO}" commit -q -m "${message}" -- ${changed} || return 2
    WEB_RELEASE_COMMIT=$(git -C "${DAISY_WEB_REPO}" rev-parse HEAD)
}

# -----------------------------------------------------------------------------
# push_daisy_web <marketing-version> [<build>]
#
# Pushes daisy-web's release commit: the push is the deploy, so this is the
# moment the appcast and the site's Download button go live. Both link to
# the source of <version> (source_url), so the push waits for the tag: it is
# held while v<version> is missing from GitHub or names other code.
#
# It pushes one commit, the release's. With anything else ahead of
# origin/main (another session's commit in the shared checkout), on another
# branch, or behind origin/main, it holds and says what to do; so it does
# when GitHub rejects the push.
#
# WEB_PUSH_STATE says how it ended: pushed, manual (DAISY_AUTO_PUSH is off:
# the commands are printed) or held. Fails on held, and then every line a
# person needs to finish the release has been printed.
# -----------------------------------------------------------------------------
WEB_PUSH_STATE=""

push_daisy_web() {
    local version="$1" build="${2:-}"
    local tag="v${version}"
    local branch ahead behind

    WEB_PUSH_STATE="held"
    if [[ "${SOURCE_TAG_STATE:-}" == "mismatch" ]]; then
        echo "  ✗ daisy-web NOT pushed: ${tag} is on GitHub and names other code (${SOURCE_TAG_REMOTE:0:7}) than this" >&2
        echo "    build's (${BUILT_COMMIT:0:7}), so $(source_url "${version}")" >&2
        echo "    would offer source that is not this build's. A tag is never moved: a changed build" >&2
        echo "    needs its own version number. See the difference:" >&2
        echo "      cd ${DAISY_REPO}" >&2
        echo "      git diff --stat ${SOURCE_TAG_REMOTE} ${BUILT_COMMIT}" >&2
        if [[ -n "${WEB_RELEASE_COMMIT}" ]]; then
            echo "    The site commit ${WEB_RELEASE_COMMIT:0:7} must not go out. To take it back while it is still the" >&2
            echo "    last commit there (other files in that checkout are left alone):" >&2
            echo "      cd ${DAISY_WEB_REPO}" >&2
            echo "      git reset --soft ${WEB_RELEASE_COMMIT}~1" >&2
            echo "      git restore --staged --worktree -- public/appcast.xml lib/latestVersion.ts lib/betaVersion.ts" >&2
        fi
        return 1
    fi

    if [[ "${DAISY_AUTO_PUSH:-0}" != "1" ]]; then
        WEB_PUSH_STATE="manual"
        echo "    daisy-web is committed, not pushed (DAISY_AUTO_PUSH is off)."
        echo "    Review: cd ${DAISY_WEB_REPO} && git show HEAD"
        echo "    To publish, in this order (the appcast and the site link to ${tag}):"
        finish_tag_commands "${version}" "${build}" || true
        echo "      cd ${DAISY_WEB_REPO}"
        echo "      git push origin main"
        return 0
    fi

    if ! source_tag_on_github "${version}"; then
        echo "  ✗ daisy-web NOT pushed: ${tag} is not on GitHub, and the appcast and the site link to" >&2
        echo "    $(source_url "${version}")" >&2
        echo "    To finish, in this order:" >&2
        finish_tag_commands "${version}" "${build}" >&2 || true
        echo "      cd ${DAISY_WEB_REPO}" >&2
        echo "      git push origin main" >&2
        return 1
    fi

    if ! git -C "${DAISY_WEB_REPO}" fetch -q origin main; then
        echo "  ✗ daisy-web NOT pushed: couldn't fetch origin/main to see what the push would carry." >&2
        echo "    When the network is back, check that the release commit is the only one ahead, then:" >&2
        echo "      cd ${DAISY_WEB_REPO}" >&2
        echo "      git log --oneline origin/main..HEAD" >&2
        echo "      git push origin main" >&2
        return 1
    fi
    branch=$(git -C "${DAISY_WEB_REPO}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
    if [[ "${branch}" != "main" ]]; then
        echo "  ✗ daisy-web NOT pushed: the checkout is on «${branch}», not main (it was on main in step 0)." >&2
        echo "    The release commit is ${WEB_RELEASE_COMMIT:0:12}. Put it on main and push:" >&2
        echo "      cd ${DAISY_WEB_REPO}" >&2
        echo "      git switch main" >&2
        echo "      git cherry-pick ${WEB_RELEASE_COMMIT}" >&2
        echo "      git push origin main" >&2
        return 1
    fi
    if git -C "${DAISY_WEB_REPO}" merge-base --is-ancestor "${WEB_RELEASE_COMMIT}" origin/main 2>/dev/null; then
        # Another session's push from the shared checkout took it along.
        WEB_PUSH_STATE="pushed"
        echo "  ✓ daisy-web's release commit is already on origin/main — Vercel deploys in 1-2 min"
        return 0
    fi
    ahead=$(git -C "${DAISY_WEB_REPO}" rev-list --count origin/main..HEAD)
    behind=$(git -C "${DAISY_WEB_REPO}" rev-list --count HEAD..origin/main)
    if [[ "${ahead}" != "1" || "$(git -C "${DAISY_WEB_REPO}" rev-parse HEAD)" != "${WEB_RELEASE_COMMIT}" ]]; then
        echo "  ✗ daisy-web NOT pushed: the push would carry more than the release commit (${WEB_RELEASE_COMMIT:0:7})." >&2
        echo "    Ahead of origin/main:" >&2
        git -C "${DAISY_WEB_REPO}" log --oneline origin/main..HEAD | cut -c1-110 | sed 's/^/      /' >&2
        echo "    A push to main deploys all of them. Push when the others are meant to go out too," >&2
        echo "    or after their author has moved them off main:" >&2
        echo "      cd ${DAISY_WEB_REPO}" >&2
        echo "      git push origin main" >&2
        return 1
    fi
    if [[ "${behind}" != "0" ]] || ! git -C "${DAISY_WEB_REPO}" push origin main; then
        echo "  ✗ daisy-web NOT pushed: GitHub refused the push, or origin/main has moved on since step 0" >&2
        echo "    (${behind} new commit(s) at the last look). Put the release commit on top of it and push:" >&2
        echo "      cd ${DAISY_WEB_REPO}" >&2
        echo "      git pull --rebase --autostash" >&2
        echo "      git push origin main" >&2
        return 1
    fi
    WEB_PUSH_STATE="pushed"
    echo "  ✓ pushed daisy-web — Vercel deploys in 1-2 min"
}

# -----------------------------------------------------------------------------
# app_branch_reminder
#
# The tag is on GitHub; the branch it was cut from is not pushed by this
# script (a branch is the person's to publish: on main a push is public
# history, and a hotfix branch is merged first). Says so when the branch
# has commits its upstream lacks, with the command.
# -----------------------------------------------------------------------------
app_branch_reminder() {
    local branch unpushed
    branch=$(git -C "${DAISY_REPO}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    [[ -n "${branch}" && "${branch}" != "HEAD" ]] || return 0
    unpushed=$(git -C "${DAISY_REPO}" rev-list --count "origin/${branch}..HEAD" 2>/dev/null || echo "?")
    [[ "${unpushed}" != "0" ]] || return 0
    echo "    Branch : «${branch}» is not pushed yet (only the tag is). When ready:"
    echo "               cd ${DAISY_REPO}"
    echo "               git push origin ${branch}"
}

# -----------------------------------------------------------------------------
# Args.
# -----------------------------------------------------------------------------

# ── GitHub Release only ──────────────────────────────────────────────
# `release.sh github-release 1.0.8.23` — attach the published DMG to a
# GitHub Release for a tag that is already on GitHub. For a stable or
# hotfix release, run it after pushing the tag.
if [[ "${1:-}" == "github-release" ]]; then
    if [[ -z "${2:-}" ]]; then
        echo "Usage: $0 github-release <marketing-version>" >&2
        exit 1
    fi
    DAISY_AUTO_PUSH=1 github_release "$2"
    exit 0
fi

# ── R2 upload only ───────────────────────────────────────────────────
# `release.sh upload-dmg build/Daisy-1.0.8.49.dmg 166` — put one build's
# DMG into R2 and check the public copy, nothing else: the 2026-11-04 move
# of the old DMGs out of daisy-web, or a check of R2 on its own.
if [[ "${1:-}" == "upload-dmg" ]]; then
    if [[ $# -ne 3 ]]; then
        echo "Usage: $0 upload-dmg <Daisy-<version>.dmg> <build-number>" >&2
        exit 1
    fi
    upload_dmg "$2" "$3"
    exit 0
fi

# ── Promote mode ─────────────────────────────────────────────────────
# `release.sh promote 1.0.8` — flip an already-published BETA release to
# the stable channel. No rebuild: the DMG and the appcast <item> already
# exist; we strip the <sparkle:channel>beta</sparkle:channel> tag from
# that item (stable clients only see untagged items) and point the
# website's main Download button (lib/latestVersion.ts) at it.
if [[ "${1:-}" == "promote" ]]; then
    PROMOTE_VERSION="${2:-}"
    if [[ -z "${PROMOTE_VERSION}" ]]; then
        echo "Usage: $0 promote <marketing-version>" >&2
        exit 1
    fi
    # Before the appcast is touched: the shared checkout must be on main and
    # level with origin/main.
    web_checkout_ready || exit 1
    APPCAST_FILE="${DAISY_WEB_REPO}/public/appcast.xml"
    PROMOTED_BUILD=$(VERSION="${PROMOTE_VERSION}" APPCAST_FILE="${APPCAST_FILE}" python3 <<'PY'
import os, re, pathlib, sys
version = os.environ["VERSION"]
path = pathlib.Path(os.environ["APPCAST_FILE"])
content = path.read_text(encoding="utf-8")
item_re = re.compile(
    r"([ \t]*<item>\s*\n[ \t]*<title>Daisy " + re.escape(version) + r"</title>.*?</item>)",
    re.DOTALL,
)
m = item_re.search(content)
if not m:
    print(f"no appcast item for Daisy {version}", file=sys.stderr)
    sys.exit(1)
item = m.group(1)
build_m = re.search(r"<sparkle:version>(\d+)</sparkle:version>", item)
if not build_m:
    print("item has no <sparkle:version>", file=sys.stderr)
    sys.exit(1)
new_item, n = re.subn(r"[ \t]*<sparkle:channel>beta</sparkle:channel>\s*\n", "", item)
if n == 0:
    print(f"note: Daisy {version} had no beta tag (already stable)", file=sys.stderr)
content = content.replace(item, new_item, 1)
path.write_text(content, encoding="utf-8")
print(build_m.group(1))
PY
)
    [[ -n "${PROMOTED_BUILD}" ]] || exit 1
    cat > "${DAISY_WEB_REPO}/lib/latestVersion.ts" <<EOF
// AUTO-GENERATED by release.sh (stable releases + promote). Do not
// hand-edit. Source of truth for the site's main Download button;
// appcast.xml is the source of truth for Sparkle updates.
export const LATEST_VERSION = "${PROMOTE_VERSION}";
export const LATEST_BUILD = ${PROMOTED_BUILD};
// Each build has its own path — see release.sh step [6/6] notes.
export const LATEST_DMG_URL = \`/downloads/\${LATEST_BUILD}/Daisy-\${LATEST_VERSION}.dmg\`;
EOF
    PROMOTE_COMMITTED=0
    commit_daisy_web "release: promote Daisy ${PROMOTE_VERSION} (build ${PROMOTED_BUILD}) to stable" || PROMOTE_COMMITTED=$?
    if [[ "${PROMOTE_COMMITTED}" == "1" ]]; then
        echo "  ⊘ nothing to promote (already stable?)"
    elif [[ "${PROMOTE_COMMITTED}" != "0" ]]; then
        echo "  ✗ Couldn't commit the promotion in ${DAISY_WEB_REPO}; appcast.xml and lib/latestVersion.ts are changed there, uncommitted." >&2
        exit 2
    else
        echo "  ✓ Daisy ${PROMOTE_VERSION} (build ${PROMOTED_BUILD}) promoted to stable (committed in daisy-web)"
        # The main Download button now serves this version and shows its
        # source link; the tag is the beta's, pushed when it was cut.
        if ! push_daisy_web "${PROMOTE_VERSION}"; then
            echo
            echo "  ✗ Daisy ${PROMOTE_VERSION} is NOT promoted on the site: the daisy-web commit (${WEB_RELEASE_COMMIT:0:7}) is made"
            echo "    locally and not pushed. What to do next is printed above."
            exit 2
        fi
    fi
    github_release "${PROMOTE_VERSION}"
    exit 0
fi

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <marketing-version> <build-number> [stable|beta]" >&2
    echo "  e.g.  $0 1.0.1 3           # stable (default)" >&2
    echo "        $0 1.0.8 62 beta     # beta channel (opt-in clients only)" >&2
    echo "        $0 promote 1.0.8     # beta → stable, no rebuild" >&2
    echo "        $0 github-release 1.0.8  # GitHub Release with the published DMG" >&2
    echo "        $0 upload-dmg build/Daisy-1.0.8.dmg 62  # R2 upload only" >&2
    exit 1
fi

VERSION="$1"
BUILD="$2"
# A dotted version or a subcommand in the build slot (e.g. an older
# release.sh that doesn't know `github-release`) must not slide into a
# full release: the appcast check below would only print a bash
# arithmetic error and carry on.
if [[ ! "${VERSION}" =~ ^[0-9]+(\.[0-9]+)+$ || ! "${BUILD}" =~ ^[0-9]+$ ]]; then
    echo "  ✗ expected <marketing-version> <build-number>, got '${VERSION}' '${BUILD}'" >&2
    exit 1
fi
# Release channel: stable items carry no <sparkle:channel> tag (every
# client sees them); beta items are tagged and only served to clients
# that opted in (About → "Get beta updates").
CHANNEL="${3:-stable}"
case "${CHANNEL}" in
    stable|beta) ;;
    *) echo "  ✗ channel must be 'stable' or 'beta' (got '${CHANNEL}')" >&2; exit 1 ;;
esac
DMG_NAME="Daisy-${VERSION}.dmg"
# Archives and the export in a `.noindex` folder (2026-09-28): Spotlight
# and LaunchServices skip it, so the 20-odd Daisy.app copies a release
# history leaves behind no longer crowd Finder's "Open With" menu. The
# archive stays for its dSYMs (crash symbolication); the export is only
# the notarised app on its way into the DMG and is removed after it.
ARCHIVE_DIR="${DAISY_REPO}/build/archives.noindex"
ARCHIVE_PATH="${ARCHIVE_DIR}/Daisy-${VERSION}.xcarchive"
EXPORT_PATH="${ARCHIVE_DIR}/export-${VERSION}"
DMG_PATH="${DAISY_REPO}/build/${DMG_NAME}"
APPCAST_FILE="${DAISY_WEB_REPO}/public/appcast.xml"

echo "▸ Daisy ${VERSION} (build ${BUILD}, channel: ${CHANNEL})"
echo "  archive : ${ARCHIVE_PATH}"
echo "  export  : ${EXPORT_PATH}"
echo "  dmg     : ${DMG_PATH}"
echo

# -----------------------------------------------------------------------------
# 0. Sanity — build number must be strictly greater than the highest
#    <sparkle:version> already published in appcast.xml. Sparkle compares
#    items by sparkle:version (CFBundleVersion), not shortVersionString —
#    on 2026-05-20 we shipped 1.0.3 build 6 alongside 1.0.2 build 7 and
#    Sparkle offered our tester a "downgrade" to 1.0.2 because 7 > 6.
#    pbxproj's CURRENT_PROJECT_VERSION is stale (release.sh doesn't bump
#    it), so the authoritative source for "what's the next free build" is
#    appcast.xml itself.
#
#    Failing here costs <1s. Failing in [6/6] would cost 15+ minutes of
#    archive + notary work for a DMG that can't be used.
# -----------------------------------------------------------------------------

if [[ -f "${APPCAST_FILE}" ]]; then
    # Extract every <sparkle:version>N</sparkle:version> integer and take
    # the max. grep -oE keeps the script portable (no xmllint required).
    MAX_PUBLISHED_BUILD=$(grep -oE '<sparkle:version>[0-9]+</sparkle:version>' "${APPCAST_FILE}" \
        | grep -oE '[0-9]+' \
        | sort -n \
        | tail -1 || true)
    if [[ -n "${MAX_PUBLISHED_BUILD}" && "${BUILD}" -le "${MAX_PUBLISHED_BUILD}" ]]; then
        echo "  ✗ Build ${BUILD} ≤ last published build ${MAX_PUBLISHED_BUILD} in appcast.xml" >&2
        echo "    Sparkle compares items by <sparkle:version> (CFBundleVersion), not by" >&2
        echo "    shortVersionString — clients already on build ${MAX_PUBLISHED_BUILD} won't see" >&2
        echo "    this release, or worse, will be offered an apparent downgrade." >&2
        echo "" >&2
        echo "    Next available build: $((MAX_PUBLISHED_BUILD + 1))" >&2
        echo "    Re-run:   $0 ${VERSION} $((MAX_PUBLISHED_BUILD + 1))" >&2
        exit 1
    fi
    if [[ -n "${MAX_PUBLISHED_BUILD}" ]]; then
        echo "  ✓ Build ${BUILD} > last published ${MAX_PUBLISHED_BUILD} (appcast.xml)"
        echo
    fi
fi

# Release notes are read in [6/6]; missing ones used to stop the release
# there, after the archive and two notary rounds (2026-10-08).
if [[ ! -f "${DAISY_REPO}/scripts/release-notes/${VERSION}.md" ]]; then
    echo "  ✗ Release notes missing: scripts/release-notes/${VERSION}.md" >&2
    echo "    Create it (one '- text' bullet per line; ${VERSION}.ru.md optional), then re-run." >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# 0. Quality gates — run BEFORE the ~15-minute archive + notarize so a failing
#    test or a surprising branch is caught in seconds, not after a wasted
#    notary cycle. Unit tests are the hard gate (skip only for an emergency
#    hotfix via DAISY_SKIP_TESTS=1); dirty-tree / branch are informational
#    because the release flow intentionally writes pbxproj back.
# -----------------------------------------------------------------------------

echo "▸ [0/6] quality gates…"

# [6/6] uploads the DMG to R2; missing uv or Keychain record found there
# would cost the archive and both notary rounds.
if ! command -v uv >/dev/null 2>&1; then
    echo "  ✗ uv not installed (brew install uv) — [6/6] uploads the DMG to R2 with it." >&2
    exit 1
fi
# Read, not just found: an access prompt shows up now, not after notarising.
if ! security find-generic-password -s io.mydaisy.models.r2 -a daisy-models -w >/dev/null 2>&1; then
    echo "  ✗ No readable R2 credentials in the Keychain (service io.mydaisy.models.r2, account daisy-models)." >&2
    exit 1
fi
# R2 never overwrites a build. A run that stopped after the upload left
# downloads/<build>/ taken although the appcast doesn't list it (step 0
# passes); a rebuild makes new bytes, which upload_dmg would refuse only
# at the end.
R2_STATUS=$(curl -s --max-time 20 -o /dev/null -w "%{http_code}" -I "${R2_DOWNLOADS_URL}/${BUILD}/${DMG_NAME}?free=$$" || true)
if [[ "${R2_STATUS}" == "200" ]]; then
    echo "  ✗ R2 already has downloads/${BUILD}/${DMG_NAME} (an earlier run stopped after its upload)." >&2
    echo "    Re-run with the next build: $0 ${VERSION} $((BUILD + 1))${3:+ ${3}}" >&2
    exit 1
elif [[ "${R2_STATUS}" != "404" ]]; then
    echo "  ✗ Couldn't check R2 for build ${BUILD} (HTTP ${R2_STATUS:-none})." >&2
    exit 1
fi

if ! git -C "${DAISY_REPO}" diff --quiet || ! git -C "${DAISY_REPO}" diff --cached --quiet; then
    echo "  ⚠ Working tree has uncommitted changes — releasing from a dirty tree."
fi
# What is about to be built, for tag_release_source in [6/6]: the commit and
# whatever the tree holds beyond it. With anything beyond it there is no
# commit to publish as this build's source. A run that publishes
# (DAISY_AUTO_PUSH=1) stops here: found in [6/6] the same thing would hold
# the site back after the archive and both notary rounds. A run that only
# builds and commits goes on with a warning; its tag is then made by hand.
BUILT_COMMIT=$(git -C "${DAISY_REPO}" rev-parse HEAD 2>/dev/null || true)
BUILT_CHANGES=$(uncommitted_source)
if [[ -n "${BUILT_CHANGES}" ]]; then
    if [[ "${DAISY_AUTO_PUSH:-0}" == "1" ]]; then
        echo "  ✗ These changes are in no commit, so no commit is the source of this build and v${VERSION} can't be tagged:" >&2
        echo "${BUILT_CHANGES}" | sed 's/^/      /' >&2
        echo "    Commit them (or take them out of the tree) and run again. Nothing was built." >&2
        exit 1
    fi
    echo "  ⚠ These changes are in no commit, so v${VERSION} can't be tagged as the source of this build:"
    echo "${BUILT_CHANGES}" | sed 's/^/      /'
    echo "    The build goes on (DAISY_AUTO_PUSH is off); the commands to commit and tag them are printed at the end."
fi
# The same for a version that is on GitHub already (a re-release with a new
# build): the tag is never moved, so it has to name this code.
if [[ "${DAISY_AUTO_PUSH:-0}" == "1" && -n "${BUILT_COMMIT}" ]]; then
    TAG_MATCHES=0
    github_tag_matches "${VERSION}" "${BUILT_COMMIT}" || TAG_MATCHES=$?
    if [[ "${TAG_MATCHES}" == "1" ]]; then
        echo "  ✗ v${VERSION} is on GitHub (${SOURCE_TAG_REMOTE:0:7}) and names other code than ${BUILT_COMMIT:0:7}." >&2
        echo "    A tag is never moved: a changed build needs its own version number. Nothing was built." >&2
        echo "      git -C ${DAISY_REPO} diff --stat ${SOURCE_TAG_REMOTE} ${BUILT_COMMIT}" >&2
        exit 1
    fi
fi
# daisy-web's checkout is shared, and its push is a deploy: on main and
# level with origin/main now, so the release pushes one commit, its own.
if ! web_checkout_ready; then
    echo "    Nothing was built." >&2
    exit 1
fi
CURRENT_BRANCH=$(git -C "${DAISY_REPO}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
echo "  • branch: ${CURRENT_BRANCH}"

if [[ "${DAISY_SKIP_TESTS:-0}" == "1" ]]; then
    echo "  ⚠ DAISY_SKIP_TESTS=1 — skipping unit tests (hotfix mode)."
else
    echo "  • running unit tests…"
    # Tests run under Debug, NOT ${CONFIGURATION}: the DaisyTests target
    # does `@testable import Daisy`, which requires ENABLE_TESTABILITY=YES.
    # That's on for Debug but off for Release (we don't want to weaken the
    # shipped/optimised build), so `-configuration Release test` fails to
    # resolve the module. The archive below still builds Release.
    # English, whatever language the person picked for Daisy: the test
    # host shares the app's defaults, and tests that read error copy
    # failed under Russian (2026-10-18).
    if ! xcodebuild \
        -project "${DAISY_REPO}/Daisy.xcodeproj" \
        -scheme "${SCHEME}" \
        -configuration Debug \
        -destination 'platform=macOS' \
        -testLanguage en -testRegion US \
        test; then
        echo "  ✗ Tests failed — aborting before archive." >&2
        echo "    Fix the tests, or re-run with DAISY_SKIP_TESTS=1 for an emergency hotfix." >&2
        exit 1
    fi
    echo "  ✓ tests passed"
fi
echo

# -----------------------------------------------------------------------------
# 1. Archive — release-config build of the Xcode project.
# -----------------------------------------------------------------------------

echo "▸ [1/6] xcodebuild archive…"
mkdir -p "${ARCHIVE_DIR}"
rm -rf "${ARCHIVE_PATH}"
xcodebuild \
    -project "${DAISY_REPO}/Daisy.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -archivePath "${ARCHIVE_PATH}" \
    MARKETING_VERSION="${VERSION}" \
    CURRENT_PROJECT_VERSION="${BUILD}" \
    archive
echo

# -----------------------------------------------------------------------------
# 1b. Debug symbols to Sentry (backlog 27 С-2, 2026-10-09). Crash reports
#     the person chooses to send arrive with addresses only; Sentry turns
#     them into function names and lines with this build's dSYMs. Never
#     fails the release. The Organization Token lives in the Keychain
#     (service daisy-sentry-auth-token, account sentry) and goes to
#     sentry-cli through its environment only — never into an argument, a
#     file or this script's output.
# -----------------------------------------------------------------------------

echo "▸ [1b/6] uploading debug symbols to Sentry…"
if ! command -v sentry-cli >/dev/null 2>&1; then
    echo "  ⚠ sentry-cli not installed (brew install getsentry/tools/sentry-cli) — crash reports from this build won't be symbolicated."
else
    SENTRY_TOKEN="$(security find-generic-password -a sentry -s daisy-sentry-auth-token -w 2>/dev/null || true)"
    if [[ -z "${SENTRY_TOKEN}" ]]; then
        echo "  ⚠ no Sentry token in the Keychain (service daisy-sentry-auth-token, account sentry) — skipped."
    elif SENTRY_AUTH_TOKEN="${SENTRY_TOKEN}" sentry-cli --log-level=warn debug-files upload \
            --org daisy-30 --project daisy-mac "${ARCHIVE_PATH}/dSYMs"; then
        echo "  ✓ dSYMs uploaded to Sentry (daisy-mac)"
    else
        echo "  ⚠ dSYM upload failed — the release goes on. Retry later:"
        echo "    SENTRY_AUTH_TOKEN=\"\$(security find-generic-password -a sentry -s daisy-sentry-auth-token -w)\" sentry-cli debug-files upload --org daisy-30 --project daisy-mac \"${ARCHIVE_PATH}/dSYMs\""
    fi
    unset SENTRY_TOKEN
fi
echo

# -----------------------------------------------------------------------------
# 2. Export — pull Daisy.app out of the archive with Developer ID
#    signing and post-export notarisation prep.
# -----------------------------------------------------------------------------

echo "▸ [2/6] exporting Daisy.app from archive…"
rm -rf "${EXPORT_PATH}"
EXPORT_OPTIONS="${DAISY_REPO}/build/ExportOptions.plist"
cat > "${EXPORT_OPTIONS}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <!-- 1.0.8: the app now carries restricted entitlements (shared
       keychain group, iCloud/CloudKit, ubiquity-kvstore). Developer ID
       signing with those requires a Developer ID PROVISIONING PROFILE,
       and "automatic" cannot fetch one from the command line without a
       signed-in Xcode account — it fails with "No profiles for
       'app.essazanov.Daisy' were found". The profile is made once in
       the portal (Profiles → Developer ID → app.essazanov.Daisy) and
       installed by double-clicking it; name it below. -->
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>Developer ID Application</string>
  <key>teamID</key>
  <string>${TEAM_ID}</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>app.essazanov.Daisy</key>
    <string>${DAISY_PROVISIONING_PROFILE:-Daisy Developer ID}</string>
  </dict>
</dict>
</plist>
EOF
xcodebuild \
    -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_PATH}" \
    -exportOptionsPlist "${EXPORT_OPTIONS}"
APP_PATH="${EXPORT_PATH}/Daisy.app"
echo "  → ${APP_PATH}"
echo

# -----------------------------------------------------------------------------
# 3. Notarise — submit Daisy.app to Apple, wait, then staple the
#    ticket so it works offline.
# -----------------------------------------------------------------------------

echo "▸ [3/6] notarising Daisy.app… (this can take a few minutes)"
ZIP_FOR_NOTARY="${EXPORT_PATH}/Daisy-notary.zip"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_FOR_NOTARY}"
notarise_with_retry "${ZIP_FOR_NOTARY}" "Daisy.app"
xcrun stapler staple "${APP_PATH}"
echo "  → notarised + stapled"
echo

# -----------------------------------------------------------------------------
# 4. DMG — create-dmg packages Daisy.app into a signed disk image.
#    Notarise the DMG itself too — required by Sparkle so the
#    in-place install doesn't trip Gatekeeper.
# -----------------------------------------------------------------------------

echo "▸ [4/6] creating DMG…"
# We use `dmgbuild` (Python) instead of `create-dmg` because create-dmg's
# AppleScript-driven layout step silently fails on macOS Sequoia/Tahoe:
# the .background/dmg-background.tiff lands correctly, but the .DS_Store
# ends up missing the BkPa/pict alias, so Finder opens the DMG in
# default view with no branded background. dmgbuild writes .DS_Store
# programmatically via the `ds_store` library — no AppleScript involved.
if ! command -v dmgbuild >/dev/null 2>&1; then
    echo "  ✗ dmgbuild not installed. Run: pip3 install --user dmgbuild" >&2
    echo "    (or: pipx install dmgbuild)" >&2
    exit 1
fi
rm -f "${DMG_PATH}"

# Build a multi-resolution TIFF from the 1× + 2× PNGs so Finder serves
# the @2x variant on retina displays. tiffutil ships with macOS.
DMG_BG_1X="${DAISY_REPO}/scripts/assets/dmg-background.png"
DMG_BG_2X="${DAISY_REPO}/scripts/assets/dmg-background@2x.png"
DMG_BG_TIFF="${DAISY_REPO}/build/dmg-background.tiff"
DMG_BG_DEFINE=()
if [[ -f "${DMG_BG_1X}" && -f "${DMG_BG_2X}" ]]; then
    tiffutil -cathidpicheck "${DMG_BG_1X}" "${DMG_BG_2X}" -out "${DMG_BG_TIFF}" >/dev/null
    DMG_BG_DEFINE=(-D "background=${DMG_BG_TIFF}")
else
    echo "  ⚠ scripts/assets/dmg-background{,@2x}.png missing — falling back to plain DMG" >&2
fi

# Pass only Daisy.app via the dmgbuild settings — see
# scripts/dmgbuild_settings.py. We deliberately do NOT include the whole
# export directory, otherwise xcodebuild's exportArchive byproducts
# (DistributionSummary.plist, ExportOptions.plist, Packaging.log) and
# our notary ZIP would all show up in the DMG window.
DMG_SETTINGS="${DAISY_REPO}/scripts/dmgbuild_settings.py"
dmgbuild \
    -s "${DMG_SETTINGS}" \
    -D "app_path=${APP_PATH}" \
    "${DMG_BG_DEFINE[@]}" \
    "Daisy ${VERSION}" \
    "${DMG_PATH}"

# dmgbuild doesn't sign the DMG — do it ourselves so Gatekeeper accepts
# it post-notarisation. Equivalent to create-dmg's --codesign flag.
codesign --force --sign "${SIGNING_IDENTITY}" --timestamp "${DMG_PATH}"

echo "▸ [4b/6] notarising DMG…"
notarise_with_retry "${DMG_PATH}" "DMG"
xcrun stapler staple "${DMG_PATH}"
echo "  → ${DMG_PATH}"
# The app is inside the DMG now; the exported copy would only be one more
# "Daisy (x.y.z)" in "Open With".
rm -rf "${EXPORT_PATH}"
echo

# -----------------------------------------------------------------------------
# 5. Sparkle EdDSA signature — required for the appcast item.
# -----------------------------------------------------------------------------

echo "▸ [5/6] signing DMG for Sparkle (EdDSA)…"
SIGN_UPDATE="$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -type f 2>/dev/null | head -1)"
if [[ -z "${SIGN_UPDATE}" ]]; then
    # Fallback — Sparkle ships sign_update inside the framework. If
    # SPM hasn't built it yet, the user can download the release
    # archive from github.com/sparkle-project/Sparkle/releases.
    SIGN_UPDATE="$(command -v sign_update || true)"
fi
if [[ -z "${SIGN_UPDATE}" ]]; then
    echo "  ✗ sign_update not found. Build Daisy once after adding Sparkle SPM dep," >&2
    echo "    OR download Sparkle release archive and add bin/ to PATH." >&2
    exit 1
fi
SIGNATURE_OUTPUT="$("${SIGN_UPDATE}" "${DMG_PATH}")"
DMG_LENGTH=$(stat -f%z "${DMG_PATH}")
echo "  → ${SIGNATURE_OUTPUT}"
echo "  → length ${DMG_LENGTH} bytes"
echo

# -----------------------------------------------------------------------------
# 6. Publish — upload the DMG to R2, build the appcast <item> from the
#    release-notes markdown, inject it into daisy-web's public/appcast.xml,
#    and commit. Push is gated behind DAISY_AUTO_PUSH=1 so you get a chance
#    to review the commit before it goes live.
# -----------------------------------------------------------------------------

echo "▸ [6/6] publishing…"

NOTES_MD="${DAISY_REPO}/scripts/release-notes/${VERSION}.md"
# Р-3: the Russian notes are optional. Their absence must never fail a
# release — the appcast then carries the English block alone, exactly as
# it did before this existed.
NOTES_MD_RU="${DAISY_REPO}/scripts/release-notes/${VERSION}.ru.md"
if [[ ! -f "${NOTES_MD}" ]]; then
    echo "  ✗ Release notes missing: ${NOTES_MD}" >&2
    echo "    Create the file with markdown bullets (one '- text' per line)," >&2
    echo "    then re-run this script. The heading and any prose are ignored;" >&2
    echo "    only '- ' / '* ' bullets are picked up." >&2
    exit 1
fi

# Before the appcast: an item must never point at a DMG that isn't served,
# so a failed upload stops the release here (`release.sh upload-dmg` checks
# R2 alone).
upload_dmg "${DMG_PATH}" "${BUILD}"

# APPCAST_FILE defined at top — used here for inject step.
PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

# The build's own path (see upload_dmg): a version re-released under the
# same file name never reaches Sparkle as another build's bytes, which
# would fail the item's EdDSA signature.
VERSION="${VERSION}" \
BUILD="${BUILD}" \
CHANNEL="${CHANNEL}" \
PUBDATE="${PUBDATE}" \
DOWNLOAD_URL="${DOWNLOAD_URL_BASE}/${BUILD}/${DMG_NAME}" \
SOURCE_URL="$(source_url "${VERSION}")" \
SIGNATURE_LINE="${SIGNATURE_OUTPUT}" \
NOTES_MD="${NOTES_MD}" \
NOTES_MD_RU="${NOTES_MD_RU}" \
APPCAST_FILE="${APPCAST_FILE}" \
python3 <<'PY'
import os, re, html, pathlib, sys

version       = os.environ["VERSION"]
build         = os.environ["BUILD"]
pubdate       = os.environ["PUBDATE"]
download_url  = os.environ["DOWNLOAD_URL"]
source_url    = os.environ["SOURCE_URL"]
signature     = os.environ["SIGNATURE_LINE"].strip()
notes_path    = pathlib.Path(os.environ["NOTES_MD"])
notes_path_ru = pathlib.Path(os.environ["NOTES_MD_RU"])
appcast_path  = pathlib.Path(os.environ["APPCAST_FILE"])

# --- Convert markdown bullets to HTML <li> -----------------------------
# Р-2 (2026-09-23): this used to escape and stop, so 1.0.8.1 shipped with
# literal asterisks in the dialog — **Fixes a slow first launch...**. The
# old comment here claimed it "keeps simple `code` spans readable"; it
# did no such thing, which is how the gap survived.
#
# Two inline forms, and deliberately no more: release notes are a handful
# of bullets, and a full markdown parser here would be a dependency and a
# new way to break a release.
CODE_RE = re.compile(r"`([^`]+)`")
STRONG_RE = re.compile(r"\*\*(.+?)\*\*")

def inline_markdown(text):
    # Escape first — everything below emits tags, and anything the author
    # wrote that looks like a tag must already be inert by then.
    safe = html.escape(text)
    # Code spans are lifted out before ** is touched: asterisks inside a
    # code span are part of the code, not emphasis around it.
    spans = []
    def stash(match):
        spans.append(match.group(1))
        return f"\x00{len(spans) - 1}\x00"
    safe = CODE_RE.sub(stash, safe)
    safe = STRONG_RE.sub(r"<strong>\1</strong>", safe)
    for index, code in enumerate(spans):
        safe = safe.replace(f"\x00{index}\x00", f"<code>{code}</code>")
    return safe

def bullets_html(path):
    lines = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        stripped = raw.lstrip()
        if stripped.startswith(("- ", "* ")):
            lines.append(f"          <li>{inline_markdown(stripped[2:].rstrip())}</li>")
    return "\n".join(lines)

notes_html = bullets_html(notes_path)
if not notes_html:
    print(f"  ✗ No bullet lines found in {notes_path.name}", file=sys.stderr)
    sys.exit(1)

# The last line of each description: where the source of this version is
# (source_url in the shell above). The update window and the site's
# changelog both render the description, so the build is never offered
# without it. Generated: a notes file can't forget it or name another
# version. The class is what the site's changelog styles the line by
# (daisy-web looks for exactly `version-source`).
def source_line(label):
    link = html.escape(source_url)
    return f'        <p class="version-source">{label}: <a href="{link}">{link}</a></p>'

# Р-3: a second, Russian <description> in the same <item>. Sparkle picks
# by the system language and falls back to the untagged one, so English
# stays the default for everyone else.
notes_html_ru = bullets_html(notes_path_ru) if notes_path_ru.exists() else ""
if notes_html_ru:
    description_ru = f"""
      <description xml:lang="ru"><![CDATA[
        <h3>Что нового в {version}</h3>
        <ul>
{notes_html_ru}
        </ul>
{source_line("Исходный код этой версии")}
      ]]></description>"""
    print(f"  → Russian release notes included ({notes_path_ru.name})")
else:
    description_ru = ""
    print("  → No Russian release notes; the English block ships alone")

# --- Build the new <item> block ----------------------------------------
# Beta-channel items carry <sparkle:channel>beta</sparkle:channel>;
# Sparkle only offers them to clients whose updater delegate opted into
# the "beta" channel. Stable items stay untagged (visible to everyone).
channel = os.environ.get("CHANNEL", "stable")
channel_line = "\n      <sparkle:channel>beta</sparkle:channel>" if channel == "beta" else ""
item_block = f"""    <item>
      <title>Daisy {version}</title>
      <pubDate>{pubdate}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>{channel_line}
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
        <h3>What's new in {version}</h3>
        <ul>
{notes_html}
        </ul>
{source_line("Source for this version")}
      ]]></description>{description_ru}
      <enclosure
        url="{download_url}"
        {signature}
        type="application/octet-stream" />
    </item>"""

content = appcast_path.read_text(encoding="utf-8")

# On the very first real publish, strip the placeholder template comment
# *before* the idempotency check — otherwise the dummy <title>Daisy 1.0.1</title>
# inside the comment trips the "already published" path.
content = re.sub(
    r"\n[ \t]*<!--\s*\n[ \t]*Template item — REMOVE.*?-->\n",
    "\n",
    content,
    count=1,
    flags=re.DOTALL,
)

# Idempotency — if an <item> for this shortVersion is already in the
# appcast, REPLACE it (new build / new length / new edSignature / new
# pubDate / new release notes). Pre-1.0.3 we silently skipped, which
# left appcast pointing at the old build's enclosure metadata while
# the DMG file on disk had been overwritten with the new build —
# producing an EdDSA-signature mismatch that Sparkle silently rejects.
#
# Match the existing <item> block by its <title>Daisy {version}</title>
# and replace the whole block (between `<item>` and `</item>` lines)
# with the freshly-built item_block.
item_re = re.compile(
    r"[ \t]*<item>\s*\n[ \t]*<title>Daisy "
    + re.escape(version)
    + r"</title>.*?</item>\s*\n",
    re.DOTALL,
)
if item_re.search(content):
    # A function, not a template: in a template `\1` or `\g` in the notes
    # would be read as a group reference and any other backslash is an error.
    new_content = item_re.sub(lambda _: item_block + "\n", content, count=1)
    appcast_path.write_text(new_content, encoding="utf-8")
    print(f"  ↻ Replaced existing <item> for Daisy {version} (build {build})")
    sys.exit(0)

sentinel = "  </channel>"
if sentinel not in content:
    print(f"  ✗ Couldn't find {sentinel!r} in appcast.xml — aborting", file=sys.stderr)
    sys.exit(1)

new_content = content.replace(sentinel, item_block + "\n\n" + sentinel, 1)
appcast_path.write_text(new_content, encoding="utf-8")
print(f"  ✓ Injected <item> for Daisy {version} into appcast.xml")
PY

# Update the "Download for Mac" button target so the website CTA
# always points at the freshly-published DMG. Source of truth lives
# at daisy-web/lib/latestVersion.ts; the download channel helpers import
# from there. Synced with appcast.xml in the same commit so the
# Sparkle-update path (existing users) and the fresh-download path
# (new users from mydaisy.io) can't drift apart.
LATEST_VERSION_FILE="${DAISY_WEB_REPO}/lib/latestVersion.ts"
BETA_VERSION_FILE="${DAISY_WEB_REPO}/lib/betaVersion.ts"
if [[ "${CHANNEL}" == "beta" ]]; then
    # Beta releases leave the main Download button (stable channel,
    # lib/latestVersion.ts) untouched — only the site's small "newest
    # beta" link data is refreshed. Promote later with:
    #   ./scripts/release.sh promote ${VERSION}
    cat > "${BETA_VERSION_FILE}" <<EOF
// AUTO-GENERATED by release.sh on each BETA release. Do not hand-edit.
// Consumed by the site's small "newest beta" link; the main Download
// button reads lib/latestVersion.ts (stable channel) instead. The link
// hides itself when BETA_BUILD <= LATEST_BUILD (beta promoted/obsolete).
export const BETA_VERSION: string | null = "${VERSION}";
export const BETA_BUILD: number = ${BUILD};
export const BETA_DMG_URL: string | null = \`/downloads/${BUILD}/Daisy-${VERSION}.dmg\`;
EOF
    echo "  ✓ Rewrote lib/betaVersion.ts → ${VERSION} (beta; stable Download button untouched)"
elif [[ -f "${LATEST_VERSION_FILE}" ]]; then
    cat > "${LATEST_VERSION_FILE}" <<EOF
// AUTO-GENERATED by daisy-app/scripts/release.sh on each stable release.
// Do not hand-edit — release.sh overwrites the whole file as part of step
// [6/6] immediately after appcast.xml is updated.
//
// The single source of truth for "what version does mydaisy.io's
// Download button point at right now" lives here. appcast.xml is the
// source of truth for Sparkle update prompts (existing users); this
// file is the source of truth for fresh downloads (new users).
//
// Keeping them in sync is the responsibility of release.sh — both are
// rewritten in step [6/6] from the same VERSION argument.

export const LATEST_VERSION = "${VERSION}";
export const LATEST_BUILD = ${BUILD};
// The build number is in the path. The DMG file name only encodes the
// marketing version (Daisy-1.0.7.3.dmg), which gets re-published across
// builds; browsers that downloaded an earlier build used to stay stuck on
// the cached copy (build 33→35, 2026-05-27, fixed then with ?v=<build>).
// Since 2026-11-04 every build has its own never-overwritten object in R2.
export const LATEST_DMG_URL = \`/downloads/\${LATEST_BUILD}/Daisy-\${LATEST_VERSION}.dmg\`;
EOF
    echo "  ✓ Rewrote lib/latestVersion.ts → ${VERSION}"
else
    echo "  ⊘ lib/latestVersion.ts not found — skipping (web Hero/Download CTAs may serve a stale link)"
fi

# Committed here, pushed in 7b: the push is what publishes, and it waits
# for the source tag. The commit names its files (commit_daisy_web): the
# checkout is shared, and the index may hold another session's work.
# WEB_RELEASE_COMMITTED is commit_daisy_web's status: 0 committed, 1 nothing
# changed, 2 git refused.
CHANNEL_NOTE=""
[[ "${CHANNEL}" == "beta" ]] && CHANNEL_NOTE=", beta"
WEB_RELEASE_COMMITTED=0
commit_daisy_web "release: Daisy ${VERSION} (build ${BUILD}${CHANNEL_NOTE})" || WEB_RELEASE_COMMITTED=$?
if [[ "${WEB_RELEASE_COMMITTED}" == "0" ]]; then
    echo "  ✓ committed: release: Daisy ${VERSION} (build ${BUILD}${CHANNEL_NOTE})"
elif [[ "${WEB_RELEASE_COMMITTED}" == "1" ]]; then
    echo "  ⊘ nothing to commit in daisy-web (already published?)"
else
    echo "  ✗ Couldn't commit the release in ${DAISY_WEB_REPO}: appcast.xml and the version file are changed there, uncommitted." >&2
fi

# -----------------------------------------------------------------------------
# 7. Write the released version back into project.pbxproj so Xcode dev
#    builds report the real version. The archive above overrides
#    MARKETING_VERSION / CURRENT_PROJECT_VERSION on the command line,
#    so the pbxproj used to stay frozen at whatever was last hand-set
#    (1.0.7.3/45 for weeks) — every ⌘R build, About panel, and
#    Send Log Report header then lied about the version under test
#    (Egor, 2026-06-12). Replaces only ≥2-digit build numbers and
#    dotted versions of ≥4 chars, which matches the app target's pair
#    but not the test target's "1" / "1.0".
#    Appcast remains the authority for "next free build" (step 0).
# -----------------------------------------------------------------------------
PBXPROJ="${DAISY_REPO}/Daisy.xcodeproj/project.pbxproj"
if [[ -f "${PBXPROJ}" ]]; then
    sed -i '' \
        -e "s/CURRENT_PROJECT_VERSION = [0-9]\{2,\};/CURRENT_PROJECT_VERSION = ${BUILD};/g" \
        -e "s/MARKETING_VERSION = [0-9][0-9.]\{3,\};/MARKETING_VERSION = ${VERSION};/g" \
        "${PBXPROJ}"
    echo "  ✓ project.pbxproj bumped to ${VERSION} (${BUILD})"
fi

# -----------------------------------------------------------------------------
# 7b. The source of this build goes to GitHub as v<version>, and only then
#     daisy-web is pushed: the appcast item and the site's Download button
#     link to that tag, and the push is what makes them public.
# -----------------------------------------------------------------------------
tag_release_source "${VERSION}" "${BUILD}"
if [[ -f "${PBXPROJ}" ]] && ! git -C "${DAISY_REPO}" diff --quiet -- "${PBXPROJ_IN_REPO}" 2>/dev/null; then
    echo "    project.pbxproj is not committed — commit it with your next app-repo push"
fi
if [[ "${WEB_RELEASE_COMMITTED}" == "0" ]]; then
    push_daisy_web "${VERSION}" "${BUILD}" || true
elif [[ "${WEB_RELEASE_COMMITTED}" == "1" ]]; then
    WEB_PUSH_STATE="none"
else
    WEB_PUSH_STATE="held"
    echo "  ✗ daisy-web NOT pushed: there is no release commit. Commit and push it, after v${VERSION} is on GitHub:" >&2
    finish_tag_commands "${VERSION}" "${BUILD}" >&2 || true
    echo "      cd ${DAISY_WEB_REPO}" >&2
    echo "      git commit -m \"release: Daisy ${VERSION} (build ${BUILD}${CHANNEL_NOTE})\" -- public/appcast.xml lib/latestVersion.ts lib/betaVersion.ts" >&2
    echo "      git push origin main" >&2
fi

# The site push was held or refused: nothing a person sees has changed. Said
# plainly, with a status of its own, so that neither a person nor a session
# reads the run as a release.
if [[ "${WEB_PUSH_STATE}" == "held" ]]; then
    echo
    echo "────────────────────────────────────────────────────────────────"
    echo "  ✗ Daisy ${VERSION} (build ${BUILD}) is NOT published."
    echo "    Done     : the DMG is in R2 as downloads/${BUILD}/${DMG_NAME} (build ${BUILD} is taken)"
    if [[ -n "${WEB_RELEASE_COMMIT}" ]]; then
        echo "               the daisy-web commit is made locally (${WEB_RELEASE_COMMIT:0:7})"
    fi
    echo "    Not done : the daisy-web push — the appcast and the site still serve the previous version"
    echo "    What to do next is printed above."
    echo "────────────────────────────────────────────────────────────────"
    exit 2
fi

# -----------------------------------------------------------------------------
# 8. Stable releases also go to GitHub Releases with the same DMG. The
#    tag is on GitHub by now; without DAISY_AUTO_PUSH this prints the one
#    command to run after the pushes.
# -----------------------------------------------------------------------------
if [[ "${CHANNEL}" == "stable" ]]; then
    echo
    github_release "${VERSION}"
fi

echo
echo "────────────────────────────────────────────────────────────────"
if [[ "${WEB_PUSH_STATE}" == "manual" ]]; then
    echo "  ✓ Daisy ${VERSION} (build ${BUILD}) is built for the ${CHANNEL} channel — NOT published yet:"
    echo "    DAISY_AUTO_PUSH is off, the commands that publish it are above."
else
    echo "  ✓ Daisy ${VERSION} (build ${BUILD}) released on the ${CHANNEL} channel."
fi
echo "    DMG    : ${DMG_PATH}"
echo "    Length : ${DMG_LENGTH} bytes"
echo "    Item   : injected into appcast.xml"
echo "    Source : $(source_url "${VERSION}")"
app_branch_reminder
echo "────────────────────────────────────────────────────────────────"
