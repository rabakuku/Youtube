### Fortinet Security Fabric Integration

Configure the perimeter firewall, VIP DNAT mapping, address objects, and security policies on FortiGate (`192.168.10.1`) to govern traffic forwarding toward the Mattermost container host (`192.168.10.2:80`).

```markdown
<!-- filepath: docs/Fortinet.md -->
# FortiOS Security Fabric Integration & Perimeter Routing Guide

This document establishes the perimeter routing, virtual IP (VIP) destination NAT, address objects, and firewall policies on the FortiGate next-generation firewall to securely route traffic from external ingress points and client test subnets to the Mattermost container environment.

---

## 1. Interface & Topology Addressing Matrix

* **Perimeter Gateway:** FortiGate Next-Generation Firewall
* **LAN / Trust Interface (`port2`):** `192.168.10.1/24`
* **WAN / External Ingress Interface (`port1`):** `198.51.100.1/24` (or upstream gateway uplink)
* **Mattermost Container Target (`port2` LAN):** `192.168.10.2` (TCP Port `80`)
* **Client Workstation (`port2` LAN):** `192.168.10.3/24`

---

## 2. Track 1: Step-by-Step FortiOS CLI Commands

Execute these configuration blocks in the FortiOS CLI console:

### Step 2.1: Verify & Bind LAN Interface (`port2`)
```fortios
config system interface
    edit "port2"
        set vdom "root"
        set ip 192.168.10.1 255.255.255.0
        set allowaccess ping https ssh
        set type physical
        set description "LAN-Mattermost-Fabric"
    next
end

```

### Step 2.2: Configure Firewall Address Objects

```fortios
config firewall address
    edit "HOST_Alpine_Mattermost"
        set subnet 192.168.10.2 255.255.255.255
        set comment "Container host running Mattermost on port 80"
    next
    edit "NET_LAN_192.168.10.0"
        set subnet 192.168.10.0 255.255.255.0
        set comment "Internal trust subnet"
    next
    edit "HOST_Client_Tester"
        set subnet 192.168.10.3 255.255.255.255
        set comment "Diagnostic test client workstation"
    next
end

```

### Step 2.5: Create Intra-LAN & Outbound Egress Policies

```fortios
config firewall policy
    edit 20
        set name "LAN_Outbound_Internet"
        set srcintf "port2"
        set dstintf "port1"
        set action accept
        set srcaddr "NET_LAN_192.168.10.0"
        set dstaddr "all"
        set schedule "always"
        set service "ALL"
        set nat enable
        set logtraffic utm
        set comments "Allow LAN container host and client outbound access"
    next
    edit 30
        set name "LAN_Client_to_Mattermost"
        set srcintf "port2"
        set dstintf "port2"
        set action accept
        set srcaddr "HOST_Client_Tester"
        set dstaddr "HOST_Alpine_Mattermost"
        set schedule "always"
        set service "HTTP"
        set logtraffic all
        set comments "Hairpin/Intra-interface access from client test box"
    next
end

```

---

## 3. Track 2: FortiOS GUI Navigation Steps

If deploying via FortiOS Web GUI, follow these navigation workflows:

### Step 3.1: Interface Verification

1. Navigate to **Network > Interfaces**.
2. Double-click `port2`.
3. Set **IP/Network Mask** to `192.168.10.1/24`.
4. Under **Administrative Access**, enable `PING`, `HTTPS`, and `SSH`.
5. Click **OK**.

### Step 3.2: Address Object Creation

1. Navigate to **Policy & Objects > Addresses**.
2. Click **Create New > Address**.
* **Name:** `HOST_Alpine_Mattermost`
* **Type:** Subnet
* **IP/Netmask:** `192.168.10.2/32`
* **Interface:** `port2`


3. Click **OK**. Repeat for `NET_LAN_192.168.10.0` (`192.168.10.0/24`) and `HOST_Client_Tester` (`192.168.10.3/32`).


### Step 3.4: Firewall Policy Creation

1. Navigate to **Policy & Objects > Firewall Policy**.
2. Click **Create New**.
* **Name:** `WAN_to_Mattermost_VIP`
* **Incoming Interface:** `port1`
* **Outgoing Interface:** `port2`
* **Source:** `all`
* **Destination:** `VIP_Mattermost_HTTP`
* **Service:** `HTTP`
* **Action:** `ACCEPT`
* **NAT:** Disabled (handled automatically by VIP DNAT)
* **Log Allowed Traffic:** `All Sessions`


3. Click **OK**.

```

---

### Zero-Trust Verification Blocker

Before transitioning to Stage 5, execute the following diagnostic traces on the FortiGate CLI while initiating HTTP traffic from your client workstation (`192.168.10.3`) or an upstream ingress host:

**1. ARP Table Resolution:**
```fortios
get system arp | grep 192.168.10.2

```

*Requirement:* Ensure `192.168.10.2` is resolved to the hardware MAC address of the Alpine Linux host interface on `port2`.

**2. Active Session Table Trace:**

```fortios
diagnose sys session filter clear
diagnose sys session filter daddr 192.168.10.2
diagnose sys session list

```

*Requirement:* Verify an active session table entry shows incoming state `proto=6`, destination IP `192.168.10.2`, and destination port `80` transitioning through FortiOS policy lookup.

**3. Live Packet Sniffer Capture:**

```fortios
diagnose sniffer packet port2 'host 192.168.10.2 and port 80' 4 0 l

```

*Requirement:* Trigger an HTTP request to `[http://192.168.10.2](http://192.168.10.2)` (or the external VIP address). Verify the sniffer displays bidirectional TCP handshakes (`[SYN]`, `[SYN, ACK]`, `[ACK]`) traversing `port2`. Press `Ctrl+C` to terminate capture.
