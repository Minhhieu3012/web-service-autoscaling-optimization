# CHỌN NỀN TẢNG (BASE IMAGE) TỐI ƯU CHO COLD START
# Sử dụng Python 3.11 bản -slim để giảm kích thước image xuống mức tối thiểu (~150MB)
FROM python:3.11-slim

# Ngăn Python tạo các file rác .pyc và ép in log trực tiếp ra màn hình terminal
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Thiết lập thư mục làm việc mặc định bên trong container
WORKDIR /app

# TỐI ƯU BỘ NHỚ ĐỆM (DOCKER LAYER CACHING)
# Sao chép riêng tệp requirements.txt trước để tận dụng cache khi build lại code
COPY requirements.txt .

# Cài đặt thư viện Python 
RUN pip install --no-cache-dir -r requirements.txt

# SAO CHÉP MÃ NGUỒN ỨNG DỤNG
COPY main.py .

# BẢO MẬT - NGUYÊN TẮC QUYỀN TỐI THIỂU (LEAST PRIVILEGE)
# Tạo một tài khoản người dùng thường (non-root) để tránh chạy ứng dụng với quyền root
RUN useradd -m -u 1000 appuser && \
    chown -R appuser:appuser /app

# Chuyển quyền thực thi sang tài khoản vừa tạo
USER appuser

# Khai báo cổng ứng dụng lắng nghe
EXPOSE 8000

# LỆNH KHỞI CHẠY ỨNG DỤNG
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]