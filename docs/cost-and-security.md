
# ĐÁNH GIÁ CHI PHÍ TÀI NGUYÊN VÀ BẢO MẬT HỆ THỐNG

## 1. Tổng quan

Đề tài nghiên cứu tối ưu tự động co giãn dịch vụ web trên Kubernetes theo tải CPU và các chỉ số nghiệp vụ.

Hạ tầng thử nghiệm sử dụng Minikube trên máy cá nhân, kết hợp:

- Docker Desktop và Kubernetes.
- Kubernetes Metrics Server.
- Prometheus và Grafana.
- Prometheus Operator.
- KEDA Operator và External Metrics API.

Mục đích của tài liệu:

1. Xác định chi phí và giới hạn tài nguyên của môi trường thử nghiệm.
2. Phân tích các yếu tố ảnh hưởng đến khả năng mở rộng.
3. Đánh giá những rủi ro bảo mật khi triển khai.
4. Đề xuất biện pháp tối ưu và kiểm soát.
5. Xác định các điều kiện cần đáp ứng trước khi chuyển sang production.

## 2. Phạm vi đánh giá

Có hai phạm vi cần phân biệt.

### 2.1. Môi trường local

Sử dụng máy tính cá nhân và Minikube để chạy thử nghiệm.

Ưu điểm:

- Không cần thuê Kubernetes cluster trên cloud.
- Chủ động kiểm soát môi trường.
- Có thể cài đặt và dọn thử nghiệm nhiều lần.
- Phù hợp để xây dựng và kiểm thử các cấu hình autoscaling.

Hạn chế:

- Phụ thuộc phần cứng máy cá nhân.
- Một node không có tính sẵn sàng cao.
- CPU, RAM và I/O của các thành phần dùng chung tài nguyên.
- Khả năng mở rộng số Pod bị giới hạn bởi node.
- Kết quả hiệu năng không đại diện hoàn toàn cho production.

### 2.2. Môi trường production

Khi chuyển sang môi trường cloud hoặc Kubernetes nhiều node, cần bổ sung:

- High availability.
- Persistent storage.
- Network security.
- Quản lý secrets và phân quyền.
- Monitoring, alerting và logging đầy đủ.
- Backup và disaster recovery.
- Quản lý chi phí thực tế.
- Kiểm thử hiệu năng và bảo mật trước khi đưa vào vận hành.

Cấu hình local hiện tại không được mặc định xem là cấu hình production-ready.

## 3. Cấu hình tài nguyên tham chiếu

| Hạng mục | Cấu hình |
|---|---|
| Máy host | Windows |
| Docker backend | Hyper-V |
| Docker CPU limit | 4 CPU |
| Docker memory limit | 4096 MiB |
| Minikube | Single-node |
| Minikube CPU | 2 CPU |
| Minikube memory | 3072 MiB |
| Prometheus retention | 3 giờ |
| Grafana persistence | Tắt |
| Alertmanager | Tắt |
| Default Prometheus rules | Tắt |

Các thông số được chọn để phù hợp với môi trường thử nghiệm có giới hạn tài nguyên.

Việc giảm tài nguyên không đồng nghĩa hệ thống giữ được cùng hiệu năng với cấu hình production.

## 4. Phân bổ tài nguyên Monitoring Stack

### 4.1. Grafana

| Loại | CPU | Memory |
|---|---|---|
| Request | 50m | 96Mi |
| Limit | 500m | 384Mi |

Grafana được bổ sung startupProbe để tránh khởi động lại quá sớm khi quá trình khởi tạo kéo dài.

### 4.2. Prometheus Operator

| Loại | CPU | Memory |
|---|---|---|
| Request | 50m | 64Mi |
| Limit | 250m | 256Mi |

### 4.3. Prometheus

| Loại | CPU | Memory |
|---|---|---|
| Request | 100m | 256Mi |
| Limit | 500m | 512Mi |

Các giá trị trên mô tả thành phần chính đã được cấu hình trong file Helm values.

Chúng chưa bao gồm toàn bộ Kubernetes system components, sidecars, KEDA, workload ứng dụng và overhead của node.

Cần sử dụng kubectl top để kiểm tra mức sử dụng thực tế.

## 5. Tối ưu footprint của Monitoring Stack

### 5.1. Giảm số lượng thành phần

Môi trường local đã tắt:

- Alertmanager.
- Default Prometheus rules.
- Default Grafana dashboards.
- kube-state-metrics.
- node-exporter.
- Một số thành phần thu thập metrics hệ thống.

