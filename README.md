# BlindWatermark

版本：**3.0.0（v6，待发布）** · [English](README.en.md)

在 iOS 界面上叠加低幅度色度水印，从截图中离线恢复 uid、时间、构建时间、页面短码、app 和 note。运行时只使用系统框架，支持 iOS 13 / macOS 11；Demo 最低 iOS 15。

**3.0.0 是破坏性迁移：只支持 v6。** 已删除 v4/v5.2 编解码、原始 bit API、HMAC、页面注册表和混合探测。历史截图必须使用历史版本工具，不能用 v6 恢复已被压缩抹掉的旧水印。原 v4 的构建号、tag、15 字符 page 和 22 字节自由文本 note 不再保留；v6 的完整字段是下表定义的紧凑字段，不需要服务端 token 回查。

v6 使用 BCH(511,211,t40) 加整体偶校验、两份不同交织的码字副本、32×8 px 平滑载波和独立色度同步列。默认 `delta=4`、`plane=chroma`。CRC24 只是完整性自检，**不是验签或身份认证**。低幅度不等于不可见；目标真机、深色页面和照片页面仍需人工验收。

## 安装与载荷

SPM 添加本仓库的版本标签；CocoaPods 使用三个同版本 pod（发布后为 `3.0.0`）。当前开发分支可用本地 `:path` 接入。

```ruby
pod 'BlindWatermark', :path => '/path/to/BlindWatermark'
```

```swift
import BlindWatermark

// 在主线程配置。uid 使用业务侧稳定的 UInt32 编码。
guard let payload = WatermarkPayload(
    uid: 123456,
    timestamp: UInt64(Date().timeIntervalSince1970),
    buildTime: 1_790_064_000, // 由构建流水线写入真实 UTC Unix 秒
    pageClassName: "BHUserProfileViewController",
    app: 11,
    note: "ticket"
) else { fatalError("载荷超出 v6 范围") }
Watermark.install(payload: payload) // delta=4, plane=.chroma

// 换页或刷新时间时，构造新载荷再更新。
Watermark.update(payload: payload)
```

| 字段 | 位数 | 范围 / 语义 |
|---|---:|---|
| profile | 4 | 固定 6 |
| uid | 32 | UInt32 |
| timestamp | 31 | UTC 2026-01-01 起的秒偏移 |
| buildTime | 24 | 同一起点的分钟偏移，输入 Unix 秒向下取整 |
| page | 42 | 8 字符 base37 短码 |
| app | 14 | 0…9999 |
| note | 32 | 最多 6 字符 base37 短码 |
| CRC24 | 24 | 前 179 bit 的完整性自检 |
| reserved | 8 | 必须为 0 |

合计 211 bit，存储为 27 字节，末字节高 5 位必须为 0。base37 字母表为 `a-z0-9_`，首字符是高位 radix digit；右侧 `_` 补齐、解码去掉尾部 `_`，因此不能区分字面尾下划线。`pageClassName` 去模块名、常见类前后缀，转小写并截取 8 字符；可能碰撞，不能反推唯一类名。`note` 不支持中文、自由文本或超过 6 字符。使用 `pageCode:` / `noteCode:` 构造器时超长或非法字符直接拒绝。

ObjC `+load` 保留零接入挂载：未显式配置时 uid 是 IDFV 的 FNV-1a 哈希，时间为刷新时间，构建时间为协议起点，page/note 空、app=0。它仅用于跑通链路，不代表业务身份。可在主线程设置 `Watermark.payloadProvider: (() -> WatermarkPayload)?`，未显式 install 时每次刷新调用；显式 install 后由 `update` 更新。每个 scene 一个非交互窗口，不成为 key window。

## 截图解码

```bash
swift build -c release
.build/release/bwdecode shot.jpg --layout
.build/release/bwdecode shot.jpg --layout --scale 0.837
python3 tools/bwdecode.py shot.jpg --layout
```

Python 工具沿用 numpy/Pillow，运行时 Swift 库不依赖它们。CLI 只接受 `--protocol v6`；`--auto` 等同默认几何搜索。`--plane` 必须与接入端一致，默认 chroma；luma 是可见性实验档，不能套用 chroma 的观感结论。

默认先搜 1.0，再搜 0.50…1.50 的 21 档粗网格及局部连续精搜。已知比例用 `--scale` 限制搜索。解码 API 与 CLI 的有效 scale 范围均为闭区间 0.5…1.5；非有限或越界参数提前拒绝。有限 Chase 的两个重试候选按各自实际 pilotScore 降序选取，同分保留原顺序。`--offset X,Y` 指定非负像素相位且关闭自动黑边裁剪，仍搜索 tile 平移；没有指定时相位相对于裁剪后的图像。默认只保守裁均匀暗边，白边/不规则边框由几何搜索处理，不能保证所有边框都能恢复。

第一行含 `protocol=v6`、27 字节 `payload`、plane、phase、tileShift、scale、correctedBits、softRecovery、pilotScore、minObs、avgObs、`|z|中位`，必要时加 `trim=(左,上,右,下)`。成功且带 `--layout` 时第二行输出完整字段，结尾固定为：

```text
crcStatus=OK(完整性自检,未验签)
```

没有 `mac=`。没有 BCH + CRC-valid 候选输出 `NO`，多个不同有效载荷输出 `ambiguous`，均 exit 1。参数错误 exit 2，不回退历史协议。

**每个码字 bit 至少 5 次不重叠物理 cell 观测才解读字段。** JPEG 将差分量化成 0 的 cell 仍计数，但其信号贡献为 0；观测数不是置信度。证据计数只包含完整落在内容矩形内的 cell：由 RGB 非均匀行列确定矩形，排除外侧完全均匀的 padding，不改变坐标或信号统计；内部 JPEG 零差分仍计数。该规则不保证识别纹理框或任意无水印区域。恢复同时必须通过 BCH、合法字段、CRC，不能仅凭面积放行。小图可能通过 CRC 但仍输出 `TOO_SMALL`，带 `--layout` 时 exit 1、无字段；不带时只报告诊断、警告并 exit 0。

## 验证与样本

```bash
swift test
python3 tools/test_bwdecode.py
Demo/sweep.sh <已启动的模拟器UDID> 4 chroma
python3 tools/benchmark_v6.py --input-dir /private/tmp/bw-v6-demo-samples
python3 tools/benchmark_channels.py --input-dir /private/tmp/bw-v6-demo-samples --automatic
```

sweep 使用 XcodeBuildMCP 编译/启动和 sim-use 原始像素截图，需预先安装这些工具并授权设备。六种页面包括纯色、白色聊天、文字列表、照片、深色、混排。组合测试覆盖裁切、非粗网格缩放、两次 JPEG、黑/白边框、小图拒答，并对 Swift/Python 同图对账。

协议细节、实际测试条件和失败边界见 [v6 协议与验收记录](docs/v6-protocol.md)。[解析 skill](skills/blind-watermark/SKILL.md) 只负责读截图；[接入 skill](skills/blind-watermark-integration/SKILL.md) 负责配置与验收。测试样本只包含 Demo，不包含用户截图。

截图之外的拍屏、透视变形、任意旋转、极小裁片、强模糊或彻底量化掉载波不在恢复保证内。测试成功率只适用于记录的样本和变换，不能代表所有 IM 转发链路。
