"""bin/vh scout: what a topic looks like on the platforms before a film is chosen, and how a film did after it went out.
Public, no-login interfaces only (tools/scout/sources.py); every number keeps where it came from, how, and when.

usage: bin/vh scout topic <keywords> [-n 20] [--baseline [N]] [--covers] [where] [--csv F] [--json] [--offline DIR] [--sleep S]
       bin/vh scout channel <url|@handle> [-n 30] [--platform youtube|x] [where] [--csv F] [--json] [--offline DIR]
       bin/vh scout post <url>… [--topic ID] [--score N] [where] [--csv F] [--json] [--offline DIR]
       bin/vh scout hot [--source baidu,toutiao,google,x] [--geo US] [-n 20] [--days 14] [where] [--csv F] [--json] [--offline DIR]
       bin/vh scout add <url> [--platform P] [--title T] [--views N] [--likes N] … [--post] [where] [--json]
       bin/vh scout add --from rows.csv|rows.json [where] [--json]
       bin/vh scout list [--via V] [--platform P] [--query Q] [--all] [where] [--csv F] [--json]
  where: --dir DIR (a research folder) or --project P (its research/); by default the project around the current
  folder, else $OVH_SCOUT, else nothing is written (the table is printed, and it says so).

  topic    a search's top N videos on YouTube (yt-dlp, metadata only; flat, so dates are approximate): views, age, and
           z, the log of the views against the other results of the same age (0–30 d, –180 d, –2 y, older; all of them
           when a band has under 4). --baseline [N]: also each result's channel (the first N channels, default 8; one
           request each): its followers and the median views of its latest 15, so multiple = views ÷ that median, the
           outlier measure that holds across channels of any size (★ at 3× and over). The titles of the ★ ones and of
           the rest side by side: length, a question, a number, a comparison, a colon (playbook/10 calibrates its title
           formulas on them). --covers: each result's cover into <research>/covers/<run>/ with a caption (rank, views,
           multiple, title), and the lot as one sheet beside it, <run>.png (bin/vh sheet's folder form; uv for pillow)
  channel  a YouTube channel's or an X account's latest N (an X profile gives about 20): followers, the median, each one's
           multiple of it, and how often it posts
  post     your own films after they went out (7 days on is the usual look): a YouTube video, a Bilibili BV, an X post;
           --topic and --score tie a film to its topic and the score it had when it was chosen (a later look without
           them keeps the ones given before). Then every film of yours on record, the latest look at each: age, the
           numbers, views ÷ followers, multiple of your own median, and with 4 or more scored, Spearman's ρ between
           the score and the views. A film on Douyin or Xiaohongshu: scout add --post with the numbers read in the browser
  hot      a snapshot of hot lists (Baidu's realtime board, Toutiao's hot board, Google Trends' daily RSS for --geo, X's
           trends), kept as hot/<date>.json in the research folder; each item with the days it has been on the list
           in the last --days (a one-day wonder, or one that lasts). A list that fails is said; the others are kept
  add      rows read by hand where there is no interface to read: Douyin, Xiaohongshu, a Bilibili search page. Read the
           page in the built-in browser and fill the same table (bin/vh scout add, or a CSV with the export's columns
           and --from). The numbers as the page shows them ("1.2万" is read as 12000); --method says how they were read
  list     the records: the latest look at each video or post (--all: every look), filtered

Every record is a line of <research>/scout.jsonl: {"v": 1, "via", "run", "fetched_at", "platform", "kind", "key", "url",
"title", "author", "author_id", "author_url", "followers", "metrics": {"views", "likes", "comments", "shares",
"favorites", "coins", "danmaku", "quotes"}, "duration", "date", "date_approx", "age_days", "multiple", "baseline": {"of",
"over", "n", "median"}, "per_follower", "z", "query", "rank", "method", "thumb", "license" (as the platform names it),
"copyright" (Bilibili: original or repost, the uploader's claim), "topic", "score", "note"},
a field left out when it is not known; a later look at the same key is a new line, the earlier ones stay (history).
--csv F (- for stdout): the rows of this run (of list: those listed) as CSV. --json: {"version": 1, "via", "dir",
"file", "records": [...]} on stdout (hot: "snapshots" instead of records), the lines a person reads on stderr.
--offline DIR: the responses recorded in DIR/responses.json (tools/assets/fetch.py; yt-dlp's output under
"yt-dlp:<target>"), no network. --sleep S: the pause between two requests to one host (default 1 s).
Rules kept: read only, low rate, no proxy pool, no login; a platform that asks for a verification (a captcha page,
HTTP 412 or 429, Bilibili's -352) stops the run and is said, never retried round; an interface that answers nothing
is said too, never written as an empty table. Exit: 0 · 1 a source failed, was blocked or found nothing · 2 usage.
"""
import argparse, csv, datetime, io, json, math, os, re, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE.parent / "assets"))
import sources   # noqa: E402
from sources import Blocked, SourceError   # noqa: E402

PROG = "bin/vh scout"
SUB = ("topic", "channel", "post", "hot", "add", "list")
LOG = "scout.jsonl"
PLATFORMS = ("youtube", "bilibili", "x", "douyin", "xiaohongshu", "kuaishou", "weixin", "zhihu", "weibo", "web")
METRICS = ("views", "likes", "comments", "shares", "favorites", "coins", "danmaku", "quotes")
COLUMNS = ("via", "platform", "kind", "url", "title", "author", "followers") + METRICS[:7] + (
    "date", "age_days", "multiple", "per_follower", "z", "query", "rank", "topic", "score", "fetched_at", "method")
