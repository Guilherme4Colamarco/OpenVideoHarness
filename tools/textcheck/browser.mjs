// A headless Chrome driven over the DevTools protocol through a pipe (--remote-debugging-pipe), and a static file server
// for the composition. No npm dependencies: Node's child_process and http are enough for what textcheck needs, so it runs
// in any project and in CI without puppeteer.
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";

export class BrowserGone extends Error {}

// Chrome's profile folder goes when the browser is closed, and also when node ends some other way: process.exit (a
// tool's own Ctrl-C handler, as bin/vh render has), or Ctrl-C, SIGTERM or SIGHUP with no handler of the tool's own
// (bin/vh frames, textcheck, determinism, cues, and readcheck's texts step), where Node would otherwise die without
// cleaning up. A tool that
// handles the signal itself keeps it: this one only steps in when it is the only listener, and then re-sends the
// signal so the process still ends the way it would have.
const LIVE = new Set();   // { proc, profile } of every browser not closed yet
const removeSync = (dir) => { try { fs.rmSync(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }); } catch { /* left in the temp folder */ } };
// Chrome runs in a process group of its own, so its helpers (GPU, renderers) go with it: left alive, they write to the
// profile again after it was removed. A short pause lets them go before the folder does
// Signal 0 only asks: is any process of Chrome's group still there? While one is, the group id is still Chrome's
const groupGone = (pid) => { try { process.kill(-pid, 0); return false; } catch (e) { return e.code === "ESRCH"; } };
const killGroup = (proc) => {
  // the main process gone and its group empty: nothing to kill, and the id may belong to another group later. On Linux
  // the helpers can outlive the main process by a moment, so an exited main process with a live group still gets it
  if ((proc.exitCode !== null || proc.signalCode !== null) && groupGone(proc.pid)) return;
  try { process.kill(-proc.pid, "SIGKILL"); } catch { try { proc.kill("SIGKILL"); } catch { /* gone */ } }
};
const cleanUp = () => {
  if (!LIVE.size) return;
  for (const b of LIVE) killGroup(b.proc);
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 200);
  for (const b of LIVE) removeSync(b.profile);
  LIVE.clear();
};
// A JS signal listener defers the signal to the event loop (Node's own handling ends the process at once), so these
// listeners live only while a browser does: after the last close, a Ctrl-C during synchronous work (determinism's
// comparisons) still ends the process at once. process.on, not once: a signal the tool handles itself uses nothing up
const SIGNALS = ["SIGINT", "SIGTERM", "SIGHUP"];
const onSignal = (sig) => {
  if (process.listenerCount(sig) > 1) return;            // the tool has its own handler: it ends the process, "exit" cleans up
  disarm(); cleanUp(); process.kill(process.pid, sig);   // no listener left, so the signal does what it does by default
};
const handlers = new Map(SIGNALS.map((sig) => [sig, () => onSignal(sig)]));
let armed = false, exitHooked = false;
function arm() {
  if (!exitHooked) { exitHooked = true; process.on("exit", cleanUp); }
  if (armed) return;
  armed = true;
  for (const [sig, h] of handlers) process.on(sig, h);
}
function disarm() {
  if (!armed) return;
  armed = false;
  for (const [sig, h] of handlers) process.removeListener(sig, h);
}

