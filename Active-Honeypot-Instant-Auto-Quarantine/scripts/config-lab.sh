#!/bin/sh
# filepath: https://github.com/rabakuku/Youtube/tree/main/Active-Honeypot-Instant-Auto-Quarantine/scripts/config-lab.sh
set -e

REPO_BASE="https://raw.githubusercontent.com/rabakuku/Youtube/main/Active-Honeypot-Instant-Auto-Quarantine"
BASE_DIR="/opt/honeypot-quarantine"
SCRIPTS_DIR="${BASE_DIR}/scripts"
COMPOSE_DIR="${BASE_DIR}/compose"
ENV_FILE="${COMPOSE_DIR}/.env"
FORENSICS_DIR="${BASE_DIR}/forensics"

# UI Color Codes
CLR_RED="\033[1;31m"
CLR_GRN="\033[1;32m"
CLR_YEL="\033[1;33m"
CLR_CYN="\033[1;36m"
CLR_MAG="\033[1;35m"
CLR_RST="\033[0m"

# -------------------------------------------------------------
# System & Pre-Flight Validation Checks
# -------------------------------------------------------------
assert_alpine() {
    if [ ! -f /etc/os-release ]; then
        printf "${CLR_RED}[✖ FATAL ERROR] /etc/os-release not found. Target OS is not Alpine Linux.${CLR_RST}\n"
        exit 1
    fi
    . /etc/os-release
    if [ "$ID" != "alpine" ]; then
        printf "${CLR_RED}[✖ FATAL ERROR] Incompatible OS: %s. This lab orchestrator requires Alpine Linux.${CLR_RST}\n" "$ID"
        exit 1
    fi
}

check_dependencies() {
    MISSING=""
    for pkg in curl docker docker-cli-compose iproute2 grep ca-certificates; do
        if ! apk info -e "$pkg" >/dev/null 2>&1; then
            MISSING="$MISSING $pkg"
        fi
    done

    if [ -n "$MISSING" ]; then
        printf "${CLR_YEL}[!] Installing missing system packages:%s...${CLR_RST}\n" "$MISSING"
        apk update
        apk add --no-cache $MISSING
    fi

    if ! rc-service docker status >/dev/null 2>&1; then
        printf "${CLR_YEL}[!] Docker service stopped. Starting via OpenRC...${CLR_RST}\n"
        rc-update add docker default 2>/dev/null || true
        rc-service docker start
    fi
}

check_python_dependencies() {
    MISSING_PY=""
    for pkg in python3 py3-requests; do
        if ! apk info -e "$pkg" >/dev/null 2>&1; then
            MISSING_PY="$MISSING_PY $pkg"
        fi
    done
    if [ -n "$MISSING_PY" ]; then
        printf "${CLR_YEL}[!] Installing Python runtime dependencies:%s...${CLR_RST}\n" "$MISSING_PY"
        apk add --no-cache $MISSING_PY
    fi
}

