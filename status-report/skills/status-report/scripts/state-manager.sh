#!/usr/bin/env bash
set -euo pipefail

# Manages the last-run state for status-report.
#
# Usage:
#   ./state-manager.sh read [--lookback-hours <N>]
#   ./state-manager.sh write

STATE_FILE="${HOME}/.claude/skills/status-report/state/last-report.json"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <read|write> [--lookback-hours <N>]" >&2
  exit 1
fi

SUBCOMMAND="$1"
shift

case "$SUBCOMMAND" in
  read)
    LOOKBACK_HOURS=24

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --lookback-hours) LOOKBACK_HOURS="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
      esac
    done

    if [[ -f "$STATE_FILE" ]]; then
      last_run=$(jq -r '.last_run // empty' "$STATE_FILE" 2>/dev/null) || true
      if [[ -n "$last_run" ]]; then
        echo "$last_run"
        exit 0
      fi
    fi

    # Fallback: now minus lookback_hours (macOS date syntax)
    date -u -v"-${LOOKBACK_HOURS}H" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
      date -u -d "${LOOKBACK_HOURS} hours ago" +"%Y-%m-%dT%H:%M:%SZ"
    ;;

  write)
    mkdir -p "$(dirname "$STATE_FILE")"
    NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "{\"last_run\": \"${NOW}\"}" > "$STATE_FILE"
    echo "State written: ${NOW}"
    ;;

  *)
    echo "Unknown subcommand: $SUBCOMMAND. Use 'read' or 'write'." >&2
    exit 1
    ;;
esac
