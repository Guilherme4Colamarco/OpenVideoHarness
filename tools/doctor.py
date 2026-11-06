"""bin/vh doctor: what this machine can use, from the table of outside modules (tools/modules.json). Stdlib only.

usage: bin/vh doctor [--json] [--probe [--only a,b] [--offline DIR]]
  (bin/vh passes what its own finders found: --chrome, --hf-chrome, --hf-pin, --webgl)
  --json        the same as JSON (below), the lines a person reads not printed
  --probe       also call each service that has a key set, once, at an endpoint that costs nothing (Gemini's model
                list, MiniMax's system voices, ElevenLabs' user, Model Studio's model list): is the key taken, is the
                interface there; and each public one that takes no key (scout's: fxtwitter, Bilibili's view, the hot
                lists): does it still answer the way the adapter reads it. Without it doctor never touches the network
  --only a,b    probe only these modules (by name); the others are reported without a probe
  --offline DIR the probes answered from DIR/responses.json instead, recorded the way tools/assets/fetch.py records
                ({"v": 1, "responses": [{"url", "status", "headers", "body": <file in DIR>}]}): the tests use it
  python3 tools/doctor.py --check   the table against its rules (tools/ci.sh)

Per module: the program on PATH (or found by bin/vh), its version against the table's (min: this or newer; pin: this
one; max_age_days: a dated version no older than that), the parts it needs (libx264 in ffmpeg, a skill file), the
packages in uv's cache, a model in Hugging Face's, and for a service whether one of its keys is set: only whether,
never the value. A module whose needed modules (needs.programs) are not usable here is not ok either ("needs node
(outdated)"); one not made for this platform says what to use instead (elsewhere). A probe's key travels in a header
that no redirect carries on (a 30x is not followed), over https only (a base address set in the environment may be
http for this machine alone), and no answer's text is passed on: a failure is its HTTP status and the provider's error
code, with any run of six or more of the key's characters taken out. A key is never printed, recorded or written.
Exit 0: it is a report (2 on a usage error or an unreadable table).

--json, "version": 1 (these fields stay; new ones may be added): {"version", "tool", "platform", "modules": [{"name",
"kind", "status" ("planned" when nothing calls it yet, else "used"), "required", "state", "found", "version", "keys":
{VAR: true|false}, "note", "install", "probe": {"state", "note"} | null}], "checks": [{"name", "state", "note"}],
"first_run": [what the first runs still download], "counts": {state: n}}. state: ok · missing · outdated (under the
minimum, not the pin, or older than max_age_days) · incomplete (found, a part it needs is not) · no_key · unsupported
(not on this platform) · per_project · unchecked. A probe: ok · failed · skipped.
"""
import datetime, glob, http.client, json, os, platform, re, shutil, subprocess, sys, time
import urllib.error, urllib.parse, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TABLE = ROOT / "tools" / "modules.json"
COMMANDS = ROOT / "tools" / "commands.json"
UA = "OpenVideoHarness (+https://github.com/ZLHad/OpenVideoHarness)"   # tools/assets/fetch.py's
LOCAL = ("localhost", "127.0.0.1", "::1")   # the hosts a key may reach over plain http (a local stand-in, the tests)
KINDS = ("program", "npm", "python", "model", "service", "agent")
STATES = ("ok", "missing", "outdated", "incomplete", "no_key", "unsupported", "per_project", "unchecked")
OK, NO, WA = "\033[32m✓\033[0m", "\033[31m✗\033[0m", "\033[33m!\033[0m"


def run(argv, timeout=20):
    """(exit status, stdout + stderr) of a command; (None, why) when it cannot run."""
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, errors="replace")
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except (OSError, subprocess.SubprocessError) as e:
        return None, str(e)


def vtuple(v):
    return tuple(int(x) for x in re.findall(r"\d+", v or ""))


def home(p):
    return Path(os.path.expanduser(p))


def shown(p):
    """A path as doctor prints it: in the harness relative, under home with ~."""
    p = str(p)
    if p.startswith(str(ROOT) + os.sep):
        return p[len(str(ROOT)) + 1:]
    h = str(Path.home())
    return "~" + p[len(h):] if p == h or p.startswith(h + os.sep) else p


