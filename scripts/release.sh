#!/usr/bin/env bash
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
#
# The publish step copies the DMG, injects the appcast item, updates the
# channel pointer, and commits daisy-web. DAISY_AUTO_PUSH=1 also pushes it.
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
DOWNLOAD_URL_BASE="https://mydaisy.io/downloads"

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
# github_release <marketing-version>
#
# Every stable release is also a GitHub Release with the SAME DMG the site
# serves (2026-10-07): mydaisy.io says so, and that has to stay true. Runs
# after `promote` and after a stable release; `release.sh github-release
# <version>` runs it alone.
#
# The DMG is taken from daisy-web/public/downloads — the published bytes,
# never a rebuild. The release hangs on the tag v<version>, which must
# already be on GitHub: this script never pushes the app repository, so
# for a stable/hotfix release (tagged after the build, see RELEASING.md)
# it prints the command to run once the tag is pushed. Publishing is
# gated behind DAISY_AUTO_PUSH=1, like the daisy-web push. Never fails
# the release — the site is already published by the time this runs.
# -----------------------------------------------------------------------------
GITHUB_REPO="${DAISY_GITHUB_REPO:-ca33u/daisy-app}"

github_release() {
    local version="$1"
    local tag="v${version}"
    local dmg="${DAISY_WEB_REPO}/public/downloads/Daisy-${version}.dmg"
    local notes="${DAISY_REPO}/scripts/release-notes/${version}.md"
    local retry="./scripts/release.sh github-release ${version}"

    echo "▸ GitHub Release ${tag} on ${GITHUB_REPO}…"
    if [[ ! -f "${dmg}" ]]; then
        echo "  ⚠ ${dmg} not found — no GitHub Release. Fix, then: ${retry}" >&2
        return 0
    fi
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

    local sha body latest_flag="--latest=false" site_latest=""
    if ! sha=$(shasum -a 256 "${dmg}" | awk '{print $1}') || [[ -z "${sha}" ]]; then
        echo "  ⚠ couldn't hash ${dmg}. Retry: ${retry}" >&2
        return 0
    fi
    if ! body=$(mktemp); then
        echo "  ⚠ mktemp failed. Retry: ${retry}" >&2
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
    rm -f "${body}"
    return 0
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
// ?v= is a cache-bust key — see release.sh step [6/6] notes.
export const LATEST_DMG_URL = \`/downloads/Daisy-\${LATEST_VERSION}.dmg?v=\${LATEST_BUILD}\`;
EOF
    (
        cd "${DAISY_WEB_REPO}"
        git add public/appcast.xml lib/latestVersion.ts
        if git diff --staged --quiet; then
            echo "  ⊘ nothing to promote (already stable?)"
        else
            git commit -m "release: promote Daisy ${PROMOTE_VERSION} (build ${PROMOTED_BUILD}) to stable" >/dev/null
            echo "  ✓ Daisy ${PROMOTE_VERSION} (build ${PROMOTED_BUILD}) promoted to stable"
            if [[ "${DAISY_AUTO_PUSH:-0}" == "1" ]]; then
                git push
                echo "  ✓ pushed daisy-web — Vercel deploys in 1-2 min"
            else
                echo "    Push:   cd ${DAISY_WEB_REPO} && git push"
            fi
        fi
    )
    github_release "${PROMOTE_VERSION}"
    exit 0
fi

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <marketing-version> <build-number> [stable|beta]" >&2
    echo "  e.g.  $0 1.0.1 3           # stable (default)" >&2
    echo "        $0 1.0.8 62 beta     # beta channel (opt-in clients only)" >&2
    echo "        $0 promote 1.0.8     # beta → stable, no rebuild" >&2
    echo "        $0 github-release 1.0.8  # GitHub Release with the published DMG" >&2
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

if ! git -C "${DAISY_REPO}" diff --quiet || ! git -C "${DAISY_REPO}" diff --cached --quiet; then
    echo "  ⚠ Working tree has uncommitted changes — releasing from a dirty tree."
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
    if ! xcodebuild \
        -project "${DAISY_REPO}/Daisy.xcodeproj" \
        -scheme "${SCHEME}" \
        -configuration Debug \
        -destination 'platform=macOS' \
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
# 6. Publish — copy DMG to daisy-web, build the appcast <item> from the
#    release-notes markdown, inject it into public/appcast.xml, and
#    commit. Push is gated behind DAISY_AUTO_PUSH=1 so you get a chance
#    to review the commit before it goes live.
# -----------------------------------------------------------------------------

echo "▸ [6/6] publishing to daisy-web…"

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

mkdir -p "${DAISY_WEB_REPO}/public/downloads"
cp "${DMG_PATH}" "${DAISY_WEB_REPO}/public/downloads/${DMG_NAME}"
echo "  → DMG copied: public/downloads/${DMG_NAME}"

# APPCAST_FILE defined at top — used here for inject step.
PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")

VERSION="${VERSION}" \
BUILD="${BUILD}" \
CHANNEL="${CHANNEL}" \
PUBDATE="${PUBDATE}" \
DOWNLOAD_URL="${DOWNLOAD_URL_BASE}/${DMG_NAME}" \
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
    new_content = item_re.sub(item_block + "\n", content, count=1)
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
export const BETA_DMG_URL: string | null = \`/downloads/Daisy-${VERSION}.dmg?v=${BUILD}\`;
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
// ?v=\${LATEST_BUILD} is a cache-bust query string. DMG filename only
// encodes the marketing version (Daisy-1.0.7.3.dmg) and gets re-published
// across builds under the same marketing version. Without the query
// string, browsers that downloaded an earlier build stay stuck on the
// cached copy for the lifetime of /downloads' Cache-Control max-age.
// Bumping the build number on every release moves the cache key forward
// so the next visit fetches the freshly-published binary. Added
// 2026-05-27 after build 33→35 cache-trap caught users on stale DMG.
export const LATEST_DMG_URL = \`/downloads/Daisy-\${LATEST_VERSION}.dmg?v=\${LATEST_BUILD}\`;
EOF
    echo "  ✓ Rewrote lib/latestVersion.ts → ${VERSION}"
else
    echo "  ⊘ lib/latestVersion.ts not found — skipping (web Hero/Download CTAs may serve a stale link)"
fi

(
    cd "${DAISY_WEB_REPO}"
    git add public/appcast.xml "public/downloads/${DMG_NAME}" lib/latestVersion.ts
    [[ -f lib/betaVersion.ts ]] && git add lib/betaVersion.ts
    if git diff --staged --quiet; then
        echo "  ⊘ nothing to commit in daisy-web (already published?)"
    else
        CHANNEL_NOTE=""
        [[ "${CHANNEL}" == "beta" ]] && CHANNEL_NOTE=", beta"
        git commit -m "release: Daisy ${VERSION} (build ${BUILD}${CHANNEL_NOTE})" >/dev/null
        echo "  ✓ committed: release: Daisy ${VERSION} (build ${BUILD}${CHANNEL_NOTE})"
        if [[ "${DAISY_AUTO_PUSH:-0}" == "1" ]]; then
            git push
            echo "  ✓ pushed daisy-web — Vercel deploys in 1-2 min"
        else
            echo "    Review: cd ${DAISY_WEB_REPO} && git show HEAD"
            echo "    Push:   cd ${DAISY_WEB_REPO} && git push"
            echo "    (or rerun with DAISY_AUTO_PUSH=1 to push automatically)"
        fi
    fi
)

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
    echo "  ✓ project.pbxproj bumped to ${VERSION} (${BUILD}) — commit it with your next app-repo push"
fi

# -----------------------------------------------------------------------------
# 8. Stable releases also go to GitHub Releases with the same DMG. The
#    tag usually isn't pushed yet at this point (RELEASING.md §3), so
#    this most often prints the one command to run after pushing it.
# -----------------------------------------------------------------------------
if [[ "${CHANNEL}" == "stable" ]]; then
    echo
    github_release "${VERSION}"
fi

echo
echo "────────────────────────────────────────────────────────────────"
echo "  ✓ Daisy ${VERSION} (build ${BUILD}) released on the ${CHANNEL} channel."
echo "    DMG    : ${DMG_PATH}"
echo "    Length : ${DMG_LENGTH} bytes"
echo "    Item   : injected into appcast.xml"
echo "────────────────────────────────────────────────────────────────"
