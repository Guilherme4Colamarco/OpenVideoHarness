# 审阅台（bin/vh desk）

审阅台是一个本地网页：人在页面里逐条勾选"可以 / 要改 / 疑问"、写一句、提交；agent 在后台等着，人一提交就接着做。它是 `studio` 档位默认的审阅界面，`standard` 想用也可以（什么时候用、agent 怎么挂等待，见 `playbook/01-pipeline.md` 的"审阅台"）。这一页讲它读什么、写什么，也就是项目文件要怎么写，审阅台才排得出来。

**文件是唯一的事实来源。** 审阅台每次刷新都从项目文件重新读，自己不存状态；人的草稿只留在浏览器里，提交以后才落进项目。读不出结构的文档不会被藏起来：每份文档都在"文档"页原样排版，结构化的页面空着时，就地显示那份文档的原文，"文档"页顶上列出哪些没按约定读出来。

## 命令

```bash
bin/vh gate <项目> <n> [--desk|--page|--chat] [--wait]   # 一次停一条命令：查 gate-<n>.json，出静态页并记成这一轮，审阅方式是审阅台时在后台起服务（12 小时没人访问自己停），打印聊天消息；--wait 再像 desk wait 一样等
bin/vh desk <项目> [--port N] [--idle 秒]       # 起服务，只听 127.0.0.1；默认 8780–8799 里第一个空闲端口；这个项目已经有一个在跑，就只打印它的地址；--idle：这么久没人访问就自己停
bin/vh desk wait <项目> [--timeout 秒]          # 等人提交：打印反馈，退出码 0；超时退出码 3（默认 7100 s）
bin/vh desk feedback <项目> [--round 1b] [--json]   # 打印最近一次提交，并记为"已交给 agent"
bin/vh desk data <项目>                        # 审阅台从项目里读出了什么（JSON），排查"为什么这一页是空的"时用
```

只用 Python 标准库，不联网，页面不从 CDN 拉任何东西，浅色和深色都有，界面有中文和英文。

`bin/vh gate`（`tools/gate.py`）把一次停要做的事做完：审阅方式取 `--desk` / `--page` / `--chat`，没有就取 `LOCAL.md` 的"审阅方式"一行，再没有就按档位（`studio` 审阅台，`standard`、`quick` 静态页）。每种方式都出静态页、打印聊天消息；审阅台方式再起服务，把地址加进消息。退出码：0 发出去了（`--wait` 时是收到了提交）；1 页面写了但不合规矩，不发消息也不起服务；2 没东西可发（没有 gate JSON、服务起不来、不是审阅台却要 `--wait`）；3 `--wait` 超时。

**一站的数据就是 `out/review/gate-<n>.json` 这一个文件。** 静态页（`bin/vh review`）、审阅台和以后的客户端都只渲染它（审阅台另外读下面这些项目文件），各自不另存一份。

## 读什么

表格按表头的**开头几个字**认列（中英文都行，英文不分大小写），列的顺序随意，多出来的列不管。

### BRIEF.md

| 位置 | 读什么 | 英文项目 |
|---|---|---|
| 第一行 `# BRIEF：片名` | 片名 | `# BRIEF: title` |
| `## Spec` 的 `- 键: 值` | 全部列出；`Effort`、`Review language`（`zh` / `en`，界面语言；这一轮的 gate JSON 写了 `lang` 时以它为准，和 `bin/vh review` 同一条规则）、`Output`、`Watch on` 放在立意卡上 | 同左 |
| `## Content` 的 `- 键: 值` | `Concept (one line)`、`Spine (one line)`、`Recurring motif`、`What the viewer should know/feel at the end`；`Specifics` 下面缩进的几条 | 同左 |
| `## Outline`（或 `## 大纲`）里的表 | 每段一行，见下 | `## Outline` |

大纲表的列：

| 列（开头是） | 用途 | 英文 |
|---|---|---|
| `#` | 段号；不写就按顺序编 | `#` |
| `段落` | **段名，按内容或阶段起**（"按下发送""信道编码与调制"） | `Segment` |
| `标签` | 可选的小标签，起承转合、幕之类，显示在段名旁边的小框里 | `Tag` |
| `环节` / `阶段` | 可选，这一段讲的环节 | `Stage` |
| `时间` | `0–10 s`、`1:30–1:52`；时间条按它画 | `Time` |
| `小节` | `4–7`；没有"时间"列时，用配乐的节拍表换成秒 | `Bars` |
| `观众` | 观众看完知道 / 感到什么 | `Viewer`、`Takeaway` |
| `关键画面` / `画面` | 关键画面 | `Key visual`、`Visual` |

旧写法的段名"承 · 发出去"会拆成标签"承"和段名"发出去"。

### SCRIPT.md

第一张带 `字幕`（字幕稿）或 `旁白`（旁白稿）列的表。

| 列（开头是） | 用途 | 英文 |
|---|---|---|
| `#` | 条目编号，点评按它记 | `#`、`ID` |
| `段` / `段落` | 属于大纲哪一段：写段名或段号；对不上时按时间归段 | `Segment` |
| `时间` 或 `小节` | 同大纲 | `Time`、`Bars` |
| `术语` | 可选，术语卡上的词（`video-types/02` 的"术语卡"） | `Term` |
| `字幕` / `旁白` | 正文；读速按"这一条占的时间"粗算 | `Caption`、`On-screen`、`Narration`、`VO` |
| `画面` | 画面 | `Visual` |
| `素材` | NOTES 素材清单的编号（`#2 #4`） | `Facts`、`Source` |

### NOTES.md

- `## 素材清单` 里的表：`#`、`素材`、`类别`、`上屏说法`（可选）、`出处`。不再用的素材整格划掉 `~~…~~`（老写法"（关卡 ① 后不用）……"也认），事实核对页把它淡化、不给点评。英文：`## Material`，列 `#`、`Item`、`Kind`、`On screen`、`Source`。
- `## 待核实的事实` 里的 `- [ ]` / `- [x]`。英文：`## To verify`。

### DECISIONS.md

