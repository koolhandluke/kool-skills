# eks-upgrade

Semi-automated assistant for in-place Amazon EKS minor-version upgrades (1.32 → 1.33 → …).

**Claude discovers, analyzes, drafts, watches and verifies. A human runs every mutation.**

## What it does

| Mode | Claude does (read-only) | Output |
|---|---|---|
| `preflight` | CP/node skew, AL2 node groups, add-on compatibility on target, VPC CNI ≥ 1.16.2, subnet free IPs, upgrade insights, IMDS hop limits, fail-closed webhooks, blocking PDBs, Fargate, kubectl skew | `summary.json` + `preflight-report.md` with READY / NOT READY verdict |
| `scan` | Greps IaC/Helm/Flux/pipeline templates for `kubeProxyVersion`, AL2 AMI types & `bootstrap.sh`, removed `flowcontrol` APIs, `Endpoints` consumers, autoscaler pins, cgroup v1 assumptions | Findings grouped by severity + proposed diffs |
| `plan` | Ordered change windows with exact human-run commands, gates, stop criteria, rollback | `change-plan.md` |
| `watch` | Polls `describe-update` + API `/readyz` during CP / node group / add-on updates | Status transitions, API availability |
| `verify` | Nodes, CoreDNS endpoints, CrashLoops, DaemonSets, PVC/attach errors, webhook backends, Flux readiness, critical namespaces, optional Prometheus metrics, diff vs baseline | `verify-<ts>.json` |
| `rollback-check` / `rollback-plan` | 7-day window, `ROLLBACK_READINESS` insights, ordered rollback commands | Report / commands |

Change windows are kept separate: OS migration (AL2 → AL2023) on the current version, pre-upgrade
add-on bumps, control plane, nodes, post-upgrade add-ons/autoscaler, clients.

## Installation

```sh
claude plugin marketplace add koolhandluke/kool-skills
claude plugin install eks-upgrade
```

Requires `aws`, `kubectl`, `jq` (optional: `helm`, `curl` for metrics).

## Guardrails (recommended)

1. Run Claude with a **read-only** IAM role and a kube context bound to `view` (+ CRD read).
2. Install the hook in the repo where you run upgrades (`.claude/settings.json`):

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash",    "hooks": [{ "type": "command", "command": "<plugin-path>/skills/upgrade/hooks/deny-mutations.sh" }] },
      { "matcher": "mcp__.*", "hooks": [{ "type": "command", "command": "<plugin-path>/skills/upgrade/hooks/deny-mutations.sh" }] }
    ]
  }
}
```

It blocks `aws eks update-*/create-*/delete-*`, `eksctl upgrade|drain…`, mutating `kubectl`/`helm`/`terraform`/`flux`
verbs, mutating Kubernetes MCP tools, and `verify.sh --active`. Text matching is best-effort; IAM/RBAC is the real boundary.

3. Fill `skills/upgrade/config.yaml`: `owner`, `critical_namespaces`, `stop_criteria`, optional metrics.

## Usage

```
/eks-upgrade:upgrade preflight my-cluster 1.33
/eks-upgrade:upgrade scan ./infra ./charts ./spinnaker-templates
/eks-upgrade:upgrade plan my-cluster 1.33
/eks-upgrade:upgrade watch my-cluster --update-id <id>
/eks-upgrade:upgrade verify my-cluster --baseline eks-upgrade-runs/my-cluster/<ts>/verify-<ts>.json
/eks-upgrade:upgrade rollback-check my-cluster
```

Typical flow: baseline `verify` → `preflight` + `scan` → fix blockers (PRs) → `plan` → rehearse in nonprod
(including a rollback) → production, with `watch` + `verify` after every human-run step.

Scripts also run standalone, e.g.:

```sh
skills/upgrade/scripts/preflight.sh --cluster my-cluster --region us-west-2 --target 1.33
skills/upgrade/scripts/verify.sh --namespaces kube-system,spinnaker --baseline <file>
```

## Notes

- Version facts in `references/` were verified 2026-10-16. The skill re-checks lifecycle, add-on versions
  and insights live; don't treat the reference files as current.
- "Pods Ready" is not success: verify PASS + baseline within thresholds + human-run e2e smoke.
