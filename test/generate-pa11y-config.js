const fs = require("fs");

const { buildPa11yConfig } = require("./accessibility-scenarios");

const outputPath = process.argv[2] || "test/pa11yci.json";

fs.writeFileSync(outputPath, `${JSON.stringify(buildPa11yConfig(), null, 2)}\n`);
