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
- `test/bench/semaphore-balance.js`: Cloud Run sweep-only mixed workload for `/play/*` plus cold conversion contention
- `test/bench/cross-instance-scaleout.js`: cross-instance scale-out benchmark where one app instance handles conversion-heavy traffic and another serves playback from the shared cache

The default benchmark runner executes the suites in this order: smoke, conversion, cache, streaming, DAST-patterns. `test/bench/semaphore-balance.js` and `test/bench/cross-instance-scaleout.js` run only through their dedicated wrappers/overlays.

`test/bench/dast-patterns.js` currently covers:

- same-hash duplicate cold `convert-url` waiters
- mixed-hash contention between cold `convert-url` and cold `convert-probed`
- cold-to-warm playback burst after a cold TFMX convert

Contract notes for the contention-oriented suites:

- `test/bench/dast-patterns.js` is the intentional same-hash duplicate-convert suite; it explicitly treats the current `200` or `409 processing` contract as valid for same-instance followers after the `2s` duplicate wait budget.
- `test/bench/semaphore-balance.js` and `test/bench/cross-instance-scaleout.js` now keep a dedicated warm playback artifact (`stormlord.ahx`) separate from the evicted cold `convert-url` target, so the play side stays read-only while the convert side still exercises reconversion.
- those mixed-load balance suites also accept `409 processing` on their conversion legs, because higher-VU same-hash pressure can now legitimately hit the short duplicate-convert contract instead of always returning `200`.

## Benchmark Scheduling Notes

The benchmark `startTime` values are intentional. They are not arbitrary sleeps.

Current rationale:

- `test/bench/conversion.js` keeps a buffer between the cold `convert-probed` stage and the warm follow-up stages so the warm measurements do not accidentally overlap the cold owner conversion
- `test/bench/dast-patterns.js` still staggers the heavy scenarios on purpose because the slow TFMX `convert-url` path can take around `14s` to `15s` locally, and the cold `convert-probed` path can still take around `4s` to `5s`
- the current local timings were verified by rerunning the benchmark stack and checking `uade-web-player` logs for warnings, errors, tracebacks, or overlap-related anomalies; none were observed

Current local stagger:

- `test/bench/conversion.js`
  - `warm_convert_probed`: `40s`
  - `warm_upload`: `46s`
- `test/bench/dast-patterns.js`
  - `multi_hash_convert_url`: `30s`
  - `multi_hash_convert_probed`: `55s`
  - `cold_to_warm_playback_burst`: `1m15s`

The `conversion.js` offsets use the safer `40s` / `46s` window because tighter local variants still produced warm-stage overlap and occasional request failures on cold-cache reruns.

## Latest Local Benchmark Extract

Latest local benchmark run on April 21, 2026:

| Flow | Source | Avg | Median | P95 | Max | Notes |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Smoke endpoints overall | `smoke-summary.json` | `1.49ms` | `0.94ms` | `3.63ms` | `24.54ms` | Healthy baseline |
| `GET /health` | `smoke-summary.json` | `2.21ms` | `1.38ms` | `5.59ms` | `14.56ms` | Fast |
| `GET /` | `smoke-summary.json` | `1.78ms` | `0.92ms` | `6.00ms` | `24.54ms` | Fast |
| `GET /client-config.js` | `smoke-summary.json` | `1.03ms` | `0.70ms` | `2.48ms` | `7.38ms` | Fast |
| `GET /supported-extensions` | `smoke-summary.json` | `0.95ms` | `0.76ms` | `1.78ms` | `4.21ms` | Fast |
| Warm upload | `conversion-summary.json` | `5.36ms` | `5.24ms` | `5.72ms` | `5.74ms` | Cache-hot |
| Cold `convert-probed` | `conversion-summary.json` | `4.48s` | `4.43s` | `4.65s` | `4.68s` | Real conversion cost |
| Warm `convert-probed` | `conversion-summary.json` | `3.40ms` | `3.33ms` | `4.00ms` | `4.16ms` | Cache-hit speed |
| Multi-hash `convert-probed` | `dast-patterns-summary.json` | `4.40s` | `4.40s` | `4.40s` | `4.40s` | Single cold probed conversion |
| Multi-hash `convert-url` TFMX | `dast-patterns-summary.json` | `13.76s` | `13.76s` | `13.76s` | `13.76s` | Slowest path |
| Play burst full | `dast-patterns-summary.json` | `0.79ms` | `0.80ms` | `0.80ms` | `0.80ms` | Very fast once ready |
| Play burst range | `dast-patterns-summary.json` | `0.78ms` | `0.81ms` | `0.82ms` | `0.82ms` | Very fast once ready |

