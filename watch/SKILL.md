---
name: watch
description: Keep an eye on anything that runs long enough to fail while nobody is looking, so a crash, a hang or a silent death is noticed in seconds, not hours. Works for a command on this machine, an app or server left running, a job somewhere else (a CI run, a cloud job, a deploy, a download) and another agent's task. A bash script starts the job detached from the session, checks it itself - exit code, death without an exit code, no progress, error lines, a failing health probe, low disk or memory, overrun - and wakes you only when something changes; it demands a quick dry run before the long one. Use when the user invokes watch; before starting anything that will run for more than a few minutes or that you will not sit and watch; when you leave an app or server running; when you wait on work you did not start; when a background job died, hung or was lost to a restart; when asked to monitor, babysit or health-check something; and after a restart or a context summary, to find work still running.
---

# Watch

The script is `scripts/watch.sh`, next to this file. It needs bash and the
standard Unix tools, `ps` among them, and `timeout` or `perl` to put a time
limit on your check commands; no jq. It is written for Linux and macOS and
has been tested on Linux.

Put the work under watch, keep one watcher on it until it is over, and do
what each `Next:` line says. The work can be anything that takes a while: a
build, a test suite, a data import, a migration, a scrape, a render, a
training run, a batch of documents; an app or server you leave running; a
job on another machine or service; another agent's task.

## What it catches and what it cannot

Silence is not health. A watcher that searches a log for error words reports
nothing when a job hangs, is killed, or fails in words nobody listed. The
script checks things that do not depend on wording:

- the exit code, and a death that leaves no exit code (a kill from outside);
- no progress for too long, where progress is the log growing, or the
  files and folders you name changing;
- error lines in the output, including ones the job retries past quietly;
- a health probe you supply, for something that should keep answering;
- disk or memory about to run out, and a run that outlasts its limit.

What it cannot do:

- Tell that healthy work is producing the wrong thing: an empty report,
  rows in the wrong table, output that looks fine and is not. Look at the
  result yourself at the first moment it can be wrong. Set a `--milestone`
  to be woken there, check the result, and stop the job if it is already
  spoiled.
- See a hang that keeps printing, such as a retry loop, by its log alone:
  the log still grows. The time limit (`--max`) catches it, and so does a
  `--progress` path, because named paths replace log growth as the sign of
  progress.
- Check anything while no watcher (`follow` or `wait`) is running. Between
  watchers nothing is looked at, though a started job's exit code is still
  recorded.

## Dry run first

Most long runs that fail do so on something a ten-second run would have
shown: a tool that is not installed, a service that is not ready, a path or
a credential that is wrong. `start` therefore demands `--preflight CMD`, a
command that finishes in seconds and exercises each risky step once. If it
fails, the job is not started. It gets five minutes
(`--preflight-timeout`). If the job has no quick mode, give it one (a
dry-run flag, a limit of a few items, a tiny input) before the long run;
that costs less than one failed run. Pass `--no-preflight "<reason>"` only
when a dry run would cost as much as the job, or the job starts in seconds.

When a run fails partway, add the step that failed to the preflight before
you run it again.

## Three ways to put work under watch

**A command on this machine: `start`.** Prefer this. The job is detached and
its exit code is recorded.

```
watch.sh start --name import-2026 --preflight "./import.sh --limit 20" \
  --stall 5m --progress out/ --max 2h -- ./import.sh
```

`--max DUR` is required: say the longest the job should take, and you are
told when it runs past that (`--max off` for something meant to run for
good). The command goes after `--` as separate words. For a pipeline or several
steps, put them in a script file and run that. The job runs in the current
folder (`--cwd` to change it) with your environment. The command must stay
in the foreground until the work is done: if it starts something in the
background and returns, the job counts as finished and what it left behind
may be stopped. Start the server command itself, not a script that
daemonises it. One name runs once at a time: a second `start` with a live
name is refused, because two copies of a job fight over the same files and
ports.

For an app or server you leave running, there is no end to wait for and
no steady output, so turn the stall check off and give it a health probe:

```
watch.sh start --name api --no-preflight "starts in seconds" --max off \
  --stall off --probe "curl -fsS localhost:3000/health" -- npm run serve
```

**A process that is already running: `attach --pid`.**

```
watch.sh attach --name api --pid 4242 --log logs/api.log --probe "curl -fsS localhost:3000/health"
```

