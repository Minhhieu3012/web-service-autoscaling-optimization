# Đề tài 3: Tối ưu tự động co giãn cho dịch vụ web theo tải và theo chỉ số nghiệp vụ

Dự án nghiên cứu và thực nghiệm thuộc nhóm **Nền tảng và Kiến trúc Điện toán Đám mây**. Kho mã nguồn này lưu trữ toàn bộ mã nguồn dịch vụ, tệp cấu hình hạ tầng (Kubernetes/HPA/KEDA), kịch bản kiểm thử tải, dữ liệu đo thô và công cụ tái lập biểu đồ phân tích.

---

## 1. Tổng quan đề tài

### Câu hỏi nghiên cứu

> Chính sách co giãn theo CPU có đủ hiệu quả đối với tải biến động nhanh, hay cần kết hợp độ trễ, hàng đợi và số yêu cầu đang chờ?

### Mục tiêu nghiên cứu

- Thiết kế và so sánh ít nhất hai chính sách co giãn (theo CPU truyền thống và theo chỉ số tùy chỉnh/nghiệp vụ) cho cùng một dịch vụ web stateless.
- Đánh giá mối quan hệ đánh đổi giữa tốc độ phản ứng, chất lượng dịch vụ (QoS - p95 latency, error rate) và chi phí tài nguyên.
- Xác định ngưỡng (threshold) và khoảng ổn định (cooldown/stabilization window) nhằm giảm thiểu hiện tượng dao động (flapping/thrashing) tăng - giảm bản sao.

---

## 2. Phân công thành viên nhóm

| Thành viên            | Vai trò chính                     | Nhiệm vụ                                                                                                                                                                                           |
| :-------------------- | :-------------------------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Phan Minh Hieu**    | Phát triển Web Service & Giám sát | Xây dựng dịch vụ FastAPI (stateless) với 2 endpoint tạo tải CPU và hàng đợi; xuất custom metrics; cấu hình Prometheus ServiceMonitor & Grafana Dashboard.                                          |
| **Nguyen Ha Gia Huy** | Hạ tầng K8s & Chính sách Co giãn  | Khởi tạo cụm Minikube; viết deployment/service; cấu hình chính sách HPA (CPU) và KEDA ScaledObject; tinh chỉnh cooldown/threshold giảm dao động; viết tài liệu dọn tài nguyên, bảo mật và chi phí. |
| **Lai Duc Thanh**     | Kiểm thử tải & Phân tích dữ liệu  | Viết 3 kịch bản k6 (bậc thang, spike, chu kỳ) và kịch bản lỗi; chạy thực nghiệm thu thập dữ liệu thô CSV/JSON; viết Notebook phân tích và vẽ biểu đồ chuẩn học thuật.                              |

---

## 3. Danh sách phiên bản công nghệ & Môi trường thực nghiệm

Hệ thống được thiết kế để chạy hoàn toàn trên máy cá nhân (gói miễn phí, chi phí \$0) với danh sách các công cụ và phiên bản đã được chuẩn hóa như sau:

| Công cụ                           | Phiên bản (Version)                | Vai trò trong dự án                                        |
| :-------------------------------- | :--------------------------------- | :--------------------------------------------------------- |
| **Git**                           | `2.47.1.windows.1`                 | Quản lý phiên bản mã nguồn và lịch sử đóng góp             |
| **WSL**                           | `WSL 2 (Ubuntu)`                   | Môi trường nhân Linux nền tảng cho Container               |
| **Docker Engine**                 | `29.9.2 (build a82e528)`           | Đóng gói ứng dụng và làm driver cho cụm Kubernetes         |
| **Minikube**                      | `v1.39.0`                          | Khởi tạo cụm Kubernetes cục bộ                             |
| **kubectl**                       | `v1.36.1 (Kustomize v5.8.1)`       | Giao tiếp và quản trị cụm Kubernetes                       |
| **Helm**                          | `v4.3.1+gc0d08d0`                  | Quản lý gói cài đặt (Prometheus, Grafana, KEDA)            |
| **Grafana k6**                    | `v1.1.0 (go1.24.4, windows/amd64)` | Giả lập 3 kịch bản tải: Bậc thang, Spike, Chu kỳ           |
| **Python & FastAPI**              | `Python 3.x`                       | Xây dựng dịch vụ stateless (CPU endpoint & Queue endpoint) |
| **Jupyter / Pandas / Matplotlib** | `Latest (venv)`                    | Xử lý dữ liệu đo thô (CSV/JSON) và tái tạo biểu đồ báo cáo |

