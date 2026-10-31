import asyncio
import math
import os
import time
from fastapi import FastAPI, HTTPException, Query, Request
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

# Tự động gắn bộ thu thập chuẩn (độ trễ p95, throughput, error rate)
Instrumentator().instrument(app).expose(app, endpoint="/metrics")

# Đọc số lượng worker đồng thời từ biến môi trường
# Giúp dễ dàng thay đổi tham số thực nghiệm từ file deployment.yaml của Kubernetes
MAX_CONCURRENT_WORKERS = int(os.getenv("MAX_CONCURRENT_WORKERS", "5"))
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

@app.get("/api/cpu", tags=["Workloads"])
def simulate_cpu_load(
    iterations: int = Query(
        default=500_000,
        ge=1_000,
        le=20_000_000,
        description="Số vòng lặp tính toán để ép xung CPU",
    )
):
    """
    Endpoint 1: Tạo tải nặng về CPU.
    Dùng để kiểm thử chính sách co giãn theo CPU (Kubernetes HPA).
    """
    start_time = time.perf_counter()

    # Thực hiện phép tính căn bậc hai và lượng giác liên tục để tiêu tốn CPU thật
    accumulator = 0.0
    for i in range(1, iterations + 1):
        accumulator += math.sqrt(i) * math.sin(i)

    duration = time.perf_counter() - start_time
    PROCESSED_JOBS_TOTAL.labels(endpoint="cpu", status="success").inc()

    return {
        "endpoint": "cpu",
        "iterations": iterations,
        "processing_time_seconds": round(duration, 4),
    }

@app.get("/api/queue", tags=["Workloads"])
async def simulate_queue_load(
    work_time: float = Query(
        default=0.5,
        ge=0.05,
        le=10.0,
        description="Thời gian xử lý 1 công việc (giây)",
    ),
    max_queue_limit: int = Query(
        default=100,
        ge=1,
        le=1000,
        description="Giới hạn hàng đợi tối đa trước khi báo lỗi quá tải (503)",
    ),
):
    """
    Endpoint 2: Mô phỏng công việc xử lý theo hàng đợi (Queue).
    Chiếm rất ít CPU nhưng gây nghẽn hàng đợi và tăng độ trễ khi có nhiều request.
    Dùng để chứng minh HPA (theo CPU) thất bại và KEDA (theo Queue/In-flight) hiệu quả.
    """
    # Nếu hàng đợi đã đầy vượt mức cho phép, lập tức trả về lỗi 503 (Service Unavailable)
    # Phục vụ đo tỷ lệ lỗi (Error Rate) và quay demo tình huống lỗi
    current_waiting = QUEUE_LENGTH._value.get()
    if current_waiting >= max_queue_limit:
        PROCESSED_JOBS_TOTAL.labels(endpoint="queue", status="rejected_overload").inc()
        raise HTTPException(
            status_code=503,
            detail=f"Hàng đợi đã quá tải ({int(current_waiting)}/{max_queue_limit}). Vui lòng thử lại sau.",
        )

    # Yêu cầu bắt đầu xếp hàng chờ đến lượt
    QUEUE_LENGTH.inc()
    is_waiting_in_queue = True 
    enqueue_time = time.perf_counter()

    try:
        async with worker_semaphore:
            # Khi đã vào được đây nghĩa là đã tới lượt xử lý -> Rời khỏi hàng đợi chờ
            QUEUE_LENGTH.dec()
            is_waiting_in_queue = False

            wait_time = time.perf_counter() - enqueue_time
            QUEUE_WAIT_DURATION.observe(wait_time)

            # Mô phỏng thời gian xử lý công việc
            await asyncio.sleep(work_time)

            total_time = time.perf_counter() - enqueue_time
            PROCESSED_JOBS_TOTAL.labels(endpoint="queue", status="success").inc()

            return {
                "endpoint": "queue",
                "queue_wait_seconds": round(wait_time, 4),
                "work_time_seconds": work_time,
                "total_response_seconds": round(total_time, 4),
            }
    except asyncio.CancelledError:
        # Ghi nhận trường hợp client chủ động ngắt kết nối (timeout) khi đang chờ
        PROCESSED_JOBS_TOTAL.labels(endpoint="queue", status="client_cancelled").inc()
        raise
    finally:
        # Nếu yêu cầu bị ngắt khi vẫn đang đứng trong hàng đợi, giảm bộ đếm đi 1
        if is_waiting_in_queue:
            QUEUE_LENGTH.dec()