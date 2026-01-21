# UADE Web Player

Play Amiga music modules directly in your web browser! No desktop software required.

## Features

- 🎵 **Play in Browser** - Upload or download modules, hear them instantly
- 🕹️ **Example Modules** - Try famous Amiga classics with one click
- 🌐 **URL Support** - Download directly from Modland, ModArchive, etc.
- 📦 **LHA & ZIP Archive Support** - Automatically extracts classic Amiga LHA archives (and ZIP)
- 🗂️ **Dual-File Module Support** - Handles dual-file modules (e.g., TFMX, RJP) automatically
- 💿 **Smart Compression** - Automatic FLAC compression for capable browsers (50-70% smaller files)
- ⬇️ **Download Audio** - Save as FLAC or WAV for offline playback
- 🚀 **Cloud Ready & Stateless Caching** - Designed for cloud platforms with stateless, shareable server-side cache support (S3/GCS/local).
- 💻 **Client-Side Caching** - Converted audio is cached in your browser for one month for instant repeat playback.
- ✅ **Cache Indicator** - The UI indicates when audio is served from the server-side cache.
- 📱 **Mobile Friendly** - Works on phones and tablets
- 🎵 **Media Session Integration** - Control playback from your phone's lock screen, with track and format information.
- ⚡ **Performance** - MD5-based module file and URL caching for instant replay and computing and bandwidth savings

## Quick Start

### Using Docker Compose (Recommended)

The easiest way to run the UADE Web Player locally:

```powershell
# Clone the repository
git clone https://github.com/rib1/uade-docker.git
cd uade-docker

# Start the web player
docker compose up -d uade-web

# Access at: http://localhost:5000
```

**What Docker Compose provides:**

- Automatic build and startup
- Health checks with auto-restart
- Persistent storage for uploads/conversions
- Web runtime environment configuration
- Read-only source code mount for security
- Cleanup of old files (1 hour interval)

**Managing the service:**

```powershell
# View logs
docker compose logs -f uade-web

# Stop the service
docker compose down uade-web # or docker compose down for all services

# Rebuild after code changes (for web player only)
docker compose up -d --build uade-web
# To inject the current git commit hash into the container, run:
$env:GIT_COMMIT = (git rev-parse HEAD); docker compose up -d --build uade-web

# View service status
docker compose ps
```

**Configuration:**

The `docker-compose.yml` includes these environment variables:

```yaml
FLASK_ENV: production # Production mode
MAX_UPLOAD_SIZE: 10485760 # 10MB max upload
MAX_DOWNLOAD_SIZE: 10485760 # 10MB max download from URLs
CLEANUP_INTERVAL: 3600 # Local files deleted after 1 hour
CACHE_CLEANUP_INTERVAL: 86400 # Cache purged after 24 hours
RATE_LIMIT_DISABLED: 1  # disable rate limiting for local testing
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

For manual control without Docker Compose:

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
- Chris Huelsbeck - "Turrican 2" (TFMX)

### 2. Upload Your Files

Drag and drop .mod, .ahx, or other module files directly into the browser.

> **Tip:** If the module has been converted before, the player will instantly serve it from cache and display a "From cache" message.

**Supported formats:**

- Individual modules (mod., .ahx, .tfmx, .okta, .sid, etc.)
- Full list of supported formats: <https://gitlab.com/uade-music-player/uade/-/tree/master/players>
- Modules inside LHA (.lha) and ZIP (.zip) archives are automatically extracted and played.

### 3. Download from URL

Paste a Modland, ModArchive or other URL to download and convert automatically. This section also supports dual-file modules.

For dual-file modules (e.g., TFMX, RJP), you can expand the details section to provide an optional second URL for the sample data.

> **Tip:** If the module has been converted before, the player will instantly serve it from cache and display a "From cache" message.

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
  "url": "https://modland.com/pub/modules/...",
  "sample_url": "https://..." // Optional
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

### Stream/Download WAV/FLAC

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
MAX_DOWNLOAD_SIZE: 10485760 # Max download from URLs (10MB)
CLEANUP_INTERVAL: 3600 # File cleanup (1 hour)
CACHE_CLEANUP_INTERVAL: 86400 # Cache cleanup interval (24 hours)
CACHE_URI: file:///tmp/cache # Remote cache URI (default: file:///tmp/cache)
RATE_LIMIT: 200 # Max Requests/hour per IP (all endpoints combined)
RATE_LIMIT_DISABLED: 0 # Set to 1 to disable rate limiting for local development/testing
GIT_COMMIT: unknown # Git commit hash (set automatically at build time)
UADE_TEST_MODE: 0 # Set to 1 to enable test mode (allows internal test server access)
```

## Caching

UADE Web Player uses two layers of caching to optimize performance, reduce bandwidth, and provide instant playback.

### 1. Client-Side (Browser) Caching

When you play an audio file, it is stored in your browser's cache for **one month**. The server sends a `Cache-Control` header that tells your browser to store the audio file. Because converted files have unique, content-based IDs, they are marked as `immutable`.

### 2. Server-Side Caching

The server maintains its own cache of converted audio files. This is primarily for efficiency in multi-instance or cloud-native deployments.

- **Stateless & Shared:** All server instances can connect to a shared cache (e.g., AWS S3, GCS, or a shared disk), allowing them to share converted files.
- **Deduplication:** If one user converts a module, it becomes available instantly to all other users without needing to be converted again.
- **Backend Options:** The cache can be a local directory, an AWS S3 bucket, or a Google Cloud Storage bucket.
- **Cleanup:** This cache is periodically cleaned of old files (default is 24 hours).

**Configuration:**

Set the `CACHE_URI` environment variable to your desired cache location:

