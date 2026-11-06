// canvas-film · main: draws the frame at t (the shot, or two shots in a transition; then grain, the chapter bar, the
// caption and the fades) and gives the page contract (engines/CONTRACT.md): window.film = { frame, duration, ready,
// width, height, shots, texts, events, chapters, cues, covers, cover, ui, timeline, music, timemap }. The page never moves on its own: it draws when frame(t) is called.

function shotAt(t) { let i = 0; while (i + 1 < SHOT_T.length && t >= SHOT_T[i + 1].a) i++; return i; }

// shot i at film time t, into X. Its draw(t, s) gets s = { i, id, t0, t1, lt (s into the shot), u (0..1 through it), o
// (its o, cues as seconds), din, dout (the transitions in and out, s), cover (the id of the cover being drawn, null in the
// film's own frames: a shot can frame a cover its own way and leave the film as it is) }. A shot's cam = [z0, z1, cx, cy] drifts the
// camera from zoom z0 to z1 about (cx, cy) over the shot, so a held picture never freezes. A shot with a three field has
// its 3D drawn first (src/07-three.js), under what its draw paints.
function drawShot(i, t) {
  const S = SHOT_T[i], prev = SHOT;
  SHOT = { i, id: S.id, t0: S.a, t1: S.b, lt: t - S.a, u: seg(t, S.a, S.b), o: S.o, din: S.din, dout: S.dout, cover: COVER_NOW };
  X.save();
  try {
    const cam = S.shot.cam;
    if (cam) { const z = lerp(cam[0], cam[1], eSine(SHOT.u)), cx = cam[2] ?? W / 2, cy = cam[3] ?? H / 2; X.translate(cx, cy); X.scale(z, z); X.translate(-cx, -cy); }
    if (S.three) drawThree(t, S);
    S.shot.draw(t, SHOT);
  } finally { X.restore(); SHOT = prev; }
}

function picture(t) {   // the shot (or the two of a transition) and the grain: the frame without what sits over it
  const i = shotAt(t), S = SHOT_T[i];
  if (S.din > 0 && t - S.a < S.din) TRANSITIONS[S.tin].draw(i - 1, i, t, (t - S.a) / S.din);
  else drawShot(i, t);
  grain(t, FILM.grain);
}
function draw(t, scene) {   // scene: the picture without the interface over it (the chapter bar and the caption)
  picture(t);
  if (!scene) { chapterBar(t); captionBand(t); }
  shade(Math.max(FILM.fadeIn > 0 ? 1 - seg(t, 0, FILM.fadeIn) : 0, FILM.fadeOut > 0 ? seg(t, DUR - FILM.fadeOut, DUR - 1.5 / FILM.fps) : 0));
}

// the frame at t, from a cleared canvas: reset() also drops any state a thrown frame left behind. o.layer "scene": the
// frame without the interface, for bin/vh textcheck to see what the shot draws under it
function frame(t, o) {
  t = clamp(Number(t) || 0, 0, Math.max(0, DUR - 1e-6));
  X.reset(); X.setTransform(PRX, 0, 0, PRX, 0, 0);
  draw(t, !!(o && o.layer === "scene"));
}
// where the interface puts its ink at t: [{ name, box: [x0, y0, x1, y1] }] in the frame's px (engines/CONTRACT.md)
function uiBoxes(t) {
  t = clamp(Number(t) || 0, 0, Math.max(0, DUR - 1e-6));
  const out = barBoxes(t).map((b) => ({ name: b.name, box: b.box.map(r3) })), cap = captionBox(t);
  if (cap) out.push({ name: "caption", box: cap.map(r3) });
  return out;
}

