# BÁO CÁO KỸ THUẬT ĐỒ ÁN ĐIỆN TOÁN ĐÁM MÂY

**Tên đề tài:** Đề tài 3 — Tối ưu tự động co giãn cho dịch vụ web theo tải và theo chỉ số nghiệp vụ  
**Nhóm đề tài:** Nền tảng và Kiến trúc Điện toán Đám mây (Bám sát Chương 1)  
**Nhóm thực hiện:**
1. **Phan Minh Hiếu** — Phát triển Dịch vụ Web Stateless, Custom Metrics & Giám sát (Prometheus/Grafana)
2. **Nguyễn Hà Gia Huy** — Hạ tầng Kubernetes, Chính sách Co giãn (HPA/KEDA), Bảo mật & Quản trị Chi phí
3. **Lại Đức Thành** — Thiết kế Kịch bản Kiểm thử Tải (Grafana k6), Tự động hóa Thực nghiệm & Phân tích Dữ liệu

---

## CHƯƠNG 1: TỔNG QUAN ĐỀ TÀI, CÂU HỎI NGHIÊN CỨU VÀ GIẢ THUYẾT KHOA HỌC

### 1.1. Bối cảnh và Đặt vấn đề

Trong kiến trúc điện toán đám mây hiện đại, **tự động co giãn (autoscaling)** là cơ chế cốt lõi hiện thực hóa đặc tính *đàn hồi nhanh (rapid elasticity)* của đám mây theo định nghĩa NIST SP 800-145. Đối với các dịch vụ web triển khai trên nền tảng điều phối container Kubernetes, **Horizontal Pod Autoscaler (HPA)** dựa trên mức sử dụng CPU (`CPU Utilization`) là chính sách mặc định và phổ biến nhất.

Tuy nhiên, trong thực tế vận hành các dịch vụ web hiện đại (như cổng thanh toán, dịch vụ gọi API bên thứ ba, truy vấn cơ sở dữ liệu hoặc xử lý công việc bất đồng bộ theo hàng đợi), phần lớn thời gian tồn tại của một yêu cầu nằm ở trạng thái **chờ I/O hoặc xếp hàng chờ worker xử lý (queueing delay)** thay vì tiêu tốn chu kỳ lệnh CPU. Khi lưu lượng truy cập biến động nhanh (dạng xung đột biến — *Spike* hoặc dao động tuần hoàn — *Periodic*), chính sách chỉ dựa vào CPU bộc lộ hai hạn chế lớn:
1. **Điểm mù tín hiệu (Metric Blind Spot):** Các tác vụ chờ I/O hoặc bị chặn bởi giới hạn đồng thời (concurrency semaphore/connection pool) chiếm rất ít CPU, dẫn tới việc hàng đợi yêu cầu phình to, độ trễ đuôi (`p95 latency`) tăng vọt và phát sinh lỗi quá tải (`HTTP 503`), trong khi HPA vẫn nhận diện hệ thống đang "nhàn rỗi" và giữ nguyên 1 bản sao.
2. **Dao động bản sao (Flapping / Thrashing) hoặc Quá điều chỉnh (Overshoot):** Khi chuyển sang co giãn theo chỉ số tùy chỉnh (custom metrics), nếu ngưỡng kích hoạt (threshold), chu kỳ lấy mẫu (polling interval) và cửa sổ ổn định (cooldown / stabilization window) không được thiết kế đồng bộ với đặc trưng tải, hệ thống hoặc sẽ phản ứng quá chậm, hoặc sẽ tăng - giảm số bản sao liên tục qua các vùng trũng ngắn của tải chu kỳ, gây phạt khởi động lạnh (*cold start penalty*) và lãng phí tài nguyên.

### 1.2. Câu hỏi Nghiên cứu (Research Question)

> **Câu hỏi nghiên cứu trung tâm:**  
> *Chính sách co giãn theo CPU có đủ hiệu quả đối với tải biến động nhanh, hay cần kết hợp độ trễ, hàng đợi và số yêu cầu đang chờ?*

### 1.3. Giả thuyết Nghiên cứu (Hypotheses)

Để trả lời câu hỏi nghiên cứu trên một cách định lượng và có thể kiểm chứng, nhóm đặt ra 3 giả thuyết khoa học tách biệt:

* **Giả thuyết $H_1$ (Hiệu lực của HPA theo CPU):**  
  Chính sách co giãn theo CPU (`baseline-cpu`, ngưỡng `70% Utilization`) đáp ứng tốt công việc thuần tính toán CPU (`/api/cpu`), nhưng **không thể kích hoạt mở rộng kịp thời** đối với công việc xử lý theo hàng đợi (`/api/queue`) do mức tiêu thụ CPU trên mỗi Pod luôn thấp hơn ngưỡng kích hoạt ngay cả khi toàn bộ worker đã bão hòa 100%.
* **Giả thuyết $H_2$ (Hiệu quả của KEDA kết hợp đa chỉ số nghiệp vụ & QoS):**  
  Chính sách co giãn sự kiện bằng KEDA kết hợp đồng thời **số yêu cầu đang xử lý (`app_in_flight_requests`)**, **độ dài hàng đợi chờ (`app_queue_length`)** và **độ trễ chờ p95 (`app_queue_wait_duration_seconds`)** với chu kỳ lấy mẫu `5s` giúp phát hiện sớm trạng thái bão hòa worker (ở mức 80% công suất theo Định luật Little), rút ngắn thời gian phản ứng mở rộng (`scale_out_s`), giảm mạnh độ trễ `p95_ms` và giảm tỷ lệ lỗi quá tải `HTTP 503` so với HPA CPU và KEDA cơ sở chưa tối ưu.
* **Giả thuyết $H_3$ (Kiểm soát dao động Flapping và Chi phí bằng Hysteresis):**  
  Việc thiết lập cơ chế trễ đóng-ngắt (**Hysteresis**) thông qua cửa sổ ổn định chiều tăng `stabilizationWindowSeconds = 0s` (mở rộng tức thời) và chiều giảm `stabilizationWindowSeconds = 60s` (lớn hơn thời gian vùng trũng `50s` của tải chu kỳ, nhưng nhỏ hơn 5 lần so với mặc định `300s`) giúp **triệt tiêu hiện tượng dao động đảo chiều (`flapping_count = 0`)** giữa các đợt sóng tải chu kỳ, đồng thời giảm chi phí tài nguyên (`ReplicaSeconds` và `Cost per 1,000 Requests`) sau khi tải đột biến kết thúc.

