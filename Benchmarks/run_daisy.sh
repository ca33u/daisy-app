#!/bin/zsh
set -euo pipefail

if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "usage: $0 AUDIO OUTPUT_JSON [LANGUAGE] [SPEAKER_COUNT]" >&2
  exit 64
fi

audio_path="$1"
output_path="$2"
language="${3:-}"
speaker_count="${4:-}"
derived_data="${DAISY_BENCHMARK_DERIVED_DATA:-/tmp/DaisyBenchmarkBuild}"
request_path="/tmp/daisy-benchmark-request.plist"
input_path="/tmp/daisy-benchmark-input-$$.${audio_path##*.}"
result_path="/tmp/daisy-benchmark-result-$$.json"

cleanup() {
  rm -f "$request_path" "$result_path" "$input_path"
}
trap cleanup EXIT

if [[ ! -f "$audio_path" ]]; then
  echo "audio file not found: $audio_path" >&2
  exit 66
fi

mkdir -p "$(dirname "$output_path")"
cp "$audio_path" "$input_path"
rm -f "$request_path" "$result_path"
plutil -create xml1 "$request_path"
plutil -insert audio_path -string "$input_path" "$request_path"
plutil -insert output_path -string "$result_path" "$request_path"
plutil -insert original_audio_name -string "${audio_path:t}" "$request_path"
plutil -insert language -string "$language" "$request_path"
plutil -insert speaker_count -string "$speaker_count" "$request_path"
plutil -insert path -string "${DAISY_BENCHMARK_PATH:-block}" "$request_path"

xcodebuild \
  -project Daisy.xcodeproj \
  -scheme Daisy \
  -configuration Debug \
  -derivedDataPath "$derived_data" \
  -only-testing:DaisyTests/DaisyBenchmarkRunnerTests \
  test

test -s "$result_path"
cp "$result_path" "$output_path"
echo "Daisy hypothesis: $output_path"
