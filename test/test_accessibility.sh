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

echo "Verifying example playback flow before accessibility scan..."
npm install -g "playwright-core@${PLAYWRIGHT_VERSION}" >/dev/null
export CHROME_PATH
node <<'EOF'
const { chromium, devices } = require('playwright-core');

(async () => {
  const browser = await chromium.launch({
    executablePath: process.env.CHROME_PATH,
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });
  const context = await browser.newContext(devices['iPhone 15']);
  const page = await context.newPage();

  try {
    await page.goto('http://uade-web:5000', { waitUntil: 'networkidle' });
    await page.waitForSelector('.example-card .play-btn[data-example-id]', { state: 'visible' });
    await page.click('.example-card .play-btn[data-example-id]');
    await page.waitForSelector('#status-container .status-success', { state: 'visible', timeout: 120000 });

    const deadline = Date.now() + 120000;
    while (Date.now() < deadline) {
      const trackText = await page.locator('#current-track').textContent();
      const downloadEnabled = await page.locator('#download-btn').isEnabled();
      if (
        trackText &&
        trackText.trim() !== '' &&
        trackText.trim() !== 'No track loaded' &&
        downloadEnabled
      ) {
        break;
      }
      await page.waitForTimeout(500);
    }

    const finalTrackText = await page.locator('#current-track').textContent();
    const finalDownloadEnabled = await page.locator('#download-btn').isEnabled();
    if (
      !finalTrackText ||
      finalTrackText.trim() === '' ||
      finalTrackText.trim() === 'No track loaded' ||
      !finalDownloadEnabled
    ) {
      throw new Error('Player did not reach a loaded, interactive state after clicking an example.');
    }
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error('ERROR: Example playback preflight failed.');
  console.error(error);
  process.exit(1);
});
EOF

npm install -g "pa11y-ci@${PA11Y_CI_VERSION}" >/dev/null
echo "Using Pa11y CI version: $(pa11y-ci --version)"

node -e '
const fs = require("fs");
const configPath = "/workspace/test/pa11yci.json";
const outPath = "/tmp/pa11yci.json";
const cfg = JSON.parse(fs.readFileSync(configPath, "utf8"));
cfg.defaults = cfg.defaults || {};
cfg.defaults.chromeLaunchConfig = {
  executablePath: process.argv[1],
  args: ["--no-sandbox", "--disable-setuid-sandbox"]
};
fs.writeFileSync(outPath, JSON.stringify(cfg, null, 2));
' "${CHROME_PATH}"

pa11y-ci --config /tmp/pa11yci.json