def bytes_of(p):
    """A folder's size on disk in bytes, links followed (a Hugging Face snapshot is all links)."""
    n = 0
    for d, _, fs in os.walk(p, followlinks=True):
        for f in fs:
            try:
                n += os.stat(os.path.join(d, f)).st_blocks * 512
            except OSError:
                pass
    return n


def mb_text(n):
    mb = n / 1e6
    return f"{mb / 1000:.1f} GB" if mb >= 1000 else f"{mb:.0f} MB"


def size_of(p):
    """A folder's size on disk, links followed: "202 MB", "2.0 GB"."""
    return mb_text(bytes_of(p))


def install_says():
    """What install.sh tells someone the reference repos come to ("250 MB"), or None: the figure doctor gives when none
    is fetched, so it is written in one place."""
    try:
        m = re.search(r"reference repos \(about (\d+(?:\.\d+)? [MG]B)", (ROOT / "install.sh").read_text(encoding="utf-8"))
    except OSError:
        return None
    return m.group(1) if m else None


def references_note(have, want, fetched, said):
    """doctor's line for references/repos when some are not fetched: the whole set's size worked out from the ones that
    are (fetched: their bytes), else what install.sh says (said), else none."""
    size = f"about {mb_text(fetched * want / have)}, at the size of the {have} here" if have and fetched else f"about {said}" if said else None
    return f"{have}/{want} repos fetched → bash references/fetch.sh (all {want}{': ' + size if size else ''}; agents read them for the case studies)"


def this_platform():
    m = platform.machine().lower()
    return f"{sys.platform}-{'arm64' if m in ('arm64', 'aarch64') else m}"


def platform_ok(want):
    return not want or this_platform() == want or this_platform().startswith(want + "-")


def uv_has(pkgs):
    """Whether uv can run these packages from its cache, offline (what bin/vh's uv run would use)."""
    if not shutil.which("uv"):
        return None
    argv = ["uv", "run", "-q", "--no-project", "--offline"] + [x for p in pkgs for x in ("--with", p)] + ["python", "-c", ""]
    rc, _ = run(argv, timeout=120)
    return rc == 0


def hf_snapshot(model):
    """The Hugging Face snapshot folder of a model with weights in it, or None."""
    hub = os.environ.get("HF_HUB_CACHE") or os.path.join(os.environ.get("HF_HOME") or str(home("~/.cache/huggingface")), "hub")
    for snap in sorted(glob.glob(os.path.join(hub, "models--" + model.replace("/", "--"), "snapshots", "*", ""))):
        if glob.glob(os.path.join(snap, "*.safetensors")):
            return snap
    return None


