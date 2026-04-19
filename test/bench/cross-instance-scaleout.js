import http from "k6/http";
import { check, fail } from "k6";
import { Counter, Trend } from "k6/metrics";

const baseUrlA = __ENV.BASE_URL_A || "http://uade-web-a:5000";
const baseUrlB = __ENV.BASE_URL_B || "http://uade-web-b:5000";
const modFixturePath = __ENV.BENCH_FIXTURE_PATH || "/fixtures/modules/space_debris.mod";
const modFixtureBytes = open(modFixturePath, "b");
const modFixtureName = __ENV.BENCH_FIXTURE_NAME || "space_debris.mod";
const streamFixtureUrl =
  __ENV.BENCH_STREAM_FIXTURE_URL ||
  "http://uade-test-http-server:8000/fixtures/modules/stormlord.ahx";
const tfmxFixtureUrl =
  __ENV.BENCH_REMOTE_FIXTURE_URL ||
  "http://uade-test-http-server:8000/fixtures/modules/mdat.turrican_2_level_0-intro";
const tfmxSampleUrl =
  __ENV.BENCH_REMOTE_SAMPLE_URL ||
  "http://uade-test-http-server:8000/fixtures/modules/smpl.turrican_2_level_0-intro";
const scenarioDuration = __ENV.BENCH_SCENARIO_DURATION || "5m";
const playFullVus = Number(__ENV.PLAY_FULL_VUS || 3);
const playRangeVus = Number(__ENV.PLAY_RANGE_VUS || 1);
const convertProbedVus = Number(__ENV.CONVERT_PROBED_VUS || 3);
const convertUrlVus = Number(__ENV.CONVERT_URL_VUS || 3);

const playFullOnBDuration = new Trend("cross_instance_play_full_b_duration", true);
const playRangeOnBDuration = new Trend("cross_instance_play_range_b_duration", true);
const coldConvertProbedOnADuration = new Trend("cross_instance_convert_probed_a_duration", true);
const coldConvertUrlOnADuration = new Trend("cross_instance_convert_url_a_duration", true);
const playFullOnBRequests = new Counter("cross_instance_play_full_b_requests");
const playRangeOnBRequests = new Counter("cross_instance_play_range_b_requests");
const coldConvertProbedOnARequests = new Counter("cross_instance_convert_probed_a_requests");
const coldConvertUrlOnARequests = new Counter("cross_instance_convert_url_a_requests");
const convertResponseCallback = http.expectedStatuses(200, 409);

