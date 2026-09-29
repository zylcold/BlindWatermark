# 条码水印（「抗微信压缩」档）

状态：3.1.0 开发中。与 v6 色度盲水印**并存互补**：v6 抗裁切、死于强压缩；条码抗压缩、裁切即失效。两层默认同时开启。

## 布局

顶部/底部各一条，高 1pt（3x 屏 3px 行，图案逐行重复），块宽按屏幕宽自适应（≥78 块，块宽 pt 不小于 4）。亮度条：bit1→205、bit0→245（Δ40，RGB 同值，4:2:0 只砍色度不砍亮度）。

76 bit：

| 字段 | bit | 说明 |
|---|---|---|
| marker | 0:4 | 固定 `1011` |
| uid | 4:36 | UInt32，MSB first |
| minuteOffset | 36:60 | 自 UTC 2026-01-01 起整分钟，24 bit |
| CRC16 | 60:76 | CRC-16/CCITT-FALSE（poly 0x1021, init 0xFFFF），对前 56 bit |

黄金向量：`"123456789"` → `0x29B1`。

## 解码策略（Swift `StripWatermark` 与 `tools/bwdecode.py` 镜像，两端必须一致）

1. 用未裁边原图；条在画面最顶/最底，黑边裁剪可能把条裁掉。
2. 块宽 6.00…32.00px 步 0.02 × 相位 0/0.25/0.5/0.75 网格扫描；块均值取前 76 块（载荷区）求 lo/hi 阈值——**尾部残块落在页面内容上，混入会拉偏阈值**。
3. marker 匹配后，弱块纠错只允许翻 **CRC 段（60..<76）内**离阈值最近的 ≤12 块中 1…3 位；载荷区（uid/分钟）不参与翻转——纠错改写载荷必然产出假身份。
4. 候选复核：把载荷映射回块亮度与实测比平均绝对差，>13 拒答（真值含噪声 ≈8-10）。
5. **双条仲裁**：top/bottom 载荷一致才采信；仅单边时只接受 fixedBits=0 且复核误差 ≤4 的精确解。溯源场景假 uid 不可接受，宁缺毋假。

## 已知边界

- 顶/底被裁掉即失效（用户裁切、IM 卡片圆角遮挡）。
- 深色背景页面上 245 亮块会明显可见——可见性本身是设计目标（「明显可见的浅水印」），真机观感需验收。
- 条码只有 uid+分钟：不含 buildTime/page/app/note，完整溯源仍靠 v6 层。

## 2026-09-29 本机验收

条件：macOS 26.6.2 / Swift 6.4 debug+release；Python 3.9 / numpy 2.0.2 / Pillow 11.3。底图 `docs/samples/v6-mixed-original.png`（1320×2868）+ `strip_render`（块宽 = 宽/88）：

| 链路 | Swift CLI | Python | 结果 |
|---|---|---|---|
| 原始 PNG | ✓ | ✓ | fixedBits=0 |
| JPEG q76 | ✓ | ✓ | fixedBits=0 |
| JPEG q60 | ✓ | ✓ | fixedBits=0 |
| 0.969 Lanczos + q76 | ✓ | ✓ | fixedBits=0 |
| 0.685 Lanczos + q60 | ✓ | ✓ | fixedBits=0 |
| 无条负样本 | strip=NO | strip=NO | 拒答 |

Swift `swift test` 23/23（含 CG JPEG 端到端 q90/76/60）；`python3 tools/test_bwdecode.py` 10/10。

真实企业微信转发图（0.969 缩放 + q75）此前用缺陷 PoC 样张验证过可解，但该样张右侧 8px 未覆盖 + 仅单条，属于**不该解**的输入——新仲裁策略下正确拒答；真机双条完整的链路待 Demo `sweep.sh` 复测。

## CLI

```bash
.build/release/bwdecode shot.jpg --strip          # v6 + 条码
.build/release/bwdecode shot.jpg --strip-only     # 只解条码，跳过 v6 几何搜索（秒级）
.build/release/bwdecode shot.jpg --json           # 机读 JSON（v6 + strip）
python3 tools/bwdecode.py shot.jpg --strip-only

# 写入端期望值（JSON 回原始数据，供编码端对账；--build 原样回显不转时区）
.build/release/bwdecode expect --uid 124914474 --timestamp 1790589485 \
  --build 202609291449 --page BHUserProfileViewController --app 11
```

退出码契约不变：v6 TOO_SMALL 带 `--layout` exit 1；v6 NO 且 strip 无解 exit 1；条码单独拒答不改变 v6 退出码。
