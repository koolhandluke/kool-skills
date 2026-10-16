#!/usr/bin/env bash
set -uo pipefail

# Read-only EKS upgrade preflight.
#
# Usage:
#   ./preflight.sh --cluster <name> [--region <region>] [--target <minor, e.g. 1.33>]
#                  [--context <kube-context>] [--out <dir>]
#
# Output:
#   <out>/summary.json   {cluster, region, current, target, checks:[{id,status,detail}]}
#   <out>/*.json         raw data per check
# status: PASS | WARN | BLOCK | SKIP
# Exit code: 0 no BLOCK, 2 at least one BLOCK, 1 usage/prereq error.

CLUSTER="" REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}" TARGET="" CONTEXT="" OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster) CLUSTER="$2"; shift 2 ;;
    --region)  REGION="$2";  shift 2 ;;
    --target)  TARGET="$2";  shift 2 ;;
    --context) CONTEXT="$2"; shift 2 ;;
    --out)     OUT="$2";     shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$CLUSTER" || -z "$REGION" ]]; then
  echo "Usage: $0 --cluster <name> --region <region> [--target <minor>] [--context <ctx>] [--out <dir>]" >&2
  exit 1
fi
for bin in aws kubectl jq; do
  command -v "$bin" >/dev/null || { echo "Missing required tool: $bin" >&2; exit 1; }
done

OUT="${OUT:-./eks-upgrade-runs/$CLUSTER/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
CHECKS="$OUT/.checks.ndjson"; : > "$CHECKS"

AWSC=(aws --region "$REGION" --output json)
KUBECTL=(kubectl)
[[ -n "$CONTEXT" ]] && KUBECTL+=(--context "$CONTEXT")

check() { # id status detail
  jq -nc --arg id "$1" --arg s "$2" --arg d "$3" '{id:$id,status:$s,detail:$d}' >> "$CHECKS"
}
minor() { echo "$1" | sed -E 's/^v?([0-9]+\.[0-9]+).*/\1/'; }
ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; } # $1 >= $2
next_minor() { awk -F. '{printf "%d.%d", $1, $2+1}' <<<"$1"; }

# --- identity -------------------------------------------------------------
if ! "${AWSC[@]}" sts get-caller-identity > "$OUT/identity.json" 2>"$OUT/identity.err"; then
  echo "AWS credentials not usable: $(cat "$OUT/identity.err")" >&2; exit 1
fi

# --- cluster --------------------------------------------------------------
if ! "${AWSC[@]}" eks describe-cluster --name "$CLUSTER" > "$OUT/cluster.json" 2>"$OUT/cluster.err"; then
  echo "describe-cluster failed: $(cat "$OUT/cluster.err")" >&2; exit 1
fi
CURRENT=$(jq -r '.cluster.version' "$OUT/cluster.json")
STATUS=$(jq -r '.cluster.status' "$OUT/cluster.json")
SUPPORT=$(jq -r '.cluster.upgradePolicy.supportType // "UNKNOWN"' "$OUT/cluster.json")
ENDPOINT=$(jq -r '.cluster.endpoint' "$OUT/cluster.json")
TARGET="${TARGET:-$(next_minor "$CURRENT")}"

[[ "$STATUS" == "ACTIVE" ]] && check cluster-status PASS "ACTIVE" \
  || check cluster-status BLOCK "Cluster status is $STATUS (must be ACTIVE)"

if [[ "$TARGET" == "$(next_minor "$CURRENT")" ]]; then
  check target-version PASS "$CURRENT -> $TARGET"
else
  check target-version BLOCK "Target $TARGET is not exactly one minor above $CURRENT"
fi
check support-policy PASS "upgradePolicy.supportType=$SUPPORT, platformVersion=$(jq -r '.cluster.platformVersion' "$OUT/cluster.json")"

