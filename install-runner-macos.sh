#!/bin/bash
# SuperSQE Runner Agent installer (macOS, per-user - no admin required).
#
# Downloads the agent for a given token, installs Node.js + Playwright and the
# Chromium browser, creates a "SuperSQE Runner" shortcut on the Desktop and
# starts it.
#
# Usage from the dashboard one-liner:
#   curl -fsSL '<platform>/api/download/<token>/install?os=macos' | bash
#
# Usage via the supersqe-runner:// handler installed with SuperSQE:
#   install-runner.sh "supersqe-runner://install?server=...&token=...&name=..."

set -euo pipefail

urldecode() {
  local value="${1//+/ }"
  printf '%b' "${value//%/\\x}"
}

SERVER="${SUPERSQE_SERVER:-}"
TOKEN="${SUPERSQE_AGENT_TOKEN:-}"
AGENT_NAME="${SUPERSQE_AGENT_NAME:-My Runner}"
FROM_PROTOCOL=0

if [ "$#" -gt 0 ]; then
  case "$1" in
    supersqe-runner://*)
      FROM_PROTOCOL=1
      QUERY="${1#*\?}"
      OLD_IFS="$IFS"
      IFS='&'
      for pair in $QUERY; do
        key="${pair%%=*}"
        value="${pair#*=}"
        case "$key" in
          server) SERVER="$(urldecode "$value")" ;;
          token) TOKEN="$value" ;;
          name) AGENT_NAME="$(urldecode "$value")" ;;
        esac
      done
      IFS="$OLD_IFS"
      ;;
  esac
fi

if [ -z "$SERVER" ] || [ -z "$TOKEN" ]; then
  echo "This installer needs a SuperSQE server URL and an agent token."
  echo "Open SuperSQE > Agents and click Install, or run:"
  echo "  SUPERSQE_SERVER='http://...' SUPERSQE_AGENT_TOKEN='...' bash install-runner.sh"
  exit 1
fi

SERVER="${SERVER%/}"
RUNNER_DIR="$HOME/SuperSQE/runner"
DESKTOP_DIR="$HOME/Desktop"

if [ "$FROM_PROTOCOL" = "1" ] && [ "${SUPERSQE_YES:-0}" != "1" ]; then
  echo ""
  echo "A website is asking to install the SuperSQE runner for:"
  echo "  Server: $SERVER"
  echo "  Agent:  $AGENT_NAME"
  echo ""
  read -r -p 'Continue? (Y/n) ' ANSWER
  case "$ANSWER" in
    n|N|no|NO) echo 'Cancelled.'; exit 0 ;;
    *) ;;
  esac
fi

mkdir -p "$RUNNER_DIR/logs" "$DESKTOP_DIR"

echo ""
echo "========================================"
echo "  SuperSQE Runner Agent"
echo "========================================"
echo "  Agent:  $AGENT_NAME"
echo "  Server: $SERVER"
echo ""
echo "Installs in your home folder - no administrator password needed."
echo "Keep the runner window open while this Mac is online. When it is"
echo "offline, use the SuperSQE Runner shortcut on the Desktop."
echo ""

echo "==> Downloading the agent files"
TMPZIP="$(mktemp /tmp/supersqe-agent.XXXXXX)"
curl -fSL --progress-bar "$SERVER/api/download/$TOKEN" -o "$TMPZIP"
unzip -o -q "$TMPZIP" -d "$RUNNER_DIR"
rm -f "$TMPZIP"
echo "    Agent files installed"

find_node() {
  command -v node >/dev/null 2>&1 || return 1
  local major
  major="$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
  [ "${major:-0}" -ge 18 ]
}

if find_node; then
  NODE="$(command -v node)"
  NPM="$(command -v npm)"
  echo "==> Using system Node.js $(node -v)"
