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

# Resolve the latest published release when no version was supplied.
if [ -z "${SUPERSQE_VERSION:-}" ]; then
  LATEST="$(curl -fsSL --max-time 15 https://api.github.com/repos/supersqe/installers/releases/latest 2>/dev/null | grep -m1 '"tag_name"' | sed -E 's/.*"v?([0-9.]+)".*/\1/' || true)"
  VERSION="${LATEST:-1.0.6}"
else
  VERSION="$SUPERSQE_VERSION"
fi
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

warn 'Note: the installation can take up to 20 minutes depending on your network'
warn 'speed and Mac configuration (the first boot prepares the database).'

# ---- Existing installation? (data is kept; port/email can change) ---------
IS_UPGRADE=0
CFG_PORT=""
CFG_EMAIL=""
if [ -f "$CFG" ]; then
  IS_UPGRADE=1
  CFG_PORT="$(sudo grep -E '^PORT=' "$CFG" 2>/dev/null | cut -d= -f2- || true)"
  CFG_EMAIL="$(sudo grep -E '^SUPERSQE_ADMIN_EMAIL=' "$CFG" 2>/dev/null | cut -d= -f2- || true)"
  log "Existing SuperSQE installation detected - your data is kept."
  log "You can change the web port and administrator email below (Enter keeps them)."
fi

# ---- Port -----------------------------------------------------------------
DEFAULT_PORT="${CFG_PORT:-3000}"
if [ -z "$PORT" ]; then
  read -r -p "Web port [$DEFAULT_PORT]: " PORT
  PORT="${PORT:-$DEFAULT_PORT}"
fi
PORT="${PORT:-$DEFAULT_PORT}"
case "$PORT" in ''|*[!0-9]*) fail "Invalid port: $PORT" ;; esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then fail "Invalid port: $PORT (1-65535)"; fi
if [ "$IS_UPGRADE" = "0" ] && lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  warn "Port $PORT is already in use."
  read -r -p 'Continue anyway? (y/N) ' ans
  case "$ans" in y|Y|yes) ;; *) fail 'Installation cancelled - choose a free port and run again.' ;; esac
fi

# ---- Administrator email (required on first install; changeable on upgrade)
DEFAULT_EMAIL="${CFG_EMAIL:-admin@supersqe.local}"
while true; do
  if [ -z "$ADMIN_EMAIL" ]; then
    if [ "$IS_UPGRADE" = "1" ]; then
      read -r -p "Administrator email [$DEFAULT_EMAIL] (Enter to keep): " ADMIN_EMAIL
      [ -z "$ADMIN_EMAIL" ] && ADMIN_EMAIL="$DEFAULT_EMAIL"
    else
      read -r -p 'Administrator email (required - this is your SuperSQE login): ' ADMIN_EMAIL
    fi
  fi
  case "$ADMIN_EMAIL" in
    *@*.*) break ;;
    *) warn 'Enter a valid email address, for example name@company.com'; ADMIN_EMAIL="" ;;
  esac
done

# ---- Administrator access (or per-user fallback) --------------------------
PORTABLE_URL="https://raw.githubusercontent.com/supersqe/installers/main/portable-install-macos.sh"
run_portable_install() {
  warn 'Switching to the per-user portable install (no administrator rights needed).'
  local tmp
  tmp="$(mktemp /tmp/supersqe-portable.XXXXXX)"
  curl -fSL --progress-bar -o "$tmp" "$PORTABLE_URL" || fail 'Could not download the portable installer.'
  if [ -n "${OUT:-}" ] && [ -f "$OUT" ]; then
    SUPERSQE_PORT="$PORT" SUPERSQE_ADMIN_EMAIL="$ADMIN_EMAIL" bash "$tmp" "$OUT"
  else
    SUPERSQE_PORT="$PORT" SUPERSQE_ADMIN_EMAIL="$ADMIN_EMAIL" bash "$tmp"
  fi
  local rc=$?
  rm -f "$tmp"
  exit $rc
}
if ! id -Gn 2>/dev/null | tr ' ' '\n' | grep -qx admin; then
  warn 'This account is not a macOS administrator.'
  run_portable_install
fi

