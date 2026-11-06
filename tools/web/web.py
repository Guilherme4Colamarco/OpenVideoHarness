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
           text or markdown: fetch says so; take --dump html and --grep the fact out of it. Obscura fails only when a
           page cannot be opened: a 404, a login or a bot wall comes back as a page and is kept too, so read the title on
           the ✓ line, and the warning when it ended on another host, before trusting what was read. --selector CSS waits
           for that element, up to --wait (default 5 s), and says when it did not come; what is kept is still the whole page
  shot     a 1280×720 screenshot of the settled page (shot.png) and the HTML of a second load (page.html), the same
           record; a page that will be shown or studied as a reference goes on to bin/vh ref add (studied) or bin/vh
           assets add (shown)
  grep     a Python regular expression (case-insensitive) over saved pages; HTML entities and JSON's \\uXXXX and \\/ are
           decoded first, so text kept in a script's JSON is found as it reads. Each hit with N characters around it
  list     the captures: id, when, what was kept, why, the URL
  install  the pinned Obscura release (tools/web/pins.json) for this platform from GitHub, size and sha256 checked,
           into ~/.local/share/ovh/obscura/<tag>/ and linked from --bin (default ~/.local/bin). --from FILE: that
           tarball instead of a download (checked the same way). A platform whose asset has no sha256 on record yet is
           installed only with --accept-unpinned, on its size alone, and the hash is printed to add to pins.json. An
           obscura already on --bin (without --bin: on PATH too) at the pinned version counts as installed; one at
           another version that is not this install's link is left alone unless --force. (The tests:
           --pins FILE, another release table; --offline DIR, the download from DIR/responses.json.)

After fetch, shot and grep a "cite:" line gives the URL, the date and the saved copy, for NOTES.md's sources. The
copy is a check, not material: nothing here clears a page's text or picture for the film.

The browser: $OVH_OBSCURA, else obscura on PATH, else ~/.local/bin/obscura, else this install's. It blocks private
addresses (localhost, 192.168.x) as Obscura does. --json: {"version": 1, …} on stdout (fetch, shot: "capture": the
record, with final_url and title; grep: "hits"; list: "captures"; install: "install"), the lines on stderr. Exit: 0 ·
1 the page could not be opened or the install failed · 2 usage.
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
    x = os.environ.get("XDG_DATA_HOME")   # a relative value is to be ignored (the XDG base directory spec)
    return (Path(x) if x and os.path.isabs(x) else Path.home() / ".local" / "share") / "ovh" / "obscura"


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
    from urllib.parse import urlsplit
    try:
        urlsplit(url).hostname
    except ValueError as e:
        raise Usage(f"{url}: {e}")


def check_times(a):
    if a.timeout < 1:
        raise Usage(f"--timeout {a.timeout}: whole seconds, 1 or more")
    if a.wait is not None and a.wait < 0:
        raise Usage(f"--wait {a.wait}: whole seconds, 0 or more")


def compiled(pattern):
    try:
        return re.compile(pattern, re.I)
    except re.error as e:
        raise Usage(f"the regular expression {pattern!r}: {e}")


def run(exe, url, dump=None, shot=None, a=None):
    """(stdout, what stderr says about the page). Obscura exits non-zero only when the page cannot be opened, so the line
    it prints on loading (no -q) is the one word on where it ended and what it was called."""
    argv = [exe, "fetch", url, "--timeout", str(a.timeout)]
    if dump:
        argv += ["--dump", dump]
    if shot:
        argv += ["--screenshot", str(shot)]
    if getattr(a, "selector", None):
        argv += ["--selector", a.selector]
    if a.wait is not None:
        argv += ["--wait", str(a.wait)]
    budget = a.timeout + (a.wait if a.wait is not None else 5) * 2 + 60   # the load, then a settle and a selector's wait
    try:
        r = subprocess.run(argv, capture_output=True, timeout=budget)
    except subprocess.TimeoutExpired:
        raise Failed(f"{url}: obscura did not finish in {budget} s")
    except OSError as e:
        raise Failed(f"{exe} could not run: {e}")
    err = r.stderr.decode("utf-8", "replace").strip().splitlines()
    if r.returncode != 0:
        said = next((x for x in err if re.match(r"\s*error\b", x, re.I)), err[-1] if err else "no message")
        raise Failed(f"{url}: obscura exit {r.returncode}: {said.strip()}")
    info = {"final_url": None, "title": None, "warnings": [x.strip() for x in err if x.lstrip().startswith("Warning:")]}
    for line in err:
        m = re.match(r'\s*Page loaded: (\S+) - "(.*)"\s*$', line)
        if m:
            info.update(final_url=m.group(1), title=html.unescape(m.group(2)).strip()[:200] or None)
    return r.stdout, info


