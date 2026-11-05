// What the page host does when a canvas loses its context (tools/film/host.mjs, WATCH_CONTEXTS). A real loss comes from
// crashing the browser's GPU process on demand; it takes a page's cached canvas too, so only a fresh page draws it again.
// A page ending its own contexts, or the browser ending the oldest past 16, is not a loss.
// usage: node tools/test_film_gpu_loss.mjs; exit 0 when every case holds, 3 when there is no Chrome to try it in
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";
import { openFilm, HostError } from "./film/host.mjs";

const shells = (() => { try { const d = path.join(os.homedir(), ".cache/puppeteer/chrome-headless-shell"); return fs.readdirSync(d).sort().reverse().flatMap((v) => fs.readdirSync(path.join(d, v)).map((x) => path.join(d, v, x, "chrome-headless-shell"))); } catch { return []; } })();
const browser = [process.env.CHROME_PATH, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/usr/bin/google-chrome", "/usr/bin/google-chrome-stable", "/usr/bin/chromium", "/usr/bin/chromium-browser", ...shells].find((p) => p && fs.existsSync(p));
if (!browser) process.exit(3);
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vh-gpu-loss-"));
let failed = 0;
const check = (name, ok, more = "") => { if (!ok) failed++; console.log(`${ok ? "ok  " : "FAIL"} ${name}${!ok && more ? ": " + more : ""}`); };

// the green channel of a pixel in Chrome's PNG (8 bits, RGB or RGBA, not interlaced)
function green(png, x, y) {
  let at = 8, w = 0, bpp = 3; const idat = [];
  while (at < png.length) {
    const len = png.readUInt32BE(at), name = png.toString("latin1", at + 4, at + 8), body = png.subarray(at + 8, at + 8 + len);
    if (name === "IHDR") { w = body.readUInt32BE(0); bpp = body[9] === 6 ? 4 : 3; }
    if (name === "IDAT") idat.push(body);
    at += 12 + len;
  }
  const stride = w * bpp, raw = zlib.inflateSync(Buffer.concat(idat)); let row = Buffer.alloc(stride), prev = Buffer.alloc(stride);
  for (let r = 0; r <= y; r++) {
    const f = raw[r * (stride + 1)];
    [row, prev] = [prev, row];
    for (let i = 0; i < stride; i++) {
      const v = raw[r * (stride + 1) + 1 + i], a = i >= bpp ? row[i - bpp] : 0, b = prev[i], c = i >= bpp ? prev[i - bpp] : 0;
      const q = a + b - c, pa = Math.abs(q - a), pb = Math.abs(q - b), pc = Math.abs(q - c);
      row[i] = (v + [0, a, b, (a + b) >> 1, pa <= pb && pa <= pc ? a : pb <= pc ? b : c][f]) & 255;
    }
  }
  return row[x * bpp + 1];
}

// a page that paints a canvas once while it loads and draws every frame from it; its WebGL canvas goes with the GPU
// process on any machine, a 2D canvas only where it is on the GPU. each(gl): what the page also does in each frame
const page = (name, each = "") => {
  const f = path.join(dir, name);
  fs.writeFileSync(f, `<!doctype html><style>html,body{margin:0}</style><canvas id="c" width="320" height="180"></canvas><script>
const kept = document.createElement("canvas"); kept.width = kept.height = 64;
{ const g = kept.getContext("2d"); g.fillStyle = "#008000"; g.fillRect(0, 0, 64, 64); }
const gl = document.createElement("canvas").getContext("webgl");
window.loads = +(sessionStorage.loads || 0) + 1; sessionStorage.loads = window.loads;
window.film = { width: 320, height: 180, duration: 2, frame(t) {
  const x = document.getElementById("c").getContext("2d"); x.clearRect(0, 0, 320, 180); x.drawImage(kept, 0, 0, 320, 180);
  ${each}
}, cover() { this.frame(0); return {}; } };
</script>`);
  return f;
};
const open = (f, o = {}) => openFilm(f, { browser, softGl: true, ...o });
const loads = (film) => film.ev("window.loads");
const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));
// the GPU process goes, and the page hears of it, on its own time (asked from here: the page's clocks stand still between frames)
const crash = async (film) => {
  await film.send("Browser.crashGpuProcess");
  for (let i = 0; i < 160; i++) { if (await film.ev("window.filmHost.contextsLost()")) return; await sleep(50); }
  throw new Error("the page never heard of the crash");
};
const watchdog = setTimeout(() => { console.log("FAIL the cases did not finish within 300 s"); process.exit(1); }, 300000);
watchdog.unref();

