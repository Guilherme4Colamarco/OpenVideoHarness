# 02 验证闭环

读代码看不出运动的效果，必须渲染出来看。下面按成本从低到高排列各层检查。调研的结论是：第 1–3 层，再加上一个按 rubric 打分的 reviewer，是真正起作用的部分；第 6 层（Gemini 看整片）只能算补充。

## 七层检查

做到第几层，按努力程度定（CLAUDE.md"努力程度"）：
- `quick`：第 1、2 层，加上整片一张联系表、一张按目标屏缩的联系表和前 2 s 的逐帧 strip（命令见下文"手机测试"），出片前跑 `bin/vh check`；
- `standard`：七层都做，第 5 层的独立评审做 1 轮；
- `studio`：七层都做，第 5 层至少 3 轮、最多 10 轮，外加下文的循环接缝、无损确定性和音频 QA（手机测试每一档都做）。

1. **能不能跑**：lint、编译、dry-run。Manim 的报错按 ScopeRefine 的顺序修：先改出错行前后 ±1 行，不行就改整个代码块，再不行就重写整个场景。
2. **不看图的结构检查**（确定性检验：从中间抽几帧单独渲染，和整片里的同一帧比对，要逐像素相同，或者 PSNR ≥ 45 dB；比的是无损 PNG 帧，不是编码后的 mp4，原因见下文"确定性"；`ffmpeg -i a.png -i b.png -lavfi psnr -f null -`）：
   - 渲染器自带的检查，例如 HyperFrames `check` 会查 DOM 包围盒、文字溢出和对比度；
   - canvas 里画的字，`check` 看不到：canvas 片子跑 `bin/vh textcheck <项目>`，合成里要有一行页面合约 `window.film`（`engines/CONTRACT.md`；原来的 `window.__vh` 也认）。它把同一帧画两遍，一遍照常、一遍单独去掉这条字，再把这条字单独画一遍当掩膜：字自己的像素里，两遍不同的（或者正是字自己颜色的）占多少，就是露出来多少，不到七成算被盖住；字和底下画面的对比、和紧挨着它一圈（描边、阴影、底板都算）的对比，两个都低于 3:1 算看不清；出画、被边缘裁掉、压在 DOM 字幕下也算。没登记的 canvas 字和字幕底下的画面亮度另外扫一遍，只警告；页面给了常驻界面的框（`window.film.ui`）时，再把场景单独画一遍，看它有没有画到进度条、字幕底下（只警告）。一支七八分钟的片子这样扫了全部一百来条画面文字，找出几条对比度不够的，翻帧时都没看出来；
   - 缺字：字体里没有的字不会报错，浏览器换一个字体画它，没有任何字体有它时画成空的"缺字"字形（苹方的是空白，什么也看不见）。`bin/vh fonts check <项目>` 按时间抽帧，记下 canvas 和 DOM 里每段字用的字体，再问浏览器每个字实际是哪个字体画的，换了字体的、哪个字体都没有的都报出来（退出码 1）；`bin/vh render` 出片时也顺带说一声。HyperFrames、canvas-film、手绘引擎的字都看得到；
   - 打印所有对象的包围盒，检查有没有重叠（SGA 的做法）；
   - 用像素统计找空白帧和卡住的帧：逐帧 YAVG 找突降，逐帧和第 0 帧比 PSNR，见下文"静默失败"；
   - 黑场、冻结、静音检测（命令见下文），孤立帧扫描（`bin/vh check` 一并做，见下文"静默失败"）；
   - `bin/vh check` 拿成片对 BRIEF 的 Output 和 Resolution：尺寸、帧率、时长，对不上就失败；`ffprobe` 再看音轨和色彩标签（命令见下文"色彩标签"）；
   - 软字幕轨（观众能关）短于读时只提醒；烧进画面的照读时底线；
   - 出 4K 时，`bin/vh check <4K 视频> --against <1080p 成片>`：同一支片子在 2 倍像素密度下画面有没有变（`engines/README.md`"出 4K"）；再把最亮、最像镜面的东西按 1:1 裁出来看一眼，反射会把距离场或法线里的小台阶放大成一排细纹，1080p 的联系表看不出来；
   - 检查输出文件的修改时间，防止把旧文件当成新结果。
3. **看静帧**（用 Read 工具读图），分三种粒度：
   - **联系表**：看构图和整片的形状，每个镜头取首、中、末三帧。
   - **strip**：看时序。按固定步长 0.1–0.15 秒出一串帧，从头到尾像观众那样读，数一数每个 read 分到几帧（24 帧 = 1 秒）。
   - **crop**：局部放大，看脸、手、接触点、发光区域。
   - 另外，每个转场前后各 0.5 秒都要单独看；整片再按目标屏的尺寸看一遍（BRIEF 的 `Watch on`）；循环播放的交付物还要看末帧接首帧（两条命令见下文"手机测试与循环接缝"）。
   - 同一位置换字、会滚动的读数，各看一条 strip：换字时旧句退完、新句才进（#17；一支 2026-10 的片子作者自查漏了三处，是 reviewer 看出来的）；读数每次停下的数都和 NOTES 里的出处对一遍，停在插值算出来的数上算编造（#19）。
