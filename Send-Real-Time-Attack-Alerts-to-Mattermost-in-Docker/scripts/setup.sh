#!/bin/sh
# filepath: scripts/setup.sh
# ==============================================================================
# Script Name : setup.sh
# Description : Automated OS verification, host provisioning, repository retrieval,
#               and container stack deployment for Mattermost on Alpine Linux.
# Target OS   : Alpine Linux v3.19+ (Strictly Enforced)
# Repository  : https://github.com/rabakuku/Youtube/tree/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker
# ==============================================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
    log_err "This deployment script must be run as root. Execute with sudo or switch to root."
    exit 1
fi

# 2. Strict Operating System Verification Gate
log_info "Verifying host operating system compatibility..."

if [ ! -f /etc/os-release ]; then
    log_err "Cannot verify operating system (/etc/os-release missing)."
    log_err "This script strictly requires Alpine Linux. Aborting installation."
    exit 1
fi

# Source os-release parameters
. /etc/os-release

if [ "$ID" != "alpine" ]; then
    printf "\n"
    log_err "======================================================================"
    log_err " INCOMPATIBLE OPERATING SYSTEM DETECTED"
    log_err "======================================================================"
    log_err "Detected OS : ${PRETTY_NAME:-$ID}"
    log_err "Required OS : Alpine Linux (apk + OpenRC)"
    printf "\n"
    log_warn "Why this failed:"
    printf "  - This automation stack utilizes Alpine's 'apk' package manager and\n"
    printf "    'OpenRC' init service controls (rc-update, rc-service).\n"
    printf "  - Other distributions like Ubuntu/Debian (apt + systemd) or RHEL/Rocky\n"
    printf "    (dnf + systemd) require different package names and service managers.\n"
    printf "\n"
    log_err "Installation terminated. Please run this script on an Alpine Linux host."
    exit 1
fi

log_info "Operating system confirmed: Alpine Linux (${VERSION_ID:-release}). Proceeding..."

# 3. Alpine Community Repository Enablement
if [ -f /etc/apk/repositories ]; then
    if ! grep -q "^http.*/community" /etc/apk/repositories; then
        log_info "Enabling Alpine Community repository in /etc/apk/repositories..."
        sed -i 's/^#\(.*\/community\)/\1/' /etc/apk/repositories
    fi
    log_info "Updating local package index..."
    apk update
else
    log_err "/etc/apk/repositories is missing. Unable to proceed with package resolution."
    exit 1
fi

# 4. Install Docker Engine, Runtime & Network Diagnostic Tools
log_info "Installing Docker Engine, CLI Compose plugin, Containerd, and networking utilities..."
apk add --no-cache \
    docker \
    docker-cli-compose \
    containerd \
    e2fsprogs \
    iptables \
    curl \
    net-tools \
    ca-certificates

# 5. OpenRC Service Management
log_info "Configuring Docker OpenRC service state..."
if ! rc-status boot 2>/dev/null | grep -q "docker"; then
    log_info "Adding Docker to 'boot' runlevel..."
    rc-update add docker boot 2>/dev/null || true
fi

if ! rc-service docker status 2>/dev/null | grep -q "started"; then
    log_info "Starting Docker daemon process..."
    rc-service docker start
else
    log_info "Docker daemon is running and active."
fi

# 6. Resolve Workspace Directories
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd || echo "/opt/mattermost-stack")"
COMPOSE_DIR="$BASE_DIR/compose"

mkdir -p "$COMPOSE_DIR"
cd "$COMPOSE_DIR"

COMPOSE_RAW_URL="https://raw.githubusercontent.com/rabakuku/Youtube/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/compose/docker-compose.yml"
ENV_RAW_URL="https://raw.githubusercontent.com/rabakuku/Youtube/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/compose/.env.example"

# 7. Acquire docker-compose.yml
if [ -f "docker-compose.yml" ]; then
    log_info "Local docker-compose.yml detected in $COMPOSE_DIR."
else
    log_info "Fetching docker-compose.yml from GitHub repository..."
    if curl -fsSL "$COMPOSE_RAW_URL" -o docker-compose.yml; then
        log_info "Successfully downloaded docker-compose.yml."
    else
        log_warn "Remote download failed. Generating local standalone docker-compose.yml..."
        cat <<'EOF' > docker-compose.yml
