# Thành — load-test & data-analysis deliverable

This package adds files into the **existing** repository root; do not replace existing `app/`, `k8s/`, `monitoring/` or infrastructure scripts.

## Prerequisites
- Windows PowerShell, k6, Python 3.10+, Minikube/kubectl/Helm running.
- FastAPI deployed and reachable via `kubectl --context minikube -n default port-forward svc/web-service 8000:8000` in terminal 1.
- Prometheus reachable via `kubectl --context minikube -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090` in terminal 2. Verify actual Service name with `kubectl -n monitoring get svc`.
- `python -m pip install -r requirements-analysis.txt`.

## Must check before each experiment
1. `kubectl --context minikube -n default get hpa,scaledobject,deploy,pods`.
2. **Only one policy** manages `web-service` Deployment. HPA CPU baseline: `kubectl --context minikube apply -f k8s/autoscaling/hpa-cpu.yaml` after deleting any KEDA ScaledObject. KEDA raw: delete standalone HPA and apply `k8s/autoscaling/keda-custom-raw.yaml`. KEDA optimized must be supplied by Huy; do not invent production results for an unprovided configuration.
3. Each run must begin with equivalent available replicas (ideally 1), same image, resource requests/limits, same k6 rate, same CPU/queue settings and wait for scale-down/cooldown between runs.
4. Verify http://127.0.0.1:8000/health and http://127.0.0.1:9090/api/v1/query?query=up. Run `kubectl get svc -n monitoring` to confirm Prometheus naming.
5. Monitoring chart may have disabled kube-state-metrics and kubelet/cAdvisor. If `prometheus_coverage.json` marks replica/CPU unavailable, enable relevant exporters/targets via the monitoring Helm values together with Huy before collecting final results. `kubectl top` alone does not prove those series exist in Prometheus.

## Execute
Run PowerShell from repository root:

```powershell
.\scripts\run-experiment.ps1 -Policy baseline-cpu -Scenario step -Endpoint queue -Repeat 1
.\scripts\run-experiment.ps1 -Policy custom-unoptimized -Scenario step -Endpoint queue -Repeat 1
# Only after Huy supplies and applies keda-optimized.yaml:
.\scripts\run-experiment.ps1 -Policy custom-optimized -Scenario step -Endpoint queue -Repeat 1
```

For all workloads run `step`, `spike`, `periodic` and both endpoints (`queue`, `cpu`) for each policy. Repeat >=3 times, ideally fresh cluster resource conditions. Use `-Rate 10 -MaxVus 150 -WorkTime 0.5 -Iterations 1000000` identically for comparable cases. For failure demo: `-Scenario fault -Endpoint queue` (forced queue work_time=1 and limit=10); do **not** merge fault results with ordinary benchmark summaries.

If you want raw k6 only: `$env:ENDPOINT='queue'; $env:BASE_URL='http://127.0.0.1:8000'; k6 run load-tests/step-workload.js`.

Raw results are stored per run under `data/<policy>/<run-id>/`: k6 summary, raw JSON, console log, metadata, Prometheus timeline and coverage. Real outputs are **not included** in this package because no live Minikube/Prometheus was supplied.

Open `notebooks/analysis.ipynb` in VS Code/Jupyter and Run All after obtaining real data. It produces `data/comparison-runs.csv`, `data/comparison-aggregated.csv` and figures in `notebooks/figures/`.

## Measurement caveats
- `http_req_duration` excludes some connection stages; use k6 metric definition consistently.
- k6 `app_error_rate` counts any non-200 response, including HTTP 503 and request failures. Collect HTTP 503 separately.
- `dropped_iterations` means offered load could not be executed and must be reported, not silently ignored.
- `replicas_available` requires kube-state-metrics; CPU and RAM require container metrics scraped by Prometheus.
- Replica timeline resolution equals Prometheus scrape step, cannot resolve changes finer than sampling interval.
- The application maintains an in-memory queue per Pod; KEDA is driven by summed per-Pod queue metric, not a shared external broker.

## Source ownership
This package does not modify files owned by Huy/Hiếu and it does not manufacture test results. Merge through branch `feat/loadtest-analysis`; coordinate autoscaler switching with Huy.
