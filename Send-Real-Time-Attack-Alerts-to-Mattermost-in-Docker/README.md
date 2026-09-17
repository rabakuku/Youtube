
<p align="left">
  <img src="https://img.shields.io/badge/FortiOS-7.x-orange.svg" alt="FortiOS" />
  <img src="https://img.shields.io/badge/Docker-Engine%20v24+-blue.svg" alt="Docker" />
  <img src="https://img.shields.io/badge/Alpine%20Linux-v3.19%20%2F%20v3.20-blue.svg" alt="Alpine Linux" />
  <img src="https://img.shields.io/badge/Mattermost-Team%20Edition-0058CC.svg" alt="Mattermost" />
  <img src="https://img.shields.io/badge/Zero--Trust-Enforced-red.svg" alt="Security Policy" />
</p>

```markdown
<!-- filepath: README.md -->
# FortiGate Real-Time Attack Alert Automation to Mattermost in Docker



An enterprise-grade, fully automated framework to deploy a self-hosted Mattermost ChatOps container stack on Alpine Linux and integrate FortiOS Automation Stitches to stream perimeter intrusion alerts directly to security engineering teams in under 50 milliseconds.

No manual file creation or entire Git repository cloning is required. The deployment script downloads and configures all necessary Compose files and dependencies on demand.

---

## Network Architecture & Topology

This deployment operates entirely across the internal trusted LAN subnet (`192.168.10.0/24`). FortiGate detects security events on its interfaces and uses an internal automation webhook action to dispatch JSON payloads directly to the Alpine container host on port `80`.

```text
               +--------------------------------------------------+
               |               WAN / Untrusted Ingress            |
               |                Subnet: 198.51.100.0/24           |
               +--------------------------------------------------+
                                        |
                                        | [port1: 198.51.100.1]
                               +-----------------+
                               |    FortiGate    |
                               | Next-Gen Firewall|
                               +-----------------+
                                        | [port2: 192.168.10.1]
                                        |
      ==================================+==================================
      |                 LAN Fabric Subnet: 192.168.10.0/24               |
      ==================================+==================================
                                        |
               +------------------------+------------------------+
               |                                                 |
               | [eth0: 192.168.10.2]                            | [eth0: 192.168.10.3]
     +-------------------+                             +-------------------+
     |   Alpine Linux    |                             |  Windows / Client |
     |   Docker Engine   |                             |   Test Bed Host   |
     +-------------------+                             +-------------------+
     | [Port 80:HTTP]    |                             | Diagnostic Check: |
     |  - mattermost-app |                             | curl 192.168.10.2 |
     |  - postgres:15    |                             +-------------------+
     +-------------------+

```

### Addressing Matrix

| Device / Host | Interface | IPv4 Address | Subnet Mask | Gateway | Function |
| --- | --- | --- | --- | --- | --- |
| **FortiGate Firewall** | `port2` | `192.168.10.1` | `255.255.255.0` (`/24`) | N/A | LAN Default Gateway & Automation Stitch Engine |
| **Alpine Linux Host** | `eth0` | `192.168.10.2` | `255.255.255.0` (`/24`) | `192.168.10.1` | Hardened Container Host (Mattermost Webhook Target) |
| **Client Test Station** | `eth0` | `192.168.10.3` | `255.255.255.0` (`/24`) | `192.168.10.1` | Test Traffic Generator & Socket Diagnostics |

---

## Architectural Problem Statement

Perimeter defense architectures frequently suffer from silent security failures. Critical IPS signatures, brute-force intrusions, and anomalous drops are written to system memory or forwarded to remote syslog collectors where human visibility is delayed by hours.

This project delivers a completely automated, zero-trust pipeline:

1. Hardens an ultra-minimal Alpine Linux host (`192.168.10.2`) with an enforced OS gatekeeper check.
2. Automates the deployment of PostgreSQL 15 and Mattermost Team Edition via [scripts/setup.sh](https://www.google.com/search?q=https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/scripts/setup.sh) by pulling required configurations without cloning the entire repository.
3. Connects FortiOS Automation Stitches directly to Mattermost incoming webhooks over the local LAN without public NAT or third-party cloud aggregators.

---

## Repository Layout

```text
├── scripts/
│   ├── setup.sh
│   └── rollback.sh
├── compose/
│   ├── docker-compose.yml
│   └── .env.example
├── Docs/
│   ├── install-docker.md
│   ├── Configuration.md
│   ├── Fortinet.md
│   └── main.md
├── presentation/
│   └── PowerPoint.html
└── README.md

