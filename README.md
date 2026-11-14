# Đề tài 3: Tối ưu tự động co giãn cho dịch vụ web theo tải và theo chỉ số nghiệp vụ

Dự án nghiên cứu và thực nghiệm thuộc nhóm **Nền tảng và Kiến trúc Điện toán Đám mây (Chương 1)**. Kho mã nguồn này lưu trữ toàn bộ mã nguồn dịch vụ web stateless, tệp cấu hình hạ tầng & chính sách co giãn (Kubernetes HPA / KEDA), cấu hình giám sát (Prometheus / Grafana), kịch bản kiểm thử tải (Grafana k6), dữ liệu đo thô (CSV/JSON), công cụ phân tích tự động (Jupyter Notebook) và tài liệu báo cáo kỹ thuật.

---

## 1. Tổng quan đề tài

### Câu hỏi nghiên cứu
> *Chính sách co giãn theo CPU có đủ hiệu quả đối với tải biến động nhanh, hay cần kết hợp độ trễ, hàng đợi và số yêu cầu đang chờ?*

### Mục tiêu nghiên cứu
- Thiết kế và so sánh ba cấu hình chính sách co giãn trên cùng một dịch vụ web stateless:
  1. **`baseline-cpu`** ([k8s/autoscaling/hpa-cpu.yaml](k8s/autoscaling/hpa-cpu.yaml)): HPA truyền thống theo mức sử dụng CPU (`averageUtilization: 70%`).
  2. **`custom-unoptimized`** ([k8s/autoscaling/keda-custom-raw.yaml](k8s/autoscaling/keda-custom-raw.yaml)): KEDA theo độ dài hàng đợi đơn thuần (`app_queue_length >= 3`, chu kỳ mặc định `30s`).
  3. **`custom-optimized`** ([k8s/autoscaling/keda-custom-optimized.yaml](k8s/autoscaling/keda-custom-optimized.yaml)): KEDA kết hợp đa chỉ số (`app_queue_length >= 2`, `app_in_flight_requests >= 4` ứng với 80% bão hòa worker theo Định luật Little, và `p95 queue wait >= 0.25s`), chu kỳ lấy mẫu `5s` và cơ chế Hysteresis (`scaleUp: 0s`, `scaleDown: 60s`).
- Đánh giá định lượng mối quan hệ đánh đổi giữa **tốc độ phản ứng (`scale_out_s`)**, **chất lượng dịch vụ (`p95 latency`, `error rate`, `HTTP 503`)** và **chi phí tài nguyên (`ReplicaSeconds`, `Cost per 1,000 Requests`)**.
- Xác định ngưỡng kích hoạt và cửa sổ ổn định (`stabilizationWindowSeconds: 60s`) giúp triệt tiêu hiện tượng dao động bản sao (**flapping/thrashing**) trong tải chu kỳ.

---

## 2. Phân công thành viên nhóm

| Thành viên | Vai trò chính | Trách nhiệm trọng tâm | Yêu cầu phối hợp |
| :--- | :--- | :--- | :--- |
| **Phan Minh Hiếu** (`Minhhieu3012`) | Phát triển Web Service & Giám sát | Xây dựng dịch vụ FastAPI stateless (`/api/cpu`, `/api/queue` với `asyncio.Semaphore(5)` và giới hạn `HTTP 503`); xuất custom metrics tại `/metrics`; cấu hình `ServiceMonitor` (`5s`) và Grafana Dashboard 6 panels. | Phối hợp với Gia Huy thống nhất nhãn `Service` / `PromQL` cho KEDA; phối hợp với Đức Thành chuẩn hóa đường dẫn API và mã trạng thái kiểm thử. |
| **Nguyễn Hà Gia Huy** (`ghu0101exe`) | Hạ tầng K8s, Chính sách Co giãn & Bảo mật | Khởi tạo cụm Minikube (`setup-cluster.ps1`, `cleanup.ps1`); viết `Deployment`/`Service`; thiết kế 3 chính sách `hpa-cpu.yaml`, `keda-custom-raw.yaml`, `keda-custom-optimized.yaml`; biên soạn hướng dẫn tái lập, bảo mật và quản trị chi phí. | Phối hợp với Minh Hiếu tích hợp Prometheus Adapter/KEDA; phối hợp với Đức Thành đảm bảo cơ chế chuyển đổi chính sách tự động và cô lập biến thực nghiệm. |
| **Lại Đức Thành** (`LDT1005`) | Kiểm thử tải, Tự động hóa & Phân tích dữ liệu | Viết 4 kịch bản tải Grafana k6 (`step`, `spike`, `periodic`, `fault`); viết script điều phối (`run-all-experiments.ps1`, `run-experiment.ps1`) & thu thập Prometheus (`collect-metrics.py`); xây dựng `notebooks/analysis.ipynb` xuất bảng và biểu đồ học thuật. | Phối hợp với cả nhóm kiểm chứng toàn bộ ma trận thực nghiệm, đối chiếu giả thuyết $H_1, H_2, H_3$ và đồng biên찬 báo cáo kỹ thuật. |

