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
from datetime import datetime
from flask import Flask, request, jsonify, send_from_directory, Response
from werkzeug.utils import secure_filename
import requests
import re
import shutil
import ipaddress

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

# Temp directories
UPLOAD_DIR = Path("/tmp/uploads")
CONVERTED_DIR = Path("/tmp/converted")
CACHE_DIR = Path("/tmp/cache")

# Shared forbidden characters regex for URL validation/sanitization
FORBIDDEN_CHARS = r'[ \t\n\r\x00-\x1f"\'`;|&$<>\\]'

for directory in [UPLOAD_DIR, CONVERTED_DIR, CACHE_DIR]:
    directory.mkdir(parents=True, exist_ok=True)

# Find music files (common Amiga module extensions and prefixes)
music_extensions = {
    "aam",
    "ahx",
    "aon",
    "bp",
    "bp3"
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
EXAMPLES = [
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
        "type": "cust",
    },
    {
        "id": "led-storm",
        "name": "Tim Follin - LED Storm",
        "format": "Hippel-COSO (LHA)",
        "duration": "38 min (7 tracks)",
        "url": (
            "http://files.exotica.org.uk/?file=exotica%2Fmedia%2Faudio%2FUnExoticA%2FGame%2FFollin_Tim%2FL_E_D_Storm.lha"
        ),
        "type": "lha",
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
        for directory in [UPLOAD_DIR, CONVERTED_DIR, CACHE_DIR]:
            for filepath in directory.glob("*"):
                if filepath.stat().st_mtime < cutoff:
                    filepath.unlink()
                    logger.info(f"Cleaned up old file: {filepath}")
    except Exception as e:
        logger.error(f"Cleanup error: {e}")


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

        music_files = []
        for file_path in extract_dir.rglob("*"):
            if file_path.is_file():
                name_lower = file_path.name.lower()
                ext = file_path.suffix.lower()[1:]
                prefix = name_lower.split(".")[0]
                # Check by extension
                if ext in music_extensions or prefix in music_extensions:
                    music_files.append(file_path)

        if not music_files:
            return False, "No music files found in LHA archive", None

        # Use the first music file found
        music_file = music_files[0]
        logger.info(
            f"Extracted LHA archive, found {len(music_files)} music file(s), using: {music_file.name}"
        )
        return True, None, music_file

    except subprocess.TimeoutExpired:
        return False, "LHA extraction timeout", None
    except Exception as e:
        logger.error(f"LHA extraction exception: {e}")
        return False, str(e), None


def get_cached_conversion(cache_hash, prefer_flac=False):
    """Check if a converted file exists in cache (WAV or FLAC)"""
    # Try FLAC first if preferred
    if prefer_flac:
        flac_file = CONVERTED_DIR / f"{cache_hash}.flac"
        if flac_file.exists():
            flac_file.touch()
            logger.info(f"Cache hit (FLAC): {cache_hash}")
            return flac_file

        # If FLAC not found but WAV exists, compress it
        wav_file = CONVERTED_DIR / f"{cache_hash}.wav"
        if wav_file.exists():
            flac_file = CONVERTED_DIR / f"{cache_hash}.flac"
            if compress_to_flac(wav_file, flac_file):
                flac_file.touch()
                logger.info(f"Cache hit (WAV) - compressed to FLAC: {cache_hash}")
                return flac_file
            else:
                # Compression failed, return WAV
                wav_file.touch()
                logger.info(f"Cache hit (WAV) - FLAC compression failed: {cache_hash}")
                return wav_file

    # Fall back to WAV
    wav_file = CONVERTED_DIR / f"{cache_hash}.wav"
    if wav_file.exists():
        wav_file.touch()
        logger.info(f"Cache hit (WAV): {cache_hash}")
        return wav_file

    return None


def detect_player_format(input_path):
    """Detect the player format of a module using uade123 -g"""
    try:
        cmd = ["/usr/local/bin/uade123", "-g", str(input_path)]  # Get info only

        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)

        # Parse output to extract player name
        # uade123 -g output format: "playername: PlayerName"
        for line in result.stdout.splitlines():
            if line.startswith("playername:"):
                player_name = line.split(":", 1)[1].strip()
                return player_name if player_name else "Module"

        # If no player name found, return generic
        return "Module"

    except Exception as e:
        logger.warning(f"Could not detect player format: {e}")
        return "Module"


def convert_to_wav(input_path, output_path, use_cache=True, compress_flac=False):
    """Convert module to WAV using UADE with optional caching and FLAC compression
    Returns: (success, error, final_file, player_format)
    """
    try:
        # Defensive: Restrict input_path to UPLOAD_DIR or CACHE_DIR
        input_resolved = Path(input_path).resolve()
        if not (
            input_resolved.is_relative_to(CACHE_DIR.resolve())
            or input_resolved.is_relative_to(UPLOAD_DIR.resolve())
        ):
            logger.error("Aborting: attempted read outside allowed directories")
            return False, "Illegal input file path", None, None
        # Detect player format before conversion
        player_format = detect_player_format(input_path)
        # Always compute cache_hash for later use
        cache_hash = get_file_hash(input_path)
        # Check cache first
        if use_cache:
            cached_file = get_cached_conversion(cache_hash, prefer_flac=compress_flac)
            if cached_file:
                # Copy cached file to output path
                if compress_flac and cached_file.suffix == ".flac":
                    # Return FLAC from cache
                    flac_output = output_path.with_suffix(".flac")
                    shutil.copy2(cached_file, flac_output)
                    return True, None, flac_output, player_format
                else:
                    shutil.copy2(cached_file, output_path)
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
            return False, "Conversion failed: Output file not created", None, None

        final_output = output_path

        # Compress to FLAC if requested
        if compress_flac:
            flac_output = output_path.with_suffix(".flac")
            if compress_to_flac(output_path, flac_output):
                final_output = flac_output
                # Cache the FLAC version
                if use_cache:
                    cache_file = CONVERTED_DIR / f"{cache_hash}.flac"
                    if not cache_file.exists():
                        shutil.copy2(flac_output, cache_file)
                        logger.info(f"Cached FLAC conversion: {cache_hash}")
            else:
                # FLAC compression failed, fall back to WAV
                logger.warning("FLAC compression failed, using WAV")

        # Save WAV to cache if not using FLAC
        if use_cache and not compress_flac:
            cache_file = CONVERTED_DIR / f"{cache_hash}.wav"
            if not cache_file.exists():
                shutil.copy2(output_path, cache_file)
                logger.info(f"Cached conversion: {cache_hash}")

        logger.info(f"Successfully converted: {input_path} -> {final_output}")
        return True, None, final_output, player_format

    except subprocess.TimeoutExpired:
        return False, "Conversion timeout (5 minutes exceeded)", None, None
    except Exception as e:
        logger.error(f"Conversion exception: {e}")
        return False, str(e), None, None


def convert_tfmx(mdat_url, smpl_url, output_path, use_cache=True, compress_flac=False):
    """Convert TFMX module using uade-convert helper with caching and FLAC compression"""
    # Defensive: Restrict output_path to CONVERTED_DIR
    output_resolved = Path(output_path).resolve()
    if not output_resolved.is_relative_to(CONVERTED_DIR.resolve()):
        logger.error("Aborting: attempted write outside converted directory")
        return False, "Illegal output file path", None
    try:
        # Create cache key from both URLs (use raw input, not sanitized)
        if use_cache:
            # Normalize URLs for cache key
            norm_mdat_url = mdat_url.strip().lower()
            norm_smpl_url = smpl_url.strip().lower()
            cache_key = hashlib.md5(
                f"{norm_mdat_url}:{norm_smpl_url}".encode(), usedforsecurity=False
            ).hexdigest()
            cached_file = get_cached_conversion(cache_key, prefer_flac=compress_flac)
            if cached_file:
                # Cache hit - copy cached file
                if compress_flac and cached_file.suffix == ".flac":
                    flac_output = output_path.with_suffix(".flac")
                    shutil.copy2(cached_file, flac_output)
                    return True, None, flac_output
                else:
                    shutil.copy2(cached_file, output_path)
                    return True, None, cached_file

        # Use strictly validated, normalized URLs as arguments; don't mutate/sanitize
        cmd = ["/usr/local/bin/uade-convert", mdat_url, smpl_url, str(output_path)]

        result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)

        if result.returncode != 0:
            logger.error(f"TFMX conversion error: {result.stderr}")
            return False, f"TFMX conversion failed: {result.stderr}", None

        final_output = output_path

        # Compress to FLAC if requested
        if compress_flac and output_path.exists():
            flac_output = output_path.with_suffix(".flac")
            if compress_to_flac(output_path, flac_output):
                final_output = flac_output
                # Cache the FLAC version
                if use_cache:
                    cache_file = CONVERTED_DIR / f"{cache_key}.flac"
                    if not cache_file.exists():
                        shutil.copy2(flac_output, cache_file)
                        logger.info(f"Cached TFMX FLAC conversion: {cache_key}")
            else:
                logger.warning("FLAC compression failed for TFMX, using WAV")

        # Save WAV to cache if not using FLAC
        if use_cache and output_path.exists() and not compress_flac:
            cache_file = CONVERTED_DIR / f"{cache_key}.wav"
            if not cache_file.exists():
                shutil.copy2(output_path, cache_file)
                logger.info(f"Cached TFMX conversion: {cache_key}")

        return True, None, final_output

    except Exception as e:
        logger.error(f"TFMX exception: {e}")
        return False, str(e), None


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
            "timestamp": datetime.utcnow().isoformat(),
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
        upload_path = UPLOAD_DIR / f"{file_id}_{filename}"
        file.save(upload_path)

        # Check if it's an LHA archive
        module_path = upload_path
        extract_dir = None
        if is_lha_file(upload_path):
            logger.info(f"Detected LHA archive upload: {filename}")
            extract_dir = UPLOAD_DIR / f"{file_id}_extracted"
            success, error, music_file = extract_lha(upload_path, extract_dir)

            if not success:
                upload_path.unlink(missing_ok=True)
                if extract_dir and extract_dir.exists():
                    shutil.rmtree(extract_dir, ignore_errors=True)
                return jsonify({"error": error}), 500

            module_path = music_file
            filename = music_file.name

        # Convert to WAV (and optionally FLAC)
        output_path = CONVERTED_DIR / f"{file_id}.wav"
        success, error, final_file, player_format = convert_to_wav(
            module_path, output_path, compress_flac=use_flac
        )

        if not success:
            upload_path.unlink(missing_ok=True)
            if extract_dir and extract_dir.exists():
                shutil.rmtree(extract_dir, ignore_errors=True)
            response = jsonify({"error": error})
            response.headers["Content-Type"] = "application/json; charset=utf-8"
            return response, 500

        # Clean up input files
        upload_path.unlink(missing_ok=True)
        if extract_dir and extract_dir.exists():
            shutil.rmtree(extract_dir, ignore_errors=True)

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
    """Download from URL and convert"""
    cleanup_old_files()

    data = request.get_json()
    if not data or "url" not in data:
        response = jsonify({"error": "No URL provided"})
        response.headers["Content-Type"] = "application/json; charset=utf-8"
        return response, 400

    url = data["url"]

    try:
        # Check browser FLAC support
        user_agent = request.headers.get("User-Agent", "")
        use_flac = supports_flac(user_agent)

        # Download file (allow redirects for URLs like exotica.org.uk)
        logger.info(f"Downloading: {sanitized_url(url)}")
        # nosec B501 - Trade-off for HTTP module downloads
        response = requests.get(url, timeout=30, verify=False, allow_redirects=True)
        response.raise_for_status()

        # Generate unique ID
        file_id = str(uuid.uuid4())
        raw_filename = url.split("/")[-1].split("#")[0].split("?")[0] or "module"
        # Sanitize filename from user input using Werkzeug's secure_filename
        filename = secure_filename(raw_filename)

        # Save downloaded file
        cache_path = CACHE_DIR / f"{file_id}_{filename}"
        # Restrict cache_path to CACHE_DIR
        if not cache_path.resolve().is_relative_to(CACHE_DIR.resolve()):
            logger.error("Aborting: attempted write outside cache directory")
            response = jsonify({"error": "Illegal file name/path"})
            response.headers["Content-Type"] = "application/json; charset=utf-8"
            return response, 400
        cache_path.write_bytes(response.content)

        # Check if it's an LHA archive
        module_path = cache_path
        extract_dir = None
        if is_lha_file(cache_path):
            logger.info(f"Detected LHA archive: {filename}")
            extract_dir = CACHE_DIR / f"{file_id}_extracted"
            success, error, music_file = extract_lha(cache_path, extract_dir)

            if not success:
                cache_path.unlink(missing_ok=True)
                if extract_dir and extract_dir.exists():
                    shutil.rmtree(extract_dir, ignore_errors=True)
                response = jsonify({"error": error})
                response.headers["Content-Type"] = "application/json; charset=utf-8"
                return response, 500

            module_path = music_file
            filename = music_file.name
        # Assign output_path before restriction check
        output_path = CONVERTED_DIR / f"{file_id}.wav"
        # Restrict output_path to CONVERTED_DIR
        if not output_path.resolve().is_relative_to(CONVERTED_DIR.resolve()):
            logger.error("Aborting: attempted write outside output directory")
            return jsonify({"error": "Illegal output path"}), 400

        # Convert to WAV (and optionally FLAC)
        success, error, final_file, player_format = convert_to_wav(
            module_path, output_path, compress_flac=use_flac
        )

        if not success:
            cache_path.unlink(missing_ok=True)
            if extract_dir and extract_dir.exists():
                shutil.rmtree(extract_dir, ignore_errors=True)
            return jsonify({"error": error}), 500

        # Clean up cached files
        cache_path.unlink(missing_ok=True)
        if extract_dir and extract_dir.exists():
            shutil.rmtree(extract_dir, ignore_errors=True)

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


