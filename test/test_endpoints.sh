#!/bin/bash

set -e

# A script to test the uade-web API endpoints.
# This script is intended to be run from a Docker container that has curl and jq installed.

# Define the base URL for the API
BASE_URL="${TEST_BASE_URL:-http://uade-web-player:5000}"
LOCAL_TEST_SERVER_PORT=8000
LOCAL_TEST_SERVER_URL="http://uade-test-http-server:$LOCAL_TEST_SERVER_PORT"
SKIP_MODARCHIVE_TESTS="${SKIP_MODARCHIVE_TESTS:-0}"

./prepare-endpoint-fixtures.sh

should_skip_modarchive_tests() {
    [ "$SKIP_MODARCHIVE_TESTS" = "1" ]
}

skip_test() {
    echo "SKIPPED: $1"
    echo ""
}


# Helper function to perform a convert-url API call
# Arguments:
# 1. URL to convert (string)
# 2. User-Agent to pass (string)
# Returns: Prints HTTP_CODE (first line) and BODY (second line) to stdout.
_perform_convert_url_call_with_agent_header() {
    LOCAL_URL=$1
    LOCAL_USER_AGENT_HEADER=$2

    JSON_PAYLOAD=$(jq -n --arg url "$LOCAL_URL" '{url: $url}')

    CURL_HEADERS=(-H "Content-Type: application/json")
    if [ -n "$LOCAL_USER_AGENT_HEADER" ]; then
        CURL_HEADERS+=(-H "User-Agent: $LOCAL_USER_AGENT_HEADER")
    fi

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        "${CURL_HEADERS[@]}" \
        -d "$JSON_PAYLOAD" \
        "$BASE_URL/convert-url")

    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    RESPONSE_BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    echo "$HTTP_CODE"
    echo "$RESPONSE_BODY"
}

# Helper function to perform a convert-url API call
# Arguments:
# 1. URL to convert (string)
# 2. Optional sample URL (string)
# Returns: Prints HTTP_CODE (first line) and BODY (second line) to stdout.
_perform_convert_url_call() {
    LOCAL_URL=$1
    LOCAL_SAMPLE_URL=$2

    if [ -z "$LOCAL_SAMPLE_URL" ]; then
        JSON_PAYLOAD=$(jq -n --arg url "$LOCAL_URL" '{url: $url}')
    else
        JSON_PAYLOAD=$(jq -n --arg url "$LOCAL_URL" --arg sample_url "$LOCAL_SAMPLE_URL" '{url: $url, sample_url: $sample_url}')
    fi

    CURL_HEADERS=(-H "Content-Type: application/json")

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        "${CURL_HEADERS[@]}" \
        -d "$JSON_PAYLOAD" \
        "$BASE_URL/convert-url")

    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    RESPONSE_BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    echo "$HTTP_CODE"
    echo "$RESPONSE_BODY"
}

# Helper function to perform a probe-url API call
# Arguments:
# 1. URL to probe (string)
# 2. Optional sample URL (string)
# Returns: Prints HTTP_CODE (first line) and BODY (second line) to stdout.
_perform_probe_url_call() {
    LOCAL_URL=$1
    LOCAL_SAMPLE_URL=$2

    if [ -z "$LOCAL_SAMPLE_URL" ]; then
        JSON_PAYLOAD=$(jq -n --arg url "$LOCAL_URL" '{url: $url}')
    else
        JSON_PAYLOAD=$(jq -n --arg url "$LOCAL_URL" --arg sample_url "$LOCAL_SAMPLE_URL" '{url: $url, sample_url: $sample_url}')
    fi

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "$JSON_PAYLOAD" \
        "$BASE_URL/probe-url")

    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    RESPONSE_BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    echo "$HTTP_CODE"
    echo "$RESPONSE_BODY"
}

# Function to test a URL
# Arguments:
# 1. Test name (string)
# 2. URL to test (string)
# 3. Optional sample URL (string)
test_url() {
    TEST_NAME=$1
    URL=$2
    SAMPLE_URL=$3

    echo "--- Testing $TEST_NAME: $URL ---"

    HTTP_CODE_BODY=$(_perform_convert_url_call "$URL" "$SAMPLE_URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)

    if [ "$HTTP_CODE" -eq 200 ]; then
        echo "SUCCESS: Received HTTP 200"
        echo "Response body: $BODY"
    # Allow 500 for the negative test case
    elif [[ "$TEST_NAME" == "Negative case (non-module)" && "$HTTP_CODE" -eq 500 ]]; then
        echo "SUCCESS: Received HTTP 500 as expected for negative test case"
        echo "Response body: $BODY"
    else
        echo "ERROR: Received HTTP $HTTP_CODE for test '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi
    echo ""
}

# Function to test security-related URL rejections
# Arguments:
# 1. Test name (string)
# 2. URL to test (string)
# 3. Optional sample URL (string) - for dual-file modules
test_security_url() {
    TEST_NAME=$1
    URL=$2
    SAMPLE_URL=$3

    echo "--- Testing Security: $TEST_NAME: $URL ---"

    HTTP_CODE_BODY=$(_perform_convert_url_call "$URL" "$SAMPLE_URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)

    if [ "$HTTP_CODE" -eq 400 ]; then
        echo "SUCCESS: Received HTTP 400 as expected"
        echo "Response body: $BODY"
    else
        echo "ERROR: Received HTTP $HTTP_CODE (expected 400) for test '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi
    echo ""
}

test_probe_url() {
    TEST_NAME=$1
    URL=$2
    SAMPLE_URL=$3

    echo "--- Testing Probe URL: $TEST_NAME ---"

    HTTP_CODE_BODY=$(_perform_probe_url_call "$URL" "$SAMPLE_URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Received HTTP $HTTP_CODE for probe test '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    OK=$(echo "$BODY" | jq -r .ok)
    PLAYABLE=$(echo "$BODY" | jq -r .playable)
    MODULE_NAME=$(echo "$BODY" | jq -r .module_name)
    PLAYER_FORMAT=$(echo "$BODY" | jq -r .player_format)

    if [ "$OK" != "true" ] || [ "$PLAYABLE" != "true" ]; then
        echo "ERROR: Probe did not report ok=true and playable=true for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    if [ -z "$MODULE_NAME" ] || [ "$MODULE_NAME" == "null" ]; then
        echo "ERROR: Probe response missing module_name for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    if [ -z "$PLAYER_FORMAT" ] || [ "$PLAYER_FORMAT" == "null" ]; then
        echo "ERROR: Probe response missing player_format for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    echo "SUCCESS: Probe returned playable metadata."
    echo "Response body: $BODY"
    echo ""
}

test_probe_error() {
    TEST_NAME=$1
    URL=$2
    SAMPLE_URL=$3
    EXPECTED_STATUS=$4
    EXPECTED_ERROR_SUBSTRING=$5

    echo "--- Testing Probe Error: $TEST_NAME ---"

    HTTP_CODE_BODY=$(_perform_probe_url_call "$URL" "$SAMPLE_URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)

    if [ "$HTTP_CODE" -ne "$EXPECTED_STATUS" ]; then
        echo "ERROR: Probe returned HTTP $HTTP_CODE (expected $EXPECTED_STATUS) for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    if [ -n "$EXPECTED_ERROR_SUBSTRING" ] && ! echo "$BODY" | grep -q "$EXPECTED_ERROR_SUBSTRING"; then
        echo "ERROR: Probe error message mismatch for '$TEST_NAME'"
        echo "Expected substring: '$EXPECTED_ERROR_SUBSTRING'"
        echo "Response body: $BODY"
        exit 1
    fi

    echo "SUCCESS: Probe returned expected error."
    echo "Response body: $BODY"
    echo ""
}

# Function to test a successful file probe-upload
# Arguments:
# 1. Test name (string)
# 2. File path to local module (string)
test_probe_upload() {
    TEST_NAME=$1
    FILE_PATH=$2

    echo "--- Testing Probe Upload: $TEST_NAME ---"

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST -F "file=@$FILE_PATH" "$BASE_URL/probe-upload")
    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Received HTTP $HTTP_CODE for probe-upload test '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    OK=$(echo "$BODY" | jq -r .ok)
    PLAYABLE=$(echo "$BODY" | jq -r .playable)
    MODULE_NAME=$(echo "$BODY" | jq -r .module_name)
    PLAYER_FORMAT=$(echo "$BODY" | jq -r .player_format)

    if [ "$OK" != "true" ] || [ "$PLAYABLE" != "true" ]; then
        echo "ERROR: Probe upload did not report ok=true and playable=true for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    if [ -z "$MODULE_NAME" ] || [ "$MODULE_NAME" == "null" ]; then
        echo "ERROR: Probe upload response missing module_name for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    if [ -z "$PLAYER_FORMAT" ] || [ "$PLAYER_FORMAT" == "null" ]; then
        echo "ERROR: Probe upload response missing player_format for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    # Verify no conversion fields are present (probe should not convert)
    PLAY_URL=$(echo "$BODY" | jq -r .play_url)
    DOWNLOAD_URL=$(echo "$BODY" | jq -r .download_url)
    if [ "$PLAY_URL" != "null" ] || [ "$DOWNLOAD_URL" != "null" ]; then
        echo "ERROR: Probe upload response contains conversion fields for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    echo "SUCCESS: Probe upload returned playable metadata."
    echo "Response body: $BODY"
    echo ""
}

# Function to test probe-upload error cases
# Arguments:
# 1. Test name (string)
# 2. File path to local file (string)
# 3. Expected HTTP status (integer)
# 4. Expected error substring (string, optional)
test_probe_upload_error() {
    TEST_NAME=$1
    FILE_PATH=$2
    EXPECTED_STATUS=$3
    EXPECTED_ERROR_SUBSTRING=$4

    echo "--- Testing Probe Upload Error: $TEST_NAME ---"

    # Use a specific curl command for empty file test
    if [[ "$TEST_NAME" == *"empty"* ]]; then
        RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST -F "file=;filename=empty.bin" "$BASE_URL/probe-upload")
    else
        RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST -F "file=@$FILE_PATH" "$BASE_URL/probe-upload")
    fi

    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne "$EXPECTED_STATUS" ]; then
        echo "ERROR: Probe upload returned HTTP $HTTP_CODE (expected $EXPECTED_STATUS) for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    if [ -n "$EXPECTED_ERROR_SUBSTRING" ] && ! echo "$BODY" | grep -q "$EXPECTED_ERROR_SUBSTRING"; then
        echo "ERROR: Probe upload error message mismatch for '$TEST_NAME'"
        echo "Expected substring: '$EXPECTED_ERROR_SUBSTRING'"
        echo "Response body: $BODY"
        exit 1
    fi

    echo "SUCCESS: Probe upload returned expected error."
    echo "Response body: $BODY"
    echo ""
}

test_probe_upload_preserves_negative_cache() {
    TEST_NAME=$1
    FILE_PATH=$2
    MODULE_HASH=$(md5sum "$FILE_PATH" | awk '{print $1}')

    echo "--- Testing Probe Upload Negative Cache Preservation: $TEST_NAME ---"

    for attempt in 1 2; do
        RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST -F "file=@$FILE_PATH" "$BASE_URL/probe-upload")
        HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
        BODY=$(echo "$RESPONSE_ALL" | sed '$d')

        if [ "$HTTP_CODE" -ne 500 ]; then
            echo "ERROR: Probe upload attempt $attempt returned HTTP $HTTP_CODE (expected 500) for '$TEST_NAME'"
            echo "Response body: $BODY"
            exit 1
        fi

        if ! echo "$BODY" | grep -q "Could not detect module metadata"; then
            echo "ERROR: Probe upload attempt $attempt returned unexpected error body for '$TEST_NAME'"
            echo "Response body: $BODY"
            exit 1
        fi
    done

    CONVERT_RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"module_hash\":\"$MODULE_HASH\",\"filename\":\"$(basename "$FILE_PATH")\"}" \
        "$BASE_URL/convert-probed")
    CONVERT_HTTP_CODE=$(echo "$CONVERT_RESPONSE_ALL" | tail -n1)
    CONVERT_BODY=$(echo "$CONVERT_RESPONSE_ALL" | sed '$d')

    if [ "$CONVERT_HTTP_CODE" -ne 404 ]; then
        echo "ERROR: convert-probed returned HTTP $CONVERT_HTTP_CODE (expected 404) for '$TEST_NAME'"
        echo "Response body: $CONVERT_BODY"
        exit 1
    fi

    if ! echo "$CONVERT_BODY" | grep -q "Module not found"; then
        echo "ERROR: convert-probed returned unexpected body for '$TEST_NAME'"
        echo "Response body: $CONVERT_BODY"
        exit 1
    fi

    echo "SUCCESS: Repeated invalid probe uploads preserved the negative cache marker."
    echo ""
}

# Test probe-upload with no file field at all
test_probe_upload_no_file() {
    echo "--- Testing Probe Upload: No file field ---"

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/probe-upload")
    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 400 ]; then
        echo "ERROR: Probe upload without file returned HTTP $HTTP_CODE (expected 400)"
        echo "Response body: $BODY"
        exit 1
    fi

    if ! echo "$BODY" | grep -q "No file provided"; then
        echo "ERROR: Unexpected error message for no-file probe upload"
        echo "Response body: $BODY"
        exit 1
    fi

    echo "SUCCESS: Probe upload correctly rejected request with no file."
    echo ""
}

# Test probe-upload with wrong HTTP method (GET instead of POST)
test_probe_upload_wrong_method() {
    echo "--- Testing Probe Upload: Wrong HTTP method (GET) ---"

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" "$BASE_URL/probe-upload")
    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)

    if [ "$HTTP_CODE" -ne 405 ]; then
        echo "ERROR: GET /probe-upload returned HTTP $HTTP_CODE (expected 405)"
        exit 1
    fi

    echo "SUCCESS: Probe upload correctly rejected GET request with 405."
    echo ""
}

# Test probe-upload with path traversal in filename
# Arguments:
# 1. File path to a valid local module (string)
test_probe_upload_path_traversal_filename() {
    FILE_PATH=$1

    echo "--- Testing Probe Upload: Path traversal filename ---"

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -F "file=@$FILE_PATH;filename=../../etc/passwd" \
        "$BASE_URL/probe-upload")
    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Probe upload with traversal filename returned HTTP $HTTP_CODE (expected 200 with sanitized filename)"
        echo "Response body: $BODY"
        exit 1
    fi

    # Verify the filename was sanitized (_safe_client_filename strips path traversal)
    FILENAME=$(echo "$BODY" | jq -r .filename)
    if echo "$FILENAME" | grep -q "\.\."; then
        echo "ERROR: Probe upload filename contains path traversal: '$FILENAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    echo "SUCCESS: Probe upload sanitized path traversal filename to '$FILENAME'."
    echo ""
}

test_probe_upload_oversized_payload_shape() {
    TEST_NAME=$1
    FILE_PATH=$2

    echo "--- Testing Probe Upload Error Payload: $TEST_NAME ---"

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST -F "file=@$FILE_PATH" "$BASE_URL/probe-upload")
    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 413 ]; then
        echo "ERROR: Probe upload oversized payload test returned HTTP $HTTP_CODE (expected 413)"
        echo "Response body: $BODY"
        exit 1
    fi

    assert_request_entity_too_large_payload "$BODY" "$TEST_NAME"

    echo "SUCCESS: Probe upload oversized file returned the shared 413 payload shape."
    echo "Response body: $BODY"
    echo ""
}

# ---------- Convert-probed tests ----------

