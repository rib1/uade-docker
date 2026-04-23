import fs from "node:fs";
import path from "node:path";

const projectRoot = process.env.PROJECT_ROOT || process.cwd();
const cliArgs = new Set(process.argv.slice(2));
const shouldListFoundReferences = cliArgs.has("--list-found-references");

const baseInstructionFiles = [
  ".agents/AGENTS.md",
  ".agents/README.md",
  ".agents/project-lessons.md",
];

const requiredReferencedFiles = {
  ".agents/AGENTS.md": [
    "docs/ARCHITECTURE.md",
    "docs/DOCKER_VERSIONING.md",
    "docs/CODE-QUALITY.md",
    "docs/WEB-PLAYER.md",
  ],
  ".agents/README.md": [
    ".agents/AGENTS.md",
    ".agents/project-lessons.md",
  ],
  ".agents/project-lessons.md": [
    "test/accessibility-preflight.js",
    "test/accessibility-scenarios.js",
    "test/test_accessibility.sh",
    "docker-compose.dev.yml",
    "pyproject.toml",
  ],
};

const failures = [];
const foundInlineReferencesByFile = new Map();
const canonicalComposePath = "docker-compose.yml";
const canonicalIntegrationTestCommand =
  "docker compose -f docker-compose.yml -f test/docker-compose.endpoints.yml run --rm --build uade-test-runner";
const canonicalDevCommand =
  "docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build uade-web";
const oneOffComposeServices = [
  "quality-check",
  "uade-test-runner",
  "uade-test-ratelimit-runner",
  "uade-test-accessibility-runner",
  "uade-test-race-condition-runner",
  "zap-scan",
  "zap-full-scan",
  "zap-scan-seeded",
  "zap-full-scan-seeded",
];

function findSkillInstructionFiles() {
  const skillsRoot = path.join(projectRoot, ".agents", "skills");
  if (!fs.existsSync(skillsRoot)) {
    return [];
  }

  const skillFiles = [];
  const stack = [skillsRoot];

  while (stack.length > 0) {
    const currentDir = stack.pop();
    for (const entry of fs.readdirSync(currentDir, { withFileTypes: true })) {
      const absolutePath = path.join(currentDir, entry.name);
      if (entry.isDirectory()) {
        stack.push(absolutePath);
        continue;
      }
      if (entry.isFile() && entry.name.endsWith(".md")) {
        skillFiles.push(path.relative(projectRoot, absolutePath).replace(/\\/g, "/"));
      }
    }
  }

  return skillFiles.sort();
}

const instructionFiles = [...baseInstructionFiles, ...findSkillInstructionFiles()];

function addFailure(file, message) {
  failures.push(`${file}: ${message}`);
}

function fileExists(relativePath) {
  return fs.existsSync(path.join(projectRoot, relativePath));
}

