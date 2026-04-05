---
name: uade-docker
description: Work on the UADE Docker repository for Amiga module playback and conversion. Use when editing this repo's Docker setup, Flask backend, vanilla JavaScript frontend, tests, CI workflows, deployment configuration, or documentation, especially when repo-specific conventions and architecture matter.
---

# UADE Docker

Read [`.agents/AGENTS.md`](./AGENTS.md) first for the repository's architecture, workflow, testing expectations, and deployment constraints.

Use [`.agents/project-lessons.md`](./project-lessons.md) for project-specific learnings and regression-avoidance notes, especially around queue behavior, backend hardening, accessibility coverage, code quality, and Docker-based testing.

Prefer the repo's Docker-first workflows over local-tool assumptions:

- For repo quality verification, use `$quality-checks` in `.agents/skills/quality-checks` and prefer the Docker Compose quality stack first.
- For repo test execution, use `$project-tests` in `.agents/skills/project-tests` and choose the exact Docker Compose test flow from `docker-compose.yml` comments.
- Run quality checks with `docker compose -f docker-compose.yml -f test/docker-compose.quality.yml run --rm --build quality-check` where appropriate.
- Use Docker Compose for integration and accessibility coverage.
- After a feature or fix is ready, run the relevant automated tests before finishing. At minimum, run the Docker-based quality suite and the most relevant Docker Compose test flow for the changed area.
- Keep changes aligned with the project's minimal-dependency approach.
- When you learn something non-obvious and repo-specific while working, update `.agents/project-lessons.md` so the next pass does not have to rediscover it.
- When you discover instruction drift or a docs regression pattern, update `test/check-instructions.mjs` so the quality pipeline can catch it automatically next time.
- When you notice documentation drift, do not stop at the one-off doc fix. Also consider whether a lightweight check belongs in `test/check-documentation.mjs` or `test/check-instructions.mjs` so the same drift is less likely to recur.

Preserve the pinned base-image strategy described in the repo instructions. Treat `Dockerfile.web` as depending on a stable published UADE base image rather than rebuilding UADE ad hoc.

Before changing deployment, caching, archive handling, queue playback, or accessibility behavior, consult the relevant docs under `docs/` and the lessons reference so existing constraints are not accidentally regressed.