STAR = 3.0     # a multiple of the baseline median that is marked ★
out = sys.stdout   # the lines a person reads; stderr under --json


class Usage(Exception):
    """A usage error: exit 2."""


def say(*a):
    print(*a, file=out)


def iso(t=None):
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(time.time() if t is None else t))


# ---- where the records go ----

def project(arg):
    import ledger
    p = Path(arg).expanduser()
    if p.exists():
        proj = ledger.project_of(p if p.is_dir() else p.parent)
        if proj is None:
            raise Usage(f"{arg} is not in a project (no BRIEF.md at or above it)")
        return proj
    from vhdraw import project_dir, Usage as NameUsage
    try:
        proj = project_dir(arg)
    except (NameUsage, SystemExit) as e:
        raise Usage(str(e))
    if not (proj / "BRIEF.md").is_file():
        raise Usage(f"{proj} is not a project (no BRIEF.md)")
    return proj


def where(a):
    """(the research folder, how it was chosen), or (None, None): nothing is written."""
    import ledger
    if getattr(a, "dir", None):
        return Path(a.dir).expanduser().resolve(), "--dir"
    if getattr(a, "project", None):
        return project(a.project) / "research", "--project"
    proj = ledger.project_of(Path.cwd())
    if proj is not None:
        return proj / "research", "the project here"
    if os.environ.get("OVH_SCOUT"):
        return Path(os.environ["OVH_SCOUT"]).expanduser().resolve(), "$OVH_SCOUT"
    return None, None


