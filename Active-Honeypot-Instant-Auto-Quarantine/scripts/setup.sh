
#!/bin/sh
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

# Check and install required packages
REQUIRED_PKGS="curl docker docker-cli-compose iproute2 grep"
MISSING_PKGS=""

for pkg in $REQUIRED_PKGS; do
    if ! apk info -e "$pkg" >/dev/null 2>&1; then
        MISSING_PKGS="$MISSING_PKGS$pkg"
    fi
done

if [ -n "$MISSING_PKGS" ]; then
    echo "[+] Installing missing packages via apk:$MISSING_PKGS"
    apk update
    apk add --no-cache $MISSING_PKGS
else
    echo "[+] All required packages are already installed."
fi

# Enable and start Docker daemon if not running
if ! rc-service docker status >/dev/null 2>&1; then
    echo "[+] Starting Docker service..."
    rc-update add docker default
    rc-service docker start
else
    echo "[+] Docker daemon is running."
fi

# Prepare target directory structure
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

# Initialize environment variables
if [ ! -f .env ]; then
    echo "[+] Creating .env from .env.example..."
    cp .env.example .env
fi

# Spin up Cowrie container stack
echo "[+] Deploying Cowrie honeypot stack..."
docker compose pull
docker compose up -d

echo "[+] Stack deployed successfully."
