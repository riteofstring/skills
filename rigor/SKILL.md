---
name: rigor
description: Get an answer the user can trust. Investigate a factual question against evidence and report as fact only what survives, with the rest labelled. Evidence is anything that can be cited by line - a project file, or the saved output of a query, an API call, a fetched page or a computation. A bash script drives the run - it demands a frame, the project's own checks where it lists them, claims pinned to source lines with checked numbers, and an attack on the claims by a model of the other provider family - and refuses to finish while a demand is open. Use when the user invokes rigor; when they will act on the answer and a wrong one is costly or hard to undo (money, an irreversible change, a public claim); when a figure, a cause or an earlier answer is in doubt or disputed; when results are bad and nobody knows why. Not for quick lookups or routine debugging.
---

# Rigor

The script is `scripts/rigor.sh`, next to this file. It needs `jq`. First run
`start`, then do what `next` prints until it prints `RIGOR: DONE`. Answer
after that. Do the investigation yourself: the challenger is the only other
agent this skill asks for.

## What the script can and cannot establish

It checks form and consistency: that a claim points at a line that exists,
that the numbers in its text match that line, and that the required second
looks were recorded. It does not prove a claim is true, that a figure was
computed correctly, or that the right record was chosen. It does not check
numbers inside backticks or written as words, cannot tell a thousands comma
from a comma between two cells, and does not know which model really ran.
Those rest on the challenger, who recomputes from the files. A claim the
challenger agrees with is upheld, not proven. A wrong yardstick or a rule
that changed is caught only by your frame and the challenger. The skill only
works when it is run.

## Start

```
rigor.sh start --question "<the user's question, verbatim>" --coordinator <your model id> [--dir D] [--root R]
```

- A Claude coordinator gets `gpt-6.2-astra` at `max`; an OpenAI coordinator
  gets `claude-fable-5-2` at `high`. Those defaults are the two lines at the
  top of the script. If the user names another model or effort, pass
  `--challenger`, `--effort` and `--override-reason "<what the user said>"`;
  do not ask again. Anything but the default is the user's choice, never
  yours, and that includes your own model. Every run has a challenger; a
  run without one does not finish. Check now that you can start the
  challenger: if you cannot, ask the user at once (see Challenge) and keep
  investigating while they decide, so the wait does not come at the end.
- The run folder is a disposable temp folder unless you pass `--dir`. In a
  project, pass `--dir` under a git-ignored folder.
- The root is `--root`, else the git top level, else the current folder.
  Relative evidence paths are under the root; `evidence/...` is in the run
  (write `./evidence/...` for a folder of that name in the project).
- `start` and `next` exit 1 while demands are open. That is normal.

## Frame (edit `claims.json` in place)

`frame`: `question` (verbatim); `evidence_date` (the date the evidence runs
to); `kind` (`cause` when the user asks why something happened or what is
going on, else `fact`); `primary_records` (`{record, why}`: why it is the
source closest to the truth, not a proxy); `changed_since` (versions, dates,
rules, prices); `not_checked`; optional `figures_from`. A `cause` question
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
`waive` (`{"R2": "reason"}`; R1 cannot be waived). The rules by name: R1
evidence on a real line; R2 numbers match the pinned line; R3 a comparison
is cross-checked; R4 a cause has no open rival; R5 a closed rival says why;
R6 a disproof is stated. Do not enter
recommendations or decisions; enter a forecast as uncertain. A supported
comparison names a claim that tests it on another period, baseline or
source. A cause is `inferred` and is supported only when no rival is open.
Comparisons and causes state their `disproof`. Example (a shop asking about
its orders by region; C3 is the second look for C2, a different baseline):

