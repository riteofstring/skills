#!/bin/bash
# watch.sh: starts a long job detached and watches it (see ../SKILL.md). Runs under bash 3.2; needs no jq.
# Exit codes: 0 the job ended well or you ended the watch; 1 something needs you, or still does
# (failed, gone, ended with no known result, stalled, error lines, unhealthy, a check that cannot
# run, low disk or memory, overdue); 2 usage or script error; 3 still running and nothing is wrong.
# Everything is a function and the last line calls main, so a run that lasts hours is not
# broken when this file is edited under it.

SELF=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)/$(basename "$0")
BASE="${WATCH_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-watch}"
case "$BASE" in /*) ;; *) BASE="$PWD/$BASE";; esac   # a job runs in another folder, so the path must not be relative
RUNS="$BASE/runs"
INTERVAL="${WATCH_INTERVAL:-5}"; GRACE="${WATCH_GRACE:-1}"
# Lines that are rarely good news. A job with its own failure wording needs --error.
DEF_ERROR='(^|[^[:alnum:]_])(Error|ERROR|FATAL|panic|Killed|OOM|ENOSPC|ENOMEM)([^[:alnum:]_]|$)|error:|fatal:|ERR!|Exception:|Traceback|Unhandled|Segmentation fault|No space left on device|[Oo]ut of memory'
BAD=" failed gone exited stalled error unhealthy check-broken low-disk low-memory overdue "
D=""; R_dir=""; R_name=""; LIGHT=""; RESERVED=""
C_stall=""; C_error=""; C_milestone=""; C_msgap=""; C_quiet=""; C_probe=""; C_pevery=""; C_ptimeout=""; C_max=""; C_disk=""; C_mem=""; C_progress=""; C_until=""; C_failwhen=""

die() { printf 'watch: %s\n' "$*" >&2; exit 2; }
now() { date +%s; }
num() { case "$1" in ''|*[!0-9]*) echo 0;; *) echo "$1";; esac; }
get() { local v=""; if [ -f "$D/$1" ]; then IFS= read -r v < "$D/$1"; printf '%s' "$v"; else printf '%s' "${2-}"; fi; }
put() { printf '%s\n' "$2" > "$D/$1.new" && mv -f "$D/$1.new" "$D/$1"; }
has() { [ -e "$D/$1" ]; }
flag() { : > "$D/$1"; }
fsize() { if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
clock() { date -d "@$1" +%H:%M 2>/dev/null || date -r "$1" +%H:%M 2>/dev/null; }
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr '-' ' '; }
# An argument as a person would type it: bare when it is plain, single-quoted otherwise.
shq() {
  local a out=""
  for a in "$@"; do
    case "$a" in ''|*[!A-Za-z0-9_./:=@%+,-]*) a="'$(printf '%s' "$a" | sed "s/'/'\\\\''/g")'";; esac
    out="$out $a"
  done
  printf '%s' "${out# }"
}
SELF=$(shq "$SELF")   # it is only ever printed, inside commands for the agent to run
okre() { printf '' | LC_ALL=C grep -E -- "$1" >/dev/null 2>&1; [ $? -le 1 ]; }
# 90 | 90s | 15m | 2h | 1d | off -> seconds (off is 0)
secs() {
  case "$1" in off|none|no) echo 0; return 0;; esac
  [[ "$1" =~ ^([0-9]+)([smhd]?)$ ]] || return 1
  case "${BASH_REMATCH[2]}" in
    m) echo $(( 10#${BASH_REMATCH[1]} * 60 ));; h) echo $(( 10#${BASH_REMATCH[1]} * 3600 ));;
    d) echo $(( 10#${BASH_REMATCH[1]} * 86400 ));; *) echo $(( 10#${BASH_REMATCH[1]} ));;
  esac
}
dur() {
  local s=$1; [ "$s" -lt 0 ] && s=0
  if [ "$s" -lt 60 ]; then printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%sm%02ds' $((s / 60)) $((s % 60))
  else printf '%sh%02dm' $((s / 3600)) $((s % 3600 / 60)); fi
}
with_timeout() {
  local s=$1; shift
  if command -v timeout >/dev/null 2>&1; then timeout -k 2 "$s" "$@"
  elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV or exit 127' "$s" "$@"
  else "$@"; fi
}

# A process is tracked by its id and its start time, never by its name: a watcher that
# greps the process list for a command can match itself and never end.
pstart() { LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//;s/ *$//'; }
pid_alive() {
  local st; [ -n "$1" ] || return 1
  st=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' '); [ -n "$st" ] || return 1
  case "$st" in Z*) return 1;; esac
  [ -z "$2" ] || [ "$(pstart "$1")" = "$2" ]
}
alive() { pid_alive "$(get pid)" "$(get pidstart)"; }
el() { echo $(( ${1:-$(now)} - $(num "$(get started "$(get created)")") )); }

event() {
  local n text; n=$(( $(num "$(get seq)") + 1 )); put seq "$n"
  text=$(printf '%s' "$2" | tr '\n\t\r' '   ')
  printf '%s\t%s\t%s\t%s\n' "$n" "$(now)" "$1" "$text" >> "$D/events"
}
fresh() { [ -f "$D/events" ] && awk -F'\t' -v d="$(num "$(get delivered)")" '$1 > d' "$D/events"; }
show() {
  local n ts kind text name; name=$(get name)
  while IFS=$'\t' read -r n ts kind text; do printf 'watch %s: %s - %s\n' "$name" "$(upper "$kind")" "$text"; done
}
anybad() {
  local n ts kind text bad=1
  while IFS=$'\t' read -r n ts kind text; do case "$BAD" in *" $kind "*) bad=0;; esac; done
  return $bad
}

# One watcher per run, so an event is never reported twice or lost between two readers.
lock() {
  local p
  if mkdir "$D/lock" 2>/dev/null; then echo $$ > "$D/lock/pid"; return 0; fi
  p=$(cat "$D/lock/pid" 2>/dev/null); [ -n "$p" ] || { sleep 0.3; p=$(cat "$D/lock/pid" 2>/dev/null); }
  if [ -n "$p" ] && [ "$p" != "$$" ] && kill -0 "$p" 2>/dev/null && ps -o command= -p "$p" 2>/dev/null | grep -q 'watch\.sh'; then return 1; fi
  rm -rf "$D/lock"; mkdir "$D/lock" 2>/dev/null && echo $$ > "$D/lock/pid"
}
unlock() { [ -n "$D" ] && [ "$(cat "$D/lock/pid" 2>/dev/null)" = "$$" ] && rm -rf "$D/lock"; return 0; }
watcher() { local p; p=$(cat "$D/lock/pid" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "$p"; }

why() {
  local rc=$1 k s=""
  k=$(( $(num "$(get oom1)") - $(num "$(get oom0)") ))
  if [ "$k" -gt 0 ] && [ "$(get launcher)" = systemd ]; then
    printf ' (out of memory: the kernel killed %s of its processes)' "$k"; return
  fi
  case "$rc" in
    126) s="the command could not be run";; 127) s="command not found";;
    129) s="SIGHUP";; 130) s="SIGINT";; 134) s="SIGABRT";; 139) s="SIGSEGV, a crash";; 141) s="SIGPIPE";;
    137) s="SIGKILL from outside; the kernel's out-of-memory killer is the usual sender";;
    143) s="SIGTERM from outside";;
  esac
  [ -n "$s" ] && printf ' (%s)' "$s"
}

flush_errors() {
  local t=$1 c; c=$(num "$(get err_count)"); [ "$c" -gt 0 ] || return 0
  if [ -n "${2-}" ] || [ $(( t - $(num "$(get err_last)") )) -ge "$(num "$(get quiet 120)")" ]; then
    event error "$c error line$([ "$c" -gt 1 ] && echo s) in the log. Latest: $(tail -n 1 "$D/err_lines" 2>/dev/null)"
    put err_last "$t"; put err_count 0; cp "$D/err_lines" "$D/err_shown" 2>/dev/null; : > "$D/err_lines"
  fi
}
flush_milestone() {
  local t=$1 c; c=$(num "$(get ms_count)"); [ "$c" -gt 0 ] || return 0
  if [ -n "${2-}" ] || [ $(( t - $(num "$(get ms_last)") )) -ge "$(num "$(get milestone_gap 300)")" ]; then
    event milestone "$(get ms_latest)$([ "$c" -gt 1 ] && echo " ($c matches since the last report)")"
    put ms_last "$t"; put ms_count 0
  fi
}
# Reads what the log gained since the last look, in whole lines; \r counts as a line end.
# No byte is skipped: a large backlog is read in 8 MiB chunks, eight a look, the rest next time.
scan_log() {
  local t=$1 log ere mre off size n used hits rounds=0 last
  log=$(get log); ere=$(get error_re); mre=$(get milestone_re)
  if [ -n "$log" ] && [ -f "$log" ]; then
    off=$(num "$(get log_off)"); size=$(fsize "$log")
    [ "$size" -lt "$off" ] && off=0
    while [ "$size" -gt "$off" ]; do
      [ -n "${2-}" ] || [ "$rounds" -lt 8 ] || break
      rounds=$((rounds + 1))
      tail -c +$((off + 1)) "$log" | head -c 8388608 | tr '\r' '\n' > "$D/chunk"
      n=$(wc -l < "$D/chunk" | tr -d ' '); last=0
      [ $(( off + $(fsize "$D/chunk") )) -ge "$size" ] && last=1
      # On the last look, read the final line even when it has no line end.
      if { [ -n "${2-}" ] && [ "$last" -eq 1 ]; } || { [ "$n" -eq 0 ] && [ "$(fsize "$D/chunk")" -ge 65536 ]; }; then cp "$D/chunk" "$D/lines"
      elif [ "$n" -gt 0 ]; then head -n "$n" "$D/chunk" > "$D/lines"
      else : > "$D/lines"; fi
      used=$(fsize "$D/lines"); [ "$used" -gt 0 ] || break
      off=$((off + used)); put log_off "$off"
      if [ -n "$ere" ]; then
        hits=$(num "$(LC_ALL=C grep -a -c -E -- "$ere" "$D/lines" 2>/dev/null)")
        if [ "$hits" -gt 0 ]; then
          put err_count $(( $(num "$(get err_count)") + hits ))
          { cat "$D/err_lines" 2>/dev/null; LC_ALL=C grep -a -E -- "$ere" "$D/lines" | tail -n 5 | cut -c1-400; } | tail -n 5 > "$D/err_lines.new"
          mv -f "$D/err_lines.new" "$D/err_lines"
        fi
      fi
      if [ -n "$mre" ]; then
        hits=$(num "$(LC_ALL=C grep -a -c -E -- "$mre" "$D/lines" 2>/dev/null)")
        if [ "$hits" -gt 0 ]; then
          put ms_count $(( $(num "$(get ms_count)") + hits ))
          put ms_latest "$(LC_ALL=C grep -a -E -- "$mre" "$D/lines" | tail -n 1 | cut -c1-300)"
        fi
      fi
    done
    rm -f "$D/chunk" "$D/lines"
  fi
  flush_errors "$t" "${2-}"; flush_milestone "$t" "${2-}"
}

# Progress is the log growing. When --progress paths are named they take its place: a file
# changing, or anything inside a folder (at any depth) being added, removed, resized or modified.
# A job that hangs while it keeps printing is then still seen as stalled.
lsdeep() { ls -lnRA --time-style=full-iso "$1" 2>/dev/null || ls -lnRAT "$1" 2>/dev/null || ls -lnRA "$1" 2>/dev/null; }
fingerprint() {
  local out="" p t every
  if [ ! -s "$D/progress" ]; then printf 'log:%s' "$(fsize "$(get log)")"; return 0; fi
  # A large folder is not listed more often than a third of the stall limit, and at most every 10 s.
  t=$(now); every=$(( $(num "$(get stall)") / 3 )); { [ "$every" -gt 10 ] || [ "$(num "$(get stall)")" -eq 0 ]; } && every=10
  if [ -f "$D/fp_cache" ] && [ $(( t - $(num "$(get fp_at)") )) -lt "$every" ]; then cat "$D/fp_cache"; return 0; fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -d "$p" ]; then out="$out|$(lsdeep "$p" | cksum | tr -d ' ')"
    elif [ -e "$p" ]; then out="$out|$(fsize "$p"):$(mtime "$p")"
    else out="$out|-"; fi
  done < "$D/progress"
  printf '%s' "$out" > "$D/fp_cache"; put fp_at "$t"
  printf '%s' "$out"
}
progress_check() {
  local t=$1 stall fp lp
  fp=$(fingerprint)
  if [ "$fp" != "$(get fp)" ]; then
    lp=$(num "$(get last_progress "$t")"); put fp "$fp"; put last_progress "$t"
    if has f_stalled; then rm -f "$D/f_stalled"; event resumed "progress again after $(dur $((t - lp))) of silence"; fi
    return 0
  fi
  stall=$(num "$(get stall)"); [ "$stall" -gt 0 ] || return 0
  lp=$(num "$(get last_progress "$(get started "$t")")")
  if ! has f_stalled && [ $((t - lp)) -ge "$stall" ]; then
    flag f_stalled; event stalled "no progress for $(dur $((t - lp))) (limit $(dur "$stall"))$([ -n "$(get pid)" ] && echo "; the process is still alive")"
  fi
}
probe_check() {
  local t=$1 cmd n
  cmd=$(get probe); [ -n "$cmd" ] || return 0
  [ $(( t - $(num "$(get probe_last)") )) -ge "$(num "$(get probe_every 30)")" ] || return 0
  put probe_last "$t"
  ( cd "$(get cwd)" 2>/dev/null; with_timeout "$(num "$(get probe_timeout 10)")" "$BASH" -c "$cmd" ) > "$D/probe.out" 2>&1 < /dev/null; n=$?
  case "$n" in 124|142) echo "the probe did not answer within $(dur "$(num "$(get probe_timeout 10)")") (--probe-timeout)" >> "$D/probe.out";; esac
  if [ "$n" -eq 0 ]; then
    put probe_fails 0
    if has f_unhealthy; then rm -f "$D/f_unhealthy"; event healthy "the health probe passes again"
    elif ! has f_ready; then event ready "the health probe passed for the first time, $(dur "$(el "$t")") after the start"; fi
    flag f_ready
  else
    n=$(( $(num "$(get probe_fails)") + 1 )); put probe_fails "$n"
    if [ "$n" -ge 3 ] && ! has f_unhealthy; then
      flag f_unhealthy
      if has f_ready; then event unhealthy "the health probe failed $n times in a row. Last output: $(tail -n 1 "$D/probe.out" | cut -c1-200)"
      else event unhealthy "the health probe has not passed once, $(dur "$(el "$t")") after the start. Last output: $(tail -n 1 "$D/probe.out" | cut -c1-200)"; fi
    fi
  fi
}
# For work watch did not start (a job on another machine, a service, another agent's task):
# a command of yours says when it is done, and another when it has failed.
# run_cond CMD: 0 it passed; 1 it did not; 2 it could not run at all (not found, not
# executable, or no answer in 30 s), which must never be read as "not yet".
# Each check keeps its own last output (cond.until.out, cond.fail_when.out), so one does not hide the other's.
run_cond() { # until|fail_when CMD
  local rc o="$D/cond.$1.out"
  ( cd "$(get cwd)" 2>/dev/null; with_timeout 30 "$BASH" -c "$2" ) > "$o" 2>&1 < /dev/null; rc=$?
  [ "$rc" -eq 0 ] && return 0
  case "$rc" in 124|126|127|142) cp "$o" "$D/cond.bad"; return 2;; esac
  if grep -q 'command not found' "$o" 2>/dev/null; then cp "$o" "$D/cond.bad"; return 2; fi
  return 1
}
# Did a check of yours print anything on its last run? Then "nothing is wrong" is not ours to say.
check_printed() { [ -n "$(get until)" ] && [ -s "$D/cond.until.out" ] && return 0; [ -n "$(get fail_when)" ] && [ -s "$D/cond.fail_when.out" ]; }
cond_check() {
  local t=$1 u f r n bad=0
  u=$(get until); f=$(get fail_when); [ -n "$u$f" ] || return 0
  [ -n "${2-}" ] || [ $(( t - $(num "$(get cond_last)") )) -ge "$(num "$(get probe_every 30)")" ] || return 0
  put cond_last "$t"
  if [ -n "$f" ]; then
    run_cond fail_when "$f"; r=$?
    if [ "$r" -eq 0 ]; then
      scan_log "$t" force
      event failed "your --fail-when check passed after $(dur "$(el "$t")"). Its output: $(tail -n 1 "$D/cond.fail_when.out" | cut -c1-200)"; put final failed; return 0
    fi
    [ "$r" -eq 2 ] && bad=1
  fi
  if [ -n "$u" ]; then
    run_cond until "$u"; r=$?
    if [ "$r" -eq 0 ]; then
      scan_log "$t" force
      event finished "your --until check passed after $(dur "$(el "$t")")"; put final finished; return 0
    fi
    [ "$r" -eq 2 ] && bad=1
  fi
  if [ "$bad" -eq 1 ]; then
    n=$(( $(num "$(get cond_fails)") + 1 )); put cond_fails "$n"
    if [ "$n" -ge 3 ] && ! has f_broken; then
      flag f_broken; event check-broken "your --until or --fail-when command cannot run, so watch cannot tell how the work is going. Its output: $(tail -n 1 "$D/cond.bad" | cut -c1-200)"
    fi
  else
    put cond_fails 0
    if has f_broken; then rm -f "$D/f_broken"; event healthy "your --until and --fail-when commands run again"; fi
  fi
  return 0
}
# Memory left before something is killed: the system's, or a cgroup limit above the job if that is tighter.
headroom_mb() {
  local best g mx cur fc h
  best=$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null); [ -n "$best" ] || return 1
  g=$(get cgroup)
  while [ -n "$g" ]; do
    mx=$(cat "/sys/fs/cgroup$g/memory.max" 2>/dev/null)
    case "$mx" in ''|max) ;; *)
      cur=$(cat "/sys/fs/cgroup$g/memory.current" 2>/dev/null)
      fc=$(awk '$1 == "inactive_file" || $1 == "active_file" {s += $2} END {print s + 0}' "/sys/fs/cgroup$g/memory.stat" 2>/dev/null)
      if [ -n "$cur" ]; then h=$(( (mx - cur + $(num "$fc")) / 1048576 )); [ "$h" -lt "$best" ] && best=$h; fi;;
    esac
    g=${g%/*}
  done
  echo "$best"
}
resource_check() {
  local t=$1 need free f2 where
  [ $(( t - $(num "$(get res_last)") )) -ge 30 ] || return 0; put res_last "$t"
  need=$(num "$(get min_disk_mb 1024)")
  if [ "$need" -gt 0 ]; then
    free=$(df -Pk "$(get cwd)" 2>/dev/null | awk 'NR == 2 {print int($4 / 1024)}'); where=$(get cwd)
    # The log is kept in the run folder, which may sit on another disk.
    f2=$(df -Pk "$D" 2>/dev/null | awk 'NR == 2 {print int($4 / 1024)}')
    if [ -n "$f2" ] && { [ -z "$free" ] || [ "$f2" -lt "$free" ]; }; then free=$f2; where="$D, where the log is kept"; fi
    if [ -n "$free" ] && [ "$free" -lt "$need" ]; then
      has f_lowdisk || { flag f_lowdisk; event low-disk "only $free MB free on the disk holding $where (limit $need MB)"; }
    elif [ -n "$free" ] && [ "$free" -ge $((need * 2)) ]; then rm -f "$D/f_lowdisk"; fi
  fi
  need=$(num "$(get min_mem_mb 1024)")
  if [ "$need" -gt 0 ] && free=$(headroom_mb); then
    if [ "$free" -lt "$need" ]; then
      has f_lowmem || { flag f_lowmem; event low-memory "only $free MB of memory left before the kernel starts killing (limit $need MB)"; }
    elif [ "$free" -ge $((need * 2)) ]; then rm -f "$D/f_lowmem"; fi
  fi
}

# One look at the run. Records what changed as events; only the lock holder calls it.
check() {
  local t rc d mx
  has final && return 0
  t=$(now)
  if has closed; then
    # The watch was ended. If the job had already ended by itself, that is what gets reported.
    if [ -n "$(get pid)" ] && { has exit || ! alive; } && ! has stopped; then :
    else scan_log "$t" force; event ended "you ended the watch after $(dur "$(el "$t")"); the job was left as it is"; put final ended; return 0; fi
  fi
  if [ -n "$(get pid)" ]; then
    if ! has exit && ! alive; then sleep "$GRACE"; fi
    if has exit || ! alive; then
      scan_log "$t" force
      d=$(dur $(( $(num "$(get ended "$t")") - $(num "$(get started "$t")") )))
      # "You stopped it" is true only if it had not already ended before you asked.
      if has stopped && ! { has exit && [ "$(num "$(get ended)")" -lt "$(num "$(get stop_at)")" ]; }; then event stopped "you stopped it after $d"; put final stopped
      elif has exit; then
        rc=$(num "$(get exit)")
        if [ "$rc" -eq 0 ]; then event finished "exit 0 after $d"; put final finished
        else event failed "exit $rc after $d$(why "$rc")"; put final failed; fi
      elif [ "$(get kind)" = attached ]; then
        # Watch did not start it, so only your own checks can say how it went.
        cond_check "$t" force; has final && return 0
        event exited "process $(get pid) ended after $d. Watch did not start it, so its exit code is unknown and so is whether it went well"; put final exited
      else
        event gone "the job ended after $d without an exit code: it was killed from outside (a stop, a reboot, or its whole process group)"; put final gone
      fi
      return 0
    fi
  fi
  # A list of every run skips your own check commands, which can each take many seconds.
  if [ -z "$LIGHT" ]; then cond_check "$t"; has final && return 0; fi
  scan_log "$t"; progress_check "$t"; [ -n "$LIGHT" ] || probe_check "$t"; resource_check "$t"
  mx=$(num "$(get max)")
  if [ "$mx" -gt 0 ] && ! has f_overdue && [ "$(el "$t")" -ge "$mx" ]; then
    flag f_overdue; event overdue "still running after $(dur "$(el "$t")"), past the limit of $(dur "$mx")"
  fi
}

# What is wrong with a live run right now, in words; empty when nothing is.
troubles() {
  local s=""
  has f_stalled && s="$s, stalled"; has f_unhealthy && s="$s, unhealthy"
  has f_broken && s="$s, a check that cannot run"; has f_overdue && s="$s, overdue"
  has f_lowdisk && s="$s, low on disk"; has f_lowmem && s="$s, low on memory"
  printf '%s' "${s#, }"
}
summary() {
  local t lp tr k; t=$(now); printf 'running for %s' "$(dur "$(el "$t")")"
  # "Last progress" is shown only where something measures progress.
  lp=$(get last_progress)
  if [ -n "$lp" ] && { [ -n "$(get log)" ] || [ -s "$D/progress" ]; }; then printf ', last progress %s ago' "$(dur $((t - lp)))"; fi
  tr=$(troubles); [ -n "$tr" ] && printf '. Still wrong: %s' "$tr"
  # A check of yours that runs but errors looks like "not yet": show what it last printed.
  for k in fail_when until; do
    if [ -n "$(get $k)" ] && [ -s "$D/cond.$k.out" ]; then printf '. Your --%s check last printed: %s' "$(printf '%s' "$k" | tr _ -)" "$(tail -n 1 "$D/cond.$k.out" | cut -c1-160)"; fi
  done
  [ -n "$(get ms_latest)" ] && printf '. Latest milestone: %s' "$(get ms_latest)"
  return 0
}
details() {
  local kinds=" $1 " log n=0; log=$(get log)
  case "$kinds" in *" error "*) [ -s "$D/err_shown" ] && { echo "Error lines:"; sed 's/^/    /' "$D/err_shown"; };; esac
  case "$kinds" in *" unhealthy "*) [ -s "$D/probe.out" ] && { echo "Probe output:"; tail -n 5 "$D/probe.out" | cut -c1-300 | sed 's/^/    /'; };; esac
  case "$kinds" in *" check-broken "*) [ -s "$D/cond.bad" ] && { echo "Check output:"; tail -n 5 "$D/cond.bad" | cut -c1-300 | sed 's/^/    /'; };; esac
  case "$kinds" in *" failed "*|*" gone "*|*" exited "*|*" stalled "*) n=15;; *" finished "*|*" error "*|*" overdue "*) n=5;; esac
  if [ "$n" -gt 0 ] && [ -n "$log" ] && [ -s "$log" ]; then
    echo "Last $n log lines ($log):"; tail -c 20000 "$log" | tr '\r' '\n' | tail -n "$n" | cut -c1-300 | sed 's/^/    /'
  fi
  return 0
}
advice() { # KINDS [follow]: a follow watcher keeps going by itself
  local kinds=" $1 " again="Then watch again with the same command." tr
  [ "${2-}" = follow ] && again=""
  local say="When you tell the user, lead with what happened and what it means for them, in plain words."
  case "$(get final)" in
    finished) echo "Next: the work is done. Check what it produced before you call it good, then tell the user. $say";;
    failed|gone) echo "Next: find the cause in the log before you run it again; a rerun without a cause fails the same way. Tell the user it failed. $say";;
    exited) echo "Next: it ended, and watch cannot tell whether it went well. Check what it produced before you tell the user anything. $say";;
    stopped|ended) echo "Next: nothing more to watch.";;
    *) case "$kinds" in
         *" stalled "*) echo "Next: $(if [ -n "$(get pid)" ]; then echo "it is alive but silent"; else echo "there is no progress where you told watch to look"; fi). Look at what it is waiting on$([ "$(get kind)" = job ] && echo ", and stop it with \`$SELF stop --name $(get name)\` if it is hung"). If it is quiet by design, run \`$SELF set --name $(get name) --stall off\` (or a longer limit, or --progress PATH). $again";;
         *" unhealthy "*) echo "Next: it runs but does not answer its health probe. Look now: fix it, or stop it$([ "$(get kind)" = job ] && echo " with \`$SELF stop --name $(get name)\`"). $again";;
         *" check-broken "*) echo "Next: the watch is blind until that command runs. Fix it with \`$SELF set --name $(get name) --until CMD\` (or --fail-when CMD). $again";;
         *" error "*) echo "Next: it is still running after printing errors, so it may be retrying quietly. Read them, and stop it if the result is already spoiled. $again";;
         *" low-disk "*|*" low-memory "*) echo "Next: free the resource now, or the job is likely to die. If the limit does not suit this machine, change it with \`$SELF set --name $(get name) --min-mem-mb N\` (or --min-disk-mb N). $again";;
         *" overdue "*) echo "Next: it has run longer than you allowed. Check that it is still doing useful work; if it is, give it a new limit with \`$SELF set --name $(get name) --max DUR\`. $again";;
         *" milestone "*) echo "Next: this is the moment to look at what it has produced so far. If that is already wrong, stop it$([ "$(get kind)" = job ] && echo " with \`$SELF stop --name $(get name)\`") and fix the cause. $again";;
         *" ready "*) echo "Next: it is up and answering its probe. Use it. $again";;
         *) tr=$(troubles)
            if [ -n "$tr" ]; then echo "Next: nothing new went wrong, but it is still $tr. Deal with that first. $again"
            else echo "Next: nothing is wrong and it is still running. Watch again with the same command."; fi;;
       esac;;
  esac
}
final_code() { case "$(get final)" in failed|gone|exited) return 1;; *) return 0;; esac; }

val() { [ "$1" -ge 2 ] || die "$2 needs a value."; }
ref_opt() { case "$1" in --dir) R_dir=$2;; --name) R_name=$2;; *) return 1;; esac; }
latest() {
  local d best=""
  for d in "$RUNS"/*/; do d=${d%/}; [ -f "$d/name" ] || continue; [ "$(cat "$d/name")" = "$1" ] && best=$d; done
  printf '%s' "$best"
}
resolve() {
  if [ -n "$R_dir" ]; then D=${R_dir%/}; [ -f "$D/name" ] || die "$D is not a watch run folder."
  elif [ -n "$R_name" ]; then D=$(latest "$R_name"); [ -n "$D" ] || die "no run named $R_name. \`$SELF list --all\` shows every run."
  else die "say which run: --dir RUN_FOLDER or --name NAME."; fi
}

