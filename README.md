# kool-skills

![kool-skills](kool-skills.png)

A collection of Claude Code skills by [Kostas Morfis](https://github.com/koolhandluke).

## Skills

| Skill | Description |
|-------|-------------|
| [status-report](status-report/) | Generates daily status reports from Jira, GitHub, and Claude sessions |
| [example-skill](example-skill/) | Template for creating new skills |

## Installation

### Add the marketplace

First, register the kool-skills marketplace:

```sh
claude plugin marketplace add koolhandluke/kool-skills
```

### Install a skill

```sh
claude plugin install status-report
claude plugin install example-skill
```

### Manual install

Clone the repo and install from a local path:

```sh
git clone https://github.com/koolhandluke/kool-skills.git
claude plugin marketplace add ./kool-skills
claude plugin install status-report
```

## Creating a New Skill

Use the `example-skill` as a starting point:

1. Copy `example-skill/` to `your-skill-name/`
2. Rename inner directories and files to match your skill name
3. Update `plugin.json` with your skill's name, description, and version
4. Write your skill content in `SKILL.md`
5. Add an entry to `.claude-plugin/marketplace.json`

## License

MIT