Timing notes from the same run:

- cold `convert-probed` was dominated by UADE render at roughly `3.7s` to `4.1s`, plus FLAC compression at roughly `0.53s` to `0.64s`
- TFMX `convert-url` was dominated by UADE render at roughly `12.3s` to `13.2s`, plus FLAC compression at roughly `1.29s` to `1.53s`
- no real app errors, warnings, tracebacks, or fixture-server anomalies were observed during this run
- the duplicate `409 processing` responses in the DAST-pattern benchmark were expected and matched the short duplicate-convert contract

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

- current deployed Cloud Run default remains `MAX_CONCURRENT_CONVERSIONS=2`
- `1` is still clearly too conservative because it reintroduces heavy conversion queueing
- the corrected default `1/2/3` rerun still points back to `2` as the best single-instance balance for the current app contract
- higher exploratory values (`5` and `6`) only looked good in lighter low-contention sweeps; they should not override the more recent default-shape rerun or the conversion-heavy oversubscription comparison

Low-contention 8-VU sweep, after the FLAC and waiter-path updates:

- workload shape:
  - `4` full-play VUs
  - `2` range-play VUs
  - `1` cold `convert-probed` VU
  - `1` cold `convert-url` VU
- useful conclusion:
  - `1` is clearly too restrictive because it reintroduces queueing
  - `2` removes the queueing bottleneck without harming `/play`
  - `3` no longer beats `2` on the corrected default-shape rerun
- latest representative numbers:
  - `1`
    - play full p95: `2.86ms`
    - play range p95: `3.13ms`
    - cold `convert-probed` p95: `17.93s`
    - cold `convert-url` p95: `17.95s`
    - semaphore wait p95: `13.33s`
  - `2`
    - play full p95: `2.58ms`
    - play range p95: `3.05ms`
    - cold `convert-probed` p95: `4.74s`
    - cold `convert-url` p95: `15.12s`
    - semaphore wait p95: `0.01ms`
  - `3`
    - play full p95: `2.79ms`
    - play range p95: `3.52ms`
    - cold `convert-probed` p95: `6.49s`
    - cold `convert-url` p95: `19.97s`
    - semaphore wait p95: `0.01ms`

Conversion-heavy oversubscription check:

- workload shape:
  - `3` full-play VUs
  - `1` range-play VU
  - `3` cold `convert-probed` VUs
  - `3` cold `convert-url` VUs
  - total `10` VUs against the Cloud Run-style `8` thread shape
- this is the first sweep that meaningfully tests whether high semaphore values still make sense when conversion work can dominate the instance

Oversubscribed 5-minute comparison:

- `3`
  - play full p95: `1.64ms`
  - play range p95: `1.79ms`
  - cold `convert-probed` p95: `5.00s`
  - cold `convert-url` p95: `15.00s`
  - `Conversion lock wait` p95: `15.00s`
- `6`
  - play full p95: `2.14ms`
  - play range p95: `2.80ms`
  - cold `convert-probed` p95: `4.04s`
  - cold `convert-url` p95: `14.01s`
  - `Conversion lock wait` p95: `13.01s`

Interpretation:

- `6` still wins on cold conversion throughput and latency under real conversion pressure
- `3` still protects playback latency better
- the tradeoff is real under oversubscription, unlike the lighter 8-VU sweep where high values mainly looked equivalent because only `2` conversion VUs were active
- because Cloud Run must protect interactive playback as well as conversion throughput, `2` remains the conservative deployed default and `3` remains the safer high-load candidate unless the product goal shifts toward maximizing conversion throughput

## Cross-Instance Scale-Out

The repo also now includes a dedicated cross-instance benchmark overlay:

- one app instance (`uade-web-a`) handles conversion-heavy traffic
- another app instance (`uade-web-b`) handles playback-only traffic
- both instances share the same cache backend

This is closer to the Cloud Run “one hot instance, one fresh instance” mental model than the single-instance semaphore sweep.

First scale-out probe:

