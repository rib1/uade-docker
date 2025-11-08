# UADE Web Player

Play Amiga music modules directly in your web browser! No desktop software required.

## Features

- 🎵 **Play in Browser** - Upload or download modules, hear them instantly
- 🎮 **Example Modules** - Try famous Amiga classics with one click
- 🌐 **URL Support** - Download directly from Modland, ModArchive, etc.
- 🎹 **TFMX Support** - Handles dual-file TFMX modules automatically
- ⬇️ **Download WAV** - Save converted files for offline playback
- 🚀 **Cloud Ready** - Designed for Kubernetes, EKS Auto Mode, and cloud platforms
- 📱 **Mobile Friendly** - Works on phones and tablets

## Quick Start

### Using Docker Compose (Recommended)

```powershell
# Clone the repository
git clone https://github.com/rib1/uade-docker.git
cd uade-docker

# Switch to web-player branch
git checkout web-player

# Start the web player
docker-compose up -d

# Access at: http://localhost:5000
```

### Manual Docker Build

```powershell
# Build the image
docker build -f Dockerfile.web -t uade-web-player .

# Run the container
docker run -p 5000:5000 uade-web-player

# Access at: http://localhost:5000
```

## Usage

### 1. Try Example Modules

Click any example module on the homepage to instantly hear classic Amiga music:
- Captain - "Space Debris" (ProTracker)
- Lizardking - "Doskpop" (ProTracker)
- Pink - "Stormlord" (AHX chiptune)
- Rob Hubbard - "Populous" (ProTracker)
- Chris Huelsbeck - "Turrican 2" (TFMX)

### 2. Upload Your Files

Drag and drop .mod, .ahx, or other module files directly into the browser.

### 3. Download from URL

Paste a Modland or ModArchive URL to download and convert automatically.

**Example URLs:**
```
https://modland.com/pub/modules/Protracker/Captain/space%20debris.mod
https://modland.com/pub/modules/AHX/Pink/stormlord.ahx
```

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
FLASK_ENV: production              # Flask environment
PORT: 5000                        # Server port
MAX_UPLOAD_SIZE: 10485760         # Max upload (10MB)
CLEANUP_INTERVAL: 3600            # File cleanup (1 hour)
RATE_LIMIT: 10                    # Max conversions/min per IP
```

## Cloud Deployment

### AWS EKS Auto Mode

The application is designed to run on Kubernetes/EKS:

**1. Build and push to ECR:**

```bash
# Authenticate to ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <account>.dkr.ecr.us-east-1.amazonaws.com

# Build and tag
docker build -f Dockerfile.web -t uade-web-player .
docker tag uade-web-player:latest <account>.dkr.ecr.us-east-1.amazonaws.com/uade-web-player:latest

# Push
docker push <account>.dkr.ecr.us-east-1.amazonaws.com/uade-web-player:latest
```

**2. Create Kubernetes deployment:**

```yaml
# k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: uade-web-player
spec:
  replicas: 3
  selector:
    matchLabels:
      app: uade-web-player
  template:
    metadata:
      labels:
        app: uade-web-player
    spec:
      containers:
      - name: uade-web-player
        image: <account>.dkr.ecr.us-east-1.amazonaws.com/uade-web-player:latest
        ports:
        - containerPort: 5000
        env:
        - name: FLASK_ENV
          value: "production"
        - name: MAX_UPLOAD_SIZE
          value: "10485760"
        - name: CLEANUP_INTERVAL
          value: "3600"
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /health
            port: 5000
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 5000
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: uade-web-player-service
spec:
  type: LoadBalancer
  selector:
    app: uade-web-player
  ports:
  - protocol: TCP
    port: 80
    targetPort: 5000
```

**3. Deploy:**

```bash
kubectl apply -f k8s/deployment.yaml
kubectl get service uade-web-player-service  # Get LoadBalancer URL
```

### Azure Container Instances

```bash
az container create \
  --resource-group myResourceGroup \
  --name uade-web-player \
  --image <registry>/uade-web-player:latest \
  --dns-name-label uade-player \
  --ports 5000 \
  --environment-variables \
    FLASK_ENV=production \
    MAX_UPLOAD_SIZE=10485760
```

### Google Cloud Run

```bash
# Build and push to GCR
gcloud builds submit --tag gcr.io/<project>/uade-web-player

# Deploy
gcloud run deploy uade-web-player \
  --image gcr.io/<project>/uade-web-player \
  --platform managed \
  --region us-central1 \
  --allow-unauthenticated \
  --port 5000 \
  --memory 512Mi \
  --timeout 300s
```

## Architecture

### Multi-Stage Build
- **Stage 1 (base):** Compile UADE and dependencies from source
- **Stage 2 (runtime):** Lightweight image with Python/Flask + UADE binaries

### Production Server
- Uses **Gunicorn** with 4 workers (configurable)
- Health checks for container orchestration
- Structured logging for cloud platforms
- Graceful shutdown handling

### File Management
- Automatic cleanup of files older than 1 hour
- Separate directories: uploads, conversions, cache
- UUID-based filenames (no collisions)

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
      - ./web:/app  # Remove :ro for hot reload
    command: python3 server.py  # Use Flask dev server
    environment:
      - FLASK_ENV=development
```

## Performance

- Conversion time: 5-30 seconds (depends on module length)
- Memory usage: ~256MB per instance
- CPU usage: Spikes during conversion, idle otherwise
- Concurrent requests: Handled by Gunicorn workers (4 default)

## Limitations

- Max file size: 10MB (configurable)
- Conversion timeout: 5 minutes
- No real-time streaming during conversion
- Files auto-delete after 1 hour

## Links

- **UADE Home:** https://zakalwe.fi/uade/
- **UADE Repository:** https://gitlab.com/uade-music-player/uade
- **GitHub Project:** https://github.com/rib1/uade-docker
- **Modland Archive:** https://modland.com/pub/modules/
- **Module Archive:** https://modarchive.org

## License

GPL v2 (same as UADE)

## Contributing

Contributions welcome! This is the `web-player` branch.

```bash
git checkout -b feature/my-feature web-player
# Make changes
git push origin feature/my-feature
```
