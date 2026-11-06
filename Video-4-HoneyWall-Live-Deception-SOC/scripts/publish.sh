#!/bin/sh
# filepath: https://github.com/rabakuku/Youtube/blob/main/Video-4-HoneyWall-Live-Deception-SOC/scripts/publish.sh
#
# Publish a video folder from a .tar.gz into the GitHub monorepo. Runs on the git machine (bdx01),
# NOT in the lab. POSIX sh.
#
#   ./publish.sh --sentinel-file scripts/setup.sh --sentinel-string 'HoneyWall' -m "Stage 4 - scripts"
#   ./publish.sh --dry-run
#   ./publish.sh --retire Video-4-Active-Honeypot-Instant-Auto-Quarantine -m "Retire old Video 4"
#
# Order of operations (stops at the first failure, so a bad archive never deletes anything):
#   git pull -> archive exists -> folder + sentinel inside archive -> secret scan of the archive
#   -> git rm old folder -> extract -> git add -> commit -> push
set -eu

REPO="${REPO:-$HOME/Youtube}"
FOLDER="Video-4-HoneyWall-Live-Deception-SOC"
ARCHIVE=""
SENTINEL_FILE="docs/Lab-Matrix.md"
SENTINEL_STRING="HoneyWall"
MESSAGE=""
BRANCH="main"
DRY=0
RETIRE=""
SKIP_SCAN=0

if [ -t 1 ]; then
  ESC=$(printf '\033'); R="${ESC}[0m"; B="${ESC}[1m"; RED="${ESC}[1;31m"; GRN="${ESC}[1;32m"; YEL="${ESC}[1;33m"; CYN="${ESC}[1;36m"
else R=""; B=""; RED=""; GRN=""; YEL=""; CYN=""; fi
info() { printf '%s[ .. ]%s %s\n' "$CYN" "$R" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$GRN" "$R" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YEL" "$R" "$*"; }
fail() { printf '%s[FAIL]%s %s\n' "$RED" "$R" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Publish a video folder from a tarball into the monorepo.

Usage: $0 [options]

  --archive PATH           Tarball (default: \$HOME/<folder>.tar.gz)
  --repo PATH              Local clone of the monorepo (default: \$HOME/Youtube)
  --folder NAME            Top-level folder inside the archive (default: $FOLDER)
  --sentinel-file PATH     File inside the folder that must exist (default: $SENTINEL_FILE)
  --sentinel-string TEXT   Text that file must contain (default: $SENTINEL_STRING)
  -m, --message TEXT       Commit message (default: "<folder>: update")
  --branch NAME            Branch to push (default: main)
  --retire FOLDER          Also delete another folder in the same commit (e.g. the old Video 4)
  --skip-scan              Skip the secret scan (not recommended)
  --dry-run                Show what would change; touch nothing
  -h, --help               This help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --archive) ARCHIVE="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --folder) FOLDER="${2:-}"; shift 2 ;;
    --sentinel-file) SENTINEL_FILE="${2:-}"; shift 2 ;;
    --sentinel-string) SENTINEL_STRING="${2:-}"; shift 2 ;;
    -m|--message) MESSAGE="${2:-}"; shift 2 ;;
    --branch) BRANCH="${2:-}"; shift 2 ;;
    --retire) RETIRE="${2:-}"; shift 2 ;;
    --skip-scan) SKIP_SCAN=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; fail "unknown option: $1" ;;
  esac
done

