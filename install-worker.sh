#!/bin/sh
# Frontier — install a worker. This URL is a permanent bootstrap, not the installer.
#
#   curl -fsSL https://frontierengineer.com/install-worker.sh | sh
#
# The real installer is `install-worker.sh`, which lives with the worker code and is
# published as the `install.sh` asset on every public channel cut (frontier repo,
# .github/workflows/publish-bundles.yml). This file only fetches and runs that
# current canonical copy, so this URL can never serve a stale installer again
# (it once did; this bootstrap is the fix). All FRONTIER_* env overrides
# (FRONTIER_CHANNEL, FRONTIER_BUNDLE_URL, FRONTIER_DIR_ROOT, …) pass straight
# through to the canonical script.
#
# FRONTIER_INSTALLER_URL overrides where the canonical script is fetched from
# (for testing against a local file server).
set -u

URL="${FRONTIER_INSTALLER_URL:-https://github.com/frontierengineer/releases/releases/download/worker-stable/install-worker.sh}"

if command -v curl >/dev/null 2>&1; then DL="curl -fsSL --proto =https --tlsv1.2"
elif command -v wget >/dev/null 2>&1; then DL="wget -qO-"
else echo "!!  need curl or wget to download the Frontier installer" >&2; exit 1; fi
case "$URL" in http://*) DL="$(printf '%s' "$DL" | sed 's/ --proto =https --tlsv1.2//')";; esac

TMP="$(mktemp "${TMPDIR:-/tmp}/frontier-install-worker.XXXXXX")" || exit 1
if ! $DL "$URL" > "$TMP" || ! [ -s "$TMP" ]; then
  rm -f "$TMP"
  echo "!!  could not download the Frontier installer from $URL" >&2
  echo "!!  check your network and retry; the installer is published with every Frontier release" >&2
  exit 1
fi
# Sanity gate so a proxy/CDN error page is never executed as shell.
if ! head -c 100 "$TMP" | grep -q "install-worker.sh"; then
  rm -f "$TMP"
  echo "!!  the download from $URL does not look like the Frontier installer; not running it" >&2
  exit 1
fi

sh "$TMP" "$@"
STATUS=$?
rm -f "$TMP"
exit $STATUS
