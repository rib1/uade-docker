#!/usr/bin/env python3
"""
UADE Web Player - Flask Server
Converts Amiga music modules to WAV for browser playback
Cloud-ready with proper logging, error handling, and cleanup
"""

import os
import uuid
import time
import subprocess
import logging
import hashlib
from pathlib import Path
from datetime import datetime, timedelta
from flask import Flask, request, jsonify, send_file, send_from_directory
from werkzeug.utils import secure_filename
import requests

# Configure logging for cloud environments
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__, static_folder='static')

# Configuration from environment variables (cloud-ready)
MAX_UPLOAD_SIZE = int(os.getenv('MAX_UPLOAD_SIZE', 10485760))  # 10MB
CLEANUP_INTERVAL = int(os.getenv('CLEANUP_INTERVAL', 3600))  # 1 hour
RATE_LIMIT = int(os.getenv('RATE_LIMIT', 10))
PORT = int(os.getenv('PORT', 5000))

app.config['MAX_CONTENT_LENGTH'] = MAX_UPLOAD_SIZE

# Temp directories
UPLOAD_DIR = Path('/tmp/uploads')
CONVERTED_DIR = Path('/tmp/converted')
CACHE_DIR = Path('/tmp/cache')

for directory in [UPLOAD_DIR, CONVERTED_DIR, CACHE_DIR]:
    directory.mkdir(parents=True, exist_ok=True)

# Example modules - keeping it simple with proven working examples
EXAMPLES = [
    {
        'id': 'captain-space-debris',
        'name': 'Captain - Space Debris',
        'format': 'ProTracker',
        'duration': '306s',
        'url': 'https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod',
        'type': 'mod'
    },
    {
        'id': 'lizardking-doskpop',
        'name': 'Lizardking - Doskpop',
        'format': 'ProTracker',
        'duration': '146s',
        'url': 'https://modland.com/pub/modules/Protracker/Lizardking/l.k%27s%20doskpop.mod',
        'type': 'mod'
    },
    {
        'id': 'pink-stormlord',
        'name': 'Pink - Stormlord',
        'format': 'AHX',
        'duration': '512s (12KB!)',
        'url': 'https://modland.com/pub/modules/AHX/Pink/stormlord.ahx',
        'type': 'ahx'
    },
    {
        'id': 'huelsbeck-turrican2',
        'name': 'Chris Huelsbeck - Turrican 2',
        'format': 'TFMX',
        'duration': '~12min',
        'mdat_url': 'https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/mdat.turrican%202%20level%200-intro',
        'smpl_url': 'https://modland.com/pub/modules/TFMX/Chris%20Huelsbeck/smpl.turrican%202%20level%200-intro',
        'type': 'tfmx'
    },
    {
        'id': 'moby-late-nite',
        'name': 'Moby - Late Nite',
        'format': 'Oktalyzer',
        'duration': '~4min',
        'url': 'https://modland.com/pub/modules/Oktalyzer/Moby/late%20nite.okta',
        'type': 'okta'
    },
    {
        'id': 'romeo-knight-beat',
        'name': 'Romeo Knight - Beat to the Pulp',
        'format': 'SidMon 1',
        'duration': '~3min',
        'url': 'https://modland.com/pub/modules/SidMon%201/Romeo%20Knight/beat%20to%20the%20pulp.sid',
        'type': 'sid'
    }
]

def cleanup_old_files():
    """Remove files older than CLEANUP_INTERVAL"""
    try:
        cutoff = time.time() - CLEANUP_INTERVAL
        for directory in [UPLOAD_DIR, CONVERTED_DIR, CACHE_DIR]:
            for filepath in directory.glob('*'):
                if filepath.stat().st_mtime < cutoff:
                    filepath.unlink()
                    logger.info(f"Cleaned up old file: {filepath}")
    except Exception as e:
        logger.error(f"Cleanup error: {e}")

def get_file_hash(file_path):
    """Calculate MD5 hash of a file for caching"""
    md5 = hashlib.md5()
    with open(file_path, 'rb') as f:
        for chunk in iter(lambda: f.read(4096), b""):
            md5.update(chunk)
    return md5.hexdigest()

def supports_flac(user_agent):
    """Check if browser supports FLAC playback"""
    # Modern browsers that support FLAC natively
    ua = user_agent.lower()
    flac_browsers = ['chrome', 'chromium', 'edge', 'firefox', 'safari']
    return any(browser in ua for browser in flac_browsers)

