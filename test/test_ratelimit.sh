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
touch dummy.mod

# 3. Send requests to exceed the rate limit (10 per minute on /upload)
echo "--- Sending 11 requests to /upload to trigger rate limit ---"
for i in {1..10}; do
  echo -n "Request $i: "
  # We don't care about the output of the first 10, just that they are sent
  curl -s -o /dev/null -w "%{http_code}" -X POST -F "file=@dummy.mod" "$BASE_URL/upload"
  echo ""
done

echo -n "Request 11 (expecting 429): "
status_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -F "file=@dummy.mod" "$BASE_URL/upload")
echo "$status_code"

# 4. Clean up the dummy file
rm dummy.mod

# 5. Check the result
if [ "$status_code" -eq 429 ]; then
  echo "--- Rate limit test PASSED! ---"
  exit 0
else
  echo "--- Rate limit test FAILED! Expected 429, got $status_code ---"
  exit 1
fi
