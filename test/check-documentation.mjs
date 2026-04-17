import fs from "node:fs";
import path from "node:path";

const projectRoot = process.env.PROJECT_ROOT || process.cwd();

const requiredDocs = [
  "README.md",
  "docs/ARCHITECTURE.md",
  "docs/CODE-QUALITY.md",
  "docs/COMPONENT-DIAGRAM.md",
  "docs/WEB-PLAYER.md",
];

const failures = [];

function addFailure(file, message) {
  failures.push(`${file}: ${message}`);
}

function fileExists(relativePath) {
  return fs.existsSync(path.join(projectRoot, relativePath));
}

function readFile(relativePath) {
  return fs.readFileSync(path.join(projectRoot, relativePath), "utf8");
}

function readJson(relativePath) {
  return JSON.parse(readFile(relativePath));
}

function stripFencedCodeBlocks(content) {
  return content.replace(/^```.*\n[\s\S]*?^```[ \t]*$/gm, "");
}

function findMarkdownFiles() {
  const markdownFiles = new Set();

  if (fileExists("README.md")) {
    markdownFiles.add("README.md");
  }

  function addMarkdownFilesFromDir(relativeDir) {
    const dirPath = path.join(projectRoot, relativeDir);
    if (!fs.existsSync(dirPath)) {
      return;
    }

    const pending = [dirPath];
    while (pending.length > 0) {
      const currentDir = pending.pop();
      for (const entry of fs.readdirSync(currentDir, { withFileTypes: true })) {
        const entryPath = path.join(currentDir, entry.name);
        if (entry.isDirectory()) {
          pending.push(entryPath);
          continue;
        }
        if (!entry.isFile() || !entry.name.endsWith(".md")) {
          continue;
        }
        markdownFiles.add(path.relative(projectRoot, entryPath).replace(/\\/g, "/"));
      }
    }
  }

  addMarkdownFilesFromDir("docs");

  return [...markdownFiles].sort();
}

function normalizeHeadingText(value) {
  return value.trim().toLowerCase().replace(/\s+/g, " ");
}

function findOriginalLineForHeading(content, headingSource, startIndex) {
  const searchStart = Math.max(startIndex, 0);
  let originalIndex = content.indexOf(headingSource, searchStart);
  if (originalIndex === -1) {
    originalIndex = content.indexOf(headingSource);
  }
  if (originalIndex === -1) {
    return null;
  }
  return content.slice(0, originalIndex).split("\n").length;
}

function validateDuplicateHeadings(relativePath, content) {
  const contentWithoutCodeBlocks = stripFencedCodeBlocks(content);
  const headingPattern = /^(#{1,6})\s+(.+?)\s*#*\s*$/gm;
  const seen = new Map();
  let lastOriginalIndex = 0;

  for (const match of contentWithoutCodeBlocks.matchAll(headingPattern)) {
    const headingText = normalizeHeadingText(match[2]);
    if (!headingText) {
      continue;
    }
    const line = findOriginalLineForHeading(content, match[0], lastOriginalIndex);
    if (line !== null) {
      const originalIndex = content.indexOf(match[0], lastOriginalIndex);
      if (originalIndex !== -1) {
        lastOriginalIndex = originalIndex + match[0].length;
      }
    }
    if (seen.has(headingText)) {
      addFailure(
        relativePath,
        `duplicate heading text "${match[2].trim()}" (previously used on line ${seen.get(headingText)})`,
      );
      continue;
    }
    seen.set(headingText, line ?? 1);
  }
}

function validateFencedCodeLanguages(relativePath, content) {
  const lines = content.split("\n");
  let insideFence = false;

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const trimmed = line.trim();
    if (!trimmed.startsWith("```")) {
      continue;
    }

    if (!insideFence) {
      const language = trimmed.slice(3).trim();
      if (!language) {
        addFailure(relativePath, `fenced code block on line ${index + 1} is missing a language`);
      }
      insideFence = true;
    } else {
      insideFence = false;
    }
  }

  if (insideFence) {
    addFailure(relativePath, "unterminated fenced code block");
  }
}