def compress_to_flac(wav_path, flac_path):
    """Compress WAV to FLAC format"""
    try:
        cmd = ['flac', '--best', '--silent', '-f', '-o', str(flac_path), str(wav_path)]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        
        if result.returncode == 0 and flac_path.exists():
            logger.info(f"Compressed to FLAC: {wav_path} -> {flac_path} ({flac_path.stat().st_size / wav_path.stat().st_size:.1%} of original)")
            return True
        else:
            logger.error(f"FLAC compression failed: {result.stderr}")
            return False
    except Exception as e:
        logger.error(f"FLAC compression exception: {e}")
        return False

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

def convert_to_wav(input_path, output_path, use_cache=True, compress_flac=False):
    """Convert module to WAV using UADE with optional caching and FLAC compression"""
    try:
        # Check cache first
        if use_cache:
            cache_hash = get_file_hash(input_path)
            cached_file = get_cached_conversion(cache_hash, prefer_flac=compress_flac)
            if cached_file:
                # Copy cached file to output path
                import shutil
                if compress_flac and cached_file.suffix == '.flac':
                    # Return FLAC from cache
                    flac_output = output_path.with_suffix('.flac')
                    shutil.copy2(cached_file, flac_output)
                    return True, None, flac_output
                else:
                    shutil.copy2(cached_file, output_path)
                    return True, None, cached_file
        
        cmd = [
            '/usr/local/bin/uade123',
            '-c',  # Headless mode
            '-f', str(output_path),
            str(input_path)
        ]
        
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=300  # 5 minute timeout
        )
        
        if result.returncode != 0:
            logger.error(f"UADE error: {result.stderr}")
            return False, f"Conversion failed: {result.stderr}", None
        
        if not output_path.exists():
            return False, "Conversion failed: Output file not created", None
        
        final_output = output_path
        
        # Compress to FLAC if requested
        if compress_flac:
            flac_output = output_path.with_suffix('.flac')
            if compress_to_flac(output_path, flac_output):
                final_output = flac_output
                # Cache the FLAC version
                if use_cache:
                    cache_file = CONVERTED_DIR / f"{cache_hash}.flac"
                    if not cache_file.exists():
                        import shutil
                        shutil.copy2(flac_output, cache_file)
                        logger.info(f"Cached FLAC conversion: {cache_hash}")
            else:
                # FLAC compression failed, fall back to WAV
                logger.warning("FLAC compression failed, using WAV")
        
        # Save WAV to cache if not using FLAC
        if use_cache and not compress_flac:
            cache_file = CONVERTED_DIR / f"{cache_hash}.wav"
            if not cache_file.exists():
                import shutil
                shutil.copy2(output_path, cache_file)
                logger.info(f"Cached conversion: {cache_hash}")
        
        logger.info(f"Successfully converted: {input_path} -> {final_output}")
        return True, None, final_output
        
    except subprocess.TimeoutExpired:
        return False, "Conversion timeout (5 minutes exceeded)", None
    except Exception as e:
        logger.error(f"Conversion exception: {e}")
        return False, str(e), None

def convert_tfmx(mdat_url, smpl_url, output_path, use_cache=True, compress_flac=False):
    """Convert TFMX module using uade-convert helper with caching and FLAC compression"""
    try:
        # Create cache key from both URLs
        if use_cache:
            cache_key = hashlib.md5(f"{mdat_url}:{smpl_url}".encode()).hexdigest()
            cached_file = get_cached_conversion(cache_key, prefer_flac=compress_flac)
            
            if cached_file:
                # Cache hit - copy cached file
                import shutil
                if compress_flac and cached_file.suffix == '.flac':
                    flac_output = output_path.with_suffix('.flac')
                    shutil.copy2(cached_file, flac_output)
                    return True, None, flac_output
                else:
                    shutil.copy2(cached_file, output_path)
                    return True, None, cached_file
        
        cmd = [
            '/usr/local/bin/uade-convert',
            mdat_url,
            smpl_url,
            str(output_path)
        ]
        
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=300
        )
        
        if result.returncode != 0:
            logger.error(f"TFMX conversion error: {result.stderr}")
            return False, f"TFMX conversion failed: {result.stderr}", None
        
        final_output = output_path
        
        # Compress to FLAC if requested
        if compress_flac and output_path.exists():
            flac_output = output_path.with_suffix('.flac')
            if compress_to_flac(output_path, flac_output):
                final_output = flac_output
                # Cache the FLAC version
                if use_cache:
                    cache_file = CONVERTED_DIR / f"{cache_key}.flac"
                    if not cache_file.exists():
                        import shutil
                        shutil.copy2(flac_output, cache_file)
                        logger.info(f"Cached TFMX FLAC conversion: {cache_key}")
            else:
                logger.warning("FLAC compression failed for TFMX, using WAV")
        
        # Save WAV to cache if not using FLAC
        if use_cache and output_path.exists() and not compress_flac:
            cache_file = CONVERTED_DIR / f"{cache_key}.wav"
            if not cache_file.exists():
                import shutil
                shutil.copy2(output_path, cache_file)
                logger.info(f"Cached TFMX conversion: {cache_key}")
        
        return True, None, final_output
        
    except Exception as e:
        logger.error(f"TFMX exception: {e}")
        return False, str(e), None

