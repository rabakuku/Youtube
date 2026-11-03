#!/bin/sh
# filepath: https://github.com/rabakuku/Youtube/blob/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/scripts/setup.sh
# -----------------------------------------------------------------------------
# Zero-Cost Visual SOC — one-command deploy for Alpine Linux 3.24
#   Vector (UDP 514) → Loki (internal 3100) → Grafana (TCP 80)
#
# Usage (as root on 192.168.10.2):
#   mkdir -p /opt/visual-soc-analytics-traffic-dashboard
#   cd /opt/visual-soc-analytics-traffic-dashboard
#   curl -fsSL https://raw.githubusercontent.com/rabakuku/Youtube/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/scripts/setup.sh -o setup.sh
#   chmod +x setup.sh && ./setup.sh
#
# Safe to re-run: config files are refreshed, .env (and your password) is kept,
# data volumes are never touched.
# -----------------------------------------------------------------------------
set -eu

PROJECT_NAME="visual-soc-analytics-traffic-dashboard"
PROJECT_DIR="/opt/${PROJECT_NAME}"
COMPOSE_DIR="${PROJECT_DIR}/compose"
RAW_BASE="https://raw.githubusercontent.com/rabakuku/Youtube/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard"
EXPECTED_ALPINE="3.24"
EXPECTED_IP="192.168.10.2"
MARKER="${PROJECT_DIR}/.setup-installed-tools"
CONTAINERS="soc-loki soc-vector soc-grafana"
HEALTH_TIMEOUT=180

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

# --- 2. dependencies (install only what is missing, remember what we added) --
need_pkg() { # $1 = command to test, $2 = apk package
    if command -v "$1" >/dev/null 2>&1; then
        ok "$1 already present."
    else
        info "Installing $2 ..."
        apk add --no-cache "$2" >/dev/null || fail "apk add $2 failed (check internet / policy SOC_To_Internet)."
        grep -qx "$2" "$MARKER" || echo "$2" >> "$MARKER"
        ok "$2 installed."
    fi
}

info "Refreshing apk index ..."
apk update >/dev/null || fail "apk update failed — Alpine cannot reach the internet (FortiGate policy 4 SOC_To_Internet)."
need_pkg curl curl
need_pkg docker docker
if docker compose version >/dev/null 2>&1; then
    ok "docker compose plugin already present."
else
    info "Installing docker-cli-compose ..."
    apk add --no-cache docker-cli-compose >/dev/null || fail "apk add docker-cli-compose failed."
    grep -qx docker-cli-compose "$MARKER" || echo docker-cli-compose >> "$MARKER"
    ok "docker-cli-compose installed."
fi

# --- 3. docker service (OpenRC) ---------------------------------------------
if ! rc-update show default 2>/dev/null | grep -q '^ *docker '; then
    rc-update add docker default >/dev/null
    grep -qx "openrc:docker" "$MARKER" || echo "openrc:docker" >> "$MARKER"
    ok "docker added to OpenRC default runlevel."
fi
service docker status >/dev/null 2>&1 || service docker start >/dev/null
info "Waiting for the Docker daemon ..."
i=0
until docker info >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -le 30 ] || fail "Docker daemon did not start (see: service docker status, /var/log/docker.log)."
    sleep 1
done
ok "Docker daemon is up."

# --- 4. download stack files -------------------------------------------------
info "Downloading stack files from ${RAW_BASE}/compose ..."
mkdir -p "${COMPOSE_DIR}/vector" "${COMPOSE_DIR}/loki" \
         "${COMPOSE_DIR}/grafana/provisioning/datasources" \
         "${COMPOSE_DIR}/grafana/provisioning/dashboards" \
         "${COMPOSE_DIR}/grafana/dashboards"

fetch() { # $1 = repo file name under compose/, $2 = local destination
    tmp="${2}.download"
    if curl -fsSL "${RAW_BASE}/compose/$1" -o "$tmp"; then
        mv "$tmp" "$2"; ok "  $1 → ${2#"${PROJECT_DIR}"/}"
    else
        rm -f "$tmp"; fail "Download failed (404 or network): ${RAW_BASE}/compose/$1"
    fi
}
fetch docker-compose.yml       "${COMPOSE_DIR}/docker-compose.yml"
fetch .env.example             "${COMPOSE_DIR}/.env.example"
fetch vector.yaml              "${COMPOSE_DIR}/vector/vector.yaml"
fetch local-config.yaml        "${COMPOSE_DIR}/loki/local-config.yaml"
fetch grafana-datasource.yaml  "${COMPOSE_DIR}/grafana/provisioning/datasources/grafana-datasource.yaml"
fetch grafana-dashboards.yaml  "${COMPOSE_DIR}/grafana/provisioning/dashboards/grafana-dashboards.yaml"
fetch soc-wallboard.json       "${COMPOSE_DIR}/grafana/dashboards/soc-wallboard.json"
chmod -R a+rX "$COMPOSE_DIR"

