"""bin/vh assets: a project's material, one record a file, in <project>/assets/ledger.json (the record:
tools/assets/asset.schema.json; the collections: tools/assets/ledger.py; the licence classes: tools/assets/licenses.py).

usage: bin/vh assets [list] <project|ledger> [--json] [--all]
       bin/vh assets add <project> <file|folder|url> [--license TEXT] [--license-url U] [--class C] [--origin O]
                  [--source-url U] [--provider P] [--provider-id X] [--title T] [--author A] [--retrieved DATE] [--range a:b]
                  [--attribution TEXT] [--aigc [yes|no]] [--model M] [--prompt TEXT | --prompt-file F] [--seed S]
                  [--cost "0.04 USD"] [--used-by S03,S05] [--tags a,b] [--derived-from ID] [--note TEXT] [--id ID] [--kind K]
                  [--extra JSON] [--update] [--to PATH] [--sha256 HEX] [--rate 2M] [--offline DIR] [--json]
       bin/vh assets check <project> [--policy strict|record] [--film <video> | --all-films] [--json]
       bin/vh assets credits <project> [--film <video>] [--lang zh|en] [--out f.md] [--json]
       bin/vh assets remove <project> <id> [--why TEXT] [--json]
<project> is a folder (or a file inside it), or a name under $OVH_PROJECTS / projects/ (the date prefix optional).

  list     the records, the project's ledger first, then each generated clip's own ledger.json from before v1 that the
           ledger does not supersede (assets/genclips/*/ledger.json); a ledger.json or a library's ledger.jsonl can be
           given instead of a project. Each: id, kind, licence class, path, and what stands out (not there, AIGC, a cost,
           a licence the policy does not take); then the policy and the budget line. --all: the removed ones too
  add      register a file or a folder (its sha256: of a folder, of its listing; tools/assets/ledger.py), or download a URL
           into the project first and register that: --to where in the project (default assets/<its name>), --sha256
           the bytes it must have, --rate a cap (2M = 2 MB a second); a .part left by a stopped download is resumed.
           The licence is classified from --license and --license-url (--class gives it outright). Where it came from
           is --origin, else said by --source-url (download), --model or --aigc (generated) or --class own (self), else
           refused. --cost: what it cost; assets/spend.jsonl (the budget's record, tools/assets/budget.py) gets what it
           does not have for this id yet (a paid command's settled holds count).
           --extra: a JSON object of more fields, kept in the record as they are (a vendor's terms, provenance marks,
           the inputs). --update: change the record of this path or --id (the fields not given are kept; the sha256 and
           size are taken again), e.g. after the file was changed on purpose. An id is the file's name made a slug
           unless --id; ids are never reused. --offline DIR: the URL's response from DIR/responses.json, recorded
           before (CONTRIBUTING.md, 联网的命令), no network
  check    each record that is not removed: its file there and its sha256 the same, the record valid, its prompt_file
           there, its licence one the project's policy takes, a file made from another (derived_from) on record with
           its source's licence at least; then both ways against what the films used (their .render.json lists every
           file bin/vh render sent the page) and the mixes (.mix.json): material a page loaded that the ledger lacks
           (fail), a record no film, mix or used_by accounts for (warn), a film made with other bytes of a file than the
           ledger has (warn), and in one line the mixes' sound files the ledger lacks (tools/assets/uses.py). Of the
           films of one page only the newest is compared (an old draft's files are history): --film <video> compares
           that one, --all-films every one. Assets:
           strict (the BRIEF's Assets line, else LOCAL.md's
           素材许可, else strict) takes public domain, CC0, CC BY, permissive licences, material used under an agreement,
           own work and generated material, and fails on NC, ND, BY-SA and unknown; record lists those as warnings and
           takes them. --policy: another policy for this run
  credits  text to paste where viewers read it: the credit lines a licence requires (the BY family, an agreement's, every
           record's attribution), the courtesy ones (public domain), and a sentence on the AI-generated content with what
           it covers; to stdout, or --out a file. What is for the publisher and not for viewers (turn on the platform's
           AI-content declaration; the lines merged; the records left out) goes to stderr. Records become one line only when no
           words a licence asks for are lost: the same words (punctuation aside), or, from one source (the same page, author and
           licence, or made from one record: derived_from), one line's words inside the other's. The longer stays, or the
           original's line when the other is made from it, and what was dropped is said on stderr. Lines that differ otherwise
           (another title, another licence version, another author) stay apart. --film <video>: only what that film used, as check --film reads it: the files its page
           loaded, any mix's inputs, what those were made from; a data or other file (a table, a paper) stays, since a
           film can use one without loading it. A picture or a sound baked into something on no record is left out too:
           read the list. --lang: zh or en (default: the BRIEF's Language)
  remove   mark a record removed (why: --why): kept on record and in the spend, out of check and credits. A generated
           clip's record from before v1 is moved into the ledger to be marked
--json: {"version": 1, "tool", "project", …} (tools/desk/README.md, 素材台账, has every field); the lines go to stderr.
Exit: 0 · 1 check found a failure, a download failed · 2 usage: no project, no such file or id, an id or a path on
record already, an unreadable ledger.
"""
import argparse, json, os, re, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
import budget, fetch, ledger, licenses, uses   # noqa: E402,E401