# Test the full probe → convert-probed → play workflow
# Arguments:
# 1. Test name (string)
# 2. File path to local module (string)
# 3. Expected module name (string)
# 4. Expected player format (string)
test_probe_convert_play_flow() {
    TEST_NAME=$1
    FILE_PATH=$2
    EXPECTED_MODULE_NAME=$3
    EXPECTED_PLAYER_FORMAT=$4

    echo "--- Testing Probe→Convert-Probed→Play: $TEST_NAME ---"

    # Step 1: Probe the file
    PROBE_RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST -F "file=@$FILE_PATH" "$BASE_URL/probe-upload")
    PROBE_HTTP_CODE=$(echo "$PROBE_RESPONSE_ALL" | tail -n1)
    PROBE_BODY=$(echo "$PROBE_RESPONSE_ALL" | sed '$d')

    if [ "$PROBE_HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Probe returned HTTP $PROBE_HTTP_CODE"
        echo "Response body: $PROBE_BODY"
        exit 1
    fi

    MODULE_HASH=$(echo "$PROBE_BODY" | jq -r .module_hash)
    if [ -z "$MODULE_HASH" ] || [ "$MODULE_HASH" == "null" ]; then
        echo "ERROR: Probe response missing module_hash"
        echo "Response body: $PROBE_BODY"
        exit 1
    fi

    PROBE_MODULE_NAME=$(echo "$PROBE_BODY" | jq -r .module_name)
    if [ "$PROBE_MODULE_NAME" != "$EXPECTED_MODULE_NAME" ]; then
        echo "ERROR: Probe module_name mismatch: expected '$EXPECTED_MODULE_NAME', got '$PROBE_MODULE_NAME'"
        exit 1
    fi

    echo "  Step 1 OK: Probe returned module_hash=$MODULE_HASH"

    # Step 2: Convert using the hash (no re-upload)
    CONVERT_RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"module_hash\":\"$MODULE_HASH\",\"filename\":\"$(basename "$FILE_PATH")\"}" \
        "$BASE_URL/convert-probed")
    CONVERT_HTTP_CODE=$(echo "$CONVERT_RESPONSE_ALL" | tail -n1)
    CONVERT_BODY=$(echo "$CONVERT_RESPONSE_ALL" | sed '$d')

    if [ "$CONVERT_HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Convert-probed returned HTTP $CONVERT_HTTP_CODE"
        echo "Response body: $CONVERT_BODY"
        exit 1
    fi

    PLAY_URL=$(echo "$CONVERT_BODY" | jq -r .play_url)
    DOWNLOAD_URL=$(echo "$CONVERT_BODY" | jq -r .download_url)
    CONVERT_MODULE_NAME=$(echo "$CONVERT_BODY" | jq -r .module_name)
    CONVERT_PLAYER_FORMAT=$(echo "$CONVERT_BODY" | jq -r .player_format)

    if [ -z "$PLAY_URL" ] || [ "$PLAY_URL" == "null" ]; then
        echo "ERROR: Convert-probed response missing play_url"
        echo "Response body: $CONVERT_BODY"
        exit 1
    fi

    if [ "$CONVERT_MODULE_NAME" != "$EXPECTED_MODULE_NAME" ]; then
        echo "ERROR: Convert-probed module_name mismatch: expected '$EXPECTED_MODULE_NAME', got '$CONVERT_MODULE_NAME'"
        exit 1
    fi

    if [ "$CONVERT_PLAYER_FORMAT" != "$EXPECTED_PLAYER_FORMAT" ]; then
        echo "ERROR: Convert-probed player_format mismatch: expected '$EXPECTED_PLAYER_FORMAT', got '$CONVERT_PLAYER_FORMAT'"
        exit 1
    fi

    echo "  Step 2 OK: Convert-probed returned play_url=$PLAY_URL"

    # Verify the filename in the response is the original name (not the hash-based disk name)
    CONVERT_FILENAME=$(echo "$CONVERT_BODY" | jq -r .filename)
    if echo "$CONVERT_FILENAME" | grep -q "probed_"; then
        echo "ERROR: Convert-probed filename leaked hash-based disk name: '$CONVERT_FILENAME'"
        echo "Response body: $CONVERT_BODY"
        exit 1
    fi

    echo "  Step 2 extra: Filename correctly preserved as '$CONVERT_FILENAME'"

    # Step 3: Verify play_url is accessible (may return 200 or 206 for range-capable responses)
    PLAY_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL$PLAY_URL")
    if [ "$PLAY_HTTP_CODE" -ne 200 ] && [ "$PLAY_HTTP_CODE" -ne 206 ]; then
        echo "ERROR: Play URL returned HTTP $PLAY_HTTP_CODE (expected 200 or 206)"
        exit 1
    fi

    echo "  Step 3 OK: Play URL returned HTTP $PLAY_HTTP_CODE"

    echo "SUCCESS: Full probe→convert-probed→play flow works for '$TEST_NAME'."
    echo "Probe response: $PROBE_BODY"
    echo "Convert response: $CONVERT_BODY"
    echo ""
}

# Test that probing the same content twice returns the same module_hash (dedup)
# Arguments:
# 1. File path to local module (string)
test_probe_upload_dedup() {
    echo "--- Testing Probe Upload Dedup: Same content returns same hash ---"

    RESPONSE1_ALL=$(curl -s -w "\n%{http_code}" -X POST -F "file=@$1" "$BASE_URL/probe-upload")
    HASH1=$(echo "$RESPONSE1_ALL" | sed '$d' | jq -r .module_hash)

    # Upload the same file with a different filename
    RESPONSE2_ALL=$(curl -s -w "\n%{http_code}" -X POST -F "file=@$1;filename=renamed_module.mod" "$BASE_URL/probe-upload")
    HASH2=$(echo "$RESPONSE2_ALL" | sed '$d' | jq -r .module_hash)

    if [ "$HASH1" != "$HASH2" ]; then
        echo "ERROR: Same file content produced different hashes: '$HASH1' vs '$HASH2'"
        exit 1
    fi

    echo "SUCCESS: Same content returns identical module_hash ($HASH1) regardless of filename."
    echo ""
}

# Test that concurrent probes of the same content all succeed and return the same hash
# Arguments:
# 1. File path to local module (string)
test_probe_upload_dedup_concurrent() {
    echo "--- Testing Probe Upload Dedup: Concurrent same-content probes ---"

    TMP_RESP_DIR=$(mktemp -d)

    for INDEX in 1 2 3 4; do
        (
            curl -s -w "\n%{http_code}" -X POST \
                -F "file=@$1;filename=concurrent_$INDEX.mod" \
                "$BASE_URL/probe-upload" > "$TMP_RESP_DIR/resp_$INDEX.txt"
        ) &
    done
    wait

    EXPECTED_HASH=""

    for RESPONSE_FILE in "$TMP_RESP_DIR"/resp_*.txt; do
        HTTP_CODE=$(tail -n1 "$RESPONSE_FILE")
        BODY=$(sed '$d' "$RESPONSE_FILE")

        if [ "$HTTP_CODE" -ne 200 ]; then
            echo "ERROR: Concurrent probe returned HTTP $HTTP_CODE"
            echo "Response body: $BODY"
            rm -rf "$TMP_RESP_DIR"
            exit 1
        fi

        HASH=$(echo "$BODY" | jq -r .module_hash)
        if [ -z "$HASH" ] || [ "$HASH" == "null" ]; then
            echo "ERROR: Concurrent probe response missing module_hash"
            echo "Response body: $BODY"
            rm -rf "$TMP_RESP_DIR"
            exit 1
        fi

        if [ -z "$EXPECTED_HASH" ]; then
            EXPECTED_HASH="$HASH"
        elif [ "$HASH" != "$EXPECTED_HASH" ]; then
            echo "ERROR: Concurrent probe returned mismatched hashes: '$EXPECTED_HASH' vs '$HASH'"
            rm -rf "$TMP_RESP_DIR"
            exit 1
        fi
    done

    rm -rf "$TMP_RESP_DIR"
    echo "SUCCESS: Concurrent same-content probes all succeeded with module_hash=$EXPECTED_HASH."
    echo ""
}

# Test that convert-probed can reconvert after cached audio is removed
# Arguments:
# 1. File path to local module (string)
test_convert_probed_reconverts_after_cache_removal() {
    echo "--- Testing Convert-Probed Recovery After Cached Audio Removal ---"

    PROBE_RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST -F "file=@$1" "$BASE_URL/probe-upload")
    PROBE_HTTP_CODE=$(echo "$PROBE_RESPONSE_ALL" | tail -n1)
    PROBE_BODY=$(echo "$PROBE_RESPONSE_ALL" | sed '$d')

    if [ "$PROBE_HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Probe returned HTTP $PROBE_HTTP_CODE"
        echo "Response body: $PROBE_BODY"
        exit 1
    fi

    MODULE_HASH=$(echo "$PROBE_BODY" | jq -r .module_hash)
    if [ -z "$MODULE_HASH" ] || [ "$MODULE_HASH" == "null" ]; then
        echo "ERROR: Probe response missing module_hash"
        echo "Response body: $PROBE_BODY"
        exit 1
    fi

    FIRST_CONVERT_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"module_hash\":\"$MODULE_HASH\",\"filename\":\"$(basename "$1")\"}" \
        "$BASE_URL/convert-probed")
    FIRST_CONVERT_HTTP_CODE=$(echo "$FIRST_CONVERT_ALL" | tail -n1)
    FIRST_CONVERT_BODY=$(echo "$FIRST_CONVERT_ALL" | sed '$d')

    if [ "$FIRST_CONVERT_HTTP_CODE" -ne 200 ]; then
        echo "ERROR: First convert-probed returned HTTP $FIRST_CONVERT_HTTP_CODE"
        echo "Response body: $FIRST_CONVERT_BODY"
        exit 1
    fi

    FILE_ID=$(echo "$FIRST_CONVERT_BODY" | jq -r .file_id)
    AUDIO_FORMAT=$(echo "$FIRST_CONVERT_BODY" | jq -r .audio_format)
    if [ -z "$FILE_ID" ] || [ "$FILE_ID" == "null" ] || [ -z "$AUDIO_FORMAT" ] || [ "$AUDIO_FORMAT" == "null" ]; then
        echo "ERROR: First convert-probed response missing file_id or audio_format"
        echo "Response body: $FIRST_CONVERT_BODY"
        exit 1
    fi

    _remove_cache_artifact "$FILE_ID" ".$AUDIO_FORMAT" > /dev/null

    SECOND_CONVERT_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"module_hash\":\"$MODULE_HASH\",\"filename\":\"$(basename "$1")\"}" \
        "$BASE_URL/convert-probed")
    SECOND_CONVERT_HTTP_CODE=$(echo "$SECOND_CONVERT_ALL" | tail -n1)
    SECOND_CONVERT_BODY=$(echo "$SECOND_CONVERT_ALL" | sed '$d')

    if [ "$SECOND_CONVERT_HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Second convert-probed returned HTTP $SECOND_CONVERT_HTTP_CODE after cache removal"
        echo "Response body: $SECOND_CONVERT_BODY"
        exit 1
    fi

    SECOND_PLAY_URL=$(echo "$SECOND_CONVERT_BODY" | jq -r .play_url)
    if [ -z "$SECOND_PLAY_URL" ] || [ "$SECOND_PLAY_URL" == "null" ]; then
        echo "ERROR: Second convert-probed response missing play_url"
        echo "Response body: $SECOND_CONVERT_BODY"
        exit 1
    fi

    echo "SUCCESS: convert-probed reconverted successfully after cached audio removal."
    echo ""
}

# Test that when convert-probed misses because the probed source file is gone,
# the same file can still be uploaded and converted successfully. This proves
# the server supports the frontend's documented 404 -> /upload fallback path.
# Arguments:
# 1. File path to local module (string)
test_convert_probed_404_then_upload_fallback() {
    echo "--- Testing Convert-Probed 404 Then Upload Fallback ---"

    PROBE_RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST -F "file=@$1" "$BASE_URL/probe-upload")
    PROBE_HTTP_CODE=$(echo "$PROBE_RESPONSE_ALL" | tail -n1)
    PROBE_BODY=$(echo "$PROBE_RESPONSE_ALL" | sed '$d')

    if [ "$PROBE_HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Probe returned HTTP $PROBE_HTTP_CODE"
        echo "Response body: $PROBE_BODY"
        exit 1
    fi

    MODULE_HASH=$(echo "$PROBE_BODY" | jq -r .module_hash)
    if [ -z "$MODULE_HASH" ] || [ "$MODULE_HASH" == "null" ]; then
        echo "ERROR: Probe response missing module_hash"
        echo "Response body: $PROBE_BODY"
        exit 1
    fi

    REMOVE_PROBED_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"module_hash\":\"$MODULE_HASH\"}" \
        "$BASE_URL/test/remove-probed-module")
    REMOVE_PROBED_HTTP_CODE=$(echo "$REMOVE_PROBED_ALL" | tail -n1)
    REMOVE_PROBED_BODY=$(echo "$REMOVE_PROBED_ALL" | sed '$d')

    if [ "$REMOVE_PROBED_HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Failed to remove probed module for hash $MODULE_HASH"
        echo "Response body: $REMOVE_PROBED_BODY"
        exit 1
    fi

    CONVERT_PROBED_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"module_hash\":\"$MODULE_HASH\",\"filename\":\"$(basename "$1")\"}" \
        "$BASE_URL/convert-probed")
    CONVERT_PROBED_HTTP_CODE=$(echo "$CONVERT_PROBED_ALL" | tail -n1)
    CONVERT_PROBED_BODY=$(echo "$CONVERT_PROBED_ALL" | sed '$d')

    if [ "$CONVERT_PROBED_HTTP_CODE" -ne 404 ]; then
        echo "ERROR: Expected convert-probed to return HTTP 404 after probed-module removal, got $CONVERT_PROBED_HTTP_CODE"
        echo "Response body: $CONVERT_PROBED_BODY"
        exit 1
    fi

    if ! echo "$CONVERT_PROBED_BODY" | grep -q "Module not found"; then
        echo "ERROR: Unexpected convert-probed 404 body after probed-module removal"
        echo "Response body: $CONVERT_PROBED_BODY"
        exit 1
    fi

    UPLOAD_RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST -F "file=@$1" "$BASE_URL/upload")
    UPLOAD_HTTP_CODE=$(echo "$UPLOAD_RESPONSE_ALL" | tail -n1)
    UPLOAD_BODY=$(echo "$UPLOAD_RESPONSE_ALL" | sed '$d')

    if [ "$UPLOAD_HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Upload fallback returned HTTP $UPLOAD_HTTP_CODE"
        echo "Response body: $UPLOAD_BODY"
        exit 1
    fi

    FALLBACK_FILE_ID=$(echo "$UPLOAD_BODY" | jq -r .file_id)
    FALLBACK_PLAY_URL=$(echo "$UPLOAD_BODY" | jq -r .play_url)
    if [ -z "$FALLBACK_FILE_ID" ] || [ "$FALLBACK_FILE_ID" == "null" ] || [ -z "$FALLBACK_PLAY_URL" ] || [ "$FALLBACK_PLAY_URL" == "null" ]; then
        echo "ERROR: Upload fallback response missing file_id or play_url"
        echo "Response body: $UPLOAD_BODY"
        exit 1
    fi

    PLAY_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL$FALLBACK_PLAY_URL")
    if [ "$PLAY_HTTP_CODE" -ne 200 ] && [ "$PLAY_HTTP_CODE" -ne 206 ]; then
        echo "ERROR: Upload fallback play URL returned HTTP $PLAY_HTTP_CODE"
        exit 1
    fi

    echo "SUCCESS: convert-probed 404 was followed by successful upload fallback and playable audio."
    echo ""
}

