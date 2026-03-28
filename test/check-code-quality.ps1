# UADE Docker - Code Quality Check (Windows PowerShell)
#
# This script runs code quality checks on Windows without needing bash,
# including linting, dead-code auditing, formatting, and workflow/config validation.
#
# Usage:
#   .\test\check-code-quality.ps1              # Run all checks
#   .\test\check-code-quality.ps1 -Fix         # Run with fixes enabled
#   .\test\check-code-quality.ps1 -Help        # Show usage and available checks
#   .\test\check-code-quality.ps1 -ESLint      # ESLint only
#   .\test\check-code-quality.ps1 -Black       # Black only
#   .\test\check-code-quality.ps1 -Ruff        # Ruff only
#   .\test\check-code-quality.ps1 -ActionLint  # ActionLint only
#   .\test\check-code-quality.ps1 -Hadolint    # Hadolint only
#   .\test\check-code-quality.ps1 -Compose     # Docker Compose only
#   .\test\check-code-quality.ps1 -ShellCheck  # ShellCheck only
#   .\test\check-code-quality.ps1 -Yamllint    # Yamllint only
#   .\test\check-code-quality.ps1 -Stylelint   # Stylelint only
#   .\test\check-code-quality.ps1 -HTMLHint    # HTMLHint only
#   .\test\check-code-quality.ps1 -Knip        # knip dead-code audit only
#   .\test\check-code-quality.ps1 -MyPy        # mypy only
#   .\test\check-code-quality.ps1 -PurgeCSS    # PurgeCSS unused CSS check only
#   .\test\check-code-quality.ps1 -Instructions # Instruction files only
#   .\test\check-code-quality.ps1 -Documentation # Documentation files only
#
# Requirements:
#   - Docker Desktop installed and running

param(
    [switch]$Help,
    [switch]$Fix,
    [switch]$ESLint,
    [switch]$Black,
    [switch]$Ruff,
    [switch]$ActionLint,
    [switch]$Hadolint,
    [switch]$Compose,
    [switch]$ShellCheck,
    [switch]$Yamllint,
    [switch]$Stylelint,
    [switch]$HTMLHint,
    [switch]$Knip,
    [switch]$MyPy,
    [switch]$Instructions,
    [switch]$Documentation,
    [switch]$PurgeCSS
)

function Show-Usage {
    Write-Host "Usage: .\test\check-code-quality.ps1 [-Fix] [-Help] [single-check switch]"
    Write-Host ""
    Write-Host "Run all checks:"
    Write-Host "  .\test\check-code-quality.ps1"
    Write-Host ""
    Write-Host "Run with auto-fixes:"
    Write-Host "  .\test\check-code-quality.ps1 -Fix"
    Write-Host ""
    Write-Host "Show help:"
    Write-Host "  .\test\check-code-quality.ps1 -Help"
    Write-Host ""
    Write-Host "Frontend Checks:"
    Write-Host "CSS Checks:"
    Write-Host "  -PurgeCSS"
    Write-Host "  -Stylelint"
    Write-Host ""
    Write-Host "JavaScript Checks:"
    Write-Host "  -ESLint"
    Write-Host "  -Knip"
    Write-Host ""
    Write-Host "HTML Checks:"
    Write-Host "  -HTMLHint"
    Write-Host ""
    Write-Host "Backend Python Checks:"
    Write-Host "  -Black"
    Write-Host "  -Ruff"
    Write-Host "  -MyPy"
    Write-Host ""
    Write-Host "Infrastructure Checks:"
    Write-Host "  -Hadolint"
    Write-Host "  -Compose"
    Write-Host "  -ActionLint"
    Write-Host "  -ShellCheck"
    Write-Host "  -Yamllint"
    Write-Host ""
    Write-Host "Markdown And Documentation Checks:"
    Write-Host "  -Instructions"
    Write-Host "  -Documentation"
}

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

# Tool versions from manifests (managed by Dependabot)
$NpmQualityManifest = Join-Path $ProjectRoot "test/package.json"
$PyQualityManifest = Join-Path $ProjectRoot "test/requirements-quality.txt"
$ToolingImageManifest = Join-Path $ProjectRoot "test/docker-compose.tooling.yml"