def check_module(m, found_by, today):
    """One module on this machine: {state, found, version, keys, note}."""
    ck, ver, needs = m.get("check") or {}, m.get("version") or {}, m.get("needs") or {}
    r = {"state": "ok", "found": None, "version": None, "keys": {}, "note": ""}
    notes = []
    if not platform_ok(needs.get("platform")):
        r.update(state="unsupported", note=f"for {needs['platform']} only; this is {this_platform()}" + (f": {m['elsewhere']}" if m.get("elsewhere") else ""))
        return r
    for k in needs.get("keys", []):
        r["keys"][k] = bool(os.environ.get(k))
    if ck.get("per_project"):
        r.update(state="per_project", note=f"each project has its own: {ck['per_project']}")
        return r
    if ck.get("program"):
        # as the tool that runs it looks: its environment variable, PATH, then the places it installs to (check's env, paths)
        at = os.environ.get(ck["env"]) if ck.get("env") else None
        path = at or shutil.which(ck["program"])
        if not path:
            at = path = next((p for p in map(os.path.expanduser, ck.get("paths", [])) if os.access(p, os.X_OK)), None)
        if not path:
            r.update(state="missing", note=f"{ck['program']} not found")
            return r
        r["found"] = path
        if ck.get("version"):
            _, out = run([path] + ck["version"][1:] if at else ck["version"])
            mm = re.search(ck.get("pattern", r"(\d+(?:\.\d+)+)"), out or "")
            r["version"] = mm.group(1) if mm else None
        for other in ck.get("also", []):
            if not shutil.which(other) and not (at and os.path.exists(os.path.join(os.path.dirname(path), other))):
                r["state"] = "incomplete"; notes.append(f"no {other} beside it")
        for f in ck.get("features", []):
            _, out = run(f["argv"])
            if f["contains"] not in (out or ""):
                r["state"] = "incomplete"; notes.append(f["missing"])
    elif ck.get("finder"):
        p = found_by.get(ck["finder"]) or ""
        if not p:
            r.update(state="missing", note="not found")
            return r
        r["found"] = p
        if ck["finder"] == "hf-chrome":
            mm = re.search(r"-(\d+(?:\.\d+)+)$", p.rstrip("/"))
            r["version"] = mm.group(1) if mm else None
            pin = found_by.get("hf-pin")
            if pin and r["version"] and r["version"] != pin:
                r["state"] = "outdated"; notes.append(f"not {pin}, the version the HyperFrames installed here pins")
            elif pin and r["version"] == pin:
                notes.append("the version HyperFrames pins")
            if os.path.isdir(p):
                notes += [size_of(p), shown(os.path.dirname(p.rstrip("/")))]
    elif ck.get("npm"):
        pj = ROOT / ck["npm"]["in"] / "node_modules" / ck["npm"]["package"] / "package.json"
        try:
            r["version"] = json.loads(pj.read_text(encoding="utf-8")).get("version")
            r["found"] = str(pj.parent)
        except (OSError, ValueError):
            r.update(state="missing", note=f"not installed in {ck['npm']['in']}")
            return r
    if ck.get("hf_model"):
        model = os.environ.get(ck["hf_model"].get("env", ""), "") or ck["hf_model"]["default"]
        snap = hf_snapshot(model)
        if snap:
            r["found"] = r["found"] or snap
            notes.append(f"{model} · {size_of(snap)}")
        else:
            r["state"] = "missing"; notes.append(f"{model} not downloaded yet")
    if ck.get("uv"):
        has = uv_has(ck["uv"])
        if has is None:
            r["state"] = "missing"; notes.append("needs uv")
        elif has:
            notes.append(f"{', '.join(ck['uv'])} in the uv cache")
        else:
            r["state"] = "missing"; notes.append(f"{', '.join(ck['uv'])} not in the uv cache yet")
    for f in ck.get("files", []):
        if not home(f).exists():
            r["state"] = "incomplete" if r["state"] == "ok" else r["state"]; notes.append(f"no {f}")
    # the version against the table's
    v = r["version"]
    if v and ver.get("min") and vtuple(v) < vtuple(ver["min"]):
        r["state"] = "outdated"; notes.append(f"{ver['min']} or newer needed")
    if v and ver.get("pin") and (ck.get("npm") or ck.get("program")) and v != ver["pin"].split()[0]:
        r["state"] = "outdated"; notes.append(f"not {ver['pin'].split()[0]}, the pinned version")
    if v and ver.get("max_age_days"):
        mm = re.fullmatch(r"(\d{4})\.(\d{1,2})\.(\d{1,2})(?:\.\d+)?", v)
        if mm:
            age = (today - datetime.date(*map(int, mm.groups()))).days
            if age > ver["max_age_days"]:
                r["state"] = "outdated"; notes.append(f"{age} days old (over {ver['max_age_days']})")
    if needs.get("keys") and not any(r["keys"].values()) and r["state"] == "ok":
        r["state"] = "no_key"; notes.append("no " + " or ".join(needs["keys"]))
    if r["state"] == "ok" and not (ck or needs.get("keys")):
        r["state"] = "unchecked"
    r["note"] = " · ".join(notes)
    return r


class _Stay(urllib.request.HTTPRedirectHandler):
    """Follows no redirect: the 30x is the answer, so a key sent to one host never goes on to another."""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def scrub(text, key):
    """The text with every run of 6 or more of the key's characters taken out: a server may echo a key whole, or a
    masked one with a few characters at each end."""
    s = str(text)
    if not key:
        return s
    if len(key) < 6:
        return s.replace(key, "…")
    for n in range(len(key), 5, -1):
        for i in range(len(key) - n + 1):
            if key[i:i + n] in s:
                s = s.replace(key[i:i + n], "…")
    return s


