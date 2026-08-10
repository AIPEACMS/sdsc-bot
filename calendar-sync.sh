#!/usr/bin/env bash
# Fetch the NTU academic calendar YAML and push it into the running bot via
# its loopback IPC endpoint. Meant to run yearly (e.g. every Aug 1).
#
# If the year's calendar is not published yet, it fails silently — the bot
# keeps its current calendar and this script retries next year.
#
# Requires: curl, the CALENDAR_IPC_TOKEN secret (same env file as the bot's),
# and the bot running with the IPC listener enabled.
#
# Usage:
#   CALENDAR_IPC_TOKEN=... ./calendar-sync.sh            # AY of the current year
#   CALENDAR_IPC_TOKEN=... ./calendar-sync.sh 2027-28    # explicit AY
#
# Crontab (runs every Aug 1 at 06:00):
#   0 6 1 8 * /usr/local/bin/calendar-sync.sh >> /var/log/sdsc-calendar-sync.log 2>&1

set -euo pipefail

REPO="AIPEACMS/parse-ntu-calander"
IPC_HOST="127.0.0.1"
IPC_PORT="${CALENDAR_IPC_PORT:-8737}"
TOKEN="${CALENDAR_IPC_TOKEN:-}"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

# Academic year starting this August: e.g. Aug 2026 -> 2026-27.
academic_year_of() {
  local y
  y=$(date +%Y)
  if [[ "$(date +%m)" -lt 8 ]]; then
    y=$((y - 1))
  fi
  printf '%d-%02d\n' "$y" $(((y + 1) % 100))
}

main() {
  [[ -n "$TOKEN" ]] || { log "CALENDAR_IPC_TOKEN not set; skipping"; exit 0; }

  local ay="${1:-$(academic_year_of)}"
  local url="https://raw.githubusercontent.com/${REPO}/main/output/ay${ay}.yaml"
  local work
  work="$(mktemp -d /tmp/sdsc-cal.XXXXXX)"

  log "fetching ${url}"
  if ! curl -fsSL --max-time 60 -o "${work}/calendar.yaml" "$url" 2>/dev/null; then
    log "calendar ${ay} not available yet; silent fail"
    rm -rf "$work"
    exit 0
  fi
  [[ -s "${work}/calendar.yaml" ]] || { log "empty payload; skip"; rm -rf "$work"; exit 0; }

  log "pushing via IPC 127.0.0.1:${IPC_PORT}"
  # Protocol: "TOKEN <token>\nLEN <byteCount>\n<yaml>" then read the reply.
  local len
  len="$(wc -c < "${work}/calendar.yaml")"
  local response
  response="$(
    {
      printf 'TOKEN %s\n' "$TOKEN"
      printf 'LEN %s\n' "$len"
      cat "${work}/calendar.yaml"
    } | timeout 20 bash -c "exec 3<>/dev/tcp/${IPC_HOST}/${IPC_PORT}; cat >&3; IFS= read -r line <&3; printf '%s' \"\$line\""
  )"

  case "$response" in
    OK*)
      log "calendar sync OK: ${response#OK }"
      ;;
    ERR*)
      log "calendar sync error: ${response#ERR }"
      rm -rf "$work"
      exit 1
      ;;
    *)
      log "no/odd IPC response ('${response}'); treating as failure"
      rm -rf "$work"
      exit 1
      ;;
  esac

  rm -rf "$work"
}

main "$@"
