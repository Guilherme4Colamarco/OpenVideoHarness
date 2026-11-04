"""Isolated-frame scan: a frame unlike both of its neighbours while the neighbours agree with each other.

usage: uv run --with numpy python tools/isoframes.py <video> [--allow t,t,a-b,…] [--confirmed f] [--motion] [--json f]
exit status: 0 none found (or only declared, confirmed or periodic ones), 1 isolated frames found (times floored to the
             ms), 2 the video could not be read, 3 a bad --allow or an unreadable --confirmed file (bin/vh check fails on
             it, so a typo cannot switch the scan off)
  --allow  times in seconds of flashes you designed, or spans a-b: a hit within one frame of one is listed as declared and
           does not fail. For this run only: nothing is kept
  --confirmed  the project's confirmed.json (tools/confirm.py; bin/vh check passes it): a run of isolated frames confirmed
           there (check.iso, within one frame of its time) is listed as confirmed and does not fail while the picture
           there is the same: the key is two 8 x 6 thumbnails at 64 grey levels, of the frame before the run and of its
           most different frame, the same when no cell moves by more than PIC_MAX levels and the cells by PIC_MEAN on
           average (a re-encode or a 4K copy keeps it; a redrawn or retimed frame does not). The key is coarse: a small
           change inside the frame (one wrong character, a thin line) may keep it, so look again after such an edit. A
           missing file is no entries yet; each unconfirmed run gets a `confirm?` line to paste there, with why and
           evidence
  --motion also, from the same decode, how the film moves (never a failure; bin/vh check passes it): see MOTION below
  --json   every number, per frame and per finding (with its confirmation, and the entry that would confirm it), into a
           file; bin/vh check's record (tools/checkrec.py) is built from it

That is what a capture glitch looks like: a single frame that flashes another scene, or text drawn as garbage, between two
frames that are fine. The black/freeze/silence scan of `bin/vh check` cannot see it (it lasts one frame), and a snapshot
of the same time is clean, because the snapshot takes another capture path. Seen in a HyperFrames 0.8.82 render whose
drawElement capture failed its self-check and fell back to multi-worker screenshots with the browser GPU on.

Frames are decoded at 192x108 grey (108x192 for a portrait video) and compared three at a time. Frame i is isolated when
  - more than 1 % of its pixels differ by more than 12 grey levels from frame i-1,
  - the same holds against frame i+1,
  - and the share of pixels differing by more than 6 between frames i-1 and i+1 is under a quarter of the smaller of those.
A cut never qualifies (the frames on either side of it differ); a one-frame flash inside a shot does, intended or not.
What it cannot see: a glitch two or more frames long (a run of bad frames looks like motion), the first and last frame,
glitches under 1 % of the picture (a few garbled characters), and any frame whose neighbours already differ by a quarter
of the picture or more (particles, camera moves, line boil): those frames are counted (leaving out the one or two a cut
makes) and their stretches of half a second or more listed, so strip-check them.

Periodic motion: an oscillation can land on its still point once a cycle, and that frame looks isolated. Four or more
hits evenly spaced (within a frame; one every 4 frames to 2 s), each small (at most 25 % of the picture) and alike in
size, are reported as periodic motion and do not fail; looked for only when there are 50 hits or fewer, since a render
with more is broken. Keep a periodic motion under a quarter of the frame rate, as a smooth cosine (playbook/03).

MOTION (--motion). Same 192x108 grey frames. The thresholds are first guesses checked on a few films, not rules
(docs/research/07-motion-checks.md has the numbers): every line is a warning to look at, never a failure.
  cuts     a frame where over 30 % of the pixels change by more than 12 levels, the mean change is over 18 and over 3 times
           the median of the 10 frames around it: a hard cut. A cut after which the brightest of the next 3 frames is at
           least 170 of 255 and over 90 above the mean of the 3 before is listed: dark to bright in one frame reads as a
           flash (a one-frame white flash between two dark shots too).
  static   runs where no frame differs from the one before it on more than 0.2 % of its pixels (by more than 6 levels;
           film grain stays under that at this size): nothing the eye reads as moving. The share of the film in runs of
           2 s or more goes on the summary line; runs of 3 s or more are listed, each said to be frozen (not even frames a
           second apart differ) or a slow drift. Black runs (under 2 % of the pixels above 25 of 255) are left to blackdetect; a
           held formula on a black background is not black.
  ending   the mean brightness still falling on each of the last 4 frames, by at least 6 levels in all and 1 on the last step,
           and the last frame still above 4: a fade that stops short of black. A fade timed to the film's length ends after
           its last frame is drawn (that frame is at length − 1 frame), and the next shot, or a clip's end, then jumps.
  summary  the share of frame pairs where over 0.5 % of the picture changes, the hard cuts, the still share, and the
           largest jump inside a shot: leaving out 0.35 s after each cut and changes as large as a cut, a frame-to-frame
           change over 8 times the shot's median (and over 6 levels) in a shot that moves at all. On the showcase films
           those were designed pops and fast pushes, so it is only a number on the summary line, not a warning.
"""
import argparse, json, re, subprocess, sys
from collections import deque
from fractions import Fraction
from pathlib import Path
import numpy as np
import confirm   # tools/confirm.py

