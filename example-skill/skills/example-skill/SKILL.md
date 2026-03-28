---
name: example-skill
description: Use when you need a template to understand how skills in this repo are structured
---

# Example Skill

## Overview
This is a placeholder skill demonstrating the expected file structure and frontmatter format.

## When to Use
- When you need to understand the skill file format
- As a copy-paste starting point for adding new skills to this repo

## Directory Structure

```
skills/your-skill-name/
├── .claude-plugin/
│   └── plugin.json          # Skill metadata (name, version, description)
├── skills/your-skill-name/
│   ├── SKILL.md             # Skill instructions (this file)
│   ├── config.yaml          # (optional) User-editable configuration
│   ├── scripts/             # (optional) Shell scripts invoked by the skill
│   ├── templates/           # (optional) Output templates (e.g. template.md)
│   ├── references/          # (optional) Documentation loaded as needed
│   ├── assets/              # (optional) Templates, fonts, icons used in output
│   └── state/               # (optional) Runtime state persisted between runs
└── README.md
```

## Process
1. Copy `skills/example-skill/` to `skills/your-skill-name/`
2. Rename directories and files to match your skill name
3. Update `plugin.json` with your skill's name, description, and version
4. Write your skill content in `SKILL.md`
5. Add an entry to `.claude-plugin/marketplace.json`
