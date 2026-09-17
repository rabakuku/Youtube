#!/bin/sh
# filepath: scripts/rollback.sh
# ==============================================================================
# Script Name : rollback.sh
# Description : Interactive teardown script providing tiered removal options:
#               1) Remove containers, volumes, and networks only
#               2) Remove containers + Docker runtime + Compose plugin
#               3) Full purge of everything installed by setup.sh
# ==============================================================================

set -e

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
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
    log_err "This rollback script must be run as root. Run with sudo or switch to root."
    exit 1
fi

# 2. Path Resolution
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd || echo "/opt/mattermost-stack")"
COMPOSE_DIR="$BASE_DIR/compose"

# 3. Teardown Helper Functions
remove_containers_and_volumes() {
    log_info "Stopping containers and purging volumes/networks..."
    if [ -d "$COMPOSE_DIR" ] && [ -f "$COMPOSE_DIR/docker-compose.yml" ]; then
        cd "$COMPOSE_DIR"
        if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
            docker compose down -v --remove-orphans 2>/dev/null || true
        fi
    fi

    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        for container in mattermost-app mattermost-postgres; do
            if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
                log_warn "Force removing container: $container"
                docker rm -f "$container" 2>/dev/null || true
            fi
        done

        for vol in mattermost_db_data mattermost_app_config mattermost_app_data mattermost_app_logs mattermost_app_plugins mattermost_app_client_plugins mattermost_app_bleve; do
            if docker volume ls --format '{{.Name}}' | grep -q "^${vol}$"; then
                log_warn "Removing persistent volume: $vol"
                docker volume rm -f "$vol" 2>/dev/null || true
            fi
        done

        if docker network ls --format '{{.Name}}' | grep -q "^mattermost_backend_net$"; then
            log_warn "Removing isolated bridge network: mattermost_backend_net"
            docker network rm mattermost_backend_net 2>/dev/null || true
        fi
    fi
    log_info "Container and volume cleanup complete."
}

remove_docker_engine() {
    log_info "Stopping Docker daemon and disabling service..."
    if command -v rc-service >/dev/null 2>&1; then
        rc-service docker stop 2>/dev/null || true
        rc-update del docker boot 2>/dev/null || true
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl stop docker 2>/dev/null || true
        systemctl disable docker 2>/dev/null || true
    fi

    log_info "Uninstalling Docker Engine, CLI Compose plugin, and containerd..."
    if command -v apk >/dev/null 2>&1; then
        apk del docker docker-cli-compose containerd 2>/dev/null || true
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
    fi

    log_warn "Purging Docker data directory (/var/lib/docker)..."
    rm -rf /var/lib/docker /var/run/docker.sock 2>/dev/null || true
    log_info "Docker runtime and Compose removal complete."
}

remove_all_setup_dependencies() {
    remove_docker_engine

    log_info "Removing all additional utilities installed by setup.sh..."
    if command -v apk >/dev/null 2>&1; then
        apk del e2fsprogs iptables curl net-tools ca-certificates 2>/dev/null || true
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get purge -y e2fsprogs iptables curl net-tools ca-certificates 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
    fi

    log_warn "Removing generated compose configurations and environment files..."
    rm -rf "$COMPOSE_DIR" 2>/dev/null || true

    log_info "Complete teardown finished. System restored to pre-setup.sh baseline."
}

# 4. Interactive Selection Menu
printf "\n"
printf "${CYAN}======================================================================${NC}\n"
printf "${CYAN}               Mattermost Lab Teardown & Rollback Menu                ${NC}\n"
printf "${CYAN}======================================================================${NC}\n"
printf "Please select the teardown scope you wish to execute:\n\n"
printf "  ${GREEN}[1]${NC} Remove ${YELLOW}CONTAINERS & VOLUMES ONLY${NC}\n"
printf "      - Stops containers, drops networks, and deletes named volumes.\n"
printf "      - Keeps Docker Engine, compose configurations, and system packages.\n\n"
printf "  ${GREEN}[2]${NC} Remove ${YELLOW}CONTAINERS + DOCKER + COMPOSE${NC}\n"
printf "      - Executes option 1.\n"
printf "      - Stops Docker service, disables from boot, and uninstalls Docker/containerd.\n"
printf "      - Leaves system network tools and repository changes intact.\n\n"
printf "  ${GREEN}[3]${NC} Remove ${RED}ALL THAT WAS INSTALLED WITH SETUP.SH${NC} (Full Reset)\n"
printf "      - Executes option 1 and option 2.\n"
printf "      - Uninstalls e2fsprogs, iptables, curl, net-tools, ca-certificates.\n"
printf "      - Purges the compose directory, .env, and /var/lib/docker.\n\n"
printf "  ${GREEN}[4]${NC} Cancel and Exit\n"
printf "${CYAN}----------------------------------------------------------------------${NC}\n"

printf "Enter your choice [1-4]: "
read -r user_choice

case "$user_choice" in
    1)
        printf "\n"
        log_warn "Executing Tier 1: Container, volume, and network teardown..."
        remove_containers_and_volumes
        log_info "Rollback option 1 completed successfully."
        ;;
    2)
        printf "\n"
        log_warn "Executing Tier 2: Containers + Docker + Compose removal..."
        remove_containers_and_volumes
        remove_docker_engine
        log_info "Rollback option 2 completed successfully."
        ;;
    3)
        printf "\n"
        log_warn "Executing Tier 3: Complete purge of all packages, containers, and configurations..."
        remove_containers_and_volumes
        remove_all_setup_dependencies
        log_info "Rollback option 3 completed successfully."
        ;;
    4|*)
        printf "\n"
        log_info "Operation cancelled by user. No modifications were made."
        exit 0
        ;;
esac
