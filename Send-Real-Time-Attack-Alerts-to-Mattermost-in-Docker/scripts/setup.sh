#!/bin/sh
# filepath: scripts/setup.sh
# ==============================================================================
# Script Name : setup.sh
# Description : Automated host provisioning, environment validation, file retrieval,
#               and container stack deployment for Mattermost on Alpine Linux.
# Repository  : https://github.com/rabakuku/Youtube/tree/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker
# ==============================================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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
    log_err "This deployment script must be run as root. Run with sudo or switch to root."
    exit 1
fi

log_info "Starting Automated Deployment Pipeline for Mattermost Alert Automation..."

# 2. Alpine Repository & Package Dependency Check
if [ -f /etc/apk/repositories ]; then
    if ! grep -q "^http.*/community" /etc/apk/repositories; then
        log_info "Enabling Alpine Community repository in /etc/apk/repositories..."
        sed -i 's/^#\(.*\/community\)/\1/' /etc/apk/repositories
    fi
    log_info "Updating local package index..."
    apk update
    log_info "Installing Docker, Containerd, Compose plugin, and networking utilities..."
    apk add --no-cache \
        docker \
        docker-cli-compose \
        containerd \
        e2fsprogs \
        iptables \
        curl \
        net-tools \
        ca-certificates
else
    log_warn "/etc/apk/repositories not found. Assuming non-Alpine host or packages pre-installed."
fi

# 3. OpenRC Service Check & Initialization
if command -v rc-status >/dev/null 2>&1; then
    log_info "Configuring Docker OpenRC service state..."
    if ! rc-status boot 2>/dev/null | grep -q "docker"; then
        rc-update add docker boot 2>/dev/null || true
    fi

    if ! rc-service docker status 2>/dev/null | grep -q "started"; then
        log_info "Starting Docker daemon..."
        rc-service docker start
    else
        log_info "Docker daemon is already active."
    fi
elif command -v systemctl >/dev/null 2>&1; then
    systemctl enable docker
    systemctl start docker
fi

# 4. Resolve Base Directory & Prepare Compose Environment
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd || echo "/opt/mattermost-stack")"
COMPOSE_DIR="$BASE_DIR/compose"

mkdir -p "$COMPOSE_DIR"
cd "$COMPOSE_DIR"

COMPOSE_RAW_URL="https://raw.githubusercontent.com/rabakuku/Youtube/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/compose/docker-compose.yml"
ENV_RAW_URL="https://raw.githubusercontent.com/rabakuku/Youtube/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/compose/.env.example"

# 5. Acquire docker-compose.yml
if [ -f "docker-compose.yml" ]; then
    log_info "Existing docker-compose.yml detected locally in $COMPOSE_DIR."
else
    log_info "Fetching docker-compose.yml from GitHub repository..."
    if curl -fsSL "$COMPOSE_RAW_URL" -o docker-compose.yml; then
        log_info "Successfully downloaded docker-compose.yml."
    else
        log_err "Failed to download docker-compose.yml from $COMPOSE_RAW_URL. Creating standard fallback configuration..."
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

# 6. Environment Configuration Verification (.env)
if [ ! -f ".env" ]; then
    if [ -f ".env.example" ]; then
        log_info "Creating .env from existing local .env.example..."
        cp .env.example .env
    else
        log_info "Fetching .env.example template from GitHub repository..."
        if curl -fsSL "$ENV_RAW_URL" -o .env.example; then
            cp .env.example .env
        else
            log_warn "Generating default production .env configuration..."
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
    log_info "Existing .env configuration confirmed."
fi

# 7. Check Port 80 Availability
if netstat -tuln 2>/dev/null | grep -q ":80 "; then
    log_warn "Port 80 is currently occupied. Inspecting process..."
    netstat -tulnp 2>/dev/null | grep ":80 " || true
    log_err "Please free TCP port 80 before starting the Mattermost stack."
    exit 1
fi

# 8. Pull Container Images and Launch Stack
log_info "Pulling official container images (mattermost-team-edition & postgres:15-alpine)..."
docker compose pull

log_info "Starting containers in detached mode..."
docker compose up -d

# 9. Healthcheck Validation Loop
log_info "Waiting for PostgreSQL and Mattermost healthchecks to report healthy..."

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

# 10. Operational Summary
if [ "$HEALTHY" = true ]; then
    printf "\n"
    log_info "======================================================================"
    log_info " Deployment Successful! Stack is operational."
    log_info "======================================================================"
    printf "${GREEN}Mattermost Web URL : ${NC}http://192.168.10.2:80\n"
    printf "${GREEN}Database Endpoint  : ${NC}172.28.0.10:5432 (Internal Docker Network)\n"
    printf "${GREEN}Container Status   : ${NC}\n"
    docker compose ps
    printf "\n${YELLOW}Next Step:${NC} Navigate to http://192.168.10.2:80 to initialize the admin\n"
    printf "account and create your incoming webhook for the FortiOS Automation Stitch.\n"
else
    log_warn "Stack initialization is taking longer than expected. Check logs with:"
    printf "  docker compose -f %s/docker-compose.yml logs -f\n" "$COMPOSE_DIR"
fi
