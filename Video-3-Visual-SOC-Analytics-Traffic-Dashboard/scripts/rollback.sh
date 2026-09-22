# filepath: scripts/rollback.sh
#!/bin/sh
# -----------------------------------------------------------------------------
# Fortinet Visual SOC Lab - Teardown and Rollback Script (Alpine Linux)
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
    
    echo "[*] Removing downloaded configuration files..."
    cd ..
    rm -rf "${BASE_DIR}"

    echo "[+] Rollback complete. The Docker environment and configurations are now clean."
else
    echo "[-] Error: Compose directory not found at ${BASE_DIR}."
    echo "[-] Have you run the setup.sh script yet?"
    exit 1
fi