Lợi ích là giảm số Pod, số tiến trình và overhead theo dõi.

Đánh đổi là hệ thống không có đầy đủ các dashboard, alert và chỉ số hạ tầng mặc định.

Các thành phần này cần được đánh giá lại khi chuyển sang môi trường production.

### 5.2. Giới hạn retention

Prometheus sử dụng retention 3 giờ để giảm nhu cầu lưu trữ lịch sử dài hạn.

Giới hạn:

- Không phù hợp để phân tích xu hướng dài ngày.
- Dữ liệu thử nghiệm cũ có thể bị loại bỏ.
- Không thay thế hệ thống lưu trữ kết quả nghiên cứu.

Với các đợt load test, dữ liệu kết quả cần được xuất và lưu riêng trước khi hết thời gian retention.

### 5.3. Không sử dụng persistence cho Grafana

Việc tắt persistence giúp đơn giản hóa môi trường local.

Đổi lại, các thay đổi được lưu trực tiếp trong Grafana có thể mất khi Pod bị tạo lại.

Dashboard và cấu hình quan trọng nên được quản lý bằng file và version control, thay vì chỉ lưu trong container.

## 6. Phân tích chi phí

### 6.1. Chi phí sử dụng Kubernetes local

Môi trường Minikube không phát sinh khoản phí thuê Kubernetes cluster từ nhà cung cấp cloud chỉ vì chạy local.

Tuy nhiên vẫn có chi phí:

- Điện năng tiêu thụ.
- Hao mòn và sử dụng phần cứng.
- Dung lượng lưu trữ.
- Internet để tải dependencies và container images.
- Thời gian cài đặt, vận hành và khắc phục sự cố.

Vì vậy không nên kết luận tổng chi phí vận hành bằng 0.

### 6.2. Ước tính chi phí điện năng

Công thức:

```text
Energy_kWh = Power_kW × Runtime_hours

ElectricityCost = Energy_kWh × ElectricityPrice_per_kWh
```

Nếu chỉ đánh giá điện năng tăng thêm do thí nghiệm:

```text
IncrementalEnergy_kWh =
    (PowerDuringExperiment_W - BaselinePower_W)
    × Runtime_hours
    / 1000
```

Không sử dụng số liệu công suất giả định làm kết quả đo thực tế.

Cần đo công suất hoặc sử dụng dữ liệu tiêu thụ có thể kiểm chứng.

### 6.3. Ước tính chi phí trên cloud

Khi chuyển sang cloud, các nhóm chi phí chính gồm:

| Nhóm | Yếu tố ảnh hưởng |
|---|---|
| Compute | Số node, loại máy, thời gian chạy |
| Storage | Dung lượng, loại ổ, thời gian lưu |
| Network | Data transfer và load balancer |
| Monitoring | Lưu trữ metrics/logs và dịch vụ quan sát |
| Control plane | Chính sách tính phí của nhà cung cấp |
| Backup | Dung lượng và tần suất sao lưu |
| Operations | Nhân lực và quản trị hệ thống |

Công thức tổng quát:

```text
TotalCost =
    ComputeCost
    + StorageCost
    + NetworkCost
    + MonitoringCost
    + ControlPlaneCost
    + BackupCost
    + OtherOperationalCost
```

Đơn giá phải lấy theo khu vực, cấu hình và nhà cung cấp tại thời điểm đánh giá.

Tài liệu này chưa đưa ra tổng chi phí cloud cụ thể vì nhóm chưa chốt cấu hình triển khai và bảng giá tương ứng.

## 7. Quan hệ giữa autoscaling và chi phí

Autoscaling có thể cải thiện hiệu quả sử dụng tài nguyên bằng cách:

- Tăng số replica khi tải vượt ngưỡng.
- Giảm replica khi nhu cầu giảm.
- Hạn chế cấp phát tài nguyên dư thừa trong thời gian tải thấp.
- Duy trì khả năng phục vụ trong các giai đoạn tải cao.

Tuy nhiên autoscaling không tự động đồng nghĩa với giảm chi phí.

Ví dụ, một cấu hình scale quá nhạy có thể tạo thêm Pod thường xuyên hoặc duy trì nhiều replica hơn cần thiết.

Khi có kết quả thực nghiệm, cần đánh giá đồng thời:

- Số replica trung bình.
- Số replica tối đa.
- Thời gian duy trì từng mức replica.
- CPU và memory usage.
- Request throughput.
- Latency p95.
- Error rate.
- Thời gian phản ứng với biến động tải.

