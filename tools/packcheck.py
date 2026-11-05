"""The publishing copy against each platform's length limits: titles, descriptions and tags in PACKAGING.md.

usage: python3 tools/packcheck.py <PACKAGING.md | project> [--json f]      (bin/vh check runs it for the project of the video;
       --json f: every field measured, in a file, for its record)

Reads the "## 发布文案" section of PACKAGING.md (templates/PACKAGING.md shows it): one "### <platform>" heading per
platform (B站, 抖音, YouTube, 小红书, 视频号, or any other name; a heading that names several is held to the smallest
limit of each), and under it
    标题：<one line>
    标签：<tags, separated by commas or 、; a # after a space starts a new one too (#a #b). AI for Science is one tag>
    简介：<the first line, and every line after it up to the next 标题/标签/简介 or heading>
(English labels work too: Title:, Tags:, Description:). Placeholders in braces ({…}) and HTML comments are skipped.
Characters are counted as the platforms count them in their boxes: one per character whatever the script (a Chinese
character is one, so is a letter; a line break counts one), except where a platform's own rule is known (COUNTS below:
X weighs a Chinese character as 2). The limits (LIMITS below) are in playbook/10 with their sources and the date they
were checked; where a platform's limit is not known, only the counts are printed. A limit nobody could find a source for
("unverified") is said with a !, and does not count as over.
Two reminders, neither counting as over: a tag with a space on a platform whose topics stop at a space (抖音, 小红书, 视频号), and,
in a project, the numbers on the "AI 生成内容" line against bin/vh assets credits (only the kinds the line gives a number
for; all the records, or what the newest films used, either will do).
Exit: 0 every field within its limit (or nothing to check) · 1 a field over its limit · 2 no such file.
"""
import json, re, sys, unicodedata
from pathlib import Path

# platform: (names it goes by, {field: (limit, how sure)}); playbook/10-hooks-and-packaging.md, 发布文案的长度
LIMITS = {
    "youtube": (("youtube", "油管"), {"title": (100, "official"), "desc": (5000, "official")}),
    "bilibili": (("b站", "bilibili", "哔哩哔哩"), {"title": (80, "second-hand"), "desc": (2000, "second-hand"), "tags": (10, "unverified")}),
    "douyin": (("抖音", "douyin"), {"title": (30, "second-hand")}),
    "xiaohongshu": (("小红书", "xiaohongshu", "rednote"), {"title": (20, "second-hand")}),
    "channels": (("视频号", "channels"), {"title": (50, "second-hand")}),
    "x": (("x", "twitter", "推特"), {"desc": (280, "official")}),   # a post: no title; the text is the 简介
}
TOPICS = {"douyin", "xiaohongshu", "channels"}   # a topic there stops at a space: `AI for Science` would be `AI`
AI_WORDS = {"图片": "image", "图": "image", "视频": "video", "声音": "audio", "旁白": "audio", "配音": "audio", "配乐": "audio", "音乐": "audio", "音效": "audio"}
FIELDS = {"标题": "title", "title": "title", "简介": "desc", "description": "desc", "描述": "desc", "标签": "tags", "tags": "tags"}
NAMES = {"title": "标题 title", "desc": "简介 description", "tags": "标签 tags"}


