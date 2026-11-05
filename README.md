# skills

Agent skills by riteofstring. Each skill is a top-level folder with a
`SKILL.md`, and works in Claude Code, Codex and other agents that read the
same format.

## Skills

- [**council**](council/SKILL.md): a council of fresh, independent
  reviewer agents score the work out of 10 from chosen perspectives (design,
  UX, marketing, performance and so on). The main agent fixes what they find,
  and new reviewers score it again until every reviewer reaches the target
  score, or until the feedback stops being useful. Has a `polish` mode for
  detail-oriented finish.
- [**overseer**](overseer/SKILL.md): supervised
  implementation. Two reviewers must agree on the plan before any code, a
  delegated coder builds it, the coordinator checks the work against evidence,
  and fresh scope and direction checks run at each checkpoint.

## Install

```bash
npx skills add riteofstring/skills
```

Or copy or symlink a skill folder into `~/.claude/skills/` (Claude Code) or
`~/.agents/skills/` (Codex and others).

## Use

```text
/council design and UX for the settings screens, target 9
/council polish the landing page
/overseer add per-machine sorting and pinning
```
