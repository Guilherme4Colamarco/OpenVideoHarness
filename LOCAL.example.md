# LOCAL（本机环境，复制为 LOCAL.md 后填写；LOCAL.md 不提交）

- 硬件：{芯片 / GPU / 内存}
- 已装工具：{Node 版本、ffmpeg 版本、Chrome 路径、Python/uv、LaTeX}（`bin/vh doctor` 的输出可以直接贴进来）
- 已装引擎：{ClaudeAnimationBase ✓ / HyperFrames / Remotion / Manim}
- 渲染速度：{ClaudeAnimationBase 1080p 每帧耗时；其他引擎}
- 可用的 API key（只写变量名，不写值）：{ELEVENLABS_API_KEY / FAL_KEY / …}
- 个人资料目录：{论文、数据、素材放在哪里}
- 默认努力程度：{quick | standard | studio}（不填就是 standard；规则见 CLAUDE.md"努力程度"，对话里说的优先）
- 默认导演模式：{例如 hook=own, packaging=own；不填就按档位的默认}（规则见 CLAUDE.md"导演模式"，对话里说的优先）
- 审阅方式：{对话 | 审阅页 | 审阅台}（不填按档位：standard 审阅页，studio 审阅台；只管在哪看、怎么回，关卡不减；对话里说的优先）
- 子代理模型：{例如：默认便宜一档；3D 段落和整片评审用最强档}（不填就用便宜一档的；对话里说的优先）
- 默认预算：{例如每支片子 20 美元；写 不限 就是不设上限}（付费接口按它停；BRIEF 的 `Budget:` 优先，两处都没写就不调付费接口，见 CLAUDE.md 的底线）
- 素材许可：{strict | record}（不填就是 strict：NC、ND、BY-SA 和许可不明的素材 `bin/vh assets check` 判失败；record：都能用，记清并列出风险。BRIEF 的 `Assets:` 优先）
- 网页浏览器：{例如 obscura 0.2.5，在 ~/.local/bin}（`bin/vh web` 读网页、核对事实用；没有就 `bin/vh web install`，`OVH_OBSCURA` 可指定别的路径）
- 声音库：{例如 ~/.ovh/sound}（`bin/vh sfx|bgm search`、`pick` 和 `sound add` 用；不填就是 ~/.ovh/sound；库在仓库外，文件是别人的作品）
- 偏好：{常用平台、画幅、配音音色、品牌色}
