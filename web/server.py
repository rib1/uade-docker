#!/usr/bin/env python3
"""
UADE Web Player - Flask Server

Converts Amiga music modules to FLAC or WAV for browser playback
Cloud-ready with proper logging, error handling, stateless caching, and cleanup
"""

import hashlib
import ipaddress
import json
import logging
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.parse
import uuid
import zipfile
from datetime import UTC, datetime
from pathlib import Path
from typing import Final

import fsspec
import requests
from flask import Flask, Response, jsonify, request, send_from_directory
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
from werkzeug.utils import secure_filename

# Configure logging for cloud environments
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

app = Flask(__name__, static_folder="static")
START_TIME: Final = time.time()
CLEANUP_TIMESTAMPS: dict[str, datetime | None] = {"local": None, "cache": None}
CLEANUP_STATUSES: dict[str, str] = {"local": "not_run_yet", "cache": "not_run_yet"}
UADE_VERSION_TOKEN_PARTS_MIN: Final = 2
MEMINFO_LINE_PARTS_EXPECTED: Final = 2
LHA_HEADER_MIN_BYTES: Final = 7
ASCII_PRINTABLE_MIN: Final = 0x20
ASCII_PRINTABLE_MAX: Final = 0x7E
SANITIZED_URL_LOG_MAX_LEN: Final = 200
CACHE_ACCESS_RECORD_SUFFIX: Final = ".cache-access.json"
ENOENT_ERRNO: Final = 2
GIT_BIN: Final = "/usr/bin/git"
UADE123_BIN: Final = "/usr/local/bin/uade123"
FLAC_BIN: Final = "/usr/bin/flac"
LHA_BIN: Final = "/usr/bin/lha"
SH_BIN: Final = "/bin/sh"