function validateRelativeLinks(relativePath, content) {
  const contentWithoutCodeBlocks = stripFencedCodeBlocks(content);
  const linkPattern = /\[[^\]]*]\(([^)]+)\)/g;
  const fileDir = path.dirname(relativePath);

  for (const match of contentWithoutCodeBlocks.matchAll(linkPattern)) {
    const rawTarget = match[1].trim();
    if (
      !rawTarget ||
      rawTarget.startsWith("http://") ||
      rawTarget.startsWith("https://") ||
      rawTarget.startsWith("mailto:") ||
      rawTarget.startsWith("#")
    ) {
      continue;
    }

    const targetPath = rawTarget.split("#", 1)[0];
    if (!targetPath) {
      continue;
    }

    const resolvedPath = path.normalize(path.join(projectRoot, fileDir, targetPath));
    if (!fs.existsSync(resolvedPath)) {
      addFailure(relativePath, `broken relative link: ${rawTarget}`);
    }
  }
}

function validateNoHardcodedWorkspacePaths(relativePath, content) {
  const normalizedRoot = projectRoot.replace(/\\/g, "/").toLowerCase();
  const normalizedContent = content.replace(/\\/g, "/").toLowerCase();
  const rootWithoutLeadingSlash = normalizedRoot.replace(/^\/+/, "");
  const genericContainerRoots = new Set(["/workspace"]);

  if (!normalizedRoot || genericContainerRoots.has(normalizedRoot)) {
    return;
  }

  if (normalizedContent.includes(normalizedRoot)) {
    addFailure(
      relativePath,
      "must not contain hardcoded local workspace paths; use repo-relative paths instead",
    );
    return;
  }

  if (rootWithoutLeadingSlash && normalizedContent.includes(`/${rootWithoutLeadingSlash}`)) {
    addFailure(
      relativePath,
      "must not contain hardcoded local workspace paths; use repo-relative paths instead",
    );
  }
}

function validateReadmeIntegrity() {
  const readmePath = "README.md";
  if (!fileExists(readmePath)) {
    return;
  }
  const content = readFile(readmePath);
  const lines = content.split("\n");
  if (lines.length > 200) {
    addFailure(readmePath, "README.md exceeds 200 lines. Keep it as a TL;DR and move details to docs/.");
  }
}

function validateComponentDiagramIntegrity() {
  const docPath = "docs/COMPONENT-DIAGRAM.md";
  if (!fileExists(docPath)) {
    return;
  }
  const content = readFile(docPath);
  if (!content.includes("ComponentDb(cache, \"Server-Side Cache\"")) {
    addFailure(docPath, "Mermaid diagram must contain the Server-Side Cache ComponentDb node.");
  }
  if (!content.includes("/probe-upload") || !content.includes("/convert-probed")) {
    addFailure(
      docPath,
      "component diagram documentation must mention /probe-upload and /convert-probed in the request flow or API description",
    );
  }
}

function validateCoreDocsConsistency() {
  const webPlayerPath = "docs/WEB-PLAYER.md";
  if (!fileExists(webPlayerPath)) {
    return;
  }
  const content = readFile(webPlayerPath);
  if (/localFile` is set to null|set `localFile` to null/i.test(content)) {
    addFailure(
      webPlayerPath,
      "stale local queue wording found; converted local tracks keep localFile for upload fallback",
    );
  }
}

function validatePerformanceDocsConsistency() {
  const docPath = "docs/PERFORMANCE.md";
  if (!fileExists(docPath)) {
    return;
  }

  const content = readFile(docPath);
  const requiredBenchSuites = [
    "test/bench/smoke.js",
    "test/bench/conversion.js",
    "test/bench/cache.js",
    "test/bench/streaming.js",
    "test/bench/dast-patterns.js",
    "test/bench/semaphore-balance.js",
  ];

  for (const suitePath of requiredBenchSuites) {
    if (!content.includes(suitePath)) {
      addFailure(docPath, `must mention benchmark suite \`${suitePath}\``);
    }
  }

  if (!content.includes("MAX_CONCURRENT_CONVERSIONS=2")) {
    addFailure(
      docPath,
      "must document the current Cloud Run default `MAX_CONCURRENT_CONVERSIONS=2`",
    );
  }

  if (!content.includes("Conversion semaphore wait")) {
    addFailure(
      docPath,
      "must mention `Conversion semaphore wait` so queueing guidance stays documented",
    );
  }

  if (!content.includes("Conversion lock wait")) {
    addFailure(
      docPath,
      "must mention `Conversion lock wait` so same-hash contention guidance stays documented",
    );
  }
}

