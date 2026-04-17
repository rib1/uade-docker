#!/bin/sh

set -eu

BASE_URL="${BASE_URL:-http://uade-web-player:5000}"
FIXTURES_DIR="${FIXTURES_DIR:-/fixtures}"
LOCAL_TEST_SERVER_URL="${LOCAL_TEST_SERVER_URL:-http://uade-test-http-server:8000}"
REPORT_DIR="${REPORT_DIR:-/reports/benchmarks}"
UPLOAD_FIXTURE_PATH="${BENCH_UPLOAD_FIXTURE_PATH:-${FIXTURES_DIR}/modules/space_debris.mod}"
TFMX_FIXTURE_URL="${BENCH_TFMX_FIXTURE_URL:-${LOCAL_TEST_SERVER_URL}/fixtures/modules/mdat.turrican_2_level_0-intro}"
TFMX_SAMPLE_URL="${BENCH_TFMX_SAMPLE_URL:-${LOCAL_TEST_SERVER_URL}/fixtures/modules/smpl.turrican_2_level_0-intro}"
REMOTE_FIXTURE_URL="${BENCH_REMOTE_FIXTURE_URL:-${LOCAL_TEST_SERVER_URL}/fixtures/modules/space_debris.mod}"

mkdir -p "$REPORT_DIR"

if [ "${BENCH_SUITE:-default}" = "cloudrun-semaphore" ]; then
  exec ./run-cloudrun-semaphore-balance.sh
fi

echo "Benchmark target: $BASE_URL"
echo "Reports directory: $REPORT_DIR"
echo "Using shared endpoint fixtures from: $FIXTURES_DIR"

for required_fixture in \
  "$UPLOAD_FIXTURE_PATH" \
  "${FIXTURES_DIR}/modules/gutenberg.txt" \
  "${FIXTURES_DIR}/modules/mdat.turrican_2_level_0-intro" \
  "${FIXTURES_DIR}/modules/smpl.turrican_2_level_0-intro"
do
  if [ ! -f "$required_fixture" ]; then
    echo "Missing required benchmark fixture: $required_fixture" >&2
    exit 1
  fi
done

echo ""
echo "--- Running smoke benchmark suite ---"
k6 run \
  --env BASE_URL="$BASE_URL" \
  --summary-export "$REPORT_DIR/smoke-summary.json" \
  ./bench/smoke.js

echo ""
echo "--- Running conversion benchmark suite ---"
k6 run \
  --env BASE_URL="$BASE_URL" \
  --env BENCH_FIXTURE_PATH="$UPLOAD_FIXTURE_PATH" \
  --env BENCH_FIXTURE_NAME="space_debris.mod" \
  --summary-export "$REPORT_DIR/conversion-summary.json" \
  ./bench/conversion.js

echo ""
echo "--- Running cache benchmark suite ---"
k6 run \
  --env BASE_URL="$BASE_URL" \
  --env BENCH_REMOTE_FIXTURE_URL="$REMOTE_FIXTURE_URL" \
  --summary-export "$REPORT_DIR/cache-summary.json" \
  ./bench/cache.js

echo ""
echo "--- Running streaming benchmark suite ---"
k6 run \
  --env BASE_URL="$BASE_URL" \
  --env BENCH_REMOTE_FIXTURE_URL="$TFMX_FIXTURE_URL" \
  --env BENCH_REMOTE_SAMPLE_URL="$TFMX_SAMPLE_URL" \
  --summary-export "$REPORT_DIR/streaming-summary.json" \
  ./bench/streaming.js

echo ""
echo "--- Running DAST-pattern benchmark suite ---"
k6 run \
  --env BASE_URL="$BASE_URL" \
  --env BENCH_UPLOAD_FIXTURE_PATH="$UPLOAD_FIXTURE_PATH" \
  --env BENCH_UPLOAD_FIXTURE_NAME="space_debris.mod" \
  --env BENCH_TFMX_FIXTURE_URL="$TFMX_FIXTURE_URL" \
  --env BENCH_TFMX_SAMPLE_URL="$TFMX_SAMPLE_URL" \
  --summary-export "$REPORT_DIR/dast-patterns-summary.json" \
  ./bench/dast-patterns.js
