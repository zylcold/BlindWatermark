# AGENTS.md

本文件是本仓库对 AI 编码代理（以及人类贡献者）的约定。**改动前先读，改动后自查。**

## 语言

- **回答与思考过程一律用中文。**
- 代码标识符、命令、报错原文、文件路径保持原样，不翻译。

## 项目结构

```
Sources/BlindWatermarkCore/   编解码核心（跨平台，macOS 上可测）
Sources/BlindWatermark/       iOS 接入层（窗口层 + 自动加载）
Sources/BlindWatermarkAutoLoad/ ObjC +load，零接入挂载
Sources/bwdecode/             截图解码 CLI
Tests/BlindWatermarkCoreTests/ 单元测试
Demo/                         iOS 演示 App（xcodegen 生成工程）+ sweep.sh 逐页对比
skills/blind-watermark/       Agent Skill
tools/bwdecode.py             Python 版解码器（镜像实现），tools/test_bwdecode.py 自检 + 与 Swift 对账
*.podspec                     三个 podspec，与 SPM target 一一对应（Core / AutoLoad / UI）
.github/workflows/ci.yml      PR check：build + test + Demo 编译 + Python 解码器对账
```

## 常用命令

```bash
swift build                          # 编译全部 target
swift test                           # 跑核心测试，macOS 本机即可，不需要模拟器
swift run bwdecode shot.png --layout --key <hex> --pages Demo/pages.json
swift run bwdecode shot.png --protocol v5.2 --layout --scale 0.837
swift run bwdecode shot.png --auto --layout       # 历史 v4 相位/平面搜索
swift run bwdecode shot.png --protocol auto --layout  # 显式混合探测：先 v5.2，再回退 v4
Demo/sweep.sh [UDID] [delta] [luma|chroma] [v4|v52]   # 逐页截图解码对比，需 xcodegen + 已启动模拟器
```

## 硬约束

- **不新增第三方依赖。** 只用系统框架：Accelerate、CryptoKit、CoreGraphics、UIKit。
- **平台下限 iOS 13 / macOS 11**（Demo 是 iOS 15）。用到的新 API 必须满足可用性，必要时 `@available` 兜底。
- **编解码参数必须两端一致**：`payloadBits` / `plane` / `offset` / 载荷布局。任何一项不一致都会解出自洽但错误的结果。
- **v4（512 bit / 64 字节）仍是默认布局并必须保留**：uid + Unix 秒 + build(12 位十进制) +
  15 字符页面短码（96 bit 字段，90 bit 有效，低 6 位必须为 0）+ tag + 22 字节 note + 96 bit 校验值。
  改字段边界 = 换协议、历史截图失效，必须显式说明影响面并同步 README / SKILL。
- **`校验值` 字段是「校验值」，有三种语义**：HMAC-SHA256 截断（有服务端密钥）、SHA-256 截断（无密钥部署的公开自检值，
  用 `WatermarkPayload.selfChecked` 构造）、全 0（没带校验值）。
  **自检通过 ≠ 验签通过**：它只能拦住"对齐错了几 bit"的近似解，拦不住伪造。
  对外输出必须分档（`mac=OK(验签)` / `mac=OK(自检,未验签)` / `mac=未签名` / `mac=未校验(需要 --key)` / `mac=BAD`），
  不得把自检说成验签。
- **裁剪自愈靠校验值裁决**：CLI 的阶梯是「严格校验器（HMAC 或自检值）→ 加 block 奇偶档 → 结构自检兜底」。
  结构自检是兵底（实测全搜索空间里放过 4~17 个近似解），用到它必须打警告并如实报 `mac=未签名`。
- **改载荷布局 = 破坏历史截图兼容。** 必须显式说明影响面，并同步 `README.md` 与 `skills/blind-watermark/SKILL.md`。
- **v5.2 是显式 opt-in 的另一协议**：207 bit 信息字段（profile4 + uid32 + timestamp31 + buildTime24 +
  page8/base37 42 + app14 + note6/base37 32 + CRC24 + reserved4），用 BCH(255,207,t6) 编码并追加一位整体偶校验形成 256 bit 码字；
  `Watermark.installV52` / `--protocol v5.2` 才启用，默认渲染与历史解码仍走 v4。