# X's weighted length (docs.x.com/fundamentals/counting-characters; the weights are twitter-text's config/v3.json): after
# NFC, a link is 23 whatever its length, an emoji 2 (with its modifiers and joined parts), a code point in U+0000–10FF,
# U+2000–200D, U+2010–201F or U+2032–2037 is 1 and any other 2, so a Chinese character, a full-width comma or 。 is 2.
# A keycap emoji counts more than X's 2.
# A link is what twitter-text's extractUrlsWithIndices takes for one (its regexp/ files, Apache-2.0, ported): after a
# character other than a letter, a digit, @, $ or # (or the full-width ＠ ＃), a domain (labels of anything but ASCII
# punctuation and spaces) whose TLD no letter, digit, @, + or - follows, then an optional :port, /path (ending in a
# letter, a digit, + - = _ # / or a closing parenthesis) and ?query. Written without http(s)://, it is a link only when the TLD is one X knows and
# the domain is not preceded by - _ . or /; only its ASCII part is the link (Chinese written straight before it stays
# text), with the path, but not a query or port that has no path before it. A domain with a label over 63 characters in
# punycode, or a URL over 4096, is no link at all (isValidUrl): Chinese written straight before a domain is part of its
# first label (a full-width comma too), so a long run of it leaves the domain unlinked, as on X. So `example.com/a`, `x.com` and
# `packcheck.py` (Paraguay) are links, `foo_bar.com`, `Node.js` and `tools/x.py` are not. Two simplifications, both
# toward counting more: with http(s):// any ASCII TLD of two letters or more is taken; without it, the TLDs are every
# ASCII ccTLD of twitter-text's list and the gTLDs below, about 200 of its 1,400, so a bare domain under a rare gTLD
# (or an IDN one such as 中国) is counted as its characters: the one case where this can come under X's count.
CCTLD = ("ac ad ae af ag ai al am an ao aq ar as at au aw ax az ba bb bd be bf bg bh bi bj bl bm bn bo bq br bs bt bv bw by bz "
         "ca cc cd cf cg ch ci ck cl cm cn co cr cu cv cw cx cy cz de dj dk dm do dz ec ee eg eh er es et eu fi fj fk fm fo fr ga "
         "gb gd ge gf gg gh gi gl gm gn gp gq gr gs gt gu gw gy hk hm hn hr ht hu id ie il im in io iq ir is it je jm jo jp ke kg "
         "kh ki km kn kp kr kw ky kz la lb lc li lk lr ls lt lu lv ly ma mc md me mf mg mh mk ml mm mn mo mp mq mr ms mt mu mv mw "
         "mx my mz na nc ne nf ng ni nl no np nr nu nz om pa pe pf pg ph pk pl pm pn pr ps pt pw py qa re ro rs ru rw sa sb sc sd "
         "se sg sh si sj sk sl sm sn so sr ss st su sv sx sy sz tc td tf tg th tj tk tl tm tn to tp tr tt tv tw tz ua ug uk um us "
         "uy uz va vc ve vg vi vn vu wf ws ye yt za zm zw").split()
GTLD = ("com net org edu gov mil int arpa info biz name pro mobi aero asia cat coop jobs museum post tel travel xxx xyz app dev "
        "page blog shop store online site website tech top club live news link art design studio video media cloud space fun "
        "life today world email network wiki one ink icu vip work works global digital agency academy company group social chat "
        "zone games game movie film photo photos pics show tube ninja guru tips tools xin ltd plus run red blue pink gold cool "
        "best team center new wtf lol love land city london nyc tokyo berlin paris mov zip docs here google youtube apple baidu "
        "moe men fit wang ren kim bar bio eco foo how ooo pub soy tax uno vote win zero codes software systems solutions services "
        "support rocks host press click help events community foundation institute university school education science finance "
        "money capital ventures partners consulting marketing report review reviews guide download stream watch audio radio "
        "band gallery graphics photography camera computer technology hosting engineering energy health care coffee cafe house "
        "garden fashion style beauty fitness moda eus gal quebec cymru scot africa earth mba phd law legal lawyer doctor bank").split()
_KNOWN = "|".join(sorted(GTLD + CCTLD, key=len, reverse=True)) + r"|xn--[\-0-9a-z]+"
_END = r"(?=[^0-9a-zA-Z@+-]|$)"   # nothing a TLD could go on with
_LAT = ("À-ÖØ-öø-ÿĀ-ɏɓɔɖɗəɛɣɨɯɲ"
        "ʉʋʻ̀-ͯḀ-ỿ")   # twitter-text's latinAccentChars
