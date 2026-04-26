const frontendEntries = ["../web/static/app.js"];

const toolingEntries = [
  "./accessibility-preflight.js",
  "./bench/conversion.js",
  "./bench/cache.js",
  "./bench/cross-instance-scaleout.js",
  "./bench/dast-patterns.js",
  "./bench/semaphore-balance.js",
  "./bench/smoke.js",
  "./bench/streaming.js",
  "./check-documentation.mjs",
  "./check-instructions.mjs",
  "./check-python-version-sync.mjs",
  "./check-purgecss.mjs",
  "./check-playwright-version-sync.mjs",
];

const frontendProjectFiles = ["../web/static/**/*.js"];

const toolingProjectFiles = ["./**/*.js", "./**/*.mjs"];

module.exports = {
  entry: [...frontendEntries, ...toolingEntries],
  project: [...frontendProjectFiles, ...toolingProjectFiles],
  ignore: [
    "../web/static/eslint.config.js",
    "./bench/conversion.js",
    "./bench/cache.js",
    "./bench/cross-instance-scaleout.js",
    "./bench/dast-patterns.js",
    "./bench/semaphore-balance.js",
    "./bench/smoke.js",
    "./bench/streaming.js",
    // Loaded via a dynamic require(configPath) in check-purgecss.mjs.
    "./purgecss.config.js",
  ],
  // These tools are invoked from shell scripts and Docker workflows rather than
  // imported from JavaScript, so they would be false positives in Knip.
  ignoreDependencies: [
    "eslint",
    "stylelint",
    "htmlhint",
    "pa11y-ci",
  ],
};
