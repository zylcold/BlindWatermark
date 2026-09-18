---
name: blind-watermark
license: MIT
description: 从 iOS 截图中读出屏上盲水印 payload，用于定位截图来自哪台设备、什么时间、哪个构建、哪个页面。用户给出截图并要求「读水印」「解析水印」「这截图谁发的」「盲水印」「溯源」「watermark」，或询问水印容量上限、能藏几个字、有哪些限制时使用。往 App 里装水印 / 调参数 / 接入验收请用 blind-watermark-integration。
---

# 截图盲水印解析

LoveLink iOS 端在整个界面上常驻一层肉眼不可见的色度扰动（BlindWatermark，`zylcold/BlindWatermark`）。
截图会把这层扰动带进来，于是**任何一张原始全屏截图都能反查出设备、时间、构建号与页面**。

用途：用户甩一张截图过来，先解水印拿到设备/时间线索，再结合代码定位问题。

**本 skill 只管解析（读截图）。** 往 App 里装水印、调参数、做接入验收看
[`blind-watermark-integration`](../blind-watermark-integration/SKILL.md) —— 参数与载荷构造的约定在那边，
两边必须一致（`payloadBits` / `plane` / `delta` / 载荷布局）。

先确认截图来源协议：默认是 v4；如果接入端调用了 `Watermark.installV52`，解析必须使用
`--protocol v5.2`（或在迁移期使用显式 `--protocol auto`）。v4 的 64 字节布局与 v5.2 的 26 字节信息字段 / 32 字节
BCH 码字不能混解。

**最短路径**（有 `--key` 时）：

```bash
BW_REPO=/path/to/BlindWatermark
swift build -c release --package-path "$BW_REPO"
"$BW_REPO/.build/release/bwdecode" shot.png --auto --layout --pages pages.json --key <hex>
```

