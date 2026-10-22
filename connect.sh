#!/bin/sh
# Frontier — connect this machine as a worker, with just a pairing code.
#   curl -fsSL https://frontierengineer.com/connect.sh | sh -s -- <CODE> [HOST:PORT]
# Get <CODE> from "+ Connect a machine" in Settings -> Machines on your Frontier server.
# HOST:PORT is optional: omit it and the worker finds the host through the Link
# service (works from anywhere); pass it to dial a known address on the same network first.
set -eu

CODE="${1:-}"
HOST="${2:-}"
if [ -z "$CODE" ]; then
  echo "Usage: curl -fsSL https://frontierengineer.com/connect.sh | sh -s -- <pairing-code> [host:port]" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "Frontier workers need Node 18+ (https://nodejs.org). Install it and re-run." >&2
  exit 1
fi
NODE_MAJOR=$(node -e 'process.stdout.write(String(process.versions.node.split(".")[0]))' 2>/dev/null || echo 0)
if [ "$NODE_MAJOR" -lt 18 ] 2>/dev/null; then
  echo "Frontier workers need Node 18+ (found $(node -v)). Upgrade and re-run." >&2
  exit 1
fi
if ! command -v claude >/dev/null 2>&1 && ! command -v opencode >/dev/null 2>&1; then
  echo "Note: no agent CLI found. Install Claude Code or OpenCode and log in on this machine to run turns." >&2
fi

DIR="${FRONTIER_WORKER_DIR:-$HOME/.frontier-worker}"
mkdir -p "$DIR"
DAEMON="$DIR/daemon.js"
DAEMON_URL="${FRONTIER_DAEMON_URL:-https://frontierengineer.github.io/releases/connect/daemon.bundle.js}"

echo "Downloading the Frontier worker daemon..."
curl -fsSL "$DAEMON_URL" -o "$DAEMON"

# Supervise: the daemon persists its identity under $DIR, so after the first
# pairing a restart reconnects with no code. Loop so a crash or a dropped
# connection comes back on its own (for a permanent install, wrap this in a
# systemd unit or a launchd agent instead).
echo "Connecting..."
while true; do
  if [ -n "$HOST" ]; then
    node "$DAEMON" connect "$HOST" "$CODE" || true
  else
    node "$DAEMON" connect "$CODE" || true
  fi
  sleep 3
done
