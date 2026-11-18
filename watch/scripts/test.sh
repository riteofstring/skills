#!/bin/bash
# Tests for watch.sh. Runs it with /bin/bash (3.2 on macOS). No network; temp folders only.
# Jobs are short sleeps and echoes; every run is stopped and the temp folder removed at the end.
HERE=$(cd "$(dirname "$0")" && pwd -P)
WATCH="$HERE/watch.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/watch-test.XXXXXX") || exit 2
T=$(cd "$T" && pwd -P)
export WATCH_HOME="$T/home" WATCH_INTERVAL=0.2 WATCH_GRACE=0.2 WATCH_LAUNCHER=setsid
pass=0; fail=0; OUT=""

W() { /bin/bash "$WATCH" "$@"; }
cleanup() {
  local d
  for d in "$WATCH_HOME"/runs/*/; do [ -f "$d/name" ] && [ ! -f "$d/final" ] && W stop --dir "$d" >/dev/null 2>&1; done
  rm -rf "$T"
}
trap cleanup EXIT
# check NAME STATUS TEXT CMD...: CMD must exit with STATUS and print TEXT (if TEXT is not empty).
check() {
  local name="$1" want="$2" pat="$3" got; shift 3
  OUT=$("$@" 2>&1); got=$?
  if [ "$got" = "$want" ] && { [ -z "$pat" ] || printf '%s' "$OUT" | grep -qF -- "$pat"; }; then pass=$((pass+1))
  else fail=$((fail+1)); echo "FAIL: $name (exit $got, wanted $want and: $pat)"; printf '%s\n' "$OUT" | head -12 | sed 's/^/    /'; fi
}
# also / nope NAME TEXT: the last output must (not) hold TEXT.
also() { if printf '%s' "$OUT" | grep -qF -- "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (missing: $2)"; printf '%s\n' "$OUT" | head -12 | sed 's/^/    /'; fi; }
nope() { if printf '%s' "$OUT" | grep -qF -- "$2"; then fail=$((fail+1)); echo "FAIL: $1 (should not hold: $2)"; else pass=$((pass+1)); fi; }
# ok NAME CMD...: CMD must succeed.
ok() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $name"; fi; }
# go NAME [checks] -- CMD...: start a job with no preflight and the machine checks off.
go() { local n="$1"; shift; W start --max off --name "$n" --no-preflight "unit test" --min-disk-mb 0 --min-mem-mb 0 "$@" >/dev/null 2>&1; }
dirof() { local d best=""; for d in "$WATCH_HOME"/runs/"$1"-*/; do [ -f "$d/name" ] && best=${d%/}; done; printf '%s' "$best"; }
LONG="sleep 300"

# Usage
check "start wants a preflight decision" 2 "--preflight CMD or --no-preflight" W start --max off --name u1 -- true
check "start wants a command" 2 "needs the command after --" W start --max off --name u2 --no-preflight x
check "start wants a name" 2 "needs --name" W start --max off --no-preflight x -- true
check "start wants a time limit" 2 "start needs --max DUR" W start --name u7 --no-preflight x -- true
check "odd name refused" 2 "letters, digits" W start --max off --name "a b" --no-preflight x -- true
check "bad duration refused" 2 "--stall wants a duration" W start --max off --name u3 --no-preflight x --stall soon -- true
check "bad regex refused" 2 "not a valid extended regular expression" W start --max off --name u4 --no-preflight x --error '(' -- true
check "unknown option refused" 2 "does not know --frobnicate" W start --max off --name u5 --no-preflight x --frobnicate 1 -- true
check "an option without its value" 2 "--name needs a value" W start --max off --name
check "a ref without its value" 2 "--name needs a value" W wait --name
check "a check without its value" 2 "--stall needs a value" W start --max off --name u6 --no-preflight x --stall
check "unknown run" 2 "no run named nothere" W status --name nothere
check "no run given" 2 "say which run" W wait
check "not a run folder" 2 "is not a watch run folder" W status --dir "$T"
check "no command" 2 "start a long job detached" W
check "nothing was started by refused commands" 0 "No runs" W list

