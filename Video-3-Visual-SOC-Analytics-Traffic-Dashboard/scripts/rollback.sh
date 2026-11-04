#!/bin/sh
# filepath: https://github.com/rabakuku/Youtube/blob/main/Video-3-Visual-SOC-Analytics-Traffic-Dashboard/scripts/rollback.sh
# -----------------------------------------------------------------------------
# Zero-Cost Visual SOC — selectable teardown for Alpine Linux 3.24
#
#   ./rollback.sh                 interactive menu
#   ./rollback.sh --containers    stop + remove containers (data kept)
#   ./rollback.sh --all --yes     everything, no questions
#   curl -fsSL <raw>/scripts/rollback.sh | sh -s -- --all --yes
# -----------------------------------------------------------------------------
set -eu

PROJECT_NAME="visual-soc-analytics-traffic-dashboard"
PROJECT_DIR="/opt/${PROJECT_NAME}"
COMPOSE_DIR="${PROJECT_DIR}/compose"
MARKER="${PROJECT_DIR}/.setup-installed-tools"
COMPOSE_PROJECT="visual-soc"
IMAGES_DEFAULT="timberio/vector:0.36.0-alpine grafana/loki:2.9.4 grafana/grafana:10.3.3 binwiederhier/ntfy:v2.11.0 python:3.12.7-alpine3.20"
CONTAINERS="soc-vector soc-loki soc-grafana soc-ntfy soc-responder"
VOLUMES="vector_data loki_data grafana_data ntfy_cache responder_data"

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

usage() {
    cat <<USAGE
Visual SOC rollback — choose what to remove:
  --all          everything below, in safe order
  --containers   docker compose down (logs + dashboards kept)
  --volumes      down -v: DELETES all stored logs and Grafana data
  --images       remove the Vector, Loki, Grafana, ntfy and Python images
  --files        remove ${PROJECT_DIR}
  --tools        remove only what setup.sh installed (docker, compose plugin, curl, sysctl file)
  --yes          do not ask for confirmation
  --help         show this help
USAGE
}

[ "$(id -u)" -eq 0 ] || fail "Run as root (or: doas ./rollback.sh / sudo ./rollback.sh)."
[ -r /etc/os-release ] || fail "/etc/os-release not found — not compatible, Alpine Linux only."
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = "alpine" ] || fail "Detected '${ID:-unknown}' — not compatible, Alpine Linux only."

DO_CONTAINERS=0; DO_VOLUMES=0; DO_IMAGES=0; DO_FILES=0; DO_TOOLS=0; ASSUME_YES=0; ANY=0
for arg in "$@"; do
    case "$arg" in
        --all)        DO_CONTAINERS=1; DO_VOLUMES=1; DO_IMAGES=1; DO_FILES=1; DO_TOOLS=1; ANY=1 ;;
        --containers) DO_CONTAINERS=1; ANY=1 ;;
        --volumes)    DO_VOLUMES=1; ANY=1 ;;
        --images)     DO_IMAGES=1; ANY=1 ;;
        --files)      DO_FILES=1; ANY=1 ;;
        --tools)      DO_TOOLS=1; ANY=1 ;;
        --yes|-y)     ASSUME_YES=1 ;;
        --help|-h)    usage; exit 0 ;;
        *)            usage; fail "Unknown option: $arg" ;;
    esac
done

# Reads answers from the terminal even when the script itself is piped (curl | sh)
ask() { # $1 = prompt; returns 0 for yes
    [ "$ASSUME_YES" -eq 1 ] && return 0
    [ -r /dev/tty ] || fail "No terminal for confirmation — re-run with --yes."
    printf '%s[?]%s %s [y/N] ' "$C_Y" "$C_0" "$1" > /dev/tty
    read -r reply < /dev/tty || reply=""
    case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

if [ "$ANY" -eq 0 ]; then
    [ -r /dev/tty ] || { usage; fail "No option given and no terminal for the menu."; }
    cat > /dev/tty <<MENU

  Visual SOC rollback
  1) Everything (all)          4) Images
  2) Containers only           5) Project files (${PROJECT_DIR})
  3) Containers + volumes      6) Tools installed by setup.sh
  q) Quit
MENU
    printf 'Choice: ' > /dev/tty
    read -r choice < /dev/tty || choice="q"
    case "$choice" in
        1) DO_CONTAINERS=1; DO_VOLUMES=1; DO_IMAGES=1; DO_FILES=1; DO_TOOLS=1 ;;
        2) DO_CONTAINERS=1 ;;
        3) DO_CONTAINERS=1; DO_VOLUMES=1 ;;
        4) DO_IMAGES=1 ;;
        5) DO_FILES=1 ;;
        6) DO_TOOLS=1 ;;
        *) info "Nothing changed."; exit 0 ;;
    esac
fi

have_docker() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }
have_compose_file() { [ -f "${COMPOSE_DIR}/docker-compose.yml" ]; }
dc() { (cd "$COMPOSE_DIR" && docker compose "$@"); }

