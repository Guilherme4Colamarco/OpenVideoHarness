"""bin/vh image: generated pictures, made once into files and kept on record (a keyframe for gate ②, a plate behind the
code, a cover's ground, a reference for 3D), and cutouts with a transparent background. Stdlib only, and ffmpeg.

usage: bin/vh image gen <project> (--prompt TEXT | --prompt-file F) [--provider gemini|codex] [--tier draft|final]
                  [--model M] [--size 1K|2K|4K] [--aspect 16:9] [--ref a.png …] [--alpha] [--n 1] [--seed S] [--id ID]
                  [--used-by S03,cover] [--dry-run] [--offline DIR] [--json]
       bin/vh image cutout <project> <image> [--key auto|green|blue|#rrggbb] [--similarity 0.16] [--blend 0.08] [--id ID]
                  [--json]
       bin/vh image prices [--json]
<project> as bin/vh assets takes it.

  gen      one picture a call (--n: that many calls), into assets/genimg/<id>/: image.jpg from Gemini (it sends JPEG
           only), image.png from Codex (image-1.jpg … with --n),
           prompt.txt and request.json (what was asked, never a key), and a contact sheet (sheet.png) when there are
           several. Each picture is one record in assets/ledger.json: aigc, the model, the prompt file, the seed, what it
           cost and the reference images it was given (inputs).
           gemini (the default): Google's Interactions API with GEMINI_API_KEY (the key in a header only). --tier draft
           (the default) is Nano Banana 2.1, for exploring and gate ② keyframes, asked to think at its minimal level (it
           thinks at medium unless told, and thinking is billed); --tier final is Nano Banana Pro, for a
           picture that goes on screen; --model names another (prices lists them). --size: 1K, 2K or 4K (default 1K
           draft, 2K final); --aspect: 1:1, 3:2, 2:3, 3:4, 4:3, 4:5, 5:4, 9:16, 16:9, 21:9 (default from the BRIEF's
           Output, else 16:9); --ref: reference pictures (up to 14; they are uploaded to the vendor: ask first when one
           shows a real person or something confidential), cast:<id> for the pictures of the project's settled cast
           entry in its order, cast:<id>:<view> for one of them (bin/vh cast; said which numbers are whose, for the
           prompt to name them); --seed: sent as given, else a random one, recorded either way.
           Every call is paid: it is held against the project's budget first (tools/assets/budget.py: no budget, or one it
           would go over, and the call is not made, with how much is missing), and settled at what the answer's usage
           says it cost, a blocked answer's input and thinking too. An error answer (HTTP 4xx/5xx) and a request that
           never left settle at 0; a timeout, a reset or an answer that cannot be read keep the estimate as spent, as
           such a call may have been billed (said so).
           codex: the Codex CLI's image_gen, on the ChatGPT plan the CLI is signed in with: not billed per picture, so
           no budget is held (as bin/vh tts on a plan's quota); no seed, no size. --ref: attached in the order given
           (codex exec -i), the model told to edit them; they go to OpenAI, the same asking first. A transparent
           background comes from the model itself. The model is the one the user's Codex config names (none is set
           here; only the reasoning effort is, low: making a picture is one tool call); when codex makes nothing, its own
           error is said, with what to change (a model a ChatGPT login cannot use: a newer CLI, or another
           model in config.toml).
           --alpha: a transparent background. Gemini has none of its own: the picture is asked for on flat chroma green
           and cut out (cutout below) into cutout.png beside it; codex is asked for a transparent PNG.
           --dry-run: the estimate and the budget's verdict, nothing called. Pictures that go on screen are AI-generated
           content (bin/vh assets credits says so for the upload); no real people, and nothing passed off as a news photo
           or a record of what happened
  cutout   a transparent background for a picture on a flat colour: the key colour measured on its border (auto) or
           given, ffmpeg chromakey and despill (playbook/05's 绿幕), into <name>.cutout.png beside it, on record and
           derived from it. It says the spill left on the edge band (G − max(R, B) where the alpha is between 0.05 and
           0.95; over about 4 levels a green fringe shows) and writes <name>.cutout-check.png: the cutout on black, white
           and paper, to look at the edges
  prices   the models gen knows, a picture's price at each size, and what a reference picture and the thinking add
--json: {"version": 1, "tool", …}; the lines go to stderr. --offline DIR: the answers from DIR/responses.json, recorded
before (CONTRIBUTING.md, 联网的命令); no network, and nothing held or spent (the budget's verdict still applies, as it
would to a call): the record has no cost and says it was replayed. A stand-in codex on the PATH answers for the Codex CLI.
Exit: 0 · 1 a call refused by the budget, or failed · 2 usage: no prompt, no key (said by its name), no such file.
The Codex route follows lemo-opuscar's styles/news-package/demo/tools/gen_image.py (MIT, Copyright (c) 2026 LemoLab): codex
exec in a read-only sandbox told to call image_gen once, the picture found under generated_images or in the session log by
a job token. The code is written anew; the Interactions request and answer follow Google's API reference (2026-10-26).
"""
import argparse, base64, glob, json, os, re, secrets, shutil, signal, subprocess, sys, tempfile, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
import assets as A, budget, fetch, ledger   # noqa: E402,E401

