// The film host (engines/CONTRACT.md): opens a page in headless Chrome, served from its folder on 127.0.0.1, sets
// window.filmHost and the clock before the page's scripts run, waits for window.film (or the older window.__vh) and its
// `ready`, then draws any t and captures the viewport as a lossless PNG. A HyperFrames composition that writes neither
// gets HyperFrames' own runtime and tools/film/hf-adapter.js before </head>, where HyperFrames' preview puts its runtime.
// No npm packages: the browser is driven over the DevTools protocol (tools/textcheck/browser.mjs).
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { launchTab } from "../textcheck/browser.mjs";

const HERE = path.dirname(new URL(import.meta.url).pathname);
const HARNESS = path.resolve(HERE, "..", "..");
const RUNTIME = path.join("node_modules", "hyperframes", "dist", "hyperframe.runtime.iife.js");
export const PAGES = ["film.html", "index.html", "studio.html"];   // what a project folder offers, in this order
export class HostError extends Error {}                            // could not draw at all: the caller exits 2

// the page a target names: the file itself, or the first of PAGES in a folder
export function findPage(target) {
  const p = path.resolve(target);
  if (!fs.existsSync(p)) throw new HostError(`no such file or folder: ${target}`);
  if (fs.statSync(p).isFile()) return p;
  const page = PAGES.map((n) => path.join(p, n)).find((f) => fs.existsSync(f));
  if (!page) throw new HostError(`${target} has no page to draw (${PAGES.join(", ")})`);
  return page;
}

