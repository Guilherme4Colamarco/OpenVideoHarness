"""bin/vh check's record: what each of its checks found, one finding at a time, as JSON (bin/vh check --json prints it).

usage (bin/vh check runs it last): python3 tools/checkrec.py <video> --dir <the checks' JSON pieces> --exit <status>
                                   [--allow s] [--against f] [--print] [--remedies]
The record is saved in the video's project, out/check/<name>.check.json: <name> is the video's file name without its
extension, after the folders between out/ and it ("out/review/sketch.mp4" → review-sketch); a video outside a project gets
no record. --print writes it to stdout too. It never changes what bin/vh check decided: --exit is its status.
--remedies: the ways out of what was found (tools/remedies.json: a recipe filter, a command or a doc for each kind) on
stdout, after the checks' own lines (on stderr with --print, whose stdout is the record); each finding in the record carries
them as "remedies" whether or not it is given.

{"version": 1, "tool": "bin/vh check", "video", "project", "record", "t", "at", "size", "mtime_ns", "args": {"allow", "against"},
 "exit", "verdict": "pass" | "fail", "counts": {"fail", "warn", "info"}, "probe": {"duration", "size", "streams"},
 "motion": {"moving", "still_share", "cuts"} | null, "findings": [...], "skipped": [{"check", "why"}]}
size, mtime_ns  the video file's bytes and modification time (nanoseconds) when the checks began, from os.stat (film.txt, below):
                a reader tells whether the file is still the one that was checked by comparing them with the file now
                (film_changed; bin/vh status and versions do), which the time of the record alone cannot (a film put back
                with an old modification time: cp -p, rsync -a, bin/vh versions use; one put in its place while the checks
                ran). Nothing is hashed. null when the file cannot be read
A finding: {"kind", "severity", "message", "t", "t1", "frame", "frames", "evidence", "confirmed", "remedies"?}.
  kind      check.spec, check.gate, check.black, check.freeze, check.silence, check.iso (an isolated frame), check.periodic,
            check.static, check.cut (a hard cut from dark to bright), check.fade (a fade still under way at the last frame),
            check.blind (frames that move too much to judge),
            check.subtitles, check.colour, check.loudness (the film's sound against what it was mixed to), check.packaging,
            check.scale, check.confirmed (an entry of confirmed.json unused, lapsed or not taken), check.slate (an edit
            list's entry with no source yet, left in the film), check.edit (an image the film was drawn from that changed
            since). The names are confirmed.json's ("tool": "check.iso")
  severity  fail (it makes bin/vh check exit 1), warn (to look at), info (said, nothing to do)
  t, t1     the time, or the span, in seconds (null when it has none); frame / frames: the frame, or [first, last]
  evidence  what the finding rests on: the measured numbers, the BRIEF's line, the key, the entry that confirms it …
  confirmed true when confirmed.json covers it, false when it could (check.iso) and does not, null for the kinds that are
            never confirmed there. An open check.iso carries "confirm": the entry to paste once why and evidence are filled
  remedies  for a kind tools/remedies.json has: [{"say", "run" | "doc"}], what can answer it (options, not verdicts)
  entry     an edit list's film (engines/EDIT.md): the entry a finding with a time falls in, {"id", "kind", "src"}
The pieces in --dir, each optional (a check that did not run is "skipped" or simply absent): spec.json (speccheck.py),
gate.json (gatecheck.py), detect.txt (ffmpeg's black/freeze/silence lines), iso.json (isoframes.py), subs.json
(subcheck.py), colour.txt (ffprobe's csv), film.txt ("<size> <mtime_ns>" of the video when the checks began; without it, the
video as it is when the record is made), pack.json (packcheck.py), scale.json (scalecheck.py), edit.json (tools/edit.py _film:
an edit list's film, its entries, slates and changed images), skipped.txt (lines of "<check>\t<why>"), errors.txt (lines of
"<kind>\t<severity>\t<message>": a failure with no result of its own).
"""
import argparse, json, os, re, subprocess, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))