4. **VLM 批评要给离散选项**：让模型从锚点网格里选位置（Code2Video 的做法），或者从几个渲染出来的变体里挑一个（Paper2Video 的做法）。不要让它输出"往左移 12px"这种数值微调。每轮最多列 3 个问题，每个问题都附一条可以直接执行的修改。关卡 ② 没把握的关键帧，可以先做一张目标图，渲出来后由 critic 并排比（`playbook/target-critic.md`）。
5. **reviewer subagent**：开一个全新上下文（`standard` 默认用便宜一档的模型，`studio` 可以用最强档；用户指定了就照它），同一轮先复述、后对照打分；不合格的退回给写代码的 agent。
   - **人设**：严苛的导演，不是为作品自豪的作者。提示词的大意是："这支片子不是你做的。你是一位挑剔的导演，任务是找出它为什么还不能发。"作者自己看久了会习以为常，换一个没有感情投入的人才看得出。
   - **先给画面证据**：联系表、目标屏联系表、关键动作和转场的 strip、开头 2 s 的逐帧 strip（慢开场再加开头 10 s 的联系表）、实际字卡及起止时间；有旁白时附实际转写和时间戳（灰盒的临时旁白要标明，尚未实现的内容记“待验证”）。先不给分镜的目标答案或作者解释，让 reviewer 用 2–3 句复述主线和核心段的含义，缺失或不明的就写出来，标镜头 / 时刻。它依据实际帧和时序检查，不能声称直接看过视频、听过音频或做过真人理解测试。
   - **收到复述后再给约束**：`TASTE_CHECKLIST.md`、`STORYBOARD.md`、cue check 结果；BRIEF 的立意、`Pace`、`Watch on`、`Platform / audience`，STYLE 的 Motion tokens、REVIEW 中人已定的事、DECISIONS 里记下的决定、NOTES 评审记录里"不采纳"的几行，以及 NOTES 的事实出处和已交给人的"已知局限"（不再重复列）。不给 NOTES 自评。对照目标与复述的差异，理解问题归入现有的立意、可读等维度，不加评分项；#5 仍只在不够快读一遍时 FAIL，低于 Pace 目标是建议。
   - **发布文案**：PACKAGING.md 的"发布文案"写好了，就一起交给 reviewer：里面的事实（人名、年份、数字、引文、和片子对得上的说法）逐条对 SCRIPT.md 和 NOTES.md，长度超了平台上限的 `bin/vh check` 会打出来（硬规则 5）。
   - **输出**：底线条目逐条 PASS/FAIL；其余条目只写有问题的，说清观看问题、附时刻和帧、给改法；`TASTE_CHECKLIST.md` 文末打分层的八个维度（1–10 分，含立意）；最多 3 个最重要的问题，每个都写时间点和改法，片子已经到位就不凑。底线有 FAIL 就退回；`studio` 还要看做工五项有没有低于 7（过线规则见打分层），至少跑 3 轮，每轮只重渲受影响的时间段。
   - **上限**：整片评审最多 10 轮，到了就停，过线交付，没过线带着分数进关卡 ③；同一类问题（同一条清单条目落在同一个镜头或段落上）最多改 5 次，第 5 次还没解决就写进 NOTES 的"已知局限"，交给人。每轮在 NOTES 的"评审记录"记一行，问题计数表跟着加（格式见 `templates/NOTES.md`）。
   - **小修只做局部复查**：一条标签的时间或字号、在安全框里挪一挪、一个音效的音量、一个镜头的排版，这类改动只查改过的那一段：这一段的帧和 strip，覆盖它的自动检查（`bin/vh readcheck`、`bin/vh qa`、`bin/vh sheet`、下文"静默失败"的像素扫描、`hyperframes snapshot`），再加作者自己看一遍。不为它重开整片评审。改好的这一段也不用重渲整片：`bin/vh render` 出的片子，`bin/vh patch <成片> --seconds <起>-<止>` 只把这几秒重画一遍，在前后的关键帧处切开、接回，声音和字幕轨照旧，再自动核对总帧数、接缝外逐帧不变、解码不报错，以及为凑到关键帧而重画的、不在这几秒里的帧和原来一样（不一样说明改动波及到了这几秒之外，比如转场里还看得到这一镜，就把范围写大）。新开一轮只为结构性的改动（几个小节一起重排时间、重写一个场景、换一个结尾）或最后一遍。`studio` 的前 3 轮不受这条限制。
   - **后一轮推翻前一轮**：见 `TASTE_CHECKLIST.md` 打分层的同名一条。
6. **整片理解**（可选）：Gemini 能直接读视频，但默认按每秒 1 帧采样，只适合检查叙事和粗略的音画对齐，快速动作里的问题它看不出来。
7. **人**：最终对听感和品味把关。

## 预算

以下是 `standard` 和 `studio` 里，新做和改过的镜头的最低量；没动的镜头抽查（`quick` 的量见上面开头那条 `quick` 的说明）。来自 ClaudeAnimationBase：
- 每个镜头至少一张联系表；
- 每个关键动作和每个转场各一条 strip；
- 每张承载剧情的脸一个 crop。

本机实测一张 6 帧联系表只要 5 秒，这一步不要省。

## 各引擎的取帧命令

**所有页面引擎通用**：HyperFrames、手绘引擎和写了 `window.film` 的页面，都能用 `bin/vh frames <项目> --at 1.5,4.2`（静帧）、`--range 2:8:0.5`（隔一段取一帧）或 `--strip 2:2.5`（一段里的每一帧，外加一张拼图）从源码取无损 PNG，不用先渲视频。它走的是页面合约（`engines/CONTRACT.md`）。要和某条渲染路径逐像素对比时，用同一个浏览器（`CHROME_PATH`）。下面各引擎自己的命令照样能用。

**ClaudeAnimationBase / p5（在你的项目目录下运行，项目由 `bin/vh new handdrawn|mv <slug>` 从 `engines/ClaudeAnimationBase/` 复制而来）**

