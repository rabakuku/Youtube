# filepath: scripts/setup.sh
#!/bin/sh
# -----------------------------------------------------------------------------
# Fortinet Visual SOC Lab - Automated Deployment Script (Alpine Linux)
# -----------------------------------------------------------------------------
# Safely installs Docker, provisions directories, downloads configurations 
# directly from GitHub, and launches the Visual SOC SIEM stack.

set -e

echo "[*] Initiating Fortinet Visual SOC Lab Deployment..."

echo "[*] Installing Docker, OpenRC, and required dependencies..."
apk update
apk add docker docker-cli-compose openrc curl

echo "[*] Initializing Docker Service..."
# Add current user (if not root) to docker group, ensure service starts on boot
addgroup root docker || true
rc-update add docker boot || true
rc-service docker start || true

# Brief pause to ensure the Docker daemon socket is fully initialized
sleep 3

echo "[*] Creating persistent volume and configuration directories..."
BASE_DIR="$(pwd)/compose"
mkdir -p "${BASE_DIR}/vector"
mkdir -p "${BASE_DIR}/loki"
mkdir -p "${BASE_DIR}/grafana/provisioning/datasources"

echo "[*] Downloading configuration files from GitHub..."
cd "${BASE_DIR}"

RAW_URL_BASE="https://raw.githubusercontent.com/rabakuku/Youtube/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/compose"

# Download core Compose and Environment files
curl -sL "${RAW_URL_BASE}/docker-compose.yml" -o docker-compose.yml
curl -sL "${RAW_URL_BASE}/.env.example" -o .env

# Download App Configurations
curl -sL "${RAW_URL_BASE}/local-config.yaml" -o loki/local-config.yaml
curl -sL "${RAW_URL_BASE}/vector.yaml" -o vector/vector.yaml
curl -sL "${RAW_URL_BASE}/loki.yaml" -o grafana/provisioning/datasources/loki.yaml

echo "[*] Setting safe permissions on configuration directories..."
chmod -R 755 "${BASE_DIR}"

echo "[*] Launching SIEM Stack via Docker Compose..."
docker compose up -d

echo "[+] Deployment complete! Allow 15-30 seconds for Grafana and Loki to initialize."
echo "[+] Grafana UI: http://192.168.10.2:80"
echo "[+] Vector Syslog Ingest: UDP 514"