### 1.4. Mục tiêu và Phạm vi Nghiên cứu

1. **Mục tiêu:**
   * Thiết kế, triển khai và so sánh thực nghiệm 3 cấu hình chính sách co giãn trên cùng một dịch vụ web stateless: (1) `baseline-cpu` (HPA theo CPU), (2) `custom-unoptimized` (KEDA theo hàng đợi đơn thuần, tham số mặc định), và (3) `custom-optimized` (KEDA đa chỉ số kết hợp tinh chỉnh ngưỡng, chu kỳ lấy mẫu `5s` và cửa sổ ổn định Hysteresis `60s`).
   * Định lượng mối quan hệ đánh đổi (trade-off) giữa **tốc độ phản ứng (`scale_out_s`)**, **chất lượng dịch vụ (`p95_ms`, `error_rate_pct`)**, **độ ổn định (`flapping_count`)** và **chi phí tài nguyên (`ReplicaSeconds`, `cost_per_1k_req_replica_s`)**.
   * Đưa ra khuyến nghị lựa chọn chính sách và bộ tham số cho các hệ thống thực tế kèm giới hạn áp dụng rõ ràng.
2. **Phạm vi thực nghiệm:**
   * Vận hành 100% trên cụm Kubernetes cục bộ (**Minikube Single-Node** trên Docker Engine, cấp phát 2 vCPU, 3072 MiB RAM, chi phí dịch vụ đám mây \$0).
   * Giới hạn số bản sao ứng dụng từ `minReplicas = 1` đến `maxReplicas = 3` để đảm bảo không vượt quá dung lượng bộ nhớ vật lý của node cục bộ và tránh nhiễu do tranh chấp CPU với bộ công cụ giám sát.

---

## CHƯƠNG 2: CƠ SỞ LÝ THUYẾT

### 2.1. Co giãn Ngang (Horizontal Scaling) và Co giãn Dọc (Vertical Scaling)

| Tiêu chí | Co giãn dọc (Vertical Scaling — Scale Up/Down) | Co giãn ngang (Horizontal Scaling — Scale Out/In) |
| :--- | :--- | :--- |
| **Bản chất** | Tăng/giảm tài nguyên (`CPU`, `RAM`) cho một thực thể (Pod/VM) hiện có. | Tăng/giảm số lượng bản sao (`Replicas`) xử lý song song đằng sau bộ cân bằng tải. |
| **Giới hạn vật lý** | Bị chặn trên bởi cấu hình phần cứng của máy chủ vật lý (Node capacity). | Mở rộng linh hoạt trên nhiều Pod/Node trong cụm. |
| **Độ gián đoạn** | Thường yêu cầu khởi động lại Pod (hoặc giới hạn bởi In-place Pod Vertical Scaling). | Không gây gián đoạn dịch vụ nếu ứng dụng được thiết kế **phi trạng thái (Stateless)**. |
| **Áp dụng trong đồ án** | Cố định `requests: 100m CPU, 96Mi RAM` và `limits: 500m CPU, 256Mi RAM` để kiểm soát biến. | Thay đổi động số lượng Pod từ `1` đến `3` thông qua HPA v2 và KEDA. |

### 2.2. Mở rộng Phản ứng (Reactive) vs. Chủ động (Proactive); Cooldown và Hysteresis

1. **Mở rộng phản ứng (Reactive Scaling) và Mở rộng chủ động/sớm (Proactive / Early-Warning Scaling):**
   * *Phản ứng trễ (Lagging Reactive):* Chỉ kích hoạt khi hệ thống đã rơi vào trạng thái suy giảm chất lượng (ví dụ: đợi `app_queue_length >= 3` hoặc đợi trung bình CPU vượt ngưỡng trong 1 phút).
   * *Phản ứng sớm dựa trên chỉ số dẫn đường (Leading Indicator):* Giám sát tỷ lệ lấp đầy các khe xử lý đồng thời (`app_in_flight_requests` đạt 4/5 workers = 80% saturation) để kích hoạt tạo bản sao mới **trước khi** hàng đợi bắt đầu dồn ứ.
2. **Hiện tượng Dao động (Flapping / Thrashing), Cooldown và Hysteresis:**
   * Khi tải dao động quanh ngưỡng kích hoạt, bộ điều khiển ngây thơ sẽ liên tục ra lệnh thêm Pod tại thời điểm $t_1$, hủy Pod tại $t_2$, rồi lại phải tạo lại Pod tại $t_3$. Quá trình này gây lãng phí chu kỳ khởi tạo container và làm tăng độ trễ do Pod mới chưa sẵn sàng.
   * **Cooldown Period (Thời gian nghỉ):** Khoảng thời gian tối thiểu phải chờ sau một hành động co giãn trước khi thực hiện hành động thu hẹp tiếp theo.
   * **Hysteresis (Độ trễ đóng - ngắt bất đối xứng):** Thiết lập quy tắc mở rộng và thu hẹp có hằng số thời gian khác nhau:
     * Chiều mở rộng (`scaleUp`): `stabilizationWindowSeconds = 0s` — ưu tiên bảo vệ SLA/QoS ngay khi xuất hiện xung tải.
     * Chiều thu hẹp (`scaleDown`): `stabilizationWindowSeconds = 60s` — bộ điều khiển lấy giá trị số bản sao khuyến nghị **cao nhất** trong suốt cửa sổ 60 giây gần nhất:
       $$R_{\text{applied}}(t) = \max_{\tau \in [t - W_{\text{down}},\, t]} R_{\text{desired}}(\tau)$$
       Nếu tải chỉ giảm tạm thời trong khoảng $< 60\text{s}$ (như vùng trũng `50s` của kịch bản tải Chu kỳ), $R_{\text{applied}}(t)$ vẫn giữ nguyên ở mức cao, triệt tiêu hoàn toàn dao động.

### 2.3. Định luật Hàng đợi Nhập môn và Mô hình Toán học của Dịch vụ

