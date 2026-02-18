# UADE Docker - Code Quality Check (Windows PowerShell)
#
# This script runs code quality checks on Windows without needing bash
#
# Usage:
#   .\test\check-code-quality.ps1              # Run all checks
#   .\test\check-code-quality.ps1 -Fix         # Run with fixes enabled
#   .\test\check-code-quality.ps1 -ESLint      # ESLint only
#   .\test\check-code-quality.ps1 -Black       # Black only
#   .\test\check-code-quality.ps1 -Ruff        # Ruff only
#   .\test\check-code-quality.ps1 -ActionLint  # ActionLint only
#   .\test\check-code-quality.ps1 -Hadolint    # Hadolint only
#   .\test\check-code-quality.ps1 -Compose     # Docker Compose only
#
# Requirements:
#   - Docker Desktop installed and running

param(
    [switch]$Fix,
    [switch]$ESLint,
    [switch]$Black,
    [switch]$Ruff,
    [switch]$ActionLint,
    [switch]$Hadolint,
    [switch]$Compose
)

# Color codes
$Green = @{ ForegroundColor = "Green" }
$Red = @{ ForegroundColor = "Red" }
$Yellow = @{ ForegroundColor = "Yellow" }
$Cyan = @{ ForegroundColor = "Cyan" }

# Get project root
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
if (-not $ScriptDir) {
    $ScriptDir = Get-Location
}
$ProjectRoot = Split-Path -Parent $ScriptDir

# Counters
$TotalChecks = 0
$PassedChecks = 0
$FailedChecks = 0

# Default to run all if no specific tool selected
if (-not $ESLint -and -not $Black -and -not $Ruff -and -not $ActionLint -and -not $Hadolint -and -not $Compose) {
    $ESLint = $true
    $Black = $true
    $Ruff = $true
    $ActionLint = $true
    $Hadolint = $true
    $Compose = $true
}

# Helper function to print headers
function Write-Header {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 70) @Cyan
    Write-Host $Title @Cyan
    Write-Host ("=" * 70) @Cyan
    Write-Host ""
}

# Helper function to print results
function Write-Result {
    param(
        [string]$TestName,
        [int]$ExitCode,
        [string]$Output
    )

    $script:TotalChecks++

    if ($ExitCode -eq 0) {
        Write-Host "PASSED: $TestName" @Green
        $script:PassedChecks++
    } else {
        Write-Host "FAILED: $TestName" @Red
        if ($Output) {
            Write-Host $Output @Red
        }
        $script:FailedChecks++
    }
}

# Check if Docker is available
try {
    $dockerVersion = docker --version 2>&1
    Write-Host "Found Docker: $dockerVersion" @Green
} catch {
    Write-Host "ERROR: Docker is not installed or not in PATH" @Red
    Write-Host "Please install Docker Desktop from: https://www.docker.com/products/docker-desktop" @Yellow
    exit 1
}

# ESLint Check
if ($ESLint) {
    Write-Header "ESLint - JavaScript/CSS Linting"

    Write-Host "Running ESLint on /web/static..."

    $FixArg = if ($Fix) { "--fix" } else { "" }

    $output = & docker run --rm `
        -v "${ProjectRoot}/web/static:/data" `
        cytopia/eslint . $FixArg 2>&1

    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        Write-Result "ESLint" 0
    } else {
        Write-Result "ESLint" 1 $output
    }
}

# Black Check
if ($Black) {
    Write-Header "Black - Python Code Formatting"

    Write-Host "Running Black on /web..."

    $CheckArg = if ($Fix) { "" } else { "--check" }

    $output = & docker run --rm `
        -v "${ProjectRoot}/web:/data" `
        cytopia/black . --line-length 100 $CheckArg 2>&1

    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        Write-Result "Black" 0
    } else {
        Write-Result "Black" 1 $output
    }
}