```bash
node render.mjs --sheet=0.1,0.8,1.6,2.4 --cols=4 --w=320 --out=out/check/sheet.jpg   # 联系表
node render.mjs --strip=2.1:2.6 --cols=6 --w=320 --out=out/check/strip.jpg            # 这段时间里的每一帧
node render.mjs --sheet=2.3,2.4 --crop=760,420,500,400 --w=500 --out=out/check/face.jpg  # 全分辨率局部
node render.mjs --strip=2.1:2.6 --crop-at=960,700,500,400 --out=out/check/feet.jpg      # 跟着世界坐标的一个点裁切
```

**HyperFrames**

```bash
npx hyperframes lint                       # 写 HTML 过程中随时跑
npx hyperframes check --snapshots          # 最终关卡：lint + 运行时错误 + 布局 + 对比度，附带标注帧
npx hyperframes snapshot --at 1.5,4.2,8.0 --describe false  # 指定时刻的静帧；不带 --describe false，设了 GEMINI_API_KEY 时帧会发给 Gemini（见 engines/README.md）
npx hyperframes preview --background       # 给用户看，确认后再 render
npx hyperframes render --quality draft     # 快速出片；最终交付用 --quality delivery --output out.mp4
# 命令前先 export HYPERFRAMES_SKIP_SKILLS=1；render 用 & 或 nohup 放到后台、命令在渲染结束前返回时，那一行前加 HYPERFRAMES_RENDER_DETACHED=1，否则 shell 退出时渲染会自己取消（见 engines/README.md）
# snapshot 在 tween 起点可能和渲染结果不一致，关键帧以 mp4 为准。逐帧 strip：
ffmpeg -i out/draft.mp4 -vf "select='between(n,95,106)',scale=320:-1,tile=6x2" -vsync vfr -frames:v 1 out/check/strip.png
```

**Remotion**

```bash
npx remotion still <CompositionId> out/check/f120.png --frame=120
npx remotion render <CompositionId> out/draft.mp4 --scale=0.5
```

**Manim CE**

```bash
manim -ql scene.py MyScene                 # 480p15 快速渲染
manim -ql -s scene.py MyScene              # 只存最后一帧
manim -qh --fps 30 scene.py MyScene        # 成片 1080p30（-qh 默认 60fps，-qk 是 4K60）
manim -ql --format png -n 30,31 scene.py MyScene   # 只渲染第 30–31 个动画为 PNG：与整片同帧做哈希比对，就是 Manim 的确定性检查
# 拿到 mp4 后，用下面的 ffmpeg 通用命令拼联系表
```

**通用：从任何 mp4 取帧（ffmpeg，本机实测可用）**

```bash
ffmpeg -i out.mp4 -vf "fps=1,scale=480:-1,tile=6x5" -frames:v 1 out/check/sheet.png                  # 每秒 1 帧的总览
ffmpeg -ss 11.7 -i out.mp4 -t 0.6 -vf "fps=10,scale=320:-1,tile=6x1" -frames:v 1 out/check/seam.png  # 某个切点 ±0.3 秒
ffmpeg -i out.mp4 -vf "blackdetect=d=0.3,freezedetect=d=1.5" -af silencedetect=d=1.5 -f null - 2>&1 | grep -E "black_|freeze_|silence_"
ffprobe -v error -show_entries format=duration:stream=codec_name,width,height,r_frame_rate -of compact out.mp4
```

冻结和静音的命中只是列出来看：这条命令按 1.5 s 列，`bin/vh check` 按 3 s 列，都只是提醒。算不算"什么都没发生"，按 TASTE_CHECKLIST #18 的秒数判（短视频 3 s、讲解 8 s）；暗底、立意要的停留、无声片都会命中，不算问题。

## 手机测试与循环接缝

**手机测试**（按目标屏缩）：缩到多宽看 BRIEF 的 `Watch on`。`phone`（竖屏）和 `feed`（横屏片放进手机信息流、不转屏）都按 360 px：常见手机在 360–430 个 CSS 像素之间，取下限。`desktop`（电脑，或手机转成横屏全屏）按 640 px：手机比 16:9 长，转成横屏全屏时画面按屏幕高度放，约 640–760 px 宽；电脑播放器默认约 850–1000，取下限。把每格缩到这个宽度，按原尺寸看：必读字读不出、主体认不出，就对应 TASTE_CHECKLIST 的 #5、#6，也是打分层"目标屏可读"一项的证据。

```bash
# 每 2 秒 1 格，每格 360 px 宽；片子长会自动出多张，不要为了塞进一张而把格子再缩小（竖屏改 tile=4x2）
ffmpeg -i out.mp4 -vf "fps=1/2,scale=360:-1:flags=area,tile=3x4" out/check/phone_%02d.png
# desktop：每格 640 px 宽，一张 2×3 格
ffmpeg -i out.mp4 -vf "fps=1/2,scale=640:-1:flags=area,tile=2x3" out/check/screen_%02d.png
```

整张图的长边控制在约 1500 px 以内。图太大时，读图会把它再缩一次，测出来就不准了。

字号下限换到屏幕上是多大，见 `03-motion-design.md` §4 的表：同一个 44 px，竖屏手机上约 15 px，横屏片放进手机信息流只有约 8 px（`docs/research/06-concept-first-ab.md`），所以 `feed` 那一档的下限高得多。

**开头 2 秒**（要进信息流的片子）：钩子要在第 0 帧就开始。把前 60 帧（30 fps 的 2 s）逐帧拼成一张，看画面是不是一开始就在动、有没有让人停下来的东西：

