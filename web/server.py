#!/usr/bin/env python3
"""
UADE Web Player - Flask Server
Converts Amiga music modules to FLAC or WAV for browser playback
Cloud-ready with proper logging, error handling, stateless caching, and cleanup
"""

import os
import uuid
import time
import subprocess
import logging
import hashlib
from pathlib import Path
from datetime import datetime, timezone
from flask import Flask, request, jsonify, send_from_directory, Response
from werkzeug.utils import secure_filename
from typing import Final
import requests
import re
import shutil
import fsspec
import zipfile
import urllib.parse
import socket
import ipaddress
import unicodedata

# Configure logging for cloud environments
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

app = Flask(__name__, static_folder="static")


# Get git commit hash for version tracking
def get_git_commit():
    """Get current git commit hash"""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            capture_output=True,
            text=True,
            timeout=2,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        # Ignore errors (e.g., not a git repo, git not installed); fallback to env var
        pass
    return os.getenv("GIT_COMMIT", "unknown")


GIT_COMMIT: Final = get_git_commit()
# Configuration from environment variables (cloud-ready)
MAX_UPLOAD_SIZE: Final = int(os.getenv("MAX_UPLOAD_SIZE", 10485760))  # 10MB
CLEANUP_INTERVAL: Final = int(os.getenv("CLEANUP_INTERVAL", 3600))  # 1 hour
CACHE_CLEANUP_INTERVAL: Final = int(
    os.getenv("CACHE_CLEANUP_INTERVAL", 86400)
)  # 24 hours
RATE_LIMIT: Final = int(os.getenv("RATE_LIMIT", 10))
PORT: Final = int(os.getenv("PORT", 5000))
app.config["MAX_CONTENT_LENGTH"] = MAX_UPLOAD_SIZE

# Local directories for processing
MODULES_DIR: Final = Path("/tmp/modules")
CONVERTED_DIR: Final = Path("/tmp/converted")


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
CACHE_URI: Final = os.getenv("CACHE_URI", "file:///tmp/cache")
fs_cache, root_cache = get_fs_and_root(CACHE_URI)

# Shared forbidden characters regex for filename and URL sanitization
FORBIDDEN_CHARS: Final = r'[ \t\n\r\x00-\x1f"\'`;|&$<>\\]'

for directory in [MODULES_DIR, CONVERTED_DIR]:
    directory.mkdir(parents=True, exist_ok=True)

