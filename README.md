# BlindWatermark

iOS 屏上盲水印：整个 App 界面常驻一层肉眼不可见的亮度扰动，截图必然被带上，
事后从截图反查出**设备与时间**，用于定位用户上报的问题。

不 hook 截屏 API。截图走 render server 合成，水印窗口的像素天然进产物。

## 原理

- 覆盖全屏的是 **16×16 像素块**平铺图案，不是单像素噪点 —— 块内平坦，过 JPEG 不会被抹掉。
- 每两个相邻块 (A, B) 编码 1 bit：`1` → A 压暗 B 提亮；`0` → A 提亮 B 压暗。
- 解码取 `d = mean(A) − mean(B)`：压暗块的减益是 `−base·α`，提亮块的增益是 `(255−base)·α`，
  两者相加把 `base` 抵消 → `d ≈ ∓alpha`。**与底色无关**，白底、黑底、深色照片都能解。
- 同一个 bit 的多份重复观测里**隔一份翻转极性**：水印分量同向累加，画面自身的亮度梯度正负相消。
- 读码不是取符号，而是按带符号差值累加后除以标准误得到 z 值：水印随观测次数线性累加，
  内容噪声按 `1/√n` 衰减。手机截图几十个 tile 重复，每个 bit 上百次观测。

## 接入

### Swift Package Manager

```swift
.package(url: "git@github.com:zylcold/BlindWatermark.git", branch: "main")
```

```swift
import BlindWatermark

// 方式一：一行接入。设置 payload 并挂载，后续新 scene 自动跟上
Watermark.install(payload: serverIssuedPayload)

// 方式二：零代码。只提供 payload 来源，窗口挂载由 ObjC +load 接管
Watermark.payloadProvider = { serverIssuedPayload }
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
| `payload` | — | 32 bit 载荷，低位在前 |
| `payloadBits` | 32 | 有效位数 1...32，解码端必须一致 |
| `delta`（代码里叫 `alpha`） | 3 | 扰动幅度。**下限 2**，更低会被色域转换与量化吃掉 |
| `offsetX/offsetY` | 0 | 解码时的图案相位，截图被裁过才需要 |

## 解码

```bash
swift build -c release
.build/release/bwdecode shot.png [--bits 32] [--offset X,Y]
```

```
payload=0x00ABCDEF  高16位=0x00AB  低16位=0xCDEF  payloadBits=32  相位=(0,0)  signal=3.00  confidence=74.5  OK
```

`confidence` 是各 bit 显著度 `|z|` 的**最小值**，即最弱那 bit 的可靠度。
`>= 3` 每 bit 可靠，`1.5 ~ 3` 勉强，`< 1.5` 画面里大概没有水印。

Agent 用法见 [`.agents/skills/blind-watermark/SKILL.md`](.agents/skills/blind-watermark/SKILL.md)。

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

**未验证**：拍屏（另一台手机拍屏幕）—— 摩尔纹与几何畸变会让块网格完全歪掉，需要同步模板 +
深度学习那一路方案，本仓库不做。**截图被缩放也解不出来**（块边长与平铺周期一起变了），
只支持原始设备像素分辨率。

## 合规

水印携带设备与时间信息，属个人信息处理。必须在隐私政策里明确告知用途与范围，
不得用于告知目的之外的追踪。技术上能做 ≠ 合规能做。

## License

MIT
