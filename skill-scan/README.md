# skill-scan

Threat models an external agent skill from GitHub before you import it.

## What it does

Fetches and analyzes a skill's `SKILL.md` at a pinned commit SHA via the GitHub API — no `git clone` needed. Evaluates it across four lenses:

1. **Attacker goals** — what could an adversary do with this skill?
2. **Capability surface** — what tools and permissions does it request?
3. **Instruction semantics** — are there prompt injection or override patterns?
4. **Supply chain** — is the source trustworthy and pinnable?

Produces a structured report with one of three verdicts:

- `APPROVE` — safe to install; includes pinned `git clone / git checkout <sha>` commands
- `CONDITIONAL` — installable with caveats; includes pinned install commands and required mitigations
- `REJECT` — do not install; explains why

## Install


## Installation

```sh
claude plugin marketplace add koolhandluke/kool-skills
claude plugin install skill-scan
```

 
## Usage

```
/skill-scan:scan <github-url>
```

Example:

```
/skill-scan:scan https://github.com/kostasmorfis/kool-skills
```
