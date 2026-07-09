#!/bin/sh
# Frontier — run the host (server + co-located worker) NATIVELY, no Docker.
#
#   curl -fsSL https://frontierengineer.com/install.sh | sh
#
# This is "connect.sh for the host": the same curl|sh pattern, a Node-version
# gate, a release-bundle download, and a persistent data dir — plus real
# supervision (a systemd user unit on Linux, a launchd agent on macOS) so the
# host restarts on crash and comes back after a reboot.
#
# What it does:
#   1. Require Node >= 22 and git (bail with a link, like connect.sh).
#   2. Download the prebuilt host bundle for the channel (the frontend ships
#      pre-built, so Vite/Monaco never build on your machine) and unpack it to
#      ~/.frontier/app.
#   3. Install + start a user service that runs `node backend/index.bundle.js`
#      with FRONTIER_DIR / HOME / PORT, restarting on crash and on login/boot.
#   4. Open http://localhost:<port>.
#
# Voice runs IN-PROCESS (STT via transformers.js ONNX Whisper, TTS via kokoro-js
# ONNX Kokoro) — no Python, ever. The model weights download on first voice use
# and cache under the data dir; set FRONTIER_STT_URL / FRONTIER_TTS_URL to point
# at a hosted engine instead.
#
# Env overrides:
#   FRONTIER_CHANNEL      release channel               (default: stable)
#   FRONTIER_DIR          install + data root           (default: $HOME/.frontier)
#   PORT                  UI/host port                  (default: 34567)
#   FRONTIER_BUNDLE_URL   exact bundle URL (wins over everything below)
#   FRONTIER_RELEASES_URL release base for the default bundle URL
#                         (default: https://github.com/frontierengineer/releases/releases/download)
#   FRONTIER_NO_SERVICE=1 skip installing supervision; just run in the foreground
#   FRONTIER_NO_OPEN=1    don't open the browser
set -eu

CHANNEL="${FRONTIER_CHANNEL:-stable}"
DIR="${FRONTIER_DIR:-$HOME/.frontier}"
PORT="${PORT:-34567}"
# Default to a GitHub release asset:
#   https://github.com/frontierengineer/releases/releases/download/host-<channel>/server-<channel>.tar.gz
# Override the whole URL with FRONTIER_BUNDLE_URL, or just the base with
# FRONTIER_RELEASES_URL (handy for testing against a local file server).
# The internal dev channels (master, nightly) are served ONLY by the in-cluster
# bundle store — they are not on the public internet at all. Installing a dev
# channel therefore works on the cluster network (dev boxes); anywhere else the
# cluster DNS name simply won't resolve. stable/rc stay public on
# frontierengineer/releases.
case "$CHANNEL" in
  master|nightly) DEFAULT_RELEASES_BASE="http://bundle-store.frontier.svc.cluster.local";;
  *)              DEFAULT_RELEASES_BASE="https://github.com/frontierengineer/releases/releases/download";;
esac
RELEASES_BASE="${FRONTIER_RELEASES_URL:-$DEFAULT_RELEASES_BASE}"
BUNDLE_URL="${FRONTIER_BUNDLE_URL:-$RELEASES_BASE/host-$CHANNEL/server-$CHANNEL.tar.gz}"

APP="$DIR/app"
DATA="$DIR/data"
AGENT_HOME="$DIR/home"
LABEL="com.frontierengineer.host"

C_INFO='\033[1;36m'; C_OK='\033[1;32m'; C_ERR='\033[1;31m'; C_OFF='\033[0m'
say() { printf "${C_INFO}▸${C_OFF} %s\n" "$1"; }
ok()  { printf "${C_OK}✓${C_OFF} %s\n" "$1"; }
die() { printf "${C_ERR}✗${C_OFF} %s\n" "$1" >&2; exit 1; }

OS="$(uname -s 2>/dev/null || echo unknown)"

open_browser() {
  [ "${FRONTIER_NO_OPEN:-0}" = "1" ] && return 0
  URL="http://localhost:$PORT"
  if command -v open >/dev/null 2>&1; then (open "$URL" >/dev/null 2>&1 &)
  elif command -v xdg-open >/dev/null 2>&1; then (xdg-open "$URL" >/dev/null 2>&1 &)
  else say "Open $URL in your browser."; fi
}

# Wait for the host to answer, then open the browser. Used by the service paths.
wait_then_open() {
  i=0
  while [ "$i" -lt 60 ]; do
    if curl -fsS -o /dev/null "http://127.0.0.1:$PORT/api/version" 2>/dev/null; then break; fi
    i=$((i + 1)); sleep 1
  done
  open_browser
}

# ── 1. Prerequisites ─────────────────────────────────────────────────────────
# Node >= 22 — the host floor (server/package.json engines; the backend bundle
# targets node22). No silent runtime install: point at the official source, like
# connect.sh does.
command -v node >/dev/null 2>&1 || die "Frontier needs Node 22+. Install it from https://nodejs.org and re-run."
NODE_MAJOR="$(node -e 'process.stdout.write(String(process.versions.node.split(".")[0]))' 2>/dev/null || echo 0)"
[ "$NODE_MAJOR" -ge 22 ] 2>/dev/null || die "Frontier needs Node >= 22 (found $(node -v)). Upgrade and re-run."

# git — agents do real git work.
command -v git >/dev/null 2>&1 || die "Frontier needs git on your PATH. Install it and re-run."

