# EKS Upgrade Change Plan — {{CLUSTER}} {{CURRENT}} → {{TARGET}}

| | |
|---|---|
| Ticket | {{TICKET}} |
| Owner (stop / drain / rollback authority) | {{OWNER}} |
| Preflight | `{{PREFLIGHT_DIR}}` — {{VERDICT}} |
| Baseline snapshot | `{{BASELINE_FILE}}` |
| Rollback window | 7 days after step 4 completes; closes if another upgrade runs |
| Next hop | {{NEXT_HOP}} (re-check lifecycle dates) |

## Stop criteria (any hit → STOP, owner decides rollback)

{{STOP_CRITERIA}}

---

Every command below is **run by a human**. Claude watches and verifies after each step.

## Window 0 — Baseline
- [ ] Claude: `scripts/verify.sh --context {{CTX}} --namespaces {{NAMESPACES}} --out {{RUN_DIR}}` → baseline file
- [ ] Human: `scripts/verify.sh --active ...` (DNS + pod credentials) and e2e smoke: {{E2E_SMOKE}}

## Window 1 — Node/kubelet skew (only if preflight node-skew BLOCK)
{{SKEW_STEPS}}
- Gate: `verify.sh --baseline` PASS

## Backup gate (before Windows 2 and 4)
- [ ] Human: `aws backup start-backup-job --backup-vault-name {{VAULT}} --resource-arn {{CLUSTER_ARN}} --iam-role-arn <role>` + same-time snapshots of {{EXTERNAL_STORES}}
- [ ] Claude: `scripts/backup-check.sh --cluster {{CLUSTER}} --region {{REGION}} --max-age-hours {{BACKUP_MAX_AGE}}` → no BLOCK
- Restore test for this cluster last passed: {{LAST_RESTORE_TEST}} (see restore-test-runbook.md)

## Window 2 — OS migration on {{CURRENT}} (only if AL2 node groups)
{{OS_STEPS}}
- Canary: cordon + drain one AL2 node; Claude verifies DNS, webhooks, PVC reattach, Flux, creds during drain
- Gate: verify PASS + active probes + e2e smoke PASS before shifting remaining capacity; retire AL2 last

## Window 3 — Pre-upgrade add-ons / controllers (valid on both {{CURRENT}} and {{TARGET}})
{{ADDON_PRE_STEPS}}
- Gate: verify PASS

## Window 4 — Control plane (backup gate first)
```sh
aws eks update-cluster-version --name {{CLUSTER}} --kubernetes-version {{TARGET}} --region {{REGION}}
```
- [ ] Claude: `scripts/watch-update.sh --cluster {{CLUSTER}} --region {{REGION}} --update-id <id> --context {{CTX}}`
- [ ] Claude: verify vs baseline; check API client reconnects (Spinnaker, Flux, CI)
- Gate: verify PASS, no stop criteria hit

## Soak — {{SOAK_HOURS}}h, nodes stay at {{CURRENT}}
- Nodes at N-1 keep a CP rollback single-step (no node rollback first)
- [ ] Claude: verify vs baseline at start, midpoint, end
- Gate: no stop criteria hit for the full soak; owner sign-off to proceed

## Window 5 — Data plane
{{NODE_STEPS}}
- [ ] Claude: watch each node group update; verify after each
- Gate: verify PASS, kubelet all at {{TARGET}}

## Window 6 — Autoscaler, add-ons, controllers to target
{{ADDON_POST_STEPS}}
- Cluster Autoscaler → {{CA_VERSION}}
- Gate: verify PASS

## Window 7 — Clients
- kubectl / CI runner images within ±1 of {{TARGET}}: {{CLIENT_STEPS}}

## Window 8 — Acceptance
- [ ] Human: verify `--active` + e2e smoke PASS
- [ ] Claude: final report vs baseline
- [ ] Owner sign-off

## Escalation ladder (owner decides each step)
1. Auto-revert (CP failed EKS health checks) → already on {{CURRENT}}; investigate, retry
2. Fix forward (pin/roll back add-on or chart, patch manifest)
3. Shift back to retained old node group
4. Version rollback (≤ 7 days):
{{ROLLBACK_STEPS}}
   (Order: node groups → self-managed/hybrid → Fargate pods → control plane → add-ons. Not a data restore.)
5. Targeted restore (namespace / storage): delete damaged objects first; restore is non-destructive
6. Full restore to new cluster or GitOps rebuild + data restore, then cut over
