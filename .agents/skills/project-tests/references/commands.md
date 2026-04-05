# Project Test Commands

Source of truth: the command comments in `docker-compose.yml`.

## Endpoint and app-behavior verification

Integration:

```powershell
$env:GIT_COMMIT = (git rev-parse HEAD); docker compose -f docker-compose.yml -f test/docker-compose.endpoints.yml run --rm --build uade-test-runner
```

Rerun:

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.endpoints.yml run --rm uade-test-runner
```

Rate-limit:

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.ratelimit.yml run --rm --build uade-test-ratelimit-runner
```

Accessibility:

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.accessibility.yml run --rm --build uade-test-accessibility-runner
```

Race condition:

```powershell
docker compose run --rm --build uade-test-race-condition-runner
```

## Multi-instance verification

Bring up:

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.multiinstance.yml up -d --build uade-web-a uade-web-b
```

Run tests:

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.multiinstance.yml run --rm --build uade-test-multiinstance-runner
```

Tear down:

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.multiinstance.yml down -v
```

## DAST

Baseline:

```powershell
docker compose run --rm --build zap-scan
```

Seeded baseline:

```powershell
docker compose run --rm --build zap-scan-seeded
```

Full:

```powershell
docker compose run --rm --build zap-full-scan
```

Seeded full:

```powershell
docker compose run --rm --build zap-full-scan-seeded
```
