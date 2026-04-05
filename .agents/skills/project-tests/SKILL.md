---
name: project-tests
description: Choose and run this repository's Docker Compose test flows. Use when code changes need endpoint, rate-limit, accessibility, race-condition, multi-instance, or DAST verification, or when the user asks which test stack to run. Follow the exact command comments in docker-compose.yml as the source of truth.
---

# Project Tests

Read [`.agents/AGENTS.md`](../../AGENTS.md) first for the repository's architecture, workflow, testing expectations, and deployment constraints.

Use [`.agents/project-lessons.md`](../../project-lessons.md) for project-specific learnings and regression-avoidance notes, especially around test-flow selection, Compose behavior, and regression coverage expectations.

Use the command comments in `docker-compose.yml` as the source of truth for test entrypoints.

## Common Flows

Integration tests:

```powershell
$env:GIT_COMMIT = (git rev-parse HEAD); docker compose -f docker-compose.yml -f test/docker-compose.endpoints.yml run --rm --build uade-test-runner
```

Re-run integration tests without rebuilding:

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.endpoints.yml run --rm uade-test-runner
```

Rate-limit tests:

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.ratelimit.yml run --rm --build uade-test-ratelimit-runner
```

Accessibility tests:

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.accessibility.yml run --rm --build uade-test-accessibility-runner
```

Race-condition test:

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

Baseline DAST:

```powershell
docker compose run --rm --build zap-scan
```

Seeded baseline DAST:

```powershell
docker compose run --rm --build zap-scan-seeded
```

Full DAST:

```powershell
docker compose run --rm --build zap-full-scan
```

Seeded full DAST:

```powershell
docker compose run --rm --build zap-full-scan-seeded
```

## Workflow

1. Pick the narrowest test stack that matches the changed behavior.
2. Prefer the exact Docker Compose command from `docker-compose.yml` comments instead of reconstructing it from memory.
3. If the change affects shared cache or filesystem behavior across containers, include the multi-instance flow.
4. If the change affects security scan behavior or ZAP seeding, run the matching DAST flow.
5. Report exactly which Compose command was run and whether follow-up teardown is still needed.
6. After a feature or fix is ready, run the relevant automated tests before finishing, using the narrowest Compose stack that still validates the changed behavior.
7. When you learn something non-obvious and repo-specific while working, update `.agents/project-lessons.md` so the next pass does not have to rediscover it.
8. When you discover instruction drift or a docs regression pattern, update `test/check-instructions.mjs` so the quality pipeline can catch it automatically next time.

For the canonical commands and brief selection guidance, see [references/commands.md](./references/commands.md).
