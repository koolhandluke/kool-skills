#!/usr/bin/env bash
set -uo pipefail

# Read-only watcher for an EKS update (cluster version, node group, or add-on).
# Also probes API server /readyz each poll to record availability during the update.
#
# Usage:
#   ./watch-update.sh --cluster <name> --update-id <id> [--region <r>]
#                     [--nodegroup <ng> | --addon <addon>] [--context <kube-ctx>]
#                     [--interval <sec, default 30>] [--log <file>]
#
# Output:
#   NDJSON lines to stdout (and --log): {ts, status, apiReady, errors}
# Exit: 0 Successful, 1 Failed/Cancelled, 3 usage error

CLUSTER="" ID="" REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}" NG="" ADDON="" CONTEXT="" INTERVAL=30 LOG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)   CLUSTER="$2"; shift 2 ;;
    --update-id) ID="$2"; shift 2 ;;
    --region)    REGION="$2"; shift 2 ;;
    --nodegroup) NG="$2"; shift 2 ;;
    --addon)     ADDON="$2"; shift 2 ;;
    --context)   CONTEXT="$2"; shift 2 ;;
    --interval)  INTERVAL="$2"; shift 2 ;;
    --log)       LOG="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 3 ;;
  esac
done
[[ -z "$CLUSTER" || -z "$ID" || -z "$REGION" ]] && { echo "Usage: $0 --cluster <c> --update-id <id> --region <r> [--nodegroup ng|--addon a]" >&2; exit 3; }

ARGS=(--region "$REGION" --output json eks describe-update --name "$CLUSTER" --update-id "$ID")
[[ -n "$NG" ]] && ARGS+=(--nodegroup-name "$NG")
[[ -n "$ADDON" ]] && ARGS+=(--addon-name "$ADDON")
KUBECTL=(kubectl); [[ -n "$CONTEXT" ]] && KUBECTL+=(--context "$CONTEXT")

last=""; apifail=0; polls=0
while true; do
  ts=$(date -u +%FT%TZ)
  u=$(aws "${ARGS[@]}" 2>&1) || u='{"update":{"status":"PollError","errors":[{"errorMessage":"describe-update failed"}]}}'
  status=$(jq -r '.update.status' <<<"$u" 2>/dev/null || echo PollError)
  if "${KUBECTL[@]}" get --raw='/readyz' --request-timeout=5s >/dev/null 2>&1; then api=true; else api=false; ((apifail++)); fi
  ((polls++))
  line=$(jq -nc --arg ts "$ts" --arg s "$status" --argjson a "$api" --argjson e "$(jq -c '.update.errors // []' <<<"$u" 2>/dev/null || echo '[]')" \
         '{ts:$ts,status:$s,apiReady:$a,errors:$e}')
  if [[ "$status" != "$last" || "$api" == "false" ]]; then
    echo "$line"; [[ -n "$LOG" ]] && echo "$line" >> "$LOG"
  fi
  last="$status"
  case "$status" in
    Successful) echo "{\"final\":\"Successful\",\"polls\":$polls,\"apiReadyFailures\":$apifail}"; exit 0 ;;
    Failed|Cancelled) echo "{\"final\":\"$status\",\"polls\":$polls,\"apiReadyFailures\":$apifail}"; exit 1 ;;
  esac
  sleep "$INTERVAL"
done
