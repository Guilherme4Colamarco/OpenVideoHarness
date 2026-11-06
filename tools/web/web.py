"""bin/vh web: read a web page through Obscura, the headless browser for agents (github.com/h4ckf0r0day/obscura), and
keep what was read in the project with its URL and the time, so a fact in NOTES.md can cite the copy it was checked on.

usage: bin/vh web fetch <project> <url> [--dump html|markdown|text|links] [--grep RE] [--context N] [--selector CSS]
                        [--wait S] [--timeout S] [--why TEXT] [--id ID] [--json]
       bin/vh web shot <project> <url> [--wait S] [--timeout S] [--why TEXT] [--id ID] [--json]
       bin/vh web grep <project> <id|all> <RE> [--context N] [--json]
       bin/vh web list <project> [--json]
       bin/vh web install [--bin DIR] [--from FILE] [--accept-unpinned] [--force] [--dry-run] [--json]
<project> is a folder (or a file inside it), or a name under $OVH_PROJECTS / projects/ (the date prefix optional).

  fetch    the page as Obscura renders it (scripts run): --dump markdown (the default), text, html or links, kept as
           research/web/<id>/page.<md|txt|html|links.txt> with meta.json beside it, and one line in research/web.jsonl.
           A page that renders its text from embedded JSON (a help centre, a store page) comes back nearly empty as
           text or markdown: fetch says so; take --dump html and --grep the fact out of it
  shot     a 1280×720 screenshot of the settled page (shot.png) and its HTML (page.html), the same record; a page that
           will be shown or studied as a reference goes on to bin/vh ref add (studied) or bin/vh assets add (shown)
  grep     a Python regular expression (case-insensitive) over saved pages; HTML entities and JSON's \\uXXXX and \\/ are
           decoded first, so text kept in a script's JSON is found as it reads. Each hit with N characters around it
  list     the captures: id, when, what was kept, why, the URL
  install  the pinned Obscura release (tools/web/pins.json) for this platform from GitHub, size and sha256 checked,
           into ~/.local/share/ovh/obscura/<tag>/ and linked from --bin (default ~/.local/bin). --from FILE: that
           tarball instead of a download (checked the same way). A platform whose asset has no sha256 on record yet is
           installed only with --accept-unpinned, on its size alone, and the hash is printed to add to pins.json. An
           obscura already on --bin that is not this install's link is left alone unless --force (one at the pinned
           version counts as installed). (The tests:
           --pins FILE, another release table; --offline DIR, the download from DIR/responses.json.)

After fetch, shot and grep a "cite:" line gives the URL, the date and the saved copy, for NOTES.md's sources. The
copy is a check, not material: nothing here clears a page's text or picture for the film.

The browser: $OVH_OBSCURA, else obscura on PATH, else ~/.local/bin/obscura, else this install's. It blocks private
addresses (localhost, 192.168.x) as Obscura does. --json: {"version": 1, …} on stdout (fetch, shot: "capture": the
record; grep: "hits"; list: "captures"; install: "install"), the lines on stderr. Exit: 0 · 1 the page or the
install failed · 2 usage.
"""
import argparse, datetime, hashlib, html, json, os, platform, re, shutil, subprocess, sys, tarfile, tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE.parent / "assets"))
sys.path.insert(0, str(HERE.parent / "scout"))

PROG = "bin/vh web"
FOLDER = Path("research") / "web"
INDEX = Path("research") / "web.jsonl"
DUMPS = {"markdown": "page.md", "text": "page.txt", "html": "page.html", "links": "page.links.txt"}
THIN = 200   # fewer visible characters than this in a text or markdown dump: the page likely renders from JSON
out = sys.stdout


class Usage(Exception):
    """A usage error: exit 2."""


class Failed(Exception):
    """The page or the install failed: exit 1."""


def say(*a):
    print(*a, file=out)


def project(arg):
    import scout
    try:
        return scout.project(arg)
    except scout.Usage as e:
        raise Usage(str(e))


def share():
    return Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share") / "ovh" / "obscura"