- 表头以 `决定` 开头的表：`决定`、`谁拍板`、`状态`、`在哪看`（导演模式的账本）。英文：`Decision`、`Who`、`Status`、`Where`。
- `## agent 定的事` 下的每条 `- 日期 话题 · 定了什么 — 理由：… — 翻案：…`，中间可以有 `###` 小标题（显示成分组）。**作废的整行划掉**，后面写原因：`- ~~2026-10-03 style · 夜色画面 — 理由：…~~（关卡 ① 后作废）`，审阅台把它收进"已经作废的"，不再给"翻案"按钮。英文：`## Decided by the agent`，`— why: … — undo: …`。

### REVIEW.md

每个 `## ` 小节是一轮：`- 原话（说明）："……"` 是人的原话，`- 定了：…`、`- 改了：…`（同一行写 `定了：A　改了：B` 也行）是之后的处理。只有空占位的小节（模板里还没填的关卡 ②③）和模板最后两节参考文字不算历史。标题以"暂停"开头、又没写"恢复"的小节，让顶栏显示"暂停"。英文：`- Verbatim: "…"`、`- Decided: …`、`- Changed: …`，`Paused`。

### 镜头表：shots.json 或 edit.json

和 `bin/vh storyboard` 同一份（`tools/shot_source.py` 找它）。有剪辑表（`edit.json`，`engines/EDIT.md`）时读它的段，起止是解好的秒，段上的 `transition` 写成文字（`turn 0.8 s`）；剪辑表解不开时，原因写进 warnings。否则读 `shots.json`（格式见 `bin/vh storyboard -h`）：一个列表，或 `{"video", "note", "shots": [...]}`；每镜 `id`、`start`、`end`、`segment`、`label`、`reads`、`caption`、`transition`、`unsure`、`frame`。关键帧取 `frame`，没有就取 `bin/vh storyboard` 写的 `out/check/storyboard/frames/<id>.png`。分镜页播放的视频：`shots.json` 的 `video`，否则最新审阅页的 `animatic`，否则 `out/animatic.mp4`、`out/draft.mp4`。

### out/review/gate-<n>.json

和 `bin/vh review` 是同一份文件，字段见 `playbook/01-pipeline.md` 的"审阅页"（`include` 照样生效）。"这一轮"是 `bin/vh review <项目> <n>`（`bin/vh gate` 也一样）最后做的那一页：它每次把页名写进 `out/review/.current`，审阅台和 `bin/vh desk wait` 都先读它；违反规则、没发出去的那一页照样写出来，但不写进 `.current`，这一轮还是正在外面的那一页。所以关卡 ② 之后回头出一页立意 `1b`、关卡 ③ 之后重定配音出 `E3b`、自己起名的 `final`，都会是"这一轮"。`.current` 没有，或者它指的那一页已经删了，才按流程顺序取最后一页：先按站（1、E0、E1、2、E2、E3、E4、3、E5），同一站再按页（1、1b、1c……，不分大小写）；不合这个写法的页名排在最前，彼此之间看修改时间。复制项目、碰一下旧文件，都不会改变哪一页是"这一轮"。`bin/vh review <项目>` 不写页名时，渲染的也是这一轮；要出新的一页，写上它的名字。页名是 1–24 个字母、数字、`-` 或 `_`，按磁盘上文件本来的写法算（APFS 不分大小写：写 `1D` 找到的是 `gate-1d.json`，这一页就叫 `1d`）；链接到项目外面的 gate 文件不读。审阅台另外认几个可选字段，`bin/vh review` 不管它们：

```json
{
  "listen": [{"t": 9.4, "note": "17 个字飞出手机：每个字一个八音盒的音"}],
  "music": {"audio": "audio/film_mix.wav", "beats": "audio/film.beats.json", "roll": "audio/film.roll/overview.png",
            "labels": {"type": "打字", "send": "发送"}},
  "film": "out/review/open-F2.mp4"
}
```

- `listen`：声音页的"请你听这几处"，`t` 是秒。
- `music`：声音页播哪条音轨、读哪份节拍表、乐段在色块上叫什么（`labels` 把乐段的 `name` 换成人看得懂的名字）。不写时，读 `audio/` 里最新的 `*.beats.json`，音轨取同名的 `*_mix.wav`，没有再取 `*.wav`，谱面取同名的 `.roll/overview.png`。节拍表也用来把"小节"换成秒。
- `film`：逐秒点评页放哪支视频；不写就用 `assets` 里第一支视频。时长从视频本身读。

路径都相对项目目录；审阅台只给项目目录里的文件（不给隐藏文件，不出项目目录）。

## 写什么

提交后，服务按这个顺序写：

1. `out/review/feedback/<轮>-<YYYYMMDD-HHMMSS>.md`：一条一行的文字版，人的话原样不动；
2. `REVIEW.md`：插一节 `## 审阅台反馈 · 关卡 <轮> · <日期 时间>`，把上面的文字整段原样放进代码块，下面留一行"定了：　改了："给 agent 填；插在模板的"授权跳过怎么记"之前，没有这一节就接在文末；
3. `out/review/feedback/<轮>-<YYYYMMDD-HHMMSS>.json`：最后写，原子替换。`bin/vh desk wait` 等的就是它。同一秒里的第二份、第三份加 `-2`、`-3`，按数字排。

交给 agent 的提交记在 `out/review/feedback/.consumed`：`bin/vh desk wait` 打印过的、`bin/vh desk feedback` 打印过的，都算交过了。`wait` 一启动，先看这一轮有没有还没交过、又晚于这一页 gate JSON 的提交（比如上一次 `wait` 超时之后人才提交），有就立刻打印、退出 0；没有才开始等新的。`.listening`（有 agent 在等）和 `.desk.json`（服务在跑）里都记着项目目录的完整路径，从别的项目拷来的这两个文件不算数。

JSON 的格式：

```json
{
  "round": "1c", "lang": "zh", "project": "2026-10-01-glass-of-water", "submitted_at": "2026-10-04T02:38:50",
  "decisions": {"look": "F2"}, "defaulted": [],
  "items": [
    {"target": "seg:9", "status": "change", "label": "大纲 第 9 段 这一次", "text": "这个压根没有升华主题……"},
    {"target": "cap:c11", "status": "change", "label": "字幕 c11", "text": "", "orig": "信号好，一次装 8 个；信号差，只装 2 个。", "suggest": "……"},
    {"target": "time:12.4", "status": "ask", "label": "小样 0:12.4", "text": "这里看不清", "t": 12.4},
    {"target": "range:20-24.5", "status": "change", "label": "小样 0:20.0–0:24.5", "text": "这一段太慢", "t": 20, "t1": 24.5}
  ],
  "general": "大体可以"
}
```