// launch(exe, flags) → { send(method, params, sessionId), once(event, sessionId), close(), version }
export async function launch(exe, flags = []) {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), "vh-textcheck-"));
  const args = ["--headless", "--remote-debugging-pipe", "--no-first-run", "--no-default-browser-check", `--user-data-dir=${profile}`,
    "--hide-scrollbars", "--mute-audio", "--force-color-profile=srgb", ...flags, "about:blank"];
  const proc = spawn(exe, args, { stdio: ["ignore", "ignore", "pipe", "pipe", "pipe"], detached: true });   // its own group: see killGroup
  const live = { proc, profile };
  LIVE.add(live); arm();
  let stderr = "";
  proc.stderr.on("data", (d) => { stderr = (stderr + d).slice(-4000); });
  const out = proc.stdio[3], inp = proc.stdio[4];
  const pending = new Map(), waiters = [], listeners = [];
  let chunks = [], id = 0, dead = null, started = false;
  // a browser that exits or crashes fails every call still waiting, so nothing hangs until the watchdog
  const gone = (why) => {
    if (dead) return;
    // its last log lines say why it would not start; once running, they are mostly noise
    dead = new BrowserGone(`the browser is gone (${why})${!started && stderr.trim() ? ": " + stderr.trim().split("\n").slice(-3).join(" | ") : ""}`);
    for (const p of pending.values()) p.reject(dead);
    pending.clear();
    for (const w of waiters.splice(0)) w.reject(dead);
  };
  const exited = new Promise((res) => {
    proc.on("exit", (code, sig) => { gone(sig || `exit ${code}`); res(); });
    proc.on("error", (e) => { stderr += String(e); gone(e.code || "error"); res(); });
  });
  out.on("error", (e) => gone(e.code || "pipe error"));
  inp.on("error", (e) => gone(e.code || "pipe error"));
  // a message ends at a NUL and can span 150+ chunks of 64 KB (a 4K PNG screenshot is 10 MB of base64): the chunks of
  // the one still arriving wait in a list and only each new chunk is searched, so a message is copied once, not per chunk
  inp.on("data", (d) => {
    let from = 0;
    for (let i; (i = d.indexOf(0, from)) >= 0; from = i + 1) {
      chunks.push(d.subarray(from, i));
      const m = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      chunks = [];
      if (m.id !== undefined && pending.has(m.id)) {
        const p = pending.get(m.id); pending.delete(m.id);
        if (m.error) p.reject(new Error(`${p.method}: ${m.error.message}${m.error.data ? " (" + m.error.data + ")" : ""}`)); else p.resolve(m.result);
      } else if (m.method) {
        for (const w of waiters.slice()) if (w.method === m.method && (!w.session || w.session === m.sessionId)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(m.params); }
        for (const l of listeners) if (l.method === m.method) l.fn(m.params);
      }
    }
    if (from < d.length) chunks.push(d.subarray(from));
  });
  const send = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
    if (dead) return reject(dead);
    const i = ++id; pending.set(i, { resolve, reject, method });
    out.write(JSON.stringify({ id: i, method, params, ...(sessionId ? { sessionId } : {}) }) + "\0");
  });
  const once = (method, session) => new Promise((resolve, reject) => (dead ? reject(dead) : waiters.push({ method, session, resolve, reject })));
  const on = (method, fn) => listeners.push({ method, fn });
  // a race against a timer that is always cleared, so a pending timer never keeps node alive
  const within = (p, ms, onTimeout) => {
    let timer;
    return Promise.race([p, new Promise((res, rej) => { timer = setTimeout(() => (onTimeout ? rej(onTimeout()) : res()), ms); })]).finally(() => clearTimeout(timer));
  };
  // the profile folder: Chrome's helper processes can still be writing to it just after the main one exits (Linux),
  // so retry, and never let a leftover temp folder turn into an error
  // the profile goes while the signal listeners are still in place: with them gone, a Ctrl-C during the removal would
  // end node half way through it and leave part of the folder behind. The last browser gone, the listeners go too,
  // before close() returns: first a turn of the event loop (a Ctrl-C that came during the removal reaches onSignal
  // then, which ends the process), then disarm, so synchronous work after the close can still be stopped at once. A
  // Ctrl-C in the instant between that turn and the disarm is dropped (nothing is left behind, a second one ends it)
  const removeProfile = () => { LIVE.delete(live); removeSync(profile); };
  const close = async () => {
    if (!dead) try { await within(send("Browser.close"), 3000); } catch { /* already gone */ }
    // a Chrome stuck on its way out (a GPU process that stopped answering) can ignore SIGTERM: 3 s, then the group gets
    // SIGKILL below, so a tool never waits on it until its own watchdog
    proc.kill(); await within(exited, 3000);
    // Linux: the GPU and renderer helpers can still write into the profile just after the main process exits, and a
    // folder removed under them comes back. Wait for the whole group (up to 2 s), then kill what is left; the profile
    // stays registered meanwhile, so a Ctrl-C now still removes it
    for (let i = 0; i < 40 && !groupGone(proc.pid); i++) await new Promise((res) => setTimeout(res, 50));
    killGroup(proc); await within(exited, 2000);
    removeProfile();
    if (!LIVE.size) await new Promise((res) => setImmediate(() => setImmediate(res)));   // the second turn's poll reads a signal
    if (!LIVE.size) disarm();
  };
  let version;
  try {
    // 60 s: a cold start on a busy CI runner has taken over 30 (a rerun of the same code passed)
    version = await within(send("Browser.getVersion"), 60000, () => new Error("the browser did not answer within 60 s"));
    started = true;
  } catch (e) { killGroup(proc); await within(exited, 3000); removeProfile(); if (!LIVE.size) disarm(); throw e; }   // a Chrome that never answered may ignore SIGTERM
  return { send, once, on, close, version: version.product };
}