# The checks a run can carry; shared by start, attach and set.
copt() {
  local v
  # A check command is kept and read back as one line.
  case "$1" in --probe|--until|--fail-when) case "$2" in *"
"*) die "$1 must be one line, because only its first line would be run. For several steps, put them in a script file and run that.";; esac;; esac
  case "$1" in
    --stall) v=$(secs "$2") || die "--stall wants a duration such as 90, 5m or off."; C_stall=$v;;
    --error) case "$2" in off|none) C_error=off;; *) okre "$2" || die "--error is not a valid extended regular expression: $2"; C_error=$2;; esac;;
    --milestone) case "$2" in off|none) C_milestone=off;; *) okre "$2" || die "--milestone is not a valid extended regular expression: $2"; C_milestone=$2;; esac;;
    --milestone-gap) v=$(secs "$2") || die "--milestone-gap wants a duration such as 5m."; C_msgap=$v;;
    --quiet) v=$(secs "$2") || die "--quiet wants a duration such as 2m."; C_quiet=$v;;
    --probe) [ -n "$2" ] || die "--probe wants a command, or off."; C_probe=$2;;
    --probe-every) v=$(secs "$2") && [ "$v" -gt 0 ] || die "--probe-every wants a duration such as 30s."; C_pevery=$v;;
    --probe-timeout) v=$(secs "$2") && [ "$v" -gt 0 ] || die "--probe-timeout wants a duration such as 10s."; C_ptimeout=$v;;
    --max) v=$(secs "$2") || die "--max wants a duration such as 40m or off."; C_max=$v;;
    --min-disk-mb) case "$2" in ''|*[!0-9]*) die "--min-disk-mb wants a whole number of megabytes (0 turns it off).";; esac; C_disk=$2;;
    --min-mem-mb) case "$2" in ''|*[!0-9]*) die "--min-mem-mb wants a whole number of megabytes (0 turns it off).";; esac; C_mem=$2;;
    --until) [ -n "$2" ] || die "--until wants a command, or off."; C_until=$2;;
    --fail-when) [ -n "$2" ] || die "--fail-when wants a command, or off."; C_failwhen=$2;;
    --progress) [ -n "$2" ] || die "--progress wants a file or folder."; C_progress="$C_progress$2