```bash
# 30 fps 取前 60 帧；每格 150 px 宽，整张 1500 px 宽（长边规则同上）
ffmpeg -i out/draft.mp4 -vf "select='lt(n,60)',scale=150:-1,tile=10x6" -vsync vfr -frames:v 1 out/check/first2s.png
```

**循环接缝**：GIF、网页背景、平台自动循环这类交付物，末帧后面紧跟着首帧。把末 6 帧和首 6 帧拼成一条，像观众那样连着读：

```bash
N=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 out.mp4)
ffmpeg -i out.mp4 -i out.mp4 -filter_complex "[0:v]select='gte(n,$N-6)'[a];[1:v]select='lt(n,6)'[b];[a][b]concat=n=2:v=1,scale=320:-1,tile=6x2" -frames:v 1 out/check/loop_seam.png   # 上行末 6 帧，下行首 6 帧
```

理想的循环是 f(T) = f(0)，T 是片长。这样末帧 f(T − 1/fps) 到首帧只差一步正常的运动。末帧和首帧一模一样反而不对，循环时会多停一帧；差得太远就是跳一下。量化的办法：末帧对首帧的 PSNR，应该和片尾任意相邻两帧之间的 PSNR 差不多。

## 确定性：比无损帧，不比 mp4

页面引擎（HyperFrames、手绘引擎、写了 `window.film` 的页面）先跑 `bin/vh determinism <项目>`：同几个时刻在同一个浏览器里换个顺序画、在另一个浏览器进程里画、再关掉宿主的时钟兜底画，比无损 PNG，低于 45 dB 就报出来；只在关掉时钟后才不同的，说明页面靠宿主钉住的时钟才一致（读了 `Math.random` 或真实时间），换一个不钉时钟的渲染器就会变。下面是各引擎自己的做法。

硬规则 1 的"PSNR ≥ 45 dB"指的是无损帧。x264 会沿参考帧把 GPU 光栅化带来的几个像素的差异放大。本仓库的介绍片（intro film）v3 做过对照：1 个 worker 和 3 个 worker 渲出的无损 PNG 序列，最低 PSNR 在 60–92 dB 之间，肉眼看不出；同样两次渲染编码成 mp4 再比，最低掉到约 42 dB，会被误判为不确定。

那几个像素来自 GPU 上的 2D canvas 光栅化：文字边缘在不同的 Chrome 进程里差 1 个色阶，同一台机器上每次都不一样。要逐字节相同，给 `hyperframes render` 加 `--no-browser-gpu`（SwiftShader 渲 WebGL，canvas 和合成都在 CPU 上，截帧路径也不再随 worker 数变）；样片渲染器 `styles/_swatch/render.sh` 就是这么做的，代价是慢一些，原因和数据见 `styles/_swatch/README.md` 的"确定性"。

```bash
# HyperFrames：同一段分别用 1 个和 3 个 worker 渲成 PNG 序列，再逐帧比
npx hyperframes render --format png-sequence --workers 1 --output out/det/w1
npx hyperframes render --format png-sequence --workers 3 --output out/det/w3
ffmpeg -i out/det/w1/frame_%06d.png -i out/det/w3/frame_%06d.png -lavfi psnr=stats_file=out/check/det.txt -f null -   # 看汇总的 min，和每帧的 psnr_avg
```

**HyperFrames 的 PNG 序列是 RGBA，不画 `html`、`body` 的背景。** `--format png-sequence` 写的是带 alpha 的 PNG（命令行帮助里写的就是 RGBA 帧）：`html`、`body` 上的 `background` 不会画进去，那些地方 alpha = 0；元素自己的底色会留下，合成根元素（带 `data-composition-id` 的那个）的也留下（0.8.82 连它也不画）。这对上面的比对有三个影响：
- **帧和 mp4 里的不是同一张图。** 没被元素盖住的地方是透明的，PNG 序列直接转成 mp4，背景是黑的（实测 RGB 0,0,0）；同一个合成直接 `render` 出的 mp4 是页面的底色。要和 mp4 的帧比，先把 PNG 叠到底色上。
- **页面背景上的东西查不到。** 背景若画在 `html`、`body` 上，序列里根本没有它，它不确定也查不出来。要让检查盖住背景，把底色放进根元素或一个铺满全屏的子元素：整帧不透明，PNG 也就成了不带 alpha 的 RGB。
- **上面那条 `ffmpeg … psnr` 可能不准。** 画面里只要还有一点透明，帧就是 RGBA；全部不透明了，帧就变成 RGB（比如底色淡入的前几帧是 RGBA，之后是 RGB）。ffmpeg 读到格式变化，会在中途重建滤镜：汇总打印两次，`stats_file` 只剩开头几行。RGBA 输入时 `average` 还把 alpha 当成第 4 个通道，比只算 RGB 高约 1.25 dB（实测 61.02 对 62.27），45 dB 的门槛被悄悄放宽（ffmpeg 8.0.1 实测）。序列里有透明的话，改成一对一对地比，先转成 rgb24，只列字节不同的帧（像素相同的显示 inf）：

  ```bash
  for f in out/det/w1/frame_*.png; do n=${f##*/}; cmp -s "$f" "out/det/w3/$n" || ffmpeg -nostdin -v info -i "$f" -i "out/det/w3/$n" -lavfi "[0:v]format=rgb24[a];[1:v]format=rgb24[b];[a][b]psnr" -f null - 2>&1 | sed -n "s/.*average:\([0-9.inf]*\).*/$n \1 dB/p"; done
  ```

