# UADE Docker Project Notes

## Queue feature lessons

- Treat the feature as a single `Queue`, not a multi-playlist system. The current UX and data model assume one ordered in-memory list.
- Keep queue UI attached to the player area. A compact launcher/summary bar is less invasive than a full extra page section.
- Reuse the existing single-track conversion flow. Queue playback should wrap the current convert/play path instead of inventing a second playback pipeline.
- Only update queue playback state after conversion succeeds. In particular, do not switch the active queue track or shareable source URL before the new track is actually playable.
- Keep UI lock state centralized. Queue item buttons, share/download, and queue controls should all disable consistently during probe/convert work.
- Queue controls must update on both lock and unlock through the same render path. If some controls only pick up their disabled state on a later `renderPlaylist()` pass, the UI will feel inconsistent even when the underlying lock flag is correct.
- Queue launcher state must always derive from actual queue contents, not generic playback state. Playing a module outside the queue must not make queue open/next controls appear active.
- Clear stale `currentPlaylistTrackId` when normal non-queue playback starts. Otherwise queue navigation and highlighting can stay active after the user leaves queue playback.
- Queue state must degrade cleanly when browser storage is unavailable. `localStorage` access can throw in restricted contexts, so all `getItem`, `setItem`, and `removeItem` calls need try/catch wrappers.
- Auto-play only the first queued track when the queue was empty and nothing is already playing. Never interrupt active playback just because a new item was queued.
- Do not auto-delete the saved local queue just because the visible queue became empty through per-item removal. Reserve destructive saved-queue removal for the explicit `Clear` action and make the status text reflect that difference.
- If both the launcher bar and a visible `Open`/`Hide` control should open the queue, avoid making the container itself a fake button with nested buttons. Use a real full-bar hit target plus separate real action buttons so accessibility and event handling stay coherent.

## Queue sharing and save lessons

- Compact queue URLs matter. Short keys (`v`, `t`, `n`, `u`, `s`, `f`, `o`) keep `?queue=` links smaller without adding dependencies.
- Warn when queue URLs get long, but do not block share/bookmark actions.
- Shared queue URLs should take precedence over single-track URL params at startup.
- Bookmark toggling should be idempotent: pressing bookmark again should remove the queue param from the current URL.

## Queue mobile UI lessons

- Keep mobile queue changes scoped to queue/playlist controls only. The rest of the player UI already has its own tested mobile behavior.
- Do not rely on transport-style emoji for queue navigation on iPhone. Use stable text labels like `Prev` and `Next` at the mobile breakpoint.
- Mobile queue item actions should use a fixed one-row layout when possible so `Play`, `Up`, `Down`, and remove do not wrap unpredictably and make entries too tall.
- If an action label overflows in the fixed mobile row, shorten only the mobile-visible text, not the accessible label. For example, `Remove` can become `Del` while `aria-label` keeps the full action.
- Queue header actions (`Save`, `Bookmark`, `Share`, `Clear`) should use stable grid slots on mobile so temporary text changes like copied/loading states do not cause row jumping.
- Match queue share feedback to the single-module share interaction. Temporary copied-state text should extend the base label rather than replacing it with a different visual pattern.
- Give queue-only mobile buttons consistent tap targets of at least `44px` height.
- Constrain the expanded queue panel height on small screens and let it scroll internally so it stays usable on full-height touch screens.
- When the player section is shown only because a saved queue exists, hide player metadata placeholders by default. The format badge should stay hidden until an actual track has loaded, otherwise startup shows an empty visual artifact.
- Put startup-safe hidden states in CSS for UI elements that depend on runtime data. If JS is solely responsible for hiding them, first paint can still expose empty badges or placeholder controls before state reconciliation runs.

## Backend hardening lessons

- `/probe-url` should validate remote module URLs before the frontend adds them to the queue.
- `/probe-url` and `/convert-url` must return JSON errors consistently, even for malformed JSON or wrong content type. Use `request.get_json(silent=True)` and explicit JSON `400` responses.
- Map hostile or malformed remote fetch failures away from `500`. Upstream `4xx` on user-supplied remote URLs should become client-facing `400`, not internal server error responses.
- Keep `/probe-url` metadata-only. It should confirm playability and return basic metadata, but never return conversion artifacts.
- The sample-file lock must be based on the actual cached sample path, not the module namespace, so concurrent requests serialize access to the shared target file.
- Download filename handling should sanitize aggressively on the server and parse `Content-Disposition` safely on the client.

## Test lessons

