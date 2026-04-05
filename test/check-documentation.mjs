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

function stripFencedCodeBlocks(content) {
  return content.replace(/^```.*\n[\s\S]*?^```[ \t]*$/gm, "");
}

function findMarkdownFiles() {
  const markdownFiles = [];

  if (fileExists("README.md")) {
    markdownFiles.push("README.md");
  }

  const docsDir = path.join(projectRoot, "docs");
  if (!fs.existsSync(docsDir)) {
    return markdownFiles;
  }

  for (const entry of fs.readdirSync(docsDir, { withFileTypes: true })) {
    if (entry.isFile() && entry.name.endsWith(".md")) {
      markdownFiles.push(path.posix.join("docs", entry.name));
    }
  }

  return markdownFiles.sort();
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

for (const requiredDoc of requiredDocs) {
  if (!fileExists(requiredDoc)) {
    addFailure(requiredDoc, "required documentation file is missing");
  }
}

validateReadmeIntegrity();
validateComponentDiagramIntegrity();
validateCoreDocsConsistency();

for (const relativePath of findMarkdownFiles()) {
  const content = readFile(relativePath);
  validateDuplicateHeadings(relativePath, content);
  validateFencedCodeLanguages(relativePath, content);
  validateRelativeLinks(relativePath, content);
  validateNoHardcodedWorkspacePaths(relativePath, content);
}

if (failures.length > 0) {
  console.error("Documentation checks failed:");
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log("Checked documentation files:");
for (const relativePath of findMarkdownFiles()) {
  console.log(`- ${relativePath}`);
}

console.log("Documentation files look consistent.");