if (-not (Test-Path $NpmQualityManifest)) {
    Write-Host "ERROR: Missing quality manifest: $NpmQualityManifest" @Red
    exit 1
}
if (-not (Test-Path $PyQualityManifest)) {
    Write-Host "ERROR: Missing quality manifest: $PyQualityManifest" @Red
    exit 1
}
if (-not (Test-Path $ToolingImageManifest)) {
    Write-Host "ERROR: Missing tooling image manifest: $ToolingImageManifest" @Red
    exit 1
}

$NpmQuality = Get-Content -Path $NpmQualityManifest -Raw | ConvertFrom-Json
$ESLINT_VERSION = $NpmQuality.devDependencies.eslint
$STYLELINT_VERSION = $NpmQuality.devDependencies.stylelint
$HTMLHINT_VERSION = $NpmQuality.devDependencies.htmlhint
$KNIP_VERSION = $NpmQuality.devDependencies.knip
$PURGECSS_VERSION = $NpmQuality.devDependencies.purgecss
$PyPins = @{}
Get-Content -Path $PyQualityManifest | ForEach-Object {
    if ($_ -match '^([A-Za-z0-9._-]+)==(.+)$') {
        $PyPins[$matches[1]] = $matches[2]
    }
}

$BLACK_VERSION = $PyPins["black"]
$RUFF_VERSION = $PyPins["ruff"]
$MYPY_VERSION = $PyPins["mypy"]
$YAMLLINT_VERSION = $PyPins["yamllint"]
$PythonQualityTargets = @("web", "test/report_endpoint_coverage.py", "test/zap_seed_targets.py")

$ToolingCompose = Get-Content -Path $ToolingImageManifest -Raw
$HadolintImageMatch = [regex]::Match($ToolingCompose, "(?ms)^  hadolint:\s*$.*?^    image:\s*([^\r\n]+)")
$ActionlintImageMatch = [regex]::Match($ToolingCompose, "(?ms)^  actionlint:\s*$.*?^    image:\s*([^\r\n]+)")
$ShellcheckImageMatch = [regex]::Match($ToolingCompose, "(?ms)^  shellcheck:\s*$.*?^    image:\s*([^\r\n]+)")
$HADOLINT_IMAGE = $HadolintImageMatch.Groups[1].Value.Trim().Trim('"')
$ACTIONLINT_IMAGE = $ActionlintImageMatch.Groups[1].Value.Trim().Trim('"')
$SHELLCHECK_IMAGE = $ShellcheckImageMatch.Groups[1].Value.Trim().Trim('"')

foreach ($Required in @(
    @{ Name = "eslint"; Value = $ESLINT_VERSION },
    @{ Name = "stylelint"; Value = $STYLELINT_VERSION },
    @{ Name = "htmlhint"; Value = $HTMLHINT_VERSION },
    @{ Name = "knip"; Value = $KNIP_VERSION },
    @{ Name = "purgecss"; Value = $PURGECSS_VERSION },
    @{ Name = "black"; Value = $BLACK_VERSION },
    @{ Name = "ruff"; Value = $RUFF_VERSION },
    @{ Name = "mypy"; Value = $MYPY_VERSION },
    @{ Name = "yamllint"; Value = $YAMLLINT_VERSION },
    @{ Name = "hadolint image"; Value = $HADOLINT_IMAGE },
    @{ Name = "actionlint image"; Value = $ACTIONLINT_IMAGE },
    @{ Name = "shellcheck image"; Value = $SHELLCHECK_IMAGE }
)) {
    if (-not $Required.Value) {
        Write-Host "ERROR: Missing $($Required.Name) pin in quality manifests" @Red
        exit 1
    }
}

# Counters
$TotalChecks = 0
$PassedChecks = 0
$FailedChecks = 0

if ($Help) {
    Show-Usage
    exit 0
}

