#!/bin/bash

set -euo pipefail

echo "--- Running accessibility test with Pa11y CI ---"

export NPM_CONFIG_PREFIX="${HOME}/.npm-global"
export PATH="${NPM_CONFIG_PREFIX}/bin:${PATH}"
export NODE_PATH="${NPM_CONFIG_PREFIX}/lib/node_modules"

PA11Y_CI_VERSION="$(node -p 'require("/workspace/test/package.json").devDependencies["pa11y-ci"]')"
PLAYWRIGHT_VERSION="$(node -p 'require("/workspace/test/package.json").devDependencies["playwright-core"]')"
PLAYWRIGHT_IMAGE_TAG="$(sed -n '/^  playwright:$/,/^  [^ ]/s/^    image: mcr\.microsoft\.com\/playwright:v\([^-[:space:]]*\)-.*$/\1/p' /workspace/test/docker-compose.tooling.yml)"
CHROME_PATH="$(
    find /ms-playwright \( -path '*/chrome-linux/chrome' -o -path '*/chrome-linux64/chrome' \) -type f | head -n 1
)"

if [ -z "${CHROME_PATH}" ]; then
    echo "ERROR: Could not find Chromium in the Playwright image." >&2
    exit 1
fi

if [ -z "${PLAYWRIGHT_IMAGE_TAG}" ]; then
    echo "ERROR: Could not read Playwright image tag from test/docker-compose.tooling.yml." >&2
    exit 1
fi

if [ "${PLAYWRIGHT_VERSION}" != "${PLAYWRIGHT_IMAGE_TAG}" ]; then
    echo "ERROR: Playwright version mismatch." >&2
    echo "  test/package.json playwright-core: ${PLAYWRIGHT_VERSION}" >&2
    echo "  test/docker-compose.tooling.yml image tag: ${PLAYWRIGHT_IMAGE_TAG}" >&2
    exit 1
fi

echo "Using Chromium at: ${CHROME_PATH}"
echo "Using Playwright version: ${PLAYWRIGHT_VERSION}"

# Run Playwright preflight and generate Pa11y config in one pass.
# This ensures async UI states and status colors are verified before auditing.
echo "Verifying UI states and generating Pa11y config..."
npm install -g "playwright-core@${PLAYWRIGHT_VERSION}" >/dev/null
node /workspace/test/accessibility-preflight.js \
    --write-config=/tmp/pa11yci.json \
    --chrome-path="${CHROME_PATH}"

# Run Pa11y CI audit against the generated configuration.
npm install -g "pa11y-ci@${PA11Y_CI_VERSION}" >/dev/null
echo "Using Pa11y CI version: $(pa11y-ci --version)"

pa11y-ci --config /tmp/pa11yci.json