# Preflight
check "preflight failure blocks the start" 1 "PREFLIGHT FAILED - exit 4" W start --max off --name p1 --preflight 'echo selector missing; exit 4' -- true
also "preflight output is shown" "selector missing"
also "preflight says the job did not start" "The job was not started"
check "no run after a failed preflight" 0 "No runs" W list
check "preflight timeout" 1 "(timed out after 1s; --preflight-timeout changes the limit)" W start --max off --name p2 --preflight 'sleep 5' --preflight-timeout 1 -- true
check "preflight pass starts the job" 0 "Preflight passed" W start --max off --name p3 --preflight 'true' --min-disk-mb 0 --min-mem-mb 0 -- true
also "start names the checks" "Checks: exit code; no progress for 10m00s (log growth); error lines (default pattern)"
also "start says how to watch" "follow --name p3"
check "no preflight records the reason" 0 "No preflight: it starts in seconds" W start --max off --name p4 --no-preflight "it starts in seconds" --min-disk-mb 0 --min-mem-mb 0 -- true

# How a job ends
go e1 -- bash -c 'echo hi; sleep 0.4; echo bye'
check "finished job" 0 "FINISHED - exit 0" W wait --name e1
also "finished shows the log tail" "bye"
also "finished says to check the output" "Check what it produced"
check "wait on a reported run repeats the ending" 0 "FINISHED - exit 0" W wait --name e1
go e2 -- bash -c 'echo working; sleep 0.4; echo "the selector did not resolve" >&2; exit 3'
check "failed job" 1 "FAILED - exit 3" W wait --name e2
also "failed shows the log tail" "the selector did not resolve"
also "failed asks for the cause first" "find the cause in the log"
check "status of a failed run exits 1" 1 "FAILED - exit 3" W status --name e2
go e10 -- bash -c 'printf "Error: boom at the very end"'
check "a last line with no line end is still read" 0 "ERROR - 1 error line" W wait --name e10
go e11 -- bash -c 'echo "Error: early trouble"; head -c 9500000 /dev/zero | tr "\0" "x" | fold -w 200; sleep 1; echo finished'
check "an error line ahead of more than 8 MiB of output is still read" 0 "ERROR - 1 error line in the log. Latest: Error: early trouble" W follow --name e11
go e3 -- no-such-command-xyz
check "missing command" 1 "FAILED - exit 127" W wait --name e3
also "missing command is named" "(command not found)"
go e4 -- bash -c 'sleep 0.3; kill -9 $$'
check "job killed by SIGKILL" 1 "FAILED - exit 137" W wait --name e4
also "SIGKILL is explained" "out-of-memory killer"
go e5 -- $LONG
kill -9 -- "-$(cat "$(dirof e5)/pgid")" 2>/dev/null
check "job killed with its runner" 1 "GONE - the job ended" W wait --name e5
also "gone explains itself" "without an exit code"
go e6 -- bash -c 'printf "%s|" "$@"; echo' _ plain 'a b' "c'd"
check "arguments keep their spaces and quotes" 0 "plain|a b|c'd|" W wait --name e6
mkdir -p "$T/sub"; go e7 --cwd "$T/sub" -- pwd
check "the job runs in --cwd" 0 "$T/sub" W wait --name e7
WATCH_TEST_VAR=carried go e8 -- bash -c 'echo "var=$WATCH_TEST_VAR"'
check "the job gets the caller's environment" 0 "var=carried" W wait --name e8
ok "the saved environment is removed once read" test ! -e "$(dirof e8)/env.sh"
go e9 -- $LONG
ok "the job is in its own process group" test "$(cat "$(dirof e9)/pgid")" != "$(ps -o pgid= -p $$ | tr -d ' ')"

