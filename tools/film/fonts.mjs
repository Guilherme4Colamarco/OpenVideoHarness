// fonts check: is every character the film draws in the font it asks for? A font that lacks a character does not fail:
// the browser draws it in another font on the machine, or, when none has it, as the font's empty "missing" glyph. This
// draws the film at sampled times through the page contract (engines/CONTRACT.md), notes the text drawn on canvases and
// the DOM's text with their fonts, and asks the browser which font draws each character (tools/film/glyphs.mjs).
//
// usage: node tools/film/fonts.mjs <project | page.html> --browser <chrome> [--step 0.5] [--at t,…]
//          [--allow-fallback "Apple Color Emoji,…"] [--strict] [--out dir] [--soft-gl] [--frame-timeout 120] [--timeout 900]
//        (bin/vh fonts check finds the browser as bin/vh frames does)
//
//   --frame-timeout 120 a frame or a cover not drawn after this many seconds stops the check at once (exit 2), naming it:
//                    the page's frame never returned, or the browser stopped painting; --timeout bounds the whole run, and
//                    given alone it is a frame's cap too (as bin/vh frames). OVH_PAGE_TIMEOUT=S: how long the page may
//                    take to set window.film and to be ready (tools/film/host.mjs)
//
//   --step 0.5       draw a frame every 0.5 s (and the middle of every timed text the page lists, window.film.texts);
//                    text on screen for less than the step between those can be missed
//   --at t,…         only these times
//   --allow-fallback platform families a character may fall back to without failing (an emoji font, say)
//   --strict         a character the first family lacks fails even when a family named later in the same stack draws it
//                    ("Helvetica Neue", "PingFang SC": by default the Chinese drawn in PingFang is said, as the stack meant)
//   --out dir        where fonts.json goes (every character by font, with what draws it): default <project>/out/check
//
// What it sees: text a canvas draws with fillText or strokeText (the canvas-film engine, HyperFrames canvases, the
// hand-drawn engine's labels), and the DOM's text (HyperFrames compositions: every clip's text, shown or not; other pages:
// what is laid out at the sampled times). Not text in images or SVG <text>, nor text a WebGL scene draws from a font
// file of its own (p5 in WEBGL mode, three.js text): those carry their glyphs in the file, and no browser fallback is
// involved. Combining marks (accents, Indic vowel signs) are not checked on their own.
// Exit: 0 every character in its font · 1 characters drawn in another font, or by no font, or a face missing ·
// 2 could not check (no page, no window.film, not ready, no browser).
import fs from "node:fs";
import path from "node:path";
import { openFilm } from "./host.mjs";
import { HOOK, check, collectDom, report } from "./glyphs.mjs";
import "./activity.mjs";   // bin/vh exec's into this: the run's end line in the project's activity log

process.stdout.on("error", (e) => { if (e.code !== "EPIPE") throw e; });
const HELP = fs.readFileSync(new URL(import.meta.url), "utf8").split("\nimport ")[0].replace(/^\/\/ ?/gm, "");
const argv = process.argv.slice(2);
if (!argv.length || argv.includes("-h") || argv.includes("--help")) { process.stdout.write(HELP.trimEnd() + "\n"); process.exit(argv.length ? 0 : 2); }
let film = null;
const finish = async (code, msg) => {
  if (msg) console.error("fonts: " + msg);
  if (film) { const f = film; film = null; try { await f.close(); } catch { /* gone */ } }
  process.exit(code);
};
process.on("unhandledRejection", (e) => finish(2, (e && e.message) || String(e)));
const bail = (msg) => { console.error("fonts: " + msg); process.exit(2); };
const o = { step: 0.5, timeout: 900, frameTimeout: 120, runtime: "auto" };
let target = null, at = null, out = null, allow = [], strict = false, frameCap = null, timeoutGiven = false;
for (let i = 0; i < argv.length; i++) {
  const a = argv[i], [k, inline] = a.startsWith("--") && a.includes("=") ? [a.slice(0, a.indexOf("=")), a.slice(a.indexOf("=") + 1)] : [a, undefined];
  const val = () => { const v = inline !== undefined ? inline : argv[++i]; if (v === undefined) bail(`${k} needs a value`); return v; };
  const num = (v, what) => { const x = Number(v); if (v === "" || !Number.isFinite(x) || x < 0) bail(`${what}: ${v} is not a number ≥ 0`); return x; };
  if (k === "--step") { o.step = num(val(), k); if (!(o.step > 0)) bail("--step must be > 0"); }
  else if (k === "--at") at = val().split(",").map((v) => num(v.trim(), "--at"));
  else if (k === "--timeout") { o.timeout = num(val(), k); timeoutGiven = true; }
  else if (k === "--frame-timeout") { o.frameTimeout = num(val(), k); if (o.frameTimeout < 1) bail("--frame-timeout: seconds, at least 1"); frameCap = "--frame-timeout"; }
  else if (k === "--allow-fallback") allow = val().split(",").map((s) => s.trim()).filter(Boolean);
  else if (k === "--out") out = val();
  else if (k === "--strict") strict = true;
  else if (k === "--browser") o.browser = val();
  else if (k === "--soft-gl") o.softGl = true;
  else if (k.startsWith("-")) bail(`unknown option ${k} (-h for the options)`);
  else if (target) bail(`one project or page, got ${target} and ${a}`);
  else target = a;
}
if (!target) bail("which project or page? (-h for the usage)");
if (!o.browser) bail("no browser: pass --browser <chrome>, or run it as bin/vh fonts check");
if (!frameCap && timeoutGiven && o.timeout >= 1) { o.frameTimeout = o.timeout; frameCap = "--timeout"; }   // a raised --timeout raises a frame's cap with it