# A downloader.
if command -v curl >/dev/null 2>&1; then DL="curl -fL --proto =https --tlsv1.2"
elif command -v wget >/dev/null 2>&1; then DL="wget -O-"
else die "Frontier's installer needs curl or wget."; fi
# Local file servers (testing) speak plain http — relax the https-only guard there.
case "$BUNDLE_URL" in http://*) DL="$(printf '%s' "$DL" | sed 's/ --proto =https --tlsv1.2//')";; esac

# ── 2. Download + unpack the host bundle ─────────────────────────────────────
# The bundle is the server root: backend/index.bundle.js + prod node_modules,
# machine/ (worker daemon), frontend/dist (prebuilt UI) + src, and the built-in
# extensions. Voice (STT/TTS) is in-process inside the backend bundle — no sidecars.
mkdir -p "$DATA" "$AGENT_HOME"
say "Downloading the Frontier host bundle ($CHANNEL)…"
say "  $BUNDLE_URL"
TMP_TGZ="$(mktemp "${TMPDIR:-/tmp}/frontier-bundle.XXXXXX")"
trap 'rm -f "$TMP_TGZ"' EXIT INT TERM
# shellcheck disable=SC2086
$DL "$BUNDLE_URL" > "$TMP_TGZ" || die "Could not download the bundle from $BUNDLE_URL"
[ -s "$TMP_TGZ" ] || die "Downloaded bundle is empty — bad URL or release asset missing."

say "Unpacking to $APP …"
# Atomic-ish swap: extract beside the live install, then move into place. The
# tarball's top dir is server-<channel>/ — strip it so files land directly in $APP.
rm -rf "$APP.new"
mkdir -p "$APP.new"
tar -xzf "$TMP_TGZ" -C "$APP.new" --strip-components=1 \
  || die "Could not unpack the bundle (corrupt download?)."
[ -f "$APP.new/backend/index.bundle.js" ] || die "Bundle is missing backend/index.bundle.js — wrong artifact?"
rm -rf "$APP"
mv "$APP.new" "$APP"
ok "Installed $(node -e 'try{const r=require(process.argv[1]);process.stdout.write(r.version+" ("+r.gitSha+")")}catch(e){process.stdout.write("Frontier")}' "$APP/release.json" 2>/dev/null || echo "Frontier")"

# ── 3. Run, supervised ───────────────────────────────────────────────────────
NODE_BIN="$(command -v node)"

run_foreground() {
  say "Starting Frontier on http://localhost:$PORT (Ctrl-C to stop)…"
  open_browser
  cd "$APP"
  FRONTIER_DIR="$DATA"; HOME="$AGENT_HOME"; export FRONTIER_DIR HOME PORT FRONTIER_CHANNEL
  exec "$NODE_BIN" backend/index.bundle.js
}

install_systemd_user() {
  # A systemd *user* unit — no root, starts at login, restarts on crash. With
  # lingering enabled it also survives logout/reboot.
  UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$UNIT_DIR"
  ENV_LINES="Environment=FRONTIER_DIR=$DATA
Environment=HOME=$AGENT_HOME
Environment=PORT=$PORT
Environment=FRONTIER_CHANNEL=$CHANNEL"
  cat > "$UNIT_DIR/frontier.service" <<EOF
[Unit]
Description=Frontier host (native)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$APP
$ENV_LINES
ExecStart=$NODE_BIN backend/index.bundle.js
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  # Survive logout/reboot if we can (best-effort; needs no password on most distros).
  loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true
  systemctl --user enable --now frontier.service
  ok "Installed + started the systemd user service 'frontier'."
  say "  logs:    journalctl --user -u frontier -f"
  say "  stop:    systemctl --user stop frontier"
  say "  remove:  systemctl --user disable --now frontier"
}

install_launchd() {
  # A launchd LaunchAgent — runs at login, KeepAlive restarts it on crash.
  PLIST_DIR="$HOME/Library/LaunchAgents"
  mkdir -p "$PLIST_DIR"
  PLIST="$PLIST_DIR/$LABEL.plist"
  LOG="$DATA/host.log"
  ENV_XML="    <key>FRONTIER_DIR</key><string>$DATA</string>
    <key>HOME</key><string>$AGENT_HOME</string>
    <key>PORT</key><string>$PORT</string>
    <key>FRONTIER_CHANNEL</key><string>$CHANNEL</string>"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE_BIN</string>
    <string>backend/index.bundle.js</string>
  </array>
  <key>WorkingDirectory</key><string>$APP</string>
  <key>EnvironmentVariables</key>
  <dict>
$ENV_XML
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
  # bootstrap (modern) with a fallback to load (older macOS).
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
    || { launchctl unload "$PLIST" >/dev/null 2>&1 || true; launchctl load "$PLIST"; }
  ok "Installed + started the launchd agent '$LABEL'."
  say "  logs:    tail -f $LOG"
  say "  stop:    launchctl bootout gui/$(id -u)/$LABEL"
}

if [ "${FRONTIER_NO_SERVICE:-0}" = "1" ]; then
  run_foreground
fi

case "$OS" in
  Linux)
    if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
      install_systemd_user
      wait_then_open
      ok "Frontier is running at http://localhost:$PORT"
    else
      say "systemd user services aren't available here — running in the foreground instead."
      run_foreground
    fi
    ;;
  Darwin)
    install_launchd
    wait_then_open
    ok "Frontier is running at http://localhost:$PORT"
    ;;
  *)
    say "Unrecognised OS ($OS) — no supervisor to install; running in the foreground."
    run_foreground
    ;;
esac