# Watching: deadline, one watcher, stale lock
check "wait deadline while healthy" 3 "STILL RUNNING" W wait --name e9 --for 1
also "deadline says nothing is wrong" "Nothing is wrong"
check "follow deadline while healthy" 3 "STILL RUNNING" W follow --name e9 --for 1
t0=$(date +%s); WATCH_INTERVAL=5 W wait --name e9 --for 1 >/dev/null 2>&1
ok "a short --for comes back on time even with a long check interval" test $(( $(date +%s) - t0 )) -le 3
W wait --name e9 --for 10 >/dev/null 2>&1 & bg=$!; sleep 0.6
check "a second watcher is refused" 2 "another watcher" W wait --name e9
check "status names the watcher" 0 "Watcher: pid" W status --name e9
check "list shows it watched" 0 "watched by pid" W list
wait $bg
mkdir "$(dirof e9)/lock"; echo 999999 > "$(dirof e9)/lock/pid"
check "a dead watcher's lock is taken over" 3 "STILL RUNNING" W wait --name e9 --for 1
check "status shows nobody watching" 0 "Nobody is watching this run" W status --name e9
check "list marks it unwatched" 0 "UNWATCHED" W list
also "list says what to do" "with nobody watching"

# Control: duplicate names, stop, end, set
check "a second run of the same name is refused" 2 "is still going" W start --max off --name e9 --no-preflight x -- true
check "set changes a check" 0 "NO hang check (--stall off)" W set --name e9 --stall off
check "set takes a limit" 0 "overdue after 1m00s" W set --name e9 --max 1m
check "stop" 0 "stopped" W stop --name e9
check "wait after stop" 0 "STOPPED - you stopped it" W wait --name e9
check "stop when already over" 0 "already over (stopped)" W stop --name e9
check "set on a finished run" 2 "this run is over" W set --name e9 --stall 5
check "the name is free again" 0 "STARTED" W start --max off --name e9 --no-preflight x --min-disk-mb 0 --min-mem-mb 0 -- true
go x1 -- bash -c 'echo "the disk filled up" >&2; exit 9'; sleep 1
check "stop on a job that had already failed reports the failure, not a stop" 1 "FAILED - exit 9" W stop --name x1
also "and says there was nothing to stop" "It had already ended, so there was nothing to stop"
also "and still asks for the cause" "find the cause in the log"
check "wait then shows the failure too" 1 "FAILED - exit 9" W wait --name x1
go x2 -- bash -c 'exit 7'; sleep 1
check "end on a job that had already failed reports the failure" 1 "FAILED - exit 7" W end --name x2
check "a name may not start with a dot" 2 "starts with a letter or digit" W start --max off --name .hid --no-preflight x -- true
go c1 -- bash -c 'sleep 300 & sleep 300'
C1=$(dirof c1); sleep 0.5
check "stop takes the whole process group" 0 "stopped" W stop --name c1
ok "no process of the group is left" bash -c "! kill -0 -- -$(cat "$C1/pgid") 2>/dev/null"
go c2 -- $LONG
check "end leaves the job" 0 "left as it is" W end --name c2
also "end says the process still runs" "still runs"
check "wait after end" 0 "ENDED - you ended the watch" W wait --name c2
ok "the job outlives the ended watch" kill -0 "$(cat "$(dirof c2)/pid")"
kill -9 -- "-$(cat "$(dirof c2)/pgid")" 2>/dev/null

