#!/bin/bash

set -e

# A script to test the uade-web API endpoints.
# This script is intended to be run from a Docker container that has curl and jq installed.

# Define the base URL for the API
BASE_URL="http://uade-web-player:5000"
LOCAL_TEST_SERVER_PORT=8000
LOCAL_TEST_SERVER_URL="http://uade-test-http-server:$LOCAL_TEST_SERVER_PORT"

# Create test fixtures on the fly
mkdir -p fixtures/invalid
touch fixtures/invalid/empty.bin
head -c 11534336 /dev/urandom > fixtures/invalid/too-large.bin

# Download test files to fixtures directory
mkdir -p fixtures/modules
if [ ! -f "fixtures/modules/space_debris.mod" ]; then
    echo "Downloading space_debris.mod..."
    curl -s --insecure -o fixtures/modules/space_debris.mod "https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod"
fi
if [ ! -f "fixtures/modules/gutenberg.txt" ]; then
    echo "Downloading gutenberg.txt..."
    curl -s --insecure -o fixtures/modules/gutenberg.txt "https://www.gutenberg.org/files/1342/1342-0.txt"
fi
if [ ! -f "fixtures/modules/mdat.turrican_2_level_0-intro" ]; then
    echo "Downloading mdat.turrican_2_level_0-intro..."
    curl -s --insecure -o fixtures/modules/mdat.turrican_2_level_0-intro "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.turrican%202%20level%200-intro"
fi
if [ ! -f "fixtures/modules/smpl.turrican_2_level_0-intro" ]; then
    echo "Downloading smpl.turrican_2_level_0-intro..."
    curl -s --insecure -o fixtures/modules/smpl.turrican_2_level_0-intro "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.turrican%202%20level%200-intro"
fi


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

# Function to test a play-example endpoint
# Arguments:
# 1. Test name (string)
# 2. Example ID (string)
test_play_example() {
    TEST_NAME=$1
    EXAMPLE_ID=$2

    echo "--- Testing $TEST_NAME: $EXAMPLE_ID ---"

    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d '{}' \
        "$BASE_URL/play-example/$EXAMPLE_ID")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" -eq 200 ]; then
        echo "SUCCESS: Received HTTP 200"
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

test_probe_oversized_remote_file() {
    TEST_NAME=$1
    URL_BASE=$2
    UNIQUE_ID=$(date +%s%N)
    URL="${URL_BASE}?test_id=${UNIQUE_ID}"

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
    UNIQUE_URL="${BASE_URL_TO_TEST}?test_id=${UNIQUE_ID}"
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

test_external_download_flow_with_oversized_file() {
    TEST_NAME=$1
    URL_BASE=$2
    # Generate a unique URL for this test run to ensure it's a fresh download attempt
    UNIQUE_ID=$(date +%s%N)
    URL="${URL_BASE}?test_id=${UNIQUE_ID}"

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
    REQUIRED_KEYS=("uptime_seconds" "python_version" "os_platform" "memory" "disk" "binaries" "cache" "config" "uade_version" "version" "uade_available")
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

    # Verify binaries check
    UADE_BIN=$(echo "$RESPONSE" | jq -r .binaries.uade123)
    if [ "$UADE_BIN" != "true" ]; then
        echo "ERROR: uade123 binary reported as unavailable"
        exit 1
    fi

    echo "SUCCESS: Health endpoint returned all expected fields and valid data."
    echo ""
}

# Wait for the service to be up
echo "Waiting for uade-web-player to be available..."
while ! curl -s "$BASE_URL/health" > /dev/null; do
    sleep 1
done
echo "Service is up!"

test_health_endpoint

test_probe_url "Probe Protracker module" "https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod"
test_probe_url "Probe TFMX module" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.turrican%202%20level%200-intro" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.turrican%202%20level%200-intro"
test_probe_has_no_conversion_fields "Probe metadata only response" "https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod"
test_probe_error "Probe reject localhost URL" "http://localhost:5000/health" "" 400 "Unsafe or disallowed URL provided"
test_probe_missing_url
test_probe_malformed_json
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

test_play_example "Play Example (Romeo Knight)" "romeo-knight-beat"
test_play_example "Play Example (Turrican 2)" "huelsbeck-turrican2"

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
test_convert_url_malformed_json
test_convert_url_wrong_content_type

# XSS in filename/module name (should not be reflected unsanitized)
test_xss_filename "https://example.com/<script>alert('xss')</script>.mod"

# Note: The FLAC test file must be unique in test cases to avoid being cached as WAV
# and must not be returned by the example modules endpoint (app.route("/examples")) to ensure a fresh conversion.
test_url_with_ua "FLAC compression with Chrome UA"  "https://modland.com/pub/modules/Protracker/Lizardking/l.k%27s%20doskpop.mod" "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0.0.0" "flac"

test_range_request "Range request for large TFMX module" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.turrican%202%20level%200-intro" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.turrican%202%20level%200-intro"

test_security_malformed_range "Reject malformed range" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.turrican%202%20level%200-intro" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.turrican%202%20level%200-intro"

test_download_functionality "Download Protracker module" "https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod"

test_cache_hit_url "Server-side cache hit for convert-url" "https://modland.com/pub/modules/Protracker/Lizardking/l.k%27s%20doskpop.mod"

test_url_cache_logic "URL download cache" "https://modland.com/pub/modules/Protracker/Lizardking/l.k%27s%20doskpop.mod"

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

test_external_download_flow_with_oversized_file "Download file exceeding 10MB limit" "$LOCAL_TEST_SERVER_URL/fixtures/invalid/too-large.bin"

echo "--- All tests passed! ---"
