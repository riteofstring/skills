---
name: overseer
description: Coordinate supervised, systematic work (code, documents, research, data, content batches, migrations and similar) with a shared checklist, independent plan review, a delegated worker, evidence checks, a read-only audit, and periodic scope and direction checks. Use when the user invokes overseer, asks for a supervised build, or explicitly asks for this workflow.
---

# Overseer

Use the invocation arguments, or the conversation's current goal if there are none.
Read applicable project instructions, requirements and any experiment ledger if
present. Otherwise use the user's request and corrections as the requirements.
Cite the relevant sources in every brief.

The work can be anything systematic: code, a document or report, research, a
dataset, a batch of content, a migration. Where this skill names code-specific
steps, use them for code and the closest equivalent otherwise.

## 1. Shared checklist

Reuse an existing checklist for this task, including one named in the arguments.
Resume against the current state: do not redo ticked items unless the work or
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

| Role | Default model | Effort |
| ---- | ------------- | ------ |
| Coordinator, checker, integrator | You | Your own |
| Worker | Claude Opus 5.5 (fallback: GPT-6 Astra) | Medium (Astra: high) |
| Plan reviewer | GPT-6 Astra | Medium |
| Plan reviewer | Claude Fable 5.1 | Medium |
| Scope reviewer | Claude Opus 5.5 | Medium |
| Direction reviewer | GPT-6 Astra | Medium |
| Auditor | GPT-6.1 Sol | Medium |

The worker does the work: the coder for code, the writer for a document, the
researcher or analyst otherwise.

Honor explicit user overrides throughout. Before delegation, discover the models,
settings and delegation mechanisms the runtime supports, and resolve these roles
through them. Do not assume particular tools, provider IDs or accounts. If a
required model, setting or capability is unavailable, report the mismatch and ask
how to proceed before dependent work; never substitute silently. Every reviewer
is a fresh agent, separate from the coordinator even when it uses the same
model, and never a fork that inherits the coordinator's context.

The worker's fallback to GPT-6 Astra at high effort is pre-approved when Opus 5.5
at medium effort is unavailable; state which one was used in the checklist and
the first update.

## 3. Agreement before work

1. Write the simplest viable approach in the checklist, asking the worker for a
   proposal if useful.
2. Give the same proposal to both plan reviewers separately, read-only. Each
   answers with evidence and `AGREED: <conclusions>` or `DISAGREE: <blocking point>`.
3. Resolve objections against the source. Start each review round with fresh
   tasks carrying the original request, current proposal, evidence, prior
   responses and unresolved findings. Reviewers concede only to evidence, never
   to finish sooner. Both must explicitly agree to the same current proposal.
4. Record their shared conclusions in the checklist. No work starts before
   this. Material changes to scope or approach require renewed agreement.

After three rounds without agreement, stop and put the disputed point to the
user with a recommendation.

## 4. The work

Brief the worker narrowly: goal, requirements, inputs (the files, for code),
constraints, what is ruled out, what to report, and a time box. Specify the
workspace and output locations, and ensure the agent can access its inputs. Keep the output to one
coherent, reviewable unit, such as one commit or small series for code. No
pushing, publishing or sending anywhere. Keep new work separate from accepted
work where comparison matters. Do not assign concurrent edits to the same files.

## 5. Check the worker's output

The worker's report is a claim. Before accepting it, for any kind of work:

- Read the output yourself (the diff, document or data) and look for scope
  beyond the brief.
- Check it against the user's own description. Output that passes its checks
  but does something else is a failure.
- Open the evidence yourself, such as logs, numbers, sources or screenshots.
- Keep the work inside any budget in the requirements (lines, words, cost,
  time); report the figure.
- When the work has a visible or interactive side, look at it and use it:
  screenshots, screen recordings, browser or device control, or computer use,
  whichever the harness offers. Ask the worker and auditor to do the same and
  include what they captured. Use test or sandbox copies, not the user's live
  accounts. If something can't be seen or driven here, say it wasn't checked.

Then the checks for its kind:

- **Code:** run the narrowest useful tests yourself. Check behavior from
  screenshots or a recording of the real build on the target hardware. Look at
  any UI before giving the owner a link. For performance, measure on real
  hardware and include the simplest arm; never take performance numbers from a
  development host when the requirements name other hardware.
- **Documents and research:** spot-check claims against their sources, and
  confirm that cited sources exist and say what is claimed.
- **Data and content batches:** check counts, formats and a sample across the
  whole range, not just the first items. Run any validator the project has.

**Audit.** After your own checks pass, give the auditor the brief, the output
(or the diff, for changes) and the requirements, as a fresh read-only task. It
digs through the output and what it touches, looking for:

- **Code:** correctness, edge cases, error handling, security, tests that don't
  test what they claim, and dead or duplicated code.
- **Documents and research:** unsupported or wrong claims, missing sources,
  contradictions and gaps against the requirements.
- **Data and content:** errors, inconsistencies, duplicates and items that
  break the stated rules.

It must not edit, commit, or run anything that changes state. Each finding
gives its location (file and line, section, or record), the evidence and its
severity. Its findings are claims too: confirm each one before acting, and
record rejected ones with the reason in the checklist.

Send failures and confirmed findings back to the worker as a new task with the
findings attached.

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

Run both checks after agreement, after each work result, and whenever work has
gone about two hours or a surprise changes the plan. Run them read-only, as
fresh tasks separate from the coordinator.

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
untested, and correct earlier mistakes openly. Record tried approaches, with
their commits where applicable, in the project's existing ledger, or otherwise
in the checklist. Never push, publish, send or merge without explicit owner
approval. Finish by ticking only verified completed items and stating what is
done, what failed and what the user must decide.

If the user asked for polish or a target score as part of this task (for
example "build this, then polish to 9"), record that in the checklist. Once the
work is verified, run the `council` skill on the result with that target, and
report the work before council starts. Otherwise, if the finished work would
benefit from scored polish, such as UI, design or copy, suggest council and
wait for the user's go-ahead. If council isn't installed, say so.
