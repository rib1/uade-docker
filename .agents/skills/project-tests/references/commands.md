# Project Test Commands

Source of truth: the command comments in `docker-compose.yml`.

## Endpoint and app-behavior verification

Integration:

Use for normal API/UI regressions: upload, probe, convert, play, download, queue behavior, and endpoint contracts.

```powershell
$env:GIT_COMMIT = (git rev-parse HEAD); docker compose -f docker-compose.yml -f test/docker-compose.endpoints.yml run --rm --build uade-test-runner
```

Rerun:

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.endpoints.yml run --rm uade-test-runner
```

Endpoint teardown:

Use after endpoint runs if the supporting app and test-server containers should be cleaned up.

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.endpoints.yml down -v
```

Prod mode:

Use to verify `/test` routes stay unavailable and production-mode wiring stays correct.

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.prodmode.yml up --force-recreate --build --abort-on-container-exit --exit-code-from uade-test-prod-mode-runner uade-web uade-test-prod-mode-runner
```

Rate-limit:

Use for limiter configuration, upload/probe thresholds, and `RATE_LIMIT_DISABLED` behavior.

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.ratelimit.yml run --rm --build uade-test-ratelimit-runner
```

Accessibility:

Use for interactive UI, semantics, labels, focus handling, and responsive behavior covered by Pa11y.

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.accessibility.yml run --rm --build uade-test-accessibility-runner
```

Race condition:

Use for lock handling, duplicate conversions, cache coordination, and concurrent filesystem behavior.

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

## Benchmark

Use for throughput/latency, cache efficiency, streaming, or concurrency-performance verification.

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.benchmark.yml run --rm --build uade-benchmark-runner
```

## DAST

Baseline:

Use for a baseline unauthenticated scan with `UADE_TEST_MODE` off.

```powershell
docker compose run --rm --build zap-scan
```

Seeded baseline:

Use when the scan needs local-only seed requests with `UADE_TEST_MODE` on.

```powershell
docker compose run --rm --build zap-scan-seeded
```

Full:

Use for a deeper scan than baseline.

```powershell
docker compose run --rm --build zap-full-scan
```

Seeded full:

Use for the deepest seeded scan.

```powershell
docker compose run --rm --build zap-full-scan-seeded
```

## Related Skill

Use the separate `quality-checks` skill for linting, formatting, type checking, documentation/instruction validation, and local CodeQL.
