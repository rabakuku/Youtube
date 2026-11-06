#!/usr/bin/env bash
# filepath: https://github.com/rabakuku/Youtube/blob/main/Video-4-HoneyWall-Live-Deception-SOC/scripts/llm-host-setup.sh
#
# HoneyWall - home LLM host setup (Ubuntu + NVIDIA GPU + Ollama)
#
# Runs on the GPU box (NOT in the lab). Detects what is installed, installs only what is missing,
# locks Ollama to localhost, puts an API-key gate (Caddy) in front of it, exposes the gate through
# Cloudflare Tunnel (default), Tailscale, or a direct port-forward, then self-tests everything and
# prints the exact .env lines for the lab.
#
#   sudo ./llm-host-setup.sh --mode cloudflare --hostname llm.ccdtt.com --allow-ip <work-public-ip>
#   sudo ./llm-host-setup.sh --mode tailscale
#   sudo ./llm-host-setup.sh --check
#   sudo ./llm-host-setup.sh --uninstall [--purge]
#
set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
MODE="cloudflare"
LLM_HOST="llm.ccdtt.com"
ZONE=""
MODEL="llama3.1:8b"
ALLOW_IPS=()
API_KEY=""
CF_API_TOKEN="${CF_API_TOKEN:-}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
TUNNEL_NAME="honeywall-llm"
GATE_PORT=8081
DIRECT_PORT=8443
CHECK_ONLY=0
UNINSTALL=0
PURGE=0
SKIP_GPU=0
ASSUME_YES=0

STATE_DIR=/etc/honeywall-llm
STATE_FILE=$STATE_DIR/state.env
CADDY_SNIPPET=/etc/caddy/honeywall-llm.caddy
CADDYFILE=/etc/caddy/Caddyfile
OLLAMA_OVERRIDE=/etc/systemd/system/ollama.service.d/honeywall.conf
CF_DIR=/etc/cloudflared
WAF_DESC="honeywall-llm-allowlist"

# ------------------------------------------------------------------ output helpers
if [ -t 1 ]; then R=$'\e[0m'; B=$'\e[1m'; RED=$'\e[1;31m'; GRN=$'\e[1;32m'; YEL=$'\e[1;33m'; CYN=$'\e[1;36m'; DIM=$'\e[2m'
else R=""; B=""; RED=""; GRN=""; YEL=""; CYN=""; DIM=""; fi
info() { printf '%s[ .. ]%s %s\n' "$CYN" "$R" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$GRN" "$R" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YEL" "$R" "$*"; }
fail() { printf '%s[FAIL]%s %s\n' "$RED" "$R" "$*" >&2; exit 1; }
step() { printf '\n%s== %s ==%s\n' "$B" "$*" "$R"; }
have() { command -v "$1" >/dev/null 2>&1; }
trap 'printf "%s[FAIL]%s line %s: %s\n" "$RED" "$R" "$LINENO" "$BASH_COMMAND" >&2' ERR

usage() {
  cat <<EOF
HoneyWall LLM host setup v$SCRIPT_VERSION

Usage: sudo $0 [options]

Access mode
  --mode cloudflare|tailscale|direct   How the lab reaches this box (default: cloudflare)
  --hostname FQDN                      Cloudflare hostname (default: llm.ccdtt.com)
  --zone DOMAIN                        Cloudflare zone (default: derived from hostname, e.g. ccdtt.com)
  --allow-ip IP[/CIDR]                 Public IP allowed to reach the LLM (repeatable).
                                       cloudflare: WAF allowlist   direct: ufw allowlist
  --cf-api-token TOKEN                 Cloudflare API token (Zone:Read + Zone WAF:Edit) to create the
                                       WAF allowlist rule automatically (or env CF_API_TOKEN)
  --ts-authkey KEY                     Tailscale auth key for unattended login (or env TS_AUTHKEY)
  --tunnel-name NAME                   Cloudflare tunnel name (default: honeywall-llm)

Model & key
  --model NAME                         Ollama model (default: llama3.1:8b - fits a 12 GB RTX 3060)
  --api-key KEY                        Bearer key for the gate (default: keep existing or generate)

Actions
  --check                              Detect + self-test only, change nothing
  --uninstall                          Remove the gate, tunnel/service config and firewall rules
  --purge                              With --uninstall: also remove Ollama and its models
  --skip-gpu                           Continue without an NVIDIA driver (CPU only, slow)
  --yes                                Do not ask for confirmation
  -h, --help                           This help
EOF
}