SUB = ("list", "add", "check", "credits", "remove")
PROG = "bin/vh assets"
out = sys.stdout   # the lines; stderr under --json


class Usage(Exception):
    """A usage error: exit 2."""


def say(*a):
    print(*a, file=out)


def find(arg, need_project=True):
    """The project a path or a name gives; with need_project False, a ledger file outside any project too (a library's)."""
    p = Path(arg).expanduser()
    if p.exists():
        proj = ledger.project_of(p if p.is_dir() else p.parent)
        if proj is not None:
            return proj
        if not need_project and p.is_file() and p.suffix in (".json", ".jsonl"):
            return p.resolve()
        raise Usage(f"{arg} is not in a project (no BRIEF.md at or above it)")
    from vhdraw import project_dir, Usage as NameUsage
    try:
        proj = project_dir(arg)
    except (NameUsage, SystemExit) as e:
        raise Usage(str(e))
    if not (proj / "BRIEF.md").is_file():
        raise Usage(f"{proj} is not a project (no BRIEF.md)")
    return proj


def shown(base, p):
    try:
        return os.path.relpath(p, Path.cwd()) if not os.path.isabs(str(p)) else str(p)
    except ValueError:
        return str(p)


def state(base, e, policy, hashes=False):
    """What the tools see of an entry now: exists, risks, accepted; with hashes, sha256_now (None when not there)."""
    r = e["record"]
    cls = ledger.class_of(r)
    p = ledger.absolute(base, r["path"]) if isinstance(r.get("path"), str) and r.get("path") else None
    s = {"from": e["from"], "exists": bool(p and p.exists()), "class": cls, "risks": licenses.risks(cls),
         "accepted": licenses.accepted(cls, policy), "attribution": licenses.attribution(cls), "removed": "removed" in r,
         "problems": e["problems"]}
    if hashes:
        s["sha256_now"] = ledger.digest(p)[0] if s["exists"] else None
    return s


def money_of(cost):
    return budget.money(cost["amount"], cost["currency"]) if isinstance(cost, dict) and "amount" in cost and "currency" in cost else ""


# ---- list ----

def cmd_list(a):
    target = find(a.target, need_project=False)
    said = []
    try:
        base, ents, f = ledger.entries(target, said)
    except ledger.LedgerError as e:
        raise Usage(str(e))
    is_project = target.is_dir()
    policy, pfrom = ledger.policy_of(base) if is_project else ("record", "a library")
    rows = []
    for e in ents:
        if "removed" in e["record"] and not a.all:
            continue
        rows.append({"record": e["record"], **state(base, e, policy)})
    live = [x for x in rows if not x["removed"]]
    counts = {"assets": len(live), "removed": sum(1 for e in ents if "removed" in e["record"]),
              "uncleared": sum(1 for x in live if x["risks"]), "aigc": sum(1 for x in live if x["record"].get("aigc") is True),
              "missing": sum(1 for x in live if not x["exists"])}
    res = {"version": 1, "tool": f"{PROG} list", "project": str(base) if is_project else None, "ledger": str(f), "policy": {"assets": policy, "from": pfrom},
           "budget": budget.summary(base) if is_project else None, "counts": counts, "assets": rows, "said": said}
    if a.json:
        print(json.dumps(res, ensure_ascii=False, indent=1))
    else:
        ext = sum(1 for x in rows if x["from"] != ledger.LEDGER.as_posix() and not x["removed"]) if is_project else 0
        say(f"assets: {counts['assets']} on record" + (f": {counts['assets'] - ext} in {ledger.LEDGER.as_posix()}, {ext} from generated clips' ledgers" if ext
                                                         else f" in {ledger.LEDGER.as_posix() if is_project else str(f)}")
            + (f" ({counts['removed']} removed)" if counts["removed"] else "") + f" · Assets: {policy} ({pfrom})")
        if rows:
            w = [max(len(str(x["record"].get(k, ""))) for x in rows) for k in ("id", "kind")]
            wc = max(len(x["class"]) for x in rows)
            wp = min(48, max(len(str(x["record"].get("path", ""))) for x in rows))
            for x in rows:
                r = x["record"]
                bits = []
                if x["removed"]:
                    bits.append("removed")
                elif not x["exists"]:
                    bits.append("not there")
                if r.get("aigc") is True:
                    bits.append("AIGC" + (f" {r['model']}" if r.get("model") else ""))
                if money_of(r.get("cost")):
                    bits.append(money_of(r["cost"]))
                if x["risks"] and not x["removed"]:
                    bits.append(", ".join(licenses.RISK_WORDS[k] for k in x["risks"]) + ("" if x["accepted"] else f" (not taken under {policy})"))
                if x["problems"]:
                    bits.append(f"{len(x['problems'])} problem(s) in the record: bin/vh assets check")
                src = r.get("source") if isinstance(r.get("source"), dict) else {}
                who = " · ".join(str(v) for v in (src.get("author"), src.get("provider")) if v)
                mark = "!" if (x["risks"] and not x["accepted"]) or not x["exists"] or x["problems"] else " "
                say((f" {mark} {str(r.get('id', '?')):<{w[0]}}  {str(r.get('kind', '?')):<{w[1]}}  {x['class']:<{wc}}  {str(r.get('path', '?')):<{wp}}"
                     + (f"  {who}" if who else "") + (f"  · {' · '.join(bits)}" if bits else "")).rstrip())
        for s in said:
            say(f"  {s}")
        if is_project:
            say(budget.line(base))
    return 0


