#!/bin/sh
set -eu

###############################################################################
# Active-Defense-Auto-Quarantine Setup Script
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
ENV_FILE="${COMPOSE_DIR}/.env"
ENV_EXAMPLE="${COMPOSE_DIR}/.env.example"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"

log_info "Using installation directory: ${BASE_DIR}"

if [ ! -d "${BASE_DIR}" ]; then
    log_warn "Creating ${BASE_DIR}"
    mkdir -p "${BASE_DIR}"
fi

if [ ! -d "${COMPOSE_DIR}" ]; then
    log_warn "Creating ${COMPOSE_DIR}"
    mkdir -p "${COMPOSE_DIR}"
fi

###############################################################################
# Root Check
###############################################################################

if [ "$(id -u)" -ne 0 ]; then
    log_fatal "This installer must be run as root."
fi

###############################################################################
# Docker Installation
###############################################################################

log_info "Checking Docker installation..."

if ! command -v docker >/dev/null 2>&1; then

    log_warn "Docker not found. Installing..."

    apk update

    apk add \
        docker \
        docker-cli \
        docker-cli-compose \
        curl \
        git

    rc-update add docker default >/dev/null 2>&1 || true

    service docker start >/dev/null 2>&1 || \
    rc-service docker start >/dev/null 2>&1 || true

    sleep 5
fi

if ! command -v docker >/dev/null 2>&1; then
    log_fatal "Docker installation failed."
fi

log_success "Docker binary detected."

###############################################################################
# Docker Service
###############################################################################

if ! pgrep dockerd >/dev/null 2>&1; then

    log_warn "Docker daemon not running. Starting..."

    service docker start >/dev/null 2>&1 || \
    rc-service docker start >/dev/null 2>&1 || true

    sleep 5
fi

if ! docker info >/dev/null 2>&1; then
    log_fatal "Docker daemon is not responding."
fi

log_success "Docker daemon is running."

###############################################################################
# Docker Compose
###############################################################################

if ! docker compose version >/dev/null 2>&1; then

    log_warn "Docker Compose plugin missing. Installing..."

    apk add docker-cli-compose

    if ! docker compose version >/dev/null 2>&1; then
        log_fatal "Docker Compose installation failed."
    fi
fi

log_success "Docker Compose plugin detected."

###############################################################################
# Download Compose Assets
###############################################################################

if [ ! -f "${COMPOSE_FILE}" ]; then

    log_info "Downloading docker-compose.yml..."

    curl -fsSL \
    "https://raw.githubusercontent.com/rabakuku/Youtube/main/Video-2-Active-Defense-Auto-Quarantine/compose/docker-compose.yml" \
    -o "${COMPOSE_FILE}"

    [ -f "${COMPOSE_FILE}" ] || \
        log_fatal "Failed to download docker-compose.yml"

    log_success "docker-compose.yml downloaded."
fi

if [ ! -f "${ENV_EXAMPLE}" ]; then

    log_info "Downloading .env.example..."

    curl -fsSL \
    "https://raw.githubusercontent.com/rabakuku/Youtube/main/Video-2-Active-Defense-Auto-Quarantine/compose/.env.example" \
    -o "${ENV_EXAMPLE}"

    [ -f "${ENV_EXAMPLE}" ] || \
        log_fatal "Failed to download .env.example"

    log_success ".env.example downloaded."
fi

###############################################################################
# Environment File
###############################################################################

if [ ! -f "${ENV_FILE}" ]; then

    log_info "Creating .env file..."

    cp "${ENV_EXAMPLE}" "${ENV_FILE}"

    chmod 600 "${ENV_FILE}"

    log_success ".env created."
fi

###############################################################################
# Encryption Key
###############################################################################

CURRENT_KEY="$(grep '^N8N_ENCRYPTION_KEY=' "${ENV_FILE}" 2>/dev/null | cut -d '=' -f2- || true)"

if [ -z "${CURRENT_KEY}" ] || \
   [ "${CURRENT_KEY}" = "replace_with_a_secure_32_character_hex_encryption_key_here" ]; then

    log_info "Generating N8N encryption key..."

    NEW_KEY="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"

    sed -i \
        "s|^N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=${NEW_KEY}|" \
        "${ENV_FILE}"

    log_success "Encryption key updated."
fi

###############################################################################
# Deploy
###############################################################################

log_info "Deploying containers..."

cd "${COMPOSE_DIR}"

docker compose pull

docker compose up -d --remove-orphans

###############################################################################
# Health Check
###############################################################################

log_info "Waiting for PostgreSQL to become healthy..."

MAX_RETRIES=60
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

log_success "Deployment completed successfully."
log_success "Installation Directory: ${BASE_DIR}"
log_success "Compose Directory: ${COMPOSE_DIR}"
log_success "Access URL: http://192.168.10.2:80/"
