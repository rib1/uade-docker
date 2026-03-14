# Code Quality Automation

This document explains the code quality checks and how to run them for the UADE Docker project.

## Overview

The UADE Docker project uses twelve automated code quality tools:

1. **ESLint** - JavaScript linting and style checking
2. **Stylelint** - CSS linting and style checking
3. **HTMLHint** - HTML validation and quality checks
4. **Black** - Python code formatting and consistency
5. **Ruff** - Fast Python linting and formatting
6. **mypy** - Lightweight Python type checking
7. **Hadolint** - Dockerfile linting and best practices
8. **Docker Compose** - Compose file validation
9. **ActionLint** - GitHub Actions workflow validation
10. **ShellCheck** - Shell script linting and bug detection
11. **Yamllint** - YAML syntax and style validation
12. **Instruction Files** - Repo guidance validation for instruction markdown and skill files

## How to Run Checks

- JavaScript/CSS/HTML tool versions are pinned in `test/package.json`.
- Python quality tool versions are pinned in `test/requirements-quality.txt`.
- Hadolint and Actionlint Docker image tags are pinned in `test/docker-compose.tooling.yml`.
- Dependabot monitors both manifests and opens update PRs.
- Dependabot also monitors Docker tags in `/test` (including `test/docker-compose.tooling.yml`).

### Docker Compose Service (Recommended)

Use the Docker Compose quality-check service for consistent, isolated checks:

```bash
# Run the default quality suite in Docker
docker compose -f docker-compose.yml -f test/docker-compose.quality.yml run --rm --build quality-check
```

This approach:

- Runs ESLint, Stylelint, HTMLHint, Black, Ruff, mypy, Hadolint, ActionLint, ShellCheck, Yamllint, and instruction-file checks in an isolated container
- No local installation required
- Consistent results across all environments
- Properly exits with code 1 on failures

### Instruction Files

**Purpose:** Catch broken relative links and known stale guidance patterns in repo instruction files such as `.github/copilot-instructions.md`, `SKILL.md`, and `references/project-lessons.md`.

**Implementation:** `test/check-instructions.mjs`

**Recommended commands:**

```bash
./test/check-code-quality.sh --instructions
```

```powershell
.\test\check-code-quality.ps1 -Instructions
```

## Tools

### ESLint (JavaScript)

**Purpose:** Enforce code style, detect errors, ensure consistency in JavaScript files.

**Version source:** `test/package.json` (`eslint`, flat config support)

**Configuration:** `/web/static/eslint.config.js`

**Files checked:** `/web/static/**/*.js`

**Dual-Mode Execution:**

- In quality-check container: Uses locally installed ESLint (version from `test/package.json`)
- Local development: Falls back to Docker container

**Direct Docker command:**

```bash
docker run --rm -v ${pwd}:/workspace --workdir /workspace/web/static \
  node:24-alpine sh -lc "npm install -g \"eslint@$(node -p 'require(\"/workspace/test/package.json\").devDependencies.eslint')\" >/dev/null && eslint ."
```

**With auto-fix:**

```bash
docker run --rm -v ${pwd}:/workspace --workdir /workspace/web/static \
  node:24-alpine sh -lc "npm install -g \"eslint@$(node -p 'require(\"/workspace/test/package.json\").devDependencies.eslint')\" >/dev/null && eslint . --fix"
```

### Stylelint (CSS)

**Purpose:** Enforce CSS quality and detect invalid/duplicate declarations.

**Version source:** `test/package.json` (`stylelint`)

**Configuration:** `.stylelintrc.json`

**Files checked:** `/web/static/**/*.css`

**Direct Docker command:**

```bash
docker run --rm -v ${pwd}:/workspace --workdir /workspace node:24-alpine sh -lc "npm install -g \"stylelint@$(node -p 'require(\"/workspace/test/package.json\").devDependencies.stylelint')\" >/dev/null && stylelint --config .stylelintrc.json web/static/*.css"
```

### HTMLHint (HTML)

**Purpose:** Validate HTML structure and common correctness rules.

**Version source:** `test/package.json` (`htmlhint`)

