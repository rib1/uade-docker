#!/usr/bin/env node

import { execSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const scriptDir = dirname(fileURLToPath(import.meta.url));
const projectRoot = process.env.PROJECT_ROOT
  ? resolve(process.env.PROJECT_ROOT)
  : resolve(scriptDir, "..");
const configPath = resolve(projectRoot, "test", "purgecss.config.js");
const configDir = dirname(configPath);
const config = require(configPath);
const shouldFix = process.argv.includes("--fix");

function loadPurgeCSS() {
  try {
    return require("purgecss");
  } catch {
    try {
      const globalNodeModules = execSync("npm root -g", { encoding: "utf8" }).trim();
      return require(join(globalNodeModules, "purgecss"));
    } catch {
      console.error(
        "Unable to resolve 'purgecss'. Install test/package.json dependencies or install purgecss globally.",
      );
      process.exit(1);
      throw new Error("Unreachable after process exit");
    }
  }
}

const { PurgeCSS } = loadPurgeCSS();

const cssFiles = (config.css ?? []).map((file) => resolve(configDir, file));
const contentEntries = (config.content ?? []).map((entry) => {
  if (typeof entry === "string") {
    return resolve(configDir, entry);
  }
  return entry;
});
const safelist = config.safelist ?? [];

function isGlobPattern(path) {
  return /[*?[\]{}()!+@]/.test(path);
}

for (const file of cssFiles) {
  if (isGlobPattern(file)) {
    continue;
  }
  if (!existsSync(file)) {
    console.error(`Required PurgeCSS input not found: ${file}`);
    process.exit(1);
  }
}

for (const entry of contentEntries) {
  if (typeof entry !== "string") {
    continue;
  }
  if (isGlobPattern(entry)) {
    continue;
  }
  if (!existsSync(entry)) {
    console.error(`Required PurgeCSS input not found: ${entry}`);
    process.exit(1);
  }
}

if (cssFiles.length === 0 || contentEntries.length === 0) {
  console.error("purgecss.config.js must define at least one CSS file and one content file.");
  process.exit(1);
}

console.log("Running PurgeCSS against configured CSS and content files...");

async function main() {
  try {
    const purgeResults = await new PurgeCSS().purge({
      content: contentEntries,
      css: cssFiles,
      safelist,
      rejected: true,
    });

    const changedFiles = [];

    for (let index = 0; index < cssFiles.length; index += 1) {
      const cssFile = cssFiles[index];
      const purgeResult = purgeResults[index];
      if (!purgeResult || typeof purgeResult.css !== "string") {
        console.error(`Expected PurgeCSS result not found for: ${cssFile}`);
        process.exit(1);
      }

      const originalCss = readFileSync(cssFile, "utf8");
      const purgedCss = purgeResult.css;

      if (originalCss !== purgedCss) {
        changedFiles.push({
          cssFile,
          purgedCss,
          rejected: Array.isArray(purgeResult.rejected) ? purgeResult.rejected : [],
        });
      }
    }

    if (shouldFix) {
      for (const changedFile of changedFiles) {
        writeFileSync(changedFile.cssFile, changedFile.purgedCss, "utf8");
      }

      if (changedFiles.length > 0) {
        console.log(`Updated ${changedFiles.length} CSS file(s).`);
      } else {
        console.log("No CSS changes were needed.");
      }
    } else if (changedFiles.length > 0) {
      for (const changedFile of changedFiles) {
        if (changedFile.rejected.length > 0) {
          console.error(`Rejected selectors for ${changedFile.cssFile}:`);
          for (const selector of changedFile.rejected) {
            console.error(`- ${selector}`);
          }
        }
        console.error(`Would update: ${changedFile.cssFile}`);
      }
      console.error("\nUnused CSS selectors found.");
      process.exit(2);
    }

    if (!shouldFix) {
      console.log("No unused selectors found.");
    }
  } catch (error) {
    if (error.stdout) {
      console.error(String(error.stdout).trim());
    }
    if (error.stderr) {
      console.error(String(error.stderr).trim());
    }
    process.exit(error.status || 1);
  }
}

void main();
