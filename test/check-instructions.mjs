import fs from "node:fs";
import path from "node:path";

const projectRoot = process.env.PROJECT_ROOT || process.cwd();
const cliArgs = new Set(process.argv.slice(2));
const shouldListFoundReferences = cliArgs.has("--list-found-references");

const instructionFiles = [
  ".github/copilot-instructions.md",
  "SKILL.md",
  "references/project-lessons.md",
];

const requiredReferencedFiles = {
  ".github/copilot-instructions.md": [
    "docs/ARCHITECTURE.md",
    "docs/DOCKER_VERSIONING.md",
    "docs/CODE-QUALITY.md",
    "docs/WEB-PLAYER.md",
  ],
  "SKILL.md": [
    ".github/copilot-instructions.md",
    "references/project-lessons.md",
  ],
  "references/project-lessons.md": [
    "test/accessibility-preflight.js",
    "test/accessibility-scenarios.js",
    "test/test_accessibility.sh",
    "docker-compose.dev.yml",
    "pyproject.toml",
  ],
};

const failures = [];
const foundInlineReferencesByFile = new Map();

function addFailure(file, message) {
  failures.push(`${file}: ${message}`);
}

function fileExists(relativePath) {
  return fs.existsSync(path.join(projectRoot, relativePath));
}

function readFile(relativePath) {
  return fs.readFileSync(path.join(projectRoot, relativePath), "utf8");
}

function validateRelativeLinks(relativePath, content) {
  const linkPattern = /\[[^\]]*]\(([^)]+)\)/g;
  const fileDir = path.dirname(relativePath);
  for (const match of content.matchAll(linkPattern)) {
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

function looksLikeRepoFilePath(value) {
  const repoPathPrefixes = [
    ".github/",
    "docs/",
    "references/",
    "test/",
    "web/",
  ];
  const repoFileNames = [
    "SKILL.md",
    "GEMINI.md",
    "Dockerfile",
    "Dockerfile.web",
    "docker-compose.yml",
    "docker-compose.dev.yml",
    "pyproject.toml",
  ];

  return (
    (repoPathPrefixes.some((prefix) => value.startsWith(prefix)) ||
      repoFileNames.includes(value)) &&
    !value.includes("*") &&
    !value.includes("://")
  );
}

function normalizeReferencedPath(rawValue) {
  return rawValue
    .trim()
    .replace(/^\.?\//, (match) => (match === "./" ? "" : match))
    .replace(/[),.:;!?]+$/g, "");
}

function validateInlineFileReferences(relativePath, content) {
  const contentWithoutCodeBlocks = content.replace(/```[\s\S]*?```/g, "");
  const inlineCodePattern = /`([^`]+)`/g;
  const checkedPaths = new Set();
  const foundPaths = new Set();

  for (const match of contentWithoutCodeBlocks.matchAll(inlineCodePattern)) {
    const rawValue = normalizeReferencedPath(match[1]);
    if (!looksLikeRepoFilePath(rawValue)) {
      continue;
    }

    foundPaths.add(rawValue);

    if (checkedPaths.has(rawValue)) {
      continue;
    }
    checkedPaths.add(rawValue);

    const resolvedPath = path.normalize(path.join(projectRoot, rawValue));
    if (!fs.existsSync(resolvedPath)) {
      addFailure(relativePath, `inline file reference is missing on disk: ${rawValue}`);
    }
  }

  foundInlineReferencesByFile.set(relativePath, [...foundPaths].sort());
}

function validateRequiredReferencedFiles(relativePath) {
  const requiredFiles = requiredReferencedFiles[relativePath] || [];
  for (const targetPath of requiredFiles) {
    if (!fileExists(targetPath)) {
      addFailure(relativePath, `required referenced file is missing: ${targetPath}`);
    }
  }
}

function validateCopilotInstructions(relativePath, content) {
  const forbiddenPatterns = [
    {
      pattern: /workflow file changes/i,
      message:
        "replace vague workflow-trigger wording with the specific watched workflow path",
    },
    {
      pattern: /UADE_TEST_MODE=1[\s\S]{0,120}disable rate limits/i,
      message:
        "do not describe UADE_TEST_MODE as the rate-limit bypass; use RATE_LIMIT_DISABLED",
    },
    {
      pattern: /Cloud Run needs [`']?\/tmp[`']? mounted as volume/i,
      message:
        "do not describe Cloud Run as requiring a docker-compose-managed /tmp volume",
    },
    {
      pattern: /Start web player with live reload:[\s\S]{0,120}docker compose up -d --build uade-web/i,
      message:
        "base compose is production-like; hot reload instructions must use docker-compose.dev.yml",
    },
  ];

  for (const { pattern, message } of forbiddenPatterns) {
    if (pattern.test(content)) {
      addFailure(relativePath, message);
    }
  }

  if (/hot reload|live reload/i.test(content) && !/docker-compose\.dev\.yml/i.test(content)) {
    addFailure(
      relativePath,
      "hot-reload guidance should mention docker-compose.dev.yml",
    );
  }

  const requiredTestingExpectations = [
    /after (a )?(feature|fix|code changes?) (is|are) ready/i,
    /check-code-quality\.(ps1|sh)/i,
    /relevant .*test/i,
  ];

  for (const pattern of requiredTestingExpectations) {
    if (!pattern.test(content)) {
      addFailure(
        relativePath,
        "must explicitly require running code quality and relevant tests after a feature or fix is ready",
      );
      break;
    }
  }

  validateNearDuplicatePolicyLines(relativePath, content);
}

