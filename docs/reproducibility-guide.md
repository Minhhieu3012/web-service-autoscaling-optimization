
# HƯỚNG DẪN TÁI LẬP MÔI TRƯỜNG THỬ NGHIỆM

## 1. Mục đích

Tài liệu mô tả quy trình tái lập môi trường Kubernetes cục bộ phục vụ đề tài tối ưu tự động co giãn dịch vụ web theo tải và các chỉ số nghiệp vụ.

Mục tiêu:

- Khởi tạo Kubernetes cluster bằng Minikube.
- Bật Metrics Server để theo dõi tài nguyên CPU/RAM.
- Triển khai Prometheus, Grafana và Prometheus Operator.
- Triển khai KEDA Operator và External Metrics API.
- Kiểm tra trạng thái hoạt động của hạ tầng.
- Hỗ trợ dọn môi trường thử nghiệm có kiểm soát.

Phạm vi hiện tại là hạ tầng thử nghiệm. Việc triển khai ứng dụng web, cấu hình HPA, KEDA ScaledObject và kiểm thử autoscaling thực tế thuộc các giai đoạn tích hợp tiếp theo.

## 2. Kiến trúc môi trường

```text
Windows Host
    |
    +-- Docker Desktop (Hyper-V backend)
            |
            +-- Minikube Cluster
                    |
                    +-- Kubernetes Metrics Server
                    |
                    +-- Namespace: monitoring
                    |       |
                    |       +-- Prometheus
                    |       +-- Prometheus Operator
                    |       +-- Grafana
                    |
                    +-- Namespace: keda
                            |
                            +-- KEDA Operator
                            +-- KEDA Metrics API Server
                            +-- KEDA Admission Webhooks
```

Trong các giai đoạn sau, ứng dụng FastAPI sẽ được triển khai thành Kubernetes Deployment và Service. Prometheus sẽ thu thập các chỉ số ứng dụng khi cấu hình ServiceMonitor phù hợp. HPA và KEDA sẽ được kiểm thử theo từng kịch bản riêng.

## 3. Phiên bản và cấu hình tham chiếu

| Thành phần | Phiên bản/cấu hình tham chiếu |
|---|---|
| Hệ điều hành | Windows 10 Pro |
| Docker Desktop | 4.97.0 |
| Docker backend | Hyper-V |
| Giới hạn Docker | 4 GiB RAM, 4 CPU |
| Minikube | v1.39.0 |
| Kubernetes cluster đã kiểm thử | v1.37.0 |
| Minikube profile | minikube |
| Minikube driver | docker |
| Minikube CPU | 2 CPU |
| Minikube RAM | 3072 MiB |
| kubectl | v1.34.1 |
| Helm | v4.3.1 |
| kube-prometheus-stack chart | 92.16.1 |
| KEDA chart | 2.21.0 |

Đây là cấu hình tham chiếu đã sử dụng trong quá trình triển khai, không phải yêu cầu cố định cho mọi máy.

Lưu ý tương thích: KEDA 2.21 được kiểm thử chính thức với Kubernetes 1.34–1.36. Cluster Kubernetes 1.37 trong môi trường này đã chạy được các thành phần hạ tầng KEDA nhưng chưa được kiểm thử đầy đủ mọi chức năng autoscaling.

## 4. Chuẩn bị công cụ

Yêu cầu cài đặt:

- Git
- Docker Desktop
- Minikube
- kubectl
- Helm
- Windows PowerShell
- Visual Studio Code hoặc trình soạn thảo tương đương

Kiểm tra phiên bản:

```powershell
git --version
docker version
minikube version
kubectl version --client
helm version
```

Kiểm tra Docker Engine:

```powershell
docker info
```

Docker Engine phải hoạt động trước khi tạo Minikube cluster.

Trong môi trường tham chiếu, Docker sử dụng Hyper-V backend. Không bắt buộc chuyển sang WSL2 khi hệ điều hành không hỗ trợ cấu hình WSL2 phù hợp.

## 5. Chuẩn bị source code

Clone repository của nhóm từ GitHub và chuyển sang nhánh phát triển Kubernetes autoscaling:

```powershell
git switch feat/k8s-autoscaling
git status -sb
```

Các file quan trọng:

```text
scripts/
    setup-cluster.ps1
    cleanup.ps1

monitoring/
    values-local.yaml
    keda-values-local.yaml

docs/
    reproducibility-guide.md
    cost-and-security.md
```

Chạy các lệnh tiếp theo từ thư mục gốc của repository.

## 6. Khởi tạo Minikube cluster

Chạy script thiết lập:

```powershell
.\scripts\setup-cluster.ps1
```

