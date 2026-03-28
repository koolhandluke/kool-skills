# status-report

Generates a daily status report from Jira, GitHub, and Claude sessions, then posts it to Slack.

## Steps

1. Read `config.yaml` (located in the same directory as this SKILL.md) to load credentials and settings. If any required fields are empty (jira.base_url, jira.token, jira.user_email, github.org, github.username, slack.channel), stop and prompt the user to fill them in before proceeding.

2. Run `scripts/state-manager.sh read --lookback-hours <report.lookback_hours>` to get the `since` timestamp for this run.

3. Run the three collectors IN PARALLEL (all using the same `since` timestamp):
   - `scripts/collect-jira.sh --since <since> --email <jira.user_email> --token <jira.token> --base-url <jira.base_url>`
   - `scripts/collect-github.sh --since <since> --org <github.org> --username <github.username>`
   - `scripts/collect-claude.sh --since <since>`

   If any collector fails or returns an error: continue with the remaining sources and note which source was skipped in the final report.

4. Cross-reference GitHub items with Jira tickets:
   - For each GitHub item, check if its `jira_refs` array contains any ticket IDs that also appear in the Jira results
   - Annotate matched GitHub items with the Jira ticket details (status, summary)

5. Load `templates/template.md` and merge collected data into it:
   - `{{JIRA_ITEMS}}`: Format Jira tickets as a bulleted list: `• <ticket_id>: <summary> [<status>] (<url>)`
   - `{{CLAUDE_SESSIONS}}`: Format Claude sessions as a bulleted list: `• <project>: <summary>`
   - `{{#SUGGESTIONS}}...{{/SUGGESTIONS}}`: Only include this section if there are suggestions (omit the block entirely if empty)
   - Include a note about any skipped data sources

6. Post the formatted report to the Slack channel specified in `slack.channel` using the Slack MCP tool:
   - If `slack.post_as_draft` is true: show the formatted report to the user first and ask for confirmation before posting
   - If the Slack MCP tool is unavailable: print the report to the terminal instead and inform the user

7. Run `scripts/state-manager.sh write` to save the current timestamp as the new baseline.

8. Confirm to the user: report posted (or printed), and show the Slack message link if available.

## Error Handling

- **Missing config fields**: Stop immediately and list which fields need to be filled in `config.yaml`
- **Collector failure**: Skip that source, add a note to the report (e.g., "⚠️ Jira data unavailable"), continue
- **Slack MCP unavailable**: Print report to terminal, skip step 7 (state write still happens)
- **State file unreadable**: Fall back to `now - lookback_hours` as the since timestamp
