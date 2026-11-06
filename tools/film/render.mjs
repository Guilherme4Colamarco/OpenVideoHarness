// render: a page's film to an MP4 through the page contract (engines/CONTRACT.md), for the engines that are web pages
// and have no renderer of their own (the canvas engine; ClaudeAnimationBase also works, its render.mjs stays the
// documented path). Every frame of the span is drawn at t = k / fps and captured as JPEG (or PNG with --png). The span
// is cut into chunks of one GOP each; --workers browsers take the next chunk as they finish one (a slow chapter does not
// hold the others up), each chunk piped into an x264 of its own; the chunks are joined without re-encoding. Video only:
// put the sound on with bin/vh mux.
//
// usage: node tools/film/render.mjs <project | page.html> --browser <chrome> [--out out/film.mp4] [--fps 30]
//          [--range a:b | --frames k0:k1] [--dpr 1] [--workers 4] [--crf 16] [--preset medium] [--gop 60] [--png] [--quality 95] [--alpha]
//          [--motion-blur N [--shutter 0.5]] [--frame-timeout 120] [--estimate | --no-estimate] [--note text] [--force] [--real-clock]
//          [--soft-gl] [--fresh] [--cache-max 10]
//        (bin/vh render finds the browser: CHROME_PATH, HyperFrames' chrome-headless-shell, then Chrome or Chromium)
//
//   --out          default <project>/out/<page>.mp4. A relative path is from the current folder, as every bin/vh path
//                  is (said when that puts the video outside the project); a lock file beside it stops a second render
//                  of the same file
//   --fps 30       the frame rate drawn. A page that gives its own (window.film.fps; canvas-film's FILM.fps, which steps
//                  its grain once a frame) is told apart when the two differ
//   --range a:b    only that span: the frames shown from a up to b seconds (frame k when a ≤ k / fps < b, as patch
//                  --seconds counts them); default the whole film
//   --frames k0:k1 only frames k0 up to k1 (k1 left out), frame k drawn at k / fps: exact, for bin/vh patch
//   --dpr 2        twice the pixels (4K for a 1920x1080 page)
//   --gop 60       a keyframe every 60 frames exactly, from the span's first frame (default 2 s of frames). Each chunk is
//                  one GOP, so a later patch can cut the video on keyframes, and the video does not depend on --workers
//   --png          lossless frames into the encoder (slower, larger pipes); default JPEG at --quality 95
//   --alpha        a transparent film, to lay over footage or into an editor: the browsers' default background is made
//                  transparent, the frames are captured as PNG with their alpha, and the video is ProRes 4444 with alpha
//                  (prores_ks at a fixed quantizer, yuva444p10le, an 8-bit alpha, BT.709 tags) in a .mov (default
//                  <project>/out/<page>.mov). What the page paints stays opaque, so a page that fills its canvas has nothing
//                  to show through: it is said. Large: about 1–8 bits a pixel. A HyperFrames composition: npx hyperframes render --format mov
//   --motion-blur 8  N from 1 to 64: each frame the mean of N sub-frames, the page drawn at N times spread over --shutter
//                  (a fraction of a frame, more than 0 and at most 1; default 0.5: a 180° shutter) centred on the frame's
//                  own time, so what moves is blurred along its path and what holds still (a caption riding the camera)
//                  stays sharp. N about the fastest speed in px a frame × the shutter ÷ 2 keeps neighbouring sub-frames
//                  within about 2 px (else a fast edge shows steps); 4–8 for most moves. The shutter is cut short where the
//                  frame's picture ends: the film's start and end, an edit list's entry (every cut there), and the
//                  boundaries of the page's own shots (window.film.shots), so a hard cut stays a cut; a frame there gets
//                  the shutter on its own side only, half the smear. Each sub-frame's time comes from the frame's number,
//                  N and the shutter alone (tools/film/blur.mjs): a frame drawn again (a resume, a patch, a later render)
//                  is the same picture. The mean is ffmpeg's tmix in the frames' own sRGB values, premultiplied with
//                  --alpha. Grain a page seeds by the frame's number (canvas-film steps it once a frame) stays as it is;
//                  seeded by the continuous t it is averaged away. A page that blurs itself (sub-frames accumulated in
//                  WebGL, the components library's motionBlur() or whip()) is not to be blurred again. In an edit list the
//                  pages and the images that move are blurred; slates, colours, still images and footage are not. N times
//                  the drawing, and more memory: each encoder holds N frames and the browser's N pictures wait for it
//                  (measured, 4K at 8: 0.3 GB more a worker with JPEG, 0.9 GB with --png or --alpha); the render says what
//                  its N, workers and size come to, and does not stop for it. 1: no blur, the render as without it, byte
//                  for byte. The sidecar records it (motion_blur, with blur.mjs's sha256), bin/vh patch draws its frames
//                  the same way, and it is in an edit list's chunk keys. A page that rounds t to its own frames
//                  (HyperFrames' seek) draws one picture N times: it is said. bin/vh frames --motion-blur shows a frame
//                  the same way first
//   --estimate     before a span of more than 600 frames to draw (--motion-blur's sub-frames counted; --estimate: any
//                  span), a few frames spread over it are drawn and encoded first: the time a frame takes, the video's
//                  size and the disk it needs are printed, and a disk that cannot hold it stops the render (exit 2). A
//                  few seconds; --no-estimate skips it
//   --force        render a HyperFrames composition this way too (by default: use npx hyperframes render, the measured path)
//   --frame-timeout 120  a frame not drawn in this many seconds fails the render (the finished chunks are kept). Each
//                  browser's page may take as long to set window.film and to be ready (at least 30 s and 120 s a wait;
//                  OVH_PAGE_TIMEOUT=S sets those alone, tools/film/host.mjs)
//   --note text    a line for this version in the project's record (bin/vh versions)
//   --fresh        draw every chunk again: none kept from a stopped render, none taken from an edit list's chunk cache (the
//                  new ones are kept in it)
//   --cache-max 10 an edit list's chunk cache, <project>/out/cache/chunks, in GB: a finished chunk is kept there under its
//                  key (what its frames are made from: the run's drawing, their place in it, the settings, the browser
//                  for what a browser draws, the ffmpeg and these tools) with the files its page was sent, and a later
//                  render takes it instead of drawing it while that key is the same and those files are the same bytes:
//                  change one entry and only its chunks are drawn again. After a render the chunks used longest ago go
//                  first past this size; 0: no cache. bin/vh clean clears it (it is made again)
//
// The colour: Chrome's frames are full-range RGB; the encode converts them to limited-range BT.709 with all four colour
// tags (what bin/vh check expects). Beside the video, <out>.render.json records how it was made (size, fps, frames,
// span, encoder settings, chunks, browser), for a later patch or re-render to match. Exit: 0 rendered and checked ·
// 1 a frame failed, the encoder stopped, or the result has the wrong frame count or colour tags; also when the page
// reported an error while drawing (the video is written then, and the errors are listed) · 2 could not start.
// Stopped (Ctrl-C or SIGTERM: exit 130, 143) or failed, a render keeps the chunks it finished in .<out>.parts beside
// the video: the same command again draws only the rest, while the page and every file it loaded, the options that shape
// the video (all but --workers, --frame-timeout and the estimate), the browser and these tools are unchanged; anything
// else changed, it says what and starts over. A chunk in which the page reported an error is never kept; in an edit list,
// none of that page's chunks go into the chunk cache in that render.
// Before drawing it checks the disk the render needs at its peak (the chunks it draws and the joined copy; on a resume,
// the chunks left and the joined copy, kept chunks included): it stops (exit 2) when even a flat film would not fit; the
// estimate above measures it. Its glyph check covers the frames it draws: on a resume it says the kept ones were not.
// A video inside a project is a version of its film (tools/versions.py, bin/vh versions): the film it replaces at that
// path is kept in out/versions/ first (while the disk can hold it; else it goes to the Trash, said), and the record gets
// the new one. The sidecar also keeps the page's shots and chapters (window.film.shots, chapters) when it gives them, and
// `files`: every file in the page's folder a browser of this render was sent and its sha256 (what a resume compares; the
// host's own scripts, outside the folder, stay in plan.json alone), by its path from that folder, null for one that could
// not be read; bin/vh assets check compares it with the project's ledger.
// bin/vh patch draws its frames through this tool with OVH_RENDER_PIECE=1: a piece of a patch is a step, so it ends without
// the "render: done" line (the patch's own last line says the job is done).
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { openFilm } from "./host.mjs";
import { HOOK, check as checkGlyphs, collectDom, merge as mergeGlyphs, report as glyphReport } from "./glyphs.mjs";
import { note as activityNote, progress as activityProgress } from "./activity.mjs";   // the project's activity log (bin/vh activity)
import { commit } from "./versions.mjs";                                                 // the project's versions (bin/vh versions)
import { frameFrom } from "./timegrid.mjs";                                              // seconds to frames (tools/timegrid.py)
import { concatChunks } from "./join.mjs";                                               // the chunks joined, one DTS step a frame
import { EditFilm, allFacts, build as buildEdit, chaptersOf, chunkKey, clipIndex, decodeArgs, editProject, openEdit, pageShort, shotsOf, timeSourceProblems } from "./edit.mjs";   // edit lists (engines/EDIT.md)
import { CACHE, ChunkCache } from "./cache.mjs";                                         // an edit list's chunk cache
import { MAX_SAMPLES, blurs, meanFilter, offsets, pageBounds, runBounds } from "./blur.mjs";   // --motion-blur's sub-frames

