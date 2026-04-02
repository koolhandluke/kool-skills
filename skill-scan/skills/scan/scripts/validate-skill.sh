#!/usr/bin/env bash
# =============================================================================
# validate-skill.sh — Agent Skill Safety Validator
# Usage: ./validate-skill.sh <path-to-skill-dir>
# =============================================================================
set -euo pipefail

SKILL_DIR="${1:-./skill}"
SKILL_FILE="$SKILL_DIR/SKILL.md"
REPORT_FILE="skill-validation-report.md"
PASS=0
WARN=0
FAIL=0

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

pass()  { echo -e "${GREEN}✅ PASS${RESET}  $1"; ((PASS++));  echo "- ✅ PASS: $1"  >> "$REPORT_FILE"; }
warn()  { echo -e "${YELLOW}⚠️  WARN${RESET}  $1"; ((WARN++));  echo "- ⚠️  WARN: $1"  >> "$REPORT_FILE"; }
fail()  { echo -e "${RED}❌ FAIL${RESET}  $1"; ((FAIL++));  echo "- ❌ FAIL: $1"  >> "$REPORT_FILE"; }
header(){ echo -e "\n${BOLD}${BLUE}━━━ $1 ━━━${RESET}"; echo -e "\n### $1" >> "$REPORT_FILE"; }

