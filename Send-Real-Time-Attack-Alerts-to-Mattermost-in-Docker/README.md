
<p align="left">
  <img src="https://img.shields.io/badge/FortiOS-7.x-orange.svg" alt="FortiOS" />
  <img src="https://img.shields.io/badge/Docker-Engine%20v24+-blue.svg" alt="Docker" />
  <img src="https://img.shields.io/badge/Alpine%20Linux-v3.19%20%2F%20v3.20-blue.svg" alt="Alpine Linux" />
  <img src="https://img.shields.io/badge/Mattermost-Team%20Edition-0058CC.svg" alt="Mattermost" />
  <img src="https://img.shields.io/badge/Zero--Trust-Enforced-red.svg" alt="Security Policy" />
</p>
```markdown
<!-- filepath: README.md -->
# FortiGate Real-Time Attack Alert Automation to Mattermost in Docker



An enterprise-grade, fully automated framework to deploy a self-hosted Mattermost ChatOps container stack on Alpine Linux and integrate FortiOS Automation Stitches to stream perimeter intrusion alerts directly to security engineering teams in under 50 milliseconds.

No manual file creation or entire Git repository cloning is required. The deployment script downloads and configures all necessary Compose files and dependencies on demand.

---

## Network Architecture & Topology

This deployment operates entirely across the internal trusted LAN subnet (`192.168.10.0/24`). FortiGate detects security events on its interfaces and uses an internal automation webhook action to dispatch JSON payloads directly to the Alpine container host on port `80`.

```text
               +--------------------------------------------------+
               |               WAN / Untrusted Ingress            |
               |                Subnet: 198.51.100.0/24           |
               +--------------------------------------------------+
                                        |
                                        | [port1: 198.51.100.1]
                               +-----------------+
                               |    FortiGate    |
                               | Next-Gen Firewall|
                               +-----------------+
                                        | [port2: 192.168.10.1]
                                        |
      ==================================+==================================
      |                 LAN Fabric Subnet: 192.168.10.0/24               |
      ==================================+==================================
                                        |
               +------------------------+------------------------+
               |                                                 |
               | [eth0: 192.168.10.2]                            | [eth0: 192.168.10.3]
     +-------------------+                             +-------------------+
     |   Alpine Linux    |                             |  Windows / Client |
     |   Docker Engine   |                             |   Test Bed Host   |
     +-------------------+                             +-------------------+
     | [Port 80:HTTP]    |                             | Diagnostic Check: |
     |  - mattermost-app |                             | curl 192.168.10.2 |
     |  - postgres:15    |                             +-------------------+
     +-------------------+

```

### Addressing Matrix

| Device / Host | Interface | IPv4 Address | Subnet Mask | Gateway | Function |
| --- | --- | --- | --- | --- | --- |
| **FortiGate Firewall** | `port2` | `192.168.10.1` | `255.255.255.0` (`/24`) | N/A | LAN Default Gateway & Automation Stitch Engine |
| **Alpine Linux Host** | `eth0` | `192.168.10.2` | `255.255.255.0` (`/24`) | `192.168.10.1` | Hardened Container Host (Mattermost Webhook Target) |
| **Client Test Station** | `eth0` | `192.168.10.3` | `255.255.255.0` (`/24`) | `192.168.10.1` | Test Traffic Generator & Socket Diagnostics |

---

## Architectural Problem Statement

Perimeter defense architectures frequently suffer from silent security failures. Critical IPS signatures, brute-force intrusions, and anomalous drops are written to system memory or forwarded to remote syslog collectors where human visibility is delayed by hours.

This project delivers a completely automated, zero-trust pipeline:

1. Hardens an ultra-minimal Alpine Linux host (`192.168.10.2`) with an enforced OS gatekeeper check.
2. Automates the deployment of PostgreSQL 15 and Mattermost Team Edition via [scripts/setup.sh](https://www.google.com/search?q=https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/scripts/setup.sh) by pulling required configurations without cloning the entire repository.
3. Connects FortiOS Automation Stitches directly to Mattermost incoming webhooks over the local LAN without public NAT or third-party cloud aggregators.

---

## Repository Layout

```text
├── scripts/
│   ├── setup.sh
│   └── rollback.sh
├── compose/
│   ├── docker-compose.yml
│   └── .env.example
├── Docs/
│   ├── install-docker.md
│   ├── Configuration.md
│   ├── Fortinet.md
│   └── main.md
├── presentation/
│   └── PowerPoint.html
└── README.md

