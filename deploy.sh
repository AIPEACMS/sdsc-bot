#!/usr/bin/env bash
# Build the AOT bundle and deploy to the production VM by whatever private channel is available.
#
# Usage: ./deploy.sh [host]
#   host defaults to user@host (SSH daily driver).
#
# Fallback (no SSH): pipe the tarball through the private channel and
# copy via SSH — see the root AGENTS.md redeploy flow.

set -euo pipefail

HOST="${1:-user@host}"
TARBALL="/tmp/sdsc-bundle.tar.gz"

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