# Keep the teardown script next to the stack
if curl -fsSL "${RAW_BASE}/scripts/rollback.sh" -o "${PROJECT_DIR}/rollback.sh.download"; then
    mv "${PROJECT_DIR}/rollback.sh.download" "${PROJECT_DIR}/rollback.sh"
    chmod +x "${PROJECT_DIR}/rollback.sh"; ok "  rollback.sh → rollback.sh"
else
    rm -f "${PROJECT_DIR}/rollback.sh.download"; fail "Download failed: ${RAW_BASE}/scripts/rollback.sh"
fi

# --- 5. .env (created once, secret generated automatically) ------------------
# Choice: instead of pausing for the viewer to edit .env, the only secret
# (Grafana admin password) is generated here and printed once at the end.
cd "$COMPOSE_DIR"
NEW_PASSWORD=""
if [ ! -f .env ]; then
    cp .env.example .env
    ok "Created compose/.env from .env.example."
fi
if grep -q '^GRAFANA_ADMIN_PASSWORD=CHANGE_ME' .env || grep -q '^GRAFANA_ADMIN_PASSWORD=$' .env; then
    NEW_PASSWORD="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-20)"
    sed -i "s|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=${NEW_PASSWORD}|" .env
    ok "Generated a random Grafana admin password (stored in compose/.env)."
fi
chmod 600 .env

# --- 6. port pre-flight ------------------------------------------------------
port_busy() { # $1 = t|u, $2 = port
    netstat -ln"$1" 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$2\$"
}
if ! docker ps --format '{{.Names}}' | grep -qx soc-grafana && port_busy t 80; then
    fail "TCP 80 is already in use by another process (netstat -tlnp | grep ':80 '). Stop it and re-run."
fi
if ! docker ps --format '{{.Names}}' | grep -qx soc-vector && port_busy u 514; then
    fail "UDP 514 is already in use (another syslog daemon?). Stop it (rc-service syslog stop) and re-run."
fi

# --- 7. pull + start ---------------------------------------------------------
info "Pulling pinned images (first run can take a few minutes) ..."
docker compose pull --quiet || fail "Image pull failed — check DNS/internet from Alpine (docker compose pull)."
info "Starting the stack ..."
docker compose up -d --remove-orphans

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
ok "soc-loki, soc-vector and soc-grafana are healthy."

# --- 9. end-to-end self-test (syslog → Vector → Loki) -------------------------
info "Self-test: sending one FortiOS-style syslog line to UDP 514 ..."
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
    if [ "$found" -eq 1 ]; then
        ok "Self-test passed: log travelled UDP 514 → Vector → Loki."
    else
        warn "Self-test line not found in Loki yet. Check: docker compose logs --tail=50 vector loki"
    fi
else
    warn "Skipped self-test (busybox nc without UDP support). Verify with the FortiGate instead."
fi

# --- 10. summary ---------------------------------------------------------------
HOST_IP="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"
[ -n "$HOST_IP" ] || HOST_IP="$EXPECTED_IP"
[ "$HOST_IP" = "$EXPECTED_IP" ] || warn "Host IP is ${HOST_IP}, Lab-Matrix expects ${EXPECTED_IP} — FortiGate syslog server must match."
ADMIN_USER="$(sed -n 's/^GRAFANA_ADMIN_USER=//p' .env)"

echo
docker compose ps
echo
ok "Visual SOC is live."
printf '    Wallboard  : http://%s   (from Kali 192.168.40.3)\n' "$HOST_IP"
printf '    Syslog in  : udp://%s:514   (FortiGate → set server "%s")\n' "$HOST_IP" "$HOST_IP"
printf '    Loki debug : http://127.0.0.1:3100  (this host only)\n'
printf '    Login      : %s / ' "${ADMIN_USER:-admin}"
if [ -n "$NEW_PASSWORD" ]; then
    printf '%s%s%s   ← shown once, saved in %s/.env\n' "$C_Y" "$NEW_PASSWORD" "$C_0" "$COMPOSE_DIR"
else
    printf '(unchanged — see GRAFANA_ADMIN_PASSWORD in %s/.env)\n' "$COMPOSE_DIR"
fi
printf '    Teardown   : %s/rollback.sh --help\n' "$PROJECT_DIR"
