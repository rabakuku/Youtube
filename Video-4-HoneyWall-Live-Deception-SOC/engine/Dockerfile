# filepath: https://github.com/rabakuku/Youtube/blob/main/Video-4-HoneyWall-Live-Deception-SOC/engine/Dockerfile
# HoneyWall engine - detection, FortiGate REST enforcement, alerts, reports, live API
FROM python:3.12-alpine

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY engine.py /app/engine.py

ENV PYTHONUNBUFFERED=1
EXPOSE 8000
CMD ["python3", "/app/engine.py"]