function normalizePolicyLine(value) {
  return value
    .toLowerCase()
    .replace(/\*\*/g, "")
    .replace(/[`'".,():;-]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function tokenizePolicyLine(value) {
  return new Set(
    normalizePolicyLine(value)
      .split(" ")
      .filter((token) => token.length >= 4),
  );
}

function jaccardSimilarity(leftTokens, rightTokens) {
  const intersectionSize = [...leftTokens].filter((token) => rightTokens.has(token)).length;
  const unionSize = new Set([...leftTokens, ...rightTokens]).size;
  return unionSize === 0 ? 0 : intersectionSize / unionSize;
}

function validateNearDuplicatePolicyLines(relativePath, content) {
  const policyLines = content
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.startsWith("**") && line.endsWith("**") === false);

  for (let i = 0; i < policyLines.length; i += 1) {
    const leftLine = policyLines[i];
    const leftTokens = tokenizePolicyLine(leftLine);
    if (leftTokens.size < 4) {
      continue;
    }

    for (let j = i + 1; j < policyLines.length; j += 1) {
      const rightLine = policyLines[j];
      const rightTokens = tokenizePolicyLine(rightLine);
      if (rightTokens.size < 4) {
        continue;
      }

      const similarity = jaccardSimilarity(leftTokens, rightTokens);
      if (similarity >= 0.6) {
        addFailure(
          relativePath,
          `near-duplicate policy lines detected: "${leftLine}" vs "${rightLine}"`,
        );
      }
    }
  }
}

function validatePlaywrightVersionAlignment() {
  const packageJsonPath = "test/package.json";
  const accessibilityComposePath = "test/docker-compose.accessibility.yml";

  if (!fileExists(packageJsonPath) || !fileExists(accessibilityComposePath)) {
    return;
  }

  let playwrightVersion;
  try {
    const packageJson = JSON.parse(readFile(packageJsonPath));
    playwrightVersion = packageJson?.devDependencies?.["playwright-core"];
  } catch {
    addFailure(packageJsonPath, "could not parse JSON to read devDependencies.playwright-core");
    return;
  }

  if (!playwrightVersion) {
    addFailure(packageJsonPath, "missing devDependencies.playwright-core");
    return;
  }

  const composeContent = readFile(accessibilityComposePath);
  const imageTagMatch = composeContent.match(
    /^\s*image:\s*mcr\.microsoft\.com\/playwright:v([^\s-]+)-/m,
  );

  if (!imageTagMatch) {
    addFailure(
      accessibilityComposePath,
      "could not read Playwright image tag from mcr.microsoft.com/playwright image reference",
    );
    return;
  }

  const playwrightImageVersion = imageTagMatch[1];
  if (playwrightVersion !== playwrightImageVersion) {
    addFailure(
      accessibilityComposePath,
      `Playwright version mismatch: test/package.json has ${playwrightVersion}, image tag has ${playwrightImageVersion}`,
    );
  }
}

for (const relativePath of instructionFiles) {
  if (!fileExists(relativePath)) {
    addFailure(relativePath, "expected instruction file is missing");
    continue;
  }

  const absolutePath = path.join(projectRoot, relativePath);
  const content = fs.readFileSync(absolutePath, "utf8");

  validateRelativeLinks(relativePath, content);
  validateInlineFileReferences(relativePath, content);
  validateRequiredReferencedFiles(relativePath);

  if (relativePath === ".github/copilot-instructions.md") {
    validateCopilotInstructions(relativePath, content);
  }
}

validatePlaywrightVersionAlignment();

if (failures.length > 0) {
  console.error("Instruction file checks failed:");
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

if (shouldListFoundReferences) {
  for (const relativePath of instructionFiles) {
    console.log(`FILE: ${relativePath}`);
    for (const reference of foundInlineReferencesByFile.get(relativePath) || []) {
      console.log(`  ${reference}`);
    }
  }
}

console.log("Instruction files look consistent.");