# Get git commit hash for version tracking
def get_git_commit():
    """Get current git commit hash"""
    try:
        # Trusted fixed binary path and static args; falls back to env var if git is unavailable.
        result = subprocess.run(  # noqa: S603
            [GIT_BIN, "rev-parse", "--short", "HEAD"],
            capture_output=True,
            text=True,
            check=False,
            timeout=2,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        # Ignore errors (e.g., not a git repo, git not installed); fallback to env var
        logger.info(
            "Could not get git commit via command line, using environment variable fallback"
        )
    return os.getenv("GIT_COMMIT", "unknown")


def get_uade_version():
    """Get UADE version from the uade123 binary"""
    try:
        # Trusted fixed binary path and static args.
        result = subprocess.run(  # noqa: S603
            [UADE123_BIN, "--version"],
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )
        # Parse version from output like "uade123 3.05"
        if result.returncode == 0:
            output = result.stdout.strip()
            # Try to extract version number
            for line in output.split("\n"):
                if "uade123" in line.lower():
                    parts = line.split()
                    if len(parts) >= UADE_VERSION_TOKEN_PARTS_MIN:
                        return parts[1]  # e.g., "3.05"
            return output.split()[0] if output else "unknown"
        return "unknown"
    except Exception:
        return "unknown"


def get_image_build_time():
    """Get image build timestamp recorded in the built image."""
    image_build_time = os.getenv("IMAGE_BUILD_TIME")
    if image_build_time and image_build_time != "unknown":
        return image_build_time

    image_build_time_file = Path("/opt/uade-web/image-build-time")
    try:
        value = image_build_time_file.read_text(encoding="utf-8").strip()
        if value:
            return value
    except OSError:
        logger.warning("Could not read image build timestamp file", exc_info=True)

    return "unknown"


def get_memory_usage():
    """Get system memory usage from /proc/meminfo (Linux only)"""
    try:
        if platform.system() != "Linux":
            return None
        with Path("/proc/meminfo").open() as f:
            lines = f.readlines()
        mem_info = {}
        for line in lines:
            parts = line.split(":")
            if len(parts) == MEMINFO_LINE_PARTS_EXPECTED:
                name = parts[0].strip()
                # Extract value and convert to KB
                value_parts = parts[1].strip().split()
                if value_parts:
                    mem_info[name] = int(value_parts[0])

        total = mem_info.get("MemTotal", 0)
        available = mem_info.get("MemAvailable", 0)
        if total > 0:
            used = total - available
            return {
                "total_mb": round(total / 1024, 2),
                "available_mb": round(available / 1024, 2),
                "percent_used": round((used / total) * 100, 1),
            }
    except Exception:
        logger.warning("Could not get memory usage", exc_info=True)
    return None


def get_disk_usage(path):
    """Get disk usage for a specific path"""
    try:
        usage = shutil.disk_usage(path)
        return {
            "total_gb": round(usage.total / (1024**3), 2),
            "used_gb": round(usage.used / (1024**3), 2),
            "free_gb": round(usage.free / (1024**3), 2),
            "percent_used": round((usage.used / usage.total) * 100, 1),
        }
    except Exception:
        logger.warning(f"Could not get disk usage for {path}", exc_info=True)
    return None


GIT_COMMIT: Final = get_git_commit()
IMAGE_BUILD_TIME: Final = get_image_build_time()
UADE_VERSION: Final = get_uade_version()

# Configuration from environment variables (cloud-ready)
MAX_UPLOAD_SIZE: Final = int(os.getenv("MAX_UPLOAD_SIZE", "10485760"))  # 10MB
app.config["MAX_CONTENT_LENGTH"] = MAX_UPLOAD_SIZE
MAX_DOWNLOAD_SIZE: Final = int(os.getenv("MAX_DOWNLOAD_SIZE", "10485760"))  # 10MB
app.config["MAX_DOWNLOAD_SIZE"] = MAX_DOWNLOAD_SIZE
CLEANUP_INTERVAL: Final = int(os.getenv("CLEANUP_INTERVAL", "3600"))  # 1 hour
CACHE_CLEANUP_INTERVAL: Final = int(os.getenv("CACHE_CLEANUP_INTERVAL", "86400"))  # 24 hours
RATE_LIMIT: Final = int(os.getenv("RATE_LIMIT", "200"))  # requests per hour
DOWNLOAD_RATE_LIMIT: Final = int(os.getenv("DOWNLOAD_RATE_LIMIT", "6"))  # downloads per minute
PORT: Final = int(os.getenv("PORT", "5000"))
DISABLE_SSL_VERIFY: Final = os.getenv("DISABLE_SSL_VERIFY", "0") == "1"  # For corporate proxies
HTTP_CLIENT_ERROR_MIN: Final = 400
HTTP_SERVER_ERROR_MIN: Final = 500
HTTP_BAD_GATEWAY: Final = 502

# Local directories for processing
TEMP_BASE: Final = tempfile.gettempdir()
MODULES_DIR: Final = Path(TEMP_BASE) / "modules"
CONVERTED_DIR: Final = Path(TEMP_BASE) / "converted"

# Ensure local directories exist
for directory in [MODULES_DIR, CONVERTED_DIR]:
    directory.mkdir(parents=True, exist_ok=True)


def get_fs_and_root(uri, fs_kwargs=None):
    fs_kwargs = fs_kwargs or {}
    # Detect S3 URI for remote storage support
    if uri.startswith("s3://"):
        fs = fsspec.filesystem("s3", **fs_kwargs)
        root = uri[5:]
    elif uri.startswith("gcs://"):
        fs = fsspec.filesystem("gcs", **fs_kwargs)
        root = uri[6:]
    else:
        fs = fsspec.filesystem("file")
        root = uri
    return fs, root


# Remote cache configuration (set your bucket URL here)
# Expected values for CACHE_URI:
#   - "file" or "file:///path/to/cache" for local filesystem
#   - "s3://bucket/path" for AWS S3
#   - "gcs://bucket/path" for Google Cloud Storage
CACHE_URI: Final = os.getenv("CACHE_URI", f"file://{TEMP_BASE}/cache")
fs_cache, root_cache = get_fs_and_root(CACHE_URI)
CACHE_ACCESS_UPDATE_INTERVAL_SECONDS: Final = int(
    os.getenv("CACHE_ACCESS_UPDATE_INTERVAL_SECONDS", "300")
)
HEALTH_INCLUDE_CACHE_DEBUG: Final = os.getenv("HEALTH_INCLUDE_CACHE_DEBUG", "0") == "1"

# Ensure remote cache directory exists (if using local filesystem)
if fs_cache.protocol == "file":
    Path(root_cache).mkdir(parents=True, exist_ok=True)

# Rate limiting, disabled if RATE_LIMIT_DISABLED is set to "1"
rate_limit_enabled = os.getenv("RATE_LIMIT_DISABLED", "0") != "1"
limiter: Final = Limiter(
    get_remote_address,
    app=app,
    storage_uri="memory://",  # NOTE: Rate limits are per-instance/pod only.
    # Not global across all instances unless using a distributed backend (e.g. Redis).
    # An instance/pod wide rate limit of requests per hour for all endpoints
    default_limits={f"{RATE_LIMIT}/hour"},
    enabled=rate_limit_enabled,
)

if not rate_limit_enabled:
    logger.info("Rate limiting is disabled via RATE_LIMIT_DISABLED env variable")


@app.errorhandler(429)
def ratelimit_handler(_e):
    return json_response(
        {"error": "Rate limit exceeded. Please wait and try again.", "code": 429}, 429
    )


@app.after_request
def add_security_headers(response):
    """Add security headers to all responses."""
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "SAMEORIGIN"
    # A more complete CSP.
    response.headers["Content-Security-Policy"] = (
        "default-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'"
    )
    return response


# Common Amiga module extensions and prefixes for detection module files in archives
MODULE_FILE_EXTENSIONS: Final = {
    "aam",  # Art And Magic
    "abk",  # AMOS Music Bank
    "ac1d",  # AC1D-DC1A Packer
    "adsc",  # Audio Sculpture
    "agi",  # Sierra AGI
    "ahx",  # Abyss' Highest eXperience
    "alp",  # Alcatraz Packer
    "amc",  # A.M.Composer 1.2
    "aon",  # Art Of Noise
    "aon8",  # Art Of Noise 8 voices
    "ash",  # Ashley Hogg
    "ast",  # Actionamics Sound Tool
    "bd",  # Benn Daglish
    "bds",  # Benn Daglish SID
    "bp",  # BP SoundMon 2.x
    "bp3",  # BP SoundMon 3
    "bsi",  # Future Composer BSI
    "bss",  # Beathoven Synthesizer
    "bye",  # Andrew Parton
    "chan",  # Channel Players
    "cin",  # Cinemaware
    "cm",  # CustomMade
    "core",  # Core Design
    "cust",  # Custom module, including player routines
    "dbm",  # DIGI Booster 2.x and 3.x
    "dh",  # David Hanney
    "di",  # Digital Illusions aka GrapeTracker
    "digi",  # DIGI Booster 1.x
    "dl",  # Dave Lowe
    "dll",  # Digital Mugician successor of SidMon
    "dln",  # Dave Lowe New
    "dm",  # Delta Music
    "dm2",  # Delta Music 2
    "dmu",  # Digital Mugician
    "dp",  # Delta Packer
    "dsc",  # Digital Sonix & Chrome
    "dsr",  # Desire
    "dw",  # David Whittaker
    "dz",  # Darius Zendeh Mod
    "ems",  # Editeur Musical Sequentiel
    "ex",  # Fashion Tracker
    "fc",  # Future Composer 1.0 - 1.3
    "fc13",  # Future Composer 1.3
    "fc14",  # Future Composer 1.4
    "fp",  # Future Player
    "fred",  # Fred Gray (Editor)
    "fw",  # FWMP
    "gmc",  # Game Music Creator
    "gray",  # FredMon
    "hd",  # Howie Davies
    "hip",  # Hippel
    "hip7",  # Hippel 7V
    "hipc",  # Hippel COSO
    "hvl",  # Hively Tracker
    "ims",  # Images
    "instr",
    "jam",  # JamCracker
    "jcb",  # Jason Brooke
    "jd",  # Special FX
    "jmf",  # Janko Mrsic-Flogel
    "jo",  # Jesper Olsen
    "jpn",  # Jason Page
    "jpo",  # Steve Turner
    "jt",  # Jeroen Tel
    "kh",  # Kris Hatlelid
    "lme",  # Leggless Music Editor
    "mc",  # Mark Cooksey
    "mcmd",
    "md",  # Mike Davies
    "med",  # OctaMED
    "mfp",  # Magnetic Fields Packer
    "mii",  # Mark II Sound-System
    "mmd0",  # OctaMED MMD0
    "mmd1",  # OctaMED MMD1
    "mmd2",  # OctaMED MMD2
    "mmd3",  # OctaMED MMD3
    "mmdc",  # OctaMED MMDC
    "mod",  # NoiseTracker, Protracker, StarTrekker and derivatives
    "mok",  # Silmarils
    "mon",  # M.O.N Old / New
    "mug",  # Digital Mugician
    "mug2",  # Mugician II
    "mus",  # Sidplayer / Stereo Sidplayer
    "mw",  # Martin Walker
    "mxtx",  # MaxTrax
    "np2",  # NoisePacker 2.x
    "np3",  # NoisePacker 3.x
    "ntp",  # NovoTrade Packer
    "okt",  # Oktalyzer
    "okta",  # Oktalyzer
    "osp",  # Synth Pack
    "p4x",  # The Player 4.x
    "p60",  # The Player 6.x
    "pap",  # Pierre Adane Packer
    "pha",  # Pha Packer
    "pp21",  # ProPacker 2.1
    "pp30",  # ProPacker 3.0
    "pr1",  # Promizer
    "pru2",  # Prorunner 2.0
    "prun",  # Prorunner 1.0
    "ps",  # Paul Shields
    "psa",  # Professional Sound Artists
    "psf",  # Soundfactory
    "puma",  # PumaTracker
    "pvp",  # Peter Verswyvelen Packer
    "rh",  # Rob Hubbard
    "rho",  # Rob Hubbard Old
    "rk",  # Ron Klaren
    "sa",  # Sonic Arranger
    "sb",  # Steve Barrett
    "sc",  # SoundControl
    "scn",  # Sean Connolly
    "scr",  # Sean Conran
    "sct",  # Soundcontrol
    "scumm",  # SCUMM
    "sdr",  # Synth Dream
    "sfx",  # SoundFX
    "sid",  # SidMon 1
    "sid2",  # SidMon 2
    "sm",  # Sound Master
    "smod",  # Future Composer 1.0 - 1.3
    "smus",
    "sng",  # Synder SNG-Player
    "snk",  # Paul Summers
    "snx",  # Sonix Music Driver
    "sonic",  # Sonic Arranger
    "spl",  # Sound Programming Language
    "ss",  # Speedy System
    "ssd",  # Paul Robotham
    "st26",  # SoundTracker 2.6
    "sun",  # SunTronic
    "syn",  # Synthesis / Synder SNG-Player
    "tb3",  # Trackerpacker 3
    "tf",  # Follin Player II
    "tfm",  # TFMX
    "tfmx",  # TFMX
    "tfx",  # TFMX
    "thx",  # original name for the AHX
    "tme",  # The Musical Enlightenment
    "tw",  # Sound Images
    "vss",  # Voodoo Supreme Synthesizer
    "wb",  # Wally Beben
    "ym",
}

DUAL_FILE_MODULES: Final = [
    {"pattern_data": "dns", "sample_data": "smp"},  # Dynamic Synthesizer
    {"pattern_data": "dum", "sample_data": "ins"},  # Infogrames
    {"pattern_data": "han", "sample_data": "smp"},  # Digital Sound Creations
    {"pattern_data": "mdat", "sample_data": "smpl"},  # TFMX (V7, Pro)
    {"pattern_data": "rjp", "sample_data": "smp"},  # Richard Joseph Player
    {"pattern_data": "sjs", "sample_data": "smp"},  # SoundPlayer
    {"pattern_data": "sng", "sample_data": "ins"},  # Richard Joseph Player / etc.
    {"pattern_data": "th", "sample_data": "smp"},  # Thomas Hermann
    {"pattern_data": "tpu", "sample_data": "smp"},  # Dirk Bialluch
    {"pattern_data": "uds", "sample_data": "smp"},  # Unique Development Sweden
]

# Combined set of extensions and prefixes for finding playable music modules within archives.
# This excludes archive formats (lha, zip) and explicitly excludes sample data extensions
# (smpl, smp, ins) to avoid incorrectly identifying them as primary music modules.
PLAYABLE_MODULE_EXTENSIONS: Final = MODULE_FILE_EXTENSIONS | {
    entry["pattern_data"] for entry in DUAL_FILE_MODULES
}

# Example modules - keeping it simple with proven working examples
EXAMPLES: Final = [
    {
        "id": "captain-space-debris",
        "name": "Captain - Space Debris",
        "format": "Protracker",
        "duration": "5:06",
        "url": "https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod",
        "type": "mod",
    },
    {
        "id": "lizardking-doskpop",
        "name": "Lizardking - Doskpop",
        "format": "Protracker",
        "duration": "2:26",
        "url": "https://modland.com/pub/modules/Protracker/Lizardking/l.k%27s%20doskpop.mod",
        "type": "mod",
    },
    {
        "id": "pink-stormlord",
        "name": "Pink - Stormlord",
        "format": "AHX",
        "duration": "8:31 (12KB!)",
        "url": "https://modland.com/pub/modules/AHX/Pink/stormlord.ahx",
        "type": "ahx",
    },
    {
        "id": "huelsbeck-turrican2",
        "name": "Chris Huelsbeck - Turrican 2",
        "format": "TFMX",
        "duration": "12 min (Level 0 Intro)",
        "url": "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.turrican%202%20level%200-intro",
        "sample_url": "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.turrican%202%20level%200-intro",
        "type": "tfmx",
    },
    {
        "id": "moby-late-nite",
        "name": "Moby - Late Nite",
        "format": "Oktalyzer",
        "duration": "6:27",
        "url": "https://modland.com/pub/modules/Oktalyzer/Moby/late%20nite.okta",
        "type": "okta",
    },
    {
        "id": "romeo-knight-beat",
        "name": "Romeo Knight - Beat to the Pulp",
        "format": "SidMon 1",
        "duration": "2:41",
        "url": "https://modland.com/pub/modules/SidMon%201/Romeo%20Knight/beat%20to%20the%20pulp.sid",
        "type": "sid",
    },
    {
        "id": "wings-of-death-levels",
        "name": "Jochen Hippel - Wings of Death",
        "format": "Hippel-COSO",
        "duration": "23 min (Levels 1-7)",
        "url": "https://zakalwe.fi/uade/amiga-music/customs/WingsOfDeath-Levels1-7/cust.WingsOfDeath-Levels1-7",
        "type": "hipc",
    },
    {
        "id": "led-storm",
        "name": "Tim Follin - LED Storm",
        "format": "Custom (LHA)",
        "duration": "38 min (7 tracks)",
        "url": (
            "https://files.exotica.org.uk/?file=exotica/media/audio/UnExoticA/Game/Follin_Tim/L_E_D_Storm.lha"
        ),
        "type": "cust",
    },
    {
        "id": "hoffman-way-too-rude",
        "name": "Hoffman - Way Too Rude",
        "format": "Protracker",
        "duration": "4:17",
        "url": "https://api.modarchive.org/downloads.php?moduleid=188875#way_too_rude.mod",
        "type": "mod",
    },
]


def json_response(data, status=200):
    """
    Wrap jsonify to enforce charset=utf-8 in the Content-Type header.

    Args:
        data: The data to be returned as JSON.
        status (int, optional): HTTP status code for the response. Defaults to 200.
    """
    response = jsonify(data)
    response.headers.extend({"Content-Type": "application/json; charset=utf-8"})
    response.status_code = status
    return response


def cleanup_old_files():
    """
    Remove files older than CLEANUP_INTERVAL from local directories.
    This function is designed to be thread-safe.
    """
    try:
        cutoff = time.time() - CLEANUP_INTERVAL
        removed = 0
        for directory in [MODULES_DIR, CONVERTED_DIR]:
            for filepath in directory.glob("*"):
                try:
                    # Use lstat to avoid following symlinks and get info about the link itself
                    if filepath.lstat().st_mtime < cutoff:
                        filepath.unlink(missing_ok=True)
                        logger.info(f"Cleaned up old file/symlink: {filepath}")
                        removed += 1
                except FileNotFoundError:
                    # File was deleted by another process/thread after glob and before lstat/unlink
                    logger.info(
                        f"File not found during cleanup (likely race condition): {filepath}"
                    )
                    continue
        if removed == 0:
            logger.info("No old files to clean up in local directories.")
    except Exception:
        logger.error("Cleanup error", exc_info=True)
        CLEANUP_STATUSES["local"] = "cleanup_error"
    else:
        CLEANUP_TIMESTAMPS["local"] = datetime.now(UTC)
        CLEANUP_STATUSES["local"] = "old_entries_removed" if removed > 0 else "no_old_entries_found"


def cleanup_cache_files():
    """Remove files older than CACHE_CLEANUP_INTERVAL from remote cache (supports file, s3, gcs)"""
    logger.info("cleanup_cache_files called at startup")
    try:
        cutoff = time.time() - CACHE_CLEANUP_INTERVAL
        removed = 0
        stale_cache_hashes = set()
        # List all files in cache root
        for cache_file in fs_cache.glob(f"{root_cache}/*"):
            try:
                if is_cache_access_temp_file(cache_file):
                    fs_cache.rm_file(cache_file)
                    logger.info(f"Cleaned up orphaned cache access temp file: {cache_file}")
                    removed += 1
                    continue
                if is_cache_access_record(cache_file):
                    continue

                cache_hash = get_cache_hash_from_remote_path(cache_file)
                mtime_ts = get_cache_entry_last_access_ts(cache_hash, cache_file)
                if mtime_ts < cutoff:
                    fs_cache.rm_file(cache_file)
                    logger.info(f"Cleaned up old cache file: {cache_file}")
                    removed += 1
                    stale_cache_hashes.add(cache_hash)
            except Exception:
                logger.warning(f"Cache cleanup error for {cache_file}", exc_info=True)

        for cache_hash in stale_cache_hashes:
            access_record_path = get_cache_access_record_path(cache_hash)
            if fs_cache.exists(access_record_path):
                try:
                    fs_cache.rm_file(access_record_path)
                    logger.info(f"Cleaned up old cache access record: {access_record_path}")
                    removed += 1
                except Exception:
                    logger.warning(
                        f"Cache cleanup error for access record {access_record_path}",
                        exc_info=True,
                    )
        if removed == 0:
            logger.info("No old files to clean up in remote cache.")
    except Exception:
        logger.error("Cache cleanup error", exc_info=True)
        CLEANUP_STATUSES["cache"] = "cleanup_error"
    else:
        CLEANUP_TIMESTAMPS["cache"] = datetime.now(UTC)
        CLEANUP_STATUSES["cache"] = "old_entries_removed" if removed > 0 else "no_old_entries_found"


def get_file_hash(file_path):
    """Calculate MD5 hash of a file for caching"""
    md5 = hashlib.md5(usedforsecurity=False)  # Only used for caching, not security
    with Path(file_path).open("rb") as f:
        for chunk in iter(lambda: f.read(4096), b""):
            md5.update(chunk)
    return md5.hexdigest()


def touch_for_lru(file_path):
    """Touch a file to update its mtime for LRU cache eviction. Silently ignores errors."""
    try:
        Path(file_path).touch()
    except Exception:
        logger.warning(f"Could not touch file for LRU update {file_path}", exc_info=True)


def is_cache_access_record(remote_path):
    """Return True when the remote cache path points to a sidecar access record."""
    return str(remote_path).endswith(CACHE_ACCESS_RECORD_SUFFIX)


def is_cache_access_temp_file(remote_path):
    """Return True when the remote cache path points to a temporary sidecar access record."""
    path_str = str(remote_path)
    return CACHE_ACCESS_RECORD_SUFFIX in path_str and path_str.endswith(".tmp")


def get_cache_hash_from_remote_path(remote_path):
    """Extract cache hash from a remote cache path."""
    filename = str(remote_path).rsplit("/", maxsplit=1)[-1]
    if filename.endswith(CACHE_ACCESS_RECORD_SUFFIX):
        return filename.removesuffix(CACHE_ACCESS_RECORD_SUFFIX)
    return filename.rsplit(".", maxsplit=1)[0]


def get_cache_access_record_path(cache_hash):
    """Return the remote access-record path for a cache entry."""
    return f"{root_cache}/{cache_hash}{CACHE_ACCESS_RECORD_SUFFIX}"


def parse_timestamp_to_epoch(timestamp_value):
    """Parse an ISO or backend-provided timestamp into epoch seconds."""
    if isinstance(timestamp_value, str):
        try:
            return datetime.fromisoformat(timestamp_value).timestamp()
        except ValueError:
            try:
                from dateutil.parser import parse as dtparse

                return dtparse(timestamp_value).timestamp()
            except Exception:
                return 0
    if timestamp_value is None:
        return 0
    try:
        return float(timestamp_value)
    except (TypeError, ValueError):
        return 0


def get_remote_path_mtime_ts(remote_path):
    """Return the remote file mtime as epoch seconds."""
    info = fs_cache.info(remote_path)
    return parse_timestamp_to_epoch(info.get("mtime") or info.get("LastModified"))


def load_cache_access_record(cache_hash):
    """Load the sidecar access record for a cache entry."""
    access_record_path = get_cache_access_record_path(cache_hash)
    if not fs_cache.exists(access_record_path):
        return None
    try:
        with fs_cache.open(access_record_path, "r") as f:
            data = json.load(f)
        if isinstance(data, dict):
            return data
    except Exception:
        logger.warning(f"Could not load cache access record for {cache_hash}", exc_info=True)
    return None


def get_cache_entry_last_access_ts(cache_hash, remote_path):
    """Return the cache entry access time, preferring the sidecar access record."""
    access_record = load_cache_access_record(cache_hash)
    if isinstance(access_record, dict):
        access_ts = parse_timestamp_to_epoch(access_record.get("last_accessed_at"))
        if access_ts > 0:
            return access_ts
    return get_remote_path_mtime_ts(remote_path)


def update_cache_access_record(cache_hash, *, force=False):
    """Best-effort write of a sidecar access record for remote-cache LRU tracking."""
    temp_record_path = None
    try:
        access_record_path = get_cache_access_record_path(cache_hash)
        now = datetime.now(UTC)
        existing_record = load_cache_access_record(cache_hash)
        if isinstance(existing_record, dict) and not force:
            last_accessed_ts = parse_timestamp_to_epoch(existing_record.get("last_accessed_at"))
            if last_accessed_ts > 0:
                age_seconds = now.timestamp() - last_accessed_ts
                if age_seconds < CACHE_ACCESS_UPDATE_INTERVAL_SECONDS:
                    return

        payload = json.dumps({"last_accessed_at": now.isoformat()})
        temp_record_path = f"{access_record_path}.{uuid.uuid4()}.tmp"
        with fs_cache.open(temp_record_path, "w") as f:
            f.write(payload)
        if fs_cache.exists(access_record_path):
            try:
                fs_cache.rm_file(access_record_path)
            except FileNotFoundError:
                logger.debug(
                    "Cache access record already removed before replacement: %s",
                    access_record_path,
                )
            except OSError as exc:
                if getattr(exc, "errno", None) != ENOENT_ERRNO:
                    raise
        fs_cache.mv(temp_record_path, access_record_path)
    except Exception:
        logger.warning(f"Could not update cache access record for {cache_hash}", exc_info=True)
    finally:
        if temp_record_path and fs_cache.exists(temp_record_path):
            try:
                fs_cache.rm_file(temp_record_path)
            except Exception:
                logger.warning(
                    f"Could not clean up temp cache access record for {cache_hash}",
                    exc_info=True,
                )


def summarize_cache_debug_times():
    """Return optional cache timing summaries for debug health output."""
    entry_times = []
    access_times = []
    try:
        for cache_file in fs_cache.glob(f"{root_cache}/*"):
            if is_cache_access_record(cache_file):
                continue
            cache_hash = get_cache_hash_from_remote_path(cache_file)
            entry_ts = get_remote_path_mtime_ts(cache_file)
            access_ts = get_cache_entry_last_access_ts(cache_hash, cache_file)
            if entry_ts > 0:
                entry_times.append(datetime.fromtimestamp(entry_ts, UTC))
            if access_ts > 0:
                access_times.append(datetime.fromtimestamp(access_ts, UTC))
    except Exception:
        logger.warning("Could not summarize cache debug times", exc_info=True)
        return {
            "oldest_entry_at": None,
            "newest_entry_at": None,
            "oldest_accessed_at": None,
            "newest_accessed_at": None,
        }

    def as_iso(value_list, fn):
        if not value_list:
            return None
        return fn(value_list).isoformat()

    return {
        "oldest_entry_at": as_iso(entry_times, min),
        "newest_entry_at": as_iso(entry_times, max),
        "oldest_accessed_at": as_iso(access_times, min),
        "newest_accessed_at": as_iso(access_times, max),
    }


def supports_flac(user_agent):
    """Check if browser supports FLAC playback"""
    # Modern browsers that support FLAC natively
    ua = user_agent.lower()
    flac_browsers = ["chrome", "chromium", "edge", "firefox", "safari"]
    return any(browser in ua for browser in flac_browsers)


def compress_to_flac(wav_path, flac_path):
    """Compress WAV to FLAC format"""
    # Use a temporary file for UADE output to ensure atomic write
    temp_flac_output_path = flac_path.with_name(f"{flac_path.name}.{uuid.uuid4()!s}.tmp")
    try:
        # Prevent division by zero if wav file is empty
        if wav_path.stat().st_size == 0:
            logger.warning(f"FLAC compression skipped: Input WAV file is empty: {wav_path}")
            return False

        cmd = [
            FLAC_BIN,
            "--best",
            "--silent",
            "-f",
            "-o",
            str(temp_flac_output_path),
            str(wav_path),
        ]
        result = subprocess.run(  # noqa: S603
            cmd, capture_output=True, text=True, check=False, timeout=60
        )

        if result.returncode == 0 and temp_flac_output_path.exists():
            Path.replace(temp_flac_output_path, flac_path)
            logger.info(f"Atomically moved {temp_flac_output_path} to {flac_path}")
            logger.info(
                f"Compressed to FLAC: {wav_path} -> {flac_path} "
                f"({flac_path.stat().st_size / wav_path.stat().st_size:.1%} of original)"
            )
            return True
        logger.error(f"FLAC compression failed: {result.stderr}")
        return False
    except Exception:
        logger.error("FLAC compression exception", exc_info=True)
        return False
    finally:
        temp_flac_output_path.unlink(missing_ok=True)  # Clean up temp file


def find_music_file(extract_dir):
    """
    Find and return the first music file in a directory matching known extensions or prefixes.
    """
    music_files = []
    for file_path in extract_dir.rglob("*"):
        if file_path.is_file():
            # Strip is applied to remove any leading/trailing spaces from extension and prefix,
            # which can occur in extracted files (e.g., 'Spirit-Creator.mod '), ensuring
            # robust matching.
            ext = file_path.suffix.lower()[1:].strip()
            prefix = file_path.name.lower().split(".")[0].strip()
            if ext in PLAYABLE_MODULE_EXTENSIONS or prefix in PLAYABLE_MODULE_EXTENSIONS:
                music_files.append(file_path)
    if not music_files:
        return None, 0
    # Sort files in reverse alphabetical order to ensure deterministic selection.
    # This tends to select later tracks or versions (e.g., 'track2' over 'track1').
    music_files.sort(reverse=True)
    return music_files[0], len(music_files)


def is_lha_file(file_path):
    """Check if file is an LHA archive by magic bytes"""
    try:
        with Path(file_path).open("rb") as f:
            # LHA files have signature at offset 2: '-lh' or '-lz'
            header = f.read(20)
            if len(header) >= LHA_HEADER_MIN_BYTES:
                signature = header[2:5]
                return signature == b"-lh" or signature == b"-lz"
        return False
    except Exception:
        return False


def is_zip_file(file_path):
    """Check if file is a ZIP archive by magic bytes"""
    try:
        with Path(file_path).open("rb") as f:
            header = f.read(4)
            # ZIP files start with PK\x03\x04 or PK\x05\x06 or PK\x07\x08
            return header[:2] == b"PK"
    except Exception:
        return False


def extract_lha(lha_path, extract_dir):
    """
    Extract LHA archive and return first music file found

    Returns: (success, error_message, music_file_path or None)
    """
    try:
        extract_dir.mkdir(parents=True, exist_ok=True)

        # Change to extract directory and run lha extraction
        cmd = [LHA_BIN, "x", str(lha_path)]
        result = subprocess.run(  # noqa: S603
            cmd, capture_output=True, text=True, check=False, timeout=30, cwd=str(extract_dir)
        )

        if result.returncode != 0:
            logger.error(f"LHA extraction error: {result.stderr}")
            return False, f"LHA extraction failed: {result.stderr}", None

        music_file, count = find_music_file(extract_dir)
        if not music_file:
            return False, "No music files found in LHA archive", None

        logger.info(f"Extracted LHA archive, found {count} music file(s), using: {music_file.name}")
        return True, None, music_file

    except subprocess.TimeoutExpired:
        return False, "LHA extraction timeout", None
    except Exception as e:
        logger.error("LHA extraction exception", exc_info=True)
        return False, str(e), None


def extract_zip(zip_path, extract_dir):
    """
    Extract ZIP archive and return first music file found

    Returns: (success, error_message, music_file_path or None)
    """
    try:
        extract_dir.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(zip_path, "r") as zip_ref:
            zip_ref.extractall(extract_dir)

        music_file, count = find_music_file(extract_dir)
        if not music_file:
            return False, "No music files found in ZIP archive", None

        logger.info(f"Extracted ZIP archive, found {count} music file(s), using: {music_file.name}")
        return True, None, music_file

    except zipfile.BadZipFile:
        return False, "ZIP extraction failed: Bad ZIP file", None
    except Exception as e:
        logger.error("ZIP extraction exception", exc_info=True)
        return False, str(e), None


def save_to_cache(cache_hash, file, ext):
    """Save a converted file and metadata to remote cache (WAV or FLAC)."""
    cache_file_remote = f"{root_cache}/{cache_hash}{ext}"
    temp_file_remote = f"{cache_file_remote}.{uuid.uuid4()}.tmp"
    if not fs_cache.exists(cache_file_remote):
        with Path(file).open("rb") as src, fs_cache.open(temp_file_remote, "wb") as dst:
            shutil.copyfileobj(src, dst, length=1024 * 1024)  # 1MB buffer
        # Atomic move to final name
        fs_cache.mv(temp_file_remote, cache_file_remote)
        logger.info(f"Cached conversion to remote: {cache_hash}{ext}")

    # Save metadata to remote cache if local file exists
    metadata_file_local = CONVERTED_DIR / f"{cache_hash}.json"
    if metadata_file_local.exists():
        # copy to remote cache
        cache_file_remote = f"{root_cache}/{cache_hash}.json"
        temp_file_remote = f"{cache_file_remote}.{uuid.uuid4()}.tmp"

        if not fs_cache.exists(cache_file_remote):
            with (
                Path(metadata_file_local).open("rb") as src,
                fs_cache.open(temp_file_remote, "wb") as dst,
            ):
                shutil.copyfileobj(src, dst, length=1024 * 1024)  # 1MB buffer
            # Atomic move to final remote name
            fs_cache.mv(temp_file_remote, cache_file_remote)
            logger.info(f"Cached metadata to remote: {cache_hash}.json")

    update_cache_access_record(cache_hash, force=True)


def fetch_cached_file(cache_hash, *, prefer_flac=False):
    """
    Check if a converted file exists in remote cache (WAV or FLAC).
    If found, copy to local and return local path with metadata.

    Returns:
        tuple: (cache_file_path, metadata) where metadata contains subsongs and
               subsong_durations, or (None, None) if not found
    """
    # Try FLAC first if preferred
    for ext in ([".flac"] if prefer_flac else []) + [".wav"]:
        cache_file_remote = f"{root_cache}/{cache_hash}{ext}"
        cache_file_local = CONVERTED_DIR / f"{cache_hash}{ext}"
        temp_file_local = cache_file_local.with_name(f"{cache_file_local.name}.{uuid.uuid4()}.tmp")
        if fs_cache.exists(cache_file_remote):
            remote_size = fs_cache.size(cache_file_remote)
            if cache_file_local.exists() and cache_file_local.stat().st_size == remote_size:
                logger.info(f"Cache hit ({ext[1:].upper()}): {cache_hash} already exists locally")
                # Touch file to extend its cleanup interval (LRU-aware caching)
                touch_for_lru(cache_file_local)
                update_cache_access_record(cache_hash)
                # Load metadata including subsong durations
                metadata = load_metadata_cache(cache_hash)
                if prefer_flac and ext == ".wav":
                    flac_cache_file_local = CONVERTED_DIR / f"{cache_hash}.flac"
                    if flac_cache_file_local.exists() or compress_to_flac(
                        cache_file_local, flac_cache_file_local
                    ):
                        save_to_cache(cache_hash, flac_cache_file_local, ".flac")
                        return flac_cache_file_local, metadata
                return cache_file_local, metadata
            # Ensure local cache directory exists
            cache_dir_local = cache_file_local.parent
            cache_dir_local.mkdir(parents=True, exist_ok=True)
            # Copy from remote cache to local temp file, then move atomically
            with (
                fs_cache.open(cache_file_remote, "rb") as src,
                Path(temp_file_local).open("wb") as dst,
            ):
                shutil.copyfileobj(src, dst, length=1024 * 1024)  # 1MB buffer
            Path.replace(temp_file_local, cache_file_local)
            logger.info(f"Cache hit ({ext[1:].upper()}): {cache_hash} from remote cache")
            # Touch file to extend its cleanup interval (LRU-aware caching)
            touch_for_lru(cache_file_local)
            update_cache_access_record(cache_hash)
            # Load metadata including subsong durations
            metadata = load_metadata_cache(cache_hash)
            if prefer_flac and ext == ".wav":
                flac_cache_file_local = CONVERTED_DIR / f"{cache_hash}.flac"
                if flac_cache_file_local.exists() or compress_to_flac(
                    cache_file_local, flac_cache_file_local
                ):
                    save_to_cache(cache_hash, flac_cache_file_local, ".flac")
                    return flac_cache_file_local, metadata
            return cache_file_local, metadata
    return None, None


def detect_module_metadata(input_path):
    """
    Detect module metadata using uade123 -g

    Returns: (metadata_success, module_name, module_format, player_format, subsongs)
    """
    try:
        cmd = [UADE123_BIN, "-g", str(input_path)]
        # Use encoding='latin1' to avoid decode errors with non-UTF-8 bytes in output
        result = subprocess.run(  # noqa: S603
            cmd, capture_output=True, text=True, check=False, timeout=5, encoding="latin1"
        )
        if result.returncode != 0:
            logger.error(f"UADE metadata detection error: {result.stderr}")
            return False, None, None, None, 0

        metadata_success = False
        module_name = None
        module_format = None
        player_format = "Module"  # Default player format
        subsongs = 1

        # Parse output to extract metadata
        # Example uade123 output:
        # formatname: type: Protracker
        # modulename: space debris
        # playername: Protracker and family
        # subsongs: cur 1 min 1 max 1
        for line in result.stdout.splitlines():
            if line.startswith("modulename:"):
                module_name = line.split(":", 1)[1].strip()
            elif line.startswith("formatname:"):
                module_format = line.split(":", 1)[1].strip()
                # Remove 'type:' prefix if present
                module_format = module_format.replace("type:", "", 1).strip()
            elif line.startswith("playername:"):
                player_format = line.split(":", 1)[1].strip()
                metadata_success = True  # A player was explicitly found
            elif line.startswith("subsongs:"):
                # Parse "subsongs: cur 1 min 1 max 1" to get subsong count
                # Extract min and max values to calculate count
                parts = line.split()
                min_val = None
                max_val = None
                for i, part in enumerate(parts):
                    if part == "min" and i + 1 < len(parts):
                        try:
                            min_val = int(parts[i + 1])
                        except ValueError:
                            logger.warning(f"Failed to parse subsong value: {parts[i + 1]}")
                    elif part == "max" and i + 1 < len(parts):
                        try:
                            max_val = int(parts[i + 1])
                        except ValueError:
                            logger.warning(f"Failed to parse subsong value: {parts[i + 1]}")
                # Calculate subsongs: max - min + 1
                if min_val is not None and max_val is not None:
                    subsongs = max_val - min_val + 1
                else:
                    subsongs = 1  # Fallback if not found

        # Check for 'uade:is_custom': True in output
        if "'uade:is_custom': True" in result.stdout:
            player_format = "Custom"
            metadata_success = True  # Custom module also means metadata was successful
            if not module_format:
                module_format = "Custom"

        logger.info(
            f"Detected: metadata_success={metadata_success}, modulename={module_name}, "
            f"moduleformat={module_format}, player={player_format}, subsongs={subsongs}"
        )
        return metadata_success, module_name, module_format, player_format, subsongs

    except subprocess.TimeoutExpired:
        logger.warning(f"Detect metadata timeout (5 seconds exceeded) for file: {input_path}")
        return False, None, None, None, 0
    except Exception:
        logger.warning("Could not detect metadata", exc_info=True)
        return False, None, None, None, 0


def parse_subsong_durations(uade_output, subsong_count):
    """
    Parse UADE stdout/stderr output to extract per-subsong durations.
    Only extracts duration information for modules with more than 1 subsong.

    Args:
        uade_output (str): UADE conversion output (stderr)
        subsong_count (int): Expected number of subsongs from metadata detection

    Returns:
        tuple: (duration_list, error)
            - duration_list: list[float] ordered durations, empty if single subsong
            - error: None on success, error message string on failure
    """
    # Skip parsing for single subsong modules
    if subsong_count <= 1:
        return [], None

    # Parse durations for multiple subsongs
    durations = {}
    time_pattern = re.compile(r"Playing time position (\d+(?:\.\d+)?)s in subsong (\d+)")

    for line in uade_output.splitlines():
        time_match = time_pattern.search(line)
        if time_match:
            time_sec = float(time_match.group(1))
            subsong_index = int(time_match.group(2))
            durations[subsong_index] = time_sec

    # Construct ordered list of durations
    duration_list = [durations.get(idx, 0.0) for idx in range(0, subsong_count)]

    # Validate that parsed count matches expected count
    if len(duration_list) != subsong_count:
        return [], f"Subsong count mismatch: expected {subsong_count}, got {len(duration_list)}"

    return duration_list, None


def save_metadata(cache_hash, metadata):
    """
    Save metadata JSON to local disk first, then copy to remote cache
    (same pattern as audio files)
    """
    try:
        # Save to local disk
        metadata_file_local = CONVERTED_DIR / f"{cache_hash}.json"
        temp_file_local = metadata_file_local.with_name(
            f"{metadata_file_local.name}.{uuid.uuid4()}.tmp"
        )

        metadata_json = json.dumps(metadata)
        with Path(temp_file_local).open("w") as f:
            f.write(metadata_json)

        # Atomic move to final local name
        Path.replace(temp_file_local, metadata_file_local)
        logger.info(f"Saved metadata to local: {cache_hash}.json")

    except Exception:
        logger.warning("Could not save metadata", exc_info=True)


def load_metadata_cache(cache_hash):
    """Load metadata JSON from local disk first, fallback to remote cache if not found locally"""
    try:
        # Try local disk first
        metadata_file_local = CONVERTED_DIR / f"{cache_hash}.json"
        if metadata_file_local.exists():
            with Path(metadata_file_local).open() as f:
                metadata = json.load(f)
            logger.info(f"Loaded metadata from local: {cache_hash}.json")
            # Touch file to extend its cleanup interval (LRU-aware caching)
            touch_for_lru(metadata_file_local)
            update_cache_access_record(cache_hash)
            return metadata

        # Fallback to remote cache if not found locally
        metadata_file_remote = f"{root_cache}/{cache_hash}.json"
        if fs_cache.exists(metadata_file_remote):
            with fs_cache.open(metadata_file_remote, "r") as f:
                metadata = json.load(f)
            logger.info(f"Loaded metadata from remote cache: {cache_hash}.json")
            update_cache_access_record(cache_hash)

            # Save to local disk for future access
            temp_file_local = metadata_file_local.with_name(
                f"{metadata_file_local.name}.{uuid.uuid4()}.tmp"
            )
            metadata_json = json.dumps(metadata)
            with Path(temp_file_local).open("w") as f:
                f.write(metadata_json)
            Path.replace(temp_file_local, metadata_file_local)
            logger.info(f"Cached metadata to local: {cache_hash}.json")
            # Touch file to extend its cleanup interval (LRU-aware caching)
            touch_for_lru(metadata_file_local)

            return metadata
    except Exception:
        logger.warning("Could not load metadata cache", exc_info=True)
    return None


def wait_for_conversion(
    cache_hash, prefer_flac, player_format, module_name, module_format, subsongs
):
    """Wait for a file conversion to complete and return the result."""
    logger.info(f"Conversion for {cache_hash} is in progress, waiting...")
    # Wait for up to 300 seconds (5 minutes), matching the conversion timeout.
    for _ in range(60):
        time.sleep(5)
        cached_file, metadata = fetch_cached_file(cache_hash, prefer_flac=prefer_flac)
        if cached_file and cached_file.exists():
            logger.info(f"Conversion for {cache_hash} completed by another thread.")
            # Extract duration_list from metadata
            duration_list = metadata.get("subsong_durations", []) if metadata else []
            return (
                True,
                None,
                cached_file,
                player_format,
                module_name,
                module_format,
                subsongs,
                True,  # cached
                cache_hash,
                duration_list,
            )
    logger.warning(f"Timeout waiting for conversion of {cache_hash}.")
    return None


def process_audio_conversion(input_path, *, compress_flac=False, sample_files=None):
    """
    Convert module to WAV using UADE with optional caching and FLAC compression.

    This function includes a file-based locking mechanism to prevent race conditions
    when multiple threads try to convert the same file simultaneously.

    Args:
        input_path (Path): Path to the module file to convert.
        compress_flac (bool): Whether to compress output to FLAC format.
        sample_files (list): Optional list of associated sample file paths to clean up
                             if metadata detection fails.

    Returns:
        A tuple containing:
        success (bool): True if conversion succeeded, False otherwise.
        error (str or None): Error message if conversion failed, None otherwise.
        final_file (Path or None): Path to the converted audio file (WAV or FLAC).
        player_format (str or None): Detected player format.
        module_name (str or None): Detected module name.
        module_format (str or None): Detected module format.
        subsongs (int): Number of subsongs detected.
        cached (bool): True if the audio was served from cache.
        cache_hash (str or None): The MD5 hash of the input file.
        duration_list (list[float]): Per-subsong durations (empty for single subsong or cache hits).
    """
    # Hold metadata to return to the caller, even if conversion fails.
    metadata_success, module_name, module_format, player_format, subsongs = (
        False,
        None,
        None,
        None,
        0,
    )
    cache_hash = None

    try:
        # Defensive: Restrict input_path to MODULES_DIR
        input_resolved = Path(input_path).resolve()
        if not (input_resolved.is_relative_to(MODULES_DIR.resolve())):
            logger.error("Aborting: attempted read outside allowed directories")
            return (
                False,
                "Illegal input file path",
                None,
                player_format,
                module_name,
                module_format,
                subsongs,
                False,
                cache_hash,
                [],
            )

        # Calculate cache hash first to check for cached metadata
        cache_hash = get_file_hash(input_path)

        # Try to load cached metadata first to avoid expensive metadata detection
        cached_metadata = load_metadata_cache(cache_hash)
        if cached_metadata:
            # Use cached metadata instead of running detection
            module_name = cached_metadata.get("module_name")
            module_format = cached_metadata.get("module_format")
            player_format = cached_metadata.get("player_format", "Module")
            subsongs = cached_metadata.get("subsongs", 1)
            metadata_success = True
            logger.info(f"Using cached metadata for {cache_hash}: {module_name} ({player_format})")
        else:
            # No cached metadata, run detection
            # Use a unique lock file for metadata detection (per thread/process)
            unique_metadata_lock = MODULES_DIR / f"{cache_hash}.metadatalock.{uuid.uuid4()!s}"
            unique_metadata_lock.touch(exist_ok=True)
            try:
                (
                    metadata_success,
                    module_name,
                    module_format,
                    player_format,
                    subsongs,
                ) = detect_module_metadata(input_path)
            finally:
                unique_metadata_lock.unlink(missing_ok=True)

        # Truncates file to 0 bytes if metadata detection fails.
        # This prevents disk abuse and caches the fact that this URL provides an invalid module.
        # Only truncates if no other .metadatalock.* files exist for this module.
        # Retains original content if metadata is detected but conversion fails (for debug).
        if not metadata_success:
            # Check for any remaining .metadatalock.* files for this module
            lock_glob = MODULES_DIR.glob(f"{cache_hash}.metadatalock.*")
            if not any(lock_glob):
                logger.info(
                    f"Could not detect metadata for {input_path}. "
                    "Truncating file to 0 bytes to cache as invalid module."
                )
                with Path(input_resolved).open("w") as _:  # Truncate to 0 bytes
                    pass

                # Also truncate any associated sample files to prevent disk abuse
                if sample_files:
                    for sample_file_path in sample_files:
                        if sample_file_path and sample_file_path.exists():
                            # Remove symlinks, truncate regular files
                            if sample_file_path.is_symlink():
                                sample_file_path.unlink(missing_ok=True)
                                logger.info(f"Removed sample symlink: {sample_file_path}")
                            else:
                                with Path(sample_file_path).open("w") as _:
                                    pass
                                logger.info(f"Truncated sample file to 0 bytes: {sample_file_path}")
            else:
                logger.info(
                    f"Could not detect metadata for {input_path}, but other locks exist. "
                    "Retaining file for ongoing metadata detection."
                )
            return (
                False,
                "Could not detect module metadata. "
                "The file may be corrupt or not a supported module.",
                None,
                player_format,
                module_name,
                module_format,
                subsongs,
                False,
                cache_hash,
                [],
            )

        output_path = CONVERTED_DIR / f"{cache_hash}.wav"
        lock_path = CONVERTED_DIR / f"{cache_hash}.lock"
        # Use a temporary file for UADE output to ensure atomic write
        temp_uade_output_path = output_path.with_name(f"{output_path.name}.{uuid.uuid4()!s}.tmp")

        # Check remote cache first (before acquiring lock)
        cached_file, metadata = fetch_cached_file(cache_hash, prefer_flac=compress_flac)
        if cached_file and cached_file.exists():
            # Extract duration_list from metadata
            duration_list = metadata.get("subsong_durations", []) if metadata else []
            return (
                True,
                None,
                cached_file,
                player_format,
                module_name,
                module_format,
                subsongs,
                True,
                cache_hash,
                duration_list,
            )

        # If lock exists, another thread is already converting this file
        if lock_path.exists():
            result = wait_for_conversion(
                cache_hash, compress_flac, player_format, module_name, module_format, subsongs
            )
            if result:
                return result
            logger.warning(
                f"Timeout waiting for conversion of {cache_hash} by another thread. "
                "Proceeding with conversion ourselves."
            )

        try:
            lock_path.touch(exist_ok=False)

            cached_file, metadata = fetch_cached_file(cache_hash, prefer_flac=compress_flac)
            if cached_file and cached_file.exists():
                # Extract duration_list from metadata
                duration_list = metadata.get("subsong_durations", []) if metadata else []
                return (
                    True,
                    None,
                    cached_file,
                    player_format,
                    module_name,
                    module_format,
                    subsongs,
                    True,
                    cache_hash,
                    duration_list,
                )

            cmd = [
                UADE123_BIN,
                "-c",
                "-f",
                str(temp_uade_output_path),
                str(input_path),
            ]  # Headless mode

            # Modern way to set umask for a child process without using the deprecated preexec_fn.
            # We wrap the command in a shell that sets the umask and then execs the binary.
            # This is thread-safe and avoids Python's deprecated preexec_fn.
            full_cmd = [SH_BIN, "-c", 'umask 0002; exec "$@"', "--", *cmd]

            result = subprocess.run(  # noqa: S603
                full_cmd,
                capture_output=True,
                text=True,
                check=False,
                timeout=300,
                encoding="latin1",
            )  # 5 minute timeout

            if result.returncode != 0:
                logger.error(f"UADE error: {result.stderr}")
                return (
                    False,
                    f"Conversion failed: {result.stderr}",
                    None,
                    player_format,
                    module_name,
                    module_format,
                    subsongs,
                    False,
                    cache_hash,
                    [],
                )

            Path.replace(temp_uade_output_path, output_path)
            logger.info(f"Atomically moved {temp_uade_output_path} to {output_path}")

            if not output_path.exists():
                return (
                    False,
                    "Conversion failed: Output file not created",
                    None,
                    player_format,
                    module_name,
                    module_format,
                    subsongs,
                    False,
                    cache_hash,
                    [],
                )

            # Parse subsong durations from conversion output
            duration_list, duration_error = parse_subsong_durations(result.stderr, subsongs)
            if duration_error:
                logger.warning(f"Duration parsing error: {duration_error}")

            final_output = output_path

            # Compress to FLAC if requested
            if compress_flac:
                flac_output = output_path.with_suffix(".flac")
                if compress_to_flac(output_path, flac_output):
                    final_output = flac_output
            # Save metadata to local disk first (includes detected metadata and subsong durations)
            metadata = {
                "subsongs": subsongs,
                "subsong_durations": duration_list,
                "module_name": module_name,
                "module_format": module_format,
                "player_format": player_format,
            }
            save_metadata(cache_hash, metadata)

            # Save audio to remote cache (will also copy metadata to remote)
            ext, file_to_save = (".flac", final_output) if compress_flac else (".wav", output_path)
            save_to_cache(cache_hash, file_to_save, ext)
            logger.info(f"Successfully converted: {input_path} -> {final_output}")
            return (
                True,
                None,
                final_output,
                player_format,
                module_name,
                module_format,
                subsongs,
                False,
                cache_hash,
                duration_list,
            )

        except FileExistsError:
            result = wait_for_conversion(
                cache_hash, compress_flac, player_format, module_name, module_format, subsongs
            )
            if result:
                return result
            return (
                False,
                "Timeout waiting for another conversion process after lock contention.",
                None,
                player_format,
                module_name,
                module_format,
                subsongs,
                False,
                cache_hash,
                [],
            )
        finally:
            lock_path.unlink(missing_ok=True)
            temp_uade_output_path.unlink(missing_ok=True)  # Clean up temp file

    except FileNotFoundError:
        logger.error(f"File not found for processing: {input_path}")
        return (
            False,
            f"File not found: {input_path}",
            None,
            None,
            None,
            None,
            0,
            False,
            None,
            [],
        )

    except subprocess.TimeoutExpired:
        return (
            False,
            "Conversion timeout (5 minutes exceeded)",
            None,
            player_format,
            module_name,
            module_format,
            subsongs,
            False,
            cache_hash,
            [],
        )
    except Exception:
        logger.error("Conversion exception", exc_info=True)
        return (
            False,
            "Internal server error during conversion",
            None,
            player_format,
            module_name,
            module_format,
            subsongs,
            False,
            cache_hash,
            [],
        )


@app.route("/")
@limiter.exempt
def index():
    """Serve main page"""
    return send_from_directory("static", "index.html")


@app.route("/robots.txt")
@limiter.exempt
def robots_txt():
    """Serve robots.txt to guide web crawlers"""
    return send_from_directory(app.static_folder, "robots.txt")


@app.route("/sitemap.xml")
@limiter.exempt
def sitemap_xml():
    """Serve sitemap.xml for search engine indexing"""
    return send_from_directory(app.static_folder, "sitemap.xml")


@app.route("/supported-extensions")
@limiter.exempt
def get_supported_extensions():
    """Return a list of supported file extensions"""
    extensions = [*sorted(PLAYABLE_MODULE_EXTENSIONS), "lha", "zip"]
    return json_response([f".{ext}" for ext in extensions])


@app.route("/health")
@limiter.exempt
def health():
    """Health check for load balancers with detailed runtime information"""
    # Check for presence of required external binaries
    binaries = {
        "uade123": Path(UADE123_BIN).exists(),
        "flac": shutil.which("flac") is not None,
        "lha": shutil.which("lha") is not None,
        "unzip": shutil.which("unzip") is not None,
    }

    # Gather cache information (redact sensitive parts of URI)
    cache_info = {
        "protocol": fs_cache.protocol,
        "uri_redacted": CACHE_URI.split("://")[0] + "://***" if "://" in CACHE_URI else "***",
        "cleanup_status": CLEANUP_STATUSES["cache"],
        "last_cleanup_at": (
            CLEANUP_TIMESTAMPS["cache"].isoformat()
            if CLEANUP_TIMESTAMPS["cache"] is not None
            else None
        ),
    }
    if HEALTH_INCLUDE_CACHE_DEBUG:
        cache_info["debug"] = summarize_cache_debug_times()
    temp_files_info = {
        "cleanup_status": CLEANUP_STATUSES["local"],
        "last_cleanup_at": (
            CLEANUP_TIMESTAMPS["local"].isoformat()
            if CLEANUP_TIMESTAMPS["local"] is not None
            else None
        ),
    }

    return json_response(
        {
            "status": "healthy",
            "version": GIT_COMMIT,
            "image_build_time": IMAGE_BUILD_TIME,
            "uade_version": UADE_VERSION,
            "timestamp": datetime.now(UTC).isoformat(),
            "uptime_seconds": int(time.time() - START_TIME),
            "uade_available": binaries["uade123"],
            "python_version": sys.version.split()[0],
            "os_platform": platform.platform(),
            "memory": get_memory_usage(),
            "disk": get_disk_usage(TEMP_BASE),
            "binaries": binaries,
            "cache": cache_info,
            "temp_files": temp_files_info,
            "config": {
                "max_upload_size_mb": MAX_UPLOAD_SIZE / (1024 * 1024),
                "max_download_size_mb": MAX_DOWNLOAD_SIZE / (1024 * 1024),
                "rate_limiting_enabled": rate_limit_enabled,
                "cleanup_interval_seconds": CLEANUP_INTERVAL,
            },
        }
    )


@app.route("/test/run-cleanup", methods=["POST"])
@limiter.exempt
def test_run_cleanup():
    """Trigger cleanup paths in test mode to validate health status transitions."""
    if os.getenv("UADE_TEST_MODE") != "1":
        return json_response({"error": "Not found"}, 404)

    data = request.get_json(silent=True) or {}
    scope = data.get("scope", "all")
    if scope not in {"local", "cache", "all"}:
        return json_response({"error": "Invalid cleanup scope"}, 400)

    if scope in {"local", "all"}:
        cleanup_old_files()
    if scope in {"cache", "all"}:
        cleanup_cache_files()

    return json_response(
        {
            "local": {
                "cleanup_status": CLEANUP_STATUSES["local"],
                "last_cleanup_at": (
                    CLEANUP_TIMESTAMPS["local"].isoformat()
                    if CLEANUP_TIMESTAMPS["local"] is not None
                    else None
                ),
            },
            "cache": {
                "cleanup_status": CLEANUP_STATUSES["cache"],
                "last_cleanup_at": (
                    CLEANUP_TIMESTAMPS["cache"].isoformat()
                    if CLEANUP_TIMESTAMPS["cache"] is not None
                    else None
                ),
            },
        }
    )


@app.route("/examples")
@limiter.exempt
def get_examples():
    """Return list of example modules"""
    return json_response(EXAMPLES)


@app.route("/upload", methods=["POST"])
@limiter.limit("10 per minute")
def upload_file():
    """Handle file upload and conversion"""
    cleanup_old_files()

    if "file" not in request.files:
        return json_response({"error": "No file provided"}, 400)

    file = request.files["file"]
    if file.filename == "":
        return json_response({"error": "No file selected"}, 400)

    # Check for empty file content
    file.seek(0, os.SEEK_END)
    file_size = file.tell()
    file.seek(0, os.SEEK_SET)  # Reset file pointer
    if file_size == 0:
        return json_response({"error": "Empty file provided"}, 400)

    try:
        # Check browser FLAC support
        user_agent = request.headers.get("User-Agent", "")
        sanitized_user_agent = user_agent.replace("\r", "").replace("\n", "")
        logger.info(f"User-Agent: {sanitized_user_agent}")
        use_flac = supports_flac(user_agent)

        # Generate unique ID
        file_id = str(uuid.uuid4())
        filename = secure_filename(file.filename)

        # Save uploaded file
        module_path = MODULES_DIR / f"{filename}_{file_id}"
        file.save(module_path)
        return process_module_and_respond(
            module_path, filename, use_flac, url_cached=False, sample_files=None
        )

    except Exception:
        logger.error("Upload error", exc_info=True)
        return json_response({"error": "Internal server error during upload"}, 500)


def process_module_and_respond(
    module_path, filename, use_flac, *, url_cached=False, sample_files=None
):
    """
    Shared logic for archive detection, extraction, conversion, metadata, cleanup, and response.
    """
    # Generate a unique ID for the extraction directory to prevent race conditions
    unique_id = str(uuid.uuid4())
    extract_dir = Path(f"{module_path}_extracted_{unique_id}")

    # Check for a zero-byte file, which indicates a previously processed invalid module
    if module_path.exists() and module_path.stat().st_size == 0:
        logger.info(f"Skipping processing for known invalid zero-byte module: {module_path}")
        return json_response(
            {
                "error": "Could not detect module metadata. "
                "The file may be corrupt or not a supported module."
            },
            500,
        )

    try:
        # Check if it's an LHA or ZIP archive
        if is_lha_file(module_path):
            logger.info(f"Detected LHA archive: {filename}")
            success, error, music_file = extract_lha(module_path, extract_dir)
            if not success:
                module_path.unlink(missing_ok=True)
                return json_response({"error": error}, 500)
            filename = music_file.name
            module_path = music_file
        elif is_zip_file(module_path):
            logger.info(f"Detected ZIP archive: {filename}")
            success, error, music_file = extract_zip(module_path, extract_dir)
            if not success:
                module_path.unlink(missing_ok=True)
                return json_response({"error": error}, 500)
            filename = music_file.name
            module_path = music_file

        # Convert to WAV (and optionally FLAC)
        (
            success,
            error,
            final_file,
            player_format,
            module_name,
            module_format,
            subsongs,
            cached,
            converted_file_id,
            duration_list,
        ) = process_audio_conversion(module_path, compress_flac=use_flac, sample_files=sample_files)

        if not success:
            return json_response({"error": error}, 500)

        return json_response(
            {
                "success": True,
                "file_id": converted_file_id,
                "filename": filename,
                "module_name": module_name,
                "module_format": module_format,
                "player_format": player_format,
                "subsongs": subsongs,
                "subsong_durations": duration_list,
                "audio_format": final_file.suffix[1:] if final_file else "wav",
                "play_url": f"/play/{converted_file_id}",
                "download_url": (
                    f"/download/{converted_file_id}?filename="
                    f"{urllib.parse.quote(module_name or filename)}"
                ),
                "cached": cached,
                "url_cached": url_cached,
            }
        )

    finally:
        # Clean up extracted files only (do not delete cached files)
        if extract_dir.exists():
            shutil.rmtree(extract_dir, ignore_errors=True)


def detect_cached_module_metadata(input_path, sample_files=None):
    """
    Load cached metadata or detect it from the module without converting audio.

    On detection failure, truncate the module (and sample files, if any) to cache the
    invalid state, matching the existing convert-url/upload behavior.
    """
    cache_hash = get_file_hash(input_path)
    module_name = None
    module_format = None
    player_format = None
    subsongs = 0

    cached_metadata = load_metadata_cache(cache_hash)
    if cached_metadata:
        module_name = cached_metadata.get("module_name")
        module_format = cached_metadata.get("module_format")
        player_format = cached_metadata.get("player_format", "Module")
        subsongs = cached_metadata.get("subsongs", 1)
        logger.info(f"Using cached metadata for {cache_hash}: {module_name} ({player_format})")
        return True, module_name, module_format, player_format, subsongs, cache_hash

    unique_metadata_lock = MODULES_DIR / f"{cache_hash}.metadatalock.{uuid.uuid4()!s}"
    unique_metadata_lock.touch(exist_ok=True)
    try:
        metadata_success, module_name, module_format, player_format, subsongs = (
            detect_module_metadata(input_path)
        )
    finally:
        unique_metadata_lock.unlink(missing_ok=True)

    if not metadata_success:
        lock_glob = MODULES_DIR.glob(f"{cache_hash}.metadatalock.*")
        if not any(lock_glob):
            logger.info(
                f"Could not detect metadata for {input_path}. "
                "Truncating file to 0 bytes to cache as invalid module."
            )
            with Path(input_path).open("w") as _:
                pass

            if sample_files:
                for sample_file_path in sample_files:
                    if sample_file_path and sample_file_path.exists():
                        if sample_file_path.is_symlink():
                            sample_file_path.unlink(missing_ok=True)
                            logger.info(f"Removed sample symlink: {sample_file_path}")
                        else:
                            with Path(sample_file_path).open("w") as _:
                                pass
                            logger.info(f"Truncated sample file to 0 bytes: {sample_file_path}")
        else:
            logger.info(
                f"Could not detect metadata for {input_path}, but other locks exist. "
                "Retaining file for ongoing metadata detection."
            )

    return metadata_success, module_name, module_format, player_format, subsongs, cache_hash


def process_module_probe_response(module_path, filename, *, url_cached=False, sample_files=None):
    """Shared logic for archive handling and metadata-only probe responses."""
    unique_id = str(uuid.uuid4())
    extract_dir = Path(f"{module_path}_extracted_{unique_id}")

    if module_path.exists() and module_path.stat().st_size == 0:
        logger.info(f"Skipping probe for known invalid zero-byte module: {module_path}")
        return json_response(
            {
                "ok": False,
                "playable": False,
                "error": "Could not detect module metadata. "
                "The file may be corrupt or not a supported module.",
            },
            500,
        )

    try:
        if is_lha_file(module_path):
            logger.info(f"Detected LHA archive during probe: {filename}")
            success, error, music_file = extract_lha(module_path, extract_dir)
            if not success:
                module_path.unlink(missing_ok=True)
                return json_response({"ok": False, "playable": False, "error": error}, 500)
            filename = music_file.name
            module_path = music_file
        elif is_zip_file(module_path):
            logger.info(f"Detected ZIP archive during probe: {filename}")
            success, error, music_file = extract_zip(module_path, extract_dir)
            if not success:
                module_path.unlink(missing_ok=True)
                return json_response({"ok": False, "playable": False, "error": error}, 500)
            filename = music_file.name
            module_path = music_file

        (
            metadata_success,
            module_name,
            module_format,
            player_format,
            subsongs,
            _cache_hash,
        ) = detect_cached_module_metadata(module_path, sample_files=sample_files)

        if not metadata_success:
            return json_response(
                {
                    "ok": False,
                    "playable": False,
                    "error": "Could not detect module metadata. "
                    "The file may be corrupt or not a supported module.",
                },
                500,
            )

        return json_response(
            {
                "ok": True,
                "playable": True,
                "filename": filename,
                "module_name": module_name or filename,
                "module_format": module_format,
                "player_format": player_format,
                "subsongs": subsongs,
                "url_cached": url_cached,
                "source_type": "dual" if sample_files else "single",
            }
        )
    finally:
        if extract_dir.exists():
            shutil.rmtree(extract_dir, ignore_errors=True)


def is_safe_url(u):
    """
    Reject private/LAN/loopback/non-HTTP(S) URLs for SSRF defense,
    including IDN/punycode normalization.
    """
    try:
        # Prepare a safe, normalized string for logging
        sanitized_url_for_log = sanitized_url(u)

        parsed = urllib.parse.urlparse(u)
        if parsed.scheme not in ("http", "https"):
            logger.info(
                f"is_safe_url: rejected scheme '{parsed.scheme}' for URL: {sanitized_url_for_log}"
            )
            return False
        if not parsed.hostname:
            logger.info(f"is_safe_url: missing hostname in URL: {sanitized_url_for_log}")
            return False
        # Normalize hostname for Unicode/punycode edge cases
        try:
            normalized_hostname = parsed.hostname.encode("idna").decode("ascii")
        except Exception:
            logger.info(
                f"is_safe_url: failed to normalize hostname '{parsed.hostname}' "
                f"in URL: {sanitized_url_for_log}"
            )  # codeql [py/log-injection] lgtm [py/log-injection]
            normalized_hostname = parsed.hostname

        if os.getenv("UADE_TEST_MODE") == "1" and normalized_hostname == "uade-test-http-server":
            logger.info(
                f"is_safe_url: allowed internal test host '{normalized_hostname}' "
                f"in test mode for URL: {sanitized_url_for_log}"
            )
            return True  # Allow immediately, skipping IP and other checks

        # IP resolution (avoid DNS rebinding, etc)
        # Attempt to resolve; fallback to hostname if not an IP
        try:
            ip = ipaddress.ip_address(normalized_hostname)
            check_ips = [ip]
        except ValueError:
            # Resolve domain to all IPs
            try:
                check_ips = [
                    ipaddress.ip_address(addr[4][0])
                    for addr in socket.getaddrinfo(normalized_hostname, None)
                ]
            except Exception:
                logger.info(
                    f"is_safe_url: failed to resolve domain '{normalized_hostname}' "
                    f"in URL: {sanitized_url_for_log}"
                )  # codeql [py/log-injection] lgtm [py/log-injection]
                return False
        for ip in check_ips:
            if (
                ip.is_loopback
                or ip.is_private
                or ip.is_link_local
                or ip.is_reserved
                or ip.is_multicast
                or ip.is_unspecified
            ):
                logger.info(f"is_safe_url: rejected IP '{ip}' for URL: {sanitized_url_for_log}")
                return False

        # Check for shell-sensitive characters in path and query
        # Unquote path and query before checking
        unquoted_path = urllib.parse.unquote(parsed.path)
        unquoted_query = urllib.parse.unquote(parsed.query)
        unquoted_fragment = urllib.parse.unquote(parsed.fragment)

        # Explicitly check for problematic characters that might cause shell injection
        problematic_chars = [
            "`",
            "\n",
            "\r",
            ";",
            "&",
            "|",
            "<",
            ">",
            "[",
            "]",
            "{",
            "}",
            "\\",
        ]
        for char in problematic_chars:
            if char in unquoted_path or char in unquoted_query or char in unquoted_fragment:
                logger.info(
                    f"is_safe_url: rejected URL due to problematic character '{char}' "
                    f"in path/query/fragment for URL: {sanitized_url_for_log}"
                )
                return False

        if (
            unquoted_path.endswith(("'", '"'))
            or unquoted_query.endswith(("'", '"'))
            or unquoted_fragment.endswith(("'", '"'))
        ):
            logger.info(
                "is_safe_url: rejected URL due to dangling quote in path/query/fragment "
                f"for URL: {sanitized_url_for_log}"
            )
            return False

        # Path traversal check in path and query
        # Normalize backslashes to slashes and check for ".." segments
        normalized_path = unquoted_path.replace("\\", "/")
        normalized_query = unquoted_query.replace("\\", "/")
        if any(seg == ".." for seg in normalized_path.split("/")) or any(
            seg == ".." for seg in normalized_query.split("/")
        ):
            logger.info(
                f"is_safe_url: rejected URL due to path traversal pattern '..' "
                f"in path/query for URL: {sanitized_url_for_log}"
            )
            return False

        # All checks passed
        logger.info(f"is_safe_url: accepted URL: {sanitized_url_for_log}")
        return True
    except Exception:
        logger.error(f"is_safe_url: exception for URL '{sanitized_url_for_log}'", exc_info=True)
        return False


def get_dual_file_module_filenames(filename):
    """
    Determine the correct filenames and suffixes for dual-file modules using DUAL_FILE_MODULES.

    Handles both suffix-based and prefix-based matching for pattern_data and sample_data.
    Returns: (filename, suffix, sample_filename, sample_suffix)
    """
    # Use DUAL_FILE_MODULES array for module pattern matching
    suffix = ""
    sample_suffix = ""
    sample_filename = None
    # Prefix-based match using DUAL_FILE_MODULES
    for entry in DUAL_FILE_MODULES:
        pat = entry["pattern_data"]
        samp = entry["sample_data"]
        if filename.startswith(f"{pat}."):
            sample_filename = f"{samp}." + filename[len(f"{pat}.") :]
            break
    if not sample_filename:
        for entry in DUAL_FILE_MODULES:
            pat = entry["pattern_data"]
            samp = entry["sample_data"]
            # Suffix-based match
            if filename.lower().endswith(f".{pat}"):
                filename = filename.removesuffix(f".{pat}")
                sample_filename = filename
                suffix = f".{pat}"
                sample_suffix = f".{samp}"
                break
    return filename, suffix, sample_filename, sample_suffix


def prepare_remote_module_source(url, sample_url=None):
    """Validate, download, and resolve a remote module source for probe/convert routes."""
    if not is_safe_url(url) or (sample_url and not is_safe_url(sample_url)):
        return None, json_response({"error": "Unsafe or disallowed URL provided"}, 400)

    filename = extract_filename_from_url(url)
    url_hash = hashlib.md5(
        sanitized_url(url, log=False).encode(), usedforsecurity=False
    ).hexdigest()

    filename, suffix, sample_filename, sample_suffix = get_dual_file_module_filenames(filename)
    module_path = MODULES_DIR / f"{filename}_{url_hash}{suffix}"
    lock_path = module_path.with_suffix(f"{module_path.suffix}.lock")

    url_cache_hit = False
    if module_path.exists():
        url_cache_hit = True
        logger.info(f"Cache hit for module: {sanitized_url(url)}, using cached file: {module_path}")
        touch_for_lru(module_path)
    else:
        try:
            lock_path.touch(exist_ok=False)
            try:
                if not module_path.exists():
                    logger.info(f"Downloading: {sanitized_url(url)}")
                    temp_path = module_path.with_suffix(f"{module_path.suffix}.tmp")
                    success, error_response = download_and_limit_size(
                        url, temp_path, "External module"
                    )
                    if temp_path.exists():
                        Path.replace(temp_path, module_path)
                        logger.info(f"Moved partial/complete download to: {module_path}")
                    if not success:
                        return None, error_response
            finally:
                lock_path.unlink(missing_ok=True)
        except FileExistsError:
            logger.info(f"Download for {sanitized_url(url)} is already in progress, waiting...")
            for _ in range(20):
                time.sleep(1)
                if module_path.exists():
                    logger.info(
                        f"Cache hit for module completed by another thread: "
                        f"{sanitized_url(url)}, using cached file: {module_path}"
                    )
                    touch_for_lru(module_path)
                    url_cache_hit = True
                    break
            else:
                logger.warning(f"Timeout waiting for download of {sanitized_url(url)}.")
                return None, json_response({"error": "Timeout waiting for file download."}, 500)

    if not module_path.exists():
        return None, json_response({"error": "Failed to retrieve module file."}, 500)

    sample_files = []
    if sample_url and sample_url != url:
        if not sample_filename:
            sample_filename = extract_filename_from_url(sample_url)
        sample_url_hash = hashlib.md5(
            sanitized_url(sample_url, log=False).encode(), usedforsecurity=False
        ).hexdigest()

        sample_path = MODULES_DIR / f"{sample_filename}_{url_hash}{sample_suffix}"
        cached_sample_path = MODULES_DIR / f"{sample_filename}_{sample_url_hash}{sample_suffix}"
        sample_lock_path = cached_sample_path.with_suffix(f"{cached_sample_path.suffix}.lock")
        sample_files = [sample_path, cached_sample_path]

        if cached_sample_path.exists():
            if not sample_path.exists():
                sample_path.unlink(missing_ok=True)
                sample_path.symlink_to(cached_sample_path)
            logger.info(
                f"Cache hit for sample file: {sanitized_url(sample_url)}, "
                f"using cached file {cached_sample_path}, linking to {sample_path}"
            )
            touch_for_lru(cached_sample_path)
        else:
            try:
                sample_lock_path.touch(exist_ok=False)
                temp_path = module_path.with_suffix(f"{cached_sample_path.suffix}.tmp")
                success, error_response = download_and_limit_size(
                    sample_url, temp_path, "External sample"
                )
                if temp_path.exists():
                    Path.replace(temp_path, cached_sample_path)
                    logger.info(f"Moved partial/complete sample download to: {cached_sample_path}")
                if not success:
                    return None, error_response

                if sample_path.exists() or sample_path.is_symlink():
                    sample_path.unlink(missing_ok=True)
                sample_path.symlink_to(cached_sample_path)
                logger.info(f"Cached sample file: {cached_sample_path}, linking to {sample_path}")
            except FileExistsError:
                logger.info(
                    f"Download for {sanitized_url(cached_sample_path)} is already "
                    "in progress, waiting..."
                )
                for _ in range(20):
                    time.sleep(1)
                    if cached_sample_path.exists():
                        if not sample_path.exists():
                            sample_path.unlink(missing_ok=True)
                            sample_path.symlink_to(cached_sample_path)
                        logger.info(
                            f"Cache hit for sample file completed by another thread: "
                            f"{sanitized_url(sample_url)}, using cached file "
                            f"{cached_sample_path}, linking to {sample_path}"
                        )
                        touch_for_lru(cached_sample_path)
                        break
                else:
                    logger.warning(
                        f"Timeout waiting for download of {sanitized_url(cached_sample_path)}."
                    )
                    return None, json_response({"error": "Timeout waiting for file download."}, 500)
            finally:
                sample_lock_path.unlink(missing_ok=True)

    return {
        "module_path": module_path,
        "filename": filename,
        "sample_files": sample_files,
        "url_cache_hit": url_cache_hit,
    }, None


def convert_url_payload(data):
    """Shared logic for URL-backed module conversion requests."""
    if not isinstance(data, dict):
        return json_response({"error": "Invalid JSON body"}, 400)
    if "url" not in data:
        return json_response({"error": "No URL provided"}, 400)

    url = data["url"]
    sample_url = data.get("sample_url")

    try:
        # Check browser FLAC support
        user_agent = request.headers.get("User-Agent", "")
        use_flac = supports_flac(user_agent)
        remote_source, error_response = prepare_remote_module_source(url, sample_url)
        if error_response:
            return error_response
        return process_module_and_respond(
            remote_source["module_path"],
            remote_source["filename"],
            use_flac,
            url_cached=remote_source["url_cache_hit"],
            sample_files=remote_source["sample_files"],
        )

    except requests.RequestException:
        logger.error("Download error", exc_info=True)
        return json_response({"error": "Download failed"}, 500)
    except Exception:
        logger.error("Convert URL error", exc_info=True)
        return json_response({"error": "Internal server error during URL conversion"}, 500)


@app.route("/convert-url", methods=["POST"])
@limiter.limit("10 per minute")
def convert_url():
    """
    Download a module file from a given URL and convert it for playback.

    Supports an optional 'sample_url' parameter for dual-file (e.g., TFMX, RJP) modules.
    The request JSON should be:
        {
            "url": "<module file URL>",
            "sample_url": "<sample file URL>"  # Optional, only for dual-file modules
        }
    """
    cleanup_old_files()
    return convert_url_payload(request.get_json(silent=True))


def probe_url_payload(data):
    """Shared logic for URL-backed metadata probe requests."""
    if not isinstance(data, dict):
        return json_response({"error": "Invalid JSON body"}, 400)
    if "url" not in data:
        return json_response({"error": "No URL provided"}, 400)

    url = data["url"]
    sample_url = data.get("sample_url")

    try:
        remote_source, error_response = prepare_remote_module_source(url, sample_url)
        if error_response:
            return error_response
        return process_module_probe_response(
            remote_source["module_path"],
            remote_source["filename"],
            url_cached=remote_source["url_cache_hit"],
            sample_files=remote_source["sample_files"],
        )
    except requests.RequestException:
        logger.error("Probe download error", exc_info=True)
        return json_response({"error": "Download failed"}, 500)
    except Exception:
        logger.error("Probe URL error", exc_info=True)
        return json_response({"error": "Internal server error during URL probe"}, 500)


@app.route("/probe-url", methods=["POST"])
@limiter.limit("10 per minute")
def probe_url():
    """Validate a remote module and return metadata without converting audio."""
    cleanup_old_files()
    return probe_url_payload(request.get_json(silent=True))


def sanitized_url(url, *, log=True):
    """
    Sanitize URL for safe logging (removes control/meta chars, line breaks, trims, limits length)
    """
    if not isinstance(url, str):
        return "<non-string URL>"
    # Unquote percent-encodings (so %0d%0a becomes literal CR/LF and can be removed)
    try:
        url = urllib.parse.unquote(url)
    except Exception:
        logger.warning("Failed to unquote URL in sanitized_url", exc_info=True)
    # Normalize unicode to a consistent form
    url = unicodedata.normalize("NFKC", url)
    # Remove bidi controls and Unicode line/paragraph separators that can create fake lines
    url = re.sub(r"[\u202A-\u202E\u2066-\u2069\u2028\u2029]", "", url)
    # Remove ASCII control characters
    url = re.sub(r"[\x00-\x1f\x7f]", "", url)
    # Trim whitespace
    url = url.strip()
    if not log:
        return url
    # Replace remaining non-ASCII / non-printable with \uXXXX escapes so logs are unforgeable
    out_chars = []
    for ch in url:
        o = ord(ch)
        if ASCII_PRINTABLE_MIN <= o <= ASCII_PRINTABLE_MAX:
            out_chars.append(ch)
        else:
            out_chars.append(f"\\u{o:04x}")
    out = "".join(out_chars)
    if len(out) > SANITIZED_URL_LOG_MAX_LEN:
        out = out[:SANITIZED_URL_LOG_MAX_LEN] + "..."
    return out


def download_and_limit_size(url, temp_file_path, error_context=""):
    """
    Downloads a file from a given URL in chunks, enforcing the maximum allowed download size
    (MAX_DOWNLOAD_SIZE).

    This limit applies to all downloads, including LHA and ZIP archives fetched via URL.
    If the file exceeds the configured limit, the download is aborted and an error is returned.

    Important: When a download exceeds the size limit, the partial file is intentionally
    left on disk and moved to its final cache location. This enables URL caching -
    subsequent requests for the same URL will find the cached file and immediately
    return an error without re-downloading.
    This prevents repeated downloads of oversized files and protects against bandwidth abuse.

    Args:
        url (str): The URL to download.
        temp_file_path (Path): The path to save the downloaded file temporarily.
        error_context (str): Additional context for error messages (e.g., 'External sample',
                             'LHA archive').

    Returns:
        tuple: (True, None) on success, or (False, json_response) on failure.
    """
    downloaded_size = 0
    max_size = app.config["MAX_DOWNLOAD_SIZE"]

    try:
        # Set a proper User-Agent header
        headers = {
            "User-Agent": f"UADE-Web-Player/{GIT_COMMIT} (https://github.com/rib1/uade-docker)"
        }

        with requests.get(
            url,
            timeout=30,
            verify=not DISABLE_SSL_VERIFY,
            allow_redirects=True,
            stream=True,
            headers=headers,
        ) as response:
            response.raise_for_status()

            # Check Content-Length header first to avoid unnecessary downloads
            content_length = response.headers.get("content-length")
            if content_length:
                try:
                    content_length = int(content_length)
                    if content_length > max_size:
                        logger.error(
                            f"External download size ({content_length} bytes) exceeds limit "
                            f"before download ({error_context}): {sanitized_url(url)}"
                        )
                        # Create zero-byte file to cache that this URL is oversized
                        temp_file_path.touch()
                        return False, json_response(
                            {
                                "error": f"{error_context} file size exceeds the maximum "
                                f"allowed limit of {max_size / (1024 * 1024):.0f}MB"
                            },
                            413,
                        )
                except ValueError:
                    # Invalid Content-Length header, continue with chunked download
                    logger.info(
                        f"Invalid Content-Length header for {sanitized_url(url)}, "
                        "continuing with chunked download"
                    )

            try:
                with Path(temp_file_path).open("wb") as fd:
                    for chunk in response.iter_content(chunk_size=8192):
                        fd.write(chunk)
                        downloaded_size += len(chunk)
                        if downloaded_size > max_size:
                            response.close()
                            logger.error(
                                f"External download exceeded limit during download "
                                f"({error_context}): {sanitized_url(url)}"
                            )
                            return False, json_response(
                                {
                                    "error": f"{error_context} file size exceeds the maximum "
                                    f"allowed limit of {max_size / (1024 * 1024):.0f}MB"
                                },
                                413,
                            )
            except Exception:
                # Clean up partial file on any write error
                if temp_file_path.exists():
                    temp_file_path.unlink(missing_ok=True)
                raise

        return True, None

    except requests.HTTPError as exc:
        status_code = exc.response.status_code if exc.response is not None else None
        if temp_file_path.exists():
            temp_file_path.unlink(missing_ok=True)

        if status_code is not None and HTTP_CLIENT_ERROR_MIN <= status_code < HTTP_SERVER_ERROR_MIN:
            logger.warning(
                f"Remote fetch rejected for {sanitized_url(url)} ({error_context}) "
                f"with HTTP {status_code}"
            )
            return False, json_response(
                {"error": f"{error_context} URL could not be fetched"},
                HTTP_CLIENT_ERROR_MIN,
            )

        logger.error(f"Download failed for {sanitized_url(url)} ({error_context})", exc_info=True)
        return False, json_response(
            {"error": f"Download failed for {error_context}"}, HTTP_BAD_GATEWAY
        )
    except requests.RequestException:
        logger.error(f"Download failed for {sanitized_url(url)} ({error_context})", exc_info=True)
        # Clean up partial file
        if temp_file_path.exists():
            temp_file_path.unlink(missing_ok=True)
        return False, json_response(
            {"error": f"Download failed for {error_context}"}, HTTP_BAD_GATEWAY
        )
    except Exception:
        logger.error(
            f"Unexpected error during download for {sanitized_url(url)} ({error_context})",
            exc_info=True,
        )
        # Clean up partial file
        if temp_file_path.exists():
            temp_file_path.unlink(missing_ok=True)
        return False, json_response(
            {"error": f"Unexpected error during {error_context} download"}, 500
        )


def extract_filename_from_url(url):
    """
    Extract a safe filename from a URL.

    For ModArchive, gets the fragment filename.
    For Modland and similar, it gets the last path segment.
    For query-based URLs (Exotica, Scene.org), gets the last segment of the query path.
    Returns a normalized, secure filename string.
    """
    url_for_filename = sanitized_url(url, log=False)
    if url_for_filename.count("api.modarchive"):
        filename = url_for_filename.split("#")[-1]
    elif url_for_filename.count("?file=") or url_for_filename.count("get:"):
        filename = (
            url_for_filename.split("?file=")[-1].split("get:")[-1].split("/")[-1].split("?")[0]
        )
    else:
        filename = url_for_filename.split("/")[-1].split("?")[0]
    filename = filename[:100]  # Limit to 100 chars
    return secure_filename(filename) or "module"


@app.route("/play-example/<example_id>", methods=["POST"])
@limiter.limit("10 per minute")
def play_example(example_id):
    """Convert and play predefined example"""
    cleanup_old_files()

    example = next((ex for ex in EXAMPLES if ex["id"] == example_id), None)
    if not example:
        return json_response({"error": "Example not found"}, 404)

    # Prepare payload for convert_url
    payload = {"url": example["url"]}
    if "sample_url" in example:
        payload["sample_url"] = example["sample_url"]

    return convert_url_payload(payload)


@app.route("/play/<file_id>")
@limiter.limit("50 per minute")
def play_file(file_id):
    """Stream audio file for playback (FLAC or WAV) with range request support."""
    return serve_audio_file(file_id, as_attachment=False)


@app.route("/download/<file_id>")
@limiter.limit(
    f"{DOWNLOAD_RATE_LIMIT} per minute",
    exempt_when=lambda: request.headers.get("Range") is not None,
)
def download_file(file_id):
    """
    Download audio file (FLAC or WAV) with custom filename support.

    Client can pass ?filename=desired_name excluding extension to set the download filename.

    Rate limiting: Apply DOWNLOAD_RATE_LIMIT per minute only to initial requests (no Range header).
    Range requests for chunked downloads are exempt to avoid blocking large file downloads.
    """
    custom_filename = request.args.get("filename")
    if custom_filename:
        custom_filename = unicodedata.normalize("NFKC", custom_filename)
        custom_filename = secure_filename(custom_filename)[:100] or None
    return serve_audio_file(file_id, as_attachment=True, custom_filename=custom_filename)


def serve_audio_file(file_id, *, as_attachment=False, custom_filename=None):
    """
    Shared logic for serving audio files (FLAC/WAV) with range support.

    If as_attachment is True, sets Content-Disposition for download.
    Also checks remote cache if local file is missing.
    """
    if not re.fullmatch(r"[a-zA-Z0-9_-]+", file_id):
        return json_response({"error": "Invalid file_id"}, 400)
    # Sanitize file_id to ensure a safe filename
    safe_file_id = secure_filename(file_id)

    converted_dir_base = CONVERTED_DIR.resolve()
    try:
        file_path = None
        mimetype = None
        filename = None
        # Try FLAC first, then WAV
        for ext, mime in [(".flac", "audio/flac"), (".wav", "audio/wav")]:
            candidate_path = CONVERTED_DIR / f"{safe_file_id}{ext}"
            if not candidate_path.exists():
                # Fetch from cache (we don't need the metadata here)
                cached_file, _ = fetch_cached_file(safe_file_id, prefer_flac=(ext == ".flac"))
                if cached_file:
                    candidate_path = cached_file

            if candidate_path.exists():
                try:
                    # Verify path is within converted_dir_base
                    candidate_path.resolve().relative_to(converted_dir_base)
                    file_path = candidate_path.resolve()
                    mimetype = mime
                    # Use custom filename if provided, else fallback to default
                    if custom_filename:
                        filename = f"uade_{custom_filename}{ext}"
                    else:
                        filename = f"uade_{safe_file_id}{ext}"
                    break
                except ValueError:
                    logger.debug(
                        "Skipping candidate outside converted directory: %s",
                        candidate_path,
                    )

        if not file_path:
            return json_response({"error": "File not found or forbidden"}, 404)

    except Exception:
        logger.error(f"Error serving file {safe_file_id}", exc_info=True)
        return json_response({"error": "Internal server error"}, 500)

    file_size = file_path.stat().st_size

    # Handle range requests for large downloads (Cloud Run has 32MB response limit)
    range_header = request.headers.get("Range")
    range_info = parse_range_header(range_header, file_size)
    if range_info:
        start, end, length = range_info
        response = Response(stream_file_range(file_path, start, length), 206, mimetype=mimetype)
        # Custom header to indicate only single range requests are supported
        # (for client-side handling)
        response.headers["X-Single-Range-Only"] = "true"
        response.headers["Content-Range"] = f"bytes {start}-{end}/{file_size}"
        response.headers["Content-Length"] = str(length)
        response.headers["Accept-Ranges"] = "bytes"
        if as_attachment:
            response.headers["Content-Disposition"] = f'attachment; filename="{filename}"'
        else:
            # Set aggressive client-side cache for audio streaming: one month (2,592,000 seconds)
            # with the 'immutable' directive, as file_id refers to content-hashed, unchanging audio.
            response.headers["Cache-Control"] = "public, max-age=2592000, immutable"
        return response
    if range_header:
        # Malformed or invalid range
        return Response("", 416)
    # For large files without range header, return minimal 206 response to prompt client to
    # use range requests. This applies to both downloads and streaming to avoid exceeding
    # Cloud Run's 32MB response limit.
    # Client-side JavaScript handles downloads via range requests (see app.js)
    if file_size > 20 * 1024 * 1024:
        response = Response("", 206, mimetype=mimetype)
        # Custom header to indicate only single range requests are supported
        # (for client-side handling)
        response.headers["X-Single-Range-Only"] = "true"
        response.headers["Content-Range"] = f"bytes 0-0/{file_size}"
        response.headers["Content-Length"] = "0"
        response.headers["Accept-Ranges"] = "bytes"
        if as_attachment:
            response.headers["Content-Disposition"] = f'attachment; filename="{filename}"'
        return response
    # For small files without range header, stream the entire file
    response = Response(stream_full_file(file_path), mimetype=mimetype)
    response.headers["Content-Length"] = str(file_size)
    response.headers["Accept-Ranges"] = "bytes"
    if as_attachment:
        response.headers["Content-Disposition"] = f'attachment; filename="{filename}"'
    else:
        # Set aggressive client-side cache for audio streaming: one month (2,592,000 seconds)
        # with the 'immutable' directive, as file_id refers to content-hashed, unchanging audio.
        response.headers["Cache-Control"] = "public, max-age=2592000, immutable"
    return response


def stream_full_file(file_path, chunk_size=8192):
    """Yield the entire file in chunks (used for small file streaming)"""
    with Path(file_path).open("rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            yield chunk


def stream_file_range(file_path, start, length, chunk_size=8192):
    """Yield a byte range from a file (used for range requests)"""
    with Path(file_path).open("rb") as f:
        f.seek(start)
        remaining = length
        while remaining > 0:
            this_chunk = min(chunk_size, remaining)
            chunk = f.read(this_chunk)
            if not chunk:
                break
            remaining -= len(chunk)
            yield chunk


def parse_range_header(range_header, file_size):
    """
    Parse and validate a Range header for a file of given size.

    Returns (start, end, length) if valid, else None.
    Only supports single range: bytes=start-end
    """
    if not range_header:
        return None
    range_match = re.match(r"^bytes=(\d*)-(\d*)$", range_header.strip())
    if not range_match:
        return None
    start_str, end_str = range_match.groups()
    try:
        start = int(start_str) if start_str else 0
    except ValueError:
        return None
    try:
        end = int(end_str) if end_str else file_size - 1
    except ValueError:
        return None
    # Validation: start/end must be within file bounds
    if start < 0 or end < 0 or end < start or start >= file_size:
        return None
    if end >= file_size:
        end = file_size - 1
    # Limit chunk size to 20MB to stay well under Cloud Run's 32MB limit
    if end - start > 20 * 1024 * 1024:
        end = start + 20 * 1024 * 1024 - 1
    length = end - start + 1
    return start, end, length


logger.info(
    "Starting UADE Web Player "
    f"(commit: {GIT_COMMIT}, build_time: {IMAGE_BUILD_TIME}) on port {PORT}"
)
logger.info(f"Max upload size: {MAX_UPLOAD_SIZE / 1024 / 1024}MB")
logger.info(f"Max download size: {MAX_DOWNLOAD_SIZE / 1024 / 1024}MB")
logger.info(f"Rate limit: {RATE_LIMIT}/hour (enabled: {rate_limit_enabled})")
logger.info(f"Cache URI: {CACHE_URI}")
logger.info(f"Cleanup interval: {CLEANUP_INTERVAL}s")
logger.info(f"Cache cleanup interval: {CACHE_CLEANUP_INTERVAL}s")

# Clean up cache files once at startup (runs in all environments)
cleanup_cache_files()

if __name__ == "__main__":
    hot_reload_enabled = os.getenv("FLASK_DEBUG", "0") == "1"
    # Only the dedicated development compose path should enable Flask reload/debug mode.
    app.run(host="0.0.0.0", port=PORT, debug=hot_reload_enabled, use_reloader=hot_reload_enabled)
