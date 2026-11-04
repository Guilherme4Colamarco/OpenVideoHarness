// canvas-film · core: the film's settings, the time model (narration lines, cues, shots, chapters, captions) and the
// recorder. Every frame is a pure function of t (hard rule 1): no Math.random, no clocks, no state carried from one frame
// to the next. What is built once (fonts, images, the line maps, the caption list, cached textures) depends only on its
// inputs, so a frame drawn first and the same frame drawn after any other are the same picture.

// ---- settings: the defaults; src/50-shots.js changes what its film needs (Object.assign(FILM, {...})) ----
const FILM = {
  width: 1920, height: 1080,   // CSS px. 4K is device pixel ratio 2 (bin/vh frames --dpr 2), not a bigger frame
  fps: 30,                     // the grain changes once a frame
  lang: "zh",                  // the narration: audio/timeline.<lang>.json, as bin/vh tts writes it
  timeline: null,              // another file; false for a silent film (then set duration, and every time is in seconds)
  music: null,                 // bin/vh music's *.beats.json; musicAt() declarations and musicT() in draw use its bars
  timemap: null,               // a time map file (src/06-time-map.js): "@#id" and mapAt() in declarations, mapU(t) in draw
  three: null,                 // the Three.js layer (src/07-three.js, three/layer.js): models, camera, lights, env; a shot's
                               // three field draws its 3D under the shot's own drawing
  duration: 0,                 // a silent film's length in seconds
  lead: 0,                     // seconds added to the timeline's times. 0 when they are film times already: bin/vh tts --lead
                               // starts the voice and its timeline late together. Set it only for a timeline that starts at
                               // 0, and then pad the voice by as much before the mix
  tail: 2.5,                   // the film runs on this long after the narration's timeline ends
  minText: 44,                 // the text-size floor in px (playbook/03 §4: desktop 44, feed 80); txt() never goes under it
  caption: { size: 52, max: 16, y: 1012, hold: 0.8, min: 1.8, from: null },   // one line ≤ max CJK characters wide (Latin counts 0.55),
                               // baseline y; the last caption of a line may stay hold s into the pause; min s on screen
  bar: null,                   // the chapter bar's span { from, to } (cues or seconds); default: the first chapter to the end
  grain: 0.04,                 // film grain over the picture (0: none)
  fadeIn: 0, fadeOut: 0.6,     // from and to black at the very start and end (fadeIn 0: frame 0 is already the picture; the last frame is black, shutter and all)
  images: {},                  // { key: "assets/x.jpg" }: loaded in ready; image(key, …) draws one (src/10-draw.js)
  ui: { text: "#F4F1EA", accent: "#E8A33D", dark: "8,10,14" },   // the chapter bar and the captions
};
let W = 1920, H = 1080, PRX = 1, X = null, DUR = 0;   // frame size, device pixel ratio, the context drawn into, length

// ---- numbers ----
const TAU = Math.PI * 2;
const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
const lerp = (a, b, u) => a + (b - a) * u;
const seg = (t, a, b) => (b > a ? clamp((t - a) / (b - a)) : t >= b ? 1 : 0);   // 0 until a, 1 from b on
const eOut = (u) => 1 - Math.pow(1 - clamp(u), 3);
const eIn = (u) => Math.pow(clamp(u), 3);
const eInOut = (u) => { u = clamp(u); return u < 0.5 ? 4 * u * u * u : 1 - Math.pow(-2 * u + 2, 3) / 2; };
const eSine = (u) => (1 - Math.cos(Math.PI * clamp(u))) / 2;
const eOutBack = (u, s = 1.7) => { u = clamp(u); return 1 + (s + 1) * Math.pow(u - 1, 3) + s * Math.pow(u - 1, 2); };
const show = (t, at, d = 0.4) => eOut(seg(t, at, at + d));   // 0 → 1 over d s from at
const win = (t, a, b, fi = 0.4, fo = 0.4) => Math.min(eOut(seg(t, a, a + fi)), 1 - eIn(seg(t, b - fo, b)));   // in from a, out by b
// randomness that is the same for the same arguments, whatever was drawn before (hard rule 1)
const hash = (i) => { const s = Math.sin(i * 127.1 + 311.7) * 43758.5453; return s - Math.floor(s); };
const hash2 = (i, j) => hash(i * 7.31 + j * 157.7);
const noise1 = (x) => { const i = Math.floor(x), f = x - i; return lerp(hash(i), hash(i + 1), f * f * (3 - 2 * f)); };
const r3 = (x) => Math.round(x * 1000) / 1000;

