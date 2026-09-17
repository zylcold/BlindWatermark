---
name: blind-watermark
license: MIT
description: 从 iOS 截图中读出屏上盲水印 payload，用于定位截图来自哪台设备、什么时间、什么问题。用户给出截图并要求「读水印」「解析水印」「这截图谁发的」「盲水印」「溯源」「watermark」，或询问水印容量上限、能藏几个字、有哪些限制时使用。
---

# 截图盲水印解析

LoveLink iOS 端在整个界面上常驻一层肉眼不可见的色度扰动（BlindWatermark，`zylcold/BlindWatermark`）。
截图会把这层扰动带进来，于是**任何一张原始全屏截图都能反查出设备、时间与页面**。

用途：用户甩一张截图过来，先解水印拿到设备/时间线索，再结合代码定位问题。

**最短路径**（有 `--key` 时）：

```bash
BW_REPO=/path/to/BlindWatermark
swift build -c release --package-path "$BW_REPO"
"$BW_REPO/.build/release/bwdecode" shot.png --auto --layout --pages pages.json --key <hex>
```

`mac=OK` → 结论可直接用，拿 uid / time / page 去查日志。`mac=BAD` 或 `NO` → 见[限制](#三限制)与[排查](#标准排查流程)。

---

## 一、容量：256 bit = uid + Unix 秒 + 页面短码 + 校验

```
[255:224] uid        32   UInt32   用户 ID 原样放，不用截断、不用查表
[223:192] timestamp  32   UInt32   Unix 秒，精确到秒且够用到 2106 年
[191:128] pageCode   64   UInt64   页面类名短码，10 个字符（见下）
[127: 96] tag        32   UInt32   布局版本(4bit) / App(8bit) / 环境(8bit) / 保留
[ 95:  0] mac        96            HMAC-SHA256(前 20 字节, 服务端密钥) 截断
```

32 字节，字段全小端。**256 bit 是上限**：每 tile 512 个 pair，此时每 tile 重复 2 份；
再大重复次数降到 1，「隔一份翻转极性抵消亮度梯度」的机制就失效了。

iPhone 16 截图（1179×2556）下每 bit 约 90 次观测。

### 页面类名怎么进来：短码 + grep

水印里放的是**从类名算出来的 10 字符短码**，不是索引、更不是完整类名（装不下）。
它利用 iOS 命名的高冗余，把 `ViewController` 这类每个页面都有的词缀剥掉：

```
BHProfileViewController        → profile
BHChatListViewController       → chatlist
BHLiveRoomViewController       → liveroom
BHUserProfileEditViewController → userprofil   （超过 10 字符才截断）
```

拿到短码后 `grep -rin "class.*chatlist" --include='*.swift'` 就能定位类名 —— **不需要注册表**。
真撞名了也只是拿到 2~3 个候选，结合截图内容判断即可（4 字符时 1000 个页面撞名概率 23%，
所以扩到了 10 字符：那个数量级下撞名概率可忽略）。

算法（`PageNameCodec`，编解码只有这一份实现）：
1. 取类名最后一段（丢掉 `Module.` 前缀）
2. 按长度降序剥**词尾**后缀，最多两层：`ViewController` / `ViewModel` / `Presenter` /
   `Interactor` / `Controller` / `View` / `Page` / `Screen` / `Scene` / `Cell` / `Item` / `Model` / `VC`
3. 剥已知 App 前缀：`BH` / `JY` / `LL` / `HW` / `XQ`
4. 转小写，只留 `a-z0-9`
5. 取前 10 字符，每字符 6 bit 打包（37 符号表，补位符 `_`）

页面变化时 `Watermark.update(payload:)` 重画图案（相位不变，解码端无感，微秒级）。

### 密钥归属

**密钥只在服务端持有**：服务端算好 mac 下发完整 32 字节，客户端只负责渲染；解码端 `--key` 校验。
客户端自己算 mac 等于把密钥交出去。96 bit mac 已足够挡住伪造与针对性碰撞。

### 余量（实测，chroma + delta 8，iPhone 16 模拟器，256 bit 布局）

| 页面 | \|z\|中位 | 最弱 | 弱 bit |
|---|---|---|---|
| plain（近纯色渐变） | 161.3 | 10.6 | 0/256 |
| whitechat（纯白 + 气泡文字） | 161.0 | 9.8 | 0/256 |
| textlist（文字密集，最差场景） | 161.3 | 6.7 | 0/256 |
| photogrid（照片网格） | 28.8 | 8.0 | 0/256 |
| darkmode（深色卡片） | 161.0 | 4.9 | 0/256 |
| mixedfeed（上白下黑 + 照片） | 160.6 | 4.8 | 0/256 |

阈值 3，余量 1.6~3.5 倍。色度平面上灰阶内容恒为零，所以文字页与纯色页的 `|z|` 同样高，
只有大面积彩色照片会把 `|z|` 拉低。若某张图出现十几个弱 bit，通常是截断/压缩痕迹，结合 MAC 判断 ——
**MAC 通过就是对的，弱 bit 多只说明余量小**。

## 二、怎么用

### 接入端（App 开发）

```swift
import BlindWatermark

// 服务端下发 payload 后装进去；后续新 scene 自动挂载
Watermark.install(payload: serverIssuedPayload)
```

要点：
- 必须用**服务端下发并签名**的 payload。默认布局（IDFV 哈希 + Unix 秒）只是 POC，不可逆、可伪造。
- 服务端下发时把「payload → 用户/设备/时间」写进映射表，否则事后拿到数字也定位不到人。
- 载荷里的时间戳每次都变，图案要刷新。库只在 App 回前台时重画一次，够用。
- 三个参数 **`payloadBits` / `plane` / `delta`，解码端必须与接入端完全一致**。写进 App 的配置，别靠记忆。

### 解码端（本 skill）

```bash
# 常规（最快，0.08s）
"$BW_REPO/.build/release/bwdecode" shot.png --layout --pages pages.json --key <hex>
# 截图被裁过 / 不确定平面与位数（0.1s，穷举 + MAC 裁决）
"$BW_REPO/.build/release/bwdecode" shot.png --auto --layout --pages pages.json --key <hex>

# 平面 / 位数确定，只是相位不确定（裁边但没缩放过）
"$BW_REPO/.build/release/bwdecode" shot.png --auto-offset --layout --pages pages.json --key <hex>

# 对照注册表里的短码
"$BW_REPO/.build/release/bwdecode" --pages pages.json --dump-codes
```

**优先用 `--auto` 并带上 `--key`。** 裁剪过的图（截掉状态栏、分享时裁边）会让载荷整体**旋转**
却依然自洽：`|z|` 中位依然很高、弱 bit 0/256，输出看着完全正常，但 uid/时间/页面全是错的。
`--auto` 穷举 2 平面 × 64 相位 × 512 tile 平移（位数只加显式给的 `--bits`），只有 MAC 能识别出正确那一组。
纵向、横向裁剪都覆盖（横向平移按行列分别回卷，不是线性索引）。
没有 `--key` 时 `--auto` 只能用时间戳合理性做弱校验，可靠性差一个档次 —— **能要到密钥就去要。**

`--auto-offset` 是它的收窄版：假定 `--bits` / `--plane` 已经给对（默认 256 / chroma），只穷举
**块网格相位（mod 8）**这个自由度；**只有给了 `--key` 才额外穷举 512 tile 平移**（用 MAC 裁决）。
它与 `--offset` 互斥（同时给直接报错退出），与 `--auto` 语义重叠（也别一起给）。
没给 `--key` 时它没有校验器可用，只搜块网格相位、平移恒 0，**非整 tile 倍数的裁剪（平移）解不了**，
只能按 `|z|` 中位裁决 —— stderr 会打印警告，输出**不保证正确**，这时必须看 `弱bit`，并用 `--layout` 检查字段是否合理。
**要覆盖裁剪平移必须给 `--key`。**

输出（两行）：

```
payload=0xefbeaddea048aa6acfe14c8e112103090000103059f32c1304708e9619bdb73c  payloadBits=256  平面=chroma  相位=(0,7)  signal=9.17  |z|中位=35.5  最弱=10.0  弱bit=0/256  OK(全部 256 bit 显著)
uid=3735928559(0xDEADBEEF)  time=2026-09-16 07:43:28 UTC  page=photogrid → BHPhotoGridViewController  layout=v3 app=1 env=0  mac=OK
```

| 字段 | 含义 |
|---|---|
| `payload` | 原始载荷 hex，小端字节序 |
| `payloadBits` | 有效位数，必须与接入端一致 |
| `平面` | `chroma`（默认，不可见）或 `luma` |
| `相位` | 图案的像素偏移，整屏截图恒为 `(0,0)` |
| `signal` | 平均特征差。chroma 默认参数下约 9。**它被内容撑大，不能拿来判断成功率** |
| `\|z\|中位` / `最弱` | 各 bit 显著度。256 bit + chroma 实测中位 29~161，无水印约 0.5 |
| `弱bit` | \|z\| < 3 的 bit 数，**判读就看它** |
| `uid` / `time` / `page` / `tag` | `--layout` 解出的字段；`page` 是短码，后面带注册表命中或 grep 提示 |
| `mac` | `--key` 给了则校验：`OK` / `BAD` / `未校验` |
| 末尾判定 | `OK` 弱 bit=0 可信；`WEAK` ≤1/8 弱 bit 要交叉验证；`NO` 大概率没水印 |

判定与 MAC 冲突时以 MAC 为准：`WEAK`/`NO` 但 `mac=OK` 仍是正确载荷（只是余量小）；
`mac=BAD` 一律当失败，**不要硬解读数字**。

**没编 Swift / 在别的机器上**：`tools/bwdecode.py` 是同逻辑的 Python 实现，
参数、输出格式、判读规则完全一致（需要 numpy + Pillow）：

```bash
python3 "$BW_REPO/tools/bwdecode.py" shot.png --auto --layout --pages pages.json --key <hex>
```

两条实现由 `python3 "$BW_REPO/tools/test_bwdecode.py"` 对账（合成图回环 + 裁剪 + 篡改检测 +
页面短码 + 同一张 PNG 与 Swift 版比对）。Python 版实测：常规 0.21s，`--auto` 0.28s。

### 标准排查流程

1. 先看 `mac`。`mac=OK` → 直接采信；`mac=BAD` → 参数或截图形态不对，别读字段。
2. 没给 `--key` 时看判定：`NO` → 走下面的排查清单；`WEAK` → 必须结合日志/用户描述交叉验证。
3. 核对 `signal` 与平面是否自洽（chroma 约 9，luma 约等于 delta）。明显偏离说明图案没对上或 `--plane` 给错。
4. 加 `--layout` 解出 uid / time / page / tag，加 `--pages` 把页面短码还原成类名。
   输出 `page=xxxxx（注册表无命中…）` 说明这张截图不是这份注册表登记的版本，或者该页面没登记过；
   短码是从类名算出来的，按提示 `grep` 类名即可，不需要表也能定位。
5. uid + time 直接去日志/Sentry 定位问题。256 bit 布局的 timestamp 已是 Unix 秒，
   `--layout` 直接给出可读时间，不用再算环绕或时间桶。

### 页面注册表

接入端 `PageRegistry(names:)` 初始化或 `register(_:)` 增量登记，
`write(to:)` 落盘；解码端 `--pages` 加载同一份 JSON。格式就是字符串数组：

```json
["BHLoginViewController", "BHProfileViewController", "BHChatListViewController"]
```

`PageRegistry.matches(code:)` 命中不到返回空数组（不是硬猜一个类名，也不是按索引越界），
所以**表与截图版本漂移不会解出错答案**，最多是没命中、退化成 `grep` 提示。表建议带版本号进 git。

### 直接调用 API

```swift
import BlindWatermarkCore

let image = RGBAImage(cgImage: cgImage)!
let result = BlockCodec.decode(image, payloadBits: 256, plane: .chroma)!
print(result.payloadBytes)                       // 32 字节
let fields = WatermarkPayload(bytes: result.payloadBytes)
print(fields.uid, fields.timestamp, fields.pageNameCode)  // pageNameCode 拿去 grep

// 参数不确定时：穷举 + MAC 裁决
let key = SymmetricKey(hex: serverKeyHex)!
let best = BlockCodec.decodeBest(image, validate: { decoded in
    guard let f = WatermarkPayload(bytes: decoded.payloadBytes) else { return false }
    return f.isValid(key: key)
})!

// 平面 / 位数已知，只想求相位：给它一个校验器，否则它只是「块对齐最好」不代表解对了
let offset = BlockCodec.findBestOffset(in: image, payloadBits: 256, plane: .chroma, validate: { decoded in
    guard let f = WatermarkPayload(bytes: decoded.payloadBytes) else { return false }
    return f.isValid(key: key)
})
```

---

## 三、限制

### 拿不到水印的情况

| 情况 | 结果 | 处理 |
|---|---|---|
| **截图被缩放过**（微信转发、聊天软件压缩、任何 resize） | ❌ 完全解不出 | 块边长与平铺周期一起变了。让用户重发**原图** |
| **拍屏**（另一台手机拍屏幕） | ❌ 解不出 | 摩尔纹 + 几何畸变。需要同步模板或深度学习方案，本仓库不做 |
| 截图被裁剪（裁掉状态栏、分享时裁边） | ⚠️ 需要补偿 | 给 `--auto --key`：纵横向裁剪都能搜回来；已知偏移也可手算 `--offset 0,-H` |
| 非整屏截图（只截一部分区域） | ⚠️ 需要补偿 | 同上，给裁剪原点相对整屏的偏移 |
| 画面里根本没有水印（系统界面、别的 App） | `NO` | 正常，`\|z\|` 中位约 0.5、弱 bit 32/32 |
| 色度结构恰好是 8px 尺度的画面（对抗样本） | ⚠️ 退化 | 必须判成 `WEAK`/`NO`，不允许静默给错结果（有测试兜底） |

### 参数必须对齐，否则会静默解错

`payloadBits` 给错时，bit 的分组方式变了，结果是一份**自洽但错误**的载荷 —— 置信度可能依然很高。
`plane` 给错通常直接判 `NO`。所以解读之前**先确认接入端用的参数**，不要靠默认值蒙。

### 别把 luma 当备选

默认 `delta 8` 是给 **chroma** 定的。256 bit 布局下 luma 平面余量不够：
`delta 6` 时六页里弱 bit 4~182/256、文字页直接解错；`delta 12` 才让纯色/白底/深色页回到 0/256，
文字页仍然是 `mac=BAD`。**要 256 bit 就用 chroma**，需要 luma 只能砍位数并实测。

### 默认 payload 的问题

`WatermarkDefaultPayload.currentBytes()` 这套默认布局（256 bit 推荐布局）：

- uid = `fnv1a(identifierForVendor.uuidString)` 的完整 32 bit，`timestamp` = 当前 Unix 秒，
  `pageCode` = 0，`tag` = `layoutVersion << 28`，`mac` 留空。**没有时间桶、没有 16 bit 截断**。
- 设备哈希**不可逆**，没有映射表就定位不到任何东西
- **没有签名，可以伪造** —— 攻击者可以埋一个栽赃别人的 payload
- 上生产必须换成服务端下发并签名的载荷

### 其他

- 水印窗口 `windowLevel = .alert + 1`，盖在系统弹窗之上；`isUserInteractionEnabled = false`，不影响输入。
- iPad 分屏、外接屏每个 scene 各挂一个窗口，已处理；displayScale 中途变化不会重画图案。
- 色彩管理：截图若经过 sRGB/P3 转换，chroma 模式比 luma 模式更抗（亮度不变性）。
- 平坦区域亮度残差 0.07/255（chroma + delta 8），肉眼看不出；luma 模式是 6/255，能看出网格。

---

## 四、合规

水印携带设备与时间信息，属个人信息处理。只在**处理用户已上报的问题**时使用，
不要把 payload 与设备身份绑定后另作追踪，也不要外传映射表。
