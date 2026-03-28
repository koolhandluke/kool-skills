#!/usr/bin/env bash
set -euo pipefail

# Collects Claude Code session activity since a given timestamp.
# Reads ~/.claude/projects/ and reports on sessions newer than --since.
#
# Usage:
#   ./collect-claude.sh --since <ISO8601>
#
# Output:
#   JSON array to stdout: [{ "summary", "files_count", "project" }]

SINCE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$SINCE" ]]; then
  echo "Usage: $0 --since <ISO8601>" >&2
  exit 1
fi

PROJECTS_DIR="${HOME}/.claude/projects"

if [[ ! -d "$PROJECTS_DIR" ]]; then
  echo "[]"
  exit 0
fi

# Convert since timestamp to epoch seconds for comparison
SINCE_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$SINCE" "+%s" 2>/dev/null) || \
  SINCE_EPOCH=$(date -d "$SINCE" "+%s" 2>/dev/null) || {
    echo "Warning: could not parse --since timestamp, returning empty." >&2
    echo "[]"
    exit 0
  }

RESULTS="[]"

for project_dir in "$PROJECTS_DIR"/*/; do
  [[ -d "$project_dir" ]] || continue
  project_name=$(basename "$project_dir")

  for session_file in "$project_dir"*.jsonl; do
    [[ -f "$session_file" ]] || continue

    # Get file modification time as epoch
    file_epoch=$(stat -f "%m" "$session_file" 2>/dev/null) || \
      file_epoch=$(stat -c "%Y" "$session_file" 2>/dev/null) || continue

    # Skip files older than --since
    [[ "$file_epoch" -gt "$SINCE_EPOCH" ]] || continue

    # Count lines as approximate message count
    line_count=$(wc -l < "$session_file" | tr -d ' ')

    entry=$(jq -n \
      --arg summary "Session with ${line_count} messages" \
      --argjson files_count "$line_count" \
      --arg project "$project_name" \
      '{ summary: $summary, files_count: $files_count, project: $project }')

    RESULTS=$(jq -n --argjson arr "$RESULTS" --argjson item "$entry" '$arr + [$item]')
  done
done

echo "$RESULTS"
