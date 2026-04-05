import { readFile } from "node:fs/promises";
import path from "node:path";

async function main() {
  const projectRoot = process.env.PROJECT_ROOT || process.cwd();
  const packageJsonPath = path.join(projectRoot, "test", "package.json");
  const toolingManifestPath = path.join(projectRoot, "test", "docker-compose.tooling.yml");

  const packageJson = JSON.parse(await readFile(packageJsonPath, "utf8"));
  const playwrightVersion = packageJson.devDependencies["playwright-core"];

  const toolingManifest = await readFile(toolingManifestPath, "utf8");
  const imageTagMatch = toolingManifest.match(
    /^    image:\s*mcr\.microsoft\.com\/playwright:v([^\s-]+)-/m,
  );

  if (!playwrightVersion) {
    console.error("ERROR: Could not read playwright-core from test/package.json.");
    process.exit(1);
  }

  if (!imageTagMatch) {
    console.error(
      "ERROR: Could not read the Playwright image tag from test/docker-compose.tooling.yml.",
    );
    process.exit(1);
  }

  const imageVersion = imageTagMatch[1];

  if (playwrightVersion !== imageVersion) {
    console.error("ERROR: Playwright version mismatch.");
    console.error(`  test/package.json playwright-core: ${playwrightVersion}`);
    console.error(`  test/docker-compose.tooling.yml image tag: ${imageVersion}`);
    process.exit(1);
  }

  console.log(`Playwright tooling versions are aligned at ${playwrightVersion}.`);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
