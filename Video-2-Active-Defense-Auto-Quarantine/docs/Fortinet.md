```markdown
<!-- filepath: docs/Fortinet.md -->
# Fortinet Security Fabric Integration Guide

This guide details the end-to-end configuration for Node 1 (`FGT-CORE-01`, `192.168.10.1/24` on `port2`) to implement automated threat containment. It establishes REST API permissions, address infrastructure, edge firewall isolation policies, and native Automation Stitches that notify the containerized orchestrator on Node 2 (`192.168.10.2:80`).

---

## 1. Architectural Role & Topology Parameters

* **Interface**: `port2`
* **FortiGate IP**: `192.168.10.1/24`
* **Alpine Docker Host (SOAR)**: `192.168.10.2`
* **Attacker Host (Kali)**: `192.168.10.3`
* **API Administrator**: `soar-api-admin`
* **API Bearer Token**: `autoquarantine-sec-token-xyz123`
* **Isolation Address Group**: `GRP_ACTIVE_QUARANTINE`

---

## 2. CLI Configuration (Step-by-Step)

Execute the following commands sequentially via the FortiGate administrative console or SSH session:

### Step 2.1: Verify Interface Configuration
Ensure `port2` is bound to the trust boundary and administrative HTTPS access is enabled for API interactions:
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

```

### Step 2.2: REST API Administrator & Access Profile

Configure a granular REST API access profile granting read/write permissions to firewall policies and address objects, then instantiate the tokenized administrator account:

```fortios
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

```

### Step 2.3: Address Group & Quarantine Blackhole Policy

Establish a placeholder object, initialize the dynamic quarantine group, and construct a top-priority `DENY` policy applied on ingress:

```fortios
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

```

### Step 2.4: DoS Anomaly Sensor & Automation Stitch

Configure the DoS anomaly detection policy and wire it directly to an outbound Webhook Automation Action targeting Node 2:

```fortios
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

## 3. Graphical User Interface (GUI) Execution Guide

### 3.1 REST API Administrator Setup

1. Log into the FortiOS administrative interface at `https://192.168.10.1/`.
2. Navigate to **System** -> **Administrators** -> Click **Create New** -> Select **REST API Admin**.
3. Set **Username** to `soar-api-admin`.
4. Under **Administrator Profile**, select **Create** or choose `prof_soar_automation` with read/write access to Firewall configuration.
5. In **PKI / Token Access**, generate or specify the API token `autoquarantine-sec-token-xyz123`.
6. Under **Restrict login to trusted hosts**, enable the slider and add `192.168.10.2/32`.
7. Click **OK**.

### 3.2 Quarantine Address Group & Blackhole Policy

1. Navigate to **Policy & Objects** -> **Addresses** -> Click **Create New** -> **Address**.
* **Name**: `QUAR_PLACEHOLDER`
* **IP/Netmask**: `0.0.0.0/32`
* Click **Save**.


2. Navigate to **Policy & Objects** -> **Addresses** -> Click **Create New** -> **Address Group**.
* **Name**: `GRP_ACTIVE_QUARANTINE`
* **Members**: Select `QUAR_PLACEHOLDER`
* Click **Save**.


3. Navigate to **Policy & Objects** -> **Firewall Policy** -> Click **Create New**.
* **Name**: `POLICY_ACTIVE_QUARANTINE_DROP`
* **Incoming Interface**: `port2`
* **Outgoing Interface**: `any`
* **Source**: `GRP_ACTIVE_QUARANTINE`
* **Destination**: `all`
* **Service**: `ALL`
* **Action**: `DENY`
* **Log Violation Traffic**: Enable
* Click **OK**.


4. Drag and place `POLICY_ACTIVE_QUARANTINE_DROP` at position **1** (top of the policy list).

### 3.3 Automation Stitch & Outbound Webhook Setup

1. Navigate to **Security Fabric** -> **Automation** -> Select the **Stitches** tab -> Click **Create New**.
2. Set **Name** to `STITCH_AUTO_QUARANTINE`.
3. Under **Trigger**, click **Add Trigger** -> Click **Create** -> Select **FortiOS Event Log**.
* **Name**: `TRIG_DOS_ANOMALY`
* **Event**: FortiOS Log ID `0100022001` (DoS Anomaly Event)
* Click **Apply**.


4. Under **Action**, click **Add Action** -> Click **Create** -> Select **Webhook**.
* **Name**: `ACTION_NOTIFY_N8N_SOAR`
* **Protocol**: `HTTP`
* **URL**: `http://192.168.10.2:80/webhook/quarantine`
* **HTTP Method**: `POST`
* **Body**: `{"srcip": "%%log.srcip%%", "logid": "%%log.logid%%", "threat": "Port Scan / SYN Anomaly Detected"}`
* Click **Apply**.


5. Click **OK** to save and activate the stitch.

```

---

### Zero-Trust Verification Blocker (Stage 5)

Run these diagnostics from the FortiGate CLI (`192.168.10.1`) and Kali (`192.168.10.3`) to confirm end-to-end integration:

#### 1. Verify Neighbor Adjacency (FortiGate CLI)
```fortios
get system arp | grep 192.168.10.2

```

*Verification standard:* `192.168.10.2` must resolve with an active hardware MAC address on `port2`.

#### 2. Arm Real-Time Webhook Packet Sniffer (FortiGate CLI)

```fortios
diagnose sniffer packet port2 'host 192.168.10.2 and port 80' 4 0 l

```

*Verification standard:* Keep this terminal open to observe the outbound TCP SYN and HTTP POST packet dispatch when the attack occurs.

#### 3. Trigger Adversary Simulation (Kali CLI - `192.168.10.3`)

```bash
hping3 -S --flood -V -p 80 192.168.10.1 --count 500

```

*Verification standard:* Initiates the SYN flood matching the DoS anomaly threshold.

#### 4. Confirm Session Drop & Dynamic Address Population (FortiGate CLI)

```fortios
diagnose sys session filter daddr 192.168.10.1
diagnose sys session list
get firewall addrgrp GRP_ACTIVE_QUARANTINE

```

*Verification standard:* `GRP_ACTIVE_QUARANTINE` must now contain `QUAR_192.168.10.3`, and subsequent traffic from `192.168.10.3` will match policy ID 100 (`action=deny`).

When the dynamic quarantine entry is confirmed on FortiOS, reply with:

`"I am done with Stage 5"`