## 8. Phương pháp so sánh chi phí tài nguyên

Dự kiến so sánh ba cấu hình:

| Cấu hình | Mục tiêu |
|---|---|
| CPU HPA | Baseline autoscaling theo CPU |
| KEDA chưa tối ưu | Autoscaling theo custom metrics với cấu hình ban đầu |
| KEDA tối ưu | Cấu hình custom metrics đã điều chỉnh ngưỡng và hành vi scale |

Các cấu hình cần được kiểm thử trên điều kiện tương đương:

- Cùng ứng dụng và container image.
- Cùng tài nguyên node.
- Cùng giới hạn tài nguyên Pod.
- Cùng kịch bản tải.
- Cùng thời lượng và phương pháp đo.
- Có giai đoạn warm-up và reset phù hợp.

Chỉ số chi phí tài nguyên có thể tính:

```text
ReplicaSeconds =
    Sum(ReplicaCount × DurationSeconds)
```

Hoặc đối với dữ liệu được lấy mẫu theo thời gian:

```text
ReplicaSeconds ≈
    Sum(ReplicaCount_i × SampleIntervalSeconds)
```

Chỉ số này biểu diễn mức sử dụng replica theo thời gian. Nó không trực tiếp bằng chi phí cloud nếu mỗi replica có resource request khác nhau hoặc dùng chung node với các workload khác.

Kết quả định lượng sẽ được bổ sung sau giai đoạn load testing.

## 9. Đánh giá bảo mật

### 9.1. Secret management

Grafana lưu thông tin đăng nhập quản trị trong Kubernetes Secret.

Rủi ro:

- Lộ mật khẩu khi sao chép output terminal.
- Commit nhầm Secret hoặc credentials lên GitHub.
- Phân quyền đọc Secret quá rộng.
- Sử dụng lại mật khẩu trong môi trường khác.

Biện pháp:

- Không hardcode credentials vào repository.
- Không lưu mật khẩu trong ảnh báo cáo.
- Chỉ cấp quyền đọc Secret cho đối tượng cần thiết.
- Sử dụng cơ chế quản lý Secret chuyên dụng trong production.
- Bật mã hóa Secret at rest khi môi trường hỗ trợ.

Kubernetes Secret được mã hóa Base64 khi biểu diễn trong YAML; Base64 không phải mã hóa bảo mật.

### 9.2. Network exposure

Các thành phần monitoring local sử dụng Kubernetes ClusterIP Service.

Khi cần truy cập từ máy host, sử dụng kubectl port-forward đến localhost.

Rủi ro:

- Vô tình công khai giao diện quản trị.
- Mở cổng không có xác thực phù hợp.
- Truy cập trái phép vào metrics nội bộ.

Biện pháp:

- Không tạo public LoadBalancer/Ingress khi chưa cần.
- Giới hạn port-forward ở localhost.
- Bảo vệ tài khoản Grafana.
- Áp dụng NetworkPolicy và TLS phù hợp trên production.

### 9.3. Prometheus Operator admission webhooks

Cấu hình local hiện tại:

```yaml
prometheusOperator:
  admissionWebhooks:
    enabled: false
  tls:
    enabled: false
```

Cấu hình này đã được sử dụng để khắc phục lỗi thiếu TLS Secret khi triển khai thử nghiệm.

Hạn chế:

- Không sử dụng cơ chế admission webhook của Prometheus Operator để kiểm tra các PrometheusRule theo cách cấu hình mặc định.
- Không đáp ứng đầy đủ yêu cầu bảo mật và kiểm soát cấu hình của production.

Định hướng:

- Bật lại admission webhooks khi môi trường hỗ trợ đầy đủ.
- Cấu hình TLS/certificates đúng cách.
- Kiểm thử quá trình cài đặt, nâng cấp và xác minh các rule.
- Không sao chép nguyên cấu hình local sang production mà không đánh giá lại.

### 9.4. KEDA Operator

Môi trường đã triển khai:

- KEDA Operator.
- Metrics API Server.
- Admission Webhooks.
- Các Kubernetes Custom Resource Definitions của KEDA.

External Metrics API đã được kiểm tra ở trạng thái Available.

Các biện pháp cần bổ sung khi tích hợp scaler:

- Phân quyền phù hợp cho service accounts.
- Hạn chế quyền truy cập metrics và secrets.
- Kiểm tra độ tin cậy của dữ liệu dùng để autoscaling.
- Giới hạn maxReplicaCount.
- Cấu hình authentication cho nguồn metrics khi cần.
- Kiểm thử tình huống scaler không truy cập được metric.