长片不必全片都比。介绍片的做法是单独建一个 4 s 的局部 composition（用一个时间偏移变量把起点挪到要测的段落），6 s 就能渲完。Manim 的对应做法见上面 `--format png` 那一行。

## 静默失败

有几种故障不报错、不崩溃，渲染照样显示"成功"，只有逐帧统计才抓得到：

- **renderAt 抛异常，画面停在上一帧。** 介绍片第 17 版 draft 里，一个 `const` 在声明之前就被读取（TDZ），36–48 s 共 12 秒的每一帧都停在 t=0 的画面，渲染日志里没有任何错误。画面上有 HUD 时间码的话，抽帧读 HUD 最快；通用做法是把每帧和第 0 帧比 PSNR，找异常高的连续段。`freezedetect` 不一定抓得到：只要颗粒或别的图层还在逐帧变化，画面就不算"冻结"。
- **逐帧干跑一遍，抓只在某几秒抛的异常。** canvas 或 Three.js 的片子，场景代码里一个未定义的变量只会让那一段画面不见，snapshot 和 render 都不报错。出片前可以在浏览器里打开合成，按成片帧率的步长从 0 到片长调一遍画帧函数（`renderAt(t)`、`draw(t)` 或合成暴露的同类入口），try/catch 收下每个抛异常的时刻和堆栈：一支 155 s 的片子 4 s 扫完，抓到一个只在一个镜头里抛的 ReferenceError（那几秒字卡不见）。纯 2D canvas 也可以在 node 里干跑：拿一个 Proxy 当 `ctx`，吞掉所有调用，`measureText` 返回假宽度，600 个时刻几秒跑完，直接报出出错的时刻和行号。
- **空帧。** 异步 build 还没完成，worker 的第一帧就被截了图。介绍片里是每个 worker chunk 开头的 1–2 帧，YAVG 24，前后都是 62。逐帧读 `signalstats` 的 YAVG，找突降。修法：在一段经典内联脚本里同步注册一个就绪 promise，由模块脚本在 build 完成、第一帧画完之后 resolve，渲染器等它再截图。
- **build 的 promise 失败没人接，整段黑场。** 介绍片 v5 里正文的组装抛了一个“先用后定义”的错，`build().then(...)` 没有失败分支：页面不报错，快照和渲染都是只剩暗角的黑底。异步组装的 promise 一律接上失败分支，`console.error` 打出堆栈再抛出去，让渲染器和快照都能看见。
- **渲染永远挂住。** importmap 指向 CDN 时，断网会让渲染卡在页面加载处：日志 0 字节，不报错，进程也不退出。依赖一律装进项目（`npm i -D --save-exact`，importmap 指向 `./node_modules/`），渲染外面再包一层看门狗：超时就杀掉，检查退出码，核对帧数，抽几个时间点查 YAVG，确认主画面层确实画出来了。
- **单帧坏帧：闪进别的场景，或者字被画成乱码，同一时刻的 snapshot 却是干净的。** 一支 160 s 的 canvas 片子用 HyperFrames 0.8.82 渲染，浏览器 GPU 开着，drawElement 截帧自检失败后退回多 worker 截屏（日志：`drawElement self-verification failed; re-rendering via screenshot`）。同样的设置渲了 4 次，有 1 次出了至少 7 处坏帧：6 处只有一帧，7.87 s 一处连着 3 帧（钩子字和手机里的字被画乱）。太短，黑场和冻结检测看不到；snapshot 走另一条截帧路径，抽 snapshot 也查不出。
  - **扫描**：`bin/vh check` 的孤立帧扫描（`tools/isoframes.py`）专找单帧坏帧：192×108 灰度下，一帧和前、后两帧都有超过 1% 的像素差 12 级以上，而前后两帧彼此很像，就判失败，列出时间（向下取整到毫秒，`ffmpeg -ss <秒> -i out.mp4 -frames:v 1 f.png` 正好取到那一帧）。切镜不算。
  - **设计好的闪也会被列出来**（风格样片 `scratched-type` 的红闪帧、`neon-step-print` 的路灯和招牌一闪）：对照分镜，是设计的就写进项目的 `confirmed.json`（见下文“确认告警”），确认过的照样列出、标成已确认，不算失败；只想这一次放过，用 `bin/vh check <视频> --allow 1.0,3.2`，不落盘。其余的，在那个时刻 snapshot 一张，和 mp4 里的那一帧比：snapshot 也坏，是画面本身在那一帧跳了（比如镜头路径）；snapshot 干净、mp4 坏，就是截帧出的错。
  - **修法**（还在验证）：加 `--no-browser-gpu --experimental-fast-capture=false` 软件渲染。这支片子 4800 帧软件渲染要 1–2 分钟，之后 7 次渲染扫出来都是 0。
  - **周期运动和画面停着**：等间隔出现的孤立帧（4 个以上，间隔相等，每帧都不大）报成周期运动，不算失败；`--allow` 也可以写区间（`--allow 12-15`）。同一次解码还报三样，都只是警告：3 s 以上一帧和一帧几乎不变的静止段（定格还是慢漂）、从暗处一下切到亮处的硬切（像闪白），和汇总一行（在动的比例、硬切数、静止占比、镜内最大跳变）。阈值和标定见 `docs/research/07-motion-checks.md`。
  - **扫描看不到的**：只坏几个字的帧（那次的 2 处，碎片只占 0.3% 和 0.1% 的像素，低于 1%）；连着 2 帧以上的坏帧（7.87 s 那 3 帧在扫描看来就是运动）；第一帧和最后一帧；还有前后两帧本身就差了四分之一画面以上的帧，粒子、运镜、线条抖动的段落都是这样，再大的坏帧在那里也分不出来。扫描会数出这些帧、列出半秒以上的段落（介绍片约三成），这些段落和有字的段落照样看 strip。

