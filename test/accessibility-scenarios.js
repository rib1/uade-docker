const APP_URL = "http://uade-web:5000";
const DEFAULT_TIMEOUT_MS = 120000;

const IPHONE_15_VIEWPORT = {
  width: 393,
  height: 852,
  deviceScaleFactor: 3,
  isMobile: true,
  hasTouch: true,
};

const SHARED_QUEUE_URL =
  `${APP_URL}?queue=` +
  "eyJ2IjoxLCJ0IjpbeyJuIjoiQ2FwdGFpbiAtIFNwYWNlIERlYnJpcyIsInUiOiJodHRwczovL21vZGxhbmQuY29tL3B1Yi9tb2R1bGVzL1Byb3RyYWNrZXIvQ2FwdGFpbi9zcGFjZSUyMGRlYnJpcy5tb2QiLCJzIjpudWxsLCJmIjoiUHJvdHJhY2tlciIsIm8iOiJleGFtcGxlIn1dfQ";

const EXAMPLE_PLAY_BUTTON_SELECTOR = ".example-card .play-btn[data-example-id]";
const PLAYER_SECTION_SELECTOR = "#player-section";
const URL_INPUT_SELECTOR = "#url-input";
const URL_SUBMIT_SELECTOR = "#url-submit";
const PLAYLIST_LAUNCHER_SELECTOR = "#playlist-launcher";
const PLAYLIST_TOGGLE_BUTTON_SELECTOR = "#playlist-toggle-btn";
const PLAYLIST_PANEL_SELECTOR = "#playlist-panel";

const STATUS_EXPECTATIONS = {
  info: {
    selector: "#status-container .status-info",
    backgroundColor: "rgb(0, 130, 151)",
    textColor: "rgb(255, 255, 255)",
  },
  success: {
    selector: "#status-container .status-success",
    backgroundColor: "rgb(10, 137, 39)",
    textColor: "rgb(255, 255, 255)",
  },
  warning: {
    selector: "#status-container .status-warning",
    backgroundColor: "rgb(255, 193, 7)",
    textColor: "rgb(0, 0, 0)",
  },
  error: {
    selector: "#status-container .status-error",
    backgroundColor: "rgb(220, 53, 69)",
    textColor: "rgb(255, 255, 255)",
  },
};

/**
 * Shared Playwright preflight helper to assert computed status colors.
 */
async function expectStatus(page, type) {
  const expected = STATUS_EXPECTATIONS[type];
  const status = page.locator(expected.selector).last();
  await status.waitFor({ state: "visible", timeout: DEFAULT_TIMEOUT_MS });

  const styles = await status.evaluate((element) => {
    const computed = window.getComputedStyle(element);
    return {
      backgroundColor: computed.backgroundColor,
      color: computed.color,
    };
  });

  if (
    styles.backgroundColor !== expected.backgroundColor ||
    styles.color !== expected.textColor
  ) {
    throw new Error(
      `${expected.selector} colors mismatch for ${type}. ` +
      `Expected background ${expected.backgroundColor} and text ${expected.textColor}, got ` +
      `${styles.backgroundColor} and ${styles.color}.`
    );
  }
}

function buildExampleInfoActions() {
  return [
    `wait for element ${EXAMPLE_PLAY_BUTTON_SELECTOR} to be visible`,
    `click element ${EXAMPLE_PLAY_BUTTON_SELECTOR}`,
    `wait for element ${STATUS_EXPECTATIONS.info.selector} to be added`,
    `wait for element ${STATUS_EXPECTATIONS.info.selector} to be visible`,
  ];
}

function buildExamplePlayingActions() {
  return [
    `wait for element ${EXAMPLE_PLAY_BUTTON_SELECTOR} to be visible`,
    `click element ${EXAMPLE_PLAY_BUTTON_SELECTOR}`,
    `wait for element ${PLAYER_SECTION_SELECTOR} to be visible`,
    `wait for element ${STATUS_EXPECTATIONS.success.selector} to be added`,
    `wait for element ${STATUS_EXPECTATIONS.success.selector} to be visible`,
  ];
}

function buildQueueOpenActions() {
  return [
    `wait for element ${PLAYLIST_LAUNCHER_SELECTOR} to be visible`,
    `click element ${PLAYLIST_TOGGLE_BUTTON_SELECTOR}`,
    `wait for element ${PLAYLIST_PANEL_SELECTOR} to be visible`,
  ];
}