---

## 3. Danh sách phiên bản công nghệ & Môi trường thực nghiệm

Hệ thống vận hành 100% trên cụm cục bộ (gói miễn phí, chi phí đám mây \$0) với danh sách công cụ và phiên bản chuẩn hóa:

| Công cụ / Thành phần | Phiên bản tham chiếu | Vai trò trong dự án |
| :--- | :--- | :--- |
| **Hệ điều hành** | `Windows 10/11 (64-bit)` | Máy chủ vật lý chạy thực nghiệm |
| **Git** | `2.47.1.windows.1` | Quản lý phiên bản mã nguồn, nhánh và lịch sử đóng góp |
| **Docker Desktop / Engine** | `Docker Desktop 4.97.0 / Engine 29.9.2` | Đóng gói container image và làm driver cho cụm Minikube |
| **Minikube** | `v1.39.0 (Kubernetes v1.37.0)` | Khởi tạo cụm Kubernetes cục bộ (2 vCPU, 3072 MiB RAM) |
| **kubectl** | `v1.34.1 – v1.36.1` | Giao tiếp và quản trị cụm Kubernetes |
| **Helm** | `v4.3.1+gc0d08d0` | Quản lý gói cài đặt Monitoring Stack và KEDA |
| **kube-prometheus-stack** | `Helm Chart 92.16.1` | Triển khai Prometheus (`scrapeInterval: 5s`), Grafana & kube-state-metrics |
| **KEDA** | `Helm Chart 2.21.0` | Bộ điều khiển co giãn hướng sự kiện (`ScaledObject` & External Metrics API) |
| **Grafana k6** | `v1.1.0 (go1.24.4, windows/amd64)` | Giả lập 4 kịch bản tải: Bậc thang (`step`), Xung (`spike`), Chu kỳ (`periodic`), Lỗi (`fault`) |
| **Python & FastAPI** | `Python 3.11 (FastAPI 0.111.0)` | Dịch vụ web stateless (`/api/cpu`, `/api/queue`, `/health`, `/metrics`) |
| **Jupyter / Pandas / Matplotlib** | `Python venv (.venv)` | Phân tích dữ liệu đo thô CSV/JSON và tái tạo bộ biểu đồ chuẩn học thuật |

---

## 4. Cấu trúc kho mã nguồn