```bash
ffmpeg -i out.mp4 -vf "signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=out/check/yavg.txt" -f null -   # 逐帧平均亮度，找突降
ffmpeg -i out.mp4 -frames:v 1 out/check/f0.png
ffmpeg -i out.mp4 -loop 1 -i out/check/f0.png -lavfi "psnr=stats_file=out/check/psnr_f0.txt:shortest=1" -f null -   # psnr_avg 异常高的连续段 = 画面卡回了 t=0
ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 out.mp4   # 帧数应等于时长 × fps

# 看门狗（macOS 默认没有 timeout 命令）：超过 25 分钟就杀掉，退出码非 0 就报错
# 整段在同一条命令里等渲染结束（$pid 和 wait 只在同一个 shell 里有效，不能拆开），不用加 HYPERFRAMES_RENDER_DETACHED
npx hyperframes render --output out/draft.mp4 > out/draft.log 2>&1 & pid=$!; t=0
while kill -0 $pid 2>/dev/null; do sleep 5; t=$((t+5)); [ $t -ge 1500 ] && { kill $pid; break; }; done
wait $pid || echo "FAIL: render exited $? (timeout or error), see out/draft.log"
```

## 色彩标签：每个 mp4 出片前查一次

PNG（或别的 RGB 画面）编成 H.264 时，如果不指定 BT.709 矩阵和标签，swscale 按 BT.601 算矩阵，又不写标签；浏览器和手机把高清片按 BT.709 解码，饱和色就偏了。用 8 个色块实测，最大偏 21 个色阶（绯红 (225,29,72) 读成 (238,48,69)，翠绿 (16,185,129) 读成 (1,164,126)）；显式写 BT.709 矩阵和四个标签后最大偏 3，这是 8 位 YUV 往返的基线【实测】。这 8 个色块里没有纯色；纯绿 (0,255,0) 用同样的方法量，读成 (0,215,0)，偏 40【实测】。

**浏览器只认一部分标签。** 在 Chrome 154（无头）和 Chromium 152 里，用同一批 BT.601 像素只改标签实测：矩阵写 `smpte170m` 的都按 BT.601 读对（最大偏 1–2，transfer 和 primaries 写不写都一样）；矩阵写 `bt470bg` 的读错，只写矩阵偏 24（绯红读成 (241,50,69)，翠绿读成 (3,165,128)），三项都写成 `bt470bg` 反而偏 38–40；不写标签的高清片按 BT.709 读。ffmpeg 读这几种都对，浏览器不是。旧的手绘引擎输出 `yuvj420p, pc, bt470bg`，所以在浏览器里偏色。不要依赖浏览器怎么处理 BT.601 的各种标签：交付一律用 BT.709，四个标签写全。

```bash
# 查一个文件：期望 pix_fmt=yuv420p，color_range=tv，color_space、color_transfer、color_primaries 都是 bt709
ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt,color_range,color_space,color_transfer,color_primaries -of default=nw=1 out.mp4

# 出片：PNG 序列编成 mp4 时，矩阵、范围和四个标签都显式写
ffmpeg -framerate 30 -i out/plate/f_%04d.png \
  -vf "scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,format=yuv420p,setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv" \
  -c:v libx264 -crf 14 plate.mp4

# 查整个仓库已提交的 mp4：列出不是 yuv420p,tv,bt709,bt709,bt709 的
git ls-files '*.mp4' | while read -r f; do
  t=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt,color_range,color_space,color_transfer,color_primaries -of csv=p=0 "$f" </dev/null | sed 's/,$//')
  [ "$t" = "yuv420p,tv,bt709,bt709,bt709" ] || echo "$f  $t"
done
```

`yuvj420p`、`color_range=pc`（全范围）、`bt470bg` 或 `smpte170m`（BT.601 矩阵）和 `unknown` 都不合本仓库的交付约定。手绘引擎 `engines/ClaudeAnimationBase/render.mjs` 原来把 Chrome 的 JPEG 帧（全范围 BT.601）直接喂给 x264，出的片子正是 `yuvj420p, pc, bt470bg`；它现在已经转成 BT.709 tv 并写全四个标签，改之前渲的片子要重新编码才会变。

**本仓库 2026-10-01 的审计**：已提交的 34 个 mp4 里，32 个是约定值，两个不是，都已在配声音时重编码成 BT.709 tv、写全四个标签（命令和核对数字在各自的 NOTES.md）：
- `showcase/01-handdrawn-clawd-leaf/media/final.mp4` 原来是 `yuvj420p`、全范围、`bt470bg`，就是上面引擎改之前的输出。**浏览器里确实偏色**，不只是不合约定：在 Chrome 154 里，它第 11.5 s 的饱和像素平均 R +6、G +5、B −5。ffmpeg 按标签读没有问题。
- `showcase/03-math-fourier/media/final.mp4` 原来没有任何标签，但像素是 BT.601。按 BT.601 解码，样片调色板里的 `#FFFF00` 原样还原（第 15 s 一帧里约 3000 个像素），按 BT.709 解码（浏览器的做法）变成 (255,240,0)（约 6000 个像素）；`#58C4DD` 变成 (78,187,224)（算出来的值）。没有源帧时，就用已知调色板这样判断矩阵。

