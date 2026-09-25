To support this workflow, the three files currently in your GitHub `scripts/` directory (`webhook-watcher.sh`, `triage_engine.py`, and `active_defense_engine.py`) along with the compose artifacts from Stage 2 are sufficient. No additional files need to be hosted on GitHub because `config-lab.sh` writes the native OpenRC service definitions dynamically into `/etc/init.d/`.

Below is the complete, unpruned `config-lab.sh` script.
```sh
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
    printf "${CLR_YEL} ├─ Service Status     :${CLR_RST} %s\n" "$(rc-service triage-engine status)"
    printf "${CLR_YEL} ├─ Threshold Policy   :${CLR_RST} >=3 failed attempts in 30s OR Instant Root/Admin Ban\n"
    printf "${CLR_YEL} ├─ Visual SOC GUI     :${CLR_RST} http://192.168.10.2:9001 (Dozzle Split View)\n"
    printf "${CLR_YEL} └─ Local Service Log  :${CLR_RST} %s/triage.log\n" "$SCRIPTS_DIR"
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
    printf "${CLR_CYN}   CONFIG-C: DEPLOYING ENTERPRISE CHATOPS & FORENSICS FABRIC   ${CLR_RST}\n"
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
    if [ -z "$CHATOPS_URL" ] || [ "$CHATOPS_URL" = "https://your-mattermost-or-slack-webhook-url-here" ]; then
        printf "\n${CLR_MAG}======================================================================${CLR_RST}\n"
        printf "${CLR_MAG}       MATTERMOST INCOMING WEBHOOK ONBOARDING (STAGE PAUSE)          ${CLR_RST}\n"
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

    # Step 4: Download and configure active defense engine
    SCRIPT_PATH="${SCRIPTS_DIR}/active_defense_engine.py"
    REMOTE_URL="${REPO_BASE}/scripts/active_defense_engine.py"
    verify_or_download_file "$SCRIPT_PATH" "$REMOTE_URL" "active_defense_engine.py"

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
    printf "${CLR_YEL} ├─ Service Status      :${CLR_RST} %s\n" "$(rc-service active-defense status)"
    printf "${CLR_YEL} ├─ Mattermost Portal   :${CLR_RST} http://192.168.10.2:8065 (Port 8065)\n"
    printf "${CLR_YEL} ├─ Visual SOC GUI      :${CLR_RST} http://192.168.10.2:9001 (Port 9001, Dozzle Multi-Feed)\n"
    printf "${CLR_YEL} ├─ Forensics Directory :${CLR_RST} %s\n" "$FORENSICS_DIR"
    printf "${CLR_YEL} └─ Local Service Log   :${CLR_RST} %s/active_defense.log\n" "$SCRIPTS_DIR"
    printf "\n${CLR_CYN}[TEST & VERIFY STEP]:${CLR_RST}\n"
    printf " 1. Attack from Kali:    ${CLR_GRN}ssh -o StrictHostKeyChecking=no -p 2222 root@192.168.40.1${CLR_RST}\n"
    printf " 2. Inspect Mattermost:  Check incoming card alert at ${CLR_GRN}http://192.168.10.2:8065${CLR_RST}\n"
    printf " 3. Verify FortiGate:    ${CLR_GRN}diagnose user banned-ip list${CLR_RST}\n"
    printf " 4. Check Keystrokes:    ${CLR_GRN}ls -la %s${CLR_RST}\n\n" "$FORENSICS_DIR"
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
    printf "${CLR_CYN}       ACTIVE HONEYPOT LAB: COMPONENT STATUS INSPECTION         ${CLR_RST}\n"
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
    printf "${CLR_CYN} ACTIVE LAB PROFILE: ${CLR_GRN}%s${CLR_RST}\n" "$ACTIVE_TIER"
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
                printf "${CLR_RED}Usage: %s setup [config-a | config-b | config-c]${CLR_RST}\n" "$0"
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
                printf "${CLR_RED}Usage: %s teardown [config-a | config-b | config-c]${CLR_RST}\n" "$0"
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
        printf "${CLR_CYN}     ACTIVE HONEYPOT INSTANT AUTO-QUARANTINE LAB MANAGER       ${CLR_RST}\n"
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
```

---

### How to Deploy and Verify `config-lab.sh` on Node 2 (Alpine)

1. **Download and grant execution rights:**
```sh
cd /opt/honeypot-quarantine/scripts
curl -fsSL https://raw.githubusercontent.com/rabakuku/Youtube/main/Active-Honeypot-Instant-Auto-Quarantine/scripts/config-lab.sh -o config-lab.sh
chmod +x config-lab.sh

```


2. **Execute directly via arguments or interactive menu:**
```sh
# Deploy Config-A
./config-lab.sh setup config-a

# Deploy Config-B (automatically decommissions Config-A first)
./config-lab.sh setup config-b

# Deploy Config-C (automatically spins up Mattermost and registers active-defense daemon)
./config-lab.sh setup config-c

# Inspect active profile, open ports, and running daemons
./config-lab.sh status

```


3. **Verify the active tier:**
When you run `./config-lab.sh status`, inspect the final verdict banner:
```text
ACTIVE LAB PROFILE: Config-C (Enterprise ChatOps & TTY Forensics)

```