# ── Init report ───────────────────────────────────────────────────────────────
cat > "$REPORT_FILE" <<EOF
# Skill Validation Report
**Skill:** \`$SKILL_DIR\`
**Date:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")

EOF

echo -e "${BOLD}Validating skill: ${BLUE}$SKILL_DIR${RESET}\n"


# =============================================================================
# STEP 1 — STRUCTURE & METADATA
# =============================================================================
header "STEP 1 — Structure & Metadata"

[[ -f "$SKILL_FILE" ]] \
  && pass "SKILL.md exists" \
  || { fail "SKILL.md not found at $SKILL_FILE"; exit 1; }

# Required frontmatter fields
for field in "name:" "description:"; do
  grep -q "^$field" "$SKILL_FILE" \
    && pass "Frontmatter field '$field' present" \
    || fail "Frontmatter field '$field' missing"
done

# File size sanity (>50KB skill files are suspicious / expensive)
SIZE_KB=$(du -k "$SKILL_FILE" | cut -f1)
[[ $SIZE_KB -lt 50 ]] \
  && pass "SKILL.md size is reasonable (${SIZE_KB}KB)" \
  || warn "SKILL.md is large (${SIZE_KB}KB) — may increase token cost and attack surface"

# Check for required sections
for section in "## " "###"; do
  grep -q "$section" "$SKILL_FILE" \
    && pass "Skill has structured sections ($section)" \
    || warn "Skill lacks structured sections — harder to review"
done


# =============================================================================
# STEP 2 — PROMPT INJECTION DETECTION
# =============================================================================
header "STEP 2 — Prompt Injection Patterns"

INJECTION_PATTERNS=(
  "ignore previous instructions"
  "ignore all instructions"
  "disregard your"
  "forget your instructions"
  "you are now"
  "pretend you are"
  "act as if you"
  "new persona"
  "system override"
  "admin override"
  "developer mode"
  "jailbreak"
  "DAN mode"
  "bypass.*safety"
  "ignore.*safety"
  "disable.*safety"
  "\\\\x[0-9a-f]{2}"   # hex encoding
  "base64"              # may indicate encoded payload
  "eval("              # code execution
  "exec("
)

INJECTION_FOUND=0
for pattern in "${INJECTION_PATTERNS[@]}"; do
  if grep -iEq "$pattern" "$SKILL_FILE" 2>/dev/null; then
    fail "Prompt injection pattern found: '$pattern'"
    grep -iEn "$pattern" "$SKILL_FILE" | head -3 | while read -r line; do
      echo "       Line: $line"
    done
    INJECTION_FOUND=1
  fi
done
[[ $INJECTION_FOUND -eq 0 ]] && pass "No prompt injection patterns detected"

# Check for suspicious Unicode / homoglyph characters
if python3 -c "
import sys, re
text = open('$SKILL_FILE').read()
suspicious = [c for c in text if ord(c) > 127 and ord(c) < 32768 and c not in 'àáâãäåæçèéêëìíîïðñòóôõöùúûüýþÿ']
if suspicious:
    print('Found suspicious chars:', set(suspicious[:10]))
    sys.exit(1)
" 2>/dev/null; then
  pass "No suspicious Unicode/homoglyph characters"
else
  warn "Suspicious Unicode characters detected — manual review needed"
fi

# Check for hidden text (zero-width chars)
if grep -Pq "[\x{200b}-\x{200f}\x{202a}-\x{202e}\x{feff}]" "$SKILL_FILE" 2>/dev/null; then
  fail "Zero-width / invisible characters found — likely injection attempt"
else
  pass "No zero-width or invisible characters"
fi


# =============================================================================
# STEP 3 — SECRETS & CREDENTIAL LEAKAGE
# =============================================================================
header "STEP 3 — Secrets & Credential Leakage"

SECRET_PATTERNS=(
  "sk-[a-zA-Z0-9]{20,}"           # OpenAI / Anthropic style keys
  "AKIA[0-9A-Z]{16}"              # AWS Access Key ID
  "ghp_[a-zA-Z0-9]{36}"          # GitHub personal token
  "glpat-[a-zA-Z0-9_-]{20}"      # GitLab token
  "xoxb-[0-9]+-"                  # Slack bot token
  "xoxp-[0-9]+-"                  # Slack user token
  "Bearer [a-zA-Z0-9+/=]{20,}"   # Generic Bearer token
  "password\s*[:=]\s*['\"][^'\"]{6,}"  # Hardcoded passwords
  "api[_-]?key\s*[:=]\s*['\"][^'\"]{8,}"  # API keys
  "secret\s*[:=]\s*['\"][^'\"]{8,}"       # Generic secrets
  "private_key"                    # Private key material
  "-----BEGIN.*PRIVATE KEY-----"   # PEM private key
)

SECRETS_FOUND=0
for pattern in "${SECRET_PATTERNS[@]}"; do
  if grep -iEq "$pattern" "$SKILL_FILE" 2>/dev/null; then
    fail "Potential credential pattern found: '$pattern'"
    SECRETS_FOUND=1
  fi
done
[[ $SECRETS_FOUND -eq 0 ]] && pass "No hardcoded secrets or credentials detected"


# =============================================================================
# STEP 4 — PACKAGE & DEPENDENCY SAFETY
# =============================================================================
header "STEP 4 — Package & Dependency Safety"

# Check for package references (npm, pip, etc.)
if grep -Eq "(npm install|pip install|yarn add|gem install)" "$SKILL_FILE"; then
  warn "Skill references package installation — verify packages are pinned to exact versions"
  
  # Check for version pinning
  if grep -Eq "(npm install|pip install) [a-zA-Z]" "$SKILL_FILE"; then
    if ! grep -Eq "(npm install|pip install) [a-zA-Z@][^@\n]+==[0-9]|@[0-9]" "$SKILL_FILE"; then
      warn "Packages may not be pinned to exact versions — supply chain risk"
    else
      pass "Package references appear to use pinned versions"
    fi
  fi

  # Check for suspicious package names (typosquatting signals)
  SUSPICIOUS_PKGS=(
    "cros-fetch" "node-fetchh" "lodahs" "axois" "reqests"
    "colourama" "python-dateutil2" "urlib3" "setup-tools"
  )
  for pkg in "${SUSPICIOUS_PKGS[@]}"; do
    grep -iq "$pkg" "$SKILL_FILE" \
      && fail "Known typosquatted package name detected: $pkg"
  done
  pass "No known typosquatted packages found"
else
  pass "No package installation instructions (lower supply chain risk)"
fi

# Check for external URLs that aren't well-known domains
EXTERNAL_URLS=$(grep -oE "https?://[^[:space:]\"')>]+" "$SKILL_FILE" 2>/dev/null | \
  grep -vE "(github\.com|npmjs\.com|pypi\.org|docs\.|anthropic\.com|registry\.npmjs)" || true)
if [[ -n "$EXTERNAL_URLS" ]]; then
  warn "External URLs to non-standard domains found — review manually:"
  echo "$EXTERNAL_URLS" | while read -r url; do
    echo "       → $url"
  done
else
  pass "All external URLs are to recognized/trusted domains"
fi


# =============================================================================
# STEP 5 — TOOL & PERMISSION SCOPE
# =============================================================================
header "STEP 5 — Tool & Permission Scope"

# Dangerous tool combinations
DANGEROUS_TOOLS=(
  "bash_tool\|execute.*shell\|run.*command"
  "file.*delete\|rm -rf\|unlink"
  "curl.*-o\|wget\|download"
  "sudo\|chmod 777\|chown root"
  "docker.*run\|kubectl.*exec"
  "eval\|exec()"
)

TOOL_RISK=0
for pattern in "${DANGEROUS_TOOLS[@]}"; do
  if grep -iEq "$pattern" "$SKILL_FILE" 2>/dev/null; then
    warn "High-privilege tool usage pattern found: '$pattern' — ensure scope is necessary"
    TOOL_RISK=1
  fi
done
[[ $TOOL_RISK -eq 0 ]] && pass "No high-privilege tool patterns detected"

# Check for data exfiltration patterns
EXFIL_PATTERNS=(
  "send.*to.*external"
  "POST.*http"
  "webhook"
  "exfil"
  "upload.*to"
)
EXFIL_FOUND=0
for pattern in "${EXFIL_PATTERNS[@]}"; do
  if grep -iEq "$pattern" "$SKILL_FILE" 2>/dev/null; then
    warn "Potential data egress instruction: '$pattern' — verify this is intentional"
    EXFIL_FOUND=1
  fi
done
[[ $EXFIL_FOUND -eq 0 ]] && pass "No data exfiltration patterns detected"

# Check skill declares its tool requirements
if grep -iq "tool\|requires\|permission\|access" "$SKILL_FILE"; then
  pass "Skill appears to document tool requirements"
else
  warn "Skill does not explicitly document required tools/permissions"
fi


# =============================================================================
# STEP 6 — SCOPE CREEP & BLAST RADIUS
# =============================================================================
header "STEP 6 — Scope Creep & Blast Radius"

# Skills should be focused — flag if they do too many things
HEADING_COUNT=$(grep -c "^## " "$SKILL_FILE" || true)
if [[ $HEADING_COUNT -le 8 ]]; then
  pass "Skill scope appears focused ($HEADING_COUNT top-level sections)"
elif [[ $HEADING_COUNT -le 15 ]]; then
  warn "Skill has $HEADING_COUNT sections — consider splitting into focused sub-skills"
else
  fail "Skill has $HEADING_COUNT sections — too broad, high blast radius risk"
fi

# Check for catch-all instructions
CATCHALL_PATTERNS=(
  "do anything"
  "do everything"
  "complete all tasks"
  "handle all"
  "any request"
  "always comply"
  "never refuse"
)
CATCHALL_FOUND=0
for pattern in "${CATCHALL_PATTERNS[@]}"; do
  if grep -iEq "$pattern" "$SKILL_FILE" 2>/dev/null; then
    fail "Catch-all permissive instruction found: '$pattern' — scope this skill more tightly"
    CATCHALL_FOUND=1
  fi
done
[[ $CATCHALL_FOUND -eq 0 ]] && pass "No overly permissive catch-all instructions"


# =============================================================================
# STEP 7 — SUPPLY CHAIN: REFERENCED SCRIPTS & ACTIONS
# =============================================================================
header "STEP 7 — Supply Chain: External Script References"

# Check for curl | bash / pipe-to-shell patterns
if grep -Eq "curl.*\|.*bash|wget.*\|.*sh|curl.*\|.*sh" "$SKILL_FILE" 2>/dev/null; then
  fail "CRITICAL: curl|bash or wget|sh pattern found — never pipe untrusted scripts to shell"
else
  pass "No curl|bash or pipe-to-shell patterns"
fi

# Check for GitHub Actions usage without SHA pinning (if skill references workflows)
if grep -Eq "uses: [a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+@" "$SKILL_FILE" 2>/dev/null; then
  if grep -Eq "uses: [a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+@(main|master|latest|v[0-9])" "$SKILL_FILE"; then
    fail "GitHub Action references not pinned to SHA — supply chain risk"
  else
    pass "GitHub Action references appear SHA-pinned"
  fi
fi


# =============================================================================
# STEP 8 — LLM-ASSISTED SEMANTIC REVIEW (via Anthropic API)
# =============================================================================
header "STEP 8 — LLM Semantic Safety Review"

if command -v python3 &>/dev/null && python3 -c "import anthropic" 2>/dev/null; then
  echo "  Running LLM-assisted review..."
  
  SKILL_CONTENT=$(cat "$SKILL_FILE")
  
  LLM_RESULT=$(python3 <<PYEOF
import anthropic, json, sys

client = anthropic.Anthropic()

skill_content = """$SKILL_CONTENT"""

prompt = f"""You are a security auditor for AI agent skills. Review this SKILL.md file for safety issues.

<skill_content>
{skill_content}
</skill_content>

Analyze for:
1. Prompt injection vulnerabilities
2. Privilege escalation attempts
3. Data exfiltration instructions
4. Ambiguous or overly broad permissions
5. Social engineering of the agent
6. Instructions that could cause unintended side effects

Respond ONLY with valid JSON in this exact format:
{{
  "overall_risk": "LOW|MEDIUM|HIGH|CRITICAL",
  "findings": [
    {{"severity": "CRITICAL|HIGH|MEDIUM|LOW", "issue": "description", "line_hint": "relevant text snippet"}}
  ],
  "summary": "2-sentence assessment"
}}"""

try:
    message = client.messages.create(
        model="claude-opus-4-5",
        max_tokens=1024,
        messages=[{"role": "user", "content": prompt}]
    )
    print(message.content[0].text)
except Exception as e:
    print(json.dumps({"overall_risk": "UNKNOWN", "findings": [], "summary": f"LLM review failed: {e}"}))
PYEOF
  )

  # Parse and display LLM results
  echo "$LLM_RESULT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    risk = data.get('overall_risk', 'UNKNOWN')
    summary = data.get('summary', '')
    findings = data.get('findings', [])
    
    colors = {'CRITICAL': '\033[0;31m', 'HIGH': '\033[0;31m', 'MEDIUM': '\033[1;33m', 
              'LOW': '\033[0;32m', 'UNKNOWN': '\033[0;34m'}
    reset = '\033[0m'
    color = colors.get(risk, reset)
    
    print(f'  Overall Risk: {color}{risk}{reset}')
    print(f'  Summary: {summary}')
    if findings:
        print('  Findings:')
        for f in findings:
            sev = f.get('severity', '?')
            c = colors.get(sev, reset)
            print(f'    {c}[{sev}]{reset} {f.get(\"issue\", \"\")}')
            if f.get('line_hint'):
                print(f'           ↳ \"{f[\"line_hint\"][:80]}\"')
except:
    print('  Could not parse LLM response')
" 2>/dev/null || warn "LLM review output could not be parsed"

  echo "$LLM_RESULT" >> "$REPORT_FILE"
else
  warn "anthropic Python SDK not found — skipping LLM semantic review (pip install anthropic)"
fi


# =============================================================================
# STEP 9 — SBOM / DEPENDENCY MANIFEST CHECK
# =============================================================================
header "STEP 9 — Dependency Manifest (SBOM)"

MANIFEST_FILES=(
  "$SKILL_DIR/package.json"
  "$SKILL_DIR/requirements.txt"
  "$SKILL_DIR/Pipfile.lock"
  "$SKILL_DIR/package-lock.json"
  "$SKILL_DIR/yarn.lock"
  "$SKILL_DIR/pyproject.toml"
)

MANIFEST_FOUND=0
for f in "${MANIFEST_FILES[@]}"; do
  if [[ -f "$f" ]]; then
    MANIFEST_FOUND=1
    pass "Dependency manifest found: $(basename $f)"
    
    # Check for lockfile presence alongside manifest
    if [[ "$(basename $f)" == "package.json" ]] && [[ ! -f "$SKILL_DIR/package-lock.json" ]] && [[ ! -f "$SKILL_DIR/yarn.lock" ]]; then
      warn "package.json present but no lockfile — dependency versions not locked"
    fi
    if [[ "$(basename $f)" == "requirements.txt" ]]; then
      # Check all deps are pinned (==)
      if grep -Eq "^[a-zA-Z]" "$f" && ! grep -vq "==" "$f" 2>/dev/null; then
        pass "requirements.txt uses pinned versions (==)"
      else
        warn "requirements.txt may have unpinned dependencies"
      fi
    fi
  fi
done

[[ $MANIFEST_FOUND -eq 0 ]] && warn "No dependency manifest found — if skill uses packages, add one"


# =============================================================================
# STEP 10 — TOOL SCAN INTEGRATION (Snyk / Trivy / Agentic Radar)
# =============================================================================
header "STEP 10 — External Scanner Integration"

# Snyk
if command -v snyk &>/dev/null; then
  echo "  Running Snyk scan..."
  snyk test "$SKILL_DIR" --json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
vulns = data.get('vulnerabilities', [])
critical = [v for v in vulns if v.get('severity') == 'critical']
high = [v for v in vulns if v.get('severity') == 'high']
print(f'  Snyk: {len(critical)} critical, {len(high)} high vulnerabilities')
" 2>/dev/null || warn "Snyk scan failed or no manifest to scan"
else
  warn "snyk not installed — skipping (brew install snyk)"
fi

# Trivy
if command -v trivy &>/dev/null; then
  echo "  Running Trivy fs scan..."
  trivy fs --quiet --exit-code 0 --format table "$SKILL_DIR" 2>/dev/null \
    && pass "Trivy scan complete (check table above for findings)" \
    || warn "Trivy scan returned non-zero exit"
else
  warn "trivy not installed — skipping (brew install trivy)"
fi

# Gitleaks (secrets in git history)
if command -v gitleaks &>/dev/null; then
  gitleaks detect --source "$SKILL_DIR" --no-git --quiet 2>/dev/null \
    && pass "Gitleaks: no secrets found in skill files" \
    || fail "Gitleaks: secrets detected in skill directory"
else
  warn "gitleaks not installed — skipping (brew install gitleaks)"
fi


# =============================================================================
# FINAL REPORT
# =============================================================================
echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}Validation Complete${RESET}"
echo -e "  ${GREEN}✅ Passed:   $PASS${RESET}"
echo -e "  ${YELLOW}⚠️  Warnings: $WARN${RESET}"
echo -e "  ${RED}❌ Failed:   $FAIL${RESET}"

{
  echo ""
  echo "---"
  echo "**Results:** ✅ $PASS passed | ⚠️ $WARN warnings | ❌ $FAIL failed"
} >> "$REPORT_FILE"

echo -e "\nFull report → ${BLUE}$REPORT_FILE${RESET}"

# Exit non-zero if any failures
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
