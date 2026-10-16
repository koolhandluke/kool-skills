#!/usr/bin/env bash
set -uo pipefail

# Post-change verification for EKS upgrades.
# Default mode is READ-ONLY. --active creates short-lived probe pods and is HUMAN-RUN ONLY.
#
# Usage:
#   ./verify.sh [--context <kube-ctx>] [--out <dir>] [--baseline <snapshot.json>]
#               [--namespaces ns1,ns2]                 # critical namespaces (must be fully healthy)
#               [--prom-url <url>] [--prom-query 'name=<promql>' ...]
#               [--active [--probe-ns <ns>] [--probe-image <img>] [--irsa-sa <ns/sa>] [--aws-cli-image <img>]]
#
# Output:
#   <out>/verify-<ts>.json  {snapshot:{...}, checks:[{id,status,detail}], diff:{...}}
#   Path printed to stdout; human summary to stderr.
# Exit: 0 no FAIL, 2 at least one FAIL, 1 usage error.

CONTEXT="" OUT="" BASELINE="" NAMESPACES="" PROM_URL="" ACTIVE=0
PROBE_NS="default" PROBE_IMAGE="public.ecr.aws/docker/library/busybox:1.36" IRSA_SA="" AWSCLI_IMAGE="public.ecr.aws/aws-cli/aws-cli:latest"
PROM_QUERIES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)       CONTEXT="$2"; shift 2 ;;
    --out)           OUT="$2"; shift 2 ;;
    --baseline)      BASELINE="$2"; shift 2 ;;
    --namespaces)    NAMESPACES="$2"; shift 2 ;;
    --prom-url)      PROM_URL="$2"; shift 2 ;;
    --prom-query)    PROM_QUERIES+=("$2"); shift 2 ;;
    --active)        ACTIVE=1; shift ;;
    --probe-ns)      PROBE_NS="$2"; shift 2 ;;
    --probe-image)   PROBE_IMAGE="$2"; shift 2 ;;
    --irsa-sa)       IRSA_SA="$2"; shift 2 ;;
    --aws-cli-image) AWSCLI_IMAGE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
for bin in kubectl jq; do command -v "$bin" >/dev/null || { echo "Missing required tool: $bin" >&2; exit 1; }; done

TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT="${OUT:-./eks-upgrade-runs/verify}"; mkdir -p "$OUT"
K=(kubectl); [[ -n "$CONTEXT" ]] && K+=(--context "$CONTEXT")
CHECKS=$(mktemp); trap 'rm -f "$CHECKS"' EXIT
check() { jq -nc --arg id "$1" --arg s "$2" --arg d "$3" '{id:$id,status:$s,detail:$d}' >> "$CHECKS"; }
getj() { "${K[@]}" get "$@" -o json 2>/dev/null || echo '{"items":[]}'; }

# --- API server -----------------------------------------------------------
if R=$("${K[@]}" get --raw='/readyz?verbose' --request-timeout=10s 2>&1); then
  check apiserver-readyz PASS "readyz ok"
else
  check apiserver-readyz FAIL "$(echo "$R" | grep -v ' ok$' | head -5 | tr '\n' ' ')"