STEP, CHANGED = 12, 0.01      # a pixel differs from a neighbour by more than STEP grey levels; frame differs: share > CHANGED
STEP_PN, MAX_PN = 6, 0.25     # the neighbours agree: their share over STEP_PN is under MAX_PN x the smaller of the two above
CUT_SHARE, CUT_MEAN = 0.30, 18.0    # --motion: a hard cut (share over 12 levels; mean absolute change)
FLASH, BRIGHT = 90.0, 170.0         # a cut whose brightness rises by more than FLASH to at least BRIGHT (of 255) reads as a flash
LIT = 25                            # a pixel over this (of 255) is not black (blackdetect's 0.10); a run under 2 % lit is black
PERIODIC_MAX, PERIODIC_SIZE = 50, 0.25   # periodic motion: only among at most this many hits, each changing at most this share
STILL_STEP, STILL_SHARE = 6, 0.002   # a frame pair is still when under STILL_SHARE of the picture changes by over STILL_STEP
STILL_SUM, STILL_LIST = 2.0, 3.0     # still runs of STILL_SUM s count towards the share; runs of STILL_LIST s are listed
JUMP_RATIO, JUMP_MIN, JUMP_MOVING, AFTER_CUT = 8.0, 6.0, 0.3, 0.35
MOVING = 0.005
FADE_FRAMES, FADE_DROP, FADE_STEP, FADE_BLACK = 4, 6.0, 1.0, 4.0   # --motion: still falling on the last frames, and not black yet
PIC_COLS, PIC_ROWS, PIC_MAX, PIC_MEAN = 8, 6, 1, 0.25   # --confirmed: the key's thumbnails, and how far they may move

def die(msg):
    print(f"isoframes: {msg}", file=sys.stderr); sys.exit(2)

def probe(video):
    """→ (width, height, rate) of the first video stream; rate is the string ffmpeg would pick (r_frame_rate, or
    avg_frame_rate when r_frame_rate is a timebase rather than a frame rate), or None when neither is usable."""
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                          "stream=width,height,avg_frame_rate,r_frame_rate", "-of", "json", video],
                         capture_output=True, text=True)
    st = (json.loads(out.stdout or "{}").get("streams") or [None])[0]
    if out.returncode or not st:
        die(f"no video stream in {video}: {out.stderr.strip() or 'ffprobe found none'}")
    for key in ("r_frame_rate", "avg_frame_rate"):
        num, _, den = st.get(key, "0/0").partition("/")
        if int(den or 0) > 0 and 0 < int(num) / int(den) <= 240:
            return st["width"], st["height"], st[key]
    return st["width"], st["height"], None