try {
  for (const softGl of [true, false]) {
    const seen = [];
    const film = await open(page("loss.html"), { softGl, beforeReload: async (f) => { seen.push(await f.ev("window.loads")); } });
    if (!softGl && !(await film.ev("!!gl"))) { console.log("ok   (this machine has no GL of its own: only software GL tried)"); await film.close(); continue; }
    await film.setParams({ take: 2 });
    await film.frame(0);
    await crash(film);
    const { png } = await film.frame(1 / 30);
    const gl = softGl ? "software GL" : "this machine's GL";
    check(`a lost GPU (${gl}): the page is loaded again`, (await loads(film)) === 2, `${await loads(film)} loads`);
    check("  and the frame comes from its cached canvas", green(png, 160, 90) === 128, `green ${green(png, 160, 90)}`);
    check("  beforeReload heard once, from the old page", seen.length === 1 && seen[0] === 1, JSON.stringify(seen));
    check("  setParams carried over", (await film.ev("window.filmHost.params.take")) === 2);
    const next = await film.frame(2 / 30);
    check("  the next frame draws on with no other load", (await loads(film)) === 2 && green(next.png, 160, 90) === 128);
    await crash(film);
    const cover = await film.cover("a", 0);
    check("  a cover is taken the same way", (await loads(film)) === 3 && green(cover.png, 160, 90) === 128);
    // Chrome's limit is 3 crashes, then no WebGL, with no event to say so
    if (softGl) {
      for (let i = 0; i < 3; i++) { await crash(film); await film.frame(0); }
      check("  WebGL is still there after 5 crashes in one browser", (await loads(film)) === 6 && await film.ev('!!document.createElement("canvas").getContext("webgl2")'), `${await loads(film)} loads`);
    }
    await film.close();
  }
  {
    // as three's forceContextLoss(), when a film drops a 3D world: its other canvases and its picture are untouched
    const film = await open(page("own.html", 'if (t > 0 && !gl.isContextLost()) gl.getExtension("WEBGL_lose_context").loseContext(); document.createElement("canvas").getContext("webgl").getExtension("WEBGL_lose_context").loseContext();'));
    await film.frame(0);
    const { png } = await film.frame(1 / 30);
    await sleep(200);
    await film.frame(2 / 30);
    check("a page ending its own contexts: no reload", (await loads(film)) === 1 && green(png, 160, 90) === 128, `${await loads(film)} loads`);
    await film.close();
  }
  {
    const film = await open(page("many.html", 'if (t === 0) { window.keep = []; for (let i = 0; i < 20; i++) window.keep.push(document.createElement("canvas").getContext("webgl")); }'));
    await film.frame(0);
    await sleep(200);
    const { png } = await film.frame(1 / 30);
    check("the browser ending the oldest of too many WebGL contexts: no reload", (await loads(film)) === 1 && green(png, 160, 90) === 128, `${await loads(film)} loads`);
    // and a real loss is still seen after them
    await crash(film);
    const after = await film.frame(2 / 30);
    check("  a lost GPU after them is still a loss", (await loads(film)) === 2 && green(after.png, 160, 90) === 128, `${await loads(film)} loads`);
    await film.close();
  }
  {
    // a page that hears of the loss first (its listener went on before getContext, as three's does) and makes a new context then
    const f = page("first.html");
    fs.writeFileSync(f, fs.readFileSync(f, "utf8").replace("const gl = document.createElement(\"canvas\").getContext(\"webgl\");", 'const c3 = document.createElement("canvas"); c3.addEventListener("webglcontextlost", () => { window.made = document.createElement("canvas").getContext("webgl"); }); const gl = c3.getContext("webgl");'));
    const film = await open(f);
    await film.frame(0);
    await crash(film);
    await film.frame(1 / 30);
    check("a new context made as the loss is heard does not hide the loss", (await loads(film)) === 2, `${await loads(film)} loads`);
    await film.close();
  }
  {
    const film = await open(page("dropped.html", 'if (t === 0) for (let i = 0; i < 40; i++) document.createElement("canvas").getContext("webgl");'));
    await film.frame(0);
    await film.send("HeapProfiler.collectGarbage");
    await crash(film);
    await film.frame(1 / 30);
    check("a lost GPU after 40 contexts the page dropped is a loss", (await loads(film)) === 2, `${await loads(film)} loads`);
    await film.close();
  }
  {
    const f = page("frames.html", 'if (t === 0) { window.fr = document.createElement("iframe"); document.body.append(window.fr); window.keep = []; for (let i = 0; i < 10; i++) { window.keep.push(document.createElement("canvas").getContext("webgl")); window.keep.push(window.fr.contentDocument.createElement("canvas").getContext("webgl")); } }');
    const film = await open(f);
    await film.frame(0);
    await sleep(200);
    const { png } = await film.frame(1 / 30);
    check("too many WebGL contexts across a page and its frame: no reload", (await loads(film)) === 1 && green(png, 160, 90) === 128, `${await loads(film)} loads`);
    await film.close();
  }
  {
    const film = await open(page("huge.html", 'if (t === 0) { const c = document.createElement("canvas"); c.width = 70000; c.height = 100; c.getContext("2d").fillRect(0, 0, 1, 1); }'));
    await film.frame(0);
    await sleep(200);
    await film.frame(1 / 30);
    check("a 2D canvas too large to exist: no reload", (await loads(film)) === 1, `${await loads(film)} loads`);
    await film.close();
  }
  {
    const film = await open(page("throws.html", 'if (gl.isContextLost()) throw new Error("no context"); if (t > 0) console.error("said in the frame");'));
    await film.frame(0);
    await crash(film);
    const { png } = await film.frame(1 / 30);
    check("a frame that throws on a lost context: reloaded, not failed", (await loads(film)) === 2 && green(png, 160, 90) === 128, `${await loads(film)} loads`);
    const said = film.problems();
    check("  and what the frame says on the good try is still reported", said.length === 1 && /said in the frame/.test(said[0]), JSON.stringify(said));
    await film.close();
  }
  {
    fs.writeFileSync(path.join(dir, "s.css"), "body { color: #111 }");
    const f = page("quiet.html");
    fs.writeFileSync(f, fs.readFileSync(f, "utf8").replace("<canvas", '<link rel="stylesheet" href="s.css"><canvas'));
    const film = await open(f, { beforeReload: async (x) => { await x.send("DOM.enable"); await x.send("CSS.enable"); await sleep(100); } });
    await film.frame(0);
    await crash(film);
    await film.frame(1 / 30);
    await sleep(100);
    const said = film.problems();
    check("the DevTools reads before a reload (CSS.enable fetches a stylesheet again) are not the film's", (await loads(film)) === 2 && !said.length, JSON.stringify(said));
    await film.close();
  }
  {
    const f = page("size.html");
    fs.writeFileSync(f, fs.readFileSync(f, "utf8").replace("window.loads =", "window.loadWidth = innerWidth; window.loads ="));
    const film = await open(f);
    const first = await film.ev("window.loadWidth");
    await film.frame(0);
    await crash(film);
    await film.frame(1 / 30);
    check("a reloaded page loads at the size it first loaded at, and draws at its own", (await film.ev("window.loadWidth")) === first && (await film.ev("innerWidth")) === 320, `${first}, ${await film.ev("window.loadWidth")}, ${await film.ev("innerWidth")}`);
    await film.close();
  }
  {
    const film = await open(page("nocapture.html"));
    await film.frame(0);
    await crash(film);
    await film.cover("a", 0, { capture: false });
    check("a cover with no capture takes no picture, so no reload (fonts check keeps its notes)", (await loads(film)) === 1, `${await loads(film)} loads`);
    await film.close();
  }
  {
    // the event a lost 2D context gets, on every load: nothing a reload can cure
    const film = await open(page("always.html", 'document.getElementById("c").dispatchEvent(new Event("contextlost"));'));
    let e = null;
    try { await film.frame(0); } catch (x) { e = x; }
    check("lost on every load: stops with a HostError after 3 reloads", e instanceof HostError && /4 times/.test(e.message) && (await loads(film)) === 4, e ? e.message : "no error");
    await film.close();
  }
} catch (e) {
  check("the cases ran", false, e.stack || String(e));
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}
process.exit(failed ? 1 : 0);