@app.route("/convert-tfmx", methods=["POST"])
def handle_tfmx():
    """Handle TFMX module conversion"""
    cleanup_old_files()

    data = request.get_json()
    if not data or "mdat_url" not in data or "smpl_url" not in data:
        return jsonify({"error": "Both mdat_url and smpl_url required"}), 400

    # Validate URLs before processing (stricter, block meta/whitespace chars, local addresses, etc)
    def is_safe_url(url):
        from urllib.parse import urlparse

        # Reject URLs containing forbidden characters
        if re.search(FORBIDDEN_CHARS, url):
            return False
        try:
            parsed = urlparse(url)
            if parsed.scheme not in ("http", "https"):
                return False
            if not parsed.netloc:
                return False
            # Disallow local hostnames and private IP addresses (prevents SSRF to internal network/services)
            hostname = parsed.hostname
            if not hostname:
                return False
            # Disallow localhost names
            if hostname in ("localhost", "127.0.0.1", "::1"):
                return False
            # Resolve IPs and check for loopback/private
            try:
                ip = ipaddress.ip_address(hostname)
                if (
                    ip.is_loopback
                    or ip.is_private
                    or ip.is_link_local
                    or ip.is_reserved
                ):
                    return False
            except ValueError:
                # If not an IP, could be a hostname, optionally check against other blocked patterns
                # Forbid .local domain as extra belt-and-suspenders, optionally restrict more
                if hostname.endswith(".local"):
                    return False
            return True
        except Exception:
            return False

    # Use normalized URLs
    mdat_url = data["mdat_url"].strip()
    smpl_url = data["smpl_url"].strip()
    if not (is_safe_url(mdat_url) and is_safe_url(smpl_url)):
        return jsonify({"error": "Invalid or unsafe URL(s) supplied"}), 400

    try:
        # Check browser FLAC support
        user_agent = request.headers.get("User-Agent", "")
        use_flac = supports_flac(user_agent)

        file_id = str(uuid.uuid4())
        output_path = CONVERTED_DIR / f"{file_id}.wav"

        success, error, final_file = convert_tfmx(
            mdat_url, smpl_url, output_path, compress_flac=use_flac
        )

        if not success:
            return jsonify({"error": error}), 500

        return jsonify(
            {
                "success": True,
                "file_id": file_id,
                "filename": "tfmx_module",
                "player_format": "TFMX",
                "audio_format": final_file.suffix[1:] if final_file else "wav",
                "play_url": f"/play/{file_id}",
                "download_url": f"/download/{file_id}",
            }
        )

    except Exception as e:
        logger.error(
            f"TFMX error: {sanitized_url(mdat_url)}, {sanitized_url(smpl_url)}: {e}"
        )
        return jsonify({"error": str(e)}), 500


