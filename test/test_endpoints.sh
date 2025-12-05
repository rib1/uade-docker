#!/bin/bash

set -e

# A script to test the uade-web API endpoints.
# This script is intended to be run from a Docker container that has curl and jq installed.

# Define the base URL for the API
BASE_URL="http://uade-web-player:5000"

# Create test fixtures on the fly
mkdir -p fixtures/invalid
touch fixtures/invalid/empty.bin
head -c 11534336 /dev/urandom > fixtures/invalid/too-large.bin


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

    if [ -z "$SAMPLE_URL" ]; then
        JSON_PAYLOAD=$(jq -n --arg url "$URL" '{url: $url}')
    else
        JSON_PAYLOAD=$(jq -n --arg url "$URL" --arg sample_url "$SAMPLE_URL" '{url: $url, sample_url: $sample_url}')
    fi

    # First, convert a module to get a file_id
    RESPONSE_ALL=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "$JSON_PAYLOAD" \
        "$BASE_URL/convert-url")

    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    RESPONSE=$(echo "$RESPONSE_ALL" | sed '$d')

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

test_url_with_ua() {
    TEST_NAME=$1
    URL=$2
    USER_AGENT=$3
    EXPECTED_AUDIO_FORMAT=$4

    echo "--- Testing User-Agent FLAC: $TEST_NAME ---"

    # Capture HTTP_CODE and RESPONSE from _perform_convert_url_call
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

    if [ "$DOWNLOAD_HTTP_CODE" -eq 200 ]; then
        echo "SUCCESS: Download URL returned HTTP 200."
    else
        echo "ERROR: Download URL returned unexpected HTTP $DOWNLOAD_HTTP_CODE (expected 200) for test '$TEST_NAME'"
        exit 1
    fi
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

    if [ -z "$SAMPLE_URL" ]; then
        JSON_PAYLOAD=$(jq -n --arg url "$URL" '{url: $url}')
    else
        JSON_PAYLOAD=$(jq -n --arg url "$URL" --arg sample_url "$SAMPLE_URL" '{url: $url, sample_url: $sample_url}')
    fi

    # First call (should convert and cache)
    RESPONSE1=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$JSON_PAYLOAD" \
        "$BASE_URL/convert-url")

    # Second call (should hit cache)
    RESPONSE2=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$JSON_PAYLOAD" \
        "$BASE_URL/convert-url")

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

# Wait for the service to be up
echo "Waiting for uade-web-player to be available..."
while ! curl -s "$BASE_URL/health" > /dev/null; do
    sleep 1
done
echo "Service is up!"

test_url "Protracker module" "https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod"
test_url "AHX module" "https://modland.com/pub/modules/AHX/Pink/stormlord.ahx"
test_url "TFMX module" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.turrican%202%20level%200-intro" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.turrican%202%20level%200-intro"
test_url "TFMX module (Apidya)" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.apidya%20%28level%201%29" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.apidya%20%28level%201%29"
test_url "LHA archive" "http://files.exotica.org.uk/?file=exotica/media%2Faudio%2FUnExoticA%2FGame%2FBrimble_Allister%2FProject-X.lha"
test_url "ZIP archive" "https://files.scene.org/get:fi-https/music/artists/4-mat/chip_shop.zip"
test_url "RJP module" "https://modland.com/pub/modules/Richard%20Joseph/Richard%20Joseph/cannon%20fodder%20(intro).sng" "https://modland.com/pub/modules/Richard%20Joseph/Richard%20Joseph/cannon%20fodder%20(intro).ins"
test_url "Negative case (non-module)" "https://www.gutenberg.org/files/1342/1342-0.txt"

test_play_example "Play Example (Romeo Knight)" "romeo-knight-beat"
test_play_example "Play Example (Turrican 2)" "huelsbeck-turrican2"

# Security tests
test_security_url "Reject localhost URL" "http://localhost:5000/health"
test_security_url "Reject private IP URL" "http://192.168.1.1/internal"
test_security_url "Reject URL with command injection attempt" "https://example.com/file%60%20rm%20-rf%20/%60"
test_security_url "Reject URL with newlines" "https://example.com/file%0a%0ainjected"
test_security_url "Reject dual-file module with unsafe sample_url" "https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod" "http://192.168.1.1/internal"
test_security_url "Reject TFMX modules sample_url with newlines" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.apidya%20%28level%201%29" "https://example.com/file%0a%0ainjected"
test_security_url "Reject RJP modules unsafe url when sample_url is safe" "https://example.com/file%60%20rm%20-rf%20/%60" "https://modland.com/pub/modules/Richard%20Joseph/Richard%20Joseph/cannon%20fodder%20(intro).ins"
test_security_url "Reject convert-url with no URL" "$BASE_URL/convert-url" "{}"

# Note: The FLAC test file must be unique in test cases to avoid being cached as WAV
# and must not be returned by the example modules endpoint (app.route("/examples")) to ensure a fresh conversion.
test_url_with_ua "FLAC compression with Chrome UA"  "https://modland.com/pub/modules/Protracker/Lizardking/l.k%27s%20doskpop.mod" "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0.0.0" "flac"

test_range_request "Range request for large TFMX module" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.turrican%202%20level%200-intro" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.turrican%202%20level%200-intro"

test_security_malformed_range "Reject malformed range" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.turrican%202%20level%200-intro" "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.turrican%202%20level%200-intro"

test_download_functionality "Download Protracker module" "https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod"

test_cache_hit_url "Server-side cache hit for convert-url" "https://modland.com/pub/modules/Protracker/Lizardking/l.k%27s%20doskpop.mod"

test_upload_error "Reject empty file upload" "fixtures/invalid/empty.bin" 400
test_upload_error "Reject oversized file upload" "fixtures/invalid/too-large.bin" 413

echo "--- All tests passed! ---"
