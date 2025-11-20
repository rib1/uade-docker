#!/usr/bin/env python3
"""
UADE Web Player - Flask Server
Converts Amiga music modules to FLAC or WAV for browser playback
Cloud-ready with proper logging, error handling, and cleanup
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
import zipfile
import fsspec

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
        pass
    return os.getenv("GIT_COMMIT", "unknown")


GIT_COMMIT = get_git_commit()
logger.info(f"Starting UADE Web Player (commit: {GIT_COMMIT})")

# Configuration from environment variables (cloud-ready)
MAX_UPLOAD_SIZE = int(os.getenv("MAX_UPLOAD_SIZE", 10485760))  # 10MB
CLEANUP_INTERVAL = int(os.getenv("CLEANUP_INTERVAL", 3600))  # 1 hour
RATE_LIMIT = int(os.getenv("RATE_LIMIT", 10))
PORT = int(os.getenv("PORT", 5000))

app.config["MAX_CONTENT_LENGTH"] = MAX_UPLOAD_SIZE

def get_fs_and_root(uri, fs_kwargs=None):
    fs_kwargs = fs_kwargs or {}
    # Detect S3 URI for remote storage support
    if uri.startswith('s3://'):
        fs = fsspec.filesystem('s3', **fs_kwargs)
        root = uri[5:]
    elif uri.startswith('gcs://'):
        fs = fsspec.filesystem('gcs', **fs_kwargs)
        root = uri[6:]
    else:
        fs = fsspec.filesystem('file')
        root = uri
    return fs, root

MODULES_URI: Final = '/tmp/modules'
CONVERTED_URI: Final = '/tmp/converted'

fs_modules, root_modules = get_fs_and_root(MODULES_URI)
fs_converted, root_converted = get_fs_and_root(CONVERTED_URI)

if fs_modules.protocol == 'file':
    fs_modules.makedirs(root_modules, exist_ok=True)
if fs_converted.protocol == 'file':
    fs_converted.makedirs(root_converted, exist_ok=True)

# Shared forbidden characters regex for URL validation/sanitization
FORBIDDEN_CHARS: Final = r'[ \t\n\r\x00-\x1f"\'`;|&$<>\\]'

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
    """Remove files older than CLEANUP_INTERVAL"""
    try:
        cutoff = time.time() - CLEANUP_INTERVAL
        for (fs, root) in zip([MODULES_URI, CONVERTED_URI], [(fs_modules, root_modules), (fs_converted, root_converted)]):
            try:
                files = fs.listdir(root)
            except Exception as e:
                logger.error(f"Could not list files in {root}: {e}")
                continue
            for fileinfo in files:
                if fileinfo.get('type') != 'file':
                    continue
                try:
                    stat = fs.stat(fileinfo['name'])
                    mtime = stat.get('mtime', stat.get('last_modified', None))
                    if mtime is None:
                        continue
                    if isinstance(mtime, str):
                        try:
                            mtime_ts = datetime.fromisoformat(mtime.replace('Z', '+00:00')).timestamp()
                        except Exception:
                            continue
                    else:
                        mtime_ts = float(mtime)
                    if mtime_ts < cutoff:
                        fs.rm(fileinfo['name'])
                        logger.info(f"Cleaned up old file: {fileinfo['name']}")
                except Exception as e:
                    logger.error(f"Cleanup error for {fileinfo['name']}: {e}")
    except Exception as e:
        logger.error(f"Cleanup error: {e}")


def get_file_hash(file_path):
    """Calculate MD5 hash of a file for caching"""
    md5 = hashlib.md5(usedforsecurity=False)  # Only used for caching, not security
    # Use modules fs/root for hashing
    # For remote, strip the MODULES_URI prefix if present
    rel_path = str(file_path)
    if rel_path.startswith(MODULES_URI + '/'):
        rel_path = rel_path[len(MODULES_URI) + 1:]
    with fs_modules.open(f"{root_modules}/{rel_path}", "rb") as f:
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


def get_cached_conversion(cache_hash, prefer_flac=False):
    """Check if a converted file exists in cache (WAV or FLAC)"""
    # Try FLAC first if preferred
    flac_path = f"{CONVERTED_URI}/{cache_hash}.flac"
    wav_path = f"{CONVERTED_URI}/{cache_hash}.wav"
    if prefer_flac:
        if fs_converted.exists(flac_path):
            logger.info(f"Cache hit (FLAC): {cache_hash}")
            return flac_path
        if fs_converted.exists(wav_path):
            if compress_to_flac(Path(wav_path), Path(flac_path)):
                logger.info(f"Cache hit (WAV) - compressed to FLAC: {cache_hash}")
                return flac_path
            else:
                logger.info(f"Cache hit (WAV) - FLAC compression failed: {cache_hash}")
                return wav_path
    if fs_converted.exists(wav_path):
        logger.info(f"Cache hit (WAV): {cache_hash}")
        return wav_path
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


def process_audio_conversion(
    input_path, output_path, use_cache=True, compress_flac=False
):
    """Convert module to WAV using UADE with optional caching and FLAC compression
    Returns: (success, error, final_file, player_format)
    """
    try:
        input_path = Path(input_path)
        output_path = Path(output_path)
        # Defensive: Restrict input_path to UPLOAD_DIR
        input_resolved = input_path.resolve()
        if not str(input_resolved).startswith(str(MODULES_URI)):
            logger.error("Aborting: attempted read outside allowed directories")
            return False, "Illegal input file path", None, None
        # Detect player format before conversion
        player_format = detect_player_format(str(input_path))
        # Always compute cache_hash for later use
        cache_hash = get_file_hash(str(input_path))
        # Check cache first
        if use_cache:
            cached_file = get_cached_conversion(cache_hash, prefer_flac=compress_flac)
            if cached_file:
                cached_file_path = Path(cached_file)
                # Copy cached file to output path
                if compress_flac and cached_file_path.suffix == ".flac":
                    # Return FLAC from cache
                    flac_output = output_path.with_suffix(".flac")
                    fs_converted.copy(str(cached_file_path), str(flac_output), recursive=False)
                    return True, None, flac_output, player_format
                else:
                    fs_converted.copy(str(cached_file_path), str(output_path), recursive=False)
                    return True, None, output_path, player_format
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
            return False, "Conversion failed: Output file not created", None, None

        final_output = output_path

        # Compress to FLAC if requested
        if compress_flac:
            flac_output = output_path.with_suffix(".flac")
            if compress_to_flac(output_path, flac_output):
                final_output = flac_output
                # Cache the FLAC version
                if use_cache:
                    cache_file = Path(f"{CONVERTED_URI}/{cache_hash}.flac")
                    if not cache_file.exists():
                        fs_converted.copy(str(flac_output), str(cache_file), recursive=False)
                        logger.info(f"Cached FLAC conversion: {cache_hash}")
            else:
                # FLAC compression failed, fall back to WAV
                logger.warning("FLAC compression failed, using WAV")
        # Save WAV to cache if not using FLAC
        if use_cache and not compress_flac:
            cache_file = Path(f"{CONVERTED_URI}/{cache_hash}.wav")
            if not cache_file.exists():
                fs_converted.copy(str(output_path), str(cache_file), recursive=False)
                logger.info(f"Cached conversion: {cache_hash}")

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
            "uade_available": Path("/usr/local/bin/uade123").exists()
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
        upload_path = f"{MODULES_URI}/{filename}_{file_id}"
        file.save(upload_path)

        # Check if it's an LHA or ZIP archive
        module_path = upload_path
        extract_dir = None
        if is_lha_file(upload_path):
            logger.info(f"Detected LHA archive upload: {filename}")
            extract_dir = f"{MODULES_URI}/{file_id}_extracted"
            fs_modules.makedirs(f"{root_modules}/{file_id}_extracted", exist_ok=True)
            success, error, music_file = extract_lha(upload_path, Path(extract_dir))
            if not success:
                rel_path = f"{filename}_{file_id}"
                if fs_modules.exists(f"{root_modules}/{rel_path}"):
                    fs_modules.rm(f"{root_modules}/{rel_path}")
                if fs_modules.exists(f"{root_modules}/{file_id}_extracted"):
                    fs_modules.rm(f"{root_modules}/{file_id}_extracted", recursive=True)
                return jsonify({"error": error}), 500
            module_path = Path(music_file)
            filename = module_path.name
        elif is_zip_file(upload_path):
            logger.info(f"Detected ZIP archive upload: {filename}")
            extract_dir = f"{MODULES_URI}/{file_id}_extracted"
            fs_modules.makedirs(f"{root_modules}/{file_id}_extracted", exist_ok=True)
            success, error, music_file = extract_zip(upload_path, Path(extract_dir))
            if not success:
                rel_path = f"{filename}_{file_id}"
                if fs_modules.exists(f"{root_modules}/{rel_path}"):
                    fs_modules.rm(f"{root_modules}/{rel_path}")
                if fs_modules.exists(f"{root_modules}/{file_id}_extracted"):
                    fs_modules.rm(f"{root_modules}/{file_id}_extracted", recursive=True)
                return jsonify({"error": error}), 500
            module_path = Path(music_file)
            filename = module_path.name

        # Convert to WAV (and optionally FLAC)
        output_path = Path(f"{CONVERTED_URI}/{file_id}.wav")
        success, error, final_file, player_format = process_audio_conversion(
            module_path, output_path, compress_flac=use_flac
        )

        # Clean up input files
        rel_path = f"{filename}_{file_id}"
        if fs_modules.exists(f"{root_modules}/{rel_path}"):
            fs_modules.rm(f"{root_modules}/{rel_path}")
        if extract_dir and fs_modules.exists(f"{root_modules}/{file_id}_extracted"):
            fs_modules.rm(f"{root_modules}/{file_id}_extracted", recursive=True)
        if not success:
            response = jsonify({"error": error})
            response.headers["Content-Type"] = "application/json; charset=utf-8"
            return response, 500

        response = jsonify(
            {
                "success": True,
                "file_id": file_id,
                "filename": filename,
                "player_format": player_format,
                "audio_format": final_file.suffix[1:] if final_file else "wav",
                "play_url": f"/play/{file_id}",
                "download_url": f"/download/{file_id}",
            }
        )
        response.headers["Content-Type"] = "application/json; charset=utf-8"
        return response

    except Exception as e:
        logger.error(f"Upload error: {e}")
    response = jsonify({"error": str(e)})
    response.headers["Content-Type"] = "application/json; charset=utf-8"
    return response, 500


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

    try:
        # Check browser FLAC support
        user_agent = request.headers.get("User-Agent", "")
        use_flac = supports_flac(user_agent)
        # Generate unique ID
        file_id = str(uuid.uuid4())

        # --- Caching logic for main module file ---
        raw_filename = url.split("/")[-1].split("#")[0].split("?")[0] or "module"
        filename = secure_filename(raw_filename)
        # Compute cache hash from URL
        url_hash = hashlib.md5(url.encode(), usedforsecurity=False).hexdigest()
        module_path = f"{MODULES_URI}/{filename}_{url_hash}"

        if fs_modules.exists(module_path):
            logger.info(
                f"Cache hit for module: {sanitized_url(url)}, using cached file: {module_path}"
            )
        else:
            logger.info(f"Downloading: {sanitized_url(url)}")
            # nosec B501 - Trade-off for HTTP module downloads
            response = requests.get(url, timeout=30, verify=False, allow_redirects=True)
            response.raise_for_status()
            # Save downloaded file to cache
            with open(module_path, "wb") as f:
                f.write(response.content)
            logger.info(f"Cached module_path: {module_path}")

        # --- Caching logic for TFMX sample file ---
        sample_path = None
        if sample_url:
            sample_url_hash = hashlib.md5(
                sample_url.encode(), usedforsecurity=False
            ).hexdigest()
            # Ensure filename matches mdat except for prefix
            if filename.startswith("mdat"):
                smplfilename = "smpl" + filename[4:]
            else:
                smplfilename = "smpl." + filename
            sample_path = f"{MODULES_URI}/{smplfilename}_{url_hash}"
            cached_sample_path = f"{MODULES_URI}/{smplfilename}_{sample_url_hash}"
            if fs_modules.exists(cached_sample_path):
                # For symlink logic, only works for local file system
                if fs_modules.protocol == 'file':
                    if os.path.exists(sample_path) or os.path.islink(sample_path):
                        try:
                            os.unlink(sample_path)
                        except Exception:
                            pass
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
                with fs_modules.open(cached_sample_path, "wb") as f:
                    f.write(sample_response.content)
                # For symlink logic, only works for local file system
                if fs_modules.protocol == 'file':
                    os.symlink(cached_sample_path, sample_path)
                logger.info(
                    f"Cached sample_path: {cached_sample_path}, linking to {sample_path}"
                )

        # Check if it's an LHA or ZIP archive
        extract_dir = None
        if is_lha_file(module_path):
            logger.info(f"Detected LHA archive: {filename}")
            extract_dir = f"{MODULES_URI}/{file_id}_extracted"
            if fs_modules.protocol == 'file':
                os.makedirs(extract_dir, exist_ok=True)
            success, error, music_file = extract_lha(module_path, Path(extract_dir))
            if not success:
                # Do not delete cached_module_path on error
                if extract_dir and fs_modules.protocol == 'file' and os.path.exists(extract_dir):
                    import shutil
                    shutil.rmtree(extract_dir, ignore_errors=True)
                response = jsonify({"error": error})
                response.headers["Content-Type"] = "application/json; charset=utf-8"
                return response, 500
            module_path = Path(music_file)
            filename = module_path.name
        elif is_zip_file(module_path):
            logger.info(f"Detected ZIP archive: {filename}")
            extract_dir = f"{MODULES_URI}/{file_id}_extracted"
            if fs_modules.protocol == 'file':
                os.makedirs(extract_dir, exist_ok=True)
            success, error, music_file = extract_zip(module_path, Path(extract_dir))
            if not success:
                # Do not delete cached_module_path on error
                if extract_dir and fs_modules.protocol == 'file' and os.path.exists(extract_dir):
                    import shutil
                    shutil.rmtree(extract_dir, ignore_errors=True)
                response = jsonify({"error": error})
                response.headers["Content-Type"] = "application/json; charset=utf-8"
                return response, 500
            module_path = Path(music_file)
            filename = module_path.name

        output_path = Path(f"{CONVERTED_URI}/{file_id}.wav")
        # Convert to WAV (and optionally FLAC)
        success, error, final_file, player_format = process_audio_conversion(
            module_path, output_path, compress_flac=use_flac
        )

        # Clean up extracted files only (do not delete cached files)
        if extract_dir:
            fs_modules.rm(extract_dir, recursive=True)
        if not success:
            return jsonify({"error": error}), 500

        response = jsonify(
            {
                "success": True,
                "file_id": file_id,
                "filename": filename,
                "player_format": player_format,
                "audio_format": final_file.suffix[1:] if final_file else "wav",
                "play_url": f"/play/{file_id}",
                "download_url": f"/download/{file_id}",
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
    url = re.sub(FORBIDDEN_CHARS, "", url)
    url = url.replace("\r", "").replace(
        "\n", ""
    )  # Remove line breaks to prevent log injection
    url = url.strip()
    if len(url) > 200:
        url = url[:200] + "..."
    return url


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
    """
    if not re.fullmatch(r"[a-zA-Z0-9_-]+", file_id):
        return jsonify({"error": "Invalid file_id"}), 400
    # Sanitize file_id to ensure a safe filename
    safe_file_id = secure_filename(file_id)
    # Try FLAC first, then WAV
    flac_path = f"{CONVERTED_URI}/{safe_file_id}.flac"
    wav_path = f"{CONVERTED_URI}/{safe_file_id}.wav"
    file_path = None
    mimetype = None
    filename = None
    if fs_converted.exists(flac_path):
        file_path = flac_path
        mimetype = "audio/flac"
        filename = f"uade_{safe_file_id}.flac"
    elif fs_converted.exists(wav_path):
        file_path = wav_path
        mimetype = "audio/wav"
        filename = f"uade_{safe_file_id}.wav"
    else:
        return jsonify({"error": "File not found or forbidden"}), 404
    file_size = fs_converted.size(file_path)

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
    with fs_converted.open(file_path, "rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            yield chunk


def stream_file_range(file_path, start, length, chunk_size=8192):
    """Yield a byte range from a file (used for range requests)"""
    with fs_converted.open(file_path, "rb") as f:
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


if __name__ == "__main__":
    logger.info(f"Starting UADE Web Player on port {PORT}")
    logger.info(f"Max upload size: {MAX_UPLOAD_SIZE / 1024 / 1024}MB")
    logger.info(f"Cleanup interval: {CLEANUP_INTERVAL}s")

    # Development server (Docker Compose overrides this with gunicorn)
    app.run(host="0.0.0.0", port=PORT, debug=False)
