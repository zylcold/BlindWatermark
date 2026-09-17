---
name: blind-watermark-integration
license: MIT
description: 在 iOS App 里接入屏上盲水印（BlindWatermark）：把肉眼不可见的载荷嵌进界面，让截图能溯源到设备/时间/构建号/页面。用户要「接入水印」「装上盲水印」「水印怎么集成」「参数怎么配」「水印太明显」「接入验收」「sweep 复测」时使用。只读截图、解析水印请用 blind-watermark skill（那边是本 skill 的对端）。
---

# 盲水印接入（App 侧）

把 BlindWatermark（`zylcold/BlindWatermark`）装进 App：整个界面常驻一层肉眼不可见的色度扰动，
截图必然被带上，事后由解码端反查出**设备 / 时间 / 构建号 / 页面**。

**本 skill 只管接入。** 解析截图、判读校验值、排查解不出，看
[`blind-watermark`](../blind-watermark/SKILL.md) —— 它的「容量与布局」一节是字段契约，
本 skill 构造的载荷必须严格符合它（否则解出来自洽但错误）。

---

## 一、最快接入

```swift
import BlindWatermark

// 装水印（服务端下发并签名的载荷最可靠）
Watermark.install(payload: serverIssuedPayload)

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

## 三、参数与可见性

| 参数 | 默认 | 说明 |
|---|---|---|
| `plane` | `chroma` | 压色度平面（不可见）。`luma` 压亮度平面，肉眼可见，512 bit 下**不可用**（实测文字页弱 bit 139/512 直接判 NO） |
| `delta`（代码里叫 `alpha`） | 8 | 扰动幅度。**下限 2**；解码端不需要知道这个值，但幅度决定余量 |
| `payloadBits` | `payload.count × 8` | v4 载荷固定 512，解码端必须一致 |
| `windowLevel` | `.alert + 1` | 盖在系统弹窗之上；调低就截不到弹窗场景 |

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

**所以"太明显"时不要抬 delta** —— 那是可见性上最差的方向。余量不够的正确解法是把载荷做小
（每 bit 观测数 = 图像面积 / pair 面积 / payloadBits，翻倍载荷就减半余量），或者接受解码端的
`WEAK` 判定（校验值仍能确认对错）。

块大小 8px 不能动：4px 更不易察觉但在 JPEG q80 下实测解不出；16px 更粗但余量崩。

## 四、接入验收（必须做）

```bash
cd Demo && ./sweep.sh "<模拟器UDID>"        # 逐页扫，默认 chroma
cd Demo && ./sweep.sh "<UDID>" 4 luma       # 换平面 / 指定 delta 找余量
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
7. 截图通道确认：解析依赖**设备像素原图**。图片消息通道会重编码/缩放（企业微信 `_HD/` 里存的是
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

## 六、合规

水印携带设备与时间信息，属个人信息处理：

- 隐私政策必须写明用途与范围，不得用于告知目的之外的追踪
- uid 与服务端映射表只用于**处理已上报的问题**，不要外传、不要和用户身份做二次绑定
- 技术上能做 ≠ 合规能做；上线前让法务过一遍
