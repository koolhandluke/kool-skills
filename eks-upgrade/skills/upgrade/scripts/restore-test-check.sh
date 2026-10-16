#!/usr/bin/env bash
set -uo pipefail

# Read-only safety gates for a backup -> restore-to-isolated-cluster test.
#
# Usage:
#   ./restore-test-check.sh --phase pre     --source <cluster> --target <cluster> [--region <r>] [--taint-key <k>]
#   ./restore-test-check.sh --phase job     --restore-job-id <id> [--region <r>]
#   ./restore-test-check.sh --phase defused --target <cluster> --target-context <ctx>
#                           [--deployer-namespaces flux-system,spinnaker] [--region <r>]
#   (all phases accept --out <dir>)
#
# Phases:
#   pre      before start-restore-job: target is a different, ACTIVE, same-version cluster in a different
#            VPC; every node group carries the NoSchedule taint so restored pods stay Pending;
#            flags peering/TGW/NAT routes that could reach prod.
#   job      restore job status; COMPLETED still requires reading SNS for skipped/failed objects.
#   defused  before removing the taint: deployers scaled to 0, Flux suspended, Pod Identity
#            associations listed for review.
#
# Output: <out>/restore-test-<phase>.json ; exit 0 no BLOCK, 2 BLOCK, 1 usage.

PHASE="" SOURCE="" TARGET="" REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}" TAINT="restore-test"
JOB="" TCTX="" DEPLOYERS="flux-system,spinnaker" OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) PHASE="$2"; shift 2 ;;
    --source) SOURCE="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --taint-key) TAINT="$2"; shift 2 ;;
    --restore-job-id) JOB="$2"; shift 2 ;;
    --target-context) TCTX="$2"; shift 2 ;;
    --deployer-namespaces) DEPLOYERS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -z "$PHASE" || -z "$REGION" ]] && { echo "Usage: see header of $0" >&2; exit 1; }
for bin in aws jq; do command -v "$bin" >/dev/null || { echo "Missing required tool: $bin" >&2; exit 1; }; done

OUT="${OUT:-./eks-upgrade-runs/restore-test/$(date -u +%Y%m%dT%H%M%SZ)}"; mkdir -p "$OUT"
AWSC=(aws --region "$REGION" --output json)
CHECKS=$(mktemp); trap 'rm -f "$CHECKS"' EXIT
check() { jq -nc --arg id "$1" --arg s "$2" --arg d "$3" '{id:$id,status:$s,detail:$d}' >> "$CHECKS"; }

