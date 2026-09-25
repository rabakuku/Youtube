```markdown
<!-- filepath: https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/docs/config-c.md -->
# Stage 5C: Enterprise Active Defense Fabric (Mattermost/Slack ChatOps & TTY Forensics)

This advanced architecture completes the closed-loop incident response fabric. While Tier A handles basic 1:1 triggering and Tier B introduces rate-limiting, Tier C adds automated SecOps collaboration and digital forensics extraction:

1. **Layer 3 Quarantine:** Attacker IP is banned across FortiOS in under 2 seconds.
2. **Local Mattermost Container:** Self-hosted enterprise team messaging server deployed directly on the Docker stack.
3. **Rich ChatOps Dispatch:** Posts interactive incident response cards to Mattermost or Slack with source IP, targeted decoy ports, threat velocity scores, and firewall quarantine state.
4. **Automated TTY Forensics Dumping:** Asynchronously isolates raw terminal keystroke files (`.tty`) captured by Cowrie into a dedicated forensic directory for SOC playback.
5. **OpenRC Native Daemon:** Managed as an Alpine Linux background service (`active-defense`) with start, stop, restart, and status controls.
6. **Dozzle Multi-Pane Integration:** Feeds both ChatOps delivery statuses and forensics engine logs directly into Dozzle for live monitoring.

---

### Incident Response Pipeline Schema

```text
[ Attacker: 192.168.40.3 ]
          │ (Brute-force probe on TCP/2222)
          ▼
[ Cowrie Container ]
          │ (Emulates Linux shell, records session, writes JSON log)
          ▼