# Find music files (common Amiga module extensions and prefixes)
music_extensions: Final = {
    "aam",
    "ahx",
    "aon",
    "bp",
    "bp3",
    "bd",
    "bds",
    "bsi",
    "bss",
    "cm",
    "cust",
    "digi",
    "dll",
    "dmu",
    "dw",
    "fc",
    "fred",
    "gray",
    "hip",
    "hip7",
    "hipc",
    "hvl",
    "instr",
    "jt",
    "mdat",
    "med",
    "mmd0",
    "mmd1",
    "mmd2",
    "mmd3",
    "mmdc",
    "mod",
    "okta",
    "rk",
    "sc",
    "sid",
    "smpl",
    "smus",
    "sng",
    "ss",
    "ssd",
    "sun",
    "tf",
    "tfmx",
    "ym",
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
        "mdat_url": "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.turrican%202%20level%200-intro",
        "smpl_url": "https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.turrican%202%20level%200-intro",
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
            "http://files.exotica.org.uk/?file=exotica%2Fmedia%2Faudio%2FUnExoticA%2FGame%2FFollin_Tim%2FL_E_D_Storm.lha"
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


def cleanup_old_files():
    """Remove files older than CLEANUP_INTERVAL from local directories"""
    try:
        cutoff = time.time() - CLEANUP_INTERVAL
        removed = 0
        for directory in [MODULES_DIR, CONVERTED_DIR]:
            # Remove symlinks first
            for filepath in directory.glob("*"):
                if filepath.is_symlink() and filepath.stat().st_mtime < cutoff:
                    filepath.unlink()
                    logger.info(f"Cleaned up old symlink: {filepath}")
                    removed += 1
            for filepath in directory.glob("*"):
                if filepath.stat().st_mtime < cutoff:
                    filepath.unlink()
                    logger.info(f"Cleaned up old file: {filepath}")
                    removed += 1
        if removed == 0:
            logger.info("No old files to clean up in local directories.")
    except Exception as e:
        logger.error(f"Cleanup error: {e}")


def cleanup_cache_files():
    """Remove files older than CACHE_CLEANUP_INTERVAL from remote cache (supports file, s3, gcs)"""
    logger.info("cleanup_cache_files called at startup")
    try:
        cutoff = time.time() - CACHE_CLEANUP_INTERVAL
        removed = 0
        # List all files in cache root
        for cache_file in fs_cache.glob(f"{root_cache}/*"):
            try:
                info = fs_cache.info(cache_file)
                mtime = info.get("mtime") or info.get("LastModified")
                # mtime may be a timestamp or datetime string
                if isinstance(mtime, str):
                    # Try to parse ISO8601 or RFC format
                    try:
                        from dateutil.parser import parse as dtparse

                        mtime_ts = dtparse(mtime).timestamp()
                    except Exception:
                        mtime_ts = 0
                else:
                    mtime_ts = float(mtime) if mtime is not None else 0
                if mtime_ts < cutoff:
                    fs_cache.rm_file(cache_file)
                    logger.info(f"Cleaned up old cache file: {cache_file}")
                    removed += 1
            except Exception as e:
                logger.warning(f"Cache cleanup error for {cache_file}: {e}")
        if removed == 0:
            logger.info("No old files to clean up in remote cache.")
    except Exception as e:
        logger.error(f"Cache cleanup error: {e}")


def get_file_hash(file_path):
    """Calculate MD5 hash of a file for caching"""
    md5 = hashlib.md5(usedforsecurity=False)  # Only used for caching, not security
    with open(file_path, "rb") as f:
        for chunk in iter(lambda: f.read(4096), b""):
            md5.update(chunk)
    return md5.hexdigest()


def supports_flac(user_agent):
    """Check if browser supports FLAC playback"""
    # Modern browsers that support FLAC natively
    ua = user_agent.lower()
    flac_browsers = ["chrome", "chromium", "edge", "firefox", "safari"]
    return any(browser in ua for browser in flac_browsers)


def compress_to_flac(wav_path, flac_path):
    """Compress WAV to FLAC format"""
    try:
        cmd = ["flac", "--best", "--silent", "-f", "-o", str(flac_path), str(wav_path)]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)

        if result.returncode == 0 and flac_path.exists():
            logger.info(
                f"Compressed to FLAC: {wav_path} -> {flac_path} "
                f"({flac_path.stat().st_size / wav_path.stat().st_size:.1%} of original)"
            )
            return True
        else:
            logger.error(f"FLAC compression failed: {result.stderr}")
            return False
    except Exception as e:
        logger.error(f"FLAC compression exception: {e}")
        return False


def find_music_file(extract_dir):
    """Find and return the first music file in a directory matching known extensions or prefixes."""
    music_files = []
    for file_path in extract_dir.rglob("*"):
        if file_path.is_file():
            ext = file_path.suffix.lower()[1:]
            prefix = file_path.name.lower().split(".")[0]
            if ext in music_extensions or prefix in music_extensions:
                music_files.append(file_path)
    if not music_files:
        return None, 0
    return music_files[0], len(music_files)


def is_lha_file(file_path):
    """Check if file is an LHA archive by magic bytes"""
    try:
        with open(file_path, "rb") as f:
            # LHA files have signature at offset 2: '-lh' or '-lz'
            header = f.read(20)
            if len(header) >= 7:
                signature = header[2:5]
                return signature == b"-lh" or signature == b"-lz"
        return False
    except Exception:
        return False


def is_zip_file(file_path):
    """Check if file is a ZIP archive by magic bytes"""
    try:
        with open(file_path, "rb") as f:
            header = f.read(4)
            # ZIP files start with PK\x03\x04 or PK\x05\x06 or PK\x07\x08
            return header[:2] == b"PK"
    except Exception:
        return False


