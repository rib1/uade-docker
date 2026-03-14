# UADE Docker - AI Agent Instructions

## Project Overview

This is a Docker-based system for playing/converting **Amiga music modules** (100+ formats from 1980s-90s) using UADE (Unix Amiga Delitracker Emulator). Two deployment modes:

1. **CLI** (`Dockerfile`) - Standalone UADE binary in Debian container for local conversion
2. **Web Player** (`Dockerfile.web`) - Flask/Gunicorn web app with drag-drop UI, deployed to Google Cloud Run

## Project Philosophy: Minimal Dependencies

**Core Principle:** Keep code and development environment as minimal as possible.

- **Zero local dependencies** - All development tools run inside Docker containers (ESLint, Black, ActionLint, Hadolint)
- **Minimal external libraries** - Avoid frameworks and libraries where vanilla solutions work (e.g., vanilla JavaScript instead of React/Vue)
- **Docker-first tooling** - Code quality checks, tests, and builds all use containerized tools
- **No local setup required** - Developers only need Docker; no Python/Node.js/linters installed locally

**Examples:**
- Frontend: Pure JavaScript (no bundlers, no frameworks) - just `app.js`, `index.html`, `style.css`
- Backend: Single `server.py` file instead of complex module structure
- Code quality: `./test/check-code-quality.sh` runs all checks in Docker with zero local installs
- Testing: Integration tests implemented with shell scripts and run via Docker Compose, no local test dependencies

## Architecture Pattern: Versioned Base Image

**Critical:** The web player uses a **pinned, versioned base image** for UADE binaries. This is NOT a typical multi-stage build pattern:

- `Dockerfile` builds `uade-cli:<VERSION>-base.<BUILD>` (e.g., `3.05-base.2`)
- `Dockerfile.web` references this via `ARG BASE_IMAGE=ghcr.io/rib1/uade-cli:3.05-base.1`
- Base image updates are **handled by a separate CI pipeline** (`.github/workflows/build-base-image.yml`)
- Web player depends on stable base; see [docs/DOCKER_VERSIONING.md](../docs/DOCKER_VERSIONING.md)

**When editing Dockerfiles:**
- Never change base image version in `Dockerfile.web` without checking versioning docs
- Base image builds are infrequent (only on UADE upstream updates or security patches)
- Web player changes do NOT trigger base image rebuild

## Code Organization (Web Player)

**Note:** The CLI mode uses the UADE binary directly from shell with no external code except for the `uade-convert` helper script (embedded in Dockerfile). This section covers the web player only.

### Backend (web/server.py)

The Flask app is a **single 2200+ line file** with clear functional sections:

1. **Lines 1-225:** Imports, logging, Flask app init, rate limiting setup
2. **Lines 226-650:** Constants (extensions, dual-file modules), utility functions (filesystem, cache, cleanup)
3. **Lines 651-985:** Archive handling (LHA/ZIP extraction, module detection, metadata)
4. **Lines 986-1400:** Core UADE conversion logic (subprocess execution, subsong parsing, WAV/FLAC compression)
5. **Lines 1406-2259:** Flask routes (`/upload`, `/play`, `/download`, `/health`, `/examples`)

**Key patterns:**
- All file operations use `Path` objects from `pathlib`
- Subprocess calls to `uade123` binary with `capture_output=True, text=True, timeout=300`
- Cache keys are MD5 hashes: `hashlib.md5(file_content).hexdigest()` or URL-based
- FLAC compression conditional on User-Agent: `supports_flac(request.headers.get("User-Agent"))`

### Frontend (web/static/)

**Structure:**
- `index.html` - Single-page app with sections: examples grid, drag-drop upload, URL download form, audio player
- `app.js` (900+ lines) - Vanilla JavaScript, no frameworks
- `style.css` - Responsive design with mobile-first approach

**JavaScript Architecture:**
- **Global state:** `currentDownloadUrl`, `currentSubsongIndex`, `currentSubsongDurations`
- **UI Lock Pattern:** `setUiLock()` / `releaseUiLock()` prevent concurrent conversions
- **Async workflows:** All conversions go through `performConversion()` which handles status updates, errors, and success callbacks
- **Large file downloads:** `downloadWithRangeRequests()` uses 10MB chunks to avoid 32MB Cloud Run response limits
- **Media Session API:** `updateMediaSession()` enables lock screen controls on mobile

**Key Functions:**
- `handleFileUpload()` - Drag-drop and file input handler
- `handleUrlConvert()` - URL form with optional dual-file support (TFMX mdat/smpl)
- `playFile()` - Plays audio, shows player UI, handles subsongs, updates Media Session
- `loadExamples()` - Fetches `/examples` endpoint and populates grid
- `setupDragAndDrop()` - Native HTML5 drag-drop events with visual feedback

**Client-Side Caching:**
- Browser caches converted audio for 1 month via standard HTTP caching headers
- Cache indicator in UI shows when audio served from server cache

## Development Workflow

### Local Testing
```powershell
# Start the production-like local web player:
docker compose up -d --build uade-web

# Start the development stack with hot reload:
docker compose -f docker-compose.yml -f docker-compose.dev.yml up --build uade-web

# View logs:
docker compose logs -f uade-web

# Run integration tests (requires running web player):
docker compose -f docker-compose.yml -f test/docker-compose.endpoints.yml up --build uade-test-runner
```

**⚠️ Critical: Always test before committing** - Run code quality checks and integration tests to verify changes work correctly.

