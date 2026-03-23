# UADE Docker Project Notes

This document contains project-specific learnings and regression-avoidance notes. Review it before making significant changes to avoid repeating past mistakes.

## Table of Contents

- [Queue Feature Lessons](#queue-feature-lessons)
- [Local File Queue Lessons](#local-file-queue-lessons)
- [Always-Visible Launcher Lessons](#always-visible-launcher-lessons)
- [Queue Sharing and Save Lessons](#queue-sharing-and-save-lessons)
- [Queue Mobile UI Lessons](#queue-mobile-ui-lessons)
- [Backend Hardening Lessons](#backend-hardening-lessons)
- [Test Lessons](#test-lessons)
- [Code Quality Lessons](#code-quality-lessons)
- [UI State Management Lessons](#ui-state-management-lessons)
- [Development Mode Lessons](#development-mode-lessons)
- [Build Metadata Lessons](#build-metadata-lessons)
- [Docker Base Image (CLI) Release Lessons](#docker-base-image-cli-release-lessons)
- [Security Scan Lessons](#security-scan-lessons)
- [Local Cleanup Lessons](#local-cleanup-lessons)

---

## Queue Feature Lessons

**Key Takeaways:** Treat the queue as a simple, single list. Reuse existing conversion logic and centralize UI state management to ensure consistency. Handle browser storage errors gracefully.

- **Data Model:** Treat the feature as a single `Queue`, not a multi-playlist system. The current UX and data model assume one ordered in-memory list.
- **UI Placement:** Keep the queue UI attached to the player area. A compact launcher/summary bar is less invasive than a full extra page section.
- **Reuse Logic:** Reuse the existing single-track conversion flow. Queue playback should wrap the current convert/play path instead of inventing a second playback pipeline.
- **State Management:** Only update queue playback state after conversion succeeds. Do not switch the active queue track or shareable source URL before the new track is actually playable.
- **Centralize UI Lock:** Keep UI lock state centralized. Queue item buttons, share/download, and queue controls should all disable consistently during probe/convert work.
- **Consistent Rendering:** Queue controls must update on both lock and unlock through the same render path to avoid inconsistent UI states.
- **State Derivation:** The queue launcher state must always derive from actual queue contents, not generic playback state. Playing a module outside the queue must not make queue controls appear active.
- **State Cleanup:** Clear stale `currentPlaylistTrackId` when normal non-queue playback starts to prevent highlighting and navigation artifacts.
- **Storage Resilience:** `localStorage` access can throw in restricted contexts. All `getItem`, `setItem`, and `removeItem` calls need `try/catch` wrappers.
- **Auto-Play Behavior:** Auto-play only the first queued track when the queue was empty and nothing is already playing. Never interrupt active playback just because a new item was queued.
- **Destructive Actions:** Reserve saved-queue removal for the explicit `Clear` action. Do not auto-delete from storage on per-item removal.
- **Accessibility:** Use a real full-bar hit target for opening the queue, with separate real action buttons, to ensure coherent accessibility and event handling.

## Local File Queue Lessons

**Key Takeaways:** Defer heavy work until it's needed. Keep the probe-then-convert pattern sharp. Cache conversion results on the track object so replay is instant.

- **Deferred Conversion:** Probe local files on queue add (`/probe-upload`), which returns a `module_hash` (content-addressed MD5). When playback is triggered, the client tries `/convert-probed` with the hash (avoiding re-upload); if 404, falls back to `/upload` with the full file. Treat `/convert-probed` as a best-effort optimization, not guaranteed shared state. It is a great fit for the primary single-container Docker Desktop path, but multi-container deployments should assume fallback may be needed after a container hop.
- **Track Object Mutation:** After a deferred track is converted, keep both `localFile` and `moduleHash` on the track and cache `playUrl`/`downloadUrl` on the track object. Subsequent plays use the cached URLs without re-uploading, but preserving `localFile` keeps `/upload` recovery available if cached audio later expires or `/convert-probed` is unavailable.
- **File Object Lifecycle:** `File` objects from drag-drop or file input remain valid as long as the page is alive, but cannot survive serialization. Exclude local tracks from share/bookmark URLs, but browser-local saved queues may serialize local tracks via `moduleHash` or cached conversion URLs.
- **Three Playback Paths:** `playPlaylistTrack()` must handle three cases: (1) already-converted local track with cached URLs, (2) deferred local track with `localFile` + `moduleHash` (tries `/convert-probed` first, falls back to `/upload`), (3) URL-based track (uses `/convert-url`). Keep these paths explicit — collapsing them introduces subtle regressions.
- **Saved Queue Durability:** When serializing a converted local track for browser-local restore, preserve `moduleHash` alongside cached `playUrl`/`downloadUrl`. If the converted audio expires later, replay should fall back to `/convert-probed` before removing the queue item.
- **Cached Track Verification:** Do not treat every failed `HEAD` probe of cached local audio as permanent expiry. `404`/`410` are real cache-miss signals, but transient verification failures should preserve the queue item instead of removing it.
- **Recovery Priority:** If a cached local track still has `localFile`, `/upload` remains a valid recovery path even when `moduleHash` is missing or `/convert-probed` fails for non-404 reasons. Treat `/convert-probed` as an optimization, not the only recovery route.
- **Multi-Container Expectation:** Shared converted-audio cache is the important cross-instance guarantee. Probed local-file state is container-local by default, so queue playback must remain correct when `/convert-probed` fails and `/upload` is required instead.
- **Probe vs Upload:** `/probe-upload` returns metadata without conversion artifacts. Do not reuse the probe response as if it were a conversion result.
- **Batch Guardrails:** Queue add probes local files one-by-one, so `/probe-upload` may need a higher rate limit than normal conversion endpoints. Pair that with a client-side batch cap so one drop or file-picker action cannot enqueue an unbounded number of probes.
- **Dev Mode Guardrails:** When rate limiting is disabled for local/dev use, disable the browser-side queue batch cap too. Otherwise the UI still enforces a production guardrail even though the backend limiter is off.
- **Stable Queue Affordance:** Do not reuse the visible `+ Files` queue browse label as a per-file probe progress indicator. In Firefox multi-file drops, repeatedly mutating that label to `Checking...` proved brittle; batch progress belongs in status text, while the queue affordance should stay stable.
- **Accept Attribute Sync:** `loadSupportedExtensions()` fetches formats from `/supported-extensions` and dynamically sets `accept` on all file inputs (`fileInput` and `queueFileInput`). No hardcoded `accept` attributes in HTML.
- **Auto-Play on Queue Add:** Only auto-play when the queue was empty and nothing is playing. Never interrupt active playback just because a file was dropped onto the queue.
- **Autoplay Recovery:** Queue autoplay can hit browser-policy or playback-start failures during local batch adds, especially in Firefox. Any `audioPlayer.play()` failure path must release the global UI lock, not just the explicit `NotAllowedError` branch.

## Always-Visible Launcher Lessons

**Key Takeaways:** Separate player content visibility from the queue launcher. Use HTML `hidden` attribute for content gating, not CSS `display: none` on the section.

- **Section vs Content:** The `#player-section` should always be visible (it contains the launcher bar). Player content (heading, audio controls) lives in a `#player-content` div with `hidden` attribute, toggled by `updatePlayerSectionVisibility()` when audio loads.
- **CSS Cleanup:** When switching from JS-driven `style.display` to HTML `hidden`, remove the corresponding `display: none` CSS rule on `#player-section`. Leaving it causes the section to be invisible even though JS no longer touches its display property.
- **Dead Code:** After removing visibility gating from `syncUiLockState()` and `renderPlaylistLauncherBar()`, grep for orphaned `playerSection.style.display` assignments in other functions (e.g., `playFile`).
- **Hitbox Overlay Punch-Through:** Interactive elements inside a parent with `pointer-events: none` need explicit `pointer-events: auto` and `z-index` to receive clicks. The `+ Files` label uses `z-index: 2` to punch through the `.playlist-launcher-hitbox` overlay.
- **HTML Restructuring Risk:** Moving elements between wrapper divs in a deeply nested HTML structure is error-prone with string-based editing. Verify closing `</div>` counts after restructuring and run HTMLHint before committing.
- **Toggle Button State:** The queue Open/Hide toggle is disabled via `data-content-disabled` when the queue is empty. This means the empty-panel state is unreachable via the UI — Pa11y cannot exercise it.
- **Accessibility Coverage:** The always-visible launcher bar and `+ Files` label are scanned by the `desktop-home` and `iphone15-home` Pa11y scenarios. No dedicated empty-queue accessibility scenario is needed because the panel toggle is disabled when empty.

## Queue Sharing and Save Lessons

**Key Takeaways:** Use compact URL parameters for shareable queues. Prioritize queue URLs over single-track params at startup.

- **URL Schema:** Use short keys (`v`, `t`, `n`, `u`, `s`, `f`, `o`) to keep `?queue=` URLs compact.
- **User Experience:** Warn when queue URLs get long, but do not block the share/bookmark action.
- **Startup Behavior:** Shared queue URLs should take precedence over single-track URL parameters at startup.
- **Idempotency:** Bookmark toggling should be idempotent, removing the queue parameter from the URL if pressed again.

## Queue Mobile UI Lessons

**Key Takeaways:** Scope mobile changes to queue controls. Use stable layouts and text labels. Ensure adequate tap targets.

- **Scoped Styling:** Keep mobile queue changes scoped to queue/playlist controls only.
- **Stable Labels:** Do not rely on transport-style emoji for navigation on all platforms. Use stable text labels like `Prev` and `Next`.
- **Layout:** Use a fixed one-row layout for mobile queue item actions to prevent unpredictable wrapping. If an action label overflows, shorten only the mobile-visible text (e.g., `Remove` becomes `Del`) while keeping the full `aria-label`.
- **Grid Stability:** Header actions (`Save`, `Bookmark`, `Share`, `Clear`) should use stable grid slots on mobile to prevent layout jumps during state changes.
- **Consistent Feedback:** Match queue share feedback (e.g., "Copied!") to the single-module share interaction.
- **Tap Targets:** Ensure queue-only mobile buttons have consistent tap targets of at least `44px` height.
- **Viewports:** Constrain the expanded queue panel height on small screens and let it scroll internally.
- **Initial State:** Use CSS to manage the initial visibility of UI elements that depend on runtime data. This prevents empty badges or placeholder controls from flashing on first paint.

## Backend Hardening Lessons

**Key Takeaways:** Validate remote URLs on the backend before use. Return consistent JSON errors and map upstream failures to appropriate client-facing error codes.

- **Input Validation:** `/probe-url` should validate remote module URLs before the frontend adds them to the queue.
- **Error Handling:** `/probe-url` and `/convert-url` must return JSON errors consistently. Use `request.get_json(silent=True)` and explicit JSON `400` responses for bad requests.
- **Error Mapping:** Map upstream `4xx` errors from user-supplied URLs to a client-facing `400`, not a `500` internal server error.
- **Error Exposure:** Do not return raw exception text, stack traces, or subprocess stderr in JSON error payloads. Log detailed failure context on the server, but send stable generic error messages to clients.
- **Endpoint Responsibility:** Keep `/probe-url` for metadata only; it should never return conversion artifacts.
- **Concurrency:** The sample-file lock must be based on the actual cached sample path, not the module namespace, to serialize access correctly.
- **Concurrency:** Content-addressed `/probe-upload` dedup must tolerate concurrent uploads of the same bytes. Use an atomic replace/move into the hash-based path so one request winning the race does not cause the others to return 500.
- **Security:** Sanitize download filenames aggressively on the server and parse `Content-Disposition` safely on the client.

## Test Lessons

**Key Takeaways:** Use the local test server and Docker Compose workflows for reliable testing. Keep accessibility checks in sync with interactive scenarios.

- **Negative Cases:** Use the local test server for negative cases that require hitting a real fetch path. Use external-looking dummy URLs for validation-only reject cases.
- **Service Isolation:** If a scan or test flow needs app-side policy changes such as `UADE_TEST_MODE=1`, model it as a dedicated Compose service rather than relying on caller-managed environment setup.
- **Shell Scripts:** Avoid `sed` when shell parameter expansion is sufficient, as flagged by ShellCheck.
- **Expected Noise:** Expect some negative-path noise in Docker test logs, especially UADE metadata errors for intentionally unsupported files and test HTTP server `ConnectionResetError` when oversized downloads are aborted early.
- **Expected Browser Noise:** During mixed local queue drops, Firefox may log autoplay-block messages and `/probe-upload` `500` responses for unsupported files. Treat those as expected noise unless the UI remains locked or the queue stops advancing.
- **Test Environment:** Prefer the repo's Docker Compose flow for endpoint coverage over ad hoc local execution.
- **Compose Exit Behavior:** Prefer `docker compose ... run --rm --build uade-test-runner` for the one-off endpoint test job. Using `up` for `uade-web`, `uade-test-runner`, and `test-http-server` stays attached because the helper services are long-lived.
- **Compose Variant Switching:** When moving between Compose test variants that override the same `uade-web` service, bring the stack down first. Reusing a stale container can preserve the wrong env vars and make suites fail for configuration reasons instead of code regressions.
- **Runtime Config Contract:** If a static client limit is derived from backend config, expose it from the server and test the server-to-client contract directly. A tiny runtime config endpoint is easier to keep in sync than duplicated constants in backend code, frontend code, and docs.
- **Fixture Downloads:** Treat `test/test_endpoints.sh` fixture downloads as a flake risk. It currently uses `curl -s --insecure -o ...` without checking HTTP status or content, which can silently save an error page or truncated file as a module fixture.
- **Upload Debugging:** When `/convert-url` tests pass but `/upload` fails with `Unknown format`, inspect the uploaded fixture bytes first. That pattern points more strongly to a bad fixture payload than to a regression in upload handling.
- **Regression Coverage:** When local queue behavior depends on server-resident probed files, add endpoint regressions for both `/convert-probed` recovery after cached-audio deletion and concurrent same-content `/probe-upload` requests.
- **CI/CD:** A long-running attached `docker compose up` can hit agent timeouts. Check `docker compose ps` or rerun in detached mode before assuming failure.
- **Docker Flakes:** A transient missing-network error right after Compose teardown can be infrastructure noise rather than a code regression. Retry once from a clean stack before debugging the app.
- **Accessibility:** Run accessibility checks within an integration test environment that has a real browser and running application.
- **Accessibility:** Use `test/accessibility-preflight.js` to verify the player reaches the intended interactive states before running `pa11y-ci`.
- **Accessibility:** Generate the Pa11y config on the fly from `test/accessibility-scenarios.js` rather than maintaining a static config file.
- **Accessibility:** Ensure every Pa11y scenario with `actions` has a corresponding Playwright preflight path to validate the same interactive state.
- **Accessibility:** If the accessibility runner installs `pa11y-ci` dynamically, print `pa11y-ci --version` in the logs so the exact runtime version is visible during test runs.
- **Accessibility:** When bumping `test/package.json` `playwright-core`, also update the Playwright image tag in `test/docker-compose.tooling.yml`.
- **Accessibility:** Playwright image browser paths can change across versions; keep `test/test_accessibility.sh` compatible with both `chrome-linux/chrome` and `chrome-linux64/chrome`.
- **Accessibility:** The number of passing scenarios may change. Treat `test/test_accessibility.sh` and current test output as the source of truth instead of hardcoding counts in prose.
- **Accessibility:** Keep accessibility documentation tied to the actual scripts in `test/`. Script names and helper entry points can drift over time, so docs should be updated alongside the implementation.
- **Accessibility:** For queue accessibility, use a preloaded `?queue=` URL to create a deterministic starting state for scans.
- **Accessibility:** To verify the open-queue state in accessibility scans, trigger the explicit queue toggle and wait for the queue panel itself to become visible before auditing.

## Code Quality Lessons

**Key Takeaways:** Treat code quality as a repo-wide pipeline, not a Python-only concern. Keep tool-specific configuration in source-controlled manifests and make the quality flow validate the full supported stack.

- **Configuration:** Keep each tool's configuration in its canonical source-controlled file instead of duplicating active rules in prose.
- **Configuration:** For Ruff specifically, `pyproject.toml` is the source of truth for rule selection.
- **Best Practices:** When enabling stricter Ruff rules (e.g., `FBT`, `SLF`, `ARG`), prefer fixing code over adding ignores.
- **Toolchain:** The repo's quality flow should validate the full supported stack: frontend assets, Python, Dockerfiles, Compose files, workflows, shell scripts, YAML, and instruction files.
- **Documentation Checks:** Keep repo guidance validation and general documentation validation separate. `test/check-instructions.mjs` should stay focused on instruction/guidance contracts, while `test/check-documentation.mjs` should own markdown/doc integrity checks. If a new checker is added under `test/`, make sure the existing ESLint `/test/*.{js,mjs}` pass covers it, register it in `test/knip.config.js` if needed, and mount every file it needs in the quality-check container.
- **Toolchain:** `knip` is now part of the quality workflow for JavaScript dead-code auditing. Keep its scope defined through `test/knip.config.js` with explicit entry files and script-invoked dependency ignores, rather than relying on raw package-graph discovery.
- **Toolchain:** The Ruff portion of the quality check should run both `ruff format --check` and `ruff check`.
- **Toolchain:** Aggregate multi-file failures in PowerShell scripts to show all errors, not just the last one.
- **Toolchain:** Keep quality-tool versions in Dependabot-managed manifests where possible. Docker-based tools such as Hadolint, Actionlint, and ShellCheck should be pinned in `test/docker-compose.tooling.yml`, while supporting `apk` packages in test Dockerfiles remain manual pins and should not be treated as Dependabot-managed.
- **Validation Scope:** Explicitly include `docker-compose.dev.yml` in validation scripts and quality-check container mounts if it's part of the supported workflow.
- **Layer Caching:** In `Dockerfile.quality`, COPY each dependency manifest (`docker-compose.tooling.yml`, `package.json`, `requirements-quality.txt`) immediately before its install step. Bundling all COPYs together means a change to any one manifest invalidates every install layer.
- **COPY --chmod:** Use `COPY --chmod=755` instead of a separate `RUN chmod` to eliminate an extra layer.
- **Dead CSS:** Do not add dead-CSS auditing to the enforced quality loop until the selector analysis has a stable safelist for dynamic UI states. Simple audits mostly flag generated classes like `status-*` and dataset-driven selectors such as `data-drag-cue-active`, which creates more noise than signal.

## UI State Management Lessons

**Key Takeaways:** Centralize UI state synchronization to prevent drift. Decouple lightweight state toggles from heavy DOM rendering. Use an internal sync path to manage global lock states while preserving complex per-item logic.

- **Internal Parameterized Sync:** Use a parameterized function (e.g., `syncUiLockState(locked)`) as the single source of truth for the global lock, and call it directly with explicit `true` or `false` values at each lock transition.
- **Explicit Selector Scope:** Within the internal sync path, use a bounded, explicit selector list (e.g., `.play-btn`, `.playlist-remove-btn`) to manage the primary lock state for generic controls.
- **Content-Disabled Pattern:** To preserve context-dependent `disabled` states (e.g., a "Next" button that should stay disabled at the end of a queue even when the UI is unlocked), use a `data-content-disabled="true"` attribute. The sync path must combine the global `locked` state with this attribute: `el.disabled = locked || el.dataset.contentDisabled === "true"`.
- **Decouple Rendering:** Avoid recommending or using heavy DOM-rebuild functions (like `renderPlaylist()`) as the primary path for simple lock toggles. Use the internal sync path with the content-disabled pattern to maintain performance and correct state.
- **Coherent Synchronization:** Always update `aria-busy` and `disabled` together in the same internal sync path to ensure a consistent and accessible UI experience.

## Development Mode Lessons

**Key Takeaways:** Isolate development configuration in `docker-compose.dev.yml`. Make Python hot reload opt-in.

- **Configuration:** Keep the base `docker-compose.yml` production-like. Use `docker-compose.dev.yml` for development-only overrides like hot reloading.
- **Environment Variables:** Note that `FLASK_ENV=development` is descriptive, while `FLASK_DEBUG=1` is the switch that enables the reloader.
- **Live Reload:** Bind-mount the `./web` directory to see HTML, CSS, and JS changes on browser refresh.
- **Live Reload:** Gate Flask's debug/reload mode on the `FLASK_DEBUG=1` environment variable in `server.py`.
- **Documentation:** Explicitly document the difference between static asset and backend reload behavior.
- **Documentation:** If dev mode is mentioned in the main compose comments or docs, keep the wording explicit that reload is enabled only through `docker-compose.dev.yml`, not in live or production deployments.

## Build Metadata Lessons

**Key Takeaways:** Keep image build time metadata generated at build time, not runtime. Use one source of truth when CI provides it, and keep a local fallback for developer builds.

- **Single Source of Truth:** If CI provides `IMAGE_CREATED`, use that same value for both `org.opencontainers.image.created` and the app-readable build-time file so image metadata and runtime health output stay aligned.
- **Local Fallback:** Keep the baked file fallback in the image for local builds. Requiring compose or runtime env-var injection for `image_build_time` adds avoidable complexity and is easy to forget.
- **Runtime Override:** `get_image_build_time()` should still honor `IMAGE_BUILD_TIME` when explicitly set so operators can override the reported value for exceptional deployments or debugging.
- **OCI vs Runtime:** OCI labels are the best-practice place for container image metadata, but the app still needs its own readable source at runtime because a running container cannot easily introspect its own image labels.
- **Health Test Coverage:** If `/health` exposes `image_build_time`, tests should verify it is non-null, parseable, and in the past rather than only checking that the field exists.
- **Layer Cache Optimization:** `ARG` values that change every build (e.g. `GIT_COMMIT`, `IMAGE_CREATED`) bust the Docker layer cache for all subsequent layers. Place these ARGs as late as possible — after expensive layers like `apt-get install`, `pip install`, and `COPY --from` stages.
- **Label Grouping:** Group all OCI metadata labels (`image.source`, `image.created`, `image.revision`) together in the late metadata block for readability, even if static labels don't affect caching.

## Docker Base Image (CLI) Release Lessons

**Key Takeaways:** Treat CLI base image releases as explicit versioned artifacts. Bump versions and docs manually, then let CI publish exactly the version you set.

- **Build Numbers:** Increment `base.<BUILD_NUMBER>` for base image security fixes, dependency changes, and other Dockerfile changes that should produce a new published image, even if the effective package set appears unchanged.
- **Version Source:** Treat the version comment in `Dockerfile` as the source that the base-image publish workflow reads for automatic tagging on `main`.
- **Documentation:** Update `docs/UADE_VERSIONS.md` whenever cutting a new CLI base image so the published tag history and current stable version stay aligned.
- **Documentation Order:** Keep `docs/UADE_VERSIONS.md` in strict descending release order (`newest` to `oldest`) and sanity-check for duplicated or misplaced version headings after manual edits.
- **Stable Version Docs:** Update user-facing version references such as `README.md` when the stable CLI base image changes.
- **Package Pinning Scope:** Hadolint package pinning guidance applies to both build-stage and runtime `apt-get install` steps. Do not stop after pinning only the final runtime dependencies.
- **CI Publish Model:** The CI workflow publishes the version you set in `Dockerfile`; it does not choose or auto-increment the next `base.<BUILD_NUMBER>` for you.
- **Release Trigger:** For automatic publish, the versioned `Dockerfile` change must be committed and pushed to `main`. Local validation alone does not publish anything.
- **Pin Drift:** `Dockerfile.web` can intentionally lag behind the latest stable CLI base image. If it does, document both the current stable CLI base image and the current `Dockerfile.web` pin explicitly so the mismatch is understood rather than accidental.
- **Validation:** Before releasing a new CLI base image version, run the repo quality flow, build the image locally, and exercise the documented examples in `docs/CLI-USAGE.md` to confirm the runtime dependencies still work.
- **Fresh Verification:** If a lint warning appears to contradict the current `Dockerfile`, rerun the repo quality suite before changing code again. Old Hadolint output can reflect a previous file state rather than the current tree.

## Security Scan Lessons

**Key Takeaways:** Understand common false positives from security scanners. Focus on cache integrity and safe handling of external inputs.

- **False Positives:** ZAP SQL injection findings on `/convert-url` were false positives caused by incorrect error classification, not evidence of a real SQL-backed issue.
- **False Positives:** Once `/convert-url` stopped surfacing hostile remote-fetch failures as `500`, the SQL injection findings disappeared in both quick and full ZAP scans.
- **False Positives:** Remaining ZAP noise is mostly low-signal warnings like HTTP-only scanning context or suspicious comments, not active queue-related vulnerabilities.
- **Seed Fixtures:** Keep ZAP seed fixtures distinct from integration-test fixtures. Synthetic ZAP-only files should use unique names such as `zap-placeholder-*` so shared fixture volumes do not create confusing collisions.
- **Seeded Scans:** Keep plain ZAP services and seeded ZAP services separate. Seeded scans are useful for coverage and regression checks, but the default scan path should still run without fixture-only setup.
- **Seeded Scans:** When seeded scans need relaxed backend policy for internal fixture hosts, give them a dedicated app service instead of toggling shared runtime state.
- **Compose Design:** Avoid using Compose `extends` when the seeded service needs materially different runtime wiring, especially ports or target hostnames. A standalone service definition is more reliable.
- **Exit Codes:** Treat ZAP exit code `2` as "scan completed with warnings", not as an infrastructure failure.
- **Cache Integrity:** Use a `HASH.cache-access.json` sidecar file for more reliable LRU cache management than `mtime`.
- **Cache Integrity:** Sidecar access-record updates must tolerate concurrent writers. Handle `ENOENT` on file replacement as an expected condition.
- **Cache Integrity:** Implement cleanup logic for orphaned `*.tmp` files to prevent cache pollution from failed sidecar updates.
- **Cache Behavior:** The cache should promote a cached WAV file to FLAC on demand if a FLAC-capable request arrives, rather than returning the wrong format.
- **Cache Behavior:** Verify WAV-to-FLAC promotion on read paths too. `/play/*` and `/download/*` should promote and serve FLAC correctly when only WAV is cached.
- **Cache Behavior:** Under scanner-style concurrent load, cache health is better judged by leftover temp files and missing sidecars than by raw warning count in logs.
- **Cache Behavior:** After the sidecar hardening patch, a healthy post-scan cache check is no `*.tmp` files in `/tmp/cache` and every cached audio object has a matching `.cache-access.json`.
- **Log Noise:** Reduce log noise during DAST scans by logging expected hostile-input rejections and DNS lookup failures at the `INFO` level without tracebacks.

## Local Cleanup Lessons

**Key Takeaways:** Keep local temp-file cleanup centralized, serialized, and explicit about which request paths may trigger it. Treat the raw file-removal helper as internal-only.

- **Read Path Safety:** Do not trigger local cleanup before `/play/*` or `/download/*`. Those read paths can legitimately need older local files and should not delete them immediately before serving.
- **Informational Fast Paths:** Do not trigger local cleanup from lightweight informational routes such as `/health`, `/`, `/examples`, `/supported-extensions`, `robots.txt`, and `sitemap.xml`. These endpoints should stay as cheap as possible.
- **Single Execution Path:** Route all local cleanup entrypoints through one lock-protected helper. Avoid direct calls to the raw file-removal routine from routes or tests.
- **Internal Primitive:** Keep the raw deletion helper private-ish (for example `_cleanup_old_files_impl`) so future changes naturally use the gated and locked wrappers instead of bypassing them.
- **Manual vs Request Cleanup:** Request-triggered cleanup should obey the interval gate, but explicit/manual cleanup paths such as `/test/run-cleanup` should still be able to force an immediate run while sharing the same lock.
- **Hook Interactions:** When cleanup moves into a global `before_request` hook, exclude the full `/test/` namespace, not just one maintenance route. Otherwise new test helpers can accidentally pick up an extra cleanup pass and skew status or timestamp expectations.
- **Fast Path Guard:** A lock-free fast-path check before acquiring the cleanup lock is fine as an optimization, but the actual interval decision must be re-checked inside the lock.
- **State Scope:** For this app, a lock is the real concurrency control. Extra cleanup state such as `in_progress` is optional observability, not a correctness requirement.
- **Shared-Volume Test Helpers:** In Docker-based tests, cache artifacts may be owned by another container or an earlier run. Test-only helpers that mutate cache-file mtimes should handle `PermissionError` and can fall back to atomic rewrite plus `utime`.
- **Docs Accuracy:** If cleanup moves from route-local calls to a gated request hook, update docs to say it is request-triggered and not a background hourly job.
