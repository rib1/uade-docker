#requires -Version 7.0

# Cloud Run-shaped semaphore sweep for mixed playback + conversion load.
#
# Usage:
#   .\test\run-cloudrun-semaphore-sweep.ps1
#   .\test\run-cloudrun-semaphore-sweep.ps1 -SemaphoreLimits 1,2,3 -Duration 5m

param(
    [int[]]$SemaphoreLimits = @(1, 2, 3),
    [string]$Duration = "8m",
    [int]$PlayFullVus = 4,
    [int]$PlayRangeVus = 2,
    [int]$ConvertProbedVus = 1,
    [int]$ConvertUrlVus = 1,
    [string]$PlayExampleId = "wings-of-death-levels",
    [string]$OutputDir = "reports/benchmarks/semaphore-sweep"
)

$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
$ProjectRoot = Split-Path -Parent $ScriptDir
$ComposeArgs = @("-f", "docker-compose.yml", "-f", "test/docker-compose.benchmark.yml")
$RunnerService = "uade-benchmark-runner"
$Results = @()
$CreatedGitCommit = $false
$OriginalMaxConcurrentConversions = $env:MAX_CONCURRENT_CONVERSIONS

function Get-K6MetricValue {
    param(
        [hashtable]$Metrics,
        [string]$MetricName,
        [string]$FieldName
    )

    if (-not $Metrics.ContainsKey($MetricName)) {
        return $null
    }

    $metric = $Metrics[$MetricName]
    if ($metric -is [hashtable] -and $metric.ContainsKey($FieldName)) {
        return [double]$metric[$FieldName]
    }

    return $null
}

function Get-LogDurationStats {
    param(
        [string[]]$LogLines,
        [string]$Operation
    )

    $pattern = [regex]::new("$([regex]::Escape($Operation)) took (?<duration>[0-9.]+)ms")
    $durations = @()
    foreach ($line in $LogLines) {
        $match = $pattern.Match($line)
        if ($match.Success) {
            $durations += [double]$match.Groups["duration"].Value
        }
    }

    if ($durations.Count -eq 0) {
        return @{
            count = 0
            avg_ms = $null
            p95_ms = $null
            max_ms = $null
        }
    }

    $sorted = $durations | Sort-Object
    $index = [Math]::Ceiling($sorted.Count * 0.95) - 1
    if ($index -lt 0) {
        $index = 0
    }

    return @{
        count = $sorted.Count
        avg_ms = [Math]::Round((($sorted | Measure-Object -Average).Average), 2)
        p95_ms = [Math]::Round($sorted[$index], 2)
        max_ms = [Math]::Round($sorted[-1], 2)
    }
}

function New-RunSummary {
    param(
        [int]$SemaphoreLimit,
        [string]$K6SummaryPath,
        [string[]]$LogLines
    )

    $k6 = Get-Content $K6SummaryPath -Raw | ConvertFrom-Json -AsHashtable
    $metrics = $k6["metrics"]

    return @{
        semaphore_limit = $SemaphoreLimit
        scenario = @{
            duration = $Duration
            play_full_vus = $PlayFullVus
            play_range_vus = $PlayRangeVus
            convert_probed_vus = $ConvertProbedVus
            convert_url_vus = $ConvertUrlVus
            total_vus = $PlayFullVus + $PlayRangeVus + $ConvertProbedVus + $ConvertUrlVus
            play_example_id = $PlayExampleId
        }
        play = @{
            full_p95_ms = Get-K6MetricValue -Metrics $metrics -MetricName "play_full_duration" -FieldName "p(95)"
            full_max_ms = Get-K6MetricValue -Metrics $metrics -MetricName "play_full_duration" -FieldName "max"
            range_p95_ms = Get-K6MetricValue -Metrics $metrics -MetricName "play_range_duration" -FieldName "p(95)"
            range_max_ms = Get-K6MetricValue -Metrics $metrics -MetricName "play_range_duration" -FieldName "max"
        }
        conversion = @{
            probed_p95_ms = Get-K6MetricValue -Metrics $metrics -MetricName "cold_convert_probed_duration" -FieldName "p(95)"
            url_p95_ms = Get-K6MetricValue -Metrics $metrics -MetricName "cold_convert_url_duration" -FieldName "p(95)"
            probed_req_rate = Get-K6MetricValue -Metrics $metrics -MetricName "cold_convert_probed_requests" -FieldName "rate"
            url_req_rate = Get-K6MetricValue -Metrics $metrics -MetricName "cold_convert_url_requests" -FieldName "rate"
        }
        waits = @{
            semaphore = Get-LogDurationStats -LogLines $LogLines -Operation "Conversion semaphore wait"
            lock = Get-LogDurationStats -LogLines $LogLines -Operation "Conversion lock wait"
        }
    }
}

