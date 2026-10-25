# Label Convention

Canonical label vocabulary — names, colors, descriptions, the tiering rule,
issue-title convention, role aliases, the remove-stock checklist, and the
`ready-for-agent` merge authority — lives in `dividedby/skills`
[`docs/agents/labels.md`](https://github.com/dividedby/skills/blob/main/docs/agents/labels.md).
Apply it as-is in this repo; this file does not duplicate it.

## Repo-local limit on `ready-for-agent`

`ready-for-agent` merge authority never overrides the "Ask the owner first" list in
[`AGENTS.md`](../../AGENTS.md): an agent working such an issue still stops for owner
approval at every item on that list.
