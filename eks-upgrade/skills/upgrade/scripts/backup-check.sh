#!/usr/bin/env bash
set -uo pipefail

# Read-only backup readiness gate for an EKS cluster (AWS Backup for EKS).
#
# Usage:
#   ./backup-check.sh --cluster <name> [--region <r>] [--max-age-hours <n, default 6>]
#                     [--vault <name>] [--out <dir>]
#
# Checks:
#   auth-mode          cluster accessConfig.authenticationMode is API or API_AND_CONFIG_MAP
#   recovery-point     newest COMPLETED/AVAILABLE recovery point for the cluster ARN is < max-age
#   child-points       child recovery points (EBS/EFS/S3) of that composite point are all complete
#
# Output: <out>/backup-check.json {cluster, latest:{arn,created,status,vault,ageHours}, checks:[...]}
# Exit: 0 no BLOCK, 2 BLOCK, 1 usage error.

CLUSTER="" REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}" MAXAGE=6 VAULT="" OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)       CLUSTER="$2"; shift 2 ;;
    --region)        REGION="$2"; shift 2 ;;
    --max-age-hours) MAXAGE="$2"; shift 2 ;;
    --vault)         VAULT="$2"; shift 2 ;;
    --out)           OUT="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -z "$CLUSTER" || -z "$REGION" ]] && { echo "Usage: $0 --cluster <c> --region <r> [--max-age-hours n] [--vault v]" >&2; exit 1; }
for bin in aws jq; do command -v "$bin" >/dev/null || { echo "Missing required tool: $bin" >&2; exit 1; }; done

OUT="${OUT:-./eks-upgrade-runs/$CLUSTER/$(date -u +%Y%m%dT%H%M%SZ)}"; mkdir -p "$OUT"
AWSC=(aws --region "$REGION" --output json)
CHECKS=$(mktemp); trap 'rm -f "$CHECKS"' EXIT
check() { jq -nc --arg id "$1" --arg s "$2" --arg d "$3" '{id:$id,status:$s,detail:$d}' >> "$CHECKS"; }

if ! C=$("${AWSC[@]}" eks describe-cluster --name "$CLUSTER" 2>&1); then
  echo "describe-cluster failed: $C" >&2; exit 1
fi
ARN=$(jq -r '.cluster.arn' <<<"$C")
MODE=$(jq -r '.cluster.accessConfig.authenticationMode // "CONFIG_MAP"' <<<"$C")
case "$MODE" in
  API|API_AND_CONFIG_MAP) check auth-mode PASS "$MODE" ;;
  *) check auth-mode BLOCK "authenticationMode=$MODE; AWS Backup needs API or API_AND_CONFIG_MAP (access entries). Change it in its own window." ;;
esac

LATEST='null'
if RP=$("${AWSC[@]}" backup list-recovery-points-by-resource --resource-arn "$ARN" 2>&1); then
  LATEST=$(jq --arg v "$VAULT" '
    [.RecoveryPoints[] | select($v=="" or .BackupVaultName==$v)
     | select(.Status=="COMPLETED" or .Status=="AVAILABLE" or .Status=="PARTIAL")]
    | sort_by(.CreationDate) | last // null' <<<"$RP")
  if [[ "$LATEST" == "null" ]]; then
    check recovery-point BLOCK "No completed recovery point for $ARN${VAULT:+ in vault $VAULT}"
  else
    created=$(jq -r '.CreationDate' <<<"$LATEST")
    if [[ "$created" =~ ^[0-9.]+$ ]]; then epoch=${created%.*}; else epoch=$(date -d "$created" +%s 2>/dev/null || echo 0); fi
    age=$(( ( $(date +%s) - epoch ) / 3600 ))
    status=$(jq -r '.Status' <<<"$LATEST")
    LATEST=$(jq --argjson a "$age" '. + {ageHours:$a}' <<<"$LATEST")
    if [[ "$status" == "PARTIAL" ]]; then
      check recovery-point BLOCK "Latest recovery point is PARTIAL ($created); some resources were not backed up"
    elif (( age > MAXAGE )); then
      check recovery-point BLOCK "Latest recovery point is ${age}h old (> ${MAXAGE}h): $created. Take a fresh backup immediately before the change window."
    else
      check recovery-point PASS "$status, ${age}h old, vault $(jq -r '.BackupVaultName' <<<"$LATEST")"
    fi
    # child recovery points of the composite point (best-effort)
    parent=$(jq -r '.RecoveryPointArn' <<<"$LATEST"); pvault=$(jq -r '.BackupVaultName' <<<"$LATEST")
    if CH=$("${AWSC[@]}" backup list-recovery-points-by-backup-vault --backup-vault-name "$pvault" \
              --by-parent-recovery-point-arn "$parent" 2>/dev/null); then
      jq '[.RecoveryPoints[] | {arn:.RecoveryPointArn, type:.ResourceType, resource:.ResourceArn, status:.Status}]' <<<"$CH" > "$OUT/backup-children.json"
      bad=$(jq -r '[.[] | select(.status!="COMPLETED" and .status!="AVAILABLE") | "\(.type) \(.resource) \(.status)"] | join("; ")' "$OUT/backup-children.json")
      n=$(jq length "$OUT/backup-children.json")
      [[ -z "$bad" ]] && check child-points PASS "$n child recovery points complete" || check child-points BLOCK "Incomplete child points: $bad"
    else
      check child-points SKIP "could not list child recovery points"
    fi
  fi
else
  check recovery-point SKIP "list-recovery-points-by-resource failed: $(head -c 200 <<<"$RP")"
fi

check external-stores WARN "AWS Backup for EKS covers cluster state + PVC-attached EBS/EFS/S3 only. Confirm same-time snapshots of external stores (RDS, Redis, Spinnaker storage) listed in config.yaml backup.external_stores."

jq -s --arg c "$CLUSTER" --arg arn "$ARN" --argjson l "$LATEST" \
  '{cluster:$c, clusterArn:$arn, latest:$l, checks:., counts:(group_by(.status)|map({key:.[0].status,value:length})|from_entries)}' \
  "$CHECKS" > "$OUT/backup-check.json"
echo "$OUT/backup-check.json"
jq -r '.checks[] | "\(.status)\t\(.id)\t\(.detail)"' "$OUT/backup-check.json" >&2
jq -e '(.counts.BLOCK // 0) == 0' "$OUT/backup-check.json" >/dev/null && exit 0 || exit 2
