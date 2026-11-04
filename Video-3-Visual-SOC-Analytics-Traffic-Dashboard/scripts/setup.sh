#!/bin/sh
# filepath: https://github.com/rabakuku/Youtube/blob/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/scripts/setup.sh
# -----------------------------------------------------------------------------
# Zero-Cost Visual SOC — one-command deploy for Alpine Linux 3.24 (192.168.10.2)
#   Vector (UDP 514) → Loki → Grafana (80) → responder (8091) → ntfy (8090)
#                                              └─► FortiGate REST API quarantine
#
# Usage (as root):
#   mkdir -p /opt/visual-soc-analytics-traffic-dashboard
#   cd /opt/visual-soc-analytics-traffic-dashboard
#   curl -fsSLO https://raw.githubusercontent.com/rabakuku/Youtube/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/scripts/setup.sh
#   chmod +x setup.sh && ./setup.sh
#
# Options:
#   --fgt-token TOKEN   store the FortiGate API token (Stage 4) without a prompt
#   --dry-run           keep / switch the responder to DRY-RUN (no FortiGate changes)
#   --no-prompt         never ask anything (also automatic under curl | sh)
#
# Safe to re-run: configs are refreshed, compose/.env is kept (new settings are
# merged in), data volumes are never touched.
# -----------------------------------------------------------------------------
set -eu

PROJECT_NAME="visual-soc-analytics-traffic-dashboard"
PROJECT_DIR="/opt/${PROJECT_NAME}"
COMPOSE_DIR="${PROJECT_DIR}/compose"
RAW_BASE="https://raw.githubusercontent.com/rabakuku/Youtube/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard"
EXPECTED_ALPINE="3.24"
EXPECTED_IP="192.168.10.2"
SOC_SUBNET="10.89.0.0/24"
MARKER="${PROJECT_DIR}/.setup-installed-tools"
CONTAINERS="soc-loki soc-vector soc-grafana soc-ntfy soc-responder"
HEALTH_TIMEOUT=240

ARG_TOKEN=""; ARG_DRY=0; PROMPT=1
while [ $# -gt 0 ]; do
    case "$1" in
        --fgt-token) shift; ARG_TOKEN="${1:-}" ;;
        --dry-run)   ARG_DRY=1 ;;
        --no-prompt) PROMPT=0 ;;
        -h|--help)   sed -n '13,20p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
    esac
    shift
done
[ -r /dev/tty ] && [ -t 0 ] || PROMPT=0

# --- output helpers ----------------------------------------------------------
if [ -t 1 ]; then
    C_B="$(printf '\033[1;36m')"; C_G="$(printf '\033[1;32m')"
    C_Y="$(printf '\033[1;33m')"; C_R="$(printf '\033[1;31m')"; C_0="$(printf '\033[0m')"
else
    C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi
info() { printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*"; }
fail() { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
remember() { grep -qx "$1" "$MARKER" 2>/dev/null || echo "$1" >> "$MARKER"; }

# --- 1. privilege + OS checks ------------------------------------------------
[ "$(id -u)" -eq 0 ] || fail "Run as root (or: doas ./setup.sh / sudo ./setup.sh)."
[ -r /etc/os-release ] || fail "/etc/os-release not found — not compatible, Alpine Linux only."
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = "alpine" ] || fail "Detected '${ID:-unknown}' — not compatible, this lab is Alpine Linux only."
case "${VERSION_ID:-}" in
    "${EXPECTED_ALPINE}"*) ok "Alpine ${VERSION_ID} detected." ;;
    *) warn "Alpine ${VERSION_ID:-?} detected; this lab is tested on ${EXPECTED_ALPINE}. Continuing." ;;
esac

info "Visual SOC deploy → ${PROJECT_DIR}"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"
touch "$MARKER"

# --- 2. dependencies ---------------------------------------------------------
need_pkg() { # $1 = command to test, $2 = apk package
    if command -v "$1" >/dev/null 2>&1; then
        ok "$1 already present."
    else
        info "Installing $2 ..."
        apk add --no-cache "$2" >/dev/null || fail "apk add $2 failed (check internet / policy SERVERS TO WAN)."
        remember "$2"; ok "$2 installed."
    fi
}
info "Refreshing apk index ..."
apk update >/dev/null || fail "apk update failed — Alpine cannot reach the internet (FortiGate policy SERVERS TO WAN)."
need_pkg curl curl
need_pkg docker docker
if docker compose version >/dev/null 2>&1; then
    ok "docker compose plugin already present."
else
    info "Installing docker-cli-compose ..."
    apk add --no-cache docker-cli-compose >/dev/null || fail "apk add docker-cli-compose failed."
    remember docker-cli-compose; ok "docker-cli-compose installed."
