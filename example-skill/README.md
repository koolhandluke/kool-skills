# example-skill

A template demonstrating the expected file structure and frontmatter format for skills in this repo. Use it as a starting point when creating a new skill.

## Installation

```sh
claude plugin install github:koolhandluke/kool-skills/skills/example-skill
```

Or install the full collection:

```sh
claude plugin install github:koolhandluke/kool-skills
```

## Creating a New Skill from This Template

1. Copy this directory to `skills/your-skill-name/`
2. Rename inner directories and files to match your skill name
3. Update `.claude-plugin/plugin.json` with your skill's name, description, and version
4. Write your skill content in `skills/your-skill-name/SKILL.md`
5. Add an entry to the root `.claude-plugin/marketplace.json`

## License

MIT
