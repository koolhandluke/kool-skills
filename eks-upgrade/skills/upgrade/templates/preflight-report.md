# EKS Upgrade Preflight — {{CLUSTER}} ({{REGION}})

| | |
|---|---|
| Current → target | {{CURRENT}} → {{TARGET}} |
| Verdict | **{{VERDICT}}** (READY / READY WITH WARNINGS / NOT READY) |
| Generated | {{GENERATED_AT}} by {{CALLER_ARN}} |
| Run directory | `{{RUN_DIR}}` |
| Support policy | {{SUPPORT_TYPE}} |

## Blockers

<!-- One row per BLOCK. Fix = concrete action incl. pinned version / resource name. Window = which change window fixes it. -->
| Check | Finding | Fix | Change window |
|---|---|---|---|
{{BLOCK_ROWS}}

## Warnings

| Check | Finding | Decision / owner |
|---|---|---|
{{WARN_ROWS}}

## Add-ons

| Add-on | Current | Valid on {{TARGET}} | Target default | Proposed pre-upgrade pin |
|---|---|---|---|---|
{{ADDON_ROWS}}

## Node groups

| Node group | Version | AMI type | Release | IMDS hop limit | Action |
|---|---|---|---|---|---|
{{NODEGROUP_ROWS}}

## Repo scan (if run)

{{SCAN_SUMMARY}}

## Notes

- Upgrade insights use a 30-day lookback; a resolved issue can still show ERROR. Evidence of the fix: {{INSIGHT_EVIDENCE}}
- Passed checks: {{PASS_LIST}}
- Skipped checks (could not run): {{SKIP_LIST}}