**Configuration:** `.htmlhintrc`

**Files checked:** `/web/static/index.html`

**Direct Docker command:**

```bash
docker run --rm -v ${pwd}:/workspace --workdir /workspace node:24-alpine sh -lc "npm install -g \"htmlhint@$(node -p 'require(\"/workspace/test/package.json\").devDependencies.htmlhint')\" >/dev/null && htmlhint --config .htmlhintrc web/static/index.html"
```

### Black (Python)

**Purpose:** Enforce consistent Python code formatting (PEP 8 compliant).

**Version source:** `test/requirements-quality.txt` (`black`)

**Configuration:** `pyproject.toml` (line length: 100 characters)

**Files checked:** `/web/**/*.py`

**Dual-Mode Execution:**

- In quality-check container: Uses locally installed Black
- Local development: Falls back to Docker container

**Recommended command:**

```bash
./test/check-code-quality.sh --black
```

### Ruff (Python)

**Purpose:** Fast Python linting and formatting, covering style, correctness, security, typing, import hygiene, and selected API design rules.

**Version source:** `test/requirements-quality.txt` (`ruff`)

**Configuration:** `pyproject.toml` (`[tool.ruff.lint]` rule selection and ignores)

**Files checked:** `/web/**/*.py`

**Dual-Mode Execution:**

- In quality-check container: Uses locally installed Ruff binary
- Local development: Falls back to Docker container

**What the scripts run:**

- `ruff format --check .`
- `ruff check .`

With `--fix` / `-Fix`, the scripts run:

- `ruff format .`
- `ruff check . --fix`

**Recommended command:**

```bash
./test/check-code-quality.sh --ruff
```

**With auto-fix:**

```bash
./test/check-code-quality.sh --ruff --fix
```

### mypy (Python Type Checking)

**Purpose:** Add a lightweight static type check pass for core Python server code.

**Version source:** `test/requirements-quality.txt` (`mypy`)

**Configuration:** `pyproject.toml` (`[tool.mypy]`)

**Files checked:** `web/server.py`

**Recommended command:**

```bash
./test/check-code-quality.sh --mypy
```

### Hadolint (Dockerfiles)

**Purpose:** Lint Dockerfiles for best practices and common errors.

**Version:** 2.14.0

**Configuration:** `.hadolint.yaml` (ignores warnings, only fails on errors)

**Files checked:** All `Dockerfile*` files in the repository

**Execution:** Requires Docker (runs hadolint/hadolint:v2.14.0 image)

**Direct Docker command:**

```bash
Get-Content Dockerfile | docker run --rm -i -v "${pwd}/.hadolint.yaml:/.hadolint.yaml:ro" hadolint/hadolint:v2.14.0 hadolint --config /.hadolint.yaml -
```

### Docker Compose (Validation)

**Purpose:** Validate Docker Compose file syntax and configuration.

**Files checked:**

- `docker-compose.yml` (base file)
- `docker-compose.dev.yml` (development override)
- `test/docker-compose.endpoints.yml` (override)
- `test/docker-compose.quality.yml` (override)
- `test/docker-compose.ratelimit.yml` (override)

**Execution:** Uses `docker compose config --quiet` for validation. Override files are validated together with the base file.

**Direct command:**

```bash
# Validate base file
docker compose -f docker-compose.yml config --quiet

# Validate development override with base
docker compose -f docker-compose.yml -f docker-compose.dev.yml config --quiet

# Validate test override with base
docker compose -f docker-compose.yml -f test/docker-compose.quality.yml config --quiet
```

**Note:** Override files in `test/` are validated together with the base file.

### ActionLint (GitHub Workflows)

**Purpose:** Validate GitHub Actions workflow syntax and best practices.

**Version:** 1.7.11

**Files checked:** `.github/workflows/**/*.yml`

**Dual-Mode Execution:**

- In quality-check container: Uses locally installed ActionLint binary
- Local development: Falls back to Docker container

**Direct Docker command:**

```bash
docker run --rm -v ${pwd}/.github/workflows:/workflows rhysd/actionlint:1.7.11 -color /workflows/*.yml
```

