#!/bin/sh
set -eu

# ==============================================================================
# Teardown & Rollback Script: Active-Defense-Auto-Quarantine
# Target Node: Alpine Linux 3.24 Host (192.168.10.2)
# Purpose: Halt containers, purge state volumes, remove bridge networks
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$1"
}

log_success() {
    printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BASE_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="${BASE_DIR}/compose"

log_warn "Initiating teardown of Active-Defense-Auto-Quarantine services..."

###############################################################################
# Verify Docker
###############################################################################

if ! command -v docker >/dev/null 2>&1; then
    log_warn "Docker is not installed. Nothing to remove."
    exit 0
fi

###############################################################################
# Compose Teardown
###############################################################################

if [ -d "${COMPOSE_DIR}" ] && [ -f "${COMPOSE_DIR}/docker-compose.yml" ]; then

    cd "${COMPOSE_DIR}"

    log_info "Stopping containers and removing volumes..."

    docker compose down -v --remove-orphans || true

else

    log_warn "Compose files not found. Falling back to direct container cleanup."

    docker stop n8n-automation-core n8n-postgres-db >/dev/null 2>&1 || true

    docker rm n8n-automation-core n8n-postgres-db >/dev/null 2>&1 || true

fi

###############################################################################
# Network Cleanup
###############################################################################

log_info "Cleaning orphaned Docker networks..."

docker network rm soar_internal_net >/dev/null 2>&1 || true

###############################################################################
# Volume Cleanup
###############################################################################

log_info "Cleaning lab volumes..."

docker volume rm n8n_enterprise_data >/dev/null 2>&1 || true
docker volume rm n8n_enterprise_postgres >/dev/null 2>&1 || true

###############################################################################
# Optional Garbage Collection
###############################################################################

log_info "Removing dangling Docker resources..."

docker system prune -f >/dev/null 2>&1 || true

###############################################################################
# Success
###############################################################################

log_success "Environment teardown complete."
log_success "Host port 80 has been released."
