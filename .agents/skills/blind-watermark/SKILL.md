---
name: blind-watermark
description: 从 iOS 截图中读出屏上盲水印 payload，用于定位截图来自哪台设备、什么时间、什么问题。用户给出截图并要求「读水印」「解析水印」「这截图谁发的」「盲水印」「溯源」「watermark」，或询问水印容量上限、能藏几个字、有哪些限制时使用。
---

# 截图盲水印解析

LoveLink iOS 端会在整个界面上常驻一层肉眼不可见的色度扰动（BlindWatermark，`zylcold/BlindWatermark`）。
截图会把这层扰动带进来，于是**任何一张原始全屏截图都能反查出设备与时间**。

用途：用户甩一张截图过来，先解水印拿到设备/时间线索，再结合代码定位问题。

---

## 一、容量：128 bit，uid + 时间戳 + 页面 + 校验一次装下

载荷上限 **256 bit**（每 tile 只重复 2 份，刚好还够翻转极性用），推荐 **128 bit**。
标准布局是 `WatermarkPayload`，字段全小端：

```
[127:96] uid        UInt32   用户 ID 原样放，不用截断、不用查表
[ 95:64] timestamp  UInt32   Unix 秒，精确到秒且够用到 2106 年 —— 不用再换算时间桶
[ 63:48] pageIndex  UInt16   页面注册表索引，最多 65536 个受监控页面
[ 47:44] magic      UInt4    固定为 0xA（1010b），解码端用 hasMagic 校验 payloadBits 是否与编码端一致
[ 43:32] appTag     UInt12   App / 端 / 环境 标识，最多 4096 个枚举值
[ 31: 0] mac        UInt32   HMAC-SHA256(前 12 字节, 服务端密钥) 截断；无后端时填 0
```

`magic` 是自检机制：解码输出中 `magic=OK` 表示 `payloadBits` 与编码端一致；`magic=BAD` 说明位数传错或图中无水印，其余字段不可信。

换算成字符量的话 128 bit ≈ 16 个 ASCII 字符，但**不要存字符串** —— 用上面的字段化布局。

### 页面类名怎么进来

`pageIndex` 不是类名（32 字节装不下字符串）。做法：接入端维护「索引 → 类名」注册表，
页面出现时 `Watermark.update(payload:)` 重画图案（相位不变，解码端无感，微秒级）。
解码后拿索引查同一张表还原类名。**没有注册表就只能拿到一个数字**，接这类工单前先要到表。

### 密钥归属

**密钥只在服务端持有**：服务端算好 mac 下发完整 16 字节，客户端只负责渲染；解码端 `--key` 校验。
客户端自己算 mac 等于把密钥交出去。32 bit mac 挡顺手伪造（单次命中 1/2³²），
挡不住针对性碰撞 —— 对抗强攻击就别塞业务字段，整个载荷做服务端票据。

### 余量（实测，chroma，iPhone 16，弱 bit 全部 0/128）

| 页面 | \|z\|中位 | 最弱 |
|---|---|---|
| text（最差场景） | 227.8 | 16.5 |
| photo | 111.6 | 23.9 |

阈值 3，余量 30 倍以上。tile 是 256 设备像素 / 8px 块 → **每 tile 512 个 pair**，
128 bit 每 tile 重复 4 份，iPhone 16 截图上每 bit 约 182 次观测。

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
"$BW_REPO/.build/release/bwdecode" shot.png --layout --key <服务端密钥hex>
# 完整参数: --bits 128 --plane chroma --offset X,Y --auto-offset --layout --key <hex>
```

输出（两行）：

```
payload=0xefbeadde123baa6a02000100a56d00a5  payloadBits=128  平面=chroma  相位=(0,0)  signal=9.00  |z|中位=227.8  最弱=16.5  弱bit=0/128  OK(全部 128 bit 显著)
uid=3735928559(0xDEADBEEF)  time=2026-09-16 06:45:38 UTC  pageIndex=2  appTag=1(0x001)  magic=OK  mac=未校验(需要 --key)
```

| 字段 | 含义 |
|---|---|
| `payload` | 原始载荷 hex，小端字节序 |
| `payloadBits` | 有效位数，必须与接入端一致 |
| `平面` | `chroma`（默认，不可见）或 `luma` |
| `相位` | 图案的像素偏移，整屏截图恒为 `(0,0)` |
| `signal` | 平均特征差。chroma 默认参数下约 9 |
| `\|z\|中位` / `最弱` | 各 bit 显著度。128 bit 下实测中位 100~230，无水印约 0.5 |
| `弱bit` | \|z\| < 3 的 bit 数，**判读就看它** |
| `uid` / `time` / `pageIndex` / `appTag` | `--layout` 解出的字段 |
| `magic` | `OK` = payloadBits 与编码端一致；`BAD` = 位数传错或图中无水印，其余字段不可信 |
| `mac` | `--key` 给了则校验：`OK` / `BAD` / `未校验` |
| 末尾判定 | `OK` 弱 bit=0 可信；`WEAK` ≤1/8 弱 bit 要交叉验证；`NO` 大概率没水印 |

### 标准排查流程

1. 先看判定。`NO` → 走下面的排查清单，别硬解读数字。
2. `WEAK` → 结果可能对，但必须结合日志/用户描述交叉验证。
3. `OK` → 核对 `signal` 与平面是否自洽（chroma 约 9，luma 约等于 delta）。明显偏离说明图案没对上或 `--plane` 给错。
4. 加 `--layout` 解出 uid / time / pageIndex / appTag，先看 `magic=OK`；`magic=BAD` 说明位数传错。
5. `pageIndex` 查接入端的页面注册表还原类名 —— 没表就只有数字。
6. uid + time 直接去日志/Sentry 定位问题。旧版 32 bit 布局才需要换算时间桶，128 bit 布局的时间戳
   已经是 Unix 秒，`--layout` 直接给出可读时间，不用再算环绕。

### 直接调用 API

```swift
import BlindWatermarkCore

let image = RGBAImage(cgImage: cgImage)!
let result = BlockCodec.decode(image, payloadBits: 128, plane: .chroma)!
print(result.payloadBytes)                       // 16 字节
let fields = WatermarkPayload(bytes: result.payloadBytes)  // uid / timestamp / pageIndex / appTag / mac
// fields.hasMagic → true 说明 payloadBits 与编码端一致
```

---

## 三、限制

### 拿不到水印的情况

| 情况 | 结果 | 处理 |
|---|---|---|
| **截图被缩放过**（微信转发、聊天软件压缩、任何 resize） | ❌ 完全解不出 | 块边长与平铺周期一起变了。让用户重发**原图** |
| **拍屏**（另一台手机拍屏幕） | ❌ 解不出 | 摩尔纹 + 几何畸变。需要同步模板或深度学习方案，本仓库不做 |
| 截图被裁剪（裁掉状态栏等） | ⚠️ 需要补偿 | 先用 `--auto-offset` 自动搜索相位；或手动给 `--offset`，裁掉顶部 H 像素 → `--offset 0,-H` |
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
