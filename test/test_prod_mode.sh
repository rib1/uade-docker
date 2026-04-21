#!/bin/bash

set -e

# A script to verify test-only endpoints stay unavailable when the normal app
# service runs with UADE_TEST_MODE disabled.

BASE_URL="http://uade-web:5000"

echo "--- Waiting for prod-mode service to become healthy ---"
retries=30
while ! curl -f "$BASE_URL/health" > /dev/null; do
  retries=$((retries - 1))
  if [ "$retries" -le 0 ]; then
    echo "Prod-mode service failed to start!"
    exit 1
  fi
  echo -n "."
  sleep 2
done
echo "Prod-mode service is healthy."

echo "--- Testing Prod Mode: /test endpoints return 404 ---"
for endpoint in \
  "POST /test/run-cleanup" \
  "OPTIONS /test/run-cleanup" \
  "POST /test/set-local-file-mtime" \
  "POST /test/create-stale-conversion-lock" \
  "POST /test/remove-cache-artifact" \
  "GET /test/flac-compression-count" \
  "POST /test/flac-compression-count" \
  "POST /test/remove-probed-module"; do
  method=${endpoint%% *}
  path=${endpoint#* }

  status_code=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$BASE_URL$path")
  echo "$method $path -> $status_code"
  if [ "$status_code" -ne 404 ]; then
    echo "Prod-mode test FAILED! Expected 404 for $method $path, got $status_code"
    exit 1
  fi
done

echo "--- Prod-mode test PASSED! All /test endpoints returned 404. ---"