# --- in-flight updates ----------------------------------------------------
if "${AWSC[@]}" eks list-updates --name "$CLUSTER" > "$OUT/updates.json" 2>/dev/null; then
  INPROG=""
  for id in $(jq -r '.updateIds[]' "$OUT/updates.json" | head -20); do
    s=$("${AWSC[@]}" eks describe-update --name "$CLUSTER" --update-id "$id" --query 'update.status' --output text 2>/dev/null)
    [[ "$s" == "InProgress" ]] && INPROG+="$id "
  done
  [[ -z "$INPROG" ]] && check updates-in-progress PASS "none" \
    || check updates-in-progress BLOCK "Updates in progress: $INPROG"
else
  check updates-in-progress SKIP "list-updates failed"
fi

# --- kube context matches cluster ----------------------------------------
KSERVER=$("${KUBECTL[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
if [[ "${KSERVER,,}" != "${ENDPOINT,,}" ]]; then
  check kube-context BLOCK "kubectl context server '$KSERVER' != cluster endpoint '$ENDPOINT'. Fix context before continuing."
  KUBE_OK=0
else
  check kube-context PASS "$KSERVER"
  KUBE_OK=1
fi

# --- nodes / skew ---------------------------------------------------------
if (( KUBE_OK )) && "${KUBECTL[@]}" get nodes -o json > "$OUT/nodes.json" 2>/dev/null; then
  jq '[.items[] | {name:.metadata.name, kubelet:.status.nodeInfo.kubeletVersion, os:.status.nodeInfo.osImage,
       kernel:.status.nodeInfo.kernelVersion, runtime:.status.nodeInfo.containerRuntimeVersion,
       nodegroup:(.metadata.labels["eks.amazonaws.com/nodegroup"] // .metadata.labels["karpenter.sh/nodepool"] // "self-managed"),
       compute:(.metadata.labels["eks.amazonaws.com/compute-type"] // "ec2"),
       ready:([.status.conditions[]|select(.type=="Ready")][0].status)}]' "$OUT/nodes.json" > "$OUT/nodes-summary.json"
  SKEW=$(jq -r --arg cp "$CURRENT" '[.[] | select((.kubelet|ltrimstr("v")|split(".")[0:2]|join(".")) != $cp) | "\(.name)=\(.kubelet)"] | join(", ")' "$OUT/nodes-summary.json")
  NOTREADY=$(jq -r '[.[]|select(.ready!="True")|.name]|join(", ")' "$OUT/nodes-summary.json")
  [[ -z "$SKEW" ]] && check node-skew PASS "All kubelets at $CURRENT" \
    || check node-skew BLOCK "Nodes not at control-plane minor $CURRENT: $SKEW"
  [[ -z "$NOTREADY" ]] && check nodes-ready PASS "All nodes Ready" \
    || check nodes-ready WARN "NotReady nodes: $NOTREADY"
else
  check node-skew SKIP "kubectl get nodes failed or context mismatch"
fi

# --- managed node groups / AMI type / IMDS -------------------------------
if "${AWSC[@]}" eks list-nodegroups --cluster-name "$CLUSTER" > "$OUT/nodegroups-list.json" 2>/dev/null; then
  echo '[]' > "$OUT/nodegroups.json"
  for ng in $(jq -r '.nodegroups[]' "$OUT/nodegroups-list.json"); do
    "${AWSC[@]}" eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng" \
      | jq '.nodegroup | {name:.nodegroupName, version, releaseVersion, amiType, capacityType, status,
            scaling:.scalingConfig, launchTemplate, updateConfig, health:.health.issues}' > "$OUT/.ng.json"
    jq -s '.[0] + [.[1]]' "$OUT/nodegroups.json" "$OUT/.ng.json" > "$OUT/.ngs.json" && mv "$OUT/.ngs.json" "$OUT/nodegroups.json"
  done
  rm -f "$OUT/.ng.json"
  AL2=$(jq -r '[.[]|select((.amiType // "")|startswith("AL2_"))|"\(.name)(\(.amiType))"]|join(", ")' "$OUT/nodegroups.json")
  CUSTOM=$(jq -r '[.[]|select(.amiType=="CUSTOM")|.name]|join(", ")' "$OUT/nodegroups.json")
  NGSKEW=$(jq -r --arg cp "$CURRENT" '[.[]|select(.version!=$cp)|"\(.name)=\(.version)"]|join(", ")' "$OUT/nodegroups.json")
  NGHEALTH=$(jq -r '[.[]|select((.health//[])|length>0)|.name]|join(", ")' "$OUT/nodegroups.json")
  if [[ -n "$AL2" ]]; then
    if ver_ge "$TARGET" "1.33"; then
      check ami-type BLOCK "AL2 node groups have no EKS-optimized AMI for $TARGET: $AL2. Migrate to AL2023/Bottlerocket on $CURRENT first (separate window)."
    else
      check ami-type WARN "AL2 node groups (EOL, plan AL2023 migration): $AL2"
    fi
  else
    check ami-type PASS "No AL2 managed node groups"
  fi
  [[ -n "$CUSTOM" ]] && check custom-ami WARN "CUSTOM AMI node groups need a target-version AMI and nodeadm/bootstrap review: $CUSTOM"
  [[ -z "$NGSKEW" ]] && check nodegroup-version PASS "All managed node groups at $CURRENT" \
    || check nodegroup-version BLOCK "Managed node groups not at $CURRENT: $NGSKEW"
  [[ -n "$NGHEALTH" ]] && check nodegroup-health WARN "Node groups with health issues: $NGHEALTH"

  # IMDS hop limit (matters for pods using node-role credentials on AL2023)
  echo '[]' > "$OUT/imds.json"
  while read -r ng ltid ltver; do
    [[ -z "$ltid" || "$ltid" == "null" ]] && { jq --arg ng "$ng" '. + [{nodegroup:$ng, launchTemplate:null, hopLimit:"default(no LT)"}]' "$OUT/imds.json" > "$OUT/.i" && mv "$OUT/.i" "$OUT/imds.json"; continue; }
    hop=$("${AWSC[@]}" ec2 describe-launch-template-versions --launch-template-id "$ltid" --versions "$ltver" \
          --query 'LaunchTemplateVersions[0].LaunchTemplateData.MetadataOptions' 2>/dev/null | jq -c '.')
    jq --arg ng "$ng" --arg lt "$ltid" --argjson m "${hop:-null}" '. + [{nodegroup:$ng, launchTemplate:$lt, metadataOptions:$m}]' "$OUT/imds.json" > "$OUT/.i" && mv "$OUT/.i" "$OUT/imds.json"
  done < <(jq -r '.[] | "\(.name) \(.launchTemplate.id // "") \(.launchTemplate.version // "")"' "$OUT/nodegroups.json")
  LOWHOP=$(jq -r '[.[]|select(.hopLimit=="default(no LT)" or ((.metadataOptions.HttpPutResponseHopLimit // 1) < 2))|.nodegroup]|join(", ")' "$OUT/imds.json")
  [[ -n "$LOWHOP" ]] && check imds-hop-limit WARN "IMDS hop limit 1 (or default) on: $LOWHOP. Pods relying on node-role credentials will fail; use IRSA/Pod Identity or hop limit 2."