function readFile(relativePath) {
  return fs.readFileSync(path.join(projectRoot, relativePath), "utf8");
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
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
    ".agents/",
    ".github/",
    "docs/",
    "references/",
    "test/",
    "web/",
  ];
  const repoFileNames = [
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
    {
      pattern:
        /docker compose -f docker-compose\.yml -f docker-compose\.dev\.yml up --build uade-web/i,
      message:
        "development-stack guidance should use detached mode (`up -d --build`) so the start command does not block the terminal",
    },
    {
      pattern: new RegExp(
        `docker compose[^\\n]*\\bup\\b[^\\n]*\\b(?:${oneOffComposeServices.map(escapeRegExp).join("|")})\\b`,
        "i",
      ),
      message:
        "one-off Compose jobs should use `docker compose run --rm` instead of `up`",
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

  if (
    !(
      /source of truth[\s\S]{0,80}docker-compose\.yml/i.test(content) ||
      /docker-compose\.yml[\s\S]{0,80}source of truth/i.test(content)
    )
  ) {
    addFailure(
      relativePath,
      "must state that docker-compose.yml command comments are the source of truth for one-off Compose jobs",
    );
  }

  if (!content.includes(canonicalIntegrationTestCommand)) {
    addFailure(
      relativePath,
      `must include the canonical integration test command: ${canonicalIntegrationTestCommand}`,
    );
  }

  if (!content.includes(canonicalDevCommand)) {
    addFailure(
      relativePath,
      `must include the canonical detached dev command: ${canonicalDevCommand}`,
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

function validateSkillInstructions(relativePath, content) {
  const requiredPatterns = [
    {
      pattern: /Read \[?`?\.agents\/AGENTS\.md`?\]?\([^)]+\) first/i,
      message: "must direct agents to read .agents/AGENTS.md first",
    },
    {
      pattern: /\.agents\/project-lessons\.md/i,
      message: "must reference .agents/project-lessons.md for repo-specific learnings",
    },
    {
      pattern: /Docker-first workflows|Docker Compose/i,
      message: "must reinforce Docker-first workflows",
    },
    {
      pattern: /After a feature or fix is ready[\s\S]{0,160}run the relevant automated tests/i,
      message: "must require running relevant automated tests after a feature or fix is ready",
    },
    {
      pattern: /update `\.agents\/project-lessons\.md`/i,
      message: "must tell contributors to record non-obvious lessons in .agents/project-lessons.md",
    },
    {
      pattern: /update `test\/check-instructions\.mjs`/i,
      message: "must tell contributors to harden test/check-instructions.mjs against repeated instruction drift",
    },
  ];

  for (const { pattern, message } of requiredPatterns) {
    if (!pattern.test(content)) {
      addFailure(relativePath, message);
    }
  }
}

function validateProjectLessons(relativePath, content) {
  const requiredPatterns = [
    {
      pattern:
        /Compose Exit Behavior:[\s\S]{0,220}run --rm --build uade-test-runner/i,
      message:
        "must preserve the lesson that one-off endpoint tests should use `docker compose ... run --rm --build uade-test-runner`",
    },
    {
      pattern: /docker-compose\.dev\.yml/i,
      message: "must document docker-compose.dev.yml as the dev-mode override",
    },
    {
      pattern: /pyproject\.toml[\s\S]{0,120}source of truth/i,
      message: "must keep the Ruff source-of-truth lesson tied to pyproject.toml",
    },
    {
      pattern:
        /playwright-core[\s\S]{0,160}docker-compose\.tooling\.yml/i,
      message:
        "must keep the Playwright version-alignment lesson tied to test/docker-compose.tooling.yml",
    },
    {
      pattern:
        /test\/test_accessibility\.sh[\s\S]{0,120}source of truth/i,
      message:
        "must keep the accessibility-count source-of-truth lesson tied to test/test_accessibility.sh",
    },
  ];

  for (const { pattern, message } of requiredPatterns) {
    if (!pattern.test(content)) {
      addFailure(relativePath, message);
    }
  }
}

function validateComposeCommandSourceOfTruth() {
  if (!fileExists(canonicalComposePath)) {
    addFailure(canonicalComposePath, "expected compose source-of-truth file is missing");
    return;
  }

  const composeContent = readFile(canonicalComposePath);
  if (!composeContent.includes(canonicalDevCommand)) {
    addFailure(
      canonicalComposePath,
      `missing canonical detached dev command in compose comments: ${canonicalDevCommand}`,
    );
  }

  if (!composeContent.includes(canonicalIntegrationTestCommand)) {
    addFailure(
      canonicalComposePath,
      `missing canonical integration test command in compose comments: ${canonicalIntegrationTestCommand}`,
    );
  }
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

function validateConsecutiveIfNumberedListItems(relativePath, content) {
  const lines = content.split("\n");
  let insideCodeBlock = false;
  let previousIfListItem = null;

  for (let index = 0; index < lines.length; index += 1) {
    const trimmedLine = lines[index].trim();

    if (trimmedLine.startsWith("```")) {
      insideCodeBlock = !insideCodeBlock;
      previousIfListItem = null;
      continue;
    }

    if (insideCodeBlock) {
      continue;
    }

    if (!trimmedLine) {
      previousIfListItem = null;
      continue;
    }

    const numberedIfMatch = trimmedLine.match(/^(\d+)\.\s+If\b/i);
    if (!numberedIfMatch) {
      previousIfListItem = null;
      continue;
    }

    if (previousIfListItem !== null) {
      addFailure(
        relativePath,
        `avoid starting consecutive numbered list items with "If" for readability: "${previousIfListItem}" then "${trimmedLine}"`,
      );
    }

    previousIfListItem = trimmedLine;
  }
}

function validatePlaywrightVersionAlignment() {
  const packageJsonPath = "test/package.json";
  const toolingComposePath = "test/docker-compose.tooling.yml";

  if (!fileExists(packageJsonPath) || !fileExists(toolingComposePath)) {
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

  const composeContent = readFile(toolingComposePath);
  const imageTagMatch = composeContent.match(
    /^  playwright:\s*$.*?^    image:\s*mcr\.microsoft\.com\/playwright:v([^\s-]+)-/ms,
  );

  if (!imageTagMatch) {
    addFailure(
      toolingComposePath,
      "could not read Playwright image tag from playwright service image reference",
    );
    return;
  }

  const playwrightImageVersion = imageTagMatch[1];
  if (playwrightVersion !== playwrightImageVersion) {
    addFailure(
      toolingComposePath,
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

  if (relativePath === ".agents/AGENTS.md") {
    validateCopilotInstructions(relativePath, content);
  } else if (relativePath === ".agents/README.md") {
    validateSkillInstructions(relativePath, content);
    validateConsecutiveIfNumberedListItems(relativePath, content);
  } else if (relativePath.startsWith(".agents/skills/") && relativePath.endsWith("/SKILL.md")) {
    validateSkillInstructions(relativePath, content);
    validateConsecutiveIfNumberedListItems(relativePath, content);
  } else if (relativePath === ".agents/project-lessons.md") {
    validateProjectLessons(relativePath, content);
  }
}

validatePlaywrightVersionAlignment();
validateComposeCommandSourceOfTruth();

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

console.log("Checked instruction files:");
for (const relativePath of instructionFiles) {
  console.log(`- ${relativePath}`);
}

console.log("Instruction files look consistent.");
