---
name: council
description: Run a council of fresh, independent reviewer agents that each score the current work out of 10 from a given perspective (design, UX, marketing, features, performance, etc.), then iterate on their critiques and re-review with new agents until every reviewer reaches the target score or the council pauses with a recommendation. Use when the user invokes council or asks for scored independent reviews repeated until a target score is met.
---

# Council

Use the invocation arguments, or the conversation's current goal if there are
none. Establish five things, and ask only for what you cannot infer:

- **Target:** what is under review (an app, screens, a page, copy, a plan,
  code).
- **Perspectives:** what each reviewer judges, such as design, UX, marketing,
  features or performance. Default to the one the request implies.
- **Target score:** default 9/10.
- **The owner's standards:** the user's stated intent and taste, in their
  words.
- **Mode:** `standard` (default) aims for the target score and treats late,
  small complaints with suspicion. `polish` is for when the user wants
  detail-oriented finish (also "pixel-perfect", "sweat the details"). There,
  small issues are the work, not noise.

You are the coordinator and you do the iteration work yourself. The reviewers
only judge.

## 1. Seats

A seat is one reviewer: one model judging from one perspective. By default
each perspective gets three seats, one per model below. So a design-only
council has three reviewers, and a design-and-marketing council has six.

- Claude Opus 5.5
- Claude Fable 5.1
- GPT-6 Astra

Use default reasoning settings unless the user specifies otherwise.

Honor user overrides of models, perspectives and seat counts. If there would
be more than nine seats, confirm with the user first.

Before the first round, discover which models and runners are available. A
runner is a way to launch a separate agent, such as a subagent tool, CLI or
API. Use one that can launch the chosen model with any requested settings as a
separate agent. If a requested model, setting or suitable runner is unavailable,
report all missing capabilities together and ask before round 1; never
substitute silently.

Give each seat a stable identifier, even when two seats use the same model and
perspective. Changing a seat's model or perspective starts a new review
history.

## 2. Keep reviewers independent

Seats never receive each other's outputs, scores, identities or conversation,
or the coordinator's conversation, ledger or private decisions list.

Reviews are blind by default: send only the neutral brief and current
materials, including relevant source and owner requirements. Exclude earlier
scores, critiques, responses, revision summaries and review-derived decisions.
Paraphrasing feedback as a constraint still leaks it. The current work may
reflect all seats' feedback; that indirect influence is allowed.

When the user requests informed reviews or higher-priority instructions require
history, supply only the receiving seat's earlier findings, unresolved objections
and factual responses about what changed or why it did not, without prior
scores or other seats' reasoning. The coordinator's preference alone does not
activate this exception. If required inputs exceed these limits, pause the
affected review and ask for a compatible approach.

Every round:

- **Start a fresh agent for every seat.** Use a separate prompt and fresh
  conversation with no inherited context, not a fork or clone of the
  coordinator's session. Never continue, message or resume an earlier reviewer.
- **Limit access.** Scope file, tool and memory access to the seat's inputs
  where supported. Otherwise use the reviewer instructions in section 3 and
  report instruction-based limits. Fresh contexts separate conversations, but
  do not restrict file or tool access. Claim access enforcement only when
  verified.
- **Review the same snapshot.** Run seats in parallel when supported,
  otherwise in batches or sequentially. Wait for every seat before triage or
  edits.
