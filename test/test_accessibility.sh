#!/bin/bash

set -euo pipefail

echo "--- Running accessibility test with Pa11y CI ---"

export NPM_CONFIG_PREFIX="${HOME}/.npm-global"
export PATH="${NPM_CONFIG_PREFIX}/bin:${PATH}"
export NODE_PATH="${NPM_CONFIG_PREFIX}/lib/node_modules"

PA11Y_CI_VERSION="$(node -p 'require("/workspace/test/package.json").devDependencies["pa11y-ci"]')"
PLAYWRIGHT_VERSION="1.51.1"
CHROME_PATH="$(find /ms-playwright -path '*/chrome-linux/chrome' -type f | head -n 1)"

if [ -z "${CHROME_PATH}" ]; then
    echo "ERROR: Could not find Chromium in the Playwright image." >&2
    exit 1
fi

echo "Using Chromium at: ${CHROME_PATH}"

# Run a Playwright preflight first so we can verify the async UI flows and
# computed status colors deterministically before handing the page to Pa11y.
echo "Verifying example playback flow before accessibility scan..."
npm install -g "playwright-core@${PLAYWRIGHT_VERSION}" >/dev/null
export CHROME_PATH
node /workspace/test/accessibility-preflight.js

# Pa11y remains the actual accessibility audit step. It scans the page after
# the shared scenarios have proven the app can reach those states reliably.
npm install -g "pa11y-ci@${PA11Y_CI_VERSION}" >/dev/null
echo "Using Pa11y CI version: $(pa11y-ci --version)"

# Build the Pa11y config on the fly from test/accessibility-scenarios.js and
# inject the runtime Chromium path so the container does not rely on a
# checked-in JSON snapshot.
node /workspace/test/generate-pa11y-config.js /tmp/pa11yci.json "${CHROME_PATH}"

pa11y-ci --config /tmp/pa11yci.json