# ---- add ----

def parse_cost(s):
    got = budget.parse(s)
    if not got or got["error"] or len(got["amounts"]) != 1:
        raise Usage(f"--cost {s!r}: one amount with its currency ($0.04, 0.04 USD, ¥3)")
    (cur, n), = got["amounts"].items()
    return {"amount": round(n, 6), "currency": cur}


def cmd_add(a):
    project = find(a.project)
    src = {"origin": a.origin, "url": a.source_url, "provider": a.provider, "provider_id": a.provider_id, "title": a.title,
           "author": a.author, "retrieved": a.retrieved}
    if a.range:
        m = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*[:-]\s*(\d+(?:\.\d+)?)\s*", a.range)
        if not m or float(m.group(1)) > float(m.group(2)):
            raise Usage(f"--range {a.range!r}: start:end in seconds of the original (12.5:20)")
        src["range"] = [float(m.group(1)), float(m.group(2))]
    if a.license_class and a.license_class not in licenses.CLASSES:
        raise Usage(f"--class {a.license_class}: one of {', '.join(licenses.CLASSES)}")
    if a.kind and a.kind not in ledger.KINDS:
        raise Usage(f"--kind {a.kind}: one of {', '.join(ledger.KINDS)}")
    if a.id and not ledger.ID.match(a.id):
        raise Usage(f"--id {a.id}: letters, digits, . _ - (up to 64, not starting with . _ -)")
    cost = parse_cost(a.cost) if a.cost else None
    extra = None
    if a.extra:
        try:
            extra = json.loads(a.extra)
        except ValueError as e:
            raise Usage(f"--extra: not JSON ({e})")
        named = set(ledger.STR_FIELDS) | {"v", "id", "kind", "path", "sha256", "bytes", "license", "source", "aigc", "seed", "cost", "used_by", "tags", "removed"}
        if not isinstance(extra, dict) or named & set(extra):
            raise Usage("--extra: a JSON object of fields the record does not name (its own flags set those: " + ", ".join(sorted(named & set(extra or {}))) + ")"
                        if isinstance(extra, dict) else "--extra: a JSON object")
    if a.prompt and a.prompt_file:
        raise Usage("--prompt or --prompt-file, not both")
    if a.prompt_file and ledger.find_file(project, a.prompt_file) is None:
        raise Usage(f"--prompt-file: no such file: {a.prompt_file} (from here, nor in the project)")
    try:
        rate = fetch.rate_of(a.rate)
    except ValueError as e:
        raise Usage(str(e))
    dl = None
    file = a.file
    if re.match(r"https?://", a.file, re.I):
        name = re.sub(r"[?#].*$", "", a.file).rstrip("/").rsplit("/", 1)[-1] or "download"
        dest = Path(a.to) if a.to and os.path.isabs(a.to) else project / (a.to or f"assets/{name}")
        if dest.exists():
            raise Usage(f"{ledger.rel(project, dest)} is there already: another --to, or register it as it is")
        try:
            dl = fetch.download(a.file, dest, sha256=a.sha256, rate=rate, opener=fetch.opener_from(a.offline))
        except fetch.FetchError as e:
            print(f"{PROG} add: {e}", file=sys.stderr)
            return 1
        src["file_url"] = a.file
        if not src.get("retrieved"):
            src["retrieved"] = time.strftime("%Y-%m-%d")
        if not src.get("origin"):
            src["origin"] = "download"
        file = str(dest)
        say(f"downloaded {fetch.redact(a.file)} → {ledger.rel(project, dest)} ({dl['bytes']:,} bytes{', resumed' if dl['resumed'] else ''})")
    elif a.to or a.sha256 or a.offline or a.rate:
        raise Usage("--to, --sha256, --rate and --offline are for a URL")
    if ledger.find_file(project, file) is None:
        raise Usage(f"no such file or folder: {file} (from here, nor in the project)")
    aigc = None if a.aigc is None else a.aigc == "yes"
    seed = (int(a.seed) if re.fullmatch(r"-?\d+", a.seed) else a.seed) if a.seed is not None else None
    split = (lambda s: [x.strip() for x in s.split(",") if x.strip()])   # noqa: E731
    try:
        rec, old, pay = ledger.add(project, file, id=a.id, kind=a.kind, license=a.license, license_url=a.license_url, license_class=a.license_class,
                              source=src, attribution=a.attribution, aigc=aigc, model=a.model, prompt=a.prompt, prompt_file=a.prompt_file,
                              seed=seed, cost=cost, used_by=split(a.used_by) if a.used_by is not None else None,
                              tags=split(a.tags) if a.tags is not None else None, derived_from=a.derived_from, note=a.note, extra=extra, update=a.update)
    except ledger.CostNotRecorded as e:
        print(f"{PROG} add: {e}", file=sys.stderr)
        return 1
    except (ledger.Refused, FileNotFoundError, ValueError, ledger.LedgerError) as e:
        if dl:
            print(f"{PROG} add: the download is kept at {ledger.rel(project, file)}", file=sys.stderr)
        raise Usage(str(e))
    cls = rec["license"]["class"]
    policy, _ = ledger.policy_of(project)
    say(f"{'updated' if old else 'added'} {rec['id']}: {rec['kind']} {rec['path']} · {cls}"
        + (f" ({rec['license'].get('name')})" if rec["license"].get("name") else "") + f" · sha256 {rec['sha256'][:12]}…"
        + (" · AIGC" if rec.get("aigc") else "") + (f" · {budget.money(pay['amount'], pay['currency'])} spent" if pay else ""))
    if os.path.isabs(rec["path"]):
        say("  ! it is outside the project: a page cannot load it (copy it under assets/ and register the copy)")
    elif rec["path"].split("/")[0].casefold() == "out":
        say("  ! it is under out/, which gets cleared (bin/vh clean, or by hand), and bin/vh assets check then fails on it: copy it under assets/ and register the copy")
    if licenses.risks(cls):
        say(f"  ! {', '.join(licenses.RISK_WORDS[k] for k in licenses.risks(cls))}: "
            + ("Assets: strict does not take it (bin/vh assets check fails on it)" if not licenses.accepted(cls, policy) else "listed by bin/vh assets check (Assets: record)"))
    if licenses.attribution(cls) == "required" and not (rec.get("attribution") or (rec.get("source") or {}).get("author")):
        say("  ! its licence asks for a credit and no author is on record: --author or --attribution (bin/vh assets add … --update)")
    if pay:
        say("  " + budget.line(project))
    try:
        import activity
        activity.note(f"{'updated' if old else 'added'} {rec['id']} ({rec['path']}, {cls})", [str(project / ledger.LEDGER)] + ([file] if dl else []))
    except Exception:   # the log never fails a command
        pass
    if a.json:
        print(json.dumps({"version": 1, "tool": f"{PROG} add", "project": str(project), "record": rec, "replaced": old, "spend": pay,
                          "download": dl}, ensure_ascii=False, indent=1))
    return 0


