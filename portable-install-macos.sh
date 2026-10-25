#!/usr/bin/env bash
# ============================================================================
# SuperSQE - portable (user-space) install for macOS. NO ADMIN / NO SUDO.
#
# Installs everything under your home folder and runs the platform as your
# user. Nothing is written to /opt, /var or /Library, and no background
# system services are registered.
#
#   Usage:
#     ./portable-install-macos.sh                 # download the latest pkg + install
#     ./portable-install-macos.sh /path/to.pkg    # install from a local .pkg
#     ./portable-install-macos.sh stop            # stop the server + postgres
#
#   Installs to:  ~/supersqe        (payload)      ~/supersqe-data (data + DB)
# ============================================================================
set -euo pipefail

INSTALL_DIR="$HOME/supersqe"
DATA_DIR="$HOME/supersqe-data"
# Resolve the latest published release when no version was supplied.
if [ -z "${SUPERSQE_VERSION:-}" ]; then
  LATEST="$(curl -fsSL --max-time 15 https://api.github.com/repos/supersqe/installers/releases/latest 2>/dev/null | grep -m1 '"tag_name"' | sed -E 's/.*"v?([0-9.]+)".*/\1/' || true)"
  VERSION="${LATEST:-1.0.10}"
else
  VERSION="$SUPERSQE_VERSION"
fi
REPO="https://github.com/supersqe/installers/releases/download"
PORT="${SUPERSQE_PORT:-}"
ADMIN_EMAIL="${SUPERSQE_ADMIN_EMAIL:-}"
PG_PORT="${SUPERSQE_PG_PORT:-5433}"
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

# ---- stop -----------------------------------------------------------------
if [ "${1:-}" = "stop" ]; then
  log "Stopping SuperSQE server..."
  [ -f "$DATA_DIR/server.pid" ] && kill "$(cat "$DATA_DIR/server.pid")" 2>/dev/null || true
  rm -f "$DATA_DIR/server.pid"
  if [ -d "$DATA_DIR/pgdata" ] && [ -x "$INSTALL_DIR/postgres/bin/pg_ctl" ]; then
    log "Stopping PostgreSQL..."
    "$INSTALL_DIR/postgres/bin/pg_ctl" -D "$DATA_DIR/pgdata" stop 2>/dev/null || true
  fi
  log "Stopped."
  exit 0
fi

[ "$(uname -s)" = "Darwin" ] || fail "This script is for macOS."

if [ "$(id -u)" -eq 0 ]; then
  fail 'Do not run the portable installer with sudo - it installs into your user account. Run it as your normal macOS user.'
fi

# Refuse to inherit root-owned files from a previous `sudo` run: PostgreSQL
# cannot start if its data directory belongs to another user.
if [ -e "$DATA_DIR" ] && [ "$(stat -f%u "$DATA_DIR" 2>/dev/null || echo "$(id -u)")" != "$(id -u)" ]; then
  fail "The data folder $DATA_DIR belongs to another user (usually from a previous sudo run). Fix it with:
    sudo chown -R $(id -u):$(id -g) \"$DATA_DIR\" \"$INSTALL_DIR\"
  then run this installer again."
fi
if [ -e "$INSTALL_DIR" ] && [ "$(stat -f%u "$INSTALL_DIR" 2>/dev/null || echo "$(id -u)")" != "$(id -u)" ]; then
  fail "The install folder $INSTALL_DIR belongs to another user. Fix it with:
    sudo chown -R $(id -u):$(id -g) \"$INSTALL_DIR\"
  then run this installer again."
fi

# Pick a free PostgreSQL port. The system .pkg install (or another database)
# may already hold 5433; the portable install must coexist without sudo.
pick_pg_port() {
  local p="${1:-5433}" i=0
  while [ "$i" -lt 50 ]; do
    if ! lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
      printf '%s' "$p"
      return 0
    fi
    p=$((p + 1))
    i=$((i + 1))
  done
  printf '%s' "$p"
}

