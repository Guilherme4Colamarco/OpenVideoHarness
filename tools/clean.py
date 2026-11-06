"""Clear a finished project's intermediate files: keep the film, its covers, captions, publishing copy, sources, docs and the
narration in use; put the rest in the Trash (or delete what the tools can make again, with --delete).

usage (via bin/vh clean): python tools/clean.py <project> [--yes] [--delete] [--keep path …] [--final path …] [--keep-versions N] [--dry-run]

Without --yes it only lists (a dry run; --dry-run says so, and wins over --yes). What goes, by kind:
  rebuilt   out/frames, out/check (check frames, contact sheets, storyboard tiles, textcheck crops: the check tools make
            them again; a video in it stays, and so do bin/vh check's records, *.check.json), out/proxy (bin/vh proxy and
            thumbs), out/cache (an edit list's chunk cache, bin/vh render), render chunks (.<film>.parts) and patch work
            folders (.<film>.patch),
            node_modules (npm ci brings it back), __pycache__, .venv and venv folders
  versions  the earlier versions of the films kept in out/versions/<id>/ (bin/vh versions), all but the newest
            --keep-versions N of each film (default 0), and folders there no version keeps; the record says where they
            went. The current films are not in there. Whether or not a film is found: the record tells them apart
  renders   video files under out/ that are not the film: drafts, video-only renders, segments, patches (*.mp4 *.mov *.webm
            *.mkv *.m4v *.avi), with their .render.json, .mux.json and .lock beside them. Only once a film is found (below)
  sound     sound files directly in audio/ that are not the narration in use (voiceover.wav, voiceover.<lang>.wav and its
            .raw.wav original, any of wav, mp3, m4a, flac, aac; <lang> like zh, en or zh-CN), not a mix (mix*, *_mix*) and not
            named in any of the project's text files (a page's <audio src>, a timeline, the notes); audio/takes/; and stem
            folders directly in audio/ (*stems*). Sound in other folders under audio/ (samples, a song's source) stays;
            a lyric video's audio/song.mp3 stays when its page names it, as it does when it plays it.
            Only once a film is found
The film: video files in out/final/ (not in a covers or 封面 folder inside it), else out/final*.<video> directly in out/,
media/*.<video>, what --final names (an existing video file, relative to the project or to here), every video under out/
the project names as a deliverable (BRIEF.md's Deliverables line and anywhere in PACKAGING.md: a path from the project, or
a name directly in out/ or out/final/; like --final, naming one is a film found, so the other renders and old takes can
then go), and every copy bin/vh deliver wrote with the master it came from (named by its record,
<copy>.deliver.json, which stays too; a file that is no longer the size or time recorded is said, and kept all the same). Covers and
out/publish/ stay, but do not count as the film. A project with no film found keeps its videos and its sound: name the
film with --final. --keep protects a path, also inside a folder that would otherwise go (the folder is then cleared item
by item around it).
What stays besides: out/review/, every other file in out/ that is not a video, timelines, scripts, src/,
assets/, lookdev/, tools/, the markdown, any folder below the project that is a project of its own (has a BRIEF.md), and
whatever the asset ledger has on record (bin/vh assets; a file moved by hand fails bin/vh assets check: run it after).
A folder directly in out/ that this tool has no word for (out/ch01, out/samples: one the project made) is treated like
the rest of out/, its videos go and its other files stay, and it is listed with what would go and what would stay. So
run it without --yes first, and read the list.
Everything goes to the Trash (macOS: /usr/bin/trash where there is one, which also handles other disks and Put Back, else
~/.Trash; Linux: the freedesktop Trash, refused for an item on another disk); --delete deletes the "rebuilt" kind outright
(the tools make it again). A video is never deleted outright: a mistaken render can come back from the Trash. Refused:
a folder without BRIEF.md, the harness itself (bin/vh, projects/), and a project where a render or a patch holds a live
lock. Nothing outside the project is touched; a symbolic link is removed as a link, never followed. What went to the
Trash frees its space when the Trash is emptied; on macOS, Time Machine's local snapshots can hold deleted data (the
Trash's too, once it is emptied) for a while: `df` may not grow at once.
Exit: 0 listed or cleared · 1 something could not be moved or deleted · 2 not a project, or refused.
"""
import argparse, json, os, re, shutil, subprocess, sys, time
from pathlib import Path