# ---- check ----

def findings(base, ents, policy):
    """[{"kind", "severity", "id", "path", "message"}] for the records not removed."""
    out = []
    by_id = {e["record"].get("id"): e["record"] for e in ents}
    def put(kind, sev, r, msg, **extra):
        out.append({"kind": kind, "severity": sev, "id": r.get("id"), "path": r.get("path"), "message": msg, **extra})
    for e in ents:
        r = e["record"]
        if "removed" in r:
            continue
        if e["problems"]:
            put("record", "fail", r, f"not a valid record ({e['from']}): " + "; ".join(e["problems"]))
            if not isinstance(r.get("path"), str) or not r.get("path"):
                continue
        p = ledger.absolute(base, r["path"])
        if not p.exists():
            put("missing", "fail", r, "the file is not there" + (" (a folder on record)" if r["path"].endswith("/") else "")
                + ": bring it back, or bin/vh assets remove it")
        elif r["path"].endswith("/") != p.is_dir():
            put("missing", "fail", r, f"on record as a {'folder' if r['path'].endswith('/') else 'file'}, a {'folder' if p.is_dir() else 'file'} there")
        elif isinstance(r.get("sha256"), str) and ledger.SHA.match(r["sha256"]):
            now, _ = ledger.digest(p)
            if now != r["sha256"]:
                put("sha256", "fail", r, f"changed since it was registered (sha256 {r['sha256'][:12]}… on record, {now[:12]}… now): "
                    "after a change on purpose, bin/vh assets add <project> <file> --update", sha256_now=now)
        if isinstance(r.get("prompt_file"), str) and not ledger.absolute(base, r["prompt_file"]).is_file():
            put("prompt_file", "warn", r, f"its prompt_file {r['prompt_file']} is not there")
        lic = r.get("license") if isinstance(r.get("license"), dict) else {}
        cls = ledger.class_of(r)
        rk = licenses.risks(cls)
        if rk:
            name = f"{lic.get('name')} ({cls})" if lic.get("name") else cls
            words = ", ".join(licenses.RISK_WORDS[k] for k in rk)
            if licenses.accepted(cls, policy):
                put("license", "warn", r, f"{name}: {words} (taken: Assets: record)", **{"class": cls, "risks": rk})
            else:
                put("license", "fail", r, f"{name}: {words}. Assets: strict takes public domain, CC0, CC BY, permissive licences, "
                    "material used under an agreement, own and generated work (Assets: record lists the rest instead)", **{"class": cls, "risks": rk})
        if licenses.attribution(cls) == "required" and not (r.get("attribution") or (r.get("source") or {}).get("author")):
            put("credit", "warn", r, "its licence asks for a credit and no author or attribution is on record")
        src = by_id.get(r.get("derived_from")) if isinstance(r.get("derived_from"), str) else None
        if isinstance(r.get("derived_from"), str) and src is None:
            put("derived", "warn", r, f"derived_from names {r['derived_from']}, which is not on record")
        elif src is not None and not set(licenses.risks(ledger.class_of(src))) <= set(rk):
            put("derived", "warn", r, f"made from {src.get('id')} ({ledger.class_of(src)}) but on record as {cls}: a file made from another "
                "keeps its source's licence (bin/vh assets add … --update --class " + ledger.class_of(src) + ")")
    return out