// ---- the narration: lines with their spoken times, in film seconds (FILM.lead added) ----
const LINES = {}, LINE_IDS = [];   // id → { id, a, b, text, words: [{ w, a, b }] }; ids in timeline order
// a text's letters: whitespace, punctuation and symbols left out (the script's "，" or "“" are not in the aligned words)
const letters = (s) => String(s).normalize("NFKC").replace(/[\s\p{P}\p{S}]/gu, "").toLowerCase();
class CueError extends Error {}

const isNum = (x) => typeof x === "number" && Number.isFinite(x);
function initTimeline(tl, problems) {   // a line without an id or times is a problem (bin/vh timeline checks the rest)
  (Array.isArray(tl.segments) ? tl.segments : []).forEach((s, i) => {
    if (!s || !s.id || !isNum(s.start) || !isNum(s.end)) return problems.push(`timeline line ${i + 1}${s && s.id ? ` (${s.id})` : ""}: no id, start or end`);
    if (LINES[s.id]) return problems.push(`timeline line ${i + 1}: the id ${s.id} is used twice (a cue on it would mean one of them)`);
    const words = (s.words || []).filter((w) => w && isNum(w.start));
    if (words.length < (s.words || []).length) problems.push(`timeline line ${s.id}: ${(s.words || []).length - words.length} word(s) without a start`);
    LINES[s.id] = { id: s.id, a: s.start + FILM.lead, b: s.end + FILM.lead, text: s.text ?? s.zh ?? s.en ?? "",
      words: words.map((w) => ({ w: String(w.w ?? ""), a: w.start + FILM.lead, b: (isNum(w.end) ? w.end : w.start) + FILM.lead })) };
    LINE_IDS.push(s.id);
  });
  if (!LINE_IDS.length && !problems.length) problems.push("the timeline has no lines (segments)");
}
// when each letter of a line is spoken: its letters matched to the aligned words (longest common subsequence, so a word
// the aligner heard differently is skipped and its letters are placed between the matched neighbours); a line without
// words is spread evenly over its span. Built once per line.
function letterTimes(L) {
  if (L.map) return L.map;
  const a = [...letters(L.text)], hc = [], ht = [];
  for (const w of L.words) { const cs = [...letters(w.w)]; cs.forEach((c, j) => { hc.push(c); ht.push(w.a + (w.b - w.a) * j / cs.length); }); }
  const n = a.length, m = hc.length, D = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1)), T = new Array(n);
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) D[i][j] = a[i] === hc[j] ? D[i + 1][j + 1] + 1 : Math.max(D[i + 1][j], D[i][j + 1]);
  const anchors = [[-1, L.a]];
  for (let i = 0, j = 0; i < n && j < m;) { if (a[i] === hc[j]) { anchors.push([i, ht[j]]); i++; j++; } else if (D[i + 1][j] >= D[i][j + 1]) i++; else j++; }
  anchors.push([n, L.b]);
  for (let k = 0; k + 1 < anchors.length; k++) {
    const [i0, t0] = anchors[k], [i1, t1] = anchors[k + 1];
    for (let q = i0 + 1; q < i1; q++) T[q] = t0 + (t1 - t0) * (q - i0) / (i1 - i0);
    if (i1 < n) T[i1] = t1;
  }
  return (L.map = T);
}