# Hangs
go s1 --stall 1 -- bash -c 'echo a; sleep 3; echo b; sleep 300'
check "silence is reported as a stall" 1 "STALLED - no progress" W wait --name s1
also "stall says the process is alive" "still alive"
also "stall says how to quiet it" "set --name s1 --stall off"
check "status of a stalled run exits 1" 1 "STALLED" W status --name s1
check "progress after a stall is reported" 3 "RESUMED - progress again" W wait --name s1
W stop --name s1 >/dev/null 2>&1
go s3 --stall 1 -- bash -c 'echo a; sleep 300'
check "a stall is reported once as an event" 1 "STALLED - no progress" W wait --name s3
check "a stall that lasts still needs attention at the deadline" 1 "that still needs you" W wait --name s3 --for 1
also "the deadline line names what is wrong" "Still wrong: stalled"
nope "a lasting stall is not called fine" "Nothing is wrong"
check "list names what is wrong" 0 "s3: RUNNING, STALLED" W list
W set --name s3 --stall off >/dev/null 2>&1
check "once the limit is lifted nothing is wrong" 3 "Nothing is wrong" W wait --name s3 --for 1
W stop --name s3 >/dev/null 2>&1
mkdir -p "$T/quiet"
go s5 --stall 1 --progress "$T/quiet" -- bash -c 'while :; do echo "waiting for upstream, retrying"; sleep 0.2; done'
check "a job that only prints, while its named folder does not change, is stalled" 1 "STALLED - no progress" W wait --name s5 --for 10
W stop --name s5 >/dev/null 2>&1
go s6 --stall 1 --max 2 -- bash -c 'while :; do echo "retrying"; sleep 0.2; done'
check "a job that keeps printing past its time limit is overdue" 1 "OVERDUE - still running" W wait --name s6 --for 10
also "overdue says how to give it more time" "set --name s6 --max DUR"
W stop --name s6 >/dev/null 2>&1
mkdir -p "$T/same"
go s7 --stall 2 --progress "$T/same" -- bash -c 'for i in 1 2 3 4 5 6 7 8 9 10; do printf "%s" $((i % 10)) > "$1/state"; sleep 0.4; done' _ "$T/same"
check "a file rewritten at the same size counts as progress" 0 "FINISHED - exit 0" W wait --name s7
mkdir -p "$T/hid/.cache"
go s8 --stall 2 --progress "$T/hid" -- bash -c 'for i in 1 2 3 4 5 6 7 8 9 10; do echo x >> "$1/.cache/part"; sleep 0.4; done' _ "$T/hid"
check "writes inside a hidden folder count as progress" 0 "FINISHED - exit 0" W wait --name s8
ok "no stall was recorded for those" bash -c "! grep -q stalled '$(dirof s8)/events'"
ok "no stall was recorded for it" bash -c "! grep -q stalled '$(dirof s7)/events'"
go r9 --min-disk-mb 999999999 -- $LONG
check "low disk is reported" 1 "LOW DISK" W wait --name r9 --for 5
W set --name r9 --min-disk-mb 0 >/dev/null 2>&1
check "a resource check that was turned off stops asking for attention" 3 "Nothing is wrong" W wait --name r9 --for 1
W stop --name r9 >/dev/null 2>&1
go j1 -- $LONG
check "set refuses an until check on a started job" 2 "--until and --fail-when are for attach" W set --name j1 --until true
check "and the job is still under watch" 3 "STILL RUNNING" W wait --name j1 --for 1
W stop --name j1 >/dev/null 2>&1
go h9 --probe 'sleep 5' --probe-every 1 --probe-timeout 1 -- $LONG
check "a probe that runs out of time says so" 1 "the probe did not answer within 1s" W wait --name h9 --for 20
W stop --name h9 >/dev/null 2>&1
mkdir -p "$T/frames"
go s2 --stall 1 --progress "$T/frames" -- bash -c 'for i in 1 2 3 4 5 6 7 8; do : > "$1/f$i"; sleep 0.3; done' _ "$T/frames"
check "a growing folder counts as progress" 0 "FINISHED - exit 0" W wait --name s2
ok "no stall was recorded" bash -c "! grep -q stalled '$(dirof s2)/events'"
mkdir -p "$T/out/sub"; : > "$T/out/data.csv"
go s4 --stall 2 --progress "$T/out" -- bash -c 'for i in 1 2 3 4 5 6 7 8 9 10; do echo row >> "$1/data.csv"; echo x >> "$1/sub/part"; sleep 0.4; done' _ "$T/out"
check "writes inside a folder count as progress, at any depth" 0 "FINISHED - exit 0" W wait --name s4
ok "no stall was recorded for them" bash -c "! grep -q stalled '$(dirof s4)/events'"
go s3 --stall off -- bash -c 'sleep 300'
check "stall off never fires" 3 "STILL RUNNING" W wait --name s3 --for 2
W stop --name s3 >/dev/null 2>&1

