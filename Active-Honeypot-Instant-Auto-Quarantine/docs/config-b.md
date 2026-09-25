```markdown
<!-- filepath: https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/docs/config-b.md -->
# Stage 5B: Intelligent Triage Engine with Dynamic Rate Limiting & Threat Scoring

While Stage 5A triggers an instant quarantine upon any failed authentication, production enterprise environments require behavioral nuance. Automated scanners or internal users mistyping credentials should not immediately lock down subnets.

This medium-tier architecture replaces simple 1-to-1 alert tailing with an **In-Memory Stateful Triage Daemon (`triage-engine`)**. It evaluates real-time sliding windows, tracks failed authentication velocity, scores high-risk username patterns (`root`, `admin`, `cisco`), suppresses duplicate alerts via cooldown timers, and streams live colorized triage verdicts into the **Dozzle GUI**—all managed as a native **Alpine OpenRC service**.

---

### Triage Logic Matrix

```text
+------------------------+-------------------------------+--------------------------+
| Offense Type           | Condition Trigger             | Action Enforced          |
+------------------------+-------------------------------+--------------------------+
| Instant High-Risk      | User in: root, admin, support | Immediate Webhook Ban    |
| Brute-Force Burst      | >= 3 failed logins in 30 sec  | Rate-Limit Threshold Ban |
| Low-Velocity Scan      | < 3 failed logins in 30 sec   | Monitored (Score Logged) |
| Duplicate Suppression  | Banned IP re-probes < 300 sec | Suppressed (No API Spam) |
+------------------------+-------------------------------+--------------------------+

```

---

### Step 1: Deploy the Python Triage Engine

Create the stateful Python engine script on Node 2 (`192.168.10.2`). This daemon parses structured JSON entries from Cowrie, maintains per-IP temporal timestamp deques, and executes authenticated HTTPS calls to the FortiOS webhook endpoint only when threat thresholds are breached.

1. Install Python prerequisites on Alpine Linux:
```sh
apk update
apk add --no-cache python3 py3-requests

```


2. Create `/opt/honeypot-quarantine/scripts/triage_engine.py`:
```python
#!/usr/bin/env python3
import json
import os
import sys
import time
from collections import defaultdict

# Target paths and endpoints
LOG_FILE = "/var/lib/docker/volumes/compose_cowrie-var/_data/log/cowrie/cowrie.json"
FGT_URL = "[https://192.168.10.1:443/api/v2/monitor/system/automation-stitch/webhook/TRIG_COWRIE_QUARANTINE](https://192.168.10.1:443/api/v2/monitor/system/automation-stitch/webhook/TRIG_COWRIE_QUARANTINE)"
ENV_FILE = "/opt/honeypot-quarantine/compose/.env"

# ANSI Terminal Colors
CLR_RED = "\033[1;31m"
CLR_GRN = "\033[1;32m"
CLR_YEL = "\033[1;33m"
CLR_CYN = "\033[1;36m"
CLR_MAG = "\033[1;35m"
CLR_RST = "\033[0m"

# Dynamic token extraction from .env
TOKEN = ""
if os.path.exists(ENV_FILE):
    with open(ENV_FILE, "r") as f:
        for line in f:
            if line.startswith("FORTIGATE_API_KEY="):
                TOKEN = line.strip().split("=", 1)[1].strip('"\'')

if not TOKEN:
    TOKEN = "PASTE_YOUR_COPIED_KEY_HERE"

# Stateful threat models
HIGH_RISK_USERS = {"root", "admin", "administrator", "support", "cisco", "ubnt", "test"}
FAILED_ATTEMPTS = defaultdict(list)
QUARANTINED_IPS = {}

WINDOW_SECONDS = 30
THRESHOLD_FAILS = 3
COOLDOWN_SECONDS = 300

def log_hud(banner_color, title, fields):
    sys.stdout.write(f"\n{banner_color}[ {title} ]{CLR_RST}\n")
    for k, v in fields.items():
        sys.stdout.write(f"{CLR_YEL} ├─ {k:<10}: {CLR_RST}{v}\n")
    sys.stdout.flush()

