#!/bin/bash

set -u
set -o pipefail

BASE_URL_A="http://uade-web-a:5000"
BASE_URL_B="http://uade-web-b:5000"
LOCAL_TEST_SERVER_URL="http://uade-test-http-server:8000"

PASS_COUNT=0
FAIL_COUNT=0
FAILURES=""

record_success() {
    TEST_NAME=$1
    echo "PASS: $TEST_NAME"
    PASS_COUNT=$((PASS_COUNT + 1))
    echo ""
}

record_failure() {
    TEST_NAME=$1
    DETAILS=$2
    echo "FAIL: $TEST_NAME"
    echo "$DETAILS"
    echo ""
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES="${FAILURES}- ${TEST_NAME}: ${DETAILS}
"
}

wait_for_service() {
    NAME=$1
    URL=$2

    echo "--- Waiting for ${NAME} (${URL}) ---"
    retries=60
    while ! curl -fsS "${URL}/health" > /dev/null; do
        retries=$((retries - 1))
        if [ "$retries" -le 0 ]; then
            record_failure "bootstrap:${NAME}" "service did not become healthy"
            return 1
        fi
        sleep 2
    done
    echo "Service is healthy: ${NAME}"
    echo ""
    return 0
}

prepare_fixtures() {
    mkdir -p fixtures/modules

    if [ ! -f "fixtures/modules/space_debris.mod" ]; then
        echo "Downloading space_debris.mod fixture..."
        curl -fsS --insecure -o fixtures/modules/space_debris.mod \
            "https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod"
    fi
}

json_post() {
    BASE_URL=$1
    PATH_SUFFIX=$2
    PAYLOAD=$3

    curl -sS -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "${BASE_URL}${PATH_SUFFIX}"
}

upload_probe() {
    BASE_URL=$1
    FILE_PATH=$2

    curl -sS -w "\n%{http_code}" -X POST \
        -F "file=@${FILE_PATH}" \
        "${BASE_URL}/probe-upload"
}

probe_url() {
    BASE_URL=$1
    TARGET_URL=$2
    SAMPLE_URL=${3:-}

    if [ -z "$SAMPLE_URL" ]; then
        PAYLOAD=$(jq -nc --arg url "$TARGET_URL" '{url: $url}')
    else
        PAYLOAD=$(jq -nc --arg url "$TARGET_URL" --arg sample_url "$SAMPLE_URL" '{url: $url, sample_url: $sample_url}')
    fi

    curl -sS -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "${BASE_URL}/probe-url"
}

fetch_http_code() {
    URL=$1
    curl -sS -o /dev/null -w "%{http_code}" "$URL"
}

fetch_body_and_code_get() {
    URL=$1
    curl -sS -w "\n%{http_code}" "$URL"
}

assert_instance_local_absence() {
    PATH_TO_CHECK=$1
    if [ -e "$PATH_TO_CHECK" ]; then
        return 1
    fi
    return 0
}

test_convert_on_a_play_on_b() {
    TEST_NAME="convert-url on A -> play on B"
    URL="${LOCAL_TEST_SERVER_URL}/fixtures/modules/space_debris.mod?case=convert-a-play-b"

    RESPONSE_ALL=$(json_post "$BASE_URL_A" "/convert-url" "$(jq -nc --arg url "$URL" '{url: $url}')")
    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 200 ]; then
        record_failure "$TEST_NAME" "convert-url on A returned HTTP ${HTTP_CODE}; body=${BODY}"
        return
    fi

    FILE_ID=$(echo "$BODY" | jq -r .file_id)
    if [ -z "$FILE_ID" ] || [ "$FILE_ID" = "null" ]; then
        record_failure "$TEST_NAME" "A response missing file_id; body=${BODY}"
        return
    fi

    PLAY_HTTP_CODE=$(fetch_http_code "${BASE_URL_B}/play/${FILE_ID}")
    if [ "$PLAY_HTTP_CODE" != "200" ] && [ "$PLAY_HTTP_CODE" != "206" ]; then
        record_failure "$TEST_NAME" "play on B returned HTTP ${PLAY_HTTP_CODE} for file_id=${FILE_ID}"
        return
    fi

    if ! ls "/instance-b/converted/${FILE_ID}".* > /dev/null 2>&1; then
        record_failure "$TEST_NAME" "play on B succeeded but did not materialize a local converted artifact from shared cache"
        return
    fi

    record_success "$TEST_NAME"
}

