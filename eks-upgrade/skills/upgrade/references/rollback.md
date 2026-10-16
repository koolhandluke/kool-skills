# EKS version rollback (verified 2026-10-16)

Source: https://docs.aws.amazon.com/eks/latest/userguide/rollback-cluster.html

## Preconditions (all required)

- Within **7 days** of the in-place upgrade completing.
- Cluster was **upgraded in place** (clusters created at the current version can't roll back).
- **One minor only** (N → N-1), and N-1 is currently supported.
- Rolling back to an extended-support version → set `upgradePolicy.supportType=EXTENDED` first.
- Not auto-upgraded at end of extended support. (Auto-upgraded at end of *standard* support: allowed
  only after setting policy to EXTENDED.)
- Status `ACTIVE`, no other update in progress.
- Enabled EKS features supported on N-1 (cannot be bypassed with `--force`).
- Another upgrade after the one you want to undo closes the window.

## Readiness check (read-only, Claude can run)

```sh
aws eks list-insights --cluster-name <c> --region <r> --filter '{"categories":["ROLLBACK_READINESS"]}'
aws eks describe-insight --cluster-name <c> --region <r> --id <insight-id>
```

`aws eks start-insights-refresh` triggers a refresh; it is blocked by the guardrail hook — ask the human.

## Order (human-run)

1. **Auto Mode nodes:** automatic (EKS rolls them back before the CP).
2. **Managed node groups:** before the CP.
   ```sh
   aws eks update-nodegroup-version --cluster-name <c> --nodegroup-name <ng> --kubernetes-version <N-1> --region <r>
   ```
3. **Self-managed / hybrid nodes:** move AMIs/config to N-1 before the CP.
4. **Fargate:** no version rollback; delete Fargate pods running at N before the CP rollback, else the
   kubelet-skew insight shows ERROR.
5. **Control plane:**
   ```sh
   aws eks update-cluster-version --name <c> --kubernetes-version <N-1> --region <r>
   aws eks describe-update --name <c> --region <r> --update-id <id>
   ```
6. **Add-ons:** reconcile to versions valid on N-1:
   ```sh
   aws eks update-addon --cluster-name <c> --addon-name <a> --addon-version <ver> --region <r>
   ```

## `--force`

Bypasses insight checks (ERROR/WARNING/UNKNOWN) only. Does not bypass the 7-day window, creation-version
check, N-1 rule, or feature compatibility. On Auto Mode it does not override PDBs or NodePool budgets.
Never a first resort: resolve the insight instead.

## What rollback is not

Not a data restore. etcd contents, workloads, PVs and add-on versions remain. Objects written with
APIs/fields new in N may need manual cleanup.