case "$PHASE" in
pre)
  [[ -z "$SOURCE" || -z "$TARGET" ]] && { echo "--source and --target required" >&2; exit 1; }
  if [[ "$SOURCE" == "$TARGET" ]]; then
    check target-distinct BLOCK "Target equals source ($SOURCE). Never restore-test into the source cluster."
  else
    S=$("${AWSC[@]}" eks describe-cluster --name "$SOURCE" 2>/dev/null) || { echo "source describe failed" >&2; exit 1; }
    T=$("${AWSC[@]}" eks describe-cluster --name "$TARGET" 2>/dev/null)
    if [[ -z "$T" ]]; then
      check target-exists BLOCK "Target cluster $TARGET not found. Create it yourself (same version, isolated VPC, tainted node group) before restoring."
    else
      check target-distinct PASS "$SOURCE -> $TARGET"
      [[ "$(jq -r .cluster.status <<<"$T")" == ACTIVE ]] && check target-status PASS ACTIVE || check target-status BLOCK "Target not ACTIVE"
      sv=$(jq -r .cluster.version <<<"$S"); tv=$(jq -r .cluster.version <<<"$T")
      [[ "$sv" == "$tv" ]] && check version-match PASS "$tv" || check version-match WARN "Source $sv vs target $tv; cross-version restore is best-effort"
      svpc=$(jq -r .cluster.resourcesVpcConfig.vpcId <<<"$S"); tvpc=$(jq -r .cluster.resourcesVpcConfig.vpcId <<<"$T")
      [[ "$svpc" != "$tvpc" ]] && check vpc-isolated PASS "target VPC $tvpc != source $svpc" \
        || check vpc-isolated BLOCK "Target shares source VPC $svpc"
      sacct=$(cut -d: -f5 <<<"$(jq -r .cluster.arn <<<"$S")"); tacct=$(cut -d: -f5 <<<"$(jq -r .cluster.arn <<<"$T")")
      check accounts PASS "source account $sacct, target account $tacct (keep inside the same authorization boundary)"
      tmode=$(jq -r '.cluster.accessConfig.authenticationMode // "CONFIG_MAP"' <<<"$T")
      [[ "$tmode" == API || "$tmode" == API_AND_CONFIG_MAP ]] && check target-auth-mode PASS "$tmode" \
        || check target-auth-mode BLOCK "Target authenticationMode=$tmode; AWS Backup needs access entries"

      # routes out of the target VPC
      "${AWSC[@]}" ec2 describe-route-tables --filters "Name=vpc-id,Values=$tvpc" \
        | jq '[.RouteTables[].Routes[] | select(.VpcPeeringConnectionId or .TransitGatewayId or .NatGatewayId or (.GatewayId // "" | startswith("igw-")))
               | {dest:(.DestinationCidrBlock // .DestinationPrefixListId), via:(.VpcPeeringConnectionId // .TransitGatewayId // .NatGatewayId // .GatewayId)}]' \
        > "$OUT/target-routes.json" 2>/dev/null
      r=$(jq -r '[.[] | "\(.dest) via \(.via)"] | unique | join(", ")' "$OUT/target-routes.json" 2>/dev/null)
      if [[ -z "$r" ]]; then check egress-routes PASS "no peering/TGW/NAT/IGW routes"
      elif grep -qE 'pcx-|tgw-' <<<"$r"; then check egress-routes BLOCK "Peering/TGW routes may reach prod: $r"
      else check egress-routes WARN "Internet egress present ($r): restored apps can reach public prod endpoints; prefer VPC endpoints only"; fi

      # node group taints
      if NG_JSON=$("${AWSC[@]}" eks list-nodegroups --cluster-name "$TARGET" 2>/dev/null); then
        NGS=$(jq -r '.nodegroups[]' <<<"$NG_JSON")
        if [[ -z "$NGS" ]]; then
          check node-taints PASS "no managed node groups (pods will stay Pending)"
        else
          untainted=""
          for ng in $NGS; do
            t=$("${AWSC[@]}" eks describe-nodegroup --cluster-name "$TARGET" --nodegroup-name "$ng" \
                | jq -r --arg k "$TAINT" '[.nodegroup.taints[]? | select(.key==$k and .effect=="NO_SCHEDULE")] | length')
            [[ "$t" == 0 ]] && untainted+="$ng "
          done
          [[ -z "$untainted" ]] && check node-taints PASS "all node groups tainted $TAINT:NoSchedule" \
            || check node-taints BLOCK "Node groups without $TAINT:NoSchedule taint: $untainted"
        fi
      else
        check node-taints SKIP "list-nodegroups failed; cannot verify taints"
      fi
      if FG_JSON=$("${AWSC[@]}" eks list-fargate-profiles --cluster-name "$TARGET" 2>/dev/null); then
        fg=$(jq '.fargateProfileNames|length' <<<"$FG_JSON")
        [[ "$fg" == 0 ]] || check fargate BLOCK "Target has Fargate profiles; matching pods would start immediately"
      else
        check fargate SKIP "list-fargate-profiles failed; cannot verify Fargate isolation"
      fi
    fi
  fi
  ;;
job)
  [[ -z "$JOB" ]] && { echo "--restore-job-id required" >&2; exit 1; }
  J=$("${AWSC[@]}" backup describe-restore-job --restore-job-id "$JOB") || { echo "describe-restore-job failed" >&2; exit 1; }
  echo "$J" > "$OUT/restore-job.json"
  st=$(jq -r .Status <<<"$J")
  case "$st" in
    COMPLETED) check restore-job WARN "COMPLETED. A COMPLETED job can still have skipped/failed objects: read the SNS notifications before trusting it." ;;
    PENDING|RUNNING) check restore-job PASS "$st $(jq -r '.PercentDone // ""' <<<"$J")" ;;
    *) check restore-job BLOCK "$st: $(jq -r '.StatusMessage // ""' <<<"$J")" ;;
  esac
  ;;