- `decisions`：这一页每个决定选了哪个选项；`defaulted` 列出人没动、按推荐算的。
- `items[].status`：`ok` 可以、`change` 要改、`ask` 疑问。没标的条目都算通过。
- `items[].target` 的前缀说明点评的是什么：`dec:` 决定、`least:` 没把握的、`deleg:` 替人定的（gate JSON `delegated` 的序号）、`concept:line` 立意、`seg:` 大纲段、`cap:` 字幕或旁白条、`shot:` 镜头、`fact:` 素材、`time:` 小样的某一秒、`range:<a>-<b>` 小样的一段（秒，ASCII 数字，存到百分之一秒后仍要 a < b；小样页按 I、O 选）、`atime:` 音轨的某一秒、`chapter:<id>` 一章、`asset:<路径>` 项目里的一件素材（相对项目的路径，不出项目；路径前后、每一段前后都不能有空格）、`card:<id>` 一张立意卡、`led:` DECISIONS 里 agent 定的事（序号）、`doc:<文件>#<小节>` 文档的某一节。整个 target 都要合这个写法：结尾多一个换行、带控制字符的都不收。
- `t` 是秒；`range:` 的条目另有 `t1`，两个都按 target 里的数存，页面发来的不算。没写 `label` 的，`desk feedback` 和 REVIEW.md 按 target 起一个（"片段 0:12.4–0:15.0""章节 c2""素材 assets/a.jpg""立意卡 B"）；一段的 `label` 后面总带着它的起止。
- `suggest` 是人直接写的"改成"，`orig` 是原句。

服务会检查：轮次对得上一份 `gate-<轮>.json`（还没有审阅页时用 `notes`），决定和选项都在那一页里，每个字段的类型、状态和 target 合法，单条文字不超过 4000 字、整份不超过 256 KiB，正文和 Content-Length 对得上；不合的回 400，不会断开连接。

## 给客户端的数据

客户端（审阅台，以后的 Studio）只是项目文件和 `bin/vh` 外面的一层壳：它要的数据都由命令给出，终端里的 agent 拿到的是同一份。下面的 JSON 都带 `"version": 1`；以后只加字段，改了含义就升版本号。

### 命令表：`bin/vh commands [--stage <阶段>] [--json]`

命令面板读它：每条命令的名字、一句话、什么时候用、属于哪几个阶段（playbook/01 总表的 0–9，加 `env`、`any`；`stages[0]` 是主站）、读写什么、用法和子命令，来源是 `tools/commands.json`。`reads`、`writes` 是给人看的文字，带 `<project>`、`<x>` 这类占位，不是能直接解析的路径；子命令名带尖括号的（`style` 的 `<preset>`）也是占位。字段见 `bin/vh commands -h`。

### 这台机器能用什么：`bin/vh doctor [--json] [--probe]`

每个外接模块（`tools/modules.json`：程序、包、模型、服务、agent）在这台机器上的状态：找到没有、版本对不对、服务的 key 设了没有（只说有没有，从不给值），再加上页面工具的浏览器和 WebGL、参考仓库、LOCAL.md、AGENTS.md。`--probe` 给每个设了 key 的服务在不花钱的接口上打一次。字段见 `bin/vh doctor -h`。

### 一个项目到哪了：`bin/vh status <项目> [--json]`

只读，只看已有的文件，不开浏览器、不跑 ffprobe（`tools/status.py`，零点一秒左右）。默认几行字；`--json` 的字段：