```text
web-service-autoscaling-optimization/
├── app/                                    # Mã nguồn dịch vụ Web Stateless (FastAPI) & Dockerfile
│   ├── Dockerfile                          # Đóng gói container Python 3.11-slim (non-root / stateless)
│   ├── main.py                             # Endpoints /api/cpu, /api/queue, /health, /metrics
│   └── requirements.txt                    # Danh sách thư viện Python cố định phiên bản
├── k8s/                                    # Cấu hình triển khai Kubernetes & Chính sách co giãn
│   ├── base/
│   │   ├── deployment.yaml                 # Deployment web-service (requests: 100m/96Mi, limits: 500m/256Mi)
│   │   └── service.yaml                    # ClusterIP Service cổng 8000
│   └── autoscaling/
│       ├── hpa-cpu.yaml                    # Chính sách 1 (baseline-cpu): HPA theo CPU Utilization 70%
│       ├── keda-custom-raw.yaml            # Chính sách 2 (custom-unoptimized): KEDA Queue >= 3 (poll 30s)
│       └── keda-custom-optimized.yaml      # Chính sách 3 (custom-optimized): KEDA 3 triggers + Hysteresis 60s (poll 5s)
├── monitoring/                             # Cấu hình hệ thống giám sát Prometheus, KEDA & Grafana
│   ├── values-local.yaml                   # Helm values tối ưu RAM cho kube-prometheus-stack (scrape 5s)
│   ├── keda-values-local.yaml              # Helm values tối ưu tài nguyên cho KEDA
│   ├── service-monitor.yaml                # ServiceMonitor thu thập /metrics ứng dụng mỗi 5s
│   └── grafana-dashboard.json              # Dashboard Grafana 6 panels đồng bộ Tải - Queue - Replicas - p95
├── load-tests/                             # Kịch bản kiểm thử tải Grafana k6
│   ├── common.js                           # Hàm dùng chung, custom metrics (overload_503_total, queue_wait_seconds)
│   ├── step-workload.js                    # Kịch bản tải Bậc thang (240s: 1x -> 2x -> 4x -> 2x -> 1x)
│   ├── spike-workload.js                   # Kịch bản tải Xung đột biến (145s: 1x -> 6x -> 1x)
│   ├── periodic-workload.js                # Kịch bản tải Chu kỳ (300s: 3 đợt sóng 4x xen kẽ vùng trũng 50s)
│   ├── fault-injection.js                  # Kịch bản ép lỗi quá tải hàng đợi cường độ cao (HTTP 503)
│   └── fault-safe-workload.js              # Kịch bản ép lỗi quá tải có giới hạn VUs an toàn cho máy cá nhân
├── scripts/                                # Kịch bản tự động hóa hạ tầng & điều phối thực nghiệm
│   ├── setup-cluster.ps1                   # Khởi tạo Minikube, bật Metrics Server và kiểm tra sức khỏe cụm
│   ├── run-experiment.ps1                  # Chạy 1 lượt thực nghiệm đơn lẻ và thu thập số liệu
│   ├── run-all-experiments.ps1             # Điều phối tự động toàn bộ ma trận thực nghiệm (Preflight/Smoke/Full)
│   ├── collect-metrics.py                  # Trích xuất chuỗi thời gian từ Prometheus Range API ra CSV
│   └── cleanup.ps1                         # Gỡ cài đặt tài nguyên có kiểm soát (mặc định Dry-Run)
├── data/                                   # Bộ dữ liệu đo thô (CSV/JSON) và bảng tổng hợp
│   ├── baseline-cpu/                       # Dữ liệu đo chính sách HPA theo CPU
│   ├── custom-unoptimized/                 # Dữ liệu đo KEDA trước tối ưu
│   ├── custom-optimized/                   # Dữ liệu đo KEDA sau tối ưu
│   ├── automation-checkpoints/             # Trạng thái checkpoint phục vụ chạy tiếp (-Resume)
│   └── automation-results/                 # Báo cáo tổng hợp từng đợt chạy tự động
├── notebooks/                              # Phân tích dữ liệu và trực quan hóa kết quả
│   ├── analysis.ipynb                      # Notebook tính toán chỉ số, bảng trước/sau tối ưu và xuất biểu đồ
│   └── figures/                            # Biểu đồ xuất ra định dạng PNG (200 DPI) và PDF vector
├── docs/                                   # Tài liệu kiến trúc, hướng dẫn tái lập và báo cáo kỹ thuật
│   ├── architecture/
│   │   └── architecture-and-flows.md       # Sơ đồ kiến trúc hiện trạng/mục tiêu, luồng dữ liệu & trình tự
│   ├── final-report/
│   │   ├── technical-report.md             # Báo cáo kỹ thuật hoàn chỉnh (Chương 1 -> Chương 5)
│   │   ├── demo-script.md                  # Kịch bản quay video demo (8-12 phút) & hỏi đáp phản biện
│   │   └── evidence/                       # Minh chứng trạng thái HPA/KEDA thực tế trên cụm
│   ├── reproducibility-guide.md            # Hướng dẫn cài đặt và tái lập thực nghiệm từng bước
│   └── cost-and-security.md                # Phân tích chi phí tài nguyên (ReplicaSeconds) và bảo mật
├── .gitignore
└── README.md
```

