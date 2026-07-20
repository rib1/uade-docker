#!/usr/bin/env python3
"""Seed local-only ZAP targets that the UI crawl will not discover on its own."""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

BASE_URL = os.environ.get("ZAP_TARGET_URL", "http://uade-web:5000")
LOCAL_TEST_SERVER_URL = os.environ.get(
    "ZAP_LOCAL_TEST_SERVER_URL", "http://uade-test-http-server:8000"
)
FIXTURE_ROOT = Path(os.environ.get("ZAP_FIXTURE_ROOT", "/zap/fixtures"))
HTTP_SERVER_ERROR_MIN = 500
HTTP_TIMEOUT_SECONDS = 20
WAIT_TIMEOUT_SECONDS = 30
ZAP_GUTENBERG_FIXTURE = "gutenberg.txt"
ZAP_SPACE_DEBRIS_FIXTURE = "space_debris.mod"
ZAP_MDAT_FIXTURE = "mdat.turrican_2_level_0-intro"
ZAP_SMPL_FIXTURE = "smpl.turrican_2_level_0-intro"
ZAP_TOO_LARGE_FIXTURE = "too-large.bin"
ZAP_EMPTY_FIXTURE = "empty.bin"


def allowlisted_urlopen(
    request_or_url: urllib.request.Request | str, *, timeout: int
) -> urllib.response.addinfourl:
    """Open only the local app and local test server URLs used by the ZAP seed flow."""
    allowed_prefixes = (
        BASE_URL,
        LOCAL_TEST_SERVER_URL,
        "http://uade-test-http-server:65534",
    )
    full_url = getattr(request_or_url, "full_url", request_or_url)
    if not full_url.startswith(allowed_prefixes):
        raise ValueError(f"Refusing to open non-allowlisted URL: {full_url}")
    return urllib.request.urlopen(  # ruff:ignore[suspicious-url-open-usage]
        request_or_url,
        timeout=timeout,
    )


def wait_for_url(url: str, *, timeout_seconds: int = 30) -> None:
    """Wait until a URL responds successfully."""
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            with allowlisted_urlopen(url, timeout=5) as response:
                if response.status < HTTP_SERVER_ERROR_MIN:
                    return
        except urllib.error.URLError:
            time.sleep(1)
    raise RuntimeError(f"Timed out waiting for {url}")


def request(
    path: str,
    *,
    method: str = "GET",
    body: str | bytes | None = None,
    content_type: str | None = None,
) -> tuple[int, str]:
    """Send an HTTP request and capture status and response body."""
    headers: dict[str, str] = {}
    data = None
    if body is not None:
        data = body.encode("utf-8") if isinstance(body, str) else body
    if content_type is not None:
        headers["Content-Type"] = content_type

    req = urllib.request.Request(  # ruff:ignore[suspicious-url-open-usage]
        f"{BASE_URL}{path}",
        data=data,
        headers=headers,
        method=method,
    )
    try:
        with allowlisted_urlopen(req, timeout=HTTP_TIMEOUT_SECONDS) as response:
            return response.status, response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", errors="replace")


def json_body(payload: dict[str, object]) -> str:
    return json.dumps(payload, separators=(",", ":"))


def multipart_form_data(
    *, field_name: str, filename: str, file_bytes: bytes, content_type: str
) -> tuple[bytes, str]:
    """Build a tiny multipart/form-data body for file upload endpoints."""
    boundary = f"----CodexBoundary{uuid.uuid4().hex}"
    preamble = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="{field_name}"; filename="{filename}"\r\n'
        f"Content-Type: {content_type}\r\n"
        "\r\n"
    ).encode()
    epilogue = (f"\r\n--{boundary}--\r\n").encode()
    body = preamble + file_bytes + epilogue
    return body, f"multipart/form-data; boundary={boundary}"


def seed_case(
    name: str,
    *,
    path: str,
    expected_status: int,
    method: str = "GET",
    body: str | None = None,
    content_type: str | None = None,
) -> None:
    status, response_body = request(
        path,
        method=method,
        body=body,
        content_type=content_type,
    )
    if status != expected_status:
        raise RuntimeError(
            f"{name} returned HTTP {status}, expected {expected_status}. Body: {response_body}"
        )
    print(f"{name}: HTTP {status}")


def seed_probe_upload_case(
    name: str,
    *,
    fixture_path: Path | None = None,
    filename: str = "upload.bin",
    expected_status: int,
) -> None:
    """Seed /probe-upload with either a multipart upload or a no-file POST."""
    if fixture_path is None:
        status, response_body = request("/probe-upload", method="POST")
    else:
        body, content_type = multipart_form_data(
            field_name="file",
            filename=filename,
            file_bytes=fixture_path.read_bytes(),
            content_type="application/octet-stream",
        )
        status, response_body = request(
            "/probe-upload",
            method="POST",
            body=body,
            content_type=content_type,
        )

    if status != expected_status:
        raise RuntimeError(
            f"{name} returned HTTP {status}, expected {expected_status}. Body: {response_body}"
        )
    print(f"{name}: HTTP {status}")