def load(d, name):
    try:
        return json.loads((Path(d) / name).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def text(d, name):
    try:
        return (Path(d) / name).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None


def finding(kind, severity, message, t=None, t1=None, frame=None, frames=None, evidence=None, confirmed=None, **extra):
    f = {"kind": kind, "severity": severity, "message": message, "t": t, "t1": t1, "frame": frame, "frames": frames,
         "evidence": evidence or {}, "confirmed": confirmed}
    f.update(extra)
    return f


def probe(video):
    try:
        r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration,size:stream=codec_type,codec_name,width,height,"
                            "r_frame_rate,pix_fmt,channels,sample_rate", "-of", "json", str(video)], capture_output=True, text=True, timeout=60)
        j = json.loads(r.stdout or "{}")
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {}
    fmt = j.get("format") or {}
    num = lambda x: float(x) if x not in (None, "N/A") else None   # noqa: E731
    out = {"duration": num(fmt.get("duration")), "size": int(fmt["size"]) if str(fmt.get("size", "")).isdigit() else None, "streams": []}
    for s in j.get("streams") or []:
        st = {"type": s.get("codec_type"), "codec": s.get("codec_name")}
        for k in ("width", "height", "pix_fmt", "channels"):
            if s.get(k) is not None:
                st[k] = s[k]
        if s.get("codec_type") == "video" and s.get("r_frame_rate"):
            st["fps"] = s["r_frame_rate"]
        if s.get("sample_rate"):
            st["sample_rate"] = int(s["sample_rate"])
        out["streams"].append(st)
    return out


def spec_findings(sp):
    out = []
    ev = {"measured": sp.get("measured"), "brief": {"file": sp.get("brief"), "output": sp.get("output"), "resolution": sp.get("resolution")}}
    for m in sp.get("fails") or []:
        out.append(finding("check.spec", "fail", m, evidence=ev))
    for m in sp.get("warns") or []:
        out.append(finding("check.spec", "warn", m, evidence=ev))
    return out


def gate_findings(g):
    st = g.get("state")
    if st == "missing":
        return [finding("check.gate", "fail", g.get("message") or "no record of gate ①", evidence={"missing": g.get("missing") or [], "effort": g.get("effort")})]
    if st in ("on record", "waived"):
        return [finding("check.gate", "info", g.get("message") or st, evidence={k: g.get(k) for k in ("effort", "waived") if g.get(k)})]
    return []


def detect_findings(txt):
    """ffmpeg's blackdetect / freezedetect / silencedetect lines → one finding per span."""
    out, open_, dur = [], {}, {}
    for line in txt.splitlines():
        for kind in ("black", "freeze", "silence"):
            ms = dict(re.findall(rf"{kind}_(start|end|duration)\s*:\s*(-?[\d.]+)", line))
            if not ms:
                continue
            if "start" in ms and "end" in ms:   # blackdetect: all three on one line
                out.append((kind, float(ms["start"]), float(ms["end"]), float(ms.get("duration") or 0)))
            elif "start" in ms:
                open_[kind] = float(ms["start"])
                dur.pop(kind, None)
            elif "end" in ms:   # silencedetect has its duration on the end line; freezedetect on the line before
                a = open_.pop(kind, None)
                out.append((kind, a, float(ms["end"]), float(ms.get("duration") or dur.pop(kind, 0) or 0)))
            elif "duration" in ms:   # the open span's own (it used to be put on the span before it)
                dur[kind] = float(ms["duration"])
    for kind, a in open_.items():   # started and never ended: it runs to the end of the file
        out.append((kind, a, None, dur.get(kind)))
    what = {"black": "a black picture", "freeze": "a frozen picture", "silence": "silence"}
    res = []
    for kind, a, b, d in out:
        dur = d if d else (b - a if a is not None and b is not None else None)
        span = f"{a:.2f}–{b:.2f} s" if a is not None and b is not None else f"from {a:.2f} s to the end" if a is not None else f"up to {b:.2f} s"
        res.append(finding(f"check.{kind}", "warn", f"{what[kind]} {span}" + (f" ({dur:.2f} s)" if dur else "") + ": look at it (a dark background, a hold or a silent film is fine)",
                           t=a, t1=b, evidence={"duration": dur}))
    return res


