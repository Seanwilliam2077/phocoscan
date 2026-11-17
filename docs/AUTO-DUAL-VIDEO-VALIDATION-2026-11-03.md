# 上传视频后自动 FF + SfM→3DGS：Windows 验证

> 后续更新：本文件记录17:50的Windows临时服务测试；22:39已完成原生App双任务接线、A10常驻服务及新一轮Windows→A10验证。当前服务与最新完成范围见 [App/A10验收](APP-A10-MVP-VALIDATION-2026-11-03.md)，本文件末尾的App接口未接入状态已被该更新替代。

日期：2026-11-03。输入为 `C:\Users\seanzjxiao\Downloads\video.mp4`，用户授权用已有视频运行两个新任务。本轮只验收 Windows 业务服务、A10 重建和私有结果下载；原生 iPhone App 尚未编译或真机验收。

**结论：Windows 闭环已通过。** 2026-11-03 17:50:35 两个任务均为 ready，两份模型及相机均经业务 HTTP 接口完整下载、核对大小和 SHA-256、验证 Range 请求。SfM 首次失败后修复并只重试该分支，旧失败记录保留；最终没有用历史模型替代本次计算。

| 本次真实产物 | FF 快速预览 | SfM→3DGS 精细结果 |
|---|---|---|
| 服务器任务耗时 | 61.02 秒 | 修复后225.56秒 |
| GPU | A10 编号7 | A10 编号1 |
| 选帧／返回相机 | 16／16 | 64／64 |
| 高斯数 | 490,221 | 142,279 |
| 手机下载格式 | SH0 `.splat`，全点数 | 完整 SH3 `.ply`，原始字节 |
| 下载大小 | 15,687,072 字节 | 35,286,723 字节 |
| 模型SHA-256 | `69a0b94009ea6d711004d8222f672e87cde998fc29329c14d4b9ad4af392d63f` | `4e73efb5c3f5b4b1123217cc1df689a8121955ba663ae04073be26bf1a2dff5f` |

文件位于 `work/auto-dual-video-20261103/live/downloads/`：`preview.splat`、`preview.cameras.json`、`refined.ply`、`refined.cameras.json`。可分享的无凭证实测记录为 `outputs/auto-dual-video-validation-20261103.json`。上表耗时取 Hub 实际开始到结束，不包含本轮诊断与修复等待；两分支计算预算不同，不是同条件画质对比。

## 实现范围

```text
外部 RGB 视频 → 所有者鉴权上传 → SHA-256/大小/容器核对 → 持久保存
  ├─ 自动 FF 任务 → 本次视频16帧 → WorldMirror2 → 模型+相机 → 私有下载
  └─ 自动 SfM 任务 → 本次视频64帧 → COLMAP → MCMC 3DGS → 模型+相机 → 私有下载
```

两条任务独立处理，先完成的结果立即可下载；不等待另一条分支。没有 ARKit 内参、手机位姿或 LiDAR 数据时不补造。这条外部视频通道不产生采集成长回执，不冒充原生采集。

- API：`server/src/video-reconstructions.mjs`，路由见 `server/README.md`。
- 队列处理器：`server/src/dual-reconstruction-worker.mjs`；每次启动恢复数据库、原片、选帧清单、provider journal。
- Hub 适配器：`server/src/dual-reconstruction-provider.mjs`；写入前落盘请求意图；结果未知的写操作进入 blocked，不能盲目重发。
- 模型／相机打包：`server/src/dual-reconstruction-assets.mjs`、`server/tools/read-hub-cameras.py`。按本次 project/step/图像资产逐一核对，读取实际相机产物。
- Windows 实测入口：`server/tools/check-auto-dual-video.mjs`。走真实 HTTP 上传／查询／结果下载，每轮启动新 worker 进程，中途重启 API 检查持久恢复。

### 重试与来源

相同来源 UUID 的相同字节重复上传始终保留两条当前任务。失败重算必须显式调用 `POST .../:id/retry` 并提供 `failedTaskId` 和固定的新 UUID。旧失败记录保留为 `previousAttempts`，新任务用独立目录，成功的另一分支不变。相同 retry 请求幂等；正在运行、已成功、未知远端写入的 blocked 任务都不可通过此接口重算。结果下载重试不触发 GPU 计算。

## 真实输入与运行记录

| 项目 | 值 |
|---|---|
| 来源类型 | 外部 RGB MP4；540×960，11.733333 秒，30 fps，352 帧，包含原视频音轨 |
| 文件字节数 | 1,892,196 |
| 原片 SHA-256 | `32b699cefa0fabdae7e7905ffbeef94a4659a2775eaf3c0aed03b13d2ea46712` |
| 业务 reconstruction ID | `45f72aa4-2ae0-43ba-b2b2-1f16bb196f5c` |
| 实测起点 | 2026-11-03 17:35:15，Asia/Shanghai |
| FF 新 Hub project / step | `8519df38c886` / `54fb6770c2ca` |
| 首次 SfM project / step | `646da9325926` / `abec5a93e0e8`，已失败并保留 |
| 修复后 SfM project / step | `b3282791d850` / `29c6b182fa6e` |