def extract_lha(lha_path, extract_dir):
    """Extract LHA archive and return first music file found
    Returns: (success, error_message, music_file_path or None)
    """
    try:
        extract_dir.mkdir(parents=True, exist_ok=True)

        # Change to extract directory and run lha extraction
        cmd = ["lha", "x", str(lha_path)]
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=30, cwd=str(extract_dir)
        )

        if result.returncode != 0:
            logger.error(f"LHA extraction error: {result.stderr}")
            return False, f"LHA extraction failed: {result.stderr}", None

        music_file, count = find_music_file(extract_dir)
        if not music_file:
            return False, "No music files found in LHA archive", None

        logger.info(
            f"Extracted LHA archive, found {count} music file(s), using: {music_file.name}"
        )
        return True, None, music_file

    except subprocess.TimeoutExpired:
        return False, "LHA extraction timeout", None
    except Exception as e:
        logger.error(f"LHA extraction exception: {e}")
        return False, str(e), None


def extract_zip(zip_path, extract_dir):
    """Extract ZIP archive and return first music file found
    Returns: (success, error_message, music_file_path or None)
    """
    try:
        extract_dir.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(zip_path, "r") as zip_ref:
            zip_ref.extractall(extract_dir)

        music_file, count = find_music_file(extract_dir)
        if not music_file:
            return False, "No music files found in ZIP archive", None

        logger.info(
            f"Extracted ZIP archive, found {count} music file(s), using: {music_file.name}"
        )
        return True, None, music_file

    except zipfile.BadZipFile:
        return False, "ZIP extraction failed: Bad ZIP file", None
    except Exception as e:
        logger.error(f"ZIP extraction exception: {e}")
        return False, str(e), None


def save_to_cache(cache_hash, file, ext):
    """Save a converted file to remote cache (WAV or FLAC)."""
    cache_file_remote = f"{root_cache}/{cache_hash}{ext}"
    # Ensure remote cache directory exists (for local file cache)
    if fs_cache.protocol == "file":
        cache_dir_remote = Path(root_cache)
        cache_dir_remote.mkdir(parents=True, exist_ok=True)
    if not fs_cache.exists(cache_file_remote):
        with open(file, "rb") as src, fs_cache.open(cache_file_remote, "wb") as dst:
            shutil.copyfileobj(src, dst, length=1024 * 1024)  # 1MB buffer
        logger.info(f"Cached conversion to remote: {cache_hash}{ext}")


def fetch_cached_file(cache_hash, prefer_flac=False):
    """Check if a converted file exists in remote cache (WAV or FLAC). If found, copy to local and return local path."""
    # Try FLAC first if preferred
    for ext in ([".flac"] if prefer_flac else []) + [".wav"]:
        cache_file_remote = f"{root_cache}/{cache_hash}{ext}"
        cache_file_local = CONVERTED_DIR / f"{cache_hash}{ext}"
        if fs_cache.exists(cache_file_remote):
            remote_size = fs_cache.size(cache_file_remote)
            if (
                cache_file_local.exists()
                and cache_file_local.stat().st_size == remote_size
            ):
                logger.info(
                    f"Cache hit ({ext[1:].upper()}): {cache_hash} already exists locally"
                )
                return cache_file_local
            # Ensure local cache directory exists
            cache_dir_local = cache_file_local.parent
            cache_dir_local.mkdir(parents=True, exist_ok=True)
            # Copy from remote cache to local
            with fs_cache.open(cache_file_remote, "rb") as src, open(
                cache_file_local, "wb"
            ) as dst:
                shutil.copyfileobj(src, dst, length=1024 * 1024)  # 1MB buffer
            logger.info(
                f"Cache hit ({ext[1:].upper()}): {cache_hash} from remote cache"
            )
            return cache_file_local
    return None