PROG = "bin/vh image"
SUB = ("gen", "cutout", "prices")
GENIMG = Path("assets") / "genimg"
API = "https://generativelanguage.googleapis.com/v1beta/interactions"
ASPECTS = ("1:1", "3:2", "2:3", "3:4", "4:3", "4:5", "5:4", "9:16", "16:9", "21:9")
TIERS = {"draft": "gemini-nano-banana-2.1", "final": "gemini-3-pro-image"}
# USD, from ai.google.dev/gemini-api/docs/pricing, checked 2026-10-26: a picture by size (the image output tokens priced
# as the page gives them), input and text output a million tokens (thinking is billed as text output)
PRICES = {
    "gemini-3-pro-image": {"name": "Nano Banana Pro", "image": {"1K": 0.134, "2K": 0.134, "4K": 0.24}, "input": 2.00, "text": 12.00, "image_out": 120.00, "refs": 6},
    "gemini-nano-banana-2.1": {"name": "Nano Banana 2.1", "image": {"1K": 0.0336, "2K": 0.0504, "4K": 0.113}, "input": 1.50, "text": 7.50, "image_out": 30.00, "refs": 14},
    "gemini-3.1-flash-image": {"name": "Nano Banana 2", "image": {"1K": 0.067, "2K": 0.101, "4K": 0.151}, "input": 0.50, "text": 3.00, "image_out": 60.00, "refs": 14},
    "gemini-3.1-flash-lite-image": {"name": "Nano Banana 2 Lite", "image": {"1K": 0.0336}, "input": 0.25, "text": 1.50, "image_out": 30.00, "refs": 14},
}
PRICES_CHECKED = "2026-10-26"
REF_TOKENS = 560        # an input picture, in tokens (the page's $0.0011 a picture at $2 a million)
THINK_TOKENS = 2000     # what the estimate allows for thinking, billed as text output; the answer's usage settles it
THINKING = {"gemini-nano-banana-2.1": "minimal"}   # thinking_level sent: 2.1's lowest (its default is medium); the Flash
                                                   # images default to minimal, Pro lists no levels (the image docs, 2026-10-26)
GREEN = "on a perfectly flat, evenly lit pure chroma-key green background (#00FF00), nothing else in the background, no shadow cast on it, no green in the subject"
CODEX_PREAMBLE = ("Use your built-in image generation tool (image_gen) to {what}, then reply DONE. If the tool fails, "
                  "print its error verbatim and stop. Do not run shell commands, do not look for or save files, do not retry.\n\n")
out = sys.stdout   # the lines; stderr under --json


class Usage(A.Usage):
    pass


class Failed(Exception):
    """A call refused or failed: exit 1."""


def say(*a):
    print(*a, file=out)


# ---- money ----

def estimate(model, size, refs, prompt):
    """What one call should cost (USD), and its parts."""
    p = PRICES[model]
    pic = p["image"][size]
    ref = refs * REF_TOKENS * p["input"] / 1e6
    text = (len(prompt) / 4 + 50) * p["input"] / 1e6   # about four characters a token, and the request's own words
    think = THINK_TOKENS * p["text"] / 1e6
    return {"amount": round(pic + ref + text + think, 6), "picture": pic, "refs": round(ref, 6), "prompt": round(text, 6), "thinking": round(think, 6)}


def cost_of(model, usage, fallback, picture=True):
    """What a call cost by its answer's usage (Interactions: total_input_tokens, output_tokens_by_modality,
    total_thought_tokens; generateContent: usageMetadata), else the fallback. picture=False: an answer with no picture
    (blocked), whose input and thinking are billed all the same."""
    p = PRICES[model]
    if not isinstance(usage, dict) or not usage:
        return fallback, "the estimate (the answer gave no usage)"
    if "promptTokenCount" in usage:   # generateContent's usageMetadata
        img = sum(d.get("tokenCount", 0) for d in usage.get("candidatesTokensDetails") or [] if str(d.get("modality", "")).upper() == "IMAGE")
        txt = max(0, int(usage.get("candidatesTokenCount") or 0) - img) + int(usage.get("thoughtsTokenCount") or 0)
        inp = int(usage.get("promptTokenCount") or 0)
    else:
        outm = {str(d.get("modality", "")).lower(): int(d.get("tokens") or 0) for d in usage.get("output_tokens_by_modality") or []}
        img = outm.get("image", 0)
        txt = int(usage.get("total_output_tokens") or 0) - img + int(usage.get("total_thought_tokens") or 0)
        inp = int(usage.get("total_input_tokens") or 0)
    if picture and not img:
        return fallback, "the estimate (the usage named no image tokens)"
    if not (img or inp or txt):
        return fallback, "the estimate (the usage counted nothing)"
    return round(inp * p["input"] / 1e6 + img * p["image_out"] / 1e6 + max(0, txt) * p["text"] / 1e6, 6), "the answer's usage"


# ---- the providers ----