---

## 4. Cấu trúc kho mã nguồn

```text
web-service-autoscaling-optimization/
├── app/                            # Mã nguồn dịch vụ Web Stateless (FastAPI) & Dockerfile
├── k8s/                            # Tệp cấu hình triển khai Kubernetes & chính sách co giãn
│   ├── base/                       # Cấu hình nền tảng (Deployment, Service)
│   └── autoscaling/                # Chính sách co giãn (HPA theo CPU, KEDA Custom Metrics)
├── monitoring/                     # Cấu hình Prometheus, ServiceMonitor & Grafana Dashboard
├── load-tests/                     # Kịch bản kiểm thử tải k6 (step, spike, periodic)
├── scripts/                        # Kịch bản tự động hóa khởi tạo cụm, thu thập số liệu và dọn dẹp tài nguyên
├── data/                           # Bộ dữ liệu đo thô (CSV/JSON) từ các kịch bản thực nghiệm
│   ├── baseline-cpu/               # Dữ liệu đo chính sách HPA theo CPU
│   ├── custom-unoptimized/         # Dữ liệu đo KEDA trước tối ưu (chưa tinh chỉnh ngưỡng/cooldown)
│   └── custom-optimized/           # Dữ liệu đo KEDA sau tối ưu (giảm dao động flapping)
├── notebooks/                      # Phân tích dữ liệu và trực quan hóa kết quả
│   └── figures/                    # Nơi lưu trữ biểu đồ xuất ra để chèn vào báo cáo
├── docs/                           # Tài liệu thiết kế, hướng dẫn tái lập và báo cáo kỹ thuật
│   ├── architecture/               # Sơ đồ kiến trúc hiện trạng/mục tiêu và luồng dữ liệu
│   └── final-report/               # Bản báo cáo kỹ thuật hoàn chỉnh (20-35 trang A4)
├── .gitignore                      # Quy tắc loại trừ tệp rác, môi trường ảo và bảo mật
└── README.md
```

## 5. Hướng dẫn triển khai & Tái lập thực nghiệm

(Chi tiết từng bước lệnh khởi tạo cụm, triển khai dịch vụ, chạy k6 và thu thập số liệu sẽ được cập nhật đầy đủ trong quá trình thực nghiệm).

- Khởi tạo cụm & Công cụ giám sát: Khởi chạy Minikube, bật metrics-server, cài đặt Prometheus, Grafana và KEDA qua Helm.
- Triển khai ứng dụng: Build image dịch vụ web và áp dụng các tệp cấu hình trong thư mục k8s/.
- Chạy kịch bản tải: Thực thi các kịch bản trong load-tests/ bằng k6 ứng với từng chính sách co giãn.
- Phân tích kết quả: Chạy Jupyter Notebook trong notebooks/ để sinh bảng so sánh và biểu đồ từ dữ liệu trong data/.

## 6. Dọn dẹp tài nguyên & Quản trị chi phí / Bảo mật

Dọn dẹp tài nguyên sau thực nghiệm:

```bash
minikube stop
minikube delete
```

- Chi phí ước tính: Thực nghiệm vận hành 100% trên cụm cục bộ (Minikube/Docker), không phát sinh chi phí dịch vụ đám mây.
- An toàn bảo mật: Kho mã nguồn tuân thủ nguyên tắc không lưu trữ mật khẩu, khóa API, token hay dữ liệu cá nhân.