def main() -> None:
    modules_dir = FIXTURE_ROOT / "modules"
    invalid_dir = FIXTURE_ROOT / "invalid"
    wait_for_url(f"{BASE_URL}/health", timeout_seconds=WAIT_TIMEOUT_SECONDS)
    wait_for_url(
        f"{LOCAL_TEST_SERVER_URL}/fixtures/modules/{ZAP_GUTENBERG_FIXTURE}",
        timeout_seconds=WAIT_TIMEOUT_SECONDS,
    )
    seed_case("health", path="/health", expected_status=200)
    seed_case("examples", path="/examples", expected_status=200)
    seed_case("supported-extensions", path="/supported-extensions", expected_status=200)
    seed_case(
        "convert-example-romeo",
        path="/convert-url",
        method="POST",
        body=json.dumps(
            {
                "url": "https://modland.com/pub/modules/SidMon%201/Romeo%20Knight/beat%20to%20the%20pulp.sid",
            }
        ),
        content_type="application/json",
        expected_status=200,
    )
    seed_case(
        "convert-example-turrican2",
        path="/convert-url",
        method="POST",
        body=json.dumps(
            {
                "url": "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.turrican%202%20level%200-intro",
                "sample_url": "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.turrican%202%20level%200-intro",
            }
        ),
        content_type="application/json",
        expected_status=200,
    )

    seed_case(
        "convert-missing-url",
        path="/convert-url",
        method="POST",
        body="{}",
        content_type="application/json",
        expected_status=400,
    )
    seed_case(
        "convert-malformed-json",
        path="/convert-url",
        method="POST",
        body='{"url":',
        content_type="application/json",
        expected_status=400,
    )
    seed_case(
        "probe-missing-url",
        path="/probe-url",
        method="POST",
        body="{}",
        content_type="application/json",
        expected_status=400,
    )
    seed_case(
        "probe-malformed-json",
        path="/probe-url",
        method="POST",
        body='{"url":',
        content_type="application/json",
        expected_status=400,
    )
    seed_probe_upload_case("probe-upload-no-file", expected_status=400)
    seed_probe_upload_case(
        "probe-upload-empty-file",
        fixture_path=invalid_dir / ZAP_EMPTY_FIXTURE,
        filename="empty.bin",
        expected_status=400,
    )
    seed_probe_upload_case(
        "probe-upload-unsupported-file",
        fixture_path=modules_dir / ZAP_GUTENBERG_FIXTURE,
        filename=ZAP_GUTENBERG_FIXTURE,
        expected_status=500,
    )
    seed_case(
        "convert-probed-invalid-body",
        path="/convert-probed",
        method="POST",
        body='{"module_hash":',
        content_type="application/json",
        expected_status=400,
    )
    seed_case(
        "convert-probed-invalid-hash",
        path="/convert-probed",
        method="POST",
        body=json_body({"module_hash": "not-an-md5", "filename": "upload.mod"}),
        content_type="application/json",
        expected_status=400,
    )
    seed_case(
        "convert-probed-missing-module",
        path="/convert-probed",
        method="POST",
        body=json_body(
            {
                "module_hash": "0123456789abcdef0123456789abcdef",
                "filename": "missing.mod",
            }
        ),
        content_type="application/json",
        expected_status=404,
    )

    shared_cases = [
        (
            "fixture-404",
            json_body({"url": f"{LOCAL_TEST_SERVER_URL}/fixtures/missing/not-found.mod"}),
            400,
        ),
        (
            "transport-502",
            json_body(
                {
                    "url": (
                        f"http://uade-test-http-server:65534/fixtures/modules/{ZAP_SPACE_DEBRIS_FIXTURE}"
                    )
                }
            ),
            502,
        ),
        (
            "unsupported-500",
            json_body({"url": f"{LOCAL_TEST_SERVER_URL}/fixtures/modules/{ZAP_GUTENBERG_FIXTURE}"}),
            500,
        ),
        (
            "mutated-module-400",
            json_body(
                {
                    "url": (
                        f"{LOCAL_TEST_SERVER_URL}/fixtures/modules/{ZAP_SPACE_DEBRIS_FIXTURE};get-help"
                    )
                }
            ),
            400,
        ),
        (
            "mutated-sample-400",
            json_body(
                {
                    "url": f"{LOCAL_TEST_SERVER_URL}/fixtures/modules/{ZAP_MDAT_FIXTURE}",
                    "sample_url": (
                        f"{LOCAL_TEST_SERVER_URL}/fixtures/modules/{ZAP_SMPL_FIXTURE};sleep%2015.0;"
                    ),
                }
            ),
            400,
        ),
    ]

    for endpoint in ("convert-url", "probe-url"):
        endpoint_cases = list(shared_cases)
        endpoint_cases.append(
            (
                "oversized-413",
                json_body(
                    {
                        "url": (
                            f"{LOCAL_TEST_SERVER_URL}/fixtures/invalid/{ZAP_TOO_LARGE_FIXTURE}"
                            f"?test_id={endpoint}-{uuid.uuid4().hex}"
                        )
                    }
                ),
                413,
            )
        )
        for suffix, payload, expected_status in endpoint_cases:
            seed_case(
                f"{endpoint}-{suffix}",
                path=f"/{endpoint}",
                method="POST",
                body=payload,
                content_type="application/json",
                expected_status=expected_status,
            )


if __name__ == "__main__":
    main()
