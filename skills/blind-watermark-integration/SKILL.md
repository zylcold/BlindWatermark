---
name: blind-watermark-integration
license: MIT
description: 在 iOS App 里接入屏上盲水印（BlindWatermark）：把肉眼不可见的载荷嵌进界面，让截图能溯源到设备/时间/构建号/页面。用户要「接入水印」「装上盲水印」「水印怎么集成」「参数怎么配」「水印太明显」「接入验收」「sweep 复测」时使用。只读截图、解析水印请用 blind-watermark skill（那边是本 skill 的对端）。
---

# 盲水印接入（App 侧）

把 BlindWatermark（`zylcold/BlindWatermark`）装进 App：v4 默认在整个界面常驻一层色度扰动，
截图会带上它，事后由解码端反查出**设备 / 时间 / 构建号 / 页面**。v5.2 是显式 opt-in 的紧凑路径，
默认 `.none` 仍以色度数据为主；pilot 实验档会留下亮度残差，不能套用 v4 的“肉眼不可见”结论。

**本 skill 只管接入。** 解析截图、判读校验值、排查解不出，看
[`blind-watermark`](../blind-watermark/SKILL.md) —— 它的「容量与布局」一节是字段契约，
本 skill 构造的载荷必须严格符合它（否则解出来自洽但错误）。

---

## 一、最快接入

```swift
import BlindWatermark

// 装水印（服务端下发并签名的载荷最可靠）
Watermark.install(payload: serverIssuedPayload) // v4 默认

// 换页时更新页面短码 —— 相位不变，解码端无感，微秒级
Watermark.update(payload: WatermarkPayload(
    uid: uid, timestamp: ts, build: build,
    pageClassName: type(of: self).description(), note: ticket, key: key
).bytes)
```

没有服务端密钥时用公开自检值（解码端无需密钥即可校验）：

```swift
Watermark.install(payload: WatermarkPayload.selfChecked(
    uid: uid, timestamp: ts, build: 202609161722,
    pageClassName: type(of: self).description(), note: "hotfix-3", app: 1
).bytes)
```

安装方式：SPM（`.package(url: "git@github.com:zylcold/BlindWatermark.git", from: "1.0.0")`）
或 CocoaPods（三个 pod 必须同时声明：`BlindWatermarkCore` / `BlindWatermarkAutoLoad` / `BlindWatermark`，
模块名与 SPM 一致）。细节见 README「接入」。

## 二、载荷怎么造

本 skill 默认描述的是 v4。若要启用紧凑协议，必须显式选 v5.2；不要把两套载荷的字节直接互换。

### v5.2 紧凑接入（显式 opt-in）

```swift
let compact = WatermarkPayloadV52(
    uid: uid,
    timestamp: UInt64(Date().timeIntervalSince1970),
    buildTime: UInt64(Date().timeIntervalSince1970),
    pageClassName: type(of: self).description(),
    app: 42,
    note: "hotfix"
)!
Watermark.installV52(payload: compact, delta: 4, plane: .chroma)   // v5.2 默认 delta 就是 4
// 换页时：Watermark.updateV52(payload: nextCompact)
```

v5.2 信息字段为 207 bit，固定顺序是 `profile(4)`、`uid(32)`、时间秒偏移(31)、构建分钟偏移(24)、
8 字符 base37 `page(42)`、`app(14)`、6 字符 base37 `note(32)`、CRC24(24) 与 reserved(4)。
它编码为 BCH(255,207,t=6) 加一位整体偶校验；每个 256 px tile 放两份相反业务极性的 256 bit 码字。
CRC 只做完整性检查，不能代替服务端签名或证明 uid 未被伪造。`page` 沿用 `PageNameCodec` 归一化后取
前 8 字符，`note` 只接受 `[a-z0-9_]` 且最多 6 字符，结尾 `_` 是填充。

**v5.2 默认 `delta: 4`**（v4 仍是 8）。原因：可见性只有亮度轴被陪色匹配掉，**色度轴极差就等于
`delta`**；v5.2 每个码字 bit 有两份反极性副本，观测余量是 v4 的两倍，所以能靠减半 delta 换来减半的
可见色差。模拟器实测（iPhone 16 / iOS 18.6，1179×2556，六版式）：

