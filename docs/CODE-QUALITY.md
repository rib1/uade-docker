# Code Quality Automation

This document explains the code quality checks and how to run them for the UADE Docker project.

## Overview

The UADE Docker project uses three automated code quality tools, all running in Docker containers (no local installation required):

1. **ESLint** - JavaScript/CSS linting and style checking
2. **Black** - Python code formatting and consistency
3. **ActionLint** - GitHub Actions workflow validation

## Tools

### ESLint (JavaScript/CSS)

**Purpose:** Enforce code style, detect errors, ensure consistency in JavaScript/CSS files.

**Version:** ESLint 9 (with flat config support)

**Configuration:** `/web/static/eslint.config.js`

**Files checked:** `/web/static/**/*.js`, `/web/static/**/*.css`

**Dual-Mode Execution:**

- In quality-check container: Uses locally installed ESLint 9
- Local development: Falls back to Docker container

**Direct Docker command:**

```bash
docker run -it --rm -v ${pwd}/web/static:/data cytopia/eslint .
```

**With auto-fix:**

```bash
docker run -it --rm -v ${pwd}/web/static:/data cytopia/eslint . --fix
```

### Black (Python)

**Purpose:** Enforce consistent Python code formatting (PEP 8 compliant).

**Version:** Black 23.3.0

**Configuration:** `pyproject.toml` (line length: 100 characters)

**Files checked:** `/web/**/*.py`

**Dual-Mode Execution:**

- In quality-check container: Uses locally installed Black
- Local development: Falls back to Docker container

**Direct Docker command:**

```bash
docker run --rm -v ${pwd}/web:/data cytopia/black . --line-length 100
```

**With auto-fix:**

```bash
docker run --rm -v ${pwd}/web:/data cytopia/black . --line-length 100
```

(Note: Black auto-formats by default when `--check` is not specified)

### ActionLint (GitHub Actions)

**Purpose:** Validate GitHub Actions workflow YAML syntax and best practices.

**Version:** ActionLint 1.7.4

**Files checked:** `/.github/workflows/**/*.yml`, `/.github/workflows/**/*.yaml`

**Dual-Mode Execution:**

- In quality-check container: Uses locally installed ActionLint
- Local development: Falls back to Docker container

**Direct Docker command:**

```bash
docker run --rm -v ${pwd}:/workspace --workdir /workspace \
  rhysd/actionlint -color /workspace/.github/workflows/build-deploy-web-player.yml
```

## Running Code Quality Checks

### Docker Compose Service (Recommended)

Use the Docker Compose quality-check service for consistent, isolated checks:

```bash
# Run all checks in Docker container
docker-compose -f docker-compose.yml -f test/docker-compose.quality.yml up --build quality-check
```

This approach:

- Runs all tools (ESLint, Black, ActionLint) in an isolated container
- No local installation required
- Consistent results across all environments
- Properly exits with code 1 on failures

### Local Script Execution

You can also run the scripts directly on your machine:

**Bash (Linux/Mac/Git Bash):**

```bash
# Run all checks
./test/check-code-quality.sh

# Run with auto-fixes enabled
./test/check-code-quality.sh --fix

# Run specific checks only
./test/check-code-quality.sh --eslint
./test/check-code-quality.sh --black
./test/check-code-quality.sh --actionlint
```

**PowerShell (Windows):**

```powershell
# Run all checks
.\test\check-code-quality.ps1

# Run with auto-fixes enabled
.\test\check-code-quality.ps1 -Fix

# Run specific checks only
.\test\check-code-quality.ps1 -ESLint
.\test\check-code-quality.ps1 -Black
.\test\check-code-quality.ps1 -ActionLint
```

### Individual Tool Commands

#### ESLint Only

```bash
# Check only
docker run -it --rm -v ${pwd}/web/static:/data cytopia/eslint .

# Fix issues automatically
docker run -it --rm -v ${pwd}/web/static:/data cytopia/eslint . --fix
```

#### Black Only

```bash
# Check formatting (no changes)
docker run --rm -v ${pwd}/web:/data cytopia/black . --line-length 100 --check

# Auto-format code
docker run --rm -v ${pwd}/web:/data cytopia/black . --line-length 100
```

#### ActionLint Only

```bash
# Validate all workflows
for file in .github/workflows/*.yml; do
  docker run --rm -v ${pwd}:/workspace --workdir /workspace \
    rhysd/actionlint -color "/workspace/$file"
done
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
- Target Python version: 3.9+
- Exclude: .git, .hg, .mypy_cache, .tox, .venv, build, dist, __pycache__

### ActionLint Configuration

ActionLint uses default GitHub Actions validation rules. No configuration file needed.

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
- Runs all three checks (ESLint, Black, ActionLint)
- Fails the build if any check reports errors
- Provides helpful error messages with fix instructions

**Status checks:**

The workflow will fail if:

- ESLint finds linting issues (syntax errors, style violations)
- Black detects formatting inconsistencies
- ActionLint identifies workflow validation errors

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
   docker-compose -f docker-compose.yml -f test/docker-compose.quality.yml up --build quality-check
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
docker run --rm -v "${pwd_path}/web/static:/data" cytopia/eslint .
```

### ESLint "No files matching" Error

Ensure `.js` and `.css` files exist in `/web/static/`. ESLint requires at least one JavaScript file to validate.

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
- **Black:** 5-10 seconds (first time: 30-45 seconds with image pull)
- **ActionLint:** 5-10 seconds per workflow (first time: 20-30 seconds)
- **All checks:** 15-30 seconds (first time: 90-120 seconds)

Subsequent runs are much faster due to Docker image caching.

## Implementation Details

### Script Architecture

Both `check-code-quality.sh` (Bash) and `check-code-quality.ps1` (PowerShell) scripts:

1. **Parse arguments** - Determines which checks to run (--fix, --eslint, --black, --actionlint)
2. **Detect environment** - Checks if tools are available locally or need Docker
3. **Run checks** - Executes each tool (local or Docker container)
4. **Capture output** - Stores results directly in variables (no temp files)
5. **Aggregate results** - Generates summary and exit code

### Dual-Mode Execution

The scripts intelligently choose execution mode:

**Quality-Check Container Mode:**

- Tools (ESLint, Black, ActionLint) are pre-installed
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
- Black: Non-zero exit on formatting inconsistencies
- ActionLint: Non-zero exit on workflow validation errors

Script aggregates all results and returns:

- `0` if all checks passed
- `1` if any check failed

## References

- [ESLint Documentation](https://eslint.org/)
- [Black Documentation](https://black.readthedocs.io/)
- [ActionLint Documentation](https://rhysd.github.io/actionlint/)
- [Docker Hub - cytopia/eslint](https://hub.docker.com/r/cytopia/eslint)
- [Docker Hub - cytopia/black](https://hub.docker.com/r/cytopia/black)
- [Docker Hub - rhysd/actionlint](https://hub.docker.com/r/rhysd/actionlint)