# Error lines
go r1 -- bash -c 'echo up; sleep 0.4; echo "Error: fetch failed"; sleep 300'
check "an error line while running" 1 "ERROR - 1 error line in the log. Latest: Error: fetch failed" W wait --name r1
also "error warns of a quiet retry" "may be retrying quietly"
W stop --name r1 >/dev/null 2>&1
go r2 --quiet 60 -- bash -c 'for i in 1 2 3 4 5 6 7 8; do echo "Error: attempt $i"; sleep 0.4; done; sleep 300'
check "the first error is reported at once" 1 "error line" W wait --name r2
check "later errors wait out the quiet time" 3 "STILL RUNNING" W wait --name r2 --for 4
W stop --name r2 >/dev/null 2>&1
check "held errors are reported when the job ends" 0 "error lines in the log. Latest: Error: attempt 8" W wait --name r2
go r3 --error off -- bash -c 'echo "Error: ignored"; sleep 300'
check "error off" 3 "STILL RUNNING" W wait --name r3 --for 1
W stop --name r3 >/dev/null 2>&1
go r4 -- bash -c 'echo "0 Errors, error_count=0, ErrorBoundary ok"; sleep 300'
check "harmless words are not errors" 3 "STILL RUNNING" W wait --name r4 --for 1
W stop --name r4 >/dev/null 2>&1
go r5 --error 'startup failed|gave up' -- bash -c 'echo "Error: not ours"; echo "attempt 1: startup failed"; sleep 300'
check "a custom error pattern" 1 "Latest: attempt 1: startup failed" W wait --name r5
nope "the custom pattern replaces the default" "2 error lines"
W stop --name r5 >/dev/null 2>&1
go r6 -- bash -c 'printf "p1\rp2\rError: mid bar\rp3"; sleep 300'
check "carriage returns end a line" 1 "Latest: Error: mid bar" W wait --name r6
W stop --name r6 >/dev/null 2>&1

# Milestones
go m1 --milestone 'step [0-9]+ of' -- bash -c 'for i in 1 2 3; do echo "step $i of 3"; done; sleep 300'
check "a milestone is reported" 3 "MILESTONE - step 3 of 3" W wait --name m1
also "a milestone says to look at the result, not to carry on" "this is the moment to look at what it has produced so far"
nope "a milestone is not called nothing" "nothing is wrong"
also "matches are counted" "(3 matches since the last report)"
check "the latest milestone is kept" 3 "Latest milestone: step 3 of 3" W wait --name m1 --for 1
W stop --name m1 >/dev/null 2>&1

# Health probe
go h1 --stall off --probe "test -f '$T/up'" --probe-every 1 -- bash -c 'sleep 1; : > "$1/up"; sleep 300' _ "$T"
check "the first passing probe is reported" 3 "READY - the health probe passed for the first time" W wait --name h1
also "ready says to use it" "it is up and answering its probe"
rm -f "$T/up"
check "a failing probe is reported" 1 "UNHEALTHY - the health probe failed 3 times in a row" W wait --name h1
: > "$T/up"
check "a recovered probe is reported" 3 "HEALTHY - the health probe passes again" W wait --name h1
W stop --name h1 >/dev/null 2>&1
go h2 --stall off --probe 'echo "connection refused"; false' --probe-every 1 -- $LONG
check "a probe that never passes" 1 "UNHEALTHY - the health probe has not passed once" W wait --name h2
also "probe output is shown" "connection refused"
W stop --name h2 >/dev/null 2>&1

# Limits
go l1 --max 1 -- $LONG
check "overdue" 1 "OVERDUE - still running after" W wait --name l1
W stop --name l1 >/dev/null 2>&1
check "low disk" 0 "STARTED" W start --max off --name l2 --no-preflight x --min-disk-mb 999999999 --min-mem-mb 0 -- $LONG
check "low disk is reported" 1 "LOW DISK - only" W wait --name l2
W stop --name l2 >/dev/null 2>&1
if [ -r /proc/meminfo ]; then
  W start --max off --name l3 --no-preflight x --min-disk-mb 0 --min-mem-mb 999999999 -- $LONG >/dev/null 2>&1
  check "low memory is reported" 1 "LOW MEMORY - only" W wait --name l3
  W stop --name l3 >/dev/null 2>&1
fi

