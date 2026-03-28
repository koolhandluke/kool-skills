#!/usr/bin/env bash
set -euo pipefail

# Collects GitHub activity (authored PRs, PR reviews, commits) for a user
# within an org since a given ISO8601 date.
#
# Usage:
#   ./collect-github.sh --since <ISO8601> --org <org> --username <username>
#
# Output:
#   JSON array to stdout:
#   [{ "type": "pr_authored|pr_review|commit", "repo": "...",
#      "title": "...", "url": "...", "jira_refs": ["PROJ-123"] }]

SINCE=""
ORG=""
USERNAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)    SINCE="$2";    shift 2 ;;
    --org)      ORG="$2";      shift 2 ;;
    --username) USERNAME="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$SINCE" || -z "$ORG" || -z "$USERNAME" ]]; then
  echo "Usage: $0 --since <ISO8601> --org <org> --username <username>" >&2
  exit 1
fi

# 1. PRs authored
prs_authored="[]"
if authored_raw=$(gh pr list \
      --author "$USERNAME" \
      --search "org:${ORG} created:>=${SINCE}" \
      --json number,title,url,repository \
      --limit 50 2>/dev/null); then
  prs_authored=$(echo "$authored_raw" | jq --arg type "pr_authored" '
    [ .[] | {
        type: $type,
        repo: .repository.nameWithOwner,
        title: .title,
        url:   .url,
        jira_refs: ((.title | [ scan("[A-Z]+-[0-9]+") ]) | unique)
    }]
  ')
else
  echo "Warning: failed to fetch authored PRs, skipping." >&2
fi

# 2. PR reviews
prs_reviewed="[]"
if reviewed_raw=$(gh pr list \
      --search "org:${ORG} reviewed-by:${USERNAME} updated:>=${SINCE}" \
      --json number,title,url,repository \
      --limit 50 2>/dev/null); then
  prs_reviewed=$(echo "$reviewed_raw" | jq --arg type "pr_review" '
    [ .[] | {
        type: $type,
        repo: .repository.nameWithOwner,
        title: .title,
        url:   .url,
        jira_refs: ((.title | [ scan("[A-Z]+-[0-9]+") ]) | unique)
    }]
  ')
else
  echo "Warning: failed to fetch reviewed PRs, skipping." >&2
fi

# 3. Recent commits (cap at 20 repos to avoid rate limits)
commits="[]"
repos=()

if repo_list=$(gh api "/orgs/${ORG}/repos" \
      --paginate \
      --jq '.[].full_name' 2>/dev/null); then
  while IFS= read -r repo; do
    repos+=("$repo")
    [[ ${#repos[@]} -ge 20 ]] && break
  done <<< "$repo_list"
else
  echo "Warning: failed to list org repos, skipping commits." >&2
fi

for repo in "${repos[@]+"${repos[@]}"}"; do
  repo_commits_raw=$(gh api \
      "/repos/${repo}/commits" \
      --field "author=${USERNAME}" \
      --field "since=${SINCE}" \
      --jq '.[] | {sha: .sha, message: .commit.message, url: .html_url}' \
      2>/dev/null) || {
    echo "Warning: failed to fetch commits for ${repo}, skipping." >&2
    continue
  }

  [[ -z "$repo_commits_raw" ]] && continue

  repo_commits=$(echo "$repo_commits_raw" | jq -s \
      --arg type "commit" \
      --arg repo "$repo" '
    [ .[] | {
        type: $type,
        repo: $repo,
        title: (.message | split("\n")[0]),
        url:   .url,
        jira_refs: ((.message | [ scan("[A-Z]+-[0-9]+") ]) | unique)
    }]
  ')

  commits=$(jq -n --argjson a "$commits" --argjson b "$repo_commits" '$a + $b')
done

# Merge and deduplicate by url
jq -n \
  --argjson authored "$prs_authored" \
  --argjson reviewed "$prs_reviewed" \
  --argjson commits  "$commits" \
  '($authored + $reviewed + $commits) | unique_by(.url)'