// a cover: the frame at its cue with the camera nudged (cam: { z, x, y }: zoom about the middle of the frame, then move by
// x, y px), without the chapter bar and the caption unless it asks for them (bar: true, caption: true), and its title on
// top. While it draws, every shot's s.cover is its id. o.title false: no title (a clean background). o.ratio "9:16":
// that aspect ratio, a crop of the picture (not a wider or taller drawing) around ratios[r].focus, with ratios[r].cam in
// place of cam when given, and ratios[r].title laid out in the ratio's own px (coverBox: 1080 x 1920 for 9:16), or the
// cover's title re-set for it (ratioTitle); the host captures the crop. The bar and the caption only at the film's own
// ratio. Returns what it drew: { id, t, title (drawn or not), lines (the title's), and for a ratio: ratio, crop [x, y, w, h],
// size, layout }
function cover(id, o = {}) {
  const c = COVER_T.find((x) => x.id === String(id));
  if (!c) throw new Error(`canvas-film: no cover "${id}" (COVERS in src/50-shots.js: ${COVER_T.map((x) => x.id).join(", ") || "none"})`);
  const spec = (o.ratio && (c.ratios || {})[o.ratio]) || {}, box = o.ratio ? coverBox(o.ratio, spec) : null;
  if (o.ratio && !box) throw new Error(`canvas-film: cover ${c.id}: "${o.ratio}" is not an aspect ratio (write it as 9:16)`);
  const t = clamp(c.t, 0, Math.max(0, DUR - 1e-6)), cam = spec.cam || c.cam || {}, full = !box || box.full;
  X.reset(); X.setTransform(PRX, 0, 0, PRX, 0, 0);
  X.save(); COVER_NOW = c.id;
  try {
    X.translate(W / 2 + (cam.x || 0), H / 2 + (cam.y || 0)); X.scale(cam.z || 1, cam.z || 1); X.translate(-W / 2, -H / 2);
    picture(t);
  } finally { COVER_NOW = null; X.restore(); }
  if (full && c.bar) chapterBar(t);
  if (full && c.caption) captionBand(t);
  const own = spec.title !== undefined, layout = own ? "own" : full ? "cover" : "default";
  let ti = own ? spec.title : c.title;
  if (!own && !full && c.title && o.title !== false) {
    try { ti = ratioTitle(c.title, ...box.size); } catch (e) { throw new Error(`canvas-film: cover ${c.id} (${o.ratio}): ${e.message.replace('["…"]', `["${o.ratio}"]`)}`); }
  }
  const drawn = o.title !== false && !!ti && [].concat(ti.text || []).length > 0;
  if (drawn && box) {   // in the ratio's own px: scaled into the crop, the shadows' blur with it
    const k = box.crop[2] / box.size[0], keep = PRX;
    X.save(); X.translate(box.crop[0], box.crop[1]); X.scale(k, k); PRX *= k;
    try { coverTitle(ti, box.size[0]); } finally { PRX = keep; X.restore(); }
  } else if (drawn) coverTitle(ti);
  return { id: c.id, t: r3(t), title: drawn, ...(drawn ? { lines: [].concat(ti.text).length } : {}), ...(box ? { ratio: o.ratio, crop: box.crop.map(r3), size: box.size, layout } : {}) };
}