def title_of(raw):
    m = re.search(rb"<title[^>]*>(.*?)</title>", raw, re.S | re.I)
    return html.unescape(m.group(1).decode("utf-8", "replace")).strip()[:200] if m else None


def visible(text):
    return len(re.sub(r"\s+", "", text))


def host_of(url):
    from urllib.parse import urlsplit
    try:
        h = (urlsplit(url).hostname or "").lower()
    except ValueError:
        return ""
    return h[4:] if h.startswith("www.") else h


def unescaped(text):
    """Text as it reads: HTML entities, JSON's \\uXXXX (surrogate pairs too) and \\/ decoded."""
    def u(m):
        try:
            s = json.loads(f'"{m.group(0)}"')
        except ValueError:
            return m.group(0)
        return m.group(0) if any(0xD800 <= ord(c) <= 0xDFFF for c in s) else s   # half a pair (an emoji regex in a script)
    text = re.sub(r"(?:\\u[dD][89abAB][0-9a-fA-F]{2}\\u[dD][c-fC-F][0-9a-fA-F]{2})|\\u[0-9a-fA-F]{4}", u, text)
    return html.unescape(text.replace("\\/", "/"))


def hits(text, pattern, context, cap=20):
    rx = compiled(pattern)
    hs, view = [], unescaped(text)
    for m in rx.finditer(view):
        s, e = max(0, m.start() - context), min(len(view), m.end() + context)
        hs.append({"at": m.start(), "match": m.group(0), "around": re.sub(r"\s+", " ", view[s:e]).strip()})
        if len(hs) >= cap:
            break
    return hs


