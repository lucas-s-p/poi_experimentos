// Carga em taxa constante (open model): RATE req/s durante DURATION, independente da latência.
// Variáveis: BASE_URL, QUERY (ex. "iterations=100000"), RATE, DURATION, MAX_VUS, SUMMARY (caminho do JSON)
import http from 'k6/http';
import { check } from 'k6';

const RATE = Number(__ENV.RATE || 10);
const MAX_VUS = Number(__ENV.MAX_VUS || 500);

export const options = {
  discardResponseBodies: true,
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(90)', 'p(95)', 'p(99)'],
  scenarios: {
    work: {
      executor: 'constant-arrival-rate',
      rate: Math.round(RATE * 100),   // permite taxa fracionária (ex. 12.5 req/s)
      timeUnit: '100s',
      duration: __ENV.DURATION || '30s',
      preAllocatedVUs: Math.min(MAX_VUS, Math.max(10, Math.ceil(RATE * 2))),
      maxVUs: MAX_VUS,
    },
  },
};

const url = `${__ENV.BASE_URL}/work?${__ENV.QUERY || ''}`;

export default function () {
  const res = http.get(url, { timeout: '30s' });
  check(res, { 'status 200': (r) => r.status === 200 });
}

export function handleSummary(data) {
  const out = {};
  if (__ENV.SUMMARY) out[__ENV.SUMMARY] = JSON.stringify(data, null, 2);
  return out;
}