test_convert_on_a_download_on_b() {
    # covers: /download/<file_id>
    TEST_NAME="convert-url on A -> download on B"
    URL="${LOCAL_TEST_SERVER_URL}/fixtures/modules/space_debris.mod?case=convert-a-download-b"

    RESPONSE_ALL=$(json_post "$BASE_URL_A" "/convert-url" "$(jq -nc --arg url "$URL" '{url: $url}')")
    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 200 ]; then
        record_failure "$TEST_NAME" "convert-url on A returned HTTP ${HTTP_CODE}; body=${BODY}"
        return
    fi

    FILE_ID=$(echo "$BODY" | jq -r .file_id)
    DOWNLOAD_URL=$(echo "$BODY" | jq -r .download_url)
    if [ -z "$FILE_ID" ] || [ "$FILE_ID" = "null" ] || [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
        record_failure "$TEST_NAME" "A response missing file_id or download_url; body=${BODY}"
        return
    fi

    DOWNLOAD_CODE=$(fetch_http_code "${BASE_URL_B}${DOWNLOAD_URL}")
    if [ "$DOWNLOAD_CODE" != "200" ] && [ "$DOWNLOAD_CODE" != "206" ]; then
        record_failure "$TEST_NAME" "download on B returned HTTP ${DOWNLOAD_CODE} for file_id=${FILE_ID}"
        return
    fi

    if ! ls "/instance-b/converted/${FILE_ID}".* > /dev/null 2>&1; then
        record_failure "$TEST_NAME" "download on B succeeded but did not materialize a local converted artifact from shared cache"
        return
    fi

    record_success "$TEST_NAME"
}

test_convert_probed_invalid_hash_on_b() {
    TEST_NAME="convert-probed invalid hash on B"

    RESPONSE_ALL=$(json_post "$BASE_URL_B" "/convert-probed" \
        '{"module_hash":"not-a-valid-hash","filename":"test.mod"}')
    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 400 ]; then
        record_failure "$TEST_NAME" "expected HTTP 400, got ${HTTP_CODE}; body=${BODY}"
        return
    fi

    if ! echo "$BODY" | grep -q "Invalid module hash"; then
        record_failure "$TEST_NAME" "unexpected error body for invalid hash; body=${BODY}"
        return
    fi

    record_success "$TEST_NAME"
}

test_probe_url_on_a_and_b() {
    TEST_NAME="probe-url returns playable metadata on A and B"
    URL="${LOCAL_TEST_SERVER_URL}/fixtures/modules/space_debris.mod?case=probe-url-a-b"

    PROBE_A_ALL=$(probe_url "$BASE_URL_A" "$URL")
    PROBE_A_CODE=$(echo "$PROBE_A_ALL" | tail -n1)
    PROBE_A_BODY=$(echo "$PROBE_A_ALL" | sed '$d')

    if [ "$PROBE_A_CODE" -ne 200 ]; then
        record_failure "$TEST_NAME" "probe-url on A returned HTTP ${PROBE_A_CODE}; body=${PROBE_A_BODY}"
        return
    fi

    PROBE_B_ALL=$(probe_url "$BASE_URL_B" "$URL")
    PROBE_B_CODE=$(echo "$PROBE_B_ALL" | tail -n1)
    PROBE_B_BODY=$(echo "$PROBE_B_ALL" | sed '$d')

    if [ "$PROBE_B_CODE" -ne 200 ]; then
        record_failure "$TEST_NAME" "probe-url on B returned HTTP ${PROBE_B_CODE}; body=${PROBE_B_BODY}"
        return
    fi

    OK_A=$(echo "$PROBE_A_BODY" | jq -r .ok)
    PLAYABLE_A=$(echo "$PROBE_A_BODY" | jq -r .playable)
    OK_B=$(echo "$PROBE_B_BODY" | jq -r .ok)
    PLAYABLE_B=$(echo "$PROBE_B_BODY" | jq -r .playable)
    MODULE_NAME_A=$(echo "$PROBE_A_BODY" | jq -r .module_name)
    MODULE_NAME_B=$(echo "$PROBE_B_BODY" | jq -r .module_name)

    if [ "$OK_A" != "true" ] || [ "$PLAYABLE_A" != "true" ] || [ "$OK_B" != "true" ] || [ "$PLAYABLE_B" != "true" ]; then
        record_failure "$TEST_NAME" "probe-url did not report ok/playable on both instances; body_a=${PROBE_A_BODY}; body_b=${PROBE_B_BODY}"
        return
    fi

    if [ -z "$MODULE_NAME_A" ] || [ "$MODULE_NAME_A" = "null" ] || [ "$MODULE_NAME_A" != "$MODULE_NAME_B" ]; then
        record_failure "$TEST_NAME" "probe-url module_name mismatch across instances; body_a=${PROBE_A_BODY}; body_b=${PROBE_B_BODY}"
        return
    fi

    record_success "$TEST_NAME"
}