def cite(rec, file):
    url = rec.get("final_url") or rec["url"]
    return f"cite: {url} (retrieved {rec['retrieved'][:10]}, {file}, sha256 {rec['files'][Path(file).name]['sha256'][:12]})"


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
    check_times(a)
    if getattr(a, "grep", None):
        compiled(a.grep)   # before anything is fetched or kept
    exe = browser()
    when = now()
    cid = new_id(proj, a.url, when, a.id)
    d = proj / FOLDER / cid
    d.mkdir(parents=True)
    files, warn, first = {}, [], None
    try:
        if kind == "shot":
            _, first = run(exe, a.url, shot=d / "shot.png", a=a)
            if not (d / "shot.png").is_file():
                raise Failed(f"{a.url}: obscura wrote no screenshot (a build without rendering? bin/vh web install)")
            dump = "html"
        else:
            dump = a.dump
        raw, info = run(exe, a.url, dump=dump, a=a)
    except Failed:
        shutil.rmtree(d, ignore_errors=True)
        raise
    page = d / DUMPS[dump]
    page.write_bytes(raw)
    for p in (d / "shot.png", page):
        if p.is_file():
            files[p.name] = file_rec(p)
    text = raw.decode("utf-8", "replace")
    warn += info["warnings"] + [w for w in (first or {}).get("warnings", []) if w not in info["warnings"]]
    final, title = info["final_url"], info["title"] or (title_of(raw) if dump == "html" else None)
    if final and host_of(final) != host_of(a.url):
        warn.append(f"it ended on {final}, another host: look at what came back before citing it (a login or a bot page?)")
    if dump in ("text", "markdown") and visible(text) < THIN:
        warn.append(f"only {visible(text)} visible characters: the page likely renders its text from embedded JSON; "
                    f"take --dump html and --grep the fact out of it")
    rec = {"version": 1, "id": cid, "kind": kind, "url": a.url, "retrieved": when.isoformat().replace("+00:00", "Z"),
           "final_url": final, "dump": dump, "files": files, "title": title, "chars": visible(text),
           "why": a.why, "obscura": version_of(exe), "warnings": warn}
    keep(proj, rec)
    rel = f"{FOLDER.as_posix()}/{cid}/{page.name}"
    say(f"✓ {cid}: {rec['chars']} characters of {dump}" + (" and shot.png" if kind == "shot" else "") + f" → {rel}"
        + (f" · {title!r}" if title else ""))
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
    if a.from_file and not Path(a.from_file).expanduser().is_file():
        raise Usage(f"--from {a.from_file}: no such file")
    mine = str(share().resolve()) + os.sep   # a link into this install's folder, of any release, is its own to replace
    links = [bindir / n for n in pins["files"]]
    theirs = [ln for ln in links if (ln.exists() or ln.is_symlink()) and not os.path.realpath(ln).startswith(mine)]
    if not a.force:
        where = bindir / "obscura"
        if not os.access(where, os.X_OK) and not a.bin:   # no --bin: the one on PATH counts too
            where = shutil.which("obscura") or where
        v = version_of(str(where)) if os.access(where, os.X_OK) else None
        if v == pins["tag"].lstrip("v"):
            say(f"✓ obscura {v} is there already ({os.path.realpath(where)}): left as it is (--force: this install instead)")
            return {"version": 1, "install": {**plan, "obscura": v, "already": True}}
        if theirs:
            raise Failed(f"{theirs[0]} is there already ({os.path.realpath(theirs[0])}, obscura {v or '?'}): left alone; "
                         f"--force replaces it, --bin DIR links elsewhere")
    say(f"→ Obscura {pins['tag']} for {key}: {asset['name']}, {asset['size'] / 1e6:.1f} MB" + (f", from {a.from_file}" if a.from_file else f", from {url}"))
    if a.dry_run:
        say(f"  would unpack into {dest} and link {', '.join(pins['files'])} from {bindir}")
        return {"version": 1, "install": {**plan, "dry_run": True}}
    dest.parent.mkdir(parents=True, exist_ok=True)
    kept = dest.parent / ".download" / asset["name"]   # outside a temporary folder, so a cut download picks up where it stopped
    tgz = Path(a.from_file).expanduser() if a.from_file else kept
    if not a.from_file:
        try:
            fetch.download(url, kept, sha256=asset["sha256"], opener=fetch.opener_from(a.offline))
        except fetch.FetchError as e:
            raise Failed(str(e))
    got = file_rec(tgz)
    def refuse(why):
        if not a.from_file:
            kept.unlink(missing_ok=True)   # or the next try finds the same bad file
        raise Failed(f"{asset['name']}: {why}; nothing installed")
    if got["bytes"] != asset["size"]:
        refuse(f"{got['bytes']} bytes, not the {asset['size']} the release lists")
    if asset["sha256"] and got["sha256"] != asset["sha256"]:
        refuse(f"sha256 {got['sha256'][:12]}… is not the {asset['sha256'][:12]}… on record")
    stage = Path(tempfile.mkdtemp(prefix=".stage-", dir=dest.parent))   # beside the destination, so the last step is a rename
    old = None
    try:
        with tarfile.open(tgz) as t:
            members = {m.name.lstrip("./"): m for m in t.getmembers() if m.isfile()}
            missing = [n for n in pins["files"] if n not in members]
            if missing:
                refuse(f"it has no {', '.join(missing)}")
            for n in pins["files"]:
                with t.extractfile(members[n]) as src, open(stage / n, "wb") as dst:
                    shutil.copyfileobj(src, dst)
                os.chmod(stage / n, 0o755)
        if dest.exists():
            old = Path(tempfile.mkdtemp(prefix=".old-", dir=dest.parent))
            dest.rename(old / "was")
        stage.rename(dest)
    except (tarfile.TarError, OSError) as e:
        shutil.rmtree(stage, ignore_errors=True)
        if old and (old / "was").exists() and not dest.exists():
            (old / "was").rename(dest)
        refuse(f"could not be unpacked ({e})")
    except Failed:
        shutil.rmtree(stage, ignore_errors=True)
        raise
    if old:
        shutil.rmtree(old, ignore_errors=True)
    if not a.from_file:
        kept.unlink(missing_ok=True)
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