else
  check nodegroups SKIP "list-nodegroups failed"
fi

# --- Fargate --------------------------------------------------------------
if "${AWSC[@]}" eks list-fargate-profiles --cluster-name "$CLUSTER" > "$OUT/fargate.json" 2>/dev/null; then
  n=$(jq '.fargateProfileNames|length' "$OUT/fargate.json")
  (( n > 0 )) && check fargate WARN "$n Fargate profile(s): pods keep old kubelet until redeployed; rollback requires deleting newer Fargate pods." \
              || check fargate PASS "No Fargate profiles"
fi

# --- add-ons --------------------------------------------------------------
if "${AWSC[@]}" eks list-addons --cluster-name "$CLUSTER" > "$OUT/addons-list.json" 2>/dev/null; then
  echo '[]' > "$OUT/addons.json"
  for a in $(jq -r '.addons[]' "$OUT/addons-list.json"); do
    cur=$("${AWSC[@]}" eks describe-addon --cluster-name "$CLUSTER" --addon-name "$a" --query 'addon.addonVersion' --output text 2>/dev/null)
    "${AWSC[@]}" eks describe-addon-versions --addon-name "$a" --kubernetes-version "$TARGET" > "$OUT/.av.json" 2>/dev/null || echo '{"addons":[]}' > "$OUT/.av.json"
    jq --arg a "$a" --arg cur "$cur" --arg t "$TARGET" --slurpfile av "$OUT/.av.json" '
      ($av[0].addons[0].addonVersions // []) as $vs |
      . + [{addon:$a, current:$cur,
            currentValidOnTarget: ([$vs[].addonVersion] | index($cur) != null),
            targetDefault: ([$vs[] | select(any(.compatibilities[]; .clusterVersion==$t and .defaultVersion==true)) | .addonVersion][0]),
            targetLatest: ($vs[0].addonVersion)}]' "$OUT/addons.json" > "$OUT/.a" && mv "$OUT/.a" "$OUT/addons.json"
  done
  rm -f "$OUT/.av.json"
  BAD=$(jq -r '[.[]|select(.currentValidOnTarget|not)|"\(.addon) \(.current) (target default \(.targetDefault))"]|join("; ")' "$OUT/addons.json")
  [[ -z "$BAD" ]] && check addons-compat PASS "All EKS add-on versions valid on $TARGET" \
    || check addons-compat BLOCK "Add-on versions not valid on $TARGET; bump first to a version valid on both $CURRENT and $TARGET: $BAD"
else
  check addons-compat SKIP "list-addons failed"
fi

# VPC CNI version (AL2023 requires >= 1.16.2)
if (( KUBE_OK )); then
  CNI=$("${KUBECTL[@]}" -n kube-system get ds aws-node -o jsonpath='{.spec.template.spec.containers[?(@.name=="aws-node")].image}' 2>/dev/null | sed -E 's/.*:v?([0-9.]+).*/\1/')
  if [[ -n "$CNI" ]]; then
    ver_ge "$CNI" "1.16.2" && check vpc-cni PASS "aws-node $CNI" \
      || check vpc-cni BLOCK "aws-node $CNI < 1.16.2 (required for AL2023 nodes)"
  else
    check vpc-cni SKIP "aws-node DaemonSet not found (alternate CNI?)"
  fi

  # Cluster Autoscaler
  CA=$("${KUBECTL[@]}" get deploy -A -o json 2>/dev/null | jq -r '[.items[].spec.template.spec.containers[].image | select(test("cluster-autoscaler"))][0] // ""')
  if [[ -n "$CA" ]]; then
    check cluster-autoscaler WARN "Cluster Autoscaler image $CA: bump to $TARGET.x after control-plane upgrade"
  fi

  # PDBs blocking drain
  "${KUBECTL[@]}" get pdb -A -o json 2>/dev/null | jq '[.items[] | select(.status.disruptionsAllowed==0) | {ns:.metadata.namespace, name:.metadata.name, expected:.status.expectedPods, healthy:.status.currentHealthy}]' > "$OUT/pdb-blocking.json"
  n=$(jq length "$OUT/pdb-blocking.json")
  (( n > 0 )) && check pdb-drain WARN "$n PDB(s) with 0 disruptions allowed will stall node drains (see pdb-blocking.json)" \
              || check pdb-drain PASS "No PDBs at 0 disruptions allowed"

  # Fail-closed webhooks (break during drain/CP restarts if backends unavailable)
  { "${KUBECTL[@]}" get validatingwebhookconfigurations -o json; "${KUBECTL[@]}" get mutatingwebhookconfigurations -o json; } 2>/dev/null \
    | jq -s '[.[].items[] | .metadata.name as $cfg | .webhooks[] | select(.failurePolicy=="Fail") |
             {config:$cfg, webhook:.name, service:(.clientConfig.service // null), timeout:.timeoutSeconds}]' > "$OUT/webhooks-failclosed.json"
  n=$(jq length "$OUT/webhooks-failclosed.json")
  (( n > 0 )) && check webhooks WARN "$n fail-closed webhook(s); verify backends have >=2 replicas + PDB (see webhooks-failclosed.json)"

  # Helm releases (inventory for controller compatibility review)
  if command -v helm >/dev/null; then
    helm list -A -o json ${CONTEXT:+--kube-context "$CONTEXT"} > "$OUT/helm-releases.json" 2>/dev/null \
      && check helm-inventory PASS "$(jq length "$OUT/helm-releases.json") releases captured; review chart compatibility with $TARGET" \
      || check helm-inventory SKIP "helm list failed"
  fi

  # kubectl client skew
  KC=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.major + "." + (.clientVersion.minor|gsub("[^0-9]";""))')
  if [[ -n "$KC" ]]; then
    d=$(awk -v a="$KC" -v b="$TARGET" 'BEGIN{split(a,x,".");split(b,y,".");print (x[2]-y[2])}')
    (( d >= -1 && d <= 1 )) && check kubectl-client PASS "kubectl $KC within ±1 of $TARGET" \
      || check kubectl-client WARN "kubectl $KC not within ±1 of $TARGET"
  fi
fi

# --- subnet free IPs ------------------------------------------------------
SUBNETS=$(jq -r '.cluster.resourcesVpcConfig.subnetIds|join(" ")' "$OUT/cluster.json")
if [[ -n "$SUBNETS" ]] && "${AWSC[@]}" ec2 describe-subnets --subnet-ids $SUBNETS \
     | jq '[.Subnets[]|{id:.SubnetId, az:.AvailabilityZone, free:.AvailableIpAddressCount}]' > "$OUT/subnets.json" 2>/dev/null; then
  LOW=$(jq -r '[.[]|select(.free<5)|"\(.id)=\(.free)"]|join(", ")' "$OUT/subnets.json")
  [[ -z "$LOW" ]] && check subnet-ips PASS "All cluster subnets have >=5 free IPs" \
    || check subnet-ips BLOCK "Cluster subnets with <5 free IPs (EKS needs up to 5 for CP update): $LOW"
else
  check subnet-ips SKIP "describe-subnets failed"
fi

# --- upgrade insights -----------------------------------------------------
if "${AWSC[@]}" eks list-insights --cluster-name "$CLUSTER" > "$OUT/insights.json" 2>/dev/null; then
  ERR=$(jq -r '[.insights[]|select(.insightStatus.status=="ERROR")|"\(.name) [\(.category)]"]|join("; ")' "$OUT/insights.json")
  WRN=$(jq -r '[.insights[]|select(.insightStatus.status=="WARNING" or .insightStatus.status=="UNKNOWN")|"\(.name) [\(.insightStatus.status)]"]|join("; ")' "$OUT/insights.json")
  for id in $(jq -r '.insights[]|select(.insightStatus.status!="PASSING")|.id' "$OUT/insights.json"); do
    "${AWSC[@]}" eks describe-insight --cluster-name "$CLUSTER" --id "$id" > "$OUT/insight-$id.json" 2>/dev/null
  done
  [[ -n "$ERR" ]] && check insights BLOCK "ERROR insights (30-day lookback; may be stale): $ERR"
  [[ -z "$ERR" && -n "$WRN" ]] && check insights WARN "$WRN"
  [[ -z "$ERR" && -z "$WRN" ]] && check insights PASS "All insights PASSING"
else
  check insights SKIP "list-insights failed"
fi

# --- summary --------------------------------------------------------------
jq -s --arg c "$CLUSTER" --arg r "$REGION" --arg cur "$CURRENT" --arg t "$TARGET" \
   --arg ts "$(date -u +%FT%TZ)" --slurpfile id "$OUT/identity.json" \
   '{cluster:$c, region:$r, current:$cur, target:$t, generatedAt:$ts, caller:$id[0].Arn,
     counts:(group_by(.status)|map({key:.[0].status, value:length})|from_entries), checks:.}' \
   "$CHECKS" > "$OUT/summary.json"
rm -f "$CHECKS"

echo "$OUT/summary.json"
jq -r '.checks[] | "\(.status)\t\(.id)\t\(.detail)"' "$OUT/summary.json" >&2
jq -e '.counts.BLOCK // 0 | . == 0' "$OUT/summary.json" >/dev/null && exit 0 || exit 2