process.stdout.on("error", (e) => { if (e.code !== "EPIPE") throw e; });
const HERE = path.dirname(new URL(import.meta.url).pathname);
const HELP = fs.readFileSync(new URL(import.meta.url), "utf8").split("\nimport ")[0].replace(/^\/\/ ?/gm, "");
const argv = process.argv.slice(2);
if (!argv.length || argv.includes("-h") || argv.includes("--help")) { process.stdout.write(HELP.trimEnd() + "\n"); process.exit(argv.length ? 0 : 2); }
const die = (msg) => { console.error("render: " + msg); process.exit(2); };
const o = { fps: 30, dpr: 1, workers: 4, crf: 16, preset: "medium", quality: 95, frameTimeout: 120, estimate: "auto", fresh: false, cacheMax: 10, blur: 1, shutter: 0.5 };
let target = null, out = null, range = null, frames = null, gop = null, png = false, force = false, fpsGiven = false, note = null, alpha = false, shutterGiven = false;
for (let i = 0; i < argv.length; i++) {
  const a = argv[i], [k, inline] = a.startsWith("--") && a.includes("=") ? [a.slice(0, a.indexOf("=")), a.slice(a.indexOf("=") + 1)] : [a, undefined];
  const val = () => { const v = inline !== undefined ? inline : argv[++i]; if (v === undefined) die(`${k} needs a value`); return v; };
  const num = (v, what, min) => { const x = Number(v); if (v === "" || !Number.isFinite(x) || x < min) die(`${what}: ${JSON.stringify(v)} is not a number ≥ ${min}`); return x; };
  if (k === "--out") out = val();
  else if (k === "--range") { range = val().split(":").map((v) => num(v, "--range", 0)); if (range.length !== 2 || range[1] <= range[0]) die("--range a:b, b > a"); }
  else if (k === "--frames") { frames = val().split(":").map((v) => num(v, "--frames", 0)); if (frames.length !== 2 || !frames.every(Number.isInteger) || frames[1] <= frames[0]) die("--frames k0:k1, whole frame numbers, k1 > k0"); }
  else if (k === "--fps") { o.fps = num(val(), k, 1); fpsGiven = true; }
  else if (k === "--dpr") o.dpr = num(val(), k, 0.25);
  else if (k === "--workers") o.workers = Math.floor(num(val(), k, 1));
  else if (k === "--crf") o.crf = num(val(), k, 0);
  else if (k === "--preset") o.preset = val();
  else if (k === "--gop") gop = Math.floor(num(val(), k, 1));
  else if (k === "--quality") o.quality = Math.min(100, Math.floor(num(val(), k, 1)));
  else if (k === "--frame-timeout") o.frameTimeout = num(val(), k, 1);
  else if (k === "--estimate" || k === "--no-estimate") { const e = k === "--estimate" ? "on" : "off"; if (o.estimate !== "auto" && o.estimate !== e) die("--estimate or --no-estimate, not both"); o.estimate = e; }
  else if (k === "--png") png = true;
  else if (k === "--alpha") { alpha = true; png = true; }
  else if (k === "--motion-blur") { o.blur = num(val(), k, 1); if (!Number.isInteger(o.blur) || o.blur > MAX_SAMPLES) die(`--motion-blur: a whole number of sub-frames a frame, 1 to ${MAX_SAMPLES} (1: no blur)`); }
  else if (k === "--shutter") { o.shutter = num(val(), k, 0); shutterGiven = true; if (!(o.shutter > 0 && o.shutter <= 1)) die("--shutter: a fraction of a frame, more than 0 and at most 1 (0.5: a 180° shutter)"); }
  else if (k === "--note") note = val();
  else if (k === "--force") force = true;
  else if (k === "--browser") o.browser = val();
  else if (k === "--real-clock") o.realClock = true;
  else if (k === "--soft-gl") o.softGl = true;
  else if (k === "--fresh") o.fresh = true;
  else if (k === "--cache-max") o.cacheMax = num(val(), k, 0);
  else if (k.startsWith("-")) die(`unknown option ${k} (-h for the options)`);
  else if (target) die(`one project or page, got ${target} and ${a}`);
  else target = a;
}
if (!target) die("which project or page? (-h for the usage)");
if (range && frames) die("--range or --frames, not both");
if (shutterGiven && !argv.some((a) => a === "--motion-blur" || a.startsWith("--motion-blur="))) die("--shutter goes with --motion-blur N: the sub-frames it spreads");
// --motion-blur N: the shutter's sub-frames a frame (tools/film/blur.mjs); 1 is no blur, drawn exactly as without it
const BLUR = o.blur > 1 ? { samples: o.blur, shutter: o.shutter } : null;
if (out && fs.existsSync(out) && fs.statSync(out).isDirectory()) die(`--out ${out} is a folder: name the video file (…/film.mp4)`);
if (out && !/\.(mp4|mov)$/i.test(out)) die(`--out ${out}: the video file, .mp4 (or .mov)`);
if (alpha && out && !/\.mov$/i.test(out)) die(`--out ${out}: --alpha writes ProRes 4444 with its alpha, which goes in a .mov`);
if (!o.browser) die("no browser: pass --browser <chrome>, or run it as bin/vh render");
for (const tool of ["ffmpeg", "ffprobe"]) if (spawnSync(tool, ["-version"]).status !== 0) die(`${tool} is not installed`);

const rel = (f) => { const r = path.relative(process.cwd(), f); return r && !r.startsWith("..") ? r : f; };
// an edit list (engines/EDIT.md): built first, every time; its pages read once for what the sidecar keeps and what they
// must hold to (long enough for their entries, the same narration as the edit list); the frame rate and size are its own
const editRoot = editProject(target);
let doc = null, facts = {}, spanK = null;
if (editRoot) {
  if (alpha) die("--alpha draws one page with the alpha it leaves; an edit list's images, colours and slates are opaque, so its film has none: render the page that leaves its background clear with --alpha");
  try { doc = buildEdit(editRoot); } catch (e) { die(e.message.replace(/^edit: /, "")); }
  if (fpsGiven && o.fps !== doc.fps) die(`--fps ${o.fps}: the edit list's film runs at ${doc.fps} fps (edit.json's fps): its cuts are in its frames`);
  o.fps = doc.fps;
  const runs = doc.runs, src = (r) => (r.draw === "slate" ? null : r.src);
  for (let i = 1; i < runs.length; i++) {
    const e = doc.entries[i];
    if (e.transition_draw && src(runs[i - 1]) !== null && src(runs[i]) !== null)
      die(`${e.id}: a transition (${e.transition.type} ${e.transition.duration} s) is not drawn yet: leave it out for a hard cut (one next to a slate is drawn as a hard cut)`);
  }
  // the frames drawn (--frames, --range): a render of a span (a piece of a patch) reads only the pages it draws
  spanK = frames ? [frames[0], Math.min(frames[1], doc.frames)] : range ? [frameFrom(range[0], doc.fps), range[1] >= doc.frames / doc.fps ? doc.frames : frameFrom(range[1], doc.fps)] : [0, doc.frames];
  const drawnSrc = new Set(runs.filter((r) => r.frames[0] < spanK[1] && r.frames[1] > spanK[0]).map((r) => r.src));
  try { facts = await allFacts(editRoot, doc, { ...o, runtime: "auto" }, drawnSrc); } catch (e) { die(e.message); }
  const bad = [];
  for (const r of runs.filter((x) => x.draw === "page" && drawnSrc.has(x.src))) {
    const f = facts[r.src] || {};
    if (f.error) { bad.push(`${r.entry} (${r.path}): ${f.error}`); continue; }
    const short = pageShort(r, f.duration, doc.fps);
    if (short !== null) bad.push(`${r.entry}: ${r.path} is ${f.duration} s long and the entry's last frame is at ${short.toFixed(3)} s of it: shorten the entry, or "hold": true to hold its last frame`);
  }
  bad.push(...timeSourceProblems(doc, facts));
  if (bad.length) die(`the edit list's pages:\n  ${bad.join("\n  ")}`);
}
// the glyph check of each page, as an edit list's worker closes it (a single page's: when its worker is done)
const glyphs = [], editFilms = [];   // editFilms: an edit list's, one a worker (what their pages loaded goes in the sidecar)
let failed = null;
const glyphCheck = async (film) => {
  if (failed) return;
  let timer;
  try { glyphs.push(await Promise.race([(async () => { await collectDom(film); return checkGlyphs(film); })(), new Promise((_, no) => { timer = setTimeout(() => no(new Error("it did not finish within 60 s")), 60000); })])); }
  catch (e) { glyphs.push({ error: e.message }); }
  finally { clearTimeout(timer); }
};
let first;
try { first = editRoot ? await openEdit(editRoot, { ...o, doc, span: spanK, prelude: [HOOK], onRetire: glyphCheck, beforeReload: glyphCheck }) : await openFilm(target, { ...o, runtime: "auto", prelude: [HOOK], beforeReload: glyphCheck }); } catch (e) { die(e.message); }
if (editRoot) editFilms.push(first);
if (first.kind === "hyperframes" && !force) {
  await first.close();
  die("this is a HyperFrames composition: render it with npx hyperframes render (its renderer is the path this repo measured)" +
    (alpha ? "; transparent: npx hyperframes render --format mov (ProRes 4444)" : "") + "; --force renders it through the page contract anyway");
}
if (!(first.duration > 0)) { await first.close(); die("the page gives no duration"); }
// the frame rate the page is made for: window.film.fps (engines/CONTRACT.md), else canvas-film's settings in a copy made
// before the engine gave it (an edit list's pages: each one's own, said when it is not the edit list's)
let pageFps = null;
if (!editRoot) try { pageFps = +(await first.field("fps")) || +(await first.ev('typeof FILM === "object" && FILM && Number(FILM.fps) || 0', "reading FILM.fps")) || null; } catch { /* none */ }
// the page's shots and chapters, for the sidecar: what bin/vh patch names and bin/vh thumbs picks a frame for (an edit
// list: its entries, then the shots inside its pages, in the film's seconds)
const listOf = async (name) => { if (editRoot) return null; try { const x = await first.field(name); return Array.isArray(x) ? x : null; } catch { return null; } };
const fin = (x) => Number.isFinite(x);
const pageShots = editRoot ? shotsOf(doc, facts).map(({ kind, ...s }) => s) : ((await listOf("shots")) || []).filter((x) => x && fin(+x.start) && fin(+x.end) && +x.end > +x.start).map((x, i) => ({
  id: String(x.id ?? `S${String(i + 1).padStart(2, "0")}`), start: +x.start, end: +x.end,
  ...(x.transition && fin(+x.transition.duration) && +x.transition.duration > 0 ? { transition: +x.transition.duration } : {}) }));
