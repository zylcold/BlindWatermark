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
```

## 常用命令

```bash
swift build                          # 编译全部 target
swift test                           # 跑核心测试，macOS 本机即可，不需要模拟器
swift run bwdecode shot.png --layout --key <hex> --pages Demo/pages.json
Demo/sweep.sh [模拟器UDID] [delta] [luma|chroma]   # 逐页截图解码对比，需 xcodegen + 已启动模拟器
```

## 硬约束

- **不新增第三方依赖。** 只用系统框架：Accelerate、CryptoKit、CoreGraphics、UIKit。
- **平台下限 iOS 13 / macOS 11**（Demo 是 iOS 15）。用到的新 API 必须满足可用性，必要时 `@available` 兜底。
- **编解码参数必须两端一致**：`payloadBits` / `plane` / `offset` / 载荷布局。任何一项不一致都会解出自洽但错误的结果。
- **改载荷布局 = 破坏历史截图兼容。** 必须显式说明影响面，并同步 `README.md` 与 `skills/blind-watermark/SKILL.md`。
- **改公共 API 语义必须带测试**，且 `swift test` 全绿才算完成。
- **非平凡逻辑留一个可运行校验**（单元测试或 assert 自检），不靠"我推理过"。
- **性能结论要实测。** 不接受"预期 4–8x"这类没测过的数字；写实测值并注明测量条件（设备/模拟器、模式、样本）。
- **不要静默降级**：解码置信度不足时按 `弱 bit` 规则如实报 `WEAK` / `NO`，不硬凑一个结果。

## 代码风格

- Swift，4 空格缩进，无分号，单文件不超过必要长度。
- 注释写**为什么**（尤其是反直觉的取整、极性翻转、阈值来源），不复述代码在做什么。
- 阈值 / 调参常量提成 `static let` 并注明来源（实测数据），不在函数体里撒魔法数字。
- 指针与 Accelerate 代码：显式检查长度不变量与越界边界，注释标出 stride 语义。

## 提交规范

- Conventional Commits，描述用中文：`type(scope): 中文描述`
  - type：`feat` / `fix` / `perf` / `test` / `docs` / `refactor` / `chore`
  - scope：`BlindWatermark` / `BlindWatermarkCore` / `bwdecode` / `Demo` / `skill`
- 一个提交一件事，不夹带无关重排。
- 不提交 `.build/`、`Demo/Demo.xcodeproj/`（已在 `.gitignore`）。
- 默认分支 `main`；改动走分支 + PR，PR 描述写清"解决了什么、如何验证"。

## Skill 规范

- Skill 遵循 [Agent Skills 规范](https://agentskills.io/specification)，放在 **`skills/<name>/SKILL.md`**，不放 `.agents/`。
- `name` 必须等于父目录名（小写字母、数字、连字符）。
- `description` 决定何时被加载，写清"做什么 + 什么时候用"，英文或中文均可但要具体。
- 本地 pi 通过 `.pi/settings.json` 的 `skills: ["../skills"]` 发现；新增 skill 目录即自动生效，无需改配置。
- 参考文档、脚本放 `references/`、`scripts/`，用相对路径引用。

## 文档同步

- `README.md` 与 `skills/blind-watermark/SKILL.md` 是**对外契约**（接入方 + Agent 都照它做事）。
- 参数、默认值、布局、容量上限、CLI 输出格式变了，两处必须同步改；文档里不要留过期数字。