def trigger_fortigate_quarantine(ip, reason, score):
    now = time.time()
    if ip in QUARANTINED_IPS and (now - QUARANTINED_IPS[ip]) < COOLDOWN_SECONDS:
        sys.stdout.write(f"{CLR_MAG}[⏳ DEDUPLICATED]{CLR_RST} IP {ip} is already quarantined (Cooldown active).\n")
        sys.stdout.flush()
        return

    QUARANTINED_IPS[ip] = now
    log_hud(CLR_RED, "CRITICAL THREAT: QUARANTINE DISPATCHED", {
        "Attacker": ip,
        "Violation": reason,
        "Score": f"{score}/100",
        "Target": "FortiGate Kernel Drop Table"
    })

    cmd = (
        f'curl -k -s -o /dev/null -w "%{{http_code}}" -X POST "{FGT_URL}" '
        f'-H "Content-Type: application/json" '
        f'-H "Authorization: Bearer {TOKEN}" '
        f'-d \'{{"srcip":"{ip}","event":"cowrie.triage.quarantine"}}\''
    )

    http_status = os.popen(cmd).read().strip()
    if http_status == "200":
        sys.stdout.write(f"{CLR_GRN}[✔ SUCCESS]{CLR_RST} FortiOS Fabric Stitch executed. Layer 3 ban applied.\n\n")
    else:
        sys.stdout.write(f"{CLR_RED}[✖ REJECTED]{CLR_RST} FortiOS API responded with HTTP {http_status}.\n\n")
    sys.stdout.flush()

def process_entry(entry):
    event_id = entry.get("eventid")
    ip = entry.get("src_ip")
    username = entry.get("username", "")

    if not ip or not event_id:
        return

    now = time.time()

    # Instant-quarantine on signature accounts
    if username.lower() in HIGH_RISK_USERS:
        trigger_fortigate_quarantine(ip, f"Signature Breach: Probed credential '{username}'", 100)
        return

    # Sliding-window rate limit evaluation
    if event_id in ("cowrie.login.failed", "cowrie.command.failed"):
        FAILED_ATTEMPTS[ip] = [t for t in FAILED_ATTEMPTS[ip] if now - t <= WINDOW_SECONDS]
        FAILED_ATTEMPTS[ip].append(now)
        fails = len(FAILED_ATTEMPTS[ip])

        if fails >= THRESHOLD_FAILS:
            trigger_fortigate_quarantine(ip, f"Brute-Force Threshold: {fails} fails in {WINDOW_SECONDS}s", 85)
        else:
            log_hud(CLR_CYN, "SUSPICIOUS PROBE DETECTED", {
                "Source": ip,
                "Attempt": f"{fails}/{THRESHOLD_FAILS}",
                "Username": username,
                "Action": "Tracking sliding-window velocity"
            })

def run():
    sys.stdout.write(f"{CLR_CYN}================================================================{CLR_RST}\n")
    sys.stdout.write(f" 🛡️  FORTINET SECURITY FABRIC: INTELLIGENT TRIAGE DAEMON        \n")
    sys.stdout.write(f"{CLR_CYN}================================================================{CLR_RST}\n")
    sys.stdout.write(f"{CLR_GRN}[+] Monitoring honeypot log stream:{CLR_RST} {LOG_FILE}\n")
    sys.stdout.write(f"{CLR_GRN}[+] Sliding Window:{CLR_RST} {WINDOW_SECONDS}s | {CLR_GRN}Threshold:{CLR_RST} {THRESHOLD_FAILS} attempts\n\n")
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


3. Make the script executable:
```sh
chmod +x /opt/honeypot-quarantine/scripts/triage_engine.py

```



---

### Step 2: Register as a Native OpenRC Service (`triage-engine`)

Wrap the Python triage script into an OpenRC daemon definition. This gives you exact start, stop, restart, and status lifecycle commands on Alpine Linux without messy terminal multiplexers.

1. Stop the Stage 5A basic watcher service to prevent overlapping API calls:
```sh
rc-service cowrie-watcher stop 2>/dev/null || true
rc-update del cowrie-watcher default 2>/dev/null || true

```


