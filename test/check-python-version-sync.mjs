import { readFile } from "node:fs/promises";
import path from "node:path";

function fail(message, details = []) {
  console.error(`ERROR: ${message}`);
  for (const detail of details) {
    console.error(`  ${detail}`);
  }
  process.exit(1);
}

function normalizePyTarget(target) {
  const match = /^py(\d)(\d+)$/.exec(target);
  if (!match) {
    return null;
  }

  return `${match[1]}.${Number(match[2])}`;
}

function requireSingleVersion(label, versions) {
  const uniqueVersions = [...new Set(versions)];

  if (uniqueVersions.length === 0) {
    fail(`Could not read ${label}.`);
  }

  if (uniqueVersions.length > 1) {
    fail(`${label} declared multiple Python versions.`, uniqueVersions);
  }

  return uniqueVersions[0];
}

function extractBlackVersion(pyprojectText) {
  const match = pyprojectText.match(/\[tool\.black\][\s\S]*?target-version\s*=\s*\[([^\]]+)\]/);
  if (!match) {
    fail("Could not read [tool.black] target-version from pyproject.toml.");
  }

  const versions = [...match[1].matchAll(/py\d+/g)]
    .map((entry) => normalizePyTarget(entry[0]))
    .filter(Boolean);

  return requireSingleVersion("pyproject.toml [tool.black] target-version", versions);
}

function extractRuffVersion(pyprojectText) {
  const match = pyprojectText.match(/\[tool\.ruff\][\s\S]*?target-version\s*=\s*"([^"]+)"/);
  if (!match) {
    fail("Could not read [tool.ruff] target-version from pyproject.toml.");
  }

  const version = normalizePyTarget(match[1]);
  if (!version) {
    fail("Unsupported [tool.ruff] target-version format.", [match[1]]);
  }

  return version;
}

function extractMypyVersion(pyprojectText) {
  const match = pyprojectText.match(/\[tool\.mypy\][\s\S]*?python_version\s*=\s*"(\d+\.\d+)"/);
  if (!match) {
    fail("Could not read [tool.mypy] python_version from pyproject.toml.");
  }

  return match[1];
}

function extractCodeqlDockerVersion(dockerfileText) {
  const match = dockerfileText.match(/^FROM python:(\d+\.\d+)(?:\.\d+)?-slim(?:-[^\s]+)?$/m);
  if (!match) {
    fail("Could not read the Python base image from test/Dockerfile.codeql.");
  }

  return match[1];
}

function extractQualityFallbackVersions(qualityScriptText) {
  const versions = [...qualityScriptText.matchAll(/python:(\d+\.\d+)(?:\.\d+)?-slim\b/g)].map(
    (match) => match[1],
  );

  return requireSingleVersion("test/check-code-quality.sh Python fallback image version", versions);
}

async function main() {
  const projectRoot = process.env.PROJECT_ROOT || process.cwd();
  const pyprojectPath = path.join(projectRoot, "pyproject.toml");
  const codeqlDockerfilePath = path.join(projectRoot, "test", "Dockerfile.codeql");
  const qualityScriptPath = path.join(projectRoot, "test", "check-code-quality.sh");

  const [pyprojectText, codeqlDockerfileText, qualityScriptText] = await Promise.all([
    readFile(pyprojectPath, "utf8"),
    readFile(codeqlDockerfilePath, "utf8"),
    readFile(qualityScriptPath, "utf8"),
  ]);

  const blackVersion = extractBlackVersion(pyprojectText);
  const ruffVersion = extractRuffVersion(pyprojectText);
  const mypyVersion = extractMypyVersion(pyprojectText);
  const codeqlDockerVersion = extractCodeqlDockerVersion(codeqlDockerfileText);
  const qualityFallbackVersion = extractQualityFallbackVersions(qualityScriptText);

  const pyprojectVersion = requireSingleVersion("pyproject.toml Python target version", [
    blackVersion,
    ruffVersion,
    mypyVersion,
  ]);

  const comparedVersions = [
    ["pyproject.toml Python target", pyprojectVersion],
    ["test/Dockerfile.codeql base image", codeqlDockerVersion],
    ["test/check-code-quality.sh Python fallback images", qualityFallbackVersion],
  ];

  const uniqueVersions = [...new Set(comparedVersions.map(([, version]) => version))];
  if (uniqueVersions.length !== 1) {
    fail(
      "Python tooling version mismatch.",
      comparedVersions.map(([label, version]) => `${label}: ${version}`),
    );
  }

  console.log(`Python tooling versions are aligned at ${pyprojectVersion}.`);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
