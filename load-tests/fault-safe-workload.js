// Resource-capped alternative to the original fault-injection.js.
import { config, requestWorkload, saveSummary, workloadThresholds } from './common.js';

const configuredRate = Number(__ENV.FAULT_RATE || 10);

if (!Number.isFinite(configuredRate) || configuredRate < 1 || configuredRate > 20) {
  throw new Error('FAULT_RATE must be between 1 and 20');
}

export const options = {
  scenarios: {
    overload: {
      executor: 'constant-arrival-rate',
      rate: configuredRate,
      timeUnit: '1s',
      duration: '90s',
      preAllocatedVUs: Math.min(config.maxVus, 6),
      maxVUs: config.maxVus,
      gracefulStop: '10s',
    },
  },
  thresholds: workloadThresholds(true),
};

export default requestWorkload;
export function handleSummary(data) { return saveSummary(data); }