_DIR = "‪-‮؜‎‏⁦-⁩"   # directional marks
_DC = rf"[^!'#%&()*+,\\\-./:;<=>?@\[\]^_{{|}}~$\s￾﻿￿{_DIR}]"   # a domain character
_PC = rf"[a-zЀ-ӿ0-9!*';:=+,.$/%#\[\]\-–_~@|&{_LAT}]"     # a path character
_PAREN = rf"\((?:{_PC}+|{_PC}*\({_PC}+\){_PC}*)\)"
_PATH = rf"(?:{_PC}*(?:{_PAREN}{_PC}*)*(?:[+\-a-zЀ-ӿ0-9=_#/{_LAT}]|{_PAREN})|@{_PC}+/)"
URL = re.compile(rf"(?P<pre>[^A-Za-z0-9@＠$#＃￾﻿￿]|[{_DIR}]|^)(?P<url>(?P<proto>https?://)?"
                 rf"(?P<domain>(?:(?:{_DC}(?:[_-]|{_DC})*)?{_DC}\.)*(?:(?:{_DC}(?:-|{_DC})*)?{_DC}\.)"
                 rf"(?(proto)[a-z]{{2,63}}|(?:{_KNOWN})){_END})"
                 rf"(?::[0-9]+)?(?P<path>/{_PATH}*)?(?:\?[a-z0-9!?*'@();:&=+$/%#\[\]\-_.,~|]*[a-z0-9\-_&=#/])?)", re.I)
ASCII_DOMAIN = re.compile(rf"(?:[\-a-z0-9{_LAT}]+\.)+(?:{_KNOWN}){_END}", re.I)
# where a domain can lie (domain characters, dots, - and _), and a known TLD ending one there: a stretch with no such TLD
# holds no link but one written with http(s):// right before it, so the URL pattern, whose domain would scan the whole
# stretch from each place it starts (quadratic on a long run of dotted words), never looks at it
RUN = re.compile(rf"(?:{_DC}|[._-])+")
HIT = re.compile(rf"\.(?:{_KNOWN}){_END}", re.I)
PROTO = re.compile(r"https?://\Z", re.I)
EMOJI = re.compile("[\U0001F1E6-\U0001F1FF]{2}|[☀-➿\U0001F000-\U0001FAFF][️\U0001F3FB-\U0001F3FF]*"
                   "(?:‍[☀-➿\U0001F000-\U0001FAFF][️\U0001F3FB-\U0001F3FF]*)*")
ONE = ((0x0000, 0x10FF), (0x2000, 0x200D), (0x2010, 0x201F), (0x2032, 0x2037))


def x_valid(m):
    """twitter-text's isValidUrl: every label of the domain 1–63 characters in punycode (a longer one is no link at all,
    nor any part of it), an xn-- domain ASCII, the URL within 4096 characters with https:// in front"""
    d = m["domain"]
    if d[:4].lower() == "xn--" and not ASCII_DOMAIN.fullmatch(d): return False
    puny = [x if x.isascii() else "xn--" + x.encode("punycode").decode("ascii") for x in d.split(".")]
    if any(not 1 <= len(x) <= 63 for x in puny): return False
    return len(m["proto"] or "https://") + len(m["url"]) - len(d) + len(".".join(puny)) <= 4096


def x_links(s):
    """The spans X counts as links, 23 each: [(start, end)] in order. The URL pattern, run where a link can be: from just
    before each stretch a domain can lie in that has a known TLD in it or http(s):// in front, to the next space."""
    out, pos = [], 0
    if "." not in s: return out   # (twitter-text's own shortcut: no domain without a dot)
    for r in RUN.finditer(s):
        a, b = r.span()
        if b <= pos: continue                                   # inside the link before
        p = PROTO.search(s, max(0, a - 8), a)
        if not p and not HIT.search(s, a, b): continue
        at, sp = max(pos, (p.start() if p else a) - 1, 0), re.compile(r"\s").search(s, b)
        end = sp.start() if sp else len(s)
        while at < b:
            m = URL.search(s, at, end)
            if not m or m.start("url") >= b: break
            at = pos = max(m.end(), at + 1)
            if not x_valid(m): continue
            if m["proto"]: out.append(m.span("url")); continue
            if re.search(r"[-_./]$", m["pre"]): continue
            d0 = m.start("domain"); found = [[d0 + d.start(), d0 + d.end()] for d in ASCII_DOMAIN.finditer(m["domain"])]
            if found and m["path"]: found[-1][1] = m.end("url")
            out += [tuple(f) for f in found]
    return out


