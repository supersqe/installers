#!/usr/bin/env bash
# ============================================================================
# SuperSQE interactive command-line installer for macOS.
#
# Mirrors the .pkg installer experience from a terminal:
#   1. prompts for the web port (default 3000) and administrator email (required),
#   2. downloads the package for your Mac's architecture,
#   3. verifies the SHA-256 / signature where available,
#   4. installs (you may be asked for your admin password + EULA acceptance),
#   5. ensures the administrator account exists and prints the Welcome Pack.
#
#   Usage:
#     bash install-macos.sh                 # interactive
#     SUPERSQE_PORT=8443 SUPERSQE_ADMIN_EMAIL=you@company.com bash install-macos.sh
# ============================================================================
set -euo pipefail

VERSION="${SUPERSQE_VERSION:-1.0.5}"
PORT="${SUPERSQE_PORT:-}"
ADMIN_EMAIL="${SUPERSQE_ADMIN_EMAIL:-}"
REPO="https://github.com/supersqe/installers/releases/download"
DATA_DIR="/var/lib/supersqe"
CFG="$DATA_DIR/config.env"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m    %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# draw_bar <percent> <label>
draw_bar() {
  local pct="$1" label="$2" width=28 filled empty bar i
  filled=$(( pct * width / 100 ))
  empty=$(( width - filled ))
  bar=""
  i=0
  while [ "$i" -lt "$filled" ]; do bar="$bar#"; i=$((i + 1)); done
  i=0
  while [ "$i" -lt "$empty" ]; do bar="$bar-"; i=$((i + 1)); done
  printf '\r  [%s] %3d%%  %s\033[K' "$bar" "$pct" "$label"
}

[ "$(uname -s)" = "Darwin" ] || fail "This script is for macOS."

# ---- Administrator access -------------------------------------------------
if ! sudo -n true 2>/dev/null; then
  warn 'Administrator access is required - enter your Mac password when prompted.'
  sudo -v || fail 'Administrator access is required to install SuperSQE.'
fi

# ---- Port -----------------------------------------------------------------
if [ -z "$PORT" ]; then
  read -r -p "Web port [3000]: " PORT
  PORT="${PORT:-3000}"
fi
case "$PORT" in ''|*[!0-9]*) fail "Invalid port: $PORT" ;; esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then fail "Invalid port: $PORT (1-65535)"; fi
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  warn "Port $PORT is already in use."
  read -r -p 'Continue anyway? (y/N) ' ans
  case "$ans" in y|Y|yes) ;; *) fail 'Installation cancelled - choose a free port and run again.' ;; esac
fi

# ---- Administrator email (required) --------------------------------------
while true; do
  if [ -z "$ADMIN_EMAIL" ]; then
    read -r -p 'Administrator email (required - this is your SuperSQE login): ' ADMIN_EMAIL
  fi
  case "$ADMIN_EMAIL" in
    *@*.*) break ;;
    *) warn 'Enter a valid email address, for example name@company.com'; ADMIN_EMAIL="" ;;
  esac
done

# ---- Download -------------------------------------------------------------
ARCH="$(uname -m)"; [ "$ARCH" = "arm64" ] || ARCH=x64
PKG="supersqe-macos-$ARCH-v$VERSION.pkg"
OUT="$HOME/Downloads/$PKG"

log "Downloading SuperSQE v$VERSION ($ARCH)"
if [ ! -f "$OUT" ]; then
  curl -fL --progress-bar -o "$OUT" "$REPO/v$VERSION/$PKG" \
    || fail "Download failed - check that v$VERSION exists at github.com/supersqe/installers/releases"
fi
xattr -dr com.apple.quarantine "$OUT" 2>/dev/null || true

log 'SHA-256 of the downloaded package:'
warn "$(shasum -a 256 "$OUT" | awk '{print $1}')"
warn 'Compare it with the checksum on https://www.supersqe.com/downloads'

# ---- Configure the package (postinstall reads these) ----------------------
log "Configuring port $PORT and administrator $ADMIN_EMAIL"
defaults write com.supersqe.server port -int "$PORT" 2>/dev/null || true
defaults write com.supersqe.server adminEmail "$ADMIN_EMAIL" 2>/dev/null || true
sudo defaults write com.supersqe.server port -int "$PORT" 2>/dev/null || true
sudo defaults write com.supersqe.server adminEmail "$ADMIN_EMAIL" 2>/dev/null || true

