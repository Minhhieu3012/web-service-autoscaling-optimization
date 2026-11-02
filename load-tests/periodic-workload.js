// load-tests/periodic-workload.js
import { config, requestWorkload, saveSummary, workloadThresholds } from './common.js';

export const options = {
  scenarios: {
    periodic: {
      executor: 'ramping-arrival-rate',
      startRate: config.rate,
      timeUnit: '1s',
      preAllocatedVUs: Math.min(config.maxVus, 50),
      maxVUs: config.maxVus,
      stages: [
        { target: config.rate * 4, duration: '20s' },
        { target: config.rate * 4, duration: '30s' },
        { target: config.rate, duration: '20s' },
        { target: config.rate, duration: '30s' },
        { target: config.rate * 4, duration: '20s' },
        { target: config.rate * 4, duration: '30s' },
        { target: config.rate, duration: '20s' },
        { target: config.rate, duration: '30s' },
        { target: config.rate * 4, duration: '20s' },
        { target: config.rate * 4, duration: '30s' },
        { target: config.rate, duration: '20s' },
        { target: config.rate, duration: '30s' },
      ],
      gracefulStop: '30s',
    },
  },
  thresholds: workloadThresholds(),
};
export default requestWorkload;
export function handleSummary(data) { return saveSummary(data); }