# Stop only this user's portable instance (never the system .pkg services).
stop_previous_install() {
  if [ -f "$DATA_DIR/server.pid" ]; then
    kill "$(cat "$DATA_DIR/server.pid")" 2>/dev/null || true
    rm -f "$DATA_DIR/server.pid"
  fi
  if [ -x "$INSTALL_DIR/postgres/bin/pg_ctl" ] && [ -f "$DATA_DIR/pgdata/PG_VERSION" ]; then
    log "Stopping the previous PostgreSQL instance..."
    "$INSTALL_DIR/postgres/bin/pg_ctl" -D "$DATA_DIR/pgdata" stop -m fast >/dev/null 2>&1 || true
  fi
  # Orphaned processes whose install dir was already replaced.
  pkill -f "$DATA_DIR/pgdata" 2>/dev/null || true
  pkill -f "$INSTALL_DIR/runtime/supersqe-server" 2>/dev/null || true
  # Remove a stale lock file left by a crash (dead PID only).
  local pidfile="$DATA_DIR/pgdata/postmaster.pid"
  if [ -f "$pidfile" ]; then
    local pid
    pid="$(sed -n '1p' "$pidfile" 2>/dev/null || true)"
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$pidfile"
    fi
  fi
}

warn 'Note: the installation can take up to 20 minutes depending on your network'
warn 'speed and Mac configuration (the first boot prepares the database).'

# ---- First-run configuration (port + administrator email) -----------------
NEW_CONFIG=0
if [ ! -f "$CFG" ]; then
  NEW_CONFIG=1
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
  while true; do
    if [ -z "$ADMIN_EMAIL" ]; then
      read -r -p 'Administrator email (required - this is your SuperSQE login): ' ADMIN_EMAIL
    fi
    case "$ADMIN_EMAIL" in
      *@*.*) break ;;
      *) warn 'Enter a valid email address, for example name@company.com'; ADMIN_EMAIL="" ;;
    esac
  done
else
  PORT="${SUPERSQE_PORT:-$(grep -E '^PORT=' "$CFG" | cut -d= -f2- || echo 3000)}"
  PORT="${PORT:-3000}"
  log "Existing installation found - keeping $CFG (port $PORT)"
fi

# Stop the previous portable instance and choose a free PostgreSQL port.
stop_previous_install

if [ -f "$CFG" ]; then
  CUR_PG="$(grep -E '^SUPERSQE_PG_PORT=' "$CFG" 2>/dev/null | cut -d= -f2- || true)"
  [ -n "$CUR_PG" ] && PG_PORT="$CUR_PG"
fi
PG_PORT="$(pick_pg_port "$PG_PORT")"
log "PostgreSQL port: $PG_PORT"

# ---- 1. Get the .pkg (local path or download the latest release) ----------
PKG="${1:-}"
if [ -n "$PKG" ]; then
  PKG_VERSION="$(basename "$PKG" | sed -n 's/.*-v\([0-9][0-9.]*\)\.pkg$/\1/p')"
  [ -n "$PKG_VERSION" ] && VERSION="$PKG_VERSION"
fi
if [ -z "$PKG" ]; then
  ARCH="$(uname -m)"; [ "$ARCH" = "arm64" ] || ARCH=x64
  PKG="$HOME/Downloads/supersqe-macos-$ARCH-v$VERSION.pkg"
  if [ ! -f "$PKG" ]; then
    log "Downloading supersqe-macos-$ARCH-v$VERSION.pkg ..."
    curl -fL --progress-bar -o "$PKG" "$REPO/v$VERSION/supersqe-macos-$ARCH-v$VERSION.pkg" \
      || fail "download failed - check the version (v$VERSION) exists on github.com/supersqe/installers/releases"
  fi
fi
[ -f "$PKG" ] || fail "package not found: $PKG"
xattr -dr com.apple.quarantine "$PKG" 2>/dev/null || true

