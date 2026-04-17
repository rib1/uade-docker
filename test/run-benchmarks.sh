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

suite_failures=0

run_suite() {
  suite_name="$1"
  shift

  echo ""
  echo "--- Running ${suite_name} benchmark suite ---"

  set +e
  "$@"
  status=$?
  set -e

  if [ "$status" -ne 0 ]; then
    echo "Benchmark suite failed: ${suite_name}" >&2
    suite_failures=1
  fi
}

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

run_suite "smoke" k6 run \
  --env BASE_URL="$BASE_URL" \
  --summary-export "$REPORT_DIR/smoke-summary.json" \
  ./bench/smoke.js

run_suite "conversion" k6 run \
  --env BASE_URL="$BASE_URL" \
  --env BENCH_FIXTURE_PATH="$UPLOAD_FIXTURE_PATH" \
  --env BENCH_FIXTURE_NAME="space_debris.mod" \
  --summary-export "$REPORT_DIR/conversion-summary.json" \
  ./bench/conversion.js

run_suite "cache" k6 run \
  --env BASE_URL="$BASE_URL" \
  --env BENCH_REMOTE_FIXTURE_URL="$REMOTE_FIXTURE_URL" \
  --summary-export "$REPORT_DIR/cache-summary.json" \
  ./bench/cache.js

run_suite "streaming" k6 run \
  --env BASE_URL="$BASE_URL" \
  --env BENCH_REMOTE_FIXTURE_URL="$TFMX_FIXTURE_URL" \
  --env BENCH_REMOTE_SAMPLE_URL="$TFMX_SAMPLE_URL" \
  --summary-export "$REPORT_DIR/streaming-summary.json" \
  ./bench/streaming.js

run_suite "DAST-pattern" k6 run \
  --env BASE_URL="$BASE_URL" \
  --env BENCH_UPLOAD_FIXTURE_PATH="$UPLOAD_FIXTURE_PATH" \
  --env BENCH_UPLOAD_FIXTURE_NAME="space_debris.mod" \
  --env BENCH_TFMX_FIXTURE_URL="$TFMX_FIXTURE_URL" \
  --env BENCH_TFMX_SAMPLE_URL="$TFMX_SAMPLE_URL" \
  --summary-export "$REPORT_DIR/dast-patterns-summary.json" \
  ./bench/dast-patterns.js

if [ "$suite_failures" -ne 0 ]; then
  exit 1
fi
