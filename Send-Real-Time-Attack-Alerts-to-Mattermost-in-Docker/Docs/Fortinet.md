```markdown
<!-- filepath: docs/Fortinet.md -->
# FortiOS Security Fabric Integration, Automation Stitches & Perimeter Routing

This guide provides configuration instructions for FortiGate (`192.168.10.1`) to route traffic to the containerized Mattermost host (`192.168.10.2:80`) and trigger real-time HTTP webhook notifications into Mattermost when perimeter IPS threats occur.

---

## 1. Network Topology & Addressing Matrix

* **Perimeter Gateway:** FortiGate Next-Generation Firewall
* **LAN / Trust Interface (`port2`):** `192.168.10.1/24`
* **WAN / External Ingress Interface (`port1`):** `198.51.100.1/24`
* **Alpine Container Host (`port2` LAN):** `192.168.10.2` (Mattermost on TCP Port `80`)
* **Client Workstation (`port2` LAN):** `192.168.10.3/24`

---

## 2. Track 1: Step-by-Step FortiOS CLI Commands

Execute these configuration blocks in sequence directly within the FortiOS CLI console.

### Step 2.1: Verify & Configure LAN Interface (`port2`)
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

### Step 2.2: Define Firewall Address Objects

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

### Step 2.3: Virtual IP (VIP) Destination NAT Configuration

Forward external inbound traffic on `port1:80` to the internal Alpine Linux container host:

```fortios
config firewall vip
    edit "VIP_Mattermost_HTTP"
        set extip 198.51.100.1
        set extintf "port1"
        set portforward enable
        set protocol tcp
        set extport 80
        set mappedip "192.168.10.2"
        set mappedport 80
        set comment "DNAT HTTP port 80 to Alpine container host"
    next
end

```

### Step 2.4: Inbound & Outbound Firewall Policies

```fortios
config firewall policy
    edit 10
        set name "WAN_to_Mattermost_VIP"
        set srcintf "port1"
        set dstintf "port2"
        set action accept
        set srcaddr "all"
        set dstaddr "VIP_Mattermost_HTTP"
        set schedule "always"
        set service "HTTP"
        set utm-status enable
        set ips-sensor "default"
        set logtraffic all
        set comments "Permit inbound webhooks and UI access with IPS inspection"
    next
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
        set comments "Permit outbound Internet access from LAN"
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
        set comments "Intra-LAN hairpin access from test box"
    next
end

```

### Step 2.5: Configure FortiOS Automation Stitch & Mattermost Webhook

Configure the automated trigger, webhook dispatch action, and binding stitch:

```fortios
config system automation-trigger
    edit "Trigger_IPS_Attack_Alert"
        set event-type event-log
        set logid 0419016384
        set description "Triggers when an IPS intrusion detection event is logged"
    next
end

config system automation-action
    edit "Action_Mattermost_Webhook"
        set action-type webhook
        set protocol http
        set uri "hooks/YOUR_MATTERMOST_HOOK_ID_HERE"
        set http-body "{\"text\": \":warning: **[FORTIGATE SECURITY ALERT]** Threat detected!\\n- **Firewall:** %%log.devname%%\\n- **Threat:** %%log.attack%%\\n- **Source IP:** %%log.srcip%%\\n- **Destination IP:** %%log.dstip%%\\n- **Action:** %%log.action%%\\n- **Severity:** %%log.severity%%\"}"
        set port 80
        config http-headers
            edit 1
                set key "Content-Type"
                set value "application/json"
            next
        end
        set comment "Dispatches threat alert JSON payload to Mattermost on port 80"
    next
end

config system automation-stitch
    edit "Stitch_FortiGate_to_Mattermost"
        set status enable
        set trigger "Trigger_IPS_Attack_Alert"
        config actions
            edit 1
                set action "Action_Mattermost_Webhook"
                set required enable
            next
        end
        config destination
            edit "HOST_Alpine_Mattermost"
            next
        end
    next
end

```

---

## 3. Track 2: FortiOS GUI Navigation Steps

### Step 3.1: Interface & VIP Setup

1. **Network > Interfaces**: Ensure `port2` is set to `192.168.10.1/24` with `PING`, `HTTPS`, and `SSH` access.
2. **Policy & Objects > Addresses**: Create address objects `HOST_Alpine_Mattermost` (`192.168.10.2/32`) and `NET_LAN_192.168.10.0` (`192.168.10.0/24`).
3. **Policy & Objects > Virtual IPs**: Create `VIP_Mattermost_HTTP` forwarding `198.51.100.1:80` to `192.168.10.2:80`.
4. **Policy & Objects > Firewall Policy**: Create inbound policy matching `port1` -> `port2`, destination `VIP_Mattermost_HTTP`, service `HTTP`, with **IPS** set to `default`.

### Step 3.2: Automation Stitch Configuration

1. Navigate to **Security Fabric > Automation**.
2. Select the **Stitches** tab and click **Create New**.
3. **Name:** Enter `Stitch_FortiGate_to_Mattermost`.
4. **Trigger:** Click the `+` icon on the trigger card:
* Click **Create**.
* Choose **FortiOS Event Log**.
* **Event:** Choose **IPS log** (Log ID `0419016384`).
* Name it `Trigger_IPS_Attack_Alert` and click **Apply**.


5. **Action:** Click the `+` icon on the action card:
* Click **Create**.
* Choose **Webhook**.
* **Name:** `Action_Mattermost_Webhook`.
* **Protocol:** `HTTP`.
* **URL / URI:** `http://192.168.10.2:80/hooks/YOUR_MATTERMOST_HOOK_ID_HERE`.
* **HTTP Method:** `POST`.
* **HTTP Headers:** `Content-Type: application/json`.
* **Body:** Paste the JSON template payload from Step 2.5.
* Click **Apply**.


6. Toggle stitch status to **Enable** and save.

---

## 4. Zero-Trust Verification Blocker

Before marking Stage 4 complete, execute and inspect these diagnostic commands in the FortiOS CLI:

**1. ARP Table Resolution:**

```fortios
get system arp | grep 192.168.10.2

```

*Requirement:* Ensure `192.168.10.2` is actively resolved to the Alpine Linux host interface on `port2`.

**2. Session Filter Trace:**

```fortios
diagnose sys session filter clear
diagnose sys session filter daddr 192.168.10.2
diagnose sys session list

```

*Requirement:* Verify active stateful sessions transitioning toward destination port `80`.

**3. Packet Sniffer Capture:**

```fortios
diagnose sniffer packet port2 'host 192.168.10.2 and port 80' 4 0 l

```

*Requirement:* Trigger an alert or curl test and verify bidirectional TCP handshakes traversing `port2`.

**4. Automation Stitch Test Trigger:**

```fortios
diagnose automation test Stitch_FortiGate_to_Mattermost

```

*Requirement:* Confirm FortiOS successfully fires the webhook action without socket timeouts or connection drops.

```

---

With the Automation Stitch fully integrated into Stage 4:
* If you need adjustments to any stage, let me know.
* Otherwise, reply with `I am done with Stage 8` when you are ready to progress to **Stage 9: Post-Production Video & Timestamps**[cite: 1].

```
