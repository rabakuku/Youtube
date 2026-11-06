#!/bin/sh
# filepath: https://github.com/rabakuku/Youtube/blob/main/Video-4-HoneyWall-Live-Deception-SOC/scripts/setup.sh
#
# HoneyWall - all-in-one setup for Alpine Linux (POSIX sh / BusyBox ash)
#
#   mkdir -p /opt/honeywall && cd /opt/honeywall
#   curl -fsSLO https://raw.githubusercontent.com/rabakuku/Youtube/main/Video-4-HoneyWall-Live-Deception-SOC/scripts/setup.sh
#   chmod +x setup.sh && ./setup.sh
#
# Installs Docker + Compose if missing, downloads the stack into /opt/honeywall, creates/merges .env,
# asks for (and validates) the FortiGate API token, builds the local images, starts the chosen
# profile, waits for health checks and prints a summary. Safe to re-run at any time.
set -eu

BASE=/opt/honeywall
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/rabakuku/Youtube/main/Video-4-HoneyWall-Live-Deception-SOC}"
EXPECTED_ALPINE=3.24
MARKER_DIR=/var/lib/honeywall
MARKER="$MARKER_DIR/installed-tools"

# Every file the stack needs, relative to the repo folder (kept in one place on purpose)
FILES="
compose/docker-compose.yml
compose/.env.example
compose/cowrie.cfg
compose/userdb.txt
compose/build_honeyfs.py
compose/ntfy/server.yml
compose/honeyfs/root/.aws/credentials
compose/honeyfs/home/svc_backup/passwords.txt
compose/honeyfs/home/svc_backup/.bash_history
compose/honeyfs/opt/backup/db_dump.sql
engine/Dockerfile
engine/requirements.txt
engine/engine.py
dashboard/Dockerfile
dashboard/nginx.conf
dashboard/index.html
dashboard/style.css
dashboard/app.js
decoy-web/Dockerfile
decoy-web/requirements.txt
decoy-web/decoy_web.py
scripts/setup.sh
scripts/rollback.sh
scripts/vt.md
"

PROFILE=""
NONINTERACTIVE=0
UPDATE=0
LOCAL=0
LLM=""
SIMULATE=""
STATUS_ONLY=0

# ------------------------------------------------------------------ output helpers
if [ -t 1 ]; then
  ESC=$(printf '\033'); R="${ESC}[0m"; B="${ESC}[1m"; RED="${ESC}[1;31m"; GRN="${ESC}[1;32m"; YEL="${ESC}[1;33m"; CYN="${ESC}[1;36m"
else R=""; B=""; RED=""; GRN=""; YEL=""; CYN=""; fi
info() { printf '%s[ .. ]%s %s\n' "$CYN" "$R" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$GRN" "$R" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YEL" "$R" "$*"; }
fail() { printf '%s[FAIL]%s %s\n' "$RED" "$R" "$*" >&2; exit 1; }
step() { printf '\n%s== %s ==%s\n' "$B" "$*" "$R"; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
HoneyWall setup (Alpine)

Usage: ./setup.sh [options]          (no options = interactive menu)

  --profile lite|standard|full   Which services to run (default: value in .env, else standard)
  --llm on|off                   AI incident reports (home LLM, see docs/LLM-Setup.md)
  --simulate on|off              Rehearsal mode: simulated FortiGate (handy before Stage 5)
  --update                       Re-download every file and rebuild the images
  --local                        Use the files already in $BASE (no downloads)
  --status                       Show container health and engine status, change nothing
  --non-interactive, -y          Never prompt (CI / re-runs)
  -h, --help                     This help

Environment: FGT_API_TOKEN=<token> ./setup.sh -y   sets the FortiGate token without a prompt.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --llm) LLM="${2:-}"; shift 2 ;;
    --simulate) SIMULATE="${2:-}"; shift 2 ;;
    --update) UPDATE=1; shift ;;
    --local) LOCAL=1; shift ;;
    --status) STATUS_ONLY=1; shift ;;
    --non-interactive|-y) NONINTERACTIVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; fail "unknown option: $1" ;;
  esac
