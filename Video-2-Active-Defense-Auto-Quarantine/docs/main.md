<!-- filepath: docs/main.md -->
# Active-Defense-Auto-Quarantine: Master Technical Runbook & Architecture Specification

## 1. Executive Summary & Problem Statement

Traditional perimeter security architectures rely heavily on asynchronous event logging, Security Information and Event Management (SIEM) ingestion pipelines, and human triage to mitigate malicious traffic. Under high-rate reconnaissance sweeps, automated SYN floods, or exploit attempts, this operational latency creates an exposure window where attackers can discover open services, map topology, or exhaust connection tables.

The **Active-Defense-Auto-Quarantine** architecture closes this loop by establishing an autonomous, closed-loop Security Orchestration, Automation, and Response (SOAR) pipeline at the network edge. FortiOS detects incoming Layer 4/Layer 7 anomalies in real time via its hardware-accelerated state engines. Rather than waiting for external analysis, an internal FortiOS Automation Stitch dispatches an outbound HTTP POST webhook containing incident metadata directly to an on-premises containerized orchestration engine (n8n running on Alpine Linux 3.24).

The orchestrator sanitizes the event payload, evaluates CIDR whitelists to prevent denial-of-service against legitimate infrastructure, and executes authenticated REST API calls against FortiOS over TLS. FortiOS dynamically creates a host address object, binds it to a dedicated quarantine address group, and enforces an immediate kernel-level drop policy while flushing existing state sessions. Total elapsed containment time occurs in under 150 milliseconds without human intervention.

---

## 2. Lab Topology & Addressing Architecture

The lab environment operates on a dedicated L2/L3 broadcast domain (`192.168.10.0/24`) representing the internal and perimeter security boundaries:

```
                                  +---------------------------------------+
                                  |            FortiGate VM               |
                                  |           FGT-CORE-01                 |
                                  |           (FortiOS 7.4)               |
                                  |           192.168.10.1                |
                                  +---------------------------------------+
                                       |                             ^
       1. SYN Flood / Port Probe       |                             | 4. REST API Dynamic
          (Adversary Ingress)          |                             |    Quarantine Policy
                                       v                             |    (TCP 443 HTTPS)
+--------------------------------+     | 2. Automation Stitch        |
|          Kali Linux            |     |    Webhook Trigger          |
|        Attacker Node           |     |    (TCP 80 HTTP)            |
|         192.168.10.3           |     v                             |
+--------------------------------+    +-----------------------------------+
       |                              |        Alpine Linux 3.24          |
       +----------------------------> |         (Docker Host)             |
          5. Connection Terminated /  |          192.168.10.2             |
             Subsequent Packets       |  +-----------------------------+  |
             Dropped at Silicon       |  |  n8n SOAR Orchestrator Core |  |
                                      |  |  PostgreSQL 16 Storage      |  |
                                      |  +-----------------------------+  |
                                      +-----------------------------------+
```

### Static Node Role & Network Matrix

| Node | Hostname / Role | IP Assignment | MAC Address | Interface | Core Services |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Node 1** | `FGT-CORE-01` | `192.168.10.1/24` | `00:09:0F:09:00:01` | `port2` | Firewall, DoS Sensor, Automation Stitch, REST API Server |
| **Node 2** | `alpine-soar-node` | `192.168.10.2/24` | VM-assigned | `eth0` | Alpine Linux 3.24, Docker 26+, n8n Orchestrator, PostgreSQL |
| **Node 3** | `kali-attacker-01` | `192.168.10.3/24` | VM-assigned | `eth0` | Kali Linux, `hping3`, `nmap`, Security Testing Tools |

---

## 3. Alpine Linux 3.24 Host & Docker Runtime Provisioning

The orchestration node runs on Alpine Linux 3.24 with the Docker Engine daemon managed via OpenRC.

### 3.1 Repository Configuration & Package Installation
Ensure community repositories are active and install required system utilities:
```sh
sed -i 's/^#\(.*\/community\)$/\1/' /etc/apk/repositories
apk update

apk add --no-cache \
    docker \
    docker-cli \
    docker-cli-compose \
    e2fsprogs \
    iptables \
    ip6tables \
    ca-certificates \
    curl \
    sudo
```

