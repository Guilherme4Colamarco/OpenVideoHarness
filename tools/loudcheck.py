"""bin/vh check's loudness: the film's sound as it is in the file that will be uploaded, measured (ITU-R BS.1770 through
ffmpeg's ebur128 filter, true peak 4× oversampled): integrated loudness, true peak and loudness range. Stdlib only, and
ffmpeg.

usage: python3 tools/loudcheck.py <video> [--project DIR] [--json f.json] [--lufs -14] [--tol 1] [--tp -1]
The target is what the film's sound was mixed to: the newest complete mix record in the project (<out>.mix.json, which
bin/vh mix writes beside its output: its lufs= and tp=, from the record's target, or from its arguments and the chain's
defaults in an older record), else the BRIEF's "- Loudness: -16 LUFS" line, else bin/vh mix's own −14 LUFS and −1.5
dBTP. Integrated within --tol LU of it; true peak at most the mix's ceiling + 0.5 dB (an AAC encode moves the peak by
an amount that depends on the content and the bitrate, +0.75 dB on a 2026-10 narration film: tools/audio/README.md),
never stricter than the platforms' −1 dBTP. --lufs and --tp say a target outright. Off the target is said ("WARN …"),
not failed: a quiet art film may be on purpose. A film with no sound is said and left there.
Exit 0 (the words say how it went); 2 a usage error, or ffmpeg could not measure it.
--json: {"audio": bool, "integrated", "true_peak", "lra", "target": {"lufs", "tol", "tp", "from"}, "ok", "problems": [text]}.
"""
import argparse, json, re, subprocess, sys
from pathlib import Path

LOUDNESS_LINE = re.compile(r"^[ \t]*[-*][ \t]*(?:\*\*)?(?:Loudness|响度)(?:\*\*)?[ \t]*[:：][ \t]*(-?\d+(?:\.\d+)?)[ \t]*LUFS", re.M | re.I)


def target_of(project):
    """(lufs, the mix's true-peak ceiling, where it was read) the film's sound was mixed to (the module's note)."""
    if project:
        p, recs = Path(project), []
        for f in list(p.glob("*.mix.json")) + list(p.glob("audio/**/*.mix.json")):
            try:
                st = json.loads(f.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if not isinstance(st, dict) or st.get("status") != "complete":
                continue
            t = st.get("target")
            if not isinstance(t, dict):   # a record from before mix wrote its target: its arguments say it
                kv = dict(x.split("=", 1) for x in st.get("args") or [] if isinstance(x, str) and "=" in x)
                t = {"lufs": kv.get("lufs", -14), "tp": kv.get("tp", -1.5 if kv.get("profile", "none") == "none" else -1.65)}
            try:
                recs.append((f.stat().st_mtime, str(f.relative_to(p)), float(t["lufs"]), float(t["tp"])))
            except (KeyError, TypeError, ValueError):
                continue
        if recs:
            _, where, lufs, tp = max(recs)
            return lufs, tp, where
        brief = p / "BRIEF.md"
        m = LOUDNESS_LINE.search(brief.read_text(encoding="utf-8")) if brief.is_file() else None
        if m:
            return float(m.group(1)), -1.5, "BRIEF.md"
    return -14.0, -1.5, None


def measure(video):
    """{"integrated", "true_peak", "lra"} of the first audio stream, or None when there is none."""
    has = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_type", "-of", "csv=p=0", video],
                         capture_output=True, text=True).stdout.strip()
    if not has:
        return None
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", video, "-map", "0:a:0", "-af", "ebur128=peak=true:framelog=quiet", "-f", "null", "-"],
                       capture_output=True, text=True, errors="replace")
    summary = r.stderr[r.stderr.rfind("Summary:"):] if "Summary:" in r.stderr else ""
    def num(pat):
        m = re.search(pat, summary, re.S)
        try:
            return float(m.group(1)) if m else None
        except ValueError:
            return None
    got = {"integrated": num(r"Integrated loudness:.*?I:\s*(-?[\d.]+|-inf)\s*LUFS"), "true_peak": num(r"True peak:.*?Peak:\s*(-?[\d.]+|-inf)\s*dBFS"),
           "lra": num(r"Loudness range:.*?LRA:\s*(-?[\d.]+)\s*LU")}
    if r.returncode or got["integrated"] is None:
        raise RuntimeError(f"ffmpeg ebur128 gave no summary (exit {r.returncode}): {r.stderr.strip()[-300:]}")
    return got


def main(argv):
    ap = argparse.ArgumentParser(prog="loudcheck.py", description=__doc__.split("\n\n")[0])
    ap.add_argument("video")
    ap.add_argument("--project")
    ap.add_argument("--json")
    ap.add_argument("--lufs", type=float)
    ap.add_argument("--tol", type=float, default=1.0)
    ap.add_argument("--tp", type=float)
    a = ap.parse_args(argv)
    lufs, ceiling, where = target_of(a.project)
    a.lufs = lufs if a.lufs is None else a.lufs
    a.tp = max(-1.0, round(ceiling + 0.5, 2)) if a.tp is None else a.tp
    src = "given" if a.lufs != lufs else where or "bin/vh mix's default"
    try:
        m = measure(a.video)
    except (RuntimeError, OSError) as e:
        print(f"loudness: {e}", file=sys.stderr)
        return 2
    target = {"lufs": a.lufs, "tol": a.tol, "tp": a.tp, "from": src}
    if m is None:
        res = {"audio": False, "target": target, "ok": True, "problems": []}
        line = "loudness: no sound (a silent film)"
    else:
        probs = []
        if abs(m["integrated"] - a.lufs) > a.tol + 1e-9:
            probs.append(f"{m['integrated']:.1f} LUFS integrated, {m['integrated'] - a.lufs:+.1f} LU off the {a.lufs:g} it was mixed to ({src}): "
                         + "the film does not carry that mix's sound (mux the mix again), or "
                         + (f"the mix went louder than asked (bin/vh mix … lufs={a.lufs:g})" if m["integrated"] > a.lufs
                            else f"it came out quieter than asked (bin/vh mix … lufs={a.lufs:g}, then mux again)"))
        if m["true_peak"] is not None and m["true_peak"] > a.tp + 1e-9:
            probs.append(f"true peak {m['true_peak']:.1f} dBTP, over {a.tp:g}: it may clip on a phone once the platform re-encodes it "
                         "(bin/vh mix's true-peak ceiling, then mux again)")
        res = {"audio": True, **m, "target": target, "ok": not probs, "problems": probs}
        line = (f"loudness: {m['integrated']:.1f} LUFS integrated · true peak {m['true_peak']:.1f} dBTP · LRA {m['lra']:.1f} LU"
                f" (target {a.lufs:g} ±{a.tol:g}, ≤ {a.tp:g} dBTP: {src})")
        if probs:
            line = "WARN " + line + "".join(f"\n   {p}" for p in probs)
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(res, f)
    print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