const pageChapters = editRoot ? chaptersOf(doc, facts) : ((await listOf("chapters")) || []).filter((x) => x && fin(+x.t)).map((x) => ({ t: +x.t, title: String(x.title ?? ""), ...(x.id != null ? { id: String(x.id) } : {}) }));
const fps = o.fps, last = editRoot ? doc.frames : frameFrom(first.duration, fps);   // the film's frame count: its last frame is last - 1
// --range a:b: the frames shown from a up to b seconds (frame k when a ≤ k / fps < b), as patch --seconds counts them
const k0 = frames ? frames[0] : range ? frameFrom(range[0], fps) : 0;
const k1 = frames ? Math.min(frames[1], last) : !range || range[1] >= first.duration ? last : frameFrom(range[1], fps);
const n = k1 - k0;
if (n <= 0) { await first.close(); die(`no frames in ${frames ? `frames ${frames.join("–")}` : range ? range.join("–") + " s" : "the film"} (it is ${first.duration} s, ${last} frames)`); }
gop = gop || Math.round(2 * fps);
const stem = path.basename(first.page, path.extname(first.page));
const outFile = path.resolve(out || path.join(first.root, "out", `${stem}.${alpha ? "mov" : "mp4"}`));
// --alpha: the browser paints no white under the page, so what the page leaves clear is clear in the capture
const clearBackground = (film) => film.send("Emulation.setDefaultBackgroundColorOverride", { color: { r: 0, g: 0, b: 0, a: 0 } });
if (alpha) { try { await clearBackground(first); } catch (e) { await first.close(); die(`--alpha: the browser would not take a transparent background (${e.message})`); } }
try { fs.mkdirSync(path.dirname(outFile), { recursive: true }); } catch (e) { await first.close(); die(`cannot make ${rel(path.dirname(outFile))}: ${e.message}`); }
// a relative --out is from the current folder; one that lands outside the project (bin/vh run from the harness with
// --out out/x.mp4) is said in full, as the short form would read as the project's own out/
const inside = (f, dir) => (f + path.sep).startsWith(dir + path.sep);
const outside = !!out && !path.isAbsolute(out) && !inside(fs.realpathSync(path.dirname(outFile)), first.root);
const shown = outside ? outFile : rel(outFile);
{   // a project's out/versions holds the earlier versions of its films (bin/vh versions): nothing is rendered over them
  const dir = fs.realpathSync(path.dirname(outFile));
  for (let d = dir; ; d = path.dirname(d)) {
    if (fs.existsSync(path.join(d, "BRIEF.md"))) {
      if (inside(dir, path.join(d, "out", "versions")) || dir === path.join(d, "out", "versions")) {
        await first.close(); die(`--out ${shown} is inside out/versions, where the earlier versions of the project's films are kept: write it elsewhere (bin/vh versions use brings a kept one back)`);
      }
      break;
    }
    if (path.dirname(d) === d) break;
  }
}

// one render per output file: a second one would interleave its chunks with ours. A lock whose render is gone (its pid
// no longer runs) is deleted and taken afresh; an empty one is a render that has not written its pid yet, unless it is old
const lock = outFile + ".lock";
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch (e) { return e.code === "EPERM"; } };
function takeLock() {
  for (let tries = 0; tries < 5; tries++) {
    try { fs.writeFileSync(lock, String(process.pid), { flag: "wx" }); return null; } catch (e) {
      if (e.code !== "EEXIST") return `cannot write ${rel(lock)}: ${e.message}`;
      let pid = 0, age = 0;
      try { pid = +fs.readFileSync(lock, "utf8"); age = Date.now() - fs.statSync(lock).mtimeMs; } catch { continue; }   // gone meanwhile
      if (pid ? alive(pid) : age < 10000) return `another render${pid ? ` (pid ${pid})` : ""} is writing ${rel(outFile)}; wait for it, or delete ${rel(lock)} if it is gone`;
      try { fs.unlinkSync(lock); } catch { /* another render took it over first: try again */ }
    }
  }
  return `could not take ${rel(lock)}`;
}
// the disk (measured once the chunks an earlier render left are kept or cleared, below): OVH_FREE_BYTES pretends that much
// is free (for tests)
const freeOnDisk = () => process.env.OVH_FREE_BYTES ? +process.env.OVH_FREE_BYTES : (() => { try { const s = fs.statfsSync(path.dirname(outFile)); return s.bavail * s.bsize; } catch { return Infinity; } })();
const gb = (b) => (b / 1e9).toFixed(b < 1e8 ? 3 : 1);
const busy = takeLock();
if (busy) { await first.close(); die(busy); }
const unlock = () => { try { if (+fs.readFileSync(lock, "utf8") === process.pid) fs.unlinkSync(lock); } catch { /* already gone */ } };
process.on("exit", unlock);