def cmd_check(a):
    project = find(a.project)
    said = []
    try:
        base, ents, f = ledger.entries(project, said)
    except ledger.LedgerError as e:
        raise Usage(str(e))
    policy, pfrom = (a.policy, "--policy") if a.policy else ledger.policy_of(project)
    try:
        used = uses.uses(project, film=a.film, all_films=a.all_films)
    except ValueError as e:
        raise Usage(f"--film {e}")
    fs = findings(base, ents, policy) + uses.compare(ents, used, policy)
    counts = {k: sum(1 for x in fs if x["severity"] == k) for k in ("fail", "warn", "info")}
    status = 1 if counts["fail"] else 0
    live = [e for e in ents if "removed" not in e["record"]]
    say(f"assets check: {len(live)} record(s) in {ledger.LEDGER.as_posix()}" + (f" and {sum(1 for e in live if e['from'] != ledger.LEDGER.as_posix())} from generated clips' ledgers"
                                                                               if any(e["from"] != ledger.LEDGER.as_posix() for e in live) else "")
        + f" · Assets: {policy} ({pfrom})")
    nf = sum(len(f["files"]) for f in used["films"])
    names = ", ".join(f["film"] for f in used["films"][:3]) + (" …" if len(used["films"]) > 3 else "")
    say(f"  against {len(used['films'])} film(s) ({names}: {nf} files their pages loaded) and {len(used['mixes'])} mix(es)" if used["films"] or used["mixes"]
        else "  no film records the files its page loaded yet (bin/vh render writes them into <film>.render.json): only the ledger itself is checked")
    if used["older"]:
        say(f"  · older films of the same page{'s' if len(used['older']) > 1 else ''} left out: {', '.join(used['older'][:3])}{' …' if len(used['older']) > 3 else ''} (--all-films compares them too)")
    if used["unknown"]:
        say(f"  · {', '.join(used['unknown'][:3])}{' …' if len(used['unknown']) > 3 else ''}: rendered before the files a page loads were recorded (render again to compare)")
    for x in fs:
        mark = "✗" if x["severity"] == "fail" else "!" if x["severity"] == "warn" else "·"
        who = "  ".join(str(v) for v in (x["id"], x["path"]) if v)
        say(f"  {mark} {who}: {x['message']}" if who else f"  {mark} {x['message']}")
    for s in said:
        say(f"  ! {s}")
    say(f"assets check: {'pass' if not status else 'fail'} ({counts['fail']} fail, {counts['warn']} warn)")
    if a.json:
        print(json.dumps({"version": 1, "tool": f"{PROG} check", "project": str(project), "ledger": str(f), "policy": {"assets": policy, "from": pfrom},
                          "exit": status, "verdict": "pass" if not status else "fail", "counts": counts, "records": len(live), "findings": fs, "said": said,
                          "uses": {"films": [{"film": f["film"], "sidecar": f["sidecar"], "page": f["page"], "files": len(f["files"])} for f in used["films"]],
                                   "older": used["older"], "unknown": used["unknown"], "mixes": [m["mix"] for m in used["mixes"]]}},
                         ensure_ascii=False, indent=1))
    return status


# ---- credits ----

