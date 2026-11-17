# 拾境：手机端 3DGS 渲染优化方案

> 2026-11-05。目标：在 iPhone 上流畅、稳定地查看 A10 生成的 FF 快速预览与 SfM 精细模型，并为后续大场景预留 World Labs Spark 2.0 式的 LoD 流式加载。本文是方案，**尚无真机性能数据**；文中所有预算数字都是待实测校准的初值，不是结论。上游交付计划见 [FF／SfM 手机交付](FF-SFM-MOBILE-DELIVERY.md) 第 4、6、7 节（批次 D、E）。

## 0. 实施状态

**2026-11-05：R0 + R1 已实现**（代码：`Viewer/RenderBudget.swift`、`Viewer/PocketSplatRenderer.swift`、`Viewer/GaussianSceneView.swift`），单元测试覆盖档位、热降级、重要性精简、SH 截断和分辨率调节；**真机效果尚未测量**，附录 B 待填。

- 设备分档（按物理内存）与热状态降级；预算决定点数上限、SH 阶数、分辨率范围、帧率。
- 加载改为每 64K 点一个 GPU chunk 边读边显示；超预算模型按“不透明度 × 投影面积”精简；SH 按档位截断；界面提示“正在补充细节 x%”与“已按本机性能精简”。
- 静止 1.5 秒后暂停重绘，相机变化／游览／加载时自动恢复；按 GPU 帧时动态调整分辨率；热状态变化即时调整分辨率和帧率；进入后台 5 秒后释放 GPU 模型，回到前台重新加载。
- 封面截图后恢复 `framebufferOnly = true`。
- Debug 构建在查看器右侧工具栏有「性能」按钮：显示档位、点数、SH、首帧/完整加载时间、fps、GPU 时间、分辨率、可用内存、热状态，可一键复制，用于填写附录 B。

## 1. 现状（已核实）

| 项目 | 现状 | 依据 |
|---|---|---|
| 渲染器 | 原生 SwiftUI + MTKView + MetalSplatter（固定 revision `71ff248e`），支持 SH0–SH3、多 chunk（add／enable／remove） | `Viewer/PocketSplatRenderer.swift`、MetalSplatter `SplatRenderer.swift` |
| 支持格式 | App 只放行 `.ply`、`.splat`；依赖里已有 `SPZSceneReader`（spz-swift 2.1.0），但未接入白名单与校验 | `readScene`、SplatIO `SPZSceneReader.swift` |
| 上限 | 单模型 ≤ 1,000,000 点、≤ 150 MiB（App 与服务端一致） | `readScene`、`ReconstructionStudy.validate`、服务端 `MAX_MODEL` |
| 加载方式 | 整个文件读入 CPU 数组 → 一次编码成单个 GPU chunk → 才出首帧。CPU 峰值约两份数据，加载期间无画面 | `readScene` → `SplatChunk(device:from:)` |
| GPU 占用 | 每点基础 32 B（位置 float3 + 颜色/不透明度 half4 + 协方差 2×half3）；SH3 另加 15×3 个 Float16 = 90 B，合计约 122 B/点；1M 点 SH3 ≈ 120 MB，另有排序索引 | `EncodedSplatPoint.swift`、`SplatChunk.swift` |
| 排序 | CPU 后台任务，`Array.sort` 比较排序（O(n log n)），相机变化即重排；百万点级别预计跟不上快速旋转（未实测） | `SplatSorter.performSort` |
| 帧率/分辨率 | 固定 30 fps，`contentScaleFactor = min(屏幕倍率, 2)`；即使画面静止也持续重绘 | `GaussianMetalCanvas.makeUIView` |
| 封面截图 | 为截取渲染封面设置了 `framebufferOnly = false`，会略增带宽 | 同上 |
| 当前产出 | FF：490,221 点、SH0；SfM：143,064 点、SH3、35.48 MB PLY；Hub FF 默认 `compress_gs_max_points = 500000`（可调 1 万–200 万） | `VIDEO-FF-SFM-COMPARISON-2026-11-03.md`、Hub `/capabilities` |

结论：今天的单个物体（十几万到五十万点）在旗舰机上大概率能看；瓶颈会依次出现在 **加载峰值内存 → CPU 排序延迟 → 发热降频 → 大场景超出单文件上限**。

## 2. 参考：World Labs Spark 2.0 做了什么