test_probe_url_on_a_convert_on_b_play_on_a() {
    TEST_NAME="probe-url on A -> convert-url on B -> play on A"
    URL="${LOCAL_TEST_SERVER_URL}/fixtures/modules/space_debris.mod?case=probe-a-convert-b-play-a"

    PROBE_ALL=$(probe_url "$BASE_URL_A" "$URL")
    PROBE_CODE=$(echo "$PROBE_ALL" | tail -n1)
    PROBE_BODY=$(echo "$PROBE_ALL" | sed '$d')

    if [ "$PROBE_CODE" -ne 200 ]; then
        record_failure "$TEST_NAME" "probe-url on A returned HTTP ${PROBE_CODE}; body=${PROBE_BODY}"
        return
    fi

    CONVERT_ALL=$(json_post "$BASE_URL_B" "/convert-url" "$(jq -nc --arg url "$URL" '{url: $url}')")
    CONVERT_CODE=$(echo "$CONVERT_ALL" | tail -n1)
    CONVERT_BODY=$(echo "$CONVERT_ALL" | sed '$d')

    if [ "$CONVERT_CODE" -ne 200 ]; then
        record_failure "$TEST_NAME" "convert-url on B returned HTTP ${CONVERT_CODE}; body=${CONVERT_BODY}"
        return
    fi

    FILE_ID=$(echo "$CONVERT_BODY" | jq -r .file_id)
    if [ -z "$FILE_ID" ] || [ "$FILE_ID" = "null" ]; then
        record_failure "$TEST_NAME" "convert-url on B response missing file_id; body=${CONVERT_BODY}"
        return
    fi

    PLAY_CODE=$(fetch_http_code "${BASE_URL_A}/play/${FILE_ID}")
    if [ "$PLAY_CODE" != "200" ] && [ "$PLAY_CODE" != "206" ]; then
        record_failure "$TEST_NAME" "play on A returned HTTP ${PLAY_CODE} for file_id=${FILE_ID}"
        return
    fi

    record_success "$TEST_NAME"
}

test_probe_url_negative_on_a_and_b() {
    TEST_NAME="probe-url negative case is stable on A and B"
    URL="${LOCAL_TEST_SERVER_URL}/fixtures/missing/not-found.mod"

    PROBE_A_ALL=$(probe_url "$BASE_URL_A" "$URL")
    PROBE_A_CODE=$(echo "$PROBE_A_ALL" | tail -n1)
    PROBE_A_BODY=$(echo "$PROBE_A_ALL" | sed '$d')

    PROBE_B_ALL=$(probe_url "$BASE_URL_B" "$URL")
    PROBE_B_CODE=$(echo "$PROBE_B_ALL" | tail -n1)
    PROBE_B_BODY=$(echo "$PROBE_B_ALL" | sed '$d')

    if [ "$PROBE_A_CODE" -ne 400 ] || [ "$PROBE_B_CODE" -ne 400 ]; then
        record_failure "$TEST_NAME" "expected HTTP 400 on both instances, got ${PROBE_A_CODE} and ${PROBE_B_CODE}; body_a=${PROBE_A_BODY}; body_b=${PROBE_B_BODY}"
        return
    fi

    if ! echo "$PROBE_A_BODY" | grep -q "External module URL could not be fetched" || \
       ! echo "$PROBE_B_BODY" | grep -q "External module URL could not be fetched"; then
        record_failure "$TEST_NAME" "unexpected probe-url negative body; body_a=${PROBE_A_BODY}; body_b=${PROBE_B_BODY}"
        return
    fi

    record_success "$TEST_NAME"
}

test_convert_probed_empty_body_on_b() {
    TEST_NAME="convert-probed empty JSON body on B"

    RESPONSE_ALL=$(curl -sS -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        "$BASE_URL_B/convert-probed")
    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 400 ]; then
        record_failure "$TEST_NAME" "expected HTTP 400, got ${HTTP_CODE}; body=${BODY}"
        return
    fi

    if ! echo "$BODY" | grep -q "Invalid request body"; then
        record_failure "$TEST_NAME" "unexpected error body for empty request; body=${BODY}"
        return
    fi

    record_success "$TEST_NAME"
}

test_convert_probed_wrong_method_on_b() {
    TEST_NAME="convert-probed GET rejected on B"

    HTTP_CODE=$(fetch_http_code "${BASE_URL_B}/convert-probed")
    if [ "$HTTP_CODE" -ne 405 ]; then
        record_failure "$TEST_NAME" "expected HTTP 405, got ${HTTP_CODE}"
        return
    fi

    record_success "$TEST_NAME"
}

test_play_invalid_file_id_on_b() {
    TEST_NAME="play invalid file_id rejected on B"

    RESPONSE_ALL=$(fetch_body_and_code_get "${BASE_URL_B}/play/../../etc/passwd")
    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 404 ] && [ "$HTTP_CODE" -ne 400 ]; then
        record_failure "$TEST_NAME" "expected HTTP 400 or 404, got ${HTTP_CODE}; body=${BODY}"
        return
    fi

    record_success "$TEST_NAME"
}

test_play_unknown_file_id_on_b() {
    TEST_NAME="play unknown file_id on B returns 404"

    RESPONSE_ALL=$(fetch_body_and_code_get "${BASE_URL_B}/play/doesnotexist123")
    HTTP_CODE=$(echo "$RESPONSE_ALL" | tail -n1)
    BODY=$(echo "$RESPONSE_ALL" | sed '$d')

    if [ "$HTTP_CODE" -ne 404 ]; then
        record_failure "$TEST_NAME" "expected HTTP 404, got ${HTTP_CODE}; body=${BODY}"
        return
    fi

    if ! echo "$BODY" | grep -q "File not found or forbidden"; then
        record_failure "$TEST_NAME" "unexpected body for unknown file_id; body=${BODY}"
        return
    fi

    record_success "$TEST_NAME"
}