def browser():
    """The obscura to run, or a Failed that says how to get one."""
    env = os.environ.get("OVH_OBSCURA")
    if env:
        if not shutil.which(env):
            raise Failed(f"OVH_OBSCURA={env} is not a program")
        return shutil.which(env)
    pins = json.loads((HERE / "pins.json").read_text(encoding="utf-8"))
    for c in (shutil.which("obscura"), Path.home() / ".local" / "bin" / "obscura", share() / pins["tag"] / "obscura"):
        if c and os.access(c, os.X_OK):
            return str(c)
    raise Failed("obscura not found: bin/vh web install (or set OVH_OBSCURA)")


def version_of(exe):
    try:
        r = subprocess.run([exe, "--version"], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return None
    m = re.search(r"(\d+\.\d+\.\d+)", r.stdout)
    return m.group(1) if m else None


def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)


def slug(s, n=40):
    s = re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")
    return s[:n].strip("-") or "page"


def records(proj):
    f = proj / INDEX
    if not f.is_file():
        return []
    rs = []
    for i, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
        if line.strip():
            try:
                rs.append(json.loads(line))
            except ValueError:
                raise Usage(f"{f}:{i} is not JSON")
    return rs


def new_id(proj, url, when, given):
    taken = {r.get("id") for r in records(proj)} | ({p.name for p in (proj / FOLDER).iterdir()} if (proj / FOLDER).is_dir() else set())
    if given:
        if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", given):
            raise Usage(f"--id {given}: lowercase letters, digits, . _ - only")
        if given in taken:
            raise Usage(f"--id {given} is taken in {proj / INDEX}")
        return given
    from urllib.parse import urlsplit
    u = urlsplit(url)
    base = f"{when:%Y%m%d}-{slug(u.hostname or 'page', 30)}" + (f"-{slug(u.path, 30)}" if slug(u.path) != "page" else "")
    i, cand = 1, base
    while cand in taken:
        i += 1
        cand = f"{base}-{i}"
    return cand


def check_url(url):
    if not re.match(r"https?://[^\s/]+", url):
        raise Usage(f"{url}: an http(s) URL is needed")


def run(exe, url, dump=None, shot=None, a=None):
    argv = [exe, "fetch", url, "-q", "--timeout", str(a.timeout)]
    if dump:
        argv += ["--dump", dump]
    if shot:
        argv += ["--screenshot", str(shot)]
    if getattr(a, "selector", None):
        argv += ["--selector", a.selector]
    if a.wait is not None:
        argv += ["--wait", str(a.wait)]
    try:
        r = subprocess.run(argv, capture_output=True, timeout=a.timeout + 60)
    except subprocess.TimeoutExpired:
        raise Failed(f"{url}: obscura did not finish in {a.timeout + 60} s")
    if r.returncode != 0:
        err = r.stderr.decode("utf-8", "replace").strip().splitlines()
        raise Failed(f"{url}: obscura exit {r.returncode}: {err[-1] if err else 'no message'}")
    return r.stdout


def title_of(raw):
    m = re.search(rb"<title[^>]*>(.*?)</title>", raw, re.S | re.I)
    return html.unescape(m.group(1).decode("utf-8", "replace")).strip()[:200] if m else None


def visible(text):
    return len(re.sub(r"\s+", "", text))


def unescaped(text):
    """Text as it reads: HTML entities, JSON's \\uXXXX (surrogate pairs too) and \\/ decoded."""
    def u(m):
        try:
            return json.loads(f'"{m.group(0)}"')
        except ValueError:
            return m.group(0)
    text = re.sub(r"(?:\\u[dD][89abAB][0-9a-fA-F]{2}\\u[dD][c-fC-F][0-9a-fA-F]{2})|\\u[0-9a-fA-F]{4}", u, text)
    return html.unescape(text.replace("\\/", "/"))


def hits(text, pattern, context, cap=20):
    try:
        rx = re.compile(pattern, re.I)
    except re.error as e:
        raise Usage(f"--grep {pattern!r}: {e}")
    hs, view = [], unescaped(text)
    for m in rx.finditer(view):
        s, e = max(0, m.start() - context), min(len(view), m.end() + context)
        hs.append({"at": m.start(), "match": m.group(0), "around": re.sub(r"\s+", " ", view[s:e]).strip()})
        if len(hs) >= cap:
            break
    return hs


