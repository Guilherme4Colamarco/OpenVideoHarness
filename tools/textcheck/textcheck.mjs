// textcheck: is the text drawn into a canvas covered by the picture, or too close to it in brightness to read?
// `npx hyperframes check` measures DOM text only; text a script draws into a <canvas> is pixels to it.
//
// usage: node tools/textcheck/textcheck.mjs <project | composition.html> --browser <chrome> [--texts f.json]
//          [--min-visible 0.7] [--min-contrast 3] [--samples 3] [--scan-step 1] [--caption-step 0.5] [--caption-close 0.12]
//          [--ui-step 1] [--ui-share 0.002] [--out dir] [--soft-gl] [--frame-timeout 120] [--timeout 900]
//        (bin/vh textcheck finds the browser: CHROME_PATH, the chrome-headless-shell `hyperframes render` uses for the
//         project, the newest one in ~/.cache/puppeteer, then Chrome or Chromium)
//
// The composition opts in with the page contract (engines/CONTRACT.md; engines/README.md, "画面文字检查"):
//     window.film = { frame: (t) => drawFrame(t), duration: 24.8, texts: TEXTS };
// (the older window.__vh = { draw, texts } still works). frame(t) draws the frame at t seconds (and the DOM it controls,
// such as a caption), the same picture the render shows at t; it may return a promise. texts (optional) is the registry of
// reads, the format of readcheck's texts.json:
// [{text, start, end, read?}]. Without it the registry is --texts, else <project>/out/texts.json, else none.
// The page is served from its folder on 127.0.0.1, at the composition's data-width x data-height, device scale 1; the
// check waits for window.__hf.buildReady (HyperFrames' own convention), the contract's ready and the fonts.
//
// Nothing else in the film changes: before its scripts run, the check hooks the canvas's fillText and strokeText, so it
// knows every text drawn, with its transform and font, and can draw a frame again without one of them. For each read:
//   A  the frame at t; B  the same frame with only this read left out; M  the read alone (opaque white) as a mask.
//   visible   the share of the read's own pixels where A differs from B: under --min-visible (0.7) something is drawn
//             over it, or it is the colour of the picture under it
//   contrast  the larger of: its contrast with the picture under it (the median over its pixels of A against B), and
//             with what is right around it in A (2–4 px out: an outline, a shadow or a plate counts); under
//             --min-contrast (3:1, WCAG's figure for large text) it is hard to read
//   frame     drawn outside the canvas, or cut by its edge
//   caption   its box meets the lines of a DOM caption showing at that moment
// A read is matched to the calls that spell it, whitespace, punctuation and symbols left out (a film draws a "·" or an
// arrow as a shape, and kinetic type one character at a time); a read drawn in several copies (a glow pass and a crisp
// one, an outline and a fill) counts as one, and of copies in different places the most legible one counts.
// Each read is sampled --samples (3) times across its window, from 0.4 s after its start to 0.3 s before its end;
// samples where it is still fading (alpha under 0.95) are not judged when an opaque one exists.
//
// The picture is what the viewer sees there: every canvas, video and image of the page over its background, so text on
// a transparent layer is measured against the layer behind it; other DOM (CSS backgrounds, SVG) is not part of it.
//
// Also, never failing the run: canvas text outside the registry (every --scan-step seconds, each distinct line judged
// once, at the middle of its longest opaque stretch; a line never seen at half opacity or more is left out); registered reads not drawn as canvas text at some or all of their
// samples (an image, DOM text, or a window that is off); and DOM captions (data-read="subtitle", readcheck's mark) over
// a bright picture: every --caption-step seconds, the share of the canvas pixels under the caption's own lines that are
// within 3:1 of its colour, over --caption-close (0.12). CSS text-shadow and strokes usually carry such a caption: look.
//
// And the interface over the scene, never failing the run either: a page that says where its interface (a chapter bar,
// a caption, a credit) puts its ink, window.film.ui(t) → [{name, box: [x0, y0, x1, y1]}], and draws the frame without it
// on frame(t, { layer: "scene" }) (engines/CONTRACT.md), is drawn both ways every --ui-step seconds: where the scene alone
// has detail inside a box (a line, an edge, a letter: a pixel 60 or more over r + g + b off the scene's ground there,
// each 32 x 32 px tile's median colour blended between tile centres; a plain or shaded background and the grain are
// not), on over --ui-share (0.002) of the box's pixels and at least 30 of them, or on 150 pixels or more in a long box,
// or in a piece that runs right across the box's short side, the scene runs under the interface. Each run of samples is listed once, with the largest share: a small one is a line
// or a shape crossing the bar or the caption (move one of them), a large one a busy picture under it. A ui(t) that
// throws is a page error, like a frame that throws.
//
// --frame-timeout 120: a frame not drawn within this many seconds stops the check at once (exit 2), naming its t: the
// page's frame never returned, or its script is stuck; --timeout (900 s) bounds the whole run, and given alone it is a
// frame's cap too. The page's ready and its fonts may take OVH_PAGE_TIMEOUT seconds when it is set, else a frame's cap,
// at least 120 s each (as bin/vh frames).
//
// Writes <out>/textcheck.json (every number) and a crop per finding (<out>/<t>s-<kind>.png); out defaults to
// <project>/out/check/textcheck. Exit: 0 no read failed (warnings allowed) · 1 a registered read is covered, under the
// contrast, outside or cut by the frame, or under a caption, or the frame function threw · 2 could not check (no
// window.film.frame nor window.__vh.draw, the page did not load, no browser, or no canvas text measured at all): not a pass.
import fs from "node:fs";
import path from "node:path";
import { BrowserGone, launchTab, serve } from "./browser.mjs";
import "../film/activity.mjs";   // bin/vh exec's into this: the run's end line in the project's activity log

