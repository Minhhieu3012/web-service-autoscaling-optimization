from fastapi import FastAPI

# KHỞI TẠO ỨNG DỤNG & CẤU HÌNH CON ĐO (METRICS)
app = FastAPI(
    title="Autoscaling Web Service",
    description="Dịch vụ web stateless phục vụ thực nghiệm tự động co giãn (HPA & KEDA)",
    version="1.0.0",
)

# CÁC ĐƯỜNG DẪN API (ENDPOINTS) PHỤC VỤ THỰC NGHIỆM
@app.get("/health", tags=["System"])
async def health_check():
    """Kiểm tra ứng dụng còn sống hay không (phục vụ Kubernetes Liveness/Readiness Probe)."""
    return {"status": "healthy"}