defused)
  [[ -z "$TARGET" || -z "$TCTX" ]] && { echo "--target and --target-context required" >&2; exit 1; }
  command -v kubectl >/dev/null || { echo "Missing required tool: kubectl" >&2; exit 1; }
  K=(kubectl --context "$TCTX")
  TEP=$("${AWSC[@]}" eks describe-cluster --name "$TARGET" | jq -r .cluster.endpoint)
  KEP=$("${K[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
  [[ "${KEP,,}" == "${TEP,,}" ]] || { check target-context BLOCK "context $TCTX points at $KEP, not $TARGET ($TEP)"; }
  if [[ "${KEP,,}" == "${TEP,,}" ]]; then
    check target-context PASS "$KEP"
    IFS=',' read -ra NSL <<< "$DEPLOYERS"
    for ns in "${NSL[@]}"; do
      live=$( { "${K[@]}" -n "$ns" get deploy -o json; "${K[@]}" -n "$ns" get sts -o json; } 2>/dev/null \
              | jq -r -s '[.[].items[] | select((.spec.replicas // 0) > 0) | "\(.kind)/\(.metadata.name)=\(.spec.replicas)"] | join(", ")')
      [[ -z "$live" ]] && check "defused:$ns" PASS "all deployments/statefulsets at 0" \
        || check "defused:$ns" BLOCK "still scaled up: $live"
    done
    if "${K[@]}" get crd kustomizations.kustomize.toolkit.fluxcd.io >/dev/null 2>&1; then
      ns=$("${K[@]}" get kustomizations.kustomize.toolkit.fluxcd.io -A -o json | jq -r '[.items[] | select(.spec.suspend!=true) | "\(.metadata.namespace)/\(.metadata.name)"] | join(", ")')
      [[ -z "$ns" ]] && check flux-suspended PASS "all Kustomizations suspended" \
        || check flux-suspended WARN "Kustomizations not suspended (ok only if Flux controllers are at 0): $ns"
    fi
    "${AWSC[@]}" eks list-pod-identity-associations --cluster-name "$TARGET" > "$OUT/pod-identity.json" 2>/dev/null \
      && { n=$(jq '.associations|length' "$OUT/pod-identity.json");
           (( n > 0 )) && check pod-identity WARN "$n Pod Identity associations restored; confirm none grant prod roles (pod-identity.json)" \
                       || check pod-identity PASS "none"; }
    sec=$("${K[@]}" get secrets -A -o json 2>/dev/null | jq '[.items[] | select(.type!="kubernetes.io/service-account-token" and .type!="helm.sh/release.v1")] | length')
    check restored-secrets WARN "${sec:-?} restored Secrets (prod credentials may be live). Rotate/strip any that reach prod before untainting."
  fi
  ;;
*) echo "Unknown phase: $PHASE" >&2; exit 1 ;;
esac

FILE="$OUT/restore-test-$PHASE.json"
jq -s --arg p "$PHASE" '{phase:$p, checks:., counts:(group_by(.status)|map({key:.[0].status,value:length})|from_entries)}' "$CHECKS" > "$FILE"
echo "$FILE"
jq -r '.checks[] | "\(.status)\t\(.id)\t\(.detail)"' "$FILE" >&2
jq -e '(.counts.BLOCK // 0) == 0' "$FILE" >/dev/null && exit 0 || exit 2
