import http from "k6/http";
import { check, fail, sleep } from "k6";
import { Counter, Trend } from "k6/metrics";

const baseUrl = __ENV.BASE_URL || "http://uade-web-player:5000";
const modFixturePath = __ENV.BENCH_FIXTURE_PATH || "/fixtures/modules/space_debris.mod";
const modFixtureBytes = open(modFixturePath, "b");
const modFixtureName = __ENV.BENCH_FIXTURE_NAME || "space_debris.mod";
const tfmxFixtureUrl =
  __ENV.BENCH_REMOTE_FIXTURE_URL ||
  "http://uade-test-http-server:8000/fixtures/modules/mdat.turrican_2_level_0-intro";
const tfmxSampleUrl =
  __ENV.BENCH_REMOTE_SAMPLE_URL ||
  "http://uade-test-http-server:8000/fixtures/modules/smpl.turrican_2_level_0-intro";
const playExampleId = __ENV.PLAY_EXAMPLE_ID || "wings-of-death-levels";
const scenarioDuration = __ENV.BENCH_SCENARIO_DURATION || "8m";
const playFullVus = Number(__ENV.PLAY_FULL_VUS || 4);
const playRangeVus = Number(__ENV.PLAY_RANGE_VUS || 2);
const convertProbedVus = Number(__ENV.CONVERT_PROBED_VUS || 1);
const convertUrlVus = Number(__ENV.CONVERT_URL_VUS || 1);

const playFullDuration = new Trend("play_full_duration", true);
const playRangeDuration = new Trend("play_range_duration", true);
const coldConvertProbedDuration = new Trend("cold_convert_probed_duration", true);
const coldConvertUrlDuration = new Trend("cold_convert_url_duration", true);
const playFullRequests = new Counter("play_full_requests");
const playRangeRequests = new Counter("play_range_requests");
const coldConvertProbedRequests = new Counter("cold_convert_probed_requests");
const coldConvertUrlRequests = new Counter("cold_convert_url_requests");

