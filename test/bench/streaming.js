import http from "k6/http";
import { check, fail, sleep } from "k6";

const baseUrl = __ENV.BASE_URL || "http://uade-web-player:5000";
const remoteFixtureUrl =
  __ENV.BENCH_REMOTE_FIXTURE_URL ||
  "http://uade-test-http-server:8000/fixtures/modules/mdat.turrican_2_level_0-intro";
const remoteSampleUrl =
  __ENV.BENCH_REMOTE_SAMPLE_URL ||
  "http://uade-test-http-server:8000/fixtures/modules/smpl.turrican_2_level_0-intro";

export const options = {
  scenarios: {
    full_file: {
      executor: "constant-vus",
      vus: 3,
      duration: "20s",
      exec: "streamFullFile",
    },
    range_request: {
      executor: "constant-vus",
      vus: 3,
      duration: "20s",
      exec: "streamRangeRequest",
      startTime: "2s",
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.01"],
    "http_req_duration{endpoint:play-full}": ["p(95)<4000"],
    "http_req_duration{endpoint:play-range}": ["p(95)<3500"],
    "checks{endpoint:play-full}": ["rate==1"],
    "checks{endpoint:play-range}": ["rate==1"],
  },
};

export function setup() {
  const uploadResponse = http.post(
    `${baseUrl}/convert-url`,
    JSON.stringify({
      url: remoteFixtureUrl,
      sample_url: remoteSampleUrl,
    }),
    {
      headers: { "Content-Type": "application/json" },
      tags: { endpoint: "upload-for-streaming" },
      timeout: "310s",
    },
  );

  let payload = null;
  try {
    payload = uploadResponse.json();
  } catch {
    payload = null;
  }

  if (!check(uploadResponse, {
    "streaming setup convert-url returned 200": (res) => res.status === 200,
  })) {
    fail(`streaming setup convert-url failed with status ${uploadResponse.status}`);
  }

  const playUrl = payload?.play_url;
  if (!playUrl) {
    fail("streaming setup convert-url did not return play_url");
  }

  return { playUrl };
}

export function streamFullFile(data) {
  const response = http.get(`${baseUrl}${data.playUrl}`, {
    tags: { endpoint: "play-full" },
    responseType: "none",
  });

  check(
    response,
    {
      "play full returned 200 or 206": (res) => res.status === 200 || res.status === 206,
      "play full advertised byte ranges": (res) => res.headers["Accept-Ranges"] === "bytes",
      "play full exposed single-range hint when partial": (res) =>
        res.status !== 206 || res.headers["X-Single-Range-Only"] === "true",
    },
    { endpoint: "play-full" },
  );

  sleep(1);
}

export function streamRangeRequest(data) {
  const response = http.get(`${baseUrl}${data.playUrl}`, {
    headers: { Range: "bytes=0-4095" },
    tags: { endpoint: "play-range" },
    responseType: "none",
  });

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
