import asyncio
from fastapi import FastAPI, Request
from prometheus_client import Counter, Gauge, Histogram
from prometheus_fastapi_instrumentator import Instrumentator

# KHỞI TẠO ỨNG DỤNG & CẤU HÌNH CON ĐO (METRICS)
app = FastAPI(
    title="Autoscaling Web Service",
    description="Dịch vụ web stateless phục vụ thực nghiệm tự động co giãn (HPA & KEDA)",
    version="1.0.0",
)

# Con đo 1: Đếm số yêu cầu đang được xử lý cùng lúc
IN_FLIGHT_REQUESTS = Gauge(
    "app_in_flight_requests",
    "Số lượng yêu cầu đang được xử lý đồng thời tại thời điểm hiện tại",
)

# Con đo 2: Đếm số yêu cầu đang phải xếp hàng chờ
QUEUE_LENGTH = Gauge(
    "app_queue_length",
    "Số lượng công việc đang nằm chờ trong hàng đợi trước khi được xử lý",
)

# Con đo 3: Đếm tổng số công việc đã hoàn thành hoặc bị lỗi
PROCESSED_JOBS_TOTAL = Counter(
    "app_processed_jobs_total",
    "Tổng số yêu cầu đã đi qua hệ thống",
    ["endpoint", "status"],
)

# Con đo 4: Đo phân phối thời gian chờ trong hàng đợi
QUEUE_WAIT_DURATION = Histogram(
    "app_queue_wait_duration_seconds",
    "Thời gian một yêu cầu phải nằm chờ trong hàng đợi (tính bằng giây)",
    buckets=[0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0],
)

# Tự động gắn bộ thu thập chuẩn (độ trễ p95, throughput, error rate) và mở đường dẫn /metrics
Instrumentator().instrument(app).expose(app, endpoint="/metrics")

# Giới hạn tối đa 5 công việc trong hàng đợi được xử lý cùng lúc trên 1 bản sao (Pod)
# Các yêu cầu thứ 6 trở đi sẽ phải xếp hàng chờ
MAX_CONCURRENT_WORKERS = 5
worker_semaphore = asyncio.Semaphore(MAX_CONCURRENT_WORKERS)


# BỘ ĐẾM TỰ ĐỘNG CHO MỌI YÊU CẦU ĐI VÀO/ĐI RA
@app.middleware("http")
async def track_in_flight_requests(request: Request, call_next):
    # Bỏ qua không đếm các yêu cầu kiểm tra sức khỏe hoặc cào số liệu của hệ thống
    if request.url.path in ["/metrics", "/health"]:
        return await call_next(request)

    IN_FLIGHT_REQUESTS.inc()
    try:
        response = await call_next(request)
        return response
    finally:
        IN_FLIGHT_REQUESTS.dec()

# CÁC ĐƯỜNG DẪN API (ENDPOINTS) PHỤC VỤ THỰC NGHIỆM
@app.get("/health", tags=["System"])
async def health_check():
    """Kiểm tra ứng dụng còn sống hay không (phục vụ Kubernetes Liveness/Readiness Probe)."""
    return {"status": "healthy"}