Watch did not start it, so its exit code cannot be known. When it ends, the
end is reported as `EXITED`, result unknown, unless an `--until` or
`--fail-when` check of yours says how it went. It is not detached; it dies
with whatever started it. `stop` will not stop it.

**Anything else: `attach` with checks of your own.** For work that is not a
process here, you supply the commands that say how it is going, and a time
limit.

```
watch.sh attach --name ci-run --probe-every 1m --max 1h \
  --until "ci status 8812 | grep -q passed" \
  --fail-when "ci status 8812 | grep -Eq 'failed|cancelled'"
```

`--until CMD` ends the watch as `FINISHED` when the command exits 0;
`--fail-when CMD` ends it as `FAILED`. Each is one line (several steps go in
a script file). Both run every `--probe-every`, and once at `attach`, which
refuses a command that cannot run. Later, a command
that cannot run (not found, not executable, no answer in 30 seconds) is
reported as `CHECK BROKEN`. A command that runs but fails for a reason of
its own (an expired login, a changed output format) still looks like "not
yet": every `STILL RUNNING` line shows what each check last printed, so read
it, and put the error words you know into `--fail-when`. `--max` is
required here too. This machine's disk and memory are not checked for work
that runs elsewhere, unless you pass `--min-disk-mb` or `--min-mem-mb`. A
watch like this ends only through its checks or your `end`: end the ones
you no longer need. A `--log` or `--progress` path with `--stall` reports a
hang: use that for another agent's output file or a download that should
keep growing. `--error` and `--milestone` read a log, so they need `--log`.

## Checks

- `--stall DUR` (default `10m` for `start`): report a hang after this long
  with no progress. Choose three to five times the longest normal quiet gap.
  `off` only for something quiet by design, and then give it a `--probe`.
  A job that buffers its output looks silent: turn buffering off for it
  (`PYTHONUNBUFFERED=1`, `stdbuf -oL`), or name a `--progress` path.
- `--progress PATH` (repeatable): a file or folder that changes while the
  work goes on. A folder counts when anything in it, at any depth, is
  added, removed, resized or modified. Named paths replace log growth:
  once you give one, printing alone no longer counts as progress. Use it
  when the job prints little, or prints even when it is stuck.
- `--error REGEX`: lines that mean trouble. The default is a fallback that
  matches common fatal markers (`Error`, `error:`, `fatal:`, `ERR!`,
  `Exception:`, `Traceback`, `FATAL`, `Killed`, out of memory, no space
  left) and can misfire (`Error rate: 0%` matches).
  Whenever you know how the job words its failures and retries, pass that;
  `off` disables it. After a report, further error lines are held for two
  minutes (`--quiet`) and then reported together.
- `--milestone REGEX`: lines worth waking for, such as a finished stage. At
  most one report every five minutes (`--milestone-gap`); the latest match is
  shown in every report.
- `--probe CMD`: a health check that exits 0 when all is well. Runs every
  30 s (`--probe-every`) and gets 10 s to answer (`--probe-timeout`); a
  probe that runs out of time counts as a failure and says so. Three
  failures in a row are reported; so is the first pass, which tells you the
  thing is ready.
- `--max DUR`: report work that is still going after this long. Required
  by `start`, and by `attach` without `--pid`; `off` for none.
- `--min-disk-mb N`, `--min-mem-mb N` (default 1024 each, 0 for off). Disk
  is checked where the job runs and where its log is kept; memory is
  checked on Linux only.

If the work turns out quiet or slow by design, tune the live run instead of
restarting it: `watch.sh set --name N --stall off` (any check).

A started job is detached. On Linux with a systemd user manager it runs as
its own unit, outside the group a harness stops when it restarts, with the
tightest memory limit that applied to you copied onto it. The tests stop such a group and the
job keeps running; a restart of a real harness has not been tried. Such a
unit still stops if the user logs out of the machine while lingering is off
(`loginctl enable-linger` turns it on); `start` says so when that is the
case. A job launched this way also runs outside any sandbox the harness
puts around its own commands, and `start` says so. If your harness
sandboxes commands, either tell the user the job will run outside it or
start with `WATCH_LAUNCHER=setsid`, which keeps it inside.
Elsewhere the job gets its own session, which outlives the shell that
started it but not a harness that kills every process it owns. `start` says
which one you got. Runs are kept in `~/.local/state/agent-watch/runs/` (`WATCH_HOME` moves
them).

## Being woken

The script reports events; how they reach you depends on what your harness
can do. A run takes one watcher at a time; a second is refused.