- v5.2 的时间字段是 UTC 2026-01-01 起的秒/分钟偏移；base37 字母表为 `a-z0-9_`，首字符为高位 radix digit，固定宽度右侧 `_` 补齐且解码去掉尾部补位；非法 radix 值、profile、reserved 或 CRC 必须拒绝。
- v5.2 的 256 bit 码字在每个 256 px tile 中重复两次且业务极性相反；`V52Codec` 的有限 Chase 只在低可靠位上尝试最多 12 位、2 次翻转，并收集全部 CRC-valid 候选后去重，不能遇到首个 CRC 通过就返回。CRC 仅是完整性检查，不是验签。
- **v5.2 的证据门槛与 v4 同一把尺（每 bit 观测 ≥ 5 次），且没有「带校验值就放行」的例外**：CRC24 只是完整性自检，不是验签。`V52Codec.Decoded.hasSufficientEvidence` 低于门槛时，CLI 必须输出 `TOO_SMALL(...)` 并把 `minObs` / `avgObs` / `|z|中位` 打进第一行；带 `--layout` 一律 exit 1 拒答，不带 `--layout` 只警告不解读字段。输出里不得出现 `mac=`（v5.2 没有 HMAC），CRC 档写作 `crcStatus=OK(完整性自检,未验签)`。
- v5.2 的 `V52SyncMode.pn/separated` 是 pilot 实验档，默认 `.none`，且**只作用于 chroma**（luma 平面把亮度通道全给数据，此时不写导频、`pilotScore` 无意义，CLI 要打警告）；实验档的公共亮度调制会记录亮度残差，不得宣称不可见或已通过人工验收。缩放搜索为 0.50...1.50 连续粗网格加图像跨度相关的局部精搜，0.837/1.173 等比例必须作为未列入粗网格的测试。裁剪搜索不接受负 `--offset`（两端一致返回 nil），相位由解码器自己搜索。
- chroma delta 必须按预乘 alpha 的整层 RGBA 合成验证，不能把 `delta` 当作简单的 chroma 加法；pilot 与 data 联合生成时 alpha 保持恒定。
- **可见性只有亮度轴被陪色匹配掉，色度轴极差 = `delta`**：实测 delta=8 时 ΔB=−8/255、ΔLuma=0.35/255，2.67pt 棋盘格在纯色页上看得见。v5.2 观测余量是 v4 的两倍，默认 `delta` 取 4（模拟器六版式 `correctedBits=0`）；v4 保持历史默认 8，要更淡用 6。改默认 delta 必须重新实测并同步 README 中英 / 接入 skill，并重跑真机 + 最暗页面可见性验收，不许只改代码。
- **改公共 API 语义必须带测试**，且 `swift test` 全绿才算完成。
- **黑边裁剪是 CLI 契约，两端必须同义**：`Sources/BlindWatermarkCore/BorderTrim.swift` 的
  `trimmingUniformDarkBorder` 与 `tools/bwdecode.py` 的 `trim_uniform_dark_border` 共享同一组
  `BorderTrimHeuristic` 阈值（近黑 32 / 覆盖率 0.90 / 单边上限 25% / 内侧探针 ≥96 且占比 0.30）。
  自动路径先裁再解，输出行加 `trim=(左,上,右,下)`，`phase` 随之相对裁剪后的图；显式 `--offset`
  时不裁。改阈值必须同时改两端 + 补"深色页留白不裁"的测试。
- **比例尺粗定位是 v5.2 搜索的第一层，两端同义**：`ScaleRuler.swift` 与 `tools/bwdecode.py` 的
  `estimate_scale_ruler` 用同一套阈值（置信 ≥0.05、候选 ±10% / 5 档、block 搜索 3.5~13px）。
  粗筛必须按**比例**排名（每个 (plane, sync, scale) 只留最高分的相位），否则同一比例的上百个相位会
  挤满 top-N，非粗网格比例（0.837 / 1.173）进不了精搜 —— 这条有回归测试钉住，不许改回去。
  比例尺只是粗定位：快路径失败必须退回完整 21 档网格。