else
  echo "==> Installing a private Node.js runtime"
  case "$(uname -m)" in
    arm64) ARCH="arm64" ;;
    *) ARCH="x64" ;;
  esac
  NODE_DIR="$HOME/SuperSQE/node"
  if [ ! -x "$NODE_DIR/bin/node" ]; then
    TARBALL="$(mktemp /tmp/supersqe-node.XXXXXX).tar.gz"
    curl -fSL --progress-bar "https://nodejs.org/dist/v20.18.0/node-v20.18.0-darwin-$ARCH.tar.gz" -o "$TARBALL"
    mkdir -p "$NODE_DIR"
    tar -xzf "$TARBALL" -C "$NODE_DIR" --strip-components=1
    rm -f "$TARBALL"
  fi
  NODE="$NODE_DIR/bin/node"
  NPM="$NODE_DIR/bin/npm"
fi

# npm is a shell script with a '#!/usr/bin/env node' shebang; make sure the
# private Node.js runtime is on PATH for it (and for any child scripts).
NODE_BIN_DIR="$(dirname "$NODE")"
export PATH="$NODE_BIN_DIR:$PATH"

echo "==> Installing Playwright and dependencies (2-5 minutes)"
(cd "$RUNNER_DIR" && "$NPM" install --no-audit --no-fund --loglevel=error)
echo "    Dependencies installed"

echo "==> Installing the Chromium browser used by the runner"
if [ -f "$RUNNER_DIR/node_modules/playwright/cli.js" ]; then
  if ! "$NODE" "$RUNNER_DIR/node_modules/playwright/cli.js" install chromium; then
    echo "    Chromium install reported an error - the runner retries it when it starts."
  fi
else
  echo "    Playwright CLI not found - the runner retries Chromium on start."
fi

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

cat > "$RUNNER_DIR/runner.config.json" <<EOF
{"server":"$(json_escape "$SERVER")","token":"$(json_escape "$TOKEN")","name":"$(json_escape "$AGENT_NAME")"}
EOF

echo "==> Creating the SuperSQE Runner shortcut"
NODE_Q="$(printf '%q' "$NODE")"
RUNNER_Q="$(printf '%q' "$RUNNER_DIR")"
cat > "$RUNNER_DIR/start-runner.sh" <<EOF
#!/bin/bash
RUNNER_DIR=$RUNNER_Q
cd "\$RUNNER_DIR" || exit 1
NODE_BIN=$NODE_Q
if [ ! -x "\$NODE_BIN" ]; then NODE_BIN="\$(command -v node)"; fi
CFG="\$RUNNER_DIR/runner.config.json"
export SUPERSQE_URL="\$("\$NODE_BIN" -e 'const c=require(process.argv[1]);process.stdout.write(c.server)' "\$CFG")"
export SUPERSQE_AGENT_TOKEN="\$("\$NODE_BIN" -e 'const c=require(process.argv[1]);process.stdout.write(c.token)' "\$CFG")"
export SUPERSQE_AGENT_NAME="\$("\$NODE_BIN" -e 'const c=require(process.argv[1]);process.stdout.write(c.name)' "\$CFG")"
echo ""
echo "Connecting to \$SUPERSQE_URL as \$SUPERSQE_AGENT_NAME..."
echo "Leave this window open while this Mac is online. Close it to go offline."
echo ""
"\$NODE_BIN" "\$RUNNER_DIR/agent.js"
echo ""
read -n 1 -s -r -p "The runner has stopped. Press any key to close..."
echo ""
EOF
chmod +x "$RUNNER_DIR/start-runner.sh"

SHORTCUT="$DESKTOP_DIR/SuperSQE Runner.command"
cp "$RUNNER_DIR/start-runner.sh" "$SHORTCUT"
chmod +x "$SHORTCUT"
xattr -dr com.apple.quarantine "$RUNNER_DIR" 2>/dev/null || true
xattr -d com.apple.quarantine "$SHORTCUT" 2>/dev/null || true
echo "    Desktop shortcut: $SHORTCUT"

echo ""
echo "========================================"
echo "  Runner installed"
echo "========================================"
echo "  Folder:   $RUNNER_DIR"
echo "  Shortcut: Desktop > SuperSQE Runner"
echo ""
echo "Double-click \"SuperSQE Runner\" on your Desktop whenever the runner is"
echo "offline. Keep its Terminal window open while connected."
echo ""

if [ "${SUPERSQE_NO_LAUNCH:-0}" != "1" ]; then
  open -a Terminal "$SHORTCUT"
fi