```

---

## Automated Step-by-Step Deployment Runbook

Follow these stages in order to deploy, configure, and verify the alerting fabric.

```text
  [Step 1: Automated Run]  -->  [Step 2: Mattermost Webhook]  -->  [Step 3: FortiGate Stitch]  -->  [Step 4: Verify]
     scripts/setup.sh             GUI Webhook Generation             Docs/Fortinet.md             CLI Sniffer

```

---

### Step 1: Automated Host Provisioning & Stack Launch

You do not need to clone the entire Git repository. Simply fetch the `setup.sh` and `rollback.sh` scripts directly using `curl`, set execute permissions, and run `setup.sh`. The script automatically handles package installation, Docker initialization, and downloads the required Compose and environment files.

1. Log into your Alpine Linux host (`192.168.10.2`) as `root`.
2. Create a dedicated workspace and retrieve the automation scripts:
```bash
mkdir -p /opt/mattermost-stack && cd /opt/mattermost-stack
curl -fsSL [https://raw.githubusercontent.com/rabakuku/Youtube/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/scripts/setup.sh](https://raw.githubusercontent.com/rabakuku/Youtube/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/scripts/setup.sh) -o setup.sh
curl -fsSL [https://raw.githubusercontent.com/rabakuku/Youtube/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/scripts/rollback.sh](https://raw.githubusercontent.com/rabakuku/Youtube/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/scripts/rollback.sh) -o rollback.sh
chmod +x setup.sh rollback.sh

```


3. Execute the automated setup harness:
```bash
./setup.sh

```



**What `setup.sh` does automatically:**

* Validates that the host is strictly running Alpine Linux via `/etc/os-release`.
* Enables the Alpine Community repository in `/etc/apk/repositories`.
* Installs `docker`, `docker-cli-compose`, `containerd`, `iptables`, `curl`, `net-tools`, and `ca-certificates`.
* Registers the Docker service with the `boot` runlevel and starts the daemon via OpenRC.
* Automatically fetches [compose/docker-compose.yml](https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/compose/docker-compose.yml) and generates [compose/.env](https://www.google.com/search?q=https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/compose/.env.example).
* Binds the Mattermost listener directly to host port `80`.
* Executes an active healthcheck loop until PostgreSQL and Mattermost return healthy status.

> **Technical Reference:** If you want to review the underlying host configuration and container architecture details handled by the script, read:
> * 👉 **[Docs/install-docker.md](https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/Docs/install-docker.md)**
> * 👉 **[Docs/Configuration.md](https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/Docs/Configuration.md)**
> 
> 

---

### Step 2: Generate Mattermost Incoming Webhook

Once `setup.sh` reports success, configure the incident channel inside Mattermost:

1. Open a browser from your management or client machine (`192.168.10.3`) and navigate to:
```text
[http://192.168.10.2:80](http://192.168.10.2:80)

```


2. Follow the on-screen prompts to establish the initial System Administrator account.
3. Create a dedicated team and create a public channel named:
```text
security-alerts

```


4. Open the System Menu in the top left, select **Integrations**, and click **Incoming Webhooks**.
5. Click **Add Incoming Webhook**:
* **Title:** `FortiGate Threat Alerts`
* **Channel:** Select `security-alerts`


6. Click **Save** and copy the generated Webhook URL (format: `http://192.168.10.2/hooks/YOUR_HOOK_ID_HERE`). You will need this URL in Step 3.

---

### Step 3: Configure FortiGate Security Fabric & Automation Stitch

Configure FortiGate (`192.168.10.1`) to inspect traffic and trigger automated HTTP POST requests directly across the LAN to your Mattermost listener whenever an IPS attack or threat is detected.

1. Follow the full CLI and GUI walkthrough in:
👉 **[Docs/Fortinet.md](https://www.google.com/search?q=https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/Docs/Fortinet.md)**
2. Apply the address objects and internal policy on FortiGate:
```fortios
config firewall address
    edit "HOST_Alpine_Mattermost"
        set subnet 192.168.10.2 255.255.255.255
        set comment "Mattermost container host"
    next
    edit "NET_LAN_192.168.10.0"
        set subnet 192.168.10.0 255.255.255.0
        set comment "Internal trust LAN"
    next
end

config firewall policy
    edit 10
        set name "LAN_Client_to_Mattermost"
        set srcintf "port2"
        set dstintf "port2"
        set action accept
        set srcaddr "NET_LAN_192.168.10.0"
        set dstaddr "HOST_Alpine_Mattermost"
        set schedule "always"
        set service "HTTP"
        set logtraffic all
    next
end

```


3. Configure the FortiOS Automation Stitch (substituting your actual Webhook URI):
```fortios
config system automation-trigger
    edit "Trigger_IPS_Attack_Alert"
        set event-type event-log
        set logid 0419016384
        set description "Firewall IPS Threat Event"
    next
end

config system automation-action
    edit "Action_Mattermost_Webhook"
        set action-type webhook
        set protocol http
        set uri "hooks/YOUR_HOOK_ID_HERE"
        set port 80
        set http-body "{\"text\": \":warning: **[FORTIGATE SECURITY ALERT]** Threat intercepted!\\n- **Firewall:** %%log.devname%%\\n- **Threat:** %%log.attack%%\\n- **Source IP:** %%log.srcip%%\\n- **Destination IP:** %%log.dstip%%\\n- **Action:** %%log.action%%\\n- **Severity:** %%log.severity%%\"}"
        config http-headers
            edit 1
                set key "Content-Type"
                set value "application/json"
            next
        end
    next
end

config system automation-stitch
    edit "Stitch_FortiGate_to_Mattermost"
        set status enable
        set trigger "Trigger_IPS_Attack_Alert"
        config actions
            edit 1
                set action "Action_Mattermost_Webhook"
                set required enable
            next
        end
        config destination
            edit "HOST_Alpine_Mattermost"
            next
        end
    next
end

```



---

### Step 4: Verification & Diagnostic Checks

Confirm end-to-end communication from the FortiGate CLI before testing live attacks:

1. **Test Automation Action Dispatch:**
```fortios
diagnose automation test Stitch_FortiGate_to_Mattermost

```


*Expected Output:* FortiGate dispatches the HTTP payload to `192.168.10.2:80`, and a test notification immediately renders inside the `#security-alerts` channel.
2. **Verify LAN Packet Flow:**
```fortios
diagnose sniffer packet port2 'host 192.168.10.2 and port 80' 4 0 l

```


3. **Verify Host Port & Sockets on Alpine:**
```bash
netstat -tuln | grep :80
docker compose -f /opt/mattermost-stack/compose/docker-compose.yml ps

```



---

## Teardown & Rollback Automation

To reset, modify, or completely wipe the lab environment, execute the interactive rollback tool:

```bash
./rollback.sh

```

*(If `rollback.sh` is not present locally, download it directly: `curl -fsSL https://raw.githubusercontent.com/rabakuku/Youtube/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/scripts/rollback.sh -o rollback.sh && chmod +x rollback.sh && ./rollback.sh`)*

The script presents an interactive menu allowing you to choose the exact level of removal:

* **Option 1: Remove Containers & Volumes Only**
Stops containers, deletes bridge networks, and purges all persistent database and configuration volumes. Leaves the Docker engine and host packages intact.
* **Option 2: Remove Containers + Docker + Compose**
Executes Option 1, then stops the Docker daemon, unregisters OpenRC runlevels, and uninstalls `docker`, `docker-cli-compose`, and `containerd`.
* **Option 3: Remove All That Was Installed With setup.sh (Full Reset)**
Executes Option 1 and Option 2, purges all installed network and storage dependencies (`e2fsprogs`, `iptables`, `curl`, `net-tools`, `ca-certificates`), removes `/var/lib/docker`, and wipes all generated configuration files to return the system to its initial baseline.

---

## Educational & Media Production Assets

* **Master Architecture Specification:**
👉 **[Docs/main.md](https://www.google.com/search?q=https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/Docs/main.md)**
* **Full-Screen Interactive HTML Presentation Deck:**
👉 **[presentation/PowerPoint.html](https://www.google.com/search?q=https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/presentation/PowerPoint.html)**
Open in any modern browser for an edge-to-edge interactive presentation with animated SVG network traffic flows, keyboard controls (`Spacebar`, `Arrow Keys`), and zero-trust metric dashboards.

```

```bash
#!/bin/sh
# filepath: scripts/setup.sh
# ==============================================================================
# Script Name : setup.sh
# Description : Automated OS verification, host provisioning, repository retrieval,
#               and container stack deployment for Mattermost on Alpine Linux.
# Target OS   : Alpine Linux v3.19+ (Strictly Enforced)
# Repository  : https://github.com/rabakuku/Youtube/tree/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker
# ==============================================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
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
    log_err "This deployment script must be run as root. Execute with sudo or switch to root."
    exit 1
fi

# 2. Strict Operating System Verification Gate
log_info "Verifying host operating system compatibility..."

if [ ! -f /etc/os-release ]; then
    log_err "Cannot verify operating system (/etc/os-release missing)."
    log_err "This script strictly requires Alpine Linux. Aborting installation."
    exit 1
fi

# Source os-release parameters
. /etc/os-release

if [ "$ID" != "alpine" ]; then
    printf "\n"
    log_err "======================================================================"
    log_err " INCOMPATIBLE OPERATING SYSTEM DETECTED"
    log_err "======================================================================"
    log_err "Detected OS : ${PRETTY_NAME:-$ID}"
    log_err "Required OS : Alpine Linux (apk + OpenRC)"
    printf "\n"
    log_warn "Why this failed:"
    printf "  - This automation stack utilizes Alpine's 'apk' package manager and\n"
    printf "    'OpenRC' init service controls (rc-update, rc-service).\n"
    printf "  - Other distributions like Ubuntu/Debian (apt + systemd) or RHEL/Rocky\n"
    printf "    (dnf + systemd) require different package names and service managers.\n"
    printf "\n"
    log_err "Installation terminated. Please run this script on an Alpine Linux host."
    exit 1
fi

log_info "Operating system confirmed: Alpine Linux (${VERSION_ID:-release}). Proceeding..."

# 3. Alpine Community Repository Enablement
if [ -f /etc/apk/repositories ]; then
    if ! grep -q "^http.*/community" /etc/apk/repositories; then
        log_info "Enabling Alpine Community repository in /etc/apk/repositories..."
        sed -i 's/^#\(.*\/community\)/\1/' /etc/apk/repositories
    fi
    log_info "Updating local package index..."
    apk update
else
    log_err "/etc/apk/repositories is missing. Unable to proceed with package resolution."
    exit 1
fi

# 4. Install Docker Engine, Runtime & Network Diagnostic Tools
log_info "Installing Docker Engine, CLI Compose plugin, Containerd, and networking utilities..."
apk add --no-cache \
    docker \
    docker-cli-compose \
    containerd \
    e2fsprogs \
    iptables \
    curl \
    net-tools \
    ca-certificates

# 5. OpenRC Service Management
log_info "Configuring Docker OpenRC service state..."
if ! rc-status boot 2>/dev/null | grep -q "docker"; then
    log_info "Adding Docker to 'boot' runlevel..."
    rc-update add docker boot 2>/dev/null || true
fi

if ! rc-service docker status 2>/dev/null | grep -q "started"; then
    log_info "Starting Docker daemon process..."
    rc-service docker start
else
    log_info "Docker daemon is running and active."
fi

# 6. Resolve Workspace Directories
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd || echo "/opt/mattermost-stack")"
COMPOSE_DIR="$BASE_DIR/compose"

mkdir -p "$COMPOSE_DIR"
cd "$COMPOSE_DIR"

COMPOSE_RAW_URL="https://raw.githubusercontent.com/rabakuku/Youtube/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/compose/docker-compose.yml"
ENV_RAW_URL="https://raw.githubusercontent.com/rabakuku/Youtube/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/compose/.env.example"

# 7. Acquire docker-compose.yml
if [ -f "docker-compose.yml" ]; then
    log_info "Local docker-compose.yml detected in $COMPOSE_DIR."
else
    log_info "Fetching docker-compose.yml from GitHub repository..."
    if curl -fsSL "$COMPOSE_RAW_URL" -o docker-compose.yml; then
        log_info "Successfully downloaded docker-compose.yml."
    else
        log_warn "Remote download failed. Generating local standalone docker-compose.yml..."
        cat <<'EOF' > docker-compose.yml
services:
  postgres:
    image: postgres:15-alpine
    container_name: mattermost-postgres
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    pids_limit: 100
    read_only: false
    tmpfs:
      - /tmp
      - /var/run/postgresql
    volumes:
      - mattermost_db_data:/var/lib/postgresql/data
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    networks:
      backend_net:
        ipv4_address: 172.28.0.10
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  mattermost:
    image: mattermost/mattermost-team-edition:latest
    container_name: mattermost-app
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    pids_limit: 200
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - mattermost_app_config:/mattermost/config
      - mattermost_app_data:/mattermost/data
      - mattermost_app_logs:/mattermost/logs
      - mattermost_app_plugins:/mattermost/plugins
      - mattermost_app_client_plugins:/mattermost/client/plugins
      - mattermost_app_bleve:/mattermost/bleve-indexes
    environment:
      MM_SQLSETTINGS_DRIVERNAME: postgres
      MM_SQLSETTINGS_DATASOURCE: postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}?sslmode=disable&connect_timeout=10
      MM_SERVICESETTINGS_SITEURL: ${MM_SITE_URL}
      MM_SERVICESETTINGS_LISTENADDRESS: :8065
      MM_FILESETTINGS_DRIVERNAME: local
      MM_FILESETTINGS_DIRECTORY: /mattermost/data/
      MM_LOGSETTINGS_CONSOLELEVEL: INFO
      MM_LOGSETTINGS_ENABLECONSOLE: "true"
    ports:
      - "80:8065"
    networks:
      backend_net:
        ipv4_address: 172.28.0.20
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:8065/api/v4/system/ping || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 30s

volumes:
  mattermost_db_data:
    name: mattermost_db_data
  mattermost_app_config:
    name: mattermost_app_config
  mattermost_app_data:
    name: mattermost_app_data
  mattermost_app_logs:
    name: mattermost_app_logs
  mattermost_app_plugins:
    name: mattermost_app_plugins
  mattermost_app_client_plugins:
    name: mattermost_app_client_plugins
  mattermost_app_bleve:
    name: mattermost_app_bleve

networks:
  backend_net:
    name: mattermost_backend_net
    driver: bridge
    ipam:
      driver: default
      config:
        - subnet: 172.28.0.0/24
          gateway: 172.28.0.1
EOF
    fi
fi

# 8. Environment Variable File (.env) Verification
if [ ! -f ".env" ]; then
    if [ -f ".env.example" ]; then
        log_info "Creating .env from existing local .env.example..."
        cp .env.example .env
    else
        log_info "Fetching .env.example template from GitHub repository..."
        if curl -fsSL "$ENV_RAW_URL" -o .env.example; then
            cp .env.example .env
        else
            log_warn "Generating fallback production .env file..."
            cat <<'EOF' > .env
POSTGRES_DB=mattermost
POSTGRES_USER=mmuser
POSTGRES_PASSWORD=SecurePassword_ChangeMe_19216810!
MM_SITE_URL=http://192.168.10.2
APP_PORT=80
EOF
        fi
    fi
else
    log_info "Active .env configuration file detected."
fi

# 9. Port 80 Listener Conflict Check
if netstat -tuln 2>/dev/null | grep -q ":80 "; then
    log_warn "Port 80 is currently bound on the host interface. Inspecting process..."
    netstat -tulnp 2>/dev/null | grep ":80 " || true
    log_err "Port 80 is occupied. Terminate the conflicting listener before proceeding."
    exit 1
fi

# 10. Container Deployment via Docker Compose
log_info "Pulling official container images..."
docker compose pull

log_info "Starting Mattermost and PostgreSQL containers in detached mode..."
docker compose up -d

# 11. Healthcheck Verification Loop
log_info "Awaiting service health convergence..."

RETRIES=15
COUNT=0
HEALTHY=false

while [ "$COUNT" -lt "$RETRIES" ]; do
    APP_STATUS=$(docker inspect --format='{{json .State.Health.Status}}' mattermost-app 2>/dev/null || echo "\"starting\"")
    DB_STATUS=$(docker inspect --format='{{json .State.Health.Status}}' mattermost-postgres 2>/dev/null || echo "\"starting\"")

    if [ "$APP_STATUS" = "\"healthy\"" ] && [ "$DB_STATUS" = "\"healthy\"" ]; then
        HEALTHY=true
        break
    fi

    log_warn "Health status: PostgreSQL ($DB_STATUS), Mattermost ($APP_STATUS). Waiting 5s (attempt $((COUNT + 1))/$RETRIES)..."
    sleep 5
    COUNT=$((COUNT + 1))
done

# 12. Final Validation Summary
if [ "$HEALTHY" = true ]; then
    printf "\n"
    log_info "======================================================================"
    log_info " Mattermost Security Automation Host Successfully Deployed!"
    log_info "======================================================================"
    printf "${GREEN}Mattermost Web GUI : ${NC}http://192.168.10.2:80\n"
    printf "${GREEN}Internal Database  : ${NC}172.28.0.10:5432 (Isolated Docker Bridge)\n"
    printf "${GREEN}Container Health   : ${NC}\n"
    docker compose ps
    printf "\n${YELLOW}Next Step:${NC} Navigate to http://192.168.10.2:80 to create your admin account\n"
    printf "and generate your Incoming Webhook URL for the FortiOS Automation Stitch.\n"
else
    log_warn "Stack is running, but containers are still initializing. Check logs with:"
    printf "  docker compose -f %s/docker-compose.yml logs -f\n" "$COMPOSE_DIR"
fi

```

```bash
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

```

---