`mac=OK` → 结论可直接用，拿 uid / time / page 去查日志。`mac=BAD` 或 `NO` → 见[限制](#三限制)与[排查](#标准排查流程)。

---

## 一、v4 容量：512 bit = uid + Unix 秒 + build + 15 字符页面短码 + note + 校验

```
[511:480] uid        32   UInt32   用户 ID 原样放，不用截断、不用查表
[479:448] timestamp  32   UInt32   Unix 秒，精确到秒且够用到 2106 年
[447:384] build      64   UInt64   构建号，12 位十进制 YYYYMMDDHHMM（如 202609161722），0 = 未填
[383:288] pageCode   96           页面类名短码，15 个字符 = 90 bit（多出的 6 bit 必须为 0）
[287:272] tag        16   UInt16   App(8) / 环境(8)
[271: 96] note      176           自定义 note，22 字节 UTF-8
[ 95:  0] 校验值     96            HMAC-SHA256(前 52 字节, 服务端密钥) 截断，或公开自检值
```

64 字节，字段全小端。**512 bit 是上限**：每 tile 只有 512 个 pair，再大连 1 份都放不下。
代价是每 bit 观测减半：iPhone 16 截图（1179×2556，23287 个 pair）下每 bit 约 **45 次观测**，
`|z|` 大致是 256 bit 布局的一半（弱 bit 变多，但校验值仍能确认对错）。

**layout v3（256 bit / 32 字节）已废弃** —— 字段边界变了，老截图用现在的解码器解不出。
要读 2026-09 之前的老图，用 1.0.0 tag 的解码器。

### v5.2 紧凑协议（显式 opt-in）

v5.2 与 v4 并存，默认渲染与默认解码仍是 v4。接入端用
`Watermark.installV52(payload:delta:plane:sync:)`，解析端用
`bwdecode shot.png --protocol v5.2`；旧版裸 `--auto` 仍只做 v4 相位/平面搜索，迁移期混合探测请显式
`--protocol auto`（先试 v5.2，再回退 v4），想固定旧行为可显式 `--protocol v4`。两套协议的载荷、码字和输出字段不能混用。

v5.2 的信息字段固定为 207 bit：`profile(4)`、`uid(32)`、UTC 2026-01-01 起的
`timestamp(31 秒)`、`buildTime(24 分钟)`、`page(42，8 字符 base37)`、`app(14)`、
`note(32，6 字符 base37)`、`CRC24(24)` 和 `reserved(4)`。字段按低位优先写入 26 字节；CRC24
覆盖前 179 bit，校验通过只说明完整性与解码候选一致，不能替代 HMAC 验签。`page` 沿用
`PageNameCodec` 归一化后取 8 字符，`note` 只接受 `[a-z0-9_]` 且不超过 6 字符，尾部 `_` 是填充，
字面尾部 `_` 不可区分。

物理码字是 BCH(255,207,t=6) 加一位整体偶校验，256 px tile 放两份相反业务极性的码字。
解码器会收集并去重 CRC-valid 候选；不同 payload 同时通过时返回 `ambiguous` 并拒答，不按首个候选
静默裁决。已知比例可传 `--scale 0.837`；自动路径在 0.50...1.50 粗网格上继续局部精搜，并使用
fractional rectangle averaging。它只覆盖等比缩放和裁剪，不覆盖旋转、透视、拍屏或聊天软件二次压缩。

`.none` 是默认导频档；`.pn` / `.separated` 只用于实验测量。当前实现的导频在恒定 alpha 的单层 tile
里加入公共亮度方向调制，会留下可测的 luma 残差，因此不能宣称不可见，也不能替代 P3/sRGB/OLED 人工验收。
导频只作用于 `--plane chroma`：`--plane luma` 下的亮度通道全给数据用，不写导频，`pilotScore` 无意义
（CLI 会就此打警告）。
只有 `--protocol v5.2` 会启用 `--pilot`；v5.2 不接受 v4 的 `--bits`、`--key`、`--pages` 或
`--dump-codes`，因为它没有 HMAC，也不使用 v4 的 15 字符注册表；`--offset` 也不接受负值（相位由解码器
自己搜索，负相位会被直接拒绝）。

v5.2 第一行输出包含 `protocol=v5.2`、payload、`plane`、`pilot`、`phase`、`scale`、
`correctedBits`、`softRecovery`、`pilotScore`、`candidateCount`，加上证据档 `minObs` / `avgObs` /
`|z|中位` 与 `OK(...)` / `TOO_SMALL(...)` 裁决；`--layout` 第二行给出紧凑字段和
`crcStatus=OK(完整性自检,未验签)`。**v5.2 没有 HMAC**：CRC24 只是完整性自检，措辞里不会出现 `mac=`，
也不许把它讲成验签。证据门槛与 v4 同一把尺（每 bit 观测 ≥ 5 次）：低于门槛时输出 `TOO_SMALL(...)`，
加 `--layout` 直接 exit 1 拒答 —— 图小的时候优先让用户发原图，不要拿解出的字段去做溯源结论。
Python 镜像支持相同参数：`python3 tools/bwdecode.py ...`；修改 v5.2 编解码时必须同时
更新 `Sources/BlindWatermarkCore/V52Codec.swift` / `V52BCH.swift` 与 `tools/bwdecode.py`，并运行
`python3 tools/test_bwdecode.py` 做跨语言 PNG 对账。

### 页面类名怎么进来：短码 + grep

v4 水印里放的是**从类名算出来的 15 字符短码**，不是索引、更不是完整类名（装不下）。
它利用 iOS 命名的高冗余，把 `ViewController` 这类每个页面都有的词缀剥掉：

```
BHProfileViewController        → profile
BHChatListViewController       → chatlist
BHLiveRoomViewController       → liveroom
BHUserProfileEditViewController → userprofileedit   （15 字符，恰好不截断）
```

拿到短码后 `grep -rin "class.*userprofileedit" --include='*.swift'` 就能定位类名 —— **不需要注册表**。
15 字符对绝大多数页面够用（剥掉冗余词缀后本来就 ≤ 15）；真撞名也只是拿到 2~3 个候选。

算法（`PageNameCodec`，编解码只有这一份实现）：
1. 取类名最后一段（丢掉 `Module.` 前缀）
2. 按长度降序剥**词尾**后缀，最多两层：`ViewController` / `ViewModel` / `Presenter` /
   `Interactor` / `Controller` / `View` / `Page` / `Screen` / `Scene` / `Cell` / `Item` / `Model` / `VC`
3. 剥已知 App 前缀：`BH` / `JY` / `LL` / `HW` / `XQ`
4. 转小写，只留 `a-z0-9`
5. 取前 15 字符，每字符 6 bit 打包成 12 字节（37 符号表，补位符 `_`）

页面变化时 `Watermark.update(payload:)` 重画图案（相位不变，解码端无感，微秒级）。

### 密钥归属

**密钥只在服务端持有**：服务端算好 mac 下发完整 32 字节，客户端只负责渲染；解码端 `--key` 校验。
客户端自己算 mac 等于把密钥交出去。96 bit mac 已足够挡住伪造与针对性碰撞。

### 余量（实测，chroma + delta 8，iPhone 16 模拟器，512 bit 布局）

| 页面 | \|z\|中位 | 最弱 | 弱 bit |
|---|---|---|---|
| plain（近纯色渐变） | 120.3 | 4.1 | 0/512 |
| whitechat（纯白 + 气泡文字） | 113.8 | 4.7 | 0/512 |
| textlist（文字密集，最差场景） | 120.6 | 2.9 | 1/512 |
| photogrid（照片网格） | 35.0 | 6.6 | 0/512 |
| darkmode（深色卡片） | 113.8 | 1.9 | 4/512 |
| mixedfeed（上白下黑 + 照片） | 54.9 | 2.1 | 4/512 |

阈值 3（判定阈值是 512/8 = 64 个弱 bit）。色度平面上灰阶内容恒为零，所以文字页与纯色页的
`|z|` 同样高，只有大面积彩色照片会把 `|z|` 拉低。

**512 bit 下判定常见 WEAK，但那只是"弱 bit 不为 0"**：上面几页弱 bit 只有 0~4 个，
离 64 的阈值很远，而 `mac=OK(自检/验签)` 已经确认解对了 ——
**判读以校验值为准，弱 bit 只作余量参考**。最苛刻内容（照片壁纸 + 图标）实测：
delta 8 → 弱 bit 32/512，delta 10 → 22，delta 12 → 9。

**别用 luma**：512 bit 下实测 delta 12 都救不了（文字页弱 bit 139/512、照片页 103/512，判 NO）。

## 二、怎么用

### 判定优先级

1. `mac=OK(验签)` / `mac=OK(自检,未验签)` —— 载荷可信，直接用 uid / time / page / build / note。
   **两种都能做裁剪与旋转搜索**：`自检` 不需要密钥（载荷自带 SHA-256 截断 96 bit 校验值），
   与有密钥同级 —— 实测全搜索空间（64 相位 × 512 tile 平移 = 32768 候选）假阳性 0、真机裁剪 20/20。
2. `mac=未签名(…)` —— 载荷没带校验值：整屏图字段可用，**被裁过的图不能信**（退结构自检，
   实测真机 20 例错 1 个）。要么让对方发没裁过的图，要么让接入端补校验值。
3. `mac=未校验(需要 --key)` —— 载荷是 HMAC 签名而手里没密钥。**这种才真的需要密钥**：
   整屏图字段能用（相位 (0,0) 没有歧义），但裁剪 / 旋转搜索缺裁决器，只能退到下一档兜底。
4. `mac=BAD(…)` —— 当失败处理，不要硬解读数字。

### 没有校验值时的兜底：语义一致性

`mac=未签名` / `mac=未校验` 且图被裁过时，别直接按 `|z|` 排序信结果 —— 错误旋转同样能给出
高 `|z|` 的自洽载荷。可按这条流程人工核对：

1. 枚举全部候选（64 相位 × 512 tile 平移 × 双平面），只留**语义自洽**的：
   时间戳落在 2015~2100、build 要么为 0 要么是日历合法的 12 位 `YYYYMMDDHHMM`、
   note 必须是合法 UTF-8、15 个短码字符都落在 37 符号表内（即 `WatermarkPayload.isPlausible`）
2. 看**跨候选一致性**：多个相位 / 相邻 rotation 是否给出同一份字段
3. **如实标注"未验签"**并列出前几名供人工判断

实测（一张真实客户端截图，1092×956 区域截图）：32768 个候选里只有 17 个语义自洽，
其中 14 个给出同一份载荷，另外 3 个只差 1~2 bit（短码 714s/715s、note 尾部填充），
核心字段（uid / time / build / note）完全一致 —— 该图同时带公开自检值，
`mac=OK(自检,未验签)` 与这条投票结果互相印证。

兜底只是"没有校验值时的次优解"：近似解也可能语义自洽（实测 v3 布局下结构自检会放过 17 个、
固定 magic 方案放过 4 个），**结论必须标注未验签**。

### 解码端（本 skill）

```bash
# 常规（最快，0.07s）
"$BW_REPO/.build/release/bwdecode" shot.png --layout --pages pages.json --key <hex>
# 截图被裁过 / 不确定平面（0.14s，穷举 + 校验值裁决）
"$BW_REPO/.build/release/bwdecode" shot.png --auto --layout --pages pages.json --key <hex>

# 平面 / 位数确定，只是相位不确定（裁边但没缩放过）
"$BW_REPO/.build/release/bwdecode" shot.png --auto-offset --layout --pages pages.json --key <hex>

# 对照注册表里的短码
"$BW_REPO/.build/release/bwdecode" --pages pages.json --dump-codes
```

v5.2 的最小调用是：

```bash
"$BW_REPO/.build/release/bwdecode" shot-v52.png --protocol v5.2 --layout --scale 0.837
# 裁剪且比例未知：显式保留 v5.2，再让它搜索 phase / tile / 0.50...1.50 比例
"$BW_REPO/.build/release/bwdecode" shot-v52.png --protocol v5.2 --auto --layout
```

v5.2 输出的 `crcStatus=OK` 只代表 CRC 完整性；需要防伪时仍应使用 v4 的 HMAC 部署，或在服务端
为 compact payload 建立签名封装。看到 `ambiguous` / 非零退出码时停止解读并保留原图，不要从多个候选
中手工挑一个。

**优先用 `--auto`。** 裁剪过的图（截掉状态栏、分享时裁边）会让载荷整体**旋转**
却依然自洽：`|z|` 中位依然很高、弱 bit 0/256，输出看着完全正常，但 uid/时间/页面全是错的。
`--auto` 穷举 2 平面 × 64 相位 × 512 tile 平移（位数只加显式给的 `--bits`），只有校验值能识别出正确那一组。
纵向、横向裁剪都覆盖（含半 pair 偏移与奇数块偏移）。

**没密钥也行，只要载荷带了公开自检值**：解码器先验 HMAC（有密钥时），再验载荷自带的
SHA-256 自检值（无密钥也能验），两侧都过不去才退结构自检并打警告。
实测（4 页面 × 5 种裁剪 = 20 个用例）：带自检值 **20/20 解对**，`mac` 全 0 的载荷 19/20（近似解会漏网），
HMAC 签名但拿不到密钥的**解不了**（没校验器）—— 这时候只能去要密钥。

`--auto-offset` 是它的收窄版：假定 `--bits` / `--plane` 已经给对（默认 512 / chroma），只穷举
**块网格相位（mod 8）与 tile 平移**，同样走校验值阶梯。它与 `--offset` 互斥（同时给直接报错退出），
与 `--auto` 语义重叠（也别一起给）。
载荷没带校验值（`mac` 全 0）而调用方也没给 `--key` 时，它只能按 `|z|` 中位裁决 —— stderr 会打印警告，
输出标注 `mac=未签名`，**不保证正确**，这时必须看 `弱bit`，并用 `--layout` 检查字段是否合理。

输出（两行）：

```
payload=0xefbeaddea5b6ab6afa75722c2f00000013714d0b224d2449922449020100686f746669782d332d7469636b65742d3132333435000137c71963ff8df233001204  payloadBits=512  平面=chroma  相位=(0,0)  signal=9.00  |z|中位=114.5  最弱=2.9  弱bit=1/512  WEAK(1/512 bit 证据不足，结论谨慎)
uid=3735928559(0xDEADBEEF)  time=2026-09-17 09:45:09 UTC  page=textlist → BHTextListViewController  build=202609161722  note=hotfix-3-ticket-12345  layout=v4 app=1 env=0  mac=OK(自检,未验签)
build 时间: 2026-09-16 17:22（构建方当地墙上时间）
```

| 字段 | 含义 |
|---|---|
| `payload` | 原始载荷 hex，小端字节序 |
| `payloadBits` | 有效位数，必须与接入端一致 |
| `平面` | `chroma`（默认，不可见）或 `luma` |
| `相位` | 图案的像素偏移，整屏截图恒为 `(0,0)` |
| `signal` | 平均特征差。chroma 默认参数下约 9。**它被内容撑大，不能拿来判断成功率** |
| `\|z\|中位` / `最弱` | 各 bit 显著度。历史 256 bit + chroma 实测中位 29~161；v4/v5.2 应以当前协议测试为准 |
| `弱bit` | \|z\| < 3 的 bit 数，**判读就看它** |
| `uid` / `time` / `page` / `tag` | `--layout` 解出的字段；`page` 是短码，后面带注册表命中或 grep 提示 |
| `mac` | 校验分档（见下），**判读优先级最高**。v5.2 没有 `mac` 字段，只有 `crcStatus` |
| 末尾判定 | `OK` 弱 bit=0 可信；`WEAK` ≤1/8 弱 bit 要交叉验证；`NO` 大概率没水印；**`TOO_SMALL` 图太小，解码器拒绝解读字段** |
| v5.2 专用 | `minObs` / `avgObs`（每 bit 最少 / 平均观测数）、`correctedBits`（BCH 纠错位数）、`softRecovery`、`pilotScore`（仅 chroma 导频，仅诊断）、`candidateCount`；**证据看 `minObs`，裁决看行末的 `OK(...)` / `TOO_SMALL(...)`** |

校验分档（`--layout` 第二行末尾）：

```
mac=OK(验签)                    HMAC 通过，账号/时间可信且未被伪造
mac=OK(自检,未验签)             公开自检值通过 —— 证明"解对了"，不证明"没被伪造"
mac=未签名(字段自洽,退结构自检)     载荷没带校验值；裁剪场景下结论不可信
mac=未校验(需要 --key)         载荷带 HMAC 但没密钥
mac=BAD(密钥不符或载荷被改)      给了密钥且两种校验都对不上
```

判定与校验值冲突时以校验值为准：`WEAK`/`NO` 但 `mac=OK(...)` 仍是正确载荷（只是余量小）；
`mac=未签名` 且图被裁过 → 必须告知用户结论不可靠；`mac=BAD` 一律当失败。

**没编 Swift / 在别的机器上**：`tools/bwdecode.py` 是同逻辑的 Python 实现，
参数、输出格式、判读规则完全一致（需要 numpy + Pillow）：

```bash
python3 "$BW_REPO/tools/bwdecode.py" shot.png --auto --layout --pages pages.json --key <hex>
```

两条实现由 `python3 "$BW_REPO/tools/test_bwdecode.py"` 对账（合成图回环 + 裁剪 + 篡改检测 +
页面短码 + 同一张 PNG 与 Swift 版比对）。Python 版实测：常规 0.21s，`--auto` 0.28s。

### 标准排查流程

1. **先看有没有 `trim=(左,上,右,下)`**：IM 转发 / 图片查看器给截图套的黑边会被自动裁掉，`phase` 随之
   相对裁剪后的图。黑边不裁会在交界列制造固定方向的假差分，按 tile 周期反复砸同一批 bit，整张图解不出；
   显式 `--offset` 时脚本不裁（那种情况下自己把黑边裁掉再传 `--offset`）。深色页留白不会被误裁。
2. **先看判定里有没有 `TOO_SMALL`**：图太小或图案已被破坏（每 bit 观测 < 5 次），解码器会拒答。
   别拿小裁剪图硬解 —— v4 的 512 bit 实测需要约 2700 个 pair（整宽 1179 时约 300px 高），
   482×440 这类小图只有 1.5~3.2 次/bit，必然拒答；v5.2 的 256 bit 码字只要约 1280 个 pair
   （整宽 1179 时约 150px 高），同一张 300×300 小图实测只有 2.6 次/bit，同样拒答。
   让对方发**原图 + 更大范围**。
3. **看病灶在哪一层**：`mac` 是哪个档（有没有校验值）+ 图有没有被裁过。
   `自检` / `验签` 档被裁过也能解；`未签名` / `未校验` 且被裁过 → 走上面的语义一致性兜底，并标注未验签。
4. 看判定：`NO` → 画面里大概率没水印（系统界面、别的 App）；`WEAK` → 必须结合日志/用户描述交叉验证。
5. 核对 `signal` 与平面是否自洽（chroma 约 9，luma 约等于 delta）。明显偏离说明图案没对上或 `--plane` 给错。
6. 加 `--layout` 解出 uid / time / page / build / note，加 `--pages` 把页面短码还原成类名。
   输出 `page=xxxxx（注册表无命中…）` 说明这张截图不是这份注册表登记的版本，或者该页面没登记过；
   短码是从类名算出来的，按提示 `grep` 类名即可，不需要表也能定位。
7. uid + time 直接去日志/Sentry 定位问题（build / note 还能把范围缩到具体构建与页面）。
   `--layout` 直接给出可读时间与构建时间，不用再算环绕或时间桶。

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
let result = BlockCodec.decode(image, payloadBits: 512, plane: .chroma)!
print(result.payloadBytes)                       // 64 字节
let fields = WatermarkPayload(bytes: result.payloadBytes)
print(fields.uid, fields.timestamp, fields.pageNameCode)  // pageNameCode 拿去 grep

// 参数不确定时：穷举 + MAC 裁决
let key = SymmetricKey(hex: serverKeyHex)!
let best = BlockCodec.decodeBest(image, validate: { decoded in
    guard let f = WatermarkPayload(bytes: decoded.payloadBytes) else { return false }
    return f.isValid(key: key)
})!

// 平面 / 位数已知，只想求相位：给它一个校验器，否则它只是「块对齐最好」不代表解对了
let offset = BlockCodec.findBestOffset(in: image, payloadBits: 512, plane: .chroma, validate: { decoded in
    guard let f = WatermarkPayload(bytes: decoded.payloadBytes) else { return false }
    return f.isValid(key: key)
})
```

---

## 三、限制

### 拿不到水印的情况

| 情况 | 结果 | 处理 |
|---|---|---|
| **v4 截图被缩放过**（微信转发、聊天软件压缩、任何 resize） | ❌ 完全解不出 | v4 块边长与平铺周期一起变了。让用户重发**原图**；v5.2 可试显式 `--scale` 或 `--protocol v5.2 --auto` |
| **拍屏**（另一台手机拍屏幕） | ❌ 解不出 | 摩尔纹 + 几何畸变。需要同步模板或深度学习方案，本仓库不做 |
| 截图被裁剪（裁掉状态栏、分享时裁边） | ⚠️ 需要补偿 | 给 `--auto`：纵横向裁剪都能搜回来（含半 pair 与奇数块偏移）；裁决靠 HMAC（需 `--key`）或载荷自带的公开自检值 |
| 非整屏截图（只截一部分区域） | ⚠️ 需要补偿 | 同上，给裁剪原点相对整屏的偏移 |
| 画面里根本没有水印（系统界面、别的 App） | `NO` | 正常，`\|z\|` 中位约 0.5、弱 bit 32/32 |
| 色度结构恰好是 8px 尺度的画面（对抗样本） | ⚠️ 退化 | 必须判成 `WEAK`/`NO`，不允许静默给错结果（有测试兜底） |

### 参数必须对齐，否则会静默解错

`payloadBits` 给错时，bit 的分组方式变了，结果是一份**自洽但错误**的载荷 —— 置信度可能依然很高。
`plane` 给错通常直接判 `NO`。所以解读之前**先确认接入端用的参数**，不要靠默认值蒙。

### 别把 luma 当 v4 备选

默认 `delta 8` 是给 **chroma** 定的。v4 512 bit 布局下 luma 平面余量不够：
`delta 6` 时六页里弱 bit 4~182/256、文字页直接解错；`delta 12` 才让纯色/白底/深色页回到 0/256，
文字页仍然是 `mac=BAD`。**v4 要 512 bit 就用 chroma**，需要 luma 只能砍位数并实测；v5.2 也应先用 chroma，
pilot 档的 luma 残差另行验收。

### 载荷是谁造的，决定了能查到什么

- 服务端 HMAC 签名 +「payload → 用户/设备/时间」映射表 → 能定到人和设备（最可靠）
- 客户端填公开自检值 → 能自检解对，但 **uid 是客户端自己填的，可伪造**、没有映射表也定不到人
- 零接入默认载荷（`WatermarkDefaultPayload`）→ uid 是 IDFV 哈希，不可逆、可伪造，只够跑通链路

看到 `mac=OK(自检,未验签)` 时别把 uid 当身份：它只证明"解对了"。

### 其他

- 水印窗口 `windowLevel = .alert + 1`，盖在系统弹窗之上；`isUserInteractionEnabled = false`，不影响输入。
- iPad 分屏、外接屏每个 scene 各挂一个窗口，已处理；displayScale 中途变化不会重画图案。
- 色彩管理：截图若经过 sRGB/P3 转换，chroma 模式比 luma 模式更抗（亮度不变性）。
- 平坦区域亮度残差 0.07/255（chroma + delta 8），肉眼看不出；luma 模式是 6/255，能看出网格。

---

## 四、合规

水印携带设备与时间信息，属个人信息处理。只在**处理用户已上报的问题**时使用，
不要把 payload 与设备身份绑定后另作追踪，也不要外传映射表。