const watchdog = setTimeout(() => finish(2, `stopped after ${o.timeout} s (--timeout); a frame function that never returns?`), o.timeout * 1000);
watchdog.unref();
// one frame or cover: back within --frame-timeout, or the check stops there and says which (tools/film/frames.mjs does the same)
const timely = (p, what) => {
  let timer;
  p.catch(() => { /* given up on */ });
  return Promise.race([p, new Promise((_, no) => { timer = setTimeout(() => no(Object.assign(new Error(`${what}: no picture after ${o.frameTimeout} s ` +
    `(${frameCap || "--frame-timeout"}): the page's frame never returned, or the browser stopped painting`), { stuck: true })), o.frameTimeout * 1000); })]).finally(() => clearTimeout(timer));
};
try { film = await openFilm(target, { ...o, prelude: [HOOK] }); } catch (e) { await finish(2, e.message); }
const rel = (f) => { const r = path.relative(process.cwd(), f); return r && !r.startsWith("..") ? r : f; };
const T0 = Date.now();
let times = at;
if (!times) {
  if (!(film.duration > 0)) await finish(2, "the page gives no duration: pass --at");
  times = [];
  for (let t = o.step / 2; t < film.duration; t += o.step) times.push(+t.toFixed(3));
  const texts = (await film.list("texts").catch(() => null)) || [];
  for (const x of texts) { const m = (+x.start + +x.end) / 2; if (Number.isFinite(m) && m >= 0 && m < film.duration) times.push(+m.toFixed(3)); }
  times = [...new Set(times)].sort((a, b) => a - b);
}
const bad = times.filter((t) => t < 0 || (film.duration > 0 && t >= film.duration));
if (bad.length) await finish(2, `${bad.join(", ")} s: outside the film (0 up to ${film.duration} s)`);
let problems = 0;
for (const p of film.loadProblems) console.log(`  while loading: ${p}`);
for (const t of times) {
  try { await timely(film.draw(t).then(() => collectDom(film)), `t=${t} s`); }
  catch (e) { if (e.stuck) await finish(2, e.message); problems++; if (problems <= 5) console.log(`  t=${t} s: ${e.message}`); }
}
await collectDom(film, true);   // a HyperFrames composition: every clip's text, shown or not
for (const c of (await film.list("covers").catch(() => null)) || []) {   // covers draw titles of their own
  try { await timely(film.cover(c.id, c.t, { capture: false }), `cover ${c.id}`); } catch (e) { if (e.stuck) await finish(2, e.message); problems++; console.log(`  cover ${c.id}: ${e.message}`); }
  for (const r of Array.isArray(c.ratios) ? c.ratios : []) {   // and each ratio it lays out a title for
    try { await timely(film.cover(c.id, c.t, { ratio: r, capture: false }), `cover ${c.id} ${r}`); } catch (e) { if (e.stuck) await finish(2, e.message); problems++; console.log(`  cover ${c.id} ${r}: ${e.message}`); }
  }
}
let res;
try { res = await check(film, { allow, strict }); } catch (e) { await finish(2, e.message); }
console.log(`fonts: ${rel(film.page)} · ${times.length} frame${times.length === 1 ? "" : "s"}${at ? "" : ` (every ${o.step} s, and each timed text)`} · ` +
  `${res.chars} distinct character${res.chars === 1 ? "" : "s"} in ${res.fonts.length} font${res.fonts.length === 1 ? "" : "s"} · ${film.version} · ${((Date.now() - T0) / 1000).toFixed(0)} s`);
const [lines, wrong] = report(res);
for (const l of lines) console.log("  " + l.replace(/^✓/, "\x1b[32m✓\x1b[0m").replace(/^✗/, "\x1b[31m✗\x1b[0m"));
if (!res.fonts.length) console.log("  no text drawn at these times (canvas fillText / strokeText, or the DOM)");
const dir = path.resolve(out || path.join(film.root, "out", "check"));
try {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "fonts.json"), JSON.stringify({ page: film.page, browser: film.version, times: times.length, fonts: res.fonts }, null, 1) + "\n");
  console.log(`  every character by font: ${rel(path.join(dir, "fonts.json"))}`);
} catch (e) { console.log(`  could not write ${rel(dir)}/fonts.json: ${e.message}`); }
if (wrong) console.log("  a font that lacks a character: name a face that has it first in its @font-face src, give that text another family, or change the text; bin/vh fonts list shows the fonts on this machine");
if (problems) console.log(`  ${problems} frame${problems > 1 ? "s" : ""} could not be drawn: bin/vh frames shows why`);
await finish(wrong || problems ? 1 : 0);
