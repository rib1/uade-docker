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
TOO_LARGE_BYTES = 11 * 1024 * 1024
HTTP_SERVER_ERROR_MIN = 500
HTTP_TIMEOUT_SECONDS = 20
WAIT_TIMEOUT_SECONDS = 30


def allowlisted_urlopen(
    request_or_url: urllib.request.Request | str, *, timeout: int
) -> urllib.response.addinfourl:
    """Open only the local app and local test server URLs used by the ZAP seed flow."""
    allowed_prefixes = (
        BASE_URL,
        LOCAL_TEST_SERVER_URL,
        "http://uade-test-http-server:65534",
    )
    full_url = (
        request_or_url.full_url
        if isinstance(request_or_url, urllib.request.Request)
        else request_or_url
    )
    if not full_url.startswith(allowed_prefixes):
        raise ValueError(f"Refusing to open non-allowlisted URL: {full_url}")
    return urllib.request.urlopen(request_or_url, timeout=timeout)  # noqa: S310


def ensure_local_fixtures() -> None:
    """Create deterministic local fixtures for the shared test HTTP server."""
    modules_dir = FIXTURE_ROOT / "modules"
    invalid_dir = FIXTURE_ROOT / "invalid"
    modules_dir.mkdir(parents=True, exist_ok=True)
    invalid_dir.mkdir(parents=True, exist_ok=True)

    (modules_dir / "gutenberg.txt").write_text(
        "This is plain text, not an Amiga module.\n",
        encoding="utf-8",
    )
    (modules_dir / "space_debris.mod").write_bytes(b"placeholder module bytes\n")
    (modules_dir / "mdat.turrican_2_level_0-intro").write_bytes(b"placeholder mdat bytes\n")
    (modules_dir / "smpl.turrican_2_level_0-intro").write_bytes(b"placeholder smpl bytes\n")

    too_large_file = invalid_dir / "too-large.bin"
    if not too_large_file.exists() or too_large_file.stat().st_size != TOO_LARGE_BYTES:
        too_large_file.write_bytes(b"0" * TOO_LARGE_BYTES)


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
    body: str | None = None,
    content_type: str | None = None,
) -> tuple[int, str]:
    """Send an HTTP request and capture status and response body."""
    headers: dict[str, str] = {}
    data = None
    if body is not None:
        data = body.encode("utf-8")
    if content_type is not None:
        headers["Content-Type"] = content_type

    req = urllib.request.Request(  # noqa: S310
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


def main() -> None:
    ensure_local_fixtures()
    wait_for_url(f"{BASE_URL}/health", timeout_seconds=WAIT_TIMEOUT_SECONDS)
    wait_for_url(
        f"{LOCAL_TEST_SERVER_URL}/fixtures/modules/gutenberg.txt",
        timeout_seconds=WAIT_TIMEOUT_SECONDS,
    )
    seed_case("health", path="/health", expected_status=200)
    seed_case("examples", path="/examples", expected_status=200)
    seed_case("supported-extensions", path="/supported-extensions", expected_status=200)
    seed_case(
        "play-example-romeo",
        path="/play-example/romeo-knight-beat",
        method="POST",
        body="{}",
        content_type="application/json",
        expected_status=200,
    )
    seed_case(
        "play-example-turrican2",
        path="/play-example/huelsbeck-turrican2",
        method="POST",
        body="{}",
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

    shared_cases = [
        (
            "fixture-404",
            json_body({"url": f"{LOCAL_TEST_SERVER_URL}/fixtures/missing/not-found.mod"}),
            400,
        ),
        (
            "transport-502",
            json_body(
                {"url": ("http://uade-test-http-server:65534/fixtures/modules/space_debris.mod")}
            ),
            502,
        ),
        (
            "unsupported-500",
            json_body({"url": f"{LOCAL_TEST_SERVER_URL}/fixtures/modules/gutenberg.txt"}),
            500,
        ),
        (
            "mutated-module-400",
            json_body(
                {"url": (f"{LOCAL_TEST_SERVER_URL}/fixtures/modules/space_debris.mod;get-help")}
            ),
            400,
        ),
        (
            "mutated-sample-400",
            json_body(
                {
                    "url": (
                        f"{LOCAL_TEST_SERVER_URL}/fixtures/modules/mdat.turrican_2_level_0-intro"
                    ),
                    "sample_url": (
                        f"{LOCAL_TEST_SERVER_URL}/fixtures/modules/"
                        "smpl.turrican_2_level_0-intro;sleep%2015.0;"
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
                            f"{LOCAL_TEST_SERVER_URL}/fixtures/invalid/too-large.bin"
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