fi

# --- 3. docker service (OpenRC) ---------------------------------------------
if ! rc-update show default 2>/dev/null | grep -q '^ *docker '; then
    rc-update add docker default >/dev/null
    remember "openrc:docker"; ok "docker added to OpenRC default runlevel."
fi
service docker status >/dev/null 2>&1 || service docker start >/dev/null
info "Waiting for the Docker daemon ..."
i=0
until docker info >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -le 30 ] || fail "Docker daemon did not start (service docker status, /var/log/docker.log)."
    sleep 1
done
ok "Docker daemon is up."

# --- 4. download stack files -------------------------------------------------
info "Downloading stack files from ${RAW_BASE} ..."
mkdir -p "${COMPOSE_DIR}/vector" "${COMPOSE_DIR}/loki" "${COMPOSE_DIR}/responder" \
         "${COMPOSE_DIR}/grafana/provisioning/datasources" \
         "${COMPOSE_DIR}/grafana/provisioning/dashboards" \
         "${COMPOSE_DIR}/grafana/provisioning/alerting" \
         "${COMPOSE_DIR}/grafana/dashboards"

fetch() { # $1 = path in the repo folder, $2 = local destination
    tmp="${2}.download"
    if curl -fsSL "${RAW_BASE}/$1" -o "$tmp"; then
        mv "$tmp" "$2"; ok "  $1 → ${2#"${PROJECT_DIR}"/}"
    else
        rm -f "$tmp"; fail "Download failed (404 or network): ${RAW_BASE}/$1"
    fi
}
G="${COMPOSE_DIR}/grafana"
fetch compose/docker-compose.yml          "${COMPOSE_DIR}/docker-compose.yml"
fetch compose/.env.example                "${COMPOSE_DIR}/.env.example"
fetch compose/vector.yaml                 "${COMPOSE_DIR}/vector/vector.yaml"
fetch compose/local-config.yaml           "${COMPOSE_DIR}/loki/local-config.yaml"
fetch compose/grafana-datasource.yaml     "${G}/provisioning/datasources/grafana-datasource.yaml"
fetch compose/grafana-dashboards.yaml     "${G}/provisioning/dashboards/grafana-dashboards.yaml"
fetch compose/grafana-contact-points.yaml "${G}/provisioning/alerting/contact-points.yaml"
fetch app/alert-rules.yaml                "${G}/provisioning/alerting/alert-rules.yaml"
fetch compose/soc-wallboard.json          "${G}/dashboards/soc-wallboard.json"
fetch app/app-advanced.json               "${G}/dashboards/app-advanced.json"
fetch app/responder/responder.py          "${COMPOSE_DIR}/responder/responder.py"
fetch scripts/rollback.sh                 "${PROJECT_DIR}/rollback.sh"
chmod +x "${PROJECT_DIR}/rollback.sh"
# Dashboards retired in this version (older installs may still have them)
for old in app-basic.json app-medium.json; do
    if [ -f "${G}/dashboards/${old}" ]; then rm -f "${G}/dashboards/${old}"; info "  removed retired dashboard ${old}"; fi
done
chmod -R a+rX "$COMPOSE_DIR"

# --- 5. .env: create, merge new settings, generate secrets -------------------
cd "$COMPOSE_DIR"
NEW_PASSWORD=""
if [ ! -f .env ]; then
    cp .env.example .env
    ok "Created compose/.env from .env.example."
else
    added=0
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        key="${line%%=*}"
        if ! grep -q "^${key}=" .env; then
            printf '%s\n' "$line" >> .env; added=$((added + 1))
        fi
    done < .env.example
    [ "$added" -eq 0 ] || ok "Merged ${added} new setting(s) from .env.example into compose/.env."
fi

env_get() { sed -n "s/^$1=//p" .env | tail -n 1; }
env_set() { # $1 key, $2 value (value must not contain | or newline)
    if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else printf '%s=%s\n' "$1" "$2" >> .env; fi
}
rand() { head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-"$1"; }

case "$(env_get GRAFANA_ADMIN_PASSWORD)" in
    ''|CHANGE_ME*) NEW_PASSWORD="$(rand 20)"; env_set GRAFANA_ADMIN_PASSWORD "$NEW_PASSWORD"
                   ok "Generated a random Grafana admin password." ;;
esac
case "$(env_get NTFY_TOPIC)" in
    ''|CHANGE_ME*) env_set NTFY_TOPIC "soc-alerts-$(rand 12 | tr '[:upper:]' '[:lower:]')"; ok "Generated a private ntfy topic name." ;;
esac
case "$(env_get RESPONDER_SECRET)" in
    ''|CHANGE_ME*) env_set RESPONDER_SECRET "$(rand 40)"; ok "Generated the button-link signing secret." ;;
