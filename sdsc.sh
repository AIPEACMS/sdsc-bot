#!/usr/bin/env bash
# SDSC bot updater — run on the VM to pull the latest bundle from GitHub
# Releases and restart the service. No secrets: the repo is public, and the
# bot's secrets stay in the secret env file, untouched by updates.
#
# Usage:
#   ./sdsc.sh update            # update to the latest release
#   ./sdsc.sh update v0.2.0     # update to a specific release tag
#
# Needs: curl, sha256sum, systemd. Run as root (or with sudo).

set -euo pipefail

REPO="AIPEACM/sdsc-bot"
API="https://api.github.com/repos/${REPO}/releases"
INSTALL_DIR="/opt/sdsc-bot"
BACKUP_DIR="/opt/sdsc-bot.prev"
SERVICE="sdsc-bot"
WORK="$(mktemp -d /tmp/sdsc-update.XXXXXX)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
  fi
}

# resolve the release: latest by default, or a pinned tag
resolve_release() {
  local tag="${1:-}"
  if [[ -n "$tag" ]]; then
    local url="${API}/tags/${tag}"
    tag="$(curl -fsSL "$url" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
    [[ -n "$tag" ]] || die "release tag '$1' not found"
  else
    tag="$(curl -fsSL "${API}/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
    [[ -n "$tag" ]] || die "no releases found"
  fi
  echo "$tag"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    update) ;;
    *) die "usage: $0 update [tag]" ;;
  esac

  require_root "$@"
  shift

  command -v curl >/dev/null || die "curl is required"
  command -v sha256sum >/dev/null || die "sha256sum is required"

  local tag
  tag="$(resolve_release "${1:-}")"
  local version="${tag#v}"
  local asset="sdsc-bot-${version}.tar.gz"
  local base="https://github.com/${REPO}/releases/download/${tag}"

  log "fetching ${tag} (${asset})"
  curl -fsSL -o "${WORK}/${asset}" "${base}/${asset}"
  curl -fsSL -o "${WORK}/${asset}.sha256" "${base}/${asset}.sha256"

  log "verifying checksum"
  (cd "$WORK" && sha256sum -c "${asset}.sha256")

  log "staging extract"
  mkdir -p "${WORK}/stage"
  tar xzf "${WORK}/${asset}" -C "${WORK}/stage"
  [[ -x "${WORK}/stage/bin/main" ]] || die "bundle has no bin/main"

  # keep the current install as a rollback point
  rm -rf "$BACKUP_DIR"
  if [[ -d "$INSTALL_DIR" ]]; then
    mv "$INSTALL_DIR" "$BACKUP_DIR"
  fi
  mv "${WORK}/stage" "$INSTALL_DIR"
  chown -R root:root "$INSTALL_DIR"

  log "restarting ${SERVICE}"
  systemctl restart "$SERVICE"

  if systemctl is-active --quiet "$SERVICE"; then
    log "deployed ${tag} — ${SERVICE} is active"
    rm -rf "$BACKUP_DIR"
    rm -rf "$WORK"
  else
    log "service failed to start — rolling back"
    systemctl stop "$SERVICE" || true
    rm -rf "$INSTALL_DIR"
    if [[ -d "$BACKUP_DIR" ]]; then
      mv "$BACKUP_DIR" "$INSTALL_DIR"
      chown -R root:root "$INSTALL_DIR"
      systemctl start "$SERVICE"
      log "rolled back to previous bundle"
    else
      die "no previous bundle to roll back to"
    fi
    exit 1
  fi
}

main "$@"
