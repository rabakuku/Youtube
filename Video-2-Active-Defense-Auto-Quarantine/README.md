<!-- filepath: README.md -->
# 🛡️ Active-Defense-Auto-Quarantine

[![FortiOS](https://img.shields.io/badge/FortiOS-7.4.x-ee2737.svg?style=for-the-badge&logo=fortinet&logoColor=white)](https://www.fortinet.com/)
[![Alpine Linux](https://img.shields.io/badge/Alpine_Linux-3.24-0d597f.svg?style=for-the-badge&logo=alpinelinux&logoColor=white)](https://alpinelinux.org/)
[![Docker Compose](https://img.shields.io/badge/Docker_Compose-v2-2496ed.svg?style=for-the-badge&logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![n8n Orchestration](https://img.shields.io/badge/n8n-SOAR_Pipeline-ea4b71.svg?style=for-the-badge&logo=n8n&logoColor=white)](https://n8n.io/)
[![Zero-Trust Verified](https://img.shields.io/badge/Verification-Zero--Trust_Passed-10b981.svg?style=for-the-badge)](https://github.com/rabakuku/Youtube/blob/main/Video-2-Active-Defense-Auto-Quarantine/docs/Lab-Matrix.md)
[![GitHub Repository](https://img.shields.io/badge/GitHub-Repository-181717.svg?style=for-the-badge&logo=github&logoColor=white)](https://github.com/rabakuku/Youtube/tree/main/Video-2-Active-Defense-Auto-Quarantine)

> **Autonomous Edge Threat Containment:** A high-speed, closed-loop Security Orchestration, Automation, and Response (SOAR) pipeline where **FortiGate VM** detects perimeter reconnaissance and L4 attacks, dispatches a real-time webhook to an on-premises **Alpine Linux + n8n** container stack, and executes authenticated REST API callbacks to dynamically blackhole attacking IPs in **under 150 milliseconds**.

---

## 📑 Repository Navigation & Documentation Hub

Explore the individual modular project stages and architectural documentation:

| Stage / Component | Document Path | Operational Focus |
| :--- | :--- | :--- |
| **Lab Architecture** | [📘 `docs/Lab-Matrix.md`](https://github.com/rabakuku/Youtube/blob/main/Video-2-Active-Defense-Auto-Quarantine/docs/Lab-Matrix.md) | Topology mapping, variable declarations, protocol schema, and event flow |
| **Container Host** | [🐧 `docs/install-docker.md`](https://github.com/rabakuku/Youtube/blob/main/Video-2-Active-Defense-Auto-Quarantine/docs/install-docker.md) | Hardened Alpine Linux 3.24 base configuration, OpenRC, and Docker Compose v2 |
| **Compose Stack** | [🐳 `compose/docker-compose.yml`](https://github.com/rabakuku/Youtube/blob/main/Video-2-Active-Defense-Auto-Quarantine/compose/docker-compose.yml) & [🔐 `compose/.env.example`](https://github.com/rabakuku/Youtube/blob/main/Video-2-Active-Defense-Auto-Quarantine/compose/.env.example) | Production n8n automation worker linked to PostgreSQL 16 backend on port 80 |
| **Workflow Engine** | [⚡ `docs/Configuration.md`](https://github.com/rabakuku/Youtube/blob/main/Video-2-Active-Defense-Auto-Quarantine/docs/Configuration.md) | Ingestion webhook endpoint, IP sanitization, CIDR whitelist, and JSON workflow |
| **Security Fabric** | [🛡️ `docs/Fortinet.md`](https://github.com/rabakuku/Youtube/blob/main/Video-2-Active-Defense-Auto-Quarantine/docs/Fortinet.md) | FortiOS REST API admin, DoS sensors, dynamic address groups, and automation stitches |
| **Master Technical Runbook** | [📖 `docs/main.md`](https://github.com/rabakuku/Youtube/blob/main/Video-2-Active-Defense-Auto-Quarantine/docs/main.md) | Comprehensive, unpruned consolidated manual covering the entire deployment |
| **Automated Deployment** | [🚀 `scripts/setup.sh`](https://github.com/rabakuku/Youtube/blob/main/Video-2-Active-Defense-Auto-Quarantine/scripts/setup.sh) | Idempotent shell installer verifying Docker, generating keys, and bootstrapping services |
| **Rollback & Teardown** | [🧹 `scripts/rollback.sh`](https://github.com/rabakuku/Youtube/blob/main/Video-2-Active-Defense-Auto-Quarantine/scripts/rollback.sh) | Clean one-command teardown script purging containers, networks, and volumes |
| **Interactive Presentation** | [📽️ `presentation/PowerPoint.html`](https://github.com/rabakuku/Youtube/blob/main/Video-2-Active-Defense-Auto-Quarantine/presentation/PowerPoint.html) | Offline-ready, zero-dependency cybersecurity slide deck with inline vector engines |
| **Spoken Teleprompter** | [🎙️ `presentation/Teleprompter.md`](https://github.com/rabakuku/Youtube/blob/main/Video-2-Active-Defense-Auto-Quarantine/presentation/Teleprompter.md) | Synchronized 3–4 sentence voiceover teleprompter script for video recording |
| **YouTube Packaging** | [📈 `marketing/YouTube-Marketing.md`](https://github.com/rabakuku/Youtube/blob/main/Video-2-Active-Defense-Auto-Quarantine/marketing/YouTube-Marketing.md) | High-CTR title hooks, SEO description, thumbnail concepts, and search tags |

---

## 🗺️ Architectural Topology & Packet Flow

```text
                                  +---------------------------------------+
                                  |            FortiGate VM               |
                                  |           FGT-CORE-01                 |
                                  |           (FortiOS 7.4)               |
                                  |           192.168.10.1                |
                                  +---------------------------------------+
                                       |                             ^
       [1] SYN Flood / Port Sweep      |                             | [4] REST API Dynamic
           Adversary Ingress Probe     |                             |     Address Injection
           (TCP SYN to port2)          |                             |     (POST /address)
                                       v                             |     (PUT /addrgrp)
+--------------------------------+     | [2] Automation Stitch       |
|          Kali Linux            |     |     Webhook Trigger         |
|        Attacker Node           |     |     (HTTP POST :80)         |
|         192.168.10.3           |     v                             |
+--------------------------------+    +-----------------------------------+
       |                              |        Alpine Linux 3.24          |
       |                              |         (Docker Host)             |
       +----------------------------> |          192.168.10.2             |
       [5] Connection Terminated /    |  +-----------------------------+  |
           Hardware-Level Drop via    |  |  n8n SOAR Orchestrator Core |  |
           POLICY_ACTIVE_QUARANTINE   |  |  PostgreSQL 16 Storage      |  |
                                      |  +-----------------------------+  |
                                      +-----------------------------------+
```

---

## 🎯 Dynamic Addressing & Role Matrix

The entire lab architecture operates strictly inside the `192.168.10.0/24` subnet boundary:

| Node Identifier | Hostname / Role | IP Address | Subnet Mask | Physical/Virtual NIC | Purpose |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Node 1** | `FGT-CORE-01` | `192.168.10.1` | `255.255.255.0` | `port2` | Default Gateway, Anomaly Sensor, REST API Server |
| **Node 2** | `alpine-soar-node` | `192.168.10.2` | `255.255.255.0` | `eth0` | Docker Host running containerized n8n and PostgreSQL |
| **Node 3** | `kali-attacker-01` | `192.168.10.3` | `255.255.255.0` | `eth0` | Attacking Node generating aggressive SYN probes |

---

## ⚙️ How the Autonomous Feedback Loop Operates

1. **Adversary Probing (`192.168.10.3`):**  
   The Kali node runs high-frequency TCP SYN scans or flood attempts against the FortiGate gateway (`192.168.10.1`).
2. **Perimeter Detection:**  
   FortiOS DoS policy (`DOS_DETECT_SYN_SWEEP`) intercepts the anomalous rate, generating event log ID `0100022001`.
3. **Stitch Activation:**  
   An automated FortiOS Stitch catches the event log and dispatches an HTTP POST payload containing `%%log.srcip%%` to `http://192.168.10.2:80/webhook/quarantine`.
4. **SOAR Logic & Whitelist Validation:**  
   The containerized n8n engine extracts `192.168.10.3`, runs it against internal whitelist filters (`192.168.10.1`, `192.168.10.2`, `127.0.0.1`), and prepares the FortiOS CMDB payloads.
5. **REST API Callback:**  
   n8n triggers two authenticated HTTPS calls against `https://192.168.10.1:443`:
   - `POST /api/v2/cmdb/firewall/address` creates `QUAR_192.168.10.3`.
   - `PUT /api/v2/cmdb/firewall/addrgrp/GRP_ACTIVE_QUARANTINE` appends the object into the group.
6. **Instant Enforcement:**  
   Top-priority firewall policy `POLICY_ACTIVE_QUARANTINE_DROP` instantly matches the attacker address group, drops all active sessions, and blackholes subsequent packets at the kernel level.

---

## 🚀 Rapid Automated Deployment

### Step 1: Initialize Workspace on the Alpine Host (`192.168.10.2`)
Log into your Alpine Linux host as `root` and retrieve the automated scripts:

```sh
apk add curl
mkdir -p /opt/Active-Defense-Auto-Quarantine && cd /opt/Active-Defense-Auto-Quarantine
curl -fsSL https://raw.githubusercontent.com/rabakuku/Youtube/refs/heads/main/Video-2-Active-Defense-Auto-Quarantine/scripts/setup.sh -o setup.sh
curl -fsSL https://raw.githubusercontent.com/rabakuku/Youtube/refs/heads/main/Video-2-Active-Defense-Auto-Quarantine/scripts/rollback.sh -o rollback.sh
chmod +x setup.sh rollback.sh
```

### Step 2: Run Automated Idempotent Setup
Execute the deployment script to prepare permissions, environment variables, and Docker containers:

```sh
./setup.sh
```

*The script verifies Docker Engine prerequisites, auto-generates a 32-character hexadecimal encryption key in `.env`, pulls official container images, maps container port `5678` to host port `80`, and waits for PostgreSQL health convergence.*

---

### Step 3: Apply Complete FortiOS Configuration

Open an SSH or console session to **FortiGate** (`192.168.10.1`) and execute the complete, unpruned configuration script:

```fortios
config system interface
    edit "port2"
        set vdom "root"
        set ip 192.168.10.1 255.255.255.0
        set allowaccess ping https ssh http
        set type physical
        set snmp-index 2
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

### Step 4: Import & Activate SOAR Workflow

1. Open your web browser and navigate to `http://192.168.10.2:80/`.
2. Complete initial user onboarding (`admin@lab.local`).
3. Click **Workflows** -> **Add Workflow** -> Click the three dots `...` (top right) -> **Import from File / Paste JSON**.
4. Copy the complete JSON workflow definition below and paste it directly into the canvas:

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

5. Click **Save** and toggle the switch in the top right to **Active**.

---

## 🧪 Zero-Touch Emulation & Verification

### Step 1: Open Real-Time Packet Sniffer on FortiGate CLI (`192.168.10.1`)
In a dedicated terminal, monitor the outbound webhook triggering from FortiGate to Alpine:

```fortios
diagnose sniffer packet port2 'host 192.168.10.2 and port 80' 4 0 l
```

### Step 2: Launch Adversary Attack from Kali Linux (`192.168.10.3`)
Execute a high-frequency SYN scan matching the FortiOS DoS anomaly threshold:

```bash
hping3 -S --flood -V -p 80 192.168.10.1 --count 500
```

### Step 3: Verify Dynamic Quarantine Entry on FortiGate CLI (`192.168.10.1`)
Inspect the CMDB address database and quarantine group:

```fortios
# Verify dynamic address object creation
get firewall address QUAR_192.168.10.3

# Confirm insertion into the active block group
get firewall addrgrp GRP_ACTIVE_QUARANTINE

# Verify session table drops
diagnose sys session filter daddr 192.168.10.1
diagnose sys session list
```

### Step 4: Verify Attacker Isolation on Kali Linux (`192.168.10.3`)
Confirm complete isolation and kernel-level blackholing:

```bash
ping -c 4 192.168.10.1
```
*Expected Result: 100% packet loss. Zero connection states allowed through the gateway.*

---

## 🧹 Teardown & Clean Rollback

To immediately halt all containers, remove networks, and purge persistent database volumes:

```sh
cd /opt/Active-Defense-Auto-Quarantine
./rollback.sh
```

Or execute directly with Docker Compose:

```sh
cd /opt/Active-Defense-Auto-Quarantine/compose
docker compose down -v --remove-orphans
```

---

## 📄 License & Attribution

Distributed under the **MIT License**. Maintained by the **Fortinet YouTube Architect** channel. Contributions and pull requests are welcomed via the [official GitHub repository](https://github.com/rabakuku/Youtube/tree/main/Video-2-Active-Defense-Auto-Quarantine).
```