done

case "$PROFILE" in ""|lite|standard|full) ;; *) fail "--profile must be lite, standard or full" ;; esac
case "$LLM" in ""|on|off) ;; *) fail "--llm must be on or off" ;; esac
case "$SIMULATE" in ""|on|off) ;; *) fail "--simulate must be on or off" ;; esac
[ -t 0 ] || NONINTERACTIVE=1

ask() { # ask "question" default -> echoes answer
  if [ "$NONINTERACTIVE" = 1 ]; then printf '%s' "$2"; return; fi
  printf '%s [%s]: ' "$1" "$2" >/dev/tty
  read -r a </dev/tty || a=""
  printf '%s' "${a:-$2}"
}

# ------------------------------------------------------------------ .env helpers
ENVF="$BASE/compose/.env"
env_get() { sed -n "s/^$1=//p" "$ENVF" 2>/dev/null | tail -n 1; }
env_set() { # env_set KEY VALUE  (value must not contain '|')
  if grep -q "^$1=" "$ENVF"; then sed -i "s|^$1=.*|$1=$2|" "$ENVF"; else printf '%s=%s\n' "$1" "$2" >> "$ENVF"; fi
}
is_placeholder() { case "$1" in "<"*">"|"") return 0 ;; *) return 1 ;; esac; }

# ------------------------------------------------------------------ checks
preflight() {
  step "Preflight"
  [ "$(id -u)" -eq 0 ] || fail "run as root (doas ./setup.sh or su -c ./setup.sh)"
  [ -r /etc/os-release ] || fail "cannot read /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID:-}" = "alpine" ] || fail "not compatible: this script is for Alpine Linux only (found ${ID:-unknown})"
  case "${VERSION_ID:-}" in
    "$EXPECTED_ALPINE"*) ok "Alpine ${VERSION_ID}" ;;
    *) warn "Alpine ${VERSION_ID:-?} detected - this lab was built on ${EXPECTED_ALPINE}; continuing" ;;
  esac
}

mark_installed() { mkdir -p "$MARKER_DIR"; grep -qx "$1" "$MARKER" 2>/dev/null || echo "$1" >> "$MARKER"; }

ensure_deps() {
  step "Dependencies"
  for pkg in curl docker docker-cli-compose; do
    if apk info -e "$pkg" >/dev/null 2>&1; then ok "$pkg present"
    else info "installing $pkg"; apk add --no-cache "$pkg" >/dev/null; mark_installed "$pkg"; ok "$pkg installed"; fi
  done
  if ! rc-update show default 2>/dev/null | grep -q '^ *docker '; then rc-update add docker default >/dev/null; mark_installed "openrc:docker"; fi
  service docker status >/dev/null 2>&1 || service docker start >/dev/null
  i=0
  until docker info >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -gt 30 ] && fail "Docker daemon did not start (service docker status)"
    sleep 1
  done
  ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null) running"
  docker compose version >/dev/null 2>&1 || fail "'docker compose' not available (apk add docker-cli-compose)"
  ok "$(docker compose version | head -n 1)"
}

download() {
  step "Files ($BASE)"
  mkdir -p "$BASE"
  if [ "$LOCAL" = 1 ]; then
    for f in $FILES; do [ -f "$BASE/$f" ] || fail "--local: missing $BASE/$f"; done
    ok "using local files"; return
  fi
  need=0
  for f in $FILES; do [ -f "$BASE/$f" ] || need=1; done
  if [ "$need" = 0 ] && [ "$UPDATE" = 0 ]; then ok "all files present (use --update to refresh)"; return; fi
  tmp="$(mktemp -d)"
  n=0
  for f in $FILES; do
    mkdir -p "$tmp/$(dirname "$f")"
    curl -fsSL --retry 2 "$RAW_BASE/$f" -o "$tmp/$f" || { rm -rf "$tmp"; fail "download failed (404?): $RAW_BASE/$f"; }
    n=$((n + 1))
  done
  # everything downloaded fine -> install (never touches compose/.env)
  for f in $FILES; do mkdir -p "$BASE/$(dirname "$f")"; mv -f "$tmp/$f" "$BASE/$f"; done
  rm -rf "$tmp"
  chmod +x "$BASE/scripts/setup.sh" "$BASE/scripts/rollback.sh" 2>/dev/null || true
  ok "downloaded $n files from $RAW_BASE"
}