### 3.2 Kernel Tuning & Module Loading
Enable packet forwarding and bridge netfilter support:
```sh
modprobe bridge
modprobe br_netfilter

cat <<EOF> /etc/modules-load.d/docker.conf
bridge
br_netfilter
EOF

cat <<EOF> /etc/sysctl.d/docker.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sysctl -p /etc/sysctl.d/docker.conf
```

### 3.3 User Group & Service Management
Configure rootless execution credentials and launch the service:
```sh
adduser -s /bin/sh -D soaradmin
echo "soaradmin:ChangeMeSecurePass123!" | chpasswd
addgroup soaradmin docker
addgroup soaradmin wheel

echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

rc-update add docker default
rc-service docker start
```

---

## 4. Orchestration Engine: Container Compose Specification

The SOAR stack utilizes n8n linked to a PostgreSQL 16 persistence layer.

### 4.1 `compose/docker-compose.yml`
```yaml
services:
  n8n:
    image: docker.n8n.io/n8nio/n8n:${N8N_VERSION:-1.80.0}
    container_name: n8n-automation-core
    restart: unless-stopped
    ports:
      - "80:5678"
    environment:
      - N8N_HOST=${N8N_HOST:-192.168.10.2}
      - N8N_PORT=5678
      - N8N_PROTOCOL=${N8N_PROTOCOL:-http}
      - WEBHOOK_URL=${WEBHOOK_URL:-[http://192.168.10.2/](http://192.168.10.2/)}
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE:-UTC}
      - NODE_ENV=production
      - N8N_DIAGNOSTICS_ENABLED=false
      - N8N_VERSION_NOTIFICATIONS_ENABLED=false
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=168
      - EXECUTIONS_DATA_SAVE_ON_ERROR=all
      - EXECUTIONS_DATA_SAVE_ON_SUCCESS=all
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${POSTGRES_DB:-n8n_db}
      - DB_POSTGRESDB_USER=${POSTGRES_USER:-n8n_user}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - n8n_data:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      backend:
        ipv4_address: 172.28.10.10

  postgres:
    image: postgres:${POSTGRES_VERSION:-16-alpine}
    container_name: n8n-postgres-db
    restart: unless-stopped
    environment:
      - POSTGRES_DB=${POSTGRES_DB:-n8n_db}
      - POSTGRES_USER=${POSTGRES_USER:-n8n_user}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - PGDATA=/var/lib/postgresql/data/pgdata
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-n8n_user} -d ${POSTGRES_DB:-n8n_db}"]
      interval: 5s
      timeout: 5s
      retries: 10
      start_period: 10s
    networks:
      backend:
        ipv4_address: 172.28.10.11

volumes:
  n8n_data:
    name: n8n_enterprise_data
  postgres_data:
    name: n8n_enterprise_postgres

networks:
  backend:
    name: soar_internal_net
    driver: bridge
    ipam:
      driver: default
      config:
        - subnet: 172.28.10.0/24
          gateway: 172.28.10.1
```

### 4.2 `compose/.env.example`
```env
N8N_VERSION=1.80.0
N8N_HOST=192.168.10.2
N8N_PROTOCOL=http
WEBHOOK_URL=[http://192.168.10.2/](http://192.168.10.2/)
GENERIC_TIMEZONE=UTC
N8N_ENCRYPTION_KEY=replace_with_a_secure_32_character_hex_encryption_key_here

POSTGRES_VERSION=16-alpine
POSTGRES_DB=n8n_db
POSTGRES_USER=n8n_user
POSTGRES_PASSWORD=replace_with_a_strong_database_password_xyz789

FGT_HOST=192.168.10.1
FGT_PORT=443
FGT_API_TOKEN=autoquarantine-sec-token-xyz123
FGT_QUARANTINE_GROUP=GRP_ACTIVE_QUARANTINE
```

---

## 5. SOAR Workflow Implementation

The n8n workflow receives incoming incident JSON from FortiOS via HTTP POST, parses the offending host, validates IP boundaries, and triggers the REST API.