| delta | 色差（ΔR/ΔG, ΔB） | 亮度 ΔLuma | 六版式解码 | 最差页 \|z\| 中位 |
|---|---|---|---|---|
| 8 | +1, −8/255 | 0.35/255 | 6/6，`correctedBits=0` | 42 |
| 6 | +1, −6/255 | 0.50/255 | 6/6，`correctedBits=0` | 28 |
| **4（默认）** | **+1, −4/255** | **0.64/255** | **6/6，`correctedBits=0`** | **14** |
| 2 | +1, −2/255 | 0.78/255 | 6/6，`correctedBits=0` | 36 |

（`|z|` 中位受页面内容与本次载荷图案影响，photo 页四次运行落在 14~42，当余量参考而不是曲线看。）
v4 用同一套配色，但每 bit 观测只有一半：实测 delta=6 六版式仍全部 `mac=OK(验签)`，delta=4 时
dark/mixed 涨到 19/512 弱 bit。**v4 要更淡就用 6 并先在真机复测**；v5.2 用 4。

v5.2 默认 `sync: .none`。`.pn` / `.separated` 是实验导频档：当前实现为恒定 alpha 的单层 RGBA tile
加入公共亮度方向调制，会留下 luma 残差，不能宣传为不可见，也不能跳过 P3/sRGB/OLED 的人工验收。
导频只作用于 `plane: .chroma`：luma 平面把亮度通道全给数据用，此时不写导频、`pilotScore` 无意义
（解析端 CLI 会打警告）。
数据与导频必须一起由 `V52Codec.makeTile` 生成，`delta` 是预乘 alpha 源层幅度，不是简单的 chroma 加法。

v5.2 不走 `Watermark.payloadProvider`（那是零接入 v4 默认载荷的入口）：载荷由 `installV52` 给出，
时间戳在 install 时就固定了；需要新的时间戳就自己再调一次 `updateV52`（例如回前台或换页时）。

解析端显式使用：

```bash
swift build -c release
.build/release/bwdecode shot-v52.png --protocol v5.2 --layout --scale 0.837
# 裁剪 / 比例未知：
.build/release/bwdecode shot-v52.png --protocol v5.2 --auto --layout
```

v5.2 不接受 v4 的 `--bits`、`--key`、`--pages` 和 `--dump-codes`；它没有 HMAC，也不使用 v4 的
15 字符页面注册表，`--offset` 也不接受负值（相位由解码器自己搜索）。自动缩放只在 0.50...1.50 的
粗网格上启动，再用 fractional rectangle averaging
局部精搜；只保证等比缩放和裁剪，不覆盖旋转、透视、拍屏或聊天软件二次压缩。`candidateCount` 大于 1
且输出 `ambiguous` 时必须停止解读，保留原图并交由上游处理。**观测证据看第一行的 `minObs`**：低于 5 次/bit
时解码器输出 `TOO_SMALL(...)` 并拒绝 `--layout`（验收时遇到这种情况要回到更完整的截图重跑，而不是把字段当结论）。

**校验值有两档，都在同一个字段里**：

| 构造方式 | 字段内容 | 解码端 | 能防伪造吗 |
|---|---|---|---|
| `WatermarkPayload(… key:)` | HMAC-SHA256 截断 96 bit | `mac=OK(验签)` | ✅ 能 |
| `WatermarkPayload.selfChecked(…)` | SHA-256 截断 96 bit（公开） | `mac=OK(自检,未验签)` | ❌ 谁都能算 |
| `mac: []` / 全 0 | 没带校验值 | `mac=未签名`，裁剪搜索只能退结构自检 | ❌ |

- **要防伪造、要能定到人**：服务端下发并 HMAC 签名，同时在服务端保留
  「payload → 用户/设备/时间」映射表。客户端自己算 HMAC 等于把密钥交出去。
- **只做质量问题定位**：公开自检值就够（能保证"解对了"），部署成本低。
- 两者都别留空 —— 留空等于把裁剪自愈能力也一起关掉。

**关键区别（决定解析端能不能干活）**：

| 校验值 | 解析端**没有密钥**时 |
|---|---|
| 公开自检值 | 整屏、裁剪、旋转都能解（自检值就是裁决器）—— 实测真机裁剪 20/20 |
| HMAC | 只有整屏图（相位 0,0）能解；**裁剪/旋转搜索没有裁决器**，会退化成按 `\|z\|` 猜 |

