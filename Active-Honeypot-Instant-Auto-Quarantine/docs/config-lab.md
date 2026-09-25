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
        echo -e "${CLR_RED}[✖ FATAL ERROR] /etc/os-release not found. Target OS is not Alpine Linux.${CLR_RST}"
        exit 1
    fi
    . /etc/os-release
    if [ "$ID" != "alpine" ]; then
        echo -e "${CLR_RED}[✖ FATAL ERROR] Incompatible OS: $ID. This lab orchestrator requires Alpine Linux.${CLR_RST}"
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
        echo -e "${CLR_YEL}[!] Installing missing system packages:${MISSING}...${CLR_RST}"
        apk update
        apk add --no-cache $MISSING
    fi

    # Ensure Docker daemon is active
    if ! rc-service docker status >/dev/null 2>&1; then
        echo -e "${CLR_YEL}[!] Docker service stopped. Starting via OpenRC...${CLR_RST}"
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
        echo -e "${CLR_YEL}[!] Installing Python runtime dependencies:${MISSING_PY}...${CLR_RST}"
        apk add --no-cache $MISSING_PY
    fi
}

check_api_key() {
    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${CLR_RED}[✖ ERROR] Environment file $ENV_FILE does not exist.${CLR_RST}"
        echo -e "${CLR_YEL}[!] Please run setup.sh first or create ${ENV_FILE}.${CLR_RST}"
        exit 1
    fi

    TOKEN=$(grep -E '^FORTIGATE_API_KEY=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    if [ -z "$TOKEN" ] || [ "$TOKEN" = "PASTE_YOUR_COPIED_KEY_HERE" ]; then
        echo -e "${CLR_RED}[✖ WARNING] FORTIGATE_API_KEY is missing or invalid in ${ENV_FILE}.${CLR_RST}"
        printf "Enter your FortiGate API Token (from 'execute api-user generate-key'): "
        read -r INPUT_TOKEN
        if [ -n "$INPUT_TOKEN" ]; then
            sed -i '/FORTIGATE_API_KEY/d' "$ENV_FILE" 2>/dev/null || true
            echo "FORTIGATE_API_KEY=\"$INPUT_TOKEN\"" >> "$ENV_FILE"
            echo -e "${CLR_GRN}[✔] API Key saved to ${ENV_FILE}.${CLR_RST}"
        else
            echo -e "${CLR_RED}[✖] Cannot proceed without a valid FortiGate API token.${CLR_RST}"
            exit 1
        fi
    fi
}

verify_or_download_file() {
    TARGET_PATH="$1"
    REMOTE_URL="$2"
    FILE_LABEL="$3"

    if [ ! -f "$TARGET_PATH" ]; then
        echo -e "${CLR_YEL}[↓] Missing ${FILE_LABEL}. Downloading from repository...${CLR_RST}"
        mkdir -p "$(dirname "$TARGET_PATH")"
        if ! curl -fsSL "$REMOTE_URL" -o "$TARGET_PATH"; then
            echo -e "${CLR_RED}[✖ ERROR] Failed to download ${FILE_LABEL} from: ${REMOTE_URL}${CLR_RST}"
            echo -e "${CLR_RED}[!] Verify internet connectivity or repository file availability.${CLR_RST}"
            exit 1
        fi
        echo -e "${CLR_GRN}[✔] Successfully retrieved ${FILE_LABEL}.${CLR_RST}"
    fi
    chmod +x "$TARGET_PATH" 2>/dev/null || true
}

ensure_cowrie_running() {
    if ! docker ps --filter "name=cowrie-honeypot" --format '{{.Names}}' | grep -q "cowrie-honeypot"; then
        echo -e "${CLR_YEL}[!] Cowrie honeypot container is not running. Launching compose stack...${CLR_RST}"
        if [ -d "$COMPOSE_DIR" ] && [ -f "${COMPOSE_DIR}/docker-compose.yml" ]; then
            cd "$COMPOSE_DIR" && docker compose up -d
        else
            echo -e "${CLR_RED}[✖ ERROR] Compose file missing in ${COMPOSE_DIR}. Run setup.sh first.${CLR_RST}"
            exit 1
        fi
    fi
}

ensure_dozzle_running() {
    if ! docker ps --filter "name=dozzle-gui" --format '{{.Names}}' | grep -q "dozzle-gui"; then
        echo -e "${CLR_CYN}[+] Deploying Dozzle Real-Time Log GUI container...${CLR_RST}"
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
    echo -e "${CLR_CYN}================================================================${CLR_RST}"
    echo -e "${CLR_CYN}   CONFIG-A: DEPLOYING BASIC ACTIVE DEFENSE WATCHER             ${CLR_RST}"
    echo -e "${CLR_CYN}================================================================${CLR_RST}"
    
    assert_alpine
    check_dependencies
    check_api_key
    ensure_cowrie_running
    stop_all_daemons

    SCRIPT_PATH="${SCRIPTS_DIR}/webhook-watcher.sh"
    REMOTE_URL="${REPO_BASE}/scripts/webhook-watcher.sh"
    verify_or_download_file "$SCRIPT_PATH" "$REMOTE_URL" "webhook-watcher.sh"

    # Inject token into script if placeholder exists
    TOKEN=$(grep -E '^FORTIGATE_API_KEY=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    sed -i "s/PASTE_YOUR_COPIED_KEY_HERE/$TOKEN/g" "$SCRIPT_PATH" 2>/dev/null || true

    # Generate OpenRC Service
    echo -e "${CLR_CYN}[+] Registering /etc/init.d/cowrie-watcher OpenRC daemon...${CLR_RST}"
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

    echo -e "\n${CLR_GRN}================================================================${CLR_RST}"
    echo -e "${CLR_GRN}[✔] CONFIG-A SUCCESSFULLY ACTIVATED!${CLR_RST}"
    echo -e "${CLR_GRN}================================================================${CLR_RST}"
    echo -e "${CLR_YEL} ├─ Service Name      :${CLR_RST} cowrie-watcher (OpenRC Daemon)"
    echo -e "${CLR_YEL} ├─ Service Status    :${CLR_RST} $(rc-service cowrie-watcher status)"
    echo -e "${CLR_YEL} ├─ Honeypot Decoy Port:${CLR_RST} TCP 2222 (Forwarded from FortiGate VIP)"
    echo -e "${CLR_YEL} ├─ Visual SOC GUI    :${CLR_RST} http://192.168.10.2:9001 (Dozzle)"
    echo -e "${CLR_YEL} └─ Local Service Log :${CLR_RST} ${SCRIPTS_DIR}/watcher.log"
    echo -e "\n${CLR_CYN}[TEST & VERIFY STEP]:${CLR_RST}"
    echo -e " 1. From Kali (${CLR_MAG}192.168.40.3${CLR_RST}), run: ${CLR_GRN}ssh -o StrictHostKeyChecking=no -p 2222 testuser@192.168.40.1${CLR_RST}"
    echo -e " 2. Inspect real-time trigger: ${CLR_GRN}tail -f ${SCRIPTS_DIR}/watcher.log${CLR_RST}"
    echo -e " 3. Verify FortiGate L3 isolation: ${CLR_GRN}diagnose user banned-ip list${CLR_RST}\n"
}

teardown_config_a() {
    echo -e "${CLR_YEL}[+] Decommissioning Config-A components...${CLR_RST}"
    rc-service cowrie-watcher stop 2>/dev/null || true
    rc-update del cowrie-watcher default 2>/dev/null || true
    rm -f /etc/init.d/cowrie-watcher
    docker rm -f dozzle-gui 2>/dev/null || true
    echo -e "${CLR_GRN}[✔] Config-A torn down successfully.${CLR_RST}"
}

# -------------------------------------------------------------
# CONFIG-B: Medium Triage Setup & Teardown
# -------------------------------------------------------------
setup_config_b() {
    echo -e "${CLR_CYN}================================================================${CLR_RST}"
    echo -e "${CLR_CYN}   CONFIG-B: DEPLOYING INTELLIGENT STATEFUL TRIAGE ENGINE       ${CLR_RST}"
    echo -e "${CLR_CYN}================================================================${CLR_RST}"

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

    echo -e "${CLR_CYN}[+] Registering /etc/init.d/triage-engine OpenRC daemon...${CLR_RST}"
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

    # Deploy companion triage monitor for split view
    docker rm -f triage-monitor 2>/dev/null || true
    touch "${SCRIPTS_DIR}/triage.log"
    docker run -d \
        --name triage-monitor \
        --restart unless-stopped \
        -v "${SCRIPTS_DIR}/triage.log":/var/log/triage.log:ro \
        alpine:3.24 sh -c "tail -F /var/log/triage.log" >/dev/null

    echo -e "\n${CLR_GRN}================================================================${CLR_RST}"
    echo -e "${CLR_GRN}[✔] CONFIG-B SUCCESSFULLY ACTIVATED!${CLR_RST}"
    echo -e "${CLR_GRN}================================================================${CLR_RST}"
    echo -e "${CLR_YEL} ├─ Service Name      :${CLR_RST} triage-engine (OpenRC Daemon)"
    echo -e "${CLR_YEL} ├─ Service Status    :${CLR_RST} $(rc-service triage-engine status)"
    echo -e "${CLR_YEL} ├─ Threshold Policy  :${CLR_RST} >=3 failed attempts in 30s OR Instant Root/Admin Ban"
    echo -e "${CLR_YEL} ├─ Visual SOC GUI    :${CLR_RST} http://192.168.10.2:9001 (Dozzle Split View)"
    echo -e "${CLR_YEL} └─ Local Service Log :${CLR_RST} ${SCRIPTS_DIR}/triage.log"
    echo -e "\n${CLR_CYN}[TEST & VERIFY STEP]:${CLR_RST}"
    echo -e " 1. Normal Probe (No Ban): ${CLR_GRN}ssh -o StrictHostKeyChecking=no -p 2222 employee@192.168.40.1${CLR_RST}"
    echo -e " 2. Instant Signature Ban: ${CLR_GRN}ssh -o StrictHostKeyChecking=no -p 2222 root@192.168.40.1${CLR_RST}"
    echo -e " 3. Verify FortiGate L3 isolation: ${CLR_GRN}diagnose user banned-ip list${CLR_RST}\n"
}

teardown_config_b() {
    echo -e "${CLR_YEL}[+] Decommissioning Config-B components...${CLR_RST}"
    rc-service triage-engine stop 2>/dev/null || true
    rc-update del triage-engine default 2>/dev/null || true
    rm -f /etc/init.d/triage-engine
    docker rm -f triage-monitor dozzle-gui 2>/dev/null || true
    echo -e "${CLR_GRN}[✔] Config-B torn down successfully.${CLR_RST}"
}

# -------------------------------------------------------------
# CONFIG-C: Advanced Active Defense Setup & Teardown
# -------------------------------------------------------------
setup_config_c() {
    echo -e "${CLR_CYN}================================================================${CLR_RST}"
    echo -e "${CLR_CYN}   CONFIG-C: DEPLOYING ENTERPRISE CHATOPS & FORENSICS FABRIC   ${CLR_RST}"
    echo -e "${CLR_CYN}================================================================${CLR_RST}"

    assert_alpine
    check_dependencies
    check_python_dependencies
    check_api_key
    ensure_cowrie_running
    stop_all_daemons

    mkdir -p "$FORENSICS_DIR"

    # Deploy Mattermost Container if not running
    if ! docker ps --filter "name=mattermost-server" --format '{{.Names}}' | grep -q "mattermost-server"; then
        echo -e "${CLR_CYN}[+] Deploying on-prem Mattermost container...${CLR_RST}"
        docker run -d \
            --name mattermost-server \
            --restart unless-stopped \
            -p 8065:8065 \
            -v mattermost_data:/mm/mattermost-data \
            mattermost/mattermost-preview:latest >/dev/null
    fi

    # Check for ChatOps Webhook URL in .env
    CHATOPS_URL=$(grep -E '^CHATOPS_WEBHOOK_URL=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    if [ -z "$CHATOPS_URL" ]; then
        echo -e "\n${CLR_YEL}[!] CHATOPS_WEBHOOK_URL is not set in ${ENV_FILE}.${CLR_RST}"
        echo -e "${CLR_CYN}    Mattermost is running at: http://192.168.10.2:8065${CLR_RST}"
        printf "Paste your Mattermost or Slack Incoming Webhook URL: "
        read -r INPUT_CHATOPS
        if [ -n "$INPUT_CHATOPS" ]; then
            sed -i '/CHATOPS_WEBHOOK_URL/d' "$ENV_FILE" 2>/dev/null || true
            echo "CHATOPS_WEBHOOK_URL=\"$INPUT_CHATOPS\"" >> "$ENV_FILE"
        fi
    fi

    SCRIPT_PATH="${SCRIPTS_DIR}/active_defense_engine.py"
    REMOTE_URL="${REPO_BASE}/scripts/active_defense_engine.py"
    verify_or_download_file "$SCRIPT_PATH" "$REMOTE_URL" "active_defense_engine.py"

    echo -e "${CLR_CYN}[+] Registering /etc/init.d/active-defense OpenRC daemon...${CLR_RST}"
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

    echo -e "\n${CLR_GRN}================================================================${CLR_RST}"
    echo -e "${CLR_GRN}[✔] CONFIG-C SUCCESSFULLY ACTIVATED!${CLR_RST}"
    echo -e "${CLR_GRN}================================================================${CLR_RST}"
    echo -e "${CLR_YEL} ├─ Service Name      :${CLR_RST} active-defense (OpenRC Daemon)"
    echo -e "${CLR_YEL} ├─ Service Status    :${CLR_RST} $(rc-service active-defense status)"
    echo -e "${CLR_YEL} ├─ Mattermost Server :${CLR_RST} http://192.168.10.2:8065"
    echo -e "${CLR_YEL} ├─ Visual SOC GUI    :${CLR_RST} http://192.168.10.2:9001 (Dozzle Multi-Feed)"
    echo -e "${CLR_YEL} ├─ Forensics Dump Dir:${CLR_RST} ${FORENSICS_DIR}"
    echo -e "${CLR_YEL} └─ Local Service Log :${CLR_RST} ${SCRIPTS_DIR}/active_defense.log"
    echo -e "\n${CLR_CYN}[TEST & VERIFY STEP]:${CLR_RST}"
    echo -e " 1. Attack from Kali: ${CLR_GRN}ssh -o StrictHostKeyChecking=no -p 2222 root@192.168.40.1${CLR_RST}"
    echo -e " 2. Inspect Mattermost alert card in your channel on: ${CLR_GRN}http://192.168.10.2:8065${CLR_RST}"
    echo -e " 3. Verify FortiGate L3 isolation: ${CLR_GRN}diagnose user banned-ip list${CLR_RST}"
    echo -e " 4. Replay keystroke dump: ${CLR_GRN}ls -la ${FORENSICS_DIR}/${CLR_RST}\n"
}

teardown_config_c() {
    echo -e "${CLR_YEL}[+] Decommissioning Config-C components...${CLR_RST}"
    rc-service active-defense stop 2>/dev/null || true
    rc-update del active-defense default 2>/dev/null || true
    rm -f /etc/init.d/active-defense
    docker rm -f active-defense-feed dozzle-gui mattermost-server 2>/dev/null || true
    echo -e "${CLR_GRN}[✔] Config-C torn down successfully.${CLR_RST}"
}

# -------------------------------------------------------------
# STATUS: Full Environment Inspection
# -------------------------------------------------------------
show_status() {
    echo -e "${CLR_CYN}================================================================${CLR_RST}"
    echo -e "${CLR_CYN}       ACTIVE HONEYPOT LAB: COMPONENT STATUS INSPECTION         ${CLR_RST}"
    echo -e "${CLR_CYN}================================================================${CLR_RST}"

    # 1. Base Honeypot Container
    if docker ps --format '{{.Names}}' | grep -q "cowrie-honeypot"; then
        echo -e "${CLR_GRN}[✔] Cowrie Container : ACTIVE (Up)${CLR_RST}"
    else
        echo -e "${CLR_RED}[✖] Cowrie Container : DOWN / STOPPED${CLR_RST}"
    fi

    # 2. Port Listeners
    echo -e "\n${CLR_YEL}[*] Active Port Listeners:${CLR_RST}"
    for p in 2222 9001 8065; do
        if ss -tuln | grep -q ":${p} "; then
            echo -e " ├─ Port ${p:<5} : ${CLR_GRN}OPEN / LISTENING${CLR_RST}"
        else
            echo -e " ├─ Port ${p:<5} : ${CLR_RED}NOT ACTIVE${CLR_RST}"
        fi
    done

    # 3. OpenRC Daemons
    echo -e "\n${CLR_YEL}[*] OpenRC Active Defense Daemons:${CLR_RST}"
    ACTIVE_TIER="None (Only Base Deception Active)"
    for s in cowrie-watcher triage-engine active-defense; do
        if [ -f "/etc/init.d/${s}" ] && rc-service "$s" status >/dev/null 2>&1; then
            echo -e " ├─ ${s:<16} : ${CLR_GRN}RUNNING${CLR_RST}"
            case "$s" in
                cowrie-watcher) ACTIVE_TIER="Config-A (Basic Webhook Watcher)" ;;
                triage-engine) ACTIVE_TIER="Config-B (Intelligent Triage & Rate Limiting)" ;;
                active-defense) ACTIVE_TIER="Config-C (Enterprise ChatOps & TTY Forensics)" ;;
            esac
        else
            echo -e " ├─ ${s:<16} : ${CLR_RED}STOPPED / DISABLED${CLR_RST}"
        fi
    done

    # 4. Containers Inventory
    echo -e "\n${CLR_YEL}[*] Docker Container Inventory:${CLR_RST}"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

    # 5. Active Lab Verdict
    echo -e "\n${CLR_CYN}================================================================${CLR_RST}"
    echo -e "${CLR_CYN} ACTIVE LAB PROFILE: ${CLR_GRN}${ACTIVE_TIER}${CLR_RST}"
    echo -e "${CLR_CYN}================================================================${CLR_RST}\n"
}