test_probe_on_a_convert_on_b_expected_gap() {
    TEST_NAME="probe-upload on A -> convert-probed on B requires fallback"

    PROBE_ALL=$(upload_probe "$BASE_URL_A" "fixtures/modules/space_debris.mod")
    PROBE_CODE=$(echo "$PROBE_ALL" | tail -n1)
    PROBE_BODY=$(echo "$PROBE_ALL" | sed '$d')

    if [ "$PROBE_CODE" -ne 200 ]; then
        record_failure "$TEST_NAME" "probe-upload on A returned HTTP ${PROBE_CODE}; body=${PROBE_BODY}"
        return
    fi

    MODULE_HASH=$(echo "$PROBE_BODY" | jq -r .module_hash)
    if [ -z "$MODULE_HASH" ] || [ "$MODULE_HASH" = "null" ]; then
        record_failure "$TEST_NAME" "probe response missing module_hash; body=${PROBE_BODY}"
        return
    fi

    if ! assert_instance_local_absence "/instance-b/modules/probed_${MODULE_HASH}"; then
        record_failure "$TEST_NAME" "B unexpectedly already had probed module file before convert-probed"
        return
    fi

    CONVERT_ALL=$(json_post "$BASE_URL_B" "/convert-probed" \
        "$(jq -nc --arg module_hash "$MODULE_HASH" --arg filename "space_debris.mod" '{module_hash: $module_hash, filename: $filename}')")
    CONVERT_CODE=$(echo "$CONVERT_ALL" | tail -n1)
    CONVERT_BODY=$(echo "$CONVERT_ALL" | sed '$d')

    if [ "$CONVERT_CODE" -eq 404 ] && echo "$CONVERT_BODY" | grep -q "Module not found"; then
        record_success "$TEST_NAME"
        return
    fi

    if [ "$CONVERT_CODE" -eq 200 ]; then
        record_failure "$TEST_NAME" "unexpected HTTP 200 from convert-probed on B; body=${CONVERT_BODY}"
        return
    fi

    record_failure "$TEST_NAME" "expected HTTP 404 fallback trigger from convert-probed on B, got HTTP ${CONVERT_CODE}; body=${CONVERT_BODY}"
}

test_queue_hop_probe_convert_play() {
    TEST_NAME="queue hop A probe -> B convert-probed 404 -> A upload/play fallback"

    PROBE_ALL=$(upload_probe "$BASE_URL_A" "fixtures/modules/space_debris.mod")
    PROBE_CODE=$(echo "$PROBE_ALL" | tail -n1)
    PROBE_BODY=$(echo "$PROBE_ALL" | sed '$d')

    if [ "$PROBE_CODE" -ne 200 ]; then
        record_failure "$TEST_NAME" "probe-upload on A returned HTTP ${PROBE_CODE}; body=${PROBE_BODY}"
        return
    fi

    MODULE_HASH=$(echo "$PROBE_BODY" | jq -r .module_hash)
    CONVERT_ALL=$(json_post "$BASE_URL_B" "/convert-probed" \
        "$(jq -nc --arg module_hash "$MODULE_HASH" --arg filename "space_debris.mod" '{module_hash: $module_hash, filename: $filename}')")
    CONVERT_CODE=$(echo "$CONVERT_ALL" | tail -n1)
    CONVERT_BODY=$(echo "$CONVERT_ALL" | sed '$d')

    if [ "$CONVERT_CODE" -eq 404 ] && echo "$CONVERT_BODY" | grep -q "Module not found"; then
        UPLOAD_ALL=$(curl -sS -w "\n%{http_code}" -X POST \
            -F "file=@fixtures/modules/space_debris.mod" \
            "${BASE_URL_A}/upload")
        UPLOAD_CODE=$(echo "$UPLOAD_ALL" | tail -n1)
        UPLOAD_BODY=$(echo "$UPLOAD_ALL" | sed '$d')

        if [ "$UPLOAD_CODE" -ne 200 ]; then
            record_failure "$TEST_NAME" "upload fallback on A returned HTTP ${UPLOAD_CODE}; body=${UPLOAD_BODY}"
            return
        fi

        FILE_ID=$(echo "$UPLOAD_BODY" | jq -r .file_id)
    elif [ "$CONVERT_CODE" -eq 200 ]; then
        record_failure "$TEST_NAME" "unexpected HTTP 200 from convert-probed on B; body=${CONVERT_BODY}"
        return
    else
        record_failure "$TEST_NAME" "expected convert-probed on B to return HTTP 404 fallback trigger, got HTTP ${CONVERT_CODE}; body=${CONVERT_BODY}"
        return
    fi

    PLAY_HTTP_CODE=$(fetch_http_code "${BASE_URL_A}/play/${FILE_ID}")
    if [ "$PLAY_HTTP_CODE" != "200" ] && [ "$PLAY_HTTP_CODE" != "206" ]; then
        record_failure "$TEST_NAME" "play on A returned HTTP ${PLAY_HTTP_CODE} for file_id=${FILE_ID}"
        return
    fi

    record_success "$TEST_NAME"
}