# Image list from .env when it still exists (keeps rollback in sync with pins)
IMAGES="$IMAGES_DEFAULT"
if [ -f "${COMPOSE_DIR}/.env" ]; then
    from_env="$(sed -n -e 's/^VECTOR_IMAGE=//p' -e 's/^LOKI_IMAGE=//p' -e 's/^GRAFANA_IMAGE=//p' \
        -e 's/^NTFY_IMAGE=//p' -e 's/^RESPONDER_IMAGE=//p' "${COMPOSE_DIR}/.env" | tr '\n' ' ')"
    [ -n "$from_env" ] && IMAGES="$from_env"
fi

# --- release active quarantines first (otherwise nobody lifts them later) -----
release_quarantines() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx soc-responder || return 0
    out="$(docker exec soc-responder wget -q -O- --post-data='' http://127.0.0.1:8092/release-all 2>/dev/null || true)"
    case "$out" in
        *'"released": {}'*) info "No active quarantines." ;;
        *'"released"'*)     ok "Released active quarantines on the FortiGate: $out" ;;
        *) warn "Could not ask the responder to release quarantines. Check the FortiGate group SOC-Quarantine by hand." ;;
    esac
}

# --- containers / volumes ----------------------------------------------------
if [ "$DO_CONTAINERS" -eq 1 ] || [ "$DO_VOLUMES" -eq 1 ]; then
    if have_docker; then
        release_quarantines
        if [ "$DO_VOLUMES" -eq 1 ]; then
            if ask "Delete containers AND volumes? All stored logs and Grafana data will be lost."; then
                if have_compose_file; then dc down -v --remove-orphans; else
                    # shellcheck disable=SC2086
                    docker rm -f $CONTAINERS >/dev/null 2>&1 || true
                    for v in $VOLUMES; do
                        docker volume rm "${COMPOSE_PROJECT}_${v}" >/dev/null 2>&1 || true
                    done
                fi
                docker network rm soc_net >/dev/null 2>&1 || true
                ok "Containers, volumes and soc_net removed."
            else
                warn "Skipped containers + volumes."
            fi
        else
            if have_compose_file; then dc down --remove-orphans; else
                # shellcheck disable=SC2086
                docker rm -f $CONTAINERS >/dev/null 2>&1 || true
            fi
            ok "Containers stopped and removed (volumes kept)."
        fi
    else
        warn "Docker is not running/installed — nothing to stop."
    fi
fi

# --- images --------------------------------------------------------------------
if [ "$DO_IMAGES" -eq 1 ]; then
    if have_docker; then
        if ask "Remove images: ${IMAGES}?"; then
            for img in $IMAGES; do
                if docker image inspect "$img" >/dev/null 2>&1; then
                    if docker rmi "$img" >/dev/null 2>&1; then
                        ok "Removed $img"
                    else
                        warn "$img still in use — remove its containers first."
                    fi
                fi
            done
        else
            warn "Skipped images."
        fi
    else
        warn "Docker is not running/installed — no images to remove."
    fi
fi

# --- tools (read marker BEFORE files are deleted) ------------------------------
TOOLS=""
[ -f "$MARKER" ] && TOOLS="$(cat "$MARKER")"

# --- files ---------------------------------------------------------------------
if [ "$DO_FILES" -eq 1 ]; then
    if [ -d "$PROJECT_DIR" ]; then
        if ask "Delete ${PROJECT_DIR} (configs, .env with your password)?"; then
            case "$PWD" in "$PROJECT_DIR"*) cd / ;; esac
            rm -rf "$PROJECT_DIR"
            ok "Removed ${PROJECT_DIR}."
        else
            warn "Skipped files."
        fi
    else
        info "${PROJECT_DIR} not present."
    fi
fi

# --- tools -----------------------------------------------------------------------
if [ "$DO_TOOLS" -eq 1 ]; then
    if [ -z "$TOOLS" ]; then
        info "setup.sh did not install any tools (or the marker is gone) — nothing to remove."
    elif ask "Remove tools setup.sh installed: $(echo "$TOOLS" | tr '\n' ' ')?"; then
        pkgs=""
        for t in $TOOLS; do
            case "$t" in
                sysctl:*)
                    rm -f "${t#sysctl:}"
                    ok "Removed ${t#sysctl:} (kernel default applies after reboot)." ;;
                openrc:docker)
                    service docker stop >/dev/null 2>&1 || true
                    rc-update del docker default >/dev/null 2>&1 || true
                    ok "docker removed from OpenRC." ;;
                *) pkgs="$pkgs $t" ;;
            esac
        done
        if [ -n "$pkgs" ]; then
            # shellcheck disable=SC2086
            apk del $pkgs >/dev/null && ok "apk del${pkgs}"
        fi
        [ -f "$MARKER" ] && rm -f "$MARKER"
    else
        warn "Skipped tools."
    fi
fi

ok "Rollback finished."
info "FortiGate objects (API user, VIPs, policies, group SOC-Quarantine) are not touched — remove them with docs/Fortinet-cli.md (rollback section)."
