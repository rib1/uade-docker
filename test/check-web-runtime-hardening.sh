#!/bin/sh

set -eu

failures=0

pass() {
  echo "PASS: $1"
}

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

# Import the configured cloud path without allowing the storage SDK to load.
if CACHE_URI=gcs://import-test-bucket/cache RATE_LIMIT_DISABLED=1 python3 - <<'PY'
import builtins
from unittest.mock import patch

original_import = builtins.__import__


def guard_cloud_import(name, *args, **kwargs):
    if name == "google.cloud" or name.startswith("google.cloud."):
        raise AssertionError("Server import must not load the cloud storage SDK")
    return original_import(name, *args, **kwargs)


with patch("builtins.__import__", side_effect=guard_cloud_import):
    import server

    assert server.CACHE_URI == "gcs://import-test-bucket/cache"
    assert server.root_cache == "import-test-bucket/cache"
    assert isinstance(server.fs_cache, server.GoogleCacheFilesystem)
    assert server.fs_cache._bucket_name == "import-test-bucket"
    assert not server.fs_cache.initialized
    assert server.CLEANUP_STATUSES["cache"] == "not_run_yet"
PY
then
  pass "configured GCS cache stays uninitialized during server import"
else
  fail "configured GCS cache initialized during server import"
fi

# Keep cloud-client quotas separate and ignore untrusted entries in the header.
if RATE_LIMIT_DISABLED=0 RATE_LIMIT_TRUSTED_PROXY_HOPS=1 python3 - <<'PY'
from unittest.mock import patch

from flask import Flask
from flask_limiter import Limiter

import server

probe = Flask(__name__)
Limiter(server.rate_limit_client_ip, app=probe, default_limits=["1 per minute"], storage_uri="memory://")
probe.add_url_rule("/", view_func=lambda: "ok")

with probe.test_client() as client:
    for forwarded, expected in (
        ("203.0.113.10", 200),
        ("198.51.100.1, 203.0.113.10", 429),
        ("198.51.100.2, 203.0.113.10", 429),
        ("203.0.113.20", 200),
        ("2001:db8::1", 200),
        ("2001:0db8:0:0:0:0:0:1", 429),
        ("::ffff:203.0.113.10", 429),
    ):
        result = client.get("/", headers={"X-Forwarded-For": forwarded})
        assert result.status_code == expected, (forwarded, result.status_code)

for forwarded in (None, "203.0.113.10, invalid", "fe80::1%arbitrary"):
    headers = {"X-Forwarded-For": forwarded} if forwarded else {"X-Real-IP": "203.0.113.10"}
    with server.app.test_request_context("/", headers=headers, environ_base={"REMOTE_ADDR": "192.0.2.1"}):
        assert server.rate_limit_client_ip() == "192.0.2.1", forwarded

with patch.object(server, "RATE_LIMIT_TRUSTED_PROXY_HOPS", 0):
    with server.app.test_request_context(
        "/", headers={"X-Forwarded-For": "203.0.113.10"},
        environ_base={"REMOTE_ADDR": "192.0.2.1"},
    ):
        assert server.rate_limit_client_ip() == "192.0.2.1"
PY
then
  pass "rate limiter separates clients behind a trusted proxy and ignores untrusted addresses"
else
  fail "rate limiter trusted proxy behavior"
fi

# The web image must not run its application or native converter as root.
if [ "$(id -u)" -ne 0 ]; then
  pass "runtime process is non-root"
else
  fail "runtime process is root"
fi

# A runtime image must not expose the host Docker control socket.
if [ ! -e /var/run/docker.sock ]; then
  pass "Docker socket is not present"
else
  fail "Docker socket is present"
fi

# A setuid converter can regain root even when the container starts non-root.
uade_permissions="$(stat -c '%A' /usr/local/bin/uade123 2>/dev/null || true)"
uade_mode="$(stat -c '%a' /usr/local/bin/uade123 2>/dev/null || true)"
case "$uade_permissions" in
  ???s*|???S*)
    fail "uade123 has a setuid bit (mode $uade_mode)"
    ;;
  *)
    pass "uade123 is not setuid (mode ${uade_mode:-unknown})"
    ;;
esac

# Conversion storage is writable; application and system paths are not.
for writable_dir in /tmp/modules /tmp/converted /tmp/cache; do
  mkdir -p "$writable_dir"
  marker="$writable_dir/.runtime-hardening-check"
  if touch "$marker" 2>/dev/null; then
    rm -f "$marker"
    pass "$writable_dir is writable for managed artifacts"
  else
    fail "$writable_dir is not writable for managed artifacts"
  fi
