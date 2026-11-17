# 原生 App 双任务接线与 A10 常驻部署

日期：2026-11-03。用户明确要求在 Mac 暂不可用时先完成 App 自动双任务、结果切换、失败重试，并把业务 API 与 worker 常驻到现有 A10，验证 Windows 能执行的部分。

**本轮完成：App 源码接线、A10 两项常驻服务、Windows→A10真实视频双结果、运行中服务重启恢复、失败分支幂等重试均已验证到各自范围。** 原生代码通过语法／工程检查；没有 Xcode 编译、XCTest执行或 iPhone 真机结论。

## 当前架构

```text
iPhone 原生采集包：原片 + 同次 ARKit metadata
  → /v2/captures 上传与核验 → 唯一采集回执（成长一次）
  → /v2/captures/:captureId/reconstructions（双算法授权）
      ├─ FF task → WorldMirror2 → 完整点数SH0展示副本 + 匹配相机
      └─ SfM task → COLMAP → MCMC GS → 完整SH3 PLY + 匹配相机
  → 私有HTTP下载、大小/哈希/格式验证 → 原生Metal版本切换与游览
```

本轮 Windows 使用外部视频走 `/v2/video-reconstructions` 验证实际部署；原生 capture 桥接使用明确合成测试数据验证协议与生命周期，没有伪造真实 ARKit 采集。两种来源的 sourceKind、capture/receipt、视频与 metadata 哈希分别保留。独立 SfM 不使用 FF 预测相机作为先验。

## App 已接入的源码行为

- 上传确认说明同时包含 FF 与 SfM。原片和 metadata 核验后自动提交双任务，后续通过 GET 恢复状态。
- 两条任务独立显示；先完成的立即可看，失败分支有单独重试按钮。blocked 未知写入不能盲目重算。
- 重试 UUID 先原子保存再 POST；丢失响应或重开 App 后沿用原请求核对，不能重复创建重试任务。
- 同一 Metal 查看器切换 FF / SfM。每个模型使用自己的相机起点；下载或渲染新版本失败时保留／恢复已成功显示的版本。
- 文件大小、SHA-256、结果路径、SH档位、来源与账号均验证；切换服务器后迟到响应不能写入当前账号状态。
- 重建记录不增加采集回执，成长只统计唯一真实采集核验回执。外部视频和人工导入 studies 不冒充原生采集。
- Debug 默认地址为 `http://9.135.79.113:8787`；Release 继续要求 HTTPS。

实现文件：`ios/PocketWorld/Models/NativeReconstruction.swift`、`Services/NativeReconstructionStore.swift`、`Services/APIClient.swift`、`Views/NativeReconstructionView.swift`。这些是源码实现，不代表 Xcode 编译或 iPhone 渲染通过。

## A10 部署

| 项目 | 实际配置 |
|---|---|
| 业务 API | `http://9.135.79.113:8787`，内网 HTTP |
| 健康检查 | `/health` |
| API 服务 | `pocketworld-api.service` |
| 双任务服务 | `pocketworld-dual-worker.service` |
| 运行身份 | 独立低权限 `pocketworld`，nologin |
| Node | 独立 v24.22.2，不替换系统 Node |
| 数据／任务记录 | `/mnt/data2/pocketworld/data`、`/mnt/data2/pocketworld/work` |
| 发布目录 | `/mnt/data2/pocketworld/releases`，root-owned不可变版本 |
| 配置 | `/etc/pocketworld/api.json`、`worker.json`，0600，不进入交接包 |
| 重建引擎 | 复用已有 RealityScan Hub；不重启它的API/worker，不改GPU分配 |

服务启用 systemd 开机启动、异常退出重启；worker 启动前等待业务 API 真正健康。任务落盘且每次远端写入先记录意图，服务重启不替换未知状态的 GPU 任务。正常运行不依赖 Windows 电脑保活。

相机读取使用受限 root-owned Python helper，输入为有大小限制的 JSON。worker 的 sudo 规则只允许这一条固定命令；没有把 Windows SSH 私钥复制到服务器，也没有给服务账号任意 root shell 权限。

首次真实部署验收发现系统 FFmpeg／FFprobe 为 root-only 0700，低权限worker无法执行。已复制独立可执行副本到专用runtime，并在worker的私有挂载环境只读映射；共享工具权限保持原状。相同sandbox下真实视频 ffprobe 和单帧抽取通过，随后用正式失败重试接口新建 attempt，旧失败记录保留。

部署脚本、systemd units、运行与恢复说明在 `deploy/a10/README.md`。本机部署诊断放在忽略目录 `work/a10-deployment-20261103/`，不包含在源码包。

## 验证范围

