#!/bin/zsh
# End-to-end crash-recovery scenario (backlog P0: "kill -9 at minute 40,
# through the product, not a unit test").
#
#   1. launch the built app with --benchmark-record → it starts a mic
#      recording by itself;
#   2. wait RECORD_SECONDS (default 2400 = 40 min; use 120 for a smoke run);
#   3. kill -9 the process — no chance to flush anything;
#   4. relaunch normally → InterruptedRecordingRecovery runs on the first
#      Library scan and writes transcript.md for the crashed folder;
#   5. wait for the transcript, then report coverage:
#      archive seconds on disk vs. seconds recorded, and the recovered
#      transcript's duration_sec.
#
# usage: Benchmarks/kill_recovery.sh [RECORD_SECONDS] [OUTPUT_JSON]
# env:   DAISY_APP (default /Applications/Daisy.app)
#        DAISY_SESSIONS (default ~/Library/Application Support/Daisy/Sessions;
#                        point it at your chosen storage folder + /Daisy/Sessions)
#        RECOVERY_TIMEOUT seconds to wait for transcript.md (default 3600)
#
# Play something into the mic while it runs (a podcast on the speakers is
# fine): the scenario measures survival, not accuracy, but an all-silent
# archive is classified as empty rather than recoverable.
set -euo pipefail

record_seconds="${1:-2400}"
output_path="${2:-Benchmarks/runs/recovery-$(date +%Y%m%d-%H%M%S).json}"
app="${DAISY_APP:-/Applications/Daisy.app}"
sessions="${DAISY_SESSIONS:-$HOME/Library/Application Support/Daisy/Sessions}"
timeout="${RECOVERY_TIMEOUT:-3600}"

if pgrep -x Daisy >/dev/null; then
  echo "Daisy is already running — quit it first." >&2
  exit 65
fi
mkdir -p "$(dirname "$output_path")"

before=$(ls -1 "$sessions" 2>/dev/null | sort || true)
echo "[1/5] launching $app with --benchmark-record"
open -a "$app" --args --benchmark-record
sleep 15
newdir=$(comm -13 <(echo "$before") <(ls -1 "$sessions" | sort) | tail -1)
if [[ -z "$newdir" ]]; then
  echo "no new session folder appeared under $sessions — did recording start?" >&2
  exit 70
fi
session="$sessions/$newdir"
echo "      recording into $session"

echo "[2/5] recording for ${record_seconds}s"
sleep "$record_seconds"

echo "[3/5] kill -9"
pkill -9 -x Daisy
killed=$(date +%s)
# Seconds the recording actually ran: from the session folder's birth
# time (the app creates it the moment capture starts) to the kill.
created=$(stat -f %B "$session")
elapsed=$((killed - created))
sleep 2
if [[ ! -f "$session/.recording" ]]; then
  echo "      warning: no .recording marker in $session (recovery relies on it or on archive size)"
fi
archive_seconds=$(afinfo "$session"/microphone*.caf 2>/dev/null | awk '/estimated duration/ {s+=$3} END {print s+0}')
echo "      archive on disk: ${archive_seconds}s of ${elapsed}s"

echo "[4/5] relaunch → recovery"
open -a "$app"
deadline=$(( $(date +%s) + timeout ))
while [[ ! -f "$session/transcript.md" ]]; do
  if (( $(date +%s) > deadline )); then
    echo "      transcript.md did not appear within ${timeout}s" >&2
    break
  fi
  sleep 10
done
recovered=$(grep -m1 '^duration_sec:' "$session/transcript.md" 2>/dev/null | awk '{print $2}')
recovered="${recovered:-0}"
lines=$(grep -c '^\*\*\[' "$session/transcript.md" 2>/dev/null || echo 0)
outcome=$([[ -f "$session/transcript.md" ]] && echo recovered || echo missing)

echo "[5/5] report → $output_path"
cat > "$output_path" <<JSON
{
  "schema_version": 1,
  "scenario": "kill-9-mid-recording",
  "app": "$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo unknown) ($(defaults read "$app/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo unknown))",
  "session": "$newdir",
  "recorded_seconds": $elapsed,
  "archive_seconds_on_disk": $archive_seconds,
  "recovered_duration_sec": $recovered,
  "recovered_segments": $lines,
  "coverage": $(awk -v a="$archive_seconds" -v e="$elapsed" 'BEGIN { if (e > 0) printf "%.3f", a / e; else print 0 }'),
  "status": "$outcome",
  "measured_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
cat "$output_path"