def iso_findings(iso):
    out = []
    fps = iso.get("fps")
    for f in iso.get("findings") or []:
        st, ev = f.get("state"), {k: f.get(k) for k in ("key", "diff_prev", "diff_next", "prev_vs_next")}
        if f.get("entry"):
            ev["entry"] = f["entry"]
        n = f["frames"][1] - f["frames"][0] + 1
        span = f"{f['a']:.3f} s" if n == 1 else f"{f['a']:.3f}–{f['b']:.3f} s ({n} frames)"
        if st == "confirmed":
            out.append(finding("check.iso", "info", f"isolated frame at {span}: confirmed ({(f.get('entry') or {}).get('why') or 'confirmed.json'})",
                               t=f["a"], t1=f["b"], frame=f["frames"][0], frames=f["frames"], evidence=ev, confirmed=True))
        else:
            out.append(finding("check.iso", "fail", f"isolated frame at {span}" + (": its confirmation lapsed, the picture there changed" if st == "lapsed" else ""),
                               t=f["a"], t1=f["b"], frame=f["frames"][0], frames=f["frames"], evidence=ev, confirmed=False,
                               lapsed=st == "lapsed", confirm=f.get("confirm")))
    for a, b in iso.get("declared_runs") or []:
        k0, k1 = (round(a * fps), round(b * fps)) if fps else (None, None)
        out.append(finding("check.iso", "info", f"isolated frame at {a:.3f}" + (f"–{b:.3f}" if b > a else "") + " s: declared with --allow, this run only",
                           t=a, t1=b, frame=k0, frames=[k0, k1] if fps else None, confirmed=False, declared=True))
    for p in iso.get("periodic_runs") or []:
        out.append(finding("check.periodic", "info", f"{len(p['frames'])} small isolated frames, one every {p['gap']:g} frames: a periodic motion, not failed",
                           t=p["a"], t1=p["b"], frame=p["frames"][0], frames=[p["frames"][0], p["frames"][-1]], evidence={"frames": p["frames"], "gap_frames": p["gap"]}))
    for a, b in iso.get("blind_runs") or []:
        out.append(finding("check.blind", "info", f"{a:.2f}–{b:.2f} s moves too much for the scan to judge: strip-check it", t=a, t1=b))
    for a, b, frozen in iso.get("static") or []:
        if b - a >= 3.0:   # the listed ones (isoframes.STILL_LIST); shorter runs only count towards the still share
            out.append(finding("check.static", "warn", f"{a:.2f}–{b:.2f} s nothing moves" + (" (frozen)" if frozen else " (a slow drift)") + ": a hold you meant is fine",
                               t=a, t1=b, evidence={"frozen": frozen}))
    for t, before, after in iso.get("flashes") or []:
        out.append(finding("check.cut", "warn", f"a hard cut from dark to bright at {t:.2f} s (mean {before:.0f} → {after:.0f}): it reads as a flash",
                           t=t, frame=round(t * fps) if fps else None, evidence={"before": round(before, 1), "after": round(after, 1)}))
    if iso.get("fade_tail"):
        t, before, after = iso["fade_tail"]
        out.append(finding("check.fade", "warn", f"still fading at the last frame (mean {before:.0f} → {after:.0f}, not black): a fade meant to reach black stops short",
                           t=t, frame=round(t * fps) if fps else None, evidence={"before": round(before, 1), "after": round(after, 1)}))
    for c in iso.get("confirmed_notes") or []:
        if c.get("state") in ("lapsed", "unused"):
            out.append(finding("check.confirmed", "warn" if c["state"] == "unused" else "info",
                               f"confirmed.json: {c.get('tool')} at {c.get('at')}: {c['state']}" + (f" ({c['reason']})" if c.get("reason") else ""),
                               evidence={"entry": c}))
    for r in iso.get("refused") or []:
        out.append(finding("check.confirmed", "warn", f"confirmed.json item {r['item']} (at {r['at']!r}) not taken: {r['why']}", evidence={"item": r}))
    return out


def subs_findings(sb):
    out = []
    for src in sb.get("sources") or []:
        for e in src.get("short") or []:
            out.append(finding("check.subtitles", "warn", f"subtitle ({src['name']}) on screen {e['t1'] - e['t']:.2f} s, needs {e['need']:.2f} s to be read",
                               t=e["t"], t1=e["t1"], evidence={"source": src["name"], "need": e["need"], "text": e["text"]}))
    return out


def colour_findings(csv):
    v = (csv or "").strip()
    if not v:
        return []
    keys = ["pix_fmt", "range", "matrix", "transfer", "primaries"]
    ev = dict(zip(keys, v.split(",")))
    if v == "yuv420p,tv,bt709,bt709,bt709":
        return []
    return [finding("check.colour", "warn", f"colour: {v} (pix_fmt, range, matrix, transfer, primaries); deliver yuv420p, tv, bt709 ×3", evidence=ev)]