// ---- cues: a time written as a place in the narration ----
//   "@id"   line id starts          "@id:词"  the first "词" in line id is spoken          "@id>"  line id ends
//   any of them + or - seconds: "@b2:跟着走-0.3". Ids are letters, digits and _ (bin/vh tts's @id). A number is seconds.
//   "@#id" and "@#id>": an event of the time map (FILM.timemap) and its end, with the same + or - seconds.
// Rewrite a line and the shots on it move with it; a cue that no longer finds its line or word stops the film in ready.
const CUE = /^@(\w+)(?:(>)|:(.+?))?([+-](?:\d+\.?\d*|\.\d+))?$/;
function cueT(c) {
  if (typeof c === "number" && Number.isFinite(c)) return c;
  if (typeof c !== "string" || c[0] !== "@") throw new CueError(`not a time: ${JSON.stringify(c)} (seconds, or a cue: "@id", "@id:词", "@id>")`);
  if (c.trim().startsWith("@#")) return mapCueT(c.trim());
  const m = CUE.exec(c.trim());
  if (!m) throw new CueError(`not a cue: write "@id" (the line starts), "@id:词" (that word is spoken) or "@id>" (the line ends), with an optional +0.3 or -0.2; ids are letters, digits and _`);
  const L = lineOf(m[1]);
  if (m[3] !== undefined && m[4] && letters(L.text).includes(letters(m[3] + m[4]))) {   // "@g1:GPT-4": the word, or 4 s before "GPT"?
    const dec = m[4] + (m[4].includes(".") ? "0" : ".0");
    throw new CueError(`"${c.trim()}" reads two ways, as line ${m[1]} says "${m[3]}${m[4]}": write "@${m[1]}:${m[3]}${m[4]}+0" for that word, or "@${m[1]}:${m[3]}${dec}" for ${m[4].slice(1)} s ${m[4][0] === "-" ? "before" : "after"} "${m[3]}"`);
  }
  return (m[2] ? L.b : m[3] !== undefined ? wordT(L, m[3]) : L.a) + (m[4] ? +m[4] : 0);
}
function lineOf(id) {
  if (LINES[id]) return LINES[id];
  if (!LINE_IDS.length) throw new CueError(`no narration line "${id}": this film has no timeline (FILM.timeline)`);
  const near = LINE_IDS.map((k) => [lcs(k, id), k]).filter((x) => x[0] > 0).sort((p, q) => q[0] - p[0]).slice(0, 3).map((x) => x[1]);
  throw new CueError(`no narration line "${id}" (the lines: ${short(LINE_IDS)}${near.length ? `; nearest: ${near.join(", ")}` : ""})`);
}
function wordT(L, word) {
  const T = letters(L.text), k = letters(word);
  if (!k) throw new CueError(`"${word}" has no letters to find`);
  const i = T.indexOf(k);
  if (i < 0) throw new CueError(`line ${L.id} has no "${word}"; it now reads "${L.text}"${nearest(T, k)}`);
  return letterTimes(L)[[...T.slice(0, i)].length];
}
const short = (ids) => (ids.length > 12 ? ids.slice(0, 12).join(", ") + ` … (${ids.length})` : ids.join(", "));
function lcs(a, b) {   // the length of the longest common subsequence of two short strings
  a = [...a]; b = [...b];
  let row = new Array(b.length + 1).fill(0);
  for (let i = a.length - 1; i >= 0; i--) { const nx = new Array(b.length + 1).fill(0); for (let j = b.length - 1; j >= 0; j--) nx[j] = a[i] === b[j] ? row[j + 1] + 1 : Math.max(row[j], nx[j + 1]); row = nx; }
  return row[0];
}
// the stretches of a line most like a word that is not in it (shared letters, in order), for the error message
function nearest(T, k) {
  const t = [...T], n = [...k].length, best = new Map();
  for (let len = Math.max(1, n - 1); len <= n + 1; len++) for (let i = 0; i + len <= t.length; i++) {
    const s = t.slice(i, i + len).join(""), sc = lcs(s, k) - 0.01 * Math.abs(len - n);
    if (sc >= 1 && !(best.get(s) >= sc)) best.set(s, sc);
  }
  const top = [...best].sort((p, q) => q[1] - p[1]).slice(0, 3).map((x) => `"${x[0]}"`);
  return top.length ? `; nearest: ${top.join(", ")}` : "";
}

