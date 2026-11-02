# 03 产品宣传 / 发布片 / 功能演示

**适用**：
- 10–90 秒的产品发布片（短的 10–30 秒最常见；讲清产品本身的介绍片可以到 60–90 秒；本仓库的介绍片 103 秒，算是偏长的；它一度为了读字把停留拉长到 150.5 秒，看着处处卡顿，又调回来）、App 或 SaaS 宣传片、功能揭示、网站导览、GitHub 项目介绍；
- 也包括给自己的开源项目、工具或课题组做的介绍片。

## 引擎

- **首选**：HyperFrames，`bin/vh new promo <slug>` 会自动初始化。
  - 借用 `/product-launch-video` 的参考资料（`references/repos/hyperframes/skills/product-launch-video/references/`），**默认不要直接运行这个工作流**。它是一整套独立的编排器，有自己的 BRIEF 契约、`videos/` 目录、网站抓取、HeyGen 登录和逐帧 subagent，和本仓库的模板、关卡不兼容。只有用户明确要走 HeyGen 那条路时才用。
- **备选**：Remotion，配合 `remotion-skills` 里的 `remotion-saas`。
- **3D 产品展示**：用 Blender（`engines/README.md`）。
- **3D 世界、一镜到底**：HyperFrames 加 Three.js 层。做法见 `playbook/08-vfx-and-motion-sources.md` 的"一镜到底"一节，坑见 `engines/README.md` 的 HyperFrames 一节。

## 工作流

1. **先有素材清单，再做动画**：产品截图或录屏、logo、真实文案、品牌色和字体、网址、架构图和流程图。**不要用占位 UI，也不要凭印象重画界面。** viggo 的 Applore 宣传片之所以可信，就是因为用了自家库里 17,550 个真实 app 图标。
   - 网页和 Web App 用 Playwright（或浏览器工具）按成片分辨率截图，例如 `npx playwright screenshot --viewport-size=1920,1080 <url> assets/ui/home.png`；终端、编辑器等本地界面用录屏或系统截图。
   - 要演示操作（点哪里、点了以后怎样）时，改用 1280×720 的视口、3 倍截，每个状态一张，再量出要点的元素的框；光标和镜头怎么动见 `recipes/interaction/browser-walkthrough.md`。
   - 全部存进项目的 `assets/`，逐条用 `bin/vh assets add` 登记进素材台账（来源、许可，sha256 由它算）。开始写场景代码前，把清单过一遍：片子里要出现的每块界面都要在清单里有对应的文件，清单里没有的就先去截，而不是自己造。
2. **选语域**：先从立意推（`playbook/12-ideation.md`）。立意没给出更好的答案时，可以从下面两种常见做法起步，写进 STYLE.md；立意推出别的语域，就用别的。
   - **Apple 系**：黑底或白底，单镜只说一句主张，大面积留白，对真实 UI 做微距裁切，每次揭示 1–2 秒，慢。
   - **Linear / Vercel / Stripe 系**：近黑底 `#0A0A0B`，1px 细线，低透明度的蓝图网格，Geist 或 Geist Mono 字体，用真实 UI。

   这两种也是发布片最常见的长相，Linear 系尤其是社区里最常见的外观【综合】，和"AI 味"只差在克制和真实 UI（见下文"警惕"一条）。
   
   **同一个产品的每支片子共用一条品牌管线**：第二支片子从上一支的 STYLE.md 起步，沿用色板、字体、强调色、转场和音色，审阅意见也回写进去。本仓库的介绍片就沿用了 showcase 00 的近黑底、发丝线和唯一的琥珀强调色。product-film-skill 用 `videos/BRAND.md` 做同一件事（见文末）。
3. **look-dev**：brief 里只说"炫酷""高级""大片感"，却没有说具体是什么样时，先做一轮 look-dev 再定：出 3 张 style frame，或者 2–3 段 10–20 s 的短变体，放在关卡 ② 之前或并进关卡 ②，让人挑。
   - 变体只换强度预设、不换内容，人比较的才是风格本身。介绍片 v3 用同一份代码、按 `fx` = A / B / C 渲了三段 22.7 s 的变体，每段都带一节产品信息图，另附一张 3 行 × 11 个时刻的对比图。预设栈的写法见 `playbook/08-vfx-and-motion-sources.md`。
   - 选定的预设写进 STYLE.md。
