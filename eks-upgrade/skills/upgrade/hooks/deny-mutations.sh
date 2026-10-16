#!/usr/bin/env bash
# Claude Code PreToolUse hook: block cluster/account mutations so Claude stays read-only.
# Install in the repo where you run upgrades (.claude/settings.json):
#
#   {"hooks":{"PreToolUse":[
#     {"matcher":"Bash","hooks":[{"type":"command","command":"<path>/deny-mutations.sh"}]},
#     {"matcher":"mcp__.*","hooks":[{"type":"command","command":"<path>/deny-mutations.sh"}]}
#   ]}}
#
# Exit 2 = block (stderr is shown to Claude). Exit 0 = allow.
# Text matching is best-effort: a wrapper script that mutates internally is not caught,
# so verify.sh --active is blocked explicitly. Pair this with a read-only IAM role / RBAC.

input=$(cat)
tool=$(jq -r '.tool_name // ""' <<<"$input")
cmd=$(jq -r '.tool_input.command // ""' <<<"$input")

block() { echo "BLOCKED by eks-upgrade guardrail: $1. Write the command into the change plan for a human to run." >&2; exit 2; }

# Mutating MCP tools (Kubernetes / Helm MCP servers)
if [[ "$tool" == mcp__* ]]; then
  if [[ "$tool" =~ (kubectl_(apply|create|delete|patch|scale|rollout|generic)|exec_in_pod|node_management|(install|upgrade|uninstall)_helm_chart|port_forward) ]]; then
    block "mutating MCP tool $tool"
  fi
  exit 0
fi

[[ "$tool" != "Bash" ]] && exit 0

shopt -s nocasematch
patterns=(
  'aws[[:space:]].*eks[[:space:]]+(update-|create-|delete-|associate-|disassociate-|tag-|untag-|register-|deregister-|start-insights-refresh)'
  'aws[[:space:]].*(ec2|autoscaling)[[:space:]]+(create-|delete-|modify-|terminate-|run-instances|update-|set-|attach-|detach-)'
  'eksctl[[:space:]]+(upgrade|create|delete|drain|scale|update|set|unset|enable|disable)'
  'kubectl([[:space:]].*)?[[:space:]](apply|create|delete|replace|patch|edit|scale|drain|cordon|uncordon|taint|label|annotate|set|run|expose|autoscale|debug|exec|cp)([[:space:]]|$)'
  'kubectl([[:space:]].*)?[[:space:]]rollout[[:space:]]+(restart|undo|pause|resume)'
  'helm([[:space:]].*)?[[:space:]](install|upgrade|uninstall|delete|rollback)([[:space:]]|$)'
  'terraform([[:space:]].*)?[[:space:]](apply|destroy|import|taint|untaint|state[[:space:]]+(rm|mv|push))([[:space:]]|$)'
  'flux[[:space:]]+(suspend|resume|delete|create|bootstrap|uninstall)'
  'verify\.sh.*--active'
)
for p in "${patterns[@]}"; do
  [[ "$cmd" =~ $p ]] && block "matched /$p/"
done
exit 0