// chunks are whole GOPs, one each, so every keyframe of the joined video falls on the grid k0 + m·gop (a patch can cut
// there) and a chunk's bytes depend on its own frames only, not on how many workers there were or which drew it. An edit
// list's grid starts again at each run's first frame (K0 + m·gop): every cut is a keyframe, and a run's chunks are the
// same wherever the run sits; --frames and --range take the grid's chunks inside their span (a patch puts back whole ones)
const runOf = [];   // an edit list's chunk → the run it draws
const plan = !editRoot ? Array.from({ length: Math.ceil(n / gop) }, (_, i) => [k0 + i * gop, Math.min(k1, k0 + (i + 1) * gop)]) : (() => {
  const out = [];
  for (const r of doc.runs) for (let s = r.frames[0]; s < r.frames[1]; s += gop) {
    const a = Math.max(s, k0), b = Math.min(s + gop, r.frames[1], k1);
    if (a < b) { out.push([a, b]); runOf.push(r); }
  }
  return out;
})();
// --motion-blur: how many sub-frames a run's frames take (an edit list's slates, colours, still images and footage: one),
// and where a frame's shutter may reach (tools/film/blur.mjs: its run's frames, its page's end and shot boundaries). r: an
// edit list's run, null for a page drawn alone
const runAt = (i) => (editRoot ? runOf[i] : null);
const subN = (r) => (BLUR && (!r || blurs(r)) ? BLUR.samples : 1);
const boundsBy = new Map();
const boundsOf = (r) => {
  if (!boundsBy.has(r)) boundsBy.set(r, r ? runBounds(r, fps, r.draw === "page" ? facts[r.src] : null) : pageBounds(last, first.duration, fps, pageShots));
  return boundsBy.get(r);
};
const subOf = (r, k) => (subN(r) > 1 ? offsets(k, subN(r), BLUR.shutter, boundsOf(r)) : [0]);   // frame k's offsets, in frames
let blurred = 0, moved = 0;   // frames drawn as sub-frames, and those whose sub-frames were not one picture
const parts = path.join(path.dirname(outFile), `.${path.basename(outFile)}.parts`);
const PEXT = alpha ? "mov" : "mp4";   // the chunks' container: ProRes goes in a .mov
const kept = (i) => path.join(parts, `part${String(i).padStart(4, "0")}.${PEXT}`);   // a chunk finished clean: kept for a resume
const isKept = (f) => new RegExp(`^part\\d{4,}\\.${PEXT}$`).test(f);
const encoders = new Set();
// after a stop or a failure the finished chunks stay (and plan.json, which says what they were made from); the rest goes
const keepFinished = () => {
  let names = [];
  try { names = fs.readdirSync(parts); } catch { return 0; }
  const k = names.filter(isKept).length;
  if (!k) { fs.rmSync(parts, { recursive: true, force: true }); return 0; }
  for (const f of names) if (f !== "plan.json" && !isKept(f)) fs.rmSync(path.join(parts, f), { recursive: true, force: true });
  return k;
};
const keptSay = (k) => `${k} of ${plan.length} chunks are kept in ${rel(parts)}: the same command again draws only the rest (a changed page starts over)`;
for (const [sig, code] of [["SIGINT", 130], ["SIGTERM", 143]]) process.once(sig, () => {   // the lock goes on exit; the browsers and their profiles too (tools/textcheck/browser.mjs)
  for (const ff of encoders) ff.kill("SIGKILL");
  const k = keepFinished();
  console.error(`render: stopped (${sig}); ` + (k ? keptSay(k) : "the chunks so far are deleted"));
  process.exit(code);
});
const COLOR = "colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv";
// x264's yuv420p needs an even width and height: an odd one (1366 x 768 at --dpr 1.5 is 2049 x 1152) loses its last column or row
const EVEN = "crop=trunc(iw/2)*2:trunc(ih/2)*2", px = [Math.round(first.width * o.dpr), Math.round(first.height * o.dpr)];
// the end of every path into x264, said outright whatever the input leaves on its frames (a JPEG says SAR 1:1 and, decoded
// by ffmpeg 6, a centred chroma; a PNG and raw RGB say neither): yuv420p, BT.709 tv with its four tags, square pixels,
// chroma sited left, H.264's default (x264 then writes no chroma location). So a page's JPEG or PNG chunks and footage's
// raw RGB chunks get one SPS/PPS, which the join needs, with any ffmpeg
const OUT = `format=yuv420p,setparams=${COLOR},setsar=1`;
const X264 = () => ["-c:v", "libx264", "-preset", o.preset, "-crf", String(o.crf), "-g", String(gop), "-keyint_min", String(gop), "-sc_threshold", "0",
  "-x264-params", "chromaloc=0", "-color_range", "tv", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-r", String(fps)];
const vf = png ? `${EVEN},scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,${OUT}`
  : `${EVEN},scale=in_color_matrix=bt601:in_range=pc:out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,${OUT}`;
// sub: the sub-frames that make one frame (--motion-blur): their mean (tools/film/blur.mjs meanFilter) goes first
const x264 = (file, sub = 1) => spawn("ffmpeg", ["-v", "error", "-y", "-f", "image2pipe", "-framerate", String(fps * sub), "-c:v", png ? "png" : "mjpeg", "-i", "-",
  "-vf", sub > 1 ? `${meanFilter(sub, fps)},${vf}` : vf, ...X264(), file], { stdio: ["pipe", "ignore", "pipe"] });
const capture = png ? { format: "png" } : { format: "jpeg", quality: o.quality };
// --alpha: PNG frames with their alpha into ProRes 4444 (every frame a keyframe; the chunks stay a GOP long for the
// workers and a resume), 4:4:4, BT.709 limited range with all four tags. A fixed quantizer, since prores_ks's own rate control
// multiplies its bit budget by 20 once there is alpha (proresenc_kostya_common.c). An 8-bit alpha, since ProRes codes alpha
// losslessly and 16 bits keep every bit of a page's dither: the PNG frames have 8, and of --motion-blur's mean it loses at most
// half a level of 255. Together they make a real film's file 2.5 times smaller, its composites about 56 dB from before
const PRORES_Q = 6, PRORES_ALPHA_BITS = 8;
const VFA = `${EVEN},scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,format=yuva444p10le,setparams=${COLOR}`;
const prores = (file, sub = 1) => spawn("ffmpeg", ["-v", "error", "-y", "-f", "image2pipe", "-framerate", String(fps * sub), "-c:v", "png", "-i", "-",
  "-vf", sub > 1 ? `${meanFilter(sub, fps, true)},${VFA}` : VFA, "-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le", "-qscale:v", String(PRORES_Q), "-alpha_bits", String(PRORES_ALPHA_BITS), "-vendor", "apl0",
  "-color_range", "tv", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-r", String(fps), file], { stdio: ["pipe", "ignore", "pipe"] });
const encoder = alpha ? prores : x264;
// an edit list's footage: raw RGB from ffmpeg's decoder into an x264 with the same output end (OUT, X264: the same SPS/PPS
// as the pages' chunks, checked before the join), read as RGB as a PNG frame is
const VFRGB = `${EVEN},scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,${OUT}`;
const rawX264 = (file) => spawn("ffmpeg", ["-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", `${px[0]}x${px[1]}`, "-framerate", String(fps), "-i", "-",
  "-vf", VFRGB, ...X264(), file], { stdio: ["pipe", "ignore", "pipe"] });

// ---- what the chunks are made from: a resume takes the finished ones only while all of it is the same ----
const sha = (f) => {
  const h = crypto.createHash("sha256"), fd = fs.openSync(f, "r"), buf = Buffer.alloc(1 << 22);
  try { for (let r; (r = fs.readSync(fd, buf, 0, buf.length, null)) > 0;) h.update(buf.subarray(0, r)); } finally { fs.closeSync(fd); }
  return h.digest("hex");
};
const BLUR_SHA = BLUR ? sha(path.join(HERE, "blur.mjs")) : null;   // how the sub-frames' times are found: another way, other frames
const recipe = {
  page: fs.realpathSync(first.page), kind: first.kind, width: first.width, height: first.height, dpr: o.dpr, fps, frames: [k0, k1], gop,
  capture: png ? "png" : `jpeg q${o.quality}`, ...(alpha ? { vf: VFA, alpha: true } : { crf: o.crf, preset: o.preset, vf }),   // what applies: x264 keeps its old keys
  real_clock: !!o.realClock, soft_gl: !!o.softGl, browser: first.version,
  ffmpeg: (spawnSync("ffmpeg", ["-version"], { encoding: "utf8" }).stdout || "").split("\n")[0],
  tools: crypto.createHash("sha256").update(["render.mjs", "host.mjs", "clock.js", "glyphs.mjs", "../textcheck/browser.mjs",
    ...(editRoot ? ["edit.mjs", "timegrid.mjs", "pages/still.html", "pages/slate.html", "pages/color.html", "../edit.py"] : [])].map((f) => sha(path.join(HERE, f))).join()).digest("hex"),
  ...(editRoot ? { edit: crypto.createHash("sha256").update(JSON.stringify(doc.runs)).digest("hex") } : {}),   // what each frame is drawn from
  ...(BLUR ? { motion_blur: { ...BLUR, version: BLUR_SHA } } : {}),
};
// an edit list's chunk keys (tools/film/edit.mjs chunkKey) and its chunk cache (tools/film/cache.mjs, out/cache/chunks): a
// chunk whose key the cache holds, and whose page's files are still the same bytes, is taken from it, not drawn
const cache = editRoot && !alpha && o.cacheMax > 0 ? new ChunkCache(path.join(editRoot, CACHE), editRoot, o.cacheMax * 1e9) : null;
// what ffmpeg and x264 are, in full: ffmpeg's whole -version (its build, its libraries) and x264's own version, which a
// one-frame encode writes (an x264 upgraded under the same ffmpeg changes the bytes), and the platform
const encoderBuild = () => {
  const v = spawnSync("ffmpeg", ["-version"], { encoding: "utf8" }).stdout || "";
  const one = spawnSync("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "color=c=black:s=16x16:d=0.04", "-frames:v", "1", "-c:v", "libx264", "-f", "h264", "-"], { maxBuffer: 1 << 22 });
  const x = (one.stdout || Buffer.alloc(0)).toString("latin1").match(/x264 - core \d+( r\d+ [0-9a-f]+)?/);
  return `${crypto.createHash("sha256").update(v).digest("hex")} ${x ? x[0] : "x264 ?"}`;
};
const keySettings = { width: first.width, height: first.height, dpr: o.dpr, fps, gop, crf: o.crf, preset: o.preset,
  ffmpeg: cache ? `${recipe.ffmpeg} · ${encoderBuild()}` : recipe.ffmpeg, tools: recipe.tools, platform: `${process.platform} ${process.arch}`,
  capture: recipe.capture, vf, vfRaw: VFRGB, browser: first.version, real_clock: !!o.realClock, soft_gl: !!o.softGl };
// a blurred run's chunk: its key holds N, the shutter, how the sub-frames' times are found (blur.mjs) and the times
// themselves (they depend on where its run, its page and the page's shots end)
const keyOf = (r, a, b) => chunkKey(r, a, b, subN(r) > 1 ? { ...keySettings, motion_blur: { ...BLUR, version: BLUR_SHA,
  offsets: crypto.createHash("sha256").update(JSON.stringify(Array.from({ length: b - a }, (_, x) => subOf(r, a + x)))).digest("hex") } } : keySettings);
const cached = new Set(), cachedFiles = new Map();   // the chunks this render took from the cache; a run → the files their pages were sent
// a page that reported a problem in this render (a file missing while it loaded, an error): none of its chunks go into
// the cache, whichever worker drew them (what it drew without the file is not what it draws with it)
const sourceOf = (r) => (r.draw === "page" ? `page:${r.path}` : r.draw);
const tainted = new Set(editRoot ? Object.entries(facts).filter(([, f]) => (f.loadProblems || []).length || f.error).map(([src]) => `page:${doc.files[src].path}`) : []);
const loaded = new Map();   // every file a browser of this render was sent, and its sha256
const planFile = path.join(parts, "plan.json");
const writePlan = (film) => {   // before a chunk is kept: the files its frames loaded are on record first
  for (const f of film.served()) if (!loaded.has(f)) { try { loaded.set(f, sha(f)); } catch { loaded.set(f, null); } }
  fs.writeFileSync(planFile, JSON.stringify({ note: "what bin/vh render's chunks here were made from; a render resumes from them only while all of it is the same", recipe, files: Object.fromEntries(loaded) }, null, 1) + "\n");
};
let reuse = new Set(), why = null;
if (o.fresh) fs.rmSync(parts, { recursive: true, force: true });   // --fresh: nothing kept from a stopped render either
{
  let old = null, names = [];
  try { names = fs.readdirSync(parts); old = JSON.parse(fs.readFileSync(planFile, "utf8")); } catch { /* none, or not ours */ }
  const done = names.filter(isKept);
  if (old && done.length) {
    // every key either side has: one only the old render had (its motion_blur, when this one blurs nothing) is a change too
    const changed = [...new Set([...Object.keys(recipe), ...Object.keys(old.recipe || {})])].filter((k) => JSON.stringify((old.recipe || {})[k]) !== JSON.stringify(recipe[k]));
    const files = Object.entries(old.files || {}).filter(([f, h]) => { try { return sha(f) !== h; } catch { return true; } }).map(([f]) => rel(f));
    if (!changed.length && !files.length) {
      for (const [f, h] of Object.entries(old.files)) loaded.set(f, h);
      reuse = new Set(plan.map((_, i) => i).filter((i) => done.includes(path.basename(kept(i))) && fs.statSync(kept(i)).size > 0));
    } else why = [...changed.map((k) => k === "frames" ? "the span" : k === "tools" ? "these tools" : k === "edit" ? "the edit list" : k === "motion_blur" ? "the motion blur" : k), ...files.slice(0, 3), ...(files.length > 3 ? [`${files.length - 3} more files`] : [])].join(", ");
  } else if (done.length) why = "no record of what they were made from";
  if (why) console.log(`  the ${done.length} chunks kept from an earlier render are not used (changed: ${why}); starting over`);
  if (reuse.size) { const keep = new Set([...reuse].map((i) => path.basename(kept(i)))); for (const f of names) if (f !== "plan.json" && !keep.has(f)) fs.rmSync(path.join(parts, f), { recursive: true, force: true }); }
  else { fs.rmSync(parts, { recursive: true, force: true }); fs.mkdirSync(parts, { recursive: true }); }
  writePlan(first);
}
if (cache && !o.fresh) {   // --fresh draws every chunk again (and keeps them)
  for (let i = 0; i < plan.length; i++) {
    if (reuse.has(i)) continue;
    const [a, b] = plan[i], hit = cache.get(keyOf(runOf[i], a, b), b - a);
    if (!hit) continue;
    try { fs.linkSync(hit.file, kept(i)); } catch { try { fs.copyFileSync(hit.file, kept(i)); } catch { fs.rmSync(kept(i), { force: true }); continue; } }
    for (const [f, h] of Object.entries(hit.files)) if (!loaded.has(f)) loaded.set(f, h);
    if (!cachedFiles.has(runOf[i])) cachedFiles.set(runOf[i], new Set());
    for (const f of Object.keys(hit.files)) cachedFiles.get(runOf[i]).add(f);
    reuse.add(i); cached.add(i);
  }
  if (cached.size) writePlan(first);
}
const resumed = reuse.size - cached.size;   // kept in the parts folder by a render of this file that stopped
const todo = plan.map((_, i) => i).filter((i) => !reuse.has(i)), nTodo = todo.reduce((s, i) => s + plan[i][1] - plan[i][0], 0);
// the disk at the peak is what this run writes on top of what is there: the chunks it draws, then the joined copy, which
// is the kept chunks' bytes (known) and those chunks again. x264 at these CRFs has made 0.04 bits a pixel (a flat test
// page) to 0.4 (4K 3D with grain): refuse only when even 0.01 does not fit, say so when 0.06–0.4 might not and nothing
// measured it (the estimate below measures it)
const keptBytes = [...reuse].reduce((s, i) => s + fs.statSync(kept(i)).size, 0), free = freeOnDisk();
const peak = (bpp) => keptBytes + 2 * px[0] * px[1] * nTodo * (alpha ? 25 * bpp : bpp) / 8;   // ProRes 4444: 1–8 bits a pixel, about 25 times x264's
const peakOf = reuse.size ? `the ${nTodo} frames left to draw and the joined copy (${reuse.size} chunks kept, ${gb(keptBytes)} GB)` : `${n} frames`;
if (peak(0.01) > free) {
  await first.close(); keepFinished();
  die(`at least ${gb(peak(0.01))} GB needed at the peak for ${peakOf} at ${px[0]}x${px[1]} (likely ${gb(peak(0.06))}–${gb(peak(0.4))}), ${gb(free)} GB free on that disk`);
}
const W = Math.min(o.workers, todo.length);
const kindSaid = editRoot ? `an edit list, ${doc.entries.length} entr${doc.entries.length === 1 ? "y" : "ies"}` + (doc.slates.length ? ` (${doc.slates.length} slate${doc.slates.length === 1 ? "" : "s"})` : "")
  : first.kind === "film" ? "window.film" : first.kind;
console.log(`render: ${rel(first.page)} · ${kindSaid} · ${first.width}x${first.height}${o.dpr !== 1 ? ` @${o.dpr}x` : ""} · ` +
  `${n} frames at ${fps} fps (${(k0 / fps).toFixed(3)}–${(k1 / fps).toFixed(3)} s) · ${plan.length} chunk${plan.length > 1 ? "s" : ""}, ${W} worker${W === 1 ? "" : "s"} · ${alpha ? "PNG with alpha → ProRes 4444 (.mov)" : `${png ? "PNG" : `JPEG q${o.quality}`} → x264 crf ${o.crf} ${o.preset}, keyframe every ${gop}`} · ${first.version}`);
for (const p of first.loadProblems) console.log(`  while loading: ${p}`);
if (editRoot) for (const [src, f] of Object.entries(facts)) for (const p of f.loadProblems || []) console.log(`  while loading ${doc.files[src].path}: ${p} (it fails the chunk that draws it)`);
if (BLUR) {
  console.log(`  motion blur: each frame the mean of ${BLUR.samples} sub-frames over a shutter of ${BLUR.shutter} frame centred on its time, cut short at the film's ends` +
    `${editRoot ? ", at every cut between entries" : ""} and at the page's shot boundaries (${BLUR.samples}x the drawing${editRoot ? " of the pages and moving images" : ""})`);
  // the memory it adds: each encoder's tmix window and the browser's pictures waiting for it, measured at 4K and 8 sub-frames
  // as 0.3 GB a worker with JPEG and 0.9 GB with PNG (about 4 and 14 bytes a pixel a sub-frame): said, never refused
  const more = W * BLUR.samples * px[0] * px[1] * (png ? 14 : 4.2);
  if (W) console.log(`  motion blur: about ${more >= 1e9 ? `${(more / 1e9).toFixed(1)} GB` : `${Math.max(1, Math.round(more / 1e6))} MB`} more memory than without it ` +
    `(${BLUR.samples} sub-frames × ${W} worker${W === 1 ? "" : "s"} at ${px[0]}x${px[1]}, ${png ? "PNG" : "JPEG"}); fewer --workers if the machine is short of it`);
  if (!editRoot && !pageShots.length) console.log("  motion blur: the page gives no shots (window.film.shots): a hard cut inside it would show both of its sides in the frame at the cut");
  if (first.kind === "hyperframes") console.log("  motion blur: HyperFrames' seek rounds t to the composition's own frames, so its sub-frames are one picture and nothing blurs");
}
if (outside) console.log(`  --out ${out} is from the current folder: ${outFile}, outside the project (${first.root})`);
if (px[0] % 2 || px[1] % 2) console.log(`  note: ${px[0]}x${px[1]} pixels; x264 needs even sizes, so the video is ${px[0] - px[0] % 2}x${px[1] - px[1] % 2}`);
if (pageFps && Math.abs(pageFps - fps) > 1e-6) console.log(`  fps: drawn at ${fps} fps (${fpsGiven ? "--fps" : "the default; --fps sets it"}), the page says ${pageFps} (window.film.fps or FILM.fps): what it steps once a frame (grain) steps at its rate; make the two agree`);
if (editRoot) for (const [src, f] of Object.entries(facts)) if (f.fps && Math.abs(f.fps - fps) > 1e-6) console.log(`  fps: ${src} (${doc.files[src].path}) is made for ${f.fps} fps, the edit list runs at ${fps}: what it steps once a frame steps at its rate`);
if (editRoot && doc.slates.length) console.log(`  slates: ${doc.slates.join(", ")} (no source yet): an animatic; bin/vh check and deliver refuse the film until each has one`);
if (editRoot) for (const line of (doc.said || []).slice(doc.slates.length ? 1 : 0)) console.log(`  edit: ${line}`);   // what the build noticed (its slates line is the one above)
if (resumed) console.log(`  resuming: ${resumed} of ${plan.length} chunks kept from the last render of this file (${plan.length - reuse.size} to draw)`);
if (cache) console.log(`  cache: ${o.fresh ? `--fresh: every chunk drawn again and kept in ${rel(cache.dir)}` : `${cached.size} of ${plan.length} chunks taken from ${rel(cache.dir)} (the same drawing, settings and page files), ${plan.length - reuse.size} to draw`}`);

let done = 0;
// the first failure ends the render; the other workers finish the chunk they are on, so that it is kept for a resume
const failWith = (msg) => { if (failed) return; failed = msg; if (W > 1) console.log(`  stopping: ${msg} (the other workers finish their chunk first)`); };
const within = (p, s, what) => { let timer; return Promise.race([p, new Promise((_, no) => { timer = setTimeout(() => no(new Error(`${what}: no picture after ${s} s (--frame-timeout)`)), s * 1000); })]).finally(() => clearTimeout(timer)); };
const size = (b) => b >= 1e9 ? `${(b / 1e9).toFixed(1)} GB` : b >= 1e6 ? `${(b / 1e6).toFixed(0)} MB` : `${Math.ceil(b / 1e3)} kB`;
const ftime = (s) => s < 90 ? `${s.toFixed(0)} s` : s < 5400 ? `${(s / 60).toFixed(0)} min` : `${(s / 3600).toFixed(1)} h`;

// ---- the estimate: a few frames spread over the span, drawn and encoded as the render will ----
// (an edit list's footage is decoded, not drawn: its chunks are left out of the estimate)
const drawn = todo.filter((i) => !editRoot || runOf[i].draw !== "clip");
const toDraw = todo.reduce((s, i) => s + (plan[i][1] - plan[i][0]) * subN(runAt(i)), 0);   // what the browsers draw: --motion-blur's sub-frames each
if (drawn.length && (o.estimate === "on" || (o.estimate === "auto" && toDraw > 600))) {
  const S = Math.min(6, drawn.length), at = [...new Set(Array.from({ length: S }, (_, i) => drawn[Math.floor((i + 0.5) * drawn.length / S)]))];   // chunks
  const ms = [], runs = [];
  try {
    await within(first.frame(plan[at[0]][0] / fps, capture), o.frameTimeout, `t=${(plan[at[0]][0] / fps).toFixed(3)} s`);   // not timed: the first frame also compiles and decodes
    for (const i of at) {   // a keyframe and the two frames after it in its chunk: what a GOP's first frame and its others cost
      const [k, kb] = plan[i], r = runAt(i), imgs = [];
      for (const kk of [k, k + 1, k + 2].filter((x) => x < kb)) {
        const t0 = performance.now();
        for (const d of subOf(r, kk)) imgs.push((await within(editRoot ? first.frameK(kk, capture, d) : first.frame((kk + d) / fps, capture), o.frameTimeout, `t=${((kk + d) / fps).toFixed(3)} s`)).png);
        ms.push(performance.now() - t0);
      }
      runs.push({ imgs, sub: subN(r) });
    }
  } catch (e) { await first.close(); console.error(`render: ${e.message} (drawing the estimate's frames)`); keepFinished(); process.exit(1); }
  first.problems();   // what these frames report, they report again when the render draws them
  const sizes = await Promise.all(runs.map(({ imgs, sub }, j) => new Promise((ok) => {
    const f = path.join(parts, `estimate${j}.${PEXT}`), ff = encoder(f, sub);
    encoders.add(ff); ff.stdin.on("error", () => {}); ff.stderr.resume();
    for (const img of imgs) ff.stdin.write(img);
    ff.stdin.end();
    ff.on("close", (code) => {
      encoders.delete(ff);
      const p = code === 0 ? spawnSync("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries", "packet=size", "-of", "csv=p=0", f], { encoding: "utf8" }) : null;
      fs.rmSync(f, { force: true });
      const b = p && p.status === 0 ? p.stdout.split(/\s+/).filter(Boolean).map(Number) : [];
      ok(b.length ? (b[0] + (gop - 1) * (b.length > 1 ? b.slice(1).reduce((x, y) => x + y, 0) / (b.length - 1) : b[0] / 4)) / gop : null);   // bytes a frame: the keyframe once a GOP, the others like those after it
    });
  })));
  const mean = ms.reduce((s, x) => s + x, 0) / ms.length, got = sizes.filter((x) => x !== null);
  const film = got.length ? n * got.reduce((s, x) => s + x, 0) / got.length : null;
  // a few places can miss the busiest stretches (measured: a film up to twice what its samples said), so it is a range
  const more = film === null ? null : Math.max(0, 2 * film - keptBytes);
  console.log(`  estimate (${ms.length} frames drawn in one browser${BLUR ? `, a blurred one as its ${BLUR.samples} sub-frames` : ""}, ${Math.min(...ms).toFixed(0)}–${Math.max(...ms).toFixed(0)} ms each): ${nTodo} frames in about ` +
    `${ftime(nTodo * mean / 1000 / W)} with ${W} worker${W === 1 ? "" : "s"} (more when they share a GPU or the machine is busy)` +
    (film === null ? "; the size could not be measured" : `; the video ${size(film)}–${size(2 * film)} (x264 crf ${o.crf} ${o.preset} on those frames), ` +
      `${size(more)}–${size(more + 2 * film)} more on that disk at the peak (the chunks, then the joined copy), ${size(free)} free${more + 2 * film > free ? ": it may not fit" : ""}`));
  if (more !== null && more > free) { await first.close(); keepFinished(); die(`about ${size(more)} is needed at the peak and ${size(free)} is free on that disk: free some, or a higher --crf; --no-estimate renders without measuring`); }
} else if (peak(0.4) > free) console.log(`  disk: about ${gb(peak(0.06))}–${gb(peak(0.4))} GB needed at the peak for ${peakOf} (more for grain, 3D, photos), ${gb(free)} GB free: it may not fit`);

const fileOf = plan.map((_, i) => (reuse.has(i) ? kept(i) : null));
const T0 = Date.now(), problems = [];
activityProgress(0, nTodo, "frames");
const progress = setInterval(() => {
  if (done) console.log(`  ${done} / ${nTodo} frames · ${((Date.now() - T0) / 1000).toFixed(0)} s · about ${(((Date.now() - T0) / done) * (nTodo - done) / 1000).toFixed(0)} s to go`);
  activityProgress(done, nTodo, "frames");
}, 15000);
progress.unref();

// one chunk into its own encoder; → { encoded: a promise that settles once the encoder is done with it } (the browser goes
// on to the next chunk meanwhile). A chunk is kept for a resume only when every frame went in and the page reported nothing
async function chunk(film, i) {
  const [a, b] = plan[i], r = runAt(i), sub = subN(r), file = path.join(parts, `part${String(i).padStart(4, "0")}.new.${PEXT}`), ff = encoder(file, sub);
  encoders.add(ff);
  let ffErr = ""; ff.stderr.on("data", (d) => { ffErr = (ffErr + d).slice(-2000); });
  const closed = new Promise((ok) => ff.on("close", (code, sig) => ok(code ?? sig)));
  // an encoder that stops early (a full disk, a frame it refuses) ends the render: nothing waits on a pipe no one reads
  let gone = false, wrote = 0, said = false;
  const exited = new Promise((ok) => ff.once("exit", () => { gone = true; encoders.delete(ff); ok(); }));
  ff.stdin.on("error", () => { /* the encoder is gone: exited says so */ });
  try {
    for (let k = a; k < b && !gone; k++) {
      const t = k / fps, imgs = [];
      for (const d of subOf(r, k))   // the frame, or its sub-frames (--motion-blur), which the encoder averages
        imgs.push((await within(editRoot ? film.frameK(k, capture, d) : film.frame((k + d) / fps, capture), o.frameTimeout, `t=${((k + d) / fps).toFixed(3)} s`)).png);
      if (sub > 1) { blurred++; if (imgs.some((x) => !x.equals(imgs[0]))) moved++; }
      const later = film.problems();
      if (later.length) {
        problems.push(`t=${t.toFixed(3)} s: ${later.join(" | ")}`); said = true;
        if (editRoot) { tainted.add(sourceOf(runOf[i])); for (const k of film.openKeys()) tainted.add(k); }
      }
      for (const img of imgs) {
        if (!ff.stdin.write(img)) await Promise.race([new Promise((ok) => ff.stdin.once("drain", ok)), exited]);
        if (gone) break;
      }
      if (gone) break;
      wrote++; done++;
    }
  } catch (e) { failWith(e.message); }
  ff.stdin.end();
  return { encoded: closed.then((code) => {
    if (code !== 0 || wrote < b - a) return failWith(`the encoder for frames ${a}–${b - 1} ${wrote < b - a ? `stopped after ${wrote} of them` : "failed"} (exit ${code}): ${ffErr.trim() || "no message"}`);
    if (said) { fileOf[i] = file; return; }   // in this video, not for a resume: drawn again next time, and said again
    writePlan(film); fs.renameSync(file, kept(i)); fileOf[i] = kept(i);
    store(i, film);
  }) };
}
// a finished chunk into the cache, with the files its page was sent and their sha256. A page's chunk only, and only while
// each of those files is still the size and mtime it was sent at (one saved while the render ran is not trusted); an
// image's, a slate's and a colour's are made from what their key holds, footage's from its file's sha256 in the key. A
// page that reported a problem in this render keeps none
function store(i, film) {
  const r = runOf[i];
  if (!cache || tainted.has(sourceOf(r))) return;
  const [a, b] = plan[i], files = {};
  if (film && r.draw === "page") for (const [f, was] of film.servedFor(r)) {
    let now = null;
    try { const st = fs.statSync(f); now = [st.size, st.mtimeMs]; } catch { /* gone */ }
    if (!was || !now || was[0] !== now[0] || was[1] !== now[1]) return;
    files[f] = loaded.has(f) ? loaded.get(f) : cache.hash(f);
  }
  cache.put(keyOf(r, a, b), kept(i), b - a, files);
}
// chunks taken from the cache that a check of the joined film does not pass: out of the cache, so the same command draws
// them again (→ what to say)
const dropCached = () => {
  if (!cache || !cached.size) return "";
  for (const i of cached) { cache.drop(keyOf(runOf[i], ...plan[i])); fs.rmSync(kept(i), { force: true }); }   // nor kept for a resume
  return ` ${cached.size} of the chunks came from the chunk cache (${rel(cache.dir)}): they are taken out of it, so the same command draws them again (--fresh draws every one)`;
};
// an edit list's footage chunk: one decoder from the chunk's first source frame (an exact seek), its frames handed to the
// encoder as the film shows them (a frame shown twice is written twice, one left out is not written); no browser
async function clipChunk(i) {
  const [a, b] = plan[i], run = runOf[i], file = path.join(parts, `part${String(i).padStart(4, "0")}.new.${PEXT}`), ff = rawX264(file);
  encoders.add(ff);
  let ffErr = "", decErr = ""; ff.stderr.on("data", (d) => { ffErr = (ffErr + d).slice(-2000); });
  const closed = new Promise((ok) => ff.on("close", (code, sig) => ok(code ?? sig)));
  let gone = false, wrote = 0;
  const exited = new Promise((ok) => ff.once("exit", () => { gone = true; encoders.delete(ff); ok(); }));
  ff.stdin.on("error", () => { /* the encoder is gone: exited says so */ });
  const js = Array.from({ length: b - a }, (_, x) => clipIndex(run, a + x, fps));
  const dec = spawn("ffmpeg", decodeArgs(run, editRoot, js[0], js[js.length - 1] - js[0] + 1, px[0], px[1]), { stdio: ["ignore", "pipe", "pipe"] });
  encoders.add(dec);
  dec.stderr.on("data", (d) => { decErr = (decErr + d).slice(-2000); });
  const decoded = new Promise((ok) => dec.on("close", (code) => { encoders.delete(dec); ok(code); }));
  const size = px[0] * px[1] * 3;
  try {
    let frame = Buffer.allocUnsafe(size), fill = 0, d = 0, x = 0;
    for await (const c of dec.stdout) {
      for (let off = 0; off < c.length && !gone;) {
        const n = Math.min(size - fill, c.length - off);
        c.copy(frame, fill, off, off + n); fill += n; off += n;
        if (fill < size) continue;
        for (const j = js[0] + d++; x < js.length && js[x] === j && !gone; x++) {
          if (!ff.stdin.write(frame)) await Promise.race([new Promise((ok) => ff.stdin.once("drain", ok)), exited]);
          wrote++; done++;
        }
        frame = Buffer.allocUnsafe(size); fill = 0;   // a fresh one: the encoder may still hold the last
      }
    }
    const code = await decoded;
    if (code !== 0 || wrote < b - a) failWith(`decoding ${run.path} for ${run.entry} (frames ${a}–${b - 1}): ${decErr.trim().split("\n")[0] || `exit ${code}, ${wrote} of ${b - a} frames`}`);
  } catch (e) { failWith(e.message); }
  ff.stdin.end();
  return { encoded: closed.then((code) => {
    if (code !== 0 || wrote < b - a) return failWith(`the encoder for frames ${a}–${b - 1} ${wrote < b - a ? `stopped after ${wrote} of them` : "failed"} (exit ${code}): ${ffErr.trim() || "no message"}`);
    const abs = path.isAbsolute(run.path) ? run.path : path.join(editRoot, run.path);
    if (!loaded.has(abs)) loaded.set(abs, run.sha256 || null);   // what the chunk is made from (a resume, bin/vh assets check)
    fs.writeFileSync(planFile, JSON.stringify({ note: "what bin/vh render's chunks here were made from; a render resumes from them only while all of it is the same", recipe, files: Object.fromEntries(loaded) }, null, 1) + "\n");
    fs.renameSync(file, kept(i)); fileOf[i] = kept(i);
    store(i, null);
  }) };
}
// the chunks in turn; an edit list's worker takes one of a run it has open first (a run's chunks stay with the browser
// that has its page), else the next
const pending = [...todo];
const nextChunk = (film) => {
  if (!pending.length) return null;
  const j = editRoot ? Math.max(0, pending.findIndex((i) => film.isOpen(runOf[i]))) : 0;
  return pending.splice(j, 1)[0];
};
async function worker(w) {
  let film = w === 0 ? first : null;
  const encoding = [];
  try {
    if (!film && editRoot) { film = new EditFilm(editRoot, doc, { ...o, prelude: [HOOK], onRetire: glyphCheck, beforeReload: glyphCheck }); editFilms.push(film); }
    if (!film) { film = await openFilm(target, { ...o, runtime: "auto", prelude: [HOOK], beforeReload: glyphCheck }); if (alpha) await clearBackground(film); }
    for (let i; !failed && (i = nextChunk(film)) !== null;) encoding.push((await (editRoot && runOf[i].draw === "clip" ? clipChunk(i) : chunk(film, i))).encoded);
  } catch (e) { failWith(e.message); }
  await Promise.all(encoding);
  // the characters this worker drew, each in the font it asked for? (tools/film/glyphs.mjs; a finding is reported, not fatal)
  // (canvas text is noted as it is drawn; the DOM's text as it stands after this worker's last frame)
  // (never in the way of the render: a minute at most, then it is said to be unchecked)
  // (an edit list's pages: each one as it is closed, glyphCheck)
  if (film && !failed && !editRoot) {
    try { glyphs.push(await within((async () => { await collectDom(film); return checkGlyphs(film); })(), 60, "the glyph check")); }
    catch (e) { glyphs.push({ error: /no picture after/.test(e.message) ? "it did not finish within 60 s" : e.message }); }
  }
  if (film) await film.close();
}

await Promise.all(Array.from({ length: W }, (_, w) => worker(w)));
if (!W) await first.close();
clearInterval(progress);
const fail = (msg) => { const k = keepFinished(); console.error(`render: ${msg}`); if (k) console.error(`  ${keptSay(k)}`); process.exit(1); };
if (failed) fail(failed);
if (editRoot) {   // an edit list's chunks came from pages and from footage: one SPS/PPS, or the joined film does not decode
  const FIELDS = ["profile", "level", "pix_fmt", "width", "height", "sample_aspect_ratio", "color_range", "color_space", "color_primaries", "color_transfer",
    "chroma_location", "field_order", "has_b_frames", "refs"];
  const facts = plan.map((_, i) => {
    const r = spawnSync("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_streams", "-show_data_hash", "sha256", "-of", "json", fileOf[i]], { encoding: "utf8" });
    return (JSON.parse(r.stdout || "{}").streams || [])[0] || {};
  });
  const odd = plan.map((_, i) => i).filter((i) => facts[i].extradata_hash !== facts[0].extradata_hash || FIELDS.some((f) => facts[i][f] !== facts[0][f]));
  if (odd.length) {   // what differs, field by field, in the first such chunk: the SPS/PPS bytes alone when no field shows it
    const i = odd[0], diff = FIELDS.filter((f) => facts[i][f] !== facts[0][f]).map((f) => `${f} ${facts[0][f] ?? "unset"} → ${facts[i][f] ?? "unset"}`);
    fail(`the chunks of ${[...new Set(odd.map((x) => runOf[x].entry))].join(", ")} are encoded otherwise than ${runOf[0].entry}'s: ` +
      `${diff.length ? diff.join(", ") : "their SPS/PPS bytes (no field ffprobe shows differs: another x264, or other settings)"} ` +
      `(chunk ${i}, frames ${plan[i][0]}–${plan[i][1] - 1}, against chunk 0): joining them would make a broken film.${dropCached()}`);
  }
}
// each chunk's length in frames: an MP4's own duration is rounded to its movie timescale (1/1000 s), which would move the
// chunk after it by a few ticks when a GOP is not a whole number of milliseconds (--gop 20 at 30 fps)
fs.writeFileSync(path.join(parts, "list.txt"), plan.map(([a, b], i) => `file '${path.basename(fileOf[i])}'\nduration ${((b - a) / fps).toFixed(9)}`).join("\n") + "\n");
// joined inside the parts folder and moved onto <out> whole (through the project's versions): a join cut short (Ctrl-C)
// never replaces an earlier video
const joined = path.join(parts, `joined${path.extname(outFile)}`);
const join = concatChunks(path.join(parts, "list.txt"), joined, fps, ["-movflags", "+faststart"]);
if (join.status !== 0) fail(`joining the chunks failed: ${(join.stderr || join.signal || "").toString().trim()}`);
// the frame count the MP4 records (counting by decoding would take minutes on a long 4K film)
const probe = spawnSync("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries",
  "stream=nb_frames,width,height,pix_fmt,color_range,color_space,color_primaries,color_transfer", "-of", "json", joined], { encoding: "utf8" });
const st = JSON.parse(probe.stdout || "{}").streams?.[0] || {};
const secs = (Date.now() - T0) / 1000;
const sidecar = {
  note: "how this video was made (bin/vh render); a patch or re-render should match these",
  // from the video's folder when the video is in the project (it moves with it), else where the page is
  page: (() => {   // first.root is a real path (host.mjs), so the video's folder is compared as one too (macOS /tmp is /private/tmp)
    const dir = fs.realpathSync(path.dirname(outFile)), page = path.join(first.root, path.basename(first.page));
    return inside(dir, first.root) ? path.relative(dir, page) : first.page;
  })(),
  kind: first.kind, width: first.width, height: first.height, dpr: o.dpr, pixels: [st.width, st.height], fps, frames: n,
  span: [+(k0 / fps).toFixed(6), +(k1 / fps).toFixed(6)], first_frame: k0, capture: png ? "png" : `jpeg q${o.quality}`,
  encoder: alpha ? { codec: "prores_ks", profile: "4444", qscale: PRORES_Q, alpha_bits: PRORES_ALPHA_BITS, gop, pix_fmt: st.pix_fmt, color: [st.color_range, st.color_space, st.color_primaries, st.color_transfer] }
    : { codec: "libx264", crf: o.crf, preset: o.preset, gop, keyint_min: gop, sc_threshold: 0, pix_fmt: st.pix_fmt, color: [st.color_range, st.color_space, st.color_primaries, st.color_transfer] },
  ...(alpha ? { alpha: true } : {}),
  // bin/vh patch draws its frames the same way; version: blur.mjs's sha256, how the sub-frames' times were found
  ...(BLUR ? { motion_blur: { samples: BLUR.samples, shutter: BLUR.shutter, version: BLUR_SHA } } : {}),
  chunks: plan.map(([a, b]) => [a, b]), reused_chunks: resumed, ...(cache ? { cached_chunks: cached.size } : {}), browser: first.version, real_clock: !!o.realClock, soft_gl: !!o.softGl, seconds: +secs.toFixed(1),
  ...(pageShots.length ? { shots: pageShots } : {}), ...(pageChapters.length ? { chapters: pageChapters } : {}),
  // the files the page loaded (plan.json's table, which goes with the parts): those in the page's folder, from it, sorted
  files: Object.fromEntries([...loaded].filter(([f]) => inside(f, first.root)).map(([f, h]) => [path.relative(first.root, f).split(path.sep).join("/"), h])
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))),
  ...(editRoot ? editSidecar() : {}),
};
// an edit list's film: the edit list and what it resolved to, its entries, and each run as it was drawn with its chunks and
// their keys (a key is what the chunk's frames are made from: the run's drawing, its frames' place in it, the settings of
// the render; a page run also lists the files its page loaded). bin/vh patch compares the runs with the edit list's now
function editSidecar() {
  const relIn = (f) => path.relative(first.root, f).split(path.sep).join("/");
  const byKey = new Map();
  for (const f of editFilms) for (const [k, set] of f.servedBy) { if (!byKey.has(k)) byKey.set(k, new Set()); for (const x of set) byKey.get(k).add(x); }
  const filesOf = (r) => Object.fromEntries([...new Set([...(byKey.get(r.draw === "page" ? `page:${r.path}` : r.draw) || []), ...(cachedFiles.get(r) || [])])].filter((f) => inside(f, first.root))
    .map((f) => [relIn(f), loaded.has(f) ? loaded.get(f) : (() => { try { return sha(f); } catch { return null; } })()]).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));
  return {
    inputs: { ...(doc.runs.some((r) => r.draw !== "clip") ? { page: recipe.capture } : {}), ...(doc.runs.some((r) => r.draw === "clip") ? { clip: "rgb24" } : {}) },   // into the one x264 setting
    edit: { path: relIn(path.join(editRoot, "edit.json")), sha256: doc.edit.sha256, resolved: crypto.createHash("sha256").update(JSON.stringify(doc)).digest("hex") },
    refs: doc.refs, slates: doc.slates,
    entries: doc.entries.map((e) => ({ id: e.id, kind: e.kind, src: e.src, ...(e.clock ? { clock: e.clock } : {}), frames: e.frames, start: e.start, end: e.end })),
    runs: doc.runs.map((r) => ({ ...r, ...(r.draw === "page" ? { files: filesOf(r) } : {}),
      chunks: plan.map(([a, b], i) => [a, b, i]).filter(([, , i]) => runOf[i] === r).map(([a, b, i]) => ({ frames: [a, b], key: keyOf(r, a, b), ...(cached.has(i) ? { cached: true } : {}) })) })),
  };
}
const sideTmp = joined + ".render.json";
fs.writeFileSync(sideTmp, JSON.stringify(sidecar, null, 1) + "\n");
// ProRes keeps the matrix, primaries and transfer but no range flag, and reads back as 4:4:4 with alpha at 12 bits
const okColor = alpha ? /^yuva444p/.test(st.pix_fmt || "") && st.color_space === "bt709" && st.color_primaries === "bt709" && st.color_transfer === "bt709"
  : st.pix_fmt === "yuv420p" && st.color_range === "tv" && st.color_space === "bt709";
