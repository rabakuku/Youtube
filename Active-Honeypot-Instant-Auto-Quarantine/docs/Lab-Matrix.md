```markdown
<!-- filepath: https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/docs/Lab-Matrix.md -->
# Lab Architecture & Topology Matrix: Active Honeypot Instant Auto-Quarantine

## 1. Architectural Overview
This deployment establishes an active deception perimeter using a containerized Cowrie SSH/Telnet honeypot running on Alpine Linux 3.24, fronted by a FortiGate VM running FortiOS 7.4. The FortiGate receives connection attempts on port 2222 from an untrusted client/attacker subnet (VLAN 40) and translates/forwards the traffic via Virtual IP (VIP) to the Cowrie honeypot residing in the server zone (VLAN 10). Upon unauthorized access attempts or brute-force logins, Cowrie dispatches a JSON webhook payload to the FortiOS incoming webhook automation endpoint. FortiOS processes the incoming event through an Automation Stitch, extracting the attacker's source IP and committing it to a Layer 3 quarantine address group/ban list across the Security Fabric within seconds.

---

## 2. L2/L3 Addressing Table

| Node Identifier | Hostname / Role | Interface / VLAN | IP Address | Subnet Mask | Default Gateway | Exposed Service / Port |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Node 1a** | FortiGate-VM | `port2.10` (VLAN 10) | `192.168.10.1` | `255.255.255.0` (`/24`) | N/A | Gateway / Automation Webhook (:443) |
| **Node 1b** | FortiGate-VM | `port2.40` (VLAN 40) | `192.168.40.1` | `255.255.255.0` (`/24`) | N/A | Gateway / VIP Listener (:2222) |
| **Node 2** | `alpine-docker` | `eth0` (VLAN 10) | `192.168.10.2` | `255.255.255.0` (`/24`) | `192.168.10.1` | Cowrie Deception Stack (:2222) |
| **Node 3** | `kali-attacker` | `eth0` (VLAN 40) | `192.168.40.3` | `255.255.255.0` (`/24`) | `192.168.40.1` | SSH Brute Force Client (Outbound) |

---

## 3. Global Variable Declarations

```text
GITHUB_URL="[https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine](https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine)"
VLAN_SERVERS_ID="10"
VLAN_USERS_ID="40"
SUBNET_SERVERS="192.168.10.0/24"
SUBNET_USERS="192.168.40.0/24"
FORTIGATE_VLAN10_IP="192.168.10.1"
FORTIGATE_VLAN40_IP="192.168.40.1"
ALPINE_HOST_IP="192.168.10.2"
KALI_ATTACKER_IP="192.168.40.3"
HONEYPOT_EXT_PORT="2222"
HONEYPOT_INT_PORT="2222"
WEBHOOK_URI="/api/v2/monitor/system/automation-stitch/webhook/cowrie-quarantine"

```

---

## 4. Communication & Protocol Schema

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

---

## 5. Event Sequence & Lifecycle Execution

1. **Reconnaissance & Ingress Probe:** Kali Linux (`192.168.40.3`) scans or targets port `2222` exposed on the FortiGate gateway (`192.168.40.1`).
2. **DNAT Translation via VIP:** FortiGate VIP matches incoming destination port `2222` and forwards the packets across the trust boundary into VLAN 10 to Alpine Docker Host (`192.168.10.2:2222`).
3. **Deception Engagement:** Cowrie honeypot accepts the TCP handshake and mimics an open OpenSSH service, capturing credentials and payload signatures sent by `192.168.40.3`.
4. **Trigger Event Generation:** Cowrie's internal alerting engine outputs JSON security events and invokes a webhook payload directed at `https://192.168.10.1:443/api/v2/monitor/system/automation-stitch/webhook/...`.
5. **Fabric Automated Quarantine:** The FortiOS Automation Stitch captures the incoming webhook, runs the `Quarantine / Ban IP` action on `%%log.srcip%%`, and inserts the IP into the firewall kernel drop table.
6. **Perimeter Isolation:** Subsequent connection attempts from `192.168.40.3` to any interface or service on the FortiGate are dropped at wire speed.

```

---

### Zero-Trust Verification Steps (Execute in Chat Before Transition)

Before confirming completion of Stage 1, run these baseline Layer 2 and Layer 3 verification commands across the nodes:

1. **From Node 2 (Alpine: `192.168.10.2`):**
   ```sh
   # Verify gateway reachability and ARP binding
   ping -c 3 192.168.10.1
   ip neigh show dev eth0

```

*Expected Output:* 0% packet loss to `192.168.10.1`, ARP entry for `192.168.10.1` in `REACHABLE` or `DELAY` state.

2. **From Node 3 (Kali Client: `192.168.40.3`):**
```sh
# Verify perimeter reachability
ping -c 3 192.168.40.1
ip neigh show dev eth0

```


*Expected Output:* 0% packet loss to `192.168.40.1`, ARP entry for `192.168.40.1` present.
3. **From Node 1 (FortiGate CLI):**
```fortios
diagnose ip arp list | grep -E "192.168.10.2|192.168.40.3"
execute ping 192.168.10.2
execute ping 192.168.40.3

```


*Expected Output:* Both IP addresses resolve with valid MAC addresses on their respective interfaces, 100% ping success rate.