done

for protected_dir in /app /usr/local/bin; do
  marker="$protected_dir/.runtime-hardening-check"
  if touch "$marker" 2>/dev/null; then
    rm -f "$marker"
    fail "$protected_dir is writable by the runtime user"
  else
    pass "$protected_dir is protected from runtime writes"
  fi
done

# Module smoke tests run with no-new-privileges, so the inherited SUID bit
# cannot elevate UADE. This catches format-specific conversion regressions.
if command -v setpriv >/dev/null 2>&1 && [ -d /fixtures/modules ]; then
  for module in space_debris.mod stormlord.ahx mdat.turrican_2_level_0-intro; do
    module_path="/fixtures/modules/$module"
    output_path="/tmp/runtime-hardening-${module}.wav"
    if [ ! -f "$module_path" ]; then
      fail "fixture is missing: $module"
      continue
    fi
    if setpriv --no-new-privs /usr/local/bin/uade123 -t 1 -f "$output_path" "$module_path" \
      >/dev/null 2>&1; then
      pass "${module} converts without privilege elevation"
      rm -f "$output_path"
    else
      fail "${module} requires privilege elevation or does not convert"
    fi
  done
else
  fail "setpriv and module fixtures are required for non-SUID conversion checks"
fi

# Exercise the retired-feature contracts against real conversion tools.
if python3 - <<'PY'
import os
import shutil
import subprocess
import tempfile
import wave
from pathlib import Path
from unittest.mock import patch

with tempfile.TemporaryDirectory(prefix="conversion-contracts-", dir="/tmp") as temporary:
    root = Path(temporary)
    with (
        patch.dict(os.environ, {"TMPDIR": temporary, "CACHE_URI": f"file://{root}/cache"}),
        patch.object(tempfile, "tempdir", None),
    ):
        import server

        with (
            patch.dict(os.environ, {"GIT_COMMIT": "supplied-build-commit"}),
            patch.object(server.subprocess, "run", side_effect=AssertionError("Git invoked")),
        ):
            assert server.get_git_commit() == "supplied-build-commit"
        with patch.dict(os.environ, {}, clear=True):
            with patch.object(
                server.subprocess, "run",
                return_value=subprocess.CompletedProcess([], 0, stdout="local-commit\n"),
            ):
                assert server.get_git_commit() == "local-commit"
            with patch.object(server.subprocess, "run", side_effect=FileNotFoundError):
                assert server.get_git_commit() == "unknown"

        wav = root / "counter.wav"
        with wave.open(str(wav), "wb") as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(16000)
            audio.writeframes(b"\0\0" * 16000)
        with patch.dict(os.environ, {"UADE_TEST_MODE": "0"}):
            assert server.compress_to_flac(wav, root / "production.flac")
            assert not server.FLAC_COMPRESSION_COUNTS
        with patch.dict(os.environ, {"UADE_TEST_MODE": "1"}):
            assert server.compress_to_flac(wav, root / "test.flac")
            assert server.FLAC_COMPRESSION_COUNTS == {"test": 1}

        module = server.MODULES_DIR / "fallback.mod"
        shutil.copyfile("/fixtures/modules/space_debris.mod", module)
        with (
            patch.dict(os.environ, {"UADE_TEST_MODE": "0"}),
            patch.object(server, "compress_to_flac", return_value=False),
        ):
            result = server.process_audio_conversion(module)
        assert result.success, result.error
        assert result.final_file is not None and result.final_file.suffix == ".wav"
        assert result.final_file.is_file()
        response = server.app.test_client().get(
            f"/play/{result.cache_hash}", headers={"Range": "bytes=0-63"}
        )
        assert response.status_code == 206
        assert response.mimetype == "audio/wav"
        assert len(response.data) == 64
        result.final_file.unlink()
        response = server.app.test_client().get(
            f"/play/{result.cache_hash}", headers={"Range": "bytes=0-63"}
        )
        assert response.status_code == 206 and response.mimetype == "audio/wav"
        assert len(response.data) == 64
        assert server.FLAC_COMPRESSION_COUNTS == {"test": 1}
PY
then
  pass "build commit precedence, local Git fallback, test-only counters, and WAV fallback"
else
  fail "conversion cleanup contracts"
fi

if [ "$failures" -ne 0 ]; then
  echo "Runtime hardening checks failed: $failures" >&2
  exit 1
fi

echo "Runtime hardening checks passed"
