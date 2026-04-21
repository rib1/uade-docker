import http from "k6/http";
import { check, fail, sleep } from "k6";
import { Counter, Trend } from "k6/metrics";

const baseUrl = __ENV.BASE_URL || "http://uade-web-player:5000";
const uploadFixturePath = __ENV.BENCH_UPLOAD_FIXTURE_PATH || "/fixtures/modules/space_debris.mod";
const uploadFixtureName = __ENV.BENCH_UPLOAD_FIXTURE_NAME || "space_debris.mod";
const uploadFixtureBytes = open(uploadFixturePath, "b");
const tfmxFixtureUrl =
  __ENV.BENCH_TFMX_FIXTURE_URL ||
  "http://uade-test-http-server:8000/fixtures/modules/mdat.turrican_2_level_0-intro";
const tfmxSampleUrl =
  __ENV.BENCH_TFMX_SAMPLE_URL ||
  "http://uade-test-http-server:8000/fixtures/modules/smpl.turrican_2_level_0-intro";
const convertUrlResponseCallback = http.expectedStatuses(200, 409);

const sameHashConvertDuration = new Trend("dast_same_hash_convert_duration", true);
const multiHashConvertUrlDuration = new Trend("dast_multi_hash_convert_url_duration", true);
const multiHashConvertProbedDuration = new Trend("dast_multi_hash_convert_probed_duration", true);
const burstConvertDuration = new Trend("dast_play_burst_convert_duration", true);
const burstPlayDuration = new Trend("dast_play_burst_play_duration", true);
const burstRangeDuration = new Trend("dast_play_burst_range_duration", true);
const sameHashRequests = new Counter("dast_same_hash_convert_requests");
const multiHashConvertUrlRequests = new Counter("dast_multi_hash_convert_url_requests");
const multiHashConvertProbedRequests = new Counter("dast_multi_hash_convert_probed_requests");
const burstConvertRequests = new Counter("dast_play_burst_convert_requests");
const burstPlayRequests = new Counter("dast_play_burst_play_requests");
const burstRangeRequests = new Counter("dast_play_burst_range_requests");