### Code Quality (Zero Local Dependencies)
```bash
# All checks (ESLint, Black, ActionLint, Hadolint):
./test/check-code-quality.sh

# Windows powershell:
.\test\check-code-quality.ps1

# Auto-fix issues:
./test/check-code-quality.sh --fix

# Windows users:
.\test\check-code-quality.ps1 -Fix
```

**Configuration:**
- Python: Black formatting at 100 chars (see `pyproject.toml`)
- JavaScript: ESLint with custom config in `web/static/eslint.config.js`
- Workflows: ActionLint validates all `.github/workflows/*.yml`
- Dockerfiles: Hadolint with inline `# hadolint ignore=DL3059` exceptions

## CI/CD Pipeline Specifics

**Build Triggers (`.github/workflows/build-deploy-web-player.yml`):**
- Runs on push to `main` when `web/**`, `Dockerfile.web`, or `.github/workflows/build-deploy-web-player.yml` changes
- **Does NOT rebuild base image** - pulls `ghcr.io/rib1/uade-cli:latest` from cache
- Tags: `latest`, `stable` (main branch), `<git-sha>` (every commit)

**Health Checks:**
- Container: `curl -f http://localhost:5000/health` (30s interval, 3 retries)
- CI: Tests `/health`, `/examples`, and `flac --version` availability

**Critical environment injection:**
```dockerfile
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}
```
Displayed in UI footer and `/health` response for deployment verification.

## Google Cloud Run Deployment

**Automated deployment** triggers on every push to `main` after successful build:

**⚠️ Single Environment:** There is only ONE Cloud Run service. Pull requests that trigger deployment will replace the stable production version. No separate staging/preview environments exist. PRs include a comment with a link to manually revert to the stable version via the Actions tab.

**Cloud Run Configuration:**
- **Region:** `us-central1`
- **Resources:** 2Gi memory, 1 CPU, 8 concurrent requests
- **Scaling:** 0-10 instances (serverless, scales to zero)
- **Timeout:** 300s (5 minutes for long conversions)
- **Service account:** Minimal permissions (zero IAM roles)
- **Response limit:** 32MB (handled via chunked transfers and range requests)

**Environment variables set during deployment:**
```bash
FLASK_ENV=production
MAX_UPLOAD_SIZE=10485760  # 10MB
CLEANUP_INTERVAL=3600  # 1 hour
CACHE_CLEANUP_INTERVAL=86400  # 24 hours
RATE_LIMIT=200  # requests/hour
CACHE_URI=file:///tmp/cache
RATE_LIMIT_DISABLED=0  # Rate limiting ON in production
```

**Deployment workflow:**
1. Build and test web player in CI
2. Push to GHCR with git SHA tag
3. Authenticate to GCP using `GCP_SA_KEY` secret
4. Pull image from GHCR and retag for GCR
5. Deploy to Cloud Run with `gcloud run deploy`
6. Run health check against deployed service
7. Comment PR with deployment URL (for PRs only)

**Important:** Deployment requires `GCP_PROJECT_ID` and `GCP_SA_KEY` secrets configured in GitHub repository.

## Rate Limiting Strategy

Uses `flask-limiter` with Redis-like storage (in-memory for now):

```python
@limiter.limit(f"{DOWNLOAD_RATE_LIMIT}/minute")  # 6/minute for downloads
@limiter.limit(f"{RATE_LIMIT}/hour")             # 200/hour global limit
```

**Test mode note:** `UADE_TEST_MODE=1` enables app test behavior such as internal test-server allowances. Rate limiting is controlled separately via `RATE_LIMIT_DISABLED`.

## Archive Handling (LHA/ZIP)

Amiga modules often come in **LHA archives** (classic Amiga compression). The system:

1. Detects LHA/ZIP via magic bytes: `is_lha_file()`, `is_zip_file()`
2. Extracts to temp dir: `extract_lha()` uses `/usr/bin/lha` binary
3. Searches for the first playable module: `find_music_file()` checks file extensions
4. Dual-file modules (TFMX mdat/smpl, RJP .mdat/.smp) auto-detected and paired

**Supported module extensions** (line 226):
```python
MODULE_FILE_EXTENSIONS = {'mod', 's3m', 'it', 'xm', 'tfmx', 'ahx', 'hvl', 'mdat', 'smp', ...}
```

## Testing Structure

- **Integration tests:** Shell scripts in `test/` directory (`test_endpoints.sh`, `test_ratelimit.sh`, `test_race_condition.sh`)
- **Test execution:** Docker Compose orchestrates tests via `test/docker-compose.*.yml` files
- **DAST scanning:** OWASP ZAP via `docker compose up zap-scan` (reports to `./reports/`)

## Common Pitfalls

1. **Don't use `docker build` directly for web player** - use `docker compose` to inject `GIT_COMMIT` env var
2. **Archive extraction requires temp storage** - local Docker Compose provides persistent temp storage via a `/tmp` volume, while Cloud Run uses the container filesystem at runtime
3. **UADE needs an audio device even in conversion mode** - The workaround uses the SUID bit: `chmod 4750 /usr/local/bin/uade123` allows a non-root user to run as root (see Dockerfile lines 100-102)
4. **Dual-file modules need special handling** - Look for `.mdat`/`.smpl` pairs in `detect_module_metadata()`
5. **Windows paths:** Use `Path` objects and forward slashes in Docker volume mounts

## File References

- Architecture diagram: [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md)
- Versioning strategy: [docs/DOCKER_VERSIONING.md](../docs/DOCKER_VERSIONING.md)
- Code quality setup: [docs/CODE-QUALITY.md](../docs/CODE-QUALITY.md)
- Web player guide: [docs/WEB-PLAYER.md](../docs/WEB-PLAYER.md)