所以"截图被裁过也要能溯源"的部署，**必须**填校验值：要么让解析同学拿到密钥，要么用 `selfChecked`。
如果两个都要（防伪造 + 无密钥可裁），可以把 96 bit 拆成 `64 bit HMAC + 32 bit 公开校验值`
（实测 32 bit 校验值在 32768 个候选里假阳性 0；HMAC 降到 64 bit 仍不可伪造）——
这是约定变更、不动字段边界，需要解析端配套改，落地前先对齐。

**字段来源**：

| 字段 | 从哪来 | 注意 |
|---|---|---|
| `uid` | 服务端下发的用户 ID | 客户端自填的话，溯源时不能当身份用 |
| `timestamp` | 当前 Unix 秒 | 每次都变，图案要刷新（见下面的刷新时机） |
| `build` | CI 打包号，12 位十进制 `YYYYMMDDHHMM`（如 `202609161722`），未填给 0 | 外部传入，库不猜 |
| `pageClassName` | 当前页面类名 | 见下面的页面栈陷阱 |
| `note` | 工单号 / 环境描述 / 测试标记，≤ 22 字节 UTF-8（线上实例：`10.1.0\|home`） | 外部传入，超长截断 |
| `app` / `environment` | 产品线 / 环境 | 各 8 bit |

### 页面栈陷阱

水印里存的是**从类名算出来的短码**（15 字符，`PageNameCodec`）。别用
`topViewController()` 直接取类名 —— 顶层常常是 `UIAlertController`、键盘宿主 VC、导航/容器 VC，
解出来会是 `alert` 之类的系统类，`grep` 不到业务页面。用业务自己的页面栈/路由记录当前页。

### 刷新时机

库只在 App 回前台（`didBecomeActive`）重画一次图案，够覆盖时间戳变化。
**换页必须显式调 `Watermark.update(payload:)`**，否则页面短码会停在旧值 —— 这是最常见的接入事故。

## 三、v4 参数与可见性

| 参数 | 默认 | 说明 |
|---|---|---|
| `plane` | `chroma` | 压色度平面（不可见）。`luma` 压亮度平面，肉眼可见，512 bit 下**不可用**（实测文字页弱 bit 139/512 直接判 NO） |
| `delta`（代码里叫 `alpha`） | 8 | 扰动幅度。**下限 2**；解码端不需要知道这个值，但幅度决定余量 |
| `payloadBits` | `payload.count × 8` | v4 载荷固定 512，解码端必须一致 |
| `windowLevel` | `.alert + 1` | 盖在系统弹窗之上；调低就截不到弹窗场景 |

v5.2 不使用 `payloadBits` 参数：信息字段固定 207 bit，物理码字固定 256 bit；由
`WatermarkPayloadV52` 和 `V52Codec` 负责布局。`delta` 仍是 alpha，建议先用 `.chroma`；改变 plane、
alpha 或 sync 后必须重新跑合成、真机和人工可见性验收。

**为什么默认 delta 是 8**：一对色是 `(0,0,a)` 与 `(p,p,0)`，`p = round(0.114a/0.886)`。
a=8 时 p 正好取整到 1，两条色的亮度几乎完全相等 —— 实测水印自己造成的亮度网格只有
**0.026/255**（万分之一灰度级）。其它取值残差都更大：

| delta | 陪色 p | 亮度网格残差 /255 |
|---|---|---|
| 6 | 1 | 0.202 |
| **8（默认）** | **1** | **0.026** |
| 10 | 1 | 0.254 |
| 12 | 2 | 0.404 |
| luma 12 | — | 12.000（可见棋盘格） |

注意上表量的是**亮度轴**。色度轴的极差就是 `delta` 本身（a=8 → 8/255，约 3% 满量程），以 2.67pt
的棋盘格铺满整屏，所以大块纯色 / 渐变页上能看见淡蓝或淡粉的格子 —— 这就是「感觉还是能看到水印」的
来源，跟协议（v4/v5.2）无关，只跟 `delta` 有关。

**所以"太明显"时不要抬 delta** —— 那是可见性上最差的方向；要更淡就**减 delta**（见上面的实测表），
并重新跑真机 + 最暗页面的可见性验收。余量不够的正确解法是把载荷做小
（每 bit 观测数 = 图像面积 / pair 面积 / payloadBits，翻倍载荷就减半余量），或者接受解码端的
`WEAK` 判定（校验值仍能确认对错）。