## Running Code Quality Checks

### Docker Compose Service (Recommended)

Use the Docker Compose quality-check service for consistent, isolated checks:

```bash
# Run the default quality suite in Docker
docker compose -f docker-compose.yml -f test/docker-compose.quality.yml run --rm --build quality-check
```

This approach:

- Runs ESLint, Stylelint, HTMLHint, Black, Ruff, mypy, Hadolint, ActionLint, ShellCheck, and Yamllint in an isolated container
- No local installation required
- Consistent results across all environments
- Properly exits with code 1 on failures

**Note:** Docker Compose file validation requires the Docker Compose plugin and is only available via local script execution.

### Local Script Execution (All Checks Including Compose Validation)

Run the scripts directly on your machine to execute all eleven checks:

**Bash (Linux/Mac/Git Bash):**

```bash
# Run all checks
./test/check-code-quality.sh

# Run with auto-fixes enabled
./test/check-code-quality.sh --fix

# Run specific checks only
./test/check-code-quality.sh --eslint
./test/check-code-quality.sh --stylelint
./test/check-code-quality.sh --htmlhint
./test/check-code-quality.sh --black
./test/check-code-quality.sh --ruff
./test/check-code-quality.sh --hadolint
./test/check-code-quality.sh --compose
./test/check-code-quality.sh --actionlint
./test/check-code-quality.sh --shellcheck
./test/check-code-quality.sh --yamllint
./test/check-code-quality.sh --mypy
```

**PowerShell (Windows):**

```powershell
# Run all checks
.\test\check-code-quality.ps1

# Run with auto-fixes enabled
.\test\check-code-quality.ps1 -Fix

# Run specific checks only
.\test\check-code-quality.ps1 -ESLint
.\test\check-code-quality.ps1 -Stylelint
.\test\check-code-quality.ps1 -HTMLHint
.\test\check-code-quality.ps1 -Black
.\test\check-code-quality.ps1 -Ruff
.\test\check-code-quality.ps1 -Hadolint
.\test\check-code-quality.ps1 -Compose
.\test\check-code-quality.ps1 -ActionLint
.\test\check-code-quality.ps1 -ShellCheck
.\test\check-code-quality.ps1 -Yamllint
.\test\check-code-quality.ps1 -MyPy
```

### Individual Tool Commands

```bash
# Bash
./test/check-code-quality.sh --eslint
./test/check-code-quality.sh --stylelint
./test/check-code-quality.sh --htmlhint
./test/check-code-quality.sh --black
./test/check-code-quality.sh --ruff
./test/check-code-quality.sh --mypy
./test/check-code-quality.sh --hadolint
./test/check-code-quality.sh --compose
./test/check-code-quality.sh --actionlint
./test/check-code-quality.sh --shellcheck
./test/check-code-quality.sh --yamllint
```

```powershell
# PowerShell
.\test\check-code-quality.ps1 -ESLint
.\test\check-code-quality.ps1 -Stylelint
.\test\check-code-quality.ps1 -HTMLHint
.\test\check-code-quality.ps1 -Black
.\test\check-code-quality.ps1 -Ruff
.\test\check-code-quality.ps1 -MyPy
.\test\check-code-quality.ps1 -Hadolint
.\test\check-code-quality.ps1 -Compose
.\test\check-code-quality.ps1 -ActionLint
.\test\check-code-quality.ps1 -ShellCheck
.\test\check-code-quality.ps1 -Yamllint
```

## Configuration Files

### ESLint Configuration

**File:** `/web/static/eslint.config.js`

ESLint is configured for ES2021 syntax with the following rules:

- Semi-colons required
- Double quotes required
- No unused variables allowed
- No console statements in production code

### Black Configuration

**File:** `pyproject.toml`

Black is configured with:

- Line length: 100 characters
- Target Python version: 3.13+
- Exclude: .git, .hg, .mypy_cache, .tox, .venv, build, dist, `__pycache__`

### Ruff Configuration

**File:** `pyproject.toml`

Ruff is configured with:

