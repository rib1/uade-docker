---
name: quality-checks
description: Run or update this repository's quality verification flows. Use when changing code, workflows, documentation checks, or agent guidance and you need to validate the repo. Prefer this skill when deciding which quality-check entrypoint to use, when the user asks to run checks, or when you need the fastest Docker-first verification path with layer-cache reuse.
---

# Quality Checks

Read [`.agents/AGENTS.md`](../../AGENTS.md) first for the repository's architecture, workflow, testing expectations, and deployment constraints.

Use [`.agents/project-lessons.md`](../../project-lessons.md) for project-specific learnings and regression-avoidance notes, especially around quality-flow drift and Docker-first verification behavior.

Prefer the Docker Compose quality stack first:

```powershell
docker compose -f docker-compose.yml -f test/docker-compose.quality.yml run --rm --build quality-check
```

Why:
- It matches the repo's preferred Docker-first verification flow.
- It is usually the fastest full-run path after the quality image layers are cached.
- It exercises the same containerized toolchain used by the quality workflow.

Use the PowerShell runner when you specifically need to verify the Windows wrapper flow too:

```powershell
.\test\check-code-quality.ps1
```

Use the Bash runner when working in a Unix-like shell and you need to verify that wrapper:

```bash
./test/check-code-quality.sh
```

## Workflow

1. If the user asks to run all quality checks, start with the Docker Compose quality stack.
2. If the task changes the PowerShell or Bash wrapper behavior, also run the affected wrapper directly after the Compose run.
3. If the task changes instruction or documentation validation only, it is acceptable to run the narrower wrapper invocation first, for example `.\test\check-code-quality.ps1 -Instructions -Documentation`, but finish with the broader flow when the change touches shared quality infrastructure.
4. Report whether the Compose flow passed, whether wrapper-specific flows passed, and any intentional differences between them.
5. After a feature or fix is ready, run the relevant automated tests before finishing. At minimum, for quality-infrastructure changes, run the Docker Compose quality flow and any affected wrapper flow.
6. When you learn something non-obvious and repo-specific while working, update `.agents/project-lessons.md` so the next pass does not have to rediscover it.
7. When you discover instruction drift or a docs regression pattern, update `test/check-instructions.mjs` so the quality pipeline can catch it automatically next time.

## Narrow Runs

Common targeted PowerShell checks:

```powershell
.\test\check-code-quality.ps1 -PurgeCSS
.\test\check-code-quality.ps1 -Instructions -Documentation
```

Common targeted Bash checks:

```bash
./test/check-code-quality.sh --purgecss
./test/check-code-quality.sh --instructions --documentation
```

For the canonical commands and expected usage, see [references/commands.md](./references/commands.md).