def loud_findings(ld):
    """The film's loudness (tools/loudcheck.py): a warning a way it is off what it was mixed to, else what it measured (info)."""
    if not ld.get("audio"):
        return []
    ev = {k: ld.get(k) for k in ("integrated", "true_peak", "lra", "target")}
    if ld.get("problems"):
        return [finding("check.loudness", "warn", f"loudness: {p}", evidence=ev) for p in ld["problems"]]
    return [finding("check.loudness", "info", f"loudness: {ld['integrated']:.1f} LUFS integrated, true peak {ld['true_peak']:.1f} dBTP, on the target", evidence=ev)]


def pack_findings(pk):
    out = []
    for f in pk.get("fields") or []:
        if f.get("over"):
            out.append(finding("check.packaging", "warn", f"PACKAGING.md · {f['heading']}: {f['field']} {f['count']} {f['unit']}, over the limit of {f['limit']} ({f.get('sure')})", evidence=f))
    for n in pk.get("notes") or []:
        out.append(finding("check.packaging", "warn", f"PACKAGING.md · {n}"))
    return out


def scale_findings(sc):
    out = []
    for p in sc.get("problems") or []:
        out.append(finding("check.scale", "fail", f"--against: {p}: not the same cut, nothing compared"))
    for s in sc.get("stretches") or []:
        out.append(finding("check.scale", s["severity"], f"{s['a']:.2f}–{s['b']:.2f} s: the picture differs from the reference (lowest {s['lowest_db']} dB)",
                           t=s["a"], t1=s["b"], frame=s["frames"][0], frames=s["frames"],
                           evidence={k: s.get(k) for k in ("lowest_db", "under_db", "image")}))
    return out


def edit_findings(ed):
    """An edit list's film: each slate left (fail), each image changed since it was drawn (warn)."""
    out = []
    if ed.get("error"):
        out.append(finding("check.slate", "fail", f"the edit list does not resolve: {ed['error']}"))
    for s in ed.get("slates") or []:
        out.append(finding("check.slate", "fail", f"{s['id']} is a slate, {s['t']:.2f}–{s['t1']:.2f} s: an entry with no source yet is a placeholder, not a film to deliver",
                           t=s["t"], t1=s["t1"], frame=s["frames"][0], frames=s["frames"], evidence={"from": ed.get("from")}))
    for c in ed.get("changed") or []:
        out.append(finding("check.edit", "warn", f"{c['path']} ({c['entry']}): {'gone' if c['now'] == 'gone' else 'not the bytes the film was drawn from'}",
                           evidence={"entry": c["entry"], "path": c["path"], "from": ed.get("from")}))
    return out


def place_in_edit(findings, ed):
    """Each finding with a time, in an edit list's film: the entry it falls in ({"id", "kind", "src"})."""
    ents, fps = ed.get("entries") or [], ed.get("fps") or 30
    for f in findings:
        t = f.get("t")
        if not isinstance(t, (int, float)) or f["kind"] == "check.slate":
            continue
        from timegrid import frame_at   # the frame on screen at t
        k = frame_at(t, fps)
        e = next((x for x in ents if isinstance(x.get("frames"), list) and x["frames"][0] <= k < x["frames"][1]), None)
        if e:
            f["entry"] = {"id": e.get("id"), "kind": e.get("kind"), "src": e.get("src")}


def record_path(video, project):
    rel = Path(os.path.relpath(video, project)).with_suffix("")
    parts = list(rel.parts)
    if parts and parts[0] == "out":
        parts = parts[1:]
    return Path(project) / "out" / "check" / ("-".join(parts) + ".check.json")


def film_changed(rec, st):
    """Is the film (st: its os.stat) other than the one this record checked? By the size and mtime_ns the record kept: a film
    put back with an old modification time still differs in one of them. None for a record without them (made before they
    were kept): the reader's own rule, by time, applies. Nothing is read or hashed, so a 4K film costs no more than a draft."""
    size, ns = rec.get("size"), rec.get("mtime_ns")
    if all(isinstance(x, int) and not isinstance(x, bool) for x in (size, ns)):
        return st.st_size != size or st.st_mtime_ns != ns
    return None


