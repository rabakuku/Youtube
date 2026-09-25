<!-- filepath: https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/README.md -->
[![FortiOS](https://img.shields.io/badge/FortiOS-7.4-red.svg)](https://www.fortinet.com/)
[![Alpine Linux](https://img.shields.io/badge/Alpine%20Linux-3.24-0D597F.svg)](https://alpinelinux.org/)
[![Docker](https://img.shields.io/badge/Docker-Cowrie%20Honeypot-2496ED.svg)](https://hub.docker.com/r/cowrie/cowrie)
[![Security Fabric](https://img.shields.io/badge/Security%20Fabric-Automation%20Stitch-10B981.svg)](https://docs.fortinet.com/)

# Active Honeypot Instant Auto-Quarantine Fabric

An enterprise-grade active defense deception network combining containerized Cowrie SSH/Telnet honeypots with the FortiOS Security Fabric. When an attacker breaches the perimeter and attempts brute-force authentication against a decoy service on port `2222`, the honeypot dispatches an authenticated webhook into FortiOS, triggering an automation stitch that quarantines the attacker's source IP at Layer 3 across the entire firewall fabric in under 2 seconds.

---

## Architecture & Topology

```text
+-----------------------+              +-----------------------------------+              +-------------------------+
|     Node 3: Kali      |              |          Node 1: FortiGate        |              |      Node 2: Alpine     |
|    192.168.40.3       |              |  port2.40: .40.1 | port2.10: .10.1 |              |       192.168.10.2      |
+-----------+-----------+              +-----------------+-----------------+              +------------+------------+
            |                                            |                                             |
            | --- [1] TCP/2222 (SSH Connection) -------> |                                             |
            |     SYN to 192.168.40.1:2222               |                                             |
            |                                            | --- [2] DNAT VIP Forward -----------------> |
            |                                            |     TCP/2222 to 192.168.10.2:2222           |
            |                                            |                                             |
            | <== [3] Cowrie Interaction & Handshake ==  |  ========================================== |
            |     Attacker delivers rogue SSH auth       |                                             |
            |                                            |                                             |
            |                                            | <--- [4] HTTPS POST (Webhook Trigger) ----- |
            |                                            |      Payload: {"srcip":"192.168.40.3"}      |
            |                                            |                                             |
            |                                            | --+                                         |
            |                                            |   | [5] Automation Stitch:                  |
            |                                            |   |     Execute Quarantine Action / L3 Ban  |
            |                                            | <-+                                         |
            |                                            |                                             |
            | -X- [6] Subsequent Packets Dropped --------|                                             |
            |     All traffic blocked at L3 ingress      |                                             |
```

### L2/L3 Addressing Schema

* **Node 1a (FortiGate Gateway):** `192.168.10.1/24` (Interface `port2.10`, VLAN 10 Gateway, Webhook Listener `:443`)
* **Node 1b (FortiGate Gateway):** `192.168.40.1/24` (Interface `port2.40`, VLAN 40 Gateway, VIP Listener `:2222`)
* **Node 2 (Alpine Linux 3.24 Host):** `192.168.10.2/24` (Docker Engine, Cowrie Container Bound to Host `:2222`)
* **Node 3 (Kali Linux Attacker):** `192.168.40.3/24` (Client Subnet, Initiating Unauthorized Probes)

For complete network interfaces, firewall zones, and protocol flow definitions, refer to [docs/Lab-Matrix.md](https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/docs/Lab-Matrix.md).

---

## 0. Honeypot Deployment on Alpine Linux

1. Connect to the FortiGate CLI console and configure the access profile and API user:
   ```fortios
   config system accprofile
       edit "PROF_WEBHOOK_QUARANTINE"
           set comments "Access profile for honeypot auto-quarantine automation"
           set secfabgrp read-write
           set sysgrp read-write
           set netgrp read-write
           set loggrp read-write
           set fwgrp read-write
       next
   end

   config system api-user
       edit "api_cowrie_quarantine"
           set accprofile "PROF_WEBHOOK_QUARANTINE"
           set vdom "root"
           config trusthost
               edit 1
                   set ipv4-trusthost 192.168.10.2 255.255.255.255
               next
           end
       next
   end
   ```

2. Generate the API token:
   ```fortios
   execute api-user generate-key api_cowrie_quarantine
   ```
   *Expected Output:*
   ```text
   New API key: 8q9N4k6Y9H3pZ1r... (copy this generated key)
   ```

---

## 1. Honeypot Deployment on Alpine Linux

Deploy the base container stack using the automated deployment utility.

### Deployment Instructions

```sh
# Create lab workspace and navigate into it
mkdir -p /opt/honeypot-quarantine
cd /opt/honeypot-quarantine

# Download the deployment script directly from GitHub
curl -fsSL https://raw.githubusercontent.com/rabakuku/Youtube/main/Active-Honeypot-Instant-Auto-Quarantine/scripts/setup.sh -o setup.sh

# Mark executable and run
chmod +x setup.sh
./setup.sh

# Enter token when prompted
======================================================================
Enter your FortiGate API Token (from 'execute api-user generate-key'):
Token: 8q9N4k6Y9H3pZ1r...
```

### Verification & Testing (Node 2)

Execute host validation steps as defined in [scripts/vt.md](https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/scripts/vt.md):

```sh
# 1. Verify container runtime state
docker ps --filter "name=cowrie-honeypot" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# 2. Inspect active socket listeners on Alpine
ss -tuln | grep -E ':2222'

# 3. Stream live container logs
docker compose -f /opt/honeypot-quarantine/compose/docker-compose.yml logs --tail=20 -f cowrie

# 4. Perform local SSH handshake check
ssh -p 2222 root@127.0.0.1

# 5. Test to make sure the webhook is working
curl -k -v -X POST "https://192.168.10.1:443/api/v2/monitor/system/automation-stitch/webhook/TRIG_COWRIE_QUARANTINE" \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer Qzrqk80zhscqny1NsgNmgm4dcy1zjx" \
     -d '{"srcip":"192.168.40.3","event":"cowrie.login.failed"}'
```

---

## 2. FortiOS Security Fabric & VIP Configuration

To establish the Virtual IPs, firewall policies, incoming webhook automation trigger, and Layer 3 quarantine actions on FortiOS 7.4.12:

* **CLI Step-by-Step Guide:** [docs/Fortinet-cli.md](https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/docs/Fortinet-cli.md)
* **FortiGate Verification & Packet Tracing:** [docs/vt.md](https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/docs/vt.md)

### Key Validation Commands (FortiGate CLI)

```fortios
# View active automation stitches
show system automation-stitch STITCH_COWRIE_AUTO_QUARANTINE

# Inspect the Layer 3 kernel quarantine / banned IP drop table
diagnose user banned-ip list

# Clear banned IP entries during testing
diagnose user banned-ip clear
```

---

## 3. Active Defense Tiers & Lab Orchestration

Manage and test all three tiers of the active defense honeypot pipeline using the unified lab orchestrator:

* **Lab Management Utility:** [scripts/config-lab.sh](https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/scripts/config-lab.sh)
* **Tier A (Basic Instant Quarantine + Dozzle Web GUI):** [docs/config-a.md](https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/docs/config-a.md)
* **Tier B (Stateful Triage & Velocity Rate Limiting):** [docs/config-b.md](https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/docs/config-b.md)
* **Tier C (Mattermost ChatOps & TTY Forensics Archive):** [docs/config-c.md](https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/docs/config-c.md)

### Lab Orchestrator Quick Start

```sh
cd /opt/honeypot-quarantine/scripts
curl -fsSL https://raw.githubusercontent.com/rabakuku/Youtube/main/Active-Honeypot-Instant-Auto-Quarantine/scripts/config-lab.sh -o config-lab.sh
chmod +x config-lab.sh

# Deploy Config-A, Config-B, or Config-C
./config-lab.sh setup config-a
./config-lab.sh setup config-b
./config-lab.sh setup config-c

# Check active profile, open ports, and running OpenRC daemons
./config-lab.sh status
```

---

## 4. Teardown & Environment Rollback

To decommission containers, clean storage volumes, or reset the environment, consult [scripts/rollback.sh](https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/scripts/rollback.sh):

```sh
cd /opt/honeypot-quarantine
curl -fsSL https://raw.githubusercontent.com/rabakuku/Youtube/main/Active-Honeypot-Instant-Auto-Quarantine/scripts/rollback.sh -o rollback.sh
chmod +x rollback.sh
./rollback.sh
```