function Write-MarkdownSummary {
    param(
        [object[]]$RunResults,
        [string]$DestinationPath
    )

    $lines = @(
        "# Cloud Run Semaphore Sweep",
        "",
        "| Limit | Play full p95 (ms) | Play range p95 (ms) | Cold probed p95 (ms) | Cold convert-url p95 (ms) | Semaphore wait p95 (ms) | Lock wait p95 (ms) |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"
    )

    foreach ($result in $RunResults) {
        $lines += "| $($result.semaphore_limit) | $($result.play.full_p95_ms) | $($result.play.range_p95_ms) | $($result.conversion.probed_p95_ms) | $($result.conversion.url_p95_ms) | $($result.waits.semaphore.p95_ms) | $($result.waits.lock.p95_ms) |"
    }

    Set-Content -Path $DestinationPath -Value ($lines -join "`n")
}

function Invoke-Compose {
    param(
        [string[]]$Arguments
    )

    & docker compose @ComposeArgs @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker compose failed: $($Arguments -join ' ')"
    }
}

Push-Location $ProjectRoot
try {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

    foreach ($limit in $SemaphoreLimits) {
        $runDir = Join-Path $OutputDir "limit-$limit"
        $k6SummaryRelative = "$runDir/k6-summary.json".Replace("\", "/")
        $runSummaryPath = Join-Path $runDir "summary.json"
        New-Item -ItemType Directory -Force -Path $runDir | Out-Null

        Write-Host ""
        Write-Host "=== Cloud Run semaphore sweep: MAX_CONCURRENT_CONVERSIONS=$limit ==="

        $env:MAX_CONCURRENT_CONVERSIONS = "$limit"
        if (-not $env:GIT_COMMIT) {
            $env:GIT_COMMIT = (git rev-parse HEAD).Trim()
            $CreatedGitCommit = $true
        }

        Invoke-Compose -Arguments @("up", "-d", "--build", "uade-web", "test-http-server")

        $runLogSince = (Get-Date).ToUniversalTime().ToString("o")
        Invoke-Compose -Arguments @(
            "run",
            "--rm",
            "--build",
            "-e", "BENCH_SUITE=cloudrun-semaphore",
            "-e", "REPORT_FILE=/$k6SummaryRelative",
            "-e", "BENCH_SCENARIO_DURATION=$Duration",
            "-e", "PLAY_FULL_VUS=$PlayFullVus",
            "-e", "PLAY_RANGE_VUS=$PlayRangeVus",
            "-e", "CONVERT_PROBED_VUS=$ConvertProbedVus",
            "-e", "CONVERT_URL_VUS=$ConvertUrlVus",
            "-e", "PLAY_EXAMPLE_ID=$PlayExampleId",
            $RunnerService
        )

        $logLines = & docker compose @ComposeArgs logs --no-color --since $runLogSince uade-web 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "docker compose logs failed for uade-web"
        }

        $summary = New-RunSummary -SemaphoreLimit $limit -K6SummaryPath $k6SummaryRelative -LogLines $logLines
        $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $runSummaryPath
        $Results += $summary
    }

    $combinedJson = Join-Path $OutputDir "summary.json"
    $combinedMd = Join-Path $OutputDir "summary.md"
    ConvertTo-Json -InputObject @($Results) -Depth 8 -AsArray | Set-Content -Path $combinedJson
    Write-MarkdownSummary -RunResults $Results -DestinationPath $combinedMd

    Write-Host ""
    Write-Host "Wrote semaphore sweep results to:"
    Write-Host "  $combinedJson"
    Write-Host "  $combinedMd"
}
finally {
    try {
        & docker compose @ComposeArgs down | Out-Null
    } catch {
        Write-Warning "Could not stop benchmark stack cleanly."
    }

    if ($null -ne $OriginalMaxConcurrentConversions) {
        $env:MAX_CONCURRENT_CONVERSIONS = $OriginalMaxConcurrentConversions
    } else {
        Remove-Item Env:MAX_CONCURRENT_CONVERSIONS -ErrorAction SilentlyContinue
    }
    if ($CreatedGitCommit) {
        Remove-Item Env:GIT_COMMIT -ErrorAction SilentlyContinue
    }
    Pop-Location
}