`showcase/04-intro-film/assets/clips/` 在 `.gitignore` 里，是 `showcase/04-intro-film/tools/make_clips.sh` 从 00–03 的成片重建的代理；重编码之前建的 `01.mp4`、`03.mp4` 还带着旧标签，重跑脚本即可。

**只补标签不等于修好。** 像素本来就是 BT.709 tv、只是缺标签的文件，可以不重编码：`-c copy -bsf:v h264_metadata=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1:video_full_range_flag=0`。像素是 BT.601 或全范围的文件（比如上面那两个原来的成片），只改标签会让它们"看上去标对了"却错得更多：在按 BT.601 全范围编的色块上试过，只改成 BT.709 标签，最大偏 29 个色阶。这类文件要重编码，用上面"出片"那条的滤镜链就行：

```bash
ffmpeg -i in.mp4 -vf "scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,format=yuv420p,setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv" -c:v libx264 -crf 14 out.mp4
```

ffmpeg 有标签时按标签读，没有标签时按 BT.601 tv 读，所以 01（有标签）和 03（没有标签，像素是 601）都能转对：在 Chrome 里量过，转完的 03，第 15 s 的 `#FFFF00` 回到 (255,255,0)，不再是 (255,240,0)；转完的 01，同一帧饱和像素的平均偏差从 R +6 / B −5 变成 R −4 / B −4，没有方向性了，剩下的是重编码的损失。如果像素其实是 BT.709 却没写标签，在 `scale=` 里先加 `in_color_matrix=bt709:in_range=tv`。重编码一次有损，能从源头重出就从源头重出【实测】。

`flags=accurate_rnd+full_chroma_int` 在 YUV 换矩阵时要加：swscale 默认的换算不够准，03 的纯黄 `#FFFF00` 换出来 Y 是 217（该是 219），x264 编码后按 BT.709 解出来 (252,253,0)；加上以后是 (254,254,1)。从 PNG 这类 RGB 源出片时，加不加结果一样（8 个纯色块最大都偏 1.1 个色阶）【实测】。

## 音频 QA

agent 听不见声音，声音也只能靠数字查。介绍片 v2 的画面自查全过了，用户却听出"部分地方卡顿或者消失"。事后扫描，v2 的混音里有 94 个 0.1 s 窗口比所在段落的中位数低 12 dB 以上，另有 6 段数字静音。最终成片上，下面四项扫描都没有问题（cue check 180/180 在 1 帧以内）。

| 扫描 | 对什么做 | 做法 | 判为问题 |
|---|---|---|---|
| 掉音 | 成片混音 | 每 0.1 s 一个 RMS，和所在段落的中位数比 | 比段中位数低 12 dB 以上（片头片尾的淡入淡出除外；给了 `--stems` 时，音乐 stem 自己也一样深的凹陷是配乐的动态，不算；谱子音符表里的休止和两音之间的空也不算）；片中任何数字静音（< −60 dBFS，持续 ≥ 20 ms） |
| 抽吸（pumping） | 音乐总线 | 50 ms RMS 对 600 ms 滑动中位数 | 凹下超过 4 dB、持续 ≥ 60 ms，而且不在设计好的打点附近（打点前 0.05 s 到后 0.4 s） |
| 爆音（click） | 成片混音 | 采样级的二阶差分，和前后 5 ms 的局部 RMS 比（不含该采样前后 ±1 ms，否则孤立的 click 永远超不过门槛） | **只报警告，不算失败**：机器分不清设计好的尖锐起音和真故障。超过局部 RMS 的 15 倍且高于 −40 dBFS、又不在设计好的起音附近（节拍表的 `hits`、`beats`、音符表的音和音效事件落点的前后 40 ms，`--click-grace` 可调）的，按倍数排序列出最严重的 10 处，请人耳复听 |
| cue check | 成片混音（WAV 是门禁；mp4 再查一遍，容差加 12 ms，单个 cue 只作警告） | onset 检测（hop 128 采样，48 kHz 下约 2.7 ms），和节拍表、音效事件表逐条比；每条打印 margin（超出检测门槛多少）；近乎纯音的音效 onset 没找到时，用它自己的声音做互相关确认；第 0 帧的 cue 先垫一帧静音 | 任何一个 cue 离最近的 onset 超过 1 帧；margin 低于 0.02 的标 `OK~`，只作警告；mp4 上整个编码偏了（8 个以上 cue 时超过 20% 对不上，或中位误差超过 15 ms，是封装错位） |
| 层次（`qa mix`） | 混音 profile 写出的各总线（`--stems`） | 逐句 VMR（人声减音乐）、每个词的 1–4 kHz SNR、每个音效相对锚点的响度和类、纵深、限幅器，见 `tools/audio/README.md` 的"混音" | 有一句低于 profile 的 VMR 下限；说话时 hero 盖过人声；危险的词超过比例；某类音效的中位数离范围超过 3 LU；timeline 有句子，人声 stem 却全是静音；一个 cue 只以“弱”对上，报告又判它 `BURIED` |

```bash
# 掉音扫描的原料：每 0.1 s 一个 RMS（48 kHz 下是 4800 采样，44.1 kHz 改成 4410），再按段落求中位数比较
ffmpeg -i audio/mix.wav -af "asetnsamples=n=4800:p=0,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=out/check/rms.txt" -f null -
bin/vh qa audio/mix.wav audio/music.beats.json audio/events.json --stems audio/stems --out out/check/audio-qa.txt   # 四项扫描 + cue check + 混音报告一条命令（tools/audio/qa.py），有问题时退出码为 1
bin/vh qa out/final-av.mp4 audio/music.beats.json audio/events.json --out out/check/audio-qa-mp4.txt              # 成片再查一遍：扫描照常判定，单个 cue 只作警告，整体偏移（封装错位）判失败
```