def append(folder, recs):
    """The records onto <folder>/scout.jsonl, one write each with O_APPEND (as .ovh/activity.jsonl)."""
    f = folder / LOG
    folder.mkdir(parents=True, exist_ok=True)
    fd = os.open(f, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        for r in recs:
            os.write(fd, (json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8"))
    finally:
        os.close(fd)
    return f


def read_log(folder, said=None):
    f = Path(folder) / LOG
    if not f.is_file():
        return []
    recs = []
    for n, line in enumerate(f.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        if not line.strip():
            continue
        try:
            r = json.loads(line)
        except ValueError:
            r = None
        if not isinstance(r, dict) or r.get("v") != 1:
            if said is not None:
                said.append(f"{f}:{n}: not a scout record, skipped")
            continue
        recs.append(r)
    return recs


def latest(recs):
    """The last look at each key (a record without a key stands alone), in the order the keys first came."""
    by, order = {}, []
    for i, r in enumerate(recs):
        k = r.get("key") or f"#{i}"
        if k not in by:
            order.append(k)
        by[k] = r
    return [by[k] for k in order]


# ---- the numbers ----

def median(xs):
    xs = sorted(x for x in xs if isinstance(x, (int, float)))
    if not xs:
        return None
    m = len(xs) // 2
    return xs[m] if len(xs) % 2 else (xs[m - 1] + xs[m]) / 2


def metric(r):
    """(name, value) of the count an outlier is measured on: views, else likes (Douyin and Xiaohongshu show no views)."""
    m = r.get("metrics") or {}
    for k in ("views", "likes"):
        if isinstance(m.get(k), int):
            return k, m[k]
    return None, None


def age(r, now):
    if not r.get("date"):
        return None
    try:
        return max(0, (now - datetime.date.fromisoformat(r["date"])).days)
    except ValueError:
        return None


def band(days):
    return None if days is None else 0 if days <= 30 else 1 if days <= 180 else 2 if days <= 730 else 3


def stamp(recs, via, run, query=None):
    """Each record made whole: v, via, run, fetched_at, age_days and views ÷ followers."""
    now, at = datetime.date.today(), iso()
    for r in recs:
        r.update({"v": 1, "via": via, "run": run, "fetched_at": at})
        if query is not None:
            r.setdefault("query", query)
        d = age(r, now)
        if d is not None:
            r["age_days"] = d
        name, v = metric(r)
        if v is not None and r.get("followers"):
            r["per_follower"] = round(v / r["followers"], 4)
    return [{k: r[k] for k in ("v", "via", "run", "fetched_at") + tuple(x for x in r if x not in ("v", "via", "run", "fetched_at"))} for r in recs]


def mark_z(recs):
    """z of log10(the metric) against the others of the same age band (≥ 4 of them), else against all (≥ 4)."""
    pts = [(r, math.log10(v), band(r.get("age_days"))) for r in recs for _, v in [metric(r)] if v and v > 0]
    for r, x, b in pts:
        same = [y for _, y, c in pts if c == b and b is not None]
        pool = same if len(same) >= 4 else [y for _, y, _ in pts]
        if len(pool) < 4:
            continue
        mu = sum(pool) / len(pool)
        sd = (sum((y - mu) ** 2 for y in pool) / (len(pool) - 1)) ** 0.5
        if sd > 0:
            r["z"] = round((x - mu) / sd, 2)


def mark_multiple(recs, base, of, over):
    """multiple = the metric ÷ the baseline median (the median of ≥ 4 counts), and the baseline it was taken over."""
    vals = [v for v in base if isinstance(v, int)]
    med = median(vals) if len(vals) >= 4 else None
    for r in recs:
        name, v = metric(r)
        if med and v is not None and name == of:
            r["multiple"] = round(v / med, 2)
            r["baseline"] = {"of": of, "over": over, "n": len(vals), "median": med}
    return med


def spearman(xs, ys):
    def ranks(v):
        order = sorted(range(len(v)), key=lambda i: v[i])
        r = [0.0] * len(v)
        i = 0
        while i < len(order):
            j = i
            while j + 1 < len(order) and v[order[j + 1]] == v[order[i]]:
                j += 1
            for k in range(i, j + 1):
                r[order[k]] = (i + j) / 2 + 1
            i = j + 1
        return r
    rx, ry = ranks(xs), ranks(ys)
    mx, my = sum(rx) / len(rx), sum(ry) / len(ry)
    sx = sum((a - mx) ** 2 for a in rx) ** 0.5
    sy = sum((b - my) ** 2 for b in ry) ** 0.5
    return None if not sx or not sy else sum((a - mx) * (b - my) for a, b in zip(rx, ry)) / (sx * sy)


# ---- what a person reads ----

def ago(r):
    """The age as a person reads it: 19d, 5mo, 13y; ~ when the date is approximate."""
    d = r.get("age_days")
    if not isinstance(d, int):
        return "–"
    s = f"{d}d" if d < 60 else f"{d // 30}mo" if d < 730 else f"{d // 365}y"
    return s + ("~" if r.get("date_approx") else "")


def number(s):
    """--score: a number, kept whole when it is one."""
    v = float(s)
    return int(v) if v.is_integer() else v


def human(n):
    if not isinstance(n, (int, float)):
        return "–"
    for div, unit in ((1e9, "B"), (1e6, "M"), (1e3, "K")):
        if abs(n) >= div:
            return f"{n / div:.1f}{unit}".replace(".0" + unit, unit)
    return str(int(n))


def width(s):
    return sum(2 if ord(ch) > 0x2E7F else 1 for ch in s)   # a CJK character takes two columns


def cut(s, n):
    """The text on one line, cut to n columns."""
    s = re.sub(r"\s+", " ", str(s or ""))
    w, outp = 0, ""
    for ch in s:
        cw = 2 if ord(ch) > 0x2E7F else 1
        if w + cw > n:
            return outp + "…"
        outp, w = outp + ch, w + cw
    return outp


def pad(s, n):
    return s + " " * max(0, n - width(s))


def table(recs, cols):
    """Rows of a few columns: rank or #, the metric, age, multiple or z, title, author."""
    for i, r in enumerate(recs, 1):
        name, v = metric(r)
        m = r.get("multiple")
        mark = "★" if isinstance(m, (int, float)) and m >= STAR else " "
        parts = [f"{r.get('rank', i):>3}", f"{human(v):>6}{'  ' if name in (None, 'views') else ' ' + name[0]}", f"{ago(r):>5}"]
        if "multiple" in cols:
            parts.append(f"{mark}{m:>5.1f}×" if isinstance(m, (int, float)) else "      –")
        if "z" in cols:
            parts.append(f"{r['z']:>+5.1f}z" if isinstance(r.get("z"), (int, float)) else "     –")
        if "followers" in cols:
            parts.append(f"{human(r.get('followers')):>6}")
        parts.append(pad(cut(r.get("title"), 54), 55))
        parts.append(cut(r.get("author"), 20))
        say("  " + "  ".join(parts))


def csv_rows(recs):
    for r in recs:
        m = r.get("metrics") or {}
        yield [r.get(c) if c not in METRICS else m.get(c) for c in COLUMNS]


def write_csv(dest, recs):
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(COLUMNS)
    for row in csv_rows(recs):
        w.writerow(["" if x is None else x for x in row])
    if dest == "-":
        sys.stdout.write(buf.getvalue())
        return "stdout"
    Path(dest).expanduser().parent.mkdir(parents=True, exist_ok=True)
    Path(dest).expanduser().write_text(buf.getvalue(), encoding="utf-8")
    return dest


def finish(a, via, recs, folder, how, extra=None):
    f = append(folder, recs) if folder and recs else None
    if f:
        say(f"→ {len(recs)} record{'s' if len(recs) != 1 else ''} onto {shown(f)} ({how})")
    elif recs:
        say("→ not written: no research folder (--dir, --project, a project here, or $OVH_SCOUT)")
    if a.csv:
        say(f"→ CSV: {write_csv(a.csv, recs)}")
    if a.json:
        print(json.dumps({"version": 1, "via": via, "dir": str(folder) if folder else None, "file": str(f) if f else None,
                          "records": recs, **(extra or {})}, ensure_ascii=False, indent=1))


def shown(p):
    p = str(p)
    for base, mark in ((str(Path.cwd()) + os.sep, ""), (str(Path.home()) + os.sep, "~/")):
        if p.startswith(base):
            return mark + p[len(base):]
    return p


def run_id(via):
    return time.strftime("%Y%m%d-%H%M%S") + "-" + via


QUESTION = re.compile(r"[?？]|^(?:why|how|what|when|where|who|is|are|can|does|do|should)\b|为什么|为何|怎么|如何|是什么|会不会|能不能|是不是", re.I)
SHAPES = (("a question", lambda t: bool(QUESTION.search(t))), ("a number", lambda t: bool(re.search(r"\d", t))),
          ("a comparison", lambda t: bool(re.search(r"\bvs\.?(?!\w)|对比|PK|还是", t, re.I))), ("a colon", lambda t: bool(re.search(r"[:：|｜—]", t))))


def title_shapes(recs):
    """Lines comparing the titles of the ★ results with the rest's: median length and how many have each shape."""
    star = [r.get("title") or "" for r in recs if isinstance(r.get("multiple"), (int, float)) and r["multiple"] >= STAR]
    rest = [r.get("title") or "" for r in recs if not (isinstance(r.get("multiple"), (int, float)) and r["multiple"] >= STAR)]
    if not star or not rest:
        return []
    def line(name, ts):
        return (f"  {name} {len(ts)}: {median([len(t) for t in ts]):g} characters · "
                + " · ".join(f"{sum(1 for t in ts if f(t))}/{len(ts)} {what}" for what, f in SHAPES))
    return ["titles", line("★", star), line("the rest", rest)]


def covers(net, recs, folder, run):
    """Each record's cover into <folder>/covers/<run>/, a caption each in captions.json, and one sheet of them."""
    d = folder / "covers" / run
    d.mkdir(parents=True, exist_ok=True)
    caps, got = {}, 0
    for r in recs:
        if not r.get("thumb"):
            continue
        name = f"{r.get('rank', 0):02d}-{re.sub(r'[^A-Za-z0-9_-]+', '-', (r.get('key') or 'x').split(':', 1)[-1])[:40]}.jpg"
        try:
            net.pace.wait(r["thumb"])
            sources.fetch.download(r["thumb"], d / name, opener=net.opener, retries=1)
        except sources.fetch.FetchError as e:
            say(f"! cover of #{r.get('rank')}: {e}")
            continue
        got += 1
        m = r.get("multiple")
        caps[name] = f"#{r.get('rank', '')} · {human(metric(r)[1])}" + (f" · {m:.1f}×" if isinstance(m, (int, float)) else "") + f" · {r.get('title', '')}"
    (d / "captions.json").write_text(json.dumps(caps, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    if not got:
        say("! no cover was fetched")
        return None
    sheet = d.parent / f"{run}.png"   # beside the folder, not in it: bin/vh sheet on the folder again stays the same
    cmd = ["uv", "run", "-q", "--no-project", "--with", "pillow", "python", str(HERE.parent / "sheet.py"), str(d), str(sheet), "5"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        if r.returncode == 0 and sheet.is_file():
            say(f"→ covers: {got} in {shown(d)}, the sheet {shown(sheet)}")
            return sheet
        say(f"! the covers sheet was not drawn: {(r.stderr or r.stdout).strip()[-200:]}")
    except (OSError, subprocess.SubprocessError) as e:
        say(f"! the covers sheet was not drawn ({e}): bin/vh sheet {shown(d)}")
    return None


def failed(e):
    if isinstance(e, Blocked):
        say(f"✗ blocked: {e}")
        say("  scout stops here; nothing was retried. Read it in the built-in browser and add the rows by hand (scout add)")
    else:
        say(f"✗ {e}")
    return 1


# ---- the subcommands ----

def cmd_topic(a):
    folder, how = where(a)
    q = " ".join(a.keywords).strip()
    if not q:
        raise Usage("topic needs keywords")
    net = sources.Net(a.offline, a.sleep)
    try:
        recs = sources.youtube_search(net, q, a.n)
    except (Blocked, SourceError) as e:
        return failed(e)
    if not recs:
        say(f"✗ no results for {q!r} on YouTube: the interface may have changed (bin/vh doctor), or read the search in the browser")
        return 1
    recs = stamp(recs, "topic", run_id("topic"), q)
    if a.baseline:
        seen, chans = set(), []
        for r in recs:
            u = r.get("author_url")
            if u and u not in seen:
                seen.add(u)
                chans.append(u)
        for u in chans[:a.baseline]:
            try:
                ch, vids = sources.youtube_channel(net, u, 15)
            except Blocked as e:
                failed(e)
                break
            except SourceError as e:
                say(f"! {u}: {e} (no baseline for it)")
                continue
            base = [metric(v)[1] for v in vids if metric(v)[0] == "views"]
            mine = [r for r in recs if r.get("author_url") == u]
            for r in mine:
                if ch.get("followers"):
                    r["followers"] = ch["followers"]
                    name, v = metric(r)
                    if v is not None:
                        r["per_follower"] = round(v / ch["followers"], 4)
            mark_multiple(mine, base, "views", "the channel's latest 15")
    mark_z(recs)
    say(f"YouTube · {q} · top {len(recs)} (yt-dlp, flat: ages approximate)" + (" · multiple: views ÷ the channel's median of its latest 15" if a.baseline else ""))
    table(recs, ("multiple", "z") if a.baseline else ("z",))
    stars = [r for r in recs if isinstance(r.get("multiple"), (int, float)) and r["multiple"] >= STAR]
    if stars:
        say(f"  ★ {len(stars)} at {STAR:g}× its channel's median or more: what they share is worth a look (title, cover, the first seconds)")
    for line in title_shapes(recs):
        say(line)
    sheet = covers(net, recs, folder, recs[0]["run"]) if a.covers and folder else None
    if a.covers and not folder:
        say("! --covers: no research folder to keep them in (--dir, --project, a project here, or $OVH_SCOUT)")
    finish(a, "topic", recs, folder, how, {"covers": str(sheet) if sheet else None} if a.covers else None)
    return 1 if net.blocked else 0


def cmd_channel(a):
    folder, how = where(a)
    ref = a.ref.strip()
    plat = a.platform
    if ref.startswith("http"):
        p, what, nid = sources.platform_of(ref)
        if (p, what) not in (("youtube", "channel"), ("x", "profile")):
            raise Usage(f"{ref}: not a YouTube channel or an X profile (a Bilibili or Douyin space is read in the browser)")
        plat, ref = p, (ref if p == "youtube" else nid)
    net = sources.Net(a.offline, a.sleep)
    try:
        ch, recs = (sources.x_profile(net, ref) if plat == "x" else sources.youtube_channel(net, ref, a.n))
    except (Blocked, SourceError) as e:
        return failed(e)
    if not recs:
        say(f"✗ {ref}: no videos or posts in the answer")
        return 1
    recs = stamp(recs[:a.n], "channel", run_id("channel"))
    of = metric(recs[0])[0] or "views"
    med = mark_multiple(recs, [metric(r)[1] for r in recs if metric(r)[0] == of], of, f"its latest {len(recs)}")
    dates = sorted(r["date"] for r in recs if r.get("date"))
    gaps = [(datetime.date.fromisoformat(b) - datetime.date.fromisoformat(a_)).days for a_, b in zip(dates, dates[1:])]
    say(f"{plat} · {ch.get('author')} {ch.get('author_id') or ''} · {human(ch.get('followers'))} followers · latest {len(recs)}"
        + (f" · median {human(med)} {of}" if med else " · under 4 with counts: no median"))
    if gaps:
        say(f"  posts about every {median(gaps):g} days" + (" (dates approximate)" if any(r.get("date_approx") for r in recs) else ""))
    table(recs, ("multiple",))
    finish(a, "channel", recs, folder, how, {"channel": ch, "median": med})
    return 0


def posts_report(folder):
    """Your films on record: each key ever looked at as a post, its latest look (a later channel run refreshes the
    numbers), with the topic and the score last given for it (a later look without them keeps the earlier ones, so a
    film stays in the rank correlation); oldest film first."""
    log = read_log(folder)
    tied = {}
    for r in log:
        if r.get("via") == "post" and r.get("key"):
            tied.setdefault(r["key"], {}).update({k: r[k] for k in ("topic", "score") if r.get(k) not in (None, "")})
    recs = [dict(r, **tied[r["key"]]) for r in latest(log) if r.get("key") in tied]
    recs.sort(key=lambda r: r.get("date") or "9999")
    if not recs:
        return
    of_views = [metric(r)[1] for r in recs if metric(r)[0] == "views"]
    med = median(of_views) if len(of_views) >= 4 else None
    say(f"your films on record ({len(recs)}), the latest look at each" + (f" · your median {human(med)} views" if med else ""))
    say(f"  {'age':>5} {'views':>6} {'×med':>5} {'likes':>6} {'comm.':>6} {'shares':>6} {'favs':>6} {'score':>5}  platform    title")
    for r in recs:
        name, v = metric(r)
        m = r.get("metrics") or {}
        mult = f"{v / med:>5.1f}" if med and name == "views" and v is not None else "    –"
        say(f"  {ago(r):>5} {human(m.get('views')):>6} {mult} {human(m.get('likes')):>6} {human(m.get('comments')):>6}"
            f" {human(m.get('shares')):>6} {human(m.get('favorites')):>6} {str(r.get('score', '–')):>5}  {r.get('platform', ''):<10}  {cut(r.get('title'), 40)}")
    pairs = [(float(r["score"]), metric(r)[1]) for r in recs if isinstance(r.get("score"), (int, float)) and metric(r)[0] == "views"]
    if len(pairs) >= 4:
        rho = spearman([p[0] for p in pairs], [p[1] for p in pairs])
        say(f"  score against views, Spearman ρ = {rho:+.2f} over {len(pairs)} films (compare looks at about the same age)"
            if rho is not None else "  score against views: no spread to rank")
    elif pairs:
        say(f"  {len(pairs)} scored with views: 4 or more give a rank correlation between score and views")


def cmd_post(a):
    folder, how = where(a)
    net = sources.Net(a.offline, a.sleep)
    recs, bad = [], 0
    for u in a.urls:
        try:
            r = sources.lookup(net, u)
        except Blocked as e:
            bad = failed(e)
            break
        except SourceError as e:
            bad = failed(e)
            continue
        for n in net.notes:
            say(f"! {u}: {n}")
        net.notes.clear()
        if a.topic:
            r["topic"] = a.topic
        if a.score is not None:
            r["score"] = a.score
        recs.append(r)
    recs = stamp(recs, "post", run_id("post"))
    for r in recs:
        name, v = metric(r)
        say(f"  {r['platform']} · {cut(r.get('title'), 50)} · {ago(r)} · {human(v)} {name or ''}")
    finish(a, "post", recs, folder, how)
    if folder:
        posts_report(folder)
    return 1 if bad or net.blocked else 0


def snapshot_file(folder, date):
    return folder / "hot" / f"{date}.json"


def hot_days(folder, source, days):
    """{title: (the days it was on the list within `days`, the first of them)} from the snapshots in <folder>/hot/."""
    seen = {}
    if not folder or not (folder / "hot").is_dir():
        return seen
    since = datetime.date.today() - datetime.timedelta(days=days - 1)
    for f in sorted((folder / "hot").glob("*.json")):
        try:
            d = datetime.date.fromisoformat(f.stem)
            doc = json.loads(f.read_text(encoding="utf-8"))
        except (ValueError, OSError):
            continue
        if d < since:
            continue
        for snap in doc.get("snapshots") or []:
            if snap.get("source") != source:
                continue
            for it in snap.get("items") or []:
                t = (it.get("title") or "").strip()
                if t:
                    s = seen.setdefault(t, set())
                    s.add(d.isoformat())
    return {t: (len(s), min(s)) for t, s in seen.items()}


def cmd_hot(a):
    folder, how = where(a)
    names = [s.strip() for s in a.source.split(",") if s.strip()]
    for s in names:
        if s not in sources.HOT:
            raise Usage(f"no hot list {s!r}: {', '.join(sources.HOT)}")
    net = sources.Net(a.offline, a.sleep)
    snaps, bad = [], 0
    for s in names:
        try:
            items, method = sources.hot(net, s, a.geo)
        except (Blocked, SourceError) as e:
            bad = 1
            say(f"✗ {s}: {e}" + (" (blocked: not retried)" if isinstance(e, Blocked) else ""))
            continue
        if not items:
            bad = 1
            say(f"✗ {s}: the list came back empty (the interface may have changed)")
            continue
        snaps.append({"source": s, "fetched_at": iso(), "method": method, "items": items})
    f = None
    if folder and snaps:
        f = snapshot_file(folder, datetime.date.today().isoformat())
        doc = {"v": 1, "date": f.stem, "snapshots": []}
        try:
            old = json.loads(f.read_text(encoding="utf-8"))
            if isinstance(old, dict) and isinstance(old.get("snapshots"), list):
                doc["snapshots"] = old["snapshots"]
        except (OSError, ValueError):
            pass
        doc["snapshots"] += snaps
        f.parent.mkdir(parents=True, exist_ok=True)
        tmp = f.with_name(f".{f.name}.tmp")
        tmp.write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        os.replace(tmp, f)
    for snap in snaps:
        seen = hot_days(folder, snap["source"], a.days)
        say(f"{snap['source']} · {snap['method']} · {len(snap['items'])} items" + (f" · days on the list in the last {a.days}" if seen else ""))
        for it in snap["items"][:a.n]:
            d, first = seen.get(it["title"].strip(), (1, None))
            say(f"  {('↑' if it.get('pinned') else it.get('rank', '')):>3} {human(it.get('score')):>6}  {(str(d) + 'd') if seen else '':>4}"
                f"  {cut(it['title'], 60)}" + (f"  [{it['label']}]" if it.get("label") else ""))
    if f:
        say(f"→ snapshot kept in {shown(f)} ({how})")
    elif snaps:
        say("→ not kept: no research folder (--dir, --project, a project here, or $OVH_SCOUT)")
    if a.csv:
        rows = [{"via": "hot", "platform": s["source"], "kind": "hot", "rank": it.get("rank"), "title": it["title"], "url": it.get("url"),
                 "metrics": {"views": it.get("score")}, "fetched_at": s["fetched_at"], "method": s["method"]} for s in snaps for it in s["items"]]
        say(f"→ CSV: {write_csv(a.csv, rows)}")
    if a.json:
        print(json.dumps({"version": 1, "via": "hot", "dir": str(folder) if folder else None, "file": str(f) if f else None,
                          "snapshots": snaps}, ensure_ascii=False, indent=1))
    return bad


def given(row, line):
    """A record from one row given by hand (flags, or a CSV or JSON row): checked, its counts read as the page writes them."""
    url = (row.get("url") or "").strip()
    if not re.match(r"https?://", url):
        raise Usage(f"{line}: a row needs the page's url (https://…)")
    plat, what, nid = sources.platform_of(url)
    p = (row.get("platform") or "").strip().lower() or plat
    if p not in PLATFORMS:
        raise Usage(f"{line}: platform {p!r} is not one of {', '.join(PLATFORMS)}")
    r = {"platform": p, "kind": (row.get("kind") or ("video" if what == "video" else "post")).strip(),
         "key": f"{p}:{nid}" if nid else f"{p}:{url.split('?')[0].rstrip('/')}", "url": url}
    for k in ("title", "author", "author_id", "author_url", "query", "topic", "note", "license"):
        v = row.get(k)
        if v not in (None, ""):
            r[k] = str(v).strip()
    for k in ("followers", "duration", "rank"):
        v = row.get(k)
        if v not in (None, ""):
            n = sources.num(v)
            if n is None or n < 0:
                raise Usage(f"{line}: {k} {v!r} is not a count")
            r[k] = n
    m = {}
    for k in METRICS:
        v = (row.get("metrics") or {}).get(k) if isinstance(row.get("metrics"), dict) else None
        v = row.get(k) if v in (None, "") else v
        if v not in (None, ""):
            n = sources.num(v)
            if n is None or n < 0:
                raise Usage(f"{line}: {k} {v!r} is not a count (123, 1.2万, 3.4K)")
            m[k] = n
    if m:
        r["metrics"] = m
    if row.get("score") not in (None, ""):
        try:
            r["score"] = float(row["score"]) if "." in str(row["score"]) else int(row["score"])
        except ValueError:
            raise Usage(f"{line}: score {row['score']!r} is not a number")
    d = (row.get("date") or "").strip()
    if d:
        try:
            datetime.date.fromisoformat(d)
        except ValueError:
            raise Usage(f"{line}: date {d!r} is not YYYY-MM-DD")
        r["date"] = d
    r["method"] = (row.get("method") or "").strip() or "built-in browser, read by hand"
    return r


def cmd_add(a):
    folder, how = where(a)
    rows = []
    if a.src:
        f = Path(a.src).expanduser()
        try:
            text = f.read_text(encoding="utf-8-sig")
        except OSError as e:
            raise Usage(f"--from {a.src}: {e}")
        if f.suffix.lower() == ".json":
            try:
                d = json.loads(text)
            except ValueError as e:
                raise Usage(f"--from {a.src}: not JSON ({e})")
            items = d.get("records") if isinstance(d, dict) else d
            if not isinstance(items, list) or not all(isinstance(x, dict) for x in items):
                raise Usage(f"--from {a.src}: a JSON list of rows, or {{\"records\": [...]}}")
            rows = [(x, f"{f.name}[{i}]") for i, x in enumerate(items)]
        else:
            rows = [(x, f"{f.name}:{i + 2}") for i, x in enumerate(csv.DictReader(io.StringIO(text)))]
        if a.url:
            raise Usage("give a url or --from, not both")
    elif a.url:
        rows = [({k: getattr(a, k) for k in ("url", "platform", "kind", "title", "author", "author_id", "followers", "duration", "rank",
                                            "query", "topic", "score", "note", "date", "method") + METRICS}, "the flags")]
    else:
        raise Usage("add needs the page's url (and the numbers read off it), or --from rows.csv|rows.json")
    recs = [given(r, line) for r, line in rows]
    recs = stamp(recs, "post" if a.post else "add", run_id("post" if a.post else "add"))
    for r in recs:
        name, v = metric(r)
        say(f"  {r['platform']} · {cut(r.get('title') or r['url'], 50)} · {human(v)} {name or ''} · {r['method']}")
    finish(a, "post" if a.post else "add", recs, folder, how)
    if a.post and folder:
        posts_report(folder)
    return 0


def cmd_list(a):
    folder, how = where(a)
    if not folder:
        raise Usage("no research folder: --dir, --project, a project here, or $OVH_SCOUT")
    said = []
    recs = read_log(folder, said)
    for s in said:
        say(f"! {s}")
    if not a.all:
        recs = latest(recs)
    for k, v in (("via", a.via), ("platform", a.platform)):
        if v:
            recs = [r for r in recs if r.get(k) in v.split(",")]
    if a.query:
        recs = [r for r in recs if a.query.lower() in (r.get("query") or "").lower() or a.query.lower() in (r.get("title") or "").lower()]
    say(f"{shown(folder / LOG)} · {len(recs)} record{'s' if len(recs) != 1 else ''}" + ("" if a.all else " (the latest look at each)"))
    for r in recs:
        name, v = metric(r)
        say(f"  {r.get('via', ''):<7} {r.get('platform', ''):<10} {human(v):>6}{'  ' if name in (None, 'views') else ' ' + name[0]}"
            f" {ago(r):>6}"
            f" {(format(r['multiple'], '.1f') + '×') if isinstance(r.get('multiple'), (int, float)) else '–':>6}  {cut(r.get('title'), 50)}")
    if a.csv:
        say(f"→ CSV: {write_csv(a.csv, recs)}")
    if a.json:
        print(json.dumps({"version": 1, "via": "list", "dir": str(folder), "file": str(folder / LOG), "records": recs}, ensure_ascii=False, indent=1))
    return 0


def overview(project):
    """What a project's research/ holds, for bin/vh status (tools/desk/README.md, 给客户端的数据): the scout records,
    the days with a hot-list snapshot, the references (bin/vh ref). Files read, nothing fetched; None with no research/."""
    d = Path(project) / "research"
    if not d.is_dir():
        return None
    log = read_log(d)
    days = sorted(f.stem for f in (d / "hot").glob("*.json") if re.fullmatch(r"\d{4}-\d\d-\d\d", f.stem))
    refs, err = [], None
    try:
        doc = json.loads((d / "refs.json").read_text(encoding="utf-8"))
        refs = [r for r in doc.get("assets", []) if isinstance(r, dict)]
    except FileNotFoundError:
        pass
    except (OSError, ValueError, AttributeError) as e:
        err = f"research/refs.json could not be read ({e})"
    web, web_err = [], None
    try:
        web = [json.loads(x) for x in (d / "web.jsonl").read_text(encoding="utf-8").splitlines() if x.strip()]
    except FileNotFoundError:
        pass
    except (OSError, ValueError) as e:
        web_err = f"research/web.jsonl could not be read ({e})"
    return {"web": {"file": "research/web.jsonl" if web or web_err else None, "records": len(web), "error": web_err,
                    "last": max((r.get("retrieved") or "" for r in web if isinstance(r, dict)), default="") or None},
            "scout": {"file": f"research/{LOG}" if log else None, "records": len(log), "latest": len(latest(log)),
                      "films": len({r["key"] for r in log if r.get("via") == "post" and r.get("key")}),
                      "last": max((r.get("fetched_at") or "" for r in log), default="") or None},
            "hot": {"days": len(days), "first": days[0] if days else None, "last": days[-1] if days else None},
            "refs": {"file": "research/refs.json" if refs or err else None, "records": len(refs), "error": err}}


# ---- the command line ----

def parser():
    ap = argparse.ArgumentParser(prog=PROG, description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog="\n\n".join(__doc__.split("\n\n")[1:]))
    sp = ap.add_subparsers(dest="cmd", metavar="{" + ",".join(SUB) + "}")

    def common(p, net=True):
        p.add_argument("--dir", help="the research folder the records go to")
        p.add_argument("--project", help="a project: its research/ folder")
        p.add_argument("--csv", metavar="F", help="this run's rows as CSV (- for stdout)")
        p.add_argument("--json", action="store_true")
        if net:
            p.add_argument("--offline", metavar="DIR", help="answer from DIR/responses.json, no network")
            p.add_argument("--sleep", type=float, default=1.0, help="seconds between two requests to one host (default 1)")
    p = sp.add_parser("topic", prog=f"{PROG} topic", help="a search's top videos, with their outliers")
    p.add_argument("keywords", nargs="+")
    p.add_argument("-n", type=int, default=20)
    p.add_argument("--baseline", type=int, nargs="?", const=8, default=0, metavar="N", help="also the first N channels' medians (default 8)")
    p.add_argument("--covers", action="store_true", help="each result's cover, and one sheet of them")
    common(p)
    p = sp.add_parser("channel", prog=f"{PROG} channel", help="an account's latest, against its own median")
    p.add_argument("ref", metavar="url|@handle")
    p.add_argument("-n", type=int, default=30)
    p.add_argument("--platform", choices=("youtube", "x"), default="youtube", help="what a bare @handle is (default youtube)")
    common(p)
    p = sp.add_parser("post", prog=f"{PROG} post", help="your films after they went out")
    p.add_argument("urls", nargs="+", metavar="url")
    p.add_argument("--topic", help="the topic it was chosen as (an id of your topic list)")
    p.add_argument("--score", type=number, help="the score it had when it was chosen")
    common(p)
    p = sp.add_parser("hot", prog=f"{PROG} hot", help="a snapshot of hot lists")
    p.add_argument("--source", default=",".join(sources.HOT), help=f"lists, comma-separated ({', '.join(sources.HOT)})")
    p.add_argument("--geo", default="US", help="Google Trends' region (US, JP, GB …)")
    p.add_argument("-n", type=int, default=20, help="items printed per list (all are kept)")
    p.add_argument("--days", type=int, default=14, help="the days on the list are counted over these (default 14)")
    common(p)
    p = sp.add_parser("add", prog=f"{PROG} add", help="rows read by hand in the browser")
    p.add_argument("url", nargs="?")
    p.add_argument("--from", dest="src", metavar="F", help="rows from a CSV (the export's columns) or a JSON list")
    p.add_argument("--post", action="store_true", help="one of your own films (scout post reports it)")
    for k in ("platform", "kind", "title", "author", "author-id", "followers", "duration", "rank", "query", "topic", "score", "note",
              "date", "method") + METRICS:
        p.add_argument(f"--{k}", dest=k.replace("-", "_"))
    common(p, net=False)
    p = sp.add_parser("list", prog=f"{PROG} list", help="the records")
    p.add_argument("--via", help="topic, channel, post, add (comma-separated)")
    p.add_argument("--platform")
    p.add_argument("--query", help="a query or a word of the title")
    p.add_argument("--all", action="store_true", help="every look, not the latest of each")
    common(p, net=False)
    return ap


def main(argv):
    global out
    if not argv:
        parser().print_usage(sys.stderr)
        print(f"{PROG}: a subcommand ({', '.join(SUB)})", file=sys.stderr)
        return 2
    a = parser().parse_args(argv)
    if a.cmd is None:
        parser().print_usage(sys.stderr)
        return 2
    if getattr(a, "json", False) and getattr(a, "csv", None) == "-":
        print(f"{PROG} {a.cmd}: --csv - and --json both write stdout: give --csv a file", file=sys.stderr)
        return 2
    if getattr(a, "json", False) or getattr(a, "csv", None) == "-":
        out = sys.stderr
    for k in ("n", "baseline", "days"):
        if isinstance(getattr(a, k, None), int) and getattr(a, k) < (0 if k == "baseline" else 1):
            print(f"{PROG} {a.cmd}: -{'-' if len(k) > 1 else ''}{k} must be {'0 or more' if k == 'baseline' else '1 or more'}", file=sys.stderr)
            return 2
    try:
        return {"topic": cmd_topic, "channel": cmd_channel, "post": cmd_post, "hot": cmd_hot, "add": cmd_add, "list": cmd_list}[a.cmd](a)
    except Usage as e:
        print(f"{PROG} {a.cmd}: {e}", file=sys.stderr)
        return 2
    except (OSError, sources.fetch.FetchError) as e:
        print(f"{PROG} {a.cmd}: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        sys.exit(0)
