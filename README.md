# BlindWatermark

[English](README.en.md) · 中文

iOS 屏上盲水印：整个 App 界面常驻一层肉眼不可见的色度扰动，截图必然被带上，
事后从截图反查出**设备、时间、页面**，用于定位用户上报的问题。

不 hook 截屏 API。截图走 render server 合成，水印窗口的像素天然进产物。

- 载体：256 bit / 32 字节，uid + Unix 秒 + 页面短码 + 96 bit HMAC
- 不可见：亮度残差 0.07/255（人眼阈值之下），只压色度平面
- 抗压缩：8×8 像素块成对差分，块内平坦，JPEG q=0.6 仍可解
- 解码：`swift run bwdecode shot.png --auto --layout --key <hex>`，整屏截图 0.1 秒

---

## 目录

- [为什么看不见](#为什么看不见)
- [原理](#原理)
- [接入](#接入)
- [参数](#参数)
- [解码](#解码)
- [默认 payload 布局](#默认-payload-布局)
- [实测与边界](#实测与边界)
- [模拟器冒烟](#模拟器冒烟)
- [CI](#ci)
- [合规](#合规)

---

## 为什么看不见

水印压在**蓝-黄对色平面**上，不是亮度平面上。

亮度零方向的向量是 `(0.128, 0.128, -1)`（`0.299×0.128 + 0.587×0.128 − 0.114 = 0`）。
一对相邻块分别叠 `(0,0,a)` 与 `(p,p,0)`，取 `p = round(0.114a/0.886)` 就得到**等亮度、只差色度**的一对色。

关键在混色是**预乘 alpha 的线性运算**：合成分的亮度差等于叠加色在预乘空间的亮度差，不随 alpha 衰减。
所以 `p` 必须精确到这个比例 —— `a=6` 时取整会得 `p=0`，等于拿纯黑去配纯蓝，亮度差 0.68/255，网格立刻显形。
`a=8, p=1` 这组最好，残差 0.026/255。

实测（iPhone 16 模拟器，plain 页水平条带，条带内背景无渐变，量到的是纯水印）：

| 模式 | 亮度极差 | 色度极差 |
|---|---|---|
| **chroma，alpha 8（默认）** | **0.07 / 255** | 9.04 |
| luma，alpha 6 | 6.04 / 255 | 0.10 |

亮度只动了 0.03%，等于没动。人眼对高频色度的分辨力也远低于亮度（色度锐度约为亮度的 1/4），
所以剩下的那点色度网格同样难以察觉 —— 这也是默认走 chroma 的原因：luma 模式的 6/255 亮度网格凑近看得见。

## 原理

- 覆盖全屏的是 **8×8 像素块**平铺图案（tile 256×256 设备像素），不是单像素噪点 —— 块内平坦，过 JPEG 不会被抹掉。
- 每两个相邻块 (A, B) 编码 1 bit：`1` → A 压暗 B 提亮；`0` → A 提亮 B 压暗。
- 解码取 `d = mean(A) − mean(B)`：压暗块的减益是 `−base·α`，提亮块的增益是 `(255−base)·α`，
  两者相加把 `base` 抵消 → `d ≈ ∓alpha`。**与底色无关**，白底、黑底、深色照片都能解。
- 同一个 bit 的多份重复观测里**隔一份翻转极性**：水印分量同向累加，画面自身的亮度梯度正负相消。
- 读码不是取符号，而是按带符号差值累加后除以标准误得到 z 值：水印随观测次数线性累加，
  内容噪声按 `1/√n` 衰减。一张 iPhone 16 截图每 bit 有约 90 次观测（256 bit 布局，每 tile 重复 2 份）。

解码余量也是模拟器实测定的（iPhone 16，3x，luma 模式，32 bit 布局）：

| 方案 | \|z\| 中位 | 弱 bit | 结论 |
|---|---|---|---|
| 16px 块，delta 3 | 1.9 | 27/32 | 解出来是运气 |
| 8px 块，delta 3 | 3.3 | 12/32 | 仍不稳 |
| **8px 块，delta 6（luma 默认）** | **6.4** | **0/32** | **可靠** |
| 无水印对照 | 0.5 | 32/32 | 不误报 |

上表是 32 bit 布局下的结论。**256 bit 布局把每个 bit 的观测数摊薄到 1/8，luma 模式不再够用**
（实测见[实测与边界](#实测与边界)），所以默认参数是 chroma + delta 8。

## 接入

### Swift Package Manager

```swift
.package(url: "git@github.com:zylcold/BlindWatermark.git", branch: "main")
```

```swift
import BlindWatermark

// 服务端算好 mac 下发完整 32 字节，客户端只管渲染
Watermark.install(payload: serverIssuedBytes)

// 换页时更新页面短码
Watermark.update(payload: WatermarkPayload(uid: uid, timestamp: ts,
    pageClassName: type(of: self).description(), key: key).bytes)

// 32 bit 便捷入口仍在
Watermark.install(payload: 0xDEAD_BEEF)
```

未设置任何东西时用默认 payload（`identifierForVendor` 哈希 + Unix 秒），开箱可跑。

### CocoaPods

```ruby
pod 'BlindWatermark', :path => '/path/to/BlindWatermark'
# 或指向 git
# pod 'BlindWatermark', :git => 'git@github.com:zylcold/BlindWatermark.git'
```

### 接入注意

- 零代码自动加载依赖 ObjC `+load` 所在目标文件被链接。只要 App 里 `import BlindWatermark`
  并调用过一次 `Watermark.install`，链接就成立。若确实要完全零调用，App target 需要加
  `-ObjC`，否则静态链接会把那个目标文件丢掉。
- 水印窗口 `windowLevel = .alert + 1`、`isUserInteractionEnabled = false`，不抢 key window，
  不影响输入法。图案 delta 8，亮度残差 0.07/255，视觉上察觉不到。
- **多 scene（iPad 分屏、外接屏）**：每个 scene 各挂一个窗口，已处理。
  displayScale 中途变化（插拔外接屏）不会重画图案，真接了外接屏再监听 trait 变化。
- 三个参数 **`payloadBits` / `plane` / `delta`，解码端必须与接入端完全一致**。写进 App 的配置，别靠记忆。

## 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `payload` | — | 载荷字节，bit 0 在 payload[0] 最低位 |
| `payloadBits` | `payload.count × 8` | 有效位数，上限 256，解码端必须一致 |
| `plane` | `chroma` | `chroma` 压色度平面（不可见），`luma` 压亮度平面（简单但看得见） |
| `delta`（代码里叫 `alpha`） | 8 | 扰动幅度。解码端看到的 \|d\|：luma 模式 ≈ delta，chroma 模式 ≈ 1.13×delta。**下限 2** |
| `offsetX/offsetY` | 0 | 解码时的图案相位，截图被裁过才需要 |
| `windowLevel` | `.alert + 1` | 水印窗口层级；盖到系统弹窗之上才能溯源弹窗场景 |

## 解码

```bash
swift build -c release
# 参数确定时（最快，0.08s）
.build/release/bwdecode shot.png --layout --pages Demo/pages.json --key <hex>

# 截图被裁过 / 不确定平面与位数时（0.1s，穷举 + MAC 裁决）
.build/release/bwdecode shot.png --auto --layout --pages Demo/pages.json --key <hex>

# 平面 / 位数已确定，只是相位不确定（裁边但没缩放过）
.build/release/bwdecode shot.png --auto-offset --layout --pages Demo/pages.json --key <hex>

# 打印注册表里每个类名的短码，供人工/agent 对照
.build/release/bwdecode --pages Demo/pages.json --dump-codes
```

`--auto` 穷举 **2 平面 × 64 相位 × 512 tile 平移**（位数默认只有 256，仅当显式给 `--bits` 且 ≠256 时才追加那一种），
用 MAC 裁决，实测 0.1s（iPhone 16 截图，M1 Pro，release 构建）。

`--auto-offset` 是它的收窄版：假定 `--bits` / `--plane` 已经给对（默认 256 / chroma），只穷举
**块网格相位（mod 8）**这个自由度；**只有给了 `--key` 才额外穷举 512 tile 平移**（用 MAC 裁决）。
它与 `--offset` 互斥，与 `--auto` 语义重叠（同时给会直接报错退出）。没给 `--key` 时它只能按 `|z|` 中位裁决，
**不保证解出正确载荷**，判读必须看 `弱bit`。

必须搜 tile 平移的原因：裁掉非 256 整数倍的内容会让图案 tile 原点相对图片平移，
观测到的本地 pair 索引整体位移，载荷表现为**旋转**（裁 137px → 旋转 32 bit）。
相位搜索只修块对齐（mod 8），修不了这个平移 —— 只搜相位时载荷旋转且自洽，
`|z|` 中位照样很高、弱 bit 0/256，看起来完全正常但就是错的。**唯一可靠的裁决是 MAC。**

横向平移必须**按行列分别取模**（在 tile 右边界回卷到本行第 0 列）。
用线性索引加偏移会让 1/16 的观测跨到下一行，z 值依旧漂亮，只有 MAC 看得出来 —— 见
`BlockCodecTests.testAutoSurvivesHorizontalCrop`。

判读顺序也是这么定的：阶段一按 `|z|` 排出块对齐最好的 16 组，阶段二在这些组上穷举平移并逐个验 MAC。
不能按 `signal` 排 —— 它被内容撑大，没水印的 luma 平面能拿 19，带水印的 chroma 才 9，会挑错平面。

```
payload=0xefbeaddea048aa6acfe14c8e112103090000103059f32c1304708e9619bdb73c  payloadBits=256  平面=chroma  相位=(0,7)  signal=9.17  |z|中位=35.5  最弱=10.0  弱bit=0/256  OK(全部 256 bit 显著)
uid=3735928559(0xDEADBEEF)  time=2026-09-16 07:43:28 UTC  page=photogrid → BHPhotoGridViewController  layout=v3 app=1 env=0  mac=OK
```

判读看**弱 bit 数**（`|z| < 3` 的 bit 个数），不看最弱那一个 —— 真实界面上个别 bit 的 z
天然会塌，全局最小值太苛刻：

```
OK   弱 bit = 0            每 bit 都显著，结论可信
WEAK 弱 bit <= payloadBits/8    勉强解出，结论要交叉验证（256 bit 时阈值 = 32）
NO   弱 bit 更多           画面里大概没有水印
```

判定为 `NO` / `WEAK` 但 `mac=OK` 时，**MAC 才是权威**：弱 bit 只说明余量小，不代表解错。
反过来 `mac=BAD` 一定要当成失败处理，别硬解读数字。

无水印画面实测 `|z|` 中位 0.5、弱 bit 32/32，与带水印画面分得很开。

Agent 用法见 [`skills/blind-watermark/SKILL.md`](skills/blind-watermark/SKILL.md)。

### Python 版解码器（跨语言备份）

`tools/bwdecode.py` 是同一套逻辑的 Python 实现：参数、输出格式、判读规则与 Swift 版一致，
用途是**换一台机器 / 没编 Swift 也能解截图**，以及拿两套实现对账。

```bash
python3 -m pip install numpy pillow
python3 tools/bwdecode.py shot.png --auto --layout --pages Demo/pages.json --key <hex>

# 两套实现对账（同一张 PNG 比对 payload / 弱 bit / 字段），有 .build/release/bwdecode 就顺手比自己
python3 tools/test_bwdecode.py
```

实测（iPhone 16 截图 1179×2556，M1 Pro）：常规解码 0.21s，`--auto` 0.28s。
依赖只有 numpy 与 Pillow（Pillow 读图，numpy 算特征平面与积分图）。
它只是镜像：**改解码逻辑必须两边一起改**，`tools/test_bwdecode.py` 会在同一张 PNG 上交叉验证。

## 默认 payload 布局

`WatermarkPayload.payloadBits` = 256 bit / 32 字节，字段全小端。
`Sources/BlindWatermarkCore/WatermarkPayload.swift` 的文档注释是唯一权威，这里是副本：

```
[255:224] uid        32   UInt32   用户 ID 原样放
[223:192] timestamp  32   UInt32   Unix 秒，精确到秒
[191:128] pageCode   64   UInt64   页面类名短码，10 个 6-bit 字符 = 60 bit
[127: 96] tag        32   UInt32   [31:28] 布局版本 [27:20] App [19:12] 环境 [11:0] 保留
[ 95:  0] mac        96            HMAC-SHA256(前 20 字节, 服务端密钥) 截断到 96 bit
```

**为什么是 256 bit**：10 字符页面短码就要 60 bit，128 bit 装不下；再大每 tile 的重复次数会低于 2，
「隔一份翻转极性抵消亮度梯度」的机制就失效了（上限见 `BlockCodec.maxPayloadBits`）。

零接入模式（没调过 `Watermark.install`、也没设 `payloadProvider`）用 `WatermarkDefaultPayload.currentBytes()`
拼一个 **256 bit 推荐布局**：uid = `fnv1a(identifierForVendor.uuidString)` 的完整 32 bit，
timestamp = 当前 Unix 秒（**没有 10 分钟时间桶**），pageCode = 0，tag = `layoutVersion << 28`，mac 留空。
`mac` 为空 ⇒ **无法验签、可伪造**，设备哈希不可逆，只够跑通链路。
**上生产必须换成服务端下发并签名的 payload**，否则拿到水印也定位不到人，还可能被伪造栽赃。

## 实测与边界

### 单元测试

`swift test` 覆盖 41 例（macOS 本机即可跑，不需要模拟器）：纯白/纯黑/中灰底色、渐变 + 照片级细节、
JPEG q=0.8 与 q=0.6、局部裁剪（纵向 + 横向）、`delta = 2` 下限、无水印画面不误报、tile 几何契约、
chroma/luma 两平面各自的可解码性、对抗性色度纹理不静默解错、`--auto` 的相位 / 平面 / 位数自动探测、
256 bit 布局回环与 MAC 篡改检测、`findBestOffset` 相位搜索（校验器裁决）以及 PageRegistry / PageNameCodec。

### 模拟器逐页实测

`Demo/` 六个差异很大的版式，iPhone 16 模拟器（iOS 18.6，1179×2556），payload 走 Demo 默认的
256 bit 布局（uid `0xDEADBEEF` + 当前时间 + 页面短码 + 真 mac），delta 8。

chroma 模式（**默认**）：

| 页面 | 内容特征 | signal | \|z\|中位 | 最弱 | 弱 bit | 判定 |
|---|---|---|---|---|---|---|
| plain | 近乎纯色渐变 | 9.00 | 161.3 | 10.6 | 0/256 | OK |
| white | 纯白 + 少量气泡文字 | 9.00 | 161.0 | 9.8 | 0/256 | OK |
| text | 文字密集列表 | 9.00 | 161.3 | 6.7 | 0/256 | OK |
| photo | 照片网格（合成噪声 + 硬边缘） | 9.34 | 28.8 | 8.0 | 0/256 | OK |
| dark | 深色底 + 深色卡片 | 9.12 | 161.0 | 4.9 | 0/256 | OK |
| mixed | 上白下黑 + 文字 + 照片 | 9.12 | 160.6 | 4.8 | 0/256 | OK |

chroma 下灰阶内容在色度平面上恒为零，所以文字页和纯色页的 `|z|` 一样高；
`photo` 的 `|z|` 被大面积彩色内容拉低，但每 bit 仍显著。

luma 模式作为对照（同一批截图，256 bit 布局）：

| delta | 结论 |
|---|---|
| 6 | 弱 bit 4~182/256，text 页直接解错（mac=BAD）。**256 bit 下不可用** |
| 12 | plain / white / dark 解对（弱 bit 0/256），mixed / photo 降级为 WEAK 但 mac=OK，text 页仍 mac=BAD |

结论：luma 的余量被 256 bit 摊薄到不够用，而提高 delta 会让那层亮度网格肉眼可见。
**要 256 bit 就用 chroma**；确需 luma 就只能砍载荷位数，并先跑 `Demo/sweep.sh` 复测这个数字。

> `signal` 大 = 内容噪声大，与能否解出无关（text 页 luma 能拿 20，却是最差的）。
> 决定成败的是 `|z|` 与 MAC。

换个版式做接入验收时，先跑 `Demo/sweep.sh` 复测，别照抄这里的数字：

```bash
cd Demo && ./sweep.sh                          # 默认 chroma 逐页扫
cd Demo && ./sweep.sh "<UDID>" 4 luma          # 换 luma 平面 / 指定 delta 找余量
```

### 已知边界

- **chroma 的对抗样本**：色度结构恰好落在 8px 尺度时会退化。
  `testChromaNeverSilentlyWrongOnAdversarialColorTexture` 兜住底线 —— 这种情况必须解不出或置信度低，
  不允许静默给出错误的 payload。
- **缩放解不出**：截图被缩放（聊天软件转发压缩、任何 resize）→ 块边长与平铺周期一起变了，完全解不出。
  只支持原始设备像素分辨率，让用户重发**原图**。
- **拍屏解不出**：另一台手机拍屏幕，摩尔纹与几何畸变会让块网格完全歪掉，
  需要同步模板 + 深度学习那一路方案，本仓库不做。
- **裁剪可以解**：`--auto` 配 `--key` 覆盖纵向与横向裁剪（含非整 pair 偏移）；
  没给 `--key` 时退化成按 `|z|` 中位猜，不保证正确。

## 模拟器冒烟

```bash
cd Demo && xcodegen generate
xcodebuild -project Demo.xcodeproj -scheme Demo \
  -destination 'id=<模拟器UDID>' -derivedDataPath /tmp/bwdd build
xcrun simctl install booted /tmp/bwdd/Build/Products/Debug-iphonesimulator/Demo.app
xcrun simctl launch booted com.zylcold.blindwatermark.demo
xcrun simctl io booted screenshot /tmp/shot.png
.build/release/bwdecode /tmp/shot.png
```

调参用环境变量（需要 `xcrun simctl launch` 前缀 `SIMCTL_CHILD_`）：
`SIMCTL_CHILD_BW_PAYLOAD=0x1234 SIMCTL_CHILD_BW_DELTA=8 SIMCTL_CHILD_BW_PLANE=chroma`。

## CI

`.github/workflows/ci.yml` 对每个 PR 跑四件事：

1. `swift build`（全 target 编译）
2. `swift test`（41 例核心测试）
3. `xcodegen generate` + `xcodebuild -destination 'generic/platform=iOS Simulator'`
   编译 `Demo/`，覆盖 iOS 侧（UIKit 窗口层、ObjC `+load`）的编译验证 —— `swift test` 在 macOS 上
   编不到那部分。
4. `python3 tools/test_bwdecode.py`：Python 解码器自检（合成图回环 / 裁剪 / 篡改检测 / 短码）
   并与 Swift 版 `bwdecode` 在同一张 PNG 上对账。

本地复现：

```bash
swift build && swift test
python3 tools/test_bwdecode.py
cd Demo && xcodegen generate && xcodebuild -project Demo.xcodeproj -scheme Demo \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/bwdd CODE_SIGNING_ALLOWED=NO build
```

## 合规

水印携带设备与时间信息，属个人信息处理。必须在隐私政策里明确告知用途与范围，
不得用于告知目的之外的追踪。技术上能做 ≠ 合规能做。

## License

MIT
