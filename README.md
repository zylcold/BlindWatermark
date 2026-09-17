# BlindWatermark

iOS 屏上盲水印：整个 App 界面常驻一层肉眼不可见的亮度扰动，截图必然被带上，
事后从截图反查出**设备与时间**，用于定位用户上报的问题。

不 hook 截屏 API。截图走 render server 合成，水印窗口的像素天然进产物。

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
所以剩下的那点色度网格同样难以察觉。

## 原理

- 覆盖全屏的是 **8×8 像素块**平铺图案，不是单像素噪点 —— 块内平坦，过 JPEG 不会被抹掉。
- 每两个相邻块 (A, B) 编码 1 bit：`1` → A 压暗 B 提亮；`0` → A 提亮 B 压暗。
- 解码取 `d = mean(A) − mean(B)`：压暗块的减益是 `−base·α`，提亮块的增益是 `(255−base)·α`，
  两者相加把 `base` 抵消 → `d ≈ ∓alpha`。**与底色无关**，白底、黑底、深色照片都能解。
- 同一个 bit 的多份重复观测里**隔一份翻转极性**：水印分量同向累加，画面自身的亮度梯度正负相消。
- 读码不是取符号，而是按带符号差值累加后除以标准误得到 z 值：水印随观测次数线性累加，
  内容噪声按 `1/√n` 衰减。一张 iPhone 截图每 bit 有约 360 次观测。

解码余量也是模拟器实测定的（iPhone 16，3x，luma 模式）：

| 方案 | \|z\| 中位 | 弱 bit | 结论 |
|---|---|---|---|
| 16px 块，delta 3 | 1.9 | 27/32 | 解出来是运气 |
| 8px 块，delta 3 | 3.3 | 12/32 | 仍不稳 |
| **8px 块，delta 6（默认）** | **6.4** | **0/32** | **可靠** |
| 无水印对照 | 0.5 | 32/32 | 不误报 |

luma 模式的代价就是那 6/255 的亮度网格，凑近看得见 —— 这也是默认改成 chroma 的原因。

## 接入

### Swift Package Manager

```swift
.package(url: "git@github.com:zylcold/BlindWatermark.git", branch: "main")
```

```swift
import BlindWatermark
import BlindWatermarkCore

// 服务端算好 mac 下发完整 16 字节，客户端只管渲染
Watermark.install(payload: serverIssuedBytes)

// 换页时更新页面索引
Watermark.update(payload: WatermarkPayload(uid: uid, timestamp: ts,
    pageClassName: type(of: self).description(), key: key).bytes)

// 32 bit 便捷入口仍在
Watermark.install(payload: 0xDEAD_BEEF)
```

未设置任何东西时用默认 payload（`identifierForVendor` 哈希 + 时间桶），开箱可跑。

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
  不影响输入法。alpha 只有 3/255，视觉上察觉不到。
- **多 scene（iPad 分屏、外接屏）**：每个 scene 各挂一个窗口，已处理。
  displayScale 中途变化（插拔外接屏）不会重画图案，真接了外接屏再监听 trait 变化。

## 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `payload` | — | 载荷字节，bit 0 在 payload[0] 最低位 |
| `payloadBits` | `payload.count × 8` | 有效位数，上限 256，解码端必须一致 |
| `plane` | `chroma` | `chroma` 压色度平面（不可见），`luma` 压亮度平面（简单但看得见） |
| `delta`（代码里叫 `alpha`） | 8 | 扰动幅度。解码端看到的 \|d\|：luma 模式 ≈ delta，chroma 模式 ≈ 1.13×delta。**下限 2** |
| `offsetX/offsetY` | 0 | 解码时的图案相位，截图被裁过才需要 |

## 解码

```bash
swift build -c release
# 参数确定时（最快，74ms）
.build/release/bwdecode shot.png --layout --pages Demo/pages.json --key <hex>

# 截图被裁过 / 不确定平面与位数时
.build/release/bwdecode shot.png --auto --layout --pages Demo/pages.json --key <hex>

# 打印注册表里每个类名的短码，供人工/agent 对照
.build/release/bwdecode --pages Demo/pages.json --dump-codes
```

`--auto` 穷举 **2 平面 × 64 相位 × 512 tile 旋转 × 2 位数种**，用 MAC 裁决，实测 0.5s。

必须搜 tile 旋转的原因：裁掉非 256 整数倍的内容会让图案 tile 原点相对图片平移，
`localPairIndex` 整体位移，载荷表现为**旋转**（裁 137px → 旋转 32 bit）。
相位搜索只修块对齐（mod 8），修不了这个平移 —— 只搜相位时载荷旋转且自洽，
`|z|` 中位照样 98、弱 bit 0/128，看起来完全正常但就是错的。**唯一可靠的裁决是 MAC。**

判读顺序也是这么定的：阶段一按 `|z|` 排出块对齐最好的 16 组，阶段二在这些组上穷举旋转并逐个验 MAC。
不能按 `signal` 排 —— 它被内容撑大，没水印的 luma 平面能拿 19，带水印的 chroma 才 9，会挑错平面。