Script chịu trách nhiệm kiểm tra các công cụ cần thiết, khởi tạo hoặc sử dụng profile Minikube hiện có, kiểm tra node và kích hoạt Metrics Server.

Lưu ý: Nếu profile Minikube đã tồn tại, script có thể sử dụng lại cấu hình profile đó. Cần kiểm tra cấu hình thực tế thay vì mặc định rằng mọi lần chạy đều tạo cluster mới với cùng tài nguyên.

Kiểm tra cluster:

```powershell
kubectl --context minikube get nodes -o wide
kubectl --context minikube get pods -n kube-system
kubectl --context minikube top nodes
```

Kết quả mong muốn:

- Node `minikube` ở trạng thái `Ready`.
- Metrics Server hoạt động.
- `kubectl top nodes` trả về số liệu CPU và RAM.

## 7. Chuẩn bị Helm repositories

Thêm hai chart repositories:

```powershell
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
```

Kiểm tra các chart cần dùng:

```powershell
helm show chart prometheus-community/kube-prometheus-stack --version 92.16.1
helm show chart kedacore/keda --version 2.21.0
```

Dự án cố định phiên bản chart để giảm khác biệt giữa các lần triển khai.

## 8. Triển khai Monitoring Stack

### 8.1. Kiểm tra Helm template

```powershell
helm template monitoring prometheus-community/kube-prometheus-stack --version 92.16.1 --namespace monitoring -f monitoring/values-local.yaml | Out-Null
```

Kiểm tra mã thoát của lệnh:

```powershell
$LASTEXITCODE
```

Giá trị `0` thể hiện quá trình render thành công.

### 8.2. Cài Prometheus và Grafana

```powershell
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack --version 92.16.1 --kube-context minikube --namespace monitoring --create-namespace -f monitoring/values-local.yaml --wait=hookOnly --timeout 3m
```

`--wait=hookOnly` không bảo đảm tất cả Pod đã Ready. Phải kiểm tra trạng thái Kubernetes sau khi Helm thực thi.

### 8.3. Kiểm tra Monitoring Stack

```powershell
kubectl --context minikube get pods -n monitoring
helm status monitoring -n monitoring
kubectl --context minikube top nodes
```

Các thành phần cần đạt trạng thái:

| Thành phần | Điều kiện |
|---|---|
| Grafana | 2/2 Running |
| Prometheus Operator | 1/1 Running |
| Prometheus | 2/2 Running |

Sau lần triển khai ổn định, không được có hiện tượng container restart liên tục.

## 9. Truy cập Grafana và Prometheus

### 9.1. Grafana

Mở một terminal riêng:

```powershell
kubectl --context minikube -n monitoring port-forward svc/monitoring-grafana 3000:80
```

Truy cập:

http://localhost:3000

Tài khoản quản trị mặc định do chart tạo có tên `admin`. Mật khẩu được lưu trong Kubernetes Secret.

Lấy mật khẩu bằng PowerShell:

```powershell
$encoded = kubectl --context minikube -n monitoring get secret monitoring-grafana -o 'jsonpath={.data.admin-password}'
[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded))
```

Không ghi mật khẩu này vào source code, tài liệu hoặc Git commit.

### 9.2. Prometheus

Mở terminal riêng:

```powershell
kubectl --context minikube -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090
```

Truy cập:

http://localhost:9090

Có thể kiểm tra trạng thái Prometheus và các scrape targets hiện có.

Lưu ý: Việc ứng dụng FastAPI xuất hiện trong targets còn phụ thuộc vào Deployment, Service và cấu hình ServiceMonitor ở giai đoạn tích hợp.

## 10. Triển khai KEDA

### 10.1. Kiểm tra cấu hình KEDA

```powershell
helm template keda kedacore/keda --version 2.21.0 --namespace keda -f monitoring/keda-values-local.yaml | Out-Null
```

### 10.2. Cài KEDA Operator

```powershell
helm upgrade --install keda kedacore/keda --version 2.21.0 --kube-context minikube --namespace keda --create-namespace -f monitoring/keda-values-local.yaml --wait=hookOnly --timeout 3m
```

### 10.3. Kiểm tra Pod

```powershell
kubectl --context minikube get pods -n keda
```

Các thành phần cần hoạt động:

- KEDA Operator
- KEDA Metrics API Server
- KEDA Admission Webhooks

### 10.4. Kiểm tra CRDs và External Metrics API

```powershell
kubectl --context minikube get crd
kubectl --context minikube get apiservice v1beta1.external.metrics.k8s.io
```

Điều kiện nghiệm thu:

```text
AVAILABLE = True
```

