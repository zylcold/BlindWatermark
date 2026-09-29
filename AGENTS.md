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
swift build
swift test
swift run bwdecode shot.jpg --layout
swift run bwdecode shot.jpg --layout --scale 0.837
python3 tools/test_bwdecode.py
Demo/sweep.sh <UDID> 4 chroma
python3 tools/benchmark_v6.py --input-dir /private/tmp/bw-v6-demo-samples
python3 tools/benchmark_channels.py --input-dir /private/tmp/bw-v6-demo-samples --automatic
```

## 硬约束

- 不新增第三方运行时依赖。Swift 只用系统框架；Python工具沿用numpy/Pillow。
- iOS13/macOS11，Demo iOS15。新增API必须满足可用性。
- **3.0.0 仅支持 v6**，按用户要求删除旧兼容代码。历史截图需旧版本工具，不新增v4/v5.2回退。
- v6 信息字段211bit/27字节：profile4(6)+uid32+timestamp31+buildTime24+page42+app14+note32+CRC24+reserved8(0)，末字节高5位全0。时间是UTC2026-01-01起的秒/分钟偏移。page8、note6用base37 `a-z0-9_`，首字符高位radix digit，右补`_`并去尾补位；app0…9999。非法profile/radix/reserved/padding/CRC必须拒绝。
- BCH(511,211,t40)使用GF(512) primitive0x211、roots1…80，300位校验加211位信息，再追加一位整体偶校验得到512位。纠错诊断可含额外整体偶校验位，但不能称t41。
- tile544×512px，cell32×8px，17列×64行；16列数据（两份512位不同交织副本），最后1列是64位独立色度同步。码字索引/极性/导频序列/常量必须两端一致。
- 默认delta4、chroma。整层RGBA恒定预乘alpha；伴色只能减小亮度残差，色度仍可见。luma是实验档。不得未经目标真机人工验收称不可见。改默认值要实测并同步文档/skill。
- CRC24只是完整性自检，不是验签，不是身份认证。输出为`crcStatus=OK(完整性自检,未验签)`，没有HMAC或`mac=`。
- **每个码字bit物理观测≥5**才解读字段，不允许CRC例外。量化为0的非重叠cell计数但其信号贡献为0，不伪造方向/置信度。证据计数只包含完整落在内容矩形内的 cell：由 RGB 非均匀行列确定矩形，排除外侧完全均匀的 padding，不改变坐标或信号统计；内部 JPEG 零差分仍计数。该规则不保证识别纹理框或任意无水印区域。不足报TOO_SMALL及minObs/avgObs/|z|中位，带--layoutexit1、无字段；不带只诊断警告。
- 没有BCH+CRC-valid载荷报NO，多个不同有效载荷报ambiguous并拒答。有限Chase在低可靠6位上翻1/2位，收集全部所搜索候选再去重。不能首个CRC通过立即返回。
- 解码 API 与 CLI 的有效 scale 范围均为闭区间 0.5…1.5；非有限或越界参数提前拒绝。有限 Chase 的两个重试候选按各自实际 pilotScore 降序选取，同分保留原顺序。
- 默认几何搜索先1.0、再0.50…1.50共21档与图像跨度决定的局部精搜。粗筛按比例留最佳相位，避免同一比例挤满候选；0.837/1.173是回归比例。性能必须实测，不给推测倍数。
- 显式--offset只允许非负有限像素相位，关闭黑边裁剪；未指定先裁再搜，phase相对裁后图。Swift/Python黑边阈值同义：近黑32、覆盖0.90、单边上限25%、内侧亮探针≥96且占比0.30、深度8。深色页面不能为了出结果强制裁掉。
- 主色度通道无有效载荷时，解码器会尝试已有 R/G 伴色残差，成功时报告 `companionRecovery=true`。这只改变解码，不提高渲染强度；小图和多载荷拒答仍保留。伴色特征 `-(R+G)/2` 只作用于 chroma 渲染；同一物理 cell 不因多通道重复计数。伴色排除内容矩形外 cell，局部细搜 x±2/±1/0、y±1/±0.5/0，按 cell 周期环绕；两端同步。
- 条码层（「抗微信压缩」档）默认开启：顶部/底部各 1pt 亮度条，**顶底同载荷**，按屏宽选档（identity 76 / buildDay 91 / full 123 bit，解码端 CRC 试解区分，tier0 与 3.1.0 逐位兼容）；块亮度 205/245，块宽 = floor(widthPx/档位 bit) 且 ≥ 9px（实测 8px 在 q60+0.685 失败）。阈值必须用 Otsu：实测顶部条最前 4 像素被系统内容盖住，min/max 中点与 k-means 都会把暗块整批判亮。条码渲染用 `UIColor(patternImage:)`，**不能用 `CALayer.contents`**（实测不合成）。解码用未裁边原图；双条载荷一致才采信，单边只收 fixedBits=0 且复核误差≤4 的精确解；弱块纠错只翻 CRC 段（60..<76）不碰载荷区；复核误差>13 拒答。**宁缺毋假：不允许为出 uid 降低门槛**。Swift `StripWatermark` 与 `tools/bwdecode.py` 同步。`expect` 子命令回显写入原始值（build 原样，不转时区）。详见 `docs/strip-watermark.md`。
- 修改公共API与非平凡逻辑带可运行验证；编解码修改同步`V6Codec.swift`、`V6BCH.swift`与`tools/bwdecode.py`。swift test及python3 tools/test_bwdecode.py全绿，并同图对账。
- 验证包括原始设备像素截图、裁切/缩放/压缩/黑白边框的组合链路、小图拒答和无水印负样本。模拟器/Pillow结果不等于真机或实际IM转发验收。
- 改布局破坏历史截图兼容，必须明说影响并同步README中英、解析和接入两个skill。

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