def error_code(js):
    """A provider's error code from its answer (error.status, error.code, detail.code …), never its message: a message
    can echo the key."""
    for k in ("error", "detail"):
        e = js.get(k) if isinstance(js, dict) else None
        if isinstance(e, dict):
            for f in ("status", "code", "type"):
                v = e.get(f)
                if isinstance(v, str) and re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]{1,40}", v):
                    return v
    return None


def apply_needs(modules, results):
    """A module whose needed modules (needs.programs) are not usable here is not ok either: "needs node (outdated)" at the
    end of its note, until nothing changes (a need can be a need's)."""
    by = {m["name"]: r for m, r in zip(modules, results)}
    usable = lambda r: r["state"] in ("ok", "per_project", "unchecked")
    changed = True
    while changed:
        changed = False
        for m, r in zip(modules, results):
            if r["state"] == "unsupported":
                continue
            for n in (m.get("needs") or {}).get("programs", []):
                dep = by.get(n)
                if dep is None or usable(dep) or f"needs {n} (" in r["note"]:
                    continue
                r["note"] = " · ".join(x for x in (r["note"], f"needs {n} ({dep['state'].replace('_', ' ')})") if x)
                if r["state"] == "ok":
                    r["state"], changed = "incomplete", True
    return results


def probe(m, offline, recs):
    """Call a service once at its free endpoint, with the first of its keys that is set (a public one that takes no key:
    without one). {state, note}. The key goes in a header that no redirect carries on, only over https (or to this
    machine), and no answer's text is passed on."""
    p = m.get("probe")
    if not p:
        return None
    keyless = not (m.get("needs") or {}).get("keys") and not p.get("auth")
    var = None if keyless else next((k for k in (m.get("needs") or {}).get("keys", []) if os.environ.get(k)), None)
    if not var and not keyless:
        return {"state": "skipped", "note": "no key set"}
    key, url = (os.environ[var] if var else ""), p["url"]
    if p.get("base_env") and os.environ.get(p["base_env"]):
        b = urllib.parse.urlsplit(os.environ[p["base_env"]])
        if not b.hostname or not (b.scheme == "https" or (b.scheme == "http" and b.hostname in LOCAL)):
            return {"state": "failed", "note": f"{p['base_env']} is not an https address (only this machine may be http): not called, the key would leave in the clear"}
        u = urllib.parse.urlsplit(url)
        url = urllib.parse.urlunsplit((b.scheme, b.netloc.rpartition("@")[2], u.path, u.query, ""))
    host = urllib.parse.urlsplit(url).netloc
    body = json.dumps(p["body"]).encode() if "body" in p else None
    try:
        if offline:
            rec = next((x for x in recs if x.get("url") == url), None)
            if rec is None:
                return {"state": "failed", "note": f"no recorded response for {url} in {offline}"}
            status, hdrs = rec.get("status", 200), {str(k).lower(): v for k, v in (rec.get("headers") or {}).items()}
            data = (Path(offline) / rec["body"]).read_bytes() if rec.get("body") else b""
        else:
            req = urllib.request.Request(url, data=body, method=p.get("method", "GET"), headers={"User-Agent": UA})
            if body is not None:
                req.add_header("Content-Type", "application/json")
            if var:
                req.add_unredirected_header(p["auth"]["header"], p["auth"].get("prefix", "") + key)
            try:
                with urllib.request.build_opener(_Stay).open(req, timeout=20) as resp:
                    status, hdrs, data = resp.status, {k.lower(): v for k, v in resp.headers.items()}, resp.read(4 << 20)
            except urllib.error.HTTPError as e:
                status, hdrs, data = e.code, {k.lower(): v for k, v in (e.headers or {}).items()}, e.read(64 << 10)
    except (OSError, ValueError, http.client.HTTPException) as e:
        return {"state": "failed", "note": scrub(f"{host}: {getattr(e, 'reason', e)}", key)}
    if 300 <= status < 400:
        to = urllib.parse.urlsplit(urllib.parse.urljoin(url, hdrs.get("location", ""))).netloc or "nowhere it says"
        return {"state": "failed", "note": scrub(f"HTTP {status}: {host} sends it on to {to}, not followed (the key went nowhere else)", key)}
    try:
        js = json.loads(data.decode("utf-8")) if data else {}
    except (UnicodeDecodeError, ValueError):
        js = None
    if status >= 400:
        code = error_code(js)
        return {"state": "failed", "note": scrub(f"HTTP {status}" + (f" with {var}" if var else "") + (f" ({code})" if code else ""), key)}
    exp, said = p.get("expect") or {}, [f"{var} taken" if var else f"answers (HTTP {status}, no key)"]
    if exp.get("text"):   # an answer that is not JSON (an RSS feed): the text it must hold
        if exp["text"] not in data.decode("utf-8", errors="replace"):
            return {"state": "failed", "note": f"HTTP {status}, but not the answer the adapter reads (no {exp['text']!r} in it)"}
        return {"state": "ok", "note": ", ".join(said)}
    if not isinstance(js, dict):
        return {"state": "failed", "note": f"HTTP {status}, but not the JSON it answers with"}
    if exp.get("path"):
        v = js
        for part in exp["path"].split("."):
            v = v.get(part) if isinstance(v, dict) else None
        if v in (None, "", [], {}):
            return {"state": "failed", "note": f"HTTP {status}, but no {exp['path']} in the answer (the adapter reads it)"}
    if exp.get("status_code"):
        code = js
        for part in exp["status_code"].split("."):
            code = code.get(part) if isinstance(code, dict) else None
        if code != 0:
            hint = (exp.get("hints") or {}).get(str(code))
            return {"state": "failed", "note": scrub(f"{var or host} refused: status_code {code}" + (f" ({hint})" if hint else ""), key)}
    if exp.get("list"):
        items = js.get(exp["list"])
        if not isinstance(items, list):
            return {"state": "failed", "note": f"HTTP {status}, but no {exp['list']} list in the answer"}
        said.append(f"{len(items)} {exp['list']}")
        if exp.get("names"):
            have = {str(x.get("name", "")).split("/")[-1] for x in items if isinstance(x, dict)}
            gone = [n for n in exp["names"] if n not in have]
            if gone:
                return {"state": "failed", "note": (f"{var} taken" if var else f"{host} answers") + f", but the models bin/vh uses are not listed: {', '.join(gone)}"}
            said.append(f"the {len(exp['names'])} models bin/vh uses among them")
    return {"state": "ok", "note": ", ".join(said)}


