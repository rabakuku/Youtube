#!/bin/sh
set -e

COMPOSE_DIR="/opt/honeypot-quarantine/compose"

echo "=========================================================="
echo "    Active Honeypot Lab - Teardown & Rollback Utility    "
echo "=========================================================="

# Verify Operating System is Alpine Linux
if [ ! -f /etc/os-release ]; then
    echo "[-] Error: /etc/os-release not found. Target operating system is not Alpine Linux."
    exit 1
fi

. /etc/os-release
if [ "$ID" != "alpine" ]; then
    echo "[-] Incompatible operating system: $ID. This script is strictly configured for Alpine Linux."
    exit 1
fi

echo "Select a rollback option:"
echo "1) Full Teardown (Stop containers, prune volumes, delete files, remove packages)"
echo "2) Container & Storage Teardown (Stop stack, remove containers and volumes only)"
echo "3) Clean Artifacts Only (Remove downloaded compose and config files)"
echo "4) Abort Rollback"
printf "Enter selection [1-4]: "
read -r CHOICE

case "$CHOICE" in
    1)
        echo "[+] Executing full environment rollback..."
        if [ -d "$COMPOSE_DIR" ]; then
            cd "$COMPOSE_DIR"
            if [ -f docker-compose.yml ]; then
                docker compose down -v --remove-orphans || true
            fi
            cd /
            rm -rf /opt/honeypot-quarantine
        fi
        echo "[+] Stopping Docker service..."
        rc-service docker stop || true
        rc-update del docker default || true
        echo "[+] Removing installed tools..."
        apk del docker docker-cli-compose || true
        echo "[+] Complete teardown finished."
        ;;
    2)
        echo "[+] Tearing down containers and volumes..."
        if [ -d "$COMPOSE_DIR" ]; then
            cd "$COMPOSE_DIR"
            if [ -f docker-compose.yml ]; then
                docker compose down -v --remove-orphans
            fi
        fi
        echo "[+] Honeypot container services stopped and volumes purged."
        ;;
    3)
        echo "[+] Removing configuration files..."
        rm -rf /opt/honeypot-quarantine
        echo "[+] Artifact directory /opt/honeypot-quarantine removed."
        ;;
    4)
        echo "[+] Rollback aborted."
        exit 0
        ;;
    *)
        echo "[-] Invalid selection. Exiting."
        exit 1
        ;;
esac