test_convert_url_cache_hit_across_instances() {
    TEST_NAME="convert-url on A -> convert-url on B shared-cache hit"
    URL="${LOCAL_TEST_SERVER_URL}/fixtures/modules/space_debris.mod?case=cache-hit-cross-instance"

    FIRST_ALL=$(json_post "$BASE_URL_A" "/convert-url" "$(jq -nc --arg url "$URL" '{url: $url}')")
    FIRST_CODE=$(echo "$FIRST_ALL" | tail -n1)
    FIRST_BODY=$(echo "$FIRST_ALL" | sed '$d')

    if [ "$FIRST_CODE" -ne 200 ]; then
        record_failure "$TEST_NAME" "first convert-url on A returned HTTP ${FIRST_CODE}; body=${FIRST_BODY}"
        return
    fi

    SECOND_ALL=$(json_post "$BASE_URL_B" "/convert-url" "$(jq -nc --arg url "$URL" '{url: $url}')")
    SECOND_CODE=$(echo "$SECOND_ALL" | tail -n1)
    SECOND_BODY=$(echo "$SECOND_ALL" | sed '$d')

    if [ "$SECOND_CODE" -ne 200 ]; then
        record_failure "$TEST_NAME" "second convert-url on B returned HTTP ${SECOND_CODE}; body=${SECOND_BODY}"
        return
    fi

    CACHED=$(echo "$SECOND_BODY" | jq -r .cached)
    if [ "$CACHED" != "true" ]; then
        record_failure "$TEST_NAME" "second convert-url on B did not report cached=true; body=${SECOND_BODY}"
        return
    fi

    record_success "$TEST_NAME"
}

test_duplicate_convert_on_other_instance_returns_processing() {
    TEST_NAME="duplicate convert on B returns 409 processing while A owns the cold convert"
    URL="${LOCAL_TEST_SERVER_URL}/fixtures/modules/mdat.turrican_2_level_0-intro?case=duplicate-processing-cross-instance"
    SAMPLE_URL="${LOCAL_TEST_SERVER_URL}/fixtures/modules/smpl.turrican_2_level_0-intro?case=duplicate-processing-cross-instance"
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' RETURN

    # Warm once to learn the stable file_id for this fixture content, then remove
    # the shared artifact so the next convert is genuinely cold and slow enough
    # to exercise the duplicate-convert contract across instances.
    WARM_ALL=$(json_post "$BASE_URL_A" "/convert-url" \
        "$(jq -nc --arg url "$URL" --arg sample_url "$SAMPLE_URL" '{url: $url, sample_url: $sample_url}')")
    WARM_CODE=$(echo "$WARM_ALL" | tail -n1)
    WARM_BODY=$(echo "$WARM_ALL" | sed '$d')

    if [ "$WARM_CODE" -ne 200 ]; then
        record_failure "$TEST_NAME" "warm-up convert-url on A returned HTTP ${WARM_CODE}; body=${WARM_BODY}"
        return
    fi

    FILE_ID=$(echo "$WARM_BODY" | jq -r .file_id)
    AUDIO_FORMAT=$(echo "$WARM_BODY" | jq -r .audio_format)
    if [ -z "$FILE_ID" ] || [ "$FILE_ID" = "null" ] || [ -z "$AUDIO_FORMAT" ] || [ "$AUDIO_FORMAT" = "null" ]; then
        record_failure "$TEST_NAME" "warm-up response missing file_id or audio_format; body=${WARM_BODY}"
        return
    fi

    for BASE_URL in "$BASE_URL_A" "$BASE_URL_B"; do
        REMOVE_ALL=$(json_post "$BASE_URL" "/test/remove-cache-artifact" \
            "$(jq -nc --arg file_id "$FILE_ID" --arg ext ".${AUDIO_FORMAT}" '{file_id: $file_id, ext: $ext}')")
        REMOVE_CODE=$(echo "$REMOVE_ALL" | tail -n1)
        REMOVE_BODY=$(echo "$REMOVE_ALL" | sed '$d')

        if [ "$REMOVE_CODE" -ne 200 ]; then
            record_failure "$TEST_NAME" "remove-cache-artifact on ${BASE_URL} returned HTTP ${REMOVE_CODE}; body=${REMOVE_BODY}"
            return
        fi
    done

    (
        json_post "$BASE_URL_A" "/convert-url" \
            "$(jq -nc --arg url "$URL" --arg sample_url "$SAMPLE_URL" '{url: $url, sample_url: $sample_url}')" \
            > "${TMP_DIR}/owner-a.txt"
    ) &
    OWNER_PID=$!

    FOLLOWER_ALL=$(json_post "$BASE_URL_B" "/convert-url" \
        "$(jq -nc --arg url "$URL" --arg sample_url "$SAMPLE_URL" '{url: $url, sample_url: $sample_url}')")
    FOLLOWER_CODE=$(echo "$FOLLOWER_ALL" | tail -n1)
    FOLLOWER_BODY=$(echo "$FOLLOWER_ALL" | sed '$d')

    wait "$OWNER_PID"
    OWNER_ALL=$(cat "${TMP_DIR}/owner-a.txt")
    OWNER_CODE=$(echo "$OWNER_ALL" | tail -n1)
    OWNER_BODY=$(echo "$OWNER_ALL" | sed '$d')

    if [ "$OWNER_CODE" -ne 200 ]; then
        record_failure "$TEST_NAME" "owner convert-url on A returned HTTP ${OWNER_CODE}; body=${OWNER_BODY}"
        return
    fi

    if [ "$FOLLOWER_CODE" -ne 200 ] && [ "$FOLLOWER_CODE" -ne 409 ]; then
        record_failure "$TEST_NAME" "expected HTTP 200 or 409 on B, got ${FOLLOWER_CODE}; body=${FOLLOWER_BODY}"
        return
    fi

    if [ "$FOLLOWER_CODE" -eq 409 ]; then
        FOLLOWER_STATUS=$(echo "$FOLLOWER_BODY" | jq -r .status)
        FOLLOWER_RETRYABLE=$(echo "$FOLLOWER_BODY" | jq -r .retryable)

        if [ "$FOLLOWER_STATUS" != "processing" ] || [ "$FOLLOWER_RETRYABLE" != "true" ]; then
            record_failure "$TEST_NAME" "follower convert-url on B did not return processing contract; body=${FOLLOWER_BODY}"
            return
        fi
    fi

    record_success "$TEST_NAME"
}