def detect_player_format(input_path):
    """Detect the player format of a module using uade123 -g"""
    try:
        cmd = ["/usr/local/bin/uade123", "-g", str(input_path)]  # Get info only
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)

        # Check for 'uade:is_custom': True in output
        if "'uade:is_custom': True" in result.stdout:
            return "Custom"

        # Parse output to extract player name
        # output format: "playername: PlayerName"
        for line in result.stdout.splitlines():
            if line.startswith("playername:"):
                player_name = line.split(":", 1)[1].strip()
                return player_name if player_name else "Module"

        # If no player name found, return generic
        return "Module"

    except Exception as e:
        logger.warning(f"Could not detect player format: {e}")
        return "Module"


def process_audio_conversion(input_path, use_cache=True, compress_flac=False):
    """Convert module to WAV using UADE with optional caching and FLAC compression
    Returns: (success, error, final_file, player_format)
    """
    try:
        # Defensive: Restrict input_path to MODULES_DIR
        input_resolved = Path(input_path).resolve()
        if not (input_resolved.is_relative_to(MODULES_DIR.resolve())):
            logger.error("Aborting: attempted read outside allowed directories")
            return False, "Illegal input file path", None, None
        # Detect player format before conversion
        player_format = detect_player_format(input_path)
        # Always compute cache_hash for later use
        cache_hash = get_file_hash(input_path)
        # Output path is always in CONVERTED_DIR
        output_path = CONVERTED_DIR / f"{cache_hash}.wav"
        # Check remote cache first
        if use_cache:
            cached_file = fetch_cached_file(cache_hash, prefer_flac=compress_flac)
            if cached_file and cached_file.exists():
                return True, None, cached_file, player_format

        cmd = [
            "/usr/local/bin/uade123",
            "-c",
            "-f",
            str(output_path),
            str(input_path),
        ]  # Headless mode

        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=300
        )  # 5 minute timeout

        if result.returncode != 0:
            logger.error(f"UADE error: {result.stderr}")
            return False, f"Conversion failed: {result.stderr}", None, None

        if not output_path.exists():
            return (
                False,
                "Conversion failed: Output file not created",
                None,
                None,
            )

        final_output = output_path

        # Compress to FLAC if requested
        if compress_flac:
            flac_output = output_path.with_suffix(".flac")
            if compress_to_flac(output_path, flac_output):
                final_output = flac_output
        # Save to remote cache
        if use_cache:
            ext, file_to_save = (
                (".flac", final_output) if compress_flac else (".wav", output_path)
            )
            save_to_cache(cache_hash, file_to_save, ext)
        logger.info(f"Successfully converted: {input_path} -> {final_output}")
        return True, None, final_output, player_format

    except subprocess.TimeoutExpired:
        return False, "Conversion timeout (5 minutes exceeded)", None, None
    except Exception as e:
        logger.error(f"Conversion exception: {e}")
        return False, str(e), None, None


@app.route("/")
def index():
    """Serve main page"""
    return send_from_directory("static", "index.html")


@app.route("/health")
def health():
    """Health check for load balancers"""
    response = jsonify(
        {
            "status": "healthy",
            "version": GIT_COMMIT,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "uade_available": Path("/usr/local/bin/uade123").exists(),
        }
    )
    response.headers["Content-Type"] = "application/json; charset=utf-8"
    return response


@app.route("/examples")
def get_examples():
    """Return list of example modules"""
    response = jsonify(EXAMPLES)
    response.headers["Content-Type"] = "application/json; charset=utf-8"
    return response