fi
SERVER_VER=$("${K[@]}" version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // "unknown"')

# --- snapshot -------------------------------------------------------------
TMPD=$(mktemp -d); trap 'rm -f "$CHECKS"; rm -rf "$TMPD"' EXIT
getj nodes > "$TMPD/n.json"; getj pods -A > "$TMPD/p.json"; getj deploy -A > "$TMPD/d.json"
getj ds -A > "$TMPD/ds.json"; getj sts -A > "$TMPD/sts.json"; getj pvc -A > "$TMPD/pvc.json"
getj volumeattachments > "$TMPD/va.json"; getj events -A --field-selector type=Warning > "$TMPD/ev.json"
getj endpointslices -n kube-system -l kubernetes.io/service-name=kube-dns > "$TMPD/sl.json"

SNAP=$(jq -n \
  --arg ts "$TS" --arg sv "$SERVER_VER" \
  --slurpfile N "$TMPD/n.json" --slurpfile P "$TMPD/p.json" --slurpfile D "$TMPD/d.json" --slurpfile DS "$TMPD/ds.json" \
  --slurpfile STS "$TMPD/sts.json" --slurpfile PVC "$TMPD/pvc.json" --slurpfile VA "$TMPD/va.json" \
  --slurpfile EV "$TMPD/ev.json" --slurpfile SL "$TMPD/sl.json" '
  $N[0] as $n | $P[0] as $p | $D[0] as $d | $DS[0] as $ds | $STS[0] as $sts | $PVC[0] as $pvc |
  $VA[0] as $va | $EV[0] as $ev | $SL[0] as $sl |
  def ready(c): ([c[]? | select(.type=="Ready")][0].status // "Unknown");
  {
    ts:$ts, serverVersion:$sv,
    nodes:{ total:($n.items|length),
            notReady:[$n.items[] | select(ready(.status.conditions)!="True") | .metadata.name],
            kubelet:($n.items | group_by(.status.nodeInfo.kubeletVersion) | map({key:.[0].status.nodeInfo.kubeletVersion, value:length}) | from_entries),
            os:($n.items | group_by(.status.nodeInfo.osImage) | map({key:.[0].status.nodeInfo.osImage, value:length}) | from_entries) },
    pods:{ badByNs:([$p.items[] | select(.status.phase!="Running" and .status.phase!="Succeeded")] | group_by(.metadata.namespace) | map({key:.[0].metadata.namespace, value:length}) | from_entries),
           crashLoop:[$p.items[] | select(any(.status.containerStatuses[]?; .state.waiting.reason=="CrashLoopBackOff" or .state.waiting.reason=="ImagePullBackOff" or .state.waiting.reason=="CreateContainerConfigError")) | "\(.metadata.namespace)/\(.metadata.name)"],
           restartsByNs:($p.items | group_by(.metadata.namespace) | map({key:.[0].metadata.namespace, value:([.[].status.containerStatuses[]?.restartCount] | add // 0)}) | from_entries) },
    workloads:{ deployUnavailable:[$d.items[] | select((.status.unavailableReplicas // 0) > 0) | "\(.metadata.namespace)/\(.metadata.name)"],
                dsNotReady:[$ds.items[] | select((.status.numberReady // 0) < (.status.desiredNumberScheduled // 0)) | "\(.metadata.namespace)/\(.metadata.name)"],
                stsNotReady:[$sts.items[] | select((.status.readyReplicas // 0) < (.spec.replicas // 0)) | "\(.metadata.namespace)/\(.metadata.name)"] },
    storage:{ pvcNotBound:[$pvc.items[] | select(.status.phase!="Bound") | "\(.metadata.namespace)/\(.metadata.name)"],
              attachErrors:[$va.items[] | select(.status.attachError != null or .status.detachError != null) | .metadata.name] },
    dns:{ readyEndpoints:([$sl.items[].endpoints[]? | select(.conditions.ready==true)] | length) },
    warningEvents:($ev.items | group_by(.reason) | map({key:.[0].reason, value:([.[].count // 1] | add)}) | from_entries)
  }')

# --- checks from snapshot -------------------------------------------------
v() { jq -r "$1" <<<"$SNAP"; }
[[ "$(v '.nodes.notReady|length')" == 0 ]] && check nodes-ready PASS "$(v '.nodes.total') nodes Ready; kubelet $(v '.nodes.kubelet|tojson')" \
  || check nodes-ready FAIL "NotReady: $(v '.nodes.notReady|join(", ")')"
[[ "$(v '.nodes.kubelet|keys|length')" -le 1 ]] || check kubelet-mix WARN "Mixed kubelet versions: $(v '.nodes.kubelet|tojson')"
[[ "$(v '.dns.readyEndpoints')" -ge 2 ]] && check coredns-endpoints PASS "$(v '.dns.readyEndpoints') ready kube-dns endpoints" \
  || check coredns-endpoints FAIL "Only $(v '.dns.readyEndpoints') ready kube-dns endpoints"
[[ "$(v '.pods.crashLoop|length')" == 0 ]] && check crashloop PASS "none" \
  || check crashloop FAIL "$(v '.pods.crashLoop[:20]|join(", ")')"
[[ "$(v '.workloads.dsNotReady|length')" == 0 ]] && check daemonsets PASS "all ready" \
  || check daemonsets FAIL "$(v '.workloads.dsNotReady|join(", ")')"
[[ "$(v '.workloads.deployUnavailable|length')" == 0 ]] && check deployments PASS "all available" \
  || check deployments WARN "$(v '.workloads.deployUnavailable[:20]|join(", ")')"
[[ "$(v '.workloads.stsNotReady|length')" == 0 ]] || check statefulsets WARN "$(v '.workloads.stsNotReady|join(", ")')"
[[ "$(v '.storage.pvcNotBound|length')" == 0 ]] && check pvc-bound PASS "all Bound" \
  || check pvc-bound WARN "$(v '.storage.pvcNotBound|join(", ")')"
[[ "$(v '.storage.attachErrors|length')" == 0 ]] && check volume-attach PASS "no attach/detach errors" \
  || check volume-attach FAIL "$(v '.storage.attachErrors|join(", ")')"

# kube-system strict
KSBAD=$(v '.pods.badByNs["kube-system"] // 0')
[[ "$KSBAD" == 0 ]] && check kube-system PASS "all pods Running" || check kube-system FAIL "$KSBAD non-running pods in kube-system"

# critical namespaces strict
IFS=',' read -ra NSL <<< "$NAMESPACES"
for ns in "${NSL[@]}"; do
  [[ -z "$ns" ]] && continue
  b=$(v ".pods.badByNs[\"$ns\"] // 0")
  u=$(jq -r --arg ns "$ns" '[.workloads[][] | select(startswith($ns+"/"))] | join(", ")' <<<"$SNAP")
  [[ "$b" == 0 && -z "$u" ]] && check "ns:$ns" PASS "healthy" || check "ns:$ns" FAIL "non-running pods=$b; unready workloads: ${u:-none}"
done

# webhooks with no ready backends
{ "${K[@]}" get validatingwebhookconfigurations -o json; "${K[@]}" get mutatingwebhookconfigurations -o json; } 2>/dev/null \
 | jq -r -s '[.[].items[].webhooks[] | select(.failurePolicy=="Fail" and .clientConfig.service!=null) | "\(.clientConfig.service.namespace)/\(.clientConfig.service.name)"] | unique[]' \
 | while read -r svc; do
     n=$("${K[@]}" get endpointslices -n "${svc%/*}" -l "kubernetes.io/service-name=${svc#*/}" -o json 2>/dev/null \
         | jq '[.items[].endpoints[]? | select(.conditions.ready==true)] | length')
     [[ "${n:-0}" -gt 0 ]] && check "webhook:$svc" PASS "$n ready endpoints" || check "webhook:$svc" FAIL "fail-closed webhook backend has no ready endpoints"
   done

# Flux (if installed)
for kind in kustomizations.kustomize.toolkit.fluxcd.io helmreleases.helm.toolkit.fluxcd.io; do
  if "${K[@]}" get crd "$kind" >/dev/null 2>&1; then
    nr=$(getj "$kind" -A | jq -r '[.items[] | select(.spec.suspend!=true) | select(([.status.conditions[]? | select(.type=="Ready")][0].status // "Unknown") != "True") | "\(.metadata.namespace)/\(.metadata.name)"] | join(", ")')
    [[ -z "$nr" ]] && check "flux:${kind%%.*}" PASS "all Ready" || check "flux:${kind%%.*}" FAIL "not Ready: $nr"
  fi
done

# --- metrics (optional, read-only HTTP GET) ------------------------------
METRICS='{}'
if [[ -n "$PROM_URL" ]]; then
  for q in "${PROM_QUERIES[@]}"; do
    name=${q%%=*}; expr=${q#*=}
    val=$(curl -fsS --max-time 15 -G "$PROM_URL/api/v1/query" --data-urlencode "query=$expr" 2>/dev/null | jq -r '.data.result[0].value[1] // "null"')
    METRICS=$(jq --arg n "$name" --arg v "${val:-null}" '. + {($n): ($v|tonumber? // null)}' <<<"$METRICS")
  done
fi
SNAP=$(jq --argjson m "$METRICS" '. + {metrics:$m}' <<<"$SNAP")

# --- active probes (HUMAN-RUN ONLY) --------------------------------------
if (( ACTIVE )); then
  echo "ACTIVE MODE: creating probe pods in namespace $PROBE_NS" >&2
  if "${K[@]}" -n "$PROBE_NS" run "eksup-dns-$TS" --rm -i --restart=Never --image="$PROBE_IMAGE" --request-timeout=90s \
       -- sh -c 'nslookup kubernetes.default.svc.cluster.local && nslookup amazonaws.com' >/dev/null 2>&1; then
    check active-dns PASS "in-cluster + external DNS resolve"
  else
    check active-dns FAIL "DNS probe pod failed"
  fi
  if [[ -n "$IRSA_SA" ]]; then
    if out=$("${K[@]}" -n "${IRSA_SA%/*}" run "eksup-creds-$TS" --rm -i --restart=Never --image="$AWSCLI_IMAGE" \
             --overrides="{\"spec\":{\"serviceAccountName\":\"${IRSA_SA#*/}\"}}" --request-timeout=120s \
             -- sts get-caller-identity --output text --query Arn 2>&1); then
      check active-pod-creds PASS "$IRSA_SA -> $(echo "$out" | grep -o 'arn:[^ ]*' | head -1)"
    else
      check active-pod-creds FAIL "pod credential probe failed for $IRSA_SA"
    fi
  fi
fi

# --- baseline diff --------------------------------------------------------
DIFF='null'
if [[ -n "$BASELINE" && -f "$BASELINE" ]]; then
  DIFF=$(jq -n --slurpfile b "$BASELINE" --argjson c "$SNAP" '
    ($b[0].snapshot // $b[0]) as $o |
    { restartsIncrease: ([$c.pods.restartsByNs | to_entries[] | {ns:.key, delta:(.value - ($o.pods.restartsByNs[.key] // 0))} | select(.delta > 0)] | sort_by(-.delta)),
      newCrashLoop: ($c.pods.crashLoop - $o.pods.crashLoop),
      newDeployUnavailable: ($c.workloads.deployUnavailable - $o.workloads.deployUnavailable),
      newDsNotReady: ($c.workloads.dsNotReady - $o.workloads.dsNotReady),
      newWarningReasons: ([$c.warningEvents | to_entries[] | select((.value) > (($o.warningEvents[.key] // 0) * 2 + 5)) | {reason:.key, now:.value, before:($o.warningEvents[.key] // 0)}]),
      nodes: {before:$o.nodes.total, after:$c.nodes.total},
      metrics: ([$c.metrics | to_entries[] | {name:.key, before:($o.metrics[.key] // null), after:.value}])
    }')
  if [[ "$(jq '(.newCrashLoop|length)+(.newDeployUnavailable|length)+(.newDsNotReady|length)' <<<"$DIFF")" -gt 0 ]]; then
    check baseline-regressions FAIL "$(jq -c '{newCrashLoop,newDeployUnavailable,newDsNotReady}' <<<"$DIFF")"
  else
    check baseline-regressions PASS "no new failing workloads vs baseline"
  fi
fi

FILE="$OUT/verify-$TS.json"
jq -s --argjson s "$SNAP" --argjson d "$DIFF" --arg active "$ACTIVE" \
  '{snapshot:$s, active:($active=="1"), checks:., diff:$d, counts:(group_by(.status)|map({key:.[0].status,value:length})|from_entries)}' \
  "$CHECKS" > "$FILE"
echo "$FILE"
jq -r '.checks[] | "\(.status)\t\(.id)\t\(.detail)"' "$FILE" >&2
jq -e '(.counts.FAIL // 0) == 0' "$FILE" >/dev/null && exit 0 || exit 2