def main():
    ap = argparse.ArgumentParser(prog="checkrec.py")
    ap.add_argument("video"); ap.add_argument("--dir", required=True); ap.add_argument("--exit", type=int, required=True)
    ap.add_argument("--allow"); ap.add_argument("--against"); ap.add_argument("--print", action="store_true")
    ap.add_argument("--remedies", action="store_true")
    a = ap.parse_args()
    import confirm   # project_of: the nearest folder holding BRIEF.md
    video = Path(a.video).resolve()
    project = confirm.project_of(video)
    rec_path = record_path(video, project) if project else None
    shown = lambda p: os.path.relpath(p, project) if project and os.path.commonpath([str(p), str(project)]) == str(project) else str(p)   # noqa: E731
    findings, skipped = [], []
    pieces = [("spec.json", spec_findings, load), ("gate.json", gate_findings, load), ("detect.txt", detect_findings, text),
              ("iso.json", iso_findings, load), ("subs.json", subs_findings, load), ("colour.txt", colour_findings, text), ("loud.json", loud_findings, load),
              ("pack.json", pack_findings, load), ("scale.json", scale_findings, load), ("edit.json", edit_findings, load)]
    for name, fn, get in pieces:
        try:
            got = get(a.dir, name)
            if got is not None:
                findings += fn(got)
        except Exception as e:   # one piece that cannot be read must not lose the others
            skipped.append({"check": name.split(".")[0], "why": f"its result could not be read ({type(e).__name__}: {e})"})
    for line in (text(a.dir, "skipped.txt") or "").splitlines():
        if "\t" in line:
            c, why = line.split("\t", 1)
            skipped.append({"check": c, "why": why})
    for line in (text(a.dir, "errors.txt") or "").splitlines():   # a check that failed without a result of its own
        if line.count("\t") >= 2:
            kind, sev, msg = line.split("\t", 2)
            findings.append(finding(kind, sev, msg))
    ed = load(a.dir, "edit.json")
    if ed:   # an edit list's film: each finding with a time in the entry it falls in
        place_in_edit(findings, ed)
    import remedies   # tools/remedies.json: what can answer each kind of finding
    for f in findings:
        r = remedies.for_kind(f["kind"])
        if r:
            f["remedies"] = r
    if a.remedies:
        out = sys.stderr if a.print else sys.stdout   # with --print, stdout is the record: the ways out go beside it
        placed = [f for f in findings if f.get("entry") and f["severity"] in ("fail", "warn") and not f.get("confirmed")]
        if placed:
            print("→ where in the edit list:", file=out)
            for f in placed[:20]:
                e = f["entry"]
                print(f"   {f['kind'].split('.', 1)[-1]} {f['t']:.2f}" + (f"–{f['t1']:.2f}" if isinstance(f.get("t1"), (int, float)) else "") +
                      f" s: in {e['id']} ({e['kind']}{' ' + e['src'] if e.get('src') else ''})", file=out)
        for line in remedies.lines(findings):
            print(line, file=out)
    counts = {s: sum(f["severity"] == s for f in findings) for s in ("fail", "warn", "info")}
    iso = load(a.dir, "iso.json") or {}
    motion = {"moving": iso.get("moving"), "still_share": iso.get("still_share"), "cuts": len(iso.get("cuts") or [])} if "moving" in iso else None
    now = time.time()
    size = ns = None   # the film as it was when the checks began (film.txt), else as it is now: later readers compare it with the film then (film_changed)
    try:
        size, ns = map(int, (text(a.dir, "film.txt") or "").split())
    except ValueError:
        try:
            st = os.stat(video)
            size, ns = st.st_size, st.st_mtime_ns
        except OSError:
            pass
    rec = {"version": 1, "tool": "bin/vh check", "video": shown(video), "project": str(project) if project else None,
           "record": shown(rec_path) if rec_path else None, "t": round(now, 3), "at": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now)),
           "size": size, "mtime_ns": ns,
           "args": {"allow": a.allow or None, "against": shown(Path(a.against).resolve()) if a.against else None},
           "exit": a.exit, "verdict": "pass" if a.exit == 0 else "fail", "counts": counts, "probe": probe(video), "motion": motion,
           "findings": findings, "skipped": skipped}
    if rec_path:
        try:
            rec_path.parent.mkdir(parents=True, exist_ok=True)
            tmp = rec_path.with_name(f".{rec_path.name}.{os.getpid()}")
            tmp.write_text(json.dumps(rec, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
            os.replace(tmp, rec_path)
        except OSError as e:
            print(f"check: could not save the record {rec_path} ({e.strerror or e})", file=sys.stderr)
            rec["record"] = None
    if a.print:
        print(json.dumps(rec, ensure_ascii=False, indent=1))
    import activity   # tools/activity.py: the verdict and the record in the project's log, when bin/vh ran us
    activity.note(f"{rec['video']}: {rec['verdict']} · {counts['fail']} fail, {counts['warn']} warn", [rec_path] if rec["record"] else [])
    return 0


if __name__ == "__main__":
    sys.exit(main())