```

---

## Automated Step-by-Step Deployment Runbook

Follow these stages in order to deploy, configure, and verify the alerting fabric.

```text
  [Step 1: Automated Run]  -->  [Step 2: Mattermost Webhook]  -->  [Step 3: FortiGate Stitch]  -->  [Step 4: Verify]
     scripts/setup.sh             GUI Webhook Generation             Docs/Fortinet.md             CLI Sniffer

```

---

### Step 1: Automated Host Provisioning & Stack Launch

You do not need to clone the entire Git repository. Simply fetch the `setup.sh` and `rollback.sh` scripts directly using `curl`, set execute permissions, and run `setup.sh`. The script automatically handles package installation, Docker initialization, and downloads the required Compose and environment files.

1. Log into your Alpine Linux host (`192.168.10.2`) as `root`.
2. Create a dedicated workspace and retrieve the automation scripts:
```bash
mkdir -p /opt/mattermost-stack && cd /opt/mattermost-stack
curl -fsSL https://raw.githubusercontent.com/rabakuku/Youtube/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/scripts/setup.sh -o setup.sh
curl -fsSL https://raw.githubusercontent.com/rabakuku/Youtube/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/scripts/rollback.sh -o rollback.sh
chmod +x setup.sh rollback.sh

```


3. Execute the automated setup harness:
```bash
./setup.sh