check_api_key() {
    if [ ! -f "$ENV_FILE" ]; then
        printf "${CLR_RED}[✖ ERROR] Environment file %s does not exist.${CLR_RST}\n" "$ENV_FILE"
        printf "${CLR_YEL}[!] Please run setup.sh first or create %s.${CLR_RST}\n" "$ENV_FILE"
        exit 1
    fi

    TOKEN=$(grep -E '^FORTIGATE_API_KEY=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    if [ -z "$TOKEN" ] || [ "$TOKEN" = "PASTE_YOUR_COPIED_KEY_HERE" ]; then
        printf "${CLR_RED}[✖ WARNING] FORTIGATE_API_KEY is missing or invalid in %s.${CLR_RST}\n" "$ENV_FILE"
        printf "Enter your FortiGate API Token (from 'execute api-user generate-key'): "
        read -r INPUT_TOKEN
        if [ -n "$INPUT_TOKEN" ]; then
            sed -i '/FORTIGATE_API_KEY/d' "$ENV_FILE" 2>/dev/null || true
            echo "FORTIGATE_API_KEY=\"$INPUT_TOKEN\"" >> "$ENV_FILE"
            printf "${CLR_GRN}[✔] API Key saved to %s.${CLR_RST}\n" "$ENV_FILE"
        else
            printf "${CLR_RED}[✖] Cannot proceed without a valid FortiGate API token.${CLR_RST}\n"
            exit 1
        fi
    fi
}

verify_or_download_file() {
    TARGET_PATH="$1"
    REMOTE_URL="$2"
    FILE_LABEL="$3"

    if [ ! -f "$TARGET_PATH" ]; then
        printf "${CLR_YEL}[↓] Missing %s. Downloading from repository...${CLR_RST}\n" "$FILE_LABEL"
        mkdir -p "$(dirname "$TARGET_PATH")"
        if ! curl -fsSL "$REMOTE_URL" -o "$TARGET_PATH"; then
            printf "${CLR_RED}[✖ ERROR] Failed to download %s from: %s${CLR_RST}\n" "$FILE_LABEL" "$REMOTE_URL"
            printf "${CLR_RED}[!] Verify network reachability and repository file path.${CLR_RST}\n"
            exit 1
        fi
        printf "${CLR_GRN}[✔] Successfully retrieved %s.${CLR_RST}\n" "$FILE_LABEL"
    fi
    chmod +x "$TARGET_PATH" 2>/dev/null || true
}

ensure_cowrie_running() {
    if ! docker ps --filter "name=cowrie-honeypot" --format '{{.Names}}' | grep -q "cowrie-honeypot"; then
        printf "${CLR_YEL}[!] Cowrie honeypot container is not running. Launching compose stack...${CLR_RST}\n"
        if [ -d "$COMPOSE_DIR" ] && [ -f "${COMPOSE_DIR}/docker-compose.yml" ]; then
            cd "$COMPOSE_DIR" && docker compose up -d
        else
            printf "${CLR_RED}[✖ ERROR] Compose file missing in %s. Run setup.sh first.${CLR_RST}\n" "$COMPOSE_DIR"
            exit 1
        fi
    fi
}

ensure_dozzle_running() {
    if ! docker ps --filter "name=dozzle-gui" --format '{{.Names}}' | grep -q "dozzle-gui"; then
        printf "${CLR_CYN}[+] Deploying Dozzle Real-Time Log GUI container...${CLR_RST}\n"
        docker rm -f dozzle-gui 2>/dev/null || true
        docker run -d \
            --name dozzle-gui \
            --restart unless-stopped \
            -p 9001:8080 \
            -v /var/run/docker.sock:/var/run/docker.sock:ro \
            amir20/dozzle:latest \
            --auth-provider none \
            --no-analytics >/dev/null
    fi
}

stop_all_daemons() {
    rc-service cowrie-watcher stop 2>/dev/null || true
    rc-update del cowrie-watcher default 2>/dev/null || true
    rc-service triage-engine stop 2>/dev/null || true
    rc-update del triage-engine default 2>/dev/null || true
    rc-service active-defense stop 2>/dev/null || true
    rc-update del active-defense default 2>/dev/null || true
    docker rm -f triage-monitor active-defense-feed 2>/dev/null || true
}

# -------------------------------------------------------------
# CONFIG-A: Basic Setup & Teardown
# -------------------------------------------------------------
setup_config_a() {
    printf "${CLR_CYN}================================================================${CLR_RST}\n"
    printf "${CLR_CYN}   CONFIG-A: DEPLOYING BASIC ACTIVE DEFENSE WATCHER             ${CLR_RST}\n"
    printf "${CLR_CYN}================================================================${CLR_RST}\n"
    
    assert_alpine
    check_dependencies
    check_api_key
    ensure_cowrie_running
    stop_all_daemons

    SCRIPT_PATH="${SCRIPTS_DIR}/webhook-watcher.sh"
    REMOTE_URL="${REPO_BASE}/scripts/webhook-watcher.sh"
    verify_or_download_file "$SCRIPT_PATH" "$REMOTE_URL" "webhook-watcher.sh"

    TOKEN=$(grep -E '^FORTIGATE_API_KEY=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    sed -i "s/PASTE_YOUR_COPIED_KEY_HERE/$TOKEN/g" "$SCRIPT_PATH" 2>/dev/null || true

    printf "${CLR_CYN}[+] Registering /etc/init.d/cowrie-watcher OpenRC daemon...${CLR_RST}\n"
    cat << EOF > /etc/init.d/cowrie-watcher
#!/sbin/openrc-run
name="cowrie-watcher"
description="Cowrie Basic Webhook Watcher Daemon"
command="${SCRIPT_PATH}"
command_background="true"
pidfile="/run/\${name}.pid"
output_log="${SCRIPTS_DIR}/watcher.log"
error_log="${SCRIPTS_DIR}/watcher.err"

depend() {
    need net docker
}
EOF
    chmod +x /etc/init.d/cowrie-watcher
    rc-update add cowrie-watcher default
    rc-service cowrie-watcher restart

    ensure_dozzle_running

    printf "\n${CLR_GRN}================================================================${CLR_RST}\n"
    printf "${CLR_GRN}[✔] CONFIG-A SUCCESSFULLY ACTIVATED!${CLR_RST}\n"
    printf "${CLR_GRN}================================================================${CLR_RST}\n"
    printf "${CLR_YEL} ├─ Service Name       :${CLR_RST} cowrie-watcher (OpenRC Daemon)\n"
    printf "${CLR_YEL} ├─ Service Status     :${CLR_RST} %s\n" "$(rc-service cowrie-watcher status)"
    printf "${CLR_YEL} ├─ Honeypot Decoy Port:${CLR_RST} TCP 2222 (Forwarded from FortiGate VIP 192.168.40.1:2222)\n"
    printf "${CLR_YEL} ├─ Visual SOC GUI     :${CLR_RST} http://192.168.10.2:9001 (Dozzle Log Streamer)\n"
    printf "${CLR_YEL} └─ Local Service Log  :${CLR_RST} %s/watcher.log\n" "$SCRIPTS_DIR"
    printf "\n${CLR_CYN}[TEST & VERIFY STEP]:${CLR_RST}\n"
    printf " 1. From Kali (${CLR_MAG}192.168.40.3${CLR_RST}), run: ${CLR_GRN}ssh -o StrictHostKeyChecking=no -p 2222 testuser@192.168.40.1${CLR_RST}\n"
    printf " 2. Open Dozzle: ${CLR_GRN}http://192.168.10.2:9001${CLR_RST} and select ${CLR_CYN}cowrie-honeypot${CLR_RST}\n"
    printf " 3. Stream watcher output: ${CLR_GRN}tail -f %s/watcher.log${CLR_RST}\n" "$SCRIPTS_DIR"
    printf " 4. Check FortiGate L3 isolation: ${CLR_GRN}diagnose user banned-ip list${CLR_RST}\n\n"
}

teardown_config_a() {
    printf "${CLR_YEL}[+] Decommissioning Config-A components...${CLR_RST}\n"
    rc-service cowrie-watcher stop 2>/dev/null || true
    rc-update del cowrie-watcher default 2>/dev/null || true
    rm -f /etc/init.d/cowrie-watcher
    docker rm -f dozzle-gui 2>/dev/null || true
    printf "${CLR_GRN}[✔] Config-A torn down successfully.${CLR_RST}\n"
}

# -------------------------------------------------------------
# CONFIG-B: Medium Triage Setup & Teardown
# -------------------------------------------------------------
setup_config_b() {
    printf "${CLR_CYN}================================================================${CLR_RST}\n"
    printf "${CLR_CYN}   CONFIG-B: DEPLOYING INTELLIGENT STATEFUL TRIAGE ENGINE       ${CLR_RST}\n"
    printf "${CLR_CYN}================================================================${CLR_RST}\n"

    assert_alpine
    check_dependencies
    check_python_dependencies
    check_api_key
    ensure_cowrie_running
    stop_all_daemons

    SCRIPT_PATH="${SCRIPTS_DIR}/triage_engine.py"
    REMOTE_URL="${REPO_BASE}/scripts/triage_engine.py"
    verify_or_download_file "$SCRIPT_PATH" "$REMOTE_URL" "triage_engine.py"

    TOKEN=$(grep -E '^FORTIGATE_API_KEY=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    sed -i "s/PASTE_YOUR_COPIED_KEY_HERE/$TOKEN/g" "$SCRIPT_PATH" 2>/dev/null || true

    printf "${CLR_CYN}[+] Registering /etc/init.d/triage-engine OpenRC daemon...${CLR_RST}\n"
    cat << EOF > /etc/init.d/triage-engine
#!/sbin/openrc-run
name="triage-engine"
description="Cowrie Intelligent Triage and Quarantine Service"
command="${SCRIPT_PATH}"
command_background="true"
pidfile="/run/\${name}.pid"
output_log="${SCRIPTS_DIR}/triage.log"
error_log="${SCRIPTS_DIR}/triage.err"

depend() {
    need net docker
}
EOF
    chmod +x /etc/init.d/triage-engine
    rc-update add triage-engine default
    rc-service triage-engine restart

    ensure_dozzle_running

    docker rm -f triage-monitor 2>/dev/null || true
    touch "${SCRIPTS_DIR}/triage.log"
    docker run -d \
        --name triage-monitor \
        --restart unless-stopped \
        -v "${SCRIPTS_DIR}/triage.log":/var/log/triage.log:ro \
        alpine:3.24 sh -c "tail -F /var/log/triage.log" >/dev/null

    printf "\n${CLR_GRN}================================================================${CLR_RST}\n"
    printf "${CLR_GRN}[✔] CONFIG-B SUCCESSFULLY ACTIVATED!${CLR_RST}\n"
    printf "${CLR_GRN}================================================================${CLR_RST}\n"
    printf "${CLR_YEL} ├─ Service Name       :${CLR_RST} triage-engine (OpenRC Daemon)\n"
    printf "${CLR_YEL} ├─ Service Status     :${CLR_RST} \%s\n" "$(rc-service triage-engine status)"
    printf "${CLR_YEL} ├─ Threshold Policy   :${CLR_RST} >=3 failed attempts in 30s OR Instant Root/Admin Ban\n"
    printf "${CLR_YEL} ├─ Verification Engine:${CLR_RST} Live FortiOS Banned-IP Table Polling\n"
    printf "${CLR_YEL} ├─ Visual SOC GUI     :${CLR_RST} http://192.168.10.2:9001 (Dozzle Split View)\n"
    printf "${CLR_YEL} └─ Local Service Log  :${CLR_RST} \%s/triage.log\n" "$SCRIPTS_DIR"
    printf "\n${CLR_CYN}[TEST & VERIFY STEP]:${CLR_RST}\n"
    printf " 1. Normal Single Probe (No Ban): ${CLR_GRN}ssh -o StrictHostKeyChecking=no -p 2222 employee@192.168.40.1${CLR_RST}\n"
    printf " 2. Instant Signature Ban:       ${CLR_GRN}ssh -o StrictHostKeyChecking=no -p 2222 root@192.168.40.1${CLR_RST}\n"
    printf " 3. Split-Screen View:           Open ${CLR_GRN}http://192.168.10.2:9001${CLR_RST} (cowrie-honeypot + triage-monitor)\n"
    printf " 4. Check FortiGate L3 isolation:${CLR_GRN}diagnose user banned-ip list${CLR_RST}\n\n"
}

teardown_config_b() {
    printf "${CLR_YEL}[+] Decommissioning Config-B components...${CLR_RST}\n"
    rc-service triage-engine stop 2>/dev/null || true
    rc-update del triage-engine default 2>/dev/null || true
    rm -f /etc/init.d/triage-engine
    docker rm -f triage-monitor dozzle-gui 2>/dev/null || true
    printf "${CLR_GRN}[✔] Config-B torn down successfully.${CLR_RST}\n"
}

# -------------------------------------------------------------
# CONFIG-C: Advanced Active Defense Setup & Teardown (Option 1)
# -------------------------------------------------------------
setup_config_c() {
    printf "${CLR_CYN}================================================================${CLR_RST}\n"
    printf "${CLR_CYN}   CONFIG-C: DEPLOYING ENTERPRISE CHATOPS & FORENSICS FABRIC${CLR_RST}\n"
    printf "${CLR_CYN}================================================================${CLR_RST}\n"

    assert_alpine
    check_dependencies
    check_python_dependencies
    check_api_key
    ensure_cowrie_running
    stop_all_daemons

    mkdir -p "$FORENSICS_DIR"

    # Step 1: Deploy Mattermost Container
    if ! docker ps --filter "name=mattermost-server" --format '{{.Names}}' | grep -q "mattermost-server"; then
        printf "${CLR_CYN}[+] Deploying on-premise Mattermost server container...${CLR_RST}\n"
        docker run -d \
            --name mattermost-server \
            --restart unless-stopped \
            -p 8065:8065 \
            -v mattermost_data:/mm/mattermost-data \
            mattermost/mattermost-preview:latest >/dev/null
    else
        printf "${CLR_GRN}[✔] Mattermost container already exists and is running.${CLR_RST}\n"
    fi

    # Step 2: Poll Port 8065 until Mattermost is responsive
    printf "${CLR_CYN}[*] Waiting for Mattermost HTTP socket (port 8065) to become responsive...${CLR_RST}\n"
    ATTEMPTS=0
    MAX_ATTEMPTS=60
    while ! curl -s -I http://127.0.0.1:8065 >/dev/null 2>&1; do
        ATTEMPTS=$((ATTEMPTS + 1))
        if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
            printf "${CLR_RED}[✖ ERROR] Timed out waiting for Mattermost to start on port 8065.${CLR_RST}\n"
            printf "${CLR_RED}[!] Inspect container logs: docker logs mattermost-server${CLR_RST}\n"
            exit 1
        fi
        printf "."
        sleep 2
    done
    printf "${CLR_GRN} ONLINE!${CLR_RST}\n"

    # Step 3: Guided In-Flight Onboarding Prompt
    CHATOPS_URL=$(grep -E '^CHATOPS_WEBHOOK_URL=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    if [ -z "$CHATOPS_URL" ] \vert{}\vert{} [ "$CHATOPS_URL" = "https://your-mattermost-or-slack-webhook-url-here" ]; then
        printf "\n${CLR_MAG}======================================================================${CLR_RST}\n"
        printf "${CLR_MAG}       MATTERMOST INCOMING WEBHOOK ONBOARDING (STAGE PAUSE)${CLR_RST}\n"
        printf "${CLR_MAG}======================================================================${CLR_RST}\n"
        printf "${CLR_YEL}[1] Open your browser to: ${CLR_GRN}http://192.168.10.2:8065${CLR_RST}\n"
        printf "${CLR_YEL}[2] Create initial admin user (e.g. 'socadmin') and team 'SOC-Operations'.${CLR_RST}\n"
        printf "${CLR_YEL}[3] Navigate to: Grid Menu (Top-Left) > Integrations > Incoming Webhooks.${CLR_RST}\n"
        printf "${CLR_YEL}[4] Click 'Add Incoming Webhook', select your channel, and click Save.${CLR_RST}\n"
        printf "${CLR_YEL}[5] Copy the generated webhook URL (http://192.168.10.2:8065/hooks/xxxx...)${CLR_RST}\n"
        printf "${CLR_MAG}----------------------------------------------------------------------${CLR_RST}\n"
        
        VALID_URL=""
        while [ -z "$VALID_URL" ]; do
            printf "Paste your Mattermost or Slack Webhook URL: "
            read -r INPUT_CHATOPS
            if [ -n "$INPUT_CHATOPS" ]; then
                VALID_URL="$INPUT_CHATOPS"
                sed -i '/CHATOPS_WEBHOOK_URL/d' "$ENV_FILE" 2>/dev/null || true
                echo "CHATOPS_WEBHOOK_URL=\"$VALID_URL\"" >> "$ENV_FILE"
                printf "${CLR_GRN}[✔] Webhook URL saved to %s.${CLR_RST}\n" "$ENV_FILE"
            else
                printf "${CLR_RED}[!] Webhook URL cannot be blank for Tier C.${CLR_RST}\n"
            fi
        done
        printf "${CLR_MAG}======================================================================${CLR_RST}\n\n"
    else
        printf "${CLR_GRN}[✔] Using existing ChatOps Webhook URL from %s.${CLR_RST}\n" "$ENV_FILE"
    fi

    # Step 4: Deploy Active Defense Engine with Dynamic FortiOS State Checking
    SCRIPT_PATH="${SCRIPTS_DIR}/active_defense_engine.py"
    
    printf "${CLR_CYN}[+] Writing active_defense_engine.py with live FortiOS state checking...${CLR_RST}\n"
    cat << 'EOF' > "$SCRIPT_PATH"
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
FGT_URL = "https://192.168.10.1:443/api/v2/monitor/system/automation-stitch/webhook/TRIG_COWRIE_QUARANTINE"
FGT_CHECK_URL = "https://192.168.10.1:443/api/v2/monitor/user/banned-ip"

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

def is_ip_banned_on_firewall(ip):
    """Reach out to FortiOS REST API to confirm if the IP is actively quarantined."""
    if not FGT_TOKEN:
        return False
    try:
        req = urllib.request.Request(
            FGT_CHECK_URL,
            headers={
                "Authorization": f"Bearer {FGT_TOKEN}",
                "Content-Type": "application/json"
            }
        )
        with urllib.request.urlopen(req, context=ctx, timeout=3) as resp:
            if resp.status == 200:
                data = json.loads(resp.read().decode("utf-8"))
                results = data.get("results", [])
                for entry in results:
                    if entry.get("ip_address") == ip or entry.get("ip") == ip or entry.get("srcip") == ip:
                        return True
    except Exception:
        # Fallback to local memory if check endpoint fails
        return False
    return False

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
    
    tty_file = os.path.join(TTY_DIR, f"{session_id}.log")
    if os.path.exists(tty_file):
        dest = os.path.join(FORENSIC_DIR, f"attacker_{attacker_ip}_{session_id}.tty")
        shutil.copyfile(tty_file, dest)
        CAPTURED_SESSIONS.add(session_id)
        sys.stdout.write(f"{CLR_CYN}[🗄 FORENSICS]{CLR_RST} Saved terminal session keystrokes to: {dest}\n")
        sys.stdout.flush()

def trigger_fortigate_quarantine(ip, reason, score, session_id, user_probe):
    now = time.time()
    
    # Live verification: Check if firewall actually holds the IP in its banned-ip list
    if ip in QUARANTINED_IPS:
        if (now - QUARANTINED_IPS[ip]) < COOLDOWN_SECONDS:
            if is_ip_banned_on_firewall(ip):
                sys.stdout.write(f"{CLR_MAG}[⏳ DEDUPLICATED]{CLR_RST} IP {ip} is actively quarantined on FortiGate. Suppressing API burst.\n")
                sys.stdout.flush()
                return
            else:
                sys.stdout.write(f"{CLR_CYN}[🔄 SYNC DETECTED]{CLR_RST} IP {ip} was removed from FortiGate banned-ip list. Re-quarantining...\n")
                sys.stdout.flush()

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
    sys.stdout.write(f"{CLR_GRN}[+] Ban Sync Check:{CLR_RST} Live FortiOS API Polling Enabled\n")
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
EOF
    chmod +x "$SCRIPT_PATH"

    printf "${CLR_CYN}[+] Registering /etc/init.d/active-defense OpenRC daemon...${CLR_RST}\n"
    cat << EOF > /etc/init.d/active-defense
#!/sbin/openrc-run
name="active-defense"
description="FortiOS Active Defense & Forensics Daemon"
command="${SCRIPT_PATH}"
command_background="true"
pidfile="/run/\${name}.pid"
output_log="${SCRIPTS_DIR}/active_defense.log"
error_log="${SCRIPTS_DIR}/active_defense.err"

depend() {
    need net docker
}
EOF
    chmod +x /etc/init.d/active-defense
    rc-update add active-defense default
    rc-service active-defense restart

    ensure_dozzle_running

    docker rm -f active-defense-feed 2>/dev/null || true
    touch "${SCRIPTS_DIR}/active_defense.log"
    docker run -d \
        --name active-defense-feed \
        --restart unless-stopped \
        -v "${SCRIPTS_DIR}/active_defense.log":/var/log/active_defense.log:ro \
        alpine:3.24 sh -c "tail -F /var/log/active_defense.log" >/dev/null

    printf "\n${CLR_GRN}================================================================${CLR_RST}\n"
    printf "${CLR_GRN}[✔] CONFIG-C SUCCESSFULLY ACTIVATED!${CLR_RST}\n"
    printf "${CLR_GRN}================================================================${CLR_RST}\n"
    printf "${CLR_YEL} ├─ Service Name        :${CLR_RST} active-defense (OpenRC Daemon)\n"
    printf "${CLR_YEL} ├─ Service Status      :${CLR_RST} \%s\n" "$(rc-service active-defense status)"
    printf "${CLR_YEL} ├─ Mattermost Portal   :${CLR_RST} http://192.168.10.2:8065 (Port 8065)\n"
    printf "${CLR_YEL} ├─ Visual SOC GUI      :${CLR_RST} http://192.168.10.2:9001 (Port 9001, Dozzle Multi-Feed)\n"
    printf "${CLR_YEL} ├─ Ban Verification    :${CLR_RST} Live FortiOS Banned-IP Table Polling\n"
    printf "${CLR_YEL} ├─ Forensics Directory :${CLR_RST} \%s\n" "$FORENSICS_DIR"
    printf "${CLR_YEL} └─ Local Service Log   :${CLR_RST} \%s/active_defense.log\n" "$SCRIPTS_DIR"
    printf "\n${CLR_CYN}[TEST & VERIFY STEP]:${CLR_RST}\n"
    printf " 1. Attack from Kali:    ${CLR_GRN}ssh -o StrictHostKeyChecking=no -p 2222 root@192.168.40.1${CLR_RST}\n"
    printf " 2. Inspect Mattermost:  Check incoming card alert at ${CLR_GRN}http://192.168.10.2:8065${CLR_RST}\n"
    printf " 3. Verify FortiGate:    ${CLR_GRN}diagnose user banned-ip list${CLR_RST}\n"
    printf " 4. Delete IP on FGT:    ${CLR_GRN}diagnose user banned-ip delete src4 192.168.40.3${CLR_RST}\n"
    printf " 5. Attack again:        Re-quarantines immediately with [🔄 SYNC DETECTED]\n"
    printf " 6. Check Keystrokes:    ${CLR_GRN}ls -la %s${CLR_RST}\n\n" "$FORENSICS_DIR"
}

teardown_config_c() {
    printf "${CLR_YEL}[+] Decommissioning Config-C components...${CLR_RST}\n"
    rc-service active-defense stop 2>/dev/null || true
    rc-update del active-defense default 2>/dev/null || true
    rm -f /etc/init.d/active-defense
    docker rm -f active-defense-feed dozzle-gui mattermost-server 2>/dev/null || true
    printf "${CLR_GRN}[✔] Config-C torn down successfully.${CLR_RST}\n"
}

# -------------------------------------------------------------
# STATUS: Full Environment Inspection
# -------------------------------------------------------------
show_status() {
    printf "${CLR_CYN}================================================================${CLR_RST}\n"
    printf "${CLR_CYN}       ACTIVE HONEYPOT LAB: COMPONENT STATUS INSPECTION${CLR_RST}\n"
    printf "${CLR_CYN}================================================================${CLR_RST}\n"

    if docker ps --format '{{.Names}}' | grep -q "cowrie-honeypot"; then
        printf "${CLR_GRN}[✔] Cowrie Container   : ACTIVE (Up)${CLR_RST}\n"
    else
        printf "${CLR_RED}[✖] Cowrie Container   : DOWN / STOPPED${CLR_RST}\n"
    fi

    printf "\n${CLR_YEL}[*] Active Port Listeners:${CLR_RST}\n"
    for p in 2222 9001 8065; do
        if ss -tuln | grep -q ":${p} "; then
            printf " ├─ Port %-5s          : ${CLR_GRN}OPEN / LISTENING${CLR_RST}\n" "$p"
        else
            printf " ├─ Port %-5s          : ${CLR_RED}NOT ACTIVE${CLR_RST}\n" "$p"
        fi
    done

    printf "\n${CLR_YEL}[*] OpenRC Active Defense Daemons:${CLR_RST}\n"
    ACTIVE_TIER="None (Only Base Deception Stack Active)"
    for s in cowrie-watcher triage-engine active-defense; do
        if [ -f "/etc/init.d/${s}" ] && rc-service "$s" status >/dev/null 2>&1; then
            printf " ├─ %-18s : ${CLR_GRN}RUNNING${CLR_RST}\n" "$s"
            case "$s" in
                cowrie-watcher) ACTIVE_TIER="Config-A (Basic Webhook Watcher)" ;;
                triage-engine)  ACTIVE_TIER="Config-B (Intelligent Triage & Rate Limiting)" ;;
                active-defense) ACTIVE_TIER="Config-C (Enterprise ChatOps & TTY Forensics)" ;;
            esac
        else
            printf " ├─ %-18s : ${CLR_RED}STOPPED / DISABLED${CLR_RST}\n" "$s"
        fi
    done

    printf "\n${CLR_YEL}[*] Docker Container Inventory:${CLR_RST}\n"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

    printf "\n${CLR_CYN}================================================================${CLR_RST}\n"
    printf "${CLR_CYN} ACTIVE LAB PROFILE:${CLR_GRN}%s${CLR_RST}\n" "$ACTIVE_TIER"
    printf "${CLR_CYN}================================================================${CLR_RST}\n\n"
}

# -------------------------------------------------------------
# Dispatcher & Interactive Menu
# -------------------------------------------------------------
ACTION="$1"
TARGET="$2"

case "$ACTION" in
    setup)
        case "$TARGET" in
            config-a) setup_config_a ;;
            config-b) setup_config_b ;;
            config-c) setup_config_c ;;
            *)
                printf "${CLR_RED}Usage: \%s setup [config-a \vert{} config-b \vert{} config-c]${CLR_RST}\n" "$0"
                exit 1
                ;;
        esac
        ;;
    teardown)
        case "$TARGET" in
            config-a) teardown_config_a ;;
            config-b) teardown_config_b ;;
            config-c) teardown_config_c ;;
            *)
                printf "${CLR_RED}Usage: \%s teardown [config-a \vert{} config-b \vert{} config-c]${CLR_RST}\n" "$0"
                exit 1
                ;;
        esac
        ;;
    status)
        show_status
        ;;
    *)
        clear
        printf "${CLR_CYN}================================================================${CLR_RST}\n"
        printf "${CLR_CYN}     ACTIVE HONEYPOT INSTANT AUTO-QUARANTINE LAB MANAGER${CLR_RST}\n"
        printf "${CLR_CYN}================================================================${CLR_RST}\n"
        printf " 1) Setup Config-A    (Basic 1:1 Instant Quarantine + Dozzle)\n"
        printf " 2) Teardown Config-A\n"
        printf " 3) Setup Config-B    (Stateful Triage, Rate-Limit + Dozzle Split)\n"
        printf " 4) Teardown Config-B\n"
        printf " 5) Setup Config-C    (Mattermost ChatOps, TTY Forensics + FortiOS)\n"
        printf " 6) Teardown Config-C\n"
        printf " 7) Status Check      (Inspect current lab configuration)\n"
        printf " 8) Exit\n"
        printf "Enter choice [1-8]: "
        read -r OPT

        case "$OPT" in
            1) setup_config_a ;;
            2) teardown_config_a ;;
            3) setup_config_b ;;
            4) teardown_config_b ;;
            5) setup_config_c ;;
            6) teardown_config_c ;;
            7) show_status ;;
            8) exit 0 ;;
            *)
                printf "${CLR_RED}Invalid option.${CLR_RST}\n"
                exit 1
                ;;
        esac
        ;;
esac