```json
{"frame": {"question": "Did the north region's share of orders drop?", "evidence_date": "2026-11-15",
   "kind": "fact", "primary_records": [{"record": "reports/orders-by-region.csv", "why": "exported from the order system, not read off a dashboard"}],
   "changed_since": "The shipping zones were redrawn in March", "not_checked": ["orders by city inside the region"], "rivals": [], "figures_from": "the order system's export"},
 "claims": [
  {"id": "C1", "text": "In the week of `Nov 9` the north region got 31.25% of orders.", "type": "fact", "basis": "observed", "status": "supported",
   "evidence": [{"path": "reports/orders-by-region.csv", "contains": ["north-share.week,", ",31.25,percent"], "shows": "north region share of orders, percent, week of Nov 9 2026"}]},
  {"id": "C2", "text": "The share fell from 58.4% in the same week `last year` to 31.25%.", "type": "comparison", "basis": "observed", "status": "supported",
   "evidence": [{"path": "reports/orders-by-region.csv", "contains": ["north-share.week-last-year,", ",58.4,percent"], "shows": "north region share, percent, same week last year"},
                {"path": "reports/orders-by-region.csv", "contains": ["north-share.week,", ",31.25,percent"], "shows": "north region share, percent, week of Nov 9 2026"}],
   "cross_checks": ["C3"], "disproof": "a period last year with a share near this week's; looked at last year's whole season in the same file"},
  {"id": "C3", "text": "Over all of `last year's` season the share was 52.1%.", "type": "fact", "basis": "observed", "status": "supported",
   "evidence": [{"path": "reports/orders-by-region.csv", "contains": ["north-share.season-last-year,", ",52.1,percent"], "shows": "north region share, percent, Nov 1 to Dec 31 last year"}]}]}
```

## Evidence

Evidence is anything you can cite by line. It does not have to be in the
project already: fetch it, query it or compute it, and save the output.

- `file`: a line of a file that already exists.
- `command`: `rigor.sh save --dir D --name N -- CMD...` runs a command (a
  `curl` fetch, a query, a computation) and stores its output in
  `evidence/N`. Line 1 records the exit code and line count, so an empty
  result can be pinned (`"contains": ["exit=1 output-lines=0"]`). Line 2
  holds the command and the folder it ran in, and is never matched. For a
  pipeline or a redirect, pass `bash -c '<the whole command line>'`;
  otherwise the shell runs the rest outside `save` and only the first
  command's output is stored. Keep secrets off the command line, because
  line 2 records it and the challenger reads the file: read a token from
  the environment inside `bash -c`.
- `transcribed`: when nothing raw can be had, write `evidence/N` yourself.
  Line 1 `# rigor-evidence kind=transcribed date=YYYY-MM-DD`, line 2
  `# source: <url or place>`.

All `contains` strings must sit on one line; if a record spreads over lines,
save a one-line extract. Every number in a supported claim's text, whole
numbers included, must equal a number in its `contains` strings. Pin whole
numbers: a string that stops in the middle of one (`",3"` on a line holding
`31.25`) is refused. A minus or plus sign written before a number in the
text must stand before the pinned number too. Put each figure's cell in its
own string: in `"Locations 2026,144"` the `144` follows a digit and a comma
and is not read, so write `["Locations 2026", ",144"]`. Put names and date
labels in backticks (`` `Nov 11-17` ``); they are not checked, so never put
a figure in them. A full date such as 2026-11-17 counts as its year only. A
figure in another form than the record (31.25% against 0.3125) must come
from a saved computation that prints it.

## Gates

Gates are checks a project keeps for itself, in `rigor-gates.json` or
`tools/rigor-gates.json` under the root:
`{"gates": [{"name": "...", "tags": ["..."], "run": "<a command that exits 0 when the check passes>"}]}`.
Output lines that begin with `FAIL`, `NO DATA` or `WARN` are copied into
the report. A project without the file has no gates and this stage is
skipped.

`start` lists the gates without running them. Read each command. Run only
commands that are checks; tell the user about one that would change state.
Then `rigor.sh gates --dir D --tag T` (or `--all`, or `--skip "<reason>"`).
A failing gate stays open until it passes or you record
`--ack NAME="<why it does not block the answer, or that it is the finding>"`.
An acknowledged failure is reported as failed, never as a pass, and a skip
does not clear a gate that has already failed.

