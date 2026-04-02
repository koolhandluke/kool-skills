# Reference Agent Capability Surface — Enterprise Agent Platform

This file defines a typical capability surface for an enterprise agentic platform.
Used by skill-scan to assess capability intersection risk when the user has not
specified their agent's tools explicitly.

**Customise this file to match your actual platform before use.**
Last updated: 2026-04

---

## Tier 1 — High Risk Capabilities

These capabilities have direct impact on systems, data, or infrastructure.
Any skill instruction that could invoke these is automatically elevated to HIGH or CRITICAL.

| Capability | Tool | What it can access |
|---|---|---|
| Shell execution | `bash_tool` | Host filesystem, env vars, network, process execution |
| File write | `create_file`, `str_replace` | Agent working directory, any writable path |
| Code execution | `bash_tool` + Python/Node | Arbitrary computation, can install packages |
| Web fetch | `web_fetch` | Any URL — can exfiltrate data via HTTP POST |
| Outbound HTTP | `web_search`, `web_fetch` | External internet (subject to egress policy) |

## Tier 2 — Medium Risk Capabilities

These capabilities expose data or enable lateral movement but have more limited blast radius.

| Capability | Tool | What it can access |
|---|---|---|
| GitHub | MCP/GitHub | Repos, PRs, issues, Actions — all orgs the agent is authed to |
| Jira | MCP/Jira | Tickets, project data, comments, attachments |
| Slack | MCP/Slack | Messages, channels, DMs, files — all workspaces the agent is authed to |
| Google Drive | MCP/GDrive | All Drive files the authed user can access |
| AWS | MCP/AWS or CLI | IAM-scoped access to configured AWS accounts |
| Kubernetes | MCP/k8s | Cluster resources in configured contexts |

## Tier 3 — Lower Risk Capabilities

Limited blast radius. Elevated only if paired with Tier 1/2 capabilities.

| Capability | Tool | What it can access |
|---|---|---|
| Read files | `view`, `read_file` | Files in agent working directory and allowed paths |
| Web search | `web_search` | Read-only web access, query contents visible in results |
| Image generation | Visualizer | Output only, no external data access |
| Calendar | MCP/GCal | Read/write to authed user's calendar |
| Email | MCP/Gmail | Read/write to authed user's Gmail |

---

## High-Risk Combinations

Flag any skill that could combine these pairs — the combination is more dangerous
than either capability alone:

| Combination | Why Dangerous |
|---|---|
| `web_fetch` (POST) + any data read | Exfiltration pipeline |
| `bash_tool` + `web_fetch` | Remote code download and execution |
| GitHub + Jira | Can correlate code changes with ticket data → IP exposure |
| Slack + any file read | Can exfiltrate file contents via Slack DM |
| AWS + bash_tool | Can assume roles, modify IAM, access S3 |
| Email + any data read | Can email sensitive data to external addresses |

---

## Egress Controls

Do NOT assume egress restrictions make exfiltration impossible —
skills can use allowed SaaS services as covert channels (Slack, GitHub, GDrive).
Verify your platform's egress filtering policy and list any restricted domains here.

## Authentication Context

Agents typically run with the authenticated user's credentials. This means:
- A skill that makes a GitHub API call has the user's full GitHub access
- A skill that sends Slack messages does so as the user
- A skill that modifies Jira tickets can touch any project the user has access to

This is the most important context for threat modeling: **the agent's blast radius
is the user's blast radius**, amplified by speed and reduced by human oversight.
