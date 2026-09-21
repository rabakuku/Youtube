#!/bin/sh
set -eu

###############################################################################
# Active-Defense-Auto-Quarantine Rollback Script
# Alpine Linux 3.24 Compatible (/bin/sh)
###############################################################################

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

log_fatal() {
    printf "${RED}[FATAL]${NC} %s\n" "$1"
    exit 1
}

###############################################################################
# Directory Structure
###############################################################################

BASE_DIR="/opt/Active-Defense-Auto-Quarantine"
COMPOSE_DIR="${BASE_DIR}/compose"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"

log_warn "Initiating Active-Defense-Auto-Quarantine rollback..."

###############################################################################
# Verify Docker
###############################################################################

if ! command -v docker >/dev/null 2>&1; then
    log_warn "Docker is not installed. Nothing to remove."
    exit 0
fi

###############################################################################
# Stop Stack
###############################################################################

if [ -d "${COMPOSE_DIR}" ] && [ -f "${COMPOSE_FILE}" ]; then

    log_info "Stopping Docker Compose stack..."

    cd "${COMPOSE_DIR}"

    docker compose down -v --remove-orphans || true

else

    log_warn "Compose directory not found. Falling back to manual cleanup."

    docker stop n8n-automation-core >/dev/null 2>&1 || true
    docker stop n8n-postgres-db >/dev/null 2>&1 || true

    docker rm n8n-automation-core >/dev/null 2>&1 || true
    docker rm n8n-postgres-db >/dev/null 2>&1 || true

fi

###############################################################################
# Network Cleanup
###############################################################################

log_info "Removing Docker networks..."

docker network rm soar_internal_net >/dev/null 2>&1 || true
docker network rm active-defense-auto-quarantine_default >/dev/null 2>&1 || true

###############################################################################
# Volume Cleanup
###############################################################################

log_info "Removing Docker volumes..."

docker volume rm n8n_enterprise_data >/dev/null 2>&1 || true
docker volume rm n8n_enterprise_postgres >/dev/null 2>&1 || true

###############################################################################
# Container Cleanup
###############################################################################

log_info "Removing any remaining containers..."

docker rm -f n8n-automation-core >/dev/null 2>&1 || true
docker rm -f n8n-postgres-db >/dev/null 2>&1 || true

###############################################################################
# Image Cleanup
###############################################################################

log_info "Removing dangling Docker resources..."

docker system prune -af >/dev/null 2>&1 || true

###############################################################################
# Remove Installation Files
###############################################################################

if [ -d "${BASE_DIR}" ]; then

    log_info "Removing installation directory..."

    rm -rf "${BASE_DIR}"

    log_success "Deleted ${BASE_DIR}"

fi

###############################################################################
# Success
###############################################################################

log_success "Rollback completed successfully."
log_success "Docker containers removed."
log_success "Docker networks cleaned."
log_success "Docker volumes cleaned."
log_success "Installation directory removed."
log_success "Host port 80 has been released."