VIDEO = {".mp4", ".mov", ".webm", ".mkv", ".m4v", ".avi"}
SOUND = {".wav", ".mp3", ".m4a", ".aac", ".flac", ".aiff", ".aif", ".ogg", ".opus", ".m4s"}
REBUILT_DIRS = {"node_modules", "__pycache__", ".venv", "venv"}   # not snapshots/: a cover can live there
TEXT = {".json", ".md", ".txt", ".html", ".htm", ".js", ".mjs", ".css", ".py", ".sh", ".srt", ".csv", ".yaml", ".yml", ".toml"}
VOICE = re.compile(r"voiceover(\.[a-z]{2,3}(-[a-z0-9]{2,4})?)?(\.raw)?\.(wav|mp3|m4a|flac|aac)")   # the narration in use
COVERS = {"covers", "cover", "封面"}


def size(p):
    if p.is_symlink() or p.is_file():
        try: return p.lstat().st_size
        except OSError: return 0
    total = 0
    for root, dirs, files in os.walk(p):
        for f in files:
            try: total += (Path(root) / f).lstat().st_size
            except OSError: pass
    return total


def human(n):
    return f"{n / 1e9:.2f} GB" if n >= 1e9 else f"{n / 1e6:.1f} MB" if n >= 1e5 else f"{n / 1e3:.0f} KB"


def low(rel):   # folder names compared as a case-blind disk does
    return tuple(x.casefold() for x in rel.parts)


def dir_kind(rel):
    p = low(rel)
    if p[-1] in REBUILT_DIRS and p[0] not in ("src", "assets"):
        return "rebuilt"
    if p[0] == "out" and (p in (("out", "frames"), ("out", "check"), ("out", "proxy"), ("out", "cache")) or p[-1].endswith(".parts") or p[-1].endswith(".patch")):
        return "rebuilt"
    if p[0] == "audio" and len(p) == 2 and "stems" in p[1]:
        return "sound"
    return None


def walk(root):
    """(folder, relative path, sub-folders, files) for the project, never into a link, .git or a project of its own."""
    for dirpath, dirs, files in os.walk(root):
        d = Path(dirpath); reld = d.relative_to(root)
        for name in list(dirs):
            if name == ".git" or (d / name).is_symlink() or (d / name / "BRIEF.md").exists():
                dirs.remove(name)
        yield d, reld, dirs, files


def subprojects(root):
    """Folders below the project that are projects of their own (a BRIEF.md): kept whole, so a folder that would go and
    holds one (out/check/<a project>) is cleared item by item around it."""
    found = []
    for dirpath, dirs, files in os.walk(root):
        d = Path(dirpath)
        for name in list(dirs):
            if name == ".git" or (d / name).is_symlink():
                dirs.remove(name)
            elif (d / name / "BRIEF.md").exists():
                found.append((d / name).relative_to(root)); dirs.remove(name)
    return found


def mentioned(root):
    """Every sound file name a text file of the project names (an <audio src>, a timeline, a mix command in the notes)."""
    names = set()
    pat = re.compile(r"[\w.\-]+\.(?:wav|mp3|m4a|aac|flac|aiff?|ogg|opus|m4s)\b", re.I)
    for d, reld, dirs, files in walk(root):
        if reld.parts and (low(reld)[0] == "out" or set(low(reld)) & REBUILT_DIRS):
            dirs[:] = []; continue
        for f in files:
            p = d / f
            try:
                if p.suffix.lower() in TEXT and p.stat().st_size < 4_000_000:
                    names |= {m.lower() for m in pat.findall(p.read_text(encoding="utf-8", errors="ignore"))}
            except OSError:
                pass
    return names


