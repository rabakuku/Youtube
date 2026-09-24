#!/bin/sh
# filepath: https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/scripts/setup.sh
set -e

REPO_BASE="https://raw.githubusercontent.com/rabakuku/Youtube/main/Active-Honeypot-Instant-Auto-Quarantine"
COMPOSE_DIR="/opt/honeypot-quarantine/compose"

echo "[+] Starting Active Deception Honeypot Deployment on Alpine Linux..."

# Verify Operating System is Alpine Linux
if [ ! -f /etc/os-release ]; then
    echo "[-] Error: /etc/os-release not found. Target operating system is not Alpine Linux."
    exit 1
fi

. /etc/os-release
if [ "$ID" != "alpine" ]; then
    echo "[-] Incompatible operating system: $ID. This script is strictly configured for Alpine Linux."
    exit 1
fi
echo "[+] Host OS confirmed: Alpine Linux ($VERSION_ID)"

# Update repository indexes and install required packages with explicit delimiter separation
echo "[+] Updating APK repositories and ensuring dependencies are installed..."
apk update
apk add --no-cache \
    curl \
    docker \
    docker-cli-compose \
    iproute2 \
    grep \
    ca-certificates

# Ensure docker system group and root assignment exist
echo "[+] Configuring Docker user permissions..."
addgroup -S docker 2>/dev/null || true
addgroup root docker 2>/dev/null || true

# Register and start Docker daemon under OpenRC
if ! rc-service docker status >/dev/null 2>&1; then
    echo "[+] Registering Docker service with OpenRC default runlevel..."
    rc-update add docker default
    echo "[+] Starting Docker service..."
    rc-service docker start
else
    echo "[+] Docker daemon is already running."
fi

# Prepare target workspace directory
echo "[+] Creating compose directory at $COMPOSE_DIR..."
mkdir -p "$COMPOSE_DIR"
cd "$COMPOSE_DIR"

# Download configuration artifacts directly from repository
echo "[+] Fetching docker-compose.yml..."
curl -fsSL "${REPO_BASE}/compose/docker-compose.yml" -o docker-compose.yml

echo "[+] Fetching .env.example..."
curl -fsSL "${REPO_BASE}/compose/.env.example" -o .env.example

echo "[+] Fetching cowrie.cfg..."
curl -fsSL "${REPO_BASE}/compose/cowrie.cfg" -o cowrie.cfg

# Initialize environment file
if [ ! -f .env ]; then
    echo "[+] Creating .env from .env.example..."
    cp .env.example .env
fi

# Spin up Cowrie container stack
echo "[+] Pulling images and deploying Cowrie honeypot stack..."
docker compose pull
docker compose up -d

echo "[+] Stack deployed successfully."
