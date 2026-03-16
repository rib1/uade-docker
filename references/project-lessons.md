# UADE Docker Project Notes

This document contains project-specific learnings and regression-avoidance notes. Review it before making significant changes to avoid repeating past mistakes.

## Table of Contents

- [Queue Feature Lessons](#queue-feature-lessons)
- [Queue Sharing and Save Lessons](#queue-sharing-and-save-lessons)
- [Queue Mobile UI Lessons](#queue-mobile-ui-lessons)
- [Backend Hardening Lessons](#backend-hardening-lessons)
- [Test Lessons](#test-lessons)
- [Code Quality Lessons](#code-quality-lessons)
- [UI State Management Lessons](#ui-state-management-lessons)
- [Development Mode Lessons](#development-mode-lessons)
- [Build Metadata Lessons](#build-metadata-lessons)
- [Security Scan Lessons](#security-scan-lessons)

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
- **Security:** Sanitize download filenames aggressively on the server and parse `Content-Disposition` safely on the client.

## Test Lessons

**Key Takeaways:** Use the local test server and Docker Compose workflows for reliable testing. Keep accessibility checks in sync with interactive scenarios.

- **Negative Cases:** Use the local test server for negative cases that require hitting a real fetch path. Use external-looking dummy URLs for validation-only reject cases.
- **Shell Scripts:** Avoid `sed` when shell parameter expansion is sufficient, as flagged by ShellCheck.
- **Expected Noise:** Expect some negative-path noise in Docker test logs, especially UADE metadata errors for intentionally unsupported files and test HTTP server `ConnectionResetError` when oversized downloads are aborted early.
- **Test Environment:** Prefer the repo's Docker Compose flow for endpoint coverage over ad hoc local execution.
- **CI/CD:** A long-running attached `docker compose up` can hit agent timeouts. Check `docker compose ps` or rerun in detached mode before assuming failure.
- **Accessibility:** Run accessibility checks within an integration test environment that has a real browser and running application.
- **Accessibility:** Use `test/accessibility-preflight.js` to verify the player reaches the intended interactive states before running `pa11y-ci`.
- **Accessibility:** Generate the Pa11y config on the fly from `test/accessibility-scenarios.js` rather than maintaining a static config file.
- **Accessibility:** Ensure every Pa11y scenario with `actions` has a corresponding Playwright preflight path to validate the same interactive state.
- **Accessibility:** If the accessibility runner installs `pa11y-ci` dynamically, print `pa11y-ci --version` in the logs so the exact runtime version is visible during test runs.
- **Accessibility:** When bumping `test/package.json` `playwright-core`, also update the Playwright image tag in `test/docker-compose.accessibility.yml`.
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
- **Toolchain:** The Ruff portion of the quality check should run both `ruff format --check` and `ruff check`.
- **Toolchain:** Aggregate multi-file failures in PowerShell scripts to show all errors, not just the last one.
- **Validation Scope:** Explicitly include `docker-compose.dev.yml` in validation scripts and quality-check container mounts if it's part of the supported workflow.

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

## Security Scan Lessons

**Key Takeaways:** Understand common false positives from security scanners. Focus on cache integrity and safe handling of external inputs.

- **False Positives:** ZAP SQL injection findings on `/convert-url` were false positives caused by incorrect error classification, not evidence of a real SQL-backed issue.
- **False Positives:** Once `/convert-url` stopped surfacing hostile remote-fetch failures as `500`, the SQL injection findings disappeared in both quick and full ZAP scans.
- **False Positives:** Remaining ZAP noise is mostly low-signal warnings like HTTP-only scanning context or suspicious comments, not active queue-related vulnerabilities.
- **Cache Integrity:** Use a `HASH.cache-access.json` sidecar file for more reliable LRU cache management than `mtime`.
- **Cache Integrity:** Sidecar access-record updates must tolerate concurrent writers. Handle `ENOENT` on file replacement as an expected condition.
- **Cache Integrity:** Implement cleanup logic for orphaned `*.tmp` files to prevent cache pollution from failed sidecar updates.
- **Cache Behavior:** The cache should promote a cached WAV file to FLAC on demand if a FLAC-capable request arrives, rather than returning the wrong format.
- **Cache Behavior:** Under scanner-style concurrent load, cache health is better judged by leftover temp files and missing sidecars than by raw warning count in logs.
- **Cache Behavior:** After the sidecar hardening patch, a healthy post-scan cache check is no `*.tmp` files in `/tmp/cache` and every cached audio object has a matching `.cache-access.json`.
- **Log Noise:** Reduce log noise during DAST scans by logging expected hostile-input rejections and DNS lookup failures at the `INFO` level without tracebacks.