// launchTab(exe, flags, domains) → { browser, sessionId }: a browser with a new tab, those domains enabled on it.
// Full Chrome on macOS can stop answering for good as its tab comes up: its main thread blocks in RunningBoard
// (rbs_acquire_appnap_assertion). On an M-series Mac in 2026-11: 6 of 278 launches when two start together, 1 of 518 one
// at a time, none of 3550 for chrome-headless-shell. Then not even a browser-wide command answers, and only a new browser
// helps. Without a limit here a tool with no watchdog of its own (render's workers) would wait for ever.
const TAB_TRIES = 3;
class NoAnswer extends Error {}
export async function launchTab(exe, flags, domains) {
  const TAB_ANSWER_S = Math.max(30, Number(process.env.OVH_PAGE_TIMEOUT) || 0);   // a slow machine's way to give it longer, never less
  for (let n = 1; ; n++) {
    const browser = await launch(exe, flags);
    const answer = (method, params, session) => {
      let timer;
      return Promise.race([browser.send(method, params, session), new Promise((_, no) => { timer = setTimeout(() => no(new NoAnswer(`${method} had no answer within ${TAB_ANSWER_S} s`)), TAB_ANSWER_S * 1000); })]).finally(() => clearTimeout(timer));
    };
    try {
      const { targetId } = await answer("Target.createTarget", { url: "about:blank" });
      const { sessionId } = await answer("Target.attachToTarget", { targetId, flatten: true });
      for (const d of domains) await answer(`${d}.enable`, {}, sessionId);
      return { browser, sessionId };
    } catch (e) {
      await browser.close();
      if (!(e instanceof NoAnswer)) throw e;
      if (n === TAB_TRIES) throw new Error(`the browser stopped answering ${n} times in a row as its tab came up (${e.message})`);
      console.error(`the browser stopped answering as its tab came up (${e.message}): starting another`);
    }
  }
}

const TYPES = { ".html": "text/html; charset=utf-8", ".htm": "text/html; charset=utf-8", ".js": "text/javascript", ".mjs": "text/javascript", ".css": "text/css",
  ".json": "application/json", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp", ".avif": "image/avif",
  ".svg": "image/svg+xml", ".woff2": "font/woff2", ".woff": "font/woff", ".ttf": "font/ttf", ".otf": "font/otf", ".wav": "audio/wav", ".mp3": "audio/mpeg",
  ".m4a": "audio/mp4", ".mp4": "video/mp4", ".webm": "video/webm", ".mov": "video/quicktime", ".wasm": "application/wasm", ".glsl": "text/plain", ".txt": "text/plain" };

// serve(dir) → { url, close() }: the folder on 127.0.0.1 (so module scripts, fetch and fonts work as they do in
// HyperFrames' own preview, which file:// would block); no path out of it
export async function serve(dir) {
  const root = fs.realpathSync(dir);
  const server = http.createServer((req, res) => {
    let f;
    try { f = path.join(root, decodeURIComponent(new URL(req.url, "http://x").pathname)); } catch { res.writeHead(400); return res.end(); }
    // inside the folder by its path (a symlinked node_modules or assets folder is followed, as HyperFrames' preview does)
    let ok = false;
    try { ok = f.startsWith(root + path.sep) && fs.statSync(f).isFile(); } catch { /* missing */ }
    if (!ok) { res.writeHead(404); return res.end(); }
    res.writeHead(200, { "content-type": TYPES[path.extname(f).toLowerCase()] || "application/octet-stream", "cache-control": "no-store" });
    fs.createReadStream(f).pipe(res);
  });
  await new Promise((res) => server.listen(0, "127.0.0.1", res));
  return { url: `http://127.0.0.1:${server.address().port}/`, close: () => new Promise((res) => server.close(res)) };
}