// A resolver for one owner (a shot, a chapter): every cue string inside a value (objects, arrays) becomes film seconds
// and is listed in CUES; other values pass through ("@@x" is the text "@x"). A cue that does not resolve adds a line to
// `problems` instead of throwing, so ready names all of them at once. who: for the message; key: for the cue's id.
const CUES = [];   // [{ id, ref, t }]: window.film.cues
function resolver(who, key, problems) {
  const walk = (v, path) => {
    if (isMusicAt(v)) {
      try {
        const t = resolveMusicAt(v);
        CUES.push({ id: `${key}.${path}`, ref: `music(${v.$music.join(",")})${v.offset ? `${v.offset > 0 ? "+" : ""}${v.offset}` : ""}`, t: r3(t) });
        return t;
      } catch (e) { problems.push(`${who} (${path}): ${e.message}`); return NaN; }
    }
    if (isMapAt(v)) {
      try {
        const t = resolveMapAt(v);
        CUES.push({ id: `${key}.${path}`, ref: `map(${v.$map})${v.offset ? `${v.offset > 0 ? "+" : ""}${v.offset}` : ""}`, t: r3(t) });
        return t;
      } catch (e) { problems.push(`${who} (${path}): ${e.message.replace(/^time map: /, "")}`); return NaN; }
    }
    if (typeof v === "string" && v[0] === "@") {
      if (v.startsWith("@@")) return v.slice(1);
      try { const t = cueT(v); CUES.push({ id: `${key}.${path}`, ref: v, t: r3(t) }); return t; }
      catch (e) { if (!(e instanceof CueError)) throw e; problems.push(`${who} (${path}), cue "${v}": ${e.message}`); return NaN; }
    }
    if (Array.isArray(v)) return v.map((x, i) => walk(x, `${path}.${i}`));
    if (v && typeof v === "object" && Object.getPrototypeOf(v) === Object.prototype) return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, walk(x, `${path}.${k}`)]));
    return v;
  };
  walk.time = (v, path) => {   // a value that must be a time: seconds or a cue
    if (typeof v === "number" && Number.isFinite(v)) return v;
    if (isMusicAt(v) || isMapAt(v)) return walk(v, path);
    if (typeof v === "string" && v[0] === "@" && !v.startsWith("@@")) return walk(v, path);
    problems.push(`${who} (${path}): not a time: ${JSON.stringify(v)} (seconds, or a cue: "@id", "@id:词", "@id>")`);
    return NaN;
  };
  return walk;
}

// ---- shots and chapters, on film time ----
let SHOT_T = [];      // [{ shot, i, id, a, b, o, three, tin, din, dout }]: a shot runs from its cue to the next shot's
let CHAPTER_T = [];   // [{ t, b, title }]
let BAR_SPAN = [0, 0];
function buildShots(problems) {
  const seen = new Set();
  SHOT_T = SHOTS.map((sh, i) => {
    const id = sh.id || `#${i + 1}`, R = resolver(`shot ${id}`, id, problems);
    if (!sh.id) problems.push(`shot #${i + 1}: no id`); else if (seen.has(sh.id)) problems.push(`shot ${sh.id}: the id is used twice`);
    seen.add(sh.id);
    if (typeof sh.draw !== "function") problems.push(`shot ${id}: no draw(t, s)`);
    if (i === 0 && sh.at !== undefined && sh.at !== 0) R.time(sh.at, "at");   // checked, but the first shot starts the film
    const a = i === 0 ? 0 : R.time(sh.at, "at");
    const [tin, d] = Array.isArray(sh.tin) ? sh.tin : [sh.tin || "cut"], T = TRANSITIONS[tin];
    if (!T) problems.push(`shot ${id}: no transition "${tin}" (${Object.keys(TRANSITIONS).join(", ")})`);
    else if (d !== undefined && (!T.draw ? d !== 0 : !(isNum(d) && d >= 0))) problems.push(`shot ${id}: ${JSON.stringify(sh.tin)}: ${T.draw ? "the length is seconds, 0 or more" : `${tin} has no length`}`);
    const din = i === 0 || !T || !T.draw ? 0 : isNum(d) && d >= 0 ? d : T.d;
    return { shot: sh, i, id, a, b: DUR, o: R(sh.o || {}, "o"), three: sh.three ? R(sh.three, "three") : null, tin: i === 0 ? "cut" : tin, din, dout: 0 };
  });
  for (let i = 0; i < SHOT_T.length; i++) {
    const S = SHOT_T[i], N = SHOT_T[i + 1];
    if (N) { S.b = N.a; S.dout = N.din; }
    if (!Number.isFinite(S.a) || !Number.isFinite(S.b)) continue;   // a cue that did not resolve: said above
    if (!(S.b - S.a >= 0.2)) problems.push(`shot ${S.id}: ${S.a.toFixed(2)}–${S.b.toFixed(2)} s, out of order or under 0.2 s (its at, and the next shot's)`);
    else if (S.din > S.b - S.a - 0.1) problems.push(`shot ${S.id}: ${(S.b - S.a).toFixed(2)} s long, too short for its ${S.tin} (${S.din} s)`);
  }
}
function buildChapters(problems) {
  const list = typeof CHAPTERS === "undefined" ? [] : CHAPTERS;
  CHAPTER_T = list.map((c, i) => ({ title: String(c.title || ""), t: resolver(`chapter ${i + 1} (${c.title})`, `chapter${i + 1}`, problems).time(c.at ?? 0, "at") }));
  CHAPTER_T.forEach((c, i) => { if (i && c.t <= CHAPTER_T[i - 1].t) problems.push(`chapter ${i + 1} (${c.title}) does not start after the one above it`); });
  const span = FILM.bar || {}, R = resolver("FILM.bar", "bar", problems);
  BAR_SPAN = [span.from !== undefined ? R.time(span.from, "from") : CHAPTER_T.length ? CHAPTER_T[0].t : 0, span.to !== undefined ? R.time(span.to, "to") : DUR];
  CHAPTER_T.forEach((c, i) => { c.b = i + 1 < CHAPTER_T.length ? CHAPTER_T[i + 1].t : BAR_SPAN[1]; });
}

