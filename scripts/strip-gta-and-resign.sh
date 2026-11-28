#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
#
# strip-gta-and-resign.sh
#
# Re-sign the Release build with an empty entitlements set — strips
# com.apple.security.get-task-allow that Xcode auto-injects for
# Apple Development certs even in Release config. This isolates
# whether get-task-allow is what's causing tccd to silently reject
# Calendar prompts.
#
# Usage: ./scripts/strip-gta-and-resign.sh
set -euo pipefail

APP="$(cd "$(dirname "$0")/.." && pwd)/build/Build/Products/Release/Daisy.app"

if [[ ! -d "$APP" ]]; then
    echo "ERROR: Release build not found at $APP"
    echo "Run: xcodebuild -project Daisy.xcodeproj -scheme Daisy -configuration Release -derivedDataPath ./build clean build"
    exit 1
fi

# Entitlements: no get-task-allow (so the binary isn't debugger-attachable),
# but KEEP com.apple.security.personal-information.calendars — Hardened
# Runtime requires it for Calendar TCC prompts. See:
#   tccd log: "Prompting policy for hardened runtime; service:
#    kTCCServiceCalendar requires entitlement
#    com.apple.security.personal-information.calendars but it is missing"
ENT=$(mktemp -t daisy_strip_ent.XXXXXX.plist)
cat > "$ENT" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.personal-information.calendars</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
EOF

# Use SHA-1 hash directly because there are two certs in keychain with
# the same human-readable name "Apple Development: Egor Sazanov (UWWSDZZ8BJ)"
# which makes codesign ambiguous when matched by name.
# Picked the SHA Xcode itself uses for Daisy (visible in build logs).
IDENTITY="0405855227C50443D84EAA54D5AB7151C63D2629"

echo "=== Killing any running Daisy ==="
killall Daisy 2>/dev/null || true

echo "=== Stripping signature ==="
codesign --remove-signature "$APP"

echo "=== Re-signing Sparkle framework first (required) ==="
codesign --force --sign "$IDENTITY" \
    -o runtime \
    --timestamp=none \
    "$APP/Contents/Frameworks/Sparkle.framework/Versions/B"

echo "=== Re-signing Daisy with empty entitlements (no get-task-allow) ==="
codesign --force --sign "$IDENTITY" \
    --entitlements "$ENT" \
    -o runtime \
    --timestamp=none \
    --generate-entitlement-der \
    "$APP"

echo
echo "=== Verifying entitlements (should NOT contain get-task-allow) ==="
codesign -d --entitlements - "$APP" 2>&1 | grep -v "^Executable=" || true

echo
echo "=== Verifying signature ==="
codesign -dvv "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority"

echo
echo "=== Launching Daisy ==="
open "$APP"

rm -f "$ENT"

echo
echo "Done. Now try Connect Apple Calendar in the just-launched Daisy."
echo "If a system prompt appears -> get-task-allow WAS the culprit."
echo "If still silent -> root cause is elsewhere, share the next log."