@app.route("/upload", methods=["POST"])
def upload_file():
    """Handle file upload and conversion"""
    cleanup_old_files()

    if "file" not in request.files:
        response = jsonify({"error": "No file provided"})
        response.headers["Content-Type"] = "application/json; charset=utf-8"
        return response, 400

    file = request.files["file"]
    if file.filename == "":
        response = jsonify({"error": "No file selected"})
        response.headers["Content-Type"] = "application/json; charset=utf-8"
        return response, 400

    try:
        # Check browser FLAC support
        user_agent = request.headers.get("User-Agent", "")
        use_flac = supports_flac(user_agent)

        # Generate unique ID
        file_id = str(uuid.uuid4())
        filename = secure_filename(file.filename)

        # Save uploaded file
        upload_path = MODULES_DIR / f"{filename}_{file_id}"
        file.save(upload_path)

        # Cache hash for later use
        converted_file_id = get_file_hash(upload_path)

        # Check if it's an LHA or ZIP archive
        module_path = upload_path
        extract_dir = None
        if is_lha_file(upload_path):
            logger.info(f"Detected LHA archive upload: {filename}")
            extract_dir = MODULES_DIR / f"{file_id}_extracted"
            success, error, music_file = extract_lha(upload_path, extract_dir)

            if not success:
                upload_path.unlink(missing_ok=True)
                if extract_dir and extract_dir.exists():
                    shutil.rmtree(extract_dir, ignore_errors=True)
                return jsonify({"error": error}), 500

            module_path = music_file
            filename = music_file.name
        elif is_zip_file(upload_path):
            logger.info(f"Detected ZIP archive upload: {filename}")
            extract_dir = MODULES_DIR / f"{file_id}_extracted"
            success, error, music_file = extract_zip(upload_path, extract_dir)

            if not success:
                upload_path.unlink(missing_ok=True)
                if extract_dir and extract_dir.exists():
                    shutil.rmtree(extract_dir, ignore_errors=True)
                return jsonify({"error": error}), 500

            module_path = music_file
            filename = music_file.name

        # Convert to WAV (and optionally FLAC)
        success, error, final_file, player_format = process_audio_conversion(
            module_path, compress_flac=use_flac
        )

        # Clean up input files
        upload_path.unlink(missing_ok=True)
        if extract_dir and extract_dir.exists():
            shutil.rmtree(extract_dir, ignore_errors=True)

        if not success:
            response = jsonify({"error": error})
            response.headers["Content-Type"] = "application/json; charset=utf-8"
            return response, 500

        response = jsonify(
            {
                "success": True,
                "file_id": converted_file_id,
                "filename": filename,
                "player_format": player_format,
                "audio_format": final_file.suffix[1:] if final_file else "wav",
                "play_url": f"/play/{converted_file_id}",
                "download_url": f"/download/{converted_file_id}",
            }
        )
        response.headers["Content-Type"] = "application/json; charset=utf-8"
        return response

    except Exception as e:
        logger.error(f"Upload error: {e}")
    response = jsonify({"error": str(e)})
    response.headers["Content-Type"] = "application/json; charset=utf-8"
    return response, 500


def is_safe_url(u):
    """Reject private/LAN/loopback/non-HTTP(S) URLs for SSRF defense, including IDN/punycode normalization."""
    try:
        # Prepare a safe, normalized string for logging
        sanitized_url_for_log = sanitized_url(u)

        parsed = urllib.parse.urlparse(u)
        if parsed.scheme not in ("http", "https"):
            logger.warning(
                f"is_safe_url: rejected scheme '{parsed.scheme}' for URL: {sanitized_url_for_log}"
            )
            return False
        if not parsed.hostname:
            logger.warning(
                f"is_safe_url: missing hostname in URL: {sanitized_url_for_log}"
            )
            return False
        # Normalize hostname for Unicode/punycode edge cases
        try:
            normalized_hostname = parsed.hostname.encode("idna").decode("ascii")
        except Exception:
            logger.warning(
                f"is_safe_url: failed to normalize hostname '{parsed.hostname}' in URL: {sanitized_url_for_log}"
            )
            normalized_hostname = parsed.hostname
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
            except Exception as e:
                logger.warning(
                    f"is_safe_url: failed to resolve domain '{normalized_hostname}' in URL: {sanitized_url_for_log} ({e})"
                )
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
                logger.warning(
                    f"is_safe_url: rejected IP '{ip}' for URL: {sanitized_url_for_log}"
                )
                return False
        # All checks passed
        logger.info(f"is_safe_url: accepted URL: {sanitized_url_for_log}")
        return True
    except Exception as e:
        logger.error(f"is_safe_url: exception for URL '{sanitized_url_for_log}': {e}")
        return False


