---
name: rigor
description: Investigate a question against evidence on disk and report as fact only what survives, with the rest labelled. A bash script drives the run - it demands a frame, project gates, claims pinned to file lines with checked numbers, and an adversarial challenge by a model of the other provider family - and refuses to finish while a demand is open. Use when the user invokes rigor, asks what is really happening, why something happened or whether a figure is right; before reporting a cause; before recommending a change to spend or anything hard to reverse; at launch and on day two of anything that spends money; when results are bad or unexplained.
---

# Rigor

The script is `scripts/rigor.sh` in this skill's folder (normally
`~/.agents/skills/rigor/scripts/rigor.sh`). It needs `jq`. First run `start`,
then do what `next` prints until it prints `RIGOR: DONE`. Answer after that.

## What the script can and cannot establish

It checks form and consistency: that a claim points at a line that exists,
that the numbers in its text match that line, and that the required second
looks were recorded. It does not prove a claim is true, that a figure was
computed correctly, or that the right record was chosen. It does not check
numbers inside backticks, or which model really ran. Those rest on the
challenger, who recomputes from the files. A claim the challenger agrees with
is upheld, not proven. Wrong yardsticks and changed platform rules are caught
only by your frame and the challenger. The skill only works when it is run.

## Start

```
rigor.sh start --question "<the user's question, verbatim>" --coordinator <your model id> [--dir D] [--root R]
```

- A Claude coordinator gets `gpt-6.2-astra` at `max`; an OpenAI coordinator
  gets `claude-fable-5-2` at `high`. If the user names another model or
  effort, pass `--challenger` and `--effort`; do not ask again. If the user
  says to skip the challenge, pass `--no-challenger "<their reason>"`.
- The run folder is a disposable temp folder unless you pass `--dir`. In a
  project, pass `--dir` under a git-ignored folder. A register kept in a
  project must cite project files, not a temp run folder.
- The root is `--root`, else the git top level, else the current folder.
  Relative evidence paths are under the root; `evidence/...` is in the run.
- `start` and `next` exit 1 while demands are open. That is normal.

## Frame (edit `claims.json` in place)

`frame`: `question` (verbatim); `evidence_date` (the date the evidence runs
to); `kind` (`cause` when the user asks why something happened or what is
going on, else `fact`); `primary_records` (`{record, why}`: why it is the
source closest to the truth, not a proxy); `changed_since` (versions, dates,
platform rules); `not_checked`; optional `figures_from`. A `cause` question
needs at least three `rivals`, written before you look at the evidence:
`{answer, null_answer, status, because}`, one with `"null_answer": true`
(nothing unusual happened, or the premise is wrong). Status is `open`,
`ruled out` or `confirmed`; a closed rival lists `because` items
`{claim, how}` citing a fact or comparison claim with evidence.

## Claims

Each claim: `id` (`C1`...), `text`, `type` (`fact`, `comparison`, `cause`),
`basis` (`observed`: the record states it; `computed`: derived by a saved
command or tool; `inferred`: reasoned from other claims or indirect
evidence), `status` (`supported`, `uncertain`, `refuted`, `unknown`),
`evidence` (`{path, contains, shows}`), `cross_checks`, `disproof`, optional
`waive` (`{"R2": "reason"}`; R1 cannot be waived). Do not enter
recommendations or decisions; enter a forecast as uncertain. A supported
comparison names a claim that repeats it on another period, baseline or
source. A cause is `inferred` and is supported only when no rival is open.
Comparisons and causes state their `disproof`. Example (a shop asking about
its orders by region):

