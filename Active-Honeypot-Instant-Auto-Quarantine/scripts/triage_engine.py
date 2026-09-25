#!/usr/bin/env python3
import json
import os
import sys
import time
from collections import defaultdict

# Target paths and endpoints
LOG_FILE = "/var/lib/docker/volumes/compose_cowrie-var/_data/log/cowrie/cowrie.json"
FGT_URL = "https://192.168.10.1:443/api/v2/monitor/system/automation-stitch/webhook/TRIG_COWRIE_QUARANTINE"
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