# Follow
go f1 -- bash -c 'echo "Error: boom"; sleep 0.5; exit 2'
check "follow streams to the end" 1 "FAILED - exit 2" W follow --name f1
also "follow shows the error event" "ERROR - 1 error line"
also "follow shows the last log line" "last log line: Error: boom"
also "follow says it is over" "over. Details:"
go f2 -- bash -c 'sleep 0.5'
check "follow ends at exit 0" 0 "FINISHED - exit 0" W follow --name f2
also "follow ends with what to do next" "Next: the work is done"
go f4 --stall 1 -- bash -c 'echo a; sleep 4'
check "follow says what to do when it reports a stall" 0 "Next: it is alive but silent" W follow --name f4
# Two starts of one name at once: the second is held off while the first is still in its preflight
W start --max off --name q1 --preflight 'sleep 2' --min-disk-mb 0 --min-mem-mb 0 -- true >/dev/null 2>&1 & qp=$!; sleep 0.5
check "a second start of a name is refused while the first is under way" 2 "another start of q1 is under way" W start --max off --name q1 --no-preflight x -- true
wait $qp
check "and the first one started" 0 "q1: " W list

# Attach
sleep 300 & apid=$!
check "attach to a process" 0 "ATTACHED - pid $apid" W attach --name a1 --pid "$apid" --min-disk-mb 0 --min-mem-mb 0
kill "$apid" 2>/dev/null
check "an attached process that ends" 1 "EXITED - process $apid ended" W wait --name a1
also "attach cannot know the exit code" "exit code is unknown"
also "an unknown ending is not called a failure" "cannot tell whether it went well"
nope "an unknown ending is not called a failure (2)" "Tell the user it failed"
sleep 300 & apid=$!
W attach --name a9 --pid "$apid" --until "test -f '$T/a9done'" --probe-every 1 --min-disk-mb 0 --min-mem-mb 0 >/dev/null 2>&1
: > "$T/a9done"; kill "$apid" 2>/dev/null
check "an attached process whose until check passes ended well" 0 "FINISHED - your --until check passed" W wait --name a9
sleep 300 & apid=$!
W attach --name a10 --pid "$apid" --fail-when "test -f '$T/a10bad'" --probe-every 1 --min-disk-mb 0 --min-mem-mb 0 >/dev/null 2>&1
: > "$T/a10bad"; kill "$apid" 2>/dev/null
check "an attached process whose fail-when check passes failed" 1 "FAILED - your --fail-when check passed" W wait --name a10
sleep 300 & apid=$!
W attach --name a11 --pid "$apid" --min-disk-mb 0 --min-mem-mb 0 >/dev/null 2>&1
check "stop does not kill a process watch did not start" 2 "stop only stops a job that watch started" W stop --name a11
ok "that process is still alive" kill -0 "$apid"
check "end stops watching it" 0 "left as it is" W end --name a11
kill "$apid" 2>/dev/null
: > "$T/a.log"
check "attach to a log" 0 "ATTACHED" W attach --name a2 --log "$T/a.log" --stall 1 --max off --min-disk-mb 0 --min-mem-mb 0
check "a silent attached log stalls" 1 "STALLED" W wait --name a2
nope "a stall with no process does not claim one is alive" "alive"
echo "Error: from the log" >> "$T/a.log"
check "an attached log is read for errors" 1 "Latest: Error: from the log" W wait --name a2
check "stop without a process ends the watch" 0 "no process to stop" W stop --name a2
check "attach to work that is not a process" 0 "done when this passes" W attach --name a6 --until "test -f '$T/done'" --fail-when "test -f '$T/broke'" --probe-every 1 --max 5m --min-disk-mb 0 --min-mem-mb 0
check "nothing to report while the work goes on" 3 "STILL RUNNING" W wait --name a6 --for 2
: > "$T/done"
check "the until check ends the watch as finished" 0 "FINISHED - your --until check passed" W wait --name a6
check "attach with a failure check" 0 "failed when this passes" W attach --name a7 --until "test -f '$T/never'" --fail-when "echo 'conclusion: failure'; test -f '$T/broke'" --probe-every 1 --max 5m --min-disk-mb 0 --min-mem-mb 0
: > "$T/broke"
check "the fail-when check ends the watch as failed" 1 "FAILED - your --fail-when check passed" W wait --name a7
also "the check's output is shown" "conclusion: failure"
check "until is not for started jobs" 2 "--until and --fail-when are for attach" W start --max off --name a8 --no-preflight x --until true -- true
check "attach wants something to check" 2 "needs something to check" W attach --name a3
check "attach to a dead process" 2 "is not running" W attach --name a4 --pid 999999
check "stall without a signal" 2 "--stall needs --log or --progress" W attach --name a5 --probe true --stall 5
check "attach without a process wants a time limit" 2 "needs --max DUR" W attach --name b3 --until true
check "an error pattern needs a log to read" 2 "--error reads a log" W attach --name b5 --until true --max 5m --error boom
check "attach to a check that runs but errors" 0 "ATTACHED" W attach --name b6 --until "echo 'authentication token expired'; exit 4" --probe-every 1 --max 5m --min-disk-mb 0 --min-mem-mb 0
check "such a check is not hidden: its last output is shown" 3 "Your --until check last printed: authentication token expired" W wait --name b6 --for 2
nope "and the watch does not call that fine" "Nothing is wrong"
also "it says to read what the check printed" "Read what your check printed"
check "list shows what an attached watch is watching, and where" 0 "watching until: echo 'authentication token expired'; exit 4   (in " W list
W end --name b6 >/dev/null 2>&1
W attach --name b8 --fail-when "echo 'login expired' >&2; exit 3" --until "false" --probe-every 1 --max 5m >/dev/null 2>&1
check "one check's output is not hidden by the other's" 3 "Your --fail-when check last printed: login expired" W wait --name b8 --for 2
check "a watch on work elsewhere does not check this machine's disk or memory" 0 "overdue after 5m00s" W status --name b8
nope "(no disk check)" "disk under"
W end --name b8 >/dev/null 2>&1
check "a check command must be one line" 2 "--until must be one line" W attach --name b7 --max 5m --until "true
false"

