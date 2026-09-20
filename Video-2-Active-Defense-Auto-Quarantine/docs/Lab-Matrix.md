<!-- filepath: docs/Lab-Matrix.md -->
# Active-Defense-Auto-Quarantine: Lab Architecture & Matrix

## 1. Architectural Overview

The Active-Defense-Auto-Quarantine architecture establishes an automated Security Orchestration, Automation, and Response (SOAR) feedback loop operating directly at the network edge. 

When an adversary initiates anomalous traffic (such as high-rate TCP SYN sweeps or unauthorized administrative probing) against the perimeter firewall, FortiOS detects the anomaly via its security engines (DoS policy, IPS sensor, or local-in rate limiters). Instead of relying exclusively on passive syslog ingestion or delayed manual review, FortiOS immediately fires a native Automation Stitch.

This stitch dispatches an outbound HTTP POST webhook containing the event payload to an orchestration engine running inside Docker on an Alpine Linux host. The containerized n8n service parses the attacker's metadata, isolates the offending IPv4 address, and initiates an authenticated REST API call back to FortiOS over TLS (port 443). FortiOS consumes this API payload by dynamically appending the hostile IP to a quarantine address group bound to an active blackhole firewall policy, terminating active connections and blocking subsequent ingress at the silicon or kernel level.

---

## 2. Dynamic Addressing & Node Role Matrix

| Node | Hostname / Role | Subnet & IP Assignment | MAC Address Assignment | Primary Interface | Operational Purpose |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Node 1** | `FGT-CORE-01` | `192.168.10.1/24` | Static / `00:09:0F:09:00:01` | `port2` (Internal LAN) | Gateway, inspection engine, automation stitch trigger, REST API server |
| **Node 2** | `alpine-soar-node` | `192.168.10.2/24` | Dynamic / VM-assigned | `eth0` | Alpine Linux 3.24 host running Docker Engine and n8n SOAR worker |
| **Node 3** | `kali-attacker-01` | `192.168.10.3/24` | Dynamic / VM-assigned | `eth0` | Attacker node launching SYN scans, port probes, and adversary emulation |

---

## 3. Global Parameter & Variable Declarations

| Variable Name | Lab Default Value | Target Scope | Description |
| :--- | :--- | :--- | :--- |
| `LAB_SUBNET` | `192.168.10.0/24` | Global Network | Common broadcast domain and security trust boundary |
| `FGT_IP` | `192.168.10.1` | FortiGate | FortiGate `port2` gateway address |
| `ALPINE_IP` | `192.168.10.2` | Alpine Host | Docker engine host running orchestration stack |
| `KALI_IP` | `192.168.10.3` | Attacker Host | IP address of attacking workstation |
| `N8N_HOST_PORT` | `80` | Alpine Docker Host | Host listening port bound to n8n webhook listener |
| `FGT_REST_PORT` | `443` | FortiGate Management | HTTPS listener for FortiOS REST API calls |
| `FGT_API_TOKEN` | `autoquarantine-sec-token-xyz123` | FortiOS & n8n | Bearer token for REST API administrative access |
| `QUARANTINE_GROUP`| `GRP_ACTIVE_QUARANTINE` | FortiOS Firewall Object | Dynamic address group referenced in quarantine drop policy |
| `TRIGGER_LOG_ID` | `0100022001` | FortiOS Stitch | Event log ID corresponding to DoS/Anomaly detection |

---

## 4. Communication Matrix & Protocol Schema

| Flow Step | Source Node & IP | Destination Node & IP | Protocol & Port | Payload / Action Content |
| :--- | :--- | :--- | :--- | :--- |
| **Step 1: Probe** | Kali (`192.168.10.3`) | FortiGate (`192.168.10.1`) | TCP / Multi-Port | Adversary SYN flood / aggressive nmap port sweep against FortiGate |
| **Step 2: Detect** | FortiGate (`192.168.10.1`) | Internal (Kernel Engine) | Internal Event | Log generation (`logid=0100022001`, `srcip=192.168.10.3`, `action=detected`) |
| **Step 3: Webhook** | FortiGate (`192.168.10.1`) | Alpine (`192.168.10.2`) | HTTP / TCP 80 | Outbound JSON webhook POST to `http://192.168.10.2:80/webhook/quarantine` |
| **Step 4: Orchestrate** | Alpine (`192.168.10.2`) | Local Container | Internal IPC | n8n workflow extracts source IP `192.168.10.3` and formats FortiOS JSON API payload |
| **Step 5: Strike Back** | Alpine (`192.168.10.2`) | FortiGate (`192.168.10.1`) | HTTPS / TCP 443 | Authenticated REST API POST: `/api/v2/cmdb/firewall/address` and group assignment |
| **Step 6: Drop** | FortiGate (`192.168.10.1`) | Kali (`192.168.10.3`) | L3/L4 Drop | FortiGate updates session table, tears down states, and drops future packets |

---

## 5. End-to-End Event Sequence

1. **Adversary Traffic Generation:**  
   Node 3 (`192.168.10.3`) executes an aggressive TCP SYN sweep targeting the interface IP of Node 1 (`192.168.10.1`).
2. **State Detection & Logging:**  
   The FortiOS security engine matches the anomaly against the preconfigured local-in policy or DoS threshold and generates an anomaly alert log.
3. **Stitch Trigger Activation:**  
   The FortiOS Automation Stitch engine catches the specific log ID event matching the anomaly rule.
4. **Outbound Notification Dispatch:**  
   FortiOS executes an Automation Action configured as an HTTP Webhook, delivering an unauthenticated or token-authenticated POST body containing JSON metadata (including `%%log.srcip%%`) to Node 2 (`http://192.168.10.2:80/webhook/quarantine`).
5. **Orchestrator Parsing & Decisioning:**  
   The n8n container on Node 2 ingests the JSON payload via its Webhook Trigger node, parses `192.168.10.3`, validates that it is not on the protected CIDR/whitelisted subnets, and creates an API request object.
6. **Programmatic Remediative Call:**  
   n8n executes an HTTPS POST request directed at `https://192.168.10.1:443/api/v2/cmdb/firewall/address` utilizing the bearer token, establishing a new host address object `QUAR_192.168.10.3`.
7. **Policy Membership Injection:**  
   n8n executes a follow-up API call appending `QUAR_192.168.10.3` into address group `GRP_ACTIVE_QUARANTINE`.
8. **Automated Enforcement:**  
   A top-priority FortiOS firewall deny policy referencing `GRP_ACTIVE_QUARANTINE` takes immediate effect. Active connection sessions for `192.168.10.3` are terminated via session flush, and any further packets from Kali are dropped.