# ------------------------------------------------------------------ arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --hostname) LLM_HOST="${2:-}"; shift 2 ;;
    --zone) ZONE="${2:-}"; shift 2 ;;
    --allow-ip) ALLOW_IPS+=("${2:-}"); shift 2 ;;
    --cf-api-token) CF_API_TOKEN="${2:-}"; shift 2 ;;
    --ts-authkey) TS_AUTHKEY="${2:-}"; shift 2 ;;
    --tunnel-name) TUNNEL_NAME="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --api-key) API_KEY="${2:-}"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --purge) PURGE=1; shift ;;
    --skip-gpu) SKIP_GPU=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; fail "unknown option: $1" ;;
  esac
done

case "$MODE" in cloudflare|tailscale|direct) ;; *) fail "--mode must be cloudflare, tailscale or direct" ;; esac
[ -n "$ZONE" ] || ZONE="$(printf '%s' "$LLM_HOST" | awk -F. '{ if (NF >= 2) print $(NF-1)"."$NF }')"
for ip in "${ALLOW_IPS[@]:-}"; do
  [ -z "$ip" ] && continue
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || fail "--allow-ip '$ip' is not an IPv4 address or CIDR"
done

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  [ -t 0 ] || return 0
  read -r -p "$1 [y/N] " a
  [[ "$a" =~ ^[Yy]$ ]]
}

[ "$(id -u)" -eq 0 ] || fail "run as root: sudo $0 $*"

# ------------------------------------------------------------------ state (key, mode)
load_state() {
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    [ -n "$API_KEY" ] || API_KEY="${SAVED_API_KEY:-}"
  fi
}
save_state() {
  mkdir -p "$STATE_DIR"
  if [ "$MODE" = direct ]; then chmod 750 "$STATE_DIR"; else chmod 700 "$STATE_DIR"; fi
  umask 077
  cat > "$STATE_FILE" <<EOF
SAVED_API_KEY='$API_KEY'
SAVED_MODE='$MODE'
SAVED_HOST='$LLM_HOST'
SAVED_MODEL='$MODEL'
SAVED_TUNNEL='$TUNNEL_NAME'
SAVED_ALLOW='${ALLOW_IPS[*]:-}'
EOF
  umask 022
}

# ------------------------------------------------------------------ detection (the "which" step)
ver_of() { "$@" 2>/dev/null | head -n1 | tr -d '\r' || true; }
inventory() {
  step "Inventory (auto-detected)"
  local os gpu drv ol olsvc model caddy cfd ts ufwst
  os="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
  if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then
    gpu="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -n1)"
    drv="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1)"
  else gpu="not detected"; drv="missing"; fi
  ol="$(have ollama && ver_of ollama --version || echo missing)"
  olsvc="$(systemctl is-active ollama 2>/dev/null || true)"
  model="$(have ollama && ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -Fx "$MODEL" >/dev/null && echo present || echo "not pulled")"
  caddy="$(have caddy && ver_of caddy version || echo missing)"
  cfd="$(have cloudflared && ver_of cloudflared --version || echo missing)"
  ts="$(have tailscale && ver_of tailscale version || echo missing)"
  ufwst="$(have ufw && (ufw status 2>/dev/null | head -n1) || echo missing)"
  printf '  %-16s %s\n' "OS" "$os" "GPU" "$gpu" "NVIDIA driver" "$drv" \
    "Ollama" "$ol (service: ${olsvc:-n/a})" "Model $MODEL" "$model" "Caddy" "$caddy" \
    "cloudflared" "$cfd" "Tailscale" "$ts" "ufw" "$ufwst" \
    "curl/jq/openssl" "$(have curl && echo y || echo n)/$(have jq && echo y || echo n)/$(have openssl && echo y || echo n)"
}

