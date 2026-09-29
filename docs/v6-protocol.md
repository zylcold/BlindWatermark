# v6 协议与验收记录

状态：3.0.0 开发样本，未发布。只支持 v6，历史截图与历史 API 需使用旧版本。v6 能离线恢复这里定义的全部紧凑字段，不依赖服务端 token；不保留 v4 的构建号/tag/自由文本布局。

## 线格式

所有整数字段按低位先行写入 bit 流，再按低位先行装入字节。字段 bit 边界：

| 字段 | 起始 bit | 位数 | 约束 |
|---|---:|---:|---|
| profile | 0 | 4 | 6 |
| uid | 4 | 32 | UInt32 |
| timestampOffset | 36 | 31 | UTC 2026-01-01 起的秒 |
| buildMinuteOffset | 67 | 24 | 同起点分钟 |
| page | 91 | 42 | 8位base37 |
| app | 133 | 14 | 0…9999 |
| note | 147 | 32 | 6位base37 |
| CRC24 | 179 | 24 | 下述bit流算法 |
| reserved | 203 | 8 | 0 |

27字节中的 bit211…215 是存储补位，必须全0。base37为 `abcdefghijklmnopqrstuvwxyz0123456789_`，首字符高位radix digit，右补 `_`，解码去掉尾 `_`；非法radix值拒绝。显式code输入先检查宽度，不能用多余尾 `_` 绕过容量限制。

CRC在前179bit上逐位计算：初值0xB704CE；每个输入bit与当前最高位异或，左移并截24位，若异或为1则异或0x864CFB。无隐式字节补位、无末尾异或。profile/reserved/补位/范围/CRC都必须通过。CRC可公开重算，**只能检查完整性，不能验签或证明身份**。

BCH在GF(512)上构造，primitive polynomial为x⁹+x⁴+1（0x211），生成多项式roots α¹…α⁸⁰及其二元cyclotomic闭包，degree300。码字位0…299是校验，300…510是211bit信息，511是使全码字偶校验的扩展位。BM+Chien可纠正BCH区最多40个错误；扩展位独立重算，40个区内错误加1个扩展位错误仍能恢复，但不能称t41。

黄金向量（测试用载荷，不是用户截图身份）：

```text
message:
f6eedbeabd745a16d0882e50bbbc36826c0140066fc77c18a80700
codeword:
f35516606e2084c0f65f6715ebd4a06fd1e5b9786cf706584579cacc15a1e9256ecc02d0f56fefbeadde4ba765018de802b5cb6b23c8160064f076cc87817a00
```

## 渲染与判读

tile为544×512px，cell32×8px，17列×64行。前16列共1024cell，分别放两份512bit码字；最后1列64cell是独立同步，不叠加到数据幅度。

位置p从前16列按行编号。第一份索引 `(p*73+19)&511`，第二份 `((p&511)*151+89)&511`。两份索引各自是双射。极性由32位环绕hash确定：乘0x9E3779B9加0x7F4A7C15、xor右移16、乘0x85EBCA6B、xor右移13，取最低bit；hash输入是完整p。pilot对行号使用同hash，按hash值排序前32行取负，其余取正。

载波为 `sin(2π(x+0.5)/32)`；符号编码bit及极性。yellow=(1-wave)/2，chroma源层red/green=round(round(0.114*delta/0.886)*yellow)，blue=round(delta*(1-yellow))，alpha始终=delta。像素是预乘RGBA，整体按source-over合成。默认delta4时，源层R/G范围0…1、B范围0…4，色度 `B-(R+G)/2` 峰峰值5/255，亮度 `0.299R+0.587G+0.114B` 峰峰值0.886/255；伴色不能同时消掉整数取整后的亮度与色度纹理。不能据此宣称不可见，尚未完成目标真机人工观感验收。

解码用fractional integral矩形计算左右半cell差分，clip±12限制内容硬边缘支配；按tile位置累计、同步列相关排名，再按交织/极性折叠。z的方差下限0.25为固定实验预算，不是统计置信度保证。信号统计保留全部不重叠物理cell，包括量化成0的cell；0仍贡献0信号，不能凭计数代替BCH/CRC。证据计数只包含完整落在内容矩形内的 cell：由 RGB 非均匀行列确定矩形，排除外侧完全均匀的 padding，不改变坐标或信号统计；内部 JPEG 零差分仍计数。该规则不保证识别纹理框或任意无水印区域。

