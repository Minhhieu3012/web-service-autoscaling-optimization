# Sơ đồ Kiến trúc Hệ thống, Luồng Dữ liệu và Trình tự Điều khiển

Tài liệu này cung cấp bộ sơ đồ kiến trúc hiện trạng (Baseline), kiến trúc mục tiêu (Target), sơ đồ luồng dữ liệu (Data Flow) và sơ đồ trình tự (Sequence Diagram) cho cả luồng hoạt động bình thường lẫn tình huống lỗi quá tải hàng đợi của đề tài **Đề tài 3: Tối ưu tự động co giãn cho dịch vụ web theo tải và theo chỉ số nghiệp vụ**.

---

## 1. Sơ đồ Kiến trúc Hiện trạng (Baseline Architecture — HPA theo CPU)

Ở kiến trúc hiện trạng, Kubernetes Horizontal Pod Autoscaler (`web-service-hpa-cpu`) chỉ thu thập chỉ số CPU thông qua `Metrics Server` (`metrics.k8s.io`). Cơ chế này hoạt động hiệu quả với tải thuần tính toán (`/api/cpu`), nhưng **bị mù thông tin (blind spot)** trước các công việc chờ I/O hoặc xếp hàng đợi (`/api/queue`) vì các tác vụ chờ bất đồng bộ (`asyncio.sleep`) tiêu thụ rất ít CPU dù toàn bộ worker đã bão hòa 100%.

```mermaid
flowchart TB
    subgraph Host["Máy chủ Thực nghiệm (Windows Host)"]
        K6["Công cụ sinh tải Grafana k6<br/>(step / spike / periodic / fault)"]
    end

    subgraph Cluster["Cụm Kubernetes (Minikube Single-Node)"]
        SVC["Kubernetes Service<br/>(web-service / NodePort Tunnel)"]

        subgraph AppPods["Deployment: web-service (1..3 Replicas)"]
            POD1["Pod: FastAPI Stateless<br/>- /api/cpu (Tính toán CPU)<br/>- /api/queue (Semaphore 5 workers + Queue)"]
        end

        subgraph KubeSystem["Namespace: kube-system"]
            CAD["Kubelet / cAdvisor<br/>(Đo CPU & RAM container)"]
            MS["Kubernetes Metrics Server<br/>(API: metrics.k8s.io)"]
        end

        subgraph Autoscaler["Namespace: default"]
            HPA["HorizontalPodAutoscaler<br/>(web-service-hpa-cpu)<br/>Target: CPU Utilization 70%"]
        end
    end

    K6 -->|"HTTP GET /api/cpu hoặc /api/queue"| SVC
    SVC -->|"Cân bằng tải (Round-Robin)"| POD1
    POD1 -.->|"Xuất chỉ số CPU container"| CAD
    CAD -->|"Cập nhật mỗi 15-60s"| MS
    MS -->|"Truy vấn CPU Utilization"| HPA
    HPA -->|"Scale 1..3 Replicas<br/>(Điểm mù: Không thấy Queue Length & Latency)"| AppPods
```

---

## 2. Sơ đồ Kiến trúc Mục tiêu (Target Architecture — KEDA Event-Driven & Multi-Metric)

Kiến trúc mục tiêu bổ sung đường thu thập chỉ số nghiệp vụ và chất lượng dịch vụ (QoS) độ phân giải cao (`5s`) qua Prometheus `ServiceMonitor`, kết hợp bộ điều khiển **KEDA (`ScaledObject`)** đánh giá đồng thời 3 tín hiệu (**Độ dài hàng đợi `app_queue_length`**, **Độ bão hòa worker `app_in_flight_requests`**, **Độ trễ chờ p95 `app_queue_wait_duration_seconds`**) và cơ chế **Hysteresis (`behavior.scaleUp` / `behavior.scaleDown`)**.

