const fs = require("fs");
const { chromium, devices } = require("playwright-core");

const {
  accessibilityScenarios,
  buildPa11yConfig,
  validateAccessibilityScenarios,
} = require("./accessibility-scenarios");

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
    for (const scenario of accessibilityScenarios) {
      if (!scenario.preflight) continue;

      console.log(`Running preflight for: ${scenario.label}`);
      const context = scenario.viewport
        ? await browser.newContext(devices["iPhone 15"])
        : await browser.newContext();
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

  // 2. Generate Pa11y Config (optional)
  if (writeConfigPath) {
    const config = buildPa11yConfig();
    if (chromePath) {
      config.defaults = config.defaults || {};
      config.defaults.chromeLaunchConfig = {
        executablePath: chromePath,
        args: ["--no-sandbox", "--disable-setuid-sandbox"],
      };
    }
    fs.writeFileSync(writeConfigPath, `${JSON.stringify(config, null, 2)}\n`);
    console.log(`Pa11y configuration written to: ${writeConfigPath}`);
  }
}

main().catch((error) => {
  console.error("ERROR: Accessibility preflight failed.");
  console.error(error);
  process.exit(1);
});