```
payload=0xefbeaddea048aa6acfe14c8e112103090000103059f32c1304708e9619bdb73c  payloadBits=256  平面=chroma  相位=(0,7)  signal=9.17  |z|中位=35.5  最弱=10.0  弱bit=0/256  OK(全部 256 bit 显著)
uid=3735928559(0xDEADBEEF)  time=2026-09-16 07:43:28 UTC  page=photogrid → BHPhotoGridViewController  layout=v3 app=1 env=0  mac=OK
```

判读看**弱 bit 数**（`|z| < 3` 的 bit 个数），不看最弱那一个 —— 真实界面上个别 bit 的 z
天然会塌，全局最小值太苛刻：

```
OK   弱 bit = 0            每 bit 都显著，结论可信
WEAK 弱 bit <= 32/8 = 4    勉强解出，结论要交叉验证
NO   弱 bit 更多           画面里大概没有水印
```

无水印画面实测 `|z|` 中位 0.5、弱 bit 32/32，与带水印画面分得很开。

Agent 用法见 [`skills/blind-watermark/SKILL.md`](skills/blind-watermark/SKILL.md)。

## 默认 payload 布局

```
高 16 位 = FNV-1a(identifierForVendor) & 0xFFFF   // 设备哈希，不可逆，需查表
低 16 位 = floor(unixTime / 600) & 0xFFFF          // 时间桶，粒度 10 分钟
```

时间桶 16 bit 每 `65536 × 600s ≈ 455 天` 环绕一次。

这是 POC 级布局：无法验签、可伪造、设备哈希不可逆。**上生产必须换成服务端下发并签名的 payload**，
否则拿到水印也定位不到人，还可能被伪造栽赃。

## 已验证 / 未验证

`swift test` 覆盖（11 例）：纯白/纯黑/中灰底色、渐变 + 照片级细节、
JPEG q=0.8 与 q=0.6、局部裁剪、`delta = 2` 下限、无水印画面不误报。

**模拟器逐页实测**（`Demo/`，iPhone 16，每页 payload 均为 0xDEADBEEF）：

chroma 模式（默认，delta 8）：

| 页面 | signal | \|z\|中位 | 最弱 | 弱 bit | 判定 |
|---|---|---|---|---|---|
| plain | 9.00 | 453.6 | 69.9 | 0/32 | OK |
| text | 9.00 | 453.1 | 58.2 | 0/32 | OK |
| photo | 8.99 | 327.5 | 87.3 | 0/32 | OK |

luma 模式（delta 6）作为对照：

| 页面 | 内容特征 | signal | \|z\|中位 | 最弱 | 弱 bit | 判定 |
|---|---|---|---|---|---|---|
| plain | 近乎纯色渐变 | 6.4 | 36.5 | 17.3 | 0/32 | OK |
| white | 纯白 + 少量气泡文字 | 7.0 | 17.1 | 12.1 | 0/32 | OK |
| dark | 深色底 + 深色卡片 | 7.2 | 17.2 | 8.7 | 0/32 | OK |
| mixed | 上白下黑 + 文字 + 照片 | 9.5 | 10.3 | 3.6 | 0/32 | OK |
| photo | 照片网格（合成噪声 + 硬边缘） | 13.4 | 10.7 | 4.8 | 0/32 | OK |
| **text** | 文字密集列表 | **15.5** | **5.6** | **3.7** | 0/32 | OK（最差） |
| 对照 | 模拟器主屏，无水印 | 12.6 | 0.4 | 0.0 | 32/32 | NO |

luma 模式下 `signal` 大 = 内容噪声大，与能否解出无关；决定成败的是 `|z|`，最差场景是文字密集页
（文字横画的水平结构与块网格同频，内容偏置最难抵消），余量只有约 1.2 倍 —— delta 降到 5 就出现弱 bit。
chroma 模式没有这个问题：灰阶内容在色度平面上恒为零，文字页和纯色页的 `|z|` 一样高。

换个版式做接入验收时，先跑 `Demo/sweep.sh` 复测，别照抄这里的数字。

```bash
cd Demo && ./sweep.sh                          # 默认 chroma 逐页扫
cd Demo && ./sweep.sh "<UDID>" 4 luma          # 换 luma 平面 / 指定 delta 找余量
```

**chroma 模式的边界**：色度结构恰好落在 8px 尺度时（对抗样本）会退化。
`testChromaNeverSilentlyWrongOnAdversarialColorTexture` 兜住底线 —— 这种情况必须解不出或置信度低，
不允许静默给出错误的 payload。

**未验证**：拍屏（另一台手机拍屏幕）—— 摩尔纹与几何畸变会让块网格完全歪掉，需要同步模板 +
深度学习那一路方案，本仓库不做。**截图被缩放也解不出来**（块边长与平铺周期一起变了），
只支持原始设备像素分辨率。

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
`SIMCTL_CHILD_BW_PAYLOAD=0x1234 SIMCTL_CHILD_BW_DELTA=8`。

## 合规

水印携带设备与时间信息，属个人信息处理。必须在隐私政策里明确告知用途与范围，
不得用于告知目的之外的追踪。技术上能做 ≠ 合规能做。

## License

MIT
