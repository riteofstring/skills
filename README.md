# skills

Agent skills by riteofstring. Each skill is a top-level folder with a
`SKILL.md`, and works in Claude Code, Codex and other agents that read the
same format.

## Skills

Use **overseer** to build something and **council** to polish and iterate on
it. They work on their own or in sequence: overseer can hand its verified
result to council.

- [**overseer**](overseer/SKILL.md), for building: supervised, systematic
  work. That's code, but also documents, research, data or content batches.
  Two reviewers must agree on the plan before work starts, a delegated worker
  does it, the coordinator checks the result against evidence, a read-only
  auditor digs through it, and fresh scope and direction checks run at each
  checkpoint. If you ask for polish or a target score up front, it hands the
  verified result to council.
- [**council**](council/SKILL.md), for polish and iteration: fresh,
  independent reviewer agents score the work out of 10 from chosen
  perspectives (design, UX, marketing, performance and so on). The main agent
  fixes what they find, and new reviewers score it again until every reviewer
  reaches the target score, or until the feedback stops being useful. Has a
  `polish` mode for detail-oriented finish.

## Install

```bash
npx skills add riteofstring/skills
```

Or copy or symlink a skill folder into `~/.claude/skills/` (Claude Code) or
`~/.agents/skills/` (Codex and others).

## Use

```text
/overseer add per-machine sorting and pinning
/overseer write phonetic spellings for the 400 new words, checked against the rules doc
/overseer add a credentials page, then polish design and UX to 9 with council
/council design and UX for the settings screens, target 9
/council polish the landing page
```

The third line builds under overseer first. Once the build is verified, it
reports back and runs council on the result with a target of 9.