def repo_checks(webgl, found_by):
    """A browser for the page tools, WebGL, the reference repos, LOCAL.md and AGENTS.md: [{name, state, note}]."""
    out = []
    if found_by.get("hf-chrome") or found_by.get("chrome"):
        out.append({"name": "browser", "state": "ok", "note": "the page tools draw with " + ("chrome-headless-shell" if found_by.get("hf-chrome") else "Chrome")})
    else:
        out.append({"name": "browser", "state": "missing", "note": "neither Chrome nor chrome-headless-shell: frames, render, textcheck and the other page tools need one (set CHROME_PATH, or see chrome above)"})
    kind, _, renderer = (webgl or "skipped|").partition("|")
    if kind in ("GPU", "software"):
        out.append({"name": "webgl", "state": "ok", "note": f"{kind}: {renderer}"})
    elif kind == "soft-gl":
        out.append({"name": "webgl", "state": "incomplete", "note": f"no WebGL with the GPU flags, only with --soft-gl ({renderer}): render with node render.mjs --soft-gl"})
    elif kind == "none":
        out.append({"name": "webgl", "state": "missing", "note": "no WebGL with the GPU flags nor with --soft-gl: WebGL scenes will not render on this machine"})
    else:
        out.append({"name": "webgl", "state": "unchecked", "note": "the probe needs Chrome and the ClaudeAnimationBase deps (bin/vh setup)"})
    try:
        want = len(re.findall(r"^(?:full|sparse|textonly)\s", (ROOT / "references" / "fetch.sh").read_text(encoding="utf-8"), re.M))
    except OSError:
        want = 0
    have = sum(1 for d in glob.glob(str(ROOT / "references" / "repos" / "*" / "")) if os.path.isdir(os.path.join(d, ".git")))
    if have >= want:
        out.append({"name": "references", "state": "ok", "note": f"{have}/{want} repos fetched, {size_of(ROOT / 'references' / 'repos')}"})
    else:
        out.append({"name": "references", "state": "missing", "note": references_note(have, want, bytes_of(ROOT / "references" / "repos") if have else 0, install_says())})
    local = ROOT / "LOCAL.md"
    if not local.exists():
        out.append({"name": "local_md", "state": "missing", "note": "no LOCAL.md → cp LOCAL.example.md LOCAL.md and fill it in"})
    else:
        ph = sum(1 for line in local.read_text(encoding="utf-8").splitlines() if re.search(r"\{[^}]*\}", line))
        out.append({"name": "local_md", "state": "incomplete" if ph else "ok",
                    "note": f"{ph} template line(s) with {{…}} placeholders → fill them in (this output goes on the 已装工具 line)" if ph else "filled in"})
    try:
        same = (ROOT / "AGENTS.md").read_text(encoding="utf-8").split("\n", 3)[3].rstrip("\n") == (ROOT / "CLAUDE.md").read_text(encoding="utf-8").rstrip("\n")
    except (OSError, IndexError):
        same = False
    out.append({"name": "agents_md", "state": "ok" if same else "incomplete", "note": "in sync with CLAUDE.md" if same else "out of sync with CLAUDE.md → bin/vh sync-agents"})
    return out