# Your own checks: one that cannot run is never read as "not yet"
check "attach refuses a check that cannot run" 2 "cannot run here" W attach --name b1 --until "no-such-command-xyz status | grep -q passed" --max 5m
also "and shows why" "command not found"
check "and leaves no run behind" 2 "no run named b1" W status --name b1
check "attach says when a check passes already" 0 "passes already" W attach --name b4 --until true --max 5m --min-disk-mb 0 --min-mem-mb 0
check "and the first look reports it" 0 "FINISHED - your --until check passed" W wait --name b4
printf 'exit 1\n' > "$T/chk.sh"
check "attach tries the check once" 0 "ATTACHED" W attach --name b2 --until "bash '$T/chk.sh'" --probe-every 1 --max 5m --min-disk-mb 0 --min-mem-mb 0
rm -f "$T/chk.sh"
check "a check that stops running is reported" 1 "CHECK BROKEN - your --until or --fail-when command cannot run" W wait --name b2 --for 15
also "and says the watch is blind" "the watch is blind until that command runs"
check "and still needs attention at the next deadline" 1 "that still needs you" W wait --name b2 --for 1
nope "and is not called fine" "Nothing is wrong"
printf 'exit 1\n' > "$T/chk.sh"
check "a repaired check is reported" 3 "HEALTHY - your --until and --fail-when commands run again" W wait --name b2 --for 15
W end --name b2 >/dev/null 2>&1

# Housekeeping
check "list keeps recent runs" 0 "e1: FINISHED" W list
go k1 -- $LONG
check "clean removes only finished runs" 0 "finished runs older than 0s" W clean --older 0
check "a running job survives clean" 0 "k1: RUNNING" W list --all
also "list shows the command and its folder" "sleep 300   (in "
nope "finished runs are gone" "e1: FINISHED"
W stop --name k1 >/dev/null 2>&1
go k2 -- $LONG
check "a taken name is refused before the preflight runs" 2 "is still going" W start --max off --name k2 --preflight ": > '$T/pre-ran'" -- true
ok "the preflight did not run" test ! -e "$T/pre-ran"
# Ending a watch does not end the job, so the job stays under control
check "end leaves a started job running" 0 "still stops it" W end --name k2
check "the name stays taken while that job runs" 2 "is still going" W start --max off --name k2 --no-preflight x -- true
W clean --older 0 >/dev/null 2>&1
ok "clean keeps a run whose job still runs" test -d "$(dirof k2)"
touch -t 202001010000 "$(dirof k2)/final"
check "list still shows it long after the watch ended" 0 "k2: ENDED, but its job still runs" W list
check "stop still stops the job" 0 "stopped" W stop --name k2
ok "the job is gone" bash -c "! kill -0 $(cat "$(dirof k2)/pid") 2>/dev/null"
check "wait then shows it was stopped" 0 "STOPPED - you stopped the job after its watch had ended" W wait --name k2
check "the name is free once the job is gone" 0 "STARTED" W start --max off --name k2 --no-preflight x --min-disk-mb 0 --min-mem-mb 0 -- true