def mime_of(path):
    return {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp"}.get(Path(path).suffix.lower())


PICTURE_NAMES = {"image/png": "PNG", "image/jpeg": "JPEG", "image/webp": "WebP"}


def picture_type(path):
    """What a file is by its first bytes: "image/png", "image/jpeg" or "image/webp"; None for anything else, or unreadable."""
    try:
        with open(path, "rb") as f:
            head = f.read(12)
    except OSError:
        return None
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if head.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "image/webp"
    return None


PICTURE_EXT = {"image/png": ".png", "image/jpeg": ".jpg", "image/webp": ".webp"}


def picture_problem(path):
    """None when a file's name and its bytes agree on a PNG, JPEG or WebP; else what is wrong and what to do, in a few
    words (a JPEG named .png goes to a vendor as a PNG it is not, and a text file named .png as a picture)."""
    by_name, by_bytes = mime_of(path), picture_type(path)
    suffix = Path(path).suffix or "no extension"
    if by_bytes is None:
        named = "" if by_name else f" (nor does its name: {suffix})"
        return f"its bytes are no PNG, JPEG or WebP{named}: save it as one of them"
    if by_name is None:
        return f"its bytes are a {PICTURE_NAMES[by_bytes]}, but it is named with {suffix}: name it {PICTURE_EXT[by_bytes]}"
    if by_name != by_bytes:
        return (f"named {suffix}, but its bytes are a {PICTURE_NAMES[by_bytes]}: convert it to a {PICTURE_NAMES[by_name]}, "
                f"or name it {PICTURE_EXT[by_bytes]}")
    return None


def cast_said(labels):
    """[(n, label)] of the pictures --ref cast:<id> sent → "references 1–3: cast:fox (character: …); 4: …": the prompt
    should say which picture is which"""
    runs = []
    for n, label in labels:
        if runs and runs[-1][2] == label and runs[-1][1] == n - 1:
            runs[-1][1] = n
        else:
            runs.append([n, n, label])
    return (("reference " if len(labels) == 1 else "references ") + "; ".join(f"{a}{'' if a == b else f'–{b}'}: {label}" for a, b, label in runs)
            + " (the prompt should say which picture is which)")


def gemini_body(model, prompt, refs, aspect, size, seed):
    parts = [{"type": "text", "text": prompt}] + [{"type": "image", "mime_type": picture_type(r) or mime_of(r), "data": base64.b64encode(Path(r).read_bytes()).decode("ascii")}
                                                 for r in refs]
    return {"model": model, "input": parts, "response_format": {"type": "image", "mime_type": "image/jpeg", "aspect_ratio": aspect, "image_size": size},
            "generation_config": {"seed": seed, **({"thinking_level": THINKING[model]} if model in THINKING else {})}, "store": False}


def media_of(answer, kind="image"):
    """(bytes, mime, text, usage) of an answer's picture or sound (kind "image" or "audio"): Interactions' steps →
    content blocks, or generateContent's candidates → parts (inlineData). Failed: none in it (said why)."""
    if not isinstance(answer, dict):
        raise Failed("the answer is not a JSON object")
    what = {"image": "picture", "audio": "sound"}[kind]
    texts, got = [], None
    for st in answer.get("steps") or []:
        for b in (st.get("content") or []) if isinstance(st, dict) else []:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "text" and b.get("text"):
                texts.append(b["text"])
            elif b.get("type") == kind and b.get("data"):
                got = (b["data"], b.get("mime_type") or ("image/png" if kind == "image" else "audio/mpeg"))
    for c in answer.get("candidates") or []:
        for prt in ((c.get("content") or {}).get("parts") or []) if isinstance(c, dict) else []:
            inl = prt.get("inlineData") or prt.get("inline_data") if isinstance(prt, dict) else None
            if inl and inl.get("data") and str(inl.get("mimeType") or inl.get("mime_type") or kind).startswith(kind):
                got = (inl["data"], inl.get("mimeType") or inl.get("mime_type"))
            elif isinstance(prt, dict) and prt.get("text"):
                texts.append(prt["text"])
    usage = answer.get("usage") or answer.get("usageMetadata") or {}
    if got is None:
        why = answer.get("status") if answer.get("status") not in (None, "completed") else None
        errs = "; ".join(str(e.get("message") or e) for e in answer.get("errors") or [] if isinstance(e, dict))
        blocked = next((c.get("finishReason") for c in answer.get("candidates") or [] if isinstance(c, dict) and c.get("finishReason") not in (None, "STOP")), None)
        raise Failed(f"no {what} in the answer" + "".join(f" ({x})" for x in (why, blocked, errs) if x) + (f": it said {' '.join(texts)[:300]!r}" if texts else ""))
    try:
        data = base64.b64decode(got[0], validate=False)
    except (ValueError, TypeError) as e:
        raise Failed(f"the {what}'s data is not base64 ({e})")
    return data, got[1], " ".join(texts), usage


def picture_of(answer):
    return media_of(answer, "image")


def codex_home():
    return Path(os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex"))


def codex_picture(prompt, aspect, alpha, timeout, refs=()):
    """(bytes, where it was found, the CLI's version) from codex exec's image_gen: read-only sandbox, one call, the
    picture under $CODEX_HOME/generated_images/<thread>/ (or embedded in that session's log). The user's own config
    stays as it is, its model too; only the reasoning effort is set, low: making a picture is one tool call. refs go
    with -i, after the prompt's "-": -i takes several values, and would take that "-" for a picture. Each is copied
    under a plain name first: -i splits a path at its commas, and what it cannot read it only tells the model."""
    exe = shutil.which("codex")
    if not exe:
        raise Usage("the codex CLI is not installed (npm install -g @openai/codex, then codex login with ChatGPT): or --provider gemini")
    ver = subprocess.run([exe, "--version"], capture_output=True, text=True).stdout.strip()
    token = f"ovh-{os.getpid()}-{int(time.time() * 1000)}"
    what = ("create exactly one image" if not refs else "edit the attached image, creating exactly one image" if len(refs) == 1
            else f"edit the {len(refs)} attached images, numbered in the order attached, into exactly one image")
    ask = CODEX_PREAMBLE.format(what=what) + (f"The image must be {aspect} (width:height), filling the frame, no borders.\n\n" if aspect else "") \
        + ("The background must be transparent: a PNG with an alpha channel, nothing behind the subject.\n\n" if alpha else "") + prompt \
        + f"\n\n(job {token}; ignore this line)"
    start = time.time()
    with tempfile.TemporaryDirectory(prefix="ovh-codex-") as cwd:
        attach = [x for i, r in enumerate(refs, 1) for x in ("-i", shutil.copyfile(r, str(Path(cwd) / f"ref-{i}{Path(r).suffix}")))]
        p = subprocess.Popen([exe, "-c", "model_reasoning_effort=low", "exec", "--skip-git-repo-check", "--sandbox", "read-only", "--json", "-C", cwd, "-"] + attach,
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            so, se = p.communicate(ask, timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(p.pid), signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                p.kill()
            so, se = p.communicate()
    threads = []
    for line in (so or "").splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if isinstance(ev, dict) and ev.get("thread_id"):
            threads.append(str(ev["thread_id"]))
    pics = []
    for th in dict.fromkeys(threads):
        pics += [Path(f) for f in glob.glob(str(codex_home() / "generated_images" / th / "*.png")) if os.path.getmtime(f) >= start - 5]
    if pics:
        best = max(pics, key=os.path.getmtime)
        return best.read_bytes(), str(best), ver
    for f in sorted(glob.glob(str(codex_home() / "sessions" / "*" / "*" / "*" / "rollout-*.jsonl")), key=os.path.getmtime):   # embedded instead
        if os.path.getmtime(f) < start - 5:
            continue
        text = Path(f).read_text(encoding="utf-8", errors="ignore")
        if token not in text:
            continue
        for line in text.splitlines():
            if "image_generation_call" not in line:
                continue
            try:
                ev = json.loads(line).get("payload", {})
            except (ValueError, AttributeError):
                continue
            if ev.get("type") == "image_generation_call" and ev.get("result"):
                try:
                    return base64.b64decode(ev["result"]), f, ver
                except (ValueError, TypeError):
                    pass
    said = codex_said(so, se)
    raise Failed(f"codex made no picture ({ver or 'codex'}, exit {p.returncode}): " + (said or "it said nothing"))


def codex_said(so, se):
    """What codex exec said when it made nothing: the errors in its --json events as it wrote them (the API's message and
    code, from inside the JSON a message may wrap), else its stderr's last lines; and what to change for the known ones.
    The model is the user's own (their Codex config), never one named here."""
    errs = []
    for line in (so or "").splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if not isinstance(ev, dict) or ev.get("type") not in ("error", "turn.failed"):
            continue
        msg = ev.get("message") if ev.get("type") == "error" else (ev.get("error") or {}).get("message")
        code = None
        try:
            inner = json.loads(msg).get("error") or {}
            msg, code = inner.get("message") or msg, inner.get("code")
        except (TypeError, ValueError, AttributeError):
            pass
        if msg and (msg, code) not in errs:
            errs.append((str(msg), code))
    said = "; ".join(f"{m}" + (f" [{c}]" if c else "") for m, c in errs) or " ".join((se or "").strip().splitlines()[-3:])[-500:]
    if not said:
        return ""
    codes = {c for _, c in errs}
    if "model_not_found" in codes:
        said += (" — the model is the one your Codex config names (model in $CODEX_HOME/config.toml, ~/.codex by default): "
                 "a newer codex CLI may know it (npm install -g @openai/codex), or name a model your plan has there")
    elif re.search(r"config\.toml|unknown variant", said):
        said += " — your Codex config has a value this CLI does not know: update the CLI (npm install -g @openai/codex) or change that line"
    return "codex said: " + said


# ---- pictures ----

def png_size(data):
    """(width, height, has an alpha channel) of PNG bytes, or None."""
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        return None
    w, h = int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
    return w, h, data[25] in (4, 6) or b"tRNS" in data[:4096]


def picture_size(data):
    """(width, height, has an alpha channel) of PNG or JPEG bytes (a JPEG's from its frame header), or None."""
    if data[:2] != b"\xff\xd8":
        return png_size(data)
    i = 2
    while i + 9 <= len(data) and data[i] == 0xFF:
        if data[i + 1] in (0xC0, 0xC1, 0xC2):
            return int.from_bytes(data[i + 7:i + 9], "big"), int.from_bytes(data[i + 5:i + 7], "big"), False
        i += 2 + int.from_bytes(data[i + 2:i + 4], "big")
    return None


def rgba(path):
    """(width, height, RGBA bytes) of a picture, decoded by ffmpeg."""
    pr = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0", str(path)],
                        capture_output=True, text=True)
    try:
        w, h = (int(x) for x in pr.stdout.strip().split(",")[:2])
    except ValueError:
        raise Failed(f"{path}: not a picture ffmpeg can read")
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgba", "-"], capture_output=True).stdout
    if len(raw) != w * h * 4:
        raise Failed(f"{path}: decoded {len(raw)} bytes, not {w}×{h}×4")
    return w, h, raw


def border_colour(path):
    """The median colour of a picture's outer band (2 % of its shorter side), and how much it varies there."""
    w, h, raw = rgba(path)
    b = max(2, min(w, h) // 50)
    step = max(1, (w * h) // 200000)
    px = []
    for y in range(0, h, 1 if h <= 400 else 2):
        edge = y < b or y >= h - b
        for x in (range(0, w, step) if edge else list(range(0, b, step)) + list(range(w - b, w, step))):
            i = 4 * (y * w + x)
            px.append(raw[i:i + 3])
    if not px:
        raise Failed(f"{path}: too small to measure")
    med = [sorted(c[k] for c in px)[len(px) // 2] for k in range(3)]
    spread = max(sorted(abs(c[k] - med[k]) for c in px)[int(len(px) * 0.9)] for k in range(3))
    return med, spread


def spill(path, blue=False):
    """The spill on a cutout's edge band: the mean of G − max(R, B) (B − max(R, G) for a blue key) where the alpha is
    between 0.05 and 0.95, and how much of the picture is opaque."""
    w, h, raw = rgba(path)
    edge, s, opaque = 0, 0.0, 0
    step = 1 if w * h <= 2_000_000 else 2
    k, o1, o2 = (2, 0, 1) if blue else (1, 0, 2)
    for i in range(0, w * h * 4, 4 * step):
        a = raw[i + 3]
        if a > 242:
            opaque += 1
        if 13 <= a <= 242:
            edge += 1
            s += raw[i + k] - max(raw[i + o1], raw[i + o2])
    return (round(s / edge, 2) if edge else 0.0), edge * step, round(opaque * step / (w * h), 4)


def cutout(project, src, key="auto", similarity=0.16, blend=0.08, cid=None, by=f"{PROG} cutout"):
    """<name>.cutout.png beside src and its record (derived from src's), with the check sheet. → (path, facts)."""
    src = Path(src)
    if key == "auto":
        rgb, spread = border_colour(src)
    else:
        m = re.fullmatch(r"#?([0-9a-fA-F]{6})", {"green": "#00FF00", "blue": "#0000FF"}.get(key, key))
        if not m:
            raise Usage(f"--key {key!r}: auto, green, blue or #rrggbb")
        rgb, spread = [int(m.group(1)[k:k + 2], 16) for k in (0, 2, 4)], None
    hexkey = "0x" + "".join(f"{c:02X}" for c in rgb)
    blue = rgb[2] > rgb[1]
    dst = src.with_name(f"{src.stem}.cutout.png")
    check = src.with_name(f"{src.stem}.cutout-check.png")
    r = subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(src), "-vf", f"format=rgb24,chromakey={hexkey}:{similarity}:{blend},despill=type={'blue' if blue else 'green'},format=rgba",
                        "-frames:v", "1", str(dst)], capture_output=True, text=True)
    if r.returncode:
        raise Failed(f"ffmpeg chromakey: {r.stderr.strip()[-400:]}")
    w, h, _ = rgba(dst)
    side = max(1, min(w, 640))
    graph = ";".join(f"color=c={c}:s={w}x{h}[b{k}];[b{k}][{k}:v]overlay=format=auto,scale={side}:-2[o{k}]" for k, c in enumerate(("black", "white", "0xF5EFE6")))
    r = subprocess.run(["ffmpeg", "-v", "error", "-y"] + sum((["-i", str(dst)] for _ in range(3)), []) + ["-filter_complex", graph + ";[o0][o1][o2]hstack=3",
                        "-frames:v", "1", str(check)], capture_output=True, text=True)
    if r.returncode:
        raise Failed(f"ffmpeg (the check sheet): {r.stderr.strip()[-400:]}")
    sp, band, opaque = spill(dst, blue)
    facts = {"key": hexkey, "measured": key == "auto", "spread": spread, "similarity": similarity, "blend": blend, "spill": sp, "edge_pixels": band,
             "opaque": opaque, "check": ledger.rel(project, check), "size": [w, h]}
    _, ents, _ = ledger.entries(project)
    rel_src = ledger.rel(project, src)
    srcrec = next((e["record"] for e in ents if e["record"].get("path") == rel_src and "removed" not in e["record"]), None)
    lic = (srcrec or {}).get("license") or {}
    rel_dst = ledger.rel(project, dst)
    at = next((e["record"] for e in ents if e["record"].get("path") == rel_dst and "removed" not in e["record"]), None)   # cut out before
    if at and cid and cid != at.get("id"):
        raise Usage(f"{rel_dst} is on record as {at.get('id')} already: cut it out again without --id")
    try:
        rec, old, _ = ledger.add(project, str(dst), id=at.get("id") if at else (cid or (srcrec or {}).get("id", ledger.slug(src.stem)) + ".cutout"), kind="image",
                                 license=lic.get("name"), license_url=lic.get("url"), license_class=lic.get("class") or None,
                                 source=dict((srcrec or {}).get("source") or {"origin": "self"}), aigc=(srcrec or {}).get("aigc"),
                                 model=(srcrec or {}).get("model"), derived_from=(srcrec or {}).get("id"),
                                 note=f"cut out of {rel_src}: chromakey {hexkey}:{similarity}:{blend} and despill (bin/vh image cutout)",
                                 update=bool(at), by=by)
    except (ledger.Refused, ValueError) as e:
        raise Usage(f"cut out into {ledger.rel(project, dst)}, but not registered: {e}")
    return dst, facts, rec


# ---- commands ----

def brief_aspect(project):
    try:
        s = (project / "BRIEF.md").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    m = re.search(r"^\s*[-*]\s*Output\s*[:：]\s*(\d{3,5})\s*[x×]\s*(\d{3,5})", s, re.M | re.I)
    if not m:
        return None
    w, h = int(m.group(1)), int(m.group(2))
    return min(ASPECTS, key=lambda a: abs(int(a.split(":")[0]) / int(a.split(":")[1]) - w / h))


def note_activity(what, paths):
    try:
        import activity
        activity.note(what, [str(p) for p in paths])
    except Exception:   # the log never fails a command
        pass


def write_json(f, d):
    tmp = f.with_name(f".{f.name}.{os.getpid()}")
    tmp.write_text(json.dumps(d, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    os.replace(tmp, f)


def sheet(paths, dest):
    """A contact sheet of several pictures, side by side at 480 px."""
    graph = "".join(f"[{k}:v]scale=480:-2,pad=480:ih[s{k}];" for k in range(len(paths))) + "".join(f"[s{k}]" for k in range(len(paths))) + f"hstack={len(paths)}"
    r = subprocess.run(["ffmpeg", "-v", "error", "-y"] + sum((["-i", str(p)] for p in paths), []) + ["-filter_complex", graph, "-frames:v", "1", str(dest)],
                       capture_output=True, text=True)
    return r.returncode == 0


def cmd_prices(a):
    rows = [{"model": m, **{k: v for k, v in p.items()}, "ref_each": round(REF_TOKENS * p["input"] / 1e6, 6), "thinking_allowance": round(THINK_TOKENS * p["text"] / 1e6, 6),
             "tier": next((t for t, x in TIERS.items() if x == m), None)} for m, p in PRICES.items()]
    if a.json:
        print(json.dumps({"version": 1, "tool": f"{PROG} prices", "checked": PRICES_CHECKED, "currency": "USD", "models": rows,
                          "codex": "on the ChatGPT plan's quota: not billed per picture"}, ensure_ascii=False, indent=1))
    say(f"image prices (USD a picture, ai.google.dev/gemini-api/docs/pricing, checked {PRICES_CHECKED}; batch is half, not used here)")
    for r in rows:
        say(f"  {r['model']:<28} {r['name']:<20} " + " · ".join(f"{s} ${v:g}" for s, v in r["image"].items())
            + f"  · a reference +${r['ref_each']:.4f} · thinking up to +${r['thinking_allowance']:.4f}" + (f"  (--tier {r['tier']})" if r["tier"] else ""))
    say("  codex image_gen          on the ChatGPT plan the Codex CLI is signed in with: not billed per picture, no budget held")
    return 0


def paid_call(h, estimate, url, body, opener, timeout=180):
    """post_json under a hold h: an HTTP error answer (status 4xx/5xx) and a request that never left (refused, no such
    host) settle at 0; a timeout, a reset or an answer that cannot be read leave the hold at the estimate, as such a
    call may have been billed. → the answer."""
    try:
        return fetch.post_json(url, body, opener, secret={"x-goog-api-key": os.environ.get("GEMINI_API_KEY", "")}, timeout=timeout)
    except fetch.FetchError as e:
        if (e.status or 0) >= 400 or not e.sent:
            h.settle(0)
            raise Failed(str(e))
        raise Failed(f"{e}: it may have been billed, so the estimate (${estimate:.4f}) stays as spent; "
                     "the provider's usage page says what it was") from None


def cmd_gen(a):
    project = A.find(a.project)
    if bool(a.prompt) == bool(a.prompt_file):
        raise Usage("--prompt TEXT or --prompt-file F (one of them)")
    if a.prompt_file:
        pf = ledger.find_file(project, a.prompt_file)
        if pf is None:
            raise Usage(f"no such prompt file: {a.prompt_file}")
        prompt = pf.read_text(encoding="utf-8").strip()
    else:
        prompt = a.prompt.strip()
    if not prompt:
        raise Usage("the prompt is empty")
    if a.n < 1 or a.n > 8:
        raise Usage("--n: 1 to 8 pictures")
    refs, labels, drafts = [], [], []   # labels: what each --ref cast:<id> picture is (bin/vh cast), said with the upload
    for r in a.ref or []:
        if r.startswith("cast:"):   # a settled reference of the project's cast: its pictures, in its order
            import cast
            try:
                got = cast.refs_for(project, r)
                cid, _, entry = cast.entry_for(project, r)
            except cast.Usage as e:
                raise Usage(str(e))
            if entry.get("status") != "final" and cid not in drafts:
                drafts.append(cid)
            for f, label in got:
                refs.append(f); labels.append((len(refs), label))
            continue
        f = ledger.find_file(project, r)
        if f is None or not f.is_file():
            raise Usage(f"--ref {r}: no such PNG, JPEG or WebP (from here, nor in the project), nor cast:<id>")
        refs.append(f)
    for f in refs:   # each picture by its bytes, not its name: what is sent goes as what it is
        why = picture_problem(f)
        if why:
            raise Usage(f"--ref {ledger.rel(project, f)}: {why}")
    twice = sorted({ledger.rel(project, f) for f in refs if sum(Path(x).resolve() == Path(f).resolve() for x in refs) > 1})
    if twice:   # cast:fox and cast:fox:front, or one --ref given twice: the same picture goes (and is paid for) twice
        say(f"  ! the same picture is sent more than once: {', '.join(twice)} (one --ref each is enough)")
    for cid in drafts:
        say(f"  ! cast:{cid} is a draft, not settled yet (bin/vh cast add {cid} --final once the person has): what is made from it may need making again")
    aspect = a.aspect or brief_aspect(project) or "16:9"
    if aspect not in ASPECTS:
        raise Usage(f"--aspect {aspect}: one of {', '.join(ASPECTS)}")
    if a.id and not ledger.ID.match(a.id):
        raise Usage(f"--id {a.id}: letters, digits, . _ - (up to 64)")
    cid = a.id or ledger.slug("img-" + "-".join(re.findall(r"[A-Za-z0-9]+", prompt)[:4]) if re.search(r"[A-Za-z0-9]", prompt) else "img")
    _, ents, _ = ledger.entries(project)
    taken = {e["record"].get("id") for e in ents}
    ids = [cid] if a.n == 1 else [f"{cid}-{k}" for k in range(1, a.n + 1)]
    if a.id and any(i in taken for i in ids):
        raise Usage(f"the id {cid} is on record already (ids are never reused): another --id")
    while any(i in taken for i in ids) or (project / GENIMG / cid).exists():
        m = re.match(r"(.*?)-(\d+)$", cid)
        cid = f"{m.group(1)}-{int(m.group(2)) + 1}" if m and not a.id else f"{cid}-2"
        ids = [cid] if a.n == 1 else [f"{cid}-{k}" for k in range(1, a.n + 1)]
    folder = project / GENIMG / cid
    ask = (prompt + "\n\n" + GREEN) if a.alpha and a.provider == "gemini" else prompt
    plan = {"provider": a.provider, "id": cid, "ids": ids, "aspect": aspect, "n": a.n, "refs": [ledger.rel(project, r) for r in refs], "alpha": a.alpha}
    if a.provider == "gemini":
        model = a.model or TIERS[a.tier]
        if model not in PRICES:
            raise Usage(f"--model {model}: not one gen knows the price of ({', '.join(PRICES)}; bin/vh image prices)")
        size = a.size or ("2K" if a.tier == "final" else "1K")
        if size not in PRICES[model]["image"]:
            raise Usage(f"--size {size}: {model} makes {', '.join(PRICES[model]['image'])}")
        if len(refs) > PRICES[model]["refs"]:
            raise Usage(f"--ref: {model} takes up to {PRICES[model]['refs']} reference pictures, not {len(refs)}")
        est = estimate(model, size, len(refs), ask)
        each = est["amount"]
        plan.update(model=f"gemini/{model}", size=size, estimate=est, total=round(each * a.n, 6))
        chk = budget.check(project, round(each * a.n, 6), "USD")
        plan["budget"] = {k: chk[k] for k in ("ok", "budget", "spent", "held", "after", "short", "message")}
    else:
        if a.size or a.model or a.tier != "draft" or a.seed is not None:
            raise Usage("--size, --model, --tier and --seed are for gemini; codex takes the prompt, --aspect, --ref and --alpha")
        plan.update(model="codex/image_gen", size=None, estimate={"amount": 0.0}, total=0.0, budget={"ok": True, "message": "codex: the ChatGPT plan's quota, no budget held"})
    if a.dry_run:
        if a.json:
            print(json.dumps({"version": 1, "tool": f"{PROG} gen", "dry_run": True, "project": str(project), **plan}, ensure_ascii=False, indent=1))
        if a.provider == "gemini":
            e = plan["estimate"]
            say(f"image gen --dry-run: {a.n} × {plan['model']} {plan['size']} {aspect}" + (f", {len(refs)} reference(s)" if refs else "")
                + f": about ${plan['total']:.4f} (each ${e['picture']:g} the picture + ${e['refs'] + e['prompt']:.4f} input + up to ${e['thinking']:.4f} thinking)")
        else:
            say(f"image gen --dry-run: {a.n} × codex image_gen {aspect}" + (f", {len(refs)} reference(s)" if refs else "") + ": the ChatGPT plan's quota, nothing billed")
        say(f"  {plan['budget']['message']}")
        if labels:
            say(f"  · {cast_said(labels)}")
        say("  nothing called (--dry-run)")
        return 0
    if a.provider == "gemini":
        if not a.offline and not os.environ.get("GEMINI_API_KEY"):
            raise Usage("set GEMINI_API_KEY (Google AI Studio → Get API key): it is read from the environment only")
        if not plan["budget"]["ok"]:
            raise Failed(f"{plan['budget']['message']} (bin/vh image gen --dry-run shows the estimate)")
    if refs:
        say(f"  · {len(refs)} reference picture(s) go to {'Google' if a.provider == 'gemini' else 'OpenAI (through Codex)'} with the prompt")
        if labels:
            say(f"  · {cast_said(labels)}")
    opener = fetch.opener_from(a.offline)
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "prompt.txt").write_text(ask + "\n", encoding="utf-8")
    made, recs, spent = [], [], 0.0
    for k, pid in enumerate(ids):
        name = "image.png" if a.n == 1 else f"image-{k + 1}.png"
        seed = a.seed if a.seed is not None else (secrets.randbelow(2**31 - 1) if a.provider == "gemini" else None)
        if a.provider == "gemini":
            model = plan["model"].split("/", 1)[1]
            body = gemini_body(model, ask, refs, aspect, plan["size"], seed)
            write_json(folder / ("request.json" if a.n == 1 else f"request-{k + 1}.json"),
                       dict(body, input=[b if b["type"] == "text" else {"type": "image", "mime_type": b["mime_type"], "path": plan["refs"][i - 1]}
                                         for i, b in enumerate(body["input"])]))
            if a.offline:   # a recorded answer: nothing is called, so nothing is held or spent
                data, mime, said, usage = picture_of(fetch.post_json(API, body, opener))
                cost, how = cost_of(model, usage, plan["estimate"]["amount"])
                replayed, cost, how = cost, 0.0, f"nothing spent: replayed with --offline (a call: ${cost:.4f} by {how})"
            else:
                replayed = None
                try:
                    with budget.hold(project, plan["estimate"]["amount"], "USD", f"image gen {pid} ({model} {plan['size']})", tool=f"{PROG} gen", asset=pid) as h:
                        answer = paid_call(h, plan["estimate"]["amount"], API, body, opener)
                        try:
                            data, mime, said, usage = picture_of(answer)
                        except Failed:   # blocked: the input and the thinking are billed all the same
                            h.settle(cost_of(model, (answer or {}).get("usage") or {}, 0.0, picture=False)[0] if isinstance(answer, dict) else 0)
                            raise
                        cost, how = cost_of(model, usage, plan["estimate"]["amount"])
                        h.settle(cost)
                except budget.Refused as e:
                    raise Failed(str(e))
            where = "Google's Interactions API"
        else:
            data, where, ver = codex_picture(prompt, aspect, a.alpha, a.timeout, refs)
            mime, said, cost, how, replayed = "image/png", "", 0.0, "the ChatGPT plan's quota", None
            model = f"image_gen via codex ({ver})" if ver else "image_gen via codex"
        if mime != "image/png":
            name = name[:-4] + {"image/jpeg": ".jpg", "image/webp": ".webp"}.get(mime, ".bin")
        dest = folder / name
        dest.write_bytes(data)
        info = picture_size(data)
        spent += cost
        extra = {"inputs": [{"path": plan["refs"][i], "sha256": ledger.sha256_file(r)} for i, r in enumerate(refs)]} if refs else {}
        extra["request"] = {"aspect": aspect, **({"size": plan["size"]} if plan["size"] else {}), "provider": a.provider}
        if said:
            extra["model_said"] = said[:500]
        if replayed is not None:
            extra["offline"] = f"replayed from a recording: nothing called, nothing spent (a call: ${replayed:.4f})"
        try:
            rec, _, _ = ledger.add(project, str(dest), id=pid, kind="image", license_class="generated",
                                   license="the vendor's terms: Gemini API" if a.provider == "gemini" else "the vendor's terms: OpenAI (ChatGPT plan, through Codex)",
                                   source={"origin": "generated", "provider": "gemini" if a.provider == "gemini" else "codex"}, aigc=True,
                                   model=plan["model"] if a.provider == "gemini" else f"openai/{model}", prompt_file=str(folder / "prompt.txt"), seed=seed,
                                   cost={"amount": round(cost, 6), "currency": "USD"} if a.provider == "gemini" and replayed is None else None,
                                   used_by=[x.strip() for x in a.used_by.split(",") if x.strip()] if a.used_by else None, tags=["genimg"],
                                   note="AI-generated, illustrative: not a photograph of anything that happened", extra=extra, by=f"{PROG} gen")
        except (ledger.Refused, ValueError, ledger.LedgerError) as e:
            raise Usage(f"made {ledger.rel(project, dest)}, but not registered: {e}")
        made.append(dest)
        recs.append(rec)
        say(f"made {pid}: {ledger.rel(project, dest)}" + (f" · {info[0]}×{info[1]}" if info else "") + f" · {plan['model'] if a.provider == 'gemini' else 'codex image_gen'}"
            + (f" · {how}" if replayed is not None else f" · ${cost:.4f} ({how})" if a.provider == "gemini" else " · the ChatGPT plan's quota")
            + (f" · seed {seed}" if seed is not None else ""))
        if a.alpha:
            if a.provider == "gemini":
                cdst, facts, crec = cutout(project, dest, by=f"{PROG} gen --alpha")
                recs.append(crec)
                say(f"  cutout {ledger.rel(project, cdst)}: key {facts['key']} (measured on the border, spread {facts['spread']}) · spill {facts['spill']}"
                    + (" (over 4: a green fringe will show)" if facts["spill"] > 4 else "") + f" · look at {facts['check']}")
            elif not (info and info[2]):
                say("  ! codex sent no alpha channel: bin/vh image cutout <project> " + ledger.rel(project, dest) + " if its background is flat")
    if len(made) > 1 and sheet(made, folder / "sheet.png"):
        say(f"  sheet: {ledger.rel(project, folder / 'sheet.png')}")
    note_activity(f"made {len(made)} picture(s) {cid} ({plan['model']}, ${spent:.4f})", [project / ledger.LEDGER] + made)
    if a.provider == "gemini":
        say("  " + budget.line(project))
    if a.json:
        print(json.dumps({"version": 1, "tool": f"{PROG} gen", "project": str(project), **plan, "spent": round(spent, 6), "records": recs,
                          "files": [ledger.rel(project, f) for f in made]}, ensure_ascii=False, indent=1))
    return 0


def cmd_cutout(a):
    project = A.find(a.project)
    src = ledger.find_file(project, a.image)
    if src is None or not src.is_file():
        raise Usage(f"no such picture: {a.image}")
    dst, facts, rec = cutout(project, src, a.key, a.similarity, a.blend, a.id)
    note_activity(f"cut out {ledger.rel(project, src)} → {ledger.rel(project, dst)}", [project / ledger.LEDGER, dst])
    say(f"cutout: {ledger.rel(project, dst)} · key {facts['key']}" + (f" (measured on the border, spread {facts['spread']})" if facts["measured"] else "")
        + f" · {facts['opaque'] * 100:.1f}% opaque · spill {facts['spill']} on {facts['edge_pixels']} edge pixels" + (" (over 4: a green fringe will show)" if facts["spill"] > 4 else ""))
    if facts["measured"] and facts["spread"] is not None and facts["spread"] > 24:
        say(f"  ! the border is not one flat colour (spread {facts['spread']}): chromakey leaves its edges; a matting model does better (playbook/05)")
    say(f"  look at {facts['check']}: on black, white and paper")
    if a.json:
        print(json.dumps({"version": 1, "tool": f"{PROG} cutout", "project": str(project), "file": ledger.rel(project, dst), **facts, "record": rec},
                         ensure_ascii=False, indent=1))
    return 0


def parser():
    ap = argparse.ArgumentParser(prog=PROG, description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog="\n\n".join(__doc__.split("\n\n")[1:]))
    sp = ap.add_subparsers(dest="cmd", metavar="{" + ",".join(SUB) + "}")
    p = sp.add_parser("gen", prog=f"{PROG} gen", help="generate pictures into the project, on record")
    p.add_argument("project")
    p.add_argument("--prompt")
    p.add_argument("--prompt-file")
    p.add_argument("--provider", choices=("gemini", "codex"), default="gemini")
    p.add_argument("--tier", choices=tuple(TIERS), default="draft")
    p.add_argument("--model")
    p.add_argument("--size", choices=("1K", "2K", "4K"))
    p.add_argument("--aspect")
    p.add_argument("--ref", action="append")
    p.add_argument("--alpha", action="store_true")
    p.add_argument("--n", type=int, default=1)
    p.add_argument("--seed", type=int)
    p.add_argument("--id")
    p.add_argument("--used-by")
    p.add_argument("--timeout", type=int, default=480, help="codex: seconds before giving up")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--offline")
    p.add_argument("--json", action="store_true")
    p = sp.add_parser("cutout", prog=f"{PROG} cutout", help="a transparent background for a picture on a flat colour")
    p.add_argument("project")
    p.add_argument("image")
    p.add_argument("--key", default="auto")
    p.add_argument("--similarity", type=float, default=0.16)
    p.add_argument("--blend", type=float, default=0.08)
    p.add_argument("--id")
    p.add_argument("--json", action="store_true")
    p = sp.add_parser("prices", prog=f"{PROG} prices", help="the models and their prices")
    p.add_argument("--json", action="store_true")
    return ap


def main(argv):
    global out
    if not argv:
        parser().print_usage(sys.stderr)
        print(f"{PROG}: a subcommand ({', '.join(SUB)})", file=sys.stderr)
        return 2
    a = parser().parse_args(argv)
    if a.cmd is None:
        parser().print_usage(sys.stderr)
        return 2
    if getattr(a, "json", False):
        out = sys.stderr
        A.out = sys.stderr
    if a.cmd in ("gen", "cutout") and not shutil.which("ffmpeg"):
        print(f"{PROG} {a.cmd}: needs ffmpeg and ffprobe (bin/vh doctor)", file=sys.stderr)
        return 2
    try:
        return {"gen": cmd_gen, "cutout": cmd_cutout, "prices": cmd_prices}[a.cmd](a)
    except (Usage, A.Usage) as e:
        print(f"{PROG} {a.cmd}: {e}", file=sys.stderr)
        return 2
    except (Failed, fetch.FetchError, budget.Refused) as e:
        print(f"{PROG} {a.cmd}: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        sys.exit(0)
