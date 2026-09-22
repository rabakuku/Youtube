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
|         192.168.40.3           |     v                             |
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
| **Node 3** | `kali-attacker-01` | `192.168.40.3/24` | VM-assigned | `eth0` | Kali Linux, `hping3`, `nmap`, Security Testing Tools |

---