function readPinnedVersions() {
  const packageJson = readJson("test/package.json");
  const qualityPins = Object.fromEntries(
    readFile("test/requirements-quality.txt")
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean)
      .map((line) => line.split("==", 2)),
  );
  const webPins = Object.fromEntries(
    readFile("web/requirements.txt")
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean)
      .map((line) => line.split("==", 2)),
  );
  const toolingManifest = readFile("test/docker-compose.tooling.yml");

  const toolingImageVersions = {
    hadolint: toolingManifest.match(/^    image:\s*hadolint\/hadolint:v([^\s]+)$/m)?.[1],
    actionlint: toolingManifest.match(/^    image:\s*rhysd\/actionlint:([^\s]+)$/m)?.[1],
    shellcheck: toolingManifest.match(/^    image:\s*koalaman\/shellcheck:v([^\s]+)$/m)?.[1],
    playwright: toolingManifest.match(
      /^    image:\s*mcr\.microsoft\.com\/playwright:v([^\s-]+)-/m,
    )?.[1],
  };

  return {
    flask: webPins.flask,
    gunicorn: webPins.gunicorn,
    werkzeug: webPins.werkzeug,
    requests: webPins.requests,
    "flask-limiter": webPins["Flask-Limiter"],
    black: qualityPins.black,
    ruff: qualityPins.ruff,
    mypy: qualityPins.mypy,
    vulture: qualityPins.vulture,
    "types-requests": qualityPins["types-requests"],
    yamllint: qualityPins.yamllint,
    eslint: packageJson.devDependencies.eslint,
    stylelint: packageJson.devDependencies.stylelint,
    htmlhint: packageJson.devDependencies.htmlhint,
    knip: packageJson.devDependencies.knip,
    "pa11y-ci": packageJson.devDependencies["pa11y-ci"],
    "playwright-core": packageJson.devDependencies["playwright-core"],
    purgecss: packageJson.devDependencies.purgecss,
    hadolint: toolingImageVersions.hadolint,
    actionlint: toolingImageVersions.actionlint,
    shellcheck: toolingImageVersions.shellcheck,
    playwright: toolingImageVersions.playwright,
  };
}

