# skills

Two skills for AI agents. Each one fixes a way agents let you down. They
work in Claude Code, Codex and any agent that reads `SKILL.md` files.

| Skill | What it does | Because agents |
| --- | --- | --- |
| [builder](#builder) | Debates a plan, builds it, then has another agent check it. | say "done" when it is not |
| [council](#council) | Your agent works. A council of independent agents scores it and says what to fix. They repeat until it reaches your target score. | stop at "good enough" |

Builder gets work built and correct. Council takes it from correct to
excellent.

Both check the work with Claude and GPT models. If your agent cannot reach
one of those models, the skill asks you what to use instead.

## [builder](builder/SKILL.md)

**Debates a plan, builds it, then has another agent check it.**

**The problem:** Agents say "done" when the work is not done. A test was
skipped, a piece is missing, or it is not what you asked for. You find out
later.

**What it does:**

1. **Plan.** Two other AI models debate the plan until both agree.
2. **Build.** An agent does the work.
3. **Check.** The work is tested, and another AI model checks it against
   what you asked for.

It works for code, documents, research and data. You choose the order:

- `heavy` (the default): plan, build, check. The plan is agreed before
  anything is built.
- `fast`: build first. Then the other models debate what was built, and it
  is fixed, tested and checked. Good when you want a working version early.

```text
/builder move the billing tables to the new schema
/builder fast prototype a drag-to-reorder sidebar
```

## [council](council/SKILL.md)

**Your agent works. A council of independent agents scores it and says what
to fix. They repeat until it reaches your target score.**

**The problem:** Work can do what was asked and still be just okay. And an
agent that judges its own work says it is good.

**What it does:**

1. **Score.** A council of fresh AI reviewers scores the work out of 10,
   each on its own. Each one judges one thing you choose, such as design,
   wording or speed.
2. **Improve.** The main agent fixes the real problems they found.
3. **Score again.** A new council, which has not seen the old scores, scores
   the new version.
4. **Repeat** until every reviewer gives your target score (9 unless you say
   otherwise). If the feedback stops being useful first, it stops and asks
   you what to do next.

It works on an app, a page, writing, a plan or code. It does not build
something new. Builder can hand its result straight to council.

```text
/council design and UX for the settings screens, target 9
/council clarity of the pricing page copy
/builder add a credentials page, then polish design to 9 with council
```

## Install

```bash
npx skills add riteofstring/skills
```

Or copy or symlink a skill folder into `~/.claude/skills/` (Claude Code) or
`~/.agents/skills/` (Codex and others).
