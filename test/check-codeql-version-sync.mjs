import { readFile } from "node:fs/promises";
import https from "node:https";
import path from "node:path";

function fail(message, details = []) {
  console.error(`ERROR: ${message}`);
  for (const detail of details) {
    console.error(`  ${detail}`);
  }
  process.exit(1);
}

function readManifestVersion(manifestText) {
  const version = manifestText.trim();
  if (!/^\d+\.\d+\.\d+$/.test(version)) {
    fail("test/codeql-version.txt must contain one CodeQL bundle version.", [
      `found: ${version || "<empty>"}`,
    ]);
  }

  return version;
}

function assertDockerfileUsesManifest(dockerfileText) {
  const details = [];
  if (/^\s*ARG\s+CODEQL_VERSION=/m.test(dockerfileText)) {
    details.push("remove the inline CODEQL_VERSION ARG from test/Dockerfile.codeql");
  }
  if (!/\bCOPY\s+test\/codeql-version\.txt\s+\/tmp\/codeql-version\.txt\b/.test(dockerfileText)) {
    details.push("copy test/codeql-version.txt into the local CodeQL image");
  }
  if (!/\bcat\s+\/tmp\/codeql-version\.txt\b/.test(dockerfileText)) {
    details.push("read CODEQL_VERSION from /tmp/codeql-version.txt before downloading the bundle");
  }

  if (details.length > 0) {
    fail("test/Dockerfile.codeql must consume test/codeql-version.txt.", details);
  }
}

function extractCodeqlActionVersion(workflowText) {
  const allActionVersions = [
    ...workflowText.matchAll(/\bgithub\/codeql-action\/[a-z-]+@(v\d+\.\d+\.\d+)\b/g),
  ].map((match) => match[1]);

  if (allActionVersions.length === 0) {
    fail("Could not read github/codeql-action versions from .github/workflows/security-sast.yml.");
  }

  const uniqueActionVersions = [...new Set(allActionVersions)];
  if (uniqueActionVersions.length > 1) {
    fail("CodeQL Action steps should use one pinned action version.", uniqueActionVersions);
  }

  const analysisActionVersions = [
    ...workflowText.matchAll(
      /\bgithub\/codeql-action\/(?:init|autobuild|analyze)@(v\d+\.\d+\.\d+)\b/g,
    ),
  ].map((match) => match[1]);

  if (analysisActionVersions.length === 0) {
    fail("Could not read CodeQL analysis action versions from .github/workflows/security-sast.yml.");
  }

  return uniqueActionVersions[0];
}

async function fetchCodeqlActionChangelog(actionVersion) {
  const changelogUrl = `https://raw.githubusercontent.com/github/codeql-action/${actionVersion}/CHANGELOG.md`;
  const response = await getHttpsText(changelogUrl);

  if (response.statusCode < 200 || response.statusCode >= 300) {
    fail("Could not fetch the CodeQL Action changelog for the pinned action version.", [
      `${changelogUrl}: HTTP ${response.statusCode}`,
    ]);
  }

  return {
    text: response.text,
    url: changelogUrl,
  };
}

function getHttpsText(url, redirectCount = 0) {
  if (redirectCount > 3) {
    return Promise.reject(new Error(`Too many redirects while fetching ${url}`));
  }

  return new Promise((resolve, reject) => {
    const request = https.get(
      url,
      {
        headers: {
          "User-Agent": "uade-codeql-version-sync",
        },
      },
      (response) => {
        const location = response.headers.location;
        if (
          response.statusCode >= 300 &&
          response.statusCode < 400 &&
          typeof location === "string" &&
          location.startsWith("https://")
        ) {
          response.resume();
          resolve(getHttpsText(location, redirectCount + 1));
          return;
        }

        response.setEncoding("utf8");
        let text = "";
        response.on("data", (chunk) => {
          text += chunk;
        });
        response.on("end", () => {
          resolve({
            statusCode: response.statusCode,
            text,
          });
        });
      },
    );

    request.setTimeout(30000, () => {
      request.destroy(new Error(`Timed out fetching ${url}`));
    });
    request.on("error", reject);
  });
}

function extractDefaultBundleVersion(changelogText, actionVersion) {
  const version = actionVersion.replace(/^v/, "");
  const headingPattern = new RegExp(`^##\\s+${version.replaceAll(".", "\\.")}\\s+-`, "m");
  const headingMatch = headingPattern.exec(changelogText);

  if (!headingMatch) {
    fail("Could not find the pinned CodeQL Action version in its changelog.", [
      `github/codeql-action@${actionVersion}`,
    ]);
  }

  const changelogFromPinnedVersion = changelogText.slice(headingMatch.index);
  const bundleMatch = changelogFromPinnedVersion.match(
    /\b(?:Update|Downgrade) default CodeQL bundle version to (?:\[(\d+\.\d+\.\d+)\]\([^)]+\)|(\d+\.\d+\.\d+))/,
  );

  if (!bundleMatch) {
    fail("Could not resolve the default CodeQL bundle version from the action changelog.", [
      `github/codeql-action@${actionVersion}`,
    ]);
  }

  return bundleMatch[1] || bundleMatch[2];
}

async function main() {
  const projectRoot = process.env.PROJECT_ROOT || process.cwd();
  const manifestPath = path.join(projectRoot, "test", "codeql-version.txt");
  const dockerfilePath = path.join(projectRoot, "test", "Dockerfile.codeql");
  const workflowPath = path.join(projectRoot, ".github", "workflows", "security-sast.yml");

  const [manifestText, dockerfileText, workflowText] = await Promise.all([
    readFile(manifestPath, "utf8"),
    readFile(dockerfilePath, "utf8"),
    readFile(workflowPath, "utf8"),
  ]);

  const localBundleVersion = readManifestVersion(manifestText);
  assertDockerfileUsesManifest(dockerfileText);

  const actionVersion = extractCodeqlActionVersion(workflowText);
  const changelog = await fetchCodeqlActionChangelog(actionVersion);
  const defaultBundleVersion = extractDefaultBundleVersion(changelog.text, actionVersion);

  if (localBundleVersion !== defaultBundleVersion) {
    fail("Local CodeQL bundle does not match the pinned CodeQL Action default bundle.", [
      `test/codeql-version.txt: ${localBundleVersion}`,
      `github/codeql-action@${actionVersion} default bundle: ${defaultBundleVersion}`,
      `source: ${changelog.url}`,
    ]);
  }

  console.log(
    `CodeQL bundle version is aligned with github/codeql-action@${actionVersion} default ${defaultBundleVersion}.`,
  );
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
