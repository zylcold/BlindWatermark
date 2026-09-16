---
name: blind-watermark
description: 从 iOS 截图中读出屏上盲水印 payload，用于定位截图来自哪台设备、什么时间、什么问题。用户给出截图并要求「读水印」「解析水印」「这截图谁发的」「盲水印」「溯源」「watermark」，或询问水印容量上限、能藏几个字、有哪些限制时使用。
---

# 截图盲水印解析

LoveLink iOS 端会在整个界面上常驻一层肉眼不可见的色度扰动（BlindWatermark，`zylcold/BlindWatermark`）。
截图会把这层扰动带进来，于是**任何一张原始全屏截图都能反查出设备与时间**。

用途：用户甩一张截图过来，先解水印拿到设备/时间线索，再结合代码定位问题。

---

## 一、容量：最多能放多少

**载荷上限就是 32 bit（`UInt32`），这是硬上限，不随屏幕大小变化。**
屏幕越大只是观测次数越多（解得更稳），不是能放更多内容。

32 bit 换算成常见编码：

| 想放的东西 | 上限 | 说明 |
|---|---|---|
| ASCII 字符 | **4 个** | 8 bit/字符 |
| Base32 字符 | **6 个** | 5 bit/字符，30 bit，最推荐 |
| Base64 字符 | **5 个** | 6 bit/字符，30 bit |
| 十进制数字 | **9 位** | `< 10^9` 只占 30 bit |
| UUID | ❌ | 128 bit，装不下 |
| 用户 ID（原样） | ❌ | 除非 ID 本身 ≤ 32 bit，一般是先映射成序号 |

放不下就**不要往水印里塞**。正确做法是水印放一个短序号，把「序号 → 用户/设备/时间」的映射表放服务端。
水印是**定位线索**，不是数据库。

### 推荐的生产布局

把一个 32 bit 切成段，比塞一个语义模糊的大整数好用得多：

```
[31:20] 12 bit  用户序号（最多 4096 个，按注册顺序分配）
[19:10] 10 bit  时间桶，600s 粒度 → 1024 个桶 ≈ 7.1 天环绕
[ 9: 4]  6 bit  App / 端 / 环境标识（可区分百合/佳缘/嗨玩、iOS/Android、内测/正式）
[ 3: 0]  4 bit  版本或随机盐，防跨版本误判
```

时间桶位数按需要的溯源时间窗取舍：**10 bit ≈ 7 天，12 bit ≈ 28 天，14 bit ≈ 113 天，16 bit ≈ 455 天**。
时间窗越长，桶越粗或占位越多，留给用户序号的位就越少。

### 容量与余量的取舍

每个 bit 的观测次数 ≈ `整屏 pair 总数 / payloadBits`。iPhone 16（1179×2556）用 8px 块：

tile 是 256 设备像素，8px 块 → **每 tile 512 个 pair**。

| payloadBits | 每 tile 重复次数 | iPhone 16 上每 bit 观测次数 | 余量 |
|---|---|---|---|
| 32（默认，上限） | 16 | 727 | 充足，chroma 模式下 \|z\| 中位 300+ |
| 16 | 32 | 1455 | 更充足，但只能放 2 个 ASCII 字符 |

实际结论：**32 bit 全用满，余量仍然充裕**，不需要为了余量压缩容量。

---

## 二、怎么用

### 接入端（App 开发）

```swift
import BlindWatermark

// 服务端下发 payload 后装进去；后续新 scene 自动挂载
Watermark.install(payload: serverIssuedPayload)
```

要点：
- 必须用**服务端下发并签名**的 payload。默认布局（IDFV 哈希 + 时间桶）只是 POC，不可逆、可伪造。
- 服务端下发时把「payload → 用户/设备/时间」写进映射表，否则事后拿到数字也定位不到人。
- 时间桶变化后图案要刷新。库只在 App 回前台时重画一次，足够（600s 粒度）。
- 三个参数 **`payloadBits` / `plane` / `delta`，解码端必须与接入端完全一致**。写进 App 的配置，别靠记忆。

### 解码端（本 skill）

解码器在 BlindWatermark 仓库。编译一次：

```bash
BW_REPO=/path/to/BlindWatermark
swift build -c release --package-path "$BW_REPO"
# 产物: $BW_REPO/.build/release/bwdecode
```

```bash
"$BW_REPO/.build/release/bwdecode" /path/to/shot.png
# 需要时: --bits 32 --plane chroma --offset X,Y
```

输出：

```
payload=0x00ABCDEF  高16位=0x00AB  低16位=0xCDEF  payloadBits=32  平面=chroma  相位=(0,0)  signal=9.00  |z|中位=453.1  最弱=58.2  弱bit=0/32  OK(全部 32 bit 显著)
```

