#!/bin/sh
set -eu

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

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BASE_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

COMPOSE_DIR="${BASE_DIR}/compose"
ENV_FILE="${COMPOSE_DIR}/.env"
ENV_EXAMPLE="${COMPOSE_DIR}/.env.example"

log_info "Verifying deployment environment and user permissions..."

if [ "$(id -u)" -eq 0 ]; then
    log_warn "Running directly as root."
fi

###############################################################################
# Docker Check / Install
###############################################################################

log_info "Checking Docker installation..."

if ! command -v docker >/dev/null 2>&1; then
    log_warn "Docker not found. Installing..."

    if command -v apk >/dev/null 2>&1; then
        apk update
        apk add docker docker-cli-compose curl
    else
        log_fatal "Unsupported operating system."
    fi

    rc-update add docker default >/dev/null 2>&1 || true
    service docker start || rc-service docker start

    sleep 5

    if ! command -v docker >/dev/null 2>&1; then
        log_fatal "Docker installation failed."
    fi
fi

log_success "Docker binary detected."

if ! pgrep dockerd >/dev/null 2>&1; then
    log_warn "Docker daemon not running. Starting..."

    service docker start >/dev/null 2>&1 || \
    rc-service docker start >/dev/null 2>&1 || true

    sleep 5
fi

if ! docker info >/dev/null 2>&1; then
    log_fatal "Docker daemon is unresponsive."
fi

log_success "Docker daemon is running."

if ! docker compose version >/dev/null 2>&1; then
    log_warn "Docker Compose plugin missing. Installing..."

    apk add docker-cli-compose

    if ! docker compose version >/dev/null 2>&1; then
        log_fatal "Docker Compose installation failed."
    fi
fi

log_success "Docker Compose plugin detected."

###############################################################################
# Compose Files
###############################################################################

log_info "Checking filesystem hierarchy and compose files..."

if [ ! -d "${COMPOSE_DIR}" ]; then
    log_fatal "Compose directory not found at: ${COMPOSE_DIR}"
fi

if [ ! -f "${COMPOSE_DIR}/docker-compose.yml" ]; then
    log_fatal "docker-compose.yml not found in ${COMPOSE_DIR}"
fi

###############################################################################
# Environment File
###############################################################################

if [ ! -f "${ENV_FILE}" ]; then

    if [ -f "${ENV_EXAMPLE}" ]; then

        log_info "Creating .env from .env.example..."

        cp "${ENV_EXAMPLE}" "${ENV_FILE}"
        chmod 600 "${ENV_FILE}"

    else

        log_fatal "Missing both .env and .env.example"

    fi
fi

###############################################################################
# Encryption Key
###############################################################################

log_info "Evaluating encryption seed..."

CURRENT_KEY="$(grep '^N8N_ENCRYPTION_KEY=' "${ENV_FILE}" 2>/dev/null | cut -d '=' -f2- || true)"

if [ -z "${CURRENT_KEY}" ] || \
   [ "${CURRENT_KEY}" = "replace_with_a_secure_32_character_hex_encryption_key_here" ]; then

    log_info "Generating encryption key..."

    NEW_KEY="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"

    sed -i \
    "s|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=${NEW_KEY}|" \
    "${ENV_FILE}"

    log_success "Encryption key updated."
fi

###############################################################################
# Deployment
###############################################################################

log_info "Deploying containers..."

cd "${COMPOSE_DIR}"

docker compose pull
docker compose up -d --remove-orphans

###############################################################################
# Health Check
###############################################################################

log_info "Waiting for PostgreSQL health check..."

MAX_RETRIES=30
RETRY_COUNT=0
HEALTHY=false

while [ "${RETRY_COUNT}" -lt "${MAX_RETRIES}" ]
do

    if docker compose ps postgres 2>/dev/null | grep -q healthy; then
        HEALTHY=true
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    sleep 2

done

if [ "${HEALTHY}" != "true" ]; then
    log_fatal "PostgreSQL failed health check."
fi

###############################################################################
# Success
###############################################################################

log_success "Active-Defense-Auto-Quarantine stack is live."
log_success "Access URL: http://192.168.10.2:80/"