@app.route("/convert-url", methods=["POST"])
def convert_url():
    """Download from URL and convert, supports optional sample URL for TFMX"""
    cleanup_old_files()

    data = request.get_json()
    if not data or "url" not in data:
        response = jsonify({"error": "No URL provided"})
        response.headers["Content-Type"] = "application/json; charset=utf-8"
        return response, 400

    url = data["url"]
    sample_url = data.get("sample_url")

    if not is_safe_url(url) or (sample_url and not is_safe_url(sample_url)):
        response = jsonify({"error": "Unsafe or disallowed sample_url"})
        response.headers["Content-Type"] = "application/json; charset=utf-8"
        return response, 400

    try:
        # Check browser FLAC support
        user_agent = request.headers.get("User-Agent", "")
        use_flac = supports_flac(user_agent)
        # Generate unique ID
        file_id = str(uuid.uuid4())

        # --- Caching logic for main module file ---
        raw_filename = url.split("/")[-1].split("#")[0].split("?")[0] or "module"
        # Unquote and normalize filename, then use werkzeug's secure_filename
        try:
            unquoted = urllib.parse.unquote(raw_filename)
        except Exception:
            unquoted = raw_filename
        normalized = unicodedata.normalize("NFKC", unquoted)
        filename = secure_filename(normalized) or "module"
        # Compute cache hash from URL
        url_hash = hashlib.md5(url.encode(), usedforsecurity=False).hexdigest()
        module_path = MODULES_DIR / f"{filename}_{url_hash}"

        if module_path.exists():
            logger.info(
                f"Cache hit for module: {sanitized_url(url)}, using cached file: {module_path}"
            )
        else:
            logger.info(f"Downloading: {sanitized_url(url)}")
            # nosec B501 - Trade-off for HTTP module downloads
            response = requests.get(url, timeout=30, verify=False, allow_redirects=True)
            response.raise_for_status()
            # Save downloaded file to cache
            module_path.write_bytes(response.content)
            logger.info(f"Cached module_path: {module_path}")

        # --- Caching logic for TFMX sample file ---
        sample_path = None
        if sample_url and sample_url != url:
            sample_url_hash = hashlib.md5(
                sample_url.encode(), usedforsecurity=False
            ).hexdigest()
            # Ensure filename matches mdat except for prefix
            if filename.startswith("mdat"):
                smplfilename = "smpl" + filename[4:]
            else:
                smplfilename = "smpl." + filename
            sample_path = MODULES_DIR / f"{smplfilename}_{url_hash}"
            cached_sample_path = MODULES_DIR / f"{smplfilename}_{sample_url_hash}"
            if cached_sample_path.exists():
                if sample_path.exists() or sample_path.is_symlink():
                    sample_path.unlink(missing_ok=True)
                os.symlink(cached_sample_path, sample_path)
                logger.info(
                    f"Cache hit for TFMX sample: {sanitized_url(sample_url)}, using cached file {cached_sample_path}, linking to {sample_path}"
                )
            else:
                logger.info(f"Downloading TFMX sample: {sanitized_url(sample_url)}")
                sample_response = requests.get(
                    sample_url, timeout=30, verify=False, allow_redirects=True
                )
                sample_response.raise_for_status()
                cached_sample_path.write_bytes(sample_response.content)
                os.symlink(cached_sample_path, sample_path)
                logger.info(
                    f"Cached sample_path: {cached_sample_path}, linking to {sample_path}"
                )

        # Check if it's an LHA or ZIP archive
        extract_dir = None
        if is_lha_file(module_path):
            logger.info(f"Detected LHA archive: {filename}")
            extract_dir = MODULES_DIR / f"{file_id}_extracted"
            success, error, music_file = extract_lha(module_path, extract_dir)
            if not success:
                # Do not delete cached_module_path on error
                if extract_dir and extract_dir.exists():
                    shutil.rmtree(extract_dir, ignore_errors=True)
                response = jsonify({"error": error})
                response.headers["Content-Type"] = "application/json; charset=utf-8"
                return response, 500
            filename = music_file.name
            module_path = music_file
        elif is_zip_file(module_path):
            logger.info(f"Detected ZIP archive: {filename}")
            extract_dir = MODULES_DIR / f"{file_id}_extracted"
            success, error, music_file = extract_zip(module_path, extract_dir)
            if not success:
                # Do not delete cached_module_path on error
                if extract_dir and extract_dir.exists():
                    shutil.rmtree(extract_dir, ignore_errors=True)
                response = jsonify({"error": error})
                response.headers["Content-Type"] = "application/json; charset=utf-8"
                return response, 500
            filename = music_file.name
            module_path = music_file

        # cache hash
        converted_file_id = get_file_hash(module_path)

        # Convert to WAV (and optionally FLAC)
        success, error, final_file, player_format = process_audio_conversion(
            module_path, compress_flac=use_flac
        )

        # Clean up extracted files only (do not delete cached files)
        if extract_dir and extract_dir.exists():
            shutil.rmtree(extract_dir, ignore_errors=True)
        if not success:
            return jsonify({"error": error}), 500

        response = jsonify(
            {
                "success": True,
                "file_id": converted_file_id,
                "filename": filename,
                "player_format": player_format,
                "audio_format": final_file.suffix[1:] if final_file else "wav",
                "play_url": f"/play/{converted_file_id}",
                "download_url": f"/download/{converted_file_id}",
            }
        )
        response.headers["Content-Type"] = "application/json; charset=utf-8"
        return response

    except requests.RequestException as e:
        logger.error(f"Download error: {e}")
        response = jsonify({"error": f"Download failed: {str(e)}"})
        response.headers["Content-Type"] = "application/json; charset=utf-8"
        return response, 500
    except Exception as e:
        logger.error(f"Convert URL error: {e}")
        response = jsonify({"error": str(e)})
        response.headers["Content-Type"] = "application/json; charset=utf-8"
        return response, 500


