#!/bin/bash
# Tests for rigor.sh. Runs it with /bin/bash (3.2 on macOS). No network; temp folders only.
HERE=$(cd "$(dirname "$0")" && pwd -P)
RIGOR="$HERE/rigor.sh"; FX="$HERE/fixtures"
eval "$(grep -E '^(CLAUDE|OPENAI)_IDS=' "$RIGOR")"   # the default pairings, read from the script so a swap there does not break the tests
T=$(mktemp -d "${TMPDIR:-/tmp}/rigor-test.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)
P="$T/proj"; PG="$T/projg"; mkdir -p "$P" "$PG"
cp "$FX/data.csv" "$P/"; cp "$FX/data.csv" "$FX/rigor-gates.json" "$PG/"
pass=0; fail=0
QF=$(jq -r .frame.question "$FX/claims.json")   # runs are started with the fixture's own question

R() { /bin/bash "$RIGOR" "$@"; }
# check NAME STATUS TEXT CMD...: CMD must exit with STATUS and print TEXT (if TEXT is not empty).
check() {
  local name="$1" want="$2" pat="$3" out got; shift 3
  out=$("$@" 2>&1); got=$?
  if [ "$got" = "$want" ] && { [ -z "$pat" ] || printf '%s' "$out" | grep -qF -- "$pat"; }; then pass=$((pass+1))
  else fail=$((fail+1)); echo "FAIL: $name (exit $got, wanted $want and: $pat)"; printf '%s\n' "$out" | head -12 | sed 's/^/    /'; fi
}
# mkrun NAME JQ-FILTER [start options]: a run whose claims.json is the fixture passed through the filter.
mkrun() {
  local d="$T/$1" f="$2"; shift 2
  R start --question "$QF" --coordinator claude-opus-5-5 --dir "$d" --root "${ROOTP:-$P}" "$@" >/dev/null 2>&1
  jq "$f" "$FX/claims.json" > "$d/claims.json"; echo "$d"
}
# bid DIR: the id of the brief the run last wrote, which a reply must name.
bid() { cksum < "$1/challenged.json" | cut -d' ' -f1; }
# agree DIR: when the run waits for its challenger, store a reply that agrees with every claim.
agree() {
  R next --dir "$1" 2>&1 | grep -qF "stage: Challenge" || return 0
  { echo "BRIEF: $(bid "$1")"; jq -r '.claims[] | "\(.id): \(if .status == "refuted" then "REFUTED" else "HOLDS" end) - read the line"' "$1/claims.json"; echo "MISSED: none"; } > "$T/agree.md"
  R verdict --dir "$1" --model "$CLAUDE_CHALLENGER" --effort "$CLAUDE_EFFORT" --file "$T/agree.md" >/dev/null 2>&1
}
# fin DIR: next, after an agreeing challenger where the run asks for one.
fin() { agree "$1"; R next --dir "$1"; }
nxt() { fin "$(mkrun "$@")"; }
C1='.claims[0]'
CAUSE='.frame.kind = "cause" | .frame.rivals = [{"answer": "orders moved to the south region", "null_answer": false, "status": "open"}, {"answer": "fewer visitors this year", "null_answer": false, "status": "ruled out", "because": [{"claim": "C1", "how": "C1 is the share; it rules out nothing by itself"}]}, {"answer": "nothing unusual happened", "null_answer": true, "status": "ruled out", "because": [{"claim": "C1", "how": "31.25% is far below last year"}]}]'
LEAK='.claims += [{"id": "C2", "text": "Orders moved to the south region.", "type": "cause", "basis": "inferred", "status": "supported", "disproof": "a per-region breakdown showing most orders in the north; looked in data.csv", "evidence": [{"path": "data.csv", "contains": ["north-share"], "shows": "north region share"}]}]'
CMP='.claims[0].type = "comparison" | .claims[0].disproof = "a later week near 58%; looked in data.csv"'
C2LAST='.claims += [{"id": "C2", "text": "Last year the north region got 58.4% of orders.", "type": "fact", "basis": "observed", "status": "supported", "evidence": [{"path": "data.csv", "contains": [",58.4,percent"], "shows": "north region share, same week last year"}]}]'

# Frame
check "frame fact passes (R1 passes)" 0 "RIGOR: DONE" nxt f1 .
check "frame kind missing" 1 "frame.kind" nxt f2 '.frame.kind = ""'
check "frame cause with three rivals" 0 "RIGOR: DONE" nxt f4 "$CAUSE"
check "frame cause with two rivals" 1 "at least three rival answers" nxt f5 "$CAUSE | .frame.rivals |= .[0:2]"
check "frame cause without null answer" 1 "mark one rival as the null answer" nxt f6 "$CAUSE | .frame.rivals[2].null_answer = false"
F7=$(mkrun f7 .); printf '{' > "$F7/claims.json"
check "claims.json not JSON" 1 "is not valid JSON" R next --dir "$F7"

# Claim fields
check "basis missing" 1 "C1: basis must be observed" nxt b1 "del($C1.basis)"
check "basis invalid" 1 "C1: basis must be observed" nxt b2 "$C1.basis = \"guessed\""

# R1
check "R1 supported without evidence" 1 "R1 C1: a supported claim needs at least one evidence item" nxt r1a "$C1.evidence = []"
check "R1 strings on different lines" 1 "R1 C1 evidence 1: no line of data.csv holds all of" nxt r1b "$C1.evidence[0].contains = [\"north-share,31.25\", \"orders.week\"]"
check "R1 cannot be waived" 1 "C1: R1 cannot be waived" nxt r1d "$C1.waive = {\"R1\": \"trust me\"}"

# R2
check "R2 5 against 58.4 fails" 1 "R2 C1: the number 5 in the text" nxt r2a "$C1.text = \"It was 5% of orders.\" | $C1.evidence[0].contains = [\",58.4,percent\"]"
check "R2 31.2 against 31.25 fails" 1 "R2 C1: the number 31.2 in the text" nxt r2b "$C1.text = \"It was 31.2% of orders.\""
check "R2 31.250 equals 31.25" 0 "RIGOR: DONE" nxt r2c "$C1.text = \"It was 31.250% of orders.\""
check "R2 CSV cell ,58.4,percent is a token" 0 "RIGOR: DONE" nxt r2d "$C1.text = \"Last year it was 58.4%.\" | $C1.evidence[0].contains = [\",58.4,percent\"]"
check "R2 number in backticks not checked" 0 "RIGOR: DONE" nxt r2e "$C1.text = \"In \`Nov 11-17 2026\` it was 31.25%.\""
check "R2 number after a digit cell is not read" 1 "R2 C1: the number 144 in the text" nxt r2f "$C1.text = \"There were 144 stores.\" | $C1.evidence[0].contains = [\"Stores open in 2026,144\"]"
check "R2 one cell per contains string" 0 "RIGOR: DONE" nxt r2g "$C1.text = \"There were 144 stores.\" | $C1.evidence[0].contains = [\"Stores open in 2026\", \",144\"]"
check "R2 whole number unpinned fails" 1 "R2 C1: the number 22 in the text" nxt r2h "$C1.text = \"It got 31.25% and 22 orders.\""
check "R2 a date's month and day are not counts" 1 "R2 C1: the number 17 in the text" nxt r2i "$C1.text = \"There were 17 orders.\" | $C1.evidence[0].contains = [\"orders.days\", \"2026-11-11..2026-11-17\"]"
check "R2 a year is read from a date" 0 "RIGOR: DONE" nxt r2j "$C1.text = \"In 2026 there were 9 orders.\" | $C1.evidence[0].contains = [\"2026-11-11..2026-11-17\", \",9,units\"]"
check "R2 waiver skips R2" 0 "RIGOR: DONE" nxt w1 "$C1.text = \"It was 5% of orders.\" | $C1.waive = {\"R2\": \"5 is a rounded label\"}"
check "waiver without reason" 1 "C1: the waiver for R2 needs a reason" nxt w2 "$C1.text = \"It was 5% of orders.\" | $C1.waive = {\"R2\": \"\"}"

# R3
check "R3 comparison with cross-check" 0 "RIGOR: DONE" nxt r3a "$CMP | $C2LAST | $C1.cross_checks = [\"C2\"]"
check "R3 comparison without cross-check" 1 "R3 C1: a supported comparison needs cross_checks" nxt r3b "$CMP"

# R4
check "R4 cause supported, rivals closed" 0 "RIGOR: DONE" nxt r4a "$CAUSE | .frame.rivals[0].status = \"confirmed\" | .frame.rivals[0].because = [{\"claim\": \"C1\", \"how\": \"31.25% inside\"}] | $LEAK"
check "R4 cause with open rival" 1 "R4 C2: cannot be supported while rivals are open" nxt r4b "$CAUSE | $LEAK"
check "R4 cause basis not inferred" 1 "R4 C2: a cause claim must have basis" nxt r4c "$CAUSE | $LEAK | .claims[1].status = \"uncertain\" | .claims[1].basis = \"observed\""
check "R4 cause in a fact frame" 1 "R4 C2: a cause claim needs frame.kind" nxt r4d "$LEAK | .claims[1].status = \"uncertain\""

# R5
check "R5 ruled out without because" 1 "R5 rival 2 (fewer visitors this year): it is marked ruled out" nxt r5a "$CAUSE | del(.frame.rivals[1].because)"

# R6
check "R6 comparison without disproof" 1 "R6 C1: state the disproof" nxt r6a "$CMP | $C2LAST | $C1.cross_checks = [\"C2\"] | del($C1.disproof)"

# Evidence files and save
SV=$(mkrun s1 '.')
R save --dir "$SV" --name empty.txt -- grep -F needle-term "$P/data.csv" >/dev/null
check "save with empty output records exit and line count" 0 "" grep -qx '# rigor-evidence kind=command exit=1 output-lines=0 date=.*' "$SV/evidence/empty.txt"
jq '.claims += [{"id": "C2", "text": "No row names the needle term.", "type": "fact", "basis": "computed", "status": "supported", "evidence": [{"path": "evidence/empty.txt", "contains": ["exit=1 output-lines=0"], "shows": "grep found no line"}]}]' "$FX/claims.json" > "$SV/claims.json"
check "negative finding matches line 1" 0 "RIGOR: DONE" fin "$SV"
jq '.claims[1].evidence[0].contains = ["needle-term"]' "$SV/claims.json" > "$T/c.json" && mv "$T/c.json" "$SV/claims.json"
check "line 2 (the command) is never matched" 1 "R1 C2 evidence 1: no line of evidence/empty.txt" R next --dir "$SV"
TR=$(mkrun s2 '.')
printf '# rigor-evidence kind=transcribed date=2026-11-17\n# source: https://example.org/page\nThe rule changed in 2026.\n' > "$TR/evidence/page.txt"
check "transcribed header passes" 0 "RIGOR: DONE" fin "$TR"
printf 'no header here\n' > "$TR/evidence/loose.txt"
check "evidence file without header" 1 "evidence/loose.txt has no rigor-evidence header" R next --dir "$TR"

# Gates
check "start lists gates without running them" 1 "bad [broken]: echo FAIL 7 rows differ" R start --question Q --coordinator claude-opus-5-5 --dir "$T/g0" --root "$PG"
check "start ran nothing" 1 "" test -e "$T/g0/evidence/gate-bad.txt"
ROOTP=$PG
G1=$(mkrun g1 .); check "gates stage open until chosen" 1 "Run the project gates" R next --dir "$G1"
check "gates by tag passes" 0 "PASS all fine" R gates --dir "$G1" --tag ok
check "after a passing gate" 0 "RIGOR: DONE" fin "$G1"
check "unmatched tag" 2 "No gate has tag 'nope'" R gates --dir "$G1" --tag nope
G2=$(mkrun g2 .); R gates --dir "$G2" --skip "no data source today" >/dev/null; agree "$G2"
check "gates skipped with reason" 0 "Gates skipped. Reason: no data source today" R report --dir "$G2"
G3=$(mkrun g3 .)
check "failing gate exits 1" 1 "exit 1" R gates --dir "$G3" --all
check "failing gate is an open demand" 1 "Gate bad failed (exit 1)" R next --dir "$G3"
check "report refuses while a demand is open" 1 "No report while demands are open" R report --dir "$G3"
R gates --dir "$G3" --ack "bad=the 7 rows are the finding" >/dev/null
check "acknowledged failure" 0 "RIGOR: DONE, with 1 failing gate(s) acknowledged" fin "$G3"
check "report shows FAILED (acknowledged) and FAIL lines" 0 "FAILED (acknowledged: the 7 rows are the finding)" R report --dir "$G3"
check "report carries FAIL output lines" 0 "    FAIL 7 rows differ" R report --dir "$G3"
ROOTP=$P

# Pairing
check "Claude coordinator gets Astra max" 1 "Challenger: $CLAUDE_CHALLENGER at $CLAUDE_EFFORT (default pairing" R start --question Q --coordinator claude-fable-5-2 --dir "$T/p1" --root "$P"
check "OpenAI coordinator gets Fable high" 1 "Challenger: $OPENAI_CHALLENGER at $OPENAI_EFFORT (default pairing" R start --question Q --coordinator gpt-6.2-astra --dir "$T/p2" --root "$P"
check "unknown coordinator needs --challenger" 2 "No default challenger for coordinator 'mystery-1'" R start --question Q --coordinator mystery-1 --dir "$T/p3" --root "$P"
check "user-named challenger" 1 "named by the user: \"use Sol for this\"" R start --question Q --coordinator opus --challenger gpt-6.1-sol --override-reason "use Sol for this" --dir "$T/p4" --root "$P"
check "a challenger other than the default needs the user's words" 2 "is the user's choice. Pass --override-reason" R start --question Q --coordinator opus --challenger gpt-6.1-sol --dir "$T/p7" --root "$P"
check "the coordinator's own model as challenger needs them too" 2 "is the user's choice. Pass --override-reason" R start --question Q --coordinator claude-opus-5-5 --challenger claude-opus-5-5 --dir "$T/p8" --root "$P"

# Challenge and verdict parser
crun() { local d; d=$(mkrun "$1" "$2"); R next --dir "$d" >/dev/null; echo "$d"; }
# reply DIR NAME TEXT: a reply file that answers DIR's current brief.
reply() { { echo "BRIEF: $(bid "$1")"; printf "$3"; } > "$T/$2.md"; echo "$T/$2.md"; }
V="--model $CLAUDE_CHALLENGER-2026-10 --effort $CLAUDE_EFFORT"
TWO="$C2LAST | .claims[1].status = \"refuted\""
V1=$(mkrun v1 "$TWO | .claims[0].disproof = \"SECRET-DISPROOF\"")
check "challenge stage asks for the challenger" 1 "Start $CLAUDE_CHALLENGER at effort $CLAUDE_EFFORT" R next --dir "$V1"
check "brief leaves out status and disproof" 1 "" grep -qw -e refuted -e SECRET-DISPROOF "$V1/challenge-brief.md"
check "verdict refuses another model without a reason" 1 "the recorded challenger is $CLAUDE_CHALLENGER at $CLAUDE_EFFORT" R verdict --dir "$V1" --model gpt-6.1-sol --effort max --file "$(reply "$V1" r0 'C1: HOLDS - ok\nC2: REFUTED - last year\nMISSED: none\n')"
check "verdict missing line" 1 "No verdict line for C2" R verdict --dir "$V1" $V --file "$(reply "$V1" r1 'C1: HOLDS - ok\n')"
check "verdict unknown id" 1 "C9 is not a claim in the brief" R verdict --dir "$V1" $V --file "$(reply "$V1" r2 'C1: HOLDS - ok\nC2: REFUTED - last year\nC9: HOLDS - ok\nMISSED: none\n')"
check "verdict duplicate identical lines" 1 "C1 has more than one verdict line" R verdict --dir "$V1" $V --file "$(reply "$V1" r3 'C1: HOLDS - ok\nC1: HOLDS - ok\nC2: REFUTED - last year\nMISSED: none\n')"
check "verdict invalid word" 1 "C2: \"MAYBE\" is not HOLDS, REFUTED or UNSUPPORTED" R verdict --dir "$V1" $V --file "$(reply "$V1" r4 'C1: HOLDS - ok\nC2: maybe\nMISSED: none\n')"
check "verdict with two words is refused" 1 "\"HOLDS/REFUTED\" is not HOLDS, REFUTED or UNSUPPORTED" R verdict --dir "$V1" $V --file "$(reply "$V1" r4b 'C1: HOLDS/REFUTED - undecided\nC2: REFUTED - last year\nMISSED: none\n')"
check "verdict with an empty MISSED line is refused" 1 "A MISSED line is empty" R verdict --dir "$V1" $V --file "$(reply "$V1" r4c 'C1: HOLDS - ok\nC2: REFUTED - last year\nMISSED:\n- the 2024 week\n')"
check "verdict plain reply stored" 0 "Stored the reply" R verdict --dir "$V1" $V --file "$(reply "$V1" r5 'C1: HOLDS - recomputed from data.csv\nC2: REFUTED - 58.4 is last year\nMISSED: none\n')"
check "supported + HOLDS is upheld" 0 "upheld (challenger: HOLDS: recomputed from data.csv)" R report --dir "$V1"
check "refuted + REFUTED agrees" 0 "refuted, and the challenger agreed" R report --dir "$V1"
V2=$(crun v2 "$TWO")
check "verdict decorated reply and override reason" 0 "Stored the reply" R verdict --dir "$V2" --model gpt-6.1-sol --effort max --override-reason "user named Sol" --file "$(reply "$V2" r6 '## Verdicts\n- **C1** — holds — fine\n2. `C2`: Refuted. It is last year.\n* MISSED: the 2024 week\n')"
check "MISSED item needs a response" 1 "M1 MISSED: \"the 2024 week\"" R next --dir "$V2"
V10=$(crun v10 .); R verdict --dir "$V10" $V --file "$(reply "$V10" r17 'C1: HOLDS - recomputed  \nMISSED: none  \n')" >/dev/null
check "trailing spaces in a reply are dropped" 0 "upheld (challenger: HOLDS: recomputed)" R report --dir "$V10"
jq '.missed = {"M1": "not relevant: the question is about 2026"}' "$V2/claims.json" > "$T/c.json" && mv "$T/c.json" "$V2/claims.json"
check "report prints the override reason" 0 "Override reason: user named Sol" R report --dir "$V2"
check "a substitute of the other family is not flagged" 1 "" sh -c "/bin/bash '$RIGOR' report --dir '$V2' | grep -q 'same-family'"
V3=$(crun v3 "$TWO")
R verdict --dir "$V3" $V --file "$(reply "$V3" r7 'C1: REFUTED - wrong week\nC2: REFUTED - last year\nMISSED: none\n')" >/dev/null
check "supported + REFUTED is a dispute" 1 "C1: you say supported; the challenger says REFUTED: wrong week" R next --dir "$V3"
jq '.claims[0].rebuttal = {"text": "the week is right", "evidence": [{"path": "data.csv", "contains": ["north-share,"], "shows": "the same row, by id"}]}' "$V3/claims.json" > "$T/c.json" && mv "$T/c.json" "$V3/claims.json"
check "rebuttal with new evidence: disputed" 0 "disputed: you say supported; the challenger says REFUTED: wrong week" R report --dir "$V3"
V4=$(crun v4 "$TWO")
R verdict --dir "$V4" $V --file "$(reply "$V4" r8 'C1: HOLDS - ok\nC2: REFUTED - last year\nMISSED: none\n')" >/dev/null
jq '.claims[0].basis = "computed" | .claims += [{"id": "C3", "text": "A new fact.", "type": "fact", "basis": "observed", "status": "uncertain"}]' "$V4/claims.json" > "$T/c.json" && mv "$T/c.json" "$V4/claims.json"
check "basis change voids the verdict" 0 "C1 [fact, computed, supported] not challenged (changed after the challenge)" R report --dir "$V4"
check "new claim is not challenged" 0 "C3 [fact, observed, uncertain] not challenged (added after the challenge)" R report --dir "$V4"

# No run without a challenger; a substitute needs the user's words; an own-family challenger is flagged
check "--no-challenger is refused" 2 "no longer exists" R start --question Q --coordinator claude-opus-5-5 --no-challenger x --dir "$T/n0" --root "$P"
N1=$(mkrun n1 .)
check "no report before the challenge" 1 "RIGOR: OPEN (stage: Challenge)" R report --dir "$N1"
check "the challenge stage says what to ask the user" 1 "ask the user to choose: another model, by name, or a fresh agent of your own model (claude-opus-5-5)" R next --dir "$N1"
check "an own-family substitute needs the user's words" 1 "If the user chose this one" R verdict --dir "$N1" --model claude-opus-5-5 --effort high --file "$(reply "$N1" r13 'C1: HOLDS - recomputed\nMISSED: none\n')"
check "an own-family substitute is stored and flagged" 0 "claude-opus-5-5 is your own model or family" R verdict --dir "$N1" --model claude-opus-5-5 --effort high --override-reason "user: Astra is down, use Opus again" --file "$(reply "$N1" r13 'C1: HOLDS - recomputed\nMISSED: none\n')"
check "report marks each claim of an own-family challenge" 0 "upheld (same-family challenger: HOLDS: recomputed)" R report --dir "$N1"
check "report says an own-family challenge is weaker" 0 "which shares its blind spots: a weaker check." R report --dir "$N1"
check "report carries the user's words" 0 "Override reason: user: Astra is down, use Opus again" R report --dir "$N1"
N2=$(mkrun n2 . --challenger claude-fable-5-2 --effort high --override-reason "user named Fable"); R next --dir "$N2" >/dev/null
R verdict --dir "$N2" --model claude-fable-5-2 --effort high --file "$(reply "$N2" r13 'C1: HOLDS - recomputed\nMISSED: none\n')" >/dev/null
check "an own-family challenger named at start is flagged too" 0 "The challenger was the coordinator's own model or family (claude-opus-5-5)" R report --dir "$N2"
check "and the report carries what the user said at start" 0 "named at start, not the default pairing for claude-opus-5-5. The user said: user named Fable" R report --dir "$N2"
N3=$(mkrun n3 .); jq '.challenger = null' "$N3/run.json" > "$T/c.json" && mv "$T/c.json" "$N3/run.json"
check "a run made without a challenger is refused" 2 "Start a new run" R next --dir "$N3"

# check mode and evidence paths
check "check: valid register" 0 "RIGOR CHECK: CLEAR" R check --claims "$FX/claims.json" --root "$FX"
check "check: frame rule applies" 1 "frame.kind" sh -c "jq '.frame.kind = \"x\"' '$FX/claims.json' > '$T/bad.json'; /bin/bash '$RIGOR' check --claims '$T/bad.json' --root '$FX'"
check "check: relative path is under --root" 1 "$T/data.csv does not exist" R check --claims "$FX/claims.json" --root "$T"

# More frame rules, each failing alone
check "frame question empty" 1 "frame.question" nxt f8 '.frame.question = ""'
check "frame evidence_date not a date" 1 "frame.evidence_date" nxt f9 '.frame.evidence_date = "Nov 17"'
check "frame primary_records empty" 1 "frame.primary_records" nxt f10 '.frame.primary_records = []'
check "frame changed_since empty" 1 "frame.changed_since" nxt f11 '.frame.changed_since = ""'
check "frame not_checked empty" 1 "frame.not_checked" nxt f12 '.frame.not_checked = []'
E1=$(mkrun e1 .); : > "$E1/claims.json"
check "empty claims.json is an open demand" 1 "is not valid JSON holding one object" R next --dir "$E1"
: > "$T/empty.json"
check "check: empty register is not clear" 1 "is not valid JSON holding one object" R check --claims "$T/empty.json" --root "$FX"

# Waivers for the other rules
check "R3 waiver skips R3" 0 "RIGOR: DONE" nxt w3 "$CMP | $C1.waive = {\"R3\": \"no second period exists\"}"
check "R6 waiver skips R6" 0 "RIGOR: DONE" nxt w4 "$CMP | $C2LAST | $C1.cross_checks = [\"C2\"] | del($C1.disproof) | $C1.waive = {\"R6\": \"stated in the answer\"}"
check "R4 waiver skips R4" 0 "RIGOR: DONE" nxt w5 "$CAUSE | $LEAK | .claims[1].waive = {\"R4\": \"the rivals cannot be tested yet\"}"
check "R5 cannot be waived on a claim" 1 "C1: R5 cannot be waived here" nxt w6 "$C1.waive = {\"R5\": \"x\"}"

# Gate names must differ; command evidence must carry the header save writes
mkdir -p "$T/projd"; cp "$FX/data.csv" "$T/projd/"
printf '{"gates":[{"name":"same","tags":["t"],"run":"echo FAIL bad; exit 1"},{"name":"same","tags":["t"],"run":"echo PASS good"}]}\n' > "$T/projd/rigor-gates.json"
ROOTP=$T/projd; GD=$(mkrun gd .); ROOTP=$P
check "two gates with one name: the file is refused" 1 "each gate with its own name" R next --dir "$GD"
check "two gates with one name: gates does not run them" 2 "each gate with its own name" R gates --dir "$GD" --all
EH=$(mkrun s3 .); printf '# rigor-evidence kind=command\nnot a cmd header\nvalue 5\n' > "$EH/evidence/fake.txt"
check "command evidence without the save header" 1 "evidence/fake.txt: a command evidence file must be written by save" R next --dir "$EH"

# Resolve pairs not covered above, and verdicts voided by other edits
V5=$(crun v5 "$TWO"); R verdict --dir "$V5" $V --file "$(reply "$V5" r9 'C1: UNSUPPORTED - no file\nC2: REFUTED - last year\nMISSED: none\n')" >/dev/null
check "supported + UNSUPPORTED is a dispute" 1 "C1: you say supported; the challenger says UNSUPPORTED: no file" R next --dir "$V5"
V6=$(crun v6 "$TWO"); R verdict --dir "$V6" $V --file "$(reply "$V6" r10 'C1: HOLDS - ok\nC2: HOLDS - it is true\nMISSED: none\n')" >/dev/null
check "refuted + HOLDS is a dispute" 1 "C2: you say refuted; the challenger says HOLDS: it is true" R next --dir "$V6"
V7=$(crun v7 "$TWO | .claims[0].status = \"uncertain\""); R verdict --dir "$V7" $V --file "$(reply "$V7" r11 'C1: REFUTED - wrong week\nC2: REFUTED - last year\nMISSED: none\n')" >/dev/null
check "an uncertain claim is never in dispute" 0 "RIGOR: DONE" R next --dir "$V7"
check "an uncertain claim shows what the challenger said" 0 "C1 [fact, observed, uncertain] challenger said REFUTED: wrong week" R report --dir "$V7"
for edit in '.claims[0].text = "The north region got 31.25% of all orders."' '.claims[0].evidence[0].shows = "another description"' '.claims[0].type = "comparison" | .claims[0].cross_checks = ["C2"] | .claims[0].disproof = "a week near 58%; looked in data.csv"'; do
  V8=$(crun "v8$pass" "$TWO"); R verdict --dir "$V8" $V --file "$(reply "$V8" r12 'C1: HOLDS - ok\nC2: REFUTED - last year\nMISSED: none\n')" >/dev/null
  jq "$edit" "$V8/claims.json" > "$T/c.json" && mv "$T/c.json" "$V8/claims.json"
  check "an edit after the challenge voids the verdict: $edit" 0 "supported] not challenged (changed after the challenge)" R report --dir "$V8"
done

# A pin may not stop in the middle of a number; a sign in the text must be on the pin
check "R1 a pin that is the start of a longer number" 1 'R1 C1 evidence 1: on line 2 of data.csv, ",3" stops in the middle of a longer number' nxt pin1 "$C1.text = \"It was 3% of orders.\" | $C1.evidence[0].contains = [\"north-share\", \",3\"]"
check "R1 a pin that stops before the decimals" 1 "stops in the middle of a longer number" nxt pin2 "$C1.text = \"It was 31% of orders.\" | $C1.evidence[0].contains = [\",31\"]"
check "R1 a pin that starts inside a number" 1 "stops in the middle of a longer number" nxt pin3 "$C1.text = \"It was 1.25% of orders.\" | $C1.evidence[0].contains = [\"1.25,percent\"]"
printf 'id,value,unit\ndelta,-31.25,percent\n' > "$P/delta.csv"
NEG="$C1.evidence[0] = {\"path\": \"delta.csv\", \"contains\": [\"delta,\", \",-31.25,\"], \"shows\": \"change in the north share, percent\"}"
check "R2 a minus in the text needs a minus on the pin" 1 "R2 C1: the number -31.25 in the text is not a number in any of its contains strings (a sign written in the text" nxt sg1 "$C1.text = \"The change was -31.25%.\""
check "R2 a minus in the text matches a minus on the pin" 0 "RIGOR: DONE" nxt sg2 "$C1.text = \"The change was -31.25%.\" | $NEG"
check "R2 a number without a sign matches either sign" 0 "RIGOR: DONE" nxt sg3 "$C1.text = \"The share fell by 31.25%.\" | $NEG"
check "R2 a plus in the text does not match a minus pin" 1 "R2 C1: the number +31.25 in the text" nxt sg4 "$C1.text = \"The change was +31.25%.\" | $NEG"

# The challenger sees the frame, rivals, cross-checks and waivers, and must give reasons and a MISSED line
B1=$(crun b1 "$CAUSE | .frame.rivals[0].status = \"confirmed\" | .frame.rivals[0].because = [{\"claim\": \"C1\", \"how\": \"31.25% inside\"}] | $LEAK | $C1.waive = {\"R2\": \"a rounded label\"} | .claims[1].cross_checks = [\"C1\"]")
for want in "Primary records:" "What may have changed:" "Rival answers, as the coordinator ruled on them:" "- nothing unusual happened [ruled out] (null answer): C1: 31.25% is far below last year" "Waived: R2, numbers match the pinned line (a rounded label)" "Cross-checks: C1" "start no other agents" "audit the frame"; do
  check "the brief carries: $want" 0 "" grep -qF -- "$want" "$B1/challenge-brief.md"
done
check "a verdict without a reason is refused" 1 "C1: no reason after HOLDS" R verdict --dir "$B1" $V --file "$(reply "$B1" r14 'C1: HOLDS\nC2: HOLDS - fits\nMISSED: none\n')"
check "a reply without a MISSED line is refused" 1 "No MISSED line" R verdict --dir "$B1" $V --file "$(reply "$B1" r15 'C1: HOLDS - ok\nC2: HOLDS - fits\n')"
check "a refused reply can be sent again" 1 "Ask the same challenger to send its reply again" R verdict --dir "$B1" $V --file "$(reply "$B1" r15 'C1: HOLDS - ok\nC2: HOLDS - fits\n')"

# A changed claim keeps what the challenger said about the earlier version
V9=$(crun v9 .); R verdict --dir "$V9" $V --file "$(reply "$V9" r16 'C1: REFUTED - wrong week\nMISSED: none\n')" >/dev/null
jq '.claims[0].text += " "' "$V9/claims.json" > "$T/c.json" && mv "$T/c.json" "$V9/claims.json"
check "a claim reworded after a refutation cannot stay supported" 1 "C1: the challenger said REFUTED: wrong week about the version it saw" R next --dir "$V9"
jq '.claims[0].status = "uncertain"' "$V9/claims.json" > "$T/c.json" && mv "$T/c.json" "$V9/claims.json"
check "marked uncertain, it still shows what the challenger said" 0 "C1 [fact, observed, uncertain] not challenged (changed after the challenge); on the earlier version the challenger said REFUTED: wrong week" R report --dir "$V9"

# Empty option values, the folder a saved command ran in, and a challenger that is the coordinator itself
ROOTP=$PG; G4=$(mkrun g4 .); ROOTP=$P
check "gates --skip with no reason is refused" 2 "--skip needs a value" R gates --dir "$G4" --skip ""
check "gates --tag with no tag is refused" 2 "--tag needs a value" R gates --dir "$G4" --tag ""
check "a refused gates call ran nothing" 1 "" test -e "$G4/evidence/gate-good.txt"
( cd "$P" && R save --dir "$SV" --name where.txt -- echo hi >/dev/null )
check "save records the folder the command ran in" 0 "" grep -qxF "# cmd: echo hi  (run in $P)" "$SV/evidence/where.txt"
R start --question "$QF" --coordinator mystery-1 --challenger mystery-1 --effort high --override-reason "user: use it again" --dir "$T/n4" --root "$P" >/dev/null 2>&1
cp "$FX/claims.json" "$T/n4/claims.json"; R next --dir "$T/n4" >/dev/null
check "a challenger that is the coordinator's own model is flagged" 0 "mystery-1 is your own model or family" R verdict --dir "$T/n4" --model mystery-1 --effort high --file "$(reply "$T/n4" r13 'C1: HOLDS - recomputed\nMISSED: none\n')"
check "and the report says so" 0 "The challenger was the coordinator's own model or family (mystery-1)" R report --dir "$T/n4"

# What the challenger did not see is never reported as checked
V11=$(crun v11 "$CAUSE | $LEAK | .claims[1].status = \"uncertain\"")
R verdict --dir "$V11" $V --file "$(reply "$V11" r18 'C1: HOLDS - ok\nC2: HOLDS - plausible\nMISSED: none\n')" >/dev/null
jq '.frame.rivals[0].status = "confirmed" | .frame.rivals[0].because = [{"claim": "C1", "how": "31.25% inside"}] | .claims[1].status = "supported"' "$V11/claims.json" > "$T/c.json" && mv "$T/c.json" "$V11/claims.json"
check "a cause is not upheld on rivals closed after the challenge" 0 "C2 [cause, inferred, supported] not challenged (the rival answers changed after the challenge); before that the challenger said HOLDS: plausible" R report --dir "$V11"
check "the report says the challenger did not see those rulings" 0 "Rival answers (changed after the challenge: the challenger did not see these rulings)" R report --dir "$V11"
check "a fact claim keeps its verdict when only the rivals change" 0 "C1 [fact, observed, supported] upheld" R report --dir "$V11"
for edit in '.claims[0].waive = {"R2": "a label"}' '.claims[0].cross_checks = ["C2"]'; do
  V12=$(crun "v12$pass" "$TWO"); R verdict --dir "$V12" $V --file "$(reply "$V12" r12 'C1: HOLDS - ok\nC2: REFUTED - last year\nMISSED: none\n')" >/dev/null
  jq "$edit" "$V12/claims.json" > "$T/c.json" && mv "$T/c.json" "$V12/claims.json"
  check "a waiver or cross-check added after the challenge voids the verdict: $edit" 0 "supported] not challenged (changed after the challenge)" R report --dir "$V12"
done
V13=$(crun v13 "$TWO"); R verdict --dir "$V13" $V --file "$(reply "$V13" r12 'C1: HOLDS - ok\nC2: REFUTED - last year\nMISSED: none\n')" >/dev/null
jq '.frame.not_checked += ["returns"]' "$V13/claims.json" > "$T/c.json" && mv "$T/c.json" "$V13/claims.json"
check "a frame edit after the challenge is named in the report" 0 "Changed after the challenge, so not seen by the challenger: frame not_checked." R report --dir "$V13"
check "frame.question must be the question given to start" 1 "frame.question: it must be the question given to start, word for word" nxt fq1 '.frame.question = "Did the north region do well?"'
V14=$(crun v14 "$TWO"); OLD=$(reply "$V14" r19 'C1: HOLDS - ok\nC2: REFUTED - last year\nMISSED: none\n')
jq '.claims[0].evidence[0].shows = "the north row"' "$V14/claims.json" > "$T/c.json" && mv "$T/c.json" "$V14/claims.json"
check "editing claims after the brief rewrites it" 1 "a reply to the earlier one is refused" R next --dir "$V14"
check "a reply to the earlier brief is refused" 1 "but the current brief is $(bid "$V14")" R verdict --dir "$V14" $V --file "$OLD"
printf 'C1: HOLDS - ok\nC2: REFUTED - last year\nMISSED: none\n' > "$T/nob.md"
check "a reply that names no brief is refused" 1 "No BRIEF line" R verdict --dir "$V14" $V --file "$T/nob.md"
check "a reply to the current brief is stored" 0 "Stored the reply" R verdict --dir "$V14" $V --file "$(reply "$V14" r20 'C1: HOLDS - ok\nC2: REFUTED - last year\nMISSED: none\n')"

# Evidence that changes after the challenge, and claims that rest on a changed claim
mkdir -p "$T/projx"; cp "$FX/data.csv" "$T/projx/"
ROOTP=$T/projx; V15=$(crun v15 .); ROOTP=$P
R verdict --dir "$V15" $V --file "$(reply "$V15" r21 'C1: HOLDS - read the row\nMISSED: none\n')" >/dev/null
check "upheld while the evidence file is as the challenger saw it" 0 "C1 [fact, observed, supported] upheld" R report --dir "$V15"
echo "note,the north figure excludes returns,text" >> "$T/projx/data.csv"
check "an evidence file that changes after the challenge voids the verdict" 0 "C1 [fact, observed, supported] not challenged (an evidence file changed after the challenge); before that the challenger said HOLDS: read the row" R report --dir "$V15"
V16=$(crun v16 "$CMP | $C2LAST | $C1.cross_checks = [\"C2\"]")
R verdict --dir "$V16" --model "openai/$CLAUDE_CHALLENGER" --effort "$CLAUDE_EFFORT" --file "$(reply "$V16" r22 'C1: HOLDS - both rows read\nC2: HOLDS - read the row\nMISSED: none\n')" >/dev/null
check "a provider prefix on the model id is accepted" 0 "C1 [comparison, observed, supported] upheld" R report --dir "$V16"
jq '.claims[1].text = "Last year the north region got 58.4% of all orders."' "$V16/claims.json" > "$T/c.json" && mv "$T/c.json" "$V16/claims.json"
check "a comparison does not stay upheld when its cross-check changes" 0 "C1 [comparison, observed, supported] not challenged (C2 changed after the challenge, and this claim rests on it); before that the challenger said HOLDS: both rows read" R report --dir "$V16"
R start --question "$QF" --coordinator gemini-3-pro --challenger gemini-3-flash --effort high --override-reason "user chose it" --dir "$T/n5" --root "$P" >/dev/null 2>&1
cp "$FX/claims.json" "$T/n5/claims.json"; R next --dir "$T/n5" >/dev/null
check "two models that share a first word count as the same family" 0 "gemini-3-flash is your own model or family" R verdict --dir "$T/n5" --model gemini-3-flash --effort high --file "$(reply "$T/n5" r23 'C1: HOLDS - ok\nMISSED: none\n')"

# A skip does not erase a gate that already failed; gate names stay distinct as file names; ids match whole words
ROOTP=$PG; G5=$(mkrun g5 .); ROOTP=$P; R gates --dir "$G5" --all >/dev/null 2>&1
check "a skip after a failed gate leaves it open" 1 "A skip does not clear them" R gates --dir "$G5" --skip "not relevant today"
check "the failed gate is still a demand" 1 "Gate bad failed (exit 1)" R next --dir "$G5"
R gates --dir "$G5" --ack "bad=the 7 rows are the finding" >/dev/null
check "once acknowledged the run can finish, and says so" 0 "RIGOR: DONE, with 1 failing gate(s) acknowledged" fin "$G5"
check "the report keeps the gates that ran before the skip" 0 "Gates that had run before the skip:" R report --dir "$G5"
check "and still shows the failure" 0 "- bad: FAILED (acknowledged: the 7 rows are the finding)" R report --dir "$G5"
mkdir -p "$T/proje"; cp "$FX/data.csv" "$T/proje/"
printf '{"gates":[{"name":"lint/a","tags":["t"],"run":"true"},{"name":"lint?a","tags":["t"],"run":"true"}]}\n' > "$T/proje/rigor-gates.json"
ROOTP=$T/proje; GE=$(mkrun ge .); ROOTP=$P
check "gate names that make the same file name are refused" 2 "each gate with its own name" R gates --dir "$GE" --all
check "a list word must be a whole word of the model id" 2 "No default challenger for coordinator 'solar-pro'" R start --question Q --coordinator solar-pro --dir "$T/p5" --root "$P"
check "a dated or versioned id still pairs" 1 "Challenger: $OPENAI_CHALLENGER at $OPENAI_EFFORT (default pairing" R start --question Q --coordinator gpt-6.1-sol-2026-10 --dir "$T/p6" --root "$P"

# Round 4: pins at a decimal point, chains of claims, dropped claims, the exact model id
check "R1 a pin that stops at the decimal point" 1 "stops in the middle of a longer number" nxt pin4 "$C1.text = \"It was 31% of orders.\" | $C1.evidence[0].contains = [\"north-share,31.\"]"
check "R1 a pin that starts at the decimal point" 1 "stops in the middle of a longer number" nxt pin5 "$C1.text = \"It was 25% of orders.\" | $C1.evidence[0].contains = [\".25,percent\"]"
CHAIN="$CMP | $C2LAST | $C1.cross_checks = [\"C2\"] | .claims[1].type = \"comparison\" | .claims[1].disproof = \"a year near 31%; looked in data.csv\" | .claims[1].cross_checks = [\"C3\"] | .claims += [{\"id\": \"C3\", \"text\": \"There were 144 stores.\", \"type\": \"fact\", \"basis\": \"observed\", \"status\": \"supported\", \"evidence\": [{\"path\": \"data.csv\", \"contains\": [\"Stores open in 2026\", \",144\"], \"shows\": \"stores open\"}]}]"
V17=$(crun v17 "$CHAIN")
R verdict --dir "$V17" $V --file "$(reply "$V17" r24 'C1: HOLDS - a\nC2: HOLDS - b\nC3: HOLDS - c\nMISSED: None found.\n')" >/dev/null
check "MISSED: None found. is read as nothing missed" 0 "RIGOR: DONE" R next --dir "$V17"
jq '.claims[2].text = "There were 144 stores open."' "$V17/claims.json" > "$T/c.json" && mv "$T/c.json" "$V17/claims.json"
check "a change carries down a chain: the middle claim" 0 "C2 [comparison, observed, supported] not challenged (C3 changed after the challenge, and this claim rests on it)" R report --dir "$V17"
check "a change carries down a chain: the claim two steps away" 0 "C1 [comparison, observed, supported] not challenged (C2 changed after the challenge, and this claim rests on it)" R report --dir "$V17"
V18=$(crun v18 "$TWO | .claims[1].status = \"supported\"")
R verdict --dir "$V18" $V --file "$(reply "$V18" r25 'C1: HOLDS - ok\nC2: REFUTED - it is last year\nMISSED: none\n')" >/dev/null
jq 'del(.claims[1])' "$V18/claims.json" > "$T/c.json" && mv "$T/c.json" "$V18/claims.json"
check "dropping a refuted claim does not end the run" 1 "C2 was taken out of the register after the challenger said REFUTED: it is last year" R next --dir "$V18"
jq '.removed = {"C2": "it was about last year, which the question does not ask about"}' "$V18/claims.json" > "$T/c.json" && mv "$T/c.json" "$V18/claims.json"
check "with a reason, the report says the claim was dropped and why" 0 "Why it was dropped: it was about last year, which the question does not ask about" R report --dir "$V18"
V19=$(crun v19 .)
check "a different model whose id starts the same is not the recorded one" 1 "the recorded challenger is $CLAUDE_CHALLENGER at $CLAUDE_EFFORT" R verdict --dir "$V19" --model "$CLAUDE_CHALLENGER-mini" --effort "$CLAUDE_EFFORT" --file "$(reply "$V19" r26 'C1: HOLDS - ok\nMISSED: none\n')"
check "start leaves the evidence date for the coordinator to give" 1 "frame.evidence_date: give the date the evidence runs to" R start --question Q --coordinator claude-opus-5-5 --dir "$T/p9" --root "$P"

echo "rigor tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
