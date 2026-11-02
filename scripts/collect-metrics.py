# scripts/collect-metrics.py
"""Export aligned Prometheus/Kubernetes time series for one k6 experiment."""
from __future__ import annotations

import argparse
import csv
import json
import math
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

QUERIES = {
    "replicas_desired": 'kube_deployment_spec_replicas{namespace="default",deployment="web-service"}',
    "replicas_available": 'kube_deployment_status_replicas_available{namespace="default",deployment="web-service"}',
    "cpu_cores": 'sum(rate(container_cpu_usage_seconds_total{namespace="default",pod=~"web-service-.*",container="web-service"}[1m]))',
    "memory_bytes": 'sum(container_memory_working_set_bytes{namespace="default",pod=~"web-service-.*",container="web-service"})',
    "queue_length": 'sum(app_queue_length{namespace="default",service="web-service"})',
    "in_flight": 'sum(app_in_flight_requests{namespace="default",service="web-service"})',
    "app_rps": 'sum(rate(http_requests_total{namespace="default",service="web-service",handler=~"/api/.*"}[1m]))',
}


def request_json(url: str, timeout: float) -> dict:
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.load(response)


def fetch_range(base: str, query: str, start: float, end: float, step: int, timeout: float):
    args = urllib.parse.urlencode({"query": query, "start": start, "end": end, "step": step})
    result = request_json(base.rstrip('/') + '/api/v1/query_range?' + args, timeout)
    if result.get('status') != 'success':
        raise RuntimeError(str(result.get('error', result)))
    return result.get('data', {}).get('result', [])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prometheus-url', default='http://127.0.0.1:9090')
    parser.add_argument('--start', type=float, required=True, help='UTC Unix seconds')
    parser.add_argument('--end', type=float, required=True, help='UTC Unix seconds')
    parser.add_argument('--step', type=int, default=5)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--timeout', type=float, default=20)
    args = parser.parse_args()
    if not (0 < args.start < args.end and args.step > 0):
        parser.error('require 0 < start < end and step > 0')
    args.output.mkdir(parents=True, exist_ok=True)
    rows = {}
    coverage = {}
    for metric, promql in QUERIES.items():
        try:
            series = fetch_range(args.prometheus_url, promql, args.start, args.end, args.step, args.timeout)
            coverage[metric] = {"series": len(series), "available": bool(series)}
            for item in series:
                for stamp, raw in item.get('values', []):
                    key = round(float(stamp), 3)
                    try:
                        value = float(raw)
                    except (ValueError, TypeError):
                        continue
                    if not math.isfinite(value):
                        continue
                    row = rows.setdefault(key, {"timestamp": key})
                    row[metric] = row.get(metric, 0) + value
        except (urllib.error.URLError, TimeoutError, ValueError, RuntimeError) as exc:
            coverage[metric] = {"series": 0, "available": False, "error": str(exc)}
            print(f'WARN {metric}: {exc}', file=sys.stderr)
    fieldnames = ['timestamp', 'timestamp_utc', *QUERIES]
    target = args.output / 'prometheus_timeseries.csv'
    with target.open('w', newline='', encoding='utf-8') as stream:
        writer = csv.DictWriter(stream, fieldnames=fieldnames)
        writer.writeheader()
        for stamp in sorted(rows):
            row = rows[stamp]
            row['timestamp_utc'] = datetime.fromtimestamp(stamp, timezone.utc).isoformat()
            writer.writerow(row)
    (args.output / 'prometheus_coverage.json').write_text(
        json.dumps({"queries": QUERIES, "coverage": coverage, "start": args.start,
                    "end": args.end, "step_seconds": args.step}, indent=2), encoding='utf-8')
    print(f'Wrote {len(rows)} timestamps to {target}')
    if not rows:
        print('ERROR: no numeric samples. Verify Prometheus URL, permissions and scrape.', file=sys.stderr)
        return 2
    if not coverage['replicas_available']['available']:
        print('WARN: kube-state-metrics may be disabled: replicas unavailable.', file=sys.stderr)
    if not coverage['cpu_cores']['available']:
        print('WARN: kubelet/cAdvisor may be disabled: CPU usage unavailable.', file=sys.stderr)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