function validatePinnedVersionMentions(relativePath, content, pinnedVersions) {
  const contentWithoutCodeBlocks = stripFencedCodeBlocks(content);
  const checks = [
    { label: "Flask", expected: pinnedVersions.flask, regex: /\bFlask\s+(\d+(?:\.\d+){0,2})\b/g },
    {
      label: "Flask-Limiter",
      expected: pinnedVersions["flask-limiter"],
      regex: /\bFlask-Limiter\s+(\d+(?:\.\d+){0,2})\b/g,
    },
    {
      label: "Gunicorn",
      expected: pinnedVersions.gunicorn,
      regex: /\bGunicorn\s+(\d+(?:\.\d+){0,2})\b/g,
    },
    {
      label: "Werkzeug",
      expected: pinnedVersions.werkzeug,
      regex: /\bWerkzeug\s+(\d+(?:\.\d+){0,2})\b/g,
    },
    {
      label: "requests",
      expected: pinnedVersions.requests,
      regex: /\brequests\s+(\d+(?:\.\d+){0,2})\b/g,
    },
    { label: "Black", expected: pinnedVersions.black, regex: /\bBlack\s+(\d+(?:\.\d+){0,2})\b/g },
    { label: "Ruff", expected: pinnedVersions.ruff, regex: /\bRuff\s+(\d+(?:\.\d+){0,2})\b/g },
    { label: "mypy", expected: pinnedVersions.mypy, regex: /\bmypy\s+(\d+(?:\.\d+){0,2})\b/g },
    {
      label: "Vulture",
      expected: pinnedVersions.vulture,
      regex: /\bVulture\s+(\d+(?:\.\d+){0,2})\b/g,
    },
    {
      label: "ESLint",
      expected: pinnedVersions.eslint,
      regex: /\bESLint\s+(\d+(?:\.\d+){0,2})\b/g,
    },
    {
      label: "Stylelint",
      expected: pinnedVersions.stylelint,
      regex: /\bStylelint\s+(\d+(?:\.\d+){0,2})\b/g,
    },
    {
      label: "HTMLHint",
      expected: pinnedVersions.htmlhint,
      regex: /\bHTMLHint\s+(\d+(?:\.\d+){0,2})\b/g,
    },
    { label: "knip", expected: pinnedVersions.knip, regex: /\bknip\s+(\d+(?:\.\d+){0,2})\b/g },
    {
      label: "PurgeCSS",
      expected: pinnedVersions.purgecss,
      regex: /\bPurgeCSS\s+(\d+(?:\.\d+){0,2})\b/g,
    },
    {
      label: "pa11y-ci",
      expected: pinnedVersions["pa11y-ci"],
      regex: /\bpa11y-ci\s+(\d+(?:\.\d+){0,2})\b/g,
    },
    {
      label: "Playwright",
      expected: pinnedVersions.playwright,
      regex: /\bPlaywright\s+(\d+(?:\.\d+){0,2})\b/g,
    },
    {
      label: "playwright-core",
      expected: pinnedVersions["playwright-core"],
      regex: /\bplaywright-core\s+(\d+(?:\.\d+){0,2})\b/g,
    },
    {
      label: "Hadolint",
      expected: pinnedVersions.hadolint,
      regex: /\bHadolint\s+(\d+(?:\.\d+){0,2})\b/g,
    },
    {
      label: "ActionLint",
      expected: pinnedVersions.actionlint,
      regex: /\bActionLint\s+(\d+(?:\.\d+){0,2})\b/g,
    },
    {
      label: "ShellCheck",
      expected: pinnedVersions.shellcheck,
      regex: /\bShellCheck\s+(\d+(?:\.\d+){0,2})\b/g,
    },
    {
      label: "Yamllint",
      expected: pinnedVersions.yamllint,
      regex: /\bYamllint\s+(\d+(?:\.\d+){0,2})\b/g,
    },
  ];

  for (const check of checks) {
    if (!check.expected) {
      continue;
    }

    for (const match of contentWithoutCodeBlocks.matchAll(check.regex)) {
      const mentionedVersion = match[1];
      if (mentionedVersion !== check.expected) {
        addFailure(
          relativePath,
          `${check.label} version mention "${mentionedVersion}" is stale; expected "${check.expected}" or omit the exact version`,
        );
      }
    }
  }
}

for (const requiredDoc of requiredDocs) {
  if (!fileExists(requiredDoc)) {
    addFailure(requiredDoc, "required documentation file is missing");
  }
}

validateReadmeIntegrity();
validateComponentDiagramIntegrity();
validateCoreDocsConsistency();
validatePerformanceDocsConsistency();

const pinnedVersions = readPinnedVersions();
const markdownFiles = findMarkdownFiles();

for (const relativePath of markdownFiles) {
  const content = readFile(relativePath);
  validateDuplicateHeadings(relativePath, content);
  validateFencedCodeLanguages(relativePath, content);
  validateRelativeLinks(relativePath, content);
  validateNoHardcodedWorkspacePaths(relativePath, content);
  validatePinnedVersionMentions(relativePath, content, pinnedVersions);
}

if (failures.length > 0) {
  console.error("Documentation checks failed:");
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log("Checked documentation files:");
for (const relativePath of markdownFiles) {
  console.log(`- ${relativePath}`);
}

console.log("Documentation files look consistent.");