const okCount = +st.nb_frames === n;
// --alpha: is anything clear? a few frames decoded with their alpha; all opaque means the page paints its own background
let clear = null;
if (alpha && okCount) {
  clear = 0;
  for (const k of [...new Set([0, Math.floor(n / 2), n - 1])]) {
    const r = spawnSync("ffmpeg", ["-v", "error", "-i", joined, "-vf", `select=eq(n\\,${k})`, "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgba", "-"], { maxBuffer: 1 << 30 });
    if (r.status === 0) for (let i = 3; i < r.stdout.length; i += 4) if (r.stdout[i] < 250) { clear++; break; }
  }
}
// the new film in place: the one it replaces kept as an earlier version first (tools/film/versions.mjs)
const ver = commit({ film: outFile, new: joined, new_sidecar: sideTmp, made_by: "render", note,
  changed: { whole: true, ...(editRoot ? { entries: [...new Set(plan.map((_, i) => runOf[i].entry))] } : {}) },
  problems: problems.length + (okCount ? 0 : 1) + (okColor ? 0 : 1) });
fs.rmSync(parts, { recursive: true, force: true });
const pruned = cache ? cache.prune() : null;   // the chunks used longest ago go first, past --cache-max
const placed = ver.placed, placedShown = placed === outFile ? shown : rel(placed);
activityProgress(nTodo, nTodo, "frames");
activityNote(`${st.nb_frames} frames, ${st.width}x${st.height}, ${fps} fps, ${(k0 / fps).toFixed(2)}–${(k1 / fps).toFixed(2)} s, in ${secs.toFixed(0)} s` +
  (resumed ? ` (${resumed} chunk(s) kept from a stopped run)` : "") + (cached.size ? ` (${cached.size} chunk(s) from the cache)` : "") + (problems.length ? ` · ${problems.length} problem(s) reported` : "") +
  (ver.id ? ` · version ${ver.id}` : "") + (ver.error ? ` · ${ver.lines[0]}` : ""), [placed, placed + ".render.json"]);
