# Performance Engineering

This repo now has a Docker-first benchmark harness for the web player. It follows the same pattern as the other test stacks: keep the application under Docker Compose, then run a dedicated one-off runner container against it.

The benchmark stack reuses the same fixture data as the endpoint test suite. Both flows prepare the shared `test-tmp` fixture volume through the same `test/prepare-endpoint-fixtures.sh` script.

The benchmark runner version pin lives in `test/docker-compose.tooling.yml`, alongside the other repo-managed test and quality tool image pins, so Dependabot can track it through the same `/test` Docker update flow.

## Benchmark Entry Point

Use the benchmark Compose overlay:

```bash
docker compose -f docker-compose.yml -f test/docker-compose.benchmark.yml run --rm --build uade-benchmark-runner
```

The runner writes benchmark summaries to `reports/benchmarks/`.

## Current Benchmark Suites

- `test/bench/smoke.js`: lightweight HTTP benchmarks for `/health`, `/`, `/client-config.js`, and `/supported-extensions`
- `test/bench/conversion.js`: upload and probe-to-convert benchmarks for `fixtures/modules/space_debris.mod`
- `test/bench/cache.js`: repeated `/convert-url` cache-hit benchmarking through the local fixture HTTP server
- `test/bench/streaming.js`: full-file and byte-range playback benchmarking after converting the TFMX fixture pair served by the local fixture HTTP server
- `test/bench/dast-patterns.js`: DAST-inspired contention and burst scenarios using local fixtures
- `test/bench/semaphore-balance.js`: Cloud Run-shaped mixed workload for `/play/*` plus cold conversion contention

The runner executes the suites in this order: smoke, conversion, cache, streaming, DAST-patterns.

`test/bench/dast-patterns.js` currently covers:

- same-hash duplicate cold `convert-url` waiters
- mixed-hash contention between cold `convert-url` and cold `convert-probed`
- cold-to-warm playback burst after a cold TFMX convert

## Cloud Run Semaphore Sweep

The repo also includes a host-side sweep wrapper for tuning `MAX_CONCURRENT_CONVERSIONS`
against the current Cloud Run shape:

- `1 CPU`
- `8` request concurrency
- Gunicorn `1` worker, `8` threads

Run it from PowerShell:

```powershell
.\test\run-cloudrun-semaphore-sweep.ps1
```

Default sweep:

- semaphore limits: `1`, `2`, `3`
- mixed load: `4` full-play VUs, `2` range-play VUs, `1` cold `convert-probed` VU, `1` cold `convert-url` VU
- duration: `8m` per semaphore value

Current measured recommendation for this Cloud Run shape:

- set `MAX_CONCURRENT_CONVERSIONS=2`
- reason: it removed conversion queueing seen at `1` while keeping `/play` latency effectively unchanged versus `3`

Latest 8-minute sweep result:

- `1`
  - play full p95: `1.55ms`
  - play range p95: `1.63ms`
  - cold `convert-probed` p95: `15.83s`
  - cold `convert-url` p95: `15.50s`
  - semaphore wait p95: `11.76s`
- `2`
  - play full p95: `2.93ms`
  - play range p95: `2.95ms`
  - cold `convert-probed` p95: `4.47s`
  - cold `convert-url` p95: `14.06s`
  - semaphore wait p95: `0.01ms`
- `3`
  - play full p95: `2.89ms`
  - play range p95: `3.35ms`
  - cold `convert-probed` p95: `4.69s`
  - cold `convert-url` p95: `15.39s`
  - semaphore wait p95: `0.01ms`

Artifacts:

- per-run `k6` summary: `reports/benchmarks/semaphore-sweep/limit-<n>/k6-summary.json`
- per-run combined summary: `reports/benchmarks/semaphore-sweep/limit-<n>/summary.json`
- cross-run rollups:
  - `reports/benchmarks/semaphore-sweep/summary.json`
  - `reports/benchmarks/semaphore-sweep/summary.md`

The wrapper also scrapes `uade-web-player` logs for:

- `Conversion semaphore wait`
- `Conversion lock wait`

That lets you compare stream latency against actual queueing time inside the app.

## Fixture Policy

Benchmark fixtures must match the endpoint test fixtures.

Why:

- conversion, cache, and playback benchmarks should exercise the same bytes the end-to-end suite validates
- the local fixture HTTP server removes third-party latency noise from `/convert-url` benchmarking
- one fixture-prep path reduces drift between test and benchmark coverage

The shared fixture-prep script downloads these files into the shared `test-tmp` volume:

```bash
fixtures/modules/space_debris.mod
fixtures/modules/gutenberg.txt
fixtures/modules/mdat.turrican_2_level_0-intro
fixtures/modules/smpl.turrican_2_level_0-intro
```

The benchmark runner uses those same fixture paths directly, and the cache and playback suites access them through `http://uade-test-http-server:8000/fixtures/...`.

## Environment Behavior

The benchmark overlay changes the app runtime in two ways:

- `UADE_TEST_MODE=1`
- `RATE_LIMIT_DISABLED=1`

The benchmark suite is measuring app performance, not rate-limit enforcement.

## Suggested Workflow

Use two benchmark passes when investigating performance work:

1. Cold-ish run:
   Start from a clean stack and run the benchmark suite once.
2. Warm-cache run:
   Run the benchmark suite again without clearing containers or temp volumes.

That split helps separate startup or cache-fill cost from steady-state behavior.

## Interpreting Results

The current thresholds are intentionally conservative. They are meant to catch obvious regressions first, not to declare strict production SLOs.

Treat these summaries as the baseline inputs for later work such as:

- tighter endpoint-specific latency thresholds
- cache-hit versus cache-miss comparisons
- concurrency sweeps
- multi-instance performance comparisons

## Current Findings

The most valuable performance changes so far have been app-side overhead reduction and contention control, not UADE flag tuning.

Implemented fixes and outcomes:

- Lower-overhead UADE subprocess handling in `web/server.py`
  - switched the long UADE render path away from full in-memory stderr capture
  - true cold `convert-url` improved from `7183.76ms` to `5261.69ms`
  - net gain: about `1.92s`, or `~26.8%`
- Global conversion semaphore plus timing logs
  - added `Conversion semaphore wait` and `Conversion lock wait` timings
  - this made queueing visible and allowed Cloud Run tuning from measured data instead of guesswork
- WAV-to-FLAC promotion race fix
  - parallel requests for the same cached WAV no longer trigger duplicate FLAC compression work
  - the race-condition regression now verifies one FLAC compression per same-hash promotion

Cloud Run recommendation:

- for the current Cloud Run shape (`1 CPU`, `8` request concurrency, Gunicorn `1` worker / `8` threads), set `MAX_CONCURRENT_CONVERSIONS=2`
- measured 8-minute mixed-load sweep result:
  - `1`: best raw `/play` latency, but heavy conversion queueing (`semaphore wait p95 11.76s`)
  - `2`: best overall balance
  - `3`: no meaningful playback improvement over `2`, slightly worse conversion-side result

Remaining dominant spikes:

- large cold conversions are still dominated by UADE render time for some modules
- request-time FLAC compression remains a large tail-latency contributor on the worst artifacts
- practical next lever: reduce or defer FLAC work on cold paths rather than chasing generic Linux tuning
