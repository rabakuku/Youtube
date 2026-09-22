<!-- filepath: docs/Lab-Matrix.md -->
# Lab Architecture Matrix: Zero-Cost Visual SOC SIEM

## 1. Architectural Overview
This environment simulates a real-time Security Operations Center (SOC) dashboard. A Kali Linux attacker node generates malicious web traffic and vulnerability exploits across a segmented network. The FortiGate NGFW intercepts, blocks, and logs this activity, streaming raw syslog events in real-time to a containerized Vector, Loki, and Grafana stack hosted on Alpine Linux.

## 2. Node Addressing & Role Matrix
| Node | Role | OS / Service | IP Address (Subnet/VLAN) | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| **Node 1** | Perimeter Gateway | FortiGate VM (FortiOS 7.4) | `192.168.10.1/24` (VLAN 10)<br>`192.168.40.1/24` (VLAN 40) | Intercepts attacks, generates security event logs, and forwards syslogs. Both VLANs terminate on `port2`. |
| **Node 2** | SIEM / Docker Host | Alpine Linux 3.24 | `192.168.10.2/24` (VLAN 10) | Hosts the Docker daemon running Vector, Loki, and Grafana. |
| **Node 3** | Traffic Generator | Kali Linux | `192.168.40.3/24` (VLAN 40) | Executes web traffic, directory traversals, and exploit payloads against the network. |

## 3. Communication Schema & Protocol Flow
1. **Traffic Generation:** Kali Linux (`192.168.40.3`) sends HTTP/HTTPS attack traffic over VLAN 40 to target destinations.
2. **Inspection & Logging:** FortiGate (`192.168.40.1` / `192.168.10.1`) analyzes the traffic, applies security profiles, and generates FortiOS syslogs.
3. **Log Streaming (UDP 514):** FortiGate forwards real-time syslog data over VLAN 10 to Vector (`192.168.10.2:514`).
4. **Parsing & Indexing (TCP 3100):** Vector parses the FortiOS key-value pairs, enriches the data (GeoIP mapping), and pushes it to Loki (`192.168.10.2:3100`).
5. **Visualization (TCP 80):** Grafana (`192.168.10.2:80`) queries Loki via LogQL to render the live NOC/SOC visual wallboards. Kali Linux (or another network client) connects to port 80 to view the dashboard.
