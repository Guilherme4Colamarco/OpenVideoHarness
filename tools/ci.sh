#!/usr/bin/env bash
# ci.sh — the repo's own checks: the same run locally before a push and in GitHub Actions (.github/workflows/ci.yml).
#
#   tools/ci.sh                      everything the installed tools allow (shellcheck, pyflakes, ffmpeg are optional locally)
#   tools/ci.sh --smoke              only the bin/vh smoke tests
#   tools/ci.sh --shard i/n          shard i of n: the groups tools/ci-shards.txt deals to it (CI's macOS job runs 1/2 and 2/2)
#   tools/ci.sh --committed [opt]    check HEAD in a clean temporary checkout: what a push sends, not the working tree
#   VH_BASH=/bin/bash tools/ci.sh    run bin/vh and the syntax checks under another bash (macOS ships bash 3.2)
#
# Why each group exists: the v0.2.1 review found macOS-only sed/stat/md5 flags that broke every Linux user, a
# doc/CLI mismatch, and a CLI that exited 0 on typos. These checks keep those from coming back. The groups (the *_checks
# functions below) and the order they run in are listed in tools/ci-shards.txt, with their time on CI's macOS runner.
# A run ends with how long it took, each group's seconds and the ten slowest checks.
# Exit status: 0 when every check passed, 1 when any failed (the count is in the last line), 2 when it could not run
# (a usage error; no groups to run).
set -uo pipefail
unset CDPATH   # an exported one could send this relative cd elsewhere (as in bin/vh)
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
ROOT=$(pwd)
VH_BASH=${VH_BASH:-bash}
export OVH_LOCAL_MD=/dev/null/LOCAL.md   # this machine's LOCAL.md stays out of every check (one that needs it writes its own)
fails=0
# each check's time: since the check before it, or since its group began (EPOCHREALTIME in bash 5; whole seconds in 3.2)
CI_TIMES=() CI_GROUPS=() CI_LAST=0 CI_NOW=0
clock() { local r=${EPOCHREALTIME:-}; if [ -n "$r" ]; then r=${r//[.,]/}; CI_NOW=$((10#$r / 1000)); else CI_NOW=$((SECONDS * 1000)); fi; }
took() { local m=${1%%$'\n'*}; clock; CI_TIMES+=("$((CI_NOW - CI_LAST))	${m:0:110}"); CI_LAST=$CI_NOW; }
ok() { took "$*"; printf '\033[32m✓\033[0m %s\n' "$*"; }
bad() { took "$*"; printf '\033[31m✗\033[0m %s\n' "$*"; fails=$((fails + 1)); }
skipped=""
skip() { took "$1"; printf '\033[33m-\033[0m %s (skipped: %s)\n' "$1" "$2"; skipped="$skipped${skipped:+, }$1"; }
no_chrome() { # no_chrome <what>: what needs a headless Chrome and found none. Here a skip; on CI (CI=true) a failure: every
  # runner has one, and a skip there would pass a run that drew nothing
  if [ "${CI:-}" = true ]; then bad "$1: no Chrome, Chromium or chrome-headless-shell on this CI runner, and the page tools need one"
  else skip "$1" "no Chrome, Chromium or chrome-headless-shell"; fi
}
no_webgl() { # no_webgl <what>: the Three.js layer got no WebGL2, even with --soft-gl. Here a skip; on CI (CI=true) a
  # failure, as no_chrome: GitHub's runners draw it in software, and a skip there would pass a run that drew nothing
  if [ "${CI:-}" = true ]; then bad "$1: no WebGL2 for the Three.js layer on this CI runner, even with --soft-gl"
  else skip "$1" "no WebGL here even with --soft-gl"; fi
}
files() { git ls-files "$@" | grep -v -E '^references/|(^|/)node_modules/|\.min\.js$'; }

static_checks() {
  local f n out
  # shell: parse with the bash that will run it, lint, and ban commands that only exist on one platform
  n=0; while IFS= read -r f; do "$VH_BASH" -n "$f" || { bad "bash -n $f"; n=$((n + 1)); }; done < <(files bin/vh '*.sh')
  [ $n = 0 ] && ok "shell syntax ($("$VH_BASH" -c 'echo $BASH_VERSION'))"
  if command -v shellcheck >/dev/null; then
    if out=$(files bin/vh '*.sh' | xargs shellcheck -S warning 2>&1); then ok "shellcheck -S warning"; else echo "$out"; bad "shellcheck"; fi
  else skip "shellcheck" "not installed; CONTRIBUTING.md shows how to run it through uv"; fi
  # BSD-only or GNU-only flags, matched where a command starts: a statement start, a pipe, after if / while / until / do /
  # then / else, after `{`, `(`, `!` or a case arm, and behind a wrapper (xargs, sudo, exec, env, time, nohup, nice, command)
  # with its flags, VAR=value tokens or arguments. A small quote-aware scanner blanks comments, single-quoted strings,
  # double-quoted strings without $ or backticks, and heredoc bodies first (line numbers kept): a heredoc opens only at a
  # `<<name` outside quotes and comments with whitespace before it (not `<<<`, `1<<n` or a `<<EOF` in a comment), and its
  # terminator is matched ignoring leading tabs and trailing blanks, so a stray `<<` cannot blank the rest of a file.
  # A line may opt out with a trailing "# portable-ok: <why>"
  local np='(^|[;&|(){}!`]|\$\()[[:space:]]*((if|while|until|do|then|else|elif|xargs|sudo|exec|env|time|nohup|nice|command)([[:space:]]+(-[^[:space:]]*|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|[A-Za-z0-9_.{}-]+))*[[:space:]]+)*(sed -i|stat -[cf] |md5 -q|md5sum|readlink -f|grep -[a-zA-Z]*P|date -[djv] |xargs -r|find [^;|]*-printf|base64 -D|sort -V|tac( |$))'   # portable-ok: the list itself
  local awkprog=''; IFS= read -r -d '' awkprog <<'AWK' || true   # a heredoc, not $(…): the awk text has a backtick
BEGIN { term = "" }
term != "" { t = $0; sub(/^\t+/, "", t); sub(/[ \t]+$/, "", t); if (t == term) term = ""; print ""; next }
/portable-ok/ { print ""; next }
{ line = $0; out = ""; q = ""; buf = ""; n = length(line); i = 1
  while (i <= n) {
    c = substr(line, i, 1)
    if (q == "") {
      if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;]/)) break
      if (c == "\\") { out = out c substr(line, i + 1, 1); i += 2; continue }
      if (c == "'" || c == "\"") { q = c; buf = ""; i++; continue }
      if (c == "<" && substr(line, i, 2) == "<<" && substr(line, i + 2, 1) != "<" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t]/)) {
        rest = substr(line, i + 2); sub(/^-/, "", rest)
        if (match(rest, /^["']?[A-Za-z_][A-Za-z0-9_]*/)) { term = substr(rest, RSTART, RLENGTH); gsub(/["']/, "", term) }
      }
      out = out c; i++
    } else {
      if (q == "\"" && c == "\\") { buf = buf c substr(line, i + 1, 1); i += 2; continue }
      if (c == q) { out = out ((q == "\"" && buf ~ /[$`]/) ? q buf q : q q); q = ""; i++; continue }
      buf = buf c; i++
    }
  }
  print out }
AWK
  out=$(while IFS= read -r f; do awk "$awkprog" "$f" | grep -n -E "$np" | sed "s#^#$f:#"; done < <(files bin/vh '*.sh'))
  if [ -n "$out" ]; then echo "$out"; bad "non-portable shell commands (use a helper that works with both BSD and GNU tools)"
  else ok "no BSD-only / GNU-only shell commands"; fi
  # python: compile everything, then pyflakes when available
  n=0; while IFS= read -r f; do python3 -m py_compile "$f" 2>/dev/null || { bad "py_compile $f"; n=$((n + 1)); }; done < <(files 'tools/*.py' 'styles/_swatch/*.py' 'styles/*/swatch.py')
  [ $n = 0 ] && ok "python syntax"
  if python3 -m pyflakes --version >/dev/null 2>&1; then
    if out=$(files 'tools/*.py' 'styles/_swatch/*.py' 'styles/*/swatch.py' | xargs python3 -m pyflakes 2>&1); then ok "pyflakes"; else echo "$out"; bad "pyflakes"; fi
  else skip "pyflakes" "not installed; CONTRIBUTING.md shows how to run it through uv"; fi
  # Blender style scenes: the static check render.sh runs before Blender (no os, subprocess, open, random, handlers …),
  # and the GPL header every file that imports bpy carries (engines/blender.md, "许可证")
  n=0; while IFS= read -r f; do
    python3 styles/_swatch/blender_prep.py scan "$f" || { bad "blender_prep.py scan $f"; n=$((n + 1)); }
  done < <(files 'styles/*/swatch.py')
  out=$(files '*.py' | python3 -c '
import ast, sys
BLENDER = {"bpy", "bmesh", "mathutils", "bpy_extras", "gpu", "gpu_extras", "freestyle", "bl_math", "idprop", "aud", "imbuf", "blf", "bgl"}
for f in sys.stdin.read().splitlines():
    src = open(f, encoding="utf-8").read()
    try: tree = ast.parse(src, f)
    except SyntaxError: continue
    mods = {a.name.split(".")[0] for n in ast.walk(tree) if isinstance(n, ast.Import) for a in n.names}
    mods |= {(n.module or "").split(".")[0] for n in ast.walk(tree) if isinstance(n, ast.ImportFrom)}
    if mods & BLENDER and "SPDX-License-Identifier: GPL-3.0-or-later" not in "".join(src.splitlines(True)[:3]): print(f)
')
  [ -z "$out" ] || { echo "$out" | sed 's/$/: imports a Blender module but has no GPL-3.0-or-later SPDX header in its first 3 lines/'; n=$((n + 1)); bad "GPL header on Blender scripts"; }
  [ $n = 0 ] && ok "Blender scenes: static check and GPL headers"
  # js: node --check detects ES modules by syntax (node ≥ 22)
  n=0; while IFS= read -r f; do node --check "$f" 2>/dev/null || { node --check "$f"; bad "node --check $f"; n=$((n + 1)); }; done < <(files '*.js' '*.mjs')
  [ $n = 0 ] && ok "js syntax"
  if python3 tools/audio/test_music_clock.py; then ok "music clock: JS/Python agree on bar time and invalid maps"; else bad "music clock"; fi
  if python3 tools/audio/test_time_map.py; then ok "time map: JS/Python agree on maps and every kind of time reference; events.json headers; time_map.py check"; else bad "time map"; fi
  # the example time-map solver (engines/canvas-film/examples): its synthetic spec solves to a map timemap check takes, and
  # a card's text made longer between two fixed points (a pin at 15 s, a segment end at 32 s) moves knots in that span alone
  local ex="$ROOT/engines/canvas-film/examples" d; d=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  if python3 "$ex/time-map-solve.py" "$ex/time-map-spec.json" "$d/a.map.json" >/dev/null && vh timemap check "$d/a.map.json" >/dev/null \
    && python3 - "$ex/time-map-solve.py" "$ex/time-map-spec.json" "$d" <<'PY'
import json, subprocess, sys
solve, spec, d = sys.argv[1:]
s = json.load(open(spec, encoding="utf-8"))
e = next(e for e in s["events"] if e["id"] == "d0505"); e["text"] += "，比去年同期高出一截"
json.dump(s, open(f"{d}/b.json", "w", encoding="utf-8"), ensure_ascii=False)
subprocess.run([sys.executable, solve, f"{d}/b.json", f"{d}/b.map.json"], check=True, stdout=subprocess.DEVNULL)
A, B = (json.load(open(f"{d}/{n}.map.json", encoding="utf-8")) for n in "ab")
out = lambda m: [k for k in m["knots"] if not 15 < k[0] < 32]
pins = lambda m: [(e["id"], e["t"]) for e in m["events"] if e["id"] in ("d0412", "d1010")]
sys.exit(0 if out(A) == out(B) and A["knots"] != B["knots"] and pins(A) == pins(B) == [("d0412", 15), ("d1010", 48)] else 1)
PY
  then ok "time-map solver example: its spec solves to a map timemap check takes; an edit between two pins moves that span's knots alone"
  else bad "time-map solver example (engines/canvas-film/examples/time-map-solve.py)"; fi
  rm -rf "$d"
  # media: videos live in the GitHub release "media" (tools/media.txt, tools/fetch_media.sh), so a clone stays small;
  # the style swatches (about 1 MB each, read by the tools) are the one exception. No file over 8 MB either.
  out=$(files | while IFS= read -r f; do
      lc=$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')   # [[ ]], not case: bash 3.2 can't parse case inside $( ); lower-cased: .GIF too
      if [[ ! "$f" =~ ^styles/[^/]+/media/swatch\.mp4$ && "$lc" =~ \.(mp4|mov|webm|mkv|gif)$ ]]; then echo "$f: a video (put it in the media release, see tools/fetch_media.sh)"; continue; fi
      if [ -f "$f" ]; then s=$(wc -c < "$f"); [ "$s" -gt 8000000 ] && echo "$f: $((s / 1000000)) MB, over 8 MB"; fi
    done)
  if [ -n "$out" ]; then echo "$out"; bad "videos or large files in git"; else ok "no videos or files over 8 MB in git"; fi
}

doc_checks() {
  local head out
  head=$(head -3 AGENTS.md)
  if [ "$(tail -n +4 AGENTS.md)" = "$(cat CLAUDE.md)" ] && [ -n "$head" ]; then ok "AGENTS.md generated from CLAUDE.md"
  else bad "AGENTS.md is out of sync with CLAUDE.md: run bin/vh sync-agents"; fi
  # the command table (tools/commands.json): its own rules, its stages those of playbook/01's 总表
  if out=$(python3 tools/commands.py check 2>&1); then ok "$out: each with a summary, when, stages (playbook/01's), reads, writes, usage; subcommands in their usage"
  else echo "$out"; bad "tools/commands.json"; fi
  # the ways out of a check's findings (tools/remedies.json): each kind checkrec.py writes, each run a real command, each
  # recipe filter finding a recipe, each doc there
  if out=$(python3 tools/remedies.py check 2>&1); then ok "$out"; else echo "$out"; bad "tools/remedies.json"; fi
  # checkrec.py's docstring reworded so its kinds cannot be found: a sentence, not a traceback
  rk=$(mktemp -d "${TMPDIR:-/tmp}/vh-rk.XXXXXX"); sed 's/^  kind      /  kinds:    /' tools/checkrec.py > "$rk/checkrec.py"; cp tools/commands.json "$rk/"
  out=$(python3 -c 'import pathlib, sys; sys.path.insert(0, "tools"); import remedies; remedies.HERE = pathlib.Path(sys.argv[1]); print("\n".join(remedies.check()))' "$rk" 2>&1)
  case "$out" in *"its docstring has no"*) ok "tools/remedies.py: a checkrec.py docstring it cannot read is said in a sentence" ;;
    *) bad "tools/remedies.py on a reworded docstring: $out" ;; esac
  rm -rf "$rk"
  # the table of outside modules (tools/modules.json): its own rules (commands that exist, adapters in the repo, keys as
  # variable names, probes over https with the key in a header), and its HyperFrames pin the one bin/vh and styles/_swatch install
  if out=$(python3 tools/doctor.py --check 2>&1) && python3 - <<'PY'
import json, re, sys
pins = set(re.findall(r"\$\{HYPERFRAMES_VERSION:-([0-9][0-9.]*)\}", open("bin/vh", encoding="utf-8").read()))
swatch = json.load(open("styles/_swatch/package.json", encoding="utf-8"))["devDependencies"]["hyperframes"]
mods = json.load(open("tools/modules.json", encoding="utf-8"))["modules"]
table = next(m for m in mods if m["name"] == "hyperframes")["version"]["pin"]
if not pins == {swatch} == {table}:
    sys.exit(f"HyperFrames pins differ: bin/vh {sorted(pins)}, styles/_swatch/package.json {swatch}, tools/modules.json {table}")
reg = next(m for m in mods if m["name"] == "hyperframes-registry")["probe"]["url"]
if f"/v{table}/registry/" not in reg:
    sys.exit(f"tools/modules.json: hyperframes-registry probes {reg}, not the registry of the pinned v{table}")
PY
  then ok "$out: each with a purpose, version, licence, needs, adapters in the repo and real commands; the HyperFrames pin is bin/vh's, styles/_swatch's and the registry probe's"
  else echo "$out"; bad "tools/modules.json"; fi
  # every `bin/vh <command>` in the docs exists; the table names exactly the commands bin/vh dispatches, and CLAUDE.md's
  # 命令行 line is the table's (bin/vh sync-agents writes it)
  if python3 - <<'PY'
import json, re, subprocess, sys
src = open("bin/vh", encoding="utf-8").read()
block = src[src.index('case "${1:-help}" in'):]
block = block[:block.index("\nesac")]
cmds = {c for pat in re.findall(r"(?:^|;;)\s*([a-z0-9|-]+)\)", block, re.M) for c in pat.split("|") if c and not c.startswith("-")}
cmds.discard("help")
table = {c.get("name") for c in json.load(open("tools/commands.json", encoding="utf-8")).get("commands", [])}
bad = []
if table != cmds:
    bad.append(f"tools/commands.json vs bin/vh dispatch: not in the table {sorted(cmds - table)}, not dispatched {sorted(table - cmds)}")
line = re.search(r"命令行：(.+)", open("CLAUDE.md", encoding="utf-8").read()).group(1)
want = subprocess.run([sys.executable, "tools/commands.py", "claude-line"], capture_output=True, text=True).stdout.strip()
if line != want:
    bad.append(f"CLAUDE.md's 命令行 line is not tools/commands.json's (bin/vh sync-agents writes it): {line!r} vs {want!r}")
docs = subprocess.run(["git", "ls-files", "*.md"], capture_output=True, text=True).stdout.split()
for d in docs:   # commands written as code: inside `backticks` or a fenced block (prose like "bin/vh · QA tools" is a label)
    if d.startswith("references/") or d == "CHANGELOG.md":
        continue
    fence = False
    for n, line in enumerate(open(d, encoding="utf-8"), 1):
        if line.lstrip().startswith("```"):
            fence = not fence; continue
        for code in [line] if fence else re.findall(r"`([^`]*)`", line):
            for c in re.findall(r"bin/vh ([a-z][a-z0-9-]*)", code):
                if c not in cmds and c != "help":
                    bad.append(f"{d}:{n}: bin/vh {c} is not a command")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
  then ok "docs name only real bin/vh commands; tools/commands.json and CLAUDE.md's 命令行 line name the ones bin/vh dispatches"; else bad "docs vs bin/vh commands"; fi
  # the front pages (tools/readme.py): every count the READMEs and the overview diagrams state is the repo's (commands,
  # styles, recipes …), their links and images are in the repo, and the two READMEs have the same sections and links
  if out=$(python3 tools/readme.py check 2>&1); then ok "$out"; else echo "$out"; bad "the READMEs against the repo (python3 tools/readme.py lists the counts)"; fi
  # the research notes (docs/research): each in both languages, the two with as many sections (## and ###), table rows and
  # figures, and as many list items in each ## section; both indexes list every note, in the same order, and nothing
  # that is not one
  if out=$(python3 - <<'PY'
import re, sys
from pathlib import Path
R = Path("docs/research")
def text(p):
    return re.sub(r"^```.*?^```", "", p.read_text(encoding="utf-8"), flags=re.S | re.M)
def shape(s):
    return {"## sections": len(re.findall(r"^## ", s, re.M)), "### sections": len(re.findall(r"^### ", s, re.M)),
            "table rows": len(re.findall(r"^\|.*\|\s*$", s, re.M)), "figures": len(re.findall(r"!\[[^\]]*\]\(", s))}
def items(s):   # each ## section's heading and its list items (- * + or 1., nested ones too)
    out = []
    for line in s.splitlines():
        if line.startswith("## "):
            out.append([line[3:].strip(), 0])
        elif out and re.match(r"\s*(?:[-*+]|\d+\.) ", line):
            out[-1][1] += 1
    return out
zh = sorted(p.name for p in R.glob("[0-9][0-9]-*.md")); en = sorted(p.name for p in (R / "en").glob("[0-9][0-9]-*.md"))
bad = [f"{n}: no en/ twin" for n in sorted(set(zh) - set(en))] + [f"en/{n}: no Chinese one" for n in sorted(set(en) - set(zh))]
for n in sorted(set(zh) & set(en)):
    ta, tb = text(R / n), text(R / "en" / n)
    a, b = shape(ta), shape(tb)
    bad += [f"{n}: {k} {a[k]} here, {b[k]} in en/" for k in a if a[k] != b[k]]
    if a["## sections"] == b["## sections"]:
        bad += [f"{n}: list items in ## {x[0]}, {x[1]} here, {y[1]} in en/ (## {y[0]})" for x, y in zip(items(ta), items(tb)) if x[1] != y[1]]
for f in (R / "README.md", R / "en" / "README.md"):
    rows = re.findall(r"^\| (\d\d) \| \[[^\]]*\]\(([^)]+)\) \|", f.read_text(encoding="utf-8"), re.M)
    linked = [p for _, p in rows]
    bad += [f"{f}: the row {k} links {p}" for k, p in rows if not p.startswith(k + "-")]
    missing, extra = [n for n in zh if n not in linked], [p for p in linked if p not in zh]
    if missing or extra:
        bad.append(f"{f}: its index" + (f" leaves out {', '.join(missing)}" if missing else "") + (" and" if missing and extra else "")
                   + (f" lists {', '.join(extra)}, which no note is" if extra else ""))
    elif linked != zh:
        bad.append(f"{f}: its index is not one row a note in the notes' order")
print("; ".join(bad) or f"{len(zh)} notes, each in both languages with the same sections, table rows, figures and list items a section; both indexes list them all")
sys.exit(1 if bad else 0)
PY
  ); then ok "docs/research: $out"; else bad "docs/research: $out"; fi
  # the group table (tools/ci-shards.txt): a group and its seconds a line, each group once and a function here; a group
  # function (named *_checks or *_report) that is not in it is called by one that is (or it would run in no run and no
  # shard)
  local g a="" b="" c="" d e r1 r2 r3 r4
  a=$(groups | awk 'NF != 2 || $2 !~ /^[0-9]+$/ || seen[$1]++ { printf " %s", $0 }')
  for g in $(groups | awk '{ print $1 }'); do declare -F "$g" >/dev/null || b="$b $g"; done
  for g in $(sed -n -E 's/^([a-z0-9_]+_(checks|report))\(\) \{.*/\1/p' tools/ci.sh); do
    groups | awk -v g="$g" '$1 == g { f = 1 } END { exit !f }' || grep -q -E "^[[:space:]]+$g([[:space:];]|\$)" tools/ci.sh || c="$c $g"
  done
  if [ -z "$a$b$c" ]; then ok "tools/ci-shards.txt: each group once with its seconds, each a function in tools/ci.sh; every *_checks and *_report function runs"
  else bad "tools/ci-shards.txt:${a:+ (lines that are not one group and its whole seconds, once:$a)}${b:+ (no such function:$b)}${c:+ (never run:$c)}"; fi
  # a table that leaves nothing to run (empty, gone) stops tools/ci.sh with exit 2, never "all checks passed"; a group
  # that is no function fails the run
  d=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX"); : > "$d/empty.txt"; printf 'readpath_report 0\nno_such_checks 1\n' > "$d/bogus.txt"
  seq 1 256 | sed 's/.*/no_such_checks_& 1/' > "$d/many.txt"   # 256 failures: an exit status of 256 % 256 = 0 was a pass
  a=$(OVH_CI_SHARDS="$d/empty.txt" tools/ci.sh 2>&1); r1=$?
  b=$(OVH_CI_SHARDS="$d/gone.txt" tools/ci.sh --shard 1/2 2>&1); r2=$?
  c=$(OVH_CI_SHARDS="$d/bogus.txt" tools/ci.sh --shard 1/1 2>&1); r3=$?
  e=$(OVH_CI_SHARDS="$d/many.txt" tools/ci.sh 2>&1); r4=$?
  rm -rf "$d"
  if [ "$r1:$r2:$r3:$r4" = 2:2:1:1 ] && grep -q 'no groups to run' <<<"$a" && grep -q 'no groups to run' <<<"$b" \
     && grep -q 'names no_such_checks, which is no function' <<<"$c" && grep -q '256 check(s) failed' <<<"$e" && ! grep -q 'all checks passed' <<<"$a$b$c$e"
  then ok "tools/ci.sh: an empty table and none stop it (exit 2: no groups to run); a group that is no function fails the run (exit 1), and so do 256 (exit 1, not 256 % 256)"
  else bad "tools/ci.sh on broken tables (empty: exit $r1, gone: exit $r2, a group that is no function: exit $r3, 256 of them: exit $r4): $(printf '%s | %s | %s | %s' "$a" "$b" "$c" "$e" | tail -c 400)"; fi
  # no headless Chrome for the page tools, or no WebGL2 for the Three.js layer: a skip here, a failure on CI (CI=true),
  # where a skip would pass a run that drew nothing
  a=$( (CI=true; fails=0; no_chrome "a page group" >/dev/null; no_webgl "a Three.js check" >/dev/null; echo "$fails") )
  b=$( (CI=""; fails=0; skipped=""; no_chrome "a page group" >/dev/null; no_webgl "a Three.js check" >/dev/null; echo "$fails:$skipped") )
  if [ "$a|$b" = "2|0:a page group, a Three.js check" ]; then ok "no Chrome for the page tools, no WebGL for the Three.js layer: a skip on this machine, a failure on CI (CI=true)"
  else bad "no_chrome and no_webgl on CI and off it (failures, then failures:skipped): $a | $b"; fi
  # the workflow and the ruleset: each context the ruleset requires is the name of a job in ci.yml, and the job that
  # reports checks (macos-latest) runs whatever became of its shards (if: always(); a required check that is skipped
  # counts as passed)
  if a=$(python3 - <<'PY'
import json, re, sys
wf = open(".github/workflows/ci.yml", encoding="utf-8").read()
jobs, cur = {}, None
for line in wf[wf.index("\njobs:\n") + 7:].splitlines():
    m = re.match(r"^  ([A-Za-z0-9_-]+):\s*(#.*)?$", line)
    if m:
        cur = jobs.setdefault(m.group(1), {}); continue
    m = re.match(r"^    (name|if):\s*(.*?)\s*(#.*)?$", line)
    if m and cur is not None:
        cur[m.group(1)] = re.sub(r"^\$\{\{\s*(.*?)\s*\}\}$", r"\1", m.group(2))
names = {j.get("name"): j for j in jobs.values()}
rules = json.load(open(".github/rulesets/main.json", encoding="utf-8"))["rules"]
ctx = [c["context"] for r in rules if r["type"] == "required_status_checks" for c in r["parameters"]["required_status_checks"]]
bad = [f"the ruleset requires {c!r}, and no job in ci.yml is named so" for c in ctx if c not in names]
mac = names.get("checks (macos-latest)")
if mac is not None and mac.get("if") != "always()":
    bad.append(f"checks (macos-latest) runs with if: {mac.get('if')!r}, not always()")
print("; ".join(bad) or f"the ruleset's {len(ctx)} required checks are jobs of ci.yml, and checks (macos-latest) runs always()")
sys.exit(1 if bad or not ctx else 0)
PY
  ); then ok "$a"; else bad "workflow and ruleset: $a"; fi
}

readpath_report() {   # how much an agent reads before it starts, per effort level and type: printed as a baseline, no limit yet
  local out
  if out=$(python3 tools/readpath.py 2>&1); then printf '%s\n' "$out" | sed 's/^/  /'; ok "read path printed above (a baseline; no limit yet)"
  else echo "$out"; bad "tools/readpath.py"; fi
}

vh() { "$VH_BASH" "$ROOT/bin/vh" "$@"; }
smoke_checks() {
  local slug="ci-smoke-$$" dir t rc langs a h o u ad
  vh help >/dev/null && vh --help >/dev/null && ok "bin/vh help exits 0" || bad "bin/vh help"
  vh no-such-command >/dev/null 2>&1; rc=$?; [ $rc = 2 ] && ok "unknown command exits 2 (a usage error)" || bad "unknown command exited $rc"
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")   # a throwaway HOME: an old bin/vh would install the skill for a bad target
  HOME="$t" vh install-skill no-such-target >/dev/null 2>&1; rc=$?; [ $rc = 2 ] && ok "install-skill rejects unknown targets" || bad "install-skill bad target exited $rc"
  rm -rf "$t"
  vh types >/dev/null && vh effort quick >/dev/null && vh style list >/dev/null && ok "types · effort · style list" || bad "types / effort / style list"
  # effort: the table comes from playbook/01, the caps and the floors from CLAUDE.md (a renamed heading must not drop them)
  a=$(vh effort studio 2>&1)
  case "$a" in *"独立评审"*"评审有上限"*"任何档位都不降"*"bin/vh check"*) ok "effort studio prints its column, the review caps and the floors" ;;
    *) bad "effort studio: table, caps or floors missing" ;; esac
  # -h prints a usage and exits 0 without running the command (setup -h used to install everything, sync-agents -h rewrote
  # AGENTS.md, and others took -h as a video, project or preset name). Every dispatched command without a help of its own
  # is tried, on a copy of bin/vh whose ROOT has only tools/ and with uv and npm stubbed out: if the check ever broke, setup
  # would stop at its first cd and nothing would be downloaded
  local cmds n
  cmds=$(python3 - <<'PY'
import re, sys
src = open("bin/vh", encoding="utf-8").read()
block = src[src.index('case "${1:-help}" in'):]
block = block[:block.index("\nesac")]
cmds = {c for pat in re.findall(r"(?:^|;;)\s*([a-z0-9|-]+)\)", block, re.M) for c in pat.split("|") if c and not c.startswith("-")} - {"help"}
own = set(re.search(r'case "\$1" in ([a-z0-9|-]+)\) ;;   # these print their own', src).group(1).split("|"))
if own - cmds: sys.exit(f"own-help list names commands bin/vh does not dispatch: {sorted(own - cmds)}")
print(" ".join(sorted(cmds - own)))
PY
) || bad "bin/vh's own-help list"
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX"); mkdir "$t/bin" "$t/stub"; cp bin/vh "$t/bin/vh"; ln -s "$ROOT/tools" "$t/tools"
  printf '#!/bin/sh\nexit 1\n' > "$t/stub/uv"; cp "$t/stub/uv" "$t/stub/npm"; chmod +x "$t/stub/uv" "$t/stub/npm"
  rc=0; for a in $cmds "style check"; do
    for h in -h --help; do
      # shellcheck disable=SC2086   # "style check" is two words on purpose
      o=$(HOME="$t" PATH="$t/stub:$PATH" "$VH_BASH" "$t/bin/vh" $a "$h" 2>&1) && case "$o" in "usage: bin/vh $a "*|"usage: bin/vh $a"|"usage: bin/vh $a"$'\n'*) continue ;; esac
      bad "bin/vh $a $h: '$(printf '%s' "$o" | head -1)'"; rc=1
    done
  done; rm -rf "$t"
  n=$(printf '%s\n' $cmds | grep -c .)
  if [ $rc = 1 ]; then :; elif [ "$n" -gt 5 ]; then ok "-h and --help print a usage for the $n commands without a help of their own, and style check"
  else bad "only $n commands found in bin/vh's dispatch for the -h check"; fi
  # the help is printed from tools/commands.json: bin/vh -h has a usage for every command there, bin/vh commands lists
  # each one once (--stage: a stage's, by its id or a part of its name, those listed under it first), --json the same in
  # the same order; a stage or an option it does not know is a usage error (2, stderr only), and so is a mistyped command,
  # with the nearest names. sync-agents, on a copy, writes CLAUDE.md's 命令行 line from the table, then AGENTS.md
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX"); mkdir "$t/bin"; cp bin/vh "$t/bin/vh"; ln -s "$ROOT/tools" "$t/tools"
  if python3 - "$VH_BASH" "$t" <<'PY'
import json, re, subprocess, sys
sh, t = sys.argv[1:3]
vh = lambda *a, bin="bin/vh": subprocess.run([sh, bin, *a], capture_output=True, text=True)
names = [c["name"] for c in json.load(open("tools/commands.json", encoding="utf-8"))["commands"]]
bad = []
h = vh("-h")
miss = [n for n in names if not re.search(rf"^  {re.escape(n)}( |$)", h.stdout, re.M)]
if h.returncode or miss:
    bad.append(f"bin/vh -h (exit {h.returncode}) has no usage for {miss}")
listed = re.findall(r"^  ([a-z][a-z0-9-]*) ", vh("commands").stdout, re.M)
if sorted(listed) != sorted(names):
    bad.append(f"bin/vh commands lists {len(listed)} of the {len(names)} commands, or one twice")
j = json.loads(vh("commands", "--json").stdout)
if j.get("version") != 1 or [c["name"] for c in j["commands"]] != listed:
    bad.append("bin/vh commands --json is not the list's commands in its order")
keys = {"name", "summary", "when", "stages", "reads", "writes", "usage"}
if any(not keys <= set(c) for c in j["commands"]) or any(set(s) - {"id", "name", "note"} for s in j["stages"]):
    bad.append("bin/vh commands --json lacks a field or has an unknown one")
a, b = vh("commands", "--stage", "4", "--json").stdout, vh("commands", "--stage=时间", "--json").stdout
if a != b or json.loads(a).get("stage") != "4":
    bad.append("bin/vh commands: --stage 4 and --stage=时间 differ")
s3 = [c["name"] for c in json.loads(vh("commands", "--stage", "3", "--json").stdout)["commands"]]
if s3[:3] != ["recipes", "storyboard", "rhythm"] or "gate" not in s3:
    bad.append(f"bin/vh commands --stage 3: {s3}")
for args in (["--stage", "nope"], ["--stage"], ["--stage", "e"], ["--bogus"]):   # "e": Brief and Review, two stages
    r = vh("commands", *args)
    if r.returncode != 2 or r.stdout or not r.stderr:
        bad.append(f"bin/vh commands {' '.join(args)}: exit {r.returncode}, stdout {r.stdout[:40]!r}")
r = vh("comands")
if r.returncode != 2 or r.stdout or "did you mean commands" not in r.stderr:
    bad.append(f"bin/vh comands: exit {r.returncode}, {r.stderr[:80]!r}")
c = open("CLAUDE.md", encoding="utf-8").read()
open(f"{t}/CLAUDE.md", "w", encoding="utf-8").write(re.sub(r"命令行：.*", "命令行：doctor · setup", c, count=1))
want = subprocess.run([sys.executable, "tools/commands.py", "claude-line"], capture_output=True, text=True).stdout.strip()
r = vh("sync-agents", bin=f"{t}/bin/vh")
got = open(f"{t}/CLAUDE.md", encoding="utf-8").read()
agents = open(f"{t}/AGENTS.md", encoding="utf-8").read() if r.returncode == 0 else "\n\n\n"
if r.returncode or got != c.replace(re.search(r"命令行：.*", c).group(0), "命令行：" + want) or agents.split("\n", 3)[3] != got:
    bad.append(f"sync-agents (exit {r.returncode}) did not write the 命令行 line from the table, or AGENTS.md from CLAUDE.md")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
  then ok "bin/vh -h has a usage for each command of tools/commands.json, bin/vh commands lists each once (--stage by id or name, --json in the same order); a bad stage or option is 2 on stderr, a mistyped command 2 with the nearest name; sync-agents writes CLAUDE.md's 命令行 line from the table"
  else bad "the help and bin/vh commands from tools/commands.json"; fi
  rm -rf "$t"
  # doctor reads tools/modules.json. In a sandbox (stub programs on the PATH, fake keys, empty caches): a node under the
  # minimum and an ffmpeg without libx264 and ffprobe are said, a dated yt-dlp far over its age is outdated, a key is set
  # or not and its value never shown. --probe --offline answers the services from recorded responses: a key taken (and
  # the models bin/vh uses listed), MiniMax's refusal with its hint, a 401 whose message echoes the key masked (only the
  # status and the error code are said, no run of six of the key's characters), no key skipped. Live against two servers
  # on this machine: a redirect is not followed (the second server hears nothing) and a base address over plain http to
  # another host is not called. A module not made for this platform says what to use instead; a needed module that is not
  # usable takes the one needing it off ok (needs.programs, also checked in the table). Without python3 on the PATH,
  # bin/vh doctor still says node, ffmpeg, uv, git and Chrome and exits 0. Usage errors exit 2 before any probe;
  # bin/vh doctor --json on this machine lists every module
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  if python3 - "$VH_BASH" "$t" <<'PY'
import json, os, shutil, subprocess, sys
sh, t = sys.argv[1:3]
stub, rec = os.path.join(t, "stub"), os.path.join(t, "rec")
os.makedirs(stub); os.makedirs(rec)
for name, body in (("node", "echo v18.19.0"), ("ffmpeg", "echo 'ffmpeg version 7.1 Copyright (c) the FFmpeg developers'"),
                   ("yt-dlp", "echo 2020.01.01"), ("uv", 'case "$1" in run) exit 1 ;; esac; echo "uv 0.9.0"')):
    with open(os.path.join(stub, name), "w") as f:
        f.write("#!/bin/sh\n" + body + "\n")
    os.chmod(os.path.join(stub, name), 0o755)
keys = {"GEMINI_API_KEY": "ciK7Hq2Zt9Lm4Wp8Rs3Vb6Xy0Jg", "MINIMAX_API_KEY": "ciQ1Wz5Nx8Pc3Kd7Lf2Hm6Gy4Tq",
        "DASHSCOPE_API_KEY": "ciT4Yb9Rg2Vs6Jn1Uk5Ep8Dw3Zc"}
env = {"PATH": stub, "HOME": t, "HF_HOME": os.path.join(t, "hf"), **keys}
doc = lambda *a: subprocess.run([sys.executable, "tools/doctor.py", *a], capture_output=True, text=True, encoding="utf-8", env=env)
bad, outs = [], []
j = doc("--json"); outs += [j.stdout, j.stderr]
d = json.loads(j.stdout)
m = {x["name"]: x for x in d["modules"]}
if list(m) != [x["name"] for x in json.load(open("tools/modules.json", encoding="utf-8"))["modules"]]:
    bad.append("doctor --json does not list the table's modules in its order")
want = {"node": "outdated", "ffmpeg": "incomplete", "yt-dlp": "outdated", "python-packages": "missing", "gemini": "ok",
        "minimax": "ok", "elevenlabs": "no_key", "chrome": "missing"}
got = {k: m[k]["state"] for k in want}
if got != want:
    bad.append(f"doctor's states: {got}")
if "22 or newer" not in m["node"]["note"] or "libx264" not in m["ffmpeg"]["note"] or "ffprobe" not in m["ffmpeg"]["note"] \
        or "days old" not in m["yt-dlp"]["note"] or m["yt-dlp"]["status"] != "used":
    bad.append(f"doctor's notes: {m['node']['note']!r}, {m['ffmpeg']['note']!r}, {m['yt-dlp']['note']!r}")
if m["gemini"]["keys"] != {"GEMINI_API_KEY": True} or m["elevenlabs"]["keys"] != {"ELEVENLABS_API_KEY": False} \
        or m["minimax"]["keys"] != {"MINIMAX_TOKEN_PLAN_KEY": False, "MINIMAX_API_KEY": True}:
    bad.append("doctor's keys are not set / not set as given")
if next(c for c in d["checks"] if c["name"] == "browser")["state"] != "missing" or any(x["probe"] for x in d["modules"]):
    bad.append("no browser was found, and nothing is probed without --probe")
txt = doc(); outs += [txt.stdout, txt.stderr]
if txt.returncode or "\033[31m✗\033[0m node  18.19.0" not in txt.stdout:
    bad.append(f"doctor's text: exit {txt.returncode}, no ✗ for the old node")
bodies = {"gemini.json": {"models": [{"name": "models/" + n} for n in ("gemini-3.8-flash-tts", "gemini-3.8-flash-lite-tts", "gemini-3.5-transcribe",
                                                                       "gemini-nano-banana-2.1", "gemini-3-pro-image", "lyria-3.5")]},
          "minimax.json": {"base_resp": {"status_code": 1004, "status_msg": "login fail"}},
          "dashscope.json": {"error": {"message": "Incorrect API key provided: " + keys["DASHSCOPE_API_KEY"][:9] + "**********"
                                       + keys["DASHSCOPE_API_KEY"][-6:], "code": "invalid_api_key"}}}
for n, b in bodies.items():
    json.dump(b, open(os.path.join(rec, n), "w"))
json.dump({"v": 1, "responses": [
    {"url": "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000", "status": 200, "headers": {}, "body": "gemini.json"},
    {"url": "https://api.minimax.io/v1/get_voice", "status": 200, "headers": {}, "body": "minimax.json"},
    {"url": "https://dashscope.aliyuncs.com/compatible-mode/v1/models", "status": 401, "headers": {}, "body": "dashscope.json"}]},
    open(os.path.join(rec, "responses.json"), "w"))
p = doc("--json", "--probe", "--offline", rec); outs += [p.stdout, p.stderr]
pr = {x["name"]: x["probe"] for x in json.loads(p.stdout)["modules"] if x["probe"]}
if pr.get("gemini", {}).get("state") != "ok" or "6 models" not in pr["gemini"]["note"] \
        or pr.get("minimax", {}).get("state") != "failed" or "1004" not in pr["minimax"]["note"] or "MINIMAX_BASE_URL" not in pr["minimax"]["note"] \
        or pr.get("dashscope", {}).get("state") != "failed" or "HTTP 401 with DASHSCOPE_API_KEY (invalid_api_key)" != pr["dashscope"]["note"] \
        or pr.get("elevenlabs", {}).get("state") != "skipped":
    bad.append(f"doctor --probe from recordings: {pr}")
pt = doc("--probe", "--offline", rec); outs += [pt.stdout, pt.stderr]
import http.server, threading
sys.path.insert(0, "tools/assets")
from fetch import LocalServer   # (http.server's own bind, which asks socket.getfqdn, stalled 35 s on GitHub's macOS runners)
heard = []
class Next(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        heard.append(dict(self.headers)); self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
    do_GET = do_POST
    def log_message(self, *a):
        pass
class First(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.send_response(302); self.send_header("Location", f"http://127.0.0.1:{nxt.server_address[1]}/v1/get_voice"); self.end_headers()
    do_GET = do_POST
    def log_message(self, *a):
        pass
nxt, first = LocalServer(("127.0.0.1", 0), Next), LocalServer(("127.0.0.1", 0), First)
for srv in (nxt, first):
    threading.Thread(target=srv.serve_forever, daemon=True).start()
live = subprocess.run([sys.executable, "tools/doctor.py", "--json", "--probe", "--only", "minimax,dashscope"], capture_output=True, text=True, encoding="utf-8",
                      env={"PATH": stub, "HOME": t, "HF_HOME": os.path.join(t, "hf"), "MINIMAX_API_KEY": keys["MINIMAX_API_KEY"],
                           "MINIMAX_BASE_URL": f"http://127.0.0.1:{first.server_address[1]}", "DASHSCOPE_API_KEY": keys["DASHSCOPE_API_KEY"],
                           "DASHSCOPE_BASE_URL": "http://example.invalid/api/v1"})
outs += [live.stdout, live.stderr]
for srv in (nxt, first):
    srv.shutdown()
lp = {x["name"]: x["probe"] for x in json.loads(live.stdout)["modules"] if x["probe"]}
if lp["minimax"]["state"] != "failed" or f"127.0.0.1:{nxt.server_address[1]}" not in lp["minimax"]["note"] or "not followed" not in lp["minimax"]["note"] or heard:
    bad.append(f"a redirect: {lp['minimax']}, the next host heard {len(heard)} request(s)")
if lp["dashscope"]["state"] != "failed" or "not an https address" not in lp["dashscope"]["note"]:
    bad.append(f"an http base address: {lp['dashscope']}")
if any(v[i:i + 6] in o for v in keys.values() for i in range(len(v) - 5) for o in outs):
    bad.append("six or more of a key's characters are in doctor's output")
sys.path.insert(0, "tools")
import datetime, doctor
table = json.load(open("tools/modules.json", encoding="utf-8"))
mod = {x["name"]: x for x in table["modules"]}
doctor.this_platform = lambda: "linux-x86_64"
q = doctor.check_module(mod["qwen3-tts"], {}, datetime.date.today())
if q["state"] != "unsupported" or "edge, gemini, minimax, dashscope or elevenlabs" not in q["note"]:
    bad.append(f"qwen3-tts off Apple Silicon: {q}")
fake = [{"name": "a"}, {"name": "b", "needs": {"programs": ["a"]}}, {"name": "c", "needs": {"programs": ["b"]}}]
res = doctor.apply_needs(fake, [{"state": "outdated", "note": ""}, {"state": "ok", "note": ""}, {"state": "ok", "note": "x"}])
if [r["state"] for r in res] != ["outdated", "incomplete", "incomplete"] or res[1]["note"] != "needs a (outdated)" or res[2]["note"] != "x · needs b (incomplete)":
    bad.append(f"needs.programs: {res}")
mod["hyperframes"]["needs"]["programs"].append("no-such-module")
if not any("no-such-module" in b for b in doctor.problems(table)):
    bad.append("the table's rules take a needs.programs that names no module")
bare = os.path.join(t, "bare")
os.makedirs(bare)
for d in ("/bin", "/usr/bin"):
    for n in sorted(os.listdir(d)):
        if not n.startswith("python") and not os.path.lexists(os.path.join(bare, n)):
            os.symlink(os.path.join(d, n), os.path.join(bare, n))
shell = shutil.which(sh) if os.sep not in sh else sh
for args in ([], ["--json"]):
    r = subprocess.run([shell, "bin/vh", "doctor", *args], capture_output=True, text=True, encoding="utf-8", env={"PATH": stub + os.pathsep + bare, "HOME": t})
    ok_ = r.returncode == 0 and (json.loads(r.stdout)["modules"][1] == {"name": "node", "state": "outdated", "note": "v18.19.0 (22 or newer needed)"} if args
                                 else all(w in r.stdout for w in ("python3  not found", "node  v18.19.0 (22 or newer needed)", "ffmpeg", "uv  uv 0.9.0", "git", "chrome", "needs python3")))
    if not ok_:
        bad.append(f"doctor {' '.join(args)} without python3: exit {r.returncode}, {r.stdout[:300]!r} {r.stderr[-200:]!r}")
for args, via in ((["--bogus"], "bin/vh"), (["--offline", rec], "bin/vh"), (["--probe", "--offline", os.path.join(t, "none")], "doctor.py")):
    r = subprocess.run([sh, "bin/vh", "doctor", *args] if via == "bin/vh" else [sys.executable, "tools/doctor.py", *args],
                       capture_output=True, text=True, encoding="utf-8")
    if r.returncode != 2 or r.stdout or not r.stderr:
        bad.append(f"doctor {' '.join(args)}: exit {r.returncode}")
r = subprocess.run([sh, "bin/vh", "doctor", "--json"], capture_output=True, text=True, encoding="utf-8")
try:
    here = [x["name"] for x in json.loads(r.stdout)["modules"]]
except ValueError:
    here = None
if r.returncode or here != list(m):
    bad.append(f"bin/vh doctor --json on this machine: exit {r.returncode}, {r.stderr[-200:]!r}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
  then ok "doctor from tools/modules.json: an old node, an ffmpeg without libx264, an aged yt-dlp and keys set or not are said, no six of a key's characters ever; --probe: a key taken, MiniMax's refusal, a 401 echoing a masked key (status and code only), no key skipped, a redirect not followed, an http base elsewhere not called; the platform's alternative; needs.programs; no python3 still reports and exits 0; usage errors 2 before any probe; bin/vh doctor --json here lists every module"
  else bad "bin/vh doctor and tools/modules.json"; fi
  rm -rf "$t"
  # ManimGX, an optional backend for Manim scenes (tools/modules.json; CI does not install it): doctor lists it, and with
  # no manimgx on the PATH says it is missing and how to install it (a uv tool, Python 3.13, the pinned version); a
  # manimgx that says another version is told apart from the pin, the pinned one is ok while uv and ffmpeg (what it
  # needs) are there, and not while they are not. Stand-ins on a PATH of their own: the machine's own do not count
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  if python3 - "$t" <<'PY'
import json, os, subprocess, sys
t = sys.argv[1]
stub = os.path.join(t, "stub"); os.makedirs(stub)
def gx():
    r = subprocess.run([sys.executable, "tools/doctor.py", "--json"], capture_output=True, text=True, encoding="utf-8", env={"PATH": stub, "HOME": t})
    return {m["name"]: m for m in json.loads(r.stdout)["modules"]}["manimgx"]
def put(name, body):
    f = os.path.join(stub, name)
    open(f, "w").write("#!/bin/sh\n" + body + "\n"); os.chmod(f, 0o755)
m = gx()
ok = m["state"] == "missing" and not m["required"] and "uv tool install --python 3.13 manimgx==0.1.1" in (m["install"] or "")
put("manimgx", "echo 'manimgx 0.1.1'"); m1 = gx()   # no uv, no ffmpeg
put("uv", "echo 'uv 0.9.0'"); put("ffprobe", "echo 'ffprobe version 7.1'")
put("ffmpeg", 'case "$1" in -version) echo "ffmpeg version 7.1" ;; *) echo " V....D libx264  libx264 H.264" ;; esac')
put("manimgx", "echo 'manimgx 0.1.0'"); m2 = gx()
put("manimgx", "echo 'manimgx 0.1.1'"); m3 = gx()
ok = ok and m1["state"] == "incomplete" and "needs uv" in m1["note"] and "needs ffmpeg" in m1["note"]
ok = ok and m2["state"] == "outdated" and "0.1.1" in m2["note"] and m3["state"] == "ok" and m3["version"] == "0.1.1"
sys.exit(0 if ok else 1)
PY
  then ok "doctor: ManimGX (an optional Manim backend) is missing here and says how to install it; another version than the pinned one is told apart; the pinned one wants uv and ffmpeg"
  else bad "doctor's ManimGX entry"; fi
  rm -rf "$t"
  # usage errors exit 2, failures 1: these commands with no arguments or a wrong one (new with an option that has no
  # value included; a project, video or folder that is not there); new into a folder that is there already is a failure.
  # Every message of a usage error or a refusal is on stderr and stdout stays empty; the usage that was asked for (-h)
  # is on stdout, exit 0. Nothing here reaches uv or a browser; a project that is not there is not made (tts did)
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX"); a=""; u=""; mkdir "$t/empty"; : > "$t/v.mp4"; : > "$t/a.wav"; cp -R tools/assets/fixtures/project "$t/fx"
  for c in deliver clean timeline remap timemap storyboard rhythm cover-preview "style compare" "style apply" "style apply dark-math" \
           "style apply no-such $t" "effort loud" new "new math" "new nope ci-x" "new math ci-x --style" "new math ci-x --effort" \
           "new math ci-x --lang" "new math ci-x --bogus" "new math ci-x --style no-such" versions proxy thumbs \
           textcheck fonts "fonts nope" frames render determinism cues patch activity status gate desk \
           tts "tts $t/no-such" sheet "sheet $t/no-such.mp4" gif "gif $t/no-such.mp4" hf-init "hf-init $t/no-such" "hf-init $t/empty 4k" "hf-init $t/empty 2:3" \
           check "check --bogus" "check $t/no-such.mp4 --bogus" "check $t/no-such.mp4 --allow" "check $t/no-such.mp4 --against" "check $t/no-such.mp4 --against $t/no-such-ref.mp4" \
           "check $t/no-such.mp4" "check $t/no-such.mp4 --json" \
           captions "captions $t/empty --media-end" "captions $t/empty --cps" "captions $t/empty --en-max" "captions $t/empty --bogus" \
           "captions $t/no-such" "captions $t/empty" "captions $t/empty zh" mix "style check" \
           "mux $t/no-such.mp4 $t/no-such.wav $t/o.mp4" "mux $t/v.mp4 $t/a.wav $t/no-dir/o.mp4" \
           assets "assets no-such" "assets list $t/no-such" "assets check $t/empty" "assets add" "assets add $t/no-such $t/v.mp4" "assets credits" \
           "assets remove $t/fx no-such-id" "assets add $t/fx $t/no-such.png" "assets add $t/fx $t/v.mp4 --class nope" "assets check $t/fx --policy loose"; do
    # shellcheck disable=SC2086   # several words on purpose
    OVH_PROJECTS="$t" vh $c >"$t/out" 2>"$t/err"; rc=$?
    [ $rc = 2 ] || a="$a | $c exited $rc"
    { [ ! -s "$t/out" ] && [ -s "$t/err" ]; } || u="$u | $c"
  done
  OVH_PROJECTS="$t" vh new math ci-twice >/dev/null 2>&1; OVH_PROJECTS="$t" vh new math ci-twice >"$t/out" 2>"$t/err"; rc=$?
  { [ ! -s "$t/out" ] && [ -s "$t/err" ]; } || u="$u | new over a project"
  for c in deliver new effort tts sheet gif hf-init status clean "style apply" "style apply dark-math" "new math" "new math ci-h" "new math ci-h --style dark-math" \
           assets "assets add" "assets check"; do
    for h in -h --help; do
      # shellcheck disable=SC2086   # several words on purpose
      OVH_PROJECTS="$t" vh $c $h >"$t/out" 2>"$t/err"; rc2=$?
      { [ $rc2 = 0 ] && [ -s "$t/out" ] && [ ! -s "$t/err" ]; } || u="$u | $c $h"
    done
  done
  [ -z "$(ls -d "$t"/*-ci-h "$t"/*--h "$t"/*---help 2>/dev/null)" ] || u="$u | new -h made a folder"
  [ -z "$a" ] && [ $rc = 1 ] && [ -z "$(ls -d "$t"/*-ci-x 2>/dev/null)" ] && [ ! -e "$t/no-such" ] \
    && ok "usage errors exit 2 (new, effort, style, deliver, clean, timeline, remap, timemap, storyboard, rhythm, cover-preview, versions, proxy, thumbs, textcheck, fonts, frames, render, determinism, cues, patch, activity, status, gate, desk, tts, sheet, gif, hf-init, check, captions, mix, mux, assets: no arguments, an option where the video goes or with no value, a project, video, timeline, input or output folder that is not there, a frame it does not know); new over a project is 1" \
    || bad "usage errors:$a (new twice exited $rc; a project made: $(ls -d "$t"/no-such 2>/dev/null))"
  [ -z "$u" ] && ok "usage errors and refusals are on stderr with nothing on stdout, the usage that was asked for (-h) on stdout with exit 0" \
    || bad "messages on the wrong stream:$u"
  # arg_dir finds the project among a page tool's arguments, to pick the browser it renders with and the project render's
  # gate check reads: a flag that takes no value in front of it must not swallow it (frames --covers, --no-title and cues
  # --chapters took the project for their value and found "."; render --alpha and --fresh too, until arg_dir had them). The
  # flags are read out of the tools' own parsers: each branch of an option loop that takes no value (frames, render,
  # determinism, cues, fonts check, patch, textcheck), argparse's flags with no value (readcheck, storyboard, rhythm) and
  # thumbs' (tools/proxy.py), so a flag a tool gains fails here until arg_dir has it; none may take a value in another of
  # them. A flag with a value still hides its value (--out o <project>). The function is read out of bin/vh
  mkdir "$t/proj"; a=""
  ad=$(awk '/^arg_dir\(\) \{/,/^\}/' bin/vh)
  if bare=$(python3 - <<'PY'
import ast, re, sys
from pathlib import Path
bare, valued = {}, {}
for f in ["tools/film/frames.mjs", "tools/film/render.mjs", "tools/film/determinism.mjs", "tools/film/cues.mjs", "tools/film/fonts.mjs",
          "tools/film/patch.mjs", "tools/textcheck/textcheck.mjs"]:
    for line in Path(f).read_text(encoding="utf-8").splitlines():
        if re.match(r"\s*(?:else )?if \((?:k|a) === \"--", line):
            for n in re.findall(r"\b(?:k|a) === \"(--[\w-]+)\"", line):
                (valued if re.search(r"\b(?:val|next)\(\)", line) else bare).setdefault(n, set()).add(f)
for f in ["tools/readcheck.py", "tools/storyboard.py", "tools/rhythm.py"]:
    for c in ast.walk(ast.parse(Path(f).read_text(encoding="utf-8"))):
        if isinstance(c, ast.Call) and getattr(c.func, "attr", "") == "add_argument" and c.args and isinstance(c.args[0], ast.Constant) and str(c.args[0].value).startswith("--"):
            act = next((k.value.value for k in c.keywords if k.arg == "action" and isinstance(k.value, ast.Constant)), None)
            (bare if act in ("store_true", "store_false", "store_const", "count") else valued).setdefault(c.args[0].value, set()).add(f)
for n in re.findall(r"\bx == \"(--[\w-]+)\"", Path("tools/proxy.py").read_text(encoding="utf-8")):
    bare.setdefault(n, set()).add("tools/proxy.py")
both = sorted(set(bare) & set(valued))
if both:
    sys.exit(print("flags with a value in one tool and none in another: " + ", ".join(n + " (" + " ".join(sorted(bare[n] | valued[n])) + ")" for n in both)) or 1)
if len(bare) < 15:
    sys.exit(print("only %d flags without a value found in the parsers of these tools: are they written another way now?" % len(bare)) or 1)
print(" ".join(sorted(bare)))
PY
  ); then
    # shellcheck disable=SC2086
    for c in $bare -h --help --covers=A,B --out=o; do
      o=$("$VH_BASH" -c "$ad"$'\n''arg_dir "$@"' _ "$c" "$t/proj"); [ "$o" = "$t/proj" ] || a="$a | $c gave '$o'"
    done
  else a=" $bare"; fi
  for c in --out --at --range --strip --ratios --fps --browser --runtime --note --shot --texts; do
    o=$("$VH_BASH" -c "$ad"$'\n''arg_dir "$@"' _ "$c" value --covers --no-title "$t/proj"); [ "$o" = "$t/proj" ] || a="$a | $c value gave '$o'"
  done
  o=$("$VH_BASH" -c "$ad"$'\n''arg_dir "$@"' _ --out o "$t/page.html"); [ "$o" = "$t" ] || a="$a | a page gave '$o'"
  [ -z "$a" ] && ok "arg_dir: a flag without a value in front of the project (--covers, --no-title, --chapters …) does not hide it; one with a value hides only its value" \
    || bad "arg_dir:$a"
  rm -rf "$t"
  # a project: effort and style are written in, and the quick gate waiver is recorded
  dir=$(ls -d "$ROOT"/projects/*-"$slug" 2>/dev/null); [ -z "$dir" ] || rm -rf "$dir"
  if vh new math "$slug" --effort quick --style dark-math >/dev/null; then
    dir=$(ls -d "$ROOT"/projects/*-"$slug")
    grep -q '^- Effort: quick' "$dir/BRIEF.md" && grep -q 'Effort: quick' "$dir/REVIEW.md" && [ -f "$dir/style-refs/dark-math/STYLE.md" ] \
      && grep -q '^- Style refs (repo presets): `styles/dark-math`' "$dir/BRIEF.md" && ! grep -q '^## Style preset' "$dir/BRIEF.md" \
      && ok "bin/vh new --effort quick --style" || bad "bin/vh new: effort or style not written into the project"
    # the type doc is named, not pasted, and the marker tools/vhdraw.py reads for the type is there
    grep -q '^- Type doc: `video-types/01-math-science-explainer.md`' "$dir/BRIEF.md" && grep -q '^<!-- from 01-math-science-explainer.md -->$' "$dir/BRIEF.md" \
      && ! grep -q '^+ TYPE:' "$dir/BRIEF.md" && ok "bin/vh new names the type doc and keeps the type marker" || bad "bin/vh new: Type doc line or type marker missing"
    rm -rf "$dir"
  else bad "bin/vh new math"; fi
  # --engine canvas-film: the canvas engine's template instead of the type's engine (nothing to install), 16:9 for any type
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  if vh new short cf --engine canvas-film --dir "$t" >/dev/null; then
    dir=$(ls -d "$t"/*-cf)
    [ -f "$dir/film.html" ] && [ -f "$dir/src/50-shots.js" ] && [ -f "$dir/audio/timeline.zh.json" ] && [ -f "$dir/ENGINE_README.md" ] && [ ! -e "$dir/index.html" ] \
      && grep -q '^- Output: 1920x1080,' "$dir/BRIEF.md" && grep -q '^- Engine: canvas-film' "$dir/BRIEF.md" \
      && ok "bin/vh new --engine canvas-film copies the engine's template at 1920x1080" || bad "bin/vh new --engine canvas-film: the template or the BRIEF's Output and Engine lines are missing"
  else bad "bin/vh new short --engine canvas-film"; fi
  # doctor <project>: the copied engine against the engine now; an older copy (a module missing, a file edited, one of
  # its own) is listed with a diff command, and nothing in the project changes
  if [ -n "${dir:-}" ] && [ -d "$dir" ]; then
    a=$(vh doctor "$dir" 2>&1); rc=$?
    rm "$dir/src/06-time-map.js" && grep -v '06-time-map' "$dir/film.html" > "$t/f.html" && mv "$t/f.html" "$dir/film.html"
    printf '// a tweak\n' >> "$dir/src/00-core.js"; printf '// its own\n' > "$dir/src/40-own.js"; printf '// the film\n' >> "$dir/src/50-shots.js"
    snap() { find "$dir" -type f -exec cksum {} + | LC_ALL=C sort; }
    before=$(snap); b=$(vh doctor "$dir" 2>&1); rc2=$?; after=$(snap)
    case "$rc:$a" in 0:*"the copy is the engine as it is now"*)
      case "$rc2:$b" in 1:*"changed (2): film.html +1 −0, src/00-core.js +0 −1"*"missing (1): src/06-time-map.js (film.html does not load it either)"*"extra (1): src/40-own.js"*"diff -u "*)
          [ "$before" = "$after" ] && ok "doctor <project>: a fresh copy is the engine; an older one lists changed, missing and extra files and a diff command, read-only" \
            || bad "doctor <project> changed the project" ;;
        *) bad "doctor on an older copy (exit $rc2): $b" ;; esac ;;
      *) bad "doctor on a fresh canvas-film project (exit $rc): $a" ;; esac
  fi
  vh new short cf2 --engine canvas-film --aspect 9:16 --dir "$t" >/dev/null 2>&1; rc=$?
  vh new short cf3 --engine no-such --dir "$t" >/dev/null 2>&1; a=$?
  [ $rc = 2 ] && [ $a = 2 ] && [ -z "$(ls -d "$t"/*-cf2 "$t"/*-cf3 2>/dev/null)" ] && ok "bin/vh new refuses a vertical canvas-film and an unknown --engine" \
    || bad "bin/vh new --engine: --aspect 9:16 exited $rc, an unknown engine $a"
  rm -rf "$t"
  # tts picks the uv dependencies from --provider too (a fake uv prints the command instead of running it)
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX"); printf '#!/bin/sh\necho "$*"\n' > "$t/uv"; chmod +x "$t/uv"
  a=$(PATH="$t:$PATH" vh tts "$t" --provider edge --lang en; PATH="$t:$PATH" vh tts "$t" --provider=dashscope)
  case "$a" in *"--with edge-tts "*"--provider edge"*"--with dashscope "*) ok "tts --provider picks the provider's dependencies" ;;
    *) bad "tts --provider: uv got '$a'" ;; esac
  # Ctrl-C (to the process group, as a terminal sends it) while a command runs through uv run ends bin/vh by SIGINT (130
  # to a shell; the caller sees the Ctrl-C), even when uv itself exits 2 ("Failed to get PID of child process", the race
  # when its Python has just exited): a fake uv that does exactly that, under each command that goes through uv
  printf '#!/bin/sh\ntrap '"'"'echo "error: Failed to get PID of child process" >&2; exit 2'"'"' INT\n: > "$UVMARK"\nwhile :; do sleep 0.05; done\n' > "$t/uv"
  if a=$(python3 - "$t" "$VH_BASH" "$ROOT/bin/vh" <<'PY'
import os, signal, subprocess, sys, time
t, sh, vh = sys.argv[1:]
open(f"{t}/x.mp4", "wb").close()   # sheet looks for its video before it runs uv
os.makedirs(f"{t}/audio", exist_ok=True); open(f"{t}/audio/timeline.json", "w").close()   # and captions for its timeline
mark, env = f"{t}/started", dict(os.environ, PATH=f"{t}:{os.environ['PATH']}", UVMARK=f"{t}/started")
runs = [["music", "x"], ["sfx", "x"], ["beats", "x"], ["qa", "x"], ["mix", "profile=x"], ["tts", t], ["pace", "x"],
        ["cover-preview", "x"], ["style", "compare", "a,b"], ["sheet", f"{t}/x.mp4"], ["fonts", "list", "x"], ["captions", t],
        ["voices", "audition", "--voices", "x", "--text", "x"]]
bad = []
for r in runs:
    if os.path.exists(mark): os.remove(mark)
    p = subprocess.Popen([sh, vh, *r], start_new_session=True, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(500):
        if os.path.exists(mark) or p.poll() is not None: break
        time.sleep(0.02)
    try: os.killpg(p.pid, signal.SIGINT)
    except OSError: pass
    try: rc = p.wait(timeout=20)
    except subprocess.TimeoutExpired: os.killpg(p.pid, signal.SIGKILL); rc = "hung"
    if rc != -signal.SIGINT: bad.append(f"{' '.join(r[:2])} {rc}")
print(", ".join(bad)); sys.exit(1 if bad else 0)
PY
); then ok "Ctrl-C ends every command that runs through uv run by SIGINT, also when uv exits 2 as its Python exits"
  else bad "Ctrl-C under uv run (command, exit; want -2, death by SIGINT): $a"; fi
  rm -rf "$t"
  # tts: a Gemini 429 that names a per-day quota fails at once, though it asks for 30 s; a per-minute one is still waited
  # out and retried; one naming no daily quota fails at once only past 90 s (a stub on 127.0.0.1; waits recorded, not slept)
  if a=$(GEMINI_API_KEY=ci-stub python3 - 2>&1 <<'PY'
import importlib.util, json, os, sys, threading
os.environ["no_proxy"] = "127.0.0.1"   # urlopen would send the stub's requests through an http_proxy
from http.server import BaseHTTPRequestHandler
sys.path.insert(0, "tools/assets")
from fetch import LocalServer   # (http.server's own bind, which asks socket.getfqdn, stalled 35 s on GitHub's macOS runners)
spec = importlib.util.spec_from_file_location("tts", "tools/audio/tts.py"); tts = importlib.util.module_from_spec(spec); spec.loader.exec_module(tts)
def body(*ids, delay="30s"):
    return json.dumps({"error": {"code": 429, "status": "RESOURCE_EXHAUSTED", "details": [
        {"@type": "type.googleapis.com/google.rpc.QuotaFailure", "violations": [{"quotaMetric": "generativelanguage.googleapis.com/x", "quotaId": i} for i in ids]},
        {"@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": delay}]}}).encode()
answers = []
class Stub(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"])); code, b = answers.pop(0)
        self.send_response(code); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
srv = LocalServer(("127.0.0.1", 0), Stub); threading.Thread(target=srv.serve_forever, daemon=True).start()
tts.GEMINI_API = f"http://127.0.0.1:{srv.server_address[1]}"
waits = []; tts.time.sleep = waits.append
minute, day = "GenerateRequestsPerMinutePerProjectPerModel", "GenerateRequestsPerDayPerProjectPerModel"
answers[:] = [(429, body(minute, day)), (200, b"{}")]
try:
    tts.gemini_call("interactions", {}); raise SystemExit(f"a per-day 429 was retried (waits {waits})")
except tts.GeminiError as e:
    assert not waits and len(answers) == 1 and day in str(e) and "--resume" in str(e), (waits, str(e))
answers[:] = [(429, body(minute)), (429, body(minute)), (200, b'{"ok": 1}')]
assert tts.gemini_call("interactions", {}) == {"ok": 1} and waits == [31.0, 31.0], waits
answers[:] = [(429, body(minute, delay="120s")), (200, b"{}")]; waits.clear()
try:
    tts.gemini_call("interactions", {}); raise SystemExit("a 429 asking for 120 s was retried")
except tts.GeminiError:
    assert not waits and len(answers) == 1, waits
PY
); then ok "tts: a Gemini 429 naming a per-day quota fails at once; a per-minute one is retried; past 90 s fails at once"
  else bad "tts: Gemini 429 handling: $a"; fi
  # tts --join block --candidates 3 and voices audition against a Gemini stub on 127.0.0.1 that speaks a tone burst per
  # character (pitch by voice; the 2nd take of each block 25 % higher) and transcribes what it spoke (讲一讲 twice; 那 heard as
  # 哪 for one voice): the take nearest the median voice is kept, a slow line and the repeat are warned of, the audition
  # measures each voice's pitch and speech rate and names the misread word; without a key, nothing is synthesized
  if ! command -v uv >/dev/null || ! command -v ffmpeg >/dev/null; then skip "tts --candidates · voices audition" "needs uv and ffmpeg"
  elif a=$(uv run -q --no-project --with numpy python - 2>&1 <<'PY'
import base64, contextlib, hashlib, importlib.util, io, json, os, re, shutil, sys, tempfile, threading, wave
import numpy as np
os.environ["no_proxy"] = "127.0.0.1"; os.environ["GEMINI_API_KEY"] = "ci-stub"
from pathlib import Path
from http.server import BaseHTTPRequestHandler
sys.path.insert(0, "tools/audio"); sys.path.insert(0, "tools/assets")
from fetch import LocalServer   # (http.server's own bind, which asks socket.getfqdn, stalled 35 s on GitHub's macOS runners)
spec = importlib.util.spec_from_file_location("tts", "tools/audio/tts.py"); tts = importlib.util.module_from_spec(spec); spec.loader.exec_module(tts)
SR, PITCH = 24000, {"Kore": 200.0, "Puck": 130.0, "Charon": 110.0}
st = {"n": 0, "vary": False, "takes": []}                  # takes: (duration, [(unit, start, end)]) of every synthesis
def speak(items, f0):                                      # a burst per CJK character, 0.35 s between the items
    x, words, t = [np.zeros(int(0.05 * SR))], [], 0.05
    for k, text in enumerate(items):
        if k:
            x.append(np.zeros(int(0.35 * SR))); t += 0.35
        for c in re.findall(r"[一-鿿]", text):
            b = 0.4 if c == "慢" else 0.15; m = int(b * SR); tt = np.arange(m) / SR
            x.append(0.3 * np.sin(np.pi * np.arange(m) / m) ** 0.5 * sum(np.sin(2 * np.pi * f0 * h * tt) / h for h in (1, 2, 3)))
            words.append((c, t, t + b)); t += b
            x.append(np.zeros(int(0.05 * SR))); t += 0.05
    x.append(np.zeros(int(0.1 * SR))); y = np.concatenate(x)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes((np.clip(y, -1, 1) * 32767).astype("<i2").tobytes())
    return buf.getvalue(), len(y) / SR, words
def heard(words, voice):                                   # the transcript: the words, 讲一讲 said twice, 那 heard as 哪 for Charon
    out, k = [], 0
    while k < len(words):
        c, a, b = words[k]; out.append((("哪" if c == "那" and voice == "Charon" else c), a, b))
        if "".join(w[0] for w in words[k - 2:k + 1]) == "讲一讲":
            out += [(w[0], b + 0.01 * j, b + 0.01 * (j + 1)) for j, w in enumerate(words[k - 2:k + 1])]
        k += 1
    return out
class Stub(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if "response_format" in body:                      # synthesis
            voice = body["generation_config"]["speech_config"][0]["voice"]
            f0 = PITCH.get(voice, 160.0) * ((1.0, 1.25, 0.98)[st["n"] % 3] if st["vary"] else 1.0); st["n"] += 1
            data, dur, words = speak([c["text"] for c in body["input"][0]["content"]], f0); st["takes"].append((dur, words, voice))
            r = {"steps": [{"type": "model_output", "content": [{"type": "audio", "data": base64.b64encode(data).decode()}]}]}
        else:                                              # transcription: the take whose length matches (trimmed by ~0.04 s)
            st["asr"] = st.get("asr", 0) + 1
            with wave.open(io.BytesIO(base64.b64decode(body["input"][0]["data"]))) as w:
                dur = w.getnframes() / w.getframerate()
            _, words, voice = min(reversed(st["takes"]), key=lambda tk: abs(tk[0] - 0.04 - dur))   # the latest of equal ones
            ws = heard(words, voice)
            r = {"steps": [{"content": [{"type": "text", "text": "".join(w[0] for w in ws), "annotations": [
                {"type": "word_info", "text": w[0], "start_offset": f"{max(0, w[1] - 0.02):.2f}s", "end_offset": f"{max(0, w[2] - 0.02):.2f}s"} for w in ws]}]}]}
        b = json.dumps(r).encode(); self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
srv = LocalServer(("127.0.0.1", 0), Stub); threading.Thread(target=srv.serve_forever, daemon=True).start()
tts.GEMINI_API = f"http://127.0.0.1:{srv.server_address[1]}"
def run(argv):
    out = io.StringIO(); rc = 0
    with contextlib.redirect_stdout(out):
        sys.argv = ["tts.py", *argv]
        try:
            tts.main()
        except SystemExit as e:
            rc = e.code if isinstance(e.code, int) else (1 if e.code else 0); print(e.code if not isinstance(e.code, int) else "")
    return rc, out.getvalue()
bad = []
with tempfile.TemporaryDirectory() as d:
    p = Path(d) / "p"; (p / "audio").mkdir(parents=True)
    (p / "audio/script.txt").write_text("@a1 我们今天讲一讲声音的来历。\n@a2 先从一根琴弦说起吧。\n@a3 它振动时推着空气走。\n\n"
                                        "@b1 空气把推挤传到耳朵里。\n@b2 慢慢慢慢慢慢慢慢。\n@b3 耳朵把它变成声音。\n", encoding="utf-8")
    st["vary"] = True
    rc, out = run([str(p), "--provider", "gemini", "--voice", "Kore", "--join", "block", "--candidates", "3"])
    st["vary"] = False
    pick = json.loads((p / "audio/vo/zh/_pick.json").read_text(encoding="utf-8")) if (p / "audio/vo/zh/_pick.json").exists() else {}
    tl = json.loads((p / "audio/timeline.zh.json").read_text(encoding="utf-8")) if rc == 0 else {}
    if rc != 0: bad.append(f"tts --candidates exited {rc}: {out[-600:]}")
    elif [pick["blocks"][b]["chosen"] for b in ("1", "2")] != [1, 1] or len(list((p / "audio/vo/zh").glob("_block0?.c?.wav"))) != 6:
        bad.append(f"picked {pick}")
    elif sum(1 for s in tl["segments"] if s.get("words")) != 6: bad.append("not every line has words")
    for want in ("warning: @b2 takes", "“讲一讲” twice"):
        if want not in out: bad.append(f"no '{want}' in: {out[-900:]}")
    if "warning: @a2" in out or "warning: @b1" in out: bad.append(f"a false warning: {out[-900:]}")
    # --resume reuses a block's transcription only while it is of the same file: nothing changed, none; a cache from before
    # the key (no sha256) beside other takes of its block, each block once (a copy that kept the date would pass for the
    # old take), then none; another candidate copied over _block01.wav by hand, that block
    vo, again = p / "audio/vo/zh", [str(p), "--provider", "gemini", "--voice", "Kore", "--join", "block", "--candidates", "3", "--resume"]
    calls = lambda out: int((re.search(r"align: (\d+) transcribe call", out) or [0, -1])[1])   # noqa: E731
    rc, out = run(again)
    if rc != 0 or calls(out) != 0: bad.append(f"--resume with nothing changed: exit {rc}, {calls(out)} transcribe call(s): {out[-300:]}")
    for f in vo.glob("_block0?.asr.json"):
        c = json.loads(f.read_text(encoding="utf-8")); c.pop("sha256", None); f.write_text(json.dumps(c, ensure_ascii=False), encoding="utf-8")
    rc, out = run(again); rc2, out2 = run(again); kept = (vo / "_block02.asr.json").stat().st_mtime_ns
    if rc != 0 or calls(out) != 2 or calls(out2) != 0: bad.append(f"--resume on caches without a key beside other takes: exit {rc}, {calls(out)} then {calls(out2)} transcribe call(s): {out[-300:]}")
    shutil.copyfile(vo / "_block01.c2.wav", vo / "_block01.wav")
    rc, out = run(again); side = json.loads((vo / "_block01.asr.json").read_text(encoding="utf-8"))
    if rc != 0 or calls(out) < 1 or side.get("sha256") != hashlib.sha256((vo / "_block01.wav").read_bytes()).hexdigest() \
            or (vo / "_block02.asr.json").stat().st_mtime_ns != kept:
        bad.append(f"--resume after _block01.wav was swapped by hand: exit {rc}, {calls(out)} call(s), cache key {side.get('sha256')}: {out[-300:]}")
    # minimax gives its own word times (a stand-in for its API: a burst per character, 0.15 s, or 0.24 s every other take, and
    # its subtitles): with --candidates, the other take copied over _block01.wav is cut by that take's own words file, and
    # a take that is no candidate of the block stops the run (no --align gemini to cut it by), saying so
    os.environ["MINIMAX_API_KEY"] = "ci-stub"; mm = {"n": 0}
    def fake_mm(text, voice, lang, emotion):
        b = 0.24 if mm["n"] % 2 else 0.15; mm["n"] += 1
        x, subs, t = [np.zeros(int(0.05 * SR))], [], 0.05
        for part in re.split(r"(<#[\d.]+#>)", text):
            m = re.fullmatch(r"<#([\d.]+)#>", part)
            if m:
                x.append(np.zeros(int(float(m[1]) * SR))); t += float(m[1]); continue
            for c in part.strip():
                if not re.match(r"[一-鿿]", c):
                    subs.append({"text": c, "time_begin": round(t * 1000), "time_end": round(t * 1000)}); continue
                n = int(b * SR); x.append(0.3 * np.sin(2 * np.pi * 180 * np.arange(n) / SR) * np.sin(np.pi * np.arange(n) / n))
                subs.append({"text": c, "time_begin": round(t * 1000), "time_end": round((t + b) * 1000)}); t += b
                x.append(np.zeros(int(0.05 * SR))); t += 0.05
        x.append(np.zeros(int(0.1 * SR))); y = np.concatenate(x); buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes((np.clip(y, -1, 1) * 32767).astype("<i2").tobytes())
        return buf.getvalue(), subs
    tts.minimax_tts = fake_mm
    q = Path(d) / "m"; (q / "audio").mkdir(parents=True); mvo = q / "audio/vo/zh"
    (q / "audio/script.txt").write_text("@m1 我们今天讲声音。\n@m2 先从琴弦说起。\n\n@n1 空气把它传走。\n", encoding="utf-8")
    mcmd = [str(q), "--provider", "minimax", "--voice", "x", "--join", "block", "--candidates", "2"]
    spans = lambda: [round(s["end"] - s["start"], 2) for s in json.loads((q / "audio/timeline.zh.json").read_text(encoding="utf-8"))["segments"]][:2]   # noqa: E731
    rc, out = run(mcmd)
    if rc != 0: bad.append(f"minimax --candidates exited {rc}: {out[-500:]}")
    else:
        other = 3 - json.loads((mvo / "_pick.json").read_text(encoding="utf-8"))["blocks"]["1"]["chosen"]; before = spans()
        shutil.copyfile(mvo / f"_block01.c{other}.wav", mvo / "_block01.wav")
        rc, out = run(mcmd + ["--resume"]); after = spans()
        own = tts.load_words(mvo / f"_block01.c{other}.words.json")[1]
        if rc != 0 or tts.load_words(mvo / "_block01.words.json")[1] != own or not all(abs(q2 / p2 - (0.29 if other == 2 else 0.2) / (0.2 if other == 2 else 0.29)) < 0.1 for p2, q2 in zip(before, after)):
            bad.append(f"minimax: the other take copied in by hand (exit {rc}): line spans {before} → {after}: {out[-300:]}")
        shutil.copyfile(mvo / "_block02.wav", mvo / "_block01.wav")
        rc, out = run(mcmd + ["--resume"])
        if rc == 0 or "is not the take its word times (_block01.words.json) are of" not in out:
            bad.append(f"minimax: a take that is no candidate of the block, copied in (exit {rc}): {out[-300:]}")
    (Path(d) / "t.txt").write_text("我们那儿的声音从一根琴弦说起。\n", encoding="utf-8")
    rc, out = run(["voices", "audition", "--provider", "gemini", "--voices", "Kore,Puck,Charon", "--text", f"{d}/t.txt", "--out", f"{d}/au", "--align", "gemini"])
    au = json.loads(Path(f"{d}/au/audition.json").read_text(encoding="utf-8")) if Path(f"{d}/au/audition.json").exists() else {"voices": []}
    R = {r["voice"]: r for r in au["voices"]}
    true = 14 / (14 * 0.2 - 0.05)                          # characters over the voice, no pause in it
    if rc != 0 or sorted(R) != ["Charon", "Kore", "Puck"] or not all((Path(d) / "au" / R[v]["file"]).exists() for v in R): bad.append(f"audition exited {rc}: {out[-500:]}")
    else:
        if not all(abs(R[v]["pitch_hz"] / PITCH[v] - 1) < 0.03 for v in R): bad.append(f"pitch {[(v, R[v]['pitch_hz']) for v in R]}")
        if not all(abs(R[v]["speech_rate"] / true - 1) < 0.08 for v in R): bad.append(f"speech rate {[(v, R[v]['speech_rate']) for v in R]} (true {true:.2f})")
        if R["Kore"]["misread"] != [] or not any("那" in m for m in R["Charon"]["misread"]): bad.append(f"misread {[(v, R[v]['misread']) for v in R]}")
    # --align local: a stand-in mlx_whisper (the real one runs on Apple Silicon only) hears each take as the stub's
    # transcriber does; no transcription goes to Gemini, and the lines are heard one at a time (MLX keeps to one thread).
    # The stand-in finds a file's take by its length, so no two lines have as many characters
    import importlib.machinery, types
    seen = {"n": 0, "threads": set()}
    fake = types.ModuleType("mlx_whisper"); fake.__spec__ = importlib.machinery.ModuleSpec("mlx_whisper", None)
    def fake_transcribe(path, **kw):
        seen["n"] += 1; seen["threads"].add(threading.get_ident())
        with wave.open(path) as w:
            dur = w.getnframes() / w.getframerate()
        _, words, voice = min(reversed(st["takes"]), key=lambda tk: abs(tk[0] - 0.04 - dur))
        ws = heard(words, voice)
        i = "".join(w[0] for w in ws).find("一九五三")       # Whisper writes the year as digits
        if i >= 0:
            ws = ws[:i] + [("1953", ws[i][1], ws[i + 3][2])] + ws[i + 4:]
        return {"text": "".join(w[0] for w in ws), "segments": [{"words": [{"word": w[0], "start": max(0, w[1] - 0.02), "end": max(0, w[2] - 0.02)} for w in ws]}]}
    fake.transcribe = fake_transcribe
    sys.modules["mlx_whisper"] = fake
    p2 = Path(d) / "p2"; (p2 / "audio").mkdir(parents=True)
    (p2 / "audio/script.txt").write_text("@l1 声音从一根琴弦说起。\n@l2 它振动时推空气。\n@l3 耳朵把它变成声音。\n@l4 一九五三年的冬天特别冷。\n", encoding="utf-8")
    before = st.get("asr", 0)
    rc, out = run([str(p2), "--provider", "gemini", "--voice", "Kore", "--align", "local"])
    tl = json.loads((p2 / "audio/timeline.zh.json").read_text(encoding="utf-8")) if (p2 / "audio/timeline.zh.json").exists() else {"segments": []}
    l4 = next((s for s in tl["segments"] if s.get("id") == "l4"), {})
    if rc != 0 or seen["n"] < 4 or seen["threads"] != {threading.get_ident()} or st.get("asr", 0) != before or not all(s.get("words") and s.get("asr", {}).get("similarity") for s in tl["segments"]):
        bad.append(f"--align local: exit {rc}, {seen['n']} local transcription(s) on {len(seen['threads'])} thread(s), {st.get('asr', 0) - before} sent to Gemini: {out[-300:]}")
    elif l4.get("asr", {}).get("similarity", 0) < 0.95 or l4["asr"].get("flag") or not l4["words"][0]["w"].startswith("一") or abs(l4["words"][0]["start"] - l4["start"]) > 0.15:
        bad.append(f"--align local: 1953 heard for 一九五三 is not taken as the script's reading: {l4.get('asr')}, first word {(l4.get('words') or [None])[0]}, line start {l4.get('start')}")
    del sys.modules["mlx_whisper"]; tts.ASR["engine"] = "gemini"
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
); then ok "tts --candidates keeps the take nearest the median voice per block; a slow line and a repeated phrase are warned of; --resume hears a block swapped by hand again, the rest not; voices audition measures pitch, speech rate and misreads; --align local hears each line on this machine, one at a time, none sent to Gemini, a year heard as digits taken as the script's 一九五三"
  else bad "tts --candidates / voices audition on the Gemini stub: $a"; fi
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX"); printf '%s\n' '一句试音。' > "$t/t.txt"
  a=$(env -u GEMINI_API_KEY "$VH_BASH" "$ROOT/bin/vh" voices audition --provider gemini --voices Kore,Puck --text "$t/t.txt" 2>&1); rc=$?
  case "$rc:$a" in 1:*"set GEMINI_API_KEY"*"nothing was synthesized"*) [ ! -e "$t/audition-t" ] && ok "voices audition without a key says so and writes nothing" || bad "voices audition without a key wrote files" ;;
    *) bad "voices audition without a key: exit $rc: $a" ;; esac
  rm -rf "$t"
  # recipes: every recipe's frontmatter validates, list filters agree with the files, bad values are errors
  vh recipes check >/dev/null && ok "recipes check (frontmatter, README index, sketches)" || bad "bin/vh recipes check"
  a=$(vh recipes list --intent carry,enter --energy 5 --engine three --ids)
  if python3 - "$a" <<'PY'
import pathlib, re, sys   # the expectation, read straight from the files with plain regexes (not tools/recipes.py)
want = set()
for p in pathlib.Path("recipes").glob("*/*.md"):
    t = p.read_text(encoding="utf-8")
    f = lambda k: re.findall(r"[a-z0-9-]+", (re.search(rf"^{k}: (.*)$", t, re.M) or [None, ""])[1])
    e = [int(x) for x in f("energy")]
    if p.parent.name != "sequences" and e and {"carry", "enter"} & set(f("intent")) and min(e) <= 5 <= max(e) and "three" in f("engines"):
        want.add(f("id")[0])
got = set(sys.argv[1].split())
sys.exit(0 if want and got == want else 1)
PY
  then ok "recipes list --intent --energy --engine match the files"; else bad "recipes list filters: got '$(echo $a)'"; fi
  vh recipes list --intent no-such-intent >/dev/null 2>&1; rc=$?; [ $rc = 2 ] && ok "recipes list rejects an unknown vocabulary value" || bad "recipes list --intent no-such-intent exited $rc"
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  sed 's/^id: .*/id: ci-copy/' recipes/seam/flash-cut.md > "$t/ok.md"; sed 's/^energy: .*/energy: 9/' "$t/ok.md" > "$t/bad.md"
  a=$(vh recipes check "$t/bad.md" 2>&1); rc=$?
  vh recipes check "$t/ok.md" >/dev/null && [ $rc = 1 ] && case "$a" in *energy*) true ;; *) false ;; esac \
    && ok "recipes check passes a valid copy and names the bad field" || bad "recipes check on a copy (bad one exited $rc)"
  sed 's/^qa: .*/qa: {peak:4}/' "$t/ok.md" > "$t/yaml.md"   # YAML reads {peak:4} as one key, "peak:4"
  a=$(vh recipes check "$t/yaml.md" 2>&1); rc=$?
  [ $rc = 1 ] && case "$a" in *"space after"*) true ;; *) false ;; esac \
    && ok "recipes check refuses frontmatter that YAML would read differently" || bad "recipes check on {peak:4} exited $rc"
  vh recipes check --json >/dev/null 2>&1; rc=$?
  [ $rc = 2 ] && ok "recipes check treats an option as bad usage" || bad "recipes check --json exited $rc"
  # the shot-grammar cards (recipes/shot/, kind grammar): listed by grammar, every grammar with --grammar alone (also
  # before another option); a card without one of its sections is refused (not sent to the recipes' template), and one
  # with nothing under 什么时候别用; a code twice in one grammar, and a README row that is not the card's; --grammar takes
  # no recipe filter, an unknown grammar is said as one, an empty --grammar= as naming none
  a=$(vh recipes list --grammar size --ids | tr '\n' ' '); vh recipes list --grammar zoom >/dev/null 2>"$t/e1"; rc=$?
  vh recipes list --grammar size --intent hook >/dev/null 2>&1; rc2=$?
  d=$(vh recipes list --grammar --ids | wc -l | tr -d ' '); e=$(vh recipes list --grammar 2>/dev/null | tail -n 1); vh recipes list --grammar= >/dev/null 2>"$t/e2"; rc4=$?
  sed -e 's/^id: .*/id: ci-card/' -e 's/^## 什么时候别用/## 别处/' recipes/shot/close-up.md > "$t/card.md"
  b=$(vh recipes check "$t/card.md" 2>&1); rc3=$?
  python3 -c 'import re, sys; s = open(sys.argv[1], encoding="utf-8").read().replace("id: close-up", "id: ci-empty")
sys.stdout.write(re.sub(r"(## 什么时候别用\n)(.*?)(?=\n## )", r"\1\n", s, flags=re.S))' recipes/shot/close-up.md > "$t/empty.md"
  f=$(vh recipes check "$t/empty.md" 2>&1); rc5=$?
  c=$(python3 -c 'import sys; sys.path.insert(0, "tools"); import recipes as R
lib = R.load_library(); p, fm = lib["close-up"]; lib["ci-twin"] = (p.with_name("ci-twin.md"), dict(fm, id="ci-twin"))
print(sum("code '"'"'CU'"'"' is" in x for x in R.library_checks(lib)))
lib = R.load_library(); p, fm = lib["close-up"]; lib["close-up"] = (p, dict(fm, name="近写"))
print(sum("the close-up row is" in x for x in R.library_checks(lib)))' 2>&1 | tr '\n' ' ')
  if [ "$a" = "close-up extreme-close extreme-wide long medium medium-close wide " ] && [ "$rc:$rc2:$rc3:$rc4:$rc5" = 2:2:1:2:1 ] && [ "$c" = "1 1 " ] \
     && [ "$d" = "$(ls recipes/shot/*.md | wc -l | tr -d ' ')" ] && grep -q "^$d shot-grammar cards" <<<"$e" \
     && grep -q "zoom is no grammar" "$t/e1" && grep -q "names no grammar" "$t/e2" \
     && grep -q "missing body section(s): ## 什么时候别用 (every shot-grammar card has" <<<"$b" && ! grep -q "_TEMPLATE" <<<"$b" && grep -q "## 什么时候别用: no item under it" <<<"$f"
  then ok "recipes list --grammar lists the shot-grammar cards by grammar, all of them alone; check refuses a card without its sections or with none under one, a code twice in a grammar, a README row that is not the card's; --grammar takes no recipe filter, and says an unknown or a missing grammar"
  else bad "the shot-grammar cards: [$a] [$d] [$e] exit $rc:$rc2:$rc3:$rc4:$rc5, [$c] | $(printf '%s' "$b$f" | tail -c 300) | $(cat "$t/e1" "$t/e2" | head -c 200)"; fi
  # a recipe's README row is the whole row its card makes (its one-liner too: only energy, length and status were held to
  # the card), however it is spaced (a row with blanks after it was never compared; one spaced otherwise is said to be),
  # and a sequence that lacks a section is pointed to a sequence, not to the recipes' template
  sed -e 's/^id: .*/id: ci-seq/' -e 's/^## 限额/## 别的/' recipes/sequences/launch-15s.md > "$t/seq.md"
  b=$(vh recipes check "$t/seq.md" 2>&1); rc=$?
  c=$(python3 -c 'import sys; sys.path.insert(0, "tools"); import recipes as R
lib = R.load_library(); p, fm = lib["hold-confirm"]; lib["hold-confirm"] = (p, dict(fm, one_liner=fm["one_liner"] + "，再停一拍"))
print(sum("the hold-confirm row differs from its card in its one-liner" in x for x in R.library_checks(lib)))
text = (R.LIB / "README.md").read_text(encoding="utf-8"); row = next(l for l in text.splitlines() if l.startswith("| [hold-confirm]"))
lib = R.load_library(); rows = lambda new: R.library_checks(lib, text.replace(row, new))
print(sum("the hold-confirm row differs from its card in its spacing (one-liner)" in x for x in rows(row.replace(" | ", " |  ", 1))))
print(sum("the hold-confirm row differs from its card in its one-liner" in x for x in rows(row.replace("按住", "按下", 1) + "  ")))
print(sum("hold-confirm" in x for x in rows(row)))' 2>&1 | tr '\n' ' ')
  if [ "$rc" = 1 ] && grep -q "## 限额 (every sequence has" <<<"$b" && ! grep -q "_TEMPLATE" <<<"$b" && [ "$c" = "1 1 1 0 " ]
  then ok "recipes check: a README row is the whole row its card makes (a one-liner that differs too), however it is spaced (spacing alone is said as such); a sequence without a section is pointed to the sequences"
  else bad "recipes check on a README row and a sequence (exit $rc, rows $c): $(printf '%s' "$b" | tail -c 300)"; fi
  a=$(vh recipes list -h 2>&1); rc=$?; b=$(vh recipes check --help 2>&1); rc2=$?
  case "$rc:$rc2|$a|$b" in "0:0|"*"usage: bin/vh recipes list"*"|"*"usage: bin/vh recipes list"*) ok "recipes list -h and check --help print the help" ;;
    *) bad "recipes list -h / check --help exited $rc / $rc2: $(printf '%s' "$a" | head -c 200)" ;; esac
  # help, not a run: captions -h and --help print the usage (it took -h for a project's name, exit 2); tools/fetch_media.sh
  # -h and --help print theirs and fetch nothing (-h was a word, and matched every path with "-h" in it: a dead URL here,
  # so nothing could come down either way), and an option it does not know is 2
  a=$(vh captions -h 2>&1); rc=$?; b=$(vh captions --help 2>&1); rc2=$?
  c=$(VH_MEDIA_URL=http://127.0.0.1:9/none tools/fetch_media.sh -h 2>&1); rc3=$?
  d=$(VH_MEDIA_URL=http://127.0.0.1:9/none tools/fetch_media.sh --help 2>&1); rc4=$?
  VH_MEDIA_URL=http://127.0.0.1:9/none tools/fetch_media.sh -x >/dev/null 2>&1; rc5=$?
  case "$rc:$rc2:$rc3:$rc4:$rc5|$a|$b|$c|$d" in "0:0:0:0:2|usage: bin/vh captions"*"|usage: bin/vh captions"*"|"*"usage: tools/fetch_media.sh"*"|"*"usage: tools/fetch_media.sh"*)
      case "$c$d" in *"fetch "*|*"could not download"*) bad "tools/fetch_media.sh --help went on to fetch: $(printf '%s' "$c$d" | tail -c 300)" ;;
        *) ok "captions -h and --help print the usage; tools/fetch_media.sh -h and --help print theirs and fetch nothing, an option it does not know exits 2" ;; esac ;;
    *) bad "the help of captions and tools/fetch_media.sh (exit $rc:$rc2:$rc3:$rc4:$rc5): $(printf '%s | %s' "$a" "$c" | head -c 400)" ;; esac
  # doctor's size of the reference repos is worked out, not written in: from the ones fetched when there are some, else
  # what install.sh tells the one installing
  a=$(python3 -c 'import sys; sys.path.insert(0, "tools"); import doctor as d
print(d.references_note(0, 37, 0, d.install_says())); print(d.references_note(31, 37, 214e6, None))' 2>&1)
  b=$(grep -o 'reference repos (about [0-9.]* [MG]B' install.sh | grep -o '[0-9.]* [MG]B')
  case "$a" in "0/37 repos fetched → bash references/fetch.sh (all 37: about $b;"*"31/37 repos fetched → bash references/fetch.sh (all 37: about 255 MB, at the size of the 31 here;"*)
      ok "doctor: the reference repos' size from the ones fetched (31 of 37 at 214 MB: about 255 MB), else as install.sh says it ($b)" ;;
    *) bad "doctor's line for the reference repos: $a (install.sh says: ${b:-nothing found})" ;; esac
  # recipes sample: bad usage exits 2 before any render (an unknown id, a sequence, an unknown style); list --json names
  # the sheet a recipe carries (recipes check, above, holds every sketch to its sheet)
  vh recipes sample no-such-recipe >/dev/null 2>&1; rc=$?; vh recipes sample launch-15s >/dev/null 2>&1; rc2=$?
  vh recipes sample button-to-player --style no-such-style >/dev/null 2>&1; rc3=$?
  a=$(vh recipes list --family ui --json | python3 -c 'import json, os, sys; d = {r["id"]: r for r in json.load(sys.stdin)}; s = d["button-to-player"].get("sample", ""); print(s if os.path.isfile(s) else "missing")')
  case "$rc:$rc2:$rc3:$a" in "2:2:2:recipes/ui/media/button-to-player.jpg") ok "recipes sample: an unknown id, a sequence or an unknown style is bad usage; list --json names the sheet" ;;
    *) bad "recipes sample usage ($rc, $rc2, $rc3) / list --json sample: $a" ;; esac
  # a sheet shows the sketch as it is: unchanged, sample keeps it without rendering; check names a sketch changed since
  # its sheet, a sheet over its size, and a sketch that leans on a clock (tools/purity.py)
  a=$(vh recipes sample button-to-player 2>&1); rc=$?
  b=$(python3 - <<'PY' 2>&1
import sys; sys.path.insert(0, "tools"); import recipes as R
lib = R.load_library(); p, fm = lib["button-to-player"]
lib["button-to-player"] = (p, {**fm, "sketch_sha": "000000000000"})
R.SHEET_MAX_KB = 1
probs = R.library_checks(lib)
print("stale" if any("button-to-player.md: its sketch changed since its sheet" in x for x in probs) else "no stale", "big" if any("button-to-player.jpg" in x and "at most 1 kB" in x for x in probs) else "no big")
PY
)
  sed 's/^id: .*/id: ci-impure/; s/const { W, H } = lib/const { W, H } = lib, j = Math.random()/' recipes/ui/button-to-player.md > "$t/impure.md"
  c=$(vh recipes check "$t/impure.md" 2>&1); rc2=$?
  case "$rc:$a|$b|$rc2:$c" in "0:"*"is the sketch as it is"*"|stale big|1:"*"Math.random (hard rule 1"*) ok "recipes: an unchanged sketch is not rendered again; check names a sheet behind its sketch, a sheet too big and a sketch on a clock" ;;
    *) bad "recipes sample / check on sheets ($rc, $rc2): $a | $b | $c" ;; esac
  # packcheck counts X's way (a Chinese character 2, a link 23); "X" names X only standing alone, not inside "xhs"
  { printf '%s\n' '# PACKAGING' '## 发布文案' '### X / 推特'; python3 -c "print('简介：' + '字' * 127 + ' https://example.com/' + 'a' * 40 + '.')"
    printf '%s\n' '### B站 + X' '简介：两个平台'; python3 -c "print('字' * 139)"; printf '%s\n' '### 小红书 xhs' "简介：$(python3 -c "print('字' * 300)")"; } > "$t/PACKAGING.md"
  a=$(python3 "$ROOT/tools/packcheck.py" "$t/PACKAGING.md"); rc=$?
  case "$rc:$a" in 1:*"X / 推特: ✓ 简介 description 279 weighted"*"B站 + X: ✗ 简介 description 287 weighted"*"official, x)"*"小红书 xhs: · 简介 description 300 characters"*)
      ok "packcheck: X's limit in its weighted length (Chinese 2, a link 23), the tightest platform of a heading, a one-letter name standing alone" ;;
    *) bad "packcheck on X copy (rc $rc): $a" ;; esac
  # what X takes for a link (twitter-text's rules): a bare domain with a TLD it knows, with its path, Chinese straight
  # before it staying text; not after - _ . / @ $, not a file name with a TLD it does not know, not a host with no TLD
  if a=$(python3 - <<'PY'
import sys; sys.path.insert(0, "tools"); import packcheck as P
cases = {"example.com/path": 23, "看这里：example.com，很好": 37, "x.com": 23, "packcheck.py": 23, "www.github.com/a/b": 23,
         "b23.tv/BV1x": 23, "example.co.uk": 23, "bit.ly/abc?x=1": 23, "example.com?x=1": 27, "example.com:8080/x": 23,
         "两个 https://a.io 和 b.io": 55, "https://example.com，后面": 29, "https://ex.com/a_(b).": 24, "ex.com/a.": 24,
         "foo_bar.com": 11, "Node.js": 7, "tools/x.py": 10, "-x.com": 6, "a@example.com": 13, "$example.com": 12, "ex.comm": 7,
         "https://localhost:3000/x": 24, "v1.2.3": 6, "a" * 63 + ".com": 23, "x" * 70 + ".com": 74, "看" * 70 + "example.com": 151,
         "a." * 3000 + " example.com": 6024}   # a label over 63 characters (in punycode) is no link, as on X; a long dotted run
bad = [f"{k!r}: {P.x_length(k)} (want {v})" for k, v in cases.items() if P.x_length(k) != v]
print("; ".join(bad)); sys.exit(1 if bad else 0)
PY
  ); then ok "packcheck: X's links as twitter-text finds them, bare domains (example.com/path) included, not foo_bar.com, Node.js or tools/x.py"
  else bad "packcheck, X's links: $a"; fi
  rm -rf "$t"
  if ! command -v ffmpeg >/dev/null; then skip "mux / gif smoke" "ffmpeg not installed"; return; fi
  if python3 tools/audio/test_mixstate.py; then ok "mix/mux: failed and stale builds refused, previous audio preserved, deliberate duration changes"
  else bad "mix/mux build validity"; fi
  # subtitle languages come from the file name, never from folders (a home dir like /home/zhang used to tag everything chi)
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX"); mkdir -p "$t/zhang/en.v1.2"
  ffmpeg -nostdin -v error -f lavfi -i color=c=black:s=64x64:d=1 -pix_fmt yuv420p -f mp4 "$t/zhang/en.v1.2/final" \
    && ffmpeg -nostdin -v error -f lavfi -i sine=d=0.5 "$t/a.wav" \
    && printf '1\n00:00:00,000 --> 00:00:00,900\nhi\n' | tee "$t/zhang/captions.en.srt" "$t/zhang/captions.zh.srt" "$t/zhang/en.v1.2/subs.srt" >/dev/null
  if vh mux "$t/zhang/en.v1.2/final" "$t/a.wav" "$t/out.mp4" --allow-short "$t/zhang/captions.en.srt" "$t/zhang/captions.zh.srt" "$t/zhang/en.v1.2/subs.srt" >/dev/null; then
    langs=$(ffprobe -v error -select_streams s -show_entries stream_tags=language -of csv=p=0 "$t/out.mp4" | tr '\n' ' ')
    [ "$langs" = "eng chi und " ] && ok "mux tags subtitle languages by file name" || bad "mux subtitle languages: got '$langs', want 'eng chi und'"
    a=$(ffprobe -v error -select_streams a -show_entries stream=duration -of csv=p=0 "$t/out.mp4"); python3 -c "import sys; sys.exit(0 if abs(float('$a') - 1) < 0.05 else 1)" \
      && ok "mux pads short audio to the video length" || bad "mux audio duration $a, want 1.0"
  else bad "bin/vh mux"; fi
  # no subtitle files: an empty array under set -u, which bash before 4.4 (macOS /bin/bash) treats as unbound
  vh mux "$t/zhang/en.v1.2/final" "$t/a.wav" "$t/out-nosubs.mp4" --allow-short >/dev/null && [ -s "$t/out-nosubs.mp4" ] \
    && ok "mux without subtitle files" || bad "bin/vh mux without subtitle files"
  vh gif "$t/zhang/en.v1.2/final" 64 5 >/dev/null && [ -f "$t/zhang/en.v1.2/final.gif" ] && ok "gif names the output after the file, not a dotted folder" || bad "bin/vh gif output name"
  # bin/vh deliver: a 2 s master with sound and a subtitle track, cut to fit 0.5 MB (a ceiling worked out from the size),
  # a keyframe every 2 s, BT.709 tags, the tracks copied, the PSNR measured; a limit too small to hold a picture is refused
  ffmpeg -nostdin -v error -f lavfi -i "testsrc2=s=320x180:r=30:d=2" -f lavfi -i "sine=d=2" -c:v libx264 -crf 10 -pix_fmt yuv420p \
    -color_range tv -colorspace bt709 -color_primaries bt709 -color_trc bt709 -c:a aac -shortest "$t/m0.mp4" \
    && vh mux "$t/m0.mp4" "$t/a.wav" "$t/master.mp4" --allow-short "$t/zhang/captions.zh.srt" >/dev/null
  a=$(vh deliver "$t/master.mp4" --max-gb 0.0005 --samples 2 2>&1); rc=$?
  if [ $rc = 0 ] && [ -s "$t/master.upload.mp4" ] && printf '%s' "$a" | grep -q 'PSNR against the master' && python3 - "$t/master.upload.mp4" <<'PY'
import json, os, subprocess, sys
f = sys.argv[1]
st = json.loads(subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-of", "json", f], capture_output=True, text=True).stdout)["streams"]
v = next(s for s in st if s["codec_type"] == "video")
keys = [l.split(",")[0] for l in subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time,flags", "-of", "csv=p=0", f],
                                                capture_output=True, text=True).stdout.split() if "K" in l.split(",")[1]]
ok = os.path.getsize(f) <= 500_000 and (v["pix_fmt"], v["color_range"], v["color_space"], v["color_transfer"], v["color_primaries"]) == ("yuv420p", "tv", "bt709", "bt709", "bt709")
ok = ok and [s["codec_type"] for s in st] == ["video", "audio", "subtitle"] and [round(float(k), 3) for k in keys] == [0.0]
sys.exit(0 if ok else 1)
PY
  then ok "deliver: the upload copy fits the size asked for, keeps BT.709 and the sound and subtitle tracks, and says its PSNR"
  else bad "deliver (exit $rc): $(printf '%s' "$a" | tail -c 600)"; fi
  a=$(vh deliver "$t/master.mp4" --for bilibili,youtube --out "$t/master.platform.mp4" --psnr off 2>&1); rc=$?
  case "$rc:$a" in 0:*"fits 8 GB with room"*"✓ Bilibili web"*"✓ YouTube"*) ok "deliver --for: a short master far under the limits is encoded at CRF alone, no VBV numbers past x264's range" ;;
    *) bad "deliver --for on a short master: exit $rc: $(printf '%s' "$a" | tail -c 500)" ;; esac
  a=$(vh deliver "$t/master.mp4" --max-gb 0.00001 2>&1); rc=$?
  case "$rc:$a" in 2:*"too little"*) ok "deliver: a limit that leaves no room for the picture is refused (exit 2)" ;; *) bad "deliver with a tiny limit: exit $rc: $a" ;; esac
  # a master that tags no colour matrix, BT.601 as ffmpeg writes it from RGB unless told otherwise (Manim CE's are): refused
  # with no copy and the way out said; with --matrix bt601 its green is green in the copy (taken for BT.709, as deliver
  # did, it came out (0, 216, 0) under BT.709 tags); --matrix on a master that tags one is refused
  ffmpeg -nostdin -v error -f lavfi -i "color=c=0x00ff00:s=320x180:r=30:d=1,format=rgb24" -pix_fmt yuv420p -c:v libx264 -crf 10 "$t/u601.mp4"
  a=$(vh deliver "$t/u601.mp4" --psnr off 2>&1); rc=$?; [ -e "$t/u601.upload.mp4" ] && rc="$rc, a copy made"
  b=$(vh deliver "$t/u601.mp4" --matrix bt601 --psnr off 2>&1); rc2=$?
  c=$(vh deliver "$t/master.mp4" --matrix bt601 --out "$t/master.m.mp4" --psnr off 2>&1); rc3=$?
  g=$(ffmpeg -nostdin -v error -i "$t/u601.upload.mp4" -frames:v 1 -vf "scale=in_color_matrix=bt709:in_range=tv:out_range=pc:flags=accurate_rnd+full_chroma_int,format=rgb24" -f rawvideo - 2>/dev/null |
    python3 -c 'import sys; d = sys.stdin.buffer.read(); i = (90 * 320 + 160) * 3; p = d[i:i + 3]; print("ok" if len(p) == 3 and p[0] <= 3 and p[1] >= 252 and p[2] <= 3 else tuple(p))')
  if [ "$rc:$rc2:$rc3:$g" = 2:0:2:ok ] && grep -q 'tags no colour matrix' <<<"$a" && grep -q -- '--matrix bt601' <<<"$a" && grep -q 'tags bt709, which is what it goes by' <<<"$c"
  then ok "deliver: a master that tags no colour matrix is refused (exit 2, no copy, --matrix said); with --matrix bt601 its green stays green; --matrix on a tagged master is refused"
  else bad "deliver on an untagged BT.601 master (exit $rc:$rc2:$rc3, the copy's green $g): $(printf '%s | %s | %s' "$a" "$b" "$c" | tail -c 500)"; fi
  # deliver under Assets: strict, no browser: two renders of one page (sidecars as bin/vh render writes them) and another
  # page's scratch film. The older render loaded a picture with no record: it stops (its own check, not the newest film's);
  # the newer one goes, though the scratch film's picture has no record either. A ledger it cannot read stops it too;
  # under record that is said and the copy made
  s="$t/strict"; mkdir -p "$s/out" "$s/renders" "$s/assets"; printf -- '- Assets: strict\n' > "$s/BRIEF.md"
  printf 'a' > "$s/assets/a.png"; printf 'b' > "$s/assets/b.png"; printf '<p>' > "$s/index.html"; printf '<p>' > "$s/other.html"
  for f in out/old out/new renders/scratch; do cp "$t/master.mp4" "$s/$f.mp4"; done
  printf '{"page": "../index.html", "files": {"index.html": null, "assets/a.png": null}}' > "$s/out/old.mp4.render.json"
  printf '{"page": "../index.html", "files": {"index.html": null}}' > "$s/out/new.mp4.render.json"
  printf '{"page": "../other.html", "files": {"other.html": null, "assets/b.png": null}}' > "$s/renders/scratch.mp4.render.json"
  touch -t 202601010000 "$s/out/old.mp4"
  a=$(vh deliver "$s/out/old.mp4" --psnr off 2>&1); r1=$?
  b=$(vh deliver "$s/out/new.mp4" --psnr off 2>&1); r2=$?
  printf '{' > "$s/assets/ledger.json"
  c2=$(vh deliver "$s/out/new.mp4" --out "$s/out/new.2.mp4" --psnr off 2>&1); r3=$?
  sed 's/strict/record/' "$s/BRIEF.md" > "$s/BRIEF.tmp" && mv "$s/BRIEF.tmp" "$s/BRIEF.md"
  d=$(vh deliver "$s/out/new.mp4" --out "$s/out/new.3.mp4" --psnr off 2>&1); r4=$?
  if [ "$r1:$r2:$r3:$r4" = "2:0:2:0" ] && [ ! -e "$s/out/old.upload.mp4" ] && [ -s "$s/out/new.upload.mp4" ] && [ ! -e "$s/out/new.2.mp4" ] && [ -s "$s/out/new.3.mp4" ] \
     && case "$a" in *"✗ assets check: fail (1 fail"*"--film "*"out/old.mp4"*"assets/a.png"*"no copy made"*) true ;; *) false ;; esac \
     && case "$b" in *"assets check"*) false ;; *) true ;; esac \
     && case "$c2|$d" in *"could not run"*"no copy made"*"|"*"the asset ledger could not be read"*) true ;; *) false ;; esac
  then ok "deliver under Assets: strict checks the master's own render: an unrecorded picture stops it (exit 2, said), another film's does not; an unreadable ledger stops it; under record that is said and the copy made"
  else bad "deliver under Assets: strict (exit $r1 $r2 $r3 $r4): $(printf '%s' "$a|$b|$c2|$d" | tail -c 700)"; fi
  # bin/vh clean: a finished project's frames, render chunks, drafts and old takes go (to a stand-in Trash here, OVH_TRASH_DIR);
  # the film in out/final/, its covers, the review pages, the narration in use and its original, sources and docs stay
  c="$t/cl"; mkdir -p "$c/out/frames" "$c/out/.film.mp4.parts" "$c/out/final/covers" "$c/out/review" "$c/audio/takes" "$c/src" "$c/node_modules/x" "$t/home"
  for f in BRIEF.md film.html src/50-shots.js out/frames/a.png out/.film.mp4.parts/part000.mp4 out/draft1.mp4 out/film.mp4 out/film.mp4.render.json \
    out/final/film-4k.mp4 out/final/covers/a.png out/review/gate-1.html out/cues.json audio/voiceover.zh.wav audio/voiceover.zh.raw.wav \
    audio/voiceover.zh.v1.wav audio/music.wav audio/takes/b.wav audio/timeline.zh.json node_modules/x/i.js; do printf x > "$c/$f"; done
  a=$(vh clean "$c" 2>&1); rc=$?; [ -f "$c/out/draft1.mp4" ] && a="$a (draft still there)"
  b=$(OVH_TRASH_DIR="$t/home/trash" vh clean "$c" --yes --delete 2>&1); rc2=$?
  left=$(cd "$c" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ')   # byte order: the runner's locale sorts otherwise
  want=".ovh/activity.jsonl BRIEF.md audio/timeline.zh.json audio/voiceover.zh.raw.wav audio/voiceover.zh.wav film.html out/cues.json out/final/covers/a.png out/final/film-4k.mp4 out/review/gate-1.html src/50-shots.js "   # (the activity log stays)
  if [ $rc = 0 ] && printf '%s' "$a" | grep -q '9 item(s)' && printf '%s' "$a" | grep -q '(draft still there)' && [ $rc2 = 0 ] && [ "$left" = "$want" ] \
    && [ "$(find "$t/home" -name '*.wav' | wc -l | tr -d ' ')" = 3 ] && [ "$(find "$t/home" -name '*.mp4' | wc -l | tr -d ' ')" = 2 ]
  then ok "clean: lists first; then the film, covers, review pages, the narration in use and the sources stay, the rest goes (old takes and renders to the Trash)"
  else bad "clean: exit $rc / $rc2, left: $left | $(printf '%s' "$a$b" | tail -c 700)"; fi
  # what went to the Trash gives no space back until it is emptied, and Time Machine's local snapshots can hold it after that
  # (a stand-in tmutil lists two, so this runs where there is none); what was deleted outright says only the snapshots' part;
  # a run that does both says the two, the Trash's after it is emptied
  mkdir -p "$t/stub" && printf '#!/bin/sh\nprintf "com.apple.TimeMachine.2026-10-25-120000.local\\ncom.apple.TimeMachine.2026-10-25-130000.local\\n"\n' > "$t/stub/tmutil" && chmod +x "$t/stub/tmutil"
  c="$t/cl5"; mkdir -p "$c/out"; c2="$t/cl6"; mkdir -p "$c2/out/frames"; c3="$t/cl7"; mkdir -p "$c3/out/frames"
  for f in BRIEF.md out/final.mp4 out/draft.mp4; do printf x > "$c/$f"; done; for f in BRIEF.md out/final.mp4 out/frames/a.png; do printf x > "$c2/$f"; done
  for f in BRIEF.md out/final.mp4 out/draft.mp4 out/frames/a.png; do printf x > "$c3/$f"; done
  a=$(PATH="$t/stub:$PATH" OVH_TRASH_DIR="$t/home/trash5" vh clean "$c" --yes 2>&1); rc=$?
  b=$(PATH="$t/stub:$PATH" OVH_TRASH_DIR="$t/home/trash5" vh clean "$c2" --yes --delete 2>&1); rc2=$?
  d=$(PATH="$t/stub:$PATH" OVH_TRASH_DIR="$t/home/trash5" vh clean "$c3" --yes --delete 2>&1); rc3=$?
  if [ $rc = 0 ] && [ $rc2 = 0 ] && [ $rc3 = 0 ] && [ -f "$t/home/trash5/draft.mp4" ] \
    && printf '%s' "$d" | grep -q 'what went to the Trash frees its space when the Trash is emptied' \
    && printf '%s' "$d" | grep -q "Time Machine holds 2 local snapshot(s): data deleted since the last one stays on the disk until macOS drops them, the Trash's too once it is emptied" \
    && printf '%s' "$a" | grep -q 'what went to the Trash frees its space when the Trash is emptied' \
    && printf '%s' "$a" | grep -q "Time Machine's 2 local snapshot(s) can still hold it on the disk after that" && ! printf '%s' "$a" | grep -q 'data deleted since the last one' \
    && printf '%s' "$b" | grep -q 'Time Machine holds 2 local snapshot(s): data deleted since the last one stays' && ! printf '%s' "$b" | grep -q 'Trash is emptied'
  then ok "clean: what went to the Trash gives its space back when the Trash is emptied (snapshots can hold it after that); what was deleted says the snapshots' part; a run of both says both"
  else bad "clean's closing lines (exit $rc / $rc2 / $rc3): $(printf '%s' "$a" | tail -n 3 | tail -c 500) | $(printf '%s' "$b" | tail -n 2 | tail -c 300) | $(printf '%s' "$d" | tail -n 3 | tail -c 400)"; fi
  # a cover video inside out/final/ is not the film, so out/final.mp4 is; a path kept inside a folder that goes stays
  c="$t/cl2"; mkdir -p "$c/out/final/covers" "$c/out/frames"
  for f in BRIEF.md out/final/covers/loop.mp4 out/final.mp4 out/draft.mp4 out/frames/a.png out/frames/keep.png; do printf x > "$c/$f"; done
  a=$(vh clean "$c" --keep out/frames/keep.png 2>&1); rc=$?
  if [ $rc = 0 ] && printf '%s' "$a" | grep -q 'the film: out/final.mp4' && printf '%s' "$a" | grep -q 'out/draft.mp4' && printf '%s' "$a" | grep -q 'out/frames/a.png' \
    && ! printf '%s' "$a" | grep -Eq 'keep\.png|  out/final\.mp4|loop\.mp4'
  then ok "clean: a cover video does not make the film a render; a path kept inside a folder that goes stays"
  else bad "clean on covers and a kept path (exit $rc): $(printf '%s' "$a" | tail -c 600)"; fi
  # deliver's copy is the film to clean: its record (<copy>.deliver.json) keeps the copy, its master and itself, so a project
  # with no out/final/ clears its draft; out/check/ is check frames (rebuilt), but a video in it stays; a copy replaced
  # since its record is said and kept
  c="$t/cl3"; mkdir -p "$c/out/check/storyboard/frames"; cp "$t/master.mp4" "$c/out/film-4k.mp4"
  for f in BRIEF.md out/draft.mp4 out/check/sheet.png out/check/storyboard/frames/S01.png; do printf x > "$c/$f"; done
  vh deliver "$c/out/film-4k.mp4" --out "$c/out/film-4k.bili.mp4" --psnr off >/dev/null 2>&1; rc=$?
  a=$(vh clean "$c" 2>&1); rc2=$?
  printf x > "$c/out/check/clip.mp4"; printf x >> "$c/out/film-4k.bili.mp4"
  mkdir -p "$c/out/check/repro"; for f in BRIEF.md source.js cut.mp4; do printf x > "$c/out/check/repro/$f"; done   # a project of its own
  b=$(OVH_TRASH_DIR="$t/home/trash3" vh clean "$c" --yes --delete 2>&1); rc3=$?
  left=$(cd "$c" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ')
  want=".ovh/activity.jsonl BRIEF.md out/check/clip.mp4 out/check/repro/BRIEF.md out/check/repro/cut.mp4 out/check/repro/source.js out/film-4k.bili.mp4 out/film-4k.bili.mp4.deliver.json out/film-4k.mp4 "
  if [ $rc = 0 ] && [ $rc2 = 0 ] && [ $rc3 = 0 ] && [ "$left" = "$want" ] && [ -f "$t/home/trash3/draft.mp4" ] \
    && printf '%s' "$a" | grep -q "record out/film-4k.bili.mp4.deliver.json stays, and what it names): out/film-4k.bili.mp4, out/film-4k.mp4" \
    && printf '%s' "$a" | grep -Eq '^ +[0-9.]+ [KMG]?B  out/check/$' && printf '%s' "$a" | grep -Eq '^ +[0-9.]+ [KMG]?B  out/draft.mp4$' \
    && ! printf '%s' "$a" | grep -Eq '^ +[0-9.]+ [KMG]?B  out/film-4k' \
    && printf '%s' "$b" | grep -q 'the copy out/film-4k.bili.mp4 is not the file recorded' && printf '%s' "$b" | grep -q 'stays in out/check (a video, not a check frame): out/check/clip.mp4' \
    && printf '%s' "$b" | grep -q 'projects of their own inside, kept whole: out/check/repro'
  then ok "clean: deliver's record keeps the copy and its master as the film (a replaced copy is said); out/check goes as rebuilt, a video and a project of its own in it stay"
  else bad "clean after deliver: exit $rc / $rc2 / $rc3, left: $left | $(printf '%s' "$a$b" | tail -c 900)"; fi
  # a record cut short (unreadable): the copy its file name names still stays, never listed as a render to clear
  c="$t/cl4"; mkdir -p "$c/out"; printf x > "$c/BRIEF.md"; cp "$t/master.mp4" "$c/out/final.mp4"
  vh deliver "$c/out/final.mp4" --out "$c/out/upload.mp4" --psnr off >/dev/null 2>&1 && printf '{' > "$c/out/upload.mp4.deliver.json"
  a=$(vh clean "$c" 2>&1); rc=$?
  if [ $rc = 0 ] && printf '%s' "$a" | grep -q 'not a record bin/vh deliver can read; the copy its name names stays' \
    && printf '%s' "$a" | grep -q 'deliver.json stays, and what it names): out/upload.mp4' && ! printf '%s' "$a" | grep -Eq '^ +[0-9.]+ [KMG]?B  out/upload.mp4$'
  then ok "clean: an unreadable delivery record still keeps the copy its name names"
  else bad "clean with a broken delivery record (rc $rc): $(printf '%s' "$a" | tail -c 600)"; fi
  # spec: the file against the BRIEF's Output and Resolution lines (python3 only)
  mkdir -p "$t/sp/out"
  sp() { ffmpeg -nostdin -v error -f lavfi -i "color=c=0x202020:s=${1}:r=${2}:d=${5:-1},${3}" -pix_fmt yuv420p "$t/sp/out/$4.mp4"; }
  sp 320x180 30 "drawbox=x=40:y=40:w=80:h=40:c=white:t=fill,drawbox=x=200:y=100:w=60:h=40:c=orange:t=fill" ref
  sp 640x360 30 "drawbox=x=80:y=80:w=160:h=80:c=white:t=fill,drawbox=x=400:y=200:w=120:h=80:c=orange:t=fill" x2
  sp 640x360 30 "drawbox=x=80:y=80:w=160:h=80:c=white:t=fill,drawbox=x=400:y=200:w=120:h=80:c=orange:t=fill,noise=alls=30:allf=t+u" noisy
  sp 640x360 30 "drawbox=x=80:y=80:w=320:h=160:c=white:t=fill,drawbox=x=400:y=200:w=120:h=80:c=orange:t=fill" big
  sp 320x180 25 "drawbox=x=40:y=40:w=80:h=40:c=white:t=fill" fps25
  sp 160x90 15 "drawbox=x=20:y=20:w=40:h=20:c=white:t=fill" draft
  sp 320x180 30 "drawbox=x=40:y=40:w=80:h=40:c=white:t=fill" long 2
  brief() { printf '%s\n' '# BRIEF' '## Spec' "- Output: $1" "- Resolution: $2  <!-- 1080p | 4k -->" > "$t/sp/BRIEF.md"; }
  brief '320x180, 30 fps, exactly 1.0s (30 frames)' 1080p
  a=$(vh check "$t/sp/out/ref.mp4" 2>&1); rc=$?; b=$(vh check "$t/sp/out/x2.mp4" 2>&1); rb=$?; c=$(vh check "$t/sp/out/fps25.mp4" 2>&1); rcc=$?
  case "$rc:$a|$rb:$b|$rcc:$c" in 0:*"spec: 320x180, 30 fps, 30 frames"*"|1:"*"FAIL frame 640x360"*"Resolution: 1080p, 4k"*"|1:"*"FAIL 25.000 fps, the BRIEF says 30"*)
      ok "check compares the file with the BRIEF: size, a 4K the BRIEF doesn't list, frame rate" ;; *) bad "check against the BRIEF ($rc/$rb/$rcc): $a | $b | $c" ;; esac
  a=$(vh check "$t/sp/out/long.mp4" 2>&1); rc=$?; b=$(vh check "$t/sp/out/draft.mp4" 2>&1); rb=$?
  case "$rc:$a|$rb:$b" in 1:*"FAIL 2.000 s of picture, the BRIEF says exactly 1.0 s"*"|0:"*"WARN 160x90 is smaller than every delivery"*) ok "check: a wrong length fails; a smaller draft only warns" ;;
    *) bad "check length / draft ($rc/$rb): $a | $b" ;; esac
  brief '320x180, 30 fps, exactly 1.0s (30 frames)' '1080p、4k'; a=$(vh check "$t/sp/out/x2.mp4" 2>&1); rc=$?
  brief '320x180, 30 fps, {2–3}s' 1080p; b=$(vh check "$t/sp/out/ref.mp4" 2>&1); rb=$?
  brief '320x180, 30 fps, 约 5 s（150 帧）' 1080p; c=$(vh check "$t/sp/out/ref.mp4" 2>&1); rcc=$?
  case "$rc:$a|$rb:$b|$rcc:$c" in 0:*"spec: 640x360"*"|0:"*"WARN 1.0 s, outside the BRIEF's 2–3 s"*"|0:"*"spec: 320x180"*)
      case "$b$c" in *placeholders*|*FAIL*) bad "check: a range or an approximate length was misread: $b | $c" ;; *) ok "check reads 1080p、4k, warns outside a range, skips approximate lengths" ;; esac ;;
    *) bad "check: separators / range / approximate ($rc/$rb/$rcc): $a | $b | $c" ;; esac
  # a variable-rate file (a still stretch written as one long frame): its frames and its length as they are, and the
  # rate said, with a BRIEF and without (the length was frames ÷ the nominal rate: 45 frames over 3 s read as 1.5 s);
  # the same frames as Matroska, whose length is the track's DURATION tag, and through a pipe, which writes none (its
  # packets' times then); a DURATION tag with a language (DURATION-eng); and constant rate with the sound 1 s longer than
  # the picture, which is no variable rate (its length frames ÷ the rate, the sound's tail said apart)
  vf=(-nostdin -v error -f lavfi -i "color=c=0x202020:s=320x180:r=30:d=3,drawbox=x=40:y=40:w=80:h=40:c=white:t=fill" \
    -vf "select='not(between(n\,30\,74))'" -fps_mode vfr -pix_fmt yuv420p)
  ffmpeg "${vf[@]}" "$t/sp/out/vfr.mp4"; ffmpeg "${vf[@]}" "$t/sp/out/vfr.mkv"; ffmpeg "${vf[@]}" -f matroska - > "$t/sp/out/vfr-pipe.mkv"
  ffmpeg -nostdin -v error -f lavfi -i "color=c=0x202020:s=320x180:r=30:d=3" -f lavfi -i "sine=f=440:d=4" -pix_fmt yuv420p \
    -c:v libx264 -c:a aac "$t/sp/out/cfr-sound.mp4"
  brief '320x180, 30 fps, exactly 3.0s' 1080p; a=$(vh check "$t/sp/out/vfr.mp4" 2>&1); rc=$?
  mkdir -p "$t/vfr" && cp "$t/sp/out/vfr.mp4" "$t/vfr/"; b=$(python3 tools/speccheck.py "$t/vfr/vfr.mp4" 2>&1)
  c=$(for f in vfr.mkv vfr-pipe.mkv cfr-sound.mp4; do python3 tools/speccheck.py "$t/sp/out/$f" --brief "$t/sp/BRIEF.md" 2>&1; echo "exit $?"; done)
  d=$(python3 -c 'import sys; sys.path.insert(0, "tools"); import speccheck as s
print(s.duration_tag({"DURATION-eng": "00:00:03.000000000"}), s.duration_tag({"ENCODER": "x", "DURATION": "N/A"}))' 2>&1)
  case "$rc:$a|$b|$c|$d" in 0:*"spec: 320x180, 30 fps, 45 frames, 3.00 s"*"WARN frames and length disagree: 45 frames over 3.00 s"*"|"*"45 frames, 3.00 s; no BRIEF"*"WARN frames and length disagree"*"|"*"45 frames, 3.00 s against"*"WARN frames and length disagree: 45 frames over 3.00 s (15 a second; the nominal rate is 30)"*"exit 0"*"45 frames, 3.00 s against"*"WARN frames and length disagree: 45 frames over 3.00 s"*"exit 0"*"90 frames, 3.00 s against"*"s past the last frame (audio longer than the picture)"*"exit 0|3.0 0.0")
      case "$c" in *"90 frames"*"disagree"*) bad "check on constant rate with a longer sound: called a variable rate: $(printf '%s' "$c" | tail -c 400)" ;;
        *) ok "check on a variable-rate file: its frames and length as they are (45 frames, 3.00 s against exactly 3 s), with a BRIEF and without, as MP4, as Matroska (its DURATION tag, or its packets' times through a pipe); DURATION-eng read; constant rate with a longer sound is none" ;; esac ;;
    *) bad "check on a variable-rate file (rc $rc): $(printf '%s' "$a" | head -c 400) | $b | $(printf '%s' "$c" | tail -c 700) | $d" ;; esac
  brief '320x180, 30 fps, exactly 1.0s (30 frames)' '1080p, 4k'
  # check: one odd frame in a moving clip fails with its time; the same clip without it, or with a two-frame flash, passes
  if command -v uv >/dev/null || python3 -c "import numpy" 2>/dev/null; then
    for a in "clean:0" "odd:eq(n,30)" "flash2:between(n,30,31)"; do
      ffmpeg -nostdin -v error -f lavfi -i testsrc=s=320x180:r=30:d=2 -vf "drawbox=c=red:t=fill:enable='${a#*:}'" -pix_fmt yuv420p "$t/${a%%:*}.mp4"; done
    a=$(vh check "$t/clean.mp4" 2>&1) && o=$(vh check "$t/flash2.mp4" 2>&1) && case "$a$o" in *"no isolated frames in 60"*"no isolated frames in 60"*) true ;; *) false ;; esac \
      && ok "check passes a clip without an odd frame, and a two-frame flash" || bad "check on clean / two-frame flash clips: $a $o"
    a=$(vh check "$t/odd.mp4" 2>&1); rc=$?
    case "$rc:$a" in 1:*"1 isolated frame(s) in 60: 1.000 s"*"--no-browser-gpu"*) ok "check fails on one odd frame and names its time" ;; *) bad "check on one odd frame (rc $rc): $a" ;; esac
    a=$(vh check "$t/odd.mp4" --allow 0.4,1.0 2>&1); rc=$?
    case "$rc:$a" in 0:*"no isolated frames in 60"*"declared (--allow, this run only): 1.000 s"*) ok "check --allow: a declared flash is listed and passes" ;; *) bad "check --allow (rc $rc): $a" ;; esac
    a=$(vh check "$t/odd.mp4" --allow 0.9-1.1 2>&1); rc=$?
    case "$rc:$a" in 0:*"declared (--allow, this run only): 1.000 s"*) ok "check --allow takes a span a-b" ;; *) bad "check --allow span (rc $rc): $a" ;; esac
    # an odd frame every 15 frames (a bounce landing on its still point once a cycle) is periodic motion, not a glitch
    ffmpeg -nostdin -v error -f lavfi -i color=c=0x404040:s=320x180:r=30:d=3 -vf "drawbox=x=100:y=60:w=60:h=60:c=white:t=fill:enable='eq(mod(n\,15)\,7)'" -pix_fmt yuv420p "$t/periodic.mp4"
    a=$(vh check "$t/periodic.mp4" 2>&1); rc=$?
    case "$rc:$a" in 0:*"no isolated frames in 90"*"periodic: 6 small frames, one every 15 frames (0.50 s)"*) ok "check: evenly spaced odd frames are periodic motion, said and not failed" ;; *) bad "check on periodic odd frames (rc $rc): $a" ;; esac
    # motion: 2 s of a moving pattern, then a hard cut to a pale still picture for 4 s: a cut that flashes and a still stretch
    ffmpeg -nostdin -v error -f lavfi -i testsrc2=s=320x180:r=30:d=2 -f lavfi -i color=c=0xE0E0E0:s=320x180:r=30:d=4 \
      -filter_complex "[0:v]lutyuv=y=val*0.4,format=yuv420p[a];[1:v]format=yuv420p[b];[a][b]concat=n=2:v=1[v]" -map "[v]" -pix_fmt yuv420p "$t/still.mp4"
    a=$(vh check "$t/still.mp4" 2>&1); rc=$?
    case "$rc:$a" in 0:*"motion: "*"1 hard cut(s)"*"static: 1 stretch(es) of 3 s or more"*"2.00–6.00 s (frozen)"*"cuts: 1 hard cut(s) from dark to bright"*"2.00 s"*) ok "check --motion: a still stretch and a cut from dark to bright are warnings, the exit status untouched" ;;
      *) bad "check on a still stretch and a bright cut (rc $rc): $a" ;; esac
    # the ways out (tools/remedies.json) after the lines, for the kinds found: a still stretch → breath recipes, a bright cut → rising seams
    case "$a" in *"ways out (tools/remedies.json"*"static (1): "*"bin/vh recipes list --role breath"*"cut (1): "*"bin/vh recipes list --family seam --jump rise"*) ok "check names a way out for what it found (a breath recipe for a still stretch, a rising seam for a bright cut), from tools/remedies.json" ;;
      *) bad "check's ways out: $(printf '%s' "$a" | tail -c 600)" ;; esac
    b=$(vh check "$t/still.mp4" --json 2>/dev/null)
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); f=[x for x in d["findings"] if x["kind"]=="check.static"]; sys.exit(0 if f and f[0]["remedies"][0]["run"]=="bin/vh recipes list --role breath" else 1)' "$b" \
      && ok "check --json: each finding carries its remedies" || bad "check --json remedies: $(printf '%s' "$b" | tail -c 400)"
    # the ending: a fade still under way at the last frame is a warning with its way out; one that reaches black, and a film that simply stops, say nothing
    ffmpeg -nostdin -v error -f lavfi -i testsrc2=s=320x180:r=30:d=2 -vf "fade=t=out:st=1.4:d=0.8,format=yuv420p" "$t/short.mp4"
    ffmpeg -nostdin -v error -f lavfi -i testsrc2=s=320x180:r=30:d=2 -vf "fade=t=out:st=1.2:d=0.7,format=yuv420p" "$t/toblack.mp4"
    ffmpeg -nostdin -v error -f lavfi -i testsrc2=s=320x180:r=30:d=2 -pix_fmt yuv420p "$t/stops.mp4"
    a=$(vh check "$t/short.mp4" 2>&1); rc=$?
    b=$(vh check "$t/toblack.mp4" 2>&1); rc2=$?
    c=$(vh check "$t/stops.mp4" 2>&1); rc3=$?
    d=$(vh check "$t/short.mp4" --json 2>/dev/null)
    case "$rc:$rc2:$rc3:$a" in 0:0:0:*"ending: the picture is still fading when the film stops"*"fade (1): "*"bin/vh patch"*)
      if ! grep -q "ending:" <<<"$b$c" && python3 -c 'import json,sys; d=json.loads(sys.argv[1]); f=[x for x in d["findings"] if x["kind"]=="check.fade"]; sys.exit(0 if f and f[0]["severity"]=="warn" and f[0]["frame"]==59 else 1)' "$d"
      then ok "check --motion: a fade still under way at the last frame is a warning with a way out; one that reaches black, and a film that just stops, are not"
      else bad "check on the ending (a fade to black, or a film that stops, warned; or no finding in --json): $b $c $(printf '%s' "$d" | tail -c 300)"; fi ;;
      *) bad "check on a fade that stops short (exits $rc, $rc2, $rc3): $a" ;;
    esac
    # the publishing copy in PACKAGING.md: a Bilibili description of 2100 characters is over its 2000 (said, not a failure)
    { printf '%s\n' '# PACKAGING' '## 发布文案' '### B站' '标题：一个够短的标题' '标签：科普, 物理' '简介：'; python3 -c "print('字' * 2100)"; printf '%s\n' '### YouTube' 'Title: short'; } > "$t/sp/PACKAGING.md"
    a=$(vh check "$t/sp/out/ref.mp4" 2>&1); rc=$?
    case "$rc:$a" in 0:*"over a platform's limit"*"B站: ✓ 标题 title 7 characters"*"✗ 简介 description 2100 characters (limit 2000"*"YouTube: ✓ 标题 title 5 characters"*) ok "check measures the publishing copy against the platforms' limits and says what is over" ;;
      *) bad "check on the publishing copy (rc $rc): $(printf '%s' "$a" | tail -c 600)" ;; esac
    rm -f "$t/sp/PACKAGING.md"
    a=$(vh check "$t/odd.mp4" --allow 1s 2>&1); rc=$?
    [ $rc = 1 ] && ok "check --allow with a typo fails instead of skipping the scan" || bad "check --allow 1s exited $rc: $a"
    # confirmed.json: a designed flash confirmed in the project (why, evidence, the key the scan printed) passes while the
    # picture there is the same: a re-encode keeps it, another flash at that time lapses it, a moved flash leaves it unused
    mkdir -p "$t/cf/audio" && printf '%s\n' '# BRIEF' '- Effort: quick' > "$t/cf/BRIEF.md" && printf '%s\n' '# STORYBOARD' 'S01 a red flash' > "$t/cf/STORYBOARD.md"
    cp "$t/odd.mp4" "$t/cf/odd.mp4"
    ffmpeg -nostdin -v error -i "$t/odd.mp4" -c:v libx264 -crf 28 -pix_fmt yuv420p "$t/cf/odd-crf28.mp4"
    for a in "blue:blue:30" "late:red:45"; do IFS=: read -r f c n <<< "$a"
      ffmpeg -nostdin -v error -f lavfi -i testsrc=s=320x180:r=30:d=2 -vf "drawbox=c=$c:t=fill:enable='eq(n,$n)'" -pix_fmt yuv420p "$t/cf/odd-$f.mp4"; done
    fill() { python3 -c 'import json, sys; json.dump({"items": [dict(json.loads(l.split("confirm? ", 1)[1]), why="the red flash", evidence=sys.argv[1]) for l in sys.stdin if "confirm? {" in l]}, open(sys.argv[2], "w"))' "$@"; }
    a=$(vh check "$t/cf/odd.mp4" 2>&1); rc=$?
    case "$rc:$a" in 1:*"1 isolated frame(s) in 60: 1.000 s"*'confirm? {"tool": "check.iso", "at": "1.000", "key": "pic:'*) ok "check in a project offers a confirm? line for an isolated frame" ;; *) bad "check offers no confirm? line (rc $rc): $a" ;; esac
    printf '%s\n' "$a" | fill STORYBOARD.md#S01 "$t/cf/confirmed.json"
    a=$(vh check "$t/cf/odd.mp4" 2>&1); rc=$?; b=$(vh check "$t/cf/odd-crf28.mp4" 2>&1); rb=$?
    case "$rc:$a|$rb:$b" in 0:*"1 isolated frame(s) in 60: 1.000 s · all confirmed (confirmed.json)"*"confirmed (已确认, confirmed.json): isolated frame at 1 s · the red flash"*"|0:"*"all confirmed"*)
        ok "check: a confirmed flash keeps its raw line, says confirmed and passes; a CRF 28 copy keeps the confirmation" ;; *) bad "check with a confirmation ($rc/$rb): $a | $b" ;; esac
    a=$(vh check "$t/cf/odd-blue.mp4" 2>&1); rc=$?; b=$(vh check "$t/cf/odd-late.mp4" 2>&1); rb=$?
    case "$rc:$a|$rb:$b" in 1:*"LAPSED (已失效"*"isolated frame at 1 s: the picture there changed"*"|1:"*"1.500 s"*"unused (confirmed.json): isolated frame at 1 s"*'"at": "1.500"'*)
        ok "check: another flash at the confirmed time lapses it, a moved one leaves it unused and fails" ;; *) bad "check on a changed or moved flash ($rc/$rb): $a | $b" ;; esac
    printf '%s\n' "$a" | fill NOTES-missing.md "$t/cf/c2.json"; printf '%s\n' "$a" | fill STORYBOARD.md "$t/cf/c3.json"
    python3 - "$t/cf" <<'PY'
import json, sys
d = sys.argv[1]; good = json.load(open(d + "/c3.json"))["items"][0]
json.dump({"items": [json.load(open(d + "/c2.json"))["items"][0], dict(good, why=" "), dict(good, tool="check.static"),
                     dict(good, evidence="audio/"), dict(good, evidence="../outside.md"), dict(good, evidence="link.md S01")]}, open(d + "/confirmed.json", "w"))
PY
    echo outside > "$t/outside.md"; ln -s "$t/outside.md" "$t/cf/link.md"
    a=$(vh check "$t/cf/odd-blue.mp4" 2>&1); rc=$?
    case "$rc:$a" in 1:*"item 1"*"evidence: NOTES-missing.md is not in the project"*"item 2"*"no why"*"item 3"*"the motion lines are advice"*"item 4"*"evidence: audio/ is a folder, not a file"*"item 5"*"evidence: ../outside.md is outside the project"*"item 6"*"evidence: link.md is outside the project"*)
        ok "check refuses an entry without evidence on file, without why, for a motion warning, or with evidence that is a folder, outside the project or a link out of it" ;;
      *) bad "check took a bad entry (rc $rc): $a" ;; esac
    printf '{"items": [' > "$t/cf/confirmed.json"; a=$(vh check "$t/cf/odd.mp4" 2>&1); rc=$?
    case "$rc:$a" in 1:*"bad --allow or confirmed.json"*) ok "check fails on an unreadable confirmed.json instead of skipping the scan" ;; *) bad "check on a broken confirmed.json (rc $rc): $a" ;; esac
    rm -f "$t/cf/confirmed.json"
    a=$(vh check "$t/cf/odd.mp4" --allow 1.0 2>&1); rc=$?
    case "$rc:$a" in 0:*"declared (--allow, this run only): 1.000 s; to keep a declaration, confirm it in "*"/cf/confirmed.json"*) ok "check --allow says it is for this run only and where to confirm for good" ;; *) bad "check --allow in a project (rc $rc): $a" ;; esac
    # --json: the same checks as findings (kind, severity, time, frame, evidence, confirmed), on stdout and kept as
    # out/check/<name>.check.json; the exit status as without it; a confirmation from the record's own entry passes it
    a=$(vh check "$t/cf/odd.mp4" --json 2>/dev/null); rc=$?
    python3 - "$t/cf" "$a" <<'PY' > "$t/cf/j1.txt" 2>&1; rc2=$?
import json, os, sys
d, out = sys.argv[1], sys.argv[2]
j = json.loads(out); rec = json.load(open(d + "/out/check/odd.check.json", encoding="utf-8"))
iso = [f for f in j["findings"] if f["kind"] == "check.iso"]
ok = j == rec and j["version"] == 1 and j["exit"] == 1 and j["verdict"] == "fail" and j["video"] == "odd.mp4" and j["record"] == "out/check/odd.check.json"
st = os.stat(d + "/odd.mp4")   # the film's size and mtime_ns as checked: what status and versions compare with the film later
ok = ok and j["size"] == st.st_size and j["mtime_ns"] == st.st_mtime_ns
ok = ok and len(iso) == 1 and iso[0]["severity"] == "fail" and iso[0]["t"] == 1.0 and iso[0]["frame"] == 30 and iso[0]["confirmed"] is False
ok = ok and iso[0]["confirm"]["tool"] == "check.iso" and iso[0]["evidence"]["key"].startswith("pic:") and j["counts"]["fail"] == 1
json.dump({"items": [dict(iso[0]["confirm"], why="the red flash", evidence="STORYBOARD.md S01")]}, open(d + "/confirmed.json", "w"))
print(out[:300]); sys.exit(0 if ok else 1)
PY
    b=$(vh check "$t/cf/odd.mp4" --json 2>/dev/null); rc3=$?
    c=$(vh check "$t/sp/out/fps25.mp4" --json 2>/dev/null); rc4=$?
    d=$(vh check "$t/clean.mp4" --json 2>/dev/null); rc5=$?
    e=$(vh clean "$t/cf" 2>&1)
    if [ $rc = 1 ] && [ $rc2 = 0 ] && [ $rc3 = 0 ] && [ $rc4 = 1 ] && [ $rc5 = 0 ] && [ ! -e "$t/check" ] && python3 - "$b" "$c" "$d" <<'PY'
import json, sys
b, c, d = (json.loads(x) for x in sys.argv[1:4])
iso = [f for f in b["findings"] if f["kind"] == "check.iso"]
spec = [f for f in c["findings"] if f["kind"] == "check.spec"]
sys.exit(0 if iso and iso[0]["confirmed"] is True and iso[0]["severity"] == "info" and iso[0]["evidence"]["entry"]["why"] == "the red flash"
         and b["verdict"] == "pass" and spec and spec[0]["severity"] == "fail" and "25.000 fps" in spec[0]["message"]
         and spec[0]["evidence"]["measured"]["fps"] == 25 and d["record"] is None and d["verdict"] == "pass" else 1)
PY
    then case "$e" in *"stays in out/check (bin/vh check's records): "*"out/check/odd.check.json"*) ok "check --json: findings with kind, severity, time, frame, evidence and confirmation, the same exit status, kept as out/check/<name>.check.json (clean keeps it); none kept outside a project" ;;
        *) bad "clean does not keep check records: $(printf '%s' "$e" | tail -c 300)" ;; esac
    else bad "check --json (rc $rc/$rc2/$rc3/$rc4/$rc5): $(tail -c 300 "$t/cf/j1.txt") | $(printf '%s' "$b$c" | head -c 600)"; fi
    rm -f "$t/cf/confirmed.json"
    # the record keeps the film as it was when the checks began (bin/vh check notes its size and mtime_ns first): a film touched
    # while they run (here, once that note is in the scratch folder, which a private TMPDIR holds alone) is not the one checked, and
    # status says so at once, where the end of the checks would have seen the new film; checkrec.py reads the note, and without it
    # takes the film as it is
    mkdir -p "$t/ck/out" "$t/ck-tmp" && printf -- '- Effort: quick\n' > "$t/ck/BRIEF.md" && cp "$t/clean.mp4" "$t/ck/out/film.mp4"
    TMPDIR="$t/ck-tmp" vh check "$t/ck/out/film.mp4" >/dev/null 2>&1 & pid=$!
    n=0; while [ -z "$(cat "$t"/ck-tmp/vh-check.*/film.txt 2>/dev/null)" ] && [ $n -lt 300 ]; do sleep 0.02; n=$((n + 1)); done
    touch "$t/ck/out/film.mp4"; wait $pid
    a=$(vh status "$t/ck" --json | python3 -c 'import json, sys; c = json.load(sys.stdin)["check"]; print(c["verdict"], c["stale"])')
    mkdir -p "$t/ckd"; printf '12 34\n' > "$t/ckd/film.txt"
    b=$(python3 tools/checkrec.py "$t/ck/out/film.mp4" --dir "$t/ckd" --exit 0 --print | python3 -c 'import json, sys; r = json.load(sys.stdin); print(r["size"], r["mtime_ns"])')
    rm "$t/ckd/film.txt"
    c=$(python3 tools/checkrec.py "$t/ck/out/film.mp4" --dir "$t/ckd" --exit 0 --print | python3 -c 'import json, os, sys; r = json.load(sys.stdin); s = os.stat(sys.argv[1]); print(r["size"] == s.st_size and r["mtime_ns"] == s.st_mtime_ns)' "$t/ck/out/film.mp4")
    [ "$a" = "pass True" ] && [ "$b" = "12 34" ] && [ "$c" = True ] \
      && ok "check: the record keeps the film as it was when the checks began (a film touched meanwhile is stale at once); read from the note, else from the film" \
      || bad "check's record of the film's size and mtime_ns: status said '$a', note read as '$b', no note '$c'"
    # no scratch folder (mktemp -d fails): the same checks, lines and exit, one warning, no record (so no ways out, which
    # come from the record's findings); and freezedetect's
    # duration line (before its end line) goes to its own span, not to the span before
    a=$(vh check "$t/cf/odd.mp4" 2>/dev/null); rc=$?; rm -f "$t/cf/out/check/odd.check.json"
    b=$(TMPDIR="$t/no-such-folder" vh check "$t/cf/odd.mp4" 2>"$t/cf/notmp.err"); rc2=$?
    c=$(TMPDIR="$t/no-such-folder" vh check "$t/cf/odd.mp4" --json 2>/dev/null); rc3=$?
    d=$(python3 -c 'import sys; sys.path.insert(0, "tools"); import checkrec as C
f = C.detect_findings("\n".join("lavfi.freezedetect.freeze_%s: %s" % x for x in [("start", 1), ("duration", 4), ("end", 5), ("start", 10), ("duration", 3.5), ("end", 13.5)]))
print([x["evidence"]["duration"] for x in f])')
    if [ $rc = 1 ] && [ $rc2 = 1 ] && [ "$(printf '%s\n' "$a" | sed '/^→ ways out/,$d')" = "$b" ] && [ "$(grep -c 'no scratch folder' "$t/cf/notmp.err")" = 1 ] && [ ! -e "$t/cf/out/check/odd.check.json" ] \
      && [ $rc3 = 1 ] && case "$c" in *'"verdict": "fail", "error": "no scratch folder'*) true ;; *) false ;; esac && [ "$d" = "[4.0, 3.5]" ]
    then ok "check with no scratch folder: the same lines and exit status, one warning, no record; each frozen span keeps its own duration"
    else bad "check without mktemp (rc $rc/$rc2/$rc3): $(tail -c 300 "$t/cf/notmp.err") | $c | freeze durations $d"; fi
    if command -v uv >/dev/null; then   # qa scan: a sparse passage (a dropout), a burst of clicks; the stems' own dip; confirmed.json
      qs() { uv run -q --no-project --with numpy --with scipy python "$ROOT/tools/audio/qa.py" scan "$@"; }
      gen() { ffmpeg -nostdin -v error -f lavfi -i "aevalsrc='0.5*sin(2*PI*220*t)*(1-$1*min(1,max(0,min((t-3)/0.02,(5-t)/0.02))))$2':s=48000:d=10" -ac 2 -c:a pcm_s16le "$3"; }
      k3='+0.4*(eq(n,288000)+eq(n,302400)+eq(n,316800))'
      gen 0.9 "$k3" "$t/cf/audio/mix.wav"; gen 0.97 "$k3" "$t/cf/audio/deeper.wav"; gen 0.9 "${k3%)}+eq(n,309600))" "$t/cf/audio/clicks4.wav"
      ffmpeg -nostdin -v error -i "$t/cf/audio/mix.wav" -af volume=-3dB -c:a aac -b:a 128k "$t/cf/audio/mix.m4a"
      mkdir -p "$t/cf/st1" "$t/cf/st2"; cp "$t/cf/audio/mix.wav" "$t/cf/st1/music.wav"; gen 0 '' "$t/cf/st2/music.wav"
      a=$(qs "$t/cf/audio/mix.wav" --stems "$t/cf/st1" 2>&1); rc=$?; b=$(qs "$t/cf/audio/mix.wav" --stems "$t/cf/st2" 2>&1); rb=$?
      case "$rc:$a|$rb:$b" in 0:*"dropouts (0.1 s RMS < section median − 12 dB): 0 (1 more that the music stem has too: the score's own dynamics)"*"|1:"*"dropouts (0.1 s RMS < section median − 12 dB): 1"*)
          ok "qa scan: a dropout the music stem has too is the score's own; one the music does not have still fails" ;; *) bad "qa dropouts against the music stem ($rc/$rb): $a | $b" ;; esac
      # the music's own dip excuses only the windows it covers: a 3 s dropout over a 0.3 s dip of the stem stays one from 3.35 s;
      # the same for pumping, frame by frame (a 0.25 s dip of the mix over a 60 ms dip of the stem)
      ff() { ffmpeg -nostdin -v error -f lavfi -i "aevalsrc='0.5*sin(2*PI*220*t)*(1-$1)':s=48000:d=10" -ac 2 -c:a pcm_s16le "$2"; }
      mkdir -p "$t/cf/st3" "$t/cf/st4"; ff '0.95*between(t,3,6)' "$t/cf/audio/drop.wav"; ff '0.95*between(t,3,3.3)' "$t/cf/st3/music.wav"
      ff '0.684*between(t,3,3.25)' "$t/cf/audio/pump.wav"; ff '0.684*between(t,3,3.06)' "$t/cf/st4/music.wav"
      a=$(qs "$t/cf/audio/drop.wav" --stems "$t/cf/st3" 2>&1); rc=$?; b=$(qs "$t/cf/audio/pump.wav" --stems "$t/cf/st4" 2>&1); rb=$?
      case "$rc:$a|$rb:$b" in 1:*"dropouts (0.1 s RMS < section median − 12 dB): 1 (1 more that the music stem has too"*"3.35-   5.95 s"*"|1:"*"pumping (dip > 4 dB for ≥ 60 ms, not at a transient music hit): 1"*"3.06-   3.23 s  depth 10.0 dB"*)
          ok "qa scan: a short dip of the music stem excuses only the windows it covers, for dropouts and pumping" ;; *) bad "qa: a short stem dip excused a longer one ($rc/$rb): $a | $b" ;; esac
      a=$(qs "$t/cf/audio/mix.wav" 2>&1); rc=$?
      case "$rc:$a" in 1:*'confirm? {"tool": "qa.dropout", "at": "3.100-4.900"'*'confirm? {"tool": "qa.click", "at": "5.950-6.650", "n": 3'*) ok "qa scan in a project offers confirm? lines for a dropout and a click burst" ;; *) bad "qa scan offers (rc $rc): $a" ;; esac
      printf '%s\n' "$a" | fill STORYBOARD.md#S01 "$t/cf/confirmed.json"
      python3 - "$t/cf/confirmed.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["items"].append({"tool": "qa.silence", "at": "7-7.1", "key": "env:V", "why": "a stop", "evidence": "STORYBOARD.md"}); json.dump(d, open(sys.argv[1], "w"))
PY
      a=$(qs "$t/cf/audio/mix.wav" 2>&1); rc=$?; b=$(qs "$t/cf/audio/mix.m4a" 2>&1); rb=$?
      case "$rc:$a|$rb:$b" in 0:*"4.90 s  0s: -32.0 dBFS vs median -12.0  confirmed (已确认)"*"3 in confirmed spans"*"not taken (confirmed.json, item 3"*"digital silence is a floor"*"✓ audio QA passed · 4 confirmed"*"|0:"*"confirmed (已确认, confirmed.json): dropout at 3.1-4.9 s"*"✓ audio QA passed"*)
          ok "qa scan: a confirmed dropout and click burst pass and keep their lines; an AAC copy 3 dB down keeps them; silence is not taken" ;; *) bad "qa scan with confirmations ($rc/$rb): $a | $b" ;; esac
      a=$(qs "$t/cf/audio/deeper.wav" 2>&1); rc=$?; b=$(qs "$t/cf/audio/clicks4.wav" 2>&1); rb=$?
      case "$rc:$a|$rb:$b" in 1:*"LAPSED (已失效, confirmed.json"*"dropout at 3.1-4.9 s: the sound there changed"*"|0:"*"LAPSED (已失效, confirmed.json"*"click span at 5.95-6.65 s: 4 there now, 3 when confirmed"*)
          ok "qa scan: a deeper dip lapses its confirmation and fails; a fourth click lapses the span (a warning)" ;; *) bad "qa scan on changed sound ($rc/$rb): $a | $b" ;; esac
      rm -f "$t/cf/confirmed.json"
      # the score (a beat map's note map): a click on a note's onset is its attack, a rest of the whole score is not a dropout;
      # with a part left out of the map, or none, the dropout counts; every open finding carries its evidence; silence stays
      mkdir -p "$t/qs/st"; gen 0.9 "$k3" "$t/qs/mix.wav"; gen 0 '' "$t/qs/st/music.wav"
      ffmpeg -nostdin -v error -f lavfi -i "aevalsrc='0.5*sin(2*PI*220*t)*(1-between(t,7,7.1))':s=48000:d=10" -ac 2 -c:a pcm_s16le "$t/qs/sil.wav"
      python3 - "$t/qs" <<'PY'
import json, sys
d = sys.argv[1]; n = lambda t, e: {"t": t, "end": e, "midi": 62, "vel": 0.8, "part": "guqin#0"}
base = {"bpm": 60, "offset": 0, "beats": [], "downbeats": [], "sections": [{"name": "a", "start": 0, "end": 10, "bars": 3}], "hits": [],
        "duration": 10, "bars": [[1, 0, 4], [2, 4, 4], [3, 8, 4]], "bars_note": "[bar, start, beats]"}
notes = [n(1.0, 3.0), n(5.0, 5.9), n(6.0, 6.2), n(6.3, 6.5), n(6.6, 6.9), n(7.2, 9.5)]
json.dump({**base, "notes": notes, "unmapped": []}, open(d + "/score.json", "w"))
json.dump({**base, "notes": notes, "unmapped": ["pad#0"]}, open(d + "/partial.json", "w"))
json.dump({**base, "bpm": 480, "bars": [[k + 1, k * 0.5, 4] for k in range(20)], "unmapped": [],
           "notes": [n(k * 0.5 + o, k * 0.5 + o + 0.1) for k in range(20) for o in (0, 0.125)]}, open(d + "/rhythm.json", "w"))
PY
      a=$(qs "$t/qs/mix.wav" "$t/qs/score.json" 2>&1); rc=$?; b=$(qs "$t/qs/mix.wav" 2>&1); rb=$?
      case "$rc:$a" in 0:*"dropouts (0.1 s RMS < section median − 12 dB): 0 (1 more where the score itself is quiet"*"3.10-   4.90 s  a: -32.0 dBFS vs median -12.0 · the score rests here (no note held after 3.00 s; next 5.00 s guqin#0)"*"0 sharp discontinuities outside ±40 ms of designed onsets (0 more at designed onsets, 3 where the score starts a note"*"6.000 s"*"6.00 s guqin#0"*"✓ audio QA passed")
          case "$rb:$b" in *"the score"*) bad "qa scan without a score mentions one: $b" ;;
            1:*"dropouts (0.1 s RMS < section median − 12 dB): 1"*"3.10-   4.90 s"*"3 sharp discontinuities outside ±40 ms of designed onsets (0 more at designed onsets)."*)
              ok "qa scan with a note map: onset clicks are the notes' attacks, a scored rest is not a dropout; without a score both count as before" ;;
            *) bad "qa scan without a score changed (rc $rb): $b" ;; esac ;;
        *) bad "qa scan with a note map (rc $rc): $a" ;; esac
      a=$(qs "$t/qs/mix.wav" "$t/qs/partial.json" --stems "$t/qs/st" --clips "$t/qs/clips" 2>&1); rc=$?
      case "$rc:$a" in 1:*"dropouts (0.1 s RMS < section median − 12 dB): 1"*"8.0 dB under the threshold (-24.0 dBFS: the section median − 12 dB) · bar 1:4.10 · the score rests here"*"parts not in the note map: pad#0"*"stems, the span vs the 0.5 s before: music +0.0 dB"*"3 where the score starts a note"*"clips: 1 excerpt(s)"*)
          if [ -s "$t/qs/clips/0003.100s-dropout.wav" ]; then ok "qa scan: a rest of a partial note map still counts, with its evidence (threshold, bar, score, stems) and a clip named by time"
          else bad "qa scan --clips wrote no 0003.100s-dropout.wav: $(ls "$t/qs/clips" 2>&1)"; fi ;;
        *) bad "qa scan with a partial note map, stems and clips (rc $rc): $a" ;; esac
      a=$(qs "$t/qs/sil.wav" "$t/qs/score.json" 2>&1); rc=$?; b=$(qs "$t/qs/st/music.wav" "$t/qs/rhythm.json" 2>&1); rb=$?
      case "$rc:$a|$rb:$b" in 1:*"digital silence (< −60 dBFS, ≥ 20 ms): 1 inside the span"*"the score rests here (no note held after 6.90 s; next 7.20 s guqin#0) · a failure whatever the score does"*"|0:"*"advice  the score's rhythm (the note map's parts together) is the same 20 bars in a row: bars 1–20"*"✓ audio QA passed (advice above)"*)
          ok "qa scan: digital silence fails where the score rests; 20 identical bars of the note map are advice, not a failure" ;; *) bad "qa scan on silence in a rest, or a repeated rhythm ($rc/$rb): $a | $b" ;; esac
      printf '%s\n' '{"bpm": 120, "sections": [{"name": "a", "bars": 1, "chords": ["i"]}], "parts": [{"inst": "guqin", "note_map": true, "pattern": [[0, 1, "s0"]]},' \
        '{"inst": "piano", "pattern": [[0, 4, "c0"]]}, {"inst": "wind", "gain_db": -20, "quiet": true}]}' > "$t/qs/np.json"
      uv run -q --no-project --with numpy --with scipy python "$ROOT/tools/audio/music.py" "$t/qs/np.json" "$t/qs/np.wav" >/dev/null 2>&1
      a=$(python3 -c 'import json, sys; b = json.load(open(sys.argv[1])); print(b.get("unmapped"), len(b.get("notes", [])))' "$t/qs/np.beats.json" 2>&1)
      case "$a" in "['piano#0'] 1") ok "music: the note map says which parts it leaves out (unmapped; a texture plays no notes)" ;; *) bad "music: unmapped in the beat map: $a" ;; esac
      # what qa and beats are given by mistake (a missing beat map, as --beats too, a missing mix, a list where the beat
      # map goes, a file that is not audio, a missing track, no track): one line that names it and exit 2, no traceback; the
      # event list where the beat map goes, beside --beats, gets the command with - in its place
      printf '[1]' > "$t/qs/list.json"; printf '{}' > "$t/qs/x.wav"; printf '[]' > "$t/qs/ev.json"; printf '{}' > "$t/qs/b.json"; a=""
      for c in "qa.py|nope.json (the beat map)|$t/qs/mix.wav|--beats|$t/qs/nope.json" "qa.py|nope.json (the beat map)|$t/qs/mix.wav|$t/qs/nope.json" \
               "qa.py|nope.wav (the mix)|$t/qs/nope.wav" "qa.py|list.json is not a beat map|$t/qs/mix.wav|$t/qs/list.json" \
               "qa.py|x.wav: no audio ffmpeg can read|$t/qs/x.wav" "beats.py|beats: no such file: $t/qs/nope.wav|$t/qs/nope.wav" "beats.py|beats: which track?|--no-drums" \
               "qa.py|write - in its place: qa $t/qs/mix.wav - $t/qs/ev.json --beats $t/qs/b.json|$t/qs/mix.wav|$t/qs/ev.json|--beats|$t/qs/b.json" \
               "qa.py|--out $t/qs/none/r.txt: no folder $t/qs/none to write it in|$t/qs/mix.wav|--out|$t/qs/none/r.txt" \
               "qa.py|--json $t/qs/none/r.json: no folder $t/qs/none to write it in|mix|$t/qs|--json|$t/qs/none/r.json"; do
        IFS='|' read -r -a cargs <<< "$c"
        b=$(uv run -q --no-project --with numpy --with scipy python "$ROOT/tools/audio/${cargs[0]}" "${cargs[@]:2}" 2>&1); rc=$?
        case "$rc:$b" in *Traceback*) a="$a | ${cargs[0]}: $b" ;; "2:"*"${cargs[1]}"*) [ "$(printf '%s\n' "$b" | wc -l | tr -d ' ')" = 1 ] || a="$a | ${cargs[0]}, more than a line: $b" ;;
          *) a="$a | ${cargs[0]} ${cargs[*]:2} (rc $rc): $b" ;; esac
      done
      [ -z "$a" ] && ok "qa and beats: a missing or wrong input (beat map, --beats, mix, track, a folder for --out / --json) is one line and exit 2, before the analysis, not a traceback" || bad "qa / beats on a wrong input:$a"
      # usage errors of music and qa exit 2 (they were 1): no arguments, one, an unknown option, a bad --length, an unknown example
      a=""
      for c in "music.py" "music.py|$t/qs/np.json" "music.py|$t/qs/np.json|$t/qs/o.wav|--bogus" "music.py|$t/qs/np.json|$t/qs/o.wav|--length|-3" \
               "music.py|--example|nope" "qa.py" "qa.py|mix"; do
        IFS='|' read -r -a cargs <<< "$c"
        uv run -q --no-project --with numpy --with scipy python "$ROOT/tools/audio/${cargs[0]}" "${cargs[@]:1}" >/dev/null 2>&1; rc=$?
        [ $rc = 2 ] || a="$a | ${cargs[*]} exited $rc"
      done
      [ -z "$a" ] && ok "music and qa: usage errors exit 2" || bad "music / qa usage errors:$a"
    fi
    a=$(vh check "$t/a.wav" 2>&1); rc=$?
    case "$rc:$a" in 0:*"isolated"*) bad "check on audio only mentions the frame scan: $a" ;; 0:*) ok "check on an audio file skips the frame scan quietly" ;; *) bad "check on audio only (rc $rc): $a" ;; esac
    # scale: a 2x render against its 1x reference (clips made by the spec tests below)
    a=$(vh check "$t/sp/out/x2.mp4" --against "$t/sp/out/ref.mp4" 2>&1); rc=$?; b=$(vh check "$t/sp/out/noisy.mp4" --against "$t/sp/out/ref.mp4" 2>&1); rb=$?
    case "$rc:$a|$rb:$b" in 0:*"the same picture throughout"*"|0:"*"the same picture throughout"*) ok "check --against: a correct 2x render and a noisy one pass" ;;
      *) bad "check --against on correct clips ($rc/$rb): $a | $b" ;; esac
    a=$(vh check "$t/sp/out/big.mp4" --against "$t/sp/out/ref.mp4" 2>&1); rc=$?
    case "$rc:$a" in 1:*"FAIL 0.00–1.00 s: the picture differs"*"scale-fail-0.000s.png"*"twice the"*) [ -s "$t/sp/out/check/scale-fail-0.000s.png" ] \
        && ok "check --against fails on an element drawn at twice the size, with a comparison image" || bad "check --against wrote no comparison image" ;;
      *) bad "check --against on a 2x element (rc $rc): $a" ;; esac
    a=$(vh check "$t/sp/out/x2.mp4" --against "$t/sp/out/fps25.mp4" 2>&1); rc=$?
    case "$rc:$a" in 1:*"FAIL different frame rate"*"twice the"*) bad "check --against on different cuts points at comparison images: $a" ;;
      1:*"FAIL different frame rate"*) ok "check --against refuses to compare different cuts" ;; *) bad "check --against on different cuts (rc $rc): $a" ;; esac
  else skip "check: isolated frames, --against" "needs uv or numpy"; fi
  rm -rf "$t"
}

# scaffolding and the decision pictures (bin/vh storyboard, rhythm, style compare/apply, cover-preview, music --roll/--length)
# the gate ① record (tools/gatecheck.py): a standard project made from the templates is refused by bin/vh render (before
# any browser) and failed by bin/vh check until REVIEW.md has the decision and DECISIONS.md the concept; the user's
# waiver counts unless it sits under gate ② or ③; quick is not checked
gate_checks() {
  local t p a b c d e g rc rc2 rc3 rc4
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  vh new math ci-gate --dir "$t" >/dev/null 2>&1; p=$(ls -d "$t"/*-ci-gate 2>/dev/null)
  if [ -z "$p" ] || [ ! -f "$p/REVIEW.md" ]; then bad "gate checks: bin/vh new made no project"; rm -rf "$t"; return; fi
  a=$(vh render "$p" 2>&1); rc=$?
  c=$(vh render "$p" --range 0:1 2>&1)
  mkdir -p "$p/out/review/sketch" && printf '<!doctype html><title>a concept sketch</title>\n' > "$p/out/review/sketch/index.html"
  d=$(vh render "$p/out/review/sketch/index.html" 2>&1)
  case "$rc:$a" in 1:*"no record of gate ①"*"the person's words"*"the decision"*"DECISIONS.md: the concept 立意 row"*"--range a:b"*)
    case "$c|$d" in *"no record of gate"*) bad "render of a part or of a sketch page was held by the gate: $c | $d" ;;
      *) ok "gate record: render refuses a whole standard film made from the templates, naming the lines to write; a part (--range) and a sketch page under out/ still render" ;; esac ;;
    *) bad "render without the gate record (exit $rc): $(printf '%s' "$a" | head -c 600)" ;; esac
  # a flag that takes no value in front of the project leaves the gate the project's (bin/vh's arg_dir): --alpha and --fresh
  # took the project for their value, so the gate looked at the current folder, found no project and let the render go
  e=""
  for g in --alpha --fresh; do
    c=$(vh render "$g" "$p" --estimate 2>&1); rc2=$?
    case "$rc2:$c" in 1:*"no record of gate ①"*) ;; *) e="$e | $g (exit $rc2): $(printf '%s' "$c" | head -c 300)" ;; esac
  done
  if [ -z "$e" ]; then ok "gate record: render --alpha or --fresh in front of the project still checks that project"; else bad "render with a flag in front of the project:$e"; fi
  if command -v ffmpeg >/dev/null; then
    mkdir -p "$p/out" && ffmpeg -nostdin -v error -f lavfi -i color=c=0x303030:s=320x180:r=30:d=2 -pix_fmt yuv420p "$p/out/film.mp4"
    b=$(vh check "$p/out/film.mp4" 2>&1); rc2=$?
    case "$rc2:$b" in 1:*"✗"*"no record of gate ①"*) ok "gate record: check fails a standard film without it" ;; *) bad "check without the gate record (exit $rc2): $(printf '%s' "$b" | head -c 400)" ;; esac
  else skip "check without the gate record" "no ffmpeg"; fi
  python3 - "$p" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
r = (p / "REVIEW.md").read_text(encoding="utf-8")
(p / "REVIEW.md").write_text(r.replace("## 关卡 ③ 初版\n", "## 关卡 ③ 初版\n- 用户授权跳过（2026-10-12）。原话：“初版不用给我看”\n", 1), encoding="utf-8")
PY
  python3 tools/gatecheck.py "$p" >/dev/null; rc=$?
  # the template's "定了：{…}" left unfilled is not a decision, whatever record line follows it ("- 改了：…")
  python3 - "$p" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
r = (p / "REVIEW.md").read_text(encoding="utf-8").replace('- 原话："……"', '- 原话："选 B"', 1).replace("- 定了：{…}　改了：{…}", "- 定了：{…}　改了：{…}\n- 改了：结尾短一点", 1)
(p / "REVIEW.md").write_text(r, encoding="utf-8")
d = (p / "DECISIONS.md").read_text(encoding="utf-8").replace("| concept 立意 | {own / review / delegate} | {待定 / 已定（关卡 ①）} |", "| concept 立意 | own | 已定（关卡 ①）：B |", 1)
(p / "DECISIONS.md").write_text(d, encoding="utf-8")
PY
  python3 tools/gatecheck.py "$p" >/dev/null; rc4=$?
  cp "$ROOT/templates/REVIEW.md" "$p/"
  python3 - "$p" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
r = (p / "REVIEW.md").read_text(encoding="utf-8").replace("- 定了：{…}　改了：{…}", "- 定了：立意卡 B　改了：结尾短一点", 1).replace('- 原话："……"', '- 原话："选 B，结尾再短一点"', 1)
(p / "REVIEW.md").write_text(r, encoding="utf-8")
d = (p / "DECISIONS.md").read_text(encoding="utf-8").replace("| concept 立意 | {own / review / delegate} | {待定 / 已定（关卡 ①）} |", "| concept 立意 | own | 已定（关卡 ①）：B |", 1)
(p / "DECISIONS.md").write_text(d, encoding="utf-8")
PY
  a=$(python3 tools/gatecheck.py "$p"); rc2=$?
  cp "$ROOT/templates/REVIEW.md" "$ROOT/templates/DECISIONS.md" "$p/" && python3 - "$p" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
r = (p / "REVIEW.md").read_text(encoding="utf-8")
(p / "REVIEW.md").write_text(r.replace("## 关卡 ① 立意和大纲\n", "## 关卡 ① 立意和大纲\n- 用户授权跳过（2026-10-12）。原话：“你直接做，中间不用我看”\n", 1), encoding="utf-8")
PY
  b=$(python3 tools/gatecheck.py "$p"); rc3=$?
  if [ $rc = 1 ] && [ "$rc4" = 1 ] && [ $rc2 = 0 ] && [ $rc3 = 0 ] && printf '%s' "$a" | grep -q "gate ① decided" && printf '%s' "$b" | grep -q "waived in the user's own words (2026-10-12"
  then ok "gate record: the decision and the concept row pass; an unfilled 定了：{…} with a line after it does not; the user's waiver passes under gate ①, not under gate ③ alone"
  else bad "gate record with the lines filled in ($rc/$rc4/$rc2/$rc3): $a | $b"; fi
  python3 -c "import sys, re; f = sys.argv[1]; s = open(f, encoding='utf-8').read(); open(f, 'w', encoding='utf-8').write(re.sub(r'(?m)^- Effort: standard', '- Effort: quick', s))" "$p/BRIEF.md" && cp "$ROOT/templates/REVIEW.md" "$p/"
  a=$(python3 tools/gatecheck.py "$p"); rc=$?
  [ $rc = 0 ] && printf '%s' "$a" | grep -q "Effort quick" && ok "gate record: a quick project is not checked" || bad "gate record on quick (exit $rc): $a"
  rm -rf "$t"
}

series_checks() {   # bin/vh new --from: the next episode carries the earlier one's spec, style, outline skeleton, STYLE.md,
  # style refs, recipes and sound effects, and its frame and engine unless given; its content is left behind, and so are
  # its budget, effort and director (said instead); a --style given now keeps the episode's own style
  local t p q r u a b rc rc2 rc3 rc4
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  OVH_PROJECTS="$t" vh new short ep1 --aspect 16:9 --style risograph >/dev/null 2>&1; p=$(ls -d "$t"/*-ep1)
  python3 - "$p" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
b = (p / "BRIEF.md").read_text(encoding="utf-8")
for old, new in (("- Output: 1920x1080, {fps} fps, exactly {N}s ({frames} frames)", "- Output: 1920x1080, 30 fps, exactly 60s (1800 frames)"),
                 ("- Platform / audience: {where it plays, who watches, sound-on or muted}", "- Platform / audience: 横屏，泛科普，有声"),
                 ("- Effort: standard ", "- Effort: quick "), ("- Budget: default ", "- Budget: 不限 "),
                 ("- Director: default ", "- Director: hook=own, rest=delegate "), ("- Assets: default ", "- Assets: record "),
                 ("- Concept (one line): {", "- Concept (one line): 第一集的立意 {"),
                 ("| 1 | {按内容起的段名} | {可不写：起 / 承 / 转 / 合} | {0–10 s} | {…} | {…} |", "| 1 | 冷开场设问 | 起 | 0–8 s | 一个问题 | 警笛 |\n| 2 | 回扣 | 合 | 8–60 s | 答案 | 街景 |")):
    assert old in b, old
    b = b.replace(old, new)
(p / "BRIEF.md").write_text(b, encoding="utf-8")
(p / "STYLE.md").write_text("# STYLE\n\n第一集定下的样子。\n", encoding="utf-8")
(p / "STORYBOARD.md").write_text((p / "STORYBOARD.md").read_text(encoding="utf-8") + "\n| # | 配方 | 转场出 |\n|---|---|---|\n| A | black-card | flash-cut |\n| B | 自创 | 硬切 |\n", encoding="utf-8")
(p / "audio" / "events.json").write_text(json.dumps([{"t": 1, "sfx": "whoosh"}, {"t": 2, "sfx": "click"}, {"t": 3, "sfx": "whoosh"}]), encoding="utf-8")
PY
  a=$(OVH_PROJECTS="$t" vh new short ep2 --from ep1 2>&1); rc=$?
  OVH_PROJECTS="$t" vh new short ep3 --from ep1 --aspect 9:16 --effort studio >/dev/null 2>&1; rc2=$?
  OVH_PROJECTS="$t" vh new short ep4 --from no-such-project >/dev/null 2>&1; rc3=$?
  b=$(OVH_PROJECTS="$t" vh new short ep5 --from ep1 --style ink-wash 2>&1); rc4=$?
  q=$(ls -d "$t"/*-ep2 2>/dev/null); r=$(ls -d "$t"/*-ep3 2>/dev/null); u=$(ls -d "$t"/*-ep5 2>/dev/null)
  if [ "$rc:$rc2:$rc3:$rc4" = 0:0:2:0 ] && [ -z "$(ls -d "$t"/*-ep4 2>/dev/null)" ] && python3 - "$p" "$q" "$r" "$u" <<'PY'
import json, sys
from pathlib import Path
p, q, r, u = (Path(x) for x in sys.argv[1:5])
s, s3, s5 = (json.loads((x / "series.json").read_text(encoding="utf-8")) for x in (q, r, u))
b2, b3, b5 = ((x / "BRIEF.md").read_text(encoding="utf-8") for x in (q, r, u))
ok = s["v"] == 1 and Path(s["from"]) == p.resolve() and s["recipes"] == ["black-card", "flash-cut"] and s["unknown"] == ["硬切", "自创"]
ok = ok and s["sfx"] == {"whoosh": 2, "click": 1} and s["style"] and s["style_refs"] == ["risograph"] and s["outline"] == 2
ok = ok and "- Output: 1920x1080, 30 fps, exactly 60s (1800 frames)" in b2 and "- Platform / audience: 横屏，泛科普，有声" in b2 and "- Watch on: desktop" in b2
ok = ok and "第一集的立意" not in b2 and "| 1 | {…} | 起 | 0–8 s | {…} | {…} |" in b2 and "Style refs (repo presets): `styles/risograph`" in b2
ok = ok and (q / "STYLE.md").read_text(encoding="utf-8") == "# STYLE\n\n第一集定下的样子。\n" and (q / "style-refs" / "risograph").is_dir()
ok = ok and "配方 black-card、flash-cut；音效 whoosh ×2、click ×1" in (q / "STORYBOARD.md").read_text(encoding="utf-8")
ok = ok and "沿用 `" + p.name + "`" in (q / "DECISIONS.md").read_text(encoding="utf-8") and not (q / "audio" / "events.json").exists()
# the person's calls stay the template's, the earlier ones said; the licence policy comes over
ok = ok and all(x in b2 for x in ("- Budget: default ", "- Effort: standard ", "- Director: default ", "- Assets: record "))
ok = ok and [h["key"] for h in s["held"]] == ["Budget", "Effort", "Director"] and s["held"][0] == {"key": "Budget", "was": "不限", "now": "default"}
ok = ok and "上一集的 Budget 不限、Effort quick、Director hook=own, rest=delegate 没有带过来" in (q / "DECISIONS.md").read_text(encoding="utf-8")
ok = ok and "- Output: 1080x1920, 30 fps, exactly 60s (1800 frames)" in b3 and "- Watch on: phone" in b3   # --aspect given: its frame, the rest carried
ok = ok and "- Effort: studio " in b3 and [h["key"] for h in s3["held"]] == ["Budget", "Director"]   # --effort given: as given, nothing to say
# --style given: the episode's own Style section, STYLE.md and style refs
ok = ok and not s5["style"] and s5["style_refs"] == [] and "第一集定下的样子" not in (u / "STYLE.md").read_text(encoding="utf-8")
ok = ok and "Style refs (repo presets): `styles/ink-wash`" in b5 and "risograph" not in b5 and sorted(x.name for x in (u / "style-refs").iterdir()) == ["ink-wash"]
sys.exit(0 if ok else 1)
PY
  then case "$a|$b" in *"frame    : 1920x1080"*"not kept : Budget 不限 (the last episode's): this one has default"*"not kept : Effort quick"*"not kept : Director hook=own, rest=delegate"*"carried  : Assets record"*"effort   : standard"*"|"*"style    : --style given"*"the last one had styles/risograph"*)
      ok "new --from: the next episode gets the earlier one's frame, spec, style section, outline skeleton, STYLE.md, style refs, recipes and sound effects (series.json), not its content, nor its budget, effort and director (said, with the licence policy that came); an option given now wins, --style keeps its own style; a project that is not there is a usage error and leaves nothing" ;;
    *) bad "new --from, its lines: $(printf '%s' "$a$b" | grep -v '^ *next\|^              ' | tail -c 900)" ;; esac
  else bad "new --from (exits $rc:$rc2:$rc3:$rc4): $(printf '%s' "$a$b" | tail -c 400)"; fi
  OVH_PROJECTS="$t" vh new short cf1 --engine canvas-film >/dev/null 2>&1; OVH_PROJECTS="$t" vh new short cf2 --from cf1 >/dev/null 2>&1; rc=$?
  q=$(ls -d "$t"/*-cf2 2>/dev/null)
  if [ "$rc" = 0 ] && [ -f "$q/ENGINE_README.md" ] && grep -q '^- Engine: canvas-film' "$q/BRIEF.md"; then ok "new --from a canvas-film project: the episode is canvas-film too"
  else bad "new --from a canvas-film project (exit $rc)"; fi
  # the components an episode names: a folder with a slots.json is one (components/README.md); lib/ and LICENSES/ are not
  mkdir -p "$t/comps/page-turn" "$t/comps/lib" "$t/comps/LICENSES" "$t/ep/src"
  printf '{"version": 1, "name": "page-turn"}' > "$t/comps/page-turn/slots.json"; : > "$t/comps/lib/core.js"; : > "$t/comps/LICENSES/MIT.txt"
  printf '<script type="module" src="components/lib/global.js"></script>\n<script src="components/page-turn/component.js"></script>\n<!-- components/LICENSES/MIT.txt -->\n' > "$t/ep/src/film.html"
  if [ "$(python3 -c 'import sys; sys.path.insert(0, "tools"); import series; print(series.components_used(sys.argv[1], sys.argv[2]))' "$t/ep" "$t/comps")" = "['page-turn']" ]; then
    ok "new --from: the components an episode uses are the folders with a slots.json, not lib/ or LICENSES/"
  else bad "new --from, the components it lists: $(python3 -c 'import sys; sys.path.insert(0, "tools"); import series; print(series.components_used(sys.argv[1], sys.argv[2]))' "$t/ep" "$t/comps" 2>&1)"; fi
  rm -rf "$t"
}

decision_checks() {
  local t p a rc out
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  # new: --dir and $OVH_PROJECTS make the project outside the harness; quick does not promise a review stop
  a=$(vh new math ci-dir --dir "$t/elsewhere" --effort quick 2>&1); rc=$?
  p=$(ls -d "$t"/elsewhere/*-ci-dir 2>/dev/null)
  if [ $rc = 0 ] && [ -n "$p" ] && [ -z "$(ls -d "$ROOT"/projects/*-ci-dir 2>/dev/null)" ]; then ok "new --dir makes the project in that folder"; else bad "new --dir: rc $rc, made '$p'"; fi
  if [ -z "$p" ] || [ ! -d "$p" ]; then   # everything below writes into $p: never let it fall back to /
    bad "decision checks stopped: no project to work in"; rm -rf "$t"; return; fi
  case "$a" in *"stops for your review"*) bad "new --effort quick still says it stops for review" ;; *"renders straight through"*) ok "new --effort quick does not promise a review stop" ;;
    *) bad "new --effort quick: no next-step line in '$a'" ;; esac
  OVH_PROJECTS="$t/env" vh new math ci-env >/dev/null 2>&1 && [ -f "$(ls -d "$t"/env/*-ci-env 2>/dev/null)/BRIEF.md" ] && ok "OVH_PROJECTS sets where projects go" || bad "OVH_PROJECTS ignored"
  vh new math ci-x --aspect 16:9 >/dev/null 2>&1; rc=$?; [ $rc = 2 ] && ok "new --aspect is refused for a non-HyperFrames type" || bad "new math --aspect exited $rc"
  vh new short ci-x --aspect 4:3 >/dev/null 2>&1; rc=$?; [ $rc = 2 ] && ok "new --aspect rejects 4:3" || bad "new --aspect 4:3 exited $rc"
  a=$(vh new short ci-x --aspect 4:5 --res 4k 2>&1); rc=$?; [ $rc = 2 ] && case "$a" in *"no 4K preset for 4:5"*) true ;; *) false ;; esac \
    && ok "new refuses 4K for a 4:5 frame (HyperFrames has no preset)" || bad "new --aspect 4:5 --res 4k (rc $rc): $a"
  a=$(vh new math ci-x --aspect 9:16 2>&1); rc=$?; case "$rc:$a" in 2:*"manim.cfg"*) ok "new --aspect on a Manim type points to manim.cfg" ;; *) bad "new math --aspect (rc $rc): $a" ;; esac
  mkdir -p "$t/hfi"; a=$(vh hf-init "$t/hfi" landscape-4k 2>&1); rc=$?; b=$(vh hf-init "$t/hfi" 2:3 2>&1); rb=$?
  case "$rc:$a|$rb:$b" in 2:*"4K is a render flag"*"|2:"*"unknown frame 2:3"*) [ -z "$(ls -A "$t/hfi")" ] && ok "hf-init refuses a 4K preset and an unknown frame before scaffolding (exit 2)" || bad "hf-init wrote files after refusing" ;;
    *) bad "hf-init frame check ($rc/$rb): $a | $b" ;; esac
  # hf-init's font fix, offline (tools/hfinit.py): the scaffold's stack starts with a generic family (0.8.202) or names
  # Inter (0.8.82), which HyperFrames fills in from Google Fonts at render time; after the fix no family is fetched
  printf '%s\n' '<!doctype html><html><head><style>' '      :root {' '        --font-display: sans-serif;' '      }' \
    '      body { font-family: var(--font-display); }' '      .old { font-family: Inter, sans-serif; }' '</style></head><body></body></html>' > "$t/hfi/index.html"
  python3 tools/hfinit.py check "$t/hfi/index.html" > "$t/hfi/before.txt"; rc=$?
  python3 tools/hfinit.py fonts "$t/hfi/index.html"; rb=$?
  a=$(python3 tools/hfinit.py check "$t/hfi/index.html"); rc2=$?
  if [ "$rc:$rb:$rc2" = "1:0:0" ] && [ -z "$a" ] && grep -q "starts with the generic sans-serif" "$t/hfi/before.txt" && grep -q "names Inter with no @font-face" "$t/hfi/before.txt" \
     && ! grep -qE "fonts\.(googleapis|gstatic)" "$t/hfi/index.html" && grep -q 'src: local("HelveticaNeue")' "$t/hfi/index.html"
  then ok "hf-init's font fix: the scaffold's generic-first and Inter stacks get local @font-face fonts, so HyperFrames fetches none"
  else bad "hf-init font fix ($rc, $rb, $rc2): $(cat "$t/hfi/before.txt") | $a"; fi
  # 4:5: the BRIEF's lines (a pinned version that does not exist makes the scaffold fail fast, offline too; new goes on without it)
  a=$(HYPERFRAMES_VERSION=0.0.0-ci OVH_PROJECTS="$t/a45" vh new short ci-45 --aspect 4:5 2>&1); d=$(ls -d "$t"/a45/*-ci-45 2>/dev/null)
  if [ -n "$d" ] && grep -q '^- Output: 1080x1350,' "$d/BRIEF.md" && grep -q '^- Watch on: phone' "$d/BRIEF.md" && grep -q '画幅 4:5（1080x1350' "$d/BRIEF.md"; then
    case "$a" in *"retry later: bin/vh hf-init"*" 4:5"*) ok "new --aspect 4:5 writes the BRIEF's frame lines, and a failed scaffold's retry hint keeps 4:5" ;; *) bad "new --aspect 4:5 retry hint: $a" ;; esac
  else bad "new --aspect 4:5 BRIEF: $a"; fi
  a=$(vh new handdrawn ci-x --res 4k 2>&1); rc=$?; [ $rc = 2 ] && case "$a" in *"no 4K output"*) true ;; *) false ;; esac && ok "new --res 4k is refused for the hand-drawn engine" || bad "new handdrawn --res 4k exited $rc: $a"
  # the hand-drawn engine's window.film gives its frame rate (PROJECT.fps, else render.mjs's 24), as canvas-film's does
  a=$(node -e 'const vm = require("vm"), fs = require("fs"), out = [];
for (const extra of ["", "PROJECT.fps = 30;"]) {
  const g = vm.createContext({ console, setTimeout }); g.window = g.self = g; g.location = { search: "" };
  vm.runInContext(fs.readFileSync("engines/ClaudeAnimationBase/src/config.js", "utf8").replace("const PROJECT", "var PROJECT") + extra, g);
  vm.runInContext(fs.readFileSync("engines/ClaudeAnimationBase/src/core.js", "utf8"), g); out.push(vm.runInContext("window.film.fps", g)); }
console.log(out.join(" "))' 2>&1)
  [ "$a" = "24 30" ] && ok "ClaudeAnimationBase: window.film.fps is PROJECT.fps, 24 without it" || bad "ClaudeAnimationBase window.film.fps (want 24 30): $a"
  a=$(vh new short ci-x --watch tv 2>&1); rc=$?; [ $rc = 2 ] && case "$a" in *"unknown --watch"*) true ;; *) false ;; esac && ok "new --watch rejects an unknown target" || bad "new --watch tv exited $rc: $a"
  a=$(vh new short ci-x --watch feed 2>&1); rc=$?; [ $rc = 2 ] && case "$a" in *"already --watch phone"*) true ;; *) false ;; esac && ok "new refuses a feed target for a vertical frame" || bad "new short --watch feed exited $rc: $a"
  a=$(vh new promo ci-x --watch phone 2>&1); rc=$?; [ $rc = 2 ] && case "$a" in *"--watch feed"*) true ;; *) false ;; esac && ok "new refuses a phone target for a landscape frame" || bad "new promo --watch phone exited $rc: $a"
  vh new math ci-x --watch phone >/dev/null 2>&1; rc=$?; [ $rc = 2 ] && ok "new refuses a phone target for a Manim (landscape) type" || bad "new math --watch phone exited $rc"
  for bad_style in "dark-math,_swatch" "Dark-Math" "../styles/ink-wash" ","; do
    vh new math ci-x --style "$bad_style" >/dev/null 2>&1; rc=$?; [ $rc = 2 ] || bad "new --style '$bad_style' exited $rc"; done
  ok "new --style rejects a bad name anywhere in the list, paths and an empty list"
  [ -z "$(ls -d "$ROOT"/projects/*-ci-x 2>/dev/null)" ] || bad "a refused new left a project behind"
  # new: where it is watched and the output resolution land in the BRIEF (defaults from the frame, flags override)
  if grep -q '^- Watch on: desktop' "$p/BRIEF.md" && grep -q '^- Resolution: 1080p' "$p/BRIEF.md" \
    && OVH_PROJECTS="$t/w" vh new math ci-w --watch feed --res 4k >/dev/null 2>&1 \
    && grep -q '^- Watch on: feed' "$(ls -d "$t"/w/*-ci-w)/BRIEF.md" && grep -q '^- Resolution: 1080p, 4k' "$(ls -d "$t"/w/*-ci-w)/BRIEF.md" \
    && OVH_PROJECTS="$t/w2" vh new edit ci-e --res 4K >/dev/null 2>&1 && grep -q '^- Watch on: phone' "$(ls -d "$t"/w2/*-ci-e)/BRIEF.md" \
    && grep -q '^- Resolution: 1080p, 4k' "$(ls -d "$t"/w2/*-ci-e)/BRIEF.md"; then ok "new writes Watch on and Resolution into the BRIEF (defaults, flags, the 4K alias)"
  else bad "new: Watch on / Resolution missing or wrong in the BRIEF"; fi
  # style apply: presets are references; two attach side by side, re-attaching one adds nothing; by name under OVH_PROJECTS
  vh style apply blueprint "$p" >/dev/null && vh style apply ink-wash "$p" >/dev/null && OVH_PROJECTS="$t/elsewhere" vh style apply ink-wash ci-dir >/dev/null
  if grep -q '^- Style refs (repo presets): `styles/blueprint`, `styles/ink-wash`  <!--' "$p/BRIEF.md" && ! grep -q '^## Style preset' "$p/BRIEF.md" \
    && [ "$(grep -c '^> 参考的风格预设：`styles/blueprint`、`styles/ink-wash`' "$p/STYLE.md")" = 1 ] && [ "$(grep -c '风格参考 · ' "$p/DECISIONS.md")" = 2 ] \
    && [ -f "$p/style-refs/blueprint/tokens.json" ] && [ -f "$p/style-refs/ink-wash/STYLE.md" ]; then ok "style apply attaches presets as references, side by side, without repeats"
  else bad "style apply: references missing, repeated, or an instruction block pasted into the BRIEF"; fi
  # a comma list in one call, and a project made the old way (STYLE_PRESET.md + a pasted block + the 为底 pointer) keeps its base as a reference
  if OVH_PROJECTS="$t/m" vh new math ci-m >/dev/null 2>&1; then
    q=$(ls -d "$t"/m/*-ci-m)
    cp "$ROOT/styles/cutout-jazz/STYLE.md" "$q/STYLE_PRESET.md"; cp "$ROOT/styles/cutout-jazz/tokens.json" "$q/style.tokens.json"
    printf '\n\n## Style preset: cutout-jazz\n\n```text\nold block\n```\n' >> "$q/BRIEF.md"
    { printf '> 本项目以风格预设 `styles/cutout-jazz` 为底：先读 `STYLE_PRESET.md`。\n\n'; cat "$q/STYLE.md"; } > "$q/STYLE.md.new" && mv "$q/STYLE.md.new" "$q/STYLE.md"
    vh style apply blueprint,ink-wash "$q" >/dev/null 2>&1
    if [ -f "$q/style-refs/cutout-jazz/STYLE.md" ] && [ -f "$q/style-refs/cutout-jazz/tokens.json" ] && [ ! -e "$q/STYLE_PRESET.md" ] \
      && grep -q '^- Style refs (repo presets): `styles/cutout-jazz`, `styles/blueprint`, `styles/ink-wash`' "$q/BRIEF.md" \
      && ! grep -q '^## Style preset' "$q/BRIEF.md" && ! grep -q '为底' "$q/STYLE.md" && [ "$(grep -c '风格参考 · ' "$q/DECISIONS.md")" = 3 ]; then
      ok "style apply a,b: one call attaches both; an old base preset becomes a reference"
    else bad "style apply: comma list or migration of an old project's preset failed"; fi
  else bad "new math ci-m failed"; fi
  vh style apply no-such-style "$p" >/dev/null 2>&1; rc=$?; [ $rc = 2 ] && ok "style apply rejects an unknown preset" || bad "style apply unknown preset exited $rc"
  # readcheck: a budget, and the timed text of a composition without a browser
  a=$(vh readcheck --budget 3.2)
  case "$a" in *"normal pace"*"up to 14 CJK"*"one brisk read"*"up to 16 CJK"*"up to 28 CJK"*) ok "readcheck --budget: the pace's target, the floor, subtitles" ;; *) bad "readcheck --budget 3.2 said: $a" ;; esac
  # no fixed seconds: under one brisk read (CJK/7 + other/20 + 0.8 s, at least 1.5 s) FAILs; under the pace's target only WARNs
  tl=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  printf '%s' '[{"id":"a","text":"CLAUDE.md router","start":0,"end":1.6,"read":"label"},{"id":"b","text":"CLAUDE.md router","start":0,"end":1.6},' \
    '{"id":"c","text":"CLAUDE.md router","start":0,"end":1.6,"pace":"brisk"}]' > "$tl/label.json"
  a=$(vh readcheck "$tl/label.json"); rc=$?
  case "$rc:$a" in 0:*"OK   a"*"lab"*"WARN b"*"normal  1.63s"*"OK   c"*"pace normal, default"*"3/3 pass · 1 WARN"*)
      ok "readcheck: under the pace's target is a WARN (exit 0); a label and a brisk text need one read" ;; *) bad "readcheck WARN band (rc $rc): $a" ;; esac
  printf '%s' '[{"id":"f","text":"CLAUDE.md router","start":0,"end":1.2},{"id":"g","text":"短","start":2,"end":2.9}]' > "$tl/flash.json"
  a=$(vh readcheck "$tl/flash.json"); rc=$?
  case "$rc:$a" in 1:*"FAIL f"*"floor  1.55s"*"FAIL g"*"floor  1.50s"*"2 FAIL"*) ok "readcheck: under the floor FAILs, and nothing passes under 1.5 s" ;; *) bad "readcheck floor (rc $rc): $a" ;; esac
  printf '%s\n' '# BRIEF' '- Pace: relaxed  <!-- relaxed | normal | brisk -->' > "$tl/BRIEF.md"
  a=$(vh readcheck "$tl/label.json"); b=$(vh readcheck "$tl/label.json" --pace brisk); rc=$?
  case "$a" in *"WARN b"*"relaxed  2.00s"*"pace relaxed, Pace in"*)
      case "$rc:$b" in 0:*"OK   b"*"pace brisk, --pace"*) ok "readcheck takes the pace from the BRIEF, and --pace overrides it" ;; *) bad "readcheck --pace brisk (rc $rc): $b" ;; esac ;;
    *) bad "readcheck with a BRIEF Pace: $a" ;; esac
  printf '%s' '[{"id":"x","text":"t","start":0,"end":2,"pace":"fast"}]' > "$tl/badpace.json"
  vh readcheck "$tl/badpace.json" >/dev/null 2>&1; rc=$?
  [ $rc = 2 ] && ok "readcheck refuses a pace that is not relaxed, normal or brisk" || bad "readcheck with a pace of \"fast\" exited $rc"
  # a project's audio/captions.json (what bin/vh captions writes) is the narration: the subtitle rule, unless --mode says otherwise
  mkdir -p "$tl/cap/audio"
  printf '%s' '[{"id":"a","start":0,"end":2.4,"zh":["慢慢地说一句话"]},{"id":"b","start":2.4,"end":3.1,"zh":["这一句太短"]}]' > "$tl/cap/audio/captions.json"
  a=$(vh readcheck "$tl/cap"); rc=$?; b=$(vh readcheck "$tl/cap" --mode onscreen)
  case "$rc:$a" in 1:*"OK   a·zh"*"need   1.80s"*"FAIL b·zh"*"readcheck (subtitle)"*)
      case "$b" in *"readcheck (onscreen"*) ok "readcheck <project> judges its captions by the subtitle rule; --mode still decides" ;; *) bad "readcheck <project> --mode onscreen: $b" ;; esac ;;
    *) bad "readcheck on a project's captions (rc $rc): $a" ;; esac
  # an exported CDPATH must not move bin/vh's own cd (run as bin/vh, its folder is relative)
  mkdir -p "$tl/cdpath/bin"
  a=$(cd "$ROOT" && CDPATH="$tl/cdpath" "$VH_BASH" bin/vh effort standard 2>&1); rc=$?
  [ $rc = 0 ] && printf '%s' "$a" | grep -q '人工关卡' && ok "bin/vh ignores an exported CDPATH" || bad "bin/vh under a CDPATH (exit $rc): $(printf '%s' "$a" | head -3)"
  rm -rf "$tl"
  printf '%s\n' '<html><body><div id="root" data-composition-id="m" data-start="0" data-duration="10">' \
    '<section id="s" class="clip" data-start="0" data-duration="10"><h1 id="t">script-driven</h1></section>' \
    '<div id="c1" class="clip" data-start="1" data-duration="4"><span>四个汉字</span></div>' \
    '<div id="c2" class="clip" data-start="6" data-duration="1.2">太短了的字</div></div><script>var x="<div>";</script></body></html>' > "$p/index.html"
  a=$(vh readcheck "$p/index.html"); rc=$?
  case "$rc:$a" in 1:*"OK   c1"*"FAIL c2"*"pace relaxed, Pace in"*"NOT checked: 1 text block"*) ok "readcheck reads a composition's clips and the new project's Pace (a math project: relaxed; and says what it left out)" ;; *) bad "readcheck index.html (rc $rc): $a" ;; esac
  vh readcheck --export "$p" >/dev/null && grep -q '"id": "c2"' "$p/texts.json" && { vh readcheck "$p" --export >/dev/null 2>&1; [ $? = 2 ]; } \
    && ok "readcheck --export writes texts.json and will not overwrite it" || bad "readcheck --export"
  mkdir "$t/hf-exports"
  a=$(vh readcheck --out "$t/hf-exports" --export "$p/index.html" 2>&1); rc=$?
  if [ $rc = 0 ] && grep -q '"id": "c2"' "$t/hf-exports/texts.json" \
    && vh readcheck "$p/index.html" --export --out "$t/hf-exports" --force >/dev/null
  then ok "readcheck: HyperFrames --export keeps custom folders, argument order and --force"
  else bad "readcheck HyperFrames custom export (exit $rc): $a"; fi
  # HyperFrames timing the way HyperFrames resolves it: "id", "id+n", a sub-composition's <template>, a typo'd reference
  mkdir -p "$t/rel/sub"
  printf '%s\n' '<html><body><div id="root" data-composition-id="m" data-start="0" data-duration="12">' \
    '<div id="a" data-start="1" data-duration="3"><h1>第一句标题文字</h1></div>' \
    '<div id="b" data-start="a" data-duration="0.8"><p>第二句</p></div>' '<div id="c" data-start="b + 0.5" data-duration="1"><p>第三句</p></div>' \
    '<div id="x" data-start="typo" data-duration="1"><p>没有这个片段</p></div>' \
    '<div id="host" data-start="6" data-duration="4" data-composition-src="sub/child.html"></div></div></body></html>' > "$t/rel/index.html"
  printf '%s\n' '<template id="t"><div data-composition-id="child" data-duration="4">' \
    '<div id="k1" data-start="0.5" data-duration="1"><span>子合成里的字</span></div></div></template>' > "$t/rel/sub/child.html"
  a=$(vh readcheck "$t/rel/index.html")
  case "$a" in *"a "*"1.00–   4.00s"*"b "*"4.00–   4.80s"*"c "*"5.30–   6.30s"*"k1"*"6.50–   7.50s"*"NOT checked"*"typo"*)
      case "$a" in *"every timed text"*) bad "readcheck claims it checked everything: $a" ;; *) ok "readcheck resolves relative starts and sub-composition templates" ;; esac ;;
    *) bad "readcheck relative / template timing: $a" ;; esac
  # with the project's own hyperframes the spans are HyperFrames' (a stand-in prints its timeline), from a relative path too
  mkdir -p "$t/rel/node_modules/.bin"
  cat > "$t/rel/node_modules/.bin/hyperframes" <<'SH'
#!/bin/sh
echo '{"timeline": {"tracks": [{"rows": [{"id": "a", "absStart": 2, "absEnd": 5.5, "file": "index.html"}]}]}}'
SH
  chmod +x "$t/rel/node_modules/.bin/hyperframes"
  a=$(cd "$t" && vh readcheck rel/index.html)
  case "$a" in *"a "*"2.00–   5.50s"*"HyperFrames' own timeline"*) ok "readcheck takes the spans from the project's hyperframes timeline" ;;
    *) bad "readcheck with a project hyperframes: $a" ;; esac
  if ! command -v uv >/dev/null || ! command -v ffmpeg >/dev/null; then skip "storyboard · rhythm · style compare · cover-preview · music --roll" "needs uv and ffmpeg"; rm -rf "$t"; return; fi
  # a small project: 3 shots (one over the type's 5 s, one unsure), a video, narration, captions (one too short) and a score
  printf '%s\n' '# BRIEF' '<!-- from 02-knowledge-short.md -->' > "$p/BRIEF.md"; rm -f "$p/texts.json"
  printf '%s\n' '[{"id": "S1", "start": 0, "end": 2, "segment": "hook", "reads": "a title"},' \
    '{"id": "S2", "start": 2, "end": 8.5, "segment": "body", "reads": ["a long shot", "second read"], "unsure": "too slow?"},' \
    '{"id": "S3", "start": 8.5, "end": 10, "segment": "body", "reads": "the end"}]' > "$p/shots.json"
  ffmpeg -nostdin -v error -f lavfi -i testsrc=s=320x180:d=10:r=10 -pix_fmt yuv420p "$p/out/final.mp4"
  printf '%s\n' '{"segments": [{"id": "l1", "text": "first line of narration", "start": 0.2, "end": 3.9}, {"id": "l2", "text": "second", "start": 4.2, "end": 9.5}]}' > "$p/audio/timeline.json"
  printf '%s\n' '[{"id": "l1", "start": 0.2, "end": 3.9, "en": ["first line of narration"]}, {"id": "l2", "start": 4.2, "end": 5.0, "en": ["second"]}]' > "$p/audio/captions.json"
  printf '%s\n' '{"bpm": 120, "key": "C", "mode": "major", "seed": 1, "sections": [{"name": "a", "bars": 2, "chords": ["I", "V"], "layers": ["pad"]},' \
    '{"name": "b", "bars": 3, "chords": ["vi", "IV", "V"], "layers": ["pad"]}], "parts": [{"inst": "piano", "pattern": [[0, 1, "c0"], [1, 1, "c2"], [2, 2, "c1"]]}]}' > "$p/audio/score.json"
  if vh music "$p/audio/score.json" "$p/audio/music.wav" --length auto --roll >/dev/null; then
    a=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$p/audio/music.wav")
    python3 -c "import json, sys; b = json.load(open(sys.argv[1])); sys.exit(0 if abs(float(sys.argv[2]) - 10) < 0.01 and b['fade']['end'] == 10.0 and max(b['beats']) < 10 and b['bars'] == [[k + 1, k * 2, 4] for k in range(5)] else 1)" "$p/audio/music.beats.json" "$a" \
      && ok "music --length auto ends where the last bar ends, with a fade" || bad "music --length auto: $a s, beat map $(head -c 200 "$p/audio/music.beats.json")"
    [ -s "$p/audio/music.roll/overview.png" ] && [ -s "$p/audio/music.roll/01-piano-0.png" ] && ok "music --roll draws an overview and a page per part" || bad "music --roll pictures missing"
    vh music "$p/audio/score.json" "$t/m7.wav" --length 7 >/dev/null && a=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$t/m7.wav") \
      && python3 -c "import sys; sys.exit(0 if abs(float(sys.argv[1]) - 7) < 0.01 else 1)" "$a" && ok "music --length 7 trims the render to 7 s" || bad "music --length 7 gave '$a' s"
  else bad "bin/vh music --length auto --roll"; fi
  # at 60 bpm a bar is 4 s: the fade still starts on a beat, 1-3 s before the end
  printf '%s\n' '{"bpm": 60, "key": "C", "mode": "major", "seed": 1, "sections": [{"name": "a", "bars": 4, "chords": ["I", "V", "vi", "IV"], "layers": ["pad"]}]}' > "$t/s60.json"
  vh music "$t/s60.json" "$t/m60.wav" --length 9.5 >/dev/null \
    && python3 -c "import json, sys; f = json.load(open(sys.argv[1]))['fade']; s = f['start']; sys.exit(0 if s == round(s) and 6.5 <= s <= 8.5 and f['end'] == 9.5 else 1)" "$t/m60.beats.json" \
    && ok "music --length at 60 bpm fades from a beat" || bad "music --length 9.5 at 60 bpm: $(head -c 300 "$t/m60.beats.json" 2>/dev/null)"
  # a section stop, a cresc and a pickup (motif-era scores): --roll draws them, --length fades from a beat and keeps the stop: hit
  printf '%s\n' '{"bpm": 100, "key": "D", "mode": "major", "seed": 1, "sections": [{"name": "a", "bars": 2, "chords": ["I", "V"], "stop": {"at": "2:3", "keep": ["pad"]}},' \
    '{"name": "b", "bars": 2, "chords": ["IV", "I"]}], "parts": [{"inst": "strings", "id": "pad", "figure": "sustain", "octave": 3, "gain_db": -14},' \
    '{"inst": "brass", "sections": ["a"], "octave": 4, "by_section": {"a": {"cresc": [-8, 0]}}, "pattern": [[0, 1, "d1"], [1, 1, "d3"], [2, 1, "d5"], [3, 1, "d3"]]},' \
    '{"inst": "celesta", "sections": ["b"], "octave": 5, "loop": 2, "pattern": [[-1, 1, "d5"], [0, 2, "d1"], [2, 2, "d3"]]}]}' > "$t/stop.json"
  if vh music "$t/stop.json" "$t/stop.wav" --roll --length 8 >/dev/null && [ -s "$t/stop.roll/overview.png" ] && [ -s "$t/stop.roll/03-celesta-0.png" ] \
    && python3 -c "import json, sys; b = json.load(open(sys.argv[1])); f = b['fade']; sys.exit(0 if f['end'] == 8.0 and any(abs(f['start'] - x) < 1e-6 for x in b['beats']) and [h['t'] for h in b['hits'] if h['what'] == 'stop:a'] == [3.6] else 1)" "$t/stop.beats.json"
  then ok "music --roll and --length with a section stop, a cresc and a pickup"; else bad "music with a stop: $(head -c 300 "$t/stop.beats.json" 2>/dev/null)"; fi
  # a score written for another engine (showcase 04's own score_engine.py: bars as [first, last]) or a list: one line, exit 2
  printf '[]' > "$t/list.json"; a=""
  for f in showcase/04-intro-film/audio/score.json showcase/04-intro-film/audio/score.base.json "$t/list.json"; do
    b=$(vh music "$f" "$t/foreign.wav" 2>&1); rc=$?
    case "$rc:$b" in *Traceback*|*Error*) a="$a | $f: $b" ;; "2:music: $f: not a score bin/vh music reads"*'"sections": [{"name"'*)
        case "$f:$b" in *score*.json:*'"engine" is audio/score_engine.py'*|*list.json:*"(a JSON list)"*) ;; *) a="$a | $f does not say why: $b" ;; esac ;;
      *) a="$a | $f (rc $rc): $b" ;; esac
  done
  [ -z "$a" ] && [ ! -e "$t/foreign.wav" ] && ok "music: another engine's score (bars as [first, last]) or a list says it is not one it reads, and what it reads" \
    || bad "music on a foreign score:$a"
  # the part voices that used to stop on a non-zero sample (taiko, saw_pluck, edm_clap, edm_hat) end on zero, every voice does
  if a=$(uv run -q --no-project --with numpy --with scipy python - 2>&1 <<'PY'
import sys
import numpy as np
sys.path.insert(0, "tools/audio"); import music, instruments as ins
R = lambda *k: np.random.default_rng([7, *k]); bad = []
for name, sp in sorted(ins.INSTR.items()):
    for d in (0.12, 0.5):
        for art in ("", "o"):
            if sp.kind == "note": x = sp.fn(60, d, 0.8, R(1), dict(sp.defaults))
            elif sp.kind == "drum": x = sp.fn(0.8, art, d, R(1), dict(sp.defaults), None)
            else: continue
            x = np.asarray(x)
            if np.abs(x[..., -1]).max() > 1e-3 * np.abs(x).max(): bad.append(f"{name} ({d} s{', ' + art if art else ''})")
print(", ".join(sorted(set(bad)))); sys.exit(1 if bad else 0)
PY
  ); then ok "music: every note and drum voice ends on (near) zero, so a note-off is not a click"; else bad "music voices that end abruptly: $a"; fi
  # beats lifts: a breath (0.8 s, 22 dB down, no hits) and the hit after it is the one candidate, ±2 frames; a fade at the end is not one
  if a=$(uv run -q --no-project --with numpy --with scipy python - 2>&1 <<'PY'
import sys
import numpy as np
sys.path.insert(0, "tools/audio"); import beats
SR = 22050; rng = np.random.default_rng(1); n = int(12 * SR); t = np.arange(n) / SR
gain = np.ones(n); gain[(t >= 6.2) & (t < 7.0)] = 0.08; gain[t >= 11.0] = np.linspace(1, 0.05, int((t >= 11.0).sum()))
y = (0.1 * np.sin(2 * np.pi * 110 * t) + 0.03 * rng.standard_normal(n)) * gain; ev = []
for k in range(24):                                   # a hit every 0.5 s, none in the breath or the fade
    b = k * 0.5
    if 6.2 <= b < 7.0 or b >= 11.0: continue
    i, m = int(b * SR), int(0.08 * SR)
    y[i:i + m] += (0.9 if b == 7.0 else 0.4) * np.exp(-np.arange(m) / (0.015 * SR)) * rng.standard_normal(m)
    ev.append({"t": b, "strength": 1.0 if b == 7.0 else 0.6, "on": ["hits"]})
L = beats.lifts(y, SR, ev)
ok = len(L) == 1 and abs(L[0]["t"] - 7.0) <= 2 / 30 and 6.2 <= L[0]["dip"] < 7.0 and L[0]["strength"] > 0.5
merged = beats.accents({"downbeats": [7.01], "hits": [{"t": 7.0, "strength": 0.9}, {"t": 3.0, "strength": 0.2}]})
ok = ok and merged == [{"t": 7.0, "strength": 0.9, "on": ["downbeat", "hits"]}]
print(L, merged); sys.exit(0 if ok else 1)
PY
  ); then ok "beats lifts: the hit after a breath is the one candidate (±2 frames), a fade-out is not; a downbeat and a hit 10 ms apart are one accent"
  else bad "beats lifts: $a"; fi
  # storyboard: a page per segment + an overview; the unsure and the long shot are flagged; the same input, the same bytes
  # review.json is tools/review.py's shape: a gate JSON that includes it builds the page
  if vh storyboard "$p" >/dev/null && mkdir -p "$p/out/review" \
    && printf '%s\n' '{"summary": "ci", "decisions": [], "include": "out/check/storyboard/review.json"}' > "$p/out/review/gate-2.json" \
    && a=$(vh review "$p" 2 2>&1) && grep -q '"frame": "out/check/storyboard/frames/S2.png"' "$p/out/check/storyboard/review.json"; then
    case "$a" in *"2 segment(s)"*"3 shot(s)"*"S2"*) ok "storyboard review.json feeds bin/vh review through include" ;; *) bad "review with include said: $a" ;; esac
  else bad "storyboard review.json + bin/vh review: $a"; fi
  # a duplicate id stops it; a shot the video never reaches gets a grey tile, not the clamped last frame
  printf '%s\n' '[{"id": "D", "start": 0, "end": 1}, {"id": "D", "start": 1, "end": 2}]' > "$t/dup.json"
  vh storyboard "$p" --shots "$t/dup.json" >/dev/null 2>&1; rc=$?; [ $rc != 0 ] && ok "storyboard rejects a duplicate shot id" || bad "storyboard took a duplicate id"
  printf '%s\n' '[{"id": "P1", "start": 0, "end": 4}, {"id": "P2", "start": 4, "end": 9}, {"id": "P3", "start": 9, "end": 14}]' > "$t/past.json"
  a=$(vh storyboard "$p" --shots "$t/past.json" --out "$t/sbpast" 2>&1)
  case "$a" in *"past the end of out/final.mp4"*"P3"*) [ ! -f "$t/sbpast/frames/P3.png" ] && ok "storyboard leaves a shot past the end of the video grey" || bad "storyboard grabbed a frame past the end" ;;
    *) bad "storyboard past the end: $a" ;; esac
  # inside a uv project (bin/vh new math suggests uv init) the tools still run: uv must not sync that project
  mkdir -p "$t/uvp" && printf '%s\n' '[project]' 'name = "uvp"' 'version = "0"' 'dependencies = ["this-package-does-not-exist-xyz==1.0"]' > "$t/uvp/pyproject.toml"
  (cd "$t/uvp" && vh storyboard "$p" >/dev/null 2>&1) && [ ! -e "$t/uvp/uv.lock" ] && ok "bin/vh's uv runs ignore the project they are started in" || bad "uv run synced the surrounding project"
  # 26 shots at 6 a page split evenly (5 5 5 5 6), not 6 6 6 6 and a page of 2
  python3 -c "import json; print(json.dumps([{'id': 'E%02d' % i, 'start': i * 0.3, 'end': i * 0.3 + 0.3} for i in range(26)]))" > "$t/even.json"
  vh storyboard "$p" --shots "$t/even.json" --out "$t/sbeven" >/dev/null 2>&1 \
    && python3 -c "import json, sys; i = json.load(open(sys.argv[1])); sys.exit(0 if [len(x['shots']) for x in i['pages']] == [5, 5, 5, 5, 6] else 1)" "$t/sbeven/index.json" \
    && ok "storyboard splits 26 shots 5-5-5-5-6" || bad "storyboard page split: $(head -c 400 "$t/sbeven/index.json" 2>/dev/null)"
  if vh storyboard "$p" >/dev/null && cp "$p/out/check/storyboard/overview.png" "$t/ov1.png" && vh storyboard "$p" >/dev/null; then
    [ -s "$p/out/check/storyboard/01-hook.png" ] && [ -s "$p/out/check/storyboard/02-body.png" ] \
      && python3 -c "import json, sys; i = json.load(open(sys.argv[1])); p = i['pages'][1]; sys.exit(0 if p['unsure'] == ['S2'] and p['long'] == ['S2'] and i['limit_s'] == 5 else 1)" "$p/out/check/storyboard/index.json" \
      && ok "storyboard: a page per segment, the unsure and the too-long shot flagged" || bad "storyboard pages or flags: $(cat "$p/out/check/storyboard/index.json")"
    cmp -s "$t/ov1.png" "$p/out/check/storyboard/overview.png" && ok "storyboard is deterministic" || bad "storyboard gave different bytes on a second run"
  else bad "bin/vh storyboard"; fi
  # a shot's camera (recipes/shot/'s codes, or a card's id) under its id and in review.json, by the cards' names in Chinese
  # and their codes in English; a value that is no card's code is printed as written and said; edit init carries it over
  printf '%s\n' '[{"id": "C1", "start": 0, "end": 2, "segment": "开场", "reads": "一座塔", "camera": {"size": "EWS", "angle": "low", "move": "push-in"}},' \
    '{"id": "C2", "start": 2, "end": 4, "segment": "开场", "reads": "灯", "camera": {"size": "close-up", "axis": "hold"}},' \
    '{"id": "C3", "start": 4, "end": 6, "segment": "开场", "reads": "拉开", "camera": {"size": "XL", "move": "pull-out"}}]' > "$t/cam.json"
  a=$(vh storyboard "$p" --shots "$t/cam.json" --out "$t/sbcam" 2>&1); b=$(vh storyboard "$p" --shots "$t/cam.json" --lang en --out "$t/sbcam-en" 2>&1)
  mkdir -p "$t/camp" && printf '# BRIEF\n' > "$t/camp/BRIEF.md" && cp "$t/cam.json" "$t/camp/shots.json" && vh edit init "$t/camp" >/dev/null 2>&1 \
    && vh storyboard "$t/camp" --out "$t/sbcam-edit" >/dev/null 2>&1
  cams() { python3 -c 'import json, sys; print(" | ".join(s.get("camera", "-") for g in json.load(open(sys.argv[1]))["segments"] for s in g["shots"]))' "$1"; }
  codes() { python3 -c 'import json, sys; print(json.dumps([s.get("camera_codes") for g in json.load(open(sys.argv[1]))["segments"] for s in g["shots"]], sort_keys=True))' "$1"; }
  # edit check reads a camera as the storyboard does: another shape fails, a code no card has is said
  c=$(vh edit check "$t/camp" 2>&1)
  python3 -c 'import json, sys; f = sys.argv[1]; d = json.load(open(f)); d["tracks"][0]["entries"][0]["camera"] = 5; json.dump(d, open(f, "w"))' "$t/camp/edit.json"
  d=$(vh edit check "$t/camp" 2>&1); rc=$?
  if [ "$(cams "$t/sbcam/review.json")" = "大远景 · 仰拍 · 推 | 特写 · 守轴线 | XL · 拉" ] && [ "$(cams "$t/sbcam-en/review.json")" = "EWS · low · push-in | CU · hold | XL · pull-out" ] \
     && [ "$(cams "$t/sbcam-edit/review.json" 2>/dev/null)" = "大远景 · 仰拍 · 推 | 特写 · 守轴线 | XL · 拉" ] && grep -q "C3 size 'XL'" <<<"$a" && ! grep -q "C1" <<<"$a$b" \
     && [ "$(codes "$t/sbcam/review.json")" = "$(codes "$t/sbcam-en/review.json")" ] \
     && [ "$(codes "$t/sbcam/review.json")" = '[{"angle": "low", "move": "push-in", "size": "EWS"}, {"axis": "hold", "size": "CU"}, {"move": "pull-out", "size": "XL"}]' ] \
     && grep -q 'C3: camera.size "XL": no shot-grammar card' <<<"$c" && ! grep -q "C1: camera" <<<"$c" && [ "$rc" = 1 ] && grep -q "C1: camera 5: a sentence, or" <<<"$d"
  then ok "storyboard: a shot's camera under its id and in review.json (the cards' names, their codes in English, the codes alone in camera_codes); an unknown value is said and printed as written; edit init carries it, and edit check reads it as the storyboard does"
  else bad "storyboard's camera: [$(cams "$t/sbcam/review.json" 2>&1)] [$(cams "$t/sbcam-en/review.json" 2>&1)] [$(cams "$t/sbcam-edit/review.json" 2>&1)] [$(codes "$t/sbcam/review.json" 2>&1)] edit check $rc | $(printf '%s' "$a" | head -c 300) | $(printf '%s' "$c$d" | tail -c 300)"; fi
  a=$(vh rhythm "$p")
  case "$a" in *"S2 6.5 s > 5 s"*"l2"*"0.8 s < 1.8 s"*) [ -s "$p/out/check/rhythm.png" ] && ok "rhythm: long shot and short caption in red" || bad "rhythm.png missing" ;; *) bad "rhythm said: $a" ;; esac
  vh rhythm "$p" --segment body >/dev/null && [ -s "$p/out/check/rhythm-body.png" ] && ok "rhythm --segment zooms in" || bad "rhythm --segment"
  printf '%s\n' '{"segments": [{"id": "e1", "text": "an English line", "start": 0.5, "end": 2.0}]}' > "$p/audio/timeline.en.json"
  a=$(vh rhythm "$p" --lang en)
  case "$a" in *"from: "*"audio/timeline.en.json"*) ok "rhythm --lang en reads timeline.en.json" ;; *) bad "rhythm --lang en: $a" ;; esac
  vh style compare blueprint,ink-wash --out "$t/sc.png" >/dev/null && vh style compare blueprint,ink-wash --frame 2 --out "$t/sc2.png" >/dev/null && [ -s "$t/sc.png" ] && [ -s "$t/sc2.png" ] \
    && ok "style compare: posters and swatch frames" || bad "bin/vh style compare"
  vh style compare blueprint,no-such >/dev/null 2>&1; rc=$?; [ $rc = 2 ] && ok "style compare rejects an unknown preset (exit 2)" || bad "style compare on an unknown preset exited $rc"
  out=$(vh cover-preview "$ROOT/styles/blueprint/media/poster.jpg" --out "$t/cover.png")
  case "$out" in *"smallest text"*"title stroke "*" px at the smallest slot"*|*"no text line found"*) [ -s "$t/cover.png" ] && ok "cover-preview draws the feed sizes and a legibility line (with the title's stroke width at the smallest slot)" || bad "cover-preview wrote nothing" ;; *) bad "cover-preview said: $out" ;; esac
  rm -rf "$t"
}

# the review desk (bin/vh desk, tools/desk/README.md): its reader on the committed fixtures (zh, and en with a NOTES.md
# whose table is missing, which must come back as text), a server on a free port (the page, the data, a 206 range, and
# what it refuses), a submission that wakes bin/vh desk wait and lands verbatim in REVIEW.md, the watcher's timeout,
# bin/vh new --lang, and bin/vh review's language default
desk_start() { # desk_start <project> <log>: bin/vh desk on a free port in the background; sets desk_pid and desk_url
  local i a; desk_url=""
  "$VH_BASH" "$ROOT/bin/vh" desk "$1" --port 0 > "$2" 2>&1 & desk_pid=$!   # bin/vh execs python: $! is the server
  for i in $(seq 150); do   # up to 30 s; stop early if the server exits
    desk_url=$(sed -n 's#^desk: \(http://127\.0\.0\.1:[0-9]*/\).*#\1#p' "$2"); [ -n "$desk_url" ] && return 0
    kill -0 "$desk_pid" 2>/dev/null || break; sleep 0.2; done
  if kill -0 "$desk_pid" 2>/dev/null; then a="no address after 30 s, still running"; kill "$desk_pid" 2>/dev/null; wait "$desk_pid" 2>/dev/null
  else wait "$desk_pid"; a="exited with $?"; fi
  bad "desk server for $(basename "$1") did not start ($a); its output: $(tr '\n' ' ' < "$2" | head -c 800)$([ -s "$2" ] || echo '(none)')"
  return 1
}
desk_checks() {
  local t pid wpid url i rc a
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  vh desk data tools/desk/fixtures/zh > "$t/zh.json" && vh desk data tools/desk/fixtures/en > "$t/en.json"
  if python3 - "$t/zh.json" "$t/en.json" <<'PY'
import json, sys
zh, en = (json.load(open(p, encoding="utf-8")) for p in sys.argv[1:3])
bad = []
def want(cond, what):
    if not cond: bad.append(what)
o = zh["outline"]
want(zh["lang"] == "zh" and zh["project"]["title"] == "一杯水的旅程" and zh["project"]["effort"] == "studio", "zh: lang, title, effort")
want([x["title"] for x in o] == ["拧开水龙头", "水厂和管道", "落进杯子"] and [x["tag"] for x in o] == ["起", "承", "合"], "zh: outline titles and tags")
want([(x["t0"], x["t1"]) for x in o] == [(0, 8), (8, 16), (16, 24)], "zh: outline times")
c = {r["id"]: r for r in zh["captions"]["rows"]}
want(zh["captions"]["kind"] == "caption" and len(c) == 5 and c["c03"]["term"] == "沉淀" and c["c03"]["seg"] == "2", "zh: captions, terms, segments")
want((c["c05"]["t0"], c["c05"]["t1"]) == (16, 24) and c["c04"]["facts"] == ["#1"], "zh: bars → seconds past the beat map, fact refs")
f = {x["id"]: x for x in zh["facts"]}
want(f["#3"]["dropped"] and not f["#1"]["dropped"] and f["#1"]["onscreen"] and [x["done"] for x in zh["fact_todo"]] == [False, True], "zh: facts, struck rows, to-verify")
a = zh["agent_decided"]
want([x["superseded"] for x in a] == [False, True, False] and a[1]["note"] == "（关卡 ① 后作废）" and a[2]["group"] == "关卡 ① 之后", "zh: DECISIONS strikethrough and groups")
h = zh["history"]
want(len(h) == 1 and h[0]["quotes"][0]["text"].startswith("大纲按内容分段") and [n["k"] for n in h[0]["notes"]] == ["定了", "改了"], "zh: REVIEW history")
r = zh["rounds"]
want([x["id"] for x in r] == ["1"] and r[0]["data"]["listen"][0]["t"] == 7.5 and r[0]["data"]["least_sure"][1] == {"id": "", "note": "配乐会不会太甜"}, "zh: the gate page and its listen prompts")
want([s["label"] for s in zh["music"]["sections"]] == ["拧开", "管道", "杯子"], "zh: music section labels from the gate JSON")
want([s["seg"] for s in zh["shots"]["items"]] == ["1", "2", "3"], "zh: shots matched to the outline")
sb = next((d for d in zh["docs"] if d["file"] == "STORYBOARD.md"), None)
want(sb and sb["sections"][0]["title"] == "Shots" and "<li>S1" in sb["sections"][0]["html"] and not zh["warnings"], "zh: STORYBOARD.md (no table) as formatted text")
want(en["lang"] == "en" and [x["title"] for x in en["outline"]][0] == "Open the tap" and en["outline"][0]["tag"] == "setup", "en: lang, outline from English headers")
c = {r["id"]: r for r in en["captions"]["rows"]}
want(en["captions"]["kind"] == "narration" and c["n3"]["seg"] == "3" and c["n2"]["term"] == "settling" and c["n1"]["t0"] == 0.5, "en: narration table")
notes = next((d for d in en["docs"] if d["file"] == "NOTES.md"), {"sections": []})
want(en["facts"] == [] and any("NOTES.md" in w for w in en["warnings"]) and any("water in city pipes" in s["html"] for s in notes["sections"]), "en: NOTES.md without its table comes back as text, with a warning")
want(en["agent_decided"][1]["superseded"] and en["history"][0]["quotes"][0]["text"] == "Name the parts by what happens in them." and en["rounds"] == [], "en: DECISIONS, REVIEW, no gate page")
if bad:
    print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
  then ok "desk reads the zh and en fixtures (outline, captions and terms, bars, facts, ledger, history, gate extras), and a doc without its table as text"
  else bad "desk reader on tools/desk/fixtures"; fi
  # this round is the page bin/vh review made last (.current), else the last in review order, never the newest file;
  # one language rule; markdown in bounded time;
  # the newest submission within one second is the highest -n. (A file, not a heredoc inside $(…): bash 3.2 counts the
  # parentheses in the heredoc's body.)
  cat > "$t/order.py" <<'PY'
import json, os, shutil, subprocess, sys, time
sys.path.insert(0, "tools/desk")
import feedback, reader
bad = []
def want(cond, what):
    if not cond: bad.append(what)
t0 = time.time()
for s in ("*a " * 20000, "[" * 60000, "**a " * 15000, "~~a " * 15000, "`" * 30000, "a](b " * 12000):
    reader.render_md(s)
want(time.time() - t0 < 3, f"long lines took {time.time() - t0:.1f} s")
try:
    h = reader.render_md(">" * 3000 + " x")
    want(h.count("<blockquote>") <= reader.MAX_QUOTE_DEPTH + 1 and h.endswith("x</p>" + "</blockquote>" * h.count("<blockquote>")), "3000 nested quotes")
except RecursionError:
    bad.append("3000 nested quotes: RecursionError")
want(reader.render_md("a *b* c") == "<p>a <em>b</em> c</p>" and reader.render_md("**b** ~~c~~") == "<p><strong>b</strong> <del>c</del></p>", "inline markup")
d = os.path.join(sys.argv[1], "order")
shutil.copytree("tools/desk/fixtures/zh", d)
g = os.path.join(d, "out", "review")
shutil.copy(os.path.join(g, "gate-1.json"), os.path.join(g, "gate-1b.json"))
os.utime(os.path.join(g, "gate-1.json"), (time.time() + 60, time.time() + 60))   # the earlier page touched later
r = reader.read_project(d)
want([x["id"] for x in r["rounds"]] == ["1", "1b"] and r["lang"] == "zh", f"order after a touch: {[x['id'] for x in r['rounds']]}, lang {r['lang']}")
j = json.load(open(os.path.join(g, "gate-1b.json"), encoding="utf-8"))
json.dump(dict(j, lang="en"), open(os.path.join(g, "gate-1b.json"), "w", encoding="utf-8"))
want(reader.read_project(d)["lang"] == "en", "this round's gate JSON lang should override the BRIEF")
fd = os.path.join(g, "feedback")
os.makedirs(fd)
for n in ("1b-20261004-030440", "1b-20261004-030440-2", "1b-20261004-030440-10"):
    json.dump({"round": "1b", "submitted_at": "2026-10-04T03:04:40", "n": n}, open(os.path.join(fd, n + ".json"), "w"))
want(feedback.latest(d)[1]["n"] == "1b-20261004-030440-10", f"latest within one second: {feedback.latest(d)[1]}")
# the page bin/vh review made last is this round (out/review/.current), whatever the stop order or its name
c = os.path.join(sys.argv[1], "current")
shutil.copytree("tools/desk/fixtures/zh", c)
cg = os.path.join(c, "out", "review")
def publish(n):
    shutil.copy(os.path.join(cg, "gate-1.json"), os.path.join(cg, f"gate-{n}.json"))
    return subprocess.run([sys.executable, "tools/review.py", c, n], capture_output=True, text=True).returncode
cur = lambda: reader.read_project(c)["rounds"][-1]["id"]   # noqa: E731
for seq, page in ((["2", "1b"], "1b"), (["3", "E3b"], "E3b"), (["final"], "final"), (["2B"], "2B")):
    rcs = [publish(n) for n in seq]
    want(rcs == [0] * len(seq) and cur() == page, f"published {seq} (exit {rcs}): this round is {cur()}, not {page}")
fd2 = os.path.join(cg, "feedback")
os.makedirs(fd2)
for rid in ("2B", "E3b"):
    json.dump({"round": rid, "submitted_at": "2026-10-04T12:00:00"}, open(os.path.join(fd2, f"{rid}-20261004-120000.json"), "w"))
want([f.name for f, _ in feedback.pending(c)] == ["2B-20261004-120000.json"], f"pending follows .current: {[f.name for f, _ in feedback.pending(c)]}")
os.remove(os.path.join(cg, "gate-2B.json"))   # .current names a page that is gone: the review order decides
want(cur() == "3", f"with .current pointing at a removed page: {cur()}")
# bin/vh review: the page as spelled on disk (APFS finds gate-1d.json for 1D); no gate: this round, not the newest
# file; ids of 1-24 characters; a gate file that links out of the project is not read
shutil.copy(os.path.join(cg, "gate-1.json"), os.path.join(cg, "gate-1d.json"))
rv = lambda *a: subprocess.run([sys.executable, "tools/review.py", c, *a], capture_output=True, text=True)   # noqa: E731
r = rv("1D")
names = os.listdir(cg)
want(r.returncode == 0 and open(os.path.join(cg, ".current")).read().strip() == "1d" and "gate-1d.html" in names and "gate-1D.html" not in names,
     f"review 1D for gate-1d.json: exit {r.returncode}, .current {open(os.path.join(cg, '.current')).read().strip()!r}, {sorted(n for n in names if n.endswith('.html'))}")
publish("E3b")
os.utime(os.path.join(cg, "gate-3.json"), (time.time() + 60, time.time() + 60))
r = rv()
want(r.returncode == 0 and "gate-E3b.html" in r.stderr and "gate-3.json is newer" in r.stderr, f"review with no gate: {r.returncode} {r.stderr[-300:]}")
r = rv("a" * 25)
want(r.returncode == 2 and "1 to 24" in r.stderr, f"a 25-character id: {r.returncode} {r.stderr}")
shutil.copy(os.path.join(cg, "gate-1.json"), os.path.join(sys.argv[1], "outside.json"))
os.symlink(os.path.join(sys.argv[1], "outside.json"), os.path.join(cg, "gate-9.json"))
want("9" not in [x["id"] for x in reader.read_project(c)["rounds"]] and rv("9").returncode == 2, "a gate file linking out of the project was read")
# writers in several processes at once: each _write has its own temp file, .consumed's read-modify-write is locked
code = ("import sys; sys.path.insert(0, 'tools/desk'); import feedback; from pathlib import Path\n"
        "d, k = sys.argv[1], sys.argv[2]\n"
        "for i in range(40):\n"
        "    feedback._write(Path(d) / 'out' / 'review' / 'feedback' / '.listening', k)\n"
        "    feedback.mark_consumed(d, [f'{k}-{i}.json'])\n")
procs = [subprocess.Popen([sys.executable, "-c", code, c, f"w{k}"], stderr=subprocess.PIPE, text=True) for k in range(8)]
errs = [(p.wait(), p.stderr.read()) for p in procs]
parts = [n for n in os.listdir(fd2) if n.endswith(".part")]
want(all(rc == 0 for rc, _ in errs) and len([n for n in feedback.consumed(c) if n.startswith("w")]) == 320 and not parts,
     f"8 concurrent writers: exits {[rc for rc, _ in errs]}, {len(feedback.consumed(c))} names, leftovers {parts}, {[e[-200:] for _, e in errs if e][:1]}")
# the targets a client points at: a span, a chapter, an asset, a concept card; a span's t / t1 come from its target
sub = lambda *its, lang="zh": {"round": "1", "lang": lang, "items": [dict({"status": "change", "text": "x"}, **i) for i in its]}   # noqa: E731
v = feedback.validate(d, sub({"target": "range:1.5-3", "t": 9}, {"target": "chapter:c2"}, {"target": "asset:assets/a b.png"}, {"target": "card:B"}))
want([(i["target"], i.get("t"), i.get("t1")) for i in v["items"]] == [("range:1.5-3", 1.5, 3.0), ("chapter:c2", None, None), ("asset:assets/a b.png", None, None), ("card:B", None, None)],
     f"new targets: {v['items']}")
for bad_t in ("range:3-1", "range:2-2", "range:-1-2", "range:a-b", "range:1", "asset:/etc/passwd", "asset:../x", "asset:a/../../x", "asset:https://x.test/a.png", "card:", "chapter:",
              "range:1.001-1.004", "range:1-2\n", "cap:c1\n", "asset:..\n", "asset: /etc/passwd", "asset:a/ ../x", "asset:a/.. /x", "asset:x ",
              "range:\u0661-\u0662", "range:1-\uff12", "asset:C:\\x", "seg:a\x7f"):   # rounding to equal, a final newline, spaces, other digits
    try:
        feedback.validate(d, sub({"target": bad_t}))
        bad.append(f"{bad_t!r} was taken")
    except ValueError:
        pass
want(feedback.clock(59.96) == "1:00.0" and feedback.clock(12.44) == "0:12.4", f"clock: {feedback.clock(59.96)}, {feedback.clock(12.44)}")
md = feedback.to_markdown(dict(feedback.validate(d, sub({"target": "range:1.5-3"}, {"target": "card:B"}, {"target": "asset:assets/a.png"}, {"target": "chapter:c2"})), submitted_at="t"))
want("- 片段 0:01.5–0:03.0 [range:1.5-3] · 要改：x" in md and "- 立意卡 B [card:B]" in md and "- 素材 assets/a.png [asset:assets/a.png]" in md and "- 章节 c2 [chapter:c2]" in md, f"zh labels: {md}")
md = feedback.to_markdown(dict(feedback.validate(d, sub({"target": "range:75-80", "label": "the bridge"}, lang="en")), submitted_at="t"))
want("- the bridge (1:15.0–1:20.0) [range:75-80] · change: x" in md, f"en label with its span: {md}")
if bad:
    print("; ".join(bad))
sys.exit(1 if bad else 0)
PY
  if a=$(python3 "$t/order.py" "$t"); then ok "desk: this round is the page bin/vh review made last (1b after 2, E3b after 3, final, 2B; pending follows it), else review order (a touched file doesn't win); the gate JSON's lang overrides the BRIEF; long and deeply nested markdown in bounded time; -10 after -2"
    ok "review: 1D renders gate-1d.json as 1d; no gate renders this round (and names a newer file); ids over 24 characters and gate links out of the project are refused; 8 concurrent writers all exit 0 with every name kept"
  else bad "desk order / lang / markdown / latest / review ids / concurrent writers: $a"; fi
  # a server on a free port, on a copy (a submission writes into the project); a hidden file, a link to it, an upper-case
  # .ENV and an SVG with a script in it: none may be served same-origin
  cp -R tools/desk/fixtures/zh "$t/p" && printf '<img src=x onerror=alert(1)>\n' >> "$t/p/STORYBOARD.md"
  printf 'KEY=secret\n' > "$t/p/.env" && ln -s .env "$t/p/visible.txt" && printf 'KEY=secret\n' > "$t/p/keys.ENV"
  printf '<svg xmlns="http://www.w3.org/2000/svg"><script>fetch("/")</script></svg>\n' > "$t/p/ref.svg"
  if ! desk_start "$t/p" "$t/srv.log"; then rm -rf "$t"; return; fi
  pid=$desk_pid; url=$desk_url
  cat > "$t/client.py" <<'PY'
import http.client, json, socket, sys, urllib.parse
u = urllib.parse.urlsplit(sys.argv[1]); proj = sys.argv[2]; what = sys.argv[3]
def req(method, path, body=None, headers=None):
    c = http.client.HTTPConnection(u.hostname, u.port, timeout=10)
    h = {"Host": f"127.0.0.1:{u.port}"}
    h.update(headers or {})
    c.request(method, path, body=body, headers=h)
    r = c.getresponse(); data = r.read(); c.close()
    return r.status, r.headers, data
bad = []
def want(cond, msg):
    if not cond: bad.append(msg)
s, _, page = req("GET", "/")
token = page.decode().split('name="desk-token" content="')[1].split('"')[0]
fb = lambda **k: json.dumps(dict({"round": "1", "lang": "zh", "decisions": {"look": "L2"}, "defaulted": [], "general": "",
    "items": [{"target": "seg:1", "status": "change", "label": "大纲 第 1 段", "text": "开头再快一点 ``` 第 0 帧就要有水声"}]}, **k)).encode()
H = {"Content-Type": "application/json", "X-Desk-Token": token}
if what == "serve":
    s, _, d = req("GET", "/api/data")
    d = json.loads(d) if s == 200 else {}
    sb = next((x for x in d.get("docs", []) if x["file"] == "STORYBOARD.md"), {"sections": [], "intro": ""})
    html = sb["intro"] + "".join(x["html"] for x in sb["sections"])
    want(s == 200 and d["project"]["slug"] == "p" and "&lt;img src=x" in html and "<img src=x" not in html, f"GET /api/data: {s}, markup in a doc escaped")
    raw = open(proj + "/NOTES.md", "rb").read()
    s, h, body = req("GET", "/p/NOTES.md", headers={"Range": "bytes=2-9"})
    want(s == 206 and h["Content-Range"] == f"bytes 2-9/{len(raw)}" and body == raw[2:10], f"Range: {s} {h.get('Content-Range')}")
    s, h, body = req("GET", "/p/NOTES.md")
    want(s == 200 and body == raw and h["Accept-Ranges"] == "bytes", f"whole file: {s}")
    for p in ("/p/NOTES.md", "/p/ref.svg"):   # opened in the browser, a project page runs in an opaque origin
        csp = req("GET", p)[1].get("Content-Security-Policy", "")
        want(csp.startswith("sandbox") and "allow-same-origin" not in csp, f"{p} not sandboxed: {csp!r}")
    for p in ("/p/%2e%2e/BRIEF.md", "/p/..%2f..%2fetc/passwd", "/p/out/review/.desk.json", "/p/nope.md", "/BRIEF.md",
              "/p/.env", "/p/visible.txt", "/p/keys.ENV", "/p/keys.env"):
        want(req("GET", p)[0] == 404, f"{p} served")
    want(req("POST", "/api/feedback", fb(defaulted=5), H)[0] == 400, "defaulted: 5")
    want(req("POST", "/api/feedback", fb(lang=[1]), H)[0] == 400, "lang: [1]")
    want(req("POST", "/api/feedback", b"[" * 200000, H)[0] == 400, "200,000 nested arrays")
    want(req("POST", "/api/feedback", fb(), dict(H, **{"X-Desk-Token": "tök€n".encode("utf-8")}))[0] == 403, "a non-ASCII token")
    sk = socket.create_connection((u.hostname, u.port), timeout=10)   # a body shorter than its Content-Length
    sk.sendall(f"POST /api/feedback HTTP/1.1\r\nHost: 127.0.0.1:{u.port}\r\nContent-Type: application/json\r\n"
               f"X-Desk-Token: {token}\r\nContent-Length: 100\r\n\r\n".encode() + b'{"round": "1"}')
    sk.shutdown(socket.SHUT_WR)
    resp = sk.recv(200)
    sk.close()
    want(resp.split(b" ")[1:2] == [b"400"], f"a short body: {resp[:40]!r}")
    want(req("GET", "/api/data", headers={"Host": "evil.test"})[0] == 403, "another Host answered")
    want(req("POST", "/api/feedback", fb(), {"Content-Type": "application/json"})[0] == 403, "a post without the token")
    want(req("POST", "/api/feedback", fb(), dict(H, Origin="http://evil.test"))[0] == 403, "a post from another origin")
    want(req("POST", "/api/feedback", fb(), dict(H, **{"Content-Type": "text/plain"}))[0] == 415, "a post that isn't JSON")
    want(req("POST", "/api/feedback", fb(round="9"), H)[0] == 400, "a round with no gate page")
    want(req("POST", "/api/feedback", fb(decisions={"look": "L9"}), H)[0] == 400, "an option the gate page doesn't have")
    want(req("POST", "/api/feedback", fb(items=[{"target": "x", "status": "ok"}]), H)[0] == 400, "a bad target")
    want(req("POST", "/api/feedback", fb(items=[{"target": "range:5-2", "status": "change"}]), H)[0] == 400, "a backward range")
    want(req("POST", "/api/feedback", fb(items=[{"target": "asset:../../etc/passwd", "status": "change"}]), H)[0] == 400, "an asset outside the project")
    want(json.loads(req("GET", "/api/status")[2])["listening"] is False, "listening before the watcher")
elif what == "status":
    print(json.loads(req("GET", "/api/status")[2])["listening"])
elif what == "post":   # no watcher: argv[4] is the comment
    s, _, d = req("POST", "/api/feedback", fb(items=[{"target": "seg:2", "status": "change", "label": "大纲 第 2 段", "text": sys.argv[4]}]), H)
    want(s == 200, f"post: {s} {d[:200]}")
elif what == "targets":   # a span, a chapter, an asset and a concept card, as a client sends them
    s, _, d = req("POST", "/api/feedback", fb(items=[{"target": "range:12.4-15", "status": "change", "text": "这一段太慢"},
        {"target": "chapter:c2", "status": "ask", "text": "这一章要不要"}, {"target": "asset:assets/photo.jpg", "status": "change", "text": "换一张"},
        {"target": "card:B", "status": "ok"}]), H)
    want(s == 200, f"targets: {s} {d[:200]}")
else:
    want(json.loads(req("GET", "/api/status")[2])["listening"] is True, "the page doesn't see the watcher")
    s, _, d = req("POST", "/api/feedback", fb(), H)
    want(s == 200 and json.loads(d)["listening"] is True and json.loads(d)["saved"].startswith("out/review/feedback/1-"), f"submit: {s} {d[:200]}")
if bad:
    print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
  if a=$(python3 "$t/client.py" "$url" "$t/p" serve); then ok "desk server: page, data with markup escaped, a 206 range, project files sandboxed; refuses other hosts, paths out of the project, hidden files (also through a link, any case), posts without the token, from another origin or not JSON, an unknown round, option or target; malformed bodies and tokens get 400/403"
  else bad "desk server: $a"; fi
  "$VH_BASH" "$ROOT/bin/vh" desk wait "$t/p" --timeout 30 > "$t/wait.out" 2>&1 & wpid=$!
  for i in $(seq 50); do [ -f "$t/p/out/review/feedback/.listening" ] && break; sleep 0.2; done
  a=$(python3 "$t/client.py" "$url" "$t/p" submit); rc=$?
  wait "$wpid"; i=$?
  if [ $rc = 0 ] && [ $i = 0 ] && grep -q '第 0 帧就要有水声' "$t/wait.out" && [ ! -e "$t/p/out/review/feedback/.listening" ] \
    && python3 - "$t/p/REVIEW.md" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^## 审阅台反馈 · 关卡 1 · .*?(?=^## )", s, re.M | re.S)
sys.exit(0 if m and "开头再快一点 ``` 第 0 帧就要有水声" in m.group(0) and "\n````text\n" in m.group(0)
         and s.index("## 审阅台反馈") < s.index("## 授权跳过怎么记") and "决定 look：L2" in m.group(0) else 1)
PY
  then ok "desk: a submission wakes bin/vh desk wait (exit 0) and goes into REVIEW.md verbatim, fenced, before the template's reference sections"
  else bad "desk submit + wait: client '$a' rc $rc, wait rc $i: $(head -c 300 "$t/wait.out")"; fi
  a=$(vh desk feedback "$t/p" --round 1) && case "$a" in *"第 0 帧就要有水声"*"json: "*) true ;; *) false ;; esac \
    && vh desk feedback "$t/p" --json | python3 -c "import json, sys; d = json.load(sys.stdin); sys.exit(0 if d['decisions'] == {'look': 'L2'} and d['project'] == 'p' else 1)" \
    && ok "desk feedback prints the latest submission (text and --json)" || bad "desk feedback: $a"
  # a submission made while no watcher runs (after a timeout, say) is handed over by the next wait at once, and only once;
  # what desk feedback printed counts as handed over too
  a=$(python3 "$t/client.py" "$url" "$t/p" post "提前到的一条" && vh desk wait "$t/p" --timeout 20 2>&1); rc=$?
  vh desk wait "$t/p" --timeout 1 >/dev/null 2>&1; i=$?
  case "$rc:$i:$a" in 0:3:*"提前到的一条"*) ok "desk wait hands over a submission made before it was armed, at once and only once" ;;
    *) bad "desk wait with a submission already there: rc $rc, then $i: $(printf '%s' "$a" | head -c 300)" ;; esac
  a=$(python3 "$t/client.py" "$url" "$t/p" post "第三条" && vh desk feedback "$t/p")
  vh desk wait "$t/p" --timeout 1 >/dev/null 2>&1; rc=$?
  case "$rc:$a" in 3:*"第三条"*) ok "desk feedback counts what it printed as handed over" ;; *) bad "desk feedback then wait: rc $rc: $(printf '%s' "$a" | head -c 300)" ;; esac
  # the new targets through the server: kept with the span's seconds, printed and written into REVIEW.md readably
  a=$(python3 "$t/client.py" "$url" "$t/p" targets && vh desk feedback "$t/p" --json) && b=$(vh desk feedback "$t/p")
  if python3 - "$a" "$t/p/REVIEW.md" "$b" <<'PY'
import json, sys
d, rv, txt = json.loads(sys.argv[1]), open(sys.argv[2], encoding="utf-8").read(), sys.argv[3]
it = {i["target"]: i for i in d["items"]}
want = ["- 片段 0:12.4–0:15.0 [range:12.4-15] · 要改：这一段太慢", "- 章节 c2 [chapter:c2] · 疑问：这一章要不要", "- 素材 assets/photo.jpg [asset:assets/photo.jpg] · 要改：换一张", "- 立意卡 B [card:B] · 可以"]
sys.exit(0 if (it["range:12.4-15"]["t"], it["range:12.4-15"]["t1"]) == (12.4, 15.0) and all(w in rv and w in txt for w in want) else 1)
PY
  then ok "desk: range, chapter, asset and card targets are taken, keep the span's seconds, and read plainly in desk feedback and REVIEW.md; a backward span or a path out of the project is refused"
  else bad "desk new targets: $(printf '%s' "$a$b" | tail -c 600)"; fi
  # a copy of the project carries the running server's .desk.json and a .listening that names another folder: neither counts
  cp -R "$t/p" "$t/p2" && printf '{"pid": %s, "since": 0, "until": 99999999999, "project": "%s"}\n' "$$" "$t/p" > "$t/p2/out/review/feedback/.listening"
  if desk_start "$t/p2" "$t/srv2.log"; then
    a=$(python3 "$t/client.py" "$desk_url" "$t/p2" status)
    [ "$a" = False ] && ok "desk: a copied project starts its own server, and a .listening from another folder doesn't count" || bad "desk on a copy: listening said '$a'"
    kill "$desk_pid"; wait "$desk_pid" 2>/dev/null
  fi
  # a .listening of this folder and a live pid whose until is not a number of seconds is not listening, and raises nothing
  a=$(python3 - "$t/p2" <<'PY' 2>&1
import json, os, sys, time
sys.path.insert(0, "tools/desk"); import feedback
p = sys.argv[1]; flag = os.path.join(p, "out/review/feedback/.listening")
def said(until):
    with open(flag, "w") as f: json.dump({"pid": os.getpid(), "since": 0, "until": until, "project": os.path.realpath(p)}, f)
    return feedback.listening(p)["listening"]
print(" ".join(str(said(u)) for u in ("soon", [1], "nan", time.time() + 60)))
PY
  )
  [ "$a" = "False False False True" ] && ok "desk: a .listening whose until is not seconds (a word, a list, NaN) is not listening, and is no error" || bad "desk listening on a bad until: $a"
  # desk wait has its signal handlers before it writes .listening: a TERM right after the write (sent from inside the
  # write, so no timing is involved) ends it with 143 and takes the flag away, as one later does
  rm -f "$t/p2/out/review/feedback/.listening"
  a=$(python3 - "$t/p2" <<'PY' 2>&1
import os, subprocess, sys
child = """import os, signal, sys
sys.path.insert(0, "tools/desk"); import feedback
w = feedback._write
def write(p, text):
    w(p, text)
    if p.name == ".listening": os.kill(os.getpid(), signal.SIGTERM)
feedback._write = write
sys.exit(feedback.wait(sys.argv[1], 30, poll=0.05))"""
rc = subprocess.run([sys.executable, "-c", child, sys.argv[1]], capture_output=True).returncode   # -15: killed by it
print(rc, "flag left" if os.path.exists(os.path.join(sys.argv[1], "out/review/feedback/.listening")) else "no flag")
PY
  )
  [ "$a" = "143 no flag" ] && ok "desk wait: a TERM the moment .listening is written ends it with 143 and no flag left" || bad "desk wait TERMed right after its flag: $a"
  a=$(vh desk "$t/p" --port 0 2>&1); case "$a" in *"already serving p"*) ok "desk: a second start points to the running server" ;; *) bad "desk second start: $a" ;; esac
  kill "$pid"; wait "$pid" 2>/dev/null
  [ ! -e "$t/p/out/review/.desk.json" ] && ok "desk: stopping the server removes out/review/.desk.json" || bad "desk left .desk.json behind"
  vh desk wait "$t/p" --timeout 1 > /dev/null 2>&1; rc=$?; [ $rc = 3 ] && ok "desk wait exits 3 on timeout" || bad "desk wait --timeout 1 exited $rc"
  # the language: bin/vh new --lang writes the BRIEF line; bin/vh review takes it when the gate JSON has no lang
  if OVH_PROJECTS="$t/new" vh new math ci-lang --lang en >/dev/null 2>&1 && grep -q '^- Review language: en ' "$t"/new/*-ci-lang/BRIEF.md \
    && OVH_PROJECTS="$t/new" vh new math ci-zh >/dev/null 2>&1 && grep -q '^- Review language: zh ' "$t"/new/*-ci-zh/BRIEF.md; then
    vh new math ci-x --lang fr >/dev/null 2>&1; rc=$?; [ $rc = 2 ] && ok "new --lang writes Review language (default zh) and rejects fr" || bad "new --lang fr exited $rc"
  else bad "new --lang: Review language not written"; fi
  cp -R tools/desk/fixtures/zh "$t/rz" && cp -R tools/desk/fixtures/zh "$t/re" && sed 's/^- Review language: zh /- Review language: en /' tools/desk/fixtures/zh/BRIEF.md > "$t/re/BRIEF.md"
  sed 's/^{/{"lang": "en",/' tools/desk/fixtures/zh/out/review/gate-1.json > "$t/rz/out/review/gate-1b.json"
  if vh review "$t/rz" 1 >/dev/null 2>&1 && vh review "$t/re" 1 >/dev/null 2>&1 && vh review "$t/rz" 1b >/dev/null 2>&1 \
    && grep -q '<html lang="zh-CN">' "$t/rz/out/review/gate-1.html" && grep -q '<html lang="en">' "$t/re/out/review/gate-1.html" \
    && grep -q '<html lang="en">' "$t/rz/out/review/gate-1b.html"
  then ok "review: the gate JSON's lang, else the BRIEF's Review language (the desk's rule), and the desk's extra keys pass"; else bad "review language rule"; fi
  a=$(vh review "$t/rz" 1 2>&1)
  if grep -q '没回的决定按推荐走' "$t/rz/out/review/gate-1.html" && grep -q 'unanswered goes by its recommendation' "$t/re/out/review/gate-1.html" \
    && case "$a" in *"没回的决定按推荐走"*) true ;; *) false ;; esac
  then ok "review: the page and the chat message say a decision left unanswered goes by its recommendation"; else bad "review: unanswered decisions not explained: $a"; fi
  gate_stop_checks "$t"
  rm -rf "$t"
}
# bin/vh gate: one stop in one command. The page channel (a flag, LOCAL.md's 审阅方式, the effort's default) prints the
# chat message and starts nothing; --wait there is refused; a page that breaks a rule sends nothing and starts no desk; the
# desk channel starts the desk in the background (once), adds its address, and with --wait hands over the submission;
# desk --idle stops a desk nobody asks anything
gate_stop_checks() {
  local t=$1 g a b rc rc2 rc3 i pid url
  g="$t/g"; cp -R tools/desk/fixtures/zh "$g"; rm -rf "$g/out/review/feedback" "$g/out/review/.current"
  printf '%s\n' '# LOCAL' '- 审阅方式：{对话 | 审阅页 | 审阅台}（不填按档位）' > "$t/LOCAL-tpl.md"; printf '%s\n' '# LOCAL' '- 审阅方式：对话' > "$t/LOCAL-chat.md"
  a=$(vh gate "$g" 1 --page 2>"$t/g1.err"); rc=$?
  vh gate "$g" 1 --page --wait >/dev/null 2>"$t/g2.err"; rc2=$?
  b=$(OVH_LOCAL_MD="$t/LOCAL-chat.md" vh gate "$g" 1 2>&1)
  if [ $rc = 0 ] && [ $rc2 = 2 ] && case "$a" in *"要你定 1 件事"*"页面："*"/out/review/gate-1.html") true ;; *) false ;; esac \
    && [ "$(cat "$g/out/review/.current")" = 1 ] && [ ! -e "$g/out/review/.desk.json" ] && grep -q 'waits for the review desk' "$t/g2.err" \
    && case "$b" in *"reviewed on the chat (LOCAL.md)"*) true ;; *) false ;; esac && [ ! -e "$g/out/review/.desk.json" ]
  then ok "gate: --page and LOCAL.md's 审阅方式 print the chat message, make the page this round and start no desk; --wait without the desk is refused"
  else bad "gate on the page (rc $rc/$rc2): $a | $(cat "$t/g1.err" "$t/g2.err") | $b"; fi
  # a page that breaks a rule: written, but no message and no desk; a standard project with LOCAL.md's placeholder: the page
  sed 's/"recommend": "L1", //' "$g/out/review/gate-1.json" > "$g/out/review/gate-1b.json"
  a=$(vh gate "$g" 1b --desk --port 0 2>/dev/null); rc=$?
  vh review "$g" 1b >/dev/null 2>&1; rc3=$?
  cp -R "$g" "$t/gs" && sed 's/^- Effort: studio/- Effort: standard/' "$g/BRIEF.md" > "$t/gs/BRIEF.md"
  b=$(OVH_LOCAL_MD="$t/LOCAL-tpl.md" vh gate "$t/gs" 1 2>&1); rc2=$?
  if [ $rc = 1 ] && [ $rc3 = 1 ] && [ -z "$a" ] && [ -f "$g/out/review/gate-1b.html" ] && [ "$(cat "$g/out/review/.current")" = 1 ] && [ ! -e "$g/out/review/.desk.json" ] \
    && [ $rc2 = 0 ] && case "$b" in *"reviewed on the page (effort standard (BRIEF))"*) true ;; *) false ;; esac && [ ! -e "$t/gs/out/review/.desk.json" ]
  then ok "gate and review: a page that breaks a rule is written but sends nothing, starts no desk and does not become this round; LOCAL.md's unfilled line falls back to the effort (standard: the page)"
  else bad "gate with a broken page or a placeholder (rc $rc/$rc3/$rc2, this round $(cat "$g/out/review/.current")): $a | $b"; fi
  # the desk channel (studio): started once in the background, its address in the message; --wait hands over a submission
  a=$(vh gate "$g" 1 --port 0 2>/dev/null); rc=$?
  b=$(vh gate "$g" 1 --port 0 2>&1); rc2=$?
  pid=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["pid"])' "$g/out/review/.desk.json" 2>/dev/null)
  url=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["url"])' "$g/out/review/.desk.json" 2>/dev/null)
  "$VH_BASH" "$ROOT/bin/vh" gate "$g" 1 --wait --timeout 30 > "$t/gw.out" 2>&1 & i=$!
  for rc3 in $(seq 50); do [ -f "$g/out/review/feedback/.listening" ] && break; sleep 0.2; done
  python3 "$t/client.py" "$url" "$g" submit >/dev/null; wait $i; rc3=$?
  if [ $rc = 0 ] && [ $rc2 = 0 ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && case "$a" in *"审阅台：http://127.0.0.1:"*"然后回到这里说一声"*) true ;; *) false ;; esac \
    && case "$b" in *"already serving this project"*) true ;; *) false ;; esac && [ $rc3 = 0 ] && grep -q '我在后台等着' "$t/gw.out" && grep -q '第 0 帧就要有水声' "$t/gw.out" \
    && python3 - "$g/.ovh/activity.jsonl" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
gates = {r["run"] for r in recs if r["event"] == "start" and r["cmd"] == "gate"}
desk = [r for r in recs if r["event"] == "start" and r["cmd"] == "desk"]
sys.exit(0 if len(desk) == 1 and desk[0].get("parent") in gates and any(r["event"] == "feedback" for r in recs) else 1)
PY
  then ok "gate: the desk channel starts the desk once in the background (its run's parent is the gate), puts its address in the message; --wait hands over the submission"
  else bad "gate on the desk (rc $rc/$rc2/$rc3): $a | $b | $(tail -c 400 "$t/gw.out")"; fi
  [ -z "$pid" ] || { kill "$pid" 2>/dev/null; for i in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done; }
  # desk --idle: a desk nobody asks anything stops by itself, and takes its .desk.json with it
  "$VH_BASH" "$ROOT/bin/vh" desk "$t/gs" --port 0 --idle 1 > "$t/idle.out" 2>&1 & pid=$!
  for i in $(seq 100); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
  if ! kill -0 $pid 2>/dev/null && grep -q 'no request for 1 s, stopped' "$t/idle.out" && [ ! -e "$t/gs/out/review/.desk.json" ]; then ok "desk --idle: a desk nobody asks anything stops by itself"
  else kill $pid 2>/dev/null; bad "desk --idle 1: $(cat "$t/idle.out")"; fi
}
concept_checks() {   # bin/vh concept: the roulette (seeded by the project's name, what the project has and --not left out)
  # and the six-then-three board (pillow through uv: the same bytes for the same input)
  local t p a b c rc rc2 rc3
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  OVH_PROJECTS="$t" vh new short roul --style risograph >/dev/null 2>&1; p=$(ls -d "$t"/*-roul)
  a=$(vh concept roulette "$p" --from styles,sequences,levers --n 3 --json 2>/dev/null); rc=$?
  b=$(vh concept roulette "$p" --from styles,sequences,levers --n 3 --json 2>/dev/null); rc2=$?
  c=$(vh concept roulette "$p" --from styles --reroll 1 --json 2>/dev/null); rc3=$?
  if [ "$rc:$rc2:$rc3" = 0:0:0 ] && [ "$a" = "$b" ] && python3 - "$a" "$c" "$(vh concept roulette "$p" --from styles --json 2>/dev/null)" \
      "$(vh concept roulette "$p" --from styles --not "$(printf '%s' "$c" | python3 -c 'import json,sys; print(json.load(sys.stdin)["picks"][0]["id"])')" --reroll 1 --json 2>/dev/null)" <<'PY'
import json, sys
a, c, first, without = (json.loads(x) for x in sys.argv[1:5])
ok = a["seed"] == "roul" and [p["pool"] for p in a["picks"]] == ["styles", "sequences", "levers"] and all(p["name"] and p["path"] for p in a["picks"])
ok = ok and "styles/risograph" in a["left_out"] and all(p["id"] != "risograph" for p in a["picks"])
ok = ok and c["reroll"] == 1 and c["picks"][0]["id"] != first["picks"][0]["id"]
ok = ok and without["picks"][0]["id"] not in (c["picks"][0]["id"], "risograph")
sys.exit(0 if ok else 1)
PY
  then ok "concept roulette: the same draw for the same project (its name the seed), one from each pool, a style the project attached and --not left out, --reroll the next one"
  else bad "concept roulette (exits $rc:$rc2:$rc3): $(printf '%s' "$a$c" | tail -c 400)"; fi
  if command -v uv >/dev/null 2>&1; then
    mkdir -p "$p/cards"
    for i in 1 2 3; do python3 -c "import struct,zlib,sys
w,h=$((32*i)),18
raw=b''.join(b'\x00'+bytes([40*$i,90,160])*w for _ in range(h))
c=lambda t,d: struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d))
sys.stdout.buffer.write(b'\x89PNG\r\n\x1a\n'+c(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+c(b'IDAT',zlib.compress(raw))+c(b'IEND',b''))" > "$p/cards/c$i.png"; done
    printf '{"candidates": [{"id": "A", "title": "时间放大镜", "image": "cards/c1.png", "source": "designer", "note": "读数常驻"}, {"id": "B", "title": "证据桌", "image": "cards/c2.png", "source": "screenshot"}, {"id": "C", "title": "孔版", "image": "c3.png", "source": "library"}, {"id": "D", "title": "没有图", "source": "roulette"}]}' > "$p/cards/four.json"
    a=$(vh concept board "$p" "$p/cards/four.json" --pick A,C --json 2>/dev/null); rc=$?
    cp "$p/out/check/concept-board.png" "$t/b1.png"; vh concept board "$p" "$p/cards/four.json" --pick A,C >/dev/null 2>&1
    printf '{"candidates": [{"id": "A", "image": "cards/nope.png", "source": "designer"}, {"id": "B", "source": "other"}]}' > "$p/cards/miss.json"
    b=$(vh concept board "$p" "$p/cards/miss.json" --out "$t/m.png" 2>&1); rc2=$?
    printf '{"candidates": [{"id": "A", "source": "magazine"}, {"id": "B"}]}' > "$p/cards/bad.json"
    vh concept board "$p" "$p/cards/bad.json" >/dev/null 2>&1; rc3=$?
    vh concept board "$p" "$p/cards/four.json" --pick Z >/dev/null 2>&1 || rc3="$rc3:$?"
    if [ "$rc:$rc2:$rc3" = 0:1:2:2 ] && cmp -s "$t/b1.png" "$p/out/check/concept-board.png" && [ -s "$t/m.png" ] \
        && printf '%s' "$b" | grep -q "A: no cards/nope.png" && python3 -c "import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d['sources']=={'designer':1,'screenshot':1,'library':1,'roulette':1} and d['picked']==['A','C'] else 1)" "$a"
    then ok "concept board: candidates with their pictures (from the project or the JSON's folder) and sources counted, the picked ones framed, the same bytes twice; a missing picture is drawn as such and exits 1; an unknown source or pick is a usage error"
    else bad "concept board (exits $rc:$rc2:$rc3): $(printf '%s' "$a$b" | tail -c 400)"; fi
  else skip "concept board" "no uv"; fi
  rc=0; for x in "concept" "concept bogus" "concept roulette" "concept board $p" "concept roulette $p --from nothing" "concept roulette $p --n 0"; do
    # shellcheck disable=SC2086
    a=$(vh $x 2>/dev/null); b=$?; [ "$b" = 2 ] && [ -z "$a" ] || { rc=1; bad "bin/vh $x: exit $b, stdout ${a:0:80}"; }
  done
  [ "$rc" = 1 ] || ok "concept: usage errors exit 2, nothing on stdout"
  rm -rf "$t"
}

# bin/vh status: a new standard project works towards gate ①; a page out waits for the person; a desk submission waits for
# the agent until it is handed over and REVIEW.md has its decision, and then the next gate is in progress; a Director stop
# adds its checkpoint; quick skips the gates; the user's waiver skips what it names; a pause waits for the person; a delivery
# record or a final film with a passing check record is delivered; a command running shows; the human view stays short
footage_checks() {   # bin/vh footage (tools/assets/footage.py) from recorded answers: the three sites parsed and their
  # licences classed by the sites' rules; with ffmpeg, a range taken from the keyframe before it and conformed frame for
  # frame, a whole file conformed, strict refusing before a download, the sync table, frames baked by film frame number
  # (slow motion too); with Chrome, a page that loads those frames rendered, checked against the ledger and delivered
  # with its credits. doctor --probe answers the key-less sites from recordings
  local t fr fp a b rc rc2 rc3 rc4 rc5 rc6
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX"); fr="$t/fr"; cp -R tools/assets/fixtures/footage/responses "$fr"
  if a=$(python3 - "$fr" <<'PY'
import json, subprocess, sys
sys.path.insert(0, "tools/assets")
import fetch, footage as F
fr, bad = sys.argv[1], []
R = fetch.Replay(fr)
want = {("nasa", "Artemis II launch", 5): {"nasa:KSC-04012026-C4829": "pd", "nasa:KSC ART II Cause Way Launch low angle": "pd"},
        ("archive", "rocket launch", 6): {"archive:youtube-YL-WYByZP7s": "unknown", "archive:e_history_StreamRoot_DH_0145_19571231_01": "unknown"},
        ("archive", "rocket AND collection:(prelinger)", 6): {"archive:NewsMaga00_9": "pd", "archive:0632_Charlies_Atlas_13_50_50_00": "unknown"},
        ("commons", "rocket launch", 6): {"commons:File:Riding on a Sounding Rocket.webm": "pd", "commons:File:Streichholzrakete (SSR-2, Steigflug).webm": "cc-by-sa"},
        ("commons", "launch incategory:CC-BY-4.0", 5): {"commons:File:SpaceX CRS-35 launch and jellyfish cloud.webm": "cc-by"}}
for (site, q, n), w in want.items():
    got = {it["ref"]: it["class"] for it in F.search(site, q, n, "video", R)}
    if got != w:
        bad.append(f"search {site} {q!r}: {got}")
yt = next(x for x in F.search("archive", "rocket launch", 6, "video", R) if x["ref"].startswith("archive:youtube-"))
if "re-upload" not in yt["why"]:
    bad.append(f"a YouTube re-upload on the Archive: {yt['why']}")
art = F.search("nasa", "Artemis II launch", 5, "video", R)
if "CSA" not in " ".join(x["description"] for x in art):
    bad.append("the fixture's Artemis II descriptions name the CSA astronaut (the case the credit rule must not take for a holder)")
for meta, cls in (({"description": "Crew launch. Credit: ESA/ATG medialab"}, "unknown"), ({"description": "© Getty Images"}, "unknown"),
                  ({"description": "Photo credit: NASA/Joel Kowsky"}, "pd"), ({"description": "a CSA astronaut", "photographer": "NASA/Kim Shiflett"}, "pd"),
                  ({"secondary_creator": "SpaceX"}, "unknown")):
    if F.judge("nasa", meta)[0] != cls:
        bad.append(f"nasa {meta}: {F.judge('nasa', meta)}")
for site, meta, cls in (("commons", {"license": "No restrictions"}, "unknown"), ("commons", {"license": "Public domain"}, "pd"),
                        ("archive", {"id": "x", "license_url": "http://creativecommons.org/licenses/publicdomain/"}, "pd"),
                        ("archive", {"id": "x", "collection": ["mirrortube"], "license_url": "http://creativecommons.org/licenses/by/4.0/"}, "unknown"),
                        ("archive", {"id": "x"}, "unknown")):
    if F.judge(site, meta)[0] != cls:
        bad.append(f"{site} {meta}: {F.judge(site, meta)}")
fs = F.files("nasa:KSC-04012026-C4829", R)
if not any(f["name"].endswith("~orig.mp4") for f in fs) or not any(f["name"].endswith(".srt") for f in fs):
    bad.append(f"files nasa: {[f['name'] for f in fs]}")
ia = F.resolve("archive:NewsMaga00_9", R)
if ia["file"] != "50517.MPG" or ia["ext"] != ".mpg" or ia["kind"] != "video" or not ia["notes"]:
    bad.append(f"resolve archive: {ia['file']} {ia['ext']} {ia['notes']}")
wc = F.resolve("commons:File:SpaceX CRS-35 launch and jellyfish cloud.webm", R)
if "utm_" in wc["file_url"] or wc["author"] != "The Eloquent Peasant" or wc["license"] != "CC BY 4.0":
    bad.append(f"resolve commons: {wc['file_url']} {wc['author']} {wc['license']}")
for ref in ("http://example.org/a.mp4", "youtube:abc"):
    try:
        F.parse_ref(ref)
        bad.append(f"{ref} taken as a ref")
    except F.Usage:
        pass
if [F.frame_from(t, 30) for t in (0, 6.85, 4.1, 10.04)] != [0, 206, 123, 302] or F.frame_at(4.1, 30) != 123 or F.frame_at(0.0333, 30) != 0:
    bad.append("frame_from / frame_at: not the edit list's two functions")
from fractions import Fraction as Fr
if [str(F.snap(x)) for x in (Fr(19001, 317), Fr(2997, 100), Fr(25), Fr(144))] != ["60000/1001", "30000/1001", "25", "144"]:
    bad.append("snap: a Matroska copy's 19001/317 is 60000/1001, 29.97 is 30000/1001, an odd rate stays")
r = subprocess.run([sys.executable, "tools/assets/footage.py", "search", "commons", "rocket launch", "--type", "video", "-n", "6", "--json", "--offline", fr],
                   capture_output=True, text=True)
j = json.loads(r.stdout or "{}")
if r.returncode or j.get("version") != 1 or len(j.get("results", [])) != 2 or j["policy"] != "strict" or [x["taken"] for x in j["results"]] != [True, False]:
    bad.append(f"search --json: exit {r.returncode} {r.stdout[:200]} {r.stderr[-200:]}")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
  ); then ok "footage: the three sites' answers parsed; licences by the sites' rules (a YouTube re-upload, Commons' \"No restrictions\" and an item crediting another holder unknown; NASA public domain though a description names a CSA astronaut; CC's old public-domain deed pd); refs; the frame grid; search --json"
  else bad "footage, parsing and licences: $a"; fi
  if command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null && ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libvpx; then
    mkdir -p "$fr/media"
    ffmpeg -v error -y -f lavfi -i "color=c=black:s=64x36:r=30000/1001,format=gray,geq=lum='mod(N*2\,256)'" -f lavfi -i sine=f=440:r=48000 -t 6 \
      -c:v libx264 -g 60 -keyint_min 60 -sc_threshold 0 -pix_fmt yuv420p -c:a aac -shortest -f mp4 "$fr/media/nasa-orig.mp4.bin"
    ffmpeg -v error -y -f lavfi -i "color=c=black:s=64x36:r=25,format=gray,geq=lum='mod(N*4\,256)'" -t 6 -pix_fmt yuv420p \
      -c:v libvpx -b:v 200k -deadline realtime -cpu-used 8 -f webm "$fr/media/commons-crs35.webm.bin"
    fp="$t/fp"; cp -R tools/assets/fixtures/footage/project "$fp"
    a=$(vh footage get "$fp" nasa:KSC-04012026-C4829 --id cam-pad --range 2.5:4.5 --offline "$fr" 2>&1); rc=$?
    b=$(vh footage get "$fp" "commons:File:SpaceX CRS-35 launch and jellyfish cloud.webm" --id cam-crs --offline "$fr" 2>&1); rc2=$?
    vh footage get "$fp" "commons:File:Streichholzrakete (SSR-2, Steigflug).webm" --offline "$fr" >/dev/null 2>"$t/e3"; rc3=$?
    vh footage get "$fp" "commons:File:SpaceX CRS-35 launch and jellyfish cloud.webm" --id cam-big --max-mb 0.001 --offline "$fr" >/dev/null 2>"$t/e4"; rc4=$?
    vh footage get "$fp" nasa:KSC-04012026-C4829 --id cam-pad --offline "$fr" >/dev/null 2>"$t/e5"; rc5=$?
    if [ "$rc:$rc2:$rc3:$rc4:$rc5" = "0:0:1:1:2" ] && grep -q "Assets: strict (BRIEF) does not take it: nothing downloaded" "$t/e3" && grep -q "over the 1 kB cap: nothing downloaded" "$t/e4" \
       && [ ! -e "$fp/assets/footage/wc-streichholzrakete-ssr-2-steigflug" ] && [ ! -e "$fp/assets/footage/cam-big/orig.webm" ] && python3 - "$fp" <<'PY'
import json, subprocess, sys
sys.path.insert(0, "tools/assets")
import ledger
fp, bad = sys.argv[1], []
def luma(f, n=0):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", f, "-vf", f"select='eq(n\\,{n})',format=gray", "-frames:v", "1", "-f", "rawvideo", "-"], capture_output=True).stdout
    return sum(raw) / max(1, len(raw))
pad = json.load(open(f"{fp}/assets/footage/cam-pad/clip.json", encoding="utf-8"))
if (pad["rate"], pad["gop"], pad["file"], pad["from"]["file"], pad["color"]) != ("30000/1001", 29, "clip.mp4", "orig.mkv", ["tv", "bt709", "bt709", "bt709"]) \
        or pad["from"]["range"][0] != 2.002 or not pad["frames"] or pad["audio"]["rate"] != 48000 or pad["source"]["ref"] != "nasa:KSC-04012026-C4829":
    bad.append(f"cam-pad's clip.json: {pad}")
first = luma(f"{fp}/assets/footage/cam-pad/clip.mp4")
if abs(first - 120) > 3:   # source frame 60 (2.002 s, the keyframe): luma 2·60
    bad.append(f"cam-pad's first frame is not the keyframe's: luma {first:.1f}, 120 wanted")
crs = json.load(open(f"{fp}/assets/footage/cam-crs/clip.json", encoding="utf-8"))
if crs["rate"] != "25" or crs["frames"] != 150 or crs["audio"] is not None or not any("BT.601" in x for x in crs["assumed"]) or crs["from"]["range"] is not None:
    bad.append(f"cam-crs's clip.json: {crs}")
st = json.loads(subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", f"{fp}/assets/footage/cam-crs/clip.mp4"], capture_output=True, text=True).stdout)
v = st["streams"][0]
if (v["codec_name"], v.get("profile"), v["pix_fmt"], v.get("color_transfer"), v.get("color_primaries"), float(v["start_time"])) != ("h264", "High", "yuv420p", "bt709", "bt709", 0.0):
    bad.append(f"cam-crs's clip.mp4: {v['codec_name']} {v.get('profile')} {v['pix_fmt']} {v.get('color_transfer')} {v.get('start_time')}")
d = json.load(open(f"{fp}/assets/ledger.json", encoding="utf-8"))
R = {r["id"]: r for r in d["assets"]}
if sorted(R) != ["cam-crs", "cam-pad"] or any(ledger.validate(r) for r in R.values()):
    bad.append(f"the ledger: {sorted(R)} {[ledger.validate(r) for r in R.values()]}")
else:
    p, c = R["cam-pad"], R["cam-crs"]
    if (p["path"], p["kind"], p["license"]["class"], p["source"]["provider"], p["source"]["range"], c["license"]["class"], c["source"]["author"]) \
            != ("assets/footage/cam-pad/", "video", "pd", "nasa", pad["from"]["range"], "cc-by", "The Eloquent Peasant") or "insignia" not in p.get("note", ""):
        bad.append(f"the records: {p} {c}")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
    then ok "footage get --offline: --range from the keyframe before it (stream-copied into Matroska, its first frame kept), conformed frame for frame (CFR at 30000/1001, keyframes ≤ 1 s, BT.709 tv, sound at 48 kHz); a WebM conformed to H.264 with the tags it lacked assumed; one record a clip folder; strict refuses BY-SA and --max-mb refuses before downloading; an id on record is exit 2"
    else bad "footage get (exits $rc:$rc2:$rc3:$rc4:$rc5): $(printf '%s | %s' "$a" "$b" | tail -c 600) $(cat "$t/e3" "$t/e4" "$t/e5" | tail -c 400)"; fi
    # an orig a get left behind is used again only when its mark says it is that file, whole: another file's (a --file
    # that failed after its download) is downloaded over, never registered as this one
    cu=https://upload.wikimedia.org/wikipedia/commons/8/88/SpaceX_CRS-35_launch_and_jellyfish_cloud.webm
    fq="$t/fq"; cp -R tools/assets/fixtures/footage/project "$fq"; mkdir -p "$fq/assets/footage/cam-x" "$fq/assets/footage/cam-y"
    cp "$fr/media/nasa-orig.mp4.bin" "$fq/assets/footage/cam-x/orig.webm"
    printf '{"file_url": "https://example.org/another.webm", "bytes": %s}\n' "$(wc -c < "$fr/media/nasa-orig.mp4.bin")" > "$fq/assets/footage/cam-x/.orig.json"
    cp "$fr/media/commons-crs35.webm.bin" "$fq/assets/footage/cam-y/orig.webm"
    printf '{"file_url": "%s", "bytes": %s}\n' "$cu" "$(wc -c < "$fr/media/commons-crs35.webm.bin")" > "$fq/assets/footage/cam-y/.orig.json"
    a=$(vh footage get "$fq" "commons:File:SpaceX CRS-35 launch and jellyfish cloud.webm" --id cam-x --offline "$fr" 2>&1); rc=$?
    b=$(vh footage get "$fq" "commons:File:SpaceX CRS-35 launch and jellyfish cloud.webm" --id cam-y --offline "$fr" 2>&1); rc2=$?
    if [ "$rc:$rc2" = "0:0" ] && case "$a|$b" in *"kept, not downloaded again"*"|"*) false ;; *"|"*"kept, not downloaded again"*) true ;; *) false ;; esac && python3 - "$fq" "$fr/media/commons-crs35.webm.bin" <<'PY'
import hashlib, json, sys
fp, want = sys.argv[1], hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest()
got = [json.load(open(f"{fp}/assets/footage/{c}/clip.json", encoding="utf-8"))["from"]["sha256"] for c in ("cam-x", "cam-y")]
sys.exit(0 if got == [want, want] else 1)
PY
    then ok "footage get: an orig a get left behind is used again only when its mark names that file, whole; another file's is downloaded over, not registered as this one"
    else bad "footage get, an orig left behind (exits $rc:$rc2): $(printf '%s | %s' "$a" "$b" | tail -c 500)"; fi
    # --license / --license-url are the user's word over the site's record: on record as given, the note keeps what the
    # site said; an Archive rights text with no licence link is the uploader's own words (unknown); CJK titles get ids apart
    a=$(vh footage get "$fq" "commons:File:SpaceX CRS-35 launch and jellyfish cloud.webm" --id cam-z --license "CC BY 4.0" \
      --license-url https://creativecommons.org/licenses/by/4.0/ --offline "$fr" 2>&1); rc=$?
    if [ "$rc" = 0 ] && python3 - "$fq" <<'PY'
import json, sys
sys.path.insert(0, "tools/assets")
import footage
r = {x["id"]: x for x in json.load(open(f"{sys.argv[1]}/assets/ledger.json", encoding="utf-8"))["assets"]}["cam-z"]
ids = {footage.default_id({"site": "commons", "id": t}) for t in ("File:嫦娥六号.webm", "File:嫦娥五号.webm")}
ok = (r["license"]["by"] == "given" and r["license"]["class"] == "cc-by" and "licence given with --license" in (r.get("note") or "")
      and footage.judge("archive", {"license": "Public Domain", "license_url": ""})[0] == "unknown"
      and footage.judge("archive", {"license": "", "license_url": "http://creativecommons.org/licenses/publicdomain/"})[0] == "pd"
      and len(ids) == 2 and all(len(x) > 3 for x in ids) and footage.default_id({"site": "archive", "id": "Apollo 11"}) == "ia-apollo-11")
sys.exit(0 if ok else 1)
PY
    then ok "footage get --license: on record as given, the site's own reading in the note; an Archive rights text with no licence link is unknown; two CJK titles get ids apart"
    else bad "footage get --license, judge, default_id (exit $rc): $(printf '%s' "$a" | tail -c 400)"; fi
    vh footage sync "$fp" cam-pad --group launch --c 1.0 --by "fixture" >/dev/null 2>&1; rc=$?
    a=$(vh footage sync "$fp" cam-crs --group launch --c 2.5 --k 2.5 2>&1); rc2=$?
    vh footage frames "$fp" cam-pad --film 0:2 --t0 1.0 >/dev/null 2>"$t/e1"; rc3=$?
    vh footage frames "$fp" cam-crs --film 0:2 --t0 1.0 >/dev/null 2>"$t/e2"; rc4=$?
    vh footage frames "$fp" cam-crs --film 0:2 --t0 1.0 --png --name crs-png >/dev/null 2>"$t/e3"; rc5=$?
    vh footage frames "$fp" cam-crs --film 0:3 --t0 1.0 >/dev/null 2>"$t/e4"; rc6=$?
    b=$(vh assets check "$fp" 2>&1)
    if [ "$rc:$rc2:$rc3:$rc4:$rc5:$rc6" = "0:0:0:0:0:1" ] && grep -q "fall outside cam-crs" "$t/e4" \
       && case "$a|$b" in *"cam-crs"*"s = 2.5·M + 2.5"*"cam-pad"*"s = 1·M + 1"*"|"*"pass (0 fail"*) true ;; *) false ;; esac && python3 - "$fp" <<'PY'
import json, math, os, subprocess, sys
fp, bad = sys.argv[1], []
names = sorted(os.listdir(f"{fp}/assets/frames/cam-pad"))
if names[0] != "00000.jpg" or names[-2:] != ["00059.jpg", "frames.json"] or len(names) != 61:
    bad.append(f"cam-pad's frames: {names[:2]} … {names[-2:]} ({len(names)})")
spec = json.load(open(f"{fp}/assets/frames/crs-png/frames.json", encoding="utf-8"))
if spec["frames"] != [0, 60] or spec["map"]["t0"] != 1.0 or spec["clip_frames"] != [0, 122]:
    bad.append(f"crs-png's frames.json: {spec}")
for n in (0, 1, 30, 59):   # film frame n shows clip frame ⌊(2.5·(n/30 − 1) + 2.5)·25 + 10⁻⁶⌋, whose luma is 4·j mod 256
    j = math.floor((2.5 * (n / 30 - 1) + 2.5) * 25 + 1e-6)
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", f"{fp}/assets/frames/crs-png/{n:05d}.png", "-vf", "format=gray", "-f", "rawvideo", "-"], capture_output=True).stdout
    got = sum(raw) / max(1, len(raw))
    if abs(got - (4 * j) % 256) > 3:
        bad.append(f"crs-png film frame {n}: luma {got:.1f}, clip frame {j} has {(4 * j) % 256}")
R = {r["id"]: r for r in json.load(open(f"{fp}/assets/ledger.json", encoding="utf-8"))["assets"]}
f = R.get("cam-crs.frames") or {}
if f.get("derived_from") != "cam-crs" or f.get("license", {}).get("class") != "cc-by" or f.get("path") != "assets/frames/cam-crs/" or R["cam-pad"]["path"] != "assets/footage/cam-pad/":
    bad.append(f"the frames' record: {f}")
if json.load(open(f"{fp}/assets/footage/cam-crs/clip.json", encoding="utf-8"))["sync"] != {"group": "launch", "c": 2.5, "k": 2.5}:
    bad.append("cam-crs's sync row")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
    then ok "footage sync and frames: s = k·M + c in clip.json, the record's hash taken again; frames named by film frame number, slow motion picking ⌊s·rate⌋ frame for frame; frames outside the clip are exit 1; each bake on record, derived from its clip; assets check passes"
    else bad "footage sync and frames (exits $rc:$rc2:$rc3:$rc4:$rc5:$rc6): $(printf '%s | %s' "$a" "$b" | tail -c 500) $(cat "$t/e1" "$t/e2" "$t/e3" "$t/e4" | tail -c 300)"; fi
    vh assets remove "$fp" crs-png.frames >/dev/null 2>&1; rm -rf "$fp/assets/frames/crs-png"
    a=$(vh render "$fp" --out "$fp/out/film.mp4" --workers 1 2>&1); rc=$?
    case "$rc:$a" in
      *"needs a headless Chrome"*) no_chrome "footage end to end (render, assets check, deliver's credits)" ;;
      0:*) a=$(vh assets check "$fp" 2>&1); rc=$?
        b=$(vh deliver "$fp/out/film.mp4" --psnr off 2>&1); rc2=$?
        case "$rc:$rc2|$a|$b" in "0:0|"*"121 files their pages loaded"*"pass (0 fail, 0 warn)"*"|"*"credits: 1 line(s) the licences ask for, 1 courtesy"*'- “SpaceX CRS-35 launch and jellyfish cloud”, The Eloquent Peasant, Wikimedia Commons'*"CC BY 4.0"*'- “Artemis II Launch from OSB II Balcony - Slo Mo”'*"NASA ("*)
            ok "footage end to end: two clips got offline, synced and baked; the page that loads their frames rendered; assets check finds every frame on record; deliver prints the CC BY credit and the NASA courtesy line once each (the frames credited through their clips)" ;;
          *) bad "footage end to end (exits $rc:$rc2): $(printf '%s | %s' "$a" "$b" | tail -c 700)" ;; esac ;;
      *) bad "footage end to end, render (exit $rc): $(printf '%s' "$a" | tail -c 500)" ;;
    esac
  else skip "footage get, sync and frames" "no ffmpeg with libx264 and libvpx"; fi
  # doctor --probe: the key-less sites from recordings (no key; an answer without the path footage reads fails); --only
  mkdir -p "$t/rec"
  printf '{"collection": {"items": [{"data": [{"nasa_id": "x"}]}]}}' > "$t/rec/nasa.json"; printf '{"query": {"search": []}}' > "$t/rec/commons.json"
  printf '{"v": 1, "responses": [{"url": "https://images-api.nasa.gov/search?q=Apollo%%2011&media_type=video&page_size=1", "status": 200, "body": "nasa.json"}, {"url": "https://commons.wikimedia.org/w/api.php?action=query&format=json&list=search&srsearch=Apollo%%2011&srnamespace=6&srlimit=1", "status": 200, "body": "commons.json"}]}' > "$t/rec/responses.json"
  a=$(python3 tools/doctor.py --json --probe --only nasa-images,wikimedia-commons --offline "$t/rec" 2>&1); rc=$?
  b=$(python3 tools/doctor.py --json --probe --only no-such-module --offline "$t/rec" 2>&1); rc2=$?
  if [ "$rc:$rc2" = "0:2" ] && python3 -c '
import json, sys
m = {x["name"]: x["probe"] for x in json.loads(sys.argv[1])["modules"]}
ok = (m["nasa-images"]["state"] == "ok" and "no key" in m["nasa-images"]["note"]
      and m["wikimedia-commons"]["state"] == "failed" and "no query.search in the answer" in m["wikimedia-commons"]["note"] and m["internet-archive"] is None and m["gemini"] is None)
sys.exit(0 if ok else 1)' "$a"
  then ok "doctor --probe: footage's sites answered from recordings with no key (an answer without the path footage reads fails); --only probes those alone, an unknown name is exit 2"
  else bad "doctor --probe, key-less (exits $rc:$rc2): $(printf '%s | %s' "$a" "$b" | tail -c 500)"; fi
  # HDR: after --tonemap, the conform's scale reads what zscale made (BT.709, tv), not the source's matrix again (that
  # once turned (93,100,192) into (86,103,192)); where ffmpeg has zscale, the clip's pixels are the tone map's own
  mkdir -p "$t/hdr"
  ffmpeg -v error -y -f lavfi -i "color=c=0x5d64c0:s=320x180:r=30:d=1" -c:v ffv1 \
    -vf "format=yuv420p10le,setparams=color_trc=smpte2084:color_primaries=bt2020:colorspace=bt2020nc:range=tv" "$t/hdr/orig.mkv"
  if a=$(python3 - "$t/hdr" <<'PY'
import subprocess, sys
from pathlib import Path
sys.path.insert(0, "tools/assets")
import footage
d, bad = Path(sys.argv[1]), []
p = footage.probe(d / "orig.mkv")
try:
    footage.conform_argv(d / "orig.mkv", d / "x.mp4", p)
    bad.append("HDR footage without --tonemap was conformed")
except footage.Failed:
    pass
argv = footage.conform_argv(d / "orig.mkv", d / "x.mp4", p, "hable")[0]
vf = argv[argv.index("-vf") + 1]
sc = vf[vf.index(",scale="):]
if "tonemap=hable" not in vf or "in_color_matrix=bt709:in_range=tv" not in sc:
    bad.append(f"the scale after the tone map: {sc[:160]}")
zs = " zscale " in subprocess.run(["ffmpeg", "-hide_banner", "-filters"], capture_output=True, text=True).stdout
if zs and not bad:
    def yuv(path, vf=None):   # the middle pixel's Y, U, V
        raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path)] + (["-vf", vf] if vf else []) + ["-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "yuv444p", "-"],
                             capture_output=True, check=True).stdout
        n = len(raw) // 3; c = n // 2 + 160
        return raw[c], raw[n + c], raw[2 * n + c]
    ref = yuv(d / "orig.mkv", vf[:vf.index(",scale=")])
    footage.conform(d, d / "orig.mkv", "hable")
    got = yuv(d / "clip.mp4")
    if max(abs(x - y) for x, y in zip(ref, got)) > 2:
        bad.append(f"tone-mapped pixels: the clip has YUV {got}, the tone map {ref}")
print("\n".join(bad) if bad else ("compared" if zs else "")); sys.exit(1 if bad else 0)
PY
  ); then ok "footage --tonemap: the scale after the tone map reads BT.709 tv, not the HDR source's matrix$( [ "$a" = compared ] && echo '; the clip'"'"'s pixels are the tone map'"'"'s own' || echo ' (no zscale here, so the pixels are not compared)'); HDR without --tonemap is refused"
  else bad "footage --tonemap: $a"; fi
  # a download is the working clip as it is only when it is what a conform makes: H.264 High, and every GOP closed (an
  # open one's leading frames, shown before their keyframe, lean on the GOP before it: a cut there cannot decode them)
  for k in closed open main; do
    case $k in main) pr=main; xp="" ;; open) pr=high; xp=":open-gop=1" ;; *) pr=high; xp="" ;; esac
    ffmpeg -v error -y -f lavfi -i "testsrc2=s=160x90:r=30:d=2" -vf "format=yuv420p,setparams=range=tv:colorspace=bt709:color_primaries=bt709:color_trc=bt709" \
      -c:v libx264 -profile:v "$pr" -x264-params "keyint=15:min-keyint=15:bframes=3:scenecut=0$xp" -movflags +faststart "$t/hdr/$k.mp4"
  done
  if a=$(python3 - "$t/hdr" <<'PY'
import sys
sys.path.insert(0, "tools/assets")
import footage
d = sys.argv[1]
why = {k: footage.unfit(f"{d}/{k}.mp4", footage.probe(f"{d}/{k}.mp4"), footage.video_packets(f"{d}/{k}.mp4")) for k in ("closed", "open", "main")}
ok = why["closed"] == [] and any("open GOPs" in x for x in why["open"]) and len(why["open"]) == 1 and why["main"] == ["h264 Main, not H.264 High"]
print(why); sys.exit(0 if ok else 1)
PY
  ); then ok "footage: a download is kept as the working clip only when it is H.264 High with every GOP closed; an open GOP and a Main profile are conformed"
  else bad "footage, what is kept as it is: $a"; fi
  if a=$(python3 - "$t/hdr" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, "tools/assets")
import fetch
d = Path(sys.argv[1])
class NoLength(fetch.Live):   # a server that says no Content-Length
    def open(self, url, headers=None, timeout=60):
        body, pos = b"x" * 5000, [0]
        def read(n=-1):
            part = body[pos[0]:] if n is None or n < 0 else body[pos[0]:pos[0] + n]
            pos[0] += len(part)
            return part
        return fetch.Response(200, {"Content-Type": "application/octet-stream"}, read)
try:
    fetch.download("https://example.org/big.bin", d / "big.bin", opener=NoLength(), max_bytes=1000)
    print("downloaded past the cap"); sys.exit(1)
except fetch.FetchError as e:
    left = [p.name for p in d.glob("big.bin*")]
    print(e, left); sys.exit(0 if "cap" in str(e) and not left else 1)
PY
  ); then ok "fetch.download: --max-mb holds when the server says no length too: stopped at the cap, nothing kept"
  else bad "fetch.download's cap without a Content-Length: $a"; fi
  rm -rf "$t"
}

image_checks() {   # bin/vh image (tools/assets/image.py) from the answer recorded live (gemini-nano-banana-2.1,
  # 2026-10-26: every field kept, its picture and thought signature replaced by small ones; the blocked one documented)
  # and a stand-in codex writing the events the real one wrote: the estimate and what a call cost by its usage; no
  # budget, or one it would go over, and nothing is called; a
  # dry run calls nothing; a picture on record (aigc, model, prompt, seed, inputs); a replay holds and spends nothing; a paid
  # call (a stand-in API on this machine) is held and settled as it was billed; --alpha cuts out the chroma green; codex on
  # the plan's quota holds no budget
  local t p r a b rc rc2 rc3 rc4 rc5 rc6
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX"); r="$t/r"; cp -R tools/assets/fixtures/image/responses "$r"
  if a=$(python3 - <<'PY'
import sys
sys.path.insert(0, "tools/assets")
import fetch, image as I
bad = []
e = I.estimate("gemini-nano-banana-2.1", "1K", 0, "x" * 40)
if abs(e["amount"] - (0.0336 + 60 * 1.5e-6 + 2000 * 7.5e-6)) > 1e-9 or I.estimate("gemini-3-pro-image", "4K", 2, "")["picture"] != 0.24:
    bad.append(f"estimate: {e}")
u = {"total_input_tokens": 52, "total_output_tokens": 1132, "output_tokens_by_modality": [{"modality": "image", "tokens": 1120}, {"modality": "text", "tokens": 12}], "total_thought_tokens": 310}
if I.cost_of("gemini-nano-banana-2.1", u, 9)[0] != 0.036093 or I.cost_of("gemini-3-pro-image", {"promptTokenCount": 10, "candidatesTokenCount": 1120,
        "candidatesTokensDetails": [{"modality": "IMAGE", "tokenCount": 1120}]}, 9)[0] != round(10 * 2e-6 + 1120 * 120e-6, 6) or I.cost_of("gemini-3-pro-image", {}, 0.2)[0] != 0.2:
    bad.append("cost_of: the usage of either API's answer")
png = b"\x89PNG\r\n\x1a\n" + b"\0\0\0\rIHDR" + (64).to_bytes(4, "big") + (36).to_bytes(4, "big") + b"\x08\x06\0\0\0"
import base64
b64 = base64.b64encode(png).decode()
for ans in ({"steps": [{"type": "model_output", "content": [{"type": "text", "text": "ok"}, {"type": "image", "mime_type": "image/png", "data": b64}]}]},
            {"candidates": [{"content": {"parts": [{"text": "ok"}, {"inlineData": {"mimeType": "image/png", "data": b64}}]}}], "usageMetadata": {"promptTokenCount": 3}}):
    data, mime, said, _ = I.picture_of(ans)
    if data != png or mime != "image/png" or said != "ok" or I.png_size(data) != (64, 36, True):
        bad.append(f"picture_of: {list(ans)}")
try:
    I.picture_of({"status": "failed", "steps": [], "errors": [{"message": "the request was blocked"}]}); bad.append("a blocked answer gave a picture")
except I.Failed as x:
    if "blocked" not in str(x):
        bad.append(f"blocked: {x}")
if fetch.scrub("key AQ.Ab12Cd34Ef56 and Cd34Ef56", {"x-goog-api-key": "AQ.Ab12Cd34Ef56"}).count("…") < 2 or "Cd34E" in fetch.scrub("Cd34Ef56", {"k": "AQ.Ab12Cd34Ef56"}):
    bad.append("scrub leaves a key's characters")
try:
    fetch.post_json("http://example.org/x", {}, secret={"k": "v"}); bad.append("a key went out over http")
except fetch.FetchError:
    pass
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
  ); then ok "image: the estimate (picture, references, prompt, thinking) and the cost by either API's usage; both answer shapes read, a blocked one says why; a key scrubbed from messages and never sent over http"
  else bad "image, prices and answers: $a"; fi
  if command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null; then
    p="$t/p"; mkdir -p "$p"; printf '# BRIEF\n\n## Spec\n- Output: 1920x1080, 30 fps\n- Assets: strict\n' > "$p/BRIEF.md"
    vh image gen "$p" --prompt "a yellow square on blue" --offline "$r" >/dev/null 2>"$t/e1"; rc=$?
    a=$(vh image gen "$p" --prompt "a yellow square on blue" --tier final --size 4K --dry-run 2>&1); rc2=$?
    printf -- '- Budget: $0.20\n' >> "$p/BRIEF.md"
    b=$(env -u GEMINI_API_KEY "$VH_BASH" "$ROOT/bin/vh" image gen "$p" --prompt "x" 2>&1); rc3=$?
    vh image gen "$p" --prompt "a yellow square on blue" --seed 7 --id sq --offline "$r" >/dev/null 2>"$t/e4"; rc4=$?
    if [ "$rc:$rc2:$rc3:$rc4" = "1:0:2:0" ] && grep -q "no budget" "$t/e1" && grep -qF 'write - Budget: $0.0487' "$t/e1" \
       && case "$a|$b" in *"4K 16:9: about \$0.2641"*"nothing called (--dry-run)"*"|"*"set GEMINI_API_KEY"*) true ;; *) false ;; esac \
       && [ ! -e "$p/assets/genimg/img-a-yellow-square-on" ] && python3 - "$p" <<'PY'
import json, sys
sys.path.insert(0, "tools/assets")
import budget, ledger
p, bad = sys.argv[1], []
R = {x["id"]: x for x in json.load(open(f"{p}/assets/ledger.json", encoding="utf-8"))["assets"]}
r = R.get("sq") or {}
if ledger.validate(r) or (r.get("aigc"), r.get("model"), r.get("seed"), r.get("cost"), r["license"]["class"], r["source"]["origin"], r.get("prompt_file")) \
        != (True, "gemini/gemini-nano-banana-2.1", 7, None, "generated", "generated", "assets/genimg/sq/prompt.txt") or "a call: $0.0355" not in r.get("offline", ""):
    bad.append(f"the record: {r}")
spend = open(f"{p}/assets/spend.jsonl", encoding="utf-8").read() if __import__("os").path.exists(f"{p}/assets/spend.jsonl") else ""
if spend.strip() or budget.spent(p).get("USD", 0):   # a replay holds and spends nothing
    bad.append(f"the spend of a replay: {spend}")
req = json.load(open(f"{p}/assets/genimg/sq/request.json", encoding="utf-8"))
if req["model"] != "gemini-nano-banana-2.1" or req["response_format"] != {"type": "image", "mime_type": "image/jpeg", "aspect_ratio": "16:9", "image_size": "1K"} \
        or req["generation_config"] != {"seed": 7, "thinking_level": "minimal"} or req["store"] is not False:
    bad.append(f"request.json: {req}")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
    then ok "image gen --offline: no budget and nothing is called (with the line to write); --dry-run calls nothing; no key is exit 2 by its name; a picture on record (aigc, model, prompt file, seed), request.json without the key; a replay holds and spends nothing and says what a call would cost"
    else bad "image gen (exits $rc:$rc2:$rc3:$rc4): $(printf '%s | %s' "$a" "$b" | tail -c 500) $(cat "$t/e1" "$t/e4" | tail -c 300)"; fi
    python3 -c 'import json,sys; f=sys.argv[1]+"/responses.json"; d=json.load(open(f)); d["responses"][0]["body"]="answer-green.json"; json.dump(d, open(f, "w"))' "$r"
    vh image gen "$p" --prompt "a red sticker" --alpha --id sticker --offline "$r" >/dev/null 2>"$t/e1"; rc=$?
    a=$(vh image cutout "$p" assets/genimg/sticker/image.jpg --json 2>/dev/null); rc2=$?
    vh image cutout "$p" assets/genimg/sticker/image.jpg --id other >/dev/null 2>"$t/e3"; rc3=$?
    python3 -c 'import json,sys; f=sys.argv[1]+"/responses.json"; d=json.load(open(f)); d["responses"][0]["body"]="answer-blocked.json"; json.dump(d, open(f, "w"))' "$r"
    vh image gen "$p" --prompt "blocked" --id blocked --offline "$r" >/dev/null 2>"$t/e4"; rc4=$?
    python3 -c 'import json,sys; f=sys.argv[1]+"/responses.json"; d=json.load(open(f)); d["responses"][0]["body"]="answer-plain.json"; json.dump(d, open(f, "w"))' "$r"
    vh image gen "$p" --prompt "two" --n 2 --id two --offline "$r" >/dev/null 2>"$t/e5"; rc5=$?
    vh image gen "$p" --prompt "one too many" --n 5 --offline "$r" >/dev/null 2>"$t/e6"; rc6=$?
    if [ "$rc:$rc2:$rc3:$rc4:$rc5:$rc6" = "0:0:2:1:0:1" ] && grep -q "the request was blocked" "$t/e4" && grep -q "short" "$t/e6" \
       && [ ! -e "$p/assets/genimg/blocked/image.jpg" ] && [ -s "$p/assets/genimg/sticker/image.cutout-check.png" ] && [ -s "$p/assets/genimg/two/sheet.png" ] \
       && python3 - "$p" "$a" <<'PY'
import json, subprocess, sys
sys.path.insert(0, "tools/assets")
import budget
p, c, bad = sys.argv[1], json.loads(sys.argv[2]), []
if not (0.14 < c["opaque"] < 0.19) or c["spill"] > 4 or c["record"]["id"] != "sticker.cutout" or c["record"]["derived_from"] != "sticker" or c["record"]["aigc"] is not True:
    bad.append(f"the cutout: {c}")
fmt = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=pix_fmt", "-of", "csv=p=0", f"{p}/assets/genimg/sticker/image.cutout.png"], capture_output=True, text=True).stdout.strip()
if fmt != "rgba":
    bad.append(f"the cutout's pixels: {fmt}")
R = [x["id"] for x in json.load(open(f"{p}/assets/ledger.json", encoding="utf-8"))["assets"]]
if R != ["sq", "sticker", "sticker.cutout", "two-1", "two-2"]:
    bad.append(f"the records: {R}")
if budget.spent(p).get("USD", 0):   # replays: nothing held or spent, a blocked one neither
    bad.append(f"the spend of replays: {budget.spent(p)}")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
    then ok "image gen --alpha: the chroma green measured and cut out (straight RGBA, a check on three grounds, on record and derived); cut out again, the same record; a blocked answer leaves no picture; --n 2 with a sheet; a call the budget cannot take is refused with the shortfall"
    else bad "image gen --alpha, blocked, --n (exits $rc:$rc2:$rc3:$rc4:$rc5:$rc6): $(printf '%s' "$a" | tail -c 300) $(cat "$t/e1" "$t/e3" "$t/e4" "$t/e5" "$t/e6" | tail -c 500)"; fi
    # a paid call, against a stand-in Interactions API on this machine (post_json takes http only there): held at the
    # estimate and settled by the answer's usage; a blocked answer by its usage too (its input); an error answer at 0; an
    # answer cut off after the request left keeps the estimate ("may have been billed"); a request that never left at 0
    if a=$(python3 - "$t" <<'PY'
import contextlib, io, json, os, sys, threading
from http.server import BaseHTTPRequestHandler
from pathlib import Path
sys.path.insert(0, "tools/assets")
import image
from fetch import LocalServer   # (http.server's own bind, which asks socket.getfqdn, stalled 35 s on GitHub's macOS runners)
t, fx, mode = Path(sys.argv[1]), Path("tools/assets/fixtures/image/responses"), {"m": "ok"}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if mode["m"] == "cut":   # the request arrived; no answer comes back
            return
        body, code = {"ok": ((fx / "answer-plain.json").read_bytes(), 200), "blocked": ((fx / "answer-blocked.json").read_bytes(), 200),
                      "http400": (b'{"error": {"code": 400, "message": "bad request"}}', 400)}[mode["m"]]
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
srv = LocalServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
image.API = f"http://127.0.0.1:{srv.server_address[1]}/v1beta/interactions"
os.environ["GEMINI_API_KEY"] = "test-not-a-key"
p = t / "paid"
p.mkdir()
(p / "BRIEF.md").write_text("# BRIEF\n\n## Spec\n- Output: 1920x1080, 30 fps\n- Budget: $1\n", encoding="utf-8")
codes, said = {}, {}
def gen(m):
    err = io.StringIO()
    with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
        codes[m] = image.main(["gen", str(p), "--prompt", "x", "--id", f"p-{m}"])
    said[m] = err.getvalue()
for m in ("ok", "blocked", "http400", "cut"):
    mode["m"] = m
    gen(m)
srv.shutdown()
srv.server_close()   # nothing listens there now: a request that never leaves
gen("refused")
spend = [json.loads(x) for x in open(p / "assets/spend.jsonl", encoding="utf-8")]
held = {x["asset"]: x["amount"] for x in spend if x["kind"] == "hold"}
settled = {x["asset"]: x["amount"] for x in spend if x["kind"] == "settle"}
want = {"p-ok": 0.035454, "p-blocked": 0.000078, "p-http400": 0.0, "p-cut": held.get("p-cut"), "p-refused": 0.0}
bad = []
if codes != {"ok": 0, "blocked": 1, "http400": 1, "cut": 1, "refused": 1}:
    bad.append(f"exits {codes}")
if settled != want or not held.get("p-cut"):
    bad.append(f"settled {settled}, wanted {want}")
if "may have been billed" not in said["cut"] or "may have been billed" in said["http400"] + said["refused"]:
    bad.append(f"what was said: {said}")
rec = {x["id"]: x for x in json.load(open(p / "assets/ledger.json", encoding="utf-8"))["assets"]}
if list(rec) != ["p-ok"] or rec["p-ok"]["cost"] != {"amount": 0.035454, "currency": "USD"}:
    bad.append(f"the records: {list(rec)}")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
    ); then ok "image gen, a paid call (a stand-in API on this machine): held, settled by the answer's usage; a blocked answer by its usage; an error answer and a request that never left at 0; an answer cut off keeps the estimate, said as maybe billed"
    else bad "image gen, settling a paid call: $a"; fi
    mkdir -p "$t/codex"
    a=$(PATH="$ROOT/tools/assets/fixtures/image/bin:$PATH" CODEX_HOME="$t/codex" FAKE_CODEX_PNG="$p/assets/genimg/sticker/image.cutout.png" vh image gen "$p" --prompt "a tile" --provider codex --alpha --id tile 2>&1); rc=$?
    PATH="$ROOT/tools/assets/fixtures/image/bin:$PATH" vh image gen "$p" --prompt "x" --provider codex --size 2K >/dev/null 2>&1; rc2=$?
    b=$(PATH="$ROOT/tools/assets/fixtures/image/bin:$PATH" CODEX_HOME="$t/codex" FAKE_CODEX_FAIL=1 vh image gen "$p" --prompt "y" --provider codex --id nomodel 2>&1); rc3=$?
    if [ "$rc:$rc2:$rc3" = "0:2:1" ] && case "$a" in *"made tile"*"the ChatGPT plan's quota"*) true ;; *) false ;; esac \
       && case "$b" in *"codex said: The 'some-model' model is not supported when using Codex with a ChatGPT account. [model_not_found]"*"a newer codex CLI may know it"*) true ;; *) false ;; esac \
       && ! grep -q '"nomodel"' "$p/assets/ledger.json" && python3 - "$p" <<'PY'
import json, os, sys
p = sys.argv[1]
r = {x["id"]: x for x in json.load(open(f"{p}/assets/ledger.json", encoding="utf-8"))["assets"]}["tile"]
spend = [json.loads(x) for x in open(f"{p}/assets/spend.jsonl", encoding="utf-8")] if os.path.exists(f"{p}/assets/spend.jsonl") else []
sys.exit(0 if "image_gen via codex (codex-cli 0.0.0-test)" in r["model"] and "cost" not in r and r["aigc"] and not any(x.get("asset") == "tile" for x in spend) else 1)
PY
    then ok "image gen --provider codex (a stand-in CLI): the picture found under CODEX_HOME by its thread, on record as AI-generated with no cost and no budget held; gemini's options refused; a turn that failed on its model is said in codex's own words, with what to change"
    else bad "image gen --provider codex (exits $rc:$rc2:$rc3): $(printf '%s | %s' "$a" "$b" | tail -c 600)"; fi
  else skip "image gen and cutout" "no ffmpeg"; fi
  rm -rf "$t"
}

library_checks() {   # the sound library (tools/audio/library.py: bin/vh sfx search|pick, bgm search|pick, sound add|list)
  # from Openverse's recorded answers, with sounds made by ffmpeg: results and their licence classes under either policy;
  # a pack registered where it is (a copy skipped); a pick from the library and from Openverse into the project (takes
  # named _a, the site's credit line verbatim, strict refusing NC before a download); bgm cut on a downbeat of the grid
  local t r l p a b rc rc2 rc3 rc4 rc5 rc6
  if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null; then skip "sound library (sfx|bgm search and pick, sound add)" "no ffmpeg"; return; fi
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX"); r="$t/r"; l="$t/lib"; p="$t/p"; cp -R tools/audio/fixtures/library/responses "$r"; mkdir -p "$r/media" "$p" "$t/q" "$t/pack/doors"
  for id in eab8a6e2 f340c2c6 aec0904a e8978d57; do ffmpeg -v error -y -f lavfi -i "sine=f=440:r=44100:d=0.8" -f wav "$r/media/$id.bin"; done
  ffmpeg -v error -y -f lavfi -i "sine=f=220:r=44100:d=20" -ac 2 -f wav "$r/media/5f7af4b0.bin"
  ffmpeg -v error -y -f lavfi -i "sine=f=300:r=48000:d=0.6" "$t/pack/doors/wood_door_close.wav"
  ffmpeg -v error -y -f lavfi -i "sine=f=500:r=48000:d=0.9" "$t/pack/doors/metal_door_slam.wav"
  cp "$t/pack/doors/wood_door_close.wav" "$t/pack/wood_copy.wav"   # the same bytes, after doors/ in path order: skipped
  printf '# BRIEF\n\n## Spec\n- Assets: strict\n- Language: en\n' > "$p/BRIEF.md"; printf '# BRIEF\n\n## Spec\n- Assets: record\n' > "$t/q/BRIEF.md"
  lv() { OVH_SOUND_LIB="$l" vh "$@"; }
  a=$(lv sfx search whoosh --top 5 --project "$p" --offline "$r" --json 2>/dev/null); rc=$?
  b=$(lv sfx search whoosh --top 6 --where openverse --project "$t/q" --offline "$r" --json 2>/dev/null); rc2=$?
  lv sound add "$t/pack" --source kenney --license "CC0 1.0" >"$t/o3" 2>&1; rc3=$?
  lv sound add "$t/pack/doors" --source kenney --license "CC0 1.0" >"$t/o4" 2>&1; rc4=$?
  c=$(lv sfx search "door close" --where library --dur 0.5-1 --json 2>/dev/null); rc5=$?
  if [ "$rc:$rc2:$rc3:$rc4:$rc5" = "0:0:0:0:0" ] && grep -q "2 file(s) into" "$t/o3" && grep -q "1 on record already" "$t/o3" && grep -q "0 file(s) into.*2 on record already" "$t/o4" \
     && python3 - "$a" "$b" "$c" "$l" <<'PY'
import json, sys
sys.path.insert(0, "tools/assets")
import ledger
a, b, c, lib = json.loads(sys.argv[1]), json.loads(sys.argv[2]), json.loads(sys.argv[3]), sys.argv[4]
bad = []
got = [(x["ref"][:18], x["class"], x["license"]) for x in a["results"]]
if got[:2] != [("openverse:eab8a6e2", "cc0", "CC0 1.0"), ("openverse:f1dc6045", "cc0", "CC0 1.0")] or a["policy"] != "strict" or not all(x["taken"] for x in a["results"]) \
        or abs(a["results"][0]["duration"] - 3.155) > 1e-6 or "freesound.org" not in a["results"][0]["page"]:
    bad.append(f"strict search: {got}")
nc = [x for x in b["results"] if x["class"] == "cc-by-nc"]
if b["policy"] != "record" or len(nc) != 1 or not nc[0]["taken"] or nc[0]["ref"][:18] != "openverse:e8978d57":
    bad.append(f"record search: {[(x['ref'][:18], x['class']) for x in b['results']]}")
recs = ledger.read_jsonl(f"{lib}/ledger.jsonl")
if len(recs) != 2 or any(ledger.validate(r) for r in recs) or {r["license"]["class"] for r in recs} != {"cc0"} or not all(r["sound"]["duration"] for r in recs) \
        or "doors" not in recs[0]["tags"]:
    bad.append(f"sound add: {[(r['id'], r['path'], ledger.validate(r)) for r in recs]}")
if [x["ref"] for x in c["results"]] != ["lib:kenney-wood_door_close", "lib:kenney-metal_door_slam"]:
    bad.append(f"library search: {[(x['ref'], x['score']) for x in c['results']]}")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
  then ok "sfx search: Openverse's results with their licence classes (strict asks for CC0 and CC BY; record takes NC and says so); sound add registers a pack where it is, one record a file, a copy skipped; the library found by name and tag first, --dur kept"
  else bad "sfx search, sound add (exits $rc:$rc2:$rc3:$rc4:$rc5): $(printf '%s | %s' "$a" "$c" | tail -c 400) $(cat "$t/o3" "$t/o4" | tail -c 300)"; fi
  lv sfx search whoosh --top 5 --project "$p" --offline "$r" >/dev/null 2>&1
  lv sfx pick "$p" openverse:eab8a6e2 --as whoosh --offline "$r" >/dev/null 2>"$t/e1"; rc=$?
  lv sfx pick "$p" openverse:f340c2c6 --as whoosh --offline "$r" >/dev/null 2>"$t/e2"; rc2=$?
  lv sfx pick "$p" lib:kenney-wood_door_close --as door --used-by S03 >/dev/null 2>"$t/e3"; rc3=$?
  lv sfx search whoosh --top 6 --where openverse --project "$t/q" --offline "$r" >/dev/null 2>&1
  lv sfx pick "$p" openverse:e8978d57 --as hit --offline "$r" >/dev/null 2>"$t/e4"; rc4=$?
  lv bgm search "calm piano" --top 4 --offline "$r" >/dev/null 2>&1
  lv bgm pick "$p" openverse:5f7af4b0 --len 9 --fade 1 --beats tools/audio/fixtures/library/grid.beats.json --offline "$r" >/dev/null 2>"$t/e5"; rc5=$?
  lv bgm pick "$p" openverse:5f7af4b0 --as bed --len 7.3 --no-beats --offline "$r" >/dev/null 2>"$t/e6"; rc6=$?
  a=$(vh assets credits "$p" --lang en 2>/dev/null); b=$(vh assets check "$p" 2>&1)
  if [ "$rc:$rc2:$rc3:$rc4:$rc5:$rc6" = "0:0:0:1:0:0" ] && grep -q "cc-by-nc: Assets: strict (BRIEF) does not take it: nothing downloaded" "$t/e4" \
     && ! compgen -G "$l/sfx/openverse/e8978d57-*" >/dev/null && case "$a|$b" in *'"whoosh motron very low.wav" by melissapons is licensed under CC BY 4.0'*'"Intro" by zero-project is licensed under CC BY 3.0'*"|"*"pass (0 fail"*) true ;; *) false ;; esac \
     && python3 - "$p" "$l" <<'PY'
import json, subprocess, sys
sys.path.insert(0, "tools/assets")
import ledger
p, lib = sys.argv[1:]
bad = []
def info(f):
    j = json.loads(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=sample_rate,channels:format=duration", "-of", "json", f], capture_output=True, text=True).stdout)
    return int(j["streams"][0]["sample_rate"]), float(j["format"]["duration"])
R = {x["id"]: x for x in json.load(open(f"{p}/assets/ledger.json", encoding="utf-8"))["assets"]}
if sorted(R) != ["bed", "door", "music", "whoosh", "whoosh_a"] or any(ledger.validate(r) for r in R.values()):
    bad.append(f"the records: {sorted(R)}")
else:
    w, wa, d, m = R["whoosh"], R["whoosh_a"], R["door"], R["music"]
    if (w["path"], wa["path"], w["source"]["origin"], w["source"]["provider"], w["license"]["class"], wa["license"]["class"]) \
            != ("audio/sfx/whoosh.wav", "audio/sfx/whoosh_a.wav", "library", "freesound", "cc0", "cc-by") or "attribution" in w \
            or not wa.get("attribution", "").startswith('"whoosh motron very low.wav" by melissapons') or w["library_id"] != "ov-eab8a6e2-0ac8-4615-9e0d-ebde30523783":
        bad.append(f"the sfx picks: {w} {wa}")
    if d["used_by"] != ["S03"] or d["source"]["provider"] != "kenney" or d["license"]["class"] != "cc0":
        bad.append(f"the library pick: {d}")
    if m["used_by"] != ["bgm"] or m["source"]["provider"] == "jamendo" is False:
        bad.append(f"the bgm pick: {m}")
for f, want in (("audio/sfx/whoosh.wav", None), ("audio/music.wav", 8.0), ("audio/bed.wav", 7.3)):
    sr, dur = info(f"{p}/{f}")
    if sr != 48000 or (want is not None and abs(dur - want) > 0.002):
        bad.append(f"{f}: {sr} Hz, {dur:.3f} s (want {want})")
g = json.load(open(f"{p}/audio/music.beats.json", encoding="utf-8"))
if g["duration"] != 8.0 or g["downbeats"] != [0.0, 2.0, 4.0, 6.0] or max(g["beats"]) >= 8.0 or "grid.beats.json" not in g["note"]:
    bad.append(f"music.beats.json: {g}")
lr = ledger.read_jsonl(f"{lib}/ledger.jsonl")
if not any(r["id"] == "ov-5f7af4b0-3629-4345-83ae-9ca5bca2e9d9" and r["sound"]["kind"] == "bgm" and r["path"].startswith("bgm/openverse/") for r in lr):
    bad.append("the library has no record of the bgm it downloaded")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
  then ok "sfx and bgm pick: an Openverse item into the library first, then the project at 48 kHz (a second take named _a), on record with the site's credit line verbatim (none for CC0); a library pick keeps its source; strict refuses NC before a download; bgm cut on the grid's last downbeat before --len with its beats up to the cut, or at --len with --no-beats; credits and check pass"
  else bad "sfx and bgm pick (exits $rc:$rc2:$rc3:$rc4:$rc5:$rc6): $(printf '%s | %s' "$a" "$b" | tail -c 500) $(cat "$t/e1" "$t/e2" "$t/e3" "$t/e4" "$t/e5" "$t/e6" | tail -c 500)"; fi
  a=$(vh sfx lib "$t/builtin" 2>&1); rc=$?; b=$(vh sfx search -h 2>&1); rc2=$?
  mkdir -p "$t/rec"; printf '{"results": [{"id": "x"}]}' > "$t/rec/ov.json"
  printf '{"v": 1, "responses": [{"url": "https://api.openverse.org/v1/audio/?q=whoosh&source=freesound&license=cc0&page_size=1", "status": 200, "body": "ov.json"}]}' > "$t/rec/responses.json"
  c=$(python3 tools/doctor.py --json --probe --only openverse --offline "$t/rec" 2>&1); rc3=$?
  if [ "$rc:$rc2:$rc3" = "0:0:0" ] && [ -f "$t/builtin/sfx-lib.json" ] && case "$a|$b" in *"21 SFX"*"|"*"usage: bin/vh sfx search"*) true ;; *) false ;; esac \
     && python3 -c 'import json,sys; m={x["name"]: x["probe"] for x in json.loads(sys.argv[1])["modules"]}; sys.exit(0 if m["openverse"]["state"] == "ok" and m["gemini"] is None else 1)' "$c"
  then ok "sfx: the built-in library and its old subcommands as before beside search and pick; doctor --probe asks Openverse with no key (from a recording)"
  else bad "sfx old and new, openverse probe (exits $rc:$rc2:$rc3): $(printf '%s | %s | %s' "$a" "$b" "$c" | tail -c 400)"; fi
  # a link in a search's answer is other people's data: only http(s) is taken (urllib would read a file:// one off this
  # machine), and no more than the cap, also from a server that says no length
  if a=$(python3 - "$t" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, "tools/audio")
sys.path.insert(0, "tools/assets")
import fetch, library
t, bad = Path(sys.argv[1]), []
class Big(fetch.Live):
    def open(self, url, headers=None, timeout=60):
        body, pos = b"x" * 5000, [0]
        def read(n=-1):
            part = body[pos[0]:] if n is None or n < 0 else body[pos[0]:pos[0] + n]
            pos[0] += len(part)
            return part
        return fetch.Response(200, {"Content-Type": "audio/mpeg"}, read)
for url in ("file:///etc/hosts", "ftp://example.org/a.mp3"):
    try:
        library.take(url, t / "x.mp3", Big()); bad.append(f"{url} was taken")
    except fetch.FetchError as e:
        if "not an http(s) link" not in str(e):
            bad.append(f"{url}: {e}")
library.MAX_BYTES = 1000
try:
    library.take("https://example.org/big.mp3", t / "big.mp3", Big()); bad.append("past the cap")
except fetch.FetchError as e:
    if "cap" not in str(e) or list(t.glob("big.mp3*")) or (t / "x.mp3").exists():
        bad.append(f"the cap: {e}")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
  ); then ok "sfx|bgm pick: only an http(s) link from a search's answer is taken (no file://), and no more than the cap, also with no length said"
  else bad "the library's downloads: $a"; fi
  rm -rf "$t"
}

lyria_checks() {   # bin/vh music --provider lyria (tools/audio/lyria.py) from answers in the documented shape and one
  # recorded live (lyria-3-clip-preview, 2026-10-26: every field kept, its 30 s of MP3 replaced by 0.5 s of tone): no
  # budget and nothing is called; a dry run calls nothing; no key is said by its name; a track on record (the answer as it
  # came and the 48 kHz WAV made from it), its price held and settled, the length and the instrumental asked for in words;
  # a blocked answer settles at 0 and leaves no track; the recorded clip read as it came (text and audio in two steps)
  local t r p a b rc rc2 rc3 rc4 rc5 rc6 rc7
  if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null; then skip "music --provider lyria" "no ffmpeg"; return; fi
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX"); r="$t/r"; p="$t/p"; cp -R tools/audio/fixtures/lyria/responses "$r"; mkdir -p "$p"
  printf '# BRIEF\n\n## Spec\n- Assets: strict\n- Language: en\n' > "$p/BRIEF.md"
  vh music --provider lyria "$p" --prompt "calm piano" --offline "$r" --no-beats >/dev/null 2>"$t/e1"; rc=$?
  a=$(vh music --provider lyria "$p" --prompt "calm piano" --dry-run 2>&1); rc2=$?
  printf -- '- Budget: $0.10\n' >> "$p/BRIEF.md"
  b=$(env -u GEMINI_API_KEY "$VH_BASH" "$ROOT/bin/vh" music --provider lyria "$p" --prompt "x" 2>&1); rc3=$?
  vh music --provider lyria "$p" --prompt "calm piano for an explainer" --len 30 --instrumental --no-beats --offline "$r" >/dev/null 2>"$t/e4"; rc4=$?
  python3 -c 'import json,sys; f=sys.argv[1]+"/responses.json"; d=json.load(open(f)); d["responses"][0]["body"]="answer-blocked.json"; json.dump(d, open(f, "w"))' "$r"
  printf -- '- Budget: $1\n' >> "$p/BRIEF.md"; sed 's/^- Budget: \$0.10$//' "$p/BRIEF.md" > "$t/b" && mv "$t/b" "$p/BRIEF.md"
  vh music --provider lyria "$p" --prompt "in the voice of a famous singer" --as other --no-beats --offline "$r" >/dev/null 2>"$t/e5"; rc5=$?
  vh music --provider lyria "$p" --prompt "again" --no-beats --offline "$r" >/dev/null 2>"$t/e6"; rc6=$?
  python3 -c 'import json,sys; f=sys.argv[1]+"/responses.json"; d=json.load(open(f)); d["responses"][0]["body"]="answer-clip.json"; json.dump(d, open(f, "w"))' "$r"
  vh music --provider lyria "$p" --model lyria-3-clip-preview --prompt "a calm, warm acoustic guitar piece" --instrumental --as clip --id clip --no-beats --offline "$r" >/dev/null 2>"$t/e7"; rc7=$?
  if [ "$rc:$rc2:$rc3:$rc4:$rc5:$rc6:$rc7" = "1:0:2:0:1:2:0" ] && grep -qF 'write - Budget: $0.08' "$t/e1" && grep -q "a named artist's voice" "$t/e5" && grep -q "audio/music.wav is there already" "$t/e6" \
     && case "$a|$b" in *'lyria-3.5, $0.08 a track'*"nothing called (--dry-run)"*"|"*"set GEMINI_API_KEY"*) true ;; *) false ;; esac \
     && [ ! -e "$p/audio/other.wav" ] && python3 - "$p" <<'PY'
import glob, json, subprocess, sys
sys.path.insert(0, "tools/assets")
import budget, ledger
p, bad = sys.argv[1], []
sys.path.insert(0, "tools/audio")
import lyria
if lyria.body_of("lyria-3-clip-preview", "x")["response_format"] != {"type": "audio"} or lyria.body_of("lyria-3.5", "x")["response_format"] != {"type": "audio", "mime_type": "audio/wav"}:
    bad.append("the response format: WAV asked of lyria-3.5 only")
R = {x["id"]: x for x in json.load(open(f"{p}/assets/ledger.json", encoding="utf-8"))["assets"]}
tr, wav = R.get("music-calm-piano-for-an") or {}, R.get("music-calm-piano-for-an-wav") or {}
if ledger.validate(tr) or ledger.validate(wav) or (tr.get("aigc"), tr.get("model"), tr.get("seed"), tr.get("cost"), tr["path"]) \
        != (True, "gemini/lyria-3.5", None, None, "assets/genmusic/music-calm-piano-for-an/track.wav") or "a call: $0.08" not in tr.get("offline", "") \
        or wav.get("derived_from") != tr.get("id") or wav.get("path") != "audio/music.wav" or wav.get("used_by") != ["bgm"]:
    bad.append(f"the records: {tr} {wav}")
ask = open(f"{p}/assets/genmusic/music-calm-piano-for-an/prompt.txt", encoding="utf-8").read()
req = json.load(open(f"{p}/assets/genmusic/music-calm-piano-for-an/request.json", encoding="utf-8"))
if "Length: about 30 seconds." not in ask or "Instrumental only, no vocals." not in ask or req["store"] is not False or "generation_config" in req:
    bad.append(f"what was asked: {ask!r} {req}")
st = json.loads(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=sample_rate,channels", "-of", "json", f"{p}/audio/music.wav"], capture_output=True, text=True).stdout)["streams"][0]
if (int(st["sample_rate"]), st["channels"]) != (48000, 2):
    bad.append(f"audio/music.wav: {st}")
if budget.spent(p).get("USD", 0):   # replays: nothing held or spent
    bad.append(f"the spend of replays: {budget.spent(p)}")
cl, cw = R.get("clip") or {}, R.get("clip-wav") or {}
if (cl.get("model"), cl.get("cost"), cl.get("path"), cw.get("path"), cw.get("derived_from")) != ("gemini/lyria-3-clip-preview", None,
        "assets/genmusic/clip/track.mp3", "audio/clip.wav", "clip") or open(f"{p}/assets/genmusic/clip/lyrics.txt", encoding="utf-8").read().strip() != "<instrumental>":
    bad.append(f"the recorded clip: {cl} {cw}")
if sorted(glob.glob(f"{p}/assets/genmusic/*/track.*")) != [f"{p}/assets/genmusic/clip/track.mp3", f"{p}/assets/genmusic/music-calm-piano-for-an/track.wav"]:
    bad.append(f"tracks: {glob.glob(p + '/assets/genmusic/*/track.*')}")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
  then ok "music --provider lyria --offline: no budget and nothing is called; --dry-run calls nothing; no key is exit 2 by its name; the track on record as AI-generated with the 48 kHz WAV made from it, a replay holding and spending nothing, length and instrumental asked in words; a blocked answer leaves no track; a name taken is exit 2; the answer recorded from lyria-3-clip-preview read as it came (MP3, text and audio in two steps)"
  else bad "music --provider lyria (exits $rc:$rc2:$rc3:$rc4:$rc5:$rc6:$rc7): $(printf '%s | %s' "$a" "$b" | tail -c 400) $(cat "$t/e1" "$t/e4" "$t/e5" "$t/e6" "$t/e7" | tail -c 500)"; fi
  # a paid call against a stand-in Interactions API on this machine: held and settled at the model's price per track (the
  # clip's, the whole track's); a blocked answer made no track (0); an error answer at 0; an answer cut off keeps the price
  if a=$(python3 - "$t" <<'PY'
import contextlib, io, json, os, sys, threading
from http.server import BaseHTTPRequestHandler
from pathlib import Path
sys.path.insert(0, "tools/audio")
import lyria
from fetch import LocalServer   # (lyria's import of tools/assets/fetch.py; http.server's own bind stalled 35 s on GitHub's macOS runners)
t, fx, mode = Path(sys.argv[1]), Path("tools/audio/fixtures/lyria/responses"), {"m": "ok"}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if mode["m"] == "cut":
            return
        body, code = {"ok": ((fx / "answer.json").read_bytes(), 200), "clip": ((fx / "answer-clip.json").read_bytes(), 200),
                      "blocked": ((fx / "answer-blocked.json").read_bytes(), 200), "http400": (b'{"error": {"code": 400, "message": "bad"}}', 400)}[mode["m"]]
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
srv = LocalServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
lyria.API = f"http://127.0.0.1:{srv.server_address[1]}/v1beta/interactions"
os.environ["GEMINI_API_KEY"] = "test-not-a-key"
p = t / "paid"
p.mkdir()
(p / "BRIEF.md").write_text("# BRIEF\n\n## Spec\n- Budget: $1\n", encoding="utf-8")
codes, said = {}, {}
for m in ("ok", "clip", "blocked", "http400", "cut"):
    mode["m"] = m
    err = io.StringIO()
    with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
        codes[m] = lyria.main(["--provider", "lyria", str(p), "--prompt", "x", "--id", f"m-{m}", "--as", f"m{m}", "--no-beats"]
                              + (["--model", "lyria-3-clip-preview"] if m == "clip" else []))
    said[m] = err.getvalue()
srv.shutdown()
srv.server_close()
spend = [json.loads(x) for x in open(p / "assets/spend.jsonl", encoding="utf-8")]
settled = {x["asset"]: x["amount"] for x in spend if x["kind"] == "settle"}
bad = []
if codes != {"ok": 0, "clip": 0, "blocked": 1, "http400": 1, "cut": 1}:
    bad.append(f"exits {codes}")
if settled != {"m-ok": 0.08, "m-clip": 0.04, "m-blocked": 0.0, "m-http400": 0.0, "m-cut": 0.08}:
    bad.append(f"settled {settled}")
if "may have been billed" not in said["cut"]:
    bad.append(f"cut said: {said['cut'][-200:]}")
rec = {x["id"]: x for x in json.load(open(p / "assets/ledger.json", encoding="utf-8"))["assets"]}
if rec["m-ok"]["cost"] != {"amount": 0.08, "currency": "USD"} or rec["m-clip"]["cost"] != {"amount": 0.04, "currency": "USD"}:
    bad.append(f"the records' costs: {rec['m-ok'].get('cost')} {rec['m-clip'].get('cost')}")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
  ); then ok "music --provider lyria, a paid call (a stand-in API on this machine): settled at the model's price per track (\$0.08 whole, \$0.04 the clip); a blocked answer and an error answer at 0; an answer cut off keeps the price, said as maybe billed"
  else bad "music --provider lyria, settling a paid call: $a"; fi
  rm -rf "$t"
}

sound_tools_checks() {   # check's loudness (tools/loudcheck.py), qa --listen and --picture (tools/audio/listen.py), and
  # beats --check's judgement (offbeat and verdict in tools/audio/beats.py, numpy only: the kicks themselves need librosa)
  local t p a b c rc rc2 rc3
  if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null; then skip "check's loudness, qa --listen, beats --check" "no ffmpeg"; return; fi
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  # lavfi's sine is at 1/8 of full scale (−21.07 LUFS at 1 kHz): +7.07 dB is −14 LUFS, −11 dB about −32
  ffmpeg -v error -y -f lavfi -i color=c=gray:s=160x90:r=30 -f lavfi -i "sine=f=1000:r=48000,volume=7.07dB" -t 4 -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 192k -shortest "$t/ok.mp4"
  ffmpeg -v error -y -f lavfi -i color=c=gray:s=160x90:r=30 -f lavfi -i "sine=f=1000:r=48000,volume=-11dB" -t 4 -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 192k -shortest "$t/quiet.mp4"
  ffmpeg -v error -y -f lavfi -i color=c=gray:s=160x90:r=30 -t 4 -c:v libx264 -pix_fmt yuv420p "$t/silent.mp4"
  a=$(python3 tools/loudcheck.py "$t/ok.mp4" --json "$t/ok.json"); rc=$?
  b=$(python3 tools/loudcheck.py "$t/quiet.mp4" --json "$t/quiet.json"); rc2=$?
  c=$(python3 tools/loudcheck.py "$t/silent.mp4" --json "$t/silent.json"); rc3=$?
  if [ "$rc:$rc2:$rc3" = "0:0:0" ] && case "$a|$b|$c" in "loudness: -14.0 LUFS integrated"*"|WARN loudness: -32."*"quieter than asked"*"|loudness: no sound"*) true ;; *) false ;; esac \
     && python3 - "$t" <<'PY'
import json, sys
sys.path.insert(0, "tools")
import checkrec
t = sys.argv[1]
ok, quiet, silent = (json.load(open(f"{t}/{n}.json")) for n in ("ok", "quiet", "silent"))
f = checkrec.loud_findings(quiet)
good = (ok["ok"] and abs(ok["integrated"] + 14) < 0.3 and not quiet["ok"] and len(f) == 1 and f[0]["kind"] == "check.loudness" and f[0]["severity"] == "warn"
        and checkrec.loud_findings(silent) == [] and checkrec.loud_findings(ok)[0]["severity"] == "info")
sys.exit(0 if good else 1)
PY
  then ok "check's loudness: a film's sound measured as uploaded (ebur128): on the mix's −14 LUFS it is info, a quiet one a warning saying what to do, a silent film nothing; a finding of its own in the check record"
  else bad "check's loudness (exits $rc:$rc2:$rc3): $a | $b | $c"; fi
  # the target is what the film was mixed to: bin/vh mix keeps lufs= and tp= in its record (<out>.mix.json); a film mixed
  # to −16 is on target, read from that record; an older record's arguments say it too; else the BRIEF's Loudness line
  ffmpeg -v error -y -f lavfi -i color=c=gray:s=160x90:r=30 -f lavfi -i "sine=f=1000:r=48000,volume=5.07dB" -t 4 -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 192k -shortest "$t/m16.mp4"
  ffmpeg -v error -y -f lavfi -i "sine=f=440:r=48000:d=3" "$t/voice.wav"
  for d in rec old brief; do mkdir -p "$t/$d/audio"; printf '# BRIEF\n\n## Spec\n- Language: en\n' > "$t/$d/BRIEF.md"; done
  printf -- '- Loudness: -16 LUFS\n' >> "$t/brief/BRIEF.md"
  printf '{"version": 1, "status": "complete", "args": ["voice=v.wav", "lufs=-16"]}\n' > "$t/old/audio/mix.wav.mix.json"
  vh mix "$t/rec/audio/mix.wav" voice="$t/voice.wav" lufs=-16 >/dev/null 2>&1; rc=$?
  a=$(python3 tools/loudcheck.py "$t/m16.mp4" --project "$t/rec"); rc2=$?
  b=$(python3 tools/loudcheck.py "$t/m16.mp4" --project "$t/old"); rc3=$?
  c=$(python3 tools/loudcheck.py "$t/m16.mp4" --project "$t/brief"); rc4=$?
  d=$(python3 tools/loudcheck.py "$t/m16.mp4"); rc5=$?
  if [ "$rc:$rc2:$rc3:$rc4:$rc5" = "0:0:0:0:0" ] && python3 -c 'import json,sys; t=json.load(open(sys.argv[1])).get("target"); sys.exit(0 if t == {"lufs": -16.0, "tp": -1.5} else 1)' "$t/rec/audio/mix.wav.mix.json" \
     && case "$a|$b|$c|$d" in "loudness: -16."*"target -16 ±1"*"audio/mix.wav.mix.json)|loudness: -16."*"target -16 ±1"*"audio/mix.wav.mix.json)|loudness: -16."*"target -16 ±1"*"BRIEF.md)|WARN loudness: -16."*"target -14 ±1"*) true ;; *) false ;; esac
  then ok "check's loudness: the target is what the film was mixed to: bin/vh mix keeps lufs= and tp= in its record, read back (an older record by its arguments), else the BRIEF's Loudness line, else −14"
  else bad "check's loudness target (exits $rc:$rc2:$rc3:$rc4:$rc5): $a | $b | $c | $d"; fi
  p="$t/p"; mkdir -p "$p/audio/stems" "$p/out/review"; printf '# BRIEF\n\n## Spec\n- Language: en\n' > "$p/BRIEF.md"
  printf '{"gate": "3", "summary": "draft", "decisions": [], "assets": [{"path": "audio/mix.wav", "caption": "the mix"}]}' > "$p/out/review/gate-3.json"
  if uv run -q --no-project --with numpy python - "$p" <<'PY'
import json, sys, wave
import numpy as np
P = sys.argv[1]; SR = 48000; n = SR * 20; t = np.arange(n) / SR
voice = np.zeros(n); lines = [(1, 4, 0.30), (5, 8, 0.05), (9, 12, 0.25), (13, 17, 0.20)]   # line 2 is the weak one
for a, b, g in lines:
    m = (t >= a) & (t < b); voice[m] = g * np.sin(2 * np.pi * 220 * t[m])
music = 0.05 * np.sin(2 * np.pi * 110 * t); music[t >= 10] *= 4                        # the music turns up at 10 s
sfx = np.zeros(n); i = int(14.5 * SR); sfx[i:i + 2400] = 0.9 * np.exp(-np.arange(2400) / 300)   # the one hit, at 14.5 s
def w(f, x):
    with wave.open(f, "wb") as o:
        o.setnchannels(1); o.setsampwidth(2); o.setframerate(SR); o.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())
for name, x in (("stems/voice", voice), ("stems/music", music), ("stems/sfx", sfx), ("mix", voice + music + sfx)):
    w(f"{P}/audio/{name}.wav", x)
json.dump({"lines": [{"id": f"l{k + 1}", "start": a, "end": b, "text": f"line {k + 1}"} for k, (a, b, g) in enumerate(lines)]}, open(f"{P}/audio/timeline.en.json", "w"))
json.dump({"bpm": 120, "beats": [], "sections": [{"name": "a", "start": 0.0, "end": 10.0}, {"name": "b", "start": 10.0, "end": 20.0}]}, open(f"{P}/audio/music.beats.json", "w"))
json.dump([{"t": 14.5, "sfx": "impact"}], open(f"{P}/audio/events.json", "w"))
PY
  then
    a=$(vh qa "$p/audio/mix.wav" "$p/audio/music.beats.json" "$p/audio/events.json" --listen 5 --stems "$p/audio/stems" --gate 3 --picture "$p/out/sound.png" --json 2>/dev/null); rc=$?
    if [ $rc = 0 ] && [ -s "$p/out/sound.png" ] && python3 - "$p" "$a" <<'PY'
import json, sys
p, j = sys.argv[1], json.loads(sys.argv[2])
pts = {x["why"]: x for x in j["points"]}
g = json.load(open(f"{p}/out/review/gate-3.json"))
ok = (len(j["points"]) == 5 and pts["weakest-line"]["detail"]["line"] == "l2" and abs(pts["loudest-hit"]["t"] - 14.7) < 0.3 and "aac-risk" in pts["loudest-hit"]["note"]
      and abs(pts["biggest-turn"]["t"] - 10.0) < 0.01 and abs(pts["ending"]["t"] - 17.0) < 0.01
      and [x["t"] for x in g["listen"]] == [x["t"] for x in j["points"]] and g["assets"][0]["path"] == "audio/mix.wav"
      and [a["path"] for a in g["assets"][1:]] == [x["file"] for x in j["points"]] and all(x["file"].startswith("out/listen/") for x in j["points"]))
sys.exit(0 if ok else 1)
PY
    then ok "qa --listen: the weakest line (by the stems), the loudest hit (the AAC risk folded into it), the biggest turn, the ending and one more weak line, 6 s each; into the gate's listen and assets; --picture draws the sound"
    else bad "qa --listen (exit $rc): $(printf '%s' "$a" | tail -c 600)"; fi
  else skip "qa --listen" "uv cannot run numpy here"; fi
  if a=$(uv run -q --no-project --with numpy --with scipy python - 2>&1 <<'PY'
import sys
sys.path.insert(0, "tools/audio")
import beats as B
grid = [0.5 * k for k in range(33)]
on, off = [0.5 * k + 0.004 for k in range(32)], [0.5 * k + 0.25 for k in range(32)]
bad = []
for kicks, want_off, words in ((on, False, "on the beat"), (off, True, "locked to the off-beat"), ([0.5 * k + 0.1 for k in range(32)], True, "+0.20 of a beat"),
                               (on[:5], False, "too few"), ([0.5 * k + (0.25 if k % 2 else 0.0) for k in range(32)], False, "too few or too scattered")):
    got = B.verdict(*B.offbeat(kicks, grid), 120)
    if got[0] != want_off or words not in got[1]:
        bad.append(f"{words}: {got}")
if "0.250 s" not in B.verdict(*B.offbeat(off, grid), 120)[1]:
    bad.append("the shift for half a beat at 120 BPM")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
  ); then ok "beats --check: kicks on the grid are on the beat; half a beat off is the off-beat with the shift to make; another steady offset says how much; too few kicks, or ones that agree on nothing, say nothing"
  else bad "beats --check's judgement: $a"; fi
  rm -rf "$t"
}

assets_checks() {   # the asset ledger (tools/assets): the record and its fixtures, the licence table, the ledger's writes on a
  # copy of the fixture project, the budget, a download from recorded responses (no network), the credits, and end to end
  # with a render (bin/vh render's .render.json against the ledger, status, the review page, deliver, patch)
  local t p q e x a b c d rc rc2 rc3 rc4 rc5 r1 r2 r3 r4 r5 tone
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  # the validator takes every valid record and the fixture ledger, and refuses every invalid one; JSON Schema agrees
  if a=$(python3 - <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, "tools/assets")
import ledger
F = Path("tools/assets/fixtures/records")
load = lambda p: json.loads(p.read_text(encoding="utf-8"))   # noqa: E731
bad = [f"{p.name}: {ledger.validate(load(p))}" for p in sorted((F / "valid").glob("*.json")) if ledger.validate(load(p))]
bad += [f"invalid/{p.name} passes" for p in sorted((F / "invalid").glob("*.json")) if not ledger.validate(load(p))]
d = load(Path("tools/assets/fixtures/project/assets/ledger.json"))
bad += [f"the fixture ledger's {r.get('id')}: {ledger.validate(r)}" for r in d["assets"] if ledger.validate(r)]
bad += [] if len(list((F / "invalid").glob("*.json"))) >= 15 else ["fewer than 15 invalid records"]
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
  ); then ok "assets: the record's validator takes the valid fixtures and the fixture ledger, and refuses each invalid one"
  else bad "assets: the record validator on tools/assets/fixtures: $a"; fi
  if command -v uv >/dev/null 2>&1; then
    if a=$(uv run -q --no-project --with "jsonschema==4.25.1" python - 2>&1 <<'PY'
import json, sys
from pathlib import Path
from jsonschema import Draft202012Validator
S = json.loads(Path("tools/assets/asset.schema.json").read_text(encoding="utf-8"))
Draft202012Validator.check_schema(S)
v, F = Draft202012Validator(S), Path("tools/assets/fixtures/records")
load = lambda p: json.loads(p.read_text(encoding="utf-8"))   # noqa: E731
bad = [f"{p.name}: {[e.message for e in v.iter_errors(load(p))]}" for p in sorted((F / "valid").glob("*.json")) if not v.is_valid(load(p))]
bad += [f"invalid/{p.name} is valid to JSON Schema" for p in sorted((F / "invalid").glob("*.json")) if v.is_valid(load(p))]
L = v.evolve(schema=S["$defs"]["ledger"])
d = load(Path("tools/assets/fixtures/project/assets/ledger.json"))
bad += [f"the fixture ledger: {e.message}" for e in L.iter_errors(d)]
bad += [] if not L.is_valid(dict(d, assets=d["assets"] + [{"v": 1}])) else ["a ledger with a bad record is valid"]
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
    ); then ok "assets: asset.schema.json is a valid JSON Schema and agrees with the validator on every fixture"
    else bad "assets: JSON Schema on the fixtures: $(printf '%s' "$a" | tail -c 600)"; fi
  else skip "assets: the JSON Schema check" "no uv"; fi
  if a=$(python3 - <<'PY'
import sys
sys.path.insert(0, "tools/assets")
import licenses
bad, n = [], 0
for k, line in enumerate(open("tools/assets/fixtures/licenses.tsv", encoding="utf-8"), 1):
    if line.startswith("#") or not line.strip("\n"):
        continue
    text, url, want = line.rstrip("\n").split("\t")
    got, n = licenses.classify(text, url or None)[0], n + 1
    if got != want:
        bad.append(f"line {k}: {text!r} {url!r} is {got}, not {want}")
ok = [licenses.risks(c) for c in ("cc-by-nc-nd", "cc-by-sa", "unknown", "cc0")] == [["nc", "nd"], ["sa"], ["unknown"], []] \
    and [licenses.accepted(c, "strict") for c in ("cc-by", "cc-by-sa", "generated", "unknown")] == [True, False, True, False] \
    and licenses.accepted("cc-by-nc", "record")
print("\n".join(bad + ([] if ok else ["risks or accepted"])) or n); sys.exit(1 if bad or not ok or n < 40 else 0)
PY
  ); then ok "assets: the licence table classifies its $a lines (CC by name, legal name, code and deed; PD, permissive, agreements, own, generated; anything else unknown)"
  else bad "assets: the licence table: $a"; fi
  # the ledger's writes on a copy of the fixture project; its generated clip from before v1 gets its bytes here (no video in git)
  p="$t/p"; cp -R tools/assets/fixtures/project "$p"; printf 'fixture clip\n' > "$p/assets/genclips/gc-0001/clip.mp4"
  a=$(vh assets check "$p" 2>&1); rc=$?
  b=$(vh assets check "$p" --policy strict 2>&1); rc2=$?
  case "$rc:$rc2|$a|$b" in "0:1|"*"6 record(s) in assets/ledger.json and 1 from generated clips' ledgers"*"! loop"*"non-commercial (taken: Assets: record)"*"pass (0 fail, 1 warn)"*"|"*"✗ loop"*"fail (1 fail"*)
      ok "assets check: a project's records and a generated clip's ledger from before v1, read as it is; NC listed under Assets: record, failed under strict" ;;
    *) bad "assets check on the fixture (exit $rc, $rc2): $a | $b" ;; esac
  printf 'x' > "$p/assets/img/new.png"
  vh assets add "$p" "$p/assets/img/new.png" >/dev/null 2>"$t/e1"; r1=$?
  vh assets add "$p" "$p/assets/img/new.png" --license "CC BY-SA 4.0" --source-url https://example.org/new --author Someone --cost '$0.25' >"$t/o2" 2>&1; r2=$?
  vh assets add "$p" "$p/assets/img/new.png" --license own >/dev/null 2>"$t/e3"; r3=$?
  vh assets add "$p" "$p/assets/img/new.png" --update --class own >"$t/o4" 2>&1; r4=$?
  vh assets remove "$p" loop --why "a CC0 loop instead" >/dev/null 2>&1; r5=$?
  vh assets remove "$p" gc-0001 >/dev/null 2>&1; r6=$?
  printf 'y' > "$p/assets/img/again.png"; vh assets add "$p" "$p/assets/img/again.png" --class own --id loop >/dev/null 2>"$t/e7"; r7=$?
  printf 'more' >> "$p/assets/sfx/knock.wav"; rm "$p/assets/frames/f0002.png"
  a=$(vh assets check "$p" --json 2>/dev/null); rc=$?
  if [ "$r1:$r2:$r3:$r4:$r5:$r6:$r7:$rc" = "2:0:2:0:0:0:2:1" ] && grep -q "where it came from is not said" "$t/e1" && grep -q "on record already as new" "$t/e3" \
     && grep -q "the id loop is taken" "$t/e7" && grep -q 'spent $0.79 of $1.00' "$t/o2" && grep -q "updated new" "$t/o4" \
     && python3 - "$p" "$a" <<'PY'
import json, sys
p, check = sys.argv[1], json.loads(sys.argv[2])
d = json.load(open(f"{p}/assets/ledger.json", encoding="utf-8"))
R = {r["id"]: r for r in d["assets"]}
ev = [f"{e['event']}:{e['id']}" for e in d["events"]][5:]
new = R["new"]
pay = [json.loads(x) for x in open(f"{p}/assets/spend.jsonl", encoding="utf-8")]
fs = {(f["kind"], f["id"]) for f in check["findings"] if f["severity"] == "fail"}
ok = (ev == ["add:new", "update:new", "remove:loop", "remove:gc-0001"]
      and new["license"] == {"name": "CC BY-SA 4.0", "class": "own", "by": "given"} and new["source"]["author"] == "Someone"
      and new["cost"] == {"amount": 0.25, "currency": "USD"} and "updated_at" in new
      and R["loop"]["removed"]["why"] == "a CC0 loop instead" and R["gc-0001"].get("legacy") == "genclip-ledger" and "removed" in R["gc-0001"]
      and [x["amount"] for x in pay] == [0.04, 0.25] and pay[1]["asset"] == "new"
      and fs == {("sha256", "knock"), ("sha256", "frames")} and check["verdict"] == "fail" and check["records"] == 5)
if not ok:
    print(f"{ev} {new} {pay} {fs} {check['records']}")
sys.exit(0 if ok else 1)
PY
  then ok "assets add and remove: where it came from is required, a path or an id on record is refused (ids never reused), --update keeps the rest, a cost goes into spend.jsonl, a removed record stays (a clip's from before v1 moved in); check fails a changed file and a changed folder"
  else bad "assets add/remove (exits $r1:$r2:$r3:$r4:$r5:$r6:$r7:$rc): $(cat "$t/e1" "$t/e3" "$t/e7" "$t/o2" "$t/o4" | tail -c 600)"; fi
  # the ledger's edges: a class that is no string and an entry that is no object are findings, not tracebacks; a file
  # made from another keeps its licence; a path is found from here or in the project; a URL keeps no secret; a cost that
  # cannot be written is exit 1
  q="$t/q"; cp -R tools/assets/fixtures/project "$q"; printf 'fixture clip\n' > "$q/assets/genclips/gc-0001/clip.mp4"
  cp "$q/assets/music/loop.wav" "$q/assets/music/loop-cut.wav"
  python3 - "$q" <<'PY'
import json, sys
q = sys.argv[1]
f = f"{q}/assets/ledger.json"
d = json.load(open(f, encoding="utf-8"))
d["assets"][0]["license"]["class"] = 5                                  # grey-square: a class that is not a string
d["assets"].append("not a record")
d["assets"].append(dict(d["assets"][4], id="loop-cut", path="assets/music/loop-cut.wav", license={"class": "own", "by": "given"}, derived_from="loop"))
d["assets"][2]["derived_from"] = "nothing-by-this-id"                    # hero: made from a record that is not there
json.dump(d, open(f, "w", encoding="utf-8"), ensure_ascii=False)
PY
  a=$(vh assets check "$q" 2>&1); rc=$?
  b=$(vh assets list "$q" 2>&1; vh assets credits "$q" 2>&1); rc2=$?
  printf 'x' > "$q/assets/img/far.png"
  c=$(cd "$t" && "$VH_BASH" "$ROOT/bin/vh" assets add "$q" assets/img/far.png --class own --source-url 'https://u:p@example.org/page?sig=secret#x' 2>&1); rc3=$?
  d=$(vh assets add "$q" 'https://example.org/files/tone.wav?token=secret' --license CC0 --offline tools/assets/fixtures/responses 2>&1); rc4=$?
  rm -f "$q/assets/spend.jsonl"; mkdir "$q/assets/spend.jsonl"; printf 'y' > "$q/assets/img/paid.png"
  e=$(vh assets add "$q" "$q/assets/img/paid.png" --class managed --origin purchased --cost '$2' 2>&1); rc5=$?
  if [ "$rc:$rc2:$rc3:$rc4:$rc5" = "1:0:0:1:1" ] && ! printf '%s' "$a$b$c$d$e" | grep -q 'Traceback\|secret\|u:p@' \
     && case "$a" in *"grey-square"*"license.class is not one of"*) true ;; *) false ;; esac \
     && case "$a" in *"assets[5] is not a record"*) true ;; *) false ;; esac \
     && case "$a" in *"hero"*"derived_from names nothing-by-this-id"*) true ;; *) false ;; esac \
     && case "$a" in *"loop-cut"*"made from loop (cc-by-nc) but on record as own"*) true ;; *) false ;; esac \
     && grep -q '"url": "https://example.org/page?sig=…#…"' "$q/assets/ledger.json" \
     && case "$e" in *"paid is on record, but its cost could not go into assets/spend.jsonl"*) true ;; *) false ;; esac
  then ok "assets: a class that is no string and an entry that is no object are findings (no traceback); a file made from another keeps its licence; a path is found in the project too; URLs keep no secret; a cost that cannot be written is exit 1"
  else bad "assets edges (exits $rc:$rc2:$rc3:$rc4:$rc5): $(printf '%s | %s | %s | %s | %s' "$a" "$b" "$c" "$d" "$e" | tail -c 900)"; fi
  if a=$(python3 - <<'PY'
import os, sys, tempfile
sys.path.insert(0, "tools/assets")
import fetch
d = tempfile.mkdtemp()
try:
    fetch.Record(d).open("https://example.org/f.wav?X-Amz-Signature=abc")
    print("a signed URL was recorded")
except fetch.FetchError as e:
    print("" if "not recorded" in str(e) and "abc" not in str(e) and not os.listdir(d) else f"Record: {e} {os.listdir(d)}")
except OSError as e:
    print(f"Record went to the network: {e}")
PY
  ) && [ -z "$a" ]; then ok "assets: Record refuses a URL that carries a credential, before it opens anything"
  else bad "assets Record: $a"; fi
  # the budget: the BRIEF's line, else LOCAL.md's 默认预算 (one line each: an empty Budget is not the line below it);
  # amounts with their currency, one a currency, never guessed; spent per currency (spend.jsonl, a clip's cost_usd from
  # before v1); a hold over it, in a currency it lacks, or with no budget is refused, and two at once cannot both pass
  cp -R tools/assets/fixtures/project "$t/b"
  if a=$(OVH_LOCAL_MD="$t/LOCAL.md" python3 - "$t/b" "$t/LOCAL.md" <<'PY'
import subprocess, sys, textwrap, time
sys.path.insert(0, "tools/assets")
import budget, ledger
b, local = sys.argv[1:]
P = budget.parse
bad = []
cases = {"$5": {"USD": 5.0}, "每支片子 20 美元": {"USD": 20.0}, "$5, ¥30": {"USD": 5.0, "CNY": 30.0}, "30 元": {"CNY": 30.0}, "0": {}, "none": {}, "无": {},
         "500 tripo-credits": {"TRIPO-CREDITS": 500.0}, "5 USD (drafts)": {"USD": 5.0}, "€2.5": {"EUR": 2.5}, "$1,000": {"USD": 1000.0}, "$1,000.50, ¥30": {"USD": 1000.5, "CNY": 30.0}}
for v, want in cases.items():
    got = P(v)
    if not got or got["error"] or got["amounts"] != want:
        bad.append(f"parse {v!r}: {got}")
for v in ("default", "{例如每支片子 20 美元}", ""):
    if P(v) is not None:
        bad.append(f"parse {v!r} should say nothing")
for v in ("5", "20 for drafts", "$5 per film, $20 total"):
    if not (P(v) or {}).get("error"):
        bad.append(f"parse {v!r} should be an error")
if not (P("不限") or {}).get("unlimited") or not (P("unlimited") or {}).get("unlimited"):
    bad.append("不限 / unlimited is no cap")
s = budget.spent(b)
if s != {"USD": 0.54}:
    bad.append(f"spent {s}")
for amount, cur, want in ((0.5, "USD", "$0.04 short"), (3, "CNY", "has no CNY")):
    try:
        with budget.hold(b, amount, cur, "image gen"):
            bad.append(f"{amount} {cur} was held")
    except budget.Refused as e:
        if want not in str(e) or not str(e).startswith("image gen: paid call refused"):
            bad.append(f"refusal: {e}")
if budget.check(b, 0.5, "USD")["short"] != 0.04 or not budget.check(b, 0.46, "USD")["ok"]:
    bad.append("check: $0.04 short for 0.50, 0.46 fits")
with budget.hold(b, 0.2, "USD", "a call", asset="img1") as h:   # settled below its estimate, then registered at that cost
    if budget.tally(b)[1] != {"USD": 0.2}:
        bad.append(f"held while in flight: {budget.tally(b)}")
    h.settle(0.1)
try:
    with budget.hold(b, 0.1, "USD", "a call that fails"):
        raise RuntimeError("the vendor is down")
except RuntimeError:
    pass
with budget.hold(b, 0.05, "USD", "a call not billed") as h:
    h.settle(0)
if budget.spent(b) != {"USD": 0.74} or budget.tally(b)[1]:   # 0.54 + 0.1 + 0.1 (an exception: its estimate) + 0
    bad.append(f"after the holds: {budget.tally(b)}")
open(f"{b}/assets/img/img1.png", "wb").write(b"x")
_, _, pay = ledger.add(b, f"{b}/assets/img/img1.png", id="img1", license_class="own", cost={"amount": 0.1, "currency": "USD"})
_, _, pay2 = ledger.add(b, f"{b}/assets/img/img1.png", update=True, cost={"amount": 0.15, "currency": "USD"})
if pay is not None or not pay2 or pay2["amount"] != 0.05 or budget.spent(b) != {"USD": 0.79}:
    bad.append(f"ledger.add's cost: what the log lacks for the id ({pay}, {pay2}, {budget.spent(b)})")
# two processes hold at once: $1 left, each wants 0.6: one is refused
open(f"{b}/BRIEF.md", "w").write("# BRIEF\n\n## Spec\n- Budget: $1.79\n")
racer = textwrap.dedent("""
    import sys, time; sys.path.insert(0, "tools/assets"); import budget
    time.sleep(max(0, float(sys.argv[2]) - time.time()))
    try:
        with budget.hold(sys.argv[1], 0.6, "USD", "racing") as h:
            time.sleep(0.4); h.settle(0.6)
        print("held")
    except budget.Refused:
        print("refused")""")
go = time.time() + 0.5
ps = [subprocess.Popen([sys.executable, "-c", racer, b, str(go)], stdout=subprocess.PIPE, text=True) for _ in range(2)]
got = sorted(p.communicate()[0].strip() for p in ps)
if got != ["held", "refused"] or budget.spent(b) != {"USD": 1.39}:
    bad.append(f"two holds at once: {got}, spent {budget.spent(b)}")
# one line each: an empty Budget or Assets line does not read the next one
open(f"{b}/BRIEF.md", "w").write("# BRIEF\n\n## Spec\n- Budget:\n- Output: 1080p, $5 test\n- Assets:\n- Pace: record\n")
if budget.budget_of(b)["from"] is not None or ledger.policy_of(b) != ("strict", "the default"):
    bad.append(f"an empty line read the next one: {budget.budget_of(b)} {ledger.policy_of(b)}")
open(f"{b}/BRIEF.md", "w").write("# BRIEF\n\n## Spec\n- Budget: default\n")
try:
    with budget.hold(b, 0.1, "USD", "x"):
        bad.append("no budget allowed a call")
except budget.Refused as e:
    if "no budget" not in str(e) or "Budget: $0.10" not in str(e):
        bad.append(f"no-budget refusal: {e}")
open(local, "w").write("- 默认预算：每支片子 20 美元\n")
if not budget.check(b, 0.1, "USD")["ok"] or budget.budget_of(b)["from"] != "LOCAL.md":
    bad.append("LOCAL.md's 默认预算 not read")
budget.spend(b, 18.65, "USD", "a test")
sm = budget.summary(b)
if sm["limit"] != {"USD": 20.0} or sm["left"] != {"USD": -0.04} or sm["over"] != ["USD"] or "over: USD" not in budget.line(b):
    bad.append(f"summary {sm} / {budget.line(b)}")
open(local, "w").write("- 默认预算：不限\n")
if not budget.check(b, 1000, "USD")["ok"] or not budget.summary(b)["unlimited"]:
    bad.append("不限: no cap")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
  ); then ok "assets budget: the BRIEF's Budget, else LOCAL.md's 默认预算, one line each; amounts need a currency, one a currency, \$1,000 is a thousand, 不限 no cap; a hold over it says how much is short, two at once cannot both pass, an exception counts its estimate; ledger.add records only what the log lacks"
  else bad "assets budget: $a"; fi
  # a download from recorded responses (fetch.Replay, no network): whole, resumed from a .part, a server that ignores
  # ranges, a 404, a sha256 that does not match, a rate cap; and add <url> --offline registers what it got
  tone=5fce37f3129150ce7ec3939b54016d9c1fd01364e27b0a788dc634064aec76b1
  if a=$(python3 - "$t/dl" "$tone" <<'PY'
import os, sys, time
sys.path.insert(0, "tools/assets")
import fetch
d, tone = sys.argv[1:]
R, bad = fetch.Replay("tools/assets/fixtures/responses"), []
body = open("tools/assets/fixtures/responses/tone.bin", "rb").read()
r = fetch.download("https://example.org/files/tone.wav", f"{d}/a.wav", sha256=tone, opener=R)
if r["sha256"] != tone or r["resumed"] or open(f"{d}/a.wav", "rb").read() != body or os.path.exists(f"{d}/a.wav.part"):
    bad.append(f"whole: {r}")
open(f"{d}/b.wav.part", "wb").write(body[:1000])
r = fetch.download("https://example.org/files/tone.wav", f"{d}/b.wav", sha256=tone, opener=R)
if not r["resumed"] or r["status"] != 206 or r["sha256"] != tone:
    bad.append(f"resumed: {r}")
open(f"{d}/c.wav.part", "wb").write(b"junk" * 10)
r = fetch.download("https://example.org/files/noranges.wav", f"{d}/c.wav", sha256=tone, opener=R)
if r["resumed"] or r["status"] != 200 or r["sha256"] != tone:
    bad.append(f"no ranges: {r}")
open(f"{d}/e.wav.part", "wb").write(body)
r = fetch.download("https://example.org/files/tone.wav", f"{d}/e.wav", sha256=tone, opener=R)
if r["sha256"] != tone:
    bad.append(f"a complete .part (416): {r}")
for url, want in (("https://example.org/files/missing.wav", "HTTP 404"), ("https://example.org/files/nothing", "no recorded response")):
    try:
        fetch.download(url, f"{d}/x.wav", opener=R); bad.append(f"{url} downloaded")
    except fetch.FetchError as e:
        if want not in str(e):
            bad.append(f"{url}: {e}")
try:
    fetch.download("https://example.org/files/tone.wav", f"{d}/f.wav", sha256="0" * 64, opener=R); bad.append("a wrong sha256 passed")
except fetch.FetchError:
    if os.path.exists(f"{d}/f.wav") or os.path.exists(f"{d}/f.wav.part"):
        bad.append("a wrong sha256 left a file")
t0 = time.monotonic(); fetch.download("https://example.org/files/tone.wav", f"{d}/g.wav", rate="128K", opener=R)
if time.monotonic() - t0 < 0.4:
    bad.append(f"128K/s for 64 kB took {time.monotonic() - t0:.2f} s")
j = fetch.get_json("https://example.org/api/search?q=knock&license=cc0,by", opener=R)
if j["results"][0]["license"] != "by":
    bad.append(f"get_json: {j}")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
  ); then ok "assets download from recorded responses: whole, resumed with Range, over a server that ignores ranges, a complete .part; 404, unrecorded and sha256 mismatch fail with nothing left; a rate cap; get_json"
  else bad "assets download (tools/assets/fetch.py): $a"; fi
  # stand-in servers, no network: get_json tries again after no answer, a 503 or a 429 (1, 2, 4 s apart, counted here, not
  # slept), never after a 404; a download resumed against a file that changed on the server since its .part began (the
  # length a 206 gives is not the one kept beside the part) starts over and says why, in the same run or the next
  if a=$(python3 - "$t/dl2" <<'PY' 2>&1
import io, json, os, re, sys, time
sys.path.insert(0, "tools/assets")
import fetch
d, bad, waits = sys.argv[1], [], []
os.makedirs(d, exist_ok=True)
time.sleep = waits.append   # fetch's waits between tries, counted
def answer(status, body, h=None):
    return fetch.Response(status, {"Content-Length": str(len(body)), **(h or {})}, io.BytesIO(body).read)
class Flaky:   # fails first as told (no answer, or an HTTP status), then answers
    def __init__(self, *fails): self.fails, self.n = list(fails), 0
    def open(self, url, headers=None, timeout=60):
        self.n += 1
        if self.fails:
            f = self.fails.pop(0)
            if f == "drop": raise ConnectionError(f"{url}: connection reset")
            e = fetch.FetchError(f"{url}: HTTP {f}"); e.status = f; raise e
        return answer(200, b'{"ok": true}')
for fails, want_waits in ((["drop"], [1]), ([503, 429], [1, 2])):
    waits.clear(); o = Flaky(*fails)
    if fetch.get_json("https://example.org/api", opener=o) != {"ok": True} or waits != want_waits or o.n != len(fails) + 1:
        bad.append(f"get_json after {fails}: waits {waits}, {o.n} asks")
waits.clear(); o = Flaky(404)
try:
    fetch.get_json("https://example.org/api", opener=o); bad.append("a 404 answered")
except fetch.FetchError as e:
    if waits or o.n != 1 or e.status != 404: bad.append(f"a 404 tried again: {waits} {o.n}")
waits.clear(); o = Flaky("drop", "drop", "drop", "drop")
try:
    fetch.get_json("https://example.org/api", opener=o); bad.append("no answer, and yet JSON")
except ConnectionError as e:
    if waits != [1, 2, 4] or "after 4 tries" not in str(e): bad.append(f"four drops: {waits} {e}")
class Site:   # serves bodies[k] at the k-th request (the last from then on), ranges honoured; cut: bytes the first answer stops after
    def __init__(self, bodies, cut=None): self.bodies, self.n, self.cut = bodies, 0, cut
    def open(self, url, headers=None, timeout=60):
        body = self.bodies[min(self.n, len(self.bodies) - 1)]; self.n += 1
        m = re.match(r"bytes=(\d+)-$", (headers or {}).get("Range", ""))
        if m:
            a = int(m.group(1))
            return answer(206, body[a:], {"Content-Range": f"bytes {a}-{len(body) - 1}/{len(body)}"})
        r = answer(200, body)
        if self.cut and self.n == 1:   # the connection drops after cut bytes
            src = io.BytesIO(body[:self.cut])
            def read(k=-1):
                b = src.read(k)
                if not b: raise ConnectionResetError("reset")
                return b
            r.read = read
        return r
old, new = bytes(range(256)) * 12, bytes(reversed(range(256))) * 10   # 3072 bytes, then 2560
r = fetch.download("https://example.org/f.bin", f"{d}/a.bin", opener=Site([old, new], cut=1000))
if open(f"{d}/a.bin", "rb").read() != new or not r["restarted"] or os.path.exists(f"{d}/.a.bin.part.json"):
    bad.append(f"changed while it came: {r}")
open(f"{d}/b.bin.part", "wb").write(old[:1000]); open(f"{d}/.b.bin.part.json", "w").write(json.dumps({"total": len(old)}))
r = fetch.download("https://example.org/f.bin", f"{d}/b.bin", opener=Site([new]))
if open(f"{d}/b.bin", "rb").read() != new or not r["restarted"] or r["resumed"]:
    bad.append(f"changed since the part: {r}")
open(f"{d}/c.bin.part", "wb").write(old[:1000]); open(f"{d}/.c.bin.part.json", "w").write(json.dumps({"total": len(old)}))
r = fetch.download("https://example.org/f.bin", f"{d}/c.bin", opener=Site([old]))
if open(f"{d}/c.bin", "rb").read() != old or r["restarted"] or not r["resumed"] or os.path.exists(f"{d}/.c.bin.part.json"):
    bad.append(f"the same file resumed: {r}")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
  ); then ok "fetch: get_json tries again after no answer, a 503 or a 429 (1, 2, 4 s), not after a 404; a resumed download whose file changed on the server starts over and says so, in one run or the next; the same file still resumes"
  else bad "fetch's tries and resumes: $a"; fi
  a=$(vh assets add "$p" https://example.org/files/tone.wav --license "CC0" --title Tone --offline tools/assets/fixtures/responses --sha256 "$tone" --to assets/sfx/tone.wav 2>&1); rc=$?
  b=$(vh assets add "$p" https://example.org/files/missing.wav --license CC0 --offline tools/assets/fixtures/responses 2>&1); rc2=$?
  if [ "$rc:$rc2" = "0:1" ] && [ ! -e "$p/assets/missing.wav" ] && python3 - "$p" <<'PY'
import json, sys
r = {x["id"]: x for x in json.load(open(f"{sys.argv[1]}/assets/ledger.json", encoding="utf-8"))["assets"]}["tone"]
s = r["source"]
sys.exit(0 if r["path"] == "assets/sfx/tone.wav" and r["license"]["class"] == "cc0" and s["origin"] == "download"
         and s["file_url"] == "https://example.org/files/tone.wav" and s.get("retrieved") and r["kind"] == "audio" else 1)
PY
  then ok "assets add <url> --offline: downloaded from the recording, then registered (origin download, the URL, the day); a 404 is exit 1 with nothing left"
  else bad "assets add <url> (exit $rc, $rc2): $a | $b"; fi
  # credits: the BY lines with their author, source and deed; public domain as courtesy; the AI notice counts what is generated
  cp -R tools/assets/fixtures/project "$t/c"
  a=$(vh assets credits "$t/c" --lang zh 2>/dev/null); b=$(vh assets credits "$t/c" --json 2>/dev/null); rc=$?
  case "$a" in *"素材署名"*"《Knock》，Fixture Author，example-sounds（https://example.org/sounds/knock），CC BY 4.0（https://creativecommons.org/licenses/by/4.0/）"*"致谢"*"《A grey square》"*"AI 生成内容"*"图片 1 件、视频 1 件"*)
      if [ $rc = 0 ] && python3 -c 'import json,sys; c=json.loads(sys.argv[1]); sys.exit(0 if c["lang"]=="en" and c["aigc"]["count"]==2 and [x["id"] for x in c["required"]]==["knock","loop"] and [x["id"] for x in c["courtesy"]]==["grey-square"] and not c["missing"] else 1)' "$b"
      then ok "assets credits: the lines a licence asks for (title, author, source, licence and their pages), courtesy for public domain, the AI-content notice with what it covers; --json; the BRIEF's language"
      else bad "assets credits --json: $b"; fi ;;
    *) bad "assets credits: $a" ;; esac
  # the commands write their notes into the project's activity log, list and check do not log
  if grep -q '"cmd":"assets"' "$p/.ovh/activity.jsonl" 2>/dev/null && grep -q '"summary":"added new' "$p/.ovh/activity.jsonl" \
     && ! grep -q '"args":\["check"' "$p/.ovh/activity.jsonl"; then ok "assets add and remove are in the activity log with what they did; check and list are not logged"
  else bad "assets in the activity log: $(tail -c 400 "$p/.ovh/activity.jsonl" 2>&1)"; fi
  # end to end: the fixture's page loads two pictures on record and assets/img/stray.png, which is not. bin/vh render puts
  # every file the page was sent into the film's .render.json; assets check compares it with the ledger both ways (a mix
  # record counts as a use too); status, the review page and deliver read the ledger; a patch keeps the table
  e="$t/e"; cp -R tools/assets/fixtures/project "$e"; printf 'fixture clip\n' > "$e/assets/genclips/gc-0001/clip.mp4"
  a=$(vh render "$e" --out "$e/out/film.mp4" --workers 1 2>&1); rc=$?
  case "$rc:$a" in
    *"needs a headless Chrome"*) no_chrome "assets end to end (render, check both ways, status, review, deliver, patch)" ;;
    0:*)
      mkdir -p "$e/audio"; printf 'mix' > "$e/audio/mix.wav"; printf 'voice' > "$e/audio/voiceover.zh.wav"
      python3 - "$e" <<'PY'
import hashlib, json, sys
from pathlib import Path
e = Path(sys.argv[1]); sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()   # noqa: E731
ins = [{"path": "../assets/music/loop.wav", "sha256": sha(e / "assets/music/loop.wav")}, {"path": "voiceover.zh.wav", "sha256": sha(e / "audio/voiceover.zh.wav")},
       {"path": "../assets/sfx/door.wav", "sha256": None}]   # a lookup that found nothing, as bin/vh mix records one
(e / "audio/mix.wav.mix.json").write_text(json.dumps({"version": 1, "status": "complete", "inputs": ins}), encoding="utf-8")
PY
      a=$(vh assets check "$e" --json 2>/dev/null); rc=$?
      b=$(vh status "$e" --json 2>/dev/null)
      if [ $rc = 1 ] && python3 - "$e" "$a" "$b" <<'PY'
import json, sys
e, c, st = sys.argv[1], json.loads(sys.argv[2]), json.loads(sys.argv[3])
side = json.load(open(f"{e}/out/film.mp4.render.json", encoding="utf-8"))
f = {(x["kind"], x["severity"], x["id"] or x["path"]) for x in c["findings"]}
mix = [x for x in c["findings"] if x["kind"] == "mix"]
a = st["assets"]
ok = (sorted(side["files"]) == ["assets/genimg/hero/image.png", "assets/img/grey-square.png", "assets/img/stray.png", "index.html"]
      and all(len(h) == 64 for h in side["files"].values())
      and f == {("unregistered", "fail", "assets/img/stray.png"), ("unused", "warn", "frames"), ("unused", "warn", "gc-0001"), ("license", "warn", "loop"), ("mix", "info", None)}
      and mix and mix[0]["paths"] == ["audio/voiceover.zh.wav"] and c["uses"]["films"][0]["files"] == 4 and c["uses"]["mixes"] == ["audio/mix.wav"]
      and not any(k.startswith("/") for k in side["files"])
      and {k: a[k] for k in ("records", "uncleared", "unregistered", "aigc", "films_known", "policy")}
      == {"records": 6, "uncleared": 1, "unregistered": 1, "aigc": 2, "films_known": 1, "policy": "record"}
      and a["budget"]["spent"] == {"USD": 0.54} and a["budget"]["limit"] == {"USD": 1.0} and a["budget"]["left"] == {"USD": 0.46})
if not ok:
    print(sorted(side["files"]), f, mix, c["uses"], a)
sys.exit(0 if ok else 1)
PY
      then ok "assets end to end: render lists every file the page loaded (.render.json files); check finds the picture the ledger lacks (fail), the records nothing uses (warn) and, in one line, the mix's sound the ledger lacks, while the mix's loop counts as used; status --json gives the counts and the spend"
      else bad "assets end to end, check (exit $rc): $(printf '%s' "$a" | tail -c 500)"; fi
      # under Assets: strict a failing check stops deliver before the encode; under record (the fixture's) it is only said
      sed 's/^- Assets: record/- Assets: strict/' "$e/BRIEF.md" > "$e/BRIEF.tmp" && mv "$e/BRIEF.tmp" "$e/BRIEF.md"
      a=$(vh deliver "$e/out/film.mp4" --psnr off 2>&1); rc=$?
      sed 's/^- Assets: strict/- Assets: record/' "$e/BRIEF.md" > "$e/BRIEF.tmp" && mv "$e/BRIEF.tmp" "$e/BRIEF.md"
      case "$rc:$a" in 2:*"✗ assets check: fail"*"Assets: strict, and bin/vh assets check"*"no copy made"*)
          if [ -e "$e/out/film.upload.mp4" ] || ls "$e/out/".film.upload.mp4.* >/dev/null 2>&1; then bad "deliver under Assets: strict left a file behind"
          else ok "deliver under Assets: strict stops before the encode when assets check fails (exit 2, no copy, no part file)"; fi ;;
        *) bad "deliver under Assets: strict with a failing check: exit $rc: $(printf '%s' "$a" | tail -c 500)" ;; esac
      vh assets add "$e" "$e/assets/img/stray.png" --class own >/dev/null 2>&1
      vh assets add "$e" assets/genimg/hero/image.png --update --derived-from frames >/dev/null 2>&1   # hero was made from frames: frames is used
      a=$(vh assets check "$e" 2>&1); rc=$?
      printf 'z' >> "$e/assets/img/grey-square.png"; vh assets add "$e" "$e/assets/img/grey-square.png" --update >/dev/null 2>&1
      b=$(vh assets check "$e" 2>&1); rc2=$?
      case "$rc:$rc2|$a|$b" in "0:0|"*"pass (0 fail, 2 warn)"*"|"*"grey-square"*"out/film.mp4 was made with other bytes of it than the ledger has"*)
          case "$a" in *"frames  assets/frames/: on record"*) bad "assets end to end: frames is unused though hero, made from it, is loaded" ;;
            *) ok "assets end to end: registered, the check passes; what a used record was made from is used too; a file changed (and its record updated) after the render says the film was made with other bytes" ;; esac ;;
        *) bad "assets end to end after registering (exit $rc, $rc2): $(printf '%s' "$a$b" | tail -c 600)" ;; esac
      mkdir -p "$e/out/review"; printf '{"gate": "3", "summary": "draft", "decisions": []}' > "$e/out/review/gate-3.json"
      vh review "$e" 3 >/dev/null 2>&1
      a=$(vh deliver "$e/out/film.mp4" --psnr off 2>&1); rc=$?
      if [ $rc = 0 ] && grep -q '<span class="spend">已花 $0.54 / 预算 $1.00</span>' "$e/out/review/gate-3.html" \
         && case "$a" in *"credits: 2 line(s) the licences ask for, 1 courtesy"*"AI-generated: 2 asset(s)"*"1 asset(s) with a licence not cleared"*) true ;; *) false ;; esac \
         && case "$a" in *"assets check: pass (0 fail, "*"said, not stopping the delivery"*) true ;; *) false ;; esac \
         && python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["assets"]; c=d.pop("check"); sys.exit(0 if d=={"records": 7, "credits": 2, "aigc": 2, "uncleared": 1} and c["verdict"]=="pass" and c["fail"]==0 else 1)' "$e/out/film.upload.mp4.deliver.json"
      then ok "assets end to end: the review page shows spent / budget; deliver says assets check's verdict without stopping, what the upload owes (credits, the AI-content notice, the licences not cleared), and keeps the counts in its record"
      else bad "assets end to end, review page and deliver (exit $rc): $(printf '%s' "$a" | tail -c 500)"; fi
      a=$(vh patch "$e/out/film.mp4" --frames 3-5 --in-place --workers 1 2>&1); rc=$?
      if [ $rc = 0 ] && python3 - "$e" <<'PY'
import hashlib, json, sys
e = sys.argv[1]
side = json.load(open(f"{e}/out/film.mp4.render.json", encoding="utf-8"))
now = hashlib.sha256(open(f"{e}/assets/img/grey-square.png", "rb").read()).hexdigest()
sys.exit(0 if len(side.get("files", {})) == 4 and side["files"]["assets/img/grey-square.png"] == now and side.get("patches") else 1)
PY
      then ok "assets end to end: a patch keeps the film's table of files, with the bytes its new frames loaded"
      else bad "assets end to end, patch (exit $rc): $(printf '%s' "$a" | tail -c 500)"; fi
      # a newer film of the same page: an older film's files are history; --film and --all-films compare it; a patch on a
      # film whose sidecar has no files writes none (a few frames are not the film's files)
      vh assets remove "$e" stray >/dev/null 2>&1
      sed 's|, "assets/img/stray.png"||' "$e/index.html" > "$e/index.tmp" && mv "$e/index.tmp" "$e/index.html"
      vh render "$e" --out "$e/out/new.mp4" --workers 1 >/dev/null 2>&1; rc=$?
      a=$(vh assets check "$e" --json 2>/dev/null); r1=$?
      b=$(vh assets check "$e" --all-films 2>&1); r2=$?
      c=$(vh assets check "$e" --film "$e/out/film.mp4" 2>&1); r3=$?
      d=$(vh assets check "$e" --film "$e/out/nope.mp4" 2>&1); r4=$?
      python3 -c 'import json,sys; f=sys.argv[1]; s=json.load(open(f)); s.pop("files"); json.dump(s, open(f, "w"))' "$e/out/new.mp4.render.json"
      vh patch "$e/out/new.mp4" --frames 2-4 --in-place --workers 1 >/dev/null 2>&1; r5=$?
      x=$(vh assets check "$e" --json 2>/dev/null)
      if [ "$rc:$r1:$r2:$r3:$r4:$r5" = "0:0:1:1:2:0" ] && python3 - "$e" "$a" "$x" <<'PY'
import json, sys
e, a, x = sys.argv[1], json.loads(sys.argv[2]), json.loads(sys.argv[3])
side = json.load(open(f"{e}/out/new.mp4.render.json", encoding="utf-8"))
ok = ([f["film"] for f in a["uses"]["films"]] == ["out/new.mp4"] and a["uses"]["older"] == ["out/film.mp4"]
      and "files" not in side and side.get("patches") and x["uses"]["unknown"] == ["out/new.mp4"] and [f["film"] for f in x["uses"]["films"]] == ["out/film.mp4"])
sys.exit(0 if ok else 1)
PY
      then case "$b|$c" in *"✗ assets/img/stray.png: loaded by out/film.mp4"*"|"*"✗ assets/img/stray.png: loaded by out/film.mp4"*)
          ok "assets end to end: of a page's films only the newest is compared (an older one's files are history; --all-films and --film compare it); a patch on a film with no table of files writes none, and the film counts as not known" ;;
        *) bad "assets end to end, older films: $(printf '%s' "$b$c" | tail -c 500)" ;; esac
      else bad "assets end to end, older films (exits $rc:$r1:$r2:$r3:$r4:$r5): $(printf '%s' "$a$d" | tail -c 500)"; fi ;;
    *) bad "assets end to end: render (exit $rc): $(printf '%s' "$a" | tail -c 500)" ;;
  esac
  rm -rf "$t"
  footage_checks   # bin/vh footage: its records are the ledger's
  image_checks     # bin/vh image: so are its pictures, and its spend the budget's
  library_checks   # the sound library's picks: on record in the project's ledger
  lyria_checks     # a generated track: on record, its price the budget's
  sound_tools_checks   # check's loudness, qa --listen and --picture, beats --check
  cast_checks      # bin/vh cast: the references image gen sends with --ref cast:<id>
}

cast_checks() {   # bin/vh cast (tools/cast.py): a project's settled references, one folder an entry, and image gen
  # --ref cast:<id> (dry runs, and a replay of a recorded answer with --offline: nothing is sent, nothing spent)
  local t p a b c d rc rc2 rc3 rc4 rc5 rc6
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX"); p="$t/p"
  mkdir -p "$p/assets/genimg/x" && printf '# BRIEF\n\n- Budget: $0.20\n' > "$p/BRIEF.md"
  png() { python3 -c 'import struct, sys, zlib; c = bytes.fromhex(sys.argv[2]); raw = b"".join(b"\x00" + c * 16 for _ in range(8))
k = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + k(b"IHDR", struct.pack(">IIBBBBB", 16, 8, 8, 2, 0, 0, 0)) + k(b"IDAT", zlib.compress(raw)) + k(b"IEND", b""))' "$1" "$2"; }
  png "$p/assets/genimg/x/a.png" c83c3c; png "$p/assets/genimg/x/b.png" 3cb43c; png "$t/sheet.png" 3c50c8
  # an entry from two of image gen's pictures (front, left), then a sheet from elsewhere with its source and licence, and
  # settled; list and check; a picture changed since fails, recorded again passes; status sums it up, in its text too
  vh cast add "$p" fox --kind character --name 小狐狸 --ref assets/genimg/x/a.png=front --ref assets/genimg/x/b.png=left >/dev/null; rc=$?
  vh cast add "$p" fox --ref "$t/sheet.png=sheet" --source "drawn for the test" --license "own work" --final >/dev/null; rc2=$?
  a=$(vh cast list "$p" --json)
  png "$p/cast/fox/front.png" 000000; b=$(vh cast check "$p" 2>&1); rc3=$?
  vh cast add "$p" fox --ref cast/fox/front.png=front >/dev/null && vh cast check "$p" >/dev/null; rc4=$?
  c=$(vh status "$p" --json | python3 -c 'import json, sys; print(json.load(sys.stdin)["cast"])'); d=$(vh status "$p" 2>&1)
  if [ "$rc:$rc2:$rc3:$rc4" = 0:0:1:0 ] && grep -q "front.png is not the picture on record" <<<"$b" && [ "$c" = "{'entries': 1, 'by_kind': {'character': 1}, 'final': 1, 'failures': 0}" ] \
     && grep -q "^cast: 1 entry (1 character), 1 settled (bin/vh cast)" <<<"$d" && python3 - "$a" "$p" <<'PY'
import json, sys
from pathlib import Path
d, p = json.loads(sys.argv[1]), Path(sys.argv[2])
e = d["entries"][0]
c = json.loads((p / "cast/fox/cast.json").read_text(encoding="utf-8"))
ok = (e["id"], e["kind"], e["name"], e["status"]) == ("fox", "character", "小狐狸", "final") and [r["file"] for r in e["refs"]] == ["front.png", "left.png", "sheet.png"]
ok = ok and e["views"] == {"front": "front.png", "left": "left.png"} and c["version"] == 1 and c["refs"][0]["from"] == {"path": "assets/genimg/x/a.png"}
ok = ok and c["refs"][2]["from"] == {"file": "sheet.png"} and (c["refs"][2]["source"], c["refs"][2]["license"]) == ("drawn for the test", "own work")
ok = ok and all(len(r["sha256"]) == 64 for r in c["refs"]) and [x["severity"] for x in d["problems"]] == ["warn"] and "without the back, right views" in d["problems"][0]["message"]
sys.exit(0 if ok else 1)
PY
  then ok "cast: an entry's pictures copied in with their views and where they came from (a file from outside by its name only); a picture changed since it was recorded fails check, recorded again it passes; a settled character without four views is said; status sums the cast up"
  else bad "cast add/list/check (exit $rc:$rc2:$rc3:$rc4): $(printf '%s' "$a$b$c" | tail -c 500)"; fi
  # image gen --ref cast:<id>: the entry's pictures in its order (cast:<id>:<view>: that one), said whose they are; an id
  # or a view that is not there is a usage error, and so is an entry whose picture changed since it was recorded
  a=$(vh image gen "$p" --prompt "the fox" --ref cast:fox --ref "$t/sheet.png" --dry-run --json 2>"$t/err"); rc=$?
  b=$(vh image gen "$p" --prompt "the fox" --ref cast:fox:left --dry-run --json 2>/dev/null)
  vh image gen "$p" --prompt x --ref cast:wolf --dry-run >/dev/null 2>&1; rc2=$?
  vh image gen "$p" --prompt x --ref cast:fox:back --dry-run >/dev/null 2>&1; rc3=$?
  vh cast add "$p" Bad --kind prop --name x >/dev/null 2>&1; rc4=$?
  vh cast add "$p" owl --name x >/dev/null 2>&1; rc5=$?
  cp "$p/cast/fox/left.png" "$t/left.keep"; png "$p/cast/fox/left.png" 101010
  c=$(vh image gen "$p" --prompt x --ref cast:fox --dry-run 2>&1); rc6=$?; cp "$t/left.keep" "$p/cast/fox/left.png"
  if [ "$rc:$rc2:$rc3:$rc4:$rc5:$rc6" = 0:2:2:2:2:2 ] && grep -q "references 1–3: cast:fox (character: 小狐狸)" "$t/err" && grep -q "left.png is not the picture on record" <<<"$c" \
     && python3 -c 'import json, sys; a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2]); sys.exit(0 if a["refs"][:3] == ["cast/fox/front.png", "cast/fox/left.png", "cast/fox/sheet.png"] and len(a["refs"]) == 4 and b["refs"] == ["cast/fox/left.png"] else 1)' "$a" "$b"
  then ok "image gen --ref cast:<id> sends the entry's pictures in its order (cast:<id>:<view> one), says whose they are; an unknown entry or view, a picture changed since it was recorded, a bad id, a new entry with no kind exit 2"
  else bad "image gen --ref cast: (exit $rc:$rc2:$rc3:$rc4:$rc5:$rc6): $(printf '%s' "$a" | tail -c 300) | $(tail -c 300 "$t/err") | $(printf '%s' "$c" | tail -c 200)"; fi
  # a picture is taken by its bytes, not its name: a JPEG named .png and a text file named .png are refused by image gen
  # --ref and cast add --ref, and a picture swapped for a JPEG under its PNG name fails cast check (on the extension alone
  # they passed, and the JPEG would have gone to the vendor as a PNG)
  printf '\377\330\377\340\000\020JFIF\000' > "$t/jpeg.png"; printf 'not a picture\n' > "$t/text.png"
  a=$(vh image gen "$p" --prompt x --ref "$t/jpeg.png" --dry-run 2>&1); rc=$?
  b=$(vh cast add "$p" owl2 --kind prop --name x --ref "$t/text.png" 2>&1); rc2=$?
  cp "$p/cast/fox/sheet.png" "$t/sheet.keep"; cp "$t/jpeg.png" "$p/cast/fox/sheet.png"
  c=$(vh cast check "$p" 2>&1); rc3=$?; cp "$t/sheet.keep" "$p/cast/fox/sheet.png"
  if [ "$rc:$rc2:$rc3" = 2:2:1 ] && grep -q 'named .png, but its bytes are a JPEG: convert it to a PNG, or name it .jpg' <<<"$a" \
     && grep -q 'its bytes are no PNG, JPEG or WebP: save it as one of them, then cast add it again' <<<"$b" \
     && grep -q 'sheet.png: named .png, but its bytes are a JPEG: convert it to a PNG, or name it .jpg; then bin/vh cast add fox' <<<"$c" \
     && grep -q 'sheet.png is not the picture on record (its bytes changed)' <<<"$c" && [ ! -e "$p/cast/owl2" ]
  then ok "image gen --ref and cast take a picture by its bytes: a JPEG named .png and text named .png are refused (exit 2) with what to do, a picture swapped for a JPEG fails cast check, its bytes said to have changed too"
  else bad "pictures by their bytes (exit $rc:$rc2:$rc3): $(printf '%s | %s | %s' "$a" "$b" "$c" | tail -c 400)"; fi
  # a call made (a recorded answer replayed: --offline, nothing sent) says whose the pictures are too, and the ledger keeps
  # what it was made from; a picture recorded again with other bytes makes check say what was made from the older one. The
  # same picture twice is said, and so is a draft entry
  if command -v ffprobe >/dev/null; then
  cp -R tools/assets/fixtures/image/responses "$t/r"
  vh image gen "$p" --prompt "the fox" --ref cast:fox --ref cast:fox:left --id fox-made --offline "$t/r" >"$t/err" 2>&1; rc=$?
  png "$p/cast/fox/left.png" 3cb43d; vh cast add "$p" fox --ref cast/fox/left.png=left >/dev/null; b=$(vh cast check "$p" 2>&1); rc2=$?
  png "$t/owl.png" 777777; vh cast add "$p" owl --kind prop --name 猫头鹰 --ref "$t/owl.png" >/dev/null 2>&1
  c=$(vh image gen "$p" --prompt "the owl" --ref cast:owl --dry-run 2>&1)
  if [ "$rc:$rc2" = 0:0 ] && grep -q "references 1–4: cast:fox (character: 小狐狸)" "$t/err" && grep -q "the same picture is sent more than once: cast/fox/left.png" "$t/err" \
     && grep -q "cast/fox/left.png: fox-made (assets/genimg/fox-made/image.jpg) was made from an older version of it" <<<"$b" && grep -q "cast:owl is a draft" <<<"$c" \
     && python3 - "$p" <<'PY'
import json, sys
r = {x["id"]: x for x in json.load(open(f"{sys.argv[1]}/assets/ledger.json", encoding="utf-8"))["assets"]}["fox-made"]
sys.exit(0 if [x["path"] for x in r["inputs"]] == ["cast/fox/front.png", "cast/fox/left.png", "cast/fox/sheet.png", "cast/fox/left.png"] and all(len(x["sha256"]) == 64 for x in r["inputs"]) else 1)
PY
  then ok "image gen with --ref cast:<id>, a call replayed: whose the pictures are said, what it was made from on record; check names what was made from an older version of a picture; a picture sent twice and a draft entry are said"
  else bad "image gen --ref cast:, a call (exit $rc:$rc2): $(tail -c 400 "$t/err") | $(printf '%s' "$b" | tail -c 300) | $(printf '%s' "$c" | tail -c 200)"; fi
  else skip "image gen --ref cast:, a call replayed" "no ffprobe"; fi
  # where a picture came from: one the ledger has (bin/vh assets add) is linked by its id; one on record nowhere is said by
  # add and check. add itself: a picture that takes a side over leaves the other in refs without a view; another kind needs
  # --force; a hidden file's copy is named plainly, a hidden one in the folder refused with nothing changed; a new entry
  # whose picture is not there leaves no folder
  png "$t/lake.png" 2050a0; png "$t/lake2.png" 2050a1; png "$t/.dot.png" 404040
  vh assets add "$p" "$t/lake.png" --license CC0 --origin self >/dev/null 2>&1; rc=$?
  vh cast add "$p" lake --kind set --name 湖 --ref "$t/lake.png=front" >/dev/null; rc2=$?
  a=$(vh cast add "$p" lake --ref "$t/lake2.png=front" 2>&1); rc3=$?
  vh cast add "$p" lake --kind prop >/dev/null 2>&1; rc4=$?
  vh cast add "$p" lake --kind prop --force >/dev/null 2>&1 && vh cast add "$p" lake --kind set --force >/dev/null 2>&1; rc5=$?
  vh cast add "$p" lake --ref "$t/.dot.png" >/dev/null; cp "$t/.dot.png" "$p/cast/lake/.inner.png"; cp "$p/cast/lake/cast.json" "$t/lake.json"
  vh cast add "$p" lake --ref cast/lake/.inner.png >/dev/null 2>&1; rc6=$?
  vh cast add "$p" ghost --kind prop --name g --ref "$t/no-such.png" >/dev/null 2>&1; b=$?
  c=$(vh cast check "$p" 2>&1); d=$?
  if [ "$rc:$rc2:$rc3:$rc4:$rc5:$rc6:$b:$d" = 0:0:0:2:0:2:2:0 ] && [ ! -e "$p/cast/ghost" ] && cmp -s "$t/lake.json" "$p/cast/lake/cast.json" \
     && grep -q "front-2.png is the front view now; front.png keeps its place among the pictures, without a view" <<<"$a" && grep -q "front-2.png: where it came from and on what terms is on record nowhere" <<<"$a" \
     && grep -q "dot.png: where it came from and on what terms is on record nowhere" <<<"$c" && ! grep -q "cast/lake/cast.json: refs\[0\]: front.png: where it came from" <<<"$c" && python3 - "$p" <<'PY'
import json, sys
c = json.load(open(f"{sys.argv[1]}/cast/lake/cast.json", encoding="utf-8"))
ok = c["kind"] == "set" and c["views"] == {"front": "front-2.png"} and [(r["file"], r.get("view")) for r in c["refs"]] == [("front.png", None), ("front-2.png", "front"), ("dot.png", None)]
ok = ok and c["refs"][0]["from"].get("asset") and "asset" not in c["refs"][1]["from"]
sys.exit(0 if ok else 1)
PY
  then ok "cast add: a picture the ledger has is linked by its id, one on record nowhere is said; a side taken over leaves the other picture without a view; another kind needs --force; a hidden file's copy named plainly, a hidden picture in the folder refused with nothing changed; nothing left of a refused new entry"
  else bad "cast add's records (exit $rc:$rc2:$rc3:$rc4:$rc5:$rc6:$b, check $d): $(printf '%s' "$a" | tail -c 300) | $(printf '%s' "$c" | tail -c 400)"; fi
  # a hand-written cast.json check did not foresee (a view that is a list): a failure of that entry, said, no traceback;
  # list --json still answers; a fault of the tool itself exits 3, not 1
  python3 -c 'import json, sys; f = sys.argv[1]; d = json.load(open(f)); d["views"]["back"] = ["a"]; json.dump(d, open(f, "w"))' "$p/cast/fox/cast.json"
  a=$(vh cast check "$p" 2>&1); rc=$?; vh cast list "$p" --json >/dev/null 2>"$t/err"; rc2=$?
  b=$(python3 -c 'import sys; sys.path.insert(0, "tools"); import cast; cast.gather = lambda p: 1 / 0; sys.exit(cast.main(["check", sys.argv[1]]))' "$p" 2>&1); rc3=$?
  if [ "$rc:$rc2:$rc3" = 1:0:3 ] && grep -q "views.back: a picture's file name, not list" <<<"$a" && ! grep -q Traceback <<<"$a" && [ ! -s "$t/err" ] \
     && grep -q "an error in this tool itself, not in the cast (ZeroDivisionError" <<<"$b"
  then ok "cast check: a cast.json of a shape it did not foresee fails that entry and says why (no traceback); a fault of the tool itself exits 3"
  else bad "cast check on a hand-written view (exit $rc:$rc2:$rc3): $(printf '%s' "$a" | tail -c 300) | $(printf '%s' "$b" | head -c 200)"; fi
  rm -rf "$t"
}

scout_checks() {   # bin/vh scout and ref (tools/scout) from recorded responses, no network: YouTube through yt-dlp's recorded
  # JSON, X through fxtwitter, Bilibili's view endpoint, the hot lists; the records, the outliers, a platform that asks
  # for a verification stopping the run, rows added by hand, the references as asset records, doctor's keyless probes
  local t p r a b c rc rc2 rc3 F=tools/scout/fixtures/responses
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX"); r="$t/research"
  a=$(vh scout topic doppler effect -n 5 --baseline 2 --dir "$r" --offline "$F" --csv "$t/topic.csv" 2>&1); rc=$?
  b=$(vh scout channel @examplephysics -n 15 --dir "$r" --offline "$F" 2>&1); rc2=$?
  c=$(vh scout channel https://x.com/exampleacct --dir "$r" --offline "$F" 2>&1); rc3=$?
  if [ "$rc:$rc2:$rc3" = 0:0:0 ] && python3 - "$r/scout.jsonl" "$t/topic.csv" <<'PY'
import csv, json, sys
recs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
topic = [x for x in recs if x["via"] == "topic"]
by = {x["key"]: x for x in topic}
ok = len(topic) == 5 and all(x["v"] == 1 and x["fetched_at"] and x["method"].startswith("yt-dlp") and x["date_approx"] for x in topic)
ok = ok and by["youtube:AAAAAAAAAA1"]["multiple"] == 23.41 and by["youtube:AAAAAAAAAA1"]["baseline"] == {"of": "views", "over": "the channel's latest 15", "n": 8, "median": 102500.0}
ok = ok and by["youtube:AAAAAAAAAA2"]["multiple"] == 3.46 and "multiple" not in by["youtube:AAAAAAAAAA3"]   # only the first 2 channels
ok = ok and by["youtube:AAAAAAAAAA1"]["followers"] == 512000 and all(isinstance(x.get("z"), float) for x in topic)
ok = ok and by["youtube:AAAAAAAAAA3"]["z"] < -1 < by["youtube:AAAAAAAAAA1"]["z"] - 1
ch = [x for x in recs if x["via"] == "channel" and x["platform"] == "youtube"]
ok = ok and len(ch) == 8 and next(x for x in ch if x["metrics"]["views"] == 400000)["multiple"] == 3.9
xs = [x for x in recs if x["via"] == "channel" and x["platform"] == "x"]
ok = ok and len(xs) == 5 and xs[0]["multiple"] == 18.64 and xs[0]["followers"] == 25000 and xs[0]["metrics"]["shares"] == 650
rows = list(csv.DictReader(open(sys.argv[2], encoding="utf-8")))
ok = ok and len(rows) == 5 and rows[0]["platform"] == "youtube" and rows[0]["views"] == "2400000" and rows[0]["multiple"] == "23.41"
sys.exit(0 if ok else 1)
PY
  then case "$a|$b|$c" in *"★ 23.4×"*"★ 2 at 3× its channel's median"*"5 records onto"*"|"*"512K followers · latest 8 · median 102.5K views"*"posts about every 7 days"*"|"*"25K followers · latest 5 · median 22K views"*)
      ok "scout topic and channel from recordings: the top results with z against their age band, --baseline's channel medians and multiples (★ at 3×), a channel's and an X account's latest against their own median, how often they post; JSONL records and the CSV" ;;
    *) bad "scout topic and channel, their lines: $(printf '%s' "$a$b$c" | tail -c 600)" ;; esac
  else bad "scout topic and channel (exits $rc:$rc2:$rc3): $(printf '%s' "$a$b$c" | tail -c 600)"; fi
  # post: three platforms, then a block (Bilibili's -352) stops the run before the next URL; HTTP 412 is a block too;
  # Douyin is said to be read in the browser; a URL with no recording fails, never goes online
  a=$(vh scout post https://www.bilibili.com/video/BV1Ab4y1C7De https://x.com/exampleacct/status/1000000000000000001 "https://www.youtube.com/watch?v=AAAAAAAAAA1" --topic T05 --score 72 --dir "$r" --offline "$F" 2>&1); rc=$?
  b=$(vh scout post https://www.bilibili.com/video/BV1Zz4y1Bk00 https://www.bilibili.com/video/BV1Ab4y1C7De --dir "$t/r2" --offline "$F" 2>&1); rc2=$?
  c=$(vh scout post https://www.douyin.com/video/7000000000000000001 "https://www.youtube.com/watch?v=BBBBBBBBBB1" https://x.com/a/status/1000000000000000099 --dir "$t/r3" --offline "$F" 2>&1); rc3=$?
  if [ "$rc:$rc2:$rc3" = 0:1:1 ] && [ ! -e "$t/r2/scout.jsonl" ] && [ ! -e "$t/r3/scout.jsonl" ] && python3 - "$r/scout.jsonl" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
post = {x["platform"]: x for x in recs if x["via"] == "post"}
b, x, y = post["bilibili"], post["x"], post["youtube"]
ok = set(post) == {"bilibili", "x", "youtube"} and all(r["topic"] == "T05" and r["score"] == 72 for r in post.values())
ok = ok and b["metrics"] == {"views": 128000, "likes": 9400, "comments": 640, "shares": 950, "favorites": 3100, "coins": 1800, "danmaku": 210}
ok = ok and b["followers"] == 41000 and b["copyright"] == "original" and "license" not in b and b["method"] == "bilibili view endpoint"
ok = ok and y["date"] == "2024-04-10" and "date_approx" not in y and y["metrics"]["likes"] == 81200 and y["license"].startswith("Creative Commons")
ok = ok and x["metrics"]["views"] == 410000 and x["age_days"] >= 0 and x["per_follower"] == 16.4
sys.exit(0 if ok else 1)
PY
  then case "$a|$b|$c" in *"your films on record (3)"*"3 scored with views: 4 or more"*"|"*"✗ blocked: bilibili /x/web-interface/view: code -352 (risk control)"*"nothing was retried"*"|"*"douyin has no interface scout may read without a login"*"no recorded response"*"✗ blocked:"*"HTTP 412"*)
      if [ "$(printf '%s' "$b" | grep -c '多普勒效应')" = 0 ]; then
        ok "scout post from recordings: Bilibili (its counts, followers, original as the uploader's claim, not a licence), X and YouTube with the topic and score; a -352 and an HTTP 412 stop the run unretried, Douyin points to the browser, a URL with no recording fails offline" 
      else bad "scout post: the URL after a block was looked up: $b"; fi ;;
    *) bad "scout post, its lines: $(printf '%s' "$a$b$c" | tail -c 700)" ;; esac
  else bad "scout post (exits $rc:$rc2:$rc3, want 0:1:1; nothing written after a block): $(printf '%s' "$a$b$c" | tail -c 700)"; fi
  # add: a row by flags as the page writes its counts (1.2万), rows from a CSV, a bad count refused; --post joins the
  # report, and with 4 scored films it ranks score against views
  a=$(vh scout add https://www.douyin.com/video/7000000000000000001 --title 抖音那支 --likes 1.2万 --favorites 5600 --followers 8.1万 --date 2026-10-19 --post --score 80 --dir "$r" 2>&1); rc=$?
  printf 'platform,url,title,views,likes,date\nyoutube,https://www.youtube.com/watch?v=CCCCCCCCCC1,手填一支,90000,1200,2026-10-01\nxiaohongshu,https://www.xiaohongshu.com/explore/650000000000000000000001,笔记,,3.4K,2026-10-20\n' > "$t/rows.csv"
  b=$(vh scout add --from "$t/rows.csv" --dir "$r" 2>&1); rc2=$?
  printf 'platform,url,likes\ndouyin,https://www.douyin.com/video/7000000000000000003,lots\n' > "$t/bad.csv"
  c=$(vh scout add --from "$t/bad.csv" --dir "$r" 2>&1); rc3=$?
  d=$(vh scout add "https://www.youtube.com/watch?v=CCCCCCCCCC2" --views 50000 --likes 900 --date 2026-10-10 --post --score 60 --dir "$r" 2>&1) || rc3=9
  if [ "$rc:$rc2:$rc3" = 0:0:2 ] && python3 - "$r/scout.jsonl" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
d = next(x for x in recs if x["platform"] == "douyin")
xhs = next(x for x in recs if x["platform"] == "xiaohongshu")
ok = d["via"] == "post" and d["metrics"] == {"likes": 12000, "favorites": 5600} and d["followers"] == 81000 and d["method"] == "built-in browser, read by hand"
ok = ok and xhs["via"] == "add" and xhs["key"] == "xiaohongshu:650000000000000000000001" and xhs["metrics"] == {"likes": 3400}
ok = ok and not any(x.get("platform") == "douyin" and x["url"].endswith("0003") for x in recs)
sys.exit(0 if ok else 1)
PY
  then case "$a|$c|$d" in *"your films on record (4)"*"3 scored with views"*"|"*"bad.csv:2: likes 'lots' is not a count"*"|"*"your films on record (5)"*"score against views, Spearman ρ = +"*"over 4 films"*)
      ok "scout add: rows read by hand (flags or a CSV, counts as the page writes them), a bad count refused with its row; --post joins your films" ;;
    *) bad "scout add, its lines: $(printf '%s' "$a$c" | tail -c 500)" ;; esac
  else bad "scout add (exits $rc:$rc2:$rc3, want 0:0:2): $(printf '%s' "$a$b$c" | tail -c 500)"; fi
  # a later look at a film without --topic or --score keeps the ones given before (it stays in the rank correlation);
  # a block on the uploader's follower count is said, the video's own numbers kept, the run stopped there, exit 1
  a=$(vh scout post https://x.com/exampleacct/status/1000000000000000001 --dir "$r" --offline "$F" 2>&1); rc=$?
  b=$(vh scout post https://www.bilibili.com/video/BV1Cd4y1F7Gh https://www.bilibili.com/video/BV1Ab4y1C7De --dir "$t/r4" --offline "$F" 2>&1); rc2=$?
  case "$rc:$rc2|$a|$b" in "0:1|"*"your films on record (5)"*"Spearman ρ = +"*"over 4 films"*"|"*"BV1Cd4y1F7Gh: no follower count, blocked: bilibili /x/relation/stat: code -352"*"✗ blocked:"*"(not asked again this run)"*"→ 1 record onto"*)
      if [ "$(wc -l < "$t/r4/scout.jsonl" | tr -d ' ')" = 1 ] && ! grep -q '"followers"' "$t/r4/scout.jsonl"; then
        ok "scout post again without --topic or --score keeps the film's topic and score; a blocked follower count is said, the video's numbers kept, the run stopped there (exit 1)"
      else bad "scout post with its follower count blocked: $(cat "$t/r4/scout.jsonl")"; fi ;;
    *) bad "scout post again, or with its follower count blocked (exits $rc:$rc2, want 0:1): $(printf '%s' "$a$b" | tail -c 700)" ;; esac
  # hot: four lists into today's snapshot, a second run appended to it; an unknown list is a usage error
  a=$(vh scout hot --dir "$r" --offline "$F" -n 3 2>&1); rc=$?
  b=$(vh scout hot --source baidu --dir "$r" --offline "$F" --json 2>/dev/null); rc2=$?
  c=$(vh scout hot --source baidu,weibo --dir "$r" --offline "$F" 2>&1); rc3=$?
  if [ "$rc:$rc2:$rc3" = 0:0:2 ] && python3 - "$r/hot" "$b" <<'PY'
import json, sys
from pathlib import Path
fs = sorted(Path(sys.argv[1]).glob("*.json"))
doc = json.loads(fs[-1].read_text(encoding="utf-8")) if fs else {}
srcs = [s["source"] for s in doc.get("snapshots", [])]
b = [s for s in doc["snapshots"] if s["source"] == "baidu"][0]["items"]
g = [s for s in doc["snapshots"] if s["source"] == "google"][0]["items"]
ok = len(fs) == 1 and srcs == ["baidu", "toutiao", "google", "x", "baidu"] and b[0]["pinned"] and b[1] == {"rank": 1, "title": "救护车为什么变调", "score": 4920000, "url": "https://www.baidu.com/s?wd=b", "desc": "一个合成的热搜"}
ok = ok and g[0]["score"] == 2000 and g[0]["news"][0]["url"] == "https://example.com/radar" and json.loads(sys.argv[2])["snapshots"][0]["source"] == "baidu"
sys.exit(0 if ok else 1)
PY
  then ok "scout hot from recordings: Baidu, Toutiao, Google Trends and X into hot/<date>.json, a later run appended to the day; an unknown list refused"
  else bad "scout hot (exits $rc:$rc2:$rc3): $(printf '%s' "$a$c" | tail -c 500)"; fi
  # list: the latest look at each key, filtered, as CSV; nowhere to read is a usage error; topic with nowhere to write says so
  a=$(vh scout list --dir "$r" --via post --csv "$t/posts.csv" 2>&1); rc=$?
  b=$(cd "$t" && OVH_SCOUT="" "$VH_BASH" "$ROOT/bin/vh" scout list 2>&1); rc2=$?
  c=$(cd "$t" && OVH_SCOUT="" "$VH_BASH" "$ROOT/bin/vh" scout topic doppler effect -n 5 --offline "$ROOT/$F" 2>&1); rc3=$?
  case "$rc:$rc2:$rc3|$a|$b|$c" in "0:2:0|"*"5 records (the latest look at each)"*"|"*"no research folder"*"|"*"not written: no research folder"*)
      if [ "$(wc -l < "$t/posts.csv" | tr -d ' ')" = 6 ]; then ok "scout list: the latest look at each, filtered, as CSV; with no research folder list refuses and topic prints without writing"
      else bad "scout list --csv: $(cat "$t/posts.csv")"; fi ;;
    *) bad "scout list (exits $rc:$rc2:$rc3): $(printf '%s' "$a$b$c" | tail -c 500)" ;; esac
  # ref: references as asset records in research/refs.json, out of the project's ledger; a CC licence the platform
  # names is classified, anything else unknown (a platform's "original" is never "own"); a duplicate refused; a block exits 1
  OVH_PROJECTS="$t" vh new short refs >/dev/null 2>&1; p=$(ls -d "$t"/*-refs)
  cp "$F/cover-1.jpg" "$p/frame.jpg"
  a=$(vh ref add "$p" "https://www.youtube.com/watch?v=AAAAAAAAAA1" --why 慢放的开场 --thumb --offline "$F" 2>&1); rc=$?
  b=$(vh ref add "$p" https://youtu.be/AAAAAAAAAA1 --offline "$F" 2>&1; vh ref add "$p" https://www.bilibili.com/video/BV1Ab4y1C7De --offline "$F" 2>&1; vh ref add "$p" https://www.bilibili.com/video/BV1Zz4y1Bk00 --offline "$F" 2>&1); rc2=$?
  c=$(vh ref add "$p" "https://example.com/a?id=3" --title 一篇文章 --type page 2>&1; vh ref add "$p" frame.jpg --why 构图 2>&1; vh ref list "$p" 2>&1); rc3=$?
  if [ "$rc" = 0 ] && [ -s "$p/research/refs/yt-AAAAAAAAAA1/thumb.jpg" ] && [ ! -e "$p/assets/ledger.json" ] && python3 - "$p" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, "tools/assets")
import ledger
p = Path(sys.argv[1])
d = json.loads((p / "research/refs.json").read_text(encoding="utf-8"))
by = {r["id"]: r for r in d["assets"]}
ok = list(by) == ["yt-AAAAAAAAAA1", "bili-BV1Ab4y1C7De", "example.com-a", "frame"] and not any(ledger.validate(r) for r in d["assets"])
ok = ok and [e["event"] for e in d["events"]] == ["add"] * 4
y, b, w, f = by["yt-AAAAAAAAAA1"], by["bili-BV1Ab4y1C7De"], by["example.com-a"], by["frame"]
ok = ok and y["license"] == {"class": "cc-by", "name": "Creative Commons Attribution license (reuse allowed)", "by": "classifier"}
ok = ok and y["path"] == "research/refs/yt-AAAAAAAAAA1/" and y["ref"]["why"] == "慢放的开场" and y["ref"]["metrics"]["views"] == 2400311
ok = ok and b["license"]["class"] == "unknown" and b["source"]["provider_id"] == "BV1Ab4y1C7De" and b["ref"]["followers"] == 41000
ok = ok and w["source"]["url"] == "https://example.com/a?id=…" and w["ref"]["type"] == "page" and w["license"]["class"] == "unknown"
ok = ok and f["path"] == "frame.jpg" and f["kind"] == "image" and f["source"]["origin"] == "user"
meta = json.loads((p / "research/refs/yt-AAAAAAAAAA1/meta.json").read_text(encoding="utf-8"))
ok = ok and meta["title"] == "The Doppler effect, slowed down" and meta["description"].startswith("A siren")
sys.exit(0 if ok else 1)
PY
  then case "$b|$c" in *"is on record already as yt-AAAAAAAAAA1"*"✓ bili-BV1Ab4y1C7De"*"✗ blocked: bilibili"*"|"*"4 references (studied, not shown)"*"why: 构图"*)
      if [ "$rc2" = 1 ] && [ "$rc3" = 0 ]; then ok "ref add and list: a YouTube video (CC BY as it says, its cover fetched), a Bilibili BV (all rights reserved: unknown), a page as given, a file where it is; asset records in research/refs.json, none in the project's ledger; a duplicate refused, a block exits 1"
      else bad "ref: exits $rc2:$rc3, want 1:0"; fi ;;
    *) bad "ref add and list, their lines: $(printf '%s' "$b$c" | tail -c 600)" ;; esac
  else bad "ref add (exit $rc): $(printf '%s' "$a$b$c" | tail -c 600)"; fi
  # status reads the project's research/: the scout records, the days with a hot-list snapshot, the references; then a
  # reference whose uploader's follower count is blocked is kept, said, and exits 1; ref fetch is a name kept, not built
  vh scout add https://www.douyin.com/video/7000000000000000005 --likes 300 --post --project "$p" >/dev/null 2>&1
  vh scout hot --source baidu --project "$p" --offline "$F" >/dev/null 2>&1
  a=$(vh status "$p" --json 2>/dev/null); b=$(vh status "$p" 2>&1)
  c=$(vh ref add "$p" https://www.bilibili.com/video/BV1Cd4y1F7Gh --offline "$F" 2>&1); rc=$?
  d=$(vh ref fetch 2>&1); rc2=$?
  if python3 - "$a" <<'PY'
import json, sys
r = json.loads(sys.argv[1])["research"]
ok = r["scout"]["file"] == "research/scout.jsonl" and (r["scout"]["records"], r["scout"]["latest"], r["scout"]["films"]) == (1, 1, 1) and r["scout"]["last"]
ok = ok and r["hot"]["days"] == 1 and r["hot"]["first"] == r["hot"]["last"] and r["refs"] == {"file": "research/refs.json", "records": 4, "error": None}
sys.exit(0 if ok else 1)
PY
  then case "$rc:$rc2|$b|$c|$d" in "1:2|"*"research: 1 scout record (1 looked at, 1 your own) · hot lists on 1 day (the last "*"· 4 references (bin/vh scout, bin/vh ref)"*"|"*"! no follower count, blocked: bilibili /x/relation/stat: code -352"*"✓ bili-BV1Cd4y1F7Gh"*"|"*"references/fetch.sh"*)
      ok "status --json and its lines: the project's research/ (scout records, hot-list days, references); ref add keeps a reference whose follower count is blocked and says so (exit 1); ref fetch is kept as a name" ;;
    *) bad "status's research, or ref add with its follower count blocked (exits $rc:$rc2, want 1:2): $(printf '%s' "$b$c$d" | tail -c 700)" ;; esac
  else bad "status --json, its research: $(printf '%s' "$a" | tail -c 500)"; fi
  # doctor's probes of the public services that take no key, from recordings: a JSON path that must be there, an RSS text
  mkdir -p "$t/rec"; printf '{"code": 200, "status": {"id": "20"}}' > "$t/rec/fx.json"; printf '<rss version="2.0"></rss>' > "$t/rec/g.xml"
  printf '{"code": 0, "message": "0", "data": null}' > "$t/rec/bi.json"; printf '{"code": -352, "message": "-352"}' > "$t/rec/bv.json"
  printf '{"v": 1, "responses": [{"url": "https://api.fxtwitter.com/2/status/20", "status": 200, "body": "fx.json"}, {"url": "https://trends.google.com/trending/rss?geo=US", "status": 200, "body": "g.xml"}, {"url": "https://top.baidu.com/api/board?platform=pc&tab=realtime", "status": 200, "body": "bi.json"}, {"url": "https://www.toutiao.com/hot-event/hot-board/?origin=toutiao_pc", "status": 403}, {"url": "https://api.bilibili.com/x/web-interface/view?bvid=BV1xx411c7mD", "status": 200, "body": "bv.json"}]}' > "$t/rec/responses.json"
  a=$(python3 tools/doctor.py --json --probe --only fxtwitter,google-trends,baidu-top,toutiao-hot,bilibili-view --offline "$t/rec" 2>&1); rc=$?
  b=$(python3 tools/doctor.py --probe --only nosuch 2>&1); rc2=$?; c=$(python3 tools/doctor.py --only fxtwitter 2>&1); rc3=$?
  if [ "$rc:$rc2:$rc3" = 0:2:2 ] && python3 - "$a" <<'PY'
import json, sys
pr = {m["name"]: m["probe"] for m in json.loads(sys.argv[1])["modules"] if m["probe"]}
ok = set(pr) == {"fxtwitter", "google-trends", "baidu-top", "toutiao-hot", "bilibili-view"}
ok = ok and pr["fxtwitter"] == {"state": "ok", "note": "answers (HTTP 200, no key)"} and pr["google-trends"]["state"] == "ok"
ok = ok and pr["baidu-top"]["state"] == "failed" and "no data.cards" in pr["baidu-top"]["note"]
ok = ok and pr["toutiao-hot"] == {"state": "failed", "note": "HTTP 403"} and pr["bilibili-view"] == {"state": "failed", "note": "api.bilibili.com refused: status_code -352"}
sys.exit(0 if ok else 1)
PY
  then ok "doctor --probe of the keyless services from recordings: an answer the adapter reads, one without its path, an RSS feed, an HTTP error, a refusal code (named by its host); --only picks the probes, a name it lacks and --only without --probe are usage errors"
  else bad "doctor's keyless probes (exits $rc:$rc2:$rc3): $(printf '%s' "$a$b$c" | tail -c 500)"; fi
  # topic's titles of the ★ results against the rest's, and --covers: each cover with its caption, one sheet beside them
  # (bin/vh sheet's folder form: pillow through uv); a folder with no pictures is refused
  a=$(vh scout topic doppler effect -n 5 --baseline 2 --covers --dir "$t/cov" --offline "$F" 2>&1); rc=$?
  case "$rc|$a" in "0|"*"titles"*"★ 2: 27.5 characters · 1/2 a question · 0/2 a number"*"the rest 3: 24 characters · 0/3 a question · 1/3 a number"*)
      if ! command -v uv >/dev/null 2>&1; then skip "scout topic --covers: the sheet" "no uv"
      elif [ "$(find "$t/cov/covers" -mindepth 2 -name '*.jpg' | wc -l | tr -d ' ')" = 5 ] && [ -n "$(find "$t/cov/covers" -maxdepth 1 -name '*.png')" ] \
          && grep -q '"01-AAAAAAAAAA1.jpg": "#1 · 2.4M · 23.4× · The Doppler effect, slowed down"' "$t"/cov/covers/*/captions.json; then
        mkdir -p "$t/empty"; b=$(vh sheet "$t/empty" 2>&1); rc2=$?
        if [ "$rc2" != 0 ] && printf '%s' "$b" | grep -q "no pictures"; then
          ok "scout topic: the ★ results' titles against the rest's; --covers fetches each cover with its caption and draws one sheet beside them (bin/vh sheet <folder>); a folder with no pictures is refused"
        else bad "bin/vh sheet on an empty folder (exit $rc2): $b"; fi
      else bad "scout topic --covers: $(find "$t/cov/covers" | head -12)"; fi ;;
    *) bad "scout topic's titles and covers (exit $rc): $(printf '%s' "$a" | tail -c 500)" ;; esac
  # usage errors exit 2 and print to stderr only
  rc=0; for x in "scout" "scout bogus" "scout topic" "ref" "ref add" "scout channel https://www.bilibili.com/video/BV1Ab4y1C7De"; do
    # shellcheck disable=SC2086
    a=$(vh $x 2>/dev/null); b=$?; [ "$b" = 2 ] && [ -z "$a" ] || { rc=1; bad "bin/vh $x: exit $b, stdout ${a:0:80}"; }
  done
  [ "$rc" = 1 ] || ok "scout and ref: usage errors exit 2, nothing on stdout"
  rm -rf "$t"
}

hf_checks() {   # bin/vh hf (tools/hf.py): HyperFrames' registry at the pin's tag, from a synthetic registry recorded under
  # the tag v0.0.0-ci (tools/assets/fixtures/hf-registry; HYPERFRAMES_VERSION points the tool there), no network
  local t p F a b c rc rc2 rc3
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX"); F="$ROOT/tools/assets/fixtures/hf-registry"
  a=$(HYPERFRAMES_VERSION=0.0.0-ci vh hf catalog --offline "$F" --json 2>/dev/null); rc=$?
  b=$(HYPERFRAMES_VERSION=0.0.0-ci vh hf catalog grain --offline "$F" 2>&1); c=$(HYPERFRAMES_VERSION=0.0.0-ci vh hf catalog --tag texture --type component --offline "$F" 2>&1)
  if [ $rc = 0 ] && python3 -c 'import json,sys; d=json.loads(sys.argv[1]); n=sorted(i["name"] for i in d["items"]); sys.exit(0 if n==["cdn-test","grain-test","title-test"] and d["registry"].endswith("/v0.0.0-ci/registry") and d["pin"]=="0.0.0-ci" else 1)' "$a" \
     && case "$b" in *"title-test"*"grain-test"*"2 of 3"*) true ;; *) false ;; esac \
     && case "$c" in *"cdn-test"*"grain-test"*"2 of 3"*) ! printf '%s' "$c" | grep -q title-test ;; *) false ;; esac
  then ok "hf catalog: the registry at the pin's tag, examples left out; words, --tag and --type filter; --json"
  else bad "hf catalog: $a | $b | $c"; fi
  # the registry read: an item that answers 429 is read once more, then the read is cut short with what it had kept;
  # the next read takes only the rest (a stand-in opener, no network, no pause)
  if a=$(python3 - "$t/cache" <<'PY' 2>&1
import json, os, sys
sys.path.insert(0, "tools"); sys.path.insert(0, "tools/assets")
import fetch, hf
hf.time.sleep = lambda s: None
os.environ["XDG_CACHE_HOME"] = sys.argv[1]
class R:
    def __init__(self, body): self.body = body.encode()
    def read(self, n=-1): return self.body
    def close(self): pass
class Opener:
    def __init__(self, bad=()): self.bad, self.calls = set(bad), []
    def open(self, url, headers=None, timeout=60):
        self.calls.append(url)
        if url.endswith("/registry.json"):
            return R(json.dumps({"items": [{"name": n, "type": "hyperframes:block"} for n in ("a-one", "b-two", "c-three")]}))
        name = url.rsplit("/", 2)[-2]
        if name in self.bad:
            raise fetch.FetchError(f"{url}: HTTP 429 Too Many Requests")
        return R(json.dumps({"name": name, "type": "hyperframes:block", "title": name}))
v, bad, good = "9.9.9-ci", Opener({"b-two"}), Opener()
try:
    hf.load_registry(v, bad)
    sys.exit("a 429 that stays did not stop the read")
except fetch.FetchError as e:
    msg = str(e)
part = sorted(i["name"] for i in json.load(open(hf.partial_file(v)))["items"])
items = [i["name"] for i in hf.load_registry(v, good)]
again = [u.rsplit("/", 2)[-2] for u in good.calls if u.endswith("registry-item.json")]
tried = sum(u.endswith("/b-two/registry-item.json") for u in bad.calls)
ok = ("1 of 3 items" in msg and "kept" in msg and tried == 2 and part == ["a-one", "c-three"] and again == ["b-two"]
      and items == ["a-one", "b-two", "c-three"] and not hf.partial_file(v).exists() and hf.cache_file(v).exists())
print(msg if ok else f"{msg} | partial {part} | read again {again} | tried b-two {tried} | {items}")
sys.exit(0 if ok else 1)
PY
  ); then ok "hf catalog's read: a 429 is tried once more, a read cut short keeps what it read and the next one reads only the rest"
  else bad "hf registry read with a 429: $a"; fi
  # add: dependencies first, hyperframes.json pointed at the tag, the files on the ledger with the item's licence (the
  # repository's Apache-2.0 when it names none), the scan's warnings; a file from elsewhere with no licence is unknown
  p="$t/p"; mkdir -p "$p"; printf '# BRIEF\n' > "$p/BRIEF.md"; printf '<!doctype html><div data-composition-id="main"></div>\n' > "$p/index.html"
  printf '{"registry": "https://raw.githubusercontent.com/heygen-com/hyperframes/main/registry"}\n' > "$p/hyperframes.json"
  a=$(HYPERFRAMES_VERSION=0.0.0-ci vh hf add "$p" title-test --offline "$F" --json 2>/dev/null); rc=$?
  if [ $rc = 0 ] && python3 - "$p" "$a" <<'PY'
import json, sys
p, d = sys.argv[1], json.loads(sys.argv[2])
cfg = json.load(open(f"{p}/hyperframes.json", encoding="utf-8"))
recs = {r["path"]: r for r in json.load(open(f"{p}/assets/ledger.json", encoding="utf-8"))["assets"]}
g, b = recs.get("compositions/components/grain-test.html"), recs.get("compositions/title-test.html")
what = sorted({h["what"] for hs in d["scan"].values() for h in hs})
notes = all(hs[0]["what"] in (recs.get(at) or {}).get("note", "") for at, hs in d["scan"].items() if at in recs)
ok = (cfg["registry"].endswith("/v0.0.0-ci/registry") and [x["name"] for x in cfg["registryItems"]] == ["grain-test", "title-test"]
      and d["installed"] == ["grain-test", "title-test"] and g and b and g["license"]["class"] == "free" and g["license"]["name"] == "Apache-2.0"
      and b["license"]["name"] == "MIT" and b["source"]["provider"] == "hyperframes-registry" and b["source"]["file_url"].endswith("/blocks/title-test/title-test.html")
      and what == ["CSS @keyframes", "CSS animation", "Math.random", "loads from the network"] and d["snippet"].startswith('<div data-composition-src="compositions/title-test.html"')
      and "Apache-2.0 presumed" in g.get("note", "") and "presumed" not in b.get("note", "") and notes)
sys.exit(0 if ok else 1)
PY
  then ok "hf add --offline: its dependency first, hyperframes.json pinned to the tag, each file on the ledger (MIT, or the repository's Apache-2.0, said to be presumed), the clock and network lines warned and noted on the file's record"
  else bad "hf add --offline (exit $rc): $a"; fi
  a=$(HYPERFRAMES_VERSION=0.0.0-ci vh hf add "$p" cdn-test --offline "$F" 2>&1); rc=$?
  b=$(vh assets check "$p" 2>&1); rc2=$?
  case "$rc:$rc2:$a:$b" in 0:1:*"assets/noise.png  unknown"*:*"noise"*"unknown"*) ok "hf add: a file the item fetches from elsewhere, with no licence named, is unknown on the ledger; assets check (strict) fails on it" ;;
    *) bad "hf add of a file from elsewhere ($rc, $rc2): $a | $b" ;; esac
  printf '<!-- edited -->\n' >> "$p/compositions/components/grain-test.html"
  a=$(HYPERFRAMES_VERSION=0.0.0-ci vh hf add "$p" grain-test --offline "$F" 2>&1); rc=$?
  b=$(HYPERFRAMES_VERSION=0.0.0-ci vh hf add "$p" grain-test --offline "$F" --force 2>&1); rc2=$?
  if [ "$rc:$rc2" = "0:0" ] && grep -q edited <<<"$a" && ! grep -q edited "$p/compositions/components/grain-test.html" && python3 - "$p" <<'PY'
import hashlib, json, sys
p = sys.argv[1]; f = "compositions/components/grain-test.html"
r = next(x for x in json.load(open(f"{p}/assets/ledger.json", encoding="utf-8"))["assets"] if x["path"] == f)
sys.exit(0 if r["sha256"] == hashlib.sha256(open(f"{p}/{f}", "rb").read()).hexdigest() else 1)
PY
  then ok "hf add keeps a file edited since it was installed; --force writes it again and updates its record"
  else bad "hf add over an edited file ($rc, $rc2): $a | $b"; fi
  a=$(HYPERFRAMES_VERSION=0.0.0-ci vh hf add "$p" demo-test --offline "$F" 2>&1); rc=$?
  b=$(HYPERFRAMES_VERSION=0.0.0-ci vh hf add "$p" no-such --offline "$F" 2>&1); rc2=$?
  c=$(HYPERFRAMES_VERSION=0.0.0-ci vh hf add "$p" title-test --offline "$F" --vars '{"a": 1}' 2>&1); rc3=$?
  case "$rc:$rc2:$rc3:$a:$b" in 2:2:2:*"an example"*:*"no 'no-such'"*) ok "hf add: an example, a name the registry lacks and --vars offline are usage errors (exit 2)" ;;
    *) bad "hf add refusals ($rc, $rc2, $rc3): $a | $b | $c" ;; esac
  # online, HyperFrames' own add runs: its --json read (a stand-in prints what 0.8.202 prints), its files recorded
  mkdir -p "$p/node_modules/.bin"
  cat > "$p/node_modules/.bin/hyperframes" <<'SH'
#!/bin/sh
mkdir -p compositions/components && printf '<div id="x"></div>\n' > compositions/components/stand-in.html
printf '{"ok":true,"name":"grain-test","type":"hyperframes:component","written":["%s/compositions/components/stand-in.html"],"preserved":[],"installed":["grain-test"],"snippet":"<!-- paste -->","warnings":["a warning of its own"]}\n' "$PWD"
SH
  chmod +x "$p/node_modules/.bin/hyperframes"
  if a=$(cd "$ROOT/tools" && python3 - "$p" "$F" <<'PY'
import sys
import hf, fetch
p, F = hf.Path(sys.argv[1]), sys.argv[2]
res, v = hf.install_online(p, "grain-test", "0.0.0-ci", False, None)
plan = hf.resolve("grain-test", hf.registry_of("0.0.0-ci"), fetch.Replay(F))
recs = hf.record(p, res["written"], plan, hf.registry_of("0.0.0-ci"), "0.0.0-ci")
ok = res["warnings"] == ["a warning of its own"] and [r["path"] for r in recs] == ["compositions/components/stand-in.html"] and v is None
print(res, recs); sys.exit(0 if ok else 1)
PY
  ); then ok "hf add online: HyperFrames' own add runs in the project (its own CLI), its --json is read and what it wrote goes on the ledger"
  else bad "hf add online with a stand-in CLI: $a"; fi
  rm -rf "$t"
}

components_checks() {   # bin/vh components (tools/components.py, components/): the tables and the code agree, each state is a
  # function of t, add copies what a project needs, and a page of classic scripts (canvas-film's kind) and one of modules
  # draw the library and the components through the page contract, the same frames in any order
  local t p a b rc rc2
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  a=$(vh components check 2>&1); rc=$?
  cp -R "$ROOT/components" "$t/comp"
  python3 - "$t/comp/page-turn/slots.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p, encoding="utf-8"))
next(x for x in d["slots"] if x["name"] == "slices")["default"] = 12
json.dump(d, open(p, "w", encoding="utf-8"))
PY
  b=$(OVH_COMPONENTS="$t/comp" vh components check 2>&1); rc2=$?
  case "$rc:$rc2:$b" in 0:1:*"slices's default is 48 in component.js, 12 in slots.json"*) ok "components check: each component's defaults are its slots.json's, its painters exported, a sample there; a default that differs is named" ;;
    *) bad "components check ($rc, $rc2): $a | $b" ;; esac
  # lib.easeOf: an unknown string gets each caller's own fallback (the first call's used to be cached for all), and a
  # name is one of lib.ease's own (an object's inherited constructor or toString used to be taken for a curve)
  if a=$(cd "$ROOT" && node --input-type=module -e '
import { easeOf, ease } from "./components/lib/core.js";
const bad = [];
if (easeOf("bogus", ease.linear) !== ease.linear || easeOf("bogus", ease.inCubic) !== ease.inCubic || easeOf("bogus") !== ease.outExpo) bad.push("an unknown string kept the first fallback");
for (const n of ["constructor", "toString", "__proto__", "hasOwnProperty", "Constructor"]) {
  let f; try { f = easeOf(n); } catch (e) { f = e.message; }
  if (f !== ease.outExpo) bad.push(`${n}: ${typeof f === "function" ? f.name || "a function" : f}`);
}
const o = easeOf("ease-out");
if (o !== easeOf("ease-out") || !(Math.abs(o(0.5) - 0.6846) < 1e-3) || easeOf("outExpo") !== ease.outExpo || easeOf("steps(4)")(0.6) !== 0.5) bad.push("the curves themselves");
console.log(bad.join("; ")); process.exit(bad.length ? 1 : 0);' 2>&1); then ok "components lib: easeOf gives an unknown string each caller's own fallback, and takes only lib.ease's own names (constructor, toString, __proto__ are none)"
  else bad "components lib, easeOf: $a"; fi
  # every state() is a function of its arguments: the same JSON forwards, backwards and alone
  if a=$(cd "$ROOT" && node --input-type=module -e '
const bad = [], ts = [0, 0.3, 0.71, 1.2, 2.5, 3.9, 4.99];
const run = async (name, fn) => { const fw = ts.map(fn).map((x) => JSON.stringify(x)), bw = [...ts].reverse().map(fn).map((x) => JSON.stringify(x)).reverse(), one = JSON.stringify(fn(ts[3]));
  if (fw.join() !== bw.join() || one !== fw[3]) bad.push(name); };
const S = await import("./components/spring-scene/component.js"), P = { ...S.defaults, layers: [{ id: "a", tin: 0.2, tout: 1.5 }], cursor: { keys: [[0, 0, 0], [1, 50, 20]], clicks: [0.9] } };
await run("spring-scene", (t) => S.state(P, t));
const T = await import("./components/page-turn/component.js"); await run("page-turn", (t) => T.state({}, t / 5)); await run("page-turn backward", (t) => T.state({ backward: true }, t / 5));
const F = await import("./components/paper-transition/component.js"); await run("fold", (t) => F.state({}, t / 5)); await run("blot", (t) => F.state({ variant: "blot" }, t / 5));
const C = await import("./components/chapter-bar/component.js"), CP = { chapters: [{ t: 0, title: "一" }, { t: 1, title: "二二" }, { t: 3, title: "三" }], end: 5 };
const lay = C.layout(CP, (s, z) => s.length * z * 0.6); await run("chapter-bar", (t) => C.state(CP, t, lay));
const B = await import("./components/build-up/component.js"), cube = (x, y, z) => ({ x, y, z, w: 1, h: 1, d: 1 });
const BP = [{ pieces: [cube(0, 0.5, 0), cube(1, 0.5, 0), cube(0, 1.5, 0), cube(1, 1.5, 1)], order: "height", bucket: 1, stagger: 0.7, jitter: 0.3, appear: "rise" },
  { pieces: [cube(0, 0.5, 0), cube(2, 0.5, 0), cube(4, 0.5, 0)], order: "distance", from: [4, 0, 0], appear: "grow", stagger: 1 },
  { pieces: [cube(0, 0.5, 0), cube(1, 0.5, 0), cube(2, 0.5, 0)], order: "random", seed: 9, appear: "drop", stagger: 0.9 }];
for (const p of BP) await run(`build-up ${p.order}`, (t) => B.state({ ...p }, t));   // a fresh object each call: no plan cached between them
const st = B.state(BP[0], 0.69), ranks = B.plan(BP[0]).rank, grow = B.state(BP[1], 0.25).pieces;   // 0.69: the first floor in, the second not yet (0.7 on)
if (ranks.join() !== "0,0,1,1" || st.started !== 2 || B.duration(BP[0]) > 0.7 + 0.3 + 0.5 + 1e-9 || !(grow[2].box.h > 0 && grow[0].box.h === 0 && grow[2].box.y - grow[2].box.h / 2 === 0)) bad.push("build-up: ranks, starts or growth");
// one params object changed after its plan was made: the plan follows (a stagger, a piece pushed onto its list)
const M = { ...BP[0], pieces: [...BP[0].pieces] }, j = (x) => JSON.stringify(x);
B.state(M, 0.9); M.stagger = 0.2;
if (j(B.state(M, 0.9)) !== j(B.state({ ...M }, 0.9))) bad.push("build-up: a stagger changed after the plan was made");
M.pieces.push(cube(2, 2.5, 0));
const five = B.state(M, 3);
if (five.n !== 5 || five.pieces.some((q) => !Number.isFinite(q.t0) || !Number.isFinite(q.box.y) || !Number.isFinite(q.u))) bad.push(`build-up: a piece pushed after the plan: ${j(five.pieces[4])}`);
// dur 0 is a step; an overshooting curve carries a rising piece past its place, never a grown one past its size; a wrong name or piece is an error
const one = (o, t) => B.state({ pieces: [cube(0, 0.5, 0)], ...o }, t).pieces[0];
if (one({ dur: 0 }, -0.1).on || j(one({ dur: 0 }, 0).box) !== j(cube(0, 0.5, 0)) || one({ dur: 0 }, 0).u !== 1) bad.push(`build-up: dur 0 ${j(one({ dur: 0 }, 0))}`);
if (!(one({ ease: "outBack", lift: 1, dur: 1 }, 0.6).box.y > 0.5) || one({ ease: "outBack", appear: "grow", dur: 1 }, 0.6).box.h > 1 || one({ ease: "outBack", dur: 1 }, 1).box.y !== 0.5)
  bad.push(`build-up: overshoot ${j(one({ ease: "outBack", lift: 1, dur: 1 }, 0.6).box)}`);
[[{ ease: "outBak" }, "ease is a name"], [{ pieces: [{ x: 0, y: 0, z: 0, w: 1, d: 1 }] }, "pieces[0].h is a number"], [{ stagger: -1 }, "stagger is a number, 0 or more"], [{ from: [1, 2] }, "from is [x, y, z]"]].forEach(([o, want]) => {
  try { B.state({ pieces: [cube(0, 0.5, 0)], ...o }, 1); bad.push(`build-up: ${j(o)} passed`); } catch (e) { if (!String(e.message).includes(want)) bad.push(`build-up: ${j(o)}: ${e.message}`); } });
if (bad.length) { console.log(bad.join(", ")); process.exit(1); }' 2>&1); then ok "components: each state(), spring-scene, page-turn (both ways), fold, blot, chapter-bar and build-up (by height, distance, seed), the same forwards, backwards and alone; build-up's ranks, starts and growth from the base, its plan after its params change, dur 0, an overshoot, errors that name the part"
  else bad "components: a state() that depends on what was drawn before: $a"; fi
  # add: the library and the components named, and what a component imports from another (paper-transition: page-turn)
  p="$t/proj"; mkdir -p "$p"; printf '# BRIEF\n' > "$p/BRIEF.md"; printf '<!doctype html>\n' > "$p/film.html"
  a=$(vh components add "$p" paper-transition chapter-bar build-up 2>&1); rc=$?
  b=$(vh components add "$p" no-such 2>&1); rc2=$?
  if [ "$rc:$rc2" = "0:2" ] && [ -f "$p/components/lib/global.js" ] && [ -f "$p/components/page-turn/component.js" ] && [ -f "$p/components/chapter-bar/slots.json" ] \
     && [ ! -e "$p/components/page-turn/sample" ] && [ ! -e "$p/components/build-up/sample" ] && grep -q "OVH.grain" <<<"$a" && grep -q "build-up's three painter, in the Three.js layer" <<<"$a"
  then ok "components add: the library, the components named and what they import (page-turn for paper-transition), no samples; canvas-film is told how to load them, and a three painter how it goes with the Three.js layer; an unknown name is exit 2"
  else bad "components add ($rc, $rc2): $a | $b"; fi
  # a page of classic scripts, as canvas-film's: the library from components/lib/global.js as OVH, grain and paper drawn
  cat > "$p/classic.html" <<'HTML'
<!doctype html><html><head><meta name="viewport" content="width=640, height=360"><style>html,body{margin:0;background:#000}</style>
<script type="module" src="components/lib/global.js"></script></head>
<body><canvas id="c" width="640" height="360"></canvas><script>
const X = document.getElementById("c").getContext("2d");
window.film = { duration: 2,
  ready: () => (window.OVH ? OVH.setFrame({ w: 640, h: 360, fps: 30 }) : Promise.reject(new Error("no OVH: global.js did not load"))),
  frame(t) { X.reset(); OVH.paper(X, { tone: "#efe8da", seed: 3 }); OVH.grain(X, t, { amount: 0.3 }); X.fillStyle = "#c33"; X.fillRect(40 + 200 * t, 140, 80, 80); } };
</script></body></html>
HTML
  # and a page of modules: page-turn between two pictures, the chapter bar over it
  cat > "$p/modules.html" <<'HTML'
<!doctype html><html><head><meta name="viewport" content="width=640, height=360"><style>html,body{margin:0;background:#000}</style></head>
<body><canvas id="c" width="640" height="360"></canvas><script type="module">
import * as L from "./components/lib/index.js";
import * as turn from "./components/page-turn/component.js";
import * as bar from "./components/chapter-bar/component.js";
import * as build from "./components/build-up/component.js";
L.setFrame({ w: 640, h: 360, fps: 30 });
const X = document.getElementById("c").getContext("2d"), P = { chapters: [{ t: 0, title: "一" }, { t: 1, title: "二" }], end: 2, y: 30, margin: 40, pad: 20 };
const BU = { pieces: [0, 1, 2, 3].flatMap((f) => [[0, 0], [1, 0], [0, 1], [1, 1]].map(([i, k]) => ({ x: i, y: f + 0.5, z: k, w: 0.9, h: 0.9, d: 0.9 }))),
  bucket: 1, stagger: 0.4, jitter: 0.1, dur: 0.3 };
let lay;
window.film = { duration: 2,
  ready: async () => { await document.fonts.ready; lay = bar.layout(P, (s, z) => { X.font = `600 ${z}px sans-serif`; return X.measureText(s).width; }); },
  frame(t) {
    X.reset();
    const A = L.offscreen("a", (x) => { x.fillStyle = "#e8dcc4"; x.fillRect(0, 0, 640, 360); x.fillStyle = "#222"; x.fillRect(80, 120, 160, 120); });
    const B = L.offscreen("b", (x) => { x.fillStyle = "#243447"; x.fillRect(0, 0, 640, 360); x.fillStyle = "#eee"; x.fillRect(400, 120, 160, 120); });
    turn.canvas(X, turn.state({}, L.seg(t, 0.4, 1.6)), A, B);
    bar.canvas(X, bar.state(P, t, lay), P);
    build.canvas(X, build.state(BU, t), BU, { origin: [560, 330], scale: 16, edge: "#222" });   // a small tower a floor at a time, bottom right
  } };
</script></body></html>
HTML
  a=$(vh frames "$p/classic.html" --at 0.5 --out "$t/f" 2>&1); rc=$?
  case "$rc:$a" in 2:*"needs a headless Chrome"*) no_chrome "components on a page"; rm -rf "$t"; return ;; esac
  b=$(vh frames "$p/modules.html" --at 1.0 --out "$t/f" 2>&1); rc2=$?
  if [ "$rc:$rc2" = "0:0" ] && python3 - "$t/f/classic-t0000.500.png" "$t/f/modules-t0001.000.png" <<'PY'
import struct, sys, zlib
def rows(f):   # the PNG's pixel rows (8-bit RGB or RGBA, filter bytes kept; enough to tell a drawn frame from an empty one)
    d = open(f, "rb").read(); i = 8; idat = b""
    while i < len(d):
        n, kind = struct.unpack(">I4s", d[i:i + 8]); body = d[i + 8:i + 8 + n]; i += 12 + n
        if kind == b"IHDR": w, h = struct.unpack(">II", body[:8])
        if kind == b"IDAT": idat += body
    return w, h, zlib.decompress(idat)
for f in sys.argv[1:]:
    w, h, raw = rows(f)
    if (w, h) != (640, 360) or len(set(raw[::97])) < 8:   # a frame of one flat colour has a handful of byte values
        sys.exit(f"{f}: {w}x{h}, {len(set(raw[::97]))} values")
PY
  then
    a=$(vh determinism "$p/classic.html" --samples 3 2>&1); rc=$?
    b=$(vh determinism "$p/modules.html" --samples 3 2>&1); rc2=$?
    case "$rc:$rc2:$a:$b" in 0:0:*"determinism: holds"*:*"determinism: holds"*) ok "components on a page: a classic-script page (canvas-film's kind) draws OVH.paper and OVH.grain from global.js, a module page draws page-turn, the chapter bar and build-up's 2.5D blocks; both a function of t (bin/vh determinism)" ;;
      *) bad "components on a page, determinism ($rc, $rc2): $(printf '%s' "$a" | tail -c 400) | $(printf '%s' "$b" | tail -c 400)" ;; esac
  else bad "components on a page (frames $rc, $rc2): $(printf '%s' "$a" | tail -c 400) | $(printf '%s' "$b" | tail -c 400)"; fi
  # the other painters through the page contract too: a canvas page of paper-transition (the fold over the first second,
  # the blot over the second) under spring-scene's canvas painter, and a page of the DOM painters (spring-scene's, the bar's)
  vh components add "$p" spring-scene > /dev/null
  cat > "$p/paper.html" <<'HTML'
<!doctype html><html><head><meta name="viewport" content="width=640, height=360"><style>html,body{margin:0;background:#000}</style></head>
<body><canvas id="c" width="640" height="360"></canvas><script type="module">
import * as L from "./components/lib/index.js";
import * as paper from "./components/paper-transition/component.js";
import * as S from "./components/spring-scene/component.js";
L.setFrame({ w: 640, h: 360, fps: 30 });
const X = document.getElementById("c").getContext("2d");
const P = { ...S.defaults, center: [320, 180], layers: [{ id: "a", tin: 0.2, tout: 1.5 }], cursor: { keys: [[0, 0, 0], [1, 50, 20]], clicks: [0.9] } };
window.film = { duration: 2,
  frame(t) {
    X.reset();
    const A = L.offscreen("pa", (x) => { x.fillStyle = "#e8dcc4"; x.fillRect(0, 0, 640, 360); x.fillStyle = "#222"; x.fillRect(80, 120, 160, 120); });
    const B = L.offscreen("pb", (x) => { x.fillStyle = "#243447"; x.fillRect(0, 0, 640, 360); x.fillStyle = "#eee"; x.fillRect(400, 120, 160, 120); });
    const V = { variant: t < 1 ? "fold" : "blot" };   // the fold over the first second, the blot over the second
    paper.canvas(X, paper.state(V, t < 1 ? t : t - 1), A, B, V);
    S.canvas(X, S.state(P, t), P, (c) => { c.fillStyle = "#c33"; c.fillRect(-40, -20, 80, 40); });
  } };
</script></body></html>
HTML
  cat > "$p/dom.html" <<'HTML'
<!doctype html><html><head><meta name="viewport" content="width=640, height=360"><style>
html,body{margin:0;background:#101418;overflow:hidden} #world,#shape,#la,#cur,#bar{position:absolute;left:0;top:0}
#world{transform-origin:0 0} #la{font:600 28px sans-serif;color:#fff} #cur{width:12px;height:12px;border-radius:6px;background:#fc0}
</style></head>
<body><div id="world"><div id="shape"></div><div id="la">Layer</div></div><div id="cur"></div><div id="bar"></div>
<script type="module">
import * as L from "./components/lib/index.js";
import * as S from "./components/spring-scene/component.js";
import * as bar from "./components/chapter-bar/component.js";
L.setFrame({ w: 640, h: 360, fps: 30 });
const P = { ...S.defaults, center: [320, 180], layers: [{ id: "a", tin: 0.2, tout: 1.5 }], cursor: { keys: [[0, 0, 0], [1, 50, 20]], clicks: [0.9] } };
const els = { world: document.getElementById("world"), shape: document.getElementById("shape"), layers: { a: document.getElementById("la") }, cursor: document.getElementById("cur") };
const BP = { chapters: [{ t: 0, title: "一" }, { t: 1, title: "二" }], end: 2, y: 30, margin: 40, pad: 20 };
let bels, blay;
window.film = { duration: 2,
  ready: async () => { await document.fonts.ready; const M = document.createElement("canvas").getContext("2d");
    blay = bar.layout(BP, (s, z) => { M.font = `600 ${z}px sans-serif`; return M.measureText(s).width; }); bels = bar.build(document.getElementById("bar"), BP, blay); },
  frame(t) { S.dom(els, S.state(P, t), P); bar.dom(bels, bar.state(BP, t, blay)); } };
</script></body></html>
HTML
  a=$(vh determinism "$p/paper.html" --samples 3 2>&1); rc=$?
  b=$(vh determinism "$p/dom.html" --samples 3 2>&1); rc2=$?
  case "$rc:$rc2:$a:$b" in 0:0:*"determinism: holds"*:*"determinism: holds"*) ok "components on a page: paper-transition's fold and blot, spring-scene's canvas and DOM painters and the chapter bar's DOM painter are each a function of t (bin/vh determinism)" ;;
    *) bad "components' other painters, determinism ($rc, $rc2): $(printf '%s' "$a" | tail -c 400) | $(printf '%s' "$b" | tail -c 400)" ;; esac
  rm -rf "$t"
}

px_are() { # px_are <png> <python condition> x,y …: true when the condition holds over P (the points' (r, g, b), in order), w and
  # h, with near(p, q) (each channel within 3); else it says what it saw. An 8-bit PNG as Chrome writes one: no ffmpeg needed
  python3 - "$@" <<'PY'
import struct, sys, zlib
f, cond, pts = sys.argv[1], sys.argv[2], sys.argv[3:]
d = open(f, "rb").read(); i = 8; idat = b""
while i < len(d):
    n, kind = struct.unpack(">I4s", d[i:i + 8]); body = d[i + 8:i + 8 + n]; i += 12 + n
    if kind == b"IHDR": w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
    if kind == b"IDAT": idat += body
bpp = {2: 3, 6: 4}[ctype]; raw = zlib.decompress(idat); stride = w * bpp; rows, prev = [], bytearray(stride)
for y in range(h):   # undo the PNG filters (8-bit, not interlaced)
    flt, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
    for x in range(stride):
        a = line[x - bpp] if x >= bpp else 0; b = prev[x]; c = prev[x - bpp] if x >= bpp else 0
        p = a + b - c; pr = a if abs(p - a) <= abs(p - b) and abs(p - a) <= abs(p - c) else b if abs(p - b) <= abs(p - c) else c
        line[x] = (line[x] + (0, a, b, (a + b) // 2, pr)[flt]) & 255
    rows.append(line); prev = line
P = [tuple(rows[y][x * bpp:x * bpp + 3]) for x, y in (map(int, q.split(",")) for q in pts)]
near = lambda p, q: all(abs(u - v) <= 3 for u, v in zip(p, q))   # noqa: E731
sys.exit(0 if eval(cond, {"P": P, "w": w, "h": h, "near": near}) else f"{f}: {w}x{h}, at {pts}: {P}")
PY
}

model3d_checks() {   # bin/vh model3d check (tools/model3d) on a model written on the spot (tools/model3d/fixture.py: a column of two
  # cubes on two bones, a 4x4 texture, the clips bend 1 s and lift 2 s; nothing downloaded), and canvas-film's Three.js
  # layer drawing the same model through the page contract in software WebGL (--soft-gl, as a machine without a GPU does)
  local t p a b c d rc rc2 rc3 rc4
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  python3 tools/model3d/fixture.py "$t/box.glb" && python3 tools/model3d/fixture.py "$t/big.glb" --scale 100
  a=$(vh model3d check "$t/box.glb" --json 2>/dev/null); rc=$?
  b=$(vh model3d check "$t/box.glb" --tier prop --max-faces 10 --max-texture 2 --json 2>/dev/null); rc2=$?
  c=$(vh model3d check "$t/big.glb" 2>&1); rc3=$?
  if [ "$rc:$rc2:$rc3" = "0:1:0" ] && python3 - "$a" "$b" "$c" <<'PY'
import json, sys
a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2]); c = sys.argv[3]; bad = []
k = a["counts"]
if (k["triangles"], k["vertices"], k["meshes"], k["materials"], k["skins"], k["joints"], k["animations"]) != (20, 32, 1, 1, 1, 2, 2): bad.append(f"counts {k}")
if [(x["format"], x["width"], x["height"], x["where"], x["used_by"]) for x in a["textures"]] != [("png", 4, 4, "embedded", ["Paint.baseColor"])]: bad.append(f"textures {a['textures']}")
if [(x["name"], x["duration"]) for x in a["animations"]] != [("bend", 1.0), ("lift", 2.0)]: bad.append(f"clips {a['animations']}")
if a["skins"][0]["joint_names"] != ["Root", "Tip"]: bad.append(f"skins {a['skins']}")
if a["bbox"]["size"] != [0.5, 2.0, 0.5] or a["origin"] != "base centre" or a["tallest"] != "y" or a["verdict"] != "pass" or a["tier"] != "hero": bad.append(f"box {a['bbox']} {a['origin']} {a['tallest']}")
if sorted(f["kind"] for f in b["findings"] if f["severity"] == "fail") != ["model3d.faces", "model3d.texture"] or b["limits"] != {"faces": 10, "texture": 2} or b["exit"] != 1: bad.append(f"over the limits: {b['findings']}")
if "200.00 m across" not in c or "glTF is metres" not in c: bad.append(f"a model 100 times its size: {c[-300:]}")
sys.exit("\n".join(bad) if bad else 0)
PY
  then ok "model3d check: the test model's triangles, vertices, texture (size, format, use), joints, clips and lengths, box in metres, origin and up; --tier prop with --max-faces and --max-texture fails it (exit 1); 100 times its size is said"
  else bad "model3d check ($rc, $rc2, $rc3): $(printf '%s' "$a" | tail -c 300) | $(printf '%s' "$b" | tail -c 300) | $(printf '%s' "$c" | tail -c 300)"; fi
  # what the Three.js layer cannot load fails (Draco required, an image not beside a .gltf); two clips of one name warn; a
  # file that is no glTF is a failed check (1), a usage error 2 (no file, a bad tier, gen: not here yet)
  python3 - "$t" <<'PY'
import base64, json, sys
sys.path.insert(0, "tools/model3d")
import fixture, glb
t = sys.argv[1]
g, blob = fixture.build()
g["extensionsUsed"] = g["extensionsRequired"] = ["KHR_draco_mesh_compression"]
g["animations"][1]["name"] = "bend"
glb.write_glb(f"{t}/draco.glb", g, blob)
g, blob = fixture.build()
g["buffers"] = [{"byteLength": len(blob), "uri": "data:application/octet-stream;base64," + base64.b64encode(blob).decode()}]
g["images"] = [{"uri": "textures/checker.png"}]
open(f"{t}/lost.gltf", "w").write(json.dumps(g))
open(f"{t}/not.glb", "w").write("hello")
PY
  a=$(vh model3d check "$t/draco.glb" 2>&1); rc=$?
  b=$(vh model3d check "$t/lost.gltf" 2>&1); rc2=$?
  c=$(vh model3d check "$t/not.glb" 2>&1); rc3=$?
  d=$(vh model3d check "$t/none.glb" 2>&1; vh model3d check "$t/box.glb" --tier huge 2>&1; vh model3d gen x 2>&1); rc4=$?
  case "$rc:$rc2:$rc3:$a|$b|$c|$d" in 1:1:1:*"needs KHR_draco_mesh_compression, and the Three.js layer has no DRACOLoader"*"2 clips are named bend"*"|"*"textures/checker.png is not beside the model"*"|"*"not a glTF 2.0 model"*"|"*"no such file"*"--tier: hero or prop"*"comes later"*)
      [ "$rc4" = 2 ] && ok "model3d check: a model the layer cannot decode or load fails, two clips of one name warn, a file that is no glTF fails (1), usage errors 2" \
        || bad "model3d check usage errors: exit $rc4: $d" ;;
    *) bad "model3d check on broken models ($rc, $rc2, $rc3): $a | $b | $c | $d" ;; esac
  # a part that points outside the file, or is not the kind glTF says, fails with the part named, and --json prints the
  # report all the same (no traceback): a node that is a number, a bufferView past its buffer, an accessor of type VEC9,
  # one of 10^12 zeros (no list of them is made), a node its own child, sparse indices past the count, a skinned
  # primitive without JOINTS_0 (three turns its skinning off); weights past a vertex's first four warn (three drops
  # them); Draco listed only as used fails (three's loader stops at it); bytes after the GLB header's length warn
  if python3 - "$VH_BASH|$ROOT/bin/vh" "$t" <<'PY'
import json, struct, subprocess, sys
sys.path.insert(0, "tools/model3d")
import fixture, glb
vh, t = sys.argv[1].split("|"), sys.argv[2]
def zeros(g, b):
    g["accessors"].append({"componentType": 5126, "type": "SCALAR", "count": 10**12})
    g["animations"][0]["samplers"][0]["input"] = len(g["accessors"]) - 1
def sparse(g, b):   # its indices read from the positions' floats: far past the 32 there are
    a = g["accessors"][0]; a.pop("min"); a.pop("max")
    a["sparse"] = {"count": 3, "indices": {"bufferView": 0, "componentType": 5125}, "values": {"bufferView": 0}}
def five(g, b):   # JOINTS_1 / WEIGHTS_1: every vertex a fifth bone, weight 0.2
    n, b = 32, bytearray(b) + bytes(-len(b) % 4)
    for data, comp, typ in ((bytes([1, 0, 0, 0]) * n, 5121, "VEC4"), (struct.pack("<4f", 0.2, 0, 0, 0) * n, 5126, "VEC4")):
        g["bufferViews"].append({"buffer": 0, "byteOffset": len(b), "byteLength": len(data)}); b += data
        g["accessors"].append({"bufferView": len(g["bufferViews"]) - 1, "componentType": comp, "count": n, "type": typ})
    at = g["meshes"][0]["primitives"][0]["attributes"]; at["JOINTS_1"], at["WEIGHTS_1"] = len(g["accessors"]) - 2, len(g["accessors"]) - 1
    g["buffers"][0]["byteLength"] = len(b)
    return bytes(b)
cases = {   # name: (what is broken, the exit, words of the finding)
    "node": (lambda g, b: g["nodes"].__setitem__(0, 5), 1, "nodes[0] is a number, not an object"),
    "loop": (lambda g, b: g["nodes"][3].update(children=[3]), 1, "nodes 3 (Rig) → 3 (Rig): each the child of the one before, a loop"),
    "sparse": (sparse, 1, "is past its 32 elements"),
    "view": (lambda g, b: g["bufferViews"][0].update(byteLength=10**9), 1, "bytes past the end of buffers[0]"),
    "vec9": (lambda g, b: g["accessors"][0].update(type="VEC9"), 1, 'type "VEC9": glTF'),
    "zeros": (zeros, 1, "1,000,000,000,000 elements and no bufferView"),
    "noskin": (lambda g, b: g["meshes"][0]["primitives"][0]["attributes"].pop("JOINTS_0"), 1, "have no JOINTS_0 and WEIGHTS_0: three turns skinning off"),
    "five": (five, 0, "32 of 32 vertices weighted to more than four bones (JOINTS_1 and on): three reads the first four"),
    "used": (lambda g, b: g.update(extensionsUsed=["KHR_draco_mesh_compression"]), 1, "lists KHR_draco_mesh_compression as used"),
    "tail": (lambda g, b: None, 0, "7 bytes after the")}
bad = []
for name, (change, want, words) in cases.items():
    g, blob = fixture.build(); out = change(g, blob); blob = out if isinstance(out, bytes) else blob   # a change that adds data gives the new blob
    glb.write_glb(f"{t}/{name}.glb", g, blob)
    if name == "tail":
        open(f"{t}/tail.glb", "ab").write(b"\0" * 7)
    r = subprocess.run([*vh, "model3d", "check", f"{t}/{name}.glb", "--json"], capture_output=True, text=True, timeout=60)
    try:
        rep = json.loads(r.stdout)
    except ValueError:
        rep = {}
    said = " | ".join(f["message"] for f in rep.get("findings", []))
    if r.returncode != want or rep.get("exit") != want or words not in said or "Traceback" in r.stderr:
        bad.append(f"{name}: exit {r.returncode} (want {want}): {said[:200] or r.stderr[-200:]}")
sys.exit("\n".join(bad) if bad else 0)
PY
  then ok "model3d check: a part that points outside the file or is not glTF's (a node that is a number, a bufferView past its buffer, type VEC9, 10^12 zeros, a node its own child, sparse indices past the count) fails naming it, the --json report all the same; a skinned primitive without JOINTS_0 fails, weights past four bones warn; Draco listed only as used fails; bytes after the GLB's length warn"
  else bad "model3d check on models whose parts point outside them"; fi
  # --blender (tools/model3d/blender_qa.py in Blender; CI has none): without one it is skipped and said, and the rest of
  # the check stands; a stand-in that writes the report Blender would gives its findings (z-fighting and inward faces
  # fail, faces back to back warn) and shows it gets none of our environment. The weights are read without Blender
  # (fixture.py --faulty): a vertex whose weights are all 0 fails (three ties it to one bone), weights that do not sum to
  # 1 warn (three scales them to 1)
  python3 tools/model3d/fixture.py "$t/faulty.glb" --faulty
  cat > "$t/blender" <<'SH'
#!/bin/sh
# a stand-in for Blender: the report tools/model3d/blender_qa.py would write, to its last argument
for a; do out=$a; done
printf '{"version": 1, "blender": "0 (stand-in)", %s"meshes": 2, "triangles": 34, "zfighting": [{"where": "Column", "tri_pairs": 2}], "back_to_back": [{"where": "Column", "tri_pairs": 1}], "inside_out": [{"object": "Inverted", "parts": 1}], "winding": [], "not_checked": ["home %s"]}\n' \
  "${OVH_CI_LEAK:+\"error\": \"OVH_CI_LEAK reached it\", }" "$HOME" > "$out"
SH
  chmod +x "$t/blender"
  a=$(BLENDER="$t/none" vh model3d check "$t/box.glb" --blender 2>&1); rc=$?
  b=$(OVH_CI_LEAK=1 BLENDER="$t/blender" vh model3d check "$t/faulty.glb" --blender --json 2>/dev/null); rc2=$?
  c=$(vh model3d check "$t/faulty.glb" --json 2>/dev/null); rc3=$?
  if [ "$rc:$rc2:$rc3" = "0:1:1" ] && python3 - "$a" "$b" "$c" <<'PY'
import json, sys
a, b, c = sys.argv[1], json.loads(sys.argv[2]), json.loads(sys.argv[3]); bad = []
if "--blender checks did not run: BLENDER is" not in a or "within hero" not in a: bad.append(f"no Blender: {a[-300:]}")
kinds = sorted((f["kind"], f["severity"]) for f in b["findings"] if f["kind"] in ("model3d.zfighting", "model3d.normals", "model3d.hidden", "model3d.blender"))
if kinds != [("model3d.blender", "info"), ("model3d.hidden", "warn"), ("model3d.normals", "fail"), ("model3d.zfighting", "fail")]: bad.append(f"the stand-in's findings: {kinds}")
home = next((f["message"] for f in b["findings"] if f["message"].startswith("not checked: home ")), "")
if "/vh-model3d-" not in home or b["blender"].get("error"): bad.append(f"Blender's environment: {home} {b['blender'].get('error')}")
w = (c["meshes"][0].get("weights") or [{}])[0]
sums = [f for f in c["findings"] if "do not sum to 1" in f["message"]]
if (w.get("verts"), w.get("unweighted"), w.get("not_one")) != (36, 1, 8) or {f["kind"] for f in c["findings"] if f["severity"] == "fail"} != {"model3d.weights"} \
   or [f["severity"] for f in sums] != ["warn"]: bad.append(f"weights {w} {c['findings']}")
sys.exit("\n".join(bad) if bad else 0)
PY
  then ok "model3d check --blender: skipped and said without Blender, the rest standing; a stand-in's report becomes findings (z-fighting and inward faces fail, back to back warns) and gets none of our environment; weights read from the file (all 0 fails, a sum not 1 warns)"
  else bad "model3d check --blender ($rc, $rc2, $rc3): $(printf '%s' "$a" | tail -c 300) | $(printf '%s' "$b" | tail -c 300)"; fi
  # macOS: the sandbox Blender runs in, tried by a stand-in from inside it: writing beside itself (outside its scratch
  # folder) and connecting to a port on this machine are both refused (no network leaves either way)
  if [ "$(uname -s)" = Darwin ]; then
    cat > "$t/probe" <<'SH'
#!/bin/sh
# a stand-in for Blender that tries the sandbox's walls, and reports what it found where blender_qa.py's report goes
for a; do out=$a; done
here=$(dirname "$0")
if (echo x > "$here/outside.txt") 2>/dev/null; then w=written; else w=refused; fi
if nc -z -w 2 127.0.0.1 "$(cat "$here/port" 2>/dev/null)" >/dev/null 2>&1; then c=connected; else c=refused; fi
printf '{"version": 1, "blender": "0 (probe)", "meshes": 1, "triangles": 20, "zfighting": [], "back_to_back": [], "inside_out": [], "winding": [], "not_checked": ["write beside it: %s", "connect to this machine: %s"]}\n' "$w" "$c" > "$out"
SH
    chmod +x "$t/probe"
    python3 -c 'import socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1); s.settimeout(30)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
try: s.accept()
except OSError: pass' "$t/port" & lp=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$t/port" ] && break; sleep 0.2; done
    a=$(BLENDER="$t/probe" vh model3d check "$t/box.glb" --blender 2>&1); rc=$?
    kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
    case "$rc:$a" in 0:*"write beside it: refused"*"connect to this machine: refused"*)
        [ ! -e "$t/outside.txt" ] && ok "model3d check --blender on macOS: inside its sandbox a stand-in can neither write outside its scratch folder nor connect to a port on this machine" \
          || bad "the --blender sandbox let a file be written: $t/outside.txt" ;;
      *) bad "the --blender sandbox ($rc): $(printf '%s' "$a" | tail -c 400)" ;; esac
  fi
  # three.js as the npm package has it: each file the layer carries, byte for byte as its NOTICE lists it
  if python3 - <<'PY'
import hashlib, pathlib, re, sys
d = pathlib.Path("engines/canvas-film/three")
rows = re.findall(r"^\| `([^`]+)` \| `[^`]+` \| `([0-9a-f]{64})` \|$", (d / "NOTICE.md").read_text(encoding="utf-8"), re.M)
have = sorted(p.relative_to(d).as_posix() for p in d.rglob("*") if p.is_file() and p.parts[len(d.parts)] in ("build", "addons"))
bad = [f for f, h in rows if hashlib.sha256((d / f).read_bytes()).hexdigest() != h] if rows else ["no rows"]
bad += [f"{f}: not in NOTICE.md" for f in have if f not in dict(rows)]
sys.exit(" ".join(bad) if bad else 0)
PY
  then ok "three.js in engines/canvas-film/three: every file in build/ and addons/ is the package's, as NOTICE.md lists it (sha256)"
  else bad "engines/canvas-film/three: files and NOTICE.md's sha256 differ"; fi
  # new --three: the layer and three.js in the project (not without --engine canvas-film); doctor holds three/ to the engine's
  a=$(vh new short tri --engine canvas-film --three --dir "$t" 2>&1); rc=$?
  vh new short tri2 --three --dir "$t" >/dev/null 2>&1; rc2=$?
  p=$(ls -d "$t"/*-tri 2>/dev/null)
  if [ "$rc:$rc2" = "0:2" ] && [ -n "$p" ] && [ -f "$p/three/layer.js" ] && [ -f "$p/three/build/three.core.js" ] && [ -f "$p/three/LICENSES/MIT-three.js.txt" ] \
     && [ -f "$p/src/07-three.js" ] && [ -z "$(ls -d "$t"/*-tri2 2>/dev/null)" ]; then
    b=$(vh doctor "$p" 2>&1); rc=$?; printf '// a tweak\n' >> "$p/three/layer.js"; c=$(vh doctor "$p" 2>&1); rc2=$?
    case "$rc:$rc2:$b|$c" in 0:1:*"the copy is the engine as it is now"*"|"*"changed (1): three/layer.js"*) ok "new --three copies the Three.js layer and three.js into the project (not without --engine canvas-film); doctor <project> holds three/ to the engine's" ;;
      *) bad "doctor on a --three project ($rc, $rc2): $b | $c" ;; esac
    cp "$ROOT/engines/canvas-film/three/layer.js" "$p/three/layer.js"
  else bad "new --three ($rc, $rc2): $a"; p=""; fi
  # the layer on a page: the model through it in software WebGL, under the 2D. The test film (fixture.py --film) holds the
  # camera while the column bends in a loop, so t = 0.25 and 1.25 (both 0.25 s into the clip, mixer.setTime) are one
  # picture and t = 0.5 another; S01's pose moves the column off the middle from 0.4 s to 1 s: at 0.5 it is off, at 0.25
  # (after ready's recorder posed it) and 1.25 (after 0.5) it is back, as the world is put back each frame; any order,
  # another browser (bin/vh determinism, ≥ 45 dB for WebGL, hard rule 1); the shot's white square lies over the 3D's
  # opaque background
  [ -n "$p" ] || { rm -rf "$t"; return; }
  python3 tools/model3d/fixture.py --film "$p"
  a=$(vh determinism "$p" --at 0.25,0.5,1.25,2.5 --soft-gl --min-psnr 45 --out "$t/d" 2>&1); rc=$?
  case "$rc:$a" in 2:*"needs a headless Chrome"*) no_chrome "the Three.js layer on a page"; rm -rf "$t"; return ;; esac
  case "$rc:$a" in *"no WebGL2 for the Three.js layer"*) no_webgl "the Three.js layer on a page"; rm -rf "$t"; return ;; esac
  if [ $rc = 0 ] && printf '%s' "$a" | grep -q "determinism: holds" && cmp -s "$t/d/A-t0000.250.png" "$t/d/A-t0001.250.png" \
     && ! cmp -s "$t/d/A-t0000.250.png" "$t/d/A-t0000.500.png" && ! cmp -s "$t/d/A-t0000.500.png" "$t/d/A-t0002.500.png" \
     && px_are "$t/d/A-t0000.250.png" '(w, h) == (160, 90) and P[0] == (255, 255, 255) and near(P[1], (0x20, 0x30, 0x40)) and not near(P[2], (0x20, 0x30, 0x40))' 8,8 150,80 80,45 \
     && px_are "$t/d/A-t0000.500.png" 'near(P[0], (0x20, 0x30, 0x40)) and not near(P[1], (0x20, 0x30, 0x40))' 80,45 95,45
  then ok "the Three.js layer: a GLB's clip set to the film's time (0.25 s into a loop at t 0.25 and 1.25: one picture), a pose put back after its frame, the camera's moves, in any order and another browser (determinism, --soft-gl); the shot's 2D over the 3D"
  else bad "the Three.js layer on a page (exit $rc): $(printf '%s' "$a" | tail -c 600)"; fi
  # ready names every problem of a shot's three at once: a clip the model lacks, one played once that stops before its
  # shot does, a model that is not there, a key the layer does not read, an ease that is no name of its table (and not
  # "constructor" as a model or an ease: every object has one); FILM.three without three/ says how to get it
  printf '%s\n' 'Object.assign(FILM, { width: 160, height: 90, timeline: false, duration: 3, grain: 0, fadeOut: 0, images: {},' \
    '  three: { models: { box: "assets/models/box.glb" } } });' \
    'const SHOTS = [{ id: "S01", at: 0, three: { play: { box: "bend" }, show: ["box", "crate", "constructor"] }, draw() {} },' \
    '  { id: "S02", at: 1.5, three: { play: { box: "wave" }, spin: 1, cam: { from: { pos: [0, 1, 4] }, to: { pos: [1, 1, 4] }, ease: "constructor" } }, draw() {} }];' > "$p/src/50-shots.js"
  a=$(vh frames "$p" --at 1 --soft-gl --out "$t/f" 2>&1); rc=$?
  rm -rf "$p/three"
  b=$(vh frames "$p" --at 1 --soft-gl --out "$t/f" 2>&1); rc2=$?
  case "$rc:$rc2:$a|$b" in 2:2:*'no model "crate"'*'"bend" is 1.00 s; played once from 0.00 s'*"has spin, which the layer does not read"*'has no clip "wave" (its clips: bend, lift'*"|"*"three/layer.js did not load"*"--engine canvas-film --three"*)
      if grep -q -F '.ease: linear, sine, inOut, in, out, not "constructor"' <<<"$a" && grep -q -F 'no model "constructor"' <<<"$a"
      then ok "the Three.js layer's ready: a missing clip, a clip that stops before its shot, an unknown model, key and ease (\"constructor\" as a model and an ease too), all at once (exit 2); FILM.three without three/ says how to get it"
      else bad "the Three.js layer's ready took \"constructor\" for a model or an ease: $(printf '%s' "$a" | tail -c 500)"; fi ;;
    *) bad "the Three.js layer's ready ($rc, $rc2): $a | $b" ;; esac
  rm -rf "$t"
}

hdri_checks() {   # bin/vh hdri (tools/assets/hdri.py) on Poly Haven's answers recorded in their shape (tools/assets/fixtures/hdri:
  # the lists trimmed, the files synthetic, a 128 x 64 test sky), no network; then build-up's three painter under that sky
  # in the Three.js layer (components/build-up/sample/three-film.js at 160 x 90, software WebGL)
  local t p a b c d e rc rc2 rc3 rc4 fx=tools/assets/fixtures/hdri
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  vh new short tw --engine canvas-film --three --dir "$t" >/dev/null 2>&1; p=$(ls -d "$t"/*-tw 2>/dev/null)
  [ -n "$p" ] || { bad "hdri: no project to get into (bin/vh new … --three)"; rm -rf "$t"; return; }
  a=$(vh hdri search sky --category outdoor --json --offline "$fx" 2>/dev/null); rc=$?
  b=$(vh hdri get "$p" studio_small_09 --json --offline "$fx" 2>/dev/null); rc2=$?
  c=$(vh hdri get "$p" studio_small_09 --offline "$fx" 2>&1; vh hdri get "$p" studio_small_09 --format exr --offline "$fx" 2>&1); rc3=$?
  d=$(vh hdri get "$p" sunflowers_puresky --res 1k --offline "$fx" 2>&1); rc4=$?
  e=$(for x in "get $p rock_wall_08" "get $p no_such_hdri" "get $p studio_small_09 --res 8k" "nope"; do
        # shellcheck disable=SC2086   # each line is the arguments, split on purpose
        vh hdri $x --offline "$fx" 2>&1; echo "exit $?"; done; vh hdri search sky --offline "$t/none" 2>&1; echo "exit $?")
  if [ "$rc:$rc2:$rc3:$rc4" = "0:0:0:1" ] && python3 - "$p" "$a" "$b" "$c" "$d" "$e" <<'PY'
import hashlib, json, sys
sys.path.insert(0, "tools/assets")
import ledger
p, a, b, c, d, e = sys.argv[1:]; a, b = json.loads(a), json.loads(b); bad = []
if [r["id"] for r in a["results"]] != ["kloofendal_48d_partly_cloudy_puresky", "sunflowers_puresky"] or a["results"][0]["max_resolution"] != "16k":
    bad.append(f"search: {[r['id'] for r in a['results']]}")
r, path = b["record"], "assets/hdri/studio_small_09/studio_small_09_2k.hdr"
if (r["id"], r["path"], r["license"]["class"], r["source"]["provider"], r["source"]["url"], r["source"]["author"], b["env"]) != \
   ("hdri-studio_small_09-2k", path, "cc0", "polyhaven", "https://polyhaven.com/a/studio_small_09", "Sergej Majboroda", path):
    bad.append(f"get's record: {r}")
if ledger.validate(r) or r["sha256"] != hashlib.sha256(open(f"{p}/{path}", "rb").read()).hexdigest(): bad.append(f"the record: {ledger.validate(r)}")
if "is here already" not in c or "got hdri-studio_small_09-2k-exr" not in c: bad.append(f"again, and an exr: {c[-300:]}")
recs = json.load(open(f"{p}/assets/ledger.json"))["assets"]
if sorted(x["id"] for x in recs) != ["hdri-studio_small_09-2k", "hdri-studio_small_09-2k-exr"]: bad.append(f"the ledger: {[x['id'] for x in recs]}")
import os
if "its md5 is not the one Poly Haven lists" not in d or os.path.exists(f"{p}/assets/hdri/sunflowers_puresky"): bad.append(f"a wrong md5: {d[-300:]}")
for want in ("is not an HDRI on Poly Haven", "Poly Haven has no no_such_hdri", "comes in 1k, 2k, 4k, not 8k", "no subcommand 'nope'", "no such folder"):
    if want not in e: bad.append(f"usage: no {want!r} in {e[-400:]}")
if e.count("exit 2") != 5: bad.append(f"usage errors are 2: {e[-300:]}")
sys.exit("\n".join(bad) if bad else 0)
PY
  then ok "hdri: Poly Haven's HDRIs by words and category, most downloaded first; get puts one in assets/hdri/<id>/ under Poly Haven's name, md5 checked, on record (CC0, page, authors, sha256: a valid record) with FILM.three.env's line; the same again is left as it is, an EXR beside it; a wrong md5 is deleted (1); a texture, an unknown id or size, an unknown subcommand: 2"
  else bad "hdri ($rc, $rc2, $rc3, $rc4): $(printf '%s' "$c$d" | tail -c 400)"; fi
  # build-up in the Three.js layer: the tower a floor at a time under the test sky (env and background from the HDRI just
  # got, the light from a copy of it 64 px across: the layer's box filter on the GPU), the pieces an InstancedMesh the
  # component's three painter sets each frame; a second shot puts the sun out in its pose, and the sky alone lights the
  # tower; any order, another browser
  vh components add "$p" build-up >/dev/null && cp components/build-up/sample/three-film.js "$p/src/50-shots.js" \
    && printf '%s\n' 'Object.assign(FILM, { width: 160, height: 90, duration: 8 });' 'FILM.three.envLight = 64;' \
      'SHOTS.push({ id: "S02", at: 6, three: { pose(t, s, W3) { BUILD.three(MESH, BUILD.state(TOWER, 99), TOWER, THREE); W3.scene.getObjectByName("light0").intensity = 0; } }, draw() {} });' \
      >> "$p/src/50-shots.js"
  a=$(vh determinism "$p" --at 0.2,2.5,5.9,7 --soft-gl --out "$t/d" 2>&1); rc=$?
  case "$rc:$a" in 2:*"needs a headless Chrome"*) no_chrome "build-up in the Three.js layer"; rm -rf "$t"; return ;; esac
  case "$rc:$a" in *"no WebGL2 for the Three.js layer"*) no_webgl "build-up in the Three.js layer"; rm -rf "$t"; return ;; esac
  if [ $rc = 0 ] && printf '%s' "$a" | grep -q "determinism: holds" && ! cmp -s "$t/d/A-t0000.200.png" "$t/d/A-t0002.500.png" \
     && px_are "$t/d/A-t0000.200.png" 'P[0][2] > P[0][0] + 8 and not P[1][0] > P[1][2] + 40' 80,3 80,45 \
     && px_are "$t/d/A-t0005.900.png" 'P[0][0] > P[0][2] + 40' 80,45 \
     && px_are "$t/d/A-t0007.000.png" 'max(P[0]) > 24' 80,45
  then ok "build-up in the Three.js layer: a tower a floor at a time (its three painter on an InstancedMesh, set from t) under an HDRI that lights it (the sun out, it still does) and shows behind it, the light from a smaller copy, the same in any order and another browser (determinism, --soft-gl)"
  else bad "build-up in the Three.js layer (exit $rc): $(printf '%s' "$a" | tail -c 600)"; fi
  # an EXR (fixture.py's, a real OpenEXR of the same sky) through EXRLoader, shown sharp behind a box that nothing lights:
  # no lights and envIntensity 0 leave it black; one page, one frame
  cp -R "$p" "$t/exr" && printf '%s\n' 'Object.assign(FILM, { width: 160, height: 90, timeline: false, duration: 2, grain: 0, fadeOut: 0, images: {},' \
    '  three: { env: "assets/hdri/studio_small_09/studio_small_09_2k.exr", envIntensity: 0, lights: [], background: "env", camera: { pos: [0, 1.5, 6], at: [0, 2.5, 0], fov: 50 },' \
    '    build({ THREE, scene }) { const m = new THREE.Mesh(new THREE.BoxGeometry(2, 2, 2), new THREE.MeshStandardMaterial({ color: "#ffffff" })); m.position.y = 2.5; scene.add(m); } } });' \
    'const SHOTS = [{ id: "S01", at: 0, three: {}, draw() {} }];' > "$t/exr/src/50-shots.js"
  a=$(vh frames "$t/exr" --at 1 --soft-gl --out "$t/fx" 2>&1); rc=$?
  # a machine without the template's CJK faces (the Linux runner) draws in a fallback and says so, which is exit 1; that
  # alone is fine here (no text on this page), as in the canvas-film template's frames
  if [ $rc = 1 ] && printf '%s' "$a" | grep -q 'fonts this machine does not have' \
    && ! printf '%s\n' "$a" | grep -E 'while loading:|^  t=[0-9.]+ s:|just after the last frame' | grep -qv 'fonts this machine does not have'; then rc=0; fi
  if [ $rc = 0 ] && px_are "$t/fx/film-t0001.000.png" 'max(P[0]) <= 12 and P[1][2] > P[1][0] + 8 and P[2][0] > P[2][2] + 8' 80,45 80,3 80,88
  then ok "the Three.js layer: an EXR read and shown sharp behind (its sky above, its ground below); no lights and envIntensity 0 leave the box black"
  else bad "an EXR in the Three.js layer (exit $rc): $(printf '%s' "$a" | tail -c 600)"; fi
  rm -rf "$t"
}

status_checks() {
  local t p q a b c d e k rc rc2
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  OVH_PROJECTS="$t" vh new math st >/dev/null 2>&1; p=$(ls -d "$t"/*-st)
  cat > "$t/st.py" <<'PY'
import json, subprocess, sys
vh, p, want = sys.argv[1:4]
d = json.loads(subprocess.run([*vh.split("|"), "status", p, "--json"], capture_output=True, text=True).stdout)
got = " ".join(f"{s['id']}:{s['state']}" for s in d["stations"]) + f" | {d['waiting_on']}"
print(got if got == want else f"{got}  (want {want})")
for k in sys.argv[4:]:   # extra checks: a python expression over d
    if not eval(k, {"d": d}):
        print(f"not: {k}")
PY
  st() { python3 "$t/st.py" "$VH_BASH|$ROOT/bin/vh" "$@"; }
  a=$(st "$p" "1:in_progress 2:not_started 3:not_started deliver:not_started | agent" 'd["version"] == 1 and d["project"]["effort"] == "standard" and d["project"]["type"] == "01-math-science-explainer"' \
    'd["review"]["current"] is None and d["renders"] == [] and d["check"] is None and d["open"] == {"review_items": [], "facts_to_verify": []}')
  b=$(vh status "$p"); rc=$?
  [ "$a" = "1:in_progress 2:not_started 3:not_started deliver:not_started | agent" ] && [ $rc = 0 ] && [ "$(printf '%s\n' "$b" | wc -l | tr -d ' ')" -le 8 ] \
    && ok "status: a new standard project works towards gate ①, the rest not started (--json version 1; a short human view)" || bad "status of a new project (rc $rc): $a | $b"
  # a page out (the page channel): waiting for the person; a desk submission: waiting for the agent, until handed over and recorded
  mkdir -p "$p/out/review" && cp tools/desk/fixtures/zh/out/review/gate-1.json "$p/out/review/" && vh gate "$p" 1 --page >/dev/null 2>&1
  a=$(st "$p" "1:waiting_person 2:not_started 3:not_started deliver:not_started | person" 'd["stations"][0]["page"] == "out/review/gate-1.html" and d["review"]["current"] == "1"')
  python3 - "$p" <<'PY'
import sys
sys.path.insert(0, "tools/desk")
import feedback
p = sys.argv[1]
feedback.save(p, feedback.validate(p, {"round": "1", "lang": "zh", "decisions": {"look": "L2"},
                                       "items": [{"target": "range:3-4.5", "status": "change", "text": "这里太快"}, {"target": "card:B", "status": "ok"}]}))
PY
  b=$(st "$p" "1:waiting_agent 2:not_started 3:not_started deliver:not_started | agent" 'd["stations"][0]["feedback"]["pending"] == 1' \
    '[(i["target"], i["label"]) for i in d["open"]["review_items"]] == [("range:3-4.5", "片段 0:03.0–0:04.5")]')
  vh desk feedback "$p" >/dev/null
  c=$(st "$p" "1:waiting_agent 2:not_started 3:not_started deliver:not_started | agent" 'd["stations"][0]["feedback"]["handed"] == 1' 'len(d["open"]["review_items"]) == 1')
  python3 -c 'import sys; f = sys.argv[1] + "/REVIEW.md"; s = open(f, encoding="utf-8").read(); i = s.index("## 审阅台反馈"); open(f, "w", encoding="utf-8").write(s[:i] + s[i:].replace("- 定了：　改了：", "- 定了：L2，开头放慢　改了：0:03–0:04.5", 1))' "$p"   # under the desk's section
  d=$(st "$p" "1:waiting_agent 2:not_started 3:not_started deliver:not_started | agent" '"DECISIONS.md" in d["stations"][0]["note"] and d["stations"][0]["record"]["from"] == "gate1"')
  python3 tools/gatecheck.py "$p" >/dev/null 2>&1; rc=$?   # gate ① as render and check read it: the concept is still missing
  python3 -c 'import sys; f = sys.argv[1] + "/DECISIONS.md"; s = open(f, encoding="utf-8").read(); open(f, "w", encoding="utf-8").write(s.replace("{待定 / 已定（关卡 ①）}", "已定（关卡 ①）：L2", 1))' "$p"
  q=$(st "$p" "1:done 2:in_progress 3:not_started deliver:not_started | agent" 'd["open"]["review_items"] == []')
  python3 tools/gatecheck.py "$p" >/dev/null 2>&1; rc2=$?
  if [ "$a" = "1:waiting_person 2:not_started 3:not_started deliver:not_started | person" ] && [ "$b" = "1:waiting_agent 2:not_started 3:not_started deliver:not_started | agent" ] \
    && [ "$c" = "1:waiting_agent 2:not_started 3:not_started deliver:not_started | agent" ] && [ "$d" = "1:waiting_agent 2:not_started 3:not_started deliver:not_started | agent" ] \
    && [ $rc = 1 ] && [ "$q" = "1:done 2:in_progress 3:not_started deliver:not_started | agent" ] && [ $rc2 = 0 ]
  then ok "status: a page out waits for the person; a submission waits for the agent (pending, then handed over) with its open items; gate ① is done when gatecheck says so (the decision, the words, DECISIONS.md's concept), then gate ② is in progress"
  else bad "status through gate ① (gatecheck $rc/$rc2): $a || $b || $c || $d || $q"; fi
  # a Director stop, a running command, a delivery record
  python3 -c 'import sys; f = sys.argv[1] + "/BRIEF.md"; s = open(f, encoding="utf-8").read(); open(f, "w", encoding="utf-8").write(s.replace("- Director: default", "- Director: hook=own, stop=E3", 1))' "$p"
  printf '{"v":1,"event":"start","run":"9-1","t":%s,"cmd":"render","args":["%s"],"pid":%s}\n' "$(date +%s)" "$p" "$$" >> "$p/.ovh/activity.jsonl"
  a=$(st "$p" "1:done 2:in_progress E3:not_started 3:not_started deliver:not_started | agent" '[r["cmd"] for r in d["activity"]["running"]] == ["render"]')
  b=$(vh status "$p")
  mkdir -p "$p/out" && : > "$p/out/final.mp4" && : > "$p/out/final.upload.mp4"
  printf '{"tool": "bin/vh deliver", "output": "final.upload.mp4", "master": "final.mp4", "time": "2026-10-19T12:00:00"}\n' > "$p/out/final.upload.mp4.deliver.json"
  c=$(st "$p" "1:done 2:in_progress E3:not_started 3:not_started deliver:not_started | agent" 'd["deliveries"][0]["output"] == "out/final.upload.mp4"' \
    'sorted(r["path"] for r in d["renders"]) == ["out/final.mp4", "out/final.upload.mp4"]' '"gate ③ is not decided" in d["stations"][-1]["note"]')
  python3 -c 'import sys; f = sys.argv[1] + "/REVIEW.md"; s = open(f, encoding="utf-8").read(); i = s.index("## 关卡 ③"); open(f, "w", encoding="utf-8").write(s[:i] + s[i:].replace("- 原话：\n", "- 原话：“可以发了”\n", 1).replace("- 定了：　改了：", "- 定了：发布　改了：无", 1))' "$p"
  d=$(st "$p" "1:done 2:not_started E3:not_started 3:done deliver:done | agent" 'd["stations"][-1]["note"] == "bin/vh deliver: out/final.upload.mp4"')
  if [ "$a" = "1:done 2:in_progress E3:not_started 3:not_started deliver:not_started | agent" ] && case "$b" in *"running: render"*) true ;; *) false ;; esac \
    && [ "$c" = "1:done 2:in_progress E3:not_started 3:not_started deliver:not_started | agent" ] && [ "$d" = "1:done 2:not_started E3:not_started 3:done deliver:done | agent" ]
  then ok "status: the Director's stop=E3 adds its checkpoint; a running command shows; bin/vh deliver's record is a delivery once gate ③ is done (before, its note says so)"
  else bad "status with a checkpoint, a run, a delivery: $a | $b | $c | $d"; fi
  # quick skips the gates; a waiver skips what it names; a pause waits for the person; a final film checked and passing
  OVH_PROJECTS="$t" vh new math qk --effort quick >/dev/null 2>&1; q=$(ls -d "$t"/*-qk)
  a=$(st "$q" "1:skipped 2:skipped 3:skipped deliver:in_progress | agent")
  mkdir -p "$q/out/check" && : > "$q/out/final.mp4"
  printf '{"version": 1, "video": "out/final.mp4", "t": %s, "verdict": "pass", "exit": 0, "counts": {"fail": 0, "warn": 1, "info": 0}, "findings": []}\n' "$(($(date +%s) + 5))" > "$q/out/check/final.check.json"
  b=$(st "$q" "1:skipped 2:skipped 3:skipped deliver:done | nobody" 'd["check"]["verdict"] == "pass" and d["check"]["record"] == "out/check/final.check.json"')
  OVH_PROJECTS="$t" vh new math wv >/dev/null 2>&1; q=$(ls -d "$t"/*-wv)
  python3 -c 'import sys; f = sys.argv[1] + "/REVIEW.md"; s = open(f, encoding="utf-8").read(); open(f, "w", encoding="utf-8").write(s.replace("## 关卡 ① 立意和大纲\n", "## 关卡 ① 立意和大纲\n- 用户授权跳过（2026-10-19）。原话：“直接做完给我看”\n- 范围：跳过关卡 ②③\n", 1))' "$q"
  c=$(st "$q" "1:in_progress 2:skipped 3:skipped deliver:not_started | agent")
  printf '\n## 暂停 · 2026-10-19\n- 原话："先停一下"\n' >> "$q/REVIEW.md"
  d=$(st "$q" "1:in_progress 2:skipped 3:skipped deliver:not_started | person" 'd["paused"] is True')
  if [ "$a" = "1:skipped 2:skipped 3:skipped deliver:in_progress | agent" ] && [ "$b" = "1:skipped 2:skipped 3:skipped deliver:done | nobody" ] \
    && [ "$c" = "1:in_progress 2:skipped 3:skipped deliver:not_started | agent" ] && [ "$d" = "1:in_progress 2:skipped 3:skipped deliver:not_started | person" ]
  then ok "status: quick skips the gates; a final film with a passing check record is delivered; a waiver skips the gates it names; a pause waits for the person"
  else bad "status: quick, waiver, pause: $a | $b | $c | $d"; fi
  # a check record keeps the film's size and mtime_ns, and a film that differs from them in either is not the one checked:
  # a film put back with an old modification time (cp -p, rsync -a, bin/vh versions use) is older than the record all the
  # same, which the time alone calls current. A record without the two (made before) goes by the film's time, as it did
  cat > "$t/ck.py" <<'PY'
import json, os, sys, time
q, what, a, b = sys.argv[1:5]
film, rec = q + "/out/final.mp4", q + "/out/check/final.check.json"
if what == "film":   # film <bytes> <modified: seconds from now | rec: the recorded mtime_ns>
    open(film, "wb").write(a.encode())
    ns = json.load(open(rec))["mtime_ns"] if b == "rec" else int((time.time() + float(b)) * 1e9)
    os.utime(film, ns=(ns, ns))
else:                # record <fields | none> <made: seconds from now>
    r = {"version": 1, "video": "out/final.mp4", "t": time.time() + float(b), "verdict": "pass", "exit": 0, "counts": {"fail": 0, "warn": 0, "info": 0}, "findings": []}
    if a == "fields":
        s = os.stat(film); r.update(size=s.st_size, mtime_ns=s.st_mtime_ns)
    json.dump(r, open(rec, "w"))
PY
  OVH_PROJECTS="$t" vh new math ck --effort quick >/dev/null 2>&1; q=$(ls -d "$t"/*-ck); mkdir -p "$q/out/check"
  python3 "$t/ck.py" "$q" film 'film one' -100 && python3 "$t/ck.py" "$q" record fields 5
  a=$(st "$q" "1:skipped 2:skipped 3:skipped deliver:done | nobody" 'd["check"]["stale"] is False')
  python3 "$t/ck.py" "$q" film 'film two!!' -200   # another film, older than the record, as a restore that keeps times puts it
  b=$(st "$q" "1:skipped 2:skipped 3:skipped deliver:in_progress | agent" 'd["check"]["stale"] is True' 'd["renders"][0]["check"]["stale"] is True')
  python3 "$t/ck.py" "$q" film 'film one' -300     # the same size, another modification time
  c=$(st "$q" "1:skipped 2:skipped 3:skipped deliver:in_progress | agent" 'd["check"]["stale"] is True')
  python3 "$t/ck.py" "$q" film 'film one, longer' rec   # the recorded modification time, another size
  d=$(st "$q" "1:skipped 2:skipped 3:skipped deliver:in_progress | agent" 'd["check"]["stale"] is True')
  python3 "$t/ck.py" "$q" film 'film one' -100 && python3 "$t/ck.py" "$q" record none 5   # a record of the old kind: by time
  e=$(st "$q" "1:skipped 2:skipped 3:skipped deliver:done | nobody" 'd["check"]["stale"] is False')
  python3 "$t/ck.py" "$q" record none -1000
  k=$(st "$q" "1:skipped 2:skipped 3:skipped deliver:in_progress | agent" 'd["check"]["stale"] is True')
  if [ "$a" = "1:skipped 2:skipped 3:skipped deliver:done | nobody" ] && [ "$b" = "1:skipped 2:skipped 3:skipped deliver:in_progress | agent" ] \
    && [ "$c" = "$b" ] && [ "$d" = "$b" ] && [ "$e" = "$a" ] && [ "$k" = "$b" ]
  then ok "status: a check record is stale when the film's size or mtime_ns is not the one it kept, though the film is older than the record (and then the delivery is not done); a record without them goes by time"
  else bad "status: a check record and a film put back with an old time: $a | $b | $c | $d | $e | $k"; fi
  # gate ②: read from the section that names its page (the template's), whatever the dates; a section without the 页面
  # line is read by date, and the note says so (older than the page: not counted)
  OVH_PROJECTS="$t" vh new math s2 >/dev/null 2>&1; q=$(ls -d "$t"/*-s2)
  python3 - "$q" <<'PY'
import os, sys, time
p = sys.argv[1]
f = p + "/REVIEW.md"; s = open(f, encoding="utf-8").read()
s = s.replace('- 原话："……"', '- 原话："选 B"', 1).replace("- 定了：{…}　改了：{…}", "- 定了：B　改了：无", 1)
i = s.index("## 关卡 ② 分镜")
open(f, "w", encoding="utf-8").write(s[:i] + s[i:].replace("- 原话：\n", '- 原话："分镜可以"\n', 1).replace("- 定了：　改了：", "- 定了：通过　改了：无", 1))
d = p + "/DECISIONS.md"; s = open(d, encoding="utf-8").read(); open(d, "w", encoding="utf-8").write(s.replace("{待定 / 已定（关卡 ①）}", "已定（关卡 ①）：B", 1))
os.makedirs(p + "/out/review", exist_ok=True)
for n in ("gate-2.json", "gate-2.html"): open(p + "/out/review/" + n, "w").write("{}")
os.utime(f, (time.time() - 100,) * 2)   # REVIEW.md older than the page
PY
  a=$(st "$q" "1:done 2:done 3:in_progress deliver:not_started | agent" 'd["stations"][1]["record"]["from"] == "page" and d["stations"][1]["note"] is None')
  python3 -c 'import os, sys, time; f = sys.argv[1] + "/REVIEW.md"; s = open(f, encoding="utf-8").read(); open(f, "w", encoding="utf-8").write(s.replace("- 页面：`out/review/gate-2.html`（{日期}）\n", "", 1)); os.utime(f, (time.time() - 100,) * 2)' "$q"
  b=$(st "$q" "1:done 2:waiting_person 3:not_started deliver:not_started | person" 'd["stations"][1]["record"]["from"] == "stop_older" and "not counted" in d["stations"][1]["note"]')
  python3 -c 'import os, sys, time; os.utime(sys.argv[1] + "/REVIEW.md", (time.time() + 100,) * 2)' "$q"
  c=$(st "$q" "1:done 2:done 3:in_progress deliver:not_started | agent" 'd["stations"][1]["record"]["from"] == "stop_by_date" and "by date" in d["stations"][1]["note"]')
  if [ "$a" = "1:done 2:done 3:in_progress deliver:not_started | agent" ] && [ "$b" = "1:done 2:waiting_person 3:not_started deliver:not_started | person" ] \
    && [ "$c" = "1:done 2:done 3:in_progress deliver:not_started | agent" ]
  then ok "status: gate ② read from the template's section, which names its page, whatever the dates; without that line, by date, and the note says so"
  else bad "status of gate ② by page and by date: $a | $b | $c"; fi
  # no REVIEW.md (a project from before the templates had one): no record, not "in progress"; machine-written records of
  # the wrong shape (a check record, a render's and a delivery's sidecar, a submission, activity lines) break nothing
  OVH_PROJECTS="$t" vh new math nr >/dev/null 2>&1; q=$(ls -d "$t"/*-nr); rm "$q/REVIEW.md"
  a=$(st "$q" "1:no_record 2:no_record 3:no_record deliver:no_record | unknown")
  mkdir -p "$q/out/check" "$q/out/review/feedback" "$q/.ovh" && : > "$q/out/x.mp4"
  printf '%s\n' '{"version": 1, "video": 5, "t": "x", "findings": "x", "counts": [1], "verdict": 3}' > "$q/out/check/bad.check.json"
  printf '%s\n' '{"version": 1, "video": "out/x.mp4", "t": 1, "findings": [1, {"severity": "fail", "message": 2}], "counts": {"fail": "x"}, "exit": true}' > "$q/out/check/x.check.json"
  printf '%s\n' '{"pixels": 5, "patches": 5, "frames": "x", "span": "y"}' > "$q/out/x.mp4.render.json"
  printf '%s\n' '{"output": 5, "master": [1]}' > "$q/out/x.mp4.deliver.json"
  printf '%s\n' '{"round": 5, "items": 5, "lang": 3}' > "$q/out/review/feedback/1-20261019-120000.json"
  printf '%s\n' '{"round": "1", "items": [{"target": 5}, {"target": "range:1-2", "status": "change", "text": 7, "label": 8, "t": "a", "t1": 2}]}' > "$q/out/review/feedback/1-20261019-120001.json"
  printf '%s\n' '{"v":1,"event":"note","run":"1-1","t":1,"outputs":5,"summary":5}' '{"v":1,"event":"end","run":"1-1","t":2,"duration":"x","exit":"y","cmd":4}' \
    '{"v":1,"event":"start","run":"2-2","t":3,"args":5,"cwd":5,"pid":"z"}' '{"v":true,"event":"x","t":1}' '{"v":1,"event":"progress","run":"2-2","t":true,"done":"x"}' \
    '{"v":1,"event":"feedback","t":4,"items":[1],"round":2}' > "$q/.ovh/activity.jsonl"
  b=""
  for c in status activity; do for d in "" --json; do
    e=$(vh "$c" "$q" ${d:+"$d"} 2>&1) || b="$b $c $d: exit $?"
    case "$e" in *Traceback*) b="$b $c $d: a traceback" ;; esac
  done; done
  [ "$a" = "1:no_record 2:no_record 3:no_record deliver:no_record | unknown" ] && [ -z "$b" ] \
    && ok "status: no REVIEW.md is no record (waiting on: unknown); records of the wrong shape break neither status nor activity" \
    || bad "status without REVIEW.md, or with bad records: $a |$b"
  vh status "$t/no-such" >/dev/null 2>&1; rc=$?; [ $rc = 2 ] && ok "status: no project exits 2" || bad "status of nothing exited $rc"
  python3 -c 'import sys; sys.path.insert(0, "tools"); import status as S; d = S.director_stops
sys.exit(0 if d("hook=own, stop=E1, stop=E3") == d("stop=E1,E3") == d("stop = e1，E3") == {"E1", "E3"} and not d("stop=E12") and not d("nostop=E3") else 1)' \
    && ok "status: every stop= on the Director line counts (stop=E1, stop=E3), E12 and nostop= do not" || bad "status: the Director line's stop= items"
  rm -rf "$t"
}

# the activity log (<project>/.ovh/activity.jsonl, tools/activity.py): a command on a project adds a start, its tool's note
# and an end with the exit status; commands without a project, and the read-only views, add nothing; keys and the
# environment never reach it; 16 commands at once leave 32 whole lines; TERM ends a command at once (no end line), a tool
# that handles it logs 128 + n, a Ctrl-C logs 130 and ends bin/vh by SIGINT; a project that cannot be written to changes
# nothing in what the command does or says; bin/vh activity reads it back (and --follow as it grows). The page tools' lines
# (render's progress, patch) are checked in film_checks
looks_checks() {   # bin/vh breakdown on a made-up film (a cut at 1 s, a 0.2 s fade at 2 s) and bin/vh looks: a delivered film's look
  # onto a ledger outside the project, a project's frames checked against it
  local t p q a b c rc rc2 rc3 m='{"bpm": 120, "beats": [0.5, 1.0, 1.5, 2.0, 2.5, 3.0], "downbeats": [1.0, 3.0]}'
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  if ! command -v ffmpeg >/dev/null 2>&1; then skip "breakdown and looks" "no ffmpeg"; rm -rf "$t"; return; fi
  ffmpeg -v error -f lavfi -i "color=c=0xd04020:s=320x180:d=1:r=30" -f lavfi -i "color=c=0x2050a0:s=320x180:d=1.2:r=30" -f lavfi -i "color=c=0x80a0a0:s=320x180:d=1.2:r=30" \
    -filter_complex "[0][1]concat=n=2:v=1:a=0,settb=1/30,fps=30[ab];[2]settb=1/30[c];[ab][c]xfade=transition=fade:duration=0.2:offset=2.0,format=yuv420p" -c:v libx264 -crf 10 "$t/film.mp4"
  printf '%s' "$m" > "$t/beats.json"
  a=$(vh breakdown "$t/film.mp4" --out "$t/bd" --beats "$t/beats.json" --json 2>"$t/bd.err"); rc=$?
  b=$(vh breakdown "$t/film.mp4" --out "$t/bd2" --beats off 2>&1); rc2=$?
  if [ "$rc:$rc2" = 0:0 ] && python3 - "$a" "$t/bd" <<'PY'
import json, sys
from pathlib import Path
d, out = json.loads(sys.argv[1]), Path(sys.argv[2])
tr = [(t["t"], t["kind"]) for t in d["transitions"]]
ok = d["v"] == 1 and len(tr) == 2 and tr[0] == (1.0, "cut") and tr[1][1] == "soft" and 1.95 <= tr[1][0] <= 2.05
ok = ok and [s["i"] for s in d["segments"]] == [1, 2, 3] and d["segments"][0]["length"] == 1.0 and d["stats"]["cuts"] == 1 and d["stats"]["soft"] == 1
ok = ok and d["beats"]["on_beat"] == 2 and d["beats"]["of"] == 2 and d["beats"]["on_downbeat"] == 1 and d["beats"]["bpm"] == 120
ok = ok and json.loads((out / "breakdown.json").read_text(encoding="utf-8"))["transitions"] == d["transitions"]
swap = (out / "swap.md").read_text(encoding="utf-8")
ok = ok and "| 1 | 0.00–1.00 | 1.00 s | cut |" in swap and swap.count("{…}") == 9
sys.exit(0 if ok else 1)
PY
  then
    if ! command -v uv >/dev/null 2>&1; then skip "breakdown's pictures" "no uv"
    elif [ -s "$t/bd/change.png" ] && [ -s "$t/bd/cuts.jpg" ] && [ -s "$t/bd/segments.jpg" ] && printf '%s' "$b" | grep -q "1 cuts, 1 soft transitions · 3 segments"; then
      ok "breakdown: a cut and a 6-frame fade found where they are, three segments, the cuts against a given beat grid (2 of 2 on a beat, 1 on a downbeat), the contact strips, keyframes and heat maps, swap.md with the measured timing and empty cells"
    else bad "breakdown's pictures: $(ls "$t/bd" | tr '\n' ' ') $b"; fi
  else bad "breakdown (exits $rc:$rc2): $(printf '%s' "$a" | tail -c 300) $(tail -c 300 "$t/bd.err")"; fi
  # looks: a film on record with its storyboard's transitions; the same film's frame looks like it, another picture
  # does not; no ledger yet is said, exit 0; a project with no film to add is 1
  OVH_PROJECTS="$t" vh new short lk-one >/dev/null 2>&1; OVH_PROJECTS="$t" vh new short lk-two >/dev/null 2>&1; OVH_PROJECTS="$t" vh new short lk-three >/dev/null 2>&1
  p=$(ls -d "$t"/*-lk-one); q=$(ls -d "$t"/*-lk-two)
  for x in "$p" "$q"; do printf '\n| # | 时间 | 配方 | 转场出 |\n|---|---|---|---|\n| A | 0–1 | black-card | flash-cut |\n' >> "$x/STORYBOARD.md"; done
  ffmpeg -v error -y -ss 0.5 -i "$t/film.mp4" -frames:v 1 "$t/red.png"; ffmpeg -v error -y -f lavfi -i "color=c=0xeeeeee:s=320x180" -frames:v 1 "$t/grey.png"
  a=$(vh looks check "$q" --images "$t/red.png" --ledger "$t/L" 2>&1); rc=$?
  b=$(vh looks add "$p" --film "$t/film.mp4" --ledger "$t/L" --json 2>/dev/null); rc2=$?
  c=$(vh looks check "$q" --images "$t/red.png" --ledger "$t/L" 2>&1; vh looks check "$(ls -d "$t"/*-lk-three)" --images "$t/grey.png" --ledger "$t/L" 2>&1; vh looks list --ledger "$t/L" 2>&1); rc3=$?
  if [ "$rc:$rc2:$rc3" = 0:0:0 ] && python3 - "$b" <<'PY'
import json, sys
sys.path.insert(0, "tools/assets")
import ledger
r = json.loads(sys.argv[1])["record"]
lk = r["look"]
ok = not ledger.validate(r) and r["id"] == "lk-one-film" and r["license"]["class"] == "own" and r["source"]["origin"] == "self"
ok = ok and lk["transitions"] == ["black-card", "flash-cut"] and 20 <= lk["frames"] <= 24 and len(lk["layout"]) == 80 and lk["measured_from"] == "film"
ok = ok and all(p["hex"].startswith("#") and 0 < p["share"] <= 1 for p in lk["palette"]) and lk["bg"].startswith("#")
sys.exit(0 if ok else 1)
PY
  then case "$a|$c" in *"(no ledger yet)"*"0 of 0 alike"*"|"*"! like lk-one-film"*"transitions black-card, flash-cut"*"1 of 1 alike"*"0 of 1 alike"*"1 film"*)
      if vh looks add "$(ls -d "$t"/*-lk-three)" --ledger "$t/L" >/dev/null 2>&1; [ $? = 1 ]; then
        ok "looks: a delivered film's background, palette, layout, transitions and the rest as an asset record outside the repo; a frame of it and the same storyboard look alike, another picture does not; no ledger yet is said; nothing to add is 1"
      else bad "looks add with no film: not exit 1"; fi ;;
    *) bad "looks check: $(printf '%s' "$a$c" | tail -c 600)" ;; esac
  else bad "looks (exits $rc:$rc2:$rc3): $(printf '%s' "$a$b" | tail -c 400)"; fi
  rc=0; for x in "looks" "looks bogus" "looks check" "breakdown" "breakdown $t/none.mp4" "breakdown $t/film.mp4 --beats nowhere.json"; do
    # shellcheck disable=SC2086
    a=$(vh $x 2>/dev/null); b=$?; [ "$b" = 2 ] && [ -z "$a" ] || { rc=1; bad "bin/vh $x: exit $b, stdout ${a:0:80}"; }
  done
  a=$(vh looks check "$p" --film "$t/film.mp4" --images "$t/red.png" 2>/dev/null); b=$?; [ "$b" = 2 ] || { rc=1; bad "looks check --film and --images: exit $b"; }
  [ "$rc" = 1 ] || ok "breakdown and looks: usage errors exit 2, nothing on stdout"
  rm -rf "$t"
}

activity_checks() {
  local t p a b c rc rc2 i pid want la lp
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX"); p="$t/p q"   # a space in the path
  cp -R tools/desk/fixtures/zh "$p"
  vh review "$p" 1 >/dev/null 2>&1; rc=$?
  vh review "$p" 9 >/dev/null 2>&1; rc2=$?
  (cd "$p" && vh effort quick >/dev/null && vh desk data . >/dev/null && vh activity . >/dev/null)
  OVH_CI_SECRET=topsecret-env vh timeline "$p" --token abc123 API_KEY=sk-123456 --api-key=xyz AIzaFAKEFAKE "$(printf 'a%.0s' $(seq 40))" >/dev/null 2>&1
  vh timeline "$p" "https://user:hunter2pw@example.com/x?sig=s3cr3tsig&v=1#frag=fragval1" -k shortflagval "Authorization: Bearer bearertok1" \
    --auth=authval1 MY_VAR=envval1 cred=credval1 Ab3dEf6.hIj9kLm2n-opQ 0123456789abcdef0123 --out=keynote.wav keepme.wav >/dev/null 2>&1
  a=$(python3 - "$p/.ovh/activity.jsonl" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]
text = open(sys.argv[1], encoding="utf-8").read()
runs = {}
for r in recs:
    runs.setdefault(r.get("run"), []).append(r)
seq = [[r["event"] for r in rs] for rs in runs.values()]
want = [["start", "note", "end"], ["start", "end"], ["start", "end"], ["start", "end"]]
review = list(runs.values())[0]
bad = []
if seq != want: bad.append(f"events {seq}")
if review[0]["cmd"] != "review" or review[0]["args"][-1] != "1" or review[2]["exit"] != 0 or not review[1]["outputs"] == ["out/review/gate-1.html"]: bad.append(f"review run {review}")
if list(runs.values())[1][-1]["exit"] != 2: bad.append("review 9 should end with exit 2")
for s in ("abc123", "sk-123456", "xyz", "AIzaFAKE", "a" * 40, "topsecret", "OVH_CI_SECRET", "hunter2pw", "s3cr3tsig", "fragval1", "shortflagval",
          "bearertok1", "authval1", "envval1", "credval1", "Ab3dEf6", "0123456789abcdef0123"):
    if s in text: bad.append(f"{s} is in the log")
shown = list(runs.values())[3][0]["args"][1:]
if shown != ["https://…@example.com/x?sig=…&v=…#…", "-k", "…", "Authorization: …", "--auth=…", "MY_VAR=…", "cred=…", "…", "…", "--out=keynote.wav", "keepme.wav"]:
    bad.append(f"shown as {shown}")
print("; ".join(bad)); sys.exit(1 if bad else 0)
PY
  )
  if [ $rc = 0 ] && [ $rc2 = 2 ] && [ -z "$a" ]; then ok "activity: a command on a project logs its start, its tool's note and its end with the exit status; effort, desk data and activity log nothing; keys, passwords, URL secrets, tokens and the environment never reach the log, option names and file names stay"
  else bad "activity: review exit $rc/$rc2: $a"; fi
  # 16 at once: every line whole (one write each), also when the arguments would fill 2 KiB (3 bytes a character)
  rm -f "$p/.ovh/activity.jsonl"
  for i in $(seq 16); do vh timeline "$p" >/dev/null 2>&1 & done; wait
  a=$(python3 -c 'import json, sys; ls = open(sys.argv[1], encoding="utf-8").read().splitlines(); [json.loads(l) for l in ls]; print(len(ls))' "$p/.ovh/activity.jsonl" 2>&1)
  rm -f "$p/.ovh/activity.jsonl"; la=(); for i in $(seq 30); do la+=("$(printf '片%.0s' $(seq 100))"); done
  for i in $(seq 16); do vh timeline "$p" "${la[@]}" >/dev/null 2>&1 & done; wait
  c=$(python3 -c 'import json, sys; ls = open(sys.argv[1], "rb").read().splitlines(); r = [json.loads(l) for l in ls]; print(len(ls), max(map(len, ls)) < 1024, r[0]["args"][-1])' "$p/.ovh/activity.jsonl" 2>&1)
  [ "$a" = 32 ] && [ "$c" = "32 True …" ] && ok "activity: 16 commands at once leave 32 whole lines, also with long arguments (cut to stay under 1 KiB)" || bad "activity: 16 concurrent commands left: $a / $c"
  # arguments that are not UTF-8 (a Latin-1 name, a surrogate's bytes, a cut character), and a tool's output path that is
  # not either, are written as \xNN: every line is UTF-8 JSON, a Chinese argument stays as it is; a line an older bin/vh
  # wrote with the raw byte still reads, with the byte as \xNN
  rm -f "$p/.ovh/activity.jsonl"
  vh timeline "$p" $'caf\xe9.wav' "片子" $'\xed\xa0\x80' $'a\xe7\x89' >/dev/null 2>&1
  OVH_ACTIVITY_LOG="$p/.ovh/activity.jsonl" OVH_ACTIVITY_RUN=ci-1 OVH_ACTIVITY_CMD=qa python3 -c 'import os, sys; sys.path.insert(0, "tools"); import activity
activity.note("made", [os.fsdecode(os.fsencode(sys.argv[1]) + b"/out/x\xff.wav")])' "$p"
  printf '{"v":1,"event":"note","run":"old-1","t":1,"cmd":"qa","summary":"raw \351 byte"}\n' >> "$p/.ovh/activity.jsonl"
  a=$(python3 - "$p/.ovh/activity.jsonl" <<'PY' 2>&1
import json, sys
ls = open(sys.argv[1], "rb").read().splitlines(); bad = []
for n, l in enumerate(ls[:-1], 1):   # the last: the older bin/vh's own line
    try: json.loads(l.decode("utf-8"))
    except ValueError as e: bad.append(f"line {n} is not UTF-8 JSON: {e}")
r = [json.loads(l.decode("utf-8")) for l in ls[:3]] if not bad else []
if r and (r[0]["args"][1:] != ["caf\\xe9.wav", "片子", "\\xed\\xa0\\x80", "a\\xe7\\x89"] or r[2]["outputs"] != ["out/x\\xff.wav"]): bad.append(f"written as {r[0]['args'][1:]} {r[2]['outputs']}")
print("; ".join(bad))
PY
  )
  b=$(vh activity "$p" 2>&1); rb=$?
  case "$a|$rb:$b" in "|0:"*'caf\xe9.wav 片子 \xed\xa0\x80 a\xe7\x89'*'out/x\xff.wav'*'raw \xe9 byte'*)
      ok "activity: arguments and paths that are not UTF-8 are written as \\xNN (every line UTF-8 JSON); an older raw line still reads" ;;
    *) bad "activity with bytes that are not UTF-8: $a | exit $rb: $(printf '%s' "$b" | tail -c 400)" ;; esac
  # signals: a tool bin/vh exec'd into writes its own end, 128 + the signal (desk wait, the desk itself); a command bash
  # waits on (a stand-in uv that never ends): TERM ends bin/vh at once, with no end line (the run reads as gone), and a
  # Ctrl-C (SIGINT to the process group) writes the end with 130 and then ends bin/vh by SIGINT (the caller sees -2). The
  # stand-in traps INT: a loop of sleeps without it can miss a Ctrl-C that lands as a sleep ends (sh takes the sleep's
  # normal exit for a child that handled it), and then it never ends, and bin/vh waits on it. The whole check takes about
  # 1.5 s. Each command has 60 s to start; it has 10 s to end, as before, but is waited on for 60: one that ends later
  # fails with how long it took, and one still running then fails with the processes of its group. Once (GitHub's macOS
  # runner, 2026-10-28) a Ctrl-C to qa had no answer within 10 s, with the steps before it on time; that ended in a
  # traceback that said nothing more
  rm -f "$p/.ovh/activity.jsonl"; mkdir -p "$t/stub"
  printf '#!/bin/sh\ntrap "exit 130" INT\n: > "$UVMARK"\nwhile :; do sleep 0.05; done\n' > "$t/stub/uv"; chmod +x "$t/stub/uv"
  : > "$p/audio/mix.wav"
  a=$(python3 - "$VH_BASH" "$ROOT" "$p" "$t" <<'PY'
import json, os, signal, subprocess, sys, time
sh, root, p, t = sys.argv[1:]
env, mark = dict(os.environ, PATH=f"{t}/stub:{os.environ['PATH']}", UVMARK=f"{t}/started"), f"{t}/started"
def start(*args, until):   # up to 60 s to get there (it takes a fraction of one): a slow start is not what this tests
    if os.path.exists(mark): os.remove(mark)
    pr = subprocess.Popen([sh, f"{root}/bin/vh", *args], start_new_session=True, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(1200):
        if os.path.exists(until) or pr.poll() is not None: break
        time.sleep(0.05)
    return pr
def stub():
    return subprocess.run(["pgrep", "-f", f"{t}/stub/uv"], capture_output=True).returncode == 0
def ended(pr):   # the exit status within 10 s of the signal; later, with how long it took ("143 after 23 s"); still
    t0 = time.time()   # running at 60 s, what of its process group ran then (and it is killed)
    try:
        rc = pr.wait(60); d = time.time() - t0
        return rc if d <= 10 else f"{rc} after {d:.0f} s"
    except subprocess.TimeoutExpired: pass
    ps = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,pgid=,stat=,command="], capture_output=True, text=True).stdout.splitlines()
    left = [" ".join(l.split()[:4] + l.split()[4:7]) for l in ps if len(l.split()) > 4 and l.split()[2] == str(pr.pid)]
    os.killpg(pr.pid, signal.SIGKILL); pr.wait()
    return "still running 60 s on: " + " | ".join(left)
out = []
pr = start("desk", "wait", p, "--timeout", "30", until=f"{p}/out/review/feedback/.listening")
pr.send_signal(signal.SIGTERM); out.append(f"wait {ended(pr)}")   # at once: its handlers are in place before the flag
pr = start("desk", p, "--port", "0", until=f"{p}/out/review/.desk.json")
time.sleep(0.5); pr.send_signal(signal.SIGTERM); out.append(f"desk {ended(pr)}")
pr = start("qa", f"{p}/audio/mix.wav", until=mark)
t0 = time.time(); pr.send_signal(signal.SIGTERM)   # to bin/vh alone, as kill <pid> does: it must not wait for the stand-in
try: rc = pr.wait(5)
except subprocess.TimeoutExpired: rc = "waited"
out.append(f"qa {rc} " + ("at once" if time.time() - t0 < 2 and stub() else "late"))
subprocess.run(["pkill", "-f", f"{t}/stub/uv"])
pr = start("qa", f"{p}/audio/mix.wav", until=mark)
os.killpg(pr.pid, signal.SIGINT); out.append(f"qa {ended(pr)}")
subprocess.run(["pkill", "-f", f"{t}/stub/uv"])
recs = [json.loads(x) for x in open(f"{p}/.ovh/activity.jsonl", encoding="utf-8")]
out.append(" ".join(f"{r['cmd']}:{r['exit']}" for r in recs if r["event"] == "end"))
j = json.loads(subprocess.run([sys.executable, f"{root}/tools/activity.py", p, "--json"], capture_output=True, text=True).stdout)
out.append(" ".join(f"{r['cmd']}:{r['state']}" for r in j["runs"]))
print(" · ".join(out))
PY
)
  want="wait 143 · desk 143 · qa -15 at once · qa -2 · desk:143 desk:143 qa:130 · desk:failed desk:failed qa:gone qa:failed"
  [ "$a" = "$want" ] && ok "activity: TERM ends a command at once (no end line: gone), a tool that handles it logs 128 + n; Ctrl-C logs 130 and ends bin/vh by SIGINT" \
    || bad "activity on signals: '$a' (want '$want')"
  # a closed pipe (bin/vh check … | head): check's scratch folder still goes, nothing stale lands in the log, and the EXIT
  # trap says nothing of its own (bash 5 runs it on SIGPIPE; bash 3.2 wrote the failed output into the next redirect, and
  # into $(date))
  if command -v ffmpeg >/dev/null; then
    mkdir -p "$t/pipetmp" "$p/out"; rm -f "$p/.ovh/activity.jsonl"
    ffmpeg -nostdin -v error -f lavfi -i testsrc=s=160x90:r=10:d=1 -pix_fmt yuv420p "$p/out/pipe.mp4"
    TMPDIR="$t/pipetmp" "$VH_BASH" "$ROOT/bin/vh" check "$p/out/pipe.mp4" 2>"$t/pipe.err" | head -1 >/dev/null
    a=$(python3 -c 'import json, sys; [json.loads(l) for l in open(sys.argv[1], encoding="utf-8")]; print("ok")' "$p/.ovh/activity.jsonl" 2>&1)
    if [ "$a" = ok ] && [ -z "$(ls -A "$t/pipetmp")" ] && ! grep -q "arithmetic\|syntax error\|Traceback" "$t/pipe.err"
    then ok "activity: under a closed pipe (check | head) the scratch folder goes, the log stays whole JSON, the trap says nothing"
    else bad "check | head: log $a, left in TMPDIR: $(ls -A "$t/pipetmp"), stderr: $(tail -c 300 "$t/pipe.err")"; fi
    rm -f "$p/out/pipe.mp4" "$p/out/check/pipe.check.json"
  else skip "check under a closed pipe" "needs ffmpeg"; fi
  # a project that cannot be written to: the same exit and the same words
  a=$(vh timeline "$p" 2>&1); rc=$?
  rm -rf "$p/.ovh"; chmod 555 "$p"
  b=$(vh timeline "$p" 2>&1); rc2=$?
  chmod 755 "$p"
  [ $rc = $rc2 ] && [ "$a" = "$b" ] && ok "activity: a project that cannot be written to changes nothing in what the command does or says" || bad "activity on a read-only project: exit $rc/$rc2, '$a' / '$b'"
  # the reader: the human lines, --json, and --follow as the log grows; bin/vh new logs into the project it made
  vh review "$p" 1 >/dev/null 2>&1; vh review "$p" 9 >/dev/null 2>&1
  a=$(vh activity "$p"); b=$(vh activity "$p" --json)
  "$VH_BASH" "$ROOT/bin/vh" activity "$p" --follow --json > "$t/follow.out" 2>&1 & pid=$!
  sleep 1; vh review "$p" 1 >/dev/null 2>&1; sleep 1.2; kill $pid 2>/dev/null; wait $pid 2>/dev/null
  if case "$a" in *"review . 1"*"✓"*"gate-1.html"*"review . 9"*"✗ exit 2"*) true ;; *) false ;; esac && python3 - "$b" "$t/follow.out" <<'PY'
import json, sys
d = json.loads(sys.argv[1]); f = [json.loads(l) for l in open(sys.argv[2], encoding="utf-8") if l.strip()]
st = [r["state"] for r in d["runs"]]
sys.exit(0 if d["version"] == 1 and st[-2:] == ["ok", "failed"] and d["runs"][-2]["outputs"] == ["out/review/gate-1.html"]
         and [r["event"] for r in f][-3:] == ["start", "note", "end"] else 1)
PY
  then ok "activity: bin/vh activity lists the runs (paths relative to the project), --json gives each run's state and outputs, --follow prints the lines as they come"
  else bad "bin/vh activity: $(printf '%s' "$a" | tail -c 400) | $(tail -c 300 "$t/follow.out")"; fi
  # a project whose path is over 120 characters (a long TMPDIR, a deep folder): the path stays whole in the log, so the
  # reader still shows it as . (cut at 120, it showed the cut path, and the arguments after it fell off the line)
  lp="$t/$(printf 'd%.0s' $(seq 130))/p"; mkdir -p "${lp%/p}"; cp -R tools/desk/fixtures/zh "$lp"
  vh review "$lp" 1 >/dev/null 2>&1; a=$(vh activity "$lp" 2>&1)
  case "$a" in *"review . 1"*) ok "activity: a project path over 120 characters stays whole in the log, the reader shows it as ." ;;
    *) bad "activity on a project path of ${#lp} characters: $(printf '%s' "$a" | tail -c 300)" ;; esac
  OVH_PROJECTS="$t/new" vh new math ci-act >/dev/null 2>&1
  a=$(cat "$t"/new/*-ci-act/.ovh/activity.jsonl 2>&1)
  case "$a" in *'"event":"start"'*'"cmd":"new"'*'"event":"end"'*'"exit":0'*'"summary":"created '*'-ci-act · math · standard"'*) ok "activity: bin/vh new logs itself into the project it made" ;;
    *) bad "activity of bin/vh new: $a" ;; esac
  rm -rf "$t"
}

know_checks() {   # bin/vh know: the index of recipes, styles and the sections read when needed, and what a few words find
  local t a b q rc rc2
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  vh know --index --json > "$t/index.json" 2>/dev/null; rc=$?   # a file: the index is over Linux's 128 KB for one argument
  if [ "$rc" = 0 ] && python3 - "$t/index.json" <<'PY'
import json, re, sys
from pathlib import Path
sys.path.insert(0, "tools")
import know
d = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
units, by = d["units"], d["by_kind"]
ok = all(by.get(k, 0) > 0 for k in ("recipe", "style", "doc", "case")) and len(units) == sum(by.values())
ok = ok and all(set(u) >= {"kind", "id", "title", "file", "line", "summary", "tags", "chars"} and u["title"] for u in units)
for u in units:   # a section's line is its heading's (or line 1, a file's lead)
    if u["kind"] in ("doc", "case") and u["line"] > 1:
        line = Path(u["file"]).read_text(encoding="utf-8").splitlines()[u["line"] - 1]
        ok = ok and bool(re.match(r"#{2,3} ", line))
ok = ok and len({u["id"] for u in units}) == len(units)
ok = ok and know.own_tags("text <!-- know: 翻页, 纸面、转场 --> more") == ["翻页", "纸面", "转场"]
ok = ok and know.terms("章节进度条 black-card") == ["章节", "节进", "进度", "度条", "black-card", "black", "card"]
sys.exit(0 if ok else 1)
PY
  then ok "know --index: every recipe, style, doc section and case section with a title, its file and its heading's line, unique ids; own tags from a section's comment; words as the index counts them"
  else bad "know --index (exit $rc): $(tail -c 300 "$t/index.json")"; fi
  # a component from its slots.json (lib/ and LICENSES/ are not components) and a section by its own tags, in a small tree
  # of their own (main has no components/ yet); then the sections tagged in the playbook, found by their tags
  mkdir -p "$t/tree/tools" "$t/tree/styles" "$t/tree/playbook" "$t/tree/components/page-turn" "$t/tree/components/lib" "$t/tree/components/LICENSES"
  cp tools/know.py tools/readpath.py "$t/tree/tools/"
  printf '{"version": 1, "name": "page-turn", "summary": "A book page turns over in perspective.", "painters": ["canvas"], "slots": [{"name": "ease", "type": "string", "default": "inOutCubic", "text": "how the turn runs"}]}' > "$t/tree/components/page-turn/slots.json"
  : > "$t/tree/components/lib/core.js"; : > "$t/tree/components/LICENSES/MIT.txt"
  printf '# 03 运动\n\n## 6. 转场\n<!-- know: 翻页, 纸面转场 -->\n\n方向连续。\n\n## 7. 别的\n\n别的。\n' > "$t/tree/playbook/03-x.md"
  a=$(python3 "$t/tree/tools/know.py" --index --json 2>/dev/null); b=$(python3 "$t/tree/tools/know.py" page turn --json 2>/dev/null)
  c=$(python3 "$t/tree/tools/know.py" 翻页 --json 2>/dev/null); d=$(vh know transition seam --kind doc --json 2>/dev/null)
  if python3 - "$a" "$b" "$c" "$d" <<'PY'
import json, sys
a, b, c, d = (json.loads(x) for x in sys.argv[1:5])
comp = [u for u in a["units"] if u["kind"] == "component"]
ok = a["by_kind"].get("component") == 1 and comp[0]["file"] == "components/page-turn/slots.json" and set(comp[0]["tags"]) >= {"page-turn", "canvas", "ease"}
ok = ok and b["hits"][0]["kind"] == "component" and b["hits"][0]["id"] == "page-turn" and b["hits"][0]["summary"].startswith("A book page")
ok = ok and c["hits"][0]["file"] == "playbook/03-x.md" and c["hits"][0]["title"].endswith("› 6. 转场") and "翻页" in c["hits"][0]["tags"]
ok = ok and d["hits"][0]["file"] in ("playbook/03-motion-design.md", "playbook/09-narrative.md") and {"transition", "seam"} <= set(d["hits"][0]["tags"])
sys.exit(0 if ok else 1)
PY
  then ok "know: a component from its slots.json (name, summary, painters, slots; lib/ and LICENSES/ are not components), a section by the tags in its own comment, the playbook's tagged sections"
  else bad "know, components and own tags: $(printf '%s' "$b$c$d" | tail -c 400)"; fi
  a=$(vh know 黑场 字卡 --json 2>/dev/null; vh know 孔版 叠印 --kind style --json 2>/dev/null; vh know 抖音 分享页 --kind doc --json 2>/dev/null); rc=$?
  b=$(vh know 黑场 字卡 --json 2>/dev/null)
  if [ "$rc" = 0 ] && [ "$b" = "$(vh know 黑场 字卡 --json 2>/dev/null)" ] && python3 - "$a" <<'PY'
import json, sys
docs, dec, i = [], json.JSONDecoder(), 0
s = sys.argv[1]
while i < len(s):
    while i < len(s) and s[i].isspace():
        i += 1
    if i < len(s):
        o, i = dec.raw_decode(s, i)
        docs.append(o)
a, b, c = docs
ok = a["hits"][0]["kind"] == "recipe" and a["hits"][0]["id"] == "black-card" and not a["hits"][0]["partial"]
ok = ok and {h["kind"] for h in a["hits"]} >= {"recipe", "style", "doc", "case"}
ok = ok and [h["kind"] for h in b["hits"]] and all(h["kind"] == "style" for h in b["hits"]) and b["hits"][0]["id"] == "risograph"
ok = ok and c["hits"][0]["file"] == "playbook/07-reverse-engineer.md" and c["hits"][0]["title"].endswith("› 1. 拿到帧")
sys.exit(0 if ok else 1)
PY
  then ok "know: a recipe by its name (black-card), a style by its craft (risograph), a playbook section by a platform's habit (07 §1), each kind in the answer, the same answer twice"
  else bad "know's answers (exit $rc): $(printf '%s' "$a" | tail -c 400)"; fi
  # the shot-grammar cards by the other names their own comment gives them (<!-- know: 荷兰角, … -->): the first recipe found
  a=""; for q in 荷兰角:dutch 鸟瞰:top-down 推镜头:push-in 摇镜头:pan 跟镜头:track 升降:crane 远景:long 近景:medium-close; do
    b=$(vh know "${q%%:*}" --kind recipe -n 1 --json 2>/dev/null | python3 -c 'import json, sys; h = json.load(sys.stdin)["hits"]; print(h[0]["id"] if h else "-")' 2>/dev/null)
    [ "$b" = "${q#*:}" ] || a="$a ${q%%:*} → ${b:-nothing} (not ${q#*:});"
  done
  if [ -z "$a" ]; then ok "know: a shot-grammar card by the names a seeker uses (荷兰角, 鸟瞰, 推镜头, 摇镜头, 跟镜头, 升降, 远景, 近景)"; else bad "know, the shot-grammar cards' other names:$a"; fi
  rc=0; for x in "know" "know --kind bogus 黑场" "know --index 黑场" "know -n -1 黑场"; do
    # shellcheck disable=SC2086
    a=$(vh $x 2>/dev/null); b=$?; [ "$b" = 2 ] && [ -z "$a" ] || { rc=1; bad "bin/vh $x: exit $b, stdout ${a:0:80}"; }
  done
  vh know zzqqxxkk >/dev/null 2>&1; [ $? = 1 ] || { rc=1; bad "know with nothing matched: not exit 1"; }
  [ "$rc" = 1 ] || ok "know: usage errors exit 2, nothing on stdout; nothing matched is 1"
  rm -rf "$t"
}

# bin/vh textcheck on its fixture (tools/textcheck/fixture/index.html: one read per case), with whatever headless Chrome
# the machine has (GitHub's runners come with Chrome); without one a skip on a machine of one's own, a failure on CI
# (no_chrome)
textcheck_checks() {
  local t a rc
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  a=$(vh textcheck tools/textcheck/fixture --out "$t/out" 2>&1); rc=$?
  case "$rc:$a" in 2:*"needs a headless Chrome"*) no_chrome "textcheck"; rm -rf "$t"; return ;; esac
  if [ $rc = 1 ] && python3 - "$t/out/textcheck.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
got = {r["text"]: (r["status"], sorted(f for f in ((r.get("worst") or {}).get("flags") or []) if f != "unstable")) for r in d["reads"]}
want = {"CLEAR": ("ok", []), "COVERED": ("fail", ["covered"]), "FAINT": ("fail", ["contrast"]), "OUTLINED": ("ok", []), "KINETIC": ("ok", []),
        "TWO · PARTS": ("ok", []), "GONE": ("fail", ["outside"]), "HIDDEN": ("fail", ["caption"]), "LATE": ("ok", []), "NOWHERE": ("not drawn", [])}
bad = [f"{k}: got {got.get(k)}, want {v}" for k, v in want.items() if got.get(k) != v]
late = [r for r in d["reads"] if r["text"] == "LATE"]
if not late or late[0].get("missingAt") != [0.4]: bad.append(f"LATE: missing at {late[0].get('missingAt') if late else None}, want [0.4]")
flagged = [e["text"] for e in d["extra"] if e["flagged"]]
if flagged != ["ghost"]: bad.append(f"outside the registry: flagged {flagged}, want ['ghost']")
bright = [c["text"] for c in d["captions"] if c["worst"]["close"] > 0.12]
if bright != ["a caption over a bright band"]: bad.append(f"captions over a bright picture: {bright}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
  then ok "textcheck: covered, faint, out-of-frame and captioned-over reads fail (exit 1); outlined, kinetic and split reads pass; a late read, a faint line outside the registry and a caption over a bright band warn"
  else bad "textcheck on its fixture (exit $rc): $(printf '%s' "$a" | tail -c 1200)"; fi
  # without the contract: nothing can be drawn on demand, so exit 2 and say what to add
  sed 's/window.__vh = { draw, texts: TEXTS };//' tools/textcheck/fixture/index.html > "$t/index.html"
  a=$(vh textcheck "$t" --out "$t/out2" 2>&1); rc=$?
  case "$rc:$a" in 2:*"window.film = { frame"*) ok "textcheck without the page contract exits 2 and names the line to add" ;;
    *) bad "textcheck without the contract: exit $rc: $(printf '%s' "$a" | tail -c 800)" ;; esac
  # the same fixture written with the page contract (window.film) instead of window.__vh: the same verdicts
  sed 's/window.__vh = { draw, texts: TEXTS };/window.film = { frame: draw, duration: 4, texts: TEXTS };/' tools/textcheck/fixture/index.html > "$t/index.html"
  a=$(vh textcheck "$t" --out "$t/out3" 2>&1); rc=$?
  if [ $rc = 1 ] && python3 -c "import json, sys; d = json.load(open(sys.argv[1], encoding='utf-8')); s = {r['text']: r['status'] for r in d['reads']}; sys.exit(0 if (s.get('CLEAR'), s.get('COVERED'), s.get('NOWHERE')) == ('ok', 'fail', 'not drawn') else 1)" "$t/out3/textcheck.json"
  then ok "textcheck reads window.film as it reads window.__vh"; else bad "textcheck with window.film (exit $rc): $(printf '%s' "$a" | tail -c 800)"; fi
  # the interface over the scene (window.film.ui and frame(t, { layer: "scene" })): a dashed line across the bar and a
  # busy picture under the caption are said, each once, the shaded and grainy paper is not; a warning, exit 0. A page whose
  # scene layer draws the interface too is said so, not checked
  a=$(vh textcheck tools/textcheck/fixture/ui.html --out "$t/out4" 2>&1); rc=$?
  if [ $rc = 0 ] && python3 -c "import json, sys; d = json.load(open(sys.argv[1])); g = [(s['name'], s['from'], s['to'], s['busy']) for s in d['ui']['spans']]; sys.exit(0 if g == [('chapter bar', 2.5, 3.5, False), ('caption', 4.5, 5.5, True)] else 1)" "$t/out4/textcheck.json"
  then ok "textcheck: a line crossing the chapter bar and a busy picture under the caption are said (scene drawn alone, shading and grain left out), exit 0"
  else bad "textcheck on the interface fixture (exit $rc): $(printf '%s' "$a" | tail -c 800)"; fi
  mkdir -p "$t/ig" && sed 's/if (!(o \&\& o.layer === "scene")) ui(t);/ui(t);/' tools/textcheck/fixture/ui.html > "$t/ig/index.html"
  a=$(vh textcheck "$t/ig" --out "$t/out5" 2>&1); rc=$?
  case "$rc:$a" in 0:*'frame(t, { layer: "scene" }) drew the chapter bar too'*) ok "textcheck: a page whose scene layer draws its interface too is said so, and that pass skipped" ;;
    *) bad "textcheck on a page that ignores the scene layer (exit $rc): $(printf '%s' "$a" | tail -c 600)" ;; esac
  rm -rf "$t"
}

# bin/vh frames (tools/film): frames drawn through the page contract (engines/CONTRACT.md) on its fixtures, with
# whatever headless Chrome the machine has; determinism on them, the frame timeouts, a browser stuck on its way out.
# render_checks and film_engine_checks take the page tools further (three groups, so the shards can share them out)
film_checks() {
  local t a rc
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  a=$(vh frames tools/film/fixture --at 0.5,2.5 --out "$t/a" 2>&1); rc=$?
  case "$rc:$a" in 2:*"needs a headless Chrome"*) no_chrome "frames"; rm -rf "$t"; return ;; esac
  vh frames tools/film/fixture --at 2.5 --out "$t/b" >/dev/null 2>&1
  if [ $rc = 0 ] && cmp -s "$t/a/index-t0002.500.png" "$t/b/index-t0002.500.png" && printf '%s' "$a" | grep -q "read Math.random" \
     && python3 -c "import struct, sys; d = open(sys.argv[1], 'rb').read(); sys.exit(0 if struct.unpack('>II', d[16:24]) == (320, 180) else 1)" "$t/b/index-t0002.500.png"
  then ok "frames: a page's frame at t is the same after another frame or alone (the clock holds Math.random at t, and says so), at its meta viewport size; ready is called as a method"
  else bad "frames on its fixture (exit $rc): $(printf '%s' "$a" | tail -c 800)"; fi
  a=$(vh frames tools/film/fixture/throws.html --at 1,2.5 --out "$t/c" 2>&1); rc=$?
  case "$rc:$a" in 1:*"t=2.5 s"*"no picture after 2 s"*) ok "frames: a frame that throws exits 1 and names its t" ;; *) bad "frames on a throwing page: exit $rc: $(printf '%s' "$a" | tail -c 600)" ;; esac
  a=$(vh frames tools/film/fixture/late.html --at 1,2.5 --out "$t/c2" 2>&1); rc=$?
  case "$rc:$a" in 1:*"a late error"*) ok "frames: an error a frame leaves behind (a timer) still fails the run" ;; *) bad "frames on a late error: exit $rc: $(printf '%s' "$a" | tail -c 600)" ;; esac
  a=$(vh frames tools/film/fixture/loaderr.html --at 1 --out "$t/c3" 2>&1); rc=$?
  case "$rc:$a" in 1:*"while loading: failed to load missing.png"*) ok "frames: a request that fails while loading fails the run" ;; *) bad "frames on a failed load: exit $rc: $(printf '%s' "$a" | tail -c 600)" ;; esac
  a=$(vh frames tools/film/fixture/nofilm.html --at 1 --out "$t/d" 2>&1); rc=$?
  case "$rc:$a" in 2:*"no window.film"*) ok "frames: a page without window.film exits 2" ;; *) bad "frames on a page without the contract: exit $rc: $(printf '%s' "$a" | tail -c 600)" ;; esac
  # a frame that never comes back (from 1 s on its promise never settles) stops the run at --frame-timeout, naming its t,
  # with the frames before it written: not at the whole run's --timeout (600 s)
  mkdir -p "$t/hang" && sed 's|if (t >= 2) throw new Error("no picture after 2 s");|if (t >= 1) return new Promise(() => {});|' tools/film/fixture/throws.html > "$t/hang/index.html"
  s0=$SECONDS; a=$(vh frames "$t/hang" --at 0.5,1.5 --frame-timeout 5 --out "$t/hang/o" 2>&1); rc=$?
  case "$rc:$a" in 2:*"t=1.5 s: no picture after 5 s (--frame-timeout)"*) [ -s "$t/hang/o/index-t0000.500.png" ] && [ $((SECONDS - s0)) -lt 120 ] \
      && ok "frames: a frame that never returns stops the run at --frame-timeout (exit 2), naming its t, the frames before it kept" \
      || bad "frames on a frame that never returns: $((SECONDS - s0)) s, $(ls "$t/hang/o" 2>&1)" ;;
    *) bad "frames on a frame that never returns: exit $rc: $(printf '%s' "$a" | tail -c 600)" ;; esac
  # a raised --timeout raises a frame's cap with it (a page whose frames are that slow), unless --frame-timeout says otherwise
  a=$(vh frames tools/film/fixture --at 0.5 --timeout 300 --out "$t/ft" 2>&1); b=$(vh frames tools/film/fixture --at 0.5 --timeout 300 --frame-timeout 7 --out "$t/ft" 2>&1)
  case "$a|$b" in *"a frame may take 300 s (--timeout)"*"|"*"a frame may take 7 s (--frame-timeout)"*) ok "frames: --timeout alone is a frame's cap too; --frame-timeout wins" ;;
    *) bad "frames: a frame's cap from --timeout: $(printf '%s' "$a" | head -1) | $(printf '%s' "$b" | head -1)" ;; esac
  # the other page tools stop at --frame-timeout too (exit 2, naming the t), not at their whole run's --timeout: fonts,
  # determinism and textcheck on the page above, whose frames never return from 1 s on; cues on a page whose cues getter
  # never returns (its script stuck in a loop)
  printf '%s\n' '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=160, height=90"></head><body><script>' \
    'window.film = { duration: 3, frame() {}, get cues() { for (;;) {} } };</script></body></html>' > "$t/hang/cues.html"
  s0=$SECONDS
  a=$(vh fonts check "$t/hang" --frame-timeout 3 --out "$t/hang/f" 2>&1); r1=$?
  b=$(vh determinism "$t/hang" --at 0.5,1.5 --frame-timeout 3 --out "$t/hang/d" 2>&1); r2=$?
  c=$(vh textcheck "$t/hang" --frame-timeout 3 --out "$t/hang/tc" 2>&1); r3=$?
  d=$(vh cues "$t/hang/cues.html" --frame-timeout 3 2>&1); r4=$?
  case "$r1:$r2:$r3:$r4|$a|$b|$c|$d" in "2:2:2:2|"*"t=1.25 s: no picture after 3 s (--frame-timeout)"*"|"*"A t=1.5 s: no picture after 3 s (--frame-timeout)"*"|"*"t=1.5 s: no picture after 3 s (--frame-timeout)"*"|"*"reading window.film.cues: no answer after 3 s (--frame-timeout)"*)
      [ $((SECONDS - s0)) -lt 150 ] && ok "fonts, determinism, textcheck and cues stop at --frame-timeout (exit 2), naming the frame or the read" \
        || bad "frame timeouts of fonts, determinism, textcheck, cues took $((SECONDS - s0)) s" ;;
    *) bad "frame timeouts (exit $r1:$r2:$r3:$r4): $(printf '%s' "$a" | tail -c 200) | $(printf '%s' "$b" | tail -c 200) | $(printf '%s' "$c" | tail -c 200) | $(printf '%s' "$d" | tail -c 200)" ;; esac
  # a browser stuck on its way out (it answers, then ignores Browser.close and SIGTERM: a stand-in on the DevTools pipe)
  # is killed: close() returns within seconds, so no tool waits on it until its watchdog
  printf '%s\n' 'import json, os, signal, time' 'signal.signal(signal.SIGTERM, signal.SIG_IGN); buf = b""' \
    'while b"Browser.getVersion" not in buf: buf += os.read(3, 65536)' \
    'm = json.loads(buf.split(b"\0")[0]); os.write(4, json.dumps({"id": m["id"], "result": {"product": "Stub/1"}}).encode() + b"\0")' \
    'while True: time.sleep(1)' > "$t/stuck.py"
  printf '#!/bin/sh\nexec python3 "%s"\n' "$t/stuck.py" > "$t/stuck"; chmod +x "$t/stuck"
  a=$(node --input-type=module -e 'import { launch } from "./tools/textcheck/browser.mjs";
const b = await launch(process.argv[1]); const t0 = Date.now();
const r = await Promise.race([b.close().then(() => "closed"), new Promise((ok) => setTimeout(() => ok("hung"), 30000))]);
console.log(r, Math.round((Date.now() - t0) / 1000)); process.exit(0);' "$t/stuck" 2>&1)
  case "$a" in "closed "[0-9]|"closed 1"[0-9]) ok "browser: one that ignores Browser.close and SIGTERM is killed, and close() returns ($a s)" ;; *) bad "browser close on a stuck browser: $a" ;; esac
  a=$(vh frames tools/film/fixture --at 5 --out "$t/e" 2>&1); rc=$?
  case "$rc:$a" in 2:*"outside the film"*) ok "frames: a time outside the film exits 2" ;; *) bad "frames outside the film: exit $rc: $(printf '%s' "$a" | tail -c 600)" ;; esac
  if command -v ffmpeg >/dev/null; then
    a=$(vh frames tools/film/fixture --strip 1:1.5 --fps 10 --out "$t/f" 2>&1); rc=$?
    if [ $rc = 0 ] && [ -s "$t/f/index-strip-1-1.5.jpg" ] && [ "$(ls "$t/f/index-strip-1-1.5" | wc -l | tr -d ' ')" = 5 ]; then ok "frames --strip: every frame of a span and one picture of them"
    else bad "frames --strip (exit $rc): $(printf '%s' "$a" | tail -c 600)"; fi
  fi
  a=$(vh determinism tools/film/fixture --samples 2 --out "$t/g" 2>&1); rc=$?
  case "$rc:$a" in 0:*"without the host's clock the frames differ"*"holds, every frame identical"*) ok "determinism: a page that reads Math.random holds under the host's clock, and is told it leans on it" ;;
    *) bad "determinism on its fixture: exit $rc: $(printf '%s' "$a" | tail -c 700)" ;; esac
  a=$(vh determinism tools/film/fixture/stateful.html --samples 2 --out "$t/h" 2>&1); rc=$?
  case "$rc:$a" in 1:*"does not hold"*) ok "determinism: a frame that depends on the frames before it does not hold (exit 1)" ;;
    *) bad "determinism on a stateful page: exit $rc: $(printf '%s' "$a" | tail -c 700)" ;; esac
  rm -rf "$t"
}
film_chrome() {   # film_chrome: whether the page tools find a headless Chrome (asked of a page that is not there: none starts)
  case $(vh frames "$ROOT/tools/film/fixture/no-such-page.html" --at 0 2>&1) in *"needs a headless Chrome"*) return 1 ;; esac
}

# bin/vh render and patch (tools/film) on the same fixtures: chunks and keyframes, motion blur and alpha, the queue and
# its resume, the disk floor, patch's windows, versions, --in-place, proxy and thumbs (where ffmpeg and ffprobe are)
render_checks() {
  local t a rc
  film_chrome || { no_chrome "render"; return; }
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  if command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null; then
    a=$(vh render tools/film/fixture --workers 2 --gop 30 --out "$t/r/film.mp4" 2>&1); rc=$?
    if [ $rc = 0 ] && python3 - "$t/r/film.mp4" <<'PY'
import json, subprocess, sys
f = sys.argv[1]
st = json.loads(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=nb_frames,width,height,pix_fmt,color_range,color_space",
                                "-of", "json", f], capture_output=True, text=True).stdout)["streams"][0]
keys = [l.split(",")[0] for l in subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time,flags", "-of", "csv=p=0", f],
                                                capture_output=True, text=True).stdout.split() if "K" in l.split(",")[1]]
side = json.load(open(f + ".render.json"))
ok = (st["nb_frames"], st["width"], st["height"], st["pix_fmt"], st["color_range"], st["color_space"]) == ("90", 320, 180, "yuv420p", "tv", "bt709")
ok = ok and [round(float(k), 3) for k in keys] == [0.0, 1.0, 2.0] and side["frames"] == 90 and side["encoder"]["gop"] == 30
sys.exit(0 if ok else 1)
PY
    then ok "render: every frame, BT.709 tv range, a keyframe exactly every --gop frames across the chunks, and how it was made beside it"
    else bad "render on its fixture (exit $rc): $(printf '%s' "$a" | tail -c 700)"; fi
    # --motion-blur (tools/film/blur.mjs) on tools/film/fixture/blur.html, a white square moving 16 px a frame. render, 4
    # sub-frames over a whole frame (--shutter 1) centred on each frame's time: frame 2's edges are ramps of 1/4, 2/4 and
    # 3/4, 4 px each (12 px a side), its light kept (30 px of white across); frame 5, the last before the page's hard cut
    # 0.1 frame after it, has none of the next shot's grey; frame 0 none of before the film, frame 14 none of after the
    # page's end (the page paints those white; its last shot ends before the page does, so the page's end is what cuts
    # that shutter short). patch draws frame 2's GOP again in a fresh browser with the film's shutter, the frames around it
    # identical (PSNR ∞); --motion-blur 1 is the render without it, packet for packet (the fixture's first GOP, just
    # rendered). frames, 4 sub-frames over the default half frame: frame 2's levels exact (2 px steps), frame 5 none of the
    # grey, frame 14 none of the white, as render draws them
    mkdir -p "$t/mb"
    a=$(vh render tools/film/fixture/blur.html --motion-blur 4 --shutter 1 --gop 5 --workers 1 --out "$t/mb/film.mp4" 2>&1); rc=$?
    b=$(vh patch "$t/mb/film.mp4" --frames 2-2 --workers 1 2>&1); rc2=$?
    c=$(vh render tools/film/fixture --frames 0:30 --gop 30 --workers 1 --motion-blur 1 --out "$t/mb/one.mp4" 2>&1); rc3=$?
    d=$(vh frames tools/film/fixture/blur.html --at 0.0667,0.1667,0.4667 --motion-blur 4 --out "$t/mb/f" 2>&1); rc4=$?
    if [ "$rc:$rc2:$rc3:$rc4" = "0:0:0:0" ] && grep -q "6 of the 15 frames drawn moved" <<<"$a" && grep -q "reach the keyframes at least ∞ dB ✓" <<<"$b" \
       && python3 - "$t/mb" "$t/r/film.mp4" <<'PY'
import json, subprocess, sys
d, ref = sys.argv[1], sys.argv[2]
W, H = 160, 90
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", f"{d}/film.mp4", "-f", "rawvideo", "-pix_fmt", "yuv420p", "-"], capture_output=True).stdout
n = W * H * 3 // 2
Y = [raw[i * n:i * n + W * H] for i in range(len(raw) // n)]
row = lambda k, r: Y[k][r * W:(r + 1) * W]   # noqa: E731
ramp = [x for x, v in enumerate(row(2, 45)) if 38 < v < 213]   # luma between 10 % and 90 % of white
light = sum(min(1, max(0, (v - 16) / 219)) for v in row(2, 45))
ok = len(Y) == 15 and ramp == list(range(36, 48)) + list(range(66, 78)) and abs(light - 30) < 0.6
ok = ok and max(row(5, 10)) <= 18 and max(row(0, 10)) <= 18 and min(Y[6]) >= 124 and max(Y[14]) <= 128
mb = json.load(open(f"{d}/film.mp4.render.json")).get("motion_blur") or {}
ok = ok and (mb.get("samples"), mb.get("shutter"), len(mb.get("version") or "")) == (4, 1, 64) and "motion_blur" not in json.load(open(f"{d}/one.mp4.render.json"))
pk = lambda f: [l.split(",")[-1].strip() for l in subprocess.run(["ffmpeg", "-v", "error", "-i", f, "-map", "0:v:0", "-c", "copy", "-f", "framemd5", "-"],   # noqa: E731
                                                                     capture_output=True, text=True).stdout.splitlines() if l and not l.startswith("#")]
one, whole = pk(f"{d}/one.mp4"), pk(ref)
ok = ok and len(one) == 30 and one == whole[:30]
png = lambda t: subprocess.run(["ffmpeg", "-v", "error", "-i", f"{d}/f/blur-t{t}.png", "-f", "rawvideo", "-pix_fmt", "gray", "-"], capture_output=True).stdout   # noqa: E731
g = png("0000.067")
steps = [v for v in g[45 * W:46 * W] if 0 < v < 255]   # 1/4, 2/4, 3/4 of white (an ffmpeg that truncates the mean: one less)
ok = ok and len(steps) == 12 and all(abs(v - e) <= 1 for v, e in zip(steps, [64, 64, 128, 128, 191, 191, 191, 191, 128, 128, 64, 64]))
cut, end = png("0000.167"), png("0000.467")   # frame 5 (before the cut) on black, frame 14 (the last) grey
ok = ok and len(cut) == W * H and max(cut[10 * W:11 * W]) == 0 and len(end) == W * H and set(end) <= {127, 128, 129}
sys.exit(0 if ok else 1)
PY
    then ok "render --motion-blur: 4 sub-frames over a whole frame blur a moving edge into steps of 1/4, 2/4, 3/4, 12 px a side, its light kept; no frame mixes in the next shot across the page's hard cut, nor a time before or after the page; patch draws a GOP again with the film's shutter (PSNR ∞); --motion-blur 1 is the render without it, packet for packet; frames --motion-blur draws the frames before the cut and at the end as render does"
    else bad "render --motion-blur ($rc, $rc2, $rc3, $rc4): $(printf '%s' "$a" | tail -c 300) | $(printf '%s' "$b" | tail -c 300) | $(printf '%s' "$c" | tail -c 200) | $(printf '%s' "$d" | tail -c 200)"; fi
    # a render stopped with blurred chunks kept, then the same command without the blur, or with --motion-blur 1: those
    # chunks are not taken, it starts over (the record compares the keys either render has). The page hangs on a time off
    # the frame grid after 0.1 s, so the blurred render keeps its first chunk and stops at --frame-timeout, while an
    # unblurred one draws only grid times. One stopped render: its chunk and record copied back before each of the two
    sed 's|frame(t) {|frame(t) { if (t > 0.1 \&\& Math.abs(t * 30 - Math.round(t * 30)) > 1e-6) return new Promise(() => {});|' tools/film/fixture/blur.html > "$t/mb/stops.html"
    vh render "$t/mb/stops.html" --motion-blur 4 --gop 3 --workers 1 --frame-timeout 2 --no-estimate --out "$t/mb/resume.mp4" >/dev/null 2>&1; rc=$?
    cp -R "$t/mb/.resume.mp4.parts" "$t/mb/stopped" 2>/dev/null
    for flag in "" "--motion-blur 1"; do
      say=${flag:-"no --motion-blur"}
      rm -rf "$t/mb/.resume.mp4.parts"; cp -R "$t/mb/stopped" "$t/mb/.resume.mp4.parts" 2>/dev/null
      # shellcheck disable=SC2086
      a=$(vh render "$t/mb/stops.html" $flag --gop 3 --workers 1 --no-estimate --out "$t/mb/resume.mp4" 2>&1); rc2=$?
      if [ "$rc:$rc2" = 1:0 ] && grep -q "the 1 chunks kept from an earlier render are not used (changed: the motion blur); starting over" <<<"$a" \
         && python3 -c 'import subprocess, sys
y = subprocess.run(["ffmpeg", "-v", "error", "-i", sys.argv[1], "-vf", "select=eq(n\\,2)", "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "gray", "-"], capture_output=True).stdout
sys.exit(0 if len(y) == 160 * 90 and not [v for v in y[45 * 160:46 * 160] if 38 < v < 213] else 1)' "$t/mb/resume.mp4"
      then ok "render, $say: the blurred chunk a stopped render kept is not taken (the motion blur changed), the film drawn sharp"
      else bad "render, $say, over a blurred chunk a stopped render kept (exit $rc:$rc2): $(printf '%s' "$a" | head -c 400)"; fi
    done
    # canvas-film's fadeOut reaches black on the last frame, which is drawn one frame before the film's end; the frames before it are not black yet
    vh new short fo --engine canvas-film --dir "$t" >/dev/null 2>&1; p=$(ls -d "$t"/*-fo 2>/dev/null)
    printf '%s\n' 'Object.assign(FILM, { width: 160, height: 90, timeline: false, duration: 2, grain: 0, fadeOut: 0.5, images: {} });' \
      'const SHOTS = [{ id: "S01", at: 0, draw() { X.fillStyle = "#e0e0e0"; X.fillRect(0, 0, W, H); } }];' > "$p/src/50-shots.js"
    a=$(vh frames "$p" --at 1.8,1.966667 --motion-blur 4 --out "$t/fo" 2>&1); rc=$?
    # a machine without the template's faces (the Linux runner) draws in a fallback and says so, which is exit 1; that alone is fine here
    if [ $rc = 1 ] && printf '%s' "$a" | grep -q 'fonts this machine does not have' \
      && ! printf '%s\n' "$a" | grep -E 'while loading:|^  t=[0-9.]+ s:|just after the last frame' | grep -qv 'fonts this machine does not have'; then rc=0; fi
    if [ $rc = 0 ] && python3 - "$t/fo" <<'PY'
import glob, subprocess, sys
fs = sorted(glob.glob(sys.argv[1] + "/*.png"))
top = [max(subprocess.run(["ffmpeg", "-v", "error", "-i", f, "-f", "rawvideo", "-pix_fmt", "gray", "-"], capture_output=True).stdout) for f in fs]
sys.exit(0 if len(top) == 2 and top[0] > 20 and top[1] == 0 else 1)
PY
    then ok "canvas-film: fadeOut is black on the last frame, shutter and all, and not on the frames before it"
    else bad "canvas-film fadeOut on the last frame (exit $rc): $(printf '%s' "$a" | tail -c 300)"; fi
    # --alpha: a page that leaves its background clear gives ProRes 4444 with that alpha; a page that paints one is told so;
    # an .mp4 is refused (no alpha there), and patch refuses an alpha film
    mkdir -p "$t/al"
    printf '%s\n' '<!doctype html><html><head><meta name="viewport" content="width=320, height=180"><style>html,body{margin:0;background:transparent}</style></head>' \
      '<body><canvas id="c" width="320" height="180"></canvas><script>const X = document.getElementById("c").getContext("2d");' \
      'window.film = { duration: 2.5, fps: 30, frame(t) { X.clearRect(0, 0, 320, 180); X.fillStyle = "#dc3c28"; X.fillRect(20 + 100 * t, 50, 60, 60); } };</script></body></html>' > "$t/al/clear.html"
    sed -e 's/background:transparent/background:#123/' "$t/al/clear.html" > "$t/al/opaque.html"
    a=$(vh render "$t/al/clear.html" --alpha --workers 2 --gop 30 --out "$t/al/clear.mov" 2>&1); rc=$?
    b=$(vh render "$t/al/opaque.html" --alpha --workers 1 --out "$t/al/opaque.mov" 2>&1); rc2=$?
    c=$(vh render "$t/al/clear.html" --alpha --out "$t/al/clear.mp4" 2>&1); rc3=$?
    d=$(vh patch "$t/al/clear.mov" --frames 10-20 2>&1); rc4=$?
    if [ "$rc:$rc2:$rc3:$rc4" = "0:0:2:2" ] && grep -q "every pixel of the frames looked at is opaque" <<<"$b" && ! grep -q "opaque" <<<"$a" \
       && grep -q "goes in a .mov" <<<"$c" && grep -q "transparent film" <<<"$d" && python3 - "$t/al/clear.mov" <<'PY'
import json, subprocess, sys
f = sys.argv[1]
st = json.loads(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name,profile,nb_frames,pix_fmt,color_space",
                                "-of", "json", f], capture_output=True, text=True).stdout)["streams"][0]
px = subprocess.run(["ffmpeg", "-v", "error", "-i", f, "-vf", "select=eq(n\\,30)", "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgba", "-"], capture_output=True).stdout
at = lambda x, y: tuple(px[(y * 320 + x) * 4:(y * 320 + x) * 4 + 4])   # noqa: E731
side = json.load(open(f + ".render.json"))
ok = (st["codec_name"], st["profile"], st["nb_frames"], st["color_space"]) == ("prores", "4444", "75", "bt709") and st["pix_fmt"].startswith("yuva444p")
ok = ok and at(5, 5)[3] == 0 and at(150, 80)[3] == 255 and abs(at(150, 80)[0] - 0xdc) <= 2 and side.get("alpha") is True and side["encoder"]["codec"] == "prores_ks"
ok = ok and "crf" not in side["encoder"] and "preset" not in side["encoder"]   # x264's settings do not apply to ProRes
ok = ok and side["encoder"]["qscale"] == 6 and side["encoder"]["alpha_bits"] == 8   # without these, prores_ks gives colour 20 times its budget and alpha 16 lossless bits
sys.exit(0 if ok else 1)
PY
    then ok "render --alpha: ProRes 4444 with the page's own alpha (clear where it draws nothing, opaque where it does), joined over chunks; a page that paints its background is told, an .mp4 refused, patch refuses it"
    else bad "render --alpha ($rc, $rc2, $rc3, $rc4): $(printf '%s' "$a" | tail -c 300) | $(printf '%s' "$b" | tail -c 300) | $c | $d"; fi
    # --alpha --motion-blur: the trail of a red square on a clear page keeps its red while its alpha ramps (the mean of the
    # premultiplied colours), not a darker red where the clear pixels' black would count
    printf '%s\n' '<!doctype html><html><head><meta name="viewport" content="width=160, height=90"><style>html,body{margin:0;background:transparent}</style></head>' \
      '<body><canvas id="c" width="160" height="90"></canvas><script>const X = document.getElementById("c").getContext("2d");' \
      'window.film = { duration: 0.2, fps: 30, frame(t) { X.clearRect(0, 0, 160, 90); X.fillStyle = "#dc3c28"; X.fillRect(10 + 480 * t, 30, 30, 30); } };</script></body></html>' > "$t/al/trail.html"
    a=$(vh render "$t/al/trail.html" --alpha --motion-blur 4 --workers 1 --out "$t/al/trail.mov" 2>&1); rc=$?
    if [ $rc = 0 ] && python3 - "$t/al/trail.mov" <<'PY'
import subprocess, sys
px = subprocess.run(["ffmpeg", "-v", "error", "-i", sys.argv[1], "-vf", "select=eq(n\\,2)", "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgba", "-"], capture_output=True).stdout
ramp = [tuple(px[(45 * 160 + x) * 4:(45 * 160 + x) * 4 + 4]) for x in range(39, 45)]   # the trailing edge of frame 2
ok = len(ramp) == 6 and all(abs(p[3] - a) <= 2 and abs(p[0] - 0xdc) <= 3 and abs(p[1] - 0x3c) <= 3 and abs(p[2] - 0x28) <= 3 for p, a in zip(ramp, [64, 64, 128, 128, 192, 192]))
sys.exit(0 if ok else 1)
PY
    then ok "render --alpha --motion-blur: a moving edge's alpha ramps while its colour stays (the premultiplied mean)"
    else bad "render --alpha --motion-blur (exit $rc): $(printf '%s' "$a" | tail -c 400)"; fi
    # what reads a transparent film: mux keeps it (and its alpha) in a .mov and says so for an .mp4; deliver makes no upload of it
    ffmpeg -v error -f lavfi -i "sine=frequency=440:duration=2.5" -ac 2 -ar 48000 "$t/al/mix.wav"
    e=$(vh mux "$t/al/clear.mov" "$t/al/mix.wav" "$t/al/final.mp4" 2>&1); rc=$?
    vh mux "$t/al/clear.mov" "$t/al/mix.wav" "$t/al/final.mov" >/dev/null 2>&1; rc2=$?
    f=$(vh deliver "$t/al/clear.mov" --psnr off 2>&1); rc3=$?
    if [ "$rc:$rc2:$rc3" = "2:0:2" ] && grep -q "name the output .mov" <<<"$e" && grep -q "alpha channel" <<<"$f" && [ ! -e "$t/al/clear.upload.mp4" ] \
       && ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$t/al/final.mov" | grep -q '^yuva'
    then ok "a transparent film: mux keeps it, alpha and all, in a .mov and refuses an .mp4; deliver makes no upload copy of it"
    else bad "mux / deliver on an alpha film ($rc, $rc2, $rc3): $e | $f"; fi
    a=$(vh render tools/film/fixture --out "$t/r/film.mp4" 2>&1); rc=$?
    [ $rc = 0 ] && printf '%s' "$a" | grep -q '^render: done · the sound goes on with bin/vh mux$' \
      && ok "render: a second render of the same file after the first one ended is not locked out, and ends with its done line" || bad "render again (exit $rc): $(printf '%s' "$a" | tail -c 400)"
    a=$(OVH_FREE_BYTES=1000 vh render tools/film/fixture --out "$t/r/full.mp4" 2>&1); rc=$?
    case "$rc:$a" in 2:*"needed at the peak"*"GB free on that disk"*) ok "render: a disk too full for even a flat film stops it before a frame is drawn (exit 2)" ;;
      *) bad "render on a full disk: exit $rc: $(printf '%s' "$a" | tail -c 400)" ;; esac
    # the queue and the resume, on a page whose frames cost unevenly (tools/film/fixture/uneven.html: from 2 s on 30 ms
    # each, frame 75 12 s): chunks of one GOP, so 3 workers make the video 1 makes (PSNR: separate browsers). A render
    # whose frame 75 passes --frame-timeout 8 keeps the 5 chunks it finished; with the page edited they are not used;
    # the same command then draws only the last chunk, and the video is the one a whole render makes. The disk floor of a
    # resume is what it writes: the chunk left and the joined copy, the kept chunks' bytes in it (a disk 1000 bytes over
    # those refuses it, the chunks kept); its glyph check (the page writes a word) says the kept chunks' frames were not checked
    mkdir -p "$t/q" && sed 's|x.fillStyle = "#fc0";|x.font = "16px sans-serif"; x.fillStyle = "#fff"; x.fillText("chunk", 8, 24); x.fillStyle = "#fc0";|' tools/film/fixture/uneven.html > "$t/q/u.html"
    vh render "$t/q/u.html" --workers 1 --gop 15 --out "$t/q/one.mp4" >/dev/null 2>&1
    a=$(vh render "$t/q/u.html" --workers 3 --gop 15 --out "$t/q/three.mp4" 2>&1); rc=$?
    b=$(vh render "$t/q/u.html" --workers 2 --gop 15 --frame-timeout 8 --out "$t/q/r.mp4" 2>&1); rc2=$?
    kb=$(python3 -c 'import os, sys; d = sys.argv[1]; print(sum(os.path.getsize(os.path.join(d, f)) for f in os.listdir(d) if f.startswith("part")))' "$t/q/.r.mp4.parts" 2>/dev/null || echo 0)
    e=$(OVH_FREE_BYTES=$((kb + 1000)) vh render "$t/q/u.html" --workers 2 --gop 15 --frame-timeout 8 --out "$t/q/r.mp4" 2>&1); rc5=$?
    case "$rc5:$e" in 2:*"needed at the peak for the 15 frames left to draw and the joined copy (5 chunks kept"*)
        kn=0; for kf in "$t/q/.r.mp4.parts"/part*.mp4; do [ ! -e "$kf" ] || kn=$((kn + 1)); done; [ $kn = 5 ] && ok "render: a resume's disk floor is the chunk left and the joined copy with the kept chunks' bytes; refused, it keeps them" \
          || bad "render: a resume refused for the disk did not keep its chunks: $(ls "$t/q/.r.mp4.parts" 2>&1)" ;;
      *) bad "render resume on a disk with room for the kept chunks only (exit $rc5, $kb bytes kept): $(printf '%s' "$e" | tail -c 500)" ;; esac
    printf '<!-- edited -->\n' >> "$t/q/u.html"
    c=$(vh render "$t/q/u.html" --workers 2 --gop 15 --frame-timeout 8 --out "$t/q/r.mp4" 2>&1); rc3=$?
    d=$(vh render "$t/q/u.html" --workers 2 --gop 15 --out "$t/q/r.mp4" 2>&1); rc4=$?
    if [ "$rc:$rc2:$rc3:$rc4" = 0:1:1:0 ] && printf '%s' "$b" | grep -q '5 of 6 chunks are kept' && printf '%s' "$c" | grep -q 'not used (changed: .*u\.html)' \
      && printf '%s' "$d" | grep -q 'resuming: 5 of 6 chunks kept' && printf '%s' "$d" | grep -q 'glyphs: checked in the 15 frames drawn now; the 75 frames of the 5 kept' \
      && [ ! -e "$t/q/.r.mp4.parts" ] && python3 - "$t/q" <<'PY'
import json, re, subprocess, sys
d = sys.argv[1]
def psnr(a, b):
    r = subprocess.run(["ffmpeg", "-v", "info", "-i", a, "-i", b, "-lavfi", "psnr", "-f", "null", "-"], capture_output=True, text=True).stderr
    m = re.findall(r"average:(inf|[\d.]+)", r)
    return float(m[-1]) if m else 0
side = json.load(open(d + "/r.mp4.render.json"))
ok = side["chunks"] == [[k, k + 15] for k in range(0, 90, 15)] and side["reused_chunks"] == 5 and side["frames"] == 90
sys.exit(0 if ok and psnr(d + "/one.mp4", d + "/three.mp4") >= 45 and psnr(d + "/one.mp4", d + "/r.mp4") >= 45 else 1)
PY
    then ok "render: one-GOP chunks taken in turn (3 workers make what 1 makes); a timed-out frame keeps the finished chunks, an edited page starts over, the same command resumes"
    else bad "render queue and resume: exit $rc:$rc2:$rc3:$rc4: $(printf '%s' "$b$c$d" | tail -c 900)"; fi
    # bin/vh patch passes --frame-timeout to the render of its frames: frames 74-76 of the film above take the GOP from 60,
    # and frame 75 (12 s) is past 2 s
    a=$(vh patch "$t/q/one.mp4" --frames 74-76 --frame-timeout 2 --out "$t/q/p.mp4" 2>&1); rc=$?
    case "$rc:$a" in 1:*"no picture after 2 s (--frame-timeout)"*"rendering frames"*"failed"*) ok "patch: --frame-timeout goes to the render of its frames" ;;
      *) bad "patch --frame-timeout (exit $rc): $(printf '%s' "$a" | tail -c 500)" ;; esac
    # the estimate, the page's own fps and a relative --out, from another folder: the canvas-film template (made for 30 fps)
    # at --fps 60 is over 600 frames, so it is estimated; the disk has room for a flat film (7.2 MB at the peak) but not
    # for what was measured (about 12 MB)
    mkdir -p "$t/e"
    a=$(cd "$t/e" && OVH_FREE_BYTES=8000000 "$VH_BASH" "$ROOT/bin/vh" render "$ROOT/engines/canvas-film/template" --fps 60 --out rel/f.mp4 2>&1); rc=$?
    case "$rc:$a" in
      2:*"--out rel/f.mp4 is from the current folder: "*"/e/rel/f.mp4, outside the project"*"drawn at 60 fps (--fps), the page says 30"*"estimate ("*" frames in about"*"is needed at the peak and 8 MB is free"*)
        [ ! -e "$t/e/rel/.f.mp4.parts" ] && ok "render: a long span is estimated first and refused on a disk that cannot hold it; --fps unlike the page's and an --out outside the project are said" \
          || bad "render: the refused estimate left $t/e/rel/.f.mp4.parts behind" ;;
      *) bad "render estimate, fps and --out (exit $rc): $(printf '%s' "$a" | tail -c 900)" ;;
    esac
    # bin/vh patch: the fixture rendered from 0.5 s with a keyframe every 20 frames (not a whole number of milliseconds) in
    # a folder whose name a filter graph would choke on; then its square turned blue from 1.4 s up to 1.7 s (the film's
    # frames 27–35) and those frames put back: 20–39 drawn again, the rest the film's own bytes and times. Naming only 27–29
    # leaves 30–35 changed outside the span: refused, the film untouched. A film without its sidecar is refused at once
    mkdir -p "$t/p, x" && cp tools/film/fixture/index.html "$t/p, x/index.html" && printf '# BRIEF\n' > "$t/p, x/BRIEF.md"   # a project: its activity log below
    vh render "$t/p, x" --range 0.5:2.5 --gop 20 --workers 2 --out "$t/p, x/out/film.mp4" >/dev/null 2>&1
    sed 's/x.fillStyle = "#fc0";/x.fillStyle = t >= 1.4 \&\& t < 1.7 ? "#0cf" : "#fc0";/' tools/film/fixture/index.html > "$t/p, x/index.html"
    s0=$(cksum < "$t/p, x/out/film.mp4")
    a=$(vh patch "$t/p, x/out/film.mp4" --frames 27-29 2>&1); rc=$?
    b=$(vh patch "$t/p, x/out/film.mp4" --frames 27-35 --verify full 2>&1); rc2=$?
    if [ $rc = 1 ] && printf '%s' "$a" | grep -q 'frames 30–35 are outside 27–29' && [ -s "$t/p, x/out/film.failed.mp4" ] && [ "$(cksum < "$t/p, x/out/film.mp4")" = "$s0" ] \
      && [ $rc2 = 0 ] && printf '%s' "$b" | grep -q '20–39 drawn again' && printf '%s' "$b" | grep -q 'frames: 60 (the film: 60) ✓' \
      && printf '%s' "$b" | grep -q "packets outside 20–39: 40 the film's own ✓" && python3 - "$t/p, x/out/film.patched.mp4" <<'PY'
import json, subprocess, sys
f = sys.argv[1]
def px(t):   # the square's colour at the film's t (the page's t + 0.5): blue inside the page's 1.4–1.7 s, yellow outside
    r = subprocess.run(["ffmpeg", "-v", "error", "-ss", str(t), "-i", f, "-frames:v", "1", "-vf", f"crop=8:8:{int(36 + 80 * (t + 0.5))}:106,scale=1:1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True)
    return tuple(r.stdout[:3])
side = json.load(open(f + ".render.json"))
blue, yellow = px(1.0), px(0.7)
sys.exit(0 if blue[2] > blue[0] + 80 and yellow[0] > yellow[2] + 80 and side["patches"][0]["frames"] == [27, 35] and side["page"] == "../index.html" else 1)
PY
    then ok "patch: frames put back between keyframes, every packet outside them the film's own; an edit reaching past the frames named is refused, the film untouched"
    else bad "patch on the fixture: exit $rc / $rc2: $(printf '%s' "$a$b" | tail -c 900)"; fi
    # the render of a patch's frames is a step: its "render: done · the sound goes on with bin/vh mux" is left out, so the
    # patch's own last line is the only one that says it is done. A film that failed the patch's checks is kept as
    # <film>.failed.mp4 or the next free name (.failed-2.mp4): an earlier one is never overwritten, and the output names both
    cp -R "$t/p, x" "$t/p3"   # a copy: the activity log of the project below counts its commands
    k0=$(cksum < "$t/p3/out/film.failed.mp4")
    c=$(vh patch "$t/p3/out/film.mp4" --frames 27-29 2>&1); rc3=$?
    if [ $rc3 = 1 ] && ! printf '%s' "$a$b$c" | grep -q 'render: done' && printf '%s' "$b" | grep -q '^patch: done in ' \
      && [ -s "$t/p3/out/film.failed-2.mp4" ] && [ "$(cksum < "$t/p3/out/film.failed.mp4")" = "$k0" ] \
      && printf '%s' "$c" | grep -q 'the new one is in .*film.failed-2.mp4 to look at (.*film.failed.mp4 was there already and is left as it is)'
    then ok "patch: its render's \"render: done\" line is left out (patch says when it is done); a second failed patch keeps its film as .failed-2.mp4, the first one untouched"
    else bad "patch's last line and its failed films (exit $rc3): $(printf '%s' "$b" | tail -n 2 | tail -c 300) | $(printf '%s' "$c" | tail -n 1 | tail -c 400) | $(ls "$t/p3/out" | tr '\n' ' ')"; fi
    cp "$t/p, x/out/film.mp4" "$t/p, x/out/bare.mp4"
    a=$(vh patch "$t/p, x/out/bare.mp4" --frames 1-2 2>&1); rc=$?
    case "$rc:$a" in 2:*"no "*"bare.mp4.render.json"*) ok "patch: a film without its sidecar is refused at once (exit 2)" ;; *) bad "patch without a sidecar: exit $rc: $(printf '%s' "$a" | tail -c 400)" ;; esac
    # the activity log of that project: render's progress and note, and the ends node wrote itself (bin/vh exec'd into it)
    cat > "$t/act.py" <<'PY'
import json, sys
runs = {}
for r in map(json.loads, open(sys.argv[1], encoding="utf-8")):
    runs.setdefault(r["run"], []).append(r)
print(" | ".join(" ".join(r["event"] + (":%s" % r["exit"] if r["event"] == "end" else "") for r in rs) for rs in runs.values()))
render = next(rs for rs in runs.values() if rs[0]["cmd"] == "render")
note = next(r for r in render if r["event"] == "note")
sys.exit(0 if note["outputs"] == ["out/film.mp4", "out/film.mp4.render.json"] and [r["done"] for r in render if r["event"] == "progress"][-1] == 60 else 1)
PY
    a=$(python3 "$t/act.py" "$t/p, x/.ovh/activity.jsonl" 2>&1); rc=$?
    case "$rc:$a" in "0:start progress progress note end:0 | start note end:1 | start note end:0 | start end:2") ok "activity: render logs its progress and what it wrote, patch its outcome; node writes the end line of a run bin/vh exec'd into" ;;
      *) bad "activity of render and patch (rc $rc): $a" ;; esac
    # versions (tools/versions.py): in a project, each render and patch is a version; the film a render or an in-place
    # patch replaces is kept in out/versions/ (moved, the same bytes), its record says what changed; compare draws a
    # moment of two and says the PSNR; use makes an earlier one current again with the newer one kept; a disk under the
    # floor and OVH_KEEP_VERSIONS send the replaced one to the Trash, said and recorded; a film made elsewhere is kept as
    # found; OVH_VERSIONS=off records nothing; status lists them; clean prunes them to the Trash
    v="$t/ver"; mkdir -p "$v" && cp tools/film/fixture/index.html "$v/index.html" && printf '# BRIEF\n' > "$v/BRIEF.md"
    vh render "$v" --gop 15 --workers 2 --out "$v/out/film.mp4" >/dev/null 2>&1
    s1=$(cksum < "$v/out/film.mp4")
    a=$(vh render "$v" --gop 15 --workers 2 --out "$v/out/film.mp4" --note "second take" 2>&1); rc=$?
    sed 's/x.fillStyle = "#fc0";/x.fillStyle = t >= 1.4 \&\& t < 1.7 ? "#0cf" : "#fc0";/' tools/film/fixture/index.html > "$v/index.html"
    b=$(vh patch "$v/out/film.mp4" --frames 42-50 --in-place --note blue 2>&1); rc2=$?
    c=$(vh versions compare "$v" v2 v3 --t 1.5 --wipe --json 2>&1); rc3=$?
    d=$(vh versions use "$v" v2 2>&1); rc4=$?
    if [ "$rc:$rc2:$rc3:$rc4" = 0:0:0:0 ] && printf '%s' "$a" | grep -q 'version v2: out/film.mp4 (from v1)' && printf '%s' "$a" | grep -q 'v1 kept: out/versions/v1/film.mp4' \
      && [ "$(cksum < "$v/out/versions/v1/film.mp4")" = "$s1" ] && printf '%s' "$b" | grep -q 'version v3: out/film.mp4 (from v2)' \
      && printf '%s' "$d" | grep -q 'v2 is the current film at out/film.mp4 again; v3 is kept in out/versions/v3/film.mp4' \
      && python3 - "$v" "$c" <<'PY'
import json, os, subprocess, sys
v, c = sys.argv[1], json.loads(sys.argv[2])
L = json.loads(subprocess.run([sys.executable, "tools/versions.py", v, "--json"], capture_output=True, text=True).stdout)
by = {x["id"]: x for x in L["versions"]}
ch = by["v3"]["changed"]
side = json.load(open(v + "/out/versions/v3/film.mp4.render.json"))
ok = [x["state"] for x in L["versions"]] == ["kept", "current", "kept"] and L["current"] == {"out/film.mp4": "v2"} and by["v2"]["note"] == "second take"
ok = ok and by["v3"]["from"] == "v2" and by["v3"]["made_by"] == "patch" and ch["frames"] == [[42, 50]] and ch["drawn"] == [[30, 59]] and by["v1"]["changed"] == {"whole": True}
ok = ok and side["page"] == "../../../index.html" and os.path.isfile(os.path.join(v, "out/versions/v3", side["page"]))   # a kept sidecar still finds its page
ok = ok and c["a"]["frame"] == 45 and c["b"]["frame"] == 45 and isinstance(c["psnr"], float) and c["psnr"] < 30 and os.path.isfile(os.path.join(v, c["image"]))
sys.exit(0 if ok else 1)
PY
    then ok "versions: each render and patch a version, the one it replaces kept as it was; compare a moment of two (PSNR); use brings one back, the newer one kept"
    else bad "versions: render/patch/compare/use (exit $rc:$rc2:$rc3:$rc4): $(printf '%s' "$a$b$c$d" | tail -c 900)"; fi
    # a disk under the floor: the replaced film goes to the Trash, named for the project, said and recorded; OVH_KEEP_VERSIONS=1
    # sends the oldest kept one there too; a film made elsewhere is kept as found; OVH_VERSIONS=off writes nothing
    a=$(OVH_FREE_BYTES=1000000000 OVH_TRASH_DIR="$t/trash" vh render "$v" --gop 15 --workers 2 --out "$v/out/film.mp4" 2>&1); rc=$?
    cp "$v/out/versions/v3/film.mp4" "$v/out/film.mp4"; touch "$v/out/film.mp4"   # a film put there by hand
    b=$(OVH_KEEP_VERSIONS=1 OVH_TRASH_DIR="$t/trash" vh render "$v" --gop 15 --workers 2 --out "$v/out/film.mp4" 2>&1); rc2=$?
    n0=$(wc -c < "$v/out/versions/versions.json")
    OVH_VERSIONS=off vh render "$v" --gop 15 --workers 2 --out "$v/out/film.mp4" >/dev/null 2>&1
    if [ "$rc:$rc2" = 0:0 ] && printf '%s' "$a" | grep -q 'v2 to the Trash: not kept: 1.0 GB free on that disk' && [ -d "$t/trash/ver v2" ] \
      && printf '%s' "$b" | grep -q 'was not made by bin/vh render or patch' && printf '%s' "$b" | grep -q 'v1 to the Trash: more than 1 earlier version' \
      && printf '%s' "$b" | grep -q 'v3 to the Trash: more than 1 earlier version' \
      && [ "$(wc -c < "$v/out/versions/versions.json")" = "$n0" ] && python3 - "$v" <<'PY'
import json, subprocess, sys
L = json.loads(subprocess.run([sys.executable, "tools/versions.py", sys.argv[1], "--json"], capture_output=True, text=True).stdout)
st = {x["id"]: (x["made_by"], x["state"]) for x in L["versions"]}
S = json.loads(subprocess.run(["bash", "bin/vh", "status", sys.argv[1], "--json"], capture_output=True, text=True).stdout)
ok = st["v1"][1] == "trashed" and st["v2"][1] == "trashed" and st["v5"] == ("found", "kept") and st["v6"][1] == "changed"   # OVH_VERSIONS=off replaced v6
ok = ok and S["versions"]["list"][-1]["id"] == "v6" and S["versions"]["current"] == {} and all(not r["path"].startswith("out/versions") for r in S["renders"])
sys.exit(0 if ok else 1)
PY
    then ok "versions: a full disk and OVH_KEEP_VERSIONS send the replaced film to the Trash (said, recorded); a film made by hand is kept as found; OVH_VERSIONS=off records nothing; status lists them"
    else bad "versions: the Trash, found, off, status (exit $rc:$rc2): $(printf '%s' "$a$b" | tail -c 900)"; fi
    a=$(vh versions 2>&1); rc=$?; b=$(vh versions compare "$v" v4 --t 1 2>&1); rc2=$?; c=$(vh versions use "$v" v1 2>&1); rc3=$?
    d=$(vh versions compare "$v" v4 v5 2>&1); rc4=$?; e=$(vh versions compare "$v" v4 v5 --t 1 --wipe=abc 2>&1); rc5=$?
    case "$rc:$rc2:$rc3:$rc4:$rc5:$c:$d:$e" in 2:2:1:2:2:*"v1 is trashed: its film is not in the project"*"compare needs --t"*"--wipe abc: where the line goes"*)
        ok "versions: usage errors exit 2 (a --wipe that is no share of the width too), a version in the Trash cannot be used (exit 1)" ;;
      *) bad "versions usage (exit $rc:$rc2:$rc3:$rc4:$rc5): $(printf '%s' "$a$b$c$d$e" | tail -c 500)" ;; esac
    a=$(vh clean "$v" 2>&1); b=$(OVH_TRASH_DIR="$t/trash" vh clean "$v" --yes --keep-versions 1 2>&1); rc=$?
    c=$(OVH_TRASH_DIR="$t/trash" vh clean "$v" --yes 2>&1); rc2=$?
    if [ "$rc:$rc2" = 0:0 ] && printf '%s' "$a" | grep -q 'versions (earlier versions of the films' && printf '%s' "$a" | grep -q 'out/versions/v5/' \
      && ! printf '%s' "$b" | grep -q 'out/versions/v5/' && [ ! -e "$v/out/versions/v5" ] && [ -d "$t/trash/ver v5" ] && [ -f "$v/out/versions/versions.json" ] \
      && vh versions "$v" | grep -q 'v5 .*in the Trash'
    then ok "clean: the earlier versions listed, then to the Trash but the newest --keep-versions N; their record says so"
    else bad "clean of versions (exit $rc:$rc2): $(printf '%s' "$a$b$c" | tail -c 700)"; fi
    # patch --shot / --chapter (tools/film/fixture/shots.html: S02 green from 1.4 to 2.2 s, under S03's 0.3 s dissolve to
    # 2.5 s): S02 turned yellow; --shot S02 draws 42–74 (through the dissolve) and passes, naming S02; the frames of S02's
    # own span alone are refused (the dissolve shows it); a chapter by its id, an unknown shot and a chapter outside the
    # film exit 2; shots.json in the project wins over the page
    s="$t/shots"; mkdir -p "$s" && cp tools/film/fixture/shots.html "$s/film.html" && printf '# BRIEF\n' > "$s/BRIEF.md"
    vh render "$s" --gop 15 --workers 2 --out "$s/out/film.mp4" >/dev/null 2>&1
    sed 's/colour: "#3c3"/colour: "#cc3"/' tools/film/fixture/shots.html > "$s/film.html"
    a=$(vh patch "$s/out/film.mp4" --frames 42-65 --out "$s/out/own.mp4" 2>&1); rc=$?
    b=$(vh patch "$s/out/film.mp4" --shot S02 --out "$s/out/shot.mp4" 2>&1); rc2=$?
    c=$(vh patch "$s/out/film.mp4" --chapter ch-two --out "$s/out/ch.mp4" 2>&1); rc3=$?
    d=$(vh patch "$s/out/film.mp4" --shot S09 2>&1); rc4=$?
    printf '[{"id": "X1", "start": "0:01.4", "end": 2.5}]\n' > "$s/shots.json"
    e=$(vh patch "$s/out/film.mp4" --shot X1 --out "$s/out/x.mp4" 2>&1); rc5=$?
    if [ "$rc:$rc2:$rc3:$rc4:$rc5" = 1:0:0:2:0 ] && printf '%s' "$a" | grep -q 'frames 66–74 are outside 42–65' && printf '%s' "$b" | grep -q 'frames 42–74 (1.400–2.500 s) asked' \
      && printf '%s' "$b" | grep -q "S02: 1.400–2.500 s (+0.3 s: S03's transition draws it underneath)" && printf '%s' "$c" | grep -q 'frames 42–89' \
      && printf '%s' "$d" | grep -q 'no shot S09: .*film.html (window.film.shots) has S01, S02, S03' && printf '%s' "$e" | grep -q 'shots from .*shots.json' && python3 - "$s" <<'PY'
import json, subprocess, sys
s = sys.argv[1]
L = json.loads(subprocess.run([sys.executable, "tools/versions.py", s, "--json"], capture_output=True, text=True).stdout)
by = {x["film"]: x for x in L["versions"]}
side = json.load(open(s + "/out/film.mp4.render.json"))
ok = side["shots"][2] == {"id": "S03", "start": 2.2, "end": 3, "transition": 0.3} and side["chapters"][1] == {"t": 1.4, "title": "two", "id": "ch-two"}
ok = ok and by["out/shot.mp4"]["changed"]["shots"] == ["S02", "S03"] and by["out/shot.mp4"]["changed"]["asked"]["shots"] == ["S02"] and by["out/shot.mp4"]["from"] == by["out/film.mp4"]["id"]
ok = ok and by["out/x.mp4"]["changed"]["shots"] == ["X1"] and "out/own.mp4" not in by
sys.exit(0 if ok else 1)
PY
    then ok "patch --shot / --chapter: a shot's frames through the next cut's transition, a chapter by its id, the shots named in the version; shots.json wins; unknown ones exit 2"
    else bad "patch --shot / --chapter (exit $rc:$rc2:$rc3:$rc4:$rc5): $(printf '%s' "$a$b$c$d$e" | tail -c 900)"; fi
    # two spans apart: their windows drawn separately and both joined in, the frames between them the film's own bytes
    a=$(vh patch "$s/out/film.mp4" --frames 5-6,80-82 --out "$s/out/two.mp4" 2>&1); rc=$?
    if [ $rc = 0 ] && printf '%s' "$a" | grep -q '0–14, 75–89 drawn again (keyframe to keyframe, 30 frames)' && printf '%s' "$a" | grep -q "packets outside 0–14, 75–89: 60 the film's own ✓"
    then ok "patch: two spans apart are drawn as two windows, the film's own packets between them"
    else bad "patch on two spans (exit $rc): $(printf '%s' "$a" | tail -c 700)"; fi
    # a link in the project to a film outside it: render and patch --in-place replace the link, never write into what it
    # points to (with versions and with OVH_VERSIONS=off), as before versions
    l="$t/lk"; mkdir -p "$l/out" "$t/outside" && cp tools/film/fixture/index.html "$l/index.html" && printf '# BRIEF\n' > "$l/BRIEF.md"
    vh render "$l" --gop 15 --workers 2 --out "$t/outside/target.mp4" >/dev/null 2>&1
    cp "$t/outside/target.mp4" "$t/outside/t2.mp4"; s1=$(cksum < "$t/outside/target.mp4")
    sig() { python3 -c 'import os, sys; print(" ".join("%d:%d" % (os.stat(f).st_ino, os.stat(f).st_mtime_ns) for f in sys.argv[1:]))' "$@"; }
    g1=$(sig "$t/outside/target.mp4" "$t/outside/t2.mp4")   # the same file, untouched: a re-render of the same page has the same bytes
    ln -s "$t/outside/target.mp4" "$l/out/link.mp4"; ln -s "$t/outside/t2.mp4" "$l/out/off.mp4"; ln -s "$t/outside/target.mp4" "$l/out/p.mp4"
    cp "$t/outside/target.mp4.render.json" "$l/out/p.mp4.render.json"
    a=$(vh render "$l" --gop 15 --workers 2 --out "$l/out/link.mp4" 2>&1); rc=$?
    OVH_VERSIONS=off vh render "$l" --gop 15 --workers 2 --out "$l/out/off.mp4" >/dev/null 2>&1; rc2=$?
    b=$(vh patch "$l/out/p.mp4" --frames 5-6 --in-place 2>&1); rc3=$?
    if [ "$rc:$rc2:$rc3" = 0:0:0 ] && [ "$(sig "$t/outside/target.mp4" "$t/outside/t2.mp4")" = "$g1" ] && [ "$(cksum < "$t/outside/t2.mp4")" = "$s1" ] \
      && [ -f "$l/out/link.mp4" ] && [ ! -L "$l/out/link.mp4" ] && [ ! -L "$l/out/off.mp4" ] && [ ! -L "$l/out/p.mp4" ] \
      && printf '%s' "$a" | grep -q 'out/link.mp4 was a link to .*target.mp4: the link is replaced by the new film, what it points to is left as it was'
    then ok "render and patch --in-place on a link replace the link, never what it points to (versions on and off)"
    else bad "a film path that is a link (exit $rc:$rc2:$rc3; target $( [ "$(cksum < "$t/outside/target.mp4")" = "$s1" ] && echo same || echo changed)): $(printf '%s' "$a$b" | tail -c 600)"; fi
    # an --out inside out/versions (a kept version's folder) is refused before anything is drawn, the kept film untouched
    v="$t/in"; mkdir -p "$v" && cp tools/film/fixture/index.html "$v/index.html" && printf '# BRIEF\n' > "$v/BRIEF.md"
    vh render "$v" --gop 15 --workers 2 --out "$v/out/film.mp4" >/dev/null 2>&1; vh render "$v" --gop 15 --workers 2 --out "$v/out/film.mp4" >/dev/null 2>&1
    s1=$(cksum < "$v/out/versions/v1/film.mp4")
    a=$(vh render "$v" --gop 15 --workers 2 --out "$v/out/versions/v1/film.mp4" 2>&1); rc=$?
    b=$(vh patch "$v/out/film.mp4" --frames 5-6 --out "$v/out/versions/v1/film.mp4" 2>&1); rc2=$?
    c=$(vh patch "$v/out/versions/v1/film.mp4" --frames 5-6 2>&1); rc3=$?
    if [ "$rc:$rc2:$rc3" = 2:2:2 ] && [ "$(cksum < "$v/out/versions/v1/film.mp4")" = "$s1" ] && printf '%s' "$a$b$c" | grep -q 'inside out/versions' \
      && vh versions "$v" | grep -q 'v1 .*kept out/versions/v1/film.mp4'
    then ok "render and patch refuse an --out inside out/versions (exit 2), the kept film untouched"
    else bad "an --out inside out/versions (exit $rc:$rc2:$rc3): $(printf '%s' "$a$b$c" | tail -c 600)"; fi
    # use: the check record at the film's path is the version's own or none. v2 checked (a record made after it), v1 never:
    # after use v1 there is no record at out/check/film.check.json, v2's went into its folder; use v2 brings it back
    mkdir -p "$v/out/check"
    printf '{"version": 1, "tool": "bin/vh check", "video": "out/film.mp4", "t": %s, "at": "now", "exit": 0, "verdict": "pass", "counts": {"fail": 0, "warn": 0, "info": 0}, "findings": []}\n' \
      "$(python3 -c 'import time; print(time.time() + 2)')" > "$v/out/check/film.check.json"
    a=$(vh versions use "$v" v1 2>&1); rc=$?
    b=$(python3 - "$v" <<'PY'
import json, os, subprocess, sys
v = sys.argv[1]
L = json.loads(subprocess.run([sys.executable, "tools/versions.py", v, "--json"], capture_output=True, text=True).stdout)
S = json.loads(subprocess.run(["bash", "bin/vh", "status", v, "--json"], capture_output=True, text=True).stdout)
by = {x["id"]: x for x in L["versions"]}
r = next(x for x in S["renders"] if x["path"] == "out/film.mp4")
print(os.path.exists(v + "/out/check/film.check.json"), by["v1"]["state"], by["v1"]["check"], by["v2"]["state"], (by["v2"]["check"] or {}).get("verdict"), r["check"])
PY
)
    c=$(vh versions use "$v" v2 2>&1); rc2=$?
    d=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["verdict"])' "$v/out/check/film.check.json" 2>&1)
    if [ "$rc:$rc2" = 0:0 ] && [ "$b" = "False current None kept pass None" ] && [ "$d" = pass ]
    then ok "versions use: the check record at the film's path is the version's own or none; the displaced one's goes with it and comes back with it"
    else bad "use and the check record (exit $rc:$rc2): $b | $d | $(printf '%s' "$a$c" | tail -c 400)"; fi
    # a version's check record is the film's by the size and mtime_ns it kept (tools/checkrec.py), not by its time: made after
    # the film, with the film's numbers it is reported (current, and kept with the film that was displaced), with other numbers
    # (size or mtime_ns) it is not; a record of the old kind, without them, goes by time as before
    if python3 - "$v" <<'PY'
import json, os, subprocess, sys, time
v = sys.argv[1]; rec = v + "/out/check/film.check.json"; film = v + "/out/film.mp4"
listing = lambda: {x["id"]: x for x in json.loads(subprocess.run([sys.executable, "tools/versions.py", v, "--json"], capture_output=True, text=True).stdout)["versions"]}
def write(**f):   # a passing record of the film at its path, made after it, with the fields given
    json.dump({"version": 1, "tool": "bin/vh check", "video": "out/film.mp4", "t": time.time() + 2, "at": "now", "exit": 0, "verdict": "pass",
               "counts": {"fail": 0, "warn": 0, "info": 0}, "findings": [], **f}, open(rec, "w"))
st = os.stat(film)
got = []
for f in ({"size": st.st_size, "mtime_ns": st.st_mtime_ns}, {"size": st.st_size + 1, "mtime_ns": st.st_mtime_ns},
          {"size": st.st_size, "mtime_ns": st.st_mtime_ns + 1}, {}):
    write(**f); got.append(listing()["v2"]["check"] is not None)
write(size=st.st_size, mtime_ns=st.st_mtime_ns)
subprocess.run([sys.executable, "tools/versions.py", "use", v, "v1"], capture_output=True)   # v2 is kept, its record with it
kept = listing()["v2"]
got.append(kept["state"] == "kept" and kept["check"] is not None)
kr = os.path.join(v, kept["check"]["record"]); j = json.load(open(kr)); j["size"] += 1; json.dump(j, open(kr, "w"))
got.append(listing()["v2"]["check"] is None)
subprocess.run([sys.executable, "tools/versions.py", "use", v, "v2"], capture_output=True)   # as it was
sys.exit(0 if got == [True, False, False, True, True, True] else 1)
PY
    then ok "versions: a check record is the film's by the size and mtime_ns it kept (current and kept versions), not by its time; a record without them goes by time"
    else bad "versions: a check record and the film's size and mtime_ns"; fi
    # a patch in place commits only over the film it cut: versions use refuses while it runs (its lock), and a film rewritten
    # meanwhile (the same bytes, another file) is left as it is, the patched one beside it (exit 1), the record unchanged
    sed 's|x.fillStyle = "#fc0"; x.fillRect(20 + t \* 80, 90, 40, 40);|x.fillStyle = "#fc0"; x.fillRect(20 + t * 80, 90, 40, 40); return new Promise((ok) => setTimeout(ok, 400));|' \
      tools/film/fixture/index.html > "$v/index.html"
    waitwork() { local n=0; while [ ! -d "$v/out/.film.mp4.patch" ] && [ $n -lt 300 ]; do sleep 0.1; n=$((n + 1)); done; }
    vh patch "$v/out/film.mp4" --frames 20-21 --in-place --workers 1 > "$t/patch-use.log" 2>&1 & pid=$!
    waitwork; a=$(vh versions use "$v" v1 2>&1); rc=$?
    wait $pid; p_use=$?
    vh patch "$v/out/film.mp4" --frames 20-21 --in-place --workers 1 > "$t/patch-swap.log" 2>&1 & pid=$!
    waitwork; cp "$v/out/film.mp4" "$t/same.mp4"; mv "$t/same.mp4" "$v/out/film.mp4"
    nv=$(python3 -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["versions"]))' "$v/out/versions/versions.json")
    wait $pid; p_swap=$?
    b=$(cat "$t/patch-swap.log")
    nv2=$(python3 -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["versions"]))' "$v/out/versions/versions.json")
    if [ "$rc:$p_use:$p_swap" = 1:0:1 ] && printf '%s' "$a" | grep -q 'is writing out/film.mp4' && printf '%s' "$b" | grep -q 'is not the one the patch cut from' \
      && [ -f "$v/out/film.new.mp4" ] && [ "$nv" = "$nv2" ]
    then ok "patch --in-place commits only over the film it cut: use waits for it, a film rewritten meanwhile is left as it is and the patched one goes beside it"
    else bad "patch and a film changed meanwhile (use exit $rc, patches $p_use/$p_swap, versions $nv/$nv2): $a | $(printf '%s' "$b" | tail -c 500)"; fi
    # proxy and thumbs (tools/proxy.py): a film with sound (the shots fixture, a tone muxed on) gets a proxy at --size on
    # its short side with a keyframe every 6 frames, no B-frames and its sound, and thumbs (tiles in a sheet, a picture a
    # shot from the sidecar's shots, a map); run again, both are up to date; after a patch in place only the proxy's
    # window around the frames drawn again is encoded (it decodes as a whole remake does, its sound kept) and only the
    # tiles and shots there are taken; a project with no film: thumbs from the page, no proxy (exit 2)
    x="$t/px"; mkdir -p "$x" && cp tools/film/fixture/shots.html "$x/film.html" && printf '# BRIEF\n' > "$x/BRIEF.md"
    vh render "$x" --gop 15 --workers 2 --out "$x/out/film.mp4" >/dev/null 2>&1
    ffmpeg -v error -nostdin -y -i "$x/out/film.mp4" -f lavfi -i "sine=frequency=440:duration=3" -map 0:v -map 1:a -c:v copy -c:a aac -shortest "$x/out/final.mp4"
    sed 's/colour: "#3c3"/colour: "#cc3"/' tools/film/fixture/shots.html > "$x/film.html"
    vh patch "$x/out/final.mp4" --sidecar "$x/out/film.mp4.render.json" --shot S02 --in-place >/dev/null 2>&1
    a=$(vh proxy "$x/out/final.mp4" --size 90 2>&1); rc=$?
    b=$(vh proxy "$x/out/final.mp4" --size 90 2>&1); rc2=$?
    c=$(vh thumbs "$x" --every 0.5 --width 80 2>&1); rc3=$?
    sed 's/colour: "#c33"/colour: "#c3c"/' "$x/film.html" > "$x/f2.html" && mv "$x/f2.html" "$x/film.html"
    vh patch "$x/out/final.mp4" --shot S01 --in-place >/dev/null 2>&1
    d=$(vh proxy "$x/out/final.mp4" --size 90 2>&1); rc4=$?
    e=$(vh thumbs "$x" --every 0.5 --width 80 --json 2>&1); rc5=$?
    cp "$x/out/proxy/final.mp4" "$t/refreshed.mp4"
    vh proxy "$x/out/final.mp4" --size 90 --full >/dev/null 2>&1
    if [ "$rc:$rc2:$rc3:$rc4:$rc5" = 0:0:0:0:0 ] && printf '%s' "$a" | grep -q '160x90, a keyframe every 6 frames, with sound · made' && printf '%s' "$b" | grep -q 'up to date' \
      && printf '%s' "$c" | grep -q '6 tiles every 0.5 s (80x46) in 1 sheet(s), 3 shot picture(s)' && printf '%s' "$d" | grep -q 'refreshed: 1 window(s) of frames encoded anew, 48 of 90 frames' \
      && python3 - "$x" "$t/refreshed.mp4" "$e" <<'PY'
import json, re, subprocess, sys
x, refreshed, e = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
def run(*a): return subprocess.run(a, capture_output=True, text=True)
keys = [i for i, l in enumerate(run("ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "packet=flags", "-of", "csv=p=0", refreshed).stdout.split()) if "K" in l]
st = run("ffprobe", "-v", "error", "-show_entries", "stream=codec_type,width,height,nb_frames,has_b_frames", "-of", "json", refreshed).stdout
st = {s["codec_type"]: s for s in json.loads(st)["streams"]}
m = re.findall(r"average:(inf|[\d.]+)", run("ffmpeg", "-v", "info", "-i", refreshed, "-i", x + "/out/proxy/final.mp4", "-lavfi", "psnr", "-f", "null", "-").stderr)
rec = json.load(open(x + "/out/proxy/final.mp4.json"))
ok = keys == list(range(0, 90, 6)) and st["video"]["nb_frames"] == "90" and (st["video"]["width"], st["video"]["height"]) == (160, 90) and "audio" in st
ok = ok and m and (m[-1] == "inf" or float(m[-1]) >= 50) and rec["made"] == "full" and rec["source_version"] == "v4"
ok = ok and e["made"] == "refreshed" and e["taken"] == {"tiles": 3, "shots": 1} and e["from"] == "proxy" and [s["id"] for s in e["shots"]] == ["S01", "S02", "S03"]
ok = ok and e["tiles"][3] == {"i": 3, "t": 1.5, "frame": 45, "sheet": 0, "x": 240, "y": 0} and e["sheets"][0]["size"] == [480, 46]
sys.exit(0 if ok else 1)
PY
    then ok "proxy and thumbs: a small short-GOP copy with its sound, a tile sheet, a picture a shot and the map; up to date when the film is; after a patch in place only its window is encoded again and its tiles taken"
    else bad "proxy and thumbs (exit $rc:$rc2:$rc3:$rc4:$rc5): $(printf '%s' "$a$b$c$d" | tail -c 900)"; fi
    mkdir -p "$t/nofilm" && cp tools/film/fixture/shots.html "$t/nofilm/film.html" && printf '# BRIEF\n' > "$t/nofilm/BRIEF.md"
    a=$(vh thumbs "$t/nofilm" --every 1 2>&1); rc=$?; b=$(vh proxy "$t/nofilm" 2>&1); rc2=$?; c=$(vh proxy "$x" --size x 2>&1); rc3=$?
    mkdir -p "$x/out/review/proxy" && cp "$x/out/film.mp4" "$x/out/review/proxy/kept.mp4"   # a folder of that name deeper down is the person's own
    s=$(vh status "$x" --json | python3 -c 'import json, sys; print(" ".join(r["path"] for r in json.load(sys.stdin)["renders"]))')
    case "$rc:$rc2:$rc3:$a:$b:$s" in 0:2:2:*"3 tiles every 1.0 s"*"3 shot picture(s)"*"from the page"*:*"no film in"*"to make a proxy of"*:*) case " $s " in *" out/proxy"*|*" out/versions"*) bad "status lists the proxy or a kept version as a render: $s" ;;
        *" out/review/proxy/kept.mp4 "*) ok "thumbs on a project with no film: from the page; proxy needs a film (exit 2); status lists neither out/proxy nor out/versions, but a proxy folder deeper down" ;;
        *) bad "status left out out/review/proxy/kept.mp4: $s" ;; esac ;;
      *) bad "thumbs from the page, proxy without a film (exit $rc:$rc2:$rc3): $(printf '%s' "$a$b$c" | tail -c 600)" ;; esac
  fi
  rm -rf "$t"
}

# the page tools beyond frames: HyperFrames' adapter where its runtime is installed, the music clock's and the time map's
# pages, the canvas-film engine's template (cues, covers, fonts, readcheck), the shot tools, and a Ctrl-C to each kind
film_engine_checks() {
  local t a rc
  film_chrome || { no_chrome "page tools"; return; }
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  if node -e 'import("./tools/film/host.mjs").then((m) => process.exit(m.findRuntime(process.cwd()) ? 0 : 1))' 2>/dev/null; then
    mkdir -p "$t/hf"
    cat > "$t/hf/index.html" <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;background:#000}.clip{position:absolute;inset:0}</style></head>
<body><div id="root" data-composition-id="main" data-start="0" data-duration="2" data-width="320" data-height="180">
<div class="clip" data-start="0" data-duration="1" data-track-index="1" style="background:#c33"></div>
<div class="clip" data-start="1" data-duration="1" data-track-index="1" style="background:#3c3"></div>
</div></body></html>
HTML
    a=$(vh frames "$t/hf" --at 0.5,1.5 --out "$t/hf/out" 2>&1); rc=$?
    if [ $rc = 0 ] && printf '%s' "$a" | grep -q "HyperFrames runtime" && python3 - "$t/hf/out" <<'PY'
import sys, zlib, struct
def first_pixel(f):   # the PNG's first pixel, enough to tell the two clips apart
    d = open(f, "rb").read(); i = 8; idat = b""
    while i < len(d):
        n, kind = struct.unpack(">I4s", d[i:i + 8]); body = d[i + 8:i + 8 + n]; i += 12 + n
        if kind == b"IHDR": bpp = {2: 3, 6: 4}[body[9]]
        if kind == b"IDAT": idat += body
    row = zlib.decompress(idat)
    return tuple(row[1:1 + bpp][:3])
a, b = first_pixel(sys.argv[1] + "/index-t0000.500.png"), first_pixel(sys.argv[1] + "/index-t0001.500.png")
sys.exit(0 if a[0] > 150 and a[1] < 100 and b[1] > 150 and b[0] < 100 else 1)
PY
    then ok "frames: a HyperFrames composition without window.film is drawn by its own runtime (clips shown by their data-start)"
    else bad "frames with the HyperFrames runtime (exit $rc): $(printf '%s' "$a" | tail -c 600)"; fi
  else skip "frames on a HyperFrames composition" "no HyperFrames runtime installed (styles/_swatch: npm ci)"; fi
  # the canvas-film engine's template (engines/canvas-film): two frames draw, each the same PNG drawn first and drawn after
  # the other (12.8 s is inside a page turn); a cue whose word is gone stops it in ready at once, naming the shot and the
  # cue; its reads and captions pass textcheck
  if python3 tools/audio/test_music_clock.py --film; then ok "music clock: live cues, reads, chapters and deterministic frames"; else bad "music clock page"; fi
  if python3 tools/audio/test_time_map.py --film; then ok "time map: live event cues move with the map, a map made on other music stops ready, deterministic frames"; else bad "time map page"; fi
  local c="$ROOT/engines/canvas-film/template" s0 pid left seen alive
  a=$(vh frames "$c" --at 4.9,12.8 --out "$t/cf1" 2>&1); rc=$?
  # a machine without the template's CJK faces (the Linux runner) draws in a fallback and says so, which is exit 1; that
  # alone is fine here, as the frames are still compared
  if [ $rc = 1 ] && printf '%s' "$a" | grep -q 'fonts this machine does not have' \
    && ! printf '%s\n' "$a" | grep -E 'while loading:|^  t=[0-9.]+ s:|just after the last frame' | grep -qv 'fonts this machine does not have'; then rc=0; fi
  vh frames "$c" --at 12.8,4.9 --out "$t/cf2" >/dev/null 2>&1
  if [ $rc = 0 ] && cmp -s "$t/cf1/film-t0004.900.png" "$t/cf2/film-t0004.900.png" && cmp -s "$t/cf1/film-t0012.800.png" "$t/cf2/film-t0012.800.png"
  then ok "canvas-film: the template draws, and a frame is the same PNG drawn first or after another (one inside a transition too)"
  else bad "canvas-film template frames (exit $rc): $(printf '%s' "$a" | tail -c 800)"; fi
  mkdir "$t/cfb" && cp -R "$c/." "$t/cfb/" && sed 's/"@a2:第二张"/"@a2:第三张"/' "$c/src/50-shots.js" > "$t/cfb/src/50-shots.js"
  s0=$SECONDS; a=$(vh frames "$t/cfb" --at 1 --out "$t/cfb/out" 2>&1); rc=$?
  case "$rc:$a" in
    2:*'shot S02 (o.two), cue "@a2:第三张"'*'it now reads'*) if [ $((SECONDS - s0)) -lt 60 ]; then ok "canvas-film: a cue whose word is gone stops it in ready ($((SECONDS - s0)) s), naming the shot, the cue and the line as it reads now"
      else bad "canvas-film: the broken cue was reported after $((SECONDS - s0)) s, not at once"; fi ;;
    *) bad "canvas-film with a broken cue: exit $rc: $(printf '%s' "$a" | tail -c 800)" ;;
  esac
  # no face of film.html on this machine: each missing face is named once, the 900 serif and its face for two dashes apart
  mkdir "$t/cfn" && cp -R "$c/." "$t/cfn/" && sed 's/local("[^"]*")/local("No Such Face CI")/g' "$c/film.html" > "$t/cfn/film.html"
  a=$(vh frames "$t/cfn" --at 1 --out "$t/cfn/out" 2>&1 | grep 'fonts this machine does not have')
  if printf '%s' "$a" | python3 -c '
import re, sys
m = re.search(r"drawn in a fallback: (.*) \(film\.html", sys.stdin.read()); L = m.group(1).split(" · ") if m else []
sys.exit(0 if len(L) == len(set(L)) == 8 and {"Film Serif 900", "Film Serif 900 for U+2013, U+2212"} <= set(L) else 1)'
  then ok "canvas-film: a machine without the faces names each missing face once (a face for a few characters says which)"
  else bad "canvas-film missing faces: $a"; fi
  a=$(vh textcheck "$c" --out "$t/cftc" 2>&1); rc=$?
  [ $rc = 0 ] && ok "canvas-film: textcheck passes the template's reads and captions" || bad "textcheck on the canvas-film template (exit $rc): $(printf '%s' "$a" | tail -c 800)"
  mkdir "$t/cfq" && cp -R "$c/." "$t/cfq/"
  a=$(vh cues "$t/cfq" --save 2>&1); rc=$?
  python3 - "$t/cfq/audio/timeline.zh.json" <<'PY'
import json, sys
p = sys.argv[1]; tl = json.load(open(p, encoding="utf-8"))
for s in tl["segments"]:
    if s["id"] in ("b1", "b2"):   # a new take: the last two lines 0.4 s later
        s["start"] = round(s["start"] + 0.4, 3); s["end"] = round(s["end"] + 0.4, 3)
        for w in s.get("words", []): w["start"] = round(w["start"] + 0.4, 3); w["end"] = round(w["end"] + 0.4, 3)
tl["duration"] = round(tl["duration"] + 0.4, 3)
json.dump(tl, open(p, "w", encoding="utf-8"), ensure_ascii=False)
PY
  b=$(vh cues "$t/cfq" 2>&1); rc2=$?
  if [ $rc = 0 ] && [ $rc2 = 0 ] && grep -q '"timeline_sha256": "[0-9a-f]\{64\}"' "$t/cfq/out/cues.json" && printf '%s' "$a" | grep -q 'S02.o.one *@a2:第一张' \
    && printf '%s' "$b" | grep -q 'another take of the narration): 7 moved, 0 new, 0 gone' && printf '%s' "$b" | grep -q 'S03.at .*(+0.400)'
  then ok "cues: the template's cues in order, saved with the timeline's sha256; a new take says which moved and by how much"
  else bad "cues on the canvas-film template: exit $rc / $rc2: $(printf '%s' "$a$b" | tail -c 800)"; fi
  a=$(vh cues "$ROOT/tools/film/fixture/index.html" 2>&1); rc=$?
  [ $rc = 2 ] && printf '%s' "$a" | grep -q 'gives no window.film.cues' && ok "cues: a page without window.film.cues exits 2 and says so" || bad "cues on a page without cues: exit $rc: $a"
  # covers picked by cue: the template's cover A is drawn into out/covers; a longer opening (every line 0.4 s later) moves
  # its time with the narration, and the picture it takes stays the same (only the grain, a function of t, differs)
  mkdir "$t/cov" && cp -R "$c/." "$t/cov/"
  a=$(vh frames "$t/cov" --covers --out "$t/cov/c1" 2>&1); rc=$?
  python3 - "$t/cov/audio/timeline.zh.json" <<'PY'
import json, sys
p = sys.argv[1]; tl = json.load(open(p, encoding="utf-8"))
for s in tl["segments"]:
    s["start"] = round(s["start"] + 0.4, 3); s["end"] = round(s["end"] + 0.4, 3)
    for w in s.get("words", []): w["start"] = round(w["start"] + 0.4, 3); w["end"] = round(w["end"] + 0.4, 3)
tl["duration"] = round(tl["duration"] + 0.4, 3)
json.dump(tl, open(p, "w", encoding="utf-8"), ensure_ascii=False)
PY
  b=$(vh frames "$t/cov" --covers --out "$t/cov/c2" 2>&1)
  t1=$(printf '%s' "$a" | sed -n 's/.*(cover A at \([0-9.]*\) s.*/\1/p'); t2=$(printf '%s' "$b" | sed -n 's/.*(cover A at \([0-9.]*\) s.*/\1/p')
  same=1; if command -v ffmpeg >/dev/null; then
    p=$(ffmpeg -v info -nostdin -i "$t/cov/c1/A.png" -i "$t/cov/c2/A.png" -lavfi psnr -f null - 2>&1 | sed -n 's/.*average:\([0-9.inf]*\).*/\1/p')
    python3 -c "import sys; v = sys.argv[1]; sys.exit(0 if v == 'inf' or float(v or 0) >= 30 else 1)" "$p" || same=0
  fi
  if [ -s "$t/cov/c1/A.png" ] && [ -n "$t1" ] && python3 -c "import sys; sys.exit(0 if abs(float(sys.argv[2]) - float(sys.argv[1]) - 0.4) < 0.002 else 1)" "$t1" "$t2" && [ $same = 1 ]
  then ok "covers: drawn into out/covers by cue; a longer opening moves the cover with the narration (+0.4 s) to the same picture"
  else bad "covers on the canvas-film template (exit $rc; $t1 → $t2, psnr ${p:-}): $(printf '%s' "$a$b" | tail -c 600)"; fi
  # --no-title: the same cover without its title (a clean background): the rows above the title's band are the same picture
  # (PSNR ≥ 40 dB; a second page need not rasterise byte for byte, as GitHub's macOS runner showed), the title's rows differ. --ratios: each ratio a crop at its own size (short side 1080 at --dpr 1), and a ratio that is
  # not one stops before any browser. A page whose cover(id) takes no options (an engine copied before) is not passed off
  # as clean. s.cover: a shot that paints a mark when s.cover is set leaves the film's frames byte for byte the template's
  # (at the cover's own t too), and the mark is in the cover, titled or clean
  a=$(vh frames "$c" --covers --out "$t/cnt" 2>&1); b=$(vh frames "$c" --covers --no-title --out "$t/cnt" 2>&1); rc=$?
  if ! command -v ffmpeg >/dev/null; then skip "covers --no-title compared with the titled cover" "no ffmpeg"
  elif [ -s "$t/cnt/A.png" ] && [ -s "$t/cnt/A-clean.png" ] && printf '%s' "$b" | grep -q '(cover A at [0-9.]* s, no title)' && python3 - "$t/cnt/A.png" "$t/cnt/A-clean.png" <<'PY'
import re, struct, subprocess, sys
def psnr(y, h):   # the two covers on rows y..y+h (two pages, so the same picture to within rasterising, not always byte for byte)
    f = f"[0:v]crop=iw:{h}:0:{y}[a];[1:v]crop=iw:{h}:0:{y}[b];[a][b]psnr"
    r = subprocess.run(["ffmpeg", "-nostdin", "-i", sys.argv[1], "-i", sys.argv[2], "-filter_complex", f, "-f", "null", "-"], capture_output=True, text=True)
    m = re.search(r"average:(inf|[0-9.]+)", r.stderr)
    return None if r.returncode or not m else float(m.group(1))   # a failed or unread comparison is no comparison
hs = [struct.unpack(">I", open(p, "rb").read()[20:24])[0] for p in sys.argv[1:3]]
top, band = psnr(0, 700), psnr(880, 120)
sys.exit(0 if hs == [1080, 1080] and top is not None and band is not None and top >= 40 and band < 30 else 1)
PY
  then ok "covers --no-title: the cover without its title, the same picture above the title's band, <id>-clean.png"
  else bad "covers --no-title (exit $rc): $(printf '%s' "$a$b" | tail -c 600)"; fi
  a=$(vh frames "$c" --covers --ratios 9:16,3:4,4:3 --out "$t/crat" 2>&1); rc=$?
  [ $rc = 1 ] && printf '%s' "$a" | grep -q 'fonts this machine does not have' && ! printf '%s\n' "$a" | grep -q '^  cover A' && rc=0
  b=$(vh frames "$c" --covers --ratios 9-16 2>&1); rc2=$?
  if [ $rc = 0 ] && [ $rc2 = 2 ] && printf '%s' "$b" | grep -q 'write them as 9:16' && printf '%s' "$a" | grep -q '9:16 1080x1920: a crop of the 1920x1080 picture' \
    && python3 - "$t/crat" <<'PY'
import struct, sys
size = lambda f: struct.unpack(">II", open(f"{sys.argv[1]}/{f}", "rb").read()[16:24])
sys.exit(0 if (size("A-9x16.png"), size("A-3x4.png"), size("A-4x3.png")) == ((1080, 1920), (1080, 1440), (1440, 1080)) else 1)
PY
  then ok "covers --ratios: each ratio a crop of the cover at its own size (9:16 1080x1920, 3:4, 4:3), said to be a crop; a malformed ratio exits 2"
  else bad "covers --ratios (exit $rc / $rc2): $(printf '%s' "$a$b" | tail -c 600)"; fi
  mkdir "$t/cold" && cp -R "$c/." "$t/cold/" && sed 's/cover(id, o) { return cover(id, o || {}); }/cover(id) { cover(id); }/' "$c/src/90-main.js" > "$t/cold/src/90-main.js"
  a=$(vh frames "$t/cold" --covers --no-title --out "$t/cold/o" 2>&1); rc=$?
  case "$rc:$a" in 1:*"cover A: the page drew its cover without saying it left the title out"*) [ ! -e "$t/cold/o/A-clean.png" ] && ok "covers --no-title: a cover(id) that takes no options is named, not passed off as clean" || bad "covers --no-title on an old cover(id) still wrote a clean cover" ;;
    *) bad "covers --no-title on an old cover(id) (exit $rc): $(printf '%s' "$a" | tail -c 500)" ;; esac
  mkdir "$t/cid" && cp -R "$c/." "$t/cid/" && cat >> "$t/cid/src/50-shots.js" <<'JS'
for (const S of SHOTS) { const d = S.draw; S.draw = (t, s) => { d(t, s); if (s.cover === "A") rect(-200, -200, 400, 400, { fill: "#FF00FF" }); }; }
JS
  ct=$(vh frames "$c" --covers --out "$t/cid/x" 2>&1 | sed -n 's/.*(cover A at \([0-9.]*\) s.*/\1/p' | head -1)
  vh frames "$c" --at "4.9,${ct:-10}" --out "$t/cid/f0" >/dev/null 2>&1; vh frames "$t/cid" --at "4.9,${ct:-10}" --out "$t/cid/f1" >/dev/null 2>&1
  vh frames "$t/cid" --covers --out "$t/cid/c" >/dev/null 2>&1; vh frames "$t/cid" --covers --no-title --out "$t/cid/c" >/dev/null 2>&1
  n0=$(find "$t/cid/f0" -name '*.png' 2>/dev/null | wc -l | tr -d ' '); same=1
  for f in "$t/cid/f0"/*.png; do cmp -s "$f" "$t/cid/f1/${f##*/}" || same=0; done
  if [ "$n0" = 2 ] && [ $same = 1 ] && python3 - "$t/cid/c/A.png" "$t/cid/c/A-clean.png" "$t/cid/f1" <<'PY'
import glob, struct, sys, zlib
def first_pixel(p):   # the top-left pixel: row 0's first pixel is stored as it is under every PNG filter
    d = open(p, "rb").read(); i, z = 8, b""
    while i < len(d):
        n, k = struct.unpack(">I4s", d[i:i + 8])
        if k == b"IDAT": z += d[i + 8:i + 8 + n]
        i += 12 + n
    return tuple(zlib.decompress(z)[1:4])
m = lambda p: first_pixel(p) == (255, 0, 255)
sys.exit(0 if m(sys.argv[1]) and m(sys.argv[2]) and not any(m(f) for f in glob.glob(sys.argv[3] + "/*.png")) else 1)
PY
  then ok "s.cover: a shot sees the cover's id only while a cover is drawn; the film's frames stay the template's, byte for byte (at the cover's t too)"
  else bad "s.cover on the canvas-film template (frames $n0, same $same, cover at ${ct:-?} s)"; fi
  # the default title for a ratio is laid out at the size txt() draws (never under FILM.minText): with an 80 px floor, a
  # 20-character title that would need 48 px in 9:16 is broken onto two lines at 80 px instead of running off both sides;
  # one that cannot fit even so (a word wider than the cover) stops ready, naming the cover and the ratio
  mkdir "$t/cmt" && cp -R "$c/." "$t/cmt/" && cat >> "$t/cmt/src/50-shots.js" <<'JS'
FILM.minText = 80;
COVERS.length = 0;
COVERS.push({ id: "L", at: "@a2:第二张+0.6", title: { text: ["二十个字的标题二十个字的标题二十个字的"], size: 80, x: 960, y: 1000, align: "center" }, ratios: { "3:4": {} } });
JS
  # (a browser that stops painting is a stall of the machine, not of the page: frames says so at --frame-timeout and the run
  # is tried once more, said in the line; each run is reported on its own)
  a=$(vh frames "$t/cmt" --covers --ratios 9:16,3:4 --frame-timeout 60 --out "$t/cmt/o" 2>&1); rc=$?; again=""
  case "$rc:$a" in 2:*"(--frame-timeout)"*|2:*"the page does not answer"*) again=" (tried again: $(printf '%s\n' "$a" | tail -1))"; a=$(vh frames "$t/cmt" --covers --ratios 9:16,3:4 --frame-timeout 60 --out "$t/cmt/o" 2>&1); rc=$? ;; esac
  [ $rc = 1 ] && printf '%s' "$a" | grep -q 'fonts this machine does not have' && ! printf '%s\n' "$a" | grep -q '^  cover L' && rc=0
  mkdir "$t/cmt2" && cp -R "$t/cmt/." "$t/cmt2/" && echo 'COVERS[0].title.text = ["Supercalifragilisticexpialidocious-and-more"]; COVERS[0].title.size = 60;' >> "$t/cmt2/src/50-shots.js"
  b=$(vh frames "$t/cmt2" --at 1 --out "$t/cmt2/o" 2>&1); rc2=$?
  if [ $rc = 0 ] && [ "$(printf '%s\n' "$a" | grep -c 're-set for it on 2 lines')" = 2 ] && [ $rc2 = 2 ] \
    && printf '%s' "$b" | grep -q 'cover L (3:4): the cover.s title does not fit 1080 x 1440 at 80 px or more (FILM.minText).*give it ratios\["3:4"\].title'
  then ok "covers --ratios: the default title is laid out at the size drawn (FILM.minText), broken onto more lines when too wide; one that cannot fit stops ready$again"
  else bad "covers --ratios default title under the text floor: the covers (exit $rc$again): $(printf '%s' "$a" | tail -c 500) | the title that cannot fit (exit $rc2): $(printf '%s' "$b" | tail -c 400)"; fi
  # a page whose size is only in window.film (1080x1920, its HTML says nothing): the drawing ratio comes from that size, so
  # its 4:3 crop (1080x810) is drawn at 1.333x and not scaled up from 1x
  mkdir "$t/ctall" && cat > "$t/ctall/film.html" <<'HTML'
<!doctype html><html><head><style>html, body { margin: 0; background: #224; }</style></head><body><script>
window.film = { width: 1080, height: 1920, duration: 2, frame() {}, covers: [{ id: "A", t: 0 }],
  cover(id, o) { return o && o.ratio === "4:3" ? { id, t: 0, title: false, crop: [0, 555, 1080, 810], size: [1440, 1080] } : { id, t: 0, title: false }; } };
</script></body></html>
HTML
  a=$(vh frames "$t/ctall" --covers --ratios 4:3 --out "$t/ctall/o" 2>&1); rc=$?
  if [ $rc = 0 ] && printf '%s' "$a" | grep -q '1080x1920 (drawn @1.333x for the crops)' && ! printf '%s' "$a" | grep -q 'scaled up' \
    && python3 -c "import struct, sys; sys.exit(0 if struct.unpack('>II', open(sys.argv[1], 'rb').read()[16:24]) == (1440, 1080) else 1)" "$t/ctall/o/A-4x3.png"
  then ok "covers --ratios: the drawing ratio follows the page's own size (window.film.width and height), not its HTML's"
  else bad "covers --ratios on a page sized by window.film (exit $rc): $(printf '%s' "$a" | tail -c 600)"; fi
  mkdir "$t/chp" && cp -R "$c/." "$t/chp/"
  a=$(vh cues "$t/chp" --chapters 2>&1); rc=$?
  if [ $rc = 0 ] && printf '%s' "$a" | grep -q '^  0:00 挂在字上' && printf '%s' "$a" | grep -q '^  0:11 翻一页' && printf '%s' "$a" | grep -q 'at least three'; then ok "cues --chapters: the engine's chapters as a description's list, half a second early, with YouTube's conditions"
  else bad "cues --chapters: exit $rc: $(printf '%s' "$a" | tail -c 500)"; fi
  # bin/vh fonts check on a font with only "A" and "B" (tools/film/fixture/fonts/ab.ttf): from 1 s the canvas draws a "C" and
  # U+10FFFD, the DOM a "D"; before that everything is in the font. render says the same, without failing
  a=$(vh fonts check "$ROOT/tools/film/fixture/glyphs.html" --out "$t/fo" 2>&1); rc=$?
  b=$(vh fonts check "$ROOT/tools/film/fixture/glyphs.html" --at 0.5 --out "$t/fo" 2>&1); rc2=$?
  if [ $rc = 1 ] && printf '%s' "$a" | grep -q 'not in "Fix AB", drawn in .*: C D' && printf '%s' "$a" | grep -q 'no font on this machine has 1 character.*U+10FFFD' \
    && [ $rc2 = 0 ] && printf '%s' "$b" | grep -q 'all in "Fix AB"'
  then ok "fonts check: characters a font lacks are named, on a canvas and in the DOM (another font draws them, or none: exit 1); none, exit 0"
  else bad "fonts check on its fixture: exit $rc / $rc2: $(printf '%s' "$a$b" | tail -c 900)"; fi
  if command -v ffmpeg >/dev/null; then
    a=$(vh render "$ROOT/tools/film/fixture/glyphs.html" --workers 2 --gop 30 --out "$t/fo/g.mp4" 2>&1); rc=$?
    [ $rc = 0 ] && printf '%s' "$a" | grep -q '2 workers' && printf '%s' "$a" | grep -q 'glyphs: characters not drawn in the font' && printf '%s' "$a" | grep -q 'C D' \
      && ok "render: says which characters were drawn in another font, or in none (two workers' findings as one), and still renders" \
      || bad "render on the glyph fixture: exit $rc: $(printf '%s' "$a" | tail -c 700)"
  fi
  if command -v uv >/dev/null; then
    a=$(vh fonts subset "$ROOT/tools/film/fixture/glyphs.html" --font "$ROOT/tools/film/fixture/fonts/ab.ttf" --family "Fix AB" --out "$t/fs" 2>&1); rc=$?
    [ $rc = 0 ] && [ -s "$t/fs/OVHFixtureAB-Regular.subset.woff2" ] && printf '%s' "$a" | grep -q 'src: url(".*OVHFixtureAB-Regular.subset.woff2") format("woff2")' \
      && ok "fonts subset: a font cut to the project's characters as woff2, with its src line" || bad "fonts subset: exit $rc: $(printf '%s' "$a" | tail -c 600)"
    a=$(vh fonts list --all 2>&1); rc=$?
    [ $rc = 0 ] && printf '%s' "$a" | tail -1 | grep -q '^fonts: [0-9]* face(s)' && ok "fonts list: the faces on this machine by their local() names" || bad "fonts list: exit $rc: $(printf '%s' "$a" | tail -c 400)"
  else skip "fonts subset and list" "no uv"; fi
  mkdir "$t/cfr" && cp -R "$c/." "$t/cfr/"
  a=$(vh readcheck "$t/cfr" 2>&1); rc=$?
  if [ $rc = 0 ] && [ ! -e "$t/cfr/out/texts.json" ] && printf '%s' "$a" | grep -q 'subtitle'; then ok "canvas-film: readcheck judges the page's reads and captions using a private temporary snapshot"
  else bad "readcheck on a canvas-film project (exit $rc): $(printf '%s' "$a" | tail -c 800)"; fi
  # a HUD card over the cut S01 -> S02 (a settle), drawn by both shots with overlay: true, is one read over its whole time on
  # screen (4.4-8.6 s), not two pieces cut at the shots (the second 1.46 s, a false FAIL); an ordinary read still keeps to its
  # shot (S02's title: from the end of the settle in, 7.138 s, to the next cut, 12.283 s); textcheck samples the card on
  # both sides of the cut and finds it at each
  mkdir "$t/cfh" && cp -R "$c/." "$t/cfh/" && cat >> "$t/cfh/src/50-shots.js" <<'JS'
for (const S of SHOTS.slice(0, 2)) { const d = S.draw; S.draw = (t, s) => { d(t, s); label(t, 4.0, "跨镜头的字卡", 1300, 250, { size: 48, until: 9.0, overlay: true }); }; }
JS
  a=$(vh readcheck "$t/cfh" --out "$t/cfh-texts.json" 2>&1); rc=$?
  b=$(vh textcheck "$t/cfh" --out "$t/cfh-tc" 2>&1); rc2=$?
  if [ $rc = 0 ] && [ $rc2 = 0 ] && python3 - "$t/cfh-texts.json" "$t/cfh-tc/textcheck.json" <<'PY'
import json, sys
texts = json.load(open(sys.argv[1], encoding="utf-8"))
span = lambda s: [(x["start"], x["end"]) for x in texts if x["text"] == s]
r = next(r for r in json.load(open(sys.argv[2], encoding="utf-8"))["reads"] if r["text"] == "跨镜头的字卡")
ts = [q["t"] for q in r["samples"] if q["found"]]
sys.exit(0 if span("跨镜头的字卡") == [(4.4, 8.6)] and span("说到哪张，哪张落下") == [(7.138, 12.283)]
         and len(ts) == len(r["samples"]) and min(ts) < 6.638 < max(ts) else 1)
PY
  then ok "canvas-film: an overlay read spans the cut it is drawn across (readcheck), ordinary reads keep to their shot, and textcheck samples it on both sides"
  else bad "canvas-film overlay read (exit $rc / $rc2): $(printf '%s' "$a$b" | tail -c 800)"; fi
  # A too-short read still exports successfully; checking it fails. Outputs are independent, including concurrent runs,
  # and an existing manual snapshot is never replaced without --force. The output folder must not change the BRIEF's pace,
  # nor the check the export hint names (a file outside the project: --pace and a quoted path). A page with no texts is
  # nothing to check (2, not the 1 of a text under the floor); no browser names the remedies, not bin/vh readcheck itself.
  a=$(python3 - "$VH_BASH" "$ROOT" "$t" <<'PYREAD'
import json, pathlib, shlex, subprocess, sys
bash, root, tmp = sys.argv[1:]
p = pathlib.Path(tmp) / "readcheck args"; p.mkdir()
(p / "film.html").write_text('<!doctype html><head><meta name="viewport" content="width=320,height=180"></head><script>'
    'window.film={duration:4,frame(){},texts:[{id:"label",text:"CLAUDE.md router",start:0,end:1.6},'
    '{id:"short",text:"Too short",start:2,end:2.3}]};</script>', encoding="utf-8")
(p / "BRIEF.md").write_text("# BRIEF\n- Pace: relaxed\n", encoding="utf-8")
(p / "out").mkdir(); default = p / "out" / "texts.json"
manual = '[{"text":"hand edited","start":0,"end":3}]'; default.write_text(manual, encoding="utf-8")
cmd = [bash, str(pathlib.Path(root) / "bin" / "vh"), "readcheck"]
def run(args, code):
    r = subprocess.run(cmd + list(map(str, args)), capture_output=True, text=True)
    assert r.returncode == code, (args, r.returncode, r.stdout, r.stderr)
    return r.stdout + r.stderr
def exported(file):
    assert [i["id"] for i in json.loads(file.read_text(encoding="utf-8"))] == ["label", "short"], file
out = run([p], 1)
assert "WARN label" in out and "FAIL short" in out and "Pace in" in out, out
assert default.read_text(encoding="utf-8") == manual
run([p, "--export"], 2)
assert default.read_text(encoding="utf-8") == manual
out = run(["--export", p, "--force"], 0); exported(default)
assert "exported; check it with" in out and "FAIL short" not in out and "--pace" not in out, out
outside = pathlib.Path(tmp) / "outside export.json"
out = run([p, "--export", "--out", outside], 0); exported(outside)
hint = out.split("check it with ")[1].strip()
assert hint == "bin/vh readcheck " + shlex.quote(str(outside)) + " --pace relaxed", out
out = run(shlex.split(hint)[2:], 1)
assert "pace relaxed, --pace" in out and "WARN label" in out, out
r = subprocess.run([sys.executable, str(pathlib.Path(root) / "tools" / "readcheck.py"), "--browser", "", str(p)], capture_output=True, text=True)
assert r.returncode == 2 and "CHROME_PATH" in r.stderr and "run it as bin/vh" not in r.stderr, (r.returncode, r.stderr)
bare = pathlib.Path(tmp) / "readcheck no texts"; bare.mkdir()
(bare / "film.html").write_text('<!doctype html><head><meta name="viewport" content="width=320,height=180"></head><script>'
    'window.film={duration:2,frame(){}};</script>', encoding="utf-8")
out = run([bare], 2)
assert "gives no window.film.texts" in out and "NOT CHECKED" in out, out
saved = default.read_bytes()
custom = pathlib.Path(tmp) / "outside project.json"
out = run(["--out", custom, p], 1); exported(custom)
assert "Pace in" in out and "WARN label" in out, out
out = run([p, "--out", custom], 2)
assert "exists" in out and "--force" in out, out
run([p / "film.html", "--out", custom, "--force", "--pace", "brisk"], 1)
folder = pathlib.Path(tmp) / "export folder"; folder.mkdir()
run(["--out=" + str(folder), "--export", p], 0); exported(folder / "texts.json")
invalid = p / "invalid.json"
run([p, "--export", "--out", invalid, "--pace", "fast"], 2)
assert not invalid.exists()
# Two distinct outputs stay distinct; two writers to the same output have one success and one refusal (exclusive create).
for names, codes in ((["one.json", "two.json"], [0, 0]), (["shared.json", "shared.json"], [0, 2])):
    procs = [(p / name, subprocess.Popen(cmd + [str(p), "--export", "--out", str(p / name)],
             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)) for name in names]
    got = []
    for f, proc in procs:
        stdout, stderr = proc.communicate(); got.append(proc.returncode)
        assert proc.returncode in codes, (stdout, stderr)
        exported(f)
    assert sorted(got) == codes, got
assert default.read_bytes() == saved
print("canvas-film readcheck: export/check, custom outputs, original Pace (in the export hint too), --force, concurrent writers, a page with no texts, no browser")
PYREAD
  ); rc=$?
  if [ $rc = 0 ]; then ok "$a"; else bad "readcheck export/output regression: $a"; fi
  if command -v uv >/dev/null; then
    if python3 "$ROOT/tools/test_film_shots.py"; then ok "film shots: resolved times, real frames, source precedence and errors"; else bad "film shots"; fi
  else skip "film shots" "needs uv (Pillow for storyboard/rhythm)"; fi
  # Ctrl-C while a page is loading: the browser's profile folder goes too (Node would otherwise die without cleaning up)
  printf '%s\n' '<!doctype html><title>hang</title><script>window.film = { duration: 2, ready: new Promise(() => {}), frame() {} };</script>' > "$t/hang.html"
  mkdir -p "$t/tmpd"
  TMPDIR="$t/tmpd" "$VH_BASH" "$ROOT/bin/vh" frames "$t/hang.html" --at 1 --out "$t/hang-out" >/dev/null 2>&1 & pid=$!
  for _ in $(seq 1 120); do ls -d "$t/tmpd"/vh-textcheck-* >/dev/null 2>&1 && break; sleep 0.25; done
  seen=$(ls -d "$t/tmpd"/vh-textcheck-* 2>/dev/null | wc -l | tr -d ' ')   # a browser was up: otherwise this tests nothing
  sleep 1; kill -INT "$pid" 2>/dev/null; wait "$pid"; rc=$?; sleep 1
  left=$(ls -d "$t/tmpd"/vh-textcheck-* 2>/dev/null | wc -l | tr -d ' '); alive=$(pgrep -f "$t/tmpd" | wc -l | tr -d ' ')
  [ "$seen" -ge 1 ] && [ "$rc" = 130 ] && [ "$left" = 0 ] && [ "$alive" = 0 ] && ok "frames stopped with Ctrl-C ends (exit 130), leaving no browser profile and no Chrome behind" \
    || bad "frames after Ctrl-C: a browser seen $seen, exit $rc, $left profile folder(s) and $alive Chrome process(es) left"
  pkill -KILL -f "$t/tmpd" 2>/dev/null
  # the same Ctrl-C sent to the whole process group, as a terminal sends it, while readcheck or rhythm waits for the page:
  # exit 130, no traceback, no profile and no Chrome left (Python killed node 0.25 s in; uv run could exit 2 instead)
  mkdir -p "$t/hangp" "$t/tmpc" && cp "$t/hang.html" "$t/hangp/film.html"
  for c in readcheck rhythm; do
    if [ $c = rhythm ] && ! command -v uv >/dev/null; then skip "rhythm stopped with Ctrl-C" "needs uv"; continue; fi
    a=$(python3 - "$t/tmpc" "$VH_BASH" "$ROOT/bin/vh" $c "$t/hangp" <<'PY'
import glob, os, signal, subprocess, sys, time
tmp, cmd = sys.argv[1], sys.argv[2:]
p = subprocess.Popen(cmd, start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, env=dict(os.environ, TMPDIR=tmp))
for _ in range(120):
    if glob.glob(f"{tmp}/vh-textcheck-*") or p.poll() is not None: break
    time.sleep(0.25)
seen = len(glob.glob(f"{tmp}/vh-textcheck-*")); time.sleep(1)
try: os.killpg(p.pid, signal.SIGINT)
except OSError: pass   # it ended before the Ctrl-C: the exit code below says how
err = p.communicate(timeout=30)[1]; time.sleep(0.5)
print(seen, p.returncode, len(glob.glob(f"{tmp}/vh-textcheck-*")), "Traceback" in err, repr(err.strip()[-200:]))
PY
)
    alive=$(pgrep -f "$t/tmpc" | wc -l | tr -d ' ')
    want=130; [ $c = readcheck ] || want=-2   # rhythm runs through uv (on_ctrl_c): bin/vh ends by SIGINT itself
    case "$alive $a" in "0 1 $want 0 False "*) ok "$c stopped with Ctrl-C (to the process group) ends with $want and no traceback, leaving no browser profile and no Chrome" ;;
      *) bad "$c after Ctrl-C (Chrome left, browsers seen, exit, profiles left, traceback): $alive $a" ;; esac
    pkill -KILL -f "$t/tmpc" 2>/dev/null
  done
  # Ctrl-C while the profile folder is being removed (a preload sends SIGINT as the removal starts): the folder still goes
  # whole, and the Ctrl-C still ends the process (before, the listeners were gone by then and node died half way through)
  printf '%s\n' 'import fs from "node:fs"; const rm = fs.rmSync; let sent = false;' \
    'fs.rmSync = function (p, ...r) { if (!sent && /vh-textcheck-/.test(String(p))) { sent = true; process.kill(process.pid, "SIGINT"); } return rm.call(this, p, ...r); };' > "$t/rmsig.mjs"
  printf '%s\n' '<!doctype html><canvas id="c" width="64" height="36"></canvas><script>const x = document.getElementById("c").getContext("2d");' \
    'window.film = { duration: 2, frame() { x.fillStyle = "#345"; x.fillRect(0, 0, 64, 36); } };</script>' > "$t/one.html"
  mkdir -p "$t/tmpr"
  TMPDIR="$t/tmpr" NODE_OPTIONS="--import=$t/rmsig.mjs" "$VH_BASH" "$ROOT/bin/vh" frames "$t/one.html" --at 0.5 --out "$t/one-out" >/dev/null 2>&1; rc=$?; sleep 0.5
  left=$(ls -d "$t/tmpr"/vh-textcheck-* 2>/dev/null | wc -l | tr -d ' '); alive=$(pgrep -f "$t/tmpr" | wc -l | tr -d ' ')
  [ "$rc" = 130 ] && [ "$left" = 0 ] && [ "$alive" = 0 ] && ok "Ctrl-C while the browser profile is being removed: the folder goes whole, then the process ends (exit 130)" \
    || bad "Ctrl-C during the profile's removal: exit $rc, $left profile folder(s) and $alive Chrome process(es) left"
  pkill -KILL -f "$t/tmpr" 2>/dev/null
  # Ctrl-C after the last browser closed (determinism comparing its frames, synchronous work): the process ends at once,
  # not after the comparisons (a signal listener left in place would hold the signal until the event loop turned again).
  # 32 moments: their comparisons (an ffmpeg each, as D draws without the host's clock) take 1.6 s on an M3 Max and longer
  # on CI's runners, time enough to be caught at 0.1 s; the 95 there were took a minute to draw on GitHub's macOS runner
  printf '%s\n' '<!doctype html><canvas id="c" width="64" height="36"></canvas><script>const x = document.getElementById("c").getContext("2d");' \
    'window.film = { duration: 2, frame(t) { x.fillStyle = `rgb(${Math.floor(Math.random() * 255)},90,${Math.floor(t * 100)})`; x.fillRect(0, 0, 64, 36); } };</script>' > "$t/rnd.html"
  # Up to three tries to catch the comparisons; never caught, it is a failure on CI (CI=true) and a skip elsewhere
  seen=0
  for _ in 1 2 3; do
    "$VH_BASH" "$ROOT/bin/vh" determinism "$t/rnd.html" --at "$(seq -s, 0.02 0.06 1.9 | sed 's/,$//')" --out "$t/rnd-out" >/dev/null 2>&1 & pid=$!
    for _ in $(seq 1 600); do if pgrep -P "$pid" -f psnr >/dev/null 2>&1; then seen=1; break; fi; kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    [ $seen = 1 ] && break
    wait "$pid" 2>/dev/null
  done
  if [ $seen = 1 ]; then kill -INT "$pid" 2>/dev/null; wait "$pid"; rc=$?
    [ "$rc" = 130 ] && ok "determinism stopped with Ctrl-C while comparing ends at once (exit 130)" || bad "determinism after Ctrl-C while comparing: exit $rc (it went on)"
  elif [ "${CI:-}" = true ]; then bad "Ctrl-C while determinism compares: the comparisons were not caught running in 3 tries (on CI a failure, not a skip)"
  else skip "Ctrl-C while determinism compares" "the comparisons were not caught running in 3 tries"; fi
  rm -rf "$t"
}

# edit lists (bin/vh edit, tools/edit.py, engines/EDIT.md) on their fixture (tools/film/fixture/edit: a title card on its
# own clock, a chapter page on the film's clock whose duration is 10.04 s, a picture with a push, a slate and a black, cut on
# the narration). Without a browser: seconds to frames the same in Python and JS, build and its refusals, init, two shot
# tables; with one: a one-entry edit list renders the frames its page renders alone, a new take moves the entries (build
# and cues say so), patch puts back an entry that moved and refuses one away from what changed, determinism by runs, the
# shot tools find the entries, check and deliver refuse a film with a slate, versions compare says what changed
edit_checks() {
  local t a b c d e rc rc2 rc3 rc4 rc5 p
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  # frame_from and frame_at: the same frame in Python and JS for every frame boundary, a hair either side of it, the
  # values a double computes too small (4.1 s), 6.85 s, a computed duration and a fractional rate
  if python3 - "$ROOT" <<'PY'
import json, subprocess, sys
sys.path.insert(0, sys.argv[1] + "/tools")
from timegrid import frame_at, frame_from
cases = []
for fps in (24, 25, 30, 50, 60):
    for k in range(0, 400, 7):
        for d in (0, 1e-7, -1e-7):
            cases.append((k / fps + d / fps, fps))
cases += [(6.85, 30), (4.1, 30), (10.04, 30), (57.21333333333333, 30), (1.0, "24000/1001"), (12.2, "24000/1001"), (0.5, [30000, 1001])]
py = [[frame_from(t, r), frame_at(t, r)] for t, r in cases]
js = json.loads(subprocess.run(["node", "--input-type=module", "-e",
    "import { frameFrom, frameAt } from './tools/film/timegrid.mjs'; const c = JSON.parse(process.argv[1]); console.log(JSON.stringify(c.map(([t, r]) => [frameFrom(t, r), frameAt(t, r)])));",
    json.dumps(cases)], capture_output=True, text=True, cwd=sys.argv[1]).stdout)
ok = py == js and frame_from(6.85, 30) == 206 and frame_from(4.1, 30) == 123 and frame_from(10.04, 30) == 302 and frame_at(4.1, 30) == 123 \
    and frame_from(205 / 30 + 1e-7 / 30, 30) == 205 and frame_from(205 / 30 - 1e-7 / 30, 30) == 205
sys.exit(0 if ok else 1)
PY
  then ok "timegrid: frame_from and frame_at give the same frame in Python and JS (boundaries ±1e-7 frame, 4.1 s, 6.85 s, 10.04 s, 24000/1001)"
  else bad "timegrid: Python and JS disagree, or a known value is off"; fi
  # build on the fixture: whole frames, the slate said, the same bytes twice; the refusals, each with its exit code
  cp -R tools/film/fixture/edit "$t/e" && printf '# BRIEF\n' > "$t/e/BRIEF.md"
  a=$(vh edit build "$t/e" 2>&1); rc=$?
  cp "$t/e/out/edit.resolved.json" "$t/r1.json"; vh edit build "$t/e" >/dev/null 2>&1
  if [ $rc = 0 ] && cmp -s "$t/r1.json" "$t/e/out/edit.resolved.json" && printf '%s' "$a" | grep -q '68 frames at 30 fps · 6 entries on V1 (3 pages, 1 image, 1 slate, 1 colour)' \
     && printf '%s' "$a" | grep -q 'S04: a slate, no source yet' && python3 - "$t/e/out/edit.resolved.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
fr = {e["id"]: e["frames"] for e in d["entries"]}
ok = fr == {"S01": [0, 9], "S02": [9, 24], "S03": [24, 39], "S04": [39, 45], "S05": [45, 54], "S06": [54, 68]}
ok = ok and [r["draw"] for r in d["runs"]] == ["page", "page", "still", "slate", "page", "color"] and d["slates"] == ["S04"]
ok = ok and d["chapters"][1] == {"t": 0.8, "title": "二", "ref": "@|S03"} and d["refs"][0]["kind"] == "timeline" and d["entries"][1]["ref"] == {"end": "@l1>"}
sys.exit(0 if ok else 1)
PY
  then ok "edit build: the fixture in whole frames (@l1>, @l3:三, an end at 2.24 s, off the frame grid), its runs and slates, the same bytes twice"
  else bad "edit build on the fixture (exit $rc): $(printf '%s' "$a" | tail -c 600)"; fi
  vary() {   # vary <name> <python expression on d, the edit list>: a copy of the fixture with that change
    rm -rf "${t:?}/${1:?}"; cp -R "$t/e" "$t/$1"; rm -rf "${t:?}/${1:?}/out"
    python3 -c 'import json, sys; p = sys.argv[1] + "/edit.json"; d = json.load(open(p)); E = d["tracks"][0]["entries"]; exec(sys.argv[2]); json.dump(d, open(p, "w"), ensure_ascii=False)' "$t/$1" "$2"
  }
  vary gap 'E[2]["start"] = 1.0'; vary over 'E[2]["start"] = 0.6'; vary twice 'd["sources"]["title"]["clock"] = "local"; E[0].update({"in": 0, "out": 1, "dur": 2})'
  vary nolen 'del E[1]["end"]'; vary noref 'E[2]["end"] = "@l9>"; E[3]["src"] = "nosuch"'
  a=$(vh edit build "$t/gap" 2>&1); rc=$?; b=$(vh edit build "$t/over" 2>&1); rc2=$?; c=$(vh edit build "$t/twice" 2>&1); rc3=$?
  d=$(vh edit build "$t/nolen" 2>&1); rc4=$?; e=$(vh edit build "$t/noref" 2>&1); rc5=$?
  case "$rc:$rc2:$rc3:$rc4:$rc5" in 1:1:1:2:2)
      if printf '%s' "$a" | grep -q 'a gap between S02 and S03: frames 24–29' && printf '%s' "$b" | grep -q 'S03 overlaps S02 by 6 frames' \
         && printf '%s' "$c" | grep -q 'S01 is said twice over' && printf '%s' "$d" | grep -q 'S02: no length' \
         && printf '%s' "$e" | grep -q 'no narration line "l9"' && printf '%s' "$e" | grep -q 'S04: src "nosuch": no such source' && [ ! -e "$t/gap/out/edit.resolved.json" ]
      then ok "edit build refuses a gap, an overlap, out and dur that disagree (exit 1), a page with no length, a cue and a source that are not there (exit 2, listed together), and writes nothing"
      else bad "edit build's refusals say other things: $(printf '%s' "$a$b$c$d$e" | tail -c 900)"; fi ;;
    *) bad "edit build's refusals (exit $rc:$rc2:$rc3:$rc4:$rc5): $(printf '%s' "$a$b$c$d$e" | tail -c 900)" ;;
  esac
  # a pinned page that is another file, a pin on a colour, a time source outside the project (exit 2); a transition
  # between two sources, which render stops on, and a ledger that cannot be read under strict fail edit check (exit 1);
  # a page on its own clock at speed 2 is long enough while its last frame falls before its end
  vary pin 'd["sources"]["ch"]["sha256"] = "0" * 64; d["sources"]["black"]["sha256"] = "0" * 64'; vary outref 'd["refs"]["timeline"] = "/etc/hosts"'
  vary trans 'E[1]["transition"] = {"type": "turn", "duration": 0.8}'; vary badledger 'pass'
  mkdir -p "$t/badledger/assets" && printf '{' > "$t/badledger/assets/ledger.json"
  a=$(vh edit build "$t/pin" 2>&1); rc=$?; b=$(vh edit build "$t/outref" 2>&1); rc2=$?
  c=$(python3 tools/edit.py check "$t/trans" 2>&1); rc3=$?; d=$(python3 tools/edit.py check "$t/badledger" 2>&1); rc4=$?   # no browser: no page is read
  e=$(node --input-type=module -e 'import { pageShort } from "./tools/film/edit.mjs"; const r = (n) => pageShort({ clock: "local", in: 0.5, speed: 2, frames: [0, n] }, 2, 30);
    console.log(r(23) === null && Math.abs(r(24) - 2.0333) < 1e-3 && pageShort({ clock: "film", frames: [0, 302] }, 10.04, 30) === null && pageShort({ clock: "film", frames: [0, 303] }, 10.04, 30) !== null)' 2>&1)
  if [ "$rc:$rc2:$rc3:$rc4:$e" = 2:2:1:1:true ] && printf '%s' "$a" | grep -q 'ch.html is not the file pinned' && printf '%s' "$a" | grep -q 'sha256 pins a file, and a colour has none' \
     && printf '%s' "$b" | grep -q 'refs.timeline: /etc/hosts is outside the project' && printf '%s' "$c" | grep -q '✗ S02: a transition (turn 0.8 s) is not drawn yet.*bin/vh render stops on it' \
     && printf '%s' "$d" | grep -q '✗ the asset ledger could not be read'
  then ok "edit build refuses a page that is not the file pinned, a pin on a colour, a time source outside the project; edit check fails a transition render stops on and a ledger it cannot read (strict); a page at speed 2 is long enough to its last frame"
  else bad "pins, refs, transitions, the ledger (exit $rc:$rc2:$rc3:$rc4, pageShort $e): $(printf '%s' "$a$b" | tail -c 500) | $(printf '%s' "$c$d" | tail -c 500)"; fi
  # init folds shots.json in: every shot a slate, timed as it was; shots with a gap are refused with nothing written; a
  # project with both tables is told to keep one (storyboard stops)
  mkdir -p "$t/i" "$t/ig" && printf '# BRIEF\n- Output: 1280x720, 25 fps, exactly 4s\n' > "$t/i/BRIEF.md" && cp "$t/i/BRIEF.md" "$t/ig/BRIEF.md"
  printf '[{"id": "S01", "start": 0, "end": 1.5, "reads": "一"}, {"id": "S02", "start": "0:01.5", "end": 4, "unsure": "?"}]\n' > "$t/i/shots.json"
  printf '[{"id": "S01", "start": 0, "end": 1.5}, {"id": "S02", "start": 2, "end": 4}]\n' > "$t/ig/shots.json"
  a=$(vh edit init "$t/i" 2>&1); rc=$?; b=$(vh edit init "$t/i" 2>&1); rc2=$?; c=$(vh edit init "$t/ig" 2>&1); rc3=$?
  cp "$t/i/shots.json.folded" "$t/i/shots.json"; d=$(vh storyboard "$t/i" 2>&1); rc4=$?; rm "$t/i/shots.json"
  mkdir -p "$t/i2" && cp "$t/i/BRIEF.md" "$t/i/shots.json.folded" "$t/i2/" && printf '[{"id": "S01", "start": 0, "end": 2}]\n' > "$t/i2/shots.json"
  vh edit init "$t/i2" >/dev/null 2>&1   # a project folded before (its edit.json since taken away): the first fold's copy stays
  if [ "$rc:$rc2:$rc3:$rc4" = 0:2:1:1 ] && [ -f "$t/i/shots.json.folded" ] && [ -f "$t/ig/shots.json" ] && [ ! -e "$t/ig/edit.json" ] \
     && grep -q '"unsure": "?"' "$t/i2/shots.json.folded" && grep -q '"end": 2' "$t/i2/shots.json.folded-2" \
     && printf '%s' "$c" | grep -q 'a gap between S01 and S02' && printf '%s' "$d" | grep -q 'two shot tables' && python3 - "$t/i" <<'PY'
import json, sys
d = json.load(open(sys.argv[1] + "/edit.json")); r = json.load(open(sys.argv[1] + "/out/edit.resolved.json"))
E = d["tracks"][0]["entries"]
ok = d["fps"] == 25 and d["size"] == [1280, 720] and [e["src"] for e in E] == [None, None] and "start" not in E[1] and E[1]["unsure"] == "?"
ok = ok and r["frames"] == 100 and r["slates"] == ["S01", "S02"] and r["entries"][1]["frames"] == [38, 100]
sys.exit(0 if ok else 1)
PY
  then ok "edit init: shots.json folded into slates (the BRIEF's size and rate), kept as shots.json.folded (a later fold beside it, -2); a second init, shots with a gap, two shot tables refused"
  else bad "edit init (exit $rc:$rc2:$rc3:$rc4): $(printf '%s' "$a$b$c$d" | tail -c 700)"; fi
  # the rest draws: a browser (the first render says when there is none). Few renders, one worker where they are
  # short: a macOS runner starts each browser cold
  command -v ffmpeg >/dev/null || { skip "edit lists drawn" "no ffmpeg"; rm -rf "$t"; return; }
  # a one-entry edit list of the chapter page made 0.54 s long (end: its duration, not on a frame: 17 frames, the last
  # chunk 2 at --gop 15) renders what the page renders alone
  mkdir -p "$t/one" && sed 's/duration: 2.24,/duration: 0.54,/' "$t/e/ch.html" > "$t/one/ch.html" && cp -R "$t/e/audio" "$t/one/"
  printf '{"v": 1, "fps": 30, "size": [160, 90], "sources": {"ch": {"page": "ch.html", "clock": "film"}}, "tracks": [{"id": "V1", "entries": [{"id": "S01", "src": "ch", "end": 0.54}]}]}\n' > "$t/one/edit.json"
  a=$(vh render "$t/one/ch.html" --gop 15 --workers 1 --out "$t/one/page.mp4" 2>&1); rc=$?
  case "$rc:$a" in 2:*"needs a headless Chrome"*) no_chrome "edit lists drawn"; rm -rf "$t"; return ;; esac
  a=$(vh render "$t/one" --gop 15 --workers 1 --out "$t/one/edit.mp4" 2>&1); rc=$?
  if [ $rc = 0 ] && python3 - "$t/one" <<'PY'
import json, re, subprocess, sys
d = sys.argv[1]
md5 = lambda f: [l.split(",")[-1].strip() for l in subprocess.run(["ffmpeg", "-v", "error", "-i", f, "-f", "framemd5", "-"], capture_output=True, text=True).stdout.splitlines() if l and not l.startswith("#")]   # noqa: E731
a, b = md5(d + "/page.mp4"), md5(d + "/edit.mp4")
same = a == b
if not same and len(a) == len(b):   # a browser that rasterises a page differently twice: the same picture is 45 dB or more
    r = subprocess.run(["ffmpeg", "-v", "info", "-i", d + "/page.mp4", "-i", d + "/edit.mp4", "-lavfi", "psnr", "-f", "null", "-"], capture_output=True, text=True).stderr
    m = re.findall(r"min:(inf|[\d.]+)", r)
    same = bool(m) and (m[-1] == "inf" or float(m[-1]) >= 45)
side = json.load(open(d + "/edit.mp4.render.json"))
ok = len(a) == 17 and len(b) == 17 and same and side["kind"] == "edit" and side["page"] == "edit.json" and side["runs"][0]["chunks"][0]["key"]
for f in ("/page.mp4", "/edit.mp4"):   # the last chunk is 2 frames: the frame rate stays whole, a constant-rate decode gives 17 frames
    rate = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=avg_frame_rate", "-of", "csv=p=0", d + f], capture_output=True, text=True).stdout.strip()
    n = len(subprocess.run(["ffmpeg", "-v", "error", "-i", d + f, "-vf", "scale=1:1", "-f", "rawvideo", "-pix_fmt", "gray", "-"], capture_output=True).stdout)
    ok = ok and rate == "30/1" and n == 17
sys.exit(0 if ok else 1)
PY
  then ok "render: a one-entry edit list of a film-clock page (0.54 s) is the page's 17 frames, the same pictures, and its sidecar records the runs and chunk keys; with a last chunk of 2 frames both stay 30/1, 17 frames decoded at a constant rate ($(printf '%s' "$a" | grep -o '[0-9]* ms a frame' | head -1) here)"
  else bad "render of a one-entry edit list (exit $rc): $(printf '%s' "$a" | tail -c 600)"; fi
  # runs of 6, 1, 2 and 7 frames at --gop 5 (chunks of 1 and 2 frames in the middle, and a run of each): every packet one
  # frame long, and a constant-rate decode (bin/vh check's) gives each frame its own colour, 16 of them
  mkdir -p "$t/short" && python3 -c 'import json, sys; L = [6, 1, 2, 7]; C = ["#ff0000", "#00ff00", "#0000ff", "#ffff00"]
json.dump({"v": 1, "fps": 30, "size": [160, 90], "sources": {f"c{i}": {"color": c} for i, c in enumerate(C)},
           "tracks": [{"id": "V1", "entries": [{"id": f"S{i + 1:02d}", "src": f"c{i}", "dur": n / 30} for i, n in enumerate(L)]}]}, open(sys.argv[1], "w"))' "$t/short/edit.json"
  a=$(vh render "$t/short" --gop 5 --workers 1 2>&1); rc=$?
  if [ $rc = 0 ] && python3 - "$t/short/out/edit.mp4" <<'PY'
import subprocess, sys
f = sys.argv[1]
durs = {l.strip() for l in subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "packet=duration", "-of", "csv=p=0", f],
                                          capture_output=True, text=True).stdout.split()}
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", f, "-vf", "scale=1:1:flags=area", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
C = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)]
want = [c for c, n in zip(C, [6, 1, 2, 7]) for _ in range(n)]
got = [tuple(raw[3 * i:3 * i + 3]) for i in range(len(raw) // 3)]
sys.exit(0 if len(durs) == 1 and len(got) == 16 and all(max(abs(x - y) for x, y in zip(g, w)) <= 40 for g, w in zip(got, want)) else 1)
PY
  then ok "render: runs of 6, 1, 2 and 7 frames at --gop 5 join with every packet one frame long; a constant-rate decode gives the 16 frames, each its own colour"
  else bad "render of short runs (exit $rc): $(printf '%s' "$a" | tail -c 400)"; fi
  # the fixture rendered; a new take of the narration (line 1 ends 0.1 s earlier): S02 is 3 frames shorter, S03 3
  # longer, and build and cues say so; patch --shot S05 is refused (the frames that changed are outside it), --shot S03
  # puts S02's tail and S03 back, the same frames a whole render makes
  p="$t/e"; rm -rf "$p/out"
  vh render "$p" --gop 10 --workers 1 --out "$p/out/film.mp4" >/dev/null 2>&1
  vh cues "$p" --save >/dev/null 2>&1
  sed 's/"end": 0.8, "text": "第一句话", "words": \[{"w": "第一句话", "start": 0.1, "end": 0.8}\]/"end": 0.7, "text": "第一句话", "words": [{"w": "第一句话", "start": 0.1, "end": 0.7}]/' \
    tools/film/fixture/edit/audio/timeline.zh.json > "$p/audio/timeline.zh.json"
  a=$(vh edit build "$p" 2>&1); b=$(vh cues "$p" 2>&1); rc=$?
  c=$(vh patch "$p/out/film.mp4" --shot S05 --out "$p/out/s5.mp4" 2>&1); rc2=$?
  d=$(vh patch "$p/out/film.mp4" --shot S03 --in-place 2>&1); rc3=$?
  vh render "$p" --gop 10 --workers 1 --fresh --out "$p/out/fresh.mp4" >/dev/null 2>&1
  if [ "$rc:$rc2:$rc3" = 0:2:0 ] && printf '%s' "$a" | grep -q 'S03 moved −0.100 s (−3 frames) (audio/timeline.zh.json changed); S02 is shorter by 0.100 s (3 frames)' \
     && printf '%s' "$b" | grep -q 'S03 moved −0.100 s (another take of the narration)' && printf '%s' "$b" | grep -q 'S02.c1 moved −0.075 s' \
     && printf '%s' "$c" | grep -q 'the edit list changed in S02, S03' && [ ! -e "$p/out/s5.mp4" ] && printf '%s' "$d" | grep -q "frames: 68 (the film: 68) ✓" \
     && python3 - "$p" <<'PY'
import json, re, subprocess, sys
p = sys.argv[1]
md5 = lambda f: [l.split(",")[-1].strip() for l in subprocess.run(["ffmpeg", "-v", "error", "-i", f, "-f", "framemd5", "-"], capture_output=True, text=True).stdout.splitlines() if l and not l.startswith("#")]   # noqa: E731
a, b = md5(p + "/out/film.mp4"), md5(p + "/out/fresh.mp4")
same = a == b
if not same and len(a) == len(b):
    r = subprocess.run(["ffmpeg", "-v", "info", "-i", p + "/out/film.mp4", "-i", p + "/out/fresh.mp4", "-lavfi", "psnr", "-f", "null", "-"], capture_output=True, text=True).stderr
    m = re.findall(r"min:(inf|[\d.]+)", r)
    same = bool(m) and (m[-1] == "inf" or float(m[-1]) >= 45)
side = json.load(open(p + "/out/film.mp4.render.json"))
runs = {r["entry"]: (r["frames"], [c["frames"] for c in r["chunks"]]) for r in side["runs"]}
ok = same and len(a) == 68 and runs["S02"] == ([9, 21], [[9, 19], [19, 21]]) and runs["S03"][0] == [21, 39] and runs["S05"][1] == [[45, 54]]
sys.exit(0 if ok else 1)
PY
  then ok "a new take moves the entries (build and cues say by how much); patch refuses an entry away from what changed, puts back the one that moved: the frames a whole render makes, the sidecar's runs the edit list's now"
  else bad "edit list after a new take (cues $rc, patch S05 $rc2, patch S03 $rc3): $(printf '%s' "$a" | tail -c 300) | $(printf '%s' "$b" | tail -c 300) | $(printf '%s' "$c$d" | tail -c 500)"; fi
  # determinism by runs (on two: a page on its own clock, an image with a push); frames at a time and into an entry; the
  # shot tools find the entries with no shots.json (storyboard's tiles from the film)
  cp -R "$p" "$t/d3" && rm -rf "$t/d3/out" && python3 -c 'import json, sys; f = sys.argv[1]; d = json.load(open(f)); E = d["tracks"][0]["entries"]
d["tracks"][0]["entries"] = [{"id": "S01", "src": "title", "dur": 0.2}, {**{k: E[2][k] for k in ("src", "fit", "move")}, "id": "S02", "dur": 0.2}]
d.pop("chapters", None); json.dump(d, open(f, "w"), ensure_ascii=False)' "$t/d3/edit.json"
  a=$(vh determinism "$t/d3" --out "$t/det" 2>&1); rc=$?
  b=$(vh frames "$p" --entry S03 --at 0,0.2 --out "$t/fe" 2>&1); rc2=$?
  python3 -c 'import json, sys; f = sys.argv[1]; d = json.load(open(f)); d["video"] = "out/film.mp4"; json.dump(d, open(f, "w"), ensure_ascii=False)' "$p/edit.json"
  c=$(vh storyboard "$p" 2>&1); rc3=$?
  d=$(vh thumbs "$p/out/film.mp4" --every 1 --width 80 --json 2>&1); rc4=$?
  e=$(python3 - "$p" <<'PY'
import sys
sys.path.insert(0, "tools/desk"); sys.path.insert(0, "tools")
from pathlib import Path
import reader
w = []
s = reader._shots(Path(sys.argv[1]), [], [], w)
print(len(s.get("items", [])), [x["id"] for x in s.get("items", [])][:2], w)
PY
)
  if [ "$rc:$rc2:$rc3:$rc4" = 0:0:0:0 ] && printf '%s' "$a" | grep -q 'an edit list, 2 runs' && printf '%s' "$a" | grep -q 'determinism: holds' \
     && [ -s "$t/fe/edit-S03-t0000.200.png" ] && printf '%s' "$c" | grep -q 'shots from: edit.json' && [ "$e" = "6 ['S01', 'S02'] []" ] \
     && printf '%s' "$d" | python3 -c 'import json, sys; d = json.load(sys.stdin); sys.exit(0 if [s["id"] for s in d["shots"]] == ["S01", "S02", "S03", "S04", "S05", "S06"] and "edit list" in d["shots_from"] else 1)'
  then ok "determinism holds run by run; frames --entry; storyboard, thumbs and the review desk find the entries with no shots.json"
  else bad "edit list's frames and shots (exit $rc:$rc2:$rc3:$rc4, desk: $e): $(printf '%s' "$a$b$c" | tail -c 700) | $(printf '%s' "$d" | tail -c 200)"; fi
  # check fails a film with a slate left, and says which entry each finding is in; deliver refuses it; versions compare
  # says what changed entry by entry
  a=$(vh check "$p/out/film.mp4" 2>&1); rc=$?
  b=$(vh deliver "$p/out/film.mp4" --psnr off 2>&1); rc2=$?
  c=$(vh versions compare "$p" v1 v2 --t 2.0 2>&1); rc3=$?
  if [ "$rc:$rc2:$rc3" = 1:2:0 ] && printf '%s' "$a" | grep -q '1 slate left, S04 (1.30–1.50 s)' && printf '%s' "$a" | grep -q 'in S06 (color black)' \
     && printf '%s' "$b" | grep -q '1 slate left in it (S04)' && [ ! -e "$p/out/film.upload.mp4" ] && printf '%s' "$c" | grep -q 'the edit list, v1 → v2: S03 moved −0.100 s' \
     && python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); f = [x for x in d["findings"] if x["kind"] == "check.slate"]; sys.exit(0 if f and f[0]["severity"] == "fail" and f[0]["frames"] == [39, 44] else 1)' "$p/out/check/film.check.json"
  then ok "check fails a film with a slate left and puts each finding in its entry; deliver refuses it; versions compare says what changed entry by entry"
  else bad "check / deliver / versions on an edit list's film (exit $rc:$rc2:$rc3): $(printf '%s' "$a" | tail -c 500) | $(printf '%s' "$b$c" | tail -c 400)"; fi
  # a local-clock page that hangs cues on the narration: cues and edit check say so (a note, exit 0)
  vary localcues 'd["sources"]["ch"]["clock"] = "local"; E[1].pop("end"); E[1]["dur"] = 0.4; E[4].pop("end"); E[4]["dur"] = 0.3'
  a=$(vh cues "$t/localcues" 2>&1); rc=$?; b=$(vh edit check "$t/localcues" 2>&1); rc2=$?
  if [ "$rc" = 0 ] && printf '%s' "$a" | grep -q 'ch.html is on its own clock and hangs 1 cue on the narration' && printf '%s' "$b" | grep -q 'S02: ch is on its own clock and hangs 1 cue'
  then ok "a local-clock page with cues on the narration is said by cues and edit check"
  else bad "a local-clock page with cues (exit $rc:$rc2): $(printf '%s' "$a" | tail -c 400) | $(printf '%s' "$b" | tail -c 400)"; fi
  rm -rf "$t"
}

# an edit list's footage (engines/EDIT.md): a clip picked frame by frame into another rate, its chunks joined to a page's
# (JPEG and PNG), patched; a colour chart drawn as a page, an image and a clip; the clip's sound in the mix, its words in
# the captions; what build refuses of footage and sound entries. Small and short: macOS runners draw a frame in a second
edit_footage_checks() {
  local t p a b c d e rc rc2 rc3 rc4
  command -v ffmpeg >/dev/null || { skip "an edit list's footage" "no ffmpeg"; return; }
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX"); p="$t/f"
  # a clip as bin/vh footage get makes one (24000/1001 fps, BT.709 tv with its tags, closed GOPs a second apart, its sound
  # as audio.wav, its words): each frame shows its own number in binary, eight squares along the top
  mkdir -p "$p/assets/footage/cam" "$p/audio" && cp tools/film/fixture/edit/title.html "$p/" && printf '# BRIEF\n' > "$p/BRIEF.md"
  if ! python3 - "$p" <<'PY'
import hashlib, json, subprocess, sys
from pathlib import Path
p = Path(sys.argv[1]); d = p / "assets/footage/cam"
lum = "if(lt(Y,20),16+219*mod(floor(N/pow(2,floor(X/20))),2),126)"
subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "color=c=gray:s=160x90:r=24000/1001:d=2", "-f", "lavfi", "-i", "sine=frequency=330:sample_rate=48000:duration=2",
                "-vf", f"format=yuv420p,geq=lum='{lum}':cb=128:cr=128,setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv",
                "-c:v", "libx264", "-crf", "12", "-g", "24", "-keyint_min", "24", "-sc_threshold", "0", "-flags", "+cgop", "-color_range", "tv", "-colorspace", "bt709",
                "-color_primaries", "bt709", "-color_trc", "bt709", "-c:a", "aac", "-shortest", "-movflags", "+faststart", str(d / "clip.mp4")], check=True)
subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(d / "clip.mp4"), "-vn", "-c:a", "pcm_s16le", "-ar", "48000", str(d / "audio.wav")], check=True)
n = int(subprocess.run(["ffprobe", "-v", "error", "-count_packets", "-select_streams", "v:0", "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", str(d / "clip.mp4")],
                       capture_output=True, text=True).stdout.strip())
sha = lambda f: hashlib.sha256(f.read_bytes()).hexdigest()   # noqa: E731
(d / "words.json").write_text(json.dumps({"segments": [
    {"id": "1", "start": 0.6, "end": 1.3, "text": "码头上的人", "words": [{"w": "码头", "start": 0.6, "end": 0.9}, {"w": "上的人", "start": 0.95, "end": 1.3}]},
    {"id": "2", "start": 1.33, "end": 1.7, "text": "船来了", "words": [{"w": "船", "start": 1.33, "end": 1.45}, {"w": "来了", "start": 1.45, "end": 1.7}]}]}, ensure_ascii=False))
json.dump({"v": 1, "id": "cam", "asset": "cam", "file": "clip.mp4", "sha256": sha(d / "clip.mp4"), "rate": "24000/1001", "frames": n, "duration": round(n * 1001 / 24000, 3),
           "size": [160, 90], "sar": "1:1", "color": ["tv", "bt709", "bt709", "bt709"], "assumed": [], "gop": 24,
           "audio": {"file": "audio.wav", "sha256": sha(d / "audio.wav"), "rate": 48000, "channels": 1}, "from": None, "crop": None, "cuts": [],
           "words": "words.json", "sync": {"group": "g", "c": 0.5, "k": 1}, "source": {}}, open(d / "clip.json", "w"))
(p / "audio/timeline.zh.json").write_text(json.dumps({"lang": "zh", "segments": [
    {"id": "l1", "start": 0.05, "end": 0.45, "text": "第一句话", "zh": "第一句话", "words": [{"w": "第一句话", "start": 0.05, "end": 0.45}]}]}, ensure_ascii=False))
json.dump({"v": 1, "fps": 30, "size": [160, 90], "refs": {"timeline": "audio/timeline.zh.json"},
           "sources": {"title": {"page": "title.html", "clock": "local"}, "cam": {"clip": "assets/footage/cam", "sound": {"role": "voice"}}, "black": {"color": "#000000"}},
           "tracks": [{"id": "V1", "entries": [{"id": "S01", "src": "title", "dur": 0.5}, {"id": "S02", "src": "cam", "in": 0.5, "dur": 1},
                                               {"id": "S03", "src": "black", "dur": 0.3}]}]}, open(p / "edit.json", "w"))
PY
  then bad "an edit list's footage: the test clip could not be made"; rm -rf "$t"; return; fi
  # 24000/1001 into 30: film frame k of S02 shows clip frame 11 + ⌊(k − 15)·800/1001⌋ (11: the frame on screen at 0.5 s),
  # read back from the film; the page's chunk and the clip's are one SPS/PPS, and the film decodes to the end; the same
  # with the page captured as PNG (--png: frames 9–20, a page chunk and a clip chunk)
  a=$(vh render "$p" --gop 15 --workers 2 2>&1); rc=$?
  case "$rc:$a" in 2:*"needs a headless Chrome"*) no_chrome "an edit list's footage"; rm -rf "$t"; return ;; esac
  b=$(vh render "$p" --png --frames 9:21 --gop 15 --workers 1 --out "$p/out/png.mp4" 2>&1); rc2=$?
  if [ "$rc:$rc2" = 0:0 ] && printf '%s' "$a" | grep -q 'S02 cam: 24000/1001 fps into 30 fps: one frame shown twice' && python3 - "$p" <<'PY'
import json, subprocess, sys
p, W, H = sys.argv[1], 160, 90
def frames(f):
    dec = subprocess.run(["ffmpeg", "-v", "error", "-i", f, "-vf", "format=gray", "-f", "rawvideo", "-"], capture_output=True)
    return [dec.stdout[i * W * H:(i + 1) * W * H] for i in range(len(dec.stdout) // (W * H))], dec.stderr.strip()
code = lambda x: sum((x[10 * W + 20 * b + 10] > 128) << b for b in range(8))   # noqa: E731
f, err = frames(p + "/out/edit.mp4")
g, err2 = frames(p + "/out/png.mp4")
side = json.load(open(p + "/out/edit.mp4.render.json"))
ok = len(f) == 54 and [code(x) for x in f[15:45]] == [11 + m * 800 // 1001 for m in range(30)] and err == b"" and len(g) == 12 and err2 == b""
ok = ok and [code(x) for x in g[6:12]] == [11 + m * 800 // 1001 for m in range(6)]
ok = ok and side["inputs"] == {"page": "jpeg q95", "clip": "rgb24"} and [r["draw"] for r in side["runs"]] == ["page", "clip", "color"]
sys.exit(0 if ok else 1)
PY
  then ok "footage at 24000/1001 in a 30 fps edit list: each film frame shows the clip frame j_in + ⌊(k − K0)·rate/fps⌋; its chunks and the page's join into a film that decodes to the end, the page's as JPEG and as PNG"
  else bad "an edit list's footage drawn (exit $rc:$rc2): $(printf '%s' "$a" | tail -c 400) | $(printf '%s' "$b" | tail -c 400)"; fi
  # its sound in the mix (the voice bus), its words in the merged timeline (a word mostly past the cut left out) and in
  # the captions; an events.json header with "edit" takes "@|S02"; the muxed film keeps its picture's render record
  printf '{"refs": {"edit": "../out/edit.resolved.json"}, "events": [{"t": "@|S02", "sfx": "a.wav"}, {"t": "@|S02>-0.2", "sfx": "a.wav"}]}\n' > "$p/audio/events.json"
  a=$(vh mix "$p/audio/mix.wav" edit="$p" 2>&1); rc=$?
  b=$(vh mux "$p/out/edit.mp4" "$p/audio/mix.wav" "$p/out/final.mp4" 2>&1); rc2=$?
  c=$(vh captions "$p" 2>&1); rc3=$?
  if [ "$rc:$rc2:$rc3" = 0:0:0 ] && printf '%s' "$a" | grep -q 'edit: 1 sound of footage on the voice bus (S02)' && printf '%s' "$c" | grep -q 'out/edit.timeline.zh.json' \
     && python3 - "$p" <<'PY'
import json, sys
sys.path.insert(0, "tools/audio"); sys.path.insert(0, "tools")
import edit, time_refs
p = sys.argv[1]
tl = json.load(open(p + "/out/edit.timeline.zh.json"))
lines = [(s["id"], s["start"], s["end"], s["text"]) for s in tl["segments"]]
srt = open(p + "/audio/captions.zh.srt", encoding="utf-8").read()
ev, _, _ = time_refs.load_events(p + "/audio/events.json")
ok = lines == [("l1", 0.05, 0.45, "第一句话"), ("S02_1", 0.641, 1.341, "码头上的人"), ("S02_2", 1.371, 1.491, "船")]
ok = ok and "00:00:00,050 -->" in srt and "00:00:00,641 -->" in srt and "码头上的人" in srt and "来了" not in srt and [round(e["t"], 6) for e in ev] == [0.5, 1.3]
mux = json.load(open(p + "/out/final.mp4.mux.json"))
ok = ok and mux["video"] == "edit.mp4" and mux["render"]["kind"] == "edit" and "as bin/vh mux kept it" in edit.film_facts(p + "/out/final.mp4")["from"]
sys.exit(0 if ok else 1)
PY
  then ok "the clip's sound goes on the voice bus; its words join the narration in film seconds (one mostly past the cut left out), and captions and \"@|S02\" in events.json follow them; the muxed film keeps its picture's render record"
  else bad "an edit list's footage sound (mix $rc, mux $rc2, captions $rc3): $(printf '%s' "$a" | tail -c 300) | $(printf '%s' "$b" | tail -c 300) | $(printf '%s' "$c" | tail -c 300)"; fi
  # the clip's clip.json changed (its sync): mux refuses the mix made before; S02 starts 0.1 s later in the clip: patch
  # --shot S02 draws it again, the frames a render of them makes (S02's alone: footage, no browser; clip frame 14 first);
  # determinism holds for its frames
  python3 -c 'import json, sys; f = sys.argv[1]; c = json.load(open(f)); c["sync"]["c"] = 0.52; json.dump(c, open(f, "w"))' "$p/assets/footage/cam/clip.json"
  a=$(vh mux "$p/out/edit.mp4" "$p/audio/mix.wav" "$p/out/final2.mp4" 2>&1); rc=$?
  python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); d["tracks"][0]["entries"][1]["in"] = 0.6; json.dump(d, open(sys.argv[1], "w"))' "$p/edit.json"
  b=$(vh patch "$p/out/edit.mp4" --shot S02 --in-place 2>&1); rc2=$?
  vh render "$p" --frames 15:45 --gop 15 --workers 1 --fresh --out "$p/out/fresh.mp4" >/dev/null 2>&1
  c=$(vh determinism "$p" --out "$t/det" 2>&1); rc3=$?
  if [ "$rc" != 0 ] && [ "$rc2:$rc3" = 0:0 ] && printf '%s' "$a" | grep -q 'clip.json' && [ ! -e "$p/out/final2.mp4" ] && printf '%s' "$c" | grep -q 'determinism: holds' \
     && python3 - "$p" <<'PY'
import re, subprocess, sys
p, W, H = sys.argv[1], 160, 90
md5 = lambda f: [l.split(",")[-1].strip() for l in subprocess.run(["ffmpeg", "-v", "error", "-i", f, "-f", "framemd5", "-"], capture_output=True, text=True).stdout.splitlines() if l and not l.startswith("#")]   # noqa: E731
a, b = md5(p + "/out/edit.mp4"), md5(p + "/out/fresh.mp4")
same = len(a) == 54 and a[15:45] == b   # the footage: exact
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", p + "/out/edit.mp4", "-vf", "select=eq(n\\,15),format=gray", "-frames:v", "1", "-f", "rawvideo", "-"], capture_output=True).stdout
sys.exit(0 if same and sum((raw[10 * W + 20 * b + 10] > 128) << b for b in range(8)) == 14 else 1)
PY
  then ok "a clip's clip.json changed: mux refuses the mix made before; a clip entry moved in its clip: patch --shot draws it again as a whole render does; determinism holds for its frames"
  else bad "a clip entry changed (mux $rc, patch $rc2, determinism $rc3): $(printf '%s' "$a" | tail -c 300) | $(printf '%s' "$b" | tail -c 300) | $(printf '%s' "$c" | tail -c 300)"; fi
  # one colour chart as a page (canvas), an image (PNG) and a lossless clip (BT.709 tv), two frames each: each patch's
  # mean within 1 level and every channel within 3 between any two of them
  if python3 - "$t/chart" <<'PY'
import hashlib, json, struct, subprocess, sys, zlib
from pathlib import Path
p = Path(sys.argv[1]); (p / "img").mkdir(parents=True); (p / "cl").mkdir()
C = [(200, 60, 60), (60, 180, 60), (60, 80, 200), (128, 128, 128), (210, 160, 120), (32, 40, 48)]
box = [(i % 3 * 50 + 5, i // 3 * 45 + 7) for i in range(6)]
def px(x, y):
    return next((c for (bx, by), c in zip(box, C) if bx <= x < bx + 40 and by <= y < by + 30), (232, 226, 208))
raw = b"".join(b"\x00" + bytes(v for x in range(160) for v in px(x, y)) for y in range(90))
chunk = lambda k, d: struct.pack(">I", len(d)) + k + d + struct.pack(">I", zlib.crc32(k + d) & 0xFFFFFFFF)   # noqa: E731
(p / "img/chart.png").write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 160, 90, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
subprocess.run(["ffmpeg", "-v", "error", "-y", "-loop", "1", "-framerate", "30", "-i", str(p / "img/chart.png"), "-frames:v", "4", "-vf",
                "scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,format=yuv420p,setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv",
                "-c:v", "libx264", "-qp", "0", "-g", "30", "-color_range", "tv", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", str(p / "cl/clip.mp4")], check=True)
json.dump({"v": 1, "id": "cl", "file": "clip.mp4", "sha256": hashlib.sha256((p / "cl/clip.mp4").read_bytes()).hexdigest(), "rate": "30", "frames": 4, "duration": 0.133,
           "size": [160, 90], "color": ["tv", "bt709", "bt709", "bt709"], "assumed": [], "audio": None, "words": None}, open(p / "cl/clip.json", "w"))
fills = "".join(f'x.fillStyle = "rgb{c}"; x.fillRect({bx}, {by}, 40, 30);' for (bx, by), c in zip(box, C))
(p / "chart.html").write_text('<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=160, height=90"><style>html,body{margin:0}'
                              'canvas{display:block}</style></head><body><canvas id="c" width="160" height="90"></canvas><script>const x = document.getElementById("c").getContext("2d");'
                              f'window.film = {{ duration: 1, frame(t) {{ x.fillStyle = "rgb(232, 226, 208)"; x.fillRect(0, 0, 160, 90); {fills} }} }};</script></body></html>\n')
two = 2 / 30
json.dump({"v": 1, "fps": 30, "size": [160, 90], "sources": {"page": {"page": "chart.html", "clock": "film"}, "img": {"image": "img/chart.png"}, "cl": {"clip": "cl"}},
           "tracks": [{"id": "V1", "entries": [{"id": "S01", "src": "page", "dur": two}, {"id": "S02", "src": "img", "dur": two}, {"id": "S03", "src": "cl", "dur": two}]}]},
          open(p / "edit.json", "w"))
PY
  then a=$(vh render "$t/chart" --workers 1 2>&1); rc=$?
  else a="the chart could not be made"; rc=9; fi
  if [ $rc = 0 ] && python3 - "$t/chart/out/edit.mp4" <<'PY'
import subprocess, sys
box, W = [(i % 3 * 50 + 5, i // 3 * 45 + 7) for i in range(6)], 160
def means(n):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", sys.argv[1], "-vf", f"select=eq(n\\,{n})", "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                         capture_output=True, check=True).stdout
    return [[sum(raw[(y * W + x) * 3 + c] for y in range(y0 + 6, y0 + 24) for x in range(x0 + 6, x0 + 34)) / 504 for c in range(3)] for x0, y0 in box]
P = [means(1), means(3), means(5)]   # the page, the image, the clip
ok = True
for a, b in ((0, 1), (0, 2), (1, 2)):
    d = [abs(u - v) for pa, pb in zip(P[a], P[b]) for u, v in zip(pa, pb)]
    ok = ok and sum(d) / len(d) <= 1 and max(d) <= 3
sys.exit(0 if ok else 1)
PY
  then ok "a colour chart drawn as a page, an image and a BT.709 clip: within 1 level on average and 3 at most, any two of them"
  else bad "the colour chart's three paths (exit $rc): $(printf '%s' "$a" | tail -c 400)"; fi
  # what build refuses or mends without a browser: a video file with no colour tags (edit check fails it), one whose
  # pixels are not square, one that drops a frame (off the constant grid), a sync time before the clip's start; a bg of
  # three digits spelt out; a sound entry's dur that is not a number, end and dur both; sound entries out of order that
  # do not overlap are taken; footage spoken in English in a Chinese film: its line in "en", its words spaced
  mkdir -p "$t/raw" && ffmpeg -v error -y -f lavfi -i testsrc2=s=160x90:r=25:d=1 -c:v libx264 -pix_fmt yuv420p "$t/raw/plain.mp4" \
    && ffmpeg -v error -y -f lavfi -i testsrc2=s=160x90:r=25:d=1 -vf setsar=4/3 -c:v libx264 -pix_fmt yuv420p "$t/raw/wide.mp4" \
    && ffmpeg -v error -y -f lavfi -i testsrc2=s=160x90:r=30:d=4 -vf "select='not(eq(n\,60))',setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv" \
      -fps_mode passthrough -c:v libx264 -pix_fmt yuv420p -color_range tv -colorspace bt709 -color_primaries bt709 -color_trc bt709 "$t/raw/drop.mp4"
  printf '{"v": 1, "fps": 25, "size": [160, 90], "sources": {"a": {"clip": "plain.mp4"}}, "tracks": [{"id": "V1", "entries": [{"id": "S01", "src": "a", "dur": 1, "bg": "#0a0"}]}]}\n' > "$t/raw/edit.json"
  vh edit build "$t/raw" >/dev/null 2>&1; a=$(vh edit check "$t/raw" 2>&1); rc=$?
  b=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["entries"][0]["bg"])' "$t/raw/out/edit.resolved.json" 2>&1)
  sed 's/plain.mp4/wide.mp4/' "$t/raw/edit.json" > "$t/raw/e2" && mv "$t/raw/e2" "$t/raw/edit.json"; c=$(vh edit build "$t/raw" 2>&1); rc2=$?
  sed 's/wide.mp4/drop.mp4/' "$t/raw/edit.json" > "$t/raw/e2" && mv "$t/raw/e2" "$t/raw/edit.json"; d=$(vh edit build "$t/raw" 2>&1); rc3=$?
  python3 -c 'import json, sys; f = sys.argv[1]; d = json.load(open(f)); E = d["tracks"][0]["entries"]; E[1]["in"] = {"sync": -1.0}
d["sources"]["wind"] = {"sound": "assets/footage/cam/audio.wav", "role": "ambience"}
d["tracks"].append({"id": "A1", "entries": [{"id": "K01", "src": "wind", "start": 1.0, "dur": 0.3}, {"id": "K02", "src": "wind", "start": 0.0, "dur": 0.5},
                                           {"id": "K03", "src": "wind", "start": 1.5, "end": 1.7, "dur": 0.2}, {"id": "K04", "src": "wind", "start": 0.6, "dur": "1"}]})
json.dump(d, open(f, "w"))' "$p/edit.json"
  e=$(vh edit build "$p" 2>&1); rc4=$?
  if [ "$rc:$rc2:$rc3:$rc4" = 1:2:2:2 ] && [ "$b" = "#00aa00" ] && printf '%s' "$a" | grep -q 'plain.mp4 has no colour tags' && printf '%s' "$c" | grep -q 'wide.mp4 cannot be drawn as it is (pixels not square (4:3))' \
     && printf '%s' "$c" | grep -q 'setsar=1' && printf '%s' "$d" | grep -q 'frames off a constant 30 fps grid' && printf '%s' "$e" | grep -q 'falls before the start of' \
     && printf '%s' "$e" | grep -q 'K04: dur "1": seconds' && printf '%s' "$e" | grep -q 'K03: end or dur, not both' && ! printf '%s' "$e" | grep -q 'overlaps'
  then ok "build refuses footage that is untagged (check), stretched, missing a frame, or asked for before its start; spells out a bg of three digits; refuses a sound entry's dur that is not a number, end and dur both, and takes sound entries out of order"
  else bad "what build refuses of footage and sounds (exit $rc:$rc2:$rc3:$rc4, bg $b): $(printf '%s' "$a$c$d" | tail -c 500) | $(printf '%s' "$e" | tail -c 500)"; fi
  python3 -c 'import json, sys; f = sys.argv[1]; d = json.load(open(f)); E = d["tracks"][0]["entries"]; E[1]["in"] = 0.5; d["tracks"] = d["tracks"][:1]; json.dump(d, open(f, "w"))' "$p/edit.json"
  printf '{"lang": "en", "segments": [{"id": "1", "start": 0.6, "end": 1.3, "text": "one small step", "words": [{"w": "one", "start": 0.6, "end": 0.8}, {"w": "small", "start": 0.85, "end": 1.05}, {"w": "step", "start": 1.1, "end": 1.3}]}]}\n' > "$p/assets/footage/cam/words.json"
  a=$(vh edit build "$p" 2>&1); rc=$?
  if [ "$rc" = 0 ] && printf '%s' "$a" | grep -q 'S02_1 is spoken in en, with no zh for it' && python3 -c 'import json, sys; L = [s for s in json.load(open(sys.argv[1]))["segments"] if s["id"] == "S02_1"]
sys.exit(0 if L and L[0]["text"] == "one small step" and L[0]["en"] == "one small step" and L[0]["zh"] == "one small step" else 1)' "$p/out/edit.timeline.zh.json"
  then ok "footage spoken in English in a Chinese film: its words spaced, its line under en, and shown as spoken in the zh captions (said, for want of a translation)"
  else bad "footage in another language (exit $rc): $(printf '%s' "$a" | tail -c 400)"; fi
  rm -rf "$t"
}

# an edit list's chunk cache (tools/film/cache.mjs), on one small edit list (three images, a page that loads a picture,
# a clip) in five renders: a page that missed a file keeps none of its chunks; a render again takes every chunk, the same
# bytes; a chunk changed in the cache, an image changed, a byte added to the clip and the page's picture changed each draw
# their own chunk again, the rest taken; --fresh draws them all; every setting is in a key, the browser not in footage's;
# --cache-max prunes, clean clears. Few renders: a macOS runner starts each browser cold
edit_cache_checks() {
  local t q a b c d e key rc rc2 rc3 rc4 rc5
  command -v ffmpeg >/dev/null || { skip "an edit list's chunk cache" "no ffmpeg"; return; }
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX"); q="$t/k"
  mkdir -p "$q/img" "$q/assets/footage/cam" && printf '# BRIEF\n' > "$q/BRIEF.md"
  png() { python3 -c 'import struct, sys, zlib; c = bytes.fromhex(sys.argv[2]); raw = b"".join(b"\x00" + c * 160 for _ in range(90))
k = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + k(b"IHDR", struct.pack(">IIBBBBB", 160, 90, 8, 2, 0, 0, 0)) + k(b"IDAT", zlib.compress(raw)) + k(b"IEND", b""))' "$1" "$2"; }
  png "$q/img/a.png" c83c3c; png "$q/img/b.png" 3cb43c; png "$q/img/c.png" 3c50c8; png "$t/logo.png" ffffff
  ffmpeg -v error -y -f lavfi -i testsrc2=s=160x90:r=30:d=1 -vf "format=yuv420p,setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv" \
    -c:v libx264 -crf 18 -g 30 -keyint_min 30 -sc_threshold 0 -flags +cgop -color_range tv -colorspace bt709 -color_primaries bt709 -color_trc bt709 \
    -movflags +faststart "$q/assets/footage/cam/clip.mp4"
  printf '{"v": 1, "id": "cam", "file": "clip.mp4", "rate": "30", "frames": 30, "duration": 1.0, "size": [160, 90], "color": ["tv", "bt709", "bt709", "bt709"], "assumed": [], "audio": null, "words": null}\n' > "$q/assets/footage/cam/clip.json"
  printf '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=160, height=90"><style>html,body{margin:0}canvas{display:block}</style></head><body><canvas id="c" width="160" height="90"></canvas><img id="logo" src="img/logo.png" style="display:none"><script>const x = document.getElementById("c").getContext("2d"), im = document.getElementById("logo");
window.film = { duration: 1, ready() { return new Promise((ok) => { if (im.complete) ok(); else { im.onload = ok; im.onerror = ok; } }); },
  frame(t) { x.fillStyle = "#123"; x.fillRect(0, 0, 160, 90); if (im.naturalWidth) x.drawImage(im, 40, 20, 40, 40); } };</script></body></html>\n' > "$q/logo.html"
  printf '{"v": 1, "fps": 30, "size": [160, 90], "sources": {"a": {"image": "img/a.png"}, "b": {"image": "img/b.png"}, "c": {"image": "img/c.png"}, "logo": {"page": "logo.html", "clock": "local"}, "cam": {"clip": "assets/footage/cam"}}, "tracks": [{"id": "V1", "entries": [{"id": "S01", "src": "a", "dur": 0.2}, {"id": "S02", "src": "b", "dur": 0.2}, {"id": "S03", "src": "c", "dur": 0.2}, {"id": "S04", "src": "logo", "dur": 0.4}, {"id": "S05", "src": "cam", "dur": 0.2}]}]}\n' > "$q/edit.json"
  flags() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d.get("cached_chunks"), " ".join(r["entry"] + ":" + "".join("c" if c.get("cached") else "d" for c in r["chunks"]) for r in d["runs"]))' "$1"; }
  same() { python3 - "$1" "$2" <<'PY'
import re, subprocess, sys
md5 = lambda f: [l.split(",")[-1].strip() for l in subprocess.run(["ffmpeg", "-v", "error", "-i", f, "-f", "framemd5", "-"], capture_output=True, text=True).stdout.splitlines() if l and not l.startswith("#")]   # noqa: E731
a, b = md5(sys.argv[1]), md5(sys.argv[2])
ok = a == b and len(a) > 0
if not ok and len(a) == len(b) > 0:   # a browser that rasterises a page differently twice: the same picture is 45 dB or more
    r = subprocess.run(["ffmpeg", "-v", "info", "-i", sys.argv[1], "-i", sys.argv[2], "-lavfi", "psnr", "-f", "null", "-"], capture_output=True, text=True).stderr
    m = re.findall(r"min:(inf|[\d.]+)", r)
    ok = bool(m) and (m[-1] == "inf" or float(m[-1]) >= 45)
sys.exit(0 if ok else 1)
PY
  }
  # 1: the logo is missing (said, exit 1): its page keeps none of its chunks · 2: with it there, the page is drawn again,
  # the rest taken · 3: nothing changed, every chunk taken, the same bytes
  a=$(vh render "$q" --gop 6 --workers 1 --out "$q/out/1.mp4" 2>&1); rc=$?
  case "$rc:$a" in 2:*"needs a headless Chrome"*) no_chrome "an edit list's chunk cache"; rm -rf "$t"; return ;; esac
  cp "$t/logo.png" "$q/img/logo.png"
  vh render "$q" --gop 6 --workers 1 --out "$q/out/2.mp4" >/dev/null 2>&1; rc2=$?
  b=$(vh render "$q" --gop 6 --workers 1 --out "$q/out/3.mp4" 2>&1); rc3=$?
  # 4: S01's chunk changed in the cache, S02's image, the clip a byte longer, the page's picture another: each drawn again, S03 taken
  key=$(python3 -c 'import json, sys; print([r for r in json.load(open(sys.argv[1]))["runs"] if r["entry"] == "S01"][0]["chunks"][0]["key"])' "$q/out/3.mp4.render.json")
  python3 -c 'import sys; f = sys.argv[1]; d = bytearray(open(f, "rb").read()); n = len(d) // 2; d[n:n + 64] = bytes(x ^ 0xFF for x in d[n:n + 64]); open(f, "wb").write(d)' "$q/out/cache/chunks/$key.mp4"
  png "$q/img/b.png" 808080; printf 'x' >> "$q/assets/footage/cam/clip.mp4"; png "$q/img/logo.png" 000000
  vh render "$q" --gop 6 --workers 1 --out "$q/out/4.mp4" >/dev/null 2>&1; rc4=$?
  # 5: --fresh draws every chunk; with --cache-max of a byte, none stays in the cache after
  vh render "$q" --gop 6 --workers 1 --fresh --cache-max 0.000000001 --out "$q/out/5.mp4" >/dev/null 2>&1; rc5=$?
  a=$(flags "$q/out/1.mp4.render.json"); c=$(flags "$q/out/2.mp4.render.json"); d=$(flags "$q/out/3.mp4.render.json"); e=$(flags "$q/out/4.mp4.render.json")
  if [ "$rc:$rc2:$rc3:$rc4:$rc5" = 1:0:0:0:0 ] && [ "$a" = "0 S01:d S02:d S03:d S04:dd S05:d" ] && [ "$c" = "4 S01:c S02:c S03:c S04:dd S05:c" ] \
     && [ "$d" = "6 S01:c S02:c S03:c S04:cc S05:c" ] && printf '%s' "$b" | grep -q 'cache: 6 of 6 chunks taken from' && cmp -s "$q/out/2.mp4" "$q/out/3.mp4" \
     && [ "$e" = "1 S01:d S02:d S03:c S04:dd S05:d" ] && [ "$(flags "$q/out/5.mp4.render.json")" = "0 S01:d S02:d S03:d S04:dd S05:d" ] && same "$q/out/4.mp4" "$q/out/5.mp4" \
     && [ "$(find "$q/out/cache/chunks" -name '*.mp4' | wc -l | tr -d ' ')" = 0 ]
  then ok "the chunk cache: a page that missed a file keeps none of its chunks; a render again takes every chunk (the same bytes); a chunk changed in the cache, an image, the clip and the page's picture each draw theirs again, the rest taken; --fresh draws them all; --cache-max prunes"
  else bad "the chunk cache (exit $rc:$rc2:$rc3:$rc4:$rc5): [$a] [$c] [$d] [$e] [$(flags "$q/out/5.mp4.render.json")] | $(printf '%s' "$b" | tail -c 300)"; fi
  # every setting is in a page's key, and all but the browser's in footage's; bin/vh clean takes the cache as made again
  e=$(node --input-type=module -e 'import { chunkKey } from "./tools/film/edit.mjs";
const s = { width: 320, height: 180, dpr: 1, fps: 30, gop: 30, crf: 16, preset: "medium", ffmpeg: "f", tools: "t", platform: "p", capture: "jpeg q95", vf: "v", vfRaw: "r", browser: "A", real_clock: false, soft_gl: false };
const other = { width: 640, height: 360, dpr: 2, fps: 25, gop: 15, crf: 18, preset: "slow", ffmpeg: "g", tools: "u", platform: "q", capture: "png", vf: "w", vfRaw: "s", browser: "B", real_clock: true, soft_gl: true };
const page = { draw: "page", clock: "film", path: "a.html", frames: [0, 30] }, clip = { draw: "clip", path: "c.mp4", sha256: "2", rate: "30", color: ["tv"], j0: 0, speed: 1, frames: [0, 30] };
const changes = (r) => Object.keys(s).filter((k) => chunkKey(r, 0, 30, s) !== chunkKey(r, 0, 30, { ...s, [k]: other[k] })).join(",");
console.log(changes(page), "|", changes(clip))' 2>&1)
  c=$(vh clean "$q" 2>&1)
  if [ "$e" = "width,height,dpr,fps,gop,crf,preset,ffmpeg,tools,platform,capture,vf,browser,real_clock,soft_gl | width,height,dpr,fps,gop,crf,preset,ffmpeg,tools,platform,vfRaw" ] \
     && printf '%s' "$c" | grep -q 'out/cache/'
  then ok "a chunk's key holds every setting, footage's all but the browser's; bin/vh clean takes the cache as made again"
  else bad "the cache's keys and clean (keys: $e): $(printf '%s' "$c" | tail -c 300)"; fi
  # --motion-blur in an edit list: a colour, then tools/film/fixture/blur.html on its own clock. The page is drawn as
  # sub-frames and the colour is not; the page's first frame (its entry's start: a cut) has no sub-frame from before it (the
  # page would paint it white); a render again takes both chunks, the same bytes; one without the blur takes the colour's
  # and draws the page's again: the blur is in a page's key, not a colour's
  q="$t/mb"; mkdir -p "$q" && printf '# BRIEF\n' > "$q/BRIEF.md" && cp tools/film/fixture/blur.html "$q/blur.html"
  printf '{"v": 1, "fps": 30, "size": [160, 90], "sources": {"grey": {"color": "#808080"}, "sq": {"page": "blur.html", "clock": "local"}}, "tracks": [{"id": "V1", "entries": [{"id": "S01", "src": "grey", "dur": 0.2}, {"id": "S02", "src": "sq", "dur": 0.2}]}]}\n' > "$q/edit.json"
  vh render "$q" --gop 6 --workers 1 --motion-blur 4 --out "$q/out/1.mp4" >/dev/null 2>&1; rc=$?
  b=$(vh render "$q" --gop 6 --workers 1 --motion-blur 4 --out "$q/out/2.mp4" 2>&1); rc2=$?
  vh render "$q" --gop 6 --workers 1 --out "$q/out/3.mp4" >/dev/null 2>&1; rc3=$?
  a=$(flags "$q/out/1.mp4.render.json"); c=$(flags "$q/out/2.mp4.render.json"); d=$(flags "$q/out/3.mp4.render.json")
  if [ "$rc:$rc2:$rc3" = 0:0:0 ] && [ "$a" = "0 S01:d S02:d" ] && [ "$c" = "2 S01:c S02:c" ] && [ "$d" = "1 S01:c S02:d" ] && cmp -s "$q/out/1.mp4" "$q/out/2.mp4" \
     && python3 - "$q/out" <<'PY'
import json, subprocess, sys
d = sys.argv[1]; W, H = 160, 90
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", f"{d}/1.mp4", "-f", "rawvideo", "-pix_fmt", "yuv420p", "-"], capture_output=True).stdout
n = W * H * 3 // 2
Y = [raw[i * n:i * n + W * H] for i in range(len(raw) // n)]
ok = len(Y) == 12 and min(Y[5]) >= 124 and max(Y[5]) <= 128 and max(Y[6][10 * W:11 * W]) <= 18 and any(38 < v < 213 for v in Y[7][45 * W:46 * W])
mb = json.load(open(f"{d}/1.mp4.render.json")).get("motion_blur") or {}
ok = ok and (mb.get("samples"), mb.get("shutter"), len(mb.get("version") or "")) == (4, 0.5, 64) and "motion_blur" not in json.load(open(f"{d}/3.mp4.render.json"))
sys.exit(0 if ok else 1)
PY
  then ok "an edit list with --motion-blur: its page is blurred, not its colour; no sub-frame reaches before the page's entry; a render again takes every chunk, the same bytes; without it, the colour's chunk is taken and the page's drawn again"
  else bad "an edit list with --motion-blur (exit $rc:$rc2:$rc3): [$a] [$c] [$d] | $(printf '%s' "$b" | tail -c 300)"; fi
  rm -rf "$t"
}

# bin/vh timeline (the narration timeline's checks) and bin/vh remap, and the refusal in bin/vh captions
timeline_checks() {
  local t a rc
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")
  a=$(vh timeline showcase/02-short-leo-doppler zh 2>&1); rc=$?
  [ $rc = 0 ] && printf '%s' "$a" | grep -q "timeline: sound" && ok "timeline: showcase 02's narration is sound" || bad "timeline on showcase 02: exit $rc: $a"
  mkdir -p "$t/p/audio"
  python3 - "$t/p/audio/timeline.zh.json" <<'PY'
import json, sys
tl = json.load(open("showcase/02-short-leo-doppler/audio/timeline.zh.json", encoding="utf-8"))
s = tl["segments"][1]; s["words"][2]["start"] = s["words"][1]["start"] - 0.5   # a word time out of order
s = tl["segments"][3]; s["words"][0]["w"] = "宾果"                               # an aligner that spelled a word its own way
json.dump(tl, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False)
PY
  a=$(vh timeline "$t/p" zh 2>&1); rc=$?
  case "$rc:$a" in 1:*"out of order"*"the words read"*) ok "timeline: a word time out of order and a word spelled differently from the text are problems (exit 1)" ;;
    *) bad "timeline on a broken timeline: exit $rc: $a" ;; esac
  a=$(vh captions "$t/p" zh 2>&1); rc=$?
  b=$(vh captions "$t/p" zh --skip-lint 2>&1); rc2=$?
  c=$(vh captions "$t/p" zh --skip-lint --media-end 30 2>&1); rc3=$?
  if [ $rc = 1 ] && printf '%s' "$a" | grep -q "timed wrong" && [ $rc2 = 0 ] && [ $rc3 = 0 ] && [ -s "$t/p/audio/captions.json" ]; then ok "captions: refuses a timeline that fails its checks, and goes on with --skip-lint (before or after --media-end)"
  else bad "captions on a broken timeline: exit $rc ($a) / with --skip-lint exit $rc2 ($b) / --skip-lint --media-end exit $rc3 ($c)"; fi
  # captions at word boundaries (jieba through uv): a long line without a comma is cut between words, one-line cards never
  # cross a sentence end, and the break table starts a card at its phrase
  if command -v uv >/dev/null && uv run -q --no-project --with jieba python -c "import jieba" >/dev/null 2>&1; then
    mkdir -p "$t/cw/audio" && printf '# BRIEF\n' > "$t/cw/BRIEF.md"
    python3 - "$t/cw/audio/timeline.zh.json" <<'PY'
import json, sys
def line(i, t0, text):
    cs = [c for c in text if c not in "，。"]; ws, t = [], t0
    for c in cs: ws.append({"w": c, "start": round(t, 3), "end": round(t + 0.2, 3)}); t += 0.2
    return {"id": i, "zh": text, "start": t0, "end": round(t, 3), "words": ws}
segs = [line("c1", 0.0, "今天我们一起来看看这台机器到底是怎么工作的"), line("c2", 6.0, "说到第一张，卡片落下。说到第二张，第二张跟上。")]
json.dump({"lang": "zh", "duration": 12.0, "segments": segs}, open(sys.argv[1], "w", encoding="utf-8"), ensure_ascii=False)
PY
    printf '["卡片落下"]\n' > "$t/cw/audio/capbreaks.json"
    a=$(vh captions "$t/cw" zh --cards 2>&1); rc=$?
    if [ $rc = 0 ] && printf '%s' "$a" | grep -q 'word boundaries by jieba' && PYTHONWARNINGS=ignore uv run -q --no-project --with jieba python - "$t/cw/audio/captions.json" <<'PY'
import json, logging, sys, jieba
jieba.setLogLevel(logging.ERROR)
cards = json.load(open(sys.argv[1], encoding="utf-8"))
c1 = [c["zh"][0] for c in cards if c["id"] == "c1"]; c2 = [c["zh"][0] for c in cards if c["id"] == "c2"]
text = "今天我们一起来看看这台机器到底是怎么工作的"
bounds, pos = set(), 0
for w in jieba.lcut(text): pos += len(w); bounds.add(pos)
cuts, pos = [], 0
for c in c1[:-1]: pos += len(c); cuts.append(pos)
ok = len(c1) >= 2 and "".join(c1) == text and all(x in bounds for x in cuts)
ok = ok and not any("落下" in c and "第二张" in c for c in c2) and any(c.startswith("卡片落下") for c in c2)
sys.exit(0 if ok else 1)
PY
    then ok "captions --cards: cut between words (jieba), never across a sentence end, a card starting at the break table's phrase"
    else bad "captions --cards (exit $rc): $(printf '%s' "$a" | tail -c 500) $(cat "$t/cw/audio/captions.zh.srt" 2>/dev/null | tr '\n' '|' | tail -c 400)"; fi
    # numbers, times and links stay whole at a narrow width (jieba cuts them at their , and :)
    if a=$(PYTHONWARNINGS=ignore uv run -q --no-project --with jieba python - "$ROOT/tools/audio" 2>&1 <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import capbreak, captions
bad = []
for text, w, keep in (("价格从1,000,000元涨到2,500,000元", 8, ("1,000,000", "2,500,000")), ("价格从1,000,000元涨到", 6, ("1,000,000",)),
                      ("会议定在12:30开始，别迟到", 6, ("12:30",)), ("在12:30:45开始", 6, ("12:30:45",)),
                      ("网址是https://example.com/a/b，记下来。", 8, ("https://example.com/a/b",)), ("网址是https://a.example.com:8080/x/y，记下", 6, ("https://a.example.com:8080/x/y",))):
    for got in ([r for _, r in capbreak.pieces(text, w, True)], captions.wrap_zh(text, w)):
        if not all(any(k in g for g in got) for k in keep): bad.append(f"{text} at {w}: {got}")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
    ); then ok "captions: 2,500,000, 12:30 and a link stay whole at a narrow width, in cards and wrapped lines"
    else bad "captions split a number, a time or a link: $a"; fi
  else skip "captions at word boundaries" "no uv to bring jieba"; fi
  # cards in English stay within --en-max characters and end at . ! ?; half-width ? ! end a Chinese sentence; a card that
  # would start after the media end is left out, and no card ends before it starts
  mkdir -p "$t/ce/audio" "$t/ch/audio" && printf '# BRIEF\n' > "$t/ce/BRIEF.md" && cp "$t/ce/BRIEF.md" "$t/ch/BRIEF.md"
  python3 - "$t" <<'PY'
import json, re, sys
d = sys.argv[1]
def seg(i, lang, text, t0, dt):
    ws, t = [], t0
    for w in (re.findall(r"[A-Za-z0-9']+", text) if lang == "en" else [c for c in text if c.strip() and c not in "?!，。"]):
        ws.append({"w": w, "start": round(t, 3), "end": round(t + dt, 3)}); t += dt
    return {"id": i, lang: text, "start": t0, "end": round(t, 3), "words": ws}
en = "The quick brown fox jumps over the lazy dog and keeps on running. Version 3.5 is out! Is it fast? It is"
json.dump({"lang": "en", "duration": 30.0, "segments": [seg("e1", "en", en, 0.0, 0.3)]}, open(f"{d}/ce/audio/timeline.en.json", "w"))
json.dump({"lang": "zh", "duration": 25.0, "segments": [seg("h1", "zh", "真的吗?我不信!你再说一遍", 0.0, 0.25), seg("h2", "zh", "这一句在画面结束以后才开始", 20.0, 0.25)]},
          open(f"{d}/ch/audio/timeline.zh.json", "w"), ensure_ascii=False)
PY
  a=$(vh captions "$t/ce" en --cards 2>&1); rc=$?
  b=$(vh captions "$t/ch" zh --cards --media-end 19 2>&1); rc2=$?
  if [ $rc = 0 ] && [ $rc2 = 0 ] && printf '%s' "$b" | grep -q "left out, starts after the media end" && python3 - "$t" <<'PY'
import json, sys
d = sys.argv[1]
en = [c["en"][0] for c in json.load(open(f"{d}/ce/audio/captions.json"))]
zh = json.load(open(f"{d}/ch/audio/captions.json", encoding="utf-8"))
ok = all(len(c) <= 42 for c in en) and not any(". " in c or "! " in c or "? " in c for c in en) and "Version 3.5 is out!" in en
ok = ok and [c["zh"][0] for c in zh][:2] == ["真的吗?", "我不信!"] and all(c["id"] == "h1" and c["end"] > c["start"] for c in zh)
sys.exit(0 if ok else 1)
PY
  then ok "captions --cards: English within --en-max and cut at . ! ? (3.5 whole), half-width ? ! end a Chinese sentence, a card after the media end left out"
  else bad "captions --cards in English / half-width / media end (exit $rc, $rc2): $(printf '%s' "$a $b" | tail -c 400) $(head -c 600 "$t/ce/audio/captions.json" 2>/dev/null)"; fi
  # check: an SRT beside the video with an entry too short to read is listed (a warning, not a failure)
  if command -v ffmpeg >/dev/null; then
    mkdir -p "$t/sc" && ffmpeg -nostdin -v error -f lavfi -i color=c=0x303030:s=320x180:r=30:d=3 -pix_fmt yuv420p "$t/sc/film.mp4"
    printf '1\n00:00:00,500 --> 00:00:01,300\n这一句只亮了零点八秒\n\n2\n00:00:01,300 --> 00:00:03,200\n这句够长\n' > "$t/sc/film.zh.srt"
    a=$(vh check "$t/sc/film.mp4" 2>&1); rc=$?
    case "$a" in *"subtitles · film.zh.srt: 1 of 2 entries are shorter than it takes to read them"*"0.80 s, needs 1.80 s"*) ok "check lists subtitle entries too short to read, from the SRT beside the film" ;;
      *) bad "check on a short subtitle (rc $rc): $(printf '%s' "$a" | tail -c 500)" ;; esac
  fi
  python3 - "$t" <<'PY'
import json, sys
d = sys.argv[1]
line = lambda i, t0, text, ws: {"id": i, "text": text, "start": t0, "end": round(t0 + sum(w[1] for w in ws), 3), "words": [
    {"w": w, "start": round(t0 + sum(x[1] for x in ws[:k]), 3), "end": round(t0 + sum(x[1] for x in ws[:k + 1]), 3)} for k, (w, _) in enumerate(ws)]}
for name, gap in (("old", 0.5), ("new", 1.5)):   # the new take has 1 s more before the second line
    json.dump({"lang": "zh", "segments": [line("a", 0.0, "风吹过", [("风", 0.4), ("吹过", 1.1)]), line("b", 1.5 + gap, "纸飞走了", [("纸", 0.5), ("飞走了", 1.5)])]},
              open(f"{d}/{name}.json", "w", encoding="utf-8"), ensure_ascii=False)
json.dump([{"t": 0.2, "sfx": "wind"}, {"t": 2.6, "sfx": "paper", "gain_db": -6}, {"name": "x", "start": 1.8, "end": 4.5}], open(f"{d}/events.json", "w"))
PY
  a=$(vh remap "$t/events.json" --from "$t/old.json" --to "$t/new.json" 2>&1); rc=$?
  if [ $rc = 0 ] && python3 -c "import json, sys; e = json.load(open(sys.argv[1])); sys.exit(0 if (e[0]['t'], e[1]['t'], e[1]['gain_db'], e[2]['start'], e[2]['end']) == (0.2, 3.6, -6, 2.4, 5.5) else 1)" "$t/events.json" && [ -s "$t/events.json.bak" ]
  then ok "remap: seconds inside a line move with its words, in a gap in proportion, after the end with the last word; other numbers stay; the original kept as .bak"
  else bad "remap: exit $rc: $a $(cat "$t/events.json" 2>/dev/null)"; fi
  a=$(vh remap "$t/events.json" --from "$t/old.json" --to "$t/new.json" 2>&1); rc=$?
  [ $rc = 2 ] && printf '%s' "$a" | grep -q "is there already" && ok "remap: refuses to overwrite an earlier remap's .bak" || bad "remap with a .bak there: exit $rc: $a"
  python3 - "$t" <<'PY'
import json, sys
d = sys.argv[1]   # two lines that meet at 1.0 s; the new take puts 0.8 s between them
L = lambda i, a, b, t: {"id": i, "text": t, "start": a, "end": b}
json.dump({"segments": [L("a", 0, 1, "风"), L("b", 1, 2, "纸")]}, open(f"{d}/old2.json", "w"))
json.dump({"segments": [L("a", 0, 1, "风"), L("b", 1.8, 2.8, "纸")]}, open(f"{d}/new2.json", "w"))
json.dump([{"t": 0.9}, {"t": 1.1}, {"t": 1.6}], open(f"{d}/ev2.json", "w"))
PY
  a=$(vh remap "$t/ev2.json" --from "$t/old2.json" --to "$t/new2.json" --out "$t/ev2o.json" 2>&1); rc=$?
  if [ $rc = 0 ] && python3 -c "import json, sys; sys.exit(0 if [e['t'] for e in json.load(open(sys.argv[1]))] == [0.9, 1.9, 2.4] else 1)" "$t/ev2o.json"
  then ok "remap: where two lines met and a pause came between them, a time on the later line moves with it"
  else bad "remap across a new pause: exit $rc: $a $(cat "$t/ev2o.json" 2>/dev/null)"; fi
  if command -v uv >/dev/null; then   # an empty event list: no length to take from it
    printf '[]\n' > "$t/none.json"
    a=$(vh sfx place "$t/none.json" "$t/none.wav" 2>&1); rc=$?; b=$(vh sfx place "$t/none.json" "$t/none.wav" 2 2>&1)
    case "$rc:$a:$b" in 2:*"has no events"*"<duration_s>"*:*"0 events"*"2.00s"*) ok "sfx place: an empty event list asks for a duration, and with one writes a silent track" ;;
      *) bad "sfx place on an empty event list (exit $rc): $a / $b" ;; esac
    a=$(vh sfx place "$t/none.json" "$t/none.wav" 2s 2>&1); rc=$?
    case "$rc:$a" in 2:*"duration '2s' is not a number of seconds"*) case "$a" in *Traceback*) bad "sfx place with a duration 2s: a traceback: $a" ;; *) ok "sfx place: a duration that is not a number is said plainly (exit 2)" ;; esac ;;
      *) bad "sfx place with a duration 2s (exit $rc): $a" ;; esac
    # usage errors exit 2 (no command, a typo, place without its files, a missing event list, lib without a folder, an
    # audition value out of range), an event list that cannot become a track exits 1 (an unknown sound, a field out of range)
    printf '[{"t": 0.5, "sfx": "nosuch"}]' > "$t/unk.json"; printf '[{"t": 0.5, "sfx": "whoosh", "dur": 99}]' > "$t/far.json"; a=""
    b=$(vh sfx audition -h 2>/dev/null); rc=$?   # help is not an error: stdout, exit 0, as sfx -h; a bare audition is a one-line one
    case "$rc:$b" in 0:*"audition <name|all>"*) ;; *) a=" | sfx audition -h (exit $rc): $(printf '%s' "$b" | head -c 200)" ;; esac
    for c in "2|" "2|plcae" "2|place" "2|place|$t/unk.json" "2|place|$t/nope.json|$t/o.wav" "2|lib" "2|audition" "2|audition|whoosh|dur=99|--out|$t/au.wav" \
             "1|place|$t/unk.json|$t/o.wav" "1|place|$t/far.json|$t/o.wav"; do
      IFS='|' read -r -a cargs <<< "$c"
      b=$(vh sfx "${cargs[@]:1}" 2>&1); rc=$?
      case "$rc:$b" in *Traceback*) a="$a | sfx ${cargs[*]:1}: $b" ;; "${cargs[0]}:sfx"*) ;; *) a="$a | sfx ${cargs[*]:1} (exit $rc, want ${cargs[0]}): $(printf '%s' "$b" | tail -c 200)" ;; esac
    done
    [ -z "$a" ] && ok "sfx: help exits 0, usage errors exit 2, an event list that cannot become a track exits 1, each in a line and none a traceback" || bad "sfx exit codes:$a"
  fi
  rm -rf "$t"
}

# bin/vh pace on a synthetic take (22.05 kHz): tone-burst "syllables" with known onsets, lines at 4 to 7 a second, a long
# pause inside a line and one the script asks for, gaps too short and too long, an ASR start placed 0.12 s late, one line's
# end and the next one's start put at the same instant inside the first one's last syllable (an aligner did that), and a
# "……" line. Then ASRs that are further off, a line with no audio, and the refusals. Checked against the known syllables,
# not against the tool's own numbers
pace_checks() {
  local t p v a rc
  if ! command -v uv >/dev/null || ! command -v ffmpeg >/dev/null; then skip "pace" "needs uv and ffmpeg"; return; fi
  t=$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX"); p="$t/p"
  python3 - "$p/audio" <<'PY'
import json, math, struct, sys, wave
from pathlib import Path
a = Path(sys.argv[1]); a.mkdir(parents=True); SR = 22050
lines = [("a1", "一二三四五六七八，", 4.0, None, 0.05), ("a2", "九十百千万亿兆京。", 7.0, None, 1.6),    # id, text, per second,
         ("b1", "甲乙丙丁戊己庚辛壬癸。", 5.5, (5, 0.7), 0.4), ("b2", "好。", 3.0, None, 0.3),         # (after unit k, pause),
         ("b3", "子丑寅卯辰巳午未。", 5.0, (4, 0.6), 0.5), ("b4", "东南西北中发白。", 5.6, None, 0.0)]   # gap after the line
(a / "script.txt").write_text("@a1 一二三四五六七八，\n@a2 九十百千万亿兆京。\n\n@b1 甲乙丙丁戊己庚辛壬癸。\n@b2 好。\n"
                              "@b3 子丑寅卯<long pause>辰巳午未。\n@b3x ……\n@b4 东南西北中发白。\n", encoding="utf-8")
x, segs = [0.0] * int(0.4 * SR), []
for k, (sid, text, rate, pause, gap) in enumerate(lines):
    chars = [c for c in text if c not in "，。"]; burst = 0.75 / rate; words = []
    for j, c in enumerate(chars):
        t0, n, f0 = len(x) / SR, int(burst * SR), 140 + 15 * ((j * 7 + k * 3) % 5)
        x += [0.25 * math.sin(math.pi * i / n) ** 0.5 * (math.sin(2 * math.pi * f0 * i / SR) + 0.5 * math.sin(4 * math.pi * f0 * i / SR)) for i in range(n)]
        words.append({"w": c + (text[-1] if j == len(chars) - 1 else ""), "start": round(t0, 3), "end": round(len(x) / SR, 3)})
        if j + 1 < len(chars):
            x += [0.0] * int((1 / rate - burst + (pause[1] if pause and j + 1 == pause[0] else 0)) * SR)
    if sid == "a1":
        words[0]["start"] += 0.12                     # the ASR heard the first syllable late
    if sid == "b2":                                   # b1 ends and b2 starts at the same instant, 20 ms before b1's voice ends
        segs[-1]["words"][-1]["end"] = words[0]["start"] = segs[-1]["end"] = round(segs[-1]["end"] - 0.02, 3)
    if sid == "b4":                                   # "……": no words, its span is the pause
        segs.append({"id": "b3x", "zh": "……", "en": "", "text": "……", "start": segs[-1]["end"], "end": words[0]["start"]})
    segs.append({"id": sid, "zh": text, "en": "", "text": text, "start": words[0]["start"], "end": words[-1]["end"], "words": words})
    x += [0.0] * int(gap * SR)
x += [0.0] * int(0.5 * SR)
with wave.open(str(a / "voiceover.zh.wav"), "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(struct.pack(f"<{len(x)}h", *(int(round(v * 32767)) for v in x)))
tl = json.dumps({"provider": "say", "lang": "zh", "duration": round(len(x) / SR, 3), "segments": segs}, ensure_ascii=False)
for f in ("timeline.zh.json", "timeline.json"):
    (a / f).write_text(tl, encoding="utf-8")
(a / "voiceover.wav").write_bytes((a / "voiceover.zh.wav").read_bytes())
PY
  cp -R "$p/audio" "$t/orig"
  # the onsets of the syllables in a take (10 ms frames above −40 dBFS) and the quiet before each: what every check below counts
  cat > "$t/onsets.py" <<'PY'
import subprocess, numpy as np
def onsets(wav, sr=22050):
    y = np.frombuffer(subprocess.run(["ffmpeg", "-v", "error", "-i", wav, "-f", "f32le", "-ac", "1", "-ar", str(sr), "-"],
                                     check=True, capture_output=True).stdout, "<f4")
    hop = sr // 100; n = len(y) // hop
    on = 10 * np.log10(np.mean(y[: n * hop].reshape(n, hop) ** 2, 1) + 1e-18) > -40
    up, down = (np.flatnonzero(np.diff(on.astype(int)) == 1) + 1) * 0.01, (np.flatnonzero(np.diff(on.astype(int)) == -1) + 1) * 0.01
    return up, np.array([up[0]] + [u - d for u, d in zip(up[1:], down)]), on
PY
  vh pace "$p" --dry-run >/dev/null && diff -r "$p/audio" "$t/orig" >/dev/null && ok "pace --dry-run writes nothing" || bad "pace --dry-run changed the project"
  if a=$(vh pace "$p" 2>&1) && a=$(PYTHONPATH="$t" uv run -q --no-project --with numpy python - "$p/audio" "$t/orig" 2>&1 <<'PY'
import json, sys
import numpy as np
from onsets import onsets
A, O = sys.argv[1], sys.argv[2]; bad = []
tl = json.load(open(f"{A}/timeline.zh.json", encoding="utf-8")); P = tl["pace"]; S = {s["id"]: s for s in tl["segments"]}
if open(f"{A}/voiceover.zh.raw.wav", "rb").read() != open(f"{O}/voiceover.zh.wav", "rb").read() or \
   open(f"{A}/timeline.zh.raw.json", "rb").read() != open(f"{O}/timeline.zh.json", "rb").read(): bad.append("the .raw files are not the original")
if open(f"{A}/voiceover.wav", "rb").read() != open(f"{A}/voiceover.zh.wav", "rb").read(): bad.append("voiceover.wav is not the paced copy")
ons, quiet, on = onsets(f"{A}/voiceover.zh.wav")
words = [w for s in tl["segments"] for w in s.get("words", [])]
if len(ons) != 42 or len(words) != 42: bad.append(f"{len(ons)} syllables in the paced take, {len(words)} words (42 each)")
else:
    err = np.abs(ons - [w["start"] for w in words])
    if err.max() > 0.035: bad.append(f"a mapped word {err.max():.3f} s from its syllable ({words[int(err.argmax())]['w']})")
L = {l["id"]: l for l in P["lines"]}
paced = [l for l in P["lines"] if l.get("note") not in ("short", "no words")]
sd = lambda k: float(np.std([l[k] for l in paced]))
if not sd("after") < 0.8 * sd("pace"): bad.append(f"spread of paces {sd('pace'):.2f} → {sd('after'):.2f}")
if not all(0.92 - 1e-9 <= l["tempo"] <= 1.18 + 1e-9 for l in P["lines"] if "tempo" in l) or L["b2"]["tempo"] != 1.0 or L["a1"]["tempo"] <= 1 \
   or L["a2"]["tempo"] >= 1 or L["b3x"].get("note") != "no words":
    bad.append(f"tempos {[(l['id'], l.get('tempo'), l.get('note')) for l in P['lines']]}")
def longest_quiet(s):
    q = on[int(s["start"] / 0.01): int(s["end"] / 0.01)]; best = cur = 0
    for v in q:
        cur = 0 if v else cur + 1; best = max(best, cur)
    return best * 0.01
if longest_quiet(S["b1"]) > 0.3 or longest_quiet(S["b3"]) < 0.5: bad.append(f"inner pauses: b1 {longest_quiet(S['b1']):.2f} (cap 0.26), b3 {longest_quiet(S['b3']):.2f} (asked for)")
gap = lambda i, j: S[j]["start"] - S[i]["end"]
if not (0.1 <= gap("a1", "a2") <= 0.2 and 1.1 <= gap("a2", "b1") <= 1.25 and 0.35 <= gap("b1", "b2") <= 0.45 and 0.45 <= gap("b3", "b4") <= 0.56):
    bad.append(f"gaps a1-a2 {gap('a1', 'a2'):.2f} (0.12), a2-b1 {gap('a2', 'b1'):.2f} (1.2), b1-b2 {gap('b1', 'b2'):.2f} (the take's 0.4),"
               f" b3-b4 {gap('b3', 'b4'):.2f} (the 0.5 a \"……\" line stands for)")
if not S["b3"]["end"] - 0.005 <= S["b3x"]["start"] <= S["b3x"]["end"] <= S["b4"]["start"] + 0.005: bad.append(f"the \"……\" line is not between b3 and b4: {S['b3x']}")
caps = json.load(open(f"{A}/captions.json", encoding="utf-8"))
if [c["start"] for c in caps] != [s["start"] for s in tl["segments"]]: bad.append("captions.json is not from the paced timeline")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
  ); then ok "pace: every syllable kept and every mapped word on it, paces closer within the clamp, an inner pause capped and an asked-for one kept, gaps in range, a \"……\" line's pause kept, originals kept, captions redone"
  else bad "pace on a synthetic take: $a"; fi
  cp "$p/audio/voiceover.zh.wav" "$t/once.wav"
  vh pace "$p" >/dev/null && cmp -s "$t/once.wav" "$p/audio/voiceover.zh.wav" && ok "pace runs again from the original take: the same bytes" || bad "pace: a second run gave a different take"
  vh pace "$p" --restore --dry-run >/dev/null 2>&1; rc=$?
  [ $rc = 2 ] && cmp -s "$t/once.wav" "$p/audio/voiceover.zh.wav" && ok "pace --restore --dry-run is refused" || bad "pace --restore --dry-run: exit $rc"
  vh pace "$p" --restore >/dev/null && cmp -s "$p/audio/voiceover.zh.wav" "$t/orig/voiceover.zh.wav" && cmp -s "$p/audio/timeline.zh.json" "$t/orig/timeline.zh.json" \
    && cmp -s "$p/audio/voiceover.wav" "$t/orig/voiceover.zh.wav" && cmp -s "$p/audio/timeline.json" "$t/orig/timeline.json" \
    && [ ! -e "$p/audio/voiceover.zh.raw.wav" ] && ok "pace --restore puts the original back" || bad "pace --restore"
  # ASRs further off: every start 0.2 s late and end 0.3 s early (f), a line break placed 0.1 s inside a2's last syllable (m),
  # the last line with no audio at all (s): no syllable lost or moved behind a pause, no crash
  for v in f m s; do mkdir "$t/$v" && cp -R "$t/orig" "$t/$v/audio"; done
  python3 - "$t" <<'PY'
import json, subprocess, sys
t = sys.argv[1]; F = "audio/timeline.zh.json"
def edit(v, fn):
    tl = json.load(open(f"{t}/{v}/{F}", encoding="utf-8")); fn(tl["segments"]); json.dump(tl, open(f"{t}/{v}/{F}", "w", encoding="utf-8"), ensure_ascii=False)
def late(segs):
    for s in segs:
        if s.get("words"):
            s["start"] = s["words"][0]["start"] = round(min(s["start"] + 0.2, s["words"][0]["end"]), 3)
            s["end"] = s["words"][-1]["end"] = round(max(s["end"] - 0.3, s["words"][-1]["start"]), 3)
def inside(segs):
    p, q = segs[1], segs[2]                           # a2 | b1
    p["end"] = p["words"][-1]["end"] = q["start"] = q["words"][0]["start"] = round(p["end"] - 0.1, 3)
edit("f", late); edit("m", inside)
b4 = json.load(open(f"{t}/s/{F}", encoding="utf-8"))["segments"][-1]["start"]
subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", f"{t}/orig/voiceover.zh.wav", "-t", f"{b4 - 0.05:.3f}", f"{t}/s/audio/voiceover.zh.wav"], check=True)
PY
  a=""; for v in f m s; do vh pace "$t/$v" >/dev/null 2>"$t/$v.err" || a="$a $v: $(tail -c 300 "$t/$v.err")"; done
  if [ -z "$a" ] && a=$(PYTHONPATH="$t" uv run -q --no-project --with numpy python - "$t" 2>&1 <<'PY'
import json, sys
from onsets import onsets
t = sys.argv[1]; bad = []
for v, want in (("f", 42), ("m", 42), ("s", 35)):
    ons, quiet, _ = onsets(f"{t}/{v}/audio/voiceover.zh.wav")
    if len(ons) != want: bad.append(f"{v}: {len(ons)} syllables, want {want}")
    elif v == "m" and quiet[15] > 0.1: bad.append(f"m: a2's last syllable moved behind a {quiet[15]:.2f} s pause")
L = {l["id"]: l for l in json.load(open(f"{t}/s/audio/timeline.zh.json", encoding="utf-8"))["pace"]["lines"]}
if L["b4"].get("note") != "nothing heard": bad.append(f"s: b4 {L['b4']}")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
  ); then ok "pace: ASR starts 0.2 s late and ends 0.3 s early, a line break inside a syllable, a line with no audio: every syllable kept, none moved"
  else bad "pace with an ASR further off:$a"; fi
  # more cases, each on its own copy: b1 with no audio (u), b1 and b2 spans swapped (o), word times only in the cache (c, and c2
  # without it), no script.txt (n), and a take of its own (t): a quiet breath before one line, three short loud syllables
  # opening the next
  for v in u o c c2 n; do mkdir "$t/$v" && cp -R "$t/orig" "$t/$v/audio"; done
  python3 - "$t" <<'PY'
import hashlib, json, math, struct, sys, wave
from pathlib import Path
t = sys.argv[1]; F = "audio/timeline.zh.json"
tl = json.load(open(f"{t}/orig/timeline.zh.json", encoding="utf-8")); S = {s["id"]: s for s in tl["segments"]}
b1 = S["b1"]                                          # b1's syllables zeroed (its timeline end sits 0.02 s before its voice ends)
with wave.open(f"{t}/orig/voiceover.zh.wav") as r:
    sr, pcm = r.getframerate(), bytearray(r.readframes(r.getnframes()))
z0, z1 = int((b1["words"][0]["start"] - 0.005) * sr), int((b1["words"][-1]["end"] + 0.025) * sr)
pcm[2 * z0: 2 * z1] = bytes(2 * (z1 - z0))
with wave.open(f"{t}/u/audio/voiceover.zh.wav", "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr); w.writeframes(bytes(pcm))
o = json.loads(json.dumps(tl)); a, b = o["segments"][2], o["segments"][3]
a["start"], a["end"], b["start"], b["end"] = b["start"], b["end"], a["start"], a["end"]
json.dump(o, open(f"{t}/o/{F}", "w", encoding="utf-8"), ensure_ascii=False)
for v in ("c", "c2"):                                 # word times removed; for c they are in the cache under the take's sha256
    c = json.loads(json.dumps(tl))
    for s in c["segments"]:
        s.pop("words", None)
    Path(f"{t}/{v}/{F}").write_text(json.dumps(c, ensure_ascii=False), encoding="utf-8")
sha = hashlib.sha256(open(f"{t}/orig/voiceover.zh.wav", "rb").read()).hexdigest()
Path(f"{t}/c/audio/pace.zh.asr.json").write_text(json.dumps({"sha256": sha, "engine": "whisper", "segments": [
    {"start": s["start"], "end": s["end"], **({"words": s["words"]} if s.get("words") else {})} for s in tl["segments"]]}), encoding="utf-8")
Path(f"{t}/n/audio/script.txt").unlink()
SR, x, segs, A = 22050, [0.0] * int(0.4 * 22050), [], Path(f"{t}/t/audio")
A.mkdir(parents=True)
def burst(dur, amp, f0):
    n = int(dur * SR); return [amp * math.sin(math.pi * i / n) ** 0.5 * (math.sin(2 * math.pi * f0 * i / SR) + 0.5 * math.sin(4 * math.pi * f0 * i / SR)) for i in range(n)]
for sid, text, plan in (("t1", "甲乙丙丁戊己庚辛。", [("breath",)] + [(0.15, 0.05)] * 8), ("t2", "子丑寅卯辰巳午未申酉戌亥。", [(0.09, 0.09)] * 3 + [(0.15, 0.05)] * 9),
                        ("t3", "东南西北中发白甲。", [(0.15, 0.05)] * 8)):
    words, chars = [], iter(text[:-1])
    for k, step in enumerate(plan):
        if step == ("breath",):
            x += burst(0.08, 0.0095, 300) + [0.0] * int(0.12 * SR); continue
        t0 = len(x) / SR; x += burst(step[0], 0.25, 150 + 10 * (k % 4))
        words.append({"w": next(chars), "start": round(t0, 3), "end": round(len(x) / SR, 3)}); x += [0.0] * int(step[1] * SR)
    words[-1]["w"] += "。"; segs.append({"id": sid, "zh": text, "en": "", "text": text, "start": words[0]["start"], "end": words[-1]["end"], "words": words})
    x += [0.0] * int(0.45 * SR)
with wave.open(str(A / "voiceover.zh.wav"), "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(struct.pack(f"<{len(x)}h", *(int(round(v * 32767)) for v in x)))
(A / "timeline.zh.json").write_text(json.dumps({"provider": "say", "lang": "zh", "segments": segs}, ensure_ascii=False), encoding="utf-8")
(A / "script.txt").write_text("".join(f"@{s['id']} {s['text']}\n" for s in segs), encoding="utf-8")
PY
  cp -R "$t/c/audio" "$t/c.before"
  a=""; rc=0
  vh pace "$t/u" >"$t/u.out" 2>&1 || a="$a u: $(tail -c 300 "$t/u.out")"
  vh pace "$t/t" >"$t/t.out" 2>&1 || a="$a t: $(tail -c 300 "$t/t.out")"
  b=$(vh pace "$t/c" --dry-run 2>&1) && diff -r "$t/c/audio" "$t/c.before" >/dev/null || a="$a c --dry-run wrote or failed: $b"
  case "$b" in *"transcribed before"*) ;; *) a="$a c --dry-run did not use the cache: $b" ;; esac
  vh pace "$t/c" >/dev/null 2>&1 && cmp -s "$t/c/audio/timeline.zh.raw.json" "$t/c.before/timeline.zh.json" || a="$a c: the .raw timeline is not the original"
  b=$(vh pace "$t/c2" 2>&1); [ $? = 1 ] && case "$b" in *"no word times"*) ;; *) false ;; esac || a="$a c2 (no words, no cache): $b"
  b=$(vh pace "$t/o" 2>&1); [ $? = 1 ] && case "$b" in *"the timeline has"*"out of order"*) ;; *) false ;; esac || a="$a o (spans swapped, the lint): $b"
  b=$(vh pace "$t/o" --skip-lint 2>&1); [ $? = 1 ] && case "$b" in *"re-align the take"*) ;; *) false ;; esac || a="$a o (spans swapped, pace's own guard): $b"
  b=$(vh pace "$t/n" --dry-run 2>&1); case "$b" in *"no audio/script.txt"*) ;; *) a="$a n (no script.txt): $b" ;; esac
  b=$(PYTHONPATH="$t" uv run -q --no-project --with numpy python - "$t" 2>&1 <<'PY'
import json, sys
from onsets import onsets
t = sys.argv[1]; bad = []
raw = {s["id"]: s for s in json.load(open(f"{t}/orig/timeline.zh.json", encoding="utf-8"))["segments"]}
tl = json.load(open(f"{t}/u/audio/timeline.zh.json", encoding="utf-8")); S = {s["id"]: s for s in tl["segments"]}
L = {l["id"]: l for l in tl["pace"]["lines"]}
ons, _, _ = onsets(f"{t}/u/audio/voiceover.zh.wav")
g0 = raw["b1"]["end"] + 0.02 + 0.4 - raw["a2"]["end"]  # a2's voice to b2's, in the take (b2's timeline start is the shared one)
g1 = S["b2"]["start"] - S["a2"]["end"]
if len(ons) != 32 or L["b1"].get("note") != "nothing heard" or abs(g1 - g0) > 0.05 or S["b1"]["end"] - S["b1"]["start"] < 0.1 - 1e-9 \
   or S["b1"]["start"] < S["a2"]["end"]:
    bad.append(f"u: {len(ons)} syllables (32), b1 {L['b1']} at {S['b1']['start']}–{S['b1']['end']}, a2→b2 {g1:.2f} s (the take's {g0:.2f})")
P = {l["id"]: l for l in json.load(open(f"{t}/t/audio/timeline.zh.json", encoding="utf-8"))["pace"]["lines"]}
true = {"t1": 8 / 1.55, "t2": 12 / 2.29}            # syllables over first onset → last end; the breath is not speech
for k, v in true.items():
    if abs(P[k]["pace"] / v - 1) > 0.06: bad.append(f"t: {k} measured {P[k]['pace']:.2f}, true {v:.2f}")
c = json.load(open(f"{t}/c/audio/timeline.zh.json", encoding="utf-8"))
if sum(len(s.get("words", [])) for s in c["segments"]) != 42: bad.append("c: the cached word times did not reach the paced timeline")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
  ) || a="$a $b"
  if [ -z "$a" ]; then ok "pace: a line with no audio keeps its stretch of the take, a quiet breath is not speech and short loud syllables are, cached word times are used and the .raw stays the original, swapped spans and a missing script.txt are said"
  else bad "pace on the other cases:$a"; fi
  mkdir "$t/k" && cp -R "$t/orig" "$t/k/audio"
  a=$(vh pace "$t/k" --dry-run --target 6 --extra b2=0.3 zh 2>&1); rc=$?
  case "$rc:$a" in 0:*"(--target 6)"*) printf '%s\n' "$a" | grep -q '^  b2 .*→ 0\.59 s' && ok "pace --target, --extra and the language after the flags" || bad "pace --extra b2=0.3: $a" ;;
    *) bad "pace --target 6 … zh: exit $rc: $a" ;; esac
  a=$(env -u GEMINI_API_KEY "$VH_BASH" "$ROOT/bin/vh" pace "$t/k" --align gemini 2>&1); rc=$?
  [ $rc = 1 ] && diff -r "$t/k/audio" "$t/orig" >/dev/null && ok "pace --align gemini without a key stops before writing" || bad "pace --align gemini without a key: exit $rc, $a"
  a=$(vh pace "$t/k" --ref b3x --dry-run 2>&1); rc=$?
  case "$rc:$a" in 1:*"--ref b3x"*) ok "pace --ref on a line without words is refused" ;; *) bad "pace --ref b3x: exit $rc: $a" ;; esac
  python3 -c "import json, sys; t = json.load(open(sys.argv[1])); t['grid'] = {'beats': 'm.json'}; json.dump(t, open(sys.argv[1], 'w'))" "$t/k/audio/timeline.zh.json"
  a=$(vh pace "$t/k" 2>&1); rc=$?
  case "$rc:$a" in 1:*"beat grid"*) ok "pace refuses a timeline on a beat grid" ;; *) bad "pace on a beat grid: exit $rc: $a" ;; esac
  # v2: the speech rate leaves pauses out (q2: a 0.5 s pause, no mark); pause floors lengthen only a silence already at a
  # comma or a full stop (q1's 0.04 s comma; q3 runs through its comma: nothing there) and never touch the voice;
  # --relative moves every line of the current take by one factor
  python3 - "$t/q/audio" <<'PY'
import json, math, struct, sys, wave
from pathlib import Path
a = Path(sys.argv[1]); a.mkdir(parents=True); SR = 22050
# id, text, syllable period (s), {after unit k: silence s}, gap after the line: p1 has a 0.04 s comma, p2 a 0.5 s pause
# (no mark), p3 runs straight through its comma (no silence there at all), then a full stop with 0.1 s to the next line
lines = [("q1", "一二三，四五六七八。", 0.2, {3: 0.04}, 0.5), ("q2", "甲乙丙丁戊己庚辛。", 0.16, {4: 0.5}, 0.1),
         ("q3", "东南西，北中发白。", 0.18, {}, 0.6)]
x, segs = [0.0] * int(0.4 * SR), []
for k, (sid, text, per, pauses, gap) in enumerate(lines):
    chars = [c for c in text if c not in "，。"]; words = []; burst = per * 0.8
    for j, c in enumerate(chars):
        t0, n, f0 = len(x) / SR, int(burst * SR), 150 + 12 * ((j * 5 + k) % 4)
        x += [0.25 * math.sin(math.pi * i / n) ** 0.5 * (math.sin(2 * math.pi * f0 * i / SR) + 0.5 * math.sin(4 * math.pi * f0 * i / SR)) for i in range(n)]
        mark = "，" if j + 1 == 3 and "，" in text else ""
        words.append({"w": c + mark + ("。" if j == len(chars) - 1 else ""), "start": round(t0, 3), "end": round(len(x) / SR, 3)})
        if j + 1 < len(chars):
            if sid == "q3" and j + 1 == 3:
                x += [0.0] * 0  # straight on into the next syllable
            else:
                x += [0.0] * int((per - burst) * SR)
            x += [0.0] * int(pauses.get(j + 1, 0) * SR)
    segs.append({"id": sid, "zh": text, "en": "", "text": text, "start": words[0]["start"], "end": words[-1]["end"], "words": words})
    x += [0.0] * int(gap * SR)
x += [0.0] * int(0.5 * SR)
with wave.open(str(a / "voiceover.zh.wav"), "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(struct.pack(f"<{len(x)}h", *(int(round(v * 32767)) for v in x)))
(a / "timeline.zh.json").write_text(json.dumps({"provider": "say", "lang": "zh", "duration": round(len(x) / SR, 3), "segments": segs}, ensure_ascii=False), encoding="utf-8")
(a / "script.txt").write_text("".join(f"@{s['id']} {s['text']}\n" for s in segs), encoding="utf-8")
PY
  cp -R "$t/q/audio" "$t/q.orig"
  a=$(vh pace "$t/q" --dry-run 2>&1); rc=$?
  b=$(vh pace "$t/q" --strength 0 --comma 0.3 --stop 0.5 2>&1) || a="$a floors: $b"
  if [ $rc = 0 ] && b=$(PYTHONPATH="$t" uv run -q --no-project --with numpy python - "$t" "$a" 2>&1 <<'PY'
import json, re, sys
from onsets import onsets
t, dry = sys.argv[1], sys.argv[2]; bad = []
m = re.search(r"^  q2 +8 +([0-9.]+)", dry, re.M)
true = 8 / (8 * 0.16 - 0.032 - 0.032)                 # syllables over the voice, the 0.5 s pause and the gap in front of it left out
if not m or abs(float(m.group(1)) / true - 1) > 0.06: bad.append(f"q2's speech rate {m and m.group(1)}, true {true:.2f}")
if "with pauses" not in dry or "speech rate" not in dry: bad.append("the dry run does not print both rates")
tl = json.load(open(f"{t}/q/audio/timeline.zh.json", encoding="utf-8")); S = {s["id"]: s for s in tl["segments"]}
ons0, _, on0 = onsets(f"{t}/q.orig/voiceover.zh.wav"); ons1, quiet, on1 = onsets(f"{t}/q/audio/voiceover.zh.wav")
runs = lambda on: [len(r) for r in "".join("x" if v else " " for v in on).split()]   # each syllable's voiced frames
if len(ons1) != len(ons0) or max(abs(p - q) for p, q in zip(runs(on0), runs(on1))) > 1: bad.append(f"voice changed: {len(ons0)} → {len(ons1)} syllables, {runs(on0)} → {runs(on1)} frames")
else:
    if quiet[3] < 0.28: bad.append(f"q1's comma: {quiet[3]:.2f} s of quiet (floor 0.3)")
    O = {s["id"]: s for s in json.load(open(f"{t}/q.orig/timeline.zh.json", encoding="utf-8"))["segments"]}
    if abs((S["q3"]["end"] - S["q3"]["start"]) - (O["q3"]["end"] - O["q3"]["start"])) > 0.02:   # its comma has no silence: nothing to lengthen
        bad.append(f"q3, whose voice runs through its comma, changed length: {O['q3']['end'] - O['q3']['start']:.2f} → {S['q3']['end'] - S['q3']['start']:.2f} s")
    if quiet[16] < 0.48: bad.append(f"q2 → q3 after a full stop: {quiet[16]:.2f} s (floor 0.5)")
if tl["pace"]["lengthened"][0] != 1: bad.append(f"pauses lengthened: {tl['pace']['lengthened']}")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
  ); then ok "pace v2: the speech rate leaves pauses out, the dry run prints it and the rate with pauses; pause floors lengthen a silence at a mark, not where the voice runs on, and the voice is untouched"
  else bad "pace v2 (speech rate, floors): exit $rc: $a $b"; fi
  rm -rf "$t/q" && mkdir "$t/q" && cp -R "$t/q.orig" "$t/q/audio"
  a=""
  vh pace "$t/q" --relative -5% >/dev/null 2>&1 || a="$a raw -5% failed"
  t1=$(python3 -c "import json,sys; print(' '.join(str(l['tempo']) for l in json.load(open(sys.argv[1]))['pace']['lines']))" "$t/q/audio/timeline.zh.json")
  [ "$t1" = "0.95 0.95 0.95" ] || a="$a on the original take: tempos $t1 (0.95 each)"
  vh pace "$t/q" >/dev/null 2>&1 || a="$a default run failed"
  last=$(python3 -c "import json,sys; print(' '.join(str(l['tempo']) for l in json.load(open(sys.argv[1]))['pace']['lines']))" "$t/q/audio/timeline.zh.json")
  vh pace "$t/q" --relative +10% >/dev/null 2>&1 || a="$a paced +10% failed"
  python3 - "$t/q/audio/timeline.zh.json" "$last" <<'PY' || a="$a on a paced take: not its tempos × 1.10 within the clamp"
import json, sys
now = [l["tempo"] for l in json.load(open(sys.argv[1]))["pace"]["lines"]]; last = [float(v) for v in sys.argv[2].split()]
sys.exit(0 if all(abs(n - min(1.18, l * 1.1)) < 1e-3 for n, l in zip(now, last)) else 1)
PY
  if [ -z "$a" ]; then ok "pace --relative: every line of the original take × 0.95; on a paced take, its own tempos × 1.10 within the clamp"
  else bad "pace --relative:$a"; fi
  rm -rf "$t"
}

land_checks() {   # tools/land.py on a made-up repository with a local origin and a stand-in gh (no network): a PR stacked
  # on one squashed since (-s ours, its tree kept), done (the squash's tree, main moved on, --clean), a plain merge on a PR
  # already mergeable, --dry-run, a conflict, main moved on after --after (a plain merge, not -s ours), an ignored file,
  # land-deny (named, not repeated), a batch's several CHANGELOG entries, and the PRs it refuses
  local t r k m; t=$(mktemp -d "${TMPDIR:-/tmp}/vh-land.XXXXXX")
  cat > "$t/test.py" <<'PY'
import json, os, subprocess, sys
t, LAND = sys.argv[1], sys.argv[2]
bindir = os.path.join(t, "bin"); os.makedirs(bindir)
with open(os.path.join(bindir, "gh"), "w") as f:   # gh pr view|ready|merge against prs.json, each call logged
    f.write(r'''#!/usr/bin/env python3
import json, os, sys
a, sf = sys.argv[1:], os.environ["LAND_GH_STATE"]
S = json.load(open(sf))
open(os.environ["LAND_GH_LOG"], "a").write(json.dumps(a) + "\n")
def opt(k): return a[a.index(k) + 1] if k in a else None
if a[:2] == ["pr", "view"]:
    print(json.dumps({k: S[a[2]].get(k) for k in opt("--json").split(",")})); sys.exit(0)
if a[:2] == ["pr", "ready"]:
    S[a[2]]["isDraft"] = False
elif a[:2] == ["pr", "merge"]:
    if S[a[2]].get("clean") and "--auto" in a:
        sys.exit(print("GraphQL: Pull request Pull request is in clean status (enablePullRequestAutoMerge)", file=sys.stderr) or 1)
    S[a[2]]["merged_with"] = {"auto": "--auto" in a, "subject": opt("--subject"), "match": opt("--match-head-commit"),
                              "body": open(opt("--body-file")).read() if opt("--body-file") else opt("--body")}
else:
    sys.exit(print("stand-in gh: " + " ".join(a), file=sys.stderr) or 2)
json.dump(S, open(sf, "w"))
''')
os.chmod(os.path.join(bindir, "gh"), 0o755)
env = dict(os.environ, PATH=bindir + os.pathsep + os.environ["PATH"], LAND_GH_STATE=os.path.join(t, "prs.json"),
           LAND_GH_LOG=os.path.join(t, "gh.log"), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
           GIT_AUTHOR_NAME="ci", GIT_AUTHOR_EMAIL="ci@example.invalid", GIT_COMMITTER_NAME="ci", GIT_COMMITTER_EMAIL="ci@example.invalid")
PRS = {}
def git(*a, cwd):
    p = subprocess.run(["git", *a], cwd=cwd, env=env, capture_output=True, text=True)
    if p.returncode: sys.exit(f"setup: git {' '.join(a)}: {p.stderr.strip()}")
    return p.stdout.strip()
def land(*a, cwd):
    json.dump(PRS, open(env["LAND_GH_STATE"], "w"))
    p = subprocess.run([sys.executable, LAND, *a], cwd=cwd, env=env, capture_output=True, text=True)
    PRS.update(json.load(open(env["LAND_GH_STATE"])))
    return p.returncode, p.stdout + p.stderr
def report(problems, what):
    print(("bad\t" if problems else "ok\t") + what + (": " + "; ".join(problems) if problems else ""))
origin, w, c = (os.path.join(t, d) for d in ("origin.git", "w", "c"))
git("init", "-q", "--bare", origin, cwd=t); git("symbolic-ref", "HEAD", "refs/heads/main", cwd=origin)
git("clone", "-q", origin, w, cwd=t); git("symbolic-ref", "HEAD", "refs/heads/main", cwd=w)
CL = "# Changelog\n\n## Unreleased\n\n"
def put(rel, text):
    with open(os.path.join(w, rel), "w") as f: f.write(text)
def entry(title, *lines):   # an entry on top, as a PR adds one
    text = open(os.path.join(w, "CHANGELOG.md")).read()
    put("CHANGELOG.md", text.replace(CL, CL + f"**{title}**\n" + "".join(f"- {x}\n" for x in lines) + "\n", 1))
def commit(msg): git("add", "-A", cwd=w); git("commit", "-q", "-m", msg, cwd=w); return git("rev-parse", "HEAD", cwd=w)
def branch(name, at): git("checkout", "-q", "-B", name, at, cwd=w)
def push(*refs): git("push", "-q", "origin", *refs, cwd=w)
def head(name): return git("rev-parse", f"refs/heads/{name}", cwd=origin)
def tree(sha): return git("rev-parse", f"{sha}^{{tree}}", cwd=origin)
def parents(sha): return git("log", "-1", "--format=%P", sha, cwd=origin).split()
def squash(sha, onto, msg):   # what GitHub's squash makes: the head's tree on main
    git("fetch", "-q", "origin", cwd=w); return git("commit-tree", f"{sha}^{{tree}}", "-p", onto, "-m", msg, cwd=w)
def pr(n, br, sha, **k):
    PRS[str(n)] = dict(dict(number=n, title=f"PR {n}", body="", state="OPEN", isDraft=True, baseRefName="main",
                            headRefName=br, headRefOid=sha, isCrossRepository=False), **k)
def queued(n): return PRS[str(n)].get("merged_with")
put("CHANGELOG.md", CL + "**Older**\n- old\n"); put("a.txt", "a\n"); put(".gitignore", "LOCAL.md\n")
m0 = commit("start"); push("main")
branch("pa", m0); entry("First thing", "one"); put("a.txt", "a1\n"); a1 = commit("first")
branch("pb", a1); entry("Second thing", "two", "three"); put("b.txt", "b\n")
put("CHANGELOG.md", open(os.path.join(w, "CHANGELOG.md")).read().replace("- old\n", "- old, reworded\n")); b1 = commit("second")   # and an older entry edited
branch("pc", m0); put("c.txt", "c\n"); c1 = commit("third")
branch("pd", m0); entry("Fourth", "four"); d1 = commit("fourth")
branch("pe", a1); entry("Fifth", "five"); e1 = commit("fifth")
push("pa", "pb", "pc", "pd", "pe")
s1 = squash(a1, m0, "First thing (#1)"); push(f"{s1}:refs/heads/main", ":pa")   # PR 1 squashed, its branch deleted
git("clone", "-q", origin, c, cwd=t)   # the maintainer's clone, where land.py runs

pr(2, "pb", b1, title="Second")
rc, out = land("ready", "2", "--after", a1, cwd=c); new2 = head("pb"); p = []
if rc: p.append(f"exit {rc}: {out[-300:]}")
if parents(new2) != [b1, s1]: p.append("pb is not the PR's head merged with main")
if tree(new2) != tree(b1): p.append("the tree changed")
if PRS["2"]["isDraft"]: p.append("still a draft")
if queued(2) != {"auto": True, "subject": "Second thing (#2)", "match": new2, "body": "- two\n- three"}: p.append(f"queued {queued(2)}")
report(p, "a PR stacked on one squashed since: main merged with -s ours, its tree kept, pushed, ready, the squash queued (auto, that head, the CHANGELOG entry)")

sq2 = squash(new2, s1, "Second thing (#2)"); push(f"{sq2}:refs/heads/main", ":pb")
PRS["2"].update(state="MERGED", mergeCommit={"oid": sq2}, headRefOid=new2)
git("branch", "pb", new2, cwd=c); git("worktree", "add", "-q", os.path.join(t, "c-pb"), "pb", cwd=c)
git("worktree", "add", "-q", "--detach", os.path.join(t, "c-detached"), new2, cwd=c)
rc, out = land("done", "2", "--clean", cwd=c); p = []
if rc: p.append(f"exit {rc}: {out[-300:]}")
if git("rev-parse", "main", cwd=c) != sq2: p.append("main not moved to the squash")
if os.path.exists(os.path.join(t, "c-pb")): p.append("pb's clean worktree left")
if git("branch", "--list", "pb", cwd=c): p.append("the branch pb left")
if not os.path.exists(os.path.join(t, "c-detached")): p.append("a detached worktree removed")
PRS["8"] = dict(number=8, state="MERGED", headRefName="x", headRefOid=b1, mergeCommit={"oid": s1})
rc8, out8 = land("done", "8", cwd=c)
if rc8 != 1 or "not the tree" not in out8: p.append(f"a squash of another tree: exit {rc8}")
report(p, "done: the squash has the last head's tree, main moved, the branch and its clean worktree removed, a detached one kept; another tree is exit 1")

pr(3, "pc", c1, title="Third", isDraft=False, clean=True)
rc0, out0 = land("ready", "3", "--dry-run", cwd=c); dry_left = head("pc") == c1 and not queued(3)
rc, out = land("ready", "3", cwd=c); new3 = head("pc"); p = []
if rc0 or not dry_left or "dry run" not in out0: p.append(f"the dry run: exit {rc0}, left alone {dry_left}")
if rc: p.append(f"exit {rc}: {out[-300:]}")
if parents(new3) != [c1, sq2]: p.append("pc is not merged with main")
if git("diff", "--name-only", sq2, new3, cwd=origin) != "c.txt": p.append("against main it changes more than c.txt")
if queued(3) != {"auto": False, "subject": "Third (#3)", "match": new3, "body": ""}: p.append(f"merged {queued(3)}")
report(p, "a PR behind main: --dry-run touches nothing; then a plain merge, pushed, no CHANGELOG entry (the PR's title), already mergeable so merged at once")

pr(4, "pd", d1)
rc, out = land("ready", "4", cwd=c)
report([] if rc == 1 and "CHANGELOG.md" in out and "conflicts" in out and head("pd") == d1 and not queued(4)
       else [f"exit {rc}, pd {'moved' if head('pd') != d1 else 'kept'}, queued {queued(4)}: {out[-200:]}"],
       "a merge of main that conflicts: exit 1 with the file named, nothing pushed or queued")

branch("main", sq2); entry("Other thing", "other"); s3 = commit("Other thing (#6)"); push("main")   # main moves on
pr(5, "pe", e1)
rc, out = land("ready", "5", "--after", a1, cwd=c)
report([] if rc == 1 and "plain merge" in out and "conflicts" in out and head("pe") == e1 else [f"exit {rc}: {out[-200:]}"],
       "--after when main has moved on since: a plain merge, not -s ours (which would drop main's change); here it conflicts")

branch("pf", s3); put("LOCAL.md", "mine\n"); git("add", "-f", "LOCAL.md", cwd=w); f1 = commit("local"); push("pf")
pr(6, "pf", f1)
rc, out = land("ready", "6", cwd=c)
report([] if rc == 1 and "LOCAL.md, which git ignores" in out and not queued(6) else [f"exit {rc}: {out[-200:]}"],
       "a PR that adds a file git ignores: exit 1, the file named")

with open(os.path.join(c, ".git", "info", "land-deny"), "w") as f: f.write("# mine\nsecret-name\n")
branch("pg", s3); put("g.txt", "x secret-name\n"); g1 = commit("g"); push("pg")
pr(7, "pg", g1, body="has secret-name in it")
rc, out = land("ready", "7", cwd=c); os.remove(os.path.join(c, ".git", "info", "land-deny"))
report([] if rc == 1 and "g.txt match land-deny line 2" in out and "description matches land-deny line 2" in out
       and "secret-name" not in out and not queued(7) else [f"exit {rc}: {out[-300:]}"],
       "land-deny: an added line and the description name the file and the pattern's line, not the text; nothing queued")

branch("ph", s3); entry("Ninth A", "a"); entry("Ninth B", "b"); h1 = commit("ninth"); push("ph")
pr(9, "ph", h1, title="Batch nine")
rc, out = land("ready", "9", cwd=c)
report([] if rc == 0 and queued(9) == {"auto": True, "subject": "Batch nine (#9)", "match": h1, "body": "Ninth B\n- b\n\nNinth A\n- a"}
       else [f"exit {rc}, queued {queued(9)}"], "a batch adding two CHANGELOG entries: the PR's title, the entries the body")

pr(10, "pe", e1, baseRefName="pb"); pr(11, "pc", c1, state="CLOSED")
r10, o10 = land("ready", "10", cwd=c); r11, o11 = land("ready", "11", cwd=c)
report([] if (r10, r11) == (2, 2) and "based on pb" in o10 and "closed" in o11 else [f"exit {r10}, {r11}"],
       "a PR still based on another branch, and a closed one: exit 2")
print("end")
PY
  python3 "$t/test.py" "$t" "$ROOT/tools/land.py" > "$t/out" 2>&1; r=$?
  while IFS=$'\t' read -r k m; do
    case $k in ok) ok "land: $m" ;; bad) bad "land: $m" ;; esac
  done < "$t/out"
  grep -qx end "$t/out" || bad "land: the test stopped (exit $r): $(tail -n 3 "$t/out" | tr '\n' ' ')"
  rm -rf "$t"
}

# the groups (tools/ci-shards.txt): one a line, in the order a full run takes them, with their seconds on CI's macOS runner.
# OVH_CI_SHARDS=<file>: another table (doc_checks runs tools/ci.sh on broken ones)
CI_TABLE=${OVH_CI_SHARDS:-$ROOT/tools/ci-shards.txt}
groups() { sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$CI_TABLE"; }
shard_of() { # shard_of <i> <n>: the groups of shard i of n, in the table's order. The longest first, each to the shard with
  # the fewest seconds so far (ties: the earlier group, the lower shard), so the same table always deals the same shards
  groups | awk -v i="$1" -v n="$2" '{ name[NR] = $1; w[NR] = $2 + 0; o[NR] = NR }
    END { for (a = 2; a <= NR; a++) { x = o[a]; for (b = a - 1; b >= 1 && w[o[b]] < w[x]; b--) o[b + 1] = o[b]; o[b + 1] = x }
          for (a = 1; a <= NR; a++) { m = 1; for (s = 2; s <= n; s++) if (load[s] < load[m]) m = s; to[o[a]] = m; load[m] += w[o[a]] }
          for (a = 1; a <= NR; a++) if (to[a] == i) print name[a] }'
}
run_groups() { # run_groups <group…>: each group's checks, timed; then how long the run took, each group's seconds as
  # tools/ci-shards.txt takes them (to copy there when the shards drift apart) and the ten slowest checks
  local g g0 t0 s ms m tab=$'\t'
  clock; t0=$CI_NOW
  for g in "$@"; do
    declare -F "$g" >/dev/null || { bad "${CI_TABLE#"$ROOT"/} names $g, which is no function in tools/ci.sh: nothing of it ran"; continue; }
    clock; g0=$CI_NOW; CI_LAST=$CI_NOW; "$g"; clock; CI_GROUPS+=("$g $(( (CI_NOW - g0 + 500) / 1000 ))")
  done
  s=$(( (CI_NOW - t0 + 500) / 1000 ))
  printf '%s took %d min %02d s. Each group in seconds, as tools/ci-shards.txt takes them:\n' "$CI_RUN" $((s / 60)) $((s % 60))
  printf '  %s\n' ${CI_GROUPS[@]+"${CI_GROUPS[@]}"}
  echo "The ten slowest checks, in seconds (from the check before, or from the start of its group):"
  # (awk reads every line: a head that stops early leaves GNU sort writing into a closed pipe, which it says)
  printf '%s\n' ${CI_TIMES[@]+"${CI_TIMES[@]}"} | sort -t "$tab" -k1,1nr | awk 'NR <= 10' | while IFS="$tab" read -r ms m; do
    printf '  %5d.%d  %s\n' $((ms / 1000)) $((ms % 1000 / 100)) "$m"; done
}
usage="usage: tools/ci.sh [--smoke | --shard i/n | --committed [--smoke | --shard i/n]]"
case "${1:-all}" in
  --committed)   # exactly what a push would send: HEAD in a clean temporary checkout, uncommitted changes left out
    shift
    w="$(mktemp -d "${TMPDIR:-/tmp}/vh-ci.XXXXXX")/head"; git worktree add -q --detach "$w" HEAD || exit 2
    (cd "$w" && tools/ci.sh "$@"); rc=$?; git worktree remove --force "$w"; rmdir "$(dirname "$w")"; exit $rc ;;
  --shard)   # i/n, 1 <= i <= n
    case "$#:${2:-}" in 2:[1-9]*/[1-9]*) ;; *) echo "$usage" >&2; exit 2 ;; esac
    i=${2%/*} n=${2#*/}
    case "$i$n" in *[!0-9]*) echo "$usage" >&2; exit 2 ;; esac
    [ "$i" -le "$n" ] || { echo "$usage" >&2; exit 2; }
    CI_RUN="Shard $i/$n" list=$(shard_of "$i" "$n") ;;
  --smoke) [ $# = 1 ] || { echo "$usage" >&2; exit 2; }
    CI_RUN="The smoke tests" list=$(groups | awk '$1 !~ /^(static_checks|doc_checks|readpath_report)$/ { print $1 }') ;;
  all) [ $# -le 1 ] || { echo "$usage" >&2; exit 2; }
    CI_RUN="The run" list=$(groups | awk '{ print $1 }') ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
# no group to run is never a pass: a table gone, emptied or unreadable would make every run "all checks passed"
[ -n "$list" ] || { echo "tools/ci.sh: no groups to run (${CI_TABLE#"$ROOT"/} is missing or empty, or this shard was dealt none)" >&2; exit 2; }
# shellcheck disable=SC2086   # one group a word
run_groups $list
[ -n "$skipped" ] && printf '\033[33m! skipped, so not checked: %s\033[0m\n' "$skipped"   # said again at the end: a pass is not a pass of these
[ $fails = 0 ] && ok "all checks passed" || printf '\033[31m%s check(s) failed\033[0m\n' "$fails"
# 1, not the count: an exit status is the count modulo 256, and 256 failed checks would have been a pass
[ "$fails" = 0 ] || exit 1
