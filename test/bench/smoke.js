import http from "k6/http";
import { check, sleep } from "k6";

const baseUrl = __ENV.BASE_URL || "http://uade-web-player:5000";

export const options = {
  vus: 4,
  duration: "30s",
  thresholds: {
    checks: ["rate==1"],
    http_req_failed: ["rate<0.01"],
    http_req_duration: ["p(95)<200"],
    "http_req_duration{endpoint:health}": ["p(95)<100"],
    "http_req_duration{endpoint:index}": ["p(95)<250"],
    "http_req_duration{endpoint:client-config}": ["p(95)<150"],
    "http_req_duration{endpoint:supported-extensions}": ["p(95)<150"],
  },
};

const requests = [
  { name: "health", path: "/health", expectedStatus: 200, bodyCheck: "\"status\":\"healthy\"" },
  { name: "index", path: "/", expectedStatus: 200, bodyCheck: "UADE Web Player" },
  {
    name: "client-config",
    path: "/client-config.js",
    expectedStatus: 200,
    bodyCheck: "window.__UADE_CONFIG__",
  },
  {
    name: "supported-extensions",
    path: "/supported-extensions",
    expectedStatus: 200,
    bodyCheck: ".mod",
  },
];

export default function () {
  for (const requestDef of requests) {
    const response = http.get(`${baseUrl}${requestDef.path}`, {
      tags: { endpoint: requestDef.name },
    });

    check(response, {
      [`${requestDef.name} returned ${requestDef.expectedStatus}`]: (res) =>
        res.status === requestDef.expectedStatus,
      [`${requestDef.name} body contained expected marker`]: (res) =>
        res.body.includes(requestDef.bodyCheck),
    });
  }

  sleep(1);
}