- Use the local test server for negative cases that actually hit the fetch path.
- Keep external-looking URLs for validation-only reject cases that fail before any network fetch. This preserves the intended validation path without burdening third-party services.
- Shell tests should avoid `sed` substitutions that ShellCheck flags when shell parameter expansion is enough.
- Expected negative-path noise in Docker test logs includes UADE metadata detection errors for intentionally unsupported files and test HTTP server `ConnectionResetError` when the app aborts oversized downloads early.
- For endpoint coverage, prefer the repo's Docker Compose flow instead of ad hoc local execution.
- A long-running attached `docker compose up` can hit agent timeout even while the stack is healthy. Check `docker compose ps` or rerun the detached test runner before treating that as a failure.
- On this Windows setup, Docker commands may require elevated access to the daemon. If a sandboxed run fails with named pipe or Docker config access errors, rerun with escalation instead of assuming the test setup is broken.
- Accessibility checks belong with integration tests, not static code-quality checks. They need a running web app, a real browser runtime, and interactive state setup.
- The accessibility runner should use a Playwright/Chromium-capable container and run a preflight that proves the player is actually loaded before `pa11y-ci` scans.
- Keep accessibility scenarios in one shared source (`test/accessibility-scenarios.js`) and generate the Pa11y config on the fly instead of maintaining a checked-in snapshot.
- Use `node test/accessibility-preflight.js --write-config=<output-path> --chrome-path=<chrome-path>` to validate the interactive states first and then write the runtime Pa11y config that matches the shared scenario source.
- For SPA accessibility coverage, have `pa11y-ci` actions click a real example flow and wait for `#player-section` to become visible before auditing the loaded player state.
- Every Pa11y scenario that defines `actions` should also have a matching Playwright preflight path. The preflight is only useful if it proves the same interactive states that Pa11y later audits.
- If the accessibility runner installs `pa11y-ci` dynamically, print `pa11y-ci --version` in the logs so the exact runtime version is visible during test runs.
- On this repo, the accessibility suite currently passes eight scenarios: `desktop-home`, `iphone15-home`, `iphone15-example-info`, `iphone15-example-playing`, `desktop-url-warning-empty`, `desktop-url-error-invalid`, `iphone15-queue-open`, and `desktop-queue-open`.
- Status coverage should be explicit in both layers for `info`, `success`, `warning`, and `error`.
- For queue accessibility coverage, prefer a deterministic preloaded `?queue=` URL over async UI setup inside `pa11y-ci` actions. That makes the scan start from a known queue state and avoids flaky waits on add-to-queue interactions.
- To verify the open-queue state in accessibility scans, trigger the explicit queue toggle and wait for the queue panel itself to become visible before auditing.

## Code quality lessons

- Keep Ruff configuration documented by reference, not by duplicating the active rule list in prose. `pyproject.toml` should remain the source of truth.
- When enabling stricter Ruff families such as `FBT`, `SLF`, and `ARG`, prefer code fixes over ignores.
- The repo's Ruff check should run both `ruff format --check` and `ruff check`, and the fix path should run both `ruff format` and `ruff check --fix`.
- PowerShell quality output is more usable when multi-file failures aggregate all offending tool output instead of only the last failing file.
- Root-level compose overrides are easy to miss when validation scripts only glob `test/docker-compose.*.yml`. If `docker-compose.dev.yml` is part of the supported workflow, include it explicitly in both host-side validation scripts and the quality-check container mounts.

## Development mode lessons

- Keep the base `docker-compose.yml` production-like. Development-only behavior such as hot reload should live in a separate `docker-compose.dev.yml` override instead of changing the default service command.
- In this repo, `FLASK_ENV` is descriptive and `FLASK_DEBUG` is the actual reload switch. Document them separately so future changes do not imply that `FLASK_ENV=development` alone enables hot reload.
- For the containerized dev path, bind-mount the whole `./web` directory read-write. That keeps HTML, CSS, and JavaScript changes visible on browser refresh without rebuilding the image.
- Python hot reload should be opt-in and dev-only. Gate Flask reload/debug mode on `FLASK_DEBUG=1` in `server.py` rather than enabling it unconditionally from `__main__`.
- Document the difference between static and backend reload behavior explicitly: HTML/CSS/JS updates are picked up from the bind mount on refresh, while Python updates require Flask's reloader.
- If dev mode becomes discoverable from the main compose file comments, keep the wording explicit that reload is enabled only through `docker-compose.dev.yml`, not in live or production deployments.

## Security scan lessons

- ZAP SQL injection findings on `/convert-url` were false positives caused by bad error classification, not evidence of a real SQL backend issue.
- Once `/convert-url` stopped surfacing hostile remote-fetch failures as `500`, the SQL injection findings disappeared in both quick and full ZAP scans.
- Remaining ZAP noise is mostly low-signal warnings like HTTP-only scanning context or suspicious comments, not active queue-related vulnerabilities.
- Remote cache LRU for `file`, `s3`, and `gcs` is more reliable with a `HASH.cache-access.json` sidecar than with backend mtime touch semantics.
- Sidecar access-record updates must tolerate concurrent writers. Deleting the previous access record can race under load, so `ENOENT` on replace/remove should be treated as expected and not logged as an error.
- Cache cleanup should remove orphaned `*.cache-access.json.*.tmp` files so failed or raced sidecar updates do not accumulate in the cache volume.
- FLAC-capable requests can legitimately arrive after a WAV cache entry already exists for the same module. The cache path should promote cached WAV to FLAC on demand instead of returning the wrong audio format.
- Under scanner-style concurrent load, cache health is better judged by leftover temp files and missing sidecars than by raw warning count in logs.
- After the sidecar hardening patch, a healthy post-scan cache check is no `*.tmp` files in `/tmp/cache` and every cached audio object has a matching `.cache-access.json`.
- `is_safe_url` can generate heavy log noise during DAST if expected hostile-input rejections and DNS lookup failures are logged as warnings with tracebacks. Keep those at `INFO` without `exc_info` unless they indicate an actual application fault.