- **It turns each output line of a background command into a
  notification:** run `watch.sh follow --name N`. It prints a line per event
  until the work is over, with a `Next:` line after each event that asks
  something of you and at the end.
- **It tells you when a background command exits:** run `watch.sh wait
  --name N` in the background. It returns at the next event, with the
  details.
- **It can wake you on a timer** (a loop, a schedule, a reminder): on each
  wake run `watch.sh wait --name N --for 1m`. It reports whatever happened
  since your last look, or `STILL RUNNING`. Checks run only during those
  waits, and a probe needs three failed looks, so keep the timer short.
- **None of these:** run `watch.sh wait --name N` in the foreground whenever
  you would otherwise sit idle, with `--for` shorter than the harness's
  limit for one command.

`follow` and `wait` come back after 25 minutes with `STILL RUNNING` when
the work is still going (`--for DUR`; keep it under your harness's limit
for a background command). `--for` is looked at between checks, so a wait
can run past it by the time your own check commands take: up to 30 seconds
each for `--until` and `--fail-when`, plus the probe's time limit. Leave
that much room. Each time one comes back while the work is still going,
start it again. Work with no watcher is the failure this skill exists to
prevent. If your harness wants background work registered before your turn
ends, do that too.

Exit codes of `wait` and `follow`: 0 the work ended well, or you stopped it;
1 something needs you now, or still does (a stall, a failing probe or an
overrun that you were told about and that has not cleared); 3 still running
and nothing is wrong; 2 usage.

## Events

| Event | Meaning | Do |
| ----- | ------- | -- |
| `FINISHED` | exit 0, or your `--until` check passed | Check what it produced, then tell the user. |
| `FAILED` | non-zero exit, or your `--fail-when` check passed | Find the cause before any rerun. |
| `GONE` | a started job ended with no exit code: killed from outside | Find what killed it (a stop, a reboot, memory). |
| `EXITED` | an attached process ended; how it went is unknown | Check what it produced. Do not report success or failure before that. |
| `STALLED` / `RESUMED` | no progress; progress again | Look at what it waits on. Stop it if hung. |
| `ERROR` | error lines while it keeps running | Read them. It may be retrying; stop it if the result is spoiled. |
| `MILESTONE` | a line you asked to be woken for | Look at what it has produced so far; stop it if that is already wrong. |
| `READY` / `UNHEALTHY` / `HEALTHY` | the probe passed first, fails, passes again | Use it, or fix it. |
| `CHECK BROKEN` | your `--until` or `--fail-when` command cannot run | Fix it with `set`; until then the watch is blind. |
| `LOW DISK` / `LOW MEMORY` | about to run out | Free it now, or the job dies. |
| `OVERDUE` | past `--max` | Check it still does useful work; if so, `set --max` a new limit. |
| `STOPPED` / `ENDED` | you stopped the job / ended the watch | Nothing. |

## After a restart

At the start of a session, after a harness restart, and after a context
summary, run `watch.sh list`. It shows every run, marks the ones still going
with nobody watching, and picks up anything that ended while you were away.
Each run is listed with its command and folder: put a watcher back on each
that is yours, and leave another agent's runs alone. `watch.sh status --name N` shows one run in
full: its checks, every event so far and the end of its log.

## Stop, end, clean

- `watch.sh stop --name N` stops a job that `start` started, and everything
  it started, then ends the watch. If the job had already ended by itself,
  `stop` and `end` report how it ended, not a stop. Stop the old run before you start its
  replacement. It refuses to stop a process you attached to: watch did not
  start it, so stopping it is your call and your command.
- `watch.sh end --name N` ends the watch and leaves the work running. A
  started job stays under control: `stop` still stops it, its name stays
  taken, and `list` shows it until it ends.
- `watch.sh clean` removes finished runs older than a week (`--older DUR`),
  never one whose job still runs. Logs stay on disk until then.

## Habits the script cannot check

- Find the cause before the rerun. A retry wrapped around a failure you have
  not explained hides it, and the next run fails the same way.
- Tell the user when a run fails or is restarted, with the cause. Do not let
  it retry in silence.
- When you tell the user, lead with what happened and what it means for
  them, in plain words, then what you will do next. Leave out event names,
  paths and exit codes unless they ask.
- Do not narrate healthy work. Report what changed; the script stays quiet
  for the same reason.
- Make long jobs resumable (chunks, checkpoints), so a failure costs one
  chunk and not the whole run.
- Delete outputs you no longer need. A full disk kills the next run.

The tests run with `bash scripts/test.sh`.