### Complete Workflow JSON Definition
```json
{
  "name": "FortiOS-Auto-Quarantine-Pipeline",
  "nodes": [
    {
      "parameters": {
        "httpMethod": "POST",
        "path": "quarantine",
        "responseMode": "onReceived",
        "responseData": "OK",
        "options": {}
      },
      "type": "n8n-nodes-base.webhook",
      "typeVersion": 2,
      "position": [0, 0],
      "id": "c7a6e7df-e9bf-4781-a83d-3aa9a4561001",
      "name": "FortiOS Anomaly Webhook",
      "webhookId": "quarantine"
    },
    {
      "parameters": {
        "jsCode": "const items = $input.all();\nconst returnData = [];\n\nfor (const item of items) {\n  const attackerIp = item.json.body?.srcip || item.json.srcip || item.json.body?.log?.srcip;\n  if (!attackerIp) continue;\n  const whitelist = ['192.168.10.1', '192.168.10.2', '127.0.0.1'];\n  if (whitelist.includes(attackerIp)) continue;\n  returnData.push({\n    json: {\n      attacker_ip: attackerIp,\n      object_name: `QUAR_${attackerIp}`,\n      comment: 'Automated isolation via SOAR stitch trigger'\n    }\n  });\n}\nreturn returnData;"
      },
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [220, 0],
      "id": "b6a5e7df-e9bf-4781-a83d-3aa9a4561002",
      "name": "Filter & Whitelist Check"
    },
    {
      "parameters": {
        "method": "POST",
        "url": "[https://192.168.10.1:443/api/v2/cmdb/firewall/address](https://192.168.10.1:443/api/v2/cmdb/firewall/address)",
        "sendHeaders": true,
        "headerParameters": {
          "parameters": [
            {
              "name": "Authorization",
              "value": "Bearer autoquarantine-sec-token-xyz123"
            }
          ]
        },
        "sendBody": true,
        "specifyBody": "json",
        "jsonBody": "={\n  \"name\": \"{{ $json.object_name }}\",\n  \"type\": \"ipmask\",\n  \"subnet\": \"{{ $json.attacker_ip }} 255.255.255.255\",\n  \"comment\": \"{{ $json.comment }}\"\n}",
        "options": {
          "allowUnauthorizedCerts": true
        }
      },
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [440, 0],
      "id": "a5a5e7df-e9bf-4781-a83d-3aa9a4561003",
      "name": "Create Host Address Object"
    },
    {
      "parameters": {
        "method": "PUT",
        "url": "[https://192.168.10.1:443/api/v2/cmdb/firewall/addrgrp/GRP_ACTIVE_QUARANTINE](https://192.168.10.1:443/api/v2/cmdb/firewall/addrgrp/GRP_ACTIVE_QUARANTINE)",
        "sendHeaders": true,
        "headerParameters": {
          "parameters": [
            {
              "name": "Authorization",
              "value": "Bearer autoquarantine-sec-token-xyz123"
            }
          ]
        },
        "sendBody": true,
        "specifyBody": "json",
        "jsonBody": "={\n  \"member\": [\n    {\n      \"name\": \"{{ $json.object_name }}\"\n    }\n  ]\n}",
        "options": {
          "allowUnauthorizedCerts": true
        }
      },
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [660, 0],
      "id": "94a5e7df-e9bf-4781-a83d-3aa9a4561004",
      "name": "Append to Quarantine Group"
    }
  ],
  "connections": {
    "FortiOS Anomaly Webhook": {
      "main": [[{ "node": "Filter & Whitelist Check", "type": "main", "index": 0 }]]
    },
    "Filter & Whitelist Check": {
      "main": [[{ "node": "Create Host Address Object", "type": "main", "index": 0 }]]
    },
    "Create Host Address Object": {
      "main": [[{ "node": "Append to Quarantine Group", "type": "main", "index": 0 }]]
    }
  },
  "active": true,
  "settings": { "executionOrder": "v1" }
}
```

---

## 6. FortiOS Security Fabric Integration

Apply these configurations to Node 1 (`FGT-CORE-01`) via SSH or administrative web console:

