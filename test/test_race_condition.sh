#!/bin/bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://uade-web-player-seeded:5000}"
PLAY_USER_AGENT="Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
URL_TO_TEST="${URL_TO_TEST:-http://uade-test-http-server:8000/fixtures/modules/space_debris.mod}"
SERVICE_READY_TIMEOUT_SECONDS="${SERVICE_READY_TIMEOUT_SECONDS:-60}"

echo "--- Testing race condition: parallel play requests stay read-only on cached FLAC ---"

perform_convert_url_flac_call() {
    local_url=$1
    JSON_PAYLOAD=$(jq -n --arg url "$local_url" '{url: $url}')

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -H "User-Agent: curl/8.0" \
        -d "$JSON_PAYLOAD" \
        "$BASE_URL/convert-url")

    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    RESPONSE_BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    echo "$HTTP_CODE"
    echo "$RESPONSE_BODY"
}

remove_cache_artifact() {
    local_file_id=$1
    local_ext=$2

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"file_id\":\"$local_file_id\",\"ext\":\"$local_ext\"}" \
        "$BASE_URL/test/remove-cache-artifact")

    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    RESPONSE_BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Failed to remove cache artifact ${local_file_id}${local_ext}"
        echo "Response body: $RESPONSE_BODY"
        exit 1
    fi
}

reset_flac_compression_counts() {
    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        "$BASE_URL/test/flac-compression-count")

    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    RESPONSE_BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Failed to reset FLAC compression counts"
        echo "Response body: $RESPONSE_BODY"
        exit 1
    fi
}

get_flac_compression_count() {
    local_file_id=$1

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" \
        "$BASE_URL/test/flac-compression-count?file_id=$local_file_id")

    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    RESPONSE_BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Failed to fetch FLAC compression count for ${local_file_id}"
        echo "Response body: $RESPONSE_BODY"
        exit 1
    fi

    echo "$RESPONSE_BODY" | jq -r .count
}

perform_play_request() {
    local_file_id=$1
    local_output_file=$2

    curl -s -D - -o /dev/null -w "\n%{http_code}" \
        -H "User-Agent: $PLAY_USER_AGENT" \
        "$BASE_URL/play/$local_file_id" > "$local_output_file"
}

wait_for_service() {
    echo "Waiting for uade-web-player to be available..."
    start_time=$(date +%s)
    while ! curl -fsS "$BASE_URL/health" > /dev/null; do
        current_time=$(date +%s)
        elapsed_seconds=$((current_time - start_time))
        if [ "$elapsed_seconds" -ge "$SERVICE_READY_TIMEOUT_SECONDS" ]; then
            echo "ERROR: uade-web-player did not become ready at $BASE_URL/health within ${SERVICE_READY_TIMEOUT_SECONDS}s"
            exit 1
        fi
        sleep 1
    done
    echo "Service is up!"
}

wait_for_service

HTTP_CODE_BODY=$(perform_convert_url_flac_call "$URL_TO_TEST")
HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)

if [ "$HTTP_CODE" -ne 200 ]; then
    echo "ERROR: Initial WAV convert-url call failed with HTTP $HTTP_CODE"
    echo "Response body: $BODY"
    exit 1
fi

FILE_ID=$(echo "$BODY" | jq -r .file_id)
AUDIO_FORMAT=$(echo "$BODY" | jq -r .audio_format)
if [ -z "$FILE_ID" ] || [ "$FILE_ID" = "null" ]; then
    echo "ERROR: file_id missing from initial response"
    echo "Response body: $BODY"
    exit 1
fi

if [ "$AUDIO_FORMAT" != "flac" ]; then
    echo "ERROR: Initial request did not establish a FLAC response starting point"
    echo "Response body: $BODY"
    exit 1
fi

reset_flac_compression_counts

PLAY_RESP_1=$(mktemp)
PLAY_RESP_2=$(mktemp)

cleanup_temp_files() {
    rm -f "$PLAY_RESP_1" "$PLAY_RESP_2"
}

trap cleanup_temp_files EXIT

perform_play_request "$FILE_ID" "$PLAY_RESP_1" &
PID_1=$!
perform_play_request "$FILE_ID" "$PLAY_RESP_2" &
PID_2=$!

wait "$PID_1"
wait "$PID_2"

for response_file in "$PLAY_RESP_1" "$PLAY_RESP_2"; do
    PLAY_HTTP_CODE=$(tail -n1 "$response_file")
    PLAY_HEADERS=$(sed '$d' "$response_file")

    if [ "$PLAY_HTTP_CODE" -ne 200 ] && [ "$PLAY_HTTP_CODE" -ne 206 ]; then
        echo "ERROR: Play endpoint returned unexpected HTTP $PLAY_HTTP_CODE"
        echo "Headers: $PLAY_HEADERS"
        exit 1
    fi

    if ! echo "$PLAY_HEADERS" | grep -qi "^Content-Type: audio/flac"; then
        echo "ERROR: Play endpoint did not serve FLAC during parallel playback"
        echo "Headers: $PLAY_HEADERS"
        exit 1
    fi
done

FLAC_COMPRESSION_COUNT=$(get_flac_compression_count "$FILE_ID")

if [ "$FLAC_COMPRESSION_COUNT" -ne 0 ]; then
    echo "ERROR: Expected parallel play requests not to trigger FLAC compression, got count=$FLAC_COMPRESSION_COUNT"
    exit 1
fi

echo "--- Parallel play requests completed successfully! ---"
echo "--- Race condition test passed: cached FLAC playback stayed read-only. ---"