---

## 5. Hướng dẫn triển khai nhanh & Tái lập thực nghiệm

*(Xem hướng dẫn chi tiết từng bước và cách xử lý sự cố tại [docs/reproducibility-guide.md](docs/reproducibility-guide.md)).*

### Bước 1: Khởi tạo cụm Minikube, Monitoring Stack và KEDA
```powershell
# 1. Khởi tạo cụm Minikube (2 CPU, 3072 MiB RAM) và bật Metrics Server
.\scripts\setup-cluster.ps1

# 2. Thêm Helm repositories và cài đặt Prometheus + Grafana + KEDA
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack `
  --version 92.16.1 --kube-context minikube --namespace monitoring --create-namespace `
  -f monitoring/values-local.yaml --wait=hookOnly --timeout 3m

helm upgrade --install keda kedacore/keda `
  --version 2.21.0 --kube-context minikube --namespace keda --create-namespace `
  -f monitoring/keda-values-local.yaml --wait=hookOnly --timeout 3m
```

### Bước 2: Đóng gói Image & Triển khai Dịch vụ Web Stateless
```powershell
# Đóng gói image trực tiếp vào Docker daemon của Minikube
minikube -p minikube image build -t web-service-autoscaling:dev ./app

# Triển khai Deployment, Service và ServiceMonitor (chu kỳ 5s)
kubectl --context minikube apply -f k8s/base/deployment.yaml
kubectl --context minikube apply -f k8s/base/service.yaml
kubectl --context minikube apply -f monitoring/service-monitor.yaml
kubectl --context minikube rollout status deployment/web-service --timeout=120s
```

### Bước 3: Chạy Thực nghiệm Tự động và Phân tích Kết quả
```powershell
# Kiểm tra tiền điều kiện (không tạo tải)
.\scripts\run-all-experiments.ps1 -Mode Preflight

# Chạy kiểm thử nhanh (Smoke test)
.\scripts\run-all-experiments.ps1 -Mode Smoke

# Chạy toàn bộ ma trận thực nghiệm (3 chính sách x các kịch bản tải + kịch bản lỗi HTTP 503)
.\scripts\run-all-experiments.ps1 -Mode Full -IncludeFault -Resume
```
Sau khi hoàn tất, mở và chạy toàn bộ các ô trong [notebooks/analysis.ipynb](notebooks/analysis.ipynb) để tự động sinh các bảng tổng hợp (`data/comparison-runs.csv`, `data/comparison-aggregated.csv`, `data/comparison-before-after.csv`) và bộ biểu đồ trong `notebooks/figures/`.

---

## 6. Dọn dẹp tài nguyên & Quản trị chi phí / Bảo mật

```powershell
# Gỡ các bản phát hành Helm (mặc định chạy ở chế độ xem trước Dry-Run an toàn)
.\scripts\cleanup.ps1
.\scripts\cleanup.ps1 -Execute

# Dừng hoặc xóa hoàn toàn cụm Minikube khi kết thúc dự án
minikube stop
minikube delete
```

- **Quản trị chi phí:** Thực nghiệm vận hành 100% trên cụm cục bộ (Minikube/Docker), không phát sinh chi phí dịch vụ đám mây (\$0). Chi phí sử dụng tài nguyên giữa các chính sách được định lượng chuẩn hóa qua chỉ số `ReplicaSeconds` và `Cost per 1,000 Requests` (xem [docs/cost-and-security.md](docs/cost-and-security.md)).
- **An toàn bảo mật:** Kho mã nguồn không lưu trữ mật khẩu, khóa API, token hay dữ liệu cá nhân; Pod ứng dụng tắt tự động gắn token (`automountServiceAccountToken: false`) và giới hạn chặt `requests`/`limits` tài nguyên.
