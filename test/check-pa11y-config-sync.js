const fs = require("fs");

const {
  buildPa11yConfig,
  validateAccessibilityScenarioCoverage,
} = require("./accessibility-scenarios");

const checkedInPath = process.argv[2] || "test/pa11yci.json";
validateAccessibilityScenarioCoverage();
const expected = `${JSON.stringify(buildPa11yConfig(), null, 2)}\n`;
const actual = fs.readFileSync(checkedInPath, "utf8");

if (actual !== expected) {
  console.error(
    `ERROR: ${checkedInPath} is out of sync with test/accessibility-scenarios.js.`
  );
  console.error(
    "Run `node test/generate-pa11y-config.js` to regenerate the checked-in snapshot."
  );
  process.exit(1);
}

console.log(`Pa11y config snapshot is in sync: ${checkedInPath}`);