# Test convert-probed error: invalid hash format
test_convert_probed_invalid_hash() {
    echo "--- Testing Convert-Probed Error: Invalid hash format ---"

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d '{"module_hash":"not-a-valid-hash","filename":"test.mod"}' \
        "$BASE_URL/convert-probed")
    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 400 ]; then
        echo "ERROR: Convert-probed with invalid hash returned HTTP $HTTP_CODE (expected 400)"
        echo "Response body: $BODY"
        exit 1
    fi

    if ! echo "$BODY" | grep -q "Invalid module hash"; then
        echo "ERROR: Unexpected error message for invalid hash"
        echo "Response body: $BODY"
        exit 1
    fi

    echo "SUCCESS: Convert-probed correctly rejected invalid hash."
    echo "Response body: $BODY"
    echo ""
}

# Test convert-probed error: non-existent hash (404)
test_convert_probed_not_found() {
    echo "--- Testing Convert-Probed Error: Non-existent hash ---"

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d '{"module_hash":"00000000000000000000000000000000","filename":"test.mod"}' \
        "$BASE_URL/convert-probed")
    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 404 ]; then
        echo "ERROR: Convert-probed with unknown hash returned HTTP $HTTP_CODE (expected 404)"
        echo "Response body: $BODY"
        exit 1
    fi

    if ! echo "$BODY" | grep -q "Module not found"; then
        echo "ERROR: Unexpected error message for unknown hash"
        echo "Response body: $BODY"
        exit 1
    fi

    echo "SUCCESS: Convert-probed correctly returned 404 for unknown hash."
    echo "Response body: $BODY"
    echo ""
}

# Test convert-probed error: missing/invalid request body
test_convert_probed_bad_request() {
    echo "--- Testing Convert-Probed Error: Missing request body ---"

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        "$BASE_URL/convert-probed")
    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 400 ]; then
        echo "ERROR: Convert-probed with no body returned HTTP $HTTP_CODE (expected 400)"
        echo "Response body: $BODY"
        exit 1
    fi

    echo "SUCCESS: Convert-probed correctly rejected empty request body."
    echo "Response body: $BODY"
    echo ""
}

test_convert_probed_non_string_filename() {
    echo "--- Testing Convert-Probed Handles Non-String Filename ---"

    PROBE_RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST -F "file=@fixtures/modules/space_debris.mod" "$BASE_URL/probe-upload")
    PROBE_HTTP_CODE=$(echo "$PROBE_RESPONSE_ALL" | tail -n1)
    PROBE_BODY=$(echo "$PROBE_RESPONSE_ALL" | sed '$d')

    if [ "$PROBE_HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Probe returned HTTP $PROBE_HTTP_CODE"
        echo "Response body: $PROBE_BODY"
        exit 1
    fi

    MODULE_HASH=$(echo "$PROBE_BODY" | jq -r .module_hash)
    if [ -z "$MODULE_HASH" ] || [ "$MODULE_HASH" == "null" ]; then
        echo "ERROR: Probe response missing module_hash"
        echo "Response body: $PROBE_BODY"
        exit 1
    fi

    CONVERT_RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"module_hash\":\"$MODULE_HASH\",\"filename\":{\"nested\":\"value\"}}" \
        "$BASE_URL/convert-probed")
    CONVERT_HTTP_CODE=$(echo "$CONVERT_RESPONSE_ALL" | tail -n1)
    CONVERT_BODY=$(echo "$CONVERT_RESPONSE_ALL" | sed '$d')

    if [ "$CONVERT_HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Convert-probed with non-string filename returned HTTP $CONVERT_HTTP_CODE"
        echo "Response body: $CONVERT_BODY"
        exit 1
    fi

    CONVERT_FILENAME=$(echo "$CONVERT_BODY" | jq -r .filename)
    PLAY_URL=$(echo "$CONVERT_BODY" | jq -r .play_url)

    if [ "$CONVERT_FILENAME" != "module" ]; then
        echo "ERROR: Convert-probed did not normalize non-string filename to 'module'"
        echo "Response body: $CONVERT_BODY"
        exit 1
    fi

    if [ -z "$PLAY_URL" ] || [ "$PLAY_URL" == "null" ]; then
        echo "ERROR: Convert-probed response missing play_url for non-string filename"
        echo "Response body: $CONVERT_BODY"
        exit 1
    fi

    echo "SUCCESS: Convert-probed normalized a non-string filename payload to '$CONVERT_FILENAME'."
    echo "Response body: $CONVERT_BODY"
    echo ""
}

# Test convert-probed error: wrong HTTP method (GET)
test_convert_probed_wrong_method() {
    echo "--- Testing Convert-Probed Error: Wrong HTTP method (GET) ---"

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" "$BASE_URL/convert-probed")
    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)

    if [ "$HTTP_CODE" -ne 405 ]; then
        echo "ERROR: GET /convert-probed returned HTTP $HTTP_CODE (expected 405)"
        exit 1
    fi

    echo "SUCCESS: Convert-probed correctly rejected GET request with 405."
    echo ""
}

test_convert_url_error() {
    TEST_NAME=$1
    URL=$2
    SAMPLE_URL=$3
    EXPECTED_STATUS=$4
    EXPECTED_ERROR_SUBSTRING=$5

    echo "--- Testing Convert URL Error: $TEST_NAME ---"

    HTTP_CODE_BODY=$(_perform_convert_url_call "$URL" "$SAMPLE_URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)

    if [ "$HTTP_CODE" -ne "$EXPECTED_STATUS" ]; then
        echo "ERROR: Convert URL returned HTTP $HTTP_CODE (expected $EXPECTED_STATUS) for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    if [ -n "$EXPECTED_ERROR_SUBSTRING" ] && ! echo "$BODY" | grep -q "$EXPECTED_ERROR_SUBSTRING"; then
        echo "ERROR: Convert URL error message mismatch for '$TEST_NAME'"
        echo "Expected substring: '$EXPECTED_ERROR_SUBSTRING'"
        echo "Response body: $BODY"
        exit 1
    fi

    echo "SUCCESS: Convert URL returned expected error."
    echo "Response body: $BODY"
    echo ""
}

test_probe_oversized_remote_file() {
    TEST_NAME=$1
    URL_BASE=$2
    UNIQUE_ID=$(date +%s%N)
    URL="${URL_BASE}?oversize_probe_id=${UNIQUE_ID}"

    echo "--- Testing Probe Error: $TEST_NAME ---"

    HTTP_CODE_BODY=$(_perform_probe_url_call "$URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)

    if [ "$HTTP_CODE" -ne 413 ]; then
        echo "ERROR: Probe returned HTTP $HTTP_CODE (expected 413) for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    if ! echo "$BODY" | grep -q "External module file size exceeds the maximum allowed limit of 10MB"; then
        echo "ERROR: Probe oversized-file error message mismatch for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    echo "SUCCESS: Probe returned expected oversized-file error."
    echo "Response body: $BODY"
    echo ""
}

test_probe_has_no_conversion_fields() {
    TEST_NAME=$1
    URL=$2
    SAMPLE_URL=$3

    echo "--- Testing Probe Response Shape: $TEST_NAME ---"

    HTTP_CODE_BODY=$(_perform_probe_url_call "$URL" "$SAMPLE_URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Probe returned HTTP $HTTP_CODE for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    for field in file_id play_url download_url audio_format; do
        if echo "$BODY" | jq -e "has(\"$field\")" > /dev/null; then
            echo "ERROR: Probe response unexpectedly contains '$field' for '$TEST_NAME'"
            echo "Response body: $BODY"
            exit 1
        fi
    done

    echo "SUCCESS: Probe response does not include conversion-only fields."
    echo "Response body: $BODY"
    echo ""
}

test_probe_missing_url() {
    echo "--- Testing Probe Error: missing URL ---"

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d '{}' \
        "$BASE_URL/probe-url")

    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 400 ]; then
        echo "ERROR: Probe returned HTTP $HTTP_CODE (expected 400) for missing URL"
        echo "Response body: $BODY"
        exit 1
    fi

    if ! echo "$BODY" | grep -q "No URL provided"; then
        echo "ERROR: Probe missing URL returned unexpected error message"
        echo "Response body: $BODY"
        exit 1
    fi

    echo "SUCCESS: Probe rejected missing URL payload."
    echo "Response body: $BODY"
    echo ""
}

test_probe_malformed_json() {
    echo "--- Testing Probe Error: malformed JSON ---"

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d '{"url":' \
        "$BASE_URL/probe-url")

    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 400 ]; then
        echo "ERROR: Probe returned HTTP $HTTP_CODE (expected 400) for malformed JSON"
        echo "Response body: $BODY"
        exit 1
    fi

    if ! echo "$BODY" | grep -q "Invalid JSON body"; then
        echo "ERROR: Probe malformed JSON returned unexpected error message"
        echo "Response body: $BODY"
        exit 1
    fi

    echo "SUCCESS: Probe rejected malformed JSON payload."
    echo "Response body: $BODY"
    echo ""
}

_assert_convert_url_invalid_json_request() {
    TEST_NAME=$1
    CONTENT_TYPE=$2
    REQUEST_BODY=$3

    echo "--- Testing Convert URL Error: $TEST_NAME ---"

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: $CONTENT_TYPE" \
        -d "$REQUEST_BODY" \
        "$BASE_URL/convert-url")

    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 400 ]; then
        echo "ERROR: Convert URL returned HTTP $HTTP_CODE (expected 400) for $TEST_NAME"
        echo "Response body: $BODY"
        exit 1
    fi

    if ! echo "$BODY" | grep -q "Invalid JSON body"; then
        echo "ERROR: Convert URL $TEST_NAME returned unexpected error message"
        echo "Response body: $BODY"
        exit 1
    fi

    echo "SUCCESS: Convert URL rejected invalid request payload."
    echo "Response body: $BODY"
    echo ""
}

test_convert_url_malformed_json() {
    _assert_convert_url_invalid_json_request "malformed JSON" "application/json" '{"url":'
}

test_convert_url_wrong_content_type() {
    _assert_convert_url_invalid_json_request "wrong content type" "text/plain" 'not json'
}

# Function to test rejecting malformed range requests
# Arguments:
# 1. Test name (string)
# 2. URL to convert (string)
# 3. Optional sample URL (string)
test_security_malformed_range() {
    TEST_NAME=$1
    URL=$2
    SAMPLE_URL=$3

    echo "--- Testing Range Request: $TEST_NAME ---"

    # First, convert a module to get a file_id
    HTTP_CODE_BODY=$(_perform_convert_url_call "$URL" "$SAMPLE_URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    RESPONSE=$(echo "$HTTP_CODE_BODY" | tail -n1)

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Initial convert-url call failed with HTTP $HTTP_CODE for malformed range test"
        echo "Response body: $RESPONSE"
        exit 1
    fi

    FILE_ID=$(echo "$RESPONSE" | jq -r .file_id)

    if [ -z "$FILE_ID" ] || [ "$FILE_ID" == "null" ]; then
        echo "ERROR: file_id not found in response for malformed range test"
        echo "Response body: $RESPONSE"
        exit 1
    fi

    # Now, test rejecting malformed range
    MALFORMED_RANGE_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -H "Range: bytes=invalid-range" "$BASE_URL/play/$FILE_ID")
    MALFORMED_RANGE_HTTP_CODE=$(echo "$MALFORMED_RANGE_RESPONSE" | tail -n1)

    if [ "$MALFORMED_RANGE_HTTP_CODE" -eq 416 ]; then
        echo "SUCCESS: Malformed range request returned HTTP 416 as expected."
    else
        echo "ERROR: Malformed range request returned unexpected HTTP $MALFORMED_RANGE_HTTP_CODE (expected 416)."
        exit 1
    fi
    echo ""
}

# Function to test URL download caching logic
# Arguments:
# 1. Test name (string)
# 2. Base URL to convert (string)
test_url_cache_logic() {
    TEST_NAME=$1
    BASE_URL_TO_TEST=$2

    echo "--- Testing URL Cache Logic: $TEST_NAME ---"

    # Generate a unique URL for this test run
    UNIQUE_ID=$(date +%s%N)
    UNIQUE_URL="${BASE_URL_TO_TEST}?cache_probe_id=${UNIQUE_ID}"
    echo "Using unique URL: $UNIQUE_URL"

    # 1. First call (should be a URL cache miss)
    echo "Making first request (expecting url_cached: false)..."
    HTTP_CODE_BODY_1=$(_perform_convert_url_call "$UNIQUE_URL")
    HTTP_CODE_1=$(echo "$HTTP_CODE_BODY_1" | head -n1)
    RESPONSE_1=$(echo "$HTTP_CODE_BODY_1" | tail -n1)

    if [ "$HTTP_CODE_1" -ne 200 ]; then
        echo "ERROR: First request failed with HTTP $HTTP_CODE_1"
        exit 1
    fi

    URL_CACHED_1=$(echo "$RESPONSE_1" | jq -r .url_cached)
    if [ "$URL_CACHED_1" == "false" ]; then
        echo "SUCCESS: First request correctly reported url_cached: false."
    else
        echo "ERROR: First request reported url_cached: $URL_CACHED_1, expected false."
        echo "Response: $RESPONSE_1"
        exit 1
    fi

    # 2. Second call (should be a URL cache hit)
    echo "Making second request (expecting url_cached: true)..."
    HTTP_CODE_BODY_2=$(_perform_convert_url_call "$UNIQUE_URL")
    HTTP_CODE_2=$(echo "$HTTP_CODE_BODY_2" | head -n1)
    RESPONSE_2=$(echo "$HTTP_CODE_BODY_2" | tail -n1)

    if [ "$HTTP_CODE_2" -ne 200 ]; then
        echo "ERROR: Second request failed with HTTP $HTTP_CODE_2"
        exit 1
    fi

    URL_CACHED_2=$(echo "$RESPONSE_2" | jq -r .url_cached)
    if [ "$URL_CACHED_2" == "true" ]; then
        echo "SUCCESS: Second request correctly reported url_cached: true."
    else
        echo "ERROR: Second request reported url_cached: $URL_CACHED_2, expected true."
        echo "Response: $RESPONSE_2"
        exit 1
    fi

    echo ""
}

test_url_cache_normalizes_cache_busters() {
    TEST_NAME=$1
    BASE_URL_TO_TEST=$2

    echo "--- Testing URL Cache Normalization: $TEST_NAME ---"

    SCENARIO_ID="$(date +%s%N)"
    CACHE_BUSTER_A="${SCENARIO_ID}"
    CACHE_BUSTER_B="$((SCENARIO_ID + 1))"
    URL_A="${BASE_URL_TO_TEST}?scenario_id=${SCENARIO_ID}&test_id=${CACHE_BUSTER_A}"
    URL_B="${BASE_URL_TO_TEST}?scenario_id=${SCENARIO_ID}&test_id=${CACHE_BUSTER_B}"

    echo "Making first request with cache-buster A (expecting url_cached: false)..."
    HTTP_CODE_BODY_1=$(_perform_convert_url_call "$URL_A")
    HTTP_CODE_1=$(echo "$HTTP_CODE_BODY_1" | head -n1)
    RESPONSE_1=$(echo "$HTTP_CODE_BODY_1" | tail -n1)

    if [ "$HTTP_CODE_1" -ne 200 ]; then
        echo "ERROR: First normalized-cache request failed with HTTP $HTTP_CODE_1"
        exit 1
    fi

    URL_CACHED_1=$(echo "$RESPONSE_1" | jq -r .url_cached)
    if [ "$URL_CACHED_1" != "false" ]; then
        echo "ERROR: First normalized-cache request reported url_cached: $URL_CACHED_1, expected false."
        echo "Response: $RESPONSE_1"
        exit 1
    fi

    echo "Making second request with cache-buster B (expecting url_cached: true)..."
    HTTP_CODE_BODY_2=$(_perform_convert_url_call "$URL_B")
    HTTP_CODE_2=$(echo "$HTTP_CODE_BODY_2" | head -n1)
    RESPONSE_2=$(echo "$HTTP_CODE_BODY_2" | tail -n1)

    if [ "$HTTP_CODE_2" -ne 200 ]; then
        echo "ERROR: Second normalized-cache request failed with HTTP $HTTP_CODE_2"
        exit 1
    fi

    URL_CACHED_2=$(echo "$RESPONSE_2" | jq -r .url_cached)
    if [ "$URL_CACHED_2" != "true" ]; then
        echo "ERROR: Second normalized-cache request reported url_cached: $URL_CACHED_2, expected true."
        echo "Response: $RESPONSE_2"
        exit 1
    fi

    echo "SUCCESS: Different cache-buster IDs reused the same URL download cache entry."
    echo ""
}