const accessibilityScenarios = [
  {
    label: "desktop-home",
    url: APP_URL,
  },
  {
    label: "iphone15-home",
    url: APP_URL,
    viewport: IPHONE_15_VIEWPORT,
  },
  {
    label: "iphone15-example-info",
    url: APP_URL,
    viewport: IPHONE_15_VIEWPORT,
    actions: buildExampleInfoActions(),
    async preflight(page) {
      await page.waitForSelector(EXAMPLE_PLAY_BUTTON_SELECTOR, { state: "visible" });
      await page.click(EXAMPLE_PLAY_BUTTON_SELECTOR);
      await expectStatus(page, "info");
    },
  },
  {
    label: "iphone15-example-playing",
    url: APP_URL,
    viewport: IPHONE_15_VIEWPORT,
    actions: buildExamplePlayingActions(),
    async preflight(page) {
      await page.waitForSelector(EXAMPLE_PLAY_BUTTON_SELECTOR, { state: "visible" });
      await page.click(EXAMPLE_PLAY_BUTTON_SELECTOR);
      await expectStatus(page, "info");
      await expectStatus(page, "success");

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
    },
  },
  {
    label: "desktop-url-warning-empty",
    url: APP_URL,
    actions: [
      `wait for element ${URL_SUBMIT_SELECTOR} to be visible`,
      `click element ${URL_SUBMIT_SELECTOR}`,
      `wait for element ${STATUS_EXPECTATIONS.warning.selector} to be added`,
      `wait for element ${STATUS_EXPECTATIONS.warning.selector} to be visible`,
    ],
    async preflight(page) {
      await page.waitForSelector(URL_SUBMIT_SELECTOR, { state: "visible" });
      await page.click(URL_SUBMIT_SELECTOR);
      await expectStatus(page, "warning");
    },
  },
  {
    label: "desktop-url-error-invalid",
    url: APP_URL,
    actions: [
      `wait for element ${URL_INPUT_SELECTOR} to be visible`,
      `set field ${URL_INPUT_SELECTOR} to this-is-not-a-valid-url`,
      `click element ${URL_SUBMIT_SELECTOR}`,
      `wait for element ${STATUS_EXPECTATIONS.error.selector} to be added`,
      `wait for element ${STATUS_EXPECTATIONS.error.selector} to be visible`,
    ],
    async preflight(page) {
      await page.waitForSelector(URL_INPUT_SELECTOR, { state: "visible" });
      await page.fill(URL_INPUT_SELECTOR, "this-is-not-a-valid-url");
      await page.click(URL_SUBMIT_SELECTOR);
      await expectStatus(page, "error");
    },
  },
  {
    label: "iphone15-queue-open",
    url: SHARED_QUEUE_URL,
    viewport: IPHONE_15_VIEWPORT,
    actions: buildQueueOpenActions(),
    async preflight(page) {
      await page.waitForSelector(PLAYLIST_LAUNCHER_SELECTOR, {
        state: "visible",
        timeout: DEFAULT_TIMEOUT_MS,
      });
      await page.click(PLAYLIST_TOGGLE_BUTTON_SELECTOR);
      await page.waitForSelector(PLAYLIST_PANEL_SELECTOR, {
        state: "visible",
        timeout: DEFAULT_TIMEOUT_MS,
      });
    },
  },
  {
    label: "desktop-queue-open",
    url: SHARED_QUEUE_URL,
    actions: buildQueueOpenActions(),
    async preflight(page) {
      await page.waitForSelector(PLAYLIST_LAUNCHER_SELECTOR, {
        state: "visible",
        timeout: DEFAULT_TIMEOUT_MS,
      });
      await page.click(PLAYLIST_TOGGLE_BUTTON_SELECTOR);
      await page.waitForSelector(PLAYLIST_PANEL_SELECTOR, {
        state: "visible",
        timeout: DEFAULT_TIMEOUT_MS,
      });
    },
  },
];

function validateAccessibilityScenarios() {
  const missingPreflight = accessibilityScenarios
    .filter((scenario) => scenario.actions && typeof scenario.preflight !== "function")
    .map((scenario) => scenario.label);
  const missingActions = accessibilityScenarios
    .filter((scenario) => typeof scenario.preflight === "function" && !scenario.actions)
    .map((scenario) => scenario.label);

  if (missingPreflight.length > 0) {
    throw new Error(
      "Every Pa11y scenario with actions must define a matching preflight function. " +
      `Missing preflight for: ${missingPreflight.join(", ")}`
    );
  }

  if (missingActions.length > 0) {
    throw new Error(
      "Every accessibility preflight scenario must define matching Pa11y actions. " +
      `Missing actions for: ${missingActions.join(", ")}`
    );
  }
}

function buildPa11yConfig() {
  return {
    concurrency: 1,
    urls: accessibilityScenarios.map(({ label, url, viewport, actions }) => {
      const entry = { url, label };
      if (viewport) {
        entry.viewport = viewport;
      }
      if (actions) {
        entry.actions = actions;
      }
      return entry;
    }),
    defaults: {
      hideElements: "#version-info",
      standard: "WCAG2AA",
      timeout: DEFAULT_TIMEOUT_MS,
    },
  };
}

module.exports = {
  APP_URL,
  DEFAULT_TIMEOUT_MS,
  IPHONE_15_VIEWPORT,
  EXAMPLE_PLAY_BUTTON_SELECTOR,
  PLAYER_SECTION_SELECTOR,
  URL_INPUT_SELECTOR,
  URL_SUBMIT_SELECTOR,
  PLAYLIST_LAUNCHER_SELECTOR,
  PLAYLIST_TOGGLE_BUTTON_SELECTOR,
  PLAYLIST_PANEL_SELECTOR,
  STATUS_EXPECTATIONS,
  accessibilityScenarios,
  buildPa11yConfig,
  validateAccessibilityScenarios,
};
