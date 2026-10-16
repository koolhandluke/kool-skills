# Restore Test — {{SOURCE}} → {{TARGET}} ({{REGION}})

| | |
|---|---|
| Owner | {{OWNER}} |
| Authorization boundary | {{BOUNDARY}} (target MUST be inside the same boundary as the source) |
| Run directory | `{{RUN_DIR}}` |
| Purpose | Prove backup → restore works; measure RTO/RPO; optionally rehearse the upgrade on the clone |

Human runs every mutating step. Claude runs the read-only gates and verification.

## 1. Prep (human)
- [ ] Source auth mode API / API_AND_CONFIG_MAP (`backup-check`)
- [ ] Target cluster `{{TARGET}}` created: version {{VERSION}}, isolated VPC (no peering/TGW to prod; VPC endpoints for ECR/S3/STS), restricted node role
- [ ] Every target node group tainted `{{TAINT}}=true:NoSchedule`; no Fargate profiles
- [ ] EBS/EFS CSI add-ons installed on target
- [ ] SNS notifications configured on the vault

## 2. Backup (human) → gate (Claude)
- [ ] `aws backup start-backup-job --backup-vault-name {{VAULT}} --resource-arn {{SOURCE_ARN}} --iam-role-arn <role>`
- [ ] Same-time snapshots of external stores: {{EXTERNAL_STORES}}
- [ ] Record backup time (RPO marker): ______
- [ ] Claude: `scripts/backup-check.sh --cluster {{SOURCE}} --region {{REGION}} --max-age-hours 2` → PASS

## 3. Isolation gate (Claude)
- [ ] `scripts/restore-test-check.sh --phase pre --source {{SOURCE}} --target {{TARGET}} --region {{REGION}} --taint-key {{TAINT}}` → no BLOCK

## 4. Restore (human) → watch (Claude)
- [ ] `aws backup start-restore-job --resource-type EKS --recovery-point-arn <composite-arn> --iam-role-arn <role> --metadata '{"clusterName":"{{TARGET}}","newCluster":"false"}'`
- [ ] Start time: ______
- [ ] Claude: `scripts/restore-test-check.sh --phase job --restore-job-id <id>` until terminal
- [ ] Human: read SNS for skipped/failed objects; record count

## 5. Defuse (human) → gate (Claude)
- [ ] Scale to 0: {{DEPLOYER_NAMESPACES}} (Flux controllers, Spinnaker, other deployers/operators)
- [ ] Suspend Flux Kustomizations/HelmReleases
- [ ] Review restored Pod Identity associations and Secrets holding prod credentials; remove/rotate
- [ ] Claude: `scripts/restore-test-check.sh --phase defused --target {{TARGET}} --target-context {{TARGET_CTX}}` → no BLOCK

## 6. Bring up (human) → verify (Claude)
- [ ] Remove taint from target node groups
- [ ] Claude: `scripts/verify.sh --context {{TARGET_CTX}} --namespaces <critical> --out {{RUN_DIR}}`
- [ ] App data checks: {{DATA_CHECKS}}
- [ ] Manual fixes needed (EFS access points, IRSA trust, CSI, other): ______

## 7. Results
| Metric | Value |
|---|---|
| RTO (restore start → verify PASS) | |
| RPO (backup time → newest data visible) | |
| Skipped/failed objects | |
| Manual fixes | |
| Verdict | PASS / FAIL |

## 8. Optional: upgrade rehearsal on the clone
Run `/eks-upgrade:upgrade preflight {{TARGET}}` → plan → CP upgrade → soak → nodes → version rollback.

## 9. Teardown (human)
- [ ] Delete target cluster, restored EBS volumes, EFS file systems, restored S3 data
- [ ] Check for orphaned ENIs / load balancers / security groups
