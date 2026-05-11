import { readFile } from "node:fs/promises";
import path from "node:path";

function fail(message, details = []) {
  console.error(`ERROR: ${message}`);
  for (const detail of details) {
    console.error(`  ${detail}`);
  }
  process.exit(1);
}

function formatNodeImage(version) {
  return `node:${version}-alpine`;
}

function extractQualityBaseVersion(dockerfileText) {
  const match = dockerfileText.match(
    /^\s*FROM\s+(?:--platform=\S+\s+)?node:(\d+)[^\s#]*(?:\s+AS\s+\S+)?\s*(?:#.*)?$/im,
  );
  if (!match) {
    fail("Could not read the Node base image from test/Dockerfile.quality.");
  }

  return match[1];
}

function extractHelperVersions(label, scriptText) {
  const versions = [...scriptText.matchAll(/\bnode:(\d+)-alpine\b/g)].map((match) => match[1]);
  if (versions.length === 0) {
    fail(`Could not read Node helper image pins from ${label}.`);
  }

  return [...new Set(versions)];
}

async function main() {
  const projectRoot = process.env.PROJECT_ROOT || process.cwd();
  const qualityDockerfilePath = path.join(projectRoot, "test", "Dockerfile.quality");
  const bashRunnerPath = path.join(projectRoot, "test", "check-code-quality.sh");
  const powershellRunnerPath = path.join(projectRoot, "test", "check-code-quality.ps1");

  const [qualityDockerfileText, bashRunnerText, powershellRunnerText] = await Promise.all([
    readFile(qualityDockerfilePath, "utf8"),
    readFile(bashRunnerPath, "utf8"),
    readFile(powershellRunnerPath, "utf8"),
  ]);

  const qualityBaseVersion = extractQualityBaseVersion(qualityDockerfileText);
  const bashHelperVersions = extractHelperVersions("test/check-code-quality.sh", bashRunnerText);
  const powershellHelperVersions = extractHelperVersions(
    "test/check-code-quality.ps1",
    powershellRunnerText,
  );

  const comparedVersions = [
    ["test/Dockerfile.quality base image", [qualityBaseVersion]],
    ["test/check-code-quality.sh helper images", bashHelperVersions],
    ["test/check-code-quality.ps1 helper images", powershellHelperVersions],
  ];

  const uniqueVersions = [
    ...new Set(comparedVersions.flatMap(([, versions]) => versions)),
  ];

  if (uniqueVersions.length !== 1) {
    fail(
      "Node quality tooling version mismatch.",
      comparedVersions.map(
        ([label, versions]) => `${label}: ${versions.map(formatNodeImage).join(", ")}`,
      ),
    );
  }

  console.log(`Node quality tooling images are aligned at ${formatNodeImage(qualityBaseVersion)}.`);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
