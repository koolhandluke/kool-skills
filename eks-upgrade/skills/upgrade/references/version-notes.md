# EKS version notes (verified 2026-10-16)

Re-verify dates and add-on versions live before acting; these notes go stale.

## Lifecycle

| Version | End of standard support | End of extended support |
|---|---|---|
| 1.32 | 2026-03-23 | 2027-03-23 |
| 1.33 | 2026-07-29 | 2027-07-29 |
| 1.34 | 2026-12-02 | — |
| 1.35 | 2027-03-27 | — |
| 1.36 | 2027-08-02 | — |

1.33 and 1.34 are waypoints. Plan the loop through 1.35/1.36, subject to controller compatibility.
Source: https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html

## General sequencing (all hops)

- Control plane moves one minor per in-place upgrade.
- Bring nodes to the current CP minor before starting (AWS allows kubelet up to 3 minors behind; the
  production procedure here uses matching versions).
- Order: CP → nodes → Cluster Autoscaler (match target minor) / controllers → EKS add-ons → clients.
- A prerequisite add-on bump may be needed *before* the CP: pick versions valid on both minors.
- kubectl within ±1 minor of the API server.
- EKS needs up to 5 free IPs across cluster subnets; new ENIs can land in any of them, so SG rules must
  allow cluster traffic for all cluster subnets.
- The CP upgrade can't be paused once started; on failed health checks EKS reverts it.
- API clients must handle reconnects (API server IPs change).
- Upgrade insights: 30-day rolling lookback for deprecated API usage; refresh ~24h after last refresh.
Source: https://docs.aws.amazon.com/eks/latest/userguide/update-cluster.html

## 1.32 → 1.33

- **No EKS-optimized AL2 AMI for 1.33.** AL2 AMI publishing ended 2025-11-26. Migrate to AL2023 or
  Bottlerocket on 1.32 in its own change window, then upgrade.
  https://docs.aws.amazon.com/eks/latest/userguide/eks-ami-deprecation-faqs.html
- **AL2023 differences:** VPC CNI ≥ 1.16.2; cgroup v2; IMDSv2 only; bootstrap via `nodeadm`
  (`NodeConfig`), not `/etc/eks/bootstrap.sh`. Custom AMI user data must supply cluster metadata.
  Managed node groups without a launch template get IMDS hop limit 1 → pods using node-role
  credentials fail; prefer IRSA/Pod Identity. Standard managed node groups need replacement groups
  for the OS change. https://docs.aws.amazon.com/eks/latest/userguide/al2023.html
- **Endpoints deprecated (not removed)** in 1.33. Move custom consumers to EndpointSlice; test service
  discovery. https://kubernetes.io/blog/2025/04/24/endpoints-deprecation/
- **`status.nodeInfo.kubeProxyVersion` no longer populated.** Fix inventory/reporting scripts.
- **flowcontrol.apiserver.k8s.io/v1beta3** removal was in 1.32, not 1.33 — a running 1.32 cluster is
  already clean, but dormant pipeline templates/charts may still reference it and fail on apply.

## Rollback (see rollback.md)

In-place upgrades can be rolled back one minor within 7 days. Not a data restore.

## Production gates (engineering recommendations)

- Baseline latency / error / queue metrics before starting.
- Rehearse from production-like config in a nonprod account with isolated state.
- Restore backups into an isolated environment at least once.
- Canary the OS change; during a drain test networking, credentials, PVC reattach, DNS, webhooks,
  controller reconciliation.
- Full Spinnaker (or equivalent) execution and a rollback rehearsal in nonprod.
- Separate changes; pin versions; named owner and explicit stop thresholds before starting.
- Pods Ready ≠ success.
