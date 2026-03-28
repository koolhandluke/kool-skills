#!/usr/bin/env bash
set -euo pipefail

# Collects Jira issues updated since a given timestamp for the current user.
#
# Usage:
#   ./collect-jira.sh --since <ISO8601> --email <email> --token <token> --base-url <url>
#
# Output:
#   JSON array to stdout: [{ "ticket_id", "summary", "status", "url" }]

SINCE=""
EMAIL=""
TOKEN=""
BASE_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)    SINCE="$2";    shift 2 ;;
    --email)    EMAIL="$2";    shift 2 ;;
    --token)    TOKEN="$2";    shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$SINCE" || -z "$EMAIL" || -z "$TOKEN" || -z "$BASE_URL" ]]; then
  echo "Usage: $0 --since <ISO8601> --email <email> --token <token> --base-url <url>" >&2
  exit 1
fi

AUTH=$(printf '%s:%s' "$EMAIL" "$TOKEN" | base64)

JQL="assignee = currentUser() AND updatedDate > \"${SINCE}\" ORDER BY updated DESC"
MAX_RESULTS=50
START_AT=0
RESULTS="[]"

while true; do
  ENCODED_JQL=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$JQL")
  URL="${BASE_URL}/rest/api/3/search?jql=${ENCODED_JQL}&maxResults=${MAX_RESULTS}&startAt=${START_AT}&fields=summary,status"

  RESPONSE=$(curl --silent --fail \
    -H "Authorization: Basic ${AUTH}" \
    -H "Accept: application/json" \
    "$URL" 2>/dev/null) || { echo "[]"; exit 0; }

  PAGE=$(echo "$RESPONSE" | jq --arg base_url "$BASE_URL" '[.issues[] | {
    ticket_id: .key,
    summary:   .fields.summary,
    status:    .fields.status.name,
    url:       ($base_url + "/browse/" + .key)
  }]') || { echo "[]"; exit 0; }

  RESULTS=$(echo "$RESULTS $PAGE" | jq -s 'add')

  TOTAL=$(echo "$RESPONSE" | jq '.total')
  START_AT=$(( START_AT + MAX_RESULTS ))

  if [[ $START_AT -ge $TOTAL ]]; then
    break
  fi
done

echo "$RESULTS"