def sanitized_url(url):
    """Sanitize URL for safe logging (removes control/meta chars, line breaks, trims, limits length)"""
    if not isinstance(url, str):
        return "<non-string URL>"
    # Unquote percent-encodings (so %0d%0a becomes literal CR/LF and can be removed)
    try:
        url = urllib.parse.unquote(url)
    except Exception:
        pass
    # Normalize unicode to a consistent form
    url = unicodedata.normalize("NFKC", url)
    # Remove bidi controls and Unicode line/paragraph separators that can create fake lines
    url = re.sub(r"[\u202A-\u202E\u2066-\u2069\u2028\u2029]", "", url)
    # Remove ASCII control characters
    url = re.sub(r"[\x00-\x1f\x7f]", "", url)
    # Trim whitespace
    url = url.strip()
    # Replace remaining non-ASCII / non-printable with \uXXXX escapes so logs are unforgeable
    out_chars = []
    for ch in url:
        o = ord(ch)
        if 0x20 <= o <= 0x7E:
            out_chars.append(ch)
        else:
            out_chars.append("\\u%04x" % o)
    out = "".join(out_chars)
    if len(out) > 200:
        out = out[:200] + "..."
    return out


@app.route("/play-example/<example_id>", methods=["POST"])
def play_example(example_id):
    """Convert and play predefined example"""
    cleanup_old_files()

    example = next((ex for ex in EXAMPLES if ex["id"] == example_id), None)
    if not example:
        return jsonify({"error": "Example not found"}), 404

    # Prepare payload for convert_url
    if example["type"] == "tfmx":
        payload = {"url": example["mdat_url"], "sample_url": example["smpl_url"]}
    else:
        payload = {"url": example["url"]}

    # Directly call convert_url with the payload
    # Save and restore request._cached_json to avoid side effects
    old_json = getattr(request, "_cached_json", None)
    request._cached_json = (payload, None)
    result = convert_url()
    request._cached_json = old_json
    return result


@app.route("/play/<file_id>")
def play_file(file_id):
    """
    Stream audio file for playback (FLAC or WAV) with range request support.
    """
    return serve_audio_file(file_id, as_attachment=False)


