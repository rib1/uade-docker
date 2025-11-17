# UADE Web Player

Play Amiga music modules directly in your web browser! No desktop software required.

## Features

- 🎵 **Play in Browser** - Upload or download modules, hear them instantly
- 🎮 **Example Modules** - Try famous Amiga classics with one click
- 🌐 **URL Support** - Download directly from Modland, ModArchive, etc.
- 📦 **LHA & ZIP Archive Support** - Automatically extracts classic Amiga LHA archives (and ZIP)
- 🎹 **TFMX Support** - Handles dual-file TFMX modules automatically
- 💿 **Smart Compression** - Automatic FLAC compression for capable browsers (50-70% smaller files)
- ⬇️ **Download Audio** - Save as FLAC or WAV for offline playback
- 🚀 **Cloud Ready** - Designed for Kubernetes, EKS Auto Mode, and cloud platforms
- 📱 **Mobile Friendly** - Works on phones and tablets
- ⚡ **Performance** - MD5-based caching for instant replay

## Quick Start

### Using Docker Compose (Recommended)

The easiest way to run the UADE Web Player locally:

```powershell
# Clone the repository
git clone https://github.com/rib1/uade-docker.git
cd uade-docker

# Start the web player
docker-compose up -d

# Access at: http://localhost:5000
```

**What docker-compose provides:**

- Automatic build and startup
- Health checks with auto-restart
- Persistent storage for uploads/conversions
- Web runtime environment configuration
- Read-only source code mount for security
- Cleanup of old files (1 hour interval)

**Managing the service:**

```powershell
# View logs
docker-compose logs -f

# Stop the service
docker-compose down

# Rebuild after code changes
docker-compose up -d --build
# To inject the current git commit hash into the container, run:
$env:GIT_COMMIT = (git rev-parse HEAD); docker-compose up -d --build

# View service status
docker-compose ps
```

**Configuration:**

The `docker-compose.yml` includes these environment variables:

```yaml
FLASK_ENV: production # Production mode
MAX_UPLOAD_SIZE: 10485760 # 10MB max upload
CLEANUP_INTERVAL: 3600 # Files deleted after 1 hour
RATE_LIMIT: 10 # Max 10 conversions/min per IP
```

To customize, edit `docker-compose.yml` or create a `docker-compose.override.yml`:

```yaml
# docker-compose.override.yml
services:
  uade-web:
    environment:
      - MAX_UPLOAD_SIZE=20971520 # 20MB
      - CLEANUP_INTERVAL=7200 # 2 hours
    ports:
      - "8080:5000" # Use port 8080 instead
```

### Manual Docker Build

For manual control without docker-compose:

```powershell
# Build the image
docker build -f Dockerfile.web -t uade-web-player .

# Run the container
docker run -d \
  --name uade-web-player \
  -p 5000:5000 \
  -e FLASK_ENV=production \
  -e MAX_UPLOAD_SIZE=10485760 \
  -e CLEANUP_INTERVAL=3600 \
  uade-web-player

# Access at: http://localhost:5000
```

**Managing the container:**

```powershell
# View logs
docker logs -f uade-web-player

# Stop the container
docker stop uade-web-player

# Remove the container
docker rm uade-web-player

# Restart the container
docker restart uade-web-player
```

## Usage

### 1. Try Example Modules

Click any example module on the homepage to instantly hear classic Amiga music:

- Captain - "Space Debris" (Protracker)
- Lizardking - "Doskpop" (Protracker)
- Pink - "Stormlord" (AHX chiptune)
- Rob Hubbard - "Populous" (Protracker)
- Chris Huelsbeck - "Turrican 2" (TFMX)

### 2. Upload Your Files

Drag and drop .mod, .ahx, or other module files directly into the browser.

**Supported formats:**

- Individual modules (.mod, .ahx, .tfmx, .okta, .sid, etc.)
- LHA (.lha) and ZIP archives (.zip) - Automatically extracted and played

### 3. Download from URL

Paste a Modland or ModArchive URL to download and convert automatically.

**Example URLs:**

```url
https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod
https://modland.com/pub/modules/AHX/Pink/stormlord.ahx
http://files.exotica.org.uk/?file=exotica%2Fmedia%2Faudio%2FUnExoticA%2FGame%2FFollin_Tim%2FL_E_D_Storm.lha
https://example.com/amiga-collection.zip
```

**LHA & ZIP Archive Support:**

The web player automatically detects and extracts classic Amiga LHA archives. Many music collections from sites like Exotica.org.uk are distributed as LHA files, and ZIP archives are also supported:

- Upload an .lha or .zip file, or provide its URL
- Player automatically extracts the archive
- First music file found is played
- Supports all common Amiga module formats inside archives
- No manual extraction needed!

### 4. TFMX Modules

For TFMX modules (requires two files), expand the TFMX section and provide both URLs:

- mdat URL (music data)
- smpl URL (samples)

## API Reference

The web player provides a REST API for programmatic access:

### Health Check

```http
GET /health
```

Returns server health status and UADE availability.

### Upload File

```http
POST /upload
Content-Type: multipart/form-data

file: <module file>
```

### Convert from URL

```http
POST /convert-url
Content-Type: application/json

{
  "url": "https://modland.com/pub/modules/..."
}
```

### Convert TFMX

```http
POST /convert-tfmx
Content-Type: application/json

{
  "mdat_url": "https://...",
  "smpl_url": "https://..."
}
```

