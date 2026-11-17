#!/bin/bash
# Tests for rigor.sh. Runs it with /bin/bash (3.2 on macOS). No network; temp folders only.
HERE=$(cd "$(dirname "$0")" && pwd -P)
RIGOR="$HERE/rigor.sh"; FX="$HERE/fixtures"
T=$(mktemp -d "${TMPDIR:-/tmp}/rigor-test.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)
P="$T/proj"; PG="$T/projg"; mkdir -p "$P" "$PG"
cp "$FX/data.csv" "$P/"; cp "$FX/data.csv" "$FX/rigor-gates.json" "$PG/"
pass=0; fail=0

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
  [ $# -gt 0 ] || set -- --no-challenger "unit test"
  R start --question Q --coordinator claude-opus-5-5 --dir "$d" --root "${ROOTP:-$P}" "$@" >/dev/null 2>&1
  jq "$f" "$FX/claims.json" > "$d/claims.json"; echo "$d"
}
nxt() { R next --dir "$(mkrun "$@")"; }
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
check "negative finding matches line 1" 0 "RIGOR: DONE" R next --dir "$SV"
jq '.claims[1].evidence[0].contains = ["needle-term"]' "$SV/claims.json" > "$T/c.json" && mv "$T/c.json" "$SV/claims.json"
check "line 2 (the command) is never matched" 1 "R1 C2 evidence 1: no line of evidence/empty.txt" R next --dir "$SV"
TR=$(mkrun s2 '.')
printf '# rigor-evidence kind=transcribed date=2026-11-17\n# source: https://example.org/page\nThe rule changed in 2026.\n' > "$TR/evidence/page.txt"
check "transcribed header passes" 0 "RIGOR: DONE" R next --dir "$TR"
printf 'no header here\n' > "$TR/evidence/loose.txt"
check "evidence file without header" 1 "evidence/loose.txt has no rigor-evidence header" R next --dir "$TR"

# Gates
check "start lists gates without running them" 1 "bad [broken]: echo FAIL 7 rows differ" R start --question Q --coordinator claude-opus-5-5 --no-challenger t --dir "$T/g0" --root "$PG"
check "start ran nothing" 1 "" test -e "$T/g0/evidence/gate-bad.txt"
ROOTP=$PG
G1=$(mkrun g1 .); check "gates stage open until chosen" 1 "Run the project gates" R next --dir "$G1"
check "gates by tag passes" 0 "PASS all fine" R gates --dir "$G1" --tag ok
check "after a passing gate" 0 "RIGOR: DONE" R next --dir "$G1"
check "unmatched tag" 2 "No gate has tag 'nope'" R gates --dir "$G1" --tag nope
G2=$(mkrun g2 .); R gates --dir "$G2" --skip "no data source today" >/dev/null
check "gates skipped with reason" 0 "Gates skipped. Reason: no data source today" R report --dir "$G2"
G3=$(mkrun g3 .)
check "failing gate exits 1" 1 "exit 1" R gates --dir "$G3" --all
check "failing gate is an open demand" 1 "Gate bad failed (exit 1)" R next --dir "$G3"
check "report refuses while a demand is open" 1 "No report while demands are open" R report --dir "$G3"
R gates --dir "$G3" --ack "bad=the 7 rows are the finding" >/dev/null
check "acknowledged failure" 0 "RIGOR: DONE, with 1 failing gate(s) acknowledged" R next --dir "$G3"
check "report shows FAILED (acknowledged) and FAIL lines" 0 "FAILED (acknowledged: the 7 rows are the finding)" R report --dir "$G3"
check "report carries FAIL output lines" 0 "    FAIL 7 rows differ" R report --dir "$G3"
ROOTP=$P

# Pairing
check "Claude coordinator gets Astra max" 1 "Challenger: gpt-6.2-astra at max (default pairing" R start --question Q --coordinator claude-fable-5-2 --dir "$T/p1" --root "$P"
check "OpenAI coordinator gets Fable high" 1 "Challenger: claude-fable-5-2 at high (default pairing" R start --question Q --coordinator gpt-6.2-astra --dir "$T/p2" --root "$P"
check "unknown coordinator needs --challenger" 2 "No default challenger for coordinator 'mystery-1'" R start --question Q --coordinator mystery-1 --dir "$T/p3" --root "$P"
check "user-named challenger" 1 "named by the user" R start --question Q --coordinator opus --challenger gpt-6.1-sol --dir "$T/p4" --root "$P"

# Challenge and verdict parser
crun() { local d; d=$(mkrun "$1" "$2" --effort max); R next --dir "$d" >/dev/null; echo "$d"; }
reply() { printf "$2" > "$T/$1.md"; echo "$T/$1.md"; }
V="--model gpt-6.2-astra-2026-10 --effort max"
TWO="$C2LAST | .claims[1].status = \"refuted\""
V1=$(mkrun v1 "$TWO | .claims[0].disproof = \"SECRET-DISPROOF\"" --effort max)
check "challenge stage asks for the challenger" 1 "Start gpt-6.2-astra at effort max" R next --dir "$V1"
check "brief leaves out status and disproof" 1 "" grep -qw -e refuted -e SECRET-DISPROOF "$V1/challenge-brief.md"
check "verdict refuses another model without a reason" 1 "the recorded challenger is gpt-6.2-astra at max" R verdict --dir "$V1" --model gpt-6.1-sol --effort max --file "$(reply r0 'C1: HOLDS\nC2: REFUTED\n')"
check "verdict missing line" 1 "No verdict line for C2" R verdict --dir "$V1" $V --file "$(reply r1 'C1: HOLDS - ok\n')"
check "verdict unknown id" 1 "C9 is not a claim in the brief" R verdict --dir "$V1" $V --file "$(reply r2 'C1: HOLDS\nC2: REFUTED\nC9: HOLDS\n')"
check "verdict duplicate identical lines" 1 "C1 has more than one verdict line" R verdict --dir "$V1" $V --file "$(reply r3 'C1: HOLDS\nC1: HOLDS\nC2: REFUTED\n')"
check "verdict invalid word" 1 "C2: \"MAYBE\" is not HOLDS, REFUTED or UNSUPPORTED" R verdict --dir "$V1" $V --file "$(reply r4 'C1: HOLDS\nC2: maybe\n')"
check "verdict with two words is refused" 1 "\"HOLDS/REFUTED\" is not HOLDS, REFUTED or UNSUPPORTED" R verdict --dir "$V1" $V --file "$(reply r4b 'C1: HOLDS/REFUTED - undecided\nC2: REFUTED\n')"
check "verdict with an empty MISSED line is refused" 1 "A MISSED line is empty" R verdict --dir "$V1" $V --file "$(reply r4c 'C1: HOLDS\nC2: REFUTED\nMISSED:\n- the 2024 week\n')"
check "verdict plain reply stored" 0 "Stored the reply" R verdict --dir "$V1" $V --file "$(reply r5 'C1: HOLDS - recomputed from data.csv\nC2: REFUTED - 58.4 is last year\nMISSED: none\n')"
check "supported + HOLDS is upheld" 0 "upheld (challenger: HOLDS: recomputed from data.csv)" R report --dir "$V1"
check "refuted + REFUTED agrees" 0 "refuted, and the challenger agreed" R report --dir "$V1"
V2=$(crun v2 "$TWO")
check "verdict decorated reply and override reason" 0 "Stored the reply" R verdict --dir "$V2" --model gpt-6.1-sol --effort max --override-reason "user named Sol" --file "$(reply r6 '## Verdicts\n- **C1** — holds — fine\n2. `C2`: Refuted.\n* MISSED: the 2024 week\n')"
check "MISSED item needs a response" 1 "M1 MISSED: \"the 2024 week\"" R next --dir "$V2"
jq '.missed = {"M1": "not relevant: the question is about 2026"}' "$V2/claims.json" > "$T/c.json" && mv "$T/c.json" "$V2/claims.json"
check "report prints the override reason" 0 "Override reason: user named Sol" R report --dir "$V2"
V3=$(crun v3 "$TWO")
R verdict --dir "$V3" $V --file "$(reply r7 'C1: REFUTED - wrong week\nC2: REFUTED\n')" >/dev/null
check "supported + REFUTED is a dispute" 1 "C1: you say supported; the challenger says REFUTED: wrong week" R next --dir "$V3"
jq '.claims[0].rebuttal = {"text": "the week is right", "evidence": [{"path": "data.csv", "contains": ["north-share,"], "shows": "the same row, by id"}]}' "$V3/claims.json" > "$T/c.json" && mv "$T/c.json" "$V3/claims.json"
check "rebuttal with new evidence: disputed" 0 "disputed: you say supported; the challenger says REFUTED: wrong week" R report --dir "$V3"
V4=$(crun v4 "$TWO")
R verdict --dir "$V4" $V --file "$(reply r8 'C1: HOLDS\nC2: REFUTED\n')" >/dev/null
jq '.claims[0].basis = "computed" | .claims += [{"id": "C3", "text": "A new fact.", "type": "fact", "basis": "observed", "status": "uncertain"}]' "$V4/claims.json" > "$T/c.json" && mv "$T/c.json" "$V4/claims.json"
check "basis change voids the verdict" 0 "C1 [fact, computed, supported] not challenged (changed after the challenge)" R report --dir "$V4"
check "new claim is not challenged" 0 "C3 [fact, observed, uncertain] not challenged (added after the challenge)" R report --dir "$V4"
check "no-challenger reason in report" 0 "No-challenger reason: unit test" R report --dir "$(mkrun n1 .)"

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
V5=$(crun v5 "$TWO"); R verdict --dir "$V5" $V --file "$(reply r9 'C1: UNSUPPORTED - no file\nC2: REFUTED\n')" >/dev/null
check "supported + UNSUPPORTED is a dispute" 1 "C1: you say supported; the challenger says UNSUPPORTED: no file" R next --dir "$V5"
V6=$(crun v6 "$TWO"); R verdict --dir "$V6" $V --file "$(reply r10 'C1: HOLDS\nC2: HOLDS - it is true\n')" >/dev/null
check "refuted + HOLDS is a dispute" 1 "C2: you say refuted; the challenger says HOLDS: it is true" R next --dir "$V6"
V7=$(crun v7 "$TWO | .claims[0].status = \"uncertain\""); R verdict --dir "$V7" $V --file "$(reply r11 'C1: REFUTED - wrong week\nC2: REFUTED\n')" >/dev/null
check "an uncertain claim is never in dispute" 0 "RIGOR: DONE" R next --dir "$V7"
check "an uncertain claim shows what the challenger said" 0 "C1 [fact, observed, uncertain] challenger said REFUTED: wrong week" R report --dir "$V7"
for edit in '.claims[0].text = "The north region got 31.25% of all orders."' '.claims[0].evidence[0].shows = "another description"' '.claims[0].type = "comparison" | .claims[0].cross_checks = ["C2"] | .claims[0].disproof = "a week near 58%; looked in data.csv"'; do
  V8=$(crun "v8$pass" "$TWO"); R verdict --dir "$V8" $V --file "$(reply r12 'C1: HOLDS\nC2: REFUTED\n')" >/dev/null
  jq "$edit" "$V8/claims.json" > "$T/c.json" && mv "$T/c.json" "$V8/claims.json"
  check "an edit after the challenge voids the verdict: $edit" 0 "supported] not challenged (changed after the challenge)" R report --dir "$V8"
done

echo "rigor tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