| 字段 | 含义 |
|---|---|
| `payload` | 32 bit 原始载荷，按接入端的布局切段解读 |
| `payloadBits` | 有效位数，必须与接入端一致 |
| `平面` | `chroma`（默认，不可见）或 `luma` |
| `相位` | 图案的像素偏移，整屏截图恒为 `(0,0)` |
| `signal` | 平均特征差。chroma 默认参数下约 9；luma 下约等于 delta |
| `\|z\|中位` | 各 bit 显著度中位数。chroma 实测 300+，luma 5~35，无水印约 0.5 |
| `弱bit` | \|z\| < 3 的 bit 数，**判读就看它** |
| 末尾判定 | `OK` 弱 bit=0 可信；`WEAK` ≤4 个弱 bit 要交叉验证；`NO` 大概率没水印 |

### 标准排查流程

1. 先看判定。`NO` → 走下面的排查清单，别硬解读数字。
2. `WEAK` → 结果可能对，但必须结合日志/用户描述交叉验证。
3. `OK` → 核对 `signal` 与平面是否自洽（chroma 约 9，luma 约等于 delta）。明显偏离说明图案没对上或 `--plane` 给错。
4. 按接入端的布局切段，拿到用户序号/时间桶。
5. 时间桶 → 时间范围（见下）。用户序号 → 查服务端映射表。
6. 用设备与时间去日志/Sentry 里定位问题。

**时间桶 → 时间范围**（默认 600s 粒度，桶序号低 16 位）：

```bash
python3 -c "
import datetime, sys
b = int(sys.argv[1], 16)
print(datetime.datetime.utcfromtimestamp(b * 600), '~', datetime.datetime.utcfromtimestamp(b * 600 + 600))
" 0xCDEF
```

桶位数不是 16 时先按布局取出来再换算。**桶序号每 `2^位数` 个环绕一次**（16 bit ≈ 455 天，10 bit ≈ 7 天），
解出来的桶值明显大于近期取值时说明落在一圈之前，别当成未来时间。

### 直接调用 API

```swift
import BlindWatermarkCore

let image = RGBAImage(cgImage: cgImage)!
let result = BlockCodec.decode(image, payloadBits: 32, plane: .chroma)
print(result.payload, result.confidence, result.weakBits)
```

---

## 三、限制

### 拿不到水印的情况

| 情况 | 结果 | 处理 |
|---|---|---|
| **截图被缩放过**（微信转发、聊天软件压缩、任何 resize） | ❌ 完全解不出 | 块边长与平铺周期一起变了。让用户重发**原图** |
| **拍屏**（另一台手机拍屏幕） | ❌ 解不出 | 摩尔纹 + 几何畸变。需要同步模板或深度学习方案，本仓库不做 |
| 截图被裁剪（裁掉状态栏等） | ⚠️ 需要补偿 | 给 `--offset`。裁掉顶部 H 像素 → `--offset 0,-H` |
| 非整屏截图（只截一部分区域） | ⚠️ 需要补偿 | 同上，给裁剪原点相对整屏的偏移 |
| 画面里根本没有水印（系统界面、别的 App） | `NO` | 正常，`\|z\|` 中位约 0.5、弱 bit 32/32 |
| 色度结构恰好是 8px 尺度的画面（对抗样本） | ⚠️ 退化 | 必须判成 `WEAK`/`NO`，不允许静默给错结果（有测试兜底） |

### 参数必须对齐，否则会静默解错

`payloadBits` 给错时，bit 的分组方式变了，结果是一份**自洽但错误**的载荷 —— 置信度可能依然很高。
`plane` 给错通常直接判 `NO`。所以解读之前**先确认接入端用的参数**，不要靠默认值蒙。

### 默认 payload 的问题

`(FNV-1a(identifierForVendor) & 0xFFFF) << 16 | 时间桶` 这套默认布局：

- 设备哈希**不可逆**，没有映射表就定位不到任何东西
- **没有签名，可以伪造** —— 攻击者可以埋一个栽赃别人的 payload
- 上生产必须换成服务端下发并签名的载荷

### 其他

- 水印窗口 `windowLevel = .alert + 1`，盖在系统弹窗之上；`isUserInteractionEnabled = false`，不影响输入。
- iPad 分屏、外接屏每个 scene 各挂一个窗口，已处理；displayScale 中途变化不会重画图案。
- 色彩管理：截图若经过 sRGB/P3 转换，chroma 模式比 luma 模式更抗（亮度不变性）。
- 平坦区域亮度残差 0.07/255（chroma 模式），肉眼看不出；luma 模式是 6/255，能看出网格。

---

## 四、合规

水印携带设备与时间信息，属个人信息处理。只在**处理用户已上报的问题**时使用，
不要把 payload 与设备身份绑定后另作追踪，也不要外传映射表。
