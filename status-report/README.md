# status-report

Generates a daily status report from Jira, GitHub, and Claude sessions, then posts it to Slack.

## Installation

```sh
claude plugin install github:koolhandluke/kool-skills/skills/status-report
```

Or install the full collection:

```sh
claude plugin install github:koolhandluke/kool-skills
```

## Directory Structure

```
skills/status-report/
├── SKILL.md             # Skill instructions
├── config.yaml          # User-editable credentials and settings
├── scripts/             # Data collectors and state manager
├── templates/           # Output templates
│   └── template.md      # Slack message template
├── references/          # (optional) Documentation loaded as needed
├── assets/              # (optional) Templates, fonts, icons used in output
└── state/               # Runtime state (last-run timestamps)
```

## Setup

After installing, edit `skills/status-report/config.yaml` with your credentials:

```yaml
jira:
  base_url: https://your-org.atlassian.net
  token: your-jira-api-token
  user_email: you@example.com

github:
  org: your-github-org
  username: your-github-username

slack:
  channel: "#your-channel"
  post_as_draft: true   # set to false to post without confirmation
```

### Required fields

| Field | Description |
|-------|-------------|
| `jira.base_url` | Your Atlassian instance URL |
| `jira.token` | Jira API token |
| `jira.user_email` | Email associated with the Jira token |
| `github.org` | GitHub org to query |
| `github.username` | Your GitHub username |
| `slack.channel` | Slack channel to post to |

### Prerequisites

- **Slack MCP** — required to post reports to Slack. If unavailable, the report is printed to the terminal instead.

## Usage

Invoke the skill in Claude Code:

```
/status-report
```

Claude will collect activity from Jira, GitHub, and local Claude sessions since the last run, merge it into the report template, and post it to Slack.

## License

MIT