@app.route("/play-example/<example_id>", methods=["POST"])
def play_example(example_id):
    """Convert and play predefined example"""
    cleanup_old_files()

    example = next((ex for ex in EXAMPLES if ex["id"] == example_id), None)
    if not example:
        return jsonify({"error": "Example not found"}), 404

    try:
        # Check browser FLAC support
        user_agent = request.headers.get("User-Agent", "")
        use_flac = supports_flac(user_agent)

        file_id = str(uuid.uuid4())
        output_path = CONVERTED_DIR / f"{file_id}.wav"

        if example["type"] == "tfmx":
            success, error, final_file = convert_tfmx(
                example["mdat_url"],
                example["smpl_url"],
                output_path,
                compress_flac=use_flac,
            )
            player_format = "TFMX"  # TFMX modules are always TFMX format
        else:
            # Download regular module (allow redirects for URLs like exotica.org.uk)
            # nosec B501 - Trade-off for HTTP module downloads
            response = requests.get(
                example["url"], timeout=30, verify=False, allow_redirects=True
            )
            response.raise_for_status()

            cache_path = CACHE_DIR / f"{file_id}_{example['type']}"
            cache_path.write_bytes(response.content)

            # Check if it's an LHA archive
            module_path = cache_path
            extract_dir = None
            if is_lha_file(cache_path):
                logger.info(f"Detected LHA archive in example: {example['name']}")
                extract_dir = CACHE_DIR / f"{file_id}_extracted"
                extract_success, extract_error, music_file = extract_lha(
                    cache_path, extract_dir
                )

                if not extract_success:
                    cache_path.unlink(missing_ok=True)
                    if extract_dir and extract_dir.exists():
                        shutil.rmtree(extract_dir, ignore_errors=True)
                    return jsonify({"error": extract_error}), 500

                module_path = music_file
            success, error, final_file, player_format = convert_to_wav(
                module_path, output_path, compress_flac=use_flac
            )

            # Clean up
            cache_path.unlink(missing_ok=True)
            if extract_dir and extract_dir.exists():
                shutil.rmtree(extract_dir, ignore_errors=True)

        if not success:
            return jsonify({"error": error}), 500

        response = jsonify(
            {
                "success": True,
                "file_id": file_id,
                "example": example,
                "player_format": player_format,
                "audio_format": final_file.suffix[1:] if final_file else "wav",
                "play_url": f"/play/{file_id}",
                "download_url": f"/download/{file_id}",
            }
        )
        response.headers["Content-Type"] = "application/json; charset=utf-8"
        return response

    except Exception as e:
        logger.error(f"Example play error: {e}")
    response = jsonify({"error": str(e)})
    response.headers["Content-Type"] = "application/json; charset=utf-8"
    return response, 500


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
    flac_path = (CONVERTED_DIR / f"{safe_file_id}.flac").resolve()
    wav_path = (CONVERTED_DIR / f"{safe_file_id}.wav").resolve()

    # Only allow files under CONVERTED_DIR to be served
    converted_base = CONVERTED_DIR.resolve()
    try:
        if flac_path.exists() and flac_path.relative_to(converted_base):
            file_path = flac_path
            mimetype = "audio/flac"
            filename = f"uade_{safe_file_id}.flac"
        elif wav_path.exists() and wav_path.relative_to(converted_base):
            file_path = wav_path
            mimetype = "audio/wav"
            filename = f"uade_{safe_file_id}.wav"
        else:
            return jsonify({"error": "File not found or forbidden"}), 404
    except ValueError:
        # Path not contained within converted_base
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


if __name__ == "__main__":
    logger.info(f"Starting UADE Web Player on port {PORT}")
    logger.info(f"Max upload size: {MAX_UPLOAD_SIZE / 1024 / 1024}MB")
    logger.info(f"Cleanup interval: {CLEANUP_INTERVAL}s")

    # Development server (Docker Compose overrides this with gunicorn)
    app.run(host="0.0.0.0", port=PORT, debug=False)