def find_film(root, finals):
    """The film's files: --final, else out/final/ (not its covers), else out/final*.<video>, and media/."""
    found = [f for f in finals if f.suffix.lower() in VIDEO and (root / f).is_file()]
    out = root / "out"
    fdir = next((q for q in out.iterdir() if q.is_dir() and q.name.casefold() == "final"), None) if out.is_dir() else None
    if fdir:
        for d, reld, dirs, files in walk(fdir):
            dirs[:] = [x for x in dirs if x.casefold() not in COVERS and not x.endswith((".parts", ".patch"))]
            found += [(d / f).relative_to(root) for f in files if Path(f).suffix.lower() in VIDEO and not f.casefold().startswith("cover")]
    if out.is_dir() and not any(low(x)[:2] == ("out", "final") and len(x.parts) > 2 for x in found):
        found += [p.relative_to(root) for p in out.iterdir() if p.is_file() and p.suffix.lower() in VIDEO and p.name.casefold().startswith("final")]
    if (root / "media").is_dir():
        found += [p.relative_to(root) for p in (root / "media").iterdir() if p.is_file() and p.suffix.lower() in VIDEO]
    return found


def named_deliverables(root):
    """The videos under out/ the project itself names as what it delivers: on BRIEF.md's Deliverables line, anywhere in
    PACKAGING.md (not its comments), as a path from the project or a name directly in out/ or out/final/. Only under out/:
    clean never touches a video elsewhere, and a source a page mentions (footage/raw.mp4) is no film found."""
    said = []
    try:
        said += re.findall(r"^\s*[-*]?\s*Deliverables\s*[:：](.*)$", (root / "BRIEF.md").read_text(encoding="utf-8", errors="ignore"), flags=re.M)
    except OSError:
        pass
    try:
        said.append(re.sub(r"<!--.*?-->", "", (root / "PACKAGING.md").read_text(encoding="utf-8", errors="ignore"), flags=re.S))
    except OSError:
        pass
    got = []
    for name in re.findall(r"[^\s`'\"(){}（）,，、|:：]+\.(?:mp4|mov|webm|mkv|m4v|avi)\b", "\n".join(said), flags=re.I):
        for base in (root, root / "out", root / "out" / "final"):
            q = os.path.normpath(base / name)
            rel = Path(os.path.relpath(q, root))
            if Path(q).is_file() and low(rel)[0] == "out":
                if rel not in got: got.append(rel)
                break
    return got


def on_ledger(root):
    """What the asset ledger has on record, relative to the project: a record's file is not an intermediate, and clearing
    it fails bin/vh assets check. Nothing when the ledger cannot be read (bin/vh assets check says so)."""
    sys.path.insert(0, str(Path(__file__).resolve().parent / "assets"))
    try:
        import ledger
        _, ents, _ = ledger.entries(root, [])
    except Exception:
        return []
    got = []
    for e in ents:
        r = e["record"]
        path = r.get("path")
        if "removed" not in r and isinstance(path, str) and not os.path.isabs(path):
            p = Path(path.rstrip("/"))
            if p.parts and ".." not in p.parts:   # not "." or "./": it would keep the whole project
                got.append(p)
    return got


def own_folders(root, items, sizes):
    """Folders directly in out/ this tool has no word for, the project's own: [(folder, its size, what of it would go)]."""
    out = root / "out"
    if not out.is_dir():
        return []
    known = {"frames", "check", "proxy", "cache", "review", "publish", "versions", "final"} | COVERS
    rows = []
    for q in sorted(out.iterdir()):
        if q.is_dir() and not q.is_symlink() and q.name.casefold() not in known and not q.name.endswith((".parts", ".patch")) and not (q / "BRIEF.md").exists():
            rows.append((q, size(q), sum(sizes[p] for _, p in items if q in p.parents)))
    return rows