4. **节拍结构**【综合】：下面是默认骨架。立意自带结构时以立意为准，例如产品的工作流本身就是故事线（`cases/oneshot-five.md` 第 5 节的 Mirage），或者用做法讲做法（第 3 节）。
   1. hook，承诺一个结果（0–3s）；
   2. 问题（1 拍）；
   3. 3 个功能拍，每拍都是"真实 UI 在做这件事"，由超大光标点击触发；
   4. 证据（数字计数）；
   5. 0.5 秒静止；
   6. logo 定版。

   60–90 秒的介绍片，把这六拍套进 `playbook/09-narrative.md` 模板 A 的比例【综合】：hook 和问题是"起"（约前 18%），功能拍是"承"，证据放在"转"的位置、做成全片最大的视觉事件，静止和定版是"合"，回扣开头。要发平台的，开头钩子、标题和封面见 `playbook/10-hooks-and-packaging.md`。
5. **镜头**：
   - 一台连续的虚拟摄像机，推、拉、摇各 1.5–3s，easeInOutCubic；
   - 速度"按你默认速度的一半"（@jake11moran 的写法）；
   - 快速运动加运动模糊，整体加轻微胶片颗粒。颗粒会让 GIF 体积暴涨（showcase 00：24MB 对比无颗粒时的 4.5MB），所以给 README 用的 GIF 预览要单独渲染一个无颗粒版本（例如用 `--variables '{"grain":0}'`）。
6. **声音**（可选；静音版的节奏由分镜的 reads 决定，TASTE_CHECKLIST #18 里的拍点检查不适用）：
   - 音乐驱动，关键点落在拍子上，配音效：先用 `bin/vh music` 按镜头分段写配乐（段落就是镜头边界，冲击点就是揭示时刻），再把光标点击、弹出、完成提示写进 `audio/events.json`，最后用 `bin/vh mix … profile=promo events=audio/events.json lib=audio/sfx` 混音：以音乐为锚点，每个音效按类（hero、detail…）往各自的电平走一半，hero 命中处音乐让 2.5 dB，音乐不会被每个音效压一下（见 `playbook/04-audio.md` 的"混音"）。介绍片和较长的发布片要一个贯穿的主题动机：问题段用它的暗色版本，揭晓时第一次完整出现，做法和一支 58.5 s 的示例见 `playbook/11-composition.md`；
   - 需要角色口播时（Applore 的吉祥物 Ace），用 ElevenLabs、Gemini 或本地 TTS，配同步字幕。
   - 有旁白时，旁白骑在音乐上：`bin/vh tts projects/<p> … --beats projects/<p>/audio/music.beats.json`（路径相对运行命令的目录），答案句、卖点句用 `@id:downbeat` 落在 drop 或小节头；混音同样用 `profile=promo`，加上 `voice=` 和 `timeline=`，音乐逐句只让到旁白下方 10 LU，不会被压没。每个画面动作都要有一个音效或配乐重音回应。见 04 篇"让声音有表情、有节奏"。
7. **多画幅**：主片 16:9，另出 4:5（1080×1350）或 9:16 的版本，按画幅重新构图，不要直接裁切：时间线照用，排版走 `layout(W, H)`（`playbook/03-motion-design.md` §5），按新画幅的合成尺寸再渲一次。合成尺寸写在 `index.html` 里，4:5 的写法照 `bin/vh new promo <slug> --aspect 4:5` 搭出来的那份。

## 审美要点