Xét một dịch vụ web có $N$ bản sao (Pods) đang hoạt động. Mỗi bản sao được cấu hình giới hạn số luồng công việc xử lý đồng thời là $c_1 = \text{MAX\_CONCURRENT\_WORKERS} = 5$ (thông qua `asyncio.Semaphore(5)`) và giới hạn hàng đợi tối đa $K_1 = \text{max\_queue\_limit}$.

1. **Định luật Little (Little's Law):**  
   Ở trạng thái dừng thống kê, số lượng yêu cầu trung bình có mặt trong hệ thống ($L$) bằng tích của tốc độ yêu cầu đến trung bình ($\lambda$, đơn vị: $\text{req/s}$) và tổng thời gian lưu lại trong hệ thống trung bình của một yêu cầu ($W$, đơn vị: $\text{s}$):
   $$L = \lambda \cdot W$$
   Tách hệ thống thành hai vùng: vùng đang được phục vụ bởi các worker ($L_s = \text{in\_flight}$) và vùng đang nằm chờ trong hàng đợi ($L_q = \text{queue\_length}$), với thời gian xử lý trung bình $W_s = \text{work\_time}$ và thời gian chờ trong hàng đợi $W_q$:
   $$L = L_s + L_q = \lambda (W_s + W_q)$$
2. **Ngưỡng Bão hòa (Saturation Capacity) và Điều kiện Không nghẽn Hàng đợi:**  
   Với tổng số worker trên toàn cụm là $C(N) = N \cdot c_1 = 5N$ và thời gian xử lý một công việc là $W_s = 0.5\text{s}$, thông lượng phục vụ tối đa của $N$ bản sao là:
   $$\mu_{\max}(N) = \frac{C(N)}{W_s} = \frac{5N}{0.5} = 10N \quad (\text{req/s})$$
   * Với $N = 1$ Pod: $\mu_{\max}(1) = 10\text{ req/s}$.
   * Hệ số sử dụng worker (Worker Utilization / Saturation $\rho$):
     $$\rho = \frac{\lambda}{\mu_{\max}(N)} = \frac{L_s}{5N}$$
   * Khi $\lambda \le 10\text{ req/s}$ ($\rho \le 1$): $L_s = \lambda W_s \le 5$, hàng đợi $L_q \approx 0$, thời gian phản hồi $W \approx W_s = 0.5\text{s}$.
   * Khi $\lambda > 10\text{ req/s}$ (ví dụ: ở đỉnh tải Bậc thang/Chu kỳ $\lambda = 16\text{ req/s}$ hoặc đỉnh tải Spike $\lambda = 24\text{ req/s}$) mà hệ thống vẫn giữ $N = 1$ Pod:
     Tốc độ tích tụ hàng đợi là $\frac{dL_q}{dt} = \lambda - \mu_{\max}(1) > 0$. Hàng đợi tăng tuyến tính theo thời gian cho tới khi chạm trần $K_1 = \text{max\_queue\_limit}$, lúc đó mọi yêu cầu mới bị từ chối với mã lỗi **`HTTP 503 Service Unavailable`** (mô hình hàng đợi hữu hạn $M/M/c/K$).
   * Khi KEDA mở rộng lên $N = 3$ Pods: $\mu_{\max}(3) = 30\text{ req/s} > 24\text{ req/s}$ ($\rho = 24/30 = 80\% < 1$), hàng đợi được giải phóng nhanh chóng về $0$.

### 2.4. Định nghĩa Hệ thống Chỉ số Đánh giá (Metrics Definitions)

1. **Độ trễ phân vị thứ 95 (`p95 Latency` — $\text{ms}$):** Giá trị thời gian phản hồi mà 95% tổng số yêu cầu hoàn thành nhanh hơn hoặc bằng giá trị đó. Chỉ số này phản ánh trải nghiệm của nhóm người dùng chịu ảnh hưởng nặng nhất khi hàng đợi bị nghẽn.
2. **Thông lượng (`Throughput` — $\text{req/s}$):** Số lượng yêu cầu HTTP được hệ thống xử lý trên một đơn vị giây.
3. **Độ bão hòa (`Saturation` — $\%$):** Tỷ lệ phần trăm tài nguyên đang bị chiếm dụng so với ngưỡng thiết kế (gồm `CPU Utilization` và `Worker Saturation` $= \frac{\text{in\_flight}}{5 \times \text{Replicas}} \times 100\%$).
4. **Tỷ lệ lỗi (`Error Rate` — $\%$):** Tỷ lệ yêu cầu thất bại (không trả về `HTTP 200`), bao gồm lỗi quá tải hàng đợi `HTTP 503` (`rejected_overload`) và lỗi quá thời gian chờ (`request timeout`).
5. **Chi phí Bản sao theo Thời gian (`ReplicaSeconds`) và Chi phí trên mỗi Yêu cầu (`Cost per Request`):**
   $$\text{ReplicaSeconds} = \sum_{i=1}^{M} R_i \cdot \Delta t_i \quad (\text{pod}\cdot\text{s})$$
   $$\text{Cost per 1,000 Requests} = \frac{\text{ReplicaSeconds}}{N_{\text{success}}} \times 1000 \quad \left(\frac{\text{pod}\cdot\text{s}}{10^3\text{ req}}\right)$$
6. **Số lần Dao động Đảo chiều (`Flapping Count`):** Số lần chuỗi thời gian số lượng bản sao đảo chiều liên tiếp ($\text{Tăng} \rightarrow \text{Giảm}$ hoặc $\text{Giảm} \rightarrow \text{Tăng}$) trong khoảng thời gian $\Delta t \le 90\text{s}$.

### 2.5. Cơ chế HPA v2, KEDA và Phân tích Chuỗi Độ trễ Co giãn (Cold Start & Control Loop Lag)

Công thức tính số bản sao mong muốn của Kubernetes HPA v2:
$$R_{\text{desired}} = \left\lceil R_{\text{current}} \times \frac{M_{\text{current}}}{M_{\text{target}}} \right\rceil$$

Khi có nhiều chỉ số (multi-trigger trong KEDA `ScaledObject`), HPA tính $R_{\text{desired}}^{(k)}$ cho từng trigger $k$ và chọn giá trị lớn nhất:
$$R_{\text{desired}} = \min\left(R_{\max},\, \max\left(R_{\min},\, \max_{k} R_{\text{desired}}^{(k)}\right)\right)$$

Tổng thời gian phản ứng mở rộng thực tế ($T_{\text{scale\_out}}$) là tổng của 5 thành phần độ trễ nối tiếp:
$$T_{\text{scale\_out}} = \tau_{\text{metric\_scrape}} + \tau_{\text{scaler\_poll}} + \tau_{\text{hpa\_sync}} + \tau_{\text{pod\_schedule\_boot}} + \tau_{\text{readiness\_probe}}$$
* $\tau_{\text{metric\_scrape}}$: Chu kỳ Prometheus cào `/metrics` (đã tối ưu từ `30s` xuống **`5s`**).
* $\tau_{\text{scaler\_poll}}$: Chu kỳ KEDA truy vấn Prometheus (đã tối ưu từ `30s` xuống **`5s`**).
* $\tau_{\text{hpa\_sync}}$: Chu kỳ vòng lặp điều khiển HPA (mặc định `15s` trong `kube-controller-manager`).
* $\tau_{\text{pod\_schedule\_boot}}$: Thời gian lập lịch Pod, khởi tạo container Python/Uvicorn (~`2–4s` khi image đã cache cục bộ).
* $\tau_{\text{readiness\_probe}}$: Thời gian chờ `readinessProbe` (`periodSeconds: 5s`) xác nhận `/health` trả về `200 OK` trước khi đưa Pod vào `Endpoints` của Service.

---

## CHƯƠNG 3: THIẾT KẾ KIẾN TRÚC VÀ PHƯƠNG PHÁP THỰC NGHIỆM

### 3.1. Ma trận Truy vết Yêu cầu (Requirements Traceability Matrix)

| Mã yêu cầu | Nội dung yêu cầu của đề cương | Thành phần hiện thực trong dự án | Tệp minh chứng trong kho mã nguồn |
| :--- | :--- | :--- | :--- |
| **REQ-01** | Dịch vụ stateless có endpoint tạo tải CPU và endpoint mô phỏng hàng đợi | Ứng dụng FastAPI với `/api/cpu`, `/api/queue` (`asyncio.Semaphore(5)`), `/health`, `/metrics` | [app/main.py](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/app/main.py), [deployment.yaml](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/k8s/base/deployment.yaml) |
| **REQ-02** | So sánh chính sách theo CPU và chính sách theo chỉ số tùy chỉnh (trước & sau tối ưu) | 3 manifest: HPA CPU (`70%`), KEDA Raw (`queue >= 3`, poll `30s`), KEDA Optimized (3 triggers, poll `5s`, hysteresis `60s`) | [hpa-cpu.yaml](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/k8s/autoscaling/hpa-cpu.yaml), [keda-custom-raw.yaml](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/k8s/autoscaling/keda-custom-raw.yaml), [keda-custom-optimized.yaml](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/k8s/autoscaling/keda-custom-optimized.yaml) |
| **REQ-03** | Chạy cùng workload dạng bậc thang, spike, chu kỳ và tình huống lỗi | 4 kịch bản Grafana k6 dùng `ramping-arrival-rate` và `constant-arrival-rate` | [step-workload.js](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/load-tests/step-workload.js), [spike-workload.js](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/load-tests/spike-workload.js), [periodic-workload.js](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/load-tests/periodic-workload.js), [fault-safe-workload.js](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/load-tests/fault-safe-workload.js) |
| **REQ-04** | Dashboard thể hiện đồng bộ tải, số bản sao và độ trễ | Grafana Dashboard 6 panels + ServiceMonitor chu kỳ `5s` | [grafana-dashboard.json](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/monitoring/grafana-dashboard.json), [service-monitor.yaml](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/monitoring/service-monitor.yaml) |
| **REQ-05** | Thu thập dữ liệu thô CSV/JSON và tái tạo bảng, biểu đồ có tên trục, đơn vị, điều kiện đo, số lần lặp | Script thu thập Prometheus Range API + Jupyter Notebook phân tích tự động | [collect-metrics.py](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/scripts/collect-metrics.py), [analysis.ipynb](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/notebooks/analysis.ipynb) |
| **REQ-06** | Hướng dẫn tái lập, dọn tài nguyên, ước tính chi phí và bảo mật | Tài liệu hướng dẫn chi tiết và script PowerShell có chế độ Dry-Run an toàn | [reproducibility-guide.md](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/docs/reproducibility-guide.md), [cost-and-security.md](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/docs/cost-and-security.md), [cleanup.ps1](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/scripts/cleanup.ps1) |

### 3.2. Thiết kế Dịch vụ Web Stateless và Chỉ số Tùy chỉnh (Custom Metrics)

Ứng dụng [app/main.py](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/app/main.py) được viết bằng Python FastAPI, hoàn toàn không lưu trạng thái phiên (stateless) giữa các yêu cầu và xuất các chỉ số Prometheus tại `/metrics`:

| Tên chỉ số Prometheus | Kiểu (Type) | Ý nghĩa đo lường & Vai trò trong Autoscaling |
| :--- | :--- | :--- |
| `app_in_flight_requests` | `Gauge` | Số lượng yêu cầu đang nằm trong hệ thống tại thời điểm tức thời (tăng khi vào middleware, giảm khi trả phản hồi). Dùng làm chỉ số báo sớm mức bão hòa worker (`in-flight-saturation`). |
| `app_queue_length` | `Gauge` | Số lượng yêu cầu đang xếp hàng chờ đến lượt vào `worker_semaphore` (chưa được worker xử lý). Dùng làm chỉ số đo độ nghẽn hàng đợi (`queue-backlog`). |
| `app_queue_wait_duration_seconds` | `Histogram` | Phân phối thời gian một yêu cầu phải đứng chờ trong hàng đợi trước khi vào được `worker_semaphore`. Dùng để tính phân vị `p95` làm chốt chặn QoS (`p95-queue-wait-latency`). |
| `app_processed_jobs_total` | `Counter` | Tổng số yêu cầu đã xử lý phân loại theo `endpoint` (`cpu`, `queue`) và `status` (`success`, `rejected_overload`, `client_cancelled`). |
| `http_request_duration_seconds` | `Histogram` | Thời gian phản hồi toàn trình HTTP (do `prometheus-fastapi-instrumentator` xuất). |

### 3.3. Thiết kế 3 Chính sách Co giãn Đối chứng

| Thuộc tính | Chính sách 1: `baseline-cpu` ([hpa-cpu.yaml](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/k8s/autoscaling/hpa-cpu.yaml)) | Chính sách 2: `custom-unoptimized` ([keda-custom-raw.yaml](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/k8s/autoscaling/keda-custom-raw.yaml)) | Chính sách 3: `custom-optimized` ([keda-custom-optimized.yaml](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/k8s/autoscaling/keda-custom-optimized.yaml)) |
| :--- | :--- | :--- | :--- |
| **Bộ điều khiển** | Kubernetes HPA v2 (`metrics.k8s.io`) | KEDA `ScaledObject` (`external.metrics.k8s.io`) | KEDA `ScaledObject` (`external.metrics.k8s.io`) |
| **Giới hạn bản sao** | `minReplicas: 1`, `maxReplicas: 3` | `minReplicaCount: 1`, `maxReplicaCount: 3` | `minReplicaCount: 1`, `maxReplicaCount: 3` |
| **Chu kỳ Polling** | Mặc định HPA (`15s` trên Metrics Server `60s`) | Mặc định KEDA (`30s`) | **`5s`** (đồng bộ với `ServiceMonitor` `5s`) |
| **Chỉ số & Ngưỡng kích hoạt** | `Resource CPU Utilization`: **`70%`** (tương đương `70m` trên `100m` request) | 1 Trigger duy nhất:<br>- `sum(app_queue_length)`: `AverageValue = 3` | Kết hợp **3 Triggers**:<br>1. `sum(app_queue_length)`: `AverageValue = 2`<br>2. `sum(app_in_flight_requests)`: `AverageValue = 4` (80% của 5 workers)<br>3. `p95(app_queue_wait_duration_seconds)`: `Value = 0.25s` (250ms) |
| **Cửa sổ ổn định Scale-Up** | Mặc định (`0s`, tối đa `4 Pods` hoặc `100% / 15s`) | Mặc định | `stabilizationWindowSeconds: 0`, tối đa `+2 Pods` hoặc `+100% / 15s` |
| **Cửa sổ ổn định Scale-Down (Hysteresis)** | Mặc định (`300s`) | Mặc định (`300s`, `cooldownPeriod: 300s`) | **`stabilizationWindowSeconds: 60`**, `cooldownPeriod: 60s`, giảm tối đa `-1 Pod / 30s` |

### 3.4. Thiết kế Kịch bản Tải Thực nghiệm và Kiểm soát Biến

Để đảm bảo tính khách quan khoa học, trước mỗi lượt đo, script [run-all-experiments.ps1](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/scripts/run-all-experiments.ps1) thực hiện quy trình chuẩn hóa trạng thái ban đầu:
1. Gỡ bỏ chính sách co giãn cũ, chờ tài nguyên HPA/ScaledObject giải phóng hoàn toàn.
2. Đưa `Deployment/web-service` về đúng `1` bản sao (`--replicas=1`) và chờ `rollout status` hoàn tất.
3. Kiểm tra dung lượng bộ nhớ trống của máy chủ Windows và container Minikube trước khi áp dụng chính sách mới.
4. Định tuyến lưu lượng qua **Kubernetes NodePort Service Tunnel** (`web-service-bench`) để đảm bảo yêu cầu từ `k6` được `kube-proxy` phân phối đều tới tất cả các Pod `Ready` khi mở rộng từ 1 lên 3 bản sao (khắc phục hạn chế của `kubectl port-forward` vốn chỉ gắn cứng vào 1 Pod duy nhất).

**Chi tiết 4 kịch bản tải Grafana k6:**

| Kịch bản | Tệp kịch bản | Tổng thời lượng | Quy luật biến thiên tốc độ yêu cầu đến $\lambda(t)$ | Mục đích kiểm chứng |
| :--- | :--- | :---: | :--- | :--- |
| **1. Bậc thang (`step`)** | [step-workload.js](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/load-tests/step-workload.js) | `240s` | `30s` $\to 1R$; `60s` $\to 2R$; `60s` $\to 4R$; `60s` $\to 2R$; `30s` $\to 1R$ | Đánh giá khả năng bám sát mức tải tăng/giảm tuần tự theo từng nấc công suất. |
| **2. Xung đột biến (`spike`)** | [spike-workload.js](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/load-tests/spike-workload.js) | `145s` | `30s` giữ $1R$; tăng vọt lên $6R$ trong `5s` và giữ `45s`; hạ về $1R$ trong `5s` và giữ `60s` | Đánh giá tốc độ phản ứng `scale_out_s`, khả năng hấp thụ xung tải gấp 6 lần và tốc độ thu hồi bản sao sau khi xung kết thúc. |
| **3. Chu kỳ (`periodic`)** | [periodic-workload.js](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/load-tests/periodic-workload.js) | `300s` | Lặp lại **3 chu kỳ sóng** (mỗi chu kỳ `100s`):<br>- Đỉnh sóng (`50s`): `20s` tăng lên $4R$ + `30s` giữ ở $4R$<br>- Vùng trũng (`50s`): `20s` giảm về $1R$ + `30s` giữ ở $1R$ | Kiểm chứng hiệu quả chống dao động (**Flapping Prevention**) của cửa sổ ổn định `stabilizationWindowSeconds: 60s` qua 2 vùng trũng `50s`. |
| **4. Tình huống lỗi (`fault`)** | [fault-safe-workload.js](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/load-tests/fault-safe-workload.js) / [fault-injection.js](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/load-tests/fault-injection.js) | `90s` | Tải hằng số cường độ cao với `work_time = 1.0s` và `max_queue_limit = 10` | Chứng minh cơ chế bảo vệ quá tải trả về `HTTP 503` (Load Shedding), ghi nhận metric `rejected_overload` và khả năng tự phục hồi. |

*(Trong đó: với endpoint `cpu`, $R = 1\text{ req/s}$, `Iterations = 1,000,000`; với endpoint `queue`, $R = 4\text{ req/s}$, `WorkTime = 0.5s`, `MaxQueueLimit = 20` — được tính toán theo Định luật Little ở Mục 2.3 để tải nền $1R = 4\text{ req/s}$ chạy vừa trên 1 Pod và tải đỉnh $4R = 16\text{ req/s}$, $6R = 24\text{ req/s}$ vượt ngưỡng bão hòa $10\text{ req/s}$ của 1 Pod).*

---

## CHƯƠNG 4: KẾT QUẢ QUAN SÁT, DIỄN GIẢI NGUYÊN NHÂN VÀ GIỚI HẠN

### 4.1. Bằng chứng Kiểm chứng Hạ tầng và Hoạt động Co giãn Thực tế

Các bằng chứng log hệ thống đã thu thập trực tiếp từ cụm Minikube trong quá trình tích hợp và chạy thử nghiệm được lưu trữ tại:
1. **Minh chứng KEDA ScaledObject & HPA hoạt động thực tế:**
   * [docs/final-report/evidence/h07-scaledobject.txt](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/docs/final-report/evidence/h07-scaledobject.txt): Xác nhận `ScaledObject/web-service-keda-custom-raw` ở trạng thái `Ready = True`, `HPAActive = True`, đăng ký thành công external metric `s0-prometheus`.
   * [docs/final-report/evidence/h07-hpa.txt](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/docs/final-report/evidence/h07-hpa.txt): Ghi nhận sự kiện `Normal SuccessfulRescale: New size: 3; reason: external metric s0-prometheus above target` và trạng thái `ScaleDownStabilized` khi tải giảm.
   * [docs/final-report/evidence/h07-keda-load.txt](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/docs/final-report/evidence/h07-keda-load.txt): Log 24 luồng worker gửi tải đồng thời vào `/api/queue` kích hoạt KEDA mở rộng từ `1` lên `3` bản sao với `failures = 0`.
2. **Minh chứng dữ liệu đo kịch bản Bậc thang trên HPA CPU (`step/cpu`):**
   * Lưu tại [data/baseline-cpu/auto-step-cpu-20261109-134818/](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/data/baseline-cpu/auto-step-cpu-20261109-134818/k6-summary.json): Hoàn thành `240s` thực nghiệm với `524` yêu cầu, tỷ lệ lỗi `0%`, độ trễ trung vị `126.02 ms`, `p95 = 150.29 ms`, và thu thập đầy đủ 57 mẫu chuỗi thời gian `prometheus_timeseries.csv` (độ phủ 7/7 chỉ số đạt 100% trong `prometheus_coverage.json`).

### 4.2. Phân tích Cơ chế và Giải thích Nguyên nhân Hiện tượng Quan sát được

Dựa trên mô hình lý thuyết Chương 2 và dữ liệu thực nghiệm, nhóm giải thích nguyên nhân gốc rễ của 3 hiện tượng kỹ thuật trọng tâm theo yêu cầu đề tài:

#### (1) Nguyên nhân của Độ trễ Co giãn (Scaling Latency / Reaction Lag)
Độ trễ từ lúc tải tăng đến khi bản sao mới thực sự gánh tải ($T_{\text{scale\_out}}$) xuất phát từ sự cộng dồn của 4 khâu:
1. **Độ trễ phát hiện tại nguồn chỉ số (Signal Generation Lag):**
   * Với `baseline-cpu`: `Metrics Server` tính trung bình trượt cửa sổ CPU container; hơn nữa, với `/api/queue`, `asyncio.sleep` nhường CPU cho event loop nên độ sử dụng CPU giữ ở mức $< 10\%$, dẫn đến $T_{\text{scale\_out}} = \infty$ (không bao giờ co giãn).
   * Với `custom-unoptimized` (`keda-custom-raw.yaml`): Chỉ theo dõi `app_queue_length` với ngưỡng `3`. Do 5 yêu cầu đầu tiên đi thẳng vào `worker_semaphore` mà không làm tăng `app_queue_length`, hệ thống mất toàn bộ khoảng thời gian từ lúc tải tăng đến khi cả 5 worker bị khóa chặt cộng thêm thời gian tích tụ 3 yêu cầu chờ trên mỗi Pod thì tín hiệu mới vượt ngưỡng.
   * Với `custom-optimized` (`keda-custom-optimized.yaml`): Nhờ bổ sung trigger `app_in_flight_requests >= 4` (80% công suất worker), tín hiệu vượt ngưỡng xuất hiện **ngay khi Pod thứ nhất mới sử dụng 4/5 worker**, rút ngắn giai đoạn phát hiện sớm trước khi hàng đợi hình thành.
2. **Độ trễ lấy mẫu & Polling (Scraping & Polling Lag):**
   * Ở cấu hình chưa tối ưu, chu kỳ `pollingInterval = 30s` của KEDA cộng với chu kỳ scrape `30s` của Prometheus có thể tạo ra độ trễ pha lên tới `30–60s` — dài hơn cả thời gian tồn tại của đỉnh xung Spike (`45s`).
   * Khi đồng bộ cả `ServiceMonitor`, Prometheus `scrapeInterval` và KEDA `pollingInterval` về **`5s`**, độ trễ truyền tin từ ứng dụng tới KEDA giảm xuống chỉ còn tối đa `5–10s`.
3. **Độ trễ vòng lặp HPA và Khởi tạo Pod (Control Loop & Cold Start):**
   * Sau khi KEDA cập nhật External Metrics API, HPA Controller cần tối đa 1 chu kỳ đồng bộ (`15s`) để cập nhật `Deployment.spec.replicas`, tiếp theo là `2–4s` khởi tạo container Uvicorn và `5s` chu kỳ `readinessProbe` (`/health`). Như vậy, giới hạn vật lý dưới (lower bound) của $T_{\text{scale\_out}}$ trên Kubernetes đối với container đã cache image là khoảng **`15–25 giây`**.

#### (2) Nguyên nhân của Hiện tượng Quá điều chỉnh (Overshoot) và Dao động (Flapping)
1. **Quá điều chỉnh chiều tăng (Scale-Up Overshoot):**
   * Khi tải đột ngột dồn vào 1 Pod, hàng đợi `app_queue_length` tăng vọt (ví dụ lên 12 yêu cầu chờ). Theo công thức tỷ lệ tuyến tính của HPA ($R_{\text{desired}} = \lceil 1 \times 12 / 2 \rceil = 6$), bộ điều khiển có xu hướng yêu cầu số bản sao lớn hơn mức cần thiết ở trạng thái dừng vì nó tính cả lượng hàng đợi tồn đọng tạm thời. Việc chặn trần `maxReplicaCount: 3` và giới hạn tốc độ mở rộng `+2 Pods / 15s` giúp ngăn hệ thống cấp phát tràn lan làm cạn kiệt RAM của node.
2. **Dao động tăng - giảm bản sao (Flapping) trong tải Chu kỳ:**
   * Trong kịch bản `periodic-workload.js`, mỗi chu kỳ `100s` gồm `50s` tải cao ($4R$) và `50s` vùng trũng tải thấp ($1R$).
   * Nếu cửa sổ ổn định chiều giảm (`scaleDown.stabilizationWindowSeconds`) đặt nhỏ hơn `50s` (ví dụ `15s` hoặc `30s`), ngay giữa vùng trũng hệ thống sẽ xóa bớt 2 Pod. Chỉ 20 giây sau, đợt sóng tiếp theo ập đến buộc hệ thống phải tạo lại 2 Pod từ đầu (chịu phạt cold start `15–25s` ở mọi chu kỳ sóng!).
   * Ngược lại, trong `custom-unoptimized` dùng mặc định `300s` của HPA, hệ thống giữ nguyên 3 Pod suốt 5 phút sau khi tải giảm, gây lãng phí `ReplicaSeconds` trong kịch bản `spike`.
   * Việc chọn **`stabilizationWindowSeconds: 60s`** trong `custom-optimized` giải quyết trọn vẹn bài toán đánh đổi: $60\text{s} > 50\text{s}$ (vùng trũng chu kỳ) nên số bản sao giữ phẳng tuyệt đối ở mức 3 qua các đợt sóng chu kỳ (`flapping_count = 0`), nhưng ngay khi kịch bản Spike kết thúc được `60s`, hệ thống bắt đầu thu hồi từng Pod (`-1 Pod / 30s`), tiết kiệm đáng kể `ReplicaSeconds`.

#### (3) Nguyên nhân Thiếu Tài nguyên và Vai trò của Cơ chế Load Shedding (HTTP 503)
* Khi tốc độ yêu cầu đến $\lambda$ vượt quá tổng công suất phục vụ tối đa của toàn cụm ($\lambda > \mu_{\max}(3) = 30\text{ req/s}$, hoặc trong thời gian $15–25\text{s}$ chờ Pod mới khởi động trong kịch bản `fault`), hàng đợi tăng nhanh.
* Nếu không có giới hạn `max_queue_limit`, hàng ngàn coroutine sẽ tích tụ trong bộ nhớ và làm nghẽn event loop, khiến `/health` liveness probe bị timeout $\rightarrow$ Kubernetes giết và khởi động lại Pod đang chạy $\rightarrow$ gây sập dây chuyền (*cascading failure*) trên các Pod còn lại.
* Nhờ kiểm tra `if current_waiting >= max_queue_limit` và trả về `HTTP 503` ngay lập tức (chi phí xử lý $< 1\text{ms}$), các worker đang chạy được bảo vệ an toàn, `livenessProbe` và `readinessProbe` luôn thành công (`0` container restart), và hệ thống tự động phục hồi ngay khi tải giảm hoặc khi Pod mới tham gia nhận tải.

### 4.3. Sai số Đo lường và Giới hạn của Nghiên cứu (Limitations & Threats to Validity)

1. **Giới hạn phần cứng Single-Node Minikube:** Cả công cụ tạo tải `k6`, Docker Engine, Minikube control plane, Prometheus, Grafana, KEDA và 3 Pod ứng dụng cùng chia sẻ tài nguyên trên một máy vật lý. Do đó, độ trễ tuyệt đối (`ms`) chịu ảnh hưởng một phần từ lập lịch CPU của hệ điều hành host.
2. **Độ phân giải lấy mẫu Rời rạc (`5s`):** Các chỉ số chuỗi thời gian (`scale_out_s`, `scale_in_s`, `ReplicaSeconds`) được lấy mẫu với bước nhảy $\Delta t = 5\text{s}$, do đó phép đo thời gian phản ứng có sai số lượng tử hóa tự nhiên là $\pm 5\text{s}$.
3. **Chưa bao gồm độ trễ Cluster Autoscaler và Kéo Image từ Registry từ xa:** Trong thực nghiệm, Docker image `web-service-autoscaling:dev` đã được nạp sẵn (`imagePullPolicy: IfNotPresent`) trên một node duy nhất. Trên môi trường đám mây thực tế, nếu node hết chỗ chứa và phải xin cấp phát máy ảo mới (Node Provisioning), thời gian cold start có thể tăng thêm từ `60s` đến `180s`.
4. **Hàng đợi trong bộ nhớ (In-Memory Per-Pod Queue):** Biến `app_queue_length` trong nghiên cứu này mô phỏng hàng đợi nội bộ tại tầng ứng dụng của từng Pod được tổng hợp qua PromQL `sum(...)`. Đối với kiến trúc worker tiêu thụ hàng đợi phân tán độc lập (như RabbitMQ, Kafka, Redis Streams), KEDA có thể đọc trực tiếp độ dài hàng đợi từ message broker mà không cần đi qua Prometheus.

---

## CHƯƠNG 5: QUẢN TRỊ CHI PHÍ, BẢO MẬT VÀ KHUYẾN NGHỊ CHÍNH SÁCH

### 5.1. Quản trị Chi phí và Danh mục Rủi ro Bảo mật Còn lại

*(Chi tiết định lượng xem tại tài liệu chuyên đề [docs/cost-and-security.md](file:///d:/UTH-Tai%20Lieu%20Dien%20Toan%20Dam%20May/web-service-autoscaling-optimization/docs/cost-and-security.md))*.

1. **Ước tính và Kiểm soát Chi phí:**
   * **Môi trường thực nghiệm:** Chạy 100% trên Minikube cục bộ, chi phí dịch vụ đám mây bằng **\$0**. Đã áp dụng tối ưu hóa footprint bộ giám sát (tắt Alertmanager, node-exporter, default dashboards, giới hạn `retention: 3h`) giúp toàn bộ cụm hoạt động ổn định trong giới hạn `3072 MiB` RAM.
   * **Khi triển khai trên Đám mây (GKE / EKS / AKS):** Cần đặt ngân sách (Budget Alert) ở các mốc 50%, 80%, 100% và luôn khóa trần `maxReplicaCount` kèm `ResourceQuota` cho từng namespace để tránh tấn công làm phình chi phí (*Economic Denial of Sustainability — EDoS*).
2. **Danh mục Rủi ro Bảo mật Còn lại (Residual Security Risks):**
   * **Rủi ro 1 (Prometheus Operator Admission Webhooks & TLS):** Đang tắt trong `monitoring/values-local.yaml` để đơn giản hóa chứng chỉ cục bộ; bắt buộc bật lại kèm `cert-manager` khi lên production.
   * **Rủi ro 2 (Xác thực nguồn chỉ số KEDA):** Kết nối từ KEDA tới Prometheus nội bộ hiện dùng HTTP không xác thực trong mạng cụm; trên production cần bật `NetworkPolicy` chỉ cho phép namespace `keda` truy cập cổng `9090` của Prometheus và cấu hình `TriggerAuthentication`.
   * **Rủi ro 3 (Quản lý Bí mật):** Kho mã nguồn tuân thủ tuyệt đối không lưu mật khẩu, khóa API hay token; mật khẩu Grafana được sinh tự động trong Kubernetes Secret và chỉ truy xuất qua lệnh đọc động khi cần xem Dashboard.

### 5.2. Khuyến nghị Chính sách Co giãn cho Hệ thống Thực tế

Từ kết quả nghiên cứu, nhóm đề xuất ma trận khuyến nghị lựa chọn chính sách tự động co giãn cho các hệ thống dịch vụ web thực tế như sau:

| Đặc trưng Tải & Ứng dụng Thực tế | Chính sách Khuyến nghị | Bộ Tham số Gợi ý | Giới hạn Áp dụng |
| :--- | :--- | :--- | :--- |
| **1. Dịch vụ thuần tính toán CPU** (Mã hóa, nén ảnh/video, suy luận mô hình nhẹ đồng bộ) | **Kubernetes HPA theo CPU** (`baseline-cpu`) | `averageUtilization: 65–75%`, `scaleDown.stabilizationWindowSeconds: 120–300s` | Không áp dụng cho dịch vụ có tỷ lệ thời gian chờ I/O, DB hoặc gọi API ngoài $> 30\%$. |
| **2. Dịch vụ Web API / Microservice có giới hạn kết nối / worker** (Cổng thanh toán, đặt vé, truy vấn DB/API ngoài, tải có Spike & Chu kỳ) | **KEDA Kết hợp Đa chỉ số + Hysteresis** (`custom-optimized`) | - Trigger 1 (`in_flight`): `75–80%` số worker tối đa/Pod<br>- Trigger 2 (`queue_length`): `2–3` yêu cầu/Pod<br>- Trigger 3 (`p95 wait`): theo ngưỡng SLO (ví dụ `250ms`)<br>- `pollingInterval: 5–10s`<br>- `scaleUp.stabilizationWindowSeconds: 0s`<br>- `scaleDown.stabilizationWindowSeconds`: lớn hơn $1.2 \times$ chu kỳ trũng ngắn nhất của tải (ví dụ `60–120s`) | Cần đảm bảo thời gian khởi động Pod mới (Cold start) nhỏ hơn thời gian diễn ra xung tải; nếu cold start quá dài ($> 60\text{s}$), phải kết hợp giữ `minReplicaCount >= 2` hoặc mở rộng chủ động theo lịch (Cron trigger). |
| **3. Xử lý tác vụ nền bất đồng bộ qua Message Broker** (Kafka, RabbitMQ, Redis Queue) | **KEDA Native Broker Scaler** | Đọc trực tiếp `queueLength` / `lag` từ Broker; có thể bật co giãn về `minReplicaCount: 0` ngoài giờ cao điểm | Chỉ co về `0` bản sao nếu chấp nhận được độ trễ cold start cho yêu cầu đầu tiên. |

---

## TÀI LIỆU THAM KHẢO

1. **[Bài giảng Chương 1]** Trường Đại học Giao thông Vận tải TP.HCM (UTH), *Tài liệu Bài giảng Học phần Điện toán Đám mây — Chương 1 (Tuần 1, 2, 3): Tổng quan Điện toán Đám mây, Kiến trúc Dịch vụ và Cơ chế Tự động Co giãn*, truy cập năm 2026.
2. **[9]** Kubernetes Authors, *"Kubernetes Documentation (v1.36 / v1.37),"* The Linux Foundation. Trực tuyến: https://kubernetes.io/docs/ (Phiên bản kiểm thử: Kubernetes `v1.37.0` / `kubectl v1.34.1–v1.36.1`, ngày truy cập: 09/11/2026).
3. **[10]** HashiCorp, *"Terraform Documentation,"* HashiCorp Developer. Trực tuyến: https://developer.hashicorp.com/terraform/docs (Tham khảo nguyên lý Infrastructure as Code & quản trị tài nguyên khai báo, ngày truy cập: 09/11/2026).
4. **[31]** Kubernetes Authors, *"Autoscaling Workloads — Horizontal Pod Autoscaling (autoscaling/v2),"* Kubernetes Documentation. Trực tuyến: https://kubernetes.io/docs/concepts/workloads/autoscaling/ (Phiên bản API: `autoscaling/v2`, ngày truy cập: 09/11/2026).
5. **[KEDA]** CNCF KEDA Authors, *"KEDA — Kubernetes Event-driven Autoscaling Documentation (v2.21),"* Cloud Native Computing Foundation. Trực tuyến: https://keda.sh/docs/2.16/concepts/scaling-deployments/ (Helm chart `kedacore/keda v2.21.0`, ngày truy cập: 09/11/2026).
6. **[Prometheus]** Prometheus Authors, *"kube-prometheus-stack & Prometheus Querying Basics,"* Cloud Native Computing Foundation. Trực tuyến: https://prometheus.io/docs/prometheus/latest/querying/basics/ (Helm chart `kube-prometheus-stack v92.16.1`, ngày truy cập: 09/11/2026).
7. **[k6]** Grafana Labs, *"Grafana k6 Documentation — Scenarios & Arrival-Rate Executors,"* Grafana Labs. Trực tuyến: https://grafana.com/docs/k6/latest/using-k6/scenarios/ (Phiên bản `k6 v1.1.0`, ngày truy cập: 09/11/2026).