- `project`：`path`、`slug`、`title`（BRIEF 第一行）、`type`（类型文档，如 `02-knowledge-short`）、`effort` 和 `effort_from`（BRIEF、LOCAL.md 或默认）、`director`（BRIEF 的 Director 一行）、`lang`（审阅语言）、`spec`（BRIEF 的 Spec 各行，原样的键）。
- `stations`：按流程顺序的各站。关卡 ①②③ 总在；检查点 E0–E5 有页面、REVIEW.md 有它的一节或 Director 写了 `stop=E3` 时才在；别的名字的审阅页（`final`）自成一站；最后是交付。每站：`id`、`name`、`kind`（gate、checkpoint、page、deliver）、`state`、`pages`（这一站的页名）、`page`（最新一页的路径）、`current`（是不是这一轮）、`record`（`decided`、`said`、`waived`、`from`：从哪读出来的，`gate1`（关卡 ① 按 gatecheck 的规则）、`page`（写了这一页的节）、`stop`（这一站的节，还没有页）、`stop_by_date`（这一站的节没写页面，按日期算它是关于这一页的）、`stop_older`（这一站的节有定了，但没写页面、又早于这一页，不算）；关卡 ① 另有 `concept_on_record`）、`feedback`（这一页之后的提交：`submitted`、`handed`、`pending`、`last`）、`note`（一句为什么）。
- `state` 七种：`done`（REVIEW.md 里有它的"定了"：先看关于最新那一页的最后一节，审阅台为提交写的那节、或写了 `gate-<n>.html` 的那节，模板的三节都预先写了；没有这种节，就看这一站自己的节，而且 REVIEW.md 要晚于这一页，`note` 里会说是按日期算的。关卡 ① 和 `bin/vh render`、`check` 用同一条规则（`tools/gatecheck.py`）：关卡 ① 的节里有定了和人的原话，DECISIONS.md 里立意定了）、`skipped`（quick 档、或用户原话授权跳过）、`waiting_person`（这一页是这一轮，还没有回音）、`waiting_agent`（人提交了还没交给 agent，或者交了但 REVIEW.md 还没写定了；或者这一轮已经往后走、这一页没有记录；或者关卡 ① 定了，但缺人的原话或 DECISIONS.md 的立意，render 和 check 会拒绝）、`in_progress`（前面都过了，agent 正朝这一站做）、`not_started`、`no_record`（standard、studio 的项目没有 REVIEW.md，模板有它之前做的：无从读起，gatecheck 也不查）。交付：`bin/vh deliver` 写过记录，或成片（`out/final*`、`out/final/`、`media/`）有一份通过的检查记录、而且就是这支成片的（记录里的 `size` 和 `mtime_ns` 和它现在的一样；没有这两个字段的老记录，要比它晚），而且关卡 ③ 过了（`done` 或 `skipped`），就是 `done`；关卡 ③ 还没过时 `note` 会说；各站都过了是 `in_progress`；没有 REVIEW.md 是 `no_record`。
- `waiting_on`：`person`、`agent`、`nobody`（交付了）或 `unknown`（没有 REVIEW.md，又没有命令在跑）；REVIEW.md 写了暂停（`paused: true`）也是 `person`。机器写的记录（检查记录、`.render.json`、`.deliver.json`、审阅台的提交）里类型不对的字段当作没有。`next`：一句话，谁下一步做什么。
- `review`：`current`（这一轮的页名）、`page`、`desk`（在跑时：`url`、`listening`）。
- `open`：`review_items`（审阅台提交里标了要改、疑问，而 REVIEW.md 那一节还没写定了 / 改了的条目：`round`、`file`、`target`、`status`、`label`、`text`）、`facts_to_verify`（NOTES.md 待核实里没打勾的）。
- `renders`：`out/`（往下三层，不含 `out/versions/` 和 `out/proxy/`）、`renders/`、`media/` 里的视频，新的在前，最多 10 个：`path`、`size`、`mtime`、`render`（`.render.json` 的帧数、帧率、像素、时间段）、`patches`、`delivery`（它是 `bin/vh deliver` 出的上传版时）、`check`（它最近的检查记录）、`version`（它是哪一版的当前文件，见下面"版本"）。`deliveries`：`bin/vh deliver` 的记录。
- `versions`：版本记录（下面"版本"）的摘要，还没有记录时是 `null`：`record`、`keep`、`current`、`kept_bytes`、`list`（每版 `id`、`at`、`t`、`film`、`file`、`state`、`made_by`、`from`、`note`、`changed`、`frames`、`pixels`、`check`）；记录读不了时是 `{"error"}`。
- `check`：最近一次 `bin/vh check` 的记录摘要：`record`、`video`、`at`、`verdict`、`exit`、`counts`、`fails`（前三条）、`stale`（视频不是检查时的那一支了：检查记录里的 `size` 或 `mtime_ns` 和视频现在的不同；没有这两个字段的老记录，看视频的修改时间是不是比记录晚，见"检查记录"）。
- `activity`：`running`（正在跑的命令）、`listening`（在跑的审阅台、`gate --wait`：是在等人，不是在干活）、`recent`（最近结束的五条），每条是下面活动记录里的一个 run。
- `assets`：素材台账的摘要（`tools/assets/uses.py` 的 `overview`，下面"素材台账"）：`ledger`（有台账时是 `assets/ledger.json`，否则 `null`）、`records`（没删的记录条数）、`removed`、`uncleared`（许可有风险的：NC、ND、BY-SA、未知）、`not_taken`（其中这一档许可策略不收的）、`aigc`、`unregistered`（成片的页面载了、台账没有的素材个数；还没有一支成片记下载了哪些文件时是 `null`）、`films_known`（记下了的成片数）、`policy`、`policy_from`、`budget`（和 `bin/vh assets list --json` 的 `budget` 同一个形状，见下面"素材台账"）、`error`（台账或 Budget 一行读不了时）。不算哈希，很快。
- `cast`：项目 `cast/` 里的定稿参考（`tools/cast.py` 的 `overview`，`bin/vh cast`），没有这个文件夹时是 `null`：`entries`（条数）、`by_kind`（`character`、`costume`、`prop`、`set` 各几条）、`final`（定稿的条数）、`failures`（`bin/vh cast check` 会报的失败数，例如参考图在记录之后改过）；读不了时是 `{"error"}`。只读文件，算参考图的哈希。
- `research`：项目 `research/` 里的调研（`tools/scout/scout.py` 的 `overview`），没有这个文件夹时是 `null`：`scout`（`bin/vh scout` 的记录：`file`、`records` 行数、`latest` 看过的视频和帖子数、`films` 其中当作自己的片子记的、`last` 最后一条的 `fetched_at`）、`hot`（`days` 有热榜快照的天数、`first`、`last`）、`refs`（`bin/vh ref` 的参考：`file`、`records`、`error`）；读不了时是 `{"error"}`。只读文件，不联网。

### 活动记录：`bin/vh activity <项目> [--json] [--follow] [--limit N]`

每条作用在项目上的 `bin/vh` 命令往 `<项目>/.ovh/activity.jsonl` 追加 JSON 行；只读的 `status`、`activity`、`desk data`、`doctor` 不记，找不到项目的命令也不记。项目从参数里找：第一个是文件夹或文件（含 `--out=f`、`voice=f` 这种）的参数，往上最近的带 BRIEF.md 的文件夹；`review`、`gate`、`desk` 这些也认 projects/ 下的项目名。每行都有 `v`（1）、`event`、`t`（epoch 秒），属于某条命令的还有 `run`：

| event | 字段 | 谁写 |
|---|---|---|
| `start` | `cmd`、`args`（照打的写，但不写秘密：名字（`=` 前那段）里带 key、token、secret、pass、auth、cred、cookie、header、bearer 的选项和 `名字=值` 的值，大写的 `NAME=值`、单字母选项后面的值，URL 里的 `用户:密码@`、查询参数的值和 `#` 后面，Bearer token，名字像秘密的 header，像 key 的参数，都写成 `…`；最多 24 个）、`cwd`、`pid`、`parent`（由另一条 `bin/vh` 起的） | `bin/vh` |
| `progress` | `done`、`total`、`unit`（`render`：frames，开头、每 15 s、结尾各一行） | 工具 |
| `note` | `summary`（一行）、`outputs`（写了哪些文件，项目里的写相对路径） | 工具：render、patch、review、gate、mix、qa、tts、check、`desk wait`、`versions compare`、`versions use` |
| `end` | `exit`（退出码；Ctrl-C 是 130，写完 `bin/vh` 再用 SIGINT 结束自己，调用它的 shell 才知道是 Ctrl-C；自己处理信号 n 的工具（desk、`desk wait`、`gate --wait`）停下时是 128 + n；被 TERM、HUP 直接杀掉的命令当场结束，没有这一行，读出来是 `gone`）、`duration`（秒；没有 `EPOCHREALTIME` 的 bash，比如 macOS 自带的 3.2，只到整秒） | `bin/vh` 的 EXIT trap；`bin/vh` exec 进去的工具（render、patch、frames 这些页面工具，desk、gate）自己写 |
| `feedback` | `round`、`file`、`items`（按状态计数）、`decisions` | 审阅台存下一份提交时；不属于哪条命令 |

