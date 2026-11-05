---
name: council
description: Run a council of fresh, independent reviewer agents that each score the current work out of 10 from a given perspective (design, UX, marketing, features, performance, etc.), then iterate on their critiques and re-review with new agents until every reviewer reaches the target score. Use when the user invokes council or asks for scored independent reviews repeated until a target score is met.
---

# Council

Use the invocation arguments, or the conversation's current goal if there are
none. Establish five things, and ask only for what you cannot infer:

- **Target:** what is under review (an app, screens, a page, copy, a plan, code).
- **Perspectives:** what each reviewer judges, such as design, UX, marketing,
  features or performance. Default to the one the request implies.
- **Target score:** default 9/10.
- **The owner's standards:** the user's stated intent and taste, in their words.
- **Mode:** `standard` (default) aims for the target score and treats late,
  small complaints with suspicion. `polish` is for when the user wants
  detail-oriented finish (also "pixel-perfect", "sweat the details"). There,
  small issues are the work, not noise.

You are the coordinator and you do the iteration work yourself. The reviewers
only judge.

## 1. Seats

A seat is one reviewer: one model judging from one perspective. By default each
perspective gets three seats, one per model below. So a design-only council has
three reviewers, and a design-and-marketing council has six.

| Model | Setting |
| ----- | ------- |
| Claude Opus 5.5 | Default effort |
| Claude Fable 5.1 | Default effort |
| GPT-6 Astra | Default effort |

Honor user overrides of models, perspectives and seat counts. If there would be
more than nine seats, confirm with the user first.

Before the first round, find out which models and subagent tools this harness
offers, and launch each seat through whichever tool can run its model with a
fresh context. Don't assume particular tools, provider IDs or accounts. For
example, T3 Code's `orchestrator_capabilities` and `delegate_task` can run any
provider. A native subagent tool may only run its own provider's models, and a
CLI such as `claude -p` or `codex exec` started from a shell also gives a fresh
agent. If a model can't be reached, or the harness can't start subagents at
all, report it and ask; never substitute silently.

## 2. Keep reviewers unpolluted

This is the point of the council. Every round:

- **Start a new agent for every seat.** Never continue, message or fork an
  earlier reviewer, and never use a fork that inherits your context. If the
  tool takes a request or idempotency ID, use a distinct one per seat per round.
- **Send each reviewer only:** the brief, the current materials, and the
  decisions list (section 3). Never send other reviewers' output, any earlier
  scores or critiques (including its own), or your opinion of the work.
- **Keep the brief neutral.** Don't write "we fixed X, confirm it". Describe
  the work as it is now.
- **Run seats in parallel** and don't share anything between them while they run.

## 3. Brief, materials and decisions

Write the brief once, in a working directory such as `/tmp/council/<slug>/`,
and keep it the same across rounds so scores stay comparable. It contains:

- What the work is and who it's for, in a few lines.
- The seat's perspective, and the owner's standards close to verbatim.
- A scale anchor: 9 = polished, obvious hierarchy, nothing redundant or
  confusing for this perspective; 10 = best in class. Be strict.
- In polish mode, also: "Small details are in scope: alignment, spacing,
  consistent wording, icons and units, every state (empty, loading, error,
  long text), and the light and dark appearances. Report every one you can
  point to in the materials, not just the top 10. Don't report taste
  preferences you can't tie to the owner's standards."
- Where the materials and relevant source are. Read-only: no edits, commits or
  servers, and no builds or tests unless the perspective needs them.
- Output, under 600 words (1,200 in polish mode):
  1. `SCORE: N/10` on the first line (halves allowed). With several areas,
     give a score per area as well as the overall score.
  2. Up to 10 issues (no limit in polish mode), most impactful first. Each
     one gives the evidence (the screenshot, file or measurement), why it
     matters, and a concrete fix.
  3. What works and must be kept.
  4. What would have to change to reach the target score.

**Materials:** capture the same set every round with a script, so rounds
compare like for like. For anything visual, give real screenshots at the sizes
and appearances the user will see (default window size, light and dark), and
tell reviewers to look at every image. Before sending, open every capture
yourself: a blank, stale or crashed screen will be scored as if it were the
design. Label fake or sandbox data as fake. For non-visual perspectives, give
the files, copy, measurements or benchmark output instead. Run benchmarks
yourself and pass on the numbers.

**Decisions list:** deliberate choices that reviewers should not mark down
unless they cause real harm, each with its reason. These come from the user or
from your triage below, never from a reviewer's text. Keep it short.

## 4. The loop

1. **Review:** launch all seats fresh and wait for all of them.
2. **Record** each seat's score, top issues and issue count in `ledger.md` in
   the working directory. Tell the user the scores per seat and the shared
   themes in a few lines. Include a screenshot when the work is visual.
3. **Done?** If every seat scores at least the target in the same round, and
   that round's materials were sound, stop and report. Otherwise check the
   escape hatch (section 5) before going on.
4. **Triage:** fix what several seats raise first, then anything that blocks a
   seat from reaching the target. If the same seat raises an item in two
   rounds, either do it or add it to the decisions list with a reason, and tell
   the user which. Items you keep putting off are why scores stall.
   Disagreement between seats is useful, not noise. Pick the suggestion with
   the better evidence and fit with the owner's standards, even if only one
   seat made it. Record the choice and its reason in the decisions list, so
   later reviewers don't reopen it, and mention it in your round update.
5. **Iterate:** make the changes yourself. Check each one with your own eyes or
   tests in proportion to the risk, and look for regressions your fixes caused.
   Commit a checkpoint per round only if the user allows commits for this work.
6. **Recapture** the materials and go back to step 1 with new agents.

## 5. Escape hatch

The target may not be reachable. Late rounds can turn into noise, where
reviewers quibble over polish and every fix uncovers a new, equally small
complaint. When that happens, pause the council instead of grinding on.

From round 4 on, after recording each round, judge whether the feedback is
still worth acting on. Count it as noise when most of these hold:

- No seat's score has risen for two rounds, even after you acted on its
  repeated asks.
- The top issues are minor polish, not problems with the user's workflow,
  clarity or correctness.
- Fixes go in circles: after you've settled a disagreement in the decisions
  list, reviewers keep asking to undo it with no new evidence.
- Each fix brings a new complaint of the same size rather than a higher score.

**In polish mode**, small issues are the work and a flat score isn't noise on
its own. Judge progress by the issue list instead: each round should find
fewer issues, or smaller ones. Use this list in place of the one above:

- Fixes go in circles, as above.
- Issues are taste with no evidence in the materials, or don't hold up when
  you check them.
- Fixed items come back reworded, or the list stays as long as before.

Pause when the feedback is noise, or at round 8 (12 in polish mode) whatever
the scores, unless the user set a different limit. To pause, finish and
verify the current round's changes, then tell the user:

- the score history per seat, and whether the scores are still rising;
- what the remaining issues look like, with a few examples;
- your honest view of the realistic ceiling, such as "8.5 looks like the
  ceiling for this scope";
- options and a recommendation: accept the current state, run a set number of
  further rounds on named issues, lower the target, or change the scope or
  perspectives.

Wait for their answer before starting another round.

## 6. Final report

Give the score history per seat, what changed, the decisions list, what was
verified and what wasn't, and where the ledger and materials are.
