// load-tests/spike-workload.js
import { config, requestWorkload, saveSummary, workloadThresholds } from './common.js';

export const options = {
  scenarios: {
    spike: {
      executor: 'ramping-arrival-rate',
      startRate: config.rate,
      timeUnit: '1s',
      preAllocatedVUs: Math.min(config.maxVus, 50),
      maxVUs: config.maxVus,
      stages: [
        { target: config.rate, duration: '30s' },
        { target: config.rate * 6, duration: '5s' },
        { target: config.rate * 6, duration: '45s' },
        { target: config.rate, duration: '5s' },
        { target: config.rate, duration: '60s' },
      ],
      gracefulStop: '30s',
    },
  },
  thresholds: workloadThresholds(),
};
export default requestWorkload;
export function handleSummary(data) { return saveSummary(data); }