```mermaid
flowchart TB
    subgraph Host["Môi trường Điều phối & Phân tích (Windows Host)"]
        K6["Grafana k6 Load Generator<br/>(step / spike / periodic / fault)"]
        ORCH["Kịch bản Điều phối & Thu thập<br/>(run-all-experiments.ps1 + collect-metrics.py)"]
        NB["Jupyter Notebook Phân tích<br/>(notebooks/analysis.ipynb -> CSV & Figures)"]
    end

    subgraph Cluster["Cụm Kubernetes (Minikube)"]
        subgraph DefaultNS["Namespace: default (Workload & Policy)"]
            SVC["Service: web-service (Port 8000)"]
            subgraph Deployment["Deployment: web-service (min=1, max=3)"]
                POD["FastAPI Stateless Pods<br/>MAX_CONCURRENT_WORKERS = 5<br/>Экспорт /metrics:<br/>- app_queue_length<br/>- app_in_flight_requests<br/>- app_queue_wait_duration_seconds<br/>- http_request_duration_seconds"]
            end
            SO["KEDA ScaledObject<br/>(web-service-keda-custom-optimized)<br/>pollingInterval: 5s, cooldownPeriod: 60s"]
            KHPA["KEDA-Managed HPA v2<br/>scaleUp: window=0s (+2 pods/15s)<br/>scaleDown: window=60s (-1 pod/30s)"]
        end

        subgraph MonitoringNS["Namespace: monitoring (Observability)"]
            SM["ServiceMonitor: web-service-monitor<br/>(interval: 5s, timeout: 4s)"]
            PROM["Prometheus Server<br/>(scrapeInterval: 5s, retention: 3h)"]
            KSM["kube-state-metrics & cAdvisor<br/>(Replicas, CPU, Memory)"]
            GRAF["Grafana Dashboard<br/>(6 Panels đồng bộ Tải - Queue - Replicas - p95)"]
        end

        subgraph KedaNS["Namespace: keda (Event-Driven Autoscaler)"]
            KOP["KEDA Operator"]
            KMET["KEDA Metrics API Server<br/>(external.metrics.k8s.io)"]
        end
    end

    K6 -->|"1. Gửi tải HTTP (Step/Spike/Periodic/Fault)"| SVC
    SVC -->|"2. Phân phối yêu cầu tới Ready Pods"| POD
    SM -.->|"3. Cấu hình mục tiêu cào 5s/lần"| PROM
    PROM -->|"4a. Scrape /metrics mỗi 5s"| POD
    PROM -->|"4b. Scrape trạng thái Pod & Node mỗi 5s"| KSM
    PROM -->|"5. Hiển thị trực quan thời gian thực"| GRAF
    KOP -->|"6. Truy vấn PromQL mỗi 5s<br/>(Queue >= 2 | InFlight >= 4 | p95 Wait >= 0.25s)"| PROM
    KOP -->|"7. Cung cấp External Metrics"| KMET
    SO -->|"8. Sinh và cấu hình hành vi Hysteresis"| KHPA
    KMET -->|"9. Cấp số liệu s0/s1/s2-prometheus"| KHPA
    KHPA -->|"10. Điều chỉnh số bản sao (1..3 Replicas)"| Deployment
    ORCH -->|"11. Truy vấn Range API (/api/v1/query_range)"| PROM
    ORCH -->|"12. Xuất k6-summary.json & prometheus_timeseries.csv"| NB
```

---

## 3. Sơ đồ Luồng Dữ liệu Thực nghiệm (Data Flow Diagram — End-to-End Pipeline)

Sơ đồ dưới đây mô tả luồng dữ liệu khép kín từ lúc phát sinh yêu cầu HTTP, biến đổi thành chỉ số đo lường, kích hoạt vòng lặp điều khiển co giãn cho tới bước hậu xử lý sinh bảng và biểu đồ học thuật.

```mermaid
flowchart LR
    A["1. Kịch bản tải k6<br/>(Arrival Rate λ)"] -->|"HTTP Request"| B["2. Bộ điều phối FastAPI<br/>(Semaphore c=5, Queue K)"]
    B -->|"Phản hồi HTTP 200 / 503"| A
    A -->|"Kết thúc lượt chạy"| C["k6-summary.json &<br/>k6-raw.json"]

    B -->|"Cập nhật Gauge/Histogram<br/>tại /metrics"| D["3. Prometheus TSDB<br/>(Chu kỳ lấy mẫu Δt = 5s)"]
    E["kube-state-metrics &<br/>Kubelet cAdvisor"] -->|"Replicas, CPU, RAM"| D

    D -->|"PromQL Queries"| F["4. Bộ quyết định Co giãn<br/>(HPA / KEDA ScaledObject)"]
    F -->|"Thay đổi spec.replicas"| B

    D -->|"HTTP query_range API<br/>(collect-metrics.py)"| G["prometheus_timeseries.csv &<br/>prometheus_coverage.json"]
    H["Tham số Lượt chạy<br/>(run-all-experiments.ps1)"] -->|"Ghi thông tin điều kiện đo"| I["metadata.json"]

    C --> J["5. Notebook Phân tích<br/>(notebooks/analysis.ipynb)"]
    G --> J
    I --> J

    J -->|"Tổng hợp & Kiểm định"| K["Bảng CSV đối chiếu:<br/>- comparison-runs.csv<br/>- comparison-aggregated.csv<br/>- comparison-before-after.csv"]
    J -->|"Trực quan hóa chuẩn hóa"| L["Biểu đồ Báo cáo (PNG/PDF):<br/>- p95-*.png/pdf<br/>- tradeoff-*.png/pdf<br/>- replicas-*.png/pdf"]
```