- Line length: 100 characters
- Rule selection and ignores are defined in `[tool.ruff.lint]`
- `pyproject.toml` is the source of truth for enabled Ruff rule families
- Repo-specific ignores:
  - `S101` allows `assert` in tests
  - `S104` allows binding all interfaces for the local dev server

### ActionLint Configuration

ActionLint uses default GitHub Actions validation rules. No configuration file needed.

### Yamllint Configuration

**File:** `.yamllint.yml`

Yamllint is configured for pragmatic validation focused on syntax/structure checks while allowing
existing repository formatting style.

## GitHub Actions Integration

The code quality checks run automatically as part of CI/CD via the [code-quality.yml](.github/workflows/code-quality.yml) workflow.

**Workflow triggers:**

- Push to main branch (when code or workflow files change)
- Pull requests to main branch
- Manual trigger via workflow_dispatch

**Monitored files:**

- Python files: `web/**/*.py`
- JavaScript files: `web/**/*.js`
- CSS files: `web/**/*.css`
- GitHub workflows: `.github/workflows/*.yml`
- Quality check infrastructure files

**Workflow behavior:**

- Builds the quality-check Docker container
- Runs ESLint, Stylelint, HTMLHint, Black, Ruff, mypy, Hadolint, ActionLint, ShellCheck, and Yamllint
- Fails the build if any check reports errors
- Provides helpful error messages with fix instructions

**Status checks:**

The workflow will fail if:

- ESLint finds linting issues (syntax errors, style violations)
- Stylelint finds CSS linting issues
- HTMLHint finds HTML validation issues
- Black detects formatting inconsistencies
- Ruff identifies linting or formatting issues
- mypy identifies Python type issues in the configured scope
- Hadolint identifies Dockerfile best-practice violations
- ActionLint identifies workflow validation errors
- ShellCheck identifies shell script issues
- Yamllint identifies YAML syntax/configuration issues

**How to fix failures:**

When the workflow fails, run locally to auto-fix:

```bash
./test/check-code-quality.sh --fix
```

Or on Windows PowerShell:

```powershell
.\test\check-code-quality.ps1 -Fix
```

Then commit and push the fixes.

## Developer Workflow

### Before Committing

1. Run code quality checks (Docker Compose - recommended):

   ```bash
   docker compose -f docker-compose.yml -f test/docker-compose.quality.yml up --build quality-check
   ```

   Or using local scripts:

   **Bash:**

   ```bash
   ./test/check-code-quality.sh
   ```

   **PowerShell:**

   ```powershell
   .\test\check-code-quality.ps1
   ```

2. Auto-fix issues:

   **Bash:**

   ```bash
   ./test/check-code-quality.sh --fix
   ```

   **PowerShell:**

   ```powershell
   .\test\check-code-quality.ps1 -Fix
   ```

3. Review remaining issues and commit:

   ```bash
   git add .
   git commit -m "Your commit message"
   ```

### For Pull Requests

- Code quality checks will run automatically via GitHub Actions
- PR will be blocked if checks fail
- Use `./test/check-code-quality.sh --fix` (Bash) or `.\test\check-code-quality.ps1 -Fix` (PowerShell) locally to resolve issues before pushing

## Troubleshooting

### Docker Not Running

```
Error: Docker daemon is not running
```

**Solution:** Start Docker Desktop or Docker daemon before running checks.

### Volume Mount Issues (Windows)

**Recommended:** Use the PowerShell script:

```powershell
.\test\check-code-quality.ps1
```

Or use Git Bash:

```bash
./test/check-code-quality.sh
```

For direct Docker commands in PowerShell:

```powershell
$pwd_path = (Get-Location).Path
docker run --rm -v "${pwd_path}:/workspace" --workdir /workspace/web/static node:24-alpine sh -lc "npm install -g \"eslint@$(node -p 'require(\"/workspace/test/package.json\").devDependencies.eslint')\" >/dev/null && eslint ."
```

### ESLint "No files matching" Error

Ensure `.js` files exist in `/web/static/`. ESLint validates JavaScript files only.

