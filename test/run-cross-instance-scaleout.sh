#!/bin/sh

set -eu

BASE_URL_A="${BASE_URL_A:-http://uade-web-a:5000}"
BASE_URL_B="${BASE_URL_B:-http://uade-web-b:5000}"
FIXTURES_DIR="${FIXTURES_DIR:-/fixtures}"
REPORT_FILE="${REPORT_FILE:-/reports/benchmarks/cross-instance-scaleout-summary.json}"
UPLOAD_FIXTURE_PATH="${BENCH_FIXTURE_PATH:-${FIXTURES_DIR}/modules/space_debris.mod}"
BENCH_STREAM_FIXTURE_URL="${BENCH_STREAM_FIXTURE_URL:-http://uade-test-http-server:8000/fixtures/modules/stormlord.ahx}"
BENCH_REMOTE_FIXTURE_URL="${BENCH_REMOTE_FIXTURE_URL:-http://uade-test-http-server:8000/fixtures/modules/mdat.turrican_2_level_0-intro}"
BENCH_REMOTE_SAMPLE_URL="${BENCH_REMOTE_SAMPLE_URL:-http://uade-test-http-server:8000/fixtures/modules/smpl.turrican_2_level_0-intro}"
BENCH_SCENARIO_DURATION="${BENCH_SCENARIO_DURATION:-5m}"
PLAY_FULL_VUS="${PLAY_FULL_VUS:-3}"
PLAY_RANGE_VUS="${PLAY_RANGE_VUS:-1}"
CONVERT_PROBED_VUS="${CONVERT_PROBED_VUS:-3}"
CONVERT_URL_VUS="${CONVERT_URL_VUS:-3}"

for required_fixture in \
  "$UPLOAD_FIXTURE_PATH" \
  "${FIXTURES_DIR}/modules/stormlord.ahx" \
  "${FIXTURES_DIR}/modules/gutenberg.txt" \
  "${FIXTURES_DIR}/modules/mdat.turrican_2_level_0-intro" \
  "${FIXTURES_DIR}/modules/smpl.turrican_2_level_0-intro"
do
  if [ ! -f "$required_fixture" ]; then
    echo "Missing required cross-instance benchmark fixture: $required_fixture" >&2
    exit 1
  fi
done

REPORT_DIR="$(dirname "$REPORT_FILE")"
mkdir -p "$REPORT_DIR"

echo "Cross-instance benchmark targets:"
echo "  A (conversion-heavy): $BASE_URL_A"
echo "  B (playback-only):    $BASE_URL_B"
echo "Report file: $REPORT_FILE"
echo "Scenario duration: $BENCH_SCENARIO_DURATION"
echo "Play VUs on B: full=$PLAY_FULL_VUS range=$PLAY_RANGE_VUS"
echo "Conversion VUs on A: probed=$CONVERT_PROBED_VUS convert-url=$CONVERT_URL_VUS"
echo "Warm play fixture URL on B: $BENCH_STREAM_FIXTURE_URL"

k6 run \
  --env BASE_URL_A="$BASE_URL_A" \
  --env BASE_URL_B="$BASE_URL_B" \
  --env BENCH_FIXTURE_PATH="$UPLOAD_FIXTURE_PATH" \
  --env BENCH_FIXTURE_NAME="space_debris.mod" \
  --env BENCH_STREAM_FIXTURE_URL="$BENCH_STREAM_FIXTURE_URL" \
  --env BENCH_REMOTE_FIXTURE_URL="$BENCH_REMOTE_FIXTURE_URL" \
  --env BENCH_REMOTE_SAMPLE_URL="$BENCH_REMOTE_SAMPLE_URL" \
  --env BENCH_SCENARIO_DURATION="$BENCH_SCENARIO_DURATION" \
  --env PLAY_FULL_VUS="$PLAY_FULL_VUS" \
  --env PLAY_RANGE_VUS="$PLAY_RANGE_VUS" \
  --env CONVERT_PROBED_VUS="$CONVERT_PROBED_VUS" \
  --env CONVERT_URL_VUS="$CONVERT_URL_VUS" \
  --summary-export "$REPORT_FILE" \
  ./bench/cross-instance-scaleout.js
