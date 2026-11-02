// load-tests/common.js
import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

export const applicationErrors = new Rate('app_error_rate');
export const overloadResponses = new Counter('overload_503_total');
export const queueWait = new Trend('queue_wait_seconds', true);
export const appProcessing = new Trend('app_processing_seconds', true);

function numberEnv(name, fallback, min, max) {
  const value = __ENV[name] === undefined ? fallback : Number(__ENV[name]);
  if (!Number.isFinite(value) || value < min || value > max) {
    throw new Error(`${name} must be between ${min} and ${max}`);
  }
  return value;
}

export const config = Object.freeze({
  baseUrl: (__ENV.BASE_URL || 'http://127.0.0.1:8000').replace(/\/+$/, ''),
  endpoint: (__ENV.ENDPOINT || 'queue').toLowerCase(),
  iterations: Math.round(numberEnv('ITERATIONS', 1000000, 1000, 20000000)),
  workTime: numberEnv('WORK_TIME', 0.5, 0.05, 10),
  queueLimit: Math.round(numberEnv('MAX_QUEUE_LIMIT', 100, 1, 1000)),
  timeout: numberEnv('REQUEST_TIMEOUT_SECONDS', 30, 1, 300),
  rate: numberEnv('RATE', 10, 1, 10000),
  maxVus: Math.round(numberEnv('MAX_VUS', 150, 1, 5000)),
});
if (!['cpu', 'queue'].includes(config.endpoint)) throw new Error('ENDPOINT must be cpu or queue');

export function requestWorkload() {
  const path = config.endpoint === 'cpu'
    ? `/api/cpu?iterations=${config.iterations}`
    : `/api/queue?work_time=${config.workTime}&max_queue_limit=${config.queueLimit}`;
  const res = http.get(`${config.baseUrl}${path}`, {
    timeout: `${config.timeout}s`,
    tags: { workload_endpoint: config.endpoint },
  });
  const ok = res.status === 200;
  applicationErrors.add(!ok);
  if (res.status === 503) overloadResponses.add(1);
  check(res, {
    'HTTP 200': (r) => r.status === 200,
    'response body agrees with endpoint': (r) => {
      if (r.status !== 200) return false;
      try { return r.json('endpoint') === config.endpoint; } catch (_) { return false; }
    },
  });
  if (ok) {
    try {
      const body = res.json();
      if (config.endpoint === 'queue' && Number.isFinite(body.queue_wait_seconds))
        queueWait.add(body.queue_wait_seconds);
      if (config.endpoint === 'cpu' && Number.isFinite(body.processing_time_seconds))
        appProcessing.add(body.processing_time_seconds);
    } catch (_) { /* HTTP validation above already detects invalid JSON */ }
  }
}

export function workloadThresholds(fault = false) {
  return {
    'http_req_duration': ['p(95)<30000'],
    'http_req_failed': [fault ? 'rate<1' : 'rate<0.8'],
    'dropped_iterations': ['count<1000000000'],
  };
}

export function saveSummary(data) {
  const filename = __ENV.SUMMARY_FILE || 'summary.json';
  return { [filename]: JSON.stringify(data, null, 2) };
}