export const options = {
  scenarios: {
    same_hash_duplicate_waiters: {
      executor: "per-vu-iterations",
      vus: 4,
      iterations: 1,
      exec: "sameHashDuplicateWaiters",
      maxDuration: "2m",
    },
    multi_hash_convert_url: {
      executor: "shared-iterations",
      vus: 1,
      iterations: 1,
      exec: "multiHashConvertUrl",
      startTime: "30s",
      maxDuration: "2m",
    },
    multi_hash_convert_probed: {
      executor: "shared-iterations",
      vus: 1,
      iterations: 1,
      exec: "multiHashConvertProbed",
      startTime: "55s",
      maxDuration: "2m",
    },
    cold_to_warm_playback_burst: {
      executor: "shared-iterations",
      vus: 1,
      iterations: 1,
      exec: "coldToWarmPlaybackBurst",
      startTime: "1m15s",
      maxDuration: "3m",
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.01"],
    "checks{endpoint:dast-same-hash-convert}": ["rate==1"],
    "checks{endpoint:dast-same-hash-evict}": ["rate==1"],
    "checks{endpoint:dast-multi-hash-convert-url}": ["rate==1"],
    "checks{endpoint:dast-multi-hash-url-evict}": ["rate==1"],
    "checks{endpoint:dast-multi-hash-convert-probed}": ["rate==1"],
    "checks{endpoint:dast-multi-hash-probed-evict}": ["rate==1"],
    "checks{endpoint:dast-play-burst-convert}": ["rate==1"],
    "checks{endpoint:dast-play-burst-evict}": ["rate==1"],
    "checks{endpoint:dast-play-burst-play}": ["rate==1"],
    "checks{endpoint:dast-play-burst-range}": ["rate==1"],
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

function uploadFixture(path, endpointTag) {
  return http.post(
    `${baseUrl}${path}`,
    {
      file: http.file(uploadFixtureBytes, uploadFixtureName, "application/octet-stream"),
    },
    {
      tags: { endpoint: endpointTag },
      timeout: "310s",
    },
  );
}

function convertProbed(moduleHash, endpointTag) {
  return http.post(
    `${baseUrl}/convert-probed`,
    JSON.stringify({ module_hash: moduleHash, filename: uploadFixtureName }),
    {
      headers: jsonHeaders(),
      tags: { endpoint: endpointTag },
      timeout: "310s",
    },
  );
}

function convertUrl(endpointTag) {
  return http.post(
    `${baseUrl}/convert-url`,
    JSON.stringify({
      url: tfmxFixtureUrl,
      sample_url: tfmxSampleUrl,
    }),
    {
      headers: jsonHeaders(),
      responseCallback: convertUrlResponseCallback,
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

export function setup() {
  const probeResponse = uploadFixture("/probe-upload", "dast-setup-probe-upload");
  const probePayload = parseJson(probeResponse);
  requireCheck(
    probeResponse,
    {
      "dast setup probe-upload returned 200": (res) => res.status === 200,
      "dast setup probe-upload returned module_hash": () => Boolean(probePayload?.module_hash),
    },
    `DAST setup probe-upload failed with status ${probeResponse.status}`,
  );

  const warmConvertProbedResponse = convertProbed(
    probePayload.module_hash,
    "dast-setup-convert-probed",
  );
  const warmConvertProbedPayload = parseJson(warmConvertProbedResponse);
  requireCheck(
    warmConvertProbedResponse,
    {
      "dast setup convert-probed returned 200": (res) => res.status === 200,
      "dast setup convert-probed returned file_id": () => Boolean(warmConvertProbedPayload?.file_id),
      "dast setup convert-probed returned audio_format": () =>
        Boolean(warmConvertProbedPayload?.audio_format),
    },
    `DAST setup convert-probed failed with status ${warmConvertProbedResponse.status}`,
  );

  const warmConvertUrlResponse = convertUrl("dast-setup-convert-url");
  const warmConvertUrlPayload = parseJson(warmConvertUrlResponse);
  requireCheck(
    warmConvertUrlResponse,
    {
      "dast setup convert-url returned 200": (res) => res.status === 200,
      "dast setup convert-url returned file_id": () => Boolean(warmConvertUrlPayload?.file_id),
      "dast setup convert-url returned audio_format": () => Boolean(warmConvertUrlPayload?.audio_format),
    },
    `DAST setup convert-url failed with status ${warmConvertUrlResponse.status}`,
  );

  const sameHashEvictResponse = removeArtifact(
    warmConvertUrlPayload.file_id,
    `.${warmConvertUrlPayload.audio_format}`,
    "dast-setup-same-hash-evict",
  );
  if (
    !check(
      sameHashEvictResponse,
      {
        "dast setup same-hash eviction returned 200": (res) => res.status === 200,
      },
      { endpoint: "dast-same-hash-evict" },
    )
  ) {
    fail(
      `DAST setup same-hash eviction failed with status ${sameHashEvictResponse.status}`,
    );
  }

  return {
    probedModuleHash: probePayload.module_hash,
    probedFileId: warmConvertProbedPayload.file_id,
    probedAudioExt: `.${warmConvertProbedPayload.audio_format}`,
    tfmxFileId: warmConvertUrlPayload.file_id,
    tfmxAudioExt: `.${warmConvertUrlPayload.audio_format}`,
  };
}

export function sameHashDuplicateWaiters() {
  const response = convertUrl("dast-same-hash-convert");
  const payload = parseJson(response);
  sameHashConvertDuration.add(response.timings.duration);
  sameHashRequests.add(1);

  check(
    response,
    {
      "dast same-hash convert returned 200 or 409": (res) => res.status === 200 || res.status === 409,
      "dast same-hash convert returned play_url or processing state": () =>
        Boolean(payload?.play_url) || payload?.status === "processing",
    },
    { endpoint: "dast-same-hash-convert" },
  );
}

export function multiHashConvertUrl(data) {
  const removeResponse = removeArtifact(
    data.tfmxFileId,
    data.tfmxAudioExt,
    "dast-multi-hash-url-evict",
  );
  check(
    removeResponse,
    {
      "dast multi-hash url eviction returned 200": (res) => res.status === 200,
    },
    { endpoint: "dast-multi-hash-url-evict" },
  );

  const response = convertUrl("dast-multi-hash-convert-url");
  const payload = parseJson(response);
  multiHashConvertUrlDuration.add(response.timings.duration);
  multiHashConvertUrlRequests.add(1);

  check(
    response,
    {
      "dast multi-hash convert-url returned 200": (res) => res.status === 200,
      "dast multi-hash convert-url returned play_url": () => Boolean(payload?.play_url),
    },
    { endpoint: "dast-multi-hash-convert-url" },
  );
}

export function multiHashConvertProbed(data) {
  const removeResponse = removeArtifact(
    data.probedFileId,
    data.probedAudioExt,
    "dast-multi-hash-probed-evict",
  );
  check(
    removeResponse,
    {
      "dast multi-hash probed eviction returned 200": (res) => res.status === 200,
    },
    { endpoint: "dast-multi-hash-probed-evict" },
  );

  const response = convertProbed(data.probedModuleHash, "dast-multi-hash-convert-probed");
  const payload = parseJson(response);
  multiHashConvertProbedDuration.add(response.timings.duration);
  multiHashConvertProbedRequests.add(1);

  check(
    response,
    {
      "dast multi-hash convert-probed returned 200": (res) => res.status === 200,
      "dast multi-hash convert-probed returned play_url": () => Boolean(payload?.play_url),
    },
    { endpoint: "dast-multi-hash-convert-probed" },
  );
}

export function coldToWarmPlaybackBurst(data) {
  const removeResponse = removeArtifact(
    data.tfmxFileId,
    data.tfmxAudioExt,
    "dast-play-burst-evict",
  );
  check(
    removeResponse,
    {
      "dast play burst eviction returned 200": (res) => res.status === 200,
    },
    { endpoint: "dast-play-burst-evict" },
  );

  const convertResponse = convertUrl("dast-play-burst-convert");
  const convertPayload = parseJson(convertResponse);
  burstConvertDuration.add(convertResponse.timings.duration);
  burstConvertRequests.add(1);

  check(
    convertResponse,
    {
      "dast play burst convert returned 200": (res) => res.status === 200,
      "dast play burst convert returned play_url": () => Boolean(convertPayload?.play_url),
    },
    { endpoint: "dast-play-burst-convert" },
  );

  const playUrl = convertPayload?.play_url;
  if (!playUrl) {
    fail("DAST play burst convert did not return play_url");
  }

  for (let i = 0; i < 3; i += 1) {
    const playResponse = http.get(`${baseUrl}${playUrl}`, {
      tags: { endpoint: "dast-play-burst-play" },
      responseType: "none",
      timeout: "120s",
    });
    burstPlayDuration.add(playResponse.timings.duration);
    burstPlayRequests.add(1);
    check(
      playResponse,
      {
        "dast play burst full returned 200 or 206": (res) => res.status === 200 || res.status === 206,
        "dast play burst full advertised byte ranges": (res) =>
          res.headers["Accept-Ranges"] === "bytes",
      },
      { endpoint: "dast-play-burst-play" },
    );

    const rangeResponse = http.get(`${baseUrl}${playUrl}`, {
      headers: { Range: "bytes=0-4095" },
      tags: { endpoint: "dast-play-burst-range" },
      responseType: "none",
      timeout: "120s",
    });
    burstRangeDuration.add(rangeResponse.timings.duration);
    burstRangeRequests.add(1);
    check(
      rangeResponse,
      {
        "dast play burst range returned 206": (res) => res.status === 206,
        "dast play burst range reported content-range": (res) =>
          Boolean(res.headers["Content-Range"]),
      },
      { endpoint: "dast-play-burst-range" },
    );
  }

  sleep(1);
}