### Play Example

```http
POST /play-example/{example_id}
```

### Get Examples

```http
GET /examples
```

### Stream/Download WAV

```http
GET /play/{file_id}      # Stream in browser
GET /download/{file_id}  # Download file
```

## Configuration

Environment variables for customization:

```yaml
FLASK_ENV: production # Flask environment
PORT: 5000 # Server port
MAX_UPLOAD_SIZE: 10485760 # Max upload (10MB)
CLEANUP_INTERVAL: 3600 # File cleanup (1 hour)
RATE_LIMIT: 10 # Max conversions/min per IP
```

## Browser Compatibility

### FLAC Support (Automatic)

Modern browsers receive FLAC-compressed audio automatically:

- ✅ **Chrome/Chromium** - Full FLAC support
- ✅ **Microsoft Edge** - Full FLAC support
- ✅ **Firefox** - Full FLAC support
- ✅ **Safari** - Full FLAC support (macOS/iOS)
- ✅ **Opera** - Full FLAC support

Older or unsupported browsers automatically receive WAV files as fallback. No configuration needed!

## Architecture

### Multi-Stage Build

- **Stage 1 (base):** Compile UADE and dependencies from source
- **Stage 2 (runtime):** Lightweight image with Python/Flask + UADE binaries + FLAC encoder

### Production Server

- Uses **Gunicorn** WSGI server
- **Local/Docker Compose:** 4 workers for parallel requests
- **Cloud Run:** 1 worker + 4 threads (optimized for memory)
- Health checks for container orchestration
- Structured logging for cloud platforms
- Graceful shutdown handling
- 300s timeout for large file conversions

### Audio Compression

- **Smart Format Selection:** Detects browser FLAC support via User-Agent
- **Automatic Compression:** Converts WAV to FLAC for capable browsers (Chrome, Firefox, Edge, Safari)
- **50-70% Size Reduction:** Typical TFMX files reduce from 30MB WAV to 10-15MB FLAC
- **Lossless Quality:** FLAC maintains bit-perfect audio fidelity
- **Fallback Support:** Non-capable browsers still receive WAV files
- **Cache Optimization:** Stores both WAV and FLAC versions for fast delivery
- **On-the-fly Conversion:** Old WAV cache files are automatically compressed to FLAC when requested

### File Management

- Automatic cleanup of files older than 1 hour
- Separate directories: uploads, conversions, cache
- UUID-based filenames (no collisions)
- MD5-based caching for instant replay

## Security

- File size limits (10MB default)
- Filename sanitization
- Subprocess calls without shell injection
- Read-only source code mount in Docker Compose
- Rate limiting ready (add Redis for multi-instance)

## Troubleshooting

**Build fails:**

- Ensure Docker Desktop is running
- Check internet connection (downloads UADE from GitLab)
- Try: `docker-compose build --no-cache`

**"502 Bad Gateway" or health check fails:**

- Check logs: `docker-compose logs -f`
- Verify port 5000 is not in use
- Wait 30s for container initialization

**Conversion errors:**

- Check file format is supported by UADE
- For TFMX, ensure both URLs are correct
- Large files may timeout (5 min limit)

**Cleanup not working:**

- Check container has write access to `/tmp`
- Verify CLEANUP_INTERVAL environment variable

## Development

### Local Development

```powershell
# Install Python dependencies
python -m venv venv
venv\Scripts\activate
pip install flask werkzeug requests gunicorn

# Run development server (requires UADE installed)
cd web
python server.py
```

### Hot Reload with Docker

```yaml
# docker-compose.override.yml (local development)
services:
  uade-web:
    volumes:
      - ./web:/app # Remove :ro for hot reload
    command: python3 server.py # Use Flask dev server
    environment:
      - FLASK_ENV=development
```

## Performance

- **Conversion time:** 5-30 seconds (depends on module length)
- **FLAC compression:** Adds 1-2 seconds but reduces download by 50-70% for bandwidth savings
- **Cache performance:** Instant playback on second request (MD5-based)
- **Memory usage:** ~256MB per instance
- **CPU usage:** Spikes during conversion/compression, idle otherwise
- **Concurrent requests:** Handled by Gunicorn workers (4 default)

### Example File Sizes

| Format              | WAV Size | FLAC Size | Reduction |
| ------------------- | -------- | --------- | --------- |
| Protracker (3min)   | 25MB     | 10-12MB   | ~55%      |
| TFMX (5min)         | 50MB     | 25-30MB   | ~45%      |
| AHX Chiptune (2min) | 20MB     | 8-10MB    | ~60%      |

## Limitations

- Max file size: 10MB (configurable)
- Conversion timeout: 5 minutes
- No real-time streaming during conversion
- Files auto-delete after 1 hour

## Links

- **UADE Home:** <https://zakalwe.fi/uade/>
- **UADE Repository:** <https://gitlab.com/uade-music-player/uade>
- **GitHub Project:** <https://github.com/rib1/uade-docker>
- **Modland Archive:** <https://modland.com/pub/modules/>
- **Module Archive:** <https://modarchive.org>
- **Exotica:** <https://www.exotica.org.uk/> (Demoscene music archive)
- **scene.org:** <https://files.scene.org/browse/music> (Demoscene file archive)

## License

GPL v2 (same as UADE)

## Contributing

Contributions welcome!

```bash
git checkout -b feature/my-feature main
# Make changes
git push origin feature/my-feature
```