// ---- covers: frames of the film picked by cue (they move with the narration), each with its own camera nudge; another
// aspect ratio is a crop of that picture around a focus, with a title laid out for it (src/90-main.js, cover) ----
let COVER_T = [];   // [{ id, t, cam, title, bar, caption, ratios }]
const RATIO = /^(\d+(?:\.\d+)?):(\d+(?:\.\d+)?)$/;
// an aspect ratio "w:h" as a crop of the cover: the largest box of exactly that shape in whole px inside the frame
// (Chrome captures whole CSS px: 603 x 1072 for 9:16 in a 1920 x 1080 film), centred on spec.focus ([x, y] in the frame's
// px, the middle by default) and kept inside it. size: the ratio's own px, its short side the frame's (1080 x 1920 for
// 9:16), which its title is laid out in. null for what is not a ratio
function coverBox(ratio, spec = {}) {
  const m = String(ratio).match(RATIO);
  if (!m) return null;
  const f = 10 ** Math.max((m[1].split(".")[1] || "").length, (m[2].split(".")[1] || "").length), gcd = (p, q) => (q ? gcd(q, p % q) : p);
  const p = Math.round(+m[1] * f), q = Math.round(+m[2] * f), g = gcd(p, q) || 1, a = p / g, b = q / g;
  const w = FILM.width, h = FILM.height, S = Math.min(w, h), n = a > 0 && b > 0 ? Math.floor(Math.min(w / a, h / b) + 1e-9) : 0;
  if (n < 1) return null;
  const cw = a * n, ch = b * n, [fx, fy] = Array.isArray(spec.focus) ? spec.focus : [w / 2, h / 2];
  return { crop: [Math.round(clamp(fx - cw / 2, 0, w - cw)), Math.round(clamp(fy - ch / 2, 0, h - ch)), cw, ch],
    size: a >= b ? [Math.round((S * a) / b), S] : [S, Math.round((S * b) / a)], full: cw === w && ch === h };
}
function buildCovers(problems) {
  const list = typeof COVERS === "undefined" ? [] : COVERS, seen = new Set();
  COVER_T = list.map((c, i) => {
    const id = String(c.id || `cover${i + 1}`), R = resolver(`cover ${id}`, `cover.${id}`, problems);
    if (seen.has(id)) problems.push(`cover ${id}: the id is used twice`);
    seen.add(id);
    const t = R.time(c.at ?? 0, "at");
    if (Number.isFinite(t) && !(t >= 0 && t < DUR)) problems.push(`cover ${id}: ${t.toFixed(2)} s is outside the film (0–${DUR.toFixed(2)} s)`);
    const camCheck = (cam, where) => {   // a move further than the zoom leaves room for shows the frame's edge
      const z = cam.z || 1;
      if (Math.abs(cam.x || 0) > (z - 1) * FILM.width / 2 + 0.5 || Math.abs(cam.y || 0) > (z - 1) * FILM.height / 2 + 0.5)
        problems.push(`cover ${id}${where}: cam ${JSON.stringify(cam)} shows the frame's edge: at zoom ${z} it can move ${((z - 1) * FILM.width / 2).toFixed(0)} px across and ${((z - 1) * FILM.height / 2).toFixed(0)} px up or down`);
    };
    const titleCheck = (ti, w, where) => {   // every title line inside its frame (a long line at a big size runs off both sides)
      if (ti && X) [].concat(ti.text || []).forEach((line, k) => {
        const size = pickAt(ti.size, k, 200), lw = coverLineWidth(line, size, ti);
        const x = ti.x ?? 120, a = ti.align === "center" ? x - lw / 2 : ti.align === "right" ? x - lw : x;
        if (a < 0 || a + lw > w) problems.push(`cover ${id}${where}: title line "${titleText(line)}" is ${Math.round(lw)} px wide at ${Math.max(FILM.minText, size)} px and runs off the frame (${Math.round(a)}–${Math.round(a + lw)} px of ${w}): a smaller size or a shorter line`);
      });
    };
    camCheck(c.cam || {}, "");
    titleCheck(c.title, FILM.width, "");
    for (const [r, spec] of Object.entries(c.ratios || {})) {
      const box = coverBox(r, spec || {});
      if (!box) { problems.push(`cover ${id}: ratios["${r}"] is not an aspect ratio (write it as "9:16")`); continue; }
      if (spec && spec.cam) camCheck(spec.cam, ` (${r})`);
      if (spec && spec.focus !== undefined && !(Array.isArray(spec.focus) && spec.focus.length === 2 && spec.focus.every(isNum)))
        problems.push(`cover ${id} (${r}): focus is [x, y] in the frame's px`);
      if (spec && spec.title) titleCheck(spec.title, box.size[0], ` (${r}, ${box.size.join(" x ")})`);
      else if (spec && spec.title === undefined && c.title && !box.full && X) {   // the default layout: does the cover's title fit this ratio?
        try { ratioTitle(c.title, ...box.size); } catch (e) { problems.push(`cover ${id} (${r}): ${e.message.replace('["…"]', `["${r}"]`)}`); }
      }
    }
    return { ...c, id, t };
  });
}

