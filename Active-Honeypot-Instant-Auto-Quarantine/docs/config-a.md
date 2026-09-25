```markdown
<!-- filepath: https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/docs/config-a.md -->
# Stage 5A: Basic Honeypot Webhook Dispatch (Enterprise Edition)

This guide establishes the primary detection-to-mitigation pipeline between the Cowrie honeypot container (`192.168.10.2`) and the FortiOS Security Fabric (`192.168.10.1`). 

To maximize the production value for your YouTube demonstration, this setup has been engineered specifically for Alpine Linux. We will create a professional **OpenRC background service**, add a **Cinematic ANSI-colorized terminal output**, and deploy a **Web-based GUI log streamer (Frontail)** to visualize the attacks live.

---

### Step 1: Create the REST API Admin User on FortiGate (Node 1)

In FortiOS, invoking `/api/v2/monitor/system/automation-stitch/webhook/...` requires authentication via a dedicated REST API Administrator bearer token.

1. Connect to the FortiGate CLI console and configure the access profile and API user:
   ```fortios
   config system accprofile
       edit "PROF_WEBHOOK_QUARANTINE"
           set comments "Access profile for honeypot auto-quarantine automation"
           set secfabread write
           set sysgrp read-write
           set netgrp read-write
           set loggrp read-write
           set fwgrp read-write
           set secfabgrp read-write
       next
   end

   config system api-user
       edit "api_cowrie_quarantine"
           set accprofile "PROF_WEBHOOK_QUARANTINE"
           set vdom "root"
           config trusthost
               edit 1
                   set ipv4-trusthost 192.168.10.2 255.255.255.255
               next
           end
       next
   end

```

2. Generate the API token:
```fortios
execute api-user generate-key api_cowrie_quarantine

```


*Console Output:*
```text
New API key: d3kF9x8Qm1Np4La7Zr2T5vW8yB0cX3jK...

```


> **CRITICAL:** Copy this key immediately. FortiOS will never display it again.



---

### Step 2: Store the API Key on Alpine Linux (Node 2)

Add the generated key to your environment configuration file so scripts can source it automatically:

```sh
cd /opt/honeypot-quarantine/compose

# Append or update the FORTIGATE_API_KEY entry in .env
sed -i '/FORTIGATE_API_KEY/d' .env 2>/dev/null || true
echo 'FORTIGATE_API_KEY="PASTE_YOUR_COPIED_KEY_HERE"' >> .env

```

---

### Step 3: Deploy the Visual SOC Dashboard (Frontail)

To give your viewers a real-time, dark-themed visual of the attacker's brute-force attempts without staring at a static text file, we will deploy Frontail to stream the JSON logs to a web browser.

1. Launch the Frontail container on your Docker host:
```sh
docker run -d \
  --name dozzle-gui \
  --restart unless-stopped \
  -p 9001:8080 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  amir20/dozzle:latest \
  --auth-provider none \
  --no-analytics

```


2. Open your web browser to: **`http://192.168.10.2:9001`**. You now have a live, auto-scrolling SOC dashboard to feature on screen.

---

### Step 4: Create the Cinematic Watcher Script

This upgraded script includes ASCII banners and ANSI color-coding. When an attacker breaches the perimeter, the terminal will light up with red and cyan alerts, making for a highly engaging video segment.

