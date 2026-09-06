import { execFile } from "node:child_process";
import { readdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const projectRoot = process.env.PROJECT_ROOT || process.cwd();
const args = new Set(process.argv.slice(2));
const fixMode = args.has("--fix");
const pullImages = !args.has("--no-pull");

function fail(message, details = []) {
  console.error(`ERROR: ${message}`);
  for (const detail of details) {
    console.error(`  ${detail}`);
  }
  process.exit(1);
}

function isDockerfileName(name) {
  return name === "Dockerfile" || name.startsWith("Dockerfile.");
}

async function findDockerfiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const dockerfiles = [];

  for (const entry of entries) {
    if (entry.name === ".git" || entry.name === "node_modules") {
      continue;
    }

    const absolutePath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      dockerfiles.push(...(await findDockerfiles(absolutePath)));
      continue;
    }

    if (entry.isFile() && isDockerfileName(entry.name)) {
      dockerfiles.push(absolutePath);
    }
  }

  return dockerfiles.sort();
}

function normalizeImageReference(image) {
  if (image.includes("${") || image.includes("$")) {
    return null;
  }
  return image;
}

function extractPinsFromRunBlock(block) {
  const withoutLineComments = block
    .split(/\r?\n/)
    .map((line) => line.replace(/\s+#.*$/, ""))
    .join("\n");
  const normalized = withoutLineComments
    .replace(/\\\r?\n/g, " ")
    .replace(/\\/g, " ")
    .replace(/\r?\n/g, " ");
  const apkAddIndex = normalized.search(/\bapk\s+add\b/);
  if (apkAddIndex === -1) {
    return [];
  }

  const tokens = normalized
    .slice(apkAddIndex)
    .split(/\s+/)
    .map((token) => token.replace(/[;,]$/g, ""))
    .filter(Boolean);

  const pins = [];
  for (const token of tokens) {
    const match = token.match(/^([A-Za-z0-9._+-]+)=~(\d+(?:\.\d+){0,3})$/);
    if (!match) {
      continue;
    }
    pins.push({
      packageName: match[1],
      pinnedFamily: match[2],
      segmentCount: match[2].split(".").length,
    });
  }
  return pins;
}

function parseDockerfile(relativePath, text) {
  const lines = text.split(/\r?\n/);
  const pins = [];
  let currentImage = null;

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const fromMatch = line.match(
      /^\s*FROM\s+(?:--platform=\S+\s+)?([^\s#]+)(?:\s+AS\s+\S+)?\s*(?:#.*)?$/i,
    );
    if (fromMatch) {
      currentImage = normalizeImageReference(fromMatch[1]);
      continue;
    }

    if (!/\bRUN\b.*\bapk\s+add\b/.test(line)) {
      continue;
    }

    const startLine = index;
    const blockLines = [line];
    while (lines[index].trimEnd().endsWith("\\") && index + 1 < lines.length) {
      index += 1;
      blockLines.push(lines[index]);
    }

    if (!currentImage || !currentImage.toLowerCase().includes("alpine")) {
      continue;
    }

    for (const pin of extractPinsFromRunBlock(blockLines.join("\n"))) {
      pins.push({
        ...pin,
        image: currentImage,
        relativePath,
        lineNumber: startLine + 1,
      });
    }
  }

  return pins;
}

function versionFamily(version, segmentCount) {
  const versionMatch = version.match(/^(\d+(?:\.\d+)*)/);
  if (!versionMatch) {
    return null;
  }

  const parts = versionMatch[1].split(".");
  if (parts.length < segmentCount) {
    return null;
  }

  return parts.slice(0, segmentCount).join(".");
}

function parseApkPolicy(stdout) {
  const versions = new Map();
  let currentPackage = null;

  for (const line of stdout.split(/\r?\n/)) {
    const packageMatch = line.match(/^([A-Za-z0-9._+-]+) policy:/);
    if (packageMatch) {
      currentPackage = packageMatch[1];
      continue;
    }

    if (!currentPackage || versions.has(currentPackage)) {
      continue;
    }

    const versionMatch = line.match(/^\s+([0-9][^\s:]+):/);
    if (versionMatch) {
      versions.set(currentPackage, versionMatch[1]);
    }
  }

  return versions;
}

async function runDocker(argsForDocker) {
  try {
    return await execFileAsync("docker", argsForDocker, {
      maxBuffer: 10 * 1024 * 1024,
    });
  } catch (error) {
    const output = [error.stdout, error.stderr].filter(Boolean).join("\n").trim();
    throw new Error(output || error.message);
  }
}

async function queryImagePackageVersions(image, packageNames) {
  if (pullImages) {
    console.log(`Pulling ${image}...`);
    await runDocker(["pull", image]);
  }

  console.log(`Checking ${image}: ${packageNames.join(", ")}`);
  const packageArgs = packageNames.join(" ");
  const { stdout } = await runDocker([
    "run",
    "--rm",
    image,
    "sh",
    "-lc",
    `apk update >/dev/null && apk policy ${packageArgs}`,
  ]);
  return parseApkPolicy(stdout);
}

async function main() {
  const dockerfiles = await findDockerfiles(projectRoot);
  const fileTexts = new Map();
  const pins = [];

  for (const absolutePath of dockerfiles) {
    const relativePath = path.relative(projectRoot, absolutePath).replace(/\\/g, "/");
    const text = await readFile(absolutePath, "utf8");
    fileTexts.set(relativePath, { absolutePath, text });
    pins.push(...parseDockerfile(relativePath, text));
  }

  if (pins.length === 0) {
    console.log("No Alpine apk version-family pins found.");
    return;
  }

  const packageNamesByImage = new Map();
  for (const pin of pins) {
    if (!packageNamesByImage.has(pin.image)) {
      packageNamesByImage.set(pin.image, new Set());
    }
    packageNamesByImage.get(pin.image).add(pin.packageName);
  }

  const availableVersionsByImage = new Map();
  for (const [image, packageNames] of packageNamesByImage) {
    const versions = await queryImagePackageVersions(image, [...packageNames].sort());
    availableVersionsByImage.set(image, versions);
  }

  const stalePins = [];
  for (const pin of pins) {
    const availableVersion = availableVersionsByImage.get(pin.image)?.get(pin.packageName);
    if (!availableVersion) {
      stalePins.push({
        ...pin,
        message: "package was not found in the Alpine package index",
      });
      continue;
    }

    const currentFamily = versionFamily(availableVersion, pin.segmentCount);
    if (!currentFamily) {
      stalePins.push({
        ...pin,
        availableVersion,
        message: "could not derive comparable version family",
      });
      continue;
    }

    if (pin.pinnedFamily !== currentFamily) {
      stalePins.push({
        ...pin,
        availableVersion,
        currentFamily,
        message: `${pin.packageName}=~${pin.pinnedFamily} should be ${pin.packageName}=~${currentFamily}`,
      });
    }
  }

  if (stalePins.length === 0) {
    console.log("Alpine apk pins are aligned with current package indexes.");
    return;
  }

  if (!fixMode) {
    fail(
      "Alpine apk pins are stale.",
      stalePins.map((pin) => {
        const available = pin.availableVersion ? ` (${pin.image} offers ${pin.availableVersion})` : "";
        return `${pin.relativePath}:${pin.lineNumber}: ${pin.message}${available}`;
      }).concat(["Run: node test/check-alpine-apk-pins.mjs --fix"]),
    );
  }

  const updatedFiles = new Set();
  for (const pin of stalePins) {
    if (!pin.currentFamily) {
      fail(
        "Cannot auto-fix every stale Alpine apk pin.",
        [`${pin.relativePath}:${pin.lineNumber}: ${pin.message}`],
      );
    }

    const fileRecord = fileTexts.get(pin.relativePath);
    const from = `${pin.packageName}=~${pin.pinnedFamily}`;
    const to = `${pin.packageName}=~${pin.currentFamily}`;
    fileRecord.text = fileRecord.text.replaceAll(from, to);
    updatedFiles.add(pin.relativePath);
    console.log(`Updated ${pin.relativePath}: ${from} -> ${to}`);
  }

  for (const relativePath of updatedFiles) {
    const { absolutePath, text } = fileTexts.get(relativePath);
    await writeFile(absolutePath, text);
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