// ---- captions: one line each, cut at sentence ends (two sentences never share one), then at commas; timed by the words ----
let CAPS = [];   // [{ id, text, start, end, joinPrev?, joinNext? }]
const STOPS = "。？！?!….", PAUSES = "，、：；,;:", CLOSERS = "”’」』）》)\"'";
const capWidth = (s) => [...s.replace(/\s/g, "")].reduce((n, c) => n + (/[\x21-\x7e]/.test(c) ? 0.55 : 1), 0);
// what a caption shows: CJK commas become a space, the punctuation at its end goes (？ and ！ stay)
const capText = (s) => s.replace(/[，、：；。,;:]+\s*$/, "").replace(/(?<!\.)\.\s*$/, "").replace(/[，、：；]/g, " ").replace(/\s+/g, " ").trim();   // "..." stays, as "……" does
// s cut after each mark of `set`; marks in a row ("……") and the closing quotes after them stay with what they end. A
// Latin mark followed by a letter or digit ends nothing, so 3.5, 1,000, 12:30 and Node.js stay whole
function splitAfter(s, set) {
  const cs = [...s], r = []; let cur = "", end = false;
  cs.forEach((ch, i) => {
    if (end && !set.includes(ch) && !CLOSERS.includes(ch)) { r.push(cur); cur = ""; end = false; }
    cur += ch;
    if (set.includes(ch) && !(/[.,:;!?]/.test(ch) && /[A-Za-z0-9]/.test(cs[i + 1] || ""))) end = true;
  });
  if (cur.trim()) r.push(cur);
  return r;
}
function captionPieces(text, max) {
  const out = [];
  const cut = (p) => {   // a phrase wider than max: parts of even width, cut where it may be (never inside a Latin word or a number)
    const cs = [...p], w = capWidth(p), n = Math.ceil(w / max);
    if (n <= 1) return [p];
    const may = [];   // [after character i, the width so far]
    let acc = 0;
    const word = (k) => /[A-Za-z0-9]/.test(cs[k] || "") || (/[.,:]/.test(cs[k] || "") && /\d/.test(cs[k - 1] || "") && /\d/.test(cs[k + 1] || ""));   // 3.5, 1,000, 12:30 hold together
    cs.forEach((ch, i) => { acc += capWidth(ch); if (i + 1 < cs.length && !(word(i) && word(i + 1))) may.push([i + 1, acc]); });
    const parts = [];
    let from = 0;
    for (let k = 1; k < n; k++) {
      const goal = w * k / n, c = may.filter(([i]) => i > from).sort((p, q) => Math.abs(p[1] - goal) - Math.abs(q[1] - goal))[0];
      if (!c) break;
      parts.push(cs.slice(from, c[0]).join("")); from = c[0];
    }
    parts.push(cs.slice(from).join(""));
    return parts.filter((x) => x.trim());
  };
  for (const sentence of splitAfter(text, STOPS)) {
    const phrases = splitAfter(sentence, PAUSES).flatMap(cut), total = capWidth(capText(sentence)), target = total / Math.ceil(total / max);
    let cur = "";
    for (const p of phrases) {   // pack phrases toward even widths, never over max
      const w0 = capWidth(capText(cur)), w1 = capWidth(capText(cur + p));
      if (cur && (w1 > max || Math.abs(w1 - target) > Math.abs(w0 - target))) { out.push(cur); cur = ""; }
      cur += p;
    }
    if (cur.trim()) out.push(cur);
  }
  return out.map((raw) => ({ raw, text: capText(raw) })).filter((c) => letters(c.raw));   // a "……" alone is a pause, not a caption
}
// from: "audio/captions.json" takes the cards bin/vh captions --cards wrote (cut at word boundaries with jieba and the
// manual break table) instead of cutting here; their times are the timeline's, so FILM.lead is added
let CAP_FILE = null;   // the cards loaded from FILM.caption.from in ready: [{ id, part, start, end, zh: [line], en: [line] }]
// the cards must be cards (each with its part: a plain bin/vh captions run, or bin/vh pace, writes wrapped blocks), one
// line no wider than FILM.caption.max (a character of slack: Latin counts 0.55 here, 0.5 there; one Latin word wider than
// that, a link, stands alone there and is let through), for this timeline's lines and this take of them (a card starts
// inside its line)
function checkCaptionFile(problems) {
  if (!CAP_FILE) return;
  const f = FILM.caption.from, blocks = CAP_FILE.filter((c) => !c || c.part === undefined), wide = [], stale = new Set(), moved = new Set();
  if (blocks.length) problems.push(`${f}: ${blocks.length} of ${CAP_FILE.length} item(s) are wrapped captions, not one-line cards: run bin/vh captions <project> --cards (a plain run or bin/vh pace wrote them)`);
  for (const c of CAP_FILE) {
    if (!c || c.part === undefined) continue;
    const text = [].concat(c[FILM.lang] || c.zh || c.en || []).join(" ").trim();
    if (capWidth(text) > FILM.caption.max + 1 && !/^[\x21-\x7e]+$/.test(text)) wide.push(`"${text}"`);
    const L = LINES[c.id];
    if (Object.keys(LINES).length && !L) stale.add(c.id);
    else if (L && isNum(c.start) && (c.start + FILM.lead < L.a - 0.3 || c.start + FILM.lead > L.b + 0.3)) moved.add(c.id);
  }
  const redo = FILM.lang === "en" ? `bin/vh captions <project> en --en-max ${Math.floor(FILM.caption.max / 0.55)} --cards` : `bin/vh captions <project> zh ${FILM.caption.max} --cards`;
  if (wide.length) problems.push(`${f}: ${wide.length} card(s) wider than FILM.caption.max (${FILM.caption.max}): ${wide.slice(0, 3).join(", ")}${wide.length > 3 ? " …" : ""} (${redo}; a card that still comes out too wide: reword it, or raise FILM.caption.max)`);
  if (stale.size) problems.push(`${f}: cards for narration lines this timeline does not have: ${[...stale].slice(0, 8).join(", ")} (made for another script? run bin/vh captions <project> --cards again)`);
  if (moved.size) problems.push(`${f}: cards that start outside their line's time in this timeline: ${[...moved].slice(0, 8).join(", ")} (made for another take? run bin/vh captions <project> --cards again)`);
}
function buildCaptions(nocap) {
  const C = FILM.caption;
  CAPS = [];
  if (CAP_FILE) for (const c of CAP_FILE) {
    const text = [].concat(c[FILM.lang] || c.zh || c.en || []).join(" ").trim();
    if (text && !nocap.has(c.id) && isNum(c.start) && isNum(c.end)) CAPS.push({ id: c.id, text, start: c.start + FILM.lead, end: c.end + FILM.lead });
  }
  else for (const id of LINE_IDS) {
    if (nocap.has(id)) continue;
    const L = LINES[id], times = letterTimes(L);
    let k = 0;
    const pieces = captionPieces(L.text, C.max).map((c) => { const at = times[k] ?? L.a; k += [...letters(c.raw)].length; return { id, text: c.text, at }; });
    pieces.forEach((c, i) => CAPS.push({ id, text: c.text, start: Math.max(L.a - 0.1, c.at - 0.1), end: i + 1 < pieces.length ? pieces[i + 1].at - 0.1 : L.b + C.hold }));
  }
  CAPS.sort((p, q) => p.start - q.start);
  for (let i = 0; i < CAPS.length; i++) {
    const c = CAPS[i], next = i + 1 < CAPS.length ? CAPS[i + 1].start : DUR - FILM.fadeOut;
    c.end = Math.min(Math.max(c.end, c.start + C.min), next);   // a short one borrows the pause after it, never the next caption's time
    if (next - c.end < 0.25 && i + 1 < CAPS.length) { c.end = next; c.joinNext = CAPS[i + 1].joinPrev = true; }   // no blink between two
    c.start = r3(c.start); c.end = r3(c.end);
  }
}
function captionAt(t) { for (const c of CAPS) if (t >= c.start && t < c.end) return c; return null; }

