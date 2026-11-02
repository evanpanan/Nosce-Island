FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
COPY requirements.lock ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt && useradd -u 10001 -m nosce && mkdir /data && chown nosce /data
COPY --chown=nosce:nosce nosce ./nosce
USER nosce
EXPOSE 8000
CMD ["python", "-m", "uvicorn", "nosce.main:factory", "--factory", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--no-access-log", "--proxy-headers", "--forwarded-allow-ips", "*"]