test_convert_probed_after_remote_cache_removal_same_instance() {
    TEST_NAME="convert-probed on A recovers after remote cache removal"

    PROBE_ALL=$(upload_probe "$BASE_URL_A" "fixtures/modules/space_debris.mod")
    PROBE_CODE=$(echo "$PROBE_ALL" | tail -n1)
    PROBE_BODY=$(echo "$PROBE_ALL" | sed '$d')

    if [ "$PROBE_CODE" -ne 200 ]; then
        record_failure "$TEST_NAME" "probe-upload on A returned HTTP ${PROBE_CODE}; body=${PROBE_BODY}"
        return
    fi

    MODULE_HASH=$(echo "$PROBE_BODY" | jq -r .module_hash)
    FIRST_CONVERT_ALL=$(json_post "$BASE_URL_A" "/convert-probed" \
        "$(jq -nc --arg module_hash "$MODULE_HASH" --arg filename "space_debris.mod" '{module_hash: $module_hash, filename: $filename}')")
    FIRST_CONVERT_CODE=$(echo "$FIRST_CONVERT_ALL" | tail -n1)
    FIRST_CONVERT_BODY=$(echo "$FIRST_CONVERT_ALL" | sed '$d')

    if [ "$FIRST_CONVERT_CODE" -ne 200 ]; then
        record_failure "$TEST_NAME" "first convert-probed on A returned HTTP ${FIRST_CONVERT_CODE}; body=${FIRST_CONVERT_BODY}"
        return
    fi

    FILE_ID=$(echo "$FIRST_CONVERT_BODY" | jq -r .file_id)
    AUDIO_FORMAT=$(echo "$FIRST_CONVERT_BODY" | jq -r .audio_format)
    REMOVE_ALL=$(json_post "$BASE_URL_A" "/test/remove-cache-artifact" \
        "$(jq -nc --arg file_id "$FILE_ID" --arg ext ".${AUDIO_FORMAT}" '{file_id: $file_id, ext: $ext}')")
    REMOVE_CODE=$(echo "$REMOVE_ALL" | tail -n1)
    REMOVE_BODY=$(echo "$REMOVE_ALL" | sed '$d')

    if [ "$REMOVE_CODE" -ne 200 ]; then
        record_failure "$TEST_NAME" "remove-cache-artifact on A returned HTTP ${REMOVE_CODE}; body=${REMOVE_BODY}"
        return
    fi

    SECOND_CONVERT_ALL=$(json_post "$BASE_URL_A" "/convert-probed" \
        "$(jq -nc --arg module_hash "$MODULE_HASH" --arg filename "space_debris.mod" '{module_hash: $module_hash, filename: $filename}')")
    SECOND_CONVERT_CODE=$(echo "$SECOND_CONVERT_ALL" | tail -n1)
    SECOND_CONVERT_BODY=$(echo "$SECOND_CONVERT_ALL" | sed '$d')

    if [ "$SECOND_CONVERT_CODE" -ne 200 ]; then
        record_failure "$TEST_NAME" "second convert-probed on A returned HTTP ${SECOND_CONVERT_CODE}; body=${SECOND_CONVERT_BODY}"
        return
    fi

    record_success "$TEST_NAME"
}