---

## 4. Sơ đồ Trình tự (Sequence Diagrams)

### 4.1. Luồng Bình thường & Tự động Co giãn theo Chỉ số Kết hợp (Normal & Proactive Scaling Flow)

Trình tự xử lý khi tải tăng đột ngột (Spike / Periodic) trên `/api/queue` dưới sự điều khiển của chính sách tối ưu `web-service-keda-custom-optimized`:

```mermaid
sequenceDiagram
    autonumber
    participant K6 as Grafana k6 (Load Generator)
    participant SVC as K8s Service (web-service)
    participant Pod1 as FastAPI Pod #1 (5 Workers)
    participant Prom as Prometheus (5s Scrape)
    participant KEDA as KEDA + HPA Controller
    participant K8s as K8s Deployment / ReplicaSet
    participant Pod23 as FastAPI Pods #2 & #3

    Note over K6,Pod1: Giai đoạn 1: Tải nền (Base Rate = 4 req/s, WorkTime = 0.5s -> L = 2 in-flight)
    K6->>SVC: Gửi 4 req/s tới /api/queue
    SVC->>Pod1: Chuyển tiếp yêu cầu
    Pod1->>Pod1: Chiếm 2/5 worker_semaphore (app_in_flight_requests = 2, app_queue_length = 0)
    Pod1-->>K6: HTTP 200 OK (total_response ≈ 0.5s)

    Note over K6,KEDA: Giai đoạn 2: Tải tăng đột biến (Spike = 24 req/s -> L = 12 yêu cầu đồng thời)
    K6->>SVC: Tăng tốc độ gửi lên 24 req/s
    SVC->>Pod1: Dồn yêu cầu vào Pod #1
    Pod1->>Pod1: 5/5 workers bận (in_flight >= 4) & yêu cầu thứ 6+ xếp hàng (queue_length >= 2)
    Prom->>Pod1: Scrape /metrics (chu kỳ 5s)
    Prom-->>KEDA: Trả kết quả PromQL (in_flight=12 > ngưỡng 4; queue_length=7 > ngưỡng 2)
    KEDA->>K8s: Kích hoạt Scale-Up tức thời (stabilizationWindow=0s, +2 Pods/15s -> 3 Replicas)
    K8s->>Pod23: Khởi tạo Pod #2 & Pod #3, kiểm tra Readiness Probe (/health)
    Pod23-->>SVC: Sẵn sàng nhận tải (Ready = True, tổng năng lực = 15 workers = 30 req/s)

    Note over K6,Pod23: Giai đoạn 3: Phân tải ổn định & Giảm tải có Hysteresis
    K6->>SVC: Tiếp tục gửi 24 req/s
    SVC->>Pod1: Phân phối ~8 req/s (queue_length -> 0)
    SVC->>Pod23: Phân phối ~16 req/s (queue_length -> 0)
    Pod1-->>K6: HTTP 200 OK (Độ trễ p95 giảm về ~0.5s)
    Pod23-->>K6: HTTP 200 OK (Độ trễ p95 giảm về ~0.5s)

    Note over K6,K8s: Giai đoạn 4: Tải hạ xuống mức nền (Hysteresis 60s chống dao động Flapping)
    K6->>SVC: Hạ tải về 4 req/s
    KEDA->>KEDA: Giữ nguyên 3 Replicas trong 60s (stabilizationWindowSeconds: 60)<br/>Vượt qua vùng trũng 50s của tải Chu kỳ mà không bị co-giãn liên tục
    KEDA->>K8s: Sau 60s tải thấp liên tục, giảm từ từ (-1 Pod / 30s) về 1 Replica
```

---

### 4.2. Luồng Tình huống Lỗi Quá tải Hàng đợi (Fault Injection / Overload HTTP 503 Flow)

Trình tự xử lý khi tải vượt quá sức chứa hàng đợi (`max_queue_limit = 10`, `work_time = 1.0s` trong kịch bản lỗi `fault-injection.js` / `fault-safe-workload.js`), chứng minh cơ chế **Load Shedding (Fail-fast HTTP 503)** bảo vệ ứng dụng không bị treo hoặc tràn bộ nhớ (`OOMKilled`):

