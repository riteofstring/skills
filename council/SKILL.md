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

## 2. Keep reviews blind

Only the coordinator sees the review history. Before launching, check how the
runner supplies context, exposes files and tools, and handles later rounds.
If it inherits conversation history or requires prior findings and responses,
use a permitted runner that supports blind review. If none is available,
explain the conflicting rule and ask whether to proceed with informed review
or change the orchestration. Follow higher-priority instructions; never call
a review blind when they require sharing earlier feedback.

Every round:

- **Start a new agent for every seat.** Never continue, message or fork an
  earlier reviewer, and never use a fork that inherits your context. If the
  tool takes a request or idempotency ID, use a distinct one per seat per round.
- **Send only the neutral brief and current materials**, including relevant
  source and the owner's requirements. Exclude earlier scores, critiques,
  responses, revision summaries, your opinions, and decisions derived from
  reviews. Paraphrasing feedback as a constraint still leaks it. The revised
  work is allowed; the review history behind it is not.
- **Keep labels and instructions neutral.** Don't write "we fixed X, confirm
  it" or label the work "improved". Describe the work as it is now.
- **Separate reviewer inputs from coordinator records.** Keep prior reviews,
  `ledger.md` and the private decisions list out of the supplied materials
  and restrict access through files, tools, memory and messages where the
  runner supports it. Tell reviewers to use only the supplied materials and
  relevant source, and not to look up review history or contact other seats.
  A separate directory, worktree or fresh context alone does not enforce
  access isolation. If access is shared, disclose that blindness relies on
  instructions rather than enforced isolation.
- **Run seats in parallel on the same snapshot.** Wait for every review
  before triage or edits; never share outputs between seats. If a reviewer
  sees earlier feedback, discard that review and rerun the seat fresh after
  removing the exposure.

## 3. Brief, materials and private decisions

Write the brief once, in a working directory such as `/tmp/council/<slug>/`,
and keep it the same across rounds so scores stay comparable. It contains:

- What the work is and who it's for, in a few lines.
- The seat's perspective, and the owner's standards close to verbatim.
- A scale anchor: 9 = polished, obvious hierarchy, nothing redundant or
  confusing for this perspective; 10 = best in class. Be strict.
- In polish mode, also: "Small details are in scope. Report every one you can
  point to in the materials, not just the top 10. Don't report taste
  preferences you can't tie to the owner's standards." Then name the details
  that fit the work, for example:
  - **Interfaces:** alignment, spacing, consistent wording, icons and units,
    every state (empty, loading, error, long text), light and dark.
  - **Code:** naming, consistent patterns, error messages, edge cases, dead
    code, comments that no longer match the code.
  - **Writing:** consistent terms, word choice, formatting, links and
    references.
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

If the user changes the requirements, update the brief neutrally and record
the changed basis for comparison in the private ledger. Do not turn your
review triage into new owner requirements.

**Materials:** capture the same set every round with a script, so rounds
compare like for like. For anything visual, give real screenshots at the sizes
and appearances the user will see (default window size, light and dark), and
tell reviewers to look at every image. Before sending, open every capture
yourself: a blank, stale or crashed screen will be scored as if it were the
design. Label fake or sandbox data as fake. For non-visual perspectives, give
the files, copy, measurements or benchmark output instead. Run benchmarks
yourself and pass on the numbers.

**Seeing and using the work:** when the work has a visible or interactive
side, use whatever the harness offers to see and drive it: screenshots, screen
recordings for motion and flows, browser or device control, or computer use
for desktop apps. Reviewers should look at the real thing whenever possible,
not a description of it. Keep any interaction on a test or sandbox copy. If
the harness can't capture or drive something, say so instead of judging it
without seeing it.

**Private decisions list:** record accepted, rejected and deferred suggestions
with reasons, so you can handle repeated feedback consistently. Never send
this list to reviewers. Owner requirements belong in the neutral brief;
critique-derived decisions belong here. Keep it short.

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
   rounds, either do it or record the reason privately, and tell the user
   which. Items you keep putting off are why scores stall.
   Disagreement between seats is useful, not noise. Pick the suggestion with
   the better evidence and fit with the owner's standards, even if only one
   seat made it. Record the choice and its reason privately, and mention it
   in your update to the user, outside the reviewer inputs.
   **Scope guard:** reviewers judge, they don't set scope. If a fix would add
   a feature, change behaviour, or reach beyond what is under review, don't
   build it. List it for the user with a recommendation, keep working on the
   rest, and record it privately as "deferred: needs the user" until they decide.
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
- Fixes go in circles: successive suggestions undo one another without
  evidence of harm. Reviewers cannot see your private decisions; repeated
  criticism alone is not noise.
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
verified and what wasn't, and where the ledger and materials are. State
whether reviews were blind or informed, whether access isolation was enforced
or instruction-based, and any exposure or reruns.