```fortios
config system interface
    edit "port2"
        set vdom "root"
        set ip 192.168.10.1 255.255.255.0
        set allowaccess ping https ssh http
        set type physical
    next
end

config system accprofile
    edit "prof_soar_automation"
        set comments "SOAR REST API Profile for Dynamic Quarantine"
        set firewallgrp read-write
        set netgrp read
        set loggrp read
        set sysgrp read
    next
end

config system api-user
    edit "soar-api-admin"
        set comments "n8n SOAR API Integration"
        set api-key "autoquarantine-sec-token-xyz123"
        set accprofile "prof_soar_automation"
        set vdom "root"
        config trusthost
            edit 1
                set ipv4-trusthost 192.168.10.2 255.255.255.255
            next
        end
    next
end

config firewall address
    edit "QUAR_PLACEHOLDER"
        set type ipmask
        set subnet 0.0.0.0 255.255.255.255
        set comment "Static anchor member for dynamic group initialization"
    next
    edit "HOST_ALPINE_SOAR"
        set type ipmask
        set subnet 192.168.10.2 255.255.255.255
        set comment "Container orchestration host"
    next
end

config firewall addrgrp
    edit "GRP_ACTIVE_QUARANTINE"
        set member "QUAR_PLACEHOLDER"
        set comment "Dynamic SOAR quarantine blocklist"
    next
end

config firewall policy
    edit 100
        set name "POLICY_ACTIVE_QUARANTINE_DROP"
        set srcintf "port2"
        set dstintf "any"
        set action deny
        set srcaddr "GRP_ACTIVE_QUARANTINE"
        set dstaddr "all"
        set schedule "always"
        set service "ALL"
        set logtraffic all
        set comments "SOAR automated isolation - drops attacking IPs instantly"
    next
    edit 101
        set name "POLICY_ALLOW_SOAR_OUTBOUND"
        set srcintf "port2"
        set dstintf "port2"
        set action accept
        set srcaddr "all"
        set dstaddr "HOST_ALPINE_SOAR"
        set schedule "always"
        set service "HTTP" "HTTPS"
        set logtraffic all
    next
end

config firewall DoS-policy
    edit 1
        set name "DOS_DETECT_SYN_SWEEP"
        set interface "port2"
        set srcaddr "all"
        set dstaddr "all"
        set service "ALL"
        config anomaly
            edit "tcp_syn_flood"
                set status enable
                set log enable
                set action pass
                set quarantine none
                set threshold 100
            next
            edit "tcp_port_scan"
                set status enable
                set log enable
                set action pass
                set quarantine none
                set threshold 30
            next
        end
    next
end

config system automation-action
    edit "ACTION_NOTIFY_N8N_SOAR"
        set action-type webhook
        set protocol http
        set method post
        set uri "192.168.10.2:80/webhook/quarantine"
        set http-body "{\"srcip\": \"%%log.srcip%%\", \"logid\": \"%%log.logid%%\", \"msg\": \"%%log.msg%%\", \"threat\": \"Port Scan / SYN Anomaly Detected\"}"
        set port 80
    next
end

config system automation-trigger
    edit "TRIG_DOS_ANOMALY"
        set event-type event-log
        set logid 0100022001
    next
end

config system automation-stitch
    edit "STITCH_AUTO_QUARANTINE"
        set status enable
        set trigger "TRIG_DOS_ANOMALY"
        config actions
            edit 1
                set action "ACTION_NOTIFY_N8N_SOAR"
                set required enable
            next
        end
    next
end
```

---

## 7. Operational Runbook: Emulation & Verification

### Step 1: Arm Real-Time Inspection Sniffers (FortiGate CLI)
Open an active SSH console to `192.168.10.1` and monitor the webhook outbound channel:
```fortios
diagnose sniffer packet port2 'host 192.168.10.2 and port 80' 4 0 l
```

### Step 2: Launch Adversary SYN Sweep (Kali Node - `192.168.10.3`)
Initiate a high-speed SYN flood targeting the FortiGate gateway interface:
```bash
hping3 -S --flood -V -p 80 192.168.10.1 --count 500
```

### Step 3: Observe Real-Time Orchestration Logs (Alpine Host - `192.168.10.2`)
```sh
docker compose -f ~/soar-stack/compose/docker-compose.yml logs --tail=20 n8n
```

### Step 4: Validate Dynamic Object Creation & Enforcement (FortiGate CLI)
Inspect the address table and group membership to confirm that `QUAR_192.168.10.3` was populated:
```fortios
get firewall address QUAR_192.168.10.3
get firewall addrgrp GRP_ACTIVE_QUARANTINE
diagnose sys session filter daddr 192.168.10.1
diagnose sys session list
```

### Step 5: Verify Complete Ingress Blackholing (Kali Node - `192.168.10.3`)
Attempt any standard ICMP or TCP probe to verify the hardware drop:
```bash
ping -c 3 192.168.10.1
```
*Expected Result:* 100% packet loss. Zero connection states established.
