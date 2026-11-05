# skills

Agent skills by riteofstring. Each skill is a top-level folder with a
`SKILL.md`, and works in Claude Code, Codex and other agents that read the
same format.

## Skills

Use **overseer** to build something and **council** to polish and iterate on
it. They work on their own or in sequence: overseer can hand its verified
result to council.

- [**overseer**](overseer/SKILL.md), for building: gets systematic work done
  and verified. That's code, but also documents, research, data or content
  batches. Three modes:
  - `fast` (default): the agent builds directly and checks the result against
    your description, including visually, with no reviews or tests yet.
  - `heavy`: two reviewers agree on the plan first, a delegated worker builds
    it, then tests, a read-only audit, and scope and direction checks.
  - `medium`: a fast pass until it works, then a heavy pass over the result.

  If you ask for polish or a target score up front, it hands the verified
  result to council.
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
/overseer heavy migrate the billing tables to the new schema
/overseer medium write phonetic spellings for the 400 new words, checked against the rules doc
/overseer medium add a credentials page, then polish design and UX to 9 with council
/council design and UX for the settings screens, target 9
/council polish the landing page
```

The fourth line builds fast, tightens with a heavy pass, then runs council on
the verified result with a target of 9. Running `/overseer heavy` after a fast
run picks up the same checklist and tightens that work.