# -------------------------------------------------------------
# Command Line Argument Dispatcher & Interactive Menu
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
                echo -e "${CLR_RED}Usage: $0 setup [config-a | config-b | config-c]${CLR_RST}"
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
                echo -e "${CLR_RED}Usage: $0 teardown [config-a | config-b | config-c]${CLR_RST}"
                exit 1
                ;;
        esac
        ;;
    status)
        show_status
        ;;
    *)
        # Interactive Menu Fallback
        clear
        echo -e "${CLR_CYN}================================================================${CLR_RST}"
        echo -e "${CLR_CYN}     ACTIVE HONEYPOT INSTANT AUTO-QUARANTINE LAB MANAGER       ${CLR_RST}"
        echo -e "${CLR_CYN}================================================================${CLR_RST}"
        echo -e " 1) Setup Config-A    (Basic 1:1 Instant Quarantine + Dozzle)"
        echo -e " 2) Teardown Config-A"
        echo -e " 3) Setup Config-B    (Stateful Triage, Rate-Limit + Dozzle Split)"
        echo -e " 4) Teardown Config-B"
        echo -e " 5) Setup Config-C    (Mattermost ChatOps, TTY Forensics + FortiOS)"
        echo -e " 6) Teardown Config-C"
        echo -e " 7) Status Check      (Inspect current lab configuration)"
        echo -e " 8) Exit"
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
                echo -e "${CLR_RED}Invalid option.${CLR_RST}"
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
