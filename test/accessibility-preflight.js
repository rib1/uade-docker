const fs = require("fs");
const { chromium, devices } = require("playwright-core");
const verifyMediaSessionNavigation = require("./media-session-preflight");

const {
  accessibilityScenarios,
  buildPa11yConfig,
  validateAccessibilityScenarios,
} = require("./accessibility-scenarios");

async function verifyMotionAndStatusAnnouncements(browser) {
  for (const reducedMotion of ["reduce", "no-preference"]) {
    console.log(`Checking motion and status announcements: ${reducedMotion}`);
    const context = await browser.newContext({ reducedMotion });
    try {
      const page = await context.newPage();
      await page.goto(accessibilityScenarios[0].url, { waitUntil: "networkidle" });
      await page.hover(".url-form");
      await page.waitForFunction((preference) => {
        const form = window.document.querySelector(".url-form");
        const transform = window.getComputedStyle(form).transform;
        return preference === "reduce" ? transform === "none" : transform !== "none";
      }, reducedMotion, { timeout: 5000 });
      await page.evaluate((preference) => {
        const region = window.document.getElementById("status-container");
        if (
          region.getAttribute("role") !== "status" ||
          region.getAttribute("aria-live") !== "polite" ||
          region.getAttribute("aria-atomic") !== "false" ||
          region.getAttribute("aria-relevant") !== "additions text"
        ) {
          throw new Error("Status region must announce added and updated messages politely.");
        }
        const button = window.document.getElementById("url-submit");
        button.focus();
        const status = window.showStatus("Converting module...", "info");
        window.setButtonLoadingState(button, "Converting...");
        const statusStyles = window.getComputedStyle(status);
        const spinnerStyles = window.getComputedStyle(button.querySelector(".loading"));
        const expectedStatus = preference === "reduce" ? "none" : "slideIn";
        const expectedSpinner = preference === "reduce" ? "none" : "spin";
        if (
          statusStyles.animationName !== expectedStatus ||
          spinnerStyles.animationName !== expectedSpinner ||
          statusStyles.visibility !== "visible" ||
          (preference === "reduce" && statusStyles.opacity !== "1")
        ) {
          throw new Error(`Status and loader motion must respect ${preference}.`);
        }
        window.updateStatusMessage(status, "Conversion complete", "success");
        if (
          !region.contains(status) || status.textContent !== "Conversion complete" ||
          window.document.activeElement !== button
        ) {
          throw new Error("Status updates must remain in the live region without moving focus.");
        }
        const dropZone = window.document.querySelector(".drop-zone");
        dropZone.classList.add("drag-over");
        if (preference === "reduce" && window.getComputedStyle(dropZone).transform !== "none") {
          throw new Error("Drop feedback must respect reduced motion.");
        }
        const scrolls = [];
        window.Element.prototype.scrollIntoView = function (options) {
          scrolls.push({ id: this.id, ...options });
        };
        window.history.replaceState({}, "", "?url=https://example.com/test.mod");
        window.handleUrlConvert = () => {};
        window.checkSharedUrlParameter();
        const audioUrl = "data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQAAAAA=";
        window.document.getElementById("audio-player").play = () => Promise.resolve();
        window.playFile("motion-test", "Motion test", audioUrl, audioUrl);
        const behavior = preference === "reduce" ? "instant" : "smooth";
        if (
          scrolls.length !== 2 || scrolls[0].id !== "url-input" ||
          scrolls[1].id !== "player-section" || scrolls.some((scroll) => scroll.behavior !== behavior)
        ) {
          throw new Error(`Shared URL and player scrolling must respect ${preference}.`);
        }
      }, reducedMotion);
    } finally {
      await context.close();
    }
  }
}

async function verifyAutoplayKeyboardActivation(browser) {
  const context = await browser.newContext();
  try {
    const page = await context.newPage();
    await page.goto(accessibilityScenarios[0].url, { waitUntil: "networkidle" });
    await page.evaluate(() => {
      window.document.getElementById("player-content").hidden = false;
      const audio = window.document.getElementById("audio-player");
      audio.src = "data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQAAAAA=";
      window.autoplayTestCalls = 0;
      audio.play = () => {
        window.autoplayTestCalls += 1;
        return Promise.resolve();
      };
    });
    for (const key of ["Enter", "Space"]) {
      console.log(`Checking autoplay recovery with ${key}`);
      await page.evaluate(() => {
        const overlay = window.document.getElementById("autoplay-overlay");
        if (overlay.tagName !== "BUTTON" || overlay.type !== "button") {
          throw new Error("Autoplay recovery must use a native button.");
        }
        overlay.style.display = "flex";
        overlay.style.pointerEvents = "auto";
      });
      const playButton = page.getByRole("button", { name: "Play", exact: true });
      await playButton.focus();
      await playButton.press(key);
      await page.waitForFunction((expectedCalls) => {
        const overlay = window.document.getElementById("autoplay-overlay");
        return window.autoplayTestCalls === expectedCalls &&
          overlay.style.display === "none" &&
          overlay.style.pointerEvents === "none" &&
          window.document.activeElement === window.document.getElementById("audio-player");
      }, key === "Enter" ? 1 : 2, { timeout: 5000 });
    }
  } finally {
    await context.close();
  }
}

