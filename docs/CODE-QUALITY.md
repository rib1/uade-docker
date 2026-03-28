# Code Quality Automation

This project has a unified code-quality runner for the main repo checks. Use the runner for day-to-day work and use `--help` / `-Help` for the exact per-check switches instead of relying on this document as a flag reference.

## Core Principle

Keep quality checks and their development environment as minimal as possible. The quality workflow is Docker-first so tool versions and execution environment stay consistent across machines and CI, without requiring a heavy local setup. For full-suite runs, the prebuilt Compose quality container is preferred because one environment with all tools installed is usually faster and simpler than spinning up separate tool containers. The local scripts are still useful for quick iteration and targeted checks, even though outside the quality container they may use Docker under the hood for individual tools.

## Recommended Workflow

Use the Docker Compose quality service for the most consistent results:

```bash
docker compose -f docker-compose.yml -f test/docker-compose.quality.yml run --rm --build quality-check
```

Use the local scripts when you want a local entrypoint for quick iteration or targeted checks:

```bash
./test/check-code-quality.sh
./test/check-code-quality.sh --fix
./test/check-code-quality.sh --help
```

```powershell
.\test\check-code-quality.ps1
.\test\check-code-quality.ps1 -Fix
.\test\check-code-quality.ps1 -Help
```

## What Gets Checked

The quality suite covers:

- JavaScript: `ESLint`
- CSS: `Stylelint`
- CSS dead selector audit: `PurgeCSS`
- HTML: `HTMLHint`
- JavaScript dead code: `knip`
- Python formatting: `Black`
- Python linting and formatting: `Ruff`
- Python type checking: `mypy`
- Dockerfiles: `Hadolint`
- Docker Compose files: compose validation
- GitHub Actions workflows: `ActionLint`
- Shell scripts: `ShellCheck`
- YAML files: `Yamllint`
- Repo instruction markdown: instruction-file checks
- Project documentation markdown: documentation-file checks

## Source Of Truth

Versions and behavior are intentionally centralized:

- JavaScript/CSS/HTML tooling versions: [`test/package.json`](../test/package.json)
- Python tooling versions: [`test/requirements-quality.txt`](../test/requirements-quality.txt)
- Pinned Docker-based tooling images: [`test/docker-compose.tooling.yml`](../test/docker-compose.tooling.yml)
- Main Bash runner: [`test/check-code-quality.sh`](../test/check-code-quality.sh)
- Main PowerShell runner: [`test/check-code-quality.ps1`](../test/check-code-quality.ps1)
- Docker Compose quality service: [`test/docker-compose.quality.yml`](../test/docker-compose.quality.yml)

## Config Files

The per-tool rules live in the normal project config files:

- ESLint: [`web/static/eslint.config.js`](../web/static/eslint.config.js)
- Stylelint: [`.stylelintrc.json`](../.stylelintrc.json)
- HTMLHint: [`.htmlhintrc`](../.htmlhintrc)
- PurgeCSS: [`test/purgecss.config.js`](../test/purgecss.config.js)
- knip: [`test/knip.config.js`](../test/knip.config.js)
- Black, Ruff, mypy: [`pyproject.toml`](../pyproject.toml)
- Hadolint: [`.hadolint.yaml`](../.hadolint.yaml)
- Yamllint: [`.yamllint.yml`](../.yamllint.yml)
- GitHub Actions CI entrypoint: [`.github/workflows/code-quality.yml`](../.github/workflows/code-quality.yml)
- Instruction checks: [`test/check-instructions.mjs`](../test/check-instructions.mjs)
- Documentation checks: [`test/check-documentation.mjs`](../test/check-documentation.mjs)

## Running Targeted Checks

For a single check or the current list of switches, ask the scripts directly:

```bash
./test/check-code-quality.sh --help
```

```powershell
.\test\check-code-quality.ps1 -Help
```

If you prefer to stay inside Docker, pass the same help request through the quality container:

```bash
docker compose -f docker-compose.yml -f test/docker-compose.quality.yml run --rm quality-check --help
```

## CI Behavior

Code quality runs automatically in GitHub Actions through [`code-quality.yml`](../.github/workflows/code-quality.yml).

The CI job:

- builds the quality-check environment
- runs the full suite
- fails the workflow if any check fails

Before opening or updating a PR, the usual flow is:

1. Run the full suite locally.
2. Run with `--fix` / `-Fix` when available.
3. Resolve any remaining manual issues.
4. Commit the result.

## Notes

- Docker Compose validation is part of the local script workflow and checks the base file together with relevant override files.
- The quality container avoids most local tool-install differences and Windows volume-mount quirks.
- Instruction-file and documentation-file checks are repo-specific checks, not off-the-shelf linters.

## Troubleshooting

Common issues:

- Docker is not running: start Docker Desktop or your Docker daemon.
- Script permission errors on Unix-like systems: run `chmod +x ./test/check-code-quality.sh`.
- Windows path or mount issues: prefer [check-code-quality.ps1](../test/check-code-quality.ps1) or the Compose workflow.

## Exit Codes

- `0`: all requested checks passed
- `1`: one or more requested checks failed