apt_ready=0
apt_install() {
  local missing=()
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  [ ${#missing[@]} -eq 0 ] && return 0
  if [ "$apt_ready" = 0 ]; then info "apt-get update"; DEBIAN_FRONTEND=noninteractive apt-get update -qq; apt_ready=1; fi
  info "installing: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
  ok "installed: ${missing[*]}"
}

# ------------------------------------------------------------------ steps
preflight() {
  step "Preflight"
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || warn "this script targets Ubuntu; detected ${ID:-unknown} - continuing"
  case "${VERSION_ID:-}" in 26.04*) ok "Ubuntu ${VERSION_ID}" ;; *) warn "tested on Ubuntu 26.04, found ${VERSION_ID:-?}" ;; esac
  curl -fsS -m 8 -o /dev/null https://ollama.com || fail "no internet access (https://ollama.com unreachable)"
  ok "internet reachable"
  apt_install curl jq openssl ca-certificates gnupg
}

ensure_gpu() {
  step "NVIDIA GPU"
  if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then
    ok "$(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader | head -n1)"
    return
  fi
  if [ "$SKIP_GPU" = 1 ]; then warn "no NVIDIA driver - continuing on CPU (--skip-gpu). Reports will be slow."; return; fi
  warn "NVIDIA driver not working (nvidia-smi missing or failing)"
  confirm "Install the recommended NVIDIA driver with ubuntu-drivers now?" || fail "driver required (or rerun with --skip-gpu)"
  apt_install ubuntu-drivers-common
  ubuntu-drivers install
  printf '\n%sDriver installed. REBOOT now, then run the exact same command again.%s\n' "$YEL" "$R"
  exit 3
}

ensure_ollama() {
  step "Ollama"
  if ! have ollama; then
    info "installing Ollama (official installer)"
    curl -fsSL https://ollama.com/install.sh | sh
  fi
  ok "$(ollama --version 2>/dev/null | head -n1)"
  mkdir -p "$(dirname "$OLLAMA_OVERRIDE")"
  cat > "$OLLAMA_OVERRIDE" <<'EOF'
# HoneyWall: keep Ollama on localhost only (the API-key gate is the only door) and keep the model warm
[Service]
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_KEEP_ALIVE=24h"
EOF
  systemctl daemon-reload
  systemctl enable --now ollama >/dev/null 2>&1 || true
  systemctl restart ollama
  for _ in $(seq 1 30); do curl -fsS -m 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1 && break; sleep 1; done
  curl -fsS -m 2 http://127.0.0.1:11434/api/version >/dev/null || fail "Ollama is not answering on 127.0.0.1:11434 (journalctl -u ollama)"
  ok "Ollama listening on 127.0.0.1:11434 only"
  if ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -Fx "$MODEL" >/dev/null; then ok "model $MODEL present"
  else info "pulling $MODEL (first time takes a few minutes)"; ollama pull "$MODEL"; ok "model $MODEL pulled"; fi
  info "warming up $MODEL on the GPU"
  curl -fsS -m 180 http://127.0.0.1:11434/api/generate -d "{\"model\":\"$MODEL\",\"prompt\":\"ok\",\"stream\":false,\"keep_alive\":\"24h\"}" >/dev/null && ok "model loaded"
}

ensure_key() {
  if [ -z "$API_KEY" ]; then API_KEY="$(openssl rand -hex 32)"; ok "generated a new API key"; else ok "using existing API key"; fi
  [[ "$API_KEY" =~ ^[A-Za-z0-9._-]{16,}$ ]] || fail "API key must be 16+ chars of [A-Za-z0-9._-]"
}

