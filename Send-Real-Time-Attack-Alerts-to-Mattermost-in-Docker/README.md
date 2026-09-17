To turn your `README.md` into an interactive, sequential runbook, organize it as a numbered execution pipeline where each stage links directly to its file in your repository, states the required prerequisite commands, and gives the user immediate verification commands before moving to the next step. Removing the VIP simplifies the architecture: FortiGate (`192.168.10.1`) communicates directly across the trusted LAN subnet to Alpine Linux (`192.168.10.2:80`) using its internal routing table and Automation Stitch engine.

```markdown
<!-- filepath: README.md -->
# FortiGate Real-Time Attack Alert Automation to Mattermost in Docker

[![FortiOS](https://img.shields.io/badge/FortiOS-7.x%20%7C%20Active-orange.svg)](#)
[![Docker](https://img.shields.io/badge/Docker-Engine%20v24+-blue.svg)](#)
[![Alpine Linux](https://img.shields.io/badge/Alpine%20Linux-v3.19%20%2F%20v3.20-blue.svg)](#)
[![Mattermost](https://img.shields.io/badge/Mattermost-Team%20Edition-0058CC.svg)](#)
[![Security Policy](https://img.shields.io/badge/Zero--Trust-Enforced-red.svg)](#)

A step-by-step implementation guide to deploying a self-hosted Mattermost ChatOps engine on Alpine Linux and connecting FortiOS Automation Stitches to receive sub-second threat notifications directly over your trusted local network.

---

## Lab Architecture & Topology Map

This deployment operates entirely inside the trusted LAN fabric without external VIP or public NAT dependencies. FortiGate detects security events on its interfaces and uses an internal webhook action to POST JSON alerts directly to the Mattermost container host.

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
     |  - mattermost-app |                             | `curl 192.168.10.2`|
     |  - postgres:15    |                             +-------------------+
     +-------------------+

```

### Addressing Matrix

| Device / Host | Interface | IP Address | Subnet Mask | Role / Function |
| --- | --- | --- | --- | --- |
| **FortiGate Gateway** | `port2` | `192.168.10.1` | `255.255.255.0` (`/24`) | Default Gateway & Automation Stitch Engine |
| **Alpine Host** | `eth0` | `192.168.10.2` | `255.255.255.0` (`/24`) | Docker Host (Mattermost Webhook Listener) |
| **Client Test Bed** | `eth0` | `192.168.10.3` | `255.255.255.0` (`/24`) | Traffic Generator & Diagnostic Verification |

---

## Implementation Roadmap (Follow in Order)

Execute the steps below sequentially. Each step links directly to the detailed configuration guide in the repository.

```text
  [Step 1: Host Prep]     -->  [Step 2: Containers]    -->  [Step 3: FortiGate Setup]
  docs/install-docker.md       docs/Configuration.md        docs/Fortinet.md
            |                            |                           |
            v                            v                           v
  Verify Docker Daemon          Verify Port 80 Listener     Trigger Live Test Stitch

```

---

### Step 1: Prepare the Alpine Linux Container Host

Before launching containers, configure Alpine Linux repositories, install Docker Engine with the Compose plugin, grant user socket permissions, and register the OpenRC service.

1. Open and follow the guide:
👉 **[Docs/install-docker.md](https://www.google.com/search?q=https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/Docs/install-docker.md)**
2. Execute the verification commands on `192.168.10.2`:
```bash
rc-service docker status
docker info

```


3. Ensure the service returns `status: started` before moving to Step 2.

---

### Step 2: Deploy Mattermost & PostgreSQL Containers

Launch the containerized ChatOps stack. Mattermost binds directly to host port `80`, while PostgreSQL is isolated on a dedicated internal Docker network (`172.28.0.0/24`).

1. Open and review the architecture guide:
👉 **[Docs/Configuration.md](https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/Docs/Configuration.md)**
2. Navigate to the compose directory:
👉 **[compose/docker-compose.yml](https://www.google.com/search?q=https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/compose/docker-compose.yml)**
👉 **[compose/.env.example](https://www.google.com/search?q=https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/compose/.env.example)**
3. Deploy the containers:
```bash
cd compose
cp .env.example .env
docker compose up -d

```


4. Verify the application listener and client reachability:
```bash
# On Alpine (192.168.10.2):
docker compose ps
netstat -tuln | grep :80

# From Windows Client (192.168.10.3):
curl.exe -I [http://192.168.10.2:80](http://192.168.10.2:80)

```


5. Open `http://192.168.10.2` in your browser, complete the initial admin account setup, create a channel named `security-alerts`, and generate an **Incoming Webhook URL** (`System Console > Integrations > Incoming Webhooks`). Note this URL for Step 3.

---

### Step 3: Configure FortiGate Security Fabric & Automation Stitch

Configure FortiGate (`192.168.10.1`) to inspect traffic, drop perimeter attacks, and fire an automated HTTP webhook notification directly across the LAN to the Alpine host.

1. Open and follow the step-by-step CLI or GUI instructions:
👉 **[Docs/Fortinet.md](https://www.google.com/search?q=https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/Docs/Fortinet.md)**
2. Main configurations applied in this step:
* **Firewall Address Objects:** Defining `HOST_Alpine_Mattermost` (`192.168.10.2`) and `NET_LAN_192.168.10.0` (`192.168.10.0/24`).
* **LAN Firewall Policies:** Permitting local traffic inspection and client access.
* **Automation Trigger:** Capturing event log IDs for IPS detections (`0419016384`) or anomaly drops.
* **Automation Action:** Sending a structured JSON payload directly to `http://192.168.10.2:80/hooks/<YOUR_HOOK_ID>`.
* **Automation Stitch:** Binding the IPS trigger directly to the Mattermost webhook action.



---

### Step 4: Verify End-to-End Alerting

Confirm that security drops automatically create alert cards inside Mattermost:

1. Test the stitch manually from the FortiGate CLI:
```fortios
diagnose automation test Stitch_FortiGate_to_Mattermost

```


2. Verify session logging and packet traversal on FortiGate:
```fortios
diagnose sniffer packet port2 'host 192.168.10.2 and port 80' 4 0 l

```


3. Check the `security-alerts` channel in Mattermost. You will see a formatted card displaying the firewall hostname, attacker IP, threat signature, and gateway action.

---

## Alternative: Automated One-Touch Scripts

For automated lab deployments and teardowns, use the bundled shell scripts:

* **Automated Provisioning:**
👉 **[scripts/setup.sh](https://www.google.com/search?q=https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/scripts/setup.sh)**
Installs dependencies, configures OpenRC, deploys the compose stack, and checks health automatically:
```bash
chmod +x scripts/setup.sh
./scripts/setup.sh

```


* **Full Teardown & Reset:**
👉 **[scripts/rollback.sh](https://www.google.com/search?q=https://github.com/rabakuku/Youtube/blob/main/Send-Real-Time-Attack-Alerts-to-Mattermost-in-Docker/scripts/rollback.sh)**
Stops containers, deletes bridge networks, and purges all persistent database volumes:
```bash
chmod +x scripts/rollback.sh
./scripts/rollback.sh

```



---

## Educational & Presentation Resources

```

```