## Challenge

When the claims are clear, `next` writes `challenge-brief.md` and names the
model and effort. Start that model as one fresh, read-only agent through
whatever the runtime offers that can reach the other provider's models: a
delegation tool (for example `delegate_task` in T3 Code), or that provider's
own command-line agent if it is installed. Pass the effort under the option
name the runtime uses (for example `effort` or `reasoningEffort`). Give it
the brief and none of your reasoning; make sure it can read the files. The
brief shows it your frame, rivals, cross-checks and waivers, and asks it to
audit them. If time has passed since you saved the evidence and what you
measured can change, save it again before you send the brief. Save the
reply unedited, then run `rigor.sh verdict --dir D
--model <model it ran> --effort <effort it ran> --file <reply>`. A reply
that lacks its `BRIEF` line, a reason on a verdict line, or a `MISSED` line
is refused: ask the same challenger to send it again in the format; do not
edit the reply. Leave the claims, the frame and the evidence alone while
the challenger works: if they change, `next` rewrites the brief under a new
id, and a reply to the old one is refused.

If the runtime cannot run that model, or has no effort of that name, stop
and ask the user to choose:
another model, by name, or a fresh agent of your own model, which is a weaker
check because it shares your blind spots. Never choose for them, and do not
give the answer while you wait. Run the one they chose and add
`--override-reason "<what the user said>"` to `verdict`; a different model or
effort is refused without it. The report marks a challenger of your own
model or family. If the user wants neither, the run stays unfinished: there
is no report, and anything you tell them is unchecked. Say so.

Where you and the challenger disagree, change the status, or keep it and add
`"rebuttal": {"text": ..., "evidence": [new items]}`; the claim is then
reported as disputed. Answer every `MISSED:` item in `"missed": {"M1": ...}`
with a new claim, how the answer accounts for it, or why it does not matter.
The challenger's agreement covers only what it was shown. A claim becomes
not challenged when, after the challenge, you edit its text, type, basis,
evidence, cross-checks or waivers; when a file it cites changes; when a
claim it rests on (a cross-check, or a claim a rival was closed with)
becomes not challenged, however long the chain; and, for a cause, when the
rivals change. Other
frame edits are listed in the report, which also keeps what the challenger
said about the earlier version. A claim the challenger did not accept
cannot be reworded back to supported: once changed, it has to be marked
uncertain. Nor can it be dropped quietly: taking it out of the register
needs a reason in `"removed": {"C2": "..."}`. One round: to have a
corrected claim checked, start a new run.

## Answer

Run `rigor.sh report --dir D` and write the answer from it, in plain words
for someone who has not seen the report: the direct answer first, then what
it rests on. Say "a second AI checked this and agreed", not "upheld"; leave
out claim ids and rule names unless asked. State as fact only upheld claims.
Word an explanation as the best supported explanation, with the rivals
ruled out. Say which items are disputed, not challenged, uncertain or
unchecked, and for a claim changed after the challenge, what the challenger
said about the earlier version. Copy every figure from the report. Name
acknowledged gate failures, waived checks, and any claim the challenger
did not accept that you dropped, with why. If the report says the
challenger was your own model or family, say that too. If the claim the
user will act on was changed or added after the challenge, say that first
and offer a new run on it.

## Habits the script cannot check

- Go to the primary record, not a summary or a proxy.
- Compute; do not recall. Save the computation.
- Widen the period before concluding (the year, not one month).
- Check what changed since this last worked: a version, a rule, a price.
- If the thing in question is costing money while you look into it, tell
  the user that before anything else.

To keep the claims for later, for example to check them again when the data
changes, copy `claims.json` into the project. Such a register must cite
project files, not a temp run folder; `rigor.sh check --claims FILE [--root
DIR]` runs the form checks on it again.

Exit codes: 0 clear, 1 open demands or failing checks, 2 usage or error.