Không đặt cả HPA độc lập và KEDA ScaledObject cùng điều khiển số replica của một Deployment trong cùng phép thử nếu chưa thiết kế rõ cơ chế phối hợp.

### 9.5. Supply chain security

Rủi ro:

- Container images chứa lỗ hổng.
- Sử dụng phiên bản chart không kiểm soát.
- Tải dependencies từ nguồn không đáng tin cậy.
- Commit file cấu hình có thông tin nhạy cảm.

Biện pháp:

- Cố định phiên bản Helm charts.
- Ưu tiên image từ nguồn tin cậy.
- Quét dependencies và container images.
- Kiểm soát thay đổi thông qua Git và pull request.
- Xem xét image digest và chính sách xác minh artifact đối với production.

## 10. Rủi ro kỹ thuật và biện pháp kiểm soát

| Rủi ro | Tác động | Biện pháp |
|---|---|---|
| Node thiếu RAM | Pod Pending/OOMKilled | Resource requests/limits, theo dõi node |
| Grafana khởi động chậm | Probe thất bại | StartupProbe |
| Sai cấu hình TLS Operator | Pod không mount được Secret | Kiểm tra Helm values và manifest |
| Prometheus hết retention | Mất dữ liệu lịch sử | Xuất kết quả sau thí nghiệm |
| Grafana không persistence | Mất dashboard chỉnh tay | Quản lý dashboard bằng file |
| KEDA mất kết nối metrics | Autoscaling không như dự kiến | Giám sát scaler, kiểm thử lỗi |
| Scale quá nhạy | Tốn tài nguyên, dao động replica | Điều chỉnh threshold và cooldown |
| Metrics không đại diện tải thật | Quyết định scale sai | Kiểm thử metrics và PromQL |
| Một node bị lỗi | Dừng toàn bộ hệ thống | Chuyển multi-node trên production |
| Lộ thông tin nhạy cảm | Rủi ro bảo mật | Secrets, RBAC và kiểm soát Git |

## 11. Giới hạn của mô hình đo hiện tại

Môi trường là single-node Minikube, do đó:

1. Không thể đánh giá high availability giữa nhiều node.
2. Kết quả autoscaling bị ảnh hưởng bởi tài nguyên máy host.
3. Thử nghiệm chưa phản ánh đầy đủ network latency và chi phí cloud.
4. Monitoring Stack cùng chia sẻ tài nguyên với ứng dụng.
5. Retention ngắn không thích hợp để lưu kết quả dài hạn.
6. Chưa có bằng chứng đo chi phí cloud trực tiếp.

Đối với custom metrics, cần đặc biệt kiểm tra cách tổng hợp chỉ số từ nhiều Pod.

Nếu ứng dụng sử dụng bộ đếm hoặc hàng đợi mô phỏng trong bộ nhớ từng process, không được mặc định xem đó là hàng đợi phân tán hoặc dữ liệu tổng hợp toàn cluster.

## 12. Khuyến nghị trước khi triển khai production

- Sử dụng Kubernetes version nằm trong phạm vi tương thích đã kiểm thử của KEDA.
- Tách môi trường production khỏi local development.
- Bật lại các cơ chế bảo mật đã giản lược.
- Bổ sung TLS, RBAC, NetworkPolicy và secret management.
- Thiết lập persistent storage và backup.
- Bật alerting và monitoring phù hợp.
- Thiết lập resource quotas và limits.
- Sử dụng nhiều node nếu có yêu cầu high availability.
- Kiểm thử load, stress, soak và recovery.
- Đo chi phí thực tế và xây dựng ngưỡng ngân sách.
- Kiểm tra rollback và disaster recovery.

## 13. Kết luận

Môi trường Kubernetes local đã triển khai thành công Monitoring Stack và KEDA, đáp ứng yêu cầu hạ tầng ban đầu để nghiên cứu autoscaling.

Việc tinh giản Monitoring Stack, giới hạn tài nguyên và sử dụng Minikube giúp phù hợp với điều kiện phần cứng hiện có.

Tuy nhiên, thành công ở mức hạ tầng không đồng nghĩa với việc giải pháp autoscaling đã được chứng minh hiệu quả.

Để kết luận cấu hình tối ưu hơn, nhóm phải hoàn thành thí nghiệm, đo latency, error rate, replica usage và chi phí tài nguyên trên các kịch bản tải tương đương.

Bảo mật production cũng cần được đánh giá độc lập, không sử dụng nguyên trạng cấu hình local đã giản lược.