### Script Permission Denied

On Linux/Mac, make sure the script is executable:

```bash
chmod +x ./test/check-code-quality.sh
```

## Exit Codes

- `0` - All checks passed ✓
- `1` - One or more checks failed ✗

## Performance

Typical run times (first run includes Docker image pull):

- **ESLint:** 5-10 seconds (first time: 30-45 seconds with image pull)
- **Stylelint:** 3-8 seconds (first time: 20-40 seconds with image pull)
- **HTMLHint:** 2-5 seconds (first time: 15-30 seconds with image pull)
- **Black:** 5-10 seconds (first time: 30-45 seconds with image pull)
- **Ruff:** 1-2 seconds (first time: 10-15 seconds with image pull)
- **mypy:** 3-8 seconds (first time: 20-40 seconds with image pull)
- **ActionLint:** 5-10 seconds per workflow (first time: 20-30 seconds)
- **ShellCheck:** 1-3 seconds
- **Yamllint:** 1-3 seconds
- **All checks:** 20-40 seconds (first time: 90-150 seconds)

Subsequent runs are much faster due to Docker image caching.

## Implementation Details

### Script Architecture

Both `check-code-quality.sh` (Bash) and `check-code-quality.ps1` (PowerShell) scripts:

1. **Parse arguments** - Determines which checks to run (--fix, --eslint, --stylelint, --htmlhint, --black, --ruff, --mypy, --hadolint, --compose, --actionlint, --shellcheck, --yamllint)
2. **Detect environment** - Checks if tools are available locally or need Docker
3. **Run checks** - Executes each tool (local or Docker container)
4. **Capture output** - Stores results directly in variables (no temp files)
5. **Aggregate results** - Generates summary and exit code

### Dual-Mode Execution

The scripts intelligently choose execution mode:

**Quality-Check Container Mode:**

- Tools (ESLint, Stylelint, HTMLHint, Black, Ruff, mypy, Hadolint, ActionLint, ShellCheck, Yamllint) are pre-installed
- Runs directly without nested Docker
- Faster execution, simpler volume mounting

**Local Development Mode:**

- Falls back to Docker containers for each tool
- No local installation required
- Consistent with legacy behavior

### Docker Compose Service

The `quality-check` service provides:

- Isolated environment with all tools pre-installed
- Mounts only necessary files (read-only)
- Proper exit codes for CI/CD integration
- No Docker-in-Docker volume mounting issues

### Exit Code Behavior

Tools are run with proper error handling:

- ESLint: Non-zero exit on linting errors
- Stylelint: Non-zero exit on CSS linting errors
- HTMLHint: Non-zero exit on HTML validation errors
- Black: Non-zero exit on formatting inconsistencies
- Ruff: Non-zero exit on linting or formatting issues
- mypy: Non-zero exit on detected type issues in configured scope
- Hadolint: Non-zero exit on Dockerfile linting errors
- ActionLint: Non-zero exit on workflow validation errors
- ShellCheck: Non-zero exit on shell script linting errors
- Yamllint: Non-zero exit on YAML validation errors

Script aggregates all results and returns:

- `0` if all checks passed
- `1` if any check failed

## References

- [ESLint Documentation](https://eslint.org/)
- [Stylelint Documentation](https://stylelint.io/)
- [HTMLHint Documentation](https://htmlhint.com/)
- [Black Documentation](https://black.readthedocs.io/)
- [Ruff Documentation](https://ruff.rs/)
- [mypy Documentation](https://mypy.readthedocs.io/)
- [ActionLint Documentation](https://rhysd.github.io/actionlint/)
- [ShellCheck Documentation](https://www.shellcheck.net/)
- [Yamllint Documentation](https://yamllint.readthedocs.io/)
- [Docker Hub - node](https://hub.docker.com/_/node)
- [Docker Hub - pyfound/black](https://hub.docker.com/r/pyfound/black)
- [Ruff Container Image](https://github.com/astral-sh/ruff/pkgs/container/ruff)
- [Docker Hub - rhysd/actionlint](https://hub.docker.com/r/rhysd/actionlint)