export const options = {
  scenarios: {
    play_full_b: {
      executor: "constant-vus",
      vus: playFullVus,
      duration: scenarioDuration,
      exec: "streamFullFileOnB",
    },
    play_range_b: {
      executor: "constant-vus",
      vus: playRangeVus,
      duration: scenarioDuration,
      exec: "streamRangeRequestOnB",
    },
    convert_probed_a: {
      executor: "constant-vus",
      vus: convertProbedVus,
      duration: scenarioDuration,
      exec: "coldConvertProbedOnA",
    },
    convert_url_a: {
      executor: "constant-vus",
      vus: convertUrlVus,
      duration: scenarioDuration,
      exec: "coldConvertUrlOnA",
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.01"],
    "checks{endpoint:cross-play-full-b}": ["rate==1"],
    "checks{endpoint:cross-play-range-b}": ["rate==1"],
    "checks{endpoint:cross-convert-probed-a}": ["rate==1"],
    "checks{endpoint:cross-convert-url-a}": ["rate==1"],
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

function uploadFixtureForProbe(baseUrl) {
  return http.post(
    `${baseUrl}/probe-upload`,
    {
      file: http.file(modFixtureBytes, modFixtureName, "application/octet-stream"),
    },
    {
      tags: { endpoint: "cross-setup-probe-upload-a" },
      timeout: "310s",
    },
  );
}

function convertProbed(baseUrl, moduleHash, endpointTag) {
  return http.post(
    `${baseUrl}/convert-probed`,
    JSON.stringify({ module_hash: moduleHash, filename: modFixtureName }),
    {
      headers: jsonHeaders(),
      responseCallback: convertResponseCallback,
      tags: { endpoint: endpointTag },
      timeout: "310s",
    },
  );
}

function convertTfmx(baseUrl, endpointTag) {
  return http.post(
    `${baseUrl}/convert-url`,
    JSON.stringify({
      url: tfmxFixtureUrl,
      sample_url: tfmxSampleUrl,
    }),
    {
      headers: jsonHeaders(),
      responseCallback: convertResponseCallback,
      tags: { endpoint: endpointTag },
      timeout: "310s",
    },
  );
}

function convertStreamingTarget(baseUrl, endpointTag) {
  return http.post(
    `${baseUrl}/convert-url`,
    JSON.stringify({
      url: streamFixtureUrl,
    }),
    {
      headers: jsonHeaders(),
      responseCallback: convertResponseCallback,
      tags: { endpoint: endpointTag },
      timeout: "310s",
    },
  );
}

function removeArtifact(baseUrl, fileId, ext, endpointTag) {
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

function evictArtifactForColdIteration(baseUrl, fileId, ext, endpointTag, failureMessage) {
  const response = removeArtifact(baseUrl, fileId, ext, endpointTag);
  requireCheck(
    response,
    {
      "artifact eviction returned 200": (res) => res.status === 200,
    },
    failureMessage,
  );
}

export function setup() {
  const probeResponse = uploadFixtureForProbe(baseUrlA);
  const probePayload = parseJson(probeResponse);

  requireCheck(
    probeResponse,
    {
      "setup probe-upload on A returned 200": (res) => res.status === 200,
      "setup probe-upload on A returned module_hash": () => Boolean(probePayload?.module_hash),
    },
    `probe-upload setup on A failed with status ${probeResponse.status}`,
  );

  const moduleHash = probePayload.module_hash;

  const warmConvertProbedResponse = convertProbed(baseUrlA, moduleHash, "cross-setup-convert-probed-a");
  const warmConvertProbedPayload = parseJson(warmConvertProbedResponse);

  requireCheck(
    warmConvertProbedResponse,
    {
      "setup convert-probed on A returned 200": (res) => res.status === 200,
      "setup convert-probed on A returned file_id": () => Boolean(warmConvertProbedPayload?.file_id),
      "setup convert-probed on A returned audio_format": () =>
        Boolean(warmConvertProbedPayload?.audio_format),
    },
    `convert-probed setup on A failed with status ${warmConvertProbedResponse.status}`,
  );

  const removeProbedResponse = removeArtifact(
    baseUrlA,
    warmConvertProbedPayload.file_id,
    `.${warmConvertProbedPayload.audio_format}`,
    "cross-setup-remove-convert-probed-a",
  );

  requireCheck(
    removeProbedResponse,
    {
      "setup remove convert-probed artifact on A returned 200": (res) => res.status === 200,
    },
    `remove-cache-artifact for convert-probed setup on A failed with status ${removeProbedResponse.status}`,
  );

  const warmStreamingResponse = convertStreamingTarget(baseUrlB, "cross-setup-stream-play-target-b");
  const warmStreamingPayload = parseJson(warmStreamingResponse);

  requireCheck(
    warmStreamingResponse,
    {
      "setup stream target on B returned 200": (res) => res.status === 200,
      "setup stream target on B returned play_url": () => Boolean(warmStreamingPayload?.play_url),
    },
    `stream target setup on B failed with status ${warmStreamingResponse.status}`,
  );

  const warmConvertUrlResponse = convertTfmx(baseUrlA, "cross-setup-convert-url-a");
  const warmConvertUrlPayload = parseJson(warmConvertUrlResponse);

  requireCheck(
    warmConvertUrlResponse,
    {
      "setup convert-url on A returned 200": (res) => res.status === 200,
      "setup convert-url on A returned file_id": () => Boolean(warmConvertUrlPayload?.file_id),
      "setup convert-url on A returned audio_format": () => Boolean(warmConvertUrlPayload?.audio_format),
    },
    `convert-url setup on A failed with status ${warmConvertUrlResponse.status}`,
  );

  const removeConvertUrlResponse = removeArtifact(
    baseUrlA,
    warmConvertUrlPayload.file_id,
    `.${warmConvertUrlPayload.audio_format}`,
    "cross-setup-remove-convert-url-a",
  );

  requireCheck(
    removeConvertUrlResponse,
    {
      "setup remove convert-url artifact on A returned 200": (res) => res.status === 200,
    },
    `remove-cache-artifact for convert-url setup on A failed with status ${removeConvertUrlResponse.status}`,
  );

  return {
    probedModuleHash: moduleHash,
    probedFileIdOnA: warmConvertProbedPayload.file_id,
    probedAudioFormatOnA: warmConvertProbedPayload.audio_format,
    convertUrlFileIdOnA: warmConvertUrlPayload.file_id,
    convertUrlAudioFormatOnA: warmConvertUrlPayload.audio_format,
    playUrlOnB: warmStreamingPayload.play_url,
  };
}

export function streamFullFileOnB(data) {
  const response = http.get(`${baseUrlB}${data.playUrlOnB}`, {
    tags: { endpoint: "cross-play-full-b" },
    responseType: "none",
  });
  playFullOnBDuration.add(response.timings.duration);
  playFullOnBRequests.add(1);

  check(response, {
    "play full on B returned 200 or 206": (res) => res.status === 200 || res.status === 206,
    "play full on B advertised byte ranges": (res) => res.headers["Accept-Ranges"] === "bytes",
  });
}

export function streamRangeRequestOnB(data) {
  const response = http.get(`${baseUrlB}${data.playUrlOnB}`, {
    headers: { Range: "bytes=0-65535" },
    tags: { endpoint: "cross-play-range-b" },
    responseType: "none",
  });
  playRangeOnBDuration.add(response.timings.duration);
  playRangeOnBRequests.add(1);

  check(response, {
    "play range on B returned 206": (res) => res.status === 206,
    "play range on B reported content-range": (res) => Boolean(res.headers["Content-Range"]),
  });
}

export function coldConvertProbedOnA(data) {
  evictArtifactForColdIteration(
    baseUrlA,
    data.probedFileIdOnA,
    `.${data.probedAudioFormatOnA}`,
    "cross-evict-convert-probed-a",
    "artifact eviction before cold convert-probed on A failed",
  );
  const response = convertProbed(baseUrlA, data.probedModuleHash, "cross-convert-probed-a");
  const payload = parseJson(response);

  coldConvertProbedOnADuration.add(response.timings.duration);
  coldConvertProbedOnARequests.add(1);

  requireCheck(
    response,
    {
      "cold convert-probed on A returned 200 or 409": (res) =>
        res.status === 200 || res.status === 409,
      "cold convert-probed on A returned play_url or processing": () =>
        Boolean(payload?.play_url) || payload?.status === "processing",
    },
    `cold convert-probed on A failed with status ${response.status}`,
  );
}

export function coldConvertUrlOnA(data) {
  evictArtifactForColdIteration(
    baseUrlA,
    data.convertUrlFileIdOnA,
    `.${data.convertUrlAudioFormatOnA}`,
    "cross-evict-convert-url-a",
    "artifact eviction before cold convert-url on A failed",
  );
  const response = convertTfmx(baseUrlA, "cross-convert-url-a");
  const payload = parseJson(response);

  coldConvertUrlOnADuration.add(response.timings.duration);
  coldConvertUrlOnARequests.add(1);

  requireCheck(
    response,
    {
      "cold convert-url on A returned 200 or 409": (res) =>
        res.status === 200 || res.status === 409,
      "cold convert-url on A returned play_url or processing": () =>
        Boolean(payload?.play_url) || payload?.status === "processing",
    },
    `cold convert-url on A failed with status ${response.status}`,
  );
}