每比例只保留最佳粗相位，避免单个比例占满排名。原始比例1.0优先；失败再用0.50…1.50、步长0.05共21档粗搜，前三个比例邻域±0.03按1/图像最大跨度精搜，比例限制在范围内；直接decode API也提前拒绝非有限或不在闭区间0.5…1.5的scale。相位粗步x4/y2，局部x±2/y±1；最终至多12上下文，每个至多2tile平移，pilot阈值0.35。先收集所有硬判决有效候选；没有硬候选时，按各候选实际pilotScore降序（同分保持输入顺序）选择前2个候选，对低可靠6位尝试翻1/2位。所搜索的全部有效载荷去重，多个不同载荷必须拒答。

唯一有效载荷还需每码字bit物理观测≥5。小图不足时 `TOO_SMALL`，带layout无字段且exit1；无layout只诊断警告。未恢复报NO，多载荷报ambiguous。CRC状态固定为 `crcStatus=OK(完整性自检,未验签)`，没有mac输出。

主色度特征失败后可读取既有伴色残差 `-(R+G)/2`。伴色的亮度边缘容易污染判位，故完整落在内容矩形之外的 cell 不参与信号和导频统计；该通道采用 x±2/±1/0、y±1/±0.5/0 的局部相位细搜，并按 cell 周期环绕。只在原通道没有有效载荷时启用；小图与多载荷结论不会触发回退。CLI 新增 `companionRecovery=true/false`，渲染协议及默认幅度不变，luma 渲染不使用该回退。2026-09-29 真实微信输入及更强压缩边界见 [恢复分析](wechat-recovery.md)。

## 2026-09-28 本机验收

条件：arm64 macOS26.6.2，Swift6.4，release CLI；iPhone17 Pro Max模拟器、iOS26.4，原始像素1320×2868，delta4/chroma。XcodeBuildMCP编译/启动，sim-use保存原始PNG。Python3环境Pillow11.3.0/numpy2.0.2。Photo/Mixed内容是Demo程序噪声纹理与硬边缘，**不是自然照片或真机样本**。运行时随机纹理以本次保留截图为准，重跑sweep可能生成不同内容。

| 链路 | 样本 | 实测结果 |
|---|---:|---|
| 六页原始PNG | 6 | 6/6字段一致，纠错0，minObs22 |
| 完整图两次JPEG：Q95/90/80/76/70/60，4:2:0 | 36 | 36/36字段一致，纠错0，minObs22 |
| 裁切后两次JPEG Q76 | 6 | 6/6字段一致 |
| 上述链路后加黑/白/灰边框 | 18 | 18/18字段一致 |
| 裁切、先加黑框、再两次JPEG Q76 | 6 | 6/6字段一致 |
| 裁切→0.837或1.173 Lanczos缩放→两次JPEG Q76→黑框，已知比例 | 12 | 12/12字段一致 |
| Mixed上述两种比例，未知比例自动搜索 | 2 | 2/2字段一致，两端一致 |
| 544×512裁片，两次JPEG Q76 | 6 | 6/6拒答，无字段输出 |

上述原图/压缩/组合成功均以全部载荷字节等于原图为准，组合链路同时调用Swift CLI与Python对账。组合正样本42张，加自动搜索2张；小裁片6张是拒答测试，不能混进“成功解码数”。裁切矩形x13/y117/w1206/h1542；黑/白/灰框左17上31右19下23，灰RGB(40,43,46)。边框加在压缩后，另设加在压缩前的一组。保存为PNG只是为了无额外损失地保存已经经过两次JPEG的像素，不能把它们描述为未经压缩PNG。

组合链路minObs10…12，最高纠错35位（Photo+灰框）。接近40位预算，不能承诺继续裁切或更强压缩仍通过。深色页面保留全部黑框，不为解码强裁内容；Photo部分边框因内侧探针不够亮而保留，仍能搜索恢复。Mixed边缘的小暗条也可能被保守规则当作暗边裁掉，裁剪阈值无法辨别所有内容与边框。