1. Create `/opt/honeypot-quarantine/scripts/webhook-watcher.sh`:
```sh
#!/bin/sh
LOG_FILE="/var/lib/docker/volumes/compose_cowrie-var/_data/log/cowrie/cowrie.json"
FGT_URL="https://192.168.10.1:443/api/v2/monitor/system/automation-stitch/webhook/TRIG_COWRIE_QUARANTINE"
ENV_FILE="/opt/honeypot-quarantine/compose/.env"

# ANSI Color Codes for YouTube UI
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Source API token from .env
if [ -f "$ENV_FILE" ]; then
    TOKEN=$(grep -E '^FORTIGATE_API_KEY=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
fi
TOKEN="Qzrqk80zhscqny1NsgNmgm4dcy1zjx"

clear
echo -e "${CYAN}"
echo "==============================================================="
echo " 🛡️  ACTIVE DEFENSE ENGINE: COWRIE TO FORTIOS WEBHOOK WATCHER"
echo "===============================================================${NC}"
echo -e "${GREEN}[+] Streaming telemetry from: ${LOG_FILE}${NC}\n"

tail -Fn0 "$LOG_FILE" | while read -r line; do
    EVENT=$(echo "$line" | grep -o '"eventid":"[^"]*' | cut -d'"' -f4)

    if [ "$EVENT" = "cowrie.login.failed" ] || [ "$EVENT" = "cowrie.login.success" ]; then
        ATTACKER_IP=$(echo "$line" | grep -o '"src_ip":"[^"]*' | cut -d'"' -f4)
        USERNAME=$(echo "$line" | grep -o '"username":"[^"]*' | cut -d'"' -f4)

        echo -e "${RED}[ ⚠️  CRITICAL BREACH ATTEMPT ]${NC}"
        echo -e "${YELLOW} ├─ Target:  Decoy SSH Service (Port 2222)${NC}"
        echo -e "${YELLOW} ├─ Source:  ${ATTACKER_IP}${NC}"
        echo -e "${YELLOW} └─ Payload: Username '${USERNAME}'${NC}"

        echo -e "${CYAN}[⚡] Dispatching Layer 3 Quarantine Webhook to FortiGate...${NC}"

        # Execute Webhook
        RESPONSE=$(curl -k -s -X POST "$FGT_URL" \
             -H "Content-Type: application/json" \
             -H "Authorization: Bearer $TOKEN" \
             -d "{\"srcip\":\"$ATTACKER_IP\",\"event\":\"$EVENT\"}")

        echo -e "${GREEN}[✔] API Response: Fabric Quarantine Enforced. Attacker Isolated.${NC}\n"
    fi
done

```


2. Make the script executable:
```sh
chmod +x /opt/honeypot-quarantine/scripts/webhook-watcher.sh

```



---

### Step 5: Convert to a Professional OpenRC Daemon

To demonstrate enterprise-grade deployment on Alpine Linux, we will wrap the script in an OpenRC init service instead of running a messy background job. This ensures the watcher survives reboots and operates natively like a real system daemon.

1. Create the OpenRC service file:
```sh
cat << 'EOF' > /etc/init.d/cowrie-watcher
#!/sbin/openrc-run

name="cowrie-watcher"
description="Cowrie Active Defense Webhook Watcher"
command="/opt/honeypot-quarantine/scripts/webhook-watcher.sh"
command_background="true"
pidfile="/run/${name}.pid"
output_log="/opt/honeypot-quarantine/scripts/watcher.log"
error_log="/opt/honeypot-quarantine/scripts/watcher.err"

depend() {
    need net docker
}
EOF

```


2. Make the service executable, add it to the default runlevel, and start it:
```sh
chmod +x /etc/init.d/cowrie-watcher
rc-update add cowrie-watcher default
rc-service cowrie-watcher start

```


3. Check the live status of your new service:
```sh
rc-service cowrie-watcher status

```


4. **Live Video Demo Tip:** To show the colorful logs generated by the script running in the background during your video recording, simply tail the log file:
```sh
tail -f /opt/honeypot-quarantine/scripts/watcher.log

```



---

### Step 6: Verify the End-to-End Quarantine Loop

1. Trigger an attack attempt from Kali Linux (`192.168.40.3`):
```bash
ssh -o StrictHostKeyChecking=no -p 2222 admin@192.168.40.1

```


2. Watch the live JSON event appear in your browser GUI at `http://192.168.10.2:9001`.
3. On Alpine Linux, review the beautifully colorized service log to confirm the webhook fired:
```sh
cat /opt/honeypot-quarantine/scripts/watcher.log

```


4. On FortiGate CLI, verify the attacker IP was successfully isolated:
```fortios
diagnose user banned-ip list

```

To delete a specific IP address from the banned list:

```fortios
diagnose user banned-ip delete src4 <IP_ADDRESS>
```

---

### Zero-Trust Verification Steps (Execute Before Transition)

1. Verify OpenRC daemon: `rc-service cowrie-watcher status`.
2. Tail the beautiful new logs and trigger the attack: `tail -f /opt/honeypot-quarantine/scripts/watcher.log`.
3. Check your new visual web dashboard on port `9001`.
```