2. Create `/etc/init.d/triage-engine`:
```sh
cat << 'EOF' > /etc/init.d/triage-engine
#!/sbin/openrc-run

name="triage-engine"
description="Cowrie Intelligent Triage and Quarantine Service"
command="/opt/honeypot-quarantine/scripts/triage_engine.py"
command_background="true"
pidfile="/run/${name}.pid"
output_log="/opt/honeypot-quarantine/scripts/triage.log"
error_log="/opt/honeypot-quarantine/scripts/triage.err"

depend() {
    need net docker
    after cowrie-honeypot
}
EOF

```


3. Enable execute permissions, register the service to boot, and start the daemon:
```sh
chmod +x /etc/init.d/triage-engine
rc-update add triage-engine default
rc-service triage-engine start

```


4. Verify service health:
```sh
rc-service triage-engine status

```


*Expected Output:*
```text
* status: started

```



---

### Step 3: Stream Triage Telemetry Live in Dozzle

To view both the raw Cowrie honeypot logs and the Triage Engine decisions side-by-side in your visual web console, deploy a lightweight log-streamer container that targets the triage log output.

1. Confirm Dozzle is running with login disabled:
```sh
docker run -d \
  --name dozzle-gui \
  --restart unless-stopped \
  -p 9001:8080 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  amir20/dozzle:latest \
  --auth-provider none \
  --no-analytics 2>/dev/null || true

```


2. Spin up the companion `triage-monitor` container:
```sh
docker run -d \
  --name triage-monitor \
  --restart unless-stopped \
  -v /opt/honeypot-quarantine/scripts/triage.log:/var/log/triage.log:ro \
  alpine:3.24 sh -c "touch /var/log/triage.log && tail -F /var/log/triage.log"

```


3. Open **`http://192.168.10.2:9001`** in your browser.
4. Use Dozzle's split-screen button (top-right) to display:
* **Left Pane:** `cowrie-honeypot` (Raw attacker session interaction).
* **Right Pane:** `triage-monitor` (Real-time threshold calculations and FortiOS API responses).



---

### Step 4: Verification & Diagnostic Scenarios

Run these two distinct attack vectors from Node 3 (`192.168.40.3`) to prove behavioral triage accuracy:

#### Scenario A: The Single Mistyped Credential (No Quarantine)

1. Clear the quarantine table on FortiGate CLI:
```fortios
diagnose user banned-ip clear

```


2. On Kali (`192.168.40.3`), attempt a single login with a standard user:
```bash
ssh -o StrictHostKeyChecking=no -p 2222 employee@192.168.40.1

```


3. Inspect `triage.log` on Alpine:
```sh
tail -n 10 /opt/honeypot-quarantine/scripts/triage.log

```


*Result:* Log displays `[ SUSPICIOUS PROBE DETECTED ] Attempt 1/3`.
4. Inspect FortiGate CLI:
```fortios
diagnose user banned-ip list

```


*Result:* Table remains empty. The user is not banned.

#### Scenario B: Signature Trigger / Threshold Breach (Instant Quarantine)

1. On Kali (`192.168.40.3`), launch an attempt using the reserved `root` user:
```bash
ssh -o StrictHostKeyChecking=no -p 2222 root@192.168.40.1

```


2. Watch the Dozzle stream immediately flash `CRITICAL THREAT: QUARANTINE DISPATCHED`.
3. Verify the IP is committed to the FortiOS drop table:
```fortios
diagnose user banned-ip list

```


*Result:* `192.168.40.3` is quarantined in under 2 seconds.

```

---

### Zero-Trust Verification Commands (Inspect in Chat Before Transition)

1. Verify OpenRC service status:
   ```sh
   rc-service triage-engine status

```

2. Verify Dozzle multi-container monitoring on port 9001:
```sh
docker ps --filter "name=triage-monitor" --filter "name=dozzle-gui"

```


3. Verify behavioral difference:
* A single login with an unknown name logs a warning.
* Probing `root` or sending 3 failed attempts in 30 seconds injects the IP into `diagnose user banned-ip list`.



