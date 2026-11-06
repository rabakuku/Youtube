#!/bin/sh
# filepath: https://github.com/rabakuku/Youtube/blob/main/Video-4-HoneyWall-Live-Deception-SOC/scripts/rollback.sh
#
# HoneyWall - selectable teardown for Alpine (POSIX sh). Interactive menu or flags.
#   ./rollback.sh                 menu
#   ./rollback.sh --containers    stop and remove containers (data kept)
#   ./rollback.sh --all --yes     everything, no questions
set -eu

BASE=/opt/honeywall
MARKER=/var/lib/honeywall/installed-tools
DO_CONTAINERS=0; DO_VOLUMES=0; DO_IMAGES=0; DO_FILES=0; DO_TOOLS=0; YES=0; BACKUP=1

if [ -t 1 ]; then
  ESC=$(printf '\033'); R="${ESC}[0m"; B="${ESC}[1m"; RED="${ESC}[1;31m"; GRN="${ESC}[1;32m"; YEL="${ESC}[1;33m"; CYN="${ESC}[1;36m"
else R=""; B=""; RED=""; GRN=""; YEL=""; CYN=""; fi
info() { printf '%s[ .. ]%s %s\n' "$CYN" "$R" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$GRN" "$R" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YEL" "$R" "$*"; }
fail() { printf '%s[FAIL]%s %s\n' "$RED" "$R" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
HoneyWall rollback (Alpine)

Usage: ./rollback.sh [options]        (no options = menu)

  --all          Everything below, in a safe order
  --containers   docker compose down (all profiles) - data volumes are kept
  --volumes      Also delete volumes: Cowrie logs, TTY recordings, reports, ntfy cache (DATA LOSS)
                 Reports are backed up to /root/honeywall-reports-<date>.tgz first
  --no-backup    Skip that reports backup
  --images       Remove the images used by the stack (local builds + pulled images)
  --files        Remove $BASE (your compose/.env with the FortiGate token goes too)
  --tools        apk del the packages setup.sh installed (only those - tracked in $MARKER)
  --yes, -y      Do not ask for confirmation
  -h, --help     This help
EOF
}

[ $# -eq 0 ] && MENU=1 || MENU=0
while [ $# -gt 0 ]; do
  case "$1" in
    --all) DO_CONTAINERS=1; DO_VOLUMES=1; DO_IMAGES=1; DO_FILES=1; DO_TOOLS=1; shift ;;
    --containers) DO_CONTAINERS=1; shift ;;
    --volumes) DO_CONTAINERS=1; DO_VOLUMES=1; shift ;;
    --no-backup) BACKUP=0; shift ;;
    --images) DO_CONTAINERS=1; DO_IMAGES=1; shift ;;
    --files) DO_FILES=1; shift ;;
    --tools) DO_TOOLS=1; shift ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; fail "unknown option: $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || fail "run as root"
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = "alpine" ] || fail "not compatible: this script is for Alpine Linux only (found ${ID:-unknown})"

confirm() {
  [ "$YES" = 1 ] && return 0
  [ -t 0 ] || fail "refusing to run destructive step without a terminal - add --yes"
  printf '%s%s%s [y/N] ' "$YEL" "$1" "$R"
  read -r a || a=""
  case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

if [ "$MENU" = 1 ]; then
  printf '\n%sHoneyWall rollback%s\n' "$B" "$R"
  printf '  1) Everything (containers, volumes, images, files, tools)\n'
  printf '  2) Containers only (keep data)\n'
  printf '  3) Containers + volumes (delete data, reports backed up)\n'
  printf '  4) Images\n'
  printf '  5) Files in %s\n' "$BASE"
  printf '  6) Tools installed by setup.sh\n'
  printf '  7) Quit\n'
  printf 'Choose [2]: '
  read -r c || c=""
  case "${c:-2}" in
    1) DO_CONTAINERS=1; DO_VOLUMES=1; DO_IMAGES=1; DO_FILES=1; DO_TOOLS=1 ;;
    2) DO_CONTAINERS=1 ;;
    3) DO_CONTAINERS=1; DO_VOLUMES=1 ;;
    4) DO_CONTAINERS=1; DO_IMAGES=1 ;;
    5) DO_FILES=1 ;;
    6) DO_TOOLS=1 ;;
    *) exit 0 ;;
  esac
fi

have_compose() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && [ -f "$BASE/compose/docker-compose.yml" ]; }
dc() { (cd "$BASE/compose" && COMPOSE_PROFILES='*' docker compose "$@"); }

backup_reports() {
  [ "$BACKUP" = 1 ] || return 0
  vol="$(docker volume ls -q | grep -x 'honeywall_honeywall-data' || true)"
  [ -n "$vol" ] || return 0
  img="$(docker images -q honeywall-engine:local 2>/dev/null)"
  [ -n "$img" ] || { warn "engine image missing - cannot back up reports (skipping)"; return 0; }
  out="/root/honeywall-reports-$(date +%Y%m%d-%H%M%S).tgz"
  if docker run --rm --entrypoint tar -v "$vol":/data:ro -v /root:/out honeywall-engine:local \
       czf "/out/$(basename "$out")" -C /data reports >/dev/null 2>&1; then ok "reports backed up to $out"
  else warn "reports backup failed (continuing)"; fi
}

if [ "$DO_CONTAINERS" = 1 ]; then
  if have_compose; then
    if [ "$DO_VOLUMES" = 1 ]; then
      confirm "Delete ALL HoneyWall data (Cowrie logs, TTY recordings, reports, ntfy cache)?" || { warn "volumes kept"; DO_VOLUMES=0; }
    fi
    [ "$DO_VOLUMES" = 1 ] && backup_reports
    if [ "$DO_VOLUMES" = 1 ] && [ "$DO_IMAGES" = 1 ]; then dc down --remove-orphans -v --rmi all
    elif [ "$DO_VOLUMES" = 1 ]; then dc down --remove-orphans -v
    elif [ "$DO_IMAGES" = 1 ]; then dc down --remove-orphans --rmi all
    else dc down --remove-orphans; fi
    ok "containers removed$( [ "$DO_VOLUMES" = 1 ] && echo ', volumes deleted' )$( [ "$DO_IMAGES" = 1 ] && echo ', images removed' )"
  else
    warn "no compose project in $BASE (or Docker not running) - skipping container/volume/image steps"
  fi
fi

if [ "$DO_FILES" = 1 ]; then
  if [ -d "$BASE" ]; then
    confirm "Remove $BASE (including compose/.env with your FortiGate token)?" && { rm -rf "$BASE"; ok "removed $BASE"; }
  else ok "$BASE already gone"; fi
fi

if [ "$DO_TOOLS" = 1 ]; then
  if [ -s "$MARKER" ]; then
    pkgs="$(grep -v '^openrc:' "$MARKER" | tr '\n' ' ')"
    confirm "Remove packages installed by setup.sh: ${pkgs:-none}?" && {
      if grep -qx 'openrc:docker' "$MARKER"; then service docker stop >/dev/null 2>&1 || true; rc-update del docker default >/dev/null 2>&1 || true; ok "docker removed from OpenRC"; fi
      # shellcheck disable=SC2086
      [ -n "$pkgs" ] && apk del $pkgs >/dev/null && ok "removed: $pkgs"
      rm -f "$MARKER"; rmdir /var/lib/honeywall 2>/dev/null || true
    }
  else ok "setup.sh did not install any packages (nothing to remove)"; fi
fi

info "done"
