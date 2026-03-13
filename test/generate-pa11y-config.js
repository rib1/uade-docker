const fs = require("fs");

const { buildPa11yConfig } = require("./accessibility-scenarios");

const outputPath = process.argv[2] || "pa11yci.json";
const chromeExecutablePath = process.argv[3];

const config = buildPa11yConfig();

if (chromeExecutablePath) {
  config.defaults = config.defaults || {};
  config.defaults.chromeLaunchConfig = {
    executablePath: chromeExecutablePath,
    args: ["--no-sandbox", "--disable-setuid-sandbox"],
  };
}

fs.writeFileSync(outputPath, `${JSON.stringify(config, null, 2)}\n`);