test_upload_error() {
    TEST_NAME=$1
    FILE_PATH=$2
    EXPECTED_STATUS=$3

    echo "--- Testing Upload Error: $TEST_NAME ---"

    # Use a specific curl command for empty file test to ensure a file part is sent
    if [[ "$TEST_NAME" == "Reject empty file upload" ]]; then
        CURL_COMMAND="curl -s -w \"\n%{http_code}\n%{stderr}\" -X POST -F \"file=;filename=empty.bin\" \"$BASE_URL/upload\""
    else
        CURL_COMMAND="curl -s -w \"\n%{http_code}\n%{stderr}\" -X POST -F \"file=@$FILE_PATH\" \"$BASE_URL/upload\""
    fi

    CURL_OUTPUT=$(eval "$CURL_COMMAND")

    HTTP_CODE=$(echo "$CURL_OUTPUT" | awk 'END{print $(NF-1)}') # Get second to last line
    CURL_STDERR=$(echo "$CURL_OUTPUT" | tail -n1) # Get last line (stderr)
    BODY=$(echo "$CURL_OUTPUT" | head -n-2) # Get all but last two lines (body)

    if [ "$HTTP_CODE" -eq "$EXPECTED_STATUS" ]; then
        echo "SUCCESS: Received HTTP $EXPECTED_STATUS as expected."
    else
        echo "ERROR: Received unexpected HTTP $HTTP_CODE (expected $EXPECTED_STATUS) for test '$TEST_NAME'"
        echo "CURL STDERR: $CURL_STDERR"
        echo "Response body: $BODY"
        exit 1
    fi
    echo ""
}

assert_request_entity_too_large_payload() {
    BODY=$1
    TEST_NAME=$2

    if ! echo "$BODY" | jq -e '
        .code == 413
        and .max_upload_size_bytes == 10485760
        and (.max_upload_size_mb == 10 or .max_upload_size_mb == 10.0)
        and (.error | type == "string")
        and (.error | contains("maximum allowed size"))
    ' > /dev/null; then
        echo "ERROR: RequestEntityTooLarge payload shape mismatch for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi
}

test_upload_oversized_payload_shape() {
    TEST_NAME=$1
    FILE_PATH=$2

    echo "--- Testing Upload Error Payload: $TEST_NAME ---"

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST -F "file=@$FILE_PATH" "$BASE_URL/upload")
    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 413 ]; then
        echo "ERROR: Upload oversized payload test returned HTTP $HTTP_CODE (expected 413)"
        echo "Response body: $BODY"
        exit 1
    fi

    assert_request_entity_too_large_payload "$BODY" "$TEST_NAME"

    echo "SUCCESS: Upload oversized file returned the shared 413 payload shape."
    echo "Response body: $BODY"
    echo ""
}

test_external_download_flow_with_oversized_file() {
    TEST_NAME=$1
    URL_BASE=$2
    # Generate a unique URL for this test run to ensure it's a fresh download attempt
    UNIQUE_ID=$(date +%s%N)
    URL="${URL_BASE}?oversize_download_id=${UNIQUE_ID}"

    EXPECTED_STATUS_FIRST_CALL=413
    EXPECTED_ERROR_MESSAGE_FIRST_CALL="External module file size exceeds the maximum allowed limit of 10MB"

    EXPECTED_STATUS_SECOND_CALL=500
    EXPECTED_ERROR_MESSAGE_SECOND_CALL="Could not detect module metadata. The file may be corrupt or not a supported module."

    echo "--- Testing External Download Flow (Oversized File): $TEST_NAME ---"
    echo "Using URL: $URL"

    # --- First Call: Should hit size limit and return 413 ---
    echo "Making first request (expecting HTTP $EXPECTED_STATUS_FIRST_CALL)..."
    HTTP_CODE_BODY_1=$(_perform_convert_url_call "$URL")
    HTTP_CODE_1=$(echo "$HTTP_CODE_BODY_1" | head -n1)
    BODY_1=$(echo "$HTTP_CODE_BODY_1" | tail -n1)

    if [ "$HTTP_CODE_1" -eq "$EXPECTED_STATUS_FIRST_CALL" ]; then
        if echo "$BODY_1" | grep -q "$EXPECTED_ERROR_MESSAGE_FIRST_CALL"; then
            echo "SUCCESS: First request correctly returned HTTP $EXPECTED_STATUS_FIRST_CALL and expected error message."
        else
            echo "ERROR: First request returned HTTP $EXPECTED_STATUS_FIRST_CALL but unexpected error message for test '$TEST_NAME'"
            echo "Expected substring: '$EXPECTED_ERROR_MESSAGE_FIRST_CALL'"
            echo "Response body: $BODY_1"
            exit 1
        fi
    else
        echo "ERROR: First request returned unexpected HTTP $HTTP_CODE_1 (expected $EXPECTED_STATUS_FIRST_CALL) for test '$TEST_NAME'"
        echo "Response body: $BODY_1"
        exit 1
    fi

    # --- Second Call: Should hit cached partial file and return 500 (metadata error) ---
    echo "Making second request to the same URL (expecting HTTP $EXPECTED_STATUS_SECOND_CALL)..."
    HTTP_CODE_BODY_2=$(_perform_convert_url_call "$URL")
    HTTP_CODE_2=$(echo "$HTTP_CODE_BODY_2" | head -n1)
    BODY_2=$(echo "$HTTP_CODE_BODY_2" | tail -n1)

    if [ "$HTTP_CODE_2" -eq "$EXPECTED_STATUS_SECOND_CALL" ]; then
        if echo "$BODY_2" | grep -q "$EXPECTED_ERROR_MESSAGE_SECOND_CALL"; then
            echo "SUCCESS: Second request correctly returned HTTP $EXPECTED_STATUS_SECOND_CALL and expected error message."
        else
            echo "ERROR: Second request returned HTTP $EXPECTED_STATUS_SECOND_CALL but unexpected error message for test '$TEST_NAME'"
            echo "Expected substring: '$EXPECTED_ERROR_MESSAGE_SECOND_CALL'"
            echo "Response body: $BODY_2"
            exit 1
        fi
    else
        echo "ERROR: Second request returned unexpected HTTP $HTTP_CODE_2 (expected $EXPECTED_STATUS_SECOND_CALL) for test '$TEST_NAME'"
        echo "Response body: $BODY_2"
        exit 1
    fi
    echo ""
}

test_url_with_ua() {
    TEST_NAME=$1
    URL=$2
    USER_AGENT=$3
    EXPECTED_AUDIO_FORMAT=$4

    echo "--- Testing User-Agent FLAC: $TEST_NAME ---"

    # Capture HTTP_CODE and RESPONSE from _perform_convert_url_call_with_agent_header
    HTTP_CODE_BODY=$(_perform_convert_url_call_with_agent_header "$URL" "$USER_AGENT")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)

    AUDIO_FORMAT=$(echo "$BODY" | jq -r .audio_format)

    if [ "$HTTP_CODE" -eq 200 ] && [ "$AUDIO_FORMAT" == "$EXPECTED_AUDIO_FORMAT" ]; then
        echo "SUCCESS: Received HTTP 200 and audio_format is $EXPECTED_AUDIO_FORMAT"
        echo "Response body: $BODY"
    else
        echo "ERROR: Received unexpected HTTP $HTTP_CODE (expected 200) or audio_format ($AUDIO_FORMAT) is not $EXPECTED_AUDIO_FORMAT for test '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi
    echo ""
}