# ---- Install (with live progress) -----------------------------------------
log 'Installing (accept the EULA if prompted)...'
INSTALL_LOG="$(mktemp -t supersqe-install)"
sudo installer -pkg "$OUT" -target / -allowUntrusted -verboseR >"$INSTALL_LOG" 2>&1 &
INSTALL_PID=$!
INSTALL_START=$(date +%s)
LAST_PHASE=""
while kill -0 "$INSTALL_PID" 2>/dev/null; do
  ELAPSED=$(( $(date +%s) - INSTALL_START ))
  PHASE="$(grep -E 'PHASE:' "$INSTALL_LOG" 2>/dev/null | tail -n 1 | sed 's/.*PHASE: *//' || true)"
  case "$PHASE" in
    *Preparing*)  PCT=10 ;;
    *Waiting*)    PCT=15 ;;
    *Configuring*) PCT=25 ;;
    *Writing*)    PCT=45 ;;
    *scripts*)    PCT=75 ;;
    *Finished*)   PCT=90 ;;
    *)            PCT=$(( 5 + ELAPSED / 4 )); [ "$PCT" -gt 85 ] && PCT=85 ;;
  esac
  draw_bar "$PCT" "Installing package - ${ELAPSED}s ${PHASE}"
  LAST_PHASE="$PHASE"
  sleep 1
done
wait "$INSTALL_PID"; INSTALL_RC=$?
echo
if [ "$INSTALL_RC" -ne 0 ]; then
  echo "--- installer output ---"; cat "$INSTALL_LOG"
  fail 'The package installer failed.'
fi
rm -f "$INSTALL_LOG"

# ---- Ensure the administrator account exists ------------------------------
# Packages released before the admin-password generation only record the email.
# Bootstrap creates the admin + Welcome Pack on the next start when BOTH
# SUPERSQE_ADMIN_EMAIL and SUPERSQE_ADMIN_PASSWORD are present.
if ! sudo grep -q '^SUPERSQE_ADMIN_PASSWORD=' "$CFG" 2>/dev/null; then
  log 'Preparing the administrator account...'
  PASS="$(openssl rand -base64 18 | tr -d '\n')"
  sudo sh -c "printf '\nSUPERSQE_ADMIN_PASSWORD=%s\n' '$PASS' >> '$CFG'"
  sudo sed -i '' "s|^SUPERSQE_ADMIN_EMAIL=.*|SUPERSQE_ADMIN_EMAIL=$ADMIN_EMAIL|" "$CFG" 2>/dev/null || true
  sudo launchctl kickstart -k system/com.supersqe.server 2>/dev/null || true
fi

# ---- Wait for first boot + Welcome Pack (progress 90-100%) ----------------
log 'Waiting for the first boot (database + schema) - this can take a few minutes'
BOOT_START=$(date +%s)
READY=""
for _ in {1..150}; do
  ELAPSED=$(( $(date +%s) - BOOT_START ))
  PCT=$(( 90 + ELAPSED / 6 )); [ "$PCT" -gt 99 ] && PCT=99
  if sudo test -f "$DATA_DIR/welcome.txt" 2>/dev/null && sudo grep -q 'Password' "$DATA_DIR/welcome.txt" 2>/dev/null; then
    READY=1; break
  fi
  if curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then READY=1; fi
  draw_bar "$PCT" "Starting server - ${ELAPSED}s"
  sleep 2
done
echo
[ -n "$READY" ] || warn 'The server is still starting - it will be ready in a few minutes.'

echo
log "Installation complete - http://127.0.0.1:$PORT"
echo
if sudo test -f "$DATA_DIR/welcome.txt"; then
  echo '---------------------------- Welcome Pack ----------------------------'
  sudo cat "$DATA_DIR/welcome.txt"
  echo '----------------------------------------------------------------------'
elif sudo test -f "$DATA_DIR/admin-credentials.txt"; then
  sudo cat "$DATA_DIR/admin-credentials.txt"
else
  warn "Welcome Pack not written yet - read it shortly at $DATA_DIR/welcome.txt"
fi

open "http://127.0.0.1:$PORT" 2>/dev/null || true