// ---- ready ----
async function loadFonts() {   // every @font-face in film.html, one by one; a face this machine lacks falls back, and is named
  const faces = [...document.fonts], got = await Promise.allSettled(faces.map((f) => f.load()));
  const range = (r) => { const p = r.split(/,\s*/); return p.length > 2 ? `${p[0]} … ${p.at(-1)}` : p.join(", "); };
  const name = (f) => `${f.family.replace(/"/g, "")} ${f.weight}` + (f.unicodeRange && f.unicodeRange !== "U+0-10FFFF" ? ` for ${range(f.unicodeRange)}` : "");
  return [...new Set(faces.filter((f, i) => got[i].status === "rejected").map(name))];   // a face for a few characters says which
}
async function loadImages() {
  await Promise.all(Object.entries(FILM.images || {}).map(async ([key, src]) => {
    const im = new Image(); im.src = src;
    try { await im.decode(); } catch (e) { throw new Error(`canvas-film: image "${key}" (${src}, FILM.images) did not load`); }
    IMG[key] = im;
  }));
}
async function loadTimeline() {
  const file = FILM.timeline === null || FILM.timeline === undefined ? `audio/timeline.${FILM.lang}.json` : FILM.timeline;
  if (!file) return null;   // a silent film
  let r;
  try { r = await fetch(file, { cache: "no-store" }); } catch (e) { throw new Error(`canvas-film: ${file} could not be fetched (${e.message}); open the page through bin/vh frames, which serves the project folder`); }
  if (!r.ok) throw new Error(`canvas-film: no ${file} (HTTP ${r.status}): write audio/script.txt and run bin/vh tts <project>, or set FILM.timeline (engines/canvas-film/README.md)`);
  const bytes = await r.arrayBuffer();   // kept: a time map's check hashes the bytes the film was built from
  return { file, tl: JSON.parse(new TextDecoder().decode(bytes)), bytes };
}
async function loadCaptions() {   // FILM.caption.from: the cards bin/vh captions --cards wrote
  const f = FILM.caption.from;
  if (!f) return;
  let r;
  try { r = await fetch(f, { cache: "no-store" }); } catch (e) { throw new Error(`canvas-film: ${f} (FILM.caption.from) could not be fetched (${e.message})`); }
  if (!r.ok) throw new Error(`canvas-film: no ${f} (FILM.caption.from, HTTP ${r.status}): run bin/vh captions <project> --cards, or leave FILM.caption.from out`);
  const j = await r.json();
  if (!Array.isArray(j)) throw new Error(`canvas-film: ${f} (FILM.caption.from) is not a list of captions`);
  CAP_FILE = j;
}
// the film on its timeline: every cue resolved, or one error that names each that is not
function build(T) {
  const problems = [], nocap = new Set();
  if (T) initTimeline(T.tl, problems);
  DUR = T ? FILM.lead + (isNum(T.tl.duration) ? T.tl.duration : Math.max(0, ...Object.values(LINES).map((L) => L.b - FILM.lead))) + FILM.tail
    : FILM.duration || (MUSIC ? MUSIC.duration : 0);
  if (!(DUR > 0)) throw new Error("canvas-film: the film has no length (a timeline, FILM.music, or FILM.duration for a silent film)" +
    (problems.length ? `:\n  ${problems.slice(0, 12).join("\n  ")}` : ""));
  buildShots(problems);
  checkThree(problems);
  for (const S of SHOT_T) for (const id of S.shot.nocap || []) { if (LINES[id]) nocap.add(id); else problems.push(`shot ${S.id} (nocap): no narration line "${id}"`); }
  buildChapters(problems);
  buildCovers(problems);
  checkCaptionFile(problems);
  if (problems.length) {
    throw new Error(`canvas-film: ${problems.length} problem${problems.length > 1 ? "s" : ""} on ${T ? T.file : "a silent film"} (src/50-shots.js):\n  ` +
      problems.slice(0, 12).join("\n  ") + (problems.length > 12 ? `\n  … ${problems.length - 12} more` : ""));
  }
  buildCaptions(nocap);
  layoutBar();
}
// every shot drawn at a few times with the recorder on: the events and reads its helpers report, and any text set in a
// font under the size floor without texture (a helper that set X.font itself; the font's size, not a scale an
// animation is passing through). Then the transitions, as events too.
let EVENTS = [], TEXTS = [], TIMELINE = null;
function record() {
  REC = { events: [], reads: [], at: 0 };   // at: the time being sampled
  const small = new Map(), fails = new Map(), P = Object.getPrototypeOf(X);
  const check = function (s) {
    if (TEXTURE > 0 || !SHOT) return;
    const px = parseFloat((this.font.match(/([\d.]+)px/) || [])[1]) || 0;
    if (px < FILM.minText - 0.5) small.set(`${SHOT.id} "${s}"`, Math.round(px));
  };
  X.fillText = function (s, ...a) { check.call(this, s); return P.fillText.call(this, s, ...a); };
  X.strokeText = function (s, ...a) { check.call(this, s); return P.strokeText.call(this, s, ...a); };
  try {
    for (const S of SHOT_T) for (const f of [0.02, 0.25, 0.5, 0.75, 0.98]) {
      const t = S.a + (S.b - S.a) * f;
      X.reset(); X.setTransform(PRX, 0, 0, PRX, 0, 0); REC.at = t;
      try { drawShot(S.i, t); } catch (e) { if (!fails.has(S.id)) fails.set(S.id, `${t.toFixed(2)} s: ${e.message}`); }
    }
  } finally { delete X.fillText; delete X.strokeText; }
  // one event per call: the same shot, kind, time and own x (not its screen x, which a camera move changes from sample to
  // sample), with the screen x of the sample nearest the event
  const one = new Map();
  for (const e of REC.events) {
    const k = `${e.shot}|${e.kind}|${Math.round(e.t * 20)}|${e.own === undefined ? "" : Math.round(e.own)}`;
    if (!one.has(k) || e.near < one.get(k).near) one.set(k, e);
  }
  EVENTS = [...[...one.values()].map(({ own, near, ...e }) => e), ...SHOT_T.slice(1).map((S) => ({ t: r3(S.a), kind: S.tin, shot: S.id, x: Math.round(W / 2), dur: S.din }))]
    .sort((p, q) => p.t - q.t);
  const seen = new Set();
  TEXTS = [...REC.reads.filter((r) => { const k = `${r.text}|${r.start}|${r.end}`; return !seen.has(k) && seen.add(k); }).sort((p, q) => p.start - q.start),
    ...CAPS.map((c) => ({ text: c.text, start: c.start, end: c.end, read: "subtitle" }))];
  REC = null;
  X.reset();
  if (fails.size) console.error(`canvas-film: shots that throw: ${[...fails].map(([id, m]) => `${id} at ${m}`).join(" · ")}`);
  if (small.size) console.error(`canvas-film: text under the ${FILM.minText} px floor (txt() keeps it; say texture: true if it is meant to be small): ${[...small].map(([k, px]) => `${k} ${px} px`).join(" · ")}`);
}
async function boot() {
  W = FILM.width; H = FILM.height; PRX = window.devicePixelRatio || 1;
  const cv = document.getElementById("film");
  cv.width = Math.round(W * PRX); cv.height = Math.round(H * PRX); cv.style.width = W + "px"; cv.style.height = H + "px";
  X = cv.getContext("2d");
  const [missing, , T] = await Promise.all([loadFonts(), loadImages(), loadTimeline(), loadCaptions(), loadMusic(), loadTimeMap(), loadThree()]);
  TIMELINE = T ? T.file : null;
  await checkTimeMapSources(T);
  build(T);
  record();
  if (missing.length) console.error(`canvas-film: fonts this machine does not have, drawn in a fallback: ${missing.join(" · ")} (film.html's @font-face)`);
}