// ---- the recorder: what the shots show, gathered in ready (src/90-main.js draws every shot a few times with it on) ----
let REC = null;   // { events, reads } while recording, else null
let SHOT = null;  // the shot being drawn: { i, id, t0, t1, lt, u, o, din, dout, cover } (src/90-main.js sets it for every draw)
let COVER_NOW = null;   // the id of the cover being drawn (src/90-main.js, cover), null in the film's own frames: a shot's s.cover
// an event on screen at t0 (a card lands, a stamp is pressed): kind names it (the sound comes later, bin/vh sfx); o.x, a
// place that does not move with t, is read through the transform, so the event's x is a screen x (for panning). Helpers
// call it on every frame; it records only while recording, and only events that happen while their shot is on screen.
// Each of a shot's samples records it again: src/90-main.js keeps one per call, with x from the sample nearest t0.
function cue(kind, t0, o = {}) {
  if (!REC || !SHOT || !Number.isFinite(t0) || t0 < SHOT.t0 - 0.05 || t0 >= SHOT.t1 + SHOT.dout) return;
  const e = { t: r3(t0), kind, shot: SHOT.id, own: o.x, near: Math.abs(REC.at - t0) };
  if (o.x !== undefined) { const m = X.getTransform(); e.x = Math.round((m.a * o.x + m.c * (o.y ?? H / 2) + m.e) / PRX); }
  if (o.dur !== undefined) e.dur = o.dur;
  REC.events.push(e);
}
// a read: text the viewer must take in, fully shown from start to end (the format of readcheck's texts.json, which
// bin/vh textcheck judges). Kept to the part of the shot drawn straight into the frame (after its transition in) and
// clear of the fades at the film's ends. o: the kind ("onscreen", "label", "subtitle"), or { kind, overlay }. overlay:
// true is text that stays on screen across a cut or a transition (a HUD card each shot it spans draws, or a layer over
// the shots): kept to start..end, clear of the fades, not to this shot, so one read covers its whole time on screen
// (registered from any shot's draw; the same call from several is kept once). textcheck still samples it there.
function read(text, start, end, o = "onscreen") {
  if (!REC || !SHOT) return;
  const { kind = "onscreen", overlay = false } = typeof o === "string" ? { kind: o } : o || {};
  const a = Math.max(start, overlay ? 0 : SHOT.t0 + SHOT.din, FILM.fadeIn), b = Math.min(end, overlay ? DUR : SHOT.t1, DUR - FILM.fadeOut);
  if (b - a >= 0.3) REC.reads.push({ text: String(text), start: r3(a), end: r3(b), read: kind });
}
