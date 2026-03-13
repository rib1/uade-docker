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
    preflight: true,
    actions: buildExampleInfoActions(),
  },
  {
    label: "iphone15-example-playing",
    url: APP_URL,
    viewport: IPHONE_15_VIEWPORT,
    preflight: true,
    actions: buildExamplePlayingActions(),
  },
  {
    label: "desktop-url-warning-empty",
    url: APP_URL,
    preflight: true,
    actions: [
      `wait for element ${URL_SUBMIT_SELECTOR} to be visible`,
      `click element ${URL_SUBMIT_SELECTOR}`,
      `wait for element ${STATUS_EXPECTATIONS.warning.selector} to be added`,
      `wait for element ${STATUS_EXPECTATIONS.warning.selector} to be visible`,
    ],
  },
  {
    label: "desktop-url-error-invalid",
    url: APP_URL,
    preflight: true,
    actions: [
      `wait for element ${URL_INPUT_SELECTOR} to be visible`,
      `set field ${URL_INPUT_SELECTOR} to this-is-not-a-valid-url`,
      `click element ${URL_SUBMIT_SELECTOR}`,
      `wait for element ${STATUS_EXPECTATIONS.error.selector} to be added`,
      `wait for element ${STATUS_EXPECTATIONS.error.selector} to be visible`,
    ],
  },
  {
    label: "iphone15-queue-open",
    url: SHARED_QUEUE_URL,
    viewport: IPHONE_15_VIEWPORT,
    preflight: true,
    actions: buildQueueOpenActions(),
  },
  {
    label: "desktop-queue-open",
    url: SHARED_QUEUE_URL,
    preflight: true,
    actions: buildQueueOpenActions(),
  },
];

const preflightScenarioLabels = accessibilityScenarios
  .filter((scenario) => scenario.actions)
  .map((scenario) => scenario.label);

function getScenario(label) {
  const scenario = accessibilityScenarios.find((entry) => entry.label === label);
  if (!scenario) {
    throw new Error(`Unknown accessibility scenario: ${label}`);
  }
  return scenario;
}

function validateAccessibilityScenarioCoverage() {
  const missingPreflight = accessibilityScenarios
    .filter((scenario) => scenario.actions && !scenario.preflight)
    .map((scenario) => scenario.label);

  if (missingPreflight.length > 0) {
    throw new Error(
      "Every Pa11y scenario with actions must opt into Playwright preflight. " +
      `Missing preflight coverage for: ${missingPreflight.join(", ")}`
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
  preflightScenarioLabels,
  getScenario,
  buildPa11yConfig,
  validateAccessibilityScenarioCoverage,
};