";;
    *) return 1;;
  esac
}
wcfg() {
  local p cwd; cwd=$(get cwd)
  [ -n "$C_stall" ] && { put stall "$C_stall"; rm -f "$D/f_stalled"; put last_progress "$(now)"; }
  [ -n "$C_error" ] && { if [ "$C_error" = off ]; then put error_re ""; else put error_re "$C_error"; fi; }
  [ -n "$C_milestone" ] && { if [ "$C_milestone" = off ]; then put milestone_re ""; else put milestone_re "$C_milestone"; fi; }
  [ -n "$C_msgap" ] && put milestone_gap "$C_msgap"
  [ -n "$C_quiet" ] && put quiet "$C_quiet"
  [ -n "$C_probe" ] && { if [ "$C_probe" = off ]; then put probe ""; else put probe "$C_probe"; fi; rm -f "$D/f_unhealthy"; put probe_fails 0; }
  [ -n "$C_pevery" ] && put probe_every "$C_pevery"
  [ -n "$C_ptimeout" ] && put probe_timeout "$C_ptimeout"
  [ -n "$C_max" ] && { put max "$C_max"; rm -f "$D/f_overdue"; }
  [ -n "$C_disk" ] && { put min_disk_mb "$C_disk"; rm -f "$D/f_lowdisk"; put res_last 0; }
  [ -n "$C_mem" ] && { put min_mem_mb "$C_mem"; rm -f "$D/f_lowmem"; put res_last 0; }
  [ -n "$C_until" ] && { if [ "$C_until" = off ]; then put until ""; else put until "$C_until"; fi; }
  [ -n "$C_failwhen" ] && { if [ "$C_failwhen" = off ]; then put fail_when ""; else put fail_when "$C_failwhen"; fi; }
  if [ -n "$C_progress" ]; then
    printf '%s' "$C_progress" | while IFS= read -r p; do
      [ -n "$p" ] || continue; case "$p" in /*) ;; *) p="$cwd/$p";; esac; printf '%s\n' "$p" >> "$D/progress"
    done
  fi
  return 0
}
describe() {
  local s="" v n
  [ -n "$(get pid)" ] && { if [ "$(get kind)" = job ]; then s="exit code"; else s="process alive"; fi; }
  v=$(num "$(get stall)"); n=0; [ -f "$D/progress" ] && n=$(wc -l < "$D/progress" | tr -d ' ')
  if [ "$v" -gt 0 ]; then s="$s; no progress for $(dur "$v") ($(if [ "$n" -gt 0 ]; then echo "changes in $n path$([ "$n" -gt 1 ] && echo s), not log growth"; else echo "log growth"; fi))"
  else s="$s; NO hang check (--stall off)"; fi
  if [ -z "$(get error_re)" ]; then s="$s; no error-line check"
  elif [ "$(get error_re)" = "$DEF_ERROR" ]; then s="$s; error lines (default pattern)"; else s="$s; error lines matching: $(get error_re)"; fi
  [ -n "$(get milestone_re)" ] && s="$s; milestones matching: $(get milestone_re)"
  [ -n "$(get probe)" ] && s="$s; health probe every $(dur "$(num "$(get probe_every 30)")"): $(get probe)"
  [ -n "$(get until)" ] && s="$s; done when this passes: $(get until)"
  [ -n "$(get fail_when)" ] && s="$s; failed when this passes: $(get fail_when)"
  if [ "$(num "$(get max)")" -gt 0 ]; then s="$s; overdue after $(dur "$(get max)")"; else s="$s; NO time limit (--max off)"; fi
  [ "$(num "$(get min_disk_mb 1024)")" -gt 0 ] && s="$s; disk under $(get min_disk_mb 1024) MB"
  [ "$(num "$(get min_mem_mb 1024)")" -gt 0 ] && [ -r /proc/meminfo ] && s="$s; memory under $(get min_mem_mb 1024) MB"
  printf '%s' "${s#; }"
}
howto() {
  echo "Next: watch it now, or a failure goes unseen. Run one of these, and run it again each time it returns while the job is still running:"
  echo "  $SELF follow --name $(get name)    (a line per event; for a tool that turns output lines into notifications)"
  echo "  $SELF wait --name $(get name)      (returns at the next event; run it as a background command)"
}

# The outermost slice above us that carries a memory limit, so a detached job keeps that
# limit while leaving the caller's own scope, which a harness may stop on restart.
pick_slice() {
  local g rest part path IFS=/
  [ -n "${WATCH_SLICE-}" ] && { echo "$WATCH_SLICE"; return 0; }
  g=$(sed -n 's/^0:://p' /proc/self/cgroup 2>/dev/null)
  case "$g" in */user@*.service/*) ;; *) return 0;; esac
  rest=${g#*/user@}; path="${g%%/user@*}/user@${rest%%/*}"; rest=${rest#*/}
  for part in $rest; do
    path="$path/$part"
    case "$part" in *.slice)
      case "$(cat "/sys/fs/cgroup$path/memory.max" 2>/dev/null):$(cat "/sys/fs/cgroup$path/memory.high" 2>/dev/null)" in
        max:max|:|max:|:max) ;; *) echo "$part"; return 0;;
      esac;;
    esac
  done
}
# The tightest memory limit on the caller, at any level above it. It is copied onto the job's
# unit, because the slice chosen above may carry a looser one.
tight_mem() {
  local g best="" mx
  g=$(sed -n 's/^0:://p' /proc/self/cgroup 2>/dev/null)
  while [ -n "$g" ]; do
    mx=$(cat "/sys/fs/cgroup$g/memory.max" 2>/dev/null)
    case "$mx" in ''|max|*[!0-9]*) ;; *) if [ -z "$best" ] || [ "$mx" -lt "$best" ]; then best=$mx; fi;; esac
    g=${g%/*}
  done
  printf '%s' "$best"
}
launch() {
  local how="${WATCH_LAUNCHER:-auto}" unit slice mem
  if [ "$how" = auto ] || [ "$how" = systemd ]; then
    if command -v systemd-run >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
      unit="watch-$(basename "$D").service"; slice=$(pick_slice)
      set -- --user --quiet --collect --unit="$unit" --description="watch: $(get name)" -p KillMode=control-group -p TimeoutStopSec=10
      [ -n "$slice" ] && set -- "$@" --slice="$slice"
      mem=$(tight_mem); [ -n "$mem" ] && set -- "$@" -p MemoryMax="$mem"
      if systemd-run "$@" -p OOMPolicy=continue "$BASH" "$D/run.sh" >/dev/null 2>"$D/launch.err" \
        || systemd-run "$@" "$BASH" "$D/run.sh" >/dev/null 2>"$D/launch.err"; then
        put launcher systemd; put unit "$unit"; put slice "$slice"
        # Without lingering, the user's systemd units are stopped when the user's last session ends.
        put linger "$(loginctl show-user "$(id -un)" -p Linger 2>/dev/null | sed 's/^Linger=//')"
        return 0
      fi
    fi
    [ "$how" = systemd ] && return 1
  fi
  if [ "$how" != nohup ] && command -v setsid >/dev/null 2>&1; then
    nohup setsid "$BASH" "$D/run.sh" >/dev/null 2>&1 < /dev/null & put launcher setsid
  elif [ "$how" != nohup ] && command -v perl >/dev/null 2>&1; then
    nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' "$BASH" "$D/run.sh" >/dev/null 2>&1 < /dev/null & put launcher setsid
  else
    nohup "$BASH" "$D/run.sh" >/dev/null 2>&1 < /dev/null & put launcher nohup
  fi
}
launched_as() {
  case "$(get launcher)" in
    systemd) printf 'detached as systemd unit %s%s; it is not stopped when this session or its harness scope is' "$(get unit)" "$([ -n "$(get slice)" ] && echo " in $(get slice)")"
      printf '. It also runs outside any sandbox the harness puts around its own commands (WATCH_LAUNCHER=setsid keeps it inside)'
      [ "$(get linger)" = no ] && printf '. It IS stopped if this user logs out of the machine, because lingering is off (loginctl enable-linger turns it on)';;
    setsid) printf 'detached in its own session; it outlives the shell that started it, but not a harness that kills every process it owns';;
    *) printf 'started with nohup only; it may die with this session';;
  esac
}
# One start or attach per name at a time: the check for a live run of that name and the making
# of the new run are not one step, so a second caller is held off for as long as they take.
reserve() {
  local r="$RUNS/.starting-$1" p
  mkdir -p "$RUNS" || die "cannot make $RUNS."
  if ! mkdir "$r" 2>/dev/null; then
    p=$(cat "$r/pid" 2>/dev/null)
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then die "another start of $1 is under way (pid $p). Wait for it, or pick another name."; fi
    rm -rf "$r"; mkdir "$r" 2>/dev/null || die "another start of $1 is under way. Wait for it, or pick another name."
  fi
  echo $$ > "$r/pid"; RESERVED=$r; trap 'release' EXIT
}
release() { [ -n "$RESERVED" ] && rm -rf "$RESERVED"; RESERVED=""; return 0; }
# The watch was ended, but the job watch started still runs.
left_running() { [ "$(get final)" = ended ] && [ "$(get kind)" = job ] && alive; }
running_named() {
  local d keep=$D hit=""
  for d in "$RUNS"/*/; do
    d=${d%/}; [ -f "$d/name" ] || continue; [ "$(cat "$d/name")" = "$1" ] || continue
    D=$d
    if has final; then left_running && hit=$d; continue; fi
    if [ -z "$(get pid)" ] || alive; then hit=$d; fi
  done
  D=$keep; printf '%s' "$hit"
}
checkname() {
  case "$1" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) die "--name wants letters, digits, dots, dashes or underscores, and starts with a letter or digit (for example render-v31).";; esac
  local other; other=$(running_named "$1")
  [ -z "$other" ] || die "a run named $1 is still going ($other). If it is yours, stop it first (\`$SELF stop --name $1\`); otherwise pick another name. Two copies of one job fight over the same files and ports."
}
newrun() {
  checkname "$1"
  D="$RUNS/$1-$(date +%Y%m%d-%H%M%S)"; [ -e "$D" ] && D="$D-$$"
  mkdir -p "$D" || die "cannot make $D."
  chmod 700 "$D"; put name "$1"; put created "$(now)"; put log_off 0
}