来源：[World Labs 官方博客《Streaming 3DGS worlds on the web》](https://www.worldlabs.ai/blog/spark-2.0)（2026-04-14）。以下只摘官方页面原文给出的事实：

- **连续 LoD 树**：每个内部节点是其子节点的低分辨率合并，直到根部一个大 splat。离线工具 `build-lod` 把 3DGS 转成可流式的 `.RAD`；浏览器也可在后台 Worker 现场建树。两者共用同一份 Rust 代码（编译为 Wasm 与原生）。CLI 默认用 Bhattacharyya 距离两两合并，树比原始点多约 30–40%；全程无需重新训练。
- **每帧选“切面”**：按屏幕尺寸从粗到细的优先队列遍历；小于 1 像素或到叶子即输出；超出 **预算 N（按设备类型 50 万–250 万 splat）** 就停止细化。支持注视点（foveation）参数，屏幕中心优先。
- **.RAD 分块**：每块 64K splat，按属性列存并分别 gzip；空间分块；**第 0 块是最大的那批 splat（根附近），先到先显示粗略 64K 近似**；其余块可任意顺序到达，缺失的子节点用父节点代替；按遍历顺序排优先级，相机移动时重新排序，3 个并行 Worker 下载解码。
- **GPU 虚拟分页**：固定 1600 万 splat 的页池，每页 64K，页表映射；满了按 LRU 且仅当新块优先级更高时淘汰；多个 `.RAD` 共享一个页表。
- **排序与绘制**：GPU 计算距离后回读，后台 Worker 两遍 **基数排序**；一次实例化绘制，每个 splat 一个四边形。
- **设备限制**：移动浏览器对 GPU 内存有上限；“大多数消费级设备在交互帧率下只能渲染 100 万–500 万 splat”；1000 万点 SH0–3 的 PLY 可达 2.3 GB，同内容 SPZ 约 200–250 MB。

对我们的启发：**固定点数预算 + 粗到细 + 按视图选择 + 分页常驻 + 快速排序**。原生 Metal 比浏览器有更多显存和更快的计算，可以把同样的思路做得更省。

## 3. 设计原则

1. **预算驱动**：每台设备有明确的“同时渲染点数”和“GPU 内存”预算，所有加载与降级都服从预算，而不是看文件大小。
2. **先有画面，再变清晰**：首帧尽快出现粗略版本，细节逐步补齐；任何时候都不出现大片空白。
3. **画质降级必须可见**：低档位在界面标注（如“精简画质”），不悄悄把 SH3 降成 SH0，也不宣称与服务器原始画质一致。
4. **服务器做重活**：剪枝、压缩、建 LoD 树都在 A10 训练完成后离线完成；手机只做选择、解码和绘制。
5. **每一步可回退**：保留现有“整文件 PLY”路径作为兜底，新格式和流式加载都可以按开关关闭。

## 4. 分阶段方案

### 阶段 R0：先测量（约 1–2 天，只改 App）

没有基线就无法判断优化是否有效。

- 在查看器加隐藏的调试面板（Debug 构建）：首帧时间（已有 `firstFrameSeconds`）、实时 fps、每帧 GPU 时间（`MTLCommandBuffer.gpuStartTime/gpuEndTime`）、排序耗时与排序延迟（相机停止后多久排序完成）、进程可用内存（`os_proc_available_memory()`）、`ProcessInfo.thermalState`。
- 固定测试集：现有 FF（49 万点 SH0）、SfM（14 万点 SH3）；再用 Hub 的 `compress_gs_max_points` 生成 100 万、200 万点的 FF 版本做压力测试。
- 固定测试动作：打开 → 静止 10 秒 → 匀速旋转 30 秒 → 轨迹游览 → 连续查看 5 分钟（看发热）。
- **验收**：每个模型一张记录表（首帧、平均/最低 fps、内存峰值、5 分钟后热状态），写入本文附录。

### 阶段 R1：App 端快速优化（约 1 周，不改服务端）

| 项 | 做法 | 预期收益 |
|---|---|---|
| 设备分档预算 | 启动时读取物理内存、`MTLDevice.recommendedMaxWorkingSetSize`、GPU 家族，得到档位：旗舰（8 GB+）初值 150 万点、主流（6 GB）80 万、入门（4 GB）40 万（初值，按 R0 实测修正） | 避免低端机加载过大模型崩溃 |
| 超预算时按重要性精简 | 不再直接拒绝超限模型；按 `不透明度 × 三轴尺度乘积`（屏幕贡献的近似）排序，保留前 N 个，而不是均匀抽稀 | 同样点数下画质明显好于均匀减点 |
| SH 按档位 | 旗舰保留 SH3；主流用 SH1/SH2；入门 SH0（MetalSplatter 支持 SH0–SH3，在读入后、编码前截断系数即可，不必改 PLY 字段） | SH3→SH1 每点从约 122 B 降到约 50 B |
| 分块编码、边读边显示 | 读取批次每满 64K 点就编码为一个 `SplatChunk` 立即 `addChunk`，不再整份读完才建 GPU 数据；读完一块即释放对应 CPU 内存 | 峰值内存约减半；大模型更早出画面 |
| 静止时停止重绘 | 相机不动且排序已收敛时暂停 MTKView（`isPaused` / 按需绘制），手势或游览开始时恢复 | 显著省电降温 |
| 动态分辨率与帧率 | 根据近 1 秒 GPU 帧时自动在 1.0×–2.0× 之间调 `contentScaleFactor`；ProMotion 机型轻负载时可到 60 fps；`thermalState ≥ .serious` 时降到 30 fps、1.0× | 稳定帧率、防止过热降频 |
| 截图后恢复 framebufferOnly | 封面只截一次，之后恢复 `framebufferOnly = true`（需要重建 drawable，放在下次加载时生效） | 少量带宽 |
| 内存警告处理 | 收到内存警告或进入后台时释放 GPU 模型，回到前台从磁盘缓存重建 | 防止被系统杀进程 |

**验收**：R0 测试集在三个档位的模拟预算下均能打开；旗舰机 14 万点 SH3 与 49 万点 SH0 连续 5 分钟 ≥ 30 fps 且不到 `.serious` 热状态；内存峰值比 R0 低 ≥ 30%。

### 阶段 R2：排序提速（约 1 周，需要对 MetalSplatter 打补丁）

当前 CPU 比较排序是百万点级别的主要瓶颈（R0 会给出实测）。

1. **先换 CPU 基数排序**：深度量化为 16 或 32 位整数键，两遍 / 四遍 radix（与 Spark 的“两遍基数排序”思路一致），O(n)；并行计算深度。
2. **必要时上 GPU**：Metal compute 计算深度 + GPU radix sort，排序结果直接写索引缓冲，免去 CPU 往返。
3. 方式：fork MetalSplatter（MIT 许可）到项目可控的仓库，仍固定 revision；补丁保持最小，便于跟进上游。

**验收**：100 万点时相机停止后排序完成时间 < 50 ms（初值），快速旋转无明显“层级跳变”。

### 阶段 R3：服务端产出手机友好版本（约 1–2 周，A10 worker + App）

训练（Hub `gs_mcmc` / FF）完成后，由我们自己的 dual worker 在 A10 上离线生成：

1. **手机版变体**：在原始结果之外，额外生成按重要性剪枝到档位预算的版本（如 `mobile-hi` 150 万 / `mobile-mid` 80 万 / `mobile-lo` 40 万点），SH 阶数分别为 3 / 1 / 0。
2. **SPZ 压缩**：变体以 SPZ 存储（官方数据：同内容约为 PLY 的 1/10）。App 端把 `.spz` 加入白名单，复用依赖里已有的 `SPZSceneReader`，并加上与 PLY 相同的点数／尺寸／哈希校验。
3. **粗到细的点序**：文件内按重要性降序排列点；配合 R1 的分块编码，前几块就是“粗略但完整”的模型，后续块补细节。
4. **版本化清单**：结果描述里增加 `variants` 列表（角色、档位、格式、点数、SH 阶数、字节数、SHA-256）。App 按设备档位选择，默认不下载原始大文件；“导出模型”仍可取原始 PLY。

**验收**：同一场景的 SPZ 变体下载体积 ≤ 原 PLY 的 20%；与原始模型在若干留出视角下的画质差（PSNR／SSIM）记录在案，并在界面标注档位；三个档位真机均通过 R1 的帧率与发热标准。

### 阶段 R4：大场景 LoD 流式加载（Spark 2.0 思路，约 3–5 周）

适用于房间、街道等超出单设备预算的场景；单个物体通常停在 R3 即可。

**服务端（A10）**
- 训练完成后离线构建 LoD 树。优先评估直接使用 Spark 的开源 `build-lod`（Rust，MIT；需先核实许可、`.RAD` 格式说明和在 A10 上的运行方式）；备选是自研合并，或采用项目文档中已提到的 PlayCanvas Streamed SOG 规范。
- 输出：一个索引（树结构、各块包围盒、点数、字节偏移、SHA-256）+ 若干 64K 点的空间块；**第 0 块为全局粗略版**。
- API：`GET .../lod/index` 与 `GET .../lod/chunks/{n}`（或对单文件使用 HTTP Range）；块不可变、可长期缓存、逐块校验哈希。

**App（原生 Metal）**
- **每帧选切面**：从根开始按“投影到屏幕的尺寸”做优先队列细化，受设备档位的点数预算约束（Spark 官方区间 50 万–250 万，可作为初值）；屏幕中心优先（注视点）；视锥外和过远的节点不细化。
- **缺失回退**：子块未到时显示父节点，保证没有空洞；同一区域的父子两级不同时启用，避免透明度叠加变亮。
- **下载调度**：按遍历优先级排队，3 个并发下载／解码，相机移动后重新排序，过时请求取消或降级；磁盘缓存与 GPU 预算分开管理。
- **GPU 分页**：固定大小的页池（每页 64K 点，映射到 MetalSplatter 的 chunk：`addChunk` / `setChunkEnabled` / `removeChunk`），满了按 LRU 淘汰低优先级页；页池大小由档位决定（远小于 Spark 浏览器端的 1600 万，按 R0 内存实测确定）。
- **跨块排序**：所有已启用页统一排序（依赖 R2 的快速排序）。
- **集成选项**：(a) 用 Swift 实现遍历与调度，只读 `.RAD` 数据；(b) 把 Spark 的 Rust 核心交叉编译为 iOS 静态库，通过 C 接口调用。先做 (a) 的最小版本验证效果，再决定是否值得引入 Rust 工具链。

**验收**：一个超出旗舰机单文件预算的真实场景，在限定内存内连续漫游 5 分钟不崩溃、不出现空洞；首帧（粗略版）< 2 秒（初值）；未加载区域和降级状态在界面可见。

## 5. 设备档位初值（待 R0 校准）

| 档位 | 判定（初值） | 同时渲染点数 | SH | 分辨率 | 帧率 |
|---|---|---|---|---|---|
| 旗舰 | 物理内存 ≥ 8 GB，A17 Pro / A18 系列 | 150 万 | SH3 | 2.0× 起，动态 | 30–60 |
| 主流 | 6 GB | 80 万 | SH1–SH2 | 1.5× 起，动态 | 30 |
| 入门 | ≤ 4 GB | 40 万 | SH0 | 1.0×–1.5× | 30 |

热状态 `.serious` 及以上：预算降一档、分辨率 1.0×、30 fps，并在界面提示“设备较热，已降低画质”。

## 6. 风险与注意事项

- **画质对齐**：剪枝、SH 截断、LoD 合并都会改变画面；必须用留出视角做量化对比并记录，不能只看文件变小。
- **坐标与 SH 方向**：任何对模型的旋转／归一化如果烘焙进资产，必须同时旋转 SH 系数（见交付计划第 5 节）。
- **双重透明**：LoD 父子同时显示会让区域变亮，选择切面时必须互斥。
- **依赖补丁**：fork MetalSplatter 后要固定版本并保留许可声明（`docs/THIRD-PARTY-NOTICES.md`）。
- **服务端成本**：建 LoD 树与多档变体会增加 A10 的 CPU 时间和磁盘占用（训练产物已不自动清理，需同步规划保留策略）。
- **安全与完整性**：新格式、新接口沿用现有原则：版本化解析、尺寸上限、逐文件／逐块 SHA-256，按后缀放行不等于可信。

## 7. 建议的执行顺序

1. **R0 + R1**（只改 App，一到两周内可在真机看到效果）——现有单物体扫描最直接受益。
2. **R2**（排序）——R0 数据显示排序是瓶颈时立即做。
3. **R3**（服务端变体 + SPZ）——上线到更多机型前完成。
4. **R4**（LoD 流式）——开始支持房间／室外大场景时再投入。

## 附录 A：参考资料

- World Labs，《Streaming 3DGS worlds on the web》（Spark 2.0）：https://www.worldlabs.ai/blog/spark-2.0
- PlayCanvas Streamed SOG 格式：https://developer.playcanvas.com/user-manual/gaussian-splatting/formats/streamed-sog/
- MetalSplatter（项目固定 revision `71ff248e`）：https://github.com/scier/MetalSplatter
- spz-swift（SPZ 读写）：https://github.com/scier/spz-swift

## 附录 B：真机测量记录

（R0 完成后填写：机型、iOS 版本、模型、首帧、fps、内存峰值、5 分钟热状态。）
