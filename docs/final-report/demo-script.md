# KỊCH BẢN TRÌNH DIỄN & QUAY VIDEO DEMO (8–12 PHÚT / TRỰC TIẾP 15–20 PHÚT)

**Đề tài 3:** Tối ưu tự động co giãn cho dịch vụ web theo tải và theo chỉ số nghiệp vụ  
**Yêu cầu bắt buộc từ đề cương:**
- Thời lượng: **8–12 phút** (đối với video quay sẵn) hoặc **15–20 phút** (đối với trình diễn trực tiếp trên lớp).
- Chứng minh **cả luồng hoạt động bình thường** (tự động mở rộng & thu hẹp bản sao) và **ít nhất một tình huống lỗi** (quá tải hàng đợi trả về `HTTP 503` / Load Shedding).
- Không dùng ảnh chụp tĩnh thay thế cho log, số liệu thời gian thực và kịch bản chạy lại được.
- Phân công rõ ràng cho cả **3 thành viên** và mỗi thành viên nắm vững quyết định kỹ thuật để trả lời phản biện.

---

## 1. Bảng Phân công Thời lượng & Trách nhiệm Trình diễn

| Phần | Thời lượng (Video / Live) | Người trình bày | Nội dung trọng tâm |
| :---: | :---: | :--- | :--- |
| **Phần 1** | `00:00 – 03:30` (3.5 phút)<br>*(Live: 5 phút)* | **Phan Minh Hiếu** (SV 1) | Giới thiệu câu hỏi nghiên cứu; kiến trúc dịch vụ FastAPI stateless (`/api/cpu`, `/api/queue`, `worker_semaphore = 5`); custom metrics tại `/metrics`; cấu hình `ServiceMonitor` (`5s`) và Grafana Dashboard 6 panels. |
| **Phần 2** | `03:30 – 07:30` (4.0 phút)<br>*(Live: 7 phút)* | **Nguyễn Hà Gia Huy** (SV 2) | Kiểm tra cụm Minikube, Prometheus, KEDA; đối chiếu 3 manifest (`hpa-cpu.yaml`, `keda-custom-raw.yaml`, `keda-custom-optimized.yaml`); **Demo Luồng Bình thường** (co giãn `1 -> 3` bản sao theo thời gian thực); trình bày cơ chế dọn tài nguyên, chi phí và bảo mật. |
| **Phần 3** | `07:30 – 11:30` (4.0 phút)<br>*(Live: 6 phút)* | **Lại Đức Thành** (SV 3) | **Demo Tình huống Lỗi Quá tải Hàng đợi (`HTTP 503`)**; trình diễn script thu thập dữ liệu (`collect-metrics.py`) và chạy trực tiếp `notebooks/analysis.ipynb` để sinh bảng đối chiếu trước/sau tối ưu & biểu đồ học thuật. |

---

## 2. Kịch bản Lệnh Chi tiết theo Từng Phút (Runbook)

### Chuẩn bị sẵn 4 cửa sổ Terminal & 1 Trình duyệt trước khi bấm máy:
* **Terminal 1 (Giám sát K8s):** Chạy lệnh theo dõi trạng thái Pod, HPA và ScaledObject.
* **Terminal 2 (Port-Forward / Service Tunnel):** Duy trì kết nối tới Grafana (`:3000`), Prometheus (`:9090`) và `web-service` (`:8000` hoặc NodePort tunnel).
* **Terminal 3 (Chạy Tải k6 & Thực nghiệm):** Dùng để kích hoạt `k6` hoặc `scripts/run-experiment.ps1`.
* **Trình duyệt:** Mở sẵn **Grafana Dashboard** (`http://localhost:3000`, chế độ `Last 15 minutes`, `Refresh: 5s`) và **Jupyter Notebook** (`notebooks/analysis.ipynb`).

---

### PHẦN 1: Kiến trúc Dịch vụ Stateless & Hệ thống Giám sát (Phan Minh Hiếu — 00:00 đến 03:30)