TXT = {"zh": {"source": "来源", "required": "素材署名", "courtesy": "致谢（公有领域，不强制署名）", "aigc": "AI 生成内容", "by": "，",
              "no_author": "作者未记", "unit": "{n} 件",
              "kinds": {"image": "图片", "video": "视频", "audio": "声音", "font": "字体", "model": "3D 模型", "data": "数据", "other": "其他"},
              "public": "本片含 AI 生成的内容：{what}。",
              "declare": "发布时在平台的发布页打开 AI 生成内容的声明（入口名称以发布时的界面为准；规则见 references/genvideo-ledger.md 的“披露”）。"},
       "en": {"source": "source", "required": "Credits", "courtesy": "Courtesy (public domain, no credit required)", "aigc": "AI-generated content",
              "by": ", ", "no_author": "author not on record", "unit": None,
              "kinds": {"image": "image", "video": "video clip", "audio": "sound", "font": "font", "model": "3D model", "data": "data file",
                        "other": "other file"},
              "public": "This film contains AI-generated content: {what}.",
              "declare": "Turn on the platform's AI-content declaration when publishing (its name changes; the rules are in references/genvideo-ledger.md, 披露)."}}
FACTS = ("data", "other")   # a film can use these without its page loading them: numbers typed into the code, a paper a figure was read from


PROVIDERS = {"nasa": "NASA", "wikimedia-commons": "Wikimedia Commons", "internet-archive": "Internet Archive", "openverse": "Openverse",
             "freesound": "Freesound", "jamendo": "Jamendo", "incompetech": "Incompetech", "kenney": "Kenney", "sonniss": "Sonniss"}


def credit_line(r, lang):
    """A record's credit, and what it lacks: its attribution as written, else title, author, source (its page), licence
    (its deed): TASL, as CC asks."""
    if isinstance(r.get("attribution"), str) and r["attribution"].strip():
        return r["attribution"].strip(), None
    T = TXT[lang]
    src = r.get("source") if isinstance(r.get("source"), dict) else {}
    lic = r.get("license") if isinstance(r.get("license"), dict) else {}
    def link(t, u):
        return f"{t}（{u}）" if lang == "zh" else f"{t} ({u})"
    title = src.get("title") or Path(str(r.get("path", "")).rstrip("/")).name
    title = f"《{title}》" if lang == "zh" else f"“{title}”"
    missing, author = (None, src["author"]) if src.get("author") else ("author", T["no_author"])
    bits = [title, author]
    if src.get("provider") or src.get("url"):
        name = PROVIDERS.get(src.get("provider"), src.get("provider")) or T["source"]
        bits.append(link(name, src["url"]) if src.get("url") else name)
    lname = lic.get("name") or licenses.NAMES.get(lic.get("class"), "")
    if lname:
        bits.append(link(lname, lic["url"]) if lic.get("url") else lname)
    return T["by"].join(bits), missing


def lang_of(project):
    try:
        s = (project / "BRIEF.md").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return "zh"
    m = re.search(r"^\s*[-*]\s*Language\s*[:：]\s*([^\s,<]+)", s, re.M | re.I)
    return "en" if m and m.group(1).lower().startswith("en") else "zh"


def source_key(r, live):
    """What makes two records one source: the page the original came from, its author and licence class, or that original
    itself (up derived_from) when it has no page. None: nothing says."""
    root, seen = r, set()
    while root.get("derived_from") in live and root.get("id") not in seen:
        seen.add(root.get("id"))
        root = live[root["derived_from"]]
    src = root.get("source") if isinstance(root.get("source"), dict) else {}
    if src.get("url"):
        return ("page", src["url"], str(src.get("author") or "").casefold(), ledger.class_of(root))
    return ("original", root.get("id")) if root is not r else None


def inside(short, long):
    return bool(short) and any(long[i:i + len(short)] == short for i in range(len(long) - len(short) + 1))


def one_line_a_source(lines, r, line, live):
    """Put a record's line into lines, on another line only when no words a licence asks for are lost: the same words, or,
    from one source, one's words inside the other's. The longer stays; the original's when the other is made from it
    (the original's credit is what covers it: what goes is only the words on how it was used)."""
    key, words, derived = source_key(r, live), re.findall(r"[^\W_]+", line.casefold()), bool(r.get("derived_from"))
    for x in lines:
        same_source = key and x["_key"] == key
        if words == x["_words"] or (same_source and (inside(words, x["_words"]) or inside(x["_words"], words))):
            x["ids"].append(r.get("id"))
            take = words != x["_words"] and (x["_derived"] and not derived or (x["_derived"] == derived and len(words) > len(x["_words"])))
            if take:
                x["merged"].append(x["line"])
                x["id"], x["line"], x["_words"], x["_derived"] = r.get("id"), line, words, derived
            elif x["line"] != line and line not in x["merged"]:
                x["merged"].append(line)
            return
    lines.append({"id": r.get("id"), "ids": [r.get("id")], "line": line, "merged": [], "_key": key, "_words": words, "_derived": derived})