def x_length(s):
    s = unicodedata.normalize("NFC", s)
    spans = x_links(s); n = 23 * len(spans)
    for a, b in reversed(spans): s = s[:a] + s[b:]
    n += 2 * len(EMOJI.findall(s)); s = EMOJI.sub("", s)
    return n + sum(1 if any(a <= ord(c) <= b for a, b in ONE) else 2 for c in s)


# platforms that do not count one per character: (count, unit); every other platform counts len()
COUNTS = {"x": (x_length, "weighted characters, Chinese and emoji 2, a link 23")}


def platforms_of(name):
    """Every platform a heading names ("B站 / YouTube 双发" names two); a one-letter name (X) only standing alone."""
    n = name.strip().lower()
    has = lambda x: re.search(rf"(?<![a-z0-9]){re.escape(x)}(?![a-z0-9])", n) if len(x) == 1 else x in n
    return [key for key, (names, _) in LIMITS.items() if any(has(x) for x in names)]


def binding(keys, field, value):
    """The tightest limit on a field over the platforms named, each counting the value its own way (COUNTS; tags by the
    tag): (count, limit, how sure and whose, unit) for the one the value comes closest to or goes furthest over, or None."""
    best = None
    for k in keys:
        if field not in LIMITS[k][1]: continue
        cap, sure = LIMITS[k][1][field]
        count, unit = (lambda v: len(tags_of(v)), "tags") if field == "tags" else COUNTS.get(k, (len, "characters"))
        n = count(value)
        if best is None or n - cap > best[0] - best[1]: best = (n, cap, f"{sure}, {k}" if len(keys) > 1 else sure, unit)
    return best


def parse(text):
    """{heading: {field: value}} from the 发布文案 section."""
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    m = re.search(r"^## *发布文案[^\n]*\n(.*?)(?=^## |\Z)", text, flags=re.M | re.S)
    if not m:
        return {}
    out, cur, field = {}, None, None
    for line in m.group(1).split("\n"):
        h = re.match(r"^### *(.+?)\s*$", line)
        if h:
            cur, field = h.group(1), None; out[cur] = {}; continue
        if cur is None:
            continue
        f = re.match(r"^\s*[-*]?\s*(标题|简介|描述|标签|title|description|tags)\s*[：:]\s*(.*)$", line, flags=re.I)
        if f:
            field = FIELDS[f.group(1).lower()]
            out[cur][field] = f.group(2).strip(); continue
        if field == "desc":
            out[cur]["desc"] = (out[cur]["desc"] + "\n" + line) if out[cur].get("desc") else line
    for fields in out.values():
        if "desc" in fields:
            fields["desc"] = fields["desc"].strip("\n")
        for k in list(fields):
            if re.fullmatch(r"\{[^}]*\}", fields[k].strip()) or not fields[k].strip():
                del fields[k]   # a placeholder, or empty
    return out


def tags_of(s):
    return [t.strip() for t in re.split(r"[,，、]+|\s+(?=#)", s) if t.strip(" \t#")]


def ai_said(text):
    """{kind: count} from the numbers on PACKAGING.md's "AI 生成内容" line (图片 22 件，旁白 14 段), and that line."""
    m = re.search(r"^\s*[-*]?\s*AI 生成内容\s*[：:](.*)$", re.sub(r"<!--.*?-->", "", text, flags=re.S), flags=re.M)
    said = {}
    for word, n in re.findall(r"(图片|视频|声音|旁白|配音|配乐|音乐|音效|图)\s*(\d+)(?![0-9A-Za-z.])", m.group(1) if m else ""):
        said[AI_WORDS[word]] = said.get(AI_WORDS[word], 0) + int(n)
    return said