- **宣传片要展示产品本身，不能只讲理念。** 架构、工作流、特色、案例都要做成动态信息图放进片子。这条来自本仓库介绍片的用户反馈：v2 主要讲 video-as-code 的理念，用户看完指出，这既然是产品的宣传片，架构、特色、案例、工作流流程图都应该做成炫酷的动效放进去。v3 把架构图、十阶段工作流加三道关卡、特色和案例都做成了 3D 世界里的信息图（做法见 `playbook/08-vfx-and-motion-sources.md` 的"一镜到底"一节）。信息图的节点和标签照抄真实来源（README、架构图、文档），数字要有出处。
- **brief 要"炫酷"时，靠这几个旋钮**（介绍片 v3 实测有效，配方和安全底线见 08 篇的"特效做成预设栈"）：
  - 光和对比：更深的黑，唯一的强调色只以光出现，bloom 和体积光随拍子呼吸；
  - 速度坡：换段用 slow–FAST–slow 的甩镜，不用匀速平移；
  - 打点：震动、FOV punch、冲击波环和配乐的冲击落在同一帧，几帧内衰减完；
  - 动态字：字像被程序解码出来，≤ 0.3 s 定住，然后照常读；
  - 有纵深的粒子：粒子分布在镜头路径两侧，提供视差和尺度感。
  
  要避开的是没有理由的通用粒子爆发。每个效果都要说得出"因为产品有 X，所以用 Y"，说不出来就删。
- **运动只走这几条路**：分阶段揭示、有意图的镜头运动、UI 自己在运作、光标点击触发下一拍。平滑优先于弹跳。
- **警惕 Linear 风和 AI slop 撞车**：Inter + 暗底 + 紫色光球同时也是"AI slop"的头号特征。区别在于克制，以及用的是不是真实 UI。
- **两种 prompt 路线**：
  - **"一句话 + 让它自由发挥"**：比如 @achxvi 的 "make a 15-second motion graphics video ... like it's your showreel for a résumé. go all out"。模型自己选风格，炫技效果好，但品牌控制力弱。
  - **"逐拍规定"**：比如 @jake11moran 的 7 个编号节拍。控制力强。
  - 先用前者探索方向，再用后者定稿【综合】。

## 禁止

底线：
- lorem ipsum、假数据；
- 未经授权的第三方品牌 logo。

常见误用（参考）：
- 紫到青的渐变、玻璃拟态、霓虹、✨ 式的 AI 图标：同类发布片最常见的样子，说不出这个产品；
- 六张等大卡片、每个元素都弹：没有重点；
- 渐变文字：小字读不清。

## Prompt 增量块

```text
+ TYPE: product launch film. 1920x1080 (+1080x1350 and 1080x1920 re-framed cuts) 30fps {15–30}s, music-driven, SFX on key hits.
Register: {follows from the concept (playbook/12-ideation.md) | Apple: black/white, one claim per shot, macro crops of the real UI | Linear/Vercel: near-black #0A0A0B, 1px hairlines, blueprint grid at 6% opacity}. Font {Geist/Geist Mono | SF-like grotesk} (default). No gradient text, glassmorphism, or purple-cyan gradients (defaults; a concept may override any of them, one line each in DECISIONS.md).
Default camera: one continuous virtual camera, moves 1.5–3s easeInOutCubic, about half your default speed; motion blur on fast moves; light grain.
Default beats (a concept with its own structure replaces them, e.g. the product's own workflow as the story): hook promise (0–3s) → problem (1 beat) → 3 feature beats, each = the real UI doing the thing, triggered by an oversized cursor click → proof count-up → 0.5s stillness → logo lockup.
Use real copy/assets from {URL / assets/}; recreate the UI accurately; no placeholder text or invented numbers.
Show the product itself: {architecture | workflow | features | case studies} as motion infographics built from its real diagrams and docs, labels copied verbatim.
{Optional mascot/voice: a character introduces the product; voice via {ElevenLabs | local TTS}, captions synced to word timestamps.}
```

## 片子里展示自己的草稿时

如果某一拍要展示这支片子自己的草稿和修复过程（showcase 00 的 beat 03），就把草稿状态做成**可复现的开关**，例如在组件里写 `const DRAFT = "final" | "v1"`，再用一个脚本重建 v1 并截图（见 `showcase/00-promo-launch-film/tools/draft-v1.sh`）。这样改名、改文案之后，"草稿"截图能从源码重新生成，而不是手工 P 图。联系表放进片子时，把时间戳标签调成灰色：`VH_SHEET_LABEL=#9a9a9a bin/vh sheet …`，避免多出一个强调色。