def cite(rec, file):
    return f"cite: {rec['url']} (retrieved {rec['retrieved'][:10]}, {file}, sha256 {rec['files'][Path(file).name]['sha256'][:12]})"


def keep(proj, rec):
    d = proj / FOLDER / rec["id"]
    (d / "meta.json").write_text(json.dumps(rec, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    with open(proj / INDEX, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def file_rec(p):
    b = p.read_bytes()
    return {"bytes": len(b), "sha256": hashlib.sha256(b).hexdigest()}


def capture(a, kind):
    proj = project(a.project)
    check_url(a.url)
    exe = browser()
    when = now()
    cid = new_id(proj, a.url, when, a.id)
    d = proj / FOLDER / cid
    d.mkdir(parents=True)
    files, warn = {}, []
    try:
        if kind == "shot":
            run(exe, a.url, shot=d / "shot.png", a=a)
            if not (d / "shot.png").is_file():
                raise Failed(f"{a.url}: obscura wrote no screenshot (a build without rendering? bin/vh web install)")
            dump = "html"
        else:
            dump = a.dump
        raw = run(exe, a.url, dump=dump, a=a)
    except Failed:
        shutil.rmtree(d, ignore_errors=True)
        raise
    page = d / DUMPS[dump]
    page.write_bytes(raw)
    for p in (d / "shot.png", page):
        if p.is_file():
            files[p.name] = file_rec(p)
    text = raw.decode("utf-8", "replace")
    if dump in ("text", "markdown") and visible(text) < THIN:
        warn.append(f"only {visible(text)} visible characters: the page likely renders its text from embedded JSON; "
                    f"take --dump html and --grep the fact out of it")
    rec = {"version": 1, "id": cid, "kind": kind, "url": a.url, "retrieved": when.isoformat().replace("+00:00", "Z"),
           "dump": dump, "files": files, "title": title_of(raw) if dump == "html" else None, "chars": visible(text),
           "why": a.why, "obscura": version_of(exe), "warnings": warn}
    keep(proj, rec)
    rel = f"{FOLDER.as_posix()}/{cid}/{page.name}"
    say(f"✓ {cid}: {rec['chars']} characters of {dump}" + (" and shot.png" if kind == "shot" else "") + f" → {rel}")
    for w in warn:
        say(f"! {w}")
    hs = hits(text, a.grep, a.context) if getattr(a, "grep", None) else None
    if hs is not None:
        say(f"  {len(hs)} hit(s) for /{a.grep}/" + (" (first 20)" if len(hs) >= 20 else ""))
        for h in hs:
            say(f"  @{h['at']}: …{h['around']}…")
    say(f"  {cite(rec, rel)}")
    if kind == "shot":
        say(f"  a reference? bin/vh ref add {proj.name} {rel.replace(page.name, 'shot.png')} --type page --why …")
    return {"version": 1, "project": str(proj), "capture": rec, **({"hits": hs} if hs is not None else {})}


def cmd_grep(a):
    proj = project(a.project)
    rs = records(proj)
    pick = rs if a.id == "all" else [r for r in rs if r.get("id") == a.id]
    if not pick:
        raise Usage(f"no capture {a.id} in {proj / INDEX} (bin/vh web list {proj.name})")
    found = []
    for r in pick:
        for name in r.get("files", {}):
            if not name.startswith("page"):
                continue
            p = proj / FOLDER / r["id"] / name
            if not p.is_file():
                say(f"! {r['id']}/{name} is on record but gone")
                continue
            hs = hits(p.read_text(encoding="utf-8", errors="replace"), a.pattern, a.context)
            rel = f"{FOLDER.as_posix()}/{r['id']}/{name}"
            if hs:
                say(f"{r['id']} ({len(hs)}): {cite(r, rel)}")
                for h in hs:
                    say(f"  @{h['at']}: …{h['around']}…")
            found.append({"id": r["id"], "file": rel, "url": r["url"], "retrieved": r["retrieved"], "hits": hs})
    n = sum(len(f["hits"]) for f in found)
    say(f"{n} hit(s) in {len(found)} page(s)")
    return {"version": 1, "project": str(proj), "hits": found}


def cmd_list(a):
    proj = project(a.project)
    rs = records(proj)
    for r in rs:
        what = "+".join(sorted(r.get("files", {})))
        say(f"{r['id']:<44} {r['retrieved'][:16]}  {what:<22} {(r.get('why') or '')[:30]:<30} {r['url']}")
    say(f"{len(rs)} capture(s) in {proj / INDEX}" if rs else f"no captures yet: bin/vh web fetch {proj.name} <url>")
    return {"version": 1, "project": str(proj), "captures": rs}


def plat():
    s, m = platform.system().lower(), platform.machine().lower()
    m = {"amd64": "x86_64", "arm64": "arm64" if s == "darwin" else "aarch64", "aarch64": "arm64" if s == "darwin" else "aarch64"}.get(m, m)
    return f"{s}-{m}"


def cmd_install(a):
    import fetch
    pins = json.loads((Path(a.pins) if a.pins else HERE / "pins.json").read_text(encoding="utf-8"))
    key = plat()
    asset = pins["assets"].get(key)
    if asset is None:
        raise Failed(f"no Obscura asset for {key} in pins.json (have: {', '.join(pins['assets'])}): see github.com/{pins['repo']}/releases")
    url = f"https://github.com/{pins['repo']}/releases/download/{pins['tag']}/{asset['name']}"
    dest = share() / pins["tag"]
    bindir = Path(a.bin).expanduser() if a.bin else Path.home() / ".local" / "bin"
    plan = {"tag": pins["tag"], "platform": key, "asset": asset["name"], "url": url, "size": asset["size"],
            "sha256": asset["sha256"], "into": str(dest), "bin": str(bindir), "from": a.from_file}
    if not asset["sha256"] and not a.accept_unpinned:
        raise Failed(f"{asset['name']} has no sha256 on record in tools/web/pins.json, only its size ({asset['size']} bytes): "
                     f"--accept-unpinned installs it on the size alone and prints the hash to add there")
    links, theirs = [bindir / n for n in pins["files"]], []
    for ln in links:
        if (ln.exists() or ln.is_symlink()) and os.path.realpath(ln) != str((dest / ln.name).resolve()):
            theirs.append(ln)
    if theirs and not a.force:
        v = version_of(str(bindir / "obscura"))
        if v == pins["tag"].lstrip("v"):
            say(f"✓ obscura {v} is on {bindir} already ({os.path.realpath(bindir / 'obscura')}): left as it is (--force: this install instead)")
            return {"version": 1, "install": {**plan, "obscura": v, "already": True}}
        raise Failed(f"{theirs[0]} is there already ({os.path.realpath(theirs[0])}, obscura {v or '?'}): left alone; "
                     f"--force replaces it, --bin DIR links elsewhere")
    say(f"→ Obscura {pins['tag']} for {key}: {asset['name']}, {asset['size'] / 1e6:.1f} MB" + (f", from {a.from_file}" if a.from_file else f", from {url}"))
    if a.dry_run:
        say(f"  would unpack into {dest} and link {', '.join(pins['files'])} from {bindir}")
        return {"version": 1, "install": {**plan, "dry_run": True}}
    with tempfile.TemporaryDirectory(prefix="ovh-obscura-") as tmp:
        tgz = Path(tmp) / asset["name"]
        if a.from_file:
            shutil.copyfile(Path(a.from_file).expanduser(), tgz)
        else:
            try:
                fetch.download(url, tgz, sha256=asset["sha256"], opener=fetch.opener_from(a.offline))
            except fetch.FetchError as e:
                raise Failed(str(e))
        got = file_rec(tgz)
        if got["bytes"] != asset["size"]:
            raise Failed(f"{asset['name']}: {got['bytes']} bytes, not the {asset['size']} the release lists; nothing installed")
        if asset["sha256"] and got["sha256"] != asset["sha256"]:
            raise Failed(f"{asset['name']}: sha256 {got['sha256'][:12]}… is not the {asset['sha256'][:12]}… on record; nothing installed")
        with tarfile.open(tgz) as t:
            members = {m.name.lstrip("./"): m for m in t.getmembers() if m.isfile()}
            missing = [n for n in pins["files"] if n not in members]
            if missing:
                raise Failed(f"{asset['name']} has no {', '.join(missing)}; nothing installed")
            stage = Path(tmp) / "x"
            stage.mkdir()
            for n in pins["files"]:
                with t.extractfile(members[n]) as src, open(stage / n, "wb") as dst:
                    shutil.copyfileobj(src, dst)
                os.chmod(stage / n, 0o755)
        dest.parent.mkdir(parents=True, exist_ok=True)
        if dest.exists():
            shutil.rmtree(dest)
        shutil.move(str(stage), dest)
    bindir.mkdir(parents=True, exist_ok=True)
    for name, ln in zip(pins["files"], links):
        if ln.exists() or ln.is_symlink():
            ln.unlink()
        ln.symlink_to(dest / name)
    v = version_of(str(dest / "obscura"))
    say(f"✓ obscura {v or '(its --version did not answer)'} in {dest}, linked from {bindir}")
    if not asset["sha256"]:
        say(f"! the size matched; its sha256 is {got['sha256']}: add it to tools/web/pins.json ({key})")
    if str(bindir) not in os.environ.get("PATH", "").split(os.pathsep):
        say(f"! {bindir} is not on PATH: add it, or set OVH_OBSCURA={dest / 'obscura'}")
    return {"version": 1, "install": {**plan, "sha256_got": got["sha256"], "obscura": v, "links": [str(x) for x in links]}}


def parser():
    p = argparse.ArgumentParser(prog=PROG, add_help=False)
    p.add_argument("-h", "--help", action="store_true")
    sub = p.add_subparsers(dest="cmd")

    def common(q, page=True):
        q.add_argument("project")
        if page:
            q.add_argument("url")
            q.add_argument("--wait", type=int)
            q.add_argument("--timeout", type=int, default=30)
            q.add_argument("--why")
            q.add_argument("--id")
        q.add_argument("--json", action="store_true")

    f = sub.add_parser("fetch", add_help=False)
    common(f)
    f.add_argument("--dump", choices=list(DUMPS), default="markdown")
    f.add_argument("--grep")
    f.add_argument("--context", type=int, default=120)
    f.add_argument("--selector")
    s = sub.add_parser("shot", add_help=False)
    common(s)
    g = sub.add_parser("grep", add_help=False)
    common(g, page=False)
    g.add_argument("id")
    g.add_argument("pattern")
    g.add_argument("--context", type=int, default=120)
    ls = sub.add_parser("list", add_help=False)
    common(ls, page=False)
    i = sub.add_parser("install", add_help=False)
    i.add_argument("--bin")
    i.add_argument("--from", dest="from_file")
    i.add_argument("--accept-unpinned", action="store_true")
    i.add_argument("--force", action="store_true")
    i.add_argument("--dry-run", action="store_true")
    i.add_argument("--pins")      # another pins.json: the tests' made-up release
    i.add_argument("--offline")   # the download from DIR/responses.json (tools/assets/fetch.py)
    i.add_argument("--json", action="store_true")
    return p


def main(argv):
    global out
    if not argv or argv[0] in ("-h", "--help") or "-h" in argv or "--help" in argv:
        print(__doc__.strip())
        return 0
    p = parser()
    p.error = lambda m: (_ for _ in ()).throw(Usage(m))
    for sp in p._subparsers._group_actions[0].choices.values():
        sp.error = p.error
    try:
        a = p.parse_args(argv)
        if a.cmd is None:
            raise Usage("a subcommand: fetch, shot, grep, list or install")
        if a.json:
            out = sys.stderr
        r = {"fetch": lambda: capture(a, "page"), "shot": lambda: capture(a, "shot"), "grep": lambda: cmd_grep(a),
             "list": lambda: cmd_list(a), "install": lambda: cmd_install(a)}[a.cmd]()
    except Usage as e:
        print(f"{PROG}: {e}\n  (bin/vh web -h)", file=sys.stderr)
        return 2
    except Failed as e:
        print(f"✗ {e}", file=sys.stderr)
        return 1
    if a.json:
        print(json.dumps(r, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