# Default to run all if no specific tool selected
if (-not $ESLint -and -not $Black -and -not $Ruff -and -not $ActionLint -and -not $Hadolint -and -not $Compose -and -not $ShellCheck -and -not $Yamllint -and -not $Stylelint -and -not $HTMLHint -and -not $Knip -and -not $MyPy -and -not $Instructions -and -not $Documentation -and -not $PurgeCSS) {
    $ESLint = $true
    $Stylelint = $true
    $HTMLHint = $true
    $Knip = $true
    $Black = $true
    $Ruff = $true
    $ActionLint = $true
    $Hadolint = $true
    $Compose = $true
    $ShellCheck = $true
    $Yamllint = $true
    $MyPy = $true
    $Instructions = $true
    $Documentation = $true
    $PurgeCSS = $true
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

function Write-GroupHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host "--- $Title ---" @Yellow
    Write-Host ""
}

function Write-SubgroupHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host "${Title}:" @Yellow
    Write-Host ""
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

# PurgeCSS Check
if ($PurgeCSS) {
    Write-GroupHeader "Frontend Checks"
    Write-SubgroupHeader "CSS Checks"
    Write-Header "PurgeCSS - Unused CSS Removal Check"

    Write-Host "Running PurgeCSS on web/static/style.css against all HTML and JS in web/..."

    $purgeCssArgs = @("check-purgecss.mjs")
    if ($Fix) {
        $purgeCssArgs += "--fix"
    }

    $hasNode = $null -ne (Get-Command node -ErrorAction SilentlyContinue)
    $hasPurgeCSS = $null -ne (Get-Command purgecss -ErrorAction SilentlyContinue)

    if ($hasNode -and $hasPurgeCSS) {
        Push-Location (Join-Path $ProjectRoot "test")
        try {
            $output = & node @purgeCssArgs 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
    } else {
        $purgeCssCommand = "npm install -g purgecss@$PURGECSS_VERSION >/dev/null && node " + ($purgeCssArgs -join " ")
        $output = & docker run --rm `
            -v "${ProjectRoot}:/workspace" `
            --workdir /workspace/test `
            node:24-alpine sh -lc $purgeCssCommand 2>&1
        $exitCode = $LASTEXITCODE
    }

    if ($exitCode -eq 0) {
        Write-Result "PurgeCSS" 0
    } else {
        Write-Result "PurgeCSS" 1 $output
    }
}

# Stylelint Check
if ($Stylelint) {
    Write-Header "Stylelint - CSS Linting"

    Write-Host "Running Stylelint on /web/static/*.css..."

    $stylelintArgs = @("--config", ".stylelintrc.json", "web/static/*.css")
    if ($Fix) {
        $stylelintArgs = @("--config", ".stylelintrc.json", "--fix", "web/static/*.css")
    }

    $output = & docker run --rm `
        -v "${ProjectRoot}:/workspace" `
        --workdir /workspace `
        node:24-alpine sh -lc "npm install -g stylelint@$STYLELINT_VERSION >/dev/null && stylelint $($stylelintArgs -join ' ')" 2>&1

    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        Write-Result "Stylelint" 0
    } else {
        Write-Result "Stylelint" 1 $output
    }
}

# ESLint Check
if ($ESLint) {
    if (-not $PurgeCSS -and -not $Stylelint) {
        Write-GroupHeader "Frontend Checks"
    }
    Write-SubgroupHeader "JavaScript Checks"
    Write-Header "ESLint - JavaScript/CSS Linting"

    Write-Host "Running ESLint on /web/static and /test/*.{js,mjs}..."

    $eslintArgs = @(".")
    if ($Fix) {
        $eslintArgs += "--fix"
    }

    $webOutput = & docker run --rm `
        -v "${ProjectRoot}:/workspace" `
        --workdir /workspace/web/static `
        node:24-alpine sh -lc "npm install -g eslint@$ESLINT_VERSION >/dev/null && eslint $($eslintArgs -join ' ')" 2>&1
    $webExitCode = $LASTEXITCODE

    $testOutput = & docker run --rm `
        -v "${ProjectRoot}:/workspace" `
        --workdir /workspace/test `
        node:24-alpine sh -lc "npm install -g eslint@$ESLINT_VERSION >/dev/null && eslint $($eslintArgs -join ' ')" 2>&1
    $testExitCode = $LASTEXITCODE

    $output = @()
    if ($webExitCode -ne 0) {
        $output += $webOutput
    }
    if ($testExitCode -ne 0) {
        $output += $testOutput
    }

    $exitCode = [Math]::Max($webExitCode, $testExitCode)

    if ($exitCode -eq 0) {
        Write-Result "ESLint" 0
    } else {
        Write-Result "ESLint" 1 ($output -join "`n")
    }
}

# knip Check
if ($Knip) {
    if (-not $PurgeCSS -and -not $Stylelint -and -not $ESLint) {
        Write-GroupHeader "Frontend Checks"
        Write-SubgroupHeader "JavaScript Checks"
    }
    Write-Header "knip - JavaScript Dead-Code Audit"

    Write-Host "Running knip on /web/static and /test with repo-specific config..."

    $output = & docker run --rm `
        -v "${ProjectRoot}:/workspace" `
        --workdir /workspace/test `
        node:24-alpine sh -lc "npm install -g knip@$KNIP_VERSION >/dev/null && knip --config knip.config.js --no-progress --treat-config-hints-as-errors" 2>&1

    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        Write-Result "knip" 0
    } else {
        Write-Result "knip" 1 $output
    }
}

# HTMLHint Check
if ($HTMLHint) {
    if (-not $PurgeCSS -and -not $Stylelint -and -not $ESLint -and -not $Knip) {
        Write-GroupHeader "Frontend Checks"
    }
    Write-SubgroupHeader "HTML Checks"
    Write-Header "HTMLHint - HTML Validation"

    Write-Host "Running HTMLHint on /web/static/index.html..."

    $output = & docker run --rm `
        -v "${ProjectRoot}:/workspace" `
        --workdir /workspace `
        node:24-alpine sh -lc "npm install -g htmlhint@$HTMLHINT_VERSION >/dev/null && htmlhint --config .htmlhintrc web/static/index.html" 2>&1

    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        Write-Result "HTMLHint" 0
    } else {
        Write-Result "HTMLHint" 1 $output
    }
}