# ---- 1b. Verify the package checksum (GitHub release digest) --------------
log 'Verifying the package checksum...'
ACTUAL_SHA="$(shasum -a 256 "$PKG" | awk '{print $1}')"
EXPECTED_SHA=""
API_JSON="$(curl -fsSL --connect-timeout 5 --max-time 20 "https://api.github.com/repos/supersqe/installers/releases/tags/v$VERSION" 2>/dev/null || true)"
if [ -n "$API_JSON" ]; then
  EXPECTED_SHA="$(printf '%s' "$API_JSON" | tr '}' '\n' \
    | grep -F "\"name\": \"$(basename "$PKG")\"" \
    | grep -o 'sha256:[0-9a-f]*' | sed -n '1p' | cut -d: -f2 | tr -d '\r' || true)"
fi
if [ -n "$EXPECTED_SHA" ]; then
  [ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] || fail "checksum mismatch for $PKG (expected $EXPECTED_SHA, got $ACTUAL_SHA)"
  log "SHA-256 verified: $ACTUAL_SHA"
else
  warn "SHA-256: $ACTUAL_SHA"
  warn "Compare it with https://www.supersqe.com/downloads"
fi

# ---- 2. Expand the package (pkgutil needs no admin) -----------------------
log "Expanding $PKG ..."
warn 'This can take a few minutes; progress is shown below.'
WORK="$(mktemp -d)"
EXTRACT="$WORK/expand"   # pkgutil requires a destination that does not exist yet
trap 'rm -rf "$WORK"' EXIT
pkgutil --expand-full "$PKG" "$EXTRACT" >/dev/null 2>&1 &
EXTRACT_PID=$!
EXTRACT_START=$(date +%s)
while kill -0 "$EXTRACT_PID" 2>/dev/null; do
  ELAPSED=$(( $(date +%s) - EXTRACT_START ))
  PCT=$(( 5 + ELAPSED / 3 )); [ "$PCT" -gt 90 ] && PCT=90
  draw_bar "$PCT" "Extracting package - ${ELAPSED}s"
  if [ "$ELAPSED" -gt 0 ] && [ $((ELAPSED % 30)) -eq 0 ]; then
    printf '\n    Still extracting the package payload (%dm %ds)\n' $((ELAPSED / 60)) $((ELAPSED % 60))
  fi
  sleep 1
done
EXTRACT_RC=0
wait "$EXTRACT_PID" || EXTRACT_RC=$?
echo
if [ "$EXTRACT_RC" -ne 0 ] || [ ! -d "$EXTRACT" ]; then fail "pkgutil --expand-full failed"; fi

SERVER_BIN="$(find "$EXTRACT" -type f -path '*/runtime/supersqe-server' | sed -n '1p')"
[ -n "$SERVER_BIN" ] || fail "payload not found inside the package (unexpected layout)"
PAYLOAD_DIR="$(dirname "$(dirname "$SERVER_BIN")")"

# ---- 3. Install into ~/supersqe -------------------------------------------
log "Installing payload to $INSTALL_DIR ..."
if [ -d "$INSTALL_DIR" ]; then
  [ -f "$DATA_DIR/server.pid" ] && kill "$(cat "$DATA_DIR/server.pid")" 2>/dev/null || true
  rm -rf "$INSTALL_DIR"
fi
mv "$PAYLOAD_DIR" "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/runtime/supersqe-server"
chmod +x "$INSTALL_DIR/service/"*.sh 2>/dev/null || true

# ---- 4. Data dir + config.env (idempotent - keeps existing secrets) -------
mkdir -p "$DATA_DIR/logs" "$DATA_DIR/uploads"
if [ "$NEW_CONFIG" = "1" ]; then
  log "Writing $CFG ..."
  PG_PASS="$(openssl rand -hex 24)"
  ADMIN_PASS="$(openssl rand -base64 18 | tr -d '\n')"
  cat > "$CFG" <<EOF