// what the HTML says before it runs: its size, whether it is a HyperFrames composition, whether it writes its own contract
export function readPage(page) {
  const html = fs.readFileSync(page, "utf8");
  const rootTag = (html.match(/<[^>]*\bdata-composition-id\b[^>]*>/) || [""])[0];
  const attr = (n) => { const m = rootTag.match(new RegExp(`\\b${n}="([\\d.]+)"`)); return m ? +m[1] : 0; };
  const meta = (html.match(/<meta[^>]*name=["']viewport["'][^>]*content=["']([^"']*)["']/i) || [])[1] || "";
  const mv = (n) => { const m = meta.match(new RegExp(`\\b${n}\\s*=\\s*(\\d+)`)); return m ? +m[1] : 0; };
  return {
    html, hyperframes: !!rootTag,
    width: attr("data-width") || mv("width") || 1920, height: attr("data-height") || mv("height") || 1080,
    ownContract: /window\.(film|__vh)\s*=/.test(html),
  };
}

// HyperFrames' runtime for a composition: the project's own (its version), else the one bin/vh setup installed
export function findRuntime(root) {
  for (let d = root; ; d = path.dirname(d)) {
    const f = path.join(d, RUNTIME);
    if (fs.existsSync(f)) return f;
    if (path.dirname(d) === d) break;
  }
  const f = path.join(HARNESS, "styles", "_swatch", RUNTIME);
  return fs.existsSync(f) ? f : null;
}

const TYPES = { ".html": "text/html; charset=utf-8", ".htm": "text/html; charset=utf-8", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css",
  ".json": "application/json", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp", ".avif": "image/avif",
  ".svg": "image/svg+xml", ".woff2": "font/woff2", ".woff": "font/woff", ".ttf": "font/ttf", ".otf": "font/otf", ".wav": "audio/wav", ".mp3": "audio/mpeg",
  ".m4a": "audio/mp4", ".mp4": "video/mp4", ".webm": "video/webm", ".mov": "video/quicktime", ".wasm": "application/wasm", ".glsl": "text/plain", ".txt": "text/plain",
  ".glb": "model/gltf-binary", ".gltf": "model/gltf+json" };

// the page's folder on 127.0.0.1 (or the folder given as the root: an edit list's, the project); the page itself with
// `inject` before </head>; /__vh/<name> from `extra` (a page of the host's own, tools/film/pages/, is one of them, typed by
// its extension); no path out of the folder. `served` collects the path of every file sent (bin/vh render resumes only
// while they are unchanged), `sent` its size and mtime as it was sent (an edit list's chunk cache keeps a chunk only
// while its page's files are still what the page was sent)
function serve(root, pageUrl, pageFile, inject, extra, served, sent = new Map()) {
  const note = (f) => {   // before the file is read: what is sent is this or newer, never older
    served.add(f);
    if (!sent.has(f)) { try { const st = fs.statSync(f); sent.set(f, [st.size, st.mtimeMs]); } catch { sent.set(f, null); } }
  };
  const server = http.createServer((req, res) => {
    let rel;
    try { rel = decodeURIComponent(new URL(req.url, "http://x").pathname); } catch { res.writeHead(400); return res.end(); }
    if (rel === "/" + pageUrl && (inject || pageUrl.startsWith("__vh/"))) {
      note(pageFile);
      const html = fs.readFileSync(pageFile, "utf8");
      const i = html.search(/<\/head>/i);
      res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
      return res.end(!inject ? html : i >= 0 ? html.slice(0, i) + inject + html.slice(i) : inject + html);
    }
    if (rel.startsWith("/__vh/") && Object.hasOwn(extra, rel.slice(6))) {
      res.writeHead(200, { "content-type": TYPES[path.extname(extra[rel.slice(6)]).toLowerCase()] || "text/javascript", "cache-control": "no-store" });
      note(extra[rel.slice(6)]);
      return fs.createReadStream(extra[rel.slice(6)]).pipe(res);
    }
    const f = path.join(root, rel);
    let ok = false;
    try { ok = f.startsWith(root + path.sep) && fs.statSync(f).isFile(); } catch { /* missing */ }
    if (!ok) { res.writeHead(404); return res.end(); }
    res.writeHead(200, { "content-type": TYPES[path.extname(f).toLowerCase()] || "application/octet-stream", "cache-control": "no-store" });
    note(f);
    fs.createReadStream(f).pipe(res);
  });
  return new Promise((ok) => server.listen(0, "127.0.0.1", () => ok({ url: `http://127.0.0.1:${server.address().port}/`, close: () => new Promise((r) => server.close(r)) })));
}

// A lost GPU empties every canvas on the page, the ones a page keeps its textures in too, and no error says so: the page
// only gets an event. Chrome's GPU process died this way in 1-2% of first frames with two browsers on a GitHub macOS
// runner (2026-11), and the capture came out blank. So the page's contexts are counted (before its own scripts, in one
// count for a page and its frames), and a picture counts only from a page that never lost one: a frame is a function of
// t, so a fresh page draws the same one. Not counted, since the GPU is fine: a WebGL context the page ended itself
// (WEBGL_lose_context, as three's forceContextLoss() when a film drops a 3D world), the oldest one, which the browser ends
// as a new one goes past its limit (lost during that getContext call), and a 2D canvas too large to exist.
// Not seen here: a Web Worker's OffscreenCanvas, WebGPU, a frame from another origin.
const WATCH_CONTEXTS = `(() => {
  let up = null; try { up = window.top.filmHost; } catch { /* a frame from another origin */ }
  const W = (up && up.contextWatch) || { lost: 0, ended: new WeakSet(), webgl: new Set() };
  window.filmHost.contextWatch = W;
  window.filmHost.contextsLost = () => W.lost;
  const wrapped = new WeakSet();
  for (const G of [window.WebGLRenderingContext, window.WebGL2RenderingContext]) {
    if (!G) continue;
    const real = G.prototype.getExtension;
    G.prototype.getExtension = function (name) {
      const ext = real.call(this, name), gl = this;
      if (ext && /^webgl_lose_context$/i.test(name) && !wrapped.has(ext)) {
        wrapped.add(ext);
        const lose = ext.loseContext;
        ext.loseContext = function () { if (!gl.isContextLost()) W.ended.add(gl.canvas); return lose.call(this); };
      }
      return ext;
    };
  }
  const seen = new WeakSet();
  for (const C of [window.HTMLCanvasElement, window.OffscreenCanvas]) {
    if (!C) continue;
    const real = C.prototype.getContext;
    C.prototype.getContext = function (...a) {
      const webgl = /webgl/i.test(a[0]) && !seen.has(this);
      const alive = webgl ? [...W.webgl].filter((r) => { const g = r.deref(); if (!g) W.webgl.delete(r); return g && !g.isContextLost(); }) : [];
      const got = real.apply(this, a);
      if (!got || seen.has(this)) return got;
      seen.add(this);
      this.addEventListener("contextlost", () => { if (this.width <= 65535 && this.height <= 65535 && this.width * this.height <= 268435456) W.lost++; });
      if (webgl) {
        for (const r of alive) { const g = r.deref(); if (g && g.isContextLost()) { W.ended.add(g.canvas); W.webgl.delete(r); } }
        const mine = new WeakRef(got);
        W.webgl.add(mine);
        this.addEventListener("webglcontextlost", () => { W.webgl.delete(mine); if (!W.ended.delete(this)) W.lost++; });
        this.addEventListener("webglcontextrestored", () => { W.webgl.add(mine); });
      }
      return got;
    };
  }
})();`;
const CONTEXT_RELOADS = 3;

// openFilm(target, { browser, dpr, width, height, realClock, softGl, runtime, prelude, root, params, beforeReload }) → a film to draw:
// { page, kind, width, height, duration, frame(t) → { png, touched }, draw(t), setParams(p), problems(), served(), close(),
// ev, send }. runtime: "auto" (HyperFrames' runtime for a composition that writes no contract of its own), "on" or "off".
// prelude: more scripts to run before the page's own, after the clock (tools/film/glyphs.mjs records the text a page draws
// this way). root: the folder to serve (an edit list's, the project: engines/EDIT.md), the page opened by its path from
// there; a page outside it (the host's own pages, tools/film/pages/) is served as /__vh/page/<name>. params: what the
// page reads as window.filmHost.params (setParams(p) changes it between two frames: the host's own pages draw from it).
// beforeReload(film): a page that lost a canvas is loaded again (see WATCH_CONTEXTS): read what it holds first
export async function openFilm(target, o = {}) {
  const page = findPage(target);
  const real = path.join(fs.realpathSync(path.dirname(page)), path.basename(page));   // its folder's real path (a linked page stays the link)
  const root = o.root ? fs.realpathSync(o.root) : path.dirname(real);
  const inRoot = real.startsWith(root + path.sep);
  const pageRel = inRoot ? path.relative(root, real).split(path.sep).join("/") : path.basename(page);
  const pageUrl = inRoot ? pageRel : `__vh/page/${pageRel}`;
  const info = readPage(page);
  let width = o.width || info.width, height = o.height || info.height;
  const firstSize = [width, height];
  const useRuntime = info.hyperframes && (o.runtime === "on" || (o.runtime !== "off" && !info.ownContract));
  const extra = {}, scripts = [];
  if (useRuntime) {
    const rt = findRuntime(root);
    if (!rt) throw new HostError(`${pageRel} is a HyperFrames composition without window.film, and no HyperFrames runtime was found: run npm install in the project (or bin/vh setup)`);
    extra["hf-runtime.js"] = rt; extra["hf-adapter.js"] = path.join(HERE, "hf-adapter.js");
    scripts.push('<script data-hyperframes-preview-runtime="1" src="/__vh/hf-runtime.js"></script>', '<script src="/__vh/hf-adapter.js"></script>');
  }
  const served = new Set(), sent = new Map();
  const server = await serve(root, pageUrl, real, scripts.join("\n"), extra, served, sent);
  const flags = o.softGl ? ["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"]
    : process.platform === "darwin" ? ["--use-angle=metal", "--ignore-gpu-blocklist"] : ["--ignore-gpu-blocklist"];
  if (process.platform === "linux") flags.push("--no-sandbox", "--disable-dev-shm-usage");
  flags.push("--font-render-hinting=none");   // as HyperFrames renders: glyph edges otherwise differ from its frames
  // after 3 GPU process crashes Chrome goes on without WebGL, with no event to say so; it takes both to keep it
  flags.push("--disable-gpu-process-crash-limit", "--disable-domain-blocking-for-3d-apis");
  let browser, s;
  try { ({ browser, sessionId: s } = await launchTab(o.browser, flags, ["Page", "Runtime", "Network"])); } catch (e) { await server.close(); throw new HostError(`could not start ${o.browser}: ${e.message}`); }
  const closeAll = async () => { try { await browser.close(); } catch { /* gone */ } await server.close(); };
  try {
    const problems = [], urls = new Map();
    browser.on("Runtime.exceptionThrown", (p) => problems.push("error: " + ((p.exceptionDetails.exception && p.exceptionDetails.exception.description) || p.exceptionDetails.text)));
    browser.on("Runtime.consoleAPICalled", (p) => { if (p.type === "error") problems.push("console.error: " + p.args.map((a) => a.value ?? a.description ?? "").join(" ")); });
    browser.on("Network.requestWillBeSent", (p) => urls.set(p.requestId, p.request.url));
    browser.on("Network.loadingFailed", (p) => { if (!p.canceled) problems.push(`failed to load ${(urls.get(p.requestId) || "?").replace(server.url, "")}: ${p.errorText}`); });
    browser.on("Network.responseReceived", (p) => { if (p.response.status >= 400 && !/\/favicon\.ico$/.test(p.response.url)) problems.push(`failed to load ${p.response.url.replace(server.url, "")}: HTTP ${p.response.status}`); });
    const metrics = (w, h) => browser.send("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: o.dpr || 1, mobile: false }, s);
    await metrics(width, height);
    await browser.send("Emulation.setTimezoneOverride", { timezoneId: "UTC" }, s);   // local time reads the same on every machine
    const prelude = o.realClock ? 'window.filmHost = { version: "0.1", name: "ovh" };' : fs.readFileSync(path.join(HERE, "clock.js"), "utf8");
    await browser.send("Page.addScriptToEvaluateOnNewDocument", { source: prelude }, s);
    await browser.send("Page.addScriptToEvaluateOnNewDocument", { source: WATCH_CONTEXTS }, s);
    if (o.params !== undefined) await browser.send("Page.addScriptToEvaluateOnNewDocument", { source: `window.filmHost.params = ${JSON.stringify(o.params)};` }, s);
    for (const source of o.prelude || []) await browser.send("Page.addScriptToEvaluateOnNewDocument", { source }, s);
    const ev = async (expression, what) => {
      const r = await browser.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true }, s);
      if (r.exceptionDetails) throw new Error(`${what}: ${(r.exceptionDetails.exception && r.exceptionDetails.exception.description) || r.exceptionDetails.text}`);
      return r.result.value;
    };
    // the contract: window.film, else window.__vh; a page has 10 s after load to set it
    // the waits below time themselves out in the page; a page whose script is stuck (a loop that never ends) never gets to
    // its timer, so the host bounds them too. How long: OVH_PAGE_TIMEOUT seconds when it is set, else the tool's frame
    // timeout (o.frameTimeout: frames, render), never under 30 s for window.film and 120 s for each of ready and the fonts
    const env = Number(process.env.OVH_PAGE_TIMEOUT), ft = Number(o.frameTimeout) || 0;
    const lookS = env > 0 ? env : Math.max(30, ft), waitS = env > 0 ? env : Math.max(120, ft), readyS = 2 * waitS + 10;
    const bounded = (p, sec, msg) => { let tm; p.catch(() => { /* what it says after the bound is not news */ }); return Promise.race([p, new Promise((_, no) => { tm = setTimeout(() => no(new HostError(msg)), sec * 1000); })]).finally(() => clearTimeout(tm)); };
    // load the page and wait until it is ready; → what kind of page it is
    const load = async () => {
      const loaded = browser.once("Page.loadEventFired", s);
      loaded.catch(() => { /* a browser that dies first fails it; the race below reports that */ });
      const sent = browser.send("Page.navigate", { url: server.url + pageUrl.split("/").map(encodeURIComponent).join("/") }, s);
      let timer;
      await Promise.race([Promise.all([sent, loaded]), new Promise((_, no) => { timer = setTimeout(() => no(new HostError("the page did not load within 60 s")), 60000); })]).finally(() => clearTimeout(timer));
      const found = await bounded(ev(`new Promise((ok) => { const t0 = Date.now(); const look = () => {
        if (window.film && typeof window.film.frame === "function") return ok(window.film.__adapter || "film");
        if (window.__vh && typeof window.__vh.draw === "function") return ok("__vh");
        if (Date.now() - t0 > 10000) return ok(""); setTimeout(look, 50); }; look(); })`, "looking for window.film"),
      lookS, `${pageRel}: no answer from the page within ${lookS} s of loading (its script never yields: a loop that does not end?)`);
      if (!found) {
        throw new HostError(`${pageRel} sets no window.film (nor window.__vh) within 10 s of loading: see engines/CONTRACT.md` +
          (problems.length ? `\npage errors while loading:\n  ${[...new Set(problems)].slice(0, 5).join("\n  ")}` : ""));
      }
      const ready = await bounded(ev(`(async () => {
      const wait = (p) => Promise.race([p, new Promise((_, no) => setTimeout(() => no(new Error("not ready after ${waitS} s")), ${waitS * 1000}))]);
      try {
        const src = window.film && window.film.frame ? window.film : window.__vh;
        let r = src.ready;
        if (typeof r === "function") r = r.call(src);   // a method: film.ready(), as OpenFilm's hosts call it
        await wait(Promise.resolve(r)); await wait(document.fonts.ready);
      } catch (e) { return String((e && e.message) || e); }
      return "";
    })()`, "waiting for ready"), readyS, `${pageRel}: not ready after ${readyS} s, and the page does not answer (its script is stuck, or the browser stopped)`);
      if (ready) throw new HostError(`${pageRel}: ${ready} (window.film.ready or the fonts)`);
      return found;
    };
    const kind = await load();
    const got = await ev(`(() => { const f = window.film && window.film.frame ? window.film : null, v = window.__vh || {};
      const root = document.querySelector("[data-composition-id]");
      return { duration: +((f ? f.duration : v.duration) || (root && root.dataset.duration) || 0), width: f && +f.width || 0, height: f && +f.height || 0 }; })()`, "reading window.film");
    if (got.width > 0 && got.height > 0 && (got.width !== width || got.height !== height)) { width = got.width; height = got.height; await metrics(width, height); }
    const loadProblems = problems.splice(0);
    // draw t and let the compositor paint it; → the clocks the frame read (tools/film/clock.js)
    const draw = (t) => ev(`(async (t) => {
          const H = window.filmHost, f = window.film && window.film.frame ? window.film : null;
          if (H && H.time) H.time(t);
          try { if (f) await f.frame(t); else await window.__vh.draw(t); } finally { if (H && H.settle) H.settle(t); }
          await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
          return H && H.touched ? H.touched() : [];
        })(${JSON.stringify(t)})`, `drawing t=${t}`);
    // one of the page's own fields as JSON (a function is called first), null when it gives none or nothing JSON can hold
    const field = (name) => ev(`((name) => { const f = window.film && window.film.frame ? window.film : window.__vh || {};
      let x = f[name]; if (typeof x === "function") x = x.call(f); const s = JSON.stringify(x); return s === undefined ? null : JSON.parse(s); })(${JSON.stringify(name)})`, `reading window.film.${name}`);
    // what the page reads as window.filmHost.params from the next frame on (the host's own pages, tools/film/pages/)
    let params;
    const setParams = (p) => { params = p; return ev(`(() => { window.filmHost.params = ${JSON.stringify(p)}; return true; })()`, "setting the page's params"); };
    let film;
    // take a picture; asked after it, since the GPU can go while the capture waits, and also when it failed, since a page
    // can throw on a context that is gone. Lost: the page again, as it first loaded, then the picture again
    const intact = async (what, take) => {
      for (let n = 0; ; n++) {
        const said = problems.length;
        let got, failed = null;
        try { got = await take(); } catch (e) { failed = e; }
        let lost;
        try { lost = await ev("(() => { const H = window.filmHost; return H && H.contextsLost ? H.contextsLost() : 0; })()", "reading the page's lost contexts"); }
        catch (e) { throw failed || e; }
        if (!lost) { if (failed) throw failed; return got; }
        if (n === CONTEXT_RELOADS) {
          throw new HostError(`${pageRel}: the page's canvases lost their contexts ${n + 1} times in a row at ${what}, so the picture cannot be trusted. ` +
            "The GPU keeps going: close what else is drawing on it, or use --soft-gl");
        }
        console.error(`${pageRel}: the GPU took the page's canvases at ${what}: loading the page again and drawing it again`);
        if (o.beforeReload) await o.beforeReload(film);
        if (firstSize[0] !== width || firstSize[1] !== height) await metrics(...firstSize);
        // what the page said on the way to the loss goes with that picture, and is shown; beforeReload's DevTools reads are noise
        const dropped = problems.splice(said).filter((p) => !p.startsWith("failed to load ?:"));
        if (dropped.length) console.error(`${pageRel}: on the way to that loss the page said (not counted): ${dropped.slice(0, 3).join(" | ")}`);
        await load();
        if (firstSize[0] !== width || firstSize[1] !== height) await metrics(width, height);
        // what it says on every load is said once; "?": a request of the page before, its stylesheet fetched again by CSS.enable
        problems.push(...problems.splice(said).filter((p) => !loadProblems.includes(p) && !p.startsWith("failed to load ?:")));
        if (params !== undefined) await setParams(params);
      }
    };
    film = {
      page, root, kind, width, height, duration: got.duration, version: browser.version, loadProblems,
      // draw t, let the compositor paint it, capture it (a lossless PNG, or { format: "jpeg", quality } for a render);
      // touched: the clocks the frame read (tools/film/clock.js)
      frame: (t, capture = { format: "png" }) => intact(`t=${t}`, async () => {
        const touched = await draw(t);
        const shot = await browser.send("Page.captureScreenshot", { ...capture, fromSurface: true, captureBeyondViewport: false }, s);
        return { png: Buffer.from(shot.data, "base64"), touched };
      }),
      draw,   // draw t without capturing it (a check that reads the page, not its pixels)
      setParams,
      // a cover (window.film.covers): the page's cover(id, opts) when it has one (its own camera and title), else frame(t).
      // o.title false: no title (a page with cover() must say it left it out: it returns { title: false }). o.ratio "9:16":
      // the page draws the cover with a title laid out for that ratio and returns the crop of its frame ({ crop: [x, y, w,
      // h], size: [w, h] }, engines/CONTRACT.md), captured at size x o.dpr px. o.capture: the screenshot's format, or
      // false to draw only. → { png, touched, reply (what cover() returned), width, height }
      cover: (id, t, c = {}) => (c.capture === false ? (f) => f() : (f) => intact(`cover ${id}`, f))(async () => {
        const opts = {};
        if (c.title === false) opts.title = false;
        if (c.ratio) opts.ratio = c.ratio;
        const got = await ev(`(async (id, t, opts) => {
          const H = window.filmHost, f = window.film && window.film.frame ? window.film : null, own = !!(f && typeof f.cover === "function");
          let reply = null;
          if (H && H.time) H.time(t);
          try { if (own) reply = await f.cover(id, opts); else if (f) await f.frame(t); else await window.__vh.draw(t); }
          finally { if (H && H.settle) H.settle(t); }
          await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
          return { touched: H && H.touched ? H.touched() : [], own, reply: reply && typeof reply === "object" ? JSON.parse(JSON.stringify(reply)) : null };
        })(${JSON.stringify(id)}, ${JSON.stringify(t)}, ${JSON.stringify(opts)})`, `drawing cover ${id}`);
        const { touched, own, reply } = got;
        if (c.title === false && own && !(reply && reply.title === false))
          throw new Error("the page drew its cover without saying it left the title out (its cover(id) takes no options: an engine copied before covers took them, engines/canvas-film/README.md)");
        let clip, want;
        if (c.ratio) {
          if (!own || !reply || !Array.isArray(reply.crop) || reply.crop.length !== 4 || !Array.isArray(reply.size))
            throw new Error(`the page drew no ${c.ratio} crop: ${own ? "its cover(id) returned none" : "it has no cover(id)"} (engines/CONTRACT.md: cover(id, { ratio }) returns { crop, size })`);
          // Chrome captures a clip of whole CSS px, scaled by clip.scale x the device pixel ratio: the crop (whole px, the
          // shape of the ratio) scaled to size x c.dpr
          const [x, y, cw, ch] = reply.crop.map(Math.round), w = Math.round(reply.size[0] * (c.dpr || 1)), h = Math.round(reply.size[1] * (c.dpr || 1));
          clip = { x, y, width: cw, height: ch, scale: (w + 1e-6) / (cw * (o.dpr || 1)) };
          want = [w, h];
        }
        if (c.capture === false) return { png: null, touched, reply, width: 0, height: 0 };
        // the output's size rounds w + 1e-6 (to w); a Chrome that rounds it up gets w - 1e-6 instead, and one that gives
        // another size fails
        let png, pw = 0, ph = 0, isPng = false;
        for (let n = 0; ; n++) {
          const shot = await browser.send("Page.captureScreenshot", { ...(c.capture || { format: "png" }), fromSurface: true, captureBeyondViewport: false, ...(clip ? { clip } : {}) }, s);
          png = Buffer.from(shot.data, "base64"); isPng = png.length > 24 && png.toString("latin1", 1, 4) === "PNG";
          pw = isPng ? png.readUInt32BE(16) : 0; ph = isPng ? png.readUInt32BE(20) : 0;
          if (!want || !isPng || (pw === want[0] && ph === want[1])) break;
          if (n === 1) throw new Error(`the ${c.ratio} capture came out ${pw}x${ph}, not ${want[0]}x${want[1]}`);
          clip = { ...clip, scale: (want[0] - 1e-6) / (clip.width * (o.dpr || 1)) };
        }
        return { png, touched, reply, width: pw, height: ph };
      }),
      problems: () => problems.splice(0),
      served: () => [...served],                             // the files sent to the page so far (absolute paths)
      sentAs: (f) => sent.get(f),                            // a file's [size, mtime] when it was first sent, or undefined
      // the page's own fields (texts, events, chapters, cues, timeline: engines/CONTRACT.md); list(name) only takes an array
      field,
      list: async (name) => { const x = await field(name); return Array.isArray(x) ? x : null; },
      // what arrives after the last frame (an error from a timer a frame set): two paints and 100 ms, then collect
      async lateProblems() {
        try { await ev("new Promise((ok) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(ok, 100))))", "after the last frame"); } catch { /* gone */ }
        return problems.splice(0);
      },
      close: closeAll,
      ev,                                                    // an expression in the page, awaited, its value as JSON
      send: (method, params = {}) => browser.send(method, params, s),   // a DevTools command to this page
    };
    return film;
  } catch (e) { await closeAll(); throw e instanceof HostError ? e : new HostError(e.message); }
}