TS_IP=""
ensure_tailscale() {
  step "Tailscale"
  have tailscale || { info "installing Tailscale"; curl -fsSL https://tailscale.com/install.sh | sh; }
  systemctl enable --now tailscaled >/dev/null 2>&1 || true
  local st
  st="$(tailscale status --json 2>/dev/null | jq -r '.BackendState' 2>/dev/null || echo unknown)"
  if [ "$st" != "Running" ]; then
    if [ -n "$TS_AUTHKEY" ]; then tailscale up --hostname=honeywall-gpu --authkey="$TS_AUTHKEY"
    else info "log in to Tailscale - open the URL it prints:"; tailscale up --hostname=honeywall-gpu; fi
  fi
  TS_IP="$(tailscale ip -4 | head -n1)"
  [ -n "$TS_IP" ] || fail "no Tailscale IPv4 address"
  ok "tailnet IP $TS_IP (MagicDNS: honeywall-gpu)"
}

is_stock_caddyfile() {
  [ -f "$CADDYFILE" ] || return 0
  grep -q 'managed by HoneyWall' "$CADDYFILE" && return 0
  grep -q '/usr/share/caddy' "$CADDYFILE" || return 1
  local lines
  lines="$(grep -cvE '^[[:space:]]*(#|$)' "$CADDYFILE" || true)"
  [ "${lines:-0}" -le 6 ]
}

ensure_selfsigned() {
  [ -f "$STATE_DIR/gate.crt" ] && return 0
  mkdir -p "$STATE_DIR"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 825 \
    -subj "/CN=honeywall-llm" -keyout "$STATE_DIR/gate.key" -out "$STATE_DIR/gate.crt" >/dev/null 2>&1
  chgrp caddy "$STATE_DIR" "$STATE_DIR/gate.key" "$STATE_DIR/gate.crt" 2>/dev/null || true
  chmod 750 "$STATE_DIR"; chmod 640 "$STATE_DIR/gate.key" "$STATE_DIR/gate.crt"
  ok "self-signed certificate for the direct-mode gate"
}

ensure_caddy() {
  step "API-key gate (Caddy)"
  if ! have caddy; then
    if ! apt_install caddy 2>/dev/null; then
      info "adding the official Caddy repository"
      curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
      curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
      apt_ready=0; apt_install caddy
    fi
  fi
  ok "$(caddy version | head -n1)"
  local site bind
  # No hostname in the site address: requests arrive with Host llm.ccdtt.com (tunnel), the tailnet IP,
  # or your public IP - the listener is restricted with "bind" instead.
  local tlsline=""
  case "$MODE" in
    cloudflare) site="http://:$GATE_PORT"; bind="127.0.0.1" ;;
    tailscale)  site="http://:$GATE_PORT"; bind="$TS_IP" ;;
    direct)     site="https://:$DIRECT_PORT"; bind="0.0.0.0"; ensure_selfsigned; tlsline="	tls $STATE_DIR/gate.crt $STATE_DIR/gate.key" ;;
  esac
  mkdir -p /var/log/caddy
  umask 027
  cat > "$CADDY_SNIPPET" <<EOF
# HoneyWall LLM gate - generated by llm-host-setup.sh ($MODE mode). Do not edit; rerun the script.
$site {
	bind $bind
$tlsline
	@authorized header Authorization "Bearer $API_KEY"
	handle @authorized {
		reverse_proxy 127.0.0.1:11434 {
			# Ollama rejects non-local Host headers when bound to localhost
			header_up Host 127.0.0.1:11434
		}
	}
	handle {
		respond "unauthorized" 401
	}
	log {
		output file /var/log/caddy/honeywall-llm.log
	}
}
EOF
  umask 022
  chown root:caddy "$CADDY_SNIPPET" 2>/dev/null || true
  chmod 640 "$CADDY_SNIPPET"
  # stock Ubuntu Caddyfile only serves the welcome page on :80 - replace it; otherwise just import ours
  if is_stock_caddyfile; then
    [ -f "$CADDYFILE" ] && cp "$CADDYFILE" "$CADDYFILE.bak.$(date +%s)"
    printf '# managed by HoneyWall llm-host-setup.sh\nimport %s\n' "$CADDY_SNIPPET" > "$CADDYFILE"
  elif ! grep -qF "import $CADDY_SNIPPET" "$CADDYFILE"; then
    cp "$CADDYFILE" "$CADDYFILE.bak.$(date +%s)"
    printf '\nimport %s\n' "$CADDY_SNIPPET" >> "$CADDYFILE"
    warn "existing Caddyfile kept; added: import $CADDY_SNIPPET"
  fi
  caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 || { caddy validate --config "$CADDYFILE" --adapter caddyfile; fail "Caddy config invalid"; }
  systemctl enable --now caddy >/dev/null 2>&1 || true
  systemctl restart caddy
  sleep 1
  ok "gate listening on $site (bind $bind) -> 127.0.0.1:11434"
}