def deliveries(root):
    """bin/vh deliver's records (<copy>.deliver.json): [(record, [files], [notes])], the files (the copy, the master it
    came from) relative to the project, those that are in it; a note for one missing or not what the record says."""
    got = []
    for d, reld, dirs, files in walk(root):
        dirs[:] = [x for x in dirs if x.casefold() not in REBUILT_DIRS]
        for f in sorted(files):
            if not f.endswith(".deliver.json"):
                continue
            rec, keep, notes = reld / f, [], []
            try:
                j = json.loads((d / f).read_text(encoding="utf-8"))
                pairs = [("the copy", j.get("output") or f[:-len(".deliver.json")], j.get("size"), j.get("mtime")),
                         ("its master", j.get("master"), j.get("master_size"), j.get("master_mtime"))]
            except (OSError, ValueError, AttributeError):   # unreadable: keep the copy its file name names, to be safe
                guess = reld / f[:-len(".deliver.json")]
                kept = [guess] if (root / guess).is_file() else []
                got.append((rec, kept, ["not a record bin/vh deliver can read; " + ("the copy its name names stays" if kept else "no file of its name is here")
                                        + ", and its master is not known: deliver again to write it anew"])); continue
            for what, name, n, mt in pairs:
                if not isinstance(name, str) or not name:
                    continue
                rel = Path(os.path.relpath(os.path.normpath(d / name), root))   # not resolved: a link stays a link
                if str(rel).startswith(".."):
                    continue   # a master outside the project: not this project's to keep or clear
                q = root / rel
                if not q.is_file():
                    notes.append(f"{what} {rel} is gone"); continue
                keep.append(rel)
                st = q.stat()
                if st.st_size != n or not isinstance(mt, (int, float)) or abs(st.st_mtime - mt) > 1:
                    notes.append(f"{what} {rel} is not the file recorded (its size or time changed since)" +
                                 (": the copy may be from an older master; deliver again if it should follow" if what == "its master" else ": kept all the same"))
            got.append((rec, keep, notes))
    return got


def candidates(root, film, keeps):
    """[(kind, path)] of what can go; a folder stands for everything in it, unless something to keep is inside it."""
    out = []
    film_set = {low(f) for f in film}
    keep_set = {low(k) for k in keeps} | film_set   # compared case-blind, as the disk does
    def kept(rel): return any(low(rel)[:len(k)] == k for k in keep_set)
    def holds(rel): return any(len(k) > len(rel.parts) and k[:len(rel.parts)] == low(rel) for k in keep_set)
    said = mentioned(root) if film else set()
    inside = {}   # a folder that would go but holds something to keep: its files go one by one, as this kind
    for d, reld, dirs, files in walk(root):
        if low(reld) == ("out", "versions"):   # the earlier versions: versions_to_go() decides, from their record
            dirs[:] = []; continue
        kind_here = next((inside[q] for q in [reld, *reld.parents] if q in inside), None)
        for name in sorted(dirs):
            rel = reld / name
            if kept(rel):
                dirs.remove(name); continue
            kind = kind_here or dir_kind(rel)
            if kind == "sound" and not film:
                continue
            if kind and not holds(rel):
                out.append((kind, d / name)); dirs.remove(name)
            elif kind:
                inside[rel] = kind
        for name in sorted(files):
            rel, ext, n = reld / name, Path(name).suffix.lower(), name.lower()
            if not rel.parts or kept(rel):
                continue
            top = low(rel)[0]
            if kind_here:
                if kind_here != "sound" or film: out.append((kind_here, d / name))
            elif not film:
                continue
            elif top == "out" and ext in VIDEO:
                if not set(low(rel)[1:-1]) & ({"review", "check", "publish"} | COVERS) and not n.startswith("cover"):
                    out.append(("renders", d / name))
            elif top == "audio" and ext in SOUND and n not in said:
                direct = len(rel.parts) == 2
                if (direct and not (VOICE.fullmatch(n) or n.startswith("mix") or "_mix" in n or "-mix" in n)) or low(rel)[1] == "takes":
                    out.append(("sound", d / name))
    gone = {p for k, p in out if k == "renders"}   # a render's sidecar and lock go with it (a mux's record too)
    for p in list(gone):
        for suf in (".render.json", ".mux.json", ".lock"):
            q = p.with_name(p.name + suf)
            if q.exists() and not kept(q.relative_to(root)): out.append(("renders", q))
    return out