# Function to test range request handling for large files
# Arguments:
# 1. Test name (string)
# 2. URL to convert (string)
# 3. Optional sample URL (string)
test_range_request() {
    TEST_NAME=$1
    URL=$2
    SAMPLE_URL=$3

    echo "--- Testing Range Request: $TEST_NAME ---"

    # First, convert the URL to get a file_id
    HTTP_CODE_BODY=$(_perform_convert_url_call "$URL" "$SAMPLE_URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    RESPONSE=$(echo "$HTTP_CODE_BODY" | tail -n1)

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Initial convert-url call failed with HTTP $HTTP_CODE for test '$TEST_NAME'"
        echo "Response body: $RESPONSE"
        exit 1
    fi

    FILE_ID=$(echo "$RESPONSE" | jq -r .file_id)

    if [ -z "$FILE_ID" ] || [ "$FILE_ID" == "null" ]; then
        echo "ERROR: file_id not found in response for test '$TEST_NAME'"
        echo "Response body: $RESPONSE"
        exit 1
    fi

    # Now, try to get a byte range from the file
    RANGE_START=0
    RANGE_END=1023 # Requesting first 1KB
    EXPECTED_CONTENT_RANGE="bytes $RANGE_START-$RANGE_END/"

    RANGE_RESPONSE=$(curl -s -D - -o /dev/null -w "\n%{http_code}" -H "Range: bytes=$RANGE_START-$RANGE_END" "$BASE_URL/play/$FILE_ID")
    RANGE_HTTP_CODE=$(echo "$RANGE_RESPONSE" | tail -n1)
    HEADERS=$(echo "$RANGE_RESPONSE" | head -n -1)
    CONTENT_RANGE_HEADER=$(echo "$HEADERS" | grep -i "Content-Range" | sed -E 's/.*Content-Range: (.*)\r/\1/I')

    if [ "$RANGE_HTTP_CODE" -eq 206 ] && [[ "$CONTENT_RANGE_HEADER" == "$EXPECTED_CONTENT_RANGE"* ]]; then
        echo "SUCCESS: Range request returned HTTP 206 and correct Content-Range header."
        echo "Headers: $HEADERS"
    else
        echo "ERROR: Range request returned unexpected HTTP $RANGE_HTTP_CODE (expected 206) or incorrect Content-Range header ('$CONTENT_RANGE_HEADER') for test '$TEST_NAME'"
        echo "Headers: $HEADERS"
        exit 1
    fi
    echo ""
}

# Function to test download functionality
# Arguments:
# 1. Test name (string)
# 2. URL to convert (string)
# 3. Optional sample URL (string)
test_download_functionality() {
    # covers: /download/<file_id>
    TEST_NAME=$1
    URL=$2
    SAMPLE_URL=$3

    echo "--- Testing Download Functionality: $TEST_NAME ---"

    # First, convert the URL to get a download_url
    HTTP_CODE_BODY=$(_perform_convert_url_call "$URL" "$SAMPLE_URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    RESPONSE=$(echo "$HTTP_CODE_BODY" | tail -n1)

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Initial convert-url call failed with HTTP $HTTP_CODE for test '$TEST_NAME'"
        echo "Response body: $RESPONSE"
        exit 1
    fi

    DOWNLOAD_URL=$(echo "$RESPONSE" | jq -r .download_url)
    if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
        echo "ERROR: download_url not found in response for test '$TEST_NAME'"
        echo "Response body: $RESPONSE"
        exit 1
    fi

    # Now, try to download the file
    DOWNLOAD_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL$DOWNLOAD_URL")

    if [ "$DOWNLOAD_HTTP_CODE" -eq 200 ] || [ "$DOWNLOAD_HTTP_CODE" -eq 206 ]; then
        echo "SUCCESS: Download URL returned HTTP $DOWNLOAD_HTTP_CODE."
    else
        echo "ERROR: Download URL returned unexpected HTTP $DOWNLOAD_HTTP_CODE (expected 200 or 206) for test '$TEST_NAME'"
        exit 1
    fi
    echo ""
}

test_download_filename_sanitization() {
    TEST_NAME=$1
    URL=$2
    SAMPLE_URL=$3
    MALICIOUS_FILENAME=$4
    EXPECTED_FILENAME_FRAGMENT=$5

    echo "--- Testing Download Filename Sanitization: $TEST_NAME ---"

    HTTP_CODE_BODY=$(_perform_convert_url_call "$URL" "$SAMPLE_URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    RESPONSE=$(echo "$HTTP_CODE_BODY" | tail -n1)

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Initial convert-url call failed with HTTP $HTTP_CODE for test '$TEST_NAME'"
        echo "Response body: $RESPONSE"
        exit 1
    fi

    DOWNLOAD_URL=$(echo "$RESPONSE" | jq -r .download_url)
    if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
        echo "ERROR: download_url not found in response for test '$TEST_NAME'"
        echo "Response body: $RESPONSE"
        exit 1
    fi

    DOWNLOAD_URL_PREFIX=${DOWNLOAD_URL%%filename=*}
    DOWNLOAD_URL_FILENAME_AND_SUFFIX=${DOWNLOAD_URL#*filename=}
    DOWNLOAD_URL_SUFFIX=""
    case "$DOWNLOAD_URL_FILENAME_AND_SUFFIX" in
        *"&"*) DOWNLOAD_URL_SUFFIX="&${DOWNLOAD_URL_FILENAME_AND_SUFFIX#*&}" ;;
    esac
    DOWNLOAD_URL_WITH_HOSTILE_FILENAME="${DOWNLOAD_URL_PREFIX}filename=${MALICIOUS_FILENAME}${DOWNLOAD_URL_SUFFIX}"

    RESPONSE_HEADERS=$(curl -s -D - -o /dev/null \
        "$BASE_URL$DOWNLOAD_URL_WITH_HOSTILE_FILENAME")

    if ! echo "$RESPONSE_HEADERS" | grep -qi "Content-Disposition: attachment; filename="; then
        echo "ERROR: Missing Content-Disposition header for test '$TEST_NAME'"
        echo "$RESPONSE_HEADERS"
        exit 1
    fi

    if echo "$RESPONSE_HEADERS" | grep -q "<img"; then
        echo "ERROR: Unsanitized HTML payload found in Content-Disposition header"
        echo "$RESPONSE_HEADERS"
        exit 1
    fi

    if ! echo "$RESPONSE_HEADERS" | grep -q "$EXPECTED_FILENAME_FRAGMENT"; then
        echo "ERROR: Sanitized filename fragment not found for test '$TEST_NAME'"
        echo "Expected fragment: $EXPECTED_FILENAME_FRAGMENT"
        echo "$RESPONSE_HEADERS"
        exit 1
    fi

    echo "SUCCESS: Download filename is sanitized in Content-Disposition."
    echo ""
}

# Function to test server-side cache hits for /convert-url
# Arguments:
# 1. Test name (string)
# 2. URL to convert (string)
# 3. Optional sample URL (string)
test_cache_hit_url() {
    TEST_NAME=$1
    URL=$2
    SAMPLE_URL=$3

    echo "--- Testing Cache Hit: $TEST_NAME ---"

    HTTP_CODE_BODY=$(_perform_convert_url_call "$URL" "$SAMPLE_URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    RESPONSE1=$(echo "$HTTP_CODE_BODY" | tail -n1)

    # First call (should convert and cache)
    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: First request convert-url call failed with HTTP $HTTP_CODE for test '$TEST_NAME'"
        echo "Response body: $RESPONSE1"
        exit 1
    fi
    echo "SUCCESS: First request completed."

    # Second call (should hit cache)
    HTTP_CODE_BODY=$(_perform_convert_url_call "$URL" "$SAMPLE_URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    RESPONSE2=$(echo "$HTTP_CODE_BODY" | tail -n1)

    CACHED_STATUS=$(echo "$RESPONSE2" | jq -r .cached)

    if [ "$CACHED_STATUS" == "true" ]; then
        echo "SUCCESS: Second request indicated cache hit."
        echo "Response body: $RESPONSE2"
    else
        echo "ERROR: Second request did NOT indicate cache hit for test '$TEST_NAME'"
        echo "Response body: $RESPONSE2"
        exit 1
    fi
    echo ""
}

# Arguments:
# 1. URL to test (string)
test_xss_filename() {
    XSS_URL=$1
    echo "--- Testing Security: XSS in filename/module name: $XSS_URL ---"
    HTTP_CODE_BODY=$(_perform_convert_url_call "$XSS_URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)
    if [ "$HTTP_CODE" -eq 200 ]; then
        if echo "$BODY" | grep -q '<script>'; then
            echo "ERROR: XSS payload found in response body!"
            exit 1
        else
            echo "SUCCESS: XSS payload not reflected in response."
        fi
    else
        echo "SUCCESS: Received HTTP $HTTP_CODE (expected for invalid file)"
    fi
    echo ""
}

# Function to test metadata extraction
# Arguments:
# 1. Test name (string)
# 2. URL to test (string)
# 3. Optional sample URL (string)
# 4. Expected module name (string)
# 5. Expected module format (string)
# 6. Expected player format (string)
# 7. Expected subsongs (integer)
test_metadata_extraction() {
    TEST_NAME=$1
    URL=$2
    SAMPLE_URL=$3
    EXPECTED_MODULE_NAME=$4
    EXPECTED_MODULE_FORMAT=$5
    EXPECTED_PLAYER_FORMAT=$6
    EXPECTED_SUBSONGS=$7

    echo "--- Testing Metadata Extraction: $TEST_NAME ---"

    HTTP_CODE_BODY=$(_perform_convert_url_call "$URL" "$SAMPLE_URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Received HTTP $HTTP_CODE for test '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    MODULE_NAME=$(echo "$BODY" | jq -r .module_name)
    MODULE_FORMAT=$(echo "$BODY" | jq -r .module_format)
    PLAYER_FORMAT=$(echo "$BODY" | jq -r .player_format)
    SUBSONGS=$(echo "$BODY" | jq -r .subsongs)

    if [[ "$MODULE_NAME" == "$EXPECTED_MODULE_NAME" && \
          "$MODULE_FORMAT" == "$EXPECTED_MODULE_FORMAT" && \
          "$PLAYER_FORMAT" == "$EXPECTED_PLAYER_FORMAT" && \
          "$SUBSONGS" -eq "$EXPECTED_SUBSONGS" ]]; then
        echo "SUCCESS: Metadata matches expected values for '$TEST_NAME'"
        echo "Response body: $BODY"
    else
        echo "ERROR: Metadata mismatch for test '$TEST_NAME'"
        echo "Expected module_name: '$EXPECTED_MODULE_NAME', Got: '$MODULE_NAME'"
        echo "Expected module_format: '$EXPECTED_MODULE_FORMAT', Got: '$MODULE_FORMAT'"
        echo "Expected player_format: '$EXPECTED_PLAYER_FORMAT', Got: '$PLAYER_FORMAT'"
        echo "Expected subsongs: '$EXPECTED_SUBSONGS', Got: '$SUBSONGS'"
        echo "Response body: $BODY"
        exit 1
    fi
    echo ""
}

# Function to test subsong durations
# Arguments:
# 1. Test name (string)
# 2. URL to test (string)
# 3. Optional sample URL (string)
# 4. Expected subsongs count (integer)
test_subsong_durations() {
    TEST_NAME=$1
    URL=$2
    SAMPLE_URL=$3
    EXPECTED_SUBSONGS=$4

    echo "--- Testing Subsong Durations: $TEST_NAME ---"

    HTTP_CODE_BODY=$(_perform_convert_url_call "$URL" "$SAMPLE_URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Received HTTP $HTTP_CODE for test '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    SUBSONGS=$(echo "$BODY" | jq -r .subsongs)
    DURATION_LIST=$(echo "$BODY" | jq -r .subsong_durations)

    # Verify subsongs count matches expected
    if [ "$SUBSONGS" -ne "$EXPECTED_SUBSONGS" ]; then
        echo "ERROR: Subsong count mismatch for test '$TEST_NAME'"
        echo "Expected subsongs: '$EXPECTED_SUBSONGS', Got: '$SUBSONGS'"
        echo "Response body: $BODY"
        exit 1
    fi

    # For multi-subsong modules, verify duration list exists and has correct length
    if [ "$EXPECTED_SUBSONGS" -gt 1 ]; then
        if [ "$DURATION_LIST" == "null" ] || [ -z "$DURATION_LIST" ]; then
            echo "ERROR: Missing subsong_durations for multi-subsong module in test '$TEST_NAME'"
            echo "Response body: $BODY"
            exit 1
        fi

        DURATION_COUNT=$(echo "$BODY" | jq -r '.subsong_durations | length')
        if [ "$DURATION_COUNT" -ne "$EXPECTED_SUBSONGS" ]; then
            echo "ERROR: Duration list length mismatch for test '$TEST_NAME'"
            echo "Expected $EXPECTED_SUBSONGS durations, got $DURATION_COUNT"
            echo "Response body: $BODY"
            exit 1
        fi

        # Verify all durations are non-negative numbers
        HAS_INVALID=$(echo "$BODY" | jq -r '.subsong_durations[] | select(. < 0)' | wc -l)
        if [ "$HAS_INVALID" -gt 0 ]; then
            echo "ERROR: Found negative duration values for test '$TEST_NAME'"
            echo "Response body: $BODY"
            exit 1
        fi

        echo "SUCCESS: Subsong durations validated for multi-subsong module '$TEST_NAME'"
        echo "Durations: $(echo "$BODY" | jq -r .subsong_durations)"
    else
        # For single-subsong modules, duration list should be empty or not present
        if [ "$DURATION_LIST" != "null" ] && [ "$DURATION_LIST" != "[]" ]; then
            echo "WARNING: Single-subsong module has non-empty duration list for test '$TEST_NAME'"
            echo "Duration list: $DURATION_LIST"
        fi
        echo "SUCCESS: Single-subsong module validated for '$TEST_NAME'"
    fi

    echo "Response body: $BODY"
    echo ""
}

# Function to test filename extraction
# Arguments:
# 1. Test name (string)
# 2. URL to test (string)
# 3. Expected filename (string)
test_filename_extraction() {
    TEST_NAME=$1
    URL=$2
    EXPECTED_FILENAME=$3

    if should_skip_modarchive_tests && [[ "$URL" == *"modarchive.org"* ]]; then
        skip_test "Filename Extraction: $TEST_NAME (SKIP_MODARCHIVE_TESTS=1)"
        return
    fi

    echo "--- Testing Filename Extraction: $TEST_NAME ---"

    HTTP_CODE_BODY=$(_perform_convert_url_call "$URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)

    if [ "$HTTP_CODE" -ne 200 ]; then
        # Allow 500 for the negative test case as it's not a real module
        if [[ "$URL" == *"nonexistent"* && "$HTTP_CODE" -eq 500 ]]; then
            echo "SUCCESS: Received HTTP 500 as expected for nonexistent file"
        else
            echo "ERROR: Received HTTP $HTTP_CODE for test '$TEST_NAME'"
            echo "Response body: $BODY"
            exit 1
        fi
    fi

    FILENAME=$(echo "$BODY" | jq -r .filename)

    if [[ "$FILENAME" == "$EXPECTED_FILENAME" ]]; then
        echo "SUCCESS: Filename extraction matches expected value for '$TEST_NAME'"
        echo "Response body: $BODY"
    else
        echo "ERROR: Filename mismatch for test '$TEST_NAME'"
        echo "Expected filename: '$EXPECTED_FILENAME', Got: '$FILENAME'"
        echo "Response body: $BODY"
        exit 1
    fi
    echo ""
}

# Function to test a successful file upload and conversion
# Arguments:
# 1. Test name (string)
# 2. File path to local module (string)
test_upload_conversion() {
    TEST_NAME=$1
    FILE_PATH=$2

    echo "--- Testing Upload Conversion: $TEST_NAME ---"

    # Upload the local module and capture the HTTP code and body
    UPLOAD_RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST -F "file=@$FILE_PATH" "$BASE_URL/upload")
    UPLOAD_HTTP_CODE=$(echo "$UPLOAD_RESPONSE_ALL" | tail -n1)
    UPLOAD_BODY=$(echo "$UPLOAD_RESPONSE_ALL" | sed '$d')

    if [ "$UPLOAD_HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Received HTTP $UPLOAD_HTTP_CODE for test '$TEST_NAME'"
        echo "Response body: $UPLOAD_BODY"
        exit 1
    else
        echo "SUCCESS: Upload and conversion was successful for '$TEST_NAME'"
        echo "Response body: $UPLOAD_BODY"
    fi
    echo ""
}

# Function to test metadata extraction from an uploaded file
# Arguments:
# 1. Test name (string)
# 2. File path to local module (string)
# 3. Expected module name (string)
# 4. Expected module format (string)
# 5. Expected player format (string)
# 6. Expected subsongs (integer)
test_upload_metadata_extraction() {
    TEST_NAME=$1
    FILE_PATH=$2
    EXPECTED_MODULE_NAME=$3
    EXPECTED_MODULE_FORMAT=$4
    EXPECTED_PLAYER_FORMAT=$5
    EXPECTED_SUBSONGS=$6

    echo "--- Testing Upload Metadata Extraction: $TEST_NAME ---"

    UPLOAD_RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST -F "file=@$FILE_PATH" "$BASE_URL/upload")
    UPLOAD_HTTP_CODE=$(echo "$UPLOAD_RESPONSE_ALL" | tail -n1)
    UPLOAD_BODY=$(echo "$UPLOAD_RESPONSE_ALL" | sed '$d')

    if [ "$UPLOAD_HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Received HTTP $UPLOAD_HTTP_CODE for test '$TEST_NAME'"
        echo "Response body: $UPLOAD_BODY"
        exit 1
    fi

    MODULE_NAME=$(echo "$UPLOAD_BODY" | jq -r .module_name)
    MODULE_FORMAT=$(echo "$UPLOAD_BODY" | jq -r .module_format)
    PLAYER_FORMAT=$(echo "$UPLOAD_BODY" | jq -r .player_format)
    SUBSONGS=$(echo "$UPLOAD_BODY" | jq -r .subsongs)

    if [[ "$MODULE_NAME" == "$EXPECTED_MODULE_NAME" && \
          "$MODULE_FORMAT" == "$EXPECTED_MODULE_FORMAT" && \
          "$PLAYER_FORMAT" == "$EXPECTED_PLAYER_FORMAT" && \
          "$SUBSONGS" -eq "$EXPECTED_SUBSONGS" ]]; then
        echo "SUCCESS: Upload and metadata matches expected values for '$TEST_NAME'"
        echo "Response body: $UPLOAD_BODY"
    else
        echo "ERROR: Upload and metadata mismatch for test '$TEST_NAME'"
        echo "Expected module_name: '$EXPECTED_MODULE_NAME', Got: '$MODULE_NAME'"
        echo "Expected module_format: '$EXPECTED_MODULE_FORMAT', Got: '$MODULE_FORMAT'"
        echo "Expected player_format: '$EXPECTED_PLAYER_FORMAT', Got: '$PLAYER_FORMAT'"
        echo "Expected subsongs: '$EXPECTED_SUBSONGS', Got: '$SUBSONGS'"
        echo "Response body: $UPLOAD_BODY"
        exit 1
    fi
    echo ""
}

# Function to test filename extraction from an uploaded file
# Arguments:
# 1. Test name (string)
# 2. File path to local module (string)
# 3. Expected filename after upload (string)
test_upload_filename_extraction() {
    TEST_NAME=$1
    FILE_PATH=$2
    EXPECTED_FILENAME=$3

    echo "--- Testing Upload Filename Extraction: $TEST_NAME ---"

    UPLOAD_RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST -F "file=@$FILE_PATH;filename=$EXPECTED_FILENAME" "$BASE_URL/upload")
    UPLOAD_HTTP_CODE=$(echo "$UPLOAD_RESPONSE_ALL" | tail -n1)
    UPLOAD_BODY=$(echo "$UPLOAD_RESPONSE_ALL" | sed '$d')

    if [ "$UPLOAD_HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Received HTTP $UPLOAD_HTTP_CODE for test '$TEST_NAME'"
        echo "Response body: $UPLOAD_BODY"
        exit 1
    fi

    FILENAME=$(echo "$UPLOAD_BODY" | jq -r .filename)

    if [[ "$FILENAME" == "$EXPECTED_FILENAME" ]]; then
        echo "SUCCESS: Upload and filename matches expected values for '$TEST_NAME'"
        echo "Response body: $UPLOAD_BODY"
    else
        echo "ERROR: Upload and filename mismatch for test '$TEST_NAME'"
        echo "Expected filename: '$EXPECTED_FILENAME', Got: '$FILENAME'"
        echo "Response body: $UPLOAD_BODY"
        exit 1
    fi
    echo ""
}

# Function to test a negative case for file upload (non-module file)
# Arguments:
# 1. Test name (string)
# 2. File path to local non-module file (string)
test_upload_negative_case() {
    TEST_NAME=$1
    FILE_PATH=$2

    echo "--- Testing Upload Negative Case: $TEST_NAME ---"

    UPLOAD_RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST -F "file=@$FILE_PATH" "$BASE_URL/upload")
    UPLOAD_HTTP_CODE=$(echo "$UPLOAD_RESPONSE_ALL" | tail -n1)
    UPLOAD_BODY=$(echo "$UPLOAD_RESPONSE_ALL" | sed '$d')

    if [ "$UPLOAD_HTTP_CODE" -eq 500 ]; then
        EXPECTED_ERROR_MESSAGE="Could not detect module metadata. The file may be corrupt or not a supported module."
        ACTUAL_ERROR_MESSAGE=$(echo "$UPLOAD_BODY" | jq -r .error)
        if [[ "$ACTUAL_ERROR_MESSAGE" == "$EXPECTED_ERROR_MESSAGE" ]]; then
            echo "SUCCESS: Received HTTP 500 and expected error message for '$TEST_NAME'"
            echo "Response body: $UPLOAD_BODY"
        else
            echo "ERROR: Received HTTP 500 but unexpected error message for '$TEST_NAME'"
            echo "Expected: '$EXPECTED_ERROR_MESSAGE'"
            echo "Got: '$ACTUAL_ERROR_MESSAGE'"
            echo "Response body: $UPLOAD_BODY"
            exit 1
        fi
    else
        echo "ERROR: Received unexpected HTTP $UPLOAD_HTTP_CODE (expected 500) for test '$TEST_NAME'"
        echo "Response body: $UPLOAD_BODY"
        exit 1
    fi
    echo ""
}

# Function to test the health endpoint
test_health_endpoint() {
    echo "--- Testing Health Endpoint ---"
    RESPONSE=$(curl -s "$BASE_URL/health")

    # Check for basic status
    STATUS=$(echo "$RESPONSE" | jq -r .status)
    if [ "$STATUS" != "healthy" ]; then
        echo "ERROR: Health status is '$STATUS', expected 'healthy'"
        echo "Response: $RESPONSE"
        exit 1
    fi

    # Check for presence of required keys
    REQUIRED_KEYS=("uptime_seconds" "python_version" "os_platform" "memory" "disk" "binaries" "cache" "temp_files" "config" "uade_version" "version" "image_build_time" "uade_available" "mode" "web_server")
    for key in "${REQUIRED_KEYS[@]}"; do
        if ! echo "$RESPONSE" | jq -e "has(\"$key\")" > /dev/null; then
            echo "ERROR: Missing key '$key' in health response"
            echo "Response: $RESPONSE"
            exit 1
        fi
    done

    # Verify uptime is a number
    UPTIME=$(echo "$RESPONSE" | jq -r .uptime_seconds)
    if [[ ! "$UPTIME" =~ ^[0-9]+$ ]]; then
        echo "ERROR: uptime_seconds is not a number: $UPTIME"
        exit 1
    fi

    MODE=$(echo "$RESPONSE" | jq -r .mode)
    if [ "$MODE" != "development" ] && [ "$MODE" != "production" ]; then
        echo "ERROR: mode is invalid: $MODE"
        exit 1
    fi

    WEB_SERVER=$(echo "$RESPONSE" | jq -r .web_server)
    if [ -z "$WEB_SERVER" ] || [ "$WEB_SERVER" = "null" ]; then
        echo "ERROR: web_server is missing or empty"
        exit 1
    fi
    WEB_SERVER_LOWER=$(printf '%s' "$WEB_SERVER" | tr '[:upper:]' '[:lower:]')
    if [ "$MODE" = "development" ] && [[ "$WEB_SERVER_LOWER" != *"werkzeug"* ]]; then
        echo "ERROR: development mode should report a Werkzeug web_server, got: $WEB_SERVER"
        exit 1
    fi
    if [ "$MODE" = "production" ] && [[ "$WEB_SERVER_LOWER" != *"gunicorn"* ]]; then
        echo "ERROR: production mode should report a Gunicorn web_server, got: $WEB_SERVER"
        exit 1
    fi

    MAX_CONCURRENT_CONVERSIONS=$(echo "$RESPONSE" | jq -r .config.max_concurrent_conversions)
    if [[ ! "$MAX_CONCURRENT_CONVERSIONS" =~ ^[0-9]+$ ]]; then
        echo "ERROR: config.max_concurrent_conversions is not numeric: $MAX_CONCURRENT_CONVERSIONS"
        echo "Response: $RESPONSE"
        exit 1
    fi
    if [ "$MAX_CONCURRENT_CONVERSIONS" -lt 1 ]; then
        echo "ERROR: config.max_concurrent_conversions must be at least 1: $MAX_CONCURRENT_CONVERSIONS"
        echo "Response: $RESPONSE"
        exit 1
    fi

    # Verify image build time is a real ISO-8601 timestamp in the past
    if ! echo "$RESPONSE" | jq -e '
        .image_build_time != null
        and .image_build_time != "unknown"
        and ((.image_build_time | fromdateiso8601) <= now)
    ' > /dev/null; then
        echo "ERROR: image_build_time is missing, invalid, or not in the past"
        echo "Response: $RESPONSE"
        exit 1
    fi

    # Verify binaries check
    UADE_BIN=$(echo "$RESPONSE" | jq -r .binaries.uade123)
    if [ "$UADE_BIN" != "true" ]; then
        echo "ERROR: uade123 binary reported as unavailable"
        exit 1
    fi

    LAST_CACHE_CLEANUP_AT=$(echo "$RESPONSE" | jq -r .cache.last_cleanup_at)
    CACHE_CLEANUP_STATUS=$(echo "$RESPONSE" | jq -r .cache.cleanup_status)
    if ! echo "$CACHE_CLEANUP_STATUS" | grep -Eq '^(not_run_yet|no_old_entries_found|old_entries_removed|cleanup_error)$'; then
        echo "ERROR: cache.cleanup_status is invalid: $CACHE_CLEANUP_STATUS"
        exit 1
    fi
    if [ "$CACHE_CLEANUP_STATUS" = "not_run_yet" ]; then
        if [ "$LAST_CACHE_CLEANUP_AT" != "null" ] && [ -n "$LAST_CACHE_CLEANUP_AT" ]; then
            echo "ERROR: cache.last_cleanup_at should be null before first run: $LAST_CACHE_CLEANUP_AT"
            exit 1
        fi
    else
        if [ "$LAST_CACHE_CLEANUP_AT" = "null" ] || [ -z "$LAST_CACHE_CLEANUP_AT" ]; then
            echo "ERROR: cache.last_cleanup_at is missing after cleanup run"
            exit 1
        fi
        if ! echo "$LAST_CACHE_CLEANUP_AT" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
            echo "ERROR: cache.last_cleanup_at is not an ISO timestamp: $LAST_CACHE_CLEANUP_AT"
            exit 1
        fi
    fi

    LAST_LOCAL_CLEANUP_AT=$(echo "$RESPONSE" | jq -r .temp_files.last_cleanup_at)
    LOCAL_CLEANUP_STATUS=$(echo "$RESPONSE" | jq -r .temp_files.cleanup_status)
    if ! echo "$LOCAL_CLEANUP_STATUS" | grep -Eq '^(not_run_yet|no_old_entries_found|old_entries_removed|cleanup_error)$'; then
        echo "ERROR: temp_files.cleanup_status is invalid: $LOCAL_CLEANUP_STATUS"
        exit 1
    fi
    if [ "$LOCAL_CLEANUP_STATUS" = "not_run_yet" ]; then
        if [ "$LAST_LOCAL_CLEANUP_AT" != "null" ] && [ -n "$LAST_LOCAL_CLEANUP_AT" ]; then
            echo "ERROR: temp_files.last_cleanup_at should be null before first run: $LAST_LOCAL_CLEANUP_AT"
            exit 1
        fi
    else
        if [ "$LAST_LOCAL_CLEANUP_AT" = "null" ] || [ -z "$LAST_LOCAL_CLEANUP_AT" ]; then
            echo "ERROR: temp_files.last_cleanup_at is missing after cleanup run"
            exit 1
        fi
        if ! echo "$LAST_LOCAL_CLEANUP_AT" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
            echo "ERROR: temp_files.last_cleanup_at is not an ISO timestamp: $LAST_LOCAL_CLEANUP_AT"
            exit 1
        fi
    fi

    CACHE_DEBUG=$(echo "$RESPONSE" | jq -c .cache.debug)
    if [ "$CACHE_DEBUG" = "null" ] || [ -z "$CACHE_DEBUG" ]; then
        echo "ERROR: cache.debug is missing in health response"
        echo "Response: $RESPONSE"
        exit 1
    fi

    for key in oldest_entry_at newest_entry_at oldest_accessed_at newest_accessed_at; do
        VALUE=$(echo "$RESPONSE" | jq -r ".cache.debug.$key")
        if [ "$VALUE" != "null" ] && [ -n "$VALUE" ]; then
            if ! echo "$VALUE" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
                echo "ERROR: cache.debug.$key is not an ISO timestamp: $VALUE"
                exit 1
            fi
        fi
    done

    echo "SUCCESS: Health endpoint returned all expected fields and valid data."
    echo ""
}

test_client_config_consistency() {
    echo "--- Testing Client Config Consistency ---"
    HEALTH_RESPONSE=$(curl -s "$BASE_URL/health")
    CONFIG_JS=$(curl -s "$BASE_URL/client-config.js")

    HEALTH_QUEUE_LIMIT=$(echo "$HEALTH_RESPONSE" | jq -r .config.queue_drop_file_limit)
    HEALTH_PROBE_LIMIT=$(echo "$HEALTH_RESPONSE" | jq -r .config.probe_upload_rate_limit_per_minute)
    HEALTH_RATE_LIMITING_ENABLED=$(echo "$HEALTH_RESPONSE" | jq -r .config.rate_limiting_enabled)

    if [[ ! "$HEALTH_QUEUE_LIMIT" =~ ^[0-9]+$ ]]; then
        echo "ERROR: queue_drop_file_limit is not numeric: $HEALTH_QUEUE_LIMIT"
        echo "Health response: $HEALTH_RESPONSE"
        exit 1
    fi

    if [[ ! "$HEALTH_PROBE_LIMIT" =~ ^[0-9]+$ ]]; then
        echo "ERROR: probe_upload_rate_limit_per_minute is not numeric: $HEALTH_PROBE_LIMIT"
        echo "Health response: $HEALTH_RESPONSE"
        exit 1
    fi

    if [ "$HEALTH_RATE_LIMITING_ENABLED" = "true" ]; then
        if [[ "$CONFIG_JS" != *"queueDropFileLimit\":$HEALTH_QUEUE_LIMIT"* ]]; then
            echo "ERROR: client-config.js does not match health queue_drop_file_limit when rate limiting is enabled"
            echo "client-config.js: $CONFIG_JS"
            echo "Health response: $HEALTH_RESPONSE"
            exit 1
        fi
    else
        if [[ "$CONFIG_JS" != *"queueDropFileLimit\":null"* ]]; then
            echo "ERROR: client-config.js should disable the queue drop cap when rate limiting is disabled"
            echo "client-config.js: $CONFIG_JS"
            echo "Health response: $HEALTH_RESPONSE"
            exit 1
        fi
    fi

    if [[ "$CONFIG_JS" != *"rateLimitingEnabled\":$HEALTH_RATE_LIMITING_ENABLED"* ]]; then
        echo "ERROR: client-config.js does not match health rate_limiting_enabled"
        echo "client-config.js: $CONFIG_JS"
        echo "Health response: $HEALTH_RESPONSE"
        exit 1
    fi

    echo "SUCCESS: client-config.js matches health config (rate limiting: $HEALTH_RATE_LIMITING_ENABLED, configured queue limit: $HEALTH_QUEUE_LIMIT, probe-upload limit: $HEALTH_PROBE_LIMIT/min)."
    echo ""
}

test_client_config_disables_queue_cap_in_app_js() {
    echo "--- Testing Client Config Null Disables Queue Cap In App JS ---"

    HEALTH_RESPONSE=$(curl -s "$BASE_URL/health")
    HEALTH_RATE_LIMITING_ENABLED=$(echo "$HEALTH_RESPONSE" | jq -r .config.rate_limiting_enabled)
    APP_JS=$(curl -s "$BASE_URL/static/app.js")

    if [ "$HEALTH_RATE_LIMITING_ENABLED" = "false" ]; then
        if [[ "$APP_JS" == *"queueDropFileLimit ?? 20"* ]]; then
            echo "ERROR: app.js still uses a nullish fallback for queueDropFileLimit, which re-enables the cap when client-config.js sets null"
            exit 1
        fi

        if [[ "$APP_JS" != *"window.__UADE_CONFIG__"* ]] || [[ "$APP_JS" != *"QUEUE_DROP_LIMIT_ENABLED"* ]]; then
            echo "ERROR: app.js is missing the expected runtime-config queue-cap logic"
            exit 1
        fi
    fi

    echo "SUCCESS: app.js preserves client-config null for queueDropFileLimit when rate limiting is disabled."
    echo ""
}

test_queue_drop_autoplay_does_not_reuse_queue_button_loading_state() {
    echo "--- Testing Queue Drop Avoids Queue Button Loading State ---"

    APP_JS=$(curl -s "$BASE_URL/static/app.js")

    if [[ "$APP_JS" == *"playPlaylistTrack(track.id, queueBrowseBtn)"* ]]; then
        echo "ERROR: queue-drop autoplay still reuses queueBrowseBtn, which can leave the queue UI stuck on Checking..."
        exit 1
    fi

    if [[ "$APP_JS" == *"showButtonLoadingAndGetOriginal(queueBrowseBtn, \"Checking...\")"* ]]; then
        echo "ERROR: queue-drop probing still reuses queueBrowseBtn as a loading indicator"
        exit 1
    fi

    if [[ "$APP_JS" != *"playPlaylistTrack(track.id)"* ]]; then
        echo "ERROR: app.js is missing the expected queue autoplay call without queueBrowseBtn"
        exit 1
    fi

    echo "SUCCESS: queue probing and autoplay no longer share queueBrowseBtn loading state."
    echo ""
}

test_queue_probe_uses_status_instead_of_queue_button_label() {
    echo "--- Testing Queue Probe Uses Status Instead Of Queue Button Label ---"

    APP_JS=$(curl -s "$BASE_URL/static/app.js")

    if [[ "$APP_JS" != *"Checking queue file \${index + 1} of \${files.length}: \${file.name}"* ]]; then
        echo "ERROR: app.js is missing the expected queue batch progress status"
        exit 1
    fi

    if [[ "$APP_JS" == *"showButtonLoadingAndGetOriginal(queueBrowseBtn, \"Checking...\")"* ]]; then
        echo "ERROR: app.js still uses queueBrowseBtn as a probe loading indicator"
        exit 1
    fi

    echo "SUCCESS: queue probes report progress in status text without mutating queueBrowseBtn."
    echo ""
}

test_remote_cache_access_record_refresh() {
    TEST_NAME=$1
    URL=$2

    echo "--- Testing Remote Cache Access Record: $TEST_NAME ---"

    HTTP_CODE_BODY=$(_perform_convert_url_call "$URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Initial convert-url call failed with HTTP $HTTP_CODE for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    FILE_ID=$(echo "$BODY" | jq -r .file_id)
    ACCESS_RECORD_PATH="/uade-tmp/cache/${FILE_ID}.cache-access.json"

    if [ ! -f "$ACCESS_RECORD_PATH" ]; then
        echo "ERROR: Cache access record not found for '$TEST_NAME'"
        echo "Expected path: $ACCESS_RECORD_PATH"
        exit 1
    fi

    BEFORE_TS=$(stat -c %Y "$ACCESS_RECORD_PATH")
    LAST_ACCESSED_AT=$(jq -r .last_accessed_at "$ACCESS_RECORD_PATH")
    if [ -z "$LAST_ACCESSED_AT" ] || [ "$LAST_ACCESSED_AT" = "null" ]; then
        echo "ERROR: Cache access record missing last_accessed_at for '$TEST_NAME'"
        cat "$ACCESS_RECORD_PATH"
        exit 1
    fi

    sleep 2

    HTTP_CODE_BODY=$(_perform_convert_url_call "$URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Second convert-url call failed with HTTP $HTTP_CODE for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    AFTER_TS=$(stat -c %Y "$ACCESS_RECORD_PATH")
    if [ "$AFTER_TS" -le "$BEFORE_TS" ]; then
        echo "ERROR: Cache access record timestamp did not advance for '$TEST_NAME'"
        echo "Before: $BEFORE_TS"
        echo "After: $AFTER_TS"
        cat "$ACCESS_RECORD_PATH"
        exit 1
    fi

    echo "SUCCESS: Cache access record timestamp advanced on cache hit."
    echo ""
}

test_no_orphaned_cache_access_temp_files_under_parallel_hits() {
    TEST_NAME=$1
    URL=$2

    echo "--- Testing Remote Cache Access Temp Cleanup: $TEST_NAME ---"

    HTTP_CODE_BODY=$(_perform_convert_url_call "$URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Initial convert-url call failed with HTTP $HTTP_CODE for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    FILE_ID=$(echo "$BODY" | jq -r .file_id)

    seq 1 8 | xargs -I{} -P 8 sh -c "
        curl -s -X POST \
            -H 'Content-Type: application/json' \
            -d '{\"url\":\"$URL\"}' \
            '$BASE_URL/convert-url' > /dev/null
    "

    TEMP_FILES=$(find /uade-tmp/cache -maxdepth 1 -name "${FILE_ID}.cache-access.json.*.tmp" | wc -l)
    if [ "$TEMP_FILES" -ne 0 ]; then
        echo "ERROR: Found orphaned cache access temp files for '$TEST_NAME'"
        find /uade-tmp/cache -maxdepth 1 -name "${FILE_ID}.cache-access.json.*.tmp"
        exit 1
    fi

    echo "SUCCESS: Parallel cache hits left no orphaned cache access temp files."
    echo ""
}

test_convert_url_uses_canonical_flac() {
    TEST_NAME=$1
    URL=$2

    echo "--- Testing Canonical FLAC Conversion: $TEST_NAME ---"

    HTTP_CODE_BODY=$(_perform_convert_url_call "$URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Initial convert-url call failed with HTTP $HTTP_CODE for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    FILE_ID=$(echo "$BODY" | jq -r .file_id)
    AUDIO_FORMAT=$(echo "$BODY" | jq -r .audio_format)
    LOCAL_WAV="/uade-tmp/converted/${FILE_ID}.wav"
    LOCAL_FLAC="/uade-tmp/converted/${FILE_ID}.flac"

    if [ -z "$FILE_ID" ] || [ "$FILE_ID" = "null" ]; then
        echo "ERROR: file_id missing from initial response for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    if [ "$AUDIO_FORMAT" != "flac" ]; then
        echo "ERROR: Initial request did not return FLAC for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    if [ ! -f "$LOCAL_FLAC" ]; then
        echo "ERROR: Expected local FLAC cache file not found for '$TEST_NAME'"
        echo "Expected path: $LOCAL_FLAC"
        exit 1
    fi

    if [ -f "$LOCAL_WAV" ]; then
        _remove_cache_artifact "$FILE_ID" ".wav" > /dev/null
    fi

    if [ -f "$LOCAL_WAV" ]; then
        echo "ERROR: Failed to clear legacy local WAV cache file for '$TEST_NAME'"
        echo "Unexpected path: $LOCAL_WAV"
        exit 1
    fi

    HTTP_CODE_BODY=$(_perform_convert_url_call "$URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)
    AUDIO_FORMAT=$(echo "$BODY" | jq -r .audio_format)

    if [ "$HTTP_CODE" -ne 200 ] || [ "$AUDIO_FORMAT" != "flac" ]; then
        echo "ERROR: Follow-up request did not return canonical FLAC for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    if [ -f "$LOCAL_WAV" ] || [ ! -f "$LOCAL_FLAC" ]; then
        echo "ERROR: Expected FLAC-only local cache files after follow-up for '$TEST_NAME'"
        echo "WAV exists: $( [ -f "$LOCAL_WAV" ] && echo yes || echo no )"
        echo "FLAC exists: $( [ -f "$LOCAL_FLAC" ] && echo yes || echo no )"
        exit 1
    fi

    echo "SUCCESS: convert-url returned canonical FLAC without creating a WAV sibling."
    echo ""
}

test_local_cleanup_preserves_refreshed_flac() {
    TEST_NAME=$1
    URL=$2

    echo "--- Testing Local Cleanup Preserves Refreshed FLAC: $TEST_NAME ---"

    HTTP_CODE_BODY=$(_perform_convert_url_call "$URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Initial convert-url call failed with HTTP $HTTP_CODE for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    FILE_ID=$(echo "$BODY" | jq -r .file_id)
    LOCAL_WAV="/uade-tmp/converted/${FILE_ID}.wav"
    LOCAL_FLAC="/uade-tmp/converted/${FILE_ID}.flac"
    AUDIO_FORMAT=$(echo "$BODY" | jq -r .audio_format)

    if [ -z "$FILE_ID" ] || [ "$FILE_ID" = "null" ]; then
        echo "ERROR: file_id missing from initial response for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    if [ "$AUDIO_FORMAT" != "flac" ] || [ ! -f "$LOCAL_FLAC" ]; then
        echo "ERROR: Initial request did not establish a FLAC-only starting point for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    if [ -f "$LOCAL_WAV" ]; then
        _remove_cache_artifact "$FILE_ID" ".wav" > /dev/null
    fi

    if [ -f "$LOCAL_WAV" ]; then
        echo "ERROR: Failed to clear legacy local WAV cache file for '$TEST_NAME'"
        exit 1
    fi

    _set_local_file_mtime "$FILE_ID" ".flac" 1577840460 > /dev/null
    FLAC_TS_OLD=$(stat -c %Y "$LOCAL_FLAC")

    HTTP_CODE_BODY=$(_perform_convert_url_call "$URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)
    AUDIO_FORMAT=$(echo "$BODY" | jq -r .audio_format)

    if [ "$HTTP_CODE" -ne 200 ] || [ "$AUDIO_FORMAT" != "flac" ]; then
        echo "ERROR: FLAC cache-hit refresh request failed for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    FLAC_TS_BEFORE_CLEANUP=$(stat -c %Y "$LOCAL_FLAC")

    if [ "$FLAC_TS_BEFORE_CLEANUP" -le "$FLAC_TS_OLD" ]; then
        echo "ERROR: Expected FLAC cache hit to refresh local FLAC for '$TEST_NAME'"
        echo "Old FLAC timestamp: $FLAC_TS_OLD"
        echo "New FLAC timestamp: $FLAC_TS_BEFORE_CLEANUP"
        exit 1
    fi

    LOCAL_RESPONSE=$(_run_cleanup_scope "local")
    LOCAL_STATUS=$(echo "$LOCAL_RESPONSE" | jq -r .local.cleanup_status)

    if [ "$LOCAL_STATUS" != "healthy" ] && [ "$LOCAL_STATUS" != "old_entries_removed" ] && [ "$LOCAL_STATUS" != "no_old_entries_found" ]; then
        echo "ERROR: Unexpected local cleanup status for '$TEST_NAME': '$LOCAL_STATUS'"
        echo "Response body: $LOCAL_RESPONSE"
        exit 1
    fi

    if [ -f "$LOCAL_WAV" ]; then
        echo "ERROR: Unexpected WAV exists after local cleanup for '$TEST_NAME'"
        exit 1
    fi

    if [ ! -f "$LOCAL_FLAC" ]; then
        echo "ERROR: Refreshed FLAC was removed unexpectedly during local cleanup for '$TEST_NAME'"
        exit 1
    fi

    echo "SUCCESS: Local cleanup preserved the refreshed canonical FLAC artifact."
    echo ""
}

test_play_endpoint_serves_existing_flac() {
    TEST_NAME=$1
    URL=$2

    echo "--- Testing Play Endpoint Serves Existing FLAC: $TEST_NAME ---"

    HTTP_CODE_BODY=$(_perform_convert_url_call "$URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Initial convert-url call failed with HTTP $HTTP_CODE for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    FILE_ID=$(echo "$BODY" | jq -r .file_id)
    AUDIO_FORMAT=$(echo "$BODY" | jq -r .audio_format)
    LOCAL_WAV="/uade-tmp/converted/${FILE_ID}.wav"
    LOCAL_FLAC="/uade-tmp/converted/${FILE_ID}.flac"

    if [ -z "$FILE_ID" ] || [ "$FILE_ID" = "null" ]; then
        echo "ERROR: file_id missing from initial response for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    if [ "$AUDIO_FORMAT" != "flac" ] || [ ! -f "$LOCAL_FLAC" ]; then
        echo "ERROR: Initial request did not establish a FLAC-only starting point for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    if [ -f "$LOCAL_WAV" ]; then
        _remove_cache_artifact "$FILE_ID" ".wav" > /dev/null
    fi

    if [ -f "$LOCAL_WAV" ]; then
        echo "ERROR: Failed to clear legacy local WAV cache file for '$TEST_NAME'"
        exit 1
    fi

    PLAY_RESPONSE=$(curl -s -D - -o /dev/null -w "\n%{http_code}" "$BASE_URL/play/$FILE_ID")
    PLAY_HTTP_CODE=$(echo "$PLAY_RESPONSE" | tail -n1)
    PLAY_HEADERS=$(echo "$PLAY_RESPONSE" | head -n -1)

    if [ "$PLAY_HTTP_CODE" -ne 200 ] && [ "$PLAY_HTTP_CODE" -ne 206 ]; then
        echo "ERROR: Play endpoint returned unexpected HTTP $PLAY_HTTP_CODE for '$TEST_NAME'"
        echo "Headers: $PLAY_HEADERS"
        exit 1
    fi

    if ! echo "$PLAY_HEADERS" | grep -qi "^Content-Type: audio/flac"; then
        echo "ERROR: Play endpoint did not serve FLAC for '$TEST_NAME'"
        echo "Headers: $PLAY_HEADERS"
        exit 1
    fi

    if [ ! -f "$LOCAL_FLAC" ] || [ -f "$LOCAL_WAV" ]; then
        echo "ERROR: Expected play endpoint to keep serving the existing FLAC only for '$TEST_NAME'"
        echo "Local FLAC exists: $( [ -f "$LOCAL_FLAC" ] && echo yes || echo no )"
        echo "Local WAV exists: $( [ -f "$LOCAL_WAV" ] && echo yes || echo no )"
        exit 1
    fi

    echo "SUCCESS: Play endpoint served the existing FLAC without creating a WAV sibling."
    echo ""
}

_run_cleanup_scope() {
    LOCAL_SCOPE=$1

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"scope\":\"$LOCAL_SCOPE\"}" \
        "$BASE_URL/test/run-cleanup")

    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Cleanup trigger failed for scope '$LOCAL_SCOPE'"
        echo "Response body: $BODY"
        exit 1
    fi

    echo "$BODY"
}

_set_local_file_mtime() {
    LOCAL_FILE_ID=$1
    LOCAL_EXT=$2
    LOCAL_MTIME_EPOCH=$3

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"file_id\":\"$LOCAL_FILE_ID\",\"ext\":\"$LOCAL_EXT\",\"mtime_epoch\":$LOCAL_MTIME_EPOCH}" \
        "$BASE_URL/test/set-local-file-mtime")

    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Failed to set local file mtime for ${LOCAL_FILE_ID}${LOCAL_EXT}"
        echo "Response body: $BODY"
        exit 1
    fi

    echo "$BODY"
}

_remove_cache_artifact() {
    LOCAL_FILE_ID=$1
    LOCAL_EXT=$2

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"file_id\":\"$LOCAL_FILE_ID\",\"ext\":\"$LOCAL_EXT\"}" \
        "$BASE_URL/test/remove-cache-artifact")

    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Failed to remove cache artifact for ${LOCAL_FILE_ID}${LOCAL_EXT}"
        echo "Response body: $BODY"
        exit 1
    fi

    echo "$BODY"
}

test_cleanup_status_and_timestamp_transitions() {
    echo "--- Testing Cleanup Status And Timestamp Transitions ---"

    mkdir -p /uade-tmp/converted /uade-tmp/cache

    LOCAL_STALE_FILE="/uade-tmp/converted/health-cleanup-stale.tmp"
    touch "$LOCAL_STALE_FILE"
    touch -t 202001010101 "$LOCAL_STALE_FILE"

    LOCAL_RESPONSE=$(_run_cleanup_scope "local")
    LOCAL_STATUS=$(echo "$LOCAL_RESPONSE" | jq -r .local.cleanup_status)
    LOCAL_TS_1=$(echo "$LOCAL_RESPONSE" | jq -r .local.last_cleanup_at)

    if [ "$LOCAL_STATUS" != "old_entries_removed" ]; then
        echo "ERROR: Expected local cleanup to remove old entries, got '$LOCAL_STATUS'"
        echo "Response body: $LOCAL_RESPONSE"
        exit 1
    fi

    if [ -e "$LOCAL_STALE_FILE" ]; then
        echo "ERROR: Local stale file still exists after cleanup"
        exit 1
    fi

    sleep 1

    LOCAL_RESPONSE=$(_run_cleanup_scope "local")
    LOCAL_STATUS=$(echo "$LOCAL_RESPONSE" | jq -r .local.cleanup_status)
    LOCAL_TS_2=$(echo "$LOCAL_RESPONSE" | jq -r .local.last_cleanup_at)

    if [ "$LOCAL_STATUS" != "no_old_entries_found" ]; then
        echo "ERROR: Expected local cleanup to report no old entries, got '$LOCAL_STATUS'"
        echo "Response body: $LOCAL_RESPONSE"
        exit 1
    fi

    if [[ ! "$LOCAL_TS_2" > "$LOCAL_TS_1" ]]; then
        echo "ERROR: Local cleanup timestamp did not advance on no-op cleanup"
        echo "First timestamp: $LOCAL_TS_1"
        echo "Second timestamp: $LOCAL_TS_2"
        exit 1
    fi

    CACHE_HASH="health-cache-stale"
    CACHE_STALE_FILE="/uade-tmp/cache/${CACHE_HASH}.wav"
    CACHE_ACCESS_RECORD="/uade-tmp/cache/${CACHE_HASH}.cache-access.json"

    echo "stale" > "$CACHE_STALE_FILE"
    cat > "$CACHE_ACCESS_RECORD" <<'EOF'
{"last_accessed_at":"2020-01-01T01:01:00+00:00"}
EOF
    touch -t 202001010101 "$CACHE_STALE_FILE"
    touch -t 202001010101 "$CACHE_ACCESS_RECORD"

    CACHE_RESPONSE=$(_run_cleanup_scope "cache")
    CACHE_STATUS=$(echo "$CACHE_RESPONSE" | jq -r .cache.cleanup_status)
    CACHE_TS_1=$(echo "$CACHE_RESPONSE" | jq -r .cache.last_cleanup_at)

    if [ "$CACHE_STATUS" != "old_entries_removed" ]; then
        echo "ERROR: Expected cache cleanup to remove old entries, got '$CACHE_STATUS'"
        echo "Response body: $CACHE_RESPONSE"
        exit 1
    fi

    if [ -e "$CACHE_STALE_FILE" ] || [ -e "$CACHE_ACCESS_RECORD" ]; then
        echo "ERROR: Cache stale artifacts still exist after cleanup"
        exit 1
    fi

    sleep 1

    CACHE_RESPONSE=$(_run_cleanup_scope "cache")
    CACHE_STATUS=$(echo "$CACHE_RESPONSE" | jq -r .cache.cleanup_status)
    CACHE_TS_2=$(echo "$CACHE_RESPONSE" | jq -r .cache.last_cleanup_at)

    if [ "$CACHE_STATUS" != "no_old_entries_found" ]; then
        echo "ERROR: Expected cache cleanup to report no old entries, got '$CACHE_STATUS'"
        echo "Response body: $CACHE_RESPONSE"
        exit 1
    fi

    if [[ ! "$CACHE_TS_2" > "$CACHE_TS_1" ]]; then
        echo "ERROR: Cache cleanup timestamp did not advance on no-op cleanup"
        echo "First timestamp: $CACHE_TS_1"
        echo "Second timestamp: $CACHE_TS_2"
        exit 1
    fi

    HEALTH_RESPONSE=$(curl -s "$BASE_URL/health")
    HEALTH_LOCAL_STATUS=$(echo "$HEALTH_RESPONSE" | jq -r .temp_files.cleanup_status)
    HEALTH_CACHE_STATUS=$(echo "$HEALTH_RESPONSE" | jq -r .cache.cleanup_status)
    HEALTH_LOCAL_TS=$(echo "$HEALTH_RESPONSE" | jq -r .temp_files.last_cleanup_at)
    HEALTH_CACHE_TS=$(echo "$HEALTH_RESPONSE" | jq -r .cache.last_cleanup_at)

    if [ "$HEALTH_LOCAL_STATUS" != "no_old_entries_found" ] || [ "$HEALTH_CACHE_STATUS" != "no_old_entries_found" ]; then
        echo "ERROR: Health endpoint cleanup statuses do not reflect latest cleanup runs"
        echo "Response: $HEALTH_RESPONSE"
        exit 1
    fi

    if [ "$HEALTH_LOCAL_TS" != "$LOCAL_TS_2" ] || [ "$HEALTH_CACHE_TS" != "$CACHE_TS_2" ]; then
        echo "ERROR: Health endpoint cleanup timestamps do not match latest cleanup runs"
        echo "Response: $HEALTH_RESPONSE"
        exit 1
    fi

    echo "SUCCESS: Cleanup status and timestamp transitions validated."
    echo ""
}

print_endpoint_coverage_summary() {
    python3 ./report_endpoint_coverage.py test_endpoints.sh
    echo ""
}


# Wait for the service to be up
echo "Waiting for uade-web-player to be available..."
while ! curl -s "$BASE_URL/health" > /dev/null; do
    sleep 1
done
echo "Service is up!"

test_health_endpoint
test_client_config_consistency
test_client_config_disables_queue_cap_in_app_js
test_queue_drop_autoplay_does_not_reuse_queue_button_loading_state
test_queue_probe_uses_status_instead_of_queue_button_label

# Cache behavior tests run early to reduce interference from warmed cache state.
# Individual tests may still use unique URLs or explicit cache-reset helpers when
# they need a precise starting condition.
test_cleanup_status_and_timestamp_transitions
test_cache_hit_url "Server-side cache hit for convert-url" "https://modland.com/pub/modules/Protracker/Lizardking/l.k%27s%20doskpop.mod"
test_url_cache_logic "URL download cache" "https://modland.com/pub/modules/Protracker/Lizardking/l.k%27s%20doskpop.mod"
test_url_cache_normalizes_cache_busters "URL cache ignores known cache-buster params" "$LOCAL_TEST_SERVER_URL/fixtures/modules/space_debris.mod"
test_remote_cache_access_record_refresh "Sidecar access record refresh" "https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod"
test_no_orphaned_cache_access_temp_files_under_parallel_hits "No orphaned sidecar temp files" "https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod"
test_convert_url_uses_canonical_flac "Canonical FLAC conversion has no WAV sibling" "https://modland.com/pub/modules/Protracker/4-Mat/agony-beginning.mod"
test_play_endpoint_serves_existing_flac "Play endpoint serves existing FLAC" "https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod"
test_local_cleanup_preserves_refreshed_flac "Local cleanup preserves refreshed canonical FLAC" "https://modland.com/pub/modules/Protracker/Captain/beyond%20music.mod"

_create_stale_conversion_lock() {
    LOCAL_CACHE_HASH=$1

    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"cache_hash\":\"$LOCAL_CACHE_HASH\"}" \
        "$BASE_URL/test/create-stale-conversion-lock")

    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Failed to create stale lock for $LOCAL_CACHE_HASH"
        echo "Response body: $BODY"
        exit 1
    fi

    echo "$BODY"
}

test_stale_conversion_lock_reclamation() {
    TEST_NAME=$1
    URL=$2

    echo "--- Testing Stale Conversion Lock Reclamation: $TEST_NAME ---"

    # Step 1: Warm once so we learn the actual stable content hash/file_id.
    HTTP_CODE_BODY=$(_perform_convert_url_call "$URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Warm-up convert-url call failed with HTTP $HTTP_CODE for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    FILE_ID=$(echo "$BODY" | jq -r .file_id)
    AUDIO_FORMAT=$(echo "$BODY" | jq -r .audio_format)

    if [ -z "$FILE_ID" ] || [ "$FILE_ID" = "null" ]; then
        echo "ERROR: Warm-up response missing file_id for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    if [ "$AUDIO_FORMAT" != "flac" ]; then
        echo "ERROR: Warm-up response did not establish canonical FLAC for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    # Step 2: Remove the exact cached artifact so the next request cannot
    # short-circuit on a remote/local cache hit before checking the lock.
    _remove_cache_artifact "$FILE_ID" ".flac" > /dev/null

    # Step 3: Create a stale lock for the exact content hash this URL uses.
    _create_stale_conversion_lock "$FILE_ID" > /dev/null

    # Step 4: Trigger conversion. It should hit the lock, see it's stale,
    # clear it, and successfully convert.
    HTTP_CODE_BODY=$(_perform_convert_url_call "$URL")
    HTTP_CODE=$(echo "$HTTP_CODE_BODY" | head -n1)
    BODY=$(echo "$HTTP_CODE_BODY" | tail -n1)

    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: convert-url failed when encountering a stale lock for '$TEST_NAME'"
        echo "HTTP Code: $HTTP_CODE"
        echo "Response body: $BODY"
        exit 1
    fi

    FILE_ID=$(echo "$BODY" | jq -r .file_id)
    if [ -z "$FILE_ID" ] || [ "$FILE_ID" = "null" ]; then
        echo "ERROR: file_id missing from response for '$TEST_NAME'"
        echo "Response body: $BODY"
        exit 1
    fi

    echo "SUCCESS: Stale conversion lock was reclaimed and conversion succeeded."
    echo ""
}

test_stale_conversion_lock_reclamation "Stale lock is reclaimed" "${LOCAL_TEST_SERVER_URL}/fixtures/modules/stormlord.ahx?case=stale-lock-reclaimed"

test_probe_url "Probe Protracker module" "https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod"
test_probe_url "Probe TFMX module" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.turrican%202%20level%200-intro" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.turrican%202%20level%200-intro"
test_probe_has_no_conversion_fields "Probe metadata only response" "https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod"
test_probe_error "Probe reject localhost URL" "http://localhost:5000/health" "" 400 "Unsafe or disallowed URL provided"
test_probe_missing_url
test_probe_malformed_json
test_probe_error "Probe local fixture server 404" "$LOCAL_TEST_SERVER_URL/fixtures/missing/not-found.mod" "" 400 "External module URL could not be fetched"
test_probe_error "Probe local upstream transport failure" "http://uade-test-http-server:65534/fixtures/modules/space_debris.mod" "" 502 "Download failed for External module"
test_probe_error "Probe reject mutated module URL" "$LOCAL_TEST_SERVER_URL/fixtures/modules/space_debris.mod;get-help" "" 400 "URL could not be fetched"
test_probe_error "Probe reject mutated sample URL" "$LOCAL_TEST_SERVER_URL/fixtures/modules/mdat.turrican_2_level_0-intro" "$LOCAL_TEST_SERVER_URL/fixtures/modules/smpl.turrican_2_level_0-intro;sleep%2015.0;" 400 "URL could not be fetched"
test_probe_oversized_remote_file "Probe oversized remote file" "$LOCAL_TEST_SERVER_URL/fixtures/invalid/too-large.bin"
test_probe_error "Probe unsupported remote file" "$LOCAL_TEST_SERVER_URL/fixtures/modules/gutenberg.txt" "" 500 "Could not detect module metadata. The file may be corrupt or not a supported module."

test_url "Protracker module" "https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod"
test_url "AHX module" "https://modland.com/pub/modules/AHX/Pink/stormlord.ahx"
test_url "TFMX module" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.turrican%202%20level%200-intro" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.turrican%202%20level%200-intro"
test_url "TFMX module (Apidya)" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.apidya%20%28level%201%29" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.apidya%20%28level%201%29"
test_url "LHA archive" "http://files.exotica.org.uk/?file=exotica/media%2Faudio%2FUnExoticA%2FGame%2FBrimble_Allister%2FProject-X.lha"
test_url "ZIP archive" "https://files.scene.org/get:fi-https/music/artists/4-mat/chip_shop.zip"
test_url "RJP module" "https://modland.com/pub/modules/Richard%20Joseph/Richard%20Joseph/cannon%20fodder%20(intro).sng" "https://modland.com/pub/modules/Richard%20Joseph/Richard%20Joseph/cannon%20fodder%20(intro).ins"
test_url "Negative case (non-module)" "$LOCAL_TEST_SERVER_URL/fixtures/modules/gutenberg.txt"
test_download_filename_sanitization "Sanitize hostile download filename" "https://modland.com/pub/modules/Protracker/Lizardking/l.k%27s%20doskpop.mod" "" "%3Cimg%20src%3Dx%20onerror%3Dalert(1)%3E" "filename=\"uade_img_srcx_onerroralert1"

# Security tests
# Keep validation-only reject cases on external-looking URLs when the app fails fast
# before any network fetch. This preserves the intended validation path without
# burdening third-party services. Only fetch-path negative cases use the local
# test server fixtures above.
test_security_url "Reject localhost URL" "http://localhost:5000/health"
test_security_url "Reject private IP URL" "http://192.168.1.1/internal"
test_security_url "Reject URL with command injection attempt" "https://example.com/file%60%20rm%20-rf%20/%60"
test_security_url "Reject URL with newlines" "https://example.com/file%0a%0ainjected"
test_security_url "Reject dual-file module with unsafe sample_url" "https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod" "http://192.168.1.1/internal"
test_security_url "Reject TFMX modules sample_url with newlines" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.apidya%20%28level%201%29" "https://example.com/file%0a%0ainjected"
test_security_url "Reject RJP modules unsafe url when sample_url is safe" "https://example.com/file%60%20rm%20-rf%20/%60" "https://modland.com/pub/modules/Richard%20Joseph/Richard%20Joseph/cannon%20fodder%20(intro).ins"
test_security_url "Reject convert-url with no URL" "$BASE_URL/convert-url" "{}"
# Path traversal in filename (should be rejected or sanitized)
test_security_url "Reject path traversal in URL" "https://example.com/../../etc/passwd"
# SSRF with encoded localhost IP (should be rejected)
test_security_url "Reject encoded localhost IP" "http://2130706433:5000/health"
# SSRF with IPv6 localhost (should be rejected)
test_security_url "Reject IPv6 localhost" "http://[::1]/admin"
test_security_url "Reject convert-url with quoted module URL" "https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod'"
test_security_url "Reject convert-url with quoted sample URL" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.turrican%202%20level%200-intro" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.turrican%202%20level%200-intro'"
test_security_url "Reject convert-url with mutated module URL" "$LOCAL_TEST_SERVER_URL/fixtures/modules/space_debris.mod;get-help"
test_security_url "Reject convert-url with mutated sample URL" "$LOCAL_TEST_SERVER_URL/fixtures/modules/mdat.turrican_2_level_0-intro" "$LOCAL_TEST_SERVER_URL/fixtures/modules/smpl.turrican_2_level_0-intro;sleep%2015.0;"
test_convert_url_error "Convert URL local fixture server 404" "$LOCAL_TEST_SERVER_URL/fixtures/missing/not-found.mod" "" 400 "External module URL could not be fetched"
test_convert_url_error "Convert URL local upstream transport failure" "http://uade-test-http-server:65534/fixtures/modules/space_debris.mod" "" 502 "Download failed for External module"
test_convert_url_malformed_json
test_convert_url_wrong_content_type

# XSS in filename/module name (should not be reflected unsanitized)
test_xss_filename "https://example.com/<script>alert('xss')</script>.mod"

# Note: The FLAC test file must be unique in test cases and must not be returned by the
# example modules endpoint (app.route("/examples")) to ensure a fresh conversion.
test_url_with_ua "Canonical FLAC conversion with Chrome UA"  "https://modland.com/pub/modules/Protracker/Lizardking/l.k%27s%20doskpop.mod" "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0.0.0" "flac"

test_range_request "Range request for large TFMX module" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.turrican%202%20level%200-intro" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.turrican%202%20level%200-intro"

test_security_malformed_range "Reject malformed range" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.turrican%202%20level%200-intro" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.turrican%202%20level%200-intro"

test_download_functionality "Download Protracker module" "https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod"
test_external_download_flow_with_oversized_file "Download file exceeding 10MB limit" "$LOCAL_TEST_SERVER_URL/fixtures/invalid/too-large.bin"

# Metadata extraction tests
test_metadata_extraction "Full metadata" "https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod" "" "space debris" "Protracker" "Protracker and family" 1
test_metadata_extraction "Custom module" "https://zakalwe.fi/uade/amiga-music/customs/WingsOfDeath-Levels1-7/cust.WingsOfDeath-Levels1-7" "" "" "Custom" "Custom" 8
test_metadata_extraction "Partial metadata" "https://modland.com/pub/modules/Richard%20Joseph/Richard%20Joseph/cannon%20fodder%20(intro).sng" "https://modland.com/pub/modules/Richard%20Joseph/Richard%20Joseph/cannon%20fodder%20(intro).ins" "" "" "Richard Joseph Player" 2

# Subsong duration tests
test_subsong_durations "Multi-subsong TFMX module" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.turrican%202%20level%200-intro" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.turrican%202%20level%200-intro" 3
test_subsong_durations "Single subsong module" "https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod" "" 1

# Filename extraction tests
test_filename_extraction "ModArchive URL" "https://api.modarchive.org/downloads.php?moduleid=188875#way_too_rude.mod" "way_too_rude.mod"
test_filename_extraction "Modland URL" "https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod" "space_debris.mod"
test_filename_extraction "Exotica URL" "http://files.exotica.org.uk/?file=exotica/media%2Faudio%2FUnExoticA%2FGame%2FBrimble_Allister%2FProject-X.lha" "mod.thesmophoria"
test_filename_extraction "Scene.org URL" "https://files.scene.org/get:fi-https/music/artists/4-mat/chip_shop.zip" "Chip_Shop.mod"

# Upload tests
test_upload_conversion "Protracker module upload" "fixtures/modules/space_debris.mod"
test_upload_metadata_extraction "Protracker module upload" "fixtures/modules/space_debris.mod" "space debris" "Protracker" "Protracker and family" 1
test_upload_filename_extraction "Protracker module upload" "fixtures/modules/space_debris.mod" "space_debris.mod"
test_upload_negative_case "Non-module file upload" "fixtures/modules/gutenberg.txt"
test_upload_error "Reject empty file upload" "fixtures/invalid/empty.bin" 400
test_upload_error "Reject oversized file upload" "fixtures/invalid/too-large.bin" 413
test_upload_oversized_payload_shape "Reject oversized file upload uses shared 413 payload" "fixtures/invalid/too-large.bin"

# Probe-upload tests
test_probe_upload "Probe upload Protracker module" "fixtures/modules/space_debris.mod"
test_probe_upload_error "Probe upload non-module file" "fixtures/modules/gutenberg.txt" 500 "Could not detect module metadata"
test_probe_upload_preserves_negative_cache "Probe upload invalid file preserves negative cache" "fixtures/modules/gutenberg.txt"
test_probe_upload_error "Probe upload empty file" "fixtures/invalid/empty.bin" 400 "Empty file provided"
test_probe_upload_error "Probe upload oversized file" "fixtures/invalid/too-large.bin" 413
test_probe_upload_oversized_payload_shape "Probe upload oversized file uses shared 413 payload" "fixtures/invalid/too-large.bin"
test_probe_upload_no_file
test_probe_upload_wrong_method
test_probe_upload_path_traversal_filename "fixtures/modules/space_debris.mod"

# Convert-probed tests (probe → convert-probed → play workflow)
test_probe_convert_play_flow "Protracker module" "fixtures/modules/space_debris.mod" "space debris" "Protracker and family"
test_probe_upload_dedup "fixtures/modules/space_debris.mod"
test_probe_upload_dedup_concurrent "fixtures/modules/space_debris.mod"
test_convert_probed_reconverts_after_cache_removal "fixtures/modules/space_debris.mod"
test_convert_probed_404_then_upload_fallback "fixtures/modules/space_debris.mod"
test_convert_probed_invalid_hash
test_convert_probed_not_found
test_convert_probed_bad_request
test_convert_probed_non_string_filename
test_convert_probed_wrong_method

print_endpoint_coverage_summary

echo "--- All tests passed! ---"
