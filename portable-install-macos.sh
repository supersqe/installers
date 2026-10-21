#!/usr/bin/env bash
# ============================================================================
# SuperSQE — portable (user-space) install for macOS. NO ADMIN / NO SUDO.
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
VERSION="${SUPERSQE_VERSION:-1.0.5}"
REPO="https://github.com/supersqe/installers/releases/download"
PORT="${SUPERSQE_PORT:-3000}"
PG_PORT="${SUPERSQE_PG_PORT:-5433}"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ── stop ────────────────────────────────────────────────────────────────────
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

# ── 1. Get the .pkg (local path or download the latest release) ─────────────
PKG="${1:-}"
if [ -z "$PKG" ]; then
  ARCH="$(uname -m)"; [ "$ARCH" = "arm64" ] || ARCH=x64
  PKG="$HOME/Downloads/supersqe-macos-$ARCH-v$VERSION.pkg"
  if [ ! -f "$PKG" ]; then
    log "Downloading supersqe-macos-$ARCH-v$VERSION.pkg ..."
    curl -fL --progress-bar -o "$PKG" "$REPO/v$VERSION/supersqe-macos-$ARCH-v$VERSION.pkg" \
      || fail "download failed — check the version (v$VERSION) exists on github.com/supersqe/installers/releases"
  fi
fi
[ -f "$PKG" ] || fail "package not found: $PKG"
xattr -dr com.apple.quarantine "$PKG" 2>/dev/null || true

# ── 2. Expand the package (pkgutil needs no admin) ──────────────────────────
log "Expanding $PKG ..."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pkgutil --expand-full "$PKG" "$WORK" || fail "pkgutil --expand-full failed"

SERVER_BIN="$(find "$WORK" -type f -path '*/runtime/supersqe-server' | head -n 1)"
[ -n "$SERVER_BIN" ] || fail "payload not found inside the package (unexpected layout)"
PAYLOAD_DIR="$(dirname "$(dirname "$SERVER_BIN")")"

# ── 3. Install into ~/supersqe ──────────────────────────────────────────────
log "Installing payload to $INSTALL_DIR ..."
if [ -d "$INSTALL_DIR" ]; then
  [ -f "$DATA_DIR/server.pid" ] && kill "$(cat "$DATA_DIR/server.pid")" 2>/dev/null || true
  rm -rf "$INSTALL_DIR"
fi
mv "$PAYLOAD_DIR" "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/runtime/supersqe-server"
chmod +x "$INSTALL_DIR/service/"*.sh 2>/dev/null || true

# ── 4. Data dir + config.env (idempotent — keeps existing secrets) ──────────
mkdir -p "$DATA_DIR/logs" "$DATA_DIR/uploads"
CFG="$DATA_DIR/config.env"
if [ ! -f "$CFG" ]; then
  log "Writing $CFG ..."
  PG_PASS="$(openssl rand -hex 24)"
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
EOF
  chmod 600 "$CFG"
else
  log "Keeping existing $CFG"
fi

# ── 5. Start the server (it bootstraps postgres + schema + admin itself) ────
log "Starting SuperSQE (first run initialises the bundled PostgreSQL)..."
export SUPERSQE_INSTALL_DIR="$INSTALL_DIR"
export SUPERSQE_DATA_DIR="$DATA_DIR"
export PLAYWRIGHT_BROWSERS_PATH="$INSTALL_DIR/browsers"
export NODE_ENV=production
cd "$INSTALL_DIR/supersqe-server"
nohup "$INSTALL_DIR/runtime/supersqe-server" -r tsconfig-paths/register dist/server.js \
  >> "$DATA_DIR/logs/server.log" 2>&1 &
echo $! > "$DATA_DIR/server.pid"

# ── 6. Wait for health ──────────────────────────────────────────────────────
log "Waiting for http://127.0.0.1:$PORT/api/health ..."
UP=""
for _ in $(seq 1 90); do
  if curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then UP=1; break; fi
  sleep 2
done
if [ -z "$UP" ]; then
  echo "--- last 40 log lines ---"; tail -n 40 "$DATA_DIR/logs/server.log" || true
  fail "server did not become healthy — see $DATA_DIR/logs/server.log"
fi

log "SuperSQE is running."
echo
echo "  URL       : http://127.0.0.1:$PORT"
echo "  Admin     : cat $DATA_DIR/welcome.txt   (system admin credentials)"
echo "  Logs      : $DATA_DIR/logs/server.log"
echo "  Stop      : $0 stop"
echo "  Restart   : $0"
echo
open "http://127.0.0.1:$PORT" 2>/dev/null || true
