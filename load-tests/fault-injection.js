// load-tests/fault-injection.js
import { requestWorkload, saveSummary, workloadThresholds } from './common.js';

// Force a queue-backlog condition with ENDPOINT=queue, WORK_TIME=1 and MAX_QUEUE_LIMIT=10.
export const options = {
  scenarios: {
    overload: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.FAULT_RATE || 100),
      timeUnit: '1s',
      duration: '90s',
      preAllocatedVUs: 100,
      maxVUs: 300,
      gracefulStop: '30s',
    },
  },
  thresholds: workloadThresholds(true),
};
export default requestWorkload;
export function handleSummary(data) { return saveSummary(data); }