[ Active Defense Daemon (OpenRC) ]
          │
          ├──▶ 1. HTTPS POST ──▶ [ FortiOS REST API ] ──▶ (Kernel Banned-IP Table)
          │
          ├──▶ 2. Webhook POST ─▶ [ Mattermost / Slack ] ─▶ (#soc-alerts Channel)
          │
          └──▶ 3. Forensics ───▶ [ /opt/forensics/ ] ────▶ (TTY Keystroke Replay)

```

---

### Step 1: Deploy Mattermost Team Collaboration Server

To establish an on-premise ChatOps incident command center, deploy the official Mattermost container on Node 2 (`192.168.10.2`) bound to port 8065:

1. Launch the Mattermost container:
```sh
docker run -d \
  --name mattermost-server \
  --restart unless-stopped \
  -p 8065:8065 \
  -v mattermost_data:/mm/mattermost-data \
  mattermost/mattermost-preview:latest

```


2. Verify that the service is running and listening:
```sh
docker ps --filter "name=mattermost-server"
ss -tuln | grep -E ':8065'

```


3. Open your browser and navigate to: **`http://192.168.10.2:8065`**.
4. Complete the initial 30-second admin onboarding:
* Create the primary admin account (e.g., `socadmin` / password).
* Create a team name: `SOC-Operations`.
* Create or open the default public channel: `Off-Topic` or create a new channel named `soc-alerts`.



---

### Step 2: Configure the Incoming Webhook

Configure the webhook integration in Mattermost (or Slack) to receive automated threat cards.

#### For Mattermost:

1. In the Mattermost web console, click the **Grid Menu (Top-Left) > Integrations**.
2. Select **Incoming Webhooks > Add Incoming Webhook**.
3. Configure the webhook profile:
* **Title:** `FortiGate Active Defense Fabric`
* **Description:** `Automated Layer 3 quarantine alerts and deception telemetry`
* **Channel:** Select `soc-alerts` (or `Off-Topic`)


4. Click **Save** and copy the generated Webhook URL (format: `http://192.168.10.2:8065/hooks/xxxx...`).

#### For Slack (Alternative):

1. Navigate to **api.slack.com/apps** and open your App.
2. Select **Incoming Webhooks** and toggle **Activate Incoming Webhooks** to ON.
3. Click **Add New Webhook to Workspace**, pick your alert channel, and copy the Webhook URL.

---

### Step 3: Deploy the Advanced Active Defense & Forensics Daemon

Create the comprehensive Python engine that evaluates threat signatures, triggers the FortiOS ban, builds the Mattermost/Slack markdown attachment payload, and archives attacker session forensics.

1. Ensure required Alpine packages are installed:
```sh
apk update
apk add --no-cache python3 py3-requests ca-certificates

```


2. Create the forensic dump storage directory:
```sh
mkdir -p /opt/honeypot-quarantine/forensics

```


3. Create `/opt/honeypot-quarantine/scripts/active_defense_engine.py`:
```python
#!/usr/bin/env python3
import json
import os
import shutil
import sys
import time
from collections import defaultdict
import urllib.request
import ssl

# Target Paths
LOG_FILE = "/var/lib/docker/volumes/compose_cowrie-var/_data/log/cowrie/cowrie.json"
TTY_DIR = "/var/lib/docker/volumes/compose_cowrie-var/_data/lib/cowrie/tty"
FORENSIC_DIR = "/opt/honeypot-quarantine/forensics"
ENV_FILE = "/opt/honeypot-quarantine/compose/.env"
FGT_URL = "[https://192.168.10.1:443/api/v2/monitor/system/automation-stitch/webhook/TRIG_COWRIE_QUARANTINE](https://192.168.10.1:443/api/v2/monitor/system/automation-stitch/webhook/TRIG_COWRIE_QUARANTINE)"

# Terminal Colors
CLR_RED = "\033[1;31m"
CLR_GRN = "\033[1;32m"
CLR_YEL = "\033[1;33m"
CLR_CYN = "\033[1;36m"
CLR_MAG = "\033[1;35m"
CLR_RST = "\033[0m"

# Sourcing Environment Variables from .env
FGT_TOKEN = ""
CHATOPS_WEBHOOK = ""

if os.path.exists(ENV_FILE):
    with open(ENV_FILE, "r") as f:
        for line in f:
            if line.startswith("FORTIGATE_API_KEY="):
                FGT_TOKEN = line.strip().split("=", 1)[1].strip('"\'')
            elif line.startswith("CHATOPS_WEBHOOK_URL="):
                CHATOPS_WEBHOOK = line.strip().split("=", 1)[1].strip('"\'')

# Threshold & Stateful Tracking
HIGH_RISK_USERS = {"root", "admin", "administrator", "support", "cisco", "ubnt"}
FAILED_LOGINS = defaultdict(list)
QUARANTINED_IPS = {}
CAPTURED_SESSIONS = set()

WINDOW_SECONDS = 30
THRESHOLD_FAILS = 3
COOLDOWN_SECONDS = 300

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

def dispatch_chatops_alert(attacker_ip, reason, score, session_id, user_probe):
    if not CHATOPS_WEBHOOK:
        sys.stdout.write(f"{CLR_YEL}[ℹ INFO]{CLR_RST} ChatOps webhook URL not found in .env. Skipping chat alert.\n")
        sys.stdout.flush()
        return

    payload = {
        "username": "Fortinet Active Defense Fabric",
        "icon_emoji": ":shield:",
        "attachments": [
            {
                "color": "#ee2737",
                "title": "🚨 CRITICAL: Perimeter Deception Trap Triggered",
                "text": (
                    f"**Threat Actor Isolated at Layer 3 across FortiOS Security Fabric**\n"
                    f"The rogue client attempted unauthorized authentication against internal decoy services."
                ),
                "fields": [
                    {"title": "Attacker IP", "value": f"`{attacker_ip}`", "short": True},
                    {"title": "Target VIP", "value": "`192.168.40.1:2222` (Cowrie SSH)", "short": True},
                    {"title": "Breach Vector", "value": f"{reason} (User: `{user_probe}`)", "short": True},
                    {"title": "Threat Score", "value": f"`{score}/100` (High)", "short": True},
                    {"title": "Session Identifier", "value": f"`{session_id}`", "short": True},
                    {"title": "Enforcement Action", "value": "`BANNED-IP (Kernel Drop Table)`", "short": True}
                ],
                "footer": "FortiOS 7.4 Security Fabric Automation Engine",
                "ts": int(time.time())
            }
        ]
    }

    try:
        req = urllib.request.Request(
            CHATOPS_WEBHOOK,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            if resp.status in (200, 204):
                sys.stdout.write(f"{CLR_GRN}[✔ CHATOPS]{CLR_RST} Alert card delivered to Mattermost/Slack.\n")
    except Exception as e:
        sys.stdout.write(f"{CLR_RED}[✖ CHATOPS ERROR]{CLR_RST} Failed to deliver ChatOps card: {e}\n")
    sys.stdout.flush()

def archive_forensics(session_id, attacker_ip):
    if not session_id or session_id in CAPTURED_SESSIONS:
        return

    # Look for matching TTY session files
    tty_file = os.path.join(TTY_DIR, f"{session_id}.log")
    if os.path.exists(tty_file):
        dest = os.path.join(FORENSIC_DIR, f"attacker_{attacker_ip}_{session_id}.tty")
        shutil.copyfile(tty_file, dest)
        CAPTURED_SESSIONS.add(session_id)
        sys.stdout.write(f"{CLR_CYN}[🗄 FORENSICS]{CLR_RST} Saved terminal session keystrokes to: {dest}\n")
        sys.stdout.flush()

def trigger_fortigate_quarantine(ip, reason, score, session_id, user_probe):
    now = time.time()
    if ip in QUARANTINED_IPS and (now - QUARANTINED_IPS[ip]) < COOLDOWN_SECONDS:
        sys.stdout.write(f"{CLR_MAG}[⏳ DEDUPLICATED]{CLR_RST} IP {ip} is already banned. Suppressing API burst.\n")
        sys.stdout.flush()
        return

    QUARANTINED_IPS[ip] = now

    sys.stdout.write(f"\n{CLR_RED}================================================================{CLR_RST}\n")
    sys.stdout.write(f"{CLR_RED}[ 🚨 ACTIVE DEFENSE ENGAGED: QUARANTINING {ip} ]{CLR_RST}\n")
    sys.stdout.write(f"{CLR_YEL} ├─ Violation : {CLR_RST}{reason}\n")
    sys.stdout.write(f"{CLR_YEL} ├─ Score     : {CLR_RST}{score}/100\n")
    sys.stdout.write(f"{CLR_YEL} └─ Session ID: {CLR_RST}{session_id}\n")
    sys.stdout.write(f"{CLR_RED}================================================================{CLR_RST}\n")
    sys.stdout.flush()

    # 1. FortiOS Automation Webhook
    cmd = (
        f'curl -k -s -o /dev/null -w "%{{http_code}}" -X POST "{FGT_URL}" '
        f'-H "Content-Type: application/json" '
        f'-H "Authorization: Bearer {FGT_TOKEN}" '
        f'-d \'{{"srcip":"{ip}","event":"cowrie.active_defense.quarantine"}}\''
    )
    http_status = os.popen(cmd).read().strip()

    if http_status == "200":
        sys.stdout.write(f"{CLR_GRN}[✔ FORTIOS]{CLR_RST} Layer 3 quarantine committed to FortiGate kernel.\n")
    else:
        sys.stdout.write(f"{CLR_RED}[✖ FORTIOS ERROR]{CLR_RST} Firewall returned HTTP status: {http_status}\n")

    # 2. Mattermost/Slack ChatOps Notification
    dispatch_chatops_alert(ip, reason, score, session_id, user_probe)

    # 3. Capture TTY Keystroke Forensics
    archive_forensics(session_id, ip)
    sys.stdout.flush()

def process_entry(entry):
    event_id = entry.get("eventid")
    ip = entry.get("src_ip")
    username = entry.get("username", "unknown")
    session_id = entry.get("session", "unknown")

    if not ip or not event_id:
        return

    now = time.time()

    # Check 1: Signature Usernames -> Immediate L3 Isolation & SOC Dispatch
    if username.lower() in HIGH_RISK_USERS:
        trigger_fortigate_quarantine(ip, f"Signature User Target ('{username}')", 100, session_id, username)
        return

    # Check 2: Brute-Force Rate Limiting
    if event_id in ("cowrie.login.failed", "cowrie.command.failed"):
        FAILED_LOGINS[ip] = [t for t in FAILED_LOGINS[ip] if now - t <= WINDOW_SECONDS]
        FAILED_LOGINS[ip].append(now)
        fails = len(FAILED_LOGINS[ip])

        if fails >= THRESHOLD_FAILS:
            trigger_fortigate_quarantine(ip, f"Brute Force ({fails} fails in {WINDOW_SECONDS}s)", 90, session_id, username)
        else:
            sys.stdout.write(f"{CLR_YEL}[⚠ PROBE]{CLR_RST} Tracking probe from {ip} ({fails}/{THRESHOLD_FAILS}) | User: '{username}'\n")
            sys.stdout.flush()

    # Check 3: Check for completed sessions to archive forensic TTYs
    if event_id == "cowrie.session.closed":
        archive_forensics(session_id, ip)

def run():
    sys.stdout.write(f"{CLR_CYN}================================================================{CLR_RST}\n")
    sys.stdout.write(f" 🛡️  ACTIVE DEFENSE SOC FABRIC: ENTERPRISE TIER-C DAEMON        \n")
    sys.stdout.write(f"{CLR_CYN}================================================================{CLR_RST}\n")
    sys.stdout.write(f"{CLR_GRN}[+] Log Source:{CLR_RST} {LOG_FILE}\n")
    sys.stdout.write(f"{CLR_GRN}[+] Forensics Repository:{CLR_RST} {FORENSIC_DIR}\n")
    sys.stdout.write(f"{CLR_GRN}[+] ChatOps Webhook:{CLR_RST} {'Configured' if CHATOPS_WEBHOOK else 'Disabled'}\n\n")
    sys.stdout.flush()

    while not os.path.exists(LOG_FILE):
        time.sleep(1)

    with open(LOG_FILE, "r") as f:
        f.seek(0, 2)
        while True:
            line = f.readline()
            if not line:
                time.sleep(0.2)
                continue
            try:
                data = json.loads(line.strip())
                process_entry(data)
            except json.JSONDecodeError:
                continue

if __name__ == "__main__":
    run()

```


4. Grant execution permissions:
```sh
chmod +x /opt/honeypot-quarantine/scripts/active_defense_engine.py

```



---

### Step 4: Register as an OpenRC Service (`active-defense`)

Stop previous tier services to avoid redundant webhooks, then configure the Tier-C engine under Alpine's OpenRC daemon manager.

1. Stop any earlier watcher or triage services:
```sh
rc-service cowrie-watcher stop 2>/dev/null || true
rc-update del cowrie-watcher default 2>/dev/null || true

rc-service triage-engine stop 2>/dev/null || true
rc-update del triage-engine default 2>/dev/null || true

```


2. Create `/etc/init.d/active-defense`:
```sh
cat << 'EOF' > /etc/init.d/active-defense
#!/sbin/openrc-run

name="active-defense"
description="FortiOS Active Defense & Forensics Daemon"
command="/opt/honeypot-quarantine/scripts/active_defense_engine.py"
command_background="true"
pidfile="/run/${name}.pid"
output_log="/opt/honeypot-quarantine/scripts/active_defense.log"
error_log="/opt/honeypot-quarantine/scripts/active_defense.err"

depend() {
    need net docker
    after cowrie-honeypot
}
EOF

```


3. Enable execute permissions, add to default runlevel, and start the service:
```sh
chmod +x /etc/init.d/active-defense
rc-update add active-defense default
rc-service active-defense start

```


4. Verify status:
```sh
rc-service active-defense status

```


*Expected Output:*
```text
* status: started

```



---

### Step 5: Configure Dozzle Multi-Pane SOC View

Expose the new active defense engine output directly inside the Dozzle Web GUI alongside Cowrie.

1. Remove any legacy monitor containers:
```sh
docker rm -f triage-monitor active-defense-feed 2>/dev/null || true

```


2. Launch the `active-defense-feed` container:
```sh
docker run -d \
  --name active-defense-feed \
  --restart unless-stopped \
  -v /opt/honeypot-quarantine/scripts/active_defense.log:/var/log/active_defense.log:ro \
  alpine:3.24 sh -c "touch /var/log/active_defense.log && tail -F /var/log/active_defense.log"

```


3. Open **`http://192.168.10.2:9001`** in your browser.
4. Select the split-screen view:
* **Pane 1:** `cowrie-honeypot` (Real-time attacker terminal inputs).
* **Pane 2:** `active-defense-feed` (Firewall status, ChatOps confirmations, and Forensics saves).



---

### Step 6: End-to-End Validation & Forensics Replay

1. Clear the banned-ip table on the FortiGate CLI:
```fortios
diagnose user banned-ip clear

```


2. From Kali Linux (`192.168.40.3`), launch an attack targeting the honeypot:
```bash
ssh -o StrictHostKeyChecking=no -p 2222 root@192.168.40.1

```


3. Review the live Dozzle feed on `http://192.168.10.2:9001`.
4. Check your Mattermost or Slack channel: An alert card displays with red banner highlighting IP `192.168.40.3` and reason `Signature User Target ('root')`.
5. Confirm FortiGate Layer 3 isolation:
```fortios
diagnose user banned-ip list

```


*Expected Output:* `192.168.40.3` is active in the quarantine table.
6. Replay the attacker's session from the captured TTY file:
```sh
# List generated forensic dump files
ls -la /opt/honeypot-quarantine/forensics/

# Locate session inside Cowrie and replay keystrokes
docker exec -it cowrie-honeypot playlog /cowrie/cowrie-git/var/lib/cowrie/tty/<session_id>.log

```



```

---

### Zero-Trust Verification Commands (Inspect in Chat Before Transition)

1. **Verify Mattermost Container Listener:**
   ```sh
   docker ps --filter "name=mattermost-server"
   ss -tuln | grep ':8065'

```

*Expected Output:* `mattermost-server` shows status `Up`, and TCP port `8065` is in `LISTEN` state.

2. **Verify OpenRC Service Status:**
```sh
rc-service active-defense status

```


*Expected Output:* `* status: started`.
3. **Verify Alert Delivery & Quarantine State:**
* An attack from `192.168.40.3` posts an alert card in your Mattermost channel.
* `diagnose user banned-ip list` on FortiGate CLI displays `192.168.40.3`.