@app.route('/')
def index():
    """Serve main page"""
    return send_from_directory('static', 'index.html')

@app.route('/health')
def health():
    """Health check for load balancers"""
    return jsonify({
        'status': 'healthy',
        'timestamp': datetime.utcnow().isoformat(),
        'uade_available': Path('/usr/local/bin/uade123').exists()
    })

@app.route('/examples')
def get_examples():
    """Return list of example modules"""
    return jsonify(EXAMPLES)

@app.route('/upload', methods=['POST'])
def upload_file():
    """Handle file upload and conversion"""
    cleanup_old_files()
    
    if 'file' not in request.files:
        return jsonify({'error': 'No file provided'}), 400
    
    file = request.files['file']
    if file.filename == '':
        return jsonify({'error': 'No file selected'}), 400
    
    try:
        # Check browser FLAC support
        user_agent = request.headers.get('User-Agent', '')
        use_flac = supports_flac(user_agent)
        
        # Generate unique ID
        file_id = str(uuid.uuid4())
        filename = secure_filename(file.filename)
        
        # Save uploaded file
        upload_path = UPLOAD_DIR / f"{file_id}_{filename}"
        file.save(upload_path)
        
        # Convert to WAV (and optionally FLAC)
        output_path = CONVERTED_DIR / f"{file_id}.wav"
        success, error, final_file = convert_to_wav(upload_path, output_path, compress_flac=use_flac)
        
        if not success:
            upload_path.unlink(missing_ok=True)
            return jsonify({'error': error}), 500
        
        # Clean up input file
        upload_path.unlink(missing_ok=True)
        
        return jsonify({
            'success': True,
            'file_id': file_id,
            'filename': filename,
            'format': final_file.suffix[1:] if final_file else 'wav',
            'play_url': f'/play/{file_id}',
            'download_url': f'/download/{file_id}'
        })
        
    except Exception as e:
        logger.error(f"Upload error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/convert-url', methods=['POST'])
def convert_url():
    """Download from URL and convert"""
    cleanup_old_files()
    
    data = request.get_json()
    if not data or 'url' not in data:
        return jsonify({'error': 'No URL provided'}), 400
    
    url = data['url']
    
    try:
        # Check browser FLAC support
        user_agent = request.headers.get('User-Agent', '')
        use_flac = supports_flac(user_agent)
        
        # Download file
        logger.info(f"Downloading: {url}")
        response = requests.get(url, timeout=30, verify=False)  # verify=False for corporate proxies
        response.raise_for_status()
        
        # Generate unique ID
        file_id = str(uuid.uuid4())
        filename = url.split('/')[-1].split('#')[0] or 'module'
        
        # Save downloaded file
        cache_path = CACHE_DIR / f"{file_id}_{filename}"
        cache_path.write_bytes(response.content)
        
        # Convert to WAV (and optionally FLAC)
        output_path = CONVERTED_DIR / f"{file_id}.wav"
        success, error, final_file = convert_to_wav(cache_path, output_path, compress_flac=use_flac)
        
        if not success:
            cache_path.unlink(missing_ok=True)
            return jsonify({'error': error}), 500
        
        # Clean up cached file
        cache_path.unlink(missing_ok=True)
        
        return jsonify({
            'success': True,
            'file_id': file_id,
            'filename': filename,
            'format': final_file.suffix[1:] if final_file else 'wav',
            'play_url': f'/play/{file_id}',
            'download_url': f'/download/{file_id}'
        })
        
    except requests.RequestException as e:
        logger.error(f"Download error: {e}")
        return jsonify({'error': f'Download failed: {str(e)}'}), 500
    except Exception as e:
        logger.error(f"Convert URL error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/convert-tfmx', methods=['POST'])
def handle_tfmx():
    """Handle TFMX module conversion"""
    cleanup_old_files()
    
    data = request.get_json()
    if not data or 'mdat_url' not in data or 'smpl_url' not in data:
        return jsonify({'error': 'Both mdat_url and smpl_url required'}), 400
    
    try:
        # Check browser FLAC support
        user_agent = request.headers.get('User-Agent', '')
        use_flac = supports_flac(user_agent)
        
        file_id = str(uuid.uuid4())
        output_path = CONVERTED_DIR / f"{file_id}.wav"
        
        success, error, final_file = convert_tfmx(data['mdat_url'], data['smpl_url'], output_path, compress_flac=use_flac)
        
        if not success:
            return jsonify({'error': error}), 500
        
        return jsonify({
            'success': True,
            'file_id': file_id,
            'filename': 'tfmx_module',
            'format': final_file.suffix[1:] if final_file else 'wav',
            'play_url': f'/play/{file_id}',
            'download_url': f'/download/{file_id}'
        })
        
    except Exception as e:
        logger.error(f"TFMX error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/play-example/<example_id>', methods=['POST'])
def play_example(example_id):
    """Convert and play predefined example"""
    cleanup_old_files()
    
    example = next((ex for ex in EXAMPLES if ex['id'] == example_id), None)
    if not example:
        return jsonify({'error': 'Example not found'}), 404
    
    try:
        # Check browser FLAC support
        user_agent = request.headers.get('User-Agent', '')
        use_flac = supports_flac(user_agent)
        
        file_id = str(uuid.uuid4())
        output_path = CONVERTED_DIR / f"{file_id}.wav"
        
        if example['type'] == 'tfmx':
            success, error, final_file = convert_tfmx(
                example['mdat_url'],
                example['smpl_url'],
                output_path,
                compress_flac=use_flac
            )
        else:
            # Download regular module
            response = requests.get(example['url'], timeout=30, verify=False)
            response.raise_for_status()
            
            cache_path = CACHE_DIR / f"{file_id}_{example['type']}"
            cache_path.write_bytes(response.content)
            
            success, error, final_file = convert_to_wav(cache_path, output_path, compress_flac=use_flac)
            cache_path.unlink(missing_ok=True)
        
        if not success:
            return jsonify({'error': error}), 500
        
        return jsonify({
            'success': True,
            'file_id': file_id,
            'example': example,
            'format': final_file.suffix[1:] if final_file else 'wav',
            'play_url': f'/play/{file_id}',
            'download_url': f'/download/{file_id}'
        })
        
    except Exception as e:
        logger.error(f"Example play error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/play/<file_id>')
def play_file(file_id):
    """Stream audio file for playback (FLAC or WAV)"""
    # Try FLAC first, then WAV
    flac_path = CONVERTED_DIR / f"{file_id}.flac"
    wav_path = CONVERTED_DIR / f"{file_id}.wav"
    
    if flac_path.exists():
        return send_file(
            flac_path,
            mimetype='audio/flac',
            as_attachment=False
        )
    elif wav_path.exists():
        return send_file(
            wav_path,
            mimetype='audio/wav',
            as_attachment=False,
            download_name=f'{file_id}.wav'
        )
    else:
        return jsonify({'error': 'File not found'}), 404

@app.route('/download/<file_id>')
def download_file(file_id):
    """Download audio file (FLAC or WAV)"""
    # Try FLAC first, then WAV
    flac_path = CONVERTED_DIR / f"{file_id}.flac"
    wav_path = CONVERTED_DIR / f"{file_id}.wav"
    
    if flac_path.exists():
        return send_file(
            flac_path,
            mimetype='audio/flac',
            as_attachment=True,
            download_name=f'uade_{file_id}.flac'
        )
    elif wav_path.exists():
        return send_file(
            wav_path,
            mimetype='audio/wav',
            as_attachment=True,
            download_name=f'uade_{file_id}.wav'
        )
    else:
        return jsonify({'error': 'File not found'}), 404

if __name__ == '__main__':
    logger.info(f"Starting UADE Web Player on port {PORT}")
    logger.info(f"Max upload size: {MAX_UPLOAD_SIZE / 1024 / 1024}MB")
    logger.info(f"Cleanup interval: {CLEANUP_INTERVAL}s")
    
    # Development server (Docker Compose overrides this with gunicorn)
    app.run(host='0.0.0.0', port=PORT, debug=False)
