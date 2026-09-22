
# filepath: scripts/rollback.sh
#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Fortinet Visual SOC Lab - Teardown and Rollback Script
# -----------------------------------------------------------------------------
# Safely spins down the container stack, removes persistent local volumes, 
# and cleans up the bridged Docker networks to reset the lab state.

echo "[*] Initiating Teardown of Fortinet Visual SOC Lab..."

BASE_DIR="$(pwd)/compose"

if [ -d "${BASE_DIR}" ]; then
    cd "${BASE_DIR}"
    
    echo "[*] Stopping containers and removing volumes (-v)..."
    docker compose down -v
    
    echo "[*] Pruning unused Docker networks..."
    docker network prune -f
    
    echo "[+] Rollback complete. The Docker environment is now clean."
    echo "[!] Note: Configuration files in ${BASE_DIR} were NOT deleted."
else
    echo "[-] Error: Compose directory not found at ${BASE_DIR}."
    echo "[-] Are you running this script from the project root?"
    exit 1
fi