cf_api() { # method path [json]
  local args=(-fsS -m 20 -X "$1" "https://api.cloudflare.com/client/v4$2" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")
  [ $# -ge 3 ] && args+=(--data "$3")
  curl "${args[@]}"
}

ensure_waf() {
  [ ${#ALLOW_IPS[@]} -gt 0 ] || { warn "no --allow-ip given: anyone with the API key can reach https://$LLM_HOST"; return; }
  local list expr rule
  list="$(printf '%s ' "${ALLOW_IPS[@]}")"; list="${list% }"
  expr="(http.host eq \"$LLM_HOST\" and not ip.src in {$list})"
  if [ -z "$CF_API_TOKEN" ]; then
    warn "no --cf-api-token: create the IP allowlist rule by hand (Cloudflare dashboard):"
    printf '    %s → Security → WAF → Custom rules → Create rule\n' "$ZONE"
    printf '    Name: %s   Action: Block   Expression (Edit expression):\n    %s\n' "$WAF_DESC" "$expr"
    return
  fi
  step "Cloudflare WAF allowlist"
  local zid rs rid
  zid="$(cf_api GET "/zones?name=$ZONE" | jq -r '.result[0].id // empty')"
  [ -n "$zid" ] || fail "zone $ZONE not found for this API token"
  rule="$(jq -nc --arg d "$WAF_DESC" --arg e "$expr" '{description:$d, expression:$e, action:"block"}')"
  if rs="$(cf_api GET "/zones/$zid/rulesets/phases/http_request_firewall_custom/entrypoint" 2>/dev/null)"; then
    local rsid; rsid="$(jq -r '.result.id' <<<"$rs")"
    rid="$(jq -r --arg d "$WAF_DESC" '.result.rules[]? | select(.description==$d) | .id' <<<"$rs" | head -n1)"
    if [ -n "$rid" ]; then cf_api PATCH "/zones/$zid/rulesets/$rsid/rules/$rid" "$rule" >/dev/null; ok "updated WAF rule $WAF_DESC"
    else cf_api POST "/zones/$zid/rulesets/$rsid/rules" "$rule" >/dev/null; ok "added WAF rule $WAF_DESC (your other rules are untouched)"; fi
  else
    cf_api PUT "/zones/$zid/rulesets/phases/http_request_firewall_custom/entrypoint" "{\"rules\":[$rule]}" >/dev/null
    ok "created WAF custom ruleset with $WAF_DESC"
  fi
  ok "only ${list} can reach https://$LLM_HOST"
}

ensure_cloudflare() {
  step "Cloudflare Tunnel ($LLM_HOST)"
  if ! have cloudflared; then
    info "adding the Cloudflare package repository"
    mkdir -p /usr/share/keyrings && chmod 0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" > /etc/apt/sources.list.d/cloudflared.list
    apt_ready=0; apt_install cloudflared
  fi
  ok "$(cloudflared --version | head -n1)"
  if [ ! -f /root/.cloudflared/cert.pem ]; then
    [ -t 0 ] || fail "not logged in to Cloudflare: run 'sudo cloudflared tunnel login' once, then rerun"
    info "log in to Cloudflare: open the URL below and pick the zone $ZONE"
    cloudflared tunnel login
  fi
  ok "Cloudflare account authorized"
  local uuid
  uuid="$(cloudflared tunnel list --output json 2>/dev/null | jq -r --arg n "$TUNNEL_NAME" '.[] | select(.name==$n) | .id' | head -n1)"
  if [ -z "$uuid" ]; then
    cloudflared tunnel create "$TUNNEL_NAME" >/dev/null
    uuid="$(cloudflared tunnel list --output json | jq -r --arg n "$TUNNEL_NAME" '.[] | select(.name==$n) | .id' | head -n1)"
    ok "created tunnel $TUNNEL_NAME ($uuid)"
  else ok "tunnel $TUNNEL_NAME exists ($uuid)"; fi
  mkdir -p "$CF_DIR"
  [ -f "/root/.cloudflared/$uuid.json" ] && install -m 600 "/root/.cloudflared/$uuid.json" "$CF_DIR/$uuid.json"
  [ -f "$CF_DIR/$uuid.json" ] || fail "tunnel credentials $uuid.json not found (delete the tunnel and rerun)"
  if [ -f "$CF_DIR/config.yml" ] && ! grep -q 'honeywall' "$CF_DIR/config.yml"; then
    cp "$CF_DIR/config.yml" "$CF_DIR/config.yml.bak.$(date +%s)"
    warn "existing $CF_DIR/config.yml backed up and replaced"
  fi
  cat > "$CF_DIR/config.yml" <<EOF
# managed by HoneyWall llm-host-setup.sh
tunnel: $uuid
credentials-file: $CF_DIR/$uuid.json
ingress:
  - hostname: $LLM_HOST
    service: http://127.0.0.1:$GATE_PORT
    originRequest:
      connectTimeout: 10s
  - service: http_status:404
EOF
  cloudflared tunnel route dns --overwrite-dns "$TUNNEL_NAME" "$LLM_HOST" >/dev/null 2>&1 \
    && ok "DNS $LLM_HOST → tunnel" || warn "could not create DNS route (is $ZONE on Cloudflare DNS?)"
  if ! systemctl list-unit-files 2>/dev/null | grep -q '^cloudflared.service'; then cloudflared service install >/dev/null 2>&1 || true; fi
  systemctl enable --now cloudflared >/dev/null 2>&1 || true
  systemctl restart cloudflared
  ok "cloudflared service running"
  ensure_waf
}

ensure_direct() {
  step "Direct mode (port-forward + ufw)"
  apt_install ufw
  ufw allow OpenSSH >/dev/null
  [ ${#ALLOW_IPS[@]} -gt 0 ] || fail "direct mode needs at least one --allow-ip"
  for ip in "${ALLOW_IPS[@]}"; do ufw allow from "$ip" to any port "$DIRECT_PORT" proto tcp comment "honeywall-llm" >/dev/null; ok "ufw: $ip → :$DIRECT_PORT"; done
  if ! ufw status | grep -q 'Status: active'; then
    confirm "Enable ufw now? (OpenSSH is allowed first so you won't be locked out)" && ufw --force enable >/dev/null && ok "ufw enabled"
  fi
  warn "on your home router: forward TCP $DIRECT_PORT → this box ($(hostname -I | awk '{print $1}')):$DIRECT_PORT"
}

ensure_ts_firewall() {
  if have ufw && ufw status | grep -q 'Status: active'; then
    ufw allow in on tailscale0 to any port "$GATE_PORT" proto tcp comment "honeywall-llm" >/dev/null
    ok "ufw: tailscale0 → :$GATE_PORT"
  fi
}

# ------------------------------------------------------------------ self-tests
PASS=0; FAILS=0
t_ok()   { printf '  %sPASS%s %s\n' "$GRN" "$R" "$*"; PASS=$((PASS+1)); }
t_fail() { printf '  %sFAIL%s %s\n' "$RED" "$R" "$*"; FAILS=$((FAILS+1)); }
t_note() { printf '  %sNOTE%s %s\n' "$YEL" "$R" "$*"; }
http_code() { local c; c="$(curl -s -o /dev/null -w '%{http_code}' -m "${TMO:-60}" "$@" 2>/dev/null || true)"; echo "${c:-000}"; }

gate_url() {
  case "$MODE" in
    cloudflare) echo "http://127.0.0.1:$GATE_PORT" ;;
    tailscale)  echo "http://${TS_IP:-$(tailscale ip -4 2>/dev/null | head -n1)}:$GATE_PORT" ;;
    direct)     echo "https://127.0.0.1:$DIRECT_PORT" ;;
  esac
}

self_test() {
  step "Self-tests"
  local body t0 ms gu code
  body="{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: HoneyWall LLM OK\"}],\"max_tokens\":12,\"stream\":false}"
  if curl -fsS -m 3 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then t_ok "Ollama answers on 127.0.0.1:11434"; else t_fail "Ollama not answering locally"; fi
  if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ':11434$' | grep -vqE '^(127\.0\.0\.1|\[::1\]):'; then t_fail "Ollama is listening on a non-local address"; else t_ok "Ollama is bound to localhost only"; fi
  t0=$(date +%s%3N)
  if curl -fsS -m 120 http://127.0.0.1:11434/v1/chat/completions -H 'Content-Type: application/json' -d "$body" | jq -e '.choices[0].message.content' >/dev/null 2>&1; then
    ms=$(( $(date +%s%3N) - t0 )); t_ok "local chat completion with $MODEL (${ms} ms)"
  else t_fail "local chat completion with $MODEL"; fi
  gu="$(gate_url)"
  code="$(TMO=120 http_code -k "$gu/v1/chat/completions" -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' -d "$body")"
  [ "$code" = 200 ] && t_ok "gate with key → 200 ($gu)" || t_fail "gate with key → $code ($gu)"
  code="$(TMO=10 http_code -k "$gu/v1/models")"
  [ "$code" = 401 ] && t_ok "gate without key → 401" || t_fail "gate without key → $code (expected 401)"
  code="$(TMO=10 http_code -k "$gu/v1/models" -H "Authorization: Bearer wrong-key-0000000000")"
  [ "$code" = 401 ] && t_ok "gate with a wrong key → 401" || t_fail "gate with a wrong key → $code (expected 401)"
  if [ "$MODE" = cloudflare ]; then
    systemctl is-active --quiet cloudflared && t_ok "cloudflared service active" || t_fail "cloudflared service not active"
    code="$(TMO=20 http_code "https://$LLM_HOST/v1/models" -H "Authorization: Bearer $API_KEY")"
    case "$code" in
      200) t_ok "https://$LLM_HOST with key → 200 (this box's IP is allowed or no allowlist yet)" ;;
      403) t_note "https://$LLM_HOST → 403 from this box: the WAF allowlist is blocking non-work IPs (expected). Test from Alpine." ;;
      530|502|1033) t_fail "https://$LLM_HOST → $code: tunnel not connected yet (journalctl -u cloudflared)" ;;
      *) t_fail "https://$LLM_HOST with key → $code" ;;
    esac
    code="$(TMO=20 http_code "https://$LLM_HOST/v1/models")"
    case "$code" in 401|403) t_ok "https://$LLM_HOST without key → $code (closed)";; *) t_fail "https://$LLM_HOST without key → $code (expected 401/403)";; esac
  fi
  printf '\n  %s%d passed, %d failed%s\n' "$B" "$PASS" "$FAILS" "$R"
}

