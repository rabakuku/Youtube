# filepath: https://github.com/rabakuku/Youtube/blob/main/Video-4-HoneyWall-Live-Deception-SOC/decoy-web/Dockerfile
# HoneyWall web decoy - fake "Corp Backup Console" login page that reports every request to the engine
FROM python:3.12-alpine

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY decoy_web.py /app/decoy_web.py

ENV PYTHONUNBUFFERED=1
EXPOSE 8088
CMD ["python3", "/app/decoy_web.py"]
