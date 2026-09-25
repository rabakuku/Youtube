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

# Update package repository index and install all dependencies directly
echo "[+] Updating APK repositories and installing dependencies..."
apk update
apk add --no-cache curl docker docker-cli-compose iproute2 grep ca-certificates

# Ensure docker group exists and current user has socket permissions
echo "[+] Configuring Docker user permissions..."
addgroup -S docker 2>/dev/null || true
addgroup root docker 2>/dev/null || true

# Register and start Docker daemon via OpenRC
if ! rc-service docker status >/dev/null 2>&1; then
    echo "[+] Registering Docker service with OpenRC default runlevel..."
    rc-update add docker default
    echo "[+] Starting Docker daemon..."
    rc-service docker start
else
    echo "[+] Docker daemon is already running."
fi

# Prepare target directory
echo "[+] Creating compose workspace at $COMPOSE_DIR..."
mkdir -p "$COMPOSE_DIR"
cd "$COMPOSE_DIR"

# Download configuration artifacts directly from repository
echo "[+] Fetching docker-compose.yml..."
curl -fsSL "${REPO_BASE}/compose/docker-compose.yml" -o docker-compose.yml

echo "[+] Fetching .env.example..."
curl -fsSL "${REPO_BASE}/compose/.env.example" -o .env.example

echo "[+] Fetching cowrie.cfg..."
curl -fsSL "${REPO_BASE}/compose/cowrie.cfg" -o cowrie.cfg

# Initialize environment configuration file
if [ ! -f .env ]; then
    echo "[+] Initializing .env from .env.example..."
    cp .env.example .env
fi

# Prompt user for FortiGate API Token and inject into active configuration files
printf "\n======================================================================\n"
printf "Enter your FortiGate API Token (from 'execute api-user generate-key'):\n"
printf "Token: "
read -r FGT_TOKEN

if [ -n "$FGT_TOKEN" ]; then
    echo "[+] Injecting API Token into configuration files..."
    
    # 1. Update compose/.env
    sed -i '/FORTIGATE_API_KEY/d' .env 2>/dev/null || true
    echo "FORTIGATE_API_KEY=\"$FGT_TOKEN\"" >> .env
    
    # 2. Update app/app.json (if it exists locally)
    if [ -f "../app/app.json" ]; then
        sed -i "s/PASTE_API_KEY_FROM_EXECUTE_API_USER_GENERATE_KEY/$FGT_TOKEN/g" ../app/app.json 2>/dev/null || true
    fi
    
    # 3. Update scripts/webhook-watcher.sh (if it exists locally)
    if [ -f "../scripts/webhook-watcher.sh" ]; then
        sed -i "s/PASTE_YOUR_COPIED_KEY_HERE/$FGT_TOKEN/g" ../scripts/webhook-watcher.sh 2>/dev/null || true
    fi

    # 4. Update scripts/triage_engine.py (if it exists locally)
    if [ -f "../scripts/triage_engine.py" ]; then
        sed -i "s/PASTE_YOUR_COPIED_KEY_HERE/$FGT_TOKEN/g" ../scripts/triage_engine.py 2>/dev/null || true
    fi
    
    echo "[+] Token successfully injected."
else
    echo "[-] No token provided. You will need to manually add it to .env and application scripts later."
fi
printf "======================================================================\n\n"

# Spin up Cowrie honeypot container stack
echo "[+] Pulling Cowrie image and starting containers..."
docker compose pull
docker compose up -d

echo "[+] Stack deployed successfully."
