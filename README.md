# BlindWatermark

[English](README.en.md) · 中文

iOS 屏上盲水印：整个 App 界面常驻一层肉眼不可见的色度扰动，截图必然被带上，
事后从截图反查出**设备、时间、页面**，用于定位用户上报的问题。

不 hook 截屏 API。截图走 render server 合成，水印窗口的像素天然进产物。

- 载体：512 bit / 64 字节（layout v4），uid + Unix 秒 + build 号 + 15 字符页面短码 + 22 字节 note + 96 bit 校验值
- 版本：`2.0.0`（[Releases](https://github.com/zylcold/BlindWatermark/releases)；SPM 用 `from: "2.0.0"`，CocoaPods 用 `:tag => '2.0.0'`）
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
  内容噪声按 `1/√n` 衰减。一张 iPhone 16 截图每 bit 有约 45 次观测（512 bit 布局，共 23287 个 pair）。

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
.package(url: "git@github.com:zylcold/BlindWatermark.git", from: "2.0.0")
```

```swift
import BlindWatermark

// 服务端算好校验值下发完整 64 字节，客户端只管渲染
Watermark.install(payload: serverIssuedBytes)

// 没密钥的部署（客户端自己拼载荷）：填公开自检值，解码端没有密钥也能校验
// build / note 由外部传入（CI 打包号 / 工单号），都是可选的
Watermark.install(payload: WatermarkPayload.selfChecked(uid: uid, timestamp: ts,
    build: 202609161722, pageClassName: type(of: self).description(),
    note: "hotfix-3", app: 1).bytes)

// 换页时更新页面短码（v4 一次性 set 全部字段）
Watermark.update(payload: WatermarkPayload(uid: uid, timestamp: ts, build: build,
    pageClassName: type(of: self).description(), note: note, key: key).bytes)

// 32 bit 便捷入口仍在
Watermark.install(payload: 0xDEAD_BEEF)
```

校验值有两档，都在同一个 `mac` 字段（96 bit）里：

| 构造方式 | 字段内容 | 解码端 |
|---|---|---|
| `WatermarkPayload(… key:)` | HMAC-SHA256(前 52 字节, 服务端密钥) | 有密钥 → `mac=OK(验签)`；没密钥 → `mac=未校验(需要 --key)`，**裁剪自愈用不了** |
| `WatermarkPayload.selfChecked(…)` | SHA-256(前 20 字节) 截断 | 任何人 → `mac=OK(自检,未验签)` |
| `mac: []` / mac 全 0 | 没有校验值 | `mac=未签名`，裁剪/相位搜索只能退结构自检 |

自检值能拦住"对齐错了几 bit"的近似解（实测全搜索空间假阳性 0），但**拦不住伪造**（谁都能算）；
要防伪造（防止有人埋一个栽赃别人的载荷）必须用服务端 HMAC。

未设置任何东西时用默认 payload（`identifierForVendor` 哈希 + Unix 秒），开箱可跑。

### CocoaPods

CocoaPods 下三个 target 拆成三个 pod（模块名与 SPM 一致），**必须一起声明**：
`BlindWatermark` 通过 `s.dependency` 依赖另外两个，只写它会在 `import BlindWatermarkCore` 处挂掉。

```ruby
pod 'BlindWatermarkCore',     :path => '/path/to/BlindWatermark'
pod 'BlindWatermarkAutoLoad', :path => '/path/to/BlindWatermark'
pod 'BlindWatermark',         :path => '/path/to/BlindWatermark'

# 换成 git 源：仓库有 tag（1.0.0 起）
# pod 'BlindWatermarkCore', :git => 'git@github.com:zylcold/BlindWatermark.git', :tag => '2.0.0'
```

注意 podspec 声明 `ios.deployment_target = '13.0'`（仓库平台下限）。Xcode 27 起最低只支持 15.0，
用它建 pod 工程需要把 pod target 的部署目标抬到 15.0，或改用较老的 Xcode。

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
| `payloadBits` | `payload.count × 8` | 有效位数，上限 512（v4 载荷固定 512），解码端必须一致 |
| `plane` | `chroma` | `chroma` 压色度平面（不可见），`luma` 压亮度平面（简单但看得见） |
| `delta`（代码里叫 `alpha`） | 8 | 扰动幅度。解码端看到的 \|d\|：luma 模式 ≈ delta，chroma 模式 ≈ 1.13×delta。**下限 2** |
| `offsetX/offsetY` | 0 | 解码时的图案相位，截图被裁过才需要 |
| `windowLevel` | `.alert + 1` | 水印窗口层级；盖到系统弹窗之上才能溯源弹窗场景 |

## 解码

```bash
swift build -c release
# 参数确定时（最快，0.07s）
.build/release/bwdecode shot.png --layout --pages Demo/pages.json --key <hex>

# 截图被裁过 / 不确定平面时（0.14s，穷举 + 校验值裁决）
.build/release/bwdecode shot.png --auto --layout --pages Demo/pages.json --key <hex>

# 平面 / 位数已确定，只是相位不确定（裁边但没缩放过）
.build/release/bwdecode shot.png --auto-offset --layout --pages Demo/pages.json --key <hex>

# 打印注册表里每个类名的短码，供人工/agent 对照
.build/release/bwdecode --pages Demo/pages.json --dump-codes
```

`--auto` 穷举 **2 平面 × 64 相位 × 512 tile 平移**（位数默认 512，显式给别的 `--bits` 时追加那一种），
用校验值裁决，实测 0.14s（iPhone 16 截图，M1 Pro，release 构建）。

### 校验阶梯

裁剪自愈靠**校验值**裁决（错误平移会给出很干净的自洽载荷，裸穷举不叫搜索，叫猜）。CLI 跑三档：

1. 严格校验器（HMAC 或公开自检值）+ 常规相位
2. 严格校验器 + **block 奇偶档**（ox 取 0..<16）—— 救横向裁剪量是**奇数个块**的情况
3. 结构自检兜底（载荷没带校验值时唯一能做到的），**打警告**，结论不保证正确

第 2 档解决的是一个真实夹缝：pair 是两个相邻块，块网格错开一个块时解码端配的是
跨两个 pattern pair 的块对，读出来是相邻两 bit 的和（只有两位相同时才留下观测），
部分 bit 会稀疏到一个证据都没有。实测文字页裁 40px 就是这种：常规相位搜不到真解，
加上奇偶档后真解出现在 `ox=8, rotation=3`，`|z|` 中位从 58.9 回到 67.3（与偶数块裁剪持平）。

实测（真机像素，4 个页面 × 5 种裁剪 = 20 个用例，不给任何密钥）：

| 载荷 | 无密钥的 `--auto` |
|---|---|
| 带公开自检值 | **20/20 解对** |
| `mac` 全 0（没带校验值，退结构自检） | 19/20（近似解漏网） |
| HMAC 签名但拿不到密钥 | 解不了（没校验器）—— 拿密钥或让接入端同时填自检值 |

`--auto-offset` 是它的收窄版：假定 `--bits` / `--plane` 已经给对（默认 256 / chroma），只穷举
**块网格相位（mod 8）**与 512 tile 平移两个自由度，同样走上面那个三档校验阶梯。
它与 `--offset` 互斥，与 `--auto` 语义重叠（同时给会直接报错退出）。
载荷没带校验值（`mac` 全 0）而调用方又没给 `--key` 时，它没有可靠的裁决器 —— 会打警告并退结构自检，
**不保证解出正确载荷**，判读必须看 `弱bit`。

必须搜 tile 平移的原因：裁掉非 256 整数倍的内容会让图案 tile 原点相对图片平移，
观测到的本地 pair 索引整体位移，载荷表现为**旋转**（裁 137px → 旋转 32 bit）。
相位搜索只修块对齐（mod 8），修不了这个平移 —— 只搜相位时载荷旋转且自洽，
`|z|` 中位照样很高、弱 bit 0/256，看起来完全正常但就是错的。**唯一可靠的裁决是校验值。**

横向平移必须**按行列分别取模**（在 tile 右边界回卷到本行第 0 列）。
用线性索引加偏移会让 1/16 的观测跨到下一行，z 值依旧漂亮，只有校验值看得出来 —— 见
`BlockCodecTests.testAutoSurvivesHorizontalCrop`。

判读顺序也是这么定的：阶段一按 `|z|` 排出块对齐最好的 16 组，阶段二在这些组上穷举平移并逐个验校验值。
不能按 `signal` 排 —— 它被内容撑大，没水印的 luma 平面能拿 19，带水印的 chroma 才 9，会挑错平面。

```
payload=0xefbeaddefab3ab6afa75722c2f00000013714d0b224d2449922449922449920100686f746669782d33000000000000000000000084c6b56fc6e6ac14ed4f3912  payloadBits=512  平面=chroma  相位=(0,0)  signal=9.00  |z|中位=120.6  最弱=2.9  弱bit=1/512  WEAK(1/512 bit 证据不足，结论谨慎)
uid=3735928559(0xDEADBEEF)  time=2026-09-17 09:33:19 UTC  page=textlist → BHTextListViewController  build=202609161722  note=hotfix-3  layout=v4 app=1 env=0  mac=OK(自检,未验签)
build 时间: 2026-09-16 17:22（构建方当地墙上时间）
```

判读看**弱 bit 数**（`|z| < 3` 的 bit 个数），不看最弱那一个 —— 真实界面上个别 bit 的 z
天然会塌，全局最小值太苛刻：

```
OK         弱 bit = 0               每 bit 都显著，结论可信
WEAK       弱 bit <= payloadBits/8  勉强解出，结论要交叉验证（512 bit 时阈值 = 64）
NO         弱 bit 更多              画面里大概没有水印
TOO_SMALL  每 bit 观测 < 5 次         图太小 / 图案已被破坏 —— 解码器拒绝解读字段
```

判定为 `NO` / `WEAK` 但 `mac=OK(...)` 时，**校验值才是权威**：弱 bit 只说明余量小，不代表解错。
反过来带校验值却对不上（`mac=BAD`）一定要当成失败处理，别硬解读数字。

校验字段分档（`--layout` 第二行末尾）：

| 输出 | 含义 |
|---|---|
| `mac=OK(验签)` | HMAC 通过，账号/时间可信且未被伪造 |
| `mac=OK(自检,未验签)` | 公开自检值通过 —— 能证明"解对了"，**不能**证明"没被伪造" |
| `mac=未签名(字段自洽,退结构自检)` | 载荷没带校验值，裁剪场景下结论不可信 |
| `mac=未校验(需要 --key)` | 带的是 HMAC 但没给密钥 —— 这种载荷**无法**做裁剪/旋转搜索（没有校验器），要么去要密钥，要么让接入端改填公开自检值 |
| `mac=BAD(密钥不符或载荷被改)` | 给了密钥且两种校验都对不上 |

无水印画面实测 `|z|` 中位 0.5、弱 bit 32/32，与带水印画面分得很开。

Agent 用法：解析看 [`skills/blind-watermark/SKILL.md`](skills/blind-watermark/SKILL.md)，
接入看 [`skills/blind-watermark-integration/SKILL.md`](skills/blind-watermark-integration/SKILL.md)。

### Python 版解码器（跨语言备份）

`tools/bwdecode.py` 是同一套逻辑的 Python 实现：参数、输出格式、判读规则与 Swift 版一致，
用途是**换一台机器 / 没编 Swift 也能解截图**，以及拿两套实现对账。

```bash
python3 -m pip install numpy pillow
python3 tools/bwdecode.py shot.png --auto --layout --pages Demo/pages.json --key <hex>

# 两套实现对账（同一张 PNG 比对 payload / 弱 bit / 字段），有 .build/release/bwdecode 就顺手比自己
python3 tools/test_bwdecode.py
```

实测（iPhone 16 截图 1179×2556，M1 Pro）：常规解码 0.34s，`--auto` 0.52s。
依赖只有 numpy 与 Pillow（Pillow 读图，numpy 算特征平面与积分图）。
它只是镜像：**改解码逻辑必须两边一起改**，`tools/test_bwdecode.py` 会在同一张 PNG 上交叉验证。

## 载荷布局（layout v4）

`WatermarkPayload.byteCount` = 64 字节 / `payloadBits` = 512，字段全小端。
`Sources/BlindWatermarkCore/WatermarkPayload.swift` 的文档注释是唯一权威，这里是副本：

```
[511:480] uid        32   UInt32   用户 ID 原样放
[479:448] timestamp  32   UInt32   Unix 秒（截图时间）
[447:384] build      64   UInt64   构建号，12 位十进制 YYYYMMDDHHMM（如 202609161722），0 = 未填
[383:288] pageCode   96           页面类名短码，15 个 6-bit 字符 = 90 bit（低 6 位必须为 0）
[287:272] tag        16   UInt16   App(8) + 环境(8)
[271: 96] note      176           自定义 note，22 字节 UTF-8，尾部 0 填充
[ 95:  0] 校验值     96           HMAC-SHA256(前 52 字节, 服务端密钥) 截断，或 SHA-256 截断（自检值）
```

**没有版本位**：布局就是这一个，字段边界变了等于换协议。**v3（256 bit / 32 字节）已废弃**，
历史 v3 截图用本版本解不出来（见「已知边界」）。

**为什么是 512 bit，代价是什么**：每 bit 的观测次数 = 图像面积 / pair 面积 / payloadBits，
**载荷翻倍就是余量减半**。iPhone 16 截图共 23287 个 pair：512 bit → 每 bit 约 45 次观测。
想补余量就调 `delta`（8 → 10 → 12，实测见下），把块缩到 4px 也能把观测拉回 183 次，
但 4px 块实测过不了 JPEG q80 —— 块只能是 8px。

**512 bit 时每 tile 只放得下 1 份**，"隔一份翻转极性抵消内容梯度"的机制自动关闭。
实测强色度渐变内容上没退化（弱 bit 0/512）；把 tile 放大到 512 换回该机制收益很小（弱 bit 40→32），
所以几何保持 tile 256 不变。

**页面短码 15 字符**：`BHUserProfileEditViewController → userprofileedit`（恰好 15 字符，不截断；
v3 的 10 字符会截成 `userprofil`）。15 字符只用 90 bit，字段留的 96 bit 里多出的 6 bit 必须为 0，
结构自检顺手查掉 —— 白拿 6 bit 判别力。真撞名也只是拿到 2~3 个候选，
`grep -rin "class.*userprofileedit" --include='*.swift'` 即可定位。

**build 与 note 都是外部传入**：build 来自 CI 打包号（12 位数字，原样存、原样打；
解码端另给一行可读时间），note 放工单号/环境描述（≤22 字节 UTF-8）。

零接入模式（没调过 `Watermark.install`、也没设 `payloadProvider`）用
`WatermarkDefaultPayload.currentBytes()` 拼一个 v4 载荷：uid = `fnv1a(identifierForVendor.uuidString)`
的完整 32 bit，timestamp = 当前 Unix 秒，build/pageCode/note 留空，校验值 = **公开自检值**。
设备哈希不可逆；**上生产必须换成服务端下发并验签的载荷**。

## 实测与边界

### 单元测试

`swift test` 覆盖 48 例（macOS 本机即可跑，不需要模拟器）：纯白/纯黑/中灰底色、渐变 + 照片级细节、
JPEG q=0.8 与 q=0.6、局部裁剪（纵向 + 横向 + 奇数块偏移）、`delta = 2` 下限、无水印画面不误报、
tile 几何契约、chroma/luma 两平面各自的可解码性、对抗性色度纹理不静默解错、`--auto` 的相位 / 平面 / 位数自动探测、
layout v4 回环与校验值（HMAC / 公开自检值 / 未签名三档）判定、近似解必须被自检值拦住、
block 奇偶档把奇数块裁剪的 `|z|` 拉回偶数块水平、`findBestOffset`（校验器裁决）以及
PageRegistry / PageNameCodec。

`python3 tools/test_bwdecode.py` 另有 74 项检查，并在同一张 PNG 上与 Swift 版对账。

### 模拟器逐页实测

`Demo/` 六个差异很大的版式，iPhone 16 模拟器（iOS 18.6，1179×2556），
payload 是 layout v4（512 bit：uid `0xDEADBEEF` + 时间 + build `202609161722` + 15 字符短码 + note），
chroma + delta 8（默认），无密钥（校验值是公开自检值）：

| 页面 | 内容特征 | signal | \|z\|中位 | 最弱 | 弱 bit | 判定 | 校验 |
|---|---|---|---|---|---|---|---|
| plain | 近乎纯色渐变 | 9.00 | 120.3 | 4.1 | 0/512 | OK | 自检通过 |
| white | 纯白 + 少量气泡文字 | 9.00 | 113.8 | 4.7 | 0/512 | OK | 自检通过 |
| text | 文字密集列表 | 9.00 | 120.6 | 2.9 | 1/512 | WEAK | 自检通过 |
| photo | 照片网格（合成噪声 + 硬边缘） | 9.10 | 35.0 | 6.6 | 0/512 | OK | 自检通过 |
| dark | 深色底 + 深色卡片 | 9.12 | 113.8 | 1.9 | 4/512 | WEAK | 自检通过 |
| mixed | 上白下黑 + 文字 + 照片 | 9.21 | 54.9 | 2.1 | 4/512 | WEAK | 自检通过 |

对比 256 bit 布局（同一批版式）：`|z|` 中位 161.0 → 120.3、最弱 6.7 → 2.9，
**余量大致减半**（payloadBits 翻倍 = 每 bit 观测减半）。上表几个 WEAK 只是弱 bit 不为 0，
离 512/8 = 64 的阈值还很远，且 `mac=OK(自检,未验签)` 已经确认解对了 ——
**512 bit 下判读以校验值为准，弱 bit 只作余量参考**。

最苛刻的真实内容（springboard 照片壁纸 + 图标，离线合成、真机像素）：

| delta | 每 bit 观测 | 解对 | \|z\|中位 | 弱 bit |
|---|---|---|---|---|
| 8（默认） | 45.5 | OK | 9.4 | 32/512 |
| 10 | 45.5 | OK | 14.9 | 22/512 |
| 12 | 45.5 | OK | 19.3 | 9/512 |

**luma 在 512 bit 下不可用**（delta 12 实测：plain 弱 bit 10/512 WEAK，text 139/512 NO、photo 103/512 NO；
delta 更小时更差）。luma 只能配更小的载荷，且要先跑 `Demo/sweep.sh` 复测。

> `signal` 大 = 内容噪声大，与能否解出无关（text 页 luma 能拿 20，却是最差的）。
> 决定成败的是 `|z|` 与校验值。

换个版式做接入验收时，先跑 `Demo/sweep.sh` 复测，别照抄这里的数字：

```bash
cd Demo && ./sweep.sh                          # 默认 chroma 逐页扫
cd Demo && ./sweep.sh "<UDID>" 4 luma          # 换 luma 平面 / 指定 delta 找余量
```

### 已知边界

- **图太小就解不出，解码器会直接拒答**：每 bit 需要的观测次数 = 可用 pair 数 / payloadBits。
  实测（真机像素、chroma、512 bit、整宽 1179）：每 bit 4.4 次观测时弱 bit 16/512、自检不过；
  5.3 次时 0/512、通过 —— 所以下限取 **5 次/bit**，折合约 **2700 个 pair**
  （整宽约 300px 高，或整屏 1179×2556）。低于这条线时解码器输出 `TOO_SMALL(...)`
  并且**拒绝用 --layout 解读字段**（退化成"输出看着正常的垃圾"是不允许的）——
  实测 482×440 的小裁剪只有 1.5~3.2 次/bit，必然拒答。
- **layout v3（256 bit / 32 字节）已废弃**：字段边界变了，历史 v3 截图用本版本解不出来 ——
  这是显式的破坏性变更。需要继续读老图的话，请用 1.0.0 tag 的解码器。

- **chroma 的对抗样本**：色度结构恰好落在 8px 尺度时会退化。
  `testChromaNeverSilentlyWrongOnAdversarialColorTexture` 兜住底线 —— 这种情况必须解不出或置信度低，
  不允许静默给出错误的 payload。
- **缩放解不出**：截图被缩放（聊天软件转发压缩、任何 resize）→ 块边长与平铺周期一起变了，完全解不出。
  只支持原始设备像素分辨率，让用户重发**原图**。
- **拍屏解不出**：另一台手机拍屏幕，摩尔纹与几何畸变会让块网格完全歪掉，
  需要同步模板 + 深度学习那一路方案，本仓库不做。
- **裁剪可以解**：`--auto` 覆盖纵向与横向裁剪（含非整 pair 偏移与奇数块偏移）；
  裁决靠校验值 —— 有服务端 HMAC 就给 `--key`，没有就靠载荷自带的公开自检值。两者都没有（`mac` 全 0）
  时只能退结构自检：实测 4 页面 × 5 裁剪 20 个用例里会错 1 个，而且错的那个长得像真解。

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
2. `swift test`（48 例核心测试）
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