test_cross_instance_play_after_remote_cache_removal_still_serves() {
    TEST_NAME="play on B still serves after A removes one shared cache artifact"
    URL="${LOCAL_TEST_SERVER_URL}/fixtures/modules/space_debris.mod?case=remote-removal-cross-play"

    CONVERT_ALL=$(json_post "$BASE_URL_A" "/convert-url" "$(jq -nc --arg url "$URL" '{url: $url}')")
    CONVERT_CODE=$(echo "$CONVERT_ALL" | tail -n1)
    CONVERT_BODY=$(echo "$CONVERT_ALL" | sed '$d')

    if [ "$CONVERT_CODE" -ne 200 ]; then
        record_failure "$TEST_NAME" "convert-url on A returned HTTP ${CONVERT_CODE}; body=${CONVERT_BODY}"
        return
    fi

    FILE_ID=$(echo "$CONVERT_BODY" | jq -r .file_id)
    AUDIO_FORMAT=$(echo "$CONVERT_BODY" | jq -r .audio_format)

    # Warm B's local copy first so this test exercises the "B already
    # materialized a local artifact, then A removes its local copy and the
    # shared remote artifact" path.
    INITIAL_PLAY_CODE=$(fetch_http_code "${BASE_URL_B}/play/${FILE_ID}")
    if [ "$INITIAL_PLAY_CODE" != "200" ] && [ "$INITIAL_PLAY_CODE" != "206" ]; then
        record_failure "$TEST_NAME" "initial play on B returned HTTP ${INITIAL_PLAY_CODE} for file_id=${FILE_ID}"
        return
    fi

    if ! ls "/instance-b/converted/${FILE_ID}".* > /dev/null 2>&1; then
        record_failure "$TEST_NAME" "initial play on B did not materialize a local converted artifact before removal"
        return
    fi

    REMOVE_ALL=$(json_post "$BASE_URL_A" "/test/remove-cache-artifact" \
        "$(jq -nc --arg file_id "$FILE_ID" --arg ext ".${AUDIO_FORMAT}" '{file_id: $file_id, ext: $ext}')")
    REMOVE_CODE=$(echo "$REMOVE_ALL" | tail -n1)
    REMOVE_BODY=$(echo "$REMOVE_ALL" | sed '$d')

    if [ "$REMOVE_CODE" -ne 200 ]; then
        record_failure "$TEST_NAME" "remove-cache-artifact on A returned HTTP ${REMOVE_CODE}; body=${REMOVE_BODY}"
        return
    fi

    PLAY_CODE=$(fetch_http_code "${BASE_URL_B}/play/${FILE_ID}")
    if [ "$PLAY_CODE" != "200" ] && [ "$PLAY_CODE" != "206" ]; then
        record_failure "$TEST_NAME" "expected HTTP 200 or 206 on B after single-artifact removal, got ${PLAY_CODE}"
        return
    fi

    record_success "$TEST_NAME"
}

test_shared_cache_access_sidecar_across_instances() {
    TEST_NAME="shared cache sidecar refresh across A and B"
    URL="${LOCAL_TEST_SERVER_URL}/fixtures/modules/space_debris.mod?case=sidecar-cross-instance"

    FIRST_ALL=$(json_post "$BASE_URL_A" "/convert-url" "$(jq -nc --arg url "$URL" '{url: $url}')")
    FIRST_CODE=$(echo "$FIRST_ALL" | tail -n1)
    FIRST_BODY=$(echo "$FIRST_ALL" | sed '$d')

    if [ "$FIRST_CODE" -ne 200 ]; then
        record_failure "$TEST_NAME" "initial convert-url on A returned HTTP ${FIRST_CODE}; body=${FIRST_BODY}"
        return
    fi

    FILE_ID=$(echo "$FIRST_BODY" | jq -r .file_id)
    ACCESS_RECORD="/uade-cache-shared/${FILE_ID}.cache-access.json"

    if [ ! -f "$ACCESS_RECORD" ]; then
        record_failure "$TEST_NAME" "shared cache access record not found at ${ACCESS_RECORD}"
        return
    fi

    BEFORE_TS=$(stat -c %Y "$ACCESS_RECORD")
    sleep 2

    SECOND_ALL=$(json_post "$BASE_URL_B" "/convert-url" "$(jq -nc --arg url "$URL" '{url: $url}')")
    SECOND_CODE=$(echo "$SECOND_ALL" | tail -n1)
    SECOND_BODY=$(echo "$SECOND_ALL" | sed '$d')

    if [ "$SECOND_CODE" -ne 200 ]; then
        record_failure "$TEST_NAME" "cache-hit convert-url on B returned HTTP ${SECOND_CODE}; body=${SECOND_BODY}"
        return
    fi

    AFTER_TS=$(stat -c %Y "$ACCESS_RECORD")
    if [ "$AFTER_TS" -le "$BEFORE_TS" ]; then
        record_failure "$TEST_NAME" "shared cache access record timestamp did not advance after B cache hit"
        return
    fi

    record_success "$TEST_NAME"
}