process.stdout.on("error", (e) => { if (e.code !== "EPIPE") throw e; });   // a reader that stops early (| head) does not leave Chrome behind
// Node exits 1 on an unhandled rejection, which here means "a read failed"; a stray one is a failure to check (2)
process.on("unhandledRejection", (e) => { console.error("textcheck: " + ((e && e.message) || e)); process.exitCode = 2; });
const HELP = fs.readFileSync(new URL(import.meta.url), "utf8").split("\nimport ")[0].replace(/^\/\/ ?/gm, "");
const argv = process.argv.slice(2);
if (!argv.length || argv.includes("-h") || argv.includes("--help")) { process.stdout.write(HELP); process.exit(argv.length ? 0 : 2); }
const opt = { minVisible: 0.7, minContrast: 3, samples: 3, scanStep: 1, captionStep: 0.5, captionClose: 0.12, uiStep: 1, uiShare: 0.002, timeout: 900, frameTimeout: 120 };
const NUM = { "--min-visible": "minVisible", "--min-contrast": "minContrast", "--samples": "samples", "--scan-step": "scanStep", "--caption-step": "captionStep",
  "--caption-close": "captionClose", "--ui-step": "uiStep", "--ui-share": "uiShare", "--timeout": "timeout", "--frame-timeout": "frameTimeout" };
const given = new Set();   // --timeout given alone is a frame's cap too, as in bin/vh frames
const BUSY = 0.15;   // a share of detail from which the scene under a box is a busy picture rather than a piece crossing it
let target = null, browserPath = null, textsFile = null, outDir = null, softGl = false;
const die = (msg) => { console.error("textcheck: " + msg); process.exit(2); };   // before the browser starts
class Stop extends Error {}
const stop = (msg) => { throw new Stop(msg); };                                  // after: the finally below closes it
for (let i = 0; i < argv.length; i++) {
  const a = argv[i], [k, inline] = a.startsWith("--") && a.includes("=") ? [a.slice(0, a.indexOf("=")), a.slice(a.indexOf("=") + 1)] : [a, undefined];
  const val = () => { const v = inline !== undefined ? inline : argv[++i]; if (v === undefined) die(`${k} needs a value`); return v; };
  if (NUM[k]) { const v = Number(val()); if (!Number.isFinite(v) || v < 0) die(`${k}: not a number ≥ 0`); if (k === "--frame-timeout" && v < 1) die("--frame-timeout: seconds, at least 1"); opt[NUM[k]] = v; given.add(k); }
  else if (k === "--browser") browserPath = val();
  else if (k === "--texts") textsFile = val();
  else if (k === "--out") outDir = val();
  else if (k === "--soft-gl") softGl = true;
  else if (k.startsWith("-")) die(`unknown option ${k} (-h for the options)`);
  else if (target) die(`one project or composition, got ${target} and ${a}`);
  else target = a;
}
if (!target) die("which project or composition? (-h for the usage)");
if (!browserPath) die("no browser: pass --browser <chrome>, or run it as bin/vh textcheck");
if (opt.samples < 1) opt.samples = 1;
const capFrom = given.has("--frame-timeout") ? "--frame-timeout" : given.has("--timeout") ? "--timeout" : "--frame-timeout";
if (!given.has("--frame-timeout") && given.has("--timeout") && opt.timeout >= 1) opt.frameTimeout = opt.timeout;
// the page's own waits (ready, the fonts): OVH_PAGE_TIMEOUT seconds when set, else as long as a frame may take, at least
// 120 s each, as tools/film/host.mjs bounds them
const envWait = Number(process.env.OVH_PAGE_TIMEOUT), waitS = envWait > 0 ? envWait : Math.max(120, opt.frameTimeout), readyS = 2 * waitS + 10;

