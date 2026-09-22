FROM python:3.12-slim-bookworm

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --requirement requirements.txt

COPY generator.py .

ENTRYPOINT ["python", "/app/generator.py"]