# Refuse to queue behind another installation (App Store, another pkg, or a
# stale 'installer' left by an interrupted run). This is what makes the CLI
# appear stuck at ~16% ("Waiting for other installations to complete").
if pgrep -f '/usr/sbin/installer' >/dev/null 2>&1 || pgrep -x Installer >/dev/null 2>&1; then
  warn 'Another macOS installation is already running:'
  pgrep -fl '/usr/sbin/installer' 2>/dev/null || true
  pgrep -x Installer 2>/dev/null | while read -r pid; do ps -p "$pid" -o pid=,comm= 2>/dev/null; done
  warn "If it is a stale run, stop it with: sudo pkill -f '/usr/sbin/installer'"
  fail 'Finish or cancel that installation, then run this command again.'
fi

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

# ---- Prepare the payload package -----------------------------------------
# The product licence in the Distribution is displayed by the GUI Installer;
# the CLI can wait on it indefinitely. Installing the component package
# directly avoids that while still running the package's postinstall scripts.
INSTALL_PKG="$OUT"
EXPAND_DIR="$(mktemp -d /tmp/supersqe-pkg.XXXXXX 2>/dev/null || true)"
if [ -n "$EXPAND_DIR" ] && pkgutil --expand "$OUT" "$EXPAND_DIR" >/dev/null 2>&1; then
  CANDIDATE="$(find "$EXPAND_DIR" -name '*.pkg' 2>/dev/null | head -n 1)"
  if [ -n "$CANDIDATE" ] && [ -d "$CANDIDATE" ]; then
    if pkgutil --flatten "$CANDIDATE" "$EXPAND_DIR/payload.pkg" >/dev/null 2>&1; then
      CANDIDATE="$EXPAND_DIR/payload.pkg"
    fi
  fi
  if [ -n "$CANDIDATE" ] && [ -e "$CANDIDATE" ]; then
    INSTALL_PKG="$CANDIDATE"
  fi
fi
log 'By continuing you accept the SuperSQE EULA (https://www.supersqe.com/eula).'

# ---- Administrator authentication (right before the system install) ------
if ! sudo -v; then
  warn 'Administrator authentication was not completed.'
  run_portable_install
fi

# ---- Configure the package (postinstall reads these) ----------------------
log "Configuring port $PORT"
defaults write com.supersqe.server port -int "$PORT" 2>/dev/null || true
sudo defaults write com.supersqe.server port -int "$PORT" 2>/dev/null || true
if [ -n "$ADMIN_EMAIL" ]; then
  log "Configuring administrator $ADMIN_EMAIL"
  defaults write com.supersqe.server adminEmail "$ADMIN_EMAIL" 2>/dev/null || true
  sudo defaults write com.supersqe.server adminEmail "$ADMIN_EMAIL" 2>/dev/null || true
fi