```json
{"frame": {"question": "Did the north region's share of orders drop?", "evidence_date": "2026-11-15",
   "kind": "fact", "primary_records": [{"record": "reports/orders-by-region.csv", "why": "exported from the order system, not read off a dashboard"}],
   "changed_since": "The shipping zones were redrawn in March", "not_checked": ["orders by city inside the region"], "rivals": [], "figures_from": "the order system's export"},
 "claims": [
  {"id": "C1", "text": "In the week of `Nov 9` the north region got 31.25% of orders.", "type": "fact", "basis": "computed", "status": "supported",
   "evidence": [{"path": "reports/orders-by-region.csv", "contains": ["north-share.week,", ",31.25,percent"], "shows": "north region share of orders, percent, week of Nov 9 2026"}]},
  {"id": "C2", "text": "The share fell from 58.4% in the same week `last year` to 31.25%.", "type": "comparison", "basis": "computed", "status": "supported",
   "evidence": [{"path": "reports/orders-by-region.csv", "contains": ["north-share.week-last-year,", ",58.4,percent"], "shows": "north region share, percent, same week last year"},
                {"path": "reports/orders-by-region.csv", "contains": ["north-share.week,", ",31.25,percent"], "shows": "north region share, percent, week of Nov 9 2026"}],
   "cross_checks": ["C3"], "disproof": "a period last year with a share near this week's; looked at last year's whole season in the same file"},
  {"id": "C3", "text": "Over all of `last year's` season the share was 52.1%.", "type": "fact", "basis": "computed", "status": "supported",
   "evidence": [{"path": "reports/orders-by-region.csv", "contains": ["north-share.season-last-year,", ",52.1,percent"], "shows": "north region share, percent, Nov 1 to Dec 31 last year"}]}]}
```

## Evidence

- `file`: a line of a file that already exists.
- `command`: `rigor.sh save --dir D --name N -- CMD...` runs a command (a
  `curl` fetch, a query, a computation) and stores its output in
  `evidence/N`. Line 1 records the exit code and line count, so an empty
  result can be pinned (`"contains": ["exit=1 output-lines=0"]`). Line 2
  holds the command and is never matched.
- `transcribed`: when nothing raw can be had, write `evidence/N` yourself.
  Line 1 `# rigor-evidence kind=transcribed date=YYYY-MM-DD`, line 2
  `# source: <url or place>`.

All `contains` strings must sit on one line; if a record spreads over lines,
save a one-line extract. Every number in a supported claim's text, whole
numbers included, must equal a number in its `contains` strings. Put each
figure's cell in its own string: in `"Locations 2026,144"` the `144` follows
a digit and a comma and is not read, so write `["Locations 2026", ",144"]`.
Put names and date labels in backticks (`` `Nov 11-17` ``); they are not
checked. A full date such as 2026-11-17 counts as its year only. A figure in another form than the record (31.25% against 0.3125)
must come from a saved computation that prints it.

## Gates

`start` lists the gates in the project's `rigor-gates.json` or
`tools/rigor-gates.json` without running them. Read each command. Run only
commands that are checks; tell the user about one that would change state.
Then `rigor.sh gates --dir D --tag T` (or `--all`, or `--skip "<reason>"`).
A failing gate stays open until it passes or you record
`--ack NAME="<why it does not block the answer, or that it is the finding>"`.
An acknowledged failure is reported as failed, never as a pass.

## Challenge

When the claims are clear, `next` writes `challenge-brief.md` and names the
model and effort. Start that model as a fresh, read-only agent through
whatever the runtime offers that can reach the other provider's models (for
example `delegate_task` in T3 Code), with the effort under the option name
the runtime uses (for example `effort` or `reasoningEffort`). Give it the brief and none of your
reasoning; make sure it can read the files. If the runtime cannot reach that
model, tell the user which one and ask; never substitute. Save its reply
unedited, then run `rigor.sh verdict --dir D --model <model it ran> --effort
<effort it ran> --file <reply>`. A different model or effort is refused
unless you add `--override-reason "<why>"`. A malformed reply is refused: ask
the challenger again; do not edit the reply.

Where you and the challenger disagree, change the status, or keep it and add
`"rebuttal": {"text": ..., "evidence": [new items]}`; the claim is then
reported as disputed. Answer every `MISSED:` item in `"missed": {"M1": ...}`
with a new claim or why it is not relevant. Editing a claim's text, type,
basis or evidence after the challenge makes it not challenged. One round.

## Answer

Run `rigor.sh report --dir D` and write the answer from it. The direct
answer first. State as fact only upheld claims. Word an explanation as the
best supported explanation, with the rivals ruled out. Label disputed, not
challenged, uncertain and unchecked items. Copy every figure from the
report. Name acknowledged gate failures.

## Habits the script cannot check

- Go to the primary record, not a summary or a proxy.
- Compute; do not recall. Save the computation.
- Widen the period before concluding (the year, not one month).
- Check what changed on the platform since this last worked.
- If money is being spent on the thing in question, say so first.

A register kept in a project: `rigor.sh check --claims FILE [--root DIR]`.
Exit codes: 0 clear, 1 open demands or failing checks, 2 usage or error.