def credits(project, lang=None, said=None, used=None):
    """{"lang", "film", "left_out": [ids], "required": [{"id", "ids", "line", "merged"}], "courtesy", "aigc": {"count", "kinds",
    "models", "public", "declare", "notice"}, "missing", "text"}. used: uses.uses()'s, to credit only what those films used."""
    base, ents, _ = ledger.entries(project, said)
    lang = lang or lang_of(project)
    T = TXT[lang]
    req, cour, missing, gen, left = [], [], [], [], []
    live = {e["record"].get("id"): e["record"] for e in ents if "removed" not in e["record"]}
    kept = uses.used_ids(ents, used) if used is not None else None
    for e in ents:
        r = e["record"]
        if "removed" in r or e["problems"] and not isinstance(r.get("license"), dict):
            continue
        if kept is not None and r.get("id") not in kept and r.get("kind") not in FACTS:
            left.append(r.get("id"))
            continue
        cls = ledger.class_of(r)
        need = licenses.attribution(cls)
        src = live.get(r.get("derived_from"))   # made from another record (a clip's baked frames, a crop): what that one says covers it
        if r.get("aigc") is True and not (src and src.get("aigc") is True):
            gen.append(r)
        if src and licenses.attribution(ledger.class_of(src)) == need and not (isinstance(r.get("attribution"), str) and r["attribution"].strip()):
            continue
        if need in ("required", "agreement") or (isinstance(r.get("attribution"), str) and r["attribution"].strip() and need != "courtesy"):
            line, miss = credit_line(r, lang)
            one_line_a_source(req, r, line, live)
            if miss and need == "required":
                missing.append({"id": r.get("id"), "what": miss})
        elif need == "courtesy":
            one_line_a_source(cour, r, credit_line(r, lang)[0], live)
    req, cour = [[{k: v for k, v in x.items() if not k.startswith("_")} for x in xs] for xs in (req, cour)]
    kinds = {}
    for r in gen:
        kinds[r.get("kind", "other")] = kinds.get(r.get("kind", "other"), 0) + 1
    models = sorted({r["model"] for r in gen if isinstance(r.get("model"), str)})
    what = ("、" if lang == "zh" else ", ").join(f"{T['kinds'].get(k, k)} {T['unit'].format(n=n)}" if T["unit"] else
                                                f"{n} {T['kinds'].get(k, k)}{'' if n == 1 else 's'}" for k, n in kinds.items())
    if models:
        what += ("（" + "、".join(models) + "）") if lang == "zh" else f" ({', '.join(models)})"
    public = T["public"].format(what=what) if gen else None
    declare = T["declare"] if gen else None
    parts = []
    for head, items in ((T["required"], req), (T["courtesy"], cour)):
        if items:
            parts.append(head + "\n" + "\n".join(f"- {x['line']}" for x in items))
    if public:
        parts.append(T["aigc"] + "\n- " + public)
    return {"lang": lang, "left_out": left, "required": req, "courtesy": cour,
            "aigc": {"count": len(gen), "kinds": kinds, "models": models, "public": public, "declare": declare,
                     "notice": public + ("" if lang == "zh" else " ") + declare if gen else None},
            "missing": missing, "text": "\n\n".join(parts) + ("\n" if parts else "")}


def cmd_credits(a):
    project = find(a.project)
    said = []
    try:
        used = uses.uses(project, film=a.film) if a.film else None
    except ValueError as e:
        raise Usage(f"--film {e}")
    try:
        c = credits(project, a.lang, said, used)
    except ledger.LedgerError as e:
        raise Usage(str(e))
    if a.out:
        Path(a.out).write_text(c["text"], encoding="utf-8")
        say(f"credits: {len(c['required'])} required, {len(c['courtesy'])} courtesy, {c['aigc']['count']} AI-generated → {a.out}")
    elif not a.json:
        print(c["text"] or ("（没有要署名的素材）" if c["lang"] == "zh" else "(nothing to credit)"), end="" if c["text"] else "\n")
    if c["aigc"]["declare"]:
        print(f"{PROG} credits: for you, not for the text: {c['aigc']['declare']}", file=sys.stderr)
    for x in c["required"] + c["courtesy"]:
        for line in x["merged"]:
            print(f"{PROG} credits: merged, same source: “{line[:90]}” into “{x['line'][:90]}”", file=sys.stderr)
    if c["left_out"]:
        print(f"{PROG} credits: left out, not in what {a.film} used: {', '.join(map(str, c['left_out'][:12]))}"
              + (f" … and {len(c['left_out']) - 12} more (--json has them all)" if len(c["left_out"]) > 12 else ""), file=sys.stderr)
    for m in c["missing"]:
        print(f"{PROG} credits: ! {m['id']}: no {m['what']} on record, and its licence asks for one", file=sys.stderr)
    for s in said:
        print(f"{PROG} credits: ! {s}", file=sys.stderr)
    if a.json:
        print(json.dumps({"version": 1, "tool": f"{PROG} credits", "project": str(project), "film": a.film, **c}, ensure_ascii=False, indent=1))
    return 0