- **改解码逻辑要同步两处**：v4 的 `Sources/BlindWatermarkCore/BlockCodec.swift` 与 `tools/bwdecode.py`
  是同一套算法的两份实现（常量、特征平面、折叠、判读阈值、载荷布局、页面短码、校验阶梯）。
  v5.2 的 `V52Codec.swift` 与其 Python 镜像也必须同步；改完必须 `swift test` 与 `python3 tools/test_bwdecode.py` 都绿 —— 后者会在同一张 PNG 上与 Swift 对账。
- **非平凡逻辑留一个可运行校验**（单元测试或 assert 自检），不靠"我推理过"。
- **性能结论要实测。** 不接受"预期 4–8x"这类没测过的数字；写实测值并注明测量条件（设备/模拟器、模式、样本）。
- **不要静默降级**：解码置信度不足时按 `弱 bit` 规则如实报 `WEAK` / `NO`，不硬凑一个结果。
- **观测不足必须拒答**：没有校验值时，每 bit 观测 < `BlockCodec.minObservationsPerBit`（5 次）
  一律输出 `TOO_SMALL(...)` 并拒绝 `--layout` 解读字段 —— 小图会解出"看着正常的垃圾"，
  宁可报图太小。阈值来源见 `BlockCodec` 的实测注释，改动要带实测数据。

## 代码风格

- Swift，4 空格缩进，无分号，单文件不超过必要长度。
- 注释写**为什么**（尤其是反直觉的取整、极性翻转、阈值来源），不复述代码在做什么。
- 阈值 / 调参常量提成 `static let` 并注明来源（实测数据），不在函数体里撒魔法数字。
- 指针与 Accelerate 代码：显式检查长度不变量与越界边界，注释标出 stride 语义。

## 版本与发布

- 三个 podspec 的 `s.version` 必须**同时**改（`BlindWatermark` 用 `~> <版本>` 依赖另两个），
  改完打同名 tag，**不带 `v` 前缀**：`1.0.0`。SPM 与 CocoaPods 都按这个 tag 解析。
- README 中英两份顶部的「版本」行同步改，并在 GitHub Releases 写一段发布说明（做了什么、怎么验证）。
- 平台下限变更（`Package.swift` 的 `platforms`、podspec 的 `ios.deployment_target`）属于破坏性变更，
  升 major 并在发布说明里写清楚影响面。

## 提交规范

- Conventional Commits，描述用中文：`type(scope): 中文描述`
  - type：`feat` / `fix` / `perf` / `test` / `docs` / `refactor` / `chore`
  - scope：`BlindWatermark` / `BlindWatermarkCore` / `bwdecode` / `Demo` / `skill`
- 一个提交一件事，不夹带无关重排。
- 不提交 `.build/`、`Demo/Demo.xcodeproj/`（已在 `.gitignore`）。
- 默认分支 `main`；改动走分支 + PR，PR 描述写清"解决了什么、如何验证"。

## Skill 规范

- Skill 遵循 [Agent Skills 规范](https://agentskills.io/specification)，放在 **`skills/<name>/SKILL.md`**，不放 `.agents/`。
- 现在有两个 skill，**职责不许重叠**：
  - `blind-watermark`：**解析**（读截图 → uid/时间/build/页面/note、校验分档、排查解不出）
  - `blind-watermark-integration`：**接入**（装水印、造载荷、参数与可见性、接入验收）
  载荷布局是两边共同的契约：改布局必须同时改两个 skill + README 中英。
- `name` 必须等于父目录名（小写字母、数字、连字符）。
- `description` 决定何时被加载，写清"做什么 + 什么时候用"，英文或中文均可但要具体。
- 本地 pi 通过 `.pi/settings.json` 的 `skills: ["../skills"]` 发现；新增 skill 目录即自动生效，无需改配置。
- 参考文档、脚本放 `references/`、`scripts/`，用相对路径引用。

## 文档同步

- `README.md`（中）/ `README.en.md`（英）/ `skills/blind-watermark/SKILL.md` 是**对外契约**
  （接入方 + Agent 都照它做事）。
- 三处内容必须一致：参数、默认值、布局、容量上限、CLI 输出格式、实测数字。中英两份改动要同一次提交做完。
- 实测表格里的数字必须来自本机可复现的测量（注明设备/模拟器版本、平面、delta、样本），不要留过期数字。
