const { chromium, devices } = require("playwright-core");

const {
  DEFAULT_TIMEOUT_MS,
  EXAMPLE_PLAY_BUTTON_SELECTOR,
  URL_INPUT_SELECTOR,
  URL_SUBMIT_SELECTOR,
  PLAYLIST_LAUNCHER_SELECTOR,
  PLAYLIST_TOGGLE_BUTTON_SELECTOR,
  PLAYLIST_PANEL_SELECTOR,
  STATUS_EXPECTATIONS,
  getScenario,
  preflightScenarioLabels,
  validateAccessibilityScenarioCoverage,
} = require("./accessibility-scenarios");

async function expectStatusColors(page, selector, expectedBackground, expectedText) {
  const status = page.locator(selector).last();
  const styles = await status.evaluate((element) => {
    const computed = window.getComputedStyle(element);
    return {
      backgroundColor: computed.backgroundColor,
      color: computed.color,
    };
  });

  if (
    styles.backgroundColor !== expectedBackground ||
    styles.color !== expectedText
  ) {
    throw new Error(
      `${selector} colors mismatch. ` +
      `Expected background ${expectedBackground} and text ${expectedText}, got ` +
      `${styles.backgroundColor} and ${styles.color}.`
    );
  }
}

async function verifyStatusState(browser, scenarioLabel) {
  const scenario = getScenario(scenarioLabel);
  const context = scenario.viewport
    ? await browser.newContext(devices["iPhone 15"])
    : await browser.newContext();
  const page = await context.newPage();

  try {
    await page.goto(scenario.url, { waitUntil: "networkidle" });
    if (scenario.label === "desktop-url-warning-empty") {
      const expected = STATUS_EXPECTATIONS.warning;
      await page.waitForSelector(URL_SUBMIT_SELECTOR, { state: "visible" });
      await page.click(URL_SUBMIT_SELECTOR);
      await page.waitForSelector(expected.selector, { state: "visible" });
      await expectStatusColors(
        page,
        expected.selector,
        expected.backgroundColor,
        expected.textColor
      );
      return;
    }

    if (scenario.label === "desktop-url-error-invalid") {
      const expected = STATUS_EXPECTATIONS.error;
      await page.waitForSelector(URL_INPUT_SELECTOR, { state: "visible" });
      await page.fill(URL_INPUT_SELECTOR, "this-is-not-a-valid-url");
      await page.click(URL_SUBMIT_SELECTOR);
      await page.waitForSelector(expected.selector, {
        state: "visible",
        timeout: DEFAULT_TIMEOUT_MS,
      });
      await expectStatusColors(
        page,
        expected.selector,
        expected.backgroundColor,
        expected.textColor
      );
      return;
    }

    if (scenario.label === "iphone15-example-info") {
      const infoStatus = STATUS_EXPECTATIONS.info;

      await page.waitForSelector(EXAMPLE_PLAY_BUTTON_SELECTOR, { state: "visible" });
      await page.click(EXAMPLE_PLAY_BUTTON_SELECTOR);
      await page.waitForSelector(infoStatus.selector, {
        state: "visible",
        timeout: DEFAULT_TIMEOUT_MS,
      });
      await expectStatusColors(
        page,
        infoStatus.selector,
        infoStatus.backgroundColor,
        infoStatus.textColor
      );
      return;
    }

    if (scenario.label === "iphone15-example-playing") {
      const infoStatus = STATUS_EXPECTATIONS.info;
      const successStatus = STATUS_EXPECTATIONS.success;

      await page.waitForSelector(EXAMPLE_PLAY_BUTTON_SELECTOR, { state: "visible" });
      await page.click(EXAMPLE_PLAY_BUTTON_SELECTOR);
      await page.waitForSelector(infoStatus.selector, {
        state: "visible",
        timeout: DEFAULT_TIMEOUT_MS,
      });
      await expectStatusColors(
        page,
        infoStatus.selector,
        infoStatus.backgroundColor,
        infoStatus.textColor
      );
      await page.waitForSelector(successStatus.selector, {
        state: "visible",
        timeout: DEFAULT_TIMEOUT_MS,
      });
      await expectStatusColors(
        page,
        successStatus.selector,
        successStatus.backgroundColor,
        successStatus.textColor
      );

      const deadline = Date.now() + DEFAULT_TIMEOUT_MS;
      while (Date.now() < deadline) {
        const trackText = await page.locator("#current-track").textContent();
        const downloadEnabled = await page.locator("#download-btn").isEnabled();
        if (
          trackText &&
          trackText.trim() !== "" &&
          trackText.trim() !== "No track loaded" &&
          downloadEnabled
        ) {
          return;
        }
        await page.waitForTimeout(500);
      }

      throw new Error("Player did not reach a loaded, interactive state after clicking an example.");
    }

    if (scenario.label === "iphone15-queue-open" || scenario.label === "desktop-queue-open") {
      await page.waitForSelector(PLAYLIST_LAUNCHER_SELECTOR, {
        state: "visible",
        timeout: DEFAULT_TIMEOUT_MS,
      });
      await page.click(PLAYLIST_TOGGLE_BUTTON_SELECTOR);
      await page.waitForSelector(PLAYLIST_PANEL_SELECTOR, {
        state: "visible",
        timeout: DEFAULT_TIMEOUT_MS,
      });
      return;
    }

    throw new Error(`No preflight handler for accessibility scenario: ${scenario.label}`);
  } finally {
    await context.close();
  }
}

async function main() {
  // This preflight complements Pa11y rather than replacing it. We use
  // Playwright here to prove the async UI can actually reach the intended
  // states and to assert computed status colors, then Pa11y performs WCAG
  // auditing against the corresponding scenarios.
  validateAccessibilityScenarioCoverage();
  const browser = await chromium.launch({
    executablePath: process.env.CHROME_PATH,
    headless: true,
    args: ["--no-sandbox", "--disable-setuid-sandbox"],
  });

  try {
    for (const label of preflightScenarioLabels) {
      await verifyStatusState(browser, label);
    }
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  console.error("ERROR: Example playback preflight failed.");
  console.error(error);
  process.exit(1);
});
