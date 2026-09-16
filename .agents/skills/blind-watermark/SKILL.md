---
name: blind-watermark
description: 从 iOS 截图中读出屏上盲水印 payload，用于定位截图来自哪台设备、什么时间、什么问题。用户给出截图并要求「读水印」「解析水印」「这截图谁发的」「盲水印」「溯源」「watermark」时使用；拿到 payload 后按本文说明换算时间桶、查设备映射表。
---

# 截图盲水印解析

LoveLink iOS 端会在整个界面上常驻一层肉眼不可见的亮度扰动（BlindWatermark，`zylcold/BlindWatermark`）。
截图会把这层扰动带进来，于是**任何一张原始全屏截图都能反查出设备与时间**。

用途：用户甩一张截图过来，先解水印拿到设备/时间线索，再结合代码定位问题。

## 前置

解码器在 BlindWatermark 仓库里。先编译一次（约 10 秒）：

```bash
BW_REPO=/path/to/BlindWatermark
swift build -c release --package-path "$BW_REPO"
# 产物: $BW_REPO/.build/release/bwdecode
```

没编译过也可以直接跑（慢一些）：

```bash
swift run -c release --package-path "$BW_REPO" bwdecode <截图路径>
```

## 解码

```bash
"$BW_REPO/.build/release/bwdecode" /path/to/shot.png
```

输出：

```
payload=0x00ABCDEF  高16位=0x00AB  低16位=0xCDEF  payloadBits=32  平面=chroma  相位=(0,0)  signal=9.00  |z|中位=453.1  最弱=58.2  弱bit=0/32  OK(全部 32 bit 显著)
```

| 字段 | 含义 |
|---|---|
| `payload` | 32 bit 原始载荷 |
| `高16位` | 默认布局下是设备标识哈希 |
| `低16位` | 默认布局下是时间桶序号 |
| `平面` | 水印压在哪个平面，默认 `chroma`。必须与打水印端一致 |
| `signal` | 平均特征差，chroma 模式默认参数下约 9，luma 模式约等于 delta |
| `\|z\|中位` | 各 bit 显著度中位数。chroma 模式实测 300+，luma 模式 5~35，无水印约 0.5 |
| `弱bit` | \|z\| < 3 的 bit 个数，**判读就看它** |
| 末尾判定 | `OK` 弱 bit=0，结论可信；`WEAK` ≤4 个弱 bit，要交叉验证；`NO` 大概率没水印 |

## 解读 payload（默认布局）

默认布局是 `(设备哈希 << 16) | 时间桶`，时间桶粒度 600 秒。

**时间桶 → 时间范围**（UTC）：

```bash
python3 -c "
import datetime, sys
b = int(sys.argv[1], 16)
print(datetime.datetime.utcfromtimestamp(b * 600), '~', datetime.datetime.utcfromtimestamp(b * 600 + 600))
" 0xCDEF
```

注意：16 bit 桶序号每 `65536 × 600s ≈ 455 天` 环绕一次。桶值明显大于近期取值时，
说明落在一圈之前，别当成未来时间。

**设备哈希 → 设备**：哈希是 FNV-1a 截断，**不可逆**，必须查映射表。
生产环境的 App 应当通过 `Watermark.payloadProvider` 换成服务端下发、可查表的 payload。
如果目标 App 换了 payload 布局，先看它的接入代码，不要照搬上面的默认解读。

## 排查顺序

1. `NO` / 弱 bit 很多 → 先怀疑图片本身：
   - **必须用原始全屏截图**。缩放、二次转发、微信压缩都会改块边长与平铺周期，直接解不出来。
   - 截图被裁过（比如裁掉状态栏）→ 手动给相位：`--offset 0,-<裁掉的高度>`。
   - 图片是转发来的缩略图 → 让用户重发原图。
   - 试一下另一个平面：`--plane luma`（默认是 `chroma`）。
2. `WEAK` → 结果可能对，但不要单凭它下结论；结合日志/用户描述交叉验证。
3. `OK` 也要核对 `signal` 与平面是否自洽：chroma 默认参数下应约 9，luma 下应约等于 delta。
   明显偏离说明图案没对上，或 `--plane` 给错了（给错平面通常会直接判 NO）。
4. 解出来但 payload 看着不像预期布局 → 看目标 App 的 `payloadProvider` 与 `payloadBits` 设置，
   必要时用 `--bits N` 对齐位数。

## 直接调用 API（不经过命令行）

```swift
import BlindWatermarkCore

let image = RGBAImage(cgImage: cgImage)!
let result = BlockCodec.decode(image)          // payloadBits 需与打水印端一致
print(result.payload, result.confidence)
```

## 合规

水印用于定位用户设备与时间，属个人信息处理。只在**处理用户已上报的问题**时使用，
不要把 payload 与设备身份绑定后另作追踪，也不要外传映射表。
