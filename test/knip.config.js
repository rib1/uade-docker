const frontendEntries = ["../web/static/app.js"];

const toolingEntries = [
  "./accessibility-preflight.js",
  "./check-instructions.mjs",
];

const frontendProjectFiles = ["../web/static/**/*.js"];

const toolingProjectFiles = ["./**/*.js", "./**/*.mjs"];

module.exports = {
  entry: [...frontendEntries, ...toolingEntries],
  project: [...frontendProjectFiles, ...toolingProjectFiles],
  ignore: ["../web/static/eslint.config.js"],
  ignoreDependencies: [
    "eslint",
    "stylelint",
    "htmlhint",
    "pa11y-ci",
  ],
};
