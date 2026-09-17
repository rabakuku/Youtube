#!/bin/sh
# filepath: scripts/rollback.sh
# ==============================================================================
# Script Name : rollback.sh
# Description : Complete teardown, container termination, volume destruction,
#               and network cleanup for the Mattermost automation stack.
# ==============================================================================

set -e

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() {
    printf "${GREEN}[INFO] %s${NC}\n" "$1"
}

log_warn() {
    printf "${YELLOW}[WARN] %s${NC}\n" "$1"
}

log_err() {
    printf "${RED}[ROLLBACK] %s${NC}\n" "$1"
}

# 1. Privilege Verification
if [ "$(id -u)" -ne 0 ]; then
    log_err "This rollback script must be run as root. Exiting."
    exit 1
fi

log_warn "Initiating full environment teardown..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="$BASE_DIR/compose"

cd "$COMPOSE_DIR"

# 2. Stop and Destroy Containers and Volumes
if [ -f docker-compose.yml ]; then
    log_info "Terminating containers, networks, and persistent data volumes..."
    docker compose down -v --remove-orphans
else
    log_err "docker-compose.yml not found in $COMPOSE_DIR. Proceeding with manual container sweep."
fi

# 3. Direct Cleanup Safeguard
log_info "Pruning stranded containers and dangling resources..."
for container in mattermost-app mattermost-postgres; do
    if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        log_warn "Removing stranded container: $container"
        docker rm -f "$container" || true
    fi
done

for volume in mattermost_db_data mattermost_app_config mattermost_app_data mattermost_app_logs mattermost_app_plugins mattermost_app_client_plugins mattermost_app_bleve; do
    if docker volume ls --format '{{.Name}}' | grep -q "^${volume}$"; then
        log_warn "Removing orphaned volume: $volume"
        docker volume rm -f "$volume" || true
    fi
done

if docker network ls --format '{{.Name}}' | grep -q "^mattermost_backend_net$"; then
    log_warn "Removing isolated bridge network: mattermost_backend_net"
    docker network rm mattermost_backend_net || true
fi

log_info "Rollback complete. Host port 80 and storage volumes have been purged."