# ---- Install (with live progress) -----------------------------------------
log 'Installing the package...'
INSTALL_LOG="$(mktemp -t supersqe-install)"
INSTALL_PID=""
cleanup_install() {
  if [ -n "$INSTALL_PID" ] && kill -0 "$INSTALL_PID" 2>/dev/null; then
    warn 'Stopping the package installer...'
    kill "$INSTALL_PID" 2>/dev/null || true
  fi
}
trap cleanup_install INT TERM
sudo -n installer -pkg "$INSTALL_PKG" -target / -allowUntrusted -verboseR >"$INSTALL_LOG" 2>&1 &
INSTALL_PID=$!
INSTALL_START=$(date +%s)
LAST_PHASE=""
LAST_CHANGE_AT=0
STALL_REPORTED=0
TICK_AT=0
TICKS=(
  "Copying application files and the bundled browser runtime..."
  "Unpacking the bundled PostgreSQL database and runner agents..."
  "Configuring the installation and the bundled components..."
  "Running package scripts and preparing the server..."
  "Finishing the install - this can take up to 20 minutes in total..."
)
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
  if [ "$PHASE" != "$LAST_PHASE" ]; then
    LAST_CHANGE_AT=$ELAPSED
    STALL_REPORTED=0
  fi
  if [ "$STALL_REPORTED" = "0" ] && [ $((ELAPSED - LAST_CHANGE_AT)) -ge 120 ]; then
    echo
    warn 'The installer has not progressed for 2 minutes. Last log lines:'
    tail -n 5 "$INSTALL_LOG" 2>/dev/null | sed 's/^/    /'
    warn 'If another installation is in progress, finish or cancel it (Installer/App Store).'
    warn 'Or press Ctrl+C and use the per-user install (no admin password):'
    warn "  curl -fsSL -o ~/portable-install-macos.sh $PORTABLE_URL"
    warn '  bash ~/portable-install-macos.sh'
    STALL_REPORTED=1
  fi
  if [ $((ELAPSED - TICK_AT)) -ge 60 ]; then
    TICK_AT=$ELAPSED
    IDX=$(( ELAPSED / 60 - 1 )); [ "$IDX" -lt 0 ] && IDX=0; [ "$IDX" -ge ${#TICKS[@]} ] && IDX=$(( ${#TICKS[@]} - 1 ))
    printf '\n    %s (%dm %ds)\n' "${TICKS[$IDX]}" $((ELAPSED / 60)) $((ELAPSED % 60))
  fi
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
[ -n "$EXPAND_DIR" ] && rm -rf "$EXPAND_DIR"

# ---- Ensure the administrator account exists ------------------------------
# Packages released before the admin-password generation only record the email.
# Bootstrap creates the admin + Welcome Pack on the next start when BOTH
# SUPERSQE_ADMIN_EMAIL and SUPERSQE_ADMIN_PASSWORD are present.
if [ "$IS_UPGRADE" = "0" ] && ! sudo grep -q '^SUPERSQE_ADMIN_PASSWORD=' "$CFG" 2>/dev/null; then
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
TICK_AT=0
BOOT_TICKS=(
  "Initialising the bundled PostgreSQL database..."
  "Applying the database schema (first boot only)..."
  "Creating the administrator account and the Welcome Pack..."
  "Starting the SuperSQE server and verifying health..."
  "Still starting - first boot can take several minutes on slower Macs..."
)
for _ in {1..150}; do
  ELAPSED=$(( $(date +%s) - BOOT_START ))
  PCT=$(( 90 + ELAPSED / 6 )); [ "$PCT" -gt 99 ] && PCT=99
  if sudo test -f "$DATA_DIR/welcome.txt" 2>/dev/null && sudo grep -q 'Password' "$DATA_DIR/welcome.txt" 2>/dev/null; then
    READY=1; break
  fi
  if curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then READY=1; fi
  draw_bar "$PCT" "Starting server - ${ELAPSED}s"
  if [ $((ELAPSED - TICK_AT)) -ge 60 ]; then
    TICK_AT=$ELAPSED
    IDX=$(( ELAPSED / 60 - 1 )); [ "$IDX" -lt 0 ] && IDX=0; [ "$IDX" -ge ${#BOOT_TICKS[@]} ] && IDX=$(( ${#BOOT_TICKS[@]} - 1 ))
    printf '\n    %s (%dm %ds)\n' "${BOOT_TICKS[$IDX]}" $((ELAPSED / 60)) $((ELAPSED % 60))
  fi
  sleep 2
done
echo
[ -n "$READY" ] || warn 'The server is still starting - it will be ready in a few minutes.'

echo
# The actual port may differ from the requested one on upgrades.
ACTUAL_PORT="$PORT"
if sudo test -f "$DATA_DIR/welcome.txt"; then
  WELCOME_PORT="$(sudo grep -m1 'http://localhost:' "$DATA_DIR/welcome.txt" 2>/dev/null | grep -oE 'localhost:[0-9]+' | head -n1 | cut -d: -f2 || true)"
  [ -n "$WELCOME_PORT" ] && ACTUAL_PORT="$WELCOME_PORT"
fi

log "Installation complete - http://127.0.0.1:$ACTUAL_PORT"
echo "  Welcome Pack:              $DATA_DIR/welcome.txt"
echo "  Administrator credentials: $DATA_DIR/admin-credentials.txt"
echo
if sudo test -f "$DATA_DIR/welcome.txt"; then
  echo '---------------------------- Welcome Pack ----------------------------'
  sudo cat "$DATA_DIR/welcome.txt"
  echo '----------------------------------------------------------------------'
  if ! sudo grep -q 'Password' "$DATA_DIR/welcome.txt" 2>/dev/null; then
    if [ "$IS_UPGRADE" = "1" ]; then
      warn 'This was an upgrade - your existing administrator account is unchanged.'
    fi
    warn "Saved credentials: sudo cat $DATA_DIR/admin-credentials.txt"
  fi
elif sudo test -f "$DATA_DIR/admin-credentials.txt"; then
  sudo cat "$DATA_DIR/admin-credentials.txt"
else
  warn "Welcome Pack not written yet - read it shortly at $DATA_DIR/welcome.txt"
fi

open "http://127.0.0.1:$ACTUAL_PORT" 2>/dev/null || true
