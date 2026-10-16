#!/usr/bin/env bash
set -euo pipefail

# Scans IaC / Helm / Flux / pipeline templates / scripts for upgrade hazards.
#
# Usage:
#   ./scan-repo.sh --target <minor> <path> [<path>...]
#
# Output:
#   JSON array to stdout:
#   [{ "rule": "...", "severity": "high|medium|low", "file": "...", "line": 12,
#      "text": "...", "why": "..." }]

TARGET=""
PATHS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    -*) echo "Unknown argument: $1" >&2; exit 1 ;;
    *) PATHS+=("$1"); shift ;;
  esac
done
[[ -z "$TARGET" ]] && { echo "Usage: $0 --target <minor> <path>..." >&2; exit 1; }
[[ ${#PATHS[@]} -eq 0 ]] && { echo "Usage: $0 --target <minor> <path>..." >&2; exit 1; }
command -v jq >/dev/null || { echo "Missing required tool: jq" >&2; exit 1; }

# rule~severity~ERE pattern~why  ('~' delimiter: patterns may contain '|')
RULES=$(cat <<'EOF'
kube-proxy-version~high~kubeProxyVersion~status.nodeInfo.kubeProxyVersion is no longer populated as of 1.33; scripts/dashboards reading it break.
al2-ami-type~high~(ami_?[Tt]ype|amiType)["':= ]+["']?AL2_~AL2 EKS-optimized AMIs are not published for 1.33+; migrate to AL2023/Bottlerocket first.
al2-bootstrap~high~/etc/eks/bootstrap\.sh~AL2 bootstrap.sh does not exist on AL2023; use nodeadm NodeConfig.
al2-ssm-param~medium~/aws/service/eks/optimized-ami/[0-9.]+/amazon-linux-2/~SSM parameter for AL2 AMI; no 1.33+ values.
flowcontrol-v1beta3~high~flowcontrol\.apiserver\.k8s\.io/v1beta3~Removed in 1.32; dormant templates/charts will fail to apply. Use flowcontrol.apiserver.k8s.io/v1.
flowcontrol-v1beta2~high~flowcontrol\.apiserver\.k8s\.io/v1beta[12]~Removed in 1.29 or earlier. Use v1.
endpoints-kind~medium~^[[:space:]]*kind:[[:space:]]*Endpoints[[:space:]]*$~core/v1 Endpoints is deprecated in 1.33 (not removed). Prefer EndpointSlice for consumers; manual Endpoints for selectorless Services still works.
endpoints-rbac~low~resources:.*["'\[ ,]endpoints["'\], ]~RBAC grants on Endpoints; consumers should move to discovery.k8s.io endpointslices.
endpoints-client~medium~(CoreV1\(\)\.Endpoints\(|get[[:space:]]+endpoints|list_namespaced_endpoints|readNamespacedEndpoints)~Code reads v1 Endpoints; migrate to EndpointSlice API.
cluster-version-pin~low~(cluster_version|kubernetes_version|kubernetesVersion|version)["':= ]+["']?1\.[0-9]{2}["']?[[:space:]]*$~Pinned Kubernetes version; update in the same PR as the corresponding change window.
autoscaler-image~medium~cluster-autoscaler:v?1\.[0-9]{2}~Cluster Autoscaler must match the target Kubernetes minor after the control-plane upgrade.
imds-hop-limit~low~http_put_response_hop_limit|httpPutResponseHopLimit~Check hop limit for AL2023 (default 1 without LT); pods using node-role creds need 2 or IRSA/Pod Identity.
cgroup-v1~medium~cgroup(fs)?[ _-]?v1|/sys/fs/cgroup/(memory|cpu)/~AL2023 uses cgroup v2; v1 paths/assumptions break (old JVMs, monitoring agents).
docker-sock~medium~/var/run/docker\.sock~dockershim is gone; workloads mounting docker.sock break.
EOF
)

TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
while IFS='~' read -r rule sev pat why; do
  [[ -z "$rule" ]] && continue
  grep -rnIE --exclude-dir={.git,node_modules,vendor,.terraform,eks-upgrade-runs} \
       --include='*.yaml' --include='*.yml' --include='*.json' --include='*.tf' --include='*.tfvars' \
       --include='*.hcl' --include='*.tpl' --include='*.j2' --include='*.sh' --include='*.py' --include='*.go' \
       --include='*.js' --include='*.ts' --include='*.java' --include='*.groovy' --include='*.jsonnet' \
       --include='*.libsonnet' --include='Dockerfile' --include='Jenkinsfile' \
       -e "$pat" "${PATHS[@]}" 2>/dev/null \
  | while IFS= read -r hit; do
      file=${hit%%:*}; rest=${hit#*:}; line=${rest%%:*}; text=${rest#*:}
      jq -nc --arg r "$rule" --arg s "$sev" --arg f "$file" --argjson l "$line" \
             --arg t "$(echo "$text" | cut -c1-200)" --arg w "$why" \
             '{rule:$r,severity:$s,file:$f,line:$l,text:$t,why:$w}'
    done >> "$TMP" || true
done <<< "$RULES"

jq -s --arg t "$TARGET" 'sort_by(({"high":0,"medium":1,"low":2}[.severity]), .file, .line)' "$TMP"