def problems(t, commands=None):
    """What breaks the table's rules, a line each."""
    bad, names = [], []
    if t.get("version") != 1:
        bad.append('"version" is not 1')
    known = None
    table_names = {m.get("name") for m in t.get("modules") or []}
    if commands is not None:
        known = {c.get("name") for c in commands.get("commands", [])}
    for m in t.get("modules") or []:
        n = m.get("name")
        at = f"module {n!r}"
        if not isinstance(n, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", n):
            bad.append(f"{at}: the name is not lower-case letters, digits and -"); continue
        names.append(n)
        extra = set(m) - {"name", "kind", "status", "purpose", "version", "license", "needs", "adapter", "commands", "required", "check",
                          "probe", "first_run", "install", "elsewhere"}
        if extra:
            bad.append(f"{at}: fields doctor does not know: {sorted(extra)}")
        if m.get("kind") not in KINDS:
            bad.append(f"{at}: kind {m.get('kind')!r} is not one of {', '.join(KINDS)}")
        if m.get("status") not in (None, "planned"):
            bad.append(f"{at}: status is only ever \"planned\"")
        for k in ("purpose", "license"):
            if not isinstance(m.get(k), str) or not m[k].strip():
                bad.append(f"{at}: no {k}")
        if not isinstance(m.get("required"), bool):
            bad.append(f"{at}: required is not true or false")
        ver = m.get("version")
        if not isinstance(ver, dict) or set(ver) - {"pin", "min", "range", "tested", "models", "max_age_days"}:
            bad.append(f"{at}: version is not an object of pin, min, range, tested, models, max_age_days")
        needs = m.get("needs")
        if not isinstance(needs, dict) or set(needs) - {"keys", "programs", "account", "platform"}:
            bad.append(f"{at}: needs is not an object of keys, programs, account, platform")
        else:
            for k in needs.get("keys", []):
                if not re.fullmatch(r"[A-Z][A-Z0-9_]*", k):
                    bad.append(f"{at}: {k!r} is not the name of an environment variable")
            for n in needs.get("programs", []):
                if n not in table_names or n == m.get("name"):
                    bad.append(f"{at}: needs.programs names {n!r}, which is not another module of this table")
            if m.get("elsewhere") and not needs.get("platform"):
                bad.append(f"{at}: elsewhere is what to use where needs.platform does not hold, and it has none")
        adapter = m.get("adapter")
        if not isinstance(adapter, list) or (not adapter and m.get("status") != "planned"):
            bad.append(f"{at}: no adapter (where the repo talks to it)")
        for a in adapter or []:
            path = a.split(" (")[0].split(" ")[0]
            if not glob.glob(str(ROOT / path)):
                bad.append(f"{at}: adapter {path!r} is not in the repo")
        cmds = m.get("commands")
        if not isinstance(cmds, list):
            bad.append(f"{at}: commands is not a list")
        elif known is not None and set(cmds) - known:
            bad.append(f"{at}: commands bin/vh does not have: {sorted(set(cmds) - known)}")
        if m.get("status") == "planned" and cmds:
            bad.append(f"{at}: planned, yet commands use it")
        ck = m.get("check")
        if not isinstance(ck, dict) or set(ck) - {"program", "env", "paths", "version", "pattern", "also", "features", "finder", "npm", "uv", "hf_model", "files", "per_project"}:
            bad.append(f"{at}: check has a key doctor does not know")
        elif ck.get("finder") not in (None, "chrome", "hf-chrome"):
            bad.append(f"{at}: finder {ck['finder']!r} is not one bin/vh passes (chrome, hf-chrome)")
        p = m.get("probe")
        if p is not None:
            if m.get("kind") != "service":
                bad.append(f"{at}: a probe is for a service")
            elif bool((needs or {}).get("keys")) != bool(p.get("auth")):
                bad.append(f"{at}: a probe sends a key (auth) exactly when the service needs one (needs.keys)")
            if not str(p.get("url", "")).startswith("https://") or re.search(r"[?&][^=]*(key|token|secret)", p.get("url", ""), re.I):
                bad.append(f"{at}: a probe's url is https and carries no key")
            if p.get("method", "GET") not in ("GET", "POST") or ("auth" in p and (not isinstance(p["auth"], dict) or not p["auth"].get("header"))):
                bad.append(f"{at}: a probe needs GET or POST, and its auth an auth.header (the key goes in a header)")
            if set(p.get("expect") or {}) - {"list", "names", "status_code", "hints", "path", "text"}:
                bad.append(f"{at}: a probe's expect has a key doctor does not know")
    if len(set(names)) != len(names):
        bad.append(f"names repeat: {sorted(n for n in set(names) if names.count(n) > 1)}")
    return bad


def print_module(m, r):
    """A module's line (and its probe's): ✓ usable, ✗ a required one that is not, ! an optional one that is not, - n/a."""
    bad = r["state"] in ("missing", "outdated", "incomplete")
    mark = OK if r["state"] == "ok" else NO if bad and m["required"] else WA if bad else "-"
    ck = m.get("check") or {}
    where = shown(r["found"]) if r["found"] and not r["version"] and (ck.get("program") or ck.get("finder") == "chrome") else ""
    keys = [k for k, on in r["keys"].items() if on]
    detail = " · ".join(x for x in (", ".join(keys) + " set" if keys else "", r["version"], where, r["note"]) if x)
    if r["state"] == "no_key" and m["commands"]:
        detail += f" (for bin/vh {', '.join(m['commands'])})"
    hint = f" → {r['install']}" if bad and r["install"] else ""
    print(f"{mark} {m['name']}  {detail}{hint}")
    if r["probe"] and r["probe"]["state"] != "skipped":   # skipped: no key, said on the line above
        print(f"   {OK if r['probe']['state'] == 'ok' else NO} live: {r['probe']['note']}")


def main(argv):
    a = {"json": False, "probe": False, "offline": None, "only": None, "chrome": "", "hf-chrome": "", "hf-pin": "", "webgl": ""}
    i = 0
    while i < len(argv):
        x = argv[i]
        if x in ("-h", "--help"):
            print(__doc__.strip()); return 0
        if x == "--check":
            t = json.loads(TABLE.read_text(encoding="utf-8"))
            bad = problems(t, json.loads(COMMANDS.read_text(encoding="utf-8")) if COMMANDS.exists() else None)
            for b in bad:
                print(f"tools/modules.json: {b}", file=sys.stderr)
            if not bad:
                print(f"tools/modules.json: {len(t['modules'])} modules")
            return 1 if bad else 0
        k, eq, v = x[2:].partition("=")
        if x in ("--json", "--probe"):
            a[x[2:]] = True
        elif k in ("offline", "only", "chrome", "hf-chrome", "hf-pin", "webgl") and x.startswith("--"):
            if not eq:
                if i + 1 >= len(argv):
                    print(f"bin/vh doctor: --{k} needs a value", file=sys.stderr); return 2
                i += 1; v = argv[i]
            a[k] = v
        else:
            print(f"bin/vh doctor: unknown option {x} (usage: bin/vh doctor [--json] [--probe [--only a,b] [--offline DIR]], or bin/vh doctor <project>)", file=sys.stderr)
            return 2
        i += 1
    if (a["offline"] or a["only"] is not None) and not a["probe"]:
        print(f"bin/vh doctor: --{'offline answers' if a['offline'] else 'only picks'} the probes: give --probe too", file=sys.stderr); return 2
    try:
        t = json.loads(TABLE.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        print(f"bin/vh doctor: cannot read {shown(TABLE)}: {e}", file=sys.stderr); return 2
    only = None if a["only"] is None else {n.strip() for n in a["only"].split(",") if n.strip()}
    if only is not None and (not only or only - {m.get("name") for m in t["modules"]}):
        print(f"bin/vh doctor: --only names no module of the table: {', '.join(sorted(only - {m.get('name') for m in t['modules']})) or '(none given)'}", file=sys.stderr)
        return 2
    recs = []
    if a["offline"]:
        try:
            recs = json.loads((Path(a["offline"]) / "responses.json").read_text(encoding="utf-8"))["responses"]
        except (OSError, ValueError, KeyError, TypeError) as e:
            print(f"bin/vh doctor: no recorded responses in {a['offline']} ({e})", file=sys.stderr); return 2
    today = datetime.date.today()
    found_by = {"chrome": a["chrome"], "hf-chrome": a["hf-chrome"], "hf-pin": a["hf-pin"]}
    mods = apply_needs(t["modules"], [check_module(m, found_by, today) for m in t["modules"]])
    for i, (m, r) in enumerate(zip(t["modules"], mods)):
        pr = probe(m, a["offline"], recs) if a["probe"] and (only is None or m["name"] in only) else None
        mods[i] = {"name": m["name"], "kind": m["kind"], "status": m.get("status", "used"), "required": m["required"], **r,
                   "install": (m.get("install") or {}).get("macos" if sys.platform == "darwin" else "linux"), "probe": pr}
    checks = repo_checks(a["webgl"], found_by)
    first = [m.get("first_run") for m, r in zip(t["modules"], mods) if m.get("first_run") and r["state"] == "missing"]
    counts = {}
    for x in mods + checks:
        counts[x["state"]] = counts.get(x["state"], 0) + 1
    if a["json"]:
        print(json.dumps({"version": 1, "tool": "bin/vh doctor", "t": round(time.time(), 3), "platform": this_platform(),
                          "modules": mods, "checks": checks, "first_run": first, "counts": counts}, ensure_ascii=False, indent=1))
        return 0
    sections = [("programs", lambda m: m["kind"] == "program"), ("packages and models", lambda m: m["kind"] in ("npm", "python", "model")),
                ("services (whether a key is set, never its value)", lambda m: m["kind"] == "service"), ("agents", lambda m: m["kind"] == "agent")]
    used = [(m, r) for m, r in zip(t["modules"], mods) if r["status"] != "planned"]
    for title, has in sections:
        print(title)
        for m, r in used:
            if has(m):
                print_module(m, r)
    print("machine and repo")
    for c in checks:
        mark = OK if c["state"] == "ok" else "-" if c["state"] == "unchecked" else NO if c["name"] == "browser" else WA
        print(f"{mark} {c['name'].replace('_', '.').replace('local.md', 'LOCAL.md').replace('agents.md', 'AGENTS.md')}  {c['note']}")
    planned = [(m, r) for m, r in zip(t["modules"], mods) if r["status"] == "planned"]
    if planned:
        print("planned (nothing in bin/vh calls these yet)")
        for m, r in planned:
            print_module(m, r)
    print("- every bin/vh new short|promo|data|meme installs its own pinned HyperFrames into the project (about 140 MB of node_modules)")
    if first:
        print(f"   still to come on first use: {', '.join(first)} (wiki: Getting Started; mirrors behind a slow or blocked network: wiki China-Network / 国内网络)")
    if not a["probe"]:
        print("   bin/vh doctor --probe: also call each service with a key once, at an endpoint that costs nothing")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
