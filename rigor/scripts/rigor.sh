#!/bin/bash
# rigor.sh: drives a rigor run (see ../SKILL.md). Runs under bash 3.2; needs jq.
# Exit codes: 0 clear, 1 open demands or failing checks, 2 usage or script error.

# Pairing table: a coordinator id containing one of these words gets this challenger.
CLAUDE_IDS="claude fable opus sonnet haiku"; CLAUDE_CHALLENGER="gpt-6.2-astra"; CLAUDE_EFFORT="max"
OPENAI_IDS="gpt astra sol terra luna codex"; OPENAI_CHALLENGER="claude-fable-5-2"; OPENAI_EFFORT="high"

SELF="$0"
die() { printf 'rigor: %s\n' "$*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die "jq is required and was not found. Install jq (for example: brew install jq) and run again."
W=$(mktemp -d "${TMPDIR:-/tmp}/rigor-work.XXXXXX") || die "cannot make a temp folder."
trap 'rm -rf "$W"' EXIT
echo null > "$W/null.json"; echo '{}' > "$W/empty.json"
ROOT=""; RUNDIR=""; RUNJ="$W/null.json"; CHJ="$W/null.json"; GATESJ="$W/null.json"; FILES="$W/empty.json"; GF=""
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

read -r -d '' LIB <<'JQ'
def ne: type == "string" and test("\\S");
def arr: if type == "array" then . else [] end;
def obj: if type == "object" then . else {} end;
def F: $F[0] // {};
def RUN: $R[0];
def CHL: ($CH[0] // []) | arr;
def resolve($p): if ($p|startswith("/")) then $p
  elif $rundir != "" and ($p|startswith("evidence/")) then $rundir + "/" + $p
  else $root + "/" + $p end;
def flines($p): resolve($p) as $k | (F | .[$k]) as $c | if $c == null then null else ($c|split("\n")) end;
def hdr: (.[0] // "") | startswith("# rigor-evidence");
def kindof: if hdr then ((.[0] | capture("kind=(?<k>[a-z]+)") | .k) // "unknown") else "file" end;
# First line (1-based) holding every string in $cs; line 2 of a rigor-evidence file never counts.
def hit($cs): . as $ls | first(range(0; $ls|length) | select(. != 1 or ($ls|hdr|not))
  | select(. as $i | all($cs[]; . as $s | $ls[$i] | contains($s))) | . + 1) // null;
def NUMRE: "(?<![0-9])(?<![0-9][.,])(?<![A-Za-z])(?<![A-Za-z]-)(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\\.[0-9]+)?(?![0-9])";
# A date gives its year only; its month and day are not counts ("2026-11-17" reads as 2026).
def nodates: gsub("(?<![0-9])(?<y>[0-9]{4})-[0-9]{2}-[0-9]{2}(?![0-9])"; .y) | gsub("(?<![0-9])(?<y>[0-9]{4})-(?:0[1-9]|1[0-2])(?![0-9])"; .y);
def nums: [nodates | match(NUMRE; "g") | .string];
def num: gsub(","; "") | tonumber;
def byid($all; $i): first($all[] | objects | select(.id == $i)) // null;
def solid: type == "object" and (.status == "supported" or .status == "refuted") and ((.evidence|arr|length) > 0);
def waived($r): (.waive|obj)[$r] | ne;

def frame_problems:
  .frame as $f |
  if ($f|type) != "object" then ["frame is missing from claims.json. Restore it from the template start wrote."] else
  [ (if ($f.question|ne|not) then "frame.question: copy the user's question verbatim." else empty end),
    (if ((($f.evidence_date|type) == "string" and ($f.evidence_date|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")))|not) then "frame.evidence_date: give the date the evidence runs to, as YYYY-MM-DD." else empty end),
    (if ($f.kind|IN("fact","cause")|not) then "frame.kind: set \"cause\" when the user asks why something happened or what is going on, otherwise \"fact\"." else empty end),
    (if ((($f.primary_records|type) == "array" and ($f.primary_records|length) > 0 and all($f.primary_records[]; type == "object" and (.record|ne) and (.why|ne)))|not) then "frame.primary_records: list each primary record as {\"record\": ..., \"why\": ...}, saying why it is the source closest to the truth and not a proxy." else empty end),
    (if ((($f.changed_since|ne) or (($f.changed_since|type) == "array" and ($f.changed_since|length) > 0 and all($f.changed_since[]; ne)))|not) then "frame.changed_since: say what may have changed since this was last known to be true (versions, dates, platform rules)." else empty end),
    (if ((($f.not_checked|type) == "array" and ($f.not_checked|length) > 0 and all($f.not_checked[]; ne))|not) then "frame.not_checked: list what you did not check." else empty end),
    (if $f.figures_from != null and ($f.figures_from|type) != "string" then "frame.figures_from: give a string (the tool or source the figures come from), or leave it empty." else empty end),
    (if $f.rivals != null and ($f.rivals|type) != "array" then "frame.rivals must be a list." else empty end),
    ($f.rivals|arr|to_entries[] | .key as $k | .value
      | if type != "object" or (.answer|ne|not) or (.status|IN("open","ruled out","confirmed")|not) then "frame.rivals item \($k+1): each rival is {\"answer\": ..., \"null_answer\": true or false, \"status\": \"open\", \"ruled out\" or \"confirmed\", \"because\": [...]}." else empty end),
    (if $f.kind == "cause" then
       (if ($f.rivals|arr|length) < 3 then "frame.rivals: a cause question needs at least three rival answers, written before you look at the evidence." else empty end),
       (if any($f.rivals|arr|.[]; type == "object" and .null_answer == true)|not then "frame.rivals: mark one rival as the null answer (\"null_answer\": true): nothing unusual happened, or the premise is wrong." else empty end)
     else empty end)
  ] end;

def item_problems($w):
  if type != "object" then ["\($w) must be an object {\"path\", \"contains\", \"shows\"}."] else
  . as $it
  | [ (if (.path|ne|not) then "\($w) has no path. Give the file it cites." else empty end),
      (if (.contains|type) != "array" or (.contains|length) == 0 or any(.contains[]; ne|not) then "\($w) needs \"contains\": a list of non-empty strings that all sit on one line of the file." else empty end),
      (if (.shows|ne|not) then "\($w) needs \"shows\": what the line is (the metric, unit and period, or the passage)." else empty end) ] as $p
  | if ($p|length) > 0 then $p
    else flines($it.path) as $ls
    | if $ls == null then ["\($w): \(resolve($it.path)) does not exist. Fix the path, or save the evidence with save."]
      elif ($ls | hit($it.contains)) == null then ["\($w): no line of \($it.path) holds all of \($it.contains|map(tojson)|join(", ")). Pin strings that sit on one line. If the record spreads a label and its value over lines, save a one-line extract with save."]
      else [] end end end;

def claim_problems($fr; $all):
  (if (.id|type) == "string" then .id else "claim \(.id|tojson)" end) as $id | . as $c |
  [ (if (.id|type) != "string" or (.id|test("^C[0-9]+$")|not) then "\($id): id must be C followed by a number, like C1." else empty end),
    (if (.text|ne|not) then "\($id): text is empty. Write the claim as one sentence." else empty end),
    (if (.type|IN("fact","comparison","cause")|not) then "\($id): type must be fact, comparison or cause." else empty end),
    (if (.basis|IN("observed","computed","inferred")|not) then "\($id): basis must be observed (the record states it), computed (derived from records by a saved command or tool) or inferred (reasoned from other claims or indirect evidence)." else empty end),
    (if (.status|IN("supported","uncertain","refuted","unknown")|not) then "\($id): status must be supported, uncertain, refuted or unknown." else empty end),
    (if .evidence != null and (.evidence|type) != "array" then "\($id): evidence must be a list." else empty end),
    (if .cross_checks != null and (.cross_checks|type) != "array" then "\($id): cross_checks must be a list of claim ids." else empty end),
    (if .waive == null then empty elif (.waive|type) != "object" then "\($id): waive must be an object like {\"R2\": \"reason\"}." else
      (.waive|to_entries[] | if .key == "R1" then "\($id): R1 cannot be waived. Give evidence or change the status." elif (.key|IN("R2","R3","R4","R6")|not) then "\($id): \(.key) cannot be waived here. Waivers name R2, R3, R4 or R6." elif (.value|ne|not) then "\($id): the waiver for \(.key) needs a reason." else empty end) end),
    (if (.status|IN("supported","refuted")) and (.evidence|arr|length) == 0 then "R1 \($id): a \(.status) claim needs at least one evidence item {\"path\", \"contains\", \"shows\"}." else empty end),
    (.evidence|arr|to_entries[] | .key as $k | .value | item_problems("\($id) evidence \($k+1)")[] | "R1 " + .),
    (if .status == "supported" and (.text|ne) and (waived("R2")|not) then
       [.evidence|arr|.[]|objects|.contains|arr|.[]|strings|nums[]|num] as $have
       | .text | gsub("`[^`]*`"; " ") | nums | unique[] | select(num as $n | any($have[]; . == $n) | not)
       | "R2 \($id): the number \(.) in the text is not a number in any of its contains strings. Pin the cell that holds it, one cell per contains string (in \"Locations 2026,144\" the 144 is not read because it follows a digit and a comma), or put a name or date label in backticks."
     else empty end),
    (if .status == "supported" and .type == "comparison" and (waived("R3")|not) then
       (if (.cross_checks|arr|length) == 0 then "R3 \($id): a supported comparison needs cross_checks: the id of another claim that repeats the comparison on a different period, baseline or source."
        else (.cross_checks[] | . as $x | byid($all; $x) as $o
          | if $x == $c.id then "R3 \($id): a claim cannot cross-check itself."
            elif $o == null then "R3 \($id): cross-check \($x) is not a claim in the register."
            elif ($o|solid|not) then "R3 \($id): cross-check \($x) must be supported or refuted with evidence."
            else empty end) end)
     else empty end),
    (if .type == "cause" and (waived("R4")|not) then
       (if $fr.kind != "cause" then "R4 \($id): a cause claim needs frame.kind \"cause\" and its rival answers." else empty end),
       (if .basis != "inferred" then "R4 \($id): a cause claim must have basis \"inferred\"." else empty end),
       (if .status == "supported" then [$fr.rivals|arr|.[]|objects|select(.status|IN("ruled out","confirmed")|not)|.answer|tostring]
          | if length > 0 then "R4 \($id): cannot be supported while rivals are open: \(join("; ")). Rule each out or confirm it with evidence, or mark the claim uncertain." else empty end
        else empty end)
     else empty end),
    (if .status == "supported" and (.type|IN("comparison","cause")) and (.disproof|ne|not) and (waived("R6")|not) then "R6 \($id): state the disproof: what would show this wrong, and where you looked for it." else empty end)
  ];

def rival_problems($fr; $all):
  [ $fr.rivals|arr|to_entries[] | .key as $k | .value | objects | select(.status|IN("ruled out","confirmed"))
    | "R5 rival \($k+1) (\(.answer // "")):" as $w
    | if (.because|arr|length) == 0 then "\($w) it is marked \(.status), so list because items {\"claim\": \"C<n>\", \"how\": \"how that claim bears on this rival\"}."
      else (.because[] | if type != "object" then "\($w) each because item is {\"claim\", \"how\"}." else
        .claim as $x | byid($all; $x) as $o
        | (if $o == null then "\($w) because cites \($x), which is not a claim."
           elif ($o.type|IN("fact","comparison")|not) then "\($w) because must cite a fact or comparison claim; \($x) is a \($o.type)."
           elif ($o|solid|not) then "\($w) \($x) must be supported or refuted with evidence."
           else empty end),
          (if (.how|ne|not) then "\($w) say how \($x) bears on this rival (\"how\")." else empty end) end) end ];

def evdir_problems:
  [ F | keys[] | select($rundir != "" and startswith($rundir + "/evidence/")) | . as $p
    | (F[$p]|split("\n")) as $ls | ($p|ltrimstr($rundir + "/")) as $rel
    | if ($ls|hdr|not) then "\($rel) has no rigor-evidence header. Write it with save. For a transcribed source, make line 1 \"# rigor-evidence kind=transcribed date=YYYY-MM-DD\" and line 2 \"# source: <url or place>\"."
      elif ($ls|kindof) == "transcribed" then
        (if ($ls[0]|test("^# rigor-evidence kind=transcribed date=[0-9]{4}-[0-9]{2}-[0-9]{2}")|not) then "\($rel): line 1 must be \"# rigor-evidence kind=transcribed date=YYYY-MM-DD\"."
         elif (($ls[1] // "")|test("^# source: \\S")|not) then "\($rel): line 2 must be \"# source: <url or place>\"."
         else empty end)
      elif ($ls|kindof) == "command" then
        (if ($ls[0]|test("^# rigor-evidence kind=command exit=[0-9]+ output-lines=[0-9]+ date=\\S+$")|not) or ((($ls[1] // "")|startswith("# cmd: "))|not)
         then "\($rel): a command evidence file must be written by save (line 1 with exit, output-lines and date; line 2 \"# cmd: ...\"). Save it again with save." else empty end)
      else "\($rel): kind must be command (written by save) or transcribed." end ];

def claims_stage:
  (.frame|obj) as $fr | .claims as $cl |
  (if ($cl|type) != "array" then ["claims must be a list."]
   elif ($cl|length) == 0 then ["No claims yet. Add each finding to claims.json as a claim (see SKILL.md for the fields)."]
   else [ ($cl[] | if type != "object" then "Each claim must be an object." else claim_problems($fr; $cl)[] end),
          ([$cl[]|objects|.id|strings] | group_by(.) | map(select(length > 1)|.[0])[] | "\(.) is used by more than one claim. Give each claim its own id."),
          rival_problems($fr; $cl)[] ] end) + evdir_problems;

def gates_ok: (.data|type) == "object" and (.data.gates|type) == "array" and all(.data.gates[]; type == "object" and (.name|ne) and (.run|ne) and ((.tags // [])|type) == "array")
  and ([.data.gates[].name] | length == (unique|length));
def gate_stage:
  $G[0] as $g | (RUN.gates // {}) as $gs |
  if $g == null or $gs.choice == "skip" then []
  elif ($g|gates_ok|not) then ["\($g.path) is not valid. It needs {\"gates\": [{\"name\": ..., \"tags\": [...], \"run\": ...}]}, each gate with its own name. Fix it, or record a skip: \($self) gates --dir \($rundir) --skip REASON."]
  elif $gs.choice == null then ["Run the project gates in \($g.path): \($self) gates --dir \($rundir) --tag TAG, or --all, or --skip REASON. Gates: " + ([$g.data.gates[] | "\(.name) [\((.tags // [])|join(", "))]"] | join("; ")) + "."]
  else [ $gs.results|obj|to_entries[] | select(.value.exit != 0) | select(($gs.acks|obj)[.key]|ne|not)
    | "Gate \(.key) failed (exit \(.value.exit)); its output is in \(.value.evidence). Fix the cause and run gates again, or record why it does not block the answer (or that it is the finding): \($self) gates --dir \($rundir) --ack \(.key)=REASON." ] end;

def proj: {text, type, basis, evidence};
def challenged: [.claims|arr|.[]|objects|{id} + proj];
def vlines: RUN.verdict.lines // {};
def cstate($c):
  if RUN.challenger == null then "none" elif RUN.verdict == null then "pending"
  else (first(CHL[] | select(.id == $c.id)) // null) as $ch
  | if $ch == null then "new" elif ($ch|proj) != ($c|proj) then "changed"
    else vlines[$c.id].word as $w
    | if ($c.status|IN("uncertain","unknown")) then "open-status"
      elif ($c.status == "supported" and $w == "HOLDS") or ($c.status == "refuted" and $w == "REFUTED") then "agree"
      else "dispute" end end end;
def rebuttal_problems($c):
  $c.rebuttal as $rb |
  if ($rb|type) != "object" then ["missing"] else
  [ (if ($rb.text|ne|not) then "rebuttal.text is empty." else empty end),
    (if ($rb.evidence|arr|length) == 0 then "rebuttal.evidence needs at least one item." else empty end),
    ($rb.evidence|arr|to_entries[] | .key as $k | .value | item_problems("rebuttal evidence \($k+1)")[]),
    (if ($rb.evidence|arr|length) > 0 and all($rb.evidence[]; . as $e | any($c.evidence|arr|.[]; . == $e)) then "rebuttal.evidence must add new evidence, not repeat the claim's own." else empty end) ] end;
def resolve_stage:
  (.claims|arr) as $cl | (.missed|obj) as $ms |
  if RUN.challenger == null or RUN.verdict == null then [] else
  [ ($cl[] | objects | . as $c | select(cstate($c) == "dispute") | rebuttal_problems($c) as $p | select($p != [])
      | vlines[$c.id] as $v
      | "\($c.id): you say \($c.status); the challenger says \($v.word)\(if ($v.reason|ne) then ": " + $v.reason else "" end). Change the status, or keep it and add \"rebuttal\": {\"text\": ..., \"evidence\": [new items that pass R1]}" + (if $p == ["missing"] then "." else ". Problems: " + ($p|join(" ")) end)),
    (RUN.verdict.missed|arr|to_entries[] | "M\(.key+1)" as $m | select($ms[$m]|ne|not)
      | "\($m) MISSED: \(.value|tojson). Respond in claims.json under \"missed\": {\"\($m)\": \"C<n>, a new claim\" or why it is not relevant}.") ] end;

def all_stages: {frame: frame_problems, gates: (if $rundir == "" then [] else gate_stage end), claims: claims_stage, resolve: resolve_stage};

def parse_reply($t; $ids):
  [$t | split("\n")[] | gsub("[*`]"; "") | sub("^\\s*(?:[-+•>]\\s*|[0-9]+[.)]\\s*)?"; "")] as $ls
  | [$ls[] | select(test("^c[0-9]+\\s*[:–—-]"; "i")) | capture("^(?<id>[cC][0-9]+)\\s*[:–—-]\\s*(?<w>[^\\s:–—.,;-]*)(?<r>.*)$")
      | {id: (.id|ascii_upcase), word: (.w|ascii_upcase), reason: (.r|sub("^\\s*[:–—.,-]*\\s*"; ""))}] as $v
  | [$ls[] | select(test("^missed\\s*[:–—-]"; "i")) | sub("^[Mm][Ii][Ss][Ss][Ee][Dd]\\s*[:–—-]\\s*"; "") | select(test("^none\\.?\\s*$"; "i")|not) | select(ne)] as $m
  | {v: $v, m: $m, errors: (
      ([$v[] | select(.id|IN($ids[])|not) | "\(.id) is not a claim in the brief."] | unique)
      + [$v[] | select(.word|IN("HOLDS","REFUTED","UNSUPPORTED")|not) | "\(.id): \"\(.word)\" is not HOLDS, REFUTED or UNSUPPORTED."]
      + ([$v[].id] | group_by(.) | map(select(length > 1) | "\(.[0]) has more than one verdict line."))
      + ([$ids[] | select(IN($v[].id)|not)] | if length > 0 then ["No verdict line for \(join(", "))."] else [] end)
      + (if any($ls[]; test("^missed\\s*[:–—-]?\\s*$"; "i")) then ["A MISSED line is empty. Each missed item goes on its own line after MISSED:, or the reply says MISSED: none."] else [] end))};

def evline($pin): . as $e | flines(.path) as $ls
  | "\(.path) (\(if $ls == null then "missing" else ($ls|kindof) end)\(if $ls != null then (($ls|hit($e.contains|arr)) as $h | if $h then ", line \($h)" else "" end) else "" end)): \(.shows)"
    + (if $pin then ". Pinned: \(.contains|arr|map(tojson)|join(", "))" else "" end);
def gate_lines($ev): flines($ev) as $ls | if $ls == null then [] else [$ls[2:][] | select(test("^(FAIL|NO DATA|WARN)"))] end;
def gate_summary:
  $G[0] as $g | (RUN.gates // {}) as $gs |
  if $g == null then ["No gates file in the project."]
  elif $gs.choice == "skip" then ["Gates skipped. Reason: \($gs.skip_reason)"]
  elif $gs.choice == null then ["Gates not run."]
  else [ ($g.data.gates|arr|.[]|objects) as $d | ($gs.results|obj)[$d.name] as $r
    | if $r == null then "- \($d.name): not run (selection: \($gs.choice))"
      else "- \($d.name): " + (if $r.exit == 0 then "PASS" elif (($gs.acks|obj)[$d.name]|ne) then "FAILED (acknowledged: \($gs.acks[$d.name]))" else "FAILED" end)
        + " (exit \($r.exit); output \($r.evidence); command: \($d.run))", (gate_lines($r.evidence)[] | "    " + .) end ] end;

def brief:
  . as $doc |
  [ "# Rigor challenge brief", "",
    "You are the challenger. Another model wrote the claims below. Find what is wrong with them. Work read-only: read files, run read-only commands, fetch sources again. Change nothing.", "",
    "Question: \($doc.frame.question)",
    "Project root: \($root)",
    "Run folder: \($rundir). A path that starts with evidence/ is in the run folder; any other relative path is under the project root.", "",
    "## What the script checked", "",
    "It checked that each cited line exists and holds the pinned strings, and that every number in a supported claim's text equals a number in its pinned strings. Numbers inside backticks are names or date labels and were not checked. It did not check that a figure was computed correctly or that the right line or record was chosen. That is your job.", "",
    "## What to do", "",
    "1. Recompute every figure from the files. Do not trust the claims' arithmetic.",
    "2. Check that each pinned line is the right metric, unit and period.",
    "3. Fetch transcribed sources again.",
    "4. Try to refute each claim.",
    "5. Say when a claim is really a cause or a recommendation, or when its basis is misstated. Basis: observed means the record states it; computed means derived from records by a saved command or tool; inferred means reasoned from other claims or from indirect evidence.",
    "6. Look for what was not examined.", "",
    "## Claims", "",
    ($doc.claims|arr|.[]|objects | "### \(.id) (\(.type), \(.basis))", "", .text, "", "Evidence:",
      (if (.evidence|arr|length) == 0 then "- none" else (.evidence[]|objects|"- " + evline(true)) end), ""),
    "## Gate output", "", gate_summary[], "",
    "## Answer format", "",
    "One line per claim, then MISSED lines. Nothing else is read.", "",
    "C1: HOLDS - why", "C2: REFUTED - why", "C3: UNSUPPORTED - why", "MISSED: something that should have been examined", "",
    "Use exactly one of HOLDS, REFUTED or UNSUPPORTED, and give each claim exactly one line. Write MISSED: none if nothing was missed."
  ] | join("\n");

def outcome($c):
  cstate($c) as $s | vlines[$c.id] as $v
  | (if $v then $v.word + (if ($v.reason|ne) then ": " + $v.reason else "" end) else "" end) as $vt
  | if $s == "none" then "not challenged (no challenger)" elif $s == "pending" then "not challenged"
    elif $s == "new" then "not challenged (added after the challenge)"
    elif $s == "changed" then "not challenged (changed after the challenge)"
    elif $s == "open-status" then "challenger said \($vt)"
    elif $s == "agree" then (if $c.status == "supported" then "upheld (challenger: \($vt))" else "refuted, and the challenger agreed (\($vt))" end)
    else "disputed: you say \($c.status); the challenger says \($vt). Rebuttal: \($c.rebuttal.text)" end;
def rivals_with($fr; $s): [$fr.rivals|arr|.[]|objects|select(.status == $s)|.answer] | if length == 0 then "none" else join("; ") end;
def claim_block($fr):
  . as $c | "- \(.id) [\(.type), \(.basis), \(.status)] \(outcome($c))", "    \(.text)",
  (if .type == "cause" and .status == "supported" then "    Best supported explanation, not proof. Rivals ruled out: \(rivals_with($fr; "ruled out")). Confirmed: \(rivals_with($fr; "confirmed"))." else empty end),
  (.evidence|arr|.[]|objects|"    evidence: " + evline(false)),
  (if cstate($c) == "dispute" then (.rebuttal.evidence|arr|.[]|objects|"    rebuttal evidence: " + evline(false)) else empty end);
def sect($fr; $t; $xs): "", $t, (if ($xs|length) == 0 then "  none" else ($xs[]|claim_block($fr)) end);
def done_line:
  ([(RUN.gates.results // {})|to_entries[]|select(.value.exit != 0)]|length) as $n
  | if $n > 0 and RUN.gates.choice != "skip" then "RIGOR: DONE, with \($n) failing gate(s) acknowledged" else "RIGOR: DONE" end;
def report:
  . as $doc | (.frame|obj) as $fr | (.claims|arr|map(objects)) as $cl | RUN as $r |
  "RIGOR REPORT",
  "Question: \($fr.question)",
  "Evidence date: \($fr.evidence_date). Kind: \($fr.kind)." + (if ($fr.figures_from|ne) then " Figures from: \($fr.figures_from)." else "" end),
  "Run: \($rundir). Project root: \($root).",
  "Upheld means the challenger agreed with a supported claim. It is not proof.",
  sect($fr; "Observed and computed claims"; [$cl[]|select((.basis|IN("observed","computed")) and (.status|IN("supported","refuted")))]),
  sect($fr; "Inferred claims (an explanation is the best supported reading, not proof)"; [$cl[]|select(.basis == "inferred" and (.status|IN("supported","refuted")))]),
  sect($fr; "Hypotheses (uncertain) and unknowns"; [$cl[]|select(.status|IN("uncertain","unknown"))]),
  (if ($fr.rivals|arr|length) > 0 then "", "Rival answers", ($fr.rivals[]|objects|"- \(.answer) [\(.status)]\(if .null_answer == true then " (null answer)" else "" end)\(if (.because|arr|length) > 0 then ": " + ([.because[]|"\(.claim): \(.how)"]|join("; ")) else "" end)") else empty end),
  ([CHL[] | .id as $i | select(any($cl[]; .id == $i)|not)] as $gone
    | if ($gone|length) > 0 and $r.verdict != null then "", "Challenged claims no longer in the register", ($gone[]|"- \(.id): \(.text) (challenger: \(vlines[.id].word // "no line"))") else empty end),
  (if ($r.verdict.missed|arr|length) > 0 then "", "Challenger's MISSED items", ($r.verdict.missed|to_entries[]|"- M\(.key+1): \(.value|tojson). Response: \(($doc.missed|obj)["M\(.key+1)"])") else empty end),
  "", "Waivers", ([$cl[]|.id as $i|(.waive|obj|to_entries[]|"- \($i) \(.key): \(.value)")] | if length == 0 then "  none" else .[] end),
  "", "Gates", gate_summary[],
  "", "Challenger",
  (if $r.challenger == null then "No challenger. No-challenger reason: \($r.no_challenger_reason). Every claim is not challenged."
   else "Recorded: \($r.challenger) at \($r.effort), " + (if $r.pairing == "default" then "the default pairing for \($r.coordinator)." else "named by the user at start, not the default pairing for \($r.coordinator)." end),
     (if $r.verdict then "Ran: \($r.verdict.model) at \($r.verdict.effort)" + (if $r.verdict.default then ", the recorded pairing." else ", not the recorded pairing." end) + (if ($r.verdict.override_reason|ne) then " Override reason: \($r.verdict.override_reason)" else "" end) + " Reply: \($rundir)/challenge-report.md" else empty end) end),
  "", "Primary records", ($fr.primary_records|arr|.[]|objects|"- \(.record): \(.why)"),
  "", "What may have changed", (if ($fr.changed_since|type) == "array" then ($fr.changed_since[]|"- " + .) else "- \($fr.changed_since)" end),
  "", "Not checked", ($fr.not_checked|arr|.[]|"- " + tostring),
  "", "Limits of these checks",
  "The script checks form and consistency: each cited line exists, the numbers in a supported claim's text match its pinned strings, and the required second looks were recorded. It does not prove a claim is true, that a figure was computed correctly, or that the right record was chosen. It does not check numbers inside backticks, or that a file is unchanged apart from the pinned line. It checks the challenger model the coordinator typed, not what ran. Those rest on the challenger.",
  "", done_line;
JQ

# J PROGRAM INPUT [jq options]: run a program with the library and the run context.
J() { local p="$1" f="$2"; shift 2
  jq -r "$@" --arg root "$ROOT" --arg rundir "$RUNDIR" --arg self "$SELF" --slurpfile F "$FILES" \
    --slurpfile R "$RUNJ" --slurpfile G "$GATESJ" --slurpfile CH "$CHJ" "$LIB
$p" "$f"; }
setrun() { local p="$1"; shift; jq "$@" "$p" "$RUNJ" > "$W/run.tmp" && mv "$W/run.tmp" "$RUNJ" || die "cannot update $RUNJ"; }

load_gates() {
  GATESJ="$W/null.json"; GF=""
  for f in "$ROOT/rigor-gates.json" "$ROOT/tools/rigor-gates.json"; do [ -f "$f" ] && { GF="$f"; break; }; done
  [ -n "$GF" ] || return 0
  GATESJ="$W/gates.json"
  jq -n --arg p "$GF" --slurpfile d "$GF" '{path: $p, data: $d[0]}' > "$GATESJ" 2>/dev/null \
    || jq -n --arg p "$GF" '{path: $p, data: null}' > "$GATESJ"
}
load_run() {
  [ -n "$1" ] || die "Pass --dir with the run folder."
  [ -f "$1/run.json" ] || die "No run at $1 (run.json is missing)."
  RUNDIR=$(cd "$1" && pwd -P); RUNJ="$RUNDIR/run.json"; CLAIMS="$RUNDIR/claims.json"
  ROOT=$(jq -r .root "$RUNJ")
  [ -f "$RUNDIR/challenged.json" ] && CHJ="$RUNDIR/challenged.json"
  load_gates
}
# Read every cited file and every run evidence file into one JSON map, path -> content.
build_files() {
  FILES="$W/empty.json"
  { J '[(.claims|arr|.[]|objects|((.evidence|arr|.[]), (.rebuttal|objects|.evidence|arr|.[]))) | objects | .path | select(ne) | resolve(.)] | unique | .[]' "$CLAIMS" 2>/dev/null
    if [ -n "$RUNDIR" ]; then for f in "$RUNDIR"/evidence/*; do [ -f "$f" ] && printf '%s\n' "$f"; done; fi
  } | sort -u | while IFS= read -r p; do [ -f "$p" ] && jq -n --arg p "$p" --rawfile c "$p" '{($p): $c}'; done > "$W/parts"
  jq -s 'add // {}' "$W/parts" > "$W/files.json" || die "cannot read the evidence files."
  FILES="$W/files.json"
}
compute() {
  if ! jq -es 'length == 1 and (.[0]|type) == "object"' "$CLAIMS" >/dev/null 2>"$W/err"; then
    jq -n --arg e "$(head -1 "$W/err")" --arg c "$CLAIMS" '{frame: ["\($c) is not valid JSON holding one object with frame and claims\(if $e == "" then " (it is empty or holds something else)" else " (" + $e + ")" end). Fix it."], gates: [], claims: [], resolve: []}' > "$W/st.json"
    return
  fi
  build_files
  J 'all_stages' "$CLAIMS" -c > "$W/st.json" 2>"$W/err" || die "internal check failed on $CLAIMS: $(head -1 "$W/err")"
}
print_stage() { # key title
  printf 'RIGOR: OPEN (stage: %s)\n' "$2"
  jq -r --arg s "$1" '.[$s] | to_entries[] | "\(.key+1). \(.value)"' "$W/st.json"
}
challenge_stage() {
  jq -e '.challenger != null and .verdict == null' "$RUNJ" >/dev/null || return 1
  J 'brief' "$CLAIMS" > "$W/brief.md"; J 'challenged' "$CLAIMS" > "$W/ch.json"
  local note="" m e
  if ! cmp -s "$W/brief.md" "$RUNDIR/challenge-brief.md" || ! cmp -s "$W/ch.json" "$RUNDIR/challenged.json"; then
    note="Wrote challenge-brief.md and challenged.json."
    [ -f "$RUNDIR/challenge-brief.md" ] && note="The claims or gate output changed, so challenge-brief.md was rewritten. Send this version."
    cp "$W/brief.md" "$RUNDIR/challenge-brief.md"; cp "$W/ch.json" "$RUNDIR/challenged.json"
  fi
  m=$(jq -r .challenger "$RUNJ"); e=$(jq -r .effort "$RUNJ")
  echo "RIGOR: OPEN (stage: Challenge)"
  [ -n "$note" ] && echo "$note"
  echo "1. Start $m at effort $e as a fresh, read-only agent through the runtime's delegation tool. Give it $RUNDIR/challenge-brief.md and none of your reasoning, and make sure it can read the files the brief lists. If the runtime cannot reach $m, tell the user which model was unavailable and ask; do not substitute."
  echo "2. Save its reply, unedited, to a file, then run: $SELF verdict --dir $RUNDIR --model <model it ran> --effort <effort it ran> --file <reply file>"
  return 0
}
first_open() {
  local s t n
  for s in frame:Frame gates:Gates claims:Claims; do
    t=${s#*:}; s=${s%%:*}; n=$(jq ".$s|length" "$W/st.json")
    if [ "$n" -gt 0 ]; then print_stage "$s" "$t"; return 0; fi
  done
  challenge_stage && return 0
  n=$(jq '.resolve|length' "$W/st.json"); [ "$n" -gt 0 ] && { print_stage resolve Resolve; return 0; }
  return 1
}
write_evidence() { # dest exit cmdline outfile
  local n; n=$(awk 'END{print NR}' "$4")
  { printf '# rigor-evidence kind=command exit=%s output-lines=%s date=%s\n' "$2" "$n" "$(now)"
    printf '# cmd: %s\n' "$(printf '%s' "$3" | tr '\n' ' ')"; cat "$4"; } > "$1"
  echo "$n"
}
need() { [ $# -ge 2 ] || die "$1 needs a value."; }

cmd_start() {
  local q="" co="" ch="" ef="" noch="" dir="" root="" dch="" deff="" k chal ceff pairing slug t
  while [ $# -gt 0 ]; do case "$1" in
    --question) need "$@"; q="$2"; shift 2;; --coordinator) need "$@"; co="$2"; shift 2;;
    --challenger) need "$@"; ch="$2"; shift 2;; --effort) need "$@"; ef="$2"; shift 2;;
    --no-challenger) need "$@"; noch="$2"; shift 2;; --dir) need "$@"; dir="$2"; shift 2;;
    --root) need "$@"; root="$2"; shift 2;; *) die "start: unknown option $1";; esac; done
  [ -n "$q" ] || die "start needs --question."
  [ -n "$co" ] || die "start needs --coordinator with your own model id."
  [ -n "$noch" ] && [ -n "$ch$ef" ] && die "Use --no-challenger or --challenger/--effort, not both."
  for k in $CLAUDE_IDS; do case "$(lc "$co")" in *"$k"*) dch=$CLAUDE_CHALLENGER; deff=$CLAUDE_EFFORT;; esac; done
  if [ -z "$dch" ]; then for k in $OPENAI_IDS; do case "$(lc "$co")" in *"$k"*) dch=$OPENAI_CHALLENGER; deff=$OPENAI_EFFORT;; esac; done; fi
  chal=""; ceff=""; pairing=none
  if [ -z "$noch" ]; then
    chal=${ch:-$dch}; ceff=${ef:-$deff}
    [ -n "$chal" ] || die "No default challenger for coordinator '$co'. Pass --challenger MODEL --effort EFFORT, or --no-challenger REASON."
    [ -n "$ceff" ] || die "Pass --effort for challenger $chal."
    pairing=default; { [ "$chal" = "$dch" ] && [ "$ceff" = "$deff" ]; } || pairing=override
  fi
  if [ -n "$root" ]; then ROOT=$(cd "$root" 2>/dev/null && pwd -P) || die "--root $root is not a folder."
  else ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || ROOT=$(pwd -P); fi
  if [ -z "$dir" ]; then
    t=${TMPDIR:-/tmp}; slug=$(printf '%s' "$q" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | cut -c1-40 | sed 's/^-//; s/-$//')
    dir="${t%/}/rigor/$(date +%Y%m%d-%H%M%S)-$slug"
  fi
  [ -f "$dir/run.json" ] && die "$dir already holds a run."
  mkdir -p "$dir/evidence" || die "cannot create $dir."
  RUNDIR=$(cd "$dir" && pwd -P); RUNJ="$RUNDIR/run.json"; CLAIMS="$RUNDIR/claims.json"
  jq -n --arg q "$q" --arg co "$co" --arg ch "$chal" --arg ef "$ceff" --arg pa "$pairing" --arg nr "$noch" --arg root "$ROOT" --arg d "$(date +%Y-%m-%d)" \
    '{question: $q, coordinator: $co, challenger: (if $ch == "" then null else $ch end), effort: (if $ef == "" then null else $ef end),
      pairing: $pa, no_challenger_reason: (if $nr == "" then null else $nr end), root: $root, date: $d,
      gates: {choice: null, skip_reason: null, results: {}, acks: {}}, verdict: null}' > "$RUNJ"
  jq -n --arg q "$q" --arg d "$(date +%Y-%m-%d)" \
    '{frame: {question: $q, evidence_date: $d, kind: "", primary_records: [{record: "", why: ""}], changed_since: "", not_checked: [], rivals: [], figures_from: ""}, claims: []}' > "$CLAIMS"
  load_gates
  echo "Run: $RUNDIR"
  echo "Register: $CLAIMS (edit it in place)"
  echo "Project root: $ROOT"
  case "$pairing" in
    none) echo "Challenger: none. Reason: $noch. Every claim will be reported as not challenged.";;
    default) echo "Challenger: $chal at $ceff (default pairing for $co).";;
    *) echo "Challenger: $chal at $ceff (named by the user; the default for $co is ${dch:-none}).";;
  esac
  if [ -n "$GF" ]; then
    echo "Project gates in $GF (nothing has been run). Read each command. Run only commands that are checks; tell the user about any that would change something:"
    jq -r '.data.gates[]? | "  \(.name) [\((.tags // [])|join(", "))]: \(.run)"' "$GATESJ" 2>/dev/null || echo "  (the file is not valid JSON)"
  else echo "No project gates (no rigor-gates.json or tools/rigor-gates.json under the root)."; fi
  compute; first_open; exit 1
}

cmd_next() {
  local dir=""; while [ $# -gt 0 ]; do case "$1" in --dir) need "$@"; dir="$2"; shift 2;; *) die "next: unknown option $1";; esac; done
  load_run "$dir"; compute
  if first_open; then echo "Do these, then run: $SELF next --dir $RUNDIR"; exit 1; fi
  J 'done_line' "$CLAIMS"; exit 0
}

cmd_report() {
  local dir=""; while [ $# -gt 0 ]; do case "$1" in --dir) need "$@"; dir="$2"; shift 2;; *) die "report: unknown option $1";; esac; done
  load_run "$dir"; compute
  if first_open; then echo "No report while demands are open. Do these, then run: $SELF next --dir $RUNDIR"; exit 1; fi
  J 'report' "$CLAIMS"; exit 0
}

cmd_save() {
  local dir="" name="" code n cl
  while [ $# -gt 0 ]; do case "$1" in
    --dir) need "$@"; dir="$2"; shift 2;; --name) need "$@"; name="$2"; shift 2;;
    --) shift; break;; *) die "save: unknown option $1 (put the command after --)";; esac; done
  case "$name" in ""|*/*|.*) die "save needs --name, a plain file name such as orders-2026.txt";; esac
  [ $# -gt 0 ] || die "save needs a command after --."
  load_run "$dir"
  "$@" </dev/null >"$W/out" 2>&1; code=$?
  cl=$(printf '%q ' "$@"); cl=${cl% }
  n=$(write_evidence "$RUNDIR/evidence/$name" "$code" "$cl" "$W/out")
  echo "Saved evidence/$name (exit $code, $n output lines). Cite it as \"path\": \"evidence/$name\"."
  exit 0
}

cmd_gates() {
  local dir="" tag="" all="" skip="" acks="" modes=0 a nm rs i cnt run code ev bad
  while [ $# -gt 0 ]; do case "$1" in
    --dir) need "$@"; dir="$2"; shift 2;; --tag) need "$@"; tag="$2"; modes=$((modes+1)); shift 2;;
    --all) all=1; modes=$((modes+1)); shift;; --skip) need "$@"; skip="$2"; modes=$((modes+1)); shift 2;;
    --ack) need "$@"; acks="$acks$2
"; shift 2;; *) die "gates: unknown option $1";; esac; done
  [ $modes -le 1 ] || die "gates takes one of --tag, --all or --skip."
  [ $modes -eq 1 ] || [ -n "$acks" ] || die "gates needs --tag TAG, --all, --skip REASON or --ack NAME=REASON."
  load_run "$dir"
  if [ -n "$skip" ]; then
    setrun '.gates.choice = "skip" | .gates.skip_reason = $r' --arg r "$skip"
    echo "Recorded: gates skipped. Reason: $skip"; exit 0
  fi
  [ -n "$GF" ] || die "No gates file under $ROOT (rigor-gates.json or tools/rigor-gates.json)."
  J 'gates_ok' "$GATESJ" -e >/dev/null || die "$GF is not valid. It needs {\"gates\": [{\"name\": ..., \"tags\": [...], \"run\": ...}]}, each gate with its own name."
  while IFS= read -r a; do
    [ -n "$a" ] || continue; nm=${a%%=*}; rs=${a#*=}
    [ "$nm" != "$a" ] && [ -n "$rs" ] || die "--ack needs NAME=REASON."
    jq -e --arg n "$nm" 'any(.data.gates[]; .name == $n)' "$GATESJ" >/dev/null || die "No gate named $nm in $GF."
    setrun '.gates.acks[$n] = $r' --arg n "$nm" --arg r "$rs"
    echo "Recorded: gate $nm does not block the answer. Reason: $rs"
  done <<EOF
$acks
EOF
  if [ $modes -eq 1 ]; then
    jq -c --arg t "$tag" '[.data.gates[] | select($t == "" or any((.tags // [])[]; . == $t))]' "$GATESJ" > "$W/sel.json"
    cnt=$(jq length "$W/sel.json")
    [ "$cnt" -gt 0 ] || die "No gate has tag '$tag'. Tags in $GF: $(jq -r '[.data.gates[].tags // [] | .[]] | unique | join(", ")' "$GATESJ")."
    if [ -n "$tag" ]; then setrun '.gates.choice = $c' --arg c "tag:$tag"; else setrun '.gates.choice = "all"'; fi
    i=0; while [ $i -lt "$cnt" ]; do
      nm=$(jq -r ".[$i].name" "$W/sel.json"); run=$(jq -r ".[$i].run" "$W/sel.json")
      echo "\$ $run   (gate $nm, in $ROOT)"
      (cd "$ROOT" && /bin/bash -c "$run") </dev/null >"$W/out" 2>&1; code=$?
      cat "$W/out"; echo "exit $code"
      ev="evidence/gate-$(printf '%s' "$nm" | tr -c 'A-Za-z0-9._-' '_').txt"
      write_evidence "$RUNDIR/$ev" "$code" "$run" "$W/out" >/dev/null
      setrun '.gates.results[$n] = {exit: $e, evidence: $v}' --arg n "$nm" --argjson e "$code" --arg v "$ev"
      i=$((i+1))
    done
  fi
  bad=$(jq -r '.gates as $g | [$g.results | to_entries[] | select(.value.exit != 0) | select(($g.acks[.key] // "") == "")] | length' "$RUNJ")
  [ "$bad" -eq 0 ] || { echo "$bad gate(s) failing and not acknowledged. Run next for what to do."; exit 1; }
  exit 0
}

cmd_verdict() {
  local dir="" model="" effort="" file="" ovr="" chal reff match=1
  while [ $# -gt 0 ]; do case "$1" in
    --dir) need "$@"; dir="$2"; shift 2;; --model) need "$@"; model="$2"; shift 2;;
    --effort) need "$@"; effort="$2"; shift 2;; --file) need "$@"; file="$2"; shift 2;;
    --override-reason) need "$@"; ovr="$2"; shift 2;; *) die "verdict: unknown option $1";; esac; done
  [ -n "$model" ] && [ -n "$effort" ] && [ -n "$file" ] || die "verdict needs --model, --effort and --file."
  [ -f "$file" ] || die "No reply file at $file."
  load_run "$dir"
  chal=$(jq -r '.challenger // ""' "$RUNJ"); reff=$(jq -r '.effort // ""' "$RUNJ")
  [ -n "$chal" ] || die "This run has no challenger (it was started with --no-challenger)."
  jq -e '.verdict == null' "$RUNJ" >/dev/null || die "A reply is already stored. A run has one challenge round."
  [ -f "$RUNDIR/challenged.json" ] || die "No challenge brief yet. Run next until it asks for the challenger."
  case "$(lc "$model")" in "$(lc "$chal")"*) ;; *) match=0;; esac
  [ "$(lc "$effort")" = "$(lc "$reff")" ] || match=0
  if [ $match -eq 0 ] && [ -z "$ovr" ]; then
    echo "RIGOR: REFUSED"
    echo "1. The reply came from $model at $effort, but the recorded challenger is $chal at $reff. Run the recorded model, or, if the user named this one or agreed to a substitute, pass --override-reason with why."
    exit 1
  fi
  J 'parse_reply($t; [CHL[].id])' "$W/null.json" --rawfile t "$file" -c > "$W/parsed.json" || die "cannot read $file."
  if [ "$(jq '.errors|length' "$W/parsed.json")" -gt 0 ]; then
    echo "RIGOR: REFUSED (the reply was not stored)"
    jq -r '.errors | to_entries[] | "\(.key+1). \(.value)"' "$W/parsed.json"
    echo "Ask the challenger again with the same brief and the answer format. Do not edit its reply."
    exit 1
  fi
  cp "$file" "$RUNDIR/challenge-report.md"
  setrun '.verdict = {model: $m, effort: $e, default: ($d == "1"), override_reason: (if $o == "" then null else $o end),
    file: "challenge-report.md", date: $t, lines: (reduce $p[0].v[] as $x ({}; .[$x.id] = {word: $x.word, reason: $x.reason})), missed: $p[0].m}' \
    --arg m "$model" --arg e "$effort" --arg d "$match" --arg o "$ovr" --arg t "$(now)" --slurpfile p "$W/parsed.json"
  echo "Stored the reply as challenge-report.md. Run: $SELF next --dir $RUNDIR"
  exit 0
}

cmd_check() {
  local root="" d
  CLAIMS=""
  while [ $# -gt 0 ]; do case "$1" in
    --claims) need "$@"; CLAIMS="$2"; shift 2;; --root) need "$@"; root="$2"; shift 2;; *) die "check: unknown option $1";; esac; done
  [ -f "$CLAIMS" ] || die "check needs --claims FILE (an existing register)."
  if [ -n "$root" ]; then ROOT=$(cd "$root" 2>/dev/null && pwd -P) || die "--root $root is not a folder."
  else d=$(dirname "$CLAIMS"); ROOT=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || ROOT=$(pwd -P); fi
  compute
  if [ "$(jq '(.frame + .claims)|length' "$W/st.json")" -gt 0 ]; then
    echo "RIGOR CHECK: OPEN ($CLAIMS)"
    jq -r '(.frame + .claims) | to_entries[] | "\(.key+1). \(.value)"' "$W/st.json"; exit 1
  fi
  echo "RIGOR CHECK: CLEAR ($CLAIMS). This checks form and consistency, not truth."; exit 0
}

usage() { cat <<EOF
Usage: rigor.sh COMMAND [options]
  start --question Q --coordinator MODEL [--challenger M --effort E] [--no-challenger REASON] [--dir D] [--root R]
  next --dir D
  save --dir D --name N -- CMD...
  gates --dir D (--tag T | --all | --skip REASON) [--ack NAME=REASON]
  verdict --dir D --model M --effort E --file F [--override-reason R]
  report --dir D
  check --claims FILE [--root DIR]
EOF
exit 2; }

[ $# -gt 0 ] || usage
c="$1"; shift
case "$c" in
  start) cmd_start "$@";; next) cmd_next "$@";; save) cmd_save "$@";; gates) cmd_gates "$@";;
  verdict) cmd_verdict "$@";; report) cmd_report "$@";; check) cmd_check "$@";; *) usage;;
esac