- **Replace exposed or failed reviews.** If a reviewer sees prohibited context
  (for example, it cites another seat's findings), discard its review, remove
  the exposure, and launch a new
  agent with corrected inputs. Keep discarded findings out of future inputs.
  For failed or unusable reviews, confirm the original run has ended to avoid
  duplicate active reviews, then launch a fresh agent with the same inputs.
  Report persistent failures; a round with a missing valid review cannot
  satisfy the target.

## 3. Brief, materials and private decisions

Keep private records separate from per-seat, per-round inputs. With filesystem
storage, use a temporary working directory, for example
`/tmp/council/<slug>/`, with `private/` for ledger, raw reviews and decisions,
and `inputs/r<N>/<seat>/` for reviewer materials. With other storage, use
equivalent separate records. Give reviewers only their own input locations,
never a directory containing private records. If a runner cannot read files,
supply materials directly in its prompt or supported attachments.

Use a common brief with a seat-specific perspective. Keep each seat's brief
unchanged across rounds unless requirements change, so scores stay comparable.
Include:

- What the work is and who it's for, in a few lines.
- The seat's perspective, and the owner's standards close to verbatim.
- A scale anchor: 9 = meets the owner's standards with no material issues for
  this perspective; 10 = best in class. Be strict.
- The assessment rule: "Assess the whole current work against this rubric.
  Earlier findings, if supplied, are background, not a checklist. A fix earns
  no credit merely for having been made; new issues count fully."
- The polish-mode instruction, when applicable: "Small details are in scope.
  Report every one you can point to in the materials, not just the top 10.
  Don't report taste preferences you can't tie to the owner's standards." Then
  name the details that fit the work, for example:
  - **Interfaces:** alignment, spacing, consistent wording, icons and units,
    every state (empty, loading, error, long text), light and dark.
  - **Code:** naming, consistent patterns, error messages, edge cases, dead
    code, comments that no longer match the code.
  - **Writing:** consistent terms, word choice, formatting, links and
    references.
- The materials and relevant source, plus these reviewer constraints:
  "Review only: do not delegate or launch agents. Use only supplied inputs and
  do not contact other seats. Do not save memories, notes or files outside your
  review output, except temporary build and test artifacts in a disposable
  copy or sandbox. Do not edit source, commit or start servers. Run builds or
  tests only when necessary for your perspective and leave the reviewed
  snapshot unchanged. Look at every supplied image."
- Output, under 600 words (1,200 in polish mode):
  1. `SCORE: N/10` on the first line (halves allowed). With several areas,
     give a score per area as well as the overall score.
  2. Up to 10 issues (no limit in polish mode), most impactful first. Each one
     gives the evidence (the screenshot, file or measurement), why it matters,
     and a concrete fix.
  3. What works and must be kept.
  4. What would have to change to reach the target score.

If the user changes the requirements, update the brief neutrally and record
the changed basis for comparison in the private ledger. Do not turn your
review triage into new owner requirements.

**Materials:** use a repeatable capture procedure with the same coverage each
round so rounds compare like for like. Automate capture when practical. For
anything visual, give real screenshots at the sizes and appearances the user
will see (default window size; light and dark if supported). Before sending,
open every capture yourself: a blank, stale or crashed screen will be scored
as if it were the design. Label fake or
sandbox data as fake. For non-visual perspectives, give the files, copy,
measurements or benchmark output instead. Run benchmarks yourself and pass on
the numbers.

**Interaction:** for interactive work, use the host's available tools to drive
flows and observe motion on a test or sandbox copy. If required visual or
interactive evidence cannot be captured, disclose the gap rather than judge
unseen behaviour.

**Private decisions list:** record accepted, rejected and deferred suggestions
with reasons, so you can handle repeated feedback consistently.

## 4. The loop

1. **Review:** run every seat as described in section 2 and wait for all of
   them.
2. **Record** each seat's score, top issues and issue count in the private
   ledger (for example, `private/ledger.md`). Tell the user the scores per
   seat and shared themes in a few lines. Include a screenshot for visual work
   when the host can display one.
3. **Done?** If every seat scores at least the target in the same round, and
   that round's materials were sound, stop and report. Otherwise check the
   escape hatch (section 5) before going on.
4. **Triage:**
   - **Priority:** fix what several seats raise first, then anything that
     blocks a seat from reaching the target.
   - **Repeated items:** if a seat raises an item in two rounds, fix it or
     record why not and tell the user. Repetition requires a decision, not
     agreement. Informed repetition is not independent corroboration; weigh
     current evidence and severity rather than repetition or past deferrals.
   - **Disagreement:** choose the suggestion with better evidence and fit with
     the owner's standards, even if only one seat made it. Record the choice
     and reason privately and mention it in the user update.
   - **Scope:** reviewers judge, they don't set scope. Fix defects within the
     authorized requirements. List suggestions beyond that scope for the user
     with a recommendation, keep working on the rest, and record them as
     "deferred: needs the user" until they decide.
5. **Iterate:** make the changes yourself. Check each one with your own eyes
   or tests in proportion to the risk, and look for regressions your fixes
   caused. Commit a checkpoint per round only if the user allows commits for
   this work. Keep checkpoint messages neutral: no seat names, critiques or
   round triage.
6. **Recapture** the materials and return to step 1.

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
  evidence of harm.
- Each fix brings a new complaint of the same size rather than a higher score.

**In polish mode**, small issues are the work and a flat score isn't noise on
its own. Judge progress by the issue list instead: each round should find
fewer issues, or smaller ones. Use this list in place of the one above:

- Fixes go in circles, as above.
- Issues are taste with no evidence in the materials, or don't hold up when
  you check them.
- Fixed items come back reworded, or the list stays as long as before.

Pause when the feedback is noise, or at round 8 (12 in polish mode) whatever
the scores, unless the user set a different limit. You may pause on the
reviewed snapshot. If you make further changes before pausing, verify them and
identify them as not yet council-reviewed; scores apply to the reviewed
snapshot only. Tell the user:

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
whether reviews were blind or informed, how reviewers were launched, what
access they had, whether isolation was enforced or instruction-based, and any
exposure or reruns.
