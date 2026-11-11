// load-tests/step-workload.js
import { config, requestWorkload, saveSummary, workloadThresholds } from './common.js';

export const options = {
  scenarios: {
    step: {
      executor: 'ramping-arrival-rate',
      startRate: config.rate,
      timeUnit: '1s',
      preAllocatedVUs: Math.min(config.maxVus, 50),
      maxVUs: config.maxVus,
      stages: [
        { target: config.rate, duration: '30s' },
        { target: config.rate * 2, duration: '60s' },
        { target: config.rate * 4, duration: '60s' },
        { target: config.rate * 2, duration: '60s' },
        { target: config.rate, duration: '30s' },
      ],
      gracefulStop: '30s',
    },
  },
  thresholds: workloadThresholds(),
};
export default requestWorkload;
export function handleSummary(data) { return saveSummary(data); }
