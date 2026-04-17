import http from "k6/http";
import { check, fail, sleep } from "k6";

const baseUrl = __ENV.BASE_URL || "http://uade-web-player:5000";
const remoteFixtureUrl =
  __ENV.BENCH_REMOTE_FIXTURE_URL ||
  "http://uade-test-http-server:8000/fixtures/modules/space_debris.mod";

export const options = {
  vus: 2,
  iterations: 6,
  thresholds: {
    http_req_failed: ["rate<0.01"],
    "http_req_duration{endpoint:convert-url-cache-hit}": ["p(95)<1500"],
    "checks{endpoint:convert-url-cache-hit}": ["rate==1"],
  },
};

function convertUrl(url, sampleUrl, endpointTag) {
  const payload = { url };
  if (sampleUrl) {
    payload.sample_url = sampleUrl;
  }

  const response = http.post(`${baseUrl}/convert-url`, JSON.stringify(payload), {
    headers: { "Content-Type": "application/json" },
    tags: { endpoint: endpointTag },
    timeout: "310s",
  });

  let responseJson = null;
  try {
    responseJson = response.json();
  } catch {
    responseJson = null;
  }

  return { response, responseJson };
}

function buildUniqueFixtureUrl(url) {
  const separator = url.includes("?") ? "&" : "?";
  return `${url}${separator}bench-cache-run=${Date.now()}`;
}

export function setup() {
  const uniqueFixtureUrl = buildUniqueFixtureUrl(remoteFixtureUrl);
  const warmup = convertUrl(uniqueFixtureUrl, "", "convert-url-cache-warmup");

  if (!check(warmup.response, { "cache warmup returned 200": (res) => res.status === 200 })) {
    fail(`cache warmup failed with status ${warmup.response.status}`);
  }

  if (!check(warmup.responseJson, { "cache warmup started as cache miss": (body) => body?.url_cached === false })) {
    fail("cache warmup did not report url_cached=false on the initial request");
  }

  return { remoteFixtureUrl: uniqueFixtureUrl };
}

export default function (data) {
  const cacheHit = convertUrl(data.remoteFixtureUrl, "", "convert-url-cache-hit");

  check(
    cacheHit.response,
    {
      "cache hit returned 200": (res) => res.status === 200,
      "cache hit reported url_cached true": () => cacheHit.responseJson?.url_cached === true,
      "cache hit reported converted cache true": () => cacheHit.responseJson?.cached === true,
      "cache hit returned play_url": () => Boolean(cacheHit.responseJson?.play_url),
      "cache hit returned download_url": () => Boolean(cacheHit.responseJson?.download_url),
    },
    { endpoint: "convert-url-cache-hit" },
  );

  sleep(1);
}