[ -n "$ARCHIVE" ] || ARCHIVE="$HOME/$FOLDER.tar.gz"
[ -n "$MESSAGE" ] || MESSAGE="$FOLDER: update"
case "$FOLDER$RETIRE" in *..*|*/*) fail "folder names must be plain names (no / or ..)" ;; esac

command -v git >/dev/null 2>&1 || fail "git not installed"
command -v tar >/dev/null 2>&1 || fail "tar not installed"
[ -d "$REPO/.git" ] || fail "$REPO is not a git clone (git clone git@github.com:<user>/<repo>.git $REPO)"
cd "$REPO"

# 1. SSH key works (GitHub answers 'successfully authenticated' with exit code 1)
remote="$(git remote get-url origin 2>/dev/null || true)"
case "$remote" in
  git@github.com:*|ssh://git@github.com/*)
    if ssh -T -o BatchMode=yes -o ConnectTimeout=8 git@github.com 2>&1 | grep -q 'successfully authenticated'; then ok "GitHub SSH key OK"
    else fail "GitHub SSH auth failed - check: ssh -T git@github.com"; fi ;;
  *) warn "origin is '$remote' (not SSH) - push may ask for credentials" ;;
esac

# 2. up to date, and no unrelated local changes in the way
[ "$(git rev-parse --abbrev-ref HEAD)" = "$BRANCH" ] || fail "repo is on '$(git rev-parse --abbrev-ref HEAD)', expected '$BRANCH'"
if [ -n "$(git status --porcelain -- "$FOLDER" ${RETIRE:+"$RETIRE"})" ]; then
  fail "uncommitted changes inside $FOLDER${RETIRE:+ or $RETIRE} - commit or 'git checkout -- $FOLDER' first"
fi
info "git pull"
git pull --ff-only -q origin "$BRANCH" || fail "git pull failed (diverged? resolve manually)"
ok "up to date with origin/$BRANCH"

# 3. archive sanity
[ -f "$ARCHIVE" ] || fail "archive not found: $ARCHIVE"
tops="$(tar -tzf "$ARCHIVE" | cut -d/ -f1 | sort -u)"
[ "$tops" = "$FOLDER" ] || fail "archive must contain exactly one top folder '$FOLDER' (found: $(echo "$tops" | tr '\n' ' '))"
tar -tzf "$ARCHIVE" | grep -qx "$FOLDER/$SENTINEL_FILE" || fail "sentinel file $SENTINEL_FILE missing in the archive"
tar -xzOf "$ARCHIVE" "$FOLDER/$SENTINEL_FILE" | grep -qF -- "$SENTINEL_STRING" || fail "sentinel text '$SENTINEL_STRING' not found in $SENTINEL_FILE - wrong/old archive?"
ok "archive OK: $(tar -tzf "$ARCHIVE" | grep -vc '/$') files, sentinel found"

# 4. secret scan on the archive content (decoy honeyfs content is fake by design and excluded)
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
tar -xzf "$ARCHIVE" -C "$tmp"
if [ "$SKIP_SCAN" = 0 ]; then
  hits="$(grep -rnEi --exclude-dir=honeyfs '(api[_-]?key|token|secret|password|passwd)[[:space:]]*[=:][[:space:]]*["'"'"']?[A-Za-z0-9+/_-]{16,}' "$tmp/$FOLDER" \
    | grep -vE '<[A-Z0-9_]+>|CHANGE_ME|PASTE_[A-Z_]+|your[_-]?(key|token)|EXAMPLE' || true)"
  [ -z "$hits" ] || { printf '%s\n' "$hits" | sed "s|$tmp/||" >&2; fail "possible secrets in the archive - fix or rerun with --skip-scan"; }
  find "$tmp/$FOLDER" -name '.env' -type f | grep -q . && fail "the archive contains a real .env file - remove it"
  ok "secret scan clean"
fi

# 5. what changes
if [ -d "$FOLDER" ]; then
  changes="$(diff -rq "$FOLDER" "$tmp/$FOLDER" 2>/dev/null | sed "s|$tmp/||" || true)"
  printf '%sChanges vs current %s:%s\n' "$B" "$FOLDER" "$R"
  if [ -n "$changes" ]; then printf '%s\n' "$changes" | sed 's/^/  /' | head -n 60; else echo "  (no differences)"; fi
else
  info "$FOLDER is new in the repo"
fi
[ -n "$RETIRE" ] && { [ -d "$RETIRE" ] && info "will retire $RETIRE" || warn "$RETIRE not found (nothing to retire)"; }

if [ "$DRY" = 1 ]; then ok "dry run - nothing changed"; exit 0; fi

# 6. replace, commit, push
git rm -r -q --ignore-unmatch -- "$FOLDER"
rm -rf "$FOLDER"
if [ -n "$RETIRE" ]; then git rm -r -q --ignore-unmatch -- "$RETIRE"; rm -rf "$RETIRE"; fi
tar -xzf "$ARCHIVE"
git add -A -- "$FOLDER"
[ -n "$RETIRE" ] && git add -A -- "$RETIRE" 2>/dev/null || true
missing="$(cd "$tmp" && find "$FOLDER" -type f | while read -r f; do git -C "$REPO" ls-files --error-unmatch "$f" >/dev/null 2>&1 || echo "$f"; done)"
[ -z "$missing" ] || { printf '%s\n' "$missing" | sed 's/^/  /' >&2; fail "files ignored by a .gitignore rule - nothing was committed. Fix with: cd $REPO && git add -f <files above> && git commit -m \"$MESSAGE\" && git push"; }
if git diff --cached --quiet; then ok "nothing to commit - repo already matches the archive"; exit 0; fi
git commit -q -m "$MESSAGE"
ok "committed: $MESSAGE"
git push -q origin "$BRANCH"
ok "pushed to origin/$BRANCH"
case "$remote" in
  git@github.com:*) slug="${remote#git@github.com:}"; slug="${slug%.git}"; printf '\n  https://github.com/%s/tree/%s/%s\n' "$slug" "$BRANCH" "$FOLDER" ;;
esac
printf '  (raw.githubusercontent.com can take up to ~5 minutes to show the new files)\n'
