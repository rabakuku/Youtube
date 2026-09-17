### Stage 5: GitHub Repository Documentation Hub

Consolidate the architecture into a standardized, production-ready GitHub repository layout containing complete master documentation, repository readmes, automated deployment scripts, and rollback procedures.

```markdown
<!-- filepath: docs/main.md -->
# Automated Security Fabric & Containerized Alerting Infrastructure

This master technical reference consolidates the engineering implementation across Host Hardening (Stage 2), Container Architecture (Stage 3), and FortiOS Security Fabric Integration (Stage 4).

---

## 1. Architectural Baseline & Network Schema

* **Network Fabric:** `192.168.10.0/24` (Trust Zone / LAN)
* **Default Gateway (FortiGate `port2`):** `192.168.10.1`
* **Hardened Container Host (Alpine Linux):** `192.168.10.2`
* **Test Client Workstation (Diagnostic PC):** `192.168.10.3`
* **External Ingress / Inbound VIP:** `198.51.100.1` (TCP Port `80` mapped to `192.168.10.2:80`)

---

## 2. Alpine Host Runtime Deployment

Docker Engine and Containerd are deployed atop Alpine Linux using OpenRC service supervision.

### Host Provisioning
1. Enable community repository:
   ```bash
   sed -i 's/^#\(.*\/community\)/\1/' /etc/apk/repositories
   apk update

```

2. Install engine components:
```bash
apk add --no-cache docker docker-cli-compose containerd e2fsprogs iptables curl net-tools

```


3. Establish user privileges:
```bash
addgroup <your_username> docker
addgroup <your_username> wheel

```


4. Register and initialize OpenRC daemon:
```bash
rc-update add docker boot
rc-service docker start

```



---

## 3. Containerized Service Topology

Mattermost and PostgreSQL 15 operate over an internal bridge network (`172.28.0.0/24`), exposing the HTTP frontend directly to the host's primary network interface.

### Docker Stack Specification

* **Mattermost App Host Binding:** `0.0.0.0:80 -> 8065/tcp`
* **PostgreSQL Network Isolation:** `172.28.0.10:5432` (Internal only)
* **Volumes Declared:**
* `mattermost_db_data`: PostgreSQL transaction journals and SQL records.
* `mattermost_app_config`: Server `config.json` application configuration.
* `mattermost_app_data`: Uploaded blobs and channel attachment assets.
* `mattermost_app_logs`: Audit and runtime process logs.
* `mattermost_app_plugins` & `mattermost_app_client_plugins`: Runtime webhook and plugin bindings.
* `mattermost_app_bleve`: Full-text search index store.



---

## 4. FortiOS Perimeter & Routing Configuration

Perimeter routing policies govern traffic delivery between external boundaries, the container workload, and diagnostic hosts.

### Production CLI Configuration

```fortios
config system interface
    edit "port2"
        set vdom "root"
        set ip 192.168.10.1 255.255.255.0
        set allowaccess ping https ssh
        set type physical
        set description "LAN-Mattermost-Fabric"
    next
end

config firewall address
    edit "HOST_Alpine_Mattermost"
        set subnet 192.168.10.2 255.255.255.255
    next
    edit "NET_LAN_192.168.10.0"
        set subnet 192.168.10.0 255.255.255.0
    next
    edit "HOST_Client_Tester"
        set subnet 192.168.10.3 255.255.255.255
    next
end


config firewall policy
    edit 20
        set name "LAN_Outbound_Internet"
        set srcintf "port2"
        set dstintf "port1"
        set action accept
        set srcaddr "NET_LAN_192.168.10.0"
        set dstaddr "all"
        set schedule "always"
        set service "ALL"
        set nat enable
        set logtraffic utm
    next
    edit 30
        set name "LAN_Client_to_Mattermost"
        set srcintf "port2"
        set dstintf "port2"
        set action accept
        set srcaddr "HOST_Client_Tester"
        set dstaddr "HOST_Alpine_Mattermost"
        set schedule "always"
        set service "HTTP"
        set logtraffic all
    next
end

```

---

## 5. Verification & Diagnostics Verification Checkpoints

* **Host Socket Status:** `rc-service docker status` and `docker info`
* **Container Operational Health:** `docker compose ps` (Check healthy states)
* **Socket Listening:** `netstat -tuln | grep :80`
* **Gateway ARP Validation:** `get system arp | grep 192.168.10.2`
* **Stateful Flow Verification:** `diagnose sniffer packet port2 'host 192.168.10.2 and port 80' 4 0 l`

```

