
# filepath: scripts/setup.sh
#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Fortinet Visual SOC Lab - Automated Deployment Script
# -----------------------------------------------------------------------------
# Ensures directory structures are correct to prevent Docker root-ownership bugs,
# verifies environment variables, and deploys the SIEM stack on Alpine Linux.

set -e

echo "[*] Initiating Fortinet Visual SOC Lab Deployment..."

# Define base paths
BASE_DIR="$(pwd)/compose"
VECTOR_DIR="${BASE_DIR}/vector"
LOKI_DIR="${BASE_DIR}/loki"
GRAFANA_PROV_DIR="${BASE_DIR}/grafana/provisioning/datasources"

echo "[*] Creating persistent volume and configuration directories..."
mkdir -p "${VECTOR_DIR}"
mkdir -p "${LOKI_DIR}"
mkdir -p "${GRAFANA_PROV_DIR}"

echo "[*] Checking environment variables..."
if [ ! -f "${BASE_DIR}/.env" ]; then
    if [ -f "${BASE_DIR}/.env.example" ]; then
        echo "[+] .env file not found. Copying from .env.example..."
        cp "${BASE_DIR}/.env.example" "${BASE_DIR}/.env"
    else
        echo "[!] Warning: .env.example not found. Stack may fail if variables are missing."
    fi
else
    echo "[+] .env file exists."
fi

echo "[*] Setting safe permissions on configuration directories..."
# Ensure the current user has access, avoiding strict root lockouts on bind mounts
chmod -R 755 "${BASE_DIR}"

echo "[*] Launching SIEM Stack via Docker Compose..."
cd "${BASE_DIR}"
docker compose up -d

echo "[+] Deployment complete! Allow 15-30 seconds for Grafana and Loki to initialize."
echo "[+] Grafana UI: http://192.168.10.2:80"
echo "[+] Vector Syslog Ingest: UDP 514"