# Black Check
if ($Black) {
    Write-GroupHeader "Backend Python Checks"
    Write-Header "Black - Python Code Formatting"

    Write-Host "Running Black on /web, /test/report_endpoint_coverage.py, and /test/zap_seed_targets.py..."

    $blackArgs = @($PythonQualityTargets + @("--line-length", "100"))
    if (-not $Fix) {
        $blackArgs += "--check"
    }

    $output = & docker run --rm `
        -v "${ProjectRoot}:/workspace" `
        --workdir /workspace `
        pyfound/black:$BLACK_VERSION black @blackArgs 2>&1

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

    Write-Host "Running Ruff on /web, /test/report_endpoint_coverage.py, and /test/zap_seed_targets.py..."

    $ruffCheckArgs = @("check") + $PythonQualityTargets
    $ruffFormatArgs = @("format") + $PythonQualityTargets + @("--check")
    if ($Fix) {
        $ruffCheckArgs += "--fix"
        $ruffFormatArgs = @("format") + $PythonQualityTargets
    }

    # Run format check
    $outputFormat = & docker run --rm `
        -v "${ProjectRoot}:/workspace" `
        --workdir /workspace `
        ghcr.io/astral-sh/ruff:$RUFF_VERSION @ruffFormatArgs 2>&1
    $exitCodeFormat = $LASTEXITCODE

    # Run linter check
    $outputCheck = & docker run --rm `
        -v "${ProjectRoot}:/workspace" `
        --workdir /workspace `
        ghcr.io/astral-sh/ruff:$RUFF_VERSION @ruffCheckArgs 2>&1
    $exitCodeCheck = $LASTEXITCODE


    if ($exitCodeFormat -eq 0 -and $exitCodeCheck -eq 0) {
        Write-Result "Ruff" 0
    } else {
        $combinedOutput = "$outputFormat`n$outputCheck"
        $finalExitCode = [Math]::Max($exitCodeFormat, $exitCodeCheck)
        Write-Result "Ruff" $finalExitCode $combinedOutput
    }
}