```yaml
CACHE_URI: file:///tmp/cache        # Local cache (default)
CACHE_URI: s3://your-bucket/cache   # AWS S3 remote cache
CACHE_URI: gcs://your-bucket/cache  # Google Cloud Storage remote cache
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

### File Management

- Automatic cleanup of local files older than 1 hour
- Separate directories: modules, conversions, cache
- UUID-based filenames (no collisions)
- URL-based caching: If the same URL is requested again, the cached file is reused instantly
- MD5-based Stateless Remote Cache: Converted files are stored in a remote cache (S3/GCS/local) for instant replay and deduplication across all instances

## Security

- File size limits (10MB default)
- Filename sanitization
- Subprocess calls without shell injection
- Read-only source code mount in Docker Compose
- Rate limiting ready (add Redis for multi-instance)

## Rate Limiting

UADE Web Player uses per-endpoint and global rate limits to prevent abuse and ensure fair usage:

- **Conversion endpoints** (`/upload`, `/convert-url`): 10 requests per minute per IP
- **Play endpoints** (`/play`, `/play-example`): 50 requests per minute per IP
- **Download endpoint** (`/download`): 3 requests per minute per IP
- **Global limit**: 200 requests per hour per IP (all endpoints combined)

> **Note:**
> Rate limits are enforced per instance/pod. In multi-instance/cloud deployments, limits are not global unless a distributed backend (e.g., Redis) is configured for Flask-Limiter.

You can adjust limits via the `RATE_LIMIT` and `RATE_LIMIT_DISABLED` environment variables and endpoint decorators in `server.py`.

## Accessibility (WCAG Compliance)

The UADE Web Player strives to meet Web Content Accessibility Guidelines (WCAG) 2.1 AA standards to ensure a usable experience for all. Key accessibility features include:

### Color Contrast

UI elements maintain a minimum contrast ratio of 4.5:1 for normal text, complying with WCAG AA requirements. This applies to:

- **Format Badges:** Background colors for badges in example cards and the player section ensure sufficient contrast with white text.
- **Primary Buttons:** Default and hover states for primary buttons meet contrast guidelines.
- **Warning and Status Messages:** Text color for messages have sufficient contrast against their background.

### Semantic Structure and Landmark Roles

The HTML structure includes appropriate landmark roles, aiding navigation for users of assistive technologies:

- **Header:** The top section of each page, containing introductory content or navigational links, is semantically marked with a `<header>` tag.
- **Main Content Landmark:** Primary content sections of the application are enclosed within a `<main>` tag, allowing screen readers to easily navigate to the main content area.
- **Footer:** The bottom section of each page, typically containing copyright information, navigation, or contact details, is semantically marked with a `<footer>` tag.

### Form Field Labels

Interactive input fields have associated accessible names to ensure they are properly identified by assistive technologies:

- **`aria-label` Attributes:** Input fields for URL entry utilize `aria-label` attributes, providing clear programmatic labels for screen reader users.

## Troubleshooting

**Build fails:**

- Ensure Docker Desktop is running
- Check internet connection (downloads UADE from GitLab)
- Try: `docker compose build --no-cache`

**"502 Bad Gateway" or health check fails:**

- Check logs: `docker compose logs -f`
- Verify port 5000 is not in use
- Wait 30s for container initialization

**Conversion errors:**

- Check file format is supported by UADE
- For TFMX, ensure both URLs are correct
- Large files may timeout (5 min limit)

**Cleanup not working:**

- Check container has write access to `/tmp`
- Verify CLEANUP_INTERVAL environment variable

**Server-Side Cache Issues (S3/GCS/local):**

- **Permission denied / Access errors:**
  - Ensure your IAM/user/role has read/write access to the bucket/prefix.
  - For S3, check bucket policy and credentials (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY).
  - For GCS, check service account permissions and `GOOGLE_APPLICATION_CREDENTIALS`.
- **File not found / cache misses:**
  - Confirm `CACHE_URI` is set correctly (e.g., `s3://your-bucket/cache`).
  - Make sure the cache prefix exists and is writable.
  - Check for typos in bucket or path names.
- **Performance issues:**
  - Remote cache may be slower than local disk; use local cache for development/testing.
  - For S3/GCS, avoid frequent small file operations; batch uploads if possible.
- **fsspec errors:**
  - Ensure `s3fs` (for S3) or `gcsfs` (for GCS) is installed in your environment.
  - Check Python logs for detailed error messages.
- **Multi-instance consistency:**
  - All instances must use the same `CACHE_URI` value.
  - Remote cache should be globally accessible and not ephemeral.

If issues persist, run with debug logging enabled and check cloud provider logs for more details.

## Development

### Running Tests

To run the integration tests using Docker Compose:

1. **Build and run the test runner service (one time setup):**

    ```powershell
    $env:GIT_COMMIT = (git rev-parse HEAD); docker compose up --build uade-test-runner
    ```

    This will build the `uade-test-runner` image and run the tests. The container will exit after the tests are completed.

2. **To run tests again (after initial setup):**

    ```powershell
    docker compose run --rm uade-test-runner
    ```

    This command will run the tests in a new container and remove it upon completion (`--rm`).
    The `uade-web` service must be running and healthy for the tests to pass.

### Security Testing (DAST)

UADE Web Player supports manual Dynamic Application Security Testing (DAST) using OWASP ZAP. To run a security scan against the running web service:

- Run: `docker compose up --build zap-scan`
- The HTML report will be generated in the `./reports` directory.

DAST scans are not automated in CI/CD and must be run manually by developers.

### Local Development

```powershell
# Install Python dependencies
python -m venv venv
venv\Scripts\activate
pip install -r requirements.txt

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
- **Cache Performance:** Subsequent plays are instant, served from either the client-side (browser) or server-side cache.
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