HOST=127.0.0.1
PORT=$PORT
NODE_ENV=production
SUPERSQE_INSTALL_DIR=$INSTALL_DIR
SUPERSQE_DATA_DIR=$DATA_DIR
SUPERSQE_PG_PORT=$PG_PORT
SUPERSQE_PG_USER=supersqe
SUPERSQE_PG_PASSWORD=$PG_PASS
SUPERSQE_PG_DB=supersqe
DATABASE_URL=postgresql://supersqe:$PG_PASS@127.0.0.1:$PG_PORT/supersqe
NEXTAUTH_SECRET=$(openssl rand -hex 32)
INTERNAL_SECRET=$(openssl rand -hex 32)
NEXTAUTH_URL=http://localhost:$PORT
SUPERSQE_ADMIN_EMAIL=$ADMIN_EMAIL
SUPERSQE_ADMIN_PASSWORD=$ADMIN_PASS
EOF
  chmod 600 "$CFG"
fi

# ---- 4b. Apply changed port/email settings on upgrade ---------------------
if [ -f "$CFG" ]; then
  CUR_PG="$(grep -E '^SUPERSQE_PG_PORT=' "$CFG" 2>/dev/null | cut -d= -f2- || true)"
  if [ -n "$CUR_PG" ] && [ "$CUR_PG" != "$PG_PORT" ]; then
    if grep -q '^SUPERSQE_PG_PORT=' "$CFG"; then
      sed -i '' "s|^SUPERSQE_PG_PORT=.*|SUPERSQE_PG_PORT=$PG_PORT|" "$CFG"
    else
      echo "SUPERSQE_PG_PORT=$PG_PORT" >> "$CFG"
    fi
    sed -i '' -E "s|(postgresql://[^@]+@127\.0\.0\.1:)[0-9]+/|\1$PG_PORT/|" "$CFG"
    log "PostgreSQL port updated to $PG_PORT"
  fi

  CUR_PORT="$(grep -E '^PORT=' "$CFG" 2>/dev/null | cut -d= -f2- || true)"
  if [ -n "$PORT" ] && [ "$CUR_PORT" != "$PORT" ]; then
    if grep -q '^PORT=' "$CFG"; then
      sed -i '' "s|^PORT=.*|PORT=$PORT|" "$CFG"
    else
      echo "PORT=$PORT" >> "$CFG"
    fi
    if grep -q '^NEXTAUTH_URL=' "$CFG"; then
      sed -i '' "s|^NEXTAUTH_URL=.*|NEXTAUTH_URL=http://localhost:$PORT|" "$CFG"
    else
      echo "NEXTAUTH_URL=http://localhost:$PORT" >> "$CFG"
    fi
    log "Web port updated to $PORT"
  fi

  if [ -n "$ADMIN_EMAIL" ]; then
    CUR_MAIL="$(grep -E '^SUPERSQE_ADMIN_EMAIL=' "$CFG" 2>/dev/null | cut -d= -f2- || true)"
    if [ "$CUR_MAIL" != "$ADMIN_EMAIL" ]; then
      if grep -q '^SUPERSQE_ADMIN_EMAIL=' "$CFG"; then
        sed -i '' "s|^SUPERSQE_ADMIN_EMAIL=.*|SUPERSQE_ADMIN_EMAIL=$ADMIN_EMAIL|" "$CFG"
      else
        echo "SUPERSQE_ADMIN_EMAIL=$ADMIN_EMAIL" >> "$CFG"
      fi
      log "Administrator email updated to $ADMIN_EMAIL"
    fi
  fi
fi

# ---- 5. Start the server (it bootstraps postgres + schema + admin itself) --
log "Starting SuperSQE (first run initialises the bundled PostgreSQL)..."
export SUPERSQE_INSTALL_DIR="$INSTALL_DIR"
export SUPERSQE_DATA_DIR="$DATA_DIR"
export PLAYWRIGHT_BROWSERS_PATH="$INSTALL_DIR/browsers"
export NODE_ENV=production
cd "$INSTALL_DIR/supersqe-server"
nohup "$INSTALL_DIR/runtime/supersqe-server" -r tsconfig-paths/register dist/server.js \
  >> "$DATA_DIR/logs/server.log" 2>&1 &