块大小 8px 不能动：4px 更不易察觉但在 JPEG q80 下实测解不出；16px 更粗但余量崩。

## 四、接入验收（必须做）

```bash
cd Demo && ./sweep.sh "<模拟器UDID>"        # 逐页扫，默认 chroma
cd Demo && ./sweep.sh "<UDID>" 4 luma       # 换平面 / 指定 delta 找余量
cd Demo && ./sweep.sh "" "" chroma v52      # v5.2 逐页扫（第 4 个参数选协议，默认 v4）
```

换成自己的版式后**必须重测，别照抄 README 的数字**。验收清单：

1. 装好水印，逐页截图（含弹窗、输入法、分屏）→ 每页都能解出正确的 uid / build / note
2. 裁掉状态栏再解（模拟分享裁边）→ `--auto` 仍能解对
3. 转成 JPEG q80 再解 → 弱 bit 明显变多但校验值仍通过
4. 在真机（不是模拟器）上过一遍：色域 / displayScale / P3 转换都会影响色度平面
5. 用最暗的背景页看肉眼可见性（深色页最容易看出色度网格）
6. **解析端视角自测一遍**：把截图给解析同学（或自己跑
   `bwdecode shot.png --auto --layout --pages pages.json`，**不带 `--key`**），
   必须能读出 uid / build / note，并且 `mac` 不是 `未签名`/`未校验` ——
   这两档意味着裁过的图将来解不出来
7. 若接入的是 v5.2，改跑
   `bwdecode shot-v52.png --protocol v5.2 --auto --layout`，确认 `crcStatus=OK(完整性自检,未验签)`、
   `candidateCount=1` 且 `minObs ≥ 5`，并把 `scale` / `phase` / `correctedBits` / `minObs` 记录到
   验收单；CRC 通过只证明完整性与“解对了”，**不是防伪证明**（v5.2 没有 HMAC，输出里不会出现 `mac=`）。
8. pilot 用 `.pn` / `.separated` 时必须单独记录亮度残差并做 P3/sRGB/OLED 人工检查，不得以导频
   相关性分数代替可见性结论。
9. 截图通道确认：解析依赖**设备像素原图**。图片消息通道会重编码/缩放（企业微信 `_HD/` 里存的是
   原始文件，能读；图片消息里的小图、缩略图不行），要求上报走文件/工单附件通道

## 五、常见坑

| 现象 | 原因 |
|---|---|
| 解出来 `mac=BAD` / 字段全是乱的 | 接入端与解码端的 `plane` / `payloadBits` 不一致（会静默解出自洽但错误的结果） |
| 页面短码不对 | 用 `topViewController()` 取到了系统 VC；或者换页没调 `Watermark.update` |
| 截图完全没有水印 | 水印窗口没挂上：静态链接丢掉了 ObjC `+load` 目标文件（App target 加 `-ObjC`），或 `windowLevel` 被调低 |
| 弹窗 / 键盘截不到水印 | `windowLevel` 低于那些系统窗口 |
| 只有一台设备解不出 | displayScale / 色域差异；在真机上复测，别用模拟器结论下判断 |
| 解码端说"未签名" | 载荷 `mac` 全 0 —— 填公开自检值或走服务端签名 |
| v5.2 解码成 v4 垃圾字段 | 未显式传 `--protocol v5.2`；迁移期间用 `--protocol auto`，稳定接入后固定协议 |
| v5.2 报 `ambiguous` | 多个 CRC-valid 候选同时存在；保留原图、不要手选，检查 phase / scale / tile 覆盖 |
| v5.2 pilot 很容易看见 | `.pn` / `.separated` 是亮度残差实验；先退回 `.none`，再按人工可见性流程复测 |
| v5.2 报 `TOO_SMALL` | 截图太小 / 被裁得太狠（每 bit 观测 < 5 次）；让上报方发完整原图，不要用解出的字段下结论 |
| v5.2 的 `pilotScore` 看着像噪声 | 导频只作用于 `plane: .chroma`；luma 平面下这个值是没意义的，改用 chroma 或退回 `.none` |

## 六、合规

水印携带设备与时间信息，属个人信息处理：

- 隐私政策必须写明用途与范围，不得用于告知目的之外的追踪
- uid 与服务端映射表只用于**处理已上报的问题**，不要外传、不要和用户身份做二次绑定
- 技术上能做 ≠ 合规能做；上线前让法务过一遍
