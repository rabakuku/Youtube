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

# Sourcing Environment Variables
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
    if not CHATOPS_WEBHOOK or "your-mattermost" in CHATOPS_WEBHOOK:
        sys.stdout.write(f"{CLR_YEL}[ℹ INFO]{CLR_RST} ChatOps webhook URL not configured. Skipping chat alert.\n")
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