## 自查重点

- 画面里的每个 UI 元素，在真实产品里都存在吗？素材台账里能找到对应的文件吗（`bin/vh assets check` 会两头比）？
- 数字有出处吗？
- 产品、店铺是虚构的时候，名字先搜一下有没有同名的真实品牌（实验里一支面包店片子起名"一条"，撞了一个知名的媒体和零售品牌，见 `docs/research/06-concept-first-ab.md` 的盲评）。
- 片子展示了产品本身（架构、工作流、特色、案例）吗，还是只讲了理念？
- 每个功能拍能在 1 秒内看懂吗？
- 镜头运动是否都是"先动后停"？一直漂移会让 DOM 文字出现亚像素闪烁。3D 一镜到底例外：停站时镜头保留慢推和低幅手持漂移，不要停死（见 08 篇）。
- 多画幅版本是重新构图的，而不是直接裁的吗？

## 可参考的案例与源码

- `showcase/00-promo-launch-film/`：本仓库 20 s 的发布短片样板：没有旁白，画面先做完，代码写的配乐和拟音是后配的。
- `showcase/04-intro-film/`：本仓库的介绍片（Blender 星河开场 + 一镜到底 3D + 代码作曲），每轮评审的分数和改法记在 NOTES。
- `cases/promo-applore.md`：一句话 prompt 做出的 15 秒宣传片拆解。
- `cases/promo-hyperframes-launches.md`：HeyGen 20 支发布片的源码，以及其中值得看的几支。
- `recipes/sequences/product-film-60s.md`、`launch-15s.md`：发布片的全片骨架（能量弧、先划 hold、按能量落差选接缝、限额）；镜头配方在 `recipes/`，拿不准怎么动时按意图和能量挑（`bin/vh recipes list --type promo …`）。它们改写自 video-shotcraft，拆解见 `cases/promo-video-shotcraft.md`。
- `references/repos/hyperframes/skills/product-launch-video/`：`SKILL.md`，以及 `references/` 下的 `story-design.md`、`visual-design.md`、`motion-language.md`、`cut-catalog.md`。
- `references/repos/hyperframes/_upstream_claude/skills/`：
  - `motion-doctrine/`：运动总纲，涉及动画时先读；
  - `oversized-cursor/`：超大光标技法；
  - `cut-the-curve/`：五种速度匹配的转场，加上 waterfall 入场和 nudge 曲线；
  - `seam-craft/`：场景接缝的渲染正确性，例如切点白闪；
  - `changelog-video/`：把更新日志做成品牌视频的完整流程。
- `references/repos/remotion-skills/skills/remotion-saas/`：Remotion 路线的 SaaS 宣传片做法。

## 社区 skill 参考

以下条目选自 183 个社区视频 skill，完整对照和许可证说明见 `references/community-skills.md`。只读参考；复用代码前，先确认它的许可证。

- **video-shotcraft**（Apache-2.0）：150 多张镜头配方卡（SKILL.md 写 157 张）；视觉 tokens 从产品自己的设计系统提取；复刻页面必须用真实截图；每个镜头只讲一个动效。见 `references/repos/video-shotcraft/SKILL.md`、`references/repos/video-shotcraft/references/shots/`。
- **guizang-product-video**（AGPL，只读）：先写 `DIRECTION.md`，列出"因为产品有 X，所以用 Y"的专属手法；同一工作区不复用上一支的开场。见 `references/repos/guizang-product-video/references/direction.md`。
- **product-film**（[Rieranthony/product-film-skill](https://github.com/Rieranthony/product-film-skill)，MIT）：在产品自己的代码库里用 Remotion 做宣传片。
  - 先 discovery：从产品的规则文件、design token、组件和落地页收集设计规则，写成 `videos/BRAND.md`，每条注明出处；审阅意见也回写进去，下一支片子从它起步。
  - 写完故事先交节拍表和 3 张 style frame。
  - 成片用 240 fps 母版加 `tmix` 做真正的运动模糊，再降到 60 fps。
  - 质量底线里明确禁止产品自己不用的特效（光晕、粒子、点击波纹、着色器），和本篇"说不出理由就删"的规则一致。