# ---- remove ----

def cmd_remove(a):
    project = find(a.project)
    try:
        rec, already = ledger.remove(project, a.id, a.why)
    except (ledger.Refused, ledger.LedgerError) as e:
        raise Usage(str(e))
    say(f"{a.id} was removed already ({rec['removed']['at']})" if already else f"removed {a.id} ({rec.get('path')}): kept on record, out of check and credits")
    if not already:
        try:
            import activity
            activity.note(f"removed {a.id}", [str(project / ledger.LEDGER)])
        except Exception:
            pass
    if a.json:
        print(json.dumps({"version": 1, "tool": f"{PROG} remove", "project": str(project), "record": rec, "already": already}, ensure_ascii=False, indent=1))
    return 0


def parser():
    ap = argparse.ArgumentParser(prog=PROG, description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog="\n\n".join(__doc__.split("\n\n")[1:]))
    sp = ap.add_subparsers(dest="cmd", metavar="{list,add,check,credits,remove}")
    p = sp.add_parser("list", prog=f"{PROG} list", help="the records")
    p.add_argument("target", metavar="project|ledger")
    p.add_argument("--all", action="store_true", help="the removed records too")
    p.add_argument("--json", action="store_true")
    p = sp.add_parser("add", prog=f"{PROG} add", help="register a file, or download one and register it")
    p.add_argument("project")
    p.add_argument("file", metavar="file|folder|url")
    for flag, h in (("--license", "the licence as the source writes it (CC BY 4.0)"), ("--license-url", "the licence's page"),
                    ("--origin", "download, generated, self, user, library or purchased"), ("--source-url", "the item's page"), ("--provider", None),
                    ("--provider-id", None), ("--title", None), ("--author", None), ("--retrieved", "when it was fetched (default today for a URL)"),
                    ("--range", "start:end, seconds of the original taken"), ("--attribution", "the credit line exactly as it must appear"),
                    ("--model", "vendor/model"), ("--prompt", None), ("--prompt-file", None), ("--seed", None), ("--cost", "what it cost: $0.04, 0.04 USD, ¥3"),
                    ("--used-by", "what it is for: S03,S05, cover, bgm"), ("--tags", None), ("--derived-from", "the id it was made from"), ("--note", None),
                    ("--id", None), ("--kind", ", ".join(ledger.KINDS)), ("--to", "where in the project a URL is saved (default assets/<its name>)"),
                    ("--sha256", "the bytes a download must have"), ("--rate", "a download's cap: 2M, 500K"), ("--offline", "DIR: a URL's recorded response"),
                    ("--extra", "JSON: more fields, kept as they are ({\"terms\": {…}})")):
        p.add_argument(flag, help=h)
    p.add_argument("--class", dest="license_class", help="the licence class outright: " + ", ".join(licenses.CLASSES))
    p.add_argument("--aigc", nargs="?", const="yes", choices=("yes", "no"), help="made by a generative model")
    p.add_argument("--update", action="store_true", help="change the record of this path or --id")
    p.add_argument("--json", action="store_true")
    p = sp.add_parser("check", prog=f"{PROG} check", help="files, hashes and licences")
    p.add_argument("project")
    p.add_argument("--policy", choices=licenses.POLICIES)
    p.add_argument("--film", help="compare this film alone (a video whose .render.json lists its files)")
    p.add_argument("--all-films", action="store_true", help="compare every film, not only the newest of each page")
    p.add_argument("--json", action="store_true")
    p = sp.add_parser("credits", prog=f"{PROG} credits", help="the credit lines and the AI-content notice")
    p.add_argument("project")
    p.add_argument("--film", help="only what this film used (a video whose .render.json lists its files)")
    p.add_argument("--lang", choices=("zh", "en"))
    p.add_argument("--out")
    p.add_argument("--json", action="store_true")
    p = sp.add_parser("remove", prog=f"{PROG} remove", help="mark a record removed")
    p.add_argument("project")
    p.add_argument("id")
    p.add_argument("--why")
    p.add_argument("--json", action="store_true")
    return ap


def main(argv):
    global out
    if not argv:
        parser().print_usage(sys.stderr)
        print(f"{PROG}: a project, or a subcommand ({', '.join(SUB)})", file=sys.stderr)
        return 2
    if argv[0] not in SUB and not argv[0].startswith("-"):
        argv = ["list"] + argv
    a = parser().parse_args(argv)
    if a.cmd is None:
        parser().print_usage(sys.stderr)
        return 2
    if getattr(a, "json", False):
        out = sys.stderr
    try:
        return {"list": cmd_list, "add": cmd_add, "check": cmd_check, "credits": cmd_credits, "remove": cmd_remove}[a.cmd](a)
    except Usage as e:
        print(f"{PROG} {a.cmd}: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        sys.exit(0)
