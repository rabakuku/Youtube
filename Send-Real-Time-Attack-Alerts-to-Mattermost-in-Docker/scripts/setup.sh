```bash
#!/bin/sh
# filepath: scripts/setup.sh
# ==============================================================================
# Script Name : setup.sh
# Description : Automated host provisioning, environment validation, and
#               container stack deployment for Mattermost on Alpine Linux.
# ==============================================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    printf "${GREEN}[INFO] %s${NC}\n" "$1"
}

log_warn() {
    printf "${YELLOW}[WARN] %s${NC}\n" "$1"
}

log_err() {
    printf "${RED}[ERROR] %s${NC}\n" "$1"
}

# 1. Privilege Verification
if [ "$(id -u)" -ne 0 ]; then
    log_err "This deployment script must be run as root. Exiting."
    exit 1
fi

log_info "Starting Automated Deployment Pipeline..."

# 2. Alpine Repository & Package Dependency Check
if ! grep -q "^http.*/community" /etc/apk/repositories; then
    log_info "Enabling Alpine Community repository in /etc/apk/repositories..."
    sed -i 's/^#\(.*\/community\)/\1/' /etc/apk/repositories
fi

log_info "Updating local package indices..."
apk update

log_info "Installing runtime prerequisites..."
apk add --no-cache \
    docker \
    docker-cli-compose \
    containerd \
    e2fsprogs \
    iptables \
    curl \
    net-tools

# 3. OpenRC Service Check & Initialization
log_info "Configuring Docker OpenRC service state..."
if ! rc-status boot | grep -q "docker"; then
    rc-update add docker boot
fi

if ! rc-service docker status | grep -q "started"; then
    log_info "Starting Docker daemon..."
    rc-service docker start
else
    log_info "Docker daemon is already running."
fi

# 4. Resolve Base Directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="$BASE_DIR/compose"

cd "$COMPOSE_DIR"

# 5. Environment File Verification
if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        log_warn ".env file not detected. Generating from .env.example..."
        cp .env.example .env
    else
        log_err ".env.example template missing. Aborting stack launch."
        exit 1
    fi
fi

# 6. Verify Port 80 Listener Availability
if netstat -tuln | grep -q ":80 "; then
    log_err "Port 80 is already bound on this host. Stop conflicting services before continuing."
    exit 1
fi

# 7. Execute Container Stack Deployment
log_info "Launching PostgreSQL and Mattermost containers via Compose..."
docker compose pull
docker compose up -d

# 8. Post-Flight Health Verification
log_info "Waiting for service health convergence (30 seconds)..."
sleep 10

RETRIES=10
COUNT=0
SUCCESS=false

while [ "$COUNT" -lt "$RETRIES" ]; do
    if docker compose ps | grep -q "healthy"; then
        SUCCESS=true
        break
    fi
    log_warn "Healthcheck pending... retry $((COUNT+1)) of $RETRIES"
    sleep 5
    COUNT=$((COUNT+1))
done

if [ "$SUCCESS" = true ]; then
    log_info "Deployment successfully completed!"
    log_info "Mattermost endpoint accessible at: http://192.168.10.2:80"
else
    log_warn "Stack launched, but health state is still converging. Run 'docker compose ps' to verify."
fi