# mypy Check
if ($MyPy) {
    Write-Header "mypy - Lightweight Python Type Checking"

    Write-Host "Running mypy on web/server.py..."

    $output = & docker run --rm `
        -v "${ProjectRoot}:/workspace" `
        --workdir /workspace `
        python:3.13-slim sh -lc "pip install --no-cache-dir -r test/requirements-quality.txt >/dev/null && mypy --config-file pyproject.toml --no-error-summary" 2>&1

    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        Write-Result "mypy" 0
    } else {
        Write-Result "mypy" 1 $output
    }
}

# Hadolint Check
if ($Hadolint) {
    Write-GroupHeader "Infrastructure Checks"
    Write-Header "Hadolint - Dockerfile Linting"

    $Dockerfiles = Get-ChildItem -Path $ProjectRoot -Recurse -Include "Dockerfile","Dockerfile.*" -File | Where-Object { $_.FullName -notmatch "node_modules|.git" }

    if ($null -eq $Dockerfiles -or $Dockerfiles.Count -eq 0) {
        Write-Host "No Dockerfiles found" @Yellow
    } else {
        Write-Host "Found $($Dockerfiles.Count) Dockerfile(s). Validating..."

        $HadolintFailed = $false
        $HadolintOutput = ""

        foreach ($Dockerfile in $Dockerfiles) {
            $DockerfileName = $Dockerfile.Name
            Write-Host "  Checking: $DockerfileName"

            $output = Get-Content $Dockerfile.FullName -Raw | docker run --rm -i `
                -v "${ProjectRoot}/.hadolint.yaml:/.hadolint.yaml:ro" `
                $HADOLINT_IMAGE hadolint --config /.hadolint.yaml - 2>&1
            $exitCode = $LASTEXITCODE

            if ($exitCode -eq 0) {
                Write-Host "    OK: $DockerfileName" @Green
            } else {
                Write-Host "    FAIL: $DockerfileName" @Red
                $HadolintFailed = $true
                $HadolintOutput += "`n$output"
            }
        }

        if ($HadolintFailed) {
            Write-Result "Hadolint" 1 $HadolintOutput
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
        Write-Result "Docker Compose" 0
    } else {
        # Find all compose files (main + root dev override + test overrides)
        $ComposeFiles = @($MainCompose)
        $DevCompose = Join-Path $ProjectRoot "docker-compose.dev.yml"
        if (Test-Path $DevCompose) {
            $ComposeFiles += $DevCompose
        }
        $TestComposes = Get-ChildItem -Path (Join-Path $ProjectRoot "test") -Filter "docker-compose.*.yml" -File -ErrorAction SilentlyContinue
        if ($TestComposes) {
            $ComposeFiles += $TestComposes.FullName
        }

        Write-Host "Found $($ComposeFiles.Count) compose file(s). Validating..."

        $ComposeFailed = $false
        $ComposeOutput = ""

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
                if ($output) {
                    Write-Host $output @Red
                    $ComposeOutput += "`n$output"
                }
                $ComposeFailed = $true
            }
        }

        if ($ComposeFailed) {
            Write-Result "Docker Compose" 1 $ComposeOutput
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
            $ActionLintOutput = ""

            foreach ($Workflow in $Workflows) {
                $WorkflowName = $Workflow.Name
                Write-Host "  Checking: $WorkflowName"

                $output = & docker run --rm `
                    -v "${ProjectRoot}:/workspace" `
                    --workdir /workspace `
                    $ACTIONLINT_IMAGE -color ".github/workflows/$WorkflowName" 2>&1

                $exitCode = $LASTEXITCODE

                if ($exitCode -eq 0) {
                    Write-Host "    OK: $WorkflowName" @Green
                } else {
                    Write-Host "    FAIL: $WorkflowName" @Red
                    $ActionLintFailed = $true
                    $ActionLintOutput += "`n$output"
                }
            }

            if ($ActionLintFailed) {
                Write-Result "ActionLint" 1 $ActionLintOutput
            } else {
                Write-Result "ActionLint" 0
            }
        }
    } else {
        Write-Host "Workflow directory not found at: $WorkflowDir" @Yellow
    }
}

