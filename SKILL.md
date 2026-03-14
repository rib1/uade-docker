---
name: uade-docker
description: Work on the UADE Docker repository for Amiga module playback and conversion. Use when editing this repo's Docker setup, Flask backend, vanilla JavaScript frontend, tests, CI workflows, deployment configuration, or documentation, especially when repo-specific conventions and architecture matter.
---

# UADE Docker

Read [`.github/copilot-instructions.md`](.github/copilot-instructions.md) first for the repository's architecture, workflow, testing expectations, and deployment constraints.

Use [references/project-lessons.md](references/project-lessons.md) for project-specific learnings and regression-avoidance notes, especially around queue behavior, backend hardening, accessibility coverage, code quality, and Docker-based testing.

Prefer the repo's Docker-first workflows over local-tool assumptions:

- Run quality checks with `.\test\check-code-quality.ps1` on Windows or `./test/check-code-quality.sh` where appropriate.
- Use Docker Compose for integration and accessibility coverage.
- Keep changes aligned with the project's minimal-dependency approach.
- When you learn something non-obvious and repo-specific while working, update `references/project-lessons.md` so the next pass does not have to rediscover it.
- When you discover instruction drift or a docs regression pattern, update `test/check-instructions.mjs` so the quality pipeline can catch it automatically next time.

Preserve the pinned base-image strategy described in the repo instructions. Treat `Dockerfile.web` as depending on a stable published UADE base image rather than rebuilding UADE ad hoc.

Before changing deployment, caching, archive handling, queue playback, or accessibility behavior, consult the relevant docs under `docs/` and the lessons reference so existing constraints are not accidentally regressed.