print_env() {
  step "Paste into the lab: /opt/honeywall/compose/.env"
  case "$MODE" in
    cloudflare) cat <<EOF
LLM_ENABLED=true
LLM_ACCESS_MODE=cloudflare
LLM_BASE_URL=https://$LLM_HOST
LLM_API_KEY=$API_KEY
LLM_MODEL=$MODEL
LLM_VERIFY_TLS=true
LLM_HTTP_PROXY=
EOF
    ;;
    tailscale) cat <<EOF
COMPOSE_PROFILES=standard,llm-tailscale
LLM_ENABLED=true
LLM_ACCESS_MODE=tailscale
LLM_BASE_URL=http://${TS_IP:-<tailscale-ip>}:$GATE_PORT
LLM_API_KEY=$API_KEY
LLM_MODEL=$MODEL
LLM_VERIFY_TLS=true
LLM_HTTP_PROXY=http://tailscale:1055
TS_AUTHKEY=<a reusable auth key from the Tailscale admin console>
EOF
    ;;
    direct) cat <<EOF
LLM_ENABLED=true
LLM_ACCESS_MODE=direct
LLM_BASE_URL=https://<your-home-public-ip-or-ddns>:$DIRECT_PORT
LLM_API_KEY=$API_KEY
LLM_MODEL=$MODEL
LLM_VERIFY_TLS=false
LLM_HTTP_PROXY=
EOF
    ;;
  esac
  printf '\nThen on Alpine:  cd /opt/honeywall/compose && docker compose up -d && curl -s -XPOST http://127.0.0.1/api/test/llm; echo\n'
  [ "$MODE" != cloudflare ] || printf 'Quick check from Alpine:  curl -s https://%s/v1/models -H "Authorization: Bearer <LLM_API_KEY>" | head -c 200; echo\n' "$LLM_HOST"
  printf '%sThe key is also saved in %s (root only).%s\n' "$DIM" "$STATE_FILE" "$R"
}