# The systemd launcher, where there is a user manager
if command -v systemd-run >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  export WATCH_LAUNCHER=systemd
  check "systemd launch" 0 "detached as systemd unit watch-d1-" W start --max off --name d1 --no-preflight x --min-disk-mb 0 --min-mem-mb 0 -- $LONG
  D1=$(dirof d1)
  ok "the job has its own cgroup" grep -q "watch-d1-" "$D1/cgroup"
  ok "the job left the caller's cgroup" test "$(cat "$D1/cgroup")" != "$(sed -n 's/^0:://p' /proc/self/cgroup)"
  check "the start line says the job outlives the session" 0 "it is not stopped when this session or its harness scope is" W status --name d1
  echo no > "$D1/linger"
  check "without lingering it says the job stops at logout" 0 "lingering is off" W status --name d1
  check "systemd stop" 0 "stopped" W stop --name d1
  ok "the unit is gone" bash -c "! systemctl --user is-active --quiet '$(cat "$D1/unit")'"
  WATCH_TEST_VAR=carried go d2 -- bash -c 'echo "var=$WATCH_TEST_VAR"; exit 5'
  check "systemd job exit code" 1 "FAILED - exit 5" W wait --name d2
  also "systemd job gets the caller's environment" "var=carried"
  # The tightest memory limit on the caller is copied onto the job's unit
  systemd-run --user --quiet --scope -p MemoryMax=300M /bin/bash -c "/bin/bash '$WATCH' start --max off --name d5 --no-preflight x --min-disk-mb 0 --min-mem-mb 0 -- sleep 300" >/dev/null 2>&1
  check "a job started from a memory-limited scope keeps that limit" 0 "MemoryMax=314572800" systemctl --user show "$(cat "$(dirof d5)/unit" 2>/dev/null)" -p MemoryMax
  W stop --name d5 >/dev/null 2>&1
  # A harness that stops its own scope: a systemd-launched job stays, a setsid-launched one goes.
  hs="watch-test-harness-$$"
  systemd-run --user --quiet --scope --unit="$hs" /bin/bash -c "/bin/bash '$WATCH' start --max off --name d3 --no-preflight x --min-disk-mb 0 --min-mem-mb 0 -- sleep 300; WATCH_LAUNCHER=setsid /bin/bash '$WATCH' start --max off --name d4 --no-preflight x --min-disk-mb 0 --min-mem-mb 0 -- sleep 300; sleep 300" >/dev/null 2>&1 &
  i=0; while { [ ! -s "$(dirof d3)/pid" ] || [ ! -s "$(dirof d4)/pid" ]; } && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
  ok "both jobs started inside the scope" bash -c "kill -0 $(cat "$(dirof d3)/pid") && kill -0 $(cat "$(dirof d4)/pid")"
  systemctl --user stop "$hs.scope" >/dev/null 2>&1; sleep 1
  ok "a systemd-launched job outlives the scope that started it" kill -0 "$(cat "$(dirof d3)/pid")"
  check "and can still be watched" 3 "STILL RUNNING" W wait --name d3 --for 1
  check "a setsid-launched job dies with that scope, and is reported" 1 "GONE - the job ended" W wait --name d4
  W stop --name d3 >/dev/null 2>&1
  export WATCH_LAUNCHER=setsid
else
  echo "skipped: the systemd launcher (no systemd user manager here)"
fi

echo "watch tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