prepare_env() {
  step "Configuration (.env)"
  if [ ! -f "$ENVF" ]; then
    cp "$BASE/compose/.env.example" "$ENVF"; chmod 600 "$ENVF"
    ok "created compose/.env from .env.example"
  else
    # upgrade: append any new keys from .env.example, keep every existing value
    added=""
    while IFS= read -r line; do
      case "$line" in [A-Z_]*=*) ;; *) continue ;; esac
      key="${line%%=*}"
      grep -q "^$key=" "$ENVF" || { printf '%s\n' "$line" >> "$ENVF"; added="$added $key"; }
    done < "$BASE/compose/.env.example"
    if [ -n "$added" ]; then ok "added new settings:$added"; else ok "compose/.env up to date"; fi
  fi

  [ -n "$PROFILE" ] || PROFILE="$(env_get COMPOSE_PROFILES | cut -d, -f1)"
  [ -n "$PROFILE" ] || PROFILE=standard
  [ "$LLM" = on ] && env_set LLM_ENABLED true
  [ "$LLM" = off ] && env_set LLM_ENABLED false
  [ "$SIMULATE" = on ] && env_set FGT_SIMULATE true
  [ "$SIMULATE" = off ] && env_set FGT_SIMULATE false

  profiles="$PROFILE"
  if [ "$(env_get LLM_ENABLED)" = true ] && [ "$(env_get LLM_ACCESS_MODE)" = tailscale ]; then profiles="$profiles,llm-tailscale"; fi
  env_set COMPOSE_PROFILES "$profiles"
  ok "profile: $profiles | LLM reports: $(env_get LLM_ENABLED) ($(env_get LLM_ACCESS_MODE)) | rehearsal mode: $(env_get FGT_SIMULATE)"

  if [ "$(env_get LLM_ENABLED)" = true ] && is_placeholder "$(env_get LLM_API_KEY)"; then
    warn "LLM_ENABLED=true but LLM_API_KEY is not set - run scripts/llm-host-setup.sh on the GPU box (docs/LLM-Setup.md)"
  fi
}

fgt_token() {
  step "FortiGate REST API"
  if [ "$(env_get FGT_SIMULATE)" = true ]; then warn "rehearsal mode (FGT_SIMULATE=true): no FortiGate calls"; return; fi
  host="$(env_get FGT_HOST)"; vdom="$(env_get FGT_VDOM)"; tok="$(env_get FGT_API_TOKEN)"
  if [ -n "${FGT_API_TOKEN:-}" ] && ! is_placeholder "$FGT_API_TOKEN"; then tok="$FGT_API_TOKEN"; env_set FGT_API_TOKEN "$tok"; fi
  if is_placeholder "$tok"; then
    if [ "$NONINTERACTIVE" = 1 ]; then
      warn "FGT_API_TOKEN not set - the dashboard will show 'FortiGate unreachable' until Stage 5 (or use --simulate on)"
      return
    fi
    printf '%sThe FortiGate API token is created in Stage 5 (execute api-user generate-key api_honeywall).%s\n' "$YEL" "$R"
    printf 'Paste it now, or press Enter to use rehearsal mode until then: ' >/dev/tty
    stty -echo </dev/tty 2>/dev/null || true
    read -r tok </dev/tty || tok=""
    stty echo </dev/tty 2>/dev/null || true
    printf '\n' >/dev/tty
    if [ -z "$tok" ]; then env_set FGT_SIMULATE true; warn "rehearsal mode enabled (FGT_SIMULATE=true) - rerun with --simulate off after Stage 5"; return; fi
    case "$tok" in *"|"*|*" "*) fail "token contains invalid characters" ;; esac
    env_set FGT_API_TOKEN "$tok"
  fi
  code="$(curl -sk -o /tmp/hw_fgt.json -w '%{http_code}' -m 8 -H "Authorization: Bearer $tok" \
    "https://$host/api/v2/monitor/system/status?vdom=$vdom" 2>/dev/null || true)"
  case "$code" in
    200)
      ver="$(sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' /tmp/hw_fgt.json | head -n 1)"
      hn="$(sed -n 's/.*"hostname" *: *"\([^"]*\)".*/\1/p' /tmp/hw_fgt.json | head -n 1)"
      ok "token valid - ${hn:-FortiGate} ${ver:-}" ;;
    401|403) warn "FortiGate rejected the token (HTTP $code): check trusthost 192.168.10.2/32 and the access profile (Stage 5)" ;;
    000) warn "cannot reach https://$host (allowaccess https on VLAN_QC_10? routing?)" ;;
    *) warn "unexpected HTTP $code from the FortiGate API" ;;
  esac
  rm -f /tmp/hw_fgt.json
}