1. **Giới thiệu bài toán & điểm mù của HPA theo CPU (00:00 – 01:00):**
   * Mở sơ đồ trong [docs/architecture/architecture-and-flows.md](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/docs/architecture/architecture-and-flows.md).
   * Nêu ngắn gọn câu hỏi nghiên cứu: Tại sao HPA theo CPU thất bại khi dịch vụ bị nghẽn bởi giới hạn worker/hàng đợi chờ I/O?
2. **Trình diễn mã nguồn FastAPI & Custom Metrics (01:00 – 02:15):**
   * Mở [app/main.py](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/app/main.py), chỉ rõ:
     * `MAX_CONCURRENT_WORKERS = 5` (`worker_semaphore = asyncio.Semaphore(5)`).
     * Endpoint `/api/cpu` (tính toán căn bậc hai & lượng giác) và `/api/queue` (xếp hàng chờ vào semaphore, xử lý `work_time`, trả lỗi `HTTP 503` khi `current_waiting >= max_queue_limit`).
   * Tại **Terminal 3**, gọi thử API và xem trực tiếp luồng `/metrics`:
     ```powershell
     Invoke-RestMethod "http://127.0.0.1:8000/health"
     Invoke-RestMethod "http://127.0.0.1:8000/api/queue?work_time=0.2&max_queue_limit=20"
     (Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:8000/metrics").Content -split "`n" | Select-String "app_queue_length|app_in_flight_requests|app_processed_jobs_total"
     ```
3. **Trình diễn ServiceMonitor (`5s`) & Grafana Dashboard (02:15 – 03:30):**
   * Mở [monitoring/service-monitor.yaml](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/monitoring/service-monitor.yaml), giải thích tại sao phải đặt `interval: 5s` (để bắt kịp xung Spike 45s và đồng bộ với KEDA).
   * Chuyển sang trình duyệt **Grafana Dashboard**, giới thiệu 6 panel đồng bộ: (1) Throughput RPS & HTTP 503, (2) Queue Length & In-Flight, (3) Active Replicas, (4) p95 Latency, (5) CPU Usage, (6) RAM Usage.

---

### PHẦN 2: Hạ tầng Kubernetes, Chính sách HPA/KEDA & Luồng Bình thường (Nguyễn Hà Gia Huy — 03:30 đến 07:30)

1. **Kiểm tra trạng thái cụm & đối chiếu 3 chính sách co giãn (03:30 – 05:00):**
   * Tại **Terminal 1**, chạy lệnh xác nhận hạ tầng:
     ```powershell
     kubectl --context minikube get nodes
     kubectl --context minikube get pods -n monitoring
     kubectl --context minikube get pods -n keda
     kubectl --context minikube get apiservice v1beta1.external.metrics.k8s.io
     ```
   * Mở song song [hpa-cpu.yaml](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/k8s/autoscaling/hpa-cpu.yaml), [keda-custom-raw.yaml](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/k8s/autoscaling/keda-custom-raw.yaml) và [keda-custom-optimized.yaml](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/k8s/autoscaling/keda-custom-optimized.yaml).
   * Giải thích 3 cải tiến trong `keda-custom-optimized.yaml`:
     1. `pollingInterval: 5s`.
     2. Kết hợp 3 triggers: `app_queue_length >= 2`, `app_in_flight_requests >= 4` (80% của 5 workers — mở rộng sớm theo Định luật Little), và `p95 queue wait >= 0.25s`.
     3. Hysteresis: `scaleUp.stabilizationWindowSeconds = 0` và `scaleDown.stabilizationWindowSeconds = 60` (chống dao động flapping qua vùng trũng `50s` của tải chu kỳ).
2. **Demo Luồng Bình thường — Tự động Co giãn với KEDA Optimized (05:00 – 06:45):**
   * Áp dụng chính sách `keda-custom-optimized.yaml`:
     ```powershell
     kubectl --context minikube delete hpa web-service-hpa-cpu --ignore-not-found=true
     kubectl --context minikube delete scaledobject web-service-keda-custom-raw --ignore-not-found=true
     kubectl --context minikube apply -f k8s/autoscaling/keda-custom-optimized.yaml
     kubectl --context minikube get scaledobject,hpa
     ```
   * Bật theo dõi trực tiếp trên **Terminal 1**:
     ```powershell
     kubectl --context minikube get hpa,pods -l app.kubernetes.io/name=web-service-autoscaling -w
     ```
   * Khi tải `spike` hoặc `step` chạy trên `/api/queue`, chỉ rõ trên **Terminal 1** và **Grafana Dashboard**:
     * `in_flight` vượt ngưỡng `4` và `queue_length` xuất hiện $\rightarrow$ KEDA lập tức nâng `REPLICAS` từ `1` lên `3`.
     * Khi 3 Pod `Ready`, hàng đợi `queue_length` rút nhanh về `0` và độ trễ `p95` hạ xuống mức ổn định `~0.5s`.
3. **An toàn Bảo mật, Chi phí & Dọn tài nguyên (06:45 – 07:30):**
   * Chạy thử chế độ an toàn (Dry-Run) của script dọn dẹp:
     ```powershell
     .\scripts\cleanup.ps1
     ```
   * Nêu rõ nguyên tắc không lưu secret trong Git, tắt `automountServiceAccountToken: false` trên Pod ứng dụng và cách tính chi phí bằng `ReplicaSeconds`.

---

### PHẦN 3: Demo Tình huống Lỗi (`HTTP 503`) & Phân tích Dữ liệu Học thuật (Lại Đức Thành — 07:30 đến 11:30)

1. **Demo Tình huống Lỗi Bắt buộc — Quá tải Hàng đợi & Load Shedding HTTP 503 (07:30 – 09:30):**
   * Mở [load-tests/fault-safe-workload.js](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/load-tests/fault-safe-workload.js) (hoặc `fault-injection.js`), giải thích thiết kế tình huống lỗi: ép `WORK_TIME = 1.0s` và hạ trần `MAX_QUEUE_LIMIT = 10` với tốc độ gửi dồn dập.
   * Thực thi kịch bản lỗi tại **Terminal 3**:
     ```powershell
     .\scripts\run-experiment.ps1 -Policy custom-optimized -Scenario fault -Endpoint queue -Rate 4 -MaxVus 30
     ```
   * Quan sát trực tiếp trên **Terminal 3** và **Grafana Panel #1 & #2**:
     * Khi hàng đợi chạm trần `10/10`, ứng dụng chủ động trả về **`HTTP 503 Service Unavailable`** (bộ đếm `overload_503_total` và đường đỏ `Lỗi quá tải hàng đợi HTTP 503/s` trên Grafana nhảy lên).
     * Kiểm tra `kubectl --context minikube get pods`: Chứng minh các Pod vẫn `Running` với **`RESTARTS = 0`** (`livenessProbe /health` không bị chết nhờ cơ chế Fail-fast Load Shedding).
2. **Trình diễn Dữ liệu Thô & Tái lập Bảng, Biểu đồ trong Notebook (09:30 – 11:30):**
   * Mở thư mục `data/` cho thấy cấu trúc lưu trữ đầy đủ (`metadata.json`, `k6-summary.json`, `prometheus_timeseries.csv`, `comparison-before-after.csv`).
   * Mở [notebooks/analysis.ipynb](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/notebooks/analysis.ipynb), chạy các cell để hiển thị trực tiếp:
     * Bảng tổng hợp `comparison-aggregated.csv` và bảng đối chiếu trước/sau tối ưu `comparison-before-after.csv`.
     * Biểu đồ `tradeoff-*.png` (4 góc: `p95 Latency`, `Error Rate`, `Cost per 1k Requests`, `Scale-out Reaction & Flapping Count`) và biểu đồ đồng bộ 3 tầng `replicas-*.png` (có đầy đủ tên trục, đơn vị, điều kiện đo và số lần lặp $n$).
   * Kết luận trả lời Câu hỏi nghiên cứu và nêu rõ giới hạn áp dụng.

---

## 3. Bộ Câu hỏi & Trả lời Phản biện (Q&A Defense Cheat Sheet)

| Câu hỏi phản biện dự kiến từ Giảng viên | Gợi ý trả lời ngắn gọn, đúng bản chất kỹ thuật |
| :--- | :--- |
| **1. Tại sao HPA theo CPU lại không hiệu quả với endpoint `/api/queue`?** | Vì trong `/api/queue`, khi một yêu cầu đang xử lý (`asyncio.sleep(0.5)`) hoặc đang xếp hàng chờ `worker_semaphore`, tiến trình nhường CPU cho event loop của hệ điều hành. Do đó mức sử dụng CPU luôn dưới `15%` (thấp hơn nhiều so với ngưỡng `70%` của HPA), mặc dù toàn bộ 5 worker đã bị khóa chặt 100% và hàng đợi đang tràn. |
| **2. Tại sao trong `keda-custom-optimized.yaml` nhóm lại kết hợp cả `app_in_flight_requests` (ngưỡng 4) và `app_queue_length` (ngưỡng 2)?** | Theo Định luật Little ($L = L_s + L_q$), `app_queue_length` ($L_q$) chỉ lớn hơn 0 **sau khi** toàn bộ 5 worker của Pod đã bão hòa ($L_s = 5$). Việc thêm trigger `app_in_flight_requests >= 4` (tương ứng 80% công suất worker) đóng vai trò tín hiệu báo sớm (*leading indicator*), giúp KEDA gọi thêm Pod ngay trước khi hàng đợi bắt đầu tích tụ. |
| **3. Cơ sở nào để nhóm chọn `stabilizationWindowSeconds: 60` cho chiều Scale-Down?** | Trong kịch bản tải chu kỳ (`periodic-workload.js`), mỗi vùng trũng tải thấp kéo dài `50s` (`20s` giảm + `30s` giữ nền). Chọn cửa sổ ổn định `60s` ($> 50\text{s}$) giúp bộ điều khiển giữ nguyên số Pod qua vùng trũng mà không bị co-giãn liên tục (flapping = 0), nhưng vẫn thu hồi Pod nhanh gấp 5 lần so với mặc định `300s` của Kubernetes sau khi tải Spike kết thúc. |
| **4. Tại sao khi kiểm thử nhiều bản sao trên Minikube không được dùng `kubectl port-forward` tới Service?** | Vì `kubectl port-forward service/web-service` thực chất chỉ chọn 1 Pod tại thời điểm kết nối và mở đường hầm TCP cố định vào Pod đó; dù KEDA có mở rộng lên 3 Pod thì toàn bộ tải từ `k6` vẫn đổ dồn vào 1 Pod duy nhất. Do đó ở chế độ `Full`, nhóm sử dụng `NodePort Service` qua `minikube service --url` để đi qua `kube-proxy` cân bằng tải thực sự tới cả 3 Pod. |
| **5. Chỉ số `Cost per Request` được nhóm định lượng như thế nào khi chạy trên Minikube miễn phí?** | Nhóm tích phân số lượng bản sao theo thời gian để tính $\text{ReplicaSeconds} = \sum R_i \Delta t_i$ ($\text{pod}\cdot\text{s}$), sau đó chia cho tổng số yêu cầu thành công để tính $\text{Cost per 1,000 Requests}$ ($\text{pod}\cdot\text{s} / 10^3\text{ req}$). Chỉ số này độc lập với bảng giá nhà cung cấp và tỷ lệ thuận trực tiếp với chi phí thuê Pod thực tế trên GKE Autopilot hoặc AWS Fargate. |