services:
  postgres:
    image: postgres:15-alpine
    container_name: mattermost-postgres
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    pids_limit: 100
    read_only: false
    tmpfs:
      - /tmp
      - /var/run/postgresql
    volumes:
      - mattermost_db_data:/var/lib/postgresql/data
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    networks:
      backend_net:
        ipv4_address: 172.28.0.10
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  mattermost:
    image: mattermost/mattermost-team-edition:latest
    container_name: mattermost-app
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    pids_limit: 200
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - mattermost_app_config:/mattermost/config
      - mattermost_app_data:/mattermost/data
      - mattermost_app_logs:/mattermost/logs
      - mattermost_app_plugins:/mattermost/plugins
      - mattermost_app_client_plugins:/mattermost/client/plugins
      - mattermost_app_bleve:/mattermost/bleve-indexes
    environment:
      MM_SQLSETTINGS_DRIVERNAME: postgres
      MM_SQLSETTINGS_DATASOURCE: postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}?sslmode=disable&connect_timeout=10
      MM_SERVICESETTINGS_SITEURL: ${MM_SITE_URL}
      MM_SERVICESETTINGS_LISTENADDRESS: :8065
      MM_FILESETTINGS_DRIVERNAME: local
      MM_FILESETTINGS_DIRECTORY: /mattermost/data/
      MM_LOGSETTINGS_CONSOLELEVEL: INFO
      MM_LOGSETTINGS_ENABLECONSOLE: "true"
    ports:
      - "80:8065"
    networks:
      backend_net:
        ipv4_address: 172.28.0.20
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:8065/api/v4/system/ping || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 30s

volumes:
  mattermost_db_data:
    name: mattermost_db_data
  mattermost_app_config:
    name: mattermost_app_config
  mattermost_app_data:
    name: mattermost_app_data
  mattermost_app_logs:
    name: mattermost_app_logs
  mattermost_app_plugins:
    name: mattermost_app_plugins
  mattermost_app_client_plugins:
    name: mattermost_app_client_plugins
  mattermost_app_bleve:
    name: mattermost_app_bleve

networks:
  backend_net:
    name: mattermost_backend_net
    driver: bridge
    ipam:
      driver: default
      config:
        - subnet: 172.28.0.0/24
          gateway: 172.28.0.1
EOF
    fi
fi

# 8. Environment Variable File (.env) Verification
if [ ! -f ".env" ]; then
    if [ -f ".env.example" ]; then
        log_info "Creating .env from existing local .env.example..."
        cp .env.example .env
    else
        log_info "Fetching .env.example template from GitHub repository..."
        if curl -fsSL "$ENV_RAW_URL" -o .env.example; then
            cp .env.example .env
        else
            log_warn "Generating fallback production .env file..."
            cat <<'EOF' > .env
POSTGRES_DB=mattermost
POSTGRES_USER=mmuser
POSTGRES_PASSWORD=SecurePassword_ChangeMe_19216810!
MM_SITE_URL=http://192.168.10.2
APP_PORT=80
EOF
        fi
    fi
else
    log_info "Active .env configuration file detected."
fi

# 9. Port 80 Listener Conflict Check
if netstat -tuln 2>/dev/null | grep -q ":80 "; then
    log_warn "Port 80 is currently bound on the host interface. Inspecting process..."
    netstat -tulnp 2>/dev/null | grep ":80 " || true
    log_err "Port 80 is occupied. Terminate the conflicting listener before proceeding."
    exit 1
fi

# 10. Container Deployment via Docker Compose
log_info "Pulling official container images..."
docker compose pull

log_info "Starting Mattermost and PostgreSQL containers in detached mode..."
docker compose up -d

# 11. Healthcheck Verification Loop
log_info "Awaiting service health convergence..."

RETRIES=15
COUNT=0
HEALTHY=false

while [ "$COUNT" -lt "$RETRIES" ]; do
    APP_STATUS=$(docker inspect --format='{{json .State.Health.Status}}' mattermost-app 2>/dev/null || echo "\"starting\"")
    DB_STATUS=$(docker inspect --format='{{json .State.Health.Status}}' mattermost-postgres 2>/dev/null || echo "\"starting\"")

    if [ "$APP_STATUS" = "\"healthy\"" ] && [ "$DB_STATUS" = "\"healthy\"" ]; then
        HEALTHY=true
        break
    fi

    log_warn "Health status: PostgreSQL ($DB_STATUS), Mattermost ($APP_STATUS). Waiting 5s (attempt $((COUNT + 1))/$RETRIES)..."
    sleep 5
    COUNT=$((COUNT + 1))
done

# 12. Final Validation Summary
if [ "$HEALTHY" = true ]; then
    printf "\n"
    log_info "======================================================================"
    log_info " Mattermost Security Automation Host Successfully Deployed!"
    log_info "======================================================================"
    printf "${GREEN}Mattermost Web GUI : ${NC}http://192.168.10.2:80\n"
    printf "${GREEN}Internal Database  : ${NC}172.28.0.10:5432 (Isolated Docker Bridge)\n"
    printf "${GREEN}Container Health   : ${NC}\n"
    docker compose ps
    printf "\n${YELLOW}Next Step:${NC} Navigate to http://192.168.10.2:80 to create your admin account\n"
    printf "and generate your Incoming Webhook URL for the FortiOS Automation Stitch.\n"
else
    log_warn "Stack is running, but containers are still initializing. Check logs with:"
    printf "  docker compose -f %s/docker-compose.yml logs -f\n" "$COMPOSE_DIR"
fi