Điều này xác nhận External Metrics API của KEDA sẵn sàng ở mức hạ tầng; chưa chứng minh một ScaledObject cụ thể đã hoạt động đúng.

## 11. Kiểm tra tổng thể

Chạy các lệnh:

```powershell
kubectl --context minikube get nodes
kubectl --context minikube get pods -n monitoring
kubectl --context minikube get pods -n keda
kubectl --context minikube top nodes
helm list -A --kube-context minikube
```

Điều kiện hoàn thành:

1. Minikube node ở trạng thái Ready.
2. Prometheus, Grafana và Operator đều Ready.
3. Ba thành phần KEDA đều Ready.
4. External Metrics API có AVAILABLE=True.
5. Không có Pod liên tục CrashLoopBackOff hoặc OOMKilled.
6. Helm releases được ghi nhận tại đúng namespace.

## 12. Xử lý sự cố thường gặp

### 12.1. Helm timeout

Hiện tượng:

```text
context deadline exceeded
```

Nguyên nhân có thể do Pod chưa Ready, đang tải image, thiếu tài nguyên hoặc lỗi cấu hình.

Kiểm tra:

```powershell
kubectl --context minikube get pods -A
kubectl --context minikube get events -A --sort-by=.metadata.creationTimestamp
```

Không tự động xóa cluster hoặc cài lại Docker.

### 12.2. Prometheus Operator thiếu TLS Secret

Hiện tượng từng gặp:

```text
secret "monitoring-kube-prometheus-admission" not found
```

Cấu hình local đã giải quyết bằng cách tắt đồng thời:

```yaml
prometheusOperator:
  admissionWebhooks:
    enabled: false
  tls:
    enabled: false
```

Đây là lựa chọn dành cho môi trường thử nghiệm, không mặc định áp dụng cho production.

### 12.3. Grafana khởi động chậm

Hiện tượng:

```text
Liveness probe failed
connect: connection refused
```

Cấu hình local sử dụng startupProbe để dành thời gian cho Grafana hoàn tất khởi tạo trước khi Kubernetes áp dụng liveness probe.

Kiểm tra log và trạng thái Pod:

```powershell
kubectl --context minikube get pods -n monitoring
kubectl --context minikube describe deployment monitoring-grafana -n monitoring
```

Không kết luận lỗi thiếu RAM nếu chưa có bằng chứng OOMKilled hoặc sự kiện tài nguyên liên quan.

### 12.4. Pod ở trạng thái Pending

Kiểm tra:

```powershell
kubectl --context minikube describe pods -n monitoring
kubectl --context minikube top nodes
```

Đặc biệt chú ý thông báo Insufficient memory, Insufficient cpu, lỗi volume và lỗi tải image.

## 13. Dọn môi trường có kiểm soát

Xem trước thao tác:

```powershell
.\scripts\cleanup.ps1
```

Script mặc định chạy ở chế độ Dry Run, không gỡ tài nguyên.

Chỉ sử dụng chế độ thực thi khi có chủ đích dọn môi trường:

```powershell
.\scripts\cleanup.ps1 -Execute
```

Script yêu cầu xác nhận trước khi gỡ Helm releases.

Không chạy chế độ thực thi khi đang cần giữ môi trường để thực hiện thí nghiệm hoặc thu thập bằng chứng.

Script không chủ động xóa Minikube cluster, Docker, source code hoặc namespace.

## 14. Giới hạn hiện tại

Hạ tầng đã được kiểm chứng ở mức Pod, APIService và Helm release.

Các phần chưa được kết luận từ kết quả này:

- Web application Deployment và Service.
- ServiceMonitor thu thập metrics ứng dụng.
- HPA tự co giãn theo CPU dưới tải.
- KEDA ScaledObject theo custom metrics.
- So sánh cấu hình KEDA chưa tối ưu và đã tối ưu.
- Phân tích kết quả load test của nhóm.

Các nội dung trên được bổ sung sau khi tích hợp đầy đủ phần ứng dụng và kiểm thử.

## 15. Thông tin tái lập và nghiệm thu

Mỗi lần thử nghiệm nên ghi lại:

- Thời gian thực hiện.
- Commit hash của source code.
- Phiên bản Docker, Kubernetes và Helm.
- Phiên bản Helm charts.
- CPU/RAM được cấp cho Minikube.
- Trạng thái Pod trước và sau triển khai.
- Các lỗi phát sinh và biện pháp xử lý.
- Ảnh chụp kết quả kiểm tra.
- Mức tiêu thụ CPU/RAM tại thời điểm đo.

Các bằng chứng này giúp nhóm so sánh kết quả và tái hiện môi trường khi báo cáo hoặc vấn đáp.
