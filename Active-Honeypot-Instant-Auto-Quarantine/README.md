
[![FortiOS](https://img.shields.io/badge/FortiOS-7.4-red.svg)](https://www.fortinet.com/)
[![Alpine Linux](https://img.shields.io/badge/Alpine%20Linux-3.24-0D597F.svg)](https://alpinelinux.org/)
[![Docker](https://img.shields.io/badge/Docker-Cowrie%20Honeypot-2496ED.svg)](https://hub.docker.com/r/cowrie/cowrie)
[![Security Fabric](https://img.shields.io/badge/Security%20Fabric-Automation%20Stitch-10B981.svg)](https://docs.fortinet.com/)
```markdown
# Active Honeypot Instant Auto-Quarantine Fabric


An enterprise-grade active defense deception network combining containerized Cowrie SSH/Telnet honeypots with the FortiOS Security Fabric. When an attacker breaches the perimeter and attempts brute-force authentication against a decoy service on port `2222`, the honeypot dispatches an authenticated webhook into FortiOS, triggering an automation stitch that quarantines the attacker's source IP at Layer 3 across the entire firewall fabric in under 2 seconds.

---

## Architecture & Topology

```text
+-----------------------+              +-----------------------------------+              +-------------------------+
|     Node 3: Kali      |              |          Node 1: FortiGate        |              |     Node 2: Alpine      |
|    192.168.40.3       |              |  port2.40: .40.1 | port2.10: .10.1 |              |      192.168.10.2       |
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

* **Node 1a (FortiGate VM):** `192.168.10.1/24` (Interface `port2.10`, VLAN 10 Gateway, Webhook Listener `:443`)
* **Node 1b (FortiGate VM):** `192.168.40.1/24` (Interface `port2.40`, VLAN 40 Gateway, VIP Listener `:2222`)
* **Node 2 (Alpine Linux 3.24 Host):** `192.168.10.2/24` (Docker Engine, Cowrie Container Bound to Host `:2222`)
* **Node 3 (Kali Linux Attacker):** `192.168.40.3/24` (Client subnet, initiating unauthorized SSH probes)

For the detailed matrix, consult [docs/Lab-Matrix.md](https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/docs/Lab-Matrix.md).

---

## 1. Honeypot Deployment on Alpine Linux

Deploy the container stack using the automated deployment utility.

### Deployment Instructions

```sh
# Create lab workspace and navigate into it
mkdir -p /opt/honeypot-quarantine
cd /opt/honeypot-quarantine

# Download the deployment script directly from GitHub
curl -fsSL [https://raw.githubusercontent.com/rabakuku/Youtube/main/Active-Honeypot-Instant-Auto-Quarantine/scripts/setup.sh](https://raw.githubusercontent.com/rabakuku/Youtube/main/Active-Honeypot-Instant-Auto-Quarantine/scripts/setup.sh) -o setup.sh

# Mark executable and run
chmod +x setup.sh
./setup.sh

```

### Verification & Testing (Node 2)

Follow the verification guide in [scripts/vt.md](https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/scripts/vt.md):

```sh
# 1. Verify container runtime state
docker ps --filter "name=cowrie-honeypot" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# 2. Inspect active socket listeners on Alpine
ss -tuln | grep -E ':2222'

# 3. Stream live container logs
docker compose -f /opt/honeypot-quarantine/compose/docker-compose.yml logs --tail=20 -f cowrie

# 4. Perform local SSH handshake check
ssh -p 2222 root@127.0.0.1

```

---

## 2. FortiOS Security Fabric & VIP Configuration

Configure FortiGate with the Virtual IP (VIP), firewall access policy, incoming webhook automation trigger, and quarantine action.

### CLI Deployment Summary

Apply the configuration from [docs/Fortinet-cli.md](https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/docs/Fortinet-cli.md) on the FortiGate console:

```fortios
config firewall vip
    edit "VIP_COWRIE_HONEYPOT_2222"
        set extip 192.168.40.1
        set mappedip "192.168.10.2"
        set extintf "port2.40"
        set portforward enable
        set protocol tcp
        set extport 2222
        set mappedport 2222
    next
end

config firewall policy
    edit 10
        set name "INBOUND_HONEYPOT_DECEPTION"
        set srcintf "port2.40"
        set dstintf "port2.10"
        set action accept
        set srcaddr "all"
        set dstaddr "VIP_COWRIE_HONEYPOT_2222"
        set schedule "always"
        set service "ALL"
        set logtraffic all
    next
end

config system automation-trigger
    edit "TRIG_COWRIE_QUARANTINE"
        set event-type webhook
    next
end

config system automation-action
    edit "ACT_QUARANTINE_ATTACKER_IP"
        set action-type quarantine
        set quarantine-log enable
    next
end

config system automation-stitch
    edit "STITCH_COWRIE_AUTO_QUARANTINE"
        set status enable
        set trigger "TRIG_COWRIE_QUARANTINE"
        config actions
            edit 1
                set action "ACT_QUARANTINE_ATTACKER_IP"
                set required enable
            next
        end
    next
end

```

For full GUI setup instructions, reference [docs/Fortinet-gui.md](https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/docs/Fortinet-gui.md).

### Verification & Diagnostics (Node 1)

Execute zero-trust checks on the FortiGate CLI per [docs/vt.md](https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/docs/vt.md):

```fortios
# Validate VIP state and policy attachment
get firewall vip VIP_COWRIE_HONEYPOT_2222
show firewall policy 10

# Trace packets flowing from Kali through the VIP to the honeypot
diagnose sniffer packet any 'host 192.168.40.3 and port 2222' 4 0 l

# Verify active session tracking
diagnose sys session filter clear
diagnose sys session filter dport 2222
diagnose sys session list

# Test automation stitch execution
diagnose automation stitch test STITCH_COWRIE_AUTO_QUARANTINE

# Inspect Layer 3 quarantine drop list
diagnose user quarantine list

# Clear IP from quarantine after testing
diagnose user quarantine delete 192.168.40.3

```

---

## 3. Application & Triage Architecture

The lab supports multi-tiered event processing defined in [app/app.json](https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/app/app.json):

* **[Basic Setup (Tier A)](https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/docs/config-a.md):** Continuous tail of `cowrie.json` on Alpine Linux with instantaneous curl dispatch to FortiOS incoming webhook upon any failed authentication.
* **[Medium Setup (Tier B)](https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/docs/config-b.md):** In-memory sliding window rate-limiting (3 failed attempts within 30 seconds) and immediate ban for high-risk targets (`root`, `admin`, `support`, `cisco`, `ubnt`).
* **[Advanced Setup (Tier C)](https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/docs/config-c.md):** Full Security Fabric integration with asynchronous Syslog alerts, Mattermost/Slack ChatOps notification cards, and TTY forensic session recording extraction.

---

## Teardown & Environment Rollback

To decommission the honeypot or reset the environment, run the rollback script:

```sh
cd /opt/honeypot-quarantine
curl -fsSL https://raw.githubusercontent.com/rabakuku/Youtube/main/Active-Honeypot-Instant-Auto-Quarantine/scripts/rollback.sh -o rollback.sh
chmod +x rollback.sh
./rollback.sh

```

```

---

### Zero-Trust Verification Steps (Execute in Chat Before Transition)

Before confirming completion of Stage 6, run the following verification checks against the master documentation hub:

1. **Verify Raw Setup Script Accessibility:**
   ```sh
   curl -I -s https://raw.githubusercontent.com/rabakuku/Youtube/main/Active-Honeypot-Instant-Auto-Quarantine/scripts/setup.sh | head -n 5

```

*Expected Output:* HTTP status line showing `200 OK` or valid repository availability.

2. **Verify Target Policy Show Output (FortiOS CLI):**
```fortios
show firewall policy 10
get system automation-stitch STITCH_COWRIE_AUTO_QUARANTINE

```


*Expected Output:* Policy 10 and Automation Stitch configurations are output cleanly with status `enable`.
3. **Verify Host Port Socket Readiness (Alpine CLI):**
```sh
ss -tuln | grep -E ':2222'

```


*Expected Output:* Active TCP listener bound on port `2222`.

Inspect these validation checks. Once complete, provide the gatekeeper exit trigger:
`"I am done with Stage 6"`
