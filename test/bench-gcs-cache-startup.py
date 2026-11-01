#!/usr/bin/env python3
"""Benchmark GCS client construction and first read against a remote bucket.

This benchmark performs read-only operations. Run one mode in a fresh process
for each sample so import and client-construction timings are not warmed by a
previous mode.
"""

from __future__ import annotations

import argparse
import os
import time
from urllib.parse import urlparse


def elapsed_ms(started_at: float) -> float:
    return round((time.perf_counter() - started_at) * 1000, 2)


def parse_uri(uri: str) -> tuple[str, str]:
    parsed = urlparse(uri)
    if parsed.scheme != "gcs" or not parsed.netloc:
        raise ValueError("URI must have the form gcs://bucket/prefix")
    return parsed.netloc, parsed.path.lstrip("/")


def benchmark_gcsfs(mode: str, bucket: str, prefix: str, project: str) -> dict[str, object]:
    import_started_at = time.perf_counter()
    import fsspec

    import_ms = elapsed_ms(import_started_at)
    token = os.environ.get("BENCH_GCS_ACCESS_TOKEN")
    kwargs: dict[str, object] = {"project": project}
    if mode == "gcsfs-cloud":
        kwargs["token"] = "cloud"
    elif mode == "gcsfs-raw":
        if not token:
            raise ValueError("BENCH_GCS_ACCESS_TOKEN is required for gcsfs-raw")
        kwargs["token"] = token
    elif mode == "gcsfs-credentials":
        if not token:
            raise ValueError("BENCH_GCS_ACCESS_TOKEN is required for gcsfs-credentials")
        from google.oauth2.credentials import Credentials

        kwargs["token"] = Credentials(token=token)
    else:
        raise ValueError(f"Unsupported GCSFS mode: {mode}")

    constructor_started_at = time.perf_counter()
    filesystem = fsspec.filesystem("gcs", **kwargs)
    constructor_ms = elapsed_ms(constructor_started_at)

    list_started_at = time.perf_counter()
    entries = filesystem.ls(f"{bucket}/{prefix}", detail=True)
    list_ms = elapsed_ms(list_started_at)

    object_name = None
    for entry in entries:
        candidate = entry.get("name") if isinstance(entry, dict) else entry
        entry_type = entry.get("type") if isinstance(entry, dict) else None
        if candidate and entry_type != "directory":
            object_name = str(candidate)
            break

    info_ms = None
    if object_name:
        info_started_at = time.perf_counter()
        filesystem.info(object_name)
        info_ms = elapsed_ms(info_started_at)

    return {
        "mode": mode,
        "import_ms": import_ms,
        "constructor_ms": constructor_ms,
        "first_list_ms": list_ms,
        "first_info_ms": info_ms,
        "entries": len(entries),
    }


def benchmark_native(bucket: str, prefix: str, project: str) -> dict[str, object]:
    import_started_at = time.perf_counter()
    from google.cloud import storage
    from google.oauth2.credentials import Credentials

    import_ms = elapsed_ms(import_started_at)
    token = os.environ.get("BENCH_GCS_ACCESS_TOKEN")
    credentials = Credentials(token=token) if token else None

    constructor_started_at = time.perf_counter()
    client = storage.Client(project=project, credentials=credentials)
    bucket_handle = client.bucket(bucket)
    constructor_ms = elapsed_ms(constructor_started_at)

    list_started_at = time.perf_counter()
    blobs = list(client.list_blobs(bucket_handle, prefix=prefix, max_results=100))
    list_ms = elapsed_ms(list_started_at)

    info_ms = None
    if blobs:
        info_started_at = time.perf_counter()
        blobs[0].reload()
        info_ms = elapsed_ms(info_started_at)

    return {
        "mode": "native-gcs",
        "import_ms": import_ms,
        "constructor_ms": constructor_ms,
        "first_list_ms": list_ms,
        "first_info_ms": info_ms,
        "entries": len(blobs),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("gcsfs-cloud", "gcsfs-raw", "gcsfs-credentials", "native"), required=True)
    parser.add_argument("--uri", default=os.getenv("BENCH_GCS_URI", "gcs://flawless-welder-477616-s8-uade-cache/cache"))
    parser.add_argument("--project", default=os.getenv("BENCH_GCS_PROJECT", "flawless-welder-477616-s8"))
    args = parser.parse_args()

    started_at = time.perf_counter()
    try:
        bucket, prefix = parse_uri(args.uri)
        if args.mode == "native":
            result = benchmark_native(bucket, prefix, args.project)
        else:
            os.environ.setdefault("GCSFS_EXPERIMENTAL_ZB_HNS_SUPPORT", "false")
            result = benchmark_gcsfs(args.mode, bucket, prefix, args.project)
        result["total_ms"] = elapsed_ms(started_at)
        print(result)
        return 0
    except Exception as exc:  # noqa: BLE001 - benchmark reports failures as data
        print({"mode": args.mode, "error": f"{type(exc).__name__}: {exc}"})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
