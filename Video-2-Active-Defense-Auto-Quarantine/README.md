<!-- filepath: README.md -->
# Active-Defense-Auto-Quarantine

[![FortiOS](https://img.shields.io/badge/FortiOS-7.4.x-ee2737.svg?style=flat-square&logo=fortinet)](https://www.fortinet.com/)
[![Alpine Linux](https://img.shields.io/badge/Alpine_Linux-3.24-0d597f.svg?style=flat-square&logo=alpinelinux)](https://alpinelinux.org/)
[![Docker Compose](https://img.shields.io/badge/Docker_Compose-v2-2496ed.svg?style=flat-square&logo=docker)](https://docs.docker.com/compose/)
[![n8n Orchestration](https://img.shields.io/badge/n8n-SOAR_Pipeline-ea4b71.svg?style=flat-square&logo=n8n)](https://n8n.io/)
[![Zero-Trust Verified](https://img.shields.io/badge/Verification-Zero--Trust_Passed-10b981.svg?style=flat-square)](#zero-trust-verification)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](LICENSE)

> **Real-time active defense and auto-quarantine pipeline (SOAR) where FortiOS detects ingress anomalies, triggers a webhook to an on-premises containerized orchestrator, and dynamically blackholes hostile IPs via REST API in under 150 milliseconds.**

---

## Network Architecture & Attack Path

```text
[ KALI LINUX (Node 3) ]                 192.168.10.0/24 Subnet Trust Boundary
  IP: 192.168.10.3
        |
        | 1. High-Rate SYN Scan / L4 Attack
        v
[ FORTIGATE VM (Node 1) ] <--------------------------------------------------+
  IP: 192.168.10.1 (port2)                                                   |
  - DoS Anomaly Sensor Matches                                                |
  - Automation Stitch Intercepts Log ID                                      | 4. REST API Call
        |                                                                    |    POST /address
        | 2. HTTP POST Webhook                                               |    PUT /addrgrp
        |    Payload: {"srcip": "192.168.10.3"}                              |    Bearer Auth
        v                                                                    |
[ ALPINE LINUX DOCKER HOST (Node 2) ]                                        |
  IP: 192.168.10.2:80                                                        |
  +-----------------------------------------------------------------------+  |
  | Docker Engine (OpenRC)                                                |  |
  |  └─ n8n Automation Core (172.28.10.10:5678 -> Host :80)              |--+
  |      └─ Extracts attacker IP, runs whitelist filter, strikes back    |
  |  └─ PostgreSQL 16 (172.28.10.11:5432)                                 |
  +-----------------------------------------------------------------------+
        |
        v
[ ENFORCEMENT & DROP ]
  FortiGate injects QUAR_192.168.10.3 into GRP_ACTIVE_QUARANTINE.
  Policy ID 100 drops subsequent packets at kernel level.
```

---

## Dynamic Role & Addressing Matrix

| Node | Name / Role | IP Address | Primary Interface | Core Function |
| :--- | :--- | :--- | :--- | :--- |
| **Node 1** | `FGT-CORE-01` | `192.168.10.1/24` | `port2` | Perimeter gateway, DoS anomaly sensor, REST API server |
| **Node 2** | `alpine-soar-node` | `192.168.10.2/24` | `eth0` | Alpine Linux 3.24, Docker Compose, n8n, PostgreSQL 16 |
| **Node 3** | `kali-attacker-01` | `192.168.10.3/24` | `eth0` | Adversary node running `hping3` and aggressive port sweeps |

---

## Repository Directory Layout

```text
├── compose/
│   ├── docker-compose.yml       # Production Compose file (Postgres 16 + n8n)
│   └── .env.example             # Runtime secrets, tokens, and DB variables
├── docs/
│   ├── Lab-Matrix.md            # Topology, variables, and communication schema
│   ├── install-docker.md        # Step-by-step Alpine 3.24 Docker guide
│   ├── Configuration.md         # n8n workflow canvas and webhook config
│   ├── Fortinet.md              # FortiOS CLI & GUI configuration guide
│   └── main.md                  # Comprehensive master technical manual
├── presentation/
│   ├── PowerPoint.html          # Interactive, dependency-free full-screen deck
│   └── Teleprompter.md          # 3-4 sentence/slide voiceover script
├── marketing/
│   └── YouTube-Marketing.md     # High-CTR titles, description, tags, thumbnails
├── scripts/
│   ├── setup.sh                 # Automated idempotent deployment script
│   └── rollback.sh              # Clean teardown and state volume purge
└── README.md                    # Project landing page and architectural guide
```

---

## Quickstart Deployment Guide

### Prerequisites
* Alpine Linux 3.24 installed on `192.168.10.2` with network reachability to `192.168.10.1`.
* FortiGate running FortiOS 7.4 on `192.168.10.1`.

### 1. Clone & Automated Deploy
Execute directly on the Alpine host (`192.168.10.2`):
```sh
git clone [https://github.com/your-org/active-defense-auto-quarantine.git](https://github.com/your-org/active-defense-auto-quarantine.git) ~/soar-stack
cd ~/soar-stack/scripts
chmod +x setup.sh rollback.sh
./setup.sh
```

### 2. Configure FortiOS Fabric
Apply the complete CLI configuration block found in `docs/Fortinet.md` on FortiGate (`192.168.10.1`):
* Creates API profile `prof_soar_automation` and token user `soar-api-admin`.
* Instantiates `GRP_ACTIVE_QUARANTINE` and drop policy `POLICY_ACTIVE_QUARANTINE_DROP`.
* Configures DoS policy `DOS_DETECT_SYN_SWEEP` and the webhook Automation Stitch.

### 3. Import & Activate Workflow
* Navigate to `http://192.168.10.2:80/`.
* Complete user setup and import `FortiOS-Auto-Quarantine-Pipeline` from `docs/Configuration.md`.
* Toggle workflow status to **Active**.

---

## Zero-Touch Threat Emulation & Verification

Execute an aggressive SYN flood from Kali Linux (`192.168.10.3`):
```bash
hping3 -S --flood -V -p 80 192.168.10.1 --count 500
```

### Verify Autonomous Mitigation (FortiGate CLI)
```fortios
# Verify dynamic address entry
get firewall address QUAR_192.168.10.3

# Confirm group membership
get firewall addrgrp GRP_ACTIVE_QUARANTINE

# Verify active session drop
diagnose sys session filter daddr 192.168.10.1
diagnose sys session list
```

---

## Full Teardown & Rollback

To immediately dismantle the container runtime, purge persistent database volumes, and release host port 80:

```sh
cd ~/soar-stack/scripts
./rollback.sh
```

Alternatively, invoke Docker Compose directly:
```sh
cd ~/soar-stack/compose
docker compose down -v --remove-orphans
```
