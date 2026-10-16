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

## Window 2 — OS migration on {{CURRENT}} (only if AL2 node groups)
{{OS_STEPS}}
- Canary: cordon + drain one AL2 node; Claude verifies DNS, webhooks, PVC reattach, Flux, creds during drain
- Gate: verify PASS + active probes + e2e smoke PASS before shifting remaining capacity; retire AL2 last

## Window 3 — Pre-upgrade add-ons / controllers (valid on both {{CURRENT}} and {{TARGET}})
{{ADDON_PRE_STEPS}}
- Gate: verify PASS

## Window 4 — Control plane
```sh
aws eks update-cluster-version --name {{CLUSTER}} --kubernetes-version {{TARGET}} --region {{REGION}}
```
- [ ] Claude: `scripts/watch-update.sh --cluster {{CLUSTER}} --region {{REGION}} --update-id <id> --context {{CTX}}`
- [ ] Claude: verify vs baseline; check API client reconnects (Spinnaker, Flux, CI)
- Gate: verify PASS, no stop criteria hit

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

## Rollback (if stop criteria hit, within 7 days)
{{ROLLBACK_STEPS}}
(Order: node groups → self-managed/hybrid → Fargate pods → control plane → add-ons. Not a data restore.)
