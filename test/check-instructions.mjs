import fs from "node:fs";
import path from "node:path";

const projectRoot = process.env.PROJECT_ROOT || process.cwd();

const instructionFiles = [
  ".github/copilot-instructions.md",
  "SKILL.md",
  "references/project-lessons.md",
];

const failures = [];

function addFailure(file, message) {
  failures.push(`${file}: ${message}`);
}

function fileExists(relativePath) {
  return fs.existsSync(path.join(projectRoot, relativePath));
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
}

for (const relativePath of instructionFiles) {
  if (!fileExists(relativePath)) {
    addFailure(relativePath, "expected instruction file is missing");
    continue;
  }

  const absolutePath = path.join(projectRoot, relativePath);
  const content = fs.readFileSync(absolutePath, "utf8");

  validateRelativeLinks(relativePath, content);

  if (relativePath === ".github/copilot-instructions.md") {
    validateCopilotInstructions(relativePath, content);
  }
}

if (failures.length > 0) {
  console.error("Instruction file checks failed:");
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log("Instruction files look consistent.");
