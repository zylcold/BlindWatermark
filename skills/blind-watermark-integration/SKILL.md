---
name: blind-watermark-integration
license: MIT
description: 在 iOS App 中接入 v6 离线截图水印，构造类型化载荷、配置色度载波，并验证裁切、缩放、压缩和边框链路及实际可见性。用户要求装水印、调参数、提高转发识别率或接入验收时使用。只读截图使用 blind-watermark。
---

# v6 接入与验收

3.0.0 仅支持 v6，删除旧编解码与 raw-bit/HMAC/注册表 API。迁移影响历史截图，必须说明它们要用旧工具；v6 字段不包含旧 v4 构建号、tag 或自由文本 note。只用系统框架，iOS13/macOS11，Demo iOS15，不新增运行时依赖。

```swift
import BlindWatermark
// 主线程；buildTime 由构建流水线提供 UTC Unix 秒。
guard let payload = WatermarkPayload(
    uid: uid, timestamp: timestamp, buildTime: buildTime,
    pageClassName: type(of: self).description(), app: 11, note: "ticket"
) else { fatalError("无效 v6 载荷") }
Watermark.install(payload: payload) // delta=4 / .chroma / strip=.topAndBottom（默认）
// 只要 v6 色度层（关闭条码）：Watermark.install(payload: payload, strip: .off)
// 换页/更新时构造新值
Watermark.update(payload: payload)
```

211 bit 字段：profile4(6)+uid32+UTC2026-01-01秒偏移31+同起点构建分钟偏移24+page8/base37 42+app14(0…9999)+note6/base37 32+CRC24+reserved8(0)。存储27字节末高5位为0。base37为 `a-z0-9_`，首字符高位digit，右补 `_`、解码去尾补位。pageClassName归一化后截8字符，可能碰撞；显式pageCode/noteCode非法或超长拒绝，note不接受中文/自由文本。CRC只是完整性自检，不是验签。

BCH(511,211,t40)+偶校验形成512位码字，544×512px tile里两份不同交织副本，cell32×8px正弦载波，最后一列64cell是独立色度同步。默认delta4，整层预乘RGBA恒alpha，伴色减小亮度残差；不能把delta理解成简单色度加法，更不能称不可见。luma仅实验。调delta后需重新验收最暗页面、纯色和照片；未经真机人工验收不宣称观感通过。

保留 ObjC +load 零接入：默认 uid=IDFV FNV-1a哈希、时间=刷新时间、buildTime=协议起点、page/note空、app0。正式业务显式提供全部字段，或者未install时用主线程 `Watermark.payloadProvider` 返回类型化值，每次刷新取新载荷。显式install后update负责更新；库不自动推断当前页面或真实构建时间。

「抗微信压缩」条码层默认开启（`strip: .topAndBottom`）：顶部/底部各 1pt 可见亮度条，按屏宽自动选档 —— 1320px(3x/440pt) 与 1125px(3x/375pt) 选 `full`（uid+分钟+buildDay+page，123 bit），828px(2x/414pt) 选 `buildDay`（91 bit），750px 选 `identity`（76 bit），<684px 不画。块宽 = floor(widthPx/档位 bit)，不低于 9px。它抗缩放/强压缩、裁切即失效，与 v6 互补；关闭传 `.off`。条码**是可见的**，接入验收必须包含目标设备深色/浅色页面顶部与底部观感确认；解码端对账用 `bwdecode expect` 回显原始 JSON（`--build` 原样返回、`--build-day` 为条码天数），并用 `--strip-only` 复测 IM 转发链路。渲染必须用 `UIView` + `UIColor(patternImage:)`：实测同一份内容用 `CALayer.contents` 在该工程里不合成。契约见 [条码协议](../../docs/strip-watermark.md)。

验收必须包括实际渲染和传播链路，不能仅看完整PNG：

```bash
swift test
python3 tools/test_bwdecode.py
Demo/sweep.sh <已启动模拟器UDID> 4 chroma
python3 tools/benchmark_v6.py --input-dir /private/tmp/bw-v6-demo-samples
python3 tools/benchmark_channels.py --input-dir /private/tmp/bw-v6-demo-samples --automatic
```

sweep使用XcodeBuildMCP和sim-use原始像素截图，需要预先安装和授权设备。对纯色/聊天/文字/照片/深色/混排各自测试；原图、裁切、两次JPEG、0.837/1.173非粗网格比例、黑/白边框应组合测试并核对全部字段。深色内容不能被黑边规则误删，小图须拒答。实际IM转发还要用目标客户端人工转发的文件复测，Pillow质量系数不代表微信内部参数。

解码 API 与 CLI 的有效 scale 范围均为闭区间 0.5…1.5；非有限或越界参数提前拒绝。有限 Chase 的两个重试候选按各自实际 pilotScore 降序选取，同分保留原顺序。

最少5次不重叠物理cell观测与BCH/CRC/合法字段必须同时满足。量化为0的cell仍计数但信号为0。证据计数只包含完整落在内容矩形内的 cell：由 RGB 非均匀行列确定矩形，排除外侧完全均匀的 padding，不改变坐标或信号统计；内部 JPEG 零差分仍计数。该规则不保证识别纹理框或任意无水印区域。不得用CRC通过绕过TOO_SMALL，不得多候选首个即返回。解码报 `crcStatus=OK(完整性自检,未验签)`，不报mac。

编解码逻辑变更同步Swift/Python，布局/参数变更同步README中英和两个skill，并更新黄金向量及可复现测试。实际数字和边界见 [协议记录](../../docs/v6-protocol.md)。截图解析流程见 [解析 skill](../blind-watermark/SKILL.md)，此处只负责接入与验收。

主色度通道无有效载荷时，解码器会尝试已有 R/G 伴色残差，成功时报告 `companionRecovery=true`。这只改变解码，不提高渲染强度；小图和多载荷拒答仍保留。伴色特征为 `-(R+G)/2`，仅适用于 chroma 渲染；排除内容矩形外的 cell 参与伴色判位和导频统计。备用通道局部细搜为 x±2/±1/0、y±1/±0.5/0，并按 cell 周期环绕相位。观测门槛仍是同一组物理 cell，不累加两个通道的观测。

真实转发前后对比：`python3 tools/benchmark_pair.py --original 原文件.jpg --compressed 转发后.jpg --output /private/tmp/pair.json`。只保存尺寸、JPEG参数和恢复统计；用户图片及其载荷不纳入公开样本。实测范围见 [微信恢复分析](../../docs/wechat-recovery.md)。