remove_inactive() {
  # services from other profiles that are still running (e.g. switching standard -> lite)
  active="$(docker compose config --services 2>/dev/null)"
  for s in $(COMPOSE_PROFILES='*' docker compose config --services 2>/dev/null); do
    echo "$active" | grep -qx "$s" && continue
    if [ -n "$(COMPOSE_PROFILES='*' docker compose ps -q "$s" 2>/dev/null)" ]; then
      COMPOSE_PROFILES='*' docker compose rm -sf "$s" >/dev/null 2>&1 && info "stopped $s (not in profile $PROFILE)"
    fi
  done
}

deploy() {
  step "Build & start"
  cd "$BASE/compose"
  info "pulling images"
  docker compose pull --ignore-buildable --quiet
  info "building local images (engine, dashboard, decoy-web)"
  if [ "$UPDATE" = 1 ]; then docker compose build --pull --quiet; else docker compose build --quiet; fi
  remove_inactive
  docker compose up -d --remove-orphans
  ok "containers started"
}

wait_healthy() {
  step "Health checks"
  cd "$BASE/compose"
  i=0
  while :; do
    pending=""; bad=""
    for id in $(docker compose ps -q); do
      name="$(docker inspect -f '{{.Name}}' "$id" | sed 's#^/##')"
      st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id")"
      case "$st" in
        healthy|running) ;;
        exited) code="$(docker inspect -f '{{.State.ExitCode}}' "$id")"; [ "$code" = 0 ] || bad="$bad $name" ;;
        unhealthy) bad="$bad $name" ;;
        *) pending="$pending $name" ;;
      esac
    done
    [ -z "$pending" ] && break
    i=$((i + 1)); [ "$i" -gt 60 ] && break
    sleep 2
  done
  docker compose ps --format 'table {{.Name}}\t{{.State}}\t{{.Status}}'
  [ -z "$bad" ] || fail "unhealthy:$bad  ->  docker compose logs --tail=50 <service>   (see scripts/vt.md)"
  [ -z "$pending" ] || warn "still starting:$pending (check again with ./setup.sh --status)"
  [ -z "$pending" ] && ok "all services healthy"
}