```markdown
<!-- filepath: README.md -->
# FortiGate Security Alert Automation to Mattermost on Alpine Docker

[![Build Status](https://img.shields.io/badge/build-passing-brightgreen.svg)](#)
[![FortiOS](https://img.shields.io/badge/FortiOS-7.x%20%7C%20Active-orange.svg)](#)
[![Docker](https://img.shields.io/badge/Docker-Engine%20v24+-blue.svg)](#)
[![Alpine Linux](https://img.shields.io/badge/Alpine%20Linux-v3.19%20%2F%20v3.20-blue.svg)](#)
[![Mattermost](https://img.shields.io/badge/Mattermost-Team%20Edition-0058CC.svg)](#)
[![Security Policy](https://img.shields.io/badge/Zero--Trust-Enforced-red.svg)](#)

A production-grade, GitOps-ready framework deploying self-hosted Mattermost inside Docker on Alpine Linux, integrated directly with FortiGate perimeter security policies, VIP address mapping, and event alerting pipelines.

---

## Network Architecture & Topology

```text
               +--------------------------------------------------+
               |                  WAN / External                  |
               |                IP: 198.51.100.0/24               |
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
     |   Alpine Linux    |                             |  Windows Client   |
     |   Docker Engine   |                             |   Test Bed Host   |
     +-------------------+                             +-------------------+
     | [Port 80:HTTP]    |                             | Validation:       |
     |  - mattermost-app |                             | `curl 192.168.10.2`|
     |  - postgres:15    |                             +-------------------+
     +-------------------+

```

---

## Architectural Problem Statement

Enterprise SOC teams frequently face high alert latency when perimeter firewalls rely strictly on centralized syslog collectors or manual administrative review. By combining Alpine Linux’s ultra-minimal host attack surface with Docker container isolation and FortiOS Virtual IP (VIP) policies, this repository establishes an automated real-time incident pipeline directly to Mattermost incoming webhooks without complex intermediate ingestion servers.

---

## Repository Layout

```text
├── scripts/
│   ├── setup.sh
│   └── rollback.sh
├── compose/
│   ├── docker-compose.yml
│   └── .env.example
├── docs/
│   ├── install-docker.md
│   ├── Configuration.md
│   ├── Fortinet.md
│   └── main.md
├── presentation/
│   ├── PowerPoint_Example.html
└── README.md

```

---

## Quickstart Deployment

1. **Clone the repository onto the Alpine host (`192.168.10.2`):**
```bash
git clone [https://github.com/your-org/fortigate-mattermost-automation.git](https://github.com/your-org/fortigate-mattermost-automation.git) /opt/mattermost-stack
cd /opt/mattermost-stack

```


2. **Execute the automated deployment harness:**
```bash
chmod +x scripts/setup.sh scripts/rollback.sh
./scripts/setup.sh

```


3. **Verify Host Services:**
```bash
docker compose -f compose/docker-compose.yml ps

```



---

## Teardown & Quick-Rollback

To terminate running containers, wipe persistent data volumes, and reset the host environment, execute:

```bash
./scripts/rollback.sh

```

Or perform manual removal via Docker CLI:

```bash
docker compose -f compose/docker-compose.yml down -v --remove-orphans

```

```

```bash
#!/bin/sh
# filepath: scripts/setup.sh
# ==============================================================================
# Script Name : setup.sh
# Description : Automated host provisioning, environment validation, and
#               container stack deployment for Mattermost on Alpine Linux.
# ==============================================================================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
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
    log_err "This deployment script must be run as root. Exiting."
    exit 1
fi

log_info "Starting Automated Deployment Pipeline..."

# 2. Alpine Repository & Package Dependency Check
if ! grep -q "^http.*/community" /etc/apk/repositories; then
    log_info "Enabling Alpine Community repository in /etc/apk/repositories..."
    sed -i 's/^#\(.*\/community\)/\1/' /etc/apk/repositories
fi

log_info "Updating local package indices..."
apk update

log_info "Installing runtime prerequisites..."
apk add --no-cache \
    docker \
    docker-cli-compose \
    containerd \
    e2fsprogs \
    iptables \
    curl \
    net-tools

# 3. OpenRC Service Check & Initialization
log_info "Configuring Docker OpenRC service state..."
if ! rc-status boot | grep -q "docker"; then
    rc-update add docker boot
fi

if ! rc-service docker status | grep -q "started"; then
    log_info "Starting Docker daemon..."
    rc-service docker start
else
    log_info "Docker daemon is already running."
fi

# 4. Resolve Base Directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="$BASE_DIR/compose"

cd "$COMPOSE_DIR"

# 5. Environment File Verification
if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        log_warn ".env file not detected. Generating from .env.example..."
        cp .env.example .env
    else
        log_err ".env.example template missing. Aborting stack launch."
        exit 1
    fi
fi

# 6. Verify Port 80 Listener Availability
if netstat -tuln | grep -q ":80 "; then
    log_err "Port 80 is already bound on this host. Stop conflicting services before continuing."
    exit 1
fi

# 7. Execute Container Stack Deployment
log_info "Launching PostgreSQL and Mattermost containers via Compose..."
docker compose pull
docker compose up -d

# 8. Post-Flight Health Verification
log_info "Waiting for service health convergence (30 seconds)..."
sleep 10

RETRIES=10
COUNT=0
SUCCESS=false

while [ "$COUNT" -lt "$RETRIES" ]; do
    if docker compose ps | grep -q "healthy"; then
        SUCCESS=true
        break
    fi
    log_warn "Healthcheck pending... retry $((COUNT+1)) of $RETRIES"
    sleep 5
    COUNT=$((COUNT+1))
done

if [ "$SUCCESS" = true ]; then
    log_info "Deployment successfully completed!"
    log_info "Mattermost endpoint accessible at: http://192.168.10.2:80"
else
    log_warn "Stack launched, but health state is still converging. Run 'docker compose ps' to verify."
fi

```

```bash
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

```

---