`bin/vh` 把这条命令交给它起的进程：环境变量 `OVH_ACTIVITY_LOG`、`_RUN`、`_PID`、`_T0`、`_CMD`。不写进去的：环境变量、key、文件内容。每行一次 O_APPEND 的 write，几条命令同时写也不会把行写乱：`bin/vh` 写的不超过 1 KiB（bash 的 printf 会把更长的一行拆成 1024 字节一段段写），Python、Node 写的不超过 4 KiB；写不进去（磁盘满、项目只读）就丢掉这一行，命令照常跑完、不多说一句。

`--json` 是 `{"version", "project", "log", "runs", "events"}`。`runs` 里每条命令一项：`run`、`cmd`、`args`、`cwd`、`pid`、`parent`、`start`、`end`、`exit`、`duration`、`summary`、`outputs`、`progress`、`state`。`state` 是 `running`（没有结束行，进程还在，开始不到 7 天）、`ok`（退出码 0）、`failed`、`gone`（没有结束行，进程也没了：被杀掉，或者机器重启过）。`events` 是不属于命令的行（`feedback`）。`--follow` 先打印最近的，再一行一行跟着打印新的；加 `--json` 是一行一个 JSON。读的时候，读不了的行跳过，类型不对的字段丢掉（`outputs` 不是列表、`summary` 不是字符串……），一行坏了不会让 `activity`、`status` 或客户端停下来。只读日志最后 4 MB。

### 版本：`bin/vh versions <项目> [--json]`

项目里的视频每经 `bin/vh render`、`bin/vh patch` 出一次，就是这支片子的一版（`tools/versions.py`），记在 `<项目>/out/versions/versions.json`。项目外的视频不记；`OVH_VERSIONS=off` 也不记，这时 render 照旧直接盖掉原来的文件。

- **旧的片子怎么留**：render 或 `patch --in-place` 要盖掉的那支片子，先整个挪进 `out/versions/<id>/`（连同 `.render.json` 和它的检查记录；只是改名，不复制，不花时间）。路径上原有的文件不是这两条命令出的（`mux` 出的、手放的、有记录之前渲的），先记成一版 `found` 再留。`out/versions/` 里的东西从不被覆盖（编号也跳过那里已有的文件夹），记录跟着字节走：片子一挪就记它的新位置。路径上是一个链接时，换掉的是链接本身，它指向的文件不动（和有版本之前一样，`OVH_VERSIONS=off` 也是）。输出落在 `out/versions/` 里的 render 和 patch 在画之前就拒绝（退出码 2）。`patch --in-place` 只在路径上还是它切开的那支片子时（大小和修改时间）才放进去；中途被换过就不动它，新片放在旁边，退出码 1。新片放不进去时放在旁边一个没人用的名字（`<stem>.new.mp4`、`.new-2.mp4`……）。
- **默认按磁盘留**：挪走之后磁盘还剩它两倍大小、并且至少 5 GB，才留在项目里；每支片子最多留 `OVH_KEEP_VERSIONS`（默认 3）个旧版，多出来的最旧那个、或者磁盘留不下的，移到废纸篓（`<项目名> v2` 这样一个文件夹），在命令的输出、活动记录和这份记录里都写明；从不直接删。`bin/vh clean` 按它的规矩修剪旧版（先列出，`--yes` 才移到废纸篓，`--keep-versions N` 每支片子留最新的 N 个）。
- **`versions.json`**（`"version": 1`）：`next`（下一个编号）、`versions`、`events`（`use` 的记录：`t`、`at`、`event`、`id`、`film`、`displaced`）。每版：`id`（`v1`、`v2`……不复用）、`n`、`t`、`at`、`film`（出片时的路径，`use` 放回这里）、`file`（现在字节在哪：当前就是 `film`，留着的在 `out/versions/<id>/`，进了废纸篓是 `null`）、`sidecar`、`made_by`（`render`、`patch`、`found`）、`from`（render：它替掉的那一版；patch：它从哪一版改来）、`note`（`--note`）、`changed`、`size`、`mtime`、`frames`、`fps`、`pixels`、`span`、`edit`（剪辑表的片子：`path`、`sha256`、`resolved`，它从哪份剪辑表渲来）、`check`（留下时一起存的检查记录）、`problems`（render 报了问题的帧数，有才写）、`gone`（`at`、`why`：为什么不在了）。
- **`changed`**：render 是 `{"whole": true}`（剪辑表的片子另有 `entries`：画了哪些段）；patch 是 `{"whole": false, "frames": [[a, b]…], "seconds": [[s, e]…], "drawn": [[A, B]…], "shots": [...], "asked": {"shots", "chapters"}}`：点名的帧（含两端）、对应的秒、为了对上关键帧实际重画的帧、这些帧跨过的镜头（项目有 `shots.json` 用它，否则用页面的 `window.film.shots`），`asked` 是 `--shot`、`--chapter` 原样点的名；剪辑表的片子另有 `entries`：重画的窗口碰到的段。
- **`--json`** 输出 `{"version": 1, "project", "record", "keep", "current": {片子路径: id}, "kept_bytes", "versions", "events"}`；每版另算 `state`：`current`（它的路径上就是这些字节）、`kept`（在 `out/versions/` 里）、`trashed`、`gone`（不在记录说的地方了）、`changed`（它的路径上现在是别的字节：在 render 和 patch 之外被换掉了），按文件大小和修改时间判断；`check` 是它的检查记录摘要（当前版取 `out/check/` 里属于它的那份：记录里的 `size` 和 `mtime_ns` 和它现在的一样，没有这两个字段的老记录看是不是比它新；留着的版本，记录若带着这两个字段而和它们不一样就不给）：`verdict`、`at`、`counts`、`record`。读不了的记录：退出码 2；render 和 patch 遇到它会把它改名成 `versions.json.bad-<时间>` 留着，另起一份，不因此失败。