echo $! > "$DATA_DIR/server.pid"

# ---- 6. Wait for health ---------------------------------------------------
log "Waiting for http://127.0.0.1:$PORT/api/health ..."
UP=""
BOOT_START=$(date +%s)
TICK_AT=0
BOOT_TICKS=(
  "Initialising the bundled PostgreSQL database..."
  "Applying the database schema (first boot only)..."
  "Creating the administrator account and the Welcome Pack..."
  "Starting the SuperSQE server and verifying health..."
  "Still starting - first boot can take several minutes on slower Macs..."
)
for _ in {1..150}; do
  if curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then UP=1; break; fi
  ELAPSED=$(( $(date +%s) - BOOT_START ))
  PCT=$(( 10 + ELAPSED / 2 )); [ "$PCT" -gt 95 ] && PCT=95
  draw_bar "$PCT" "Starting server (database + schema) - ${ELAPSED}s"
  if [ $((ELAPSED - TICK_AT)) -ge 60 ]; then
    TICK_AT=$ELAPSED
    IDX=$(( ELAPSED / 60 - 1 )); [ "$IDX" -lt 0 ] && IDX=0; [ "$IDX" -ge ${#BOOT_TICKS[@]} ] && IDX=$(( ${#BOOT_TICKS[@]} - 1 ))
    printf '\n    %s (%dm %ds)\n' "${BOOT_TICKS[$IDX]}" $((ELAPSED / 60)) $((ELAPSED % 60))
  fi
  sleep 2
done
echo
if [ -z "$UP" ]; then
  echo "--- last 40 server log lines ---"; tail -n 40 "$DATA_DIR/logs/server.log" || true
  echo "--- last 40 PostgreSQL log lines ---"; tail -n 40 "$DATA_DIR/logs/postgres.log" 2>/dev/null || true
  fail "server did not become healthy - see $DATA_DIR/logs/server.log"
fi

# ---- 7. Welcome Pack ------------------------------------------------------
log "SuperSQE is running - http://127.0.0.1:$PORT"
echo
if [ -f "$DATA_DIR/welcome.txt" ]; then
  echo '---------------------------- Welcome Pack ----------------------------'
  cat "$DATA_DIR/welcome.txt"
  echo '----------------------------------------------------------------------'
else
  echo "  Welcome Pack: $DATA_DIR/welcome.txt (written shortly after first boot)"
fi
echo
echo "  Admin     : $DATA_DIR/welcome.txt   (system admin credentials)"
echo "  Logs      : $DATA_DIR/logs/server.log"
echo "  Stop      : $0 stop"
echo "  Restart   : $0"
echo "  Desktop   : ~/Desktop/SuperSQE.command (start + open in browser)"
echo

# ---- 8. Desktop shortcut: start the server + open the browser -------------
START_SCRIPT="$INSTALL_DIR/start-supersqe.sh"
cat > "$START_SCRIPT" <<'EOS'
#!/bin/bash
set -u
INSTALL_DIR="$HOME/supersqe"
DATA_DIR="$HOME/supersqe-data"
CFG="$DATA_DIR/config.env"
if [ ! -f "$CFG" ]; then
  echo "SuperSQE is not installed in $INSTALL_DIR."
  read -n 1 -s -r -p "Press any key to close..."
  exit 1
fi
PORT="$(grep -E '^PORT=' "$CFG" | cut -d= -f2- | tr -d '[:space:]' || true)"
[ -n "$PORT" ] || PORT=3000
export SUPERSQE_INSTALL_DIR="$INSTALL_DIR"
export SUPERSQE_DATA_DIR="$DATA_DIR"
export PLAYWRIGHT_BROWSERS_PATH="$INSTALL_DIR/browsers"
export NODE_ENV=production
if ! curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
  echo "Starting SuperSQE on port $PORT..."
  mkdir -p "$DATA_DIR/logs"
  cd "$INSTALL_DIR/supersqe-server" || exit 1
  nohup "$INSTALL_DIR/runtime/supersqe-server" -r tsconfig-paths/register dist/server.js \
    >> "$DATA_DIR/logs/server.log" 2>&1 &
  echo $! > "$DATA_DIR/server.pid"
  n=0
  while [ "$n" -lt 120 ]; do
    if curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then break; fi
    n=$((n + 1))
    sleep 2
  done
fi
if curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
  open "http://127.0.0.1:$PORT"
else
  echo "SuperSQE did not start. Last log lines:"
  tail -n 30 "$DATA_DIR/logs/server.log" 2>/dev/null || true
  read -n 1 -s -r -p "Press any key to close..."
fi
EOS
chmod +x "$START_SCRIPT"
cp "$START_SCRIPT" "$HOME/Desktop/SuperSQE.command"
chmod +x "$HOME/Desktop/SuperSQE.command"

# Branded URL shortcut (matches the configured port). The .command above starts
# the server; this opens the UI once it is running.
WEBLOC="$HOME/Desktop/SuperSQE.webloc"
WEBLOC_TEMPLATE="$INSTALL_DIR/resources/SuperSQE.webloc"
if [ -f "$WEBLOC_TEMPLATE" ]; then
  ditto "$WEBLOC_TEMPLATE" "$WEBLOC" 2>/dev/null || cp "$WEBLOC_TEMPLATE" "$WEBLOC"
  /usr/libexec/PlistBuddy -c "Set :URL http://127.0.0.1:$PORT" "$WEBLOC" 2>/dev/null || true
else
  cat > "$WEBLOC" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict><key>URL</key><string>http://127.0.0.1:$PORT</string></dict>
</plist>
EOF
fi
chmod 644 "$WEBLOC" 2>/dev/null || true

# ---- One-click agent install URL handler (supersqe-runner://) --------------
RUNNER_APP="$HOME/Applications/SuperSQE Runner.app"
RUNNER_INSTALLER="$INSTALL_DIR/service/install-runner.sh"
if [ -f "$RUNNER_INSTALLER" ]; then
  mkdir -p "$RUNNER_APP/Contents/MacOS" "$RUNNER_APP/Contents/Resources"
  cp "$RUNNER_INSTALLER" "$RUNNER_APP/Contents/Resources/install-runner.sh"
  chmod +x "$RUNNER_APP/Contents/Resources/install-runner.sh"
  cat > "$RUNNER_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SuperSQE Runner</string>
  <key>CFBundleDisplayName</key><string>SuperSQE Runner</string>
  <key>CFBundleIdentifier</key><string>com.supersqe.runner.launcher.portable</string>
  <key>CFBundleVersion</key><string>1.0.0</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>runner-install</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>SuperSQE Runner Installer</string>
      <key>CFBundleURLSchemes</key><array><string>supersqe-runner</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
  cat > "$RUNNER_APP/Contents/MacOS/runner-install" <<'LAUNCHER'
#!/bin/bash
HERE="$(cd "$(dirname "$0")/../Resources" && pwd)"
URL="${1:-}"
[ -z "$URL" ] && exit 0
TMP="/tmp/supersqe-runner-install-$$.command"
{
  echo '#!/bin/bash'
  printf 'exec "%s/install-runner.sh" %q\n' "$HERE" "$URL"
} > "$TMP"
chmod +x "$TMP"
open -a Terminal "$TMP"
LAUNCHER
  chmod +x "$RUNNER_APP/Contents/MacOS/runner-install"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$RUNNER_APP" >/dev/null 2>&1 || true
  echo "  Agents    : Install button opens Terminal automatically"
  echo
fi

open "http://127.0.0.1:$PORT" 2>/dev/null || true
