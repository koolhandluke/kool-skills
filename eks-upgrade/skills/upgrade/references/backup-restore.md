# AWS Backup for EKS (verified 2026-10-16)

Sources:
- https://docs.aws.amazon.com/eks/latest/userguide/integration-backup.html
- https://docs.aws.amazon.com/aws-backup/latest/devguide/restoring-eks.html
- https://aws.amazon.com/about-aws/whats-new/2025/11/aws-backup-supports-amazon-eks

Not verified: availability in AWS GovCloud; cross-account copy of EKS composite recovery points.
Check both before relying on them for FedRAMP clusters. Velero is the fallback.

## What it captures

One **composite recovery point**: Kubernetes cluster state + persistent storage attached through PVCs
(EBS, EFS, S3), each as a child recovery point.

Not covered: anything outside PVCs (RDS, ElastiCache, Spinnaker storage in external S3/SQL/Redis).
Snapshot those at the same time so the cluster and its stores agree on a point in time.

## Prerequisites

- Cluster `authenticationMode` = `API` or `API_AND_CONFIG_MAP` (AWS Backup uses access entries).
- Backup role with `AWSBackupServiceRolePolicyForBackup` (+ `AWSBackupServiceRolePolicyForS3Backup` for S3).
- SNS notifications on the vault: restore jobs can report COMPLETED with skipped/failed objects.

## Commands

Read-only (Claude):
```sh
aws backup list-recovery-points-by-resource --resource-arn <cluster-arn>
aws backup list-recovery-points-by-backup-vault --backup-vault-name <v> --by-parent-recovery-point-arn <composite-arn>
aws backup describe-restore-job --restore-job-id <id>
```

Mutating (human):
```sh
aws backup start-backup-job --backup-vault-name <v> --resource-arn <cluster-arn> --iam-role-arn <role>
aws backup start-restore-job --resource-type EKS --recovery-point-arn <composite-arn> --iam-role-arn <role> \
  --metadata '{"clusterName":"<target>","newCluster":"false"}'
# namespace-level (max 5):
#   --metadata '{"clusterName":"<c>","newCluster":"false","namespaceLevelRestore":"true","namespaces":"[\"ns1\"]"}'
# manifests only: add "restoreKubernetesManifestsOnly":"true"
```

## Restore semantics

| Behavior | Consequence |
|---|---|
| Non-destructive: existing objects skipped | To revert a corrupted object, delete it first, then restore |
| Does not change the target cluster's version | Version rollback ≠ restore |
| New-cluster restore creates node groups first | Pods start immediately; prod automation (Flux, Spinnaker) goes live in the clone. Prefer restoring into a pre-created, tainted cluster |
| Cross-version restore is best-effort | Restore at the same version as the backup when possible |
| IRSA annotations / trust policies not rewritten | Pods may fail to assume roles cross-cluster (Pod Identity is portable) |
| EFS restores to random prefixes; no access points/mount targets | Recreate manually |
| CSI drivers must exist before restore into an existing cluster | Install EBS/EFS CSI add-ons first |
| Skipped always: Endpoints, EndpointSlices, IPAddresses, CSINodes, VolumeAttachments | Recreated by Kubernetes |
| Default order: CRDs → Namespaces → StorageClasses → PVs → PVCs → Secrets → ConfigMaps → SAs → … | Override with `kubernetesRestoreOrder` |
| Data written after the backup is lost | Take the backup immediately before each change window |

## When to restore (escalation ladder)

Restore is the last resort. In order:

1. **Auto-revert**: CP upgrade failed EKS health checks → cluster already back on N-1. Investigate, retry.
2. **Fix forward**: pin/roll back an add-on or chart, patch a manifest.
3. **Shift back nodes**: cordon new nodes, move back to the retained old node group.
4. **Version rollback** (≤ 7 days): see rollback.md. Not a data restore.
5. **Targeted restore**: namespace-level or storage-only, for damaged state (CRs rewritten, objects deleted, PV corrupted). Delete damaged objects first.
6. **Full restore / rebuild**: new cluster from backup (or GitOps rebuild + data restore), then cut traffic over.

The owner in config.yaml decides each escalation, triggered by stop criteria.
