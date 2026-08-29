---
name: project-tests
description: Choose and run this repository's Docker Compose test flows. Use when code changes need endpoint, prod-mode, rate-limit, accessibility, race-condition, multi-instance, benchmark, or DAST verification, or when the user asks which test stack to run. Use this skill for runtime and integration verification; use the separate quality-checks skill for linting, formatting, type checking, and local CodeQL. Follow the exact command comments in docker-compose.yml as the source of truth.
---

# Project Tests

Read [`.agents/AGENTS.md`](../../AGENTS.md) first for the repository's architecture, workflow, testing expectations, and deployment constraints.

Use [`.agents/project-lessons.md`](../../project-lessons.md) for project-specific learnings and regression-avoidance notes, especially around test-flow selection, Compose behavior, and regression coverage expectations.

Use the command comments in `docker-compose.yml` as the source of truth for test entrypoints.

Use the separate `quality-checks` skill when the user asks for linting, formatting, type checking, instruction/doc validation, or local CodeQL instead of runtime app verification.

## Common Flows

Integration tests:

Use when the change affects normal API/UI behavior, endpoint contracts, upload/download flows, queue/probe/convert/play behavior, or general regressions.

```powershell
$env:GIT_COMMIT = (git rev-parse HEAD); docker compose -f docker-compose.yml -f test/docker-compose.endpoints.yml run --rm --build uade-test-runner
```

Re-run integration tests without rebuilding:

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.endpoints.yml run --rm uade-test-runner
```

Endpoint stack teardown:

Use after endpoint runs if you do not need the app and local test server to keep running.

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.endpoints.yml down -v
```

Prod-mode test:

Use when the change affects `/test` route exposure, production-only wiring, or behavior that should differ between test mode and prod mode.

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.prodmode.yml up --force-recreate --build --abort-on-container-exit --exit-code-from uade-test-prod-mode-runner uade-web uade-test-prod-mode-runner
```

Rate-limit tests:

Use when the change affects Flask-Limiter behavior, rate-limit headers/responses, upload/probe throughput rules, or `RATE_LIMIT_DISABLED` handling.

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.ratelimit.yml run --rm --build uade-test-ratelimit-runner
```

Accessibility tests:

Use when the change affects interactive UI, semantics, keyboard flow, labels, focus behavior, or responsive layout that Pa11y covers.

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.accessibility.yml run --rm --build uade-test-accessibility-runner
```

Race-condition test:

Use when the change affects locking, cache coordination, duplicate conversion handling, or concurrent filesystem behavior.

```powershell
docker compose run --rm --build uade-test-race-condition-runner
```

Multi-instance UI setup:

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.multiinstance.yml up -d --build uade-web-a uade-web-b
```

Multi-instance tests:

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.multiinstance.yml run --rm --build uade-test-multiinstance-runner
```

Multi-instance teardown:

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.multiinstance.yml down -v
```

Benchmark suite:

Use when the change affects performance, concurrency, cache efficiency, range streaming, or you need throughput/latency reports rather than pass/fail functional coverage.

```powershell
$env:GIT_COMMIT = (git rev-parse HEAD); docker compose -f docker-compose.yml -f test/docker-compose.benchmark.yml run --rm --build uade-benchmark-runner
```

Baseline DAST:

Use when the change affects security posture and you need an unauthenticated scan with `UADE_TEST_MODE` off.

```powershell
docker compose run --rm --build zap-scan
```

Seeded baseline DAST:

Use when the scan needs local-only seeded requests and `UADE_TEST_MODE` on.

```powershell
docker compose run --rm --build zap-scan-seeded
```

Full DAST:

Use for deeper security scanning when a baseline scan is not enough.

```powershell
docker compose run --rm --build zap-full-scan
```

Seeded full DAST:

Use for the deepest scan with local-only seeding enabled.

```powershell
docker compose run --rm --build zap-full-scan-seeded
```

## Workflow

1. Pick the narrowest test stack that matches the changed behavior.
2. Prefer the exact Docker Compose command from `docker-compose.yml` comments instead of reconstructing it from memory.
3. Use the separate `quality-checks` skill when the request is about static validation rather than runtime behavior.
4. When changes affect shared cache or filesystem behavior across containers, include the multi-instance flow.
5. For security scan behavior or ZAP seeding changes, run the matching DAST flow.
6. When affecting `/test` exposure or prod/test mode separation, include the prod-mode flow.
7. If the change affects performance or concurrency characteristics rather than correctness alone, consider the benchmark flow.
8. Report exactly which Compose command was run and whether follow-up teardown is still needed.
9. After a feature or fix is ready, run the relevant automated tests before finishing, using the narrowest Compose stack that still validates the changed behavior.
10. When you learn something non-obvious and repo-specific while working, update `.agents/project-lessons.md` so the next pass does not have to rediscover it.
11. When you discover instruction drift or a docs regression pattern, update `test/check-instructions.mjs` so the quality pipeline can catch it automatically next time.

For the canonical commands and brief selection guidance, see [references/commands.md](./references/commands.md).