let html = path.resolve(target);
// a project folder: its film.html (the canvas-film engine's page), else its index.html, as bin/vh frames looks
if (fs.existsSync(html) && fs.statSync(html).isDirectory()) html = ["film.html", "index.html"].map((n) => path.join(html, n)).find((f) => fs.existsSync(f)) || path.join(html, "index.html");
if (!fs.existsSync(html)) die(`no composition at ${html}`);
const dir = path.dirname(html), project = dir;
outDir = path.resolve(outDir || path.join(project, "out", "check", "textcheck"));
const src = fs.readFileSync(html, "utf8"), rootTag = (src.match(/<[^>]*\bdata-composition-id\b[^>]*>/) || [""])[0];
const attr = (n) => { const m = rootTag.match(new RegExp(`\\b${n}="([\\d.]+)"`)); return m ? +m[1] : 0; };
const W = attr("data-width") || 1920, H = attr("data-height") || 1080;

// the registry of reads: --texts, else the page's texts (window.film.texts or window.__vh.texts), else out/texts.json (what bin/vh readcheck --export saves)
function items(j) {
  const list = Array.isArray(j) ? j : j && (j.texts || j.items || j.captions || j.cues);
  if (!Array.isArray(list)) return null;
  return list.map((x) => ({ text: Array.isArray(x.text) ? x.text.join("\n") : x.text, start: +(x.start ?? x.t0), end: +(x.end ?? x.t1), read: x.read || "onscreen" }))
    .filter((x) => typeof x.text === "string" && x.text.trim() && Number.isFinite(x.start) && Number.isFinite(x.end));
}
const fmt = (t) => t.toFixed(2).padStart(7) + " s";
const pct = (x) => Math.round(100 * x) + "%";
const short = (s) => { const one = s.replace(/\s+/g, " ").trim(); return [...one].length > 40 ? [...one].slice(0, 39).join("") + "…" : one; };
const sampleTimes = (a, b, n) => {
  const d = b - a; if (!(d > 0)) return [];
  const lo = a + Math.min(0.4, d / 4), hi = b - Math.min(0.3, d / 4);
  if (n <= 1 || hi - lo < 0.2) return [+((lo + hi) / 2).toFixed(3)];
  return Array.from({ length: n }, (_, i) => +(lo + ((hi - lo) * i) / (n - 1)).toFixed(3));
};
const steps = (step, dur) => { const out = []; if (step > 0) for (let t = step / 2; t < dur; t += step) out.push(+t.toFixed(3)); return out; };
const FAIL = ["outside", "cut", "caption", "covered", "contrast"];
const SAY = { outside: () => "outside the frame", cut: () => "cut by the frame edge", caption: () => "under a caption", covered: (r) => `${pct(r.share)} visible`,
  contrast: (r) => `contrast ${r.under.toFixed(1)}:1 with the picture, ${r.edge.toFixed(1)}:1 with its edge` };
const words = (r) => r.flags.filter((f) => FAIL.includes(f)).map((f) => SAY[f](r)).join(", ");

const flags = softGl ? ["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"]
  : process.platform === "darwin" ? ["--use-angle=metal", "--ignore-gpu-blocklist"] : ["--ignore-gpu-blocklist"];
if (process.platform === "linux") flags.push("--no-sandbox", "--disable-dev-shm-usage");

