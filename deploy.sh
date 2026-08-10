#!/usr/bin/env bash
# Build the AOT bundle and deploy to the production VM.
#
# Usage: ./deploy.sh [host]
#   host defaults to the value of $SDSC_HOST, or to a generic placeholder.
#   Set SDSC_HOST=<user>@<host> in your environment — the real hostname is
#   never committed to this repo.
#
# Fallback: copy the bundle to the VM by whatever private channel is
# available (see the root AGENTS.md redeploy flow).

set -euo pipefail

HOST="${1:-${SDSC_HOST:-user@host}}"
TARBALL="/tmp/sdsc-bundle.tar.gz"

if [[ "$HOST" == "user@host" ]]; then
  echo "error: set SDSC_HOST (e.g. export SDSC_HOST=user@host) before deploying" >&2
  exit 1
fi

echo "==> dart build cli -o build"
dart build cli -o build

echo "==> packing bundle"
tar czf "$TARBALL" -C build/bundle .

echo "==> scp to $HOST"
scp "$TARBALL" "$HOST":/tmp/

echo "==> extract + restart on $HOST"
ssh "$HOST" 'sudo tar xzf /tmp/sdsc-bundle.tar.gz -C /opt/sdsc-bot && sudo systemctl restart sdsc-bot'

rm -f "$TARBALL"
echo "==> deployed"
