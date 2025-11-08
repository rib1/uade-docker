# UADE Web Player - Deployment Guide

This guide covers deploying the UADE Web Player to various cloud platforms.

## Table of Contents

- [AWS EKS Auto Mode](#aws-eks-auto-mode)
- [Azure Container Instances](#azure-container-instances)
- [Google Cloud Run](#google-cloud-run)
- [Configuration](#configuration)

## AWS EKS Auto Mode

The application is designed to run on Kubernetes/EKS with auto-scaling.

### 1. Build and Push to ECR

```bash
# Authenticate to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  <account>.dkr.ecr.us-east-1.amazonaws.com

# Build and tag
docker build -f Dockerfile.web -t uade-web-player .
docker tag uade-web-player:latest \
  <account>.dkr.ecr.us-east-1.amazonaws.com/uade-web-player:latest

# Push
docker push <account>.dkr.ecr.us-east-1.amazonaws.com/uade-web-player:latest
```

### 2. Create Kubernetes Deployment

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

### 3. Deploy to EKS

```bash
kubectl apply -f k8s/deployment.yaml
kubectl get service uade-web-player-service  # Get LoadBalancer URL
```

## Azure Container Instances

Simple deployment to Azure Container Instances:

```bash
az container create \
  --resource-group myResourceGroup \
  --name uade-web-player \
  --image <registry>/uade-web-player:latest \
  --dns-name-label uade-player \
  --ports 5000 \
  --environment-variables \
    FLASK_ENV=production \
    MAX_UPLOAD_SIZE=10485760 \
    CLEANUP_INTERVAL=3600
```

Access at: `http://uade-player.<region>.azurecontainer.io:5000`

## Google Cloud Run

Serverless deployment with automatic scaling:

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
  --timeout 300s \
  --set-env-vars FLASK_ENV=production,MAX_UPLOAD_SIZE=10485760
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `FLASK_ENV` | `production` | Flask environment mode |
| `PORT` | `5000` | Server port |
| `MAX_UPLOAD_SIZE` | `10485760` | Max upload size (10MB) |
| `CLEANUP_INTERVAL` | `3600` | File cleanup interval (seconds) |
| `RATE_LIMIT` | `10` | Max conversions per minute per IP |

### Docker Compose Example

```yaml
version: '3.8'
services:
  uade-web:
    build:
      context: .
      dockerfile: Dockerfile.web
    ports:
      - "5000:5000"
    environment:
      - FLASK_ENV=production
      - MAX_UPLOAD_SIZE=10485760
      - CLEANUP_INTERVAL=3600
    volumes:
      - ./web:/app:ro
      - uade-tmp:/tmp
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5000/health"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  uade-tmp:
```

## Security Considerations

### Production Checklist

- [ ] Enable HTTPS (use reverse proxy or cloud load balancer)
- [ ] Set proper CORS headers if needed
- [ ] Configure rate limiting (consider Redis for multi-instance)
- [ ] Use secrets management for sensitive configs
- [ ] Enable authentication if required
- [ ] Monitor resource usage and set alerts
- [ ] Configure backup/disaster recovery

### Network Security

```yaml
# Example: Restrict to private network
apiVersion: v1
kind: Service
metadata:
  name: uade-web-player-service
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-internal: "true"
spec:
  type: LoadBalancer
  # ... rest of service config
```

## Monitoring

### Health Check Endpoint

```bash
curl http://localhost:5000/health
```

Returns:

```json
{
  "status": "healthy",
  "timestamp": "2025-11-08T12:34:56.789Z",
  "uade_available": true
}
```

### Logging

Logs are written to stdout in structured format:

```text
2025-11-08 12:34:56,789 - server - INFO - Successfully converted: /tmp/cache/abc123_mod -> /tmp/converted/abc123.wav
```

View logs:


```bash
# Docker Compose
docker-compose logs -f uade-web

# Kubernetes
kubectl logs -f deployment/uade-web-player
```

## Performance Tuning

### Gunicorn Workers

Adjust workers in Dockerfile.web:

```dockerfile
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "4", "--timeout", "120", "server:app"]
```

Formula: `workers = (2 × CPU_cores) + 1`

### Resource Limits

For Kubernetes:

```yaml
resources:
  requests:
    memory: "256Mi"  # Minimum
    cpu: "250m"
  limits:
    memory: "512Mi"  # Maximum
    cpu: "500m"
```

## Troubleshooting

### Container Won't Start

```bash
# Check logs
docker-compose logs uade-web

# Verify health check
docker exec uade-web-player curl -f http://localhost:5000/health
```

### High Memory Usage

- Reduce Gunicorn workers
- Lower CLEANUP_INTERVAL
- Adjust resource limits

### Slow Conversions

- Increase timeout in Dockerfile
- Check CPU allocation
- Monitor conversion queue

## Backup and Recovery

### Persistent Data

The application stores temporary files in `/tmp`. For production:

1. Use persistent volumes for cache
2. Back up converted files if needed
3. Consider external storage (S3, Azure Blob)

### Example with S3

Modify server.py to upload converted files to S3 for persistence.

## Scaling

### Horizontal Scaling

Works out-of-the-box with:

- Load balancer distributing traffic
- Independent file storage per instance
- Stateless application design

### Auto-scaling (Kubernetes)

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: uade-web-player-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: uade-web-player
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
```

## Support

For deployment issues, check:

- [Main README](README.md)
- [Web Player Documentation](WEB-PLAYER.md)
- [GitHub Issues](https://github.com/rib1/uade-docker/issues)