let browser = null, server = null;
const watchdog = setTimeout(async () => { console.error(`textcheck: stopped after ${opt.timeout} s (--timeout); a frame function that never returns?`); try { await browser?.close(); } catch { /* gone */ } process.exit(2); }, opt.timeout * 1000);
watchdog.unref();
try {
  server = await serve(dir);
  let s;
  try { ({ browser, sessionId: s } = await launchTab(browserPath, flags, ["Page", "Runtime"])); } catch (e) { stop(`could not start ${browserPath}: ${e.message}`); }
  const loadErrors = [];
  browser.on("Runtime.exceptionThrown", (p) => loadErrors.push((p.exceptionDetails.exception && p.exceptionDetails.exception.description) || p.exceptionDetails.text));
  await browser.send("Emulation.setDeviceMetricsOverride", { width: W, height: H, deviceScaleFactor: 1, mobile: false }, s);
  await browser.send("Page.addScriptToEvaluateOnNewDocument", { source: fs.readFileSync(new URL("./page.js", import.meta.url), "utf8") }, s);
  const rawEv = async (expression) => {
    const r = await browser.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true }, s);
    if (r.exceptionDetails) throw new Error((r.exceptionDetails.exception && r.exceptionDetails.exception.description) || r.exceptionDetails.text);
    return r.result.value;
  };
  // a frame not back within --frame-timeout stops the check (exit 2) and names its t: while an evaluation is out, the page
  // is asked once a second what it draws and for how long (page.js busy()); a page that does not answer within the bound
  // is stuck in its script (a loop that never ends) or the browser stopped
  let lastT = null;
  const ev = (expression) => new Promise((ok, no) => {
    let done = false, timer = null;
    const end = () => { done = true; clearTimeout(timer); };
    const stuck = (msg) => { if (!done) { end(); no(new Stop(msg)); } };
    const tick = () => {
      if (done) return;
      let answered = false;
      const bound = setTimeout(() => { if (!answered) stuck(`${lastT !== null ? `t=${lastT} s: ` : ""}the page does not answer after ${opt.frameTimeout} s (${capFrom}): its script is stuck, or the browser stopped`); }, opt.frameTimeout * 1000);
      bound.unref();
      rawEv("window.__vhTC && window.__vhTC.busy ? window.__vhTC.busy() : null").then((b) => {
        answered = true; clearTimeout(bound);
        if (done) return;
        if (b) { lastT = b.t; if (b.ms > opt.frameTimeout * 1000) return stuck(`t=${b.t} s: no picture after ${opt.frameTimeout} s (${capFrom}): the page's frame never returned`); }
        timer = setTimeout(tick, 1000); timer.unref();
      }, () => { answered = true; clearTimeout(bound); if (!done) { timer = setTimeout(tick, 1000); timer.unref(); } });
    };
    timer = setTimeout(tick, 1000); timer.unref();
    rawEv(expression).then((v) => { if (!done) { end(); ok(v); } }, (e) => { if (!done) { end(); no(e); } });
  });
  const call = (fn, ...args) => ev(`window.__vhTC.${fn}(${args.map((a) => JSON.stringify(a)).join(", ")})`);
  const loaded = browser.once("Page.loadEventFired", s);
  loaded.catch(() => { /* a browser that dies first fails it; the race below reports that */ });
  await browser.send("Page.navigate", { url: server.url + encodeURIComponent(path.basename(html)) }, s);
  let loadTimer;
  await Promise.race([loaded, new Promise((_, rej) => { loadTimer = setTimeout(() => rej(new Error("the page did not load within 60 s")), 60000); })]).catch((e) => stop(e.message)).finally(() => clearTimeout(loadTimer));
  let readyTimer;
  const ready = await Promise.race([rawEv(`(async () => {
    const wait = (p) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error("not ready after ${waitS} s")), ${waitS * 1000}))]);
    try { await wait(Promise.all(Object.values((window.__hf && window.__hf.buildReady) || {})));
      const src = window.film && typeof window.film.frame === "function" ? window.film : window.__vh || {};
      let r = src.ready; if (typeof r === "function") r = r.call(src);   // a method, as OpenFilm's hosts call it
      if (r) await wait(r); await wait(document.fonts.ready); }
    catch (e) { return String(e && e.message || e); }
    return "";
  })()`), new Promise((_, rej) => { readyTimer = setTimeout(() => rej(new Stop(`not ready after ${readyS} s, and the page does not answer (its script is stuck, or the browser stopped)`)), readyS * 1000); })])
    .finally(() => clearTimeout(readyTimer));
  if (ready) stop(`${ready} (window.__hf.buildReady, window.film.ready, window.__vh.ready or the fonts)`);
  const T0 = Date.now(), phase = (name) => { if (process.env.TEXTCHECK_TIMING) console.error(`  [${((Date.now() - T0) / 1000).toFixed(1)} s] ${name}`); };
  const info = await call("info");
  if (!info.draw) {
    stop(`${path.relative(process.cwd(), html) || html} has no window.film.frame(t) (nor the older window.__vh.draw), so nothing can be drawn on demand. Add one line to the composition's inline script:\n` +
      `    window.film = { frame: (t) => drawFrame(t), duration: 24.8 };   // your function that draws frame t, and the length; texts: [...] optional\n` +
      `(engines/CONTRACT.md; engines/README.md, "画面文字检查")` + (loadErrors.length ? `\npage errors while loading:\n  ${[...new Set(loadErrors)].slice(0, 5).join("\n  ")}` : ""));
  }
  let reg = null, regFrom = "";
  if (textsFile) { try { reg = items(JSON.parse(fs.readFileSync(textsFile, "utf8"))); } catch (e) { stop(`--texts ${textsFile}: ${e.message}`); } if (!reg) stop(`--texts ${textsFile}: not a list of {text, start, end}`); regFrom = path.relative(process.cwd(), textsFile) || textsFile; }
  else if (info.texts) { reg = items(info.texts); if (!reg) stop("the page's texts (window.film.texts or window.__vh.texts) is not a list of {text, start, end}"); regFrom = "the page's texts"; }
  else if (fs.existsSync(path.join(project, "out", "texts.json"))) { reg = items(JSON.parse(fs.readFileSync(path.join(project, "out", "texts.json"), "utf8"))) || []; regFrom = "out/texts.json"; }
  reg = reg || [];
  const dur = info.duration || Math.max(0, ...reg.map((x) => x.end));
  if (!(dur > 0)) stop("no length: give window.film a duration (or window.__vh, or the composition root a data-duration)");
  console.log(`textcheck: ${path.basename(html)} · ${W}x${H} · ${dur} s · ${browser.version}`);
  console.log(`  reads: ${reg.length ? `${reg.length} from ${regFrom}, ${opt.samples} sample(s) each` : "no registry (the page's texts, --texts or out/texts.json): only the scan below"}` +
    ` · canvas text outside it: ${opt.scanStep > 0 ? `every ${opt.scanStep} s` : "off"} · captions: ${opt.captionStep > 0 ? `every ${opt.captionStep} s` : "off"}` +
    ` · interface over the scene: ${!info.ui ? "no window.film.ui" : opt.uiStep > 0 ? `every ${opt.uiStep} s` : "off"}`);

  // 1 the registered reads
  const reads = [];
  for (const x of reg) {
    const times = sampleTimes(x.start, x.end, opt.samples);
    if (!times.length) { reads.push({ ...x, status: "bad window" }); continue; }
    const smp = await call("read", x.text, times, opt), found = smp.filter((r) => r.found);
    const r = { ...x, samples: smp };
    if (!found.length) {
      const d = await call("dom", x.text, times[Math.floor(times.length / 2)]);
      r.status = d.dom ? (d.subtitle ? "dom caption" : "dom") : "not drawn";
    } else {
      const opaque = found.filter((q) => q.alpha >= 0.95), judged = opaque.length ? opaque : found;
      const fails = judged.filter((q) => q.flags.some((f) => FAIL.includes(f)));
      const score = (q) => (q.contrast || 0) * (q.share || 0);
      r.worst = fails.length ? fails.sort((a, b) => b.flags.length - a.flags.length || score(a) - score(b))[0] : judged.slice().sort((a, b) => score(a) - score(b))[0];
      // drawn, but nothing judged could be measured (a glyph too small or squeezed to nothing): not a pass
      r.status = fails.length ? "fail" : judged.some((q) => q.share !== undefined) ? "ok" : "unmeasured";
      r.missingAt = smp.filter((q) => !q.found).map((q) => q.t);
      r.faded = !opaque.length;
      r.unstable = found.some((q) => q.flags.includes("unstable"));
    }
    reads.push(r);
  }
  phase("reads");
  // 2 canvas text outside the registry
  const regKeys = (await ev(`${JSON.stringify(reg.map((x) => x.text))}.map(window.__vhTC.keyOf)`)).filter(Boolean);
  let fading = 0;
  const extra = [], ts = steps(opt.scanStep, dur), lines = opt.scanStep > 0 ? await call("lines", ts) : [];
  const lineKeys = await ev(`${JSON.stringify(lines.map((l) => l.text))}.map(window.__vhTC.keyOf)`);
  for (const [i, l] of lines.entries()) {
    const k = lineKeys[i];
    if (regKeys.some((r) => r.includes(k) || k.includes(r))) continue;
    // judge it once: the middle of its longest run of opaque samples, else its most opaque one
    const hits = l.hits;
    if (Math.max(...hits.map((h) => h[1])) < 0.5) { fading++; continue; }   // only ever seen fading in or out
    let best = [], run = [];
    for (const h of hits) { if (h[1] >= 0.95 && run.length && ts.indexOf(h[0]) === ts.indexOf(run[run.length - 1][0]) + 1) run.push(h); else run = h[1] >= 0.95 ? [h] : []; if (run.length > best.length) best = run.slice(); }
    const h = best.length ? best[Math.floor(best.length / 2)] : hits.slice().sort((a, b) => b[1] - a[1])[0];
    const [q] = await call("read", l.text, [h[0]], opt, h[2]);
    extra.push({ text: l.text, seen: [hits[0][0], hits[hits.length - 1][0]], sample: q, flagged: !!(q.found && q.flags.some((f) => FAIL.includes(f))) });
  }
  phase("canvas text outside the registry");
  // 3 DOM captions over a bright picture: each caption's worst sample
  const capByText = new Map();
  for (const c of opt.captionStep > 0 && info.subtitles ? await call("captions", steps(opt.captionStep, dur)) : []) {
    const k = capByText.get(c.text);
    if (!k) capByText.set(c.text, { text: c.text, samples: 1, worst: c }); else { k.samples++; if (c.close > k.worst.close) k.worst = c; }
  }
  const caps = [...capByText.values()], capBad = caps.filter((c) => c.worst.close > opt.captionClose);
  phase("captions");
  // 4 the interface over the scene: runs of samples where the scene has detail under one of the interface's boxes
  const ui = { checked: 0, spans: [], ignored: null };
  if (info.ui && opt.uiStep > 0) {
    const uts = steps(opt.uiStep, dur), got = await call("ui", uts, W, H);
    if (got.ignored) ui.ignored = got;
    else {
      const hit = (q) => q.px >= 30 && (q.share > opt.uiShare || q.px >= 150 || q.across);   // a short line across a long bar
      ui.checked = got.samples.length;
      const open = new Map();   // name → the span still growing
      for (const q of got.samples) {
        const k = q.name, sp = open.get(k), i = uts.indexOf(q.t);
        if (!hit(q)) continue;
        if (sp && sp.last === i - 1) { sp.last = i; sp.to = q.t; if (q.share > sp.worst.share) sp.worst = q; }
        else { const n = { name: k, from: q.t, to: q.t, last: i, worst: q }; open.set(k, n); ui.spans.push(n); }
      }
      for (const sp of ui.spans) { delete sp.last; sp.busy = sp.worst.share >= BUSY; }
    }
  }
  phase("interface");
  const errors = await call("errors");

  // report
  const failed = reads.filter((r) => r.status === "fail"), ok = reads.filter((r) => r.status === "ok");
  const notDrawn = reads.filter((r) => r.status === "not drawn"), part = reads.filter((r) => r.status === "ok" || r.status === "fail").filter((r) => r.missingAt.length);
  const unmeasured = reads.filter((r) => r.status === "unmeasured");
  const dom = reads.filter((r) => r.status.startsWith("dom")), badWin = reads.filter((r) => r.status === "bad window");
  const unstable = reads.filter((r) => r.unstable), extraBad = extra.filter((e) => e.flagged);
  fs.mkdirSync(outDir, { recursive: true });
  for (const f of fs.readdirSync(outDir)) if (/^[\d.]+s-[a-z-]+(-\d+)?\.png$/.test(f)) fs.rmSync(path.join(outDir, f));
  const crops = new Map();
  const crop = async (t, box, kind) => {
    if (!box || crops.size >= 60) return "";
    const m = 40, x = Math.max(0, Math.floor(box[0]) - m), y = Math.max(0, Math.floor(box[1]) - m);
    const w = Math.min(W, Math.ceil(box[2]) + m) - x, h = Math.min(H, Math.ceil(box[3]) + m) - y;
    if (w <= 0 || h <= 0) return "";
    await call("show", t);
    let name = `${t.toFixed(2)}s-${kind}.png`;
    for (let i = 2; crops.has(name); i++) name = `${t.toFixed(2)}s-${kind}-${i}.png`;
    const shot = await browser.send("Page.captureScreenshot", { format: "png", clip: { x, y, width: w, height: h, scale: 1 } }, s);
    fs.writeFileSync(path.join(outDir, name), Buffer.from(shot.data, "base64")); crops.set(name, true);
    return name;
  };
  const G = "\x1b[32m✓\x1b[0m", R = "\x1b[31m✗\x1b[0m", Y = "\x1b[33m!\x1b[0m";
  if (reg.length) {
    if (ok.length) console.log(`${G} ${ok.length} read(s) in the frame, at least ${pct(opt.minVisible)} visible and ${opt.minContrast}:1`);
    if (failed.length) console.log(`${R} ${failed.length} read(s) covered, under ${opt.minContrast}:1, outside or cut by the frame, or under a caption:`);
    for (const r of failed) { const w = r.worst; w.crop = await crop(w.t, w.box, w.flags.find((f) => FAIL.includes(f))); console.log(`   ${fmt(w.t)}  ${words(w)}  ${short(r.text)}`); }
    if (unmeasured.length) console.log(`${Y} ${unmeasured.length} read(s) drawn, but too small to measure at every sample: ${unmeasured.map((r) => short(r.text)).join(" · ")}`);
    if (notDrawn.length) console.log(`${Y} ${notDrawn.length} read(s) not drawn as canvas text at any sample (an image? a window that is off?): ${notDrawn.map((r) => short(r.text)).join(" · ")}`);
    if (part.length) console.log(`${Y} ${part.length} read(s) missing from some samples inside their window (on screen for less than registered?):`);
    for (const r of part.slice(0, 12)) console.log(`   not at ${r.missingAt.map((t) => t.toFixed(2)).join(", ")} s (window ${r.start}–${r.end} s)  ${short(r.text)}`);
    if (part.length > 12) console.log(`   … ${part.length - 12} more in textcheck.json`);
    if (dom.length) console.log(`  ${dom.length} read(s) are DOM text, not canvas: npx hyperframes check measures those${dom.some((r) => r.status === "dom caption") ? "; captions are in the caption scan below" : ""}`);
    if (badWin.length) console.log(`${Y} ${badWin.length} read(s) with end ≤ start, not checked: ${badWin.map((r) => short(r.text)).join(" · ")}`);
    if (reads.some((r) => r.faded)) console.log(`${Y} ${reads.filter((r) => r.faded).length} read(s) never fully opaque at their samples (judged anyway): ${reads.filter((r) => r.faded).map((r) => short(r.text)).join(" · ")}`);
  }
  if (opt.scanStep > 0) {
    if (extraBad.length) console.log(`${Y} ${extraBad.length} of ${extra.length} canvas text line(s) outside the registry are covered, under ${opt.minContrast}:1 or out of the frame (if a viewer should read one, register it):`);
    else console.log(`${G} ${extra.length} canvas text line(s) outside the registry: none covered, under ${opt.minContrast}:1 or out of the frame`);
    for (const e of extraBad.sort((a, b) => (a.sample.contrast || 0) - (b.sample.contrast || 0)).slice(0, 15)) { const q = e.sample; q.crop = await crop(q.t, q.box, "extra"); console.log(`   ${fmt(q.t)}  ${words(q)}  ${short(e.text)}`); }
    if (extraBad.length > 15) console.log(`   … ${extraBad.length - 15} more in textcheck.json`);
    if (fading) console.log(`  ${fading} more line(s) only seen under half opacity, fading in or out: not judged`);
  }
  if (info.subtitles && opt.captionStep > 0) {
    if (capBad.length) console.log(`${Y} ${capBad.length} of ${caps.length} caption(s) over a bright picture (over ${pct(opt.captionClose)} of the pixels under their lines within 3:1 of the caption's colour; a text-shadow may carry it, look):`);
    else console.log(`${G} ${caps.length} caption(s): the picture under their lines stays apart from their colour`);
    for (const c of capBad.sort((a, b) => b.worst.close - a.worst.close).slice(0, 15)) { c.worst.crop = await crop(c.worst.t, c.worst.box, "caption"); console.log(`   ${fmt(c.worst.t)}  ${pct(c.worst.close)} within 3:1  ${short(c.text)}`); }
    if (capBad.length > 15) console.log(`   … ${capBad.length - 15} more in textcheck.json`);
  }
  if (ui.ignored) console.log(`${Y} the page gives window.film.ui, but frame(t, { layer: "scene" }) drew the ${ui.ignored.name} too (at ${ui.ignored.t} s): the interface over the scene was not checked (engines/CONTRACT.md)`);
  else if (info.ui && opt.uiStep > 0) {
    const cross = ui.spans.filter((sp) => !sp.busy), busy = ui.spans.filter((sp) => sp.busy);
    const say = (sp) => `   ${fmt(sp.from)}${sp.to > sp.from ? ` – ${sp.to.toFixed(2)} s` : "     "}  ${sp.name}: ${(100 * sp.worst.share).toFixed(1)}% of its box over the scene's detail` +
      ` (x ${sp.worst.at[0]}–${sp.worst.at[2]}, y ${sp.worst.at[1]}–${sp.worst.at[3]})`;
    if (!ui.checked) console.log(`  the interface over the scene: window.film.ui gave no box at any sample, nothing to check`);
    else if (!ui.spans.length) console.log(`${G} the interface over the scene: at ${ui.checked} box sample(s) the scene keeps out of the interface's boxes`);
    if (cross.length) console.log(`${Y} ${cross.length} time(s) the scene draws a line, an edge or a letter under the interface (move the scene's piece, or the interface; look at the crop):`);
    for (const sp of cross.slice(0, 15)) { sp.worst.crop = await crop(sp.worst.t, sp.worst.box, "ui"); console.log(say(sp)); }
    if (cross.length > 15) console.log(`   … ${cross.length - 15} more in textcheck.json`);
    if (busy.length) console.log(`${Y} ${busy.length} time(s) the interface sits over a busy picture (over ${pct(BUSY)} of a box is detail: a plate or a darker band should carry it; look):`);
    for (const sp of busy.slice(0, 8)) { sp.worst.crop = await crop(sp.worst.t, sp.worst.box, "ui-busy"); console.log(say(sp)); }
    if (busy.length > 8) console.log(`   … ${busy.length - 8} more in textcheck.json`);
  }
  if (unstable.length) console.log(`${Y} ${unstable.length} read(s) at a time where the frame drawn twice is not the same (hard rule 1); their numbers are unreliable: ${unstable.map((r) => short(r.text)).join(" · ")}`);
  const errs = [...new Map(errors.map((e) => [e.msg.split("\n")[0], e])).values()];
  if (errs.length) { console.log(`${R} the frame function threw or logged an error at ${errs.length} point(s):`); for (const e of errs.slice(0, 8)) console.log(`   ${fmt(e.t)}  ${e.msg.split("\n")[0]}`); }
  // nothing measured is not a pass: no registered read was found and measured as canvas text, and no other line was seen
  const nothing = !extra.length && !reads.some((r) => r.status === "ok" || r.status === "fail");
  if (nothing) console.log(`${R} nothing measured: no canvas text found${reg.length ? " for any registered read" : ""}. Is the text drawn some other way (DOM, WebGL, images, an offscreen canvas)?`);
  fs.writeFileSync(path.join(outDir, "textcheck.json"), JSON.stringify({ composition: html, size: [W, H], duration: dur, registry: regFrom || null, options: opt, reads, extra, captions: caps, ui, errors }, null, 1));
  const rel = (p) => { const r = path.relative(process.cwd(), p); return r && !r.startsWith("..") ? r : p; };
  console.log(`  ${crops.size ? `crops: ${rel(outDir)}/*.png · ` : ""}every number: ${rel(path.join(outDir, "textcheck.json"))}`);
  if (nothing) process.exitCode = 2;
  else process.exitCode = failed.length || errs.length ? 1 : 0;
} catch (e) {
  console.error("textcheck: " + ((e && e.message) || e) + (e instanceof Stop || e instanceof BrowserGone ? "" : "\n" + (e && e.stack || "")));
  process.exitCode = 2;
} finally {
  // cleaning up never changes the verdict: the exit code is already set
  clearTimeout(watchdog);
  try { if (browser) await browser.close(); } catch (e) { console.error("textcheck: closing the browser: " + ((e && e.message) || e)); }
  try { if (server) await server.close(); } catch { /* the process is exiting anyway */ }
}