# ------------------------------------------------------------------ uninstall
uninstall() {
  step "Uninstall"
  confirm "Remove the HoneyWall LLM gate and access layer from this box?" || exit 0
  if [ -f "$CADDY_SNIPPET" ]; then
    rm -f "$CADDY_SNIPPET"
    sed -i "\#import $CADDY_SNIPPET#d" "$CADDYFILE" 2>/dev/null || true
    grep -qvE '^\s*(#|$)' "$CADDYFILE" 2>/dev/null || systemctl stop caddy 2>/dev/null || true
    systemctl reload caddy 2>/dev/null || true
    ok "Caddy gate removed"
  fi
  if [ -f "$CF_DIR/config.yml" ] && grep -q honeywall "$CF_DIR/config.yml"; then
    cloudflared service uninstall >/dev/null 2>&1 || systemctl disable --now cloudflared 2>/dev/null || true
    rm -f "$CF_DIR/config.yml"
    ok "cloudflared service removed (tunnel '$TUNNEL_NAME' kept - delete with: cloudflared tunnel delete -f $TUNNEL_NAME)"
    warn "remove the DNS record $LLM_HOST and WAF rule '$WAF_DESC' in the Cloudflare dashboard if no longer needed"
  fi
  if have ufw; then
    while ufw status numbered 2>/dev/null | grep -q honeywall-llm; do
      n="$(ufw status numbered | grep honeywall-llm | head -n1 | sed -E 's/^\[ *([0-9]+)\].*/\1/')"
      ufw --force delete "$n" >/dev/null
    done
    ok "ufw rules removed"
  fi
  rm -f "$OLLAMA_OVERRIDE"; systemctl daemon-reload; systemctl restart ollama 2>/dev/null || true
  if [ "$PURGE" = 1 ]; then
    confirm "PURGE: also remove Ollama and all downloaded models?" && {
      systemctl disable --now ollama 2>/dev/null || true
      rm -f /etc/systemd/system/ollama.service /usr/local/bin/ollama /usr/bin/ollama
      rm -rf /usr/share/ollama /usr/local/lib/ollama
      userdel ollama 2>/dev/null || true
      ok "Ollama purged"
    }
  fi
  rm -rf "$STATE_DIR"
  ok "done"
}