首次 SfM 失败是真实算法失败：64张上传图像与此前成功实验逐字节一致，但 COLMAP 多线程导入导致 image_id 分配不同，mapper 选择了不同的初始两视角。此轮只注册3帧且稀疏点为0，MCMC 在训练前退出。没有借用旧模型或 FF 位姿填补结果。补丁位于 `deploy/sfm-quality-guard/`：确定的图像导入顺序与随机种子、真实稀疏质量门槛、最多两个额外候选初始化。候选仅来自当前任务的两视几何，不硬编码此视频的图片对。

修复后通过正式 retry API 仅替换失败 SfM 任务为 `29e795b0-2b98-42e8-819c-330d81cefe91`，FF 任务 ID 与文件保持不变。新 SfM 在默认初始化即通过：64/64 注册、6,275 稀疏点、逐点重投影误差中位数约0.459 px；没有触发候选重试。随后继续7,000步 MCMC 训练。

FF 已由本次上传自动提交并完成；所有高斯保留为 SH0 `.splat`，按该引擎真实语义解释 opacity probability 与 log scale。SfM 展示文件保留原始完整 SH3 PLY。两者分别绑定自己的相机，统一导出 OpenGL camera-to-world、row-major；尺度仍为 unknown。所有 SfM export_check 必需标志通过才允许发布，不以存在输出文件代替成功。

## 软件检查

`npm.cmd --prefix server test`：117/117通过，覆盖身份隔离、不可变视频、重复上传、独立结果、重启恢复、显式失败重试、未知写入阻止重发、进程并发恢复、相机来源、SH3、文件校验、删除后晚到结果不复活。`node scripts/check-project.mjs` 结构检查通过。两者不替代真实 GPU 验证或 Xcode 编译。

本次实际 HTTP/GPU 验证还确认：重复视频上传不增任务；重复 retry 请求不增任务；API 重启保持同一来源与任务ID；重试阶段连续45次重新启动 worker 进程能恢复同一远端任务；SfM 仍处理中时 FF 已可完整下载；最终两份结果都绑定同一原片哈希。

SfM guard 另有5个 Python 测试通过：退化候选排除、二进制稀疏门槛、默认失败后的候选成功、最多3次上限、漏图不能缩小分母。最终 helper 对旧失败、旧成功、本次新成功的真实 sparse 模型均进行了只读核验。默认初始化后的两次候选恢复在模拟测试通过，本次真实新任务没有触发该分支，不能声称所有候选恢复场景已实测。

## 复跑方法

本机当前测试配置与结果放在忽略目录 `work/auto-dual-video-20261103/`。`live/pilot-private.json` 保存用户 token，不能发给 App、提交 Git 或放进源码 ZIP。

```powershell
Set-Location D:\PocketWorld
# 重开同一次测试：保留原片、任务ID、provider日志；已完成任务只下载验证，不重算
node server/tools/check-auto-dual-video.mjs --config work/auto-dual-video-20261103/pilot-config.json

# 运维确认某个任务确实失败且原因已处理后，显式只重试该分支
node server/tools/check-auto-dual-video.mjs --config work/auto-dual-video-20261103/pilot-config.json --retry-failed-task <失败任务UUID>

# 持续服务需另起常驻业务 API 和 worker，二者使用相同 dataDir
node server/tools/dual-reconstruction-worker.mjs --config work/auto-dual-video-20261103/live/worker-private.json --watch
```

配置指定 FFmpeg/FFprobe 路径、Hub origin、16/64帧以及服务端 SSH 相机读取。测试脚本创建临时 loopback API，结束时正常关闭；这不是稳定公网后端。不要同时为同一工作目录启动多个 supervisor。

新环境可参考 `deploy/dual-reconstruction-worker.example.json`，将副本保存到忽略目录后填实际路径。`dataDir` 必须与业务服务完全相同，`dataDir`／`workDir` 相对 CLI 配置文件目录解析；SSH 用户需获授权只读获取指定任务产物。首次创建后处理器配置会绑定到工作目录，不能在已有任务中静默换服务器、凭证、抽帧配置或 SSH 路径。

## 未包含的验收

- 原生 App 对新自动任务 envelope 的接入、Xcode 编译、iPhone 上传与 Metal 渲染未在本轮通过。已有 SH3 与相机游览源码不等于真机运行。
- 当前相机产物通过服务端只读 SSH helper 获取；生产部署应提供鉴权 Hub 产物接口，避免业务 worker 依赖服务器本地目录布局。
- 结果是全文件下载，包含 Range 支持；不是 LOD／大场景按视锥 streaming，未验证手机峰值内存或 FPS。
- API 删除已删除业务原片／结果并阻止晚到发布，worker 工作文件及远端 Hub 数据仍需单独清理；不宣称全链路自动擦除。
- 一个视频的算法／分发成功不代表通用重建成功率，更不代表机器人碰撞、尺度、标定或训练数据质量通过。