`bin/vh versions compare <项目> <vA> <vB> --t <秒> [--wipe [0.5]] [--out f.png] [--json]`：两版在 `--t` 秒显示的那一帧（第 floor(t·fps) 帧），并排（vA 在左）或擦除对比（线左 vA、线右 vB，默认在一半处），每边最宽 1920 px；默认写到 `out/check/versions/<vA>-<vB>-t<秒>.png`。PSNR（dB，RGB；尺寸不同时把 vB 缩到 vA 的大小）是从两支编码后的片子解出来的帧算的，两边都带着 x264 的损失，所以它说的是两支片子在那一刻差多远，不是两版页面画得差多远。`--json`：`{"version", "project", "t", "a": {"id", "file", "frame", "fps"}, "b", "psnr"（数，或 `"inf"`）, "layout", "wipe", "image", "from": "the encoded films"}`。

`bin/vh versions use <项目> <vN>`：让 vN 重新成为它路径上的当前片子。路径上现在的那支先挪进 `out/versions/` 留着（这里从不进废纸篓，也不按数量修剪），它在 `out/check/` 的检查记录跟着挪走；vN 的文件、`.render.json` 和它自己的检查记录放回原处。所以换完以后，这个路径的检查记录要么是 vN 自己的，要么没有，不会把别的片子的结论算在 vN 头上。render 或原地 patch 正在写这支片子时（它们的锁）拒绝。什么都不删。退出码：0；1 这一版不在项目里（进了废纸篓或不见了）、ffmpeg 失败；2 用法错、没有这个项目、记录读不了。`compare` 和 `use` 记进活动记录，列表不记。

### 拖动用的代理和缩略图：`bin/vh proxy`、`bin/vh thumbs`

都只用 ffmpeg（`tools/proxy.py`），参数给一支片子或一个项目；项目指它的片子：最新的当前版（`bin/vh versions`），否则 `out/` 里最新的、旁边有 `.render.json` 的视频，否则 `out/` 里最新的视频（不看 `out/check`、`out/review`、`out/proxy`、`out/versions`）。输出在 `<项目>/out/proxy/`（项目外的片子：它旁边的 `proxy/`），文件名照检查记录的起法（`out/review/sketch.mp4` 是 `review-sketch`）。`bin/vh clean` 把 `out/proxy/` 当作工具能重做的东西。退出码：0 做好了或本来就是新的；1 ffmpeg 或页面失败；2 用法错、`proxy` 没有片子、`thumbs` 既没片子也没页面。

`bin/vh proxy <片子|项目> [--size 360] [--gop N] [--crf 28] [--full] [--out 目录] [--json]`：`<名字>.mp4`，短边 `--size` 像素（不放大），H.264，每 `--gop` 帧一个关键帧（默认五分之一秒，30 fps 是 6），没有 B 帧，按快速解码调过，带片子的声音（AAC）：任意一处拖过去，最多解 `--gop` 帧。旁边的 `<名字>.mp4.json`（`"version": 1`）：`source`、`source_ident`（片子的 `size`、`mtime`）、`source_version`、`proxy`、`settings`（`size`、`gop`、`crf`）、`fps`、`frames`、`duration`、`audio`、`made`（`full`、`refreshed`）、`windows`（refreshed 时重编的帧段）、`t`、`at`、`seconds`。再跑一次：片子没变就什么都不做（`up to date`）；片子在那之后只经过原地 patch（版本记录里从代理那一版到现在每一步都是这支片子的 `patch --in-place`），就只把重画的帧所在的代理关键帧段从新片子重编、接进去，其余照拷，声音照旧；别的情况（重新 render、换了参数、`--full`）整支重做。接进去的几段和整支重做的同一段可能差一点点（x264 的码率控制会看段外的帧），在测试片上最差的一帧约 65 dB。`--json` 打印这份记录，另加 `state`。

`bin/vh thumbs <片子|项目> [--every 2] [--width 160] [--shot-width 320] [--full] [--out 目录] [--json]`：`<名字>.thumbs/` 里每 `--every` 秒一格（`--width` 宽），每 10×10 格拼一张 `sheet-01.jpg`……；每个镜头一张 `shots/<id>.jpg`（`--shot-width` 宽），取它的 `at`，没有就取镜头 60% 处，和 `bin/vh storyboard` 一样；`thumbs.json` 是对照表。镜头表：项目的 `shots.json`；没有的话，给的是片子就用它 `.render.json` 里记的（渲的时候页面的 `window.film.shots`；对片子不开浏览器，sidecar 里没有镜头就不出镜头图），还没有片子就读页面的。帧从同一支片子做的代理里取（快），没有就从片子取，没有片子就画页面（`bin/vh frames`，要 Chrome）。片子只经过原地 patch 时，只重取落在重画帧里的格子和镜头。`thumbs.json`（`"version": 1`）：`source`、`from`（`proxy`、`film`、`page`）、`source_ident`、`source_version`、`fps`、`duration`、`frames`、`settings`、`tile`（`[宽, 高]`）、`shot`（镜头图的 `[宽, 高]`）、`sheets`（每张 `file`、`tiles`、`size`）、`tiles`（每格 `i`、`t`、`frame`、`sheet`、`x`、`y`：在那张拼图里的左上角）、`shots`（每镜 `id`、`t`、`frame`、`start`、`end`、`file`）、`shots_from`、`made`（`full`、`refreshed`）、`taken`（这次取了几格、几个镜头）、`t`、`at`、`seconds`。时间都是片子的秒（从 `--range` 渲的片子，镜头时间已经减去它的起点）。

### 检查记录：`bin/vh check <视频> --json`