1. Windows 和 A10 服务账号下分别运行全部后端测试，验证 native capture 桥接、独立结果、来源保护、失败重试、重复请求与删除。
2. Windows 客户端向常驻 A10 API 上传现有真实视频，由 A10 worker 自动抽帧、运行两条GPU任务、打包并返回模型与相机；结果下载检查大小／SHA-256／格式／SH3／Range／所有者鉴权。
3. 单独使用明确合成的不可解码小容器测试失败与重试，不当作扫描或真实重建。需核实停止于解码阶段、没有 provider/GPU 提交。
4. 在确认远端任务已绑定后重启业务服务，核对 source、task、project和step不变，成功结果不重复计算。
5. Swift 工程结构与语法检查；XCTest 源码可交给 Mac 执行，不把语法检查记为编译或 XCTest 通过。

### 最终实测结果

完成时间：2026-11-03 22:39:20（Asia/Shanghai）。原片为已有 `Downloads/video.mp4`，1,892,196字节；SHA-256为 `32b699cefa0fabdae7e7905ffbeef94a4659a2775eaf3c0aed03b13d2ea46712`。

| 项目 | FF | SfM→3DGS |
|---|---|---|
| Hub project / step | `9786070931d8` / `7e4833ecb8c4` | `4c74779487d5` / `958a81be3e80` |
| 最终状态 | SUCCESS → 业务ready | SUCCESS → 业务ready |
| 远端任务耗时 | 37.79秒 | 234.74秒，7,000步 |
| A10编号 | 7 | 4 |
| 模型 | 全点数SH0 `.splat` | 完整SH3 `.ply` |
| 高斯数／相机数 | 490,742／16 | 142,256／64 |
| 文件大小 | 15,703,744字节 | 35,281,019字节 |
| SHA-256 | `526b6ba324d4ff8a757487b318d6b1fbbdf7eccd0c6c6df1913583be25b57ffe` | `4dd8986b1a5563240513ec4fc44847d47bf05b6d1f1b0dc483e86d565746e647` |

业务来源 ID：`2b93177b-d993-4d49-8551-18393c150d65`。两份模型和相机均完整下载，通过大小、SHA-256、模型格式、高斯数、相机结构、SH3、HTTP Range和跨用户拒绝检查。FF在SfM仍运行时已可下载。该耗时只代表本次样本，不含前面的部署排错，不是不同帧数算法的公平画质评测。

原始任务因解码工具权限失败后，已通过正式 retry API建立两条新attempt，旧错误记录留在previousAttempts。不存在删除失败日志、改ready状态、复用上次结果冒充新计算的操作。

14:36:38 UTC启动业务服务重启验证：API与worker进程确实更换；来源、job/claim/worker/project/step/group/images ID保持不变；Hub每个算法仍只有1个计算step。原Hub两进程PID未变。FF保持ready，SfM恢复后完成。开机自启已配置，未通过重启整台A10主机进行验证。

单独的合成无视频轨测试在工具权限修复后重跑：FF/SfM均正确返回invalid_video；只重试FF、重复UUID、历史1条、SfM不受影响、鉴权与删除防重生均通过。三次attempt均无provider目录或manifest；同fixture在服务环境的ffprobe返回空视频流，证实没有提交GPU计算。合成源已删除，不计真实扫描或重建样本。

检查结果：Windows后端125/125，A10服务账号后端125/125；25个Swift文件语法通过，23个App源文件与2个测试源文件工程结构通过。新增9项Swift XCTest覆盖来源绑定、重试持久化、连接恢复和账号切换，**待Mac执行**。

### 本机证据与复跑

- 无凭证真实结果报告：`outputs/app-a10-real-video-validation-20261103.json`。
- 无凭证错误路径报告：`outputs/app-a10-failure-retry-validation-20261103.json`。
- 真实下载：`work/a10-mvp-20261103/live/downloads/{preview.splat,preview.cameras.json,refined.ply,refined.cameras.json}`。
- 服务重启证据：`work/a10-deployment-20261103/restart-verification.json`。
- 客户端私有身份：`work/a10-mvp-20261103/live/client-private.json`，含token，仅留本机，不随交接包分享。

```powershell
Set-Location D:\PocketWorld
# 读取同一次来源并再次验证下载，不会新建GPU任务
node server/tools/check-deployed-dual-video.mjs --config work/a10-mvp-20261103/client-config.json
```

发布版本为 `20261103-a10-41f62f60916f-r2`。业务服务保持运行，无需启动Windows本地API或worker；旧Windows临时pilot仍独立保留，不作为当前App默认地址。

最后只读检查：两个业务服务均active/running且enabled，pendingWorkerJobs=0，两份真实结果ready，每个算法只有1个Hub计算step，Hub进程未变。详见 `work/a10-deployment-20261103/final-service-verification.json`。系统FFmpeg原权限问题、worker启动时API未就绪的竞态均已修复并保留部署诊断。

## 后续真机验收

Mac 可用后仍需：Xcode解析依赖和编译、Personal Team签名装机，真实拍摄／上传，FF与SH3首帧、版本切换、轨迹游览、内存／FPS与断网恢复测试。当前内部HTTP地址仅用于Debug联调，尚无公网域名/TLS部署。结果仍为全文件下载，未实现大场景LOD streaming。