# ------------------------------------------------------------------ main
printf '%sHoneyWall LLM host setup v%s%s  mode=%s host=%s model=%s\n' "$B" "$SCRIPT_VERSION" "$R" "$MODE" "$LLM_HOST" "$MODEL"
load_state
if [ -n "${SAVED_MODE:-}" ] && [ "${SAVED_MODE}" != "$MODE" ] && [ "$CHECK_ONLY" = 0 ] && [ "$UNINSTALL" = 0 ]; then
  warn "switching from $SAVED_MODE to $MODE mode (the old access layer stays until --uninstall)"
fi

if [ "$UNINSTALL" = 1 ]; then uninstall; exit 0; fi

inventory
if [ "$CHECK_ONLY" = 1 ]; then
  [ -z "$API_KEY" ] && fail "no saved API key - run the setup first"
  if [ "$MODE" = tailscale ]; then TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"; fi
  self_test
  [ "$FAILS" -eq 0 ] || exit 1
  exit 0
fi

preflight
ensure_gpu
ensure_ollama
ensure_key
if [ "$MODE" = tailscale ]; then ensure_tailscale; fi
ensure_caddy
case "$MODE" in
  cloudflare) ensure_cloudflare ;;
  tailscale)  ensure_ts_firewall ;;
  direct)     ensure_direct ;;
esac
save_state
self_test
print_env
[ "$FAILS" -eq 0 ] || { warn "some tests failed - see above, fix, then rerun (safe to rerun any time)"; exit 1; }
ok "LLM host ready"