cmd_start() {
  local name="" cwd="$PWD" pre="" nopre="" pft=300 tmp rc t0 i
  while [ $# -gt 0 ]; do
    [ "$1" = -- ] || val $# "$1"
    case "$1" in
      --) shift; break;;
      --name) name=$2; shift 2;; --cwd) cwd=$2; shift 2;;
      --preflight) pre=$2; shift 2;; --no-preflight) nopre=$2; shift 2;;
      --preflight-timeout) pft=$(secs "$2") && [ "$pft" -gt 0 ] || die "--preflight-timeout wants a duration such as 5m."; shift 2;;
      *) copt "$1" "${2-}" || die "start does not know $1. Put the command after --."; shift 2;;
    esac
  done
  [ -n "$name" ] || die "start needs --name NAME."
  [ $# -gt 0 ] || die "start needs the command after --. For a pipeline or several steps, put them in a script file and run that."
  [ -z "$C_until$C_failwhen" ] || die "--until and --fail-when are for attach. A job started here ends with its own exit code."
  [ -d "$cwd" ] || die "--cwd $cwd is not a folder."
  cwd=$(cd "$cwd" && pwd -P)
  command -v ps >/dev/null 2>&1 || die "watch tracks a job with ps, and ps is not installed here."
  if [ -z "$pre" ] && [ -z "$nopre" ]; then
    die "start needs --preflight CMD or --no-preflight \"<reason>\". A preflight is a quick command (seconds, not minutes) that exercises each risky step of the job: the tools it calls exist, what it depends on answers, the first item goes through. Most long runs that fail do so on something a short dry run would have shown."
  fi
  [ -n "$C_max" ] || die "start needs --max DUR, the longest this job should take: a job that hangs while it keeps printing is caught only by its time limit. Pass --max off for something meant to run for good."
  case "$name" in [!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) die "--name wants letters, digits, dots, dashes or underscores, and starts with a letter or digit (for example render-v31).";; esac
  reserve "$name"; checkname "$name"
  if [ -n "$pre" ]; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/watch-preflight.XXXXXX") || die "cannot make a temp file."
    t0=$(now); ( cd "$cwd" && with_timeout "$pft" "$BASH" -c "$pre" ) > "$tmp" 2>&1 < /dev/null; rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "watch $name: PREFLIGHT FAILED - exit $rc after $(dur $(( $(now) - t0 )))$( { [ "$rc" = 124 ] || [ "$rc" = 142 ]; } && echo " (timed out after $(dur "$pft"); --preflight-timeout changes the limit)"). The job was not started."
      echo "Preflight output:"; tail -n 20 "$tmp" | cut -c1-300 | sed 's/^/    /'; rm -f "$tmp"
      echo "Next: fix what the preflight shows, then start again."
      exit 1
    fi
    echo "Preflight passed in $(dur $(( $(now) - t0 )))."; rm -f "$tmp"
  fi
  newrun "$name"
  put kind job; put cwd "$cwd"; put log "$D/job.log"; : > "$D/job.log"
  put stall 600; put error_re "$DEF_ERROR"
  [ -n "$pre" ] && put preflight "$pre"; [ -n "$nopre" ] && put no_preflight "$nopre"
  wcfg
  put cmdline "$(shq "$@")"
  { printf 'exec'; printf ' %q' "$@"; printf '\n'; } > "$D/cmd.sh"
  ( umask 077; export -p > "$D/env.sh" )
  cat > "$D/run.sh" <<RUN
#!/bin/bash
# Written by watch.sh: runs the job, keeps its output, and records how it ended.
D=$(printf '%q' "$D")
[ -f "\$D/env.sh" ] && { . "\$D/env.sh"; rm -f "\$D/env.sh"; } 2>/dev/null
# Output into a file is block-buffered by default in Python, which looks like a stall.
[ -n "\${PYTHONUNBUFFERED+x}" ] || export PYTHONUNBUFFERED=1
cd $(printf '%q' "$cwd") 2>/dev/null || { echo "watch: cannot enter the working folder" >> "\$D/job.log"; echo 126 > "\$D/exit"; exit 126; }
oom() { local g; g=\$(sed -n 's/^0:://p' /proc/self/cgroup 2>/dev/null); [ -n "\$g" ] && awk '\$1 == "oom_kill" {print \$2}' "/sys/fs/cgroup\$g/memory.events" 2>/dev/null; }
sed -n 's/^0:://p' /proc/self/cgroup > "\$D/cgroup" 2>/dev/null
oom > "\$D/oom0"
ps -o pgid= -p \$\$ | tr -d ' ' > "\$D/pgid"
date +%s > "\$D/started"
echo \$\$ > "\$D/pid.new" && mv -f "\$D/pid.new" "\$D/pid"
"\$BASH" "\$D/cmd.sh" >> "\$D/job.log" 2>&1 < /dev/null
rc=\$?
oom > "\$D/oom1"
date +%s > "\$D/ended"
echo "\$rc" > "\$D/exit.new" && mv -f "\$D/exit.new" "\$D/exit"
exit "\$rc"
RUN
  launch || { i=$(tail -n 2 "$D/launch.err" 2>/dev/null); rm -rf "$D"; die "could not launch with systemd: $i"; }
  i=0; while [ ! -s "$D/pid" ] && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
  if [ ! -s "$D/pid" ]; then
    rm -f "$D/env.sh"
    event gone "the job could not be launched. $(tail -n 2 "$D/launch.err" 2>/dev/null)"; put final gone; put delivered "$(get seq)"
    echo "watch $name: GONE - the job could not be launched. $(tail -n 2 "$D/launch.err" 2>/dev/null)"; echo "Run: $D"; exit 1
  fi
  put pidstart "$(pstart "$(get pid)")"; put last_progress "$(get started "$(now)")"; put fp "$(fingerprint)"
  event started "pid $(get pid), $(launched_as)"; put delivered "$(get seq)"
  echo "watch $name: STARTED - pid $(get pid), $(launched_as)."
  echo "Run: $D"; echo "Log: $D/job.log"; echo "Checks: $(describe)"
  [ -n "$nopre" ] && echo "No preflight: $nopre"
  release; howto
}

