# UADE Docker - System Architecture

This document describes the architecture of the UADE Docker system, showing both the CLI and Web Player deployments.

## System Architecture Diagram

```mermaid
architecture-beta
    group user(cloud)[User Interface]
    group local(server)[Local Docker]
    group gcp(cloud)[Google Cloud Platform]
    
    service browser(internet)[Web Browser] in user
    service cli(disk)[Command Line] in user
    
    service docker_cli(server)[UADE CLI Container] in local
    service docker_web(server)[UADE Web Container] in local
    
    service github(internet)[GitHub Actions] in gcp
    service gcr(database)[Container Registry] in gcp
    service cloudrun(server)[Cloud Run Service] in gcp
    
    service modland(internet)[Modland Archive]
    
    browser:B --> T:cloudrun
    cli:B --> T:docker_cli
    browser:B --> T:docker_web
    
    github:R --> L:gcr
    gcr:R --> L:cloudrun
    
    cloudrun:B --> T:modland
    docker_web:B --> T:modland
    docker_cli:B --> T:modland
```

## Components

### User Interface Layer

- **Web Browser** - Access web player via HTTPS
- **Command Line** - Run Docker commands locally via PowerShell/Bash

### Local Docker Layer

- **UADE CLI Container** (`uade-player`)
  - Debian stable-slim base
  - UADE player compiled from source
  - Command-line interface for module conversion
  - Non-root user (uid=1000)

- **UADE Web Container** (`uade-web-player`)
  - Multi-stage build using UADE CLI as base
  - Flask web application + Gunicorn
  - Python 3 with virtual environment
  - Supports file upload and URL downloads
  - Non-root user (uid=1000)

### Google Cloud Platform Layer

- **GitHub Actions**
  - Automated CI/CD pipeline
  - Builds Docker images on push to main
  - Change detection for UADE base caching
  - Runs tests and health checks

- **Container Registry (GCR)**
  - Stores built Docker images
  - UADE base image cached for faster builds
  - Web player image with git commit tags

- **Cloud Run Service**
  - Serverless container deployment
  - Auto-scaling (0-10 instances)
  - Minimal service account (zero permissions)
  - gVisor sandbox isolation
  - 2Gi memory, 2 CPU, 300s timeout

### External Services

- **Modland Archive**
  - HTTP access to module database
  - ProTracker, TFMX, AHX formats
  - Direct download support

## Data Flow

### CLI Workflow

1. User runs Docker command with module file
2. UADE CLI container processes module
3. Converts to WAV/FLAC format
4. Outputs to mounted volume
5. User plays converted file locally

### Web Player Workflow

1. User uploads module or provides URL
2. Flask server receives request
3. Downloads module (if URL provided)
4. Calls UADE player subprocess
5. Converts to WAV or FLAC
6. Streams audio back to browser
7. Cleans up temporary files (1 hour TTL)

### Deployment Workflow

1. Developer pushes code to GitHub
2. GitHub Actions triggered
3. Checks if UADE base needs rebuild
4. Builds web player image (with caching)
5. Pushes to Container Registry
6. Deploys to Cloud Run
7. Runs health check validation

## Security Model

### Container Security

- Non-root user (uid=1000) in all containers
- Minimal base images (Debian stable-slim)
- No shell=True in subprocess calls
- Read-only application directory
- Writable temp directories only

### Cloud Run Security

- Minimal service account with zero IAM roles
- gVisor sandbox isolation
- No GCP API access
- HTTPS only with managed certificates
- Max 10 instances (DoS protection)
- Budget alerts at $1/month

### Application Security

- UUID-based filenames (path traversal prevention)
- File size limits (10MB uploads)
- Process timeouts (300s max)
- Automatic file cleanup
- Input validation and sanitization
- Zero HIGH severity security issues (Bandit, ESLint)

## Technology Stack

### Backend

- **Language:** Python 3
- **Framework:** Flask 3.0.0
- **Server:** Gunicorn 21.2.0
- **Audio Processing:** UADE player, FLAC encoder

### Frontend

- **Language:** JavaScript (ES6+)
- **Styling:** CSS3 with ProTracker theme
- **Icons:** ProTracker favicon

### Infrastructure

- **Container Runtime:** Docker
- **Orchestration:** Docker Compose (local), Cloud Run (production)
- **CI/CD:** GitHub Actions
- **Registry:** Google Container Registry
- **Cloud Provider:** Google Cloud Platform

### Development

- **Linting:** Black (Python), ESLint (JS), Hadolint (Docker), Prettier (All)
- **Security:** Bandit, W3C Validator
- **Version Control:** Git, GitHub
- **Documentation:** Markdown, Mermaid

## Performance Optimizations

### Docker Build

- Multi-stage builds
- Layer caching with `--cache-from`
- UADE base image caching
- Change detection (only rebuild when needed)
- `.dockerignore` excludes test files

### Application

- Single Gunicorn worker (memory optimization)
- 4 threads per worker
- Connection pooling
- Temporary file cleanup (hourly)
- Cache directory for downloads

### Cloud Run

- Auto-scaling from 0 to 10 instances
- 2Gi memory allocation
- 2 CPU allocation
- Keep-alive connections (5s)
- Graceful shutdown (300s)

## Monitoring

- Cloud Run logs (errors, requests)
- Health endpoint (`/health`)
- Git commit tracking in responses
- Budget alerts
- Network egress monitoring (1GB free tier)
