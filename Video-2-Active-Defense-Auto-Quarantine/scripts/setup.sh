# filepath: scripts/setup.sh
#!/bin/bash
set -euo pipefail

# ==============================================================================
# Pipeline Setup & Deployment Script: Active-Defense-Auto-Quarantine
# Target Node: Alpine Linux 3.24 Host (192.168.10.2)
# Purpose: Initialize directories, enforce secrets, and launch the SOAR runtime
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

log_fatal() {
    printf "${RED}[FATAL]${NC} %s\n" "$1"
    exit 1
}

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="${BASE_DIR}/compose"
ENV_FILE="${COMPOSE_DIR}/.env"
ENV_EXAMPLE="${COMPOSE_DIR}/.env.example"

log_info "Verifying deployment environment and user permissions..."

if [[ $EUID -eq 0 ]]; then
    log_warn "Running directly as root. Non-root user with docker group access is recommended."
fi

command -v docker >/dev/null 2>&1 || log_fatal "Docker Engine is not installed. Run docs/install-docker.md first."

if ! docker info >/dev/null 2>&1; then
    log_fatal "Docker daemon is unresponsive or the current user lacks socket permissions."
fi

if ! docker compose version >/dev/null 2>&1; then
    log_fatal "Docker Compose CLI plugin (v2) is not detected."
fi

log_info "Checking filesystem hierarchy and compose files..."

[[ -d "${COMPOSE_DIR}" ]] || log_fatal "Compose directory not found at: ${COMPOSE_DIR}"
[[ -f "${COMPOSE_DIR}/docker-compose.yml" ]] || log_fatal "docker-compose.yml not found in ${COMPOSE_DIR}"

if [[ ! -f "${ENV_FILE}" ]]; then
    if [[ -f "${ENV_EXAMPLE}" ]]; then
        log_info "Creating .env configuration from .env.example..."
        cp "${ENV_EXAMPLE}" "${ENV_FILE}"
        chmod 0600 "${ENV_FILE}"
    else
        log_fatal "Missing both .env and .env.example in ${COMPOSE_DIR}"
    fi
fi

log_info "Evaluating cryptographic encryption seed..."
CURRENT_KEY=$(grep -E '^N8N_ENCRYPTION_KEY=' "${ENV_FILE}" | cut -d '=' -f2- || true)

if [[ -z "${CURRENT_KEY}" || "${CURRENT_KEY}" == "replace_with_a_secure_32_character_hex_encryption_key_here" ]]; then
    log_info "Generating a fresh 32-character hexadecimal encryption key..."
    NEW_KEY=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    sed -i "s|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=${NEW_KEY}|" "${ENV_FILE}"
    log_success "Cryptographic key generated and saved to ${ENV_FILE}"
fi

log_info "Pulling container images and instantiating stack..."
cd "${COMPOSE_DIR}"
docker compose pull
docker compose up -d --remove-orphans

log_info "Awaiting service health convergence..."
MAX_RETRIES=30
RETRY_COUNT=0
HEALTHY=false

while [[ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]]; do
    if docker compose ps postgres | grep -q "(healthy)"; then
        HEALTHY=true
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    sleep 2
done

if [[ "${HEALTHY}" != "true" ]]; then
    log_fatal "PostgreSQL service failed to reach healthy status within 60 seconds."
fi

log_success "Active-Defense-Auto-Quarantine SOAR stack is live on http://192.168.10.2:80/"