cmd_attach() {
  local name="" cwd="$PWD" pid="" log="" k r
  while [ $# -gt 0 ]; do
    val $# "$1"
    case "$1" in
      --name) name=$2; shift 2;; --cwd) cwd=$2; shift 2;; --pid) pid=$2; shift 2;; --log) log=$2; shift 2;;
      *) copt "$1" "${2-}" || die "attach does not know $1."; shift 2;;
    esac
  done
  [ -n "$name" ] || die "attach needs --name NAME."
  [ -d "$cwd" ] || die "--cwd $cwd is not a folder."
  cwd=$(cd "$cwd" && pwd -P)
  if [ -n "$pid" ]; then
    case "$pid" in *[!0-9]*) die "--pid wants a process id.";; esac
    command -v ps >/dev/null 2>&1 || die "watch tracks a process with ps, and ps is not installed here."
    pid_alive "$pid" "" || die "process $pid is not running."
  fi
  if [ -n "$log" ]; then case "$log" in /*) ;; *) log="$cwd/$log";; esac; [ -f "$log" ] || die "--log $log does not exist."; fi
  if [ -z "$pid" ] && [ -z "$C_probe$C_until$C_failwhen" ] && { [ "$(num "$C_stall")" -eq 0 ] || [ -z "$log$C_progress" ]; }; then
    die "attach needs something to check: --pid, --until or --fail-when CMD, --probe CMD, or --stall with --log or --progress."
  fi
  if [ "$(num "$C_stall")" -gt 0 ] && [ -z "$log$C_progress" ]; then die "--stall needs --log or --progress to measure progress by."; fi
  if [ -z "$log" ]; then
    case "$C_error" in ''|off) ;; *) die "--error reads a log: give --log FILE with it.";; esac
    case "$C_milestone" in ''|off) ;; *) die "--milestone reads a log: give --log FILE with it.";; esac
  fi
  if [ -z "$pid" ] && [ -z "$C_max" ]; then
    die "attach without --pid needs --max DUR: with no process to watch, a time limit is what tells you the work never finished. Pass --max off for something meant to run for good."
  fi
  case "$name" in [!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) die "--name wants letters, digits, dots, dashes or underscores, and starts with a letter or digit (for example render-v31).";; esac
  reserve "$name"; newrun "$name"
  put kind attached; put cwd "$cwd"; put started "$(now)"; put stall 0
  [ -n "$log" ] && { put log "$log"; put log_off "$(fsize "$log")"; put error_re "$DEF_ERROR"; }
  [ -n "$pid" ] && { put pid "$pid"; put pidstart "$(pstart "$pid")"; put cmdline "$(ps -o command= -p "$pid" 2>/dev/null | cut -c1-300)"; }
  wcfg
  # Work that is not a process here is usually somewhere else: this machine's disk and memory say nothing about it.
  [ -n "$pid" ] || { [ -n "$C_disk" ] || put min_disk_mb 0; [ -n "$C_mem" ] || put min_mem_mb 0; }
  # Try your own checks once now: one that cannot run would look like "not yet" for ever.
  for k in until fail_when; do
    [ -n "$(get $k)" ] || continue
    run_cond "$k" "$(get $k)"; r=$?
    if [ "$r" -eq 2 ]; then
      r=$(tail -n 1 "$D/cond.bad" | cut -c1-200); rm -rf "$D"
      die "your --$(printf '%s' "$k" | tr _ -) command cannot run here (not found, not executable, or no answer in 30 s). Its output: $r"
    fi
    [ "$r" -eq 0 ] && echo "Note: your --$(printf '%s' "$k" | tr _ -) command passes already, so the first look will report the work as $([ "$k" = until ] && echo finished || echo failed)."
  done
  put last_progress "$(now)"; put fp "$(fingerprint)"
  event started "attached$([ -n "$pid" ] && echo " to pid $pid")"; put delivered "$(get seq)"
  echo "watch $name: ATTACHED$([ -n "$pid" ] && echo " - pid $pid: $(get cmdline)")"
  echo "Run: $D"; echo "Checks: $(describe)"; release; howto
}

cmd_watch() {
  local mode=$1 for=1500 deadline="" ev kinds bad last i nap left; shift
  while [ $# -gt 0 ]; do
    val $# "$1"
    case "$1" in
      --for) for=$(secs "$2") || die "--for wants a duration such as 25m, or off."; shift 2;;
      *) ref_opt "$1" "${2-}" || die "$mode does not know $1."; shift 2;;
    esac
  done
  resolve
  # A status or list call holds the lock for a moment; give it a few seconds before refusing.
  i=0; until lock; do
    i=$((i + 1)); [ "$i" -lt 25 ] || die "another watcher (pid $(cat "$D/lock/pid" 2>/dev/null)) is already on this run. One is enough; \`$SELF status --name $(get name)\` shows where it stands."
    sleep 0.2
  done
  trap 'unlock' EXIT; trap 'exit 130' INT TERM HUP
  [ "$for" -gt 0 ] && deadline=$(( $(now) + for ))
  if has final && [ -z "$(fresh)" ]; then
    last=$(tail -n 1 "$D/events"); printf '%s\n' "$last" | show
    [ "$mode" = wait ] && echo "Run: $D"
    advice ""; final_code; exit $?
  fi
  while :; do
    check; ev=$(fresh)
    if [ -n "$ev" ]; then
      put delivered "$(printf '%s\n' "$ev" | tail -n 1 | cut -f1)"
      kinds=$(printf '%s\n' "$ev" | cut -f3 | tr '\n' ' ')
      printf '%s\n' "$ev" | show
      if [ "$mode" = wait ]; then
        details "$kinds"; has final || echo "Now: $(summary)."; echo "Run: $D"; advice "$kinds"
        if has final; then final_code; exit $?; fi
        if printf '%s\n' "$ev" | anybad || [ -n "$(troubles)" ]; then exit 1; else exit 3; fi
      fi
      case " $kinds" in *" failed "*|*" gone "*|*" stalled "*)
        last=$(tail -c 4000 "$(get log)" 2>/dev/null | tr '\r' '\n' | tail -n 1 | cut -c1-300)
        [ -n "$last" ] && echo "  last log line: $last";;
      esac
      # follow gives a Next: line too, for the events that ask something of you.
      if ! has final; then case " $kinds" in *" stalled "*|*" unhealthy "*|*" check-broken "*|*" error "*|*" low-disk "*|*" low-memory "*|*" overdue "*|*" milestone "*|*" ready "*) advice "$kinds" follow;; esac; fi
    fi
    if has final; then echo "watch $(get name): over. Details: $SELF status --name $(get name)"; advice ""; final_code; exit $?; fi
    if [ -n "$deadline" ] && [ "$(now)" -ge "$deadline" ]; then
      if [ -n "$(troubles)" ]; then
        echo "watch $(get name): STILL RUNNING - $(summary). Nothing new since the last report, but that still needs you. Watch again: $SELF $mode --name $(get name)"
        exit 1
      fi
      if check_printed; then
        echo "watch $(get name): STILL RUNNING - $(summary). No event since the last report. Read what your check printed: if that is an error, the watch cannot see how the work is going. Watch again: $SELF $mode --name $(get name)"
        exit 3
      fi
      echo "watch $(get name): STILL RUNNING - $(summary). Nothing is wrong. Watch again: $SELF $mode --name $(get name)"
      exit 3
    fi
    # Do not sleep past the deadline: a short --for should come back when it says.
    nap=$INTERVAL
    if [ -n "$deadline" ]; then
      left=$(( deadline - $(now) )); [ "$left" -lt 1 ] && left=1
      [ "$left" -lt "$(num "${INTERVAL%.*}")" ] && nap=$left
    fi
    sleep "$nap"
  done
}

cmd_status() {
  local w n ts kind text f
  while [ $# -gt 0 ]; do val $# "$1"; ref_opt "$1" "${2-}" || die "status does not know $1."; shift 2; done
  resolve
  if lock; then check; unlock; w=""; else w=$(watcher); fi
  f=$(get final)
  if [ -n "$f" ]; then tail -n 1 "$D/events" | show; else echo "watch $(get name): RUNNING - $(summary)."; fi
  [ -n "$(get cmdline)" ] && echo "  Command: $(get cmdline)"
  echo "  Started: $(clock "$(num "$(get started "$(get created)")")")$([ -n "$(get pid)" ] && echo ", pid $(get pid)")$([ -n "$(get launcher)" ] && echo ", $(launched_as)")"
  echo "  Checks: $(describe)"
  if [ -z "$f" ]; then
    if [ -n "$w" ]; then echo "  Watcher: pid $w"; else echo "  Watcher: none. Nobody is watching this run."; fi
  fi
  echo "  Events:"
  while IFS=$'\t' read -r n ts kind text; do echo "    $(clock "$ts") $(upper "$kind") - $text"; done < "$D/events"
  details "error unhealthy overdue"
  echo "Run: $D"
  if [ -z "$f" ] && [ -z "$w" ]; then howto; fi
  if [ "$f" = failed ] || [ "$f" = gone ] || [ "$f" = exited ]; then return 1; fi
  if [ -z "$f" ] && [ -n "$(troubles)" ]; then return 1; fi
  return 0
}

cmd_list() {
  local all="" d f state age w what k shown=0 loose=0 t; t=$(now); LIGHT=1
  while [ $# -gt 0 ]; do case "$1" in --all) all=1; shift;; *) die "list does not know $1.";; esac; done
  for d in "$RUNS"/*/; do
    D=${d%/}; [ -f "$D/name" ] || continue
    if lock; then check; unlock; w=""; else w=$(watcher); fi
    f=$(get final)
    if [ -n "$f" ]; then
      age=$(( t - $(mtime "$D/final") )); [ -n "$all" ] || [ "$age" -lt 86400 ] || left_running || continue
      state=$(upper "$f"); age="$(dur "$age") ago"; w=""
      left_running && state="ENDED, but its job still runs (pid $(get pid); \`$SELF stop --dir $D\` stops it)"
    else
      state=RUNNING; [ -n "$(troubles)" ] && state="RUNNING, $(upper "$(troubles)")"
      age="for $(dur "$(el "$t")")"
      if [ -n "$w" ]; then w="watched by pid $w"; else w="UNWATCHED"; loose=$((loose + 1)); fi
    fi
    printf '%s: %s %s%s\n    %s\n' "$(get name)" "$state" "$age" "$([ -n "$w" ] && echo ", $w")" "$D"
    if [ -n "$(get cmdline)" ]; then printf '    %s   (in %s)\n' "$(get cmdline | cut -c1-160)" "$(get cwd)"
    else
      what=""; for k in until fail_when probe log; do [ -n "$(get $k)" ] && what="$what; $(printf '%s' "$k" | tr _ -): $(get $k | cut -c1-80)"; done
      printf '    watching %s   (in %s)\n' "${what#; }" "$(get cwd)"
    fi
    shown=$((shown + 1))
  done
  [ "$shown" -gt 0 ] || echo "No runs$([ -n "$all" ] || echo " in the last day (\`list --all\` shows older ones)")."
  [ "$loose" -eq 0 ] || echo "Next: $loose run$([ "$loose" -gt 1 ] && echo s) with nobody watching. Start \`$SELF follow --dir RUN\` or \`$SELF wait --dir RUN\` on each that is yours (the command and folder show whose it is)."
  D=""
}

cmd_set() {
  while [ $# -gt 0 ]; do val $# "$1"; ref_opt "$1" "${2-}" || copt "$1" "${2-}" || die "set does not know $1."; shift 2; done
  resolve; has final && die "this run is over; there is nothing left to tune."
  [ "$(get kind)" != job ] || [ -z "$C_until$C_failwhen" ] || die "--until and --fail-when are for attach. A job started here ends with its own exit code."
  if [ "$(num "$C_stall")" -gt 0 ] && [ -z "$(get log)$C_progress" ] && [ ! -s "$D/progress" ]; then die "--stall needs --progress to measure progress by."; fi
  wcfg; echo "watch $(get name): checks are now: $(describe)"
}

cmd_stop() {
  local unit pid pg target i was=""
  while [ $# -gt 0 ]; do val $# "$1"; ref_opt "$1" "${2-}" || die "stop does not know $1."; shift 2; done
  resolve
  # Look first: a job that already ended by itself is reported as it ended, not as stopped.
  if ! has final; then
    if lock; then check; unlock; fi
    if has final; then
      tail -n 1 "$D/events" | show; echo "It had already ended, so there was nothing to stop."; advice ""; final_code; return $?
    fi
  fi
  if has final; then
    # An ended watch does not end the job: stop still has to work on it.
    if left_running; then was=ended; else echo "watch $(get name): already over ($(get final))."; return 0; fi
  fi
  pid=$(get pid); pg=$(get pgid); unit=$(get unit)
  if [ -z "$pid" ]; then flag closed
  elif [ "$(get kind)" = attached ]; then
    die "stop only stops a job that watch started. This run is attached to pid $pid, which watch did not start: stop that yourself if you mean to, or run \`$SELF end --name $(get name)\` to stop watching it."
  else
    flag stopped; put stop_at "$(now)"
    [ -n "$unit" ] && systemctl --user stop "$unit" >/dev/null 2>&1
    if alive; then
      target=$pid
      if [ "$pg" = "$pid" ] && [ "$pg" -gt 1 ]; then target="-$pg"; fi
      kill -TERM -- "$target" 2>/dev/null
      i=0; while kill -0 -- "$target" 2>/dev/null && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
      kill -KILL -- "$target" 2>/dev/null
    fi
  fi
  if [ -n "$was" ]; then
    if alive; then echo "watch $(get name): could not stop pid $pid."; return 1; fi
    event stopped "you stopped the job after its watch had ended"; put final stopped; put delivered "$(get seq)"
    echo "watch $(get name): stopped."; return 0
  fi
  if lock; then check; unlock; fi
  if [ -z "$pid" ]; then echo "watch $(get name): the watch is ended; it had no process to stop."
  elif alive; then echo "watch $(get name): could not stop pid $pid."; return 1
  else echo "watch $(get name): stopped."; fi
}

cmd_end() {
  while [ $# -gt 0 ]; do val $# "$1"; ref_opt "$1" "${2-}" || die "end does not know $1."; shift 2; done
  resolve
  if has final; then echo "watch $(get name): already over ($(get final))."; return 0; fi
  if lock; then check; unlock; fi
  if has final; then
    tail -n 1 "$D/events" | show; echo "It had already ended, so there was no watch left to end."; advice ""; final_code; return $?
  fi
  flag closed; if lock; then check; unlock; fi
  echo "watch $(get name): the watch is ended. The job itself was left as it is$([ -n "$(get pid)" ] && alive && echo " (pid $(get pid) still runs$([ "$(get kind)" = job ] && echo "; \`$SELF stop --name $(get name)\` still stops it, and its name stays taken until it ends"))")."
}

cmd_clean() {
  local older=604800 d n=0 kb=0 k t; t=$(now)
  while [ $# -gt 0 ]; do
    case "$1" in --older) val $# "$1"; older=$(secs "$2") || die "--older wants a duration such as 7d."; shift 2;; *) die "clean does not know $1.";; esac
  done
  for d in "$RUNS"/*/; do
    D=${d%/}; [ -f "$D/name" ] && [ -f "$D/final" ] || continue
    [ $(( t - $(mtime "$D/final") )) -ge "$older" ] || continue
    left_running && continue
    k=$(du -sk "$D" 2>/dev/null | awk '{print $1}'); kb=$(( kb + $(num "$k") )); rm -rf "$D"; n=$((n + 1))
  done
  D=""; echo "Removed $n finished run$([ "$n" = 1 ] || echo s) older than $(dur "$older"), $((kb / 1024)) MB."
}

usage() {
  cat <<'USE'
watch.sh: start a long job detached and watch it. See SKILL.md.
  start   --name N (--preflight CMD | --no-preflight "reason") --max DUR|off [checks] [--cwd DIR]
          [--preflight-timeout DUR (5m)] -- CMD...
  attach  --name N [--pid PID] [--log FILE] [checks]        watch something watch did not start
                                                            (without --pid it needs --max DUR|off)
  follow  --dir RUN | --name N [--for 25m]                  a line per event, until the job ends
  wait    --dir RUN | --name N [--for 25m]                  returns at the next event
  status  --dir RUN | --name N                              where the run stands
  list    [--all]                                           every run; marks the unwatched ones
  set     --dir RUN | --name N [checks]                     tune the checks of a live run
  stop    --dir RUN | --name N                              stop the job and its watch
  end     --dir RUN | --name N                              end the watch, leave the job
  clean   [--older 7d]                                      remove old finished runs
checks: --stall DUR|off (default 10m for start)  --progress PATH (repeat)  --error REGEX|off
        --milestone REGEX  --milestone-gap DUR (5m)  --quiet DUR (2m between error reports)
        --probe CMD|off  --probe-every DUR (30s)  --probe-timeout DUR (10s)  --max DUR|off  --min-disk-mb N  --min-mem-mb N
        --until CMD  --fail-when CMD (attach only: your command says when the work is done or failed)
USE
}

main() {
  local cmd="${1-}"; [ $# -gt 0 ] && shift
  case "$cmd" in
    start) cmd_start "$@";; attach) cmd_attach "$@";; follow|wait) cmd_watch "$cmd" "$@";;
    status) cmd_status "$@";; list) cmd_list "$@";; set) cmd_set "$@";; stop) cmd_stop "$@";;
    end) cmd_end "$@";; clean) cmd_clean "$@";; help|-h|--help) usage;;
    *) usage >&2; exit 2;;
  esac
}
main "$@"; exit $?