esac

# FortiGate API token: flag > prompt > keep existing > dry-run
TOKEN="$(env_get FGT_API_TOKEN)"
if [ -n "$ARG_TOKEN" ]; then
    TOKEN="$ARG_TOKEN"
elif [ "$ARG_DRY" -eq 1 ]; then
    TOKEN=""
elif [ -z "$TOKEN" ] && [ "$PROMPT" -eq 1 ]; then
    printf '%s[?]%s FortiGate API token for the quarantine (Stage 4). Paste it, or press Enter for DRY-RUN: ' "$C_Y" "$C_0" > /dev/tty
    stty -echo < /dev/tty 2>/dev/null || true
    read -r TOKEN < /dev/tty || TOKEN=""
    stty echo < /dev/tty 2>/dev/null || true
    printf '\n' > /dev/tty
fi
case "$TOKEN" in
    *[!A-Za-z0-9]*) fail "That token contains unexpected characters. FortiGate API keys are letters and digits only." ;;
esac
env_set FGT_API_TOKEN "$TOKEN"
chmod 600 .env

FGT_HOST="$(env_get FGT_HOST)"
FGT_GROUP="$(env_get FGT_QUARANTINE_GROUP)"
if [ -n "$TOKEN" ]; then
    code="$(curl -sk -o /dev/null -w '%{http_code}' -m 8 -H "Authorization: Bearer ${TOKEN}" \
        "https://${FGT_HOST}/api/v2/cmdb/firewall/addrgrp/${FGT_GROUP}?vdom=$(env_get FGT_VDOM)" || echo 000)"
    case "$code" in
        200) ok "FortiGate API token works and group ${FGT_GROUP} exists — quarantine is LIVE." ;;
        404) warn "FortiGate API token works, but group ${FGT_GROUP} does not exist yet (create it in Stage 4)." ;;
        401|403) warn "FortiGate rejected the token (HTTP ${code}): check trusthost 192.168.10.2 and the access profile." ;;
        000) warn "Cannot reach https://${FGT_HOST} (is HTTPS admin enabled on VLAN_QC_10?)." ;;
        *)   warn "FortiGate API answered HTTP ${code}." ;;
    esac
else
    warn "No FortiGate API token: the responder runs in DRY-RUN (notifications and timers only)."
fi

# --- 6. port pre-flight --------------------------------------------------------
port_busy() { netstat -ln"$1" 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$2\$"; }
running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }
for spec in "t 80 soc-grafana" "u 514 soc-vector" "t 8090 soc-ntfy" "t 8091 soc-responder"; do
    # shellcheck disable=SC2086
    set -- $spec
    if ! running "$3" && port_busy "$1" "$2"; then
        fail "Port $2/$( [ "$1" = t ] && echo tcp || echo udp ) is already in use (netstat -lnp | grep ':$2 '). Free it and re-run."
    fi
done

# --- 6b. kernel UDP buffer (stops syslog drops during nmap bursts) ------------
SYSCTL_FILE="/etc/sysctl.d/90-visual-soc.conf"
if [ ! -f "$SYSCTL_FILE" ]; then
    printf '%s\n' "# Visual SOC: allow an 8 MiB UDP receive buffer for Vector (syslog bursts)" \
        "net.core.rmem_max = 8388608" > "$SYSCTL_FILE"
    remember "sysctl:${SYSCTL_FILE}"
fi
sysctl -q -p "$SYSCTL_FILE" >/dev/null 2>&1 || sysctl -w net.core.rmem_max=8388608 >/dev/null 2>&1 \
    || warn "Could not raise net.core.rmem_max — bursts of syslog may drop packets."
ok "UDP receive buffer limit: $(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo unknown) bytes."

# --- 6c. soc_net must use the pinned subnet (older installs used Docker's pool) --
cur_net="$(docker network inspect soc_net --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)"
if [ -n "$cur_net" ] && [ "$cur_net" != "$SOC_SUBNET" ]; then
    warn "soc_net uses ${cur_net}; recreating it as ${SOC_SUBNET} (data volumes are kept)."
    docker compose down --remove-orphans >/dev/null 2>&1 || true
    docker network rm soc_net >/dev/null 2>&1 || true
fi

# --- 7. pull + start ---------------------------------------------------------
info "Pulling pinned images (first run can take a few minutes) ..."
docker compose pull --quiet || fail "Image pull failed — check DNS/internet from Alpine (docker compose pull)."
info "Starting the stack ..."
docker compose up -d --remove-orphans
# Re-runs: bind-mounted configs may have changed — restart so every service reloads them
docker compose restart >/dev/null 2>&1 || true

