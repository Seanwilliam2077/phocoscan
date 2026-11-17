# Android 接入说明

此仓库的现有成品是 iOS 版 phocoscan。Android 端以同一套产品流程为目标，复用后端协议及校验规则；目前没有可直接运行的 Android 客户端。

## 同仓库协作

- `ios/`：现有 iPhone 客户端和测试。
- `android/`：Android 工程预留目录。
- `server/`：共享 API、异步任务、显存准入、结果验证及私有下载。
- `docs/CONTRACT.md`：接口说明；具体字段以相应实现和测试为准。

拿到私有仓库权限后：

```sh
git clone https://github.com/Seanwilliam2077/phocoscan.git
cd phocoscan
git switch -c android/bootstrap
```

Android 功能在 `android/*` 分支开发，通过 Pull Request 合入 `main`。共享接口的改动须兼容现有 iOS 客户端，并附服务端测试；不要直接改动线上服务或部署脚本的运行配置。

## 对齐当前产品，而不是历史文档中的旧界面

1. 深色背景、紫色强调色，横向创建入口；支持物体、人像、空间和独立单图创作。
2. 扫描优先保存原始素材，进入作品后先展示原始项目。**采集检查**展示采集点云/覆盖证据，不等同于训练出的 3DGS。
3. **3DGS 重建**分区内分别选择 **快速预览、精细重建、本机重建**；上传完成不自动启动全部算法。
4. 单图 AI 作品在独立的「单图」栏，不能计为实拍扫描重建或实测尺寸。
5. 每种结果独立生成、查看、失败恢复；切换不能串模型或覆盖原素材。
6. 「设置 → 作品管理」保留批量删除及低覆盖清理；显示百分比低于 80% 才进入清理候选，未知/无效覆盖和活跃任务不选中，确认后再删除。低覆盖清理保留关联的独立单图作品。
7. 本机训练必须真实存在才能提供入口；未移植 GPU 训练时应明确不可用，不能用云端任务冒充。

## 代码入口与复用边界

| 功能 | iOS/共享实现 | Android 工作 |
|---|---|---|
| 首页、作品、设置 | `ios/PocketWorld/Views/RootView.swift`、`HomeLayout.swift` | 重做原生界面，保持同一信息结构 |
| 采集、校准、偏离 | `ios/PocketWorld/Capture/ARScanRecorder.swift` | 平台相机、实际位姿/内参、时间同步与权限 |
| 采集检查 | `Capture/CaptureReview.swift`、`QualityVolume.swift` | 复用评估原则；设备无真实深度时不能伪造 |
| 原始数据包与关键帧 | `Capture/TrainingPackage.swift`、`KeyframeSelector.swift` | 保留像素、坐标、时间和来源的一致性 |
| 上传与任务恢复 | `Services/APIClient.swift`、`ResumableUpload.swift`、`NativeReconstructionStore.swift` | 实现持久意图、断点上传、账号隔离和幂等 |
| 结果格式和校验 | `Models/NativeReconstruction.swift`、`ReconstructionStudy.swift`、`Viewer/SceneCameraPath.swift` | 对齐字段、哈希、大小、结果 ID 与相机约定 |
| GPU 查看与本机训练 | `Viewer/`、`Training/` | Metal/ARKit 不能直接编译到 Android；需独立实现和真机数值验证 |
| 云端执行 | `server/src/` | 共用后端，先检查 `/health` 功能标记，按版本显式提交 |

## 先解决 Android 采集协议兼容

当前原生采集协议含 `cameraToWorldARKit`、`arTimestampSeconds`；`server/src/capture-v2.mjs` 校验器及 `server/src/server.mjs` 仍将该渠道的位姿来源记录为 `arkit_device_reported`。**不能直接把 Android 数据套入这些字段并宣称来自 ARKit。**

接入 Android 实采前，需要一次向后兼容的契约扩展，明确平台/位姿来源、坐标约定和时间基准，同时保留旧 iOS 协议。还须检查 `dual-reconstruction-worker.mjs` 的相机转换、关键帧对齐和位姿先验生成，使用合成数据与 Android 真机记录验证。真实缺失的深度、内参、跟踪质量不可用猜测填补。

可先做不依赖相机位姿的账号连接、作品状态、独立单图流程和真实结果查看。相关路由见 `server/src/image-generations.mjs` 及 `docs/CONTRACT.md` 的单图章节。请求需带当前用户认证，结果及上传缓存须按账号/服务器隔离。

## 必须保留的行为

- `/health` 功能标记决定可用入口；GPU 忙时显示服务器返回的忙碌状态，不悄悄增加另一种重建任务。
- 上传文件和 metadata 保持原始哈希；断网后依据服务器 offset 续传，避免重新生成拍摄 ID。
- 快速与精细任务角色分别为 `preview` / `refined`，展示名称改变不能改动协议值。
- 独立单图来源为 `ai_single_image`；不授予实测精度或真实未见面的保证。
- 只有真实且通过校验的资产才能显示可查看；下载失败不能假称重建失败或触发新 GPU 训练。
- 本机续训需保存优化器、随机状态、输入绑定等完整状态；成功重训保留上一版。

## 验证与私有数据

服务端使用 Node.js 24+：`npm --prefix server ci`，然后 `npm --prefix server test`。iOS 对照测试在 `ios/PocketWorldTests/`；源码测试不等于 Android 真机验收。

仓库不含真实拍摄视频/照片/相机轨迹、训练模型、数据库或密钥。唯一保留的图片资源是应用图标；数值测试使用代码构造的合成数据。真实相机轨迹参考测试需要在测试设备上显式设置 `PHOCOSCAN_ORBIT_REFERENCE_FIXTURE` 指向本机私有文件，未配置时跳过该项，其余合成测试正常运行。

每个平台至少验证：独立选择任务、断网上传恢复、不同结果切换、缺失缓存重新下载、重拍保留旧素材、删除失败保留原数据。真实拍摄和重建验收另外申请测试素材与运行权限，不从仓库获取密钥，也不把真实数据提交进 Git。
