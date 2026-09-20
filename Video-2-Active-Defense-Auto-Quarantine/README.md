
[![FortiOS](https://img.shields.io/badge/FortiOS-7.4.x-ee2737.svg?style=for-the-badge&logo=fortinet&logoColor=white)](https://www.fortinet.com/)
[![Alpine Linux](https://img.shields.io/badge/Alpine_Linux-3.24-0d597f.svg?style=for-the-badge&logo=alpinelinux&logoColor=white)](https://alpinelinux.org/)
[![Docker Compose](https://img.shields.io/badge/Docker_Compose-v2-2496ed.svg?style=for-the-badge&logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![n8n Orchestration](https://img.shields.io/badge/n8n-SOAR_Pipeline-ea4b71.svg?style=for-the-badge&logo=n8n&logoColor=white)](https://n8n.io/)
[![Zero-Trust Verified](https://img.shields.io/badge/Verification-Zero--Trust_Passed-10b981.svg?style=for-the-badge)](docs/Lab-Matrix.md#zero-trust-verification-blocker-stage-1)
[![GitHub Repository](https://img.shields.io/badge/GitHub-Repository-181717.svg?style=for-the-badge&logo=github&logoColor=white)](https://github.com/rabakuku/Youtube/tree/main/Video-2-Active-Defense-Auto-Quarantine)

```markdown
<!-- filepath: README.md -->
# 🛡️ Active-Defense-Auto-Quarantine


> **Autonomous Edge Threat Containment:** A high-speed, closed-loop Security Orchestration, Automation, and Response (SOAR) pipeline where **FortiGate VM** detects perimeter reconnaissance and L4 attacks, dispatches a real-time webhook to an on-premises **Alpine Linux + n8n** container stack, and executes authenticated REST API callbacks to dynamically blackhole attacking IPs in **under 150 milliseconds**.

---

## 📑 Repository Navigation & Documentation Hub

Explore the individual modular project stages and architectural documentation:

| Stage / Component | Document Path | Operational Focus |
| :--- | :--- | :--- |
| **Lab Architecture** | [📘 `docs/Lab-Matrix.md`](docs/Lab-Matrix.md) | Topology mapping, variable declarations, protocol schema, and event flow |
| **Container Host** | [🐧 `docs/install-docker.md`](docs/install-docker.md) | Hardened Alpine Linux 3.24 base configuration, OpenRC, and Docker Compose v2 |
| **Compose Stack** | [🐳 `compose/docker-compose.yml`](compose/docker-compose.yml) & [🔐 `compose/.env.example`](compose/.env.example) | Production n8n automation worker linked to PostgreSQL 16 backend on port 80 |
| **Workflow Engine** | [⚡ `docs/Configuration.md`](docs/Configuration.md) | Ingestion webhook endpoint, IP sanitization, CIDR whitelist, and JSON workflow |
| **Security Fabric** | [🛡️ `docs/Fortinet.md`](docs/Fortinet.md) | FortiOS REST API admin, DoS sensors, dynamic address groups, and automation stitches |
| **Master Technical Runbook** | [📖 `docs/main.md`](docs/main.md) | Comprehensive, unpruned consolidated manual covering the entire deployment |
| **Automated Deployment** | [🚀 `scripts/setup.sh`](scripts/setup.sh) | Idempotent shell installer verifying Docker, generating keys, and bootstrapping services |
| **Rollback & Teardown** | [🧹 `scripts/rollback.sh`](scripts/rollback.sh) | Clean one-command teardown script purging containers, networks, and volumes |
| **Interactive Presentation** | [📽️ `presentation/PowerPoint.html`](presentation/PowerPoint.html) | Offline-ready, zero-dependency cybersecurity slide deck with inline vector engines |
| **Spoken Teleprompter** | [🎙️ `presentation/Teleprompter.md`](presentation/Teleprompter.md) | Synchronized 3–4 sentence voiceover teleprompter script for video recording |
| **YouTube Packaging** | [📈 `marketing/YouTube-Marketing.md`](marketing/YouTube-Marketing.md) | High-CTR title hooks, SEO description, thumbnail concepts, and search tags |

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

The lab network operates strictly inside the `192.168.10.0/24` subnet boundary:

| Node Identifier | Hostname / Role | IP Address | Subnet Mask | Physical/Virtual NIC | Purpose |
| --- | --- | --- | --- | --- | --- |
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
4. **SOAR Logic & Sanitation:**
The containerized n8n engine extracts `192.168.10.3`, runs it against internal whitelist filters (`192.168.10.1`, `192.168.10.2`, `127.0.0.1`), and prepares the FortiOS CMDB payloads.
5. **REST API Callback:**
n8n triggers two authenticated HTTPS calls against `https://192.168.10.1:443`:
* `POST /api/v2/cmdb/firewall/address` creates `QUAR_192.168.10.3`.
* `PUT /api/v2/cmdb/firewall/addrgrp/GRP_ACTIVE_QUARANTINE` appends the object into the group.


6. **Instant Enforcement:**
Top-priority firewall policy `POLICY_ACTIVE_QUARANTINE_DROP` instantly matches the attacker address group, drops all active sessions, and blackholes subsequent packets at the kernel level.

---

## 🚀 Rapid Automated Deployment

### Step 1: Log into your Alpine Linux host (`192.168.10.2`) as `root`.
### Step 1.1: Create a dedicated workspace and retrieve the automation scripts:

```sh
mkdir -p /opt/Active-Defense-Auto-Quarantine && cd /opt/Active-Defense-Auto-Quarantine
curl -fsSL https://raw.githubusercontent.com/rabakuku/Youtube/refs/heads/main/Video-2-Active-Defense-Auto-Quarantine/scripts/setup.sh -o setup.sh
curl -fsSL https://raw.githubusercontent.com/rabakuku/Youtube/refs/heads/main/Video-2-Active-Defense-Auto-Quarantine/scripts/rollback.sh -o rollback.sh
chmod +x setup.sh rollback.sh

```

### Step 2: Run Automated Idempotent Setup

```sh
chmod +x scripts/setup.sh scripts/rollback.sh
./scripts/setup.sh

```

*The script checks Docker Engine prerequisites, auto-generates a 32-character hexadecimal encryption key in `.env`, pulls official container images, and starts the stack.*

### Step 3: Apply FortiOS Configuration

Open the SSH CLI on FortiGate (`192.168.10.1`) and paste the configuration block from [docs/Fortinet.md](https://github.com/rabakuku/Youtube/blob/main/Video-2-Active-Defense-Auto-Quarantine/docs/Fortinet.md):

```fortios
config system accprofile
    edit "prof_soar_automation"
        set firewallgrp read-write
        set netgrp read
        set loggrp read
        set sysgrp read
    next
end
# (Refer to docs/Fortinet.md for the complete script)

```

### Step 4: Import SOAR Workflow

1. Navigate to `http://192.168.10.2:80/` in your browser.
2. Complete user registration and create an empty workflow.
3. Import the JSON definition from [docs/Configuration.md](https://github.com/rabakuku/Youtube/blob/main/Video-2-Active-Defense-Auto-Quarantine/docs/Configuration.md).
4. Toggle the workflow to **Active**.

---

## 🧪 Zero-Touch Emulation & Verification

Launch the attack from **Kali Linux** (`192.168.10.3`):

```bash
hping3 -S --flood -V -p 80 192.168.10.1 --count 500

```

### 1. Monitor Outbound Webhook Packets (FortiGate CLI)

```fortios
diagnose sniffer packet port2 'host 192.168.10.2 and port 80' 4 0 l

```

### 2. Verify Dynamic Quarantine Group (FortiGate CLI)

```fortios
get firewall address QUAR_192.168.10.3
get firewall addrgrp GRP_ACTIVE_QUARANTINE

```

### 3. Verify Active Connection Termination (Kali CLI)

```bash
ping -c 4 192.168.10.1

```

*Expected Result:* 100% packet loss. Kali is isolated from the gateway interface.

---

## 🧹 Teardown & Clean Rollback

To immediately dismantle all lab services, purge persistent database volumes, and release port 80:

```sh
cd ~/Youtube/Video-2-Active-Defense-Auto-Quarantine
./scripts/rollback.sh

```

Or execute directly via Docker Compose:

```sh
cd compose
docker compose down -v --remove-orphans

```

---

## 📄 License & Attribution

Distributed under the **MIT License**. Maintained by the **Fortinet YouTube Architect** channel. Contributions and pull requests are welcomed via the [official GitHub repository](https://github.com/rabakuku/Youtube/tree/main/Video-2-Active-Defense-Auto-Quarantine).

```

---

### Verification & Transition

The updated `README.md` has been enriched with:
- Direct relative markdown links to every document in `docs/`, `compose/`, `presentation/`, `marketing/`, and `scripts/`.
- Badges and direct link to your GitHub repository: `[https://github.com/rabakuku/Youtube/tree/main/Video-2-Active-Defense-Auto-Quarantine](https://github.com/rabakuku/Youtube/tree/main/Video-2-Active-Defense-Auto-Quarantine)`.
- Visual ASCII topology, role matrix, and step-by-step SOAR feedback loop.
- One-command quickstart deployment and complete teardown instructions.


```