def ai_check(path, text):
    """A line when the numbers PACKAGING.md gives for the AI-generated content are not bin/vh assets credits' (all the
    records, or what the newest films used). None when they are, when it gives none, or when the ledger cannot say."""
    said = ai_said(text)
    if not said:
        return None
    sys.path.insert(0, str(Path(__file__).resolve().parent / "assets"))
    try:
        import assets as A, ledger, uses
        project = ledger.project_of(Path(path).resolve().parent)
        if project is None or not (project / ledger.LEDGER).is_file():
            return None
        everything = A.credits(project)["aigc"]["kinds"]
        used = uses.uses(project)
        counted = [everything, A.credits(project, used=used)["aigc"]["kinds"]] if used["films"] else [everything]
    except Exception:   # a reminder: a ledger that cannot be read is for bin/vh assets check to say
        return None
    if any(all(c.get(k, 0) == n for k, n in said.items()) for c in counted):
        return None
    return f"  ! AI 生成内容 in {Path(path).name} says {said}, bin/vh assets credits says {everything}: copy the numbers from it"


def main():
    args, jpath = list(sys.argv[1:]), None
    if "--json" in args:   # the fields measured, in a file: for bin/vh check's record
        i = args.index("--json"); jpath = args[i + 1] if i + 1 < len(args) else None; del args[i:i + 2]
    if len(args) != 1:
        sys.exit("usage: python3 tools/packcheck.py <PACKAGING.md | project> [--json f]")
    p = Path(args[0])
    if p.is_dir():
        p = p / "PACKAGING.md"
    if not p.is_file():
        print(f"packcheck: no {p}", file=sys.stderr); sys.exit(2)
    text = p.read_text(encoding="utf-8")
    got = parse(text)
    ai = ai_check(p, text)
    if ai:
        print(ai)
    over, rec, notes = 0, [], [ai.strip(" !")] if ai else []
    def record():
        if not jpath:
            return
        try: Path(jpath).write_text(json.dumps({"file": str(p), "fields": rec, "notes": notes}, ensure_ascii=False), encoding="utf-8")
        except OSError as e: print(f"packcheck: could not write {jpath} ({e.strerror or e})", file=sys.stderr)
    if not any(got.values()):
        print(f"packaging: {p.name} has no 发布文案 to measure (## 发布文案, a ### heading per platform: templates/PACKAGING.md)")
        if notes:
            record()
        sys.exit(0)
    for head, fields in got.items():
        if not fields:
            continue
        keys = platforms_of(head)
        parts = []
        for f in ("title", "desc", "tags"):
            if f not in fields:
                continue
            v = fields[f]
            lim = binding(keys, f, v)
            n, unit = (len(tags_of(v)), "tags") if f == "tags" else (len(v), "characters")
            if lim:
                n, cap, sure, unit = lim
                loose = sure.startswith("unverified")   # a number nobody could source: said, not held against the copy
                bad = n > cap and not loose
                over += bad
                parts.append(f"{'✗' if bad else '!' if n > cap else '✓'} {NAMES[f]} {n} {unit} (limit {cap}, {sure})")
                rec.append({"heading": head, "field": f, "count": n, "unit": unit, "limit": cap, "sure": sure, "over": bad})
            else:
                parts.append(f"· {NAMES[f]} {n} {unit}")
                rec.append({"heading": head, "field": f, "count": n, "unit": unit, "limit": None, "over": False})
        print(f"packaging · {head}: " + " · ".join(parts))
        spaced = [t.lstrip("#") for t in tags_of(fields.get("tags", "")) if re.search(r"\s", t.strip().lstrip("#"))] if TOPICS & set(keys) else []
        if spaced:
            notes.append(f"{head}: a topic stops at a space there: {', '.join(spaced)}: write it without one")
            print(f"  ! {notes[-1]}")
    if over:
        print("  over a limit: shorten it there, or move the long part (credits, sources) to a pinned comment; the upload page has the last word")
    record()
    sys.exit(1 if over else 0)


if __name__ == "__main__":
    main()