# ShellCheck Check
if ($ShellCheck) {
    Write-Header "ShellCheck - Shell Script Linting"

    $ShellFiles = Get-ChildItem -Path (Join-Path $ProjectRoot "test") -Filter "*.sh" -File -ErrorAction SilentlyContinue

    if ($null -eq $ShellFiles -or $ShellFiles.Count -eq 0) {
        Write-Host "No shell scripts found" @Yellow
    } else {
        Write-Host "Found $($ShellFiles.Count) shell script(s). Validating..."

        $ShellcheckFailed = $false
        $ShellcheckOutput = ""
        foreach ($ShellFile in $ShellFiles) {
            Write-Host "  Checking: $($ShellFile.Name)"
            $relativePath = "test/$($ShellFile.Name)"
            $output = & docker run --rm `
                -v "${ProjectRoot}:/workspace" `
                --workdir /workspace `
                $SHELLCHECK_IMAGE -x --severity=style "$relativePath" 2>&1
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                $ShellcheckFailed = $true
                $ShellcheckOutput += "`n$output"
            }
        }

        if ($ShellcheckFailed) {
            Write-Result "ShellCheck" 1 $ShellcheckOutput
        } else {
            Write-Result "ShellCheck" 0
        }
    }
}

# Yamllint Check
if ($Yamllint) {
    Write-Header "Yamllint - YAML Validation"

    $YamlFiles = @()
    $YamlFiles += Get-ChildItem -Path (Join-Path $ProjectRoot ".github") -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @(".yml", ".yaml") }
    $YamlFiles += Get-ChildItem -Path (Join-Path $ProjectRoot "test") -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @(".yml", ".yaml") }
    $YamlFiles += Get-ChildItem -Path $ProjectRoot -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @(".yml", ".yaml") }
    $YamlFiles = $YamlFiles | Sort-Object FullName -Unique

    if ($null -eq $YamlFiles -or $YamlFiles.Count -eq 0) {
        Write-Host "No YAML files found" @Yellow
    } else {
        Write-Host "Found $($YamlFiles.Count) YAML file(s). Validating..."

        $YamllintConfig = Join-Path $ProjectRoot ".yamllint.yml"
        $yamllintArgs = @()
        if (Test-Path $YamllintConfig) {
            $yamllintArgs += "-c"
            $yamllintArgs += "/workspace/.yamllint.yml"
        }

        foreach ($YamlFile in $YamlFiles) {
            $relativePath = $YamlFile.FullName.Replace($ProjectRoot, "").TrimStart('\').Replace('\', '/')
            $yamllintArgs += $relativePath
        }

        $output = & docker run --rm `
            -v "${ProjectRoot}:/workspace" `
            --workdir /workspace `
            python:3.13-slim sh -lc "pip install --no-cache-dir yamllint==$YAMLLINT_VERSION >/dev/null && yamllint $($yamllintArgs -join ' ')" 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-Result "Yamllint" 0
        } else {
            Write-Result "Yamllint" 1 $output
        }
    }
}

# Instruction Files Check
if ($Instructions) {
    Write-GroupHeader "Markdown And Documentation Checks"
    Write-Header "Instruction Files - Repo Guidance Validation"

    Write-Host "Running repo-specific checks on instruction files..."

    try {
        node --version 2>$null | Out-Null
        $output = & node (Join-Path $ProjectRoot "test/check-instructions.mjs") 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        $output = & docker run --rm `
            -v "${ProjectRoot}:/workspace" `
            --workdir /workspace `
            node:25-alpine node test/check-instructions.mjs 2>&1
        $exitCode = $LASTEXITCODE
    }

    if ($exitCode -eq 0) {
        Write-Result "Instruction Files" 0
    } else {
        Write-Result "Instruction Files" 1 $output
    }
}

# Documentation Files Check
if ($Documentation) {
    Write-Header "Documentation Files - Markdown Integrity Validation"

    Write-Host "Running repo-specific checks on README.md and docs/*.md..."

    try {
        node --version 2>$null | Out-Null
        $output = & node (Join-Path $ProjectRoot "test/check-documentation.mjs") 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        $output = & docker run --rm `
            -v "${ProjectRoot}:/workspace" `
            --workdir /workspace `
            node:25-alpine node test/check-documentation.mjs 2>&1
        $exitCode = $LASTEXITCODE
    }

    if ($exitCode -eq 0) {
        Write-Result "Documentation Files" 0
    } else {
        Write-Result "Documentation Files" 1 $output
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