summary() {
  cd "$BASE/compose"
  wan="$(env_get FGT_WAN_IP)"; alp="$(env_get ALPINE_IP)"; vip="$(env_get DECOY_VIP_IP)"
  h="$(curl -s -m 3 http://127.0.0.1:"$(env_get DASHBOARD_HOST_PORT)"/api/health 2>/dev/null || true)"
  svcs="$(docker compose config --services | tr '\n' ' ')"
  printf '\n%s+------------------------------------------------------------------------+%s\n' "$GRN" "$R"
  printf '%s|  HoneyWall is up%55s|%s\n' "$GRN" "" "$R"
  printf '%s+------------------------------------------------------------------------+%s\n' "$GRN" "$R"
  printf '  Profile        %s\n' "$(env_get COMPOSE_PROFILES)"
  printf '  Services       %s\n' "$svcs"
  printf '  Enforcement    %s (expiry %s = until Unban)%s\n' "$(env_get ENFORCEMENT_MODE)" "$(env_get BAN_EXPIRY)" \
    "$( [ "$(env_get FGT_SIMULATE)" = true ] && echo '  [REHEARSAL MODE]' )"
  printf '  Engine health  %s\n' "${h:-n/a (dashboard not in this profile)}"
  echo
  printf '  HoneyWall      http://%s:8080   (from your PC, WAN VIP - Stage 5)   http://%s/ (lab)\n' "$wan" "$alp"
  printf '  ntfy alerts    http://%s:8090/%s\n' "$wan" "$(env_get NTFY_TOPIC)"
  echo "$svcs" | grep -q dozzle && printf '  Dozzle logs    http://%s:9999\n' "$wan"
  printf '  SSH decoy      %s:%s  ->  %s:%s (Cowrie)\n' "$vip" "$(env_get DECOY_VIP_PORT)" "$alp" "$(env_get COWRIE_HOST_PORT)"
  echo "$svcs" | grep -q decoy-web && printf '  Web decoy      http://%s:%s  ->  %s:%s\n' "$vip" "$(env_get WEB_DECOY_VIP_PORT)" "$alp" "$(env_get WEB_DECOY_HOST_PORT)"
  echo
  printf '  Next: Stage 5 FortiGate config (docs/Fortinet-cli.md), then on Kali:\n'
  printf '        ./kali-attack-campaign.sh --all\n'
  printf '  Rehearse now: curl -s -XPOST -d %s http://127.0.0.1/api/test/simulate   (rehearsal mode only)\n' "'{\"act\":\"2\"}'"
  printf '  Logs:  cd %s/compose && docker compose logs -f engine\n\n' "$BASE"
}

status() {
  [ -f "$BASE/compose/docker-compose.yml" ] || fail "not installed in $BASE"
  cd "$BASE/compose"
  docker compose ps --format 'table {{.Name}}\t{{.State}}\t{{.Status}}'
  printf '\nengine: %s\n' "$(curl -s -m 3 http://127.0.0.1:"$(env_get DASHBOARD_HOST_PORT)"/api/health 2>/dev/null || echo 'no answer on the dashboard port')"
}

menu() {
  cur="$(env_get COMPOSE_PROFILES 2>/dev/null || true)"
  printf '\n%sHoneyWall setup%s  (installed profile: %s)\n' "$B" "$R" "${cur:-none}"
  printf '  1) Install / update - standard profile (video build)\n'
  printf '  2) Install / update - choose profile\n'
  printf '  3) Toggle AI reports (LLM)\n'
  printf '  4) Toggle rehearsal mode (simulated FortiGate)\n'
  printf '  5) Status\n'
  printf '  6) Quit\n'
  c="$(ask 'Choose' 1)"
  case "$c" in
    1) PROFILE=standard ;;
    2) PROFILE="$(ask 'Profile lite|standard|full' standard)" ;;
    3) if [ "$(env_get LLM_ENABLED 2>/dev/null)" = true ]; then LLM=off; else LLM=on; fi ;;
    4) if [ "$(env_get FGT_SIMULATE 2>/dev/null)" = true ]; then SIMULATE=off; else SIMULATE=on; fi ;;
    5) status; exit 0 ;;
    *) exit 0 ;;
  esac
}

# ------------------------------------------------------------------ main
printf '%sHoneyWall%s - live deception SOC setup\n' "$B" "$R"
if [ "$STATUS_ONLY" = 1 ]; then status; exit 0; fi
if [ "$NONINTERACTIVE" = 0 ] && [ -z "$PROFILE$LLM$SIMULATE" ] && [ "$UPDATE" = 0 ] && [ "$LOCAL" = 0 ]; then menu; fi
case "$PROFILE" in ""|lite|standard|full) ;; *) fail "profile must be lite, standard or full" ;; esac

preflight
ensure_deps
download
prepare_env
fgt_token
deploy
wait_healthy
summary
