#!/usr/bin/env bash
# SDSC bot updater — run on the VM to pull the latest bundle from GitHub
# Releases and restart the service. No secrets: the repo is public, and the
# bot's secrets stay in the VM's secret env file, untouched by updates.
#
# Usage:
#   ./sdsc.sh update            # update to the latest release
#   ./sdsc.sh update v0.2.0     # update to a specific release tag
#
# Needs: curl, sha256sum, file. Run as root (or with sudo). Detects the
# machine's architecture and fetches the matching bundle.

set -euo pipefail

REPO="AIPEACMS/sdsc-bot"
API="https://api.github.com/repos/${REPO}/releases"
INSTALL_DIR="/opt/sdsc-bot"
BACKUP_DIR="/opt/sdsc-bot.prev"
SERVICE="${SERVICE:-}"
WORK="$(mktemp -d /tmp/sdsc-update.XXXXXX)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
  fi
}

# release_json -- the release payload: latest by default, or a pinned tag.
release_json() {
  local tag="${1:-}"
  if [[ -n "$tag" ]]; then
    curl -fsSL "${API}/tags/${tag}" || die "release tag '$tag' not found"
  else
    curl -fsSL "${API}/latest" || die "no releases found"
  fi
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
  command -v file >/dev/null || die "file is required"

  local arch tag version asset base
  case "$(uname -m)" in
    x86_64)  arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac

  local json
  json="$(release_json "${1:-}")"
  tag="$(printf '%s' "$json" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
  [[ -n "$tag" ]] || die "no release tag in the API response"
  version="${tag#v}"

  asset="sdsc-bot-${version}-${arch}.tar.gz"
  base="https://github.com/${REPO}/releases/download/${tag}"

  asset_digest() {
    printf '%s' "$json" | awk -v want="$1" '
      /"name":/ { n=$0; sub(/.*"name": *"/,"",n); sub(/".*/,"",n) }
      /"digest":/ && n==want { d=$0; sub(/.*"digest": *"sha256:/,"",d); sub(/".*/,"",d); print d; exit }
    '
  }

  local digest
  digest="$(asset_digest "$asset")"
  if [[ -z "$digest" ]]; then
    asset="sdsc-bot-${version}.tar.gz"
    digest="$(asset_digest "$asset")"
    [[ -n "$digest" ]] || die "release ${tag} has no ${arch} bundle"
    log "no arch-suffixed bundle; falling back to legacy ${asset}"
  fi

  log "fetching ${tag} (${asset})"
  curl -fsSL -o "${WORK}/${asset}" "${base}/${asset}" || die "failed to download ${asset}"

  log "verifying against GitHub's digest"
  printf '%s  %s\n' "$digest" "$asset" > "${WORK}/expected.sha256"
  (cd "$WORK" && sha256sum -c expected.sha256)

  log "staging extract"
  mkdir -p "${WORK}/stage"
  tar xzf "${WORK}/${asset}" -C "${WORK}/stage"
  [[ -x "${WORK}/stage/bin/main" ]] || die "bundle has no bin/main"

  # confirm the binary matches this machine
  local got
  got=$(file -b "${WORK}/stage/bin/main")
  case "$got" in
    *"x86-64"*)  [[ "$arch" = "amd64" ]] || die "binary arch mismatch: $got (expected $arch)" ;;
    *"aarch64"*) [[ "$arch" = "arm64" ]] || die "binary arch mismatch: $got (expected $arch)" ;;
  esac

  # keep the current install as a rollback point
  rm -rf "$BACKUP_DIR"
  if [[ -d "$INSTALL_DIR" ]]; then
    mv "$INSTALL_DIR" "$BACKUP_DIR"
  fi
  mv "${WORK}/stage" "$INSTALL_DIR"
  chown -R root:root "$INSTALL_DIR"

  # pick the service name: explicit override, or the one that exists locally
  if [[ -z "${SERVICE:-}" ]]; then
    if [[ -f /etc/systemd/system/bot.service ]]; then
      SERVICE=bot
    else
      SERVICE=sdsc-bot
    fi
  fi

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