```mermaid
sequenceDiagram
    autonumber
    participant K6 as Grafana k6 (Fault Workload)
    participant Pod as FastAPI Pod (/api/queue)
    participant Prom as Prometheus & Grafana

    Note over K6,Pod: Điều kiện ép lỗi: work_time = 1.0s, max_queue_limit = 10, Tải dồn dập
    K6->>Pod: 5 yêu cầu đầu tiên đi vào hệ thống
    Pod->>Pod: Chiếm hết 5/5 vị trí trong worker_semaphore (app_in_flight_requests = 5)

    K6->>Pod: 10 yêu cầu tiếp theo (thứ 6 đến thứ 15) đến khi chưa worker nào giải phóng
    Pod->>Pod: Tăng app_queue_length từ 1 lên 10 (Đạt ngưỡng max_queue_limit = 10)

    K6->>Pod: Yêu cầu thứ 16+ đến khi current_waiting (10) >= max_queue_limit (10)
    Pod->>Pod: Tăng bộ đếm app_processed_jobs_total{endpoint="queue", status="rejected_overload"}
    Pod-->>K6: Lập tức trả về HTTP 503 Service Unavailable (Fail-Fast Load Shedding)
    K6->>K6: Ghi nhận overload_503_total++ và app_error_rate

    Prom->>Pod: Scrape /metrics mỗi 5s
    Prom->>Prom: Ghi nhận tốc độ lỗi 503 (rejected_overload) & Queue Length = 10 trên Grafana Panel #1 & #2
    Note over Pod,Prom: Ứng dụng vẫn sống khỏe (Readiness/Liveness Probe /health = 200 OK),<br/>không bị OOMKilled và tiếp tục giải phóng dần 10 yêu cầu trong hàng đợi
```

---

## 5. Bảng Phân tích Đánh đổi Thiết kế Kiến trúc (Architectural Trade-offs)

| Quyết định thiết kế | Phương án lựa chọn trong đồ án | Phương án thay thế | Lợi ích đạt được | Chi phí / Giới hạn chấp nhận (Trade-off) |
| :--- | :--- | :--- | :--- | :--- |
| **1. Tín hiệu điều khiển Co giãn** | Kết hợp đa chỉ số nghiệp vụ & QoS trên KEDA (`app_queue_length`, `app_in_flight_requests`, `p95 queue wait`) | Chỉ dùng HPA theo tài nguyên phần cứng (`CPU Utilization 70%`) | Phát hiện chính xác tắc nghẽn hàng đợi & bão hòa worker (80%) ngay cả khi CPU thấp; phản ứng chủ động trước khi độ trễ tăng vọt. | Phụ thuộc vào độ sẵn sàng của chuỗi Prometheus + KEDA Operator; cấu hình phức tạp hơn HPA thuần túy. |
| **2. Chu kỳ lấy mẫu & Polling (`5s` vs `30s`)** | Đồng bộ `5s` trên `ServiceMonitor`, Prometheus global scrape và KEDA `pollingInterval` | Giữ mặc định `30s` của Prometheus và KEDA | Giảm độ trễ phát hiện tải đột biến (Spike 45s) tới 6 lần; cung cấp đủ 6 mẫu trong cửa sổ `rate(...[30s])`. | Tăng nhẹ tải CPU/RAM và dung lượng TSDB của Prometheus (được bù trừ bằng việc giới hạn `retention: 3h`). |
| **3. Cửa sổ ổn định thu hẹp (`scaleDown: 60s`)** | Đặt `stabilizationWindowSeconds: 60`, tốc độ giảm tối đa `1 Pod / 30s` | Dùng mặc định `300s` của K8s HPA hoặc giảm tức thời `0s` | Chặn đứng hiện tượng dao động (flapping) qua vùng trũng `50s` của tải chu kỳ, nhưng vẫn thu hồi Pod nhanh gấp 5 lần so với mặc định `300s` khi hết tải Spike. | Duy trì Pod thêm 60s sau khi tải thực sự kết thúc (tăng nhẹ `ReplicaSeconds` đổi lấy sự ổn định QoS). |
| **4. Cơ chế bảo vệ quá tải (`max_queue_limit` + HTTP 503)** | Kiểm tra giới hạn hàng đợi tại tầng ứng dụng và trả lỗi `HTTP 503` tức thời (Load Shedding) | Để hàng đợi phình vô hạn trong bộ nhớ | Ngăn chặn tràn RAM (`OOMKilled`), giữ `/health` probe luôn phản hồi để Kubernetes không khởi động lại Pod đang xử lý dở công việc. | Xuất hiện tỷ lệ lỗi `503` ngắn hạn trong vài giây đầu khi tải vượt ngưỡng trước khi Pod mới kịp `Ready`. |
| **5. Môi trường triển khai thực nghiệm** | Cụm Minikube cục bộ (Single-node, `maxReplicas: 3`) kết hợp NodePort Service Tunnel | Cụm Kubernetes đa node trên Cloud (GKE / EKS / AKS) | Chi phí \$0, kiểm soát chặt biến nhiễu mạng WAN, dễ dàng tái lập 100% trên máy cá nhân của cả 3 thành viên. | Tổng tài nguyên bị giới hạn bởi máy host (2 CPU, 3 GiB RAM); không đo được độ trễ cấp phát máy ảo mới (Cluster Autoscaler). |
