# 条码水印（「抗微信压缩」档）

状态：3.2.0。与 v6 色度盲水印**并存互补**：v6 抗裁切、死于强压缩；条码抗压缩、裁切即失效。两层默认同时开启（`Watermark.install(…, strip: .off)` 可关条码）。

## 布局

顶部/底部各一条，高 1pt（3x 屏 3px 行，图案逐行重复），**顶底内容相同**（保留双条仲裁与单边裁切后的完整身份）。亮度条：bit1→205、bit0→245（Δ40，RGB 同值，4:2:0 只砍色度不砍亮度）。

三档载荷，按屏幕像素宽自动选**最高可用档**（解码端用 CRC 试解区分档位，不写档位位）：

| 档 | bit | 字段 |
|---|---:|---|
| `identity` | 76 | marker4 + uid32 + 分钟偏移24 + CRC16 |
| `buildDay` | 91 | 上述 + buildDay15（2026-01-01 起的**天**） |
| `full` | 123 | 上述 + page32（6 字符 base37，37^6 < 2^32） |

块宽 = `floor(widthPx / payloadBits)`，要求 ≥ 9px（实测 9px 在 q76/q60/0.969+q76/0.685+q60 全链路可解，8px 在 q60+0.685 失败）。选档结果（实测）：

| 设备像素宽 | 典型来源 | 选中档 | 块宽 |
|---:|---|---|---:|
| 1320 | iPhone 17 Pro Max（3x/440pt） | full | 10.73px |
| 1125 | iPhone SE3（3x/375pt） | full | 9.14px |
| 828 | 414pt @2x | buildDay | 9.09px |
| 750 | 375pt @2x | identity | 9.86px |
| < 684 | 极窄 | 不画条码 | — |

黄金向量：CRC-16/CCITT-FALSE，`"123456789"` → `0x29B1`。tier0 与 3.1.0 的 76 bit 布局逐位一致（老截图可解）。

## 解码策略（Swift `StripWatermark` 与 `tools/bwdecode.py` 镜像，两端必须一致）

1. 用未裁边原图；条在画面最顶/最底，黑边裁剪可能把条裁掉。
2. 块宽 6.00…32.00px 步 0.02 × 相位 0/0.25/0.5/0.75 网格扫描；块均值只取该档的载荷位（0..<payloadBits）求阈值——尾部残块落在页面内容上会拉偏阈值。
3. **阈值用 Otsu**（最大化类间方差），不是 min/max 中点、也不是 k-means：实测 iPhone 17 Pro Max 顶部条最前 4 像素被系统内容盖住（0/154，块均值 ≈144），形成第三个簇，(min+max)/2 与 k-means 都会把阈值拉到 ~180，导致 205 的暗块被整批判亮；Otsu 在 `{144}` 与 `{205,245}` 之间分割，不受影响。
4. marker 匹配后，弱块纠错只允许翻该档 **CRC 段内**离阈值最近的 ≤12 块中 1…3 位；载荷区不参与翻转。
5. 候选复核：载荷映射回块亮度与实测比平均绝对差，>13 拒答。
6. 档位歧义：两个档位同时有效且复核误差差 ≤2 且载荷不同 → 拒答。
7. **双条仲裁**：top/bottom 载荷一致才采信；仅单边时只接受 fixedBits=0 且复核误差 ≤4 的精确解。溯源场景假 uid 不可接受，宁缺毋假。

## 已知边界

- 顶/底被裁掉即失效（用户裁切、IM 卡片圆角遮挡）；只剩单边时按上面第 7 条严格处理。
- page 只存 6 字符 base37，`"userprof"` 解出 `"userpr"`——比 v6 的 8 字符更易碰撞，完整页面短码仍看 v6 层。
- 条码不含 app/note，也不含 build 时刻（只到天）。
- 深色页面上 245 亮块明显可见——可见性是设计目标；真机观感需验收。

## 2026-09-29 本机验收

条件：macOS 26.6.2 / Swift 6.4；Python 3.9 / numpy 2.0.2 / Pillow 11.3；iPhone 17 Pro Max 模拟器（iOS 26.4，1320×2868，3x）。

合成链路（底图 `docs/samples/v6-mixed-original.png`）：

| 链路 | Swift CLI | Python | 结果 |
|---|---|---|---|
| 原始 PNG / JPEG q76 / q60 / 0.969+q76 / 0.685+q60 | ✓ | ✓ | 全部 fixedBits=0（tier identity/full 均测） |
| 无条负样本 | strip=NO | strip=NO | 拒答 |
| 缺陷样本（单条 + 右缘 8px 未覆盖） | strip=NO | strip=NO | 拒答 |

Demo 端到端（`Demo/`，SwiftPM 本地路径接入，3x 屏 → tier full）：

```
BW_PAGE=white strip=OK tier=full edge=top uid=3735928559 buildDay=271 page=whitec fixedBits=0
BW_PAGE=dark  strip=OK tier=full edge=top uid=3735928559 buildDay=271 page=darkmo fixedBits=0
BW_PAGE=plain strip=OK tier=full edge=top uid=3735928559 buildDay=271 page=plain  fixedBits=0
```

三页顶底条均可解；顶部前 4 像素被系统内容污染仍 fixedBits=0（Otsu 阈值的直接验证）。Swift `swift test` 27/27；`python3 tools/test_bwdecode.py` 10/10。

**渲染实现坑**：条码层不能用 `CALayer.contents`——本工程实测 `backgroundColor` 可见但 `contents` 不合成（同尺寸同内容）。现用 `UIView` + `UIColor(patternImage:)`，与 v6 图案同一条路径。

## CLI

```bash
.build/release/bwdecode shot.jpg --strip          # v6 + 条码
.build/release/bwdecode shot.jpg --strip-only     # 只解条码，跳过 v6 几何搜索（秒级）
.build/release/bwdecode shot.jpg --json           # 机读 JSON（v6 + strip）

# 写入端期望值（JSON 回原始数据；--build 原样回显不转时区，--build-day 为条码天数）
.build/release/bwdecode expect --uid 124914474 --timestamp 1790589485 \
  --build 202609291449 --build-day 271 --page BHUserProfileViewController --app 11
```

退出码契约不变：v6 TOO_SMALL 带 `--layout` exit 1；v6 NO 且条码无解 exit 1；条码单独拒答不改变 v6 退出码。
