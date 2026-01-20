# UADE Docker - Code Quality Check (Windows PowerShell)
#
# This script runs code quality checks on Windows without needing bash
#
# Usage:
#   .\test\check-code-quality.ps1              # Run all checks
#   .\test\check-code-quality.ps1 -Fix         # Run with fixes enabled
#   .\test\check-code-quality.ps1 -ESLint      # ESLint only
#   .\test\check-code-quality.ps1 -Black       # Black only
#   .\test\check-code-quality.ps1 -ActionLint  # ActionLint only
#
# Requirements:
#   - Docker Desktop installed and running

param(
    [switch]$Fix,
    [switch]$ESLint,
    [switch]$Black,
    [switch]$ActionLint
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
if (-not $ESLint -and -not $Black -and -not $ActionLint) {
    $ESLint = $true
    $Black = $true
    $ActionLint = $true
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