- playback on `uade-web-b` while `uade-web-a` was busy converting:
  - play full p95: `8.28ms`
  - play range p95: `17.81ms`
- `uade-web-a` carried the queueing:
  - `Conversion lock wait` avg: `11016.33ms`
  - `Conversion lock wait` p95: `18034.51ms`
  - `UADE audio render` avg: `9657.38ms`
  - `Full audio conversion pipeline` avg: `9859.93ms`

Interpretation:

- the queueing pressure stayed on the conversion-heavy instance, not the playback-focused one
- that supports the Cloud Run scale-out intuition better than the single-instance sweeps alone
- the current bottleneck under this pattern is duplicate-work locking on the conversion-heavy instance, not the global semaphore

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
- Read-only playback race fix
  - playback requests no longer perform lazy WAV-to-FLAC promotion on the hot path
  - the race-condition regression now verifies that parallel `/play/<file_id>` requests do not trigger FLAC compression and keep cached playback read-only
- Faster request-time FLAC compression
  - `compress_to_flac()` now uses `flac -5` instead of `--best`
  - this keeps compression broadly effective while cutting CPU cost on heavy artifacts
- Canonical FLAC conversion output
  - conversion endpoints now produce `flac` by default instead of choosing between WAV and FLAC per user agent
  - successful FLAC conversion removes the intermediate local WAV artifact instead of keeping both siblings around
  - reasoning:
    - this simplifies cache state to one normal playback artifact instead of a mixed WAV/FLAC lifecycle
    - it removes playback-side WAV-to-FLAC promotion as a performance concern on the steady-state path
    - it makes cross-instance cache behavior easier to reason about because conversion and playback both converge on the same artifact format
- Frontend example playback now uses `/convert-url`
  - the legacy `/play-example/<example_id>` route has been removed, and example playback now goes through the same `/examples` -> `/convert-url` -> `/play/<file_id>` path as other URL-backed playback
  - example cards resolve metadata from `/examples` and then call `/convert-url` directly, just like other URL-backed playback flows
  - reasoning:
    - this keeps the main playback path conceptually read-only: prepare audio through conversion, then serve it through `/play/<file_id>`
    - it removes one special backend route from the hot user flow and makes example playback follow the same conversion contract as shared URLs and queued tracks
    - it reduces architectural duplication by keeping example selection in the frontend and conversion in the conversion endpoint
- Short duplicate-convert wait contract
  - same-hash follower requests now wait up to `2s` for the owner conversion and then return HTTP `409` with `status: "processing"` and `retryable: true`
  - the frontend treats that as a retryable state instead of surfacing a hard conversion error immediately
  - the frontend retry window now totals `63s` (`1s + 2s + 4s + 8s + 16s + 32s`), which covers the current worst known heavy owner conversion class
  - the per-hash conversion lock now lives in the shared cache backend, so the same `409 processing` contract applies across instances when they share the same cache storage
  - the local multi-instance stack uses `/tmp/cache/conversion-locks` for this shared lock path
  - reasoning:
    - this avoids holding duplicate requests open for the full cold-convert duration
    - it protects Cloud Run request capacity better than long synchronous follower waits
    - it keeps the app simple: no queue product, no extra service, just a clearer duplicate-work contract
- Targeted `led-storm` FLAC-heavy cold-path recheck
  - earlier baseline on `571dca...` (`L_E_D_Storm`) was:
    - UADE render: `44038.08ms`
    - FLAC: `21807.33ms`
    - full pipeline: `66947.04ms`
  - targeted rerun after the `flac -5` change measured:
    - UADE render: `24179.37ms`
    - FLAC: `3908.71ms`
    - full pipeline: `28512.54ms`
  - net gain on the FLAC stage: about `17.90s` faster, or `~82.1%`
  - net gain on the full pipeline: about `38.43s` faster, or `~57.4%`
  - caveat: the FLAC-stage reduction is attributable to the compression-level change; the full-pipeline gain also includes run-to-run UADE variance on this very heavy module

Remaining dominant spikes:

- large cold owner conversions are still dominated by UADE render time for some modules
- request-time FLAC compression is smaller than before, but still a meaningful secondary tail on heavy artifacts
- duplicate same-hash owner/follower contention is now clearer and better bounded, but it still shows up as `409 processing` plus short lock waits under bursty load