def frames(video, w, h, rate):
    """Decoded frames as int16 arrays, one at a time. The output is resampled to `rate` (a no-op for a constant-rate
    file), so frame i is at i / rate."""
    cmd = ["ffmpeg", "-nostdin", "-v", "error", "-i", video, "-map", "0:v:0", "-vf", f"scale={w}:{h},format=gray"]
    p = subprocess.Popen(cmd + (["-r", rate] if rate else []) + ["-f", "rawvideo", "-"], stdout=subprocess.PIPE)
    while len(buf := p.stdout.read(w * h)) == w * h:
        yield np.frombuffer(buf, np.uint8).reshape(h, w).astype(np.int16)
    p.stdout.close()
    if p.wait():
        die(f"ffmpeg could not decode {video} (exit {p.returncode})")

def thumb(g):
    """The key's thumbnail of a 192 x 108 grey frame: PIC_COLS x PIC_ROWS cell means (rows and columns swap for a
    portrait frame), at 64 levels (4 grey levels each), one character a cell."""
    h, w = g.shape
    c, r = (PIC_COLS, PIC_ROWS) if w > h else (PIC_ROWS, PIC_COLS)
    return confirm.code(np.clip(g.reshape(r, h // r, c, w // c).mean((1, 3)) // 4, 0, 63).ravel())

def same_pic(k1, k2):
    """Two keys ("pic:<thumbnail>.<thumbnail>") of the same picture: no cell more than PIC_MAX levels apart, and on
    average no more than PIC_MEAN."""
    a, b = (confirm.uncode(k.removeprefix("pic:").replace(".", "")) for k in (k1, k2))
    if not a or not b or len(a) != len(b):
        return False
    d = [abs(x - y) for x, y in zip(a, b)]
    return max(d) <= PIC_MAX and sum(d) / len(d) <= PIC_MEAN

def changed(a, b, step):
    return float((np.abs(a - b) > step).mean())

def runs(idx, gap):
    """[first, last] stretches of sorted frame numbers, joining neighbours up to `gap` frames apart."""
    out = []
    for i in idx:
        if out and i - out[-1][1] <= gap:
            out[-1][1] = i
        else:
            out.append([i, i])
    return out

def scan(video, motion=False):
    """→ (frames decoded, rate, hits [(frame, d_prev, d_next, d_pn)], blind [frames whose neighbours differ too much to
    judge], per-frame motion stats or None, {hit: (thumbnail of the frame before, of the hit)}). The stats, per frame n
    from 1: area (share over STEP against frame n-1), energy (mean absolute change), luma (mean of frame n; luma[0] for
    frame 0 too), still (share over STILL_STEP against the frame a second before, None for the first second)."""
    vw, vh, rate = probe(video)
    w, h = (108, 192) if vh > vw else (192, 108)
    sec = max(1, round(float(Fraction(rate)))) if rate else 30
    hits, blind, n, prev, cur, d_prev, pics = [], [], 0, None, None, 0.0, {}
    st = {"area": [0.0], "area6": [0.0], "energy": [0.0], "luma": [], "lit": [], "still": [None]} if motion else None
    ring = deque(maxlen=sec + 1)
    for nxt in frames(video, w, h, rate):
        if motion:
            st["luma"].append(float(nxt.mean())); st["lit"].append(float((nxt > LIT).mean()))
            ring.append(nxt)
            if n:
                st["area"].append(changed(cur, nxt, STEP)); st["area6"].append(changed(cur, nxt, STILL_STEP)); st["energy"].append(float(np.abs(nxt - cur).mean()))
                st["still"].append(changed(ring[0], nxt, STILL_STEP) if len(ring) == sec + 1 else None)
        if cur is not None:
            d_next = changed(cur, nxt, STEP)
            if prev is not None:
                d_pn = changed(prev, nxt, STEP_PN)
                if d_pn >= MAX_PN:   # no glitch, however large, can pass the third test here
                    blind.append(n - 1)
                elif d_prev > CHANGED and d_next > CHANGED and d_pn < MAX_PN * min(d_prev, d_next):
                    hits.append((n - 1, d_prev, d_next, d_pn)); pics[n - 1] = (thumb(prev), thumb(cur))
            d_prev = d_next
        prev, cur, n = cur, nxt, n + 1
    if n == 0:
        die(f"no frames decoded from {video}")
    return n, rate, hits, blind, st, pics

def periodic(hits, fps):
    """Isolated frames that are a periodic motion rather than glitches: chains of 4 or more evenly spaced hits (each gap
    within one frame of the first, the gap from 4 frames to 2 s), each hit small (changing at most PERIODIC_SIZE of the
    picture) and the hits of a chain alike (the largest at most 3x the smallest). Looked for only among PERIODIC_MAX hits
    or fewer: a render with more is broken, not bouncing. → [(frames, gap)], longest first, each frame in one chain."""
    if not fps or len(hits) > PERIODIC_MAX:
        return []
    size = {i: max(d1, d2) for i, d1, d2, _ in hits}
    left = sorted(i for i in size if size[i] <= PERIODIC_SIZE)
    out = []
    while len(left) >= 4:
        have, best = set(left), []
        for a in left:
            for g in range(4, int(round(2 * fps)) + 1):
                chain, last = [a], a
                slack = (0, -1, 1) if g >= 8 else (0,)   # short gaps must be exact: a few frames of jitter there is noise
                while True:
                    nxt = next((last + g + d for d in slack if last + g + d in have), None)
                    if nxt is None: break
                    chain.append(nxt); last = nxt
                # one steady rhythm: every hit within a frame of the line through the first and the last (no drift)
                step = (chain[-1] - chain[0]) / max(1, len(chain) - 1)
                steady = all(abs(c - (chain[0] + k * step)) <= 1 for k, c in enumerate(chain))
                if steady and len(chain) > len(best) and max(size[c] for c in chain) <= 3 * min(size[c] for c in chain): best = chain
        if len(best) < 4: break
        out.append((best, round((best[-1] - best[0]) / (len(best) - 1), 2)))
        left = [x for x in left if x not in best]
    return out

def motion_report(st, n, fps, hits_near):
    """The --motion findings: (lines, numbers)."""
    area, area6, energy, luma, lit, still = st["area"], st["area6"], st["energy"], st["luma"], st["lit"], st["still"]
    # hard cuts: one frame of large change, well above the frames around it (a camera that keeps moving after a cut too)
    cuts = []
    for i in range(1, n):
        if area[i] > CUT_SHARE and energy[i] > CUT_MEAN:
            around = [energy[k] for k in range(max(1, i - 5), min(n, i + 6)) if k != i]
            if not around or energy[i] > 3 * float(np.median(around)): cuts.append(i)
    flashes = []
    for i in cuts:   # the brightest of the 3 frames after the cut: a one-frame white flash between two dark shots counts too
        before, after = np.mean(luma[max(0, i - 3):i]), max(luma[i:i + 3])
        if after - before > FLASH and after >= BRIGHT: flashes.append((i, float(before), float(after)))
    # static: frame pairs where almost nothing changes (over STILL_STEP on under STILL_SHARE of the picture: grain stays
    # under the step at this size), in runs of STILL_MIN s; "frozen" when not even a second apart shows a change, else a
    # slow drift that the eye reads as still. Black runs are blackdetect's
    stretches, i = [], 1
    while i < n:
        if area6[i] < STILL_SHARE:
            j = i
            while j + 1 < n and area6[j + 1] < STILL_SHARE: j += 1
            if (j - i + 2) / fps >= STILL_SUM and np.mean(lit[i - 1:j + 1]) >= 0.02:   # black (under 2 % lit) is blackdetect's
                inside = [still[k] for k in range(i + int(round(fps)), j + 1) if still[k] is not None]   # a second apart, both in the run
                frozen = bool(inside) and all(x < STILL_SHARE for x in inside)
                stretches.append((i - 1, j, frozen))
            i = j + 1
        else: i += 1
    # jumps inside shots: not cuts, not where an isolated frame was already reported
    bounds = [0, *cuts, n]
    jumps = []
    skip = int(round(AFTER_CUT * fps))
    for a, b in zip(bounds, bounds[1:]):
        e = [(k, energy[k]) for k in range(a + skip + 1, b) if k not in hits_near]
        if len(e) < 3: continue
        med = float(np.median([x for _, x in e]))
        k, peak = max(((k, x) for k, x in e if area[k] <= CUT_SHARE), key=lambda x: x[1], default=(None, 0.0))
        if k is not None and med > JUMP_MOVING and peak > JUMP_MIN and peak > JUMP_RATIO * med:
            jumps.append((k, peak, med))
    moving = float(np.mean([x > MOVING for x in area[1:]])) if n > 1 else 0.0
    # ending: a fade still under way when the film stops. A film that ends on a hold, or on a dark picture, falls short of none of this
    tail = [float(x) for x in luma[-FADE_FRAMES:]] if n >= FADE_FRAMES else []
    fade_tail = None
    if tail and all(y < x for x, y in zip(tail, tail[1:])) and tail[0] - tail[-1] >= FADE_DROP and tail[-2] - tail[-1] >= FADE_STEP and tail[-1] > FADE_BLACK:
        fade_tail = [(n - 1) / fps, tail[0], tail[-1]]
    t = lambda k: f"{k / fps:.2f}"
    still_s = sum((j - i + 1) / fps for i, j, _ in stretches)
    long_ = [x for x in stretches if (x[1] - x[0] + 1) / fps >= STILL_LIST]
    top = max(jumps, key=lambda x: x[1] / x[2], default=None)
    lines = [f"  motion: {moving:.0%} of the frame pairs move (over {MOVING:.1%} of the picture) · {len(cuts)} hard cut(s) · still in runs of "
             f"{STILL_SUM:g} s or more: {still_s / (n / fps):.0%} of the film" + (f" · the largest jump inside a shot {top[1] / top[2]:.0f}x its median at {t(top[0])} s" if top else "")]
    if long_:
        lines.append(f"  static: {len(long_)} stretch(es) of {STILL_LIST:g} s or more where nothing moves from frame to frame: "
                     + ", ".join(f"{t(i)}–{t(j + 1)} s{' (frozen)' if fz else ' (a slow drift)'}" for i, j, fz in long_[:8])
                     + (" …" if len(long_) > 8 else "") + " (a hold you meant: fine; otherwise a new event, a push or a move)")
    if flashes:
        lines.append(f"  cuts: {len(flashes)} hard cut(s) from dark to bright, which read as a flash: "
                     + ", ".join(f"{t(i)} s (mean {b:.0f} → {a:.0f})" for i, b, a in flashes[:8]) + (" …" if len(flashes) > 8 else "")
                     + " (dim the bright side or fade it in over a few frames)")
    if fade_tail:
        lines.append(f"  ending: the picture is still fading when the film stops: its last {FADE_FRAMES} frames fall from mean {tail[0]:.0f} to {tail[-1]:.0f}, not to black "
                     "(a fade timed to the film's length ends after its last frame is drawn; meant to end there: fine)")
    nums = {"moving": moving, "fade_tail": fade_tail, "still_share": still_s / (n / fps), "cuts": [k / fps for k in cuts], "flashes": [[i / fps, b, a] for i, b, a in flashes],
            "static": [[i / fps, (j + 1) / fps, fz] for i, j, fz in stretches], "jumps": [[k / fps, p, m] for k, p, m in jumps]}
    return lines, nums

def main():
    ap = argparse.ArgumentParser(prog="isoframes.py", usage=__doc__.split("\n\n")[1].split("\n")[0][7:])
    ap.add_argument("video")
    ap.add_argument("--allow", default="", help="times (s) or spans (a-b) of flashes you designed, comma-separated")
    ap.add_argument("--confirmed", help="the project's confirmed.json (a missing file: no entries yet)")
    ap.add_argument("--motion", action="store_true", help="also how the film moves: cuts, flashes, static stretches, jumps")
    ap.add_argument("--json", help="every number into this file")
    a = ap.parse_args()
    allow, num = [], r"(\d+(?:\.\d*)?|\.\d+)"
    for x in (x.strip() for x in a.allow.split(",") if x.strip()):
        m = re.fullmatch(rf"{num}(?:\s*-\s*{num})?", x)
        if not m or (m.group(2) is not None and float(m.group(2)) < float(m.group(1))):
            print(f"isoframes: --allow takes seconds or spans a-b (b ≥ a) separated by commas, not {x!r}", file=sys.stderr); sys.exit(3)
        allow.append((float(m.group(1)), float(m.group(2) if m.group(2) is not None else m.group(1))))
    taken, refused = [], []
    if a.confirmed and Path(a.confirmed).exists():
        try:
            taken, refused = confirm.load(a.confirmed, "check.")
        except confirm.Bad as e:
            print(f"isoframes: {e}", file=sys.stderr); sys.exit(3)
    try:
        n, rate, hits, blind, st, pics = scan(a.video, a.motion)
    except OSError as e:   # ffprobe or ffmpeg missing: not a finding
        die(f"cannot run {e.filename or 'ffmpeg'}: {e.strerror}")
    fps = float(Fraction(rate)) if rate else None
    def t(i):   # floored to the ms, so `ffmpeg -ss <t> -i video` lands on this frame and not the next
        return f"{i * 1000 // Fraction(rate) / 1000:.3f} s" if rate else f"frame {i}"
    def span(r, count=True):
        if r[0] == r[1]:
            return t(r[0])
        return f"{t(r[0]).removesuffix(' s')}–{t(r[1])}" + (f" ({r[1] - r[0] + 1} frames)" if count else "")
    # a declared time matches a hit within one frame either way; +1 ms because printed times are floored to the ms
    declared = [x for x in hits if fps and any(lo - 1 / fps - 0.001 <= x[0] / fps <= hi + 1 / fps + 0.001 for lo, hi in allow)]
    rest = [x for x in hits if x not in declared]
    chains = periodic(rest, fps)
    regular = {i for c, _ in chains for i in c}
    found = [x for x in rest if x[0] not in regular]
    # confirmed.json: one finding per run of isolated frames, keyed by the frame before it and its most different frame
    rs, size = runs([i for i, *_ in found], 2), {i: max(d1, d2) for i, d1, d2, _ in found}
    sec = lambda i: i * 1000 // Fraction(rate) / 1000 if rate else 0.0   # noqa: E731 (t() without the unit)
    finds = [{"a": float(sec(r[0])), "b": float(sec(r[1])),
              "key": f"pic:{pics[r[0]][0]}.{pics[max((i for i in size if r[0] <= i <= r[1]), key=size.get)][1]}"} for r in rs]
    state, notes = ([("open", None)] * len(rs), [])
    if fps and taken:   # within a frame of the run's first and last frame, as --allow
        state, notes = confirm.judge(taken, "check.iso", finds, 1 / fps + 0.001, same_pic)
    shut = {i for r, (s_, _) in zip(rs, state) if s_ == "confirmed" for i in range(r[0], r[1] + 1)}
    open_ = [x for x in found if x[0] not in shut]
    diff = {i: (d1, d2, d3) for i, d1, d2, d3 in found}
    iso_findings = []   # --json: one per run of isolated frames, with its numbers, its confirmation and the line to confirm it
    for f, r, (s_, e) in zip(finds, rs, state):
        k = max((i for i in size if r[0] <= i <= r[1]), key=size.get)   # the run's most different frame
        item = {"a": f["a"], "b": f["b"], "frames": [r[0], r[1]], "state": s_, "key": f["key"],
                "diff_prev": round(diff[k][0], 4), "diff_next": round(diff[k][1], 4), "prev_vs_next": round(diff[k][2], 4)}
        if e:
            item["entry"] = {x: e.get(x) for x in ("at", "why", "evidence", "date")}
        if s_ != "confirmed" and fps:
            item["confirm"] = json.loads(confirm.offer("check.iso", f["a"], f["b"], f["key"]).split("confirm? ", 1)[1])
        iso_findings.append(item)
    if found:
        k = len(rs) - sum(s_ != "confirmed" for s_, _ in state)
        print(f"{len(found)} isolated frame(s) in {n}: " + ", ".join(span(r) for r in rs)
              + ("" if not k else f" · all confirmed ({confirm.NAME})" if not open_ else f" · {k} of {len(rs)} confirmed ({confirm.NAME})"))
        for i, d1, d2, d3 in open_[:10]:
            print(f"  frame {i:>6}  {t(i):>11}   differs from prev {d1:6.1%}, next {d2:6.1%}; prev vs next {d3:5.1%}")
        if len(open_) > 10:
            print(f"  … {len(open_) - 10} more")
    else:
        print(f"no isolated frames in {n} frames")
    for c, g in chains:
        print(f"  periodic: {len(c)} small frames, one every {g:g} frames ({g / fps:.2f} s), at {t(c[0]).removesuffix(' s')}–{t(c[-1])}: a periodic motion "
              f"landing on its still point once a cycle, so not failed; a bounce that flickers is aliasing: keep periodic motion under "
              f"{fps / 4:.1f} Hz, a smooth cosine (playbook/03)")
    if declared:
        print("  declared (--allow, this run only): " + ", ".join(span(r) for r in runs([i for i, *_ in declared], 2))
              + (f"; to keep a declaration, confirm it in {a.confirmed}" if a.confirmed else ""))
        wide = [f"{lo:g}-{hi:g}" for lo, hi in allow if hi - lo > 5]
        if wide or len(declared) > 10:
            print(f"  note: --allow {', '.join(wide) or a.allow} declares {len(declared)} frame(s)" + (" over spans longer than 5 s" if wide else "")
                  + ": make sure every one is a flash you designed")
    if allow and not fps:
        print("  --allow ignored: the video has no usable frame rate, so times cannot be matched")
    if taken and not fps:
        print(f"  {a.confirmed} ignored: the video has no usable frame rate, so times cannot be matched")
    for line in confirm.lines(notes, refused):
        print(line)
    offers = [(f, r) for f, r, (s_, _) in zip(finds, rs, state) if s_ != "confirmed"]
    if a.confirmed and offers and fps:
        print(f"  a flash you designed: paste its line into {a.confirmed}, with why (the shot) and evidence (a file that shows it);"
              " a capture glitch is fixed, not confirmed:")
        for f, r in offers[:10]:
            print(confirm.offer("check.iso", f["a"], f["b"], f["key"]))
    near = {j for i, *_ in hits for j in (i - 1, i + 1)}   # a flagged frame's neighbours see it, not motion
    free = [i for i in blind if i not in near]
    k = sum(r[1] - r[0] + 1 for r in runs(free, 1) if r[1] - r[0] + 1 >= 3)   # a cut makes one or two such frames
    blind_runs = []
    if k:
        rs = blind_runs = [r for r in runs(free, 3) if r[1] - r[0] + 1 >= max(3, round((fps or 30) / 2))]
        more = f" (+{len(rs) - 6} more)" if len(rs) > 6 else ""
        where = (": " + ", ".join(span(r, False) for r in rs[:6]) + more) if rs else " (all in stretches under half a second)"
        print(f"  {k} of {n} frames ({k / n:.0%}) move too much to judge, strip-check them{where}")
    nums = {}
    if st is not None and fps:
        lines, nums = motion_report(st, n, fps, {j for i, *_ in hits for j in (i, i + 1)})
        for line in lines: print(line)
    if a.json:
        out = {"frames": n, "fps": fps, "isolated": [i for i, *_ in found], "periodic": [[c, g] for c, g in chains],
               "declared": [i for i, *_ in declared], "confirmed": sorted(shut), "open": [i for i, *_ in open_], **nums}
        s = lambda i: float(sec(i))   # noqa: E731
        out.update(findings=iso_findings, declared_runs=[[s(r[0]), s(r[1])] for r in runs([i for i, *_ in declared], 2)],
                   periodic_runs=[{"frames": c, "gap": g, "a": s(c[0]), "b": s(c[-1])} for c, g in chains],
                   confirmed_notes=[{"state": st_, "tool": e["tool"], "at": e.get("at"), "why": str(e.get("why") or "").strip(), "reason": why}
                                    for e, st_, why in notes],
                   refused=[{"item": n_, "at": at_, "why": why} for n_, at_, why in refused],
                   blind_frames=k, blind_runs=[[s(r[0]), s(r[1] + 1)] for r in blind_runs])
        if st is not None: out["per_frame"] = {k2: st[k2] for k2 in ("area", "area6", "energy", "luma", "still")}
        Path(a.json).write_text(json.dumps(out))
    sys.exit(1 if open_ else 0)

if __name__ == "__main__":
    main()