`bin/vh check` 每跑一次，都把结果存成视频所在项目的 `out/check/<名字>.check.json`（名字是文件名去掉扩展名，前面加上 `out/` 之后的文件夹：`out/review/sketch.mp4` 是 `review-sketch`；项目外的视频不存），`bin/vh clean` 留着它。`--json` 把同一份打到标准输出，给人看的那些行改去标准错误；检查本身、退出码和不加 `--json` 时一样（`tools/checkrec.py`）。

顶层：`version`、`tool`、`video`（项目里的写相对路径）、`project`、`record`、`t`、`at`、`size` 和 `mtime_ns`（检查开始时视频文件的字节数和修改时间，纳秒，都是整数，取自 `os.stat`，不算哈希；读不了视频时是 `null`）、`args`（`allow`、`against`）、`exit`、`verdict`（`pass` / `fail`，和退出码一致）、`counts`（`fail`、`warn`、`info` 各几条）、`probe`（时长、大小、各条流）、`motion`（动着的帧对占比、静止占比、硬切数）、`findings`、`skipped`（没跑成的检查和原因）。读不了视频时只有 `error`。建不了临时文件夹（`mktemp -d` 失败，比如 `TMPDIR` 指向不存在的地方）时，检查照跑，输出和退出码不变，多一行提示，不存记录；`--json` 只打 `verdict`、`exit` 和 `error`。

`size` 和 `mtime_ns` 是用来认片子的：`bin/vh status`（`check.stale`、各个 render 的 `check.stale`、交付那一站）和 `bin/vh versions`（每一版的 `check`）拿它们和视频现在的大小、`mtime_ns` 比，有一个不同，这份记录就不是这支片子的了（`stale` 为真，或这一版没有 `check`）。只看记录的时间认不出被换回来的旧片子：`cp -p`、`rsync -a`、`bin/vh versions use` 会把旧的修改时间一起放回去，视频看上去比记录还早；检查跑到一半被换上的片子也一样（记录存的是检查开始时的那一支）。没有这两个字段的老记录照旧：视频的修改时间比记录晚就算改过（`versions` 留 1 s 的宽限）。`mtime_ns` 超过 2^53，JavaScript 的 `JSON.parse` 读成数会丢低位：客户端要自己比就用 BigInt，一般直接看 `stale`。

每条 finding：`kind`、`severity`（`fail` 让退出码是 1，`warn` 要看一眼，`info` 只是说一声）、`message`、`t` 和 `t1`（秒，有时间或时间段的才有）、`frame` 和 `frames`（`[第一帧, 最后一帧]`）、`evidence`（判断依据：量到的数、BRIEF 那一行、画面的 key、确认它的那一条……）、`confirmed`（confirmed.json 盖住了是 true，能确认但没确认是 false，这一类从来不在那里确认就是 null）。没确认的孤立帧还带 `confirm`：填上 why 和 evidence 就能贴进 confirmed.json 的那一条。`kind` 用 confirmed.json 的名字：`check.spec`、`check.gate`、`check.black`、`check.freeze`、`check.silence`、`check.iso`（孤立帧；`declared: true` 是这次 `--allow` 声明的，`lapsed: true` 是确认失效了）、`check.periodic`、`check.static`、`check.cut`（从暗到亮的硬切）、`check.blind`（动得太多、扫描判断不了的一段）、`check.subtitles`、`check.colour`、`check.packaging`、`check.scale`、`check.confirmed`（confirmed.json 里没用上、失效或没收下的条目）。

### 素材台账：`bin/vh assets <项目> [--json]`

一个项目用到的素材，一个文件（或一个文件夹，比如从片段烘出来的一组帧）一条记录，记在 `<项目>/assets/ledger.json`（`tools/assets/`，只用标准库）。记录的格式是 `tools/assets/asset.schema.json` 的 v1；仓库外的声音库、跨片的外观账本以后也是这种记录，只是放在别处（库是 `ledger.jsonl`，一行一条）。