test_cleanup_state_is_per_instance() {
    TEST_NAME="cleanup health state is not shared between instances"

    HEALTH_A_BEFORE=$(curl -fsS "${BASE_URL_A}/health")
    HEALTH_B_BEFORE=$(curl -fsS "${BASE_URL_B}/health")
    TS_A_BEFORE=$(echo "$HEALTH_A_BEFORE" | jq -r .cache.last_cleanup_at)
    TS_B_BEFORE=$(echo "$HEALTH_B_BEFORE" | jq -r .cache.last_cleanup_at)

    sleep 1

    CLEANUP_ALL=$(json_post "$BASE_URL_A" "/test/run-cleanup" '{"scope":"cache"}')
    CLEANUP_CODE=$(echo "$CLEANUP_ALL" | tail -n1)
    CLEANUP_BODY=$(echo "$CLEANUP_ALL" | sed '$d')

    if [ "$CLEANUP_CODE" -ne 200 ]; then
        record_failure "$TEST_NAME" "cleanup trigger on A returned HTTP ${CLEANUP_CODE}; body=${CLEANUP_BODY}"
        return
    fi

    HEALTH_A=$(curl -fsS "${BASE_URL_A}/health")
    HEALTH_B=$(curl -fsS "${BASE_URL_B}/health")
    TS_A=$(echo "$HEALTH_A" | jq -r .cache.last_cleanup_at)
    TS_B=$(echo "$HEALTH_B" | jq -r .cache.last_cleanup_at)

    if [ "$TS_A" = "null" ]; then
        record_failure "$TEST_NAME" "A health did not record cleanup timestamp after cleanup run"
        return
    fi

    if [ "$TS_A_BEFORE" = "$TS_A" ]; then
        record_failure "$TEST_NAME" "A cleanup timestamp did not advance after explicit cleanup"
        return
    fi

    if [ "$TS_B_BEFORE" != "$TS_B" ]; then
        record_failure "$TEST_NAME" "B cleanup timestamp changed even though cleanup was only triggered on A (${TS_B_BEFORE} -> ${TS_B})"
        return
    fi

    record_success "$TEST_NAME"
}

test_parallel_convert_url_both_instances() {
    TEST_NAME="parallel convert-url from A and B to one shared cache entry"
    URL="${LOCAL_TEST_SERVER_URL}/fixtures/modules/space_debris.mod?case=parallel-cross-instance"
    TMP_DIR=$(mktemp -d)

    (
        json_post "$BASE_URL_A" "/convert-url" "$(jq -nc --arg url "$URL" '{url: $url}')" > "${TMP_DIR}/a.txt"
    ) &
    PID_A=$!

    (
        json_post "$BASE_URL_B" "/convert-url" "$(jq -nc --arg url "$URL" '{url: $url}')" > "${TMP_DIR}/b.txt"
    ) &
    PID_B=$!

    wait "$PID_A"
    wait "$PID_B"

    BODY_A=$(sed '$d' "${TMP_DIR}/a.txt")
    BODY_B=$(sed '$d' "${TMP_DIR}/b.txt")
    CODE_A=$(tail -n1 "${TMP_DIR}/a.txt")
    CODE_B=$(tail -n1 "${TMP_DIR}/b.txt")
    rm -rf "$TMP_DIR"

    if [ "$CODE_A" -ne 200 ] || [ "$CODE_B" -ne 200 ]; then
        record_failure "$TEST_NAME" "parallel calls returned HTTP ${CODE_A} and ${CODE_B}; body_a=${BODY_A}; body_b=${BODY_B}"
        return
    fi

    FILE_ID_A=$(echo "$BODY_A" | jq -r .file_id)
    FILE_ID_B=$(echo "$BODY_B" | jq -r .file_id)
    if [ "$FILE_ID_A" != "$FILE_ID_B" ]; then
        record_failure "$TEST_NAME" "parallel calls produced different file_ids (${FILE_ID_A} vs ${FILE_ID_B})"
        return
    fi

    TMP_COUNT=$(find /uade-cache-shared -maxdepth 1 -name "${FILE_ID_A}.cache-access.json.*.tmp" | wc -l)
    if [ "$TMP_COUNT" -ne 0 ]; then
        record_failure "$TEST_NAME" "found ${TMP_COUNT} orphaned shared-cache sidecar temp files for ${FILE_ID_A}"
        return
    fi

    record_success "$TEST_NAME"
}

print_summary_and_exit() {
    python3 ./report_endpoint_coverage.py test_multiinstance.sh
    echo ""
    echo "--- Multi-instance Summary ---"
    echo "Passed: ${PASS_COUNT}"
    echo "Failed: ${FAIL_COUNT}"
    if [ "$FAIL_COUNT" -gt 0 ]; then
        echo ""
        echo "Failed cases:"
        printf "%s" "$FAILURES"
        exit 1
    fi
    exit 0
}

wait_for_service "uade-web-a" "$BASE_URL_A" || print_summary_and_exit
wait_for_service "uade-web-b" "$BASE_URL_B" || print_summary_and_exit
prepare_fixtures

test_convert_on_a_play_on_b
test_convert_on_a_download_on_b
test_probe_url_on_a_and_b
test_probe_url_on_a_convert_on_b_play_on_a
test_probe_url_negative_on_a_and_b
test_convert_probed_invalid_hash_on_b
test_convert_probed_empty_body_on_b
test_convert_probed_wrong_method_on_b
test_play_invalid_file_id_on_b
test_play_unknown_file_id_on_b
test_probe_on_a_convert_on_b_expected_gap
test_queue_hop_probe_convert_play
test_convert_probed_after_remote_cache_removal_same_instance
test_convert_url_cache_hit_across_instances
test_duplicate_convert_on_other_instance_returns_processing
test_cross_instance_play_after_remote_cache_removal_still_serves
test_shared_cache_access_sidecar_across_instances
test_cleanup_state_is_per_instance
test_parallel_convert_url_both_instances

print_summary_and_exit
