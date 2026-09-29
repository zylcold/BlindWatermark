# BlindWatermark

代码版本：**3.0.0** · 协议：**v6** · [English](README.en.md)

在 iOS 界面上叠加低幅度色度水印，从截图中离线恢复 uid、时间、构建时间、页面短码、app 和 note，无需服务端回查。Swift 运行时只使用系统框架，支持 iOS 13 / macOS 11；Demo 最低 iOS 15。

当前只支持 v6，历史截图需使用对应历史版本工具。默认 `delta=4`、`plane=chroma`。CRC24 用于完整性自检，不代表验签或身份认证；水印观感需在目标设备上验收。

## 安装

v6 目前从 `main` 分支接入。Swift Package Manager 添加 `https://github.com/zylcold/BlindWatermark.git`，选择分支 `main` 和产品 `BlindWatermark`。正式版本见 [Releases](https://github.com/zylcold/BlindWatermark/releases)。

CocoaPods 将三个模块指向同一来源：

```ruby
watermark_source = { :git => 'https://github.com/zylcold/BlindWatermark.git', :branch => 'main' }
pod 'BlindWatermarkCore', watermark_source
pod 'BlindWatermarkAutoLoad', watermark_source
pod 'BlindWatermark', watermark_source
```

## 接入

在主线程配置载荷：

```swift
import BlindWatermark

guard let payload = WatermarkPayload(
    uid: 123456,
    timestamp: UInt64(Date().timeIntervalSince1970),
    buildTime: 1_790_064_000, // 示例值；接入时由构建流水线写入真实 UTC Unix 秒
    pageClassName: "BHUserProfileViewController",
    app: 11,
    note: "ticket"
) else { fatalError("载荷超出 v6 范围") }

Watermark.install(payload: payload) // delta=4, plane=.chroma
// 换页或刷新时间时构造新载荷，再调用 Watermark.update(payload: newPayload)。
```

| 字段 | 位数 | 范围 / 语义 |
|---|---:|---|
| uid | 32 | 业务侧稳定的 UInt32 编码 |
| timestamp | 31 | UTC 2026-01-01 起的秒偏移 |
| buildTime | 24 | 同一起点的分钟偏移，输入 Unix 秒向下取整 |
| page | 42 | 最多 8 字符 base37 短码 |
| app | 14 | 0…9999 |
| note | 32 | 最多 6 字符 base37 短码 |

base37 字母表为 `a-z0-9_`，解码会去掉尾部 `_`。`pageClassName` 去模块名、常见类前后缀，转小写并截取 8 字符；短码可能碰撞。`note` 只接受上述字符；使用 `pageCode:` / `noteCode:` 构造器时，超长或非法字符直接拒绝。

ObjC `+load` 会自动挂载。未配置时 uid 为 IDFV 的 FNV-1a 哈希，时间为刷新时间，构建时间为协议起点，page/note 为空、app=0；业务接入应显式提供载荷。也可设置 `Watermark.payloadProvider`，在未显式 install 时每次刷新生成载荷。每个 scene 使用一个不接收触摸、不成为 key window 的水印窗口。

## 截图解码

```bash
swift build -c release
.build/release/bwdecode shot.jpg --layout
.build/release/bwdecode shot.jpg --layout --scale 0.837
```

默认自动搜索比例和相位；已知比例可传 `--scale`，有效范围为 0.5…1.5。`--plane` 必须与生成端一致，默认 chroma；luma 为实验档。`--offset X,Y` 指定非负像素相位并关闭自动黑边裁剪；未指定时，输出的 phase 相对于裁剪后的图像。

带 `--layout` 成功时输出完整载荷及字段，校验状态为 `crcStatus=OK(完整性自检,未验签)`。每个码字 bit 至少需要 5 次有效物理观测；外侧完全均匀的空白框不增加观测，内部 JPEG 零差分仍保留。观测数不等于置信度。

主色度通道无有效载荷时，解码器会尝试已有 R/G 伴色残差，成功时报告 `companionRecovery=true`。这只改变解码，不提高渲染强度；小图和多载荷拒答仍保留。

| 结果 | 含义 | 退出码 |
|---|---|---:|
| 成功 | 唯一有效载荷，BCH、字段、CRC 与观测门槛均通过 | 0 |
| `TOO_SMALL` | 观测不足；带 `--layout` 时不输出字段 | 带 `--layout` 为 1，否则仅警告并返回 0 |
| `NO` / `ambiguous` | 无有效载荷 / 存在多个不同有效载荷 | 1 |
| 参数错误 | 非法选项、比例或相位 | 2 |

Python 镜像工具使用 numpy/Pillow：`python3 tools/bwdecode.py shot.jpg --layout`。诊断字段、载荷布局与搜索算法见 [v6 协议文档](docs/v6-protocol.md)。

## 验证与限制

```bash
swift test
python3 tools/test_bwdecode.py
```

回归覆盖裁切、缩放、重复 JPEG、边框、小图拒答，并进行 Swift/Python 同图对账。[样本](docs/samples/samples.json)与[验收记录](docs/v6-protocol.md#2026-09-28-本机验收)包含可复核数据和复测命令。

极小裁片、强模糊、载波被彻底量化抹除，以及拍屏、任意旋转或透视变形不在恢复保证内。记录中的成功率仅适用于对应样本和变换；实际 IM 转发、目标真机与深色/照片页面观感需单独验收。

微信压缩的实测结果与进一步改进方向见 [恢复分析](docs/wechat-recovery.md)。

Agent 使用：[截图解析 skill](skills/blind-watermark/SKILL.md) · [接入 skill](skills/blind-watermark-integration/SKILL.md)。