@app.route("/download/<file_id>")
def download_file(file_id):
    """Download audio file (FLAC or WAV) - large files may require a download manager"""
    return serve_audio_file(file_id, as_attachment=True)


def serve_audio_file(file_id, as_attachment=False):
    """
    Shared logic for serving audio files (FLAC/WAV) with range support.
    If as_attachment is True, sets Content-Disposition for download.
    Also checks remote cache if local file is missing.
    """
    if not re.fullmatch(r"[a-zA-Z0-9_-]+", file_id):
        return jsonify({"error": "Invalid file_id"}), 400
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
                fetch_cached_file(safe_file_id, prefer_flac=(ext == ".flac"))
            if candidate_path.exists() and candidate_path.resolve().relative_to(
                converted_dir_base
            ):
                file_path = candidate_path.resolve()
                mimetype = mime
                filename = f"uade_{safe_file_id}{ext}"
                break
        if not file_path:
            return jsonify({"error": "File not found or forbidden"}), 404
    except ValueError:
        # Path not contained within converted_dir_base
        return jsonify({"error": "File not found or forbidden"}), 404

    file_size = file_path.stat().st_size

    # Handle range requests for large downloads (Cloud Run has 32MB response limit)
    range_header = request.headers.get("Range")
    range_info = parse_range_header(range_header, file_size)
    if range_info:
        start, end, length = range_info
        response = Response(
            stream_file_range(file_path, start, length), 206, mimetype=mimetype
        )
        # Custom header to indicate that only single range requests are supported (for client-side handling)
        response.headers["X-Single-Range-Only"] = "true"
        response.headers["Content-Range"] = f"bytes {start}-{end}/{file_size}"
        response.headers["Content-Length"] = str(length)
        response.headers["Accept-Ranges"] = "bytes"
        if as_attachment:
            response.headers["Content-Disposition"] = (
                f'attachment; filename="{filename}"'
            )
        else:
            response.headers["Cache-Control"] = "public, max-age=3600"
        return response
    elif range_header:
        # Malformed or invalid range
        return Response("", 416)
    else:
        if not as_attachment and file_size > 20 * 1024 * 1024:
            # For large files without range header, return minimal 206 response to prompt client to use range requests
            response = Response("", 206, mimetype=mimetype)
            # Custom header to indicate that only single range requests are supported (for client-side handling)
            response.headers["X-Single-Range-Only"] = "true"
            response.headers["Content-Range"] = f"bytes 0-0/{file_size}"
            response.headers["Content-Length"] = "0"
            response.headers["Accept-Ranges"] = "bytes"
            return response
        # For requests without range header, stream the entire file
        # Browsers will automatically use range requests for large files when needed
        response = Response(stream_full_file(file_path), mimetype=mimetype)
        response.headers["Content-Length"] = str(file_size)
        response.headers["Accept-Ranges"] = "bytes"
        if as_attachment:
            response.headers["Content-Disposition"] = (
                f'attachment; filename="{filename}"'
            )
        else:
            response.headers["Cache-Control"] = "public, max-age=3600"
        return response


def stream_full_file(file_path, chunk_size=8192):
    """Yield the entire file in chunks (used for small file streaming)"""
    with open(file_path, "rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            yield chunk


def stream_file_range(file_path, start, length, chunk_size=8192):
    """Yield a byte range from a file (used for range requests)"""
    with open(file_path, "rb") as f:
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


logger.info(f"Starting UADE Web Player (commit: {GIT_COMMIT}) on port {PORT}")
logger.info(f"Max upload size: {MAX_UPLOAD_SIZE / 1024 / 1024}MB")
logger.info(f"Cleanup interval: {CLEANUP_INTERVAL}s")
logger.info(f"Cache cleanup interval: {CACHE_CLEANUP_INTERVAL}s")

# Clean up cache files once at startup (runs in all environments)
cleanup_cache_files()

if __name__ == "__main__":
    # Development server (Docker Compose overrides this with gunicorn)
    app.run(host="0.0.0.0", port=PORT, debug=False)
