# skills

Agent skills by riteofstring. Each skill is a top-level folder with a
`SKILL.md`, and works in Claude Code, Codex and other agents that read the
same format.

## Skills

Use **overseer** to build something and **council** to polish and iterate on
it. They work on their own or in sequence: overseer can hand its verified
result to council. Use **rigor** when you need to know what is true before
you act on it.

- [**overseer**](overseer/SKILL.md), for building: gets systematic work done
  and verified. That's code, but also documents, research, data or content
  batches. Three modes:
  - `medium` (default): builds fast until it works, then a heavy pass over
    the result: reviewers check the approach as built, then tests, a
    read-only audit, and scope and direction checks.
  - `fast`: only the fast build. The agent works directly and checks the
    result against your description, including visually.
  - `heavy`: two reviewers agree on the plan before anything is built, then a
    delegated worker, tests, the audit and the checks.

  If you ask for polish or a target score up front, it hands the verified
  result to council.
- [**council**](council/SKILL.md), for polish and iteration: fresh,
  independent reviewer agents score the work out of 10 from chosen
  perspectives (design, UX, marketing, performance and so on). The main agent
  fixes what they find, and new reviewers score it again until every reviewer
  reaches the target score, or until the feedback stops being useful. Has a
  `polish` mode for detail-oriented finish.
- [**rigor**](rigor/SKILL.md), for investigating: answers a question from
  evidence on disk. A bash script drives the run and will not finish while a
  demand is open:
  - a frame first: the primary records, what may have changed, and rival
    answers when the question is "why";
  - every claim tied to a line in a file, and every number in a claim
    matched against that line;
  - the project's own checks, if it has a `rigor-gates.json`;
  - a challenge from a model of the other provider family (a Claude
    coordinator gets GPT-6.2 Astra, an OpenAI coordinator gets Claude Fable
    5.2), which recomputes from the files and tries to refute each claim.
    You can name another model or effort when you ask.

  The report labels each claim upheld, disputed, not challenged or
  uncertain. The script checks form and consistency, not truth; the
  challenger does the recomputing. Needs `jq` and bash 3.2 or later.

## Install

```bash
npx skills add riteofstring/skills
```

Or copy or symlink a skill folder into `~/.claude/skills/` (Claude Code) or
`~/.agents/skills/` (Codex and others).

## Use

```text
/overseer add per-machine sorting and pinning
/overseer fast prototype a drag-to-reorder sidebar
/overseer heavy migrate the billing tables to the new schema
/overseer write phonetic spellings for the 400 new words, checked against the rules doc
/overseer add a credentials page, then polish design and UX to 9 with council
/council design and UX for the settings screens, target 9
/council polish the landing page
/rigor why did signups drop last week?
/rigor is it true the export has skipped rows since the upgrade? challenger sol, effort high
```

The fifth line builds fast, tightens with a heavy pass, then runs council on
the verified result with a target of 9. Running `/overseer heavy` after a
`fast` run picks up the same checklist and tightens that work.

Rigor's tests run with `bash rigor/scripts/test.sh`.