- **一条记录**（`"v": 1`）：`id`（不复用）、`kind`（`image`、`video`、`audio`、`font`、`model`、`data`、`other`）、`path`（相对项目；文件夹以 `/` 结尾）、`sha256`（文件夹是它的清单的 sha256：每个文件一行"相对路径\tsha256\n"，按路径排）、`bytes`、`license`（`class`、`name`、`url`、`by`：分类器认的还是登记时给的）、`source`（`origin`：`download`、`generated`、`self`、`user`、`library`、`purchased`；`url`、`file_url`、`provider`、`provider_id`、`title`、`author`、`retrieved`、`range`）、`attribution`、`aigc`、`model`、`prompt`、`prompt_file`、`seed`、`cost`（`amount`、`currency`）、`added_at`、`updated_at`、`used_by`、`tags`、`derived_from`、`note`、`removed`（`at`、`why`）。没命名的字段原样留着（厂商条款、请求号、输入素材）。
- **`license.class`** 十三类（`tools/assets/licenses.py`）：`pd`、`cc0`、`cc-by`、`cc-by-sa`、`cc-by-nc`、`cc-by-nc-sa`、`cc-by-nd`、`cc-by-nc-nd`、`free`、`managed`、`own`、`generated`、`unknown`。认不出的一律 `unknown`。风险标签 `nc`、`nd`、`sa`、`unknown`；`Assets: strict` 收 `pd`、`cc0`、`cc-by`、`free`、`managed`、`own`、`generated`。
- **`ledger.json`**：`{"v": 1, "note", "assets", "events"}`；`events` 每条 `t`、`at`、`event`（`add`、`update`、`remove`）、`id`、`sha256`、`by`、`why`。记录从不删：`remove` 只是标上 `removed`。整份在 `assets/.ledger.lock` 的 flock 下先写临时文件再 `os.replace`，和 `versions.json` 一样。项目里以前每个生成片段一份的 `assets/genclips/<id>/ledger.json`（没有 `v`）照读成记录，台账里有同 id 或同路径的就以台账为准（`references/genvideo-ledger.md` 有字段对照）。
- **`assets/spend.jsonl`**：花钱的记录，一行一条，在 `assets/.spend.lock` 的 flock 下追加写（一次 O_APPEND）：`v`、`kind`、`t`、`at`、`amount`、`currency`、`what`、`tool`、`asset`、`estimate`、`run`。`kind` 三种：`payment`（花掉的钱，没有 `kind` 的老行也算）、`hold`（调用前预占的估价，另有 `id`，结算前算作已花）、`settle`（那次调用实际花了多少，另有 `hold`；没计费是 0）。预算读 BRIEF 的 `Budget:`，没有就读 LOCAL.md 的"默认预算"；按货币分别累计，不换算（`tools/assets/budget.py`）。
- **`list --json`**：`{"version": 1, "tool", "project", "ledger", "policy": {"assets", "from"}, "budget", "counts": {"assets", "removed", "uncleared", "aigc", "missing"}, "assets", "said"}`。`assets` 每项：`record`（原样），加上现在看到的 `from`（哪份台账）、`exists`、`class`、`risks`、`accepted`（这一档许可策略收不收）、`attribution`（`required`、`agreement`、`courtesy` 或 `null`）、`removed`、`problems`（对 schema 不合的地方）。`budget`：`limit`（上限，按货币）、`unlimited`（`不限`）、`from`、`raw`、`error`、`spent`、`held`（预占还没结算的）、`left`（都按货币）、`over`（超了的货币）；`bin/vh status --json` 的 `assets.budget` 是同一个形状。不算哈希，很快。
- **`check --json`**：`{"version": 1, "tool", "project", "ledger", "policy", "exit", "verdict", "counts": {"fail", "warn", "info"}, "records", "findings", "said", "uses"}`；每条 finding：`kind`、`severity`、`id`、`path`、`message`。台账自己的：`record`（对 schema 不合）、`missing`、`sha256`（另有 `sha256_now`）、`prompt_file`、`license`（另有 `class`、`risks`）、`credit`（要署名却没记作者）、`derived`（`derived_from` 指向不存在的记录，或者从别的素材做出来却登记了更宽的许可）。和成片两头比的（`tools/assets/uses.py`）：`unregistered`（页面载了、台账没有的素材，失败）、`stale`（成片载的这个文件和台账的字节不一样）、`unused`（没有成片载、没有混音用、也没写 `used_by` 的记录；至少有一支成片记下了文件时才报）、`mix`（混音用了、台账没有的声音文件，`info`，另有 `paths`）。`uses`：`films`（每支 `film`、`sidecar`、`page`、`files` 个数）、`older`、`unknown`（记下文件之前渲的成片）、`mixes`。要读每个文件算哈希，大项目要几秒。
- **成片用了什么**：`bin/vh render` 把浏览器加载过的、页面文件夹里的每个文件和它的 sha256 写进 `<成片>.render.json` 的 `files`（从页面所在的文件夹算的相对路径；宿主自己的脚本只记在续渲用的 `plan.json` 里）；`bin/vh patch` 把新画的帧载的文件并进去，成片原来没有这张表就不写（几帧的表不是整支片子的）。一个页面出过几支成片时只比最新的一支（按 `versions.json` 里当前那一版的时间，没有就按文件时间，整支的排在只渲一段的前面），`check --film <片子>` 只比那一支，`--all-films` 全比；`uses` 另有 `older`（没比的旧片子）。混音用的文件来自 `<混音>.mix.json` 的 `inputs`。不改页面合约（`engines/CONTRACT.md`）。
- **`credits --json`**：`{"version": 1, "tool", "project", "film", "lang", "left_out", "required", "courtesy", "aigc": {"count", "kinds", "models", "public", "declare", "notice"}, "missing", "text"}`；`required`、`courtesy` 每项 `id`、`ids`（合进这一行的所有记录）、`line`、`merged`（被合掉的不同写法）。`text` 是可以直接贴的文字，AI 那一段只有 `public`；`declare` 是给发布人的话，`notice` 是两句连起来（原有字段）。`--film` 给了时，`left_out` 是没列进去的记录。

## 安全

- 只绑定 127.0.0.1，只回答 Host 是自己的请求（挡住 DNS rebinding）。
- 提交要带页面里那一次启动生成的令牌、JSON 格式，浏览器带了 Origin 时必须是同源；所以同一个浏览器里别的网页既读不到项目，也没法冒充人提交反馈。
- `/p/` 下的每个文件都带 `Content-Security-Policy: sandbox allow-scripts allow-popups`（没有 `allow-same-origin`）：项目里的 HTML、SVG（HyperFrames 的 `index.html`、`node_modules` 里的页面、下载来的参考图）在浏览器里打开时是一个不透明的源，脚本照样能跑，但读不到审阅台的页面和令牌，也没法替人提交。
- `/p/` 只给项目目录里的普通文件：不出目录、不跟着符号链接出去；隐藏文件和 `*.env` 不给，按请求的名字和解析后的真实文件各查一遍，不分大小写（指向 `.env` 的链接、`keys.ENV` 都不给）。
- 每个连接 30 s 不动就断开，发了一半的请求不会一直占着线程。

## 限制

- 开着的旧页面不会自己换轮：agent 出了新的一页，人在之前打开、没刷新的标签页里提交，反馈记在旧的那一轮（那一页的 gate JSON 还在，服务照收）。页面右上角的 ↻ 重新读取。
- 几个 `bin/vh desk` 进程同时动手（比如两个 `bin/vh desk wait` 一起启动，或者一边 `wait` 一边 `desk feedback`），最坏是同一份反馈交出去两次：它们各自先看到这份反馈还没交过，各打印一遍。不会崩，也不会丢反馈：每次写文件都用自己的临时文件再原子替换，`.consumed` 的读改写在 `.consumed.lock` 上加了文件锁（flock），谁都不会把别人记下的名字冲掉。

## 测试

`tools/ci.sh` 用 `tools/desk/fixtures/` 里的两个小项目（中文、英文）测读取（包括读不出表格时退回原文、"这一轮"取 `.current`（2 之后的 1b、3 之后的 E3b、自起的页名，`.current` 指向已删的页时退回流程顺序）、语言规则、超长和深层嵌套的 markdown），在空闲端口起一个服务测 `/api/data`、206 Range、`/p/` 的 sandbox、各种拒绝和坏请求、提交到临时副本、REVIEW.md 的追加，测 `wait` 在有提交时退出 0、启动前就到的提交立刻交出、交过的不再交，拷来的 `.desk.json` 和 `.listening` 不算数，以及 `bin/vh desk -h`。