原始六页Swift CLI耗时0.117…0.377s。本次完整图JPEG矩阵Python已知比例搜索0.188…0.374s（含候选判读、不含加载）；本次修复复测组合已知比例0.220…0.542s，部分阶段与单元测试并行。Mixed未知比例Python自动搜索下采样16.284s、上采样40.075s；并非交互实时搜索。完整合成图未知1.173的另一次运行约110s，图像跨度和候选数会影响耗时。已知比例优先传--scale，性能结论只适用于这里的模式/样本。

另外，把用户给出的真实照片页**作为背景重新叠加测试v6**，原图及上述7种组合链路共8/8恢复，最高纠错13，note非空也完全一致。这证明该背景上的新v6实验，不是恢复旧水印；原截图不会被误解为v6。该输入和生成图片不进入仓库，仅保留无图像/身份内容的统计[记录](measurements/background.json)。实际企业微信重新转发、真机拍屏与人工可见性验收尚未完成，Pillow Q值不等同IM编码参数。

可复核原始结果：[sweep](measurements/sweep.json)、[JPEG矩阵](measurements/jpeg.json)、[组合链路](measurements/channels.json)。固定[样本元数据](samples/samples.json)与4张Demo图片纳入Python回归，Swift/Python恢复相同27字节载荷。参数/载荷上限、40位错误、非法字段、量化为0、无水印噪声、多候选、小图拒答都有自动检查。

## Review 修复回归

2026-09-28 同一 macOS/Python/Swift 环境复测：SDK 对 `1e-320` 等非法 scale 提前返回空结果，不再发生整数转换崩溃；scale 接受范围统一为闭区间0.5…1.5。

原544×512单tile图每bit只有2次观测，添加左右各544、上下各512的空白框后仍为2次，不能靠扩充画布绕过TOO_SMALL。回归覆盖黑/灰/白4种颜色、框后两次Q76压缩，以及非cell对齐框厚度；内部量化擦除仍保留。外框识别只针对RGB完全均匀的外侧行列，不保证纹理框或任意无水印区域。

本次修复复测原组合正样本42/42、未知比例2/2、小裁片拒答6/6，两端同图一致。新增空白框拒答10/10；Swift14项、Python9项测试通过。

新增[Chase排名样本](samples/v6-photo-chase-ranking.png)：从保留的Photo截图裁x20/y93/w1024/h1500，再两次JPEG Q76/4:2:0。修复前默认相位搜索报NO，指定phase12,3可恢复；修复后默认搜索在相同两个重试预算内恢复，`correctedBits=42`、`softRecovery=true`、minObs7，完整27字节与源图一致。42是相对原始硬判决的差异数，恢复包含Chase翻转，不代表BCH单次纠错能力超过t40。

## 最终样本

```bash
.build/release/bwdecode docs/samples/v6-mixed-original.png --layout --scale 1
.build/release/bwdecode docs/samples/v6-mixed-crop-scale0837-q76-black.png --layout --scale 0.837
.build/release/bwdecode docs/samples/v6-photo-crop-q76-white.png --layout --scale 1
python3 tools/test_bwdecode.py
```

[原始混排图](samples/v6-mixed-original.png)与[裁切/0.837缩放/两次Q76/黑框样本](samples/v6-mixed-crop-scale0837-q76-black.png)，以及[照片纹理裁切/两次Q76/白框样本](samples/v6-photo-crop-q76-white.png)保留了真实系统渲染链路。自动缩放搜索在回归脚本 `benchmark_channels.py --automatic` 中执行；固定样本CI使用已知比例以限制运行时间。

`benchmark_channels.py --background <本地真实内容图片>` 可重新嵌入固定测试载荷再测传播链路，输出只能放私有临时目录；切勿把用户图片、生产uid或密钥提交到公开样本。

另有 [合成色度衰减样本](samples/v6-companion-attenuated.png)：对白色背景的测试载荷将蓝黄差值保留40%，裁切后缩至904×1220，再两次JPEG Q92。它用于独立验证伴色回退，不代表实际微信编码器。

## 范围

不保证小范围裁片、极端压缩、强模糊、任意旋转/透视、拍屏恢复；不保证所有背景与边框。强纠错不能恢复被通道完全抹掉的信息。v6的CRC和纠错是可靠读取机制，不是防伪/验签机制；低幅度色度载波的可见性也必须单独验收。
