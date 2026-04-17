#!/bin/sh

set -eu

BASE_URL="${BASE_URL:-http://uade-web-player:5000}"
FIXTURES_DIR="${FIXTURES_DIR:-/fixtures}"
REPORT_FILE="${REPORT_FILE:-/reports/benchmarks/semaphore-balance-summary.json}"
UPLOAD_FIXTURE_PATH="${BENCH_FIXTURE_PATH:-${FIXTURES_DIR}/modules/space_debris.mod}"
BENCH_REMOTE_FIXTURE_URL="${BENCH_REMOTE_FIXTURE_URL:-http://uade-test-http-server:8000/fixtures/modules/mdat.turrican_2_level_0-intro}"
BENCH_REMOTE_SAMPLE_URL="${BENCH_REMOTE_SAMPLE_URL:-http://uade-test-http-server:8000/fixtures/modules/smpl.turrican_2_level_0-intro}"
PLAY_EXAMPLE_ID="${PLAY_EXAMPLE_ID:-wings-of-death-levels}"
BENCH_SCENARIO_DURATION="${BENCH_SCENARIO_DURATION:-8m}"
PLAY_FULL_VUS="${PLAY_FULL_VUS:-4}"
PLAY_RANGE_VUS="${PLAY_RANGE_VUS:-2}"
CONVERT_PROBED_VUS="${CONVERT_PROBED_VUS:-1}"
CONVERT_URL_VUS="${CONVERT_URL_VUS:-1}"

for required_fixture in \
  "$UPLOAD_FIXTURE_PATH" \
  "${FIXTURES_DIR}/modules/gutenberg.txt" \
  "${FIXTURES_DIR}/modules/mdat.turrican_2_level_0-intro" \
  "${FIXTURES_DIR}/modules/smpl.turrican_2_level_0-intro"
do
  if [ ! -f "$required_fixture" ]; then
    echo "Missing required semaphore benchmark fixture: $required_fixture" >&2
    exit 1
  fi
done

REPORT_DIR="$(dirname "$REPORT_FILE")"
mkdir -p "$REPORT_DIR"

echo "Cloud Run semaphore benchmark target: $BASE_URL"
echo "Report file: $REPORT_FILE"
echo "Scenario duration: $BENCH_SCENARIO_DURATION"
echo "Play VUs: full=$PLAY_FULL_VUS range=$PLAY_RANGE_VUS"
echo "Conversion VUs: probed=$CONVERT_PROBED_VUS convert-url=$CONVERT_URL_VUS"
echo "Play example id: $PLAY_EXAMPLE_ID"

k6 run \
  --env BASE_URL="$BASE_URL" \
  --env BENCH_FIXTURE_PATH="$UPLOAD_FIXTURE_PATH" \
  --env BENCH_FIXTURE_NAME="space_debris.mod" \
  --env BENCH_REMOTE_FIXTURE_URL="$BENCH_REMOTE_FIXTURE_URL" \
  --env BENCH_REMOTE_SAMPLE_URL="$BENCH_REMOTE_SAMPLE_URL" \
  --env PLAY_EXAMPLE_ID="$PLAY_EXAMPLE_ID" \
  --env BENCH_SCENARIO_DURATION="$BENCH_SCENARIO_DURATION" \
  --env PLAY_FULL_VUS="$PLAY_FULL_VUS" \
  --env PLAY_RANGE_VUS="$PLAY_RANGE_VUS" \
  --env CONVERT_PROBED_VUS="$CONVERT_PROBED_VUS" \
  --env CONVERT_URL_VUS="$CONVERT_URL_VUS" \
  --summary-export "$REPORT_FILE" \
  ./bench/semaphore-balance.js
