---
name: supervised-build
description: Coordinate supervised implementation with a shared checklist, independent plan review, delegated coding, evidence checks, and periodic scope and direction checks. Use when the user invokes supervised-build or explicitly asks for this workflow.
---

# Supervised build

Use the invocation arguments, or the conversation's current goal if there are none.
Read applicable project instructions, requirements and any experiment ledger if
present. Otherwise use the user's request and corrections as the requirements.
Cite the relevant sources in every brief.

## 1. Shared checklist

Reuse an existing checklist for this task, including one named in the arguments.
Resume against the current state: do not redo ticked items unless the code or
requirements they depended on changed; revalidate affected checkpoints. Confirm
unticked items and add missing checkpoints or stop conditions.

Otherwise write a short Markdown checklist in a suitable project location, such
as `docs/plans/<task>-checklist.md`. Follow the project's convention on committing
docs. Include the goal, constraints, agreed approach and reviewer agreement,
ordered steps with verification evidence, open decisions, next step, stop
conditions and which actions need the user. Keep detail proportional to the task.
The coordinator owns updates at decisions and checkpoints, and before long waits.
Give each agent the relevant contents and source references; do not assume shared
conversation history. Keep the plan and agreement in this one checklist.

## 2. Roles

| Role | Default model | Setting |
| ---- | ------------- | ------- |
| Coder | Claude Opus 5.5, else GPT-6 Astra | Medium effort; Astra at high effort |
| Plan reviewer | GPT-6 Astra | Medium effort |
| Plan reviewer | Claude Fable 5.1 | Medium effort |
| Scope reviewer | Claude Opus 5.5 | Fresh context |
| Direction reviewer | GPT-6 Astra | Medium effort |
| Coordinator, checker, integrator | You | Direct |

Honor explicit user overrides throughout. Before delegation, discover the models,
settings and delegation mechanisms the runtime supports, and resolve these roles
through them. Do not assume particular tools, provider IDs or accounts. If a
required model, setting or capability is unavailable, report the mismatch and ask
how to proceed before dependent work; never substitute silently. Reviewers must
be separate agents from the coordinator, even when they use the same model.

Do not use GPT-6.1 Sol for any role unless the user explicitly asks for it. The
coder's fallback to GPT-6 Astra at high effort is pre-approved when Opus 5.5 at
medium effort is unavailable; state which one was used in the checklist and the
first update.

## 3. Agreement before code

1. Write the simplest viable approach in the checklist, asking the coder for a
   proposal if useful.
2. Give the same proposal to both plan reviewers separately, read-only. Each
   answers with evidence and `AGREED: <conclusions>` or `DISAGREE: <blocking point>`.
3. Resolve objections against the source. Start each review round with fresh
   tasks carrying the original request, current proposal, evidence, prior
   responses and unresolved findings. Reviewers concede only to evidence, never
   to finish sooner. Both must explicitly agree to the same current proposal.
4. Record their shared conclusions in the checklist. No implementation before
   this. Material changes to scope or approach require renewed agreement.

After three rounds without agreement, stop and put the disputed point to the
user with a recommendation.

## 4. Implementation

Brief the coder narrowly: goal, requirements, files, constraints, what is ruled
out, what to report, and a time box. Specify the workspace and output locations,
and ensure the agent can access its inputs. Keep it to one coherent commit or
small series where applicable, and no pushing. Work must be separate from
accepted work where comparison matters. Do not assign concurrent edits to the
same files.

## 5. Check the coder's work

The coder's report is a claim. Before accepting it:

- Read the diff yourself and look for scope beyond the brief.
- Check the behavior against the user's own description, from screenshots or a
  recording of the real build on the target hardware. Code that passes but does
  something else is a failure.
- Keep the work inside any line budget in the requirements; report the count.
- Run the narrowest useful tests yourself.
- Open the evidence yourself, such as logs, numbers or screenshots.
- Look at any UI before giving the owner a link.
- For performance, measure on real hardware and include the simplest arm. Never
  take performance numbers from a development host when the requirements name
  other hardware.

Send failures back to the coder as a new task with the findings attached.

## 6. Supervision

Retain task handles, workspace and output locations in the checklist. Check
delegated work using the runtime's status or notification facilities and a timer
where supported. Stop any agent looping on tooling, after two restarts or 30
minutes without evidence about the real goal. Use actual task cancellation;
a wait timeout is not cancellation. Confirm work has stopped and record and
inspect partial changes before retrying or accepting them. Preserve user and
accepted work. If monitoring or cancellation cannot be enforced, disclose the
limitation before starting unattended work.

## 7. Checkpoints

Run both checks after agreement, after each implementation result, and whenever
work has gone about two hours or a surprise changes the plan. Run them read-only,
as fresh tasks separate from the coordinator.

**Scope check.** Give the scope reviewer the checklist, requirements and a short
factual status, not your conclusions. Ask whether the work is off track, whether
scope has expanded beyond the goal, and whether anyone is obsessing over the wrong
thing. Ask what it would stop doing. Limit it to 25 lines.

**Direction check.** Give the direction reviewer accessible conversation history,
the checklist and the requirements. If history is unavailable, provide a faithful
summary of the user's requests, corrections and decisions, labeled as a summary
with any gaps disclosed. Ask whether the conversation is heading the right way,
what the user asked for that has been dropped, what has been overclaimed, and
whether a simpler route exists. Limit it to 25 lines.

Read both yourself. Act on what you accept and record what you reject and why in
the checklist. If either finds real drift, stop and tell the user.

## 8. Reporting and finishing

Keep updates short and outcome-first. Say plainly what was measured, inferred or
untested, and correct earlier mistakes openly. Record tried approaches with their
commits where applicable in the project's existing ledger, or otherwise in the
checklist. Never push, publish or merge without explicit owner approval. Finish
by ticking only verified completed items and stating what is done, what failed
and what the user must decide.

If the finished work would benefit from scored polish, such as UI, design or
copy, suggest running the `council` skill on it if it's installed. Don't start
it without the user's go-ahead.