console.log(`  ${placedShown}: ${st.nb_frames} frames, ${st.width}x${st.height}, ${st.pix_fmt} ${st.color_range}/${st.color_space}, in ${secs.toFixed(0)} s` +
  (nTodo ? ` (${(secs * 1000 / nTodo).toFixed(0)} ms a frame${reuse.size ? `, ${nTodo} of them drawn` : ""})` : " (every chunk kept)") + `; how it was made: ${outside ? placed + ".render.json" : rel(placed + ".render.json")}`);
for (const l of ver.lines) console.log(`  ${l}`);
if (pruned) console.log(`  cache: ${rel(cache.dir)} holds ${pruned.kept} chunks, ${size(pruned.bytes)} (--cache-max ${o.cacheMax} GB)` +
  (pruned.evicted ? `; the ${pruned.evicted} used longest ago removed to stay under it` : "") + (pruned.cleared ? `; ${pruned.cleared} leftover file(s) of earlier renders cleared` : ""));
for (const p of problems) console.log(`  ${p}`);
{   // a character in another font than it asks for, or in none: said, not fatal
  const okG = glyphs.filter((g) => !g.error), errG = glyphs.filter((g) => g.error);
  const [lines, wrong] = okG.length ? glyphReport(mergeGlyphs(okG)) : [[], false];
  if (wrong) { console.log("  glyphs: characters not drawn in the font they ask for (bin/vh fonts check lists them all):"); for (const l of lines.filter((x) => /^[✗!]/.test(x))) console.log("    " + l); }
  if (errG.length) console.log(`  glyphs: ${errG.length} of ${glyphs.length} worker(s) could not check theirs (${errG[0].error}); bin/vh fonts check does it on its own`);
  // a resume draws only the chunks left; the kept ones come from a render that stopped before its own check
  if (reuse.size && (!W || okG.some((g) => g.chars))) console.log(`  glyphs: ${W ? `checked in the ${nTodo} frames drawn now; the` : "not checked: every chunk was kept, so no frame was drawn; the"} ` +
    `${n - nTodo} frames of the ${reuse.size} kept chunk(s) were drawn by ${cached.size ? "earlier renders" : "the render that stopped"}, before its check (bin/vh fonts check covers the whole film)`);
}
// --motion-blur: a page whose sub-frames were all one picture (it rounds t to its own frames) blurred nothing
if (blurred) console.log(`  motion blur: ${moved} of the ${blurred} frames drawn moved within their shutter` + (moved ? "" :
  `: at every frame the page drew one picture ${BLUR.samples} times (a page that rounds t to its own frames cannot blur), so the film is as without --motion-blur`));
if (!okCount) console.log(`  the video has ${st.nb_frames} frames, not ${n}.${dropCached()}`);
if (!okColor) console.log(`  the colour tags are not ${alpha ? "4:4:4 with alpha, bt709" : "yuv420p tv/bt709"}`);
if (clear === 0) console.log("  --alpha: every pixel of the frames looked at is opaque: the page paints its own background (a full canvas, a body colour). Leave clear what should show through");
if (problems.length || !okCount || !okColor || placed !== outFile) process.exit(1);
if (!process.env.OVH_RENDER_PIECE) console.log(alpha ? "render: done · a transparent film, to lay over footage; bin/vh mux keeps it in a .mov" : "render: done · the sound goes on with bin/vh mux");   // a piece of bin/vh patch is a step (patch sets it): patch says when it is done
