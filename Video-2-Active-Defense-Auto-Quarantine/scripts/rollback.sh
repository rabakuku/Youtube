# filepath: scripts/rollback.sh
#!/bin/bash
set -euo pipefail

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

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="${BASE_DIR}/compose"

log_warn "Initiating teardown of Active-Defense-Auto-Quarantine services..."

if [[ -d "${COMPOSE_DIR}" && -f "${COMPOSE_DIR}/docker-compose.yml" ]]; then
    cd "${COMPOSE_DIR}"
    log_info "Stopping containers and destroying persistent volumes (-v)..."
    docker compose down -v --remove-orphans
else
    log_warn "Compose files not found at ${COMPOSE_DIR}. Fallback: stopping containers directly."
    docker stop n8n-automation-core n8n-postgres-db >/dev/null 2>&1 || true
    docker rm n8n-automation-core n8n-postgres-db >/dev/null 2>&1 || true
fi

log_info "Cleaning up orphaned Docker networks..."
docker network rm soar_internal_net >/dev/null 2>&1 || true

log_info "Pruning dangling lab volumes..."
docker volume rm n8n_enterprise_data n8n_enterprise_postgres >/dev/null 2>&1 || true

log_success "Environment teardown complete. Host port 80 released."