export const options = {
  scenarios: {
    play_full: {
      executor: "constant-vus",
      vus: playFullVus,
      duration: scenarioDuration,
      exec: "streamFullFile",
    },
    play_range: {
      executor: "constant-vus",
      vus: playRangeVus,
      duration: scenarioDuration,
      exec: "streamRangeRequest",
    },
    convert_probed_cold: {
      executor: "constant-vus",
      vus: convertProbedVus,
      duration: scenarioDuration,
      exec: "coldConvertProbed",
    },
    convert_url_cold: {
      executor: "constant-vus",
      vus: convertUrlVus,
      duration: scenarioDuration,
      exec: "coldConvertUrl",
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.01"],
    "checks{endpoint:play-full}": ["rate==1"],
    "checks{endpoint:play-range}": ["rate==1"],
    "checks{endpoint:cold-convert-probed}": ["rate==1"],
    "checks{endpoint:cold-convert-url}": ["rate==1"],
  },
};

function jsonHeaders(extraHeaders) {
  return {
    "Content-Type": "application/json",
    ...extraHeaders,
  };
}

function parseJson(response) {
  try {
    return response.json();
  } catch {
    return null;
  }
}

function requireCheck(response, checks, failureMessage) {
  if (!check(response, checks)) {
    fail(failureMessage);
  }
}

function uploadFixtureForProbe() {
  return http.post(
    `${baseUrl}/probe-upload`,
    {
      file: http.file(modFixtureBytes, modFixtureName, "application/octet-stream"),
    },
    {
      tags: { endpoint: "setup-probe-upload" },
      timeout: "310s",
    },
  );
}

function convertProbed(moduleHash) {
  return http.post(
    `${baseUrl}/convert-probed`,
    JSON.stringify({ module_hash: moduleHash, filename: modFixtureName }),
    {
      headers: jsonHeaders(),
      tags: { endpoint: "cold-convert-probed" },
      timeout: "310s",
    },
  );
}

function convertTfmx(endpointTag) {
  return http.post(
    `${baseUrl}/convert-url`,
    JSON.stringify({
      url: tfmxFixtureUrl,
      sample_url: tfmxSampleUrl,
    }),
    {
      headers: jsonHeaders(),
      tags: { endpoint: endpointTag },
      timeout: "310s",
    },
  );
}

function removeArtifact(fileId, ext, endpointTag) {
  return http.post(
    `${baseUrl}/test/remove-cache-artifact`,
    JSON.stringify({ file_id: fileId, ext }),
    {
      headers: jsonHeaders(),
      tags: { endpoint: endpointTag },
      timeout: "60s",
    },
  );
}

function warmStreamingTarget() {
  const response = http.post(
    `${baseUrl}/play-example/${playExampleId}`,
    "{}",
    {
      headers: jsonHeaders(),
      tags: { endpoint: "setup-play-example" },
      timeout: "310s",
    },
  );
  const payload = parseJson(response);

  requireCheck(
    response,
    {
      "setup play-example returned 200": (res) => res.status === 200,
      "setup play-example returned play_url": () => Boolean(payload?.play_url),
    },
    `streaming target setup failed with status ${response.status}`,
  );

  return payload;
}

export function setup() {
  const probeResponse = uploadFixtureForProbe();
  const probePayload = parseJson(probeResponse);

  requireCheck(
    probeResponse,
    {
      "setup probe-upload returned 200": (res) => res.status === 200,
      "setup probe-upload returned module_hash": () => Boolean(probePayload?.module_hash),
    },
    `probe-upload setup failed with status ${probeResponse.status}`,
  );

  const moduleHash = probePayload.module_hash;

  const warmConvertProbedResponse = convertProbed(moduleHash);
  const warmConvertProbedPayload = parseJson(warmConvertProbedResponse);

  requireCheck(
    warmConvertProbedResponse,
    {
      "setup convert-probed returned 200": (res) => res.status === 200,
      "setup convert-probed returned file_id": () => Boolean(warmConvertProbedPayload?.file_id),
      "setup convert-probed returned audio_format": () =>
        Boolean(warmConvertProbedPayload?.audio_format),
    },
    `convert-probed setup failed with status ${warmConvertProbedResponse.status}`,
  );

  const removeProbedResponse = removeArtifact(
    warmConvertProbedPayload.file_id,
    `.${warmConvertProbedPayload.audio_format}`,
    "setup-remove-convert-probed",
  );

  requireCheck(
    removeProbedResponse,
    {
      "setup remove probed artifact returned 200": (res) => res.status === 200,
    },
    `remove-cache-artifact for probed setup failed with status ${removeProbedResponse.status}`,
  );

  const streamingPayload = warmStreamingTarget();

  const warmConvertUrlResponse = convertTfmx("setup-convert-url");
  const warmConvertUrlPayload = parseJson(warmConvertUrlResponse);

  requireCheck(
    warmConvertUrlResponse,
    {
      "setup convert-url returned 200": (res) => res.status === 200,
      "setup convert-url returned file_id": () => Boolean(warmConvertUrlPayload?.file_id),
      "setup convert-url returned audio_format": () => Boolean(warmConvertUrlPayload?.audio_format),
    },
    `convert-url setup failed with status ${warmConvertUrlResponse.status}`,
  );

  const removeConvertUrlResponse = removeArtifact(
    warmConvertUrlPayload.file_id,
    `.${warmConvertUrlPayload.audio_format}`,
    "setup-remove-convert-url",
  );

  requireCheck(
    removeConvertUrlResponse,
    {
      "setup remove convert-url artifact returned 200": (res) => res.status === 200,
    },
    `remove-cache-artifact for convert-url setup failed with status ${removeConvertUrlResponse.status}`,
  );

  return {
    streamPlayUrl: streamingPayload.play_url,
    probedModuleHash: moduleHash,
    probedFileId: warmConvertProbedPayload.file_id,
    probedAudioExt: `.${warmConvertProbedPayload.audio_format}`,
    tfmxFileId: warmConvertUrlPayload.file_id,
    tfmxAudioExt: `.${warmConvertUrlPayload.audio_format}`,
  };
}

export function streamFullFile(data) {
  const response = http.get(`${baseUrl}${data.streamPlayUrl}`, {
    tags: { endpoint: "play-full" },
    responseType: "none",
  });
  playFullDuration.add(response.timings.duration);
  playFullRequests.add(1);

  check(
    response,
    {
      "play full returned 200 or 206": (res) => res.status === 200 || res.status === 206,
      "play full advertised byte ranges": (res) => res.headers["Accept-Ranges"] === "bytes",
    },
    { endpoint: "play-full" },
  );

  sleep(1);
}

export function streamRangeRequest(data) {
  const response = http.get(`${baseUrl}${data.streamPlayUrl}`, {
    headers: { Range: "bytes=0-4095" },
    tags: { endpoint: "play-range" },
    responseType: "none",
  });
  playRangeDuration.add(response.timings.duration);
  playRangeRequests.add(1);

  check(
    response,
    {
      "play range returned 206": (res) => res.status === 206,
      "play range reported content-range": (res) => Boolean(res.headers["Content-Range"]),
    },
    { endpoint: "play-range" },
  );

  sleep(1);
}

export function coldConvertProbed(data) {
  const removeResponse = removeArtifact(
    data.probedFileId,
    data.probedAudioExt,
    "cold-convert-probed-evict",
  );
  check(
    removeResponse,
    {
      "cold convert-probed eviction returned 200": (res) => res.status === 200,
    },
    { endpoint: "cold-convert-probed" },
  );

  const response = convertProbed(data.probedModuleHash);
  const payload = parseJson(response);
  coldConvertProbedDuration.add(response.timings.duration);
  coldConvertProbedRequests.add(1);

  check(
    response,
    {
      "cold convert-probed returned 200": (res) => res.status === 200,
      "cold convert-probed returned play_url": () => Boolean(payload?.play_url),
    },
    { endpoint: "cold-convert-probed" },
  );

  sleep(1);
}

export function coldConvertUrl(data) {
  const removeResponse = removeArtifact(data.tfmxFileId, data.tfmxAudioExt, "cold-convert-url-evict");
  check(
    removeResponse,
    {
      "cold convert-url eviction returned 200": (res) => res.status === 200,
    },
    { endpoint: "cold-convert-url" },
  );

  const response = convertTfmx("cold-convert-url");
  const payload = parseJson(response);
  coldConvertUrlDuration.add(response.timings.duration);
  coldConvertUrlRequests.add(1);

  check(
    response,
    {
      "cold convert-url returned 200": (res) => res.status === 200,
      "cold convert-url returned play_url": () => Boolean(payload?.play_url),
    },
    { endpoint: "cold-convert-url" },
  );

  sleep(1);
}
