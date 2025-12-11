#!/bin/bash
set -e

# A script to test for race conditions by making simultaneous requests
# to the same conversion endpoint.

BASE_URL="http://uade-web-player:5000"
# This URL should point to a file that is not in the cache,
# so that conversion is triggered. We'll add a unique query string.
URL_TO_TEST="https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod"
# Make the URL unique to bypass any caching layers
UNIQUE_URL="${URL_TO_TEST}?racetest=$(date +%s)"

NUM_REQUESTS=20
PIDS=()

echo "--- Testing for race conditions with $NUM_REQUESTS simultaneous requests to: $UNIQUE_URL ---"

# Function to make a single request
make_request() {
    local_url=$1
    local_index=$2
    echo "  [Request $local_index] Firing request..."
    JSON_PAYLOAD=$(jq -n --arg url "$local_url" '{url: $url}')
    CURL_HEADERS=(-H "Content-Type: application/json")
    
    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        "${CURL_HEADERS[@]}" \
        -d "$JSON_PAYLOAD" \
        "$BASE_URL/convert-url")
    
    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    RESPONSE_BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -eq 200 ]; then
        echo "  [Request $local_index] SUCCESS: Received HTTP 200"
    else
        echo "  [Request $local_index] ERROR: Received HTTP $HTTP_CODE"
        echo "  [Request $local_index] Response body: $RESPONSE_BODY"
        exit 1 # Exit with an error code
    fi
}

# Fire off all requests in the background
for i in $(seq 1 $NUM_REQUESTS); do
    make_request "$UNIQUE_URL" "$i" &
    PIDS+=($!)
done

# Wait for all background jobs to complete
echo "--- Waiting for all requests to complete... ---"
for pid in "${PIDS[@]}"; do
    wait "$pid"
done

echo "--- All simultaneous requests completed successfully! ---"
echo "--- Race condition test passed! ---"