# Ruff Check
if ($Ruff) {
    Write-Header "Ruff - Python Linting and Formatting"

    Write-Host "Running Ruff on /web..."

    $FixArg = if ($Fix) { "--fix" } else { "" }

    $output = & docker run --rm `
        -v "${ProjectRoot}:/workspace" `
        --workdir /workspace/web `
        ghcr.io/astral-sh/ruff:latest check . $FixArg 2>&1

    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        Write-Result "Ruff" 0
    } else {
        Write-Result "Ruff" 1 $output
    }
}

# Hadolint Check
if ($Hadolint) {
    Write-Header "Hadolint - Dockerfile Linting"

    $Dockerfiles = Get-ChildItem -Path $ProjectRoot -Recurse -Include "Dockerfile","Dockerfile.*" -File | Where-Object { $_.FullName -notmatch "node_modules|.git" }

    if ($null -eq $Dockerfiles -or $Dockerfiles.Count -eq 0) {
        Write-Host "No Dockerfiles found" @Yellow
    } else {
        Write-Host "Found $($Dockerfiles.Count) Dockerfile(s). Validating..."

        $HadolintFailed = $false

        foreach ($Dockerfile in $Dockerfiles) {
            $DockerfileName = $Dockerfile.Name
            Write-Host "  Checking: $DockerfileName"

            $output = Get-Content $Dockerfile.FullName -Raw | docker run --rm -i `
                -v "${ProjectRoot}/.hadolint.yaml:/.hadolint.yaml:ro" `
                hadolint/hadolint:v2.12.0 hadolint --config /.hadolint.yaml - 2>&1
            $exitCode = $LASTEXITCODE

            if ($exitCode -eq 0) {
                Write-Host "    OK: $DockerfileName" @Green
            } else {
                Write-Host "    FAIL: $DockerfileName" @Red
                $HadolintFailed = $true
            }
        }

        if ($HadolintFailed) {
            Write-Result "Hadolint" 1 $output
        } else {
            Write-Result "Hadolint" 0
        }
    }
}

# Docker Compose Check
if ($Compose) {
    Write-Header "Docker Compose - Configuration Validation"

    # Find main compose file
    $MainCompose = Join-Path $ProjectRoot "docker-compose.yml"
    if (-not (Test-Path $MainCompose)) {
        $MainCompose = Join-Path $ProjectRoot "compose.yml"
    }

    if (-not (Test-Path $MainCompose)) {
        Write-Host "No base docker-compose.yml found" @Yellow
    } else {
        # Find all compose files (main + test overrides)
        $ComposeFiles = @($MainCompose)
        $TestComposes = Get-ChildItem -Path (Join-Path $ProjectRoot "test") -Filter "docker-compose.*.yml" -File -ErrorAction SilentlyContinue
        if ($TestComposes) {
            $ComposeFiles += $TestComposes.FullName
        }

        Write-Host "Found $($ComposeFiles.Count) compose file(s). Validating..."

        $ComposeFailed = $false

        foreach ($ComposeFile in $ComposeFiles) {
            $ComposeFileName = Split-Path $ComposeFile -Leaf
            Write-Host "  Checking: $ComposeFileName"

            # Main compose file validates alone, overrides validate with base
            if ($ComposeFile -eq $MainCompose) {
                $output = docker compose -f $ComposeFile config --quiet 2>&1
            } else {
                $output = docker compose -f $MainCompose -f $ComposeFile config --quiet 2>&1
            }
            $exitCode = $LASTEXITCODE

            if ($exitCode -eq 0) {
                Write-Host "    OK: $ComposeFileName" @Green
            } else {
                Write-Host "    FAIL: $ComposeFileName" @Red
                $ComposeFailed = $true
            }
        }

        if ($ComposeFailed) {
            Write-Result "Docker Compose" 1 $output
        } else {
            Write-Result "Docker Compose" 0
        }
    }
}

# ActionLint Check
if ($ActionLint) {
    Write-Header "ActionLint - GitHub Workflows Validation"

    $WorkflowDir = Join-Path $ProjectRoot ".github/workflows"

    if (Test-Path $WorkflowDir) {
        $Workflows = Get-ChildItem -Path $WorkflowDir -Filter "*.yml" -File
        $Workflows += Get-ChildItem -Path $WorkflowDir -Filter "*.yaml" -File

        if ($null -eq $Workflows -or $Workflows.Count -eq 0) {
            Write-Host "No workflow files found" @Yellow
        } else {
            Write-Host "Found $($Workflows.Count) workflow(s). Validating..."

            $ActionLintFailed = $false

            foreach ($Workflow in $Workflows) {
                $WorkflowName = $Workflow.Name
                Write-Host "  Checking: $WorkflowName"

                $output = & docker run --rm `
                    -v "${ProjectRoot}:/workspace" `
                    --workdir /workspace `
                    rhysd/actionlint -color ".github/workflows/$WorkflowName" 2>&1

                $exitCode = $LASTEXITCODE

                if ($exitCode -eq 0) {
                    Write-Host "    OK: $WorkflowName" @Green
                } else {
                    Write-Host "    FAIL: $WorkflowName" @Red
                    $ActionLintFailed = $true
                }
            }

            if ($ActionLintFailed) {
                Write-Result "ActionLint" 1 $output
            } else {
                Write-Result "ActionLint" 0
            }
        }
    } else {
        Write-Host "Workflow directory not found at: $WorkflowDir" @Yellow
    }
}

# Summary
Write-Header "Code Quality Check Summary"

Write-Host "Total Checks: $TotalChecks"
Write-Host "Passed: $PassedChecks" @Green
Write-Host "Failed: $FailedChecks" @Red

if ($Fix) {
    Write-Host ""
    Write-Host "Note: Running with -Fix flag. Applicable issues have been auto-corrected." @Yellow
}

Write-Host ""

# Exit with appropriate code
if ($FailedChecks -eq 0) {
    Write-Host "All code quality checks passed!" @Green
    Write-Host ""
    exit 0
} else {
    Write-Host "Some code quality checks failed. Please review and fix." @Red
    Write-Host ""
    exit 1
}