cue check 必须在最终混音上做，只查配乐不够。介绍片的配乐单独查时每个 hit 都准，混进音效后出了 3 处偏差：两个 pop 离配乐的按钮音只差 67 ms，onset 检测把它们并成了一个；另一处 whoosh 的上升段盖住了配乐的 hit。修法分别是把画面事件改对到按钮音上，以及删掉那个 whoosh。riser、swell 这类渐强没有瞬态，在节拍表里标成 `swell-peak`，不参加打点检查。

## 确认告警

检测器判错或要看语境时（分镜要的一帧闪、谱子里的留白），不改作品去迁就，写进项目的 `confirmed.json`：`check` 的孤立帧，`qa` 的掉音、抽吸、成串的 click 能确认。照抄工具印的 `confirm? {…}`，填 `why` 和 `evidence`（项目里的文件）。原始结果照列，标已确认；那里的画面或声音变了就失效（画面的 key 很粗，小改动要自己再看）。底线（数字静音、读时、字号、关卡）不收。同一种确认到 5 处以上，多半是检测器的问题，报告它。

## 事实核查

硬规则 5 的做法：几处独立来源对得上的才上屏，只有一处的写明出处、不进标题，只在聚合站见到的先找原始出处；会变的数字（股价、星数、排名）带取数日期；星期、月相、时区、单位用代码算；评审要改引文或数字，先回出处。

## 自评的写法

每次自评都写进 `NOTES.md`，格式见 `templates/TASTE_CHECKLIST.md` 的末尾：先写场景编号、时间范围和联系表路径，再写 FAIL 的条目编号，最后写具体改法。只写"看起来不错"不算自评。

## 已知的坑

- **镜头的抖和不连贯，用数字查**：联系表和 strip 看的是单帧，看不出镜头往前冲一截又退回来，也看不出一两帧的跳。两个查法（介绍片 v5 用过）：
  - 渲出来的底片（Blender、生成式视频）：逐帧算缩小后的灰度平均差，画成曲线。正常的运动是平滑地升、降；某一帧比前后几帧高出一截就是跳，去看那几帧。
  - 关键帧插值的相机（three.js、HyperFrames 里的 3D）：在浏览器里逐帧 seek，记下相机位置，找相邻两帧速度方向相反的地方（点积 < 0）。停留段里出现反向，多半是样条过冲（见 `08-vfx-and-motion-sources.md` 的一镜到底一节）。设计好的抖动也会被找出来，逐条核对是不是设计的。

- **亚像素文字闪烁**：镜头一直漂移时会出现，改成先移动、再停住（Chris Tyson 的 Remotion 实践）。
- **卡片边缘 boiling**：非整数缩放比例（例如 0.6667）会导致，缩放只用 1.0 和 0.5。
- **手绘风里静止的物体跟着抖**：前面某个运动物体打乱了随机数流。给每个元素设置独立的 `boilSeed()`。
- **p5.brush 颜色发灰发绿**：它按颜料的方式混色，所以黄色光叠在蓝底上会变灰绿。发光效果要用 `glow()`。
- **片尾的渐暗走不到黑**：最后一帧画的是"时长 − 1 帧"，渐暗算到时长的终点，这一帧还亮着，接下一镜或叠成落款时会跳一下。让渐暗提前 1.5 帧收完（运动模糊的快门也算进去）；`bin/vh check` 会提醒，canvas-film 的 `fadeOut` 已经这样算。
- **把旧的输出文件当成新结果**：渲染前先删掉旧文件，或者检查修改时间。
- **镜头推近后字发虚**：被缩放的元素挂着 CSS `will-change: transform` 时，浏览器会按它当时的尺寸栅格化成一张位图，之后的放大只是把这张位图拉大。要被推近、放大的元素不加 `will-change`；或者按放大后的尺寸排版，入场时再缩小。
- **第一帧用了回退字体**：网页字体还没加载完就截了第一帧，前几帧的字宽不同，排版会跳一下。第一次截图之前先 `await document.fonts.ready`，把它并进渲染器等待的就绪 promise 里（见上文"静默失败"的空帧一条）。
- **canvas 上的中文网页字体只加载了一部分**：`document.fonts.ready` 只等"已经开始加载"的字体。canvas 要到第一次画某个字时才去下载它所在的字体文件，这一帧先用回退字体画；而 Google Fonts 把中文字体按 unicode-range 切成上百个分片（Noto Serif SC 的一个字重是 101 个），只有用到的分片才会下载。所以 ready 了也可能缺字，缺的字悄悄用系统字体画出来。做法是对每个字重调一次 `document.fonts.load('700 40px "Noto Serif SC"', 全部要用的字)`，把片中所有中文字一次交给它。abstract-algebra-promo 的取字办法很省事：页面脚本源码里所有非 ASCII 字符去重，再加上 A–Z、a–z、0–9。它的毛病也值得记住：`load()` 的失败被 `.catch(() => {})` 吞掉，15 s 后不管成没成都把就绪标记设为真，断网时导出会用回退字体照常出片。我们的规矩是失败就大声报错：`load()` 被拒、返回的 FontFace 数组为空（字体串没匹配上任何 `@font-face`，常见于族名拼错或样式表没加载进来），或超过时限（例如 60 s）还没好，都抛异常，让渲染器以非 0 退出；不要设"超时就当就绪"的兜底。