def versions_to_go(root, keep_n, keeps):
    """The earlier versions kept in out/versions/<id>/ (bin/vh versions) that can go: every kept one but the newest keep_n
    of each film, and folders no version of the record keeps (an earlier film all the same). The current films are not in
    there. → ([folders], note): nothing, with a note, when the record cannot be read."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import versions as V
    d = V.store(root)
    if not d.is_dir():
        return [], None
    try:
        L = V.listing(root)
    except ValueError as e:
        return [], f"{e}: out/versions stays as it is"
    kept = [v for v in L["versions"] if v["state"] == "kept"]
    stay = set()
    for film in {v["film"] for v in kept}:
        stay |= {v["id"] for v in [x for x in kept if x["film"] == film][::-1][:keep_n]}
    keep_set = {low(k) for k in keeps}
    out = []
    for q in sorted(d.iterdir()):
        if not q.is_dir() or q.is_symlink() or not re.fullmatch(r"v\d+", q.name) or q.name in stay:
            continue
        rel = q.relative_to(root)
        if any(low(rel)[:len(k)] == k or k[:len(low(rel))] == low(rel) for k in keep_set):
            continue
        out.append(q)
    return out, None


def live_locks(root):
    """Locks a running render or patch holds (bin/vh render: <film>.lock; bin/vh patch: <out>.patch.lock)."""
    held = []
    for d, reld, dirs, files in walk(root):
        if reld.parts and low(reld)[0] == "node_modules":
            dirs[:] = []; continue
        for f in files:
            if not f.endswith(".lock"):
                continue
            try: pid = int((d / f).read_text().strip() or 0)
            except (OSError, ValueError): continue
            if pid <= 0:
                continue
            try:
                os.kill(pid, 0); held.append(((d / f).relative_to(root), pid))
            except PermissionError:
                held.append(((d / f).relative_to(root), pid))
            except OSError:
                pass
    return held


def to_trash(p):
    """Into the Trash. OVH_TRASH_DIR (tests) is a folder to move into; macOS uses /usr/bin/trash where it exists. A link
    holds no data and its target may be outside the project: it is only unlinked."""
    if p.is_symlink():
        p.unlink(); return
    test = os.environ.get("OVH_TRASH_DIR")
    if not test and sys.platform == "darwin" and Path("/usr/bin/trash").exists():
        r = subprocess.run(["/usr/bin/trash", str(p)], capture_output=True, text=True)
        if r.returncode or os.path.lexists(p):
            raise OSError((r.stderr or r.stdout or f"exit {r.returncode}").strip())
        return
    if test:
        files = Path(test); files.mkdir(parents=True, exist_ok=True); info = None
    elif sys.platform == "darwin":
        files = Path.home() / ".Trash"; info = None
    else:
        tdir = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share") / "Trash"
        files, info = tdir / "files", tdir / "info"
        files.mkdir(parents=True, exist_ok=True); info.mkdir(parents=True, exist_ok=True)
    name, k = p.name, 1
    while os.path.lexists(files / name) or (info and (info / f"{name}.trashinfo").exists()):
        k += 1; name = f"{p.stem} {k}{p.suffix}" if p.is_file() else f"{p.name} {k}"
    if os.stat(p.parent).st_dev != os.stat(files).st_dev:
        raise OSError(f"the Trash is on another disk; move {p.name} yourself")
    if info:
        from urllib.parse import quote
        (info / f"{name}.trashinfo").write_text(f"[Trash Info]\nPath={quote(str(p))}\nDeletionDate={time.strftime('%Y-%m-%dT%H:%M:%S')}\n")
    os.rename(p, files / name)


def local_snapshots():
    """How many Time Machine local snapshots macOS holds on / (0 where there is no tmutil)."""
    try:
        r = subprocess.run(["tmutil", "listlocalsnapshots", "/"], capture_output=True, text=True)
    except OSError:
        return 0
    return len([ln for ln in r.stdout.splitlines() if "com.apple" in ln]) if r.returncode == 0 else 0


def remove(p, root):
    if root not in p.parents:   # never outside the project
        raise OSError(f"{p} is not inside {root}")
    if p.is_symlink() or p.is_file():
        p.unlink()
    else:
        shutil.rmtree(p)


def main():
    ap = argparse.ArgumentParser(prog="bin/vh clean", usage="bin/vh clean <project> [--yes] [--delete] [--keep path …] [--final path …] [--keep-versions N] [--dry-run]")
    ap.add_argument("project")
    ap.add_argument("--keep-versions", type=int, default=0, metavar="N", help="keep the newest N earlier versions of each film in out/versions (default 0)")
    ap.add_argument("--yes", action="store_true", help="clear them; without it, only list (a dry run)")
    ap.add_argument("--dry-run", action="store_true", help="only list, even with --yes")
    ap.add_argument("--delete", action="store_true", help="delete what the tools make again (frames, check frames, chunks, node_modules) instead of the Trash")
    ap.add_argument("--keep", action="append", default=[], help="a path in the project to keep (repeatable)")
    ap.add_argument("--final", action="append", default=[], help="the film's file, when it is not in out/final/, out/final*.*, or media/")
    a = ap.parse_args()
    root = Path(a.project).resolve()
    if not (root / "BRIEF.md").is_file():
        print(f"clean: {a.project} is not a project folder (no BRIEF.md)", file=sys.stderr); sys.exit(2)
    if (root / "bin" / "vh").exists() or (root / "projects").is_dir():
        print(f"clean: {a.project} is the harness (or holds projects), not one project", file=sys.stderr); sys.exit(2)

    def inproj(x):   # relative to the project first, else to here
        q = Path(x)
        q = q if q.is_absolute() else (root / q if os.path.lexists(root / q) else Path.cwd() / q)
        r = Path(os.path.relpath(q.resolve(), root))
        if str(r).startswith(".."):
            print(f"clean: {x} is not inside the project", file=sys.stderr); sys.exit(2)
        return r
    keeps = [inproj(k) for k in a.keep]
    finals = [inproj(f) for f in a.final]
    for f in finals:
        if f.suffix.lower() not in VIDEO or not (root / f).is_file():
            print(f"clean: --final {f}: not a video file in the project", file=sys.stderr); sys.exit(2)
    locks = live_locks(root)
    if locks:
        print("clean: something is writing in the project: " + ", ".join(f"{p} (pid {pid})" for p, pid in locks) + "; wait for it", file=sys.stderr)
        sys.exit(2)
    found = find_film(root, finals)
    named = named_deliverables(root)
    sent = deliveries(root)
    seen = set()   # the film: what was found or named, and every delivered copy and its master, each once (case-blind, as the disk)
    film = [f for f in found + named + [f for _, fs, _ in sent for f in fs] if not (low(f) in seen or seen.add(low(f)))]
    # out/check goes as rebuilt (check frames), a video in it does not: the check tools write none, so it is someone's
    out = root / "out"
    chk = next((q for q in out.iterdir() if q.name.casefold() == "check" and q.is_dir() and not q.is_symlink()), None) if out.is_dir() else None
    keep_vid = [(d / f).relative_to(root) for d, _, _, fs in walk(chk) for f in fs if Path(f).suffix.lower() in VIDEO] if chk else []
    keep_rec = sorted((d / f).relative_to(root) for d, _, _, fs in walk(chk) for f in fs if f.endswith(".check.json")) if chk else []   # what the film was checked for
    own = subprojects(root)
    ledgered = on_ledger(root)
    items = candidates(root, film, keeps + film + [r for r, _, _ in sent] + keep_vid + keep_rec + own + ledgered)
    if a.keep_versions < 0:
        print("clean: --keep-versions N: a number ≥ 0", file=sys.stderr); sys.exit(2)
    vgo, vnote = versions_to_go(root, a.keep_versions, keeps + film + [r for r, _, _ in sent])
    items += [("versions", q) for q in vgo]
    sizes = {p: size(p) for _, p in items}
    total = sum(sizes.values())
    doing = a.yes and not a.dry_run
    say = {"rebuilt": "made again by the tools", "renders": "renders that are not the film", "sound": "sound not in use",
           "versions": "earlier versions of the films, bin/vh versions" + (f"; the newest {a.keep_versions} of each stay" if a.keep_versions else "; --keep-versions N keeps some")}
    print(f"clean: {root.name} · {human(size(root))} now · {len(items)} item(s), {human(total)} " + ("to clear" if doing else "would go (a dry run: --yes clears them)"))
    if found:
        print("  the film: " + ", ".join(str(f) for f in found[:6]) + (" …" if len(found) > 6 else ""))
    for r, fs, notes in sent:   # each delivery stays as the film, with why
        print(f"  delivered (bin/vh deliver's record {r} stays, and what it names): " + (", ".join(str(f) for f in fs) or "nothing left in the project"))
        for n in notes:
            print(f"    ! {n}")
    if named:
        print("  named as deliverables (BRIEF.md's Deliverables, PACKAGING.md): " + ", ".join(str(f) for f in named[:6]) + (" …" if len(named) > 6 else ""))
    in_out = [k for k in ledgered if low(k)[0] == "out"]
    if in_out:
        print("  on the asset ledger, stays (better under assets/): " + ", ".join(str(f) for f in in_out[:6]) + (" …" if len(in_out) > 6 else ""))
    if own:
        print("  projects of their own inside, kept whole: " + ", ".join(str(f) for f in own[:6]) + (" …" if len(own) > 6 else ""))
    if keep_vid:
        print("  stays in out/check (a video, not a check frame): " + ", ".join(str(f) for f in keep_vid[:6]) + (" …" if len(keep_vid) > 6 else ""))
    if keep_rec:
        print("  stays in out/check (bin/vh check's records): " + ", ".join(str(f) for f in keep_rec[:6]) + (" …" if len(keep_rec) > 6 else ""))
    if not film:
        print("  no film found (out/final/, out/final*.<video>, media/, bin/vh deliver's records): its videos and sound stay; name the film with --final <file> to clear them"
              + (" (the earlier versions below are told apart by their record)" if vgo else ""))
    if vnote:
        print(f"  ! {vnote}")
    for kind in ("rebuilt", "renders", "sound", "versions"):
        xs = [p for k, p in items if k == kind]
        if not xs:
            continue
        where = "deleted" if a.delete and kind == "rebuilt" else "to the Trash"
        print(f"  {kind} ({say[kind]}; {where}): {human(sum(sizes[p] for p in xs))}")
        for p in sorted(xs, key=lambda q: -sizes[q])[:25]:
            print(f"    {human(sizes[p]):>9}  {p.relative_to(root)}{'/' if p.is_dir() and not p.is_symlink() else ''}")
        if len(xs) > 25:
            print(f"    … {len(xs) - 25} more")
        if kind == "renders" and not doing:
            print("    a deliverable among these? name it on BRIEF.md's Deliverables line or in PACKAGING.md, or --final <file>")
    rows = own_folders(root, items, sizes)
    if rows:
        print("  in out/ and not known to clean, the project's own: look before clearing (their videos go as renders, the other files stay)")
        for q, n, gone in sorted(rows, key=lambda x: -x[1])[:25]:
            print(f"    {human(n):>9}  {q.relative_to(root)}/  {human(gone)} would go, {human(n - gone)} would stay")
        if len(rows) > 25:
            print(f"    … {len(rows) - 25} more")
    if not doing:
        sys.exit(0)
    failed, trashed, deleted, vgone = 0, 0, 0, []
    for kind, p in items:
        try:
            if a.delete and kind == "rebuilt":
                remove(p, root); deleted += sizes[p]
            elif kind == "versions":   # named for the project in the Trash ("<project> v2"), its record told
                named = p.with_name(f"{root.name} {p.name}")
                os.replace(p, named)
                try:
                    to_trash(named)
                except OSError:
                    os.replace(named, p); raise
                trashed += sizes[p]; vgone.append(p)
            else:
                to_trash(p); trashed += sizes[p]
        except OSError as e:
            failed += 1; print(f"  ✗ {p.relative_to(root)}: {e}")
    if vgone:
        import versions as V
        V.mark_trashed(root, vgone, "bin/vh clean")
    print(f"clean: {human(deleted)} deleted, {human(trashed)} moved to the Trash" + (f", {failed} could not be cleared" if failed else "") +
          f"; {root.name} is {human(size(root))} now")
    n = local_snapshots() if deleted or trashed else 0
    if trashed:   # no space is back for it yet: that happens when the Trash is emptied, and the snapshots can hold it after that
        print("  what went to the Trash frees its space when the Trash is emptied (that is yours to do)")
    if n and deleted:   # what was deleted outright is held by the snapshots now; a run that also trashed says the Trash's will be too
        print(f"  Time Machine holds {n} local snapshot(s): data deleted since the last one stays on the disk until macOS drops them"
              + (", the Trash's too once it is emptied" if trashed else "") + " (hours; sooner when space runs short)")
    elif n:
        print(f"  and Time Machine's {n} local snapshot(s) can still hold it on the disk after that, until macOS drops them (hours; sooner when space runs short)")
    if (root / "assets" / "ledger.json").is_file() and (trashed or deleted):
        print(f"  then bin/vh assets check {a.project}: what the ledger names has to be there still")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