const READY = boot();
READY.catch(() => {});   // a host reports the rejection when it awaits ready; this only keeps the browser from calling it unhandled
window.film = {
  width: FILM.width, height: FILM.height,
  ready: READY,
  frame,
  get duration() { return DUR; },
  get fps() { return FILM.fps; },                                                // the rate it is made for (bin/vh render says when --fps differs)
  get shots() {                                                                 // actual cut boundaries, resolved by ready
    return SHOT_T.map((S) => {
      const s = S.shot, chapter = CHAPTER_T.filter((c) => c.t <= S.a).at(-1);
      return { id: S.id, start: S.a, end: S.b, segment: s.segment ?? (chapter ? chapter.title : ""),
        reads: s.reads ?? s.see ?? [], label: s.label ?? "", unsure: s.unsure ?? false,
        transition: { type: S.tin, duration: S.din }, ...(s.camera ? { camera: s.camera } : {}) };
    });
  },
  get texts() { return TEXTS; },                                                  // reads and captions: [{ text, start, end, read }]
  get events() { return EVENTS; },                                                // [{ t, kind, shot, x?, dur? }], transitions too
  get chapters() { return CHAPTER_T.map((c) => ({ t: r3(c.t), title: c.title })); },
  get cues() { return CUES; },                                                    // [{ id, ref, t }]
  get covers() {                                                                // [{ id, t, title, ratios: ["9:16", …] }]
    return COVER_T.map((c) => ({ id: c.id, t: r3(c.t), title: c.title ? [].concat(c.title.text || []).map(titleText).join(" / ") : "", ratios: Object.keys(c.ratios || {}) }));
  },
  cover(id, o) { return cover(id, o || {}); },                                    // draw a cover (bin/vh frames --covers [--no-title] [--ratios])
  ui: uiBoxes,                                                                     // the interface's boxes at t (bin/vh textcheck)
  get timeline() { return TIMELINE; },                                            // the timeline file the cues hang on, beside film.html
  get music() { return MUSIC_SOURCE; },                                           // { path, sha256 } of the beat map actually loaded
  get timemap() { return TIMEMAP_SOURCE; },                                       // { path, sha256 } of the time map actually loaded
};