async function verifyUrlKeyboardSubmission(browser) {
  const context = await browser.newContext();
  try {
    const page = await context.newPage();
    await page.goto(accessibilityScenarios[0].url, { waitUntil: "networkidle" });
    await page.evaluate(() => {
      window.document.querySelector(".sample-url-details").open = true;
      window.handleUrlConvert = () => { window.urlConversionCalls += 1; };
    });
    for (const selector of ["#url-input", "#sample-url-input"]) {
      console.log(`Checking Enter submission and IME composition: ${selector}`);
      await page.evaluate(() => { window.urlConversionCalls = 0; });
      const input = page.locator(selector);
      await input.press("a");
      await input.dispatchEvent("keydown", { key: "Enter", isComposing: true });
      if (await page.evaluate(() => window.urlConversionCalls) !== 0) {
        throw new Error("Typing and IME composition must not submit a conversion.");
      }
      await input.press("Enter");
      await page.waitForFunction(() => window.urlConversionCalls === 1, null, { timeout: 5000 });
    }
  } finally {
    await context.close();
  }
}

async function main() {
  const args = process.argv.slice(2);
  const writeConfigPath = args.find((arg) => arg.startsWith("--write-config="))?.split("=")[1];
  const chromePath = args.find((arg) => arg.startsWith("--chrome-path="))?.split("=")[1];

  validateAccessibilityScenarios();

  // 1. Run Playwright Preflight
  // This verifies that the UI actually reaches the intended states and
  // asserts computed status colors before Pa11y performs WCAG auditing.
  const browser = await chromium.launch({
    executablePath: chromePath || process.env.CHROME_PATH,
    headless: true,
    args: ["--no-sandbox", "--disable-setuid-sandbox"],
  });

  try {
    await verifyMediaSessionNavigation(browser, accessibilityScenarios[0].url);
    await verifyMotionAndStatusAnnouncements(browser);
    await verifyAutoplayKeyboardActivation(browser);
    await verifyUrlKeyboardSubmission(browser);
    for (const scenario of accessibilityScenarios) {
      if (!scenario.preflight) {
        continue;
      }

      console.log(`Running preflight for: ${scenario.label}`);
      const context = scenario.viewport
        ? await browser.newContext({ ...devices["iPhone 15"], reducedMotion: scenario.reducedMotion })
        : await browser.newContext({ reducedMotion: scenario.reducedMotion });
      const page = await context.newPage();

      try {
        await page.goto(scenario.url, { waitUntil: "networkidle" });
        await scenario.preflight(page);
      } finally {
        await context.close();
      }
    }
  } finally {
    await browser.close();
  }

  // 2. Verify native browser preferences and generate separate Pa11y configs (optional).
  if (writeConfigPath) {
    for (const preference of ["no-preference", "reduce"]) {
      const config = buildPa11yConfig(chromePath, preference);
      const auditBrowser = await chromium.launch(config.defaults.chromeLaunchConfig);
      try {
        // Clear Playwright's media override so this checks Chromium's launch flags.
        const page = await auditBrowser.newPage({ reducedMotion: null });
        const prefersReducedMotion = await page.evaluate(() =>
          window.matchMedia("(prefers-reduced-motion: reduce)").matches,
        );
        if (prefersReducedMotion !== (preference === "reduce")) {
          throw new Error(`Pa11y browser launch must apply ${preference}.`);
        }
      } finally {
        await auditBrowser.close();
      }
      const configPath = `${writeConfigPath}-${preference}.json`;
      fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`);
      console.log(`Verified ${preference} browser; Pa11y configuration written to: ${configPath}`);
    }
  }
}

main().catch((error) => {
  console.error("ERROR: Accessibility preflight failed.");
  console.error(error);
  process.exit(1);
});