# --- 8. wait for health ------------------------------------------------------
info "Waiting for containers to become healthy (up to ${HEALTH_TIMEOUT}s) ..."
elapsed=0
while :; do
    pending=""
    for c in $CONTAINERS; do
        st="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null || echo missing)"
        [ "$st" = "healthy" ] || pending="${pending} ${c}(${st})"
    done
    [ -z "$pending" ] && break
    [ "$elapsed" -lt "$HEALTH_TIMEOUT" ] || fail "Still not healthy:${pending}. Check: docker compose logs --tail=50"
    sleep 5; elapsed=$((elapsed + 5))
done
ok "All 5 containers are healthy: ${CONTAINERS}."

# --- 9. self-tests ---------------------------------------------------------------
info "Self-test 1/3: FortiOS-style syslog line → UDP 514 → Vector → Loki ..."
TEST_ID="selftest$(date +%s)"
TEST_LINE="<189>date=$(date +%Y-%m-%d) time=$(date +%H:%M:%S) devname=\"setup-selftest\" logid=\"0100032001\" type=\"event\" subtype=\"system\" level=\"information\" action=\"selftest\" msg=\"${TEST_ID}\""
if printf '%s' "$TEST_LINE" | nc -u -w1 127.0.0.1 514 2>/dev/null; then
    found=0; i=0
    while [ "$i" -lt 10 ]; do
        sleep 2; i=$((i + 1))
        if curl -fsG "http://127.0.0.1:3100/loki/api/v1/query_range" \
             --data-urlencode "query={source=\"fortigate\"} |= \"${TEST_ID}\"" \
             --data-urlencode "limit=1" 2>/dev/null | grep -q "$TEST_ID"; then
            found=1; break
        fi
    done
    if [ "$found" -eq 1 ]; then ok "Syslog pipeline works."
    else warn "Test line not found in Loki yet (docker compose logs vector loki)."; fi
else
    warn "Skipped (busybox nc without UDP support). Verify with the FortiGate instead."
fi

info "Self-test 2/3: responder ..."
RH="$(curl -fs -m 5 http://127.0.0.1:8091/health || true)"
case "$RH" in
    *'"ok": true'*) ok "Responder answers on :8091 ($(printf '%s' "$RH" | grep -o '"dry_run": [a-z]*'), mode $(env_get QUARANTINE_MODE))." ;;
    *) warn "Responder health check failed (docker compose logs responder)." ;;
esac

info "Self-test 3/3: test notification to ntfy ..."
TOPIC="$(env_get NTFY_TOPIC)"
if curl -fs -m 5 -H "Title: Visual SOC is live" -H "Tags: white_check_mark" -H "Priority: 3" \
        -d "Alerts, approvals and quarantine messages will appear here." \
        "http://127.0.0.1:8090/${TOPIC}" >/dev/null; then
    ok "Test notification published."
else
    warn "Could not publish to ntfy (docker compose logs ntfy)."
fi

# --- 10. summary ---------------------------------------------------------------
HOST_IP="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"
[ -n "$HOST_IP" ] || HOST_IP="$EXPECTED_IP"
[ "$HOST_IP" = "$EXPECTED_IP" ] || warn "Host IP is ${HOST_IP}, the lab expects ${EXPECTED_IP} — VIPs and FortiGate syslog must match."
echo
docker compose ps
echo
ok "Visual SOC is live."
printf '    Wallboard  : %s   (admin PC)   ·   http://%s (Kali)\n' "$(env_get PUBLIC_GRAFANA_URL)" "$HOST_IP"
printf '    ntfy       : %s/%s   ← open on the admin PC, allow notifications\n' "$(env_get PUBLIC_NTFY_URL)" "$TOPIC"
printf '    Responder  : mode=%s  minutes=%s  %s\n' "$(env_get QUARANTINE_MODE)" "$(env_get QUARANTINE_MINUTES)" \
    "$( [ -n "$TOKEN" ] && echo "FortiGate API: configured" || echo "DRY-RUN (re-run with --fgt-token after Stage 4)" )"
printf '    Syslog in  : udp://%s:514\n' "$HOST_IP"
printf '    Login      : %s / ' "$(env_get GRAFANA_ADMIN_USER)"
if [ -n "$NEW_PASSWORD" ]; then
    printf '%s%s%s   ← shown once, saved in %s/.env\n' "$C_Y" "$NEW_PASSWORD" "$C_0" "$COMPOSE_DIR"
else
    printf '(unchanged — GRAFANA_ADMIN_PASSWORD in %s/.env)\n' "$COMPOSE_DIR"
fi
printf '    Teardown   : %s/rollback.sh --help\n' "$PROJECT_DIR"