```



**What `setup.sh` does automatically:**

* Validates that the host is strictly running Alpine Linux via `/etc/os-release`.
* Enables the Alpine Community repository in `/etc/apk/repositories`.
* Installs `docker`, `docker-cli-compose`, `containerd`, `iptables`, `curl`, `net-tools`, and `ca-certificates`.
* Registers the Docker service with the `boot` runlevel and starts the daemon via OpenRC.
* Automatically fetches [compose/docker-compose.yml](https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/compose/docker-compose.yml) and generates [compose/.env](https://www.google.com/search?q=https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/compose/.env.example).
* Binds the Mattermost listener directly to host port `80`.
* Executes an active healthcheck loop until PostgreSQL and Mattermost return healthy status.

> **Technical Reference:** If you want to review the underlying host configuration and container architecture details handled by the script, read:
> * 👉 **[Docs/install-docker.md](https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/Docs/install-docker.md)**
> * 👉 **[Docs/Configuration.md](https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/Docs/Configuration.md)**
> 
> 

---

### Step 2: Generate Mattermost Incoming Webhook

Once `setup.sh` reports success, configure the incident channel inside Mattermost:

1. Open a browser from your management or client machine (`192.168.10.3`) and navigate to:
```text
[http://192.168.10.2:80](http://192.168.10.2:80)

```


2. Follow the on-screen prompts to establish the initial System Administrator account.
3. Create a dedicated team and create a public channel named:
```text
security-alerts

```


4. Open the System Menu in the top left, select **Integrations**, and click **Incoming Webhooks**.
5. Click **Add Incoming Webhook**:
* **Title:** `FortiGate Threat Alerts`
* **Channel:** Select `security-alerts`


6. Click **Save** and copy the generated Webhook URL (format: `http://192.168.10.2/hooks/YOUR_HOOK_ID_HERE`). You will need this URL in Step 3.

---

### Step 3: Configure FortiGate Security Fabric & Automation Stitch

Configure FortiGate (`192.168.10.1`) to inspect traffic and trigger automated HTTP POST requests directly across the LAN to your Mattermost listener whenever an IPS attack or threat is detected.

1. Follow the full CLI and GUI walkthrough in:
👉 **[Docs/Fortinet.md](https://www.google.com/search?q=https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/Docs/Fortinet.md)**
2. Apply the address objects and internal policy on FortiGate:
```fortios
config firewall address
    edit "HOST_Alpine_Mattermost"
        set subnet 192.168.10.2 255.255.255.255
        set comment "Mattermost container host"
    next
    edit "NET_LAN_192.168.10.0"
        set subnet 192.168.10.0 255.255.255.0
        set comment "Internal trust LAN"
    next
end

config firewall policy
    edit 10
        set name "LAN_Client_to_Mattermost"
        set srcintf "port2"
        set dstintf "port2"
        set action accept
        set srcaddr "NET_LAN_192.168.10.0"
        set dstaddr "HOST_Alpine_Mattermost"
        set schedule "always"
        set service "HTTP"
        set logtraffic all
    next
end

```


3. Configure the FortiOS Automation Stitch (substituting your actual Webhook URI):
```fortios
config system automation-trigger
    edit "Trigger_IPS_Attack_Alert"
        set event-type event-log
        set logid 0419016384
        set description "Firewall IPS Threat Event"
    next
end

config system automation-action
    edit "Action_Mattermost_Webhook"
        set action-type webhook
        set protocol http
        set uri "hooks/YOUR_HOOK_ID_HERE"
        set port 80
        set http-body "{\"text\": \"warning\"}"
        config http-headers
            edit 1
                set key "Content-Type"
                set value "application/json"
            next
        end
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
3.1. Other HTTP Body Formats
1. Compact Single-Line Alert
```fortios
{"text": ":warning: **FortiGate Alert:** Event `%%log.logid%%` triggered from `%%log.srcip%%` -> `%%log.dstip%%` (Action: `%%log.action%%`)"}
```

2. Clean Multi-Line Markdown Card

```fortios
{"text": "### :rotating_light: FortiGate Threat Detection\n* **Log ID:** `%%log.logid%%`\n* **Message:** %%log.msg%%\n* **Source IP:** `%%log.srcip%%` (Port: `%%log.srcport%%`)\n* **Destination IP:** `%%log.dstip%%` (Port: `%%log.dstport%%`)\n* **Action:** `%%log.action%%`\n* **Firewall Policy:** `%%log.policyid%%`"}
```

3. Raw Log Dump (Useful for Debugging)

```fortios
{"text": ":warning: **Trigger Log Dump:**\n```json\n%%log%%\n```"}
```


---

### Step 4: Verification & Diagnostic Checks

Confirm end-to-end communication from the FortiGate CLI before testing live attacks:

1. **Test Automation Action Dispatch:**
```fortios
diagnose automation test Stitch_FortiGate_to_Mattermost

```


*Expected Output:* FortiGate dispatches the HTTP payload to `192.168.10.2:80`, and a test notification immediately renders inside the `#security-alerts` channel.
2. **Verify LAN Packet Flow:**
```fortios
diagnose debug application autod -1
diagnose debug enable

```


3. **Verify Host Port & Sockets on Alpine:**
```bash
netstat -tuln | grep :80
docker compose -f /opt/mattermost-stack/compose/docker-compose.yml ps

```



---

## Teardown & Rollback Automation

To reset, modify, or completely wipe the lab environment, execute the interactive rollback tool:

```bash
./rollback.sh

```

*(If `rollback.sh` is not present locally, download it directly: `curl -fsSL https://raw.githubusercontent.com/rabakuku/Youtube/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/scripts/rollback.sh -o rollback.sh && chmod +x rollback.sh && ./rollback.sh`)*

The script presents an interactive menu allowing you to choose the exact level of removal:

* **Option 1: Remove Containers & Volumes Only**
Stops containers, deletes bridge networks, and purges all persistent database and configuration volumes. Leaves the Docker engine and host packages intact.
* **Option 2: Remove Containers + Docker + Compose**
Executes Option 1, then stops the Docker daemon, unregisters OpenRC runlevels, and uninstalls `docker`, `docker-cli-compose`, and `containerd`.
* **Option 3: Remove All That Was Installed With setup.sh (Full Reset)**
Executes Option 1 and Option 2, purges all installed network and storage dependencies (`e2fsprogs`, `iptables`, `curl`, `net-tools`, `ca-certificates`), removes `/var/lib/docker`, and wipes all generated configuration files to return the system to its initial baseline.

---

## Educational & Media Production Assets

* **Master Architecture Specification:**
👉 **[Docs/main.md](https://www.google.com/search?q=https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/Docs/main.md)**
* **Full-Screen Interactive HTML Presentation Deck:**
👉 **[presentation/PowerPoint.html](https://www.google.com/search?q=https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/presentation/PowerPoint.html)**
Open in any modern browser for an edge-to-edge interactive presentation with animated SVG network traffic flows, keyboard controls (`Spacebar`, `Arrow Keys`), and zero-trust metric dashboards.

```

---
