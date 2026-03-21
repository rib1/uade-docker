#!/bin/bash

# A script to test the uade-web rate limiting functionality.
# This script is intended to be run from inside the uade-test-runner container.

set -e

# Define the base URL for the API. 'uade-web' is the service name in docker-compose.
BASE_URL="http://uade-web:5000"

# 1. Wait for the service to be healthy
echo "--- Waiting for service to become healthy ---"
retries=30
while ! curl -f "$BASE_URL/health"; do
  retries=$((retries - 1))
  if [ $retries -le 0 ]; then
    echo "Service failed to start!"
    exit 1
  fi
  echo -n "."
  sleep 2
done
echo "Service is healthy."

# 2. Create a dummy file for upload on the fly
echo "--- Creating dummy file for upload ---"
mkdir -p fixtures/invalid
touch fixtures/invalid/empty.bin

# 3. Send requests to exceed the normal conversion rate limit (10 per minute on /upload)
echo "--- Sending 11 requests to /upload to trigger rate limit ---"
for i in {1..10}; do
  echo -n "Request $i: "
  # We don't care about the output of the first 10, just that they are sent
  curl -s -o /dev/null -w "%{http_code}" -X POST -F "file=@fixtures/invalid/empty.bin" "$BASE_URL/upload"
  echo ""
done

echo -n "Request 11 (expecting 429): "
status_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -F "file=@fixtures/invalid/empty.bin" "$BASE_URL/upload")
echo "$status_code"

# 4. Check the /upload result
if [ "$status_code" -eq 429 ]; then
  echo "--- /upload rate limit behaved as expected ---"
else
  echo "--- Rate limit test FAILED! Expected /upload request 11 to return 429, got $status_code ---"
  exit 1
fi

# 5. Verify /probe-upload allows more than the normal limit, then enforces its higher limit
echo "--- Sending 11 requests to /probe-upload; request 11 should still be allowed ---"
for i in {1..11}; do
  echo -n "Probe request $i: "
  probe_status=$(curl -s -o /dev/null -w "%{http_code}" -X POST -F "file=@fixtures/invalid/empty.bin" "$BASE_URL/probe-upload")
  echo "$probe_status"
  if [ "$probe_status" -eq 429 ]; then
    echo "--- Rate limit test FAILED! /probe-upload hit 429 too early on request $i ---"
    exit 1
  fi
done

echo "--- Sending probe requests 12-40 to reach the higher /probe-upload limit ---"
for i in {12..40}; do
  echo -n "Probe request $i: "
  probe_status=$(curl -s -o /dev/null -w "%{http_code}" -X POST -F "file=@fixtures/invalid/empty.bin" "$BASE_URL/probe-upload")
  echo "$probe_status"
  if [ "$probe_status" -eq 429 ]; then
    echo "--- Rate limit test FAILED! /probe-upload hit 429 too early on request $i ---"
    exit 1
  fi
done

echo -n "Probe request 41 (expecting 429): "
probe_status=$(curl -s -o /dev/null -w "%{http_code}" -X POST -F "file=@fixtures/invalid/empty.bin" "$BASE_URL/probe-upload")
echo "$probe_status"

if [ "$probe_status" -eq 429 ]; then
  echo "--- Rate limit test PASSED! /probe-upload limit is higher than /upload and still enforced. ---"
  exit 0
fi

echo "--- Rate limit test FAILED! Expected /probe-upload request 41 to return 429, got $probe_status ---"
exit 1
