import http from "k6/http";
import { check, fail, sleep } from "k6";

const baseUrl = __ENV.BASE_URL || "http://uade-web-player:5000";
const fixturePath = __ENV.BENCH_FIXTURE_PATH || "/fixtures/modules/space_debris.mod";
const fixtureBytes = open(fixturePath, "b");
const fixtureName = __ENV.BENCH_FIXTURE_NAME || "space_debris.mod";

export const options = {
  scenarios: {
    cold_convert_probed: {
      executor: "shared-iterations",
      vus: 1,
      iterations: 5,
      exec: "coldConvertProbed",
      maxDuration: "3m",
    },
    warm_convert_probed: {
      executor: "shared-iterations",
      vus: 1,
      iterations: 5,
      exec: "warmConvertProbed",
      startTime: "40s",
      maxDuration: "2m",
    },
    warm_upload: {
      executor: "shared-iterations",
      vus: 1,
      iterations: 5,
      exec: "warmUpload",
      startTime: "46s",
      maxDuration: "2m",
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.01"],
    "http_req_duration{endpoint:probe-upload}": ["p(95)<1500"],
    "http_req_duration{endpoint:cold-convert-probed}": ["p(95)<6000"],
    "http_req_duration{endpoint:warm-convert-probed}": ["p(95)<250"],
    "http_req_duration{endpoint:warm-upload}": ["p(95)<100"],
    "checks{endpoint:cold-convert-probed}": ["rate==1"],
    "checks{endpoint:warm-convert-probed}": ["rate==1"],
    "checks{endpoint:warm-upload}": ["rate==1"],
    "checks{endpoint:probe-upload}": ["rate==1"],
  },
};

function uploadFixture(path, endpointTag) {
  const response = http.post(
    `${baseUrl}${path}`,
    {
      file: http.file(fixtureBytes, fixtureName, "application/octet-stream"),
    },
    {
      tags: { endpoint: endpointTag },
      timeout: "310s",
    },
  );

  let payload = null;
  try {
    payload = response.json();
  } catch {
    payload = null;
  }

  return { response, payload };
}

export function setup() {
  const probeResult = uploadFixture("/probe-upload", "probe-upload");
  if (!check(probeResult.response, {
    "probe-upload returned 200": (res) => res.status === 200,
  })) {
    fail(`probe-upload setup failed with status ${probeResult.response.status}`);
  }

  const moduleHash = probeResult.payload?.module_hash;
  if (!moduleHash) {
    fail("probe-upload setup did not return module_hash");
  }

  const warmupConvertResponse = http.post(
    `${baseUrl}/convert-probed`,
    JSON.stringify({ module_hash: moduleHash, filename: fixtureName }),
    {
      headers: { "Content-Type": "application/json" },
      tags: { endpoint: "setup-convert-probed" },
      timeout: "310s",
    },
  );

  if (!check(warmupConvertResponse, {
    "setup convert-probed returned 200": (res) => res.status === 200,
  })) {
    fail(`setup convert-probed failed with status ${warmupConvertResponse.status}`);
  }

  const fileId = warmupConvertResponse.json("file_id");
  const audioFormat = warmupConvertResponse.json("audio_format");
  if (!fileId || !audioFormat) {
    fail("setup convert-probed did not return file_id or audio_format");
  }

  const removeResponse = http.post(
    `${baseUrl}/test/remove-cache-artifact`,
    JSON.stringify({ file_id: fileId, ext: `.${audioFormat}` }),
    {
      headers: { "Content-Type": "application/json" },
      tags: { endpoint: "setup-remove-cache-artifact" },
      timeout: "60s",
    },
  );

  if (!check(removeResponse, {
    "setup remove-cache-artifact returned 200": (res) => res.status === 200,
  })) {
    fail(`setup remove-cache-artifact failed with status ${removeResponse.status}`);
  }

  return { moduleHash, fileId, audioFormat };
}

function removeArtifact(fileId, audioFormat, endpointTag) {
  const removeResponse = http.post(
    `${baseUrl}/test/remove-cache-artifact`,
    JSON.stringify({ file_id: fileId, ext: `.${audioFormat}` }),
    {
      headers: { "Content-Type": "application/json" },
      tags: { endpoint: endpointTag },
      timeout: "60s",
    },
  );

  if (!check(removeResponse, {
    "remove-cache-artifact returned 200": (res) => res.status === 200,
  })) {
    fail(`remove-cache-artifact failed with status ${removeResponse.status}`);
  }
}

function runConvertProbed(data, endpointTag) {
  const probeConvertResponse = http.post(
    `${baseUrl}/convert-probed`,
    JSON.stringify({ module_hash: data.moduleHash, filename: fixtureName }),
    {
      headers: { "Content-Type": "application/json" },
      tags: { endpoint: endpointTag },
      timeout: "310s",
    },
  );

  check(
    probeConvertResponse,
    {
      "convert-probed returned 200": (res) => res.status === 200,
      "convert-probed returned play_url": (res) => Boolean(res.json("play_url")),
    },
    { endpoint: endpointTag },
  );
}

export function coldConvertProbed(data) {
  removeArtifact(data.fileId, data.audioFormat, "cold-convert-probed-evict");
  runConvertProbed(data, "cold-convert-probed");
  sleep(1);
}

export function warmConvertProbed(data) {
  runConvertProbed(data, "warm-convert-probed");
  sleep(1);
}

export function warmUpload() {
  const uploadResult = uploadFixture("/upload", "warm-upload");
  check(
    uploadResult.response,
    {
      "upload returned 200": (res) => res.status === 200,
      "upload returned play_url": () => Boolean(uploadResult.payload?.play_url),
      "upload returned download_url": () => Boolean(uploadResult.payload?.download_url),
    },
    { endpoint: "warm-upload" },
  );

  sleep(1);
}
